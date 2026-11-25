ALTER TABLE fuel_pairs ADD COLUMN IF NOT EXISTS issuer_binding text;
CREATE UNIQUE INDEX IF NOT EXISTS fuel_pairs_active_code ON fuel_pairs(ns,code_hash) WHERE status IN ('pending','basic_pending');
