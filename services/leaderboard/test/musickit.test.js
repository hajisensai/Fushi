import { beforeEach, describe, expect, it } from 'vitest';
import { call, makeEnv } from './harness.js';
import { MUSICKIT_LIMITS, resetMusicKitStateForTests } from '../src/musickit.js';
import { b64urlDecode } from '../src/util.js';

const NOW = Date.UTC(2026, 9, 31, 12);

async function mediaKey() {
  const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const der = new Uint8Array(await crypto.subtle.exportKey('pkcs8', pair.privateKey));
  let bin = '';
  for (const b of der) bin += String.fromCharCode(b);
  const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(bin).replace(/(.{64})/g, '$1\n')}\n-----END PRIVATE KEY-----\n`;
  return { pem, publicKey: pair.publicKey };
}

const dec = (x) => JSON.parse(new TextDecoder().decode(b64urlDecode(x)));

beforeEach(() => resetMusicKitStateForTests());

describe('GET /v1/musickit/token', () => {
  it('没配 MUSICKIT_* 时 503，不影响其它接口', async () => {
    const env = makeEnv();
    const r = await call(env, 'GET', '/v1/musickit/token', { now: NOW });
    expect(r.status).toBe(503);
    expect(r.data.error).toBe('musickit_not_configured');
    expect((await call(env, 'GET', '/v1/health', { now: NOW })).status).toBe(200);
  });

  it('签出能被公钥验过的 ES256 developer token，claims 带 Team ID 与一天有效期', async () => {
    const key = await mediaKey();
    const env = makeEnv({ MUSICKIT_KEY_P8: key.pem, MUSICKIT_KEY_ID: '687L35A8T2', MUSICKIT_TEAM_ID: 'TEAM123456' });
    const r = await call(env, 'GET', '/v1/musickit/token', { now: NOW });
    expect(r.status).toBe(200);
    expect(r.res.headers.get('Cache-Control')).toBe('no-store');
    const [h, c, s] = r.data.token.split('.');
    const iat = Math.floor(NOW / 1000);
    const exp = iat + MUSICKIT_LIMITS.tokenTtlMs / 1000;
    expect(dec(h)).toEqual({ alg: 'ES256', kid: '687L35A8T2' });
    expect(dec(c)).toEqual({ iss: 'TEAM123456', iat, exp });
    expect(r.data.expiresAt).toBe(exp * 1000);
    const ok = await crypto.subtle.verify(
      { name: 'ECDSA', hash: 'SHA-256' }, key.publicKey, b64urlDecode(s), new TextEncoder().encode(`${h}.${c}`),
    );
    expect(ok).toBe(true);
  });

  it('有效期过半前复用同一枚 token，过半重签', async () => {
    const key = await mediaKey();
    const env = makeEnv({ MUSICKIT_KEY_P8: key.pem, MUSICKIT_KEY_ID: '687L35A8T2', MUSICKIT_TEAM_ID: 'TEAM123456' });
    const half = MUSICKIT_LIMITS.tokenTtlMs / 2;
    const first = (await call(env, 'GET', '/v1/musickit/token', { now: NOW })).data;
    const reused = (await call(env, 'GET', '/v1/musickit/token', { now: NOW + half - 1 })).data;
    expect(reused).toEqual(first);
    const fresh = (await call(env, 'GET', '/v1/musickit/token', { now: NOW + half })).data;
    expect(fresh.token).not.toBe(first.token);
    expect(fresh.expiresAt).toBe(Math.floor((NOW + half) / 1000) * 1000 + MUSICKIT_LIMITS.tokenTtlMs);
  });
});
