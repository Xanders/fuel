require "./spec_helper"

describe Fuel::NameDictionary do
  it "generates stable localized names from the consumer dictionary" do
    dict = Fuel::NameDictionary.from_json(%({"version":1,"fallback":"en","separator":" ","locales":{"en":[["Bright","Quiet"],["Fox","Owl"]],"ru":[["Тихий"],["Лис"]]}}))
    dict.generate("seed", "ru-RU").should eq("Тихий Лис")
    dict.generate("seed", "xx").should eq(dict.generate("seed", "en"))
    expect_raises(Fuel::Error, "invalid_dictionary") { Fuel::NameDictionary.from_json(%({"version":1,"fallback":"en","locales":{"en":[[]]}})) }
  end
end

describe Fuel::Chat do
  it "requires a live delivery adapter when retention is disabled" do
    expect_raises(Fuel::Error, "delivery_required") do
      Fuel::Chat.new(history_limit: 0) { |_, _, _| true }
    end
  end

  it "delivers censored messages to another player without retaining history" do
    received = [] of JSON::Any
    chat = Fuel::Chat.new(history_limit: 0, censor: Fuel::Censor.new(["rude"]), delivery: ->(kind : String, target : String, event : JSON::Any) {
      received << event if kind == "private" && target == "bob"
      nil
    }) { |_, _, _| true }
    sent = chat.post("alice", "private", "bob", "RUDE")
    received.first["id"].should eq(sent["id"])
    received.first["text"].as_s.should eq("****")
    chat.history("bob", "private", "alice").should be_empty
  end

  it "checks channel access on both send and history and bounds retention" do
    chat = Fuel::Chat.new(history_limit: 1, censor: Fuel::Censor.new(["rude"])) do |actor, kind, target|
      kind == "global" || (kind == "session" && actor == "alice" && target == "room") || (kind == "guild" && actor == "alice" && target == "guild")
    end
    chat.post("alice", "global", "", "Not RUDE!")
    chat.history("bob", "global", "").first["text"].as_s.should eq("Not ****!")
    chat.post("bob", "global", "", "second")
    chat.history("alice", "global", "").size.should eq(1)
    chat.post("alice", "private", "bob", "hello")
    chat.history("bob", "private", "alice").size.should eq(1)
    chat.history("eve", "private", "alice").should be_empty
    expect_raises(Fuel::Error, "forbidden") { chat.history("eve", "guild", "guild") }
    expect_raises(Fuel::Error, "forbidden") { chat.post("eve", "session", "room", "spy") }
    expect_raises(Fuel::Error, "invalid_message") { chat.post("alice", "global", "", " " * 5) }
  end
end
