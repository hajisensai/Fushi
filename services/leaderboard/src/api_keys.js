// 处理台个人密钥的通用存取（拍板台密钥 decision_api_keys / 反馈密钥 feedback_api_keys 共用）。
//
// 每种密钥一张表、一个前缀、一条角色判据：表结构相同（迁移 0024 / 0026），库里只存 token 的 SHA-256，
// 明文只在签发时出现一次；账户角色不再满足判据时密钥随之失效（鉴权时现查 role）。
// 两种密钥互不通用：拍板台密钥碰不到反馈，反馈密钥碰不到拍板台。

import { HttpError, b64urlEncode, hex, randomId, sha256 } from './util.js';

/**
 * @typedef {object} KeyKind
 * @property {string} table        表名（decision_api_keys / feedback_api_keys）
 * @property {string} prefix       明文前缀（fdk_ / ffk_）
 * @property {RegExp} re           明文格式
 * @property {(role: string) => boolean} roleOk  鉴权时账户角色须满足的判据
 * @property {string} missingCode  缺 / 格式不对时的 401 错误码
 * @property {string} badCode      不存在 / 已吊销 / 角色不符时的 401 错误码
 */

export const API_KEY_LIMITS = Object.freeze({ activePerAccount: 5, labelMax: 60, touchEveryMs: 10 * 60 * 1000 });

/**
 * @param {string} token
 * @returns {Promise<string>}
 */
export async function apiKeyHash(token) {
  return hex(await sha256(new TextEncoder().encode(token)));
}

/**
 * 本账户这一种的全部密钥（含已吊销），新的在前。不含哈希。
 * @param {object} env
 * @param {KeyKind} kind
 * @param {string} accountId
 * @returns {Promise<Array<{id: string, hint: string, label: string|null, created_at: number, last_used_at: number|null, revoked_at: number|null}>>}
 */
export async function listApiKeys(env, kind, accountId) {
  const r = await env.DB.prepare(`SELECT id, hint, label, created_at, last_used_at, revoked_at FROM ${kind.table}
    WHERE account_id = ?1 ORDER BY created_at DESC, id`).bind(accountId).all();
  return r.results || [];
}

/**
 * 签发一把新密钥；明文只在返回值里出现这一次。每个账户每种最多 activePerAccount 把未吊销的。
 * @param {object} env
 * @param {KeyKind} kind
 * @param {{id: string}} account
 * @param {string|null} name  已清洗的备注（null = 无）
 * @param {number} now
 * @returns {Promise<{id: string, token: string}>}
 */
export async function createApiKey(env, kind, account, name, now) {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  const token = kind.prefix + b64urlEncode(bytes);
  const id = randomId(10);
  // 名额检查与插入在同一条语句里：并发签发也不会超过上限。
  const r = await env.DB.prepare(`INSERT INTO ${kind.table} (id, account_id, token_hash, hint, label, created_at)
    SELECT ?1, ?2, ?3, ?4, ?5, ?6
    WHERE (SELECT COUNT(*) FROM ${kind.table} WHERE account_id = ?2 AND revoked_at IS NULL) < ?7`)
    .bind(id, account.id, await apiKeyHash(token), token.slice(-4), name, now, API_KEY_LIMITS.activePerAccount).run();
  if (!r.meta || r.meta.changes !== 1) throw new HttpError(409, 'too_many_keys');
  return { id, token };
}

/**
 * 吊销本人的一把密钥（别人的或不存在的 → 404；已吊销的幂等）。
 * @param {object} env
 * @param {KeyKind} kind
 * @param {{id: string}} account
 * @param {string} keyId
 * @param {number} now
 * @returns {Promise<void>}
 */
export async function revokeApiKey(env, kind, account, keyId, now) {
  const row = await env.DB.prepare(`SELECT revoked_at FROM ${kind.table} WHERE id = ?1 AND account_id = ?2`)
    .bind(keyId, account.id).first();
  if (!row) throw new HttpError(404, 'not_found');
  if (row.revoked_at) return;
  await env.DB.prepare(`UPDATE ${kind.table} SET revoked_at = ?3 WHERE id = ?1 AND account_id = ?2 AND revoked_at IS NULL`)
    .bind(keyId, account.id, now).run();
}

/**
 * Bearer 密钥 → 账户。缺 / 格式不对 → 401 missingCode；不存在、已吊销、角色不符 → 401 badCode（不区分，免得探测）。
 * last_used_at 最多每 touchEveryMs 写一次。
 * @param {object} env
 * @param {KeyKind} kind
 * @param {Request} request
 * @param {number} now
 * @returns {Promise<{id: string, nickname: string, role: string, key_id: string}>}
 */
export async function apiKeyAccount(env, kind, request, now) {
  const m = /^Bearer\s+(\S+)$/.exec(request.headers.get('Authorization') || '');
  if (!m || !kind.re.test(m[1])) throw new HttpError(401, kind.missingCode);
  const row = await env.DB.prepare(`SELECT k.id AS key_id, k.last_used_at AS key_used_at, a.id, a.nickname, a.role
    FROM ${kind.table} k JOIN accounts a ON a.id = k.account_id
    WHERE k.token_hash = ?1 AND k.revoked_at IS NULL`).bind(await apiKeyHash(m[1])).first();
  if (!row || !kind.roleOk(row.role)) throw new HttpError(401, kind.badCode);
  if (!row.key_used_at || now - row.key_used_at >= API_KEY_LIMITS.touchEveryMs) {
    await env.DB.prepare(`UPDATE ${kind.table} SET last_used_at = ?2 WHERE id = ?1`).bind(row.key_id, now).run();
  }
  return { id: row.id, nickname: row.nickname, role: row.role, key_id: row.key_id };
}
