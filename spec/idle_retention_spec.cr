require "./session_spec"
require "./effects_spec"

class Fuel::Room
  def elapse_idle_member_for_spec(actor : String, age : Time::Span)
    @mutex.synchronize { @activity[actor] = Time.instant - age }
  end
end

class IdleWaitRules < CounterRules
  def initialize(@human = "alice")
  end

  def initial : JSON::Any
    Fuel.json({value: 0, wait: true, cancelled: false, retention_probe: false, online: [] of String})
  end

  def apply(state : JSON::Any, actor : String, action : JSON::Any) : JSON::Any
    state.as_h["value"] = super(state, actor, action)["value"]
    state.as_h["wait"] = action["wait"] if action["wait"]?
    state
  end

  def leave(state : JSON::Any, actor : String) : JSON::Any
    state.as_h["cancelled"] = JSON::Any.new(true)
    state
  end

  def tick(state : JSON::Any, dt : Time::Span, presence : Fuel::SessionPresence, events : Fuel::SessionEvents) : JSON::Any
    state.as_h["online"] = Fuel.json(presence.connected)
    state
  end

  def retain_idle_member?(state : JSON::Any, actor : String, presence : Fuel::SessionPresence) : Bool
    state.as_h["retention_probe"] = JSON::Any.new(true)
    state["wait"].as_bool && presence.connected?(@human)
  end
end

class AlwaysRetainIdleRules < IdleWaitRules
  def retain_idle_member?(state : JSON::Any, actor : String, presence : Fuel::SessionPresence) : Bool
    true
  end
end

describe "domain idle membership retention" do
  it "retains an offline member beyond the timeout without cancelling play, until the game stops waiting" do
    sessions = Fuel::Sessions.new(IdleWaitRules.new, ttl: nil, invite_ttl: nil, idle_timeout: 45.seconds)
    room = sessions.create("alice", "duel", 2)
    room.join(["bob"])
    room.connect("alice")
    bob = room.connect("bob")
    room.disconnect("bob", bob)
    [46.seconds, 1.hour].each do |age|
      room.elapse_idle_member_for_spec("bob", age)
      sessions.cleanup
      room.members.should eq(["alice", "bob"])
      state = room.snapshot("alice")["state"]
      state["cancelled"].as_bool.should be_false
      state["retention_probe"].as_bool.should be_false
    end
    room.command("alice", room.epoch, "stop-wait", room.snapshot("alice")["revision"].as_s.to_i64, Fuel.json({amount: 1, wait: false}))
    sessions.cleanup
    room.members.should eq(["alice"])
    room.snapshot("alice")["state"]["cancelled"].as_bool.should be_true
  end

  it "reclaims an all-offline room even when its rules still request waiting" do
    sessions = Fuel::Sessions.new(AlwaysRetainIdleRules.new, ttl: nil, invite_ttl: nil, idle_timeout: 45.seconds)
    room = sessions.create("alice", "duel", 2)
    room.join(["bob"])
    alice = room.connect("alice")
    bob = room.connect("bob")
    room.disconnect("bob", bob)
    room.elapse_idle_member_for_spec("bob", 46.seconds)
    sessions.cleanup
    room.member?("bob").should be_true
    room.disconnect("alice", alice)
    room.elapse_idle_member_for_spec("alice", 46.seconds)
    sessions.cleanup
    room.members.should be_empty
    expect_raises(Fuel::Error, "session_lost") { sessions.get(room.id) }
  end

  it "keeps default cleanup and lets the game reject retention without a connected human" do
    [CounterRules.new, IdleWaitRules.new].each do |rules|
      room = Fuel::Room.new(rules, "alice", "duel", 2, false)
      room.join(["bob"])
      room.connect("bob")
      room.elapse_idle_member_for_spec("alice", 46.seconds)
      room.expire_idle(45.seconds)
      room.members.should eq(["bob"])
    end
  end

  it "does not veto expiration of stale connected members or an explicit departure" do
    room = Fuel::Room.new(IdleWaitRules.new, "alice", "duel", 2, false)
    room.join(["bob"])
    room.connect("alice")
    room.connect("bob")
    room.elapse_idle_member_for_spec("bob", 46.seconds)
    room.expire_idle(45.seconds)
    room.members.should eq(["alice"])
    room.leave("alice")
    room.members.should be_empty
  end
end

if url = ENV["FUEL_TEST_DATABASE_URL"]?
  describe "canonical transport idle retention" do
    it "preserves a closed peer through real cleanup and admits its fenced reconnect" do
      store = Fuel::Store.new(url, "idle_wait_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      credentials = Array.new(2) { Fuel::Credential.new(Fuel.id, Random::Secure.hex(32)) }
      actors = credentials.map { |proof| store.bootstrap(proof, Fuel.id) }
      sessions = Fuel::Sessions.new(IdleWaitRules.new(actors[0]), ttl: nil, invite_ttl: nil, idle_timeout: 45.seconds)
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
        sockets[1].close
        deadline = Time.instant + 3.seconds
        until room.snapshot(actors[0])["state"]["online"].as_a.map(&.as_s) == [actors[0]] || Time.instant >= deadline
          sleep 1.millisecond
        end
        room.snapshot(actors[0])["state"]["online"].as_a.map(&.as_s).should eq([actors[0]])
        room.elapse_idle_member_for_spec(actors[1], 46.seconds)
        sessions.cleanup
        room.members.should eq(actors)
        room.snapshot(actors[0])["state"]["cancelled"].as_bool.should be_false
        headers = HTTP::Headers{"Authorization" => "Fuel #{credentials[1].id}:#{credentials[1].secret}"}
        reconnect = HTTP::WebSocket.new(address.address, "/fuel/v1/stream?session_id=#{room.id}", port: address.port, headers: headers)
        sockets << reconnect
        envelope = JSON.parse(reconnect.receive.as(String))
        envelope["data"]["session_id"].as_s.should eq(room.id)
        envelope["generation"].as_s.should_not be_empty
        reconnect.send(Fuel.json({epoch: room.epoch, sequence: "0", action: {amount: 1}}).to_json)
        deadline = Time.instant + 3.seconds
        until room.snapshot(actors[0])["state"]["value"].as_i == 1 || Time.instant >= deadline
          sleep 1.millisecond
        end
        room.snapshot(actors[0])["state"]["value"].as_i.should eq(1)
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
