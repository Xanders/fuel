require "http/client"

module Fuel
  class Questmetry
    @send : Proc(String, Int32)

    def initialize(@store : Store, @events : Hash(String, Array(String)), @environment : String, @version : String, &@send : String -> Int32)
    end

    def self.http(store : Store, events : Hash(String, Array(String)), environment : String, version : String, endpoint : String, write_key : String) : Questmetry
      uri = URI.parse(endpoint)
      Fuel.check(uri.scheme == "https" && !uri.host.nil? && uri.user.nil?, "invalid_endpoint")
      new(store, events, environment, version) do |body|
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

    def capture(credential : Credential, id : String, name : String, session : String, properties : JSON::Any)
      @store.with_actor(credential) { |c, account| enqueue(c, account, id, name, session, properties) }
    end

    # Use inside record_result's effect block for atomic result/event creation.
    def enqueue(c : DB::Connection, account : String, id : String, name : String, session : String, properties : JSON::Any)
      Fuel.key(id)
      allowed = @events[name]?
      Fuel.check(!allowed.nil? && properties.as_h.keys.all? { |k| allowed.not_nil!.includes?(k) }, "invalid_event")
      Fuel.check(properties.to_json.bytesize <= 2048 && properties.as_h.values.all? { |v| v.raw.is_a?(String) || v.raw.is_a?(Bool) || v.raw.is_a?(Int64) }, "invalid_event")
      enabled = c.query_one("SELECT analytics_enabled FROM fuel_accounts WHERE ns=$1 AND id=$2 FOR UPDATE", @store.namespace, account, as: Bool)
      return unless enabled
      c.exec("SELECT pg_advisory_xact_lock(hashtextextended($1,0))", "#{@store.namespace}:outbox")
      count = c.query_one("SELECT count(*) FROM fuel_outbox WHERE ns=$1", @store.namespace, as: Int64)
      Fuel.check(count < 10000, "capacity")
      body = Fuel.json({event_id: id, name: name, schema_version: 1, occurred_at: Time.utc.to_rfc3339,
                        source: "server", environment: @environment, app_version: @version,
                        anonymous_id: @store.digest("analytics", account), session_id: @store.digest("analytics-session", session), properties: properties})
      c.exec("INSERT INTO fuel_outbox(ns,id,account,body) VALUES($1,$2,$3,$4::jsonb) ON CONFLICT DO NOTHING", @store.namespace, id, account, body.to_json)
    end

    def enabled(credential : Credential, value : Bool)
      @store.with_actor(credential) do |c, account|
        c.exec("UPDATE fuel_accounts SET analytics_enabled=$3 WHERE ns=$1 AND id=$2", @store.namespace, account, value)
        c.exec("DELETE FROM fuel_outbox WHERE ns=$1 AND account=$2", @store.namespace, account) unless value
      end
    end

    # A bounded worker; the embedding application chooses its schedule.
    def drain(now = Time.utc)
      10.times do
        sent = @store.db.transaction do |tx|
          c = tx.connection
          row = c.query_one?("SELECT o.id,o.body::text,o.attempts FROM fuel_outbox o JOIN fuel_accounts a ON a.ns=o.ns AND a.id=o.account WHERE o.ns=$1 AND o.due<=$2 AND a.analytics_enabled ORDER BY due LIMIT 1 FOR UPDATE OF o SKIP LOCKED FOR SHARE OF a", @store.namespace, now, as: {String, String, Int32})
          if row
            status = begin
              @send.call({events: [JSON.parse(row[1])]}.to_json)
            rescue
              503
            end
            if status == 202 || (400..499).includes?(status) && status != 429
              c.exec("DELETE FROM fuel_outbox WHERE ns=$1 AND id=$2", @store.namespace, row[0])
            else
              c.exec("UPDATE fuel_outbox SET attempts=attempts+1,due=$3 WHERE ns=$1 AND id=$2", @store.namespace, row[0], now + (2 ** Math.min(row[2] + 1, 10)).seconds)
            end
            true
          else
            false
          end
        end
        break unless sent
      end
    end
  end
end
