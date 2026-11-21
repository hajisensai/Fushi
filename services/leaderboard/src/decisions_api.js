// 拍板台 JSON API + 开发者个人密钥（迁移 0024）。
//
// 让没有 Cloudflare 凭据的开发者（及其本机代理）也能用 scripts/decisions.mjs：开发者在处理台 /dev/keys
// 给自己签发密钥，代理带 `Authorization: Bearer fdk_…` 调下面的接口。密钥只能读写拍板台，
// 拿不到反馈、账户等其余数据；账户被撤开发者后密钥随之失效，也可在 /dev/keys 单把吊销。
//
//   GET    /v1/decisions                          全部事项（最近 listMax 条，含留言与 stage）
//   GET    /v1/decisions/:id                      单条
//   POST   /v1/decisions          {items:[…]}     写入待拍事项（同 id 已存在的跳过、不覆盖）→ {inserted, skipped}
//   POST   /v1/decisions/:id/notes   {text}       以 Claude 身份留言（记下签发密钥的开发者）
//   POST   /v1/decisions/:id/close   {state: done|dropped, text}  结单 / 撤回
//   POST   /v1/decisions/:id/verdict {v}          按开发者留言校正决定（do|skip|…|choice:<key>；与 CLI 一样记为无署名）
//   POST   /v1/decisions/:id/files?name=<文件名>   请求体 = 文件原始字节，附一个附件（≤ 10 MB，每条 ≤ 10 个）
//   GET    /v1/decisions/:id/files/:n             取第 n 个附件
//   DELETE /v1/decisions/:id/files/:n             删第 n 个附件（R2 对象一并删）
//
// SQL 与校验全部复用 decisions.js（与网页、wrangler 模式的 CLI 同一份）。
// 鉴权只认请求头，不读 Cookie，所以没有 CSRF 面；限流在 worker.js 按 IP 过 READ_LIMITER。

import { HttpError, b64urlEncode, hex, json, parseJsonBytes, randomId, readBodyBytes, sha256 } from './util.js';
import {
  ADD_NOTE_SQL, CLOSE_DECISION_SQL, DECISION_ID_RE, DECISION_LIMITS, DECISION_VERDICTS, INSERT_DECISION_SQL, SET_VERDICT_SQL,
  cleanDecisionText, decisionFileResponse, decisionFileType, decisionStage, getDecision, insertDecisionArgs, listDecisions,
  normalizeDecision, parseChoices, parseDecisionFiles,
} from './decisions.js';

export const DECISION_KEY_PREFIX = 'fdk_';
export const DECISION_KEY_RE = /^fdk_[A-Za-z0-9_-]{43}$/;
export const DECISION_KEY_LIMITS = { activePerAccount: 5, labelMax: 60, touchEveryMs: 10 * 60 * 1000 };

/** 写入事项的请求体上限：每条最长约 2 万字（UTF-8 最坏 3 字节 / 字），一批 20 条够用。 */
const ADD_BODY_MAX = 1024 * 1024;
const SMALL_BODY_MAX = 64 * 1024;

/**
 * @param {string} token
 * @returns {Promise<string>}
 */
async function keyHash(token) {
  return hex(await sha256(new TextEncoder().encode(token)));
}

/**
 * 本账户的全部密钥（含已吊销），新的在前。不含哈希。
 * @param {object} env
 * @param {string} accountId
 * @returns {Promise<Array<{id: string, hint: string, label: string|null, created_at: number, last_used_at: number|null, revoked_at: number|null}>>}
 */
export async function listDecisionKeys(env, accountId) {
  const r = await env.DB.prepare(`SELECT id, hint, label, created_at, last_used_at, revoked_at FROM decision_api_keys
    WHERE account_id = ?1 ORDER BY created_at DESC, id`).bind(accountId).all();
  return r.results || [];
}

/**
 * 签发一把新密钥；明文只在返回值里出现这一次。每个账户最多 activePerAccount 把未吊销的。
 * @param {object} env
 * @param {{id: string}} dev
 * @param {string} label
 * @param {number} now
 * @returns {Promise<{id: string, token: string}>}
 */
export async function createDecisionKey(env, dev, label, now) {
  let name;
  try {
    name = cleanDecisionText(label, DECISION_KEY_LIMITS.labelMax, '备注');
  } catch {
    throw new HttpError(400, 'bad_label');
  }
  if (name && name.includes('\n')) throw new HttpError(400, 'bad_label');
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  const token = DECISION_KEY_PREFIX + b64urlEncode(bytes);
  const id = randomId(10);
  // 名额检查与插入在同一条语句里：并发签发也不会超过上限。
  const r = await env.DB.prepare(`INSERT INTO decision_api_keys (id, account_id, token_hash, hint, label, created_at)
    SELECT ?1, ?2, ?3, ?4, ?5, ?6
    WHERE (SELECT COUNT(*) FROM decision_api_keys WHERE account_id = ?2 AND revoked_at IS NULL) < ?7`)
    .bind(id, dev.id, await keyHash(token), token.slice(-4), name, now, DECISION_KEY_LIMITS.activePerAccount).run();
  if (!r.meta || r.meta.changes !== 1) throw new HttpError(409, 'too_many_keys');
  return { id, token };
}

/**
 * 吊销本人的一把密钥（别人的或不存在的 → 404；已吊销的幂等）。
 * @param {object} env
 * @param {{id: string}} dev
 * @param {string} keyId
 * @param {number} now
 */
export async function revokeDecisionKey(env, dev, keyId, now) {
  const row = await env.DB.prepare('SELECT revoked_at FROM decision_api_keys WHERE id = ?1 AND account_id = ?2')
    .bind(keyId, dev.id).first();
  if (!row) throw new HttpError(404, 'not_found');
  if (row.revoked_at) return;
  await env.DB.prepare('UPDATE decision_api_keys SET revoked_at = ?3 WHERE id = ?1 AND account_id = ?2 AND revoked_at IS NULL')
    .bind(keyId, dev.id, now).run();
}

/**
 * Bearer 密钥 → 开发者账户。缺 / 格式不对 → 401 decision_key_required；
 * 不存在、已吊销、账户已不是开发者 → 401 bad_decision_key（不区分，免得探测）。
 * last_used_at 最多每 touchEveryMs 写一次。
 * @param {object} env
 * @param {Request} request
 * @param {number} now
 * @returns {Promise<{id: string, nickname: string, key_id: string}>}
 */
export async function decisionKeyAccount(env, request, now) {
  const m = /^Bearer\s+(\S+)$/.exec(request.headers.get('Authorization') || '');
  if (!m || !DECISION_KEY_RE.test(m[1])) throw new HttpError(401, 'decision_key_required');
  const row = await env.DB.prepare(`SELECT k.id AS key_id, k.last_used_at AS key_used_at, a.id, a.nickname, a.role
    FROM decision_api_keys k JOIN accounts a ON a.id = k.account_id
    WHERE k.token_hash = ?1 AND k.revoked_at IS NULL`).bind(await keyHash(m[1])).first();
  if (!row || row.role !== 'dev') throw new HttpError(401, 'bad_decision_key');
  if (!row.key_used_at || now - row.key_used_at >= DECISION_KEY_LIMITS.touchEveryMs) {
    await env.DB.prepare('UPDATE decision_api_keys SET last_used_at = ?2 WHERE id = ?1').bind(row.key_id, now).run();
  }
  return { id: row.id, nickname: row.nickname, key_id: row.key_id };
}

export function isDecisionsApiPath(path) {
  return path === '/v1/decisions' || path.startsWith('/v1/decisions/');
}

function withStage(row) {
  return { ...row, stage: decisionStage(row) };
}

async function readJson(request, max) {
  const bytes = await readBodyBytes(request, max);
  const body = bytes.length ? parseJsonBytes(bytes) : {};
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw new HttpError(400, 'bad_json');
  return body;
}

/** 校验失败（normalizeDecision / cleanDecisionText 抛的 Error）→ 400，带原因。 */
function invalid(fn) {
  try {
    return fn();
  } catch (e) {
    if (e instanceof HttpError) throw e;
    throw new HttpError(400, 'invalid', e.message);
  }
}

async function existing(env, id) {
  if (!DECISION_ID_RE.test(id)) throw new HttpError(404, 'not_found');
  const row = await env.DB.prepare('SELECT id, state, choices, files FROM decisions WHERE id = ?1').bind(id).first();
  if (!row) throw new HttpError(404, 'not_found');
  return row;
}

/**
 * 写入一批事项。先全部校验，任一不合法整批不写。迁移字段（verdict / notes）只给 wrangler 模式的 CLI 用，这里拒收，
 * 免得静默丢掉。
 * @returns {Promise<{inserted: string[], skipped: string[]}>}
 */
export async function addDecisions(env, list, now) {
  if (!Array.isArray(list) || !list.length) throw new HttpError(400, 'invalid', 'items 必须是非空数组');
  const rows = invalid(() => {
    const seen = new Set();
    return list.map((raw) => {
      if (raw && typeof raw === 'object' && (raw.verdict !== undefined || raw.notes !== undefined)) {
        throw new Error('verdict / notes 是迁移字段，只能用 wrangler 模式写入');
      }
      const d = normalizeDecision(raw);
      if (seen.has(d.id)) throw new Error(`本批 id 重复：${d.id}`);
      seen.add(d.id);
      return d;
    });
  });
  const res = await env.DB.batch(rows.map((d) => env.DB.prepare(INSERT_DECISION_SQL).bind(...insertDecisionArgs(d, now))));
  const inserted = [];
  const skipped = [];
  rows.forEach((d, i) => ((res[i] && res[i].meta && res[i].meta.changes === 1) ? inserted : skipped).push(d.id));
  return { inserted, skipped };
}

/**
 * @param {string} v do|skip|…|choice:<key>
 * @param {string|null} choicesRaw
 * @returns {{verdict: string, choice: string|null}}
 */
function parseVerdict(v, choicesRaw) {
  let verdict = typeof v === 'string' ? v : '';
  let choice = null;
  if (verdict.startsWith('choice:')) {
    choice = verdict.slice(7);
    verdict = 'choice';
    if (!parseChoices(choicesRaw).some((c) => c.key === choice)) throw new HttpError(400, 'bad_choice');
  } else if (!(verdict in DECISION_VERDICTS) || verdict === 'choice') {
    throw new HttpError(400, 'bad_verdict');
  }
  return { verdict, choice };
}

function nonce() {
  return [...crypto.getRandomValues(new Uint8Array(4))].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** 追加一个代理附件（不带 by，卡片上不标「开发者上传」）。与网页上传同样只收进行中的事项。 */
const APPEND_AGENT_FILE_SQL = `UPDATE decisions SET files = json_insert(COALESCE(files, '[]'), '$[#]', json(?2)), updated_at = ?3
  WHERE id = ?1 AND state = 'open' AND json_array_length(COALESCE(files, '[]')) < ?4`;

/** 删附件的乐观锁：files 列仍是读到的那一份才写，并发改动 → 409。 */
const REPLACE_FILES_SQL = 'UPDATE decisions SET files = ?2, updated_at = ?3 WHERE id = ?1 AND files = ?4';

/**
 * /v1/decisions/** 的路由。worker.js 已过限流。
 * @param {Request} request
 * @param {object} env
 * @param {URL} url
 * @param {number} now
 * @returns {Promise<Response>}
 */
export async function routeDecisionsApi(request, env, url, now) {
  const dev = await decisionKeyAccount(env, request, now);
  const path = url.pathname;
  const method = request.method;
  const noStore = { 'Cache-Control': 'private, no-store' };
  let m;

  if (path === '/v1/decisions') {
    if (method === 'GET') return json({ items: (await listDecisions(env)).map(withStage) }, 200, noStore);
    if (method === 'POST') {
      const body = await readJson(request, ADD_BODY_MAX);
      return json(await addDecisions(env, body.items, now), 200, noStore);
    }
    throw new HttpError(405, 'method_not_allowed');
  }
  if ((m = /^\/v1\/decisions\/([A-Za-z0-9_-]{1,40})$/.exec(path)) && method === 'GET') {
    return json({ item: withStage(await getDecision(env, m[1])) }, 200, noStore);
  }
  if ((m = /^\/v1\/decisions\/([A-Za-z0-9_-]{1,40})\/notes$/.exec(path)) && method === 'POST') {
    const body = await readJson(request, SMALL_BODY_MAX);
    const text = invalid(() => cleanDecisionText(body.text));
    if (!text) throw new HttpError(400, 'invalid', '留言不能为空');
    await existing(env, m[1]);
    await env.DB.prepare(ADD_NOTE_SQL).bind(m[1], 'claude', dev.id, text, now).run();
    return json({ ok: true }, 200, noStore);
  }
  if ((m = /^\/v1\/decisions\/([A-Za-z0-9_-]{1,40})\/close$/.exec(path)) && method === 'POST') {
    const body = await readJson(request, SMALL_BODY_MAX);
    if (body.state !== 'done' && body.state !== 'dropped') throw new HttpError(400, 'bad_state');
    const text = invalid(() => cleanDecisionText(body.text, DECISION_LIMITS.resolutionMax, '处理结果'));
    if (!text) throw new HttpError(400, 'invalid', '结单要写处理结果');
    await existing(env, m[1]);
    await env.DB.prepare(CLOSE_DECISION_SQL).bind(m[1], body.state, text, now).run();
    return json({ ok: true }, 200, noStore);
  }
  if ((m = /^\/v1\/decisions\/([A-Za-z0-9_-]{1,40})\/verdict$/.exec(path)) && method === 'POST') {
    const body = await readJson(request, SMALL_BODY_MAX);
    const row = await existing(env, m[1]);
    if (row.state !== 'open') throw new HttpError(409, 'decision_closed');
    const { verdict, choice } = parseVerdict(body.v, row.choices);
    await env.DB.prepare(SET_VERDICT_SQL).bind(m[1], verdict, choice, null, now, now).run();
    return json({ ok: true }, 200, noStore);
  }
  if ((m = /^\/v1\/decisions\/([A-Za-z0-9_-]{1,40})\/files$/.exec(path)) && method === 'POST') {
    const name = url.searchParams.get('name') || '';
    const type = decisionFileType(name);
    if (!type || name.includes('/') || name.includes('\\')) throw new HttpError(400, 'bad_file_type');
    if (name.length > DECISION_LIMITS.fileNameMax) throw new HttpError(400, 'bad_file_name');
    const row = await existing(env, m[1]);
    if (row.state !== 'open') throw new HttpError(409, 'decision_closed');
    if (parseDecisionFiles(row.files, m[1]).length >= DECISION_LIMITS.filesMax) throw new HttpError(400, 'too_many_files');
    const bytes = await readBodyBytes(request, DECISION_LIMITS.fileMax);
    if (!bytes.length) throw new HttpError(400, 'no_file');
    const key = `decisions/${m[1]}/${nonce()}-${name.replace(/[^A-Za-z0-9._-]+/g, '_')}`;
    await env.MEDIA.put(key, bytes, { httpMetadata: { contentType: type.type } });
    const entry = { name, type: type.type, key, bytes: bytes.length };
    const r = await env.DB.prepare(APPEND_AGENT_FILE_SQL).bind(m[1], JSON.stringify(entry), now, DECISION_LIMITS.filesMax).run();
    if (!r.meta || r.meta.changes !== 1) {
      await env.MEDIA.delete(key);
      throw new HttpError(409, 'files_changed');
    }
    return json({ ok: true, file: entry }, 200, noStore);
  }
  if ((m = /^\/v1\/decisions\/([A-Za-z0-9_-]{1,40})\/files\/(\d{1,2})$/.exec(path))) {
    if (method === 'GET') return decisionFileResponse(env, m[1], Number(m[2]));
    if (method === 'DELETE') {
      const row = await existing(env, m[1]);
      const list = parseDecisionFiles(row.files, m[1]);
      const n = Number(m[2]);
      if (!list[n]) throw new HttpError(404, 'not_found');
      const [gone] = list.splice(n, 1);
      const r = await env.DB.prepare(REPLACE_FILES_SQL).bind(m[1], JSON.stringify(list), now, row.files).run();
      if (!r.meta || r.meta.changes !== 1) throw new HttpError(409, 'files_changed');
      await env.MEDIA.delete(gone.key);
      return json({ ok: true, removed: gone.name }, 200, noStore);
    }
  }
  throw new HttpError(404, 'not_found');
}
