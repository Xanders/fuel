require "./effects_spec"

class MilestoneRules < Fuel::Rules
  def initial : JSON::Any
    Fuel.json({value: 0})
  end

  def apply(state : JSON::Any, actor : String, action : JSON::Any) : JSON::Any
    state.as_h["value"] = JSON::Any.new(state["value"].as_i64 + 1_i64)
    state
  end

  def apply(state : JSON::Any, actor : String, action : JSON::Any, events : Fuel::SessionEvents) : JSON::Any
    events.once(action["subject"]?.try(&.as_s) || actor, action["event"].as_s, Fuel.json({mode: "duel"}), action["key"]?.try(&.as_s) || "")
    apply(state, actor, action)
  end

  def project(state : JSON::Any, actor : String) : JSON::Any
    state
  end
end

class MilestoneResultRules < MilestoneRules
  def result(state : JSON::Any, actor : String) : Fuel::GameResult?
    if state["value"].as_i64 > 0
      Fuel::GameResult.new("milestone", 1_i64, "Player", Fuel.json({completed: true}))
    end
  end
end

class MilestoneLeaveRules < MilestoneRules
  def leave(state : JSON::Any, actor : String, events : Fuel::SessionEvents) : JSON::Any
    events.once(actor, "session_left", JSON.parse("{}"))
    state
  end
end

class InvalidMetricMilestoneRules < MilestoneRules
  def initialize(@actor : String)
  end

  def apply(state : JSON::Any, actor : String, action : JSON::Any, events : Fuel::SessionEvents) : JSON::Any
    events.once(actor, "metric", JSON::Any.new({"metric" => JSON::Any.new(Float64::NAN)}))
    apply(state, actor, action)
  end

  def tick(state : JSON::Any, dt : Time::Span, events : Fuel::SessionEvents) : JSON::Any
    events.once(@actor, "metric", JSON::Any.new({"metric" => JSON::Any.new(Float64::NAN)}))
    state.as_h["value"] = JSON::Any.new(state["value"].as_i64 + 1_i64)
    state
  end
end

class InvalidMetricWalletRules < WalletRules
  def apply(tx : Fuel::AccountTransaction, actor : String, action : String, payload : JSON::Any, now : Int64) : JSON::Any
    reply = super
    tx.event(actor, "metric", "", JSON::Any.new({"metric" => JSON::Any.new(Float64::NAN)}), now)
    tx.events.should be_empty
    reply
  end
end

describe "invalid telemetry JSON isolation" do
  it "keeps a room command successful and drops its non-finite analytics metric" do
    actor = Fuel.id
    room = Fuel::Room.new(InvalidMetricMilestoneRules.new(actor), actor, "solo", 1, false)
    room.command(actor, room.epoch, "one", 0_i64, JSON.parse("{}"))
    room.snapshot(actor)["state"]["value"].as_i64.should eq(1)
    room.drain_events.should be_empty
  end

  it "keeps a room tick successful and drops its non-finite analytics metric" do
    actor = Fuel.id
    room = Fuel::Room.new(InvalidMetricMilestoneRules.new(actor), actor, "solo", 1, false)
    room.ready(actor)
    room.tick(50.milliseconds)
    room.snapshot(actor)["state"]["value"].as_i64.should eq(1)
    room.drain_events.should be_empty
  end
end

describe "best-effort room milestones" do
  it "does not block valid commands or session departure when analytics is absent" do
    actor = Fuel.id
    room = Fuel::Room.new(MilestoneRules.new, actor, "solo", 1, false, effect_limit: 1)
    room.command(actor, room.epoch, "one", 0_i64, Fuel.json({event: "run_started"}))
    room.command(actor, room.epoch, "repeat", 1_i64, Fuel.json({event: "run_started"}))
    room.command(actor, room.epoch, "next", 2_i64, Fuel.json({event: "objective_reached"}))
    snapshot = room.snapshot(actor)
    snapshot["state"]["value"].as_i64.should eq(3)
    snapshot["saving_backlog"].as_bool.should be_false
    snapshot["receipts"].as_a.should be_empty
    room.pending_effects.should eq(0)
    room.pending_work.should eq(0)
    room.leave(actor)
    room.disposable?.should be_true
  end

  it "drops excess analytics rather than rejecting gameplay at the once-ID limit" do
    actor = Fuel.id
    room = Fuel::Room.new(MilestoneRules.new, actor, "solo", 1, false)
    16_385.times do |index|
      room.command(actor, room.epoch, "c#{index}", index.to_i64,
        Fuel.json({event: "run_started", key: index.to_s}))
      room.drain_events(256) if index % 128 == 0
    end
    room.snapshot(actor)["state"]["value"].as_i64.should eq(16_385)
    room.pending_effects.should eq(0)
    room.leave(actor)
    room.disposable?.should be_true
  end

  it "deduplicates once IDs across RAM drains and bounds pending facts" do
    actor = Fuel.id
    room = Fuel::Room.new(MilestoneRules.new, actor, "solo", 1, false)
    room.command(actor, room.epoch, "one", 0_i64, Fuel.json({event: "run_started"}))
    facts = room.drain_events
    facts.size.should eq(1)
    facts.first.name.should eq("run_started")
    facts.first.id.should start_with(room.epoch)
    room.command(actor, room.epoch, "repeat", 1_i64, Fuel.json({event: "run_started"}))
    room.drain_events.should be_empty
    300.times do |index|
      room.command(actor, room.epoch, "e#{index}", (index + 2).to_i64,
        Fuel.json({event: "objective_reached", key: index.to_s}))
    end
    room.drain_events(1000).size.should eq(256)
    room.pending_work.should eq(0)
    room.command(actor, room.epoch, "dropped-repeat", 302_i64,
      Fuel.json({event: "objective_reached", key: "299"}))
    room.drain_events.should be_empty
  end

  it "drops malformed milestones without rejecting a valid command" do
    actor = Fuel.id
    room = Fuel::Room.new(MilestoneRules.new, actor, "solo", 1, false)
    room.command(actor, room.epoch, "bad-name", 0_i64, Fuel.json({event: "invalid name"}))
    room.command(actor, room.epoch, "bad-key", 1_i64, Fuel.json({event: "run_started", key: "x" * 101}))
    room.snapshot(actor)["state"]["value"].as_i64.should eq(2)
    room.drain_events.should be_empty
  end

  it "drops an oversized milestone subject while accepting the gameplay command" do
    actor = Fuel.id
    room = Fuel::Room.new(MilestoneRules.new, actor, "solo", 1, false)
    room.command(actor, room.epoch, "large-subject", 0_i64,
      Fuel.json({event: "run_started", subject: "a" * 10_000}))
    room.snapshot(actor)["state"]["value"].as_i64.should eq(1)
    room.drain_events.should be_empty
  end
end

if url = ENV["FUEL_TEST_DATABASE_URL"]?
  describe "invalid telemetry JSON isolation" do
    it "commits a reward, progress and its receipt despite a non-finite analytics metric" do
      store = Fuel::Store.new(url, "invalid_metric_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      credential = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      actor = store.bootstrap(credential, "test")
      begin
        effect = Fuel::Effect.new("grant", actor, "grant", JSON.parse("{}"), Time.utc.to_unix)
        receipt = store.apply_effect(effect, InvalidMetricWalletRules.new)
        receipt["reply"]["coins"].as_i64.should eq(130)
        store.progress(credential)["coins"].as_i64.should eq(130)
        store.operation(credential, "grant")["reply"]["coins"].as_i64.should eq(130)
      ensure
        store.close
      end
    end
  end

  describe "analytics Store lifetime" do
    it "closes an actual second admission connection while its SQL is blocked" do
      store = Fuel::Store.new(url, "analytics_owned_connection_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      credential = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      actor = store.bootstrap(credential, "test")
      first = store.db.checkout
      blocker = DB.open(url)
      checked_out = Channel(DB::Connection).new(1)
      finished = Channel(Nil).new(1)
      begin
        blocker.transaction do |transaction|
          transaction.connection.query_one("SELECT id FROM fuel_accounts WHERE ns=$1 AND id=$2 FOR UPDATE", store.namespace, actor, as: String)
          spawn do
            begin
              store.with_analytics_admission do |connection|
                checked_out.send(connection)
                connection.query_one("SELECT analytics_revision FROM fuel_accounts WHERE ns=$1 AND id=$2 FOR UPDATE", store.namespace, actor, as: Int64)
              end
            rescue
              # Closing disposable admission is allowed to interrupt its query.
            ensure
              finished.send(nil)
            end
          end
          connection = select
          when handle = checked_out.receive
            handle
          when timeout(3.seconds)
            fail "analytics connection was not checked out"
          end
          store.close
          connection.closed?.should be_true
        end
        select
        when finished.receive
        when timeout(3.seconds)
          fail "closed analytics admission did not exit"
        end
      ensure
        first.close
        first.release
        blocker.close
        store.close
      end
    end
  end

  describe "milestones independent of analytics delivery" do
    it "keeps the result consent revision from creation across a later room preference refresh" do
      store = Fuel::Store.new(url, "result_consent_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      credential = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      actor = store.bootstrap(credential, "test")
      revision = store.analytics_enabled(credential, false)
      bodies = [] of String
      analytics = Fuel::Questmetry.new(store, {"session_finished" => [] of String}, "test", "0.3.14") { |body| bodies << body; 202 }
      room = Fuel::Room.new(MilestoneResultRules.new, actor, "solo", 1, false, preferences: {actor => revision})
      begin
        room.command(actor, room.epoch, "finish", 0_i64, Fuel.json({event: "run_started"}))
        room.preference(actor, store.analytics_enabled(credential, true))
        room.persist_result(store, credential, analytics)
        deadline = Time.instant + 3.seconds
        until analytics.pending == 0
          fail "result analytics admission did not settle" if Time.instant >= deadline
          sleep 1.millisecond
        end
        analytics.drain
        bodies.should be_empty
        store.progress(credential)["completed"].as_bool.should be_true
        room.pending_result?.should be_false
      ensure
        store.close
      end
    end

    it "delivers a final leave fact after cleanup or immediate room replacement" do
      [false, true].each do |cleanup|
        store = Fuel::Store.new(url, "leave_handoff_#{Fuel.id}", "d" * 32, "p" * 32)
        store.migrate
        credential = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
        actor = store.bootstrap(credential, "test")
        bodies = [] of JSON::Any
        analytics = Fuel::Questmetry.new(store, {"session_left" => [] of String}, "test", "0.3.14") { |body| bodies.concat(JSON.parse(body)["events"].as_a); 202 }
        sessions = Fuel::Sessions.new(MilestoneLeaveRules.new, max_rooms: 1)
        room = sessions.create(actor, "solo", 1, preferences: {actor => 0_i64})
        rules = WalletRules.new
        handler = Fuel::Handler.new(store, sessions, [] of String, analytics, account_rules: rules)
        runtime = Fuel::Runtime.new(store, sessions, handler, rules, analytics)
        begin
          room.leave(actor)
          sessions.cleanup if cleanup
          sessions.create(actor, "solo", 1, preferences: {actor => 0_i64})
          runtime.pump_analytics
          deadline = Time.instant + 3.seconds
          until bodies.size == 1
            fail "final leave fact was lost on room disposal" if Time.instant >= deadline
            analytics.drain
            sleep 1.millisecond
          end
          bodies.first["name"].as_s.should eq("session_left")
          store.db.query_one("SELECT count(*) FROM fuel_operations WHERE ns=$1", store.namespace, as: Int64).should eq(0)
        ensure
          runtime.stop
          store.close
        end
      end
    end

    it "keeps results and progress committed when analytics validation fails" do
      store = Fuel::Store.new(url, "milestone_result_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      credential = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      actor = store.bootstrap(credential, "test")
      rejected = Channel(Nil).new(1)
      analytics = Fuel::Questmetry.new(store, {"session_finished" => [] of String}, "test", "0.3.14",
        validate: ->(name : String, properties : JSON::Any) { rejected.send(nil); false }) { |_| 503 }
      room = Fuel::Room.new(MilestoneResultRules.new, actor, "solo", 1, false, preferences: {actor => 0_i64})
      begin
        room.command(actor, room.epoch, "finish", 0_i64, Fuel.json({event: "run_started"}))
        room.persist_result(store, credential, analytics)
        select
        when rejected.receive
        when timeout(3.seconds)
          fail "result analytics admission was not attempted"
        end
        store.progress(credential)["completed"].as_bool.should be_true
        store.leaderboard("milestone").first["score"].as_s.should eq("1")
        room.pending_result?.should be_false
        room.persist_result(store, credential, analytics)
        store.db.query_one("SELECT count(*) FROM fuel_results WHERE ns=$1", store.namespace, as: Int64).should eq(1)
        room.leave(actor)
        deadline = Time.instant + 3.seconds
        until analytics.pending == 0
          fail "analytics admission did not settle" if Time.instant >= deadline
          sleep 1.millisecond
        end
        recovered = Fuel::Room.new(MilestoneResultRules.new, actor, "solo", 1, false, preferences: {actor => 0_i64})
        recovered.command(actor, recovered.epoch, "finish", 0_i64, Fuel.json({event: "run_started"}))
        store.record_result(credential, recovered.id, "milestone", 1_i64, "Player", Fuel.json({completed: true}))
        recovered.persist_result(store, credential, analytics)
        analytics.pending.should eq(0)
        recovered.pending_result?.should be_false
        recovered.leave(actor)
      ensure
        store.close
      end
    end

    it "leaves business health, commands and departure available while a full sink is stalled" do
      store = Fuel::Store.new(url, "milestone_delivery_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      credential = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      actor = store.bootstrap(credential, "test")
      started = Channel(Nil).new(1)
      release = Channel(Nil).new(1)
      completed = Channel(Nil).new(1)
      analytics = Fuel::Questmetry.new(store, {"run_started" => ["mode"]}, "test", "0.3.14", max_pending: 1) do |_|
        started.send(nil)
        release.receive
        completed.send(nil)
        503
      end
      sessions = Fuel::Sessions.new(MilestoneRules.new)
      room = sessions.create(actor, "solo", 1)
      rules = WalletRules.new
      handler = Fuel::Handler.new(store, sessions, [] of String, analytics, account_rules: rules)
      runtime = Fuel::Runtime.new(store, sessions, handler, rules, analytics)
      begin
        analytics.capture(credential, "prefill", "run_started", room.id, Fuel.json({mode: "duel"}))
        room.command(actor, room.epoch, "one", 0_i64, Fuel.json({event: "run_started"}))
        runtime.pump_analytics
        select
        when started.receive
        when timeout(3.seconds)
          fail "analytics attempt did not start"
        end
        room.command(actor, room.epoch, "next", 1_i64, Fuel.json({event: "run_started", key: "next"}))
        room.snapshot(actor)["state"]["value"].as_i64.should eq(2)
        room.pending_work.should eq(0)
        room.leave(actor)
        runtime.drain
        runtime.health["safe_to_replace"].as_bool.should be_true
        store.db.query_one("SELECT count(*) FROM fuel_operations WHERE ns=$1", store.namespace, as: Int64).should eq(0)
        runtime.stop
      ensure
        release.send(nil)
        select
        when completed.receive
        when timeout(3.seconds)
        end
        runtime.stop
        store.close
      end
    end
  end
end
