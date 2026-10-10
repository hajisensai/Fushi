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

  it('反馈人取回自己的截图：只认本条 ticket、只给截图槽位、限次、响应禁缓存禁脚本', async () => {
    const env = makeEnv();
    const { id, ticket } = (await submit(env)).data;
    const put = (slot, bytes) => withTicket(env, 'PUT', `/v1/feedback/${id}/attachments/${slot}`, ticket, { body: bytes });
    expect((await put('s0', PNG)).status).toBe(201);
    expect((await put('log', new Uint8Array(gzipSync(Buffer.from('secret log\n'))))).status).toBe(201);
    const get = (slot, t = ticket, now = NOW) => withTicket(env, 'GET', `/v1/feedback/${id}/attachments/${slot}`, t, { now });

    const ok = await get('s0');
    expect(ok.status).toBe(200);
    expect(ok.res.headers.get('Content-Type')).toBe('image/png');
    expect(ok.res.headers.get('Cache-Control')).toContain('no-store');
    expect(ok.res.headers.get('X-Content-Type-Options')).toBe('nosniff');
    expect(ok.res.headers.get('Content-Security-Policy')).toBe("default-src 'none'");
    // 日志不回传；空槽位 / 越界槽位与日志同样 404（不区分）。
    expect((await get('log')).status).toBe(404);
    expect((await get('s1')).status).toBe(404);
    expect((await get('s9')).status).toBe(404);
    // 别人的回执 / 没有回执 / 别的反馈 id 都拿不到。
    const other = (await submit(env)).data;
    expect((await get('s0', other.ticket)).status).toBe(404);
    expect((await call(env, 'GET', `/v1/feedback/${id}/attachments/s0`, { now: NOW })).status).toBe(404);
    expect((await withTicket(env, 'GET', `/v1/feedback/${other.id}/attachments/s0`, ticket)).status).toBe(404);
    // 单条反馈按小时限次（第 1 次已用掉一个名额）。
    for (let i = 1; i < FEEDBACK_LIMITS.reporterDownloadsPerFeedbackHour; i++) {
      expect((await get('s0')).status).toBe(200);
    }
    expect((await get('s0')).status).toBe(429);
    expect((await get('s0', ticket, NOW + 3600 * 1000)).status).toBe(200);
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

describe('反馈人标记完成', () => {
  it('凭本条 ticket 把 open / 处理中改为已关闭；时间线记「反馈人标记完成」；处理台看得到', async () => {
    const env = makeEnv();
    const dev = await makeDev(env);
    const { id, ticket } = (await submit(env)).data;
    // 请求体里夹带别的字段一律无视：只做这一种状态变更。
    const r = await withTicket(env, 'POST', `/v1/feedback/${id}/close`, ticket, {
      body: { status: 'resolved', title: '改标题', body: '改正文' }, now: NOW + 1000,
    });
    expect(r.status).toBe(200);
    expect(r.data).toMatchObject({ id, status: 'closed', title: '阅读器白屏', body: '打开某本书白屏', userReplyAt: NOW + 1000 });
    expect(r.data.messages).toEqual([expect.objectContaining({ author: 'user', status: 'closed', body: '' })]);
    const row = env.DB.raw.prepare('SELECT title, body, status FROM feedback WHERE id = ?').get(id);
    expect(row).toEqual({ title: '阅读器白屏', body: '打开某本书白屏', status: 'closed' });
    // 开发者：列表标新消息、详情时间线是反馈人的关闭事件。
    const list = await as(env, dev, 'GET', '/v1/dev/feedback?status=all');
    expect(list.data.items[0]).toMatchObject({ id, status: 'closed', awaitingDev: true });
    const detail = await as(env, dev, 'GET', `/v1/dev/feedback/${id}`);
    expect(detail.data.messages.at(-1)).toMatchObject({ author: 'user', status: 'closed' });
    // 已关闭再点：409，不重复记事件。
    expect((await withTicket(env, 'POST', `/v1/feedback/${id}/close`, ticket)).data.error).toBe('not_closable');
    expect(env.DB.raw.prepare('SELECT COUNT(*) n FROM feedback_messages WHERE feedback_id = ?').get(id).n).toBe(1);
    // 追加说明重新打开后可以再关。
    await withTicket(env, 'POST', `/v1/feedback/${id}/messages`, ticket, { body: { body: '又出现了' } });
    expect((await withTicket(env, 'POST', `/v1/feedback/${id}/close`, ticket)).data.status).toBe('closed');
  });

  it('别人的 / 错误的 / 没有 ticket 一律 404；开发者给出结论后不能再改；按条限流', async () => {
    const env = makeEnv();
    const dev = await makeDev(env);
    const mine = (await submit(env)).data;
    const other = (await submit(env)).data;
    const close = (id, t, now = NOW) => withTicket(env, 'POST', `/v1/feedback/${id}/close`, t, { now });
    expect((await close(mine.id, other.ticket)).status).toBe(404);
    expect((await close(mine.id, 'x'.repeat(32))).status).toBe(404);
    expect((await call(env, 'POST', `/v1/feedback/${mine.id}/close`, { now: NOW })).status).toBe(404);
    expect((await close('zzzzzzzzzz', mine.ticket)).status).toBe(404);
    expect(env.DB.raw.prepare('SELECT status FROM feedback WHERE id = ?').get(mine.id).status).toBe('open');

    // 处理中可以关；已解决 / 不修复 / 重复不能被反馈人改写。
    await as(env, dev, 'POST', `/v1/dev/feedback/${other.id}`, { status: 'in_progress' });
    expect((await close(other.id, other.ticket)).data.status).toBe('closed');
    for (const status of ['resolved', 'wont_fix', 'duplicate']) {
      const f = (await submit(env, { title: `s-${status}` })).data;
      await as(env, dev, 'POST', `/v1/dev/feedback/${f.id}`, { status });
      const res = await close(f.id, f.ticket);
      expect(res.status).toBe(409);
      expect(env.DB.raw.prepare('SELECT status FROM feedback WHERE id = ?').get(f.id).status).toBe(status);
    }

    // 限流：单条每小时 N 次（上面成功的那次与失败的 409 都计数），下一小时恢复。
    for (let i = 1; i < FEEDBACK_LIMITS.reporterClosePerFeedbackHour; i++) {
      expect((await close(other.id, other.ticket)).status).toBe(409);
    }
    expect((await close(other.id, other.ticket)).status).toBe(429);
    expect((await close(other.id, other.ticket, NOW + 3600 * 1000)).status).toBe(409);
  });
});

describe('重新提交', () => {
  it('凭原反馈 ticket 新建一条并关联；原反馈须已结案；双向可见；处理台标出关联', async () => {
    const env = makeEnv();
    const dev = await makeDev(env);
    const orig = (await submit(env)).data;
    const reopen = (o, extra = {}) => submit(env, { reopenOf: o, ...extra });
    // 未结案不能重新提交（照旧追加说明即可）。
    expect((await reopen({ id: orig.id, ticket: orig.ticket })).data.error).toBe('parent_not_closed');
    await as(env, dev, 'POST', `/v1/dev/feedback/${orig.id}`, { status: 'resolved', reply: '已修复' });

    // 原样带着原标题 / 正文：不当作重复拒收，也不打 duplicate 标记。
    const r = await reopen({ id: orig.id, ticket: orig.ticket }, { body: '打开某本书白屏' });
    expect(r.status).toBe(201);
    expect(r.data.parentId).toBe(orig.id);
    const child = r.data;
    expect(env.DB.raw.prepare('SELECT parent_id, flags, status FROM feedback WHERE id = ?').get(child.id))
      .toEqual({ parent_id: orig.id, flags: '[]', status: 'open' });
    // 原对话不动：原反馈仍是已解决，时间线照旧。
    const parentView = await withTicket(env, 'GET', `/v1/feedback/${orig.id}`, orig.ticket);
    expect(parentView.data).toMatchObject({ status: 'resolved', reopenedAs: [child.id], parentId: null });
    expect(parentView.data.messages).toHaveLength(1);
    const childView = await withTicket(env, 'GET', `/v1/feedback/${child.id}`, child.ticket);
    expect(childView.data).toMatchObject({ parentId: orig.id, reopenedAs: [] });

    const list = await as(env, dev, 'GET', '/v1/dev/feedback?status=active');
    expect(list.data.items).toEqual([expect.objectContaining({ id: child.id, parentId: orig.id })]);
    expect((await as(env, dev, 'GET', `/v1/dev/feedback/${orig.id}`)).data.reopenedAs).toEqual([child.id]);
    const st = await call(env, 'POST', '/v1/feedback/status', { body: { items: [{ id: child.id, ticket: child.ticket }] }, now: NOW });
    expect(st.data.items[0].parentId).toBe(orig.id);

    // 网页处理台：新反馈上「重新提交自」、原反馈上「已被重新提交为」，都能点过去。
    const cookie = (await webLogin(env, dev)).res.headers.get('Set-Cookie').split(';')[0];
    const listPage = await page(env, 'GET', '/dev?status=all', { cookie });
    expect(listPage.data).toContain(`重新提交自 #${orig.id}`);
    expect((await page(env, 'GET', `/dev/f/${child.id}`, { cookie })).data)
      .toContain(`重新提交自 <a href="/dev/f/${orig.id}">#${orig.id}</a>`);
    expect((await page(env, 'GET', `/dev/f/${orig.id}`, { cookie })).data)
      .toContain(`已被重新提交为 <a href="/dev/f/${child.id}">#${child.id}</a>`);
  });

  it('ticket 错 / 别人的 / 格式不对 → 404 / 400，不建反馈；反馈人标记完成后也能重提；次数有上限', async () => {
    const env = makeEnv();
    const mine = (await submit(env, { title: 'mine' })).data;
    const other = (await submit(env, { title: 'other' })).data;
    await withTicket(env, 'POST', `/v1/feedback/${mine.id}/close`, mine.ticket);
    await withTicket(env, 'POST', `/v1/feedback/${other.id}/close`, other.ticket);
    const count = () => env.DB.raw.prepare('SELECT COUNT(*) n FROM feedback').get().n;
    const before = count();
    // 用自己的 ticket 关联别人的反馈 → 404。
    expect((await submit(env, { title: 'x1', reopenOf: { id: other.id, ticket: mine.ticket } })).status).toBe(404);
    expect((await submit(env, { title: 'x2', reopenOf: { id: mine.id, ticket: 'y'.repeat(32) } })).status).toBe(404);
    expect((await submit(env, { title: 'x3', reopenOf: { id: mine.id } })).status).toBe(404);
    expect((await submit(env, { title: 'x4', reopenOf: 'abc' })).status).toBe(400);
    expect(count()).toBe(before);

    for (let i = 0; i < FEEDBACK_LIMITS.reopensPerFeedback; i++) {
      const r = await submit(env, { title: `again ${i}`, reopenOf: { id: mine.id, ticket: mine.ticket } });
      expect(r.status).toBe(201);
      expect(r.data.parentId).toBe(mine.id);
    }
    expect((await submit(env, { title: 'too many', reopenOf: { id: mine.id, ticket: mine.ticket } })).data.error)
      .toBe('too_many_reopens');
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

  it('搜索 q：编号精确匹配，标题 / 正文包含；可与状态过滤叠加；% _ 按字面', async () => {
    const env = makeEnv();
    const dev = await makeDev(env);
    const a = (await submit(env, { title: '阅读器白屏', body: '打开某本书白屏' }, { now: NOW })).data;
    const b = (await submit(env, { title: '视频卡顿', body: '播放 4K 视频时掉帧 100%' }, { now: NOW + 1 })).data;
    const c = (await submit(env, { title: 'Crash on launch', body: 'app closes' }, { now: NOW + 2 })).data;
    await as(env, dev, 'POST', `/v1/dev/feedback/${c.id}`, { status: 'closed' });
    const search = async (q, status = 'all') => (await as(env, dev, 'GET',
      `/v1/dev/feedback?status=${status}&q=${encodeURIComponent(q)}`)).data.items.map((x) => x.id);
    expect(await search(b.id)).toEqual([b.id]);
    expect(await search('白屏')).toEqual([a.id]);
    expect(await search('掉帧')).toEqual([b.id]);
    expect(await search('crash')).toEqual([c.id]);
    expect(await search('crash', 'active')).toEqual([]);
    expect(await search('100%')).toEqual([b.id]);
    expect(await search('%')).toEqual([b.id]);
    expect(await search('_')).toEqual([]);
    expect(await search('   ')).toHaveLength(3);
    // 编号只做精确匹配：部分编号不当包含搜。
    expect(await search(a.id.slice(0, 5))).toEqual([]);
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

  it('列表有搜索框，q 过滤并在分页 / 状态标签里保留；时间线标出「反馈人标记完成」', async () => {
    const env = makeEnv();
    const dev = await makeDev(env);
    const a = (await submit(env, { title: '阅读器白屏' })).data;
    const b = (await submit(env, { title: '视频卡顿' })).data;
    await withTicket(env, 'POST', `/v1/feedback/${b.id}/close`, b.ticket);
    const cookie = (await webLogin(env, dev)).res.headers.get('Set-Cookie').split(';')[0];
    const all = await page(env, 'GET', '/dev?status=all', { cookie });
    expect(all.data).toContain('name="q"');
    expect(all.data).toContain(`#${b.id}`);
    const hit = await page(env, 'GET', `/dev?status=all&q=${encodeURIComponent('阅读器')}`, { cookie });
    expect(hit.data).toContain(`/dev/f/${a.id}`);
    expect(hit.data).not.toContain(`/dev/f/${b.id}`);
    expect(hit.data).toContain('status=active&amp;q=');
    const none = await page(env, 'GET', `/dev?status=all&q=${encodeURIComponent('不存在')}`, { cookie });
    expect(none.data).toContain('没有匹配的反馈');
    const detail = await page(env, 'GET', `/dev/f/${b.id}`, { cookie });
    expect(detail.data).toContain('反馈人标记完成');
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

describe('开发者私有批注（AI 总结 / 开发者批改）', () => {
  it('只进开发者出口：反馈人详情 / 批量进度一律不带，也不写时间线、不动排序与红点', async () => {
    const env = makeEnv();
    const dev = await makeDev(env);
    const reporter = await registerUser(env, 'rep', { now: NOW });
    const { id, ticket } = (await submit(env)).data;
    const before = env.DB.raw.prepare('SELECT updated_at, dev_reply_at FROM feedback WHERE id = ?').get(id);

    expect((await as(env, reporter, 'POST', `/v1/dev/feedback/${id}/notes`, { devNote: 'x' })).status).toBe(403);
    expect((await call(env, 'POST', `/v1/dev/feedback/${id}/notes`, { body: { devNote: 'x' }, now: NOW })).status).toBe(401);
    expect((await as(env, dev, 'POST', `/v1/dev/feedback/${id}/notes`, {})).data.error).toBe('nothing_to_update');
    expect((await as(env, dev, 'POST', `/v1/dev/feedback/${id}/notes`, { devNote: 7 })).data.error).toBe('bad_dev_note');
    expect((await as(env, dev, 'POST', `/v1/dev/feedback/${id}/notes`,
      { aiSummary: '字'.repeat(FEEDBACK_LIMITS.aiSummaryMax + 1) })).data.error).toBe('ai_summary_too_long');

    const saved = await as(env, dev, 'POST', `/v1/dev/feedback/${id}/notes`,
      { aiSummary: 'AI：白屏，疑似 EPUB 解析失败', devNote: '先查导入日志​' });
    expect(saved.status).toBe(200);
    expect(saved.data).toMatchObject({
      aiSummary: 'AI：白屏，疑似 EPUB 解析失败', aiSummaryAt: NOW, devNote: '先查导入日志', devNoteAt: NOW,
    });
    const item = (await as(env, dev, 'GET', '/v1/dev/feedback')).data.items.find((x) => x.id === id);
    expect(item).toMatchObject({ aiSummary: 'AI：白屏，疑似 EPUB 解析失败', hasDevNote: true });

    // 反馈人一侧：字段与文字都不出现。
    const mine = await withTicket(env, 'GET', `/v1/feedback/${id}`, ticket);
    const status = await call(env, 'POST', '/v1/feedback/status', { body: { items: [{ id, ticket }] }, now: NOW });
    for (const res of [mine, status]) {
      const text = JSON.stringify(res.data);
      expect(res.status).toBe(200);
      expect(text).not.toMatch(/aiSummary|devNote|hasDevNote/);
      expect(text).not.toContain('EPUB 解析失败');
      expect(text).not.toContain('先查导入日志');
    }
    expect(mine.data.messages).toEqual([]);
    expect(env.DB.raw.prepare('SELECT COUNT(*) n FROM feedback_messages').get().n).toBe(0);
    expect(env.DB.raw.prepare('SELECT updated_at, dev_reply_at FROM feedback WHERE id = ?').get(id)).toEqual(before);

    // 只给一个字段时另一个不动；空白 = 清除。
    const cleared = await as(env, dev, 'POST', `/v1/dev/feedback/${id}/notes`, { devNote: '  ' });
    expect(cleared.data).toMatchObject({ aiSummary: 'AI：白屏，疑似 EPUB 解析失败', devNote: null, devNoteAt: null });
    expect((await as(env, dev, 'GET', '/v1/dev/feedback')).data.items.find((x) => x.id === id).hasDevNote).toBe(false);
  });

  it('网页处理台：详情显示 AI 总结、批改表单保存（要本站 Origin），长中文不被表单上限拒', async () => {
    const env = makeEnv();
    const dev = await makeDev(env);
    const { id, ticket } = (await submit(env)).data;
    await as(env, dev, 'POST', `/v1/dev/feedback/${id}/notes`, { aiSummary: '<b>总结</b>' });
    const cookie = (await webLogin(env, dev)).res.headers.get('Set-Cookie').split(';')[0];

    const detail = await page(env, 'GET', `/dev/f/${id}`, { cookie });
    expect(detail.data).toContain('&#60;b&#62;总结');
    expect(detail.data).not.toContain('<b>总结');
    expect(detail.data).toContain(`action="/dev/f/${id}/note"`);
    expect((await page(env, 'GET', '/dev', { cookie })).data).toContain('AI：&#60;b&#62;总结');

    expect((await page(env, 'POST', `/dev/f/${id}/note`, { cookie, fields: { devNote: 'x' }, origin: null })).status).toBe(403);
    const longNote = '批'.repeat(FEEDBACK_LIMITS.devNoteMax);
    const saved = await page(env, 'POST', `/dev/f/${id}/note`, { cookie, fields: { devNote: longNote } });
    expect(saved.status).toBe(303);
    expect(env.DB.raw.prepare('SELECT dev_note FROM feedback WHERE id = ?').get(id).dev_note).toBe(longNote);
    expect((await page(env, 'GET', '/dev', { cookie })).data).toContain('已批改');
    // 网页只收批改：表单里夹带 aiSummary 也改不了 AI 总结。
    await page(env, 'POST', `/dev/f/${id}/note`, { cookie, fields: { devNote: '', aiSummary: 'hack' } });
    expect(env.DB.raw.prepare('SELECT ai_summary, dev_note FROM feedback WHERE id = ?').get(id))
      .toEqual({ ai_summary: '<b>总结</b>', dev_note: null });

    // 回复框满 4000 个汉字（urlencoded 约 36 KB）也能提交，不再被 32 KB 一刀切成 413。
    const reply = '复'.repeat(FEEDBACK_LIMITS.replyMax);
    expect((await page(env, 'POST', `/dev/f/${id}`, { cookie, fields: { status: 'open', reply } })).status).toBe(303);
    expect((await withTicket(env, 'GET', `/v1/feedback/${id}`, ticket)).data.messages[0].body).toBe(reply);
  });
});
