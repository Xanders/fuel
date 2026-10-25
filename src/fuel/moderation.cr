module Fuel
  class Store
    def public_progress(account : String) : JSON::Any?
      row = @db.query_one?("SELECT progress::text FROM fuel_accounts WHERE ns=$1 AND id=$2", @namespace, account, as: String)
      row.try { |text| JSON.parse(text) }
    end

    def muted_ids(account : String) : Array(String)
      result = [] of String
      @db.query("SELECT target FROM fuel_mutes WHERE ns=$1 AND account=$2", @namespace, account) { |rs| rs.each { result << rs.read(String) } }
      result
    end

    def muted(credential : Credential) : Array(JSON::Any)
      with_actor(credential) do |c, account|
        result = [] of JSON::Any
        c.query("SELECT a.id,a.progress::text FROM fuel_mutes m JOIN fuel_accounts a ON a.ns=m.ns AND a.id=m.target WHERE m.ns=$1 AND m.account=$2 ORDER BY a.id", @namespace, account) do |rs|
          rs.each { result << Fuel.json({id: rs.read(String), progress: JSON.parse(rs.read(String))}) }
        end
        result
      end
    end

    def set_muted(credential : Credential, target : String, value : Bool)
      with_accounts(credential, [target], nil) do |c, actor, profiles|
        Fuel.check(actor != target && profiles.has_key?(target), "invalid_recipient")
        if value
          unless c.query_one?("SELECT target FROM fuel_mutes WHERE ns=$1 AND account=$2 AND target=$3", @namespace, actor, target, as: String)
            count = c.query_one("SELECT count(*) FROM fuel_mutes WHERE ns=$1 AND account=$2", @namespace, actor, as: Int64)
            Fuel.check(count < 200, "capacity")
            c.exec("INSERT INTO fuel_mutes(ns,account,target) VALUES($1,$2,$3)", @namespace, actor, target)
          end
        else
          c.exec("DELETE FROM fuel_mutes WHERE ns=$1 AND account=$2 AND target=$3", @namespace, actor, target)
        end
      end
    end

    def chat_message(channel : String, id : String) : JSON::Any?
      text = @db.query_one?("SELECT body::text FROM fuel_chat WHERE ns=$1 AND channel=$2 AND id=$3 AND expires_at>now()", @namespace, channel, id, as: String)
      text.try { |value| JSON.parse(value) }
    end

    def record_report(c : DB::Connection, actor : String, channel : String, message : JSON::Any, reason : String)
      id = message["id"].as_s
      return if c.query_one?("SELECT id FROM fuel_reports WHERE ns=$1 AND reporter=$2 AND message_id=$3", @namespace, actor, id, as: String)
      limit("reports:#{actor}", 12, 86400, c)
      c.exec("SELECT pg_advisory_xact_lock(hashtextextended($1,0))", "#{@namespace}:reports")
      count = c.query_one("SELECT count(*) FROM fuel_reports WHERE ns=$1", @namespace, as: Int64)
      Fuel.check(count < 100000, "capacity")
      c.exec("INSERT INTO fuel_reports(ns,id,reporter,target,message_id,channel,message_text,reason) VALUES($1,$2,$3,$4,$5,$6,$7,$8)", @namespace, Fuel.id, actor, message["actor"].as_s, id, channel, message["text"].as_s, reason)
    end
  end
end
