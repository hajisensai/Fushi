// 账户生命周期：注册（幂等）、改资料、删除（服务端全删，含 R2 头像与成为孤儿的作品）。

import { HttpError } from './util.js';
import { verifyRegistration } from './auth.js';
import { allocateDiscriminator, checkNickname } from './nickname.js';
import { consumeCode } from './email.js';
import { casBatch, casStatements, coverKeysOf, orphanPurgeStatements, readersDeltaStatement } from './shelf.js';
import { periodContributions, workPeriodsDeltaStatements } from './periods.js';
import { deleteMedia, spend } from './budget.js';
import { publicAccount } from './views.js';

export function selfView(row) {
  return {
    ...publicAccount(row),
    visibility: row.visibility,
    createdAt: row.created_at,
    shelfCount: row.shelf_count,
    emailVerified: true,
    // 开发者账户：App 据此显示反馈处理入口（权限仍以服务端为准）。
    role: row.role === 'dev' ? 'dev' : 'user',
    // 本机是否为「上传设备」（还没有任何设备上传过时，第一台上传的就是）。
    uploadDevice: row.upload_key === null || row.upload_key === undefined || row.upload_key === row.keyId,
  };
}

/** 设备钥匙已绑定的账户（重复注册 / 登录的幂等返回）。 */
async function accountOfKey(env, keyId) {
  return env.DB.prepare(
    'SELECT a.* FROM device_keys k JOIN accounts a ON a.id = k.account_id WHERE k.key_id = ?1',
  ).bind(keyId).first();
}

/**
 * POST /v1/register {pubkey, nickname, email, code}：邮箱验证码通过才建账户。
 * 同一把钥匙重复注册 = 返回已有账户（客户端丢了注册响应后重试是安全的，此时不再要求验证码）。
 */
export async function register(env, request, body, bodyBytes, now) {
  if (!body || typeof body.pubkey !== 'string') throw new HttpError(400, 'bad_pubkey');
  const reg = await verifyRegistration(request, body.pubkey, bodyBytes, now);
  const existing = await accountOfKey(env, reg.id);
  if (existing) return { created: false, account: selfView(existing) };
  const nickname = checkNickname(body.nickname, env);
  const hash = await consumeCode(env, body.email, 'register', body.code, now);
  const taken = await env.DB.prepare('SELECT 1 AS x FROM accounts WHERE email_hash = ?1').bind(hash).first();
  if (taken) throw new HttpError(409, 'email_taken');
  await spend(env, 'register', 1, now);
  const discriminator = await allocateDiscriminator(env, nickname);
  try {
    await env.DB.batch([
      env.DB.prepare(
        `INSERT INTO accounts (id, email_hash, nickname, discriminator, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5)`,
      ).bind(reg.id, hash, nickname, discriminator, now),
      env.DB.prepare('INSERT INTO device_keys (key_id, account_id, pubkey, created_at) VALUES (?1, ?1, ?2, ?3)')
        .bind(reg.id, reg.pubkeyB64, now),
    ]);
  } catch (e) {
    // 并发：同钥匙另一请求先落库 → 按幂等返回；同邮箱并发注册 → email_taken；判别码撞车 → 重试。
    const again = await accountOfKey(env, reg.id);
    if (again) return { created: false, account: selfView(again) };
    const dup = await env.DB.prepare('SELECT 1 AS x FROM accounts WHERE email_hash = ?1').bind(hash).first();
    if (dup) throw new HttpError(409, 'email_taken');
    throw new HttpError(409, 'retry', String(e && e.message));
  }
  return { created: true, account: selfView(await accountOfKey(env, reg.id)) };
}

export const MAX_DEVICES = 10;

/** GET /v1/me/devices：本账户已登录的设备（钥匙）。 */
export async function listDevices(env, viewer) {
  const rows = await env.DB.prepare(
    'SELECT key_id, created_at, last_used_at FROM device_keys WHERE account_id = ?1 ORDER BY created_at',
  ).bind(viewer.id).all();
  return {
    devices: rows.results.map((r) => ({
      keyId: r.key_id,
      createdAt: r.created_at,
      lastUsedAt: r.last_used_at,
      current: r.key_id === viewer.keyId,
    })),
  };
}

/**
 * DELETE /v1/me/devices/:keyId：解绑本账户的另一台设备（重装 / 丢机后腾出名额）。不能解绑当前设备
 * （那是「仅本机退出」或删号）。解绑的若是上传设备，清空上传设备，下一台上传的设备自动接任。
 */
export async function removeDevice(env, account, keyId) {
  if (keyId === account.keyId) throw new HttpError(400, 'cannot_remove_current');
  const res = await env.DB.batch([
    env.DB.prepare('DELETE FROM device_keys WHERE key_id = ?1 AND account_id = ?2').bind(keyId, account.id),
    env.DB.prepare('UPDATE accounts SET upload_key = NULL WHERE id = ?1 AND upload_key = ?2').bind(account.id, keyId),
    env.DB.prepare('DELETE FROM used_sigs WHERE account_id = ?1').bind(keyId),
  ]);
  if (res[0].meta.changes !== 1) throw new HttpError(404, 'not_found');
}

/**
 * POST /v1/login {pubkey, email, code}：新设备用邮箱验证码把自己的钥匙绑到已有账户上。
 * 邮箱没有账户时根本不会发码（email.js），这里必然 400 bad_code——外人分辨不出邮箱是否已注册。
 */
export async function login(env, request, body, bodyBytes, now) {
  if (!body || typeof body.pubkey !== 'string') throw new HttpError(400, 'bad_pubkey');
  const reg = await verifyRegistration(request, body.pubkey, bodyBytes, now);
  const bound = await accountOfKey(env, reg.id);
  if (bound) return selfView(bound);
  const hash = await consumeCode(env, body.email, 'login', body.code, now);
  const acc = await env.DB.prepare('SELECT * FROM accounts WHERE email_hash = ?1').bind(hash).first();
  if (!acc) throw new HttpError(404, 'no_account');
  // 计数与插入在同一条语句里：并发登录也不会越过上限。
  const res = await env.DB.prepare(
    `INSERT OR IGNORE INTO device_keys (key_id, account_id, pubkey, created_at)
     SELECT ?1, ?2, ?3, ?4 WHERE (SELECT COUNT(*) FROM device_keys WHERE account_id = ?2) < ?5`,
  ).bind(reg.id, acc.id, reg.pubkeyB64, now, MAX_DEVICES).run();
  if (res.meta.changes !== 1) {
    const again = await accountOfKey(env, reg.id);
    if (again) return selfView(again);
    throw new HttpError(409, 'too_many_devices');
  }
  return selfView(acc);
}

export async function updateProfile(env, account, body) {
  if (!body || typeof body !== 'object') throw new HttpError(400, 'bad_json');
  let { nickname, discriminator, visibility } = account;
  if (body.nickname !== undefined) {
    const next = checkNickname(body.nickname, env);
    if (next !== nickname) {
      nickname = next;
      discriminator = await allocateDiscriminator(env, next, account.id);
    }
  }
  if (body.visibility !== undefined) {
    if (!['public', 'friends'].includes(body.visibility)) throw new HttpError(400, 'bad_visibility');
    visibility = body.visibility;
  }
  try {
    await env.DB.prepare(
      'UPDATE accounts SET nickname = ?2, discriminator = ?3, visibility = ?4 WHERE id = ?1',
    ).bind(account.id, nickname, discriminator, visibility).run();
  } catch {
    // 并发改成同一昵称时判别码撞上 UNIQUE(nickname, discriminator)：让客户端重试。
    throw new HttpError(409, 'retry');
  }
  const row = await env.DB.prepare('SELECT * FROM accounts WHERE id = ?1').bind(account.id).first();
  return selfView({ ...row, keyId: account.keyId });
}

export async function deleteAccount(env, account) {
  const id = account.id;
  // 版本与旧行在同一次 CAS 保护下：与本账户的并发上传交错时整批回滚（409，客户端重试删除）。
  const acc = await env.DB.prepare('SELECT shelf_rev, hidden FROM accounts WHERE id = ?1').bind(id).first();
  const prev = await env.DB.prepare('SELECT work_id, finished_at, finished_date, counted FROM shelf WHERE account_id = ?1')
    .bind(id).all();
  const prevJson = JSON.stringify(prev.results.map((r) => r.work_id));
  // 读完过的作品读者数 / 周期读者数减一（被隐藏的账户、counted = 0 的行本来就没计入）。
  const finished = acc.hidden ? [] : prev.results.filter((r) => r.finished_at !== null && r.counted !== 0);
  const deltas = finished.map((r) => ({ id: r.work_id, d: -1 }));
  const periodDeltas = finished.flatMap((r) => periodContributions(r.work_id, r.finished_at, r.finished_date, -1));
  const results = await casBatch(env.DB, [
    ...casStatements(env.DB, id, acc.shelf_rev),
    readersDeltaStatement(env.DB, JSON.stringify(deltas)),
    ...workPeriodsDeltaStatements(env.DB, JSON.stringify(periodDeltas)),
    env.DB.prepare('DELETE FROM account_periods WHERE account_id = ?1').bind(id),
    env.DB.prepare('DELETE FROM shelf WHERE account_id = ?1').bind(id),
    env.DB.prepare('DELETE FROM stat_days WHERE account_id = ?1').bind(id),
    env.DB.prepare('DELETE FROM account_totals WHERE account_id = ?1').bind(id),
    env.DB.prepare('DELETE FROM friends WHERE a = ?1 OR b = ?1').bind(id),
    env.DB.prepare('DELETE FROM blocks WHERE account_id = ?1 OR blocked_id = ?1').bind(id),
    // 反馈是给开发者的问题记录，不随账户删除；只断开与账户的关联（变成匿名反馈，ticket 照旧可用）。
    env.DB.prepare('UPDATE feedback SET account_id = NULL WHERE account_id = ?1').bind(id),
    env.DB.prepare('DELETE FROM dev_sessions WHERE account_id = ?1').bind(id),
    env.DB.prepare('DELETE FROM reports WHERE reporter = ?1 OR (target_kind = \'account\' AND target_id = ?1)').bind(id),
    // 精确列出本账户的限流桶（LIKE 的 '_' 是通配符，账户 id 里正好有 '_'）。
    env.DB.prepare('DELETE FROM rate_limits WHERE bucket IN (?1, ?2, ?3, ?4)')
      .bind(`shelf:${id}`, `media:${id}`, `social:${id}`, `rows:${id}`),
    env.DB.prepare(
      'DELETE FROM used_sigs WHERE account_id IN (SELECT key_id FROM device_keys WHERE account_id = ?1)',
    ).bind(id),
    env.DB.prepare('DELETE FROM device_keys WHERE account_id = ?1').bind(id),
    env.DB.prepare('DELETE FROM accounts WHERE id = ?1').bind(id),
    // 只有他一个人读过的作品随之消失；别人也在架的作品（及其封面）保留。
    ...orphanPurgeStatements(env.DB, prevJson),
  ]);
  await deleteMedia(env, [account.avatar_key, ...coverKeysOf(results[results.length - 1])]);
}
