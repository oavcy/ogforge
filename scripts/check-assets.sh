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
#   ./scripts/check-assets.sh [BASE_URL] [--self-test] [--no-self-test] [--verbose]
#
# EXIT CODES
#   0  everything passed
#   1  at least one page or asset failed
#   2  the checker itself is untrustworthy (self-test misbehaved) or bad usage

set -u

DEFAULT_BASE="https://snapog.aoadmin.workers.dev"
BASE=""
MODE="full"        # full | selftest-only
RUN_SELFTEST=1
VERBOSE=0

# A real browser UA: we are reproducing what a HUMAN visitor sees, and some
# origins vary behaviour by UA. Crucially we send NO credentials of any kind.
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"

MAX_TIME=25
CONNECT_TIMEOUT=10

while [ $# -gt 0 ]; do
  case "$1" in
    --self-test)    MODE="selftest-only" ;;
    --no-self-test) RUN_SELFTEST=0 ;;
    --verbose|-v)   VERBOSE=1 ;;
    -h|--help)      sed -n '2,40p' "$0"; exit 0 ;;
    -*)             echo "unknown flag: $1" >&2; exit 2 ;;
    *)              BASE="$1" ;;
  esac
  shift
done

[ -n "$BASE" ] || BASE="$DEFAULT_BASE"
BASE="${BASE%/}"                       # strip trailing slash
BASE_HOST=$(printf '%s' "$BASE" | sed -e 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' -e 's#/.*$##')

command -v curl >/dev/null 2>&1 || { echo "FATAL: curl not found" >&2; exit 2; }

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
/definitely-not-a-real-page-9f3a1c|^404$
'

# ------------------------------------------------------------------- output state
TOTAL=0; PASSED=0; FAILED=0; SKIPPED=0
FAILLOG="$WORKDIR/failures.txt"
: > "$FAILLOG"

row() { # page kind verdict status ct url reason
  printf '%-14s %-6s %-4s %-4s %-26s %s%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "${7:+  <-- $7}"
}

hr() { printf '%s\n' "----------------------------------------------------------------------------------------------------"; }

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

looks_like_image_path() {
  printf '%s' "$1" | sed -e 's/?.*$//' \
    | grep -qiE '\.(png|jpe?g|gif|svg|webp|avif|ico|bmp|apng)$'
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

  hr
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
  # <img src="..."> — the category that produced the 19-cycle defect. Tracked by
  # tag, not by file extension, because /og?title=... has no extension at all.
  grep -oE '<img[^>]*>' "$_flat" 2>/dev/null \
    | grep -oE 'src="[^"]*"' | sed -e 's/^src="//' -e 's/"$//' \
    | awk '{print "image\t" $0}'
  # <link rel="icon"|"apple-touch-icon" href="...">
  grep -oE '<link[^>]*>' "$_flat" 2>/dev/null | grep -iE 'rel="[^"]*icon' \
    | grep -oE 'href="[^"]*"' | sed -e 's/^href="//' -e 's/"$//' \
    | awk '{print "image\t" $0}'
  # social unfurl images — these break silently and only in someone else's UI.
  # Match the URL-bearing properties EXACTLY: og:image:width/height/alt and
  # twitter:image:alt carry a number or prose, not a URL, and treating them as
  # assets produces confident nonsense like "GET /1200 -> 404".
  grep -oE '<meta[^>]*>' "$_flat" 2>/dev/null \
    | grep -iE '(property|name)="(og:image(:(url|secure_url))?|twitter:image(:src)?)"' \
    | grep -oE 'content="[^"]*"' | sed -e 's/^content="//' -e 's/"$//' \
    | awk '{print "image\t" $0}'
  # every other src= (script, iframe, source, video, audio)
  grep -oE 'src="[^"]*"' "$_flat" 2>/dev/null | sed -e 's/^src="//' -e 's/"$//' \
    | awk '{print "asset\t" $0}'
  # every href= (stylesheets, routes, in-page nav)
  grep -oE 'href="[^"]*"' "$_flat" 2>/dev/null | sed -e 's/^href="//' -e 's/"$//' \
    | awk '{print "link\t" $0}'
}

scan_page() {
  page_path="$1"; expected="$2"
  label=$(printf '%s' "$page_path" | cut -c1-14)
  body="$WORKDIR/body$(printf '%s' "$page_path" | tr -c 'a-zA-Z0-9' '_').html"

  page_out=$(curl -sS -L --compressed \
                  --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
                  -A "$UA" -o "$body" \
                  -w '%{http_code}|%{content_type}' "${BASE}${page_path}" 2>/dev/null)
  p_status=$(printf '%s' "$page_out" | awk -F'|' '{print $1}')
  p_ct=$(printf '%s' "$page_out" | awk -F'|' '{print $2}' | sed -e 's/;.*$//' -e 's/[[:space:]]//g')

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
    abs=$(normalize_url "$raw")
    if [ -z "$abs" ]; then
      SKIPPED=$((SKIPPED + 1))
      [ "$VERBOSE" -eq 1 ] && row "$label" "$kind" "SKIP" "-" "external/anchor" "$raw"
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
    echo "(no local references found on this page)"
    return
  fi
  echo "${n} distinct local reference(s):"
  while IFS="$(printf '\t')" read -r kind abs; do
    [ -n "${abs:-}" ] || continue
    check_and_report "$label" "$kind" "$abs"
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

echo "$PAGES" | grep -v '^[[:space:]]*$' > "$WORKDIR/pages.txt"
while IFS='|' read -r p exp; do
  [ -n "${p:-}" ] || continue
  scan_page "$p" "$exp"
done < "$WORKDIR/pages.txt"

echo
echo "===================================================================================================="
echo "SUMMARY   checks: ${TOTAL}   passed: ${PASSED}   failed: ${FAILED}   skipped(external/anchor): ${SKIPPED}"
echo "===================================================================================================="
if [ "$FAILED" -ne 0 ]; then
  echo
  echo "FAILURES (${FAILED}):"
  awk -F'\t' '{printf "  [%s] %-6s %s\n         %s\n", $1, $2, $3, $4}' "$FAILLOG"
  echo
  echo "RESULT: FAIL"
  exit 1
fi
echo
echo "RESULT: PASS"
exit 0
