// 公开书架上报：整份上报、整份替换、幂等。
//
// D1 每次调用有查询条数上限（免费 50 / 付费 1000），所以书架**不能逐条写**：整份条目
// 作为一个 JSON 参数，用 json_each 在少数几条集合 SQL 里完成「别名解析 → 建作品 →
// 挂别名 → 替换书架 → 回写作品展示字段」，放进一个 batch（D1 batch = 一个事务）。
//
// 作品身份：条目带一组按优先级排列的匹配键 refs（bgm:/isbn:/vndb:/tmdb:/anidb:/src:/t:），
// 存储时统一加 '<kind>|' 前缀。解析规则只有一条：取第一个已存在别名指向的作品；
// 全都不存在就新建作品。新键一律挂到解析出的作品上——这就是 ISBN 与「标题+作者」
// 两路匹配汇合的方式。误配由管理员拆分（admin.js，依据 shelf.refs）。

import { HttpError, clampInt, randomId } from './util.js';

export const KINDS = ['book', 'manga', 'video', 'game'];
export const MAX_ENTRIES = 20000;
export const MAX_DAILY = 5000;
export const MAX_REFS = 8;
export const DAILY_CHARS_CAP = 400000;
export const MAX_SHELF_BODY = 8 * 1024 * 1024;

const REF_RE = /^(bgm|isbn|vndb|tmdb|anidb|src|t):[^\u0000-\u001f]{1,256}$/;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const EARLIEST_MS = Date.UTC(2000, 0, 1);
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
  for (const r of e.refs) {
    if (typeof r !== 'string' || !REF_RE.test(r)) throw bad('ref');
    const full = `${e.kind}|${r}`;
    if (!refs.includes(full)) refs.push(full);
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
    if (typeof e.finishedDate !== 'string' || !DATE_RE.test(e.finishedDate)) throw bad('finishedDate');
    finishedDate = e.finishedDate;
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
  };
}

export function normalizeDaily(d, i, now) {
  if (!d || typeof d.date !== 'string' || !DATE_RE.test(d.date)) {
    throw new HttpError(400, 'bad_daily', `${i}`);
  }
  // 客户端本地日可能比 UTC 快一天。
  const maxKey = new Date(now + 36 * 3600 * 1000).toISOString().slice(0, 10);
  if (d.date > maxKey) throw new HttpError(400, 'bad_daily', `${i}: future`);
  return { date: d.date, chars: clampInt(d.chars, 0, DAILY_CHARS_CAP, 0) };
}

export function normalizeUpload(body, now) {
  if (!body || !Array.isArray(body.entries)) throw new HttpError(400, 'bad_upload');
  if (body.entries.length > MAX_ENTRIES) throw new HttpError(413, 'too_many_entries');
  const daily = Array.isArray(body.daily) ? body.daily : [];
  if (daily.length > MAX_DAILY) throw new HttpError(413, 'too_many_daily');
  const entries = body.entries.map((e, i) => ({ ...normalizeEntry(e, i, now), cand: randomId(12) }));
  const dailyMap = new Map();
  daily.forEach((d, i) => {
    const n = normalizeDaily(d, i, now);
    dailyMap.set(n.date, n.chars); // 同日重复取后者
  });
  return { entries, daily: [...dailyMap].map(([date, chars]) => ({ date, chars })) };
}

// 条目 e（json_each 行）的解析作品：第一个已存在别名指向的作品。
const RESOLVE = `(SELECT a.work_id FROM json_each(json_extract(e.value, '$.refs')) r
                  JOIN work_aliases a ON a.ref = r.value ORDER BY r.key LIMIT 1)`;
const J = (path) => `json_extract(e.value, '$.${path}')`;

/** 构造整份替换的 batch 语句（纯函数，便于单测看 SQL 顺序）。 */
export function shelfStatements(db, accountId, entriesJson, dailyJson, now) {
  return [
    // 1. 所有键都没见过的条目：用候选 id 建新作品。
    db.prepare(
      `INSERT INTO works (id, kind, title, author, cover_url, nsfw, created_at)
       SELECT ${J('cand')}, ${J('kind')}, ${J('title')}, ${J('author')}, ${J('coverUrl')}, ${J('nsfw')}, ?2
       FROM json_each(?1) e
       WHERE NOT EXISTS (SELECT 1 FROM json_each(${J('refs')}) r JOIN work_aliases a ON a.ref = r.value)`,
    ).bind(entriesJson, now),
    // 2. 挂别名：每个键指向解析出的作品（新作品则为候选 id）；已存在的键不动。
    db.prepare(
      `INSERT OR IGNORE INTO work_aliases (ref, work_id)
       SELECT r.value, COALESCE(${RESOLVE}, ${J('cand')})
       FROM json_each(?1) e, json_each(${J('refs')}) r`,
    ).bind(entriesJson),
    // 3. 同一次上报里两条目共享一个新键时，后者的候选作品一个别名都没抢到 → 删掉孤儿。
    db.prepare(
      `DELETE FROM works
       WHERE id IN (SELECT json_extract(value, '$.cand') FROM json_each(?1))
         AND NOT EXISTS (SELECT 1 FROM work_aliases a WHERE a.work_id = works.id)`,
    ).bind(entriesJson),
    // 4. 整份替换书架。
    db.prepare('DELETE FROM shelf WHERE account_id = ?1').bind(accountId),
    db.prepare(
      `INSERT INTO shelf (account_id, work_id, refs, title, author, finished_at, finished_date, chars, ms, updated_at)
       SELECT ?2, m.work_id, m.refs, m.title, m.author, m.finished_at, m.finished_date, m.chars, m.ms, ?3
       FROM (SELECT ${RESOLVE} AS work_id, json(${J('refs')}) AS refs, ${J('title')} AS title,
                    ${J('author')} AS author, ${J('finishedAt')} AS finished_at,
                    ${J('finishedDate')} AS finished_date, ${J('chars')} AS chars, ${J('ms')} AS ms
             FROM json_each(?1) e) m
       WHERE m.work_id IS NOT NULL
       ON CONFLICT (account_id, work_id) DO UPDATE SET
         finished_date = CASE WHEN excluded.finished_at > COALESCE(shelf.finished_at, -1)
                              THEN excluded.finished_date ELSE shelf.finished_date END,
         finished_at = MAX(COALESCE(shelf.finished_at, -1), COALESCE(excluded.finished_at, -1)),
         chars = shelf.chars + excluded.chars,
         ms = shelf.ms + excluded.ms`,
    ).bind(entriesJson, accountId, now),
    // 上面 MAX(…, -1) 把「都在读」写成 -1，这里还原成 NULL。
    db.prepare('UPDATE shelf SET finished_at = NULL, finished_date = NULL WHERE account_id = ?1 AND finished_at = -1')
      .bind(accountId),
    // 5. 作品展示字段 = 全体读者上报的众数（管理员锁定的作品除外）。
    db.prepare(
      `UPDATE works SET
         title = (SELECT s.title FROM shelf s WHERE s.work_id = works.id
                  GROUP BY s.title ORDER BY COUNT(*) DESC, MIN(s.updated_at) ASC LIMIT 1),
         author = (SELECT s.author FROM shelf s WHERE s.work_id = works.id
                   GROUP BY s.author ORDER BY COUNT(*) DESC, MIN(s.updated_at) ASC LIMIT 1)
       WHERE locked = 0 AND id IN (SELECT work_id FROM shelf WHERE account_id = ?1)`,
    ).bind(accountId),
    // 6. 封面 URL 先到先得；nsfw 只升不降（降级只能管理员做）。
    db.prepare(
      `UPDATE works SET
         cover_url = COALESCE(cover_url, CASE WHEN cover_key IS NULL THEN (
           SELECT ${J('coverUrl')} FROM json_each(?1) e
           WHERE ${J('coverUrl')} IS NOT NULL AND ${RESOLVE} = works.id LIMIT 1) END),
         nsfw = MAX(nsfw, COALESCE((
           SELECT MAX(${J('nsfw')}) FROM json_each(?1) e WHERE ${RESOLVE} = works.id), 0))
       WHERE id IN (SELECT work_id FROM shelf WHERE account_id = ?2)`,
    ).bind(entriesJson, accountId),
    // 7. 按天字数整份替换。
    db.prepare('DELETE FROM daily_chars WHERE account_id = ?1').bind(accountId),
    db.prepare(
      `INSERT INTO daily_chars (account_id, date_key, chars)
       SELECT ?2, json_extract(value, '$.date'), json_extract(value, '$.chars')
       FROM json_each(?1) WHERE json_extract(value, '$.chars') > 0`,
    ).bind(dailyJson, accountId),
  ];
}

/** 删除「本账户曾有、现在无人在架」的作品（含别名与 R2 缩略图）。previousIds 为替换前的作品集合。 */
export async function purgeOrphanWorks(env, previousIds) {
  if (previousIds.length === 0) return 0;
  const ids = JSON.stringify(previousIds);
  const orphans = await env.DB.prepare(
    `SELECT id, cover_key FROM works
     WHERE id IN (SELECT value FROM json_each(?1))
       AND NOT EXISTS (SELECT 1 FROM shelf s WHERE s.work_id = works.id)`,
  ).bind(ids).all();
  if (orphans.results.length === 0) return 0;
  const orphanIds = JSON.stringify(orphans.results.map((r) => r.id));
  await env.DB.batch([
    env.DB.prepare('DELETE FROM work_aliases WHERE work_id IN (SELECT value FROM json_each(?1))').bind(orphanIds),
    env.DB.prepare('DELETE FROM works WHERE id IN (SELECT value FROM json_each(?1))').bind(orphanIds),
  ]);
  const keys = orphans.results.map((r) => r.cover_key).filter(Boolean);
  if (keys.length && env.MEDIA) await env.MEDIA.delete(keys);
  return orphans.results.length;
}

/** 执行整份上报。返回每条上报条目（按下标）对应的作品 id 与是否缺封面。 */
export async function replaceShelf(env, accountId, upload, now) {
  const entriesJson = JSON.stringify(upload.entries);
  const dailyJson = JSON.stringify(upload.daily);
  const prev = await env.DB.prepare('SELECT work_id FROM shelf WHERE account_id = ?1').bind(accountId).all();
  await env.DB.batch(shelfStatements(env.DB, accountId, entriesJson, dailyJson, now));
  await purgeOrphanWorks(env, prev.results.map((r) => r.work_id));
  const mapped = await env.DB.prepare(
    `SELECT CAST(e.key AS INTEGER) AS i, w.id AS work_id,
            (w.cover_url IS NULL AND w.cover_key IS NULL) AS needs_cover
     FROM json_each(?1) e JOIN works w ON w.id = ${RESOLVE}
     ORDER BY i`,
  ).bind(entriesJson).all();
  return mapped.results.map((r) => ({ i: r.i, workId: r.work_id, needsCover: r.needs_cover === 1 }));
}
