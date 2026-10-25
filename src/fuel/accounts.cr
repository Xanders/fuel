module Fuel
  # Game hooks are pure: the framework owns authentication, locks and commit.
  abstract class AccountRules
    def initial(account : String, now : Int64) : JSON::Any
      JSON.parse("{}")
    end

    def refresh(account : String, state : JSON::Any, now : Int64) : JSON::Any
      state
    end

    def public_action?(name : String) : Bool
      false
    end

    def display_name(account : String, state : JSON::Any) : String
      account
    end

    def terminal?(action : String, reply : JSON::Any) : Bool
      false
    end

    def participants(actor : String, name : String, payload : JSON::Any) : Array(String)
      [] of String
    end

    abstract def apply(tx : AccountTransaction, actor : String, action : String, payload : JSON::Any, now : Int64) : JSON::Any
  end

  class AccountTransaction
    @notifications = {} of String => JSON::Any
    @scores = [] of Tuple(String, String, Int64, String, String?)
    @events = [] of Tuple(String, String, String, JSON::Any, Int64)

    def notifications
      @notifications.transform_values { |value| JSON.parse(value.to_json) }
    end

    def scores
      @scores.dup
    end

    def events
      @events.map { |account, name, session, properties, time| {account, name, session, JSON.parse(properties.to_json), time} }
    end

    def initialize(@states : Hash(String, JSON::Any))
    end

    def get?(account : String) : JSON::Any?
      @states[account]?.try { |value| JSON.parse(value.to_json) }
    end

    def get(account : String) : JSON::Any
      get?(account) || raise Error.new("account_missing")
    end

    def save(account : String, state : JSON::Any)
      Fuel.check(@states.has_key?(account), "undeclared_account")
      Fuel.check(state.to_json.bytesize <= 65536, "too_large")
      @states[account] = JSON.parse(state.to_json)
    end

    def notify(account : String, reply : JSON::Any)
      Fuel.check(@states.has_key?(account), "undeclared_account")
      Fuel.check(reply.to_json.bytesize <= 65536, "too_large")
      @notifications[account] = JSON.parse(reply.to_json)
    end

    def score(account : String, board : String, value : Int64, name : String, outcome : String? = nil)
      Fuel.key(board)
      Fuel.check(@states.has_key?(account) && @scores.size < 16, "undeclared_account")
      Fuel.check(value >= 0 && (1..80).includes?(name.size) && outcome.in?(nil, "win", "loss", "draw"), "invalid_result")
      @scores << {account, board, value, name, outcome}
    end

    def event(account : String, name : String, session : String, properties : JSON::Any, occurred_at : Int64)
      Fuel.check(@states.has_key?(account) && @events.size < 16, "undeclared_account")
      Fuel.check(properties.to_json.bytesize <= 2048, "invalid_event")
      @events << {account, name, session, JSON.parse(properties.to_json), occurred_at}
    end
  end

  # Frozen server work; clients cannot select this trust domain through HTTP.
  class Effect
    getter id : String, actor : String, action : String, occurred_at : Int64
    getter session_id : String?, epoch : String?
    @payload : String
    @preferences : Hash(String, Int64)

    def initialize(@id, @actor, @action, payload : JSON::Any, @occurred_at, @session_id = nil, @epoch = nil, preferences = {} of String => Int64)
      @payload = payload.to_json
      @preferences = preferences.dup
      Fuel.key(id)
      Fuel.key(actor)
      Fuel.key(action)
      Fuel.check(@payload.bytesize <= 65536, "too_large")
      Fuel.check(@preferences.size <= 64 && @preferences.values.all? { |revision| revision >= 0 }, "invalid_preference")
    end

    def payload : JSON::Any
      JSON.parse(@payload)
    end

    def preferences : Hash(String, Int64)
      @preferences.dup
    end
  end

  def self.canonical(value : JSON::Any) : JSON::Any
    case raw = value.raw
    when Hash
      Fuel.json(raw.keys.sort.to_h { |key| {key, canonical(raw[key])} })
    when Array
      Fuel.json(raw.map { |item| canonical(item) })
    else
      value
    end
  end

  class Store
    def available? : Bool
      @db.query_one("SELECT 1", as: Int32) == 1
    rescue
      false
    end

    def effect_receipts(effect : Effect) : Hash(String, JSON::Any)
      cursor = @db.query_one?("SELECT cursor FROM fuel_operations WHERE ns=$1 AND account=$2 AND id=$3", @namespace, effect.actor, effect.id, as: Int64)
      raise Error.new("account_missing") unless cursor
      result = {} of String => JSON::Any
      @db.query("SELECT account,receipt::text FROM fuel_operation_views WHERE ns=$1 AND cursor=$2", @namespace, cursor) do |rs|
        rs.each { result[rs.read(String)] = JSON.parse(rs.read(String)) }
      end
      result
    end

    # Resolve profiles before the caller takes a registry/room lock, retaining
    # the sorted account locks through its short nonblocking authority boundary.
    def with_accounts(credential : Credential, participants : Array(String), rules : AccountRules?, &)
      transaction do |c|
        actor = identify(c, credential)
        ids = ([actor] + participants).uniq.sort
        Fuel.check(ids.size <= 32, "too_many_participants")
        ids.each do |id|
          Fuel.key(id)
          c.query_one?("SELECT id FROM fuel_accounts WHERE ns=$1 AND id=$2 FOR UPDATE", @namespace, id, as: String)
        end
        Fuel.check(verify(c, credential) == actor, "unauthorized")
        profiles = {} of String => JSON::Any
        preferences = {} of String => Int64
        ids.each do |id|
          next unless c.query_one?("SELECT id FROM fuel_accounts WHERE ns=$1 AND id=$2", @namespace, id, as: String)
          if rules
            state = account_state(c, id, rules, Time.utc.to_unix)
            persist_state(c, id, state)
            profiles[id] = state
          else
            profiles[id] = JSON.parse("{}")
          end
          preferences[id] = c.query_one("SELECT analytics_revision FROM fuel_accounts WHERE ns=$1 AND id=$2", @namespace, id, as: Int64)
        end
        yield c, actor, profiles, preferences
      end
    end

    def account(credential : Credential, rules : AccountRules) : JSON::Any
      with_actor(credential) do |c, actor|
        now = Time.utc.to_unix
        state = account_state(c, actor, rules, now)
        persist_state(c, actor, state)
        enabled, revision = c.query_one("SELECT analytics_enabled,analytics_revision FROM fuel_accounts WHERE ns=$1 AND id=$2", @namespace, actor, as: {Bool, Int64})
        Fuel.json({account_id: actor, progress: state, analytics_enabled: enabled, analytics_revision: revision.to_s, server_time: now})
      end
    end

    def execute(credential : Credential, id : String, action : String, payload : JSON::Any, rules : AccountRules, analytics : Questmetry? = nil) : JSON::Any
      Fuel.check(!action.starts_with?("_fuel_") && rules.public_action?(action), "forbidden")
      perform_operation(id, action, payload, rules, credential: credential, analytics: analytics)
    end

    def apply_effect(effect : Effect, rules : AccountRules, analytics : Questmetry? = nil) : JSON::Any
      perform_operation(effect.id, effect.action, effect.payload, rules, actor: effect.actor, occurred_at: effect.occurred_at,
        session: effect.session_id, epoch: effect.epoch, analytics: analytics, preferences: effect.preferences)
    end

    def operation(credential : Credential, id : String) : JSON::Any
      Fuel.key(id)
      with_actor(credential) do |c, actor|
        text = c.query_one?("SELECT receipt::text FROM fuel_operation_views WHERE ns=$1 AND account=$2 AND id=$3", @namespace, actor, id, as: String)
        text ? JSON.parse(text) : raise Error.new("not_found")
      end
    end

    # A fresh client receives the latest page; a journal resumes forward.
    def operations(credential : Credential, after : String? = nil, limit : Int32 = 100, terminal_only = false) : Array(JSON::Any)
      Fuel.check((1..100).includes?(limit), "invalid_limit")
      Fuel.check(after.nil? || after.not_nil!.matches?(/\A[0-9]{1,19}\z/), "invalid_cursor")
      cursor = after.try(&.to_i64) || 0_i64
      with_actor(credential) do |c, actor|
        rows = [] of JSON::Any
        bytes = 0
        full = false
        order = after ? "ASC" : "DESC"
        c.query("SELECT receipt::text FROM fuel_operation_views WHERE ns=$1 AND account=$2 AND cursor>$3 AND (NOT $5 OR receipt @> '{\"terminal\":true}'::jsonb) ORDER BY cursor #{order} LIMIT $4", @namespace, actor, cursor, limit, terminal_only) do |rs|
          rs.each do
            text = rs.read(String)
            full ||= bytes + text.bytesize > 491520
            next if full
            bytes += text.bytesize
            rows << JSON.parse(text)
          end
        end
        after ? rows : rows.reverse
      end
    end

    private def perform_operation(id : String, action : String, payload : JSON::Any, rules : AccountRules,
                                  credential : Credential? = nil, actor : String? = nil, occurred_at : Int64? = nil,
                                  session : String? = nil, epoch : String? = nil, analytics : Questmetry? = nil, preferences = {} of String => Int64) : JSON::Any
      Fuel.key(id)
      Fuel.key(action)
      Fuel.check(payload.to_json.bytesize <= 65536, "too_large")
      transaction do |c|
        owner = actor || identify(c, credential.not_nil!)
        internal_event = credential.nil? && action == "_fuel_event"
        participants = ([owner] + (internal_event ? [] of String : rules.participants(owner, action, JSON.parse(payload.to_json)))).uniq.sort
        Fuel.check(participants.size <= 16, "too_many_participants")
        participants.each do |account|
          Fuel.key(account)
          c.query_one?("SELECT id FROM fuel_accounts WHERE ns=$1 AND id=$2 FOR UPDATE", @namespace, account, as: String)
        end
        Fuel.check(!c.query_one?("SELECT id FROM fuel_accounts WHERE ns=$1 AND id=$2", @namespace, owner, as: String).nil?, "account_missing")
        Fuel.check(verify(c, credential) == owner, "unauthorized") if credential
        source = credential ? "public" : (internal_event ? "event" : "effect")
        fingerprint = Digest::SHA256.hexdigest({source, action, Fuel.canonical(payload), participants, occurred_at, session, epoch, preferences.to_a.sort}.to_json)
        if prior = c.query_one?("SELECT fingerprint,reply::text FROM fuel_operations WHERE ns=$1 AND account=$2 AND id=$3", @namespace, owner, id, as: {String, String})
          Fuel.check(prior[0] == fingerprint, "conflict")
          next JSON.parse(prior[1])
        end
        now = occurred_at || Time.utc.to_unix
        states = {} of String => JSON::Any
        participants.each do |account|
          if c.query_one?("SELECT id FROM fuel_accounts WHERE ns=$1 AND id=$2", @namespace, account, as: String)
            states[account] = internal_event ? JSON.parse(c.query_one("SELECT progress::text FROM fuel_accounts WHERE ns=$1 AND id=$2", @namespace, account, as: String)) : account_state(c, account, rules, now)
          end
        end
        domain = AccountTransaction.new(states)
        reply = if internal_event
                  domain.event(owner, payload["name"].as_s, session || id, payload["properties"], now)
                  Fuel.json({status: "recorded"})
                else
                  rules.apply(domain, owner, action, JSON.parse(payload.to_json), now)
                end
        Fuel.check(reply.to_json.bytesize <= 65536, "too_large")
        states.each { |account, state| persist_state(c, account, state) } unless internal_event
        cursor = c.query_one("INSERT INTO fuel_operations(ns,account,id,fingerprint,reply) VALUES($1,$2,$3,$4,'{}'::jsonb) RETURNING cursor", @namespace, owner, id, fingerprint, as: Int64)
        committed = Time.utc.to_unix
        receipts = domain.notifications.merge({owner => reply})
        result = JSON.parse("{}")
        receipts.each do |viewer, body|
          Fuel.check(c.query_one?("SELECT id FROM fuel_operation_views WHERE ns=$1 AND account=$2 AND id=$3", @namespace, viewer, id, as: String).nil?, "conflict")
          receipt = Fuel.json({operation_id: id, cursor: cursor.to_s, source: source, session_id: session, epoch: epoch,
                               action: action, occurred_at: now, committed_at: committed, terminal: source == "effect" && rules.terminal?(action, body), reply: body})
          c.exec("INSERT INTO fuel_operation_views(ns,account,id,cursor,receipt) VALUES($1,$2,$3,$4,$5::jsonb)", @namespace, viewer, id, cursor, receipt.to_json)
          result = receipt if viewer == owner
        end
        c.exec("UPDATE fuel_operations SET reply=$4::jsonb WHERE ns=$1 AND account=$2 AND id=$3", @namespace, owner, id, result.to_json)
        domain.scores.each do |account, board, value, name, outcome|
          c.exec(<<-SQL, @namespace, board, account, value, name)
            INSERT INTO fuel_scores(ns,board,account,score,name) VALUES($1,$2,$3,$4,$5)
            ON CONFLICT(ns,board,account) DO UPDATE SET score=excluded.score,name=excluded.name,achieved_at=now()
            WHERE excluded.score>fuel_scores.score
            SQL
          c.exec("INSERT INTO fuel_results(ns,account,id,fingerprint,reply,board,name,outcome) VALUES($1,$2,$3,$4,$5::jsonb,$6,$7,$8)", @namespace, account, "#{id}-#{board}", fingerprint, reply.to_json, board, name, outcome) if outcome
        end
        if sink = analytics
          domain.events.each_with_index do |(account, name, journey, properties, occurrence), index|
            sink.enqueue(c, account, Digest::SHA256.hexdigest({owner, id, index}.to_json), name, journey, properties, Time.unix(occurrence), preferences[account]?)
          end
        end
        result
      end
    end

    private def identify(c : DB::Connection, credential : Credential) : String
      row = c.query_one?("SELECT b.account,b.verifier FROM fuel_bindings b JOIN fuel_accounts a ON a.ns=b.ns AND a.id=b.account WHERE b.ns=$1 AND b.id=$2 AND NOT b.revoked", @namespace, credential.id, as: {String, String})
      Fuel.check(!row.nil? && ([@device_key] + @previous_device_keys).any? { |key| Crypto::Subtle.constant_time_compare(row.not_nil![1], device_verifier(credential, key)) }, "unauthorized")
      row.not_nil![0]
    end

    private def account_state(c : DB::Connection, account : String, rules : AccountRules, now : Int64) : JSON::Any
      row = c.query_one("SELECT progress::text,progress_initialized FROM fuel_accounts WHERE ns=$1 AND id=$2", @namespace, account, as: {String, Bool})
      state = row[1] ? JSON.parse(row[0]) : rules.initial(account, now)
      state = rules.refresh(account, state, now)
      Fuel.check(state.to_json.bytesize <= 65536, "too_large")
      state
    end

    private def persist_state(c : DB::Connection, account : String, state : JSON::Any)
      c.exec("UPDATE fuel_accounts SET progress=$3::jsonb,progress_initialized=true WHERE ns=$1 AND id=$2 AND (NOT progress_initialized OR progress<>$3::jsonb)", @namespace, account, state.to_json)
    end
  end
end
