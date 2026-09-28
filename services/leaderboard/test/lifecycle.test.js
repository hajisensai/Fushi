import { describe, expect, it } from 'vitest';
import { JPEG, call, entry, makeEnv, registerUser } from './harness.js';

const NOW = Date.UTC(2026, 8, 30, 12);
const done = { finishedAt: NOW - 1000, finishedDate: '2026-09-30' };

async function upload(env, u, entries) {
  const r = await call(env, 'POST', '/v1/shelf', { key: u.key, account: u.id, body: { reset: true, put: entries }, now: NOW });
  return r.data.works;
}

const basic = (u, p) => ({ Authorization: `Basic ${btoa(`${u}:${p}`)}` });

describe('头像与封面', () => {
  it('头像：只收图片魔数，换头像删旧对象，出图带 immutable 缓存', async () => {
    const env = makeEnv();
    const u = await registerUser(env, 'tom', { now: NOW });
    const notImg = await call(env, 'PUT', '/v1/me/avatar', { key: u.key, account: u.id, body: new Uint8Array([1, 2, 3]), now: NOW });
    expect(notImg.status).toBe(415);
    const a1 = await call(env, 'PUT', '/v1/me/avatar', { key: u.key, account: u.id, body: JPEG, now: NOW });
    const a2 = await call(env, 'PUT', '/v1/me/avatar', { key: u.key, account: u.id, body: JPEG, now: NOW + 1 });
    expect(a1.status).toBe(200);
    expect([...env.MEDIA.store.keys()]).toEqual([a2.data.avatar.slice(5)]);
    const img = await call(env, 'GET', a2.data.avatar, { now: NOW });
    expect(img.res.headers.get('Content-Type')).toBe('image/jpeg');
    expect(img.res.headers.get('Cache-Control')).toContain('immutable');
  });

  it('封面：只有在架的人能传，先到先得', async () => {
    const env = makeEnv();
    const a = await registerUser(env, 'a', { now: NOW });
    const b = await registerUser(env, 'b', { now: NOW });
    const outsider = await registerUser(env, 'c', { now: NOW });
    const [w] = await upload(env, a, [entry('book', ['t:x|'], 'x')]);
    await upload(env, b, [entry('book', ['t:x|'], 'x')]);
    expect(w.needsCover).toBe(true);
    const path = `/v1/works/${w.workId}/cover`;
    expect((await call(env, 'PUT', path, { key: outsider.key, account: outsider.id, body: JPEG, now: NOW })).status).toBe(403);
    expect((await call(env, 'PUT', path, { key: a.key, account: a.id, body: JPEG, now: NOW })).status).toBe(200);
    const late = await call(env, 'PUT', path, { key: b.key, account: b.id, body: JPEG, now: NOW });
    expect(late.status).toBe(409);
    expect(env.MEDIA.store.size).toBe(1); // 输家的对象已删
  });
});

describe('删除账户', () => {
  it('删掉账户的全部行与头像；独有作品随之消失，共享作品保留', async () => {
    const env = makeEnv();
    const a = await registerUser(env, 'a', { now: NOW });
    const b = await registerUser(env, 'b', { now: NOW });
    await upload(env, a, [entry('book', ['t:mine|'], 'mine', done), entry('book', ['t:shared|'], 'shared', done)]);
    await upload(env, b, [entry('book', ['t:shared|'], 'shared', done)]);
    await call(env, 'PUT', '/v1/me/avatar', { key: a.key, account: a.id, body: JPEG, now: NOW });
    const [a1, b1] = [a.id, b.id].sort();
    env.DB.raw.prepare("INSERT INTO friends (a, b, requester, state, created_at) VALUES (?1, ?2, ?1, 'accepted', 0)").run(a1, b1);

    const r = await call(env, 'DELETE', '/v1/me', { key: a.key, account: a.id, now: NOW });
    expect(r.status).toBe(204);
    const count = (sql) => env.DB.raw.prepare(sql).get().n;
    expect(count(`SELECT COUNT(*) n FROM accounts WHERE id = '${a.id}'`)).toBe(0);
    expect(count(`SELECT COUNT(*) n FROM shelf WHERE account_id = '${a.id}'`)).toBe(0);
    expect(count('SELECT COUNT(*) n FROM friends')).toBe(0);
    expect(env.MEDIA.store.size).toBe(0);
    expect(env.DB.raw.prepare('SELECT title FROM works').all().map((w) => w.title)).toEqual(['shared']);
    // 共享作品的读者数随删除减一（增量维护，不现场 COUNT）。
    expect(env.DB.raw.prepare('SELECT readers FROM works').get().readers).toBe(1);
    // 周期读者数同步减一（本周、本月各一行，只剩 b）。
    expect(env.DB.raw.prepare('SELECT period, n FROM work_periods ORDER BY period').all().map((r) => [r.period, r.n]))
      .toEqual([['m:2026-09', 1], ['w:2026-09-28', 1]]);
    // 删除后同一把钥匙的签名请求失效。
    expect((await call(env, 'GET', '/v1/me', { key: a.key, account: a.id, now: NOW })).status).toBe(401);
  });
});

describe('管理端', () => {
  it('没配置凭据 fail-closed；凭据错 401', async () => {
    const env = makeEnv({ ADMIN_USER: '', ADMIN_PASS: '' });
    expect((await call(env, 'GET', '/admin/api/reports', { now: NOW })).status).toBe(503);
    const env2 = makeEnv();
    expect((await call(env2, 'GET', '/admin/api/reports', { headers: basic('admin', 'nope'), now: NOW })).status).toBe(401);
    expect((await call(env2, 'GET', '/admin/api/reports', { headers: basic('admin', 'pw'), now: NOW })).status).toBe(200);
  });

  it('合并：别名与书架迁到目标作品，同一用户两边都有时合并为一行', async () => {
    const env = makeEnv();
    const a = await registerUser(env, 'a', { now: NOW });
    const b = await registerUser(env, 'b', { now: NOW });
    const [w1, w2] = await upload(env, a, [
      entry('book', ['t:saekano 1|'], 'saekano 1', { ...done, chars: 10 }),
      entry('book', ['t:冴えない 1|'], '冴えない 1', { chars: 5 }),
    ]);
    await upload(env, b, [entry('book', ['t:冴えない 1|'], '冴えない 1', done)]);
    const r = await call(env, 'POST', '/admin/api/works/merge', {
      headers: basic('admin', 'pw'), body: { from: w2.workId, into: w1.workId }, now: NOW,
    });
    expect(r.status).toBe(200);
    expect(env.DB.raw.prepare('SELECT COUNT(*) n FROM works').get().n).toBe(1);
    const aRow = env.DB.raw.prepare('SELECT * FROM shelf WHERE account_id = ?1').get(a.id);
    expect(aRow.chars).toBe(15);
    expect(aRow.finished_at).toBe(done.finishedAt);
    const readers = await call(env, 'GET', `/v1/works/${w1.workId}`, { now: NOW });
    expect(readers.data.readers).toBe(2);
    // 之后任何人上报旧别名都落到合并后的作品。
    const c = await registerUser(env, 'c', { now: NOW });
    const [w] = await upload(env, c, [entry('book', ['t:冴えない 1|'], 'x')]);
    expect(w.workId).toBe(w1.workId);
  });

  it('拆分：误挂的别名带着当初按它解析进来的书架行一起迁走', async () => {
    const env = makeEnv();
    const a = await registerUser(env, 'a', { now: NOW });
    const b = await registerUser(env, 'b', { now: NOW });
    // a 先上报：同名但不同作者的书只剩标题键，被误并。
    const [wa] = await upload(env, a, [entry('book', ['isbn:9780000000001', 't:同名|'], '同名', done)]);
    await upload(env, b, [entry('book', ['t:同名|'], '同名', done)]);
    const before = await call(env, 'GET', `/v1/works/${wa.workId}`, { now: NOW });
    expect(before.data.readers).toBe(2);

    const r = await call(env, 'POST', '/admin/api/works/split', { headers: basic('admin', 'pw'), body: { ref: 'book|t:同名|' }, now: NOW });
    expect(r.status).toBe(200);
    const newId = r.data.workId;
    // a 是按 isbn 解析进来的，留在原作品；b 只有标题键，跟着别名走。
    expect(env.DB.raw.prepare('SELECT work_id FROM shelf WHERE account_id = ?1').get(a.id).work_id).toBe(wa.workId);
    expect(env.DB.raw.prepare('SELECT work_id FROM shelf WHERE account_id = ?1').get(b.id).work_id).toBe(newId);
  });

  it('隐藏账户、改作品标题即锁定（之后上报不再回写众数）', async () => {
    const env = makeEnv();
    const a = await registerUser(env, 'a', { now: NOW });
    const [w] = await upload(env, a, [entry('book', ['t:x|'], 'typo')]);
    await call(env, 'POST', `/admin/api/works/${w.workId}`, { headers: basic('admin', 'pw'), body: { title: 'Fixed' }, now: NOW });
    await upload(env, a, [entry('book', ['t:x|'], 'typo')]);
    expect(env.DB.raw.prepare('SELECT title, locked FROM works').get()).toEqual({ title: 'Fixed', locked: 1 });
    const h = await call(env, 'POST', `/admin/api/accounts/${a.id}`, { headers: basic('admin', 'pw'), body: { hidden: true }, now: NOW });
    expect(h.status).toBe(200);
    expect((await call(env, 'GET', `/v1/users/${a.id}`, { now: NOW })).status).toBe(404);
  });
});
