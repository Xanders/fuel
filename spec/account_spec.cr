require "./spec_helper"

describe Fuel::AccountTransaction do
  it "does not expose mutable descriptor buffers that bypass declared participants" do
    tx = Fuel::AccountTransaction.new({"alice" => Fuel.json({coins: 10})})
    tx.notifications["intruder"] = Fuel.json({status: "forged"})
    tx.events << {"intruder", "forged", "", JSON.parse("{}"), 1_i64}
    tx.scores << {"intruder", "board", 1_i64, "forged", nil}
    tx.notifications.should be_empty
    tx.events.should be_empty
    tx.scores.should be_empty
  end
end

class WalletRules < Fuel::AccountRules
  def initial(account : String, now : Int64) : JSON::Any
    Fuel.json({coins: 100_i64, refreshed: now})
  end

  def refresh(account : String, state : JSON::Any, now : Int64) : JSON::Any
    state.as_h["refreshed"] = JSON::Any.new(now)
    state
  end

  def public_action?(name : String) : Bool
    ["transfer", "fail"].includes?(name)
  end

  def terminal?(action : String, reply : JSON::Any) : Bool
    action == "grant"
  end

  def participants(actor : String, name : String, payload : JSON::Any) : Array(String)
    name == "transfer" ? [payload["recipient"].as_s] : [] of String
  end

  def apply(tx : Fuel::AccountTransaction, actor : String, action : String, payload : JSON::Any, now : Int64) : JSON::Any
    state = tx.get(actor)
    case action
    when "transfer"
      recipient = payload["recipient"].as_s
      other = tx.get?(recipient) || raise Fuel::Error.new("invalid_recipient")
      amount = payload["amount"].as_i64
      Fuel.check(amount > 0 && amount <= state["coins"].as_i64 && actor != recipient, "invalid_amount")
      state.as_h["coins"] = JSON::Any.new(state["coins"].as_i64 - amount)
      other.as_h["coins"] = JSON::Any.new(other["coins"].as_i64 + amount)
      tx.save(recipient, other)
      tx.notify(recipient, Fuel.json({status: "received", amount: amount}))
    when "grant", "fail"
      state.as_h["coins"] = JSON::Any.new(state["coins"].as_i64 + 30_i64)
    else
      raise Fuel::Error.new("invalid_action")
    end
    tx.save(actor, state)
    raise "injected" if action == "fail"
    Fuel.json({status: "committed", coins: state["coins"]})
  end
end

class LargeReceiptRules < WalletRules
  def apply(tx : Fuel::AccountTransaction, actor : String, action : String, payload : JSON::Any, now : Int64) : JSON::Any
    reply = super
    reply.as_h["detail"] = JSON::Any.new("x" * 50000)
    reply
  end
end

if url = ENV["FUEL_TEST_DATABASE_URL"]?
  describe "canonical account actions" do
    store = Fuel::Store.new(url, "accounts_#{Fuel.id}", "d" * 32, "p" * 32)
    store.migrate
    rules = WalletRules.new
    a = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
    b = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
    actor = store.bootstrap(a, "a")
    recipient = store.bootstrap(b, "b")

    it "initializes and refreshes permanent progress through pure rules" do
      state = store.account(a, rules)
      state["account_id"].as_s.should eq(actor)
      state["progress"]["coins"].as_i64.should eq(100)
      state["analytics_enabled"].as_bool.should be_true
    end

    it "bounds history bytes without skipping the next operation cursor" do
      proof = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      owner = store.bootstrap(proof, Fuel.id)
      10.times { store.apply_effect(Fuel::Effect.new(Fuel.id, owner, "grant", JSON.parse("{}"), Time.utc.to_unix), LargeReceiptRules.new) }
      page = store.operations(proof, after: "0")
      page.size.should eq(9)
      page.to_json.bytesize.should be < 491600
      rest = store.operations(proof, after: page.last["cursor"].as_s)
      rest.size.should eq(1)
      (page + rest).map(&.["operation_id"].as_s).uniq.size.should eq(10)
    end

    it "recovers the latest terminal result even after later ordinary actions" do
      proof = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      other = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      owner = store.bootstrap(proof, Fuel.id)
      target = store.bootstrap(other, Fuel.id)
      effect = Fuel::Effect.new(Fuel.id, owner, "grant", JSON.parse("{}"), Time.utc.to_unix)
      terminal = store.apply_effect(effect, rules)
      terminal["terminal"].as_bool.should be_true
      store.execute(proof, Fuel.id, "transfer", Fuel.json({recipient: target, amount: 1_i64}), rules)
      store.operations(proof, limit: 1, terminal_only: true).should eq([terminal])
    end

    it "commits both participants and recovers the original receipt without reapplying" do
      id = Fuel.id
      payload = Fuel.json({recipient: recipient, amount: 10_i64})
      reply = store.execute(a, id, "transfer", payload, rules)
      store.execute(a, id, "transfer", JSON.parse(%({"amount":10,"recipient":"#{recipient}"})), rules).should eq(reply)
      store.account(a, rules)["progress"]["coins"].as_i64.should eq(90)
      store.account(b, rules)["progress"]["coins"].as_i64.should eq(110)
      store.operation(a, id).should eq(reply)
      received = store.operation(b, id)
      received["reply"]["status"].as_s.should eq("received")
      expect_raises(Fuel::Error, "conflict") { store.execute(a, id, "transfer", Fuel.json({recipient: recipient, amount: 11}), rules) }
      outsider = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      store.bootstrap(outsider, "c")
      expect_raises(Fuel::Error, "not_found") { store.operation(outsider, id) }
    end

    it "rolls back progress and receipts together, and does not create missing recipients" do
      id = Fuel.id
      expect_raises(Exception, "injected") { store.execute(a, id, "fail", JSON.parse("{}"), rules) }
      store.account(a, rules)["progress"]["coins"].as_i64.should eq(90)
      expect_raises(Fuel::Error, "not_found") { store.operation(a, id) }
      expect_raises(Fuel::Error, "invalid_recipient") { store.execute(a, Fuel.id, "transfer", Fuel.json({recipient: Fuel.id, amount: 1}), rules) }
      store.account(a, rules)["progress"]["coins"].as_i64.should eq(90)
    end

    it "keeps trusted grants out of the public action path and recovers effects after room loss" do
      id = Fuel.id
      expect_raises(Fuel::Error, "forbidden") { store.execute(a, id, "grant", JSON.parse("{}"), rules) }
      effect = Fuel::Effect.new(id, actor, "grant", JSON.parse("{}"), 123_i64, "room", "epoch")
      reply = store.apply_effect(effect, rules)
      store.apply_effect(effect, rules).should eq(reply)
      reply["occurred_at"].as_i64.should eq(123)
      fresh = Fuel::Store.new(url, store.namespace, "d" * 32, "p" * 32)
      fresh.operation(a, id).should eq(reply)
      history = fresh.operations(a, after: "0", limit: 100)
      history.last["operation_id"].as_s.should eq(id)
      fresh.operations(a, after: history.last["cursor"].as_s).should be_empty
      fresh.account(a, rules)["progress"]["coins"].as_i64.should eq(120)
      fresh.close
    end

    it "serializes opposite transfers without lock-order deadlock or lost coins" do
      done = Channel(Exception?).new(2)
      [{a, recipient}, {b, actor}].each do |credential, target|
        spawn do
          begin
            10.times { store.execute(credential, Fuel.id, "transfer", Fuel.json({recipient: target, amount: 1}), rules) }
            done.send(nil)
          rescue error
            done.send(error)
          end
        end
      end
      2.times { done.receive.should be_nil }
      store.account(a, rules)["progress"]["coins"].as_i64.should eq(120)
      store.account(b, rules)["progress"]["coins"].as_i64.should eq(110)
    end

    it "does not permit reading receipts through a revoked binding" do
      id = Fuel.id
      store.apply_effect(Fuel::Effect.new(id, actor, "grant", JSON.parse("{}"), 123_i64), rules)
      store.revoke(a, a.id, confirmed_last: true)
      expect_raises(Fuel::Error, "unauthorized") { store.operation(a, id) }
    end

    it "does not replace trusted result progress when initializing the account facade" do
      credential = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      store.bootstrap(credential, "result-account")
      store.record_result(credential, Fuel.id, "counter", 7_i64, "Fox", Fuel.json({coins: 7_i64}))
      store.account(credential, rules)["progress"]["coins"].as_i64.should eq(7)
    end

    it "rolls back an already written progress row when durable receipt insertion fails" do
      credential = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      actor = store.bootstrap(credential, "receipt-failure")
      store.account(credential, rules)
      effect = Fuel::Effect.new(Fuel.id, actor, "grant", JSON.parse("{}"), Time.utc.to_unix)
      constraint = "fixture_#{Fuel.id}"
      store.db.exec("ALTER TABLE fuel_operations ADD CONSTRAINT #{constraint} CHECK(account<>'#{actor}') NOT VALID")
      begin
        expect_raises(PQ::PQError, "violates check constraint") { store.apply_effect(effect, rules) }
        store.account(credential, rules)["progress"]["coins"].as_i64.should eq(100)
        expect_raises(Fuel::Error, "not_found") { store.operation(credential, effect.id) }
      ensure
        store.db.exec("ALTER TABLE fuel_operations DROP CONSTRAINT #{constraint}")
      end
      store.apply_effect(effect, rules)["reply"]["coins"].as_i64.should eq(130)
    end
  end
end
