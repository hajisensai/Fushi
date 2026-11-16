// 拍板台（迁移 0020；src/decisions.js、/dev/decisions、scripts/decisions.mjs）。
import { describe, expect, it } from 'vitest';
import { BASE, call, makeEnv, registerUser } from './harness.js';
import { hex, sha256 } from '../src/util.js';
import { decisionStage, normalizeDecision } from '../src/decisions.js';
import { DECISIONS_CLIENT_JS } from '../src/decisions_client.js';
import { addSql, closeSql, noteSql, parseArgs, verdictSql } from '../scripts/decisions.mjs';

const NOW = Date.UTC(2026, 10, 10, 12);
const DAY = 24 * 3600 * 1000;
const basic = { Authorization: `Basic ${btoa('admin:pw')}` };

let seq = 0;
async function devSession(env) {
  const dev = await registerUser(env, 'dev', { now: NOW });
  expect((await call(env, 'POST', `/admin/api/accounts/${dev.id}/role`, { headers: basic, body: { role: 'dev' }, now: NOW })).status).toBe(200);
  seq += 1;
  const token = `dtok${seq}`.padEnd(43, 'x');
  env.DB.raw.prepare('INSERT INTO dev_sessions (token_hash, account_id, expires_at) VALUES (?, ?, ?)')
    .run(hex(await sha256(new TextEncoder().encode(token))), dev.id, NOW + DAY);
  return { dev, cookie: `fushi_dev=${token}` };
}

function page(env, s, stage = 'todo') {
  return call(env, 'GET', `/dev/decisions?stage=${stage}`, { headers: { Cookie: s.cookie }, now: NOW });
}

function submit(env, s, id, fields, { now = NOW, origin = BASE, accept } = {}) {
  const body = new TextEncoder().encode(new URLSearchParams(fields).toString());
  return call(env, 'POST', `/dev/d/${id}`, {
    headers: {
      Cookie: s.cookie, Origin: origin, 'Content-Type': 'application/x-www-form-urlencoded', ...(accept ? { Accept: accept } : {}),
    },
    body,
    now,
  });
}

function row(env, id) {
  return env.DB.raw.prepare('SELECT * FROM decisions WHERE id = ?').get(id);
}

const ITEMS = [
  { id: 'pr3162a', kind: 'pr', title: '缓存策略取舍', ask: '要不要把缓存改成按集？', source: 'https://github.com/hajisensai/Fushi/pull/3162', rec: 'do' },
  {
    id: 'C9wcnKaPq_', kind: 'feedback', title: '点句子跳播', ask: '左键行为三选一', rec: 'weigh',
    choices: [{ key: 'a', label: 'a 中键跳句' }, { key: 'b', label: 'b 没点中词才跳' }],
  },
];

describe('normalizeDecision / CLI SQL', () => {
  it('校验 id、kind、必填字段与 choices', () => {
    expect(normalizeDecision(ITEMS[0]).kind).toBe('pr');
    expect(() => normalizeDecision({ ...ITEMS[0], id: 'a b' })).toThrow(/id/);
    expect(() => normalizeDecision({ ...ITEMS[0], kind: 'x' })).toThrow(/kind/);
    expect(() => normalizeDecision({ ...ITEMS[0], ask: '  ' })).toThrow(/ask/);
    expect(() => normalizeDecision({ ...ITEMS[1], choices: [{ key: 'a' }] })).toThrow(/choices/);
    expect(() => normalizeDecision({ ...ITEMS[1], choices: [{ key: 'a' }, { key: 'a' }] })).toThrow(/重复/);
  });

  it('add 重复写入不覆盖已拍结果；迁移字段只作用于新插入的行', () => {
    const env = makeEnv();
    env.DB.raw.exec(addSql(ITEMS, NOW).sql);
    env.DB.raw.exec(verdictSql('pr3162a', 'skip', NOW + 1));
    const again = addSql([{ ...ITEMS[0], title: '改过的标题', verdict: 'do', notes: [{ author: 'dev', body: '重复' }] }], NOW + 2);
    env.DB.raw.exec(again.sql);
    const r = row(env, 'pr3162a');
    expect(r.title).toBe('缓存策略取舍');
    expect(r.verdict).toBe('skip');
    expect(env.DB.raw.prepare('SELECT COUNT(*) AS n FROM decision_notes').get().n).toBe(0);

    env.DB.raw.exec(addSql([{ id: 'zDThL5i5Kr', title: 'AI 翻译字幕', ask: '做不做', verdict: 'never', verdictAt: NOW - 5,
      notes: [{ author: 'dev', body: '不做，拉黑', at: NOW - 6 }] }], NOW + 3).sql);
    const m = row(env, 'zDThL5i5Kr');
    expect(m.verdict).toBe('never');
    expect(m.verdict_at).toBe(NOW - 5);
    expect(env.DB.raw.prepare("SELECT body FROM decision_notes WHERE decision_id = 'zDThL5i5Kr'").get().body).toBe('不做，拉黑');
  });

  it('参数解析：--json 是路径、--raw 是布尔', () => {
    expect(parseArgs(['add', '--json', 'a.json']).flags.json).toBe('a.json');
    expect(parseArgs(['list', '--stage', 'exec', '--raw']).flags).toEqual({ stage: 'exec', raw: true });
    expect(() => verdictSql('x', 'maybe', NOW)).toThrow();
    expect(() => closeSql('x', 'done', '  ', NOW)).toThrow(/处理结果/);
  });
});

describe('/dev/decisions', () => {
  it('需要开发者会话', async () => {
    const env = makeEnv();
    expect((await call(env, 'GET', '/dev/decisions', { now: NOW })).status).toBe(303);
  });

  it('拍板 + 留言 → 待执行；结单后进已结', async () => {
    const env = makeEnv();
    env.DB.raw.exec(addSql(ITEMS, NOW - 10).sql);
    const s = await devSession(env);
    const p = await page(env, s);
    expect(p.status).toBe(200);
    expect(p.data).toContain('缓存策略取舍');
    expect(p.data).toContain('PR #3162');
    expect(p.data).toContain('a 中键跳句');
    expect(p.data).toContain('<a href="/dev/decisions">拍板</a>');

    const r = await submit(env, s, 'pr3162a', { v: 'do', text: '照做，顺手把旧缓存清掉', back: 'todo' });
    expect(r.status).toBe(303);
    expect(r.res.headers.get('Location')).toBe('/dev/decisions?stage=todo#d-pr3162a');
    const after = row(env, 'pr3162a');
    expect(after.verdict).toBe('do');
    expect(after.verdict_by).toBe(s.dev.id);
    expect((await page(env, s, 'exec')).data).toContain('照做，顺手把旧缓存清掉');
    // 全部事项都渲染（客户端本地切栏），不在当前栏的带 hidden。
    expect((await page(env, s, 'todo')).data).toMatch(/<article[^>]*id="d-pr3162a"[^>]*hidden>/);

    env.DB.raw.exec(closeSql('pr3162a', 'done', '已在 #3170 实现', NOW + 5));
    const closed = await page(env, s, 'closed');
    expect(closed.data).toContain('已在 #3170 实现');
    expect((await submit(env, s, 'pr3162a', { v: 'skip' })).status).toBe(409);
  });

  it('没看懂 → 等解释；Claude 留言后回到待拍', async () => {
    const env = makeEnv();
    env.DB.raw.exec(addSql(ITEMS, NOW - 10).sql);
    const s = await devSession(env);
    await submit(env, s, 'pr3162a', { v: 'explain', text: '按集是什么意思' });
    expect(decisionStage({ ...row(env, 'pr3162a'), claude_at: null })).toBe('explain');
    expect((await page(env, s, 'explain')).data).toContain('按集是什么意思');
    env.DB.raw.exec(noteSql('pr3162a', '现在按整部缓存，按集指每集一份。', NOW + 60000));
    const todo = await page(env, s, 'todo');
    expect(todo.data).toContain('已补充解释，请重拍');
    expect(todo.data).toContain('现在按整部缓存');
  });

  it('多方案：选项按钮、拒绝不存在的方案与「做」', async () => {
    const env = makeEnv();
    env.DB.raw.exec(addSql(ITEMS, NOW - 10).sql);
    const s = await devSession(env);
    expect((await submit(env, s, 'C9wcnKaPq_', { v: 'choice:z' })).status).toBe(400);
    expect((await submit(env, s, 'C9wcnKaPq_', { v: 'do' })).status).toBe(400);
    expect((await submit(env, s, 'C9wcnKaPq_', { v: 'choice:a' })).status).toBe(303);
    expect(row(env, 'C9wcnKaPq_').choice).toBe('a');
    expect((await submit(env, s, 'C9wcnKaPq_', { v: 'clear' })).status).toBe(303);
    expect(row(env, 'C9wcnKaPq_').verdict).toBe(null);
  });

  it('只留言不改决定；POST 必须带本站 Origin；未知事项 404', async () => {
    const env = makeEnv();
    env.DB.raw.exec(addSql(ITEMS, NOW - 10).sql);
    const s = await devSession(env);
    await submit(env, s, 'pr3162a', { v: 'never' });
    await submit(env, s, 'pr3162a', { v: 'note', text: '补一句' });
    expect(row(env, 'pr3162a').verdict).toBe('never');
    expect((await page(env, s, 'never')).data).toContain('补一句');
    expect((await submit(env, s, 'pr3162a', { v: 'do' }, { origin: 'https://evil.example' })).status).toBe(403);
    expect((await submit(env, s, 'nope', { v: 'do' })).status).toBe(404);
  });

  it('页面转义事项与留言里的 HTML', async () => {
    const env = makeEnv();
    env.DB.raw.exec(addSql([{ id: 'x1', title: '<script>t</script>', ask: '<img src=x>' }], NOW - 10).sql);
    const s = await devSession(env);
    await submit(env, s, 'x1', { v: 'note', text: '<b>hi</b>' });
    const p = await page(env, s, 'all');
    expect(p.data).not.toContain('<script>t</script>');
    expect(p.data).not.toContain('<img src=x>');
    expect(p.data).not.toContain('<b>hi</b>');
  });

  it('页面一次渲染全部事项，非当前栏 hidden；放行本站脚本', async () => {
    const env = makeEnv();
    env.DB.raw.exec(addSql(ITEMS, NOW - 10).sql);
    const s = await devSession(env);
    await submit(env, s, 'pr3162a', { v: 'do' });
    const p = await page(env, s, 'todo');
    expect(p.data).toMatch(/<article[^>]*id="d-pr3162a"[^>]*data-stage="exec"[^>]*hidden>/);
    expect(p.data).toMatch(/<article[^>]*id="d-C9wcnKaPq_"[^>]*data-stage="todo"[^>]*tabindex="-1">/);
    expect(p.res.headers.get('Content-Security-Policy')).toContain("script-src 'self'");
    const src = /<script src="(\/dev\/decisions\.js\?v=[a-z0-9]+)" defer>/.exec(p.data);
    expect(src).not.toBeNull();
    const js = await call(env, 'GET', src[1], { headers: { Cookie: s.cookie }, now: NOW });
    expect(js.status).toBe(200);
    expect(js.res.headers.get('Content-Type')).toContain('javascript');
    // 其他处理台页面仍然禁脚本。
    const list = await call(env, 'GET', '/dev', { headers: { Cookie: s.cookie }, now: NOW });
    expect(list.res.headers.get('Content-Security-Policy')).toContain("default-src 'none'");
    expect(list.res.headers.get('Content-Security-Policy')).not.toContain('script-src');
  });

  it('客户端脚本能解析，且不含会被 String.raw 当插值的片段', () => {
    expect(() => new Function(DECISIONS_CLIENT_JS)).not.toThrow();
    expect(DECISIONS_CLIENT_JS).not.toContain('`');
  });

  it('Accept: application/json 的拍板回新卡片，不跳转；撤销恢复上一个决定', async () => {
    const env = makeEnv();
    env.DB.raw.exec(addSql(ITEMS, NOW - 10).sql);
    const s = await devSession(env);
    const r = await submit(env, s, 'C9wcnKaPq_', { v: 'choice:b', text: '选 b' }, { accept: 'application/json' });
    expect(r.status).toBe(200);
    expect(r.data.item.id).toBe('C9wcnKaPq_');
    expect(r.data.item.stage).toBe('exec');
    expect(r.data.item.never).toBe(false);
    expect(r.data.item.html).toContain('data-verdict="choice:b"');
    expect(r.data.item.html).toContain('选 b');
    expect(r.data.item.html).toMatch(/class="vb v-do on"[^>]*>b 没点中词才跳/);
    expect(r.data.sig).toMatch(/^\d+\.\d+\.\d+$/);

    const undo = await submit(env, s, 'C9wcnKaPq_', { v: 'clear' }, { accept: 'application/json' });
    expect(undo.data.item.stage).toBe('todo');
    expect(row(env, 'C9wcnKaPq_').verdict).toBe(null);

    const bad = await submit(env, s, 'C9wcnKaPq_', { v: 'choice:z' }, { accept: 'application/json' });
    expect(bad.status).toBe(400);
    expect(bad.data.error).toBe('bad_choice');
  });

  it('decisions.json：签名没变回 same，有新事项 / 留言后回全部卡片', async () => {
    const env = makeEnv();
    env.DB.raw.exec(addSql(ITEMS, NOW - 10).sql);
    const s = await devSession(env);
    const get = (sig) => call(env, 'GET', `/dev/decisions.json?sig=${encodeURIComponent(sig)}`, { headers: { Cookie: s.cookie }, now: NOW });
    const first = await get('');
    expect(first.status).toBe(200);
    expect(first.data.items.map((i) => i.id).sort()).toEqual(['C9wcnKaPq_', 'pr3162a']);
    expect((await get(first.data.sig)).data).toEqual({ sig: first.data.sig, same: true });

    env.DB.raw.exec(noteSql('pr3162a', '补充一句', NOW + 1));
    const afterNote = await get(first.data.sig);
    expect(afterNote.data.same).toBeUndefined();
    const v0 = first.data.items.find((i) => i.id === 'pr3162a').v;
    const v1 = afterNote.data.items.find((i) => i.id === 'pr3162a').v;
    expect(v1).not.toBe(v0);
    expect(afterNote.data.items.find((i) => i.id === 'pr3162a').html).toContain('补充一句');

    env.DB.raw.exec(addSql([{ id: 'n3w', title: '新事项', ask: '要不要' }], NOW + 2).sql);
    const afterAdd = await get(afterNote.data.sig);
    expect(afterAdd.data.items.map((i) => i.id)).toContain('n3w');

    expect((await call(env, 'GET', '/dev/decisions.json', { now: NOW })).status).toBe(401);
  });

  it('乐观锁：两人同时拍同一条，后到的 409 不覆盖，回最新卡；留言也不写', async () => {
    const env = makeEnv();
    env.DB.raw.exec(addSql(ITEMS, NOW - 10).sql);
    const a = await devSession(env);
    const b = await devSession(env);
    // 两人打开页面时都看到「未拍」（base = ''）。
    const ra = await submit(env, a, 'pr3162a', { v: 'do', base: '' }, { accept: 'application/json' });
    expect(ra.status).toBe(200);
    const rb = await submit(env, b, 'pr3162a', { v: 'skip', text: '我觉得不做', base: '' }, { accept: 'application/json' });
    expect(rb.status).toBe(409);
    expect(rb.data.error).toBe('verdict_conflict');
    expect(rb.data.item.html).toContain('data-verdict="do"');
    const r = row(env, 'pr3162a');
    expect(r.verdict).toBe('do');
    expect(r.verdict_by).toBe(a.dev.id);
    expect(env.DB.raw.prepare("SELECT COUNT(*) AS n FROM decision_notes WHERE decision_id = 'pr3162a'").get().n).toBe(0);

    // 拿到最新卡后（base = 'do'）再拍就能改。
    expect((await submit(env, b, 'pr3162a', { v: 'skip', base: 'do' }, { accept: 'application/json' })).status).toBe(200);
    expect(row(env, 'pr3162a').verdict).toBe('skip');
  });

  it('乐观锁：别人拍成的正好是同一个决定 → 成功不冲突，留言照写；只留言不受锁影响', async () => {
    const env = makeEnv();
    env.DB.raw.exec(addSql(ITEMS, NOW - 10).sql);
    const a = await devSession(env);
    const b = await devSession(env);
    await submit(env, a, 'C9wcnKaPq_', { v: 'choice:a', base: '' }, { accept: 'application/json' });
    const same = await submit(env, b, 'C9wcnKaPq_', { v: 'choice:a', text: '同意 a', base: '' }, { accept: 'application/json' });
    expect(same.status).toBe(200);
    expect(row(env, 'C9wcnKaPq_').verdict_by).toBe(a.dev.id);
    expect(same.data.item.html).toContain('同意 a');
    const note = await submit(env, b, 'C9wcnKaPq_', { v: 'note', text: '再补一句', base: '' }, { accept: 'application/json' });
    expect(note.status).toBe(200);
    expect(note.data.item.html).toContain('再补一句');
  });

  it('乐观锁：读到行之后别人抢先写入（条件 UPDATE 不命中）也判冲突', async () => {
    const env = makeEnv();
    env.DB.raw.exec(addSql(ITEMS, NOW - 10).sql);
    const a = await devSession(env);
    // 在 submitDecision 读完行、写之前插一笔别人的决定。
    const realPrepare = env.DB.prepare.bind(env.DB);
    let injected = false;
    env.DB.prepare = (sql) => {
      if (!injected && sql.includes('AND COALESCE(CASE WHEN verdict')) {
        injected = true;
        env.DB.raw.prepare("UPDATE decisions SET verdict = 'never', updated_at = ? WHERE id = 'pr3162a'").run(NOW + 1);
      }
      return realPrepare(sql);
    };
    const r = await submit(env, a, 'pr3162a', { v: 'do', text: '做', base: '' }, { accept: 'application/json' });
    expect(r.status).toBe(409);
    expect(row(env, 'pr3162a').verdict).toBe('never');
    expect(env.DB.raw.prepare("SELECT COUNT(*) AS n FROM decision_notes WHERE decision_id = 'pr3162a'").get().n).toBe(0);
  });

  it('乐观锁：无脚本表单冲突时跳回「全部」并提示', async () => {
    const env = makeEnv();
    env.DB.raw.exec(addSql(ITEMS, NOW - 10).sql);
    const a = await devSession(env);
    await submit(env, a, 'pr3162a', { v: 'later', base: '' });
    const r = await submit(env, a, 'pr3162a', { v: 'do', base: '' });
    expect(r.status).toBe(303);
    expect(r.res.headers.get('Location')).toBe('/dev/decisions?stage=all&conflict=1#d-pr3162a');
    const p = await call(env, 'GET', '/dev/decisions?stage=all&conflict=1', { headers: { Cookie: a.cookie }, now: NOW });
    expect(p.data).toContain('已被别人改了决定');
    expect(p.data).toContain('name="base" value="later"');
  });
});
