/*
 * MOIS file service on Cloudflare (2026-11-11; build-plan "Cloudflare" part 3, migration 117).
 *
 * Files (payment proofs, director slips, report photos, delivery photos) live in one private
 * R2 bucket. Nobody reaches R2 directly:
 *   1. The app asks POST /api/files/sign with the person's own Supabase sign-in.
 *   2. This service asks the database, as that person, file_access(key, write) — the same
 *      company / branch / permission rules as before.
 *   3. If allowed it returns a link valid for 10 minutes, signed with FILES_SECRET; reading or
 *      uploading through /api/files/o/<key> checks that signature and nothing else.
 * Everything else (the app's own pages and files) is served as static assets and never runs here.
 *
 * env: FILES (R2 bucket), ASSETS (static app), SUPABASE_URL (var), SUPABASE_ANON_KEY and
 *      FILES_SECRET (secrets: wrangler secret put …).
 */
const MAX_BYTES = 10 * 1024 * 1024;
const TYPES = ['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif', 'application/pdf'];
const BUCKETS = ['payment-proofs', 'director-proofs', 'report-photos', 'delivery-proofs'];
const LINK_SECONDS = 600;
const ORIGINS = [
  /^https:\/\/moisv1\.netlify\.app$/,
  /^https:\/\/[a-z0-9-]+--moisv1\.netlify\.app$/,
  /^https:\/\/mois\.swahzitech\.workers\.dev$/,
  /^https:\/\/[a-z0-9-]+-mois\.swahzitech\.workers\.dev$/,
  /^http:\/\/localhost:\d+$/,
];
const UUID = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
const KEY_RE = new RegExp(`^(${BUCKETS.join('|')})/${UUID}/${UUID}/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$`);

function corsHeaders(req) {
  const o = req.headers.get('Origin');
  if (!o || !ORIGINS.some(r => r.test(o))) return {};
  return {
    'Access-Control-Allow-Origin': o,
    'Access-Control-Allow-Methods': 'GET, PUT, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Authorization, Content-Type',
    'Access-Control-Max-Age': '86400',
    Vary: 'Origin',
  };
}
const json = (req, body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', ...corsHeaders(req) } });

async function hmac(secret, msg) {
  const k = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', k, new TextEncoder().encode(msg));
  return [...new Uint8Array(sig)].map(b => b.toString(16).padStart(2, '0')).join('');
}
function sameText(a, b) {   // compare without leaking where they differ
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
const linkText = (mode, key, exp, dl) => `${mode}|${key}|${exp}|${dl}`;

// 1–3: may this person read / write this file? then a short-lived signed link
async function sign(req, env, url) {
  const auth = req.headers.get('Authorization') || '';
  if (!/^Bearer \S+$/.test(auth)) return json(req, { error: 'Sign in first.' }, 401);
  let body;
  try { body = await req.json(); } catch { return json(req, { error: 'Bad request.' }, 400); }
  const key = String(body?.key || '');
  const write = body?.write === true;
  const dl = typeof body?.download === 'string' ? body.download.replace(/[^\w .()-]/g, '_').slice(0, 120) : '';
  if (!KEY_RE.test(key) || key.includes('..')) return json(req, { error: 'Not a MOIS file.' }, 400);

  const r = await fetch(`${env.SUPABASE_URL}/rest/v1/rpc/file_access`, {
    method: 'POST',
    headers: { apikey: env.SUPABASE_ANON_KEY, Authorization: auth, 'Content-Type': 'application/json' },
    body: JSON.stringify({ p_key: key, p_write: write }),
  });
  if (r.status === 401) return json(req, { error: 'Sign in again.' }, 401);
  if (!r.ok) return json(req, { error: 'Could not check access.' }, 502);
  if ((await r.json()) !== true) return json(req, { error: 'Not allowed.' }, 403);

  if (!write && !(await env.FILES.head(key))) return json(req, { missing: true });
  if (write && (await env.FILES.head(key))) return json(req, { error: 'That file already exists.' }, 409);

  const mode = write ? 'w' : 'r';
  const exp = Math.floor(Date.now() / 1000) + LINK_SECONDS;
  const s = await hmac(env.FILES_SECRET, linkText(mode, key, exp, dl));
  const q = new URLSearchParams({ m: mode, e: String(exp), s, ...(dl ? { d: dl } : {}) });
  return json(req, { url: `${url.origin}/api/files/o/${key}?${q}` });
}

// reading or uploading with a signed link
async function object(req, env, url) {
  const key = decodeURIComponent(url.pathname.slice('/api/files/o/'.length));
  const p = url.searchParams;
  const mode = p.get('m'), exp = Number(p.get('e')), dl = p.get('d') || '';
  if (!KEY_RE.test(key) || !['r', 'w'].includes(mode) || !(exp > Date.now() / 1000)) return new Response('This link has expired.', { status: 403, headers: corsHeaders(req) });
  if (!sameText(await hmac(env.FILES_SECRET, linkText(mode, key, exp, dl)), p.get('s') || '')) return new Response('Bad link.', { status: 403, headers: corsHeaders(req) });

  if (mode === 'r' && (req.method === 'GET' || req.method === 'HEAD')) {
    const obj = await env.FILES.get(key);
    if (!obj) return new Response('Not found.', { status: 404, headers: corsHeaders(req) });
    const h = new Headers(corsHeaders(req));
    obj.writeHttpMetadata(h);
    h.set('ETag', obj.httpEtag);
    h.set('Cache-Control', 'private, max-age=600');   // never cached for others at the CDN
    // the same photo is shown (no Origin) and drawn on / shared (with Origin): cached apart, or the drawing is blocked
    h.set('Vary', 'Origin');
    if (dl) h.set('Content-Disposition', `attachment; filename="${dl}"`);
    return new Response(req.method === 'HEAD' ? null : obj.body, { headers: h });
  }
  if (mode === 'w' && req.method === 'PUT') {
    const type = (req.headers.get('Content-Type') || '').split(';')[0].trim().toLowerCase();
    if (!TYPES.includes(type)) return new Response('Only photos and PDFs.', { status: 415, headers: corsHeaders(req) });
    const data = await req.arrayBuffer();
    if (data.byteLength > MAX_BYTES) return new Response('Over 10 MB.', { status: 413, headers: corsHeaders(req) });
    if (await env.FILES.head(key)) return new Response('That file already exists.', { status: 409, headers: corsHeaders(req) });
    await env.FILES.put(key, data, { httpMetadata: { contentType: type } });
    return new Response(null, { status: 201, headers: corsHeaders(req) });
  }
  return new Response('Not allowed.', { status: 405, headers: corsHeaders(req) });
}

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    if (!url.pathname.startsWith('/api/files/')) return env.ASSETS.fetch(req);
    if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders(req) });
    try {
      if (url.pathname === '/api/files/sign' && req.method === 'POST') return await sign(req, env, url);
      if (url.pathname.startsWith('/api/files/o/')) return await object(req, env, url);
      return new Response('Not found.', { status: 404, headers: corsHeaders(req) });
    } catch (e) {
      console.error(e);
      return json(req, { error: 'Something went wrong.' }, 500);
    }
  },
};
