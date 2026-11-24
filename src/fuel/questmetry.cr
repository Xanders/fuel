require "http/client"

module Fuel
  class Questmetry
    record Submission, account : String, id : String, name : String, session : String, properties : JSON::Any, occurred_at : Time, revision : Int64?
    @send : Proc(String, Int32)
    @client_events : Set(String)
    @admissions = [] of Submission
    @pending = [] of Tuple(String, String)
    @ids = Set(String).new
    @used = 0
    @omitted = 0_i64
    @admitting = false
    @draining = false
    @mutex = Mutex.new

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
      @events = @events.transform_values(&.dup)
      @context = JSON.parse(@context.to_json)
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
      validate(id, name, session, properties)
      @store.with_actor(credential) { |c, account| admit(c, account, id, name, session, properties, occurred_at, revision) }
    end

    def capture_client(credential : Credential, id : String, name : String, session : String, properties : JSON::Any, revision : Int64) : String
      Fuel.key(id)
      Fuel.check(@client_events.includes?(name) && revision >= 0, "invalid_event")
      validate(id, name, session, properties)
      @store.with_actor(credential) do |c, account|
        client_id = @store.digest("analytics-client-id", {account, id}.to_json)
        admit(c, account, client_id, name, session, properties, Time.utc, revision, "client")
      end
    end

    # Call after business commit; one bounded background worker admits server facts.
    def emit(account : String, id : String, name : String, session : String, properties : JSON::Any, occurred_at : Time = Time.utc, revision : Int64? = nil) : Nil
      return if revision.nil? || revision < 0
      Fuel.key(account)
      Fuel.key(id)
      Fuel.key(name)
      return if session.bytesize > 200 || properties.to_json.bytesize > 2048
      submission = Submission.new(account, id, name, session, JSON.parse(properties.to_json), occurred_at, revision)
      start = @mutex.synchronize do
        return unless reserve
        @admissions << submission
        if @admitting
          false
        else
          @admitting = true
          true
        end
      end
      spawn admit_pending if start
    rescue
      # Telemetry never changes a committed business result.
    end

    private def validate(id : String, name : String, session : String, properties : JSON::Any)
      Fuel.key(id)
      Fuel.key(name)
      Fuel.check(session.bytesize <= 200, "invalid_event")
      allowed = @events[name]?
      Fuel.check(!allowed.nil? && properties.as_h.keys.all? { |k| allowed.not_nil!.includes?(k) }, "invalid_event")
      Fuel.check(properties.to_json.bytesize <= 2048 && properties.as_h.values.all? { |v| v.raw.is_a?(String) || v.raw.is_a?(Bool) || v.raw.is_a?(Int64) }, "invalid_event")
      Fuel.check(@validate.call(name, properties), "invalid_event")
    end

    private def admit_pending
      loop do
        submission = @mutex.synchronize do
          if @admissions.empty?
            @admitting = false
            return
          end
          @admissions.shift
        end
        accepted = false
        begin
          unless @store.closed?
            validate(submission.id, submission.name, submission.session, submission.properties)
            @store.with_analytics_admission do |connection|
              accepted = admit(connection, submission.account, submission.id, submission.name, submission.session,
                submission.properties, submission.occurred_at, submission.revision, reserved: true) == "queued"
            end
          end
        rescue
          # Failed admission is dropped; no durable journal or replay exists.
        ensure
          @mutex.synchronize { @used -= 1 } unless accepted
        end
      end
    end

    private def admit(c : DB::Connection, account : String, id : String, name : String, session : String, properties : JSON::Any, occurred_at : Time,
                      revision : Int64?, source : String = "server", reserved = false) : String
      preference = c.query_one?("SELECT analytics_enabled,analytics_revision FROM fuel_accounts WHERE ns=$1 AND id=$2 FOR UPDATE", @store.namespace, account, as: {Bool, Int64})
      return "disabled" unless preference
      enabled, current = preference
      return "stale" if revision && revision != current
      return "disabled" unless enabled
      body = Fuel.json({event_id: id, name: name, schema_version: 1, occurred_at: occurred_at.to_rfc3339,
                        source: source, environment: @environment, app_version: @version,
                        anonymous_id: pseudonym("account", account), session_id: pseudonym("session", {account, session}.to_json), properties: properties, context: @context})
      body.as_h["playtest_id"] = JSON::Any.new(@playtest.not_nil!) if @playtest
      body.as_h.delete("session_id") if session.empty?
      encoded = body.to_json
      @mutex.synchronize do
        return "duplicate" if @ids.includes?(id)
        return "capacity" unless reserved || reserve
        @ids.add(id)
        @pending << {id, encoded}
        "queued"
      end
    end

    # Includes queued admission, accepted events and the in-flight batch.
    private def reserve : Bool
      if @used >= @max_pending
        @omitted += 1
        false
      else
        @used += 1
        true
      end
    end

    def omitted : Int64
      @mutex.synchronize { @omitted }
    end

    def pending : Int32
      @mutex.synchronize { @used }
    end

    def preference(credential : Credential) : Int64
      @store.with_actor(credential) { |c, account| c.query_one("SELECT analytics_revision FROM fuel_accounts WHERE ns=$1 AND id=$2", @store.namespace, account, as: Int64) }
    end

    def enabled(credential : Credential, value : Bool) : Int64
      @store.analytics_enabled(credential, value)
    end

    # Compatibility only: single-attempt delivery has no halted/recoverable tail.
    def halted : Int64
      0_i64
    end

    def resume(now = Time.utc) : Int64
      0_i64
    end

    private def pseudonym(kind : String, value : String) : String
      if key = @pseudonym_key
        OpenSSL::HMAC.hexdigest(:sha256, key, {"fuel-analytics-v1", @store.namespace, kind, value}.to_json)
      else
        @store.digest("analytics-#{kind}", value)
      end
    end

    # One best-effort batch. No account lookup, opt-out fence or retry on delivery.
    def drain(now = Time.utc)
      rows = @mutex.synchronize do
        return if @draining
        @draining = true
        @pending.shift({@pending.size, 25}.min)
      end
      begin
        @send.call({events: rows.map { |_, body| JSON.parse(body) }}.to_json) unless rows.empty?
      rescue
        # Network/configuration failures discard this batch.
      ensure
        @mutex.synchronize do
          rows.each { |id, _| @ids.delete(id) }
          @used -= rows.size
          @draining = false
        end
      end
    end
  end
end
