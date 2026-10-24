require "./spec_helper"

describe Fuel::SocketFrames do
  it "rejects invalid close reason encoding and reserved close codes" do
    [Bytes[0x03, 0xe8, 0xff], Bytes[0x03, 0xed]].each do |payload|
      io = IO::Memory.new
      sender = HTTP::WebSocket::Protocol.new(io, masked: true, sync_close: false)
      sender.send(payload, HTTP::WebSocket::Protocol::Opcode::CLOSE)
      io.rewind
      expect_raises(Fuel::Error, "invalid_request") { Fuel::SocketFrames.new(io).receive { |_, _| } }
    end
  end
  it "assembles fragmented text with interleaved control frames" do
    io = IO::Memory.new
    sender = HTTP::WebSocket::Protocol.new(io, masked: true, sync_close: false)
    sender.send("{\"n\":".to_slice, HTTP::WebSocket::Protocol::Opcode::TEXT, HTTP::WebSocket::Protocol::Flags::None)
    sender.ping("probe")
    sender.send("1}".to_slice, HTTP::WebSocket::Protocol::Opcode::CONTINUATION)
    io.rewind
    controls = [] of Tuple(UInt8, String)
    reader = Fuel::SocketFrames.new(io, 32)
    reader.receive { |op, body| controls << {op, body} }.should eq("{\"n\":1}")
    controls.should eq([{9_u8, "probe"}])
  end

  it "rejects binary, unmasked, orphan continuation and nonfinal control frames" do
    [Bytes[0x82, 0x80, 0, 0, 0, 0], Bytes[0x81, 0],
     Bytes[0x80, 0x80, 0, 0, 0, 0], Bytes[0x09, 0x80, 0, 0, 0, 0]].each do |bytes|
      expect_raises(Fuel::Error) { Fuel::SocketFrames.new(IO::Memory.new(bytes), 32).receive { |_, _| } }
    end
  end

  it "rejects declared oversize before reading or allocating its payload" do
    bytes = Bytes[0x81, 0xfe, 0x10, 0x00]
    expect_raises(Fuel::Error, "too_large") { Fuel::SocketFrames.new(IO::Memory.new(bytes), 32).receive { |_, _| } }
  end

  it "bounds the assembled message across individually small frames" do
    io = IO::Memory.new
    sender = HTTP::WebSocket::Protocol.new(io, masked: true, sync_close: false)
    sender.send("1234".to_slice, HTTP::WebSocket::Protocol::Opcode::TEXT, HTTP::WebSocket::Protocol::Flags::None)
    sender.send("5678".to_slice, HTTP::WebSocket::Protocol::Opcode::CONTINUATION)
    io.rewind
    expect_raises(Fuel::Error, "too_large") { Fuel::SocketFrames.new(io, 7).receive { |_, _| } }
  end
end

class StalledSocketIO < IO
  getter entered = Channel(Nil).new(1)
  @stopped = Channel(Nil).new
  getter? closed = false

  def read(slice : Bytes) : Int32
    @stopped.receive?
    0
  end

  def write(slice : Bytes) : Nil
    select
    when @entered.send(nil)
    else
    end
    @stopped.receive?
    raise IO::Error.new("closed")
  end

  def close
    return if @closed
    @closed = true
    @stopped.close
  end
end

describe Fuel::SocketBudget do
  it "releases global and account permits exactly once, including failed admission" do
    budget = Fuel::SocketBudget.new(2, 1)
    first = budget.reserve
    first.admit("a")
    second = budget.reserve
    expect_raises(Fuel::Error, "capacity") { budget.reserve }
    expect_raises(Fuel::Error, "capacity") { second.admit("a") }
    second.release
    second.release
    first.release
    third = budget.reserve
    third.admit("a")
    third.release
    budget.active.should eq(0)
  end
end

describe Fuel::Limiter do
  it "enforces a bounded shared fixed window and recovers expired capacity" do
    limiter = Fuel::Limiter.new(1)
    limiter.check("actor", 2, 10, 0)
    limiter.check("actor", 2, 10, 1)
    expect_raises(Fuel::Error, "rate_limit") { limiter.check("actor", 2, 10, 2) }
    expect_raises(Fuel::Error, "capacity") { limiter.check("another", 2, 10, 2) }
    limiter.check("another", 2, 10, 10)
  end
end

class SocketTestPeer < Fuel::SocketPeer
  def start(socket : Fuel::SocketConnection) : Nil
    socket.admit("account")
  end

  def message(socket : Fuel::SocketConnection, raw : String) : Nil
    socket.enqueue(raw)
  end

  def send_message(socket : Fuel::SocketConnection, raw : String) : Nil
    socket.write(raw)
  end

  def send_snapshot(socket : Fuel::SocketConnection) : Nil
    socket.write(%({"snapshot":true}))
  end
end

class AwaitedSetupPeer < SocketTestPeer
  getter entered = Channel(Nil).new(1)
  getter? setup_done = false
  getter? early_snapshot = false

  def initialize(@native : Bool)
  end

  def start(socket : Fuel::SocketConnection) : Nil
    setup(socket) unless @native
  end

  def message(socket : Fuel::SocketConnection, raw : String) : Nil
    setup(socket)
  end

  private def setup(socket)
    socket.admit("account")
    @entered.send(nil)
    sleep 20.milliseconds
    socket.check_open
    @setup_done = true
  end

  def send_snapshot(socket : Fuel::SocketConnection) : Nil
    unless @setup_done
      @early_snapshot = true
      raise "snapshot before setup"
    end
    super
  end
end

describe Fuel::SocketServer do
  [false, true].each do |native|
    it "waits for #{native ? "native authentication" : "initial"} post-admission setup before output" do
      sockets = Fuel::SocketServer.new([] of String, interval: 1.millisecond)
      peer = AwaitedSetupPeer.new(native)
      server = HTTP::Server.new do |context|
        sockets.upgrade(context) { |_| peer.as(Fuel::SocketPeer) }
      end
      address = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      socket = HTTP::WebSocket.new(address.address, "/socket", address.port)
      received = Channel(String).new(32)
      socket.on_message { |raw| received.send(raw) }
      spawn { socket.run }
      begin
        socket.send("{}") if native
        select
        when peer.entered.receive
        when timeout(1.second)
          fail "setup did not start"
        end
        sleep 40.milliseconds
        peer.early_snapshot?.should be_false
        peer.setup_done?.should be_true
        select
        when raw = received.receive
          raw.should eq(%({"snapshot":true}))
        when timeout(1.second)
          fail "ready setup did not receive a snapshot"
        end
      ensure
        socket.close
        100.times { break if sockets.budget.active == 0; sleep 1.millisecond }
        sockets.budget.active.should eq(0)
        server.close
      end
    end
  end
  it "closes an overflowing reliable queue and frees only its own permit" do
    server = Fuel::SocketServer.new([] of String)
    io = StalledSocketIO.new
    permit = server.budget.reserve
    connection = Fuel::SocketConnection.new(io, permit, server, 10.milliseconds, 1.second, 16384)
    stopped = Channel(Nil).new(1)
    spawn do
      connection.run(SocketTestPeer.new)
      stopped.send(nil)
    end
    io.entered.receive
    32.times { connection.enqueue("{}") }
    expect_raises(Fuel::Error, "capacity") { connection.enqueue("{}") }
    select
    when stopped.receive
    when timeout(1.second)
      fail "overflow did not finish stalled IO"
    end
    connection.closed?.should be_true
    server.connected?("account").should be_false
    server.budget.active.should eq(0)
  end

  it "delivers successive reliable events to both admitted peers" do
    sockets = Fuel::SocketServer.new([] of String, interval: 10.milliseconds)
    server = HTTP::Server.new do |context|
      sockets.upgrade(context) { |_| SocketTestPeer.new.as(Fuel::SocketPeer) }
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    received = [Channel(String).new(32), Channel(String).new(32)]
    clients = received.map do |messages|
      socket = HTTP::WebSocket.new(address.address, "/socket", address.port)
      socket.on_message { |raw| messages.send(raw) unless raw.includes?("snapshot") }
      spawn { socket.run }
      socket
    end
    begin
      100.times { break if sockets.budget.active == 2; sleep 1.millisecond }
      # Initial start/admission can yield independently of the HTTP upgrade.
      sleep 20.milliseconds
      sockets.broadcast("account", %({"receipt":1}))
      sockets.broadcast("account", %({"receipt":2}))
      received.each do |messages|
        [1, 2].each do |expected|
          select
          when raw = messages.receive
            JSON.parse(raw)["receipt"].as_i.should eq(expected)
          when timeout(1.second)
            fail "reliable event was lost or coalesced"
          end
        end
      end
    ensure
      clients.each(&.close)
      100.times { break if sockets.budget.active == 0; sleep 1.millisecond }
      sockets.budget.active.should eq(0)
      server.close
    end
  end
  it "rejects invalid handshake before constructing or admitting the application peer" do
    sockets = Fuel::SocketServer.new(["https://game.example"])
    constructed = 0
    server = HTTP::Server.new do |context|
      begin
        sockets.upgrade(context) do |socket|
          constructed += 1
          SocketTestPeer.new.as(Fuel::SocketPeer)
        end
      rescue Fuel::Error
        context.response.status_code = 400
      end
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    client = HTTP::Client.new(address.address, address.port)
    begin
      headers = HTTP::Headers{"Upgrade" => "websocket", "Connection" => "Upgrade", "Sec-WebSocket-Version" => "13", "Sec-WebSocket-Key" => "invalid"}
      client.get("/socket", headers).status_code.should eq(400)
      constructed.should eq(0)
      sockets.budget.active.should eq(0)
    ensure
      client.close
      server.close
    end
  end

  it "sends snapshots to idle players and releases permits after physical close" do
    sockets = Fuel::SocketServer.new([] of String, interval: 10.milliseconds)
    server = HTTP::Server.new do |context|
      sockets.upgrade(context) { |_| SocketTestPeer.new.as(Fuel::SocketPeer) }
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    socket = HTTP::WebSocket.new(address.address, "/socket", address.port)
    received = Channel(String).new(1)
    socket.on_message { |raw| received.send(raw) }
    spawn { socket.run }
    begin
      select
      when raw = received.receive
        raw.should eq(%({"snapshot":true}))
      when timeout(2.seconds)
        fail "idle peer did not receive a snapshot"
      end
    ensure
      socket.close
      100.times { break if sockets.budget.active == 0; sleep 1.millisecond }
      sockets.budget.active.should eq(0)
      server.close
    end
  end
end
