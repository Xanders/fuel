module Fuel
  record GameResult, board : String, score : Int64, name : String, progress : JSON::Any, outcome : String? = nil
  record SessionContext, id : String, epoch : String, mode : String, actor : String, progress : JSON::Any
  record ModePolicy, capacity : Int32, public : Bool = false, late_join : Bool = true,
    shared : Bool = false, exclusive : Bool = true, start_immediately : Bool = false

  abstract class Rules
    abstract def initial : JSON::Any
    abstract def apply(state : JSON::Any, actor : String, action : JSON::Any) : JSON::Any
    abstract def project(state : JSON::Any, actor : String) : JSON::Any

    def initial(context : SessionContext) : JSON::Any
      initial
    end

    def join(state : JSON::Any, actor : String, progress : JSON::Any) : JSON::Any
      state
    end

    def join(state : JSON::Any, actor : String, progress : JSON::Any, events : SessionEvents) : JSON::Any
      join(state, actor, progress)
    end

    def leave(state : JSON::Any, actor : String) : JSON::Any
      state
    end

    def leave(state : JSON::Any, actor : String, events : SessionEvents) : JSON::Any
      leave(state, actor)
    end

    def apply(state : JSON::Any, actor : String, action : JSON::Any, events : SessionEvents) : JSON::Any
      apply(state, actor, action)
    end

    def authorize(state : JSON::Any, actor : String, progress : JSON::Any) : Nil
    end

    def finished?(state : JSON::Any) : Bool
      false
    end

    def tick(state : JSON::Any, dt : Time::Span) : JSON::Any
      state
    end

    def tick(state : JSON::Any, dt : Time::Span, events : SessionEvents) : JSON::Any
      tick(state, dt)
    end

    def result(state : JSON::Any, actor : String) : GameResult?
      nil
    end

    def effects(state : JSON::Any, now : Int64) : Array(Effect)
      [] of Effect
    end

    def acknowledge(state : JSON::Any, effect : Effect, receipt : JSON::Any) : JSON::Any
      state
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
    @pending = [] of Effect
    @effect_inflight = false
    @effect_retry_at : Time::Instant?
    @effect_error : String?
    @backlog = false
    @receipt_sequences = {} of String => Int64
    @receipt_log = {} of String => Array(JSON::Any)
    @analytics_revisions = {} of String => Int64
    @milestones = Set(String).new
    @activity = {} of String => Time::Instant
    @mutex = Mutex.new

    def initialize(@rules : Rules, owner : String, @mode : String, @capacity : Int32, @public : Bool, @receipt_limit = 256, @late_join = true, @effect_limit = 1024, @event_limit = 64, progress : JSON::Any = JSON.parse("{}"), start_immediately : Bool = false, preferences = {} of String => Int64)
      Fuel.key(mode)
      Fuel.check((1..32).includes?(capacity) && receipt_limit > 0 && effect_limit > 0 && event_limit > 0, "invalid_capacity")
      @members = [owner]
      @analytics_revisions = preferences.select { |actor, _| actor == owner }
      @state = @rules.initial(SessionContext.new(@id, @epoch, @mode, owner, progress))
      events = SessionEvents.new(Time.utc.to_unix)
      publish_candidate(@rules.join(JSON.parse(@state.to_json), owner, progress, events), facts: events.facts)
      @started = start_immediately
      remember(owner)
    end

    def member?(actor : String) : Bool
      @mutex.synchronize { @members.includes?(actor) && !@ended }
    end

    def members : Array(String)
      @mutex.synchronize { @members.dup }
    end

    def preference(actor : String, revision : Int64)
      @mutex.synchronize { @analytics_revisions[actor] = revision if @members.includes?(actor) }
    end

    def join(actors : Array(String), profiles = {} of String => JSON::Any, preferences = {} of String => Int64)
      @mutex.synchronize do
        Fuel.check(!@ended, "session_ended")
        additions = actors.uniq.reject { |a| @members.includes?(a) }
        Fuel.check(@late_join || !@started, "not_joinable")
        Fuel.check(@members.size + additions.size <= @capacity, "full")
        Fuel.check(@view_revisions.size + additions.count { |a| !@view_revisions.has_key?(a) } <= 1024, "capacity")
        candidate = JSON.parse(@state.to_json)
        events = SessionEvents.new(Time.utc.to_unix)
        additions.each { |actor| candidate = @rules.join(candidate, actor, profiles[actor]? || JSON.parse("{}"), events) }
        additions.each { |actor| @rules.project(JSON.parse(candidate.to_json), actor) }
        publish_candidate(candidate, preferences: preferences.select { |actor, _| additions.includes?(actor) }, facts: events.facts)
        changed(force: !additions.empty?)
        @members.concat(additions)
        additions.each { |actor| remember(actor) }
      end
    end

    def leave(actor : String, force = false)
      @mutex.synchronize { leave_unlocked(actor, force) }
    end

    private def leave_unlocked(actor : String, force = false)
      Fuel.check(force || @pending.empty? && (!@results.has_key?(actor) || @settled.includes?(actor)), "pending_result")
      return unless @members.includes?(actor)
      events = SessionEvents.new(Time.utc.to_unix)
      candidate = @rules.leave(JSON.parse(@state.to_json), actor, events)
      if force
        if @pending.first?.try(&.actor) == actor
          @effect_inflight = false
          @effect_error = nil
        end
        @pending.reject! { |effect| effect.actor == actor }
        @state = candidate
      else
        publish_candidate(candidate, excluding: actor, facts: events.facts)
      end
      @members.delete(actor)
      @activity.delete(actor)
      @connections.delete(actor)
      @sequences.delete(actor)
      @ready.delete(actor)
      @visible.delete(actor)
      @receipt_log.delete(actor)
      @analytics_revisions.delete(actor)
      @results.delete(actor)
      @settled.delete(actor)
      @ended = true if @members.empty?
      changed(force: true)
    end

    def disconnect(actor : String, generation : String)
      @mutex.synchronize do
        if @connections[actor]? == generation
          @connections.delete(actor)
          @sequences.delete(actor)
          @activity[actor] = Time.instant
        end
      end
    end

    def expire_idle(timeout : Time::Span)
      @mutex.synchronize do
        @activity.keys.each do |actor|
          next if Time.instant - @activity[actor] < timeout
          begin
            leave_unlocked(actor)
          rescue error : Error
            raise error unless error.code.in?("pending_result", "saving_backlog")
          end
        end
      end
    end

    def ready(actor : String, progress : JSON::Any? = nil)
      @mutex.synchronize do
        authorize(actor, progress)
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

    def snapshot(actor : String, generation : String? = nil, progress : JSON::Any? = nil) : JSON::Any
      @mutex.synchronize do
        authorize(actor, progress)
        Fuel.check(generation.nil? || @connections[actor]? == generation, "stale_connection")
        view(actor)
      end
    end

    def check(actor : String, generation : String?, progress : JSON::Any) : Nil
      @mutex.synchronize do
        authorize(actor, progress)
        Fuel.check(generation.nil? || @connections[actor]? == generation, "stale_connection")
      end
    end

    def command(actor : String, epoch : String, command_id : String, revision : Int64, action : JSON::Any, progress : JSON::Any? = nil) : JSON::Any
      Fuel.key(command_id)
      @mutex.synchronize do
        authorize(actor, progress)
        Fuel.check(epoch == @epoch, "session_lost")
        fingerprint = Digest::SHA256.hexdigest({revision, action}.to_json)
        receipt_key = {actor, command_id}.to_json
        if receipt = @receipts[receipt_key]?
          Fuel.check(receipt[0] == fingerprint, "conflict")
          return JSON.parse(receipt[1].to_json)
        end
        Fuel.check(!@backlog, "saving_backlog")
        Fuel.check(revision == @view_revisions[actor], "revision_conflict")
        Fuel.check(!@results.has_key?(actor), "session_ended")
        Fuel.check(!@rules.finished?(JSON.parse(@state.to_json)), "session_ended")
        events = SessionEvents.new(Time.utc.to_unix)
        publish_candidate(@rules.apply(JSON.parse(@state.to_json), actor, action, events), facts: events.facts)
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

    def connect(actor : String, progress : JSON::Any? = nil) : String
      @mutex.synchronize do
        authorize(actor, progress)
        @sequences[actor] = -1_i64
        @connections[actor] = Fuel.id
      end
    end

    def input(actor : String, generation : String, sequence : Int64, action : JSON::Any, progress : JSON::Any? = nil) : JSON::Any
      @mutex.synchronize do
        authorize(actor, progress)
        Fuel.check(@connections[actor]? == generation, "stale_connection")
        Fuel.check(!@backlog, "saving_backlog")
        Fuel.check(sequence >= 0 && sequence > @sequences[actor], "stale_input")
        Fuel.check(!@results.has_key?(actor), "session_ended")
        Fuel.check(!@rules.finished?(JSON.parse(@state.to_json)), "session_ended")
        events = SessionEvents.new(Time.utc.to_unix)
        publish_candidate(@rules.apply(JSON.parse(@state.to_json), actor, action, events), facts: events.facts)
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
        return if @ended || !@started || @backlog
        events = SessionEvents.new(Time.utc.to_unix)
        publish_candidate(@rules.tick(JSON.parse(@state.to_json), dt, events), facts: events.facts)
        @revision += 1
        changed
        freeze_results
      end
    rescue error : Error
      raise error unless error.code == "saving_backlog"
    end

    def pending_effects : Int32
      @mutex.synchronize { @pending.size }
    end

    def pending_work : Int32
      @mutex.synchronize { @pending.size + @results.keys.count { |actor| !@settled.includes?(actor) } }
    end

    def begin_effect : Effect?
      @mutex.synchronize do
        return nil if @effect_inflight || @effect_error || @pending.empty? || @effect_retry_at.try { |at| Time.instant < at }
        @effect_inflight = true
        @pending.first
      end
    end

    def retry_effect(effect : Effect, error : String? = nil, delay = Time::Span.zero)
      @mutex.synchronize do
        if @pending.first?.try(&.id) == effect.id
          @effect_inflight = false
          @view_revisions.each_key { |actor| @view_revisions[actor] += 1 } if @effect_error != error
          @effect_error = error
          @effect_retry_at = Time.instant + delay
        end
      end
    end

    def finish_effect(effect : Effect, receipts : Hash(String, JSON::Any))
      @mutex.synchronize do
        return unless @pending.first?.try(&.id) == effect.id && @effect_inflight
        reply = receipts[effect.actor]? || raise Error.new("missing_receipt")
        backlog_before = @backlog
        candidate = effect.action == "_fuel_event" ? JSON.parse(@state.to_json) : @rules.acknowledge(JSON.parse(@state.to_json), effect, reply)
        publish_candidate(candidate, effect.id)
        @effect_inflight = false
        @effect_retry_at = nil
        receipts.each do |actor, receipt|
          next if receipt["source"]?.try(&.as_s) == "event"
          next unless @members.includes?(actor)
          sequence = (@receipt_sequences[actor]? || 0_i64) + 1_i64
          @receipt_sequences[actor] = sequence
          log = @receipt_log[actor] ||= [] of JSON::Any
          log << Fuel.json({sequence: sequence.to_s, operation: receipt})
          while log.size > @event_limit || log.to_json.bytesize > 16384
            log.shift
          end
          @view_revisions[actor] += 1
        end
        changed
        # Saving pressure is visible to everyone; receipts only to their recipients.
        @view_revisions.each_key { |actor| @view_revisions[actor] += 1 } if backlog_before != @backlog
      end
    end

    def pending_result? : Bool
      @mutex.synchronize { !@pending.empty? || @results.keys.any? { |actor| !@settled.includes?(actor) } }
    end

    def pending_for?(actor : String) : Bool
      @mutex.synchronize { @pending.any? { |effect| effect.actor == actor } || @results.has_key?(actor) && !@settled.includes?(actor) }
    end

    def quarantined? : Bool
      @mutex.synchronize { !@effect_error.nil? }
    end

    def finished? : Bool
      @mutex.synchronize { @ended || @rules.finished?(JSON.parse(@state.to_json)) || !@members.empty? && @members.all? { |a| @results.has_key?(a) } }
    end

    def disposable? : Bool
      @mutex.synchronize { @ended && @pending.empty? && !@effect_inflight && @results.keys.none? { |a| !@settled.includes?(a) } }
    end

    def persist_result(store : Store, credential : Credential, analytics : Questmetry? = nil)
      return if @mutex.synchronize { @results.empty? }
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

    private def authorize(actor : String, progress : JSON::Any? = nil)
      Fuel.check(!@ended, "session_ended")
      Fuel.check(@members.includes?(actor), "forbidden")
      @rules.authorize(JSON.parse(@state.to_json), actor, progress || JSON.parse("{}"))
      @activity[actor] = Time.instant
    end

    private def view(actor : String) : JSON::Any
      log = @receipt_log[actor]? || [] of JSON::Any
      cursor = @receipt_sequences[actor]? || 0_i64
      Fuel.json({session_id: @id, mode: @mode, code: @code, epoch: @epoch, revision: @view_revisions[actor].to_s, server_time: Time.utc.to_rfc3339,
                 state: @rules.project(JSON.parse(@state.to_json), actor), ready: @ready.size == @members.size,
                 last_input: (@sequences[actor]? || -1_i64).to_s, saving_backlog: @backlog, effect_error: @effect_error,
                 receipt_cursor: cursor.to_s, receipt_base: (log.first?.try(&.["sequence"].as_s) || (cursor + 1).to_s), receipts: log})
    end

    private def effect_fingerprint(effect : Effect) : String
      Digest::SHA256.hexdigest({effect.actor, effect.action, Fuel.canonical(effect.payload)}.to_json)
    end

    private def publish_candidate(candidate : JSON::Any, remove : String? = nil, excluding : String? = nil, preferences = {} of String => Int64, facts = [] of Effect)
      Fuel.check(@effect_error.nil?, "saving_backlog")
      retained = @pending.reject { |effect| effect.id == remove }
      seen = Set(String).new
      fresh = facts.reject { |fact| @milestones.includes?(fact.id) }
      Fuel.check(@milestones.size + fresh.size <= 16384, "milestone_capacity")
      (@rules.effects(JSON.parse(candidate.to_json), Time.utc.to_unix) + fresh).each do |descriptor|
        id = "#{@epoch}-#{descriptor.id}"
        Fuel.check(id != remove, "effect_acknowledgement")
        Fuel.check(seen.add?(id), "effect_conflict")
        if prior = retained.find { |effect| effect.id == id }
          Fuel.check(effect_fingerprint(prior) == effect_fingerprint(descriptor), "effect_conflict")
        else
          revisions = @analytics_revisions.merge(preferences)
          frozen = descriptor.preferences.empty? ? revisions : descriptor.preferences
          retained << Effect.new(id, descriptor.actor, descriptor.action, descriptor.payload, descriptor.occurred_at, @id, @epoch, frozen)
        end
      end
      if retained.size > @effect_limit
        unless @backlog
          @backlog = true
          @view_revisions.each_key { |actor| @view_revisions[actor] += 1 }
        end
        raise Error.new("saving_backlog")
      end
      @members.each { |actor| @rules.project(JSON.parse(candidate.to_json), actor) unless actor == excluding }
      @state = candidate
      @pending = retained
      @analytics_revisions.merge!(preferences)
      fresh.each { |fact| @milestones.add(fact.id) }
      @backlog = false
    end

    private def remember(actor : String)
      @activity[actor] = Time.instant
      @view_revisions[actor] = @view_revisions.has_key?(actor) ? @view_revisions[actor] + 1 : 0_i64
      @visible[actor] = @rules.project(JSON.parse(@state.to_json), actor).to_json
    end

    private def changed(initiator : String? = nil, force = false)
      @members.each do |actor|
        visible = @rules.project(JSON.parse(@state.to_json), actor).to_json
        @view_revisions[actor] += 1 if force || actor == initiator || @visible[actor]? != visible
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

    def initialize(@rules : Rules, @max_rooms = 1000, @max_tickets = 2000, @ttl = 6.hours, @ticket_ttl = 5.minutes, @modes = {} of String => ModePolicy, @idle_timeout = 30.seconds)
      Fuel.check(@idle_timeout > Time::Span.zero, "invalid_limit")
      @modes.each do |mode, policy|
        Fuel.key(mode)
        Fuel.check((1..32).includes?(policy.capacity), "invalid_capacity")
      end
    end

    def create(actor : String, mode : String, capacity = 2, public = false, late_join = true, progress : JSON::Any = JSON.parse("{}"), preferences = {} of String => Int64) : Room
      @mutex.synchronize { create_unlocked(actor, mode, capacity, public, late_join, progress, preferences) }
    end

    def get(id : String) : Room
      @mutex.synchronize { @rooms[id]? || raise Error.new("session_lost") }
    end

    def join(actor : String, id : String, progress : JSON::Any = JSON.parse("{}"), preferences = {} of String => Int64) : Room
      @mutex.synchronize do
        room = @rooms[id]? || raise Error.new("session_lost")
        join_unlocked(actor, room, progress, preferences)
      end
    end

    def join_code(actor : String, value : String, progress : JSON::Any = JSON.parse("{}"), preferences = {} of String => Int64) : Room
      code = Invite.normalize(value)
      @mutex.synchronize do
        room = @rooms.values.find { |r| r.code == code && Time.instant - r.created_at < 5.minutes }
        raise Error.new("invalid_code") unless room
        join_unlocked(actor, room, progress, preferences)
      end
    end

    def list(mode : String) : Array(JSON::Any)
      @mutex.synchronize { @rooms.values.select { |r| r.mode == mode }.compact_map(&.listing).first(100) }
    end

    # Recover an unknown admission outcome without creating a second room.
    def mine(actor : String) : Array(JSON::Any)
      @mutex.synchronize do
        @rooms.values.select(&.member?(actor)).map do |room|
          Fuel.json({session_id: room.id, epoch: room.epoch, mode: room.mode, code: room.code})
        end
      end
    end

    def snapshot(actor : String, id : String, progress : JSON::Any? = nil) : JSON::Any
      get(id).snapshot(actor, progress: progress)
    end

    def command(actor : String, id : String, epoch : String, command_id : String, revision : Int64, action : JSON::Any) : JSON::Any
      get(id).command(actor, epoch, command_id, revision, action)
    end

    def match_candidates(mode : String) : Array(String)
      @mutex.synchronize { @tickets.keys.select { |key| key[1] == mode }.first(31).map(&.[0]) }
    end

    def match(actor : String, mode : String, generation = "default", profiles = {} of String => JSON::Any, preferences = {} of String => Int64) : JSON::Any
      match_party([actor], mode, @modes[mode]?.try(&.capacity) || 2, generation, profiles, preferences)
    end

    # Game code must verify party consent before calling this trusted API.
    def match_party(actors : Array(String), mode : String, capacity : Int32, generation = "default", profiles = {} of String => JSON::Any, preferences = {} of String => Int64) : JSON::Any
      Fuel.key(mode)
      Fuel.key(generation)
      Fuel.check(@modes.empty? || @modes.has_key?(mode), "invalid_mode")
      if policy = @modes[mode]?
        Fuel.check(!policy.shared && capacity == policy.capacity, "invalid_mode")
        Fuel.check(actors.all? { |actor| profiles.has_key?(actor) }, "missing_profile")
      end
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
        actors.each { |actor| check_admission(actor) }
        Fuel.check(@tickets.keys.none? { |k| actors.includes?(k[0]) }, "conflict")
        Fuel.check(@tickets.size + actors.size <= @max_tickets, "capacity")
        # Keep parties intact, but skip an earlier party when another combination
        # can fill the room. Capacity bounds this subset search to 33 states.
        needed = capacity - actors.size
        combinations = {0 => [] of Array(String)}
        @tickets.each_key do |k|
          party = @parties[k]
          if k[1] == mode && k[0] == party.first && @ticket_capacity[k] == capacity && party.all? { |member| can_admit?(member) && (@modes.empty? || profiles.has_key?(member)) }
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
          members.each { |actor| check_admission(actor) }
          room = create_unlocked(members.first, mode, capacity, false, false, profiles[members.first]? || JSON.parse("{}"), preferences)
          begin
            members.each { |actor| check_exclusive(actor, mode, room.id) }
            room.join(members, profiles, preferences)
          rescue error
            @rooms.delete(room.id)
            raise error
          end
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
      rooms.each { |room| room.expire_idle(@idle_timeout) }
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

    def rooms : Array(Room)
      @mutex.synchronize { @rooms.values.dup }
    end

    def preference(actor : String, revision : Int64)
      rooms.each { |room| room.preference(actor, revision) }
    end

    def active?(room : Room) : Bool
      !@modes[room.mode]?.try(&.shared) && !room.finished? && !room.members.empty?
    end

    def stats
      snapshot = rooms
      {rooms: snapshot.size, active: snapshot.count { |room| active?(room) },
       pending: snapshot.sum(&.pending_work), quarantined: snapshot.count(&.quarantined?)}
    end

    private def create_unlocked(actor, mode, capacity, public, late_join, progress : JSON::Any = JSON.parse("{}"), preferences = {} of String => Int64) : Room
      Fuel.check(@modes.empty? || @modes.has_key?(mode), "invalid_mode")
      policy = @modes[mode]?
      if policy
        capacity, public, late_join = policy.capacity, policy.public, policy.late_join
        if policy.shared && (existing = @rooms.values.find { |room| room.mode == mode && !room.finished? })
          return join_unlocked(actor, existing, progress, preferences)
        end
      end
      @rooms.reject! { |_, room| room.disposable? }
      Fuel.check(@rooms.size < @max_rooms, "capacity")
      check_exclusive(actor, mode)
      check_admission(actor)
      8.times do
        room = Room.new(@rules, actor, mode, capacity, public, late_join: late_join, progress: progress, start_immediately: policy.try(&.start_immediately) || false, preferences: preferences)
        next if @rooms.values.any? { |r| r.code == room.code }
        @rooms[room.id] = room
        return room
      end
      raise Error.new("capacity")
    end

    private def check_admission(actor : String)
      Fuel.check(@rooms.values.none?(&.pending_for?(actor)), "pending_result")
      Fuel.check(can_admit?(actor), "capacity")
    end

    private def can_admit?(actor : String) : Bool
      @rooms.values.none?(&.pending_for?(actor)) && @rooms.values.count { |r| r.member?(actor) } < 8
    end

    private def check_exclusive(actor : String, mode : String, target : String? = nil)
      @rooms.each_value do |room|
        next if room.id == target || !room.member?(actor)
        Fuel.check(!(@modes[mode]?.try(&.exclusive) || @modes[room.mode]?.try(&.exclusive)), "already_joined")
      end
    end

    private def join_unlocked(actor : String, room : Room, progress : JSON::Any = JSON.parse("{}"), preferences = {} of String => Int64) : Room
      if room.member?(actor)
        room.preference(actor, preferences[actor]) if preferences.has_key?(actor)
        return room
      end
      Fuel.check(!room.finished?, "session_ended")
      # Report the target's capacity before an unrelated membership conflict.
      Fuel.check(room.members.size < room.capacity, "full")
      check_exclusive(actor, room.mode, room.id)
      check_admission(actor)
      room.join([actor], {actor => progress}, preferences)
      room
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
