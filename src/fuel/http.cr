require "http/server"
require "http/web_socket"

module Fuel
  class Handler
    include HTTP::Handler
    @polls = Set(String).new
    @sockets = 0
    @mutex = Mutex.new
    getter chat : Chat

    def initialize(@store : Store, @sessions : Sessions, @origins : Array(String), @analytics : Questmetry? = nil,
                   censor = Censor.new([] of String), persisted_chat = [] of String,
                   @guild_access : Proc(String, String, Bool) = ->(actor : String, guild : String) { false },
                   @deletion_hook : Proc(DB::Connection, String, Nil)? = nil)
      @chat = Chat.new(censor: censor, store: @store, persist: persisted_chat) do |actor, kind, target|
        kind == "global" || (kind == "session" && @sessions.get(target).member?(actor)) || (kind == "guild" && @guild_access.call(actor, target))
      end
    end

    def call(context : HTTP::Server::Context)
      response = context.response
      response.content_type = "application/json"
      response.headers["Cache-Control"] = "no-store"
      response.headers["X-Content-Type-Options"] = "nosniff"
      check_origin(context)
      path = context.request.path
      if path == "/health"
        reply(context, Fuel.json({version: VERSION}))
        return
      end
      Fuel.check(context.request.headers["X-Fuel-Version"]?.in?(nil, "1"), "unsupported_version")
      if ["/fuel/v1/auth/prepare", "/fuel/v1/auth/pair/prepare"].includes?(path) && context.request.method == "GET"
        slot = path.ends_with?("pair/prepare") ? "__Host-fuel-candidate" : "__Host-fuel"
        credential = read_credential(context, slot) || Credential.new(Fuel.id, Random::Secure.hex(32))
        if slot == "__Host-fuel-candidate"
          renew = context.request.query_params["new"]? == "true"
          begin
            status = @store.pair_status(credential)["status"].as_s
            retained = [read_credential(context).try(&.id), read_credential(context, "__Host-fuel-previous").try(&.id)]
            renew ||= ["expired", "cancelled"].includes?(status) || status == "linked" && retained.includes?(credential.id)
          rescue error : Fuel::Error
            raise error unless ["unauthorized", "invalid_code"].includes?(error.code)
          end
          credential = Credential.new(Fuel.id, Random::Secure.hex(32)) if renew
        end
        cookie(context, credential, slot)
        reply(context, Fuel.json({status: "prepared"}))
        return
      end
      candidate_path = ["/fuel/v1/auth/pair/request", "/fuel/v1/auth/pair/status", "/fuel/v1/auth/pair/activate"].includes?(path)
      slot = candidate_path ? "__Host-fuel-candidate" : "__Host-fuel"
      credential = read_credential(context, slot) || raise Error.new("unauthorized")
      data = context.request.method == "POST" ? body(context) : JSON.parse("{}")
      if path == "/fuel/v1/auth/pair/activate" && context.request.method == "POST"
        account = @store.authenticate(credential)
        if previous = read_credential(context)
          cookie(context, previous, "__Host-fuel-previous") if previous.id != credential.id
        end
        cookie(context, credential)
        reply(context, Fuel.json({account_id: account}))
        return
      elsif path == "/fuel/v1/auth/switch" && context.request.method == "POST"
        previous = read_credential(context, "__Host-fuel-previous") || raise Error.new("unauthorized")
        account = @store.authenticate(previous)
        cookie(context, credential, "__Host-fuel-previous")
        cookie(context, previous)
        reply(context, Fuel.json({account_id: account}))
        return
      end
      if path == "/fuel/v1/stream"
        stream(context, credential)
        return
      end
      address = context.request.remote_address
      source = address.is_a?(Socket::IPAddress) ? address.address : "unknown"
      result = if path == "/fuel/v1/auth/bootstrap" && context.request.method == "POST"
                 Fuel.json({account_id: @store.bootstrap(credential, source)})
               elsif path == "/fuel/v1/auth/pair/request" && context.request.method == "POST"
                 @store.request_pair(data["code"].as_s, credential, source)
               elsif path == "/fuel/v1/auth/pair/status" && context.request.method == "GET"
                 @store.pair_status(credential)
               else
                 dispatch(context, credential, data)
               end
      session_parts = path.split('/')
      if session_parts.size >= 5 && session_parts[1..3] == ["fuel", "v1", "sessions"] && !path.ends_with?("/leave")
        @sessions.get(session_parts[4]).persist_result(@store, credential, @analytics)
      end
      cookie(context, credential, slot) if context.request.headers["Cookie"]?
      reply(context, result)
    rescue error : Error
      context.response.headers["Connection"] = "close" if error.code == "too_large"
      context.response.status_code = case error.code
                                     when "unauthorized"                                                                                      then 401
                                     when "forbidden"                                                                                         then 403
                                     when "not_found"                                                                                         then 404
                                     when "too_large"                                                                                         then 413
                                     when "capacity", "rate_limited", "poll_active"                                                           then 429
                                     when "conflict", "revision_conflict", "session_lost", "session_ended", "stale_input", "stale_connection" then 409
                                     else                                                                                                          400
                                     end
      context.response.print({wire_version: 1, error: error.code}.to_json)
    rescue JSON::ParseException | TypeCastError | KeyError | ArgumentError | OverflowError
      context.response.status_code = 400
      context.response.print({wire_version: 1, error: "invalid_request"}.to_json)
    rescue
      context.response.status_code = 503
      context.response.print({wire_version: 1, error: "unavailable"}.to_json)
    end

    private def dispatch(context, credential, data) : JSON::Any
      path = context.request.path.sub("/fuel/v1/", "")
      parts = path.split('/')
      method = context.request.method
      if method == "GET" && parts.size == 3 && parts[0] == "sessions" && parts[2] == "events"
        return poll(context, credential, parts[1])
      end
      if method == "POST" && path == "auth/pair"
        return @store.issue_pair(credential)
      elsif method == "POST" && path == "auth/pair/approve"
        return @store.approve_pair(credential, data["id"].as_s)
      elsif method == "GET" && path == "auth/pair/pending"
        return Fuel.json(@store.pending_pairs(credential))
      elsif method == "POST" && path == "auth/pair/cancel"
        @store.cancel_pair(credential, data["id"].as_s)
        return Fuel.json({status: "cancelled"})
      elsif method == "GET" && path == "auth/bindings"
        return Fuel.json(@store.bindings(credential))
      elsif method == "POST" && path == "auth/revoke"
        @store.revoke(credential, data["id"].as_s)
        return Fuel.json({status: "revoked"})
      elsif method == "GET" && path == "progress"
        return @store.progress(credential)
      elsif method == "POST" && path == "auth/delete"
        account = @store.authenticate(credential)
        @store.delete_account(credential, data["confirmed"].as_bool) { |c, owner| @deletion_hook.try(&.call(c, owner)) }
        @sessions.remove_account(account)
        @chat.remove_account(account)
        return Fuel.json({status: "deleted"})
      elsif method == "POST" && path == "analytics/enabled"
        analytics = @analytics || raise Error.new("not_configured")
        analytics.enabled(credential, data["enabled"].as_bool)
        return Fuel.json({status: "updated"})
      end
      @store.with_actor(credential) do |_, actor|
        @store.limit("request:#{actor}", 1200, 60)
        case {method, path}
        when {"POST", "sessions"}
          room = @sessions.create(actor, data["mode"].as_s, data["capacity"]?.try(&.as_i) || 2, data["public"]?.try(&.as_bool) || false, data["late_join"]?.try(&.as_bool) != false)
          Fuel.json({session_id: room.id, epoch: room.epoch, code: room.code})
        when {"GET", "sessions"}
          Fuel.json(@sessions.list(context.request.query_params["mode"]? || "duel"))
        when {"POST", "join"}
          room = if code = data["code"]?
                   @sessions.join_code(actor, code.as_s)
                 else
                   id = data["session_id"].as_s
                   Fuel.check(!@sessions.get(id).listing.nil?, "forbidden")
                   @sessions.join(actor, id)
                 end
          room.snapshot(actor)
        when {"POST", "match"}
          @sessions.match(actor, data["mode"].as_s, data["ticket_id"]?.try(&.as_s) || "default")
        when {"POST", "match/cancel"}
          @sessions.cancel_match(actor, data["mode"].as_s, data["ticket_id"]?.try(&.as_s) || "default")
        when {"POST", "chat"}
          @store.limit("chat:#{actor}", 8, 60)
          @chat.post(actor, data["kind"].as_s, data["target"].as_s, data["text"].as_s)
        when {"GET", "chat"}
          Fuel.json(@chat.history(actor, context.request.query_params["kind"], context.request.query_params["target"]? || ""))
        else
          if parts.size == 2 && parts[0] == "leaderboards" && method == "GET"
            Fuel.json(@store.leaderboard(parts[1], context.request.query_params["limit"]?.try(&.to_i) || 100))
          elsif parts.size == 2 && parts[0] == "ratings" && method == "GET"
            Fuel.json(@store.ratings(parts[1], context.request.query_params["metric"]? || "wins", context.request.query_params["hours"]?.try(&.to_i) || 24))
          elsif parts.size == 2 && parts[0] == "sessions" && method == "GET"
            @sessions.snapshot(actor, parts[1])
          elsif parts.size == 3 && parts[0] == "sessions" && method == "POST"
            room = @sessions.get(parts[1])
            case parts[2]
            when "commands"
              room.command(actor, data["epoch"].as_s, data["id"].as_s, data["revision"].as_s.to_i64, data["action"])
            when "ready"
              room.ready(actor)
              room.snapshot(actor)
            when "leave"
              room.leave(actor)
              Fuel.json({status: "left"})
            else
              raise Error.new("not_found")
            end
          else
            raise Error.new("not_found")
          end
        end
      end
    end

    private def poll(context, credential, session) : JSON::Any
      @mutex.synchronize do
        Fuel.check(!@polls.includes?(credential.id), "poll_active")
        Fuel.check(@polls.size < 256, "capacity")
        @polls.add(credential.id)
      end
      begin
        revision = context.request.query_params["cursor"]? || ""
        epoch = context.request.query_params["epoch"]? || ""
        deadline = Time.instant + 15.seconds
        loop do
          state = @store.with_actor(credential) { |_, actor| @sessions.snapshot(actor, session) }
          Fuel.check(epoch.empty? || state["epoch"] == epoch, "session_lost")
          return state if state["revision"].as_s != revision || Time.instant >= deadline
          sleep 100.milliseconds
        end
      ensure
        @mutex.synchronize { @polls.delete(credential.id) }
      end
    end

    private def body(context) : JSON::Any
      Fuel.check((context.request.content_length || 0) <= 65536, "too_large")
      memory = IO::Memory.new
      if input = context.request.body
        IO.copy(input, memory, 65537)
      end
      Fuel.check(memory.size <= 65536, "too_large")
      JSON.parse(memory.empty? ? "{}" : memory.to_s)
    end

    private def reply(context, result)
      context.response.print({wire_version: 1, data: result}.to_json)
    end

    private def check_origin(context)
      origin = context.request.headers["Origin"]?
      Fuel.check(@origins.includes?(origin), "forbidden") if origin
      if context.request.headers["Cookie"]? && context.request.method != "GET"
        Fuel.check(!origin.nil? && @origins.includes?(origin), "forbidden")
      end
      if context.request.path == "/fuel/v1/stream" && context.request.headers["Cookie"]?
        Fuel.check(!origin.nil? && @origins.includes?(origin), "forbidden")
      end
    end

    private def read_credential(context, slot = "__Host-fuel") : Credential?
      if header = context.request.headers["Authorization"]?
        Fuel.check(header.starts_with?("Fuel "), "unauthorized")
        parts = header[5..].split(':', 2)
        Fuel.check(parts.size == 2, "unauthorized")
        return Credential.new(parts[0], parts[1])
      end
      if value = context.request.cookies[slot]?.try(&.value)
        parts = value.split(':', 2)
        Fuel.check(parts.size == 2, "unauthorized")
        Credential.new(parts[0], parts[1])
      end
    end

    private def cookie(context, credential, slot = "__Host-fuel")
      context.response.headers.add("Set-Cookie", "#{slot}=#{credential.id}:#{credential.secret}; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=34560000")
    end

    private def stream(context, credential)
      Fuel.check(context.request.method == "GET" && context.request.headers["Upgrade"]?.try(&.downcase) == "websocket", "invalid_request")
      session = context.request.query_params["session_id"]
      actor = @store.authenticate(credential)
      room = @sessions.get(session)
      generation = room.connect(actor)
      key = context.request.headers["Sec-WebSocket-Key"]? || raise Error.new("invalid_request")
      Fuel.check(context.request.headers["Sec-WebSocket-Version"]? == "13", "unsupported_version")
      @mutex.synchronize { Fuel.check(@sockets < 128, "capacity"); @sockets += 1 }
      context.response.status_code = 101
      context.response.headers["Upgrade"] = "websocket"
      context.response.headers["Connection"] = "Upgrade"
      context.response.headers["Sec-WebSocket-Accept"] = HTTP::WebSocket::Protocol.key_challenge(key)
      context.response.upgrade do |io|
        io.read_timeout = 30.seconds if io.responds_to?(:read_timeout=)
        io.write_timeout = 3.seconds if io.responds_to?(:write_timeout=)
        protocol = HTTP::WebSocket::Protocol.new(io, sync_close: false)
        lock = Mutex.new
        closed = false
        spawn do
          begin
            until closed
              @store.with_actor(credential) do |_, verified|
                state = room.snapshot(verified, generation)
                lock.synchronize { protocol.send({wire_version: 1, generation: generation, data: state}.to_json) }
              end
              room.persist_result(@store, credential, @analytics)
              sleep 100.milliseconds
            end
          rescue
            io.close
          end
        end
        begin
          buffer = Bytes.new(4096)
          message = IO::Memory.new
          loop do
            frame = protocol.receive(buffer)
            case frame.opcode
            when .close?
              break
            when .ping?
              lock.synchronize { protocol.pong(String.new(buffer[0, frame.size])) }
            when .text?
              Fuel.check(message.size + frame.size <= 16384, "too_large")
              message.write(buffer[0, frame.size])
              if frame.final
                data = JSON.parse(message.to_s)
                message.clear
                Fuel.check(data["epoch"].as_s == room.epoch, "session_lost")
                @store.with_actor(credential) do |_, verified|
                  @store.limit("input:#{verified}", 120, 1)
                  room.input(verified, generation, data["sequence"].as_s.to_i64, data["action"])
                end
              end
            else
              raise Error.new("invalid_request")
            end
          end
        rescue
          # Malformed/oversized input and revocation close the connection.
        ensure
          closed = true
          io.close
          @mutex.synchronize { @sockets -= 1 }
        end
      end
    end
  end
end
