// 公开书架上报：**增量协议**，幂等。
//
//   POST /v1/shelf { reset?, put: [条目 ≤ 500], remove: [workId ≤ 500], daily: [{date, chars} ≤ 400] }
//   reset = 先清空本账户书架与每日计分（首次同步 / 对账失败时用，随后分批 put）。
//   put   = 每部作品覆盖写（客户端发该作品合并后的完整值）；remove = 删除这些作品的行；
//   daily = 按日期覆盖当天字数（chars = 0 即清零）。
//
// 成本模型：D1 按读/写行数计量，所以一次请求的读写行数只随这一批的大小变化，与总用户数、
// 作品读者数无关——计数全部增量维护（accounts.shelf_count、works.readers、stat_days、
// account_totals），不做现场 COUNT / 全表扫描；众数只看每部作品最近 200 位读者。
// 写入前按估算行数扣全局日预算（budget.js）与每账户日上限。
//
// 作品身份：条目带一组按优先级排列的匹配键 refs（bgm:/isbn:/vndb:/tmdb:/anidb:/src:/t:），
// 每个命名空间至多一个；存储时统一加 '<kind>|' 前缀。解析在 JS 里一次算完（resolveUpload）：
//   1. 一次查询取出本批所有键里已存在的别名，再一次查询取出这些作品已有的命名空间；
//   2. 每条目：第一个已存在别名指向的作品；没有的条目按「共用新键」union-find 成组，
//      组内跟随第一个已解析成员，否则整组共建一部新作品；
//   3. 新键挂到「第一个带它的条目」解析出的作品上——但强 ID 命名空间（bgm/isbn/…）
//      已有键的作品不再挂同命名空间的新键（防止一条 [bgm:1, bgm:2…] 把无关作品抢注合并）；
//   4. 同一作品的多条目在 JS 里合并成一行书架。
//
// 已知竞态：两人在同一瞬间首次上报同一部全新作品，各建一部、后者的新键 INSERT OR IGNORE
// 落空 → 同一作品被拆成两部，由管理员合并。概率极低，不值得为它加锁。

import { HttpError, clampInt, randomId, utcDateKey } from './util.js';
import { adjustSpend, spend } from './budget.js';
import { accountPeriodsStatements, periodContributions, periodsOf, workPeriodsDeltaStatements } from './periods.js';
import { DAY, LIMITS, hit } from './ratelimit.js';

export const KINDS = ['book', 'manga', 'video', 'game'];
export const MAX_PUT = 500;
export const MAX_REMOVE = 500;
export const MAX_DAILY = 400;
/** 单账户书架行数上限（也受 D1 单参数约 2MB 约束——reset 时要一次读出全部旧行）。 */
export const MAX_SHELF_ROWS = 8000;
export const DAILY_CHARS_CAP = 400000;
/** 每日字数只收最近这么多天（见 normalizeDaily）。 */
export const DAILY_WINDOW_DAYS = 3650;
export const MAX_SHELF_BODY = 1024 * 1024;
/** 单个绑定参数（JSON 串）的字节上限；D1 线上约 2MB，node:sqlite 不限，所以必须自己查。 */
export const MAX_PARAM_BYTES = 1900 * 1024;
/** 计分规则：同一账户同一天最多计 30 部（批量补标历史作品照常入架，只是不刷分）。 */
export const DAILY_FINISH_CAP = 30;
/** 众数投票只看每部作品最近这么多位读者（有界读取）。 */
export const META_VOTERS = 200;
const ID_RE = /^[A-Za-z0-9_-]{1,32}$/;

export const NAMESPACES = ['bgm', 'isbn', 'vndb', 'anidb', 'mal', 'tmdb', 'src', 't'];
/** 强 ID：同一作品同命名空间只认第一个键。't'（标题+作者）是弱键，译名/变体可以挂多个。 */
export const STRONG_NAMESPACES = new Set(['bgm', 'isbn', 'vndb', 'anidb', 'mal', 'tmdb', 'src']);
export const MAX_REFS = NAMESPACES.length;

const REF_RE = /^(bgm|isbn|vndb|anidb|mal|tmdb|src|t):[^\u0000-\u001f]{1,256}$/;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const EARLIEST_MS = Date.UTC(2000, 0, 1);
const DAY_MS = 24 * 3600 * 1000;
/** 「读完但不知道哪天」（如 v112 前就标为玩过的游戏）的 finished_at 取值。 */
export const UNKNOWN_FINISH = 0;

/** 允许作为远端封面的主机（公开元数据站点的图床）。其它来源由客户端上传缩略图。 */
export const COVER_HOSTS = new Set([
  'image.tmdb.org',
  'lain.bgm.tv',
  't.vndb.org',
  's.vndb.org',
  'cdn.myanimelist.net',
  'cdn.anidb.net',
  'cdn-eu.anidb.net',
  'cdn-us.anidb.net',
]);

/** 存储形态的 ref（'<kind>|<ns>:<id>'）的命名空间。 */
export function refNamespace(storedRef) {
  const body = storedRef.slice(storedRef.indexOf('|') + 1);
  return body.slice(0, body.indexOf(':'));
}

export function acceptCoverUrl(raw) {
  if (typeof raw !== 'string' || raw.length > 512) return null;
  try {
    const u = new URL(raw);
    if (u.protocol !== 'https:' || !COVER_HOSTS.has(u.hostname)) return null;
    return u.toString();
  } catch {
    return null;
  }
}

function str(v, max) {
  if (typeof v !== 'string') return '';
  return v.normalize('NFC').replace(/[\u0000-\u001f]/g, ' ').trim().slice(0, max);
}

/** 校验并规范化一条书架条目；不合法抛 400（带下标，便于客户端定位）。 */
export function normalizeEntry(e, i, now) {
  const bad = (why) => new HttpError(400, 'bad_entry', `${i}: ${why}`);
  if (!e || typeof e !== 'object') throw bad('not_object');
  if (!KINDS.includes(e.kind)) throw bad('kind');
  if (!Array.isArray(e.refs) || e.refs.length < 1 || e.refs.length > MAX_REFS) throw bad('refs');
  const refs = [];
  const seenNs = new Set();
  for (const r of e.refs) {
    if (typeof r !== 'string' || !REF_RE.test(r)) throw bad('ref');
    const ns = r.slice(0, r.indexOf(':'));
    if (seenNs.has(ns)) throw bad('duplicate_namespace');
    seenNs.add(ns);
    refs.push(`${e.kind}|${r}`);
  }
  const title = str(e.title, 300);
  if (!title) throw bad('title');
  // 三态：在读（都不给）/ 读完且日期未知（finished:true，存 0，只进总榜）/ 读完有日期。
  let finishedAt = e.finished === true ? UNKNOWN_FINISH : null;
  let finishedDate = null;
  if (e.finishedAt != null) {
    finishedAt = Number(e.finishedAt);
    if (!Number.isSafeInteger(finishedAt) || finishedAt < EARLIEST_MS || finishedAt > now + 5 * 60 * 1000) {
      throw bad('finishedAt');
    }
    // 本地日期只能与读完时刻的 UTC 日期差一天以内（时区）——否则可以把几千部作品
    // 摊到几千个未来日期上，绕开每日 30 部的计分上限、永久霸占周榜/月榜。
    const d = e.finishedDate;
    if (
      typeof d !== 'string' || !DATE_RE.test(d) ||
      d < utcDateKey(finishedAt - DAY_MS) || d > utcDateKey(finishedAt + DAY_MS)
    ) {
      throw bad('finishedDate');
    }
    finishedDate = d;
  }
  return {
    kind: e.kind,
    refs,
    title,
    author: str(e.author, 200),
    coverUrl: acceptCoverUrl(e.coverUrl),
    nsfw: e.nsfw === true ? 1 : 0,
    finishedAt,
    finishedDate,
    chars: clampInt(e.chars, 0, 50_000_000, 0),
    ms: clampInt(e.ms, 0, 10_000_000_000, 0),
    // 同机多 Profile 去重（迁移 0002）：只有显式 false 才不计入作品维度的读者数。
    counted: e.counted === false ? 0 : 1,
  };
}

export function normalizeDaily(d, i, now) {
  if (!d || typeof d.date !== 'string' || !DATE_RE.test(d.date)) {
    throw new HttpError(400, 'bad_daily', `${i}`);
  }
  // 客户端本地日可能比 UTC 快一天；下限 10 年：更早的日期没有真实用途，却能无限刷字数总榜、
  // 也会让每次上传都要重算的 account_totals 读量没有上界。
  if (d.date > utcDateKey(now + 36 * 3600 * 1000)) throw new HttpError(400, 'bad_daily', `${i}: future`);
  if (d.date < utcDateKey(now - DAILY_WINDOW_DAYS * DAY_MS)) throw new HttpError(400, 'bad_daily', `${i}: too_old`);
  return { date: d.date, chars: clampInt(d.chars, 0, DAILY_CHARS_CAP, 0) };
}

export function normalizeUpload(body, now) {
  if (!body || typeof body !== 'object') throw new HttpError(400, 'bad_upload');
  const put = body.put === undefined ? [] : body.put;
  const remove = body.remove === undefined ? [] : body.remove;
  const daily = body.daily === undefined ? [] : body.daily;
  if (!Array.isArray(put) || !Array.isArray(remove) || !Array.isArray(daily)) throw new HttpError(400, 'bad_upload');
  if (put.length > MAX_PUT || remove.length > MAX_REMOVE || daily.length > MAX_DAILY) {
    throw new HttpError(413, 'batch_too_large');
  }
  for (const id of remove) if (typeof id !== 'string' || !ID_RE.test(id)) throw new HttpError(400, 'bad_remove');
  const dailyMap = new Map();
  daily.forEach((d, i) => {
    const n = normalizeDaily(d, i, now);
    dailyMap.set(n.date, n.chars); // 同日重复取后者
  });
  if (body.claim === true && body.reset !== true) throw new HttpError(400, 'claim_requires_reset');
  return {
    reset: body.reset === true,
    claim: body.claim === true,
    put: put.map((e, i) => normalizeEntry(e, i, now)),
    remove: [...new Set(remove)],
    daily: [...dailyMap].map(([date, chars]) => ({ date, chars })),
  };
}

function finishRank(at) {
  return at === null ? -1 : at;
}

/**
 * 纯函数：把规范化后的条目解析成作品。
 * @param entries      normalizeEntry 的结果（按上报顺序）
 * @param existing     Map<ref, workId>：本次涉及的键里已存在的别名
 * @param workNs       Map<workId, Set<namespace>>：这些已存在作品已有的命名空间
 * @param newId        () => string：新作品 id 生成器（测试可注入）
 * @returns {{ entryWork: string[], newWorks: object[], newAliases: object[], rows: object[] }}
 */
export function resolveUpload(entries, existing, workNs, newId = () => randomId(12)) {
  const n = entries.length;
  const own = entries.map((e) => {
    for (const r of e.refs) if (existing.has(r)) return existing.get(r);
    return null;
  });

  // 没解析到已有作品的条目，按共用的新键成组。
  const parent = [...Array(n).keys()];
  const find = (x) => {
    while (parent[x] !== x) x = parent[x] = parent[parent[x]];
    return x;
  };
  const firstWithRef = new Map();
  entries.forEach((e, i) => {
    for (const r of e.refs) {
      if (existing.has(r)) continue;
      if (firstWithRef.has(r)) parent[find(i)] = find(firstWithRef.get(r));
      else firstWithRef.set(r, i);
    }
  });

  // 组的作品：组内第一个自带解析的成员的作品；没有就整组共建一部新作品。
  const groupWork = new Map();
  const newWorks = [];
  const ns = new Map([...workNs].map(([w, s]) => [w, new Set(s)]));
  for (let i = 0; i < n; i++) {
    const g = find(i);
    if (!groupWork.has(g) && own[i] !== null) groupWork.set(g, own[i]);
  }
  const entryWork = entries.map((e, i) => {
    if (own[i] !== null) return own[i];
    const g = find(i);
    if (!groupWork.has(g)) {
      const id = newId();
      groupWork.set(g, id);
      ns.set(id, new Set());
      newWorks.push({ id, kind: e.kind, title: e.title, author: e.author });
    }
    return groupWork.get(g);
  });

  // 新键挂到第一个带它的条目的作品上；强命名空间已占用则不挂。
  const newAliases = [];
  for (const [ref, i] of firstWithRef) {
    const w = entryWork[i];
    const space = refNamespace(ref);
    const taken = ns.get(w) || new Set();
    if (STRONG_NAMESPACES.has(space) && taken.has(space)) continue;
    taken.add(space);
    ns.set(w, taken);
    newAliases.push({ ref, workId: w });
  }

  // 同一作品的多条目合并成一行：读完取最晚，字数/时长累加，refs 取并集（保持先后）。
  const byWork = new Map();
  entries.forEach((e, i) => {
    const w = entryWork[i];
    const row = byWork.get(w);
    if (!row) {
      byWork.set(w, {
        workId: w,
        refs: [...e.refs],
        title: e.title,
        author: e.author,
        finishedAt: e.finishedAt,
        finishedDate: e.finishedDate,
        chars: e.chars,
        ms: e.ms,
        coverUrl: e.coverUrl,
        nsfw: e.nsfw,
        counted: e.counted ?? 1,
      });
      return;
    }
    for (const r of e.refs) if (!row.refs.includes(r)) row.refs.push(r);
    if (finishRank(e.finishedAt) > finishRank(row.finishedAt)) {
      row.finishedAt = e.finishedAt;
      row.finishedDate = e.finishedDate;
    }
    row.chars += e.chars;
    row.ms += e.ms;
    row.coverUrl = row.coverUrl || e.coverUrl;
    row.nsfw = Math.max(row.nsfw, e.nsfw);
    // 同一作品的任一条目计入，整行就计入。
    row.counted = Math.max(row.counted, e.counted ?? 1);
  });
  return { entryWork, newWorks, newAliases, rows: [...byWork.values()] };
}

function jsonParam(value) {
  const s = JSON.stringify(value);
  if (new TextEncoder().encode(s).length > MAX_PARAM_BYTES) throw new HttpError(413, 'shelf_too_large');
  return s;
}

const J = (p) => `json_extract(value, '$.${p}')`;

/**
 * 「这些作品若已无人在架就删掉」的两条语句（别名 + 作品，后者 RETURNING cover_key 供删 R2）。
 * 判据写在删除语句自身里、并与其它写入同处一个事务——先查孤儿再另发删除会误删别人刚上架的作品。
 */
export function orphanPurgeStatements(db, idsJson) {
  return [
    db.prepare(
      `DELETE FROM work_aliases
       WHERE work_id IN (SELECT value FROM json_each(?1))
         AND NOT EXISTS (SELECT 1 FROM shelf s WHERE s.work_id = work_aliases.work_id)`,
    ).bind(idsJson),
    db.prepare(
      `DELETE FROM works
       WHERE id IN (SELECT value FROM json_each(?1))
         AND NOT EXISTS (SELECT 1 FROM shelf s WHERE s.work_id = works.id)
       RETURNING cover_key`,
    ).bind(idsJson),
  ];
}

export function coverKeysOf(purgeResult) {
  return ((purgeResult && purgeResult.results) || []).map((r) => r.cover_key).filter(Boolean);
}

/**
 * 作品展示字段 = 最近 META_VOTERS 位未隐藏读者上报的众数（管理员锁定的除外；作者只数非空票）。
 * 有界：沿 idx_shelf_work 取最近的读者，不随作品总读者数增长。idSubquery 选出要重算的作品 id。
 */
export function recomputeMetaStatementWhere(db, idSubquery) {
  const voters = `SELECT s.title, s.author FROM shelf s JOIN accounts a ON a.id = s.account_id AND a.hidden = 0
                  WHERE s.work_id = works.id AND s.counted = 1 ORDER BY s.finished_at DESC LIMIT ${META_VOTERS}`;
  return db.prepare(
    `UPDATE works SET
       title = COALESCE((SELECT title FROM (${voters}) GROUP BY title ORDER BY COUNT(*) DESC, title LIMIT 1), title),
       author = COALESCE((SELECT author FROM (${voters}) WHERE author != ''
                          GROUP BY author ORDER BY COUNT(*) DESC, author LIMIT 1), '')
     WHERE locked = 0 AND id IN (${idSubquery})`,
  );
}

/** 按 id 列表（JSON）重算众数。 */
export function recomputeMetaStatement(db, idsJson) {
  return recomputeMetaStatementWhere(db, 'SELECT value FROM json_each(?1)').bind(idsJson);
}

/**
 * 重算一个账户若干天（dates JSON；null = 全部天）的计分行与总计。读取只涉及该账户自己的行。
 * 返回语句数组（放进调用方的事务）。
 */
export function accountStatsStatements(db, accountId, datesJson) {
  const dateFilter = datesJson === null ? '' : 'AND date_key IN (SELECT value FROM json_each(?2))';
  const shelfDateFilter = datesJson === null ? '' : 'AND s.finished_date IN (SELECT value FROM json_each(?2))';
  const cap = (k) => `MIN(SUM(w.kind = '${k}'), ${DAILY_FINISH_CAP})`;
  const binds = datesJson === null ? [accountId] : [accountId, datesJson];
  const unknown = (k) => `(SELECT COUNT(*) FROM shelf s JOIN works w ON w.id = s.work_id
                           WHERE s.account_id = ?1 AND s.finished_at = 0 AND w.kind = '${k}')`;
  return [
    db.prepare(
      `UPDATE stat_days SET book = 0, manga = 0, video = 0, game = 0 WHERE account_id = ?1 ${dateFilter}`,
    ).bind(...binds),
    db.prepare(
      `INSERT INTO stat_days (account_id, date_key, book, manga, video, game)
       SELECT ?1, s.finished_date, ${cap('book')}, ${cap('manga')}, ${cap('video')}, ${cap('game')}
       FROM shelf s JOIN works w ON w.id = s.work_id
       WHERE s.account_id = ?1 AND s.finished_at > 0 ${shelfDateFilter}
       GROUP BY s.finished_date
       ON CONFLICT (account_id, date_key) DO UPDATE SET
         book = excluded.book, manga = excluded.manga, video = excluded.video, game = excluded.game`,
    ).bind(...binds),
    db.prepare(
      `DELETE FROM stat_days WHERE account_id = ?1 ${dateFilter}
         AND book = 0 AND manga = 0 AND video = 0 AND game = 0 AND chars = 0`,
    ).bind(...binds),
    db.prepare(
      `INSERT INTO account_totals (account_id, book, manga, video, game, chars)
       SELECT ?1,
              COALESCE(SUM(book), 0) + ${unknown('book')}, COALESCE(SUM(manga), 0) + ${unknown('manga')},
              COALESCE(SUM(video), 0) + ${unknown('video')}, COALESCE(SUM(game), 0) + ${unknown('game')},
              COALESCE(SUM(chars), 0)
       FROM stat_days WHERE account_id = ?1
       ON CONFLICT (account_id) DO UPDATE SET
         book = excluded.book, manga = excluded.manga, video = excluded.video,
         game = excluded.game, chars = excluded.chars`,
    ).bind(accountId),
  ];
}

/** 作品读者数增量：deltas = [{id, d}]。 */
export function readersDeltaStatement(db, deltasJson) {
  return db.prepare(
    `UPDATE works SET readers = MAX(0, works.readers + j.d)
     FROM (SELECT ${J('id')} AS id, SUM(${J('d')}) AS d FROM json_each(?1) GROUP BY 1) AS j
     WHERE works.id = j.id AND j.d != 0`,
  ).bind(deltasJson);
}

const isFinished = (at) => at !== null && at !== undefined;

/**
 * 纯函数：本批之后的新旧差。对每个被触及的作品只用一条规则——
 *   之后存在 = 在 put 里，或（非 reset 且旧行存在且不在 remove 里）；
 *   之后读完 = put 的看新值，否则沿用旧值；
 *   书架行数差 / 读者数差 / 周期读者数差 = 之后 − 之前。
 * @param oldRows Map<workId, {finished_at, finished_date}>（reset 时是本账户全部旧行）
 * @param putRows resolveUpload().rows
 */
export function shelfDiff({ reset, remove, oldRows, putRows }) {
  const put = new Map(putRows.map((r) => [r.workId, r]));
  const removeSet = new Set(remove);
  const ids = new Set([...oldRows.keys(), ...put.keys(), ...remove]);
  let countDelta = 0;
  const readerDeltas = [];
  const periodDeltas = [];
  const dates = new Set();
  const gone = [];
  for (const id of ids) {
    const o = oldRows.get(id);
    const p = put.get(id);
    const existedBefore = o !== undefined;
    const existsAfter = p !== undefined || (!reset && existedBefore && !removeSet.has(id));
    // 作品维度的读者数（works.readers / work_periods）只算 counted 的行（迁移 0002）；
    // 账户自己的计分（shelf_count / stat_days / account_periods）不看 counted。
    const countedBefore = existedBefore && o.counted !== 0;
    const countedAfter = p !== undefined ? p.counted !== 0 : existsAfter && countedBefore;
    const readerBefore = countedBefore && isFinished(o.finished_at);
    const readerAfter = countedAfter && (p !== undefined ? isFinished(p.finishedAt) : isFinished(o.finished_at));
    countDelta += (existsAfter ? 1 : 0) - (existedBefore ? 1 : 0);
    const d = (readerAfter ? 1 : 0) - (readerBefore ? 1 : 0);
    if (d !== 0) readerDeltas.push({ id, d });
    if (existedBefore && !existsAfter) gone.push(id);
    const changed = p !== undefined || !existsAfter;
    if (changed && o) {
      if (o.finished_date) dates.add(o.finished_date);
      if (countedBefore) periodDeltas.push(...periodContributions(id, o.finished_at, o.finished_date, -1));
    }
    if (changed && existsAfter) {
      const after = p !== undefined ? { at: p.finishedAt, date: p.finishedDate } : { at: o.finished_at, date: o.finished_date };
      if (after.date) dates.add(after.date);
      if (countedAfter) periodDeltas.push(...periodContributions(id, after.at, after.date, 1));
    }
  }
  return { countDelta, readerDeltas, periodDeltas, dates, gone };
}

/**
 * 乐观锁：本批只有在账户书架版本仍是 rev 时才生效。版本不符时第一条语句向 cas_guard 插 NULL，
 * NOT NULL 约束让整个 batch（一个事务）回滚；第二条语句把版本 +1。
 * 所有改本账户书架 / 计数的写路径（上传、隐藏、删号、管理合并拆分）都走它或递增同一版本。
 */
export function casStatements(db, accountId, rev) {
  return [
    db.prepare(
      'INSERT INTO cas_guard (ok) SELECT NULL WHERE NOT EXISTS (SELECT 1 FROM accounts WHERE id = ?1 AND shelf_rev = ?2)',
    ).bind(accountId, rev),
    db.prepare('UPDATE accounts SET shelf_rev = shelf_rev + 1 WHERE id = ?1').bind(accountId),
  ];
}

export function isCasConflict(e) {
  return /cas_guard/.test(String(e && e.message));
}

/** 跑一个带 CAS 的 batch；版本冲突转成 409 conflict（整批已回滚，无副作用，客户端重读后重试）。 */
export async function casBatch(db, stmts) {
  try {
    return await db.batch(stmts);
  } catch (e) {
    if (isCasConflict(e)) throw new HttpError(409, 'conflict');
    throw e;
  }
}

/** D1 每写一行、每个受影响索引另计一行；估算按表的索引数放大（shelf 有 4 个索引 + works 回写）。 */
export function estimateWriteRows({ newWorks, newAliases, rows, gone, dates, periods, readerDeltas, periodDeltas }) {
  return newWorks * 3 + newAliases * 3 + rows * 7 + gone * 7 + dates * 4 + periods * 3 +
    readerDeltas * 3 + periodDeltas * 4 + 16;
}

/**
 * 执行一批增量上报。keyId = 发起请求的设备钥匙。返回 put 条目（按下标）对应的作品与是否缺封面、
 * 服务端书架行数、待删 R2 key、D1 实际写入行数（若可得）。
 */
export async function applyShelfDelta(env, account, keyId, upload, now) {
  const db = env.DB;
  const accountId = account.id;

  // 0. 事务外先读版本（此后任何并发改动都会让本批的 CAS 失败）与上传设备。
  const acc = await db.prepare('SELECT shelf_rev, shelf_count, hidden, upload_key FROM accounts WHERE id = ?1')
    .bind(accountId).first();
  if (!acc) throw new HttpError(401, 'unknown_account');
  if (acc.upload_key !== null && acc.upload_key !== keyId) {
    if (!(upload.claim && upload.reset)) throw new HttpError(409, 'upload_owned_by_other_device');
  }

  // 1. 解析本批 put 的作品（读取量 ≈ 本批键数）。
  let res = { entryWork: [], newWorks: [], newAliases: [], rows: [] };
  if (upload.put.length) {
    const allRefs = [...new Set(upload.put.flatMap((e) => e.refs))];
    const found = await db.prepare(
      `SELECT a.ref, a.work_id FROM work_aliases a JOIN works w ON w.id = a.work_id
       WHERE a.ref IN (SELECT value FROM json_each(?1))`,
    ).bind(jsonParam(allRefs)).all();
    const existing = new Map(found.results.map((r) => [r.ref, r.work_id]));
    const nsRows = await db.prepare(
      'SELECT work_id, ref FROM work_aliases WHERE work_id IN (SELECT value FROM json_each(?1))',
    ).bind(jsonParam([...new Set(existing.values())])).all();
    const workNs = new Map();
    for (const r of nsRows.results) {
      if (!workNs.has(r.work_id)) workNs.set(r.work_id, new Set());
      workNs.get(r.work_id).add(refNamespace(r.ref));
    }
    res = resolveUpload(upload.put, existing, workNs);
  }
  const kindOf = new Map(res.rows.map((r, i) => [r.workId, upload.put[res.entryWork.indexOf(r.workId)].kind]));

  // 2. 被触及的旧行（reset = 本账户全部旧行；否则只按 PK 取本批涉及的作品）。
  const putIds = res.rows.map((r) => r.workId);
  const old = upload.reset
    ? await db.prepare('SELECT work_id, finished_at, finished_date, counted FROM shelf WHERE account_id = ?1')
      .bind(accountId).all()
    : await db.prepare(
      `SELECT work_id, finished_at, finished_date, counted FROM shelf
       WHERE account_id = ?1 AND work_id IN (SELECT value FROM json_each(?2))`,
    ).bind(accountId, jsonParam([...new Set([...putIds, ...upload.remove])])).all();
  const oldRows = new Map(old.results.map((r) => [r.work_id, r]));

  // 3. 新旧差（纯函数）。
  const diff = shelfDiff({ reset: upload.reset, remove: upload.remove, oldRows, putRows: res.rows });
  const newCount = (upload.reset ? old.results.length : acc.shelf_count) + diff.countDelta;
  if (newCount > MAX_SHELF_ROWS) throw new HttpError(413, 'shelf_full');
  for (const d of upload.daily) diff.dates.add(d.date);
  const periods = [...new Set([...diff.dates].flatMap(periodsOf))];
  // 被隐藏的账户不计入任何作品的读者数，也不参与众数（hidden 取本次读到的最新值）。
  const readerDeltas = acc.hidden ? [] : diff.readerDeltas;
  const periodDeltas = acc.hidden ? [] : diff.periodDeltas;

  // 4. 预算：按估算写入行数扣本账户日上限与全局日预算（都在写入之前）。
  const estRows = estimateWriteRows({
    newWorks: res.newWorks.length, newAliases: res.newAliases.length, rows: res.rows.length,
    gone: diff.gone.length, dates: diff.dates.size, periods: periods.length,
    readerDeltas: readerDeltas.length, periodDeltas: periodDeltas.length,
  });
  await hit(env, `rows:${accountId}`, DAY, LIMITS.shelfRowsPerAccountDay, now, estRows);
  await spend(env, 'write_rows', estRows, now);

  // 5. 一个事务写完：CAS 打头，版本不符整批回滚。
  const rowsJson = jsonParam(res.rows.map((r) => ({ ...r, kind: kindOf.get(r.workId), refs: JSON.stringify(r.refs) })));
  const stmts = [
    ...casStatements(db, accountId, acc.shelf_rev),
    db.prepare(
      `INSERT INTO works (id, kind, title, author, created_at)
       SELECT ${J('id')}, ${J('kind')}, ${J('title')}, ${J('author')}, ?2 FROM json_each(?1)`,
    ).bind(jsonParam(res.newWorks), now),
    db.prepare(
      `INSERT OR IGNORE INTO work_aliases (ref, work_id)
       SELECT ${J('ref')}, ${J('workId')} FROM json_each(?1)`,
    ).bind(jsonParam(res.newAliases)),
  ];
  if (acc.upload_key !== keyId) {
    stmts.push(db.prepare('UPDATE accounts SET upload_key = ?2 WHERE id = ?1').bind(accountId, keyId));
  }
  if (upload.reset) {
    stmts.push(
      db.prepare('DELETE FROM shelf WHERE account_id = ?1').bind(accountId),
      db.prepare('DELETE FROM stat_days WHERE account_id = ?1').bind(accountId),
    );
  } else if (diff.gone.length) {
    stmts.push(db.prepare(
      'DELETE FROM shelf WHERE account_id = ?1 AND work_id IN (SELECT value FROM json_each(?2))',
    ).bind(accountId, jsonParam(diff.gone)));
  }
  stmts.push(
    db.prepare(
      `INSERT INTO shelf (account_id, work_id, kind, refs, title, author, finished_at, finished_date, chars, ms, counted, updated_at)
       SELECT ?2, ${J('workId')}, ${J('kind')}, ${J('refs')}, ${J('title')}, ${J('author')}, ${J('finishedAt')},
              ${J('finishedDate')}, ${J('chars')}, ${J('ms')}, ${J('counted')}, ?3
       FROM json_each(?1) WHERE 1
       ON CONFLICT (account_id, work_id) DO UPDATE SET
         refs = excluded.refs, title = excluded.title, author = excluded.author,
         finished_at = excluded.finished_at, finished_date = excluded.finished_date,
         chars = excluded.chars, ms = excluded.ms, counted = excluded.counted, updated_at = excluded.updated_at`,
    ).bind(rowsJson, accountId, now),
    readersDeltaStatement(db, jsonParam(readerDeltas)),
    ...workPeriodsDeltaStatements(db, jsonParam(periodDeltas)),
    // 远端封面先到先得（已有上传缩略图的不覆盖）；nsfw 只升不降。只改真的会变的行（没变也算写入）。
    db.prepare(
      `UPDATE works SET
         cover_url = COALESCE(works.cover_url, CASE WHEN works.cover_key IS NULL THEN j.cover END),
         nsfw = MAX(works.nsfw, j.nsfw)
       FROM (SELECT ${J('workId')} AS id, ${J('coverUrl')} AS cover, ${J('nsfw')} AS nsfw FROM json_each(?1)) AS j
       WHERE works.id = j.id
         AND ((works.cover_url IS NULL AND works.cover_key IS NULL AND j.cover IS NOT NULL) OR j.nsfw > works.nsfw)`,
    ).bind(rowsJson),
    db.prepare(
      `INSERT INTO stat_days (account_id, date_key, chars)
       SELECT ?2, ${J('date')}, ${J('chars')} FROM json_each(?1) WHERE 1
       ON CONFLICT (account_id, date_key) DO UPDATE SET chars = excluded.chars`,
    ).bind(jsonParam(upload.daily), accountId),
    ...accountStatsStatements(db, accountId, upload.reset ? null : jsonParam([...diff.dates])),
    ...accountPeriodsStatements(db, accountId, upload.reset ? null : periods),
    db.prepare('UPDATE accounts SET shelf_count = shelf_count + ?2 WHERE id = ?1')
      .bind(accountId, upload.reset ? newCount - acc.shelf_count : diff.countDelta),
  );
  if (!acc.hidden) stmts.push(metaIfChangedStatement(db, rowsJson));
  stmts.push(...orphanPurgeStatements(db, jsonParam(diff.gone)));
  const results = await casBatch(db, stmts);
  const coverKeys = coverKeysOf(results[results.length - 1]);
  const written = results.reduce((n, r) => n + ((r && r.meta && r.meta.rows_written) || 0), 0);
  // 用 D1 回报的真实写入行数校正预算（本地 SQLite 没有该字段时跳过）。
  if (written > 0) await adjustSpend(env, 'write_rows', written - estRows, now);

  const covers = await db.prepare(
    `SELECT id, (cover_url IS NULL AND cover_key IS NULL) AS needs_cover FROM works
     WHERE id IN (SELECT value FROM json_each(?1))`,
  ).bind(jsonParam(putIds)).all();
  const needs = new Map(covers.results.map((r) => [r.id, r.needs_cover === 1]));
  return {
    coverKeys,
    works: res.entryWork.map((workId, i) => ({ i, workId, needsCover: needs.get(workId) === true })),
    shelfCount: newCount,
  };
}

/**
 * 众数只在「上报的标题 / 非空作者」与作品现值不同时重算：热门作品绝大多数上报都与现值一致，
 * 这样常态下一行都不用读。
 */
function metaIfChangedStatement(db, rowsJson) {
  return recomputeMetaStatementWhere(
    db,
    `SELECT j.id FROM (SELECT ${J('workId')} AS id, ${J('title')} AS title, ${J('author')} AS author
                       FROM json_each(?1)) AS j
     JOIN works w2 ON w2.id = j.id
     WHERE w2.title != j.title OR (j.author != '' AND w2.author != j.author)`,
  ).bind(rowsJson);
}
