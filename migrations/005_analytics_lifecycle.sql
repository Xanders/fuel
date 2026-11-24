ALTER TABLE fuel_accounts ADD COLUMN IF NOT EXISTS analytics_revision bigint NOT NULL DEFAULT 0;
