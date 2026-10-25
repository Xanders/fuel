require "./spec_helper"

if url = ENV["FUEL_TEST_DATABASE_URL"]?
  describe "optional analytics and persistent chat" do
    store = Fuel::Store.new(url, "social_#{Fuel.id}", "d" * 32, "p" * 32)
    store.migrate
    a = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
    account = store.bootstrap(a, "test")

    it "keeps event IDs on retry and purges queued events on opt-out" do
      bodies = [] of String
      status = 503
      analytics = Fuel::Questmetry.new(store, {"match_finished" => ["mode"]}, "test", "0.1.0") do |body|
        bodies << body
        status
      end
      id = Fuel.id
      analytics.capture(a, id, "match_finished", "match", JSON.parse(%({"mode":"duel"})))
      analytics.drain
      bodies.size.should eq(1)
      bodies.first.should_not contain(account)
      status = 202
      analytics.drain(Time.utc + 1.hour)
      JSON.parse(bodies.last)["events"][0]["event_id"].as_s.should eq(id)
      expect_raises(Fuel::Error, "invalid_event") { analytics.capture(a, Fuel.id, "match_finished", "m", JSON.parse(%({"text":"secret chat"}))) }
      analytics.capture(a, Fuel.id, "match_finished", "m", JSON.parse(%({"mode":"duel"})))
      analytics.enabled(a, false)
      analytics.drain(Time.utc + 2.hours)
      bodies.size.should eq(2)
    end

    it "stores only configured private or guild history and reads it after restart" do
      chat = Fuel::Chat.new(store: store, persist: ["private"], history_limit: 2) { |_, kind, _| kind == "global" }
      chat.post(account, "private", "bob", "hello")
      restarted = Fuel::Chat.new(store: store, persist: ["private"], history_limit: 2) { |_, _, _| false }
      restarted.history("bob", "private", account).first["text"].as_s.should eq("hello")
      expect_raises(Fuel::Error, "invalid_channel") { Fuel::Chat.new(store: store, persist: ["unknown"]) { |_, _, _| true } }
    end
  end
end

describe Fuel::Censor do
  it "supports consumer glyph variants and punctuation evasion without regex injection" do
    censor = Fuel::Censor.new(["bad"], {"a" => "а4"})
    censor.filter("b.4.d!").should eq("*****!")
    censor.filter("badge").should eq("badge")
  end
end
