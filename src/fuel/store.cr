require "pg"
require "openssl/hmac"
require "crypto/subtle"

module Fuel
  struct Credential
    getter id : String
    getter secret : String

    def initialize(@id, @secret)
      Fuel.check(id.matches?(/\A[0-9a-f]{32}\z/) && secret.matches?(/\A[0-9a-f]{64}\z/), "unauthorized")
    end

    def inspect(io : IO) : Nil
      io << "Fuel::Credential([redacted])"
    end
  end

  # Persistent state is isolated by namespace, not by client-supplied account IDs.
  class Store
    getter db : DB::Database
    getter namespace : String

    def initialize(url : String, @namespace : String, @device_key : String, @pair_key : String, @previous_device_keys = [] of String, @max_accounts = 1000000)
      Fuel.check(url.starts_with?("postgres://") || url.starts_with?("postgresql://"), "postgres_required")
      Fuel.key(namespace)
      Fuel.check(device_key.bytesize >= 32 && pair_key.bytesize >= 32 && device_key != pair_key, "invalid_server_keys")
      @db = DB.open(url)
    end

    def close
      @db.close
    end

    def migrate
      @db.transaction do |tx|
        {{ read_file("#{__DIR__}/../../migrations/001_initial.sql") }}.split(';').each do |statement|
          tx.connection.exec(statement) unless statement.strip.empty?
        end
      end
    end

    def bootstrap(credential : Credential, source : String) : String
      transaction do |c|
        if row = c.query_one?("SELECT verifier FROM fuel_bindings WHERE ns=$1 AND id=$2", @namespace, credential.id, as: String)
          return verify(c, credential)
        end
        limit("bootstrap:global", 1000, 60, c)
        limit("bootstrap:#{source}", 20, 60, c)
        c.exec("SELECT pg_advisory_xact_lock(hashtextextended($1,0))", "#{@namespace}:bootstrap")
        count = c.query_one("SELECT count(*) FROM fuel_accounts WHERE ns=$1", @namespace, as: Int64)
        Fuel.check(count < @max_accounts, "capacity")
        account = Fuel.id
        c.exec("INSERT INTO fuel_accounts(ns,id) VALUES($1,$2)", @namespace, account)
        c.exec("INSERT INTO fuel_bindings(ns,id,account,verifier) VALUES($1,$2,$3,$4)", @namespace, credential.id, account, verifier(credential))
        account
      end
    end

    def authenticate(credential : Credential) : String
      transaction { |c| verify(c, credential) }
    end

    def bindings(credential : Credential) : Array(JSON::Any)
      with_actor(credential) do |c, account|
        result = [] of JSON::Any
        c.query("SELECT id,revoked FROM fuel_bindings WHERE ns=$1 AND account=$2 ORDER BY id", @namespace, account) do |rs|
          rs.each { result << Fuel.json({id: rs.read(String), revoked: rs.read(Bool)}) }
        end
        result
      end
    end

    def revoke(credential : Credential, binding : String)
      with_actor(credential) do |c, account|
        c.exec("UPDATE fuel_bindings SET revoked=true WHERE ns=$1 AND id=$2 AND account=$3", @namespace, binding, account)
      end
    end

    def issue_pair(credential : Credential) : JSON::Any
      with_actor(credential) do |c, account|
        limit("pair:issue:#{account}", 5, 60, c)
        c.exec("UPDATE fuel_pairs SET status='cancelled' WHERE ns=$1 AND account=$2 AND status='pending'", @namespace, account)
        8.times do
          code = Invite.code
          id = Fuel.id
          inserted = c.exec("INSERT INTO fuel_pairs(ns,id,account,code_hash,expires_at) VALUES($1,$2,$3,$4,now()+interval '5 minutes') ON CONFLICT DO NOTHING", @namespace, id, account, code_hash(code))
          if inserted.rows_affected == 1
            break Fuel.json({id: id, code: code, expires_in: 300})
          end
        end || raise Error.new("capacity")
      end
    end

    def request_pair(code : String, candidate : Credential, source : String) : JSON::Any
      limit("pair:global", 200, 60)
      limit("pair:source:#{source}", 10, 60)
      normalized = Invite.normalize(code)
      transaction do |c|
        row = c.query_one?("SELECT id,candidate,phrase FROM fuel_pairs WHERE ns=$1 AND code_hash=$2 AND status='pending' AND expires_at>now() FOR UPDATE", @namespace, code_hash(normalized), as: {String, String?, String?})
        raise Error.new("invalid_code") unless row
        id, prior, phrase = row
        Fuel.check(prior.nil? || prior == candidate.id, "invalid_code")
        c.exec("INSERT INTO fuel_bindings(ns,id,verifier,expires_at) VALUES($1,$2,$3,now()+interval '5 minutes') ON CONFLICT DO NOTHING", @namespace, candidate.id, verifier(candidate))
        binding = c.query_one("SELECT account,verifier,revoked FROM fuel_bindings WHERE ns=$1 AND id=$2 FOR UPDATE", @namespace, candidate.id, as: {String?, String, Bool})
        Fuel.check(binding[0].nil? && !binding[2] && Crypto::Subtle.constant_time_compare(binding[1], verifier(candidate)), "invalid_code")
        phrase ||= Random::Secure.hex(3)
        c.exec("UPDATE fuel_pairs SET candidate=$3,phrase=$4 WHERE ns=$1 AND id=$2", @namespace, id, candidate.id, phrase)
        Fuel.json({id: id, phrase: phrase, status: "pending"})
      end
    end

    def pending_pairs(credential : Credential) : Array(JSON::Any)
      with_actor(credential) do |c, account|
        items = [] of JSON::Any
        c.query("SELECT id,phrase FROM fuel_pairs WHERE ns=$1 AND account=$2 AND status='pending' AND candidate IS NOT NULL AND expires_at>now() LIMIT 10", @namespace, account) do |rs|
          rs.each { items << Fuel.json({id: rs.read(String), phrase: rs.read(String)}) }
        end
        items
      end
    end

    def approve_pair(credential : Credential, id : String) : JSON::Any
      with_actor(credential) do |c, account|
        row = c.query_one?("SELECT candidate,status,expires_at>now() FROM fuel_pairs WHERE ns=$1 AND id=$2 AND account=$3 FOR UPDATE", @namespace, id, account, as: {String?, String, Bool})
        raise Error.new("invalid_code") unless row && row[0]
        return Fuel.json({status: "linked"}) if row[1] == "linked"
        Fuel.check(row[1] == "pending" && row[2], "invalid_code")
        updated = c.exec("UPDATE fuel_bindings SET account=$3,expires_at=NULL WHERE ns=$1 AND id=$2 AND account IS NULL AND NOT revoked AND expires_at>now()", @namespace, row[0], account)
        Fuel.check(updated.rows_affected == 1, "invalid_code")
        c.exec("UPDATE fuel_pairs SET status='linked' WHERE ns=$1 AND id=$2", @namespace, id)
        Fuel.json({status: "linked"})
      end
    end

    def cancel_pair(credential : Credential, id : String)
      with_actor(credential) do |c, account|
        c.exec("UPDATE fuel_pairs SET status='cancelled' WHERE ns=$1 AND id=$2 AND account=$3 AND status='pending'", @namespace, id, account)
      end
    end

    def pair_status(candidate : Credential) : JSON::Any
      transaction do |c|
        binding = c.query_one?("SELECT verifier,account,revoked FROM fuel_bindings WHERE ns=$1 AND id=$2", @namespace, candidate.id, as: {String, String?, Bool})
        Fuel.check(!binding.nil?, "unauthorized")
        b = binding.not_nil!
        Fuel.check(!b[2] && Crypto::Subtle.constant_time_compare(b[0], verifier(candidate)), "unauthorized")
        return Fuel.json({status: "linked", account_id: b[1]}) if b[1]
        row = c.query_one?("SELECT id,phrase,status,expires_at>now() FROM fuel_pairs WHERE ns=$1 AND candidate=$2 ORDER BY expires_at DESC LIMIT 1", @namespace, candidate.id, as: {String, String?, String, Bool})
        raise Error.new("invalid_code") unless row
        Fuel.json({id: row[0], phrase: row[1], status: row[3] ? row[2] : "expired"})
      end
    end

    def progress(credential : Credential) : JSON::Any
      with_actor(credential) do |c, account|
        JSON.parse(c.query_one("SELECT progress::text FROM fuel_accounts WHERE ns=$1 AND id=$2", @namespace, account, as: String))
      end
    end

    # Trusted game code calls this after authoritative validation; no public score submission route.
    def record_result(credential : Credential, id : String, board : String, score : Int64, name : String, progress : JSON::Any, outcome : String? = nil) : JSON::Any
      record_result(credential, id, board, score, name, progress, outcome) { |_, _| }
    end

    def record_result(credential : Credential, id : String, board : String, score : Int64, name : String, progress : JSON::Any, outcome : String? = nil, &effect : DB::Connection, String ->) : JSON::Any
      Fuel.key(id)
      Fuel.key(board)
      Fuel.check(score >= 0 && (1..80).includes?(name.size) && progress.to_json.bytesize <= 65536, "invalid_result")
      Fuel.check(outcome.nil? || ["win", "loss", "draw"].includes?(outcome), "invalid_result")
      fingerprint = Digest::SHA256.hexdigest({board, score, name, progress, outcome}.to_json)
      with_actor(credential) do |c, account|
        c.query_one("SELECT id FROM fuel_accounts WHERE ns=$1 AND id=$2 FOR UPDATE", @namespace, account, as: String)
        if prior = c.query_one?("SELECT fingerprint,reply::text FROM fuel_results WHERE ns=$1 AND account=$2 AND id=$3", @namespace, account, id, as: {String, String})
          Fuel.check(prior[0] == fingerprint, "conflict")
          return JSON.parse(prior[1])
        end
        reply = Fuel.json({status: "committed", result_id: id})
        c.exec("INSERT INTO fuel_results(ns,account,id,fingerprint,reply,board,name,outcome) VALUES($1,$2,$3,$4,$5::jsonb,$6,$7,$8)", @namespace, account, id, fingerprint, reply.to_json, board, name, outcome)
        c.exec("UPDATE fuel_accounts SET progress=$3::jsonb WHERE ns=$1 AND id=$2", @namespace, account, progress.to_json)
        c.exec(<<-SQL, @namespace, board, account, score, name)
          INSERT INTO fuel_scores(ns,board,account,score,name) VALUES($1,$2,$3,$4,$5)
          ON CONFLICT(ns,board,account) DO UPDATE SET score=excluded.score,name=excluded.name,achieved_at=now()
          WHERE excluded.score>fuel_scores.score
          SQL
        yield c, account
        reply
      end
    end

    def leaderboard(board : String, limit = 100) : Array(JSON::Any)
      Fuel.key(board)
      Fuel.check((1..100).includes?(limit), "invalid_limit")
      result = [] of JSON::Any
      @db.query("SELECT account,name,score FROM fuel_scores WHERE ns=$1 AND board=$2 ORDER BY score DESC,achieved_at,account LIMIT $3", @namespace, board, limit) do |rs|
        rs.each { result << Fuel.json({account_id: rs.read(String), name: rs.read(String), score: rs.read(Int64).to_s, rank: (result.size + 1).to_s}) }
      end
      result
    end

    def ratings(board : String, metric = "wins", hours = 24) : Array(JSON::Any)
      Fuel.key(board)
      Fuel.check(["wins", "battles", "win_ratio"].includes?(metric) && (1..8760).includes?(hours), "invalid_board")
      order = {"wins" => "wins DESC,battles DESC", "battles" => "battles DESC,wins DESC", "win_ratio" => "ratio DESC,wins DESC"}[metric]
      result = [] of JSON::Any
      @db.query(<<-SQL, @namespace, board, hours) do |rs|
        SELECT account,(array_agg(name ORDER BY completed_at DESC))[1],
        count(*) FILTER(WHERE outcome='win') wins,count(*) FILTER(WHERE outcome='loss') losses,
        count(*) FILTER(WHERE outcome='draw') draws,count(*) battles,
        COALESCE(count(*) FILTER(WHERE outcome='win')::float8/NULLIF(count(*) FILTER(WHERE outcome IN ('win','loss')),0),0::float8) ratio
        FROM fuel_results WHERE ns=$1 AND board=$2 AND outcome IS NOT NULL
        AND completed_at>=now()-make_interval(hours=>$3) GROUP BY account ORDER BY #{order},account LIMIT 100
        SQL
        rs.each { result << Fuel.json({account_id: rs.read(String), name: rs.read(String), wins: rs.read(Int64).to_s, losses: rs.read(Int64).to_s, draws: rs.read(Int64).to_s, battles: rs.read(Int64).to_s, win_ratio: rs.read(Float64)}) }
      end
      result
    end

    def delete_account(credential : Credential, confirmed : Bool, &purge : DB::Connection, String ->)
      Fuel.check(confirmed, "confirmation_required")
      with_actor(credential) do |c, account|
        yield c, account
        c.exec("DELETE FROM fuel_chat WHERE ns=$1 AND (actor=$2 OR recipient=$2)", @namespace, account)
        c.exec("DELETE FROM fuel_accounts WHERE ns=$1 AND id=$2", @namespace, account)
      end
    end

    def delete_account(credential : Credential, confirmed : Bool)
      delete_account(credential, confirmed) { |_, _| }
    end

    def limit(key : String, maximum : Int32, seconds : Int32, c : DB::Connection? = nil)
      if connection = c
        bucket = Time.utc.to_unix // seconds
        count = connection.query_one(<<-SQL, @namespace, digest("limit", key), bucket, seconds, as: Int32)
          INSERT INTO fuel_limits(ns,key,bucket,count,expires_at) VALUES($1,$2,$3,1,now()+make_interval(secs=>$4))
          ON CONFLICT(ns,key) DO UPDATE SET bucket=excluded.bucket,
          count=CASE WHEN fuel_limits.bucket=excluded.bucket THEN fuel_limits.count+1 ELSE 1 END,expires_at=excluded.expires_at RETURNING count
          SQL
        Fuel.check(count <= maximum, "rate_limited")
      else
        @db.using_connection { |conn| limit(key, maximum, seconds, conn) }
      end
    end

    def cleanup
      @db.exec("DELETE FROM fuel_limits WHERE ns=$1 AND expires_at<now()", @namespace)
      @db.exec("DELETE FROM fuel_pairs WHERE ns=$1 AND expires_at<now()-interval '1 day'", @namespace)
      @db.exec("DELETE FROM fuel_bindings WHERE ns=$1 AND account IS NULL AND expires_at<now()", @namespace)
      @db.exec("DELETE FROM fuel_chat WHERE ns=$1 AND expires_at<now()", @namespace)
    end

    def save_chat(channel : String, actor : String, recipient : String, entry : JSON::Any, limit : Int32, ttl : Time::Span)
      transaction do |c|
        c.exec("SELECT pg_advisory_xact_lock(hashtextextended($1,0))", "#{@namespace}:chat:#{channel}")
        c.exec("INSERT INTO fuel_chat(ns,id,channel,actor,recipient,body,expires_at) VALUES($1,$2,$3,$4,$5,$6::jsonb,now()+make_interval(secs=>$7))", @namespace, entry["id"].as_s, channel, actor, recipient, entry.to_json, ttl.total_seconds.to_i)
        c.exec("DELETE FROM fuel_chat WHERE ns=$1 AND channel=$2 AND id NOT IN (SELECT id FROM fuel_chat WHERE ns=$1 AND channel=$2 ORDER BY created_at DESC,id DESC LIMIT $3)", @namespace, channel, limit)
      end
    end

    def read_chat(channel : String, limit : Int32, ttl : Time::Span) : Array(JSON::Any)
      entries = [] of JSON::Any
      @db.query("SELECT body::text FROM fuel_chat WHERE ns=$1 AND channel=$2 AND expires_at>now() AND created_at>now()-make_interval(secs=>$4) ORDER BY created_at DESC,id DESC LIMIT $3", @namespace, channel, limit, ttl.total_seconds.to_i) do |rs|
        rs.each { entries << JSON.parse(rs.read(String)) }
      end
      entries.reverse
    end

    def with_actor(credential : Credential, &)
      transaction do |c|
        account = verify(c, credential)
        yield c, account
      end
    end

    private def transaction(&block : DB::Connection -> T) : T forall T
      @db.transaction { |tx| yield tx.connection }.as(T)
    end

    private def verify(c : DB::Connection, credential : Credential) : String
      row = c.query_one?("SELECT b.account,b.verifier FROM fuel_bindings b JOIN fuel_accounts a ON a.ns=b.ns AND a.id=b.account WHERE b.ns=$1 AND b.id=$2 AND NOT b.revoked FOR UPDATE OF a,b", @namespace, credential.id, as: {String, String})
      raise Error.new("unauthorized") unless row
      valid = ([@device_key] + @previous_device_keys).any? { |key| Crypto::Subtle.constant_time_compare(row[1], device_verifier(credential, key)) }
      raise Error.new("unauthorized") unless valid
      if row[1] != verifier(credential)
        c.exec("UPDATE fuel_bindings SET verifier=$3 WHERE ns=$1 AND id=$2", @namespace, credential.id, verifier(credential))
      end
      row[0]
    end

    private def verifier(credential : Credential) : String
      device_verifier(credential, @device_key)
    end

    private def device_verifier(credential : Credential, key : String) : String
      OpenSSL::HMAC.hexdigest(:sha256, key, {"fuel-v1", @namespace, "device", {credential.id, credential.secret}.to_json}.to_json)
    end

    private def code_hash(code : String) : String
      digest("pair", code)
    end

    def digest(purpose : String, value : String) : String
      OpenSSL::HMAC.hexdigest(:sha256, purpose == "pair" ? @pair_key : @device_key, {"fuel-v1", @namespace, purpose, value}.to_json)
    end
  end
end
