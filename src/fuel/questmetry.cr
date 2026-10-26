require "http/client"

module Fuel
  class Questmetry
    @send : Proc(String, Int32)
    @client_events : Set(String)
    getter omitted = 0_i64

    def initialize(@store : Store, @events : Hash(String, Array(String)), @environment : String, @version : String,
                   @pseudonym_key : String? = nil, @max_pending = 10000,
                   @validate : Proc(String, JSON::Any, Bool) = ->(name : String, properties : JSON::Any) { true },
                   @context : JSON::Any = JSON.parse("{}"), @playtest : String? = nil,
                   client_events : Array(String) = [] of String, &@send : String -> Int32)
      Fuel.key(@environment)
      Fuel.check(@version.matches?(/\A[a-zA-Z0-9.+_-]{1,80}\z/) && @max_pending > 0, "invalid_analytics_config")
      Fuel.check(@pseudonym_key.nil? || @pseudonym_key.not_nil!.bytesize >= 32, "invalid_server_keys")
      Fuel.check(@context.to_json.bytesize <= 2048 && @context.raw.is_a?(Hash), "invalid_analytics_config")
      Fuel.check(@playtest.nil? || @playtest.not_nil!.matches?(/\A[a-zA-Z0-9_-]{1,80}\z/), "invalid_analytics_config")
      Fuel.check(client_events.all? { |name| @events.has_key?(name) }, "invalid_analytics_config")
      @client_events = client_events.to_set
    end

    def self.http(store : Store, events : Hash(String, Array(String)), environment : String, version : String, endpoint : String, write_key : String,
                  pseudonym_key : String? = nil, validate : Proc(String, JSON::Any, Bool) = ->(name : String, properties : JSON::Any) { true },
                  context : JSON::Any = JSON.parse("{}"), playtest : String? = nil,
                  client_events : Array(String) = [] of String) : Questmetry
      uri = URI.parse(endpoint)
      Fuel.check(uri.scheme == "https" && !uri.host.nil? && uri.user.nil? && uri.password.nil? && uri.path.in?("", "/") && uri.query.nil? && uri.fragment.nil?, "invalid_endpoint")
      Fuel.check(write_key.starts_with?("qm_") && write_key.size > 3 && write_key.each_char.none?(&.control?), "invalid_analytics_config")
      new(store, events, environment, version, pseudonym_key: pseudonym_key, validate: validate, context: context, playtest: playtest, client_events: client_events) do |body|
        client = HTTP::Client.new(uri)
        client.connect_timeout = 3.seconds
        client.read_timeout = 3.seconds
        client.write_timeout = 3.seconds
        begin
          client.post("/v1/events/batch", HTTP::Headers{"Authorization" => "Bearer #{write_key}", "Content-Type" => "application/json"}, body).status_code
        ensure
          client.close
        end
      end
    end

    def capture(credential : Credential, id : String, name : String, session : String, properties : JSON::Any, occurred_at : Time = Time.utc, revision : Int64? = nil) : String
      @store.with_actor(credential) { |c, account| enqueue(c, account, id, name, session, properties, occurred_at, revision) }
    end

    def capture_client(credential : Credential, id : String, name : String, session : String, properties : JSON::Any, revision : Int64) : String
      Fuel.check(@client_events.includes?(name) && revision >= 0, "invalid_event")
      @store.with_actor(credential) { |c, account| enqueue(c, account, id, name, session, properties, revision: revision, source: "client") }
    end

    # Use inside record_result's effect block for atomic result/event creation.
    def enqueue(c : DB::Connection, account : String, id : String, name : String, session : String, properties : JSON::Any, occurred_at : Time = Time.utc, revision : Int64? = nil, source : String = "server") : String
      Fuel.key(id)
      Fuel.key(name)
      Fuel.check(session.bytesize <= 200, "invalid_event")
      Fuel.check(source.in?("server", "client"), "invalid_event")
      allowed = @events[name]?
      Fuel.check(!allowed.nil? && properties.as_h.keys.all? { |k| allowed.not_nil!.includes?(k) }, "invalid_event")
      Fuel.check(properties.to_json.bytesize <= 2048 && properties.as_h.values.all? { |v| v.raw.is_a?(String) || v.raw.is_a?(Bool) || v.raw.is_a?(Int64) }, "invalid_event")
      Fuel.check(@validate.call(name, properties), "invalid_event")
      enabled, current = c.query_one("SELECT analytics_enabled,analytics_revision FROM fuel_accounts WHERE ns=$1 AND id=$2 FOR UPDATE", @store.namespace, account, as: {Bool, Int64})
      return "stale" if revision && revision != current
      return "disabled" unless enabled
      c.exec("SELECT pg_advisory_xact_lock(hashtextextended($1,0))", "#{@store.namespace}:outbox")
      return "duplicate" if c.query_one?("SELECT id FROM fuel_outbox WHERE ns=$1 AND id=$2", @store.namespace, id, as: String)
      count = c.query_one("SELECT count(*) FROM fuel_outbox WHERE ns=$1", @store.namespace, as: Int64)
      if count >= @max_pending
        @omitted += 1
        STDERR.puts "Fuel analytics capacity reached; new events omitted" if @omitted == 1
        return "capacity"
      end
      body = Fuel.json({event_id: id, name: name, schema_version: 1, occurred_at: occurred_at.to_rfc3339,
                        source: source, environment: @environment, app_version: @version,
                        anonymous_id: pseudonym("account", account), session_id: pseudonym("session", {account, session}.to_json), properties: properties, context: @context})
      body.as_h["playtest_id"] = JSON::Any.new(@playtest.not_nil!) if @playtest
      body.as_h.delete("session_id") if session.empty?
      c.exec("INSERT INTO fuel_outbox(ns,id,account,body,revision) VALUES($1,$2,$3,$4::jsonb,$5) ON CONFLICT DO NOTHING", @store.namespace, id, account, body.to_json, current)
      "queued"
    end

    def preference(credential : Credential) : Int64
      @store.with_actor(credential) { |c, account| c.query_one("SELECT analytics_revision FROM fuel_accounts WHERE ns=$1 AND id=$2", @store.namespace, account, as: Int64) }
    end

    def enabled(credential : Credential, value : Bool) : Int64
      @store.with_analytics_delivery do
        @store.with_actor(credential) do |c, account|
          c.exec("UPDATE fuel_accounts SET analytics_enabled=$3,analytics_revision=analytics_revision+1 WHERE ns=$1 AND id=$2 AND analytics_enabled<>$3", @store.namespace, account, value)
          c.exec("DELETE FROM fuel_outbox WHERE ns=$1 AND account=$2", @store.namespace, account) unless value
          c.query_one("SELECT analytics_revision FROM fuel_accounts WHERE ns=$1 AND id=$2", @store.namespace, account, as: Int64)
        end
      end
    end

    def halted : Int64
      @store.db.query_one("SELECT count(*) FROM fuel_outbox WHERE ns=$1 AND halted AND created_at>=now()-interval '7 days'", @store.namespace, as: Int64)
    end

    def resume(now = Time.utc) : Int64
      @store.with_analytics_delivery do
        @store.db.exec("UPDATE fuel_outbox o SET halted=false,attempts=0,due=$2 FROM fuel_accounts a WHERE o.ns=$1 AND a.ns=o.ns AND a.id=o.account AND a.analytics_enabled AND a.analytics_revision=o.revision AND o.halted AND o.created_at>=$2::timestamptz-interval '7 days'", @store.namespace, now).rows_affected
      end
    end

    private def pseudonym(kind : String, value : String) : String
      if key = @pseudonym_key
        OpenSSL::HMAC.hexdigest(:sha256, key, {"fuel-analytics-v1", @store.namespace, kind, value}.to_json)
      else
        @store.digest("analytics-#{kind}", value)
      end
    end

    # The shared delivery gate fences opt-out/deletion, without holding a
    # gameplay account lock or a database transaction during external IO.
    def drain(now = Time.utc)
      @store.with_analytics_delivery do
        @store.db.exec("DELETE FROM fuel_outbox WHERE ns=$1 AND created_at<$2::timestamptz-interval '7 days'", @store.namespace, now)
        rows = [] of Tuple(String, String, Int32)
        @store.db.query("SELECT o.id,o.body::text,o.attempts FROM fuel_outbox o JOIN fuel_accounts a ON a.ns=o.ns AND a.id=o.account WHERE o.ns=$1 AND NOT o.halted AND o.due<=$2 AND a.analytics_enabled AND a.analytics_revision=o.revision ORDER BY o.due,o.id LIMIT 25", @store.namespace, now) { |rs| rs.each { rows << rs.read(String, String, Int32) } }
        return if rows.empty?
        status = begin
          @send.call({events: rows.map { |row| JSON.parse(row[1]) }}.to_json)
        rescue
          503
        end
        configuration_error = status != 202 && status != 429 && status < 500 && status > 0
        @store.db.transaction do |tx|
          c = tx.connection
          rows.each do |id, _, attempts|
            if status == 202
              c.exec("DELETE FROM fuel_outbox WHERE ns=$1 AND id=$2", @store.namespace, id)
            else
              halted = configuration_error || attempts >= 11
              delay = {2 ** (attempts + 1).clamp(1, 9), 300}.min + Random.rand(0..30)
              c.exec("UPDATE fuel_outbox SET attempts=attempts+1,due=$3,halted=$4 WHERE ns=$1 AND id=$2", @store.namespace, id, now + delay.seconds, halted)
            end
          end
        end
        STDERR.puts "Fuel analytics delivery halted; verify configuration" if configuration_error
      end
    end
  end
end
