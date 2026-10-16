import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { JPEG, call, entry, makeEnv, registerUser } from './harness.js';
import { COVER_HASH_MAX_DISTANCE, hammingHex, nearestCandidate, normalizeCoverHash } from '../src/cover_votes.js';

const NOW = Date.UTC(2026, 9, 16, 12);
const basic = { Authorization: `Basic ${btoa('admin:pw')}` };

// 64 位 dHash（16 位 hex）。NEAR_A 与 A 差 3 位（同一张图的不同压缩），B 与 A 差 64 位。
const A = '0000000000000000';
const NEAR_A = '0000000000000007';
const B = 'ffffffffffffffff';
const C = '00000000ffffffff';

const TMDB = 'https://image.tmdb.org/t/p/w300/a.jpg';
const TMDB2 = 'https://image.tmdb.org/t/p/w300/b.jpg';

async function shelf(env, u, extra = {}, now = NOW) {
  const r = await call(env, 'POST', '/v1/shelf', {
    key: u.key, account: u.id, now,
    body: { reset: true, put: [entry('book', ['t:x|'], 'x', extra)] },
  });
  expect(r.status).toBe(200);
  return r.data.works[0];
}

function img(n) {
  // 魔数是 JPEG，长度不同便于核对配额。
  const b = new Uint8Array(10 + n);
  b.set(JPEG);
  return b;
}

const putCover = (env, u, workId, h, now = NOW, bytes = img(1)) =>
  call(env, 'PUT', `/v1/works/${workId}/cover${h ? `?h=${h}` : ''}`, { key: u.key, account: u.id, body: bytes, now });
const vote = (env, u, workId, body, now = NOW) =>
  call(env, 'POST', `/v1/works/${workId}/cover/vote`, { key: u.key, account: u.id, body, now });
const work = (env, id) => env.DB.raw.prepare('SELECT cover_key, cover_url FROM works WHERE id = ?1').get(id);
const candidates = (env, id) => env.DB.raw
  .prepare('SELECT id, phash, cover_key, cover_url, votes FROM cover_candidates WHERE work_id = ?1 ORDER BY id').all(id);
const usage = (env) => env.DB.raw.prepare('SELECT bytes FROM media_usage WHERE id = 1').get().bytes;

async function users(env, n) {
  const out = [];
  for (let i = 0; i < n; i++) out.push(await registerUser(env, `u${i}`, { now: NOW }));
  return out;
}

describe('哈希工具', () => {
  it('汉明距离与阈值内最近候选', () => {
    expect(hammingHex(A, NEAR_A)).toBe(3);
    expect(hammingHex(A, B)).toBe(64);
    expect(hammingHex(A, C)).toBe(32);
    expect(COVER_HASH_MAX_DISTANCE).toBe(10);
    const cands = [
      { id: 1, phash: C, votes: 5 },
      { id: 2, phash: NEAR_A, votes: 1 },
      { id: 3, phash: null, votes: 9 },
    ];
    expect(nearestCandidate(cands, A).id).toBe(2);
    expect(nearestCandidate(cands, B)).toBeNull();
    expect(normalizeCoverHash('ABCDEF0123456789')).toBe('abcdef0123456789');
    expect(normalizeCoverHash('xyz')).toBeNull();
  });
});

describe('封面按人数投票', () => {
  it('相近的图归为同一候选、只存一份；票多者成为作品封面', async () => {
    const env = makeEnv();
    const [u0, u1, u2] = await users(env, 3);
    const w = await shelf(env, u0);
    await shelf(env, u1);
    await shelf(env, u2);

    // u0 先传 A：唯一候选，成为封面。
    const r0 = await putCover(env, u0, w.workId, A);
    expect(r0.status).toBe(200);
    expect(work(env, w.workId).cover_key).toBe(r0.data.cover.slice(5));

    // u1 传 B：各一票平票，取最早达到 1 票的 A。
    await putCover(env, u1, w.workId, B, NOW + 1000);
    expect(work(env, w.workId).cover_key).toBe(r0.data.cover.slice(5));
    expect(env.MEDIA.store.size).toBe(2);

    // u2 的图与 A 只差 3 位：先投票接口直接命中，不再上传字节。
    const v = await vote(env, u2, w.workId, { hash: NEAR_A }, NOW + 2000);
    expect(v.status).toBe(200);
    expect(v.data.cover).toBe(r0.data.cover);
    expect(env.MEDIA.store.size).toBe(2);
    expect(candidates(env, w.workId).map((c) => c.votes)).toEqual([2, 1]);

    // 就算直接 PUT 字节，命中已有候选也不存第二份。
    const again = await putCover(env, u2, w.workId, NEAR_A, NOW + 3000);
    expect(again.status).toBe(200);
    expect(env.MEDIA.store.size).toBe(2);
  });

  it('改投即移票：B 超过 A 后封面换成 B；零票候选连同 R2 对象清理并归还配额', async () => {
    const env = makeEnv();
    const [u0, u1, u2] = await users(env, 3);
    const w = await shelf(env, u0);
    await shelf(env, u1);
    await shelf(env, u2);
    const a = await putCover(env, u0, w.workId, A, NOW, img(100));
    const b = await putCover(env, u1, w.workId, B, NOW + 1, img(200));
    expect(usage(env)).toBe(110 + 210);
    // u2 投 B → B 2 票胜出。
    await vote(env, u2, w.workId, { hash: B }, NOW + 2);
    expect(work(env, w.workId).cover_key).toBe(b.data.cover.slice(5));
    // u0 本地更正后也换成 B：A 零票、不是当前封面 → 删除，配额归还。
    const moved = await vote(env, u0, w.workId, { hash: B }, NOW + 3);
    expect(moved.data.cover).toBe(b.data.cover);
    expect(candidates(env, w.workId).map((c) => [c.phash, c.votes])).toEqual([[B, 3]]);
    expect(env.MEDIA.store.has(a.data.cover.slice(5))).toBe(false);
    expect(usage(env)).toBe(210);
  });

  it('投票接口：哈希没命中 → 409 cover_bytes_required；URL 不在白名单 → 400；不在架 → 403', async () => {
    const env = makeEnv();
    const [u0, outsider] = await users(env, 2);
    const w = await shelf(env, u0);
    const miss = await vote(env, u0, w.workId, { hash: A });
    expect([miss.status, miss.data.error]).toEqual([409, 'cover_bytes_required']);
    expect((await vote(env, u0, w.workId, { url: 'https://evil.example/x.jpg' })).status).toBe(400);
    expect((await vote(env, u0, w.workId, { hash: 'nothex' })).status).toBe(400);
    expect((await vote(env, u0, w.workId, { hash: A, url: TMDB })).status).toBe(400);
    expect((await vote(env, outsider, w.workId, { url: TMDB })).status).toBe(403);
    expect((await putCover(env, u0, w.workId, 'zz')).status).toBe(400);
  });

  it('白名单 URL：书架上报带 coverUrl 即投票；不带了撤票；不覆盖已投的缩略图票', async () => {
    const env = makeEnv();
    const [u0, u1, u2] = await users(env, 3);
    const w0 = await shelf(env, u0, { coverUrl: TMDB });
    expect(w0.coverVote).toBe('url');
    expect(work(env, w0.workId).cover_url).toBe(TMDB);
    await shelf(env, u1, { coverUrl: TMDB2 }, NOW + 1);
    await shelf(env, u2, { coverUrl: TMDB2 }, NOW + 2);
    // TMDB2 两票胜出。
    expect(work(env, w0.workId)).toEqual({ cover_key: null, cover_url: TMDB2 });

    // u1 改投本地缩略图：上报再带 TMDB2 也不会把缩略图票冲掉。
    await putCover(env, u1, w0.workId, A, NOW + 3);
    const w1 = await shelf(env, u1, { coverUrl: TMDB2 }, NOW + 4);
    expect(w1.coverVote).toBe('hash');
    // 现在 TMDB 1、TMDB2 1（u2）、A 1：平票取最早达到 1 票的 → TMDB（u0 最早）。
    expect(work(env, w0.workId).cover_url).toBe(TMDB);

    // u0 的条目不再带 coverUrl：URL 票撤掉；TMDB 零票、不再是封面 → 候选删除。
    const w2 = await shelf(env, u0, {}, NOW + 5);
    expect(w2.coverVote).toBeNull();
    expect(candidates(env, w0.workId).map((c) => c.cover_url || c.phash).sort()).toEqual([A, TMDB2].sort());
  });

  it('旧客户端（不带哈希）：作品没封面时照收并记一票；已有封面 409 cover_exists', async () => {
    const env = makeEnv();
    const [u0, u1] = await users(env, 2);
    const w = await shelf(env, u0);
    await shelf(env, u1);
    const first = await putCover(env, u0, w.workId, null);
    expect(first.status).toBe(200);
    expect(candidates(env, w.workId)).toHaveLength(1);
    expect(candidates(env, w.workId)[0]).toMatchObject({ phash: null, votes: 1 });
    const late = await putCover(env, u1, w.workId, null);
    expect([late.status, late.data.error]).toEqual([409, 'cover_exists']);
    expect(env.MEDIA.store.size).toBe(1);
  });

  it('迁移回填：存量封面成为零票候选；有人投票后被替换并清理', async () => {
    const env = makeEnv();
    const [u0] = await users(env, 1);
    const w = await shelf(env, u0);
    // 模拟迁移前的先到先得封面。
    const legacy = `c/${w.workId}-old-1.jpg`;
    env.DB.raw.prepare('UPDATE works SET cover_key = ?1 WHERE id = ?2').run(legacy, w.workId);
    await env.MEDIA.put(legacy, img(5));
    const sql = readFileSync(fileURLToPath(new URL('../migrations/0011_cover_votes.sql', import.meta.url)), 'utf8');
    env.DB.raw.exec(sql);
    env.DB.raw.exec(sql); // 重复应用是空操作
    expect(candidates(env, w.workId)).toEqual([
      expect.objectContaining({ cover_key: legacy, votes: 0, phash: null }),
    ]);
    const r = await putCover(env, u0, w.workId, A);
    expect(work(env, w.workId).cover_key).toBe(r.data.cover.slice(5));
    expect(env.MEDIA.store.has(legacy)).toBe(false);
    expect(candidates(env, w.workId).map((c) => c.phash)).toEqual([A]);
  });

  it('删除账户：撤票后作品按剩余票数重新物化', async () => {
    const env = makeEnv();
    const [u0, u1, u2] = await users(env, 3);
    const w = await shelf(env, u0);
    await shelf(env, u1);
    await shelf(env, u2);
    await putCover(env, u0, w.workId, A, NOW);
    await vote(env, u1, w.workId, { hash: A }, NOW + 1);
    const b = await putCover(env, u2, w.workId, B, NOW + 2);
    expect(work(env, w.workId).cover_key).not.toBe(b.data.cover.slice(5));
    for (const u of [u0, u1]) {
      expect((await call(env, 'DELETE', '/v1/me', { key: u.key, account: u.id, now: NOW + 3 })).status).toBe(204);
    }
    expect(work(env, w.workId).cover_key).toBe(b.data.cover.slice(5));
    expect(env.MEDIA.store.size).toBe(1);
    expect(env.DB.raw.prepare('SELECT COUNT(*) n FROM cover_votes').get().n).toBe(1);
  });

  it('下架到无人在架：作品、候选、票与 R2 对象一起清理', async () => {
    const env = makeEnv();
    const [u0] = await users(env, 1);
    const w = await shelf(env, u0);
    await putCover(env, u0, w.workId, A);
    const r = await call(env, 'POST', '/v1/shelf', { key: u0.key, account: u0.id, now: NOW + 1, body: { reset: true, put: [] } });
    expect(r.status).toBe(200);
    expect(env.DB.raw.prepare('SELECT COUNT(*) n FROM cover_candidates').get().n).toBe(0);
    expect(env.DB.raw.prepare('SELECT COUNT(*) n FROM cover_votes').get().n).toBe(0);
    expect(env.MEDIA.store.size).toBe(0);
    expect(usage(env)).toBe(0);
  });

  it('隐藏账户的票不计数；恢复后重新计入', async () => {
    const env = makeEnv();
    const [u0, u1, u2] = await users(env, 3);
    const w = await shelf(env, u0);
    await shelf(env, u1);
    await shelf(env, u2);
    const a = await putCover(env, u0, w.workId, A, NOW);
    const b = await putCover(env, u1, w.workId, B, NOW + 1);
    await vote(env, u2, w.workId, { hash: B }, NOW + 2);
    expect(work(env, w.workId).cover_key).toBe(b.data.cover.slice(5));
    const hide = (u, hidden) => call(env, 'POST', `/admin/api/accounts/${u.id}`, { headers: basic, body: { hidden }, now: NOW + 3 });
    await hide(u1, true);
    await hide(u2, true);
    expect(work(env, w.workId).cover_key).toBe(a.data.cover.slice(5));
    await hide(u2, false);
    // B 1 票（u2）、A 1 票：B 恢复时才重新涨到 1，A 更早达到 1 票。
    expect(work(env, w.workId).cover_key).toBe(a.data.cover.slice(5));
    await hide(u1, false);
    expect(work(env, w.workId).cover_key).toBe(b.data.cover.slice(5));
  });

  it('管理端清除封面：撤掉当前候选与其票，次多票的候选顶上', async () => {
    const env = makeEnv();
    const [u0, u1, u2] = await users(env, 3);
    const w = await shelf(env, u0);
    await shelf(env, u1);
    await shelf(env, u2);
    const a = await putCover(env, u0, w.workId, A, NOW);
    await vote(env, u1, w.workId, { hash: A }, NOW + 1);
    const b = await putCover(env, u2, w.workId, B, NOW + 2);
    const r = await call(env, 'POST', `/admin/api/works/${w.workId}`, { headers: basic, body: { clearCover: true }, now: NOW + 3 });
    expect(r.status).toBe(200);
    expect(work(env, w.workId).cover_key).toBe(b.data.cover.slice(5));
    expect(env.MEDIA.store.has(a.data.cover.slice(5))).toBe(false);
    expect(env.DB.raw.prepare('SELECT COUNT(*) n FROM cover_votes').get().n).toBe(1);
  });

  it('管理端合并：两边的候选与票并到目标作品，同 URL 候选合一，两边都投过的账户只留一票', async () => {
    const env = makeEnv();
    const [u0, u1, u2] = await users(env, 3);
    const up = (u, title, extra, now) => call(env, 'POST', '/v1/shelf', {
      key: u.key, account: u.id, now,
      body: { reset: true, put: [entry('book', [`t:${title}|`], title, extra)] },
    });
    const into = (await up(u0, 'into', { coverUrl: TMDB }, NOW)).data.works[0].workId;
    const from = (await up(u1, 'from', { coverUrl: TMDB2 }, NOW + 1)).data.works[0].workId;
    await call(env, 'POST', '/v1/shelf', {
      key: u2.key, account: u2.id, now: NOW + 2,
      body: { reset: true, put: [entry('book', ['t:from|'], 'from', { coverUrl: TMDB2 })] },
    });
    // from：TMDB2 两票；into：TMDB 一票。
    const r = await call(env, 'POST', '/admin/api/works/merge', { headers: basic, body: { from, into }, now: NOW + 3 });
    expect(r.status).toBe(200);
    expect(work(env, into).cover_url).toBe(TMDB2);
    expect(candidates(env, into).map((c) => [c.cover_url, c.votes]).sort()).toEqual([[TMDB, 1], [TMDB2, 2]].sort());
    expect(env.DB.raw.prepare('SELECT COUNT(*) n FROM cover_candidates WHERE work_id = ?1').get(from).n).toBe(0);
  });
});
