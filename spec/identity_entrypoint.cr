require "../src/fuel/identity"
require "http/server"

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
puts "identity entrypoint HTTP smoke passed"
