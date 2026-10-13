// 跨设备看自己的工单：GET /v1/feedback/mine + 反馈人接口「ticket 或同账户签名」二选一。
import { describe, expect, it } from 'vitest';
import { call, makeEnv, nextIp, pngHeader, registerUser } from './harness.js';
import { FEEDBACK_LIMITS } from '../src/feedback.js';

const NOW = Date.UTC(2026, 9, 12, 12);
const PNG = pngHeader(320, 640);

function submit(env, { user = null, title = `t ${Math.random()}`, now = NOW } = {}) {
  return call(env, 'POST', '/v1/feedback', {
    body: { category: 'bug', title, body: '正文', contact: 'tg @me', meta: { app: '1.0' } },
    headers: { 'CF-Connecting-IP': nextIp() },
    now,
    ...(user ? { key: user.key, account: user.id } : {}),
  });
}

const signed = (env, u, method, path, body, headers = {}) => call(env, method, path, { key: u.key, account: u.id, body, headers, now: NOW });
const withTicket = (env, method, path, ticket, body) => call(env, method, path, { headers: { 'X-Fushi-Ticket': ticket }, body, now: NOW });

const SUMMARY_KEYS = ['category', 'createdAt', 'devReplyAt', 'fix', 'id', 'parentId', 'status', 'title', 'updatedAt', 'userReplyAt'];

describe('GET /v1/feedback/mine', () => {
  it('只列签名账户自己的，按创建时间倒序、游标分页；只给反馈人视角摘要；no-store', async () => {
    const env = makeEnv();
    const a = await registerUser(env, 'a', { now: NOW });
    const b = await registerUser(env, 'b', { now: NOW });
    const mine = [];
    for (let i = 0; i < 5; i++) mine.push((await submit(env, { user: a, title: `a${i}`, now: NOW + i })).data.id);
    // 同一毫秒的两条按 id 倒序稳定排。
    const tieA = (await submit(env, { user: a, title: 'tie1', now: NOW + 10 })).data.id;
    const tieB = (await submit(env, { user: a, title: 'tie2', now: NOW + 10 })).data.id;
    await submit(env, { user: b, title: 'b0' });
    await submit(env, { title: 'anon' });

    const expected = [...[tieA, tieB].sort().reverse(), ...[...mine].reverse()];
    const p1 = await signed(env, a, 'GET', '/v1/feedback/mine?limit=3');
    expect(p1.status).toBe(200);
    expect(p1.res.headers.get('Cache-Control')).toBe('no-store');
    expect(p1.data.items.map((x) => x.id)).toEqual(expected.slice(0, 3));
    expect(Object.keys(p1.data.items[0]).sort()).toEqual(SUMMARY_KEYS);
    expect(p1.data.next).toMatch(/^\d+:/);
    const p2 = await signed(env, a, 'GET', `/v1/feedback/mine?limit=3&cursor=${encodeURIComponent(p1.data.next)}`);
    expect(p2.data.items.map((x) => x.id)).toEqual(expected.slice(3, 6));
    const p3 = await signed(env, a, 'GET', `/v1/feedback/mine?limit=3&cursor=${encodeURIComponent(p2.data.next)}`);
    expect(p3.data.items.map((x) => x.id)).toEqual(expected.slice(6));
    expect(p3.data.next).toBeNull();

    // 默认 / 上限。
    const all = await signed(env, a, 'GET', '/v1/feedback/mine');
    expect(all.data.items).toHaveLength(7);
    expect(all.data.next).toBeNull();
    expect((await signed(env, a, 'GET', '/v1/feedback/mine?limit=999')).data.items).toHaveLength(7);
    expect(FEEDBACK_LIMITS.minePageMax).toBe(50);

    const bs = await signed(env, b, 'GET', '/v1/feedback/mine');
    expect(bs.data.items.map((x) => x.title)).toEqual(['b0']);
  });

  it('未签名 401；签名不对 401', async () => {
    const env = makeEnv();
    const a = await registerUser(env, 'a', { now: NOW });
    expect((await call(env, 'GET', '/v1/feedback/mine', { now: NOW })).status).toBe(401);
    const bad = await call(env, 'GET', '/v1/feedback/mine', { key: a.key, account: a.id, badSig: true, now: NOW });
    expect(bad.status).toBe(401);
  });
});

describe('反馈人接口：ticket 或同账户签名', () => {
  it('同账户签名能看详情、追加说明、取截图、标记完成；ticket 照旧可用', async () => {
    const env = makeEnv();
    const a = await registerUser(env, 'a', { now: NOW });
    const f = (await submit(env, { user: a })).data;
    expect((await withTicket(env, 'PUT', `/v1/feedback/${f.id}/attachments/s0`, f.ticket, PNG)).status).toBe(201);

    const d = await signed(env, a, 'GET', `/v1/feedback/${f.id}`);
    expect(d.status).toBe(200);
    expect(d.data).toMatchObject({ id: f.id, body: '正文' });
    expect(d.data.contact).toBeUndefined();
    expect(d.data.meta).toBeUndefined();
    expect(d.data.flags).toBeUndefined();

    const msg = await signed(env, a, 'POST', `/v1/feedback/${f.id}/messages`, { body: '换了台设备补充' });
    expect(msg.status).toBe(201);
    expect(msg.data.messages.at(-1)).toMatchObject({ author: 'user', body: '换了台设备补充' });

    const shot = await signed(env, a, 'GET', `/v1/feedback/${f.id}/attachments/s0`);
    expect(shot.status).toBe(200);
    expect(shot.res.headers.get('Content-Type')).toBe('image/png');

    const closed = await signed(env, a, 'POST', `/v1/feedback/${f.id}/close`);
    expect(closed.status).toBe(200);
    expect(closed.data.status).toBe('closed');

    // ticket 照旧。
    expect((await withTicket(env, 'GET', `/v1/feedback/${f.id}`, f.ticket)).data.status).toBe('closed');
    expect((await withTicket(env, 'POST', `/v1/feedback/${f.id}/messages`, f.ticket, { body: '又出现了' })).data.status).toBe('open');
  });

  it('越权：别人的 / 匿名提交的 / 不存在的，用签名一律 404；带了错 ticket 不回落到签名；什么都没带 404', async () => {
    const env = makeEnv();
    const a = await registerUser(env, 'a', { now: NOW });
    const b = await registerUser(env, 'b', { now: NOW });
    const fb = (await submit(env, { user: b })).data;
    const anon = (await submit(env)).data;
    const fa = (await submit(env, { user: a })).data;
    for (const f of [fb, anon]) {
      expect((await withTicket(env, 'PUT', `/v1/feedback/${f.id}/attachments/s0`, f.ticket, PNG)).status).toBe(201);
    }
    for (const id of [fb.id, anon.id, 'zzzzzzzzzz']) {
      expect((await signed(env, a, 'GET', `/v1/feedback/${id}`)).status, id).toBe(404);
      expect((await signed(env, a, 'POST', `/v1/feedback/${id}/messages`, { body: 'x' })).status, id).toBe(404);
      expect((await signed(env, a, 'POST', `/v1/feedback/${id}/close`)).status, id).toBe(404);
      expect((await signed(env, a, 'GET', `/v1/feedback/${id}/attachments/s0`)).status, id).toBe(404);
    }
    // 没被改动。
    const rowB = env.DB.raw.prepare('SELECT status, message_count FROM feedback WHERE id = ?').get(fb.id);
    expect(rowB).toEqual({ status: 'open', message_count: 0 });

    // 带了 ticket 就只认 ticket：错 ticket + 正确签名 → 404。
    const wrong = await call(env, 'GET', `/v1/feedback/${fa.id}`, {
      key: a.key, account: a.id, headers: { 'X-Fushi-Ticket': 'x'.repeat(32) }, now: NOW,
    });
    expect(wrong.status).toBe(404);
    // 什么都没带。
    expect((await call(env, 'GET', `/v1/feedback/${fa.id}`, { now: NOW })).status).toBe(404);
    expect((await call(env, 'POST', `/v1/feedback/${fa.id}/close`, { now: NOW })).status).toBe(404);
    // B 看不到 A 的。
    expect((await signed(env, b, 'GET', `/v1/feedback/${fa.id}`)).status).toBe(404);
    // 补传附件只认 ticket，签名不行。
    expect((await signed(env, a, 'PUT', `/v1/feedback/${fa.id}/attachments/s0`, PNG)).status).toBe(404);
  });

  it('签名写请求防重放：同一签名串第二次 401', async () => {
    const env = makeEnv();
    const a = await registerUser(env, 'a', { now: NOW });
    const f = (await submit(env, { user: a })).data;
    const opts = { key: a.key, account: a.id, body: { body: 'once' }, time: NOW, now: NOW };
    expect((await call(env, 'POST', `/v1/feedback/${f.id}/messages`, opts)).status).toBe(201);
    expect((await call(env, 'POST', `/v1/feedback/${f.id}/messages`, opts)).status).toBe(401);
  });

  it('删账户后签名不再可用；回执照旧', async () => {
    const env = makeEnv();
    const a = await registerUser(env, 'a', { now: NOW });
    const f = (await submit(env, { user: a })).data;
    expect((await signed(env, a, 'DELETE', '/v1/me')).status).toBe(204);
    expect((await signed(env, a, 'GET', '/v1/feedback/mine')).status).toBe(401);
    expect((await withTicket(env, 'GET', `/v1/feedback/${f.id}`, f.ticket)).status).toBe(200);
  });
});
