CREATE TABLE IF NOT EXISTS fuel_accounts (
  ns text NOT NULL, id text NOT NULL, progress jsonb NOT NULL DEFAULT '{}',
  analytics_enabled boolean NOT NULL DEFAULT true, PRIMARY KEY(ns,id)
);
CREATE TABLE IF NOT EXISTS fuel_bindings (
  ns text NOT NULL, id text NOT NULL, account text, verifier text NOT NULL,
  revoked boolean NOT NULL DEFAULT false, expires_at timestamptz,
  PRIMARY KEY(ns,id), FOREIGN KEY(ns,account) REFERENCES fuel_accounts(ns,id) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS fuel_pairs (
  ns text NOT NULL, id text NOT NULL, account text NOT NULL, code_hash text NOT NULL,
  candidate text, phrase text, status text NOT NULL DEFAULT 'pending', expires_at timestamptz NOT NULL,
  PRIMARY KEY(ns,id), FOREIGN KEY(ns,account) REFERENCES fuel_accounts(ns,id) ON DELETE CASCADE
);
CREATE UNIQUE INDEX IF NOT EXISTS fuel_pairs_code ON fuel_pairs(ns,code_hash) WHERE status='pending';
CREATE INDEX IF NOT EXISTS fuel_pairs_candidate ON fuel_pairs(ns,candidate);
CREATE TABLE IF NOT EXISTS fuel_results (
  ns text NOT NULL, account text NOT NULL, id text NOT NULL, fingerprint text NOT NULL,
  reply jsonb NOT NULL, board text NOT NULL, name text NOT NULL, outcome text,
  completed_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(ns,account,id),
  FOREIGN KEY(ns,account) REFERENCES fuel_accounts(ns,id) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS fuel_scores (
  ns text NOT NULL, board text NOT NULL, account text NOT NULL, score bigint NOT NULL CHECK(score>=0),
  name text NOT NULL, achieved_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(ns,board,account),
  FOREIGN KEY(ns,account) REFERENCES fuel_accounts(ns,id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS fuel_scores_rank ON fuel_scores(ns,board,score DESC,achieved_at,account);
CREATE TABLE IF NOT EXISTS fuel_limits (
  ns text NOT NULL, key text NOT NULL, bucket bigint NOT NULL, count integer NOT NULL,
  expires_at timestamptz NOT NULL, PRIMARY KEY(ns,key)
);
CREATE TABLE IF NOT EXISTS fuel_chat (
  ns text NOT NULL, id text NOT NULL, channel text NOT NULL, actor text NOT NULL, recipient text NOT NULL,
  body jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT clock_timestamp(), expires_at timestamptz NOT NULL,
  PRIMARY KEY(ns,id)
);
CREATE INDEX IF NOT EXISTS fuel_chat_history ON fuel_chat(ns,channel,created_at DESC,id DESC);
CREATE TABLE IF NOT EXISTS fuel_outbox (
  ns text NOT NULL, id text NOT NULL, account text NOT NULL, body jsonb NOT NULL,
  attempts integer NOT NULL DEFAULT 0, due timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(ns,id), FOREIGN KEY(ns,account) REFERENCES fuel_accounts(ns,id) ON DELETE CASCADE
);
