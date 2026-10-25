ALTER TABLE fuel_bindings ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE fuel_bindings ADD COLUMN IF NOT EXISTS last_seen timestamptz NOT NULL DEFAULT now();
CREATE TABLE IF NOT EXISTS fuel_retired_bindings (
  ns text NOT NULL, id text NOT NULL, PRIMARY KEY(ns,id)
);
CREATE TABLE IF NOT EXISTS fuel_deletions (
  ns text NOT NULL, proof text NOT NULL, account_digest text NOT NULL,
  result jsonb NOT NULL, expires_at timestamptz NOT NULL DEFAULT now()+interval '30 days',
  PRIMARY KEY(ns,proof)
);
