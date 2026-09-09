// OGForge — Main Cloudflare Worker
// Routes: GET /og (image gen), GET / (landing), GET/POST /register, GET /dashboard

import { Hono } from 'hono';
import { generateOGImage, buildCacheKey } from './og/render';
import {
  landingPage,
  registerPage,
  keyCreatedPage,
  dashboardPage,
  errorPage,
} from './dashboard/pages';
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

// ─── Routes ───────────────────────────────────────────────────────────────────

// Landing page
app.get('/', c => htmlResponse(landingPage(origin(c.req.url))));

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

app.get('/brand.png', async c => {
  const cached = await c.env.OG_CACHE.get(BRAND_CARD_KEY);
  if (cached) {
    return new Response(await cached.arrayBuffer(), {
      headers: {
        'Content-Type': 'image/png',
        'Cache-Control': 'public, max-age=86400, s-maxage=604800',
        'X-Cache': 'HIT',
        'X-OGForge-Rendered-By': 'ogforge',
      },
    });
  }

  const imageResponse = await generateOGImage(BRAND_CARD, false);
  const imageBuffer = await imageResponse.arrayBuffer();

  c.executionCtx.waitUntil(
    c.env.OG_CACHE.put(BRAND_CARD_KEY, imageBuffer.slice(0), {
      httpMetadata: { contentType: 'image/png' },
    })
  );

  return new Response(imageBuffer, {
    headers: {
      'Content-Type': 'image/png',
      'Cache-Control': 'public, max-age=86400, s-maxage=604800',
      'X-Cache': 'MISS',
      'X-OGForge-Rendered-By': 'ogforge',
    },
  });
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
    return htmlResponse(registerPage('Enter your API key or create a new one below'), 400);
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
app.get('/health', c => c.json({ ok: true, ts: new Date().toISOString() }));

// 404 fallback
app.notFound(_c => htmlResponse(errorPage(404, 'Page not found'), 404));
app.onError((err, _c) => {
  console.error('Unhandled error:', err);
  return htmlResponse(errorPage(500, 'Internal server error'), 500);
});

export default app;
