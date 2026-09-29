// 社交：好友、屏蔽、举报（设计 §4/§5）。
//
//   GET    /v1/friends      [签名]      {friends:[{account, since}], incoming:[{account, at}], outgoing:[{account, at}]}
//   POST   /v1/friends/:id  [签名, 写]  对方已向我申请 → accepted；否则建 pending（我为 requester）
//   DELETE /v1/friends/:id  [签名, 写]  删好友 / 撤回 / 拒绝，204（不存在也 204）
//   GET    /v1/blocks       [签名]      {blocked:[account]}
//   POST   /v1/blocks/:id   [签名, 写]  屏蔽并删掉双方的好友关系与申请，204
//   DELETE /v1/blocks/:id   [签名, 写]  解除屏蔽，204
//   POST   /v1/reports      [签名, 写]  {targetKind, targetId, reason} → 201 {id}
//
// friends 存有序对 (a<b) + requester：一对人只有一行，「互相申请」自然落成同一行的
// 状态转换（upsert 一条语句完成，不存在先查后写的竞态）。被管理员隐藏的账户从所有
// 列表里消失，也不能被加好友 / 屏蔽（对外等同不存在）。
// 写接口的签名、防重放与 social:<id> 限流在 worker.js 统一做，这里只管业务。

import { HttpError, json, parseJsonBytes } from './util.js';
import { publicAccount } from './views.js';

/** 账户 id / 作品 id 的形状（与 worker.js 的路由 ID 一致）。 */
const ID_RE = /^[A-Za-z0-9_-]{1,32}$/;
export const REPORT_REASON_MAX = 500;
export const REPORT_KINDS = ['account', 'work'];

const noContent = () => new Response(null, { status: 204 });

/**
 * 有序对：friends 行主键。
 * @param {string} x
 * @param {string} y
 * @returns {[string, string]}
 */
function pair(x, y) {
  return x < y ? [x, y] : [y, x];
}

/**
 * 取一个对外可见（存在且未隐藏）的账户；不可见抛 404。自己对自己抛 400。
 * @param {any} env
 * @param {{id: string}} me
 * @param {string} targetId
 * @returns {Promise<any>}
 */
async function visibleTarget(env, me, targetId) {
  if (targetId === me.id) throw new HttpError(400, 'self_target');
  const row = await env.DB.prepare('SELECT * FROM accounts WHERE id = ?1 AND hidden = 0').bind(targetId).first();
  if (!row) throw new HttpError(404, 'not_found');
  return row;
}

/**
 * 两人之间（任一方向）是否有屏蔽。
 * @param {any} env
 * @param {string} x
 * @param {string} y
 * @returns {Promise<boolean>}
 */
async function blockedBetween(env, x, y) {
  const row = await env.DB.prepare(
    `SELECT 1 AS ok FROM blocks
     WHERE (account_id = ?1 AND blocked_id = ?2) OR (account_id = ?2 AND blocked_id = ?1)`,
  ).bind(x, y).first();
  return row !== null;
}

/**
 * GET /v1/friends：好友、收到的申请、发出的申请（对方被隐藏的行不出现）。
 * @param {any} env
 * @param {{id: string}} me
 * @returns {Promise<{friends: object[], incoming: object[], outgoing: object[]}>}
 */
export async function listFriends(env, me) {
  const rows = await env.DB.prepare(
    `SELECT f.state, f.requester, f.created_at AS at, o.*
     FROM friends f JOIN accounts o ON o.id = CASE WHEN f.a = ?1 THEN f.b ELSE f.a END
     WHERE (f.a = ?1 OR f.b = ?1) AND o.hidden = 0
     ORDER BY f.created_at DESC, o.id`,
  ).bind(me.id).all();
  const out = { friends: [], incoming: [], outgoing: [] };
  for (const r of rows.results) {
    if (r.state === 'accepted') out.friends.push({ account: publicAccount(r), since: r.at });
    else if (r.requester === me.id) out.outgoing.push({ account: publicAccount(r), at: r.at });
    else out.incoming.push({ account: publicAccount(r), at: r.at });
  }
  return out;
}

/**
 * POST /v1/friends/:id。一条 upsert 完成三种情况：新申请 / 接受对方的申请 / 重复申请（不变）。
 * 屏蔽判断在同一语句里再做一次（INSERT … SELECT … WHERE NOT EXISTS），与并发屏蔽不留缝。
 * @param {any} env
 * @param {{id: string}} me
 * @param {string} targetId
 * @param {number} now
 * @returns {Promise<{state: 'pending' | 'accepted'}>}
 */
export async function addFriend(env, me, targetId, now) {
  await visibleTarget(env, me, targetId);
  if (await blockedBetween(env, me.id, targetId)) throw new HttpError(403, 'blocked');
  const [a, b] = pair(me.id, targetId);
  const accepting = `friends.state = 'pending' AND friends.requester != excluded.requester`;
  const row = await env.DB.prepare(
    `INSERT INTO friends (a, b, requester, state, created_at)
     SELECT ?1, ?2, ?3, 'pending', ?4
     WHERE NOT EXISTS (SELECT 1 FROM blocks
       WHERE (account_id = ?1 AND blocked_id = ?2) OR (account_id = ?2 AND blocked_id = ?1))
     ON CONFLICT (a, b) DO UPDATE SET
       state = CASE WHEN ${accepting} THEN 'accepted' ELSE friends.state END,
       created_at = CASE WHEN ${accepting} THEN excluded.created_at ELSE friends.created_at END
     RETURNING state`,
  ).bind(a, b, me.id, now).first();
  if (!row) throw new HttpError(403, 'blocked');
  return { state: row.state };
}

/**
 * DELETE /v1/friends/:id：删好友、撤回自己的申请、拒绝对方的申请都是删掉这一行。
 * @param {any} env
 * @param {{id: string}} me
 * @param {string} targetId
 * @returns {Promise<void>}
 */
export async function removeFriend(env, me, targetId) {
  const [a, b] = pair(me.id, targetId);
  await env.DB.prepare('DELETE FROM friends WHERE a = ?1 AND b = ?2').bind(a, b).run();
}

/**
 * GET /v1/blocks：我屏蔽的人（被隐藏的账户不出现）。
 * @param {any} env
 * @param {{id: string}} me
 * @returns {Promise<{blocked: object[]}>}
 */
export async function listBlocks(env, me) {
  const rows = await env.DB.prepare(
    `SELECT o.* FROM blocks k JOIN accounts o ON o.id = k.blocked_id
     WHERE k.account_id = ?1 AND o.hidden = 0 ORDER BY k.created_at DESC, o.id`,
  ).bind(me.id).all();
  return { blocked: rows.results.map(publicAccount) };
}

/**
 * POST /v1/blocks/:id：屏蔽 + 删掉这对人的好友行（含任一方向的申请），一个事务。
 * @param {any} env
 * @param {{id: string}} me
 * @param {string} targetId
 * @param {number} now
 * @returns {Promise<void>}
 */
export async function blockAccount(env, me, targetId, now) {
  await visibleTarget(env, me, targetId);
  const [a, b] = pair(me.id, targetId);
  await env.DB.batch([
    env.DB.prepare('INSERT OR IGNORE INTO blocks (account_id, blocked_id, created_at) VALUES (?1, ?2, ?3)')
      .bind(me.id, targetId, now),
    env.DB.prepare('DELETE FROM friends WHERE a = ?1 AND b = ?2').bind(a, b),
  ]);
}

/**
 * DELETE /v1/blocks/:id。
 * @param {any} env
 * @param {{id: string}} me
 * @param {string} targetId
 * @returns {Promise<void>}
 */
export async function unblockAccount(env, me, targetId) {
  await env.DB.prepare('DELETE FROM blocks WHERE account_id = ?1 AND blocked_id = ?2').bind(me.id, targetId).run();
}

/**
 * 校验举报 body，返回规范化后的 {targetKind, targetId, reason}。
 * @param {any} body
 * @returns {{targetKind: string, targetId: string, reason: string}}
 */
export function normalizeReport(body) {
  if (!body || typeof body !== 'object') throw new HttpError(400, 'bad_json');
  const { targetKind, targetId } = body;
  if (!REPORT_KINDS.includes(targetKind)) throw new HttpError(400, 'bad_target_kind');
  if (typeof targetId !== 'string' || !ID_RE.test(targetId)) throw new HttpError(400, 'bad_target');
  const raw = body.reason ?? '';
  if (typeof raw !== 'string') throw new HttpError(400, 'bad_reason');
  const reason = raw.normalize('NFC').replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, ' ').trim();
  if ([...reason].length > REPORT_REASON_MAX) throw new HttpError(400, 'bad_reason');
  return { targetKind, targetId, reason };
}

/**
 * POST /v1/reports：目标须存在；同一举报人对同一目标的未处理举报去重（只刷新理由），返回那条的 id。
 * @param {any} env
 * @param {{id: string}} me
 * @param {any} body
 * @param {number} now
 * @returns {Promise<{id: number}>}
 */
export async function fileReport(env, me, body, now) {
  const { targetKind, targetId, reason } = normalizeReport(body);
  if (targetKind === 'account' && targetId === me.id) throw new HttpError(400, 'self_target');
  const table = targetKind === 'account' ? 'accounts' : 'works';
  const exists = await env.DB.prepare(`SELECT 1 AS ok FROM ${table} WHERE id = ?1`).bind(targetId).first();
  if (!exists) throw new HttpError(404, 'not_found');
  const row = await env.DB.prepare(
    `INSERT INTO reports (reporter, target_kind, target_id, reason, created_at) VALUES (?1, ?2, ?3, ?4, ?5)
     ON CONFLICT (reporter, target_kind, target_id) WHERE resolved = 0 DO UPDATE SET reason = excluded.reason
     RETURNING id`,
  ).bind(me.id, targetKind, targetId, reason, now).first();
  return { id: row.id };
}

const TARGET = '([A-Za-z0-9_-]{1,32})';
/**
 * 写路由表：[方法, 路径正则, 处理函数(env, me, 路径参数, 已解析 body 字节, now) → Response]。
 * @type {Array<[string, RegExp, (env: any, me: any, id: string, bytes: Uint8Array, now: number) => Promise<Response>]>}
 */
const WRITES = [
  ['POST', new RegExp(`^/v1/friends/${TARGET}$`), async (env, me, id, _b, now) => json(await addFriend(env, me, id, now))],
  ['DELETE', new RegExp(`^/v1/friends/${TARGET}$`), async (env, me, id) => (await removeFriend(env, me, id), noContent())],
  ['POST', new RegExp(`^/v1/blocks/${TARGET}$`), async (env, me, id, _b, now) => (await blockAccount(env, me, id, now), noContent())],
  ['DELETE', new RegExp(`^/v1/blocks/${TARGET}$`), async (env, me, id) => (await unblockAccount(env, me, id), noContent())],
  ['POST', /^\/v1\/reports$/, async (env, me, _id, bytes, now) => json(await fileReport(env, me, parseJsonBytes(bytes), now), 201)],
];

/**
 * 匹配社交写路由；不是社交写请求返回 null。返回的函数在鉴权与限流之后调用。
 * @param {string} method
 * @param {string} path
 * @returns {((env: any, me: any, bytes: Uint8Array, now: number) => Promise<Response>) | null}
 */
export function matchSocialWrite(method, path) {
  for (const [m, re, handler] of WRITES) {
    const hit = m === method ? re.exec(path) : null;
    if (hit) return (env, me, bytes, now) => handler(env, me, hit[1], bytes, now);
  }
  return null;
}
