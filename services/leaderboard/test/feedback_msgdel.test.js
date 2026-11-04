// DELETE /v1/feedback/:id/messages/:mid：反馈人删除自己的一条追加说明。
import { describe, expect, it } from 'vitest';
import { call, makeEnv, nextIp } from './harness.js';

const NOW = Date.UTC(2026, 9, 12, 12);

async function submit(env) {
  return (await call(env, 'POST', '/v1/feedback', {
    body: { category: 'bug', title: `t ${Math.random()}`, body: '正文', contact: 'tg @me', meta: { app: '1.0' } },
    headers: { 'CF-Connecting-IP': nextIp() },
    now: NOW,
  })).data;
}
const tk = (env, method, path, ticket, body) => call(env, method, path, { headers: { 'X-Fushi-Ticket': ticket }, body, now: NOW });
const say = (env, f, text) => tk(env, 'POST', `/v1/feedback/${f.id}/messages`, f.ticket, { body: text });
const del = (env, f, mid, ticket = f.ticket) => tk(env, 'DELETE', `/v1/feedback/${f.id}/messages/${mid}`, ticket);
const addDev = (env, f, body) => env.DB.raw.prepare(
  'INSERT INTO feedback_messages (feedback_id, author, body, status, created_at) VALUES (?, \'dev\', ?, NULL, ?)',
).run(f.id, body, NOW).lastInsertRowid;

describe('DELETE /v1/feedback/:id/messages/:mid', () => {
  it('删自己的追加说明成功，时间线里没了，message_count 不回退', async () => {
    const env = makeEnv();
    const f = await submit(env);
    const r = await say(env, f, '补错了');
    const mid = r.data.messages.at(-1).id;
    const d = await del(env, f, mid);
    expect(d.status).toBe(200);
    expect(d.data.messages.some((m) => m.id === mid)).toBe(false);
    expect(env.DB.raw.prepare('SELECT message_count FROM feedback WHERE id = ?').get(f.id).message_count).toBe(1);
    expect((await del(env, f, mid)).status).toBe(404);
  });

  it('用错 ticket 404，不删', async () => {
    const env = makeEnv();
    const f = await submit(env);
    const g = await submit(env);
    const mid = (await say(env, f, 'x')).data.messages.at(-1).id;
    expect((await del(env, f, mid, g.ticket)).status).toBe(404);
    expect((await del(env, g, mid)).status).toBe(404);
    expect(env.DB.raw.prepare('SELECT COUNT(*) AS n FROM feedback_messages WHERE id = ?').get(mid).n).toBe(1);
  });

  it('开发者消息 / 状态事件 / 不存在的 id 一律 404', async () => {
    const env = makeEnv();
    const f = await submit(env);
    const devId = addDev(env, f, '已收到');
    expect((await del(env, f, devId)).status).toBe(404);
    expect((await del(env, f, 999999)).status).toBe(404);
    const c = await tk(env, 'POST', `/v1/feedback/${f.id}/close`, f.ticket);
    const ev = c.data.messages.at(-1);
    expect(ev).toMatchObject({ author: 'user', body: '', status: 'closed' });
    expect((await del(env, f, ev.id)).status).toBe(404);
  });

  it('其后已有开发者回复时 409 dev_replied，不删', async () => {
    const env = makeEnv();
    const f = await submit(env);
    const mid = (await say(env, f, '补充')).data.messages.at(-1).id;
    addDev(env, f, '看过了');
    const d = await del(env, f, mid);
    expect(d.status).toBe(409);
    expect(JSON.stringify(d.data)).toContain('dev_replied');
    expect(env.DB.raw.prepare('SELECT body FROM feedback_messages WHERE id = ?').get(mid).body).toBe('补充');
  });

  it('带 status 的那条（重新打开）只清空 body，保留事件', async () => {
    const env = makeEnv();
    const f = await submit(env);
    await tk(env, 'POST', `/v1/feedback/${f.id}/close`, f.ticket);
    const r = await say(env, f, '又出现了');
    expect(r.data.status).toBe('open');
    const mid = r.data.messages.at(-1).id;
    const d = await del(env, f, mid);
    expect(d.status).toBe(200);
    expect(d.data.messages.find((m) => m.id === mid)).toMatchObject({ author: 'user', body: '', status: 'open' });
    // 空 body 的事件再删 → 404。
    expect((await del(env, f, mid)).status).toBe(404);
  });
});
