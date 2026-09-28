import { describe, expect, it } from 'vitest';
import { call, entry, makeEnv, registerUser } from './harness.js';
import { windowStartKey } from '../src/views.js';

// 2026-09-30 是周三：本周从 09-28 起，本月从 09-01 起。
const NOW = Date.UTC(2026, 8, 30, 12);
const at = (date) => ({ finishedAt: Date.parse(`${date}T10:00:00Z`), finishedDate: date });

async function upload(env, u, entries, daily = []) {
  const r = await call(env, 'POST', '/v1/shelf', { key: u.key, account: u.id, body: { reset: true, put: entries, daily }, now: NOW });
  if (r.status !== 200) throw new Error(JSON.stringify(r.data));
  return r.data.works;
}

async function rank(env, query, viewer) {
  const opts = viewer ? { key: viewer.key, account: viewer.id, now: NOW } : { now: NOW };
  return call(env, 'GET', `/v1/rank?${query}`, opts);
}

function befriend(env, x, y) {
  const [a, b] = [x.id, y.id].sort();
  env.DB.raw.prepare("INSERT INTO friends (a, b, requester, state, created_at) VALUES (?1, ?2, ?1, 'accepted', 0)").run(a, b);
}

describe('窗口', () => {
  it('week = 本周一（UTC），month = 本月 1 日，all = null', () => {
    expect(windowStartKey('week', NOW)).toBe('2026-09-28');
    expect(windowStartKey('week', Date.UTC(2026, 8, 28, 0))).toBe('2026-09-28');
    expect(windowStartKey('week', Date.UTC(2026, 8, 27, 23))).toBe('2026-09-21');
    expect(windowStartKey('month', NOW)).toBe('2026-09-01');
    expect(windowStartKey('all', NOW)).toBeNull();
  });
});

describe('榜单', () => {
  async function seed() {
    const env = makeEnv();
    const a = await registerUser(env, 'alice', { now: NOW });
    const b = await registerUser(env, 'bob', { now: NOW });
    const c = await registerUser(env, 'carol', { now: NOW });
    await upload(env, a, [
      entry('book', ['t:a1|'], 'a1', at('2026-09-29')),
      entry('book', ['t:a2|'], 'a2', at('2026-09-10')),
      entry('book', ['t:a3|'], 'a3', at('2025-01-01')),
      entry('book', ['t:a4|'], 'a4'), // 在读，不计
    ], [{ date: '2026-09-29', chars: 1000 }, { date: '2026-08-01', chars: 5000 }]);
    await upload(env, b, [
      entry('book', ['t:b1|'], 'b1', at('2026-09-28')),
      entry('book', ['t:b2|'], 'b2', at('2026-09-29')),
      entry('manga', ['t:m1|'], 'm1', at('2026-09-29')),
    ], [{ date: '2026-09-30', chars: 3000 }]);
    await upload(env, c, [entry('game', ['vndb:v1'], 'g1', { finished: true })]);
    return { env, a, b, c };
  }

  it('本周书榜：bob 2 > alice 1；在读与窗口外不计', async () => {
    const { env } = await seed();
    const r = await rank(env, 'metric=book&window=week');
    expect(r.data.from).toBe('2026-09-28');
    expect(r.data.rows.map((x) => [x.rank, x.account.nickname, x.value])).toEqual([[1, 'bob', 2], [2, 'alice', 1]]);
    expect(r.data.total).toBe(2);
  });

  it('月榜 / 总榜', async () => {
    const { env } = await seed();
    const month = await rank(env, 'metric=book&window=month');
    expect(month.data.rows.map((x) => [x.account.nickname, x.value]).sort()).toEqual([['alice', 2], ['bob', 2]]);
    expect(month.data.rows.map((x) => x.rank)).toEqual([1, 1]); // 并列同名次
    const all = await rank(env, 'metric=book&window=all');
    expect(all.data.rows[0]).toMatchObject({ rank: 1, value: 3 });
  });

  it('漫画与书分开计', async () => {
    const { env } = await seed();
    const r = await rank(env, 'metric=manga&window=all');
    expect(r.data.rows.map((x) => [x.account.nickname, x.value])).toEqual([['bob', 1]]);
  });

  it('日期未知的读完只进总榜', async () => {
    const { env } = await seed();
    expect((await rank(env, 'metric=game&window=week')).data.rows).toEqual([]);
    expect((await rank(env, 'metric=game&window=all')).data.rows.map((x) => x.value)).toEqual([1]);
  });

  it('字数榜按天切窗', async () => {
    const { env } = await seed();
    const week = await rank(env, 'metric=chars&window=week');
    expect(week.data.rows.map((x) => [x.account.nickname, x.value])).toEqual([['bob', 3000], ['alice', 1000]]);
    const all = await rank(env, 'metric=chars&window=all');
    expect(all.data.rows.map((x) => [x.account.nickname, x.value])).toEqual([['alice', 6000], ['bob', 3000]]);
  });

  it('签名请求返回「我的名次」', async () => {
    const { env, a } = await seed();
    const r = await rank(env, 'metric=book&window=week', a);
    expect(r.data.me).toEqual({ rank: 2, value: 1 });
  });

  it('同日读完计分上限 30；日期未知的不被合并截断', async () => {
    const env = makeEnv();
    const a = await registerUser(env, 'bulk', { now: NOW });
    const entries = [];
    for (let i = 0; i < 40; i++) entries.push(entry('book', [`t:same-day-${i}|`], `s${i}`, at('2026-09-29')));
    for (let i = 0; i < 40; i++) entries.push(entry('book', [`t:unknown-${i}|`], `u${i}`, { finished: true }));
    await upload(env, a, entries);
    expect((await rank(env, 'metric=book&window=week')).data.rows[0].value).toBe(30);
    expect((await rank(env, 'metric=book&window=all')).data.rows[0].value).toBe(70);
  });

  it('隐藏第一名后，后面的人名次顶上来（快照本身排除隐藏账户，而不只是展示时过滤）', async () => {
    const { env, b } = await seed();
    const { setAccountHidden } = await import('../src/admin.js');
    await setAccountHidden(env, b.id, true, NOW);
    const r = await rank(env, 'metric=book&window=week');
    expect(r.data.total).toBe(1);
    expect(r.data.rows.map((x) => [x.rank, x.account.nickname])).toEqual([[1, 'alice']]);
  });

  it('被管理员隐藏的账户不上榜；屏蔽双方互相看不到', async () => {
    const { env, a, b } = await seed();
    env.DB.raw.prepare('INSERT INTO blocks (account_id, blocked_id, created_at) VALUES (?1, ?2, 0)').run(a.id, b.id);
    const seenByBob = await rank(env, 'metric=book&window=all', b);
    expect(seenByBob.data.rows.map((x) => x.account.nickname)).toEqual(['bob']);
    env.DB.raw.prepare('UPDATE accounts SET hidden = 1 WHERE id = ?1').run(b.id);
    const anon = await rank(env, 'metric=book&window=all');
    expect(anon.data.rows.map((x) => x.account.nickname)).toEqual(['alice']);
  });

  it('好友榜只含本人与已接受的好友；匿名请求好友榜 401', async () => {
    const { env, a, b } = await seed();
    expect((await rank(env, 'metric=book&window=all&scope=friends')).status).toBe(401);
    const solo = await rank(env, 'metric=book&window=all&scope=friends', a);
    expect(solo.data.rows.map((x) => x.account.nickname)).toEqual(['alice']);
    befriend(env, a, b);
    const withBob = await rank(env, 'metric=book&window=all&scope=friends', a);
    expect(withBob.data.rows.map((x) => x.account.nickname).sort()).toEqual(['alice', 'bob']);
  });

  it('参数非法 → 400', async () => {
    const env = makeEnv();
    expect((await rank(env, 'metric=pages')).status).toBe(400);
    expect((await rank(env, 'window=year')).status).toBe(400);
  });
});

describe('用户主页 / 书架 / 作品页', () => {
  async function seed() {
    const env = makeEnv();
    const tom = await registerUser(env, 'tom', { now: NOW });
    const readers = [];
    for (const n of ['r1', 'r2', 'r3']) readers.push(await registerUser(env, n, { now: NOW }));
    const saekano = entry('book', ['isbn:9784040000011'], '冴えない彼女の育てかた 11', { author: '丸戸 史明', ...at('2026-09-09') });
    const other = entry('book', ['isbn:9784040000010'], '冴えない彼女の育てかた 10', { author: '丸戸 史明', ...at('2026-09-08') });
    const works = await upload(env, tom, [saekano, other, entry('video', ['anidb:9'], 'reading-now')], [
      { date: '2026-07-28', chars: 10 },
    ]);
    for (const r of readers) await upload(env, r, [saekano]);
    return { env, tom, readers, workId: works[0].workId };
  }

  it('卡片：各类读完数与名次、首条记录日', async () => {
    const { env, tom } = await seed();
    const r = await call(env, 'GET', `/v1/users/${tom.id}`, { now: NOW });
    expect(r.status).toBe(200);
    expect(r.data.account.nickname).toBe('tom');
    expect(r.data.stats.book).toEqual({ value: 2, rank: 1 });
    expect(r.data.stats.video).toEqual({ value: 0, rank: null });
    expect(r.data.stats.chars).toEqual({ value: 10, rank: 1 });
    expect(r.data.firstRecordDate).toBe('2026-07-28');
    expect(r.data.shelfVisible).toBe(true);
  });

  it('书架：按读完时间倒序，带读者人数与读者墙（不含主人自己）', async () => {
    const { env, tom } = await seed();
    const r = await call(env, 'GET', `/v1/users/${tom.id}/shelf`, { now: NOW });
    expect(r.data.rows.map((x) => x.work.title)).toEqual(['冴えない彼女の育てかた 11', '冴えない彼女の育てかた 10']);
    const first = r.data.rows[0];
    expect(first.work.author).toBe('丸戸 史明');
    expect(first.finishedDate).toBe('2026-09-09');
    expect(first.readers).toBe(4);
    expect(first.wall.map((a) => a.nickname).sort()).toEqual(['r1', 'r2', 'r3']);
    const reading = await call(env, 'GET', `/v1/users/${tom.id}/shelf?status=reading`, { now: NOW });
    expect(reading.data.rows.map((x) => x.work.title)).toEqual(['reading-now']);
  });

  it('仅好友可见：陌生人 403，好友 200；该用户仍计入读者人数但不出现在陌生人的读者墙', async () => {
    const { env, tom, readers, workId } = await seed();
    const [r1, r2] = readers;
    await call(env, 'PATCH', '/v1/me', { key: r1.key, account: r1.id, body: { visibility: 'friends' }, now: NOW });
    expect((await call(env, 'GET', `/v1/users/${r1.id}/shelf`, { now: NOW })).status).toBe(403);
    befriend(env, r1, r2);
    const asFriend = await call(env, 'GET', `/v1/users/${r1.id}/shelf`, { key: r2.key, account: r2.id, now: NOW });
    expect(asFriend.status).toBe(200);

    const anon = await call(env, 'GET', `/v1/works/${workId}`, { now: NOW });
    expect(anon.data.readers).toBe(4);
    expect(anon.data.rows.map((x) => x.account.nickname).sort()).toEqual(['r2', 'r3', 'tom']);
    // 读者墙同一规则：仅好友可见的 r1 不出现在陌生人看到的 tom 书架读者墙里，好友能看到。
    const anonWall = await call(env, 'GET', `/v1/users/${tom.id}/shelf`, { now: NOW });
    expect(anonWall.data.rows[0].wall.map((x) => x.nickname).sort()).toEqual(['r2', 'r3']);
    const friendWall = await call(env, 'GET', `/v1/users/${tom.id}/shelf`, { key: r2.key, account: r2.id, now: NOW });
    expect(friendWall.data.rows[0].wall.map((x) => x.nickname)).toContain('r1');
    const friendView = await call(env, 'GET', `/v1/works/${workId}`, { key: r2.key, account: r2.id, now: NOW });
    // 作品页读者列表沿索引按读完时间倒序（有界分页）；仅好友可见的 r1 只对好友出现。
    expect(friendView.data.rows.map((x) => x.account.nickname).sort()).toEqual(['r1', 'r2', 'r3', 'tom']);
  });

  it('读者墙好友优先', async () => {
    const env = makeEnv();
    const owner = await registerUser(env, 'owner', { now: NOW });
    const viewer = await registerUser(env, 'viewer', { now: NOW });
    const others = [];
    for (let i = 0; i < 9; i++) others.push(await registerUser(env, `o${i}`, { now: NOW }));
    const friend = await registerUser(env, 'friend', { now: NOW });
    const e = (date) => entry('book', ['t:wall|'], 'wall', at(date));
    await upload(env, owner, [e('2026-09-20')]);
    await upload(env, friend, [e('2026-09-01')]); // 最早读完：不靠好友优先就挤不进前 8
    for (const o of others) await upload(env, o, [e('2026-09-25')]);
    befriend(env, viewer, friend);
    const shelf = await call(env, 'GET', `/v1/users/${owner.id}/shelf`, { key: viewer.key, account: viewer.id, now: NOW });
    const wall = shelf.data.rows[0].wall.map((a) => a.nickname);
    expect(wall).toHaveLength(8);
    expect(wall[0]).toBe('friend');
    const anon = await call(env, 'GET', `/v1/users/${owner.id}/shelf`, { now: NOW });
    expect(anon.data.rows[0].wall.map((a) => a.nickname)).not.toContain('friend');
  });

  it('被隐藏或互相屏蔽的主页 404', async () => {
    const { env, tom, readers } = await seed();
    env.DB.raw.prepare('INSERT INTO blocks (account_id, blocked_id, created_at) VALUES (?1, ?2, 0)').run(tom.id, readers[0].id);
    const blocked = await call(env, 'GET', `/v1/users/${tom.id}`, { key: readers[0].key, account: readers[0].id, now: NOW });
    expect(blocked.status).toBe(404);
    env.DB.raw.prepare('UPDATE accounts SET hidden = 1 WHERE id = ?1').run(tom.id);
    expect((await call(env, 'GET', `/v1/users/${tom.id}`, { now: NOW })).status).toBe(404);
  });

  it('作品人气榜：按窗口内读完人数', async () => {
    const { env } = await seed();
    const r = await call(env, 'GET', '/v1/works/popular?window=month', { now: NOW });
    expect(r.data.rows.map((x) => [x.rank, x.readers, x.work.title])).toEqual([
      [1, 4, '冴えない彼女の育てかた 11'],
      [2, 1, '冴えない彼女の育てかた 10'],
    ]);
  });
});
