ALTER TABLE fuel_accounts ADD COLUMN IF NOT EXISTS progress_initialized boolean NOT NULL DEFAULT false;
CREATE TABLE IF NOT EXISTS fuel_operations (
  ns text NOT NULL, account text NOT NULL, id text NOT NULL, fingerprint text NOT NULL,
  cursor bigserial NOT NULL, reply jsonb NOT NULL, PRIMARY KEY(ns,account,id),
  FOREIGN KEY(ns,account) REFERENCES fuel_accounts(ns,id) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS fuel_operation_views (
  ns text NOT NULL, account text NOT NULL, id text NOT NULL, cursor bigint NOT NULL,
  receipt jsonb NOT NULL, PRIMARY KEY(ns,account,id),
  FOREIGN KEY(ns,account) REFERENCES fuel_accounts(ns,id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS fuel_operation_history ON fuel_operation_views(ns,account,cursor);
