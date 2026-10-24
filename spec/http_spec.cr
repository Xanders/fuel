require "./spec_helper"
require "http/server"

if url = ENV["FUEL_TEST_DATABASE_URL"]?
  describe Fuel::Handler do
    it "keeps browser transfer candidates separate from the current guest cookie" do
      store = Fuel::Store.new(url, "browser_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      handler = Fuel::Handler.new(store, Fuel::Sessions.new(CounterRules.new), ["https://game.example"])
      server = HTTP::Server.new(handler)
      address = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      client = HTTP::Client.new(address.address, address.port)
      owner = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      owner_account = store.bootstrap(owner, "test")
      pair = store.issue_pair(owner)
      begin
        prepare = client.get("/fuel/v1/auth/prepare")
        prepare.headers["Set-Cookie"].should contain("HttpOnly")
        guest_cookie = prepare.headers["Set-Cookie"].split(';').first
        headers = HTTP::Headers{"Cookie" => guest_cookie, "Origin" => "https://game.example"}
        old_account = JSON.parse(client.post("/fuel/v1/auth/bootstrap", headers, "{}").body)["data"]["account_id"].as_s
        candidate = client.get("/fuel/v1/auth/pair/prepare", headers)
        candidate_cookie = candidate.headers["Set-Cookie"].split(';').first
        headers["Cookie"] = "#{guest_cookie}; #{candidate_cookie}"
        request = client.post("/fuel/v1/auth/pair/request", headers, {code: pair["code"]}.to_json)
        request.status_code.should eq(200)
        id = JSON.parse(request.body)["data"]["id"].as_s
        store.approve_pair(owner, id)
        activated = client.post("/fuel/v1/auth/pair/activate", headers, "{}")
        activated.status_code.should eq(200)
        JSON.parse(activated.body)["data"]["account_id"].as_s.should eq(owner_account)
        store.db.query_one("SELECT count(*) FROM fuel_accounts WHERE ns=$1 AND id=$2", store.namespace, old_account, as: Int64).should eq(1)
      ensure
        client.close
        server.close
      end
    end
    it "runs guest, lobby, command, polling and revoke through the actual HTTP handler" do
      store = Fuel::Store.new(url, "http_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      rooms = Fuel::Sessions.new(CounterRules.new)
      handler = Fuel::Handler.new(store, rooms, ["https://game.example"])
      server = HTTP::Server.new(handler)
      address = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      client = HTTP::Client.new(address.address, address.port)
      credential = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      headers = HTTP::Headers{"Authorization" => "Fuel #{credential.id}:#{credential.secret}", "Content-Type" => "application/json"}
      begin
        client.post("/fuel/v1/auth/bootstrap", headers, "{}").status_code.should eq(200)
        created = JSON.parse(client.post("/fuel/v1/sessions", headers, %({"mode":"solo","capacity":1})).body)["data"]
        id = created["session_id"].as_s
        epoch = created["epoch"].as_s
        result = client.post("/fuel/v1/sessions/#{id}/commands", headers, {id: "move", epoch: epoch, revision: "0", action: {amount: 2}}.to_json)
        result.status_code.should eq(200)
        JSON.parse(result.body)["data"]["state"]["value"].as_i.should eq(2)
        client.post("/fuel/v1/sessions", headers, "x" * 65537).status_code.should eq(413)
        client.close
        client = HTTP::Client.new(address.address, address.port)
        bad_origin = headers.dup
        bad_origin["Origin"] = "https://attacker.example"
        client.post("/fuel/v1/sessions", bad_origin, "{}").status_code.should eq(403)
        store.revoke(credential, credential.id)
        client.get("/fuel/v1/sessions/#{id}", headers).status_code.should eq(401)
      ensure
        client.close
        server.close
      end
    end
  end
end
