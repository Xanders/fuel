require "../src/fuel"

# A neutral server-authoritative sample, independent of any existing game.
class Counter < Fuel::Rules
  def initial : JSON::Any
    JSON.parse(%({"value":0}))
  end

  def apply(state : JSON::Any, actor : String, action : JSON::Any) : JSON::Any
    amount = action["amount"].as_i
    Fuel.check((1..3).includes?(amount) && state["value"].as_i < 7, "illegal_action")
    Fuel.json({value: state["value"].as_i + amount})
  end

  def project(state : JSON::Any, actor : String) : JSON::Any
    state
  end

  def result(state : JSON::Any, actor : String) : Fuel::GameResult?
    if state["value"].as_i >= 7
      Fuel::GameResult.new("counter", state["value"].as_i64, "Player", Fuel.json({completed: true}))
    end
  end
end

store = Fuel::Store.new(ENV.fetch("DATABASE_URL"), "counter", ENV.fetch("FUEL_DEVICE_KEY"), ENV.fetch("FUEL_PAIR_KEY"))
store.migrate
sessions = Fuel::Sessions.new(Counter.new)
origins = ENV.fetch("FUEL_ORIGINS", "https://game.example").split(',')
server = HTTP::Server.new(Fuel::Handler.new(store, sessions, origins))
server.bind_tcp("0.0.0.0", ENV.fetch("PORT", "8080").to_i)
spawn do
  loop do
    sleep 30.seconds
    sessions.cleanup
    store.cleanup
  end
end
Signal::TERM.trap { server.close }
Signal::INT.trap { server.close }
puts "Fuel #{Fuel::VERSION} counter sample listening"
begin
  server.listen
ensure
  store.close
end
