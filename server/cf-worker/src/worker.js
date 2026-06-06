// Hibiki 报错日志接收 Worker（零服务器）。
// 安全：日志只当字符串存 D1、原样 text/plain 吐回，绝不执行/解释。
// 上传验 X-Upload-Token；查看 HTTP Basic Auth；缺 secret 则 fail-closed。

const ID_PATTERN = /^\d{8}-\d{6}-[a-z]+-[a-z0-9]{6}\.txt$/;
const RAND_ALPHABET = 'abcdefghijklmnopqrstuvwxyz0123456789';
export const MAX_BODY_BYTES = 512 * 1024;

export function sanitizePlatform(p) {
  let s = String(p ?? '').toLowerCase().replace(/[^a-z]/g, '');
  if (!s) s = 'unknown';
  if (s.length > 16) s = s.slice(0, 16);
  return s;
}

export function validLogID(id) {
  return ID_PATTERN.test(id);
}

export function randCode(n, fill) {
  const buf = new Uint8Array(n);
  (fill ?? ((b) => crypto.getRandomValues(b)))(buf);
  let out = '';
  for (const b of buf) out += RAND_ALPHABET[b % RAND_ALPHABET.length];
  return out;
}

// now: Date；生成 UTC 的 YYYYMMDD-HHMMSS-<platform>-<rand>.txt
export function genLogId(now, platform, rand) {
  const p = (x) => String(x).padStart(2, '0');
  const ts =
    `${now.getUTCFullYear()}${p(now.getUTCMonth() + 1)}${p(now.getUTCDate())}` +
    `-${p(now.getUTCHours())}${p(now.getUTCMinutes())}${p(now.getUTCSeconds())}`;
  return `${ts}-${sanitizePlatform(platform)}-${rand}.txt`;
}

export function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]),
  );
}

export function buildLogContent(payload) {
  const clean = (v) => String(v ?? '').replace(/[\r\n]/g, ' ');
  return (
    `# kind: ${clean(payload.kind)}\n` +
    `# app_version: ${clean(payload.app_version)}\n` +
    `# platform: ${clean(payload.platform)}\n` +
    `# device: ${clean(payload.device)}\n` +
    `# ts: ${clean(payload.ts)}\n\n` +
    String(payload.log ?? '')
  );
}

// 常数时间比较（长度不等直接 false；等长则 XOR 累积）。
export function timingSafeEqual(a, b) {
  const enc = new TextEncoder();
  const ab = enc.encode(String(a ?? ''));
  const bb = enc.encode(String(b ?? ''));
  if (ab.length !== bb.length) return false;
  let diff = 0;
  for (let i = 0; i < ab.length; i++) diff |= ab[i] ^ bb[i];
  return diff === 0;
}

export function checkBasicAuth(header, user, pass) {
  if (!header || !header.startsWith('Basic ')) return false;
  let decoded;
  try {
    decoded = atob(header.slice(6));
  } catch {
    return false;
  }
  const idx = decoded.indexOf(':');
  if (idx < 0) return false;
  const u = decoded.slice(0, idx);
  const pw = decoded.slice(idx + 1);
  // 两个都比，避免短路泄露
  const okU = timingSafeEqual(u, user);
  const okP = timingSafeEqual(pw, pass);
  return okU && okP;
}

// 缺任一关键 secret 或 D1 binding → 返回缺失项（用于 fail-closed）。
// 含 DB binding：漏配时返回受控 500，而非到存储层才抛裸 TypeError。
export function configMissing(env) {
  const missing = [];
  for (const k of ['UPLOAD_TOKEN', 'BASIC_USER', 'BASIC_PASS', 'DB']) {
    if (!env || !env[k]) missing.push(k);
  }
  return missing;
}

function securityHeaders(extra = {}) {
  return {
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY',
    'Content-Security-Policy': "default-src 'none'; frame-ancestors 'none'",
    'Cache-Control': 'no-store',
    ...extra,
  };
}

export function renderList(ids) {
  const items = ids
    .map((id) => `<li><a href="/log/${escapeHtml(id)}">${escapeHtml(id)}</a></li>`)
    .join('\n');
  return (
    `<!doctype html>\n<html><head><meta charset="utf-8"><title>hibiki logs</title></head>\n` +
    `<body><h1>hibiki logs (${ids.length})</h1><ul>\n${items}\n</ul></body></html>`
  );
}

function unauthorized() {
  return new Response('unauthorized', {
    status: 401,
    headers: securityHeaders({
      'WWW-Authenticate': 'Basic realm="hibiki-logs", charset="UTF-8"',
    }),
  });
}

// 存储层：收口 D1 SQL，便于测试用假 DB 注入。
export const storage = {
  async put(env, id, content) {
    await env.DB.prepare(
      'INSERT OR REPLACE INTO logs (id, content, created) VALUES (?1, ?2, ?3)',
    )
      .bind(id, content, new Date().toISOString())
      .run();
  },
  async get(env, id) {
    const row = await env.DB.prepare('SELECT content FROM logs WHERE id = ?1')
      .bind(id)
      .first();
    return row ? row.content : null;
  },
  async listIds(env) {
    const { results } = await env.DB.prepare(
      'SELECT id FROM logs ORDER BY id DESC',
    ).all();
    return (results || []).map((r) => r.id);
  },
  async prune(env, retain) {
    if (!retain || retain <= 0) return;
    await env.DB.prepare(
      'DELETE FROM logs WHERE id NOT IN (SELECT id FROM logs ORDER BY id DESC LIMIT ?1)',
    )
      .bind(retain)
      .run();
  },
};

function retainFrom(env) {
  const n = Number(env.RETAIN);
  return Number.isFinite(n) && n > 0 ? n : 2000;
}

async function handleUpload(request, env) {
  if (!timingSafeEqual(request.headers.get('X-Upload-Token'), env.UPLOAD_TOKEN)) {
    return new Response('unauthorized', { status: 401, headers: securityHeaders() });
  }
  const cl = Number(request.headers.get('Content-Length') || '0');
  if (cl > MAX_BODY_BYTES) {
    return new Response('too large', { status: 413, headers: securityHeaders() });
  }
  const raw = await request.text();
  if (new TextEncoder().encode(raw).length > MAX_BODY_BYTES) {
    return new Response('too large', { status: 413, headers: securityHeaders() });
  }
  let payload;
  try {
    payload = JSON.parse(raw);
  } catch {
    return new Response('bad request', { status: 400, headers: securityHeaders() });
  }
  const id = genLogId(new Date(), payload.platform, randCode(6));
  await storage.put(env, id, buildLogContent(payload));
  await storage.prune(env, retainFrom(env));
  return new Response(JSON.stringify({ id }), {
    status: 200,
    headers: securityHeaders({ 'Content-Type': 'application/json; charset=utf-8' }),
  });
}

async function handleList(request, env) {
  if (!checkBasicAuth(request.headers.get('Authorization'), env.BASIC_USER, env.BASIC_PASS)) {
    return unauthorized();
  }
  const ids = (await storage.listIds(env)).filter(validLogID);
  // listIds 已按 id DESC 排序（最新在前）；仍过白名单防脏数据
  return new Response(renderList(ids), {
    status: 200,
    headers: securityHeaders({ 'Content-Type': 'text/html; charset=utf-8' }),
  });
}

async function handleViewLog(request, env, id) {
  if (!checkBasicAuth(request.headers.get('Authorization'), env.BASIC_USER, env.BASIC_PASS)) {
    return unauthorized();
  }
  if (!validLogID(id)) {
    return new Response('not found', { status: 404, headers: securityHeaders() });
  }
  const data = await storage.get(env, id);
  if (data === null || data === undefined) {
    return new Response('not found', { status: 404, headers: securityHeaders() });
  }
  // 日志正文一律 text/plain 原样吐 → 浏览器当纯文本，脚本不执行。
  return new Response(data, {
    status: 200,
    headers: securityHeaders({ 'Content-Type': 'text/plain; charset=utf-8' }),
  });
}

export default {
  async fetch(request, env) {
    // fail-closed：缺关键 secret 绝不带病服务（空 secret 会让鉴权门洞开）。
    if (configMissing(env).length > 0) {
      return new Response('server misconfigured', { status: 500, headers: securityHeaders() });
    }
    const url = new URL(request.url);
    if (url.pathname === '/api/logs') {
      if (request.method !== 'POST') {
        return new Response('method not allowed', { status: 405, headers: securityHeaders() });
      }
      return handleUpload(request, env);
    }
    if (url.pathname.startsWith('/log/')) {
      if (request.method !== 'GET') {
        return new Response('method not allowed', { status: 405, headers: securityHeaders() });
      }
      let id;
      try {
        id = decodeURIComponent(url.pathname.slice('/log/'.length));
      } catch {
        return new Response('not found', { status: 404, headers: securityHeaders() });
      }
      return handleViewLog(request, env, id);
    }
    if (url.pathname === '/') {
      if (request.method !== 'GET') {
        return new Response('method not allowed', { status: 405, headers: securityHeaders() });
      }
      return handleList(request, env);
    }
    return new Response('not found', { status: 404, headers: securityHeaders() });
  },
};
