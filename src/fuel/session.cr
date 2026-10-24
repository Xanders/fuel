module Fuel
  record GameResult, board : String, score : Int64, name : String, progress : JSON::Any, outcome : String? = nil

  abstract class Rules
    abstract def initial : JSON::Any
    abstract def apply(state : JSON::Any, actor : String, action : JSON::Any) : JSON::Any
    abstract def project(state : JSON::Any, actor : String) : JSON::Any

    def tick(state : JSON::Any, dt : Time::Span) : JSON::Any
      state
    end

    def result(state : JSON::Any, actor : String) : GameResult?
      nil
    end
  end

  module Invite
    ALPHABET = "ACDEFHJKMNPRTUVWXY34679"

    def self.code : String
      String.build { |io| 6.times { io << ALPHABET[Random::Secure.rand(ALPHABET.size)] } }
    end

    def self.normalize(value : String) : String
      Fuel.check(value.ascii_only? && value.bytesize <= 30, "invalid_code")
      result = value.upcase.delete(" -")
      Fuel.check(result.size == 6 && result.each_char.all? { |c| ALPHABET.includes?(c) }, "invalid_code")
      result
    end

    def self.link(base : String, code : String) : String
      uri = URI.parse(base)
      Fuel.check(uri.scheme == "https" && !uri.host.nil? && uri.user.nil? && uri.query.nil? && uri.fragment.nil?, "invalid_link")
      "#{base}?invite=#{normalize(code)}"
    end
  end

  class Room
    getter id = Fuel.id
    getter epoch = Fuel.id
    getter code = Invite.code
    getter mode : String
    getter capacity : Int32
    getter public : Bool
    getter created_at = Time.instant
    @members : Array(String)
    @state : JSON::Any
    @revision = 0_i64
    @visible = {} of String => String
    @view_revisions = {} of String => Int64
    @receipts = {} of String => Tuple(String, JSON::Any)
    @connections = {} of String => String
    @sequences = {} of String => Int64
    @ready = Set(String).new
    @results = {} of String => GameResult
    @settled = Set(String).new
    @ended = false
    @started = false
    @mutex = Mutex.new

    def initialize(@rules : Rules, owner : String, @mode : String, @capacity : Int32, @public : Bool, @receipt_limit = 256, @late_join = true)
      Fuel.key(mode)
      Fuel.check((1..32).includes?(capacity) && receipt_limit > 0, "invalid_capacity")
      @members = [owner]
      @state = @rules.initial
      remember(owner)
    end

    def member?(actor : String) : Bool
      @mutex.synchronize { @members.includes?(actor) && !@ended }
    end

    def join(actors : Array(String))
      @mutex.synchronize do
        Fuel.check(!@ended, "session_ended")
        additions = actors.uniq.reject { |a| @members.includes?(a) }
        Fuel.check(@late_join || !@started, "not_joinable")
        Fuel.check(@members.size + additions.size <= @capacity, "full")
        Fuel.check(@view_revisions.size + additions.count { |a| !@view_revisions.has_key?(a) } <= 1024, "capacity")
        @members.concat(additions)
        additions.each { |actor| remember(actor) }
      end
    end

    def leave(actor : String, force = false)
      @mutex.synchronize do
        Fuel.check(force || !@results.has_key?(actor) || @settled.includes?(actor), "pending_result")
        @members.delete(actor)
        @connections.delete(actor)
        @sequences.delete(actor)
        @ready.delete(actor)
        @visible.delete(actor)
        @results.delete(actor)
        @settled.delete(actor)
        @ended = true if @members.empty?
      end
    end

    def ready(actor : String)
      @mutex.synchronize do
        authorize(actor)
        unless @ready.includes?(actor)
          @ready.add(actor)
          @view_revisions.each_key { |member| @view_revisions[member] += 1 }
          @started = true if @members.size == @capacity && @ready.size == @capacity
        end
      end
    end

    def listing : JSON::Any?
      @mutex.synchronize do
        if @public && !@ended && @members.size < @capacity && (@late_join || !@started)
          Fuel.json({id: @id, mode: @mode, capacity: @capacity, players: @members.size})
        end
      end
    end

    def snapshot(actor : String, generation : String? = nil) : JSON::Any
      @mutex.synchronize do
        authorize(actor)
        Fuel.check(generation.nil? || @connections[actor]? == generation, "stale_connection")
        view(actor)
      end
    end

    def command(actor : String, epoch : String, command_id : String, revision : Int64, action : JSON::Any) : JSON::Any
      Fuel.key(command_id)
      @mutex.synchronize do
        authorize(actor)
        Fuel.check(epoch == @epoch, "session_lost")
        fingerprint = Digest::SHA256.hexdigest({revision, action}.to_json)
        receipt_key = {actor, command_id}.to_json
        if receipt = @receipts[receipt_key]?
          Fuel.check(receipt[0] == fingerprint, "conflict")
          return JSON.parse(receipt[1].to_json)
        end
        Fuel.check(revision == @view_revisions[actor], "revision_conflict")
        Fuel.check(!@results.has_key?(actor), "session_ended")
        @state = @rules.apply(JSON.parse(@state.to_json), actor, action)
        @started = true
        @revision += 1
        changed(actor)
        freeze_results
        result = view(actor)
        @receipts[receipt_key] = {fingerprint, result}
        @receipts.shift if @receipts.size > @receipt_limit
        JSON.parse(result.to_json)
      end
    end

    def connect(actor : String) : String
      @mutex.synchronize do
        authorize(actor)
        @sequences[actor] = -1_i64
        @connections[actor] = Fuel.id
      end
    end

    def input(actor : String, generation : String, sequence : Int64, action : JSON::Any) : JSON::Any
      @mutex.synchronize do
        authorize(actor)
        Fuel.check(@connections[actor]? == generation, "stale_connection")
        Fuel.check(sequence >= 0 && sequence > @sequences[actor], "stale_input")
        Fuel.check(!@results.has_key?(actor), "session_ended")
        @state = @rules.apply(JSON.parse(@state.to_json), actor, action)
        @started = true
        @sequences[actor] = sequence
        @revision += 1
        changed(actor)
        freeze_results
        view(actor)
      end
    end

    def tick(dt : Time::Span)
      @mutex.synchronize do
        return if @ended || !@started
        @state = @rules.tick(JSON.parse(@state.to_json), dt)
        @revision += 1
        changed
        freeze_results
      end
    end

    def pending_result? : Bool
      @mutex.synchronize { @results.keys.any? { |actor| !@settled.includes?(actor) } }
    end

    def finished? : Bool
      @mutex.synchronize { @ended || !@members.empty? && @members.all? { |a| @results.has_key?(a) } }
    end

    def disposable? : Bool
      @mutex.synchronize { @ended && @results.keys.none? { |a| !@settled.includes?(a) } }
    end

    def persist_result(store : Store, credential : Credential, analytics : Questmetry? = nil)
      actor = store.authenticate(credential)
      result = @mutex.synchronize do
        authorize(actor)
        @settled.includes?(actor) ? nil : @results[actor]?
      end
      return unless result
      store.record_result(credential, @id, result.board, result.score, result.name, result.progress, result.outcome) do |c, account|
        if sink = analytics
          sink.enqueue(c, account, @id + actor, "session_finished", @id, JSON.parse("{}"))
        end
      end
      @mutex.synchronize { @settled.add(actor) }
    end

    private def freeze_results
      @members.each do |actor|
        next if @results.has_key?(actor)
        if result = @rules.result(JSON.parse(@state.to_json), actor)
          @results[actor] = result
        end
      end
    end

    private def authorize(actor : String)
      Fuel.check(!@ended, "session_ended")
      Fuel.check(@members.includes?(actor), "forbidden")
    end

    private def view(actor : String) : JSON::Any
      Fuel.json({session_id: @id, epoch: @epoch, revision: @view_revisions[actor].to_s, server_time: Time.utc.to_rfc3339,
                 state: @rules.project(JSON.parse(@state.to_json), actor), ready: @ready.size == @members.size,
                 last_input: (@sequences[actor]? || -1_i64).to_s})
    end

    private def remember(actor : String)
      @view_revisions[actor] = @view_revisions.has_key?(actor) ? @view_revisions[actor] + 1 : 0_i64
      @visible[actor] = @rules.project(JSON.parse(@state.to_json), actor).to_json
    end

    private def changed(initiator : String? = nil)
      @members.each do |actor|
        visible = @rules.project(JSON.parse(@state.to_json), actor).to_json
        @view_revisions[actor] += 1 if actor == initiator || @visible[actor]? != visible
        @visible[actor] = visible
      end
    end
  end

  class Sessions
    record MatchOutcome, reply : JSON::Any, party : Array(String), capacity : Int32, created_at : Time::Instant
    @rooms = {} of String => Room
    @tickets = {} of Tuple(String, String) => JSON::Any
    @parties = {} of Tuple(String, String) => Array(String)
    @ticket_created = {} of Tuple(String, String) => Time::Instant
    @ticket_capacity = {} of Tuple(String, String) => Int32
    @ticket_generation = {} of Tuple(String, String) => String
    @cancelled = {} of Tuple(String, String, String) => Time::Instant
    @matched = {} of Tuple(String, String, String) => MatchOutcome
    @playing = {} of String => String
    @mutex = Mutex.new

    def initialize(@rules : Rules, @max_rooms = 1000, @max_tickets = 2000, @ttl = 6.hours, @ticket_ttl = 5.minutes)
    end

    def create(actor : String, mode : String, capacity = 2, public = false, late_join = true) : Room
      @mutex.synchronize { create_unlocked(actor, mode, capacity, public, late_join) }
    end

    def get(id : String) : Room
      @mutex.synchronize { @rooms[id]? || raise Error.new("session_lost") }
    end

    def join(actor : String, id : String) : Room
      room = get(id)
      room.join([actor])
      room
    end

    def join_code(actor : String, value : String) : Room
      code = Invite.normalize(value)
      room = @mutex.synchronize { @rooms.values.find { |r| r.code == code && Time.instant - r.created_at < 5.minutes } }
      raise Error.new("invalid_code") unless room
      room.join([actor])
      room
    end

    def list(mode : String) : Array(JSON::Any)
      @mutex.synchronize { @rooms.values.select { |r| r.mode == mode }.compact_map(&.listing).first(100) }
    end

    def snapshot(actor : String, id : String) : JSON::Any
      get(id).snapshot(actor)
    end

    def command(actor : String, id : String, epoch : String, command_id : String, revision : Int64, action : JSON::Any) : JSON::Any
      get(id).command(actor, epoch, command_id, revision, action)
    end

    def match(actor : String, mode : String, generation = "default") : JSON::Any
      match_party([actor], mode, 2, generation)
    end

    # Game code must verify party consent before calling this trusted API.
    def match_party(actors : Array(String), mode : String, capacity : Int32, generation = "default") : JSON::Any
      Fuel.key(mode)
      Fuel.key(generation)
      Fuel.check(!actors.empty? && actors.uniq == actors && (2..32).includes?(capacity) && actors.size <= capacity, "invalid_party")
      @mutex.synchronize do
        key = {actors.first, mode}
        if outcome = @matched[{actors.first, mode, generation}]?
          Fuel.check(outcome.party == actors && outcome.capacity == capacity, "conflict")
          return outcome.reply
        end
        if prior = @tickets[key]?
          Fuel.check(@parties[key] == actors && @ticket_capacity[key] == capacity && @ticket_generation[key] == generation, "conflict")
          return prior
        end
        Fuel.check(actors.none? { |actor| @cancelled.has_key?({actor, mode, generation}) }, "match_cancelled")
        actors.each do |actor|
          if playing = @playing[actor]?
            room = @rooms[playing]?
            Fuel.check(room.nil? || room.finished? || !room.member?(actor), "conflict")
            @playing.delete(actor)
          end
        end
        Fuel.check(@tickets.keys.none? { |k| actors.includes?(k[0]) }, "conflict")
        Fuel.check(@tickets.size + actors.size <= @max_tickets, "capacity")
        # Keep parties intact, but skip an earlier party when another combination
        # can fill the room. Capacity bounds this subset search to 33 states.
        needed = capacity - actors.size
        combinations = {0 => [] of Array(String)}
        @tickets.each_key do |k|
          party = @parties[k]
          if k[1] == mode && k[0] == party.first && @ticket_capacity[k] == capacity
            combinations.keys.sort.reverse_each do |size|
              total = size + party.size
              if total <= needed && !combinations.has_key?(total)
                combinations[total] = combinations[size] + [party]
              end
            end
          end
          break if combinations.has_key?(needed)
        end
        members = actors + (combinations[needed]? || [] of Array(String)).flatten
        if members.size == capacity
          Fuel.check(@matched.size + members.size <= @max_tickets, "capacity")
          room = create_unlocked(members.first, mode, capacity, false, false)
          room.join(members)
          result = Fuel.json({status: "matched", session_id: room.id})
          members.each do |a|
            k = {a, mode}
            member_generation = @ticket_generation[k]? || generation
            party = @parties[k]? || actors
            @matched[{a, mode, member_generation}] = MatchOutcome.new(result, party.dup, capacity, Time.instant)
            @playing[a] = room.id
            forget_ticket(k)
          end
          return result
        end
        actors.each do |a|
          k = {a, mode}
          @tickets[k] = Fuel.json({status: "waiting"})
          @parties[k] = actors.dup
          @ticket_capacity[k] = capacity
          @ticket_created[k] = Time.instant
          @ticket_generation[k] = generation
        end
        @tickets[key]
      end
    end

    def cancel_match(actor : String, mode : String, generation = "default") : JSON::Any
      Fuel.key(mode)
      Fuel.key(generation)
      @mutex.synchronize do
        key = {actor, mode}
        if outcome = @matched[{actor, mode, generation}]?
          return outcome.reply
        end
        cancel_key = {actor, mode, generation}
        Fuel.check(@cancelled.has_key?(cancel_key) || @cancelled.size < @max_tickets, "capacity")
        @cancelled[cancel_key] = Time.instant
        return Fuel.json({status: "cancelled"}) if @ticket_generation[key]? != generation
        (@parties[key]? || [actor]).each do |a|
          @cancelled[{a, mode, generation}] = Time.instant
          forget_ticket({a, mode})
        end
        Fuel.json({status: "cancelled"})
      end
    end

    def remove_account(actor : String)
      @mutex.synchronize do
        @tickets.keys.select { |k| k[0] == actor }.each { |k| cancel_party(k) }
        @playing.delete(actor)
        @matched.reject! { |k, _| k[0] == actor }
        @rooms.each_value { |r| r.leave(actor, force: true) }
      end
    end

    def cleanup
      @mutex.synchronize do
        @cancelled.reject! { |_, created| Time.instant - created >= @ticket_ttl }
        @matched.reject! { |_, outcome| Time.instant - outcome.created_at >= @ticket_ttl }
        expired = @rooms.select { |_, r| r.disposable? || Time.instant - r.created_at >= @ttl && !r.pending_result? }.keys
        expired.each { |id| @rooms.delete(id) }
        @tickets.keys.each do |key|
          next unless @tickets.has_key?(key)
          if Time.instant - @ticket_created[key] >= @ticket_ttl
            cancel_party(key)
          end
        end
        @playing.reject! { |actor, id| !@rooms.has_key?(id) || !@rooms[id].member?(actor) }
      end
    end

    private def forget_ticket(key)
      @tickets.delete(key)
      @parties.delete(key)
      @ticket_created.delete(key)
      @ticket_capacity.delete(key)
      @ticket_generation.delete(key)
    end

    private def cancel_party(key)
      (@parties[key]? || [key[0]]).dup.each do |actor|
        k = {actor, key[1]}
        if generation = @ticket_generation[k]?
          @cancelled[{actor, key[1], generation}] = Time.instant
        end
        forget_ticket(k)
      end
    end

    def tick(dt : Time::Span)
      @mutex.synchronize { @rooms.values.dup }.each { |room| room.tick(dt) }
    end

    private def create_unlocked(actor, mode, capacity, public, late_join) : Room
      @rooms.reject! { |_, room| room.disposable? }
      Fuel.check(@rooms.size < @max_rooms, "capacity")
      Fuel.check(@rooms.values.count { |r| r.member?(actor) } < 8, "capacity")
      8.times do
        room = Room.new(@rules, actor, mode, capacity, public, late_join: late_join)
        next if @rooms.values.any? { |r| r.code == room.code }
        @rooms[room.id] = room
        return room
      end
      raise Error.new("capacity")
    end
  end

  class Ticker
    @accumulated = Time::Span.zero

    def initialize(@sessions : Sessions, @step = 50.milliseconds, @max_steps = 4)
      Fuel.check(@step > Time::Span.zero && @max_steps > 0, "invalid_tick")
    end

    def advance(elapsed : Time::Span) : Int32
      Fuel.check(elapsed >= Time::Span.zero, "invalid_tick")
      @accumulated = Math.min(@accumulated + elapsed, @step * @max_steps)
      count = 0
      while @accumulated >= @step
        @sessions.tick(@step)
        @accumulated -= @step
        count += 1
      end
      count
    end
  end
end
