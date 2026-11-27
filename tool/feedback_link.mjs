#!/usr/bin/env node
// 反馈修复标记：把 commit message / 合并 PR 描述里的 `Feedback: <id>` 行登记到反馈服务。
//
// 由 .github/workflows/feedback-link.yml 在 push develop / main 时调用：
//   * 逐个 commit 解析 message，其中的 id → 该 commit 的 sha；
//   * 每个 commit 再查关联 PR（GET /repos/{repo}/commits/{sha}/pulls，GITHUB_TOKEN），
//     只认 merged_at 非空、base 是本分支的 PR，解析它的描述；PR 描述里的 id → 该 PR
//     在这次 push 里出现的**最后一个** commit（按 event.commits 顺序）的 sha；
//   * 同一个 id 在一次 push 里出现多次：取 push 顺序最后的那个 sha（同位次 app 优先）。
//   * main 只处理 distinct 的 commit：正式版后 develop 同步进 main 的那次 push 带的是
//     develop 上早已登记过的提交，不再重登记。develop 处理全部 commit（同仓分支合进来的
//     提交此前推到过别的分支，distinct=false，但在 develop 上是第一次出现）。
// 事件内容只从 $GITHUB_EVENT_PATH 读、PR 描述只从 API 响应读——两者都是外部可控文本，
// 不经过 `${{ }}` 进入任何 shell。
//
// 行格式（不区分大小写，必须在行首，前面只允许空白；可多行、逗号或空格分隔多个 id）：
//   Feedback: <id>[, <id>...]        → scope app（需要新 App 才生效）
//   Feedback-NoApp: <id>[, <id>...]  → scope none（不需要更新 App）
// id 必须匹配 [A-Za-z0-9_-]{8,16}；不合法的忽略并记 ::warning。
//
// 接口：POST <FEEDBACK_API_BASE>/v1/ci/feedback/fixed
//   {"sha": "<40hex>", "ids": [...] (1..50), "scope": "app"|"none"}
//   Authorization: Bearer $FEEDBACK_CI_TOKEN
//   → {"updated": [...], "missing": [...], "unchanged": [...]}（sha+scope 相同的重登记是幂等的）
// 没配 secret → ::notice 后退出；GitHub API / 反馈接口的任何失败只记 ::warning，退出码恒为 0。
//
// 环境：GITHUB_EVENT_NAME / GITHUB_EVENT_PATH / GITHUB_REPOSITORY / GITHUB_API_URL /
//       GITHUB_TOKEN / FEEDBACK_CI_TOKEN / FEEDBACK_API_BASE
//
// 用法：
//   node tool/feedback_link.mjs             读事件、查 PR、登记
//   node tool/feedback_link.mjs --dry-run   读事件、查 PR、只打印计划（`PLAN {json}` 每行一条）
//   node tool/feedback_link.mjs --parse     从 stdin 读一段文本，打印解析结果 JSON
// 离线测试：fushi/test/tools/feedback_link_script_test.dart（假 GitHub API + 假反馈服务）。

import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

export const FEEDBACK_ID_RE = /^[A-Za-z0-9_-]{8,16}$/;
const SHA_RE = /^[0-9a-fA-F]{40}$/;
const LINE_RE = /^[ \t]*feedback(-noapp)?[ \t]*:(.*)$/i;
const LINKED_BRANCHES = new Set(['develop', 'main']);
const MAX_IDS_PER_REQUEST = 50;
const MAX_PR_LOOKUPS = 200;
// push 事件 payload 里 commits 数组的上限（GitHub 文档：最多 20 个）。
const PUSH_EVENT_COMMIT_CAP = 20;
// compare API 单页上限 100、最多返回 250 个提交。
const COMPARE_PAGE_SIZE = 100;
const COMPARE_MAX_PAGES = 3;
const DEFAULT_API_BASE = 'https://rank.fushi.moe';
const DEFAULT_GITHUB_API = 'https://api.github.com';

/**
 * 解析一段文本里的 Feedback 行。
 * @param {string} text
 * @returns {{app: string[], none: string[], invalid: string[]}}
 */
export function parseFeedbackRefs(text) {
  const app = [];
  const none = [];
  const invalid = [];
  if (typeof text !== 'string') return { app, none, invalid };
  for (const line of text.split(/\r\n|\r|\n/)) {
    const m = LINE_RE.exec(line);
    if (!m) continue;
    const target = m[1] ? none : app;
    for (const token of m[2].split(/[\s,]+/)) {
      if (token === '') continue;
      if (!FEEDBACK_ID_RE.test(token)) {
        invalid.push(token);
        continue;
      }
      if (!target.includes(token)) target.push(token);
    }
  }
  // 同一个 id 既写了 Feedback 又写了 Feedback-NoApp：按需要新 App 算（保守）。
  return { app, none: none.filter((id) => !app.includes(id)), invalid };
}

/**
 * 本次 push 要处理的 commit（按 event.commits 顺序）。不是 develop/main 的 push 返回 null。
 * @returns {{branch: string, commits: {sha: string, message: string}[]} | null}
 */
export function pushCommits(eventName, event) {
  if (eventName !== 'push' || !event) return null;
  const ref = event.ref || '';
  const branch = ref.startsWith('refs/heads/') ? ref.slice('refs/heads/'.length) : '';
  if (!LINKED_BRANCHES.has(branch)) return null;
  const commits = (Array.isArray(event.commits) ? event.commits : [])
    .filter((c) => c && typeof c.id === 'string' && SHA_RE.test(c.id))
    .filter((c) => branch !== 'main' || c.distinct !== false)
    .map((c) => ({ sha: c.id, message: typeof c.message === 'string' ? c.message : '' }));
  return { branch, commits };
}

/**
 * GitHub 的 push 事件 `commits` 最多带 20 个（多出的直接截掉，文档要求改用 compare API 取全）。
 * develop 上一次批量合并常推几十个提交，只读事件会漏登记前面的 Feedback 行（2026-11-27：
 * 一次推 76 个，漏了 4 条）。返回需要经 compare 补全时的 {before, after}，否则 null。
 * main 不补全：main 的 push 是正式版同步，compare 会带出 develop 上早已登记过的全部提交，
 * 而 compare 结果没有 distinct 字段可滤。
 * @returns {{before: string, after: string} | null}
 */
export function compareRange(branch, event) {
  if (branch !== 'develop' || !event) return null;
  const n = Array.isArray(event.commits) ? event.commits.length : 0;
  if (n < PUSH_EVENT_COMMIT_CAP) return null;
  const before = typeof event.before === 'string' ? event.before : '';
  const after = typeof event.after === 'string' ? event.after : '';
  if (!SHA_RE.test(before) || !SHA_RE.test(after) || /^0+$/.test(before)) return null;
  return { before, after };
}

/**
 * 纯函数：commit 列表 + 每个 commit 的关联 PR → 登记计划。
 * @param {{sha: string, message: string}[]} commits  push 顺序
 * @param {Map<string, {number: number, body: string}[]>} prsBySha  已按 merged/base 过滤
 */
export function planLinks(commits, prsBySha) {
  const invalid = [];
  // id → {order, sha, scope}；order 越大越晚，同 order 下 app 压过 none。
  const latest = new Map();
  const record = (refs, order, sha) => {
    invalid.push(...refs.invalid);
    for (const [scope, ids] of [['app', refs.app], ['none', refs.none]]) {
      for (const id of ids) {
        const prev = latest.get(id);
        if (
          !prev ||
          order > prev.order ||
          (order === prev.order && scope === 'app' && prev.scope === 'none')
        ) {
          latest.set(id, { order, sha, scope });
        }
      }
    }
  };

  // PR 编号 → {body, lastIndex}
  const prs = new Map();
  commits.forEach((c, i) => {
    for (const pr of prsBySha.get(c.sha) || []) {
      prs.set(pr.number, { body: pr.body || '', lastIndex: i });
    }
  });

  commits.forEach((c, i) => record(parseFeedbackRefs(c.message), i, c.sha));
  for (const { body, lastIndex } of prs.values()) {
    record(parseFeedbackRefs(body), lastIndex, commits[lastIndex].sha);
  }

  // 按 (sha, scope) 归组，组的顺序跟 push 顺序走，组内 id 按出现顺序。
  const groups = new Map();
  const sorted = [...latest.entries()].sort((a, b) => a[1].order - b[1].order);
  for (const [id, { sha, scope }] of sorted) {
    const key = `${sha} ${scope}`;
    if (!groups.has(key)) groups.set(key, { sha, scope, ids: [] });
    groups.get(key).ids.push(id);
  }
  const plans = [];
  for (const g of groups.values()) {
    for (let i = 0; i < g.ids.length; i += MAX_IDS_PER_REQUEST) {
      plans.push({ sha: g.sha, scope: g.scope, ids: g.ids.slice(i, i + MAX_IDS_PER_REQUEST) });
    }
  }
  return { plans, invalid };
}

// 外部可控文本进日志前收窄字符集，免得拼出 workflow command。
function safe(text) {
  return String(text).slice(0, 32).replace(/[^A-Za-z0-9_.<>-]/g, '?');
}

const warn = (msg) => console.log(`::warning title=Feedback link::${msg}`);
const notice = (msg) => console.log(`::notice title=Feedback link::${msg}`);

async function mergedPrsFor(sha, branch) {
  const api = (process.env.GITHUB_API_URL || DEFAULT_GITHUB_API).replace(/\/+$/, '');
  const repo = process.env.GITHUB_REPOSITORY || '';
  const token = process.env.GITHUB_TOKEN || '';
  if (!/^[\w.-]+\/[\w.-]+$/.test(repo)) {
    warn('GITHUB_REPOSITORY is not set; skipping PR description lookup.');
    return null;
  }
  try {
    const headers = {
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
    };
    if (token) headers.Authorization = `Bearer ${token}`;
    const res = await fetch(`${api}/repos/${repo}/commits/${sha}/pulls`, {
      headers,
      signal: AbortSignal.timeout(20000),
    });
    if (!res.ok) {
      warn(`PR lookup for ${sha.slice(0, 7)} returned HTTP ${res.status}.`);
      return [];
    }
    const list = await res.json();
    if (!Array.isArray(list)) return [];
    return list
      .filter((pr) => pr && pr.merged_at && pr.base && pr.base.ref === branch)
      .filter((pr) => Number.isInteger(pr.number))
      .map((pr) => ({ number: pr.number, body: typeof pr.body === 'string' ? pr.body : '' }));
  } catch (e) {
    warn(`PR lookup for ${sha.slice(0, 7)} failed: ${safe(e && e.name)}`);
    return [];
  }
}

/**
 * compare API 取 before...after 的全部提交（旧→新，与 event.commits 同序）。失败返回 null，
 * 调用方退回事件里的（可能被截断的）列表。
 * @returns {Promise<{sha: string, message: string}[] | null>}
 */
async function compareCommits(range) {
  const api = (process.env.GITHUB_API_URL || DEFAULT_GITHUB_API).replace(/\/+$/, '');
  const repo = process.env.GITHUB_REPOSITORY || '';
  const token = process.env.GITHUB_TOKEN || '';
  if (!/^[\w.-]+\/[\w.-]+$/.test(repo)) return null;
  const headers = {
    Accept: 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
  };
  if (token) headers.Authorization = `Bearer ${token}`;
  const out = [];
  try {
    for (let page = 1; page <= COMPARE_MAX_PAGES; page++) {
      const url =
        `${api}/repos/${repo}/compare/${range.before}...${range.after}` +
        `?per_page=${COMPARE_PAGE_SIZE}&page=${page}`;
      const res = await fetch(url, { headers, signal: AbortSignal.timeout(20000) });
      if (!res.ok) {
        warn(`compare ${range.before.slice(0, 7)}...${range.after.slice(0, 7)} returned HTTP ${res.status}.`);
        return null;
      }
      const body = await res.json();
      const list = body && Array.isArray(body.commits) ? body.commits : [];
      for (const c of list) {
        if (!c || typeof c.sha !== 'string' || !SHA_RE.test(c.sha)) continue;
        const message = c.commit && typeof c.commit.message === 'string' ? c.commit.message : '';
        out.push({ sha: c.sha, message });
      }
      const total = body && Number.isInteger(body.total_commits) ? body.total_commits : out.length;
      if (list.length < COMPARE_PAGE_SIZE || out.length >= total) break;
    }
  } catch (e) {
    warn(`compare failed: ${safe(e && e.name)}`);
    return null;
  }
  return out;
}

async function postFixed(apiBase, token, plan) {
  try {
    const res = await fetch(`${apiBase}/v1/ci/feedback/fixed`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/json',
        Accept: 'application/json',
      },
      body: JSON.stringify(plan),
      signal: AbortSignal.timeout(20000),
    });
    const text = await res.text();
    if (!res.ok) {
      warn(`POST fixed for ${plan.sha.slice(0, 7)} (${plan.scope}) returned HTTP ${res.status}.`);
      return;
    }
    let body = {};
    try {
      body = JSON.parse(text);
    } catch {
      // 只用于日志；响应形状不对不影响结果。
    }
    const list = (k) => (Array.isArray(body[k]) ? body[k].map(safe).join(', ') : '-');
    console.log(
      `Linked ${plan.sha.slice(0, 7)} (${plan.scope}): updated [${list('updated')}], ` +
        `unchanged [${list('unchanged')}], missing [${list('missing')}]`,
    );
  } catch (e) {
    warn(`POST fixed for ${plan.sha.slice(0, 7)} failed: ${safe(e && e.name)}`);
  }
}

async function main(argv) {
  if (argv.includes('--parse')) {
    console.log(JSON.stringify(parseFeedbackRefs(readFileSync(0, 'utf8'))));
    return;
  }
  const dryRun = argv.includes('--dry-run');
  const eventPath = process.env.GITHUB_EVENT_PATH || '';
  if (!eventPath) {
    warn('GITHUB_EVENT_PATH is not set; nothing to do.');
    return;
  }
  const event = JSON.parse(readFileSync(eventPath, 'utf8'));
  const push = pushCommits(process.env.GITHUB_EVENT_NAME || '', event);
  if (!push || push.commits.length === 0) {
    console.log('Not a push to develop/main with new commits; nothing to do.');
    return;
  }
  const token = process.env.FEEDBACK_CI_TOKEN || '';
  if (!dryRun && !token) {
    notice('FEEDBACK_CI_TOKEN is not configured; skipping.');
    return;
  }
  const range = compareRange(push.branch, event);
  if (range) {
    const full = await compareCommits(range);
    if (full && full.length > push.commits.length) {
      console.log(`push event listed ${push.commits.length} commits; compare API returned ${full.length}.`);
      push.commits = full;
    } else if (!full) {
      warn(`push event lists only ${push.commits.length} commits and compare failed; earlier commits may be missed.`);
    }
  }

  const prsBySha = new Map();
  const lookups = push.commits.slice(-MAX_PR_LOOKUPS);
  if (lookups.length < push.commits.length) {
    warn(`push has ${push.commits.length} commits; PR descriptions are read for the last ${MAX_PR_LOOKUPS} only.`);
  }
  for (const c of lookups) {
    const prs = await mergedPrsFor(c.sha, push.branch);
    if (prs === null) break;
    prsBySha.set(c.sha, prs);
  }

  const { plans, invalid } = planLinks(push.commits, prsBySha);
  if (invalid.length > 0) {
    warn(`ignored ${invalid.length} malformed feedback id(s): ${invalid.slice(0, 5).map(safe).join(' ')}`);
  }
  for (const plan of plans) console.log(`PLAN ${JSON.stringify(plan)}`);
  if (plans.length === 0) {
    console.log('No Feedback: lines found.');
    return;
  }
  if (dryRun) return;
  const apiBase = (process.env.FEEDBACK_API_BASE || DEFAULT_API_BASE).replace(/\/+$/, '');
  for (const plan of plans) await postFixed(apiBase, token, plan);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2))
    .catch((e) => warn(`unexpected failure: ${safe(e && e.name)}`))
    .finally(() => {
      process.exitCode = 0;
    });
}
