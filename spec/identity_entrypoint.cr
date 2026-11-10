require "../src/fuel/identity"
require "http/server"

store : Fuel::Store? = nil
if url = ENV["FUEL_TEST_DATABASE_URL"]?
  authorize = ->(c : DB::Connection, account : String, proof : JSON::Any?) do
    Fuel.check(proof == Fuel.json({approved: true}), "factor_required")
  end
  store = Fuel::Store.new(url, "identity_#{Fuel.id}", "d" * 32, "p" * 32, login_authorizer: authorize)
  store.migrate
  account = store.enroll_account(Fuel.id)
  grant = store.issue_login(account, Fuel.id)
  candidate = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
  begin
    store.redeem_login(grant["code"].as_s, candidate, "identity-missing")
    raise "identity authorizer bypassed"
  rescue error : Fuel::Error
    raise error unless error.code == "factor_required"
  end
  bound = store.redeem_login(grant["code"].as_s, candidate, "identity-approved", step_up: Fuel.json({approved: true}))
  raise "identity step-up activation failed" unless bound == account && store.authenticate(candidate) == account
end

# Compile/run separately: loading the canonical Handler in this process would
# hide a Crystal 1.22.1 code-generation failure for uninstantiated game handlers.
server = HTTP::Server.new do |context|
  context.response.print(Fuel::VERSION)
end
address = server.bind_tcp("127.0.0.1", 0)
spawn { server.listen }
response = HTTP::Client.get("http://127.0.0.1:#{address.port}")
raise "embedded identity HTTP failed" unless response.status_code == 200 && response.body == Fuel::VERSION
server.close
store.try(&.close)
puts "identity entrypoint HTTP smoke passed"
