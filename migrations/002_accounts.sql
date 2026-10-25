ALTER TABLE fuel_accounts ADD COLUMN IF NOT EXISTS progress_initialized boolean NOT NULL DEFAULT false;
UPDATE fuel_accounts a SET progress_initialized=true
WHERE NOT progress_initialized AND (progress<>'{}'::jsonb OR EXISTS (
  SELECT 1 FROM fuel_results r WHERE r.ns=a.ns AND r.account=a.id
));
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
