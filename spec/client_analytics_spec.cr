require "./spec_helper"

class ClientAnalyticsRules < Fuel::Rules
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

if url = ENV["FUEL_TEST_DATABASE_URL"]?
  describe "client product analytics" do
    it "uses an explicit client allowlist, current consent and server-owned context" do
      store = Fuel::Store.new(url, "ui_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      proof = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      actor = store.bootstrap(proof, "fixture")
      bodies = [] of JSON::Any
      sink = Fuel::Questmetry.new(store, {"screen_viewed" => ["screen"], "result_saved" => ["score"]}, "test", "1.0.0",
        client_events: ["screen_viewed"], context: Fuel.json({app: "example"}),
        validate: ->(name : String, props : JSON::Any) { name != "screen_viewed" || props["screen"]?.try(&.as_s?) == "home" }) do |body|
        bodies << JSON.parse(body)
        202
      end
      server = HTTP::Server.new(Fuel::Handler.new(store, Fuel::Sessions.new(ClientAnalyticsRules.new), ["https://game.example"], sink))
      address = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      client = HTTP::Client.new(address.address, address.port)
      headers = HTTP::Headers{"Authorization" => "Fuel #{proof.id}:#{proof.secret}", "Content-Type" => "application/json"}
      id = Fuel.id
      event = Fuel.json({id: id, name: "screen_viewed", session: "run", properties: {screen: "home"}, revision: "0"})
      begin
        2.times do
          response = client.post("/fuel/v1/analytics/events", headers, event.to_json)
          response.status_code.should eq(200)
        end
        sink.drain
        bodies.size.should eq(1)
        sent = bodies.first["events"].as_a
        sent.size.should eq(1)
        sent.first["source"].as_s.should eq("client")
        sent.first["context"]["app"].as_s.should eq("example")
        sent.first["anonymous_id"].as_s.should_not eq(actor)
        sent.first["session_id"].as_s.should_not eq("run")
        # No result/progress operation is created for a cosmetic UI event.
        store.operations(proof).should be_empty
        forbidden = Fuel.json({id: Fuel.id, name: "result_saved", session: "", properties: {score: 999}, revision: "0"})
        client.post("/fuel/v1/analytics/events", headers, forbidden.to_json).status_code.should eq(400)
        invalid = Fuel.json({id: Fuel.id, name: "screen_viewed", session: "", properties: {screen: "private text"}, revision: "0"})
        client.post("/fuel/v1/analytics/events", headers, invalid.to_json).status_code.should eq(400)
        sink.enabled(proof, false)
        stale = client.post("/fuel/v1/analytics/events", headers, event.to_json)
        JSON.parse(stale.body)["data"]["status"].as_s.should eq("stale")
        sink.enabled(proof, true)
        # A delayed pre-opt-out event stays stale after opt-in as well.
        JSON.parse(client.post("/fuel/v1/analytics/events", headers, event.to_json).body)["data"]["status"].as_s.should eq("stale")
        sink.drain
        bodies.size.should eq(1)
        headers["X-Fuel-Expected-Account"] = Fuel.id
        client.post("/fuel/v1/analytics/events", headers, event.to_json).status_code.should eq(400)
        headers.delete("X-Fuel-Expected-Account")
        headers["Origin"] = "https://other.example"
        client.post("/fuel/v1/analytics/events", headers, event.to_json).status_code.should eq(403)
      ensure
        client.close
        server.close
        store.close
      end
    end
  end
end
