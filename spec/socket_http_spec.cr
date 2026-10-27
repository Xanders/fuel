require "./session_spec"

if url = ENV["FUEL_TEST_DATABASE_URL"]?
  describe "canonical socket admission" do
    it "tells a replaced room connection to yield without losing membership" do
      store = Fuel::Store.new(url, "replaced_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      credential = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      actor = store.bootstrap(credential, "test")
      sessions = Fuel::Sessions.new(CounterRules.new)
      room = sessions.create(actor, "solo", 1)
      server = HTTP::Server.new(Fuel::Handler.new(store, sessions, [] of String))
      address = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      headers = HTTP::Headers{"Authorization" => "Fuel #{credential.id}:#{credential.secret}"}
      first = HTTP::WebSocket.new(address.address, "/fuel/v1/stream?session_id=#{room.id}", port: address.port, headers: headers)
      second : HTTP::WebSocket? = nil
      frames = Channel(String?).new(8)
      first.on_message { |raw| frames.send(raw) }
      first.on_close { |_, _| frames.send(nil) }
      spawn { first.run }
      next_frame = -> {
        select
        when raw = frames.receive
          raw.try { |value| JSON.parse(value) }
        when timeout(3.seconds)
          raise "Timed out waiting for replaced socket"
        end
      }
      begin
        next_frame.call.not_nil!["data"]["session_id"].as_s.should eq(room.id)
        second = HTTP::WebSocket.new(address.address, "/fuel/v1/stream?session_id=#{room.id}", port: address.port, headers: headers)
        second.receive.should be_a(String)
        replacement : JSON::Any? = nil
        20.times do
          frame = next_frame.call
          break unless frame
          if frame["error"]?
            replacement = frame
            break
          end
        end
        replacement.should_not be_nil
        replacement.not_nil!["error"].as_s.should eq("connection_replaced")
        replacement.not_nil!["wire_version"].as_i.should eq(1)
        second.receive.should be_a(String)
        room.snapshot(actor)["session_id"].as_s.should eq(room.id)
      ensure
        first.close unless first.closed?
        second.try { |socket| socket.close unless socket.closed? }
        server.close
        store.close
      end
    end

    it "does not invalidate an active room generation on a rejected handshake" do
      store = Fuel::Store.new(url, "socket_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      credential = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      actor = store.bootstrap(credential, "test")
      sessions = Fuel::Sessions.new(CounterRules.new)
      room = sessions.create(actor, "solo", 1)
      generation = room.connect(actor)
      handler = Fuel::Handler.new(store, sessions, [] of String)
      server = HTTP::Server.new(handler)
      address = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      client = HTTP::Client.new(address.address, address.port)
      begin
        headers = HTTP::Headers{"Authorization" => "Fuel #{credential.id}:#{credential.secret}",
                                "Upgrade" => "websocket", "Connection" => "Upgrade", "Sec-WebSocket-Version" => "12"}
        client.get("/fuel/v1/stream?session_id=#{room.id}", headers).status_code.should_not eq(101)
        room.snapshot(actor, generation)["session_id"].as_s.should eq(room.id)
      ensure
        client.close
        server.close
        store.db.close
      end
    end
  end
end
