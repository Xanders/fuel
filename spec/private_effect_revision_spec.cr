require "./session_spec"
require "./effects_spec"

class HiddenMilestoneRules < HiddenRules
  def join(state : JSON::Any, actor : String, progress : JSON::Any, events : Fuel::SessionEvents) : JSON::Any
    events.once(actor, "joined", JSON.parse("{}"))
    state
  end

  def apply(state : JSON::Any, actor : String, action : JSON::Any, events : Fuel::SessionEvents) : JSON::Any
    events.once(actor, action["event"].as_s, JSON.parse("{}"))
    apply(state, actor, action)
  end
end

class InvisibleEffectRules < EffectRules
  def project(state : JSON::Any, actor : String) : JSON::Any
    Fuel.json({value: 0})
  end
end

def finish_milestones(room)
  while effect = room.begin_effect
    effect.action.should eq("_fuel_event")
    room.finish_effect(effect, {effect.actor => Fuel.json({source: "event", reply: {status: "recorded"}})})
  end
end

describe "settlement publication" do
  it "keeps unrelated private revisions unchanged after analytics-only acknowledgement" do
    room = Fuel::Room.new(HiddenMilestoneRules.new, "alice", "duel", 2, false)
    room.join(["bob"])
    room.pending_effects.should eq(2)
    finish_milestones(room)
    before = room.snapshot("bob")
    revision = room.snapshot("alice")["revision"].as_s.to_i64
    room.command("alice", room.epoch, "secret", revision, Fuel.json({amount: 1, event: "choice_committed"}))
    room.snapshot("bob")["revision"].should eq(before["revision"])
    alice_revision = room.snapshot("alice")["revision"]
    finish_milestones(room)
    after = room.snapshot("bob")
    after["state"].should eq(before["state"])
    after["revision"].should eq(before["revision"])
    after["receipt_cursor"].should eq(before["receipt_cursor"])
    after["receipts"].as_a.should be_empty
    room.snapshot("alice")["revision"].should eq(alice_revision)
    room.command("bob", room.epoch, "own", before["revision"].as_s.to_i64, Fuel.json({amount: 1, event: "own_choice"}))
  end

  it "publishes a receipt only to its recipient when projections are unchanged" do
    room = Fuel::Room.new(InvisibleEffectRules.new, "alice", "duel", 2, false)
    room.join(["bob"])
    revision = room.snapshot("alice")["revision"].as_s.to_i64
    room.command("alice", room.epoch, "grant", revision, Fuel.json({id: "grant"}))
    before_alice = room.snapshot("alice")
    before_bob = room.snapshot("bob")
    effect = room.begin_effect.not_nil!
    room.finish_effect(effect, {"alice" => Fuel.json({source: "effect", reply: {status: "committed"}})})
    alice = room.snapshot("alice")
    alice["revision"].as_s.to_i64.should be > before_alice["revision"].as_s.to_i64
    alice["receipt_cursor"].as_s.should eq("1")
    alice["receipts"].as_a.size.should eq(1)
    room.snapshot("bob")["revision"].should eq(before_bob["revision"])
  end

  it "publishes receipts to every affected participant" do
    room = Fuel::Room.new(InvisibleEffectRules.new, "alice", "duel", 2, false)
    room.join(["bob"])
    room.command("alice", room.epoch, "grant", room.snapshot("alice")["revision"].as_s.to_i64, Fuel.json({id: "grant"}))
    before = ["alice", "bob"].to_h { |actor| {actor, room.snapshot(actor)["revision"].as_s.to_i64} }
    effect = room.begin_effect.not_nil!
    receipt = Fuel.json({source: "effect", reply: {status: "committed"}})
    room.finish_effect(effect, {"alice" => receipt, "bob" => receipt})
    before.each do |actor, revision|
      snapshot = room.snapshot(actor)
      snapshot["revision"].as_s.to_i64.should be > revision
      snapshot["receipt_cursor"].as_s.should eq("1")
    end
  end

  it "publishes clearing visible saving backpressure to all viewers" do
    room = Fuel::Room.new(HiddenMilestoneRules.new, "alice", "duel", 2, false, effect_limit: 2)
    room.join(["bob"])
    finish_milestones(room)
    ["first", "second"].each do |name|
      room.command("alice", room.epoch, name, room.snapshot("alice")["revision"].as_s.to_i64, Fuel.json({amount: 1, event: name}))
    end
    expect_raises(Fuel::Error, "saving_backlog") do
      room.command("alice", room.epoch, "third", room.snapshot("alice")["revision"].as_s.to_i64, Fuel.json({amount: 1, event: "third"}))
    end
    before = room.snapshot("bob")
    before["saving_backlog"].as_bool.should be_true
    effect = room.begin_effect.not_nil!
    room.finish_effect(effect, {"alice" => Fuel.json({source: "event", reply: {status: "recorded"}})})
    after = room.snapshot("bob")
    after["saving_backlog"].as_bool.should be_false
    after["state"].should eq(before["state"])
    after["revision"].as_s.to_i64.should be > before["revision"].as_s.to_i64
  end
end
