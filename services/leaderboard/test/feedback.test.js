import { gzipSync } from 'node:zlib';
import { describe, expect, it } from 'vitest';
import { BASE, JPEG, call, lastCode, makeEnv, nextIp, pngHeader, registerUser } from './harness.js';
import { FEEDBACK_LIMITS, purgeFeedbackAttachments } from '../src/feedback.js';
import { LOG_UNTRUSTED_HEADER } from '../src/feedback_guard.js';

const NOW = Date.UTC(2026, 9, 8, 12);
const basic = { Authorization: `Basic ${btoa('admin:pw')}` };
const PNG = pngHeader(320, 640);

function submit(env, body = {}, opts = {}) {
  return call(env, 'POST', '/v1/feedback', {
    body: { category: 'bug', title: '阅读器白屏', body: '打开某本书白屏', meta: { app: '1.2.3+45', platform: 'android' }, ...body },
    headers: { 'CF-Connecting-IP': opts.ip ?? nextIp() },
    now: opts.now ?? NOW,
    ...(opts.user ? { key: opts.user.key, account: opts.user.id } : {}),
  });
}

function withTicket(env, method, path, ticket, opts = {}) {
  return call(env, method, path, { ...opts, headers: { 'X-Fushi-Ticket': ticket, ...(opts.headers || {}) }, now: opts.now ?? NOW });
}

async function makeDev(env, name = 'dev') {
  const u = await registerUser(env, name, { now: NOW });
  const r = await call(env, 'POST', `/admin/api/accounts/${u.id}/role`, { headers: basic, body: { role: 'dev' }, now: NOW });
  expect(r.status).toBe(200);
  return u;
}

const as = (env, u, method, path, body) => call(env, method, path, { key: u.key, account: u.id, body, now: NOW });

describe('反馈人', () => {
  it('匿名提交 → 回执；凭回执看详情与批量进度；回执不对一律 404', async () => {
    const env = makeEnv();
    const r = await submit(env);
    expect(r.status).toBe(201);
    expect(r.data).toMatchObject({ status: 'open', createdAt: NOW });
    expect(r.data.ticket.length).toBe(32);
    const { id, ticket } = r.data;
    // 库里只存哈希。
    const row = env.DB.raw.prepare('SELECT * FROM feedback WHERE id = ?').get(id);
    expect(row.ticket_hash).not.toContain(ticket);
    expect(row.account_id).toBeNull();
    expect(JSON.parse(row.meta)).toEqual({ app: '1.2.3+45', platform: 'android' });

    const d = await withTicket(env, 'GET', `/v1/feedback/${id}`, ticket);
    expect(d.status).toBe(200);
    expect(d.data).toMatchObject({ id, title: '阅读器白屏', body: '打开某本书白屏', messages: [], attachments: [] });
    expect(d.data.meta).toBeUndefined();
    expect((await withTicket(env, 'GET', `/v1/feedback/${id}`, 'x'.repeat(32))).status).toBe(404);
    expect((await call(env, 'GET', `/v1/feedback/${id}`, { now: NOW })).status).toBe(404);

    const s = await call(env, 'POST', '/v1/feedback/status', {
      body: { items: [{ id, ticket }, { id, ticket: 'wrong' }, { id: 'zzzzzzzzzz', ticket }] }, now: NOW,
    });
    expect(s.data.items).toEqual([expect.objectContaining({ id, status: 'open', devReplyAt: null })]);
  });

  it('校验：分类 / 标题 / 正文 / meta；按 IP 限流', async () => {
    const env = makeEnv();
    expect((await submit(env, { category: 'x' })).data.error).toBe('bad_category');
    expect((await submit(env, { title: '  ' })).data.error).toBe('missing_title');
    expect((await submit(env, { body: 'a'.repeat(FEEDBACK_LIMITS.bodyMax + 1) })).data.error).toBe('body_too_long');
    expect((await submit(env, { meta: [1] })).data.error).toBe('bad_meta');
    // meta 只留一层标量，嵌套 / 非法键丢掉。
    const ok = await submit(env, { meta: { a: 1, nested: { x: 1 }, 'bad key': 'x', ok: true } });
    expect(JSON.parse(env.DB.raw.prepare('SELECT meta FROM feedback WHERE id = ?').get(ok.data.id).meta)).toEqual({ a: 1, ok: true });
    const ip = '203.0.113.9';
    for (let i = 0; i < FEEDBACK_LIMITS.submitPerIpHour; i++) {
      expect((await submit(env, { title: `t${i}` }, { ip })).status).toBe(201);
    }
    expect((await submit(env, { title: 'one more' }, { ip })).status).toBe(429);
  });

  it('附件：截图 / gzip 日志各槽位只收一次；类型不对 415；超过补传窗口 403', async () => {
    const env = makeEnv();
    const { id, ticket } = (await submit(env)).data;
    const put = (slot, bytes, now = NOW) => withTicket(env, 'PUT', `/v1/feedback/${id}/attachments/${slot}`, ticket, { body: bytes, now });
    expect((await put('s0', PNG)).status).toBe(201);
    expect((await put('s0', PNG)).data.error).toBe('slot_taken');
    expect((await put('s1', new Uint8Array([1, 2, 3, 4]))).status).toBe(415);
    expect((await put('s3', PNG)).data.error).toBe('bad_slot');
    expect((await put('log', new TextEncoder().encode('plain text log, not gzip'))).data.error).toBe('not_gzip');
    const gz = new Uint8Array(gzipSync(Buffer.from('line 1\nline 2\n')));
    expect((await put('log', gz)).status).toBe(201);
    expect((await put('s1', JPEG, NOW + FEEDBACK_LIMITS.attachWindowMs + 1)).data.error).toBe('attach_window_closed');
    // 别人的回执传不进来。
    const other = (await submit(env)).data;
    expect((await withTicket(env, 'PUT', `/v1/feedback/${id}/attachments/s2`, other.ticket, { body: PNG })).status).toBe(404);
    const d = await withTicket(env, 'GET', `/v1/feedback/${id}`, ticket);
    expect(d.data.attachments.map((a) => a.slot)).toEqual(['s0', 'log']);
    expect(env.MEDIA.store.size).toBe(2);
    expect(env.DB.raw.prepare('SELECT bytes FROM media_usage').get().bytes).toBe(PNG.length + gz.length);
  });

  it('追加说明；结案后追加会重新打开', async () => {
    const env = makeEnv();
    const dev = await makeDev(env);
    const { id, ticket } = (await submit(env)).data;
    const r = await withTicket(env, 'POST', `/v1/feedback/${id}/messages`, ticket, { body: { body: '补充：只在横屏出现' } });
    expect(r.status).toBe(201);
    expect(r.data.messages).toEqual([expect.objectContaining({ author: 'user', body: '补充：只在横屏出现', nickname: null })]);
    await as(env, dev, 'POST', `/v1/dev/feedback/${id}`, { status: 'resolved', reply: '已修复' });
    const again = await withTicket(env, 'POST', `/v1/feedback/${id}/messages`, ticket, { body: { body: '还是会出现' } });
    expect(again.data.status).toBe('open');
    expect(again.data.messages.at(-1)).toMatchObject({ author: 'user', status: 'open' });
  });
});

describe('开发者（App 端签名接口）', () => {
  it('非开发者 403；管理员设为开发者后可列表 / 详情 / 回复改状态；反馈人看得到进度', async () => {
    const env = makeEnv();
    const reporter = await registerUser(env, 'reporter', { now: NOW });
    const { id, ticket } = (await submit(env, { contact: 'tg @me' }, { user: reporter })).data;
    expect(env.DB.raw.prepare('SELECT account_id FROM feedback WHERE id = ?').get(id).account_id).toBe(reporter.id);

    expect((await as(env, reporter, 'GET', '/v1/dev/feedback')).status).toBe(403);
    expect((await as(env, reporter, 'GET', '/v1/me')).data.role).toBe('user');
    const dev = await makeDev(env);
    expect((await as(env, dev, 'GET', '/v1/me')).data.role).toBe('dev');
    expect((await call(env, 'GET', '/v1/dev/feedback', { now: NOW })).status).toBe(401);

    const list = await as(env, dev, 'GET', '/v1/dev/feedback?status=active');
    expect(list.data.items).toEqual([expect.objectContaining({ id, status: 'open', hasAccount: true, awaitingDev: false })]);
    const detail = await as(env, dev, 'GET', `/v1/dev/feedback/${id}`);
    expect(detail.data).toMatchObject({
      contact: 'tg @me',
      meta: { app: '1.2.3+45', platform: 'android' },
      reporter: { id: reporter.id, nickname: 'reporter' },
    });

    expect((await as(env, dev, 'POST', `/v1/dev/feedback/${id}`, {})).data.error).toBe('nothing_to_update');
    expect((await as(env, dev, 'POST', `/v1/dev/feedback/${id}`, { status: 'nope' })).data.error).toBe('bad_status');
    const upd = await as(env, dev, 'POST', `/v1/dev/feedback/${id}`, { status: 'in_progress', reply: '复现了，在修' });
    expect(upd.status).toBe(200);
    expect(upd.data.status).toBe('in_progress');

    const seen = await withTicket(env, 'GET', `/v1/feedback/${id}`, ticket);
    expect(seen.data.status).toBe('in_progress');
    expect(seen.data.devReplyAt).toBe(NOW);
    expect(seen.data.messages).toEqual([
      expect.objectContaining({ author: 'dev', body: '复现了，在修', status: 'in_progress', nickname: 'dev' }),
    ]);
    // 反馈人再说话 → 处理台标新消息。
    await withTicket(env, 'POST', `/v1/feedback/${id}/messages`, ticket, { body: { body: '谢谢' }, now: NOW + 1000 });
    const l2 = await as(env, dev, 'GET', '/v1/dev/feedback');
    expect(l2.data.items[0].awaitingDev).toBe(true);
    // 撤销开发者。
    await call(env, 'POST', `/admin/api/accounts/${dev.id}/role`, { headers: basic, body: { role: 'user' }, now: NOW });
    expect((await as(env, dev, 'GET', '/v1/dev/feedback')).status).toBe(403);
  });

  it('列表按状态过滤、游标分页', async () => {
    const env = makeEnv();
    const dev = await makeDev(env);
    const ids = [];
    for (let i = 0; i < 5; i++) ids.push((await submit(env, { title: `t${i}` }, { now: NOW + i })).data.id);
    await as(env, dev, 'POST', `/v1/dev/feedback/${ids[0]}`, { status: 'closed' });
    const p1 = await as(env, dev, 'GET', '/v1/dev/feedback?status=open&limit=2');
    expect(p1.data.items.map((x) => x.title)).toEqual(['t4', 't3']);
    const p2 = await as(env, dev, 'GET', `/v1/dev/feedback?status=open&limit=2&cursor=${encodeURIComponent(p1.data.next)}`);
    expect(p2.data.items.map((x) => x.title)).toEqual(['t2', 't1']);
    expect(p2.data.next).toBeNull();
    const closed = await as(env, dev, 'GET', '/v1/dev/feedback?status=closed');
    expect(closed.data.items.map((x) => x.id)).toEqual([ids[0]]);
    const all = await as(env, dev, 'GET', '/v1/dev/feedback?status=all');
    expect(all.data.items).toHaveLength(5);
  });

  it('附件：截图原样；日志 ?view=text 解压成文本', async () => {
    const env = makeEnv();
    const dev = await makeDev(env);
    const { id, ticket } = (await submit(env)).data;
    await withTicket(env, 'PUT', `/v1/feedback/${id}/attachments/s0`, ticket, { body: PNG });
    await withTicket(env, 'PUT', `/v1/feedback/${id}/attachments/log`, ticket, { body: new Uint8Array(gzipSync(Buffer.from('E/fushi boom\n'))) });
    const img = await as(env, dev, 'GET', `/v1/dev/feedback/${id}/attachments/s0`);
    expect(img.res.headers.get('Content-Type')).toBe('image/png');
    const text = await as(env, dev, 'GET', `/v1/dev/feedback/${id}/attachments/log?view=text`);
    expect(text.data).toBe(`${LOG_UNTRUSTED_HEADER}E/fushi boom\n`);
    const raw = await as(env, dev, 'GET', `/v1/dev/feedback/${id}/attachments/log`);
    expect(raw.res.headers.get('Content-Disposition')).toContain('.log.gz');
    expect((await as(env, dev, 'GET', `/v1/dev/feedback/${id}/attachments/s2`)).status).toBe(404);
  });
});

describe('生命周期', () => {
  it('删账户：反馈保留、变匿名，回执照旧可用', async () => {
    const env = makeEnv();
    const u = await registerUser(env, 'gone', { now: NOW });
    const { id, ticket } = (await submit(env, {}, { user: u })).data;
    expect((await as(env, u, 'DELETE', '/v1/me')).status).toBe(204);
    expect(env.DB.raw.prepare('SELECT account_id FROM feedback WHERE id = ?').get(id).account_id).toBeNull();
    expect((await withTicket(env, 'GET', `/v1/feedback/${id}`, ticket)).status).toBe(200);
  });

  it('结案超过保留期的附件被清掉，配额归还；未结案的不动', async () => {
    const env = makeEnv();
    const dev = await makeDev(env);
    const a = (await submit(env)).data;
    const b = (await submit(env)).data;
    for (const f of [a, b]) await withTicket(env, 'PUT', `/v1/feedback/${f.id}/attachments/s0`, f.ticket, { body: PNG });
    await as(env, dev, 'POST', `/v1/dev/feedback/${a.id}`, { status: 'resolved' });
    expect(await purgeFeedbackAttachments(env, NOW + 1000)).toBe(0);
    expect(await purgeFeedbackAttachments(env, NOW + FEEDBACK_LIMITS.attachmentRetentionMs + 1)).toBe(1);
    expect(env.MEDIA.store.size).toBe(1);
    expect(env.DB.raw.prepare('SELECT bytes FROM media_usage').get().bytes).toBe(PNG.length);
    expect((await withTicket(env, 'GET', `/v1/feedback/${a.id}`, a.ticket)).data.attachments).toEqual([]);
  });
});

// ---- 网页处理台 ----

function form(fields) {
  return new TextEncoder().encode(new URLSearchParams(fields).toString());
}

function page(env, method, path, { cookie, fields, origin = BASE, ip } = {}) {
  const headers = { 'CF-Connecting-IP': ip ?? nextIp() };
  if (cookie) headers.Cookie = cookie;
  if (method === 'POST') {
    headers['Content-Type'] = 'application/x-www-form-urlencoded';
    if (origin) headers.Origin = origin;
  }
  return call(env, method, path, { headers, body: fields ? form(fields) : undefined, now: NOW });
}

async function webLogin(env, user) {
  const ip = nextIp();
  const sent = await page(env, 'POST', '/dev/code', { fields: { email: user.email }, ip });
  expect(sent.status).toBe(200);
  const res = await page(env, 'POST', '/dev/login', { fields: { email: user.email, code: lastCode(env, user.email) }, ip });
  return res;
}

describe('网页处理台', () => {
  it('未登录看到登录页；开发者邮箱验证码登录 → 列表 / 详情 / 处理 / 退出', async () => {
    const env = makeEnv();
    const dev = await makeDev(env);
    const { id, ticket } = (await submit(env, { title: '<script>x</script>' })).data;
    await withTicket(env, 'PUT', `/v1/feedback/${id}/attachments/s0`, ticket, { body: PNG });

    const anon = await page(env, 'GET', '/dev');
    expect(anon.status).toBe(200);
    expect(anon.data).toContain('发送验证码');
    expect(anon.res.headers.get('Content-Security-Policy')).toContain("default-src 'none'");
    // no-referrer 会让浏览器给本页表单的 POST 发 `Origin: null`，被 checkOrigin 拒成 bad_origin（线上登录全挂过一次）。
    expect(anon.res.headers.get('Referrer-Policy')).toBe('same-origin');
    expect(anon.data).not.toMatch(/<meta[^>]+name="referrer"/i);
    expect((await page(env, 'GET', `/dev/f/${id}`)).status).toBe(303);

    const login = await webLogin(env, dev);
    expect(login.status).toBe(303);
    const setCookie = login.res.headers.get('Set-Cookie');
    expect(setCookie).toMatch(/HttpOnly; Secure; SameSite=Strict/);
    const cookie = setCookie.split(';')[0];

    const list = await page(env, 'GET', '/dev', { cookie });
    expect(list.data).toContain(`/dev/f/${id}`);
    expect(list.data).toContain('&#60;script&#62;');
    expect(list.data).not.toContain('<script>x');

    const detail = await page(env, 'GET', `/dev/f/${id}`, { cookie });
    expect(detail.data).toContain(`/dev/f/${id}/a/s0`);
    expect(detail.data).toContain('1.2.3+45');
    expect((await page(env, 'GET', `/dev/f/${id}/a/s0`, { cookie })).res.headers.get('Content-Type')).toBe('image/png');

    // 无 Origin / 跨站 Origin 的 POST 一律 403。
    expect((await page(env, 'POST', `/dev/f/${id}`, { cookie, fields: { status: 'resolved' }, origin: null })).status).toBe(403);
    expect((await page(env, 'POST', `/dev/f/${id}`, { cookie, fields: { status: 'resolved' }, origin: 'https://evil.example' })).status).toBe(403);
    const upd = await page(env, 'POST', `/dev/f/${id}`, { cookie, fields: { status: 'resolved', reply: '下个版本修复' } });
    expect(upd.status).toBe(303);
    const seen = await withTicket(env, 'GET', `/v1/feedback/${id}`, ticket);
    expect(seen.data.status).toBe('resolved');
    expect(seen.data.messages[0]).toMatchObject({ author: 'dev', body: '下个版本修复', nickname: 'dev' });
    // 状态没变、回复为空：不产生记录。
    await page(env, 'POST', `/dev/f/${id}`, { cookie, fields: { status: 'resolved', reply: '' } });
    expect(env.DB.raw.prepare('SELECT COUNT(*) n FROM feedback_messages').get().n).toBe(1);

    const out = await page(env, 'POST', '/dev/logout', { cookie });
    expect(out.status).toBe(303);
    expect(env.DB.raw.prepare('SELECT COUNT(*) n FROM dev_sessions').get().n).toBe(0);
    expect((await page(env, 'GET', '/dev', { cookie })).data).toContain('发送验证码');
  });

  it('非开发者账户登录被拒，不建会话', async () => {
    const env = makeEnv();
    const u = await registerUser(env, 'plain', { now: NOW });
    const res = await webLogin(env, u);
    expect(res.status).toBe(200);
    expect(res.data).toContain('不是开发者账户');
    expect(env.DB.raw.prepare('SELECT COUNT(*) n FROM dev_sessions').get().n).toBe(0);
  });

  it('撤销开发者后旧会话立即失效', async () => {
    const env = makeEnv();
    const dev = await makeDev(env);
    const cookie = (await webLogin(env, dev)).res.headers.get('Set-Cookie').split(';')[0];
    expect((await page(env, 'GET', '/dev', { cookie })).data).toContain('反馈');
    await call(env, 'POST', `/admin/api/accounts/${dev.id}/role`, { headers: basic, body: { role: 'user' }, now: NOW });
    expect((await page(env, 'GET', '/dev', { cookie })).data).toContain('发送验证码');
  });
});
