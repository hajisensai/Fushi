import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { JPEG, call, coverJpeg, entry, makeEnv, pngHeader, registerUser } from './harness.js';
import {
  COVER_HASH_MAX_DISTANCE,
  COVER_REPLACE_COOLDOWN_MS,
  hammingHex,
  nearestCandidate,
  normalizeCoverHash,
  settlePendingCovers,
} from '../src/cover_votes.js';

const NOW = Date.UTC(2026, 9, 16, 12);
const basic = { Authorization: `Basic ${btoa('admin:pw')}` };

// 64 位 dHash（16 位 hex）。NEAR_A 与 A 差 3 位（同一张图的不同压缩），B 与 A 差 64 位。
// 上传的字节一律是真 JPEG（coverJpeg(h)：服务端解码后算出的 dHash 恰为 h），因为候选哈希由服务端算。
const A = '0000000000000000';
const NEAR_A = '0000000000000007';
const B = 'ffffffffffffffff';
const C = '00000000ffffffff';

const COVER_HASH_RE_TEST = /^[0-9a-f]{16}$/;

const DAY = COVER_REPLACE_COOLDOWN_MS;

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

const putCover = (env, u, workId, h, now = NOW, bytes = coverJpeg(h && COVER_HASH_RE_TEST.test(h) ? h : A)) =>
  call(env, 'PUT', `/v1/works/${workId}/cover${h ? `?h=${h}` : ''}`, { key: u.key, account: u.id, body: bytes, now });
const vote = (env, u, workId, body, now = NOW) =>
  call(env, 'POST', `/v1/works/${workId}/cover/vote`, { key: u.key, account: u.id, body, now });
const work = (env, id) => env.DB.raw.prepare('SELECT cover_key, cover_url FROM works WHERE id = ?1').get(id);
const candidates = (env, id) => env.DB.raw
  .prepare('SELECT id, phash, cover_key, cover_url, votes FROM cover_candidates WHERE work_id = ?1 ORDER BY id').all(id);
const usage = (env) => env.DB.raw.prepare('SELECT bytes FROM media_usage WHERE id = 1').get().bytes;
const cidOf = (env, workId, phash) => candidates(env, workId).find((c) => c.phash === phash).id;
// 新客户端本机比对通过后的确认票（cover_votes.js 文件头「确认票」）。
const confirm = (env, u, workId, h, now = NOW) =>
  vote(env, u, workId, { hash: h, confirm: cidOf(env, workId, h) }, now);
/** 定时任务那一步（worker.scheduled 里的 settlePendingCovers），连同删 R2。 */
async function cron(env, now) {
  const { released } = await settlePendingCovers(env.DB, now);
  for (const k of released) await env.MEDIA.delete(k);
}

async function users(env, n) {
  const out = [];
  for (let i = 0; i < n; i++) out.push(await registerUser(env, `u${i}`, { now: NOW - 60_000 }));
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

  it('改投即移票：B 凑够确认票、过了冷却后换成 B；零票候选连同 R2 对象清理并归还配额', async () => {
    const env = makeEnv();
    const [u0, u1, u2, u3] = await users(env, 4);
    for (const u of [u0, u1, u2, u3]) await shelf(env, u);
    const w = await shelf(env, u0);
    const aBytes = coverJpeg(A);
    const bBytes = coverJpeg(B, { tint: [40, 0, -40] });
    const a = await putCover(env, u0, w.workId, A, NOW, aBytes);
    const b = await putCover(env, u1, w.workId, B, NOW + 1, bBytes);
    expect(usage(env)).toBe(aBytes.length + bBytes.length);
    // u2、u3 本机比对通过 → B 三张确认票、3 票 > A 1 票，但 B 才建了几毫秒：冷却期内不换。
    await confirm(env, u2, w.workId, B, NOW + 2);
    await confirm(env, u3, w.workId, B, NOW + 3);
    expect(work(env, w.workId).cover_key).toBe(a.data.cover.slice(5));
    // 冷却满后 u0 本地更正也换成 B（这一票的事务重新物化）：B 取代 A；A 零票、不是当前封面 → 删除，配额归还。
    const moved = await confirm(env, u0, w.workId, B, NOW + 1 + DAY);
    expect(moved.data.cover).toBe(b.data.cover);
    expect(work(env, w.workId).cover_key).toBe(b.data.cover.slice(5));
    expect(candidates(env, w.workId).map((c) => [c.phash, c.votes])).toEqual([[B, 4]]);
    expect(env.MEDIA.store.has(a.data.cover.slice(5))).toBe(false);
    expect(usage(env)).toBe(bBytes.length);
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

  it('白名单 URL：书架上报带 coverUrl 即投票（确认票）；不带了撤票；不覆盖已投的缩略图票', async () => {
    const env = makeEnv();
    const [u0, u1, u2] = await users(env, 3);
    const w0 = await shelf(env, u0, { coverUrl: TMDB });
    expect(w0.coverVote).toBe('url');
    expect(work(env, w0.workId).cover_url).toBe(TMDB);
    await shelf(env, u1, { coverUrl: TMDB2 }, NOW + 1);
    await shelf(env, u2, { coverUrl: TMDB2 }, NOW + 2);
    // TMDB2 两票多于 TMDB 一票，但不到替换门槛（3 张确认票）：TMDB 留任。
    expect(work(env, w0.workId)).toEqual({ cover_key: null, cover_url: TMDB });
    expect(env.DB.raw.prepare('SELECT COUNT(*) n FROM cover_votes WHERE confirmed = 1').get().n).toBe(3);

    // u1 改投本地缩略图：上报再带 TMDB2 也不会把缩略图票冲掉。
    await putCover(env, u1, w0.workId, A, NOW + 3);
    const w1 = await shelf(env, u1, { coverUrl: TMDB2 }, NOW + 4);
    expect(w1.coverVote).toBe('hash');

    // u0 的条目不再带 coverUrl：URL 票撤掉。TMDB 零票，但仍是现封面（挑战者都没过门槛），不删。
    const w2 = await shelf(env, u0, {}, NOW + 5);
    expect(w2.coverVote).toBeNull();
    expect(work(env, w0.workId).cover_url).toBe(TMDB);
    expect(candidates(env, w0.workId).map((c) => [c.cover_url || c.phash, c.votes]).sort())
      .toEqual([[A, 1], [TMDB, 0], [TMDB2, 1]].sort());
  });
  it('旧客户端（不带哈希）：作品没封面时照收并记一票；已有封面 409 cover_exists', async () => {
    const env = makeEnv();
    const [u0, u1] = await users(env, 2);
    const w = await shelf(env, u0);
    await shelf(env, u1);
    const first = await putCover(env, u0, w.workId, null, NOW, coverJpeg(C));
    expect(first.status).toBe(200);
    expect(candidates(env, w.workId)).toHaveLength(1);
    // 不带哈希也存服务端算的哈希：之后的新客户端可以归并到它。
    expect(candidates(env, w.workId)[0]).toMatchObject({ phash: C, votes: 1 });
    const late = await putCover(env, u1, w.workId, null);
    expect([late.status, late.data.error]).toEqual([409, 'cover_exists']);
    expect(env.MEDIA.store.size).toBe(1);
  });

  it('迁移回填：存量封面成为零票候选，视为已有封面；挑战者过门槛后替换并清理', async () => {
    const env = makeEnv();
    const [u0, u1, u2] = await users(env, 3);
    const w = await shelf(env, u0);
    await shelf(env, u1);
    await shelf(env, u2);
    // 模拟迁移前的先到先得封面。
    const legacy = `c/${w.workId}-old-1.jpg`;
    env.DB.raw.prepare('UPDATE works SET cover_key = ?1 WHERE id = ?2').run(legacy, w.workId);
    await env.MEDIA.put(legacy, coverJpeg(B));
    const sql = readFileSync(fileURLToPath(new URL('../migrations/0012_cover_votes.sql', import.meta.url)), 'utf8');
    env.DB.raw.exec(sql);
    env.DB.raw.exec(sql); // 重复应用是空操作
    expect(candidates(env, w.workId)).toEqual([
      expect.objectContaining({ cover_key: legacy, votes: 0, phash: null }),
    ]);
    // 一个人传了别的图：存量封面算已有封面，一票换不掉。
    const r = await putCover(env, u0, w.workId, A);
    expect(work(env, w.workId).cover_key).toBe(legacy);
    // 再两人确认、过了冷却 → 定时任务替换，零票的存量候选与对象一并清理。
    await confirm(env, u1, w.workId, A, NOW + 1);
    await confirm(env, u2, w.workId, A, NOW + 2);
    expect(work(env, w.workId).cover_key).toBe(legacy);
    await cron(env, NOW + DAY);
    expect(work(env, w.workId).cover_key).toBe(r.data.cover.slice(5));
    expect(env.MEDIA.store.has(legacy)).toBe(false);
    expect(candidates(env, w.workId).map((c) => c.phash)).toEqual([A]);
  });
  it('删除账户：撤票后作品按剩余票数重新物化（仍受替换门槛约束）', async () => {
    const env = makeEnv();
    const us = await users(env, 5);
    const [u0, u1, u2, u3, u4] = us;
    for (const u of us) await shelf(env, u);
    const w = await shelf(env, u0);
    await putCover(env, u0, w.workId, A, NOW);
    await vote(env, u1, w.workId, { hash: A }, NOW + 1);
    const b = await putCover(env, u2, w.workId, B, NOW + 2);
    await confirm(env, u3, w.workId, B, NOW + 3);
    await confirm(env, u4, w.workId, B, NOW + 4);
    // B 3 票 > A 2 票、3 张确认票，但冷却未满：A 留任。
    expect(work(env, w.workId).cover_key).not.toBe(b.data.cover.slice(5));
    for (const u of [u0, u1]) {
      expect((await call(env, 'DELETE', '/v1/me', { key: u.key, account: u.id, now: NOW + 2 + DAY })).status).toBe(204);
    }
    // 删号事务重新物化：B 已过冷却 → 取代 A；A 零票、不再是封面 → 清理。
    expect(work(env, w.workId).cover_key).toBe(b.data.cover.slice(5));
    expect(env.MEDIA.store.size).toBe(1);
    expect(env.DB.raw.prepare('SELECT COUNT(*) n FROM cover_votes').get().n).toBe(3);
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

  it('隐藏账户的票不计数（含确认票）；恢复后重新计入', async () => {
    const env = makeEnv();
    const us = await users(env, 4);
    const [u0, u1, u2, u3] = us;
    for (const u of us) await shelf(env, u);
    const w = await shelf(env, u0);
    const a = await putCover(env, u0, w.workId, A, NOW);
    const b = await putCover(env, u1, w.workId, B, NOW + 1);
    await confirm(env, u2, w.workId, B, NOW + 2);
    await confirm(env, u3, w.workId, B, NOW + 3);
    const hide = (u, hidden, now) => call(env, 'POST', `/admin/api/accounts/${u.id}`, { headers: basic, body: { hidden }, now });
    // 冷却期内隐藏 u3：B 只剩两张有效确认票。
    await hide(u3, true, NOW + 4);
    await cron(env, NOW + 1 + DAY);
    expect(work(env, w.workId).cover_key).toBe(a.data.cover.slice(5));
    // 恢复 u3（重算 + 物化）：B 三张确认票、已过冷却 → 取代 A。
    await hide(u3, false, NOW + 2 + DAY);
    expect(work(env, w.workId).cover_key).toBe(b.data.cover.slice(5));
  });
  it('管理端清除封面：撤掉当前候选与其票；保护期内顶上的也要过替换门槛', async () => {
    const env = makeEnv();
    const us = await users(env, 5);
    const [u0, u1, u2, u3, u4] = us;
    for (const u of us) await shelf(env, u);
    const w = await shelf(env, u0);
    const a = await putCover(env, u0, w.workId, A, NOW);
    await vote(env, u1, w.workId, { hash: A }, NOW + 1);
    const b = await putCover(env, u2, w.workId, B, NOW + 2);
    const r = await call(env, 'POST', `/admin/api/works/${w.workId}`, { headers: basic, body: { clearCover: true }, now: NOW + 3 });
    expect(r.status).toBe(200);
    // 以前：B（1 票）立即顶上。现在：刚清过封面的作品首张也要过门槛（攻击者不能在清掉的瞬间抢回首张）。
    expect(work(env, w.workId)).toEqual({ cover_key: null, cover_url: null });
    expect(env.MEDIA.store.has(a.data.cover.slice(5))).toBe(false);
    expect(env.DB.raw.prepare('SELECT COUNT(*) n FROM cover_votes').get().n).toBe(1);
    await confirm(env, u3, w.workId, B, NOW + 4);
    await confirm(env, u4, w.workId, B, NOW + 5);
    expect(work(env, w.workId).cover_key).toBeNull();
    await cron(env, NOW + 2 + DAY);
    expect(work(env, w.workId).cover_key).toBe(b.data.cover.slice(5));
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
    // from：TMDB2 两票；into：TMDB 一票（现封面）。
    const r = await call(env, 'POST', '/admin/api/works/merge', { headers: basic, body: { from, into }, now: NOW + 3 });
    expect(r.status).toBe(200);
    // 合并后 TMDB2 两票多于 TMDB，但不到替换门槛：目标作品的现封面留任。
    expect(work(env, into).cover_url).toBe(TMDB);
    expect(candidates(env, into).map((c) => [c.cover_url, c.votes]).sort()).toEqual([[TMDB, 1], [TMDB2, 2]].sort());
    expect(env.DB.raw.prepare('SELECT COUNT(*) n FROM cover_candidates WHERE work_id = ?1').get(from).n).toBe(0);
  });

  it('管理端合并：清封面保护期随合并带到目标作品（取较晚的清除时刻）', async () => {
    const env = makeEnv();
    const [u0, u1] = await users(env, 2);
    const up = (u, title, now) => call(env, 'POST', '/v1/shelf', {
      key: u.key, account: u.id, now, body: { reset: true, put: [entry('book', [`t:${title}|`], title)] },
    });
    const into = (await up(u0, 'into', NOW)).data.works[0].workId;
    const from = (await up(u1, 'from', NOW + 1)).data.works[0].workId;
    const cleared = (id) => env.DB.raw.prepare('SELECT cover_cleared_at c FROM works WHERE id = ?1').get(id).c;
    await call(env, 'POST', `/admin/api/works/${from}`, { headers: basic, body: { clearCover: true }, now: NOW + 5 });
    expect(cleared(into)).toBeNull();
    const r = await call(env, 'POST', '/admin/api/works/merge', { headers: basic, body: { from, into }, now: NOW + 6 });
    expect(r.status).toBe(200);
    expect(cleared(into)).toBe(NOW + 5);
  });
});

describe('封面哈希由服务端算（客户端声称的哈希不可信）', () => {
  it('伪造哈希：任意图片冒充正版封面的哈希 → 400 cover_hash_mismatch，不存图、不建候选', async () => {
    const env = makeEnv();
    const [attacker, honest] = await users(env, 2);
    const w = await shelf(env, attacker);
    await shelf(env, honest);
    const forged = await putCover(env, attacker, w.workId, A, NOW, coverJpeg(B));
    expect([forged.status, forged.data.error]).toEqual([400, 'cover_hash_mismatch']);
    expect(env.MEDIA.store.size).toBe(0);
    expect(candidates(env, w.workId)).toEqual([]);
    expect(usage(env)).toBe(0);
    // 持正版封面的人照常建自己的候选，票不会被吸走。
    const real = await putCover(env, honest, w.workId, A, NOW + 1);
    expect(real.status).toBe(200);
    expect(candidates(env, w.workId).map((c) => [c.phash, c.votes])).toEqual([[A, 1]]);
  });

  it('攻击者不声称哈希（旧协议）抢先上传：候选按服务端哈希入库，正版持有者不会命中它', async () => {
    const env = makeEnv();
    const [attacker, honest] = await users(env, 2);
    const w = await shelf(env, attacker);
    await shelf(env, honest);
    expect((await putCover(env, attacker, w.workId, null, NOW, coverJpeg(B))).status).toBe(200);
    const miss = await vote(env, honest, w.workId, { hash: A }, NOW + 1);
    expect([miss.status, miss.data.error]).toEqual([409, 'cover_bytes_required']);
    expect((await putCover(env, honest, w.workId, A, NOW + 2)).status).toBe(200);
    expect(candidates(env, w.workId).map((c) => c.phash)).toEqual([B, A]);
  });

  it('声称的哈希在阈值内照收，但入库与归并用服务端哈希', async () => {
    const env = makeEnv();
    const [u0] = await users(env, 1);
    const w = await shelf(env, u0);
    const r = await putCover(env, u0, w.workId, NEAR_A, NOW, coverJpeg(A));
    expect(r.status).toBe(200);
    expect(candidates(env, w.workId).map((c) => c.phash)).toEqual([A]);
  });

  it('不是 JPEG → 415 cover_not_jpeg；JPEG 魔数但解不开 → 400 bad_cover_image', async () => {
    const env = makeEnv();
    const [u0] = await users(env, 1);
    const w = await shelf(env, u0);
    const png = await putCover(env, u0, w.workId, A, NOW, pngHeader(4, 4));
    expect([png.status, png.data.error]).toEqual([415, 'cover_not_jpeg']);
    const junk = await putCover(env, u0, w.workId, A, NOW, JPEG);
    expect([junk.status, junk.data.error]).toEqual([400, 'bad_cover_image']);
    const legacyJunk = await putCover(env, u0, w.workId, null, NOW, JPEG);
    expect([legacyJunk.status, legacyJunk.data.error]).toEqual([400, 'bad_cover_image']);
    expect(env.MEDIA.store.size).toBe(0);
  });

  it('解压炸弹：帧头声称超大尺寸的小 JPEG 在分配像素前就被拒（400 bad_cover_image）', async () => {
    const env = makeEnv();
    const [u0] = await users(env, 1);
    const w = await shelf(env, u0);
    const bomb = coverJpeg(A);
    // 改 SOF0 帧头里的高 / 宽为 60000×60000（3600 MP）。
    let sof = -1;
    for (let i = 2; i + 1 < bomb.length; i++) {
      if (bomb[i] === 0xff && bomb[i + 1] === 0xc0) { sof = i; break; }
    }
    expect(sof).toBeGreaterThan(0);
    bomb.set([0xea, 0x60, 0xea, 0x60], sof + 5);
    const r = await putCover(env, u0, w.workId, A, NOW, bomb);
    expect([r.status, r.data.error]).toEqual([400, 'bad_cover_image']);
  });

  it('不在架的人上传：先 403，不解码', async () => {
    const env = makeEnv();
    const [u0, outsider] = await users(env, 2);
    const w = await shelf(env, u0);
    const r = await putCover(env, outsider, w.workId, A, NOW, JPEG);
    expect([r.status, r.data.error]).toEqual([403, 'not_on_shelf']);
  });

  it('删除账户时连同封面投票限流桶 cover:<id> 一起清掉', async () => {
    const env = makeEnv();
    const [u0] = await users(env, 1);
    const w = await shelf(env, u0);
    await vote(env, u0, w.workId, { url: TMDB });
    const bucket = () => env.DB.raw.prepare('SELECT COUNT(*) n FROM rate_limits WHERE bucket = ?1').get(`cover:${u0.id}`).n;
    expect(bucket()).toBe(1);
    expect((await call(env, 'DELETE', '/v1/me', { key: u0.key, account: u0.id, now: NOW + 1 })).status).toBe(204);
    expect(bucket()).toBe(0);
  });
});
