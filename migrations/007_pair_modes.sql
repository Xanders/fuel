ALTER TABLE fuel_pairs ADD COLUMN IF NOT EXISTS issuer_binding text;
ALTER TABLE fuel_bindings ADD COLUMN IF NOT EXISTS basic_transfer boolean NOT NULL DEFAULT false;
CREATE UNIQUE INDEX IF NOT EXISTS fuel_pairs_active_code ON fuel_pairs(ns,code_hash) WHERE status IN ('pending','basic_pending');
