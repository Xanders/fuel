require "./spec_helper"

if url = ENV["FUEL_TEST_DATABASE_URL"]?
  describe "recoverable deletion and device safety" do
    it "requires last-device confirmation and returns metadata for the selected proof" do
      store = Fuel::Store.new(url, "devices_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      credential = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      store.bootstrap(credential, "test")
      binding = store.bindings(credential).first
      binding["current"].as_bool.should be_true
      binding["created_at"].as_s.should_not be_empty
      binding["last_seen"].as_s.should_not be_empty
      expect_raises(Fuel::Error, "last_device_confirmation_required") { store.revoke(credential, credential.id) }
      store.authenticate(credential).should_not be_empty
      store.revoke(credential, credential.id, confirmed_last: true)
      expect_raises(Fuel::Error, "unauthorized") { store.authenticate(credential) }
      store.close
    end

    it "recovers a deleted outcome without live credentials and never resurrects old bindings" do
      namespace = "deletion_#{Fuel.id}"
      store = Fuel::Store.new(url, namespace, "d" * 32, "p" * 32)
      store.migrate
      credential = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      actor = store.bootstrap(credential, "test")
      proof = Random::Secure.hex(32)
      store.deletion_status(proof, actor)["status"].as_s.should eq("unknown")
      expect_raises(Fuel::Error, "confirmation_required") { store.delete_account(credential, false, proof, actor) }
      expect_raises(Fuel::Error, "conflict") { store.delete_account(credential, true, proof, Fuel.id) }
      result = store.delete_account(credential, true, proof, actor)
      result["status"].as_s.should eq("deleted")
      result["removed_bindings"].as_a.map(&.as_s).should eq([credential.id])
      fresh = Fuel::Store.new(url, namespace, "e" * 32, "p" * 32, previous_device_keys: ["d" * 32])
      fresh.deletion_status(proof, actor).should eq(result)
      fresh.deletion_status(proof, Fuel.id)["status"].as_s.should eq("unknown")
      fresh.deletion_status(Random::Secure.hex(32), actor)["status"].as_s.should eq("unknown")
      expect_raises(Fuel::Error, "unauthorized") { fresh.bootstrap(credential, "test") }
      owner = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      fresh.bootstrap(owner, "owner")
      code = fresh.issue_pair(owner)["code"].as_s
      expect_raises(Fuel::Error, "invalid_code") { fresh.request_pair(code, credential, "test") }
      fresh.db.query_one("SELECT count(*) FROM fuel_accounts WHERE ns=$1 AND id=$2", namespace, actor, as: Int64).should eq(0)
      fresh.close
      store.close
    end
  end
end
