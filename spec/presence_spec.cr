require "./session_lifetime_spec"
require "./session_spec"

class PresenceRules < CounterRules
  getter observations = [] of Fuel::SessionPresence

  def initial : JSON::Any
    Fuel.json({value: 0, online: [] of String, paused: false})
  end

  def apply(state : JSON::Any, actor : String, action : JSON::Any, presence : Fuel::SessionPresence, events : Fuel::SessionEvents) : JSON::Any
    @observations << presence
    Fuel.check(presence.connected?(actor), "offline_vote") if action["vote"]?.try(&.as_bool)
    state.as_h["value"] = super(state, actor, action, events)["value"]
    state.as_h["online"] = Fuel.json(presence.connected)
    state
  end

  def tick(state : JSON::Any, dt : Time::Span, presence : Fuel::SessionPresence, events : Fuel::SessionEvents) : JSON::Any
    @observations << presence
    state.as_h["online"] = Fuel.json(presence.connected)
    state.as_h["paused"] = JSON::Any.new(presence.connected.size < presence.members.size)
    state
  end
end

describe "room-owned rule presence" do
  it "supplies authoritative immutable action and tick snapshots, fencing a replaced connection" do
    rules = PresenceRules.new
    room = Fuel::Room.new(rules, "alice", "duel", 2, false)
    room.join(["bob"])
    old = room.connect("alice")
    bob = room.connect("bob")
    room.command("alice", room.epoch, "one", room.snapshot("alice")["revision"].as_s.to_i64, Fuel.json({amount: 1}))
    rules.observations.should_not be_empty
    saved = rules.observations.last
    saved.connected.should eq(["alice", "bob"])
    saved.members.clear
    saved.connected.clear
    saved.members.should eq(["alice", "bob"])
    current = room.connect("alice")
    room.disconnect("alice", old)
    room.disconnect("bob", bob)
    room.input("alice", current, 0_i64, Fuel.json({amount: 1, claimed_online: ["alice", "bob"]}))
    latest = rules.observations.last
    latest.connected.should eq(["alice"])
    latest.generation("alice").should eq(current)
    latest.generation("bob").should be_nil
    saved.generation("alice").should eq(old)
    saved.connected.should eq(["alice", "bob"])
    before = room.snapshot("alice")["state"]
    expect_raises(Fuel::Error, "offline_vote") do
      room.command("bob", room.epoch, "offline", room.snapshot("bob")["revision"].as_s.to_i64, Fuel.json({amount: 1, vote: true, claimed_online: ["bob"]}))
    end
    room.snapshot("alice")["state"].should eq(before)
    room.tick(50.milliseconds)
    room.snapshot("alice")["state"]["paused"].as_bool.should be_true
    room.connect("bob")
    room.tick(50.milliseconds)
    room.snapshot("alice")["state"]["paused"].as_bool.should be_false
  end

  it "does not start waiting lobbies or call the tick hook before gameplay starts" do
    rules = PresenceRules.new
    room = Fuel::Room.new(rules, "alice", "duel", 2, false)
    room.connect("alice")
    room.tick(50.milliseconds)
    rules.observations.should be_empty
    room.snapshot("alice")["state"]["value"].as_i.should eq(0)
  end
end

if url = ENV["FUEL_TEST_DATABASE_URL"]?
  describe "canonical transport presence" do
    it "exposes actual WebSocket close and reconnect through the existing runtime ticker" do
      store = Fuel::Store.new(url, "presence_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      credentials = Array.new(2) { Fuel::Credential.new(Fuel.id, Random::Secure.hex(32)) }
      actors = credentials.map { |proof| store.bootstrap(proof, Fuel.id) }
      sessions = Fuel::Sessions.new(PresenceRules.new, ttl: nil)
      room = sessions.create(actors[0], "duel", 2)
      sessions.join(actors[1], room.id)
      runtime = Fuel::Runtime.new(store, sessions, Fuel::Handler.new(store, sessions, [] of String), WalletRules.new)
      address = runtime.server.bind_tcp("127.0.0.1", 0)
      done = Channel(Exception?).new(1)
      spawn do
        runtime.listen
        done.send(nil)
      rescue error
        done.send(error)
      end
      sockets = [] of HTTP::WebSocket
      begin
        credentials.each do |proof|
          headers = HTTP::Headers{"Authorization" => "Fuel #{proof.id}:#{proof.secret}"}
          socket = HTTP::WebSocket.new(address.address, "/fuel/v1/stream?session_id=#{room.id}", port: address.port, headers: headers)
          sockets << socket
          socket.receive.should be_a(String)
        end
        room.ready(actors[0])
        room.ready(actors[1])
        deadline = Time.instant + 3.seconds
        until room.snapshot(actors[0])["state"]["online"].as_a.size == 2 || Time.instant >= deadline
          sleep 1.millisecond
        end
        room.snapshot(actors[0])["state"]["online"].as_a.size.should eq(2)
        sockets[1].close
        deadline = Time.instant + 3.seconds
        until room.snapshot(actors[0])["state"]["paused"].as_bool || Time.instant >= deadline
          sleep 1.millisecond
        end
        room.snapshot(actors[0])["state"]["online"].as_a.map(&.as_s).should eq([actors[0]])
        headers = HTTP::Headers{"Authorization" => "Fuel #{credentials[1].id}:#{credentials[1].secret}"}
        reconnect = HTTP::WebSocket.new(address.address, "/fuel/v1/stream?session_id=#{room.id}", port: address.port, headers: headers)
        sockets << reconnect
        reconnect.receive.should be_a(String)
        deadline = Time.instant + 3.seconds
        while room.snapshot(actors[0])["state"]["paused"].as_bool && Time.instant < deadline
          sleep 1.millisecond
        end
        room.snapshot(actors[0])["state"]["online"].as_a.map(&.as_s).should eq(actors)
        room.snapshot(actors[0])["state"]["paused"].as_bool.should be_false
      ensure
        sockets.each { |socket| socket.close unless socket.closed? }
        runtime.stop
        error = done.receive
        store.close
        raise error if error
      end
    end
  end
end
