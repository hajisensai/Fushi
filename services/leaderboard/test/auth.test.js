import { describe, expect, it } from 'vitest';
import { call, makeEnv, newKey, registerUser } from './harness.js';
import { normalizeNickname } from '../src/nickname.js';

const NOW = Date.UTC(2026, 8, 30, 12);

describe('注册', () => {
  it('首次 201，同一把钥匙重复注册返回同一账户 200', async () => {
    const env = makeEnv();
    const key = await newKey();
    const body = { pubkey: key.pubkey, nickname: 'tom' };
    const a = await call(env, 'POST', '/v1/register', { key, body, now: NOW });
    expect(a.status).toBe(201);
    expect(a.data.nickname).toBe('tom');
    expect(a.data.id).toHaveLength(16);
    const b = await call(env, 'POST', '/v1/register', { key, body, now: NOW + 10 });
    expect(b.status).toBe(200);
    expect(b.data.id).toBe(a.data.id);
  });

  it('用别人的公钥注册（签名对不上）→ 401', async () => {
    const env = makeEnv();
    const victim = await newKey();
    const attacker = await newKey();
    const r = await call(env, 'POST', '/v1/register', {
      key: attacker,
      body: { pubkey: victim.pubkey, nickname: 'x' },
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

  it('注册按 IP 限流', async () => {
    const env = makeEnv();
    const statuses = [];
    for (let i = 0; i < 6; i++) {
      const key = await newKey();
      const r = await call(env, 'POST', '/v1/register', {
        key,
        body: { pubkey: key.pubkey, nickname: `n${i}` },
        headers: { 'CF-Connecting-IP': '1.2.3.4' },
        now: NOW,
      });
      statuses.push(r.status);
    }
    expect(statuses).toEqual([201, 201, 201, 201, 201, 429]);
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
