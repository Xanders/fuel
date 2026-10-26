require "./socket"

module Fuel
  class SessionSocketPeer < SocketPeer
    @room : Room?
    @generation : String?
    @actor : String?

    def initialize(@store : Store, @sessions : Sessions, @credential : Credential,
                   @session : String, @limiter : Limiter, @analytics : Questmetry?, @account_rules : AccountRules? = nil,
                   @accepting : Proc(Bool) = -> { true }, @expected_account : String? = nil)
    end

    def start(socket : SocketConnection) : Nil
      @store.with_accounts(@credential, [] of String, @account_rules) do |_, actor, profiles, preferences|
        Fuel.check(@expected_account.in?(nil, actor), "selection_changed")
        socket.admit(actor)
        room = @sessions.get(@session)
        room.preference(actor, preferences[actor])
        Fuel.check(@accepting.call || @sessions.active?(room), "maintenance")
        @generation = room.connect(actor, progress: profiles[actor])
        @actor = actor
        @room = room
      end
    end

    def message(socket : SocketConnection, raw : String) : Nil
      data = JSON.parse(raw)
      @store.with_accounts(@credential, [] of String, @account_rules) do |_, actor, profiles, preferences|
        socket.check_open
        room = @room.not_nil!
        room.preference(actor, preferences[actor])
        Fuel.check(@accepting.call || @sessions.active?(room), "maintenance")
        Fuel.check(data["epoch"].as_s == room.epoch, "session_lost")
        @limiter.check("input:#{actor}", 120, 1)
        room.input(actor, @generation.not_nil!, data["sequence"].as_s.to_i64, data["action"], progress: profiles[actor])
      end
    rescue error : Error
      raise error unless error.code == "session_ended"
      send_snapshot(socket)
    end

    def send_message(socket : SocketConnection, raw : String) : Nil
      @store.with_accounts(@credential, [] of String, @account_rules) do |_, actor, profiles, preferences|
        @room.not_nil!.preference(actor, preferences[actor])
        @room.not_nil!.check(actor, @generation, profiles[actor])
        socket.write(raw)
      end
    end

    def send_snapshot(socket : SocketConnection) : Nil
      room = @room.not_nil!
      @store.with_accounts(@credential, [] of String, @account_rules) do |_, actor, profiles, preferences|
        room.preference(actor, preferences[actor])
        socket.check_open
        state = room.snapshot(actor, @generation, profiles[actor])
        socket.write({wire_version: 1, account_id: actor, generation: @generation, data: state}.to_json)
      end
      room.persist_result(@store, @credential, @analytics)
    end

    def closed(socket : SocketConnection) : Nil
      if (room = @room) && (actor = @actor) && (generation = @generation)
        room.disconnect(actor, generation)
      end
    end
  end
end
