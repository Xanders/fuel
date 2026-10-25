require "./account_spec"

if url = ENV["FUEL_TEST_DATABASE_URL"]?
  describe "private delivery authority" do
    it "holds binding authorization through delivery and rejects the next send after revocation" do
      store = Fuel::Store.new(url, "authority_#{Fuel.id}", "d" * 32, "p" * 32)
      store.migrate
      proof = Fuel::Credential.new(Fuel.id, Random::Secure.hex(32))
      store.bootstrap(proof, "test")
      entered = Channel(Nil).new(1)
      release = Channel(Nil).new(1)
      delivered = Channel(Nil).new(1)
      revoked = Channel(Nil).new(1)
      spawn do
        store.with_accounts(proof, [] of String, WalletRules.new) do
          entered.send(nil)
          release.receive
          delivered.send(nil)
        end
      end
      entered.receive
      spawn do
        store.db.exec("UPDATE fuel_bindings SET revoked=true WHERE ns=$1 AND id=$2", store.namespace, proof.id)
        revoked.send(nil)
      end
      select
      when revoked.receive
        fail "revocation overtook authorized private delivery"
      when timeout(20.milliseconds)
      end
      release.send(nil)
      delivered.receive
      revoked.receive
      unauthorized_delivery = false
      expect_raises(Fuel::Error, "unauthorized") { store.with_accounts(proof, [] of String, WalletRules.new) { unauthorized_delivery = true; nil } }
      unauthorized_delivery.should be_false
      store.close
    end
  end
end
