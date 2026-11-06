// AI 额度消耗：上传端把本机 Claude Code 日志按「UTC 日 × 模型」汇总后推上来，/usage 页公开展示。
// 表结构与取舍见 migrations/0019_ai_usage.sql。
//
//   POST /v1/ci/usage   [Bearer USAGE_UPLOAD_TOKEN]  {source, rows: [{day, model, requests, input, output, cacheRead, cacheWrite}]}
//
// 没配 USAGE_UPLOAD_TOKEN 时整个接口当不存在（404）；token 不对 401。只存汇总计数。

import { HttpError, timingSafeEqual, utcDateKey } from './util.js';
import { spend } from './budget.js';

export const USAGE_LIMITS = {
  maxRows: 400,
  maxBodyBytes: 128 * 1024,
  /** 接受的最早日期距今天数 / 允许的最晚日期（时区差留一天）。 */
  maxAgeDays: 400,
  /** 单个计数上限，挡住明显的溢出 / 乱填值。 */
  maxCount: 1e13,
  /** 页面展示的天数。 */
  pageDays: 30,
};

const DAY_MS = 86400 * 1000;
const SOURCE_RE = /^[a-z0-9_-]{1,32}$/;
// 模型名形态：直连 `claude-opus-5-5`、Vertex `claude-…@20251101`、Bedrock `us.anthropic.claude-…:0` / ARN `arn:aws:bedrock:…/…`。
// 与 tool/claude_usage_upload.mjs 的 MODEL_RE 保持一致：客户端先按它丢弃不合规行，单行坏数据不会让整批 400。
export const MODEL_RE = /^[A-Za-z0-9._:@/-]{1,128}$/;
const DAY_RE = /^\d{4}-\d{2}-\d{2}$/;

/**
 * 估算额度权重：按 Anthropic 缓存计价比例折成「输入 token 当量」
 * （输出 5×、缓存写 1.25×、缓存读 0.1×）。只是相对大小，不是真实额度。
 * @param {{input: number, output: number, cacheRead: number, cacheWrite: number}} u
 * @returns {number}
 */
export function weightedCost(u) {
  return u.input + u.output * 5 + u.cacheWrite * 1.25 + u.cacheRead * 0.1;
}

/** Bearer 鉴权：没配 token 当不存在（404）；token 不对 401。 */
function requireUploadToken(request, env) {
  const token = typeof env.USAGE_UPLOAD_TOKEN === 'string' ? env.USAGE_UPLOAD_TOKEN : '';
  if (!token) throw new HttpError(404, 'not_found');
  const auth = request.headers.get('Authorization') || '';
  const given = auth.startsWith('Bearer ') ? auth.slice(7).trim() : '';
  if (!given || !timingSafeEqual(given, token)) throw new HttpError(401, 'unauthorized');
}

function count(v, what) {
  if (!Number.isInteger(v) || v < 0 || v > USAGE_LIMITS.maxCount) throw new HttpError(400, 'bad_usage', what);
  return v;
}

/**
 * 校验并规整上传体。
 * @param {unknown} body
 * @param {number} now
 * @returns {{source: string, rows: Array<{day: string, model: string, requests: number, input: number, output: number, cacheRead: number, cacheWrite: number}>}}
 */
export function normalizeUsage(body, now) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw new HttpError(400, 'bad_usage');
  const { source, rows } = /** @type {any} */ (body);
  if (typeof source !== 'string' || !SOURCE_RE.test(source)) throw new HttpError(400, 'bad_usage', 'source');
  if (!Array.isArray(rows) || rows.length === 0 || rows.length > USAGE_LIMITS.maxRows) {
    throw new HttpError(400, 'bad_usage', 'rows');
  }
  const oldest = utcDateKey(now - USAGE_LIMITS.maxAgeDays * DAY_MS);
  const newest = utcDateKey(now + DAY_MS);
  const seen = new Set();
  const out = rows.map((r) => {
    if (!r || typeof r !== 'object') throw new HttpError(400, 'bad_usage', 'row');
    if (typeof r.day !== 'string' || !DAY_RE.test(r.day) || r.day < oldest || r.day > newest) {
      throw new HttpError(400, 'bad_usage', 'day');
    }
    if (typeof r.model !== 'string' || !MODEL_RE.test(r.model)) throw new HttpError(400, 'bad_usage', 'model');
    const key = `${r.day}|${r.model}`;
    if (seen.has(key)) throw new HttpError(400, 'bad_usage', 'duplicate');
    seen.add(key);
    return {
      day: r.day,
      model: r.model,
      requests: count(r.requests, 'requests'),
      input: count(r.input, 'input'),
      output: count(r.output, 'output'),
      cacheRead: count(r.cacheRead, 'cacheRead'),
      cacheWrite: count(r.cacheWrite, 'cacheWrite'),
    };
  });
  return { source, rows: out };
}

/**
 * 接收一批汇总（整行覆盖，重传幂等）。
 * @param {any} env
 * @param {Request} request
 * @param {unknown} body
 * @param {number} now
 * @returns {Promise<{accepted: number}>}
 */
export async function recordAiUsage(env, request, body, now) {
  requireUploadToken(request, env);
  const { source, rows } = normalizeUsage(body, now);
  await spend(env, 'write_rows', rows.length, now);
  const stmt = env.DB.prepare(
    `INSERT INTO ai_usage_daily (day, source, model, requests, input, output, cache_read, cache_write, updated_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
     ON CONFLICT (day, source, model) DO UPDATE SET
       requests = ?4, input = ?5, output = ?6, cache_read = ?7, cache_write = ?8, updated_at = ?9`,
  );
  await env.DB.batch(
    rows.map((r) => stmt.bind(r.day, source, r.model, r.requests, r.input, r.output, r.cacheRead, r.cacheWrite, now)),
  );
  return { accepted: rows.length };
}

/**
 * 最近 days 天的汇总（各机器合并），按日期升序。
 * @param {any} env
 * @param {number} now
 * @returns {Promise<{days: Array<{day: string, models: Record<string, {requests: number, input: number, output: number, cacheRead: number, cacheWrite: number}>}>, updatedAt: number | null}>}
 */
export async function loadAiUsage(env, now) {
  const since = utcDateKey(now - (USAGE_LIMITS.pageDays - 1) * DAY_MS);
  const res = await env.DB.prepare(
    `SELECT day, model, SUM(requests) AS requests, SUM(input) AS input, SUM(output) AS output,
            SUM(cache_read) AS cache_read, SUM(cache_write) AS cache_write, MAX(updated_at) AS updated_at
     FROM ai_usage_daily WHERE day >= ?1 GROUP BY day, model ORDER BY day`,
  ).bind(since).all();
  /** @type {Map<string, any>} */
  const byDay = new Map();
  let updatedAt = null;
  for (const r of res.results) {
    let d = byDay.get(r.day);
    if (!d) byDay.set(r.day, (d = { day: r.day, models: {} }));
    d.models[r.model] = {
      requests: r.requests,
      input: r.input,
      output: r.output,
      cacheRead: r.cache_read,
      cacheWrite: r.cache_write,
    };
    if (updatedAt === null || r.updated_at > updatedAt) updatedAt = r.updated_at;
  }
  return { days: [...byDay.values()], updatedAt };
}
