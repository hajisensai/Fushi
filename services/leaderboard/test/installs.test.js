// 安装统计心跳（迁移 0011；POST /v1/ping、/dev/stats、反馈详情的安装轨迹）。
import { describe, expect, it } from 'vitest';
import { call, makeEnv, nextIp, registerUser } from './harness.js';
import { INSTALL_LIMITS, installStats, versionIncludes } from '../src/installs.js';
import worker from '../src/worker.js';

const NOW = Date.UTC(2026, 9, 17, 12);
const DAY = 24 * 3600 * 1000;
const A = '0f8fad5b-d9cb-469f-a165-70867728950e';
const B = '7c9e6679-7425-40de-944b-e07fc1f90ae7';
const C = '16fd2706-8baf-433b-82eb-8c7fada847da';
const basic = { Authorization: `Basic ${btoa('admin:pw')}` };

function ping(env, body = {}, opts = {}) {
  return call(env, 'POST', '/v1/ping', {
    body: { installId: A, version: '2.10.0', platform: 'windows', channel: 'stable', ...body },
    headers: { 'CF-Connecting-IP': opts.ip ?? nextIp() },
    now: opts.now ?? NOW,
  });
}

const count = (env, table) => env.DB.raw.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get().n;
const budgetUsed = (env, day = '2026-10-17') =>
  env.DB.raw.prepare("SELECT used FROM budgets WHERE day = ? AND kind = 'ping'").get(day)?.used ?? 0;

async function devPage(env, path) {
  const dev = await registerUser(env, 'dev', { now: NOW });
  expect((await call(env, 'POST', `/admin/api/accounts/${dev.id}/role`, { headers: basic, body: { role: 'dev' }, now: NOW })).status).toBe(200);
  const token = 'tok'.padEnd(43, 'x');
  const { hex, sha256 } = await import('../src/util.js');
  env.DB.raw.prepare('INSERT INTO dev_sessions (token_hash, account_id, expires_at) VALUES (?, ?, ?)')
    .run(hex(await sha256(new TextEncoder().encode(token))), dev.id, NOW + DAY);
  return call(env, 'GET', path, { headers: { Cookie: `fushi_dev=${token}` }, now: NOW });
}

describe('POST /v1/ping', () => {
  it('首次心跳 → 204，写入 installs 与 install_days，不存 IP', async () => {
    const env = makeEnv();
    const r = await ping(env, {}, { ip: '203.0.113.9' });
    expect(r.status).toBe(204);
    const row = env.DB.raw.prepare('SELECT * FROM installs WHERE install_id = ?').get(A);
    expect(row).toMatchObject({ first_seen: NOW, last_seen: NOW, platform: 'windows', channel: 'stable', version: '2.10.0' });
    expect(env.DB.raw.prepare('SELECT * FROM install_days').all()).toEqual([
      { day: '2026-10-17', install_id: A, platform: 'windows', channel: 'stable', version: '2.10.0' },
    ]);
    const dump = JSON.stringify([
      env.DB.raw.prepare('SELECT * FROM installs').all(),
      env.DB.raw.prepare('SELECT * FROM install_days').all(),
    ]);
    expect(dump).not.toContain('203.0.113.9');
    expect(budgetUsed(env)).toBe(1);
  });

  it('同一安装同一天第二次心跳不写库、不扣预算', async () => {
    const env = makeEnv();
    await ping(env);
    const r = await ping(env, { version: '2.10.1' }, { now: NOW + 3600 * 1000 });
    expect(r.status).toBe(204);
    expect(count(env, 'install_days')).toBe(1);
    expect(env.DB.raw.prepare('SELECT version, last_seen FROM installs').get()).toEqual({ version: '2.10.0', last_seen: NOW });
    expect(budgetUsed(env)).toBe(1);
  });

  it('隔天心跳更新 installs 的最近版本，install_days 按天各一行', async () => {
    const env = makeEnv();
    await ping(env);
    await ping(env, { version: '2.11.0' }, { now: NOW + DAY });
    expect(count(env, 'install_days')).toBe(2);
    expect(env.DB.raw.prepare('SELECT first_seen, last_seen, version FROM installs').get())
      .toEqual({ first_seen: NOW, last_seen: NOW + DAY, version: '2.11.0' });
  });

  it.each([
    ['installId 不是 UUID v4', { installId: 'abc' }, 'bad_install_id'],
    ['installId 大写', { installId: A.toUpperCase() }, 'bad_install_id'],
    ['iOS 不收', { platform: 'ios' }, 'bad_platform'],
    ['未知通道', { channel: 'nightly' }, 'bad_channel'],
    ['版本串含空格', { version: '2.10 beta' }, 'bad_version'],
  ])('%s → 400', async (_name, body, code) => {
    const env = makeEnv();
    const r = await ping(env, body);
    expect(r.status).toBe(400);
    expect(r.data.error).toBe(code);
    expect(count(env, 'installs')).toBe(0);
  });

  it('ping 日预算打满 → 503，已记过的安装照常 204', async () => {
    const env = makeEnv({ BUDGET_PING: '1' });
    expect((await ping(env)).status).toBe(204);
    const r = await ping(env, { installId: B });
    expect(r.status).toBe(503);
    expect(r.data.error).toBe('daily_budget');
    expect((await ping(env)).status).toBe(204);
  });
});

describe('统计', () => {
  it('日活 / 周活 / 月活 / 分布按安装去重', async () => {
    const env = makeEnv();
    await ping(env, { installId: A }, { now: NOW - 20 * DAY });
    await ping(env, { installId: A, version: '2.11.0' }, { now: NOW });
    await ping(env, { installId: B, platform: 'android', channel: 'debug', version: '2.11.0-debug.9' }, { now: NOW - 3 * DAY });
    await ping(env, { installId: C, platform: 'linux' }, { now: NOW - 40 * DAY });
    const st = await installStats(env, NOW);
    expect(st).toMatchObject({ today: '2026-10-17', dau: 1, wau: 2, mau: 2, total: 3 });
    expect(st.daily[0]).toMatchObject({ day: '2026-10-17', n: 1, fresh: 0, platforms: { windows: 1, android: 0 } });
    expect(st.daily.find((d) => d.day === '2026-10-14')).toMatchObject({ n: 1, fresh: 1, platforms: { android: 1 } });
    expect(st.platforms).toEqual([{ key: 'android', n: 1 }, { key: 'windows', n: 1 }]);
    expect(st.channels).toEqual([{ key: 'debug', n: 1 }, { key: 'stable', n: 1 }]);
    expect(st.versions.map((v) => v.key).sort()).toEqual(['2.11.0', '2.11.0-debug.9']);
  });

  it('定时任务清掉超出保留期的记录', async () => {
    const env = makeEnv();
    const old = NOW - (INSTALL_LIMITS.retentionDays + 2) * DAY;
    await ping(env, { installId: A }, { now: old });
    await ping(env, { installId: B }, { now: NOW });
    await worker.scheduled({}, env, { waitUntil() {} }, NOW);
    expect(env.DB.raw.prepare('SELECT install_id FROM installs').all()).toEqual([{ install_id: B }]);
    expect(count(env, 'install_days')).toBe(1);
  });

  it('/dev/stats 需要开发者会话并显示数字', async () => {
    const env = makeEnv();
    await ping(env);
    expect((await call(env, 'GET', '/dev/stats', { now: NOW })).status).toBe(303);
    const page = await devPage(env, '/dev/stats');
    expect(page.status).toBe(200);
    expect(page.data).toContain('安装统计');
    expect(page.data).toContain('2026-10-17');
  });
});

describe('反馈关联安装', () => {
  async function submit(env, installId) {
    const r = await call(env, 'POST', '/v1/feedback', {
      body: { category: 'bug', title: `白屏 ${Math.random()}`, body: '正文', installId },
      headers: { 'CF-Connecting-IP': nextIp() },
      now: NOW,
    });
    expect(r.status).toBe(201);
    return r.data;
  }
  const installCol = (env, id) => env.DB.raw.prepare('SELECT install_id FROM feedback WHERE id = ?').get(id).install_id;

  it('合法 installId 落库；不合法或没带当 null，提交照常成功', async () => {
    const env = makeEnv();
    expect(installCol(env, (await submit(env, A)).id)).toBe(A);
    expect(installCol(env, (await submit(env, 'not-a-uuid')).id)).toBeNull();
    expect(installCol(env, (await submit(env, undefined)).id)).toBeNull();
  });

  it('处理台详情显示版本轨迹、同一安装的其它反馈与修复是否装上', async () => {
    const env = makeEnv({ FEEDBACK_CI_TOKEN: 'ci-token-0123456789abcdef' });
    await ping(env, { version: '2.10.0-debug.5', channel: 'debug' }, { now: NOW - 2 * DAY });
    await ping(env, { version: '2.10.0-debug.8', channel: 'debug' }, { now: NOW });
    const first = await submit(env, A);
    const second = await submit(env, A);
    const ci = { Authorization: 'Bearer ci-token-0123456789abcdef' };
    await call(env, 'POST', '/v1/ci/feedback/fixed', { body: { sha: 'a'.repeat(40), ids: [second.id], scope: 'app' }, headers: ci, now: NOW });
    await call(env, 'POST', '/v1/ci/feedback/released', {
      body: { channel: 'debug', platform: 'windows', version: '2.10.0-debug.7', ids: [{ id: second.id, sha: 'a'.repeat(40) }] },
      headers: ci,
      now: NOW,
    });
    const page = await devPage(env, `/dev/f/${second.id}`);
    expect(page.status).toBe(200);
    expect(page.data).toContain(A);
    expect(page.data).toContain('2.10.0-debug.5');
    expect(page.data).toContain(`/dev/f/${first.id}`);
    expect(page.data).toContain('已装上修复');
  });
});

describe('versionIncludes', () => {
  it.each([
    ['2.10.0', '2.10.0', true],
    ['2.10.0+123', '2.10.0', true],
    ['2.11.0', '2.10.0', true],
    ['2.9.9', '2.10.0', false],
    ['2.10.0-debug.8', '2.10.0-debug.7', true],
    ['2.10.0-debug.6', '2.10.0-debug.7', false],
    ['2.10.0-beta.9', '2.10.0-debug.7', null],
    ['2.10.0', '2.10.0-debug.7', null],
    ['', '2.10.0', null],
  ])('%s 包含 %s → %s', (installed, release, want) => {
    expect(versionIncludes(installed, release)).toBe(want);
  });
});
