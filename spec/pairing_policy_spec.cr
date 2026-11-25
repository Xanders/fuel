require "./spec_helper"
require "./account_http_spec"

private def pairing_proof
  Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
end

if url = ENV["FUEL_TEST_DATABASE_URL"]?
  describe "ordinary transfer authorization" do
    it "links exactly one basic candidate, preserves progress and returns the same notice to A and B" do
      store = Fuel::Store.new(url, "base_pair_#{Fuel.id}", "d" * 32, "p" * 32, pair_mode: Fuel::PairMode::Basic)
      begin
        store.migrate
        a, b, candidate = pairing_proof, pairing_proof, pairing_proof
        owner, previous = store.bootstrap(a, "a"), store.bootstrap(b, "b")
        store.record_result(a, "round_one", "test", 4_i64, "Guest", Fuel.json({points: 4}))
        expect_raises(Fuel::Error, "transfer_update_required") { store.issue_pair(a) }
        issued = store.issue_pair(a, supports_basic: true)
        issued["mode"].as_s.should eq("basic")
        id, code = issued["id"].as_s, issued["code"].as_s
        expect_raises(Fuel::Error, "invalid_code") { store.request_pair(code, candidate, "b") }
        expect_raises(Fuel::Error, "invalid_code") { store.approve_pair(a, id) }
        linked = store.redeem_pair(code, candidate, "b")
        store.authenticate(candidate).should eq(owner)
        store.progress(candidate)["points"].as_i.should eq(4)
        store.authenticate(b).should eq(previous)
        store.issued_pair(a, id).should eq(linked)
        store.pair_status(candidate).should eq(linked)
        linked["emojis"].as_a.size.should eq(3)
        store.redeem_pair(code, candidate, "b").should eq(linked)
        expect_raises(Fuel::Error, "invalid_code") { store.redeem_pair(code, pairing_proof, "b") }
        expect_raises(Fuel::Error, "invalid_code") { store.redeem_pair(code, Fuel::Credential.new(candidate.id, Random::Secure.hex(32)), "b") }
        expect_raises(Fuel::Error, "not_found") { store.issued_pair(candidate, id) }
        store.bindings(a).size.should eq(2)
        store.revoke(candidate, a.id)
        store.redeem_pair(code, candidate, "b").should eq(linked)
        store.db.exec("DELETE FROM fuel_pairs WHERE ns=$1 AND id=$2", store.namespace, id)
        store.pair_status(candidate).should eq(Fuel.json({status: "linked", mode: "basic", account_id: owner}))
      ensure
        store.close
      end
    end

    it "rejects revoked issuers, elapsed codes and pre-migration pending rows" do
      ns = "pair_expiry_#{Fuel.id}"
      confirmed = Fuel::Store.new(url, ns, "d" * 32, "p" * 32)
      basic = Fuel::Store.new(url, ns, "d" * 32, "p" * 32, pair_mode: Fuel::PairMode::Basic)
      begin
        confirmed.migrate
        a, other, b = pairing_proof, pairing_proof, pairing_proof
        confirmed.bootstrap(a, "a")
        first = confirmed.issue_pair(a)["code"].as_s
        pending = confirmed.request_pair(first, other, "b")
        confirmed.approve_pair(a, pending["id"].as_s)
        legacy = confirmed.issue_pair(a, supports_basic: true)
        legacy["mode"].as_s.should eq("confirmed")
        id, code = legacy["id"].as_s, legacy["code"].as_s
        confirmed.request_pair(code, b, "b")
        expect_raises(Fuel::Error, "invalid_code") { basic.redeem_pair(code, b, "b") }
        confirmed.db.exec("UPDATE fuel_pairs SET issuer_binding=NULL WHERE ns=$1 AND id=$2", ns, id)
        expect_raises(Fuel::Error, "invalid_code") { basic.approve_pair(a, id) }
        expect_raises(Fuel::Error, "unauthorized") { basic.authenticate(b) }
        expired = basic.issue_pair(a, supports_basic: true)
        basic.db.exec("UPDATE fuel_pairs SET expires_at=clock_timestamp()-interval '1 second' WHERE ns=$1 AND id=$2", ns, expired["id"].as_s)
        expect_raises(Fuel::Error, "invalid_code") { basic.redeem_pair(expired["code"].as_s, b, "b") }
        revoked = basic.issue_pair(a, supports_basic: true)
        basic.revoke(other, a.id)
        expect_raises(Fuel::Error, "invalid_code") { basic.redeem_pair(revoked["code"].as_s, b, "b") }
        expect_raises(Fuel::Error, "unauthorized") { basic.authenticate(b) }
      ensure
        confirmed.close
        basic.close
      end
    end

    it "admits only one candidate when two devices redeem the same basic code concurrently" do
      store = Fuel::Store.new(url, "pair_race_#{Fuel.id}", "d" * 32, "p" * 32, pair_mode: Fuel::PairMode::Basic)
      begin
        store.migrate
        a = pairing_proof
        owner = store.bootstrap(a, "a")
        code = store.issue_pair(a, supports_basic: true)["code"].as_s
        results = Channel(Fuel::Credential | Exception).new(2)
        {pairing_proof, pairing_proof}.each do |candidate|
          spawn do
            store.redeem_pair(code, candidate, candidate.id)
            results.send(candidate)
          rescue error
            results.send(error)
          end
        end
        outcomes = Array.new(2) do
          select
          when result = results.receive
            result
          when timeout(3.seconds)
            fail "Concurrent redemption did not finish"
          end
        end
        winners = outcomes.compact_map { |result| result.as?(Fuel::Credential) }
        losers = outcomes.compact_map { |result| result.as?(Fuel::Error) }
        winners.size.should eq(1)
        losers.map(&.code).should eq(["invalid_code"])
        store.authenticate(winners.first).should eq(owner)
        store.bindings(a).size.should eq(2)
      ensure
        store.close
      end
    end

    it "selects the linked browser cookie on redemption without erasing B's previous guest on retry" do
      store = Fuel::Store.new(url, "pair_web_#{Fuel.id}", "d" * 32, "p" * 32, pair_mode: Fuel::PairMode::Basic)
      store.migrate
      a, b = pairing_proof, pairing_proof
      owner, previous = store.bootstrap(a, "a"), store.bootstrap(b, "b")
      issued = store.issue_pair(a, supports_basic: true)
      server = HTTP::Server.new(Fuel::Handler.new(store, Fuel::Sessions.new(AccountSessionRules.new), ["https://game.example"], account_rules: WalletRules.new))
      address = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      client = HTTP::Client.new(address.address, address.port)
      begin
        origin = HTTP::Headers{"Origin" => "https://game.example"}
        slot = "__Host-fuel-#{Digest::SHA256.hexdigest(store.namespace)}"
        client.get("/fuel/v1/auth/pair/prepare", origin).status_code.should eq(400)
        candidate = client.get("/fuel/v1/auth/pair/prepare?flow=basic-v1", origin).headers["Set-Cookie"].split(';').first
        current_binding = candidate.split('=', 2)[1].split(':', 2)[0]
        origin["Cookie"] = "#{slot}=#{b.id}:#{b.secret}; #{candidate}"
        body = {code: issued["code"].as_s, target_id: current_binding, from: b.id}.to_json
        client.post("/fuel/v1/auth/pair/activate", origin, {target_id: current_binding}.to_json).status_code.should eq(503)
        untrusted = origin.dup
        untrusted["Origin"] = "https://other.example"
        HTTP::Client.post("http://#{address}/fuel/v1/auth/pair/redeem", untrusted, body).status_code.should eq(403)
        wrong_target = {code: issued["code"].as_s, target_id: a.id, from: b.id}.to_json
        fenced = client.post("/fuel/v1/auth/pair/redeem", origin, wrong_target)
        fenced.status_code.should eq(400)
        JSON.parse(fenced.body)["error"].as_s.should eq("selection_changed")
        redeemed = client.post("/fuel/v1/auth/pair/redeem", origin, body)
        redeemed.status_code.should eq(200)
        cookies = redeemed.headers.get("Set-Cookie").map { |cookie| cookie.split(';').first }
        cookies.should contain("#{slot}-previous=#{b.id}:#{b.secret}")
        cookies.should contain("#{slot}=#{candidate.split('=', 2)[1]}")
        result = JSON.parse(redeemed.body)["data"]
        result["account_id"].as_s.should eq(owner)
        origin["Cookie"] = "#{cookies.join("; ")}; #{candidate}"
        duplicate = client.post("/fuel/v1/auth/pair/redeem", origin, body)
        duplicate.status_code.should eq(200)
        JSON.parse(duplicate.body)["data"].should eq(result)
        duplicate.headers.get("Set-Cookie").none? { |cookie| cookie.starts_with?("#{slot}-previous=") }.should be_true
        client.get("/fuel/v1/account", origin).status_code.should eq(200)
        switched = client.post("/fuel/v1/auth/switch", origin, {from: current_binding, to: b.id}.to_json)
        JSON.parse(switched.body)["data"]["account_id"].as_s.should eq(previous)
      ensure
        client.close
        server.close
        store.close
      end
    end

    it "invalidates a pending confirmation when the issuing binding is revoked" do
      store = Fuel::Store.new(url, "pair_policy_#{Fuel.id}", "d" * 32, "p" * 32)
      begin
        store.migrate
        a, other, b = pairing_proof, pairing_proof, pairing_proof
        owner = store.bootstrap(a, "test")
        first = store.issue_pair(a)
        store.request_pair(first["code"].as_s, other, "test")
        store.approve_pair(a, first["id"].as_s)
        store.authenticate(other).should eq(owner)
        second = store.issue_pair(a)
        store.request_pair(second["code"].as_s, b, "test")
        store.revoke(other, a.id)
        expect_raises(Fuel::Error, "invalid_code") { store.approve_pair(other, second["id"].as_s) }
        expect_raises(Fuel::Error, "unauthorized") { store.authenticate(b) }
      ensure
        store.close
      end
    end
  end
end
