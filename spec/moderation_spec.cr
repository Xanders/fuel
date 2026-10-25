require "./spec_helper"

if url = ENV["FUEL_TEST_DATABASE_URL"]?
  describe "shared moderation" do
    it "persists configured global history, trusted names, mutes and reports across restart" do
      store = Fuel::Store.new(url, "moderation_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      alice = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      bob = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      a = store.bootstrap(alice, "a")
      b = store.bootstrap(bob, "b")
      chat = Fuel::Chat.new(store: store, persist: ["global"], history_limit: 40,
        censor: Fuel::Censor.new(["rude"]), display_name: ->(id : String, progress : JSON::Any) { id == a ? "Quiet Fox" : "Bright Owl" }) { |_, kind, _| kind == "global" }
      message = chat.post(a, "global", "", "RUDE comment")
      message["name"].as_s.should eq("Quiet Fox")
      message["text"].as_s.should eq("**** comment")
      chat.set_muted(bob, a, true)
      chat.history(b, "global", "").should be_empty
      chat.muted(bob).first["id"].as_s.should eq(a)
      chat.report(bob, "global", "", message["id"].as_s, "harassment")
      chat.report(bob, "global", "", message["id"].as_s, "harassment")
      store.db.query_one("SELECT count(*) FROM fuel_reports WHERE ns=$1", store.namespace, as: Int64).should eq(1)
      expect_raises(Fuel::Error, "invalid_report") { chat.report(bob, "global", "", message["id"].as_s, "invented") }
      expect_raises(Fuel::Error, "invalid_report") { chat.report(bob, "private", a, message["id"].as_s, "spam") }
      chat.set_muted(bob, a, false)
      restarted = Fuel::Chat.new(store: store, persist: ["global"]) { |_, kind, _| kind == "global" }
      restarted.history(b, "global", "").first["id"].as_s.should eq(message["id"].as_s)
      store.delete_account(alice, true)
      restarted.history(b, "global", "").should be_empty
      chat.muted(bob).should be_empty
      store.db.query_one("SELECT count(*) FROM fuel_reports WHERE ns=$1", store.namespace, as: Int64).should eq(0)
      store.close
    end
  end
end
