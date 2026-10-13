import { describe, expect, it } from 'vitest';
import { call, makeEnv, nextIp } from './harness.js';
import { FEEDBACK_LIMITS } from '../src/feedback.js';
import {
  existingIdsSql, formatShow, listSql, missingIds, parseArgs, parseWranglerJson, showSql, sqlText, summarizeBatchSql, summarizeSql,
} from '../scripts/feedback.mjs';

const NOW = Date.UTC(2026, 9, 10, 4);

async function seed(env, title = '阅读器白屏') {
  const res = await call(env, 'POST', '/v1/feedback', {
    body: { category: 'bug', title, body: '正文', contact: 'me@example.com', meta: { platform: 'ios' } },
    headers: { 'CF-Connecting-IP': nextIp() },
    now: NOW,
  });
  expect(res.status).toBe(201);
  return res.data.id;
}

describe('scripts/feedback.mjs', () => {
  it('summarize 的 SQL 在真库上原样写回任意文本（引号 / 注入载荷 / 换行），剥伪装字符，不动 updated_at', async () => {
    const env = makeEnv();
    const id = await seed(env);
    const before = env.DB.raw.prepare('SELECT updated_at, dev_reply_at FROM feedback WHERE id = ?').get(id);
    const nasty = "总结'); DROP TABLE feedback; --\n第二行‮";
    env.DB.raw.exec(summarizeSql(id, nasty, NOW + 5));
    const row = env.DB.raw.prepare('SELECT ai_summary, ai_summary_at, updated_at, dev_reply_at FROM feedback WHERE id = ?').get(id);
    expect(row.ai_summary).toBe("总结'); DROP TABLE feedback; --\n第二行");
    expect(row.ai_summary_at).toBe(NOW + 5);
    expect({ updated_at: row.updated_at, dev_reply_at: row.dev_reply_at }).toEqual(before);

    env.DB.raw.exec(summarizeSql(id, null, NOW));
    expect(env.DB.raw.prepare('SELECT ai_summary, ai_summary_at FROM feedback WHERE id = ?').get(id))
      .toEqual({ ai_summary: null, ai_summary_at: null });
    expect(() => summarizeSql(id, '字'.repeat(FEEDBACK_LIMITS.aiSummaryMax + 1), NOW)).toThrow(/ai_summary_too_long/);
    expect(() => summarizeSql("x' OR '1'='1", 'a', NOW)).toThrow(/编号不合法/);
  });

  it('批量回写：一次写多条；任一条编号不合法整批不生成', async () => {
    const env = makeEnv();
    const a = await seed(env, '甲');
    const b = await seed(env, '乙');
    env.DB.raw.exec(summarizeBatchSql({ [a]: '总结甲', [b]: "总结'乙" }, NOW));
    expect(env.DB.raw.prepare('SELECT id, ai_summary FROM feedback ORDER BY id').all().map((r) => r.ai_summary).sort())
      .toEqual(["总结'乙", '总结甲']);
    expect(() => summarizeBatchSql({ [a]: 'x', 'bad id!': 'y' }, NOW)).toThrow(/编号不合法/);
    expect(() => summarizeBatchSql({ [a]: 3 }, NOW)).toThrow(/不是字符串/);
    expect(() => summarizeBatchSql([], NOW)).toThrow(/对象/);
  });

  it('写前核对编号：不存在的编号被找出来（UPDATE 命中 0 行不会报错）', async () => {
    const env = makeEnv();
    const a = await seed(env);
    const rows = env.DB.raw.prepare(existingIdsSql([a, 'nothere123'])).all();
    expect(missingIds([a, 'nothere123'], rows)).toEqual(['nothere123']);
    expect(missingIds([a], rows)).toEqual([]);
    expect(() => existingIdsSql(["x' OR 1=1 --"])).toThrow(/编号不合法/);
  });

  it('list / show 的 SQL 能在真库上跑；--need-summary 只列没总结的', async () => {
    const env = makeEnv();
    const a = await seed(env, '甲');
    const b = await seed(env, '乙');
    env.DB.raw.exec(summarizeSql(a, '有了', NOW));
    const need = env.DB.raw.prepare(listSql({ needSummary: true })).all().map((r) => r.id);
    expect(need).toEqual([b]);
    expect(env.DB.raw.prepare(listSql({ status: 'all' })).all()).toHaveLength(2);
    expect(() => listSql({ status: "open' OR 1=1 --" })).toThrow(/未知状态/);

    const [rowSql, msgSql] = showSql(a);
    const row = env.DB.raw.prepare(rowSql).get();
    const text = formatShow(row, env.DB.raw.prepare(msgSql).all());
    expect(text).toContain('AI 总结：');
    expect(text).toContain('有了');
    expect(text).toContain('未经核实');
    // 联系方式不进 CLI 输出。
    expect(text).not.toContain('me@example.com');
  });

  it('解析 wrangler 输出（前面可能多一行代理提示）与参数', () => {
    const body = JSON.stringify([{ results: [{ id: 'x' }], success: true }]);
    expect(parseWranglerJson(body)).toEqual([[{ id: 'x' }]]);
    expect(parseWranglerJson(`Proxy environment variables detected. We'll use your proxy for fetch requests.\n${body}`))
      .toEqual([[{ id: 'x' }]]);
    expect(() => parseWranglerJson('boom')).toThrow(/不是 JSON/);

    expect(parseArgs(['summarize', 'abcdefgh', '--text', '你好', '--local']))
      .toEqual({ cmd: 'summarize', id: 'abcdefgh', flags: { text: '你好', local: true } });
    expect(() => parseArgs(['list', '--status'])).toThrow(/需要一个值/);
    expect(sqlText(null)).toBe('NULL');
  });
});
