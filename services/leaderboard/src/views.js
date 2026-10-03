// 读取侧：榜单、作品人气、用户卡片、书架、作品页。
//
// 成本：每个读接口的 D1 读取行数都有界、与总用户数无关——
//   - 榜单 / 人气 / 名次读定时快照（snapshots.js），只按页取展示字段；
//   - 读者人数读 works.readers（增量维护），不现场 COUNT；
//   - 读者墙每部作品沿 idx_shelf_work 取最近几位；列表分页 offset 有上限。
//
// 可见性只有两条规则，所有查询共用：
// - 「上榜资格」：未被管理员隐藏、与观看者之间无屏蔽；friends 范围再限定为本人+好友。
//   visibility='friends' 的账户**照样上榜**（数字不是隐私），只是书架/读者墙对非好友不可见。
// - 「读者墙可见」visibleReader：上榜资格 + (public 或 本人 或 好友)。作品读者**人数**计全体未隐藏账户。

import { HttpError, clampInt } from './util.js';
import { KINDS } from './shelf.js';
import {
  METRICS,
  WINDOWS,
  competitionRanks,
  popularSnapshot,
  rankSnapshot,
  windowPeriod,
  windowStartKey,
} from './snapshots.js';

export { METRICS, WINDOWS, windowStartKey };

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

/** 分页参数。offset 有上限：越往后越贵（D1 按读取行数计量），再往后也没有真实用途。 */
export function parsePage(url, maxLimit = 50, maxOffset = 10_000) {
  return {
    limit: clampInt(url.searchParams.get('limit'), 1, maxLimit, 50),
    offset: clampInt(url.searchParams.get('offset'), 0, maxOffset, 0),
  };
}

/** 观看者的屏蔽（双向）与好友集合；匿名观看者为空集。 */
async function viewerRelations(env, viewerId) {
  if (!viewerId) return { blocked: new Set(), friends: new Set() };
  const blocks = await env.DB.prepare(
    `SELECT blocked_id AS id FROM blocks WHERE account_id = ?1
     UNION ALL SELECT account_id AS id FROM blocks WHERE blocked_id = ?1`, // 去重交给下面的 Set（UNION 会建临时 B 树）
  ).bind(viewerId).all();
  const friends = await env.DB.prepare(
    `SELECT CASE WHEN a = ?1 THEN b ELSE a END AS id FROM friends
     WHERE state = 'accepted' AND (a = ?1 OR b = ?1)`,
  ).bind(viewerId).all();
  return {
    blocked: new Set(blocks.results.map((r) => r.id)),
    friends: new Set(friends.results.map((r) => r.id)),
  };
}

async function accountsByIds(env, ids) {
  if (ids.length === 0) return new Map();
  const rows = await env.DB.prepare(
    'SELECT * FROM accounts WHERE hidden = 0 AND id IN (SELECT value FROM json_each(?1))',
  ).bind(JSON.stringify(ids)).all();
  return new Map(rows.results.map((r) => [r.id, r]));
}

export async function leaderboard(env, url, viewer, now) {
  const metric = parseChoice(url.searchParams.get('metric'), METRICS, 'book', 'bad_metric');
  const window = parseChoice(url.searchParams.get('window'), WINDOWS, 'week', 'bad_window');
  const scope = parseChoice(url.searchParams.get('scope'), ['global', 'friends'], 'global', 'bad_scope');
  if (scope === 'friends' && !viewer) throw new HttpError(401, 'auth_required');
  const { limit, offset } = parsePage(url, 100);
  const viewerId = viewer ? viewer.id : '';
  const snap = await rankSnapshot(env, window, metric, now);
  const rel = await viewerRelations(env, viewerId);

  // 全局榜：去掉与观看者互相屏蔽的人，但保留全局名次；好友榜：限定本人+好友后重新排名。
  let list = snap.list.filter((r) => !rel.blocked.has(r[0]));
  if (scope === 'friends') {
    list = competitionRanks(list.filter((r) => r[0] === viewerId || rel.friends.has(r[0])).map((r) => [r[0], r[1]]));
  }
  const page = list.slice(offset, offset + limit);
  const accounts = await accountsByIds(env, page.map((r) => r[0]));
  const mine = viewerId ? list.find((r) => r[0] === viewerId) : undefined;
  return {
    metric,
    window,
    scope,
    from: snap.from,
    computedAt: snap.computedAt,
    total: list.length,
    me: mine ? { rank: mine[2], value: mine[1] } : await liveStanding(env, viewerId, metric, window, now),
    rows: page
      .filter((r) => accounts.has(r[0]))
      .map((r) => ({ rank: r[2], value: r[1], account: publicAccount(accounts.get(r[0])) })),
  };
}

/**
 * 观看者自己不在快照里时的实时值（快照最多滞后 30 分钟：刚同步完的人一定不在里面）。
 * 只读观看者自己的一行计分，返回 {rank: null, value}——名次要等下次刷新；没有数据 = null。
 */
async function liveStanding(env, viewerId, metric, window, now) {
  if (!viewerId) return null;
  const period = windowPeriod(window, now);
  // metric 已经过 METRICS 白名单校验，可以直接当列名。
  const row = period === null
    ? await env.DB.prepare(`SELECT ${metric} AS v FROM account_totals WHERE account_id = ?1`).bind(viewerId).first()
    : await env.DB.prepare(`SELECT ${metric} AS v FROM account_periods WHERE period = ?1 AND account_id = ?2`)
      .bind(period, viewerId).first();
  return row && row.v > 0 ? { rank: null, value: row.v } : null;
}

/** 单账户在全局某指标下的名次（快照）；没上榜 = null。 */
export async function accountRank(env, accountId, metric, window, now) {
  const snap = await rankSnapshot(env, window, metric, now);
  const i = snap.index.get(accountId);
  return i === undefined ? null : snap.list[i][2];
}

export async function popularWorks(env, url, now) {
  const window = parseChoice(url.searchParams.get('window'), WINDOWS, 'month', 'bad_window');
  const kind = url.searchParams.get('kind');
  if (kind != null && !KINDS.includes(kind)) throw new HttpError(400, 'bad_kind');
  const { limit, offset } = parsePage(url, 50, 100);
  const snap = await popularSnapshot(env, window, kind ?? 'all', now);
  const page = snap.list.slice(offset, offset + limit);
  const works = page.length === 0 ? [] : (await env.DB.prepare(
    'SELECT * FROM works WHERE id IN (SELECT value FROM json_each(?1))',
  ).bind(JSON.stringify(page.map((r) => r[0]))).all()).results;
  const byId = new Map(works.map((w) => [w.id, w]));
  return {
    window,
    kind,
    from: snap.from,
    computedAt: snap.computedAt,
    rows: page
      .filter((r) => byId.has(r[0]))
      .map((r) => ({ rank: r[2], readers: r[1], work: publicWork(byId.get(r[0])) })),
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

function canSeeShelf(account, viewerId, rel) {
  return account.visibility === 'public' || account.id === viewerId || rel.friends.has(account.id);
}

/**
 * 观看者与该账户的关系（用户页按钮状态用；匿名 = null）：
 * 'self' | 'friend' | 'outgoing'（我发出、待对方接受）| 'incoming'（对方发来、待我接受）| 'none'。
 */
async function relationTo(env, accountId, viewerId, rel) {
  if (!viewerId) return null;
  if (accountId === viewerId) return 'self';
  if (rel.friends.has(accountId)) return 'friend';
  const [a, b] = [accountId, viewerId].sort();
  const pending = await env.DB.prepare(
    "SELECT requester FROM friends WHERE a = ?1 AND b = ?2 AND state = 'pending'",
  ).bind(a, b).first();
  if (!pending) return 'none';
  return pending.requester === viewerId ? 'outgoing' : 'incoming';
}

export async function userCard(env, id, viewer, now) {
  const viewerId = viewer ? viewer.id : '';
  const acc = await loadVisibleAccount(env, id, viewerId);
  const rel = await viewerRelations(env, viewerId);
  const totals = await env.DB.prepare('SELECT * FROM account_totals WHERE account_id = ?1').bind(acc.id).first();
  const stats = {};
  for (const metric of METRICS) {
    stats[metric] = {
      value: totals ? totals[metric] : 0,
      rank: await accountRank(env, acc.id, metric, 'all', now),
    };
  }
  const first = await env.DB.prepare('SELECT MIN(date_key) AS d FROM stat_days WHERE account_id = ?1')
    .bind(acc.id).first();
  const snap = await rankSnapshot(env, 'all', 'book', now);
  return {
    account: publicAccount(acc),
    createdAt: acc.created_at,
    firstRecordDate: first.d,
    visibility: acc.visibility,
    shelfVisible: canSeeShelf(acc, viewerId, rel),
    rankComputedAt: snap.computedAt,
    relation: await relationTo(env, acc.id, viewerId, rel),
    stats,
  };
}

/** 读者墙：好友优先（主键查找），再按作品沿索引取最近的可见读者。每部作品至多 perWork 人。 */
async function readerWalls(env, workIds, viewerId, excludeId, perWork, rel) {
  const walls = new Map(workIds.map((w) => [w, []]));
  if (workIds.length === 0) return walls;
  const push = (r) => {
    const wall = walls.get(r.work_id);
    if (wall.length < perWork && !wall.some((a) => a.id === r.id)) wall.push(publicAccount(r));
  };
  const friendIds = [...rel.friends].filter((f) => f !== excludeId && !rel.blocked.has(f)).slice(0, 500);
  if (friendIds.length) {
    const fr = await env.DB.prepare(
      `SELECT s.work_id, a.id, a.nickname, a.discriminator, a.avatar_key
       FROM shelf s JOIN accounts a ON a.id = s.account_id AND a.hidden = 0
       WHERE s.account_id IN (SELECT value FROM json_each(?1))
         AND s.work_id IN (SELECT value FROM json_each(?2)) AND s.finished_at IS NOT NULL AND s.counted = 1
       ORDER BY s.finished_at DESC`,
    ).bind(JSON.stringify(friendIds), JSON.stringify(workIds)).all();
    fr.results.forEach(push);
  }
  // 一条语句：对每部作品用关联子查询沿 idx_shelf_work 取最近 perWork 位可见读者，
  // 打成 JSON 数组带回。语句数与参数个数都不随页大小变。
  // 不拼 UNION ALL：D1 的 compound SELECT 上限只有 5 段（线上实测第 6 段即 SQLITE_ERROR）；
  // 也不按作品各发一条：免费计划每次调用的 D1 查询数有上限，一页 50 部作品会越界。
  const rows = (await env.DB.prepare(
    `SELECT j.value AS work_id,
       (SELECT json_group_array(json_object('id', id, 'nickname', nickname,
                 'discriminator', discriminator, 'avatar_key', avatar_key))
        FROM (SELECT a.id, a.nickname, a.discriminator, a.avatar_key
              FROM shelf s JOIN accounts a ON a.id = s.account_id
              WHERE s.work_id = j.value AND s.finished_at IS NOT NULL AND s.counted = 1 AND a.id != ?2
                AND ${visibleReaderSql('a', '?3')}
              ORDER BY s.finished_at DESC LIMIT ?4)) AS wall
     FROM json_each(?1) j`,
  ).bind(JSON.stringify(workIds), excludeId, viewerId, perWork).all()).results;
  for (const r of rows) {
    for (const a of JSON.parse(r.wall)) push({ work_id: r.work_id, ...a });
  }
  return walls;
}

/**
 * 游标：'<finished_at>.<id>'（在读用 'n.<id>'）。排序键与索引逐列对齐（finished_at DESC, id DESC），
 * 每页只读 limit + 1 行，不论翻到第几页（offset 分页要先读掉前面所有行）。
 */
export function parseCursor(raw) {
  if (raw === null || raw === undefined || raw === '') return null;
  const m = /^(n|-?\d{1,16})\.([A-Za-z0-9_-]{1,32})$/.exec(raw);
  if (!m) throw new HttpError(400, 'bad_cursor');
  return { at: m[1] === 'n' ? null : Number(m[1]), id: m[2] };
}

function makeCursor(at, id) {
  return `${at === null || at === undefined ? 'n' : at}.${id}`;
}

function pageLimit(url) {
  return clampInt(url.searchParams.get('limit'), 1, 50, 50);
}

export async function userShelf(env, id, url, viewer) {
  const viewerId = viewer ? viewer.id : '';
  const acc = await loadVisibleAccount(env, id, viewerId);
  const rel = await viewerRelations(env, viewerId);
  if (!canSeeShelf(acc, viewerId, rel)) throw new HttpError(403, 'shelf_private');
  const status = parseChoice(url.searchParams.get('status'), ['finished', 'reading'], 'finished', 'bad_status');
  const kind = url.searchParams.get('kind');
  if (kind != null && !KINDS.includes(kind)) throw new HttpError(400, 'bad_kind');
  const limit = pageLimit(url);
  const cursor = parseCursor(url.searchParams.get('cursor'));
  const q = params();
  const where = [`s.account_id = ${q.p(acc.id)}`];
  if (kind != null) where.push(`s.kind = ${q.p(kind)}`);
  if (status === 'finished') {
    where.push('s.finished_at IS NOT NULL');
    if (cursor) where.push(`(s.finished_at, s.work_id) < (${q.p(cursor.at ?? 0)}, ${q.p(cursor.id)})`);
  } else {
    where.push('s.finished_at IS NULL');
    if (cursor) where.push(`s.work_id < ${q.p(cursor.id)}`);
  }
  const order = status === 'finished' ? 's.finished_at DESC, s.work_id DESC' : 's.work_id DESC';
  const rows = (await env.DB.prepare(
    `SELECT w.*, s.finished_at, s.finished_date, s.chars AS my_chars, s.ms AS my_ms
     FROM shelf s JOIN works w ON w.id = s.work_id
     WHERE ${where.join(' AND ')}
     ORDER BY ${order}
     LIMIT ${q.p(limit + 1)}`,
  ).bind(...q.values).all()).results;
  const more = rows.length > limit;
  const page = rows.slice(0, limit);
  const last = page[page.length - 1];
  const walls = await readerWalls(env, page.map((r) => r.id), viewerId, acc.id, 8, rel);
  return {
    account: publicAccount(acc),
    status,
    next: more ? makeCursor(status === 'finished' ? last.finished_at : null, last.id) : null,
    rows: page.map((r) => ({
      work: publicWork(r),
      finishedAt: r.finished_at || null, // 0 = 读完日期未知 → null
      finishedDate: r.finished_date,
      chars: r.my_chars,
      ms: r.my_ms,
      readers: r.readers,
      wall: walls.get(r.id),
    })),
  };
}

export async function workPage(env, id, url, viewer) {
  const viewerId = viewer ? viewer.id : '';
  const work = await env.DB.prepare('SELECT * FROM works WHERE id = ?1').bind(id).first();
  if (!work) throw new HttpError(404, 'not_found');
  const limit = pageLimit(url);
  const cursor = parseCursor(url.searchParams.get('cursor'));
  const q = params();
  const pv = q.p(viewerId);
  const after = cursor ? `AND (s.finished_at, s.account_id) < (${q.p(cursor.at ?? 0)}, ${q.p(cursor.id)})` : '';
  const rows = (await env.DB.prepare(
    `SELECT a.id, a.nickname, a.discriminator, a.avatar_key, s.finished_at, s.finished_date
     FROM shelf s JOIN accounts a ON a.id = s.account_id
     WHERE s.work_id = ${q.p(id)} AND s.finished_at IS NOT NULL AND s.counted = 1 ${after} AND ${visibleReaderSql('a', pv)}
     ORDER BY s.finished_at DESC, s.account_id DESC
     LIMIT ${q.p(limit + 1)}`,
  ).bind(...q.values).all()).results;
  const more = rows.length > limit;
  const page = rows.slice(0, limit);
  const last = page[page.length - 1];
  return {
    work: publicWork(work),
    readers: work.readers,
    next: more ? makeCursor(last.finished_at, last.id) : null,
    rows: page.map((r) => ({
      account: publicAccount(r),
      finishedAt: r.finished_at || null,
      finishedDate: r.finished_date,
    })),
  };
}
