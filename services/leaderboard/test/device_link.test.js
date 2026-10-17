// POST /v1/me/devices：已登录设备代已互联配对的新设备绑定钥匙（新设备只交出公钥 + 持有证明）。
import { describe, expect, it } from 'vitest';
import { call, makeEnv, newKey, registerUser } from './harness.js';
import { MAX_DEVICES } from '../src/account.js';
import { accountIdFromSpki, deviceLinkProofString } from '../src/auth.js';
import { b64urlEncode } from '../src/util.js';

const NOW = Date.UTC(2026, 9, 16, 12);

async function proofFor(key, time) {
  const msg = new TextEncoder().encode(deviceLinkProofString(key.pubkey, time));
  const sig = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key.privateKey, msg);
  return b64urlEncode(new Uint8Array(sig));
}

async function link(env, owner, phone, { time = NOW, proof, now = NOW } = {}) {
  return call(env, 'POST', '/v1/me/devices', {
    key: owner.key,
    account: owner.keyId ?? owner.id,
    body: { pubkey: phone.pubkey, time, proof: proof ?? (await proofFor(phone, time)) },
    now,
  });
}

describe('代绑新设备 POST /v1/me/devices', () => {
  it('已登录设备把新设备公钥挂到同一账户，新设备随即能以该账户身份读写', async () => {
    const env = makeEnv();
    const u = await registerUser(env, 'tom', { now: NOW });
    const phone = await newKey();
    const r = await link(env, u, phone);
    expect(r.status).toBe(201);
    expect(r.data.id).toBe(u.id);
    expect(r.data.nickname).toBe('tom');
    const phoneKeyId = await accountIdFromSpki(phone.spki);
    const me = await call(env, 'GET', '/v1/me', { key: phone, account: phoneKeyId, now: NOW });
    expect(me.status).toBe(200);
    expect(me.data.id).toBe(u.id);
    const patch = await call(env, 'PATCH', '/v1/me', { key: phone, account: phoneKeyId, body: { nickname: 'tom2' }, now: NOW });
    expect(patch.data.nickname).toBe('tom2');
    const list = await call(env, 'GET', '/v1/me/devices', { key: u.key, account: u.id, now: NOW });
    expect(list.data.devices.map((d) => d.keyId)).toEqual([u.id, phoneKeyId]);
  });

  it('上传设备已被占时，新设备视角 uploadDevice=false（与邮箱登录一致）', async () => {
    const env = makeEnv();
    const u = await registerUser(env, 'tom', { now: NOW });
    await call(env, 'POST', '/v1/shelf', { key: u.key, account: u.id, body: { reset: true, put: [] }, now: NOW });
    const r = await link(env, u, await newKey());
    expect(r.data.uploadDevice).toBe(false);
  });

  it('同一把钥匙重复绑定幂等 200；已属于别的账户 409 key_taken', async () => {
    const env = makeEnv();
    const u = await registerUser(env, 'tom', { now: NOW });
    const v = await registerUser(env, 'jerry', { now: NOW });
    const phone = await newKey();
    expect((await link(env, u, phone)).status).toBe(201);
    const again = await link(env, u, phone, { time: NOW + 1 });
    expect(again.status).toBe(200);
    expect(again.data.id).toBe(u.id);
    const stolen = await link(env, v, phone, { time: NOW + 2 });
    expect(stolen.status).toBe(409);
    expect(stolen.data.error).toBe('key_taken');
    // 别人账户的主钥匙也挂不过来。
    expect((await link(env, v, u.key, { time: NOW + 3 })).data.error).toBe('key_taken');
  });

  it('持有证明：签名错 / 换公钥 / 过期都拒绝，且不落库', async () => {
    const env = makeEnv();
    const u = await registerUser(env, 'tom', { now: NOW });
    const phone = await newKey();
    const other = await newKey();
    const bad = await link(env, u, phone, { proof: b64urlEncode(new Uint8Array(64)) });
    expect(bad.data.error).toBe('bad_proof');
    // 别的钥匙签的证明不能给这把公钥用。
    const swapped = await link(env, u, phone, { proof: await proofFor(other, NOW) });
    expect(swapped.data.error).toBe('bad_proof');
    const stale = await link(env, u, phone, { time: NOW - 10 * 60 * 1000 });
    expect(stale.data.error).toBe('stale_time');
    const garbage = await call(env, 'POST', '/v1/me/devices', {
      key: u.key, account: u.id, body: { pubkey: 'AAAA', time: NOW, proof: 'x' }, now: NOW,
    });
    expect(garbage.data.error).toBe('bad_pubkey');
    expect(env.DB.raw.prepare('SELECT COUNT(*) AS n FROM device_keys').get().n).toBe(1);
  });

  it('必须由已登录设备签名：匿名 401、未知钥匙 401', async () => {
    const env = makeEnv();
    const phone = await newKey();
    const anon = await call(env, 'POST', '/v1/me/devices', {
      body: { pubkey: phone.pubkey, time: NOW, proof: await proofFor(phone, NOW) }, now: NOW,
    });
    expect(anon.status).toBe(401);
    const stranger = await newKey();
    const unknown = await link(env, { key: stranger, id: 'nobody' }, phone);
    expect(unknown.data.error).toBe('unknown_account');
  });

  it(`遵守 MAX_DEVICES（${MAX_DEVICES}）：超限 409 too_many_devices`, async () => {
    const env = makeEnv();
    const u = await registerUser(env, 'tom', { now: NOW });
    const out = [];
    for (let i = 0; i < MAX_DEVICES; i++) {
      // 隔小时：每账户每小时最多代绑 10 次。
      const t = NOW + i * 3600 * 1000;
      const r = await link(env, u, await newKey(), { time: t, now: t });
      out.push(r.status === 201 ? 201 : r.data.error);
    }
    expect(out.slice(0, MAX_DEVICES - 1).every((s) => s === 201)).toBe(true);
    expect(out[MAX_DEVICES - 1]).toBe('too_many_devices');
  });

  it('按账户限流：一小时最多 10 次', async () => {
    const env = makeEnv();
    const u = await registerUser(env, 'tom', { now: NOW });
    const phone = await newKey();
    const statuses = [];
    for (let i = 0; i < 11; i++) statuses.push((await link(env, u, phone, { time: NOW + i })).status);
    expect(statuses.slice(0, 10).every((s) => s === 201 || s === 200)).toBe(true);
    expect(statuses[10]).toBe(429);
  });
});
