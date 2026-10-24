require "./spec_helper"

class CounterRules < Fuel::Rules
  def initial : JSON::Any
    JSON.parse(%({"value":0}))
  end

  def apply(state : JSON::Any, actor : String, action : JSON::Any) : JSON::Any
    amount = action["amount"].as_i
    raise Fuel::Error.new("illegal_action") unless (1..3).includes?(amount)
    JSON.parse({value: state["value"].as_i + amount}.to_json)
  end

  def project(state : JSON::Any, actor : String) : JSON::Any
    state
  end
end

describe Fuel::Sessions do
  it "keeps a co-op party together and removes expired waiting tickets" do
    rooms = Fuel::Sessions.new(CounterRules.new, ticket_ttl: 0.seconds)
    rooms.match_party(["alice", "bob"], "coop", 4)["status"].as_s.should eq("waiting")
    rooms.cleanup
    rooms.match_party(["carol", "dave"], "coop", 4)["status"].as_s.should eq("waiting")
    normal = Fuel::Sessions.new(CounterRules.new)
    normal.match_party(["alice", "bob"], "coop", 4)
    result = normal.match_party(["carol", "dave"], "coop", 4)
    result["status"].as_s.should eq("matched")
    room = normal.get(result["session_id"].as_s)
    ["alice", "bob", "carol", "dave"].each { |a| room.member?(a).should be_true }
  end
  it "unifies private codes, links and public joins without leaking invites" do
    rooms = Fuel::Sessions.new(CounterRules.new)
    room = rooms.create("alice", "duel", 2, false)
    rooms.list("duel").should be_empty
    rooms.join_code("bob", room.code.downcase).id.should eq(room.id)
    expect_raises(Fuel::Error, "full") { rooms.join("eve", room.id) }
    public_room = rooms.create("carol", "duel", 2, true)
    rooms.list("duel").map(&.["id"].as_s).should eq([public_room.id])
    rooms.list("duel").first.as_h.has_key?("code").should be_false
    Fuel::Invite.link("https://game.example/join", room.code).should contain("invite=")
  end

  it "matches compatible players with one stable ticket and supports cancellation" do
    rooms = Fuel::Sessions.new(CounterRules.new)
    a = rooms.match("alice", "duel")
    rooms.match("alice", "duel").should eq(a)
    rooms.match("eve", "coop")["status"].as_s.should eq("waiting")
    b = rooms.match("bob", "duel")
    b["status"].as_s.should eq("matched")
    rooms.cancel_match("bob", "duel")["status"].as_s.should eq("matched")
    rooms.match("bob", "duel")["status"].as_s.should eq("matched")
    rooms.match("alice", "duel")["session_id"].should eq(b["session_id"])
    rooms.cancel_match("eve", "coop")
    rooms.match("carol", "coop")["status"].as_s.should eq("waiting")
  end

  it "fences a delayed matchmaking request after cancellation of the same generation" do
    rooms = Fuel::Sessions.new(CounterRules.new)
    rooms.cancel_match("alice", "duel", "intent-1")
    expect_raises(Fuel::Error, "match_cancelled") { rooms.match("alice", "duel", "intent-1") }
    rooms.match("alice", "duel", "intent-2")["status"].as_s.should eq("waiting")
    rooms.cancel_match("alice", "duel", "intent-1")
    rooms.match("bob", "duel", "other")["status"].as_s.should eq("matched")
  end

  it "serializes actions, checks membership and revision, and replays exact IDs" do
    rooms = Fuel::Sessions.new(CounterRules.new)
    room = rooms.create("alice", "solo", 1, false)
    action = JSON.parse(%({"amount":2}))
    first = rooms.command("alice", room.id, room.epoch, "a", 0_i64, action)
    rooms.command("alice", room.id, room.epoch, "a", 0_i64, action).should eq(first)
    expect_raises(Fuel::Error, "conflict") { rooms.command("alice", room.id, room.epoch, "a", 0_i64, JSON.parse(%({"amount":1}))) }
    expect_raises(Fuel::Error, "forbidden") { rooms.snapshot("eve", room.id) }
    expect_raises(Fuel::Error, "revision_conflict") { rooms.command("alice", room.id, room.epoch, "b", 0_i64, action) }
    expect_raises(Fuel::Error, "session_lost") { Fuel::Sessions.new(CounterRules.new).snapshot("alice", room.id) }
    rooms.snapshot("alice", room.id)["revision"].as_s.should eq("1")
  end

  it "fences old connections and rejects stale realtime input without replay" do
    rooms = Fuel::Sessions.new(CounterRules.new)
    room = rooms.create("alice", "solo", 1, false)
    generation = room.connect("alice")
    room.input("alice", generation, 1_i64, JSON.parse(%({"amount":1})))
    expect_raises(Fuel::Error, "stale_input") { room.input("alice", generation, 1_i64, JSON.parse(%({"amount":1}))) }
    room.connect("alice")
    expect_raises(Fuel::Error, "stale_connection") { room.input("alice", generation, 2_i64, JSON.parse(%({"amount":1}))) }
  end

  it "does not execute a command twice after bounded receipt eviction" do
    room = Fuel::Room.new(CounterRules.new, "alice", "solo", 1, false, receipt_limit: 1)
    room.command("alice", room.epoch, "a", 0_i64, JSON.parse(%({"amount":1})))
    room.command("alice", room.epoch, "b", 1_i64, JSON.parse(%({"amount":1})))
    expect_raises(Fuel::Error, "revision_conflict") { room.command("alice", room.epoch, "a", 0_i64, JSON.parse(%({"amount":1}))) }
  end
end

class HiddenRules < CounterRules
  def project(state : JSON::Any, actor : String) : JSON::Any
    actor == "alice" ? state : JSON.parse(%({"value":0}))
  end
end

describe "private projections" do
  it "does not change an opponent cursor for a secret-only action" do
    rooms = Fuel::Sessions.new(HiddenRules.new)
    room = rooms.create("alice", "duel")
    rooms.join("bob", room.id)
    before = room.snapshot("bob")["revision"]
    room.command("alice", room.epoch, "secret", 0_i64, JSON.parse(%({"amount":1})))
    room.snapshot("bob")["revision"].should eq(before)
  end
end
