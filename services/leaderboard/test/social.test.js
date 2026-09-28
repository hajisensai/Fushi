import { describe, expect, it } from 'vitest';
import { call, entry, makeEnv, registerUser } from './harness.js';
import { LIMITS } from '../src/ratelimit.js';

const NOW = Date.UTC(2026, 8, 30, 12);
const basic = { Authorization: `Basic ${btoa('admin:pw')}` };

/** 以 u 的身份发签名请求。 */
function as(env, u, method, path, body) {
  return call(env, method, path, { key: u.key, account: u.id, body, now: NOW });
}

async function hide(env, u) {
  const r = await call(env, 'POST', `/admin/api/accounts/${u.id}`, { headers: basic, body: { hidden: true }, now: NOW });
  expect(r.status).toBe(200);
}

async function three() {
  const env = makeEnv();
  const a = await registerUser(env, 'alice', { now: NOW });
  const b = await registerUser(env, 'bob', { now: NOW });
  const c = await registerUser(env, 'carol', { now: NOW });
  return { env, a, b, c };
}

const ids = (list) => list.map((x) => x.account.id);

describe('好友', () => {
  it('申请 → 对方列表里是 incoming、自己是 outgoing；对方回加即 accepted', async () => {
    const { env, a, b } = await three();
    const req = await as(env, a, 'POST', `/v1/friends/${b.id}`);
    expect(req.status).toBe(200);
    expect(req.data).toEqual({ state: 'pending' });
    // 重复申请：仍是 pending，不会自己把自己「接受」掉。
    expect((await as(env, a, 'POST', `/v1/friends/${b.id}`)).data).toEqual({ state: 'pending' });

    const la = await as(env, a, 'GET', '/v1/friends');
    expect(la.data.friends).toEqual([]);
    expect(ids(la.data.outgoing)).toEqual([b.id]);
    expect(la.data.outgoing[0]).toEqual({
      account: { id: b.id, nickname: 'bob', discriminator: b.discriminator, avatar: null },
      at: NOW,
    });
    const lb = await as(env, b, 'GET', '/v1/friends');
    expect(ids(lb.data.incoming)).toEqual([a.id]);
    expect(lb.data.outgoing).toEqual([]);

    const acc = await call(env, 'POST', `/v1/friends/${a.id}`, { key: b.key, account: b.id, now: NOW + 5000 });
    expect(acc.data).toEqual({ state: 'accepted' });
    const after = await as(env, a, 'GET', '/v1/friends');
    expect(after.data.friends).toEqual([{ account: expect.objectContaining({ id: b.id }), since: NOW + 5000 }]);
    expect(after.data.incoming).toEqual([]);
    expect(after.data.outgoing).toEqual([]);
    // 有序对：一对人永远只有一行。
    expect(env.DB.raw.prepare('SELECT COUNT(*) n FROM friends').get().n).toBe(1);
    const row = env.DB.raw.prepare('SELECT * FROM friends').get();
    expect(row.a < row.b).toBe(true);
    expect(row.requester).toBe(a.id);
  });

  it('接受后成为好友：好友榜与 friends 可见书架立刻生效', async () => {
    const { env, a, b } = await three();
    await as(env, b, 'PATCH', '/v1/me', { visibility: 'friends' });
    await as(env, b, 'POST', '/v1/shelf', { entries: [entry('book', ['t:x|'], 'x', { finishedAt: NOW - 1, finishedDate: '2026-09-30' })] });
    expect((await as(env, a, 'GET', `/v1/users/${b.id}/shelf`)).status).toBe(403);
    await as(env, a, 'POST', `/v1/friends/${b.id}`);
    await as(env, b, 'POST', `/v1/friends/${a.id}`);
    expect((await as(env, a, 'GET', `/v1/users/${b.id}/shelf`)).status).toBe(200);
    const r = await as(env, a, 'GET', '/v1/rank?metric=book&window=all&scope=friends');
    expect(r.data.rows.map((x) => x.account.id)).toEqual([b.id]);
  });

  it('删除：撤回自己的申请 / 拒绝对方的申请 / 删好友都是 204，不存在也 204', async () => {
    const { env, a, b, c } = await three();
    await as(env, a, 'POST', `/v1/friends/${b.id}`);
    expect((await as(env, a, 'DELETE', `/v1/friends/${b.id}`)).status).toBe(204); // 撤回
    expect((await as(env, b, 'GET', '/v1/friends')).data.incoming).toEqual([]);
    await as(env, a, 'POST', `/v1/friends/${b.id}`);
    expect((await as(env, b, 'DELETE', `/v1/friends/${a.id}`)).status).toBe(204); // 拒绝
    expect((await as(env, a, 'GET', '/v1/friends')).data.outgoing).toEqual([]);
    await as(env, a, 'POST', `/v1/friends/${b.id}`);
    await as(env, b, 'POST', `/v1/friends/${a.id}`);
    expect((await as(env, b, 'DELETE', `/v1/friends/${a.id}`)).status).toBe(204); // 删好友
    expect((await as(env, a, 'GET', '/v1/friends')).data.friends).toEqual([]);
    expect((await as(env, a, 'DELETE', `/v1/friends/${c.id}`)).status).toBe(204);
    expect((await as(env, a, 'DELETE', '/v1/friends/nobody')).status).toBe(204);
  });

  it('自己加自己 400；目标不存在 / 被隐藏 404', async () => {
    const { env, a, b } = await three();
    expect((await as(env, a, 'POST', `/v1/friends/${a.id}`)).status).toBe(400);
    expect((await as(env, a, 'POST', '/v1/friends/doesNotExist0000')).status).toBe(404);
    await hide(env, b);
    const r = await as(env, a, 'POST', `/v1/friends/${b.id}`);
    expect(r.status).toBe(404);
    expect(env.DB.raw.prepare('SELECT COUNT(*) n FROM friends').get().n).toBe(0);
  });

  it('被隐藏账户从好友 / 申请列表里消失', async () => {
    const { env, a, b, c } = await three();
    await as(env, a, 'POST', `/v1/friends/${b.id}`);
    await as(env, b, 'POST', `/v1/friends/${a.id}`);
    await as(env, c, 'POST', `/v1/friends/${a.id}`);
    const before = await as(env, a, 'GET', '/v1/friends');
    expect(ids(before.data.friends)).toEqual([b.id]);
    expect(ids(before.data.incoming)).toEqual([c.id]);
    await hide(env, b);
    await hide(env, c);
    const after = await as(env, a, 'GET', '/v1/friends');
    expect(after.data).toEqual({ friends: [], incoming: [], outgoing: [] });
  });

  it('任一方屏蔽了另一方 → 403 blocked，且不落行', async () => {
    const { env, a, b, c } = await three();
    await as(env, b, 'POST', `/v1/blocks/${a.id}`);
    const r1 = await as(env, a, 'POST', `/v1/friends/${b.id}`); // 被对方屏蔽
    expect(r1.status).toBe(403);
    expect(r1.data.error).toBe('blocked');
    const r2 = await as(env, b, 'POST', `/v1/friends/${a.id}`); // 自己屏蔽了对方
    expect(r2.status).toBe(403);
    expect(env.DB.raw.prepare('SELECT COUNT(*) n FROM friends').get().n).toBe(0);
    // 解除后可以加。
    await as(env, b, 'DELETE', `/v1/blocks/${a.id}`);
    expect((await as(env, a, 'POST', `/v1/friends/${b.id}`)).data).toEqual({ state: 'pending' });
    // 与第三人无关。
    expect((await as(env, a, 'POST', `/v1/friends/${c.id}`)).status).toBe(200);
  });

  it('屏蔽检查在写语句里也生效（与并发屏蔽之间不留缝）', async () => {
    const { env, a, b } = await three();
    const { addFriend } = await import('../src/social.js');
    // 模拟「前置检查之后、写入之前」屏蔽落库：让前置查询看不到 blocks。
    const realPrepare = env.DB.prepare;
    env.DB.prepare = (sql) => realPrepare(sql.startsWith('SELECT 1 AS ok FROM blocks') ? 'SELECT 1 AS ok WHERE ?1 IS NULL AND ?2 IS NULL' : sql);
    env.DB.raw.prepare('INSERT INTO blocks (account_id, blocked_id, created_at) VALUES (?1, ?2, 0)').run(b.id, a.id);
    await expect(addFriend(env, a, b.id, NOW)).rejects.toMatchObject({ status: 403, code: 'blocked' });
    env.DB.prepare = realPrepare;
    expect(env.DB.raw.prepare('SELECT COUNT(*) n FROM friends').get().n).toBe(0);
  });
});

describe('屏蔽', () => {
  it('屏蔽删掉双方好友关系与任一方向的申请；列表 / 解除', async () => {
    const { env, a, b, c } = await three();
    await as(env, a, 'POST', `/v1/friends/${b.id}`);
    await as(env, b, 'POST', `/v1/friends/${a.id}`);
    await as(env, c, 'POST', `/v1/friends/${a.id}`);
    expect((await as(env, a, 'POST', `/v1/blocks/${b.id}`)).status).toBe(204);
    expect((await as(env, a, 'POST', `/v1/blocks/${c.id}`)).status).toBe(204);
    expect((await as(env, a, 'POST', `/v1/blocks/${c.id}`)).status).toBe(204); // 幂等
    expect((await as(env, a, 'GET', '/v1/friends')).data).toEqual({ friends: [], incoming: [], outgoing: [] });
    expect((await as(env, c, 'GET', '/v1/friends')).data.outgoing).toEqual([]);
    const list = await as(env, a, 'GET', '/v1/blocks');
    expect(list.data.blocked.map((x) => x.id).sort()).toEqual([b.id, c.id].sort());
    expect(list.data.blocked[0]).toHaveProperty('nickname');
    // 被屏蔽的人只看到自己的列表，看不到屏蔽关系。
    expect((await as(env, b, 'GET', '/v1/blocks')).data.blocked).toEqual([]);

    expect((await as(env, a, 'DELETE', `/v1/blocks/${b.id}`)).status).toBe(204);
    expect((await as(env, a, 'DELETE', `/v1/blocks/${b.id}`)).status).toBe(204); // 不存在也 204
    expect((await as(env, a, 'GET', '/v1/blocks')).data.blocked.map((x) => x.id)).toEqual([c.id]);
  });

  it('屏蔽自己 400；目标不存在 / 被隐藏 404；隐藏账户不出现在屏蔽列表', async () => {
    const { env, a, b, c } = await three();
    expect((await as(env, a, 'POST', `/v1/blocks/${a.id}`)).status).toBe(400);
    expect((await as(env, a, 'POST', '/v1/blocks/doesNotExist0000')).status).toBe(404);
    await as(env, a, 'POST', `/v1/blocks/${c.id}`);
    await hide(env, b);
    await hide(env, c);
    expect((await as(env, a, 'POST', `/v1/blocks/${b.id}`)).status).toBe(404);
    expect((await as(env, a, 'GET', '/v1/blocks')).data.blocked).toEqual([]);
  });

  it('屏蔽后互相从榜单与主页消失（沿用 views.js 规则）', async () => {
    const { env, a, b } = await three();
    await as(env, a, 'POST', `/v1/blocks/${b.id}`);
    expect((await as(env, b, 'GET', `/v1/users/${a.id}`)).status).toBe(404);
    expect((await as(env, a, 'GET', `/v1/users/${b.id}`)).status).toBe(404);
  });
});

describe('举报', () => {
  it('举报账户与作品 → 201 {id}；同一目标未处理举报去重，处理后可再举报', async () => {
    const { env, a, b } = await three();
    const [w] = (await as(env, b, 'POST', '/v1/shelf', { entries: [entry('book', ['t:x|'], 'x')] })).data.works;
    const r1 = await as(env, a, 'POST', '/v1/reports', { targetKind: 'account', targetId: b.id, reason: '昵称冒犯' });
    expect(r1.status).toBe(201);
    expect(typeof r1.data.id).toBe('number');
    const r2 = await as(env, a, 'POST', '/v1/reports', { targetKind: 'account', targetId: b.id, reason: '更新理由' });
    expect(r2.status).toBe(201);
    expect(r2.data.id).toBe(r1.data.id);
    const rows = env.DB.raw.prepare('SELECT * FROM reports').all();
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ reporter: a.id, target_kind: 'account', target_id: b.id, reason: '更新理由', resolved: 0 });

    const rw = await as(env, a, 'POST', '/v1/reports', { targetKind: 'work', targetId: w.workId, reason: '封面' });
    expect(rw.status).toBe(201);
    expect(rw.data.id).not.toBe(r1.data.id);
    // 另一个举报人对同一目标是另一条。
    const rb = await as(env, b, 'POST', '/v1/reports', { targetKind: 'work', targetId: w.workId });
    expect(rb.data.id).not.toBe(rw.data.id);

    await call(env, 'POST', `/admin/api/reports/${r1.data.id}/resolve`, { headers: basic, now: NOW });
    const again = await as(env, a, 'POST', '/v1/reports', { targetKind: 'account', targetId: b.id, reason: '又来了' });
    expect(again.status).toBe(201);
    expect(again.data.id).not.toBe(r1.data.id);
    expect(env.DB.raw.prepare('SELECT COUNT(*) n FROM reports WHERE resolved = 0').get().n).toBe(3);
  });

  it('参数校验：kind、id 形状、理由 ≤ 500 字符、目标须存在、不能举报自己', async () => {
    const { env, a, b } = await three();
    const post = (body) => as(env, a, 'POST', '/v1/reports', body);
    expect((await post({ targetKind: 'user', targetId: b.id })).status).toBe(400);
    expect((await post({ targetKind: 'account', targetId: 'bad id!' })).status).toBe(400);
    expect((await post({ targetKind: 'account', targetId: b.id, reason: 5 })).status).toBe(400);
    expect((await post({ targetKind: 'account', targetId: b.id, reason: '字'.repeat(501) })).status).toBe(400);
    expect((await post({ targetKind: 'account', targetId: b.id, reason: '字'.repeat(500) })).status).toBe(201);
    expect((await post({ targetKind: 'account', targetId: 'doesNotExist0000' })).status).toBe(404);
    expect((await post({ targetKind: 'work', targetId: 'doesNotExist0000' })).status).toBe(404);
    expect((await post({ targetKind: 'account', targetId: a.id })).status).toBe(400);
    const notJson = await call(env, 'POST', '/v1/reports', { key: a.key, account: a.id, body: new TextEncoder().encode('{'), now: NOW });
    expect(notJson.status).toBe(400);
  });
});

describe('社交接口的鉴权与限流', () => {
  const writes = (id) => [
    ['POST', `/v1/friends/${id}`, undefined],
    ['DELETE', `/v1/friends/${id}`, undefined],
    ['POST', `/v1/blocks/${id}`, undefined],
    ['DELETE', `/v1/blocks/${id}`, undefined],
    ['POST', '/v1/reports', { targetKind: 'account', targetId: id }],
  ];

  it('未签名 401（读写都要签名）；读接口带错签名 401', async () => {
    const { env, b } = await three();
    for (const [method, path, body] of [['GET', '/v1/friends'], ['GET', '/v1/blocks'], ...writes(b.id)]) {
      const r = await call(env, method, path, { body, now: NOW });
      expect([method, path, r.status]).toEqual([method, path, 401]);
    }
    const bad = await call(env, 'GET', '/v1/friends', { key: b.key, account: b.id, badSig: true, now: NOW });
    expect(bad.status).toBe(401);
  });

  it('写请求同一签名第二次到达 → 401 replayed', async () => {
    const { env, a, b } = await three();
    for (const [method, path, body] of writes(b.id)) {
      const opts = { key: a.key, account: a.id, body, time: NOW + 7, now: NOW };
      const first = await call(env, method, path, opts);
      expect(first.status).toBeLessThan(300);
      const replay = await call(env, method, path, opts);
      expect([method, path, replay.status, replay.data.error]).toEqual([method, path, 401, 'replayed']);
    }
  });

  it(`社交写按账户每小时 ${LIMITS.socialWritePerHour} 次限流（与别人的桶互不影响）`, async () => {
    const { env, a, b, c } = await three();
    for (let i = 0; i < LIMITS.socialWritePerHour; i++) {
      const r = await as(env, a, i % 2 ? 'DELETE' : 'POST', `/v1/friends/${b.id}`);
      expect(r.status).toBeLessThan(300);
    }
    const over = await as(env, a, 'POST', `/v1/blocks/${b.id}`);
    expect(over.status).toBe(429);
    expect((await as(env, c, 'POST', `/v1/friends/${b.id}`)).status).toBe(200);
    // 下一个小时窗口恢复。
    // 显式 time：不推进 harness 的单调签名时钟，免得后续用例的签名时刻落到一小时后。
    const next = NOW + 3600 * 1000;
    const later = await call(env, 'POST', `/v1/friends/${b.id}`, { key: a.key, account: a.id, time: next, now: next });
    expect(later.status).toBe(200);
  });

  it('删除账户时连带清掉屏蔽与社交限流桶', async () => {
    const { env, a, b } = await three();
    await as(env, a, 'POST', `/v1/blocks/${b.id}`);
    await as(env, b, 'POST', '/v1/reports', { targetKind: 'account', targetId: a.id });
    expect((await as(env, a, 'DELETE', '/v1/me')).status).toBe(204);
    const count = (sql, ...args) => env.DB.raw.prepare(sql).get(...args).n;
    expect(count('SELECT COUNT(*) n FROM blocks')).toBe(0);
    expect(count('SELECT COUNT(*) n FROM reports')).toBe(0);
    expect(count('SELECT COUNT(*) n FROM rate_limits WHERE bucket = ?1', `social:${a.id}`)).toBe(0);
  });
});
