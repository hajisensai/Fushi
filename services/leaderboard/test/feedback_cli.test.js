import { gunzipSync, gzipSync } from 'node:zlib';
import { describe, expect, it } from 'vitest';
import { call, makeEnv, nextIp } from './harness.js';
import { FEEDBACK_LIMITS } from '../src/feedback.js';
import {
  devAccountSql, existingIdsSql, fixedSql, formatShow, gzipPayload, inlineSql, listSql, missingIds, parseArgs,
  parseWranglerJson, pickDevAccount, r2WhereArgs, replySql, showSql, sqlText, summarizeBatchSql,
  summarizeSql,
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
    const nasty = "总结'); DROP TABLE feedback; --\n第二行\u202e";
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
    expect(text).not.toContain('★');
  });

  it('reply：以开发者身份回复，与处理台同一份 SQL（进时间线、刷新 dev_reply_at、不改状态）', async () => {
    const env = makeEnv();
    const a = await seed(env, '甲');
    const b = await seed(env, '乙');
    env.DB.raw.exec("INSERT INTO accounts (id, email_hash, nickname, discriminator, role, created_at) VALUES ('devacct00000001', 'h', '哈吉', 1, 'dev', 0)");
    env.DB.raw.exec("INSERT INTO accounts (id, email_hash, nickname, discriminator, role, created_at) VALUES ('useracct0000001', 'u', '路人', 2, 'user', 0)");
    env.DB.raw.prepare("UPDATE feedback SET status = 'in_progress' WHERE id = ?").run(b);

    expect(() => pickDevAccount('路人', env.DB.raw.prepare(devAccountSql('路人')).all())).toThrow(/没有这个开发者账户/);
    const dev = pickDevAccount('哈吉', env.DB.raw.prepare(devAccountSql('哈吉')).all());
    expect(dev.id).toBe('devacct00000001');
    expect(env.DB.raw.prepare(devAccountSql('devacct00000001')).all()).toHaveLength(1);
    expect(() => devAccountSql('')).toThrow(/--as/);

    const sql = replySql({ [a]: "请补充版本号'); DROP TABLE feedback; --\u202e", [b]: '第二条' }, dev.id, NOW + 9);
    expect(sql).not.toMatch(/SET status/);
    env.DB.raw.exec(sql);
    for (const [id, status, body] of [[a, 'open', "请补充版本号'); DROP TABLE feedback; --"], [b, 'in_progress', '第二条']]) {
      const row = env.DB.raw.prepare('SELECT status, dev_reply_at, updated_at FROM feedback WHERE id = ?').get(id);
      expect(row).toEqual({ status, dev_reply_at: NOW + 9, updated_at: NOW + 9 });
      const msg = env.DB.raw.prepare('SELECT author, account_id, body, status FROM feedback_messages WHERE feedback_id = ? ORDER BY id DESC').get(id);
      expect(msg).toEqual({ author: 'dev', account_id: dev.id, body, status: null });
    }
    expect(() => replySql({ [a]: '   ' }, dev.id, NOW)).toThrow(/空的/);
    expect(() => replySql({ 'bad id!': 'x' }, dev.id, NOW)).toThrow(/编号不合法/);
  });

  it('reply 不撤回生成 SQL 之后别人做的结案', async () => {
    const env = makeEnv();
    const id = await seed(env, '并发结案');
    env.DB.raw.exec("INSERT INTO accounts (id, email_hash, nickname, discriminator, role, created_at) VALUES ('devacct00000001', 'h', '哈吉', 1, 'dev', 0)");
    // CLI 先生成回复 SQL（此时条目还是 open），写库之前处理台把它结了案。
    const sql = replySql({ [id]: '已收到' }, 'devacct00000001', NOW + 5);
    env.DB.raw.prepare("UPDATE feedback SET status = 'closed' WHERE id = ?").run(id);
    env.DB.raw.exec(sql);
    const row = env.DB.raw.prepare('SELECT status, dev_reply_at, updated_at FROM feedback WHERE id = ?').get(id);
    expect(row).toEqual({ status: 'closed', dev_reply_at: NOW + 5, updated_at: NOW + 5 });
  });

  it('list / show 标出开发者账户自己提的反馈', async () => {
    const env = makeEnv();
    const id = await seed(env, '内部自测');
    const other = await seed(env, '外部');
    env.DB.raw.exec("INSERT INTO accounts (id, email_hash, nickname, discriminator, role, created_at) VALUES ('devacct00000001', 'h', '哈吉', 1, 'dev', 0)");
    env.DB.raw.prepare('UPDATE feedback SET account_id = ? WHERE id = ?').run('devacct00000001', id);
    const rows = env.DB.raw.prepare(listSql({ status: 'all' })).all();
    expect(Object.fromEntries(rows.map((r) => [r.id, r.dev_reporter]))).toEqual({ [id]: '哈吉', [other]: '' });
    const [rowSql, msgSql] = showSql(id);
    expect(formatShow(env.DB.raw.prepare(rowSql).get(), env.DB.raw.prepare(msgSql).all())).toContain('★【开发者 哈吉 自己提的】');
  });

  it('fixed：与 CI 接口同一份 SQL——改状态、记时间线、重置 fixed_in；--no-app = scope none；校验 sha / 编号', async () => {
    const env = makeEnv();
    const a = await seed(env);
    const sha = 'B'.repeat(40);
    env.DB.raw.prepare(`UPDATE feedback SET fixed_in = '{"debug":{"android":{"version":"1","at":1}}}' WHERE id = ?`).run(a);
    env.DB.raw.exec(fixedSql(a, sha, 'app', NOW + 7));
    expect(env.DB.raw.prepare('SELECT status, fix_sha, fix_scope, fix_at, fixed_in, dev_reply_at, updated_at FROM feedback WHERE id = ?').get(a))
      .toEqual({ status: 'resolved', fix_sha: 'b'.repeat(40), fix_scope: 'app', fix_at: NOW + 7, fixed_in: '{}', dev_reply_at: NOW + 7, updated_at: NOW + 7 });
    expect(env.DB.raw.prepare('SELECT author, account_id, body, status FROM feedback_messages WHERE feedback_id = ?').all(a))
      .toEqual([{ author: 'dev', account_id: null, body: '', status: 'resolved' }]);
    // 同 sha 同 scope 重复执行：幂等，什么都不动。
    env.DB.raw.prepare(`UPDATE feedback SET fixed_in = '{"debug":{"android":{"version":"2","at":2}}}' WHERE id = ?`).run(a);
    const snap = env.DB.raw.prepare('SELECT * FROM feedback WHERE id = ?').get(a);
    env.DB.raw.exec(fixedSql(a, sha, 'app', NOW + 99));
    expect(env.DB.raw.prepare('SELECT * FROM feedback WHERE id = ?').get(a)).toEqual(snap);
    expect(env.DB.raw.prepare('SELECT COUNT(*) AS n FROM feedback_messages WHERE feedback_id = ?').get(a).n).toBe(1);
    // 再标一次（--no-app）：覆盖 commit 与 scope，已解决的不重复记时间线。
    env.DB.raw.exec(fixedSql(a, 'c'.repeat(40), 'none', NOW + 8));
    // 已解决的不插时间线，dev_reply_at 也不刷（与时间线同一判据，否则反馈人亮红点却没有新消息）。
    expect(env.DB.raw.prepare('SELECT fix_sha, fix_scope, dev_reply_at, updated_at FROM feedback WHERE id = ?').get(a))
      .toEqual({ fix_sha: 'c'.repeat(40), fix_scope: 'none', dev_reply_at: NOW + 7, updated_at: NOW + 8 });
    expect(env.DB.raw.prepare('SELECT COUNT(*) AS n FROM feedback_messages WHERE feedback_id = ?').get(a).n).toBe(1);

    expect(() => fixedSql(a, 'abc', 'app', NOW)).toThrow(/bad_sha/);
    expect(() => fixedSql(a, 'b'.repeat(40), 'x', NOW)).toThrow(/bad_scope/);
    expect(() => fixedSql("x' OR '1'='1", 'b'.repeat(40), 'app', NOW)).toThrow(/编号不合法/);
    expect(parseArgs(['fixed', a, '--sha', sha, '--no-app'])).toEqual({ cmd: 'fixed', id: a, flags: { sha, 'no-app': true } });
    expect(inlineSql('SELECT ?1, ?2, ?3', ["it's", 5, null])).toBe(`SELECT ${sqlText("it's")}, 5, NULL`);
    expect(() => inlineSql('SELECT ?1', [1.5])).toThrow(/不支持/);
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

  it('show --log：r2 不传 --remote，--pipe 前的代理提示行被跳过', () => {
    expect(r2WhereArgs('--remote')).toEqual([]);
    expect(r2WhereArgs('--local')).toEqual(['--local']);

    const gz = gzipSync(Buffer.from('第一行\n第二行', 'utf8'));
    const noisy = Buffer.concat([Buffer.from("Proxy environment variables detected. We'll use your proxy for fetch requests.\n"), gz]);
    expect(gunzipSync(gzipPayload(noisy)).toString('utf8')).toBe('第一行\n第二行');
    expect(gzipPayload(gz)).toBe(gz);
  });
});
