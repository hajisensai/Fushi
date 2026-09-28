// 测试装置：真 SQLite（node:sqlite）上的 D1 适配层 + 内存 R2 + 签名请求构造器。
// 用真 SQLite 跑真迁移，是因为本服务的正确性几乎全在 SQL（json_each 集合写入、
// 窗口函数排名、upsert 合并）——正则假 D1 验证不了这些。

import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/worker.js';
import { signingString } from '../src/auth.js';
import { b64urlEncode } from '../src/util.js';
import { clearSnapshotMemo, refreshSnapshots } from '../src/snapshots.js';

// vite 会剥掉 'node:' 前缀，而 sqlite 只能以 'node:sqlite' 加载 → 走 require 绕开 vite 解析。
const { DatabaseSync } = createRequire(import.meta.url)('node:sqlite');

const MIGRATION =fileURLToPath(new URL('../migrations/0001_init.sql', import.meta.url));

function checkBind(v) {
  // 与 D1 一致：不接受 undefined / boolean。
  if (v === undefined) throw new Error('D1_TYPE_ERROR: undefined bind');
  if (typeof v === 'boolean') throw new Error('D1_TYPE_ERROR: boolean bind');
  return v;
}

export function makeD1() {
  const db = new DatabaseSync(':memory:');
  db.exec(readFileSync(MIGRATION, 'utf8'));
  const plain = (r) => (r ? { ...r } : null);
  function stmt(sql, args) {
    return {
      sql,
      args,
      bind: (...a) => stmt(sql, a.map(checkBind)),
      async first(col) {
        const r = plain(db.prepare(sql).get(...args));
        return r && col ? r[col] : r;
      },
      async all() {
        return { results: db.prepare(sql).all(...args).map(plain) };
      },
      async run() {
        const r = db.prepare(sql).run(...args);
        return { success: true, meta: { changes: Number(r.changes) } };
      },
    };
  }
  return {
    raw: db,
    prepare: (sql) => stmt(sql, []),
    async batch(stmts) {
      db.exec('BEGIN');
      try {
        const out = [];
        // 与 D1 一致：batch 的每条结果都带 results（RETURNING 行）与 meta.changes。
        for (const s of stmts) {
          if (/\bRETURNING\b/i.test(s.sql)) {
            const rows = db.prepare(s.sql).all(...s.args).map(plain);
            out.push({ success: true, results: rows, meta: { changes: rows.length } });
          } else {
            out.push({ ...(await s.run()), results: [] });
          }
        }
        db.exec('COMMIT');
        return out;
      } catch (e) {
        db.exec('ROLLBACK');
        throw e;
      }
    },
  };
}

export function makeR2() {
  const store = new Map();
  return {
    store,
    async put(key, bytes, opts = {}) {
      store.set(key, { bytes: new Uint8Array(bytes), httpMetadata: opts.httpMetadata || {} });
    },
    async get(key) {
      const o = store.get(key);
      if (!o) return null;
      return { body: o.bytes, httpMetadata: o.httpMetadata };
    },
    async head(key) {
      const o = store.get(key);
      return o ? { size: o.bytes.length } : null;
    },
    async delete(keys) {
      for (const k of Array.isArray(keys) ? keys : [keys]) store.delete(k);
    },
  };
}

/**
 * 测试 env。sent = 假发信器收到的邮件；autoSnapshot = 每个成功的写请求后立刻刷新榜单快照
 * （生产由定时任务每 30 分钟刷新；测快照滞后语义的用例把它关掉）。
 */
export function makeEnv(over = {}) {
  clearSnapshotMemo();
  const sent = [];
  return {
    DB: makeD1(),
    MEDIA: makeR2(),
    ADMIN_USER: 'admin',
    ADMIN_PASS: 'pw',
    EMAIL_PEPPER: 'test-pepper',
    EMAIL_SENDER: async (to, subject, text) => {
      sent.push({ to, subject, text });
    },
    sent,
    autoSnapshot: true,
    ...over,
  };
}

/** 最近一封发给 email 的验证码。 */
export function lastCode(env, email) {
  const mail = [...env.sent].reverse().find((m) => m.to === email.trim().toLowerCase());
  if (!mail) return null;
  return /\b(\d{6})\b/.exec(mail.text)[1];
}

export async function newKey() {
  const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const spki = new Uint8Array(await crypto.subtle.exportKey('spki', pair.publicKey));
  return { ...pair, spki, pubkey: b64urlEncode(spki) };
}

export const BASE = 'https://rank.example.com';

/**
 * 发一个请求到 Worker。opts：
 *   key        签名钥匙（省略 = 匿名）
 *   account    X-Fushi-Account（注册时省略）
 *   time       签名时刻（默认 now）
 *   now        服务器时刻（默认 Date.now()）
 *   body       对象（JSON）或 Uint8Array
 *   headers    额外头
 */
let lastTime = 0;
export async function call(env, method, path, opts = {}) {
  const now = opts.now ?? Date.now();
  // 真客户端的签名时刻单调递增（写请求防重放要求）；测试同一 now 下连发也照此。
  // 只在离 now 一分钟内递增——否则把「服务器时刻推到未来」的用例后面的调用全部拖成 stale_time。
  const time = opts.time ?? (lastTime = lastTime >= now && lastTime - now < 60000 ? lastTime + 1 : now);
  let bytes = new Uint8Array();
  const headers = { ...(opts.headers || {}) };
  if (opts.body instanceof Uint8Array) {
    bytes = opts.body;
  } else if (opts.body !== undefined) {
    bytes = new TextEncoder().encode(JSON.stringify(opts.body));
    headers['Content-Type'] = 'application/json';
  }
  if (opts.key) {
    const u = new URL(BASE + path);
    const msg = await signingString(method, u.pathname + u.search, time, bytes);
    const sig = new Uint8Array(
      await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, opts.key.privateKey, new TextEncoder().encode(msg)),
    );
    headers['X-Fushi-Time'] = String(time);
    headers['X-Fushi-Sig'] = opts.badSig ? b64urlEncode(new Uint8Array(64)) : b64urlEncode(sig);
    if (opts.account) headers['X-Fushi-Account'] = opts.account;
  }
  const req = new Request(BASE + path, {
    method,
    headers,
    body: method === 'GET' || method === 'HEAD' ? undefined : bytes,
  });
  const realNow = Date.now;
  Date.now = () => now;
  try {
    const res = await worker.fetch(req, env);
    if (env.autoSnapshot && method !== 'GET' && res.status < 300) await refreshSnapshots(env, now);
    const text = res.status === 204 ? '' : await res.text();
    let data = null;
    try {
      data = text ? JSON.parse(text) : null;
    } catch {
      data = text;
    }
    return { status: res.status, data, res };
  } finally {
    Date.now = realNow;
  }
}

/**
 * 走完整的邮箱验证码流程注册一个用户，返回 {key, email, id, ...account}。
 * 每次用不同的 CF-Connecting-IP 与邮箱，绕开按 IP / 邮箱的限流。
 */
let ipSeq = 0;
let mailSeq = 0;
export function nextIp() {
  ipSeq += 1;
  return `10.${(ipSeq >> 16) & 255}.${(ipSeq >> 8) & 255}.${ipSeq & 255}`;
}
export async function registerUser(env, nickname, opts = {}) {
  const key = opts.key ?? (await newKey());
  const email = opts.email ?? `user${++mailSeq}@example.com`;
  const ip = nextIp();
  const sent = await call(env, 'POST', '/v1/email/code', {
    body: { email, purpose: 'register' },
    headers: { 'CF-Connecting-IP': ip },
    now: opts.now,
  });
  if (sent.status !== 202) throw new Error(`email code failed ${sent.status} ${JSON.stringify(sent.data)}`);
  const r = await call(env, 'POST', '/v1/register', {
    key,
    body: { pubkey: key.pubkey, nickname, email, code: lastCode(env, email) },
    headers: { 'CF-Connecting-IP': ip },
    now: opts.now,
  });
  if (r.status !== 201) throw new Error(`register failed ${r.status} ${JSON.stringify(r.data)}`);
  return { key, email, ...r.data };
}

export function entry(kind, refs, title, extra = {}) {
  return { kind, refs, title, author: '', chars: 0, ms: 0, ...extra };
}

export const JPEG = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0, 0x10, 0x4a, 0x46, 0x49, 0x46]);
