require "./session_lifetime_spec"
require "./session_spec"

describe "invite age policy" do
  it "preserves the default five-minute limit and accepts an explicit finite horizon" do
    [Fuel::Sessions.new(CounterRules.new), Fuel::Sessions.new(CounterRules.new, invite_ttl: 10.minutes)].each do |sessions|
      room = sessions.create("alice", "duel", 2)
      room.elapse_for_lifetime_spec(15.minutes)
      expect_raises(Fuel::Error, "invalid_code") { sessions.join_code("bob", room.code) }
    end
    sessions = Fuel::Sessions.new(CounterRules.new, invite_ttl: 20.minutes)
    room = sessions.create("alice", "duel", 2)
    room.elapse_for_lifetime_spec(15.minutes)
    sessions.join_code("bob", room.code).should be(room)
  end

  it "retains the original code while an age-unlimited room remains registered and joinable" do
    sessions = Fuel::Sessions.new(CounterRules.new, ttl: nil, invite_ttl: nil)
    room = sessions.create("alice", "duel", 2)
    original = room.code
    room.elapse_for_lifetime_spec(7.hours)
    room.connect("alice")
    sessions.cleanup
    sessions.join_code("bob", original.downcase).should be(room)
    expect_raises(Fuel::Error, "full") { sessions.join_code("carol", original) }
    room.leave("bob")
    room.elapse_for_lifetime_spec(7.hours, idle: true)
    sessions.cleanup
    expect_raises(Fuel::Error, "session_lost") { sessions.get(room.id) }
    expect_raises(Fuel::Error, "invalid_code") { sessions.join_code("carol", original) }
  end
end
