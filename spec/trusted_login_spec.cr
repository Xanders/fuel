require "./spec_helper"

if url = ENV["FUEL_TEST_DATABASE_URL"]?
  describe "trusted enrollment and login grants" do
    store = Fuel::Store.new(url, "trusted_#{Fuel.id}", "d" * 32, "p" * 32)
    store.migrate

    it "enrolls idempotently without a provisioning device, then consumes into an ordinary binding" do
      operation = Fuel.id
      account = store.enroll_account(operation)
      store.enroll_account(operation).should eq(account)
      grant_id = Fuel.id
      grant = store.issue_login(account, grant_id)
      store.issue_login(account, grant_id).should eq(grant)
      candidate = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      expect_raises(Fuel::Error, "unauthorized") { store.authenticate(candidate) }
      store.redeem_login(grant["code"].as_s, candidate, "local").should eq(account)
      store.authenticate(candidate).should eq(account)
      store.redeem_login(grant["code"].as_s, candidate, "local").should eq(account)
      store.bindings(candidate).size.should eq(1)
      stranger = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      expect_raises(Fuel::Error, "invalid_code") { store.redeem_login(grant["code"].as_s, stranger, "local") }
      store.revoke(candidate, candidate.id, true)
      expect_raises(Fuel::Error, "invalid_code") { store.redeem_login(grant["code"].as_s, candidate, "local") }
    end

    it "expires and supersedes grants without moving an existing account or accepting a guessed proof" do
      account = store.enroll_account(Fuel.id)
      candidate = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      old = store.issue_login(account, Fuel.id)
      current = store.issue_login(account, Fuel.id)
      expect_raises(Fuel::Error, "invalid_code") { store.redeem_login(old["code"].as_s, candidate, "expiry") }
      store.db.exec("UPDATE fuel_login_grants SET expires_at=now()-interval '1 second' WHERE ns=$1 AND account=$2", store.namespace, account)
      expect_raises(Fuel::Error, "invalid_code") { store.redeem_login(current["code"].as_s, candidate, "expiry") }
      store.db.exec("UPDATE fuel_login_grants SET expires_at=now()-interval '2 days' WHERE ns=$1 AND account=$2", store.namespace, account)
      store.cleanup
      store.issue_login(account, current["id"].as_s)["code"].should eq(current["code"])
      expect_raises(Fuel::Error, "invalid_code") { store.redeem_login(current["code"].as_s, candidate, "expiry") }
      another = store.issue_login(account, Fuel.id)
      occupied = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      previous = store.bootstrap(occupied, "test")
      expect_raises(Fuel::Error, "invalid_code") { store.redeem_login(another["code"].as_s, occupied, "occupied") }
      store.authenticate(occupied).should eq(previous)
      store.redeem_login(another["code"].as_s, candidate, "expiry").should eq(account)
      forged = Fuel::Credential.new(candidate.id, Random::Secure.hex(32))
      expect_raises(Fuel::Error, "invalid_code") { store.redeem_login(another["code"].as_s, forged, "forged") }
    end

    it "retains attempts across restart and keeps enrollment tombstones after deletion" do
      10.times { expect_raises(Fuel::Error, "invalid_code") { store.redeem_login("A" * 16, Fuel::Credential.new(Fuel.id, Random::Secure.hex(32)), "bounded") } }
      reopened = Fuel::Store.new(url, store.namespace, "d" * 32, "p" * 32)
      expect_raises(Fuel::Error, "rate_limited") { reopened.redeem_login("A" * 16, Fuel::Credential.new(Fuel.id, Random::Secure.hex(32)), "bounded") }
      operation = Fuel.id
      account = store.enroll_account(operation)
      grant = store.issue_login(account, Fuel.id)
      credential = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      store.redeem_login(grant["code"].as_s, credential, "delete")
      store.delete_account(credential, true)
      expect_raises(Fuel::Error, "deleted") { store.enroll_account(operation) }
      expect_raises(Fuel::Error, "invalid_code") { store.redeem_login(grant["code"].as_s, credential, "delete") }
      reopened.close
    end
    it "serializes concurrent redemption and preserves owner-confirmed transfer as a separate path" do
      account = store.enroll_account(Fuel.id)
      grant = store.issue_login(account, Fuel.id)
      results = Channel(String).new(2)
      candidates = Array.new(2) { Fuel::Credential.new(Fuel.id, Random::Secure.hex(32)) }
      candidates.each_with_index do |credential, index|
        spawn do
          begin
            results.send(store.redeem_login(grant["code"].as_s, credential, "race-#{index}"))
          rescue error : Fuel::Error
            results.send(error.code)
          end
        end
      end
      [results.receive, results.receive].sort.should eq([account, "invalid_code"].sort)
      owner = candidates.find do |credential|
        begin
          store.authenticate(credential) == account
        rescue Fuel::Error
          false
        end
      end.not_nil!
      ordinary = store.issue_pair(owner)
      next_device = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      requested = store.request_pair(ordinary["code"].as_s, next_device, "ordinary")
      expect_raises(Fuel::Error, "unauthorized") { store.authenticate(next_device) }
      store.approve_pair(owner, requested["id"].as_s)
      store.authenticate(next_device).should eq(account)
      expect_raises(Fuel::Error, "invalid_code") { store.redeem_login(ordinary["code"].as_s, Fuel::Credential.new(Fuel.id, Random::Secure.hex(32)), "separate") }
    end

    it "cannot revive a binding while its previous account deletion commits" do
      candidate = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      old_account = store.bootstrap(candidate, "delete-race")
      target = store.enroll_account(Fuel.id)
      grant = store.issue_login(target, Fuel.id)
      locked = Channel(Nil).new
      release = Channel(Nil).new
      deleted = Channel(Nil).new
      spawn do
        store.db.transaction do |tx|
          c = tx.connection
          c.exec("SELECT id FROM fuel_accounts WHERE ns=$1 AND id=$2 FOR UPDATE", store.namespace, old_account)
          c.exec("INSERT INTO fuel_retired_bindings(ns,id) VALUES($1,$2)", store.namespace, candidate.id)
          c.exec("DELETE FROM fuel_accounts WHERE ns=$1 AND id=$2", store.namespace, old_account)
          locked.send(nil)
          release.receive
        end
        deleted.send(nil)
      end
      locked.receive
      result = Channel(String).new
      spawn do
        begin
          result.send(store.redeem_login(grant["code"].as_s, candidate, "delete-race"))
        rescue error : Fuel::Error
          result.send(error.code)
        end
      end
      waiting = false
      100.times do
        waiting = store.db.query_one("SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE wait_event_type='Lock' AND query LIKE 'INSERT INTO fuel_bindings%')", as: Bool)
        break if waiting
        sleep 10.milliseconds
      end
      release.send(nil)
      deleted.receive
      result.receive.should eq("invalid_code")
      waiting.should be_true
      expect_raises(Fuel::Error, "unauthorized") { store.authenticate(candidate) }
    end

    it "checks wall-clock expiry after an account lock wait" do
      target = store.enroll_account(Fuel.id)
      grant = store.issue_login(target, Fuel.id)
      store.db.exec("UPDATE fuel_login_grants SET expires_at=clock_timestamp()+interval '1 second' WHERE ns=$1 AND id=$2", store.namespace, grant["id"].as_s)
      locked = Channel(Nil).new
      release = Channel(Nil).new
      spawn do
        store.db.transaction do |tx|
          tx.connection.exec("SELECT id FROM fuel_accounts WHERE ns=$1 AND id=$2 FOR UPDATE", store.namespace, target)
          locked.send(nil)
          release.receive
        end
      end
      locked.receive
      candidate = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      result = Channel(String).new
      spawn do
        begin
          result.send(store.redeem_login(grant["code"].as_s, candidate, "expiry-race"))
        rescue error : Fuel::Error
          result.send(error.code)
        end
      end
      sleep 1200.milliseconds
      release.send(nil)
      result.receive.should eq("invalid_code")
      expect_raises(Fuel::Error, "unauthorized") { store.authenticate(candidate) }
    end
  end
end
