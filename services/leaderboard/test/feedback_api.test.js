// 反馈密钥与给 AI 代理用的反馈 JSON API（迁移 0026；src/feedback_api.js、/dev/keys 的反馈密钥一节）。
import { describe, expect, it } from 'vitest';
import { BASE, call, makeEnv, nextIp, pngHeader, registerUser } from './harness.js';
import { hex, sha256 } from '../src/util.js';
import { FEEDBACK_KEY_LIMITS, FEEDBACK_KEY_RE } from '../src/feedback_api.js';

const NOW = Date.UTC(2026, 10, 26, 12);
const DAY = 24 * 3600 * 1000;
const basic = { Authorization: `Basic ${btoa('admin:pw')}` };
const PNG = pngHeader(320, 640);

let seq = 0;
async function session(env, nickname, role) {
  const u = await registerUser(env, nickname, { now: NOW });
  expect((await call(env, 'POST', `/admin/api/accounts/${u.id}/role`, { headers: basic, body: { role }, now: NOW })).status).toBe(200);
  seq += 1;
  const token = `ftok${seq}`.padEnd(43, 'x');
  env.DB.raw.prepare('INSERT INTO dev_sessions (token_hash, account_id, expires_at) VALUES (?, ?, ?)')
    .run(hex(await sha256(new TextEncoder().encode(token))), u.id, NOW + DAY);
  return { user: u, cookie: `fushi_dev=${token}` };
}

function form(env, s, path, fields = {}, { origin = BASE } = {}) {
  return call(env, 'POST', path, {
    headers: { Cookie: s.cookie, Origin: origin, 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new TextEncoder().encode(new URLSearchParams(fields).toString()),
    now: NOW,
  });
}

async function issue(env, s, kind, label = '') {
  const r = await form(env, s, '/dev/keys', { label, kind });
  expect(r.status).toBe(200);
  const m = new RegExp(`<code>(${kind === 'feedback' ? 'ffk' : 'fdk'}_[A-Za-z0-9_-]{43})</code>`).exec(r.data);
  expect(m).not.toBeNull();
  return m[1];
}

function api(env, key, method, path, { body, headers = {}, now = NOW } = {}) {
  return call(env, method, path, { headers: { ...(key ? { Authorization: `Bearer ${key}` } : {}), ...headers }, body, now });
}

async function submit(env) {
  const r = await call(env, 'POST', '/v1/feedback', {
    body: { category: 'bug', title: '阅读器白屏', body: '打开某本书白屏', meta: { app: '1.2.3+45', platform: 'android' } },
    headers: { 'CF-Connecting-IP': nextIp() },
    now: NOW,
  });
  expect(r.status).toBe(201);
  await call(env, 'PUT', `/v1/feedback/${r.data.id}/attachments/s0`, { headers: { 'X-Fushi-Ticket': r.data.ticket }, body: PNG, now: NOW });
  return r.data;
}

const fbRow = (env, id) => env.DB.raw.prepare('SELECT * FROM feedback WHERE id = ?').get(id);

describe('/dev/keys 反馈密钥', () => {
  it('triage 能签发 / 吊销自己的反馈密钥；明文只出现一次、库里只存哈希；开发者两种都能签', async () => {
    const env = makeEnv();
    const tri = await session(env, 'helper', 'triage');
    const key = await issue(env, tri, 'feedback', '笔记本');
    expect(FEEDBACK_KEY_RE.test(key)).toBe(true);
    const page = await call(env, 'GET', '/dev/keys', { headers: { Cookie: tri.cookie }, now: NOW });
    expect(page.data).not.toContain(key);
    expect(page.data).toContain(`ffk_…${key.slice(-4)}`);
    expect(page.data).toContain('笔记本');
    const stored = env.DB.raw.prepare('SELECT * FROM feedback_api_keys').get();
    expect(stored.token_hash).toBe(hex(await sha256(new TextEncoder().encode(key))));
    expect(JSON.stringify(stored)).not.toContain(key);

    const dev = await session(env, 'dev', 'dev');
    expect(await issue(env, dev, 'decision')).toMatch(/^fdk_/);
    expect(await issue(env, dev, 'feedback')).toMatch(/^ffk_/);
    const devPage = await call(env, 'GET', '/dev/keys', { headers: { Cookie: dev.cookie }, now: NOW });
    expect(devPage.data).toContain('拍板台密钥');
    expect(devPage.data).toContain('反馈密钥');

    // 别人的、拍板台那条吊销路由都吊不掉；自己的能吊。
    expect((await form(env, dev, `/dev/fkeys/${stored.id}/revoke`)).status).toBe(404);
    expect((await form(env, tri, `/dev/keys/${stored.id}/revoke`)).status).toBe(403);
    expect((await form(env, tri, `/dev/fkeys/${stored.id}/revoke`, {}, { origin: 'https://evil.example' })).status).toBe(403);
    expect((await form(env, tri, `/dev/fkeys/${stored.id}/revoke`)).status).toBe(303);
    expect((await api(env, key, 'GET', '/v1/agent/feedback')).data.error).toBe('bad_feedback_key');
  });

  it('每种每人最多 5 把未吊销的，两种名额互不占用；未知 kind 400', async () => {
    const env = makeEnv();
    const dev = await session(env, 'dev', 'dev');
    for (let i = 0; i < FEEDBACK_KEY_LIMITS.activePerAccount; i += 1) await issue(env, dev, 'feedback');
    const full = await form(env, dev, '/dev/keys', { kind: 'feedback' });
    expect(full.data).toContain('最多 5 把');
    expect(full.data).not.toMatch(/<code>ffk_[A-Za-z0-9_-]{43}<\/code>/);
    expect(await issue(env, dev, 'decision')).toMatch(/^fdk_/);
    expect((await form(env, dev, '/dev/keys', { kind: 'admin' })).status).toBe(400);
  });
});

describe('/v1/agent/feedback', () => {
  it('凭反馈密钥读列表 / 详情 / 附件，与网页处理台同一份数据', async () => {
    const env = makeEnv();
    const tri = await session(env, 'helper', 'triage');
    const key = await issue(env, tri, 'feedback');
    const { id } = await submit(env);

    const list = await api(env, key, 'GET', '/v1/agent/feedback?status=all');
    expect(list.status).toBe(200);
    expect(list.res.headers.get('Cache-Control')).toBe('private, no-store');
    expect(list.data.items.map((x) => x.id)).toEqual([id]);
    const web = await call(env, 'GET', '/dev/feedback.json?status=all', { headers: { Cookie: tri.cookie }, now: NOW });
    expect(list.data).toEqual(web.data);

    const one = await api(env, key, 'GET', `/v1/agent/feedback/${id}`);
    expect(one.data.id).toBe(id);
    expect(one.data.body).toBe('打开某本书白屏');
    expect(one.data.devNote).toBeNull();
    const shot = await api(env, key, 'GET', `/v1/agent/feedback/${id}/a/s0`);
    expect(shot.status).toBe(200);
    expect(shot.res.headers.get('Content-Type')).toBe('image/png');
    expect((await api(env, key, 'GET', '/v1/agent/feedback/NoSuchId1')).status).toBe(404);
  });

  it('改批改要带 base：读到的那份没变才写，期间被改过 409 不覆盖；空串清除', async () => {
    const env = makeEnv();
    const tri = await session(env, 'helper', 'triage');
    const key = await issue(env, tri, 'feedback');
    const { id } = await submit(env);
    const note = (body) => api(env, key, 'POST', `/v1/agent/feedback/${id}/note`, { body });

    expect((await note({ devNote: '先写' })).data.error).toBe('base_required');
    const first = await note({ devNote: '第一版', base: null });
    expect(first.status).toBe(200);
    expect(first.data.devNote).toBe('第一版');
    expect(fbRow(env, id).dev_note).toBe('第一版');
    expect(fbRow(env, id).dev_note_at).toBe(NOW);

    // 网页上有人在这期间改了：拿旧 base 写 → 409，批改保持别人的版本。
    await form(env, tri, `/dev/f/${id}/note`, { devNote: '别人改的' });
    const stale = await note({ devNote: '第二版', base: '第一版' });
    expect(stale.status).toBe(409);
    expect(stale.data.error).toBe('note_changed');
    expect(fbRow(env, id).dev_note).toBe('别人改的');

    expect((await note({ devNote: '第二版', base: '别人改的' })).status).toBe(200);
    expect((await note({ devNote: '', base: '第二版' })).data.devNote).toBeNull();
    expect(fbRow(env, id).dev_note).toBeNull();
    expect(fbRow(env, id).dev_note_at).toBeNull();
    expect((await note({ devNote: 3, base: null })).status).toBe(400);
  });

  it('不开放回复 / 改状态；两种密钥互不通用；缺密钥 401；账户降成 user 后密钥失效', async () => {
    const env = makeEnv();
    const dev = await session(env, 'dev', 'dev');
    const fkey = await issue(env, dev, 'feedback');
    const dkey = await issue(env, dev, 'decision');
    const { id } = await submit(env);

    // 开发者的反馈密钥同样只有只读 + 批改。
    expect((await api(env, fkey, 'POST', `/v1/agent/feedback/${id}`, { body: { status: 'resolved', reply: 'x' } })).status).toBe(405);
    expect((await api(env, fkey, 'POST', `/v1/dev/feedback/${id}`, { body: { status: 'resolved', reply: 'x' } })).status).not.toBe(200);
    expect(fbRow(env, id).status).toBe('open');
    expect(env.DB.raw.prepare('SELECT COUNT(*) n FROM feedback_messages').get().n).toBe(0);

    expect((await api(env, dkey, 'GET', '/v1/agent/feedback')).data.error).toBe('feedback_key_required');
    expect((await api(env, fkey, 'GET', '/v1/decisions')).data.error).toBe('decision_key_required');
    expect((await api(env, null, 'GET', '/v1/agent/feedback')).status).toBe(401);
    expect((await api(env, `ffk_${'A'.repeat(43)}`, 'GET', '/v1/agent/feedback')).data.error).toBe('bad_feedback_key');

    // dev → triage 照常可用；→ user 失效。
    await call(env, 'POST', `/admin/api/accounts/${dev.user.id}/role`, { headers: basic, body: { role: 'triage' }, now: NOW });
    expect((await api(env, fkey, 'GET', '/v1/agent/feedback')).status).toBe(200);
    await call(env, 'POST', `/admin/api/accounts/${dev.user.id}/role`, { headers: basic, body: { role: 'user' }, now: NOW });
    expect((await api(env, fkey, 'GET', '/v1/agent/feedback')).data.error).toBe('bad_feedback_key');
  });

  it('last_used_at 最多每 10 分钟写一次', async () => {
    const env = makeEnv();
    const tri = await session(env, 'helper', 'triage');
    const key = await issue(env, tri, 'feedback');
    const used = () => env.DB.raw.prepare('SELECT last_used_at FROM feedback_api_keys').get().last_used_at;
    await api(env, key, 'GET', '/v1/agent/feedback');
    expect(used()).toBe(NOW);
    await api(env, key, 'GET', '/v1/agent/feedback', { now: NOW + 60_000 });
    expect(used()).toBe(NOW);
    await api(env, key, 'GET', '/v1/agent/feedback', { now: NOW + FEEDBACK_KEY_LIMITS.touchEveryMs });
    expect(used()).toBe(NOW + FEEDBACK_KEY_LIMITS.touchEveryMs);
  });
});
