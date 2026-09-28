// 设备密钥鉴权。账户 = ECDSA P-256 公钥（SPKI DER，base64url）。
//
// 签名串（UTF-8）：`${METHOD}\n${pathWithQuery}\n${time}\n${hex(sha256(body))}`
// 签名：WebCrypto ECDSA/SHA-256，IEEE P1363 格式（r||s 各 32 字节），base64url。
// 头：X-Fushi-Account（注册时省略，公钥在 body）、X-Fushi-Time（epoch ms）、X-Fushi-Sig。
//
// 时效：|now - time| ≤ 5 分钟。有副作用的请求另要求 time 严格大于该账户已接受的
// 最大时刻（原子 UPDATE … WHERE last_seen_time < ?），挡重放；只读请求不做单调检查
// ——客户端并发拉榜单/主页时请求会乱序到达，单调检查会把合法请求当重放拒掉。

import { HttpError, b64urlDecode, b64urlEncode, hex, sha256 } from './util.js';

export const SIG_WINDOW_MS = 5 * 60 * 1000;
const P256 = { name: 'ECDSA', namedCurve: 'P-256' };
const ECDSA_SHA256 = { name: 'ECDSA', hash: 'SHA-256' };

export async function accountIdFromSpki(spkiBytes) {
  return b64urlEncode(await sha256(spkiBytes)).slice(0, 16);
}

export async function signingString(method, pathWithQuery, time, bodyBytes) {
  return `${method.toUpperCase()}\n${pathWithQuery}\n${time}\n${hex(await sha256(bodyBytes))}`;
}

export async function importPublicKey(spkiBytes) {
  try {
    return await crypto.subtle.importKey('spki', spkiBytes, P256, false, ['verify']);
  } catch {
    throw new HttpError(400, 'bad_pubkey');
  }
}

export async function verifySignature(publicKey, sigB64, message) {
  const sig = b64urlDecode(sigB64);
  if (!sig || sig.length !== 64) return false;
  return crypto.subtle.verify(ECDSA_SHA256, publicKey, sig, new TextEncoder().encode(message));
}

function pathWithQuery(request) {
  const u = new URL(request.url);
  return u.pathname + u.search;
}

function readTime(request, now) {
  const time = Number(request.headers.get('X-Fushi-Time'));
  if (!Number.isSafeInteger(time)) throw new HttpError(401, 'bad_time');
  if (Math.abs(now - time) > SIG_WINDOW_MS) throw new HttpError(401, 'stale_time');
  return time;
}

async function checkSig(request, publicKey, time, bodyBytes) {
  const msg = await signingString(request.method, pathWithQuery(request), time, bodyBytes);
  const ok = await verifySignature(publicKey, request.headers.get('X-Fushi-Sig') || '', msg);
  if (!ok) throw new HttpError(401, 'bad_signature');
}

/**
 * 校验已注册账户的签名请求，返回账户行。
 * - `optional`：没带 X-Fushi-Account 时返回 null（匿名读）；带了就必须验过。
 * - `mutating`：推进 last_seen_time，挡重放。
 */
export async function authenticate(request, env, bodyBytes, now, { optional = false, mutating = false } = {}) {
  const id = request.headers.get('X-Fushi-Account');
  if (!id) {
    if (optional) return null;
    throw new HttpError(401, 'auth_required');
  }
  const time = readTime(request, now);
  const account = await env.DB.prepare('SELECT * FROM accounts WHERE id = ?1').bind(id).first();
  if (!account) throw new HttpError(401, 'unknown_account');
  const spki = b64urlDecode(account.pubkey);
  await checkSig(request, await importPublicKey(spki), time, bodyBytes);
  if (mutating) {
    const res = await env.DB
      .prepare('UPDATE accounts SET last_seen_time = ?2 WHERE id = ?1 AND last_seen_time < ?2')
      .bind(id, time)
      .run();
    if (!res.meta || res.meta.changes !== 1) throw new HttpError(401, 'replayed');
  }
  return account;
}

/** 注册请求：公钥在 body，签名用同一把钥匙（证明持有私钥）。返回 {spki, pubkeyB64, id, time}。 */
export async function verifyRegistration(request, pubkeyB64, bodyBytes, now) {
  const spki = b64urlDecode(pubkeyB64);
  if (!spki || spki.length < 60 || spki.length > 120) throw new HttpError(400, 'bad_pubkey');
  const time = readTime(request, now);
  await checkSig(request, await importPublicKey(spki), time, bodyBytes);
  return { spki, pubkeyB64, id: await accountIdFromSpki(spki), time };
}
