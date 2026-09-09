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
function bearerChallenge(invalidToken = false): string {
  return invalidToken
    ? `Bearer realm="${AUTH_REALM}", error="invalid_token", ` +
        `error_description="The API key is expired, revoked, or not valid"`
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
      },
      429
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

  if ((inserted.meta?.changes ?? 0) === 0) {
    return htmlResponse(
      registerPage(
        origin(c.req.url),
        `${email} already has ${MAX_KEYS_PER_EMAIL} API keys — that's the maximum. ` +
          `Use one you already have, or open its dashboard to check usage. ` +
          `Each key gets its own monthly allowance, so extra keys are not a way to get extra images.`
      ),
      429
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
app.get('/dashboard', async c => {
  const rawKey = c.req.query('key');
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
    return htmlResponse(
      registerPage(origin(c.req.url), 'Enter your API key or create a new one below', 'other'),
      200,
      NOINDEX_HEADER
    );
  }

  const apiKey = await resolveApiKey(c.env.DB, rawKey);
  if (!apiKey) {
    return htmlResponse(errorPage(404, 'API key not found'), 404, NOINDEX_HEADER);
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
    NOINDEX_HEADER
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
// `Disallow: /admin/` STAYS. Verified this cycle: `/admin/` and `/admin/upgrade`
// both answer 404 to GET (the only handler is a POST), so there is no page there
// emitting a directive for this line to suppress. A Disallow with nothing behind
// it cancels nothing.
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

app.get('/health', c => c.json({ ok: true, ts: new Date().toISOString() }));

// 404 fallback
app.notFound(_c => htmlResponse(errorPage(404, 'Page not found'), 404));
app.onError((err, _c) => {
  console.error('Unhandled error:', err);
  return htmlResponse(errorPage(500, 'Internal server error'), 500);
});

export default app;
