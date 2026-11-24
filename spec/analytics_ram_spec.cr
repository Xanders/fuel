require "./effects_spec"

class RamEventWallet < WalletRules
  def apply(tx : Fuel::AccountTransaction, actor : String, action : String, payload : JSON::Any, now : Int64) : JSON::Any
    reply = super
    tx.event(actor, "reward_banked", "run", Fuel.json({mode: "solo"}), now)
    reply
  end
end

if url = ENV["FUEL_TEST_DATABASE_URL"]?
  describe "RAM-only analytics" do
    it "never stores accepted payloads or replays them through a restarted adapter" do
      store = Fuel::Store.new(url, "ram_restart_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      proof = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      actor = store.bootstrap(proof, "test")
      legacy = Fuel.json({event_id: "legacy", name: "view"}).to_json
      store.db.exec("INSERT INTO fuel_outbox(ns,id,account,body,revision) VALUES($1,'legacy',$2,$3::jsonb,0)", store.namespace, actor, legacy)
      bodies = [] of String
      sink = Fuel::Questmetry.new(store, {"view" => [] of String}, "test", "1.0") { |body| bodies << body; 202 }
      sink.capture(proof, "one", "view", "", JSON.parse("{}")).should eq("queued")
      rows = store.db.query_one("SELECT count(*) FROM fuel_outbox WHERE ns=$1", store.namespace, as: Int64)
      restarted = Fuel::Questmetry.new(store, {"view" => [] of String}, "test", "1.0") { |body| bodies << body; 202 }
      restarted.drain
      bodies.should be_empty
      rows.should eq(1)
      sink.enabled(proof, false)
      retained = store.db.query_one("SELECT body::text FROM fuel_outbox WHERE ns=$1 AND id='legacy'", store.namespace, as: String)
      JSON.parse(retained).should eq(JSON.parse(legacy))
      store.close
    end

    it "drops failed delivery rather than retrying a persistent tail" do
      store = Fuel::Store.new(url, "ram_failure_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      proof = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      store.bootstrap(proof, "test")
      calls = 0
      sink = Fuel::Questmetry.new(store, {"view" => [] of String}, "test", "1.0", max_pending: 1) { |_| calls += 1; raise "offline" }
      sink.capture(proof, "one", "view", "", JSON.parse("{}")).should eq("queued")
      sink.capture(proof, "two", "view", "", JSON.parse("{}")).should eq("capacity")
      sink.drain
      sink.drain(Time.utc + 1.hour)
      calls.should eq(1)
      sink.capture(proof, "three", "view", "", JSON.parse("{}")).should eq("queued")
      store.close
    end

    it "retains accepted RAM events but rejects a first delayed client request after opt-out" do
      store = Fuel::Store.new(url, "ram_optout_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      proof = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      store.bootstrap(proof, "test")
      events = [] of JSON::Any
      sink = Fuel::Questmetry.new(store, {"view" => [] of String}, "test", "1.0", client_events: ["view"]) { |body| events.concat(JSON.parse(body)["events"].as_a); 202 }
      delayed_id, revision = "delayed", sink.preference(proof)
      sink.capture_client(proof, "accepted", "view", "", JSON.parse("{}"), revision).should eq("queued")
      sink.enabled(proof, false)
      sink.capture_client(proof, delayed_id, "view", "", JSON.parse("{}"), revision).should_not eq("queued")
      sink.drain
      events.size.should eq(1)
      store.close
    end

    it "commits rewards despite a failing analytics schema validator" do
      store = Fuel::Store.new(url, "ram_commit_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      proof = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      actor = store.bootstrap(proof, "test")
      rejected = Channel(Nil).new(1)
      sink = Fuel::Questmetry.new(store, {"reward_banked" => ["mode"]}, "test", "1.0",
        validate: ->(name : String, props : JSON::Any) { rejected.send(nil); false }) { |_| 503 }
      effect = Fuel::Effect.new("grant", actor, "grant", JSON.parse("{}"), Time.utc.to_unix)
      store.apply_effect(effect, RamEventWallet.new, sink)
      select
      when rejected.receive
      when timeout(2.seconds) then fail "analytics admission was not attempted"
      end
      store.account(proof, WalletRules.new)["progress"]["coins"].as_i64.should eq(130)
      store.apply_effect(effect, RamEventWallet.new, sink)
      store.account(proof, WalletRules.new)["progress"]["coins"].as_i64.should eq(130)
      store.close
    end

    it "does not make opt-out or a business commit wait for a blocked delivery" do
      store = Fuel::Store.new(url, "ram_inflight_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      proof = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      actor = store.bootstrap(proof, "test")
      started, release, finished = Channel(Nil).new, Channel(Nil).new, Channel(Nil).new(1)
      opted_out, committed = Channel(Nil).new(1), Channel(Nil).new(1)
      sink = Fuel::Questmetry.new(store, {"view" => [] of String}, "test", "1.0") do |_|
        started.send(nil)
        release.receive
        202
      end
      sink.capture(proof, "one", "view", "", JSON.parse("{}"))
      spawn { sink.drain; finished.send(nil) }
      started.receive
      spawn { sink.enabled(proof, false); opted_out.send(nil) }
      optout_fast = select
      when opted_out.receive then true
      when timeout(2.seconds) then false
      end
      spawn do
        store.apply_effect(Fuel::Effect.new("grant", actor, "grant", JSON.parse("{}"), Time.utc.to_unix), WalletRules.new, sink)
        committed.send(nil)
      end
      commit_fast = select
      when committed.receive then true
      when timeout(2.seconds) then false
      end
      release.send(nil)
      finished.receive
      opted_out.receive unless optout_fast
      committed.receive unless commit_fast
      optout_fast.should be_true
      commit_fast.should be_true
      store.account(proof, WalletRules.new)["progress"]["coins"].as_i64.should eq(130)
      store.close
    end

    it "bounds async admissions and batch work without blocking a business caller" do
      store = Fuel::Store.new(url, "ram_bounds_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      proof = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      actor = store.bootstrap(proof, "test")
      started, release = Channel(Nil).new, Channel(Nil).new
      validations, delivered = 0, 0
      sink = Fuel::Questmetry.new(store, {"view" => [] of String}, "test", "1.0", max_pending: 2,
        validate: ->(name : String, props : JSON::Any) {
          validations += 1
          if validations == 1
            started.send(nil)
            release.receive
          end
          true
        }) { |body| delivered += JSON.parse(body)["events"].as_a.size; 202 }
      sink.emit(actor, "one", "view", "", JSON.parse("{}"))
      started.receive
      sink.emit(actor, "two", "view", "", JSON.parse("{}"))
      sink.emit(actor, "three", "view", "", JSON.parse("{}"))
      sink.pending.should eq(2)
      sink.omitted.should eq(1)
      store.apply_effect(Fuel::Effect.new("grant", actor, "grant", JSON.parse("{}"), Time.utc.to_unix), WalletRules.new)
      release.send(nil)
      deadline = Time.instant + 2.seconds
      while sink.pending > 0 && Time.instant < deadline
        sink.drain
        sleep 1.millisecond
      end
      sink.pending.should eq(0)
      delivered.should eq(2)
      store.close
    end

    it "limits each delivery batch to25 even when more events are ready" do
      store = Fuel::Store.new(url, "ram_batch_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      proof = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      store.bootstrap(proof, "test")
      sizes = [] of Int32
      sink = Fuel::Questmetry.new(store, {"view" => [] of String}, "test", "1.0") { |body| sizes << JSON.parse(body)["events"].as_a.size; 202 }
      26.times { |index| sink.capture(proof, "id#{index}", "view", "", JSON.parse("{}")) }
      sink.drain
      sizes.should eq([25])
      sink.pending.should eq(1)
      sink.drain
      sizes.should eq([25, 1])
      store.close
    end
  end
end
