// 拍板台（迁移 0020；src/decisions.js、/dev/decisions、scripts/decisions.mjs）。
import { describe, expect, it } from 'vitest';
import { BASE, call, makeEnv, registerUser } from './harness.js';
import { hex, sha256 } from '../src/util.js';
import { decisionStage, normalizeDecision } from '../src/decisions.js';
import { DECISIONS_CLIENT_JS } from '../src/decisions_client.js';
import { addSql, attachPlan, closeSql, noteSql, parseArgs, verdictSql } from '../scripts/decisions.mjs';

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

  it('要设计图 → 等解释栏标「等 Claude 画设计图」；附图并留言后回到待拍', async () => {
    const env = makeEnv();
    env.DB.raw.exec(addSql(ITEMS, NOW - 10).sql);
    const s = await devSession(env);
    const before = (await page(env, s, 'todo')).data;
    expect(before).toContain('value="mockup"');
    expect(before).toContain('data-key="d"');
    const r = await submit(env, s, 'pr3162a', { v: 'mockup', text: '两种缓存的设置页各画一张' });
    expect(r.status).toBe(303);
    expect(row(env, 'pr3162a').verdict).toBe('mockup');
    const waiting = (await page(env, s, 'explain')).data;
    expect(waiting).toContain('等 Claude 画设计图');
    expect(waiting).toContain('想看哪部分的设计图');
    env.DB.raw.prepare('UPDATE decisions SET files = ? WHERE id = ?').run(JSON.stringify([
      { name: 'a-整部.html', type: 'text/html', key: 'decisions/pr3162a/1-a.html', bytes: 9 },
    ]), 'pr3162a');
    env.DB.raw.exec(noteSql('pr3162a', 'a 是整部缓存的设置页', NOW + 60000));
    const todo = (await page(env, s, 'todo')).data;
    expect(todo).toContain('设计图已附上，请重拍');
    expect(todo).toContain('<iframe src="/dev/d/pr3162a/f/0"');
    expect(parseArgs(['verdict', 'pr3162a', 'mockup']).rest).toEqual(['mockup']);
    expect(() => verdictSql('pr3162a', 'mockup', NOW)).not.toThrow();
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

  it('原文默认展开显示：写入方给的 original 优先，反馈类事项联表取用户原话，都转义', async () => {
    const env = makeEnv();
    env.DB.raw.prepare(`INSERT INTO feedback (id, ticket_hash, category, title, body, created_at, updated_at)
      VALUES ('C9wcnKaPq_', 'h', 'suggestion', '想点句子跳播', '左键点句子<b>直接</b>跳到那句', ?, ?)`).run(NOW - 50, NOW - 50);
    env.DB.raw.exec(addSql([
      ...ITEMS,
      { id: 'pr9', kind: 'pr', title: '外部 PR', ask: '要不要', original: 'Add <i>foo</i> option' },
    ], NOW - 10).sql);
    expect(row(env, 'pr9').original).toBe('Add <i>foo</i> option');
    const s = await devSession(env);
    const p = (await page(env, s, 'all')).data;
    const card = (id) => p.slice(p.indexOf(`id="d-${id}"`), p.indexOf('</article>', p.indexOf(`id="d-${id}"`)));
    expect(card('pr9')).toContain('<details class="dorig" open><summary>原文</summary>');
    expect(card('pr9')).toContain('Add &#60;i&#62;foo&#60;/i&#62; option');
    expect(card('C9wcnKaPq_')).toContain('想点句子跳播');
    expect(card('C9wcnKaPq_')).toContain('左键点句子&#60;b&#62;直接&#60;/b&#62;跳到那句');
    expect(card('pr3162a')).not.toContain('dorig');
    // 拍板后回给客户端的单卡同样带原文（getDecision 与列表共用列）。
    const r = await submit(env, s, 'C9wcnKaPq_', { v: 'choice:a' }, { accept: 'application/json' });
    expect(r.status).toBe(200);
    expect(JSON.stringify(r.data)).toContain('想点句子跳播');
    expect(() => normalizeDecision({ ...ITEMS[0], original: 'x'.repeat(8001) })).toThrow(/original/);
  });

  it('原文图片：反馈截图走本站附件、原文里只嵌 GitHub 白名单图片，CSP 同步放行', async () => {
    const env = makeEnv();
    const att = JSON.stringify([
      { slot: 's0', kind: 'screenshot', key: 'k0', bytes: 10 }, { slot: 'v0', kind: 'video', key: 'kv', bytes: 10 },
      { slot: 'log', kind: 'log', key: 'kl', bytes: 10 },
    ]);
    env.DB.raw.prepare(`INSERT INTO feedback (id, ticket_hash, category, title, body, attachments, created_at, updated_at)
      VALUES ('fbimg1', 'h', 'bug', '截图反馈', '看图', ?, ?, ?)`).run(att, NOW - 50, NOW - 50);
    const gh = 'https://github.com/user-attachments/assets/9a349d0b-e47d-4349-81b4-2a7a235a9bb0';
    env.DB.raw.exec(addSql([
      { id: 'fbimg1', kind: 'feedback', title: '反馈', ask: '要不要' },
      {
        id: 'pr10', kind: 'pr', title: 'PR 带图', ask: '要不要',
        original: `before\n![shot](${gh})\n<img width="300" src="https://user-images.githubusercontent.com/1/a.png">\n`
          + `![evil](https://evil.example/x.png)\n![dup](${gh})\nhttps://github.com/user-attachments/assets/aaaa-video`,
      },
    ], NOW - 10).sql);
    const s = await devSession(env);
    const res = await page(env, s, 'all');
    const p = res.data;
    const card = (id) => p.slice(p.indexOf(`id="d-${id}"`), p.indexOf('</article>', p.indexOf(`id="d-${id}"`)));
    const fb = card('fbimg1');
    expect(fb).toContain('<img src="/dev/f/fbimg1/a/s0"');
    expect(fb).not.toContain('/a/log');
    expect(fb).toContain('反馈详情（含视频）');
    const pr = card('pr10');
    expect(pr.match(/<img /g)).toHaveLength(2);
    expect(pr).toContain(`<img src="${gh}"`);
    expect(pr).toContain('<img src="https://user-images.githubusercontent.com/1/a.png"');
    expect(pr).not.toContain('<img src="https://evil.example');
    expect(pr).not.toContain('<img src="https://github.com/user-attachments/assets/aaaa-video"');
    const csp = res.res.headers.get('Content-Security-Policy');
    expect(csp).toContain("img-src 'self' https://github.com https://github-production-user-asset-6210df.s3.amazonaws.com");
    expect(csp).not.toMatch(/img-src[^;]*https:(\s|;|$)/);
  });

  it('附件：attach 计划校验格式 / 大小 / 数量，key 落在 decisions/<id>/ 下', () => {
    const plan = attachPlan('pr9', '[]', [{ path: 'D:/x/设计 稿.html', bytes: 100 }, { path: '/tmp/a.MD', bytes: 5 }], () => 'n0');
    expect(plan.uploads.map((u) => [u.key, u.type])).toEqual([
      ['decisions/pr9/n0-_.html', 'text/html; charset=utf-8'], ['decisions/pr9/n0-a.MD', 'text/plain; charset=utf-8'],
    ]);
    expect(JSON.parse(plan.files).map((f) => f.name)).toEqual(['设计 稿.html', 'a.MD']);
    expect(() => attachPlan('pr9', '[]', [{ path: 'a.exe', bytes: 1 }])).toThrow(/不支持/);
    expect(() => attachPlan('pr9', '[]', [{ path: 'a.png', bytes: 11 * 1024 * 1024 }])).toThrow(/10 MB/);
    const ten = JSON.stringify(Array.from({ length: 10 }, (_, i) => ({ name: `${i}.png`, key: `decisions/pr9/${i}`, bytes: 1 })));
    expect(() => attachPlan('pr9', ten, [{ path: 'b.png', bytes: 1 }])).toThrow(/最多 10/);
    expect(() => attachPlan('a b', '[]', [{ path: 'b.png', bytes: 1 }])).toThrow(/id/);
  });

  it('附件：卡片预览 html（sandbox iframe）/ 图片 / md 链接；取文件回包带 sandbox CSP，越界与外部 key 一律 404', async () => {
    const env = makeEnv();
    env.DB.raw.exec(addSql([{ id: 'design-x', kind: 'design', title: '设计', ask: '选哪个' }], NOW - 10).sql);
    const files = [
      { name: 'mock.html', type: 'text/html', key: 'decisions/design-x/1-mock.html', bytes: 2048 },
      { name: 'a.png', type: 'image/png', key: 'decisions/design-x/2-a.png', bytes: 10 },
      { name: 'spec.md', type: 'text/plain', key: 'decisions/design-x/3-spec.md', bytes: 10 },
      { name: 'evil.html', type: 'text/html', key: 'feedback/other/secret', bytes: 10 },
    ];
    env.DB.raw.prepare('UPDATE decisions SET files = ? WHERE id = ?').run(JSON.stringify(files), 'design-x');
    await env.MEDIA.put('decisions/design-x/1-mock.html', new TextEncoder().encode('<h1>hi</h1>'));
    await env.MEDIA.put('decisions/design-x/3-spec.md', new TextEncoder().encode('# 规格'));
    await env.MEDIA.put('feedback/other/secret', new TextEncoder().encode('secret'));
    const s = await devSession(env);
    const res = await page(env, s, 'all');
    const p = res.data;
    expect(p).toContain('<iframe src="/dev/d/design-x/f/0"');
    expect(p).toContain('sandbox="allow-scripts allow-popups allow-forms allow-modals"');
    expect(p).toContain('<img src="/dev/d/design-x/f/1"');
    expect(p).toContain('<a href="/dev/d/design-x/f/2" target="_blank" rel="noopener">spec.md</a>');
    expect(p).not.toContain('evil.html');
    expect(res.res.headers.get('Content-Security-Policy')).toContain("frame-src 'self'");

    const get = (n) => call(env, 'GET', `/dev/d/design-x/f/${n}`, { headers: { Cookie: s.cookie }, now: NOW });
    const html = await get(0);
    expect(html.status).toBe(200);
    expect(html.data).toBe('<h1>hi</h1>');
    expect(html.res.headers.get('Content-Type')).toBe('text/html; charset=utf-8');
    expect(html.res.headers.get('Content-Security-Policy')).toMatch(/^sandbox allow-scripts/);
    expect(html.res.headers.get('Content-Security-Policy')).toContain("frame-ancestors 'self'");
    expect(html.res.headers.get('X-Content-Type-Options')).toBe('nosniff');
    const md = await get(2);
    expect(md.data).toBe('# 规格');
    expect(md.res.headers.get('Content-Type')).toBe('text/plain; charset=utf-8');
    expect((await get(1)).status).toBe(404); // R2 里没有
    expect((await get(3)).status).toBe(404); // key 不在本事项前缀下，不认
    expect((await get(9)).status).toBe(404);
    // 未登录拿不到附件。
    expect((await call(env, 'GET', '/dev/d/design-x/f/0', { now: NOW })).status).toBe(303);
  });

  it('网页上传附件：multipart 收下写 R2、追加进 files、留言记一笔；校验格式 / 大小 / 数量 / 结单 / Origin', async () => {
    const env = makeEnv();
    env.DB.raw.exec(addSql([{ id: 'up1', title: '传图', ask: '看图' }], NOW - 10).sql);
    const s = await devSession(env);
    const up = async (files, { origin = BASE, accept = 'application/json', id = 'up1' } = {}) => {
      const fd = new FormData();
      for (const [name, text, type] of files) fd.append('file', new File([text], name, { type: type || 'application/octet-stream' }));
      fd.append('back', 'all');
      const req = new Response(fd);
      return call(env, 'POST', `/dev/d/${id}/files`, {
        headers: { Cookie: s.cookie, Origin: origin, 'Content-Type': req.headers.get('Content-Type'), Accept: accept },
        body: new Uint8Array(await req.arrayBuffer()),
        now: NOW,
      });
    };
    const r = await up([['设计 A.html', '<p>A</p>', 'text/html'], ['image.png', 'png-bytes', 'image/png']]);
    expect(r.status).toBe(200);
    expect(r.data.item.html).toContain('<iframe src="/dev/d/up1/f/0"');
    expect(r.data.item.html).toContain('开发者上传');
    const files = JSON.parse(row(env, 'up1').files);
    expect(files.map((f) => [f.name, f.by, f.bytes])).toEqual([['设计 A.html', 'dev', 8], ['image.png', 'dev', 9]]);
    expect(files.every((f) => f.key.startsWith('decisions/up1/'))).toBe(true);
    expect(new TextDecoder().decode(env.MEDIA.store.get(files[0].key).bytes)).toBe('<p>A</p>');
    expect(env.DB.raw.prepare("SELECT body FROM decision_notes WHERE decision_id = 'up1'").get().body).toBe('上传了附件：设计 A.html、image.png');
    const got = await call(env, 'GET', '/dev/d/up1/f/0', { headers: { Cookie: s.cookie }, now: NOW });
    expect(got.data).toBe('<p>A</p>');
    // 无脚本表单：303 回原栏。
    const plain = await up([['b.md', '# b']], { accept: 'text/html' });
    expect(plain.status).toBe(303);
    expect(plain.res.headers.get('Location')).toBe('/dev/decisions?stage=all#d-up1');

    expect((await up([['x.exe', 'x']])).data.error).toBe('bad_file_type');
    expect((await up([])).data.error).toBe('no_file');
    expect((await up([['a.png', 'x']], { origin: 'https://evil.example' })).status).toBe(403);
    expect((await up([['a.png', 'x']], { id: 'nope' })).status).toBe(404);
    const many = Array.from({ length: 8 }, (_, i) => [`${i}.txt`, 'x']);
    expect((await up(many)).data.error).toBe('too_many_files');
    expect(JSON.parse(row(env, 'up1').files)).toHaveLength(3);
    env.DB.raw.exec(closeSql('up1', 'done', '做完了', NOW + 1));
    expect((await up([['c.png', 'x']])).data.error).toBe('decision_closed');
    // 结单的卡不再有上传表单。
    expect((await page(env, s, 'all')).data).not.toContain('action="/dev/d/up1/files"');
  });

  it('网页上传：单个文件超过 10 MB 拒收', async () => {
    const env = makeEnv();
    env.DB.raw.exec(addSql([{ id: 'up2', title: '大', ask: '大' }], NOW - 10).sql);
    const s = await devSession(env);
    const fd = new FormData();
    fd.append('file', new File([new Uint8Array(10 * 1024 * 1024 + 1)], 'big.png'));
    const req = new Response(fd);
    const r = await call(env, 'POST', '/dev/d/up2/files', {
      headers: { Cookie: s.cookie, Origin: BASE, 'Content-Type': req.headers.get('Content-Type'), Accept: 'application/json' },
      body: new Uint8Array(await req.arrayBuffer()),
      now: NOW,
    });
    expect(r.data.error).toBe('file_too_large');
    expect(env.MEDIA.store.size).toBe(0);
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

describe('附件公开分享（迁移 0025）', () => {
  /** 一条带三个附件（html / md / 外部 key）的事项 + 一个开发者会话。 */
  async function setup() {
    const env = makeEnv();
    env.DB.raw.exec(addSql([{ id: 'design-s', kind: 'design', title: '设计', ask: '选哪个' }], NOW - 10).sql);
    const files = [
      { name: 'mock.html', type: 'text/html', key: 'decisions/design-s/1-mock.html', bytes: 11 },
      { name: 'spec.md', type: 'text/plain', key: 'decisions/design-s/2-spec.md', bytes: 8 },
      { name: 'evil.html', type: 'text/html', key: 'feedback/other/secret', bytes: 6 },
    ];
    env.DB.raw.prepare('UPDATE decisions SET files = ? WHERE id = ?').run(JSON.stringify(files), 'design-s');
    await env.MEDIA.put('decisions/design-s/1-mock.html', new TextEncoder().encode('<h1>hi</h1>'));
    await env.MEDIA.put('decisions/design-s/2-spec.md', new TextEncoder().encode('# 规格'));
    await env.MEDIA.put('feedback/other/secret', new TextEncoder().encode('secret'));
    return { env, s: await devSession(env) };
  }
  const post = (env, s, path, { origin = BASE, accept = 'application/json', cookie = s && s.cookie, now = NOW } = {}) => call(env, 'POST', path, {
    headers: {
      ...(cookie ? { Cookie: cookie } : {}), Origin: origin, 'Content-Type': 'application/x-www-form-urlencoded', Accept: accept,
    },
    body: new TextEncoder().encode('back=all'),
    now,
  });
  const pub = (env, path) => call(env, 'GET', path, { now: NOW });
  const shares = (env) => env.DB.raw.prepare('SELECT * FROM decision_file_shares ORDER BY created_at, token').all();

  it('签发：回链接与新卡片，重复点幂等；公开路由不登录可读，沿用 sandbox CSP，不许嵌、不缓存、不收录', async () => {
    const { env, s } = await setup();
    const r = await post(env, s, '/dev/d/design-s/f/0/share', { now: NOW + 5 });
    expect(r.status).toBe(200);
    expect(r.data.path).toMatch(/^\/share\/f\/[A-Za-z0-9_-]{32}$/);
    expect(r.data.item.html).toContain(`href="${r.data.path}"`);
    expect(r.data.item.html).toContain('撤销分享');
    expect(r.data.item.html).toContain('action="/dev/d/design-s/f/1/share"'); // 另一个附件还没分享
    expect(row(env, 'design-s').updated_at).toBe(NOW + 5); // 卡片版本随之变化，别的页面同步得到
    const again = await post(env, s, '/dev/d/design-s/f/0/share');
    expect(again.data.path).toBe(r.data.path);
    expect(shares(env)).toHaveLength(1);
    expect(shares(env)[0]).toMatchObject({ decision_id: 'design-s', file_key: 'decisions/design-s/1-mock.html', created_by: s.dev.id });

    const got = await pub(env, r.data.path);
    expect(got.status).toBe(200);
    expect(got.data).toBe('<h1>hi</h1>');
    const h = got.res.headers;
    expect(h.get('Content-Type')).toBe('text/html; charset=utf-8');
    expect(h.get('Content-Security-Policy')).toBe("sandbox allow-scripts allow-popups allow-forms allow-modals; frame-ancestors 'none'");
    expect(h.get('X-Content-Type-Options')).toBe('nosniff');
    expect(h.get('Cache-Control')).toBe('no-store');
    expect(h.get('X-Robots-Tag')).toContain('noindex');
    expect(h.get('Referrer-Policy')).toBe('no-referrer');

    // md 按纯文本回；整页（无脚本）也渲染出公开链接。
    const md = await post(env, s, '/dev/d/design-s/f/1/share');
    const mdGot = await pub(env, md.data.path);
    expect(mdGot.data).toBe('# 规格');
    expect(mdGot.res.headers.get('Content-Type')).toBe('text/plain; charset=utf-8');
    const p = (await page(env, s, 'all')).data;
    expect(p).toContain(`<a href="${r.data.path}" class="dsharelink"`);
    expect(p).toContain(`data-href="${md.data.path}"`);
  });

  it('撤销：原链接立刻 404，卡片回到「分享」按钮；再分享换新 token，旧的仍 404；无脚本表单 303 回原栏', async () => {
    const { env, s } = await setup();
    const first = (await post(env, s, '/dev/d/design-s/f/0/share')).data.path;
    const un = await post(env, s, '/dev/d/design-s/f/0/unshare');
    expect(un.status).toBe(200);
    expect(un.data.item.html).toContain('action="/dev/d/design-s/f/0/share"');
    expect(un.data.item.html).not.toContain(first);
    expect((await pub(env, first)).status).toBe(404);
    expect(shares(env)[0].revoked_at).toBe(NOW);
    // 没有分享时撤销也算成功（幂等）。
    expect((await post(env, s, '/dev/d/design-s/f/0/unshare')).status).toBe(200);

    const second = (await post(env, s, '/dev/d/design-s/f/0/share')).data.path;
    expect(second).not.toBe(first);
    expect((await pub(env, second)).status).toBe(200);
    expect((await pub(env, first)).status).toBe(404);

    const plain = await post(env, s, '/dev/d/design-s/f/0/unshare', { accept: 'text/html' });
    expect(plain.status).toBe(303);
    expect(plain.res.headers.get('Location')).toBe('/dev/decisions?stage=all#d-design-s');
    expect((await pub(env, second)).status).toBe(404);
  });

  it('越权：签发 / 撤销要开发者会话与本站 Origin；token 只开一个附件；越界 / 外部 key / 坏 token 一律 404', async () => {
    const { env, s } = await setup();
    // 没登录、非开发者账户的会话、外站 Origin。
    expect((await post(env, null, '/dev/d/design-s/f/0/share', { cookie: null })).status).toBe(401);
    const user = await registerUser(env, 'plain', { now: NOW });
    const utok = 'utok'.padEnd(43, 'y');
    env.DB.raw.prepare('INSERT INTO dev_sessions (token_hash, account_id, expires_at) VALUES (?, ?, ?)')
      .run(hex(await sha256(new TextEncoder().encode(utok))), user.id, NOW + DAY);
    expect((await post(env, null, '/dev/d/design-s/f/0/share', { cookie: `fushi_dev=${utok}` })).status).toBe(401);
    expect((await post(env, s, '/dev/d/design-s/f/0/share', { origin: 'https://evil.example' })).status).toBe(403);
    expect(shares(env)).toHaveLength(0);

    const path = (await post(env, s, '/dev/d/design-s/f/0/share')).data.path;
    // 公开路由只读；无会话撤销被拒，链接照常可用。
    expect((await call(env, 'POST', path, { now: NOW })).status).toBe(404);
    expect((await post(env, null, '/dev/d/design-s/f/0/unshare', { cookie: null })).status).toBe(401);
    expect((await pub(env, path)).status).toBe(200);
    // token 只对应 mock.html：拼路径拿不到别的附件；处理台附件路由仍要登录。
    expect((await pub(env, `${path}/1`)).status).toBe(404);
    expect((await pub(env, '/dev/d/design-s/f/1')).status).toBe(303);
    expect((await pub(env, `/share/f/${'A'.repeat(32)}`)).status).toBe(404);
    expect((await pub(env, '/share/f/short')).status).toBe(404);
    // 越界序号、被过滤掉的外部 key（合法列表只有 2 个）、不存在的事项。
    expect((await post(env, s, '/dev/d/design-s/f/2/share')).status).toBe(404);
    expect((await post(env, s, '/dev/d/design-s/f/9/share')).status).toBe(404);
    expect((await post(env, s, '/dev/d/nope/f/0/share')).status).toBe(404);
  });

  it('失效：签发人被撤开发者 → 404（恢复后可用）；附件从事项里删掉 → 404，不会错指到顶上来的附件', async () => {
    const { env, s } = await setup();
    const path = (await post(env, s, '/dev/d/design-s/f/0/share')).data.path;
    const role = (r) => call(env, 'POST', `/admin/api/accounts/${s.dev.id}/role`, { headers: basic, body: { role: r }, now: NOW });
    expect((await role('user')).status).toBe(200);
    expect((await pub(env, path)).status).toBe(404);
    expect((await role('dev')).status).toBe(200);
    expect((await pub(env, path)).status).toBe(200);
    const files = JSON.parse(row(env, 'design-s').files).slice(1);
    env.DB.raw.prepare('UPDATE decisions SET files = ? WHERE id = ?').run(JSON.stringify(files), 'design-s');
    expect((await pub(env, path)).status).toBe(404);
  });

  it('签发人被撤开发者后：处理台不再显示那条死链接；别的开发者重新分享拿到新的可用链接，旧的永久作废', async () => {
    const { env, s } = await setup();
    const other = await devSession(env);
    const dead = (await post(env, s, '/dev/d/design-s/f/0/share')).data.path;
    expect((await call(env, 'POST', `/admin/api/accounts/${s.dev.id}/role`, { headers: basic, body: { role: 'user' }, now: NOW })).status).toBe(200);
    expect((await pub(env, dead)).status).toBe(404);
    const p = (await page(env, other, 'all')).data;
    expect(p).not.toContain(dead);
    expect(p).toContain('action="/dev/d/design-s/f/0/share"');

    const fresh = await post(env, other, '/dev/d/design-s/f/0/share', { now: NOW + 1 });
    expect(fresh.status).toBe(200);
    expect(fresh.data.path).not.toBe(dead);
    expect(fresh.data.item.html).toContain(`href="${fresh.data.path}"`);
    expect((await pub(env, fresh.data.path)).status).toBe(200);
    const rows = shares(env);
    expect(rows).toHaveLength(2);
    expect(rows.find((r) => r.created_by === s.dev.id).revoked_at).toBe(NOW + 1);
    // 原签发人恢复开发者也不会让死链接复活（已撤销），只有新链接有效。
    expect((await call(env, 'POST', `/admin/api/accounts/${s.dev.id}/role`, { headers: basic, body: { role: 'dev' }, now: NOW })).status).toBe(200);
    expect((await pub(env, dead)).status).toBe(404);
    expect((await pub(env, fresh.data.path)).status).toBe(200);
  });
});
