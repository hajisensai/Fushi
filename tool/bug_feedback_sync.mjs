#!/usr/bin/env node
// 仓库 BUG → 应用内反馈对账：docs/bugs/BUG-*.md 里「① 未修复」的条目，在反馈服务里按 BUG 号
// 各有一条反馈（开发者处理台 / App 开发者视图里看得到）；BUG 文件勾了 ① 就把那条标「已修复」，
// 文件删掉 / 改号 / 标成 ❌ 未复现就结案。
//
// 由 .github/workflows/bug-feedback-sync.yml 在 develop 收到 push 时调用；跑多少次结果都一样：
//   1. 扫 docs/bugs，按与 tool/bug.dart statusIcons 同一口径判每个文件的状态：
//        open     有 ① 标记、没勾 [x] ①，且「真实性」行没有 ❌
//        fixed    勾了 [x] ①
//        dropped  没勾 ①，但「真实性」行写了 ❌（未复现 / 非 bug）
//        record   既无 ① 也无 ②（仅记录）
//      同一个号有两个文件（develop 上还没 settle 的撞号）→ 这个号本轮整个跳过，不建不改不结案。
//   2. GET  <API>/v1/ci/feedback/bugs   拿服务端已同步的 {bug, id, hash, status}
//   3. 算差异：
//        open 且服务端没有（且号 ≥ BUG_FEEDBACK_MIN_NUMBER） → upsert（新建）
//        open 且 hash 不同                                    → upsert（改文字；已解决的会被拉回 open）
//        服务端 open / in_progress、文件 fixed                 → close fixed（修复 commit 记本次 push 的 sha）
//        服务端 open / in_progress、文件 dropped / record / 不存在 → close dropped
//   4. POST <API>/v1/ci/feedback/bugs   每批 ≤ 25 条
//   hash = SHA-256(标题 + "\n" + 正文)，只由本脚本算；服务端只存、只比。
//
// 契约与服务端实现：services/leaderboard/src/feedback_repo_bugs.js（迁移 0028）。
//
// 环境：
//   FEEDBACK_CI_TOKEN        secret；为空 → ::notice 后退出 0
//   FEEDBACK_API_BASE        接口根，空则 https://rank.fushi.moe
//   BUG_FEEDBACK_MIN_NUMBER  只为号 ≥ 它的 BUG 新建反馈（回填范围；空 = 全部）；已建的照常更新 / 结案
//   GITHUB_SHA               本次 push 的提交（close fixed 记成修复 commit）
//   GITHUB_SERVER_URL / GITHUB_REPOSITORY   正文里的仓库链接
// 参数：
//   --dry-run          照常扫描、GET、算差异，只打印 `PLAN {json}` 每行一条，不 POST
//   --bugs-dir <dir>   默认 docs/bugs
// 失败：没配 token 或服务端还没部署该接口（404）→ ::notice 退出 0；其他接口错误 → ::error 退出 1
// （不重试：下一次 push 重新对账就会补上）。
//
// 测试：services/leaderboard/test/feedback_repo_bugs.test.js（真迁移 + 真 Worker 路由端到端跑本脚本）。

import { createHash } from 'node:crypto';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

export const TITLE_MAX = 120;
export const BODY_MAX = 8000;
export const BATCH_MAX = 25;
const DEFAULT_API_BASE = 'https://rank.fushi.moe';
const HEADING_RE = /^##\s+BUG-(\d+)\s*·\s*(.*)$/;
const REALITY_RE = /\*\*真实性\*\*\s*[：:](.*)$/;
const ACTIVE = new Set(['open', 'in_progress']);

/**
 * 解析一个 BUG 文件。解析不出 `## BUG-NNN · 标题` 的返回 null。
 * @param {string} fileName
 * @param {string} text
 * @returns {{number: number, fileName: string, title: string, state: 'open'|'fixed'|'dropped'|'record', text: string} | null}
 */
export function parseBugFile(fileName, text) {
  const src = text.replace(/\r\n?/g, '\n');
  const lines = src.split('\n');
  let number = null;
  let title = '';
  let headingAt = -1;
  for (let i = 0; i < lines.length; i++) {
    const m = HEADING_RE.exec(lines[i].trimEnd());
    if (m) {
      number = Number.parseInt(m[1], 10);
      title = m[2].trim();
      headingAt = i;
      break;
    }
  }
  if (number === null || !Number.isSafeInteger(number) || number < 1) return null;
  // 与 tool/bug.dart statusIcons 同一口径。
  const hasFixMark = src.includes('① ') || src.includes('①未');
  const fixDone = src.includes('[x] ①');
  let reality = '';
  for (const l of lines) {
    const m = REALITY_RE.exec(l);
    if (m) {
      reality = m[1];
      break;
    }
  }
  let state;
  if (!hasFixMark) state = 'record';
  else if (fixDone) state = 'fixed';
  else if (reality.includes('❌')) state = 'dropped';
  else state = 'open';
  const rest = lines.slice(headingAt + 1).join('\n').trim();
  return { number, fileName, title: title || fileName, state, text: rest };
}

/**
 * 扫目录。撞号（同一个号多个文件）的号单独返回，本轮不处理。
 * @param {string} dir
 * @returns {{entries: Map<number, ReturnType<typeof parseBugFile>>, collided: Set<number>, unparsed: string[]}}
 */
export function scanBugsDir(dir) {
  const entries = new Map();
  const collided = new Set();
  const unparsed = [];
  for (const name of readdirSync(dir).sort()) {
    if (!name.endsWith('.md') || name.startsWith('_')) continue;
    const e = parseBugFile(name, readFileSync(join(dir, name), 'utf8'));
    if (!e) {
      unparsed.push(name);
      continue;
    }
    if (entries.has(e.number) || collided.has(e.number)) {
      collided.add(e.number);
      entries.delete(e.number);
      continue;
    }
    entries.set(e.number, e);
  }
  return { entries, collided, unparsed };
}

function clip(s, max) {
  return s.length <= max ? s : `${s.slice(0, max - 1)}…`;
}

/**
 * 反馈的标题 / 正文 / hash。只依赖文件内容与仓库链接（不含 sha / 时间），同一份文件永远同一个 hash。
 * @param {{number: number, fileName: string, title: string, text: string}} entry
 * @param {{repoUrl?: string}} [opts]
 */
export function feedbackFor(entry, opts = {}) {
  // 与 tool/bug.dart padNum 同口径（3 位补零），处理台里搜 `BUG-066` 能搜到。
  const title = clip(`BUG-${String(entry.number).padStart(3, '0')} · ${entry.title}`, TITLE_MAX).trim();
  const path = `docs/bugs/${entry.fileName}`;
  const link = opts.repoUrl ? `${opts.repoUrl}/blob/develop/${path}` : path;
  const head = `［仓库 BUG 自动同步］来源 ${link}\n以仓库文件为准：文件更新后这里随下一次 develop push 覆盖；勾上 ① 自动标为已修复。\n\n`;
  const body = (head + clip(entry.text || '（文件正文为空）', BODY_MAX - head.length)).trim();
  const hash = createHash('sha256').update(`${title}\n${body}`, 'utf8').digest('hex');
  return { title, body, hash };
}

/**
 * 算差异。
 * @param {Map<number, any>} entries scanBugsDir().entries
 * @param {Set<number>} collided
 * @param {{bug: number, id: string, hash: string|null, status: string}[]} remote
 * @param {{minBug?: number, repoUrl?: string}} [opts]
 * @returns {{upsert: {bug: number, title: string, body: string, hash: string}[], close: {bug: number, reason: 'fixed'|'dropped'}[]}}
 */
export function planSync(entries, collided, remote, opts = {}) {
  const minBug = opts.minBug ?? 0;
  const byBug = new Map(remote.map((r) => [r.bug, r]));
  const upsert = [];
  const close = [];
  for (const e of [...entries.values()].sort((a, b) => a.number - b.number)) {
    if (e.state !== 'open') continue;
    const row = byBug.get(e.number);
    if (!row && e.number < minBug) continue;
    const fb = feedbackFor(e, opts);
    if (row && row.hash === fb.hash) continue;
    upsert.push({ bug: e.number, ...fb });
  }
  for (const r of [...remote].sort((a, b) => a.bug - b.bug)) {
    if (!ACTIVE.has(r.status) || collided.has(r.bug)) continue;
    const e = entries.get(r.bug);
    if (e && e.state === 'open') continue;
    close.push({ bug: r.bug, reason: e && e.state === 'fixed' ? 'fixed' : 'dropped' });
  }
  return { upsert, close };
}

/** 切成每批 ≤ BATCH_MAX 条（先 close 再 upsert，结案先落地）。 */
export function batches(plan) {
  const items = [...plan.close.map((c) => ({ close: c })), ...plan.upsert.map((u) => ({ upsert: u }))];
  const out = [];
  for (let i = 0; i < items.length; i += BATCH_MAX) {
    const chunk = items.slice(i, i + BATCH_MAX);
    out.push({
      upsert: chunk.filter((x) => x.upsert).map((x) => x.upsert),
      close: chunk.filter((x) => x.close).map((x) => x.close),
    });
  }
  return out;
}

export class ApiError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

async function api(fetchImpl, base, token, method, path, body) {
  const res = await fetchImpl(`${base}${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(60_000),
  });
  const text = await res.text();
  if (!res.ok) throw new ApiError(res.status, `${method} ${path} → HTTP ${res.status} ${text.slice(0, 200)}`);
  return JSON.parse(text);
}

/**
 * 跑一轮对账。
 * @param {{
 *   bugsDir: string, apiBase: string, token: string, sha?: string, repoUrl?: string, minBug?: number,
 *   dryRun?: boolean, fetchImpl?: typeof fetch, log?: (line: string) => void,
 * }} o
 * @returns {Promise<{planned: {upsert: number, close: number}, created: number[], updated: number[], unchanged: number[], closed: number[], missing: number[], collided: number[]}>}
 */
export async function runSync(o) {
  const log = o.log ?? ((l) => console.log(l));
  const fetchImpl = o.fetchImpl ?? fetch;
  const base = o.apiBase.replace(/\/+$/, '');
  const { entries, collided, unparsed } = scanBugsDir(o.bugsDir);
  for (const n of unparsed) log(`::warning title=BUG feedback sync::${n} 解析不出 BUG 标题，已跳过`);
  if (collided.size > 0) {
    log(`::warning title=BUG feedback sync::撞号未 settle，本轮跳过：${[...collided].sort((a, b) => a - b).join(', ')}`);
  }
  const remote = (await api(fetchImpl, base, o.token, 'GET', '/v1/ci/feedback/bugs')).items;
  const plan = planSync(entries, collided, remote, { minBug: o.minBug, repoUrl: o.repoUrl });
  const out = {
    planned: { upsert: plan.upsert.length, close: plan.close.length },
    created: [], updated: [], unchanged: [], closed: [], missing: [],
    collided: [...collided].sort((a, b) => a - b),
  };
  if (o.dryRun) {
    for (const c of plan.close) log(`PLAN ${JSON.stringify({ op: 'close', ...c })}`);
    for (const u of plan.upsert) log(`PLAN ${JSON.stringify({ op: 'upsert', bug: u.bug, title: u.title })}`);
    return out;
  }
  for (const b of batches(plan)) {
    const r = await api(fetchImpl, base, o.token, 'POST', '/v1/ci/feedback/bugs', { sha: o.sha, ...b });
    for (const k of ['created', 'updated', 'unchanged', 'closed', 'missing']) out[k].push(...r[k]);
  }
  return out;
}

async function main(argv, env) {
  const dryRun = argv.includes('--dry-run');
  const dirAt = argv.indexOf('--bugs-dir');
  const bugsDir = dirAt >= 0 ? argv[dirAt + 1] : 'docs/bugs';
  const token = env.FEEDBACK_CI_TOKEN || '';
  if (!token) {
    console.log('::notice title=BUG feedback sync::FEEDBACK_CI_TOKEN 未配置，跳过。');
    return 0;
  }
  const minRaw = (env.BUG_FEEDBACK_MIN_NUMBER || '').trim();
  const minBug = minRaw === '' ? 0 : Number.parseInt(minRaw, 10);
  if (!Number.isSafeInteger(minBug) || minBug < 0) {
    console.log(`::error title=BUG feedback sync::BUG_FEEDBACK_MIN_NUMBER 不是非负整数：${minRaw}`);
    return 1;
  }
  const repoUrl = env.GITHUB_SERVER_URL && env.GITHUB_REPOSITORY ? `${env.GITHUB_SERVER_URL}/${env.GITHUB_REPOSITORY}` : undefined;
  try {
    const r = await runSync({
      bugsDir, apiBase: env.FEEDBACK_API_BASE || DEFAULT_API_BASE, token, sha: env.GITHUB_SHA, repoUrl, minBug, dryRun,
    });
    console.log(`RESULT ${JSON.stringify(r)}`);
    return 0;
  } catch (e) {
    if (e instanceof ApiError && e.status === 404) {
      console.log('::notice title=BUG feedback sync::反馈服务还没有 /v1/ci/feedback/bugs（Worker 未部署迁移 0028 这一版），跳过。');
      return 0;
    }
    console.log(`::error title=BUG feedback sync::${e && e.message ? e.message : e}`);
    return 1;
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] || '').href) {
  process.exitCode = await main(process.argv.slice(2), process.env);
}
