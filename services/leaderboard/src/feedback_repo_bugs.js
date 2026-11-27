// 仓库 BUG → 反馈同步（迁移 0028；CI 脚本 tool/bug_feedback_sync.mjs，workflow bug-feedback-sync.yml）。
//
// docs/bugs/BUG-NNNN*.md 里「① 未修复」的条目，由 develop 的 push CI 按 BUG 号幂等地对账成反馈，
// 开发者在处理台 / App 开发者视图里看得到，不用 agent 一条条手动 `fushi_cli feedback submit`。
// 对账（算差异）全在 CI 脚本里做，服务端只提供两个原子操作：
//
//   GET  /v1/ci/feedback/bugs   → {items:[{bug, id, hash, status}]}  已同步过的全部 BUG 行（按号升序）
//   POST /v1/ci/feedback/bugs   {sha?, upsert:[{bug, title, body, hash}], close:[{bug, reason}]}（合计 ≤ 25）
//                               → {created, updated, unchanged, closed, missing}（都是 BUG 号数组）
//     upsert：没有该号的行 → 新建（category bug、无反馈人、origin {"source":"repo_bug"}）；
//             有且 hash 不同 → 改标题 / 正文；若该行是「已解决」（BUG 文件曾标修复又被改回未修复 =
//             回归），同时拉回 open、清掉修复记录、时间线记一笔。hash 相同 → unchanged（幂等）。
//             wont_fix / duplicate / closed（开发者手动结案）只更新文字，状态不动。
//     close：reason 'fixed'   BUG 文件勾了 ①：走与 /v1/ci/feedback/fixed 同一份 MARK_FIXED_SQL，
//                            修复 commit 记本次 push 的 sha（scope app），发布回填照常跟进；
//            reason 'dropped' BUG 文件被删除 / 改号 / 标成 ❌ 未复现：open / in_progress → closed。
//            只动 open / in_progress 的行；已结案的进 unchanged，没同步过的号进 missing。
//   鉴权与其他 CI 接口相同（Bearer FEEDBACK_CI_TOKEN，feedback.js requireCi）。
//
// 不扣 feedback 日预算（那是给用户提交的 300 条/天），只扣 write_rows。

import { HttpError, randomId } from './util.js';
import { spend } from './budget.js';
import { FEEDBACK_LIMITS, MARK_FIXED_SQL, markFixedArgs, normalizeFixSha, ticketHash } from './feedback.js';

export const REPO_BUG_LIMITS = {
  /** 单次 POST 的 upsert + close 条数上限（正文最长 8000 字，25 条约 600 KB 以内）。 */
  itemsPerRequest: 25,
  /** POST 请求体上限。 */
  bodyMaxBytes: 1024 * 1024,
  bugMax: 9_999_999,
};

const HASH_RE = /^[0-9a-f]{64}$/;
const CLOSE_REASONS = ['fixed', 'dropped'];
export const REPO_BUG_ORIGIN = JSON.stringify({ source: 'repo_bug' });
export const REPO_BUG_REOPEN_NOTE = '仓库 BUG 文件又标回「未修复」，自动重新打开。';
export const REPO_BUG_DROP_NOTE = '仓库 BUG 文件已删除、改号或标为未复现，自动结案。';

function normalizeBug(v) {
  if (!Number.isInteger(v) || v < 1 || v > REPO_BUG_LIMITS.bugMax) throw new HttpError(400, 'bad_bug');
  return v;
}

function normalizeText(v, max, code) {
  if (typeof v !== 'string') throw new HttpError(400, code);
  const s = v.trim();
  if (s.length === 0 || s.length > max) throw new HttpError(400, code);
  return s;
}

/** 校验请求体：任一条不合法整批 400；同一个号在一次请求里只能出现一次。 */
export function normalizeRepoBugSync(body) {
  if (!body || typeof body !== 'object') throw new HttpError(400, 'bad_json');
  const upsertIn = body.upsert ?? [];
  const closeIn = body.close ?? [];
  if (!Array.isArray(upsertIn) || !Array.isArray(closeIn)) throw new HttpError(400, 'bad_items');
  const total = upsertIn.length + closeIn.length;
  if (total === 0) throw new HttpError(400, 'bad_items');
  if (total > REPO_BUG_LIMITS.itemsPerRequest) throw new HttpError(400, 'too_many_items');
  const seen = new Set();
  const once = (bug) => {
    if (seen.has(bug)) throw new HttpError(400, 'duplicate_bug');
    seen.add(bug);
    return bug;
  };
  const upsert = upsertIn.map((it) => {
    if (!it || typeof it !== 'object') throw new HttpError(400, 'bad_items');
    if (typeof it.hash !== 'string' || !HASH_RE.test(it.hash)) throw new HttpError(400, 'bad_hash');
    return {
      bug: once(normalizeBug(it.bug)),
      title: normalizeText(it.title, FEEDBACK_LIMITS.titleMax, 'bad_title'),
      body: normalizeText(it.body, FEEDBACK_LIMITS.bodyMax, 'bad_body'),
      hash: it.hash,
    };
  });
  const close = closeIn.map((it) => {
    if (!it || typeof it !== 'object' || !CLOSE_REASONS.includes(it.reason)) throw new HttpError(400, 'bad_reason');
    return { bug: once(normalizeBug(it.bug)), reason: it.reason };
  });
  const sha = close.some((c) => c.reason === 'fixed') ? normalizeFixSha(body.sha) : null;
  return { sha, upsert, close };
}

/** GET /v1/ci/feedback/bugs。 */
export async function ciRepoBugList(env) {
  const rows = await env.DB.prepare(
    'SELECT repo_bug, id, repo_bug_hash, status FROM feedback WHERE repo_bug IS NOT NULL ORDER BY repo_bug',
  ).all();
  return {
    items: rows.results.map((r) => ({ bug: r.repo_bug, id: r.id, hash: r.repo_bug_hash, status: r.status })),
  };
}

const REOPEN_SQL = `INSERT INTO feedback_messages (feedback_id, author, account_id, body, status, created_at)
  SELECT id, 'dev', NULL, ?2, 'open', ?3 FROM feedback
  WHERE repo_bug = ?1 AND status = 'resolved' AND repo_bug_hash IS NOT ?4`;

// DO UPDATE 里裸列名 / feedback.* 都是冲突前的旧行：CASE 按旧状态判是否回归。
const WAS_RESOLVED = "feedback.status = 'resolved'";
const UPSERT_SQL = `INSERT INTO feedback (id, ticket_hash, account_id, category, title, body, contact, meta,
    created_at, updated_at, flags, content_hash, origin, repo_bug, repo_bug_hash)
  VALUES (?1, ?2, NULL, 'bug', ?3, ?4, '', '{}', ?5, ?5, '[]', NULL, ?6, ?7, ?8)
  ON CONFLICT (repo_bug) WHERE repo_bug IS NOT NULL DO UPDATE SET
    title = excluded.title,
    body = excluded.body,
    repo_bug_hash = excluded.repo_bug_hash,
    updated_at = excluded.updated_at,
    status = CASE WHEN ${WAS_RESOLVED} THEN 'open' ELSE feedback.status END,
    dev_reply_at = CASE WHEN ${WAS_RESOLVED} THEN excluded.updated_at ELSE feedback.dev_reply_at END,
    fix_sha = CASE WHEN ${WAS_RESOLVED} THEN NULL ELSE feedback.fix_sha END,
    fix_scope = CASE WHEN ${WAS_RESOLVED} THEN NULL ELSE feedback.fix_scope END,
    fix_at = CASE WHEN ${WAS_RESOLVED} THEN NULL ELSE feedback.fix_at END,
    fixed_in = CASE WHEN ${WAS_RESOLVED} THEN '{}' ELSE feedback.fixed_in END
  WHERE feedback.repo_bug_hash IS NOT excluded.repo_bug_hash`;

const ACTIVE = "status IN ('open', 'in_progress')";
const DROP_SQL = [
  `INSERT INTO feedback_messages (feedback_id, author, account_id, body, status, created_at)
   SELECT id, 'dev', NULL, ?2, 'closed', ?3 FROM feedback WHERE repo_bug = ?1 AND ${ACTIVE}`,
  `UPDATE feedback SET status = 'closed', dev_reply_at = ?3, updated_at = ?3 WHERE repo_bug = ?1 AND ${ACTIVE}`,
];

/** POST /v1/ci/feedback/bugs。 */
export async function ciRepoBugSync(env, body, now) {
  const req = normalizeRepoBugSync(body);
  const t = Math.trunc(now);
  const bugs = [...req.upsert.map((u) => u.bug), ...req.close.map((c) => c.bug)];
  const existing = await env.DB.prepare(
    'SELECT repo_bug, id, status FROM feedback WHERE repo_bug IN (SELECT value FROM json_each(?1))',
  ).bind(JSON.stringify(bugs)).all();
  const byBug = new Map(existing.results.map((r) => [r.repo_bug, r]));

  // 每条：反馈行 + 时间线 + 几个索引。
  await spend(env, 'write_rows', bugs.length * 6, now);

  const stmts = [];
  /** @type {{bug: number, kind: 'upsert' | 'close', index: number}[]} */
  const slots = [];
  const created = [];
  const updated = [];
  const unchanged = [];
  const closed = [];
  const missing = [];
  for (const u of req.upsert) {
    stmts.push(env.DB.prepare(REOPEN_SQL).bind(u.bug, REPO_BUG_REOPEN_NOTE, t, u.hash));
    stmts.push(env.DB.prepare(UPSERT_SQL).bind(
      randomId(10), await ticketHash(randomId(32)), u.title, u.body, t, REPO_BUG_ORIGIN, u.bug, u.hash,
    ));
    slots.push({ bug: u.bug, kind: 'upsert', index: stmts.length - 1 });
  }
  for (const c of req.close) {
    const row = byBug.get(c.bug);
    if (!row) {
      missing.push(c.bug);
      continue;
    }
    if (c.reason === 'fixed') {
      // 只给还在处理中的行记修复：已结案（开发者手动 wont_fix 等）的不往上挂 commit。
      if (row.status !== 'open' && row.status !== 'in_progress') {
        unchanged.push(c.bug);
        continue;
      }
      for (const sql of MARK_FIXED_SQL) stmts.push(env.DB.prepare(sql).bind(...markFixedArgs(row.id, req.sha, 'app', t)));
    } else {
      for (const sql of DROP_SQL) stmts.push(env.DB.prepare(sql).bind(c.bug, REPO_BUG_DROP_NOTE, t));
    }
    slots.push({ bug: c.bug, kind: 'close', index: stmts.length - 1 });
  }
  const res = stmts.length > 0 ? await env.DB.batch(stmts) : [];
  for (const s of slots) {
    const changed = res[s.index].meta.changes === 1;
    if (s.kind === 'upsert') {
      if (!changed) unchanged.push(s.bug);
      else if (byBug.has(s.bug)) updated.push(s.bug);
      else created.push(s.bug);
    } else if (changed) {
      closed.push(s.bug);
    } else {
      unchanged.push(s.bug);
    }
  }
  return { created, updated, unchanged, closed, missing };
}
