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
#   of reading that file did not catch it; one fetch did. Note the difference in
#   scope from the HTML scan: on our own site an external link is somebody else's
#   problem, but in a doc an EXTERNAL link is exactly the kind that rots, so the
#   doc scan follows external hosts too.
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
#
# EXIT CODES
#   0  everything passed
#   1  at least one page, asset or doc link failed
#   2  the checker itself is untrustworthy (self-test misbehaved) or bad usage

set -u

DEFAULT_BASE="https://snapog.aoadmin.workers.dev"
BASE=""
MODE="full"        # full | selftest-only | docs-only
RUN_SELFTEST=1
RUN_DOCS=1
VERBOSE=0

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
    -h|--help)      sed -n '2,50p' "$0"; exit 0 ;;
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
    printf '![a card](%s/definitely-missing-asset.png)\n' "$BASE"
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
  # Both quote characters, every pass. HTML permits src='...' exactly as much as
  # src="...", and for 22 cycles this extractor only knew the double-quoted form.
  # That is the same defect class as the split-element wordmark: the reference was
  # THERE, the gate simply could not see that shape of it, and an unseen reference
  # is indistinguishable from a healthy one in the summary line.
  _sq=$(printf '\047')
  for _q in '"' "$_sq"; do
    # <img src="..."> — the category that produced the 19-cycle defect. Tracked by
    # tag, not by file extension, because /og?title=... has no extension at all.
    grep -oE '<img[^>]*>' "$_flat" 2>/dev/null \
      | grep -oE "src=${_q}[^${_q}]*${_q}" | sed -e "s/^src=${_q}//" -e "s/${_q}\$//" \
      | awk '{print "image\t" $0}'
    # <link rel="icon"|"apple-touch-icon" href="...">
    grep -oE '<link[^>]*>' "$_flat" 2>/dev/null | grep -iE "rel=${_q}[^${_q}]*icon" \
      | grep -oE "href=${_q}[^${_q}]*${_q}" | sed -e "s/^href=${_q}//" -e "s/${_q}\$//" \
      | awk '{print "image\t" $0}'
    # social unfurl images — these break silently and only in someone else's UI.
    # Match the URL-bearing properties EXACTLY: og:image:width/height/alt and
    # twitter:image:alt carry a number or prose, not a URL, and treating them as
    # assets produces confident nonsense like "GET /1200 -> 404".
    grep -oE '<meta[^>]*>' "$_flat" 2>/dev/null \
      | grep -iE "(property|name)=${_q}(og:image(:(url|secure_url))?|twitter:image(:src)?)${_q}" \
      | grep -oE "content=${_q}[^${_q}]*${_q}" | sed -e "s/^content=${_q}//" -e "s/${_q}\$//" \
      | awk '{print "image\t" $0}'
    # every other src= (script, iframe, source, video, audio)
    grep -oE "src=${_q}[^${_q}]*${_q}" "$_flat" 2>/dev/null \
      | sed -e "s/^src=${_q}//" -e "s/${_q}\$//" \
      | awk '{print "asset\t" $0}'
    # every href= (stylesheets, routes, in-page nav)
    grep -oE "href=${_q}[^${_q}]*${_q}" "$_flat" 2>/dev/null \
      | sed -e "s/^href=${_q}//" -e "s/${_q}\$//" \
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

# ----------------------------------------------------------------- doc link scan
# Emits "<kind>\t<raw-url>". Images come from markdown image syntax and <img src>;
# every other URL is swept in bulk, which picks up markdown link targets, autolinks
# and URLs inside fenced code blocks in one pass. Overlap between the two passes is
# fine and in fact wanted — the rank-based dedupe below keeps the STRICTER kind.
extract_md_refs() {
  _f="$1"
  grep -oE '!\[[^]]*\]\([^) ]+' "$_f" 2>/dev/null | sed -e 's/^.*(//' \
    | awk '{print "image\t" $0}'
  grep -oE '<img[^>]*>' "$_f" 2>/dev/null \
    | grep -oE 'src="[^"]*"' | sed -e 's/^src="//' -e 's/"$//' \
    | awk '{print "image\t" $0}'
  grep -oE 'https?://[^ )>"'"'"'`]+' "$_f" 2>/dev/null \
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
      SKIPPED=$((SKIPPED + 1))
      [ "$VERBOSE" -eq 1 ] && row "$label" "$kind" "SKIP" "-" "relative/anchor" "$raw"
      continue
    fi
    if [ "$kind" != "image" ] && looks_like_image_path "$abs"; then kind="image"; fi
    case "$kind" in
      image) rank=0 ;;
      asset) rank=1 ;;
      *)     rank=2 ;;
    esac
    printf '%s\t%s\t%s\n' "$rank" "$kind" "$abs" >> "$resolved"
  done < "$refs"

  uniq_refs="$WORKDIR/mduniq.txt"
  sort -u "$resolved" | sort -t"$(printf '\t')" -k3,3 -k1,1n \
    | awk -F'\t' '!seen[$3]++ {print $2 "\t" $3}' > "$uniq_refs"

  n=$(wc -l < "$uniq_refs" | tr -d ' ')
  if [ "$n" = "0" ]; then echo "(no fetchable URLs in this doc)"; return; fi
  echo "${n} distinct URL(s), external included:"
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
echo "SUMMARY   checks: ${TOTAL}   passed: ${PASSED}   failed: ${FAILED}   skipped(external/anchor/placeholder): ${SKIPPED}"
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
