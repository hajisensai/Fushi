// 反馈「修复 → 打包 → 发布」追踪（迁移 0009；CI 接口 /v1/ci/feedback/**）。
import { describe, expect, it } from 'vitest';
import { call, makeEnv, nextIp, registerUser } from './harness.js';
import { FEEDBACK_LIMITS } from '../src/feedback.js';

const NOW = Date.UTC(2026, 9, 13, 12);
const DAY = 24 * 3600 * 1000;
const TOKEN = 'ci-token-0123456789abcdef';
const SHA = 'a'.repeat(40);
const SHA2 = '0123456789abcdef0123456789abcdef01234567';
const basic = { Authorization: `Basic ${btoa('admin:pw')}` };

const ciEnv = () => makeEnv({ FEEDBACK_CI_TOKEN: TOKEN });

function ci(env, method, path, body, opts = {}) {
  return call(env, method, path, {
    body,
    now: opts.now ?? NOW,
    headers: opts.token === null ? {} : { Authorization: `Bearer ${opts.token ?? TOKEN}` },
  });
}

async function submit(env, title = '阅读器白屏') {
  const r = await call(env, 'POST', '/v1/feedback', {
    body: { category: 'bug', title, body: '正文' },
    headers: { 'CF-Connecting-IP': nextIp() },
    now: NOW - 10 * DAY,
  });
  expect(r.status).toBe(201);
  return r.data;
}

const fixed = (env, ids, sha = SHA, scope = 'app', now = NOW) => ci(env, 'POST', '/v1/ci/feedback/fixed', { sha, ids, scope }, { now });
const pending = (env, channel, platform, now = NOW) => ci(env, 'GET', `/v1/ci/feedback/pending?channel=${channel}&platform=${platform}`, undefined, { now });
const released = (env, body, now = NOW) => ci(env, 'POST', '/v1/ci/feedback/released', body, { now });
/** released 的一条：{id, sha}（CI 判过祖先关系的那个修复 commit）。 */
const rel = (id, sha = SHA) => ({ id, sha });
const row = (env, id) => env.DB.raw.prepare('SELECT * FROM feedback WHERE id = ?').get(id);

describe('CI 鉴权', () => {
  it('没配 FEEDBACK_CI_TOKEN：三个接口一律 404（带不带 token 都一样）', async () => {
    const env = makeEnv();
    const f = await submit(env);
    expect((await fixed(env, [f.id])).status).toBe(404);
    expect((await pending(env, 'debug', 'android')).status).toBe(404);
    expect((await released(env, { channel: 'debug', platform: 'android', version: '1.0.0', ids: [rel(f.id)] })).status).toBe(404);
    expect((await ci(env, 'GET', '/v1/ci/feedback/pending?channel=debug&platform=android', undefined, { token: null })).status).toBe(404);
    expect(row(env, f.id).fix_sha).toBeNull();
  });

  it('token 不对 / 没带 → 401；不存在的 CI 路径 404', async () => {
    const env = ciEnv();
    const f = await submit(env);
    expect((await ci(env, 'POST', '/v1/ci/feedback/fixed', { sha: SHA, ids: [f.id] }, { token: 'wrong' })).status).toBe(401);
    expect((await ci(env, 'POST', '/v1/ci/feedback/fixed', { sha: SHA, ids: [f.id] }, { token: null })).status).toBe(401);
    expect((await ci(env, 'GET', '/v1/ci/feedback/pending?channel=debug&platform=android', undefined, { token: `${TOKEN}x` })).status).toBe(401);
    expect((await ci(env, 'GET', '/v1/ci/feedback/nope')).status).toBe(404);
    expect(row(env, f.id).fix_sha).toBeNull();
  });
});

describe('POST /v1/ci/feedback/fixed', () => {
  it('写修复 commit；open / 处理中 → 已解决并记时间线；结案的状态不动；不存在的列进 missing', async () => {
    const env = ciEnv();
    const a = await submit(env, '甲');
    const b = await submit(env, '乙');
    env.DB.raw.prepare("UPDATE feedback SET status = 'wont_fix' WHERE id = ?").run(b.id);
    const r = await fixed(env, [a.id, b.id, 'missing123', a.id]);
    expect(r.status).toBe(200);
    expect(r.data).toEqual({ updated: [a.id, b.id], unchanged: [], missing: ['missing123'] });

    const ra = row(env, a.id);
    expect(ra).toMatchObject({ fix_sha: SHA, fix_scope: 'app', fix_at: NOW, fixed_in: '{}', status: 'resolved', dev_reply_at: NOW, updated_at: NOW });
    // 结案的不插时间线，也就不刷「开发者新消息」时刻（否则反馈人亮红点却没有新消息）。
    expect(row(env, b.id)).toMatchObject({ status: 'wont_fix', fix_sha: SHA, dev_reply_at: null, updated_at: NOW });
    const msgs = (id) => env.DB.raw.prepare('SELECT author, account_id, body, status, created_at FROM feedback_messages WHERE feedback_id = ?').all(id);
    expect(msgs(a.id)).toEqual([{ author: 'dev', account_id: null, body: '', status: 'resolved', created_at: NOW }]);
    expect(msgs(b.id)).toEqual([]);

    // 反馈人：批量进度与详情都带 fix。
    const s = await call(env, 'POST', '/v1/feedback/status', { body: { items: [{ id: a.id, ticket: a.ticket }] }, now: NOW });
    expect(s.data.items[0]).toMatchObject({ status: 'resolved', devReplyAt: NOW, fix: { sha: SHA, scope: 'app', at: NOW, releases: {} } });
    const d = await call(env, 'GET', `/v1/feedback/${a.id}`, { headers: { 'X-Fushi-Ticket': a.ticket }, now: NOW });
    expect(d.data.fix).toEqual({ sha: SHA, scope: 'app', at: NOW, releases: {} });
    expect(d.data.messages).toEqual([expect.objectContaining({ author: 'dev', status: 'resolved', body: '', nickname: null })]);
  });

  it('重复 fixed：新 commit 覆盖旧的并重置 fixed_in；已解决的不再插时间线', async () => {
    const env = ciEnv();
    const a = await submit(env);
    await fixed(env, [a.id]);
    await released(env, { channel: 'debug', platform: 'android', version: '2.3.0-debug.1', ids: [rel(a.id)] });
    expect(JSON.parse(row(env, a.id).fixed_in)).toEqual({ debug: { android: { version: '2.3.0-debug.1', at: NOW } } });
    const r = await fixed(env, [a.id], SHA2.toUpperCase(), 'none', NOW + 1000);
    expect(r.data.updated).toEqual([a.id]);
    // 已解决的重新标记：不插时间线，dev_reply_at 停在第一次标记修复的时刻。
    expect(row(env, a.id)).toMatchObject({ fix_sha: SHA2, fix_scope: 'none', fix_at: NOW + 1000, fixed_in: '{}', status: 'resolved', dev_reply_at: NOW, updated_at: NOW + 1000 });
    expect(env.DB.raw.prepare('SELECT COUNT(*) AS n FROM feedback_messages WHERE feedback_id = ?').get(a.id).n).toBe(1);
  });

  it('幂等：同 sha 同 scope 重复登记进 unchanged，发布进度 / fix_at / 时间线 / 更新时刻都不动；只换 scope 也算变更', async () => {
    const env = ciEnv();
    const a = await submit(env);
    const b = await submit(env, '乙');
    await fixed(env, [a.id]);
    await released(env, { channel: 'debug', platform: 'android', version: '2.3.0-debug.1', ids: [rel(a.id)] }, NOW + 5);
    const before = row(env, a.id);
    const again = await fixed(env, [a.id, b.id, 'missing123'], SHA.toUpperCase(), 'app', NOW + 100);
    expect(again.data).toEqual({ updated: [b.id], unchanged: [a.id], missing: ['missing123'] });
    expect(row(env, a.id)).toEqual(before);
    expect(JSON.parse(row(env, a.id).fixed_in).debug.android.version).toBe('2.3.0-debug.1');
    const count = () => env.DB.raw.prepare('SELECT COUNT(*) AS n FROM feedback_messages WHERE feedback_id = ?').get(a.id).n;
    expect(count()).toBe(1);
    // 反馈人重新打开后再同 sha 重复登记：依然不动（不重新标已解决、不插时间线）。
    env.DB.raw.prepare("UPDATE feedback SET status = 'open' WHERE id = ?").run(a.id);
    expect((await fixed(env, [a.id], SHA, 'app', NOW + 200)).data.unchanged).toEqual([a.id]);
    expect(row(env, a.id).status).toBe('open');
    expect(count()).toBe(1);
    // 只换 scope：照旧覆盖并重置。
    const scoped = await fixed(env, [a.id], SHA, 'none', NOW + 300);
    expect(scoped.data).toEqual({ updated: [a.id], unchanged: [], missing: [] });
    expect(row(env, a.id)).toMatchObject({ fix_scope: 'none', fix_at: NOW + 300, fixed_in: '{}', status: 'resolved', updated_at: NOW + 300 });
    expect(count()).toBe(2);
  });

  it('重新标记后，旧 sha 的 released 不写入（静默跳过）；新 sha（大写也认）照常写', async () => {
    const env = ciEnv();
    const a = await submit(env);
    await fixed(env, [a.id]);
    // CI 拿到 pending（旧 sha）后、回填前，开发者用新 commit 重新标记。
    expect((await pending(env, 'debug', 'android')).data.items).toEqual([{ id: a.id, sha: SHA }]);
    await fixed(env, [a.id], SHA2, 'app', NOW + 1);
    const body = { channel: 'debug', platform: 'android', version: '2.3.0-debug.1' };
    const stale = await released(env, { ...body, ids: [rel(a.id, SHA)] }, NOW + 2);
    expect(stale.status).toBe(200);
    expect(stale.data).toEqual({ updated: 0 });
    expect(row(env, a.id)).toMatchObject({ fixed_in: '{}', updated_at: NOW + 1 });
    expect((await pending(env, 'debug', 'android')).data.items).toEqual([{ id: a.id, sha: SHA2 }]);
    expect((await released(env, { ...body, version: '2.3.0-debug.2', ids: [rel(a.id, SHA2.toUpperCase())] }, NOW + 3)).data)
      .toEqual({ updated: 1 });
    expect(JSON.parse(row(env, a.id).fixed_in)).toEqual({ debug: { android: { version: '2.3.0-debug.2', at: NOW + 3 } } });
  });

  it('参数校验：sha 格式 / scope / ids 数量与格式', async () => {
    const env = ciEnv();
    const a = await submit(env);
    expect((await fixed(env, [a.id], 'abc')).data.error).toBe('bad_sha');
    expect((await fixed(env, [a.id], `${'g'.repeat(40)}`)).data.error).toBe('bad_sha');
    expect((await fixed(env, [a.id], `${SHA}0`)).data.error).toBe('bad_sha');
    expect((await fixed(env, [a.id], SHA, 'later')).data.error).toBe('bad_scope');
    expect((await fixed(env, [])).data.error).toBe('bad_ids');
    expect((await fixed(env, 'x')).data.error).toBe('bad_ids');
    expect((await fixed(env, ["x' OR 1=1"])).data.error).toBe('bad_id');
    const many = Array.from({ length: FEEDBACK_LIMITS.ciFixedIds + 1 }, (_, i) => `id${String(i).padStart(6, '0')}`);
    expect((await fixed(env, many)).data.error).toBe('too_many_ids');
    // scope 缺省 = app。
    expect((await ci(env, 'POST', '/v1/ci/feedback/fixed', { sha: SHA, ids: [a.id] })).status).toBe(200);
    expect(row(env, a.id).fix_scope).toBe('app');
  });
});

describe('GET /v1/ci/feedback/pending + POST /v1/ci/feedback/released', () => {
  it('pending 过滤：scope none、已回填的 channel.platform、180 天前的修复都不列', async () => {
    const env = ciEnv();
    const [a, b, c, d, e] = [await submit(env, 'a'), await submit(env, 'b'), await submit(env, 'c'), await submit(env, 'd'), await submit(env, 'e')];
    await fixed(env, [a.id, c.id]);
    await fixed(env, [b.id], SHA2, 'none');
    await fixed(env, [d.id], SHA2, 'app', NOW - FEEDBACK_LIMITS.ciPendingWindowMs - 1);
    // e 未标记修复。
    void e;
    const p = await pending(env, 'debug', 'android');
    expect(p.status).toBe(200);
    expect(p.data.items.map((x) => x.id).sort()).toEqual([a.id, c.id].sort());
    expect(p.data.items[0].sha).toBe(SHA);

    const r = await released(env, { channel: 'debug', platform: 'android', version: '2.3.0-debug.12345', ids: [rel(a.id)] }, NOW + 5);
    expect(r.data).toEqual({ updated: 1 });
    expect((await pending(env, 'debug', 'android')).data.items.map((x) => x.id)).toEqual([c.id]);
    // 别的通道 / 平台不受影响。
    expect((await pending(env, 'debug', 'windows')).data.items.map((x) => x.id).sort()).toEqual([a.id, c.id].sort());
    expect((await pending(env, 'stable', 'android')).data.items).toHaveLength(2);
  });

  it('released 只写首次（保留最早版本）；未标记修复的行不写；反馈人看到 releases', async () => {
    const env = ciEnv();
    const a = await submit(env);
    const plain = await submit(env, '没修');
    await fixed(env, [a.id]);
    const body = { channel: 'debug', platform: 'android', version: '2.3.0-debug.12345', ids: [rel(a.id), rel(plain.id)] };
    expect((await released(env, body, NOW + 10)).data).toEqual({ updated: 1 });
    expect((await released(env, { ...body, version: '2.3.0-debug.12399' }, NOW + 20)).data).toEqual({ updated: 0 });
    expect((await released(env, { ...body, channel: 'beta', version: '2.3.0-beta.12001' }, NOW + 30)).data).toEqual({ updated: 1 });
    // 回填不是开发者回复：dev_reply_at / updated_at 停在标记修复那一刻。
    expect(row(env, a.id)).toMatchObject({ dev_reply_at: NOW, updated_at: NOW });
    expect(row(env, plain.id).fixed_in).toBe('{}');

    const releases = {
      debug: { android: { version: '2.3.0-debug.12345', at: NOW + 10 } },
      beta: { android: { version: '2.3.0-beta.12001', at: NOW + 30 } },
    };
    const s = await call(env, 'POST', '/v1/feedback/status', { body: { items: [{ id: a.id, ticket: a.ticket }] }, now: NOW });
    expect(s.data.items[0].fix).toEqual({ sha: SHA, scope: 'app', at: NOW, releases });
    const d = await call(env, 'GET', `/v1/feedback/${a.id}`, { headers: { 'X-Fushi-Ticket': a.ticket }, now: NOW });
    expect(d.data.fix.releases).toEqual(releases);
  });

  it('参数校验：channel / platform 白名单、version 格式、ids 上限', async () => {
    const env = ciEnv();
    const a = await submit(env);
    await fixed(env, [a.id]);
    expect((await pending(env, 'nightly', 'android')).data.error).toBe('bad_channel');
    expect((await pending(env, 'debug', 'web')).data.error).toBe('bad_platform');
    expect((await pending(env, 'debug', 'android.x')).data.error).toBe('bad_platform');
    const ok = { channel: 'stable', platform: 'ios', version: '2.3.0', ids: [rel(a.id)] };
    // 每条必须是 {id, sha}：裸编号 / 坏编号 / 坏 sha 整批 400。
    expect((await released(env, { ...ok, ids: [a.id] })).data.error).toBe('bad_id');
    expect((await released(env, { ...ok, ids: [rel("x' OR 1=1")] })).data.error).toBe('bad_id');
    expect((await released(env, { ...ok, ids: [rel(a.id), rel(a.id, 'abc')] })).data.error).toBe('bad_sha');
    expect((await released(env, { ...ok, ids: [{ id: a.id }] })).data.error).toBe('bad_sha');
    expect((await released(env, { ...ok, channel: '__proto__' })).data.error).toBe('bad_channel');
    expect((await released(env, { ...ok, platform: 'ios"}' })).data.error).toBe('bad_platform');
    expect((await released(env, { ...ok, version: '2.3.0 beta' })).data.error).toBe('bad_version');
    expect((await released(env, { ...ok, version: 'v'.repeat(65) })).data.error).toBe('bad_version');
    expect((await released(env, { ...ok, version: 7 })).data.error).toBe('bad_version');
    const many = Array.from({ length: FEEDBACK_LIMITS.ciReleasedIds + 1 }, (_, i) => rel(`id${String(i).padStart(6, '0')}`));
    expect((await released(env, { ...ok, ids: many })).data.error).toBe('too_many_ids');
    expect((await released(env, { ...ok, ids: [] })).data.error).toBe('bad_ids');
    expect(row(env, a.id).fixed_in).toBe('{}');
    expect((await released(env, { ...ok, version: '2.3.0+45' })).data).toEqual({ updated: 1 });
  });
});

describe('CI 回填不冒充开发者回复', () => {
  async function makeDev(env) {
    const dev = await registerUser(env, 'dev', { now: NOW });
    expect((await call(env, 'POST', `/admin/api/accounts/${dev.id}/role`, { headers: basic, body: { role: 'dev' }, now: NOW })).status).toBe(200);
    return dev;
  }
  const awaiting = async (env, dev, id) => {
    const list = await call(env, 'GET', '/v1/dev/feedback?status=all', { key: dev.key, account: dev.id, now: NOW });
    return list.data.items.find((x) => x.id === id).awaitingDev;
  };
  const say = (env, f, text, now) => call(env, 'POST', `/v1/feedback/${f.id}/messages`, {
    headers: { 'X-Fushi-Ticket': f.ticket }, body: { body: text }, now,
  });

  it('标记修复后反馈人追问：多通道多平台回填都不冲掉「新消息」，dev_reply_at / updated_at 不动', async () => {
    const env = ciEnv();
    const dev = await makeDev(env);
    const a = await submit(env);
    await fixed(env, [a.id]);
    expect(row(env, a.id).dev_reply_at).toBe(NOW);
    expect((await say(env, a, '升级后还是白屏', NOW + 10)).status).toBeLessThan(300);
    expect(await awaiting(env, dev, a.id)).toBe(true);
    const before = row(env, a.id);

    let at = NOW + 100;
    for (const channel of ['debug', 'beta', 'stable']) {
      for (const platform of ['android', 'windows', 'macos', 'ios']) {
        at += 1;
        const r = await released(env, { channel, platform, version: channel === 'stable' ? '2.3.0' : `2.3.0-${channel}.1`, ids: [rel(a.id)] }, at);
        expect(r.data).toEqual({ updated: 1 });
      }
    }
    const after = row(env, a.id);
    expect({ dev_reply_at: after.dev_reply_at, updated_at: after.updated_at, user_reply_at: after.user_reply_at, status: after.status })
      .toEqual({ dev_reply_at: before.dev_reply_at, updated_at: before.updated_at, user_reply_at: before.user_reply_at, status: before.status });
    expect(Object.keys(JSON.parse(after.fixed_in)).sort()).toEqual(['beta', 'debug', 'stable']);
    expect(await awaiting(env, dev, a.id)).toBe(true);
    // 反馈人侧：摘要的 devReplyAt 也没被回填推后（App 拿它和 seenAt 比亮红点）。
    const s = await call(env, 'POST', '/v1/feedback/status', { body: { items: [{ id: a.id, ticket: a.ticket }] }, now: at });
    expect(s.data.items[0].devReplyAt).toBe(NOW);
  });

  it('对已结案的行重新标记修复：不插时间线，也不刷 dev_reply_at（「新消息」保留）', async () => {
    const env = ciEnv();
    const dev = await makeDev(env);
    const a = await submit(env);
    // 反馈人追问过、开发者已把它判成重复：追加说明不会把 duplicate 拉回 open。
    env.DB.raw.prepare("UPDATE feedback SET status = 'duplicate', dev_reply_at = ?2, user_reply_at = ?3 WHERE id = ?1").run(a.id, NOW - 20, NOW - 10);
    expect(await awaiting(env, dev, a.id)).toBe(true);
    const r = await fixed(env, [a.id], SHA, 'app', NOW + 5);
    expect(r.data.updated).toEqual([a.id]);
    expect(row(env, a.id)).toMatchObject({ status: 'duplicate', fix_sha: SHA, dev_reply_at: NOW - 20, user_reply_at: NOW - 10, updated_at: NOW + 5 });
    expect(env.DB.raw.prepare('SELECT COUNT(*) AS n FROM feedback_messages WHERE feedback_id = ?').get(a.id).n).toBe(0);
    expect(await awaiting(env, dev, a.id)).toBe(true);
  });
});

describe('开发者视图带 fix', () => {
  it('处理台列表 / 详情 / 网页详情都显示修复 commit 与发布版本', async () => {
    const env = ciEnv();
    const dev = await registerUser(env, 'dev', { now: NOW });
    expect((await call(env, 'POST', `/admin/api/accounts/${dev.id}/role`, { headers: basic, body: { role: 'dev' }, now: NOW })).status).toBe(200);
    const a = await submit(env);
    await fixed(env, [a.id]);
    await released(env, { channel: 'debug', platform: 'windows', version: '2.3.0-debug.7', ids: [rel(a.id)] });
    const as = (path) => call(env, 'GET', path, { key: dev.key, account: dev.id, now: NOW });
    const list = await as('/v1/dev/feedback?status=all');
    expect(list.data.items[0].fix).toMatchObject({ sha: SHA, scope: 'app', releases: { debug: { windows: { version: '2.3.0-debug.7' } } } });
    const detail = await as(`/v1/dev/feedback/${a.id}`);
    expect(detail.data.fix.sha).toBe(SHA);
    // 网页处理台详情（只读展示）。
    const token = 'tok'.padEnd(43, 'x');
    const { hex, sha256 } = await import('../src/util.js');
    env.DB.raw.prepare('INSERT INTO dev_sessions (token_hash, account_id, expires_at) VALUES (?, ?, ?)')
      .run(hex(await sha256(new TextEncoder().encode(token))), dev.id, NOW + DAY);
    const page = await call(env, 'GET', `/dev/f/${a.id}`, { headers: { Cookie: `fushi_dev=${token}` }, now: NOW });
    expect(page.status).toBe(200);
    expect(page.data).toContain(SHA);
    expect(page.data).toContain('2.3.0-debug.7');
    expect(page.data).toContain('调试版 · windows');
  });
});
