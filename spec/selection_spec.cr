require "./account_spec"
require "http/server"

class SelectionRules < Fuel::Rules
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

class PausedSelectionAccounts < WalletRules
  getter entered = Channel(Nil).new
  getter release = Channel(Nil).new

  def refresh(account : String, state : JSON::Any, now : Int64) : JSON::Any
    @entered.send(nil)
    @release.receive
    state
  end
end

if url = ENV["FUEL_TEST_DATABASE_URL"]?
  describe "Browser selection recovery" do
    it "does not restore a stale cookie when an older account request finishes after selection" do
      store = Fuel::Store.new(url, "late_selection_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      a = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      b = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      store.bootstrap(a, "test")
      second = store.bootstrap(b, "test")
      prefix = "__Host-fuel-#{Digest::SHA256.hexdigest(store.namespace)}"
      headers = HTTP::Headers{"Origin" => "https://game.example", "Cookie" => "#{prefix}=#{a.id}:#{a.secret}; #{prefix}-previous=#{b.id}:#{b.secret}"}
      rules = PausedSelectionAccounts.new
      server = HTTP::Server.new(Fuel::Handler.new(store, Fuel::Sessions.new(SelectionRules.new), ["https://game.example"], account_rules: rules))
      address = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      client = HTTP::Client.new(address.address, address.port)
      other = HTTP::Client.new(address.address, address.port)
      late = Channel(HTTP::Client::Response).new
      begin
        spawn { late.send(other.get("/fuel/v1/account", headers)) }
        rules.entered.receive
        switched = client.post("/fuel/v1/auth/switch", headers, {from: a.id, to: b.id}.to_json)
        switched.status_code.should eq(200)
        JSON.parse(switched.body)["data"]["account_id"].as_s.should eq(second)
        switched.headers.get("Set-Cookie").any? { |value| value.starts_with?("#{prefix}=#{b.id}:") }.should be_true
        rules.release.send(nil)
        response = late.receive
        response.status_code.should eq(200)
        response.headers.has_key?("Set-Cookie").should be_false
      ensure
        client.close
        other.close
        server.close
        store.close
      end
    end

    it "retries an exact swap without toggling and can select the survivor after deletion" do
      store = Fuel::Store.new(url, "selection_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      a = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      b = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      first = store.bootstrap(a, "test")
      second = store.bootstrap(b, "test")
      prefix = "__Host-fuel-#{Digest::SHA256.hexdigest(store.namespace)}"
      headers = HTTP::Headers{"Origin" => "https://game.example", "Cookie" => "#{prefix}=#{a.id}:#{a.secret}; #{prefix}-previous=#{b.id}:#{b.secret}"}
      server = HTTP::Server.new(Fuel::Handler.new(store, Fuel::Sessions.new(SelectionRules.new), ["https://game.example"]))
      address = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      client = HTTP::Client.new(address.address, address.port)
      begin
        cross_site = client.get("/fuel/v1/auth/prepare", HTTP::Headers{"Sec-Fetch-Site" => "cross-site"})
        cross_site.status_code.should eq(403)
        cross_site.headers.has_key?("Set-Cookie").should be_false
        selection = client.get("/fuel/v1/auth/selection", headers)
        client.get("/fuel/v1/auth/prepare", headers).headers.has_key?("Set-Cookie").should be_false
        selection.status_code.should eq(200)
        JSON.parse(selection.body)["data"]["current"]["binding_id"].as_s.should eq(a.id)
        issued = store.issue_pair(a)
        owner_view = client.get("/fuel/v1/auth/pair/issued?id=#{issued["id"].as_s}", headers)
        owner_view.status_code.should eq(200)
        JSON.parse(owner_view.body)["data"]["status"].as_s.should eq("pending")
        JSON.parse(owner_view.body)["data"]["expires_at"].as_i64.should be > Time.utc.to_unix
        body = {from: a.id, to: b.id}.to_json
        swapped = client.post("/fuel/v1/auth/switch", headers, body)
        swapped.status_code.should eq(200)
        headers["Cookie"] = "#{prefix}=#{b.id}:#{b.secret}; #{prefix}-previous=#{a.id}:#{a.secret}"
        retried = client.post("/fuel/v1/auth/switch", headers, body)
        JSON.parse(retried.body)["data"]["account_id"].as_s.should eq(second)
        retried.headers.get?("Set-Cookie").try(&.any? { |v| v.starts_with?("#{prefix}-previous=") }).should_not be_true
        client.post("/fuel/v1/auth/switch", headers, {from: "stale", to: a.id}.to_json).status_code.should eq(409)
        progress = client.get("/fuel/v1/progress", headers)
        progress.headers["X-Fuel-Account"].should eq(second)
        stale = headers.dup
        stale["X-Fuel-Expected-Account"] = first
        client.get("/fuel/v1/progress", stale).status_code.should eq(400)
        client.post("/fuel/v1/auth/revoke", stale, {id: b.id, confirmed_last: true}.to_json).status_code.should eq(400)
        store.authenticate(b).should eq(second)
        store.delete_account(b, true)
        headers["Cookie"] = "#{prefix}-previous=#{a.id}:#{a.secret}"
        survivor = client.post("/fuel/v1/auth/switch", headers, {from: nil, to: a.id}.to_json)
        survivor.status_code.should eq(200)
        JSON.parse(survivor.body)["data"]["account_id"].as_s.should eq(first)
        headers["Cookie"] = "#{prefix}=#{a.id}:#{a.secret}; #{prefix}-previous=#{b.id}:#{b.secret}"
        retained = client.get("/fuel/v1/auth/selection", headers)
        retained.status_code.should eq(200)
        JSON.parse(retained.body)["data"]["previous"].raw.should be_nil
      ensure
        client.close
        server.close
      end
    end
  end
end
