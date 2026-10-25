require "./effects_spec"

class EventWalletRules < WalletRules
  def apply(tx : Fuel::AccountTransaction, actor : String, action : String, payload : JSON::Any, now : Int64) : JSON::Any
    reply = super
    tx.event(actor, "reward_banked", "journey", Fuel.json({mode: "duel"}), now)
    reply
  end
end

if url = ENV["FUEL_TEST_DATABASE_URL"]?
  describe "bounded revision-fenced analytics" do
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
        store.db.query_one("SELECT count(*) FROM fuel_outbox WHERE ns=$1", store.namespace, as: Int64).should eq(0)
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
      store.db.query_one("SELECT count(*) FROM fuel_outbox WHERE ns=$1", store.namespace, as: Int64).should eq(0)
      store.close
    end

    it "lets gameplay progress while delivery waits, but delays opt-out acknowledgement" do
      store = Fuel::Store.new(url, "analytics_inflight_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      credential = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      store.bootstrap(credential, "test")
      started = Channel(Nil).new
      release = Channel(Nil).new
      delivered = Channel(Nil).new(1)
      progress = Channel(JSON::Any).new(1)
      optout_started = Channel(Nil).new
      opted_out = Channel(Nil).new(1)
      analytics = Fuel::Questmetry.new(store, {"run_started" => ["mode"]}, "test", "0.3.0") do |_|
        started.send(nil)
        release.receive
        202
      end
      analytics.capture(credential, "one", "run_started", "journey", Fuel.json({mode: "duel"}))
      spawn { analytics.drain; delivered.send(nil) }
      started.receive
      spawn { progress.send(store.account(credential, WalletRules.new)) }
      gameplay_completed = select
      when progress.receive then true
      when timeout(100.milliseconds) then false
      end
      spawn { optout_started.send(nil); analytics.enabled(credential, false); opted_out.send(nil) }
      optout_started.receive
      premature = select
      when opted_out.receive then true
      when timeout(20.milliseconds) then false
      end
      release.send(nil)
      delivered.receive
      opted_out.receive unless premature
      gameplay_completed.should be_true
      premature.should be_false
      store.close
    end

    it "keeps original occurrence and cannot restore pre-opt-out events after opt-in" do
      store = Fuel::Store.new(url, "analytics_revision_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      a = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      b = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      account = store.bootstrap(a, "a")
      store.bootstrap(b, "b")
      bodies = [] of String
      analytics = Fuel::Questmetry.new(store, {"run_started" => ["mode"]}, "test", "0.3.0", pseudonym_key: "q" * 32) { |body| bodies << body; 202 }
      revision = analytics.preference(a)
      original = Time.unix(1000)
      analytics.capture(a, "original", "run_started", "same-room", Fuel.json({mode: "duel"}), occurred_at: original, revision: revision)
      analytics.capture(b, "other", "run_started", "same-room", Fuel.json({mode: "duel"}), occurred_at: original)
      analytics.drain
      events = JSON.parse(bodies.first)["events"].as_a
      events.size.should eq(2)
      events.map(&.["occurred_at"].as_s).uniq.should eq([original.to_rfc3339])
      events.map(&.["session_id"].as_s).uniq.size.should eq(2)
      bodies.first.should_not contain(account)
      analytics.enabled(a, false)
      analytics.enabled(a, true)
      analytics.capture(a, "old", "run_started", "same-room", Fuel.json({mode: "duel"}), occurred_at: original, revision: revision).should eq("stale")
      analytics.drain
      bodies.size.should eq(1)
      store.close
    end

    it "omits a full telemetry queue without rolling back a committed reward" do
      store = Fuel::Store.new(url, "analytics_full_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      credential = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      actor = store.bootstrap(credential, "test")
      analytics = Fuel::Questmetry.new(store, {"reward_banked" => ["mode"]}, "test", "0.3.0", max_pending: 1) { |_| 503 }
      analytics.capture(credential, "first", "reward_banked", "journey", Fuel.json({mode: "duel"}))
      effect = Fuel::Effect.new("grant", actor, "grant", JSON.parse("{}"), Time.utc.to_unix)
      store.apply_effect(effect, EventWalletRules.new, analytics)
      store.apply_effect(effect, EventWalletRules.new, analytics)
      store.account(credential, EventWalletRules.new)["progress"]["coins"].as_i64.should eq(130)
      analytics.omitted.should eq(1)
      store.db.query_one("SELECT count(*) FROM fuel_outbox WHERE ns=$1", store.namespace, as: Int64).should eq(1)
      store.close
    end

    it "halts configuration failures, resumes explicitly and coordinates opt-out with delivery" do
      store = Fuel::Store.new(url, "analytics_halt_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      credential = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      store.bootstrap(credential, "test")
      code = 401
      calls = 0
      analytics = Fuel::Questmetry.new(store, {"run_started" => ["mode"]}, "test", "0.3.0") { |_| calls += 1; code }
      analytics.capture(credential, "one", "run_started", "journey", Fuel.json({mode: "duel"}))
      analytics.drain
      analytics.drain(Time.utc + 1.hour)
      calls.should eq(1)
      analytics.halted.should eq(1)
      code = 202
      analytics.resume.should eq(1)
      analytics.drain
      calls.should eq(2)
      analytics.halted.should eq(0)
      store.close
    end
  end
end
