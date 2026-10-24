require "http/web_socket"
require "base64"

module Fuel
  # Monotonic process-local admission; persistent issuance limits stay in Store.
  class Limiter
    @started = Time.instant
    @entries = {} of String => Tuple(Int64, Int32)
    @purged_at = Int64::MIN

    def initialize(@capacity : Int32 = 10000)
      Fuel.check(@capacity > 0, "invalid_limit")
    end

    def check(key : String, count : Int32, window : Int64, now : Int64 = @started.elapsed.total_seconds.to_i64)
      Fuel.check(key.bytesize <= 256 && count > 0 && window > 0, "invalid_limit")
      if !@entries.has_key?(key) && @entries.size >= @capacity && @purged_at != now
        @entries.reject! { |_, entry| entry[0] <= now }
        @purged_at = now
      end
      expires, used = @entries[key]? || {now + window, 0}
      expires, used = now + window, 0 if expires <= now
      Fuel.check(used < count, "rate_limit")
      Fuel.check(@entries.has_key?(key) || @entries.size < @capacity, "capacity")
      @entries[key] = {expires, used + 1}
    end
  end

  class SocketPermit
    def initialize(@budget : SocketBudget, @token : UInt64)
    end

    def admit(account : String)
      @budget.admit(@token, account)
    end

    def release
      @budget.release(@token)
    end
  end

  class SocketBudget
    @mutex = Mutex.new
    @permits = {} of UInt64 => String?
    @accounts = {} of String => Int32
    @token = 0_u64

    def initialize(@capacity : Int32 = 128, @per_account : Int32 = 2)
      Fuel.check(@capacity > 0 && @per_account > 0, "invalid_limit")
    end

    def active : Int32
      @mutex.synchronize { @permits.size }
    end

    def reserve : SocketPermit
      @mutex.synchronize do
        Fuel.check(@permits.size < @capacity, "capacity")
        @token += 1
        @permits[@token] = nil
        SocketPermit.new(self, @token)
      end
    end

    # :nodoc:
    def admit(token : UInt64, account : String)
      @mutex.synchronize do
        Fuel.check(@permits.has_key?(token), "closed")
        Fuel.check(@permits[token].nil?, "already_admitted")
        count = @accounts[account]? || 0
        Fuel.check(count < @per_account, "capacity")
        @accounts[account] = count + 1
        @permits[token] = account
      end
    end

    # :nodoc:
    def release(token : UInt64)
      @mutex.synchronize do
        if account = @permits.delete(token)
          count = @accounts[account] - 1
          if count == 0
            @accounts.delete(account)
          else
            @accounts[account] = count
          end
        end
      end
    end
  end

  # Reads masked client frames in fixed chunks, before any JSON allocation.
  # Protocol#receive flattens continuation metadata, so validate headers here.
  class SocketFrames
    def initialize(@io : IO, @limit : Int32 = 16384)
      Fuel.check(@limit > 0, "invalid_limit")
    end

    def receive(&control : UInt8, String -> Nil) : String?
      message = IO::Memory.new
      fragmented = false
      buffer = Bytes.new(4096)
      mask = Bytes.new(4)
      loop do
        first = @io.read_byte || raise IO::EOFError.new
        second = @io.read_byte || raise IO::EOFError.new
        final = first & 0x80 != 0
        opcode = first & 0x0f
        Fuel.check(first & 0x70 == 0 && second & 0x80 != 0, "invalid_request")
        size = (second & 0x7f).to_u64
        if size == 126
          size = @io.read_bytes(UInt16, IO::ByteFormat::NetworkEndian).to_u64
          Fuel.check(size >= 126, "invalid_request")
        elsif size == 127
          size = @io.read_bytes(UInt64, IO::ByteFormat::NetworkEndian)
          Fuel.check(size > UInt16::MAX && size <= Int64::MAX, "invalid_request")
        end
        is_control = opcode >= 8
        if is_control
          Fuel.check(opcode.in?(8, 9, 10) && final && size <= 125, "invalid_request")
        else
          Fuel.check(opcode == 0 && fragmented || opcode == 1 && !fragmented, "invalid_request")
          Fuel.check(size <= @limit.to_u64 - message.size, "too_large")
          fragmented = !final
        end
        @io.read_fully(mask)
        target = is_control ? IO::Memory.new : message
        offset = 0_u64
        while offset < size
          count = {size - offset, buffer.size.to_u64}.min.to_i
          @io.read_fully(buffer[0, count])
          count.times { |i| buffer[i] ^= mask[(offset + i) % 4] }
          target.write(buffer[0, count])
          offset += count
        end
        if is_control
          payload = target.to_s
          if opcode == 8
            Fuel.check(payload.bytesize != 1, "invalid_request")
            if payload.bytesize >= 2
              code = IO::ByteFormat::NetworkEndian.decode(UInt16, payload.to_slice)
              valid = (1000..1014).includes?(code) && !code.in?(1004, 1005, 1006) || (3000..4999).includes?(code)
              Fuel.check(valid && String.new(payload.to_slice[2..]).valid_encoding?, "invalid_request")
            end
          end
          yield opcode, payload
          return nil if opcode == 8
        elsif final
          payload = message.to_s
          Fuel.check(payload.valid_encoding?, "invalid_request")
          return payload
        end
      end
    end
  end

  # Each callback must revalidate authority across its effect/physical-send
  # boundary. Application wire formats and game state remain in this adapter.
  abstract class SocketPeer
    abstract def start(socket : SocketConnection) : Nil
    abstract def message(socket : SocketConnection, raw : String) : Nil
    abstract def send_message(socket : SocketConnection, raw : String) : Nil
    abstract def send_snapshot(socket : SocketConnection) : Nil

    def closed(socket : SocketConnection) : Nil
    end
  end

  # A compact adapter for existing wire handlers that keep state in closures.
  class SocketCallbacks < SocketPeer
    def initialize(@on_start : Proc(SocketConnection, Nil),
                   @on_message : Proc(SocketConnection, String, Nil),
                   @on_snapshot : Proc(SocketConnection, Nil),
                   @on_send : Proc(SocketConnection, String, Nil),
                   @on_close : Proc(SocketConnection, Nil))
    end

    def start(socket : SocketConnection) : Nil
      @on_start.call(socket)
    end

    def message(socket : SocketConnection, raw : String) : Nil
      @on_message.call(socket, raw)
    end

    def send_snapshot(socket : SocketConnection) : Nil
      @on_snapshot.call(socket)
    end

    def send_message(socket : SocketConnection, raw : String) : Nil
      @on_send.call(socket, raw)
    end

    def closed(socket : SocketConnection) : Nil
      @on_close.call(socket)
    end
  end

  class SocketConnection
    getter? closed = false
    getter? admitted = false
    @queue = Deque(Tuple(UInt8, String)).new
    @closing = false
    @output_ready = false
    @wake = Channel(Nil).new(1)
    @stopped = Channel(Nil).new
    @protocol : HTTP::WebSocket::Protocol
    @account : String?

    def initialize(@io : IO, @permit : SocketPermit, @server : SocketServer, @interval : Time::Span,
                   @auth_timeout : Time::Span, @message_limit : Int32,
                   @queue_limit : Int32 = 32, @output_limit : Int32 = 65536)
      @protocol = HTTP::WebSocket::Protocol.new(@io, sync_close: false)
    end

    def check_open
      Fuel.check(!@closed && !@closing, "closed")
    end

    def admit(account : String)
      check_open
      @permit.admit(account)
      @server.attach(account, self)
      @account = account
      @admitted = true
      nil
    end

    def enqueue(raw : String, pong = false)
      check_open
      Fuel.check(!@closing, "closed")
      if raw.bytesize > @output_limit || @queue.size >= @queue_limit
        close
        raise Error.new("capacity")
      end
      @queue << {pong ? 10_u8 : 1_u8, raw}
      select
      when @wake.send(nil)
      else
      end
      nil
    end

    # Only the engine's single writer calls this, inside the peer's auth guard.
    def write(raw : String)
      check_open
      Fuel.check(raw.bytesize <= @output_limit, "too_large")
      @protocol.send(raw)
    end

    def close
      return if @closed
      @closed = true
      @queue.clear
      @wake.close
      @stopped.close
      @io.close rescue nil
      nil
    end

    def run(peer : SocketPeer)
      done = Channel(Nil).new(1)
      spawn do
        select
        when @stopped.receive?
        when timeout(@auth_timeout)
          close unless @admitted
        end
      end
      spawn do
        begin
          next_snapshot = Time.instant
          until @closed
            if packet = @queue.first?
              if @output_ready || packet[0] >= 8
                @queue.shift
                if packet[0] == 8
                  @protocol.send(packet[1].to_slice, HTTP::WebSocket::Protocol::Opcode::CLOSE)
                  close
                  break
                elsif packet[0] == 10
                  @protocol.pong(packet[1])
                else
                  peer.send_message(self, packet[1])
                end
              end
            end
            if @output_ready && !@closing && Time.instant >= next_snapshot
              peer.send_snapshot(self)
              next_snapshot = Time.instant + @interval
            end
            next if @output_ready && !@queue.empty?
            select
            when @wake.receive?
            when timeout(@interval)
            end
          end
        rescue
          close
        ensure
          done.send(nil)
        end
      end
      begin
        writer_finished = false
        peer.start(self)
        @output_ready = @admitted && !@closed
        reader = SocketFrames.new(@io, @message_limit)
        until @closed
          raw = reader.receive do |opcode, payload|
            enqueue(payload, pong: true) if opcode == 9
            if opcode == 8
              @closing = true
              @queue.clear
              @queue << {8_u8, payload}
              select
              when @wake.send(nil)
              else
              end
            end
          end
          unless raw
            select
            when done.receive
              writer_finished = true
            when timeout(3.seconds)
              close
            end
            break
          end
          check_open
          peer.message(self, raw)
          @output_ready = @admitted && !@closed
        end
      rescue
        # Malformed input, revocation and failed IO all detach the same owner.
      ensure
        close
        # Keep the permit while a writer still owns an awaited auth/send.
        done.receive unless writer_finished
        begin
          if account = @account
            @server.detach(account, self)
          end
          peer.closed(self)
        ensure
          @permit.release
        end
      end
    end
  end

  class SocketServer
    getter budget : SocketBudget
    getter limiter = Limiter.new
    @peers = {} of String => Set(SocketConnection)

    def connected?(account : String) : Bool
      @peers[account]?.try(&.any? { |peer| !peer.closed? }) || false
    end

    def broadcast(account : String, raw : String)
      if peers = @peers[account]?
        peers.dup.each do |peer|
          begin
            peer.enqueue(raw)
          rescue Fuel::Error
            # Overflow closes this peer; other viewers still receive the event.
          end
        end
      end
      nil
    end

    # :nodoc:
    def attach(account : String, peer : SocketConnection)
      (@peers[account] ||= Set(SocketConnection).new).add(peer)
    end

    # :nodoc:
    def detach(account : String, peer : SocketConnection)
      if peers = @peers[account]?
        peers.delete(peer)
        @peers.delete(account) if peers.empty?
      end
    end

    def initialize(@origins : Array(String), @capacity : Int32 = 128,
                   per_account : Int32 = 2, @interval : Time::Span = 100.milliseconds,
                   @auth_timeout : Time::Span = 10.seconds, @message_limit : Int32 = 16384,
                   @queue_limit : Int32 = 32, @output_limit : Int32 = 65536)
      @budget = SocketBudget.new(@capacity, per_account)
      Fuel.check(@interval > Time::Span.zero && @auth_timeout > Time::Span.zero &&
                 @message_limit > 0 && @queue_limit > 0 && @output_limit > 0, "invalid_limit")
    end

    def upgrade(context : HTTP::Server::Context, &factory : SocketConnection -> SocketPeer)
      request = context.request
      Fuel.check(request.method == "GET" && request.headers["Upgrade"]?.try(&.downcase) == "websocket", "invalid_request")
      Fuel.check(request.headers["Connection"]?.try { |v| v.downcase.split(',').map(&.strip).includes?("upgrade") } == true, "invalid_request")
      Fuel.check(request.headers["Sec-WebSocket-Version"]? == "13", "unsupported_version")
      Fuel.check((request.content_length || 0) == 0 && !request.headers.has_key?("Transfer-Encoding"), "invalid_request")
      key = request.headers["Sec-WebSocket-Key"]? || raise Error.new("invalid_request")
      begin
        Fuel.check(key.bytesize == 24, "invalid_request")
        decoded = Base64.decode(key)
        Fuel.check(decoded.size == 16 && Base64.strict_encode(decoded) == key, "invalid_request")
      rescue ArgumentError
        raise Error.new("invalid_request")
      end
      origin = request.headers["Origin"]?
      Fuel.check(!origin || @origins.includes?(origin), "forbidden")
      Fuel.check(!request.headers["Cookie"]? || !origin.nil?, "forbidden")
      Fuel.check(request.headers["Sec-Fetch-Site"]? != "cross-site", "forbidden")
      Fuel.check(@budget.active < @capacity, "capacity")
      context.response.status_code = 101
      context.response.headers["Upgrade"] = "websocket"
      context.response.headers["Connection"] = "Upgrade"
      context.response.headers["Sec-WebSocket-Accept"] = HTTP::WebSocket::Protocol.key_challenge(key)
      context.response.upgrade do |io|
        permit = nil
        begin
          # Reserve in the upgrade callback: a failed HTTP header flush must not
          # leak a permit. Recheck capacity before constructing any game peer.
          permit = @budget.reserve
          io.write_timeout = 3.seconds if io.responds_to?(:write_timeout=)
          socket = SocketConnection.new(io, permit, self, @interval, @auth_timeout,
            @message_limit, @queue_limit, @output_limit)
          socket.run(factory.call(socket))
        ensure
          permit.try(&.release)
          io.close rescue nil
        end
      end
    end
  end
end
