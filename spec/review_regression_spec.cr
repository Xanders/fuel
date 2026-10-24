require "./spec_helper"

describe "initial review regressions" do
  it "packs compatible parties without a small head-of-line party blocking them" do
    sessions = Fuel::Sessions.new(CounterRules.new)
    sessions.match_party(["single"], "coop", 4)
    sessions.match_party(["a", "b"], "coop", 4)
    match = sessions.match_party(["c", "d"], "coop", 4)
    match["status"].as_s.should eq("matched")
    room = sessions.get(match["session_id"].as_s)
    ["a", "b", "c", "d"].each { |actor| room.member?(actor).should be_true }
    room.member?("single").should be_false
  end
  it "never reuses a viewer revision after leaving and rejoining" do
    room = Fuel::Room.new(CounterRules.new, "alice", "duel", 2, false, receipt_limit: 1)
    room.join(["bob"])
    room.command("alice", room.epoch, "a", 0_i64, JSON.parse(%({"amount":1})))
    room.command("alice", room.epoch, "b", 1_i64, JSON.parse(%({"amount":1})))
    room.leave("alice")
    room.join(["alice"])
    expect_raises(Fuel::Error, "revision_conflict") { room.command("alice", room.epoch, "a", 0_i64, JSON.parse(%({"amount":1}))) }
  end

  it "allows new matchmaking generations after leaving a matched room" do
    sessions = Fuel::Sessions.new(CounterRules.new)
    sessions.match("alice", "duel", "first")
    match = sessions.match("bob", "duel", "first")
    sessions.get(match["session_id"].as_s).leave("alice")
    sessions.match("alice", "duel", "second")["status"].as_s.should eq("waiting")
  end

  it "does not start a waiting room or close invites on a no-op tick" do
    sessions = Fuel::Sessions.new(CounterRules.new)
    room = sessions.create("alice", "duel", 2, false, false)
    sessions.tick(50.milliseconds)
    sessions.join_code("bob", room.code).member?("bob").should be_true
  end

  it "purges sent and received RAM private chat on account deletion" do
    chat = Fuel::Chat.new { |_, _, _| true }
    chat.post("alice", "global", "", "old")
    chat.post("alice", "private", "bob", "old")
    chat.post("bob", "private", "alice", "old reply")
    chat.remove_account("alice")
    chat.history("bob", "global", "").should be_empty
    chat.history("bob", "private", "alice").should be_empty
  end

  it "cancels a whole waiting party when one member is deleted" do
    sessions = Fuel::Sessions.new(CounterRules.new)
    sessions.match_party(["alice", "bob"], "coop", 4)
    sessions.remove_account("alice")
    sessions.match_party(["carol", "dave"], "coop", 4)["status"].as_s.should eq("waiting")
  end

  it "admits an already-full party and can pack more than two parties" do
    sessions = Fuel::Sessions.new(CounterRules.new)
    sessions.match_party(["a", "b", "c", "d"], "coop", 4)["status"].as_s.should eq("matched")
    sessions.match_party(["e"], "coop", 4)
    sessions.match_party(["f"], "coop", 4)
    sessions.match_party(["g", "h"], "coop", 4)["status"].as_s.should eq("matched")
  end

  it "reclaims empty ended rooms before the registry reaches capacity" do
    sessions = Fuel::Sessions.new(CounterRules.new, max_rooms: 1)
    room = sessions.create("alice", "solo", 1)
    room.leave("alice")
    sessions.create("bob", "solo", 1).member?("bob").should be_true
  end
end
