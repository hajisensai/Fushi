// 通用小工具：base64url、sha256、JSON 响应、带上限的请求体读取、HttpError。

export class HttpError extends Error {
  constructor(status, code, detail = '') {
    super(`${status} ${code}${detail ? `: ${detail}` : ''}`);
    this.status = status;
    this.code = code;
    this.detail = detail;
  }
}

export function json(body, status = 200, headers = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8', ...headers },
  });
}

export function errorResponse(e) {
  if (e instanceof HttpError) {
    return json({ error: e.code, detail: e.detail || undefined }, e.status);
  }
  console.error('unhandled', e && e.stack ? e.stack : e);
  return json({ error: 'internal' }, 500);
}

export function b64urlEncode(bytes) {
  const u8 = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let bin = '';
  for (const b of u8) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/** 非法输入返回 null（调用方决定报什么错），不抛。 */
export function b64urlDecode(s) {
  if (typeof s !== 'string' || !/^[A-Za-z0-9_-]*$/.test(s)) return null;
  const pad = s.length % 4 === 0 ? '' : '='.repeat(4 - (s.length % 4));
  try {
    const bin = atob(s.replace(/-/g, '+').replace(/_/g, '/') + pad);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  } catch {
    return null;
  }
}

export async function sha256(bytes) {
  return new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
}

export function hex(bytes) {
  let s = '';
  for (const b of bytes) s += b.toString(16).padStart(2, '0');
  return s;
}

/** 读请求体为字节，超过 maxBytes 抛 413。先看 Content-Length，再以实际长度为准。 */
export async function readBodyBytes(request, maxBytes) {
  const declared = Number(request.headers.get('Content-Length') || '0');
  if (declared > maxBytes) throw new HttpError(413, 'body_too_large');
  const buf = new Uint8Array(await request.arrayBuffer());
  if (buf.byteLength > maxBytes) throw new HttpError(413, 'body_too_large');
  return buf;
}

export function parseJsonBytes(bytes) {
  try {
    return JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    throw new HttpError(400, 'bad_json');
  }
}

/** 'YYYY-MM-DD'（UTC）。 */
export function utcDateKey(ms) {
  return new Date(ms).toISOString().slice(0, 10);
}

/** null / undefined / '' 视为「没给」走 fallback（Number(null) === 0 会把缺省 limit 夹成下限）。 */
export function clampInt(v, lo, hi, fallback) {
  if (v === null || v === undefined || v === '') return fallback;
  const n = Number(v);
  if (!Number.isFinite(n)) return fallback;
  return Math.min(hi, Math.max(lo, Math.trunc(n)));
}

export function randomId(n = 12) {
  const bytes = new Uint8Array(n);
  crypto.getRandomValues(bytes);
  return b64urlEncode(bytes).slice(0, n);
}

/** 常数时间比较（Basic Auth 用）。 */
export function timingSafeEqual(a, b) {
  const enc = new TextEncoder();
  const ab = enc.encode(String(a ?? ''));
  const bb = enc.encode(String(b ?? ''));
  if (ab.length !== bb.length) return false;
  let diff = 0;
  for (let i = 0; i < ab.length; i++) diff |= ab[i] ^ bb[i];
  return diff === 0;
}
