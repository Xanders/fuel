require "./spec_helper"

if url = ENV["FUEL_TEST_DATABASE_URL"]?
  describe Fuel::Store do
    store = Fuel::Store.new(url, "spec_#{Fuel.id}", "device" * 8, "pair" * 8)
    store.migrate
    a = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
    b = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))

    it "bootstraps idempotently, never accepts ID or verifier as credentials" do
      who = store.bootstrap(a, "test")
      store.bootstrap(a, "test").should eq(who)
      store.authenticate(a).should eq(who)
      expect_raises(Fuel::Error, "unauthorized") { store.authenticate(Fuel::Credential.new(a.id, Random::Secure.hex(32))) }
      store.bindings(a).size.should eq(1)
    end

    it "requires owner confirmation, preserves both device secrets, and recovers a lost approval ACK" do
      old_b = store.bootstrap(b, "test")
      candidate = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      pair = store.issue_pair(a)
      request = store.request_pair(pair["code"].as_s, candidate, "test")
      expect_raises(Fuel::Error, "unauthorized") { store.authenticate(candidate) }
      store.pair_status(candidate)["status"].as_s.should eq("pending")
      store.approve_pair(a, request["id"].as_s)["status"].as_s.should eq("linked")
      store.approve_pair(a, request["id"].as_s)["status"].as_s.should eq("linked")
      store.authenticate(candidate).should eq(store.authenticate(a))
      store.authenticate(b).should eq(old_b)
      expect_raises(Fuel::Error, "invalid_code") { store.request_pair(pair["code"].as_s, Fuel::Credential.new(Fuel.id, Random::Secure.hex(32)), "test") }
      store.revoke(a, candidate.id)
      expect_raises(Fuel::Error, "unauthorized") { store.authenticate(candidate) }
    end

    it "commits a result exactly once, rejects changed reuse and ranks best scores with stable ties" do
      who = store.authenticate(a)
      result_id = Fuel.id
      result = store.record_result(a, result_id, "daily", 20_i64, "Quiet Fox", JSON.parse(%({"coins":3})))
      store.record_result(a, result_id, "daily", 20_i64, "Quiet Fox", JSON.parse(%({"coins":3}))).should eq(result)
      expect_raises(Fuel::Error, "conflict") { store.record_result(a, result_id, "daily", 99_i64, "Quiet Fox", JSON.parse(%({"coins":3}))) }
      store.progress(a)["coins"].as_i.should eq(3)
      store.record_result(a, Fuel.id, "daily", 10_i64, "Quiet Fox", JSON.parse(%({"coins":4})))
      store.leaderboard("daily", 10).first["score"].as_s.should eq("20")
      store.leaderboard("daily", 10).first["account_id"].as_s.should eq(who)
    end

    it "rolls back progress and receipt when a transactional effect hook fails" do
      id = Fuel.id
      expect_raises(Exception, "injected") do
        store.record_result(a, id, "failure", 9_i64, "Fox", JSON.parse(%({"coins":999}))) { |_, _| raise "injected" }
      end
      store.progress(a)["coins"].as_i.should eq(4)
      store.record_result(a, id, "failure", 9_i64, "Fox", JSON.parse(%({"coins":5})))
      store.progress(a)["coins"].as_i.should eq(5)
    end

    it "bounds guest issuance in PostgreSQL without revoking existing accounts" do
      key = "limit_#{Fuel.id}"
      store.limit(key, 1, 60)
      expect_raises(Fuel::Error, "rate_limited") { store.limit(key, 1, 60) }
      store.authenticate(a).should_not be_empty
    end

    it "preserves persistent identity across server key rotation and supports outcome ratings" do
      old = Fuel::Store.new(url, store.namespace, "e" * 32, "q" * 32, previous_device_keys: ["device" * 8])
      expected = store.authenticate(a)
      old.authenticate(a).should eq(expected)
      old.record_result(a, Fuel.id, "duel", 5_i64, "Fox", JSON.parse("{}"), outcome: "win")
      old.ratings("duel", "wins").first["wins"].as_s.should eq("1")
      old.close
    end

    it "deletes owned data and revokes every binding with explicit confirmation" do
      expect_raises(Fuel::Error, "confirmation_required") { store.delete_account(b, false) }
      store.delete_account(b, true)
      expect_raises(Fuel::Error, "unauthorized") { store.authenticate(b) }
    end
  end
end
