// 账户生命周期：注册（幂等）、改资料、删除（服务端全删，含 R2 头像与成为孤儿的作品）。

import { HttpError } from './util.js';
import { verifyRegistration } from './auth.js';
import { allocateDiscriminator, checkNickname } from './nickname.js';
import { deleteCoverObjects, orphanPurgeStatements } from './shelf.js';
import { publicAccount } from './views.js';

export function selfView(row) {
  return { ...publicAccount(row), visibility: row.visibility, createdAt: row.created_at };
}

export async function register(env, request, body, bodyBytes, now) {
  if (!body || typeof body.pubkey !== 'string') throw new HttpError(400, 'bad_pubkey');
  const reg = await verifyRegistration(request, body.pubkey, bodyBytes, now);
  const existing = await env.DB.prepare('SELECT * FROM accounts WHERE id = ?1').bind(reg.id).first();
  // 同一把钥匙重复注册 = 返回已有账户（客户端丢了注册响应后重试是安全的）。
  if (existing) return { created: false, account: selfView(existing) };
  const nickname = checkNickname(body.nickname, env);
  const discriminator = await allocateDiscriminator(env, nickname);
  try {
    await env.DB.prepare(
      `INSERT INTO accounts (id, pubkey, nickname, discriminator, created_at)
       VALUES (?1, ?2, ?3, ?4, ?5)`,
    ).bind(reg.id, reg.pubkeyB64, nickname, discriminator, now).run();
  } catch (e) {
    // 并发：同钥匙另一请求先落库（pubkey UNIQUE）→ 按幂等返回；判别码撞车 → 让客户端重试。
    const again = await env.DB.prepare('SELECT * FROM accounts WHERE id = ?1').bind(reg.id).first();
    if (again) return { created: false, account: selfView(again) };
    throw new HttpError(409, 'retry', String(e && e.message));
  }
  const row = await env.DB.prepare('SELECT * FROM accounts WHERE id = ?1').bind(reg.id).first();
  return { created: true, account: selfView(row) };
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
  return selfView(row);
}

export async function deleteAccount(env, account) {
  const id = account.id;
  const prev = await env.DB.prepare('SELECT work_id FROM shelf WHERE account_id = ?1').bind(id).all();
  const prevJson = JSON.stringify(prev.results.map((r) => r.work_id));
  const results = await env.DB.batch([
    env.DB.prepare('DELETE FROM shelf WHERE account_id = ?1').bind(id),
    env.DB.prepare('DELETE FROM daily_chars WHERE account_id = ?1').bind(id),
    env.DB.prepare('DELETE FROM friends WHERE a = ?1 OR b = ?1').bind(id),
    env.DB.prepare('DELETE FROM blocks WHERE account_id = ?1 OR blocked_id = ?1').bind(id),
    env.DB.prepare('DELETE FROM reports WHERE reporter = ?1 OR (target_kind = \'account\' AND target_id = ?1)').bind(id),
    // 精确列出本账户的限流桶（LIKE 的 '_' 是通配符，账户 id 里正好有 '_'）。
    env.DB.prepare('DELETE FROM rate_limits WHERE bucket IN (?1, ?2, ?3)')
      .bind(`shelf:${id}`, `media:${id}`, `social:${id}`),
    env.DB.prepare('DELETE FROM used_sigs WHERE account_id = ?1').bind(id),
    env.DB.prepare('DELETE FROM accounts WHERE id = ?1').bind(id),
    // 只有他一个人读过的作品随之消失；别人也在架的作品（及其封面）保留。
    ...orphanPurgeStatements(env.DB, prevJson),
  ]);
  if (account.avatar_key) await env.MEDIA.delete(account.avatar_key);
  await deleteCoverObjects(env, results[results.length - 1]);
}
