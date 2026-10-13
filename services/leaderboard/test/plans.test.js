// 成本硬门：每个读接口执行的 SELECT 都必须走索引——不许对大表 SCAN、不许为 ORDER BY 建临时 B 树。
// D1 按读取行数计费，一条退化成全表扫描的查询在用户多了之后就是账单；这里在 SQLite 的查询计划上
// 直接断言，改 SQL 的人一退化就红，不用等上线后看账单。
// （定时快照刷新里的 account_totals 全扫是有意的：每账户一行、每 30 分钟一次，单独豁免。）

import { describe, expect, it } from 'vitest';
import { call, entry, makeEnv, registerUser } from './harness.js';

const NOW = Date.UTC(2026, 8, 30, 12);
const at = (date) => ({ finishedAt: Date.parse(`${date}T10:00:00Z`), finishedDate: date });

function recordSql(env) {
  const seen = [];
  const real = env.DB.prepare;
  env.DB.prepare = (sql) => {
    const stmt = real(sql);
    const wrap = (s) => ({
      ...s,
      bind: (...a) => {
        const b = s.bind(...a);
        seen.push({ sql, args: a });
        return wrap(b);
      },
    });
    seen.push({ sql, args: [] });
    return wrap(stmt);
  };
  return seen;
}

function badPlanLines(db, sql, args) {
  if (!/^\s*(SELECT|WITH)/i.test(sql)) return [];
  let plan;
  try {
    plan = db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...args);
  } catch {
    return []; // 参数个数对不上的中间记录（prepare 未 bind），跳过
  }
  return plan
    .map((r) => r.detail)
    .filter((d) => (/^SCAN /.test(d) && !/VIRTUAL TABLE|subquery|CO-ROUTINE|json_each/i.test(d)) || /TEMP B-TREE/.test(d)); // 含 'FOR RIGHT PART OF / LAST TERM OF ORDER BY' 等变体
}

describe('查询计划：读接口不全表扫描', () => {
  it('榜单 / 人气 / 用户卡片 / 书架（含 kind、游标）/ 作品页 / 读者墙', async () => {
    const env = makeEnv();
    const users = [];
    for (let i = 0; i < 3; i++) users.push(await registerUser(env, `u${i}`, { now: NOW }));
    for (const [i, u] of users.entries()) {
      await call(env, 'POST', '/v1/shelf', {
        key: u.key, account: u.id, now: NOW,
        body: { reset: true, put: [
          entry('book', ['t:a|'], 'a', at('2026-09-29')),
          entry('manga', [`t:m${i}|`], 'm', at('2026-09-28')),
          entry('video', ['t:v|'], 'v'),
        ] },
      });
    }
    const workId = env.DB.raw.prepare("SELECT id FROM works WHERE kind = 'book'").get().id;
    const seen = recordSql(env);
    const v = users[1];
    const reads = [
      '/v1/rank?metric=book&window=week',
      '/v1/rank?metric=chars&window=all&scope=friends',
      '/v1/works/popular?window=month',
      '/v1/works/popular?window=all&kind=book',
      `/v1/users/${users[0].id}`,
      `/v1/users/${users[0].id}/shelf`,
      `/v1/users/${users[0].id}/shelf?kind=manga`,
      `/v1/users/${users[0].id}/shelf?status=reading`,
      `/v1/users/${users[0].id}/shelf?cursor=1790000000000.zzz`,
      `/v1/works/${workId}`,
      `/v1/works/${workId}?cursor=1790000000000.zzz`,
    ];
    for (const path of reads) {
      const r = await call(env, 'GET', path, { key: v.key, account: v.id, now: NOW });
      expect(r.status, path).toBe(200);
    }
    const bad = [];
    for (const { sql, args } of seen) {
      for (const line of badPlanLines(env.DB.raw, sql, args)) bad.push(`${line}\n    in: ${sql.replace(/\s+/g, ' ').slice(0, 160)}`);
    }
    expect(bad).toEqual([]);
  });

  it('上传路径的读取也走索引（别名查找、旧行、命名空间）', async () => {
    const env = makeEnv({ autoSnapshot: false }); // 快照刷新是定时任务，单独豁免
    const u = await registerUser(env, 'up', { now: NOW });
    const seen = recordSql(env);
    await call(env, 'POST', '/v1/shelf', {
      key: u.key, account: u.id, now: NOW,
      body: { put: [entry('book', ['isbn:9784040000015', 't:x|'], 'x', at('2026-09-29'))], daily: [{ date: '2026-09-29', chars: 10 }] },
    });
    const bad = [];
    for (const { sql, args } of seen) {
      for (const line of badPlanLines(env.DB.raw, sql, args)) bad.push(`${line}\n    in: ${sql.replace(/\s+/g, ' ').slice(0, 160)}`);
    }
    expect(bad).toEqual([]);
  });

  it('反馈 CI：pending 只走修复索引，released 按主键回填', async () => {
    const env = makeEnv({ autoSnapshot: false, FEEDBACK_CI_TOKEN: 't0ken' });
    const ci = { Authorization: 'Bearer t0ken' };
    const f = await call(env, 'POST', '/v1/feedback', { body: { category: 'bug', title: 't', body: 'b' }, headers: { 'CF-Connecting-IP': '198.51.100.8' }, now: NOW });
    expect((await call(env, 'POST', '/v1/ci/feedback/fixed', { body: { sha: 'a'.repeat(40), ids: [f.data.id] }, headers: ci, now: NOW })).status).toBe(200);
    const stamps = () => env.DB.raw.prepare('SELECT dev_reply_at, updated_at FROM feedback WHERE id = ?').get(f.data.id);
    const before = stamps();
    const seen = recordSql(env);
    expect((await call(env, 'GET', '/v1/ci/feedback/pending?channel=debug&platform=android', { headers: ci, now: NOW })).status).toBe(200);
    const released = { channel: 'debug', platform: 'android', version: '1.0.0', ids: [{ id: f.data.id, sha: 'a'.repeat(40) }] };
    expect((await call(env, 'POST', '/v1/ci/feedback/released', { body: released, headers: ci, now: NOW + 1 })).status).toBe(200);
    // 回填只写 fixed_in（不在任何索引里）：不碰 updated_at 所在的两条索引，也不冒充开发者回复。
    expect(stamps()).toEqual(before);
    const bad = [];
    let checked = 0;
    for (const { sql, args } of seen) {
      if (args.length === 0) continue;
      // UPDATE 也要过同一道门：EXPLAIN QUERY PLAN 对 UPDATE 同样给出扫描方式。
      if (/^\s*UPDATE feedback SET fixed_in/i.test(sql)) {
        const plan = env.DB.raw.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...args).map((r) => r.detail);
        checked += 1;
        for (const d of plan) if (/^SCAN feedback/.test(d) || /TEMP B-TREE/.test(d)) bad.push(`${d}\n    in: ${sql.replace(/\s+/g, ' ').slice(0, 160)}`);
        continue;
      }
      if (/fix_sha IS NOT NULL AND fix_scope = 'app'/.test(sql)) checked += 1;
      for (const line of badPlanLines(env.DB.raw, sql, args)) bad.push(`${line}\n    in: ${sql.replace(/\s+/g, ' ').slice(0, 160)}`);
    }
    expect(bad).toEqual([]);
    expect(checked).toBe(2);
    for (const { sql } of seen) {
      if (/^\s*UPDATE feedback SET fixed_in/i.test(sql)) expect(sql).not.toMatch(/dev_reply_at|updated_at/);
    }
  });

  it('反馈：回执读取 / 批量进度 / 处理台按状态列表走索引', async () => {
    const env = makeEnv({ autoSnapshot: false });
    const ip = { 'CF-Connecting-IP': '198.51.100.7' };
    const f = await call(env, 'POST', '/v1/feedback', { body: { category: 'bug', title: 't', body: 'b' }, headers: ip, now: NOW });
    const dev = await registerUser(env, 'dev', { now: NOW });
    env.DB.raw.prepare("UPDATE accounts SET role = 'dev' WHERE id = ?").run(dev.id);
    const seen = recordSql(env);
    const t = { 'X-Fushi-Ticket': f.data.ticket };
    expect((await call(env, 'GET', `/v1/feedback/${f.data.id}`, { headers: t, now: NOW })).status).toBe(200);
    expect((await call(env, 'POST', '/v1/feedback/status', { body: { items: [f.data] }, now: NOW })).status).toBe(200);
    expect((await call(env, 'GET', '/v1/dev/feedback?status=open', { key: dev.key, account: dev.id, now: NOW })).status).toBe(200);
    expect((await call(env, 'GET', `/v1/dev/feedback/${f.data.id}`, { key: dev.key, account: dev.id, now: NOW })).status).toBe(200);
    const bad = [];
    for (const { sql, args } of seen) {
      for (const line of badPlanLines(env.DB.raw, sql, args)) bad.push(`${line}\n    in: ${sql.replace(/\s+/g, ' ').slice(0, 160)}`);
    }
    expect(bad).toEqual([]);
  });

  it('反馈：「我的反馈」（首页 / 游标）与同账户签名读详情走索引，不建临时 B 树', async () => {
    const env = makeEnv({ autoSnapshot: false });
    const u = await registerUser(env, 'me', { now: NOW });
    const ids = [];
    for (let i = 0; i < 3; i++) {
      const r = await call(env, 'POST', '/v1/feedback', {
        key: u.key, account: u.id, body: { category: 'bug', title: `t${i}`, body: 'b' },
        headers: { 'CF-Connecting-IP': `198.51.100.${i + 1}` }, now: NOW + i,
      });
      ids.push(r.data.id);
    }
    const seen = recordSql(env);
    const first = await call(env, 'GET', '/v1/feedback/mine?limit=1', { key: u.key, account: u.id, now: NOW });
    expect(first.status).toBe(200);
    expect((await call(env, 'GET', `/v1/feedback/mine?limit=1&cursor=${encodeURIComponent(first.data.next)}`,
      { key: u.key, account: u.id, now: NOW })).status).toBe(200);
    expect((await call(env, 'GET', `/v1/feedback/${ids[0]}`, { key: u.key, account: u.id, now: NOW })).status).toBe(200);
    const bad = [];
    const mine = [];
    for (const { sql, args } of seen) {
      for (const line of badPlanLines(env.DB.raw, sql, args)) bad.push(`${line}\n    in: ${sql.replace(/\s+/g, ' ').slice(0, 160)}`);
      if (/FROM feedback WHERE account_id = \?1/.test(sql) && args.length) {
        mine.push(...env.DB.raw.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...args).map((r) => r.detail));
      }
    }
    expect(bad).toEqual([]);
    expect(mine.length).toBeGreaterThan(0);
    expect(mine.every((d) => /idx_feedback_account_created/.test(d))).toBe(true);
  });

  it('反馈：视频到期清理只读带视频的行（idx_feedback_video 部分索引），不扫整张反馈表', async () => {
    const env = makeEnv({ autoSnapshot: false });
    const seen = recordSql(env);
    const { purgeFeedbackVideos } = await import('../src/feedback.js');
    await purgeFeedbackVideos(env, NOW);
    const sel = seen.filter(({ sql, args }) => /has_video = 1/.test(sql) && /^\s*SELECT/i.test(sql) && args.length);
    expect(sel.length).toBe(1);
    const plan = env.DB.raw.prepare(`EXPLAIN QUERY PLAN ${sel[0].sql}`).all(...sel[0].args).map((r) => r.detail);
    // 部分索引只含 has_video = 1 的行（视频 30 天内必被清掉，行数有界）；不许回落成整表扫描 / 临时 B 树。
    expect(plan.join('\n')).toMatch(/idx_feedback_video/);
    expect(plan.filter((d) => /^SCAN feedback$/.test(d) || /TEMP B-TREE/.test(d))).toEqual([]);
  });
});
