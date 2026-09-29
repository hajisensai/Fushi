// 榜单 / 作品人气快照。
//
// 为什么要快照：现场算一次榜 = 扫全体账户的计分行；D1 按读取行数计量，按请求现场算，读量随
// 「请求数 × 用户数」增长。快照由定时任务每 30 分钟算一次，请求只读快照行（再加 isolate 内
// 60 秒内存缓存）。代价：榜单最多滞后 30 分钟——响应里带 computedAt，客户端如实显示。
//
// 刷新本身也有界：周/月榜只读 account_periods 的当期段（行数 = 当期活跃账户数），总榜读
// account_totals（每账户一行）；周/月人气读 work_periods 当期段按索引取前 N，总榜人气沿
// works.readers 索引取前 N。都不扫历史、不扫 shelf。
//
// 快照缺失（刚部署、定时任务还没跑）时返回空榜（computedAt = null），**不在请求里现场生成**——
// 否则并发的首批读会各自跑一次全量刷新（踩踏）。管理端可手动触发一次刷新。

import { KINDS } from './shelf.js';
import { utcDateKey } from './util.js';
import { monthKeyOf, weekKeyOf } from './periods.js';

export const METRICS = [...KINDS, 'chars'];
export const WINDOWS = ['week', 'month', 'all'];
export const POPULAR_KINDS = ['all', ...KINDS];
export const POPULAR_TOP = 100;
/** 每块快照的条目数（每条约 30 字节 → 约 600KB，远低于 D1 单行 2MB）。 */
export const SNAPSHOT_CHUNK = 20000;
const MEMO_MS = 60 * 1000;

/** 窗口起始日（UTC）。week = 本周一，month = 本月 1 日，all = null。 */
export function windowStartKey(window, now) {
  if (window === 'all') return null;
  const today = utcDateKey(now);
  if (window === 'month') return `${today.slice(0, 7)}-01`;
  return weekKeyOf(today).slice(2);
}

/** 当前窗口对应的周期键；all = null。 */
export function windowPeriod(window, now) {
  if (window === 'all') return null;
  const today = utcDateKey(now);
  return window === 'week' ? weekKeyOf(today) : monthKeyOf(today);
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
  const period = windowPeriod(window, now);
  const stmt = period === null
    ? env.DB.prepare(
      `SELECT t.account_id AS id, t.book, t.manga, t.video, t.game, t.chars
       FROM account_totals t JOIN accounts a ON a.id = t.account_id AND a.hidden = 0`,
    )
    : env.DB.prepare(
      `SELECT p.account_id AS id, p.book, p.manga, p.video, p.game, p.chars
       FROM account_periods p JOIN accounts a ON a.id = p.account_id AND a.hidden = 0
       WHERE p.period = ?1`,
    ).bind(period);
  return (await stmt.all()).results;
}

async function popularRows(env, window, kind, now) {
  const period = windowPeriod(window, now);
  if (period === null) {
    const sql = kind === 'all'
      ? 'SELECT id AS work_id, readers AS n FROM works WHERE readers > 0 ORDER BY readers DESC, id LIMIT ?1'
      : 'SELECT id AS work_id, readers AS n FROM works WHERE kind = ?2 AND readers > 0 ORDER BY readers DESC, id LIMIT ?1';
    const stmt = env.DB.prepare(sql);
    return (await (kind === 'all' ? stmt.bind(POPULAR_TOP) : stmt.bind(POPULAR_TOP, kind)).all()).results;
  }
  const sql = kind === 'all'
    ? 'SELECT work_id, n FROM work_periods WHERE period = ?1 ORDER BY n DESC, work_id LIMIT ?2'
    : 'SELECT work_id, n FROM work_periods WHERE period = ?1 AND kind = ?3 ORDER BY n DESC, work_id LIMIT ?2';
  const stmt = env.DB.prepare(sql);
  return (await (kind === 'all' ? stmt.bind(period, POPULAR_TOP) : stmt.bind(period, POPULAR_TOP, kind)).all()).results;
}

/** 重算全部快照（scheduled 调用；管理端也可手动触发）。返回写入的快照行数。 */
export async function refreshSnapshots(env, now) {
  const stmts = [];
  for (const window of WINDOWS) {
    const from = windowStartKey(window, now);
    const rows = await accountValues(env, window, now);
    for (const metric of METRICS) {
      const list = competitionRanks(
        rows
          .filter((r) => r[metric] > 0)
          .map((r) => [r.id, r[metric]])
          .sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1)),
      );
      const chunks = Math.max(1, Math.ceil(list.length / SNAPSHOT_CHUNK));
      for (let c = 0; c < chunks; c++) {
        stmts.push(env.DB.prepare(
          `INSERT INTO rank_snapshots (win, metric, chunk, from_key, computed_at, data) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
           ON CONFLICT (win, metric, chunk) DO UPDATE SET
             from_key = excluded.from_key, computed_at = excluded.computed_at, data = excluded.data`,
        ).bind(window, metric, c, from, now, JSON.stringify(list.slice(c * SNAPSHOT_CHUNK, (c + 1) * SNAPSHOT_CHUNK))));
      }
      stmts.push(env.DB.prepare('DELETE FROM rank_snapshots WHERE win = ?1 AND metric = ?2 AND chunk >= ?3')
        .bind(window, metric, chunks));
    }
    for (const kind of POPULAR_KINDS) {
      const list = competitionRanks((await popularRows(env, window, kind, now)).map((r) => [r.work_id, r.n]));
      stmts.push(env.DB.prepare(
        `INSERT INTO popular_snapshots (win, kind, from_key, computed_at, data) VALUES (?1, ?2, ?3, ?4, ?5)
         ON CONFLICT (win, kind) DO UPDATE SET
           from_key = excluded.from_key, computed_at = excluded.computed_at, data = excluded.data`,
      ).bind(window, kind, from, now, JSON.stringify(list)));
    }
  }
  await env.DB.batch(stmts);
  memo.clear();
  return stmts.length;
}

// isolate 内存缓存：key → {at, value}。Workers 的 isolate 会被复用，热点请求连快照行都不读。
const memo = new Map();

const EMPTY = { from: null, computedAt: null, list: [], index: new Map() };

function remember(memoKey, now, list, from, computedAt) {
  const value = { from, computedAt, list, index: new Map(list.map((r, i) => [r[0], i])) };
  memo.set(memoKey, { at: now, value });
  return value;
}

/** 榜单快照：{from, computedAt, list: [[accountId, value, rank]], index: Map<id, 下标>}；缺失 = 空榜。 */
export async function rankSnapshot(env, window, metric, now) {
  const memoKey = `rank:${window}:${metric}`;
  const hit = memo.get(memoKey);
  if (hit && now - hit.at < MEMO_MS) return hit.value;
  const rows = await env.DB.prepare(
    'SELECT from_key, computed_at, data FROM rank_snapshots WHERE win = ?1 AND metric = ?2 ORDER BY chunk',
  ).bind(window, metric).all();
  if (rows.results.length === 0) return EMPTY;
  const list = rows.results.flatMap((r) => JSON.parse(r.data));
  return remember(memoKey, now, list, rows.results[0].from_key, rows.results[0].computed_at);
}

/** 作品人气快照：{from, computedAt, list: [[workId, readers, rank]], index}；缺失 = 空榜。 */
export async function popularSnapshot(env, window, kind, now) {
  const memoKey = `popular:${window}:${kind}`;
  const hit = memo.get(memoKey);
  if (hit && now - hit.at < MEMO_MS) return hit.value;
  const row = await env.DB.prepare(
    'SELECT from_key, computed_at, data FROM popular_snapshots WHERE win = ?1 AND kind = ?2',
  ).bind(window, kind).first();
  if (!row) return EMPTY;
  return remember(memoKey, now, JSON.parse(row.data), row.from_key, row.computed_at);
}

/** 测试用：清空内存缓存。 */
export function clearSnapshotMemo() {
  memo.clear();
}
