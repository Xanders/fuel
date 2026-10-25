require "./session_spec"

class AdmissionRules < CounterRules
  def initial(context : Fuel::SessionContext) : JSON::Any
    Fuel.json({value: 0, mode: context.mode, epoch: context.epoch, members: {} of String => String})
  end

  def join(state : JSON::Any, actor : String, progress : JSON::Any) : JSON::Any
    Fuel.check(progress["active"].as_bool, "avatar_retired")
    state["members"].as_h[actor] = progress["generation"]
    state
  end

  def authorize(state : JSON::Any, actor : String, progress : JSON::Any) : Nil
    Fuel.check(progress["active"].as_bool && state["members"][actor] == progress["generation"], "stale_avatar")
  end

  def leave(state : JSON::Any, actor : String) : JSON::Any
    state["members"].as_h.delete(actor)
    state
  end
end

describe "canonical session admission" do
  it "matches using current guarded profiles and rolls back failed group admission" do
    sessions = Fuel::Sessions.new(AdmissionRules.new, modes: {"duel" => Fuel::ModePolicy.new(2)})
    valid = Fuel.json({active: true, generation: "first"})
    invalid = Fuel.json({active: false, generation: "first"})
    sessions.match("alice", "duel", "a", profiles: {"alice" => valid})["status"].as_s.should eq("waiting")
    sessions.match_candidates("duel").should eq(["alice"])
    expect_raises(Fuel::Error, "avatar_retired") do
      sessions.match("bob", "duel", "b", profiles: {"alice" => invalid, "bob" => valid})
    end
    result = sessions.match("bob", "duel", "b", profiles: {"alice" => valid, "bob" => valid})
    result["status"].as_s.should eq("matched")
    sessions.get(result["session_id"].as_s).members.sort.should eq(["alice", "bob"])
  end

  it "owns shared modes, fixed capacities, exclusive membership and fresh avatar checks" do
    modes = {"hub" => Fuel::ModePolicy.new(2, shared: true), "solo" => Fuel::ModePolicy.new(1)}
    sessions = Fuel::Sessions.new(AdmissionRules.new, modes: modes)
    progress = Fuel.json({active: true, generation: "first"})
    hub = sessions.create("alice", "hub", progress: progress)
    sessions.create("bob", "hub", progress: progress).id.should eq(hub.id)
    hub.capacity.should eq(2)
    expect_raises(Fuel::Error, "already_joined") { sessions.create("alice", "solo", progress: progress) }
    expect_raises(Fuel::Error, "invalid_mode") { sessions.create("alice", "unknown", progress: progress) }
    expect_raises(Fuel::Error, "stale_avatar") { hub.snapshot("alice", progress: Fuel.json({active: true, generation: "second"})) }
    hub.leave("alice")
    solo = sessions.create("alice", "solo", capacity: 32, progress: progress)
    solo.capacity.should eq(1)
    solo.snapshot("alice", progress: progress)["state"]["epoch"].as_s.should eq(solo.epoch)
    expect_raises(Fuel::Error, "full") { sessions.join("bob", solo.id, progress: progress) }
  end

  it "does not keep membership or a created room after a failed domain join" do
    sessions = Fuel::Sessions.new(AdmissionRules.new, modes: {"hub" => Fuel::ModePolicy.new(3, public: true, shared: true)})
    valid = Fuel.json({active: true, generation: "first"})
    invalid = Fuel.json({active: false, generation: "first"})
    expect_raises(Fuel::Error, "avatar_retired") { sessions.create("alice", "hub", progress: invalid) }
    sessions.list("hub").should be_empty
    hub = sessions.create("alice", "hub", progress: valid)
    expect_raises(Fuel::Error, "avatar_retired") { sessions.join("bob", hub.id, progress: invalid) }
    hub.member?("bob").should be_false
    hub.snapshot("alice", progress: valid)["state"]["members"].as_h.keys.should eq(["alice"])
  end
end
