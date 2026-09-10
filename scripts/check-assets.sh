#!/usr/bin/env bash
# check-assets.sh — anonymous asset/link reachability checker for OGForge.
#
# WHY THIS EXISTS
#   For 19 cycles the landing page shipped <img src="/og?title=..."> with no API key.
#   /og returns 401 without a key, so the hero "Live OG preview" was a broken image
#   for every human who ever visited. Cycle #18 diagnosed the exact mechanism
#   ("crawlers have no key -> 401") in a comment one line below the <img> tag and
#   still did not fix the tag. Reading the file was not enough. Fetching is.
#
# WHAT IT DOES
#   Fetches each page ANONYMOUSLY (no API key, no cookies, no auth header) — exactly
#   what a browser, a crawler, or a Slack/Twitter unfurler gets — extracts every local
#   src=/href=/og:image reference, fetches each one, and asserts:
#     * the response is not 4xx/5xx
#     * anything that is supposed to be an image actually has content-type: image/*
#
#   It ALSO checks markdown docs (README.md), because the repo front page is a
#   published surface too and it was never covered. Cycle #20 found out how: the
#   README credited our core renderer to `github.com/nicholasgasior/workers-og`,
#   which is a 404 — an invented repo under a real person's account. Twenty cycles
#   of reading that file did not catch it; one fetch did.
#
# THE ADVISORY CLASS (Cycle #24)
#   Until #24 the two scans had OPPOSITE policies for the same thing. The page scan
#   dropped every off-host reference silently (counted as "skipped"); the doc scan
#   fetched them and let a stranger's outage fail our deploy. Neither is right, and
#   having both is worse than having either: the postmortem page's entire
#   credibility rests on ten off-host citations, and the summary line reported
#   46/46 while checking exactly none of them.
#
#   One policy now, both scans: an off-host reference is ADVISORY. It is fetched,
#   it is reported, and it never changes the exit code. Two severities, because
#   "your citation is gone" and "their server is down" are different facts:
#
#     WARN  4xx — the thing we cited is GONE. That is a defect in OUR page.
#     NOTE  5xx / timeout / DNS — THEIR outage. Never our defect, never actionable
#           by us, and the single most common reason a link checker gets ignored.
#
#   --external-strict promotes WARN (only WARN) to a real failure. That flag is
#   what makes this class falsifiable rather than decorative: same detection, same
#   fetch, different exit code — so "can this thing go red?" is answerable by
#   command instead of by reading the source.
#
#   EXCLUDED from the fetch set: <link rel="preconnect"> and rel="dns-prefetch".
#   Their href is a bare ORIGIN and the browser never issues a GET for it — it
#   opens a socket. Fetching them produced this script's only two false 404s.
#   They are counted and printed as their own "hint" class, not silently dropped.
#   NOT excluded: rel="preload"/"modulepreload", which the browser really does
#   fetch. (Cycle #23's written design said to exclude those too; `curl` says
#   otherwise about what a preload is, and an advisory WARN cannot break a deploy,
#   so there is no reason to buy a blind spot here. See docs/devops/cycle-24.)
#
# FALSIFIABILITY (company standing rule: a gate that cannot go red is not evidence)
#   --self-test injects known-bad URLs and asserts this checker calls them FAIL,
#   plus one known-good URL it must call PASS. If the self-test does not behave,
#   the script exits non-zero and declares ITSELF untrustworthy. The self-test also
#   runs as a preflight on every normal run (disable with --no-self-test).
#
# PORTABILITY
#   No GNU coreutils. `timeout` does not exist here -> curl --max-time.
#   `python` is not on PATH -> nothing but curl/grep/sed/awk/tr is used.
#   BSD (macOS) sed/grep compatible. bash 3.2 compatible (no assoc arrays).
#
# USAGE
#   ./scripts/check-assets.sh [BASE_URL] [--self-test] [--no-self-test]
#                             [--no-docs] [--docs-only] [--verbose]
#                             [--external-lenient] [--no-external]
#
# EXIT CODES
#   0  everything passed
#   1  at least one page, asset or doc link failed, or an external citation is GONE
#      (4xx). --external-lenient downgrades that last case to advice.
#   2  the checker itself is untrustworthy (self-test misbehaved) or bad usage

set -u

DEFAULT_BASE="https://snapog.aoadmin.workers.dev"
BASE=""
MODE="full"        # full | selftest-only | docs-only
RUN_SELFTEST=1
RUN_DOCS=1
VERBOSE=0
RUN_EXTERNAL=1     # fetch off-host references
# WARN ("we cited something that is GONE") fails the run by DEFAULT.
# The first version of this made it opt-in via --external-strict, and package.json
# calls this script with no flags, so in the only path that ever runs, an invented
# repo under a real person's name would have shipped green — the exact Cycle #20
# defect this gate was built to catch, preserved as a comment and removed as a
# behaviour. A control you have to remember to pass is not a control.
# NOTE ("their host is down") never fails, in any mode. That distinction is what
# makes failing on WARN affordable.
EXT_WARN_FAILS=1

# Markdown files that are published to strangers. Paths are relative to the repo
# root (the parent of scripts/), so the script works from any cwd.
DOCS="${DOCS:-README.md}"

# A real browser UA: we are reproducing what a HUMAN visitor sees, and some
# origins vary behaviour by UA. Crucially we send NO credentials of any kind.
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"

MAX_TIME=25
CONNECT_TIMEOUT=10

while [ $# -gt 0 ]; do
  case "$1" in
    --self-test)    MODE="selftest-only" ;;
    --no-self-test) RUN_SELFTEST=0 ;;
    --no-docs)      RUN_DOCS=0 ;;
    --docs-only)    MODE="docs-only" ;;
    --verbose|-v)   VERBOSE=1 ;;
    --external-lenient) EXT_WARN_FAILS=0 ;;
    --external-strict)  EXT_WARN_FAILS=1 ;;   # now the default; kept as a no-op alias
    --no-external)  RUN_EXTERNAL=0 ;;
    -h|--help)      sed -n '2,80p' "$0"; exit 0 ;;
    -*)             echo "unknown flag: $1" >&2; exit 2 ;;
    *)              BASE="$1" ;;
  esac
  shift
done

[ -n "$BASE" ] || BASE="$DEFAULT_BASE"
BASE="${BASE%/}"                       # strip trailing slash
BASE_HOST=$(printf '%s' "$BASE" | sed -e 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' -e 's#/.*$##')

command -v curl >/dev/null 2>&1 || { echo "FATAL: curl not found" >&2; exit 2; }

# Repo root = parent of scripts/. Resolved from $0 so DOCS paths hold from any cwd
# (npm runs this from the package dir, a human may run it from anywhere).
REPO_ROOT=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)
[ -n "$REPO_ROOT" ] || { echo "FATAL: cannot resolve repo root from $0" >&2; exit 2; }

WORKDIR=$(mktemp -d 2>/dev/null || mktemp -d -t ogforge)
trap 'rm -rf "$WORKDIR"' EXIT INT TERM

# ---------------------------------------------------------------- pages to check
# "path|expected" — expected is a regex anchored against the HTTP status.
# A page a human can reach must be 2xx. The deliberately-missing path must be 404:
# that entry is here so the checker proves it can tell "gone" from "fine", and so a
# catch-all route that silently 200s every URL cannot hide.
PAGES='
/|^2[0-9][0-9]$
/register|^2[0-9][0-9]$
/dashboard|^2[0-9][0-9]$
/postmortem/self-certifying-ci-gate|^2[0-9][0-9]$
/postmortem/hits|^2[0-9][0-9]$
/definitely-not-a-real-page-9f3a1c|^404$
'

# ------------------------------------------------------------------- output state
TOTAL=0; PASSED=0; FAILED=0; SKIPPED=0

# Self-test row tally. Cycle #24's consensus quoted "57 self-test assertions" in
# one paragraph and "39 assertions" in another; #25 found neither reproducible and
# recorded that "the script prints no runtime assertion total". True — but the rows
# were always countable with `grep -c '^selftest '`, which nobody ran. So the fix
# is not a comment, it is a printed number plus a floor that fails when the
# self-test silently stops emitting rows. A shrinking self-test is invisible
# otherwise: every remaining row still says OK.
ST_ROWS=0; ST_BAD=0
# Floor on CHECK rows only — the meta/coverage rows the floor itself emits are
# excluded by construction (the count is read before they exist). 59 was measured
# on 2026-09-09 (Cycle #26). #26 A3 standing: DO NOT raise this. It is lowerable
# by one character, which is the whole reason it is a tripwire and not a floor;
# its value was never the problem, so "finishing the job" by raising it does
# nothing. It is tracked, so any change to it shows in a diff and in git blame.
ST_ROWS_MIN=59
FAILLOG="$WORKDIR/failures.txt"
: > "$FAILLOG"

# The advisory class is counted in its OWN variables and never touches TOTAL /
# PASSED / FAILED. That separation is the point: a reader must be able to tell
# "46 things were checked" from "46 things were checked and 10 more were looked at
# under a weaker rule", and a single blended number cannot say that.
EXT_TOTAL=0; EXT_OK=0; EXT_WARN=0; EXT_NOTE=0; HINTS=0
EXTLOG="$WORKDIR/advisory.txt"
: > "$EXTLOG"

row() { # page kind verdict status ct url reason
  if [ "$1" = "selftest" ]; then
    ST_ROWS=$((ST_ROWS + 1))
    [ "$3" = "BAD" ] && ST_BAD=$((ST_BAD + 1))
  fi
  printf '%-14s %-6s %-4s %-4s %-26s %s%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "${7:+  <-- $7}"
}

hr() { printf '%s\n' "----------------------------------------------------------------------------------------------------"; }

# --------------------------------------------------------------- canonical head
# Cycle #50 shipped a `<link rel="canonical">` on /dashboard that named /register,
# and this gate fetched /dashboard, got 200, and passed it. Nothing here compared
# what a page CLAIMS to be against the URL that actually served it, so the whole
# class was invisible. These two functions are that comparison.
#
# Absent canonical is NOT a failure: /dashboard and the error pages are noindex on
# purpose, and a crawler with no canonical falls back to the request URL, which is
# correct. Only a canonical naming a DIFFERENT address is a defect.
page_canonical() { # body-file -> href on stdout, empty if none
  tr '\n\r\t' '   ' < "$1" \
    | grep -oE '<link[^>]+rel="canonical"[^>]*>' \
    | grep -oE 'href="[^"]*"' \
    | head -1 | sed -e 's/^href="//' -e 's/"$//'
}

# Compare a canonical against the URL that answered, ignoring a single trailing
# slash (a server may canonicalize "/x" and "/x/" to one form legitimately).
# Returns 0 = MISMATCH detected, 1 = agrees or absent.
canonical_mismatch() { # body-file effective-url
  _can=$(page_canonical "$1")
  [ -n "$_can" ] || return 1
  _eff=$(printf '%s' "$2" | sed -e 's/#.*$//' -e 's|/$||')
  _can=$(printf '%s' "$_can" | sed -e 's|/$||')
  [ "$_can" = "$_eff" ] && return 1
  return 0
}

# ------------------------------------------------- noindex reachability (#53)
# Cycle #50 put `<meta name="robots" content="noindex, nofollow">` on /dashboard.
# Cycle #53 fetched Google's own documentation and found the tag had never been
# readable, because our robots.txt also said `Disallow: /dashboard`:
#
#   "Important: For the noindex rule to be effective, the page or resource must
#    not be blocked by a robots.txt file, and it has to be otherwise accessible
#    to the crawler."   -- developers.google.com/search/docs/crawling-indexing/
#                          block-indexing (fetched 2026-09-10, HTTP 200)
#
# Disallow and noindex are not two locks on one door. Disallow stops the FETCH,
# so the noindex behind it is never read and the URL can still be listed from an
# inbound link. Every check we owned passed while the two cancelled each other:
# the page really did carry the tag, and robots.txt really did carry the rule.
#
# Returns 0 = this path IS blocked by a Disallow rule, 1 = it is reachable.
robots_disallows() { # robots-body-file path
  _rf="$1"; _rp="$2"
  [ -s "$_rf" ] || return 1
  # Values only, whitespace trimmed. An empty `Disallow:` means "allow all" per
  # RFC 9309 and must not be read as blocking everything.
  grep -iE '^[[:space:]]*Disallow:' "$_rf" 2>/dev/null \
    | sed -e 's/^[^:]*:[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/\r$//' \
    | while IFS= read -r _rule; do
        [ -n "$_rule" ] || continue
        case "$_rp" in "$_rule"*) echo BLOCKED ;; esac
      done | grep -q BLOCKED
}

# What directive does this response actually carry? Header OR meta tag: a JSON
# endpoint cannot carry a meta tag, so a check that only reads HTML would report
# "no directive" for the exact case where the header is the only mechanism.
response_says_noindex() { # header-file body-file
  grep -iE '^x-robots-tag:.*noindex' "$1" >/dev/null 2>&1 && return 0
  [ -s "$2" ] || return 1
  tr -d '\n' < "$2" \
    | grep -oiE '<meta[^>]+name="robots"[^>]*>' 2>/dev/null \
    | grep -qi 'noindex'
}

# ------------------------------------------------- sitemap field discipline (#54)
# Cycle #53 found a defect in the COMPOSITION of two mechanisms that were each
# correct. Cycle #54 asked the same question one rung out — not "do two of MY
# mechanisms compose?" but "does my mechanism compose with the CONSUMER's published
# rule for reading it?" — and the sitemap answered:
#
#   "Google ignores <priority> and <changefreq> values."
#   "Google uses the <lastmod> value if it's consistently and verifiably (for
#    example by comparing to the last modification of the page) accurate."
#     -- developers.google.com/search/docs/crawling-indexing/sitemaps/build-sitemap
#        (fetched 2026-09-10, HTTP 200, redirects=0)
#
# Every entry carried the two ignored fields and none carried the one that is read.
# Both halves were individually valid — sitemaps.org marks all three optional, so
# no XML validator would ever flag this — and together they conveyed nothing, while
# two of the values were false (`yearly` on a page that changed in four consecutive
# cycles; `weekly` on `/`, which changes several times a day).
#
# Prints one line per defect; empty output means clean. A predicate rather than an
# inline block so the self-test can drive it on synthetic fixtures, including the
# reconstructed pre-#54 sitemap that MUST come back red.
#
# The <lastmod> assertions are deliberately live before the field is. If a future
# cycle adds lastmod, this is already waiting to reject a malformed or future date
# — the two ways that field goes wrong without anything else noticing.
sitemap_field_defects() { # sitemap-body-file today-YYYY-MM-DD
  _sf="$1"; _stoday="$2"
  # An unreadable sitemap makes every verdict below vacuous. Say so; never let an
  # empty input read as a clean result (#41).
  [ -s "$_sf" ] || { echo "UNREADABLE: sitemap is empty or was not fetched"; return 0; }
  grep -q '<urlset' "$_sf" 2>/dev/null || {
    echo "NOT-A-SITEMAP: no <urlset> element — this is not a sitemap document"; return 0; }

  _scf=$(grep -o '<changefreq>' "$_sf" 2>/dev/null | wc -l | tr -d ' ')
  [ "$_scf" -gt 0 ] && \
    echo "IGNORED-FIELD: ${_scf} <changefreq> element(s) — Google publishes that it ignores these"
  _spr=$(grep -o '<priority>' "$_sf" 2>/dev/null | wc -l | tr -d ' ')
  [ "$_spr" -gt 0 ] && \
    echo "IGNORED-FIELD: ${_spr} <priority> element(s) — Google publishes that it ignores these"

  _su=$(grep -o '<url>' "$_sf" 2>/dev/null | wc -l | tr -d ' ')
  _sl=$(grep -o '<loc>' "$_sf" 2>/dev/null | wc -l | tr -d ' ')
  [ "$_su" -eq "$_sl" ] || \
    echo "SHAPE: ${_su} <url> element(s) but ${_sl} <loc> — every <url> needs exactly one <loc>"
  [ "$_su" -gt 0 ] || \
    echo "EMPTY: <urlset> contains zero <url> entries — a sitemap that submits nothing"

  # Any <lastmod> that IS present must be a W3C Datetime and must not be in the
  # future. A future modification date cannot be true of any page.
  grep -o '<lastmod>[^<]*</lastmod>' "$_sf" 2>/dev/null \
    | sed -e 's|<lastmod>||' -e 's|</lastmod>||' \
    | while IFS= read -r _sd; do
        case "$_sd" in
          [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]|[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*) ;;
          *) echo "BAD-LASTMOD: '${_sd}' is not W3C Datetime (YYYY-MM-DD or a full timestamp)"
             continue ;;
        esac
        if [ "$(printf '%s' "$_sd" | cut -c1-10)" \> "$_stoday" ]; then
          echo "FUTURE-LASTMOD: '${_sd}' is later than today (${_stoday}) — cannot be a modification date"
        fi
      done
  return 0
}

# ------------------------------------- 401 challenge discipline (#55)
# #54 asked "who READS this output, and what have they published about how they
# read it?" and found a sitemap nobody read. #55 asked it of /og's ERROR
# responses, where the consumer is every HTTP client and cache on the internet
# and the published rule is normative. Fetched this cycle, not recalled:
#
#   "The server generating a 401 response MUST send a WWW-Authenticate header
#    field (Section 11.6.1) containing at least one challenge applicable to the
#    target resource."          -- RFC 9110 §15.5.2, repeated verbatim in §11.6.1
#
#   "All challenges defined by this specification MUST use the auth-scheme
#    value 'Bearer'. ... The 'realm' attribute MUST NOT appear more than once."
#   "If the request lacks any authentication information ... the resource server
#    SHOULD NOT include an error code or other error information."
#   "invalid_token: The access token provided is expired, revoked, malformed, or
#    invalid ... SHOULD respond with the HTTP 401 status code."
#                                                    -- RFC 6750 §3, §3.1
#
# /og sent bare 401s for 55 cycles. Note what was NOT wrong: the status code was
# right, the JSON body was clear and actionable, and no client ever complained —
# there are no clients. A defect against a MUST does not need a victim to exist.
#
# `Vary` is checked in the same predicate because the two are one change. See the
# note above readCredential() in src/index.ts: reading `Authorization` while
# serving `Cache-Control: public, s-maxage=604800` is exactly the shape RFC 9111
# §3.5 permits a shared cache to collapse. Splitting these into two checks would
# let a future cycle satisfy one and drop the other.
auth_challenge_defects() { # headers-file  expect(none|invalid)
  _af="$1"; _aexp="$2"
  # An unfetched response makes every verdict below vacuous (#41). Never let an
  # empty input read as a clean result.
  [ -s "$_af" ] || { echo "UNREADABLE: no response headers captured"; return 0; }

  _ast=$(grep -i '^HTTP/' "$_af" 2>/dev/null | tail -1 | tr -d '\r' | awk '{print $2}')
  [ -n "$_ast" ] || { echo "UNREADABLE: no status line in captured headers"; return 0; }
  if [ "$_ast" != "401" ]; then
    echo "STATUS: got ${_ast}, expected 401 — a rejected credential is 401 (RFC 6750 §3.1)"
    return 0
  fi

  _awa=$(grep -i '^WWW-Authenticate:' "$_af" 2>/dev/null | head -1 | tr -d '\r' \
         | sed -e 's/^[Ww][Ww][Ww]-[Aa]uthenticate:[[:space:]]*//')
  if [ -z "$_awa" ]; then
    echo "NO-CHALLENGE: 401 without WWW-Authenticate — RFC 9110 §15.5.2 makes this a MUST"
  else
    case "$_awa" in
      Bearer\ *|Bearer) ;;
      *) echo "SCHEME: challenge is '${_awa%% *}', not Bearer (RFC 6750 §3 MUST)" ;;
    esac
    _arn=$(printf '%s' "$_awa" | grep -o 'realm=' | wc -l | tr -d ' ')
    [ "$_arn" -le 1 ] || \
      echo "REALM: 'realm' appears ${_arn} times — RFC 6750 §3 says MUST NOT appear more than once"
    case "$_aexp" in
      none)
        # No credentials were sent, so there is nothing to report an error ABOUT.
        printf '%s' "$_awa" | grep -q 'error=' && \
          echo "OVERSHARE: challenge carries error= for a request that sent no credentials (RFC 6750 §3.1 SHOULD NOT)"
        ;;
      invalid)
        # This row is the anti-prop assertion: it can only pass if the server
        # actually READ the credential it is now advertising it accepts.
        printf '%s' "$_awa" | grep -q 'error="invalid_token"' || \
          echo "NO-ERROR-CODE: a rejected credential must say error=\"invalid_token\" (RFC 6750 §3.1)"
        ;;
    esac
  fi

  _av=$(grep -i '^Vary:' "$_af" 2>/dev/null | tr -d '\r' | sed -e 's/^[Vv]ary:[[:space:]]*//')
  printf '%s' "$_av" | grep -qi 'authorization' || \
    echo "NO-VARY: response reads Authorization but omits 'Vary: Authorization' (RFC 9111 §3.5, §4.1)"
  return 0
}

# ---------------------------------- retry semantics (#56)
# #55 asked "what does my fix make newly possible, and which other standard
# governs that?" #56 asked a blunter question of one status code we use TWICE:
# is the code itself true? Fetched this cycle, not recalled:
#
#   "The 429 status code indicates that the user has sent too many requests in a
#    given amount of time ("rate limiting")."
#   "The response representations SHOULD include details explaining the
#    condition, and MAY include a Retry-After header indicating how long to wait
#    before making a new request."
#   "Responses with the 429 status code MUST NOT be stored by a cache."
#                                                        -- RFC 6585 §4
#   "Retry-After = HTTP-date / delay-seconds ... A delay-seconds value is a
#    non-negative decimal integer"                        -- RFC 9110 §10.2.3
#   409: "used in situations where the user MIGHT BE ABLE to resolve the
#    conflict and resubmit the request."                  -- RFC 9110 §15.5.10
#   403: "the server understood the request but refuses to fulfill it ... The
#    client SHOULD NOT automatically repeat the request." -- RFC 9110 §15.5.4
#
# NOTE WHERE 429 IS *NOT* DEFINED. RFC 9110 does not define it; the string "429"
# occurs ZERO times in all 502,941 bytes of it, and §15.5 stops at 15.5.22 (426).
# A citation of "RFC 9110 §15.5.30" for 429 is a phantom. This company's own
# consensus carried that phantom into the instruction that says "fetch the
# standard, do not recall it" — recalled, in the sentence telling us not to.
#
# THE RULE THIS PREDICATE ENFORCES, which is NOT "429 needs Retry-After":
#   a status code that invites a retry which can never succeed is a lie,
#   whatever its number.
# The first draft of this check was "a 429 whose Retry-After cannot be honestly
# computed is not a 429". That was rejected as both too narrow and too weak: a
# genuine load-shedding limiter with jittered recovery cannot compute one and is
# still unambiguously a 429, and the narrow form let 409 through — 409 invites a
# MANUAL retry that can never succeed, which is the same lie told more quietly.
#
# POST /register answered 429 for 56 cycles when an email held MAX_KEYS_PER_EMAIL
# keys. There is no time in that condition: the cap is COUNT(*) against a
# constant and no `DELETE FROM api_keys` exists in the worker, so the count never
# falls. The response contradicted itself in plain sight — the BODY said "that's
# the maximum" (never) under a STATUS LINE meaning "too many requests in a given
# amount of time" (later). Measured on a local workerd, both directions.
retry_semantics_defects() { # headers-file  condition(transient|permanent)
  _rf="$1"; _rcond="$2"
  # An unfetched response makes every verdict below vacuous (#41).
  [ -s "$_rf" ] || { echo "UNREADABLE: no response headers captured"; return 0; }

  _rst=$(grep -i '^HTTP/' "$_rf" 2>/dev/null | tail -1 | tr -d '\r' | awk '{print $2}')
  [ -n "$_rst" ] || { echo "UNREADABLE: no status line in captured headers"; return 0; }

  _rra=$(grep -i '^Retry-After:' "$_rf" 2>/dev/null | head -1 | tr -d '\r' \
         | sed -e 's/^[Rr]etry-[Aa]fter:[[:space:]]*//' -e 's/[[:space:]]*$//')
  _rcc=$(grep -i '^Cache-Control:' "$_rf" 2>/dev/null | head -1 | tr -d '\r' \
         | sed -e 's/^[Cc]ache-[Cc]ontrol:[[:space:]]*//')

  # ---- the lie test, first, because it is the whole point -------------------
  if [ "$_rcond" = "permanent" ]; then
    case "$_rst" in
      429)
        echo "RETRY-LIE: 429 for a condition no amount of waiting clears — RFC 6585 §4 scopes 429 to 'too many requests in a given amount of time'" ;;
      409)
        echo "RETRY-LIE: 409 invites a resubmit the user cannot make — RFC 9110 §15.5.10 requires that the user MIGHT resolve the conflict" ;;
      403) ;;
      *)   echo "STATUS: got ${_rst} for a permanent refusal; 403 is the code that says SHOULD NOT automatically repeat (RFC 9110 §15.5.4)" ;;
    esac
    # A permanent refusal must not suggest a wait, whatever its status number.
    [ -z "$_rra" ] || \
      echo "STRAY-RETRY-AFTER: a permanent refusal carries Retry-After: ${_rra}, which states a falsehood"
  fi

  # ---- 429-specific obligations ---------------------------------------------
  # Gated on the condition being transient on purpose. If we already said the
  # 429 is a lie for this condition, demanding it also carry Retry-After would
  # be self-contradictory advice: "add the header that would state a falsehood".
  # The defect is the status code; its headers are not the finding.
  if [ "$_rst" = "429" ] && [ "$_rcond" != "permanent" ]; then
    if [ -z "$_rra" ]; then
      # RFC 6585 §4 makes this a MAY. It is a house MUST because OUR window is
      # the calendar month and the value is therefore exactly computable. A MAY
      # declined for a good reason is fine; declined because nobody looked is
      # what this row is for.
      echo "NO-RETRY-AFTER: 429 without Retry-After, though this service's quota window is computable (RFC 6585 §4)"
    fi
    case "$_rcc" in
      *no-store*) ;;
      "") echo "CACHEABLE-429: no Cache-Control — RFC 6585 §4 says a 429 MUST NOT be stored by a cache; send no-store rather than trusting every intermediary read it" ;;
      *)  echo "CACHEABLE-429: Cache-Control '${_rcc}' lacks no-store — RFC 6585 §4 MUST NOT be stored by a cache" ;;
    esac
  fi

  # ---- Retry-After syntax and scope, on ANY status --------------------------
  if [ -n "$_rra" ]; then
    # RFC 9110 §10.2.3 defines the field for 503 and 3xx; RFC 6585 §4 adds 429.
    # Anywhere else it is a value no consumer has a rule for (#54's question).
    case "$_rst" in
      429|503|3??) ;;
      *) echo "SCOPE: Retry-After on a ${_rst}; RFC 9110 §10.2.3 defines it for 503 and 3xx, RFC 6585 §4 for 429" ;;
    esac
    # delay-seconds = 1*DIGIT, non-negative integer. Reject anything else that
    # is not a plausible HTTP-date. A negative or fractional value is the shape
    # a naive (target - now)/1000 produces after the boundary passes.
    case "$_rra" in
      *[!0-9]*)
        # Not all digits — allow an IMF-fixdate, reject the rest.
        case "$_rra" in
          *,\ *[0-9]*\ GMT) ;;
          *) echo "MALFORMED: Retry-After '${_rra}' is neither delay-seconds (1*DIGIT) nor an HTTP-date (RFC 9110 §10.2.3)" ;;
        esac ;;
      "") echo "MALFORMED: Retry-After is empty" ;;
      0)  echo "MALFORMED: Retry-After: 0 invites an immediate retry into the same closed gate" ;;
      *)  ;;
    esac
  fi
  return 0
}

# ---------------------------------- method semantics (#57)
# #56 asked whether a status code was true. #57 asks the same question one rung
# lower, of the code this service reaches for when it does not know what else to
# say. Fetched this cycle from rfc-editor.org (200, 502,941 B, redirects=0), and
# per #56 A2 the SECTION NUMBERS were verified to exist before being quoted —
# §15.5.5 at line 7587, §15.5.6 at line 7601, §10.2.1 at line 4710, §9.1 at 3728:
#
#   "The 404 (Not Found) status code indicates that the origin server did not
#    find a current representation for the target resource or is not willing to
#    disclose that one exists."                          -- RFC 9110 §15.5.5
#   "The 405 (Method Not Allowed) status code indicates that the method received
#    in the request-line is known by the origin server but not supported by the
#    target resource. The origin server MUST generate an Allow header field in a
#    405 response containing a list of the target resource's currently supported
#    methods."                                           -- RFC 9110 §15.5.6
#   "An origin server MUST generate an Allow header field in a 405 (Method Not
#    Allowed) response"                                  -- RFC 9110 §10.2.1
#   "All general-purpose servers MUST support the methods GET and HEAD. All
#    other methods are OPTIONAL."                        -- RFC 9110 §9.1
#
# Measured before the fix: POST/PUT/DELETE/PATCH/OPTIONS on `/` all returned 404
# with no Allow header, as did POST to /health, /robots.txt, /sitemap.xml,
# /dashboard, /postmortem/hits and /favicon.svg. `/` has a current representation
# (GET / -> 200, 33,473 B) and we are demonstrably willing to disclose it: it is
# the front door, one of the five <loc> entries in our own sitemap.xml, and its
# canonical link names it. So the 404 failed BOTH disjuncts of §15.5.5.
#
# Cycle #55 examined this same behaviour and recorded it CLEAN, on the reasoning
# that since we return 404 the "405 MUST send Allow" never applies. True, and
# backwards. The MUST did not apply because the code was wrong. A false status
# code does not discharge the obligations of the true one by displacing it —
# that is the general form of the trap, and it is why "no MUST applies here" is
# a conclusion that has to be earned rather than observed.
#
# THE EXCEPTION THAT WAS ARGUED OUT, recorded because the reasoning is the
# valuable part. The first draft carved out /admin/upgrade — a live secret-gated
# operator endpoint — so it would keep its 404 under §15.5.5's second disjunct
# instead of answering `405 Allow: POST` and publishing its own location. That
# was vetoed on a measurement the draft had already made and misread:
#
#   POST /admin/upgrade      -> 403  application/json          21 B
#   POST /admin/nonexistent  -> 404  text/html; charset=utf-8  15,868 B
#
# The path is ALREADY an existence oracle to anyone sending POST, which is what
# scanners send. The carve-out hid it from GET only, and in doing so made its own
# 404 a NEW false status code under the clause cited to justify it: §15.5.5's
# second disjunct requires that we are "not willing to disclose that one exists",
# and we disclose it on POST. It would have removed fifteen false 404s and
# manufactured a sixteenth WITH A CITATION ATTACHED — which is worse, because a
# cited falsehood survives review and an uncited one does not.
#
# So this predicate has two expectations, not three, and no path-specific
# exceptions of any kind. One rule. An exception list here would also have been
# a hand-maintained table thirty lines below a comment rejecting hand-maintained
# tables.
method_semantics_defects() { # headers-file  request-method  expectation(disclosed|absent)  expected-allow
  _mf="$1"; _mmeth="$2"; _mexp="$3"; _mwant="$4"
  # An unfetched response makes every verdict below vacuous (#41). Report and
  # fail; never let a dead fetch read as a pass.
  [ -s "$_mf" ] || { echo "UNREADABLE: no response headers captured"; return 0; }

  _mst=$(grep -i '^HTTP/' "$_mf" 2>/dev/null | tail -1 | tr -d '\r' | awk '{print $2}')
  [ -n "$_mst" ] || { echo "UNREADABLE: no status line in captured headers"; return 0; }

  # Read the count on its own line, then head -1: `grep -c` PRINTS 0 and EXITS 1
  # on no match, so `n=$(grep -c … || echo 0)` captures "0\n0" (#54, in the wild).
  _mac=$(grep -ci '^Allow:' "$_mf" 2>/dev/null | head -1); _mac=${_mac:-0}
  _mal=$(grep -i '^Allow:' "$_mf" 2>/dev/null | head -1 | tr -d '\r' \
         | sed -e 's/^[Aa]llow:[[:space:]]*//' -e 's/[[:space:]]*$//')

  case "$_mexp" in
    disclosed)
      if [ "$_mst" != "405" ]; then
        echo "STATUS-LIE: got ${_mst} for ${_mmeth} on a resource we publish; 404 claims no representation exists or that we will not disclose one, and both are false of a path in our own sitemap (RFC 9110 §15.5.5 vs §15.5.6)"
        return 0
      fi
      # The MUST. Not decoration: without it a 405 names no way forward at all.
      if [ "$_mac" -eq 0 ]; then
        echo "MISSING-ALLOW: 405 without an Allow header — RFC 9110 §15.5.6 and §10.2.1 both make this a MUST"
        return 0
      fi
      [ "$_mac" -eq 1 ] || \
        echo "DUPLICATE-ALLOW: ${_mac} Allow headers; a recipient may combine them, so send one list"
      # An empty value is legal per §10.2.1 ("the resource allows no methods")
      # but is false here — we only reach this branch for a registered route.
      [ -n "$_mal" ] || \
        echo "EMPTY-ALLOW: §10.2.1 reads an empty Allow as 'this resource allows no methods', which is false of a registered route"
      # Normalise ONCE into a comma-delimited, space-free, comma-fenced form so
      # the membership tests below are exact rather than substring-lucky: a bare
      # `*GET*` would match "TARGET" and `*HEAD*` would match "OVERHEAD".
      _mnorm=",$(printf '%s' "$_mal" | tr -d ' ' | tr -d '\r'),"
      # THE SELF-CONTRADICTION ROW. A 405 that lists the very method it just
      # refused tells the client to do again exactly what failed — #56 A1's rule
      # (a code inviting a retry that cannot succeed is a lie) reaching a header.
      case "$_mnorm" in
        *",${_mmeth},"*)
          echo "ALLOW-CONTRADICTS-STATUS: refused ${_mmeth} with 405 yet Allow lists ${_mmeth}" ;;
      esac
      # §9.1 makes HEAD support mandatory, and Hono really does answer HEAD from
      # a GET handler (measured: HEAD / -> 200). Advertising GET without HEAD
      # understates what the resource serves.
      case "$_mnorm" in
        *",GET,"*)
          case "$_mnorm" in
            *",HEAD,"*) ;;
            *) echo "ALLOW-OMITS-HEAD: lists GET but not HEAD, though the server answers HEAD and RFC 9110 §9.1 makes it mandatory" ;;
          esac ;;
      esac
      # Allow = #method, a comma-separated list of tokens. Reject a value that
      # is not that shape — e.g. a bare string, or a list joined with something
      # a parser will not split on.
      case "$_mal" in
        *[!A-Za-z0-9,\ -]*)
          echo "MALFORMED-ALLOW: '${_mal}' is not the '#method' comma-separated token list of RFC 9110 §10.2.1" ;;
      esac
      # EVERY TOKEN MUST BE AN ACTUAL METHOD. This row exists because of a real
      # bug in this cycle's first draft: it filtered `route.path.includes('*')`
      # to drop middleware, which is a test of the path string rather than of
      # method-agnosticism, so the first `app.use('/dashboard', mw)` anyone adds
      # (measured: registers as method ALL, path /dashboard, NO star) would have
      # emitted `Allow: ALL, GET, HEAD`. `ALL` is a well-formed token, so the
      # syntax check above passes it, every client parses it, nothing errors, and
      # the header is a lie. Only an is-it-really-a-method check catches that.
      for _mtok in $(printf '%s' "$_mal" | tr ',' ' '); do
        case "$_mtok" in
          GET|HEAD|POST|PUT|DELETE|PATCH|OPTIONS|TRACE|CONNECT) ;;
          *) echo "NOT-A-METHOD: Allow lists '${_mtok}', which is not an HTTP method — a framework's internal wildcard marker reaching the wire is the usual cause" ;;
        esac
      done

      # THE CROSS-INSTRUMENT ASSERTION (#59) — every clause above tests the
      # SHAPE of the header; this one tests its VALUE against what the source
      # declares. Nothing did that for two cycles, and the gap has a name:
      # UNDER-DISCLOSURE IS INVISIBLE TO EVERY CLAUSE ABOVE. Let the router
      # serve `Allow: GET, HEAD` for /register while src/index.ts registers GET
      # and POST, and the response is a 405, with exactly one Allow, non-empty,
      # syntactically a token list, every token a real method, no ALL, HEAD
      # present beside GET, and not listing the refused method. Seven clauses
      # pass. The header is still wrong, and the client is told a POST endpoint
      # does not exist.
      #
      # THE EXPECTATION MUST COME FROM THE SOURCE, NEVER FROM THE RESPONSE.
      # Deriving it from "$_mal" is the accident that would make this clause
      # unfalsifiable while looking identical in the transcript, so the value
      # arrives as an argument computed by derive_allow_map() from the route
      # pairs, and this function never sees src/index.ts.
      case "$_mwant" in
        # A fixture that is aiming at one of the shape clauses above and has no
        # source to derive from. Spelled explicitly rather than left blank, so
        # that "no expectation" and "expectation came back empty" cannot look
        # the same to a reader or to the code.
        '-') ;;
        # The empty case is NOT skipped, because "" = "" would compare two dead
        # inputs and pass (#41: index_parity=0 on two empty lists). If the
        # derivation produced nothing, that is a broken instrument, not a clean
        # route.
        '') echo "UNREADABLE-DERIVATION: no expected Allow was derived from src/index.ts for this path, so an equality test here would compare two empty strings and pass" ;;
        *)
          # Order and spacing are not semantic in a #method list, so normalise
          # both sides the same way and compare sets, not strings.
          _mgotset=$(printf '%s' "$_mal" | tr -d ' \r' | tr ',' '\n' | grep -v '^$' \
                     | sort -u | tr '\n' ',' | sed -e 's/,$//')
          _mwantset=$(printf '%s' "$_mwant" | tr -d ' \r' | tr ',' '\n' | grep -v '^$' \
                      | sort -u | tr '\n' ',' | sed -e 's/,$//')
          [ "$_mgotset" = "$_mwantset" ] || \
            echo "ALLOW-DISAGREES-WITH-SOURCE: the router served '${_mal}' but src/index.ts declares '${_mwant}' — one of the two instruments is wrong and until now neither could see the other"
          ;;
      esac
      ;;

    absent)
      # The control. If everything became a 405 this row is what notices.
      if [ "$_mst" != "404" ]; then
        echo "STATUS: got ${_mst} for ${_mmeth} on a path with no registered route; 404 is the true code (RFC 9110 §15.5.5, first disjunct)"
      fi
      [ "$_mac" -eq 0 ] || \
        echo "STRAY-ALLOW: Allow: ${_mal} on a path that has no resource to allow methods on"
      ;;

    *) echo "UNREADABLE: unknown expectation '${_mexp}'" ;;
  esac
  return 0
}

# ---- cache semantics (#58) ---------------------------------------------------
# RFC 9111 §4.2.2 lets a cache invent a freshness lifetime for any response that
# carries no explicit expiration and whose status is heuristically cacheable
# (RFC 9110 line 6953 for 200, line 7597 for 404). Four of our responses are
# selected by "now" or by one caller's key, and inherited that default.
#
# `heuristic` is not a weaker expectation than `no-store`, it is the OPPOSITE
# one, and it is the reason this section can fail. Without it, a change that
# no-stored the entire surface would turn every other row green. That failure
# mode is not hypothetical for this fix: `no-store` is the kind of directive
# that looks harmless everywhere, so the cheapest wrong implementation is one
# global header, and the ONLY row that would notice is one asserting a response
# must remain storable.
# Emit "METHOD /path", one per line, sorted, for every Hono route registration
# in a source file. Line comments are stripped FIRST — that is the whole fix, and
# without it this function has the same defect as the grep it replaces.
# `app.use` is deliberately not matched: it registers method ALL, which is
# middleware and not part of the method surface (#57 A3 — and note that the
# wrong way to exclude it is by looking for a `*` in the path, since
# `app.use('/dashboard', mw)` has no star).
route_pairs() { # source-file
  sed -E 's@^[[:space:]]*//.*@@' "$1" 2>/dev/null \
    | grep -oE "app\.(get|post|put|delete|all)\([^,)]+" \
    | sed -E "s/^app\.//; s/\(/ /; s/[\`'\"]//g" \
    | sed -E "s@\\\$\{POSTMORTEM_PATH\}@/postmortem/self-certifying-ci-gate@" \
    | sed -E "s@^([a-z]+) POSTMORTEM_PATH\$@\1 /postmortem/self-certifying-ci-gate@" \
    | awk 'NF==2 {print toupper($1), $2}' \
    | sort
}

# Turn a route-pair list into the Allow header each path OUGHT to serve:
# "<path><TAB><Allow value>", one per line, sorted by path.
#
# THIS IS THE ONLY DERIVATION IN THIS FILE, and that is the point of extracting
# it (#59). It used to live inline inside ROUTE SURFACE's print loop, where its
# comment described it as decorative: "Printed, not asserted: the assertion that
# matters is the live one in METHOD SEMANTICS." That was false in a way neither
# section could see. METHOD SEMANTICS never compared the live Allow to this
# value — it only checked the header's SHAPE — so the derived surface was
# printed and never asserted, while the live surface was asserted and never
# compared. Two instruments about one fact, both green, never confronted with
# each other (#51, aimed at the instruments instead of at the pages).
#
# HEAD is synthesized here rather than read from the source because it is never
# in `app.routes` at all: Hono rewrites a HEAD request into a GET at dispatch
# (`node_modules/hono/dist/hono-base.js:273`). So the source of truth for Allow
# is the registration list PLUS that one rule, and this function is where the
# rule lives. RFC 9110 §9.1 (line 3794) makes HEAD mandatory regardless.
# THE HAND-MAINTAINED LITERAL — the third point that makes the other two able to
# disagree (#59, on Munger's amendment). It is deliberately typed out and
# deliberately not generated.
#
# The first draft of this cycle derived METHOD SEMANTICS' expected Allow from
# route_pairs(src/index.ts) — the same call ROUTE SURFACE compares against this
# literal. That is not circular against the response, which is the trap I went
# looking for; it is circular against ITSELF. A source edit moves the derived
# expectation and the live router together, in step, so the new live assertion
# stays green through any route change and only the literal diff goes red. One
# edge, doing the work of two.
#
# Anchored here instead, the three points are: this literal, the source, and the
# router. ROUTE SURFACE tests literal↔source. METHOD SEMANTICS tests literal↔live.
# Either edge can fail without the other, which is the whole reason to have two
# sections. Changing a route means changing this list in the same commit — on
# purpose, by a person, which is the point (#57 A2 is about hand-maintained
# EXCEPTION tables inside a truthfulness rule; this is a hand-maintained
# EXPECTATION, and an expectation nobody has to type is one nobody has to mean).
expected_route_pairs() {
  cat <<'ROUTES'
GET /
GET /brand.png
GET /dashboard
GET /demo.png
GET /favicon.ico
GET /favicon.svg
GET /health
GET /interest
GET /og
GET /postmortem/hits
GET /postmortem/self-certifying-ci-gate
GET /postmortem/self-certifying-ci-gate/
GET /register
GET /robots.txt
GET /sitemap.xml
POST /admin/upgrade
POST /interest
POST /register
ROUTES
}

derive_allow_map() { # route-pairs-file
  awk '
    NF == 2 {
      p = $2; m = toupper($1)
      if (index(" " seen[p] " ", " " m " ") == 0) seen[p] = seen[p] " " m
    }
    END {
      for (p in seen) {
        if (index(" " seen[p] " ", " GET ") > 0 && index(" " seen[p] " ", " HEAD ") == 0)
          seen[p] = seen[p] " HEAD"
        # A single space as the separator is awks special case: split on runs of
        # whitespace and drop leading/trailing, so the leading space above is safe.
        n = split(seen[p], a, " ")
        for (i = 2; i <= n; i++) { v = a[i]; j = i - 1
          while (j > 0 && a[j] > v) { a[j+1] = a[j]; j-- }
          a[j+1] = v }
        out = ""
        for (i = 1; i <= n; i++) out = (i == 1 ? a[i] : out ", " a[i])
        printf "%s\t%s\n", p, out
      }
    }' "$1" 2>/dev/null | sort
}

cache_semantics_defects() { # headers-file  expectation(no-store|heuristic)
  _cf="$1"; _cexp="$2"
  [ -s "$_cf" ] || { echo "UNREADABLE: no response headers captured"; return 0; }
  _cst=$(grep -i '^HTTP/' "$_cf" 2>/dev/null | tail -1 | tr -d '\r' | awk '{print $2}')
  [ -n "$_cst" ] || { echo "UNREADABLE: no status line in captured headers"; return 0; }

  # Count on its own line then head -1 (#54: `grep -c` prints 0 and EXITS 1).
  _ccc=$(grep -ci '^Cache-Control:' "$_cf" 2>/dev/null | head -1); _ccc=${_ccc:-0}
  _ccv=$(grep -i '^Cache-Control:' "$_cf" 2>/dev/null | head -1 | tr -d '\r' \
         | sed -e 's/^[Cc]ache-[Cc]ontrol:[[:space:]]*//' -e 's/[[:space:]]*$//')
  # Comma-fenced and space-free, so membership is exact rather than
  # substring-lucky: a bare *no-store* also matches "no-store-please", and
  # *private* matches nothing useful inside "no-transform".
  _cnorm=",$(printf '%s' "$_ccv" | tr 'A-Z' 'a-z' | tr -d ' '),"

  case "$_cexp" in
    no-store)
      if [ "$_ccc" -eq 0 ]; then
        echo "HEURISTICALLY-CACHEABLE: ${_cst} with no Cache-Control — RFC 9111 §4.2.2 lets a cache assign its own freshness lifetime, and this representation is selected by the current time or by one caller's key"
        return 0
      fi
      [ "$_ccc" -eq 1 ] || \
        echo "DUPLICATE-CACHE-CONTROL: ${_ccc} Cache-Control headers; send one list"
      case "$_cnorm" in
        *",no-store,"*) _chas=1 ;;
        *) _chas=0
           echo "WRONG-DIRECTIVE: Cache-Control is '${_ccv}' with no no-store — RFC 9111 §5.2.2.5 is the directive that binds both private and shared caches" ;;
      esac
      # THE ROWS BELOW ARE GUARDED ON no-store BEING PRESENT, and the self-test
      # is why. Ungated, `public, max-age=3600` reported three defects: the
      # correct WRONG-DIRECTIVE, plus "'public' sits beside no-store" and
      # "'max-age=3600' sits beside no-store" — on a response with no no-store
      # in it. Both messages were false statements about the header they were
      # reading, and each was individually plausible enough to survive a skim.
      # A checker that says a true thing about the wrong header is the same
      # defect class it is here to find (#57 A3: a test must test the property
      # it names).
      [ "$_chas" -eq 1 ] || return 0
      # A stored-lifetime directive beside no-store is self-contradictory. §5.2.2.5
      # wins, so nothing breaks — which is exactly why nothing would report it.
      for _ctok in $(printf '%s' "$_cnorm" | tr ',' ' '); do
        case "$_ctok" in
          max-age=*|s-maxage=*|public)
            echo "CONTRADICTORY-DIRECTIVE: '${_ctok}' sits beside no-store; one says store it for a while and the other says never store it" ;;
          private)
            # #56 A3, aimed at this cycle's own addition. no-store already binds
            # both cache classes, so `private` here is legal, plausible, and
            # does no work — the same shape as a Vary on a no-store response.
            echo "INERT-DIRECTIVE: 'private' beside no-store adds nothing — §5.2.2.5 already binds both private and shared caches" ;;
        esac
      done
      # A validator exists to make a revalidation cheap. There is nothing stored
      # to revalidate, so one here is inert in the same way `private` is.
      for _cvh in ETag Last-Modified Expires; do
        _cvn=$(grep -ci "^${_cvh}:" "$_cf" 2>/dev/null | head -1); _cvn=${_cvn:-0}
        [ "$_cvn" -eq 0 ] || \
          echo "INERT-VALIDATOR: ${_cvh} on a no-store response — nothing may be stored, so there is nothing to revalidate"
      done
      ;;
    heuristic)
      # THE OVER-FIRE CONTROL. Asserts a response must remain storable.
      case "$_cnorm" in
        *",no-store,"*)
          echo "OVER-FIRED: no-store on a response with no per-caller or time-dependent content — the fix was applied wholesale instead of per call site" ;;
      esac
      ;;
    *) echo "UNREADABLE: unknown expectation '${_cexp}'" ;;
  esac
  return 0
}

# ------------------------------------------------------------------- URL helpers
# Normalize a raw attribute value to an absolute URL on BASE, or emit nothing if
# the reference is out of scope (external host, anchor, mailto:, data:, ...).
# Emits: "<absolute-url>" on stdout, or "" for skip.
normalize_url() {
  raw="$1"
  # HTML entity that shows up constantly inside query strings
  raw=$(printf '%s' "$raw" | sed -e 's/&amp;/\&/g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  [ -n "$raw" ] || { echo ""; return; }
  case "$raw" in
    '#'*|'mailto:'*|'tel:'*|'data:'*|'javascript:'*|'blob:'*) echo ""; return ;;
  esac
  # drop fragment: "/#how-it-works" -> "/", "/x#y" -> "/x"
  raw=$(printf '%s' "$raw" | sed -e 's/#.*$//')
  [ -n "$raw" ] || { echo ""; return; }
  case "$raw" in
    //*)
      host=$(printf '%s' "$raw" | sed -e 's#^//##' -e 's#/.*$##')
      if [ "$host" = "$BASE_HOST" ]; then
        echo "https:$raw"
      else echo ""; fi
      ;;
    http://*|https://*)
      host=$(printf '%s' "$raw" | sed -e 's#^[a-z]*://##' -e 's#/.*$##')
      if [ "$host" = "$BASE_HOST" ]; then echo "$raw"; else echo ""; fi
      ;;
    /*) echo "${BASE}${raw}" ;;
    *)  echo "${BASE}/${raw}" ;;   # relative: pages here are all at root depth
  esac
}

# The other half of normalize_url: emit the absolute URL when a reference points
# OFF this host, and nothing otherwise. Together the two are total — every raw
# reference is local, external, or genuinely not an address — which is what lets
# scan_page stop reporting "external" and "anchor" as the same word.
external_url() {
  raw=$(printf '%s' "$1" | sed -e 's/&amp;/\&/g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  [ -n "$raw" ] || { echo ""; return; }
  case "$raw" in
    '#'*|'mailto:'*|'tel:'*|'data:'*|'javascript:'*|'blob:'*) echo ""; return ;;
  esac
  raw=$(printf '%s' "$raw" | sed -e 's/#.*$//')
  [ -n "$raw" ] || { echo ""; return; }
  case "$raw" in
    //*)
      host=$(printf '%s' "$raw" | sed -e 's#^//##' -e 's#/.*$##')
      if [ "$host" = "$BASE_HOST" ]; then echo ""; else echo "https:$raw"; fi
      ;;
    http://*|https://*)
      host=$(printf '%s' "$raw" | sed -e 's#^[a-z]*://##' -e 's#/.*$##')
      if [ "$host" = "$BASE_HOST" ]; then echo ""; else echo "$raw"; fi
      ;;
    *) echo "" ;;
  esac
}

looks_like_image_path() {
  printf '%s' "$1" | sed -e 's/?.*$//' \
    | grep -qiE '\.(png|jpe?g|gif|svg|webp|avif|ico|bmp|apng)$'
}

# ------------------------------------------------------------- rendered-text check
# Strip <style>/<script> bodies and all tags, leaving roughly what a human READS.
# This exists because markup and reading are different things: the nav wordmark was
# `Snap<span>OG</span>`, so `grep SnapOG` over the source or the served HTML returned
# nothing for four cycles while every page displayed "SnapOG" — the name of a live
# competitor — at the top left. Assertions about what a page SAYS have to run against
# the text, not the tags.
render_text() {
  tr '\n\r\t' '   ' < "$1" \
  | awk '{
      s = $0; out = "";
      # Drop <style>...</style> and <script>...</script> bodies, whichever comes
      # first, repeatedly. Done with index() rather than a regex because BSD sed
      # has no non-greedy match and a greedy .* eats the whole document — which is
      # precisely what the first version of this function did, and why the page
      # checks would all have passed on an empty string.
      while (1) {
        i = index(tolower(s), "<style"); j = index(tolower(s), "<script");
        c = index(s, "<!--");
        # HTML comments must go too. A regex cannot do it: gsub(/<[^>]*>/) stops at
        # the first ">" inside the comment, so a comment mentioning any tag leaks its
        # prose into "rendered text" — which happened on the very commit that added
        # this function, and would make the brand assertion fire on a code comment.
        k = 0; tag = "";
        if (i > 0)                     { k = i; tag = "</style>" }
        if (j > 0 && (k == 0 || j < k)) { k = j; tag = "</script>" }
        if (c > 0 && (k == 0 || c < k)) { k = c; tag = "-->" }
        if (k == 0) break;
        out = out substr(s, 1, k - 1);
        rest = substr(s, k);
        e = index(tolower(rest), tag);
        if (e == 0) { s = ""; break }        # unterminated: drop the remainder
        s = substr(rest, e + length(tag));
      }
      out = out s;
      # Tags are removed with NO separator. That is the whole point: an inline
      # <span> adds no visual space, so "Snap<span>OG</span>" reads as one word
      # "SnapOG" and must be found as one word. Joining with a space instead makes
      # this check miss exactly the defect it was written for (verified: it did).
      # The cost is that adjacent block text can fuse; for substring assertions
      # that errs toward a false positive, which is loud and cheap to inspect,
      # rather than a false negative, which is what we have been shipping.
      gsub(/<[^>]*>/, "", out);
      print out;
    }'
}

# Strings that must never appear in rendered page text. Case-SENSITIVE on purpose:
# the worker hostname is legitimately `snapog.aoadmin.workers.dev` and renaming it
# would break the only public URL we have, so lowercase `snapog` is expected and
# fine. It is the capitalised brand form that must be gone.
FORBIDDEN_TEXT="SnapOG"

# ------------------------------------------------------- doc (markdown) helpers
# A doc URL that is deliberately not a real address: a shell variable the reader
# substitutes, an angle-bracket placeholder, a localhost dev address. These must be
# SKIPPED — but reported, not swallowed. A gate that silently drops what it cannot
# judge teaches you to trust a number that was never measured.
is_placeholder() {
  case "$1" in
    *'$'*|*'<'*|*'>'*|*'YOUR_'*|*'your-worker'*|*'{'*|*'}'*) return 0 ;;
    *'//127.0.0.1'*|*'//localhost'*|*'//0.0.0.0'*)           return 0 ;;
  esac
  return 1
}

# Unlike normalize_url (site scan), this KEEPS external hosts: in a doc, the
# external link is the one that rots without anyone noticing.
normalize_doc_url() {
  raw=$(printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/[.,;:]*$//')
  [ -n "$raw" ] || { echo ""; return; }
  case "$raw" in
    '#'*|'mailto:'*|'tel:'*|'data:'*) echo ""; return ;;
    http://*|https://*) echo "$raw"; return ;;
    *) echo ""; return ;;   # relative repo paths: rendered by GitHub, not fetchable here
  esac
}

# ------------------------------------------------------------------- the one probe
# probe_url <kind> <absolute-url>
# kind: image | asset | link   (image => content-type MUST be image/*)
# sets: R_STATUS R_CT R_VERDICT R_REASON
probe_url() {
  _kind="$1"; _url="$2"
  R_REASON=""
  _out=$(curl -sS -L --compressed \
              --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
              -A "$UA" \
              -o /dev/null \
              -w '%{http_code}|%{content_type}|%{size_download}' \
              "$_url" 2>"$WORKDIR/curl.err")
  _rc=$?
  if [ $_rc -ne 0 ] || [ -z "$_out" ]; then
    R_STATUS="ERR"; R_CT="-"; R_VERDICT="FAIL"
    R_REASON="curl exit $_rc: $(tr -d '\n' < "$WORKDIR/curl.err" | cut -c1-90)"
    return 1
  fi
  R_STATUS=$(printf '%s' "$_out" | awk -F'|' '{print $1}')
  R_CT=$(printf '%s'   "$_out" | awk -F'|' '{print $2}' | sed -e 's/;.*$//' -e 's/[[:space:]]//g')
  _size=$(printf '%s'  "$_out" | awk -F'|' '{print $3}')
  [ -n "$R_CT" ] || R_CT="-"

  case "$R_STATUS" in
    4*|5*) R_VERDICT="FAIL"; R_REASON="HTTP $R_STATUS"; return 1 ;;
    000)   R_VERDICT="FAIL"; R_REASON="no response";    return 1 ;;
  esac

  if [ "$_kind" = "image" ]; then
    case "$R_CT" in
      image/*) : ;;
      *) R_VERDICT="FAIL"
         R_REASON="expected image/*, got '${R_CT}' (browser renders a broken-image icon)"
         return 1 ;;
    esac
    # Guards against "200 OK, content-type: image/png, empty body". Floor is 32B:
    # the smallest possible valid PNG is ~67B, so a legitimate 1x1 pixel still passes.
    if [ "${_size:-0}" -lt 32 ] 2>/dev/null; then
      R_VERDICT="FAIL"; R_REASON="content-type says image but body is only ${_size}B"
      return 1
    fi
  fi
  R_VERDICT="PASS"
  return 0
}

# check_and_report <page-label> <kind> <url>
check_and_report() {
  TOTAL=$((TOTAL + 1))
  if probe_url "$2" "$3"; then
    PASSED=$((PASSED + 1))
    row "$1" "$2" "PASS" "$R_STATUS" "$R_CT" "$3"
  else
    FAILED=$((FAILED + 1))
    row "$1" "$2" "FAIL" "$R_STATUS" "$R_CT" "$3" "$R_REASON"
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$R_REASON" >> "$FAILLOG"
  fi
}

# ------------------------------------------------------- the advisory (external) class
# Whose fault is it? That is the whole distinction, and it is a pure function of
# the status so the self-test can assert it without touching the network or the
# counters. 4xx: the thing we cited is gone and OUR page is now wrong. 5xx /
# timeout / DNS: their server is having a day — not a fact about us, and it must
# never read like one, or people learn to scroll past this whole section.
ext_severity() {
  case "$1" in
    5*|ERR|000) echo "NOTE" ;;
    # 429/408 are 4xx by number and NOTE by meaning. Throttling and a server-side
    # request timeout say "ask again later", not "the thing you cited is gone" —
    # the exact distinction this function's own header draws. Left in the WARN
    # catch-all, they made the evidence path NON-DETERMINISTIC and flaky toward
    # FAIL: cycle #25's first gate run went red on a 429 from a host that served
    # the identical URL 200 minutes later. That direction of flake is the
    # dangerous one. A gate that fails for reasons the repo cannot fix is a gate
    # someone switches off, and the switch was sitting right there in
    # --external-lenient, which would have disarmed the real WARN check that #24
    # D3 deliberately armed. Fixing the classifier keeps the arming intact.
    429|408)    echo "NOTE" ;;
    *)          echo "WARN" ;;
  esac
}

# check_external <label> <kind> <url>
# Fetches an off-host reference and files the result under ADVISORY. Cannot change
# the exit code unless --external-strict, and even then only on WARN.
check_external() {
  EXT_TOTAL=$((EXT_TOTAL + 1))
  if probe_url "$2" "$3"; then
    EXT_OK=$((EXT_OK + 1))
    row "$1" "ext" "OK" "$R_STATUS" "$R_CT" "$3"
    return 0
  fi
  _sev=$(ext_severity "$R_STATUS")
  if [ "$_sev" = "NOTE" ]; then EXT_NOTE=$((EXT_NOTE + 1)); else EXT_WARN=$((EXT_WARN + 1)); fi
  row "$1" "ext" "$_sev" "$R_STATUS" "$R_CT" "$3" "$R_REASON"
  printf '%s\t%s\t%s\t%s\t%s\n' "$_sev" "$1" "$2" "$3" "$R_REASON" >> "$EXTLOG"
  return 1
}

# check_relative <label> <doc-path> <raw-target>
# A repo-relative markdown target, resolved on disk. GitHub resolves a leading "/"
# against the repository root and everything else against the file's directory;
# so do we. Sets no network traffic and has exactly one possible excuse for
# failing — the file is not there — which is why this one is allowed to be hard.
resolve_rel() { # <doc-path> <raw-target> -> absolute path on disk, or "" for anchor-only
  _rr_p=$(printf '%s' "$2" | sed -e 's/#.*$//' -e 's/?.*$//')
  [ -n "$_rr_p" ] || { echo ""; return; }
  case "$_rr_p" in
    /*) echo "${REPO_ROOT}${_rr_p}" ;;
    *)  echo "$(dirname "$1")/${_rr_p}" ;;
  esac
}

# is_published <abs-path> — is this path something a STRANGER can reach?
#
# The first version of this check used `[ -e ]`, and `[ -e ]` was the wrong
# filesystem. This repo's .gitignore ignores docs/*/* and the auto-loop restores
# that on every cycle; the whole `git add -f` ritual in CLAUDE.md exists because
# new files get silently dropped from the index. So a gitignored, untracked file
# is present on this laptop and 404s on GitHub — and `[ -e ]` would have called
# it PASS. A link checker whose oracle is the author's working tree confidently
# green-lights exactly the dead-link class this repo manufactures.
#
# `git ls-files --error-unmatch` is also case-EXACT even with core.ignorecase=true
# (verified: Readme.md -> not tracked, README.md -> tracked), so this fixes the
# macOS case trap in the same move: [x](./Readme.md) opens fine here and 404s for
# everyone else.
is_published() {
  git -C "$REPO_ROOT" ls-files --error-unmatch -- "$1" >/dev/null 2>&1
}

check_relative() {
  TOTAL=$((TOTAL + 1))
  _rl_t=$(resolve_rel "$2" "$3")
  if [ -z "$_rl_t" ]; then
    TOTAL=$((TOTAL - 1)); SKIPPED=$((SKIPPED + 1)); return 0
  fi
  if is_published "$_rl_t"; then
    PASSED=$((PASSED + 1))
    row "$1" "rel" "PASS" "-" "git-tracked" "$3"
  elif [ -e "$_rl_t" ]; then
    FAILED=$((FAILED + 1))
    row "$1" "rel" "FAIL" "-" "untracked" "$3" "exists here but is NOT tracked by git — a stranger gets 404"
    printf '%s\t%s\t%s\t%s\n' "$1" "rel" "$3" \
      "resolves to ${_rl_t}, which exists locally but is not in the git index (gitignored, untracked, or wrong case)" >> "$FAILLOG"
  else
    FAILED=$((FAILED + 1))
    row "$1" "rel" "FAIL" "-" "no-such-file" "$3" "resolves to ${_rl_t} — not on disk"
    printf '%s\t%s\t%s\t%s\n' "$1" "rel" "$3" "relative link resolves to ${_rl_t}, which does not exist" >> "$FAILLOG"
  fi
}

# count_hint <label> <raw-url> — a connection hint, deliberately NOT fetched.
count_hint() {
  HINTS=$((HINTS + 1))
  row "$1" "hint" "n/a" "-" "not-fetched" "$2" "rel=preconnect/dns-prefetch: an origin, never GETted"
}

# ------------------------------------------------------------------ the self-test
# Known-bad cases MUST come back FAIL; the known-good case MUST come back PASS.
# The good case matters as much as the bad ones: an always-red gate is just as
# worthless as an always-green one, it is only worthless later.
self_test() {
  echo "SELF-TEST — proving this checker can produce a red result"
  hr
  st_fail=0

  # 1. the exact historical defect: an unauthenticated /og reference
  probe_url image "${BASE}/og?title=selftest-injected-bad-asset"
  if [ "$R_VERDICT" = "FAIL" ]; then
    row "selftest" "image" "OK" "$R_STATUS" "$R_CT" "/og (no api key) -> correctly FAILed"
  else
    row "selftest" "image" "BAD" "$R_STATUS" "$R_CT" "/og (no api key) -> checker said $R_VERDICT, expected FAIL"
    st_fail=1
  fi

  # 2. a path that has never existed
  probe_url image "${BASE}/definitely-missing-asset.png"
  if [ "$R_VERDICT" = "FAIL" ]; then
    row "selftest" "image" "OK" "$R_STATUS" "$R_CT" "/definitely-missing-asset.png -> correctly FAILed"
  else
    row "selftest" "image" "BAD" "$R_STATUS" "$R_CT" "/definitely-missing-asset.png -> checker said $R_VERDICT, expected FAIL"
    st_fail=1
  fi

  # 3. HTTP 200 but the wrong content-type — proves the image/* assertion is not
  #    merely a restatement of the status check.
  probe_url image "${BASE}/register"
  if [ "$R_VERDICT" = "FAIL" ]; then
    row "selftest" "image" "OK" "$R_STATUS" "$R_CT" "200-but-text/html as image -> correctly FAILed"
  else
    row "selftest" "image" "BAD" "$R_STATUS" "$R_CT" "200 text/html treated as image -> checker said $R_VERDICT, expected FAIL"
    st_fail=1
  fi

  # 4. control: a URL that genuinely works must PASS
  probe_url link "${BASE}/"
  if [ "$R_VERDICT" = "PASS" ]; then
    row "selftest" "link" "OK" "$R_STATUS" "$R_CT" "/ -> correctly PASSed (checker is not always-red)"
  else
    row "selftest" "link" "BAD" "$R_STATUS" "$R_CT" "/ -> checker said $R_VERDICT, expected PASS ($R_REASON)"
    st_fail=1
  fi

  # ---- rendered-text self-test --------------------------------------------
  # 4b. The exact markup that defeated four rename audits, plus a <style> block
  #     to prove CSS is not mistaken for prose. The negative case matters just as
  #     much: if render_text returned nothing, every page would "pass" forever.
  # ---- canonical-vs-serving-URL (added #51; the class that #50 shipped live) ----
  # Four fixtures, because this check has two ways to be useless: always-green
  # (never catches the foreign canonical) and always-red (flags noindex pages and
  # the -L redirect that legitimately moved the URL).
  st_can="$WORKDIR/selftest-canonical.html"
  printf '%s' '<html><head><link rel="canonical" href="https://example.org/register" /></head><body>x</body></html>' > "$st_can"
  if canonical_mismatch "$st_can" "https://example.org/dashboard"; then
    row "selftest" "head" "OK" "-" "canonical" "foreign canonical -> correctly detected (the #50 defect)"
  else
    row "selftest" "head" "BAD" "-" "canonical" "foreign canonical NOT detected — this check is decorative"
    st_fail=1
  fi
  printf '%s' '<html><head><link rel="canonical" href="https://example.org/register" /></head><body>x</body></html>' > "$st_can"
  if canonical_mismatch "$st_can" "https://example.org/register"; then
    row "selftest" "head" "BAD" "-" "canonical" "agreeing canonical flagged — check is always-red"
    st_fail=1
  else
    row "selftest" "head" "OK" "-" "canonical" "agreeing canonical -> correctly passed (not always-red)"
  fi
  printf '%s' '<html><head><meta name="robots" content="noindex, nofollow" /></head><body>x</body></html>' > "$st_can"
  if canonical_mismatch "$st_can" "https://example.org/dashboard"; then
    row "selftest" "head" "BAD" "-" "canonical" "absent canonical flagged — noindex pages would be permanently red"
    st_fail=1
  else
    row "selftest" "head" "OK" "-" "canonical" "absent canonical -> correctly NOT a defect"
  fi
  printf '%s' '<html><head><link rel="canonical" href="https://example.org/x/" /></head><body>x</body></html>' > "$st_can"
  if canonical_mismatch "$st_can" "https://example.org/x"; then
    row "selftest" "head" "BAD" "-" "canonical" "trailing-slash-only difference flagged as a mismatch"
    st_fail=1
  else
    row "selftest" "head" "OK" "-" "canonical" "trailing slash tolerated -> not a mismatch"
  fi

  # ---- noindex reachability (added #53; the class this gate shipped for 3 cycles) ----
  # Both halves matter. Always-green would never have caught #53's defect; always-red
  # would flag `Disallow: /admin/`, which is correct precisely because nothing is there.
  st_rb="$WORKDIR/selftest-robots.txt"
  st_hd="$WORKDIR/selftest-headers.txt"
  st_bd="$WORKDIR/selftest-noindex.html"
  printf '%s\n' 'User-agent: *' 'Allow: /' 'Disallow: /dashboard' 'Disallow: /admin/' > "$st_rb"
  if robots_disallows "$st_rb" "/dashboard"; then
    row "selftest" "robots" "OK" "-" "noindex-reach" "exact Disallow -> correctly detected (the #53 defect)"
  else
    row "selftest" "robots" "BAD" "-" "noindex-reach" "exact Disallow NOT detected — this check is decorative"
    st_fail=1
  fi
  if robots_disallows "$st_rb" "/admin/upgrade"; then
    row "selftest" "robots" "OK" "-" "noindex-reach" "prefix Disallow -> correctly detected"
  else
    row "selftest" "robots" "BAD" "-" "noindex-reach" "prefix rule did not match a path beneath it"
    st_fail=1
  fi
  if robots_disallows "$st_rb" "/register"; then
    row "selftest" "robots" "BAD" "-" "noindex-reach" "unblocked path flagged — check is always-red"
    st_fail=1
  else
    row "selftest" "robots" "OK" "-" "noindex-reach" "unblocked path -> correctly passed (not always-red)"
  fi
  # RFC 9309: an empty Disallow value allows everything. Read as a blanket block it
  # would make every page on the site red forever.
  printf '%s\n' 'User-agent: *' 'Disallow:' > "$st_rb"
  if robots_disallows "$st_rb" "/anything"; then
    row "selftest" "robots" "BAD" "-" "noindex-reach" "empty 'Disallow:' read as blocking — RFC 9309 says it allows all"
    st_fail=1
  else
    row "selftest" "robots" "OK" "-" "noindex-reach" "empty 'Disallow:' -> correctly not a block"
  fi
  # And the directive reader: header-only is the JSON case, meta-only the HTML case.
  printf '%s\n' 'HTTP/2 200' 'x-robots-tag: noindex, nofollow' > "$st_hd"
  : > "$st_bd"
  if response_says_noindex "$st_hd" "$st_bd"; then
    row "selftest" "robots" "OK" "-" "noindex-reach" "X-Robots-Tag with empty body -> detected (the JSON case)"
  else
    row "selftest" "robots" "BAD" "-" "noindex-reach" "header-only noindex missed — JSON endpoints unverifiable"
    st_fail=1
  fi
  printf '%s\n' 'HTTP/2 200' 'content-type: text/html' > "$st_hd"
  printf '%s' '<html><head><meta name="robots"
     content="noindex, nofollow" /></head><body>x</body></html>' > "$st_bd"
  if response_says_noindex "$st_hd" "$st_bd"; then
    row "selftest" "robots" "OK" "-" "noindex-reach" "meta noindex across a newline -> detected"
  else
    row "selftest" "robots" "BAD" "-" "noindex-reach" "meta noindex missed when the tag wraps a line"
    st_fail=1
  fi
  printf '%s' '<html><head><meta name="robots" content="index, follow" /></head><body>x</body></html>' > "$st_bd"
  if response_says_noindex "$st_hd" "$st_bd"; then
    row "selftest" "robots" "BAD" "-" "noindex-reach" "'index, follow' read as noindex — check is always-red"
    st_fail=1
  else
    row "selftest" "robots" "OK" "-" "noindex-reach" "'index, follow' -> correctly not noindex"
  fi

  st_html="$WORKDIR/selftest-brand.html"
  printf '%s' '<html><head><style>.x{content:"OGForge"}</style></head><body><nav><a class="nav-logo" href="/">Snap<span>OG</span></a></nav><p>hello</p></body></html>' > "$st_html"
  if render_text "$st_html" | grep -q 'SnapOG'; then
    row "selftest" "text" "OK" "-" "rendered-text" "split-element 'Snap<span>OG</span>' -> correctly detected"
  else
    row "selftest" "text" "BAD" "-" "rendered-text" "split-element wordmark NOT detected — this check is decorative"
    st_fail=1
  fi
  if render_text "$st_html" | grep -q 'hello'; then
    row "selftest" "text" "OK" "-" "rendered-text" "body prose survives extraction (not always-empty)"
  else
    row "selftest" "text" "BAD" "-" "rendered-text" "render_text returned no prose — every page would pass vacuously"
    st_fail=1
  fi
  if render_text "$st_html" | grep -q 'content:'; then
    row "selftest" "text" "BAD" "-" "rendered-text" "CSS leaked into rendered text — will produce false positives"
    st_fail=1
  else
    row "selftest" "text" "OK" "-" "rendered-text" "<style> body excluded from rendered text"
  fi

  # ---- doc-scan self-test -------------------------------------------------
  # 5. End-to-end on a fixture, because a broken EXTRACTOR looks exactly like a
  #    clean site. The fixture reproduces the Cycle #20 defect: a markdown link
  #    to a GitHub repo path that does not exist. Extraction and probing are
  #    asserted together — passing only one of them is how a gate goes quietly
  #    blind on the very reference it was built to watch.
  st_md="$WORKDIR/selftest-fixture.md"
  {
    printf '# fixture\n\n'
    printf 'A credit to a repo that does not exist: '
    printf '[workers-og](https://github.com/oavcy/ogforge-selftest-404-9f3a1c)\n\n'
    printf 'A placeholder a reader substitutes: https://<your-worker>.workers.dev/og\n\n'
    printf '![a card](%s/definitely-missing-asset.png)\n\n' "$BASE"
    printf 'A relative link that resolves: [self](./selftest-fixture.md)\n\n'
    printf 'A relative link that does not: [gone](./definitely-missing-doc-9f3a1c.md)\n\n'
    printf 'An in-page anchor, which is not a file: [jump](#self-hosting)\n'
  } > "$st_md"

  st_bad_link="https://github.com/oavcy/ogforge-selftest-404-9f3a1c"
  if extract_md_refs "$st_md" | grep -q "$st_bad_link"; then
    row "selftest" "doc" "OK" "-" "extract" "markdown link target -> extracted"
  else
    row "selftest" "doc" "BAD" "-" "extract" "markdown link target NOT extracted — doc scan is blind"
    st_fail=1
  fi

  probe_url link "$st_bad_link"
  if [ "$R_VERDICT" = "FAIL" ]; then
    row "selftest" "doc" "OK" "$R_STATUS" "$R_CT" "nonexistent GitHub repo -> correctly FAILed"
  else
    row "selftest" "doc" "BAD" "$R_STATUS" "$R_CT" "nonexistent repo -> checker said $R_VERDICT, expected FAIL"
    st_fail=1
  fi

  # 6. A missing image referenced with markdown ![]() syntax must be extracted
  #    AS AN IMAGE, not merely as a link.
  if extract_md_refs "$st_md" | grep -q "^image$(printf '\t')${BASE}/definitely-missing-asset.png$"; then
    row "selftest" "doc" "OK" "-" "extract" "![](...) -> classified image, not link"
  else
    row "selftest" "doc" "BAD" "-" "extract" "![](...) not classified as image — content-type check would be dropped"
    st_fail=1
  fi

  # 7. The placeholder rule must skip what is not an address AND must not skip
  #    what is. A gate that skips everything is green for the same reason a
  #    healthy one is, and you cannot tell them apart from the summary line.
  if is_placeholder 'https://<your-worker>.workers.dev/og'; then
    row "selftest" "doc" "OK" "-" "placeholder" "<your-worker> -> correctly skipped"
  else
    row "selftest" "doc" "BAD" "-" "placeholder" "<your-worker> not skipped — gate will be permanently red"
    st_fail=1
  fi
  if is_placeholder 'https://github.com/kvnang/workers-og'; then
    row "selftest" "doc" "BAD" "-" "placeholder" "a real URL was classified placeholder — gate is silently blind"
    st_fail=1
  else
    row "selftest" "doc" "OK" "-" "placeholder" "real URL -> correctly NOT skipped"
  fi

  # 8. Reference SHAPES the extractor was blind to until Cycle #22: single-quoted
  #    attributes and CSS url(). Listed as "not yet covered" in consensus for
  #    several cycles, which is a strictly worse state than not knowing — the gate
  #    was reporting 34/34 while unable to see two legal ways to reference an asset.
  #    Each shape gets a positive assertion AND the fixture carries two negative
  #    controls, because an extractor that finds nothing is indistinguishable from
  #    a clean page in the summary line.
  st_sq=$(printf '\047')
  st_tab=$(printf '\t')
  st_bt=$(printf '\140')
  st_shapes="$WORKDIR/selftest-shapes.html"
  {
    printf '%s' '<html><head><style>.hero{background:url("/definitely-missing-bg.png") no-repeat}'
    printf '%s' '@font-face{src:url(/definitely-missing-font.woff2)}</style></head><body>'
    printf 'a <img src=%s/definitely-missing-asset.png%s alt=%sx%s>' "$st_sq" "$st_sq" "$st_sq" "$st_sq"
    printf 'b <div style="background-image:url(%s/definitely-missing-inline.png%s)"></div>' "$st_sq" "$st_sq"
    printf 'c <p>it%ss fine</p>' "$st_sq"
    printf '%s' '<img src="data:image/svg+xml;base64,AAAA"></body></html>'
  } > "$st_shapes"
  extract_refs "$st_shapes" > "$WORKDIR/selftest-shapes.refs"

  for st_case in \
    "image${st_tab}/definitely-missing-asset.png|single-quoted <img src='...'>" \
    "image${st_tab}/definitely-missing-bg.png|CSS url(\"...\") in <style>" \
    "asset${st_tab}/definitely-missing-font.woff2|unquoted CSS url(...) in @font-face" \
    "image${st_tab}/definitely-missing-inline.png|CSS url('...') in inline style="
  do
    st_want=${st_case%%|*}; st_desc=${st_case#*|}
    if grep -q "^${st_want}$" "$WORKDIR/selftest-shapes.refs"; then
      row "selftest" "shape" "OK" "-" "extract" "$st_desc -> extracted"
    else
      row "selftest" "shape" "BAD" "-" "extract" "$st_desc NOT extracted — gate is blind to this shape"
      st_fail=1
    fi
  done

  # negative control A: an apostrophe in prose must not manufacture a reference.
  # Without this, "fix the blindness" could be satisfied by matching far too much,
  # and the gate would go permanently red on ordinary English.
  if grep -q 'fine' "$WORKDIR/selftest-shapes.refs"; then
    row "selftest" "shape" "BAD" "-" "extract" "prose apostrophe became a reference — extractor over-matches"
    st_fail=1
  else
    row "selftest" "shape" "OK" "-" "extract" "prose apostrophe -> not a reference"
  fi

  # negative control B: an inlined data: URI must be skipped, not probed as a path.
  if [ -z "$(normalize_url 'data:image/svg+xml;base64,AAAA')" ]; then
    row "selftest" "shape" "OK" "-" "normalize" "data: URI -> correctly skipped"
  else
    row "selftest" "shape" "BAD" "-" "normalize" "data: URI treated as a path — would be a false failure"
    st_fail=1
  fi

  # ---- advisory (external) class self-test — Cycle #24 ---------------------
  # 9. The classifier that decides local vs external. normalize_url and
  #    external_url must partition, not overlap: if both claimed the same URL it
  #    would be checked twice under two policies, and if neither did, an entire
  #    reference would vanish into the skip count — which is precisely the state
  #    this class was built to end.
  if [ -n "$(external_url 'https://github.com/oavcy/ogforge')" ]; then
    row "selftest" "ext" "OK" "-" "classify" "off-host URL -> external"
  else
    row "selftest" "ext" "BAD" "-" "classify" "off-host URL not classed external — advisory class is dead code"
    st_fail=1
  fi
  if [ -z "$(external_url "${BASE}/postmortem/hits")" ]; then
    row "selftest" "ext" "OK" "-" "classify" "own-host URL -> NOT external (stays a hard check)"
  else
    row "selftest" "ext" "BAD" "-" "classify" "own-host URL classed external — our own site would go advisory"
    st_fail=1
  fi
  if [ -z "$(normalize_url 'https://github.com/oavcy/ogforge')" ]; then
    row "selftest" "ext" "OK" "-" "classify" "off-host URL -> not local (no double-counting)"
  else
    row "selftest" "ext" "BAD" "-" "classify" "off-host URL also classed local — counted twice"
    st_fail=1
  fi

  # 10. Severity. An advisory class whose two severities collapse into one is a
  #     single label wearing two names, and --external-strict would then fail on
  #     GitHub having a bad afternoon.
  if [ "$(ext_severity 404)" = "WARN" ] && [ "$(ext_severity 410)" = "WARN" ]; then
    row "selftest" "ext" "OK" "-" "severity" "4xx -> WARN (our citation is gone)"
  else
    row "selftest" "ext" "BAD" "-" "severity" "4xx did not classify WARN — strict mode would never fire"
    st_fail=1
  fi
  if [ "$(ext_severity 503)" = "NOTE" ] && [ "$(ext_severity ERR)" = "NOTE" ] \
     && [ "$(ext_severity 000)" = "NOTE" ]; then
    row "selftest" "ext" "OK" "-" "severity" "5xx/ERR/000 -> NOTE (their outage, never ours)"
  else
    row "selftest" "ext" "BAD" "-" "severity" "an outage classified WARN — strict mode would fail on someone else's server"
    st_fail=1
  fi
  # 10b. Transient 4xx. Added in #25 after a real 429 turned this gate red on a
  #      live URL that was fine minutes later. Asserted in BOTH directions,
  #      because the failure has two sides: too strict makes the path flake to
  #      FAIL and invites someone to pass --external-lenient; too loose would
  #      swallow a genuine 404. So 429/408 must be NOTE AND 404/403/410 must
  #      still be WARN. One assertion alone cannot tell those apart.
  if [ "$(ext_severity 429)" = "NOTE" ] && [ "$(ext_severity 408)" = "NOTE" ]; then
    row "selftest" "ext" "OK" "-" "severity" "429/408 -> NOTE (throttled/timeout, ask again later)"
  else
    row "selftest" "ext" "BAD" "-" "severity" "429/408 classified WARN — a rate limit can fail this run"
    st_fail=1
  fi
  if [ "$(ext_severity 403)" = "WARN" ] && [ "$(ext_severity 404)" = "WARN" ] \
     && [ "$(ext_severity 410)" = "WARN" ]; then
    row "selftest" "ext" "OK" "-" "severity" "403/404/410 still WARN (the 429 fix did not widen)"
  else
    row "selftest" "ext" "BAD" "-" "severity" "a real dead citation now classifies NOTE — the 429 fix swallowed 4xx"
    st_fail=1
  fi

  # 11. End to end on a real off-host 404: the fetch happens, the status comes
  #     back, and the severity that results is WARN. This is the assertion that
  #     the advisory class can produce a bad result at all — the Falsifiability
  #     Rule applied to a class whose whole design is "cannot fail the run".
  #     Not-failing-the-build and not-being-able-to-go-red are different things,
  #     and only the first one is intended.
  probe_url link "$st_bad_link"
  if [ "$R_VERDICT" = "FAIL" ] && [ "$(ext_severity "$R_STATUS")" = "WARN" ]; then
    row "selftest" "ext" "OK" "$R_STATUS" "$R_CT" "live off-host 404 -> advisory WARN"
  else
    row "selftest" "ext" "BAD" "$R_STATUS" "$R_CT" "live off-host 404 did not produce WARN (verdict=$R_VERDICT)"
    st_fail=1
  fi

  # 12. Connection hints. The two false 404s this gate has ever produced were
  #     both <link rel=preconnect> hrefs: bare origins the browser resolves and
  #     connects to but never GETs. Three assertions, because the tempting fix
  #     (strip <link> tags) would also delete the stylesheet — and a missing
  #     stylesheet is a real, visible, page-wrecking defect.
  st_hint="$WORKDIR/selftest-hints.html"
  {
    printf '%s' '<html><head>'
    printf '%s' '<link rel="preconnect" href="https://hint-a.selftest-9f3a1c/">'
    printf '<link rel=%sdns-prefetch%s href=%shttps://hint-b.selftest-9f3a1c/%s>' \
           "$st_sq" "$st_sq" "$st_sq" "$st_sq"
    printf '%s' '<link rel="stylesheet" href="https://sheet.selftest-9f3a1c/app.css">'
    printf '%s' '</head><body><a href="https://hint-a.selftest-9f3a1c/">also a real link</a>'
    printf '%s' '</body></html>'
  } > "$st_hint"
  extract_refs "$st_hint" > "$WORKDIR/selftest-hints.refs"

  if grep -q "^hint${st_tab}https://hint-b.selftest-9f3a1c/$" "$WORKDIR/selftest-hints.refs"; then
    row "selftest" "hint" "OK" "-" "extract" "single-quoted rel=dns-prefetch -> classed hint"
  else
    row "selftest" "hint" "BAD" "-" "extract" "dns-prefetch not classed hint — would be fetched and 404"
    st_fail=1
  fi
  if grep -q "^link${st_tab}https://hint-b.selftest-9f3a1c/$" "$WORKDIR/selftest-hints.refs"; then
    row "selftest" "hint" "BAD" "-" "extract" "hint href still reached the href sweep — exclusion never fires"
    st_fail=1
  else
    row "selftest" "hint" "OK" "-" "extract" "hint-only href removed from the fetch set"
  fi
  if grep -q "^link${st_tab}https://sheet.selftest-9f3a1c/app.css$" "$WORKDIR/selftest-hints.refs"; then
    row "selftest" "hint" "OK" "-" "extract" "rel=stylesheet survives the hint stripper"
    else
    row "selftest" "hint" "BAD" "-" "extract" "stylesheet was stripped along with the hints — real asset now unchecked"
    st_fail=1
  fi
  if grep -q "^link${st_tab}https://hint-a.selftest-9f3a1c/$" "$WORKDIR/selftest-hints.refs"; then
    row "selftest" "hint" "OK" "-" "extract" "same URL used as a real <a href> is still checked"
  else
    row "selftest" "hint" "BAD" "-" "extract" "a genuine link was suppressed because a hint shared its URL"
    st_fail=1
  fi

  # 13. JS-constructed references. fetch('/x') is a reference; no markup pass can
  #     see it. Two positives and three negatives — the negatives carry more
  #     weight here than anywhere else in this file, because a URL detector let
  #     loose on JavaScript will happily report '/' as a broken asset forever.
  st_js="$WORKDIR/selftest-js.html"
  {
    printf '%s' '<html><body><script>'
    printf "  fetch(%s/definitely-missing-endpoint.json%s);" "$st_sq" "$st_sq"
    printf '%s' '  var i = new Image(); i.src = "/definitely-missing-js.png";'
    printf "  var parts = p.split(%s/%s);" "$st_sq" "$st_sq"
    printf '  var u = %s/img/${id}.png%s;' "$st_bt" "$st_bt"
    printf "  el.textContent = %sCopied!%s;" "$st_sq" "$st_sq"
    printf '%s' '</script></body></html>'
  } > "$st_js"
  extract_refs "$st_js" > "$WORKDIR/selftest-js.refs"

  if grep -q "^asset${st_tab}/definitely-missing-endpoint.json$" "$WORKDIR/selftest-js.refs"; then
    row "selftest" "js" "OK" "-" "extract" "fetch('/path') -> extracted"
  else
    row "selftest" "js" "BAD" "-" "extract" "fetch('/path') NOT extracted — JS refs still invisible"
    st_fail=1
  fi
  if grep -q "^image${st_tab}/definitely-missing-js.png$" "$WORKDIR/selftest-js.refs"; then
    row "selftest" "js" "OK" "-" "extract" "el.src = \"/x.png\" -> extracted as image"
  else
    row "selftest" "js" "BAD" "-" "extract" "JS-assigned image src not extracted as image"
    st_fail=1
  fi
  if grep -qE "^(asset|image|link)${st_tab}/$" "$WORKDIR/selftest-js.refs"; then
    row "selftest" "js" "BAD" "-" "extract" "split('/') became a reference — detector over-matches"
    st_fail=1
  else
    row "selftest" "js" "OK" "-" "extract" "split('/') -> not a reference"
  fi
  if grep -q 'img/' "$WORKDIR/selftest-js.refs"; then
    row "selftest" "js" "BAD" "-" "extract" "unresolved template literal reported as a URL — guaranteed false 404"
    st_fail=1
  else
    row "selftest" "js" "OK" "-" "extract" 'template literal `/img/${id}.png` -> correctly skipped'
  fi
  if grep -q 'Copied' "$WORKDIR/selftest-js.refs"; then
    row "selftest" "js" "BAD" "-" "extract" "a UI string became a reference — detector over-matches"
    st_fail=1
  else
    row "selftest" "js" "OK" "-" "extract" "ordinary JS string -> not a reference"
  fi

  # 14. Relative markdown links. Extracted by nothing at all until now, which is
  #     worse than skipped: a skip is at least counted. Resolution is asserted in
  #     both directions on real paths, so "the file is there" and "the file is
  #     gone" are demonstrably different outcomes rather than one code path.
  if extract_md_refs "$st_md" | grep -q "^mdrel${st_tab}./definitely-missing-doc-9f3a1c.md$"; then
    row "selftest" "rel" "OK" "-" "extract" "relative markdown target -> extracted"
  else
    row "selftest" "rel" "BAD" "-" "extract" "relative markdown target NOT extracted — still invisible"
    st_fail=1
  fi
  if extract_md_refs "$st_md" | grep -q "^mdrel${st_tab}#self-hosting$"; then
    row "selftest" "rel" "BAD" "-" "extract" "in-page anchor treated as a file — permanent false failure"
    st_fail=1
  else
    row "selftest" "rel" "OK" "-" "extract" "in-page anchor -> not a file reference"
  fi
  if extract_md_refs "$st_md" | grep -q "^mdrel${st_tab}https"; then
    row "selftest" "rel" "BAD" "-" "extract" "an http URL was routed to the on-disk check"
    st_fail=1
  else
    row "selftest" "rel" "OK" "-" "extract" "http URLs -> not routed to the on-disk check"
  fi
  if [ -e "$(resolve_rel "$st_md" './selftest-fixture.md')" ]; then
    row "selftest" "rel" "OK" "-" "resolve" "existing relative target -> found on disk"
  else
    row "selftest" "rel" "BAD" "-" "resolve" "existing relative target NOT found — every doc link would fail"
    st_fail=1
  fi
  if [ -e "$(resolve_rel "$st_md" './definitely-missing-doc-9f3a1c.md')" ]; then
    row "selftest" "rel" "BAD" "-" "resolve" "missing relative target reported as present — check is vacuous"
    st_fail=1
  else
    row "selftest" "rel" "OK" "-" "resolve" "missing relative target -> correctly absent"
  fi
  if [ "$(resolve_rel "$st_md" '/LICENSE')" = "${REPO_ROOT}/LICENSE" ]; then
    row "selftest" "rel" "OK" "-" "resolve" "leading-slash target resolves to repo root, as GitHub does"
  else
    row "selftest" "rel" "BAD" "-" "resolve" "leading-slash target resolved against the wrong base"
    st_fail=1
  fi

  # ---- shapes found by adversarial QA, not by the author ------------------
  # Every assertion below covers a shape that was NOT in a fixture when this file
  # reported 39/39. That number measured fixture coverage, not reference
  # coverage. Each one was a reproduced defect before it was a test.
  st_qa="$WORKDIR/selftest-qa.html"
  {
    printf '%s' '<html><head>'
    printf '%s' '<link rel="preconnect stylesheet" href="/qa-multitoken.css">'
    printf '%s' '<LINK REL="preconnect" HREF="https://qa-upper.selftest-9f3a1c/">'
    printf '%s' '<link href="https://qa-gt.selftest-9f3a1c/" data-note="a>b" rel="preconnect">'
    printf '%s' '<script type="application/ld+json">{"url":"/qa-ldjson","x":"https://schema.org"}</script>'
    printf '%s' '</head><body>'
    printf '%s' '<IMG SRC="/qa-upper-img.png" ALT="x">'
    printf '%s' '<a HREF="/qa-upper-link">up</a>'
    printf '%s' '<script>'
    printf '  el.textContent = "it%ss done"; fetch(%s/qa-after-apostrophe.json%s);' \
           "$st_sq" "$st_sq" "$st_sq"
    printf '  // we don%st retry here\n  router.add(%s/user/:id%s, h);' "$st_sq" "$st_sq" "$st_sq"
    printf '%s' '</script></body></html>'
  } > "$st_qa"
  extract_refs "$st_qa" > "$WORKDIR/selftest-qa.refs"

  st_qa_check() { # <grep-args...> handled by caller; $1=expect(present|absent) $2=pattern $3=desc
    if grep -q "$2" "$WORKDIR/selftest-qa.refs"; then st_got=present; else st_got=absent; fi
    if [ "$st_got" = "$1" ]; then
      row "selftest" "qa" "OK" "-" "extract" "$3"
    else
      row "selftest" "qa" "BAD" "-" "extract" "$3 — got $st_got, wanted $1"
      st_fail=1
    fi
  }
  st_qa_check absent  "^hint${st_tab}/qa-multitoken.css$" \
    'rel="preconnect stylesheet" is NOT a hint (token list, order-independent)'
  st_qa_check present "^link${st_tab}/qa-multitoken.css$" \
    'multi-token rel keeps the stylesheet in the fetch set'
  st_qa_check present "^hint${st_tab}https://qa-upper.selftest-9f3a1c/$" \
    'uppercase <LINK REL=...> is recognised as a hint'
  st_qa_check present "^image${st_tab}/qa-upper-img.png$" \
    'uppercase <IMG SRC=...> reaches the generic image sweep, not just the hint detector'
  st_qa_check present "^link${st_tab}/qa-upper-link$" \
    'uppercase <a HREF=...> reaches the generic href sweep'
  st_qa_check present "^hint${st_tab}https://qa-gt.selftest-9f3a1c/$" \
    "'>' inside an attribute value does not defeat the hint exclusion"
  st_qa_check present "^asset${st_tab}/qa-after-apostrophe.json$" \
    "apostrophe in a JS string does not hide the next single-quoted reference"
  st_qa_check absent  "qa-ldjson" \
    'application/ld+json is data, not code — its "url" values are not references'
  st_qa_check absent  "schema.org" \
    'JSON-LD @context is not fetched'
  st_qa_check absent  "user/:id" \
    'a JS route pattern /user/:id is not a reference'

  # 15. Markdown shapes: balanced parens, and fenced code is an example not a link.
  st_md2="$WORKDIR/selftest-md2.md"
  {
    printf '# fixture 2\n\n'
    printf 'A citation with parens: [Ruby](https://en.wikipedia.org/wiki/Ruby_(programming_language))\n\n'
    printf 'An example inside a fence:\n\n'
    printf '```markdown\n[docs](path/to/your/file.md)\n```\n'
  } > "$st_md2"
  extract_md_refs "$st_md2" > "$WORKDIR/selftest-md2.refs"
  if grep -q "^link${st_tab}https://en.wikipedia.org/wiki/Ruby_(programming_language)$" "$WORKDIR/selftest-md2.refs"; then
    row "selftest" "md" "OK" "-" "extract" "URL containing () extracted whole (depth counting)"
  else
    row "selftest" "md" "BAD" "-" "extract" "parenthesised URL truncated — invents a 404 on a good link"
    st_fail=1
  fi
  if grep -q "programming_language$" "$WORKDIR/selftest-md2.refs" \
     && grep -q "^mdrel" "$WORKDIR/selftest-md2.refs"; then
    row "selftest" "md" "BAD" "-" "extract" "URL tail became a filename — hard-fails on a valid citation"
    st_fail=1
  else
    row "selftest" "md" "OK" "-" "extract" "no URL tail leaked into the on-disk check"
  fi
  if grep -q "path/to/your/file.md" "$WORKDIR/selftest-md2.refs"; then
    row "selftest" "md" "BAD" "-" "extract" "example inside a fenced code block treated as a real link — false red"
    st_fail=1
  else
    row "selftest" "md" "OK" "-" "extract" "fenced code block is an example, not a reference"
  fi

  # 16. is_published, not [ -e ]: the oracle must be what a STRANGER can fetch.
  if is_published "${REPO_ROOT}/README.md"; then
    row "selftest" "rel" "OK" "-" "published" "tracked file -> published"
  else
    row "selftest" "rel" "BAD" "-" "published" "a tracked file was called unpublished — every doc link fails"
    st_fail=1
  fi
  for st_case in \
    "${REPO_ROOT}/Readme.md|wrong-case target rejected (macOS lies, GitHub does not)" \
    "${REPO_ROOT}/../../etc/passwd|path outside the repo rejected" \
    "${WORKDIR}/selftest-fixture.md|untracked file rejected (exists here, 404s for a stranger)"
  do
    st_p=${st_case%%|*}; st_desc=${st_case#*|}
    if is_published "$st_p"; then
      row "selftest" "rel" "BAD" "-" "published" "$st_desc — FAILED, it was called published"
      st_fail=1
    else
      row "selftest" "rel" "OK" "-" "published" "$st_desc"
    fi
  done

  # 16b. SITEMAP FIELD DISCIPLINE (#54). Eight fixtures, driven through the same
  #      predicate the live check uses. The first is the reconstructed pre-#54
  #      sitemap: if this gate could not go red on the exact document that was
  #      served until this cycle, it would be certifying its own fix. The second
  #      is the current shape and MUST come back clean, because a check that
  #      flags every sitemap is worth nothing.
  #
  #      Note what is NOT asserted here: that <lastmod> is present. #54 refused to
  #      add it (no per-page modification signal can be kept accurate), so an
  #      always-red "missing lastmod" rule would have been a trap set for a future
  #      cycle. These rows police the field's CORRECTNESS if it ever appears.
  st_smdir="$WORKDIR/selftest-sitemaps"; mkdir -p "$st_smdir"
  st_sm_today=$(date -u +%Y-%m-%d)
  st_sm_future=$(date -u -v+30d +%Y-%m-%d 2>/dev/null || date -u -d '+30 days' +%Y-%m-%d 2>/dev/null || echo "2099-01-01")
  st_sm_head='<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'

  printf '%s\n  <url><loc>%s/</loc><changefreq>weekly</changefreq><priority>1.0</priority></url>\n  <url><loc>%s/register</loc><changefreq>monthly</changefreq><priority>0.8</priority></url>\n</urlset>\n' \
    "$st_sm_head" "$BASE" "$BASE" > "$st_smdir/pre54.xml"
  printf '%s\n  <url><loc>%s/</loc></url>\n  <url><loc>%s/register</loc></url>\n</urlset>\n' \
    "$st_sm_head" "$BASE" "$BASE" > "$st_smdir/current.xml"
  printf '%s\n  <url><loc>%s/</loc><lastmod>2026-01-15</lastmod></url>\n</urlset>\n' \
    "$st_sm_head" "$BASE" > "$st_smdir/lastmod-ok.xml"
  printf '%s\n  <url><loc>%s/</loc><lastmod>%s</lastmod></url>\n</urlset>\n' \
    "$st_sm_head" "$BASE" "$st_sm_future" > "$st_smdir/lastmod-future.xml"
  printf '%s\n  <url><loc>%s/</loc><lastmod>last Tuesday</lastmod></url>\n</urlset>\n' \
    "$st_sm_head" "$BASE" > "$st_smdir/lastmod-bad.xml"
  printf '%s\n  <url><loc>%s/</loc></url>\n  <url></url>\n</urlset>\n' \
    "$st_sm_head" "$BASE" > "$st_smdir/shape.xml"
  printf '%s\n</urlset>\n' "$st_sm_head" > "$st_smdir/empty-urlset.xml"
  : > "$st_smdir/unfetchable.xml"

  for st_case in \
    "2|pre54.xml|the sitemap served until #54 — 2 ignored-field defects" \
    "0|current.xml|the shape #54 deploys — <loc> only, must be clean" \
    "0|lastmod-ok.xml|a valid past <lastmod> is accepted, not flagged" \
    "1|lastmod-future.xml|a <lastmod> in the future is rejected" \
    "1|lastmod-bad.xml|a non-W3C-Datetime <lastmod> is rejected" \
    "1|shape.xml|a <url> with no <loc> is rejected" \
    "1|empty-urlset.xml|a <urlset> submitting zero URLs is rejected" \
    "1|unfetchable.xml|an empty/unfetched sitemap reports UNREADABLE, never a pass"
  do
    st_want=${st_case%%|*}; st_rest=${st_case#*|}
    st_file=${st_rest%%|*}; st_desc=${st_rest#*|}
    st_got=$(sitemap_field_defects "$st_smdir/$st_file" "$st_sm_today" | grep -c .)
    if [ "$st_got" = "$st_want" ]; then
      row "selftest" "smap" "OK" "$st_got" "field-discipline" "$st_desc"
    else
      row "selftest" "smap" "BAD" "$st_got" "field-discipline" \
          "$st_desc — got ${st_got} defect(s), wanted ${st_want}"
      st_fail=1
    fi
  done

  # 16c. 401 CHALLENGE DISCIPLINE (#55). Nine fixtures through the same predicate
  #      the live check uses. The first is the response /og actually served until
  #      this cycle — captured, not imagined — so if this gate could not go red on
  #      it, it would be certifying its own fix. Two green controls (one per
  #      expectation) are here because a check that flags every 401 is worth
  #      nothing.
  st_chdir="$WORKDIR/selftest-challenges"; mkdir -p "$st_chdir"

  # The pre-#55 response, verbatim: correct status, clear body, no challenge.
  printf 'HTTP/2 401 \r\ncontent-type: application/json\r\n\r\n' > "$st_chdir/pre55.txt"
  printf 'HTTP/2 401 \r\nwww-authenticate: Bearer realm="ogforge"\r\nvary: Authorization\r\ncontent-type: application/json\r\n\r\n' \
    > "$st_chdir/good-none.txt"
  printf 'HTTP/2 401 \r\nwww-authenticate: Bearer realm="ogforge", error="invalid_token", error_description="x"\r\nvary: Authorization\r\n\r\n' \
    > "$st_chdir/good-invalid.txt"
  printf 'HTTP/2 401 \r\nwww-authenticate: Basic realm="ogforge"\r\nvary: Authorization\r\n\r\n' \
    > "$st_chdir/wrong-scheme.txt"
  printf 'HTTP/2 401 \r\nwww-authenticate: Bearer realm="a", realm="b"\r\nvary: Authorization\r\n\r\n' \
    > "$st_chdir/double-realm.txt"
  printf 'HTTP/2 401 \r\nwww-authenticate: Bearer realm="ogforge", error="invalid_token"\r\nvary: Authorization\r\n\r\n' \
    > "$st_chdir/overshare.txt"
  printf 'HTTP/2 401 \r\nwww-authenticate: Bearer realm="ogforge"\r\nvary: Accept-Encoding\r\n\r\n' \
    > "$st_chdir/no-vary.txt"
  printf 'HTTP/2 200 \r\ncontent-type: image/png\r\n\r\n' > "$st_chdir/not-401.txt"
  : > "$st_chdir/unfetchable.txt"

  for st_case in \
    "2|pre55.txt|none|the 401 /og served until #55 — no challenge, no Vary" \
    "0|good-none.txt|none|no credentials: bare Bearer challenge, must be clean" \
    "0|good-invalid.txt|invalid|rejected credential: error=invalid_token, must be clean" \
    "1|wrong-scheme.txt|none|a Basic challenge on a Bearer resource is rejected" \
    "1|double-realm.txt|none|realm twice is rejected (RFC 6750 §3 MUST NOT)" \
    "1|overshare.txt|none|error= on a request that sent no credentials is rejected" \
    "1|no-vary.txt|none|a Vary that omits Authorization is rejected" \
    "1|not-401.txt|invalid|a non-401 on the rejected-credential probe is rejected" \
    "1|unfetchable.txt|none|an uncaptured response reports UNREADABLE, never a pass"
  do
    st_want=${st_case%%|*}; st_rest=${st_case#*|}
    st_file=${st_rest%%|*}; st_rest=${st_rest#*|}
    st_exp=${st_rest%%|*}; st_desc=${st_rest#*|}
    # Count on its own line, then head -1: `grep -c .` prints 0 AND exits 1 on no
    # match, so `$(... | grep -c .)` inside a pipeline is fine but the `|| echo 0`
    # form is not. This is the bug #54's own new check shipped with.
    st_got=$(auth_challenge_defects "$st_chdir/$st_file" "$st_exp" | grep -c . | head -1)
    if [ "$st_got" = "$st_want" ]; then
      row "selftest" "auth" "OK" "$st_got" "challenge" "$st_desc"
    else
      row "selftest" "auth" "BAD" "$st_got" "challenge" \
          "$st_desc — got ${st_got} defect(s), wanted ${st_want}"
      st_fail=1
    fi
  done

  # 16d. RETRY SEMANTICS (#56). Thirteen fixtures through the same predicate the
  #      live check uses. The first two are the responses this worker actually
  #      served until this cycle — captured from a real workerd running the
  #      pre-fix source against a local D1 seeded to hit each branch, not
  #      imagined. Two green controls (one transient, one permanent) are here
  #      because a check that flags every 429 is worth nothing, and a check that
  #      flags every permanent refusal would flag the fix itself.
  st_rtdir="$WORKDIR/selftest-retry"; mkdir -p "$st_rtdir"

  # --- verbatim captures, local workerd, pre-fix source ---
  printf 'HTTP/1.1 429 Too Many Requests\r\nContent-Type: application/json\r\n\r\n' \
    > "$st_rtdir/pre56-og.txt"
  printf 'HTTP/1.1 429 Too Many Requests\r\nContent-Type: text/html; charset=utf-8\r\n\r\n' \
    > "$st_rtdir/pre56-register.txt"
  # --- verbatim captures, same runtime, post-fix source ---
  printf 'HTTP/1.1 429 Too Many Requests\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nRetry-After: 1803702\r\n\r\n' \
    > "$st_rtdir/good-transient.txt"
  printf 'HTTP/1.1 403 Forbidden\r\nContent-Type: text/html; charset=utf-8\r\n\r\n' \
    > "$st_rtdir/good-permanent.txt"
  # --- synthetic: each isolates one clause ---
  printf 'HTTP/1.1 429 Too Many Requests\r\nCache-Control: no-store\r\n\r\n' \
    > "$st_rtdir/no-retry-after.txt"
  printf 'HTTP/1.1 429 Too Many Requests\r\nRetry-After: 1803702\r\nCache-Control: public, max-age=60\r\n\r\n' \
    > "$st_rtdir/cacheable-429.txt"
  printf 'HTTP/1.1 429 Too Many Requests\r\nCache-Control: no-store\r\nRetry-After: -5\r\n\r\n' \
    > "$st_rtdir/negative.txt"
  printf 'HTTP/1.1 429 Too Many Requests\r\nCache-Control: no-store\r\nRetry-After: 1803702.5\r\n\r\n' \
    > "$st_rtdir/fractional.txt"
  printf 'HTTP/1.1 429 Too Many Requests\r\nCache-Control: no-store\r\nRetry-After: soon\r\n\r\n' \
    > "$st_rtdir/wordy.txt"
  printf 'HTTP/1.1 429 Too Many Requests\r\nCache-Control: no-store\r\nRetry-After: Thu, 01 Oct 2026 00:00:00 GMT\r\n\r\n' \
    > "$st_rtdir/http-date.txt"
  printf 'HTTP/1.1 403 Forbidden\r\nRetry-After: 3600\r\n\r\n' \
    > "$st_rtdir/permanent-with-wait.txt"
  printf 'HTTP/1.1 409 Conflict\r\nContent-Type: text/html\r\n\r\n' \
    > "$st_rtdir/vetoed-409.txt"
  : > "$st_rtdir/unfetchable.txt"

  for st_case in \
    "2|pre56-og.txt|transient|the 429 /og served until #56 — no Retry-After, storable" \
    "1|pre56-register.txt|permanent|the 429 /register served until #56 — the retry lie itself" \
    "0|good-transient.txt|transient|post-fix /og 429: computed Retry-After + no-store, must be clean" \
    "0|good-permanent.txt|permanent|post-fix /register 403: must be clean, or the fix fails its own gate" \
    "1|no-retry-after.txt|transient|a 429 with no Retry-After is rejected" \
    "1|cacheable-429.txt|transient|a 429 a cache may store is rejected (RFC 6585 §4)" \
    "1|negative.txt|transient|Retry-After: -5 is rejected (delay-seconds is non-negative)" \
    "1|fractional.txt|transient|a fractional Retry-After is rejected (1*DIGIT)" \
    "1|wordy.txt|transient|a non-numeric, non-date Retry-After is rejected" \
    "0|http-date.txt|transient|an IMF-fixdate Retry-After is accepted, not just seconds" \
    "2|permanent-with-wait.txt|permanent|a permanent refusal advertising a wait is rejected twice" \
    "1|vetoed-409.txt|permanent|409 for an unresolvable conflict is rejected — the quiet lie" \
    "1|unfetchable.txt|transient|an uncaptured response reports UNREADABLE, never a pass"
  do
    st_want=${st_case%%|*}; st_rest=${st_case#*|}
    st_file=${st_rest%%|*}; st_rest=${st_rest#*|}
    st_cond=${st_rest%%|*}; st_desc=${st_rest#*|}
    st_got=$(retry_semantics_defects "$st_rtdir/$st_file" "$st_cond" | grep -c . | head -1)
    if [ "$st_got" = "$st_want" ]; then
      row "selftest" "retry" "OK" "$st_got" "semantics" "$st_desc"
    else
      row "selftest" "retry" "BAD" "$st_got" "semantics" \
          "$st_desc — got ${st_got} defect(s), wanted ${st_want}"
      st_fail=1
    fi
  done

  # 16e. METHOD SEMANTICS (#57). Fifteen fixtures through the same predicate the
  #      live check uses. Unlike #56, this cycle's fix IS anonymously reachable,
  #      so the live rows below can genuinely go red — these fixtures are not
  #      carrying the falsifiability on their own, they are pinning the branches
  #      production cannot reach (the undisclosed carve-out is exercised live,
  #      but the malformed-Allow shapes are not).
  st_mmdir="$WORKDIR/selftest-method"; mkdir -p "$st_mmdir"

  # --- verbatim captures, local workerd, PRE-fix source (what we served for 56
  #     cycles). Every one of these was 404 with zero Allow headers. ---
  printf 'HTTP/1.1 404 Not Found\r\nContent-Type: text/html; charset=utf-8\r\n\r\n' \
    > "$st_mmdir/pre57-post-root.txt"
  printf 'HTTP/1.1 404 Not Found\r\nContent-Type: text/html; charset=utf-8\r\n\r\n' \
    > "$st_mmdir/pre57-options-root.txt"
  # --- verbatim captures, same runtime, POST-fix source ---
  printf 'HTTP/1.1 405 Method Not Allowed\r\nContent-Type: text/html; charset=utf-8\r\nAllow: GET, HEAD\r\n\r\n' \
    > "$st_mmdir/good-405-get.txt"
  printf 'HTTP/1.1 405 Method Not Allowed\r\nContent-Type: text/html; charset=utf-8\r\nAllow: GET, HEAD, POST\r\n\r\n' \
    > "$st_mmdir/good-405-getpost.txt"
  printf 'HTTP/1.1 405 Method Not Allowed\r\nContent-Type: text/html; charset=utf-8\r\nAllow: POST\r\n\r\n' \
    > "$st_mmdir/good-405-postonly.txt"
  printf 'HTTP/1.1 404 Not Found\r\nContent-Type: text/html; charset=utf-8\r\n\r\n' \
    > "$st_mmdir/good-absent.txt"
  # --- synthetic: each isolates one clause ---
  printf 'HTTP/1.1 405 Method Not Allowed\r\n\r\n' > "$st_mmdir/no-allow.txt"
  printf 'HTTP/1.1 405 Method Not Allowed\r\nAllow: \r\n\r\n' > "$st_mmdir/empty-allow.txt"
  printf 'HTTP/1.1 405 Method Not Allowed\r\nAllow: GET, HEAD, POST\r\n\r\n' \
    > "$st_mmdir/contradicts.txt"
  printf 'HTTP/1.1 405 Method Not Allowed\r\nAllow: GET\r\n\r\n' > "$st_mmdir/omits-head.txt"
  printf 'HTTP/1.1 405 Method Not Allowed\r\nAllow: GET; HEAD\r\n\r\n' > "$st_mmdir/malformed.txt"
  printf 'HTTP/1.1 405 Method Not Allowed\r\nAllow: GET, HEAD\r\nAllow: POST\r\n\r\n' \
    > "$st_mmdir/duplicate.txt"
  printf 'HTTP/1.1 405 Method Not Allowed\r\nAllow: ALL, GET, HEAD\r\n\r\n' > "$st_mmdir/all-token.txt"
  printf 'HTTP/1.1 405 Method Not Allowed\r\nAllow: GET, HEAD\r\n\r\n' > "$st_mmdir/overreach.txt"
  : > "$st_mmdir/unfetchable.txt"

  # Field 5 is the EXPECTED Allow, as derive_allow_map() would emit it from the
  # literal. `-` means "this fixture is aiming at one of the shape clauses and
  # has no source-side expectation"; an EMPTY field means the derivation came
  # back with nothing, which must be a defect and not a skip.
  for st_case in \
    "1|pre57-post-root.txt|POST|disclosed|-|the 404 POST / served until #57 — the status lie itself" \
    "1|pre57-options-root.txt|OPTIONS|disclosed|-|the 404 OPTIONS / served until #57" \
    "0|good-405-get.txt|POST|disclosed|-|post-fix 405 on a GET-only path must be clean" \
    "0|good-405-getpost.txt|PUT|disclosed|-|post-fix 405 on a GET+POST path must be clean" \
    "0|good-405-postonly.txt|GET|disclosed|-|post-fix 405 on the POST-only operator path must be clean" \
    "0|good-absent.txt|POST|absent|-|a genuinely absent path must still read 404, or the fix over-fired" \
    "1|no-allow.txt|POST|disclosed|-|405 without Allow is rejected (§15.5.6 and §10.2.1 MUST)" \
    "1|empty-allow.txt|POST|disclosed|-|an empty Allow claims the resource allows no methods" \
    "1|contradicts.txt|POST|disclosed|-|a 405 whose Allow lists the refused method is rejected" \
    "1|omits-head.txt|POST|disclosed|-|Allow: GET without HEAD is rejected (§9.1)" \
    "2|malformed.txt|POST|disclosed|-|a semicolon-joined Allow is rejected twice: bad syntax, and 'GET;' is not a method" \
    "1|duplicate.txt|PUT|disclosed|-|two Allow headers are rejected — send one list" \
    "1|all-token.txt|POST|disclosed|-|Allow: ALL is rejected — the exact header the vetoed path filter would have served" \
    "2|overreach.txt|POST|absent|-|a 405 on a path with no route is rejected: status and stray Allow" \
    "1|unfetchable.txt|POST|disclosed|-|an uncaptured response reports UNREADABLE, never a pass" \
    "1|good-405-get.txt|POST|disclosed|GET, HEAD, POST|THE POISONED ROW: Allow GET,HEAD against a source declaring POST too. Under-disclosure passes all seven shape clauses — if this fixture is not RED the equality test is not wired" \
    "1|good-405-getpost.txt|PUT|disclosed|GET, HEAD|over-disclosure: the router claims POST and the source does not declare it" \
    "0|good-405-getpost.txt|PUT|disclosed|POST,HEAD,GET|equality is on the SET: order and spacing are not semantic in a #method list" \
    "0|good-405-postonly.txt|GET|disclosed|POST|the POST-only operator path agrees with the literal" \
    "1|good-405-get.txt|POST|disclosed||AN UNRESOLVED EXPECTATION IS A DEFECT, NOT A SKIP: comparing '' to a parsed '' would pass on two dead inputs (#41), and the trailing-slash twin is how a loose lookup produces exactly that"
  do
    st_want=${st_case%%|*}; st_rest=${st_case#*|}
    st_file=${st_rest%%|*}; st_rest=${st_rest#*|}
    st_mth=${st_rest%%|*};  st_rest=${st_rest#*|}
    st_exp=${st_rest%%|*};  st_rest=${st_rest#*|}
    st_wal=${st_rest%%|*};  st_desc=${st_rest#*|}
    st_got=$(method_semantics_defects "$st_mmdir/$st_file" "$st_mth" "$st_exp" "$st_wal" | grep -c . | head -1)
    if [ "$st_got" = "$st_want" ]; then
      row "selftest" "method" "OK" "$st_got" "semantics" "$st_desc"
    else
      row "selftest" "method" "BAD" "$st_got" "semantics" \
          "$st_desc — got ${st_got} defect(s), wanted ${st_want}"
      st_fail=1
    fi
  done

  # 17. CACHE SEMANTICS (#58). The four pre/post pairs below are verbatim from a
  #     local workerd running HEAD source and then this cycle's source against a
  #     local D1 seeded with one api_keys row — the only way to execute the
  #     valid-key branch without registering a key in production. The synthetic
  #     rows isolate one clause each, including the two "legal, plausible, does
  #     nothing" shapes (`private` and a validator beside no-store) that no
  #     client would ever error on and so nothing else would report.
  st_csdir="$WORKDIR/selftest-cache"; mkdir -p "$st_csdir"
  # --- verbatim, local workerd, PRE-fix source (what production served) ---
  printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n' \
    > "$st_csdir/pre58-health.txt"
  printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Robots-Tag: noindex, nofollow\r\n\r\n' \
    > "$st_csdir/pre58-hits.txt"
  printf 'HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nX-Robots-Tag: noindex, nofollow\r\n\r\n' \
    > "$st_csdir/pre58-dash-keyed.txt"
  printf 'HTTP/1.1 404 Not Found\r\nContent-Type: text/html; charset=utf-8\r\nX-Robots-Tag: noindex, nofollow\r\n\r\n' \
    > "$st_csdir/pre58-dash-badkey.txt"
  # --- verbatim, same runtime, POST-fix source ---
  printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nCache-Control: no-store\r\n\r\n' \
    > "$st_csdir/good-health.txt"
  printf 'HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nX-Robots-Tag: noindex, nofollow\r\nCache-Control: no-store\r\n\r\n' \
    > "$st_csdir/good-dash-keyed.txt"
  printf 'HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nX-Robots-Tag: noindex, nofollow\r\n\r\n' \
    > "$st_csdir/good-dash-nokey.txt"
  # --- synthetic: one clause each ---
  printf 'HTTP/1.1 200 OK\r\nCache-Control: private, no-store\r\n\r\n' > "$st_csdir/inert-private.txt"
  printf 'HTTP/1.1 200 OK\r\nCache-Control: no-store, max-age=60\r\n\r\n' > "$st_csdir/contradict.txt"
  printf 'HTTP/1.1 200 OK\r\nCache-Control: public, max-age=3600\r\n\r\n' > "$st_csdir/wrong-directive.txt"
  printf 'HTTP/1.1 200 OK\r\nCache-Control: no-store\r\nETag: "abc"\r\n\r\n' > "$st_csdir/inert-validator.txt"
  printf 'HTTP/1.1 200 OK\r\nCache-Control: no-store\r\nCache-Control: max-age=5\r\n\r\n' \
    > "$st_csdir/duplicate-cc.txt"
  printf 'HTTP/1.1 200 OK\r\nCache-Control: no-store\r\n\r\n' > "$st_csdir/overfire.txt"
  printf 'HTTP/1.1 200 OK\r\nCache-Control: no-store-please\r\n\r\n' > "$st_csdir/lookalike.txt"
  : > "$st_csdir/unfetchable.txt"

  for st_case in \
    "1|pre58-health.txt|no-store|the headerless /health served until #58 — heuristically cacheable" \
    "1|pre58-hits.txt|no-store|the headerless live counter served until #58" \
    "1|pre58-dash-keyed.txt|no-store|the headerless keyed dashboard — local workerd, HEAD source" \
    "1|pre58-dash-badkey.txt|no-store|the headerless key-dependent 404 (404 is heuristically cacheable, 9110 line 7597)" \
    "0|good-health.txt|no-store|post-fix /health must be clean" \
    "0|good-dash-keyed.txt|no-store|post-fix keyed dashboard must be clean — local workerd, this source" \
    "0|good-dash-nokey.txt|heuristic|the no-key branch must STAY storable — the over-fire control" \
    "1|overfire.txt|heuristic|a no-store where none belongs is rejected: this is the row a route-wide header trips" \
    "1|inert-private.txt|no-store|'private' beside no-store is rejected as inert (#56 A3, on our own addition)" \
    "1|contradict.txt|no-store|max-age beside no-store is rejected as self-contradictory" \
    "1|wrong-directive.txt|no-store|'public, max-age' where no-store is required is rejected" \
    "1|inert-validator.txt|no-store|an ETag on a no-store response is rejected as inert" \
    "1|duplicate-cc.txt|no-store|two Cache-Control headers are rejected — send one list" \
    "1|lookalike.txt|no-store|'no-store-please' must NOT satisfy no-store — the comma-fencing row" \
    "1|unfetchable.txt|no-store|an uncaptured response reports UNREADABLE, never a pass"
  do
    st_want=${st_case%%|*}; st_rest=${st_case#*|}
    st_file=${st_rest%%|*}; st_rest=${st_rest#*|}
    st_exp=${st_rest%%|*};  st_desc=${st_rest#*|}
    st_got=$(cache_semantics_defects "$st_csdir/$st_file" "$st_exp" | grep -c . | head -1)
    if [ "$st_got" = "$st_want" ]; then
      row "selftest" "cache" "OK" "$st_got" "semantics" "$st_desc"
    else
      row "selftest" "cache" "BAD" "$st_got" "semantics" \
          "$st_desc — got ${st_got} defect(s), wanted ${st_want}"
      st_fail=1
    fi
  done

  # 18. THE ROUTE EXTRACTOR (#57 A5). The first fixture is the one that matters:
  #     it is the exact prose shape that moved the old greps from 16/18 to 17/19
  #     — a comment ABOUT routing, containing route-registration syntax. A
  #     string counter reads it as two routes. Nothing else in this file would
  #     have noticed, because the wrong answer is a plausible number.
  st_rsdir="$WORKDIR/selftest-routes"; mkdir -p "$st_rsdir"
  printf 'app.get(%s/real%s, h);\n// app.use(%s/dashboard%s, mw) -> { method: ALL } <- no star\n//   app.post(%s/fake%s, h) is prose, not a route\n' \
    "'" "'" "'" "'" "'" "'" > "$st_rsdir/prose.ts"
  printf 'app.get(%s/a%s, h);\napp.post(%s/a%s, h);\napp.get(%s/b%s, h);\n' \
    "'" "'" "'" "'" "'" "'" > "$st_rsdir/pairs.ts"
  printf 'app.use(%s*%s, mw);\napp.get(%s/a%s, h);\n' "'" "'" "'" "'" > "$st_rsdir/middleware.ts"
  printf '// nothing here but a comment about app.get(\n' > "$st_rsdir/empty.ts"
  for st_case in \
    "1|prose.ts|a comment containing app.use(/dashboard) and app.post(/fake) must count ONE route, not three" \
    "3|pairs.ts|two methods on one path are TWO pairs — the count the old greps could not express" \
    "1|middleware.ts|app.use is middleware (method ALL) and is not part of the method surface" \
    "0|empty.ts|a file with only prose yields zero pairs, which the caller treats as FAIL not PASS"
  do
    st_want=${st_case%%|*}; st_rest=${st_case#*|}
    st_file=${st_rest%%|*}; st_desc=${st_rest#*|}
    st_got=$(route_pairs "$st_rsdir/$st_file" | grep -c . | head -1)
    if [ "$st_got" = "$st_want" ]; then
      row "selftest" "routes" "OK" "$st_got" "surface" "$st_desc"
    else
      row "selftest" "routes" "BAD" "$st_got" "surface" \
          "$st_desc — got ${st_got} pair(s), wanted ${st_want}"
      st_fail=1
    fi
  done
  # The old grep, run on the same prose fixture, so the transcript shows the
  # defect rather than only asserting it was fixed.
  st_oldn=$(grep -cE 'app\.(get|post|put|delete|all)\(' "$st_rsdir/prose.ts" 2>/dev/null | head -1)
  st_oldn=${st_oldn:-0}
  if [ "$st_oldn" -eq 2 ]; then
    row "selftest" "routes" "OK" "$st_oldn" "surface" \
        "the RETIRED grep counts 2 on that fixture where the truth is 1 — the #57 A5 defect, demonstrated"
  else
    row "selftest" "routes" "BAD" "$st_oldn" "surface" \
        "expected the retired grep to miscount as 2 here; got ${st_oldn} — this fixture no longer demonstrates the defect"
    st_fail=1
  fi

  # 19. THE EXIT CODE ITSELF. Every assertion above tests a pure function; none of
  #     them would notice if the exit-code block were deleted. That block is the
  #     one thing this design cites as making the external class falsifiable
  #     rather than decorative, and it was the only thing in the file with no
  #     gate on it. Runs a real sub-invocation, so it is the end-to-end behaviour
  #     being asserted and not a restatement of the source.
  st_warn_md="$WORKDIR/selftest-exit-warn.md"
  printf '# exit fixture\n\n[gone](%s)\n' \
    "https://github.com/oavcy/ogforge-selftest-404-9f3a1c" > "$st_warn_md"
  for st_case in \
    "1||WARN fails the run by default" \
    "0|--external-lenient|--external-lenient downgrades WARN to advice"
  do
    st_want=${st_case%%|*}; st_rest=${st_case#*|}
    st_flag=${st_rest%%|*}; st_desc=${st_rest#*|}
    DOCS="$st_warn_md" "$0" "$BASE" --docs-only --no-self-test $st_flag >/dev/null 2>&1
    st_rc=$?
    if [ "$st_rc" = "$st_want" ]; then
      row "selftest" "exit" "OK" "$st_rc" "sub-invocation" "$st_desc"
    else
      row "selftest" "exit" "BAD" "$st_rc" "sub-invocation" "$st_desc — got exit $st_rc, wanted $st_want"
      st_fail=1
    fi
  done
  DOCS="$WORKDIR/nothing-at-all-9f3a1c" "$0" "$BASE" --docs-only --no-self-test --no-docs >/dev/null 2>&1
  st_rc=$?
  if [ "$st_rc" = "2" ]; then
    row "selftest" "exit" "OK" "$st_rc" "sub-invocation" "a run that measured nothing aborts instead of passing"
  else
    row "selftest" "exit" "BAD" "$st_rc" "sub-invocation" "zero checks exited $st_rc — a vacuous green"
    st_fail=1
  fi

  # Coverage floor. Every check above reports its own verdict; none of them can
  # report that it did not run. If a future edit drops half the self-test, the
  # remaining half still prints OK and the run still says PASSED. This is the
  # only assertion in the file whose subject is the self-test's own size.
  # Read the count BEFORE emitting the verdict row: the row goes through row(),
  # which increments ST_ROWS, so a naive version reports a tally one higher than
  # the number it just complained about. An assertion whose own output moves its
  # subject is the house defect in miniature.
  st_rows_measured="$ST_ROWS"
  if [ "$st_rows_measured" -lt "$ST_ROWS_MIN" ]; then
    row "selftest" "meta" "BAD" "$st_rows_measured" "coverage-floor" \
      "self-test emitted ${st_rows_measured} rows, floor is ${ST_ROWS_MIN} — coverage was silently lost"
    st_fail=1
  else
    row "selftest" "meta" "OK" "$st_rows_measured" "coverage-floor" \
      "row count ${st_rows_measured} is at or above the floor of ${ST_ROWS_MIN}"
  fi

  # Cycle #27, Mutation C. The block above used to be SILENT when it passed, so
  # deleting the whole thing changed no output at all: 40/40, PASS, exit 0, tally
  # byte-identical. #26 shipped it knowing that and named it an open defect.
  # It now emits in both branches, which turns its absence from invisible into
  # arithmetic: exactly one meta row must exist, so the live counter must have
  # advanced by exactly one since it was read.
  #
  # This does NOT eliminate #26 A4's terminus ("every gate terminates in one
  # assertion nothing else checks"), and the first draft of this comment claimed
  # the two blocks check EACH OTHER. Measured, that is false. It is a chain, not
  # a mutual pair:
  #
  #   delete a real check (Mut A)  -> floor fires        -> exit 2   CAUGHT
  #   delete the floor    (Mut C)  -> this block fires   -> exit 2   CAUGHT (new)
  #   delete THIS block   (Mut E)  -> nothing fires      -> exit 0   NOT CAUGHT
  #   delete both     (Mut C+E)    -> nothing fires      -> exit 0   NOT CAUGHT
  #
  # So the terminus moved out one level; it did not disappear. What was bought:
  # the undetectable edit is no longer "delete a silent block that appears to do
  # nothing" but "delete a block whose stated purpose is to catch that deletion",
  # and Mut C+E still prints "+ 0 coverage" in the tally where a green run prints
  # "+ 1" — visible to a reader, not to the exit code. Do not add a third block
  # to guard this one; that just relabels the terminus again.
  st_meta_rows=$((ST_ROWS - st_rows_measured))
  if [ "$st_meta_rows" -ne 1 ]; then
    row "selftest" "meta" "BAD" "$st_meta_rows" "coverage-floor-ran" \
      "the coverage floor emitted ${st_meta_rows} rows, not 1 — the floor check itself is missing or duplicated"
    st_fail=1
  fi

  hr
  # ST_ROWS is read HERE, after every meta row has been emitted, so this number
  # equals the reproduce command's output in every branch. #26's version printed
  # the pre-meta count, which matched `grep -c` only when the run was green —
  # i.e. the tally disagreed with its own reproduce line exactly when something
  # was wrong. Splitting it into "checks + coverage rows" keeps the floor
  # comparison legible without lying about the total.
  echo "SELF-TEST TALLY  rows: ${ST_ROWS}   (${st_rows_measured} checks + $((ST_ROWS - st_rows_measured)) coverage)   bad: ${ST_BAD}   floor: ${ST_ROWS_MIN}"
  echo "                 reproduce with: ./scripts/check-assets.sh | grep -c '^selftest '"
  if [ "$st_fail" -ne 0 ]; then
    echo "SELF-TEST FAILED. THIS CHECKER IS UNTRUSTWORTHY — do not read anything into"
    echo "its green results. Fix the checker (or the network path to ${BASE}) first."
    return 1
  fi
  echo "SELF-TEST PASSED — the checker demonstrably goes red on bad assets and green on good ones."
  return 0
}

# --------------------------------------------------------------- page asset scan
# Extract references from one page's HTML into "<kind>\t<raw-url>" lines.
extract_refs() {
  _flat="$1"

  # Connection hints first, and — crucially — REMOVED from what the generic href
  # sweep below can see. Emitting them as "hint" is not enough on its own: the
  # bulk href= pass would pick the same URL up as a plain link, the rank dedupe
  # would keep the stricter kind, and the exclusion would quietly never fire.
  # Subtracting the tag is the only version of this that works.
  #
  # Three things this got wrong on the first attempt, all found by QA attack and
  # all in the FALSE-GREEN direction, which is the direction that matters:
  #   * `rel="preconnect stylesheet"` matched a substring test and the real
  #     stylesheet was deleted from the fetch set. rel is a TOKEN LIST; a tag is a
  #     hint only if EVERY token is a hint token. Order must not matter.
  #   * `<LINK REL=...>` matched nothing — HTML attribute names are case
  #     insensitive. Matching is done against a lowercased copy and the offsets
  #     applied to the original, which is safe because tolower preserves length.
  #   * `<link href="..." data-x="a>b" rel="preconnect">` — `[^>]*` stopped at the
  #     `>` INSIDE the attribute value, so rel fell outside the tag and the origin
  #     became a hard check that 404s. The tag pattern now steps over quoted runs.
  _AWK_HINT='
    BEGIN {
      Q = sprintf("%c", 39)
      TAG = "<link([^>\"" Q "]|\"[^\"]*\"|" Q "[^" Q "]*" Q ")*>"
      ATT = "(\"[^\"]*\"|" Q "[^" Q "]*" Q "|[^ \t>]+)"
    }
    function attr(tag, name,   v) {
      if (!match(tolower(tag), name "[ \t]*=[ \t]*" ATT)) return ""
      v = substr(tag, RSTART, RLENGTH)
      sub(/^[a-zA-Z-]+[ \t]*=[ \t]*/, "", v)
      gsub("^[\"" Q "]|[\"" Q "]$", "", v)
      return v
    }
    function is_hint(tag,   v, n, i, p, all) {
      v = tolower(attr(tag, "rel"))
      if (v == "") return 0
      n = split(v, p, /[ \t]+/)
      if (n == 0) return 0
      all = 1
      for (i = 1; i <= n; i++)
        if (p[i] != "" && p[i] != "preconnect" && p[i] != "dns-prefetch") all = 0
      return all
    }'

  awk "$_AWK_HINT"'
  {
    s = $0
    while (match(tolower(s), TAG)) {
      tag = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
      if (is_hint(tag)) { h = attr(tag, "href"); if (h != "") print "hint\t" h }
    }
  }' "$_flat" 2>/dev/null

  _nohint="${_flat}.nohint"
  awk "$_AWK_HINT"'
  {
    out = ""; s = $0
    while (match(tolower(s), TAG)) {
      pre = substr(s, 1, RSTART - 1)
      tag = substr(s, RSTART, RLENGTH)
      s   = substr(s, RSTART + RLENGTH)
      if (is_hint(tag)) tag = " "
      out = out pre tag
    }
    print out s
  }' "$_flat" 2>/dev/null > "$_nohint"
  [ -s "$_nohint" ] || cp "$_flat" "$_nohint"

  # Both quote characters, every pass. HTML permits src='...' exactly as much as
  # src="...", and for 22 cycles this extractor only knew the double-quoted form.
  # That is the same defect class as the split-element wordmark: the reference was
  # THERE, the gate simply could not see that shape of it, and an unseen reference
  # is indistinguishable from a healthy one in the summary line.
  #
  # Tag and attribute NAMES are matched case-insensitively (`-oiE`), because HTML
  # permits `<IMG SRC=...>` exactly as much as `<img src=...>`. For 27 cycles only
  # the hint detector knew that — it runs in awk over tolower(tag) — so an
  # uppercase attribute was recognised as a hint to EXCLUDE while being invisible
  # to every sweep that would have fetched it. Fixed in Cycle #28; the fixture that
  # proves it is `qa-upper-img.png` / `qa-upper-link`, and it was red first.
  # The value strip is `^[A-Za-z-]*=` rather than a literal attribute name for the
  # same reason: it cannot know the case grep matched. It stays exact because
  # `[A-Za-z-]*` cannot cross the quote, so only the real attribute name is cut.
  _sq=$(printf '\047')
  for _q in '"' "$_sq"; do
    # <img src="..."> — the category that produced the 19-cycle defect. Tracked by
    # tag, not by file extension, because /og?title=... has no extension at all.
    grep -oiE '<img[^>]*>' "$_flat" 2>/dev/null \
      | grep -oiE "src=${_q}[^${_q}]*${_q}" | sed -e "s/^[A-Za-z-]*=${_q}//" -e "s/${_q}\$//" \
      | awk '{print "image\t" $0}'
    # <link rel="icon"|"apple-touch-icon" href="...">
    grep -oiE '<link[^>]*>' "$_flat" 2>/dev/null | grep -iE "rel=${_q}[^${_q}]*icon" \
      | grep -oiE "href=${_q}[^${_q}]*${_q}" | sed -e "s/^[A-Za-z-]*=${_q}//" -e "s/${_q}\$//" \
      | awk '{print "image\t" $0}'
    # social unfurl images — these break silently and only in someone else's UI.
    # Match the URL-bearing properties EXACTLY: og:image:width/height/alt and
    # twitter:image:alt carry a number or prose, not a URL, and treating them as
    # assets produces confident nonsense like "GET /1200 -> 404".
    grep -oiE '<meta[^>]*>' "$_flat" 2>/dev/null \
      | grep -iE "(property|name)=${_q}(og:image(:(url|secure_url))?|twitter:image(:src)?)${_q}" \
      | grep -oiE "content=${_q}[^${_q}]*${_q}" | sed -e "s/^[A-Za-z-]*=${_q}//" -e "s/${_q}\$//" \
      | awk '{print "image\t" $0}'
    # every other src= (script, iframe, source, video, audio)
    grep -oiE "src=${_q}[^${_q}]*${_q}" "$_flat" 2>/dev/null \
      | sed -e "s/^[A-Za-z-]*=${_q}//" -e "s/${_q}\$//" \
      | awk '{print "asset\t" $0}'
    # every href= (stylesheets, routes, in-page nav) — from the hint-stripped copy
    grep -oiE "href=${_q}[^${_q}]*${_q}" "$_nohint" 2>/dev/null \
      | sed -e "s/^[A-Za-z-]*=${_q}//" -e "s/${_q}\$//" \
      | awk '{print "link\t" $0}'
  done
  # CSS url(...) — <style> blocks, inline style="", @font-face. A background image
  # or webfont that 404s is invisible to every check above: the page still returns
  # 200 and the missing thing is a blank area, which is exactly how /og shipped
  # broken for 19 cycles. Quotes around the value are optional in CSS, so all three
  # forms are handled. normalize_url() drops data: URIs, so inlined SVG is skipped
  # rather than probed as a path.
  grep -oE 'url\([^)]*\)' "$_flat" 2>/dev/null \
    | sed -e 's/^url(//' -e 's/)$//' \
          -e "s/^[\"${_sq}]//" -e "s/[\"${_sq}]\$//" \
          -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | while IFS= read -r _u; do
        [ -n "$_u" ] || continue
        if looks_like_image_path "$_u"; then printf 'image\t%s\n' "$_u"
        else printf 'asset\t%s\n' "$_u"; fi
      done

  # JS-CONSTRUCTED references. `fetch('/api/keys')` and `img.src = "/x.png"` are
  # references by every meaning that matters — a human sees the same broken thing
  # — and no markup pass above can see them, because there is no attribute to
  # match. Only STRING LITERALS inside <script> bodies are considered, so a regex
  # literal /foo/g is out of scope by construction.
  #
  # The filter is deliberately narrow. A URL-ish literal must be an absolute URL
  # or start "/" followed by an alphanumeric, which is what keeps `.split('/')`,
  # `'//'` and ordinary prose from being reported as broken assets. A gate that
  # invents references is worse than one that misses them: it trains you to
  # dismiss red.
  # Quote pairing cannot be done with grep, and the first version of this tried.
  # `grep -oE "'[^']*'"` over a whole script pairs the apostrophe in
  #     el.textContent = "it's done";
  # with the NEXT apostrophe in the file, which is the opening quote of
  # `fetch('/api/keys')` — and every single-quoted reference from that point on
  # silently disappears. One character, total blindness, and the summary still
  # says PASS. That is the precise defect class this whole file exists to end,
  # reintroduced by the code meant to extend it. Nothing short of a real
  # tokenizer is correct here: it tracks quote state, honours backslash escapes,
  # and skips // and /* */ comments so an apostrophe in prose ("don't") cannot
  # open a string.
  #
  # JSON-LD is excluded. `<script type="application/ld+json">` is data, not code;
  # its "url":"/api/v1" values are schema.org metadata, and probing them produced
  # confident hard 404s against paths that were never meant to be routes.
  _js="${_flat}.js"
  awk '
    BEGIN { Q = sprintf("%c", 39); BT = sprintf("%c", 96); ins = 0 }
    {
      line = $0
      while (length(line) > 0) {
        if (ins == 0) {
          if (match(tolower(line), /<script[^>]*>/)) {
            tag = tolower(substr(line, RSTART, RLENGTH))
            line = substr(line, RSTART + RLENGTH)
            ins = (tag ~ /type[ \t]*=[ \t]*["\047]?[^"\047>]*json/) ? 2 : 1
          } else line = ""
        } else {
          if (match(tolower(line), /<\/script>/)) {
            if (ins == 1) print substr(line, 1, RSTART - 1)
            line = substr(line, RSTART + RLENGTH); ins = 0
          } else { if (ins == 1) print line; line = "" }
        }
      }
    }' "$_flat" 2>/dev/null > "$_js"

  if [ -s "$_js" ]; then
    awk '
      BEGIN { Q = sprintf("%c", 39); BT = sprintf("%c", 96); blk = 0 }
      {
        s = $0; n = length(s); i = 1
        while (i <= n) {
          c = substr(s, i, 1)
          if (blk) {                                   # inside /* ... */
            if (c == "*" && substr(s, i + 1, 1) == "/") { blk = 0; i += 2 } else i++
            continue
          }
          if (c == "/" && substr(s, i + 1, 1) == "*") { blk = 1; i += 2; continue }
          if (c == "/" && substr(s, i + 1, 1) == "/") break        # // to end of line
          if (c == "\"" || c == Q || c == BT) {
            q = c; i++; lit = ""
            while (i <= n) {
              d = substr(s, i, 1)
              if (d == "\\") { lit = lit substr(s, i, 2); i += 2; continue }
              if (d == q) { i++; break }
              lit = lit d; i++
            }
            if (lit != "") print lit
            continue
          }
          i++
        }
      }' "$_js" 2>/dev/null \
      | grep -E '^(https?://[^[:space:]]+|/[A-Za-z0-9][A-Za-z0-9._~!$&*+,;=%/?#-]*)$' \
      | while IFS= read -r _u; do
          case "$_u" in *'${'*) continue ;; esac   # unresolved template literal
          if looks_like_image_path "$_u"; then printf 'image\t%s\n' "$_u"
          else printf 'asset\t%s\n' "$_u"; fi
        done
  fi
}

scan_page() {
  page_path="$1"; expected="$2"
  label=$(printf '%s' "$page_path" | cut -c1-14)
  body="$WORKDIR/body$(printf '%s' "$page_path" | tr -c 'a-zA-Z0-9' '_').html"

  page_out=$(curl -sS -L --compressed \
                  --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
                  -A "$UA" -o "$body" \
                  -w '%{http_code}|%{content_type}|%{url_effective}' "${BASE}${page_path}" 2>/dev/null)
  p_status=$(printf '%s' "$page_out" | awk -F'|' '{print $1}')
  p_ct=$(printf '%s' "$page_out" | awk -F'|' '{print $2}' | sed -e 's/;.*$//' -e 's/[[:space:]]//g')
  # This curl uses -L. Per the #39 finding, %{http_code} and friends describe
  # wherever the request ENDED UP, so the canonical must be compared against
  # url_effective and NOT against "${BASE}${page_path}" — otherwise the very
  # redirect that makes a page legitimate would be reported as a mismatch.
  p_eff=$(printf '%s' "$page_out" | awk -F'|' '{print $3}')
  [ -n "$p_eff" ] || p_eff="${BASE}${page_path}"

  echo
  echo "PAGE ${page_path}   (expected status: ${expected})"
  hr
  TOTAL=$((TOTAL + 1))
  if printf '%s' "$p_status" | grep -qE "$expected"; then
    PASSED=$((PASSED + 1))
    row "$label" "page" "PASS" "$p_status" "$p_ct" "${BASE}${page_path}"
  else
    FAILED=$((FAILED + 1))
    row "$label" "page" "FAIL" "$p_status" "$p_ct" "${BASE}${page_path}" \
        "status does not match expected ${expected}"
    printf '%s\t%s\t%s\t%s\n' "$label" "page" "${BASE}${page_path}" \
        "HTTP $p_status, expected $expected" >> "$FAILLOG"
  fi

  [ -s "$body" ] || { echo "(empty body — no references to extract)"; return; }

  # single-quoted attributes would slip past the double-quote parser entirely
  if grep -qE "(src|href)='" "$body"; then
    echo "WARNING: single-quoted src/href attributes present on this page."
    echo "         This parser only reads double-quoted attributes, so those are UNCHECKED."
  fi

  # What the page CLAIMS TO BE, as opposed to the URL that served it. (#50/#51)
  TOTAL=$((TOTAL + 1))
  page_can=$(page_canonical "$body")
  if canonical_mismatch "$body" "$p_eff"; then
    FAILED=$((FAILED + 1))
    row "$label" "head" "FAIL" "$p_status" "canonical" "$page_can" \
        "canonical names a different URL than the one that served it ($p_eff)"
    printf '%s\t%s\t%s\t%s\n' "$label" "head" "$p_eff" \
        "canonical=$page_can does not match the serving URL" >> "$FAILLOG"
  else
    PASSED=$((PASSED + 1))
    row "$label" "head" "PASS" "$p_status" "canonical" "${page_can:-none (noindex/absent — OK)}"
  fi

  # What the page SAYS, as opposed to what it is made of.
  for bad in $FORBIDDEN_TEXT; do
    TOTAL=$((TOTAL + 1))
    if render_text "$body" | grep -q "$bad"; then
      FAILED=$((FAILED + 1))
      row "$label" "text" "FAIL" "-" "rendered-text" "forbidden string '${bad}' is visible on this page"
      printf '%s\t%s\t%s\t%s\n' "$label" "text" "${BASE}${page_path}" \
        "rendered text contains '${bad}'" >> "$FAILLOG"
    else
      PASSED=$((PASSED + 1))
      row "$label" "text" "PASS" "-" "rendered-text" "no forbidden string '${bad}'"
    fi
  done

  flat="$WORKDIR/flat.html"
  tr '\n\r\t' '   ' < "$body" > "$flat"

  refs="$WORKDIR/refs.txt"
  extract_refs "$flat" > "$refs"

  # Resolve + dedupe. An <img src="/og?..."> is also picked up by the generic src=
  # pass as kind "asset", and the same URL must not be deduped down to the WEAKER
  # assertion — that would silently drop the content-type check on exactly the tag
  # that caused this script to exist. So carry an explicit rank and keep the
  # strictest kind per URL. (Alphabetical order gets this backwards: asset < image.)
  resolved="$WORKDIR/resolved.txt"
  : > "$resolved"
  while IFS="$(printf '\t')" read -r kind raw; do
    [ -n "${raw:-}" ] || continue
    if [ "$kind" = "hint" ]; then
      # rank 3 = weakest. If this exact URL is ALSO referenced for real somewhere
      # on the page, the dedupe keeps the stronger kind and it gets checked.
      printf '3\thint\t%s\n' "$raw" >> "$resolved"
      continue
    fi
    abs=$(normalize_url "$raw")
    if [ -z "$abs" ]; then
      ext=$(external_url "$raw")
      if [ -n "$ext" ] && [ "$RUN_EXTERNAL" -eq 1 ]; then
        if [ "$kind" != "image" ] && looks_like_image_path "$ext"; then kind="image"; fi
        case "$kind" in image) rank=0 ;; asset) rank=1 ;; *) rank=2 ;; esac
        printf '%s\tx:%s\t%s\n' "$rank" "$kind" "$ext" >> "$resolved"
      else
        SKIPPED=$((SKIPPED + 1))
        [ "$VERBOSE" -eq 1 ] && row "$label" "$kind" "SKIP" "-" "anchor/non-address" "$raw"
      fi
      continue
    fi
    if [ "$kind" != "image" ] && looks_like_image_path "$abs"; then kind="image"; fi
    case "$kind" in
      image) rank=0 ;;   # strictest: status AND content-type: image/*
      asset) rank=1 ;;
      *)     rank=2 ;;
    esac
    printf '%s\t%s\t%s\n' "$rank" "$kind" "$abs" >> "$resolved"
  done < "$refs"

  uniq_refs="$WORKDIR/uniq.txt"
  sort -u "$resolved" | sort -t"$(printf '\t')" -k3,3 -k1,1n \
    | awk -F'\t' '!seen[$3]++ {print $2 "\t" $3}' > "$uniq_refs"

  n=$(wc -l < "$uniq_refs" | tr -d ' ')
  if [ "$n" = "0" ]; then
    echo "(no references found on this page)"
    return
  fi
  echo "${n} distinct reference(s)  (ext = advisory, cannot fail the run):"
  while IFS="$(printf '\t')" read -r kind abs; do
    [ -n "${abs:-}" ] || continue
    case "$kind" in
      hint)  count_hint "$label" "$abs" ;;
      x:*)   check_external "$label" "${kind#x:}" "$abs" ;;
      *)     check_and_report "$label" "$kind" "$abs" ;;
    esac
  done < "$uniq_refs"
}

# ----------------------------------------------------------------- doc link scan
# Emits "<kind>\t<raw-url>". Images come from markdown image syntax and <img src>;
# every other URL is swept in bulk, which picks up markdown link targets, autolinks
# and URLs inside fenced code blocks in one pass. Overlap between the two passes is
# fine and in fact wanted — the rank-based dedupe below keeps the STRICTER kind.
# Markdown inline link/image targets, with BALANCED PAREN counting.
#
# `grep -oE '\]\([^) ]+'` truncates at the first ')' , which turns
#   [Ruby](https://en.wikipedia.org/wiki/Ruby_(programming_language))
# into a 404 for a link that is perfectly fine, and the old greedy
# `sed 's/^.*(//'` then stripped to the LAST '(' — handing the tail
# "programming_language" to the hard on-disk check as if it were a filename.
# One ordinary Wikipedia citation, two invented failures, and an error message
# that names a file nobody wrote. Depth counting is the only correct reading of
# an inline link target, so it is done in awk.
#
# mode=refs   -> print "<kind>\t<target>" for each inline link/image
# mode=blank  -> print the document with those targets blanked, so the bulk URL
#                sweep below cannot re-extract a truncated copy of the same URL.
_AWK_MDLINK='
  function emit(mode, bang, t, pre, post) {
    if (mode == "refs") {
      if (t ~ /^[ \t]*$/) return
      if (bang) print "image\t" t
      else if (t ~ /^(https?:|#|mailto:|tel:|data:)/) print "link\t" t
      else print "mdrel\t" t
    }
  }
  {
    line = $0; out = ""; i = 1; n = length(line)
    while (i <= n) {
      if (substr(line, i, 2) == "](") {
        bang = 0
        # walk back over [text] to see if this was an image ![alt](...)
        j = i - 1; depth = 1
        while (j >= 1 && depth > 0) {
          c = substr(line, j, 1)
          if (c == "]") depth++
          else if (c == "[") depth--
          j--
        }
        if (j >= 1 && substr(line, j, 1) == "!") bang = 1
        k = i + 2; d = 1; t = ""
        while (k <= n && d > 0) {
          c = substr(line, k, 1)
          if (c == "(") d++
          else if (c == ")") { d--; if (d == 0) break }
          t = t c; k++
        }
        if (d == 0) {
          emit(MODE, bang, t)
          out = out "]("
          for (z = 0; z < length(t); z++) out = out " "
          out = out ")"
          i = k + 1
          continue
        }
      }
      out = out substr(line, i, 1); i++
    }
    if (MODE == "blank") print out
  }'

extract_md_refs() {
  _f="$1"

  # Fenced code blocks are excluded from the INLINE-LINK pass only, and the
  # distinction is not cosmetic. `[x](path/to/your/file.md)` inside a fence is
  # documentation doing its job, and feeding it to the hard on-disk check failed
  # the deploy on a worked example. But a URL inside a fence is usually a command
  # the reader is told to RUN —
  #     curl -sS -o card.png https://…/brand.png
  #     git clone https://github.com/oavcy/ogforge.git
  # — and if those 404 the README is wrong in the most user-visible way there is.
  # De-fencing everything silently dropped both of those from this very repo's
  # README. Fences change what a markdown LINK means; they do not make a URL stop
  # being an address.
  _defenced="${WORKDIR}/$(basename "$_f").defenced"
  awk '/^[[:space:]]*(```|~~~)/ { f = !f; print ""; next } { print (f ? "" : $0) }' \
    "$_f" 2>/dev/null > "$_defenced"
  [ -s "$_defenced" ] || cp "$_f" "$_defenced"

  awk -v MODE=refs "$_AWK_MDLINK" "$_defenced" 2>/dev/null

  grep -oE '<img[^>]*>' "$_f" 2>/dev/null \
    | grep -oE 'src="[^"]*"' | sed -e 's/^src="//' -e 's/"$//' \
    | awk '{print "image\t" $0}'

  # Bulk sweep for autolinks, bare URLs and URLs in commands — over the WHOLE
  # document with inline-link targets blanked out, so a URL containing
  # parentheses is reported once, whole, by the depth-counting pass above rather
  # than twice with one copy truncated at the inner ')'.
  awk -v MODE=blank "$_AWK_MDLINK" "$_f" 2>/dev/null \
    | grep -oE 'https?://[^ )>"'"'"'`]+' \
    | awk '{print "link\t" $0}'
}

scan_doc() {
  doc="$1"
  label=$(basename "$doc" | cut -c1-14)

  echo
  echo "DOC ${doc}"
  hr
  if [ ! -f "$doc" ]; then
    TOTAL=$((TOTAL + 1)); FAILED=$((FAILED + 1))
    row "$label" "doc" "FAIL" "-" "-" "$doc" "file not found"
    printf '%s\t%s\t%s\t%s\n' "$label" "doc" "$doc" "file not found" >> "$FAILLOG"
    return
  fi

  refs="$WORKDIR/mdrefs.txt"
  extract_md_refs "$doc" > "$refs"

  resolved="$WORKDIR/mdresolved.txt"
  : > "$resolved"
  while IFS="$(printf '\t')" read -r kind raw; do
    [ -n "${raw:-}" ] || continue
    if is_placeholder "$raw"; then
      SKIPPED=$((SKIPPED + 1))
      row "$label" "$kind" "SKIP" "-" "placeholder" "$raw"
      continue
    fi
    abs=$(normalize_doc_url "$raw")
    if [ -z "$abs" ]; then
      case "$raw" in
        '#'*|'mailto:'*|'tel:'*|'data:'*)
          SKIPPED=$((SKIPPED + 1))
          [ "$VERBOSE" -eq 1 ] && row "$label" "$kind" "SKIP" "-" "anchor/non-address" "$raw"
          ;;
        *)
          # collapse image/mdrel duplicates of the same target onto one kind
          printf '4\trel\t%s\n' "$raw" >> "$resolved"
          ;;
      esac
      continue
    fi
    if [ "$kind" != "image" ] && looks_like_image_path "$abs"; then kind="image"; fi
    case "$kind" in
      image) rank=0 ;;
      asset) rank=1 ;;
      *)     rank=2 ;;
    esac
    # Same policy as the page scan, which is the point: off-host is advisory
    # everywhere. Before #24 this scan hard-failed on other people's hosts while
    # the page scan did not even look at them — two rules for one class.
    if [ -n "$(external_url "$abs")" ]; then
      if [ "$RUN_EXTERNAL" -eq 0 ]; then
        SKIPPED=$((SKIPPED + 1)); continue
      fi
      kind="x:${kind}"
    fi
    printf '%s\t%s\t%s\n' "$rank" "$kind" "$abs" >> "$resolved"
  done < "$refs"

  uniq_refs="$WORKDIR/mduniq.txt"
  sort -u "$resolved" | sort -t"$(printf '\t')" -k3,3 -k1,1n \
    | awk -F'\t' '!seen[$3]++ {print $2 "\t" $3}' > "$uniq_refs"

  n=$(wc -l < "$uniq_refs" | tr -d ' ')
  if [ "$n" = "0" ]; then echo "(no checkable references in this doc)"; return; fi
  echo "${n} distinct reference(s)  (ext = advisory; rel = on-disk, hard):"
  while IFS="$(printf '\t')" read -r kind abs; do
    [ -n "${abs:-}" ] || continue
    case "$kind" in
      rel)  check_relative "$label" "$doc" "$abs" ;;
      x:*)  check_external "$label" "${kind#x:}" "$abs" ;;
      *)    check_and_report "$label" "$kind" "$abs" ;;
    esac
  done < "$uniq_refs"
}

# ------------------------------------------------------------------------- main
echo "===================================================================================================="
echo " OGForge anonymous asset check"
echo " base:      ${BASE}   (host ${BASE_HOST})"
echo " credentials: NONE — no api key, no cookies, no auth header (what a human/crawler gets)"
echo " date:      $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "===================================================================================================="
echo

if [ "$MODE" = "selftest-only" ]; then
  if self_test; then exit 0; else exit 2; fi
fi

if [ "$RUN_SELFTEST" -eq 1 ]; then
  if ! self_test; then
    echo
    echo "RESULT: ABORTED — self-test failed, so no scan result would be believable."
    exit 2
  fi
fi

printf '\n%s\n' "===================================================================================================="
printf '%-14s %-6s %-4s %-4s %-26s %s\n' "PAGE" "KIND" "RES" "HTTP" "CONTENT-TYPE" "URL"

if [ "$MODE" != "docs-only" ]; then
  echo "$PAGES" | grep -v '^[[:space:]]*$' > "$WORKDIR/pages.txt"
  while IFS='|' read -r p exp; do
    [ -n "${p:-}" ] || continue
    scan_page "$p" "$exp"
  done < "$WORKDIR/pages.txt"
fi

# ---- live noindex reachability (#53) -----------------------------------------
# For every path that asks not to be indexed, robots.txt must let a crawler in to
# hear it. Runs against the live site, anonymously, like everything else here.
# Falsifiable: RED before #53's deploy (both paths were Disallow-ed while
# carrying/needing a noindex), GREEN after.
if [ "$MODE" != "docs-only" ]; then
  echo
  echo "NOINDEX REACHABILITY   (a Disallow-ed page never gets to say noindex)"
  hr
  nr_robots="$WORKDIR/live-robots.txt"
  curl -sS -L --compressed --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
       -A "$UA" -o "$nr_robots" "${BASE}/robots.txt" 2>/dev/null || :
  if [ ! -s "$nr_robots" ]; then
    # An unreadable robots.txt makes every verdict below vacuous, so say so
    # instead of printing a row of passes. (#41: never let an empty input read
    # as a clean result.)
    TOTAL=$((TOTAL + 1)); FAILED=$((FAILED + 1))
    row "robots.txt" "robots" "FAIL" "-" "noindex-reach" "${BASE}/robots.txt" \
        "robots.txt empty or unfetchable — reachability of every noindex is UNKNOWN, not OK"
    printf '%s\t%s\t%s\t%s\n' "robots.txt" "robots" "${BASE}/robots.txt" \
        "robots.txt could not be read; noindex reachability unverifiable" >> "$FAILLOG"
  else
    for nr_p in /dashboard /postmortem/hits /register /; do
      nr_h="$WORKDIR/nr-h$(printf '%s' "$nr_p" | tr -c 'a-zA-Z0-9' '_').txt"
      nr_b="$WORKDIR/nr-b$(printf '%s' "$nr_p" | tr -c 'a-zA-Z0-9' '_').out"
      curl -sS -L --compressed --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
           -A "$UA" -D "$nr_h" -o "$nr_b" "${BASE}${nr_p}" 2>/dev/null || :
      nr_lbl=$(printf '%s' "$nr_p" | cut -c1-14)
      if response_says_noindex "$nr_h" "$nr_b"; then
        TOTAL=$((TOTAL + 1))
        if robots_disallows "$nr_robots" "$nr_p"; then
          FAILED=$((FAILED + 1))
          row "$nr_lbl" "robots" "FAIL" "-" "noindex-reach" "noindex + Disallow" \
              "asks noindex but robots.txt blocks the fetch, so no crawler ever reads it"
          printf '%s\t%s\t%s\t%s\n' "$nr_lbl" "robots" "${BASE}${nr_p}" \
              "noindex directive is unreachable behind a Disallow rule" >> "$FAILLOG"
        else
          PASSED=$((PASSED + 1))
          row "$nr_lbl" "robots" "PASS" "-" "noindex-reach" "noindex, crawlable"
        fi
      else
        row "$nr_lbl" "robots" "-" "-" "noindex-reach" "no noindex directive (indexable — nothing to reach)"
      fi
    done
  fi
fi

# ---- live sitemap field discipline (#54) -------------------------------------
# The sitemap must not ship fields the consumer publishes as ignored, and any
# <lastmod> it does ship must be a date that could be true. Runs against the live
# site, anonymously. Falsifiable: RED before #54's deploy (ten ignored fields,
# two of them false), GREEN after.
if [ "$MODE" != "docs-only" ]; then
  echo
  echo "SITEMAP FIELD DISCIPLINE   (fields the consumer ignores, and dates that cannot be true)"
  hr
  sm_body="$WORKDIR/live-sitemap.xml"
  curl -sS -L --compressed --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
       -A "$UA" -o "$sm_body" "${BASE}/sitemap.xml" 2>/dev/null || :
  sm_today=$(date -u +%Y-%m-%d)
  sm_defects="$WORKDIR/sitemap-defects.txt"
  sitemap_field_defects "$sm_body" "$sm_today" > "$sm_defects"
  # `grep -c .` PRINTS 0 and EXITS 1 when there are no matches, so the obvious
  # `$(grep -c . f || echo 0)` captures BOTH the count and the fallback — sm_n
  # becomes the two-line string "0\n0", every integer test on it errors, and the
  # check reports "FAIL — 0 defect(s)". Caught by this gate on its own first run:
  # the self-test's clean fixture said 0 while the live check said FAIL, and only
  # the disagreement between them made it visible. Same family as #33 — a shell
  # construct that conflates a value with the signal that there was no value.
  # Read the count on its own, then take the first line.
  sm_n=$(grep -c . "$sm_defects" 2>/dev/null | head -1)
  sm_n=${sm_n:-0}
  sm_locs=$(grep -o '<loc>' "$sm_body" 2>/dev/null | wc -l | tr -d ' ')
  TOTAL=$((TOTAL + 1))
  if [ "$sm_n" -eq 0 ]; then
    PASSED=$((PASSED + 1))
    row "sitemap.xml" "sitemap" "PASS" "-" "field-discipline" \
        "${sm_locs} <loc>, no ignored fields, no impossible dates"
  else
    FAILED=$((FAILED + 1))
    row "sitemap.xml" "sitemap" "FAIL" "-" "field-discipline" \
        "${sm_n} defect(s) in ${BASE}/sitemap.xml"
    while IFS= read -r sm_d; do
      [ -n "$sm_d" ] || continue
      row "" "sitemap" "" "" "" "  $sm_d"
      printf '%s\t%s\t%s\t%s\n' "sitemap.xml" "sitemap" "${BASE}/sitemap.xml" "$sm_d" >> "$FAILLOG"
    done < "$sm_defects"
  fi
fi

# ---- live 401 challenge discipline (#55) -------------------------------------
# Two probes, anonymous, against the real /og. Falsifiable by measurement: both
# were RED before #55's deploy (bare 401, no challenge, no Vary).
#
# The second probe is the load-bearing one. It sends the credential in the
# `Authorization` header the challenge advertises; before #55 the server ignored
# that header entirely and answered with the no-credentials error, so a passing
# row here is the proof that the challenge is not a prop. A gate that only
# checked the header's PRESENCE would go green on a server that advertises
# Bearer and reads nothing.
if [ "$MODE" != "docs-only" ]; then
  echo
  echo "401 CHALLENGE DISCIPLINE   (RFC 9110 §15.5.2 MUST · RFC 6750 §3.1 · RFC 9111 §3.5)"
  hr
  for au_case in \
    "none|/og?title=probe||no credentials sent" \
    "invalid|/og?title=probe|Authorization: Bearer ogf_definitely_not_a_real_key|rejected Bearer credential"
  do
    au_exp=${au_case%%|*}; au_rest=${au_case#*|}
    au_path=${au_rest%%|*}; au_rest=${au_rest#*|}
    au_hdr=${au_rest%%|*}; au_desc=${au_rest#*|}
    au_file="$WORKDIR/auth-${au_exp}.hdr"
    if [ -n "$au_hdr" ]; then
      curl -sS --compressed --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
           -A "$UA" -H "$au_hdr" -D "$au_file" -o /dev/null "${BASE}${au_path}" 2>/dev/null || :
    else
      curl -sS --compressed --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
           -A "$UA" -D "$au_file" -o /dev/null "${BASE}${au_path}" 2>/dev/null || :
    fi
    au_defects="$WORKDIR/auth-${au_exp}-defects.txt"
    auth_challenge_defects "$au_file" "$au_exp" > "$au_defects"
    # Count read on its own, then head -1 (see #54's bug, noted in the self-test).
    au_n=$(grep -c . "$au_defects" 2>/dev/null | head -1)
    au_n=${au_n:-0}
    TOTAL=$((TOTAL + 1))
    if [ "$au_n" -eq 0 ]; then
      PASSED=$((PASSED + 1))
      row "/og" "auth" "PASS" "-" "challenge" "${au_desc} — conformant 401, ${au_n} defect(s)"
    else
      FAILED=$((FAILED + 1))
      row "/og" "auth" "FAIL" "-" "challenge" "${au_desc} — ${au_n} defect(s)"
      while IFS= read -r au_d; do
        [ -n "$au_d" ] || continue
        row "" "auth" "" "" "" "  $au_d"
        printf '%s\t%s\t%s\t%s\n' "/og" "auth" "${BASE}${au_path}" "$au_d" >> "$FAILLOG"
      done < "$au_defects"
    fi
  done
fi

# ---- live retry semantics (#56) ----------------------------------------------
# THE HONEST BOUND ON THIS SECTION, stated before its rows so it cannot be read
# as more than it is (#51 A4, #55 A4):
#
#   The two branches #56 fixed are NOT anonymously reachable in production. The
#   /og quota 429 needs a valid key with an exhausted allowance; the /register
#   403 needs an email already holding MAX_KEYS_PER_EMAIL keys. This cycle is
#   forbidden from registering a key, so neither can be probed from here.
#   Both were MEASURED, both directions, on a local workerd running this exact
#   source against a local D1 seeded to hit each branch — that is what the four
#   captured fixtures in the self-test are. Production behaviour is INFERRED
#   from identical source on an identical runtime. It is not measured.
#
# So these live rows assert the CONTRAPOSITIVE, which is what the anonymous
# surface can actually testify to: nothing reachable emits a 429, and nothing
# reachable carries a Retry-After that is malformed or outside the statuses the
# RFCs define it for. That is a genuine tripwire — it goes red if a future cycle
# adds a 429 to an anonymous path — and it is NOT a proof of the fix.
#
# The /register probe is the one live row that reaches a handler #56 edited. It
# POSTs a deliberately invalid email. That path returns 400 from the EMAIL_RE
# guard, which sits ahead of every INSERT in the handler, so it writes nothing:
# no tier_interest row, no users upsert, no key. Verified by reading the handler
# and by re-counting `users` after the probe.
if [ "$MODE" != "docs-only" ]; then
  echo
  echo "RETRY SEMANTICS   (RFC 6585 §4 · RFC 9110 §10.2.3, §15.5.4, §15.5.10)"
  hr
  for rt_case in \
    "/|GET|anonymous landing page" \
    "/register|GET|the signup form" \
    "/og?title=probe|GET|the metered route, unauthenticated" \
    "/postmortem/hits|GET|the JSON gauge" \
    "/health|GET|liveness" \
    "/register|POST|the changed handler, via its pre-INSERT 400 guard"
  do
    rt_path=${rt_case%%|*}; rt_rest=${rt_case#*|}
    rt_meth=${rt_rest%%|*}; rt_desc=${rt_rest#*|}
    rt_file="$WORKDIR/retry-$(printf '%s' "${rt_meth}${rt_path}" | tr -c 'A-Za-z0-9' '-').hdr"
    if [ "$rt_meth" = "POST" ]; then
      curl -sS --compressed --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
           -A "$UA" -X POST --data-urlencode 'email=ogforge-gate-probe-no-at-sign' \
           --data-urlencode 'keyname=gate' \
           -D "$rt_file" -o /dev/null "${BASE}${rt_path}" 2>/dev/null || :
    else
      curl -sS --compressed --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
           -A "$UA" -D "$rt_file" -o /dev/null "${BASE}${rt_path}" 2>/dev/null || :
    fi
    # Every anonymously reachable response is, by construction, NOT one of the
    # two permanent/metered branches — so `transient` is the right expectation
    # and a 429 appearing here at all is what this row is watching for.
    rt_defects="$WORKDIR/retry-defects-$$.txt"
    retry_semantics_defects "$rt_file" "transient" > "$rt_defects"
    rt_st=$(grep -i '^HTTP/' "$rt_file" 2>/dev/null | tail -1 | tr -d '\r' | awk '{print $2}')
    rt_n=$(grep -c . "$rt_defects" 2>/dev/null | head -1)
    rt_n=${rt_n:-0}
    TOTAL=$((TOTAL + 1))
    if [ "$rt_n" -eq 0 ]; then
      PASSED=$((PASSED + 1))
      row "$rt_meth $rt_path" "retry" "PASS" "${rt_st:-?}" "semantics" \
          "${rt_desc} — no 429, no stray Retry-After"
    else
      FAILED=$((FAILED + 1))
      row "$rt_meth $rt_path" "retry" "FAIL" "${rt_st:-?}" "semantics" "${rt_desc} — ${rt_n} defect(s)"
      while IFS= read -r rt_d; do
        [ -n "$rt_d" ] || continue
        row "" "retry" "" "" "" "  $rt_d"
        printf '%s\t%s\t%s\t%s\n' "$rt_path" "retry" "${BASE}${rt_path}" "$rt_d" >> "$FAILLOG"
      done < "$rt_defects"
    fi
  done
fi

# ---- live method semantics (#57) ---------------------------------------------
# WHAT THIS SECTION CAN DO THAT #56's COULD NOT: go red against live production.
# #56's two fixed branches needed a credential no anonymous prober has, so its
# live rows could only assert a contrapositive and its falsifiability rested on
# captured fixtures. This cycle's fix is reachable by anyone with curl. Every
# `disclosed` row below returned 404-with-no-Allow from production before this
# cycle's deploy and returns 405-with-Allow after it, so each one is a real
# before/after measurement rather than an inference.
#
# The last row is the over-fire control, and it catches the most likely way this
# change goes wrong: a fix that turns EVERYTHING into a 405 would still make
# every row above it green. `absent` pins that a path with no route at all still
# tells the truth — a change that broke it would be invisible to the rows above.
if [ "$MODE" != "docs-only" ]; then
  echo
  echo "METHOD SEMANTICS   (RFC 9110 §15.5.5 · §15.5.6 MUST · §10.2.1 MUST · §9.1)"
  hr
  # EVERY registered path, not a chosen six (#59). #57 probed six and #58 named
  # the gap in writing: "ROUTE SURFACE reads the SOURCE — it proves the pair set
  # is what we wrote, not that the router registered it. Only METHOD SEMANTICS
  # testifies about the router, and it probes 6 of 16 paths."
  #
  # THE PATH LIST AND THE PROBE METHOD ARE BOTH DERIVED, NOT TYPED. A hand-kept
  # list of six paths and their probe methods is a second source of truth free to
  # drift from the first (#43: a comment is not an implementation), and its
  # failure mode is silence — add a seventeenth route and a typed list keeps
  # passing while saying nothing about it. The paths come from derive_allow_map()
  # and the probe method is the first one this path does NOT register, so a new
  # route is probed the first time the gate runs after it is added.
  #
  # DERIVED FROM THE LITERAL, NOT FROM src/index.ts. See expected_route_pairs():
  # deriving it from the source would move the expectation and the router in step
  # on every route change, and this edge would never be able to fail alone.
  mm_pairs="$WORKDIR/method-routes.txt"
  mm_map="$WORKDIR/method-allow-derived.txt"
  expected_route_pairs > "$mm_pairs"
  derive_allow_map "$mm_pairs" > "$mm_map"
  mm_derived=$(grep -c . "$mm_map" 2>/dev/null | head -1); mm_derived=${mm_derived:-0}
  mm_probed=0

  # THE GUARD THAT MAKES THE LOOP'S SILENCE AUDIBLE, and it goes first on purpose.
  # A `for`/`while` over an empty list runs zero times, adds zero checks, fails
  # nothing, and the SUMMARY line still reads PASS. That is the cheapest way this
  # entire section becomes decorative: break route_pairs' matcher, or point
  # REPO_ROOT somewhere without src/index.ts, and sixteen assertions evaporate
  # without a single red row. Assert the derivation is non-empty BEFORE trusting
  # anything derived from it.
  TOTAL=$((TOTAL + 1))
  if [ "$mm_derived" -eq 0 ]; then
    FAILED=$((FAILED + 1))
    row "src/index.ts" "method" "FAIL" "0" "derivation" \
        "derived Allow for ZERO paths — the loop below would probe nothing and report nothing"
    printf '%s\t%s\t%s\t%s\n' "src/index.ts" "method" "$REPO_ROOT/src/index.ts" \
      "derive_allow_map produced no paths" >> "$FAILLOG"
  else
    PASSED=$((PASSED + 1))
    row "src/index.ts" "method" "PASS" "$mm_derived" "derivation" \
        "expected Allow derived from source for ${mm_derived} paths — every one is probed below"
  fi

  while IFS="$(printf '\t')" read -r mm_path mm_allow; do
    [ -n "$mm_path" ] || continue
    mm_probed=$((mm_probed + 1))
    mm_exp="disclosed"
    mm_desc="declared: ${mm_allow}"
    # Pick a method this path does not register. Comma-fenced and space-free so
    # membership is exact: a bare *GET* also matches TARGET (#57's normalisation).
    mm_fence=",$(printf '%s' "$mm_allow" | tr -d ' '),"
    mm_meth=""
    for mm_cand in PUT DELETE PATCH OPTIONS POST GET; do
      case "$mm_fence" in
        *",${mm_cand},"*) ;;
        *) mm_meth="$mm_cand"; break ;;
      esac
    done
    # Unreachable while any method stays unregistered somewhere, but a path that
    # registered all six would otherwise be probed with an EMPTY method string,
    # and curl -X '' sends GET — a silent pass on a row that tested nothing.
    if [ -z "$mm_meth" ]; then
      TOTAL=$((TOTAL + 1)); FAILED=$((FAILED + 1))
      row "$mm_path" "method" "FAIL" "-" "semantics" \
          "no unregistered method left to probe with; this row would have tested nothing"
      printf '%s\t%s\t%s\t%s\n' "$mm_path" "method" "${BASE}${mm_path}" \
        "no unregistered probe method available" >> "$FAILLOG"
      continue
    fi
    mm_file="$WORKDIR/method-$(printf '%s' "${mm_meth}${mm_path}" | tr -c 'A-Za-z0-9' '-').hdr"
    # -X on its own sends the method with no body and does not follow redirects.
    # NEVER add -L here: #39: -w/-D would then describe whatever answered last.
    curl -sS --compressed --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
         -A "$UA" -X "$mm_meth" -D "$mm_file" -o /dev/null "${BASE}${mm_path}" 2>/dev/null || :
    mm_defects="$WORKDIR/method-defects-$$.txt"
    method_semantics_defects "$mm_file" "$mm_meth" "$mm_exp" "$mm_allow" > "$mm_defects"
    mm_st=$(grep -i '^HTTP/' "$mm_file" 2>/dev/null | tail -1 | tr -d '\r' | awk '{print $2}')
    # Count on its own line, then head -1 (#54: `grep -c` prints 0 AND exits 1).
    mm_n=$(grep -c . "$mm_defects" 2>/dev/null | head -1)
    mm_n=${mm_n:-0}
    TOTAL=$((TOTAL + 1))
    if [ "$mm_n" -eq 0 ]; then
      PASSED=$((PASSED + 1))
      # Print the Allow value beside the verdict so the two can contradict each
      # other in the transcript (#54 A4) rather than the verdict standing alone.
      mm_al=$(grep -i '^Allow:' "$mm_file" 2>/dev/null | head -1 | tr -d '\r' \
              | sed -e 's/^[Aa]llow:[[:space:]]*//')
      row "$mm_meth $mm_path" "method" "PASS" "${mm_st:-?}" "semantics" \
          "${mm_desc} — Allow: [${mm_al:-none}]"
    else
      FAILED=$((FAILED + 1))
      row "$mm_meth $mm_path" "method" "FAIL" "${mm_st:-?}" "semantics" "${mm_desc} — ${mm_n} defect(s)"
      while IFS= read -r mm_d; do
        [ -n "$mm_d" ] || continue
        row "" "method" "" "" "" "  $mm_d"
        printf '%s\t%s\t%s\t%s\n' "$mm_path" "method" "${BASE}${mm_path}" "$mm_d" >> "$FAILLOG"
      done < "$mm_defects"
    fi
    # Redirected, never piped: a `... | while read` loop runs in a subshell and
    # every TOTAL/PASSED/FAILED increment above would be discarded at `done`,
    # leaving a section that prints sixteen rows and contributes zero checks.
  done < "$mm_map"

  # THE COVERAGE ROW (#44 A1: a number without its coverage is not a measurement).
  # The rows above can only testify about paths the loop actually reached. If the
  # map holds sixteen paths and the loop ran four times — a truncated read, a
  # path containing a newline, an early `continue` — the four would all pass and
  # the transcript would look complete. Stating both numbers lets them disagree.
  TOTAL=$((TOTAL + 1))
  if [ "$mm_probed" -eq "$mm_derived" ] && [ "$mm_derived" -gt 0 ]; then
    PASSED=$((PASSED + 1))
    row "src/index.ts" "method" "PASS" "$mm_probed" "coverage" \
        "probed ${mm_probed} of ${mm_derived} declared paths live — #58 probed 6 of 16"
  else
    FAILED=$((FAILED + 1))
    row "src/index.ts" "method" "FAIL" "$mm_probed" "coverage" \
        "probed ${mm_probed} of ${mm_derived} declared paths — the untouched ones are unverified, not clean"
    printf '%s\t%s\t%s\t%s\n' "src/index.ts" "method" "$REPO_ROOT/src/index.ts" \
      "probed ${mm_probed} of ${mm_derived} declared paths" >> "$FAILLOG"
  fi

  # THE OVER-FIRE CONTROL, and it is not decorative just because all sixteen rows
  # above now assert an exact value. Those rows are all drawn from the derived
  # map, so every one of them describes a path that HAS a route; none of them can
  # notice a change that starts answering 405 for paths that have none. A blanket
  # `return 405` would satisfy sixteen exact-value assertions only if it also
  # guessed each Allow — but the realistic wrong turn is looser than that: widen
  # the lookup (a prefix match, a trailing-slash fallback, a catch-all) and the
  # sixteen keep passing while a nonexistent path starts claiming methods.
  mm_ctlpath="/ogforge-gate-no-such-path"
  mm_ctlfile="$WORKDIR/method-control.hdr"
  curl -sS --compressed --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
       -A "$UA" -X POST -D "$mm_ctlfile" -o /dev/null "${BASE}${mm_ctlpath}" 2>/dev/null || :
  mm_ctldef="$WORKDIR/method-control-defects-$$.txt"
  # `-` for the expected Allow: the `absent` branch asserts there is NO Allow at
  # all, so there is nothing to compare a derived value against.
  method_semantics_defects "$mm_ctlfile" "POST" "absent" "-" > "$mm_ctldef"
  mm_ctlst=$(grep -i '^HTTP/' "$mm_ctlfile" 2>/dev/null | tail -1 | tr -d '\r' | awk '{print $2}')
  mm_ctln=$(grep -c . "$mm_ctldef" 2>/dev/null | head -1); mm_ctln=${mm_ctln:-0}
  TOTAL=$((TOTAL + 1))
  if [ "$mm_ctln" -eq 0 ]; then
    PASSED=$((PASSED + 1))
    row "POST $mm_ctlpath" "method" "PASS" "${mm_ctlst:-?}" "semantics" \
        "over-fire control: no route, so 404 with no Allow is the TRUE answer"
  else
    FAILED=$((FAILED + 1))
    row "POST $mm_ctlpath" "method" "FAIL" "${mm_ctlst:-?}" "semantics" \
        "over-fire control tripped — ${mm_ctln} defect(s)"
    while IFS= read -r mm_d; do
      [ -n "$mm_d" ] || continue
      row "" "method" "" "" "" "  $mm_d"
      printf '%s\t%s\t%s\t%s\n' "$mm_ctlpath" "method" "${BASE}${mm_ctlpath}" "$mm_d" >> "$FAILLOG"
    done < "$mm_ctldef"
  fi
fi

# ---- live cache semantics (#58) ----------------------------------------------
# THE BOUND, before the rows (#51 A4, #55 A4, #56's section header).
#
#   MEASURED: three of the four fixed branches are anonymously reachable and
#   were 200/404-with-no-Cache-Control against live production before this
#   cycle's deploy and carry no-store after it. The fourth — /dashboard with a
#   VALID key — needs a credential no anonymous prober has, and this cycle is
#   forbidden from registering one in production. Munger's review rejected
#   shipping it INFERRED when a measurement was available: it was executed both
#   directions on a local workerd running this exact source against a local D1
#   seeded with one api_keys row (pre: no Cache-Control, post: no-store). That
#   is a measurement of the branch, not of production.
#
#   NOT MEASURED, AND NOT MEASURABLE FROM HERE: that any cache would have
#   stored any of these. We emit no ETag, no Last-Modified and no Expires, so a
#   heuristic has nothing to compute from; cf-cache-status was absent from all
#   sixteen rows of the sweep; and we read our own endpoints with curl, which
#   has no cache. This section proves an obligation is now met. It does NOT
#   prove a stale read was ever prevented, and a record claiming so would be a
#   fabricated harm.
#
# The three `heuristic` rows are the over-fire control and they are the reason
# this section can go red. /dashboard-with-no-key is the sharpest of them: it is
# the SAME ROUTE as two of the fixed rows, one call site away, so it fails on
# exactly the wrong implementation this fix invites — one header for the route.
if [ "$MODE" != "docs-only" ]; then
  echo
  echo "CACHE SEMANTICS   (RFC 9111 §4.2.2 · §5.2.2.5 · RFC 9110 §15.1)"
  hr
  for cs_case in \
    "/health|no-store|liveness: the body IS the current time" \
    "/postmortem/hits|no-store|a live counter; its value is the count as of now" \
    "/dashboard?key=ogforge-gate-no-such-key|no-store|a key-dependent 404 — one caller's verdict" \
    "/|heuristic|over-fire control: the landing page must stay storable" \
    "/register|heuristic|over-fire control: a static form must stay storable" \
    "/dashboard|heuristic|over-fire control, SAME ROUTE as two rows above — catches a route-wide header"
  do
    cs_path=${cs_case%%|*}; cs_rest=${cs_case#*|}
    cs_exp=${cs_rest%%|*};  cs_desc=${cs_rest#*|}
    cs_file="$WORKDIR/cache-$(printf '%s' "$cs_path" | tr -c 'A-Za-z0-9' '-').hdr"
    # NEVER -L (#39): -D would then describe whatever answered last.
    curl -sS --compressed --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
         -A "$UA" -D "$cs_file" -o /dev/null "${BASE}${cs_path}" 2>/dev/null || :
    cs_defects="$WORKDIR/cache-defects-$$.txt"
    cache_semantics_defects "$cs_file" "$cs_exp" > "$cs_defects"
    cs_st=$(grep -i '^HTTP/' "$cs_file" 2>/dev/null | tail -1 | tr -d '\r' | awk '{print $2}')
    cs_n=$(grep -c . "$cs_defects" 2>/dev/null | head -1); cs_n=${cs_n:-0}
    TOTAL=$((TOTAL + 1))
    if [ "$cs_n" -eq 0 ]; then
      PASSED=$((PASSED + 1))
      # Print the value beside the verdict so the two can contradict each other
      # in the transcript rather than the verdict standing alone (#54 A4).
      cs_cc=$(grep -i '^Cache-Control:' "$cs_file" 2>/dev/null | head -1 | tr -d '\r' \
              | sed -e 's/^[Cc]ache-[Cc]ontrol:[[:space:]]*//')
      row "$cs_path" "cache" "PASS" "${cs_st:-?}" "semantics" \
          "${cs_desc} — Cache-Control: [${cs_cc:-none}]"
    else
      FAILED=$((FAILED + 1))
      row "$cs_path" "cache" "FAIL" "${cs_st:-?}" "semantics" "${cs_desc} — ${cs_n} defect(s)"
      while IFS= read -r cs_d; do
        [ -n "$cs_d" ] || continue
        row "" "cache" "" "" "" "  $cs_d"
        printf '%s\t%s\t%s\t%s\n' "$cs_path" "cache" "${BASE}${cs_path}" "$cs_d" >> "$FAILLOG"
      done < "$cs_defects"
    fi
  done
fi

# ---- route surface (#57 A5, fixed here) --------------------------------------
# WHAT WAS WRONG WITH THE OLD INVARIANT. For twenty-three cycles the public
# surface was asserted by two greps pasted into consensus.md:
#
#   grep -oE 'app\.(get|post|put|delete|all)\([^,)]*' src/index.ts | … | wc -l   # 16
#   grep -cE 'app\.(get|post|put|delete|all)\('       src/index.ts               # 18
#
# Two defects, both found by #57 and both fixed here rather than in the cycle
# whose work the instrument certified:
#
#  1. IT MATCHES PROSE. A comment #57 drafted contained the literal `app.get(`
#     and moved the numbers to 17/19. It counts STRINGS IN A FILE, not routes in
#     a router — #37's question ("is this command the program its name implies?")
#     aimed at a grep. Fixed by stripping line comments before matching, which
#     the self-test pins with a fixture containing exactly that prose.
#  2. IT UNDER-MEASURED BY CONSTRUCTION. #57 turned route registration into
#     automatic public disclosure: every registered path now publishes its
#     methods in an `Allow` header. The observable surface grew by fifteen
#     declarations and both numbers sat still, because neither counts methods.
#     Fixed by counting METHOD/PATH PAIRS and printing the derived Allow set —
#     the thing a stranger can actually observe.
#
# It is asserted as a SET, not a count. A count says two numbers matched; a set
# says which pairs, so a route swapped for another cannot cancel out. The count
# is printed beside it so the two can contradict each other (#54 A4).
#
# NOT DONE HERE, AND NAMED SO IT IS NOT MISTAKEN FOR DONE: this reads the
# source, so it proves the pair set is what we wrote — not that the router
# registered it. #57's METHOD SEMANTICS section probes six of these paths live
# and is the only part that testifies about the router. Extending that to all
# sixteen is the next rung and is #59's, not a same-cycle addition to the
# instrument that just certified this cycle.
if [ "$MODE" != "docs-only" ] && [ -f "$REPO_ROOT/src/index.ts" ]; then
  echo
  echo "ROUTE SURFACE   (#57 A5 — method/path pairs, comments stripped)"
  hr
  rs_expected="$WORKDIR/routes-expected.txt"
  rs_actual="$WORKDIR/routes-actual.txt"
  # The literal each side is compared against — now defined once, near the top,
  # because METHOD SEMANTICS anchors its live expectation to the SAME list (#59).
  # When it lived only here, the live check had nothing to anchor to but the
  # source it was supposed to be independent of.
  expected_route_pairs > "$rs_expected"
  route_pairs "$REPO_ROOT/src/index.ts" > "$rs_actual"
  rs_n=$(grep -c . "$rs_actual" 2>/dev/null | head -1); rs_n=${rs_n:-0}
  rs_want=$(grep -c . "$rs_expected" 2>/dev/null | head -1); rs_want=${rs_want:-0}
  rs_paths=$(awk '{print $2}' "$rs_actual" 2>/dev/null | sort -u | grep -c . | head -1)
  rs_paths=${rs_paths:-0}
  TOTAL=$((TOTAL + 1))
  # An empty extraction is the failure this whole file exists to catch: it would
  # otherwise diff clean against nothing and read as a pass (#41).
  if [ "$rs_n" -eq 0 ]; then
    FAILED=$((FAILED + 1))
    row "src/index.ts" "routes" "FAIL" "0" "surface" \
        "extracted ZERO route pairs — the matcher is broken, not the source"
    printf '%s\t%s\t%s\t%s\n' "src/index.ts" "routes" "$REPO_ROOT/src/index.ts" \
      "zero pairs extracted" >> "$FAILLOG"
  elif diff -q "$rs_expected" "$rs_actual" >/dev/null 2>&1; then
    PASSED=$((PASSED + 1))
    row "src/index.ts" "routes" "PASS" "$rs_n" "surface" \
        "${rs_n} method/path pairs over ${rs_paths} distinct paths, exact set match"
  else
    FAILED=$((FAILED + 1))
    row "src/index.ts" "routes" "FAIL" "$rs_n" "surface" \
        "surface changed: ${rs_n} pairs / ${rs_paths} paths, expected ${rs_want} — update the literal in this script in the same commit"
    diff "$rs_expected" "$rs_actual" 2>/dev/null | while IFS= read -r rs_d; do
      case "$rs_d" in
        '<'*|'>'*) row "" "routes" "" "" "" "  $rs_d" ;;
      esac
    done
    printf '%s\t%s\t%s\t%s\n' "src/index.ts" "routes" "$REPO_ROOT/src/index.ts" \
      "route pair set differs from the asserted literal" >> "$FAILLOG"
  fi
  # The Allow surface #57 created and the old greps could not see. It is no
  # longer "printed, not asserted" — that phrase was this file's own description
  # of a gap it could not see (#59). derive_allow_map() is now the single
  # derivation, and METHOD SEMANTICS asserts each of these values against the
  # live router. Printed here from `rs_actual` — the SOURCE side — so this
  # listing and the live assertion read from opposite ends of the same claim.
  #
  # The inline version this replaces tested `case " $rs_set " in *" GET "*`
  # against a NEWLINE-separated list, so /register and /interest printed
  # "GET, POST" while production served "GET, HEAD, POST": self-consistent and
  # wrong, caught only by comparing it against live values measured elsewhere in
  # the cycle (#51). Folding it into one function is what stops that from being
  # possible in one place and not the other.
  echo "  derived Allow surface (${rs_paths} paths, HEAD synthesized where GET is registered):"
  derive_allow_map "$rs_actual" | while IFS="$(printf '\t')" read -r rs_p rs_a; do
    printf '    %-42s Allow: %s\n' "$rs_p" "$rs_a"
  done
fi

if [ "$RUN_DOCS" -eq 1 ]; then
  for d in $DOCS; do
    case "$d" in
      /*) scan_doc "$d" ;;
      *)  scan_doc "${REPO_ROOT}/${d}" ;;
    esac
  done
fi

echo
echo "===================================================================================================="
echo "SUMMARY   checks: ${TOTAL}   passed: ${PASSED}   failed: ${FAILED}   skipped(anchor/placeholder): ${SKIPPED}"
echo "ADVISORY  external: ${EXT_TOTAL}   ok: ${EXT_OK}   gone(WARN): ${EXT_WARN}   unreachable(NOTE): ${EXT_NOTE}   |   hints not fetched: ${HINTS}"
if [ "$EXT_WARN_FAILS" -eq 1 ]; then
  echo "          WARN fails the run (our citation is gone). NOTE never does (their outage). --external-lenient to downgrade."
else
  echo "          --external-lenient: WARN is advice only this run. NOTE never fails in any mode."
fi
echo "===================================================================================================="

if [ "$EXT_TOTAL" -gt 0 ] && [ $((EXT_WARN + EXT_NOTE)) -ne 0 ]; then
  echo
  echo "ADVISORY FINDINGS ($((EXT_WARN + EXT_NOTE))):"
  awk -F'\t' '{printf "  %-4s [%s] %-6s %s\n              %s\n", $1, $2, $3, $4, $5}' "$EXTLOG"
  echo "  WARN = the cited resource is gone; our page is now wrong."
  echo "  NOTE = their host is down or unreachable; not a defect in this repo."
fi

# A gate that checked zero things and printed PASS is the purest form of the
# defect this file is about. `--docs-only --no-docs` reaches it; so does an empty
# DOCS. Green must mean "something was measured and it was fine".
if [ $((TOTAL + EXT_TOTAL)) -eq 0 ]; then
  echo
  echo "RESULT: ABORTED — zero references were checked. A green run that measured"
  echo "nothing is not evidence. Check the flags/DOCS you passed."
  exit 2
fi

if [ "$FAILED" -ne 0 ]; then
  echo
  echo "FAILURES (${FAILED}):"
  awk -F'\t' '{printf "  [%s] %-6s %s\n         %s\n", $1, $2, $3, $4}' "$FAILLOG"
  echo
  echo "RESULT: FAIL"
  exit 1
fi

if [ "$EXT_WARN_FAILS" -eq 1 ] && [ "$EXT_WARN" -ne 0 ]; then
  echo
  echo "RESULT: FAIL (${EXT_WARN} external citation(s) gone — pass --external-lenient to downgrade)"
  exit 1
fi

echo
echo "RESULT: PASS"
exit 0
