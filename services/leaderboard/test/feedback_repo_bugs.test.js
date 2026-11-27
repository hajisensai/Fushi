// 仓库 BUG → 反馈同步（迁移 0028；src/feedback_repo_bugs.js + tool/bug_feedback_sync.mjs）。
// 端到端：CI 脚本 runSync 的 fetch 直接接到真 Worker（真 SQLite 跑真迁移），验证幂等、修复结案、
// 回归重开、删除结案、撞号跳过与回填下限。
import { mkdtempSync, rmSync, writeFileSync, unlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import worker from '../src/worker.js';
import { call, makeEnv } from './harness.js';
import { devList } from '../src/feedback.js';
import { REPO_BUG_DROP_NOTE, REPO_BUG_REOPEN_NOTE } from '../src/feedback_repo_bugs.js';
import { BODY_MAX, TITLE_MAX, feedbackFor, parseBugFile, planSync, runSync } from '../../../tool/bug_feedback_sync.mjs';

const TOKEN = 'ci-token-0123456789abcdef';
const SHA = 'b'.repeat(40);
const API = 'https://rank.example.com';

const ciEnv = () => makeEnv({ FEEDBACK_CI_TOKEN: TOKEN });

function bugText(n, title, { fixed = false, reality = '✅ 真 bug，根因 `a.dart:1`', note = '' } = {}) {
  return `## BUG-${n} · ${title}
- **报告**：2026-11-27（用户：）
- **真实性**：${reality}
- **[${fixed ? 'x' : ' '}] ① ${fixed ? '已修复' : '未修复'}** —
- **[ ] ② 未加自动化测试** —
- **备注**：${note}
`;
}

let dir;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'bugsync-'));
});
afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

const put = (name, text) => writeFileSync(join(dir, name), text, 'utf8');

function sync(env, opts = {}) {
  const log = [];
  const fetchImpl = (url, init) => worker.fetch(new Request(url, init), env);
  return runSync({
    bugsDir: dir, apiBase: API, token: TOKEN, sha: SHA, repoUrl: 'https://github.com/o/r', fetchImpl,
    log: (l) => log.push(l), ...opts,
  }).then((r) => ({ ...r, log }));
}

const rows = (env) => env.DB.raw.prepare('SELECT * FROM feedback WHERE repo_bug IS NOT NULL ORDER BY repo_bug').all();
const row = (env, bug) => env.DB.raw.prepare('SELECT * FROM feedback WHERE repo_bug = ?').get(bug);
const msgs = (env, id) => env.DB.raw.prepare('SELECT author, body, status FROM feedback_messages WHERE feedback_id = ? ORDER BY id').all(id);

describe('parseBugFile（与 tool/bug.dart statusIcons 同口径）', () => {
  it('open / fixed / dropped / record', () => {
    expect(parseBugFile('BUG-1-a.md', bugText(1, '甲')).state).toBe('open');
    expect(parseBugFile('BUG-1-a.md', bugText(1, '甲', { fixed: true })).state).toBe('fixed');
    expect(parseBugFile('BUG-1-a.md', bugText(1, '甲', { reality: '❌ 未复现（无日志）' })).state).toBe('dropped');
    // 勾了 ① 的即使写了 ❌ 也按 fixed。
    expect(parseBugFile('BUG-1-a.md', bugText(1, '甲', { fixed: true, reality: '❌ 非 bug' })).state).toBe('fixed');
    expect(parseBugFile('BUG-2.md', '## BUG-002 · 仅记录\n- **备注**：x\n').state).toBe('record');
    expect(parseBugFile('BUG-2.md', '没有标题\n')).toBeNull();
    const p = parseBugFile('BUG-007-x.md', '## BUG-007 · 标题\r\n- **[ ] ① 未修复** —\r\n');
    expect(p).toMatchObject({ number: 7, title: '标题', state: 'open' });
  });

  it('超长标题 / 正文截到服务端上限内，hash 只随内容变', () => {
    const e = parseBugFile('BUG-9-x.md', bugText(9, '长'.repeat(300), { note: '字'.repeat(20000) }));
    const fb = feedbackFor(e, { repoUrl: 'https://github.com/o/r' });
    expect(fb.title.length).toBeLessThanOrEqual(TITLE_MAX);
    expect(fb.body.length).toBeLessThanOrEqual(BODY_MAX);
    expect(fb.body).toContain('https://github.com/o/r/blob/develop/docs/bugs/BUG-9-x.md');
    expect(feedbackFor(e, { repoUrl: 'https://github.com/o/r' }).hash).toBe(fb.hash);
    expect(fb.hash).toMatch(/^[0-9a-f]{64}$/);
    expect(fb.title.startsWith('BUG-009 · ')).toBe(true);
  });
});

describe('鉴权与校验', () => {
  it('没配 token 404；token 不对 401', async () => {
    expect((await call(makeEnv(), 'GET', '/v1/ci/feedback/bugs', { headers: { Authorization: `Bearer ${TOKEN}` } })).status).toBe(404);
    expect((await call(ciEnv(), 'GET', '/v1/ci/feedback/bugs', { headers: { Authorization: 'Bearer nope' } })).status).toBe(401);
  });

  it('同号重复 / 条数超限 / fixed 缺 sha / 坏 hash → 400，什么都不写', async () => {
    const env = ciEnv();
    const h = { Authorization: `Bearer ${TOKEN}` };
    const up = (bug) => ({ bug, title: 't', body: 'b', hash: 'a'.repeat(64) });
    const post = (body) => call(env, 'POST', '/v1/ci/feedback/bugs', { body, headers: h });
    expect((await post({ upsert: [up(1)], close: [{ bug: 1, reason: 'dropped' }] })).data.error).toBe('duplicate_bug');
    expect((await post({ upsert: Array.from({ length: 26 }, (_, i) => up(i + 1)) })).data.error).toBe('too_many_items');
    expect((await post({ close: [{ bug: 1, reason: 'fixed' }] })).data.error).toBe('bad_sha');
    expect((await post({ upsert: [{ ...up(1), hash: 'xyz' }] })).data.error).toBe('bad_hash');
    expect((await post({ upsert: [{ ...up(1), bug: 1.5 }] })).data.error).toBe('bad_bug');
    expect(rows(env)).toEqual([]);
  });
});

describe('runSync 端到端', () => {
  it('只建未修复的；同一份文件跑两次只有一条反馈', async () => {
    const env = ciEnv();
    put('BUG-101-open.md', bugText(101, '未修复的'));
    put('BUG-102-fixed.md', bugText(102, '已修复的', { fixed: true }));
    put('BUG-103-nope.md', bugText(103, '未复现', { reality: '❌ 未复现' }));
    put('BUG-104.md', '## BUG-104 · 仅记录\n- **备注**：x\n');
    const r1 = await sync(env);
    expect(r1.created).toEqual([101]);
    expect(rows(env).map((r) => r.repo_bug)).toEqual([101]);
    const r101 = row(env, 101);
    expect(r101).toMatchObject({ category: 'bug', status: 'open', account_id: null, title: 'BUG-101 · 未修复的', origin: '{"source":"repo_bug"}' });
    expect(r101.body).toContain('**真实性**');

    const r2 = await sync(env);
    expect(r2.planned).toEqual({ upsert: 0, close: 0 });
    expect(rows(env)).toHaveLength(1);
    expect(row(env, 101).updated_at).toBe(r101.updated_at);

    // 服务端层面同样幂等：同 hash 再 upsert 一次 → unchanged。
    const again = await call(env, 'POST', '/v1/ci/feedback/bugs', {
      headers: { Authorization: `Bearer ${TOKEN}` },
      body: { upsert: [{ bug: 101, title: r101.title, body: r101.body, hash: r101.repo_bug_hash }] },
    });
    expect(again.data).toMatchObject({ created: [], updated: [], unchanged: [101] });
    expect(rows(env)).toHaveLength(1);

    // 开发者列表能看到 BUG 号。
    const list = await devList(env, {});
    expect(list.items.find((i) => i.id === r101.id).repoBug).toBe(101);
  });

  it('文件改了 → 改文字；勾 ① → 已修复并记 sha；再跑不动；改回未修复 → 重开', async () => {
    const env = ciEnv();
    put('BUG-201-a.md', bugText(201, '旧标题'));
    await sync(env);
    const id = row(env, 201).id;

    put('BUG-201-a.md', bugText(201, '新标题', { note: '补充复现步骤' }));
    expect((await sync(env)).updated).toEqual([201]);
    expect(row(env, 201)).toMatchObject({ id, title: 'BUG-201 · 新标题', status: 'open' });
    expect(row(env, 201).body).toContain('补充复现步骤');

    put('BUG-201-a.md', bugText(201, '新标题', { fixed: true }));
    expect((await sync(env)).closed).toEqual([201]);
    expect(row(env, 201)).toMatchObject({ id, status: 'resolved', fix_sha: SHA, fix_scope: 'app' });
    expect(msgs(env, id).at(-1)).toMatchObject({ author: 'dev', status: 'resolved' });
    expect((await sync(env)).planned).toEqual({ upsert: 0, close: 0 });

    put('BUG-201-a.md', bugText(201, '新标题', { note: '又复现了' }));
    expect((await sync(env)).updated).toEqual([201]);
    expect(row(env, 201)).toMatchObject({ id, status: 'open', fix_sha: null, fix_scope: null, fix_at: null, fixed_in: '{}' });
    expect(msgs(env, id).at(-1)).toMatchObject({ body: REPO_BUG_REOPEN_NOTE, status: 'open' });
    expect(rows(env)).toHaveLength(1);
  });

  it('文件删掉 / 标 ❌ → 结案；开发者手动结案的不被改状态', async () => {
    const env = ciEnv();
    put('BUG-301-a.md', bugText(301, '会被删'));
    put('BUG-302-b.md', bugText(302, '会被判未复现'));
    put('BUG-303-c.md', bugText(303, '开发者 wont_fix'));
    await sync(env);
    env.DB.raw.prepare("UPDATE feedback SET status = 'wont_fix' WHERE repo_bug = 303").run();

    unlinkSync(join(dir, 'BUG-301-a.md'));
    put('BUG-302-b.md', bugText(302, '会被判未复现', { reality: '❌ 未复现' }));
    put('BUG-303-c.md', bugText(303, '开发者 wont_fix', { note: '文字改了' }));
    const r = await sync(env);
    expect(r.closed).toEqual([301, 302]);
    expect(r.updated).toEqual([303]);
    expect(row(env, 301).status).toBe('closed');
    expect(msgs(env, row(env, 302).id).at(-1)).toMatchObject({ body: REPO_BUG_DROP_NOTE, status: 'closed' });
    expect(row(env, 303)).toMatchObject({ status: 'wont_fix' });
    expect(row(env, 303).body).toContain('文字改了');

    // 结案的再跑一次不动；wont_fix 的文件后来勾了 ① 也不挂 commit。
    put('BUG-303-c.md', bugText(303, '开发者 wont_fix', { fixed: true }));
    expect((await sync(env)).planned).toEqual({ upsert: 0, close: 0 });
    expect(row(env, 303).fix_sha).toBeNull();
  });

  it('撞号（未 settle）整号跳过：不建、不结案', async () => {
    const env = ciEnv();
    put('BUG-401-a.md', bugText(401, '甲'));
    await sync(env);
    put('BUG-401-b.md', bugText(401, '乙'));
    const r = await sync(env);
    expect(r.collided).toEqual([401]);
    expect(r.planned).toEqual({ upsert: 0, close: 0 });
    expect(r.log.some((l) => l.includes('撞号'))).toBe(true);
    expect(row(env, 401)).toMatchObject({ status: 'open', title: 'BUG-401 · 甲' });
  });

  it('BUG_FEEDBACK_MIN_NUMBER：低于下限的不新建，已建的照常结案', async () => {
    const env = ciEnv();
    put('BUG-501-a.md', bugText(501, '旧'));
    await sync(env);
    put('BUG-499-old.md', bugText(499, '更旧'));
    put('BUG-600-new.md', bugText(600, '新'));
    put('BUG-501-a.md', bugText(501, '旧', { fixed: true }));
    const r = await sync(env, { minBug: 550 });
    expect(r.created).toEqual([600]);
    expect(r.closed).toEqual([501]);
    expect(row(env, 499)).toBeUndefined();
  });

  it('超过一批（25 条）分批提交，dry-run 只打印计划', async () => {
    const env = ciEnv();
    for (let n = 1000; n < 1060; n++) put(`BUG-${n}.md`, bugText(n, `第 ${n} 条`));
    const dry = await sync(env, { dryRun: true });
    expect(dry.planned.upsert).toBe(60);
    expect(dry.log.filter((l) => l.startsWith('PLAN '))).toHaveLength(60);
    expect(rows(env)).toEqual([]);
    const r = await sync(env);
    expect(r.created).toHaveLength(60);
    expect(rows(env)).toHaveLength(60);
    expect((await sync(env)).planned).toEqual({ upsert: 0, close: 0 });
  });

  it('planSync 纯函数：已结案行不再结案', () => {
    const e = parseBugFile('BUG-1.md', bugText(1, 'x', { fixed: true }));
    const plan = planSync(new Map([[1, e]]), new Set(), [{ bug: 1, id: 'abcdefgh', hash: null, status: 'resolved' }]);
    expect(plan).toEqual({ upsert: [], close: [] });
  });
});
