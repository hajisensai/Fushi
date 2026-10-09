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
});
