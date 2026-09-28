// 榜单 / 作品人气快照。
//
// 为什么要快照：现场算一次榜 = 扫全体账户的计分行；D1 按读取行数计量，按请求现场算，读量随
// 「请求数 × 用户数」增长，免费额度很快见底。快照由定时任务每 30 分钟算一次（读量只随用户数），
// 请求只读一行快照（再加 isolate 内 60 秒内存缓存，热点时连这一行都不读）。
// 代价：榜单最多滞后 30 分钟——响应里带 computedAt，客户端如实显示「更新于 …」。

import { KINDS } from './shelf.js';
import { utcDateKey } from './util.js';

export const METRICS = [...KINDS, 'chars'];
export const WINDOWS = ['week', 'month', 'all'];
export const POPULAR_KINDS = ['all', ...KINDS];
export const POPULAR_TOP = 100;
const MEMO_MS = 60 * 1000;

/** 窗口起始日（UTC）。week = 本周一，month = 本月 1 日，all = null。 */
export function windowStartKey(window, now) {
  if (window === 'all') return null;
  const d = new Date(now);
  if (window === 'month') return `${d.toISOString().slice(0, 7)}-01`;
  const back = (d.getUTCDay() + 6) % 7;
  return utcDateKey(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() - back));
}

/** 标准竞赛排名（1, 1, 3）：rows 已按 value 降序。 */
export function competitionRanks(rows) {
  let prevValue = null;
  let prevRank = 0;
  return rows.map((r, i) => {
    const rank = r[1] === prevValue ? prevRank : i + 1;
    prevValue = r[1];
    prevRank = rank;
    return [r[0], r[1], rank];
  });
}

async function accountValues(env, window, now) {
  const from = windowStartKey(window, now);
  const sql = from === null
    ? `SELECT t.account_id AS id, t.book, t.manga, t.video, t.game, t.chars
       FROM account_totals t JOIN accounts a ON a.id = t.account_id AND a.hidden = 0`
    : `SELECT d.account_id AS id, SUM(d.book) AS book, SUM(d.manga) AS manga, SUM(d.video) AS video,
              SUM(d.game) AS game, SUM(d.chars) AS chars
       FROM stat_days d JOIN accounts a ON a.id = d.account_id AND a.hidden = 0
       WHERE d.date_key >= ?1 GROUP BY d.account_id`;
  const stmt = env.DB.prepare(sql);
  return { from, rows: (await (from === null ? stmt : stmt.bind(from)).all()).results };
}

async function popularRows(env, window, now) {
  const from = windowStartKey(window, now);
  if (from === null) {
    // 总榜直接沿 readers 索引取：每类各取前 POPULAR_TOP。
    const out = [];
    for (const kind of KINDS) {
      const r = await env.DB.prepare(
        `SELECT id AS work_id, kind, readers FROM works WHERE kind = ?1 AND readers > 0
         ORDER BY readers DESC, id LIMIT ?2`,
      ).bind(kind, POPULAR_TOP).all();
      out.push(...r.results);
    }
    return { from, rows: out };
  }
  const r = await env.DB.prepare(
    `SELECT s.work_id, w.kind, COUNT(*) AS readers
     FROM shelf s JOIN works w ON w.id = s.work_id JOIN accounts a ON a.id = s.account_id AND a.hidden = 0
     WHERE s.finished_date >= ?1 AND s.finished_at > 0
     GROUP BY s.work_id`,
  ).bind(from).all();
  return { from, rows: r.results };
}

/** 重算全部快照（scheduled 调用；首次部署后第一次读也会触发）。返回写入的快照行数。 */
export async function refreshSnapshots(env, now) {
  const stmts = [];
  for (const window of WINDOWS) {
    const { from, rows } = await accountValues(env, window, now);
    for (const metric of METRICS) {
      const list = rows
        .filter((r) => r[metric] > 0)
        .map((r) => [r.id, r[metric]])
        .sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1));
      stmts.push(env.DB.prepare(
        `INSERT INTO rank_snapshots (win, metric, from_key, computed_at, data) VALUES (?1, ?2, ?3, ?4, ?5)
         ON CONFLICT (win, metric) DO UPDATE SET
           from_key = excluded.from_key, computed_at = excluded.computed_at, data = excluded.data`,
      ).bind(window, metric, from, now, JSON.stringify(competitionRanks(list))));
    }
    const pop = await popularRows(env, window, now);
    for (const kind of POPULAR_KINDS) {
      const list = pop.rows
        .filter((r) => kind === 'all' || r.kind === kind)
        .map((r) => [r.work_id, r.readers])
        .sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1))
        .slice(0, POPULAR_TOP);
      stmts.push(env.DB.prepare(
        `INSERT INTO popular_snapshots (win, kind, from_key, computed_at, data) VALUES (?1, ?2, ?3, ?4, ?5)
         ON CONFLICT (win, kind) DO UPDATE SET
           from_key = excluded.from_key, computed_at = excluded.computed_at, data = excluded.data`,
      ).bind(window, kind, pop.from, now, JSON.stringify(competitionRanks(list))));
    }
  }
  await env.DB.batch(stmts);
  memo.clear();
  return stmts.length;
}

// isolate 内存缓存：key → {at, value}。Workers 的 isolate 会被复用，热点请求连快照行都不读。
const memo = new Map();

async function readSnapshot(env, table, keyCol, window, key, now) {
  const memoKey = `${table}:${window}:${key}`;
  const hit = memo.get(memoKey);
  if (hit && now - hit.at < MEMO_MS) return hit.value;
  let row = await env.DB.prepare(
    `SELECT from_key, computed_at, data FROM ${table} WHERE win = ?1 AND ${keyCol} = ?2`,
  ).bind(window, key).first();
  if (!row) {
    // 首次部署还没跑过定时任务：现场生成一次。
    await refreshSnapshots(env, now);
    row = await env.DB.prepare(
      `SELECT from_key, computed_at, data FROM ${table} WHERE win = ?1 AND ${keyCol} = ?2`,
    ).bind(window, key).first();
  }
  const list = JSON.parse(row.data);
  const value = {
    from: row.from_key,
    computedAt: row.computed_at,
    list,
    index: new Map(list.map((r, i) => [r[0], i])),
  };
  memo.set(memoKey, { at: now, value });
  return value;
}

/** 榜单快照：{from, computedAt, list: [[accountId, value, rank]], index: Map<id, 下标>}。 */
export function rankSnapshot(env, window, metric, now) {
  return readSnapshot(env, 'rank_snapshots', 'metric', window, metric, now);
}

/** 作品人气快照：{from, computedAt, list: [[workId, readers, rank]], index}。 */
export function popularSnapshot(env, window, kind, now) {
  return readSnapshot(env, 'popular_snapshots', 'kind', window, kind, now);
}

/** 测试用：清空内存缓存。 */
export function clearSnapshotMemo() {
  memo.clear();
}
