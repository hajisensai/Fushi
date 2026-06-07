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

// 列表页用内联 <style>，CSP 需放开 style-src（仍不放开 script-src）。
// 日志正文走 text/plain，沿用严格 securityHeaders 不受影响。
function htmlSecurityHeaders() {
  return securityHeaders({
    'Content-Type': 'text/html; charset=utf-8',
    'Content-Security-Policy':
      "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'",
  });
}

// ROUTE_PREFIX → 链接前缀段（"/ec70..."）；未配前缀为 ""。
export function linkBase(prefix) {
  if (!prefix) return '';
  return prefix.startsWith('/') ? prefix : '/' + prefix;
}

// 把白名单 id（YYYYMMDD-HHMMSS-platform-rand.txt）拆成可读字段；不匹配返回 null。
export function parseLogId(id) {
  const m = String(id).match(
    /^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})-([a-z]+)-([a-z0-9]{6})\.txt$/,
  );
  if (!m) return null;
  const [, y, mo, d, h, mi, s, platform, rand] = m;
  return {
    date: `${y}-${mo}-${d}`,
    time: `${h}:${mi}:${s}`,
    platform,
    rand,
  };
}

// 平台 → 徽章配色（背景/前景）。未知平台回落中性灰，消除「未列平台就没样式」特例。
const PLATFORM_COLORS = {
  android: ['#1b3a2a', '#7ee2a8'],
  ios: ['#1b2c45', '#8fb8ff'],
  macos: ['#33323a', '#cfcad8'],
  windows: ['#10303a', '#6fd6f0'],
  linux: ['#3a2f12', '#f0c969'],
  web: ['#2b1b40', '#c79bff'],
  unknown: ['#2a2a30', '#9aa0aa'],
};

function platformBadge(platform) {
  const key = Object.prototype.hasOwnProperty.call(PLATFORM_COLORS, platform)
    ? platform
    : 'unknown';
  const [bg, fg] = PLATFORM_COLORS[key];
  return (
    `<span class="badge" style="background:${bg};color:${fg}">` +
    `${escapeHtml(platform)}</span>`
  );
}

const LIST_STYLE = `
:root{color-scheme:dark}
*{box-sizing:border-box}
body{margin:0;background:#0e0e11;color:#e6e6ea;
  font:15px/1.5 ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
.wrap{max-width:880px;margin:0 auto;padding:32px 20px 64px}
header{display:flex;align-items:baseline;gap:12px;margin-bottom:24px;
  padding-bottom:16px;border-bottom:1px solid #26262e}
h1{margin:0;font-size:22px;font-weight:650;letter-spacing:.2px}
.count{font-size:13px;color:#9aa0aa;background:#1a1a20;
  padding:2px 10px;border-radius:999px}
table{width:100%;border-collapse:collapse;font-size:14px}
thead th{text-align:left;font-weight:550;color:#8a8f99;font-size:12px;
  text-transform:uppercase;letter-spacing:.6px;padding:0 12px 10px}
tbody tr{border-top:1px solid #1d1d24}
tbody tr:hover{background:#16161c}
td{padding:11px 12px;vertical-align:middle}
td.ts{white-space:nowrap;color:#cfd2d8;font-variant-numeric:tabular-nums}
td.ts .date{color:#80858f;font-size:12px;margin-right:8px}
.badge{display:inline-block;font-size:12px;font-weight:600;
  padding:2px 9px;border-radius:6px;letter-spacing:.3px}
a.id{color:#8fb8ff;text-decoration:none;font-family:ui-monospace,
  SFMono-Regular,Menlo,Consolas,monospace;font-size:13px}
a.id:hover{text-decoration:underline}
.empty{text-align:center;color:#80858f;padding:64px 0}
footer{margin-top:28px;color:#5c606a;font-size:12px;text-align:center}
`;

// linkBase：前缀路径段（如 "/ec70..."）；无前缀为 ""。链接须带住前缀，否则点开 404。
export function renderList(ids, linkBase = '') {
  const rows = ids
    .map((id) => {
      const meta = parseLogId(id);
      const href = `${linkBase}/log/${escapeHtml(id)}`;
      if (!meta) {
        return (
          `<tr><td class="ts">—</td><td>${platformBadge('unknown')}</td>` +
          `<td><a class="id" href="${href}">${escapeHtml(id)}</a></td></tr>`
        );
      }
      return (
        `<tr>` +
        `<td class="ts"><span class="date">${meta.date}</span>${meta.time}` +
        `<span class="date" style="margin-left:6px">UTC</span></td>` +
        `<td>${platformBadge(meta.platform)}</td>` +
        `<td><a class="id" href="${href}">${escapeHtml(meta.rand)}</a></td>` +
        `</tr>`
      );
    })
    .join('\n');
  const body =
    ids.length === 0
      ? `<div class="empty">还没有日志</div>`
      : `<table><thead><tr><th>时间</th><th>平台</th><th>日志</th></tr></thead>\n` +
        `<tbody>\n${rows}\n</tbody></table>`;
  return (
    `<!doctype html>\n<html lang="zh"><head><meta charset="utf-8">` +
    `<meta name="viewport" content="width=device-width,initial-scale=1">` +
    `<meta name="robots" content="noindex,nofollow">` +
    `<title>Hibiki 日志</title><style>${LIST_STYLE}</style></head>\n` +
    `<body><div class="wrap">` +
    `<header><h1>Hibiki 报错日志</h1><span class="count">${ids.length}</span></header>` +
    `${body}` +
    `<footer>时间为 UTC · 点条目看原文</footer>` +
    `</div></body></html>`
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
  return new Response(renderList(ids, linkBase(env.ROUTE_PREFIX)), {
    status: 200,
    headers: htmlSecurityHeaders(),
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

// 在随机密钥前缀下解析出真实路由路径；前缀不匹配返回 null（→404，连存在都不暴露）。
// 未配 ROUTE_PREFIX 时按原路径（向后兼容）。
export function routePath(pathname, prefix) {
  if (!prefix) return pathname;
  const p = prefix.startsWith('/') ? prefix : '/' + prefix;
  if (pathname === p) return '/';
  if (pathname.startsWith(p + '/')) return pathname.slice(p.length) || '/';
  return null;
}

export default {
  async fetch(request, env) {
    // fail-closed：缺关键 secret 绝不带病服务（空 secret 会让鉴权门洞开）。
    if (configMissing(env).length > 0) {
      return new Response('server misconfigured', { status: 500, headers: securityHeaders() });
    }
    const url = new URL(request.url);
    // 随机密钥前缀：猜不中前缀（含裸域名）一律 404，不暴露服务存在。
    const path = routePath(url.pathname, env.ROUTE_PREFIX);
    if (path === null) {
      return new Response('not found', { status: 404, headers: securityHeaders() });
    }
    if (path === '/api/logs') {
      if (request.method !== 'POST') {
        return new Response('method not allowed', { status: 405, headers: securityHeaders() });
      }
      return handleUpload(request, env);
    }
    if (path.startsWith('/log/')) {
      if (request.method !== 'GET') {
        return new Response('method not allowed', { status: 405, headers: securityHeaders() });
      }
      let id;
      try {
        id = decodeURIComponent(path.slice('/log/'.length));
      } catch {
        return new Response('not found', { status: 404, headers: securityHeaders() });
      }
      return handleViewLog(request, env, id);
    }
    if (path === '/') {
      if (request.method !== 'GET') {
        return new Response('method not allowed', { status: 405, headers: securityHeaders() });
      }
      return handleList(request, env);
    }
    return new Response('not found', { status: 404, headers: securityHeaders() });
  },
};
