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
    it "isolates untrusted event IDs by account and from server-owned outcome IDs" do
      store = Fuel::Store.new(url, "ui_ids_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      first = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      second = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      store.bootstrap(first, "fixture")
      actor = store.bootstrap(second, "fixture")
      trusted_id = Fuel.id + actor
      delivered = [] of JSON::Any
      sink = Fuel::Questmetry.new(store, {"screen_viewed" => ["screen"], "session_finished" => [] of String}, "test", "1.0.0", client_events: ["screen_viewed"]) do |body|
        delivered.concat(JSON.parse(body)["events"].as_a)
        202
      end
      begin
        props = Fuel.json({screen: "home"})
        sink.capture_client(first, trusted_id, "screen_viewed", "", props, 0_i64).should eq("queued")
        sink.capture(second, trusted_id, "session_finished", "", JSON.parse("{}")).should eq("queued")
        sink.capture_client(second, trusted_id, "screen_viewed", "", props, 0_i64).should eq("queued")
        sink.capture_client(first, trusted_id, "screen_viewed", "", props, 0_i64).should eq("duplicate")
        expect_raises(Fuel::Error, "invalid_key") { sink.capture_client(first, "bad id", "screen_viewed", "", props, 0_i64) }
        sink.drain
        delivered.size.should eq(3)
        delivered.map { |event| event["event_id"].as_s }.uniq.size.should eq(3)
        delivered.find { |event| event["source"] == "server" }.not_nil!["event_id"].as_s.should eq(trusted_id)
        delivered.select { |event| event["source"] == "client" }.each { |event| event["event_id"].as_s.should_not eq(trusted_id) }
      ensure
        store.close
      end
    end

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
