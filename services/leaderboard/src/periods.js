// 周期（周 / 月）汇总：周/月榜与周/月人气榜的读取面。
//
// 周期键：周 'w:<该周周一 YYYY-MM-DD>'、月 'm:<YYYY-MM>'。日期一律是客户端本地日（finished_date /
// stat_days.date_key）；当前窗口的键由服务器 UTC 今天推出（snapshots.windowStartKey），两者同一算法。
//
// 为什么要它：周/月榜若从 stat_days / shelf 按日期段现场聚合，读量 = 全体账户在窗口内的全部行，
// 每 30 分钟一次就会越过 D1 免费额度。改成增量维护的汇总后，快照只读「当期」这一段：
//   account_periods：每账户每周期计分，由 stat_days 按受影响周期重算（读量 ≤ 该账户 31 行 / 周期）；
//   work_periods：每作品每周期读完人数，随读者增减 ±1（有日期的读完、未隐藏账户）。

import { utcDateKey } from './util.js';

const DAY_MS = 24 * 3600 * 1000;

/** 'YYYY-MM-DD' → 该周周一。 */
export function weekStartOf(dateKey) {
  const t = Date.parse(`${dateKey}T00:00:00Z`);
  const back = (new Date(t).getUTCDay() + 6) % 7;
  return utcDateKey(t - back * DAY_MS);
}

export function weekKeyOf(dateKey) {
  return `w:${weekStartOf(dateKey)}`;
}

export function monthKeyOf(dateKey) {
  return `m:${dateKey.slice(0, 7)}`;
}

export function periodsOf(dateKey) {
  return [weekKeyOf(dateKey), monthKeyOf(dateKey)];
}

/** 周期的闭区间 [from, to]（日期键）。 */
export function periodRange(period) {
  if (period.startsWith('w:')) {
    const from = period.slice(2);
    return { from, to: utcDateKey(Date.parse(`${from}T00:00:00Z`) + 6 * DAY_MS) };
  }
  const month = period.slice(2);
  const [y, m] = month.split('-').map(Number);
  const last = new Date(Date.UTC(y, m, 0)).getUTCDate();
  return { from: `${month}-01`, to: `${month}-${String(last).padStart(2, '0')}` };
}

/**
 * 重算一个账户若干周期的 account_periods（periods = null：该账户全部周期，reset 时用）。
 * 读量：该账户落在这些周期里的 stat_days 行。
 */
export function accountPeriodsStatements(db, accountId, periods) {
  if (periods === null) {
    const wk = "'w:' || date(date_key, '-6 days', 'weekday 1')";
    const mo = "'m:' || substr(date_key, 1, 7)";
    const sum = 'SUM(book), SUM(manga), SUM(video), SUM(game), SUM(chars)';
    return [
      db.prepare('DELETE FROM account_periods WHERE account_id = ?1').bind(accountId),
      db.prepare(
        `INSERT INTO account_periods (period, account_id, book, manga, video, game, chars)
         SELECT ${wk}, ?1, ${sum} FROM stat_days WHERE account_id = ?1 GROUP BY 1
         UNION ALL
         SELECT ${mo}, ?1, ${sum} FROM stat_days WHERE account_id = ?1 GROUP BY 1`,
      ).bind(accountId),
    ];
  }
  const spec = JSON.stringify(periods.map((p) => ({ p, ...periodRange(p) })));
  return [
    db.prepare(
      'DELETE FROM account_periods WHERE account_id = ?1 AND period IN (SELECT json_extract(value, \'$.p\') FROM json_each(?2))',
    ).bind(accountId, spec),
    db.prepare(
      `INSERT INTO account_periods (period, account_id, book, manga, video, game, chars)
       SELECT json_extract(p.value, '$.p'), ?1, SUM(d.book), SUM(d.manga), SUM(d.video), SUM(d.game), SUM(d.chars)
       FROM json_each(?2) p
       JOIN stat_days d ON d.account_id = ?1
        AND d.date_key BETWEEN json_extract(p.value, '$.from') AND json_extract(p.value, '$.to')
       GROUP BY 1`,
    ).bind(accountId, spec),
  ];
}

/**
 * work_periods 增量：deltas = [{id: workId, p: period, d: ±n}]。先 upsert 累加，再删掉降到 0 的行。
 */
export function workPeriodsDeltaStatements(db, deltasJson) {
  return [
    db.prepare(
      `INSERT INTO work_periods (period, work_id, kind, n)
       SELECT j.p, j.id, w.kind, j.d
       FROM (SELECT json_extract(value, '$.p') AS p, json_extract(value, '$.id') AS id,
                    SUM(json_extract(value, '$.d')) AS d
             FROM json_each(?1) GROUP BY 1, 2) AS j
       JOIN works w ON w.id = j.id
       WHERE j.d != 0
       ON CONFLICT (period, work_id) DO UPDATE SET n = work_periods.n + excluded.n`,
    ).bind(deltasJson),
    db.prepare(
      `DELETE FROM work_periods WHERE n <= 0 AND (period, work_id) IN (
         SELECT json_extract(value, '$.p'), json_extract(value, '$.id') FROM json_each(?1))`,
    ).bind(deltasJson),
  ];
}

/** 读完行对周期读者数的贡献：有日期的读完才进周/月（日期未知的只进总榜）。 */
export function periodContributions(workId, finishedAt, finishedDate, sign) {
  if (finishedAt === null || finishedAt === undefined || !(finishedAt > 0) || !finishedDate) return [];
  return periodsOf(finishedDate).map((p) => ({ id: workId, p, d: sign }));
}

/**
 * 管理操作后的精确重算：这些作品的 work_periods 全部按 shelf 现场重建（读量 = 这些作品的读者数，
 * 只在低频的管理操作里用）。
 */
export function exactWorkPeriodsStatements(db, workIdsJson) {
  const base = `FROM shelf s JOIN accounts a ON a.id = s.account_id AND a.hidden = 0 JOIN works w ON w.id = s.work_id
                WHERE s.work_id IN (SELECT value FROM json_each(?1)) AND s.finished_at > 0 AND s.counted = 1`;
  return [
    db.prepare('DELETE FROM work_periods WHERE work_id IN (SELECT value FROM json_each(?1))').bind(workIdsJson),
    db.prepare(
      `INSERT INTO work_periods (period, work_id, kind, n)
       SELECT 'w:' || date(s.finished_date, '-6 days', 'weekday 1'), s.work_id, w.kind, COUNT(*) ${base} GROUP BY 1, 2
       UNION ALL
       SELECT 'm:' || substr(s.finished_date, 1, 7), s.work_id, w.kind, COUNT(*) ${base} GROUP BY 1, 2`,
    ).bind(workIdsJson),
  ];
}
