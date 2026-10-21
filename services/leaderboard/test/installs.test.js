// 安装统计心跳（迁移 0011 / 0013 / 0017；POST /v1/ping、安装证明、/dev/stats、反馈详情的安装轨迹）。
import { createHash } from 'node:crypto';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { BASE, call, makeEnv, newKey, nextIp, registerUser } from './harness.js';
import {
  INSTALL_HEADERS,
  INSTALL_LIMITS,
  INSTALL_POW_BITS,
  INSTALL_SIG_PREFIX,
  installIdFromSpki,
  installPowValid,
  installStats,
  normalizeLocale,
  retentionCohorts,
  versionAdoption,
  versionIncludes,
} from '../src/installs.js';
import {
  archLabel, countryLabel, localeLabel, osVersionLabel, sourceLabel,
} from '../src/devconsole.js';
import { signingString } from '../src/auth.js';
import { b64urlDecode, b64urlEncode } from '../src/util.js';
import worker from '../src/worker.js';

const NOW = Date.UTC(2026, 9, 17, 12);
const DAY = 24 * 3600 * 1000;
const A = '0f8fad5b-d9cb-469f-a165-70867728950e';
const B = '7c9e6679-7425-40de-944b-e07fc1f90ae7';
const basic = { Authorization: `Basic ${btoa('admin:pw')}` };

/** 未验证（旧客户端形状）的心跳：只有 body，没有安装证明头。 */
function ping(env, body = {}, opts = {}) {
  return call(env, 'POST', '/v1/ping', {
    body: { installId: A, version: '2.10.0', platform: 'windows', channel: 'stable', ...body },
    headers: { 'CF-Connecting-IP': opts.ip ?? nextIp() },
    now: opts.now ?? NOW,
    cf: opts.cf,
  });
}

/** 前导 0 位数（测试侧独立实现，用 node:crypto 同步哈希求解 PoW）。 */
function zeroBits(buf, bits) {
  for (let i = 0; i < bits; i += 1) {
    if ((buf[i >> 3] >> (7 - (i & 7))) & 1) return false;
  }
  return true;
}
function solvePow(installId, bits = INSTALL_POW_BITS) {
  for (let n = 0; ; n += 1) {
    if (zeroBits(createHash('sha256').update(`fip1|${installId}|${n}`).digest(), bits)) return String(n);
  }
}

// 固定安装池（test/gen_install_pool.mjs 生成）：现场给随机钥匙解 PoW 的耗时长尾很重，
// 一条用例造 2~3 个安装就会随机超过 5 秒超时。池按顺序轮转，单条用例里取到的互不相同。
const POOL = JSON.parse(readFileSync(new URL('./install_pool.json', import.meta.url), 'utf8'));
let poolCursor = 0;

/** 一个安装：WebCrypto 钥匙 + 指纹 id + 已求好的 PoW（取自固定池）。 */
async function makeInstall() {
  const { jwk, installId, pow } = POOL.installs[poolCursor++ % POOL.installs.length];
  const algo = { name: 'ECDSA', namedCurve: 'P-256' };
  const privateKey = await crypto.subtle.importKey('jwk', jwk, algo, true, ['sign']);
  const publicKey = await crypto.subtle.importKey('jwk', { kty: jwk.kty, crv: jwk.crv, x: jwk.x, y: jwk.y }, algo, true, ['verify']);
  const spki = new Uint8Array(await crypto.subtle.exportKey('spki', publicKey));
  return { key: { privateKey, publicKey, spki, pubkey: b64urlEncode(spki) }, installId, pow };
}

/** 给一次请求构造安装证明头。override 可替换任一头（构造伪造请求用）。 */
async function proofHeaders(inst, method, path, bytes, time, override = {}) {
  const msg = INSTALL_SIG_PREFIX + await signingString(method, path, time, bytes);
  const sig = new Uint8Array(await crypto.subtle.sign(
    { name: 'ECDSA', hash: 'SHA-256' }, inst.key.privateKey, new TextEncoder().encode(msg),
  ));
  const all = {
    [INSTALL_HEADERS.key]: inst.key.pubkey,
    [INSTALL_HEADERS.time]: String(time),
    [INSTALL_HEADERS.sig]: b64urlEncode(sig),
    [INSTALL_HEADERS.pow]: inst.pow,
    ...override,
  };
  return Object.fromEntries(Object.entries(all).filter(([, v]) => v !== undefined));
}

/** 已验证的心跳。opts.override 改头、opts.time 改签名时刻、opts.bodyInstallId 改 body 里的 id。 */
async function signedPing(env, inst, body = {}, opts = {}) {
  const now = opts.now ?? NOW;
  const bytes = new TextEncoder().encode(JSON.stringify({
    installId: opts.bodyInstallId ?? inst.installId, version: '2.10.0', platform: 'windows', channel: 'stable', ...body,
  }));
  const headers = await proofHeaders(inst, 'POST', '/v1/ping', bytes, opts.time ?? now, opts.override);
  return call(env, 'POST', '/v1/ping', {
    body: bytes,
    headers: { 'CF-Connecting-IP': opts.ip ?? nextIp(), ...headers, ...(opts.extraHeaders || {}) },
    now,
    cf: opts.cf,
  });
}

const utcDay = (ms) => new Date(ms).toISOString().slice(0, 10);

let seedSeq = 0;
/** 统计用例的合成安装 id（形状合法的 UUID v4，不对应任何钥匙）。 */
const seedId = () => `00000000-0000-4000-8000-${String((seedSeq += 1)).padStart(12, '0')}`;

/**
 * 直接写一条心跳（跳过签名 + PoW）：只给统计**聚合**类用例用——每个 makeInstall 要现解一次 18 位 PoW，
 * 聚合用例一次造好几个安装会把并行跑的其它测试文件饿到超时。入库路径由签名心跳的用例覆盖。
 * 按时间顺序调用（installs 的最近值取最后一次调用）。
 */
function seedPing(env, id, fields = {}) {
  const f = {
    at: NOW, verified: 1, platform: 'windows', channel: 'stable', version: '2.10.0',
    country: null, locale: null, arch: null, osVersion: null, source: null, ...fields,
  };
  env.DB.raw.prepare(
    `INSERT INTO install_days
       (day, install_id, platform, channel, version, verified, country, locale, arch, os_version, source)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT DO NOTHING`,
  ).run(utcDay(f.at), id, f.platform, f.channel, f.version, f.verified, f.country, f.locale, f.arch, f.osVersion, f.source);
  if (!f.verified) return;
  env.DB.raw.prepare(
    `INSERT INTO installs
       (install_id, first_seen, last_seen, platform, channel, version, verified, country, locale, arch, os_version, source)
     VALUES (?1, ?2, ?2, ?3, ?4, ?5, 1, ?6, ?7, ?8, ?9, ?10)
     ON CONFLICT (install_id) DO UPDATE SET last_seen = MAX(last_seen, ?2), platform = ?3, channel = ?4,
       version = ?5, country = ?6, locale = ?7, arch = ?8, os_version = ?9, source = ?10`,
  ).run(id, f.at, f.platform, f.channel, f.version, f.country, f.locale, f.arch, f.osVersion, f.source);
}
const count = (env, table) => env.DB.raw.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get().n;
const budgetUsed = (env, day = '2026-10-17') =>
  env.DB.raw.prepare("SELECT used FROM budgets WHERE day = ? AND kind = 'ping'").get(day)?.used ?? 0;
const installRow = (env, id) => env.DB.raw.prepare('SELECT * FROM installs WHERE install_id = ?').get(id);

let devSeq = 0;
async function devPage(env, path) {
  const dev = await registerUser(env, 'dev', { now: NOW });
  expect((await call(env, 'POST', `/admin/api/accounts/${dev.id}/role`, { headers: basic, body: { role: 'dev' }, now: NOW })).status).toBe(200);
  devSeq += 1;
  const token = `tok${devSeq}`.padEnd(43, 'x');
  const { hex, sha256 } = await import('../src/util.js');
  env.DB.raw.prepare('INSERT INTO dev_sessions (token_hash, account_id, expires_at) VALUES (?, ?, ?)')
    .run(hex(await sha256(new TextEncoder().encode(token))), dev.id, NOW + DAY);
  return call(env, 'GET', path, { headers: { Cookie: `fushi_dev=${token}` }, now: NOW });
}

describe('POST /v1/ping（未验证 / 旧客户端）', () => {
  it('首次心跳 → 204，写入 installs 与 install_days（verified = 0），不存 IP', async () => {
    const env = makeEnv();
    const r = await ping(env, {}, { ip: '203.0.113.9' });
    expect(r.status).toBe(204);
    const row = installRow(env, A);
    expect(row).toMatchObject({
      first_seen: NOW, last_seen: NOW, platform: 'windows', channel: 'stable', version: '2.10.0', verified: 0,
    });
    expect(env.DB.raw.prepare('SELECT * FROM install_days').all()).toEqual([
      {
        day: '2026-10-17', install_id: A, platform: 'windows', channel: 'stable', version: '2.10.0', verified: 0,
        country: null, locale: null, arch: null, os_version: null, source: null,
      },
    ]);
    const dump = JSON.stringify([
      env.DB.raw.prepare('SELECT * FROM installs').all(),
      env.DB.raw.prepare('SELECT * FROM install_days').all(),
    ]);
    expect(dump).not.toContain('203.0.113.9');
    expect(budgetUsed(env)).toBe(1);
  });

  it('同一安装同一天第二次心跳不写库、不扣预算', async () => {
    const env = makeEnv();
    await ping(env);
    const r = await ping(env, { version: '2.10.1' }, { now: NOW + 3600 * 1000 });
    expect(r.status).toBe(204);
    expect(count(env, 'install_days')).toBe(1);
    expect(env.DB.raw.prepare('SELECT version, last_seen FROM installs').get()).toEqual({ version: '2.10.0', last_seen: NOW });
    expect(budgetUsed(env)).toBe(1);
  });

  it('隔天心跳更新 installs 的最近版本，install_days 按天各一行', async () => {
    const env = makeEnv();
    await ping(env);
    await ping(env, { version: '2.11.0' }, { now: NOW + DAY });
    expect(count(env, 'install_days')).toBe(2);
    expect(env.DB.raw.prepare('SELECT first_seen, last_seen, version FROM installs').get())
      .toEqual({ first_seen: NOW, last_seen: NOW + DAY, version: '2.11.0' });
  });

  it.each([
    ['installId 不是 UUID v4', { installId: 'abc' }, 'bad_install_id'],
    ['installId 大写', { installId: A.toUpperCase() }, 'bad_install_id'],
    ['iOS 不收', { platform: 'ios' }, 'bad_platform'],
    ['未知通道', { channel: 'nightly' }, 'bad_channel'],
    ['版本串含空格', { version: '2.10 beta' }, 'bad_version'],
    ['界面语言不是字符串', { locale: 42 }, 'bad_locale'],
    ['界面语言形状不对', { locale: 'zh CN' }, 'bad_locale'],
    ['架构带大写 / 空格', { arch: 'ARM 64' }, 'bad_arch'],
    ['系统版本不是字符串', { osVersion: 34 }, 'bad_os_version'],
    ['安装来源太长', { source: 'x'.repeat(25) }, 'bad_source'],
  ])('%s → 400', async (_name, body, code) => {
    const env = makeEnv();
    const r = await ping(env, body);
    expect(r.status).toBe(400);
    expect(r.data.error).toBe(code);
    expect(count(env, 'installs')).toBe(0);
  });

  it('ping 日预算打满 → 503，已记过的安装照常 204', async () => {
    const env = makeEnv({ BUDGET_PING: '1' });
    expect((await ping(env)).status).toBe(204);
    const r = await ping(env, { installId: B });
    expect(r.status).toBe(503);
    expect(r.data.error).toBe('daily_budget');
    expect((await ping(env)).status).toBe(204);
  });
});

describe('安装证明', () => {
  it('installIdFromSpki：UUID v4 形状、确定性、不同公钥不同', async () => {
    const k1 = await newKey();
    const k2 = await newKey();
    const id1 = await installIdFromSpki(k1.spki);
    expect(id1).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
    expect(await installIdFromSpki(k1.spki)).toBe(id1);
    expect(await installIdFromSpki(k2.spki)).not.toBe(id1);
  });

  it('installPowValid：求出的 nonce 过、别的 id / 非数字 nonce 不过', async () => {
    const nonce = solvePow(A);
    expect(await installPowValid(A, nonce)).toBe(true);
    expect(await installPowValid(B, nonce, 30)).toBe(false);
    expect(await installPowValid(A, 'x1')).toBe(false);
    expect(await installPowValid(A, undefined)).toBe(false);
  });

  it('签名 + PoW 正确 → 204，记 verified = 1', async () => {
    const env = makeEnv();
    const inst = await makeInstall();
    const r = await signedPing(env, inst);
    expect(r.status).toBe(204);
    expect(installRow(env, inst.installId).verified).toBe(1);
    expect(env.DB.raw.prepare('SELECT verified FROM install_days WHERE install_id = ?').get(inst.installId).verified).toBe(1);
  });

  it('installId ≠ 公钥指纹 → 401 install_id_mismatch，不落库', async () => {
    const env = makeEnv();
    const inst = await makeInstall();
    const other = await makeInstall();
    const r = await signedPing(env, inst, {}, { bodyInstallId: other.installId });
    expect(r.status).toBe(401);
    expect(r.data.error).toBe('install_id_mismatch');
    expect(count(env, 'installs')).toBe(0);
  });

  it('签名错（别的钥匙签 / 篡改请求体）→ 401 bad_install_signature', async () => {
    const env = makeEnv();
    const inst = await makeInstall();
    const other = await makeInstall();
    // 公钥是 inst 的，签名却是 other 的钥匙签的。
    const forged = { ...inst, key: { ...inst.key, privateKey: other.key.privateKey } };
    const r1 = await signedPing(env, forged);
    expect(r1.status).toBe(401);
    expect(r1.data.error).toBe('bad_install_signature');
    // 签的是 version 2.10.0 的体，发出去的是 2.99.0。
    const goodBytes = new TextEncoder().encode(JSON.stringify({
      installId: inst.installId, version: '2.10.0', platform: 'windows', channel: 'stable',
    }));
    const headers = await proofHeaders(inst, 'POST', '/v1/ping', goodBytes, NOW);
    const r2 = await call(env, 'POST', '/v1/ping', {
      body: { installId: inst.installId, version: '2.99.0', platform: 'windows', channel: 'stable' },
      headers: { 'CF-Connecting-IP': nextIp(), ...headers },
      now: NOW,
    });
    expect(r2.status).toBe(401);
    expect(r2.data.error).toBe('bad_install_signature');
    expect(count(env, 'installs')).toBe(0);
  });

  it('同一签名请求重放：当天已记过时直接 204 无副作用；会写库时 401 install_replayed', async () => {
    const env = makeEnv();
    const inst = await makeInstall();
    const bytes = new TextEncoder().encode(JSON.stringify({
      installId: inst.installId, version: '2.10.0', platform: 'windows', channel: 'stable',
    }));
    const headers = await proofHeaders(inst, 'POST', '/v1/ping', bytes, NOW);
    const send = () => call(env, 'POST', '/v1/ping', {
      body: bytes, headers: { 'CF-Connecting-IP': nextIp(), ...headers }, now: NOW,
    });
    expect((await send()).status).toBe(204);
    expect((await send()).status).toBe(204);
    expect(count(env, 'install_days')).toBe(1);
    // 当天记录不在了（例如被清理）→ 这次重放会走到写库，签名串已登记过 → 拒。
    env.DB.raw.prepare('DELETE FROM install_days').run();
    const r = await send();
    expect(r.status).toBe(401);
    expect(r.data.error).toBe('install_replayed');
  });

  it('已验证安装当天第二次心跳（换签名时刻）：不验签不写 used_sigs、不写库、不扣预算', async () => {
    const env = makeEnv();
    const inst = await makeInstall();
    const sigs = () => env.DB.raw.prepare("SELECT COUNT(*) AS n FROM used_sigs WHERE account_id LIKE 'install:%'").get().n;
    expect((await signedPing(env, inst)).status).toBe(204);
    expect(sigs()).toBe(1);
    expect(budgetUsed(env)).toBe(1);
    for (let i = 1; i <= 3; i += 1) {
      const r = await signedPing(env, inst, { version: '2.10.1' }, { now: NOW + i * 60 * 1000 });
      expect(r.status).toBe(204);
    }
    expect(sigs()).toBe(1);
    expect(budgetUsed(env)).toBe(1);
    expect(installRow(env, inst.installId)).toMatchObject({ version: '2.10.0', last_seen: NOW });
    // 无状态检查照常先做：拿别人的公钥来「探测」当天是否记过，过不了指纹比对。
    const other = await makeInstall();
    const probe = await signedPing(env, inst, {}, { now: NOW + 5000, override: { [INSTALL_HEADERS.key]: other.key.pubkey } });
    expect(probe.status).toBe(401);
    expect(probe.data.error).toBe('install_id_mismatch');
  });

  it('签名时刻超出 ±5 分钟 → 401 stale_install_time', async () => {
    const env = makeEnv();
    const inst = await makeInstall();
    const r = await signedPing(env, inst, {}, { time: NOW - 6 * 60 * 1000 });
    expect(r.status).toBe(401);
    expect(r.data.error).toBe('stale_install_time');
  });

  it('PoW 不足 / 缺失 → 401', async () => {
    const env = makeEnv();
    const inst = await makeInstall();
    // 找一个满足不了难度的 nonce（不满足 18 位的绝大多数 nonce 都行）。
    let bad = 0;
    while (await installPowValid(inst.installId, String(bad))) bad += 1;
    const r1 = await signedPing(env, inst, {}, { override: { [INSTALL_HEADERS.pow]: String(bad) } });
    expect(r1.status).toBe(401);
    expect(r1.data.error).toBe('install_pow_required');
    const r2 = await signedPing(env, { ...inst, pow: undefined }, {}, {});
    expect(r2.status).toBe(401);
    expect(r2.data.error).toBe('bad_install_proof');
    expect(count(env, 'installs')).toBe(0);
  });

  it('只带部分证明头 → 401 bad_install_proof（不静默降成未验证）', async () => {
    const env = makeEnv();
    const r = await call(env, 'POST', '/v1/ping', {
      body: { installId: A, version: '2.10.0', platform: 'windows', channel: 'stable' },
      headers: { 'CF-Connecting-IP': nextIp(), [INSTALL_HEADERS.key]: 'AAAA' },
      now: NOW,
    });
    expect(r.status).toBe(401);
    expect(r.data.error).toBe('bad_install_proof');
  });

  it('未验证心跳改写不了已验证安装的行；已验证心跳可把同 id 的未验证行升级', async () => {
    const env = makeEnv();
    const inst = await makeInstall();
    // 先有人用这个 id 发了未验证心跳（例如猜到了 id），随后本人发已验证心跳 → 升级。
    await ping(env, { installId: inst.installId, platform: 'linux' });
    expect(installRow(env, inst.installId).verified).toBe(0);
    expect((await signedPing(env, inst, { platform: 'windows' }, { now: NOW + 1000 })).status).toBe(204);
    expect(installRow(env, inst.installId)).toMatchObject({ verified: 1, platform: 'windows' });
    expect(env.DB.raw.prepare('SELECT verified, platform FROM install_days WHERE install_id = ?').get(inst.installId))
      .toEqual({ verified: 1, platform: 'windows' });
    // 隔天再来一条未验证、平台改成 android：installs 不被改写。
    expect((await ping(env, { installId: inst.installId, platform: 'android' }, { now: NOW + DAY })).status).toBe(204);
    expect(installRow(env, inst.installId)).toMatchObject({ verified: 1, platform: 'windows' });
  });
});

describe('地区与界面语言（迁移 0017）', () => {
  const geo = (env, id) => env.DB.raw.prepare('SELECT country, locale FROM installs WHERE install_id = ?').get(id);
  const dayGeo = (env, id) => env.DB.raw
    .prepare('SELECT day, country, locale FROM install_days WHERE install_id = ? ORDER BY day').all(id);

  it('normalizeLocale：规范大小写与分隔符，没带 → null', () => {
    expect(normalizeLocale(undefined)).toBeNull();
    expect(normalizeLocale(null)).toBeNull();
    expect(normalizeLocale('zh_cn')).toBe('zh-CN');
    expect(normalizeLocale('ZH-hant-tw')).toBe('zh-Hant-TW');
    expect(normalizeLocale('pt-BR')).toBe('pt-BR');
    expect(normalizeLocale('ja')).toBe('ja');
    expect(() => normalizeLocale('a')).toThrow();
    expect(() => normalizeLocale('zh-CN-x-private-extra')).toThrow();
  });

  it('cf.country 与 locale 落进 installs 与 install_days；只存两位码', async () => {
    const env = makeEnv();
    const inst = await makeInstall();
    const r = await signedPing(env, inst, { locale: 'zh_cn' }, {
      ip: '203.0.113.9', cf: { country: 'JP', city: 'Tokyo', latitude: '35.6', asn: 2516 },
    });
    expect(r.status).toBe(204);
    expect(geo(env, inst.installId)).toEqual({ country: 'JP', locale: 'zh-CN' });
    expect(dayGeo(env, inst.installId)).toEqual([{ day: '2026-10-17', country: 'JP', locale: 'zh-CN' }]);
    const dump = JSON.stringify([
      env.DB.raw.prepare('SELECT * FROM installs').all(),
      env.DB.raw.prepare('SELECT * FROM install_days').all(),
    ]);
    for (const leak of ['203.0.113.9', 'Tokyo', '35.6', '2516']) expect(dump).not.toContain(leak);
  });

  it('这次没有 cf / 没带 locale：installs 保留上次的值，install_days 当天记 NULL', async () => {
    const env = makeEnv();
    const inst = await makeInstall();
    await signedPing(env, inst, { locale: 'ja' }, { cf: { country: 'JP' } });
    await signedPing(env, inst, {}, { now: NOW + DAY });
    expect(geo(env, inst.installId)).toEqual({ country: 'JP', locale: 'ja' });
    expect(dayGeo(env, inst.installId)).toEqual([
      { day: '2026-10-17', country: 'JP', locale: 'ja' },
      { day: '2026-10-18', country: null, locale: null },
    ]);
    // 换了地方 / 语言就跟着更新。
    await signedPing(env, inst, { locale: 'en' }, { now: NOW + 2 * DAY, cf: { country: 'US' } });
    expect(geo(env, inst.installId)).toEqual({ country: 'US', locale: 'en' });
  });

  it('cf.country 不是两位大写码 → 当作没有', async () => {
    const env = makeEnv();
    await ping(env, {}, { cf: { country: 'japan' } });
    expect(geo(env, A).country).toBeNull();
    await ping(env, { installId: B }, { cf: { country: 'T1' } });
    expect(geo(env, B).country).toBe('T1');
  });

  it('统计按近 30 天活跃的已验证安装分组；未记录的归 null', async () => {
    const env = makeEnv();
    seedPing(env, seedId(), { locale: 'zh-CN', country: 'CN' });
    seedPing(env, seedId(), { locale: 'zh-CN', country: 'CN' });
    seedPing(env, seedId(), { locale: 'ja', country: 'JP' });
    seedPing(env, seedId());
    seedPing(env, seedId(), { locale: 'en', country: 'US', at: NOW - 40 * DAY });
    // 未验证的照常走真心跳路径（不需要 PoW），也不进分布。
    await ping(env, { locale: 'ko' }, { cf: { country: 'KR' } });
    const st = await installStats(env, NOW);
    expect(st.countries).toEqual([{ key: 'CN', n: 2 }, { key: null, n: 1 }, { key: 'JP', n: 1 }]);
    expect(st.locales).toEqual([{ key: 'zh-CN', n: 2 }, { key: null, n: 1 }, { key: 'ja', n: 1 }]);

    const page = await devPage(env, '/dev/stats');
    expect(page.data).toContain('国家 / 地区');
    expect(page.data).toContain('（CN）');
    expect(page.data).toContain('界面语言');
    expect(page.data).toContain('（zh-CN）');
    expect(page.data).not.toContain('（KR）');
  });

  it('标签：特殊码与 null 有中文说明，不认识的码原样显示', () => {
    expect(countryLabel(null)).toBe('未记录');
    expect(countryLabel('T1')).toContain('Tor');
    expect(countryLabel('XX')).toContain('XX');
    expect(countryLabel('JP')).toContain('（JP）');
    expect(localeLabel(null)).toContain('未上报');
    expect(localeLabel('ja')).toContain('（ja）');
  });
});

describe('设备维度：架构 / 系统大版本 / 安装来源（迁移 0017）', () => {
  const dims = (env, id) => env.DB.raw
    .prepare('SELECT arch, os_version, source FROM installs WHERE install_id = ?').get(id);

  it('落进 installs 与 install_days；没带时 installs 保留上次的值；不认识的取值照收', async () => {
    const env = makeEnv();
    const inst = await makeInstall();
    await signedPing(env, inst, { platform: 'android', arch: 'arm64', osVersion: '34', source: 'self_update' });
    expect(dims(env, inst.installId)).toEqual({ arch: 'arm64', os_version: '34', source: 'self_update' });
    expect(env.DB.raw.prepare('SELECT arch, os_version, source FROM install_days').get())
      .toEqual({ arch: 'arm64', os_version: '34', source: 'self_update' });
    await signedPing(env, inst, { platform: 'android' }, { now: NOW + DAY });
    expect(dims(env, inst.installId)).toEqual({ arch: 'arm64', os_version: '34', source: 'self_update' });
    await signedPing(env, inst, { platform: 'android', arch: 'riscv64', osVersion: '37', source: 'some_store' }, {
      now: NOW + 2 * DAY,
    });
    expect(dims(env, inst.installId)).toEqual({ arch: 'riscv64', os_version: '37', source: 'some_store' });
  });

  it('统计按平台 × 取值分组', async () => {
    const env = makeEnv();
    seedPing(env, seedId(), { platform: 'android', arch: 'arm64', osVersion: '34', source: 'manual' });
    seedPing(env, seedId(), { platform: 'android', arch: 'arm64', osVersion: '35', source: 'manual' });
    seedPing(env, seedId(), { platform: 'windows', arch: 'x64', osVersion: '11', source: 'installer' });
    seedPing(env, seedId(), { platform: 'windows' });
    const st = await installStats(env, NOW);
    expect(st.archs).toEqual([
      { platform: 'android', value: 'arm64', n: 2 },
      { platform: 'windows', value: null, n: 1 },
      { platform: 'windows', value: 'x64', n: 1 },
    ]);
    expect(st.sources).toContainEqual({ platform: 'android', value: 'manual', n: 2 });
    expect(st.osVersions).toContainEqual({ platform: 'android', value: '35', n: 1 });

    const page = await devPage(env, '/dev/stats');
    for (const text of ['CPU 架构', '系统版本', '安装来源', 'Android 14（API 34）', 'Windows 11', 'Windows · 安装包']) {
      expect(page.data).toContain(text);
    }
  });

  it('标签', () => {
    expect(osVersionLabel('android', '34')).toBe('Android 14（API 34）');
    expect(osVersionLabel('android', '99')).toBe('Android API 99');
    expect(osVersionLabel('macos', '15')).toBe('macOS 15');
    expect(osVersionLabel('windows', null)).toBe('Windows · 未上报');
    expect(sourceLabel('android', 'play')).toBe('Android · Google Play');
    expect(sourceLabel('android', 'new_store')).toBe('Android · new_store');
    expect(archLabel('linux', null)).toBe('Linux · 未上报');
  });
});

describe('留存 / 版本升级进度 / 分国家趋势', () => {
  it('留存：按首次心跳日分组，窗口没走完给 null，起始日标 seeded', async () => {
    const env = makeEnv();
    const T0 = NOW - 40 * DAY; // 2026-09-07
    // 起始日两个安装（存量）；一个第 1 天回来、一个第 30 天回来。
    const [a, b] = [seedId(), seedId()];
    seedPing(env, a, { at: T0 });
    seedPing(env, b, { at: T0 });
    seedPing(env, a, { at: T0 + DAY });
    seedPing(env, b, { at: T0 + 35 * DAY });
    // 10 天前新增三个：一个第 1 天回来，一个第 8 天回来，一个再没回来。
    const T1 = NOW - 10 * DAY;
    const [c, d, e] = [seedId(), seedId(), seedId()];
    for (const x of [c, d, e]) seedPing(env, x, { at: T1 });
    seedPing(env, c, { at: T1 + DAY });
    seedPing(env, d, { at: T1 + 8 * DAY });
    // 未验证的回访不算留存。
    seedPing(env, e, { at: T1 + DAY, verified: 0 });

    const rows = await retentionCohorts(env, NOW);
    expect(rows).toEqual([
      { day: utcDay(T1), n: 3, seeded: false, d1: 1, d7: null, d30: null },
      { day: utcDay(T0), n: 2, seeded: true, d1: 1, d7: 0, d30: null },
    ]);
    // 第 7–13 天窗口已过完 → 给数字。
    expect((await retentionCohorts(env, T1 + 14 * DAY))[0]).toMatchObject({ d1: 1, d7: 1, d30: null });
  });

  it('版本升级进度：同轨道 7 日活跃里装到该版本或更新的比例', async () => {
    const env = makeEnv();
    const [old, mid, up, dbg] = [seedId(), seedId(), seedId(), seedId()];
    seedPing(env, old, { version: '2.10.0', at: NOW - 5 * DAY });
    seedPing(env, mid, { version: '2.10.0', at: NOW - 5 * DAY });
    seedPing(env, mid, { version: '2.11.0', at: NOW - 2 * DAY });
    seedPing(env, up, { version: '2.12.0+300' });
    seedPing(env, dbg, { version: '2.12.0-debug.4', channel: 'debug' });
    // 已经 8 天没出现的安装不进分母。
    seedPing(env, seedId(), { version: '2.9.0', at: NOW - 8 * DAY });
    const rows = await versionAdoption(env, NOW);
    const by = Object.fromEntries(rows.map((r) => [r.version, r]));
    expect(by['2.11.0']).toMatchObject({ track: '', peers: 3, reached: 2, exact: 1, firstDay: utcDay(NOW - 2 * DAY) });
    expect(by['2.10.0']).toMatchObject({ peers: 3, reached: 3, exact: 1 });
    expect(by['2.12.0-debug.4']).toMatchObject({ track: 'debug', peers: 1, reached: 1, exact: 1 });
    expect(rows[0].firstDay >= rows[rows.length - 1].firstDay).toBe(true);
  });

  it('分国家日活趋势：前几个国家逐日计数，其余并进 other', async () => {
    const env = makeEnv();
    for (let i = 0; i < 3; i += 1) seedPing(env, seedId(), { country: 'CN' });
    seedPing(env, seedId(), { country: 'JP' });
    seedPing(env, seedId(), { at: NOW - DAY, country: 'JP' });
    // 再来 8 个各 1 人的国家：前 8 = CN、JP + 按码排序的前 6 个，TW / US 并进 other；未验证的不算。
    for (const c of ['US', 'TW', 'SG', 'KR', 'HK', 'FR', 'DE', 'BR']) seedPing(env, seedId(), { country: c });
    seedPing(env, seedId(), { country: 'XX', verified: 0 });
    const st = await installStats(env, NOW);
    expect(st.countryTrend.countries).toEqual(['CN', 'JP', 'BR', 'DE', 'FR', 'HK', 'KR', 'SG']);
    expect(st.countryTrend.days[0]).toEqual({ day: '2026-10-17', counts: [3, 1, 1, 1, 1, 1, 1, 1], other: 2 });
    expect(st.countryTrend.days[1]).toEqual({ day: '2026-10-16', counts: [0, 1, 0, 0, 0, 0, 0, 0], other: 0 });

    const page = await devPage(env, '/dev/stats');
    for (const text of ['分国家日活趋势', '留存', '版本升级进度']) expect(page.data).toContain(text);
  });
});

describe('固定安装池', () => {
  it('每条都按当前 INSTALL_POW_BITS 有效、指纹 id 对得上、互不相同（调高难度后重跑 gen_install_pool.mjs）', async () => {
    expect(POOL.powBits).toBe(INSTALL_POW_BITS);
    const ids = new Set();
    for (let i = 0; i < POOL.installs.length; i += 1) {
      const inst = await makeInstall();
      expect(await installIdFromSpki(inst.key.spki)).toBe(inst.installId);
      expect(await installPowValid(inst.installId, inst.pow)).toBe(true);
      ids.add(inst.installId);
    }
    expect(ids.size).toBe(POOL.installs.length);
  });
});

describe('跨语言安装向量（Dart 客户端生成）', () => {
  const DIR = fileURLToPath(new URL('./vectors_install/', import.meta.url));
  const files = readdirSync(DIR).filter((f) => f.endsWith('.json'));
  it('至少有一条向量', () => expect(files.length).toBeGreaterThan(0));
  for (const f of files) {
    it(f, async () => {
      const v = JSON.parse(readFileSync(DIR + f, 'utf8'));
      const spki = b64urlDecode(v.pubkey);
      expect(await installIdFromSpki(spki)).toBe(v.installId);
      expect(await installPowValid(v.installId, v.powNonce)).toBe(true);
      const env = makeEnv();
      // 把 Dart 签好的请求原样送进 Worker：签名时刻落在 ±5 分钟内即被收为已验证。
      const r = await call(env, 'POST', v.path, {
        body: new TextEncoder().encode(v.body),
        headers: {
          'CF-Connecting-IP': nextIp(),
          [INSTALL_HEADERS.key]: v.pubkey,
          [INSTALL_HEADERS.time]: String(v.time),
          [INSTALL_HEADERS.sig]: v.signature,
          [INSTALL_HEADERS.pow]: v.powNonce,
        },
        now: v.time,
      });
      expect(r.status).toBe(204);
      expect(installRow(env, v.installId).verified).toBe(1);
      expect(new URL(BASE + v.path).pathname).toBe('/v1/ping');
    });
  }
});

describe('统计', () => {
  it('日活 / 周活 / 月活 / 分布只数已验证安装，未验证另列', async () => {
    const env = makeEnv();
    const a = await makeInstall();
    const b = await makeInstall();
    const c = await makeInstall();
    await signedPing(env, a, {}, { now: NOW - 20 * DAY });
    await signedPing(env, a, { version: '2.11.0' }, { now: NOW });
    await signedPing(env, b, { platform: 'android', channel: 'debug', version: '2.11.0-debug.9' }, { now: NOW - 3 * DAY });
    await signedPing(env, c, { platform: 'linux' }, { now: NOW - 40 * DAY });
    // 未验证：今天一条、10 天前一条（不同 id），都不进主数字与分布。
    await ping(env, { installId: A, platform: 'macos' }, { now: NOW });
    await ping(env, { installId: B, platform: 'macos' }, { now: NOW - 10 * DAY });
    const st = await installStats(env, NOW);
    expect(st).toMatchObject({ today: '2026-10-17', dau: 1, wau: 2, mau: 2, total: 3 });
    expect(st.unverified).toEqual({ dau: 1, wau: 1, mau: 2, total: 2 });
    expect(st.daily[0]).toMatchObject({
      day: '2026-10-17', n: 1, unverified: 1, fresh: 0, platforms: { windows: 1, android: 0, macos: 0 },
    });
    expect(st.daily.find((d) => d.day === '2026-10-14')).toMatchObject({ n: 1, fresh: 1, platforms: { android: 1 } });
    expect(st.platforms).toEqual([{ key: 'android', n: 1 }, { key: 'windows', n: 1 }]);
    expect(st.channels).toEqual([{ key: 'debug', n: 1 }, { key: 'stable', n: 1 }]);
    expect(st.versions.map((v) => v.key).sort()).toEqual(['2.11.0', '2.11.0-debug.9']);
  });

  it('定时任务清掉超出保留期的记录', async () => {
    const env = makeEnv();
    const old = NOW - (INSTALL_LIMITS.retentionDays + 2) * DAY;
    await ping(env, { installId: A }, { now: old });
    await ping(env, { installId: B }, { now: NOW });
    await worker.scheduled({}, env, { waitUntil() {} }, NOW);
    expect(env.DB.raw.prepare('SELECT install_id FROM installs').all()).toEqual([{ install_id: B }]);
    expect(count(env, 'install_days')).toBe(1);
  });

  it('/dev/stats 需要开发者会话并显示数字与未验证计数', async () => {
    const env = makeEnv();
    await signedPing(env, await makeInstall());
    await ping(env);
    expect((await call(env, 'GET', '/dev/stats', { now: NOW })).status).toBe(303);
    const page = await devPage(env, '/dev/stats');
    expect(page.status).toBe(200);
    expect(page.data).toContain('安装统计');
    expect(page.data).toContain('2026-10-17');
    expect(page.data).toContain('未验证：今日 1');
  });
});

describe('反馈关联安装', () => {
  async function submit(env, installId, extraHeaders = {}) {
    const r = await call(env, 'POST', '/v1/feedback', {
      body: { category: 'bug', title: `白屏 ${Math.random()}`, body: '正文', installId },
      headers: { 'CF-Connecting-IP': nextIp(), ...extraHeaders },
      now: NOW,
    });
    return r;
  }
  async function submitSigned(env, inst, override = {}) {
    const bytes = new TextEncoder().encode(JSON.stringify({
      category: 'bug', title: `白屏 ${Math.random()}`, body: '正文', installId: inst.installId,
    }));
    const headers = await proofHeaders(inst, 'POST', '/v1/feedback', bytes, NOW, override);
    return call(env, 'POST', '/v1/feedback', {
      body: bytes, headers: { 'CF-Connecting-IP': nextIp(), ...headers }, now: NOW,
    });
  }
  const installCols = (env, id) =>
    env.DB.raw.prepare('SELECT install_id, install_verified FROM feedback WHERE id = ?').get(id);

  it('合法 installId 落库（未验证）；不合法或没带当 null，提交照常成功', async () => {
    const env = makeEnv();
    expect(installCols(env, (await submit(env, A)).data.id)).toEqual({ install_id: A, install_verified: 0 });
    expect(installCols(env, (await submit(env, 'not-a-uuid')).data.id)).toEqual({ install_id: null, install_verified: 0 });
    expect(installCols(env, (await submit(env, undefined)).data.id)).toEqual({ install_id: null, install_verified: 0 });
  });

  it('带安装证明的反馈记 install_verified = 1；证明验不过不拒收反馈，只丢掉不可信的 installId', async () => {
    const env = makeEnv();
    const inst = await makeInstall();
    const ok = await submitSigned(env, inst);
    expect(ok.status).toBe(201);
    expect(installCols(env, ok.data.id)).toEqual({ install_id: inst.installId, install_verified: 1 });
    const other = await makeInstall();
    let weakPow = 0;
    while (await installPowValid(inst.installId, String(weakPow))) weakPow += 1;
    for (const override of [
      { [INSTALL_HEADERS.key]: other.key.pubkey }, // id ≠ 指纹
      { [INSTALL_HEADERS.pow]: String(weakPow) }, // 难度调高后老客户端的 nonce 不够
      { [INSTALL_HEADERS.sig]: b64urlEncode(new Uint8Array(64)) }, // 签名错
      { [INSTALL_HEADERS.time]: String(NOW - 10 * 60 * 1000) }, // 过期
    ]) {
      const r = await submitSigned(env, inst, override);
      expect(r.status).toBe(201);
      expect(installCols(env, r.data.id)).toEqual({ install_id: null, install_verified: 0 });
    }
    expect(count(env, 'feedback')).toBe(5);
  });

  it('反馈的签名请求重放：反馈照收，installId 不记', async () => {
    const env = makeEnv();
    const inst = await makeInstall();
    const bytes = new TextEncoder().encode(JSON.stringify({
      category: 'bug', title: '重放', body: '正文', installId: inst.installId,
    }));
    const headers = await proofHeaders(inst, 'POST', '/v1/feedback', bytes, NOW);
    const send = () => call(env, 'POST', '/v1/feedback', {
      body: bytes, headers: { 'CF-Connecting-IP': nextIp(), ...headers }, now: NOW,
    });
    const first = await send();
    expect(installCols(env, first.data.id)).toEqual({ install_id: inst.installId, install_verified: 1 });
    const second = await send();
    expect(second.status).toBe(201);
    expect(installCols(env, second.data.id)).toEqual({ install_id: null, install_verified: 0 });
  });

  it('已验证安装的轨迹只取已验证心跳日与反馈；未验证反馈冒用其 id 看不到轨迹', async () => {
    const env = makeEnv();
    const inst = await makeInstall();
    await signedPing(env, inst, { version: '2.10.0-debug.5', channel: 'debug' }, { now: NOW - 2 * DAY });
    // 知道 id 的人在别的日子塞未验证心跳、提交未验证反馈。
    await ping(env, { installId: inst.installId, version: '6.6.6' }, { now: NOW - DAY });
    const junk = (await submit(env, inst.installId)).data;
    const real = (await submitSigned(env, inst)).data;
    const page = await devPage(env, `/dev/f/${real.id}`);
    expect(page.status).toBe(200);
    expect(page.data).toContain('2.10.0-debug.5');
    expect(page.data).not.toContain('6.6.6');
    expect(page.data).not.toContain(`/dev/f/${junk.id}`);
    const junkPage = await devPage(env, `/dev/f/${junk.id}`);
    expect(junkPage.data).toContain('未验证');
    expect(junkPage.data).toContain('不展示该安装的轨迹');
    expect(junkPage.data).not.toContain('2.10.0-debug.5');
    expect(junkPage.data).not.toContain(`/dev/f/${real.id}`);
  });

  it('处理台详情显示版本轨迹、同一安装的其它反馈、修复是否装上与验证状态', async () => {
    const env = makeEnv({ FEEDBACK_CI_TOKEN: 'ci-token-0123456789abcdef' });
    const inst = await makeInstall();
    await signedPing(env, inst, { version: '2.10.0-debug.5', channel: 'debug' }, { now: NOW - 2 * DAY });
    await signedPing(env, inst, { version: '2.10.0-debug.8', channel: 'debug', locale: 'ja' }, {
      now: NOW, cf: { country: 'JP' },
    });
    const first = (await submitSigned(env, inst)).data;
    const second = (await submitSigned(env, inst)).data;
    const ci = { Authorization: 'Bearer ci-token-0123456789abcdef' };
    await call(env, 'POST', '/v1/ci/feedback/fixed', { body: { sha: 'a'.repeat(40), ids: [second.id], scope: 'app' }, headers: ci, now: NOW });
    await call(env, 'POST', '/v1/ci/feedback/released', {
      body: { channel: 'debug', platform: 'windows', version: '2.10.0-debug.7', ids: [{ id: second.id, sha: 'a'.repeat(40) }] },
      headers: ci,
      now: NOW,
    });
    const page = await devPage(env, `/dev/f/${second.id}`);
    expect(page.status).toBe(200);
    expect(page.data).toContain(inst.installId);
    expect(page.data).toContain('2.10.0-debug.5');
    expect(page.data).toContain(`/dev/f/${first.id}`);
    expect(page.data).toContain('已装上修复');
    expect(page.data).toContain('地区 / 界面语言');
    expect(page.data).toContain('（JP）');
    expect(page.data).toContain('已验证');

    const unverified = (await submit(env, A)).data;
    const page2 = await devPage(env, `/dev/f/${unverified.id}`);
    expect(page2.data).toContain('未验证');
    expect(page2.data).toContain('可伪造');
  });
});

describe('versionIncludes', () => {
  it.each([
    ['2.10.0', '2.10.0', true],
    ['2.10.0+123', '2.10.0', true],
    ['2.11.0', '2.10.0', true],
    ['2.9.9', '2.10.0', false],
    ['2.10.0-debug.8', '2.10.0-debug.7', true],
    ['2.10.0-debug.6', '2.10.0-debug.7', false],
    ['2.10.0-beta.9', '2.10.0-debug.7', null],
    ['2.10.0', '2.10.0-debug.7', null],
    ['', '2.10.0', null],
  ])('%s 包含 %s → %s', (installed, release, want) => {
    expect(versionIncludes(installed, release)).toBe(want);
  });
});
