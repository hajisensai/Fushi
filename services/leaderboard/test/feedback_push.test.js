import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { call, makeEnv, nextIp, registerUser } from './harness.js';
import { PUSH_LIMITS, apnsJwt, normalizePushLang, resetPushStateForTests } from '../src/feedback_push.js';
import { b64urlDecode } from '../src/util.js';

const NOW = Date.UTC(2026, 9, 13, 12);
const basic = { Authorization: `Basic ${btoa('admin:pw')}` };
const TOKEN_A = 'a'.repeat(64);
const TOKEN_B = 'b'.repeat(64);
const SECRET_REPLY = '内部排查细节：数据库路径是 /secret';

async function apnsKey() {
  const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const der = new Uint8Array(await crypto.subtle.exportKey('pkcs8', pair.privateKey));
  let bin = '';
  for (const b of der) bin += String.fromCharCode(b);
  const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(bin).replace(/(.{64})/g, '$1\n')}\n-----END PRIVATE KEY-----\n`;
  return { pem, publicKey: pair.publicKey };
}

/** 带 APNs 配置与假 APNs 的 env；sent 收集出站请求，respond 决定每个令牌的回应。 */
async function pushEnv(respond = () => ({ status: 200 })) {
  const key = await apnsKey();
  const sent = [];
  const env = makeEnv({
    APNS_KEY_P8: key.pem,
    APNS_KEY_ID: 'KEY1234567',
    APNS_TEAM_ID: 'TEAM123456',
    APNS_BUNDLE_ID: 'app.fushi.reader',
    APNS_ENV: 'sandbox',
    APNS_FETCH: async (url, init) => {
      const token = url.split('/').pop();
      sent.push({ url, init, token, body: JSON.parse(init.body) });
      const r = respond(token);
      return new Response(r.reason ? JSON.stringify({ reason: r.reason }) : '', { status: r.status });
    },
  });
  return { env, sent, key };
}

function submit(env, title = '阅读器白屏') {
  return call(env, 'POST', '/v1/feedback', {
    body: { category: 'bug', title, body: '打开某本书白屏' },
    headers: { 'CF-Connecting-IP': nextIp() },
    now: NOW,
  });
}

function submitAs(env, user, title = '账户提交') {
  return call(env, 'POST', '/v1/feedback', {
    body: { category: 'bug', title, body: '打开某本书白屏' },
    headers: { 'CF-Connecting-IP': nextIp() },
    key: user.key,
    account: user.id,
    now: NOW,
  });
}

function push(env, method, id, ticket, body, now = NOW) {
  return call(env, method, `/v1/feedback/${id}/push`, { body, headers: { 'X-Fushi-Ticket': ticket }, now });
}

async function makeDev(env) {
  const u = await registerUser(env, 'dev', { now: NOW });
  const r = await call(env, 'POST', `/admin/api/accounts/${u.id}/role`, { headers: basic, body: { role: 'dev' }, now: NOW });
  expect(r.status).toBe(200);
  return u;
}

function devUpdate(env, dev, id, body) {
  return call(env, 'POST', `/v1/dev/feedback/${id}`, { key: dev.key, account: dev.id, body, now: NOW });
}

function tokens(env, id) {
  return env.DB.raw.prepare('SELECT token, lang FROM feedback_push_tokens WHERE feedback_id = ? ORDER BY token').all(id);
}

beforeEach(() => resetPushStateForTests());
afterEach(() => vi.restoreAllMocks());

describe('推送令牌登记', () => {
  it('凭 ticket 登记 / 注销；同一令牌按哈希去重；别人的 ticket 不能给这条登记', async () => {
    const { env } = await pushEnv();
    const a = (await submit(env)).data;
    const b = (await submit(env, '另一条')).data;
    expect((await push(env, 'PUT', a.id, a.ticket, { token: TOKEN_A, lang: 'zh-CN' })).data)
      .toEqual({ registered: true, delivering: true });
    // 大写 / 重复登记：同一个令牌只占一行，语言随最后一次登记。
    expect((await push(env, 'PUT', a.id, a.ticket, { token: TOKEN_A.toUpperCase(), lang: 'ja' })).status).toBe(200);
    expect(tokens(env, a.id)).toEqual([{ token: TOKEN_A, lang: 'ja' }]);
    // 越权：b 的 ticket 给 a 登记 → 404（与其它 ticket 接口同口径，不区分不存在 / 不对）。
    expect((await push(env, 'PUT', a.id, b.ticket, { token: TOKEN_B })).status).toBe(404);
    expect((await push(env, 'PUT', a.id, '', { token: TOKEN_B })).status).toBe(404);
    expect(tokens(env, a.id)).toHaveLength(1);
    expect(tokens(env, b.id)).toHaveLength(0);
    // 坏令牌。
    expect((await push(env, 'PUT', a.id, a.ticket, { token: 'xyz' })).data.error).toBe('bad_token');
    // 注销。
    expect((await push(env, 'DELETE', a.id, a.ticket, { token: TOKEN_A })).data).toEqual({ registered: false });
    expect(tokens(env, a.id)).toHaveLength(0);
  });

  it('账户条目（没有 ticket）凭同账户签名登记 / 注销；别人的账户、匿名反馈一律 404', async () => {
    const { env } = await pushEnv();
    const owner = await registerUser(env, 'owner', { now: NOW });
    const other = await registerUser(env, 'other', { now: NOW });
    const mine = (await submitAs(env, owner)).data;
    const anon = (await submit(env, '匿名')).data;
    const signedPush = (u, method, id, body) =>
      call(env, method, `/v1/feedback/${id}/push`, { key: u.key, account: u.id, body, now: NOW });

    expect((await signedPush(owner, 'PUT', mine.id, { token: TOKEN_A, lang: 'en' })).data)
      .toEqual({ registered: true, delivering: true });
    expect(tokens(env, mine.id)).toEqual([{ token: TOKEN_A, lang: 'en' }]);
    // 别人的账户给这条登记：404（不区分不存在 / 不是你的）。
    expect((await signedPush(other, 'PUT', mine.id, { token: TOKEN_B })).status).toBe(404);
    expect((await signedPush(other, 'DELETE', mine.id, { token: TOKEN_A })).status).toBe(404);
    // 匿名提交的反馈只能凭 ticket。
    expect((await signedPush(owner, 'PUT', anon.id, { token: TOKEN_B })).status).toBe(404);
    expect(tokens(env, mine.id)).toHaveLength(1);
    expect(tokens(env, anon.id)).toHaveLength(0);
    // 签名不对照常 401。
    const bad = await call(env, 'PUT', `/v1/feedback/${mine.id}/push`, {
      key: owner.key, account: owner.id, badSig: true, body: { token: TOKEN_B }, now: NOW,
    });
    expect(bad.status).toBe(401);
    // 注销。
    expect((await signedPush(owner, 'DELETE', mine.id, { token: TOKEN_A })).data).toEqual({ registered: false });
    expect(tokens(env, mine.id)).toHaveLength(0);
  });

  it('每条反馈最多 N 个令牌：满了挤掉最久没登记的', async () => {
    const { env } = await pushEnv();
    const a = (await submit(env)).data;
    const all = Array.from({ length: PUSH_LIMITS.tokensPerFeedback + 1 }, (_, i) => String(i).repeat(64).slice(0, 64));
    for (let i = 0; i < all.length; i++) {
      expect((await push(env, 'PUT', a.id, a.ticket, { token: all[i] }, NOW + i)).status).toBe(200);
    }
    const left = tokens(env, a.id).map((r) => r.token);
    expect(left).toHaveLength(PUSH_LIMITS.tokensPerFeedback);
    expect(left).not.toContain(all[0]);
    expect(left).toContain(all[all.length - 1]);
  });

  it('已结案的反馈不收登记；反馈人标记完成时令牌全部作废', async () => {
    const { env } = await pushEnv();
    const a = (await submit(env)).data;
    await push(env, 'PUT', a.id, a.ticket, { token: TOKEN_A });
    const closed = await call(env, 'POST', `/v1/feedback/${a.id}/close`, { headers: { 'X-Fushi-Ticket': a.ticket }, now: NOW });
    expect(closed.status).toBe(200);
    expect(tokens(env, a.id)).toHaveLength(0);
    expect((await push(env, 'PUT', a.id, a.ticket, { token: TOKEN_A })).data.error).toBe('feedback_closed');
  });

  it('语言标签归一', () => {
    expect(normalizePushLang('zh-CN')).toBe('zh');
    expect(normalizePushLang('zh_HK')).toBe('zh-Hant');
    expect(normalizePushLang('zh-Hant-TW')).toBe('zh-Hant');
    expect(normalizePushLang('ja-JP')).toBe('ja');
    expect(normalizePushLang('ko')).toBe('ko');
    expect(normalizePushLang('fr')).toBe('en');
    expect(normalizePushLang(null)).toBe('en');
  });
});

describe('开发者处理后的 APNs 推送', () => {
  it('回复 → 每个令牌一条推送；载荷只有通用文案与反馈 id，不含回复正文与标题', async () => {
    const { env, sent } = await pushEnv();
    const dev = await makeDev(env);
    const a = (await submit(env, '标题也是隐私')).data;
    await push(env, 'PUT', a.id, a.ticket, { token: TOKEN_A, lang: 'zh-CN' });
    await push(env, 'PUT', a.id, a.ticket, { token: TOKEN_B, lang: 'en' });
    expect((await devUpdate(env, dev, a.id, { reply: SECRET_REPLY })).status).toBe(200);
    expect(sent.map((s) => s.token).sort()).toEqual([TOKEN_A, TOKEN_B]);
    const zh = sent.find((s) => s.token === TOKEN_A);
    expect(zh.url).toBe(`https://api.sandbox.push.apple.com/3/device/${TOKEN_A}`);
    expect(zh.init.method).toBe('POST');
    expect(zh.init.headers['apns-topic']).toBe('app.fushi.reader');
    expect(zh.init.headers['apns-push-type']).toBe('alert');
    expect(zh.init.headers.authorization).toMatch(/^bearer [\w-]+\.[\w-]+\.[\w-]+$/);
    expect(zh.body.aps.alert.body).toBe('开发者回复了你的反馈');
    expect(zh.body.fushi).toEqual({ feedback: a.id });
    expect(sent.find((s) => s.token === TOKEN_B).body.aps.alert.body).toBe('A developer replied to your feedback');
    for (const s of sent) {
      expect(s.init.body).not.toContain('内部排查');
      expect(s.init.body).not.toContain('/secret');
      expect(s.init.body).not.toContain('标题也是隐私');
    }
  });

  it('只改状态 → 状态文案；结案 → 发完之后令牌清空', async () => {
    const { env, sent } = await pushEnv();
    const dev = await makeDev(env);
    const a = (await submit(env)).data;
    await push(env, 'PUT', a.id, a.ticket, { token: TOKEN_A, lang: 'en' });
    await devUpdate(env, dev, a.id, { status: 'in_progress' });
    expect(sent.at(-1).body.aps.alert.body).toBe('Your feedback status was updated');
    expect(tokens(env, a.id)).toHaveLength(1);
    await devUpdate(env, dev, a.id, { status: 'resolved' });
    expect(sent).toHaveLength(2);
    expect(tokens(env, a.id)).toHaveLength(0);
  });

  it('生产路径（ctx.waitUntil）：响应不等推送完成，推送与结案清令牌随后执行', async () => {
    const { env, sent } = await pushEnv();
    let release;
    const gate = new Promise((resolve) => {
      release = resolve;
    });
    const deliver = env.APNS_FETCH;
    env.APNS_FETCH = async (url, init) => {
      await gate;
      return deliver(url, init);
    };
    const dev = await makeDev(env);
    const a = (await submit(env)).data;
    await push(env, 'PUT', a.id, a.ticket, { token: TOKEN_A, lang: 'en' });
    const pending = [];
    const ctx = { waitUntil: (p) => pending.push(p) };
    const r = await call(env, 'POST', `/v1/dev/feedback/${a.id}`, {
      key: dev.key, account: dev.id, body: { status: 'resolved', reply: 'fixed' }, now: NOW, ctx,
    });
    // 回复已写入、响应已返回，推送还卡在 APNs 那一步：没有出站、令牌也还没清。
    expect(r.status).toBe(200);
    expect(r.data.messages.at(-1).body).toBe('fixed');
    expect(pending.length).toBeGreaterThan(0);
    expect(sent).toHaveLength(0);
    expect(tokens(env, a.id)).toHaveLength(1);

    release();
    await Promise.all(pending);
    expect(sent).toHaveLength(1);
    expect(sent[0].body.aps.alert.body).toBe('A developer replied to your feedback');
    expect(tokens(env, a.id)).toHaveLength(0);
  });

  it('网页处理台的回复同样推送', async () => {
    const { env, sent } = await pushEnv();
    const dev = await makeDev(env);
    const a = (await submit(env)).data;
    await push(env, 'PUT', a.id, a.ticket, { token: TOKEN_A });
    // 直接给开发者建一个网页会话（登录流程本身由 devconsole 的测试覆盖）。
    const { newSessionToken } = await import('../src/feedback.js');
    const { sha256, hex } = await import('../src/util.js');
    const session = newSessionToken();
    env.DB.raw.prepare('INSERT INTO dev_sessions (token_hash, account_id, expires_at) VALUES (?, ?, ?)')
      .run(hex(await sha256(new TextEncoder().encode(session))), dev.id, NOW + 3600_000);
    const form = new URLSearchParams({ status: 'open', reply: SECRET_REPLY });
    const r = await call(env, 'POST', `/dev/f/${a.id}`, {
      body: new TextEncoder().encode(form.toString()),
      headers: {
        Cookie: `fushi_dev=${session}`,
        Origin: 'https://rank.example.com',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      now: NOW,
    });
    expect(r.status).toBe(303);
    expect(sent).toHaveLength(1);
    expect(sent[0].init.body).not.toContain('内部排查');
  });

  it('APNs 回 410 / BadDeviceToken → 清掉令牌；其它失败不影响回复写入', async () => {
    const { env, sent } = await pushEnv((token) => (token === TOKEN_A
      ? { status: 410, reason: 'Unregistered' }
      : { status: 400, reason: 'BadDeviceToken' }));
    const dev = await makeDev(env);
    const a = (await submit(env)).data;
    const b = (await submit(env, '第二条')).data;
    await push(env, 'PUT', a.id, a.ticket, { token: TOKEN_A });
    await push(env, 'PUT', a.id, a.ticket, { token: TOKEN_B });
    // 同一台设备也登记在 b 下：令牌失效是设备级的，b 下的那条一起清。
    await push(env, 'PUT', b.id, b.ticket, { token: TOKEN_A });
    expect((await devUpdate(env, dev, a.id, { reply: 'hi' })).status).toBe(200);
    expect(sent).toHaveLength(2);
    expect(tokens(env, a.id)).toHaveLength(0);
    expect(tokens(env, b.id)).toHaveLength(0);

    // APNs 整个挂掉（抛异常 / 500）：回复照样写入，令牌保留。
    const c = (await submit(env, '第三条')).data;
    await push(env, 'PUT', c.id, c.ticket, { token: TOKEN_A });
    env.APNS_FETCH = async () => {
      throw new Error('network down');
    };
    vi.spyOn(console, 'log').mockImplementation(() => {});
    const r = await devUpdate(env, dev, c.id, { reply: 'still saved' });
    expect(r.status).toBe(200);
    expect(r.data.messages.at(-1).body).toBe('still saved');
    expect(tokens(env, c.id)).toHaveLength(1);
  });

  it('缺 APNs secrets：不发送、不报错，只记一次日志；结案照样清令牌', async () => {
    const log = vi.spyOn(console, 'log').mockImplementation(() => {});
    const fetchSpy = vi.fn();
    const env = makeEnv({ APNS_FETCH: fetchSpy, APNS_ENV: 'production' });
    const dev = await makeDev(env);
    const a = (await submit(env)).data;
    // 照常登记，但告诉客户端「此刻不会推送」（客户端据此继续用本机后台检查）。
    expect((await push(env, 'PUT', a.id, a.ticket, { token: TOKEN_A })).data)
      .toEqual({ registered: true, delivering: false });
    expect((await devUpdate(env, dev, a.id, { reply: 'one' })).status).toBe(200);
    expect((await devUpdate(env, dev, a.id, { reply: 'two' })).status).toBe(200);
    expect(fetchSpy).not.toHaveBeenCalled();
    expect(log.mock.calls.filter((c) => String(c[0]).startsWith('apns: push not configured'))).toHaveLength(1);
    await devUpdate(env, dev, a.id, { status: 'wont_fix' });
    expect(tokens(env, a.id)).toHaveLength(0);
  });

  it('APNS_ENV 不认识按未配置处理', async () => {
    vi.spyOn(console, 'log').mockImplementation(() => {});
    const { env, sent } = await pushEnv();
    env.APNS_ENV = 'staging';
    const dev = await makeDev(env);
    const a = (await submit(env)).data;
    await push(env, 'PUT', a.id, a.ticket, { token: TOKEN_A });
    await devUpdate(env, dev, a.id, { reply: 'x' });
    expect(sent).toHaveLength(0);
  });
});

describe('provider token（ES256 JWT）', () => {
  it('用 .p8 签名、能被公钥验过；50 分钟内复用，超过重签', async () => {
    const key = await apnsKey();
    const cfg = { keyP8: key.pem, keyId: 'KEY1234567', teamId: 'TEAM123456' };
    const jwt = await apnsJwt(cfg, NOW);
    const [h, c, s] = jwt.split('.');
    const dec = (x) => JSON.parse(new TextDecoder().decode(b64urlDecode(x)));
    expect(dec(h)).toEqual({ alg: 'ES256', kid: 'KEY1234567' });
    expect(dec(c)).toEqual({ iss: 'TEAM123456', iat: Math.floor(NOW / 1000) });
    const ok = await crypto.subtle.verify(
      { name: 'ECDSA', hash: 'SHA-256' }, key.publicKey, b64urlDecode(s), new TextEncoder().encode(`${h}.${c}`),
    );
    expect(ok).toBe(true);
    expect(await apnsJwt(cfg, NOW + PUSH_LIMITS.jwtMaxAgeMs - 1)).toBe(jwt);
    const fresh = await apnsJwt(cfg, NOW + PUSH_LIMITS.jwtMaxAgeMs);
    expect(fresh).not.toBe(jwt);
    expect(dec(fresh.split('.')[1]).iat).toBe(Math.floor((NOW + PUSH_LIMITS.jwtMaxAgeMs) / 1000));
  });
});
