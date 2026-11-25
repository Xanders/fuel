require "./effects_spec"

if url = ENV["FUEL_TEST_DATABASE_URL"]?
  it "reports a monotonic process uptime shared by distinct runtimes over HTTP" do
    store = Fuel::Store.new(url, "uptime_#{Fuel.id}", "d" * 32, "p" * 32)
    servers = [] of HTTP::Server
    begin
      store.migrate
      read_uptime = -> do
        sessions = Fuel::Sessions.new(EffectRules.new)
        handler = Fuel::Handler.new(store, sessions, [] of String)
        runtime = Fuel::Runtime.new(store, sessions, handler, WalletRules.new)
        server = runtime.server
        servers << server
        address = server.bind_tcp("127.0.0.1", 0)
        spawn { server.listen }
        result = HTTP::Client.get("http://#{address}/health")
        result.status_code.should eq(200)
        JSON.parse(result.body)["process_uptime_seconds"].as_f
      end
      first = read_uptime.call
      first.should be >= 0.0
      before = Time.instant
      sleep 25.milliseconds
      elapsed = (Time.instant - before).total_seconds
      read_uptime.call.should be >= first + elapsed
    ensure
      servers.each(&.close)
      store.close
    end
  end
end
