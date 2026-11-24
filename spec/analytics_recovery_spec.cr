require "./effects_spec"

class EventWalletRules < WalletRules
  def apply(tx : Fuel::AccountTransaction, actor : String, action : String, payload : JSON::Any, now : Int64) : JSON::Any
    reply = super
    tx.event(actor, "reward_banked", "journey", Fuel.json({mode: "duel"}), now)
    reply
  end
end

if url = ENV["FUEL_TEST_DATABASE_URL"]?
  describe "analytics admission revisions" do
    it "carries the current preference through HTTP admission before an effect is queued" do
      store = Fuel::Store.new(url, "analytics_http_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      credential = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      store.bootstrap(credential, "test")
      analytics = Fuel::Questmetry.new(store, {"reward_banked" => ["mode"]}, "test", "0.3.0") { |_| 202 }
      sessions = Fuel::Sessions.new(EffectRules.new)
      rules = EventWalletRules.new
      handler = Fuel::Handler.new(store, sessions, [] of String, analytics, account_rules: rules)
      runtime = Fuel::Runtime.new(store, sessions, handler, rules, analytics)
      address = runtime.server.bind_tcp("127.0.0.1", 0)
      spawn { runtime.server.listen }
      client = HTTP::Client.new(address.address, address.port)
      headers = HTTP::Headers{"Authorization" => "Fuel #{credential.id}:#{credential.secret}"}
      begin
        created = JSON.parse(client.post("/fuel/v1/sessions", headers, {mode: "solo", capacity: 1}.to_json).body)["data"]
        id = created["session_id"].as_s
        client.post("/fuel/v1/sessions/#{id}/commands", headers, {id: "one", epoch: created["epoch"], revision: "0", action: {id: "one"}}.to_json).status_code.should eq(200)
        client.post("/fuel/v1/analytics/enabled", headers, {enabled: false}.to_json).status_code.should eq(200)
        client.post("/fuel/v1/analytics/enabled", headers, {enabled: true}.to_json).status_code.should eq(200)
        runtime.pump_effects
        deadline = Time.instant + 3.seconds
        until sessions.get(id).pending_effects == 0 || Time.instant > deadline
          sleep 1.millisecond
        end
        sessions.get(id).pending_effects.should eq(0)
        deadline = Time.instant + 2.seconds
        while analytics.pending > 0 && Time.instant < deadline
          sleep 1.millisecond
        end
        analytics.pending.should eq(0)
      ensure
        client.close
        runtime.stop
        store.close
      end
    end

    it "freezes a room effect's preference revision before deferred reward application" do
      store = Fuel::Store.new(url, "analytics_effect_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      credential = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      actor = store.bootstrap(credential, "test")
      analytics = Fuel::Questmetry.new(store, {"reward_banked" => ["mode"]}, "test", "0.3.0") { |_| 202 }
      room = Fuel::Room.new(EffectRules.new, actor, "solo", 1, false, preferences: {actor => analytics.preference(credential)})
      room.command(actor, room.epoch, "one", 0_i64, Fuel.json({id: "one"}))
      analytics.enabled(credential, false)
      analytics.enabled(credential, true)
      effect = room.begin_effect.not_nil!
      store.apply_effect(effect, EventWalletRules.new, analytics)
      store.account(credential, WalletRules.new)["progress"]["coins"].as_i64.should eq(130)
      deadline = Time.instant + 2.seconds
      while analytics.pending > 0 && Time.instant < deadline
        sleep 1.millisecond
      end
      analytics.pending.should eq(0)
      store.close
    end
  end
end
