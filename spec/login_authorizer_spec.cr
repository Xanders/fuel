require "./spec_helper"

if url = ENV["FUEL_TEST_DATABASE_URL"]?
  describe "trusted login authorization before activation" do
    it "fails closed without proof, atomically consumes a factor, and permits exact active-proof recovery" do
      namespace = "stepup_#{Fuel.id}"
      policy = ->(c : DB::Connection, account : String, proof : JSON::Any?) do
        counter = proof.try { |value| value["counter"]?.try(&.as_i64) } || raise Fuel::Error.new("factor_required")
        Fuel.check(counter == 42, "invalid_factor")
        changed = c.exec("UPDATE stepup_fixture SET counter=$3 WHERE ns=$1 AND account=$2 AND counter<$3", namespace, account, counter)
        Fuel.check(changed.rows_affected == 1, "replayed_factor")
      end
      store = Fuel::Store.new(url, namespace, "d" * 32, "p" * 32, login_authorizer: policy)
      store.migrate
      store.db.exec("CREATE TABLE IF NOT EXISTS stepup_fixture(ns text,account text,counter bigint,PRIMARY KEY(ns,account))")
      account = store.enroll_account(Fuel.id)
      store.db.exec("INSERT INTO stepup_fixture VALUES($1,$2,0)", namespace, account)
      grant = store.issue_login(account, Fuel.id)
      code = grant["code"].as_s
      candidate = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      begin
        expect_raises(Fuel::Error, "factor_required") { store.redeem_login(code, candidate, "missing") }
        expect_raises(Fuel::Error, "invalid_factor") { store.redeem_login(code, candidate, "wrong", step_up: Fuel.json({counter: 41})) }
        expect_raises(Fuel::Error, "unauthorized") { store.authenticate(candidate) }
        store.db.query_one("SELECT candidate IS NULL FROM fuel_login_grants WHERE ns=$1 AND id=$2", namespace, grant["id"].as_s, as: Bool).should be_true
        store.db.query_one("SELECT counter FROM stepup_fixture WHERE ns=$1 AND account=$2", namespace, account, as: Int64).should eq(0)
        store.redeem_login(code, candidate, "correct", step_up: Fuel.json({counter: 42})).should eq(account)
        store.authenticate(candidate).should eq(account)
        # A lost successful response must not require a second consumption of the factor.
        store.redeem_login(code, candidate, "retry").should eq(account)
        store.db.query_one("SELECT counter FROM stepup_fixture WHERE ns=$1 AND account=$2", namespace, account, as: Int64).should eq(42)
        another = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
        expect_raises(Fuel::Error, "invalid_code") { store.redeem_login(code, another, "stranger", step_up: Fuel.json({counter: 42})) }
        next_grant = store.issue_login(account, Fuel.id)
        expect_raises(Fuel::Error, "replayed_factor") { store.redeem_login(next_grant["code"].as_s, another, "replay", step_up: Fuel.json({counter: 42})) }
        store.revoke(candidate, candidate.id, confirmed_last: true)
        expect_raises(Fuel::Error, "invalid_code") { store.redeem_login(code, candidate, "revoked") }
      ensure
        store.close
      end
    end

    it "rolls back factor writes if a candidate cannot be bound and bounds proof input before policy" do
      namespace = "stepup_#{Fuel.id}"
      calls = 0
      policy = ->(c : DB::Connection, account : String, proof : JSON::Any?) do
        calls += 1
        c.exec("INSERT INTO stepup_fixture VALUES($1,$2,1) ON CONFLICT(ns,account) DO UPDATE SET counter=stepup_fixture.counter+1", namespace, account)
        raise "policy unavailable" if proof.try { |value| value["fail"]?.try(&.as_bool) }
        nil
      end
      store = Fuel::Store.new(url, namespace, "d" * 32, "p" * 32, login_authorizer: policy)
      store.migrate
      store.db.exec("CREATE TABLE IF NOT EXISTS stepup_fixture(ns text,account text,counter bigint,PRIMARY KEY(ns,account))")
      owner = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      store.bootstrap(owner, "test")
      target = store.enroll_account(Fuel.id)
      grant = store.issue_login(target, Fuel.id)
      begin
        expect_raises(Fuel::Error, "invalid_code") { store.redeem_login(grant["code"].as_s, owner, "occupied") }
        store.db.query_one("SELECT count(*) FROM stepup_fixture WHERE ns=$1", namespace, as: Int64).should eq(0)
        calls.should eq(1)
        candidate = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
        expect_raises(Exception, "policy unavailable") { store.redeem_login(grant["code"].as_s, candidate, "failed", step_up: Fuel.json({fail: true})) }
        expect_raises(Fuel::Error, "unauthorized") { store.authenticate(candidate) }
        store.db.query_one("SELECT count(*) FROM stepup_fixture WHERE ns=$1", namespace, as: Int64).should eq(0)
        expect_raises(Fuel::Error, "invalid_proof") { store.redeem_login(grant["code"].as_s, candidate, "array", step_up: Fuel.json([1])) }
        expect_raises(Fuel::Error, "invalid_proof") { store.redeem_login(grant["code"].as_s, candidate, "large", step_up: Fuel.json({factor: "x" * 2048})) }
        calls.should eq(2)
      ensure
        store.close
      end
    end

    it "serializes concurrent candidates and commits factor state with exactly one ordinary binding" do
      namespace = "stepup_#{Fuel.id}"
      policy = ->(c : DB::Connection, account : String, proof : JSON::Any?) do
        c.exec("INSERT INTO stepup_fixture VALUES($1,$2,1)", namespace, account)
        nil
      end
      store = Fuel::Store.new(url, namespace, "d" * 32, "p" * 32, login_authorizer: policy)
      store.migrate
      store.db.exec("CREATE TABLE IF NOT EXISTS stepup_fixture(ns text,account text,counter bigint,PRIMARY KEY(ns,account))")
      account = store.enroll_account(Fuel.id)
      grant = store.issue_login(account, Fuel.id)
      results = Channel(String).new(2)
      begin
        2.times do |i|
          spawn do
            candidate = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
            results.send(store.redeem_login(grant["code"].as_s, candidate, "race_#{i}"))
          rescue error : Fuel::Error
            results.send(error.code)
          end
        end
        [results.receive, results.receive].sort.should eq([account, "invalid_code"].sort)
        store.db.query_one("SELECT count(*) FROM stepup_fixture WHERE ns=$1", namespace, as: Int64).should eq(1)
        store.db.query_one("SELECT count(*) FROM fuel_bindings WHERE ns=$1 AND account=$2", namespace, account, as: Int64).should eq(1)
      ensure
        store.close
      end
    end

    it "retains per-account factor attempt budgets across failures and reopened stores" do
      namespace = "stepup_#{Fuel.id}"
      policy = ->(c : DB::Connection, account : String, proof : JSON::Any?) { raise Fuel::Error.new("invalid_factor"); nil }
      store = Fuel::Store.new(url, namespace, "d" * 32, "p" * 32, login_authorizer: policy)
      store.migrate
      account = store.enroll_account(Fuel.id)
      grant = store.issue_login(account, Fuel.id)
      begin
        10.times do |i|
          candidate = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
          expect_raises(Fuel::Error, "invalid_factor") { store.redeem_login(grant["code"].as_s, candidate, "source_#{i}") }
        end
        reopened = Fuel::Store.new(url, namespace, "d" * 32, "p" * 32, login_authorizer: policy)
        begin
          expect_raises(Fuel::Error, "rate_limited") { reopened.redeem_login(grant["code"].as_s, Fuel::Credential.new(Fuel.id, Random::Secure.hex(32)), "new_source") }
        ensure
          reopened.close
        end
      ensure
        store.close
      end
    end

    it "rolls back factor consumption if the grant expires while the authorizer runs" do
      namespace = "stepup_#{Fuel.id}"
      calls = 0
      policy = ->(c : DB::Connection, account : String, proof : JSON::Any?) do
        calls += 1
        c.exec("INSERT INTO stepup_fixture VALUES($1,$2,1)", namespace, account)
        sleep 1200.milliseconds
        nil
      end
      store = Fuel::Store.new(url, namespace, "d" * 32, "p" * 32, login_authorizer: policy)
      store.migrate
      store.db.exec("CREATE TABLE IF NOT EXISTS stepup_fixture(ns text,account text,counter bigint,PRIMARY KEY(ns,account))")
      account = store.enroll_account(Fuel.id)
      grant = store.issue_login(account, Fuel.id)
      store.db.exec("UPDATE fuel_login_grants SET expires_at=clock_timestamp()+interval '1 second' WHERE ns=$1 AND id=$2", namespace, grant["id"].as_s)
      candidate = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      begin
        expect_raises(Fuel::Error, "invalid_code") { store.redeem_login(grant["code"].as_s, candidate, "expiry") }
        calls.should eq(1)
        expect_raises(Fuel::Error, "unauthorized") { store.authenticate(candidate) }
        store.db.query_one("SELECT count(*) FROM stepup_fixture WHERE ns=$1", namespace, as: Int64).should eq(0)
        store.db.query_one("SELECT candidate IS NULL FROM fuel_login_grants WHERE ns=$1 AND id=$2", namespace, grant["id"].as_s, as: Bool).should be_true
      ensure
        store.close
      end
    end
  end
end
