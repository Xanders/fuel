require "./session_spec"

class FiniteSocketRules < CounterRules
  def finished?(state : JSON::Any) : Bool
    state["value"].as_i >= 1
  end
end

private def terminal_frame(socket : HTTP::WebSocket) : JSON::Any?
  frames = Channel(JSON::Any?).new(1)
  spawn do
    value = socket.receive?
    frames.send(value.is_a?(String) ? JSON.parse(value) : nil)
  rescue
    frames.send(nil)
  end
  select
  when frame = frames.receive
    frame
  when timeout(3.seconds)
    raise "Timed out waiting for terminal socket state"
  end
end

if url = ENV["FUEL_TEST_DATABASE_URL"]?
  it "refreshes a final private snapshot for late input without applying it or hiding a lost epoch" do
    store = Fuel::Store.new(url, "terminal_socket_#{Fuel.id}", "d" * 32, "p" * 32)
    store.migrate
    proof = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
    actor = store.bootstrap(proof, "test")
    sessions = Fuel::Sessions.new(FiniteSocketRules.new)
    room = sessions.create(actor, "solo", 1)
    server = HTTP::Server.new(Fuel::Handler.new(store, sessions, [] of String))
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    headers = HTTP::Headers{"Authorization" => "Fuel #{proof.id}:#{proof.secret}"}
    socket = HTTP::WebSocket.new(address.address, "/fuel/v1/stream?session_id=#{room.id}", port: address.port, headers: headers)
    begin
      terminal_frame(socket).not_nil!["data"]["state"]["value"].as_i.should eq(0)
      socket.send({epoch: room.epoch, sequence: "1", action: {amount: 1}}.to_json)
      20.times do
        break if terminal_frame(socket).not_nil!["data"]["state"]["value"].as_i == 1
      end
      room.snapshot(actor)["state"]["value"].as_i.should eq(1)
      socket.send({epoch: room.epoch, sequence: "2", action: {amount: 100}}.to_json)
      3.times do
        frame = terminal_frame(socket)
        frame.should_not be_nil
        frame.not_nil!["account_id"].as_s.should eq(actor)
        frame.not_nil!["data"]["state"]["value"].as_i.should eq(1)
      end
      socket.closed?.should be_false
      socket.send({epoch: "lost-epoch", sequence: "3", action: {amount: 100}}.to_json)
      20.times { break if terminal_frame(socket).nil? }
      socket.closed?.should be_true
      room.snapshot(actor)["state"]["value"].as_i.should eq(1)
    ensure
      socket.close unless socket.closed?
      server.close
      store.close
    end
  end
end
