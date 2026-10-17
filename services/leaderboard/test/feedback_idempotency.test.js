// 反馈提交幂等（2026-10-17，BUG-3489 审查）：客户端为「这一次提交」生成 submissionKey，重试复用。
// 同键再来 → 原样回同一张回执（同 id、同 ticket），不新建反馈、不撞「重复反馈」409、不再计限流。
import { describe, expect, it } from 'vitest';
import { call, makeEnv, nextIp } from './harness.js';
import { FEEDBACK_LIMITS } from '../src/feedback.js';

const NOW = Date.UTC(2026, 9, 17, 12);
const KEY = 'k'.repeat(20) + 'AbCdEf0123_-'; // 32 位 base64url
const KEY2 = 'z'.repeat(32);

function submit(env, body = {}, opts = {}) {
  return call(env, 'POST', '/v1/feedback', {
    body: { category: 'bug', title: '阅读器白屏', body: '打开某本书白屏', meta: { app: '2.0.0' }, ...body },
    headers: { 'CF-Connecting-IP': opts.ip ?? nextIp() },
    now: opts.now ?? NOW,
  });
}

const count = (env) => env.DB.raw.prepare('SELECT COUNT(*) n FROM feedback').get().n;

describe('反馈提交幂等（submissionKey）', () => {
  it('同键重试：同一张回执、只有一条反馈、回执能打开；库里不存键明文', async () => {
    const env = makeEnv();
    const ip = '203.0.113.9';
    const first = await submit(env, { submissionKey: KEY }, { ip });
    expect(first.status).toBe(201);
    // 同来源同内容在窗口内本会被判重桶拒收（409 duplicate_feedback）；同键必须按重放回。
    const again = await submit(env, { submissionKey: KEY }, { ip, now: NOW + 60_000 });
    expect(again.status).toBe(201);
    expect(again.data).toEqual(first.data);
    expect(count(env)).toBe(1);

    const view = await call(env, 'GET', `/v1/feedback/${first.data.id}`, {
      headers: { 'X-Fushi-Ticket': again.data.ticket }, now: NOW,
    });
    expect(view.status).toBe(200);
    const row = env.DB.raw.prepare('SELECT submission_hash, ticket_hash FROM feedback').get();
    expect(row.submission_hash).toMatch(/^[0-9a-f]{64}$/);
    expect(row.submission_hash).not.toContain(KEY);
    expect(row.ticket_hash).not.toBe(row.submission_hash);
  });

  it('重放发生在限流 / 判重 / 预算之前：IP 限流打满后同键重试照样拿回执', async () => {
    const env = makeEnv();
    const ip = '203.0.113.10';
    const first = await submit(env, { submissionKey: KEY, title: 'first' }, { ip });
    expect(first.status).toBe(201);
    for (let i = 1; i < FEEDBACK_LIMITS.submitPerIpHour; i++) {
      expect((await submit(env, { title: `fill ${i}` }, { ip })).status).toBe(201);
    }
    expect((await submit(env, { title: 'over' }, { ip })).status).toBe(429);
    const replay = await submit(env, { submissionKey: KEY, title: 'first' }, { ip });
    expect(replay.status).toBe(201);
    expect(replay.data.id).toBe(first.data.id);
    expect(count(env)).toBe(FEEDBACK_LIMITS.submitPerIpHour);
  });

  it('不同键 = 不同提交：内容不同各建一条；同来源同内容仍按重复拒收（判重桶不变）', async () => {
    const env = makeEnv();
    const ip = '203.0.113.11';
    const a = await submit(env, { submissionKey: KEY, title: 'A' }, { ip });
    const b = await submit(env, { submissionKey: KEY2, title: 'B' }, { ip });
    expect(a.status).toBe(201);
    expect(b.status).toBe(201);
    expect(b.data.id).not.toBe(a.data.id);
    expect(b.data.ticket).not.toBe(a.data.ticket);
    const dup = await submit(env, { submissionKey: 'q'.repeat(40), title: 'A' }, { ip });
    expect(dup.status).toBe(409);
    expect(dup.data.error).toBe('duplicate_feedback');
    expect(count(env)).toBe(2);
  });

  it('不带键：旧客户端 / 网页表单照旧，每次随机回执', async () => {
    const env = makeEnv();
    const a = await submit(env, { title: 'old A' });
    const b = await submit(env, { title: 'old B' });
    expect(a.status).toBe(201);
    expect(b.status).toBe(201);
    expect(a.data.ticket).toHaveLength(32);
    expect(a.data.ticket).not.toBe(b.data.ticket);
    expect(env.DB.raw.prepare('SELECT COUNT(*) n FROM feedback WHERE submission_hash IS NULL').get().n).toBe(2);
  });

  it('键格式不对 → 400，不建反馈', async () => {
    const env = makeEnv();
    for (const bad of ['short', 'x'.repeat(65), 'has space'.padEnd(40, 'x'), 123]) {
      const r = await submit(env, { submissionKey: bad });
      expect(r.status).toBe(400);
      expect(r.data.error).toBe('bad_submission_key');
    }
    expect(count(env)).toBe(0);
  });

  it('重新提交的同键重试：拿回同一条，不再核次数上限、不多占一次', async () => {
    const env = makeEnv();
    const orig = (await submit(env, { title: 'orig' })).data;
    await call(env, 'POST', `/v1/feedback/${orig.id}/close`, { headers: { 'X-Fushi-Ticket': orig.ticket }, now: NOW });
    const reopenOf = { id: orig.id, ticket: orig.ticket };
    const first = await submit(env, { title: 'reopen', submissionKey: KEY, reopenOf });
    expect(first.status).toBe(201);
    for (let i = 1; i < FEEDBACK_LIMITS.reopensPerFeedback; i++) {
      expect((await submit(env, { title: `more ${i}`, reopenOf })).status).toBe(201);
    }
    const replay = await submit(env, { title: 'reopen', submissionKey: KEY, reopenOf });
    expect(replay.status).toBe(201);
    expect(replay.data).toEqual(first.data);
    expect(replay.data.parentId).toBe(orig.id);
    expect(env.DB.raw.prepare('SELECT COUNT(*) n FROM feedback WHERE parent_id = ?').get(orig.id).n)
      .toBe(FEEDBACK_LIMITS.reopensPerFeedback);
  });

  it('同键并发：只建一条，成功的请求拿到的都是同一张回执', async () => {
    // 每次 D1 往返真实等待，两个请求都会在对方写入前查不到对方（唯一索引兜底）。
    const env = makeEnv({ d1DelayMs: 3 });
    const results = await Promise.all([0, 1, 2].map((i) => submit(env, { submissionKey: KEY }, { ip: `198.51.100.${i}` })));
    const ok = results.filter((r) => r.status === 201);
    expect(ok.length).toBe(3);
    for (const r of ok) expect(r.data).toEqual(ok[0].data);
    expect(count(env)).toBe(1);
  });

  it('唯一索引：同一个 submission_hash 不能写两行', () => {
    const env = makeEnv();
    const ins = env.DB.raw.prepare(
      `INSERT INTO feedback (id, ticket_hash, category, title, body, created_at, updated_at, submission_hash)
       VALUES (?, 'h', 'bug', 't', 'b', 0, 0, 'same')`,
    );
    ins.run('aaaaaaaaaa');
    expect(() => ins.run('bbbbbbbbbb')).toThrow(/UNIQUE/i);
  });
});
