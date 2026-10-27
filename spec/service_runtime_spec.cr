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

class WakeWalletRules < WalletRules
  getter attempts = [] of Tuple(String, Time::Instant)

  def initialize(@retry_actor : String)
  end

  def apply(tx : Fuel::AccountTransaction, actor : String, action : String, payload : JSON::Any, now : Int64) : JSON::Any
    @attempts << {actor, Time.instant}
    raise "temporary failure" if actor == @retry_actor && @attempts.count { |attempt| attempt[0] == actor } == 1
    super
  end
end

if url = ENV["FUEL_TEST_DATABASE_URL"]?
  describe "shared service runtime" do
    it "cannot start queued effects after stop" do
      store = Fuel::Store.new(url, "runtime_stopped_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      actor = store.bootstrap(Fuel::Credential.new(Fuel.id, Random::Secure.hex(32)), Fuel.id)
      sessions = Fuel::Sessions.new(EffectRules.new)
      room = sessions.create(actor, "solo", 1)
      room.command(actor, room.epoch, "pending", 0_i64, Fuel.json({id: "pending"}))
      runtime = Fuel::Runtime.new(store, sessions, Fuel::Handler.new(store, sessions, [] of String), WalletRules.new)
      runtime.stop
      begin
        runtime.pump_effects.should eq(0)
        room.pending_effects.should eq(1)
      ensure
        deadline = Time.instant + 3.seconds
        until runtime.health["inflight"].as_i == 0 || Time.instant >= deadline
          sleep 1.millisecond
        end
        store.close
      end
    end

    it "continues queued effects on completion while preserving fairness and retry delay" do
      store = Fuel::Store.new(url, "runtime_wake_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      credentials = Array.new(2) { Fuel::Credential.new(Fuel.id, Random::Secure.hex(32)) }
      actors = credentials.map { |credential| store.bootstrap(credential, Fuel.id) }
      sessions = Fuel::Sessions.new(EffectRules.new)
      rooms = actors.map { |actor| sessions.create(actor, "solo", 1) }
      24.times do |index|
        rooms[0].command(actors[0], rooms[0].epoch, "queued_#{index}", rooms[0].snapshot(actors[0])["revision"].as_s.to_i64, Fuel.json({id: "queued_#{index}"}))
      end
      rooms[1].command(actors[1], rooms[1].epoch, "other", 0_i64, Fuel.json({id: "other"}))
      rules = WakeWalletRules.new(actors[0])
      runtime = Fuel::Runtime.new(store, sessions, Fuel::Handler.new(store, sessions, [] of String), rules, worker_limit: 1)
      runtime.server.bind_tcp("127.0.0.1", 0)
      completed = Channel(Exception?).new(1)
      spawn do
        runtime.listen
        completed.send(nil)
      rescue error
        completed.send(error)
      end
      begin
        # A discovery-only 250ms cadence takes over six seconds for this queue.
        # This deadline checks scheduling, not a game latency guarantee.
        deadline = Time.instant + 3.seconds
        until rooms.all? { |room| room.pending_effects == 0 } || Time.instant >= deadline
          sleep 1.millisecond
        end
        rooms.map(&.pending_effects).should eq([0, 0])
        rules.attempts.first(2).map(&.[0]).should eq(actors)
        retry_times = rules.attempts.select { |attempt| attempt[0] == actors[0] }.map(&.[1])
        (retry_times[1] - retry_times[0]).should be >= 1.second
        store.progress(credentials[0])["coins"].as_i64.should eq(820)
        store.progress(credentials[1])["coins"].as_i64.should eq(130)
        store.operations(credentials[0], after: "0").map(&.["operation_id"].as_s).should eq(
          Array.new(24) { |index| "#{rooms[0].epoch}-queued_#{index}" })
      ensure
        runtime.stop
        error = completed.receive
        store.close
        raise error if error
      end
      runtime.health["inflight"].as_i.should eq(0)
    end

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
