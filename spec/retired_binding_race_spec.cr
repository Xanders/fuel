require "./spec_helper"

if url = ENV["FUEL_TEST_DATABASE_URL"]?
  [false, true].each do |pairing|
    it "rejects a retired proof when deletion overtakes #{pairing ? "pair preparation" : "guest bootstrap"}" do
      store = Fuel::Store.new(url, "retirement_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      credential = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      actor = store.bootstrap(credential, "test")
      proof = Random::Secure.hex(32)
      owner = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      code = if pairing
               store.bootstrap(owner, "test")
               store.issue_pair(owner)["code"].as_s
             else
               ""
             end
      locked = Channel(Nil).new(1)
      release = Channel(Nil).new(1)
      deleted = Channel(Exception?).new(1)
      result = Channel(String | Exception).new(1)
      deletion_joined = false
      spawn do
        begin
          store.delete_account(credential, true, proof, actor) do |connection, _|
            # Stop admission after its first tombstone read, before binding access.
            connection.exec("LOCK TABLE fuel_bindings IN ACCESS EXCLUSIVE MODE")
            locked.send(nil)
            release.receive?
          end
          deleted.send(nil)
        rescue error
          deleted.send(error)
        end
      end
      begin
        select
        when locked.receive
        when timeout(3.seconds)
          fail "Deletion did not reach the controlled boundary"
        end
        spawn do
          begin
            result.send(pairing ? store.request_pair(code, credential, "race").to_json : store.bootstrap(credential, "race"))
          rescue error
            result.send(error)
          end
        end
        query = pairing ? "INSERT INTO fuel_bindings%" : "SELECT verifier FROM fuel_bindings%"
        blocked = false
        1000.times do
          blocked = store.db.query_one("SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock' AND query LIKE $1)", query, as: Bool)
          break if blocked
          sleep 2.milliseconds
        end
        blocked.should be_true
        release.close
        error = deleted.receive
        deletion_joined = true
        raise error if error
        outcome = select
        when value = result.receive
          value
        when timeout(3.seconds)
          fail "Admission did not finish after deletion committed"
        end
        case outcome
        when Fuel::Error
          outcome.code.should eq(pairing ? "invalid_code" : "unauthorized")
        when String
          fail "Admission accepted a deleted binding"
        else
          raise outcome
        end
        store.db.query_one("SELECT count(*) FROM fuel_accounts WHERE ns=$1", store.namespace, as: Int64).should eq(pairing ? 1 : 0)
        store.db.query_one("SELECT count(*) FROM fuel_bindings WHERE ns=$1 AND id=$2", store.namespace, credential.id, as: Int64).should eq(0)
        store.db.query_one("SELECT count(*) FROM fuel_retired_bindings WHERE ns=$1 AND id=$2", store.namespace, credential.id, as: Int64).should eq(1)
        store.deletion_status(proof, actor)["status"].as_s.should eq("deleted")
      ensure
        release.close
        deleted.receive unless deletion_joined
        store.close
      end
    end
  end
end
