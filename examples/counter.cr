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

class CounterAccounts < Fuel::AccountRules
  def apply(tx : Fuel::AccountTransaction, actor : String, action : String, payload : JSON::Any, now : Int64) : JSON::Any
    raise Fuel::Error.new("invalid_action")
  end
end

store = Fuel::Store.new(ENV.fetch("DATABASE_URL"), "counter", ENV.fetch("FUEL_DEVICE_KEY"), ENV.fetch("FUEL_PAIR_KEY"))
store.migrate
sessions = Fuel::Sessions.new(Counter.new)
origins = ENV.fetch("FUEL_ORIGINS", "https://game.example").split(',')
accounts = CounterAccounts.new
handler = Fuel::Handler.new(store, sessions, origins, account_rules: accounts)
runtime = Fuel::Runtime.new(store, sessions, handler, accounts)
puts "Fuel #{Fuel::VERSION} counter sample listening"
begin
  runtime.run("0.0.0.0", ENV.fetch("PORT", "8080").to_i)
ensure
  store.close
end
