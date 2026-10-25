CREATE TABLE IF NOT EXISTS fuel_mutes (
  ns text NOT NULL, account text NOT NULL, target text NOT NULL,
  PRIMARY KEY(ns,account,target), CHECK(account<>target),
  FOREIGN KEY(ns,account) REFERENCES fuel_accounts(ns,id) ON DELETE CASCADE,
  FOREIGN KEY(ns,target) REFERENCES fuel_accounts(ns,id) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS fuel_reports (
  ns text NOT NULL, id text NOT NULL, reporter text NOT NULL, target text NOT NULL,
  message_id text NOT NULL, channel text NOT NULL, message_text text NOT NULL,
  reason text NOT NULL, expires_at timestamptz NOT NULL DEFAULT now()+interval '7 days',
  PRIMARY KEY(ns,id), UNIQUE(ns,reporter,message_id),
  FOREIGN KEY(ns,reporter) REFERENCES fuel_accounts(ns,id) ON DELETE CASCADE,
  FOREIGN KEY(ns,target) REFERENCES fuel_accounts(ns,id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS fuel_reports_expiry ON fuel_reports(ns,expires_at);
