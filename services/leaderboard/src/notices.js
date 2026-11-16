// 服务端下发的公告：App 带上构建信息来问，服务端按规则（D1，迁移 0022_notices.sql）匹配后下发公告与文案。
// 规则、文案与匹配逻辑只在服务端；客户端只负责上报构建信息、按 level 显示收到的公告。
//
//   POST /v1/notices  {v, p, c, l, id, h, k} → 200 {notices: [{id, level, title, body, url}], ttl}
//     v   运行中的版本号            p  平台（android / windows / macos / linux）
//     c   更新通道                  l  界面语言（BCP 47，如 zh-CN）
//     id  Android applicationId（其它平台 null）
//     h   系统 PackageManager 给出的各签名证书 SHA-256（小写 hex）
//     k   App 自己从已安装 APK 的签名块解析出的各签名证书 SHA-256（小写 hex）
//     h / k 可以为空（非 Android 或读取失败）；不认识的字段忽略。请求不带安装 id、设备标识或账户。
//   ttl：没有公告时 6 小时、有公告时 1 小时后再问。
//
// 规则种类见迁移文件头。一个请求可能命中多条规则：全部返回（id = "r<规则 id>"），严重的在前
// （block > dialog > banner，同级按规则 id）。文案：界面语言以 zh 开头取中文两列，否则取英文两列，
// 英文标题与正文都空时回落中文。
//
// 计数（notice_seen）：每个请求按「UTC 日 × 应用 id × 首个摘要 × h/k 是否不相交 × 版本 × 平台 × 国家」
// upsert 一次，让维护者看到外面有哪些构建在跑。不存 IP。写入扣 'notices' 日预算（budget.js），
// 用完当天就只匹配不计数——公告照常下发，计数成为下限。
//
// 管理端（admin.js 的 Basic Auth 之后分派到 handleNoticesAdmin）：
//   GET  /admin/api/notices/rules                 全部规则
//   POST /admin/api/notices/rules                 {kind, value?, platform?, level, title_zh?, body_zh?, title_en?, body_en?, url?, enabled?}
//   POST /admin/api/notices/rules/:id             同上字段的部分更新
//   POST /admin/api/notices/rules/:id/disable     停用（不删，便于回看）
//   POST /admin/api/notices/rules/:id/delete      删除
//   GET  /admin/api/notices/known                 已登记摘要
//   POST /admin/api/notices/known                 {h, label?} 登记（已有则改 label）
//   POST /admin/api/notices/known/:h/remove       移除
//   GET  /admin/api/notices/seen?days=&limit=     近 days 天按构建信息汇总的计数（n 降序）

import { HttpError, clampInt, json, utcDateKey } from './util.js';
import { budgetLimit } from './budget.js';
import { PING_PLATFORMS, normalizeLocale, requestCountry } from './installs.js';

const DAY_MS = 24 * 3600 * 1000;

export const NOTICE_LIMITS = {
  /** 请求体上限（字节）。 */
  maxBodyBytes: 2048,
  /** h / k 各最多几项（Android 签名证书通常 1 个，轮换后 2 个）。 */
  maxDigests: 8,
  /** 没有公告 / 有公告时客户端多久后再问（秒）。 */
  ttlEmpty: 21600,
  ttlMatched: 3600,
  /** notice_seen 保留天数（定时任务清理）。 */
  retentionDays: 120,
  /** 管理端汇总默认 / 最大天数与行数。 */
  seenDays: 30,
  seenDaysMax: 120,
  seenLimit: 200,
  seenLimitMax: 1000,
  /** 文案长度上限（字符）。 */
  titleMax: 200,
  bodyMax: 4000,
  urlMax: 500,
  labelMax: 200,
};

export const NOTICE_KINDS = ['h', 'id', 'h_unlisted', 'hk_disjoint', 'all'];
export const NOTICE_LEVELS = ['banner', 'dialog', 'block'];
/** 严重程度：数字越大越靠前。 */
const LEVEL_RANK = { block: 3, dialog: 2, banner: 1 };

const VERSION_RE = /^[A-Za-z0-9.+_-]{1,64}$/;
const CHANNEL_RE = /^[A-Za-z0-9_-]{1,32}$/;
const DIGEST_RE = /^[0-9a-f]{64}$/;
/** Android applicationId：至少两段，每段字母开头。 */
const APP_ID_RE = /^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+$/;
const APP_ID_MAX = 255;

function digestList(v, field) {
  if (v === undefined || v === null) return [];
  if (!Array.isArray(v) || v.length > NOTICE_LIMITS.maxDigests) throw new HttpError(400, `bad_${field}`);
  const out = [];
  for (const d of v) {
    if (typeof d !== 'string') throw new HttpError(400, `bad_${field}`);
    const x = d.toLowerCase();
    if (!DIGEST_RE.test(x)) throw new HttpError(400, `bad_${field}`);
    if (!out.includes(x)) out.push(x);
  }
  return out;
}

/** 校验并规范化请求体；形状不对 400。 */
export function normalizeNoticeQuery(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw new HttpError(400, 'bad_json');
  if (typeof body.v !== 'string' || !VERSION_RE.test(body.v)) throw new HttpError(400, 'bad_v');
  if (!PING_PLATFORMS.includes(body.p)) throw new HttpError(400, 'bad_p');
  let c = null;
  if (body.c !== undefined && body.c !== null) {
    if (typeof body.c !== 'string' || !CHANNEL_RE.test(body.c)) throw new HttpError(400, 'bad_c');
    c = body.c;
  }
  let l = null;
  try {
    l = normalizeLocale(body.l);
  } catch {
    throw new HttpError(400, 'bad_l');
  }
  let id = null;
  if (body.id !== undefined && body.id !== null) {
    if (typeof body.id !== 'string' || body.id.length > APP_ID_MAX || !APP_ID_RE.test(body.id)) {
      throw new HttpError(400, 'bad_id');
    }
    id = body.id;
  }
  return { v: body.v, p: body.p, c, l, id, h: digestList(body.h, 'h'), k: digestList(body.k, 'k') };
}

/** h 与 k 都非空且没有共同摘要。 */
export function digestsDisjoint(q) {
  return q.h.length > 0 && q.k.length > 0 && !q.h.some((d) => q.k.includes(d));
}

/** 一条规则是否命中。known = 请求里已登记在 notice_known_h 的摘要集合。 */
export function ruleMatches(rule, q, known) {
  if (rule.platform && rule.platform !== q.p) return false;
  const all = [...q.h, ...q.k];
  switch (rule.kind) {
    case 'h':
      return typeof rule.value === 'string' && all.includes(rule.value);
    case 'id':
      return typeof rule.value === 'string' && q.id === rule.value;
    case 'h_unlisted':
      return all.length > 0 && !all.some((d) => known.has(d));
    case 'hk_disjoint':
      return digestsDisjoint(q);
    case 'all':
      return true;
    default:
      return false;
  }
}

/** 规则 → 下发给客户端的公告（按界面语言选文案）。 */
export function noticeOf(rule, locale) {
  const zh = typeof locale === 'string' && locale.toLowerCase().startsWith('zh');
  const hasEn = Boolean(rule.title_en) || Boolean(rule.body_en);
  const useZh = zh || !hasEn;
  return {
    id: `r${rule.id}`,
    level: rule.level,
    title: (useZh ? rule.title_zh : rule.title_en) || '',
    body: (useZh ? rule.body_zh : rule.body_en) || '',
    url: rule.url || null,
  };
}

/** 按严重程度降序、同级按规则 id 升序。 */
function bySeverity(a, b) {
  return (LEVEL_RANK[b.level] - LEVEL_RANK[a.level]) || (a.id - b.id);
}

/** 匹配：读平台相关的启用规则；有 'h_unlisted' 规则时才查已登记摘要。 */
export async function matchNotices(env, q) {
  const rules = (await env.DB.prepare(
    'SELECT * FROM notice_rules WHERE enabled = 1 AND (platform IS NULL OR platform = ?1)',
  ).bind(q.p).all()).results;
  if (rules.length === 0) return [];
  const known = new Set();
  const all = [...q.h, ...q.k];
  if (all.length > 0 && rules.some((r) => r.kind === 'h_unlisted')) {
    const rows = (await env.DB.prepare(
      'SELECT h FROM notice_known_h WHERE h IN (SELECT value FROM json_each(?1))',
    ).bind(JSON.stringify(all)).all()).results;
    for (const r of rows) known.add(r.h);
  }
  return rules.filter((r) => ruleMatches(r, q, known)).sort(bySeverity).map((r) => noticeOf(r, q.l));
}

/**
 * 计数 upsert。先在 'notices' 日预算里条件加一（到上限就不再写预算行，也不写计数），
 * 所以超额后这条路径零写入。
 */
export async function recordSeen(env, request, q, now) {
  const day = utcDateKey(now);
  const ok = await env.DB.prepare(
    `INSERT INTO budgets (day, kind, used) VALUES (?1, 'notices', 1)
     ON CONFLICT (day, kind) DO UPDATE SET used = used + 1 WHERE used < ?2
     RETURNING used`,
  ).bind(day, budgetLimit(env, 'notices')).first();
  if (!ok) return false;
  await env.DB.prepare(
    `INSERT INTO notice_seen (day, id, h, hk_disjoint, v, p, country, n) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 1)
     ON CONFLICT (day, id, h, hk_disjoint, v, p, country) DO UPDATE SET n = n + 1`,
  ).bind(day, q.id ?? '', q.h[0] ?? q.k[0] ?? '', digestsDisjoint(q) ? 1 : 0, q.v, q.p, requestCountry(request) ?? '').run();
  return true;
}

/** POST /v1/notices。 */
export async function handleNotices(env, request, body, now) {
  const q = normalizeNoticeQuery(body);
  const notices = await matchNotices(env, q);
  await recordSeen(env, request, q, now);
  return json(
    { notices, ttl: notices.length ? NOTICE_LIMITS.ttlMatched : NOTICE_LIMITS.ttlEmpty },
    200,
    { 'Cache-Control': 'no-store' },
  );
}

/** 清掉保留期外的计数（scheduled）。 */
export async function purgeNoticeSeen(env, now) {
  await env.DB.prepare('DELETE FROM notice_seen WHERE day < ?1')
    .bind(utcDateKey(now - NOTICE_LIMITS.retentionDays * DAY_MS)).run();
}

// ---- 管理端 ----

function optText(v, max, code) {
  if (v === undefined || v === null || v === '') return null;
  if (typeof v !== 'string' || v.length > max) throw new HttpError(400, code);
  return v;
}

/**
 * 校验一条规则（创建：base = null；更新：base = 现有行，body 里没给的字段沿用）。返回要写入的完整行。
 */
export function normalizeRule(body, base = null) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw new HttpError(400, 'bad_json');
  const pick = (k) => (Object.hasOwn(body, k) ? body[k] : base ? base[k] : undefined);
  const kind = pick('kind');
  if (!NOTICE_KINDS.includes(kind)) throw new HttpError(400, 'bad_kind');
  let value = pick('value');
  if (kind === 'h') {
    value = typeof value === 'string' ? value.toLowerCase() : value;
    if (typeof value !== 'string' || !DIGEST_RE.test(value)) throw new HttpError(400, 'bad_value');
  } else if (kind === 'id') {
    if (typeof value !== 'string' || value.length > APP_ID_MAX || !APP_ID_RE.test(value)) throw new HttpError(400, 'bad_value');
  } else {
    value = null;
  }
  const platform = pick('platform') ?? null;
  if (platform !== null && !PING_PLATFORMS.includes(platform)) throw new HttpError(400, 'bad_platform');
  const level = pick('level');
  if (!NOTICE_LEVELS.includes(level)) throw new HttpError(400, 'bad_level');
  const L = NOTICE_LIMITS;
  const row = {
    kind,
    value,
    platform,
    level,
    title_zh: optText(pick('title_zh'), L.titleMax, 'bad_title_zh'),
    body_zh: optText(pick('body_zh'), L.bodyMax, 'bad_body_zh'),
    title_en: optText(pick('title_en'), L.titleMax, 'bad_title_en'),
    body_en: optText(pick('body_en'), L.bodyMax, 'bad_body_en'),
    url: optText(pick('url'), L.urlMax, 'bad_url'),
    enabled: pick('enabled'),
  };
  if (row.url !== null && !/^https:\/\/[^\s]+$/.test(row.url)) throw new HttpError(400, 'bad_url');
  if (!row.title_zh && !row.body_zh && !row.title_en && !row.body_en) throw new HttpError(400, 'empty_text');
  if (row.enabled === undefined || row.enabled === null) row.enabled = 1;
  else if (row.enabled === true || row.enabled === 1) row.enabled = 1;
  else if (row.enabled === false || row.enabled === 0) row.enabled = 0;
  else throw new HttpError(400, 'bad_enabled');
  return row;
}

const RULE_COLUMNS = ['kind', 'value', 'platform', 'level', 'title_zh', 'body_zh', 'title_en', 'body_en', 'url', 'enabled'];

async function ruleById(env, id) {
  const row = await env.DB.prepare('SELECT * FROM notice_rules WHERE id = ?1').bind(id).first();
  if (!row) throw new HttpError(404, 'not_found');
  return row;
}

export async function listRules(env) {
  return (await env.DB.prepare('SELECT * FROM notice_rules ORDER BY enabled DESC, id').all()).results;
}

export async function listKnown(env) {
  return (await env.DB.prepare('SELECT h, label, created_at FROM notice_known_h ORDER BY created_at DESC, h').all()).results;
}

/** 近 days 天按构建信息（跨日合计）汇总的计数，n 降序。 */
export async function seenSummary(env, now, days = NOTICE_LIMITS.seenDays, limit = NOTICE_LIMITS.seenLimit) {
  const since = utcDateKey(now - (days - 1) * DAY_MS);
  return (await env.DB.prepare(
    `SELECT s.id, s.h, s.hk_disjoint AS hkDisjoint, s.v, s.p, s.country,
            SUM(s.n) AS n, MIN(s.day) AS firstDay, MAX(s.day) AS lastDay,
            (SELECT label FROM notice_known_h k WHERE k.h = s.h) AS label
     FROM notice_seen s WHERE s.day >= ?1
     GROUP BY s.id, s.h, s.hk_disjoint, s.v, s.p, s.country
     ORDER BY n DESC, lastDay DESC LIMIT ?2`,
  ).bind(since, limit).all()).results;
}

/** /admin/api/notices/** 分派（调用方已过 Basic Auth）。 */
export async function handleNoticesAdmin(env, request, path, body, now) {
  const method = request.method;
  let r;
  if (method === 'GET' && path === '/admin/api/notices/rules') return json({ rows: await listRules(env) });
  if (method === 'GET' && path === '/admin/api/notices/known') return json({ rows: await listKnown(env) });
  if (method === 'GET' && path === '/admin/api/notices/seen') {
    const url = new URL(request.url);
    const days = clampInt(url.searchParams.get('days'), 1, NOTICE_LIMITS.seenDaysMax, NOTICE_LIMITS.seenDays);
    const limit = clampInt(url.searchParams.get('limit'), 1, NOTICE_LIMITS.seenLimitMax, NOTICE_LIMITS.seenLimit);
    return json({ days, rows: await seenSummary(env, now, days, limit) });
  }
  if (method !== 'POST') throw new HttpError(405, 'method');
  if (path === '/admin/api/notices/rules') {
    const row = normalizeRule(body);
    const res = await env.DB.prepare(
      `INSERT INTO notice_rules (${RULE_COLUMNS.join(', ')}, created_at)
       VALUES (${RULE_COLUMNS.map((_, i) => `?${i + 1}`).join(', ')}, ?${RULE_COLUMNS.length + 1}) RETURNING id`,
    ).bind(...RULE_COLUMNS.map((c) => row[c]), now).first();
    return json({ ok: true, id: res.id }, 201);
  }
  if ((r = /^\/admin\/api\/notices\/rules\/(\d+)$/.exec(path))) {
    const id = Number(r[1]);
    const row = normalizeRule(body, await ruleById(env, id));
    await env.DB.prepare(
      `UPDATE notice_rules SET ${RULE_COLUMNS.map((c, i) => `${c} = ?${i + 2}`).join(', ')} WHERE id = ?1`,
    ).bind(id, ...RULE_COLUMNS.map((c) => row[c])).run();
    return json({ ok: true });
  }
  if ((r = /^\/admin\/api\/notices\/rules\/(\d+)\/disable$/.exec(path))) {
    const res = await env.DB.prepare('UPDATE notice_rules SET enabled = 0 WHERE id = ?1').bind(Number(r[1])).run();
    if (res.meta.changes !== 1) throw new HttpError(404, 'not_found');
    return json({ ok: true });
  }
  if ((r = /^\/admin\/api\/notices\/rules\/(\d+)\/delete$/.exec(path))) {
    const res = await env.DB.prepare('DELETE FROM notice_rules WHERE id = ?1').bind(Number(r[1])).run();
    if (res.meta.changes !== 1) throw new HttpError(404, 'not_found');
    return json({ ok: true });
  }
  if (path === '/admin/api/notices/known') {
    const h = typeof body?.h === 'string' ? body.h.toLowerCase() : '';
    if (!DIGEST_RE.test(h)) throw new HttpError(400, 'bad_h');
    const label = optText(body.label, NOTICE_LIMITS.labelMax, 'bad_label');
    await env.DB.prepare(
      `INSERT INTO notice_known_h (h, label, created_at) VALUES (?1, ?2, ?3)
       ON CONFLICT (h) DO UPDATE SET label = ?2`,
    ).bind(h, label, now).run();
    return json({ ok: true });
  }
  if ((r = /^\/admin\/api\/notices\/known\/([0-9a-fA-F]{64})\/remove$/.exec(path))) {
    const res = await env.DB.prepare('DELETE FROM notice_known_h WHERE h = ?1').bind(r[1].toLowerCase()).run();
    if (res.meta.changes !== 1) throw new HttpError(404, 'not_found');
    return json({ ok: true });
  }
  throw new HttpError(404, 'not_found');
}
