CREATE TABLE IF NOT EXISTS fuel_enrollments (
  ns text NOT NULL, request_id text NOT NULL, account text,
  PRIMARY KEY(ns,request_id)
);
CREATE TABLE IF NOT EXISTS fuel_login_grants (
  ns text NOT NULL, id text NOT NULL, account text NOT NULL, code_hash text NOT NULL,
  candidate text, cancelled boolean NOT NULL DEFAULT false, expires_at timestamptz NOT NULL,
  PRIMARY KEY(ns,id), UNIQUE(ns,code_hash),
  FOREIGN KEY(ns,account) REFERENCES fuel_accounts(ns,id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS fuel_login_grants_account ON fuel_login_grants(ns,account);
