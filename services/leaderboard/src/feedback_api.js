// 反馈密钥与给 AI 代理用的反馈 JSON API（迁移 0026）。
//
// 开发者与反馈协查（triage）在处理台 /dev/keys 给自己签发反馈密钥，代理带 `Authorization: Bearer ffk_…`
// 调下面的接口，不用复制网页会话 Cookie。权限与 triage 的网页处理台一致、且对开发者的密钥同样只给这些：
// 只读反馈 + 写内部批改；回复反馈人、改状态（反馈人可见、会推送）一律不开放。账户被撤成 user 后密钥失效，
// 也可在 /dev/keys 单把吊销。拍板台密钥（fdk_）与反馈密钥互不通用。
//
//   GET  /v1/agent/feedback?status=&q=&cursor=&limit=   列表（与 /dev/feedback.json 同一份 devList；status 缺省 = 未结案，all = 全部）
//   GET  /v1/agent/feedback/:id                         详情（与 /dev/f/:id.json 同一份 devView）
//   GET  /v1/agent/feedback/:id/a/:slot                 附件 log | s0..s2 | v0 | f0..f2（?view=text 文本查看，?download=1 下载；视频支持 Range）
//   POST /v1/agent/feedback/:id/note  {devNote, base}   改内部批改。base = 改之前读到的 devNote（没有就是 null）：
//                                                       批改在这期间被别人改过 → 409 note_changed，不覆盖（批改是整段替换，
//                                                       代理不先读就写会冲掉别人的批改）。devNote 空串 = 清除。
//
// 鉴权只认请求头，不读 Cookie，所以没有 CSRF 面；限流在 worker.js 按 IP 过 READ_LIMITER。

import { HttpError, json, parseJsonBytes, readBodyBytes } from './util.js';
import { API_KEY_LIMITS, apiKeyAccount, createApiKey, listApiKeys, revokeApiKey } from './api_keys.js';
import { cleanKeyLabel } from './decisions_api.js';
import {
  FEEDBACK_LIMITS, attachmentResponse, canViewFeedback, cleanDevNoteText, devList, devView, feedbackById,
} from './feedback.js';

export const FEEDBACK_KEY_PREFIX = 'ffk_';
export const FEEDBACK_KEY_RE = /^ffk_[A-Za-z0-9_-]{43}$/;
export const FEEDBACK_KEY_LIMITS = API_KEY_LIMITS;
export const FEEDBACK_API_PREFIX = '/v1/agent/feedback';

/** 反馈密钥：开发者与 triage 都能签，只能读反馈、写内部批改。 */
export const FEEDBACK_KEY_KIND = Object.freeze({
  table: 'feedback_api_keys',
  prefix: FEEDBACK_KEY_PREFIX,
  re: FEEDBACK_KEY_RE,
  roleOk: canViewFeedback,
  missingCode: 'feedback_key_required',
  badCode: 'bad_feedback_key',
});

/** 批改请求体上限：devNote 最长 devNoteMax 字（UTF-8 最坏 4 字节 / 字）+ 同样长的 base。 */
const NOTE_BODY_MAX = FEEDBACK_LIMITS.devNoteMax * 4 * 2 + 1024;

/**
 * @param {object} env
 * @param {string} accountId
 */
export function listFeedbackKeys(env, accountId) {
  return listApiKeys(env, FEEDBACK_KEY_KIND, accountId);
}

/**
 * @param {object} env
 * @param {{id: string}} account
 * @param {string} label
 * @param {number} now
 * @returns {Promise<{id: string, token: string}>}
 */
export function createFeedbackKey(env, account, label, now) {
  return createApiKey(env, FEEDBACK_KEY_KIND, account, cleanKeyLabel(label), now);
}

/**
 * @param {object} env
 * @param {{id: string}} account
 * @param {string} keyId
 * @param {number} now
 */
export function revokeFeedbackKey(env, account, keyId, now) {
  return revokeApiKey(env, FEEDBACK_KEY_KIND, account, keyId, now);
}

/**
 * @param {string} path
 * @returns {boolean}
 */
export function isFeedbackApiPath(path) {
  return path === FEEDBACK_API_PREFIX || path.startsWith(`${FEEDBACK_API_PREFIX}/`);
}

/** 只在批改仍是读到的那一份时才写（dev_note IS ?4：两边都可为 NULL）。 */
const SAVE_NOTE_IF_UNCHANGED_SQL = `UPDATE feedback SET dev_note = ?2, dev_note_at = ?3
  WHERE id = ?1 AND dev_note IS ?4`;

/**
 * 按乐观锁改内部批改。base 与库里不一致（期间被别人改过）→ 409 note_changed。
 * @param {object} env
 * @param {{id: string, dev_note: string|null}} row
 * @param {unknown} devNote
 * @param {unknown} base
 * @param {number} now
 * @returns {Promise<{devNote: string|null}>}
 */
export async function saveNoteIfUnchanged(env, row, devNote, base, now) {
  if (typeof devNote !== 'string') throw new HttpError(400, 'invalid', 'devNote 必须是字符串（空串 = 清除）');
  if (base === undefined) throw new HttpError(400, 'base_required', 'base 必须给改之前读到的 devNote（没有批改时为 null）');
  if (base !== null && typeof base !== 'string') throw new HttpError(400, 'invalid', 'base 必须是字符串或 null');
  let text;
  try {
    text = cleanDevNoteText('dev_note', devNote);
  } catch (e) {
    throw new HttpError(400, 'invalid', e.message);
  }
  // 读到的批改本就是清洗过的库内原文；空串与 null 都表示「之前没有批改」。
  const expected = base === '' ? null : base;
  const r = await env.DB.prepare(SAVE_NOTE_IF_UNCHANGED_SQL)
    .bind(row.id, text, text ? now : null, expected).run();
  if (!r.meta || r.meta.changes !== 1) throw new HttpError(409, 'note_changed');
  return { devNote: text };
}

/**
 * @param {Request} request
 * @param {number} max
 * @returns {Promise<Record<string, unknown>>}
 */
async function readJson(request, max) {
  const bytes = await readBodyBytes(request, max);
  const body = bytes.length ? parseJsonBytes(bytes) : {};
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw new HttpError(400, 'bad_json');
  return body;
}

/**
 * /v1/agent/feedback/** 的路由。worker.js 已过限流。
 * @param {Request} request
 * @param {object} env
 * @param {URL} url
 * @param {number} now
 * @returns {Promise<Response>}
 */
export async function routeFeedbackApi(request, env, url, now) {
  await apiKeyAccount(env, FEEDBACK_KEY_KIND, request, now);
  const path = url.pathname;
  const method = request.method;
  const noStore = { 'Cache-Control': 'private, no-store' };
  let m;

  if (path === FEEDBACK_API_PREFIX) {
    if (method !== 'GET') throw new HttpError(405, 'method_not_allowed');
    const status = url.searchParams.get('status') || 'active';
    return json(await devList(env, {
      status: status === 'all' ? null : status,
      cursor: url.searchParams.get('cursor'),
      limit: url.searchParams.get('limit') || 50,
      q: (url.searchParams.get('q') || '').trim(),
    }), 200, noStore);
  }
  const rest = path.slice(FEEDBACK_API_PREFIX.length + 1);
  if ((m = /^([A-Za-z0-9_-]{8,16})$/.exec(rest))) {
    if (method !== 'GET') throw new HttpError(405, 'method_not_allowed');
    return json(await devView(env, await feedbackById(env, m[1])), 200, noStore);
  }
  if ((m = /^([A-Za-z0-9_-]{8,16})\/a\/(log|s[0-2]|v0|f[0-2])$/.exec(rest))) {
    if (method !== 'GET') throw new HttpError(405, 'method_not_allowed');
    return attachmentResponse(env, await feedbackById(env, m[1]), m[2], url.searchParams.get('view') === 'text', {
      range: request.headers.get('Range'),
      download: url.searchParams.get('download') === '1',
    });
  }
  if ((m = /^([A-Za-z0-9_-]{8,16})\/note$/.exec(rest))) {
    if (method !== 'POST') throw new HttpError(405, 'method_not_allowed');
    const body = await readJson(request, NOTE_BODY_MAX);
    const row = await feedbackById(env, m[1]);
    return json({ ok: true, ...(await saveNoteIfUnchanged(env, row, body.devNote, body.base, now)) }, 200, noStore);
  }
  throw new HttpError(404, 'not_found');
}
