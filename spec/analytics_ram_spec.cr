require "./effects_spec"

class RamEventWallet < WalletRules
  def apply(tx : Fuel::AccountTransaction, actor : String, action : String, payload : JSON::Any, now : Int64) : JSON::Any
    reply = super
    tx.event(actor, "reward_banked", "run", Fuel.json({mode: "solo"}), now)
    reply
  end
end

class RamPublicWallet < RamEventWallet
  def public_action?(name : String) : Bool
    name == "grant"
  end
end

def ram_wait(channel : Channel(Nil), label : String)
  select
  when channel.receive
  when timeout(3.seconds) then fail label
  end
end

def ram_release(channel : Channel(Nil))
  select
  when channel.send(nil)
  else
  end
end

if url = ENV["FUEL_TEST_DATABASE_URL"]?
  describe "RAM-only analytics" do
    it "drops an invalid trusted wire ID without sending it beside healthy events" do
      store = Fuel::Store.new(url, "ram_wire_id_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      proof = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      actor = store.bootstrap(proof, "test")
      sent = [] of JSON::Any
      sink = Fuel::Questmetry.new(store, {"view" => [] of String}, "test", "1.0") do |body|
        sent.concat(JSON.parse(body)["events"].as_a)
        202
      end
      begin
        sink.capture(proof, "healthy", "view", "", JSON.parse("{}")).should eq("queued")
        sink.emit(actor, "x" * 81, "view", "", JSON.parse("{}"), revision: 0_i64)
        deadline = Time.instant + 3.seconds
        while sink.pending > 0 && Time.instant < deadline
          sink.drain
          sleep 1.millisecond
        end
        sink.pending.should eq(0)
        sent.map { |event| event["event_id"].as_s }.should eq(["healthy"])
      ensure
        store.close
      end
    end

    it "checks outgoing IDs after client keying and enforces receiver event names" do
      store = Fuel::Store.new(url, "ram_wire_names_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      proof = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      store.bootstrap(proof, "test")
      invalid_names = ["match-finished", "Match_finished", "a" * 81]
      names = {"view" => [] of String, "a" * 80 => [] of String}
      invalid_names.each { |name| names[name] = [] of String }
      sent = [] of JSON::Any
      sink = Fuel::Questmetry.new(store, names, "test", "1.0", client_events: ["view"]) do |body|
        sent.concat(JSON.parse(body)["events"].as_a)
        202
      end
      begin
        sink.capture(proof, "x" * 80, "a" * 80, "", JSON.parse("{}")).should eq("queued")
        sink.capture_client(proof, "x" * 100, "view", "", JSON.parse("{}"), 0_i64).should eq("queued")
        expect_raises(Fuel::Error, "invalid_event") { sink.capture(proof, "x" * 81, "view", "", JSON.parse("{}")) }
        invalid_names.each do |name|
          expect_raises(Fuel::Error, "invalid_event") { sink.capture(proof, Fuel.id, name, "", JSON.parse("{}")) }
        end
        sink.drain
        sent.size.should eq(2)
        sent.all? { |event| event["event_id"].as_s.bytesize <= 80 }.should be_true
        sent.find { |event| event["source"] == "client" }.not_nil!["event_id"].as_s.bytesize.should eq(64)
      ensure
        store.close
      end
    end

    it "rejects environments exceeding the receiver limit at configuration" do
      store = Fuel::Store.new(url, "ram_wire_environment_#{Fuel.id}", "d" * 32, "p" * 32)
      begin
        Fuel::Questmetry.new(store, {"view" => [] of String}, "a" * 40, "1.0") { |_| 202 }
        expect_raises(Fuel::Error, "invalid_analytics_config") do
          Fuel::Questmetry.new(store, {"view" => [] of String}, "a" * 41, "1.0") { |_| 202 }
        end
      ensure
        store.close
      end
    end

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
      effect = Fuel::Effect.new("grant", actor, "grant", JSON.parse("{}"), Time.utc.to_unix, preferences: {actor => 0_i64})
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
      started, release, finished = Channel(Nil).new(1), Channel(Nil).new(1), Channel(Nil).new(1)
      opted_out, committed = Channel(Nil).new(1), Channel(Nil).new(1)
      sink = Fuel::Questmetry.new(store, {"view" => [] of String}, "test", "1.0") do |_|
        started.send(nil)
        release.receive
        202
      end
      begin
        sink.capture(proof, "one", "view", "", JSON.parse("{}"))
        spawn { sink.drain; finished.send(nil) }
        ram_wait(started, "delivery did not start")
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
        ram_wait(finished, "delivery did not finish")
        ram_wait(opted_out, "opt-out did not finish") unless optout_fast
        ram_wait(committed, "business commit did not finish") unless commit_fast
        optout_fast.should be_true
        commit_fast.should be_true
        store.account(proof, WalletRules.new)["progress"]["coins"].as_i64.should eq(130)
      ensure
        ram_release(release)
        store.close
      end
    end

    it "bounds async admissions and batch work without blocking a business caller" do
      store = Fuel::Store.new(url, "ram_bounds_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      proof = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      actor = store.bootstrap(proof, "test")
      started, release = Channel(Nil).new(1), Channel(Nil).new(1)
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
      begin
        sink.emit(actor, "one", "view", "", JSON.parse("{}"), revision: 0_i64)
        ram_wait(started, "deferred admission did not start")
        sink.emit(actor, "two", "view", "", JSON.parse("{}"), revision: 0_i64)
        sink.emit(actor, "three", "view", "", JSON.parse("{}"), revision: 0_i64)
        sink.pending.should eq(2)
        sink.omitted.should eq(1)
        business = Channel(Nil).new(1)
        spawn do
          store.apply_effect(Fuel::Effect.new("grant", actor, "grant", JSON.parse("{}"), Time.utc.to_unix), WalletRules.new)
          business.send(nil)
        end
        ram_wait(business, "business commit waited for the validator")
        release.send(nil)
        deadline = Time.instant + 2.seconds
        while sink.pending > 0 && Time.instant < deadline
          sink.drain
          sleep 1.millisecond
        end
        sink.pending.should eq(0)
        delivered.should eq(2)
      ensure
        ram_release(release)
        store.close
      end
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

    it "freezes public action consent so disabled-interval facts cannot return after opt-in" do
      store = Fuel::Store.new(url, "ram_public_revision_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      proof = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      store.bootstrap(proof, "test")
      store.analytics_enabled(proof, false)
      started, release = Channel(Nil).new(1), Channel(Nil).new(1)
      delivered = 0
      sink = Fuel::Questmetry.new(store, {"reward_banked" => ["mode"]}, "test", "1.0",
        validate: ->(name : String, props : JSON::Any) { started.send(nil); release.receive; true }) { |_| delivered += 1; 202 }
      begin
        business = Channel(Nil).new(1)
        spawn do
          store.execute(proof, "grant", "grant", JSON.parse("{}"), RamPublicWallet.new, sink)
          business.send(nil)
        end
        ram_wait(business, "business commit waited for analytics admission")
        ram_wait(started, "server fact admission did not start")
        store.analytics_enabled(proof, true)
        release.send(nil)
        deadline = Time.instant + 3.seconds
        while sink.pending > 0 && Time.instant < deadline
          sink.drain
          sleep 1.millisecond
        end
        sink.pending.should eq(0)
        delivered.should eq(0)
        store.account(proof, WalletRules.new)["progress"]["coins"].as_i64.should eq(130)
      ensure
        ram_release(release)
        store.close
      end
    end

    it "does not reopen a closed Store after a deferred validator resumes" do
      store = Fuel::Store.new(url, "ram_closed_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      proof = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      actor = store.bootstrap(proof, "test")
      started, release = Channel(Nil).new(1), Channel(Nil).new(1)
      sink = Fuel::Questmetry.new(store, {"view" => [] of String}, "test", "1.0",
        validate: ->(name : String, props : JSON::Any) { started.send(nil); release.receive; true }) { |_| 202 }
      begin
        sink.emit(actor, "one", "view", "", JSON.parse("{}"), revision: 0_i64)
        ram_wait(started, "deferred validator did not start")
        store.close
        release.send(nil)
        deadline = Time.instant + 3.seconds
        while sink.pending > 0 && Time.instant < deadline
          sleep 1.millisecond
        end
        store.db.pool.stats.open_connections.should eq(0)
        sink.pending.should eq(0)
      ensure
        ram_release(release)
        store.close
      end
    end

    it "drops server offers with an unknown consent snapshot" do
      store = Fuel::Store.new(url, "ram_unknown_revision_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      proof = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      actor = store.bootstrap(proof, "test")
      sink = Fuel::Questmetry.new(store, {"view" => [] of String}, "test", "1.0") { |_| 202 }
      sink.emit(actor, "one", "view", "", JSON.parse("{}"))
      sink.pending.should eq(0)
      store.close
    end

    [false, true].each do |initially_enabled|
      it "snapshots standalone consent before a suspended validator can be overtaken by opt-in (enabled=#{initially_enabled})" do
        store = Fuel::Store.new(url, "ram_capture_snapshot_#{Fuel.id}", "d" * 32, "p" * 32)
        store.migrate
        proof = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
        store.bootstrap(proof, "test")
        store.analytics_enabled(proof, false) unless initially_enabled
        started, release = Channel(Nil).new(1), Channel(Nil).new(1)
        result = Channel(String).new(1)
        sent = 0
        sink = Fuel::Questmetry.new(store, {"view" => [] of String}, "test", "1.0",
          validate: ->(name : String, props : JSON::Any) { started.send(nil); release.receive; true }) { |_| sent += 1; 202 }
        begin
          spawn { result.send(sink.capture(proof, "one", "view", "", JSON.parse("{}"))) }
          first = select
          when started.receive then "validating"
          when value = result.receive then value
          when timeout(3.seconds) then "timeout"
          end
          store.analytics_enabled(proof, false) if initially_enabled
          store.analytics_enabled(proof, true)
          release.send(nil)
          status = if first == "validating"
                     select
                     when value = result.receive then value
                     when timeout(3.seconds) then "timeout"
                     end
                   else
                     first
                   end
          sink.drain
          status.should eq(initially_enabled ? "stale" : "disabled")
          sent.should eq(0)
        ensure
          ram_release(release)
          store.close
        end
      end
    end

    it "treats schema validation as a predicate over a copy of the frozen payload" do
      store = Fuel::Store.new(url, "ram_validator_copy_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      proof = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      store.bootstrap(proof, "test")
      delivered = [] of JSON::Any
      sink = Fuel::Questmetry.new(store, {"view" => ["kind"]}, "test", "1.0",
        validate: ->(name : String, props : JSON::Any) {
          props.as_h["kind"] = JSON::Any.new("x" * 300_000)
          props.as_h["not_allowed"] = JSON::Any.new(true)
          true
        }) { |body| delivered.concat(JSON.parse(body)["events"].as_a); 202 }
      begin
        sink.capture(proof, "one", "view", "", Fuel.json({kind: "small"})).should eq("queued")
        sink.drain
        delivered.first.to_json.bytesize.should be < 4096
        delivered.first["properties"].should eq(Fuel.json({kind: "small"}))
      ensure
        store.close
      end
    end
  end
end
