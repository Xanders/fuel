require "./socket"

module Fuel
  class SessionSocketPeer < SocketPeer
    @room : Room?
    @generation : String?

    def initialize(@store : Store, @sessions : Sessions, @credential : Credential,
                   @session : String, @limiter : Limiter, @analytics : Questmetry?)
    end

    def start(socket : SocketConnection) : Nil
      @store.with_actor(@credential) do |_, actor|
        socket.admit(actor)
        room = @sessions.get(@session)
        @generation = room.connect(actor)
        @room = room
      end
    end

    def message(socket : SocketConnection, raw : String) : Nil
      data = JSON.parse(raw)
      @store.with_actor(@credential) do |_, actor|
        socket.check_open
        room = @room.not_nil!
        Fuel.check(data["epoch"].as_s == room.epoch, "session_lost")
        @limiter.check("input:#{actor}", 120, 1)
        room.input(actor, @generation.not_nil!, data["sequence"].as_s.to_i64, data["action"])
      end
    end

    def send_message(socket : SocketConnection, raw : String) : Nil
      @store.with_actor(@credential) { |_, _| socket.write(raw) }
    end

    def send_snapshot(socket : SocketConnection) : Nil
      room = @room.not_nil!
      @store.with_actor(@credential) do |_, actor|
        socket.check_open
        state = room.snapshot(actor, @generation)
        socket.write({wire_version: 1, generation: @generation, data: state}.to_json)
      end
      room.persist_result(@store, @credential, @analytics)
    end
  end
end
