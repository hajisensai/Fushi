import { describe, expect, it } from 'vitest';
import { call, entry, makeEnv, registerUser } from './harness.js';
import { acceptCoverUrl, normalizeUpload } from '../src/shelf.js';

const NOW = Date.UTC(2026, 8, 30, 12);
const DAY = 24 * 3600 * 1000;

async function upload(env, u, entries, daily = []) {
  return call(env, 'POST', '/v1/shelf', { key: u.key, account: u.id, body: { entries, daily }, now: NOW });
}

function works(env) {
  return env.DB.raw.prepare('SELECT * FROM works ORDER BY created_at, id').all();
}

function aliases(env) {
  return Object.fromEntries(env.DB.raw.prepare('SELECT ref, work_id FROM work_aliases').all().map((r) => [r.ref, r.work_id]));
}

describe('上报校验', () => {
  it('非法 kind / ref / 未来的读完时刻 → 400 并带下标', () => {
    expect(() => normalizeUpload({ entries: [entry('novel', ['t:x'], 'x')] }, NOW)).toThrow(/0: kind/);
    expect(() => normalizeUpload({ entries: [entry('book', ['foo:x'], 'x')] }, NOW)).toThrow(/0: ref/);
    expect(() => normalizeUpload({ entries: [entry('book', ['t:x\ny'], 'x')] }, NOW)).toThrow(/0: ref/);
    expect(() =>
      normalizeUpload({ entries: [entry('book', ['t:x'], 'x', { finishedAt: NOW + DAY, finishedDate: '2026-10-01' })] }, NOW),
    ).toThrow(/finishedAt/);
    expect(() =>
      normalizeUpload({ entries: [entry('book', ['t:x'], 'x', { finishedAt: NOW })] }, NOW),
    ).toThrow(/finishedDate/);
  });

  it('finishedDate 必须与 finishedAt 的 UTC 日期相差一天以内（防摊到未来日期刷周榜）', () => {
    const ok = (d) => normalizeUpload({ entries: [entry('book', ['t:x'], 'x', { finishedAt: NOW, finishedDate: d })] }, NOW);
    expect(() => ok('2026-09-29')).not.toThrow();
    expect(() => ok('2026-10-01')).not.toThrow();
    expect(() => ok('2031-01-01')).toThrow(/finishedDate/);
    expect(() => ok('2026-09-27')).toThrow(/finishedDate/);
  });

  it('同一条目同一命名空间只能有一个键', () => {
    expect(() => normalizeUpload({ entries: [entry('book', ['bgm:1', 'bgm:2'], 'x')] }, NOW)).toThrow(/duplicate_namespace/);
  });

  it('三态：在读 / 读完日期未知 / 读完有日期', () => {
    const { entries } = normalizeUpload({
      entries: [
        entry('game', ['vndb:v1'], 'a'),
        entry('game', ['vndb:v2'], 'b', { finished: true }),
        entry('game', ['vndb:v3'], 'c', { finishedAt: NOW, finishedDate: '2026-09-30' }),
      ],
    }, NOW);
    expect(entries.map((e) => [e.finishedAt, e.finishedDate])).toEqual([[null, null], [0, null], [NOW, '2026-09-30']]);
  });

  it('封面 URL 只收白名单主机的 https', () => {
    expect(acceptCoverUrl('https://image.tmdb.org/t/p/w300/a.jpg')).toBe('https://image.tmdb.org/t/p/w300/a.jpg');
    expect(acceptCoverUrl('http://image.tmdb.org/a.jpg')).toBeNull();
    expect(acceptCoverUrl('https://evil.example/a.jpg')).toBeNull();
    expect(acceptCoverUrl('https://image.tmdb.org.evil.example/a.jpg')).toBeNull();
  });

  it('每日字数超上限被夹到 400000', () => {
    const { daily } = normalizeUpload({ entries: [], daily: [{ date: '2026-09-30', chars: 9_000_000 }] }, NOW);
    expect(daily).toEqual([{ date: '2026-09-30', chars: 400000 }]);
  });
});

describe('跨用户作品匹配', () => {
  it('ISBN 与「标题+作者」两路汇合到同一作品', async () => {
    const env = makeEnv();
    const a = await registerUser(env, 'a', { now: NOW });
    const b = await registerUser(env, 'b', { now: NOW });
    const c = await registerUser(env, 'c', { now: NOW });
    // A 只有标题键；B 有 ISBN + 同一标题键；C 只有 ISBN。
    await upload(env, a, [entry('book', ['t:冴えない|丸戸史明'], '冴えない 1', { author: '丸戸 史明' })]);
    await upload(env, b, [entry('book', ['isbn:9784040000001', 't:冴えない|丸戸史明'], '冴えない 1')]);
    const rc = await upload(env, c, [entry('book', ['isbn:9784040000001'], '冴えない彼女の育てかた 1')]);
    expect(works(env)).toHaveLength(1);
    const al = aliases(env);
    expect(al['book|isbn:9784040000001']).toBe(al['book|t:冴えない|丸戸史明']);
    expect(rc.data.works[0].workId).toBe(al['book|isbn:9784040000001']);
  });

  it('两个键分别指向不同作品时，按上报顺序（优先级）取第一个', async () => {
    const env = makeEnv();
    const a = await registerUser(env, 'a', { now: NOW });
    const b = await registerUser(env, 'b', { now: NOW });
    const c = await registerUser(env, 'c', { now: NOW });
    const [byIsbn] = await upload(env, a, [entry('book', ['isbn:9780000000002'], 'x')]).then((r) => r.data.works);
    const [byTitle] = await upload(env, b, [entry('book', ['t:x|'], 'x')]).then((r) => r.data.works);
    expect(byIsbn.workId).not.toBe(byTitle.workId);
    const [resolved] = await upload(env, c, [entry('book', ['isbn:9780000000002', 't:x|'], 'x')]).then((r) => r.data.works);
    expect(resolved.workId).toBe(byIsbn.workId);
    // 已存在的键不被改挂。
    expect(aliases(env)['book|t:x|']).toBe(byTitle.workId);
  });

  it('同一个键在不同 kind 下是不同作品', async () => {
    const env = makeEnv();
    const a = await registerUser(env, 'a', { now: NOW });
    await upload(env, a, [entry('book', ['bgm:100'], 'X'), entry('manga', ['bgm:100'], 'X')]);
    expect(works(env).map((w) => w.kind).sort()).toEqual(['book', 'manga']);
  });

  it('展示标题取全体读者上报的众数', async () => {
    const env = makeEnv();
    const users = [];
    for (const n of ['a', 'b', 'c']) users.push(await registerUser(env, n, { now: NOW }));
    await upload(env, users[0], [entry('video', ['anidb:1'], 'Title A')]);
    await upload(env, users[1], [entry('video', ['anidb:1'], 'Title B')]);
    await upload(env, users[2], [entry('video', ['anidb:1'], 'Title B')]);
    expect(works(env)[0].title).toBe('Title B');
  });

  it('同一次上报里两条目共享一个新键：只建一个作品，不留孤儿', async () => {
    const env = makeEnv();
    const a = await registerUser(env, 'a', { now: NOW });
    const r = await upload(env, a, [
      entry('book', ['t:x|'], 'x', { chars: 10 }),
      entry('book', ['t:x|'], 'x', { chars: 5, finishedAt: NOW, finishedDate: '2026-09-30' }),
    ]);
    expect(r.status).toBe(200);
    expect(works(env)).toHaveLength(1);
    const shelf = env.DB.raw.prepare('SELECT * FROM shelf').all();
    expect(shelf).toHaveLength(1);
    expect(shelf[0].chars).toBe(15);
    expect(shelf[0].finished_at).toBe(NOW);
  });

  it('共用新键的条目成组：只建一部作品，所有新键都挂在它上面（无幽灵作品）', async () => {
    const env = makeEnv();
    const a = await registerUser(env, 'a', { now: NOW });
    const b = await registerUser(env, 'b', { now: NOW });
    await upload(env, a, [entry('book', ['bgm:1', 'isbn:111'], 'x'), entry('book', ['bgm:1', 't:y|'], 'x')]);
    expect(works(env)).toHaveLength(1);
    const al = aliases(env);
    expect(new Set([al['book|bgm:1'], al['book|isbn:111'], al['book|t:y|']]).size).toBe(1);
    // 之后别人只报其中任一键都落到同一部。
    const r = await upload(env, b, [entry('book', ['t:y|'], 'x')]);
    expect(r.data.works[0].workId).toBe(al['book|bgm:1']);
  });

  it('别名抢注：已有强 ID 的作品不再挂同命名空间的新键', async () => {
    const env = makeEnv();
    const victim = await registerUser(env, 'v', { now: NOW });
    const attacker = await registerUser(env, 'x', { now: NOW });
    await upload(env, victim, [entry('video', ['anidb:1'], 'real 1')]);
    // 攻击者想把 anidb:2 挂到 anidb:1 的作品上（经由共用的标题键）。
    await upload(env, attacker, [entry('video', ['anidb:1', 't:bait|'], 'real 1'), entry('video', ['anidb:2', 't:bait|'], 'fake')]);
    const al = aliases(env);
    expect(al['video|anidb:2']).toBeUndefined();
    const c = await registerUser(env, 'c', { now: NOW });
    const r = await upload(env, c, [entry('video', ['anidb:2'], 'real 2')]);
    expect(r.data.works[0].workId).not.toBe(al['video|anidb:1']);
  });

  it('作品标题众数不计被管理员隐藏的账户', async () => {
    const env = makeEnv();
    const users = [];
    for (const n of ['a', 'b', 'c']) users.push(await registerUser(env, n, { now: NOW }));
    await upload(env, users[0], [entry('video', ['anidb:1'], 'Real')]);
    env.DB.raw.prepare('UPDATE accounts SET hidden = 1 WHERE id IN (?1, ?2)').run(users[1].id, users[2].id);
    await upload(env, users[1], [entry('video', ['anidb:1'], 'Spam')]);
    await upload(env, users[2], [entry('video', ['anidb:1'], 'Spam')]);
    expect(works(env)[0].title).toBe('Real');
  });

  it('上限规模（8000 条）一次上传是线性的：几秒内完成，且只有常数条语句', async () => {
    const env = makeEnv();
    const a = await registerUser(env, 'big', { now: NOW });
    let prepared = 0;
    const realPrepare = env.DB.prepare;
    env.DB.prepare = (sql) => {
      prepared++;
      return realPrepare(sql);
    };
    const entries = [];
    for (let i = 0; i < 8000; i++) {
      entries.push(entry(i % 2 ? 'book' : 'video', [`isbn:97800000${String(i).padStart(5, '0')}`, `t:title ${i}|author`], `title ${i}`, {
        finishedAt: NOW - i * 60000, finishedDate: new Date(NOW - i * 60000).toISOString().slice(0, 10), chars: 100,
        coverUrl: i % 3 ? null : 'https://image.tmdb.org/t/p/w300/x.jpg',
      }));
    }
    const t0 = Date.now();
    const r = await upload(env, a, entries);
    const first = Date.now() - t0;
    expect(r.status).toBe(200);
    expect(r.data.works).toHaveLength(8000);
    const t1 = Date.now();
    expect((await upload(env, a, entries)).status).toBe(200); // 二次上报走「全已存在」路径
    const second = Date.now() - t1;
    console.log(`8000 entries: first ${first}ms, second ${second}ms, statements ${prepared}`);
    expect(first).toBeLessThan(10000);
    expect(second).toBeLessThan(10000);
    expect(prepared).toBeLessThan(60);
  }, 60000);

  it('两条在读条目合并后仍是在读（NULL，不是 -1）', async () => {
    const env = makeEnv();
    const a = await registerUser(env, 'a', { now: NOW });
    await upload(env, a, [entry('book', ['t:y|'], 'y'), entry('book', ['t:y|'], 'y')]);
    const shelf = env.DB.raw.prepare('SELECT finished_at, finished_date FROM shelf').get();
    expect(shelf.finished_at).toBeNull();
    expect(shelf.finished_date).toBeNull();
  });
});

describe('整份替换与孤儿清理', () => {
  it('下架的作品：自己独有的作品连同别名和封面删除；别人也在架的保留', async () => {
    const env = makeEnv();
    const a = await registerUser(env, 'a', { now: NOW });
    const b = await registerUser(env, 'b', { now: NOW });
    await upload(env, a, [entry('book', ['t:mine|'], 'mine'), entry('book', ['t:shared|'], 'shared')]);
    await upload(env, b, [entry('book', ['t:shared|'], 'shared')]);
    const mine = aliases(env)['book|t:mine|'];
    env.DB.raw.prepare('UPDATE works SET cover_key = ?1 WHERE id = ?2').run(`c/${mine}-1.jpg`, mine);
    await env.MEDIA.put(`c/${mine}-1.jpg`, new Uint8Array([1]));

    const r = await upload(env, a, []);
    expect(r.status).toBe(200);
    expect(works(env).map((w) => w.title)).toEqual(['shared']);
    expect(aliases(env)['book|t:mine|']).toBeUndefined();
    expect(env.MEDIA.store.has(`c/${mine}-1.jpg`)).toBe(false);
  });

  it('每日字数整份替换', async () => {
    const env = makeEnv();
    const a = await registerUser(env, 'a', { now: NOW });
    await upload(env, a, [], [{ date: '2026-09-29', chars: 100 }, { date: '2026-09-30', chars: 200 }]);
    await upload(env, a, [], [{ date: '2026-09-30', chars: 50 }]);
    expect(env.DB.raw.prepare('SELECT date_key, chars FROM daily_chars').all().map((r) => ({ ...r }))).toEqual([
      { date_key: '2026-09-30', chars: 50 },
    ]);
  });

  it('远端封面先到先得，并回报哪些作品还缺封面', async () => {
    const env = makeEnv();
    const a = await registerUser(env, 'a', { now: NOW });
    const r = await upload(env, a, [
      entry('video', ['tmdb:tv:1'], 'v', { coverUrl: 'https://image.tmdb.org/t/p/w300/a.jpg' }),
      entry('book', ['t:b|'], 'b', { coverUrl: 'https://evil.example/x.jpg' }),
    ]);
    expect(r.data.works.map((w) => [w.i, w.needsCover])).toEqual([[0, false], [1, true]]);
  });

  it('上传按账户限流', async () => {
    const env = makeEnv();
    const a = await registerUser(env, 'a', { now: NOW });
    const statuses = [];
    for (let i = 0; i < 13; i++) statuses.push((await upload(env, a, [])).status);
    expect(statuses.slice(0, 12).every((s) => s === 200)).toBe(true);
    expect(statuses[12]).toBe(429);
  });
});
