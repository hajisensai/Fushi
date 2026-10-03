import { describe, expect, it } from 'vitest';
import { call, entry, lastCode, makeEnv, newKey, nextIp, registerUser } from './harness.js';
import { acceptCoverUrl, normalizeUpload, shelfDiff } from '../src/shelf.js';
import { LIMITS } from '../src/ratelimit.js';

const NOW = Date.UTC(2026, 8, 30, 12);
const DAY = 24 * 3600 * 1000;

/** 整份替换（reset + put），沿用旧用例的语义。 */
async function upload(env, u, entries, daily = []) {
  return call(env, 'POST', '/v1/shelf', { key: u.key, account: u.id, body: { reset: true, put: entries, daily }, now: NOW });
}

/** 增量一批。 */
async function delta(env, u, body, now = NOW) {
  return call(env, 'POST', '/v1/shelf', { key: u.key, account: u.id, body, now });
}

function works(env) {
  return env.DB.raw.prepare('SELECT * FROM works ORDER BY created_at, id').all();
}

function aliases(env) {
  return Object.fromEntries(env.DB.raw.prepare('SELECT ref, work_id FROM work_aliases').all().map((r) => [r.ref, r.work_id]));
}

describe('上报校验', () => {
  it('非法 kind / ref / 未来的读完时刻 → 400 并带下标', () => {
    expect(() => normalizeUpload({ reset: true, put: [entry('novel', ['t:x'], 'x')] }, NOW)).toThrow(/0: kind/);
    expect(() => normalizeUpload({ reset: true, put: [entry('book', ['foo:x'], 'x')] }, NOW)).toThrow(/0: ref/);
    expect(() => normalizeUpload({ reset: true, put: [entry('book', ['t:x\ny'], 'x')] }, NOW)).toThrow(/0: ref/);
    expect(() =>
      normalizeUpload({ reset: true, put: [entry('book', ['t:x'], 'x', { finishedAt: NOW + DAY, finishedDate: '2026-10-01' })] }, NOW),
    ).toThrow(/finishedAt/);
    expect(() =>
      normalizeUpload({ reset: true, put: [entry('book', ['t:x'], 'x', { finishedAt: NOW })] }, NOW),
    ).toThrow(/finishedDate/);
  });

  it('finishedDate 必须与 finishedAt 的 UTC 日期相差一天以内（防摊到未来日期刷周榜）', () => {
    const ok = (d) => normalizeUpload({ reset: true, put: [entry('book', ['t:x'], 'x', { finishedAt: NOW, finishedDate: d })] }, NOW);
    expect(() => ok('2026-09-29')).not.toThrow();
    expect(() => ok('2026-10-01')).not.toThrow();
    expect(() => ok('2031-01-01')).toThrow(/finishedDate/);
    expect(() => ok('2026-09-27')).toThrow(/finishedDate/);
  });

  it('同一条目同一命名空间只能有一个键', () => {
    expect(() => normalizeUpload({ reset: true, put: [entry('book', ['bgm:1', 'bgm:2'], 'x')] }, NOW)).toThrow(/duplicate_namespace/);
  });

  it('三态：在读 / 读完日期未知 / 读完有日期', () => {
    const { put } = normalizeUpload({
      put: [
        entry('game', ['vndb:v1'], 'a'),
        entry('game', ['vndb:v2'], 'b', { finished: true }),
        entry('game', ['vndb:v3'], 'c', { finishedAt: NOW, finishedDate: '2026-09-30' }),
      ],
    }, NOW);
    expect(put.map((e) => [e.finishedAt, e.finishedDate])).toEqual([[null, null], [0, null], [NOW, '2026-09-30']]);
  });

  it('单批上限 500 / 500 / 400，remove 只收作品 id 形状', () => {
    const many = (n) => Array.from({ length: n }, (_, i) => entry('book', [`t:${i}|`], `${i}`));
    expect(() => normalizeUpload({ put: many(501) }, NOW)).toThrow(/batch_too_large/);
    expect(() => normalizeUpload({ remove: Array(501).fill('abc') }, NOW)).toThrow(/batch_too_large/);
    expect(() => normalizeUpload({ remove: ['../x'] }, NOW)).toThrow(/bad_remove/);
  });

  it('封面 URL 只收白名单主机的 https', () => {
    expect(acceptCoverUrl('https://image.tmdb.org/t/p/w300/a.jpg')).toBe('https://image.tmdb.org/t/p/w300/a.jpg');
    expect(acceptCoverUrl('http://image.tmdb.org/a.jpg')).toBeNull();
    expect(acceptCoverUrl('https://evil.example/a.jpg')).toBeNull();
    expect(acceptCoverUrl('https://image.tmdb.org.evil.example/a.jpg')).toBeNull();
  });

  it('每日字数超上限被夹到 400000', () => {
    const { daily } = normalizeUpload({ reset: true, put: [], daily: [{ date: '2026-09-30', chars: 9_000_000 }] }, NOW);
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

  it('上限规模（8000 条，分 16 批）线性完成；每批语句数为常数；满了再加 413', async () => {
    // 这里只测复杂度：放宽预算与每账户日上限（真实部署下 8000 条首次同步要分两三天续传，见 LIMITS 注释）。
    const env = makeEnv({ autoSnapshot: false, BUDGET_WRITE_ROWS: '10000000' });
    const savedRows = LIMITS.shelfRowsPerAccountDay;
    LIMITS.shelfRowsPerAccountDay = 10000000;
    const a = await registerUser(env, 'big', { now: NOW });
    let prepared = 0;
    const realPrepare = env.DB.prepare;
    env.DB.prepare = (sql) => {
      prepared++;
      return realPrepare(sql);
    };
    const all = [];
    for (let i = 0; i < 8000; i++) {
      all.push(entry(i % 2 ? 'book' : 'video', [`isbn:97800000${String(i).padStart(5, '0')}`, `t:title ${i}|author`], `title ${i}`, {
        finishedAt: NOW - i * 60000, finishedDate: new Date(NOW - i * 60000).toISOString().slice(0, 10), chars: 100,
        coverUrl: i % 3 ? null : 'https://image.tmdb.org/t/p/w300/x.jpg',
      }));
    }
    const t0 = Date.now();
    for (let b = 0; b < 16; b++) {
      const r = await delta(env, a, { reset: b === 0, put: all.slice(b * 500, b * 500 + 500) });
      expect(r.status).toBe(200);
      expect(r.data.shelfCount).toBe((b + 1) * 500);
    }
    const elapsed = Date.now() - t0;
    const perBatch = prepared / 16;
    console.log(`8000 entries in 16 batches: ${elapsed}ms, ${perBatch} statements/batch`);
    expect(elapsed).toBeLessThan(20000);
    expect(perBatch).toBeLessThan(40);
    const full = await delta(env, a, { put: [entry('book', ['t:one more|'], 'one more')] });
    expect(full.status).toBe(413);
    expect(full.data.error).toBe('shelf_full');
    // 改已有作品不增加行数，照常接受。
    expect((await delta(env, a, { put: [all[1]] })).status).toBe(200);
    LIMITS.shelfRowsPerAccountDay = savedRows;
  }, 120000);

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

  it('每日字数：reset 整份替换；增量按日期覆盖，0 删除', async () => {
    const env = makeEnv();
    const a = await registerUser(env, 'a', { now: NOW });
    const days = () => env.DB.raw.prepare('SELECT date_key, chars FROM stat_days ORDER BY date_key').all().map((r) => ({ ...r }));
    await upload(env, a, [], [{ date: '2026-09-29', chars: 100 }, { date: '2026-09-30', chars: 200 }]);
    await delta(env, a, { daily: [{ date: '2026-09-30', chars: 50 }] });
    expect(days()).toEqual([{ date_key: '2026-09-29', chars: 100 }, { date_key: '2026-09-30', chars: 50 }]);
    await delta(env, a, { daily: [{ date: '2026-09-29', chars: 0 }] });
    expect(days()).toEqual([{ date_key: '2026-09-30', chars: 50 }]);
    await upload(env, a, [], [{ date: '2026-09-28', chars: 7 }]);
    expect(days()).toEqual([{ date_key: '2026-09-28', chars: 7 }]);
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
    const env = makeEnv({ autoSnapshot: false });
    const a = await registerUser(env, 'a', { now: NOW });
    const statuses = [];
    for (let i = 0; i <= LIMITS.shelfUploadPerHour; i++) statuses.push((await delta(env, a, {})).status);
    expect(statuses.slice(0, LIMITS.shelfUploadPerHour).every((s) => s === 200)).toBe(true);
    expect(statuses[LIMITS.shelfUploadPerHour]).toBe(429);
  });
});

describe('增量协议与增量计数', () => {
  const done = (date) => ({ finishedAt: Date.parse(`${date}T10:00:00Z`), finishedDate: date });

  it('shelfDiff：存在 / 读完的前后差只有一条规则', () => {
    const oldRows = new Map([
      ['w1', { finished_at: 1, finished_date: '2026-09-01' }],
      ['w2', { finished_at: null, finished_date: null }],
      ['w3', { finished_at: 5, finished_date: '2026-09-03' }],
    ]);
    const putRows = [
      { workId: 'w2', finishedAt: 9, finishedDate: '2026-09-09' }, // 在读 → 读完
      { workId: 'w4', finishedAt: null, finishedDate: null }, // 新增在读
    ];
    const d = shelfDiff({ reset: false, remove: ['w3', 'wX'], oldRows, putRows });
    expect(d.countDelta).toBe(0); // +w4 −w3
    expect(d.readerDeltas.sort((x, y) => (x.id < y.id ? -1 : 1))).toEqual([{ id: 'w2', d: 1 }, { id: 'w3', d: -1 }]);
    expect(d.gone).toEqual(['w3']);
    expect([...d.dates].sort()).toEqual(['2026-09-03', '2026-09-09']);
    const r = shelfDiff({ reset: true, remove: [], oldRows, putRows: [{ workId: 'w1', finishedAt: 1, finishedDate: '2026-09-01' }] });
    expect(r.countDelta).toBe(-2);
    expect(r.readerDeltas).toEqual([{ id: 'w3', d: -1 }]);
    expect(r.gone.sort()).toEqual(['w2', 'w3']);
  });

  it('remove 删行、读者数与书架行数随之变化；无人在架的作品被清理', async () => {
    const env = makeEnv();
    const a = await registerUser(env, 'a', { now: NOW });
    const b = await registerUser(env, 'b', { now: NOW });
    const [w] = (await delta(env, a, { reset: true, put: [entry('book', ['t:x|'], 'x', done('2026-09-29'))] })).data.works;
    await delta(env, b, { reset: true, put: [entry('book', ['t:x|'], 'x', done('2026-09-29'))] });
    const readers = () => env.DB.raw.prepare('SELECT readers FROM works WHERE id = ?1').get(w.workId)?.readers;
    expect(readers()).toBe(2);
    const r = await delta(env, a, { remove: [w.workId] });
    expect(r.data.shelfCount).toBe(0);
    expect(readers()).toBe(1);
    await delta(env, b, { put: [entry('book', ['t:x|'], 'x')] }); // 读完 → 在读
    expect(readers()).toBe(0);
    await delta(env, b, { remove: [w.workId] });
    expect(readers()).toBeUndefined();
  });

  it('counted:false（同机另一 Profile）：上架、计入本账户计分，但不计入作品读者数（BUG-2870）', async () => {
    const env = makeEnv({ autoSnapshot: false });
    const a = await registerUser(env, 'a', { now: NOW });
    const b = await registerUser(env, 'b', { now: NOW });
    const finished = done('2026-09-29');
    const [w] = (await delta(env, a, { reset: true, put: [entry('book', ['t:dup|'], 'dup', finished)] })).data.works;
    const r = await delta(env, b, { reset: true, put: [entry('book', ['t:dup|'], 'dup', { ...finished, counted: false })] });
    expect(r.status).toBe(200);
    expect(r.data.shelfCount).toBe(1);
    const db = env.DB.raw;
    const readers = () => db.prepare('SELECT readers FROM works WHERE id = ?1').get(w.workId)?.readers;
    const periodN = () => db.prepare("SELECT n FROM work_periods WHERE work_id = ?1 AND period LIKE 'm:%'").get(w.workId)?.n;
    const bookTotal = (acc) => db.prepare('SELECT book FROM account_totals WHERE account_id = ?1').get(acc.id)?.book;
    expect(readers()).toBe(1);
    expect(periodN()).toBe(1);
    expect(bookTotal(b)).toBe(1); // 账户自己的读完数不去重
    // 计数的那个 Profile 不再上传 → 另一个接手计入：0 → 1 也产生增量。
    await delta(env, b, { put: [entry('book', ['t:dup|'], 'dup', finished)] });
    expect(readers()).toBe(2);
    expect(periodN()).toBe(2);
    await delta(env, b, { put: [entry('book', ['t:dup|'], 'dup', { ...finished, counted: false })] });
    expect(readers()).toBe(1);
    expect(periodN()).toBe(1);
    // 删除不计入的行不动读者数；删除计入的行才减。
    await delta(env, b, { remove: [w.workId] });
    expect(readers()).toBe(1);
    await delta(env, a, { remove: [w.workId] });
    expect(readers()).toBeUndefined();
  });

  it('对拍：任意增量操作序列之后，增量维护的计数 == 从零精确重算', async () => {
    const env = makeEnv({ autoSnapshot: false });
    const users = [];
    for (let i = 0; i < 4; i++) users.push(await registerUser(env, `u${i}`, { now: NOW }));
    // mulberry32：线性同余的低位周期太短，rnd(4)/rnd(5) 会高度相关（总挑同一个用户）。
    let seed = 42;
    const rnd = (n) => {
      seed = (seed + 0x6d2b79f5) | 0;
      let t = seed;
      t = Math.imul(t ^ (t >>> 15), t | 1);
      t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
      return ((t ^ (t >>> 14)) >>> 0) % n;
    };
    const kinds = ['book', 'manga', 'video', 'game'];
    const dates = ['2026-09-26', '2026-09-27', '2026-09-28', '2026-09-29'];
    const mk = (k) => {
      const kind = kinds[k % 4];
      const f = rnd(3);
      const extra = f === 0 ? {} : f === 1 ? { finished: true } : done(dates[rnd(4)]);
      // 同机多 Profile 去重：约三分之一的条目不计入作品维度读者数（BUG-2870）。
      const counted = rnd(3) === 0 ? { counted: false } : {};
      return entry(kind, [`t:work${k}|`], `w${k}`, { ...extra, ...counted, chars: rnd(1000) });
    };
    for (let step = 0; step < 60; step++) {
      const now = NOW + step * 90 * 1000; // 每步 90 秒，免得撞上每小时上传次数限流
      const up = (u, body) => delta(env, u, body, now);
      const u = users[rnd(4)];
      const op = rnd(5);
      if (op === 0) {
        const ks = Array.from({ length: 1 + rnd(5) }, () => rnd(12));
        const r = await up(u, { reset: true, put: ks.map(mk), daily: [{ date: dates[rnd(4)], chars: rnd(500) }] });
        expect(r.status).toBe(200);
      } else if (op <= 2) {
        const ks = Array.from({ length: 1 + rnd(4) }, () => rnd(12));
        const r = await up(u, { put: ks.map(mk), daily: [{ date: dates[rnd(4)], chars: rnd(500) }] });
        expect(r.status).toBe(200);
      } else if (op === 3) {
        const mine = env.DB.raw.prepare('SELECT work_id FROM shelf WHERE account_id = ?1').all(u.id).map((x) => x.work_id);
        if (mine.length) expect((await up(u, { remove: [mine[rnd(mine.length)]] })).status).toBe(200);
      } else {
        const hidden = rnd(2) === 1;
        const { setAccountHidden } = await import('../src/admin.js');
        await setAccountHidden(env, u.id, hidden, now);
      }
      const db = env.DB.raw;
      const drift = db.prepare(
        `SELECT w.id, w.readers, (SELECT COUNT(*) FROM shelf s JOIN accounts a ON a.id = s.account_id AND a.hidden = 0
                                  WHERE s.work_id = w.id AND s.finished_at IS NOT NULL AND s.counted = 1) AS exact
         FROM works w`,
      ).all().filter((r) => r.readers !== r.exact);
      expect(drift, `step ${step} readers drift`).toEqual([]);
      const countDrift = db.prepare(
        `SELECT a.id, a.shelf_count, (SELECT COUNT(*) FROM shelf s WHERE s.account_id = a.id) AS exact FROM accounts a`,
      ).all().filter((r) => r.shelf_count !== r.exact);
      expect(countDrift, `step ${step} shelf_count drift`).toEqual([]);
      for (const kind of kinds) {
        const totals = db.prepare(`SELECT account_id, ${kind} AS v FROM account_totals`).all();
        for (const t of totals) {
          const exact = db.prepare(
            `SELECT COALESCE(SUM(c), 0) AS v FROM (
               SELECT MIN(COUNT(*), 30) AS c FROM shelf s JOIN works w ON w.id = s.work_id
               WHERE s.account_id = ?1 AND w.kind = ?2 AND s.finished_at IS NOT NULL
               GROUP BY COALESCE(s.finished_date, s.work_id))`,
          ).get(t.account_id, kind).v;
          expect(t.v, `step ${step} ${kind} total of ${t.account_id}`).toBe(exact);
        }
      }
      const orphans = db.prepare('SELECT id FROM works w WHERE NOT EXISTS (SELECT 1 FROM shelf s WHERE s.work_id = w.id)').all();
      expect(orphans, `step ${step} orphan works`).toEqual([]);
      // work_periods == 按 shelf 现场聚合（未隐藏、有日期的读完）
      const wp = db.prepare('SELECT period, work_id, n FROM work_periods ORDER BY 1, 2').all().map((r) => ({ ...r }));
      const wpExact = db.prepare(
        `SELECT period, work_id, n FROM (
           SELECT 'w:' || date(s.finished_date, '-6 days', 'weekday 1') AS period, s.work_id, COUNT(*) AS n
           FROM shelf s JOIN accounts a ON a.id = s.account_id AND a.hidden = 0
           WHERE s.finished_at > 0 AND s.counted = 1 GROUP BY 1, 2
           UNION ALL
           SELECT 'm:' || substr(s.finished_date, 1, 7), s.work_id, COUNT(*)
           FROM shelf s JOIN accounts a ON a.id = s.account_id AND a.hidden = 0
           WHERE s.finished_at > 0 AND s.counted = 1 GROUP BY 1, 2) ORDER BY 1, 2`,
      ).all().map((r) => ({ ...r }));
      expect(wp, `step ${step} work_periods drift`).toEqual(wpExact);
      // account_periods == 按 stat_days 现场聚合
      const ap = db.prepare('SELECT period, account_id, book, manga, video, game, chars FROM account_periods ORDER BY 1, 2').all().map((r) => ({ ...r }));
      const apExact = db.prepare(
        `SELECT * FROM (
           SELECT 'w:' || date(date_key, '-6 days', 'weekday 1') AS period, account_id,
                  SUM(book) AS book, SUM(manga) AS manga, SUM(video) AS video, SUM(game) AS game, SUM(chars) AS chars
           FROM stat_days GROUP BY 1, 2
           UNION ALL
           SELECT 'm:' || substr(date_key, 1, 7), account_id, SUM(book), SUM(manga), SUM(video), SUM(game), SUM(chars)
           FROM stat_days GROUP BY 1, 2) ORDER BY 1, 2`,
      ).all().map((r) => ({ ...r }));
      expect(ap, `step ${step} account_periods drift`).toEqual(apExact);
    }
  }, 120000);

  it('全局写入预算用尽 → 503 daily_budget；每账户日上限 → 429', async () => {
    const env = makeEnv({ BUDGET_WRITE_ROWS: '30' });
    const a = await registerUser(env, 'a', { now: NOW });
    const many = Array.from({ length: 20 }, (_, i) => entry('book', [`t:b${i}|`], `b${i}`));
    const r = await delta(env, a, { reset: true, put: many });
    expect(r.status).toBe(503);
    expect(r.data.error).toBe('daily_budget');
    expect(env.DB.raw.prepare('SELECT COUNT(*) AS n FROM shelf').get().n).toBe(0); // 预算检查在写入之前

    const saved = LIMITS.shelfRowsPerAccountDay;
    LIMITS.shelfRowsPerAccountDay = 30;
    try {
      const env2 = makeEnv();
      const b = await registerUser(env2, 'b', { now: NOW });
      expect((await delta(env2, b, { reset: true, put: many })).status).toBe(429);
    } finally {
      LIMITS.shelfRowsPerAccountDay = saved;
    }
  });

  it('榜单读快照：新上报在下次刷新（定时任务）之前不可见', async () => {
    const env = makeEnv({ autoSnapshot: false });
    const a = await registerUser(env, 'a', { now: NOW });
    const rank = () => call(env, 'GET', '/v1/rank?metric=book&window=all', { now: NOW });
    expect((await rank()).data.rows).toEqual([]); // 首次读现场生成空快照
    await delta(env, a, { reset: true, put: [entry('book', ['t:x|'], 'x', done('2026-09-29'))] });
    expect((await rank()).data.rows).toEqual([]);
    const worker = (await import('../src/worker.js')).default;
    await worker.scheduled({}, env);
    const { clearSnapshotMemo } = await import('../src/snapshots.js');
    clearSnapshotMemo();
    const after = await rank();
    expect(after.data.rows.map((r) => r.value)).toEqual([1]);
    expect(typeof after.data.computedAt).toBe('number');
  });
});

describe('并发、上传设备与边界（审查修复回归）', () => {
  const done = (date) => ({ finishedAt: Date.parse(`${date}T10:00:00Z`), finishedDate: date });

  it('同账户并发两批：一批成功、另一批 409 conflict 且整批无副作用；计数不漂移', async () => {
    // 每次 D1 往返等 3ms：两批都在对方提交前读到旧状态（没有 CAS 时读者数会被 +2）。
    const env = makeEnv({ autoSnapshot: false, d1DelayMs: 3 });
    const a = await registerUser(env, 'a', { now: NOW });
    const e = entry('book', ['t:race|'], 'race', done('2026-09-29'));
    for (let round = 0; round < 5; round++) {
      const [r1, r2] = await Promise.all([delta(env, a, { put: [e] }), delta(env, a, { put: [e] })]);
      const statuses = [r1.status, r2.status].sort();
      expect(statuses[0]).toBe(200);
      expect([200, 409]).toContain(statuses[1]);
      const loser = [r1, r2].find((r) => r.status === 409);
      if (loser) expect(loser.data.error).toBe('conflict');
      // 竞争刚结束就核对（之后的并发删除若同样漂移会把误差抵消掉，只在最后核对抓不住）。
      const db0 = env.DB.raw;
      expect(db0.prepare('SELECT readers FROM works').get().readers, `round ${round} readers after put race`).toBe(1);
      expect(db0.prepare('SELECT shelf_count FROM accounts').get().shelf_count, `round ${round} shelf_count`).toBe(1);
      const w = env.DB.raw.prepare('SELECT id FROM works').get().id;
      const [x1, x2] = await Promise.all([delta(env, a, { remove: [w] }), delta(env, a, { remove: [w] })]);
      expect([x1.status, x2.status]).toContain(200);
    }
    const db = env.DB.raw;
    expect(db.prepare('SELECT shelf_count FROM accounts').get().shelf_count).toBe(db.prepare('SELECT COUNT(*) AS n FROM shelf').get().n);
    const readers = db.prepare('SELECT COALESCE(SUM(readers), 0) AS n FROM works').get().n;
    expect(readers).toBe(db.prepare('SELECT COUNT(*) AS n FROM shelf WHERE finished_at IS NOT NULL').get().n);
  });

  it('上传设备：另一台设备上传 409；带 claim + reset 接管后原设备 409', async () => {
    const env = makeEnv();
    const u = await registerUser(env, 'tom', { email: 'tom@example.com', now: NOW });
    expect((await delta(env, u, { reset: true, put: [entry('book', ['t:a|'], 'a')] })).status).toBe(200);
    const phone = await newKey();
    await call(env, 'POST', '/v1/email/code', { body: { email: 'tom@example.com', purpose: 'login' }, headers: { 'CF-Connecting-IP': nextIp() }, now: NOW });
    await call(env, 'POST', '/v1/login', { key: phone, body: { pubkey: phone.pubkey, email: 'tom@example.com', code: lastCode(env, 'tom@example.com') }, now: NOW });
    const { accountIdFromSpki } = await import('../src/auth.js');
    const p = { key: phone, id: await accountIdFromSpki(phone.spki) };
    const me = await call(env, 'GET', '/v1/me', { key: phone, account: p.id, now: NOW });
    expect(me.data.uploadDevice).toBe(false);
    const blocked = await delta(env, p, { put: [entry('book', ['t:b|'], 'b')] });
    expect(blocked.data.error).toBe('upload_owned_by_other_device');
    expect((await delta(env, p, { claim: true, put: [] })).data.error).toBe('claim_requires_reset');
    expect((await delta(env, p, { reset: true, claim: true, put: [entry('book', ['t:b|'], 'b')] })).status).toBe(200);
    expect((await delta(env, u, { put: [entry('book', ['t:c|'], 'c')] })).data.error).toBe('upload_owned_by_other_device');
    expect((await call(env, 'GET', '/v1/me', { key: phone, account: p.id, now: NOW })).data.uploadDevice).toBe(true);
  });

  it('每日字数只收最近 10 年', () => {
    expect(() => normalizeUpload({ daily: [{ date: '0001-01-01', chars: 1 }] }, NOW)).toThrow(/too_old/);
    expect(() => normalizeUpload({ daily: [{ date: '2020-01-01', chars: 1 }] }, NOW)).not.toThrow();
  });
});
