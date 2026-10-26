require "./session_spec"
require "http/server"

class PollPresenceRules < CounterRules
  property watched : String? = nil
  property forbidden = false
  getter observations = Channel(Nil).new(64)

  def authorize(state : JSON::Any, actor : String, progress : JSON::Any) : Nil
    if actor == @watched
      select
      when @observations.send(nil)
      else
      end
      raise Fuel::Error.new("forbidden") if @forbidden
    end
  end
end

def poll_observation(rules)
  select
  when rules.observations.receive
  when timeout(2.seconds)
    fail "poll did not revalidate authorization"
  end
end

if url = ENV["FUEL_TEST_DATABASE_URL"]?
  describe "long-poll presence" do
    it "does not renew presence while rechecking a disconnected request" do
      store = Fuel::Store.new(url, "poll_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      credential = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      actor = store.bootstrap(credential, "test")
      rules = PollPresenceRules.new
      rooms = Fuel::Sessions.new(rules)
      room = rooms.create(actor, "duel", 2)
      rooms.join("other", room.id)
      snapshot = room.snapshot(actor)
      rules.watched = actor
      server = HTTP::Server.new(Fuel::Handler.new(store, rooms, ["https://game.example"]))
      address = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      socket = TCPSocket.new(address.address, address.port)
      begin
        socket << "GET /fuel/v1/sessions/#{room.id}/events?cursor=#{snapshot["revision"].as_s}&epoch=#{room.epoch} HTTP/1.1\r\nHost: game.example\r\nAuthorization: Fuel #{credential.id}:#{credential.secret}\r\n\r\n"
        socket.flush
        poll_observation(rules)
        socket.close
        3.times { poll_observation(rules) }
        room.snapshot("other")
        room.expire_idle(150.milliseconds)
        room.member?(actor).should be_false
        room.member?("other").should be_true
      ensure
        socket.close unless socket.closed?
        room.leave(actor, force: true)
        server.close
      end
    end

    ["revoked", "forbidden"].each do |rejection|
      it "still rejects #{rejection} authorization during an unchanged poll" do
        store = Fuel::Store.new(url, "poll_#{Fuel.id}", "d" * 32, "p" * 32)
        store.migrate
        credential = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
        actor = store.bootstrap(credential, "test")
        rules = PollPresenceRules.new
        rooms = Fuel::Sessions.new(rules)
        room = rooms.create(actor, "solo", 1)
        snapshot = room.snapshot(actor)
        rules.watched = actor
        server = HTTP::Server.new(Fuel::Handler.new(store, rooms, ["https://game.example"]))
        address = server.bind_tcp("127.0.0.1", 0)
        spawn { server.listen }
        client = HTTP::Client.new(address.address, address.port)
        response = Channel(HTTP::Client::Response).new(1)
        begin
          spawn do
            response.send(client.get("/fuel/v1/sessions/#{room.id}/events?cursor=#{snapshot["revision"].as_s}&epoch=#{room.epoch}", HTTP::Headers{"Authorization" => "Fuel #{credential.id}:#{credential.secret}"}))
          end
          poll_observation(rules)
          if rejection == "revoked"
            store.revoke(credential, credential.id, confirmed_last: true)
          else
            rules.forbidden = true
          end
          select
          when result = response.receive
            result.status_code.should eq(rejection == "revoked" ? 401 : 403)
            JSON.parse(result.body)["error"].as_s.should eq(rejection == "revoked" ? "unauthorized" : "forbidden")
          when timeout(2.seconds)
            fail "revoked long poll remained open"
          end
        ensure
          client.close
          server.close
        end
      end
    end
  end
end
