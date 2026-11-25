module Fuel
  class Store
    def deletion_status(proof : String, expected_account : String) : JSON::Any
      validate_deletion(proof, expected_account)
      row = @db.query_one?("SELECT result::text FROM fuel_deletions WHERE ns=$1 AND proof=$2 AND account_digest=$3 AND expires_at>now()",
        @namespace, deletion_digest("proof", proof), deletion_digest("account", expected_account), as: String)
      row ? JSON.parse(row) : Fuel.json({status: "unknown"})
    end

    def delete_account(credential : Credential, confirmed : Bool, proof : String, expected_account : String, *, abandon : Credential? = nil) : JSON::Any
      delete_account(credential, confirmed, proof, expected_account, abandon: abandon) { |_, _| }
    end

    def delete_account(credential : Credential, confirmed : Bool, proof : String, expected_account : String, *, abandon : Credential? = nil, &purge : DB::Connection, String ->) : JSON::Any
      Fuel.check(confirmed, "confirmation_required")
      validate_deletion(proof, expected_account)
      with_actor(credential) do |c, actor|
        Fuel.check(credential.id != abandon.try(&.id), "transfer_completed")
        Fuel.check(actor == expected_account, "conflict")
        key = deletion_digest("proof", proof)
        Fuel.check(c.query_one?("SELECT proof FROM fuel_deletions WHERE ns=$1 AND proof=$2", @namespace, key, as: String).nil?, "conflict")
        bindings = [] of String
        c.query("SELECT id FROM fuel_bindings WHERE ns=$1 AND account=$2 ORDER BY id", @namespace, actor) { |rs| rs.each { bindings << rs.read(String) } }
        if abandon
          retire_unlinked_pair(c, abandon)
          bindings << abandon.id unless bindings.includes?(abandon.id)
        end
        result = Fuel.json({status: "deleted", removed_bindings: bindings})
        c.exec("INSERT INTO fuel_deletions(ns,proof,account_digest,result) VALUES($1,$2,$3,$4::jsonb)", @namespace, key, deletion_digest("account", actor), result.to_json)
        yield c, actor
        purge_account(c, actor)
        result
      end
    end

    private def retire_unlinked_pair(c : DB::Connection, candidate : Credential)
      # Claim the same binding row a redemption must lock, even if the POST
      # has not arrived. The tombstone then fences late redemption and bootstrap.
      c.exec("INSERT INTO fuel_bindings(ns,id,verifier) VALUES($1,$2,$3) ON CONFLICT DO NOTHING", @namespace, candidate.id, verifier(candidate))
      row = c.query_one?("SELECT verifier,account IS NOT NULL,revoked FROM fuel_bindings WHERE ns=$1 AND id=$2 FOR UPDATE", @namespace, candidate.id, as: {String, Bool, Bool})
      raise Error.new("selection_changed") unless row && verify_proof(c, candidate, row[0])
      _, linked, revoked = row
      Fuel.check(!linked || revoked, "transfer_completed")
      unless linked
        c.exec("INSERT INTO fuel_retired_bindings(ns,id) VALUES($1,$2) ON CONFLICT DO NOTHING", @namespace, candidate.id)
        c.exec("DELETE FROM fuel_bindings WHERE ns=$1 AND id=$2", @namespace, candidate.id)
      end
    end

    private def validate_deletion(proof : String, account : String)
      Fuel.check(proof.matches?(/\A[0-9a-f]{64}\z/), "invalid_proof")
      Fuel.key(account)
    end

    private def deletion_digest(kind : String, value : String) : String
      OpenSSL::HMAC.hexdigest(:sha256, @pair_key, {"fuel-delete-v1", @namespace, kind, value}.to_json)
    end

    private def purge_account(c : DB::Connection, account : String)
      # Keep retired public binding IDs so a stale saved secret cannot bootstrap
      # an unexpected replacement account after the deletion outcome expires.
      c.exec("INSERT INTO fuel_retired_bindings(ns,id) SELECT ns,id FROM fuel_bindings WHERE ns=$1 AND account=$2 ON CONFLICT DO NOTHING", @namespace, account)
      c.exec("DELETE FROM fuel_chat WHERE ns=$1 AND (actor=$2 OR recipient=$2)", @namespace, account)
      c.exec("UPDATE fuel_enrollments SET account=NULL WHERE ns=$1 AND account=$2", @namespace, account)
      c.exec("DELETE FROM fuel_accounts WHERE ns=$1 AND id=$2", @namespace, account)
    end
  end
end
