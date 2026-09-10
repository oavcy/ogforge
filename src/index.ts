// OGForge — Main Cloudflare Worker
// Routes: GET /og (image gen), GET / (landing), GET/POST /register, GET /dashboard

import { Hono } from 'hono';
import type { Context } from 'hono';
import { generateOGImage, buildCacheKey } from './og/render';
import {
  landingPage,
  registerPage,
  keyCreatedPage,
  dashboardPage,
  errorPage,
} from './dashboard/pages';
import { postmortemPage, POSTMORTEM_PATH } from './dashboard/postmortem';
import type { ApiKey, Env, OGParams, Tier } from './types';
import {
  MAX_KEYS_PER_EMAIL,
  PAID_TIERS,
  SIGNUP_TIER,
  TIER_LIMITS,
  isPaidTier,
} from './types';

const app = new Hono<{ Bindings: Env }>();

// ─── Helpers ──────────────────────────────────────────────────────────────────

async function sha256(text: string): Promise<string> {
  const buf = await crypto.subtle.digest(
    'SHA-256',
    new TextEncoder().encode(text)
  );
  return Array.from(new Uint8Array(buf))
    .map(b => b.toString(16).padStart(2, '0'))
    .join('');
}

// Length-independent comparison, so a wrong guess leaks no timing information
// about how many leading characters were correct.
function timingSafeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const ab = enc.encode(a);
  const bb = enc.encode(b);
  // Fold length into the result rather than returning early on a mismatch.
  let diff = ab.length ^ bb.length;
  const len = Math.max(ab.length, bb.length);
  for (let i = 0; i < len; i++) {
    diff |= (ab[i] ?? 0) ^ (bb[i] ?? 0);
  }
  return diff === 0;
}

// Loose on purpose: the point is to catch typos, not to police addresses.
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

// `tier_interest.requested_tier` is free-form text. Nothing is for sale, so the
// only thing a visitor can ask for is a bigger allowance.
const INTEREST_REASON = 'more-renders';

function generateRawKey(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return 'sk_' + Array.from(bytes).map(b => b.toString(16).padStart(2, '0')).join('');
}

// `wrangler dev` serves plaintext and https://localhost:8787 answers nothing, so
// the scheme pinning below must not reach it. Kept as a named predicate because
// two places need the same exemption and they must not drift apart.
function isLocalHost(hostname: string): boolean {
  return (
    hostname === 'localhost' || hostname === '127.0.0.1' || hostname === '::1'
  );
}

// Every copy-pasteable example on the site is built from the URL the visitor
// actually reached us on. Hardcoding a domain here is how a service ends up
// documenting an address that does not exist.
//
// The SCHEME is the exception, and cycle #51 is why. `http://` was served, not
// redirected, and this function handed the request scheme to every absolute URL
// on the site: `/`, `/register` and the postmortem each returned 200 with a
// self-referencing `http://` canonical, and `sitemap.xml` listed five `http://`
// <loc>s — i.e. it did not merely tolerate the duplicates, it submitted them for
// indexing. Note what this is NOT: every one of those heads was truthful about
// the URL that served it, so #50's invariant held at every route and the site
// still declared two canonical identities for the same three pages. A
// per-response invariant cannot see a defect that only exists across responses.
// ogp.me defines og:url as "the canonical URL of the object", not the request
// URL, so pinning the scheme is what that spec asks for rather than a deviation
// from it.
function origin(requestUrl: string): string {
  const url = new URL(requestUrl);
  if (!isLocalHost(url.hostname)) url.protocol = 'https:';
  return url.origin;
}

function htmlResponse(
  html: string,
  status = 200,
  extraHeaders: Record<string, string> = {}
): Response {
  return new Response(html, {
    status,
    headers: { 'Content-Type': 'text/html; charset=utf-8', ...extraHeaders },
  });
}

// Cycle #53. A `<meta name="robots">` tag only works if the crawler is allowed to
// FETCH the page and read it. Google's own documentation, fetched this cycle from
// developers.google.com/search/docs/crawling-indexing/block-indexing:
//
//   "Important: For the noindex rule to be effective, the page or resource must
//    not be blocked by a robots.txt file, and it has to be otherwise accessible
//    to the crawler."
//   "If the page is blocked by a robots.txt file or the crawler can't access the
//    page, the crawler will never see the noindex rule, and the page can still
//    appear in search results, for example if other pages link to it."
//
// So `Disallow: /dashboard` did not reinforce PRIVATE_HEAD, it CANCELLED it — and
// two comments in pages.ts said the opposite. Sent as a header as well as a meta
// tag because a header is the only mechanism available to a JSON endpoint, and
// because it survives a page whose head we forget to mark.
const NOINDEX_HEADER = { 'X-Robots-Tag': 'noindex, nofollow' };

// ── Cycle #58: what does the SET of responses disclose that no single one does?
// #57 asked whether one status code was true. The next rung down is not another
// response — it is the whole surface at once. Swept live before this change,
// every path, reading only Cache-Control:
//
//   public, max-age=86400, s-maxage=604800   /brand.png  /demo.png
//   public, max-age=86400                    /favicon.svg
//   public, max-age=3600                     /robots.txt  /sitemap.xml
//   (none)                                   /  /postmortem/…  /postmortem/hits
//                                            /register  /dashboard  /health
//                                            /interest(302)  /favicon.ico(301)
//                                            404  405
//
// (plus, not visible to an anonymous sweep: `/og`'s 200 carries the same
// `public, s-maxage` as the PNGs, and its 429 carries `no-store` — #56.)
//
// THE FIRST DRAFT OF THIS COMMENT WAS WRONG AND MUNGER KILLED IT. It read: the
// split is ASSET TYPE, not semantics — every path carrying a directive is a
// static file. That is refuted by this file, forty lines up: `/og`'s 429 is
// `no-store` and is not a file, and `/og`'s 200 carries `max-age` on a PNG this
// worker just generated. Worse, the taxonomy treats ten absences as ten
// decisions. **The presence of a header is a decision; its absence is not.**
// The sweep found five decisions and ten non-decisions, and calling that a
// classification scheme reads a policy into a default.
//
// What survives, and it is the smaller and truer claim: every directive above
// was argued at its own call site, in its own cycle, about its own response —
// and no cycle ever asked the question across all responses at once. So the
// responses whose value IS currency or specific to one caller inherit Hono's
// `c.json`/`htmlResponse` default, which nobody chose for them, and which is
// exactly right for `/` and `/register` in the same list. Reading one row at a
// time cannot show this: `/health` alone looks like a forgotten header. Only
// the set shows that nothing was forgotten, because nothing was ever asked.
//
// Default does not mean uncacheable. RFC 9111 §4.2.2, fetched this cycle:
//
//   "Since origin servers do not always provide explicit expiration times, a
//    cache MAY assign a heuristic expiration time when an explicit time is not
//    specified… heuristics can only be used on responses without explicit
//    freshness whose status codes are defined as 'heuristically cacheable'"
//
// RFC 9110 line 6953 makes 200 heuristically cacheable and line 7597 does the
// same for 404, so all four responses below are eligible today. The obvious
// objection — "`/dashboard?key=…` has a query string, caches leave those alone"
// — is answered by that same section's closing Note, which is why it is quoted
// rather than paraphrased:
//
//   "*Note:* A previous version of the HTTP specification (Section 13.9 of
//    [RFC2616]) prohibited caches from calculating heuristic freshness for URIs
//    with query components… In practice, this has not been widely implemented.
//    Therefore, origin servers are encouraged to send explicit directives…"
//
// `no-store` rather than `no-cache` (RFC 9111 §5.2.2.5): `no-cache` means store
// it but revalidate, and we serve no ETag and no Last-Modified anywhere, so
// every revalidation could only be a full refetch. `no-store` alone rather than
// `private, no-store`: §5.2.2.5 binds "both private and shared caches", so
// `private` beside it would be inert — #56 A3's lesson (a `Vary` that does no
// work on a `no-store` response) aimed at this cycle's own addition instead of
// at inherited code.
//
// THE BOUND, stated here so no cycle record can overstate this (#35, #55 A4).
// MEASURED: these four responses carried no Cache-Control before this change
// and carry `no-store` after it, live, and three of the four over-fire controls
// (`/`, `/register`, `/dashboard` with no key) still carry none.
// NOT MEASURED, and NOT MEASURABLE FROM HERE: that any cache anywhere would
// have stored them. We serve no ETag, no Last-Modified and no Expires, so a
// heuristic has nothing to compute a lifetime from; `cf-cache-status` is absent
// from all sixteen rows; and we read our own endpoints with `curl`, which has
// no cache at all. So this fixes an OBLIGATION, not an observed staleness. If a
// later record claims a stale read was prevented, that is a fabricated harm —
// the honest claim is the one RFC 9111 §4.2.2 itself makes, that origin servers
// are "encouraged to send explicit directives" precisely because what an
// intermediary will do cannot be predicted from here.
const NO_STORE_HEADER = { 'Cache-Control': 'no-store' };
const NOINDEX_NO_STORE = { ...NOINDEX_HEADER, ...NO_STORE_HEADER };

// Validate an API key from request and return the DB row, or null
async function resolveApiKey(
  db: D1Database,
  rawKey: string | null
): Promise<ApiKey | null> {
  if (!rawKey) return null;
  const hash = await sha256(rawKey);
  const row = await db
    .prepare('SELECT * FROM api_keys WHERE key_hash = ?')
    .bind(hash)
    .first<ApiKey>();
  return row ?? null;
}

// Reset monthly usage if billing month rolled over
async function maybeResetUsage(db: D1Database, key: ApiKey): Promise<ApiKey> {
  const resetAt = new Date(key.usage_reset_at);
  const now = new Date();
  const thisMonth = new Date(now.getFullYear(), now.getMonth(), 1);

  if (resetAt < thisMonth) {
    const newResetAt = thisMonth.toISOString();
    await db
      .prepare(
        'UPDATE api_keys SET usage_count = 0, usage_reset_at = ? WHERE id = ?'
      )
      .bind(newResetAt, key.id)
      .run();
    return { ...key, usage_count: 0, usage_reset_at: newResetAt };
  }
  return key;
}

// Seconds until the quota gate can next open, for RFC 6585 §4's Retry-After.
//
// RFC 6585 §4 defines 429 as "too many requests in a given amount of time
// ('rate limiting')" and says the response "MAY include a Retry-After header
// indicating how long to wait before making a new request". The MAY is why this
// went 56 cycles without one; the reason to send it is that here the value is
// exactly computable rather than guessed.
//
// It mirrors maybeResetUsage() deliberately — same `new Date(y, m, 1)`
// construction, one month on. That function resets lazily, on the first request
// after the boundary, so the boundary IS the moment a retry starts succeeding.
// Workers run in UTC, so the local-component constructor and UTC agree.
//
// THE OBLIGATION THIS HEADER CREATES: it is honest only while the quota window
// is the calendar month. If the window ever becomes rolling-30-day, or
// anniversary-of-signup, this header becomes a lie and MUST change in the same
// commit that changes the window. Sending a wrong Retry-After is worse than
// sending none: none is a MAY declined, wrong is a stated fact that is false.
function secondsUntilQuotaReset(now: Date = new Date()): number {
  const nextReset = new Date(now.getFullYear(), now.getMonth() + 1, 1);
  // RFC 9110 §10.2.3: delay-seconds = 1*DIGIT, a NON-NEGATIVE decimal integer.
  // Clamped and rounded up so the value is never 0 (which would invite an
  // immediate retry into the same closed gate) and never a fraction.
  return Math.max(1, Math.ceil((nextReset.getTime() - now.getTime()) / 1000));
}

// Record the event, and meter the quota — but only for real renders.
//
// Every request is logged to usage_events (cache_hit tells the two apart, which
// is where the analytics value is). Only a cache MISS increments usage_count.
// An OG image lives in a customer's <meta> tag and gets re-fetched forever by
// Twitter/Slack/LinkedIn unfurlers; charging for those repeats would mean the
// better a post does, the sooner the customer's whole site loses its previews.
// A hit is bytes out of R2 — our marginal cost is ~0, so the price is 0.
async function recordUsage(
  db: D1Database,
  key: ApiKey,
  template: string,
  cacheHit: boolean
): Promise<void> {
  const eventId = crypto.randomUUID();
  const statements = [
    db
      .prepare(
        'INSERT INTO usage_events (id, api_key_id, template, cache_hit) VALUES (?, ?, ?, ?)'
      )
      .bind(eventId, key.id, template, cacheHit ? 1 : 0),
  ];
  if (!cacheHit) {
    statements.unshift(
      db
        .prepare('UPDATE api_keys SET usage_count = usage_count + 1 WHERE id = ?')
        .bind(key.id)
    );
  }
  await db.batch(statements);
}

// Record that an off-site page sent us a visitor. See migrations/0003 for why this
// exists: the company's done-condition for distribution was a GitHub traffic API
// call, but the link being distributed points at this Worker, so that gauge could
// read `[]` forever while the thing actually worked. A gate that cannot register
// success is the same defect as one that cannot go red.
//
// Writes ONLY for a cross-origin Referer — direct hits and same-origin navigation
// store nothing. Host only; never the full referring URL.
//
// CORRECTED Cycle #43. This comment used to claim crawlers store nothing and that
// "every row means exactly one thing." Both were false. The test below is three
// conditions — a Referer header is present, it parses as a URL, and its host is
// not ours — and NOT ONE OF THEM LOOKS AT WHO IS ASKING. There is no bot check
// (there cannot be: we deliberately never read the user agent), no rate limit and
// no dedupe. So ONE agent making N requests writes N rows, and the owner can add
// a row from a shell with `curl -H 'Referer: https://example.com/'`. Measured:
// ids 6–10 arrived at 19:37:37/38/39/39/40 — five rows in four seconds, two in one
// second, all path `/`, all ref_host `github.com`. That is one client, not five
// readers. A row is a REQUEST that carried an off-site Referer. Nothing more.
//
// SCOPE — this function is CALLED PER ROUTE, and for fifteen cycles nothing wrote
// down which routes. Cycle #44 counted: 2 call sites against 11 paths that return
// 200. Nine paths recorded nothing and no comment, doc or consensus line said so.
// That is Cycle #43's defect with the sign flipped: #43's comment claimed an
// exclusion the code does not implement, this was an exclusion the code implements
// that no prose stated. An unstated scope is the defect, not the narrowness.
//
// Instrumented (4): `/` · the postmortem page · /brand.png · /demo.png.
// CANNOT produce a row, so not a choice — no realistic client sends a
// cross-origin Referer for them: /robots.txt, /sitemap.xml, /favicon.svg,
// /health. Do not "fix" these; physics decided, not us.
// DELIBERATELY not recorded (3): /register — the funnel's bottom already writes
// `users` and `tier_interest` with an email, which is strictly stronger evidence
// than a host, and all four internal links to it are same-origin anyway;
// /dashboard — a cross-origin Referer here would mean a user leaked their API key
// in public, which is a security event, not demand; /postmortem/hits — the read
// side of this very table, recording itself.
//
// The scope above is prose, and #41 A2 is that an expectation the code does not
// measure is a hope with a `#` in front. So the four instrumented paths live in
// ONE constant, read by both the call sites and the public JSON. A fifth call site
// would have to pass a bare literal to escape this list, which is now the visibly
// odd shape in the file. A stranger can audit the coverage without our source:
// GET /postmortem/hits returns `instrumented_paths`.
const HIT_PATHS = {
  landing: '/',
  postmortem: POSTMORTEM_PATH,
  brand: '/brand.png',
  demo: '/demo.png',
} as const;

// Deliberately fire-and-forget via waitUntil and wrapped in a catch: an
// instrumentation failure must never turn a readable page into a 500. The read
// side (GET /postmortem/hits) is where a problem would surface.
function recordInboundHit(c: Context<{ Bindings: Env }>, path: string): void {
  const referer = c.req.header('referer');
  if (!referer) return;

  let refHost: string;
  try {
    refHost = new URL(referer).host.toLowerCase();
  } catch {
    return; // malformed Referer — nothing meaningful to record
  }
  if (!refHost || refHost === new URL(c.req.url).host.toLowerCase()) return;

  c.executionCtx.waitUntil(
    c.env.DB.prepare(
      'INSERT INTO inbound_hits (path, ref_host) VALUES (?, ?)'
    )
      .bind(path, refHost)
      .run()
      .then(() => undefined)
      .catch(err => {
        console.error('inbound_hits insert failed:', err);
      })
  );
}

// ─── Transport ────────────────────────────────────────────────────────────────
// Pinning the scheme in origin() fixes what the pages SAY. It does not remove
// the second URL: without this, http:// still answers 200 and a crawler that
// reaches it is being asked to trust an annotation instead of finding one door.
// The stronger reason is not SEO. This worker takes its credential as a query
// parameter (`/og?key=sk_…`), and over http it reached its own validation code:
// measured this cycle, `curl http://…/og?title=…` returns this app's own
// `{"error":"key parameter is required…"}` 401, not a redirect — so a real key
// would have travelled, in the URL, in cleartext. A 301 is the only response
// that removes the plaintext path rather than documenting it.
//
// HSTS (RFC 6797) covers the case the redirect cannot: the FIRST request, which
// is already on the wire before any redirect can be sent.
//
// This is app.use, not app.get/post — the public surface stays 16 distinct paths
// / 18 registrations, and the counting greps in consensus.md still return those.
app.use('*', async (c, next) => {
  const url = new URL(c.req.url);
  if (url.protocol === 'http:' && !isLocalHost(url.hostname)) {
    url.protocol = 'https:';
    return c.redirect(url.toString(), 301);
  }
  await next();
  // Re-wrap so the headers are mutable regardless of how the handler built its
  // Response; setting on an immutable headers object throws.
  if (!isLocalHost(url.hostname)) {
    c.res = new Response(c.res.body, c.res);
    c.res.headers.set(
      'Strict-Transport-Security',
      'max-age=31536000; includeSubDomains'
    );
  }
});

// ─── Routes ───────────────────────────────────────────────────────────────────

// Landing page
app.get('/', c => {
  recordInboundHit(c, HIT_PATHS.landing);
  return htmlResponse(landingPage(origin(c.req.url)));
});

// ── Postmortem: a CI gate that certified a product it never tested ────────────
// A published incident report, not a product surface. Nothing here is gated and
// nothing is sold; it exists because it is the one thing this company has that is
// both genuinely useful to strangers and entirely honest.
app.get(POSTMORTEM_PATH, c => {
  recordInboundHit(c, HIT_PATHS.postmortem);
  return htmlResponse(postmortemPage(origin(c.req.url)));
});

// Trailing-slash variant, so a link that picks up a slash somewhere between a
// submission form and a reader's browser does not land on the 404 page.
app.get(`${POSTMORTEM_PATH}/`, c => c.redirect(POSTMORTEM_PATH, 301));

// The read side of the referrer instrument. Public and unauthenticated on purpose:
// it is the evidence that a distribution attempt did or did not produce inbound
// traffic, and evidence only we can read is worth less. Aggregate rows only —
// referrer host and a count. No paths, no URLs, no visitor data of any kind.
app.get('/postmortem/hits', async c => {
  // JSON cannot carry a <meta> tag, so the header is not belt-and-braces here —
  // it is the only mechanism this endpoint has. It replaces `Disallow:
  // /postmortem/hits`, which kept the crawler from reading any directive at all.
  c.header('X-Robots-Tag', 'noindex, nofollow');
  // #58. A live counter: its value is the count AS OF NOW, so a stored copy is
  // a confident wrong answer rather than an old one.
  //
  // THE DRAFT'S REASON WAS FALSE AND IS RECORDED HERE RATHER THAN DELETED. It
  // said: this is our own instrument, so a cached read would give us a false
  // "zero delta" meaning "cache", not "no traffic". That harm cannot occur on
  // the reader named — every cycle reads this with `curl`, which has no cache,
  // and `cf-cache-status` is absent from all sixteen rows of this cycle's
  // sweep. The header protects a THIRD-PARTY reader (a browser, a proxy), not
  // us. Writing our own instrument into the justification made the fix sound
  // urgent and made the reasoning unfalsifiable in our own favour, which is the
  // shape this repo exists to catch.
  //
  // Set before the `try` so the 500 branch inherits it too: a cached failure is
  // worse than a cached success, because it outlives the outage that made it.
  c.header('Cache-Control', 'no-store');
  try {
    const { results } = await c.env.DB.prepare(
      `SELECT ref_host, COUNT(*) AS hits, MIN(day) AS first_day, MAX(day) AS last_day
         FROM inbound_hits
        GROUP BY ref_host
        ORDER BY hits DESC
        LIMIT 100`
    ).all<{ ref_host: string; hits: number; first_day: string; last_day: string }>();

    const rows = results ?? [];
    return c.json({
      ok: true,
      // The whole point of the endpoint: is this list empty or not?
      distinct_referrer_hosts: rows.length,
      total_inbound_hits: rows.reduce((sum, r) => sum + r.hits, 0),
      referrers: rows,
      // Cycle #44: the coverage is now a value, not a sentence. This endpoint
      // reported a total for fifteen cycles without ever saying which paths could
      // contribute to it, and the answer was 2 of the 11 that return 200.
      instrumented_paths: Object.values(HIT_PATHS),
      note:
        'Cross-origin Referer hosts only. Direct traffic and same-origin navigation ' +
        'are not recorded. Host only — no URLs, IPs, user agents or identifiers. ' +
        'Counts are REQUESTS, not visitors: there is no bot filter, no rate limit ' +
        'and no dedupe, so one client making N requests reports as N hits. Do not ' +
        'read these numbers as an audience. PARTIAL COVERAGE: only the paths in ' +
        'instrumented_paths can produce a row. This service answers 200 on 11 paths; ' +
        'a visit to any other one is invisible here, so a zero is not proof nobody ' +
        'came. /register and /dashboard are deliberately excluded; robots.txt, ' +
        'sitemap.xml, favicon.svg and /health cannot carry a cross-origin Referer.',
    });
  } catch (err) {
    // Report the failure instead of pretending the answer is zero. An instrument
    // that returns an empty list when it is broken is indistinguishable from one
    // reporting a true zero, and that ambiguity is the exact thing this postmortem
    // is about.
    console.error('/postmortem/hits failed:', err);
    return c.json(
      { ok: false, error: 'inbound_hits query failed', detail: String(err) },
      500
    );
  }
});

// ── Bearer credentials (RFC 9110 §15.5.2, §11.6.1 · RFC 6750) ─────────────────
// RFC 9110 says it twice, in two sections, as a MUST: "The server generating a
// 401 response MUST send a WWW-Authenticate header field ... containing at
// least one challenge applicable to the target resource." For 55 cycles this
// endpoint sent bare 401s. The header is not decoration — it is the only thing
// in the response that tells a client HOW to authenticate.
//
// A challenge naming a scheme the server ignores would be a prop: a header
// advertising a capability that does not exist. Before this change,
// `Authorization: Bearer <key>` was MEASURED to be ignored — it returned
// "key parameter is required", the no-credentials error. So the challenge and
// the reader of that challenge ship together, or neither ships.
const AUTH_REALM = 'ogforge';

// RFC 6750 §3.1: "If the request lacks any authentication information ... the
// resource server SHOULD NOT include an error code or other error
// information." Only a credential that was SUPPLIED AND REJECTED earns one.
// The description is a fixed literal — never interpolate the submitted key,
// which would reflect an attacker's bytes into a quoted header value.
//
// Cycle #63. This description used to read "The API key is expired, revoked, or
// not valid", and TWO OF THOSE THREE STATES DO NOT EXIST IN THIS SYSTEM. There
// is no expiry column and no revocation anywhere in the schema — checked by
// command against all three migrations, which contain no `expire`, `revoke`,
// `suspend`, `disable` or `status` column. A key is valid from creation until
// the database is destroyed. So of the three causes we named to every rejected
// caller, exactly one was reachable.
//
// The provenance is the interesting part, and it is not carelessness. RFC 6750
// §3.1 (fetched, not recalled — rfc-editor.org/rfc/rfc6750.txt, 200, 38,949 B)
// DEFINES the error CODE this way at line 476:
//
//   "invalid_token — The access token provided is expired, revoked, malformed,
//    or invalid for other reasons."
//
// That sentence enumerates the conditions under which an implementation should
// choose `error="invalid_token"`. It is a disjunction across ALL deployments.
// #55 pasted it into `error_description`, which §3 line 418 defines as "a
// human-readable explanation" — of THIS failure, to THIS developer. Copying the
// code's applicability list into the description converts a statement about
// when a code applies into a claim about what just happened to one request.
//
// Our single reachable cause is the RFC's own catch-all, "invalid for other
// reasons": the supplied credential hashed to nothing in `api_keys`. Say that,
// and nothing else. Note the response was already contradicting itself — the
// JSON body says "Invalid API key" (one cause, true) while this header said
// three, two of them impossible, in the SAME response. The body was right.
//
// Character set is constrained: RFC 6750 §3 line 428 restricts this value to
// %x20-21 / %x23-5B / %x5D-7E, which excludes `"` and `\`. Keep it plain ASCII
// with no quotes or backslashes.
function bearerChallenge(invalidToken = false): string {
  return invalidToken
    ? `Bearer realm="${AUTH_REALM}", error="invalid_token", ` +
        `error_description="No API key matches the credential supplied"`
    : `Bearer realm="${AUTH_REALM}"`;
}

// The 401 bodies now genuinely differ by request header — "key parameter is
// required" with no credentials, "Invalid API key" with a rejected Bearer — so
// they Vary for the same reason the images do. Two payoffs beyond correctness:
// a shared cache cannot pin one 401 over the other, and unlike the 200s this
// response is reachable WITHOUT an API key, which is the only way the gate can
// prove anonymously that `Vary` survives the platform at all.
function challengeHeaders(invalidToken = false): Record<string, string> {
  return {
    'WWW-Authenticate': bearerChallenge(invalidToken),
    Vary: 'Authorization',
  };
}

// ── Why both /og 200s carry `Vary: Authorization` ─────────────────────────────
// RFC 9111 §3.5: a shared cache MUST NOT reuse a response to a request bearing
// an `Authorization` header field UNLESS the response carries a directive that
// allows it — and it names exactly three: `must-revalidate`, `public`, and
// `s-maxage`. The /og image response carries `public, max-age=86400,
// s-maxage=604800`: TWO of the three. The prohibition that would have saved us
// is lifted by our own header.
//
// So the moment /og began reading `Authorization`, two different requests to
// the SAME URL — `/og?title=x` with a Bearer header, and without — became
// cache-confusable, and a shared cache would be within spec to serve one
// account's render to an anonymous requester for a week. `Vary` (RFC 9111 §4.1)
// is what re-separates them. Fixing the RFC 9110 defect opened an RFC 9111 one;
// both halves ship in the same commit, because half of this is worse than none.
//
// Cost to existing clients: zero. They authenticate with `?key=` and send no
// `Authorization` header at all, so they all match on the same absent value and
// keep sharing one cache entry.
//
// `?key=` remains the documented interface: every key we have issued, the
// README and the landing page all use it, and removing it would break them.
// RFC 6750 §2.3 rates query-parameter delivery "NOT RECOMMENDED", so we do NOT
// adopt its `access_token` alias — adding a second discouraged spelling buys
// nothing. We add the header form §2.1 does recommend, beside what we serve.
function readCredential(c: Context<{ Bindings: Env }>): string | null {
  const fromQuery = c.req.query('key');
  if (fromQuery) return fromQuery;
  const header = (c.req.header('Authorization') ?? '').trim();
  const match = /^Bearer[ \t]+(\S+)$/i.exec(header);
  return match ? match[1] : null;
}

// ── OG image generation ────────────────────────────────────────────────────────
app.get('/og', async c => {
  const q = c.req.query();
  const rawKey = readCredential(c);

  // Validate required param
  const title = (q['title'] ?? '').trim().slice(0, 120);
  if (!title) {
    return c.json({ error: 'title parameter is required' }, 400);
  }

  // Resolve API key (required)
  if (!rawKey) {
    return c.json(
      { error: 'key parameter is required. Get a free key at /register' },
      401,
      challengeHeaders()
    );
  }
  let apiKey = await resolveApiKey(c.env.DB, rawKey);
  if (!apiKey) {
    return c.json({ error: 'Invalid API key' }, 401, challengeHeaders(true));
  }

  // Reset usage if month rolled
  apiKey = await maybeResetUsage(c.env.DB, apiKey);

  const params: OGParams = {
    title,
    description: (q['description'] ?? '').trim().slice(0, 200) || undefined,
    domain: (q['domain'] ?? '').trim().slice(0, 100) || undefined,
    author: (q['author'] ?? '').trim().slice(0, 80) || undefined,
    tag: (q['tag'] ?? '').trim().slice(0, 40) || undefined,
    theme: (q['theme'] === 'light' ? 'light' : 'dark') as 'dark' | 'light',
    template: (['blog', 'article'].includes(q['template'] ?? '')
      ? q['template']
      : 'default') as OGParams['template'],
  };

  const watermark = apiKey.tier === 'free';
  const cacheKey = await buildCacheKey(params, watermark);
  const r2Key = `og/${cacheKey}.png`;

  // ── R2 cache lookup ──
  // Deliberately ahead of the quota gate. Re-serving an image we already
  // rendered is free for us, so it is free for the customer — and it must keep
  // working after the quota runs out, or a popular post silently blanks every
  // social preview on their site.
  const cached = await c.env.OG_CACHE.get(r2Key);
  if (cached) {
    c.executionCtx.waitUntil(
      recordUsage(c.env.DB, apiKey, params.template ?? 'default', true)
    );
    const imageData = await cached.arrayBuffer();
    return new Response(imageData, {
      headers: {
        'Content-Type': 'image/png',
        'Cache-Control': 'public, max-age=86400, s-maxage=604800',
        // See the Vary note above readCredential(). Required from the moment
        // this route began reading `Authorization`, not before.
        Vary: 'Authorization',
        'X-Cache': 'HIT',
        'X-OGForge-Tier': apiKey.tier,
        'X-OGForge-Quota-Charged': 'false',
      },
    });
  }

  // ── Quota gate — meters renders, not requests ──
  if (apiKey.usage_count >= apiKey.monthly_limit) {
    return c.json(
      {
        error: 'Monthly render limit reached',
        detail:
          'Images already in the cache keep serving for free — only new renders are metered.',
        tier: apiKey.tier,
        limit: apiKey.monthly_limit,
        interest_url: '/#interest',
        retry_after_seconds: secondsUntilQuotaReset(),
      },
      429,
      {
        // RFC 6585 §4 MAY — sent because the value is computed, not guessed.
        'Retry-After': String(secondsUntilQuotaReset()),
        // RFC 6585 §4, final paragraph: "Responses with the 429 status code
        // MUST NOT be stored by a cache." That MUST NOT binds the cache, not
        // us, and 429 is not in RFC 9110 §15.1's heuristically-cacheable set,
        // so a conformant cache would not have stored this anyway. This header
        // is the enforcing half: it makes the prohibition hold without relying
        // on every intermediary having read RFC 6585. It also matters more here
        // than it looks — /og's 200s carry `public, s-maxage=604800`, so this
        // route is one a shared cache is already actively storing for.
        'Cache-Control': 'no-store',
        // DELIBERATELY NO `Vary: Authorization`, though this body is derived
        // entirely from the credential (it names the key's tier and limit).
        // Vary selects among responses a cache MAY STORE (RFC 9111 §4.1); we
        // have just told caches to store nothing. The header would be inert —
        // legal, plausible, and doing no work. #54's lesson applied to our own
        // addition. This is a genuine bound on #55 A1: "reads Authorization"
        // implies Vary only for a STORABLE response.
      }
    );
  }

  // ── Generate image ──
  const imageResponse = await generateOGImage(params, watermark);
  const imageBuffer = await imageResponse.arrayBuffer();

  // Store in R2 (fire-and-forget, don't block response)
  c.executionCtx.waitUntil(
    c.env.OG_CACHE.put(r2Key, imageBuffer.slice(0), {
      httpMetadata: { contentType: 'image/png' },
      customMetadata: { tier: apiKey.tier, template: params.template ?? 'default' },
    })
  );

  // Record usage (also fire-and-forget after we have the image)
  c.executionCtx.waitUntil(
    recordUsage(c.env.DB, apiKey, params.template ?? 'default', false)
  );

  return new Response(imageBuffer, {
    headers: {
      'Content-Type': 'image/png',
      'Cache-Control': 'public, max-age=86400, s-maxage=604800',
      // See the Vary note above readCredential(). Both /og exits carry it; a
      // cache that saw only the HIT path would still be free to confuse the
      // MISS one.
      Vary: 'Authorization',
      'X-Cache': 'MISS',
      'X-OGForge-Tier': apiKey.tier,
      'X-OGForge-Quota-Charged': 'true',
    },
  });
});

// ── Our own social card ───────────────────────────────────────────────────────
// An OG image API whose own pages had no OG tags shipped for 17 cycles: every
// time anyone shared our link, it rendered as a bare blue string. Fixing that
// needs an image URL a social crawler can fetch — and crawlers do not carry API
// keys, so /og could never serve it.
//
// This route is deliberately NOT a keyless /og. Query params are ignored and the
// content is hard-coded, so it cannot be used as a free general-purpose
// generator. It touches neither D1 nor the quota ledger.
//
// It renders through buildElement — the same code path a paying request takes.
// That is the point: the card that advertises the API is an *output* of the API,
// so it cannot drift from what the product actually produces. If rendering
// breaks, our own preview breaks first, and we find out before a customer does.
const BRAND_CARD: OGParams = {
  title: 'Open Graph images, generated at the edge',
  description: 'One GET request returns a 1200×630 PNG. No SDK, no browser, no build step.',
  domain: 'ogforge',
  tag: 'API',
  // Rendered by the template's footer row. Without it the lower third of the
  // card is empty, which reads as unfinished in a feed. Showing the literal
  // request turns that dead space into the one thing a reader needs to act on:
  // the claim above becomes a concrete URL shape.
  author: 'GET /og?title=Your+Title → PNG',
  theme: 'dark',
  template: 'default',
};

// Bump when BRAND_CARD or the templates change, so the cached object is replaced
// rather than served stale forever behind the long max-age below.
const BRAND_CARD_KEY = 'og/brand/v2.png';

// The hero image on the landing page. Cycle #19 found that this slot pointed at
// `/og?title=…` with no key — so it answered 401 to every human who ever loaded
// the page, and had done so since the page existed. The page's single most
// important pixel, the one that shows what the product makes, was a broken-image
// icon for nineteen cycles.
//
// The bug was not the 401. The 401 is correct and stays. The bug was asking an
// authenticated endpoint to serve an anonymous visitor. Cycle #18 wrote that
// exact sentence about crawlers, two hundred lines above, and shipped /brand.png
// to fix it — while this <img> sat unfixed in the file it was editing.
//
// So the demo gets the same treatment as the brand card, for the same reason:
// fixed content, no key, params ignored, no D1, no quota. It renders through
// buildElement, so it is an output of the API rather than a picture of one.
// A hand-made mockup here would have hidden the outage indefinitely.
const DEMO_CARD: OGParams = {
  title: 'How We Cut Cold-Start Latency by 80%',
  description:
    'A walk through the edge-caching path — what we measured, what we changed, and what it cost us.',
  domain: 'myblog.dev',
  tag: 'ENGINEERING',
  author: 'Rendered by OGForge — this is a real API response',
  theme: 'dark',
  template: 'default',
};

const DEMO_CARD_KEY = 'og/demo/v1.png';

// Both static cards share this. Two copies of the R2-cache dance is one copy too
// many, and the second copy is where the drift starts.
async function serveStaticCard(
  c: Context<{ Bindings: Env }>,
  card: OGParams,
  cacheKey: string
): Promise<Response> {
  const headers = (cacheState: 'HIT' | 'MISS') => ({
    'Content-Type': 'image/png',
    'Cache-Control': 'public, max-age=86400, s-maxage=604800',
    'X-Cache': cacheState,
    'X-OGForge-Rendered-By': 'ogforge',
  });

  const cached = await c.env.OG_CACHE.get(cacheKey);
  if (cached) {
    return new Response(await cached.arrayBuffer(), { headers: headers('HIT') });
  }

  const imageResponse = await generateOGImage(card, false);
  const imageBuffer = await imageResponse.arrayBuffer();

  c.executionCtx.waitUntil(
    c.env.OG_CACHE.put(cacheKey, imageBuffer.slice(0), {
      httpMetadata: { contentType: 'image/png' },
    })
  );

  return new Response(imageBuffer, { headers: headers('MISS') });
}

// These two record, and they are the highest-value rows this instrument can
// write. /brand.png is the og:image of BOTH the landing page (dashboard/pages.ts,
// og:image) and the postmortem (dashboard/postmortem.ts, og:image + twitter:image).
// Every reference to it from our own HTML is same-origin and is therefore dropped
// by the host test in recordInboundHit — so the noise floor here is zero, and a
// cross-origin Referer on an image means one specific thing: A THIRD PARTY
// EMBEDDED OUR CARD ON THEIR PAGE. That is a publication event. It needs no click
// and no human intent to be captured, which is exactly why it is worth more than a
// page view. Cycle #44 found these two were being thrown away.
app.get('/brand.png', c => {
  recordInboundHit(c, HIT_PATHS.brand);
  return serveStaticCard(c, BRAND_CARD, BRAND_CARD_KEY);
});
// Cycle #49: this handler ignored its query string. Two requests differing only
// by `?title=` returned byte-identical 42,251-byte bodies — measured, not assumed.
// That matters because Show HN's published guidelines, fetched in #49, say
// verbatim: "Please make it easy for users to try your thing out, ideally without
// barriers such as signups or emails." We failed that line twice over: `/og` is
// 401 without a key, and the one keyless path was a photograph of the product
// rather than the product. A stranger had no way to make this API do anything.
//
// So `title` — and only `title` — is now honoured. Everything the comment above
// claims for DEMO_CARD still holds: no key, no D1 quota, no user control over
// theme, template, domain, tag or author. The cache key is derived from the
// normalised title, so a repeat render is an R2 GET rather than a rasterise, and
// the unparameterised request keeps its original key and therefore its warm
// object. The exposure this opens is one unauthenticated rasterise per distinct
// title, bounded by DEMO_TITLE_MAX; that is stated here rather than discovered later.
const DEMO_TITLE_MAX = 120;

// Same alphabet as the rest of the cache namespace: a stable 32-bit hash keeps the
// key printable and fixed-length, and collisions only ever serve one demo card in
// place of another — there is nothing private in this namespace to leak.
function demoTitleKey(title: string): string {
  let h = 2166136261;
  for (let i = 0; i < title.length; i++) {
    h ^= title.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return `og/demo/v1-${(h >>> 0).toString(36)}.png`;
}

app.get('/demo.png', c => {
  recordInboundHit(c, HIT_PATHS.demo);

  const raw = c.req.query('title');
  const title = raw?.trim().slice(0, DEMO_TITLE_MAX);
  if (!title) {
    return serveStaticCard(c, DEMO_CARD, DEMO_CARD_KEY);
  }

  return serveStaticCard(c, { ...DEMO_CARD, title }, demoTitleKey(title));
});

// ── Registration ──────────────────────────────────────────────────────────────
app.get('/register', c => htmlResponse(registerPage(origin(c.req.url))));

app.post('/register', async c => {
  let email: string, keyname: string, tier: string;
  try {
    const form = await c.req.formData();
    email = (form.get('email') as string ?? '').trim().toLowerCase();
    keyname = (form.get('keyname') as string ?? '').trim() || 'default';
    tier = (form.get('tier') as string ?? 'free').trim();
  } catch {
    return htmlResponse(registerPage(origin(c.req.url), 'Invalid form data'), 400);
  }

  if (!email || !EMAIL_RE.test(email)) {
    return htmlResponse(registerPage(origin(c.req.url), 'Please enter a valid email address'), 400);
  }

  // Nothing on the site asks for a tier any more, but the guard stays: a
  // hand-crafted POST with tier=business must still land on the free plan. The
  // form field is a statement of intent, never an entitlement.
  const requestedTier = isPaidTier(tier) ? tier : null;
  const safeTier: Tier = SIGNUP_TIER;

  // Someone who went out of their way to ask for a bigger allowance is a demand
  // signal worth keeping. Best-effort: a failure here must not cost them a key.
  if (requestedTier) {
    await c.env.DB
      .prepare(
        'INSERT INTO tier_interest (id, email, requested_tier, source) VALUES (?, ?, ?, ?)'
      )
      .bind(crypto.randomUUID(), email, requestedTier, 'register')
      .run()
      .catch(err => console.error('tier_interest insert failed:', err));
  }

  // Upsert user
  const userId = crypto.randomUUID();
  await c.env.DB
    .prepare(
      'INSERT INTO users (id, email) VALUES (?, ?) ON CONFLICT(email) DO NOTHING'
    )
    .bind(userId, email)
    .run();

  const user = await c.env.DB
    .prepare('SELECT id FROM users WHERE email = ?')
    .bind(email)
    .first<{ id: string }>();
  if (!user) {
    return htmlResponse(registerPage(origin(c.req.url), 'Database error — please try again'), 500);
  }

  // Generate API key
  const rawKey = generateRawKey();
  const keyHash = await sha256(rawKey);
  const keyPrefix = rawKey.slice(0, 12);
  const keyId = crypto.randomUUID();
  const resetAt = new Date(new Date().getFullYear(), new Date().getMonth(), 1).toISOString();
  const monthlyLimit = TIER_LIMITS[safeTier];

  // The cap lives inside the INSERT so there is no window between counting and
  // writing — a burst of concurrent signups can't slip past a check-then-insert.
  // Zero rows written means the ceiling was already reached.
  const inserted = await c.env.DB
    .prepare(
      `INSERT INTO api_keys
         (id, user_id, name, key_prefix, key_hash, tier, monthly_limit, usage_reset_at)
       SELECT ?, ?, ?, ?, ?, ?, ?, ?
        WHERE (SELECT COUNT(*) FROM api_keys WHERE user_id = ?) < ?`
    )
    .bind(
      keyId,
      user.id,
      keyname,
      keyPrefix,
      keyHash,
      safeTier,
      monthlyLimit,
      resetAt,
      user.id,
      MAX_KEYS_PER_EMAIL
    )
    .run();

  // Zero rows written means the per-email ceiling was already reached.
  //
  // This answered 429 Too Many Requests for 56 cycles, and that was a misuse.
  // RFC 6585 §4 defines 429 as "too many requests IN A GIVEN AMOUNT OF TIME
  // ('rate limiting')". This condition has no time in it: the cap is
  // `COUNT(*) FROM api_keys WHERE user_id = ?` against a constant, and there is
  // no `DELETE FROM api_keys` anywhere in this worker, so the count never falls.
  // Waiting does not help — not in an hour, not ever. 429 is THE canonical
  // retryable status; mainstream HTTP clients retry it with backoff, which is
  // why RFC 6585 pairs it with Retry-After. We could not fill that header in
  // honestly, and that inability was the tell.
  //
  // Note the response was already contradicting itself: the BODY says "that's
  // the maximum" (never) while the STATUS LINE said "too many requests in a
  // given amount of time" (later). Measured on a local workerd before this fix.
  //
  // NOT 409 Conflict, which was the first candidate and was vetoed. RFC 9110
  // §15.5.10: 409 "is used in situations where the user MIGHT BE ABLE to
  // resolve the conflict and resubmit the request." With no key-deletion
  // endpoint the user cannot, so 409 would invite a manual retry that can never
  // succeed — the same lie as 429, told more quietly.
  //
  // 403 Forbidden is the honest code TODAY. RFC 9110 §15.5.4: "the server
  // understood the request but refuses to fulfill it… The client SHOULD NOT
  // automatically repeat the request." That anti-retry instruction is exactly
  // the semantic missing above, and it is carried by the status code itself.
  //
  // This code is downstream of a product decision not yet made. Ship key
  // revocation and 409 becomes the true code the same hour. Until then, 403.
  //
  // CYCLE #63: THAT LAST SENTENCE WAS A WORK ORDER THIS FILE ISSUED TO ITSELF,
  // AND IT WAS CITED BACK SIX CYCLES LATER AS A REQUIREMENT. #63 was assigned
  // to ship revocation and close it. It was VETOED, and the reason belongs
  // beside the code rather than only in a doc, because the next cycle to read
  // this comment will otherwise re-run the same job:
  //
  //   • The cap has never fired. Measured against remote D1 this cycle:
  //     MAX(keys per user) = 1 across all 7 users, 7 of 7 holding exactly one.
  //     This branch has not executed once in the product's life.
  //   • Revocation here could only be authenticated BY THE KEY, because there
  //     is no other credential — `readCredential()` is the whole auth system
  //     and there is no mail channel in the worker (checked: no resend /
  //     sendgrid / mailgun / postmark / smtp / mailchannels anywhere).
  //   • And the front page instructs the user to PUBLISH that key in page
  //     source. So a revoke route would let any stranger who viewed the source
  //     destroy the key permanently — with the 3-key lifetime cap, walk an
  //     account to zero. Today the worst case for a leaked key is quota theft,
  //     bounded by monthly_limit and self-healing at rollover (maybeResetUsage).
  //     Revocation would convert a bounded, self-healing harm into an
  //     unbounded, unrecoverable one.
  //
  // So the ordering in the "scoped, restrictable, revocable" property list is
  // wrong for this product: revocation is not the third of three, it is the
  // FOURTH OF FOUR, and the third — an account identity distinct from the
  // credential — does not exist. Shipping it before that is what makes it
  // harmful rather than merely unnecessary. 403 stays, and it stays honest.
  // Do not "fix" this to 409 and do not build revocation to justify the 409.
  if ((inserted.meta?.changes ?? 0) === 0) {
    return htmlResponse(
      registerPage(
        origin(c.req.url),
        `${email} already has ${MAX_KEYS_PER_EMAIL} API keys — that's the maximum, ` +
          `and it does not reset. Use one you already have, or open its dashboard ` +
          `to check usage. Each key gets its own monthly allowance, so extra keys ` +
          `are not a way to get extra images.`
      ),
      403
    );
  }

  return htmlResponse(keyCreatedPage(origin(c.req.url), rawKey, email, safeTier));
});

// ── Demand capture ────────────────────────────────────────────────────────────
// The only thing this deployment can honestly ask a visitor for: an address and
// the fact that 100 renders a month wasn't enough. Lands in `tier_interest` —
// the same table a paid-plan click used to be recorded in, which is now the
// only thing it is used for.
app.get('/interest', c => c.redirect('/#interest', 302));

app.post('/interest', async c => {
  const notice = (ok: boolean, message: string, status = 200) =>
    htmlResponse(landingPage(origin(c.req.url), { ok, message }), status);

  let email: string;
  try {
    const form = await c.req.formData();
    email = ((form.get('email') as string) ?? '').trim().toLowerCase();
  } catch {
    return notice(false, 'Invalid form data', 400);
  }

  if (!email || !EMAIL_RE.test(email)) {
    return notice(false, 'Please enter a valid email address', 400);
  }

  // Unlike signup, this one is not best-effort: if we did not store it, saying
  // "recorded" would be a lie.
  try {
    await c.env.DB.prepare(
      'INSERT INTO tier_interest (id, email, requested_tier, source) VALUES (?, ?, ?, ?)'
    )
      .bind(crypto.randomUUID(), email, INTEREST_REASON, 'landing')
      .run();
  } catch (err) {
    console.error('tier_interest insert failed:', err);
    return notice(false, "Couldn't record that — please try again in a moment.", 500);
  }

  return notice(
    true,
    `Recorded — ${email}. We'll ask you one question about what you needed. Nothing to pay, because there is nothing to buy.`
  );
});

// ── Admin: raise a key's monthly allowance ────────────────────────────────────
// Operator-only, and the only way a key's allowance ever changes. Gated on the
// AUTH_SECRET worker secret, which is unset by default — an unconfigured
// deployment cannot raise anyone's allowance at all.
app.post('/admin/upgrade', async c => {
  const secret = c.env.AUTH_SECRET;
  if (!secret) {
    return c.json({ error: 'Allowance grants are not configured on this deployment' }, 503);
  }

  const presented = c.req.header('X-Admin-Secret') ?? '';
  if (!timingSafeEqual(presented, secret)) {
    return c.json({ error: 'Forbidden' }, 403);
  }

  let body: { key_prefix?: string; tier?: string };
  try {
    body = await c.req.json();
  } catch {
    return c.json({ error: 'Expected a JSON body' }, 400);
  }

  const keyPrefix = (body.key_prefix ?? '').trim();
  const tier = (body.tier ?? '').trim();
  if (!keyPrefix) {
    return c.json({ error: 'key_prefix is required' }, 400);
  }
  if (!isPaidTier(tier)) {
    return c.json({ error: `tier must be one of: ${PAID_TIERS.join(', ')}` }, 400);
  }

  const target = await c.env.DB
    .prepare('SELECT * FROM api_keys WHERE key_prefix = ?')
    .bind(keyPrefix)
    .first<ApiKey>();
  if (!target) {
    return c.json({ error: 'No API key with that prefix' }, 404);
  }

  const upgradedAt = new Date().toISOString();
  await c.env.DB
    .prepare(
      'UPDATE api_keys SET tier = ?, monthly_limit = ?, upgraded_at = ? WHERE id = ?'
    )
    .bind(tier, TIER_LIMITS[tier], upgradedAt, target.id)
    .run();

  return c.json({
    ok: true,
    key_prefix: keyPrefix,
    tier,
    monthly_limit: TIER_LIMITS[tier],
    upgraded_at: upgradedAt,
  });
});

// ── Dashboard ─────────────────────────────────────────────────────────────────
// THE CONSTRAINT, WRITTEN DOWN — Cycle #62. It has governed this product since
// day one and had never been stated anywhere, in code or in docs.
//
// An `og:image` URL is fetched by anonymous third parties (Twitterbot, Slackbot,
// facebookexternalhit). It therefore CANNOT carry a request header, and the
// landing page consequently instructs the user to embed the credential itself:
//   <meta property="og:image" content="…/og?title=…&key=YOUR_KEY" />
// So the key is public BY CONSTRUCTION for the primary use case. Not by accident,
// not by a defect — there is no design of this product in which it is otherwise.
//
// A credential that must be published is legitimate (Stripe `pk_`, Maps browser
// keys) when three properties hold: it is SCOPED to low-harm operations, it is
// RESTRICTABLE to an origin, and it is REVOCABLE. This product has none of them:
// `domain=` is a cosmetic render label, `Referer`/`Origin` are client-supplied or
// absent so no origin lock is verifiable (Cycle #61), and there is no revocation.
//
// The line below was the third property's cost: `/dashboard` authenticated with
// `c.req.query('key')` — THE SAME STRING the landing page tells the user to
// publish — so the published render token was also the account console token.
// That is the part this cycle can act on, and the rule it leaves behind is:
//
//   *** /dashboard MUST NEVER grow an operation whose loss the holder of a
//   *** published og:image URL could not tolerate. Read-only, forever, until
//   *** the credential embedded in customer HTML stops being this string.
//
// Cycle #62 does not change WHICH string is accepted — removing `?key=` would
// break every issued key and the documented interface. It adds the RFC 6750 §2.1
// header form, which readCredential() has offered on /og since Cycle #55 and
// which this route silently ignored. Measured before the change: a request to
// /dashboard carrying `Authorization: Bearer …` and no query param returned a
// byte-identical 16,964 B "Get API Key" page — the header did nothing.
//
// The asymmetry is the point: /og advertises the recommended form to a caller
// (a <meta> tag) that structurally cannot send it, while /dashboard withheld it
// from the one caller (a human at a terminal) who can. The mitigation had been
// installed exactly where the primary use case could not reach it.
app.get('/dashboard', async c => {
  const rawKey = readCredential(c);
  if (!rawKey) {
    // 200, not 400. Every page's nav links here, so this is the ordinary way a
    // stranger arrives — and what they get back is a usable page asking for
    // their key, which is a normal page state, not a malformed request. Cycle
    // #19's asset checker flagged this on its first production run: a nav link
    // present on every page that answered 4xx to everyone who clicked it.
    // Reserve 4xx for requests that are actually wrong (see the 404 below, for
    // a key that was supplied and does not exist).
    // 'other' is load-bearing: this is /dashboard, not /register. Without it the
    // register page's canonical and og:url name /register while the request URL is
    // /dashboard — see the note on registerPage.
    // `Vary: Authorization` — the second half of this cycle's change, shipped in
    // the same commit because half of it is worse than none (#55 A1). Reading the
    // `Authorization` header is exactly what makes `Vary` mandatory here.
    //
    // ONLY this branch gets it, and the asymmetry is reasoned, not sloppy:
    //   • this branch is the one storable response on the route (it deliberately
    //     carries no Cache-Control — #58 A6's over-fire control), and as of this
    //     commit its representation is selected by a request header. Without
    //     `Vary`, a shared cache may store this "Get API Key" page and hand it
    //     back to a caller presenting a valid Bearer token. RFC 9111 §4.1.
    //   • the two branches below are `no-store`, where `Vary` selects among
    //     responses a cache MAY STORE and is therefore inert (#56 A3). Adding it
    //     there would be a plausible, legal, load-bearing-looking no-op.
    // Note this does NOT add Cache-Control to this branch; it stays the control.
    return htmlResponse(
      registerPage(origin(c.req.url), 'Enter your API key or create a new one below', 'other'),
      200,
      { ...NOINDEX_HEADER, Vary: 'Authorization' }
    );
  }

  // #58. From here down the representation is selected by a secret in the URL,
  // so both remaining branches are per-caller and neither may be stored. Note
  // that the branch ABOVE — no key at all — is deliberately left with no
  // Cache-Control: it is a static "enter your key" page in the same class as
  // `/` and `/register`, where the default is right. That is not tidiness, it
  // is the over-fire control, and it is structural rather than asserted: a
  // change that no-stored the whole route would have to touch a third call
  // site. The gate re-measures it after every deploy and expects NONE.
  const apiKey = await resolveApiKey(c.env.DB, rawKey);
  if (!apiKey) {
    // The reason is key-dependent representation, NOT secrecy. `no-store` hides
    // nothing: this 404 and the keyed 200 are already a perfect existence
    // oracle to whoever sent the request, and storage does not change that by
    // one bit — the same confusion #57 A2 vetoed. It is here because a cache
    // must not answer a second caller's key with the verdict on a first one's.
    // Its sibling 404s (a path with no route) stay heuristically cacheable and
    // correctly so; the two are byte-similar and now differ in exactly one
    // header, which is deliberate and not drift.
    return htmlResponse(errorPage(
        404,
        'API key not found',
        // Deliberately the SAME sentence bearerChallenge() puts in
        // `error_description` for the same fact on /og (#63). Two endpoints, two
        // status codes, one underlying condition: the key presented resolves to
        // no row. #63 A2's remedy is that the channels of one response agree; the
        // channels of one FACT agreeing is the same discipline one step out.
        // Says what the lookup did. Not `invalid`, `inactive` or `no longer
        // valid` — each implies a state or a transition this schema cannot
        // represent, which is the #63 A1 defect with new vocabulary.
        'No API key matches the credential supplied.'
      ), 404, NOINDEX_NO_STORE);
  }

  const refreshed = await maybeResetUsage(c.env.DB, apiKey);

  // Count recent events (last 24h)
  const yesterday = new Date(Date.now() - 86_400_000).toISOString();
  const recent = await c.env.DB
    .prepare(
      'SELECT COUNT(*) as cnt FROM usage_events WHERE api_key_id = ? AND generated_at > ?'
    )
    .bind(refreshed.id, yesterday)
    .first<{ cnt: number }>();

  return htmlResponse(
    dashboardPage(origin(c.req.url), refreshed, recent?.cnt ?? 0),
    200,
    // One caller's usage count, limit and reset date. The key itself is masked
    // in the body (`key_prefix••••`), so this is not a credential leak — it is
    // account state, which is reason enough on its own.
    NOINDEX_NO_STORE
  );
});

// ── Health / ops ──────────────────────────────────────────────────────────────
// ── Files every stranger's browser and every crawler asks for ────────────────
// Cycle #19 swept the external surface anonymously for the first time and found
// all three of these missing: /favicon.ico and /sitemap.xml were 404, and
// /robots.txt was answered by something upstream of this Worker with 1.2KB of
// content-signal boilerplate containing zero actual directives — no User-agent,
// no Allow, no Sitemap. We had never served, or read, any of them.

// The mark is the product's own subject: a 1200×630 card. Amber on near-black,
// matching the site. Drawn as geometry rather than a glyph because "OG" is
// illegible at 16px, while an aspect-ratio frame with a content block still
// reads as a distinct silhouette in a crowded tab strip.
const FAVICON_SVG = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">
  <rect width="32" height="32" rx="7" fill="#0A0A0A"/>
  <rect x="6" y="9.5" width="20" height="13" rx="2" fill="none" stroke="#F59E0B" stroke-width="2"/>
  <rect x="9" y="17" width="9" height="2.5" rx="1.25" fill="#F59E0B"/>
  <circle cx="21.5" cy="14" r="2" fill="#F59E0B"/>
</svg>`;

app.get('/favicon.svg', _c =>
  new Response(FAVICON_SVG, {
    headers: {
      'Content-Type': 'image/svg+xml; charset=utf-8',
      'Cache-Control': 'public, max-age=86400',
    },
  })
);

// Browsers and link unfurlers still probe the bare /favicon.ico path regardless
// of what <link rel="icon"> says, so that path must not 404.
app.get('/favicon.ico', c => c.redirect('/favicon.svg', 301));

// Ours, with directives that actually exist. /register is NOT key-scoped and used
// to be lumped in with /dashboard (cycle #21): it is a plain 200 HTML page and the
// only conversion point of a free product, so "free og image api key" ought to be
// able to land there. "Form-only" is not the same thing as "authenticated".
//
// Cycle #53: `Disallow: /dashboard` and `Disallow: /postmortem/hits` are GONE, and
// their removal is the fix, not a relaxation. Both paths want to stay out of search
// results, and both now say so where a crawler can actually hear it — see
// NOINDEX_HEADER above for Google's published rule. Disallow and noindex are not
// two locks on one door: Disallow stops the fetch, so the noindex behind it is
// never read, and the URL can still be listed from an inbound link. Exactly two
// mechanisms are in play now and they compose instead of cancelling.
//
// `Disallow: /admin/` STAYS, and the CONCLUSION survives while the fact behind
// it does not. #53 wrote "`/admin/` and `/admin/upgrade` both answer 404 to GET";
// #57 changed that and nobody came back here. Re-measured live in #64:
// `GET /admin/` -> 404 (no Allow), `GET /admin/upgrade` -> 405 `Allow: POST`.
// The line still cancels nothing, because what a 405 serves is an error page and
// an error page emits no robots directive either — but the reason on record was
// stale for seven cycles. Corrected rather than deleted: a Disallow with nothing
// behind it is still the right call, and now for a reason that was measured.
app.get('/robots.txt', c => {
  const site = origin(c.req.url);
  const body = [
    'User-agent: *',
    'Allow: /',
    'Disallow: /admin/',
    '',
    `Sitemap: ${site}/sitemap.xml`,
    '',
  ].join('\n');
  return new Response(body, {
    headers: {
      'Content-Type': 'text/plain; charset=utf-8',
      'Cache-Control': 'public, max-age=3600',
      'X-OGForge-Robots': 'ogforge-worker',
    },
  });
});

// Everything publicly useful. /dashboard is key-scoped so it stays out; /register
// is in as of cycle #21 (see robots.txt above). /demo.png was missing while
// /brand.png was listed — same kind of asset, no reason for the asymmetry.
//
// Cycle #54: `<changefreq>` and `<priority>` are GONE from all five entries, and
// `<lastmod>` was deliberately NOT added in their place. Both halves of that need
// their reason on the record, because the removal looks like a loss of signal and
// the omission looks like an oversight, and neither is.
//
// Why the two fields went. Both are legal — sitemaps.org marks all three optional,
// so no validator would ever have flagged this file. Against the one consumer whose
// rules we actually fetched, they are inert:
//
//   "Google ignores <priority> and <changefreq> values."
//     -- developers.google.com/search/docs/crawling-indexing/sitemaps/build-sitemap
//        (fetched 2026-09-10, HTTP 200, redirects=0)
//
// and the protocol spec itself says changefreq "is considered a hint and not a
// command" and that priority "is not likely to influence the position of your URLs".
// So the ten values here were read by nobody we can name — and two of them were
// false. This file told crawlers `${POSTMORTEM_PATH}` changes `yearly` while that
// page's bytes changed in cycles #50, #51, #52 and #53 — four consecutive cycles —
// and that `/` changes `weekly` while it changed several times in a single day.
// A claim with no readership is still a claim, and these were wrong.
//
// Why <lastmod> is NOT here, which is the harder half. It is the one field Google
// says it reads, so adding it is the obvious "fix" — and it is a trap:
//
//   "Google uses the <lastmod> value if it's consistently and verifiably (for
//    example by comparing to the last modification of the page) accurate."
//
// The use is CONDITIONAL on accuracy, and we have no per-page modification signal
// we can keep accurate. There is no build step, no CMS and no content table; every
// page here is rendered by this worker's code. The only date available at runtime
// is the worker's own deploy time (a `version_metadata` binding), and that is an
// upper bound, not a modification date: a deploy that touches only robots.txt would
// bump the lastmod of all five URLs. A date that is routinely too recent is exactly
// the inconsistency the sentence above conditions on, so that binding would buy a
// field Google then learns to distrust.
//
// The remaining option is hardcoding dates in this file. That is worse. Nothing
// would go red when a cycle edits a page and forgets to bump its date, so the value
// would rot silently into a falsehood that looks like evidence of freshness — a
// prop, by this company's own definition. Cycle #50 A3 states it directly: fixing
// an omission can install an assertion, and assertions can be false.
//
// Absent is honest. Emitting <loc> alone is Google's documented minimum minus a
// field we cannot support, and it is what this site can actually stand behind.
// If a real per-page modification signal ever exists, add <lastmod> then — the
// gate already checks that any lastmod appearing here is a valid W3C date and is
// not in the future, so the anti-relapse check is live before the field is.
app.get('/sitemap.xml', c => {
  const site = origin(c.req.url);
  const body = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>${site}/</loc></url>
  <url><loc>${site}/register</loc></url>
  <url><loc>${site}${POSTMORTEM_PATH}</loc></url>
  <url><loc>${site}/brand.png</loc></url>
  <url><loc>${site}/demo.png</loc></url>
</urlset>
`;
  return new Response(body, {
    headers: {
      'Content-Type': 'application/xml; charset=utf-8',
      'Cache-Control': 'public, max-age=3600',
    },
  });
});

// The whole content of this response is "I am alive, and it is now". A stored
// copy of it is not a stale answer to the question — it is a confident wrong
// one, because the field a reader would use to notice staleness (`ts`) is
// itself the thing that got frozen. Of the four responses this cycle marks, it
// is the one where heuristic caching could not produce anything true.
app.get('/health', c =>
  c.json({ ok: true, ts: new Date().toISOString() }, 200, NO_STORE_HEADER)
);

// ── Cycle #57: is the STATUS CODE true? ───────────────────────────────────────
// For 56 cycles `POST /` returned 404. Measured this cycle, before the fix:
// POST/PUT/DELETE/PATCH/OPTIONS on `/` → 404 with no Allow header, and the same
// for POST to /health, /robots.txt, /sitemap.xml, /dashboard, /postmortem/hits
// and /favicon.svg. RFC 9110 §15.5.5 (fetched, 502,941 B; section verified to
// exist at line 7587 — #56 A2):
//
//   "The 404 (Not Found) status code indicates that the origin server did not
//    find a current representation for the target resource or is not willing to
//    disclose that one exists."
//
// `/` HAS a current representation (GET / → 200, 33,473 B) and we are plainly
// WILLING to disclose it: it is the front door, it is one of the five <loc>
// entries in our own public sitemap.xml, and its canonical link names it. The
// 404 failed BOTH disjuncts. The true code is §15.5.6:
//
//   "The 405 (Method Not Allowed) status code indicates that the method received
//    in the request-line is known by the origin server but not supported by the
//    target resource. The origin server MUST generate an Allow header field in a
//    405 response containing a list of the target resource's currently supported
//    methods."
//
// Cycle #55 looked at this same behaviour and recorded it clean, reasoning that
// since we return 404 the "405 MUST send Allow" never applies. That is true and
// backwards: the MUST did not apply BECAUSE the code was wrong. A false status
// code cannot discharge the obligations of the true one by displacing it.
//
// The allowed-method set is derived from Hono's own `app.routes` — the array the
// route registrations above populate as a side effect of registering — and never
// from a hand-kept table, which would be a second source of truth free to drift
// (#43: a comment is not an implementation).
//
// THE FILTER IS ON THE METHOD, NOT THE PATH, and that distinction is the whole
// correctness of this block. The first draft skipped `route.path.includes('*')`,
// reasoning that `app.use('*', …)` is middleware. That tests "does the path
// string contain an asterisk" while claiming to test "is this middleware", and
// the two coincide only because our single `app.use` happens to be written with
// a star. Measured in this repo's Hono 4.12.12:
//
//   app.use('/dashboard', mw)  ->  { method: 'ALL', path: '/dashboard' }   <- no star
//   app.use('/dash/*', mw)     ->  { method: 'ALL', path: '/dash/*' }
//
// So the first path-scoped middleware anyone adds — `app.use('/dashboard',
// requireAuth)` is the obvious next commit — would have put ALL into the set and
// served `Allow: ALL, GET, HEAD`. `ALL` is not an HTTP method, but it is a valid
// token, so every client would have parsed it and no test would have failed.
// A method-agnostic registration says nothing about which methods a resource
// supports; that is the real property, so that is what is filtered on.
//
// BOUND (what this does NOT do): matching is exact string equality on the
// registered path. Every one of our 16 paths is static — no `:param`, no regex —
// so this is exact today. If a future route uses a pattern, it will not match
// here and that request falls through to 404, i.e. it degrades to the behaviour
// this comment is replacing rather than to something new.
//
// Computed lazily on first miss rather than at module scope, so its correctness
// does not depend on this block's line position in the file. A module-scope IIFE
// snapshots `app.routes` as it stands at that line, and a route registered below
// it would have been silently absent from every Allow header.
let allowedMethods: Map<string, string> | null = null;
function allowedMethodsFor(path: string): string | undefined {
  if (!allowedMethods) {
    const byPath = new Map<string, Set<string>>();
    for (const route of app.routes) {
      if (route.method.toUpperCase() === 'ALL') continue;
      const methods = byPath.get(route.path) ?? new Set<string>();
      methods.add(route.method.toUpperCase());
      byPath.set(route.path, methods);
    }
    allowedMethods = new Map<string, string>();
    for (const [p, methods] of byPath) {
      // HEAD is never in `app.routes` — Hono synthesizes it at dispatch, not at
      // registration: `node_modules/hono/dist/hono-base.js:273` rewrites a HEAD
      // request into a GET and returns the result with a null body. So the
      // source of truth for Allow is `app.routes` PLUS that one rule, and saying
      // "app.routes is the single source of truth" would have been false.
      // Confirmed by measurement too (HEAD / → 200), and RFC 9110 §9.1 line 3794
      // makes HEAD support mandatory regardless.
      if (methods.has('GET')) methods.add('HEAD');
      allowedMethods.set(p, [...methods].sort().join(', '));
    }
  }
  return allowedMethods.get(path);
}

// ONE RULE, NO EXCEPTIONS — and the exception is what had to be argued out.
// The first draft carved out /admin/upgrade, a live secret-gated operator
// endpoint, so it would keep its 404 under §15.5.5's second disjunct rather than
// answer `405 Allow: POST` and publish its own location. That was vetoed, on a
// measurement the draft had already made and misread. Live, right now:
//
//   POST /admin/upgrade      -> 403  application/json          21 B
//   POST /admin/nonexistent  -> 404  text/html; charset=utf-8  15,868 B
//   POST /no-such-page       -> 404  text/html; charset=utf-8  15,868 B
//
// The path is ALREADY a perfect existence oracle to anyone who sends POST, which
// is what path scanners send. Hiding it from GET is a lock on one door of a
// two-door room. Worse, it makes the carved-out 404 a NEW false status code
// under the very clause cited to justify it: §15.5.5's second disjunct requires
// that we are "not willing to disclose that one exists", and we disclose it on
// POST, in production, with a distinguishable status, content-type and length.
// The carve-out would have removed fifteen false 404s and manufactured a
// sixteenth with a citation attached — and a cited falsehood survives review,
// which an uncited one does not.
//
// Disclosure grants no privilege: the secret check is timing-safe and an unset
// AUTH_SECRET returns 503. If non-disclosure is ever actually wanted, that is a
// larger and different change — unauthenticated POST must return the
// byte-identical 404 that /admin/nonexistent returns — and it should be argued
// on its own rather than smuggled in as an exception to a rule about telling the
// truth. Shipping half of it is the only option that is wrong.
app.notFound(c => {
  const allow = allowedMethodsFor(c.req.path);
  if (allow) {
    // The Allow header is the MUST; it is not decoration. It also gives a client
    // exactly what an OPTIONS request would have returned, which matters because
    // we do not implement OPTIONS — RFC 9110 §9.1 (line 3794) makes GET and HEAD
    // the only mandatory methods and every other one OPTIONAL, so 405 is the
    // honest answer to OPTIONS rather than an omission to apologise for. Listing
    // OPTIONS in Allow while refusing it would be the same defect one level in.
    return htmlResponse(errorPage(
      405,
      'Method not allowed',
      // Deliberately does NOT enumerate the allowed methods. That was proposed
      // and VETOED this cycle: RFC 9110 §15.5.6's MUST is addressed to the
      // protocol client, which reads headers, so `Allow` above already reaches
      // the reader it names — its coverage is total and there is no #62 A1 gap
      // to close. Restating it here would be a new disclosure bundled into a
      // truthfulness fix, which is #57 A2 one level out.
      'This address does not accept that request method.'
    ), 405, {
      Allow: allow,
    });
  }
  return htmlResponse(errorPage(404, 'Page not found', 'No page exists at this address.'), 404);
});
app.onError((err, _c) => {
  console.error('Unhandled error:', err);
  return htmlResponse(errorPage(
    500,
    'Internal server error',
    // UNCHANGED, and it is the control. This is the one branch where the old
    // sentence was TRUE: an unhandled exception is something going wrong, and a
    // retry may genuinely succeed. If a future edit makes all four strings
    // agree, that is the bug returning, not tidiness.
    'Something went wrong. Try again or check the docs.'
  ), 500);
});

export default app;
