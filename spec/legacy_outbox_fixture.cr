# Schema created by Fuel 0.3.14 and its durable predecessors.
def create_legacy_outbox(db : DB::Database)
  db.exec <<-SQL
    CREATE TABLE IF NOT EXISTS fuel_outbox (
      ns text NOT NULL, id text NOT NULL, account text NOT NULL, body jsonb NOT NULL,
      attempts integer NOT NULL DEFAULT 0, due timestamptz NOT NULL DEFAULT now(),
      revision bigint NOT NULL DEFAULT 0, created_at timestamptz NOT NULL DEFAULT now(),
      halted boolean NOT NULL DEFAULT false,
      PRIMARY KEY(ns,id), FOREIGN KEY(ns,account) REFERENCES fuel_accounts(ns,id) ON DELETE CASCADE
    )
    SQL
end
