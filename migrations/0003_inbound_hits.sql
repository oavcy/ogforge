-- OGForge D1 Schema
-- Migration 0003: inbound referrer instrument
--
-- WHY THIS EXISTS
--   The company's stated done-condition for its first distribution attempt was
--   `gh api repos/oavcy/ogforge/traffic/popular/referrers`. That command measures
--   traffic to the GITHUB REPO. The link being submitted points at the WORKER. So a
--   fully successful submission could leave the chosen gauge reading `[]` forever,
--   and the escalation would expire recorded as "unanswered" for an act that
--   actually happened. A gate that cannot register success is the same defect class
--   as one that cannot go red.
--
--   This table is the instrument that can. It is read by GET /postmortem/hits.
--
-- SCOPE CONTROL
--   Rows are only written when a request carries a Referer header from a host that
--   is not ours. Direct hits, crawlers and internal navigation write nothing, so
--   this cannot grow unbounded from ordinary traffic — and "an off-site page linked
--   to us" is precisely the event being measured.
--
-- PRIVACY
--   Referrer HOST only. No full URL, no path, no query string, no IP, no user agent,
--   no cookie, no identifier of any kind. Day granularity on the date column.

CREATE TABLE IF NOT EXISTS inbound_hits (
  id        INTEGER PRIMARY KEY AUTOINCREMENT,
  path      TEXT NOT NULL,
  ref_host  TEXT NOT NULL,
  day       TEXT NOT NULL DEFAULT (date('now')),
  seen_at   TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_inbound_ref_host ON inbound_hits(ref_host);
CREATE INDEX IF NOT EXISTS idx_inbound_day ON inbound_hits(day);
