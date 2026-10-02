// 管理端 JSON API（HTTP Basic Auth，缺 ADMIN_USER/ADMIN_PASS 则 fail-closed）。
//
//   GET  /admin/api/reports                     未处理举报
//   POST /admin/api/reports/:id/resolve
//   POST /admin/api/accounts/:id  {hidden}      隐藏/恢复账户（不删数据）
//   POST /admin/api/works/:id     {title?, author?, nsfw?, clearCover?}  改标题/作者即锁定
//   POST /admin/api/works/merge   {from, into}  把 from 并入 into
//   POST /admin/api/works/split   {ref}         把一个误挂的别名拆成新作品，上报过它的书架随之迁走

import { HttpError, json, randomId, timingSafeEqual } from './util.js';
import {
  accountStatsStatements,
  casBatch,
  casStatements,
  readersDeltaStatement,
  recomputeMetaStatement,
} from './shelf.js';
import { accountPeriodsStatements, exactWorkPeriodsStatements, periodContributions, workPeriodsDeltaStatements } from './periods.js';
import { deleteMedia } from './budget.js';
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
  const both = await env.DB.prepare('SELECT id, kind, cover_key FROM works WHERE id IN (?1, ?2)').bind(from, into).all();
  if (both.results.length !== 2) throw new HttpError(404, 'not_found');
  if (both.results[0].kind !== both.results[1].kind) throw new HttpError(400, 'kind_mismatch');
  const fromRow = both.results.find((r) => r.id === from);
  // 只有两边都在架的账户计分会变（两行并成一行）；其余账户只是换了作品 id，计分不变。
  const dup = await env.DB.prepare(
    'SELECT account_id FROM shelf WHERE work_id = ?1 AND account_id IN (SELECT account_id FROM shelf WHERE work_id = ?2)',
  ).bind(from, into).all();
  await env.DB.batch([
    bumpRevStatement(env.DB, [from, into]),
    env.DB.prepare('UPDATE work_aliases SET work_id = ?2 WHERE work_id = ?1').bind(from, into),
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
    env.DB.prepare('DELETE FROM works WHERE id = ?1').bind(from),
    ...recountStatements(env.DB, [from, into], dup.results.map((r) => r.account_id)),
    env.DB.prepare('UPDATE accounts SET shelf_count = (SELECT COUNT(*) FROM shelf s WHERE s.account_id = accounts.id) WHERE id IN (SELECT value FROM json_each(?1))')
      .bind(JSON.stringify(dup.results.map((r) => r.account_id))),
  ]);
  const kept = await env.DB.prepare('SELECT cover_key FROM works WHERE id = ?1').bind(into).first();
  if (fromRow.cover_key && kept.cover_key !== fromRow.cover_key) await deleteMedia(env, fromRow.cover_key);
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
  await env.DB.batch([
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
    // 拆分只是把行换个作品 id（同 kind、同读完时刻），账户计分不变，只重算两部作品。
    ...recountStatements(env.DB, [newId, old.id], []),
  ]);
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
  // CAS：与本账户并发上传交错时整批回滚（409），管理员重试即可——否则上传用的旧 hidden 会让读者数重复计入。
  await casBatch(env.DB, [
    ...casStatements(env.DB, accountId, acc.shelf_rev),
    env.DB.prepare('UPDATE accounts SET hidden = ?2 WHERE id = ?1').bind(accountId, hidden ? 1 : 0),
    readersDeltaStatement(env.DB, JSON.stringify(finished.results.map((x) => ({ id: x.work_id, d })))),
    ...workPeriodsDeltaStatements(env.DB, JSON.stringify(
      finished.results.flatMap((x) => periodContributions(x.work_id, x.finished_at, x.finished_date, d)),
    )),
  ]);
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
    await env.DB.prepare(
      `UPDATE works SET title = ?2, author = ?3, locked = ?4, nsfw = ?5,
         cover_url = CASE WHEN ?6 THEN NULL ELSE cover_url END,
         cover_key = CASE WHEN ?6 THEN NULL ELSE cover_key END
       WHERE id = ?1`,
    ).bind(work.id, title, author, locked, nsfw, clear ? 1 : 0).run();
    if (clear && work.cover_key) await deleteMedia(env, work.cover_key);
    return json({ ok: true });
  }
  throw new HttpError(404, 'not_found');
}
