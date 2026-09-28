// 设备密钥鉴权。账户 = ECDSA P-256 公钥（SPKI DER，base64url）。
//
// 签名串（UTF-8）：`${METHOD}\n${pathWithQuery}\n${time}\n${hex(sha256(body))}`
// 签名：WebCrypto ECDSA/SHA-256，IEEE P1363 格式（r||s 各 32 字节），base64url。
// 头：X-Fushi-Account（注册时省略，公钥在 body）、X-Fushi-Time（epoch ms）、X-Fushi-Sig。
//
// 时效：|now - time| ≤ 5 分钟。有副作用的请求另要求「同一签名串只用一次」（used_sigs），
// 挡重放；只读请求不去重。去重键是**签名串的哈希**而不是签名值：ECDSA 签名可延展
// （(r, s) 与 (r, n−s) 同样有效），按签名值去重可被翻转 s 绕过。

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

/** 验签，返回签名串（去重键的来源）。 */
async function checkSig(request, publicKey, time, bodyBytes) {
  const msg = await signingString(request.method, pathWithQuery(request), time, bodyBytes);
  const ok = await verifySignature(publicKey, request.headers.get('X-Fushi-Sig') || '', msg);
  if (!ok) throw new HttpError(401, 'bad_signature');
  return msg;
}

/**
 * 校验已注册账户的签名请求，返回账户行。
 * X-Fushi-Account 是**设备钥匙 id**（一个账户可绑多台设备，见 device_keys）；首台设备的钥匙 id
 * 恰好等于账户 id，其它设备不等——账户 id 以返回的账户行为准。
 * - `optional`：没带 X-Fushi-Account 时返回 null（匿名读）；带了就必须验过。
 * - `mutating`：登记签名串，同一签名串第二次到达即 401 replayed。
 */
export async function authenticate(request, env, bodyBytes, now, { optional = false, mutating = false } = {}) {
  const id = request.headers.get('X-Fushi-Account');
  if (!id) {
    if (optional) return null;
    throw new HttpError(401, 'auth_required');
  }
  const time = readTime(request, now);
  const key = await env.DB.prepare('SELECT account_id, pubkey FROM device_keys WHERE key_id = ?1').bind(id).first();
  if (!key) throw new HttpError(401, 'unknown_account');
  const account = await env.DB.prepare('SELECT * FROM accounts WHERE id = ?1').bind(key.account_id).first();
  if (!account) throw new HttpError(401, 'unknown_account');
  const spki = b64urlDecode(key.pubkey);
  const msg = await checkSig(request, await importPublicKey(spki), time, bodyBytes);
  if (mutating) {
    const dedup = hex(await sha256(new TextEncoder().encode(msg)));
    const res = await env.DB
      .prepare('INSERT OR IGNORE INTO used_sigs (account_id, sig, time) VALUES (?1, ?2, ?3)')
      .bind(id, dedup, time)
      .run();
    if (!res.meta || res.meta.changes !== 1) throw new HttpError(401, 'replayed');
  }
  // 发起请求的设备钥匙（上传设备判定、/v1/me 的 uploadDevice 用）。
  return { ...account, keyId: id };
}

/** 注册 / 登录请求：公钥在 body，签名用同一把钥匙（证明持有私钥）。返回 {spki, pubkeyB64, id(=key_id), time}。 */
export async function verifyRegistration(request, pubkeyB64, bodyBytes, now) {
  const spki = b64urlDecode(pubkeyB64);
  if (!spki || spki.length < 60 || spki.length > 120) throw new HttpError(400, 'bad_pubkey');
  const time = readTime(request, now);
  await checkSig(request, await importPublicKey(spki), time, bodyBytes);
  return { spki, pubkeyB64, id: await accountIdFromSpki(spki), time };
}
