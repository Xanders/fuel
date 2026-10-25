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
    events.once(actor, action["event"].as_s, Fuel.json({mode: "duel"}))
    apply(state, actor, action)
  end

  def project(state : JSON::Any, actor : String) : JSON::Any
    state
  end
end

if url = ENV["FUEL_TEST_DATABASE_URL"]?
  describe "framework-owned milestone buffering" do
    it "deduplicates facts, atomically backpressures, and delivers without invoking game actions" do
      store = Fuel::Store.new(url, "milestones_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      credential = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      actor = store.bootstrap(credential, "test")
      analytics = Fuel::Questmetry.new(store, {"run_started" => ["mode"], "objective_reached" => ["mode"]}, "test", "0.3.0") { |_| 202 }
      room = Fuel::Room.new(MilestoneRules.new, actor, "solo", 1, false, effect_limit: 1, preferences: {actor => 0_i64})
      room.command(actor, room.epoch, "one", 0_i64, Fuel.json({event: "run_started"}))
      room.command(actor, room.epoch, "repeat", 1_i64, Fuel.json({event: "run_started"}))
      room.pending_effects.should eq(1)
      expect_raises(Fuel::Error, "saving_backlog") { room.command(actor, room.epoch, "next", 2_i64, Fuel.json({event: "objective_reached"})) }
      room.snapshot(actor)["state"]["value"].as_i64.should eq(2)
      first = room.begin_effect.not_nil!
      receipt = store.apply_effect(first, WalletRules.new, analytics)
      receipt["source"].as_s.should eq("event")
      room.finish_effect(first, store.effect_receipts(first))
      room.snapshot(actor)["receipts"].as_a.should be_empty
      revision = room.snapshot(actor)["revision"].as_s.to_i64
      room.command(actor, room.epoch, "next", revision, Fuel.json({event: "objective_reached"}))
      second = room.begin_effect.not_nil!
      store.apply_effect(second, WalletRules.new, analytics)
      room.finish_effect(second, store.effect_receipts(second))
      room.pending_effects.should eq(0)
      store.db.query_one("SELECT count(*) FROM fuel_outbox WHERE ns=$1", store.namespace, as: Int64).should eq(2)
      expect_raises(Fuel::Error, "forbidden") { store.execute(credential, Fuel.id, "_fuel_event", Fuel.json({name: "run_started", properties: {mode: "duel"}}), WalletRules.new, analytics) }
      store.close
    end
  end
end
