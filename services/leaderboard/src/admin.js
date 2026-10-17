// 管理端 JSON API（HTTP Basic Auth，缺 ADMIN_USER/ADMIN_PASS 则 fail-closed）。
//
//   GET  /admin/api/reports                     未处理举报
//   GET  /admin/api/email-conflicts             邮箱别名归一时没能升级的账户对（只有账户 id）
//   POST /admin/api/reports/:id/resolve
//   POST /admin/api/accounts/:id  {hidden}      隐藏/恢复账户（不删数据）
//   POST /admin/api/works/:id     {title?, author?, nsfw?, clearCover?}  改标题/作者即锁定
//   GET  /admin/api/works/:id/covers            封面候选与状态（票数 / 确认票 / 不符 / 待生效）
//   POST /admin/api/works/merge   {from, into}  把 from 并入 into
//   POST /admin/api/accounts/:id/role {role: 'dev'|'user'}  设 / 撤开发者（反馈处理台）
//   POST /admin/api/works/split   {ref}         把一个误挂的别名拆成新作品，上报过它的书架随之迁走

import { HttpError, json, randomId, timingSafeEqual } from './util.js';
import {
  accountStatsStatements,
  casBatch,
  casStatements,
  coverKeysOf,
  readersDeltaStatement,
  recomputeMetaStatement,
} from './shelf.js';
import { accountPeriodsStatements, exactWorkPeriodsStatements, periodContributions, workPeriodsDeltaStatements } from './periods.js';
import { deleteMedia } from './budget.js';
import { recountStatement, settleStatements, workCoverCandidates } from './cover_votes.js';
import { refreshSnapshots } from './snapshots.js';

/**
 * 管理操作改了作品归属后的精确重算语句（放进同一个事务）：作品读者数与周期读者数现场 COUNT，
 * 给出的账户（只有「两边都在架」的账户计分会变）计分与周期全量重算。
 * 读量 = 这些作品的读者数 + 这些账户的计分行；管理操作频率极低，用精确重算换正确性。
 */
function recountStatements(db, workIds, accountIds) {
  const ids = JSON.stringify(workIds);
  const stmts = [
    db.prepare(
      `UPDATE works SET readers = (
         SELECT COUNT(*) FROM shelf s JOIN accounts a ON a.id = s.account_id AND a.hidden = 0
         WHERE s.work_id = works.id AND s.finished_at IS NOT NULL AND s.counted = 1)
       WHERE id IN (SELECT value FROM json_each(?1))`,
    ).bind(ids),
    ...exactWorkPeriodsStatements(db, ids),
  ];
  for (const acc of accountIds) {
    stmts.push(...accountStatsStatements(db, acc, null), ...accountPeriodsStatements(db, acc, null));
  }
  return stmts;
}

/** 精确重算这些作品的封面票数，再物化 + 清理（清理 RETURNING cover_key）。 */
function coverResettleStatements(db, workIds, now) {
  const ids = JSON.stringify(workIds);
  return [recountStatement(db, ids, now), ...settleStatements(db, ids, now)];
}

/** 这些作品的全部在架账户书架版本 +1：与之交错的上传 CAS 失败、重读后重试。 */
function bumpRevStatement(db, workIds) {
  return db.prepare(
    `UPDATE accounts SET shelf_rev = shelf_rev + 1
     WHERE id IN (SELECT account_id FROM shelf WHERE work_id IN (SELECT value FROM json_each(?1)))`,
  ).bind(JSON.stringify(workIds));
}

export function checkBasicAuth(request, env) {
  if (!env.ADMIN_USER || !env.ADMIN_PASS) throw new HttpError(503, 'admin_not_configured');
  const h = request.headers.get('Authorization') || '';
  const m = /^Basic\s+(.+)$/i.exec(h);
  let user = '';
  let pass = '';
  if (m) {
    try {
      const decoded = atob(m[1]);
      const i = decoded.indexOf(':');
      user = decoded.slice(0, i);
      pass = decoded.slice(i + 1);
    } catch {
      /* 落到下面的 401 */
    }
  }
  // 两个比较都做完再判，避免按用户名短路泄露时序。
  const ok = timingSafeEqual(user, env.ADMIN_USER) & timingSafeEqual(pass, env.ADMIN_PASS);
  if (!ok) throw new HttpError(401, 'admin_auth');
}

async function recomputeMeta(env, workId) {
  await recomputeMetaStatement(env.DB, JSON.stringify([workId])).run();
}

export async function mergeWorks(env, from, into, now) {
  if (!from || !into || from === into) throw new HttpError(400, 'bad_merge');
  const both = await env.DB.prepare('SELECT id, kind FROM works WHERE id IN (?1, ?2)').bind(from, into).all();
  if (both.results.length !== 2) throw new HttpError(404, 'not_found');
  if (both.results[0].kind !== both.results[1].kind) throw new HttpError(400, 'kind_mismatch');
  // 只有两边都在架的账户计分会变（两行并成一行）；其余账户只是换了作品 id，计分不变。
  const dup = await env.DB.prepare(
    'SELECT account_id FROM shelf WHERE work_id = ?1 AND account_id IN (SELECT account_id FROM shelf WHERE work_id = ?2)',
  ).bind(from, into).all();
  const results = await env.DB.batch([
    bumpRevStatement(env.DB, [from, into]),
    env.DB.prepare('UPDATE work_aliases SET work_id = ?2 WHERE work_id = ?1').bind(from, into),
    // 封面票：两边都投过的账户保留目标作品上的那票；同一 URL 的候选并成一个（票转到目标那边）；
    // 其余候选与票整体迁到目标作品，随后精确重算、重新物化。
    env.DB.prepare(
      'DELETE FROM cover_votes WHERE work_id = ?1 AND account_id IN (SELECT account_id FROM cover_votes WHERE work_id = ?2)',
    ).bind(from, into),
    env.DB.prepare(
      `UPDATE cover_votes SET candidate_id = (
         SELECT c2.id FROM cover_candidates c1 JOIN cover_candidates c2 ON c2.work_id = ?2 AND c2.cover_url = c1.cover_url
         WHERE c1.id = cover_votes.candidate_id)
       WHERE work_id = ?1 AND candidate_id IN (
         SELECT c1.id FROM cover_candidates c1 JOIN cover_candidates c2 ON c2.work_id = ?2 AND c2.cover_url = c1.cover_url
         WHERE c1.work_id = ?1)`,
    ).bind(from, into),
    env.DB.prepare(
      `DELETE FROM cover_candidates WHERE work_id = ?1 AND cover_url IN (
         SELECT cover_url FROM cover_candidates WHERE work_id = ?2 AND cover_url IS NOT NULL)`,
    ).bind(from, into),
    env.DB.prepare('UPDATE cover_votes SET work_id = ?2 WHERE work_id = ?1').bind(from, into),
    env.DB.prepare('UPDATE OR IGNORE cover_mismatches SET work_id = ?2 WHERE work_id = ?1').bind(from, into),
    env.DB.prepare('UPDATE cover_candidates SET work_id = ?2 WHERE work_id = ?1').bind(from, into),
    // 同一账户两边都有：与上报合并规则一致——读完时刻取较晚者，字数/时长累加。
    env.DB.prepare(
      `INSERT INTO shelf (account_id, work_id, kind, refs, title, author, finished_at, finished_date, chars, ms, counted, updated_at)
       SELECT account_id, ?2, kind, refs, title, author, finished_at, finished_date, chars, ms, counted, updated_at
       FROM shelf WHERE work_id = ?1
       ON CONFLICT (account_id, work_id) DO UPDATE SET
         counted = MAX(shelf.counted, excluded.counted),
         finished_date = CASE WHEN COALESCE(excluded.finished_at, -1) > COALESCE(shelf.finished_at, -1)
                              THEN excluded.finished_date ELSE shelf.finished_date END,
         finished_at = CASE WHEN COALESCE(excluded.finished_at, -1) > COALESCE(shelf.finished_at, -1)
                            THEN excluded.finished_at ELSE shelf.finished_at END,
         chars = shelf.chars + excluded.chars,
         ms = shelf.ms + excluded.ms`,
    ).bind(from, into),
    env.DB.prepare('DELETE FROM shelf WHERE work_id = ?1').bind(from),
    env.DB.prepare(
      `UPDATE works SET
         cover_url = COALESCE(cover_url, (SELECT cover_url FROM works WHERE id = ?1)),
         cover_key = CASE WHEN cover_url IS NULL AND cover_key IS NULL
                          THEN (SELECT cover_key FROM works WHERE id = ?1) ELSE cover_key END,
         nsfw = MAX(nsfw, (SELECT nsfw FROM works WHERE id = ?1))
       WHERE id = ?2`,
    ).bind(from, into),
    // 清封面保护期随合并带到目标作品（取两边较晚的清除时刻），免得把被清过的作品并进去就绕开保护期。
    env.DB.prepare(
      `UPDATE works SET cover_cleared_at = NULLIF(MAX(COALESCE(cover_cleared_at, 0),
         COALESCE((SELECT cover_cleared_at FROM works WHERE id = ?1), 0)), 0)
       WHERE id = ?2`,
    ).bind(from, into),
    env.DB.prepare('DELETE FROM works WHERE id = ?1').bind(from),
    ...coverResettleStatements(env.DB, [into], now),
    ...recountStatements(env.DB, [from, into], dup.results.map((r) => r.account_id)),
    env.DB.prepare('UPDATE accounts SET shelf_count = (SELECT COUNT(*) FROM shelf s WHERE s.account_id = accounts.id) WHERE id IN (SELECT value FROM json_each(?1))')
      .bind(JSON.stringify(dup.results.map((r) => r.account_id))),
  ]);
  // 来源作品的封面都已是候选（迁移 0012 回填）、随候选迁到目标作品；落选且无票的由清理语句交回。
  await deleteMedia(env, coverKeysOf(results));
  await recomputeMeta(env, into);
  await refreshSnapshots(env, now);
}

/**
 * 拆分：别名 ref 挂错了作品。新建作品接走这个别名；上报 refs 里**第一个已知别名**就是它的
 * 书架行（即当初按它解析进来的）随之迁走。其余书架行不动。
 */
export async function splitWork(env, ref, now) {
  const alias = await env.DB.prepare('SELECT work_id FROM work_aliases WHERE ref = ?1').bind(ref).first();
  if (!alias) throw new HttpError(404, 'not_found');
  const old = await env.DB.prepare('SELECT * FROM works WHERE id = ?1').bind(alias.work_id).first();
  if (!old) throw new HttpError(404, 'not_found');
  const newId = randomId(12);
  const splitResults = await env.DB.batch([
    env.DB.prepare(
      'INSERT INTO works (id, kind, title, author, nsfw, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)',
    ).bind(newId, old.kind, old.title, old.author, old.nsfw, now),
    bumpRevStatement(env.DB, [old.id]),
    env.DB.prepare('UPDATE work_aliases SET work_id = ?2 WHERE ref = ?1').bind(ref, newId),
    env.DB.prepare(
      `UPDATE shelf SET work_id = ?3
       WHERE work_id = ?2 AND (
         SELECT r.value FROM json_each(shelf.refs) r
         WHERE r.value = ?1 OR EXISTS (SELECT 1 FROM work_aliases a WHERE a.ref = r.value AND a.work_id = ?2)
         ORDER BY r.key LIMIT 1) = ?1`,
    ).bind(ref, old.id, newId),
    // 迁走的账户在原作品上的封面票随之作废（它们的客户端会对新作品重新投票）。
    env.DB.prepare(
      `DELETE FROM cover_votes WHERE work_id = ?1
         AND NOT EXISTS (SELECT 1 FROM shelf s WHERE s.work_id = ?1 AND s.account_id = cover_votes.account_id)`,
    ).bind(old.id),
    ...coverResettleStatements(env.DB, [old.id], now),
    // 拆分只是把行换个作品 id（同 kind、同读完时刻），账户计分不变，只重算两部作品。
    ...recountStatements(env.DB, [newId, old.id], []),
  ]);
  await deleteMedia(env, coverKeysOf(splitResults));
  await recomputeMeta(env, newId);
  await recomputeMeta(env, old.id);
  await refreshSnapshots(env, now);
  return newId;
}

/**
 * 隐藏 / 恢复账户：状态真的变了才调整它读完作品的读者数（±1），然后立刻刷新快照，
 * 让它马上从 / 回到各榜单（不等 30 分钟的定时任务）。
 */
export async function setAccountHidden(env, accountId, hidden, now) {
  const acc = await env.DB.prepare('SELECT hidden, shelf_rev FROM accounts WHERE id = ?1').bind(accountId).first();
  if (!acc) throw new HttpError(404, 'not_found');
  if ((acc.hidden === 1) === hidden) return;
  const finished = await env.DB.prepare(
    'SELECT work_id, finished_at, finished_date FROM shelf WHERE account_id = ?1 AND finished_at IS NOT NULL AND counted = 1',
  ).bind(accountId).all();
  const d = hidden ? -1 : 1;
  // 隐藏账户的封面票照记、不计数：它投过的作品精确重算并重新物化。
  const voted = await env.DB.prepare('SELECT work_id FROM cover_votes WHERE account_id = ?1').bind(accountId).all();
  const votedWorks = voted.results.map((x) => x.work_id);
  // CAS：与本账户并发上传交错时整批回滚（409），管理员重试即可——否则上传用的旧 hidden 会让读者数重复计入。
  const results = await casBatch(env.DB, [
    ...casStatements(env.DB, accountId, acc.shelf_rev),
    env.DB.prepare('UPDATE accounts SET hidden = ?2 WHERE id = ?1').bind(accountId, hidden ? 1 : 0),
    ...(votedWorks.length ? coverResettleStatements(env.DB, votedWorks, now) : []),
    readersDeltaStatement(env.DB, JSON.stringify(finished.results.map((x) => ({ id: x.work_id, d })))),
    ...workPeriodsDeltaStatements(env.DB, JSON.stringify(
      finished.results.flatMap((x) => periodContributions(x.work_id, x.finished_at, x.finished_date, d)),
    )),
  ]);
  await deleteMedia(env, coverKeysOf(results));
  await refreshSnapshots(env, now);
}

export async function handleAdmin(env, request, path, body, now) {
  checkBasicAuth(request, env);
  const m = (re) => re.exec(path);
  let r;
  if (request.method === 'GET' && path === '/admin/api/reports') {
    const rows = await env.DB.prepare('SELECT * FROM reports WHERE resolved = 0 ORDER BY id DESC LIMIT 200').all();
    return json({ rows: rows.results });
  }
  if (request.method === 'GET' && path === '/admin/api/email-conflicts') {
    // 同一个收件箱在旧规则下注册出的多个账户（见 migrations/0015）。不返回邮箱或哈希。
    const count = await env.DB.prepare('SELECT COUNT(*) AS n FROM email_hash_conflicts').first('n');
    const rows = await env.DB.prepare(
      `SELECT account_id AS accountId, holder_id AS holderId, first_seen_at AS firstSeenAt,
              last_seen_at AS lastSeenAt, seen_count AS seenCount
       FROM email_hash_conflicts ORDER BY last_seen_at DESC LIMIT 200`,
    ).all();
    return json({ count, rows: rows.results });
  }
  if (request.method === 'GET' && (r = m(/^\/admin\/api\/works\/([A-Za-z0-9_-]+)\/covers$/))) {
    const res = await workCoverCandidates(env.DB, r[1], now);
    if (!res) throw new HttpError(404, 'not_found');
    return json(res);
  }
  if (request.method !== 'POST') throw new HttpError(405, 'method');
  if ((r = m(/^\/admin\/api\/reports\/(\d+)\/resolve$/))) {
    await env.DB.prepare('UPDATE reports SET resolved = 1 WHERE id = ?1').bind(Number(r[1])).run();
    return json({ ok: true });
  }
  if (path === '/admin/api/snapshots/refresh') {
    return json({ ok: true, rows: await refreshSnapshots(env, now) });
  }
  if (path === '/admin/api/works/merge') {
    await mergeWorks(env, body.from, body.into, now);
    return json({ ok: true });
  }
  if (path === '/admin/api/works/split') {
    return json({ ok: true, workId: await splitWork(env, String(body.ref || ''), now) });
  }
  if ((r = m(/^\/admin\/api\/accounts\/([A-Za-z0-9_-]+)\/devices\/clear$/))) {
    // 用户设备名额满、自己又没有任何一台还登录着时的人工出口：清空后用邮箱验证码重新登录。
    const res = await env.DB.batch([
      env.DB.prepare('DELETE FROM device_keys WHERE account_id = ?1').bind(r[1]),
      env.DB.prepare('UPDATE accounts SET upload_key = NULL WHERE id = ?1').bind(r[1]),
    ]);
    return json({ ok: true, removed: res[0].meta.changes });
  }
  if ((r = m(/^\/admin\/api\/accounts\/([A-Za-z0-9_-]+)\/role$/))) {
    if (body.role !== 'dev' && body.role !== 'user') throw new HttpError(400, 'bad_role');
    const res = await env.DB.batch([
      env.DB.prepare('UPDATE accounts SET role = ?2 WHERE id = ?1').bind(r[1], body.role),
      // 撤销开发者时顺带作废其网页会话（会话查询本身也会核对 role，这里只是不留垃圾）。
      env.DB.prepare('DELETE FROM dev_sessions WHERE account_id = ?1 AND ?2 = \'user\'').bind(r[1], body.role),
    ]);
    if (res[0].meta.changes !== 1) throw new HttpError(404, 'not_found');
    return json({ ok: true });
  }
  if ((r = m(/^\/admin\/api\/accounts\/([A-Za-z0-9_-]+)$/))) {
    await setAccountHidden(env, r[1], body.hidden === true, now);
    return json({ ok: true });
  }
  if ((r = m(/^\/admin\/api\/works\/([A-Za-z0-9_-]+)$/))) {
    const work = await env.DB.prepare('SELECT * FROM works WHERE id = ?1').bind(r[1]).first();
    if (!work) throw new HttpError(404, 'not_found');
    const title = typeof body.title === 'string' && body.title.trim() ? body.title.trim() : work.title;
    const author = typeof body.author === 'string' ? body.author.trim() : work.author;
    const locked = title !== work.title || author !== work.author ? 1 : work.locked;
    const nsfw = typeof body.nsfw === 'boolean' ? (body.nsfw ? 1 : 0) : work.nsfw;
    const clear = body.clearCover === true;
    const stmts = [];
    if (clear) {
      // 清掉的是「当前封面」这一个候选及投给它的票；其余候选按票数顶上（都没票则作品无封面）。
      // 投过这张图的客户端不会自动重投同一张（本机记着已投过），要换封面得本地先换。
      // 记下清除时刻：COVER_CLEAR_GUARD_MS 内首张封面也要过替换门槛（cover_votes.js 文件头），
      // 否则攻击者在清掉的瞬间再投一次就又抢回首张；所以顶上的也只能是已过门槛的候选。
      const current = `SELECT id FROM cover_candidates WHERE work_id = ?1
                       AND (cover_key = ?2 OR cover_url = ?3)`;
      stmts.push(
        env.DB.prepare(`DELETE FROM cover_votes WHERE candidate_id IN (${current})`)
          .bind(work.id, work.cover_key, work.cover_url),
        env.DB.prepare(`DELETE FROM cover_candidates WHERE id IN (${current})`)
          .bind(work.id, work.cover_key, work.cover_url),
      );
    }
    stmts.push(env.DB.prepare(
      `UPDATE works SET title = ?2, author = ?3, locked = ?4, nsfw = ?5,
         cover_url = CASE WHEN ?6 THEN NULL ELSE cover_url END,
         cover_key = CASE WHEN ?6 THEN NULL ELSE cover_key END,
         cover_cleared_at = CASE WHEN ?6 THEN ?7 ELSE cover_cleared_at END
       WHERE id = ?1`,
    ).bind(work.id, title, author, locked, nsfw, clear ? 1 : 0, now));
    if (clear) stmts.push(...coverResettleStatements(env.DB, [work.id], now));
    const results = await env.DB.batch(stmts);
    if (clear) await deleteMedia(env, [work.cover_key, ...coverKeysOf(results)]);
    return json({ ok: true });
  }
  throw new HttpError(404, 'not_found');
}
