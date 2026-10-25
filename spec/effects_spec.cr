require "./account_spec"

class EffectRules < Fuel::Rules
  def initial : JSON::Any
    Fuel.json({value: 0, pending: [] of JSON::Any})
  end

  def apply(state : JSON::Any, actor : String, action : JSON::Any) : JSON::Any
    state.as_h["value"] = JSON::Any.new(state["value"].as_i64 + 1_i64)
    state["pending"].as_a << Fuel.json({id: action["id"], actor: actor, action: "grant"})
    state
  end

  def project(state : JSON::Any, actor : String) : JSON::Any
    Fuel.json({value: state["value"]})
  end

  def effects(state : JSON::Any, now : Int64) : Array(Fuel::Effect)
    state["pending"].as_a.map { |item| Fuel::Effect.new(item["id"].as_s, item["actor"].as_s, item["action"].as_s, JSON.parse("{}"), now) }
  end

  def acknowledge(state : JSON::Any, effect : Fuel::Effect, receipt : JSON::Any) : JSON::Any
    state["pending"].as_a.shift
    state
  end
end

class FinishedEffectRules < EffectRules
  def finished?(state : JSON::Any) : Bool
    state["value"].as_i64 > 0
  end
end

class DepartureEffectRules < EffectRules
  def leave(state : JSON::Any, actor : String) : JSON::Any
    apply(state, actor, Fuel.json({id: "departure"}))
  end
end

describe "bounded room effects" do
  it "bounds receipt bytes and leaves an explicit cursor gap for durable recovery" do
    actor = Fuel.id
    room = Fuel::Room.new(EffectRules.new, actor, "solo", 1, false)
    room.command(actor, room.epoch, "one", 0_i64, Fuel.json({id: "one"}))
    effect = room.begin_effect.not_nil!
    room.finish_effect(effect, {actor => Fuel.json({source: "effect", reply: {text: "x" * 20000}})})
    snapshot = room.snapshot(actor)
    snapshot.to_json.bytesize.should be < 17000
    snapshot["receipt_cursor"].as_s.should eq("1")
    snapshot["receipt_base"].as_s.should eq("2")
  end

  it "blocks new admission until a departure's persistent effect is settled" do
    actor = Fuel.id
    sessions = Fuel::Sessions.new(DepartureEffectRules.new, modes: {"solo" => Fuel::ModePolicy.new(1)})
    room = sessions.create(actor, "solo")
    sessions.mine(actor).first["session_id"].as_s.should eq(room.id)
    room.leave(actor)
    sessions.mine(actor).should be_empty
    expect_raises(Fuel::Error, "pending_result") { sessions.create(actor, "solo") }
    effect = room.begin_effect.not_nil!
    room.finish_effect(effect, {actor => Fuel.json({source: "effect", reply: {status: "committed"}})})
    sessions.create(actor, "solo").id.should_not eq(room.id)
  end
  it "owns idle departure, preserves pending work and fences an old socket's close" do
    actor = Fuel.id
    room = Fuel::Room.new(EffectRules.new, actor, "solo", 1, false)
    old = room.connect(actor)
    current = room.connect(actor)
    room.disconnect(actor, old)
    room.snapshot(actor, current)["last_input"].as_s.should eq("-1")
    room.command(actor, room.epoch, "one", 0_i64, Fuel.json({id: "one"}))
    room.disconnect(actor, current)
    room.expire_idle(0.seconds)
    room.member?(actor).should be_true
    room.pending_effects.should eq(1)
    effect = room.begin_effect.not_nil!
    room.finish_effect(effect, {actor => Fuel.json({source: "effect", operation_id: effect.id, reply: {status: "committed"}})})
    room.expire_idle(0.seconds)
    room.member?(actor).should be_false
    room.disposable?.should be_true
  end

  it "rejects new gameplay after a terminal rule state but retains an exact command receipt" do
    actor = Fuel.id
    room = Fuel::Room.new(FinishedEffectRules.new, actor, "solo", 1, false)
    action = Fuel.json({id: "one"})
    reply = room.command(actor, room.epoch, "one", 0_i64, action)
    room.command(actor, room.epoch, "one", 0_i64, action).should eq(reply)
    generation = room.connect(actor)
    expect_raises(Fuel::Error, "session_ended") { room.input(actor, generation, 1_i64, Fuel.json({id: "two"})) }
  end

  it "accepts state plus effects atomically, retaining work under saturation" do
    actor = Fuel.id
    room = Fuel::Room.new(EffectRules.new, actor, "solo", 1, false, effect_limit: 1)
    first = room.command(actor, room.epoch, "one", 0_i64, Fuel.json({id: "one"}))
    first["state"]["value"].as_i64.should eq(1)
    expect_raises(Fuel::Error, "saving_backlog") { room.command(actor, room.epoch, "two", 1_i64, Fuel.json({id: "two"})) }
    room.snapshot(actor)["state"]["value"].as_i64.should eq(1)
    room.snapshot(actor)["saving_backlog"].as_bool.should be_true
    room.pending_effects.should eq(1)
    room.disposable?.should be_false
    expect_raises(Fuel::Error, "pending_result") { room.leave(actor) }
  end
end

if url = ENV["FUEL_TEST_DATABASE_URL"]?
  describe "room effect commit and delivery" do
    it "keeps a failed head and replays a committed head before advancing later work" do
      store = Fuel::Store.new(url, "effects_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      credential = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      actor = store.bootstrap(credential, "test")
      room = Fuel::Room.new(EffectRules.new, actor, "solo", 1, false, effect_limit: 2, event_limit: 1)
      room.command(actor, room.epoch, "one", 0_i64, Fuel.json({id: "one"}))
      room.command(actor, room.epoch, "two", 1_i64, Fuel.json({id: "two"}))
      first = room.begin_effect.not_nil!
      room.begin_effect.should be_nil
      receipt = store.apply_effect(first, WalletRules.new)
      # The transaction committed, but its worker acknowledgement was lost.
      room.retry_effect(first)
      again = room.begin_effect.not_nil!
      again.id.should eq(first.id)
      store.apply_effect(again, WalletRules.new).should eq(receipt)
      room.finish_effect(again, {actor => receipt})
      second = room.begin_effect.not_nil!
      second.id.should_not eq(first.id)
      second_receipt = store.apply_effect(second, WalletRules.new)
      room.finish_effect(second, {actor => second_receipt})
      room.pending_effects.should eq(0)
      store.account(credential, WalletRules.new)["progress"]["coins"].as_i64.should eq(160)
      snapshot = room.snapshot(actor)
      snapshot["receipt_base"].as_s.should eq("2")
      snapshot["receipts"].as_a.size.should eq(1)
      store.operations(credential, after: "0").size.should eq(2)
      store.close
    end
  end
end
