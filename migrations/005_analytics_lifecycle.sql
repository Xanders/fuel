ALTER TABLE fuel_accounts ADD COLUMN IF NOT EXISTS analytics_revision bigint NOT NULL DEFAULT 0;
ALTER TABLE fuel_outbox ADD COLUMN IF NOT EXISTS revision bigint NOT NULL DEFAULT 0;
ALTER TABLE fuel_outbox ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE fuel_outbox ADD COLUMN IF NOT EXISTS halted boolean NOT NULL DEFAULT false;
CREATE INDEX IF NOT EXISTS fuel_outbox_due ON fuel_outbox(ns,due) WHERE NOT halted;
