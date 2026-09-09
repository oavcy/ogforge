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
--   Of the REFERRER: host only. Never its full URL, its path or its query string. No
--   IP, no user agent, no cookie, no identifier of any kind.
--
--   That list describes the referrer, NOT the table. Two columns below describe this
--   site rather than the visitor, and reading the list as a table inventory makes
--   `path TEXT NOT NULL` four lines down look like a contradiction of "no path":
--     path     OUR landing path (e.g. `/postmortem/self-certifying-ci-gate`) — ours,
--              never the referrer's. Not exposed by GET /postmortem/hits.
--     seen_at  SECOND precision, not day. `day` is the day-granular column; seen_at
--              is where an exact last-hit time is read from (MAX(seen_at)) when a
--              cycle needs one. Also not exposed by the endpoint, which aggregates
--              to MIN(day)/MAX(day) — so a second-precision baseline cannot be
--              verified by curling that endpoint, only by querying D1.

CREATE TABLE IF NOT EXISTS inbound_hits (
  id        INTEGER PRIMARY KEY AUTOINCREMENT,
  path      TEXT NOT NULL,
  ref_host  TEXT NOT NULL,
  day       TEXT NOT NULL DEFAULT (date('now')),
  seen_at   TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_inbound_ref_host ON inbound_hits(ref_host);
CREATE INDEX IF NOT EXISTS idx_inbound_day ON inbound_hits(day);
