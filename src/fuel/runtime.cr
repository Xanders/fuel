require "mime"

module Fuel
  class Runtime
    include HTTP::Handler
    @server : HTTP::Server?
    @accepting = true
    @running = false
    @inflight = 0
    @workers = 0
    @effect_cursor = 0
    @mutex = Mutex.new

    def server : HTTP::Server
      @server.not_nil!
    end

    def initialize(@store : Store, @sessions : Sessions, @handler : Handler, @rules : AccountRules,
                   @analytics : Questmetry? = nil, @worker_limit = 8,
                   @static_root : String? = nil, @static_prefix = "/play/")
      Fuel.check(worker_limit > 0 && @static_prefix.matches?(/\A(?:\/[a-zA-Z0-9_-]+)+\/\z/), "invalid_limit")
      @handler.accepting = -> { @mutex.synchronize { @accepting } }
      @server = HTTP::Server.new(self)
    end

    def drain
      @mutex.synchronize { @accepting = false }
    end

    def resume
      @mutex.synchronize { @accepting = true }
    end

    def health : JSON::Any
      database = begin
        @store.available?
      rescue
        false
      end
      stats = @sessions.stats
      @mutex.synchronize do
        safe = database && !@accepting && @inflight == 0 && @workers == 0 && stats[:active] == 0 && stats[:pending] == 0 && stats[:quarantined] == 0
        Fuel.json({version: VERSION, database: database, accepting: @accepting, rooms: stats[:rooms],
                   active_sessions: stats[:active], pending_work: stats[:pending], quarantined_rooms: stats[:quarantined],
                   inflight: @inflight + @workers, safe_to_replace: safe})
      end
    end

    def call(context : HTTP::Server::Context)
      if context.request.method == "GET" && context.request.path == "/health"
        state = health
        context.response.status_code = 503 unless state["database"].as_bool
        context.response.content_type = "application/json"
        context.response.headers["Cache-Control"] = "no-store"
        context.response.print(state.to_json)
        return
      end
      @mutex.synchronize { @inflight += 1 }
      begin
        path = context.request.path
        if path.starts_with?("#{@handler.prefix}/")
          @handler.call(context)
        else
          static(context)
        end
      ensure
        @mutex.synchronize { @inflight -= 1 }
      end
    end

    # Each room exposes one head; slow database work holds no room/registry lock.
    def pump_effects : Int32
      started = 0
      rooms = @sessions.rooms
      return started if rooms.empty?
      first = @mutex.synchronize { @effect_cursor % rooms.size }
      rooms.size.times do |offset|
        index = (first + offset) % rooms.size
        room = rooms[index]
        reserved = @mutex.synchronize do
          if @workers < @worker_limit
            @workers += 1
            @effect_cursor = (index + 1) % rooms.size
            true
          else
            false
          end
        end
        break unless reserved
        if effect = room.begin_effect
          started += 1
          spawn settle(room, effect)
        else
          @mutex.synchronize { @workers -= 1 }
        end
      end
      started
    end

    private def settle(room : Room, effect : Effect)
      begin
        @store.apply_effect(effect, @rules, @analytics)
        room.finish_effect(effect, @store.effect_receipts(effect))
      rescue error : Error
        if error.code == "account_missing"
          room.finish_effect(effect, {effect.actor => Fuel.json({operation_id: effect.id, source: "effect", session_id: effect.session_id, epoch: effect.epoch, action: effect.action, reply: {status: "account_deleted"}})})
        else
          quarantine = error.code.in?("conflict", "invalid_action", "invalid_event", "invalid_result", "undeclared_account", "effect_acknowledgement", "missing_receipt")
          room.retry_effect(effect, quarantine ? error.code : nil, delay: 1.second)
          STDERR.puts(quarantine ? "Fuel room effect quarantined: #{error.code}" : "Fuel room effect postponed")
        end
      rescue
        room.retry_effect(effect, delay: 1.second)
        STDERR.puts "Fuel room effect postponed"
      ensure
        @mutex.synchronize { @workers -= 1 }
      end
    end

    def run(host = "0.0.0.0", port = 8080)
      server.bind_tcp(host, port)
      Signal::USR1.trap { drain }
      Signal::USR2.trap { resume }
      Signal::INT.trap { stop }
      Signal::TERM.trap { stop }
      @running = true
      ticker = Ticker.new(@sessions)
      spawn do
        previous = Time.instant
        while @running
          sleep 50.milliseconds
          now = Time.instant
          ticker.advance(now - previous)
          previous = now
        end
      end
      spawn do
        cleanup_at = Time.instant
        while @running
          pump_effects
          @sessions.cleanup
          if Time.instant >= cleanup_at
            cleanup_at = Time.instant + 1.hour
            begin
              @store.cleanup
            rescue
              STDERR.puts "Fuel storage cleanup postponed"
            end
          end
          sleep 250.milliseconds
        end
      end
      spawn do
        while @running
          if sink = @analytics
            stats = @sessions.stats
            deliver = @mutex.synchronize { @accepting || stats[:active] > 0 || stats[:pending] > 0 }
            if deliver
              @mutex.synchronize { @inflight += 1 }
              begin
                sink.drain
              rescue
                STDERR.puts "Fuel analytics delivery postponed"
              ensure
                @mutex.synchronize { @inflight -= 1 }
              end
            end
          end
          sleep 2.seconds
        end
      end
      server.listen
    ensure
      @running = false
    end

    def stop
      @running = false
      drain
      server.close unless server.closed?
    end

    private def static(context)
      request, response = context.request, context.response
      response.headers["X-Content-Type-Options"] = "nosniff"
      response.headers["Cache-Control"] = "no-store"
      if request.method == "GET" && request.path == @static_prefix.rchop('/')
        response.status_code = 308
        response.headers["Location"] = @static_prefix
        return
      end
      root = @static_root
      unless root && request.method == "GET" && request.path.starts_with?(@static_prefix)
        response.status_code = 404
        return
      end
      relative = URI.decode(request.path[@static_prefix.size..])
      if relative.includes?('\\') || relative.includes?('\0') || relative.split('/').any? { |part| part.starts_with?('.') }
        response.status_code = 400
        return
      end
      relative = "index.html" if relative.empty?
      file = File.join(root, relative)
      unless File.file?(file) && File.realpath(file).starts_with?(File.realpath(root).rstrip('/') + "/")
        response.status_code = 404
        return
      end
      response.content_type = MIME.from_filename(file, "application/octet-stream")
      File.open(file) { |input| IO.copy(input, response) }
    end
  end
end
