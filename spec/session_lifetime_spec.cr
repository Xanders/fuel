require "./effects_spec"

# Advance only lifecycle timestamps, without waiting hours or changing production clocks.
class Fuel::Room
  def elapse_for_lifetime_spec(age : Time::Span, idle = false)
    @mutex.synchronize do
      @created_at = Time.instant - age
      @activity.transform_values! { Time.instant - age } if idle
    end
  end
end

describe "session age policy" do
  it "keeps the six-hour default and explicit finite age limits" do
    [Fuel::Sessions.new(EffectRules.new), Fuel::Sessions.new(EffectRules.new, ttl: 1.hour)].each do |sessions|
      room = sessions.create("alice", "solo", 1)
      room.elapse_for_lifetime_spec(7.hours)
      room.connect("alice")
      sessions.cleanup
      expect_raises(Fuel::Error, "session_lost") { sessions.get(room.id) }
    end
  end

  it "retains old active rooms with ttl nil while preserving admission and idle cleanup" do
    sessions = Fuel::Sessions.new(EffectRules.new, ttl: nil, max_rooms: 1)
    room = sessions.create("alice", "solo", 1)
    room.elapse_for_lifetime_spec(7.hours)
    generation = room.connect("alice")
    sessions.cleanup
    sessions.rooms.should contain(room)
    sessions.get(room.id).should be(room)
    room.input("alice", generation, 0_i64, Fuel.json({id: "one"}))
    room.elapse_for_lifetime_spec(7.hours, idle: true)
    sessions.cleanup
    sessions.get(room.id).should be(room)
    room.pending_effects.should eq(1)
    expect_raises(Fuel::Error, "capacity") { sessions.create("bob", "solo", 1) }
    effect = room.begin_effect.not_nil!
    room.finish_effect(effect, {"alice" => Fuel.json({source: "effect", reply: {status: "committed"}})})
    sessions.cleanup
    expect_raises(Fuel::Error, "session_lost") { sessions.get(room.id) }
    sessions.create("bob", "solo", 1).id.should_not eq(room.id)
  end

  it "retains pending effects under an explicit age limit until settlement" do
    sessions = Fuel::Sessions.new(EffectRules.new, ttl: 1.hour)
    room = sessions.create("alice", "solo", 1)
    room.command("alice", room.epoch, "one", 0_i64, Fuel.json({id: "one"}))
    room.elapse_for_lifetime_spec(7.hours)
    sessions.cleanup
    sessions.get(room.id).should be(room)
    effect = room.begin_effect.not_nil!
    room.finish_effect(effect, {"alice" => Fuel.json({source: "effect", reply: {status: "committed"}})})
    sessions.cleanup
    expect_raises(Fuel::Error, "session_lost") { sessions.get(room.id) }
  end
end

if url = ENV["FUEL_TEST_DATABASE_URL"]?
  describe "age-unlimited runtime" do
    it "keeps an old socket, HTTP recovery and newly created terminal effects in the same registry" do
      store = Fuel::Store.new(url, "lifetime_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      credential = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      actor = store.bootstrap(credential, "test")
      sessions = Fuel::Sessions.new(FinishedEffectRules.new, ttl: nil)
      room = sessions.create(actor, "solo", 1)
      runtime = Fuel::Runtime.new(store, sessions, Fuel::Handler.new(store, sessions, [] of String), WalletRules.new)
      address = runtime.server.bind_tcp("127.0.0.1", 0)
      completed = Channel(Exception?).new(1)
      spawn do
        runtime.listen
        completed.send(nil)
      rescue error
        completed.send(error)
      end
      headers = HTTP::Headers{"Authorization" => "Fuel #{credential.id}:#{credential.secret}"}
      socket = HTTP::WebSocket.new(address.address, "/fuel/v1/stream?session_id=#{room.id}", port: address.port, headers: headers)
      client = HTTP::Client.new(address.address, address.port)
      client.read_timeout = 3.seconds
      reconnect : HTTP::WebSocket? = nil
      begin
        socket.receive.should be_a(String)
        room.elapse_for_lifetime_spec(7.hours)
        sessions.cleanup
        sessions.rooms.should contain(room)
        sessions.get(room.id).should be(room)
        socket.send(Fuel.json({epoch: room.epoch, sequence: "0", action: {id: "terminal"}}).to_json)
        deadline = Time.instant + 3.seconds
        until room.finished? && room.pending_effects == 0 || Time.instant >= deadline
          sleep 1.millisecond
        end
        room.finished?.should be_true
        room.pending_effects.should eq(0)
        store.progress(credential)["coins"].as_i64.should eq(130)
        store.operations(credential, after: "0").map(&.["operation_id"].as_s).should eq(["#{room.epoch}-terminal"])
        response = client.get("/fuel/v1/sessions/#{room.id}", headers)
        response.status_code.should eq(200)
        JSON.parse(response.body)["data"]["state"]["value"].as_i64.should eq(1)
        socket.close
        reconnect = HTTP::WebSocket.new(address.address, "/fuel/v1/stream?session_id=#{room.id}", port: address.port, headers: headers)
        state = JSON.parse(reconnect.receive.as(String))["data"]
        state["state"]["value"].as_i64.should eq(1)
        state["receipt_cursor"].as_s.should eq("1")
      ensure
        reconnect.try(&.close)
        socket.close unless socket.closed?
        client.close
        runtime.stop
        error = completed.receive
        store.close
        raise error if error
      end
    end
  end
end
