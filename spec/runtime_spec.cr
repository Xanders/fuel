require "./spec_helper"

class ResultRules < CounterRules
  def result(state : JSON::Any, actor : String) : Fuel::GameResult?
    if state["value"].as_i >= 3
      Fuel::GameResult.new("counter", 3_i64, "Player", JSON.parse(%({"completed":true})))
    end
  end
end

describe Fuel::Ticker do
  it "caps fixed-step catch-up after a long stall" do
    sessions = Fuel::Sessions.new(CounterRules.new)
    ticker = Fuel::Ticker.new(sessions, step: 50.milliseconds, max_steps: 3)
    ticker.advance(2.seconds).should eq(3)
    ticker.advance(0.seconds).should eq(0)
    ticker.advance(50.milliseconds).should eq(1)
  end
end

if url = ENV["FUEL_TEST_DATABASE_URL"]?
  describe "runtime settlement and revocation" do
    it "persists authoritative results on retry without applying the command twice" do
      store = Fuel::Store.new(url, "result_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      credential = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      actor = store.bootstrap(credential, "test")
      room = Fuel::Room.new(ResultRules.new, actor, "solo", 1, false)
      action = JSON.parse(%({"amount":3}))
      room.command(actor, room.epoch, "finish", 0_i64, action)
      room.pending_result?.should be_true
      room.persist_result(store, credential)
      room.command(actor, room.epoch, "finish", 0_i64, action)
      room.persist_result(store, credential)
      room.pending_result?.should be_false
      store.leaderboard("counter").size.should eq(1)
      store.progress(credential)["completed"].as_bool.should be_true
    end

    it "revalidates a binding while long polling and on an already open socket" do
      store = Fuel::Store.new(url, "revoke_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      credential = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      actor = store.bootstrap(credential, "test")
      sessions = Fuel::Sessions.new(CounterRules.new)
      room = sessions.create(actor, "solo", 1)
      server = HTTP::Server.new(Fuel::Handler.new(store, sessions, [] of String))
      address = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      headers = HTTP::Headers{"Authorization" => "Fuel #{credential.id}:#{credential.secret}"}
      client = HTTP::Client.new(address.address, address.port)
      client.read_timeout = 3.seconds
      socket = HTTP::WebSocket.new(address.address, "/fuel/v1/stream?session_id=#{room.id}", port: address.port, headers: headers)
      begin
        socket.receive.should be_a(String)
        response = Channel(Int32).new
        spawn { response.send(client.get("/fuel/v1/sessions/#{room.id}/events?cursor=0&epoch=#{room.epoch}", headers).status_code) }
        sleep 20.milliseconds
        store.revoke(credential, credential.id)
        response.receive.should eq(401)
        # At most one already-sent snapshot remains buffered before closure.
        5.times { break if socket.receive?.nil? }
        socket.closed?.should be_true
      ensure
        socket.close
        client.close
        server.close
      end
    end
  end
end
