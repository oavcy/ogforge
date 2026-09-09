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

  # 17. THE EXIT CODE ITSELF. Every assertion above tests a pure function; none of
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
