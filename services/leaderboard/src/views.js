// 读取侧：榜单、作品人气、用户卡片、书架、作品页。
//
// 可见性只有两条规则，所有查询共用：
// - 「上榜资格」eligible：未被管理员隐藏、与观看者之间无屏蔽；friends 范围再限定为本人+好友。
//   visibility='friends' 的账户**照样上榜**（数字不是隐私），只是书架/读者墙对非好友不可见。
// - 「读者墙可见」visibleReader：上榜资格 + (public 或 本人 或 好友)。作品读者**人数**计全体未隐藏账户。

import { HttpError, clampInt } from './util.js';
import { KINDS } from './shelf.js';

export const METRICS = [...KINDS, 'chars'];
export const WINDOWS = ['week', 'month', 'all'];
/** 计分规则：同一账户同一天最多计 30 部（批量补标历史作品照常入架，只是不刷分）。 */
export const DAILY_FINISH_CAP = 30;

/** 窗口起始日（UTC）。week = 本周一，month = 本月 1 日，all = null。 */
export function windowStartKey(window, now) {
  if (window === 'all') return null;
  const d = new Date(now);
  if (window === 'month') return `${d.toISOString().slice(0, 7)}-01`;
  const back = (d.getUTCDay() + 6) % 7;
  return new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() - back)).toISOString().slice(0, 10);
}

/** 顺序编号的参数构造器：p(v) 返回 '?N' 并记下 v。 */
function params() {
  const values = [];
  const p = (v) => {
    values.push(v);
    return `?${values.length}`;
  };
  return { p, values };
}

function isFriendSql(accCol, viewerParam) {
  return `EXISTS (SELECT 1 FROM friends f WHERE f.state = 'accepted'
            AND ((f.a = ${accCol} AND f.b = ${viewerParam}) OR (f.a = ${viewerParam} AND f.b = ${accCol})))`;
}

function notBlockedSql(accCol, viewerParam) {
  return `NOT EXISTS (SELECT 1 FROM blocks b
            WHERE (b.account_id = ${viewerParam} AND b.blocked_id = ${accCol})
               OR (b.account_id = ${accCol} AND b.blocked_id = ${viewerParam}))`;
}

function visibleReaderSql(alias, viewerParam) {
  return `${alias}.hidden = 0 AND ${notBlockedSql(`${alias}.id`, viewerParam)}
          AND (${alias}.visibility = 'public' OR ${alias}.id = ${viewerParam} OR ${isFriendSql(`${alias}.id`, viewerParam)})`;
}

/** 每账户指标值子查询（列 id, value）。 */
function metricSql(metric, from, p) {
  if (metric === 'chars') {
    return `SELECT account_id AS id, SUM(chars) AS value FROM daily_chars
            WHERE (${p(from)} IS NULL OR date_key >= ${p(from)}) GROUP BY account_id`;
  }
  // 日期未知的条目（finished_date NULL）各自成组，不被 30 部上限合并截断。
  return `SELECT id, SUM(c) AS value FROM (
            SELECT s.account_id AS id, MIN(COUNT(*), ${DAILY_FINISH_CAP}) AS c
            FROM shelf s JOIN works w ON w.id = s.work_id
            WHERE w.kind = ${p(metric)} AND s.finished_at IS NOT NULL
              AND (${p(from)} IS NULL OR s.finished_date >= ${p(from)})
            GROUP BY s.account_id, COALESCE(s.finished_date, s.work_id)
          ) GROUP BY id`;
}

function rankedCte(metric, window, now, viewerId, scope, p) {
  const from = windowStartKey(window, now);
  const v = p(viewerId || '');
  const scopeSql = scope === 'friends' ? `AND (a.id = ${v} OR ${isFriendSql('a.id', v)})` : '';
  return `WITH v AS (${metricSql(metric, from, p)}),
          e AS (SELECT a.id, a.nickname, a.discriminator, a.avatar_key, a.created_at, v.value
                FROM v JOIN accounts a ON a.id = v.id
                WHERE a.hidden = 0 AND v.value > 0 AND ${notBlockedSql('a.id', v)} ${scopeSql}),
          r AS (SELECT e.*, RANK() OVER (ORDER BY value DESC) AS rank FROM e)`;
}

export function publicAccount(row) {
  return {
    id: row.id,
    nickname: row.nickname,
    discriminator: row.discriminator,
    avatar: row.avatar_key ? `/img/${row.avatar_key}` : null,
  };
}

export function publicWork(row) {
  return {
    id: row.id,
    kind: row.kind,
    title: row.title,
    author: row.author,
    cover: row.cover_url || (row.cover_key ? `/img/${row.cover_key}` : null),
    nsfw: row.nsfw === 1,
  };
}

function parseChoice(v, allowed, fallback, code) {
  const x = v ?? fallback;
  if (!allowed.includes(x)) throw new HttpError(400, code);
  return x;
}

export function parsePage(url, maxLimit = 50) {
  return {
    limit: clampInt(url.searchParams.get('limit'), 1, maxLimit, 50),
    offset: clampInt(url.searchParams.get('offset'), 0, 1_000_000, 0),
  };
}

export async function leaderboard(env, url, viewer, now) {
  const metric = parseChoice(url.searchParams.get('metric'), METRICS, 'book', 'bad_metric');
  const window = parseChoice(url.searchParams.get('window'), WINDOWS, 'week', 'bad_window');
  const scope = parseChoice(url.searchParams.get('scope'), ['global', 'friends'], 'global', 'bad_scope');
  if (scope === 'friends' && !viewer) throw new HttpError(401, 'auth_required');
  const { limit, offset } = parsePage(url, 100);
  const viewerId = viewer ? viewer.id : '';

  const q1 = params();
  const rows = await env.DB.prepare(
    `${rankedCte(metric, window, now, viewerId, scope, q1.p)}
     SELECT * FROM r ORDER BY rank, created_at, id LIMIT ${q1.p(limit)} OFFSET ${q1.p(offset)}`,
  ).bind(...q1.values).all();

  const q2 = params();
  const total = await env.DB.prepare(
    `${rankedCte(metric, window, now, viewerId, scope, q2.p)} SELECT COUNT(*) AS n FROM r`,
  ).bind(...q2.values).first();

  let me = null;
  if (viewer) {
    const q3 = params();
    const mine = await env.DB.prepare(
      `${rankedCte(metric, window, now, viewerId, scope, q3.p)} SELECT * FROM r WHERE id = ${q3.p(viewerId)}`,
    ).bind(...q3.values).first();
    if (mine) me = { rank: mine.rank, value: mine.value };
  }

  return {
    metric,
    window,
    scope,
    from: windowStartKey(window, now),
    total: total.n,
    me,
    rows: rows.results.map((r) => ({ rank: r.rank, value: r.value, account: publicAccount(r) })),
  };
}

/** 单账户在全局某指标下的 {value, rank}（没数据 = {value:0, rank:null}）。 */
export async function accountStanding(env, accountId, metric, window, now) {
  const q = params();
  const row = await env.DB.prepare(
    `${rankedCte(metric, window, now, '', 'global', q.p)} SELECT value, rank FROM r WHERE id = ${q.p(accountId)}`,
  ).bind(...q.values).first();
  return row ? { value: row.value, rank: row.rank } : { value: 0, rank: null };
}

export async function popularWorks(env, url, now) {
  const window = parseChoice(url.searchParams.get('window'), WINDOWS, 'month', 'bad_window');
  const kind = url.searchParams.get('kind');
  if (kind != null && !KINDS.includes(kind)) throw new HttpError(400, 'bad_kind');
  const { limit, offset } = parsePage(url);
  const from = windowStartKey(window, now);
  const q = params();
  const rows = await env.DB.prepare(
    `SELECT w.*, COUNT(*) AS readers, RANK() OVER (ORDER BY COUNT(*) DESC) AS rank
     FROM shelf s JOIN works w ON w.id = s.work_id JOIN accounts a ON a.id = s.account_id AND a.hidden = 0
     WHERE s.finished_at IS NOT NULL
       AND (${q.p(from)} IS NULL OR s.finished_date >= ${q.p(from)})
       AND (${q.p(kind)} IS NULL OR w.kind = ${q.p(kind)})
     GROUP BY w.id ORDER BY readers DESC, MAX(s.finished_at) DESC
     LIMIT ${q.p(limit)} OFFSET ${q.p(offset)}`,
  ).bind(...q.values).all();
  return {
    window,
    kind,
    from,
    rows: rows.results.map((r) => ({ rank: r.rank, readers: r.readers, work: publicWork(r) })),
  };
}

async function loadVisibleAccount(env, id, viewerId) {
  const q = params();
  const row = await env.DB.prepare(
    `SELECT a.* FROM accounts a WHERE a.id = ${q.p(id)} AND a.hidden = 0 AND ${notBlockedSql('a.id', q.p(viewerId))}`,
  ).bind(...q.values).first();
  if (!row) throw new HttpError(404, 'not_found');
  return row;
}

async function canSeeShelf(env, account, viewerId) {
  if (account.visibility === 'public' || account.id === viewerId) return true;
  if (!viewerId) return false;
  const q = params();
  const row = await env.DB.prepare(`SELECT ${isFriendSql(q.p(account.id), q.p(viewerId))} AS ok`)
    .bind(...q.values).first();
  return row.ok === 1;
}

export async function userCard(env, id, viewer, now) {
  const viewerId = viewer ? viewer.id : '';
  const acc = await loadVisibleAccount(env, id, viewerId);
  const stats = {};
  for (const metric of METRICS) stats[metric] = await accountStanding(env, acc.id, metric, 'all', now);
  const first = await env.DB.prepare(
    `SELECT MIN(d) AS d FROM (
       SELECT MIN(finished_date) AS d FROM shelf WHERE account_id = ?1
       UNION ALL SELECT MIN(date_key) FROM daily_chars WHERE account_id = ?1)`,
  ).bind(acc.id).first();
  return {
    account: publicAccount(acc),
    createdAt: acc.created_at,
    firstRecordDate: first.d,
    visibility: acc.visibility,
    shelfVisible: await canSeeShelf(env, acc, viewerId),
    stats,
  };
}

/** 一批作品的读者人数 + 对观看者可见的前 N 位读者（好友优先，再按读完时间倒序）。 */
async function readerWalls(env, workIds, viewerId, excludeId, perWork) {
  if (workIds.length === 0) return new Map();
  const ids = JSON.stringify(workIds);
  const counts = await env.DB.prepare(
    `SELECT s.work_id, COUNT(*) AS n FROM shelf s JOIN accounts a ON a.id = s.account_id AND a.hidden = 0
     WHERE s.finished_at IS NOT NULL AND s.work_id IN (SELECT value FROM json_each(?1))
     GROUP BY s.work_id`,
  ).bind(ids).all();
  const q = params();
  const pIds = q.p(ids);
  const pv = q.p(viewerId);
  const walls = await env.DB.prepare(
    `SELECT * FROM (
       SELECT s.work_id, s.finished_at, a.id, a.nickname, a.discriminator, a.avatar_key,
              ROW_NUMBER() OVER (PARTITION BY s.work_id
                ORDER BY ${isFriendSql('a.id', pv)} DESC, s.finished_at DESC) AS rn
       FROM shelf s JOIN accounts a ON a.id = s.account_id
       WHERE s.finished_at IS NOT NULL AND s.work_id IN (SELECT value FROM json_each(${pIds}))
         AND a.id != ${q.p(excludeId)} AND ${visibleReaderSql('a', pv)}
     ) WHERE rn <= ${q.p(perWork)}`,
  ).bind(...q.values).all();
  const out = new Map(workIds.map((w) => [w, { readers: 0, wall: [] }]));
  for (const c of counts.results) out.get(c.work_id).readers = c.n;
  for (const r of walls.results) out.get(r.work_id).wall.push(publicAccount(r));
  return out;
}

export async function userShelf(env, id, url, viewer) {
  const viewerId = viewer ? viewer.id : '';
  const acc = await loadVisibleAccount(env, id, viewerId);
  if (!(await canSeeShelf(env, acc, viewerId))) throw new HttpError(403, 'shelf_private');
  const status = parseChoice(url.searchParams.get('status'), ['finished', 'reading'], 'finished', 'bad_status');
  const kind = url.searchParams.get('kind');
  if (kind != null && !KINDS.includes(kind)) throw new HttpError(400, 'bad_kind');
  const { limit, offset } = parsePage(url);
  const q = params();
  const rows = await env.DB.prepare(
    `SELECT w.*, s.finished_at, s.finished_date, s.chars AS my_chars, s.ms AS my_ms
     FROM shelf s JOIN works w ON w.id = s.work_id
     WHERE s.account_id = ${q.p(acc.id)}
       AND s.finished_at IS ${status === 'finished' ? 'NOT ' : ''}NULL
       AND (${q.p(kind)} IS NULL OR w.kind = ${q.p(kind)})
     ORDER BY s.finished_at DESC, s.updated_at DESC, w.id
     LIMIT ${q.p(limit)} OFFSET ${q.p(offset)}`,
  ).bind(...q.values).all();
  const walls = await readerWalls(env, rows.results.map((r) => r.id), viewerId, acc.id, 8);
  return {
    account: publicAccount(acc),
    status,
    rows: rows.results.map((r) => ({
      work: publicWork(r),
      finishedAt: r.finished_at || null, // 0 = 读完日期未知 → null
      finishedDate: r.finished_date,
      chars: r.my_chars,
      ms: r.my_ms,
      readers: walls.get(r.id).readers,
      wall: walls.get(r.id).wall,
    })),
  };
}

export async function workPage(env, id, url, viewer) {
  const viewerId = viewer ? viewer.id : '';
  const work = await env.DB.prepare('SELECT * FROM works WHERE id = ?1').bind(id).first();
  if (!work) throw new HttpError(404, 'not_found');
  const { limit, offset } = parsePage(url);
  const count = await env.DB.prepare(
    `SELECT COUNT(*) AS n FROM shelf s JOIN accounts a ON a.id = s.account_id AND a.hidden = 0
     WHERE s.work_id = ?1 AND s.finished_at IS NOT NULL`,
  ).bind(id).first();
  const q = params();
  const pv = q.p(viewerId);
  const readers = await env.DB.prepare(
    `SELECT a.id, a.nickname, a.discriminator, a.avatar_key, s.finished_at, s.finished_date
     FROM shelf s JOIN accounts a ON a.id = s.account_id
     WHERE s.work_id = ${q.p(id)} AND s.finished_at IS NOT NULL AND ${visibleReaderSql('a', pv)}
     ORDER BY ${isFriendSql('a.id', pv)} DESC, s.finished_at DESC, a.id
     LIMIT ${q.p(limit)} OFFSET ${q.p(offset)}`,
  ).bind(...q.values).all();
  return {
    work: publicWork(work),
    readers: count.n,
    rows: readers.results.map((r) => ({
      account: publicAccount(r),
      finishedAt: r.finished_at || null,
      finishedDate: r.finished_date,
    })),
  };
}
