require "./effects_spec"

if url = ENV["FUEL_TEST_DATABASE_URL"]?
  describe "optional analytics integration" do
    it "persists and purges an account's consent without a configured delivery adapter" do
      store = Fuel::Store.new(url, "optional_analytics_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      credential = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      other = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      actor = store.bootstrap(credential, "test")
      other_actor = store.bootstrap(other, "test")
      # Retained events can predate temporarily disabling the delivery adapter.
      {actor => "own_event", other_actor => "other_event"}.each do |account, id|
        store.db.exec("INSERT INTO fuel_outbox(ns,id,account,body,revision) VALUES($1,$2,$3,'{}'::jsonb,0)", store.namespace, id, account)
      end
      sessions = Fuel::Sessions.new(EffectRules.new)
      rules = WalletRules.new
      handler = Fuel::Handler.new(store, sessions, [] of String, account_rules: rules)
      runtime = Fuel::Runtime.new(store, sessions, handler, rules)
      address = runtime.server.bind_tcp("127.0.0.1", 0)
      spawn { runtime.server.listen }
      client = HTTP::Client.new(address.address, address.port)
      headers = HTTP::Headers{"Authorization" => "Fuel #{credential.id}:#{credential.secret}"}
      begin
        disabled = client.post("/fuel/v1/analytics/enabled", headers, {enabled: false}.to_json)
        disabled.status_code.should eq(200)
        JSON.parse(disabled.body)["data"]["revision"].as_s.should eq("1")
        store.account(credential, rules)["analytics_enabled"].as_bool.should be_false
        store.db.query_one("SELECT count(*) FROM fuel_outbox WHERE ns=$1 AND account=$2", store.namespace, actor, as: Int64).should eq(0)
        store.db.query_one("SELECT count(*) FROM fuel_outbox WHERE ns=$1 AND account=$2", store.namespace, other_actor, as: Int64).should eq(1)
        repeated = client.post("/fuel/v1/analytics/enabled", headers, {enabled: false}.to_json)
        JSON.parse(repeated.body)["data"]["revision"].as_s.should eq("1")
        enabled = client.post("/fuel/v1/analytics/enabled", headers, {enabled: true}.to_json)
        JSON.parse(enabled.body)["data"]["revision"].as_s.should eq("2")
        store.account(credential, rules)["analytics_enabled"].as_bool.should be_true
        store.db.query_one("SELECT count(*) FROM fuel_outbox WHERE ns=$1 AND account=$2", store.namespace, actor, as: Int64).should eq(0)
        client.post("/fuel/v1/analytics/events", headers, {id: "new", name: "view", session: "", revision: "2", properties: {} of String => String}.to_json).status_code.should eq(400)
      ensure
        client.close
        runtime.stop
        store.close
      end
    end
  end
end
