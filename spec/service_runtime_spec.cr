require "./effects_spec"

class RuntimeProbeStore < Fuel::Store
  property offline = false

  def available? : Bool
    raise "simulated database outage" if @offline
    super
  end
end

class LegacyCompletionRules < EffectRules
  def effects(state : JSON::Any, now : Int64) : Array(Fuel::Effect)
    [] of Fuel::Effect
  end

  def result(state : JSON::Any, actor : String) : Fuel::GameResult?
    Fuel::GameResult.new("counter", 1_i64, "Player", JSON.parse("{}")) if state["value"].as_i64 > 0
  end
end

class WaitingWalletRules < WalletRules
  getter entered = Channel(Nil).new(1)
  getter release = Channel(Nil).new(1)

  def public_action?(name : String) : Bool
    name == "grant"
  end

  def apply(tx : Fuel::AccountTransaction, actor : String, action : String, payload : JSON::Any, now : Int64) : JSON::Any
    @entered.send(nil)
    @release.receive
    super
  end
end

if url = ENV["FUEL_TEST_DATABASE_URL"]?
  describe "shared service runtime" do
    it "cannot replace a drained process with an unsettled completion result" do
      store = Fuel::Store.new(url, "legacy_drain_#{Fuel.id}", "d" * 32, "p" * 32)
      sessions = Fuel::Sessions.new(LegacyCompletionRules.new)
      room = sessions.create("alice", "solo", 1)
      room.command("alice", room.epoch, "finish", 0_i64, Fuel.json({id: "finish"}))
      room.finished?.should be_true
      room.pending_result?.should be_true
      runtime = Fuel::Runtime.new(store, sessions, Fuel::Handler.new(store, sessions, [] of String), WalletRules.new)
      runtime.drain
      state = runtime.health
      state["active_sessions"].as_i.should eq(0)
      state["pending_work"].as_i.should eq(1)
      state["safe_to_replace"].as_bool.should be_false
      runtime.stop
      store.close
    end

    it "serves later rooms while the first worker batch keeps producing effects" do
      store = Fuel::Store.new(url, "runtime_fair_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      actors = Array.new(9) do
        store.bootstrap(Fuel::Credential.new(Fuel.id, Random::Secure.hex(32)), Fuel.id)
      end
      sessions = Fuel::Sessions.new(EffectRules.new)
      rooms = actors.map { |actor| sessions.create(actor, "solo", 1) }
      runtime = Fuel::Runtime.new(store, sessions, Fuel::Handler.new(store, sessions, [] of String), WalletRules.new)
      begin
        3.times do |round|
          actors.zip(rooms).each do |actor, room|
            if room.pending_effects == 0
              room.command(actor, room.epoch, "grant#{round}", room.snapshot(actor)["revision"].as_s.to_i64, Fuel.json({id: "grant#{round}"}))
            end
          end
          runtime.pump_effects.should eq(8)
          deadline = Time.instant + 3.seconds
          until runtime.health["inflight"].as_i == 0 || Time.instant > deadline
            sleep 1.millisecond
          end
          runtime.health["inflight"].as_i.should eq(0)
        end
        rooms.last.snapshot(actors.last)["receipt_cursor"].as_s.to_i64.should be > 0
      ensure
        runtime.stop
        store.close
      end
    end

    it "does not report a drained replacement safe while an admitted HTTP write is in flight" do
      store = Fuel::Store.new(url, "drain_http_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      proof = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      store.bootstrap(proof, "test")
      sessions = Fuel::Sessions.new(EffectRules.new)
      rules = WaitingWalletRules.new
      runtime = Fuel::Runtime.new(store, sessions, Fuel::Handler.new(store, sessions, [] of String, account_rules: rules), rules)
      address = runtime.server.bind_tcp("127.0.0.1", 0)
      spawn { runtime.server.listen }
      completed = Channel(Int32).new(1)
      headers = HTTP::Headers{"Authorization" => "Fuel #{proof.id}:#{proof.secret}"}
      spawn do
        completed.send(HTTP::Client.post("http://#{address}/fuel/v1/actions", headers, {id: "grant", action: "grant", payload: JSON.parse("{}")}.to_json).status_code)
      end
      rules.entered.receive
      runtime.drain
      state = runtime.health
      state["inflight"].as_i.should eq(1)
      state["safe_to_replace"].as_bool.should be_false
      rules.release.send(nil)
      completed.receive.should eq(200)
      runtime.health["safe_to_replace"].as_bool.should be_true
      runtime.stop
      store.close
    end
    it "settles without sockets, drains, and requires a healthy database for replacement" do
      store = RuntimeProbeStore.new(url, "runtime_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      credential = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      actor = store.bootstrap(credential, "test")
      sessions = Fuel::Sessions.new(EffectRules.new)
      room = sessions.create(actor, "solo", 1)
      handler = Fuel::Handler.new(store, sessions, [] of String, account_rules: WalletRules.new)
      runtime = Fuel::Runtime.new(store, sessions, handler, WalletRules.new)
      room.command(actor, room.epoch, "one", 0_i64, Fuel.json({id: "one"}))
      runtime.drain
      runtime.health["safe_to_replace"].as_bool.should be_false
      runtime.pump_effects.should eq(1)
      deadline = Time.instant + 3.seconds
      until room.pending_effects == 0 || Time.instant > deadline
        sleep 1.millisecond
      end
      room.pending_effects.should eq(0)
      store.account(credential, WalletRules.new)["progress"]["coins"].as_i64.should eq(130)
      room.leave(actor)
      runtime.health["safe_to_replace"].as_bool.should be_true
      runtime.resume
      runtime.health["safe_to_replace"].as_bool.should be_false
      runtime.drain
      store.offline = true
      runtime.health["database"].as_bool.should be_false
      runtime.health["safe_to_replace"].as_bool.should be_false
      runtime.stop
      store.close
    end

    it "lets an unrelated room commit while one effect waits on its account lock" do
      store = Fuel::Store.new(url, "runtime_parallel_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      credentials = Array.new(2) { Fuel::Credential.new(Fuel.id, Random::Secure.hex(32)) }
      actors = credentials.map { |credential| store.bootstrap(credential, Fuel.id) }
      sessions = Fuel::Sessions.new(EffectRules.new)
      rooms = actors.map { |actor| sessions.create(actor, "solo", 1) }
      runtime = Fuel::Runtime.new(store, sessions, Fuel::Handler.new(store, sessions, [] of String), WalletRules.new)
      actors.zip(rooms).each { |actor, room| room.command(actor, room.epoch, "grant", 0_i64, Fuel.json({id: "grant"})) }
      store.db.transaction do |tx|
        tx.connection.query_one("SELECT id FROM fuel_accounts WHERE ns=$1 AND id=$2 FOR UPDATE", store.namespace, actors[0], as: String)
        runtime.pump_effects.should eq(2)
        deadline = Time.instant + 3.seconds
        until rooms[1].pending_effects == 0 || Time.instant > deadline
          sleep 1.millisecond
        end
        rooms[1].pending_effects.should eq(0)
        rooms[0].pending_effects.should eq(1)
      end
      deadline = Time.instant + 3.seconds
      until rooms[0].pending_effects == 0 || Time.instant > deadline
        sleep 1.millisecond
      end
      rooms[0].pending_effects.should eq(0)
      runtime.stop
      store.close
    end
  end
end
