// OGForge — Dashboard & landing page HTML
// Aesthetic: "Carbon Terminal" — dark developer tool, amber accent, monospace-first

import type { ApiKey } from '../types';

// Email passes a loose regex on the way in, so `a<script>x</script>@b.co` is a
// "valid" address as far as signup is concerned. Anything user-supplied that
// lands in markup goes through here.
function esc(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

const CSS = `
  @import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:ital,wght@0,300;0,400;0,500;0,700;1,400&family=DM+Sans:ital,opsz,wght@0,9..40,300;0,9..40,400;0,9..40,500;0,9..40,700;1,9..40,400&display=swap');

  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

  :root {
    --bg:      #0A0A0A;
    --surface: #141414;
    --border:  #1F1F1F;
    --divider: #2A2A2A;
    --text-1:  #F5F5F5;
    --text-2:  #A3A3A3;
    --text-3:  #525252;
    --accent:  #F59E0B;
    --accent-dim: #92400E;
    --teal:    #14B8A6;
    --red:     #EF4444;
    --font-mono: 'JetBrains Mono', 'Consolas', monospace;
    --font-sans: 'DM Sans', system-ui, sans-serif;
    --r: 6px;
    --r-lg: 12px;
    --shadow: 0 0 0 1px var(--border);
  }

  html { scroll-behavior: smooth; }

  body {
    background: var(--bg);
    color: var(--text-1);
    font-family: var(--font-sans);
    font-size: 16px;
    line-height: 1.6;
    min-height: 100vh;
    /* Dot-grid background */
    background-image: radial-gradient(circle, #1F1F1F 1px, transparent 1px);
    background-size: 32px 32px;
  }

  a { color: var(--accent); text-decoration: none; }
  a:hover { text-decoration: underline; }

  /* Nav */
  .nav {
    position: sticky; top: 0; z-index: 100;
    display: flex; align-items: center; justify-content: space-between;
    padding: 16px 32px;
    background: rgba(10,10,10,0.92);
    backdrop-filter: blur(12px);
    border-bottom: 1px solid var(--border);
  }
  .nav-logo {
    font-family: var(--font-mono);
    font-weight: 700;
    font-size: 18px;
    color: var(--text-1);
    letter-spacing: -0.02em;
  }
  .nav-logo span { color: var(--accent); }
  .nav-links { display: flex; gap: 24px; align-items: center; }
  /* :not(.btn) matters. The bare descendant selector is specificity 0-1-1 and .btn-primary
     is 0-1-0, so without it the nav CTA loses its own colour and renders #A3A3A3 on amber
     — about 1.5:1, illegible. It shipped that way until cycle #14. */
  .nav-links a:not(.btn) { color: var(--text-2); font-size: 14px; }
  .nav-links a:not(.btn):hover { color: var(--text-1); text-decoration: none; }
  .btn {
    display: inline-flex; align-items: center; justify-content: center;
    font-family: var(--font-mono); font-size: 13px; font-weight: 500;
    padding: 8px 20px; border-radius: var(--r);
    border: none; cursor: pointer; transition: all 0.15s;
    text-decoration: none;
  }
  .btn-primary { background: var(--accent); color: #000; }
  .btn-primary:hover { background: #FBBF24; text-decoration: none; }
  .btn-ghost { background: transparent; color: var(--text-2); border: 1px solid var(--border); }
  .btn-ghost:hover { border-color: var(--accent); color: var(--accent); text-decoration: none; }

  /* Container */
  .container { max-width: 900px; margin: 0 auto; padding: 0 24px; }
  .container-wide { max-width: 1100px; margin: 0 auto; padding: 0 24px; }

  /* Hero */
  .hero { padding: 100px 0 72px; text-align: center; position: relative; }
  .hero-eyebrow {
    display: inline-flex; align-items: center; gap: 8px;
    font-family: var(--font-mono); font-size: 12px; color: var(--accent);
    letter-spacing: 0.1em; text-transform: uppercase;
    border: 1px solid var(--accent-dim); border-radius: 100px;
    padding: 4px 14px; margin-bottom: 28px;
  }
  .hero-eyebrow::before {
    content: ''; width: 6px; height: 6px; border-radius: 50%;
    background: var(--accent); animation: pulse 2s ease-in-out infinite;
  }
  @keyframes pulse {
    0%, 100% { opacity: 1; transform: scale(1); }
    50% { opacity: 0.4; transform: scale(0.8); }
  }
  .hero h1 {
    font-size: clamp(42px, 6vw, 72px);
    font-weight: 700; letter-spacing: -0.04em;
    line-height: 1.05;
    background: linear-gradient(135deg, #F5F5F5 0%, #A3A3A3 100%);
    -webkit-background-clip: text; -webkit-text-fill-color: transparent;
    background-clip: text;
    margin-bottom: 24px;
  }
  .hero h1 em {
    font-style: normal;
    background: linear-gradient(135deg, var(--accent), #FCD34D);
    -webkit-background-clip: text; -webkit-text-fill-color: transparent;
    background-clip: text;
  }
  .hero-sub {
    font-size: 18px; color: var(--text-2); max-width: 560px; margin: 0 auto 40px;
    line-height: 1.65;
  }
  .hero-cta { display: flex; gap: 12px; justify-content: center; }

  /* OG Preview */
  .og-preview-wrap {
    position: relative; margin: 72px auto 0; max-width: 720px;
    border-radius: var(--r-lg); overflow: hidden;
    box-shadow: 0 0 0 1px var(--border), 0 40px 80px rgba(0,0,0,0.6);
  }
  .og-preview-wrap img {
    width: 100%; display: block;
    border-radius: var(--r-lg);
  }
  .og-preview-label {
    position: absolute; top: 12px; left: 12px;
    font-family: var(--font-mono); font-size: 11px; color: var(--text-3);
    background: var(--surface); border: 1px solid var(--border);
    padding: 4px 10px; border-radius: var(--r);
  }

  /* Section */
  .section { padding: 80px 0; }
  .section-title {
    font-family: var(--font-mono); font-size: 11px; font-weight: 500;
    color: var(--accent); letter-spacing: 0.12em; text-transform: uppercase;
    margin-bottom: 12px;
  }
  .section-h2 {
    font-size: 36px; font-weight: 700; letter-spacing: -0.025em;
    margin-bottom: 16px; line-height: 1.15;
  }
  .section-sub { font-size: 17px; color: var(--text-2); max-width: 480px; line-height: 1.6; }

  /* Code block */
  .code-block {
    background: var(--surface); border: 1px solid var(--border);
    border-radius: var(--r-lg); overflow: hidden; margin-top: 32px;
  }
  .code-block-header {
    display: flex; align-items: center; justify-content: space-between;
    padding: 12px 20px; border-bottom: 1px solid var(--border);
  }
  .code-block-lang {
    font-family: var(--font-mono); font-size: 12px; color: var(--text-3);
    letter-spacing: 0.06em;
  }
  .code-block-dots { display: flex; gap: 6px; }
  .dot { width: 10px; height: 10px; border-radius: 50%; }
  .dot-red { background: #FF5F57; }
  .dot-yellow { background: #FEBC2E; }
  .dot-green { background: #28C840; }
  .code-block pre {
    padding: 24px 20px; font-family: var(--font-mono); font-size: 13px;
    line-height: 1.7; color: var(--text-1); overflow-x: auto;
    white-space: pre;
  }
  .c-comment { color: var(--text-3); }
  .c-key { color: var(--teal); }
  .c-val { color: #86EFAC; }
  .c-str { color: #FCD34D; }
  .c-url { color: var(--accent); }

  /* API params table */
  .params-table { width: 100%; border-collapse: collapse; margin-top: 24px; }
  .params-table th, .params-table td {
    padding: 12px 16px; text-align: left;
    border-bottom: 1px solid var(--border); font-size: 14px;
  }
  .params-table th {
    font-family: var(--font-mono); font-size: 11px; color: var(--text-3);
    letter-spacing: 0.08em; text-transform: uppercase;
  }
  .params-table td:first-child { font-family: var(--font-mono); color: var(--teal); }
  .params-table .required {
    font-family: var(--font-mono); font-size: 10px; color: var(--accent);
    border: 1px solid var(--accent-dim); border-radius: 3px; padding: 1px 6px;
  }
  .params-table .optional {
    font-family: var(--font-mono); font-size: 10px; color: var(--text-3);
    border: 1px solid var(--border); border-radius: 3px; padding: 1px 6px;
  }

  /* Limits & interest */
  .limits-grid {
    display: grid; grid-template-columns: repeat(2, 1fr); gap: 16px;
    margin-top: 48px; align-items: start;
  }
  .limits-list { list-style: none; }
  .limits-list li {
    font-size: 14px; color: var(--text-2); padding: 6px 0;
    display: flex; gap: 8px; align-items: flex-start;
  }
  .limits-list li::before { content: '→'; color: var(--accent); flex-shrink: 0; }
  .limits-list li.dim { color: var(--text-3); }
  .limits-list li.dim::before { color: var(--text-3); }
  .card-accent {
    border-color: var(--accent-dim);
    background: linear-gradient(180deg, #1C1400 0%, var(--surface) 100%);
  }

  /* Features grid */
  .features-grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 24px; margin-top: 48px; }
  .feature-card {
    background: var(--surface); border: 1px solid var(--border);
    border-radius: var(--r-lg); padding: 28px;
  }
  .feature-icon {
    font-family: var(--font-mono); font-size: 20px; color: var(--accent);
    margin-bottom: 16px; display: block;
  }
  .feature-card h3 { font-size: 17px; font-weight: 600; margin-bottom: 8px; }
  .feature-card p { font-size: 14px; color: var(--text-2); line-height: 1.6; }

  /* Dashboard */
  .dash-layout { padding: 40px 0 80px; }
  .dash-header { margin-bottom: 40px; }
  .dash-header h1 { font-size: 26px; font-weight: 700; margin-bottom: 4px; letter-spacing: -0.02em; }
  .dash-header p { font-size: 14px; color: var(--text-2); }

  .dash-grid { display: grid; grid-template-columns: 2fr 1fr; gap: 24px; }
  .dash-grid-full { grid-column: 1 / -1; }

  .card {
    background: var(--surface); border: 1px solid var(--border);
    border-radius: var(--r-lg); padding: 28px;
  }
  .card-title {
    font-family: var(--font-mono); font-size: 11px; font-weight: 500;
    color: var(--text-3); letter-spacing: 0.1em; text-transform: uppercase;
    margin-bottom: 20px;
  }

  /* API key display */
  .api-key-display {
    display: flex; align-items: center; gap: 8px;
    background: var(--bg); border: 1px solid var(--border);
    border-radius: var(--r); padding: 12px 16px;
    font-family: var(--font-mono); font-size: 13px; color: var(--text-2);
    flex: 1;
  }
  .api-key-display .key-val { flex: 1; word-break: break-all; }
  .api-key-row { display: flex; gap: 8px; align-items: stretch; }

  /* Usage meter */
  .usage-bar-wrap {
    background: var(--bg); border-radius: 100px;
    height: 6px; margin: 12px 0 8px; overflow: hidden;
  }
  .usage-bar {
    height: 100%; border-radius: 100px;
    background: var(--accent);
    transition: width 0.6s ease;
  }
  .usage-bar.warn { background: #F97316; }
  .usage-bar.full { background: var(--red); }
  .usage-meta { display: flex; justify-content: space-between; font-size: 13px; }
  .usage-count { font-family: var(--font-mono); font-size: 28px; font-weight: 700; }
  .usage-limit { font-size: 13px; color: var(--text-3); }

  /* Allowance badge. Deliberately one neutral style for every tier value: a badge
     that renders 'pro' in gold is paid-tier UI, and nothing here is for sale. */
  .tier-badge {
    display: inline-flex; align-items: center;
    font-family: var(--font-mono); font-size: 10px; letter-spacing: 0.08em;
    text-transform: uppercase; padding: 3px 10px; border-radius: 100px;
    background: #1C1C1C; color: var(--text-3); border: 1px solid var(--border);
  }

  /* Register form */
  .form-group { margin-bottom: 20px; }
  .form-label { display: block; font-family: var(--font-mono); font-size: 12px; color: var(--text-2); margin-bottom: 8px; letter-spacing: 0.06em; }
  .form-input {
    width: 100%; padding: 12px 16px;
    background: var(--bg); border: 1px solid var(--border);
    border-radius: var(--r); font-family: var(--font-mono);
    font-size: 14px; color: var(--text-1);
    outline: none; transition: border-color 0.15s;
  }
  .form-input:focus { border-color: var(--accent); }
  .form-hint { font-size: 12px; color: var(--text-3); margin-top: 6px; }

  /* Alert */
  .alert { padding: 14px 18px; border-radius: var(--r); font-size: 14px; margin-bottom: 20px; }
  .alert-error { background: #1C0A0A; border: 1px solid #7F1D1D; color: #FCA5A5; }
  .alert-success { background: #052E16; border: 1px solid #14532D; color: #86EFAC; }

  /* Fork in the road — hosted vs self-host */
  .fork-grid {
    display: grid; grid-template-columns: 1fr auto 1fr;
    gap: 0; margin-top: 40px; align-items: stretch;
  }
  .fork-rail {
    display: flex; flex-direction: column; align-items: center;
    gap: 14px; padding: 0 28px;
  }
  .fork-rail::before, .fork-rail::after {
    content: ''; flex: 1; width: 1px; background: var(--divider);
  }
  .fork-rail span {
    font-family: var(--font-mono); font-size: 10px; letter-spacing: 0.18em;
    text-transform: uppercase; color: var(--text-3);
    border: 1px solid var(--divider); border-radius: 100px;
    padding: 5px 12px; background: var(--bg);
  }
  .fork-pane {
    background: var(--surface); border: 1px solid var(--border);
    border-radius: var(--r-lg); padding: 28px;
    display: flex; flex-direction: column;
    transition: border-color 0.2s;
  }
  .fork-pane:hover { border-color: var(--divider); }
  .fork-pane.is-ours { border-top: 2px solid var(--teal); }
  .fork-pane.is-yours { border-top: 2px solid var(--accent); }
  .fork-pane h3 {
    font-size: 19px; font-weight: 500; letter-spacing: -0.01em; margin-bottom: 6px;
  }
  .fork-verdict {
    font-family: var(--font-mono); font-size: 11px; letter-spacing: 0.08em;
    text-transform: uppercase; margin-bottom: 18px;
  }
  .is-ours .fork-verdict { color: var(--teal); }
  .is-yours .fork-verdict { color: var(--accent); }
  .fork-list { list-style: none; font-size: 14px; color: var(--text-2); line-height: 1.9; }
  .fork-list li { padding-left: 20px; position: relative; }
  .fork-list li::before {
    content: '–'; position: absolute; left: 0;
    font-family: var(--font-mono); color: var(--text-3);
  }
  .fork-shell {
    background: var(--bg); border: 1px solid var(--border);
    border-radius: var(--r); padding: 16px;
    font-family: var(--font-mono); font-size: 12px; line-height: 1.9;
    color: var(--text-2); overflow-x: auto; white-space: pre;
    margin: 18px 0 0;
  }
  .fork-shell .c-prompt { color: var(--text-3); user-select: none; }
  .fork-foot { margin-top: auto; padding-top: 24px; }

  /* Footer */
  .footer {
    border-top: 1px solid var(--border); padding: 32px 0;
    text-align: center; font-size: 13px; color: var(--text-3);
    font-family: var(--font-mono);
  }

  @media (max-width: 768px) {
    .limits-grid { grid-template-columns: 1fr; }
    .features-grid { grid-template-columns: 1fr; }
    .fork-grid { grid-template-columns: 1fr; gap: 16px; }
    .fork-rail { flex-direction: row; padding: 0; }
    .fork-rail::before, .fork-rail::after { width: auto; height: 1px; flex: 1; }
    .dash-grid { grid-template-columns: 1fr; }
    .hero h1 { font-size: 36px; }
  }
`;

// Meta tags a social crawler reads when someone shares our link. Absolute URLs
// are mandatory here — Slack, Discord, Twitter and iMessage all discard a
// relative og:image, which is why this takes an origin instead of using '/'.
//
// og:image points at /brand.png, our own API's output. Dogfooding is the whole
// argument: a preview card rendered by anything else would be a claim, this one
// is a demonstration.
function socialHead(origin: string, title: string, description: string): string {
  const url = `${origin}/`;
  const image = `${origin}/brand.png`;
  return `
  <link rel="canonical" href="${esc(url)}" />
  <meta property="og:type" content="website" />
  <meta property="og:site_name" content="OGForge" />
  <meta property="og:url" content="${esc(url)}" />
  <meta property="og:title" content="${esc(title)}" />
  <meta property="og:description" content="${esc(description)}" />
  <meta property="og:image" content="${esc(image)}" />
  <meta property="og:image:width" content="1200" />
  <meta property="og:image:height" content="630" />
  <meta property="og:image:alt" content="${esc(title)}" />
  <meta name="twitter:card" content="summary_large_image" />
  <meta name="twitter:title" content="${esc(title)}" />
  <meta name="twitter:description" content="${esc(description)}" />
  <meta name="twitter:image" content="${esc(image)}" />`;
}

function layout(title: string, body: string, extraHead = ''): string {
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>${title} — OGForge</title>
  <meta name="description" content="Generate stunning Open Graph images via API. Hosted on Cloudflare edge, cached globally, delivered in milliseconds." />
  <style>${CSS}</style>
  ${extraHead}
</head>
<body>
  ${body}
</body>
</html>`;
}

// Public source. OGForge is MIT — the self-host path is a first-class option, not a
// fallback, so the link belongs in the nav rather than buried in a footer.
const REPO_URL = 'https://github.com/oavcy/ogforge';

function nav(_activePath = '/'): string {
  return `
  <nav class="nav">
    <a class="nav-logo" href="/">Snap<span>OG</span></a>
    <div class="nav-links">
      <a href="/#how-it-works">Docs</a>
      <a href="/#limits">Limits</a>
      <a href="${REPO_URL}">Source</a>
      <a href="/register" class="btn btn-primary">Get API Key →</a>
    </div>
  </nav>`;
}

function footer(): string {
  return `
  <footer class="footer">
    <div class="container">
      OGForge — OG images at the edge. MIT-licensed, built on Cloudflare Workers.
      <a href="${REPO_URL}" style="color:var(--text-2);">Source on GitHub ↗</a>
    </div>
  </footer>`;
}

// `origin` is the scheme + host the visitor actually reached us on, e.g.
// http://127.0.0.1:8787 locally or https://snapog.<account>.workers.dev once
// deployed. Every example below is built from it so the docs can never drift
// from reality.
export function landingPage(
  origin: string,
  interest?: { ok: boolean; message: string }
): string {
  const notice = interest
    ? `<div class="alert alert-${interest.ok ? 'success' : 'error'}">${esc(interest.message)}</div>`
    : '';
  const body = `
  ${nav('/')}

  <!-- Hero -->
  <section class="hero">
    <div class="container">
      <div class="hero-eyebrow">Open Graph Images API</div>
      <h1>OG images for every URL,<br/><em>delivered at the edge</em></h1>
      <p class="hero-sub">
        One API call. Instant PNG. Cached globally on Cloudflare CDN.
        Stop hand-coding OG templates — let OGForge generate them dynamically.
      </p>
      <div class="hero-cta">
        <a href="/register" class="btn btn-primary" style="font-size:15px;padding:12px 28px;">Get Free API Key</a>
        <a href="/#how-it-works" class="btn btn-ghost" style="font-size:15px;padding:12px 28px;">View Docs</a>
      </div>

      <!-- Live OG preview -->
      <div class="og-preview-wrap" style="margin-top:56px;">
        <div class="og-preview-label">1200 × 630 PNG — rendered live</div>
        <img
          src="/og?title=How%20We%20Cut%20Cold-Start%20Latency%20by%2080%25&description=A%20walk%20through%20the%20edge-caching%20path%20%E2%80%94%20what%20we%20measured%2C%20what%20we%20changed%2C%20and%20what%20it%20cost%20us&domain=myblog.dev&theme=dark&template=default"
          alt="Live OG image example"
          style="width:100%;border-radius:8px;"
        />
      </div>
    </div>
  </section>

  <!-- How it works -->
  <section class="section" id="how-it-works">
    <div class="container">
      <p class="section-title">API Reference</p>
      <h2 class="section-h2">One endpoint, infinite images</h2>
      <p class="section-sub">
        Send a GET request. Get a PNG back. Cache it in your CDN. Done.
      </p>

      <div class="code-block" style="margin-top:36px;">
        <div class="code-block-header">
          <div class="code-block-dots">
            <div class="dot dot-red"></div>
            <div class="dot dot-yellow"></div>
            <div class="dot dot-green"></div>
          </div>
          <span class="code-block-lang">HTTP GET</span>
        </div>
        <pre><span class="c-url">GET ${origin}/og</span>
  <span class="c-comment">  ?title=</span><span class="c-str">Your Page Title Here</span>
  <span class="c-comment">  &amp;description=</span><span class="c-str">Optional subtitle or excerpt</span>
  <span class="c-comment">  &amp;domain=</span><span class="c-str">yourdomain.com</span>
  <span class="c-comment">  &amp;author=</span><span class="c-str">Jane Doe</span>
  <span class="c-comment">  &amp;template=</span><span class="c-str">default</span>  <span class="c-comment"># default | blog | article</span>
  <span class="c-comment">  &amp;theme=</span><span class="c-str">dark</span>      <span class="c-comment"># dark | light</span>
  <span class="c-comment">  &amp;tag=</span><span class="c-str">Tutorial</span>
  <span class="c-comment">  &amp;key=</span><span class="c-str">sk_your_api_key</span>

<span class="c-comment">← 200 OK  Content-Type: image/png  X-Cache: MISS</span></pre>
      </div>

      <h3 style="font-size:18px;font-weight:600;margin:48px 0 0;letter-spacing:-0.01em;">Parameters</h3>
      <table class="params-table">
        <thead>
          <tr>
            <th>Param</th><th>Type</th><th>Required</th><th>Description</th>
          </tr>
        </thead>
        <tbody>
          <tr><td>title</td><td>string</td><td><span class="required">required</span></td><td>Page title — the main headline (max 120 chars)</td></tr>
          <tr><td>key</td><td>string</td><td><span class="required">required</span></td><td>Your API key (100 rendered images/month; cache hits are free)</td></tr>
          <tr><td>description</td><td>string</td><td><span class="optional">optional</span></td><td>Subtitle or page excerpt (max 200 chars)</td></tr>
          <tr><td>domain</td><td>string</td><td><span class="optional">optional</span></td><td>Your domain shown as source label</td></tr>
          <tr><td>author</td><td>string</td><td><span class="optional">optional</span></td><td>Author name shown in footer</td></tr>
          <tr><td>template</td><td>enum</td><td><span class="optional">optional</span></td><td><code>default</code> | <code>blog</code> | <code>article</code></td></tr>
          <tr><td>theme</td><td>enum</td><td><span class="optional">optional</span></td><td><code>dark</code> (default) | <code>light</code></td></tr>
          <tr><td>tag</td><td>string</td><td><span class="optional">optional</span></td><td>Category label shown as pill (e.g. "Tutorial")</td></tr>
        </tbody>
      </table>

      <h3 style="font-size:18px;font-weight:600;margin:48px 0 20px;letter-spacing:-0.01em;">Use in HTML</h3>
      <div class="code-block">
        <div class="code-block-header">
          <div class="code-block-dots">
            <div class="dot dot-red"></div><div class="dot dot-yellow"></div><div class="dot dot-green"></div>
          </div>
          <span class="code-block-lang">HTML meta tags</span>
        </div>
        <pre><span class="c-comment">&lt;!-- Drop in &lt;head&gt; --&gt;</span>
<span class="c-key">&lt;meta</span> <span class="c-val">property=</span><span class="c-str">"og:image"</span>
      <span class="c-val">content=</span><span class="c-str">"${origin}/og?title=My+Post+Title&amp;key=YOUR_KEY"</span> <span class="c-key">/&gt;</span>
<span class="c-key">&lt;meta</span> <span class="c-val">property=</span><span class="c-str">"og:image:width"</span>  <span class="c-val">content=</span><span class="c-str">"1200"</span> <span class="c-key">/&gt;</span>
<span class="c-key">&lt;meta</span> <span class="c-val">property=</span><span class="c-str">"og:image:height"</span> <span class="c-val">content=</span><span class="c-str">"630"</span>  <span class="c-key">/&gt;</span>
<span class="c-key">&lt;meta</span> <span class="c-val">name=</span><span class="c-str">"twitter:card"</span>    <span class="c-val">content=</span><span class="c-str">"summary_large_image"</span> <span class="c-key">/&gt;</span>
<span class="c-key">&lt;meta</span> <span class="c-val">name=</span><span class="c-str">"twitter:image"</span>   <span class="c-val">content=</span><span class="c-str">"${origin}/og?title=My+Post+Title&amp;key=YOUR_KEY"</span> <span class="c-key">/&gt;</span></pre>
      </div>
    </div>
  </section>

  <!-- Features -->
  <section class="section" style="padding-top:0;">
    <div class="container">
      <p class="section-title">Why OGForge</p>
      <h2 class="section-h2">Four things a one-off snippet won't do for you</h2>
      <div class="features-grid">
        <div class="feature-card">
          <span class="feature-icon">⚡</span>
          <h3>Edge-cached globally</h3>
          <p>Images are generated once and stored on Cloudflare R2. Subsequent requests hit the cache in under 50ms worldwide.</p>
        </div>
        <div class="feature-card">
          <span class="feature-icon">🎨</span>
          <h3>3 templates out of the box</h3>
          <p>Default, Blog, and Article templates — dark and light variants. No design work needed.</p>
        </div>
        <div class="feature-card">
          <span class="feature-icon">🔑</span>
          <h3>Instant API key</h3>
          <p>Sign up with email, get a key immediately. 100 rendered images a month, free.</p>
        </div>
        <div class="feature-card">
          <span class="feature-icon">📊</span>
          <h3>Usage dashboard</h3>
          <p>Track how many images you've generated, how much of the monthly limit is left, and when it resets.</p>
        </div>
      </div>
    </div>
  </section>

  <!-- Limits & demand capture -->
  <section class="section" id="limits">
    <div class="container">
      <p class="section-title">What it costs</p>
      <h2 class="section-h2">Free while we find out if anyone wants it.</h2>
      <p class="section-sub">
        Nothing here is for sale. There is no payment page, no card form, and no plan
        hiding behind a button — just a key, a real limit, and one question we can't
        answer without you.
      </p>
      <div class="limits-grid">

        <div class="card">
          <p class="card-title">The limits, in full</p>
          <ul class="limits-list">
            <li>100 rendered images per month, per key</li>
            <li>Cache hits are free and unmetered — re-fetches never count</li>
            <li>Images already cached keep serving after the limit is reached</li>
            <li>3 templates, dark and light</li>
            <li>3 keys per email address</li>
            <li class="dim">Rendered images carry a small OGForge watermark</li>
          </ul>
          <div style="margin-top:28px;">
            <a href="/register" class="btn btn-ghost" style="width:100%;">Get a key →</a>
          </div>
        </div>

        <div class="card card-accent" id="interest">
          <p class="card-title">100 a month not enough?</p>
          ${notice}
          <p style="font-size:14px;color:var(--text-2);">
            Then say so. We built this before anyone asked for it, so a real address from
            someone who hit the ceiling is worth more to us than any amount of code.
            Leave your email and we'll ask you what you needed.
          </p>
          <form method="POST" action="/interest#interest" style="margin-top:20px;">
            <div class="form-group">
              <label class="form-label" for="interest-email">EMAIL ADDRESS</label>
              <input class="form-input" type="email" name="email" id="interest-email" placeholder="you@example.com" required autocomplete="email" />
              <p class="form-hint">Used to ask one question. No list, no newsletter, nothing to buy.</p>
            </div>
            <button type="submit" class="btn btn-primary" style="width:100%;">Tell us you need more →</button>
          </form>
        </div>

      </div>
    </div>
  </section>

  <!-- Fork in the road: hosted vs self-host. Both paths are real; the repo link is
       not a courtesy. If the honest answer for a visitor is "run it yourself", the
       page should say so rather than route them through a signup they don't need. -->
  <section class="section" id="source" style="padding-top:0;">
    <div class="container">
      <p class="section-title">Source</p>
      <h2 class="section-h2">MIT-licensed. Run ours, or run your own.</h2>
      <p class="section-sub">
        The whole thing is about 1,900 lines. If you're already on Cloudflare, the
        second column is the better deal, and we'd rather tell you that than bury it.
      </p>

      <div class="fork-grid">

        <div class="fork-pane is-ours">
          <h3>Use our instance</h3>
          <p class="fork-verdict">→ fastest to a working &lt;meta&gt; tag</p>
          <ul class="fork-list">
            <li>Email in, key out, roughly 30 seconds</li>
            <li>100 rendered images a month, cache hits unmetered</li>
            <li>Nothing to provision, nothing to pay</li>
            <li>Rendered images carry a small watermark</li>
            <li>Your usage rows live on our D1</li>
          </ul>
          <div class="fork-foot">
            <a href="/register" class="btn btn-ghost" style="width:100%;">Get a key →</a>
          </div>
        </div>

        <div class="fork-rail"><span>or</span></div>

        <div class="fork-pane is-yours">
          <h3>Run it on your account</h3>
          <p class="fork-verdict">→ no watermark, no limit, no us</p>
          <ul class="fork-list">
            <li>Your Workers, your D1, your R2, your data</li>
            <li>Delete the watermark line — it's your deploy</li>
            <li>Cloudflare's free tier covers most blogs</li>
            <li>No key to rotate, no service to outlive us</li>
          </ul>
          <pre class="fork-shell"><span class="c-prompt">$</span> git clone ${REPO_URL}.git
<span class="c-prompt">$</span> npm install
<span class="c-prompt">$</span> npx wrangler d1 create snapog-db
<span class="c-prompt">$</span> npx wrangler deploy --env production</pre>
          <div class="fork-foot">
            <a href="${REPO_URL}" class="btn btn-primary" style="width:100%;">Read the source ↗</a>
          </div>
        </div>

      </div>
    </div>
  </section>

  ${footer()}

  <script>
    // Copy to clipboard helper
    document.querySelectorAll('[data-copy]').forEach(btn => {
      btn.addEventListener('click', () => {
        navigator.clipboard.writeText(btn.dataset.copy || '');
        const orig = btn.textContent;
        btn.textContent = 'Copied!';
        setTimeout(() => { btn.textContent = orig; }, 1500);
      });
    });
  </script>`;

  return layout(
    'Generate OG images at the edge',
    body,
    socialHead(
      origin,
      'OGForge — Open Graph images, generated at the edge',
      'One GET request returns a 1200×630 PNG. No SDK, no browser, no build step. Free tier, no card.'
    )
  );
}

export function registerPage(error?: string): string {
  const body = `
  ${nav()}
  <section class="section">
    <div class="container" style="max-width:480px;">
      <p class="section-title">Get API Key</p>
      <h1 class="section-h2">Start generating</h1>
      <p class="section-sub" style="margin-bottom:32px;">Enter your email to receive your API key instantly. No password, and nothing to pay — 100 rendered images a month.</p>

      ${error ? `<div class="alert alert-error">${esc(error)}</div>` : ''}

      <div class="card">
        <form method="POST" action="/register">
          <div class="form-group">
            <label class="form-label" for="email">EMAIL ADDRESS</label>
            <input class="form-input" type="email" name="email" id="email" placeholder="you@example.com" required autocomplete="email" />
            <p class="form-hint">Your API key will be displayed immediately after registration.</p>
          </div>
          <div class="form-group">
            <label class="form-label" for="keyname">KEY NAME (optional)</label>
            <input class="form-input" type="text" name="keyname" id="keyname" placeholder="production" />
            <p class="form-hint">Give this key a label to identify it later.</p>
          </div>
          <button type="submit" class="btn btn-primary" style="width:100%;padding:14px;font-size:15px;">
            Create API Key →
          </button>
        </form>
      </div>

      <p style="font-size:13px;color:var(--text-3);margin-top:20px;text-align:center;">
        Already have a key? <a href="/dashboard">View your dashboard</a>
      </p>
    </div>
  </section>
  ${footer()}`;

  return layout('Get API Key', body);
}

export function keyCreatedPage(
  origin: string,
  rawKey: string,
  email: string,
  tier: string
): string {
  const safeEmail = esc(email);
  const body = `
  ${nav()}
  <section class="section">
    <div class="container" style="max-width:600px;">
      <div class="alert alert-success">
        ✓ API key created for ${safeEmail}
      </div>
      <p class="section-title">Your API Key</p>
      <h1 class="section-h2">Save this key now</h1>
      <p class="section-sub" style="margin-bottom:32px;">
        This is the only time you'll see the full key. Copy it and store it securely.
      </p>

      <div class="card">
        <p class="card-title">API KEY</p>
        <div class="api-key-row">
          <div class="api-key-display">
            <span class="key-val" id="api-key">${rawKey}</span>
          </div>
          <button class="btn btn-primary" data-copy="${rawKey}" style="white-space:nowrap;">Copy</button>
        </div>
        <p style="font-size:12px;color:var(--text-3);margin-top:12px;font-family:var(--font-mono);">
          ${tier === 'free' ? '100 rendered images/month' : `${esc(tier)} allowance`} · Resets on the 1st of each month
        </p>
        <p style="font-size:12px;color:var(--text-3);margin-top:6px;font-family:var(--font-mono);">
          Cache hits don't count — re-fetches of an image we already rendered are free and unlimited.
        </p>
      </div>

      <div class="code-block" style="margin-top:32px;">
        <div class="code-block-header">
          <div class="code-block-dots">
            <div class="dot dot-red"></div><div class="dot dot-yellow"></div><div class="dot dot-green"></div>
          </div>
          <span class="code-block-lang">Quick start</span>
        </div>
        <pre><span class="c-comment"># Test your key</span>
<span class="c-key">curl</span> <span class="c-str">"${origin}/og?title=Hello+World&amp;key=${rawKey}"</span> \
  <span class="c-val">--output</span> og.png && <span class="c-key">open</span> og.png</pre>
      </div>

      <div style="margin-top:32px;display:flex;gap:12px;">
        <a href="/dashboard?key=${rawKey}" class="btn btn-primary">Open Dashboard →</a>
        <a href="/#how-it-works" class="btn btn-ghost">Read the docs</a>
      </div>
    </div>
  </section>
  ${footer()}
  <script>
    document.querySelectorAll('[data-copy]').forEach(btn => {
      btn.addEventListener('click', () => {
        navigator.clipboard.writeText(btn.dataset.copy || '');
        const orig = btn.textContent;
        btn.textContent = 'Copied!';
        setTimeout(() => { btn.textContent = orig; }, 1500);
      });
    });
  </script>`;

  return layout('API Key Created', body);
}

export function dashboardPage(
  origin: string,
  key: ApiKey,
  recentCount: number
): string {
  const pct = Math.round((key.usage_count / key.monthly_limit) * 100);
  const barClass = pct >= 100 ? 'full' : pct >= 80 ? 'warn' : '';
  const resetDate = new Date(key.usage_reset_at);
  const nextReset = new Date(resetDate.getFullYear(), resetDate.getMonth() + 1, 1)
    .toLocaleDateString('en-US', { month: 'short', day: 'numeric' });

  const tierBadge = `<span class="tier-badge">${esc(key.tier)}</span>`;

  const body = `
  ${nav()}
  <div class="container">
    <div class="dash-layout">
      <div class="dash-header">
        <h1>Dashboard ${tierBadge}</h1>
        <p>API key: <code style="font-family:var(--font-mono);font-size:13px;color:var(--text-2);">${key.key_prefix}••••••••••••••••••••</code></p>
      </div>

      <div class="dash-grid">

        <!-- Usage card -->
        <div class="card">
          <p class="card-title">Renders This Month</p>
          <div class="usage-count">${key.usage_count.toLocaleString()}</div>
          <p class="usage-limit">of ${key.monthly_limit.toLocaleString()} renders · cache hits are free</p>
          <div class="usage-bar-wrap">
            <div class="usage-bar ${barClass}" style="width:${Math.min(pct, 100)}%"></div>
          </div>
          <div class="usage-meta">
            <span style="color:var(--text-3);font-size:13px;">${pct}% used</span>
            <span style="color:var(--text-3);font-size:13px;">Resets ${nextReset}</span>
          </div>
          ${
            key.tier === 'free'
              ? `<div style="margin-top:20px;padding-top:20px;border-top:1px solid var(--border);">
                   <p style="font-size:13px;color:var(--text-2);">100 renders a month not enough? Nothing is for sale — but tell us and we'll ask what you needed.</p>
                   <a href="/#interest" class="btn btn-ghost" style="margin-top:10px;">Tell us you need more →</a>
                 </div>`
              : ''
          }
        </div>

        <!-- Stats sidebar -->
        <div style="display:flex;flex-direction:column;gap:16px;">
          <div class="card">
            <p class="card-title">Recent Generations</p>
            <p style="font-size:32px;font-weight:700;font-family:var(--font-mono);">${recentCount}</p>
            <p style="font-size:13px;color:var(--text-3);margin-top:4px;">in last 24h</p>
          </div>
          <div class="card">
            <p class="card-title">Cache Hit Rate</p>
            <p style="font-size:32px;font-weight:700;font-family:var(--font-mono);color:var(--teal);">—</p>
            <p style="font-size:13px;color:var(--text-3);margin-top:4px;">not tracked yet</p>
          </div>
        </div>

        <!-- Quick start code -->
        <div class="card dash-grid-full">
          <p class="card-title">Quick Start</p>
          <div class="code-block">
            <div class="code-block-header">
              <div class="code-block-dots">
                <div class="dot dot-red"></div><div class="dot dot-yellow"></div><div class="dot dot-green"></div>
              </div>
              <span class="code-block-lang">HTML / meta tags</span>
            </div>
            <pre><span class="c-key">&lt;meta</span> <span class="c-val">property=</span><span class="c-str">"og:image"</span>
      <span class="c-val">content=</span><span class="c-str">"${origin}/og?title=YOUR_TITLE&amp;key=${key.key_prefix}..."</span> <span class="c-key">/&gt;</span></pre>
          </div>
          <div class="code-block" style="margin-top:12px;">
            <div class="code-block-header">
              <div class="code-block-dots">
                <div class="dot dot-red"></div><div class="dot dot-yellow"></div><div class="dot dot-green"></div>
              </div>
              <span class="code-block-lang">cURL test</span>
            </div>
            <pre><span class="c-key">curl</span> <span class="c-str">"${origin}/og?title=My+Blog+Post&amp;domain=myblog.com&amp;key=${key.key_prefix}..."</span> \
  <span class="c-val">--output</span> og.png && <span class="c-key">open</span> og.png</pre>
          </div>
        </div>

      </div>
    </div>
  </div>
  ${footer()}`;

  return layout('Dashboard', body);
}

export function errorPage(code: number, message: string): string {
  const body = `
  ${nav()}
  <section class="section">
    <div class="container" style="text-align:center;max-width:480px;">
      <p style="font-family:var(--font-mono);font-size:80px;font-weight:700;color:var(--border);line-height:1;">${code}</p>
      <h1 style="font-size:24px;margin:16px 0 12px;">${message}</h1>
      <p style="color:var(--text-2);margin-bottom:32px;">Something went wrong. Try again or check the docs.</p>
      <a href="/" class="btn btn-ghost">← Back to home</a>
    </div>
  </section>
  ${footer()}`;

  return layout(`${code} Error`, body);
}
