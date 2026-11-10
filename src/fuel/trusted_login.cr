module Fuel
  class Store
    # Trusted server-only entrypoints. Issuer/subject authorization belongs to the
    # embedding application; none is exposed by the anonymous canonical Handler.
    def enroll_account(request_id : String) : String
      Fuel.key(request_id)
      transaction do |c|
        c.exec("SELECT pg_advisory_xact_lock(hashtextextended($1,0))", "#{@namespace}:bootstrap")
        if prior = c.query_one?("SELECT account,account IS NULL FROM fuel_enrollments WHERE ns=$1 AND request_id=$2", @namespace, request_id, as: {String?, Bool})
          Fuel.check(!prior[1], "deleted")
          next prior[0].not_nil!
        end
        limit("enroll:global", 1000, 60, c)
        count = c.query_one("SELECT count(*) FROM fuel_accounts WHERE ns=$1", @namespace, as: Int64)
        Fuel.check(count < @max_accounts, "capacity")
        account = Fuel.id
        c.exec("INSERT INTO fuel_accounts(ns,id) VALUES($1,$2)", @namespace, account)
        c.exec("INSERT INTO fuel_enrollments(ns,request_id,account) VALUES($1,$2,$3)", @namespace, request_id, account)
        account
      end
    end

    def issue_login(account : String, request_id : String) : JSON::Any
      Fuel.key(account)
      Fuel.key(request_id)
      transaction do |c|
        Fuel.check(!c.query_one?("SELECT id FROM fuel_accounts WHERE ns=$1 AND id=$2 FOR UPDATE", @namespace, account, as: String).nil?, "not_found")
        code = login_digest("code", {account, request_id}.to_json)[0, 16].upcase
        if prior = c.query_one?("SELECT account,extract(epoch from expires_at)::bigint FROM fuel_login_grants WHERE ns=$1 AND id=$2", @namespace, request_id, as: {String, Int64})
          Fuel.check(prior[0] == account, "conflict")
          next Fuel.json({id: request_id, code: code, expires_at: prior[1]})
        end
        limit("login:issue:#{account}", 5, 60, c)
        c.exec("UPDATE fuel_login_grants SET cancelled=true WHERE ns=$1 AND account=$2 AND candidate IS NULL", @namespace, account)
        expires = c.query_one("INSERT INTO fuel_login_grants(ns,id,account,code_hash,expires_at) VALUES($1,$2,$3,$4,now()+interval '5 minutes') RETURNING extract(epoch from expires_at)::bigint", @namespace, request_id, account, login_digest("verifier", code), as: Int64)
        Fuel.json({id: request_id, code: code, expires_at: expires})
      end
    end

    def redeem_login(code : String, candidate : Credential, source : String, step_up : JSON::Any? = nil) : String
      # Admission commits independently: invalid proofs cannot roll back budgets.
      limit("login:global", 200, 60)
      limit("login:source:#{source}", 10, 60)
      normalized = code.gsub('-', "").upcase
      Fuel.check(normalized.matches?(/\A[0-9A-F]{16}\z/), "invalid_code")
      proof = step_up.try(&.to_json)
      Fuel.check(step_up.nil? || step_up.raw.is_a?(Hash) && proof.not_nil!.bytesize <= 2048, "invalid_proof")
      hash = login_digest("verifier", normalized)
      lookup = @db.query_one?("SELECT account,candidate IS NULL AND NOT cancelled AND expires_at>clock_timestamp() FROM fuel_login_grants WHERE ns=$1 AND code_hash=$2", @namespace, hash, as: {String, Bool})
      raise Error.new("invalid_code") unless lookup
      account = lookup[0]
      # Commit outside activation: policy denial must not refund account attempts.
      limit("login:account:#{account}", 10, 60) if @login_authorizer && lookup[1]
      transaction do |c|
        # Same order as ordinary binding operations and issuer reissuance.
        Fuel.check(!c.query_one?("SELECT id FROM fuel_accounts WHERE ns=$1 AND id=$2 FOR UPDATE", @namespace, account, as: String).nil?, "invalid_code")
        grant = c.query_one?("SELECT candidate,cancelled,expires_at>now() FROM fuel_login_grants WHERE ns=$1 AND code_hash=$2 FOR UPDATE", @namespace, hash, as: {String?, Bool, Bool})
        raise Error.new("invalid_code") unless grant && !grant[1]
        if bound = grant[0]
          Fuel.check(bound == candidate.id, "invalid_code")
          begin
            Fuel.check(verify(c, candidate) == account, "invalid_code")
          rescue error : Error
            raise Error.new("invalid_code") if error.code == "unauthorized"
            raise error
          end
          next account
        end
        Fuel.check(grant[2], "invalid_code")
        Fuel.check(c.query_one?("SELECT id FROM fuel_retired_bindings WHERE ns=$1 AND id=$2", @namespace, candidate.id, as: String).nil?, "invalid_code")
        @login_authorizer.try(&.call(c, account, proof.try { |text| JSON.parse(text) }))
        inserted = c.exec("INSERT INTO fuel_bindings(ns,id,account,verifier) VALUES($1,$2,$3,$4) ON CONFLICT DO NOTHING", @namespace, candidate.id, account, verifier(candidate))
        Fuel.check(inserted.rows_affected == 1, "invalid_code")
        # An insert may wait for deletion of the old binding. Recheck after that
        # wait so a newly committed tombstone cannot be bypassed.
        Fuel.check(c.query_one?("SELECT id FROM fuel_retired_bindings WHERE ns=$1 AND id=$2", @namespace, candidate.id, as: String).nil?, "invalid_code")
        Fuel.check(c.query_one("SELECT expires_at>clock_timestamp() FROM fuel_login_grants WHERE ns=$1 AND code_hash=$2", @namespace, hash, as: Bool), "invalid_code")
        c.exec("UPDATE fuel_login_grants SET candidate=$3 WHERE ns=$1 AND code_hash=$2", @namespace, hash, candidate.id)
        account
      end
    end

    private def login_digest(kind : String, value : String) : String
      OpenSSL::HMAC.hexdigest(:sha256, @pair_key, {"fuel-login-v1", @namespace, kind, value}.to_json)
    end
  end
end
