-- SnapOG D1 Schema
-- Migration 0002: close the self-service paid-tier giveaway
--
-- Before this migration POST /register trusted the `tier` field coming from the
-- signup form, so anyone could mint a 100,000 images/month "business" key for
-- free. Paid tiers are now server-assigned only. A request for a paid tier is
-- recorded here as a demand signal instead of being granted.

CREATE TABLE IF NOT EXISTS tier_interest (
  id              TEXT PRIMARY KEY,
  email           TEXT NOT NULL,
  -- Free-form label for what the visitor asked for, e.g. 'more-renders'
  requested_tier  TEXT NOT NULL,
  -- Where the request came from, e.g. 'landing' — free-form, for attribution
  source          TEXT NOT NULL DEFAULT 'register',
  created_at      TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_tier_interest_tier ON tier_interest(requested_tier);
CREATE INDEX IF NOT EXISTS idx_tier_interest_email ON tier_interest(email);

-- Audit trail for keys whose allowance was raised out of band (POST /admin/upgrade).
ALTER TABLE api_keys ADD COLUMN upgraded_at TEXT;
