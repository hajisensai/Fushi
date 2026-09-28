import { describe, expect, it } from 'vitest';
import { call, lastCode, makeEnv, newKey, nextIp, registerUser } from './harness.js';
import { normalizeNickname } from '../src/nickname.js';

const NOW = Date.UTC(2026, 8, 30, 12);

describe('注册（邮箱验证码）', () => {
  async function codeFor(env, email, purpose = 'register', ip = nextIp()) {
    const r = await call(env, 'POST', '/v1/email/code', {
      body: { email, purpose, lang: 'zh' },
      headers: { 'CF-Connecting-IP': ip },
      now: NOW,
    });
    return { status: r.status, code: lastCode(env, email) };
  }

  it('验证码注册 201；同一把钥匙重复注册返回同一账户 200（不再要验证码）', async () => {
    const env = makeEnv();
    const key = await newKey();
    const { status, code } = await codeFor(env, 'Tom@Example.com ');
    expect(status).toBe(202);
    expect(env.sent[0].to).toBe('tom@example.com');
    expect(env.sent[0].subject).toBe('Fushi 验证码');
    const body = { pubkey: key.pubkey, nickname: 'tom', email: 'tom@example.com', code };
    const a = await call(env, 'POST', '/v1/register', { key, body, now: NOW });
    expect(a.status).toBe(201);
    expect(a.data).toMatchObject({ nickname: 'tom', emailVerified: true });
    expect(a.data.id).toHaveLength(16);
    const b = await call(env, 'POST', '/v1/register', { key, body: { ...body, code: '000000' }, now: NOW + 10 });
    expect(b.status).toBe(200);
    expect(b.data.id).toBe(a.data.id);
  });

  it('不存邮箱明文', async () => {
    const env = makeEnv();
    await registerUser(env, 'tom', { email: 'secret.person@example.com', now: NOW });
    const dump = JSON.stringify(env.DB.raw.prepare('SELECT * FROM accounts').all())
      + JSON.stringify(env.DB.raw.prepare('SELECT * FROM email_codes').all());
    expect(dump).not.toContain('secret.person');
  });

  it('错码累计 5 次后作废；过期 410；验证码只能用一次', async () => {
    const env = makeEnv();
    const key = await newKey();
    const { code } = await codeFor(env, 'a@example.com');
    // 每次换 IP：注册入口按 IP 限流（本身就是防暴力猜码的一道），这里要测的是验证码自己的次数上限。
    const reg = (c, now = NOW) => call(env, 'POST', '/v1/register', {
      key, body: { pubkey: key.pubkey, nickname: 'a', email: 'a@example.com', code: c }, now,
      headers: { 'CF-Connecting-IP': nextIp() },
    });
    const wrong = code === '111111' ? '222222' : '111111';
    for (let i = 0; i < 5; i++) expect((await reg(wrong)).data.error).toBe('bad_code');
    expect((await reg(code)).data.error).toBe('too_many_attempts'); // 第 6 次即便对也作废
    expect((await reg(code)).data.error).toBe('bad_code');

    const env2 = makeEnv();
    const k2 = await newKey();
    const c2 = (await codeFor(env2, 'b@example.com')).code;
    const late = await call(env2, 'POST', '/v1/register', {
      key: k2, body: { pubkey: k2.pubkey, nickname: 'b', email: 'b@example.com', code: c2 },
      now: NOW + 11 * 60 * 1000, time: NOW + 11 * 60 * 1000,
    });
    expect(late.status).toBe(410);
  });

  it('验证码用过即作废：同一个码不能再用第二次', async () => {
    const env = makeEnv();
    const k1 = await newKey();
    const k2 = await newKey();
    const { code } = await codeFor(env, 'once@example.com');
    const body = (k, nickname) => ({ pubkey: k.pubkey, nickname, email: 'once@example.com', code });
    expect((await call(env, 'POST', '/v1/register', { key: k1, body: body(k1, 'a'), now: NOW })).status).toBe(201);
    const again = await call(env, 'POST', '/v1/register', { key: k2, body: body(k2, 'b'), now: NOW });
    expect(again.data.error).toBe('bad_code'); // 不是 email_taken：码已被消费，根本走不到占用检查
  });

  it('同一邮箱只能注册一个账户', async () => {
    const env = makeEnv();
    await registerUser(env, 'first', { email: 'dup@example.com', now: NOW });
    const key = await newKey();
    const { code } = await codeFor(env, 'dup@example.com');
    const r = await call(env, 'POST', '/v1/register', {
      key, body: { pubkey: key.pubkey, nickname: 'second', email: 'dup@example.com', code }, now: NOW,
    });
    expect(r.status).toBe(409);
    expect(r.data.error).toBe('email_taken');
  });

  it('用别人的公钥注册（签名对不上）→ 401', async () => {
    const env = makeEnv();
    const victim = await newKey();
    const attacker = await newKey();
    const r = await call(env, 'POST', '/v1/register', {
      key: attacker,
      body: { pubkey: victim.pubkey, nickname: 'x', email: 'x@example.com', code: '123456' },
      now: NOW,
    });
    expect(r.status).toBe(401);
    expect(r.data.error).toBe('bad_signature');
  });

  it('同名用户拿到不同判别码', async () => {
    const env = makeEnv();
    const seen = new Set();
    for (let i = 0; i < 5; i++) {
      const u = await registerUser(env, 'same', { now: NOW });
      seen.add(u.discriminator);
    }
    expect(seen.size).toBe(5);
  });

  it('发码：按 IP 限流是显式 429；按邮箱限流与预算耗尽一律静默（照样 202，只是不发）', async () => {
    const env = makeEnv();
    const ipStatuses = [];
    for (let i = 0; i < 6; i++) ipStatuses.push((await codeFor(env, `ip${i}@example.com`, 'register', '1.2.3.4')).status);
    expect(ipStatuses).toEqual([202, 202, 202, 202, 202, 429]);
    const before = env.sent.length;
    const addrStatuses = [];
    for (let i = 0; i < 4; i++) addrStatuses.push((await codeFor(env, 'same@example.com')).status);
    expect(addrStatuses).toEqual([202, 202, 202, 202]);
    expect(env.sent.length - before).toBe(3);

    const tight = makeEnv({ BUDGET_EMAIL: '2' });
    const b = [];
    for (let i = 0; i < 3; i++) b.push((await codeFor(tight, `b${i}@example.com`)).status);
    expect(b).toEqual([202, 202, 202]);
    expect(tight.sent).toHaveLength(2);
  });

  it('防探测：预算耗尽时已注册 / 未注册邮箱的登录发码响应完全一致', async () => {
    const env = makeEnv({ BUDGET_EMAIL: '1' });
    await registerUser(env, 'known', { email: 'known@example.com', now: NOW }); // 用掉唯一的 1 封
    const known = await codeFor(env, 'known@example.com', 'login');
    const ghost = await codeFor(env, 'ghost@example.com', 'login');
    expect([known.status, ghost.status]).toEqual([202, 202]);
    expect(env.sent).toHaveLength(1);
  });

  it('同一邮箱每天累计猜错 10 次后，跨重发也不再接受任何码', async () => {
    const env = makeEnv();
    const key = await newKey();
    const reg = (c) => call(env, 'POST', '/v1/register', {
      key, body: { pubkey: key.pubkey, nickname: 'a', email: 'cap@example.com', code: c }, now: NOW,
      headers: { 'CF-Connecting-IP': nextIp() },
    });
    let code = null;
    for (let round = 0; round < 3; round++) {
      code = (await codeFor(env, 'cap@example.com')).code;
      const wrong = code === '111111' ? '222222' : '111111';
      for (let i = 0; i < 4; i++) await reg(wrong);
    }
    // 已猜错 12 次 > 10：拿着最新的正确码也被拒。
    expect((await reg(code)).data.error).toBe('too_many_attempts');
  });

  it('没配置发信 / pepper → 503 fail-closed', async () => {
    const env = makeEnv({ EMAIL_SENDER: undefined });
    expect((await codeFor(env, 'x@example.com')).status).toBe(503);
    const env2 = makeEnv({ EMAIL_PEPPER: '' });
    expect((await codeFor(env2, 'x@example.com')).status).toBe(503);
  });
});

describe('新设备登录', () => {
  it('邮箱验证码把新设备的钥匙绑到已有账户，之后能以该账户身份写', async () => {
    const env = makeEnv();
    const u = await registerUser(env, 'tom', { email: 'tom@example.com', now: NOW });
    const phone = await newKey();
    await call(env, 'POST', '/v1/email/code', { body: { email: 'tom@example.com', purpose: 'login' }, headers: { 'CF-Connecting-IP': nextIp() }, now: NOW });
    const r = await call(env, 'POST', '/v1/login', {
      key: phone, body: { pubkey: phone.pubkey, email: 'tom@example.com', code: lastCode(env, 'tom@example.com') }, now: NOW,
    });
    expect(r.status).toBe(200);
    expect(r.data.id).toBe(u.id);
    const { accountIdFromSpki } = await import('../src/auth.js');
    const phoneKeyId = await accountIdFromSpki(phone.spki);
    expect(phoneKeyId).not.toBe(u.id);
    const patch = await call(env, 'PATCH', '/v1/me', { key: phone, account: phoneKeyId, body: { nickname: 'tom2' }, now: NOW });
    expect(patch.status).toBe(200);
    expect(patch.data.id).toBe(u.id);
    expect(patch.data.nickname).toBe('tom2');
  });

  it('防探测：没账户的邮箱申请登录码也回 202，但不发信，登录必然 bad_code', async () => {
    const env = makeEnv();
    const r = await call(env, 'POST', '/v1/email/code', { body: { email: 'ghost@example.com', purpose: 'login' }, headers: { 'CF-Connecting-IP': nextIp() }, now: NOW });
    expect(r.status).toBe(202);
    expect(env.sent).toHaveLength(0);
    const key = await newKey();
    const l = await call(env, 'POST', '/v1/login', {
      key, body: { pubkey: key.pubkey, email: 'ghost@example.com', code: '123456' }, now: NOW,
    });
    expect(l.data.error).toBe('bad_code');
  });

  it('一个账户最多 10 台设备', async () => {
    const env = makeEnv();
    await registerUser(env, 'tom', { email: 'many@example.com', now: NOW });
    const statuses = [];
    for (let i = 0; i < 10; i++) {
      const k = await newKey();
      // 隔天申请：同一邮箱每天最多 10 封。
      const t = NOW + (i + 1) * 24 * 3600 * 1000;
      await call(env, 'POST', '/v1/email/code', { body: { email: 'many@example.com', purpose: 'login' }, headers: { 'CF-Connecting-IP': nextIp() }, now: t });
      const r = await call(env, 'POST', '/v1/login', {
        key: k, body: { pubkey: k.pubkey, email: 'many@example.com', code: lastCode(env, 'many@example.com') }, now: t,
        headers: { 'CF-Connecting-IP': nextIp() },
      });
      statuses.push(r.status === 200 ? 200 : r.data.error);
    }
    expect(statuses.slice(0, 9).every((s) => s === 200)).toBe(true);
    expect(statuses[9]).toBe('too_many_devices');
  });
});

describe('昵称规范化', () => {
  it('折叠空白、拒绝零宽/方向控制符与 #、限长 24 码点', () => {
    expect(normalizeNickname('  a   b ')).toBe('a b');
    expect(normalizeNickname('a​b')).toBeNull();
    expect(normalizeNickname('a‮b')).toBeNull();
    expect(normalizeNickname('a#1')).toBeNull();
    expect(normalizeNickname('字'.repeat(24))).toBe('字'.repeat(24));
    expect(normalizeNickname('字'.repeat(25))).toBeNull();
    expect(normalizeNickname('')).toBeNull();
  });

  it('屏蔽词来自 env.BANNED_WORDS', async () => {
    const env = makeEnv({ BANNED_WORDS: 'Bad, worse' });
    const key = await newKey();
    const r = await call(env, 'POST', '/v1/register', {
      key,
      body: { pubkey: key.pubkey, nickname: 'so BAD' },
      now: NOW,
    });
    expect(r.status).toBe(400);
    expect(r.data.error).toBe('nickname_rejected');
  });
});

describe('签名请求', () => {
  it('签名错 / 时刻过期 / 未知账户 → 401', async () => {
    const env = makeEnv();
    const u = await registerUser(env, 'tom', { now: NOW });
    const bad = await call(env, 'GET', '/v1/me', { key: u.key, account: u.id, badSig: true, now: NOW });
    expect(bad.data.error).toBe('bad_signature');
    const stale = await call(env, 'GET', '/v1/me', { key: u.key, account: u.id, time: NOW - 6 * 60 * 1000, now: NOW });
    expect(stale.data.error).toBe('stale_time');
    const unknown = await call(env, 'GET', '/v1/me', { key: u.key, account: 'nope', now: NOW });
    expect(unknown.data.error).toBe('unknown_account');
  });

  it('签名覆盖路径与查询串：篡改 query 失效', async () => {
    const env = makeEnv();
    const u = await registerUser(env, 'tom', { now: NOW });
    const ok = await call(env, 'GET', '/v1/rank?metric=book', { key: u.key, account: u.id, now: NOW });
    expect(ok.status).toBe(200);
    // 用 metric=book 的签名去请求 metric=chars。
    const { signingString } = await import('../src/auth.js');
    const { b64urlEncode } = await import('../src/util.js');
    const msg = await signingString('GET', '/v1/rank?metric=book', NOW, new Uint8Array());
    const sig = new Uint8Array(
      await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, u.key.privateKey, new TextEncoder().encode(msg)),
    );
    const r = await call(env, 'GET', '/v1/rank?metric=chars', {
      headers: { 'X-Fushi-Account': u.id, 'X-Fushi-Time': String(NOW), 'X-Fushi-Sig': b64urlEncode(sig) },
      now: NOW,
    });
    expect(r.data.error).toBe('bad_signature');
  });

  it('写请求防重放：同一签名串第二次被拒；乱序到达的不同写请求照常放行', async () => {
    const env = makeEnv();
    const u = await registerUser(env, 'tom', { now: NOW });
    const w1 = await call(env, 'PATCH', '/v1/me', { key: u.key, account: u.id, body: { visibility: 'friends' }, time: NOW + 100, now: NOW });
    expect(w1.status).toBe(200);
    const replay = await call(env, 'PATCH', '/v1/me', { key: u.key, account: u.id, body: { visibility: 'friends' }, time: NOW + 100, now: NOW });
    expect(replay.data.error).toBe('replayed');
    // 并发写乱序到达：时刻更早但内容不同 → 合法。
    const older = await call(env, 'PATCH', '/v1/me', { key: u.key, account: u.id, body: { visibility: 'public' }, time: NOW + 50, now: NOW });
    expect(older.status).toBe(200);
    expect(older.data.visibility).toBe('public');
  });

  it('ECDSA 延展签名 (r, n−s) 重放同一请求也被拒（去重键是签名串，不是签名值）', async () => {
    const env = makeEnv();
    const u = await registerUser(env, 'tom', { now: NOW });
    const { signingString } = await import('../src/auth.js');
    const { b64urlEncode } = await import('../src/util.js');
    const body = new TextEncoder().encode(JSON.stringify({ visibility: 'friends' }));
    const time = NOW + 500;
    const msg = await signingString('PATCH', '/v1/me', time, body);
    const sig = new Uint8Array(
      await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, u.key.privateKey, new TextEncoder().encode(msg)),
    );
    // s' = n − s（P-256 群阶 n）。
    const N = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551n;
    const toBig = (b) => BigInt('0x' + [...b].map((x) => x.toString(16).padStart(2, '0')).join(''));
    const toBytes = (v) => Uint8Array.from((v.toString(16).padStart(64, '0').match(/../g)).map((h) => parseInt(h, 16)));
    const flipped = new Uint8Array(64);
    flipped.set(sig.slice(0, 32), 0);
    flipped.set(toBytes(N - toBig(sig.slice(32))), 32);
    const send = (s) => call(env, 'PATCH', '/v1/me', {
      body,
      headers: { 'X-Fushi-Account': u.id, 'X-Fushi-Time': String(time), 'X-Fushi-Sig': b64urlEncode(s), 'Content-Type': 'application/json' },
      now: NOW,
    });
    expect((await send(sig)).status).toBe(200);
    const replay = await send(flipped);
    expect(replay.status).toBe(401);
    expect(replay.data.error).toBe('replayed'); // 证明延展签名本身验签通过，是去重拦下的
  });

  it('改昵称重新分配判别码，visibility 只收两个值', async () => {
    const env = makeEnv();
    const u = await registerUser(env, 'tom', { now: NOW });
    const r = await call(env, 'PATCH', '/v1/me', { key: u.key, account: u.id, body: { nickname: 'jerry' }, now: NOW });
    expect(r.data.nickname).toBe('jerry');
    const bad = await call(env, 'PATCH', '/v1/me', { key: u.key, account: u.id, body: { visibility: 'secret' }, now: NOW });
    expect(bad.data.error).toBe('bad_visibility');
  });
});
