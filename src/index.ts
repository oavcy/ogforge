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

// Every copy-pasteable example on the site is built from the URL the visitor
// actually reached us on. Hardcoding a domain here is how a service ends up
// documenting an address that does not exist.
function origin(requestUrl: string): string {
  return new URL(requestUrl).origin;
}

function htmlResponse(html: string, status = 200): Response {
  return new Response(html, {
    status,
    headers: { 'Content-Type': 'text/html; charset=utf-8' },
  });
}

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

// ── OG image generation ────────────────────────────────────────────────────────
app.get('/og', async c => {
  const q = c.req.query();
  const rawKey = q['key'] ?? null;

  // Validate required param
  const title = (q['title'] ?? '').trim().slice(0, 120);
  if (!title) {
    return c.json({ error: 'title parameter is required' }, 400);
  }

  // Resolve API key (required)
  if (!rawKey) {
    return c.json({ error: 'key parameter is required. Get a free key at /register' }, 401);
  }
  let apiKey = await resolveApiKey(c.env.DB, rawKey);
  if (!apiKey) {
    return c.json({ error: 'Invalid API key' }, 401);
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
app.get('/demo.png', c => {
  recordInboundHit(c, HIT_PATHS.demo);
  return serveStaticCard(c, DEMO_CARD, DEMO_CARD_KEY);
});

// ── Registration ──────────────────────────────────────────────────────────────
app.get('/register', _c => htmlResponse(registerPage()));

app.post('/register', async c => {
  let email: string, keyname: string, tier: string;
  try {
    const form = await c.req.formData();
    email = (form.get('email') as string ?? '').trim().toLowerCase();
    keyname = (form.get('keyname') as string ?? '').trim() || 'default';
    tier = (form.get('tier') as string ?? 'free').trim();
  } catch {
    return htmlResponse(registerPage('Invalid form data'), 400);
  }

  if (!email || !EMAIL_RE.test(email)) {
    return htmlResponse(registerPage('Please enter a valid email address'), 400);
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
    return htmlResponse(registerPage('Database error — please try again'), 500);
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
    return htmlResponse(registerPage('Enter your API key or create a new one below'));
  }

  const apiKey = await resolveApiKey(c.env.DB, rawKey);
  if (!apiKey) {
    return htmlResponse(errorPage(404, 'API key not found'), 404);
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
    dashboardPage(origin(c.req.url), refreshed, recent?.cnt ?? 0)
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

// Ours, with directives that actually exist. Disallowing /dashboard and
// Keep key-scoped and admin paths out of indexes. /dashboard genuinely needs a
// key, so it is worthless as a search result. /register is NOT in that category
// and used to be lumped in with it (cycle #21): it is a plain 200 HTML page and
// the only conversion point of a free product, so "free og image api key" ought
// to be able to land there. "Form-only" is not the same thing as "authenticated".
app.get('/robots.txt', c => {
  const site = origin(c.req.url);
  const body = [
    'User-agent: *',
    'Allow: /',
    'Disallow: /dashboard',
    'Disallow: /admin/',
    // The postmortem page itself is very much indexable; only the JSON
    // instrument beneath it is not a search result anyone wants.
    'Disallow: /postmortem/hits',
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
app.get('/sitemap.xml', c => {
  const site = origin(c.req.url);
  const body = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>${site}/</loc><changefreq>weekly</changefreq><priority>1.0</priority></url>
  <url><loc>${site}/register</loc><changefreq>monthly</changefreq><priority>0.8</priority></url>
  <url><loc>${site}${POSTMORTEM_PATH}</loc><changefreq>yearly</changefreq><priority>0.9</priority></url>
  <url><loc>${site}/brand.png</loc><changefreq>monthly</changefreq><priority>0.3</priority></url>
  <url><loc>${site}/demo.png</loc><changefreq>monthly</changefreq><priority>0.3</priority></url>
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
