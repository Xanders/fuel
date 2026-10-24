require "./session_spec"

if url = ENV["FUEL_TEST_DATABASE_URL"]?
  describe "canonical socket admission" do
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
