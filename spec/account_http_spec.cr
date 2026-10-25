require "./account_spec"

class AccountSessionRules < Fuel::Rules
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
  describe "canonical account HTTP" do
    it "clears only deleted browser bindings, including recovery after a lost response" do
      store = Fuel::Store.new(url, "http_delete_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      server = HTTP::Server.new(Fuel::Handler.new(store, Fuel::Sessions.new(AccountSessionRules.new), ["https://game.example"], account_rules: WalletRules.new))
      address = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      client = HTTP::Client.new(address.address, address.port)
      begin
        prepared = client.get("/fuel/v1/auth/prepare")
        cookie = prepared.headers["Set-Cookie"].split(';').first
        headers = HTTP::Headers{"Cookie" => cookie, "Origin" => "https://game.example"}
        actor = JSON.parse(client.post("/fuel/v1/auth/bootstrap", headers, "{}").body)["data"]["account_id"].as_s
        other = client.get("/fuel/v1/auth/prepare").headers["Set-Cookie"].split(';').first
        other_headers = HTTP::Headers{"Cookie" => other, "Origin" => "https://game.example"}
        previous_account = JSON.parse(client.post("/fuel/v1/auth/bootstrap", other_headers, "{}").body)["data"]["account_id"].as_s
        name, value = other.split('=', 2)
        previous_name = "#{name}-previous"
        headers["Cookie"] = "#{cookie}; #{previous_name}=#{value}"
        proof = Random::Secure.hex(32)
        deleted = client.post("/fuel/v1/auth/delete", headers, {confirmed: true, account_id: actor, proof: proof}.to_json)
        deleted.status_code.should eq(200)
        deleted.headers.get("Set-Cookie").any? { |entry| entry.starts_with?("#{name}=") && entry.includes?("Max-Age=0") }.should be_true
        deleted.headers.get("Set-Cookie").none? { |entry| entry.starts_with?("#{previous_name}=") }.should be_true
        # Ignore that response's cookie updates, as if the acknowledgement was lost.
        recovered = client.post("/fuel/v1/auth/delete/status", headers, {account_id: actor, proof: proof}.to_json)
        recovered.headers.get("Set-Cookie").any? { |entry| entry.starts_with?("#{name}=") && entry.includes?("Max-Age=0") }.should be_true
        previous_only = HTTP::Headers{"Cookie" => "#{previous_name}=#{value}", "Origin" => "https://game.example"}
        fresh_cookie = client.get("/fuel/v1/auth/prepare", previous_only).headers["Set-Cookie"].split(';').first
        fresh_cookie.should_not eq(cookie)
        previous_only["Cookie"] = "#{fresh_cookie}; #{previous_name}=#{value}"
        client.post("/fuel/v1/auth/bootstrap", previous_only, "{}").status_code.should eq(200)
        fresh_id = fresh_cookie.split('=', 2)[1].split(':', 2)[0]
        selected = client.post("/fuel/v1/auth/switch", previous_only, {from: fresh_id, to: value.split(':', 2)[0]}.to_json)
        selected.status_code.should eq(200)
        JSON.parse(selected.body)["data"]["account_id"].as_s.should eq(previous_account)
      ensure
        client.close
        server.close
        store.close
      end
    end

    it "bounds requests to the new account surface without replacing the saved identity" do
      store = Fuel::Store.new(url, "http_rate_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      credential = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      account = store.bootstrap(credential, "test")
      server = HTTP::Server.new(Fuel::Handler.new(store, Fuel::Sessions.new(AccountSessionRules.new), [] of String, account_rules: WalletRules.new))
      address = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      client = HTTP::Client.new(address.address, address.port)
      headers = HTTP::Headers{"Authorization" => "Fuel #{credential.id}:#{credential.secret}"}
      begin
        statuses = Array.new(1201) { client.get("/fuel/v1/account", headers).status_code }
        statuses.count(200).should eq(1200)
        statuses.last.should eq(429)
        store.authenticate(credential).should eq(account)
      ensure
        client.close
        server.close
        store.close
      end
    end

    it "uses application prefixes, namespaced cookies and authorized receipt recovery" do
      store = Fuel::Store.new(url, "http_accounts_#{Fuel.id}", "d" * 32, "p" * 32)
      other = Fuel::Store.new(url, "http_other_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      rules = WalletRules.new
      handler = Fuel::Handler.new(store, Fuel::Sessions.new(AccountSessionRules.new), ["https://game.example"], account_rules: rules, prefix: "/sample/fuel/v1")
      second = Fuel::Handler.new(other, Fuel::Sessions.new(AccountSessionRules.new), ["https://game.example"], account_rules: rules)
      server = HTTP::Server.new(handler)
      server2 = HTTP::Server.new(second)
      address = server.bind_tcp("127.0.0.1", 0)
      address2 = server2.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      spawn { server2.listen }
      client = HTTP::Client.new(address.address, address.port)
      client2 = HTTP::Client.new(address2.address, address2.port)
      begin
        prepared = client.get("/sample/fuel/v1/auth/prepare")
        prepared.status_code.should eq(200)
        cookie = prepared.headers["Set-Cookie"].split(';').first
        cookie.should start_with("__Host-fuel-#{Digest::SHA256.hexdigest(store.namespace)}=")
        headers = HTTP::Headers{"Cookie" => cookie, "Origin" => "https://game.example"}
        client.post("/sample/fuel/v1/auth/bootstrap", headers, "{}").status_code.should eq(200)
        client.get("/fuel/v1/account", headers).status_code.should eq(404)
        account = JSON.parse(client.get("/sample/fuel/v1/account", headers).body)["data"]
        account["progress"]["coins"].as_i64.should eq(100)
        mine = client.get("/sample/fuel/v1/sessions/mine", headers)
        mine.status_code.should eq(200)
        JSON.parse(mine.body)["data"].as_a.should be_empty
        client2.get("/fuel/v1/account", headers).status_code.should eq(401)
        id = Fuel.id
        actor = account["account_id"].as_s
        receipt = store.apply_effect(Fuel::Effect.new(id, actor, "grant", JSON.parse("{}"), 100_i64), rules)
        recovered = JSON.parse(client.get("/sample/fuel/v1/operations/#{id}", headers).body)["data"]
        recovered.should eq(receipt)
        history = JSON.parse(client.get("/sample/fuel/v1/operations?after=0&limit=1", headers).body)["data"].as_a
        history.size.should eq(1)
        public_grant = client.post("/sample/fuel/v1/actions", headers, {id: Fuel.id, action: "grant", payload: {} of String => String}.to_json)
        public_grant.status_code.should eq(403)
        client.get("/sample/fuel/v1/operations?after=-1", headers).status_code.should eq(400)
        message = JSON.parse(client.post("/sample/fuel/v1/chat", headers, {kind: "global", target: "", text: "hello", name: "Forged"}.to_json).body)["data"]
        message["name"].as_s.should eq(actor)
        bob = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
        bob_account = store.bootstrap(bob, "bob")
        bob_headers = HTTP::Headers{"Authorization" => "Fuel #{bob.id}:#{bob.secret}"}
        client.post("/sample/fuel/v1/chat/mute", bob_headers, {target: actor, muted: true}.to_json).status_code.should eq(200)
        JSON.parse(client.get("/sample/fuel/v1/chat?kind=global&target=", bob_headers).body)["data"].as_a.should be_empty
        client.post("/sample/fuel/v1/chat/report", bob_headers, {kind: "global", target: "", message_id: message["id"], reason: "spam"}.to_json).status_code.should eq(200)
        proof = Random::Secure.hex(32)
        deleted = client.post("/sample/fuel/v1/auth/delete", bob_headers, {confirmed: true, proof: proof, account_id: bob_account}.to_json)
        deleted.status_code.should eq(200)
        client.get("/sample/fuel/v1/account", bob_headers).status_code.should eq(401)
        status = client.post("/sample/fuel/v1/auth/delete/status", HTTP::Headers.new, {proof: proof, account_id: bob_account}.to_json)
        JSON.parse(status.body)["data"]["status"].as_s.should eq("deleted")
      ensure
        client.close
        client2.close
        server.close
        server2.close
        store.close
        other.close
      end
    end
  end
end
