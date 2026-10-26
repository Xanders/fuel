require "http/server"
require "http/web_socket"

module Fuel
  class Handler
    include HTTP::Handler
    @polls = Set(String).new
    @sockets : SocketServer
    @mutex = Mutex.new
    getter chat : Chat
    getter prefix : String
    property accepting : Proc(Bool) = -> { true }

    def close
      @sockets.close
    end

    def closed? : Bool
      @sockets.closed? && @sockets.budget.active == 0
    end

    def initialize(@store : Store, @sessions : Sessions, @origins : Array(String), @analytics : Questmetry? = nil,
                   censor = Censor.new([] of String), persisted_chat = [] of String,
                   @guild_access : Proc(String, String, Bool) = ->(actor : String, guild : String) { false },
                   @deletion_hook : Proc(DB::Connection, String, Nil)? = nil,
                   @account_rules : AccountRules? = nil, @prefix : String = "/fuel/v1",
                   @leaderboard_reader : LeaderboardReader? = nil)
      Fuel.check(@prefix.matches?(/\A(?:\/[a-zA-Z0-9_-]+)+\z/), "invalid_prefix")
      @sockets = SocketServer.new(@origins)
      names = ->(actor : String, state : JSON::Any) { @account_rules.try(&.display_name(actor, state)) || actor }
      @chat = Chat.new(censor: censor, store: @store, persist: persisted_chat, display_name: names) do |actor, kind, target|
        kind == "global" || (kind == "session" && @sessions.get(target).member?(actor)) || (kind == "guild" && @guild_access.call(actor, target))
      end
    end

    def call(context : HTTP::Server::Context)
      response = context.response
      response.content_type = "application/json"
      response.headers["Cache-Control"] = "no-store"
      response.headers["X-Content-Type-Options"] = "nosniff"
      check_origin(context)
      path = api_path(context)
      if path == "/health"
        reply(context, Fuel.json({version: VERSION}))
        return
      end
      Fuel.check(context.request.headers["X-Fuel-Version"]?.in?(nil, "1"), "unsupported_version")
      unless @accepting.call
        session_mutation = path.starts_with?("/fuel/v1/sessions/") && context.request.method == "POST"
        allowed = context.request.method == "GET" || path.in?("/fuel/v1/analytics/enabled", "/fuel/v1/auth/delete/status") || session_mutation
        Fuel.check(allowed, "maintenance")
      end
      if path == "/fuel/v1/auth/delete/status" && context.request.method == "POST"
        data = body(context)
        result = @store.deletion_status(data["proof"].as_s, data["account_id"].as_s)
        if result["status"].as_s == "deleted"
          @sessions.remove_account(data["account_id"].as_s)
          @chat.remove_account(data["account_id"].as_s)
          clear_deleted_cookies(context, result)
        end
        reply(context, result)
        return
      end
      if ["/fuel/v1/auth/prepare", "/fuel/v1/auth/pair/prepare"].includes?(path) && context.request.method == "GET"
        slot = path.ends_with?("pair/prepare") ? "__Host-fuel-candidate" : "__Host-fuel"
        existing = read_credential(context, slot)
        credential = existing || Credential.new(Fuel.id, Random::Secure.hex(32))
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
        cookie(context, credential, slot) if existing.nil? || credential.id != existing.id
        reply(context, Fuel.json({status: "prepared"}))
        return
      end
      data = context.request.method == "POST" ? body(context) : JSON.parse("{}")
      if path == "/fuel/v1/auth/selection" && context.request.method == "GET"
        current = read_credential(context)
        previous = read_credential(context, "__Host-fuel-previous")
        candidate = read_credential(context, "__Host-fuel-candidate")
        selection = ->(proof : Credential?, slot : String) do
          if proof
            begin
              Fuel.json({binding_id: proof.id, account_id: @store.authenticate(proof)})
            rescue error : Error
              raise error unless error.code == "unauthorized"
              clear_cookie(context, slot)
              JSON.parse("null")
            end
          else
            JSON.parse("null")
          end
        end
        reply(context, Fuel.json({current: selection.call(current, "__Host-fuel"), previous: selection.call(previous, "__Host-fuel-previous"), candidate_id: candidate.try(&.id)}))
        return
      elsif path == "/fuel/v1/auth/switch" && context.request.method == "POST"
        current = read_credential(context)
        target = data["to"].as_s
        Fuel.key(target)
        if current.try(&.id) == target
          account = @store.authenticate(current.not_nil!)
        else
          Fuel.check(data["from"].as_s? == current.try(&.id), "conflict")
          previous = read_credential(context, "__Host-fuel-previous") || raise Error.new("unauthorized")
          Fuel.check(previous.id == target, "conflict")
          account = @store.authenticate(previous)
          cookie(context, current, "__Host-fuel-previous") if current
          cookie(context, previous)
        end
        reply(context, Fuel.json({account_id: account}))
        return
      end
      candidate_path = ["/fuel/v1/auth/pair/request", "/fuel/v1/auth/pair/status", "/fuel/v1/auth/pair/activate"].includes?(path)
      slot = candidate_path ? "__Host-fuel-candidate" : "__Host-fuel"
      credential = read_credential(context, slot) || raise Error.new("unauthorized")
      if path == "/fuel/v1/auth/pair/activate" && context.request.method == "POST"
        Fuel.check(data["target_id"].as_s == credential.id, "conflict")
        account = @store.authenticate(credential)
        if previous = read_credential(context)
          cookie(context, previous, "__Host-fuel-previous") if previous.id != credential.id
        end
        cookie(context, credential)
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
      if session_parts.size >= 5 && session_parts[1..3] == ["fuel", "v1", "sessions"] && session_parts[4] != "mine" && !path.ends_with?("/leave")
        @sessions.get(session_parts[4]).persist_result(@store, credential, @analytics)
      end
      reply(context, result)
    rescue error : Error
      code = error.code == "rate_limit" ? "rate_limited" : error.code
      context.response.headers["Connection"] = "close" if error.code == "too_large"
      context.response.status_code = case code
                                     when "unauthorized"                                                                                      then 401
                                     when "forbidden"                                                                                         then 403
                                     when "not_found"                                                                                         then 404
                                     when "too_large"                                                                                         then 413
                                     when "capacity", "rate_limited", "poll_active"                                                           then 429
                                     when "maintenance", "saving_backlog"                                                                     then 503
                                     when "conflict", "revision_conflict", "session_lost", "session_ended", "stale_input", "stale_connection" then 409
                                     else                                                                                                          400
                                     end
      context.response.print({wire_version: 1, error: code}.to_json)
    rescue JSON::ParseException | TypeCastError | KeyError | ArgumentError | OverflowError
      context.response.status_code = 400
      context.response.print({wire_version: 1, error: "invalid_request"}.to_json)
    rescue
      context.response.status_code = 503
      context.response.print({wire_version: 1, error: "unavailable"}.to_json)
    end

    private def dispatch(context, credential, data) : JSON::Any
      actor = @store.authenticate(credential)
      context.response.headers["X-Fuel-Account"] = actor
      Fuel.check(context.request.headers["X-Fuel-Expected-Account"]?.in?(nil, actor), "selection_changed")
      @sockets.limiter.check("http:#{actor}", 1200, 60)
      path = api_path(context).sub("/fuel/v1/", "")
      parts = path.split('/')
      method = context.request.method
      if method == "GET" && path == "account"
        return @store.account(credential, @account_rules || raise Error.new("not_configured"))
      elsif method == "POST" && path == "actions"
        return @store.execute(credential, data["id"].as_s, data["action"].as_s, data["payload"], (@account_rules || raise Error.new("not_configured")), @analytics)
      elsif method == "GET" && path == "operations"
        return Fuel.json(@store.operations(credential, context.request.query_params["after"]?, context.request.query_params["limit"]?.try(&.to_i) || 100, context.request.query_params["terminal"]? == "true"))
      elsif method == "GET" && parts.size == 2 && parts[0] == "operations"
        return @store.operation(credential, parts[1])
      elsif method == "GET" && path == "sessions/mine"
        return Fuel.json(@sessions.mine(actor))
      elsif method == "GET" && parts.size == 3 && parts[0] == "sessions" && parts[2] == "events"
        return poll(context, credential, parts[1])
      end
      if method == "POST" && path == "auth/pair"
        return @store.issue_pair(credential)
      elsif method == "POST" && path == "auth/pair/approve"
        return @store.approve_pair(credential, data["id"].as_s)
      elsif method == "GET" && path == "auth/pair/pending"
        return Fuel.json(@store.pending_pairs(credential))
      elsif method == "GET" && path == "auth/pair/issued"
        return @store.issued_pair(credential, context.request.query_params["id"])
      elsif method == "POST" && path == "auth/pair/cancel"
        @store.cancel_pair(credential, data["id"].as_s)
        return Fuel.json({status: "cancelled"})
      elsif method == "GET" && path == "auth/bindings"
        return Fuel.json(@store.bindings(credential))
      elsif method == "POST" && path == "auth/revoke"
        @store.revoke(credential, data["id"].as_s, data["confirmed_last"]?.try(&.as_bool) || false)
        return Fuel.json({status: "revoked"})
      elsif method == "GET" && path == "progress"
        return @store.progress(credential)
      elsif method == "POST" && path == "auth/delete"
        account = @store.authenticate(credential)
        result = @store.delete_account(credential, data["confirmed"].as_bool, data["proof"].as_s, data["account_id"].as_s) { |c, owner| @deletion_hook.try(&.call(c, owner)) }
        @sessions.remove_account(account)
        @chat.remove_account(account)
        clear_deleted_cookies(context, result)
        return result
      elsif method == "POST" && path == "analytics/events"
        analytics = @analytics || raise Error.new("not_configured")
        status = analytics.capture_client(credential, data["id"].as_s, data["name"].as_s,
          data["session"].as_s, data["properties"], data["revision"].as_s.to_i64)
        return Fuel.json({status: status})
      elsif method == "POST" && path == "analytics/enabled"
        analytics = @analytics || raise Error.new("not_configured")
        account = @store.authenticate(credential)
        revision = analytics.enabled(credential, data["enabled"].as_bool)
        @sessions.preference(account, revision)
        return Fuel.json({status: "updated", enabled: data["enabled"], revision: revision.to_s})
      elsif method == "GET" && path == "chat/mutes"
        return Fuel.json(@chat.muted(credential))
      elsif method == "POST" && path == "chat/mute"
        @chat.set_muted(credential, data["target"].as_s, data["muted"].as_bool)
        return Fuel.json({status: "updated"})
      elsif method == "POST" && path == "chat/report"
        @chat.report(credential, data["kind"].as_s, data["target"].as_s, data["message_id"].as_s, data["reason"].as_s)
        return Fuel.json({status: "reported"})
      end
      candidates = path == "match" ? @sessions.match_candidates(data["mode"].as_s) : [] of String
      @store.with_accounts(credential, candidates, @account_rules) do |connection, actor, profiles, preferences|
        @store.limit("request:#{actor}", 1200, 60, connection)
        progress = profiles[actor]
        case {method, path}
        when {"POST", "sessions"}
          room = @sessions.create(actor, data["mode"].as_s, data["capacity"]?.try(&.as_i) || 2, data["public"]?.try(&.as_bool) || false, data["late_join"]?.try(&.as_bool) != false, progress: progress, preferences: preferences)
          Fuel.json({session_id: room.id, epoch: room.epoch, code: room.code})
        when {"GET", "sessions"}
          Fuel.json(@sessions.list(context.request.query_params["mode"]? || "duel"))
        when {"POST", "join"}
          room = if code = data["code"]?
                   @sessions.join_code(actor, code.as_s, progress: progress, preferences: preferences)
                 else
                   id = data["session_id"].as_s
                   Fuel.check(!@sessions.get(id).listing.nil?, "forbidden")
                   @sessions.join(actor, id, progress: progress, preferences: preferences)
                 end
          room.snapshot(actor, progress: progress)
        when {"POST", "match"}
          @sessions.match(actor, data["mode"].as_s, data["ticket_id"]?.try(&.as_s) || "default", profiles: profiles, preferences: preferences)
        when {"POST", "match/cancel"}
          @sessions.cancel_match(actor, data["mode"].as_s, data["ticket_id"]?.try(&.as_s) || "default")
        when {"POST", "chat"}
          @store.limit("chat:#{actor}", 8, 60, connection)
          @chat.post(actor, data["kind"].as_s, data["target"].as_s, data["text"].as_s, progress)
        when {"GET", "chat"}
          Fuel.json(@chat.history(actor, context.request.query_params["kind"], context.request.query_params["target"]? || ""))
        else
          if parts.size == 3 && parts[0] == "leaderboards" && parts[2] == "page" && method == "GET"
            board = parts[1]
            limit = context.request.query_params["limit"]?.try(&.to_i) || 100
            Fuel.key(board)
            Fuel.check((1..100).includes?(limit), "invalid_limit")
            page = @leaderboard_reader.try(&.call(connection, @store.namespace, actor, board, limit)) || @store.leaderboard_page(connection, actor, board, limit)
            Fuel.check(page.to_json.bytesize <= 65536, "too_large")
            page
          elsif parts.size == 2 && parts[0] == "leaderboards" && method == "GET"
            Fuel.json(@store.leaderboard(parts[1], context.request.query_params["limit"]?.try(&.to_i) || 100))
          elsif parts.size == 2 && parts[0] == "ratings" && method == "GET"
            Fuel.json(@store.ratings(parts[1], context.request.query_params["metric"]? || "wins", context.request.query_params["hours"]?.try(&.to_i) || 24))
          elsif parts.size == 2 && parts[0] == "sessions" && method == "GET"
            room = @sessions.get(parts[1])
            room.preference(actor, preferences[actor])
            room.snapshot(actor, progress: progress)
          elsif parts.size == 3 && parts[0] == "sessions" && method == "POST"
            room = @sessions.get(parts[1])
            room.preference(actor, preferences[actor])
            Fuel.check(@accepting.call || @sessions.active?(room), "maintenance")
            case parts[2]
            when "commands"
              room.command(actor, data["epoch"].as_s, data["id"].as_s, data["revision"].as_s.to_i64, data["action"], progress: progress)
            when "ready"
              room.ready(actor, progress: progress)
              room.snapshot(actor, progress: progress)
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
        refresh_activity = true
        loop do
          Fuel.check(!@sockets.closed?, "maintenance")
          state = @store.with_accounts(credential, [] of String, @account_rules) do |_, actor, profiles, preferences|
            room = @sessions.get(session)
            room.preference(actor, preferences[actor])
            room.snapshot(actor, progress: profiles[actor], refresh_activity: refresh_activity)
          end
          refresh_activity = false
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
      Fuel.check(context.request.headers["Sec-Fetch-Site"]?.in?(nil, "same-origin", "none"), "forbidden")
      origin = context.request.headers["Origin"]?
      Fuel.check(@origins.includes?(origin), "forbidden") if origin
      if context.request.headers["Cookie"]? && context.request.method != "GET"
        Fuel.check(!origin.nil? && @origins.includes?(origin), "forbidden")
      end
      if context.request.path == "#{@prefix}/stream" && context.request.headers["Cookie"]?
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
      if value = context.request.cookies[cookie_name(slot)]?.try(&.value)
        parts = value.split(':', 2)
        Fuel.check(parts.size == 2, "unauthorized")
        Credential.new(parts[0], parts[1])
      end
    end

    private def cookie(context, credential, slot = "__Host-fuel")
      context.response.headers.add("Set-Cookie", "#{cookie_name(slot)}=#{credential.id}:#{credential.secret}; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=34560000")
    end

    private def clear_deleted_cookies(context, result : JSON::Any)
      removed = result["removed_bindings"].as_a.map(&.as_s)
      ["__Host-fuel", "__Host-fuel-previous", "__Host-fuel-candidate"].each do |slot|
        name = cookie_name(slot)
        if value = context.request.cookies[name]?.try(&.value)
          if removed.includes?(value.split(':', 2).first)
            clear_cookie(context, slot)
          end
        end
      end
    end

    private def clear_cookie(context, slot : String)
      context.response.headers.add("Set-Cookie", "#{cookie_name(slot)}=; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=0")
    end

    private def cookie_name(slot : String) : String
      slot.sub("__Host-fuel", "__Host-fuel-#{Digest::SHA256.hexdigest(@store.namespace)}")
    end

    private def api_path(context) : String
      path = context.request.path
      return path if path == "/health"
      Fuel.check(path.starts_with?("#{@prefix}/"), "not_found")
      "/fuel/v1/" + path[(@prefix.size + 1)..]
    end

    private def stream(context, credential)
      session = context.request.query_params["session_id"]
      @sockets.upgrade(context) do |_|
        SessionSocketPeer.new(@store, @sessions, credential, session, @sockets.limiter, @analytics, @account_rules, @accepting, context.request.query_params["account_id"]?).as(SocketPeer)
      end
    end
  end
end
