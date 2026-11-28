// 反馈协查角色（accounts.role = 'triage'）：能看反馈（列表 / 详情 / 附件）、写内部批注；
// 回复反馈人、改状态（反馈人可见、会推送）与处理台其余页面一律拒。另含 BUG-5493：网页处理台样本文件 f0..f2 下载 404。
import { describe, expect, it } from 'vitest';
import { BASE, call, lastCode, makeEnv, nextIp, pngHeader, registerUser } from './harness.js';
import { ACCOUNT_ROLES, canViewFeedback } from '../src/feedback.js';
import { consoleRouteAllowed } from '../src/devconsole.js';

const NOW = Date.UTC(2026, 10, 26, 12);
const basic = { Authorization: `Basic ${btoa('admin:pw')}` };
const PNG = pngHeader(320, 640);
const MD = new TextEncoder().encode('# 复现步骤\n\n1. 打开\n');

function submit(env) {
  return call(env, 'POST', '/v1/feedback', {
    body: { category: 'bug', title: '阅读器白屏', body: '打开某本书白屏', meta: { app: '1.2.3+45', platform: 'android' } },
    headers: { 'CF-Connecting-IP': nextIp() },
    now: NOW,
  });
}

function withTicket(env, method, path, ticket, opts = {}) {
  return call(env, method, path, { ...opts, headers: { 'X-Fushi-Ticket': ticket, ...(opts.headers || {}) }, now: NOW });
}

function setRole(env, id, role) {
  return call(env, 'POST', `/admin/api/accounts/${id}/role`, { headers: basic, body: { role }, now: NOW });
}

async function makeRole(env, name, role) {
  const u = await registerUser(env, name, { now: NOW });
  expect((await setRole(env, u.id, role)).status).toBe(200);
  return u;
}

const as = (env, u, method, path, body) => call(env, method, path, { key: u.key, account: u.id, body, now: NOW });

function page(env, method, path, { cookie, fields, origin = BASE } = {}) {
  const headers = { 'CF-Connecting-IP': nextIp() };
  if (cookie) headers.Cookie = cookie;
  if (method === 'POST') {
    headers['Content-Type'] = 'application/x-www-form-urlencoded';
    if (origin) headers.Origin = origin;
  }
  const body = fields ? new TextEncoder().encode(new URLSearchParams(fields).toString()) : undefined;
  return call(env, method, path, { headers, body, now: NOW });
}

async function webCookie(env, user) {
  const ip = nextIp();
  const headers = { 'CF-Connecting-IP': ip, 'Content-Type': 'application/x-www-form-urlencoded', Origin: BASE };
  const enc = (o) => new TextEncoder().encode(new URLSearchParams(o).toString());
  await call(env, 'POST', '/dev/code', { headers, body: enc({ email: user.email }), now: NOW });
  const res = await call(env, 'POST', '/dev/login', {
    headers, body: enc({ email: user.email, code: lastCode(env, user.email) }), now: NOW,
  });
  expect(res.status).toBe(303);
  return res.res.headers.get('Set-Cookie').split(';')[0];
}

const msgCount = (env) => env.DB.raw.prepare('SELECT COUNT(*) n FROM feedback_messages').get().n;
const fbRow = (env, id) => env.DB.raw.prepare('SELECT status, dev_note, ai_summary, dev_reply_at FROM feedback WHERE id = ?').get(id);

describe('角色表', () => {
  it('dev / triage 能看反馈，user 与未知值不能；管理接口收三种角色、别的 400', async () => {
    expect(ACCOUNT_ROLES).toEqual(['dev', 'triage', 'user']);
    expect(['dev', 'triage', 'user', 'admin', null].map(canViewFeedback)).toEqual([true, true, false, false, false]);
    const env = makeEnv();
    const u = await registerUser(env, 'x', { now: NOW });
    expect((await setRole(env, u.id, 'admin')).data.error).toBe('bad_role');
    expect((await setRole(env, u.id, 'triage')).status).toBe(200);
    expect((await as(env, u, 'GET', '/v1/me')).data.role).toBe('triage');
  });

  it('triage 处理台白名单只含反馈只读、批改与自己的反馈密钥', () => {
    const id = 'AbCdEfGh12';
    const ok = [['GET', '/dev'], ['GET', '/dev/feedback.json'], ['GET', `/dev/f/${id}`], ['GET', `/dev/f/${id}.json`],
      ['GET', `/dev/f/${id}/a/log`], ['GET', `/dev/f/${id}/a/s0`], ['GET', `/dev/f/${id}/a/v0`], ['GET', `/dev/f/${id}/a/f2`],
      ['POST', `/dev/f/${id}/note`], ['GET', '/dev/keys'], ['POST', '/dev/keys'], ['POST', '/dev/fkeys/k1/revoke']];
    const no = [['POST', `/dev/f/${id}`], ['GET', '/dev/decisions'], ['GET', '/dev/decisions.json'], ['GET', '/dev/stats'],
      ['GET', '/dev/stats.json'], ['GET', '/dev/project'], ['GET', '/dev/notices'], ['POST', '/dev/keys/k1/revoke'],
      ['POST', '/dev/d/abc'], ['GET', `/dev/f/${id}/note`]];
    for (const [m, p] of ok) expect([m, p, consoleRouteAllowed('triage', m, p)]).toEqual([m, p, true]);
    for (const [m, p] of no) expect([m, p, consoleRouteAllowed('triage', m, p)]).toEqual([m, p, false]);
    for (const [m, p] of [...ok, ...no]) {
      expect(consoleRouteAllowed('dev', m, p)).toBe(true);
      expect(consoleRouteAllowed('user', m, p)).toBe(false);
    }
  });
});

describe('triage：App 端签名接口', () => {
  it('能列表 / 详情 / 取附件 / 写批注；回复与改状态 403 且不留任何痕迹', async () => {
    const env = makeEnv();
    const tri = await makeRole(env, 'helper', 'triage');
    const { id, ticket } = (await submit(env)).data;
    await withTicket(env, 'PUT', `/v1/feedback/${id}/attachments/s0`, ticket, { body: PNG });

    expect((await as(env, tri, 'GET', '/v1/dev/feedback')).data.items).toEqual([expect.objectContaining({ id })]);
    expect((await as(env, tri, 'GET', `/v1/dev/feedback/${id}`)).data).toMatchObject({ id, meta: { app: '1.2.3+45' } });
    expect((await as(env, tri, 'GET', `/v1/dev/feedback/${id}/attachments/s0`)).status).toBe(200);

    const noted = await as(env, tri, 'POST', `/v1/dev/feedback/${id}/notes`, { devNote: '内部：疑似字体问题', aiSummary: '总结' });
    expect(noted.status).toBe(200);
    expect(fbRow(env, id)).toMatchObject({ dev_note: '内部：疑似字体问题', ai_summary: '总结' });

    for (const body of [{ reply: '在修了' }, { status: 'resolved' }, { status: 'in_progress', reply: 'x' }]) {
      const r = await as(env, tri, 'POST', `/v1/dev/feedback/${id}`, body);
      expect(r.status).toBe(403);
      expect(r.data.error).toBe('not_developer');
    }
    expect(msgCount(env)).toBe(0);
    expect(fbRow(env, id)).toMatchObject({ status: 'open', dev_reply_at: null });
    // 反馈人那边：没有任何开发者消息，批注也不外露。
    const seen = await withTicket(env, 'GET', `/v1/feedback/${id}`, ticket);
    expect(seen.data.messages).toEqual([]);
    expect(JSON.stringify(seen.data)).not.toContain('疑似字体问题');

    // 撤成普通用户后全部 403。
    await setRole(env, tri.id, 'user');
    expect((await as(env, tri, 'GET', '/v1/dev/feedback')).status).toBe(403);
    expect((await as(env, tri, 'POST', `/v1/dev/feedback/${id}/notes`, { devNote: 'y' })).status).toBe(403);
  });
});

describe('triage：网页处理台', () => {
  it('能登录、看列表详情附件、保存批改；页面不给回复表单与其他入口；对外动作与其他页面 403', async () => {
    const env = makeEnv();
    const tri = await makeRole(env, 'helper', 'triage');
    const { id, ticket } = (await submit(env)).data;
    await withTicket(env, 'PUT', `/v1/feedback/${id}/attachments/s0`, ticket, { body: PNG });
    const cookie = await webCookie(env, tri);

    const list = await page(env, 'GET', '/dev', { cookie });
    expect(list.status).toBe(200);
    expect(list.data).toContain(`/dev/f/${id}`);
    expect(list.data).not.toContain('href="/dev/decisions"');
    expect(list.data).toContain('href="/dev/keys"');

    const detail = await page(env, 'GET', `/dev/f/${id}`, { cookie });
    expect(detail.data).toContain(`action="/dev/f/${id}/note"`);
    expect(detail.data).not.toContain(`action="/dev/f/${id}"`);
    expect(detail.data).not.toContain('name="reply"');
    expect(detail.data).toContain('反馈协查');
    expect((await page(env, 'GET', `/dev/f/${id}/a/s0`, { cookie })).res.headers.get('Content-Type')).toBe('image/png');
    expect((await page(env, 'GET', `/dev/f/${id}.json`, { cookie })).data.id).toBe(id);
    expect((await page(env, 'GET', '/dev/feedback.json', { cookie })).data.items[0].id).toBe(id);

    expect((await page(env, 'POST', `/dev/f/${id}/note`, { cookie, fields: { devNote: '协查记录' } })).status).toBe(303);
    expect(fbRow(env, id).dev_note).toBe('协查记录');

    const reply = await page(env, 'POST', `/dev/f/${id}`, { cookie, fields: { status: 'resolved', reply: '修好了' } });
    expect(reply.status).toBe(403);
    expect(msgCount(env)).toBe(0);
    expect(fbRow(env, id).status).toBe('open');

    for (const p of ['/dev/decisions', '/dev/decisions.json', '/dev/stats', '/dev/stats.json', '/dev/project', '/dev/notices']) {
      expect([p, (await page(env, 'GET', p, { cookie })).status]).toEqual([p, 403]);
    }
    // 密钥页只给反馈密钥：不显示拍板台密钥，签拍板台密钥（kind 缺省 = decision）403。
    const keys = await page(env, 'GET', '/dev/keys', { cookie });
    expect(keys.status).toBe(200);
    expect(keys.data).toContain('反馈密钥');
    expect(keys.data).not.toContain('拍板台密钥');
    expect((await page(env, 'POST', '/dev/keys', { cookie, fields: { label: 'k' } })).status).toBe(403);
    expect((await page(env, 'POST', '/dev/keys', { cookie, fields: { label: 'k', kind: 'decision' } })).status).toBe(403);
    expect(env.DB.raw.prepare('SELECT COUNT(*) n FROM decision_api_keys').get().n).toBe(0);

    // triage → dev：同一会话立即拿到全部能力；→ user：会话作废。
    await setRole(env, tri.id, 'dev');
    expect((await page(env, 'GET', `/dev/f/${id}`, { cookie })).data).toContain('name="reply"');
    expect((await page(env, 'GET', '/dev/stats', { cookie })).status).toBe(200);
    await setRole(env, tri.id, 'user');
    expect((await page(env, 'GET', '/dev', { cookie })).data).toContain('发送验证码');
    expect(env.DB.raw.prepare('SELECT COUNT(*) n FROM dev_sessions').get().n).toBe(0);
  });
});

describe('BUG-5493 网页处理台样本文件', () => {
  it('详情页的样本文件下载链接可用（f0..f2 作附件下发）', async () => {
    const env = makeEnv();
    const dev = await makeRole(env, 'dev', 'dev');
    const { id, ticket } = (await submit(env)).data;
    const put = await withTicket(env, 'PUT', `/v1/feedback/${id}/attachments/f0`, ticket, {
      body: MD, headers: { 'X-Fushi-File-Name': encodeURIComponent('notes.md'), 'Content-Length': String(MD.length) },
    });
    expect(put.status).toBe(201);
    const cookie = await webCookie(env, dev);
    expect((await page(env, 'GET', `/dev/f/${id}`, { cookie })).data).toContain(`/dev/f/${id}/a/f0`);
    const r = await page(env, 'GET', `/dev/f/${id}/a/f0`, { cookie });
    expect(r.status).toBe(200);
    expect(r.res.headers.get('Content-Type')).toBe('application/octet-stream');
    expect(r.res.headers.get('Content-Disposition')).toMatch(/^attachment;/);
    const text = await page(env, 'GET', `/dev/f/${id}/a/f0?view=text`, { cookie });
    expect(text.status).toBe(200);
    expect(text.data).toContain('复现步骤');
  });
});
