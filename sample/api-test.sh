#!/usr/bin/env bash
# SnapOG — API regression suite (requires a running dev server)
#
#   BASE_URL=http://127.0.0.1:8799 ADMIN_SECRET=... bash sample/api-test.sh
#
# Registers its own key, so no setup beyond a running server is needed.
set -uo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:8787}"
ADMIN_SECRET="${ADMIN_SECRET:-}"
OUT_DIR="${OUT_DIR:-$(mktemp -d /tmp/snapog-test-XXXX)}"
mkdir -p "$OUT_DIR"

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; }

# expect_status <label> <expected-code> <curl args...>
expect_status() {
  local label="$1" want="$2"; shift 2
  local got
  got=$(curl -s -o /dev/null -w '%{http_code}' "$@")
  [ "$got" = "$want" ] && ok "$label" || bad "$label" "expected HTTP $want, got $got"
}

echo "=== SnapOG API regression suite ==="
echo "Base URL: $BASE_URL"
echo "Artifacts: $OUT_DIR"
echo ""

# ─── 1. Service basics ────────────────────────────────────────────────────────
echo "[1] Service basics"
expect_status "GET /health"          200 "$BASE_URL/health"
expect_status "GET / (landing)"      200 "$BASE_URL/"
expect_status "GET /register"        200 "$BASE_URL/register"
expect_status "GET /nope (404)"      404 "$BASE_URL/nope"
echo ""

# ─── 2. Registration ──────────────────────────────────────────────────────────
echo "[2] Registration"
expect_status "POST /register rejects bad email" 400 \
  -X POST "$BASE_URL/register" -d "email=notanemail"

REG_HTML="$OUT_DIR/register.html"
curl -s -X POST "$BASE_URL/register" \
  -d "email=test-$RANDOM@snapog.test" -d "keyname=regression" -o "$REG_HTML"
KEY=$(grep -oE 'sk_[a-f0-9]{64}' "$REG_HTML" | head -1)
if [ -n "$KEY" ]; then ok "POST /register issues a key"; else
  bad "POST /register issues a key" "no sk_ key in response"; echo; echo "Cannot continue."; exit 1
fi
echo ""

# ─── 3. Paid tiers are not self-service (regression: revenue giveaway) ────────
# A signup form that trusted its own `tier` field handed out 100,000 images/month
# for free. Signup must always land on the free plan.
echo "[3] Paid tiers are not self-service"
for want_tier in pro business; do
  H="$OUT_DIR/register-$want_tier.html"
  curl -s -X POST "$BASE_URL/register" \
    -d "email=greedy-$want_tier-$RANDOM@snapog.test" -d "tier=$want_tier" -o "$H"
  ESC_KEY=$(grep -oE 'sk_[a-f0-9]{64}' "$H" | head -1)
  if [ -z "$ESC_KEY" ]; then
    bad "signup with tier=$want_tier" "no key issued at all"
    continue
  fi
  GOT_TIER=$(curl -s -o /dev/null -D - "$BASE_URL/og?title=Escalation+probe&key=$ESC_KEY" \
    | grep -i '^x-snapog-tier:' | tr -d '\r' | awk '{print $2}')
  if [ "$GOT_TIER" = "free" ]; then
    ok "signup with tier=$want_tier still lands on free"
  else
    bad "signup with tier=$want_tier still lands on free" "got tier '$GOT_TIER'"
  fi
done
echo ""

# ─── 3b. One email cannot mint unlimited keys ─────────────────────────────────
# Paid tiers being server-only doesn't matter if the free plan is infinite:
# re-registering the same address used to hand out a fresh 100/month allowance
# every time. MAX_KEYS_PER_EMAIL caps it.
echo "[3b] Per-email key cap"
CAP_EMAIL="cap-$RANDOM@snapog.test"
CAP_OK=1
for i in 1 2 3; do
  H="$OUT_DIR/cap-$i.html"
  CODE=$(curl -s -o "$H" -w '%{http_code}' -X POST "$BASE_URL/register" -d "email=$CAP_EMAIL")
  grep -qE 'sk_[a-f0-9]{64}' "$H" && [ "$CODE" = "200" ] || CAP_OK=0
done
[ "$CAP_OK" = "1" ] && ok "first 3 keys for one email are issued" \
  || bad "first 3 keys for one email are issued" "one of the first 3 was refused"

H4="$OUT_DIR/cap-4.html"
CODE4=$(curl -s -o "$H4" -w '%{http_code}' -X POST "$BASE_URL/register" -d "email=$CAP_EMAIL")
if [ "$CODE4" = "429" ] && ! grep -qE 'sk_[a-f0-9]{64}' "$H4"; then
  ok "4th key for the same email is refused (HTTP 429, no key leaked)"
else
  bad "4th key for the same email is refused" "HTTP $CODE4, key present: $(grep -cE 'sk_[a-f0-9]{64}' "$H4")"
fi
echo ""

# ─── 3c. Demand capture ───────────────────────────────────────────────────────
# The landing page has no prices and nothing to buy, so the only conversion it
# can honestly measure is "100 a month wasn't enough". That must actually store.
echo "[3c] Demand capture"
expect_status "POST /interest rejects bad email" 400 \
  -X POST "$BASE_URL/interest" -d "email=notanemail"

INT_EMAIL="interest-$RANDOM@snapog.test"
IH="$OUT_DIR/interest.html"
INT_CODE=$(curl -s -o "$IH" -w '%{http_code}' -X POST "$BASE_URL/interest" -d "email=$INT_EMAIL")
if [ "$INT_CODE" = "200" ] && grep -q "Recorded — $INT_EMAIL" "$IH"; then
  ok "POST /interest records the address"
else
  bad "POST /interest records the address" "HTTP $INT_CODE"
fi

# No price, no plan name, no checkout anywhere on a publicly reachable page.
LH="$OUT_DIR/landing.html"
curl -s "$BASE_URL/" -o "$LH"
PROPS='\$[0-9]|Upgrade|upgrade|checkout|credit card|[Bb]illing|/mo\b'
if grep -qE "$PROPS" "$LH"; then
  bad "landing page carries no revenue props" "$(grep -oE "$PROPS" "$LH" | sort -u | tr '\n' ' ')"
else
  ok "landing page carries no revenue props"
fi
echo ""

# ─── 4. Admin upgrade is the only way up ──────────────────────────────────────
echo "[4] Admin upgrade gate"
KEY_PREFIX="${KEY:0:12}"
expect_status "POST /admin/upgrade without secret is refused" \
  "$([ -n "$ADMIN_SECRET" ] && echo 403 || echo 503)" \
  -X POST "$BASE_URL/admin/upgrade" -H 'Content-Type: application/json' \
  -d "{\"key_prefix\":\"$KEY_PREFIX\",\"tier\":\"pro\"}"

if [ -n "$ADMIN_SECRET" ]; then
  expect_status "wrong secret is refused" 403 \
    -X POST "$BASE_URL/admin/upgrade" -H 'X-Admin-Secret: wrong-secret' \
    -H 'Content-Type: application/json' \
    -d "{\"key_prefix\":\"$KEY_PREFIX\",\"tier\":\"pro\"}"

  expect_status "free is not an upgrade target" 400 \
    -X POST "$BASE_URL/admin/upgrade" -H "X-Admin-Secret: $ADMIN_SECRET" \
    -H 'Content-Type: application/json' \
    -d "{\"key_prefix\":\"$KEY_PREFIX\",\"tier\":\"free\"}"

  expect_status "unknown key prefix is 404" 404 \
    -X POST "$BASE_URL/admin/upgrade" -H "X-Admin-Secret: $ADMIN_SECRET" \
    -H 'Content-Type: application/json' \
    -d '{"key_prefix":"sk_00000000","tier":"pro"}'

  UP=$(curl -s -X POST "$BASE_URL/admin/upgrade" -H "X-Admin-Secret: $ADMIN_SECRET" \
    -H 'Content-Type: application/json' \
    -d "{\"key_prefix\":\"$KEY_PREFIX\",\"tier\":\"pro\"}")
  case "$UP" in
    *'"tier":"pro"'*) ok "valid secret upgrades to pro" ;;
    *) bad "valid secret upgrades to pro" "response: $UP" ;;
  esac

  NEW_TIER=$(curl -s -o /dev/null -D - "$BASE_URL/og?title=Post+upgrade&key=$KEY" \
    | grep -i '^x-snapog-tier:' | tr -d '\r' | awk '{print $2}')
  [ "$NEW_TIER" = "pro" ] && ok "upgraded key serves as pro" \
    || bad "upgraded key serves as pro" "got '$NEW_TIER'"
else
  echo "  SKIP secret-holder cases (ADMIN_SECRET not set)"
fi
echo ""

# ─── 5. Image generation ──────────────────────────────────────────────────────
echo "[5] Image generation"
expect_status "missing key is 401"   401 "$BASE_URL/og?title=Test"
expect_status "invalid key is 401"   401 "$BASE_URL/og?title=Test&key=sk_bogus"
expect_status "missing title is 400" 400 "$BASE_URL/og?key=$KEY"

for tpl in default blog article; do
  for theme in dark light; do
    F="$OUT_DIR/og-$tpl-$theme.png"
    curl -s -o "$F" "$BASE_URL/og?title=The+quick+brown+fox+ships+to+production&description=A+subtitle+that+should+sit+directly+under+the+title&domain=example.com&author=Jane+Doe&tag=Guide&template=$tpl&theme=$theme&key=$KEY"
    DIMS=$(file -b "$F" | grep -oE '[0-9]+ x [0-9]+' | head -1)
    if [ "$DIMS" = "1200 x 630" ]; then
      ok "$tpl/$theme renders 1200x630 PNG ($(wc -c < "$F" | tr -d ' ') bytes)"
    else
      bad "$tpl/$theme renders 1200x630 PNG" "file says: $(file -b "$F" | cut -c1-60)"
    fi
  done
done
echo ""

# ─── 6. R2 cache ──────────────────────────────────────────────────────────────
echo "[6] R2 cache"
CACHE_URL="$BASE_URL/og?title=Cache+probe+$RANDOM&domain=example.com&key=$KEY"
C1=$(curl -s -o "$OUT_DIR/cache-1.png" -D - "$CACHE_URL" | grep -i '^x-cache:' | tr -d '\r' | awk '{print $2}')
C2=$(curl -s -o "$OUT_DIR/cache-2.png" -D - "$CACHE_URL" | grep -i '^x-cache:' | tr -d '\r' | awk '{print $2}')
[ "$C1" = "MISS" ] && ok "first request is a cache MISS" || bad "first request is a cache MISS" "got '$C1'"
[ "$C2" = "HIT" ]  && ok "second request is a cache HIT"  || bad "second request is a cache HIT"  "got '$C2'"
cmp -s "$OUT_DIR/cache-1.png" "$OUT_DIR/cache-2.png" \
  && ok "cached bytes are identical" || bad "cached bytes are identical" "byte mismatch"
echo ""

# ─── 6b. Quota meters renders, not requests ───────────────────────────────────
# Unfurlers re-fetch the same OG image forever. If a cache hit burned quota, a
# post going viral would blank every social preview on the customer's site.
echo "[6b] Cache hits do not consume quota"
QH="$OUT_DIR/quota-register.html"
curl -s -X POST "$BASE_URL/register" -d "email=quota-$RANDOM@snapog.test" -o "$QH"
QKEY=$(grep -oE 'sk_[a-f0-9]{64}' "$QH" | head -1)

# usage_count as rendered by the dashboard
usage_of() {
  curl -s "$BASE_URL/dashboard?key=$1" \
    | grep -o 'class="usage-count">[0-9,]*' | head -1 | sed 's/.*>//' | tr -d ','
}

if [ -z "$QKEY" ]; then
  bad "quota probe key issued" "no key"
else
  U0=$(usage_of "$QKEY")
  QURL="$BASE_URL/og?title=Quota+probe+$RANDOM&key=$QKEY"

  CH1=$(curl -s -o /dev/null -D - "$QURL" | grep -i '^x-snapog-quota-charged:' | tr -d '\r' | awk '{print $2}')
  U1=$(usage_of "$QKEY")
  [ "$CH1" = "true" ] && ok "MISS reports X-SnapOG-Quota-Charged: true" \
    || bad "MISS reports X-SnapOG-Quota-Charged: true" "got '$CH1'"
  [ "$U1" = "$((U0 + 1))" ] && ok "MISS increments usage ($U0 → $U1)" \
    || bad "MISS increments usage" "$U0 → $U1"

  # Three more fetches of the same URL — all cache hits.
  for _ in 1 2 3; do curl -s -o /dev/null "$QURL"; done
  CH2=$(curl -s -o /dev/null -D - "$QURL" | grep -i '^x-snapog-quota-charged:' | tr -d '\r' | awk '{print $2}')
  U2=$(usage_of "$QKEY")
  [ "$CH2" = "false" ] && ok "HIT reports X-SnapOG-Quota-Charged: false" \
    || bad "HIT reports X-SnapOG-Quota-Charged: false" "got '$CH2'"
  [ "$U2" = "$U1" ] && ok "4 cache hits leave usage unchanged (still $U2)" \
    || bad "4 cache hits leave usage unchanged" "$U1 → $U2"
fi
echo ""

# ─── 7. Dashboard ─────────────────────────────────────────────────────────────
echo "[7] Dashboard"
expect_status "GET /dashboard with key"    200 "$BASE_URL/dashboard?key=$KEY"
expect_status "GET /dashboard bad key"     404 "$BASE_URL/dashboard?key=sk_bogus"
expect_status "GET /dashboard without key" 400 "$BASE_URL/dashboard"
echo ""

echo "════════════════════════════════"
printf 'PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
echo "Artifacts in $OUT_DIR"
[ "$FAIL" -eq 0 ] || exit 1
