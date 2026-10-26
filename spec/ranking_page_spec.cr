require "./spec_helper"
require "http/server"

class RankingRules < Fuel::Rules
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
  describe "authenticated ranking pages" do
    it "returns the viewer standing beyond the page without exposing account IDs" do
      store = Fuel::Store.new(url, "ranking_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      viewer = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      leader = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      actor = store.bootstrap(viewer, "test")
      store.bootstrap(leader, "test")
      store.record_result(viewer, Fuel.id, "classic", 10_i64, "Quiet Fox", JSON.parse("{}"))
      store.record_result(leader, Fuel.id, "classic", 50_i64, "Bright Owl", JSON.parse("{}"))
      server = HTTP::Server.new(Fuel::Handler.new(store, Fuel::Sessions.new(RankingRules.new), [] of String))
      address = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      client = HTTP::Client.new(address.address, address.port)
      headers = HTTP::Headers{"Authorization" => "Fuel #{viewer.id}:#{viewer.secret}"}
      begin
        response = client.get("/fuel/v1/leaderboards/classic/page?limit=1", headers)
        response.status_code.should eq(200)
        page = JSON.parse(response.body)["data"]
        page["player_rank"].as_s.should eq("2")
        page["player_best"].as_s.should eq("10")
        page["entries"].as_a.size.should eq(1)
        page["entries"][0]["name"].as_s.should eq("Bright Owl")
        page["entries"][0]["is_player"].as_bool.should be_false
        response.body.should_not contain(actor)
        client.get("/fuel/v1/leaderboards/classic/page?limit=0", headers).status_code.should eq(400)
      ensure
        client.close
        server.close
        store.close
      end
    end

    it "invokes a trusted reader only after validating current authority and page bounds" do
      store = Fuel::Store.new(url, "reader_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      proof = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      actor = store.bootstrap(proof, "test")
      calls = [] of String
      reader = ->(connection : DB::Connection, namespace : String, viewer : String, board : String, limit : Int32) do
        connection.query_one("SELECT 1", as: Int32).should eq(1)
        namespace.should eq(store.namespace)
        viewer.should eq(actor)
        board.should eq("classic")
        limit.should eq(1)
        calls << viewer
        Fuel.json({entries: [{rank: "1", name: "Archived Owl", score: "90", is_player: false}], player_rank: nil, player_best: nil})
      end
      server = HTTP::Server.new(Fuel::Handler.new(store, Fuel::Sessions.new(RankingRules.new), ["https://game.example"], leaderboard_reader: reader))
      address = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      client = HTTP::Client.new(address.address, address.port)
      headers = HTTP::Headers{"Authorization" => "Fuel #{proof.id}:#{proof.secret}"}
      begin
        client.get("/fuel/v1/leaderboards/classic/page?limit=1", headers).status_code.should eq(200)
        calls.size.should eq(1)
        client.get("/fuel/v1/leaderboards/classic/page?limit=101", headers).status_code.should eq(400)
        client.get("/fuel/v1/leaderboards/bad%20board/page?limit=1", headers).status_code.should eq(400)
        headers["X-Fuel-Expected-Account"] = Fuel.id
        client.get("/fuel/v1/leaderboards/classic/page?limit=1", headers).status_code.should eq(400)
        headers.delete("X-Fuel-Expected-Account")
        headers["Origin"] = "https://other.example"
        client.get("/fuel/v1/leaderboards/classic/page?limit=1", headers).status_code.should eq(403)
        headers.delete("Origin")
        store.revoke(proof, proof.id, true)
        client.get("/fuel/v1/leaderboards/classic/page?limit=1", headers).status_code.should eq(401)
        calls.size.should eq(1)
      ensure
        client.close
        server.close
        store.close
      end
    end
  end
end
