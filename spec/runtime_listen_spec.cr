require "./spec_helper"

class ListenRules < Fuel::Rules
  def initial : JSON::Any
    JSON.parse("{}")
  end

  def apply(state : JSON::Any, actor : String, action : JSON::Any) : JSON::Any
    state
  end

  def project(state : JSON::Any, actor : String) : JSON::Any
    state
  end
end

class ListenAccounts < Fuel::AccountRules
  def apply(tx : Fuel::AccountTransaction, actor : String, action : String, payload : JSON::Any, now : Int64) : JSON::Any
    raise Fuel::Error.new("invalid_action")
  end
end

class JoiningStore < Fuel::Store
  getter entered = Channel(Nil).new(1)
  getter release = Channel(Nil).new(1)
  getter finished = Channel(Nil).new(1)

  def cleanup
    entered.send(nil)
    release.receive
    finished.send(nil)
  end
end

class StoppedProbeStore < Fuel::Store
  getter availability_checks = 0

  def available? : Bool
    @availability_checks += 1
    true
  end
end

if url = ENV["FUEL_TEST_DATABASE_URL"]?
  describe "composable runtime listener" do
    it "never admits a late accepted HTTP request to storage after stop" do
      store = StoppedProbeStore.new(url, "late_#{Fuel.id}", "d" * 32, "p" * 32)
      sessions = Fuel::Sessions.new(ListenRules.new)
      runtime = Fuel::Runtime.new(store, sessions, Fuel::Handler.new(store, sessions, [] of String), ListenAccounts.new)
      runtime.stop
      response = HTTP::Server::Response.new(IO::Memory.new)
      runtime.call(HTTP::Server::Context.new(HTTP::Request.new("GET", "/health"), response))
      response.status_code.should eq(503)
      store.availability_checks.should eq(0)
      store.close
    end

    it "waits for an admitted background database owner before returning from stop" do
      store = JoiningStore.new(url, "listen_#{Fuel.id}", "d" * 32, "p" * 32)
      sessions = Fuel::Sessions.new(ListenRules.new)
      runtime = Fuel::Runtime.new(store, sessions, Fuel::Handler.new(store, sessions, [] of String), ListenAccounts.new)
      runtime.server.bind_tcp("127.0.0.1", 0)
      completed = Channel(String).new(1)
      released = false
      spawn do
        runtime.listen
        completed.send("joined")
      rescue error
        completed.send(error.message.to_s)
      end
      begin
        store.entered.receive
        expect_raises(Fuel::Error, "runtime_started") { runtime.listen }
        runtime.drain
        runtime.health["inflight"].as_i.should eq(1)
        runtime.health["safe_to_replace"].as_bool.should be_false
        runtime.stop
        select
        when premature = completed.receive
          fail "runtime returned while cleanup still owns the database: #{premature}"
        when timeout(20.milliseconds)
        end
        store.release.send(nil)
        released = true
        select
        when result = completed.receive
          result.should eq("joined")
        when timeout(3.seconds)
          fail "runtime failed to join released work"
        end
        expect_raises(Fuel::Error, "runtime_closed") { runtime.listen }
      ensure
        runtime.stop
        store.release.send(nil) unless released
        store.close
      end
    end

    it "rejects listener startup after an explicit stop" do
      store = Fuel::Store.new(url, "closed_#{Fuel.id}", "d" * 32, "p" * 32)
      sessions = Fuel::Sessions.new(ListenRules.new)
      runtime = Fuel::Runtime.new(store, sessions, Fuel::Handler.new(store, sessions, [] of String), ListenAccounts.new)
      runtime.server.bind_tcp("127.0.0.1", 0)
      runtime.stop
      expect_raises(Fuel::Error, "runtime_closed") { runtime.listen }
      expect_raises(Fuel::Error, "runtime_closed") { runtime.run("127.0.0.1", 0) }
      store.close
    end

    it "reports a bounded shutdown timeout instead of claiming database owners have joined" do
      store = JoiningStore.new(url, "timeout_#{Fuel.id}", "d" * 32, "p" * 32)
      sessions = Fuel::Sessions.new(ListenRules.new)
      runtime = Fuel::Runtime.new(store, sessions, Fuel::Handler.new(store, sessions, [] of String), ListenAccounts.new)
      runtime.server.bind_tcp("127.0.0.1", 0)
      completed = Channel(String).new(1)
      spawn do
        runtime.listen(shutdown_timeout: 20.milliseconds)
        completed.send("joined")
      rescue error : Fuel::Error
        completed.send(error.code)
      end
      begin
        store.entered.receive
        runtime.stop
        select
        when result = completed.receive
          result.should eq("shutdown_timeout")
        when timeout(2.seconds)
          fail "shutdown deadline did not finish the listener"
        end
        runtime.health["safe_to_replace"].as_bool.should be_false
      ensure
        runtime.stop
        store.release.send(nil)
        store.finished.receive
        Fiber.yield
        store.close
      end
    end

    it "composes two prebound app listeners without replacing process signal handlers" do
      stores = ["first", "second"].map { |app| Fuel::Store.new(url, "#{app}_#{Fuel.id}", "d" * 32, "p" * 32) }
      runtimes = stores.map do |store|
        sessions = Fuel::Sessions.new(ListenRules.new)
        Fuel::Runtime.new(store, sessions, Fuel::Handler.new(store, sessions, [] of String), ListenAccounts.new)
      end
      addresses = runtimes.map { |runtime| runtime.server.bind_tcp("127.0.0.1", 0) }
      completed = Channel(String).new(2)
      previous = Signal::USR1.trap_handler?
      Signal::USR1.trap { runtimes.each(&.drain) }
      owned_handler = Signal::USR1.trap_handler?
      runtimes.each do |runtime|
        spawn do
          runtime.listen
          completed.send("joined")
        rescue error
          completed.send(error.message.to_s)
        end
      end
      begin
        addresses.each do |address|
          HTTP::Client.get("http://#{address}/health").status_code.should eq(200)
        end
        Signal::USR1.trap_handler?.should eq(owned_handler)
        runtimes.each(&.drain)
        runtimes.each { |runtime| runtime.health["accepting"].as_bool.should be_false }
        runtimes.each(&.stop)
        2.times do
          select
          when result = completed.receive
            result.should eq("joined")
          when timeout(3.seconds)
            fail "one application did not join"
          end
        end
      ensure
        runtimes.each(&.stop)
        if previous
          Signal::USR1.trap(&previous)
        else
          Signal::USR1.reset
        end
        stores.each(&.close)
      end
    end
  end
end
