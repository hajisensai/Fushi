// 封面替换门槛 + 冷却期 + 确认票（迁移 0014；规则见 src/cover_votes.js 文件头）。

import { afterEach, describe, expect, it, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import worker from '../src/worker.js';
import { call, coverJpeg, makeEnv, registerUser, entry } from './harness.js';
import {
  COVER_CLEAR_GUARD_MS,
  COVER_REPLACE_COOLDOWN_MS,
  COVER_REPLACE_MIN_CONFIRMED,
  pendingCoverWorks,
  settlePendingCovers,
} from '../src/cover_votes.js';

const NOW = Date.UTC(2026, 9, 17, 12);
const DAY = COVER_REPLACE_COOLDOWN_MS;
const basic = { Authorization: `Basic ${btoa('admin:pw')}` };
const A = '0000000000000000';
const NEAR_A = '0000000000000007';
const B = 'ffffffffffffffff';
const C = '00000000ffffffff';

async function setup(n) {
  const env = makeEnv();
  const us = [];
  for (let i = 0; i < n; i++) us.push(await registerUser(env, `u${i}`, { now: NOW - 60_000 }));
  let workId;
  for (const u of us) {
    const r = await call(env, 'POST', '/v1/shelf', {
      key: u.key, account: u.id, now: NOW, body: { reset: true, put: [entry('book', ['t:x|'], 'x')] },
    });
    workId = r.data.works[0].workId;
  }
  return { env, us, workId };
}

const putCover = (env, u, workId, h, now = NOW, bytes = coverJpeg(h)) =>
  call(env, 'PUT', `/v1/works/${workId}/cover?h=${h}`, { key: u.key, account: u.id, body: bytes, now });
const vote = (env, u, workId, body, now = NOW) =>
  call(env, 'POST', `/v1/works/${workId}/cover/vote`, { key: u.key, account: u.id, body, now });
const coverKey = (env, id) => env.DB.raw.prepare('SELECT cover_key FROM works WHERE id = ?1').get(id).cover_key;
const cand = (env, workId, phash) => env.DB.raw
  .prepare('SELECT id, votes, created_at, reached_at FROM cover_candidates WHERE work_id = ?1 AND phash = ?2').get(workId, phash);
const confirm = (env, u, workId, h, now = NOW) => vote(env, u, workId, { hash: h, confirm: cand(env, workId, h).id }, now);
async function cron(env, now) {
  const { released } = await settlePendingCovers(env.DB, now);
  for (const k of released) await env.MEDIA.delete(k);
}
const keyOf = (r) => r.data.cover.slice(5);

afterEach(() => vi.useRealTimers());

describe('替换门槛：确认票 ≥ N', () => {
  it('常量与迁移 0014 的部分索引一致', () => {
    expect(COVER_REPLACE_MIN_CONFIRMED).toBe(3);
    const sql = readFileSync(new URL('../migrations/0014_cover_replace_guard.sql', import.meta.url), 'utf8');
    expect(sql).toContain(`WHERE votes >= ${COVER_REPLACE_MIN_CONFIRMED};`);
  });

  it('定时重算的查询走部分索引，不扫 cover_candidates 全表', async () => {
    const { env } = await setup(1);
    const seen = [];
    const real = env.DB.prepare;
    env.DB.prepare = (sql) => {
      const st = real(sql);
      return { ...st, bind: (...args) => { seen.push({ sql, args }); return st.bind(...args); } };
    };
    await pendingCoverWorks(env.DB, NOW);
    env.DB.prepare = real;
    expect(seen).toHaveLength(1);
    const plan = env.DB.raw.prepare(`EXPLAIN QUERY PLAN ${seen[0].sql}`).all(...seen[0].args).map((r) => r.detail);
    expect(plan.join(' | ')).toContain('idx_cover_candidates_pending');
    expect(plan.filter((d) => /^SCAN (c|cover_candidates)( |$)/.test(d))).toEqual([]);
  });

  it('单账户 / 少于 N 个账户：票再多于现封面、冷却再久也换不掉', async () => {
    const { env, us, workId } = await setup(3);
    const a = await putCover(env, us[0], workId, A);
    await putCover(env, us[1], workId, B, NOW + 1);
    await confirm(env, us[2], workId, B, NOW + 2);
    expect(cand(env, workId, B).votes).toBe(2);
    await cron(env, NOW + 2 * DAY);
    // 再投一票触发事务内物化，同样不换。
    await vote(env, us[2], workId, { hash: B }, NOW + 2 * DAY);
    expect(coverKey(env, workId)).toBe(keyOf(a));
  });

  it('N 个确认票但冷却未满：不换；冷却满后定时任务换上（没有新票）', async () => {
    const { env, us, workId } = await setup(4);
    const a = await putCover(env, us[0], workId, A);
    const b = await putCover(env, us[1], workId, B, NOW + 10);
    await confirm(env, us[2], workId, B, NOW + 11);
    await confirm(env, us[3], workId, B, NOW + 12);
    expect(coverKey(env, workId)).toBe(keyOf(a));
    await cron(env, NOW + 10 + DAY - 1);
    expect(coverKey(env, workId)).toBe(keyOf(a));
    expect(await pendingCoverWorks(env.DB, NOW + 10 + DAY)).toEqual([workId]);
    await cron(env, NOW + 10 + DAY);
    expect(coverKey(env, workId)).toBe(keyOf(b));
    // 换完不再是待生效：下一轮不再选中它（幂等，且不浪费重算）。
    expect(await pendingCoverWorks(env.DB, NOW + 10 + DAY + 1)).toEqual([]);
    await cron(env, NOW + 10 + DAY + 1);
    expect(coverKey(env, workId)).toBe(keyOf(b));
  });

  it('冷却满后的惰性路径：下一次该作品的投票事务重新物化', async () => {
    const { env, us, workId } = await setup(5);
    await putCover(env, us[0], workId, A);
    const b = await putCover(env, us[1], workId, B, NOW + 10);
    await confirm(env, us[2], workId, B, NOW + 11);
    await confirm(env, us[3], workId, B, NOW + 12);
    // 定时任务没跑；冷却满后第五个人随便投一票（投给 A 也行），B 照样生效。
    await vote(env, us[4], workId, { hash: A }, NOW + 10 + DAY);
    expect(coverKey(env, workId)).toBe(keyOf(b));
  });

  it('worker.scheduled 里接了定时重算', async () => {
    const { env, us, workId } = await setup(4);
    await putCover(env, us[0], workId, A);
    const b = await putCover(env, us[1], workId, B, NOW + 10);
    await confirm(env, us[2], workId, B, NOW + 11);
    await confirm(env, us[3], workId, B, NOW + 12);
    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(NOW + 10 + DAY);
    await worker.scheduled({}, env);
    expect(coverKey(env, workId)).toBe(keyOf(b));
  });

  it('门槛够、冷却满，但票数不多于现封面（平票）：现封面留任', async () => {
    const { env, us, workId } = await setup(6);
    const a = await putCover(env, us[0], workId, A);
    await confirm(env, us[1], workId, A, NOW + 1);
    await confirm(env, us[2], workId, A, NOW + 2);
    await putCover(env, us[3], workId, B, NOW + 3);
    await confirm(env, us[4], workId, B, NOW + 4);
    await confirm(env, us[5], workId, B, NOW + 5);
    await cron(env, NOW + 3 + DAY);
    expect(coverKey(env, workId)).toBe(keyOf(a));
  });
});

describe('确认票账户与入场票收割', () => {
  it('候选创建之后才注册的账户，确认票不计入门槛', async () => {
    const { env, us, workId } = await setup(2);
    const a = await putCover(env, us[0], workId, A);
    await putCover(env, us[1], workId, B, NOW + 10);
    // 候选 B 建好之后现注册两个小号来确认。
    const late = [];
    for (const n of ['late0', 'late1']) {
      const u = await registerUser(env, n, { now: NOW + 20 });
      await call(env, 'POST', '/v1/shelf', {
        key: u.key, account: u.id, now: NOW + 21, body: { reset: true, put: [entry('book', ['t:x|'], 'x')] },
      });
      late.push(u);
    }
    for (const u of late) expect((await confirm(env, u, workId, B, NOW + 30)).status).toBe(200);
    expect(cand(env, workId, B).votes).toBe(3);
    await cron(env, NOW + 10 + DAY);
    await vote(env, us[0], workId, { hash: A }, NOW + 10 + DAY);
    expect(coverKey(env, workId)).toBe(keyOf(a));
    const res = await call(env, 'GET', `/admin/api/works/${workId}/covers`, { headers: basic, now: NOW + 11 + DAY });
    expect(res.data.candidates.find((c) => c.phash === B)).toMatchObject({ votes: 3, confirmed: 1, status: 'needs_votes' });
  });

  it('入场票收割：伪造图抢到首张、旧客户端的未确认票把它撑高；正版凭确认票仍能替换', async () => {
    const { env, us, workId } = await setup(8);
    // 攻击者 us[0] 抢先传伪造图 A 成为首张；四个旧客户端按哈希投给它（未确认）→ A 5 票、1 张确认票。
    await putCover(env, us[0], workId, A);
    for (const u of us.slice(1, 5)) await vote(env, u, workId, { hash: A }, NOW + 1);
    expect(cand(env, workId, A).votes).toBe(5);
    // 正版 B：三张确认票、总票数 3 < 5。
    const b = await putCover(env, us[5], workId, B, NOW + 10);
    await confirm(env, us[6], workId, B, NOW + 11);
    await confirm(env, us[7], workId, B, NOW + 12);
    await cron(env, NOW + 10 + DAY);
    expect(coverKey(env, workId)).toBe(keyOf(b));
  });

  it('现封面自己确认票已过门槛时仍比总票数：平票留任，多一票才换', async () => {
    const { env, us, workId } = await setup(8);
    const a = await putCover(env, us[0], workId, A);
    await confirm(env, us[1], workId, A, NOW + 1);
    await confirm(env, us[2], workId, A, NOW + 2);
    await vote(env, us[3], workId, { hash: A }, NOW + 3); // A：4 票（3 确认）
    await putCover(env, us[4], workId, B, NOW + 10);
    await confirm(env, us[5], workId, B, NOW + 11);
    await confirm(env, us[6], workId, B, NOW + 12);
    await vote(env, us[7], workId, { hash: B }, NOW + 13); // B：4 票（3 确认），确认票不比 A 少也不换
    await cron(env, NOW + 10 + DAY);
    expect(coverKey(env, workId)).toBe(keyOf(a));
    await confirm(env, us[3], workId, B, NOW + 11 + DAY); // us[3] 改投 B：B 5 > A 3
    expect(coverKey(env, workId)).not.toBe(keyOf(a));
  });
});

describe('确认票', () => {
  it('旧客户端的哈希票（未确认）不计入替换门槛：再多也换不掉；首张封面照旧计', async () => {
    const { env, us, workId } = await setup(6);
    const a = await putCover(env, us[0], workId, A);
    await putCover(env, us[1], workId, B, NOW + 1);
    for (const u of us.slice(2)) await vote(env, u, workId, { hash: B }, NOW + 2);
    expect(cand(env, workId, B).votes).toBe(5);
    await cron(env, NOW + 2 * DAY);
    await vote(env, us[5], workId, { hash: B }, NOW + 2 * DAY);
    expect(coverKey(env, workId)).toBe(keyOf(a));
    // 补上确认（同一候选只改 confirmed，不动票数与 reached_at）→ 门槛满足 → 换上。
    const before = cand(env, workId, B);
    await confirm(env, us[2], workId, B, NOW + 2 * DAY + 1);
    expect(coverKey(env, workId)).toBe(keyOf(a)); // 还差一张
    await confirm(env, us[3], workId, B, NOW + 2 * DAY + 2);
    const after = cand(env, workId, B);
    expect([after.votes, after.reached_at]).toEqual([before.votes, before.reached_at]);
    expect(coverKey(env, workId)).not.toBe(keyOf(a));
  });

  it('check：只返回命中的候选与缩略图地址，不投票；确认过的回 confirmed', async () => {
    const { env, us, workId } = await setup(2);
    const a = await putCover(env, us[0], workId, A);
    const c = await vote(env, us[1], workId, { hash: NEAR_A, check: true });
    expect(c.status).toBe(200);
    expect(c.data).toEqual({ voted: false, candidate: { id: cand(env, workId, A).id, image: a.data.cover }, confirmed: false });
    expect(env.DB.raw.prepare('SELECT COUNT(*) n FROM cover_votes').get().n).toBe(1);
    // 上传者自己 check：他的票就是确认票。
    expect((await vote(env, us[0], workId, { hash: A, check: true })).data.confirmed).toBe(true);
    const miss = await vote(env, us[1], workId, { hash: B, check: true });
    expect([miss.status, miss.data.error]).toEqual([409, 'cover_bytes_required']);
    // check 只按防重放 / 限流那几行扣全局写入预算（投票按 16 行）。
    const used = () => env.DB.raw.prepare("SELECT used FROM budgets WHERE kind = 'write_rows'").get().used;
    const before = used();
    await vote(env, us[1], workId, { hash: A, check: true }, NOW + 1);
    expect(used() - before).toBe(4);
    await vote(env, us[1], workId, { hash: A }, NOW + 2);
    expect(used() - before).toBe(4 + 16);
  });

  it('confirm：候选必须属于本作品、与哈希在阈值内；重复确认是空操作', async () => {
    const { env, us, workId } = await setup(2);
    await putCover(env, us[0], workId, A);
    const cid = cand(env, workId, A).id;
    const far = await vote(env, us[1], workId, { hash: B, confirm: cid });
    expect([far.status, far.data.error]).toEqual([400, 'cover_hash_mismatch']);
    const gone = await vote(env, us[1], workId, { hash: A, confirm: cid + 999 });
    expect([gone.status, gone.data.error]).toEqual([409, 'cover_candidate_gone']);
    const ok = await vote(env, us[1], workId, { hash: NEAR_A, confirm: cid });
    expect([ok.status, ok.data.voted, ok.data.confirmed]).toEqual([200, true, true]);
    const again = await vote(env, us[1], workId, { hash: NEAR_A, confirm: cid }, NOW + 5);
    expect(again.status).toBe(200);
    expect(cand(env, workId, A).votes).toBe(2);
    expect((await vote(env, us[1], workId, { hash: A, check: true, confirm: cid })).status).toBe(400);
  });

  it('mismatch：记不符、撤票、不计票；之后对该账户跳过此候选，命中下一个或要求上传', async () => {
    const { env, us, workId } = await setup(3);
    await putCover(env, us[0], workId, A);
    const cid = cand(env, workId, A).id;
    // u1 旧协议先投了 A，后来升级、本机比对不通过。
    await vote(env, us[1], workId, { hash: NEAR_A });
    expect(cand(env, workId, A).votes).toBe(2);
    const r = await vote(env, us[1], workId, { hash: NEAR_A, mismatch: cid }, NOW + 1);
    expect([r.status, r.data.error]).toEqual([409, 'cover_bytes_required']);
    expect(cand(env, workId, A).votes).toBe(1);
    expect(env.DB.raw.prepare('SELECT COUNT(*) n FROM cover_mismatches WHERE candidate_id = ?1').get(cid).n).toBe(1);
    // 按哈希查找对他跳过 A：上传自己的图另立候选（确认票）。
    const up = await putCover(env, us[1], workId, NEAR_A, NOW + 2, coverJpeg(NEAR_A, { tint: [0, 30, 0] }));
    expect(up.status).toBe(200);
    expect(up.data.confirmed).toBe(true);
    expect(cand(env, workId, NEAR_A).votes).toBe(1);
    // 别人照常命中 A（不符只影响标记它的人）。
    expect((await vote(env, us[2], workId, { hash: A, check: true })).data.candidate.id).toBe(cid);
    // 重复标不符是空操作；确认他标过不符的候选被拒。
    expect((await vote(env, us[1], workId, { hash: A, mismatch: cid }, NOW + 3)).status).toBe(200);
    const blocked = await vote(env, us[1], workId, { hash: A, confirm: cid }, NOW + 4);
    expect([blocked.status, blocked.data.error]).toEqual([409, 'cover_candidate_gone']);
  });

  it('PUT 命中已有候选：投未确认票并返回 candidate，供客户端本机比对', async () => {
    const { env, us, workId } = await setup(2);
    const a = await putCover(env, us[0], workId, A);
    const r = await putCover(env, us[1], workId, NEAR_A);
    expect(r.data).toEqual({ cover: a.data.cover, confirmed: false, candidate: { id: cand(env, workId, A).id, image: a.data.cover } });
  });

  it('管理端 /covers：票数、确认票、不符、待生效状态', async () => {
    const { env, us, workId } = await setup(5);
    await putCover(env, us[0], workId, A);
    await putCover(env, us[1], workId, B, NOW + 1);
    await confirm(env, us[2], workId, B, NOW + 2);
    await confirm(env, us[3], workId, B, NOW + 3);
    await putCover(env, us[4], workId, C, NOW + 4);
    await vote(env, us[4], workId, { hash: B, mismatch: cand(env, workId, B).id }, NOW + 5);
    const res = await call(env, 'GET', `/admin/api/works/${workId}/covers`, { headers: basic, now: NOW + 6 });
    expect(res.status).toBe(200);
    const by = Object.fromEntries(res.data.candidates.map((c) => [c.phash, c]));
    expect(by[A]).toMatchObject({ status: 'current', votes: 1, confirmed: 1 });
    expect(by[B]).toMatchObject({ status: 'cooldown', votes: 3, confirmed: 3, mismatches: 1, eligibleAt: NOW + 1 + DAY });
    expect(by[C]).toMatchObject({ status: 'needs_votes', votes: 1, confirmed: 1 });
  });
});

describe('没有封面的作品', () => {
  it('首张封面不受门槛约束，立即生效', async () => {
    const { env, us, workId } = await setup(1);
    const a = await putCover(env, us[0], workId, A);
    expect(coverKey(env, workId)).toBe(keyOf(a));
  });

  it('管理员清封面后：保护期内首张也要过门槛；保护期过后恢复「有票即生效」', async () => {
    const { env, us, workId } = await setup(2);
    await putCover(env, us[0], workId, A);
    const clear = await call(env, 'POST', `/admin/api/works/${workId}`, { headers: basic, body: { clearCover: true }, now: NOW + 1 });
    expect(clear.status).toBe(200);
    // 攻击者在清掉的瞬间再传一张：不生效。
    await putCover(env, us[1], workId, B, NOW + 2);
    await cron(env, NOW + 2 + DAY);
    expect(coverKey(env, workId)).toBeNull();
    // 保护期过后，该作品的下一次投票让唯一候选成为首张封面。
    await vote(env, us[0], workId, { hash: B }, NOW + 1 + COVER_CLEAR_GUARD_MS);
    expect(coverKey(env, workId)).not.toBeNull();
  });
});

describe('并发 / 幂等', () => {
  it('定时任务与投票交错、重复运行：结果一致，R2 对象只删一次', async () => {
    const { env, us, workId } = await setup(4);
    const a = await putCover(env, us[0], workId, A);
    const b = await putCover(env, us[1], workId, B, NOW + 10);
    await confirm(env, us[2], workId, B, NOW + 11);
    await confirm(env, us[3], workId, B, NOW + 12);
    const t = NOW + 10 + DAY;
    const [r1, r2] = await Promise.all([
      settlePendingCovers(env.DB, t),
      vote(env, us[0], workId, { hash: B, confirm: cand(env, workId, B).id }, t),
    ]);
    expect(r2.status).toBe(200);
    for (const k of r1.released) await env.MEDIA.delete(k);
    await cron(env, t + 1);
    expect(coverKey(env, workId)).toBe(keyOf(b));
    expect(env.MEDIA.store.has(keyOf(a))).toBe(false);
    expect(env.DB.raw.prepare('SELECT COUNT(*) n FROM cover_candidates WHERE work_id = ?1').get(workId).n).toBe(1);
  });

  it('删除账户：不符记录随之删除；候选被清理后不符记录随之删除', async () => {
    const { env, us, workId } = await setup(3);
    await putCover(env, us[0], workId, A);
    await putCover(env, us[1], workId, B, NOW + 1);
    await vote(env, us[2], workId, { hash: A, mismatch: cand(env, workId, A).id }, NOW + 2);
    await vote(env, us[2], workId, { hash: B, mismatch: cand(env, workId, B).id }, NOW + 3);
    const n = () => env.DB.raw.prepare('SELECT COUNT(*) n FROM cover_mismatches').get().n;
    expect(n()).toBe(2);
    // u1 撤掉 B（下架）→ B 零票被清理 → 指向 B 的不符记录随之删除。
    await call(env, 'POST', '/v1/shelf', { key: us[1].key, account: us[1].id, now: NOW + 4, body: { reset: true, put: [] } });
    expect(n()).toBe(1);
    expect((await call(env, 'DELETE', '/v1/me', { key: us[2].key, account: us[2].id, now: NOW + 5 })).status).toBe(204);
    expect(n()).toBe(0);
  });
});
