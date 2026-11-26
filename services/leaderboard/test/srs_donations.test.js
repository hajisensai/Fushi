// SRS 复习历史捐赠（src/srs_donations.js，迁移 0027）：上传 / 覆盖 / 查询 / 撤回、限流与配额、批次下载、公开统计。
import { describe, expect, it } from 'vitest';
import { call, makeEnv, nextIp } from './harness.js';
import { SRS_DONATION_LIMITS, donationKey, donorKeyHash } from '../src/srs_donations.js';
import { poolQuota } from '../src/budget.js';

const NOW = Date.UTC(2026, 10, 26, 12);
const HOUR = 3600 * 1000;
const DAY = 24 * HOUR;
const basic = { Authorization: `Basic ${btoa('admin:pw')}` };

/** 第 n 个捐赠者：donorId 32 位 hex、donorKey 64 位 hex。 */
function donor(n) {
  const h = n.toString(16).padStart(8, '0');
  return { id: `${h}${'a'.repeat(24)}`, key: `${h}${'b'.repeat(56)}` };
}

/** zip 魔数开头的假 apkg。 */
function apkg(n = 64, fill = 7) {
  const b = new Uint8Array(n).fill(fill);
  b.set([0x50, 0x4b, 0x03, 0x04], 0);
  return b;
}

function put(env, d, bytes, opts = {}) {
  const headers = {
    Authorization: `Bearer ${opts.key ?? d.key}`,
    'Content-Type': 'application/octet-stream',
    'CF-Connecting-IP': opts.ip ?? nextIp(),
    'x-donation-reviews': ('reviews' in opts ? opts.reviews : '1234'),
    'x-donation-cards': ('cards' in opts ? opts.cards : '200'),
    'x-donation-app-version': ('version' in opts ? opts.version : '1.2.3+45'),
  };
  const length = opts.length === undefined ? bytes.length : opts.length;
  if (length !== null) headers['Content-Length'] = String(length);
  for (const [k, v] of Object.entries(headers)) if (v === null) delete headers[k];
  return call(env, 'PUT', `/v1/srs-donations/${opts.id ?? d.id}`, { body: bytes, headers, now: opts.now ?? NOW, ctx: opts.ctx });
}

function withKey(env, method, d, opts = {}) {
  return call(env, method, `/v1/srs-donations/${d.id}`, {
    headers: { Authorization: `Bearer ${opts.key ?? d.key}` },
    now: opts.now ?? NOW,
  });
}

/** 捐赠专用配额池（budget.js 'donation'，迁移 0027）；视频池 / 普通池不该被捐赠动到。 */
const donationBytes = (env) => env.DB.raw.prepare('SELECT donation_bytes FROM media_usage').get().donation_bytes;
const otherPools = (env) => env.DB.raw.prepare('SELECT bytes, video_bytes FROM media_usage').get();
const row = (env, id) => env.DB.raw.prepare('SELECT * FROM srs_donations WHERE donor_id = ?').get(id);
const withdrawal = (env, id) => env.DB.raw.prepare('SELECT * FROM srs_donation_withdrawals WHERE donor_id = ?').get(id);

async function batch(env, now = NOW) {
  const r = await call(env, 'POST', '/v1/admin/srs-donations/batch', { headers: basic, now });
  expect(r.status).toBe(200);
  return r.data;
}

/** 批次链接 → 站内路径。 */
const pathOf = (url) => new URL(url).pathname;

describe('上传', () => {
  it('成功：流式写 R2、记行（只存 key 的哈希）、占捐赠池（不碰视频 / 普通池）、返回 updatedAt', async () => {
    const env = makeEnv();
    const d = donor(1);
    const bytes = apkg(100);
    const r = await put(env, d, bytes);
    expect(r.status).toBe(200);
    expect(r.data).toEqual({ donated: true, updatedAt: NOW });
    expect(env.MEDIA.lastPutWasStream).toBe(true);
    expect(env.MEDIA.store.get(donationKey(d.id)).bytes).toEqual(bytes);
    const rec = row(env, d.id);
    expect(rec).toMatchObject({ bytes: 100, reviews: 1234, cards: 200, app_version: '1.2.3+45', created_at: NOW, updated_at: NOW });
    expect(rec.key_hash).toBe(await donorKeyHash(d.key));
    expect(rec.key_hash).not.toContain(d.key);
    expect(donationBytes(env)).toBe(100);
    expect(otherPools(env)).toEqual({ bytes: 0, video_bytes: 0 });
  });

  it('Bearer key 大小写不敏感', async () => {
    const env = makeEnv();
    const d = { id: donor(2).id, key: 'AB'.repeat(32) };
    expect((await put(env, d, apkg())).status).toBe(200);
    expect((await withKey(env, 'GET', d, { key: 'ab'.repeat(32) })).data.donated).toBe(true);
  });

  it('校验：donorId / key / 长度 / 魔数 / 计数头', async () => {
    const env = makeEnv();
    const d = donor(3);
    expect((await put(env, d, apkg(), { id: 'A'.repeat(32) })).data.error).toBe('bad_donor_id');
    expect((await put(env, d, apkg(), { id: 'a'.repeat(31) })).data.error).toBe('bad_donor_id');
    expect((await put(env, d, apkg(), { key: 'z'.repeat(64) })).status).toBe(401);
    expect((await put(env, d, apkg(), { key: 'a'.repeat(63) })).data.error).toBe('bad_donor_key');
    expect((await put(env, d, apkg(), { length: null })).status).toBe(411);
    const big = await put(env, d, apkg(8), { length: SRS_DONATION_LIMITS.maxBytes + 1 });
    expect(big.status).toBe(413);
    const notZip = await put(env, d, new Uint8Array(64).fill(1));
    expect(notZip.status).toBe(415);
    expect(notZip.data.error).toBe('not_a_zip');
    expect((await put(env, d, apkg(), { reviews: '-1' })).data.error).toBe('bad_reviews');
    expect((await put(env, d, apkg(), { cards: null })).data.error).toBe('bad_cards');
    expect((await put(env, d, apkg(), { version: 'a b' })).data.error).toBe('bad_app_version');
    expect(row(env, d.id)).toBeUndefined();
    expect(env.MEDIA.store.size).toBe(0);
    expect(donationBytes(env)).toBe(0);
  });

  it('实际长度与声明不符：400 bad_length，归还配额，旧文件仍在', async () => {
    const env = makeEnv();
    const d = donor(4);
    const first = apkg(50, 1);
    expect((await put(env, d, first)).status).toBe(200);
    const bad = await put(env, d, apkg(40, 2), { length: 60 });
    expect(bad.status).toBe(400);
    expect(bad.data.error).toBe('bad_length');
    expect(env.MEDIA.store.get(donationKey(d.id)).bytes).toEqual(first);
    expect(donationBytes(env)).toBe(50);
    expect(row(env, d.id).bytes).toBe(50);
  });

  it('同一 donorId 重传覆盖：行与文件换新、配额按新大小、created_at 不变', async () => {
    const env = makeEnv();
    const d = donor(5);
    expect((await put(env, d, apkg(80, 1))).status).toBe(200);
    const r = await put(env, d, apkg(30, 2), { now: NOW + 10, reviews: '2000', cards: '300' });
    expect(r.data).toEqual({ donated: true, updatedAt: NOW + 10 });
    expect(env.MEDIA.store.get(donationKey(d.id)).bytes).toEqual(apkg(30, 2));
    expect(row(env, d.id)).toMatchObject({ bytes: 30, reviews: 2000, cards: 300, created_at: NOW, updated_at: NOW + 10 });
    expect(donationBytes(env)).toBe(30);
  });

  it('已有记录时换 key：403 donor_key_mismatch，不碰文件', async () => {
    const env = makeEnv();
    const d = donor(6);
    expect((await put(env, d, apkg(20, 1))).status).toBe(200);
    const other = { id: d.id, key: donor(99).key };
    const r = await put(env, other, apkg(20, 9));
    expect(r.status).toBe(403);
    expect(r.data.error).toBe('donor_key_mismatch');
    expect(env.MEDIA.store.get(donationKey(d.id)).bytes).toEqual(apkg(20, 1));
    expect((await withKey(env, 'GET', other)).status).toBe(403);
    expect((await withKey(env, 'DELETE', other)).status).toBe(403);
    expect(row(env, d.id)).toBeTruthy();
  });

  it('每 donorId 每小时 2 次', async () => {
    const env = makeEnv();
    const d = donor(7);
    expect((await put(env, d, apkg())).status).toBe(200);
    expect((await put(env, d, apkg())).status).toBe(200);
    const third = await put(env, d, apkg());
    expect(third.status).toBe(429);
    expect(third.data.error).toBe('rate_limited');
    expect((await put(env, d, apkg(), { now: NOW + HOUR })).status).toBe(200);
  });

  it('每 IP 每日字节额度：超了 429 upload_quota_daily', async () => {
    const env = makeEnv();
    const ip = '203.0.113.9';
    const half = SRS_DONATION_LIMITS.bytesPerIpDay / 2;
    // 只声明长度、不给够字节：额度按声明长度扣（传失败不退），不必真造 64 MiB。
    expect((await put(env, donor(8), apkg(8), { ip, length: half })).status).toBe(400);
    expect((await put(env, donor(9), apkg(8), { ip, length: half })).status).toBe(400);
    const r = await put(env, donor(10), apkg(8), { ip });
    expect(r.status).toBe(429);
    expect(r.data.error).toBe('upload_quota_daily');
    expect((await put(env, donor(10), apkg(8), { ip, now: NOW + DAY })).status).toBe(200);
    expect(donationBytes(env)).toBe(8);
  });

  it('捐赠池满了 507 donation_quota；视频池满了不挡捐赠', async () => {
    const env = makeEnv({ MEDIA_QUOTA_BYTES: '1000', DONATION_QUOTA_BYTES: '100' });
    env.DB.raw.prepare('UPDATE media_usage SET video_bytes = ?').run(poolQuota(env, 'video'));
    expect((await put(env, donor(11), apkg(60))).status).toBe(200);
    const r = await put(env, donor(12), apkg(60));
    expect(r.status).toBe(507);
    expect(r.data.error).toBe('donation_quota');
    expect(env.MEDIA.store.has(donationKey(donor(12).id))).toBe(false);
    expect(donationBytes(env)).toBe(60);
  });

  it('池接近满时重传：只预占多出的字节（不按新旧两份算），变小归还差额', async () => {
    const env = makeEnv({ MEDIA_QUOTA_BYTES: '1000', DONATION_QUOTA_BYTES: '100' });
    const d = donor(13);
    expect((await put(env, d, apkg(70, 1))).status).toBe(200);
    // 新旧合计 150 > 100，但净增 10：照收。
    expect((await put(env, d, apkg(80, 2))).status).toBe(200);
    expect(donationBytes(env)).toBe(80);
    expect(env.MEDIA.store.get(donationKey(d.id)).bytes).toEqual(apkg(80, 2));
    // 净增超出：507，旧文件与计数原样。
    const big = await put(env, d, apkg(130, 3), { now: NOW + HOUR });
    expect(big.status).toBe(507);
    expect(big.data.error).toBe('donation_quota');
    expect(env.MEDIA.store.get(donationKey(d.id)).bytes).toEqual(apkg(80, 2));
    expect(donationBytes(env)).toBe(80);
    // 变小：归还差额。
    expect((await put(env, d, apkg(20, 4), { now: NOW + HOUR })).status).toBe(200);
    expect(donationBytes(env)).toBe(20);
    expect(row(env, d.id).bytes).toBe(20);
  });

  it('重传长度不符失败：只退本次多占的，池里仍是旧文件大小', async () => {
    const env = makeEnv();
    const d = donor(14);
    expect((await put(env, d, apkg(50, 1))).status).toBe(200);
    expect((await put(env, d, apkg(40, 2), { length: 90 })).status).toBe(400);
    expect(donationBytes(env)).toBe(50);
  });
});

describe('查询与撤回', () => {
  it('GET：无记录 {donated:false}，有记录给统计', async () => {
    const env = makeEnv();
    const d = donor(20);
    expect((await withKey(env, 'GET', d)).data).toEqual({ donated: false });
    await put(env, d, apkg(), { reviews: '5000', cards: '700' });
    const r = await withKey(env, 'GET', d);
    expect(r.status).toBe(200);
    expect(r.data).toEqual({ donated: true, reviews: 5000, cards: 700, updatedAt: NOW });
    expect(r.res.headers.get('Cache-Control')).toBe('no-store');
    expect((await call(env, 'GET', `/v1/srs-donations/${d.id}`, { now: NOW })).status).toBe(401);
  });

  it('DELETE：删 R2 与行、归还配额、写撤回记录；无记录幂等且不写撤回', async () => {
    const env = makeEnv();
    const d = donor(21);
    expect((await withKey(env, 'DELETE', d)).data).toEqual({ donated: false });
    expect(withdrawal(env, d.id)).toBeUndefined();
    await put(env, d, apkg(70));
    const r = await withKey(env, 'DELETE', d, { now: NOW + 5 });
    expect(r.status).toBe(200);
    expect(r.data).toEqual({ donated: false });
    expect(env.MEDIA.store.has(donationKey(d.id))).toBe(false);
    expect(row(env, d.id)).toBeUndefined();
    expect(donationBytes(env)).toBe(0);
    expect(withdrawal(env, d.id)).toMatchObject({ withdrawn_at: NOW + 5, reported_batch: null });
    expect((await withKey(env, 'DELETE', d)).status).toBe(200);
  });

  it('撤回后重新捐赠：未报告的撤回删掉；已报告的保留', async () => {
    const env = makeEnv();
    const a = donor(22);
    const b = donor(23);
    await put(env, a, apkg());
    await put(env, b, apkg());
    await withKey(env, 'DELETE', a);
    await withKey(env, 'DELETE', b);
    const bt = await batch(env); // 两条撤回都在这一批里报告
    expect(withdrawal(env, a.id).reported_batch).toBe(bt.token);
    await put(env, a, apkg(), { now: NOW + 2 * HOUR });
    expect(withdrawal(env, a.id)).toMatchObject({ reported_batch: bt.token });
    // 再撤一次：重新变成未报告，进下一批。
    await withKey(env, 'DELETE', a, { now: NOW + 3 * HOUR });
    expect(withdrawal(env, a.id)).toMatchObject({ withdrawn_at: NOW + 3 * HOUR, reported_batch: null });
    // 未报告状态下重新捐赠 → 撤回记录删掉。
    await put(env, a, apkg(), { now: NOW + 4 * HOUR });
    expect(withdrawal(env, a.id)).toBeUndefined();
    expect(withdrawal(env, b.id).reported_batch).toBe(bt.token);
  });
});

describe('批次', () => {
  it('管理接口要 Basic Auth', async () => {
    const env = makeEnv();
    expect((await call(env, 'POST', '/v1/admin/srs-donations/batch', { now: NOW })).status).toBe(401);
    expect((await call(env, 'GET', '/v1/admin/srs-donations', { now: NOW })).status).toBe(401);
    const bad = { Authorization: `Basic ${btoa('admin:nope')}` };
    expect((await call(env, 'POST', '/v1/admin/srs-donations/batch', { headers: bad, now: NOW })).status).toBe(401);
  });

  it('生成批次：清单 / 文件下载 / 撤回清单；快照后撤回的 404、快照后新捐的不在内、过期 404', async () => {
    const env = makeEnv();
    const a = donor(30);
    const b = donor(31);
    const gone = donor(32);
    await put(env, a, apkg(40, 1), { reviews: '1500' });
    await put(env, b, apkg(50, 2), { reviews: '2500' });
    await put(env, gone, apkg(10, 3));
    await withKey(env, 'DELETE', gone);

    const bt = await batch(env);
    expect(bt).toMatchObject({ donors: 2, reviews: 4000, withdrawn: 1, expiresAt: NOW + 30 * DAY });
    expect(bt.token).toMatch(/^[0-9a-f]{64}$/);
    expect(bt.url).toBe(`https://rank.example.com/d/srs-donations/${bt.token}/`);

    const late = donor(33);
    await put(env, late, apkg(), { now: NOW + 1 });

    const manifest = await call(env, 'GET', pathOf(bt.url), { now: NOW + 1 });
    expect(manifest.status).toBe(200);
    expect(manifest.res.headers.get('Cache-Control')).toBe('no-store');
    expect(manifest.data.files.map((f) => f.donorId)).toEqual([a.id, b.id]);
    expect(manifest.data.files[0]).toMatchObject({ reviews: 1500, bytes: 40, url: `${bt.url}${a.id}.apkg` });
    expect(manifest.data.withdrawn).toEqual([gone.id]);

    const file = await call(env, 'GET', pathOf(`${bt.url}${a.id}.apkg`), { now: NOW + 1 });
    expect(file.status).toBe(200);
    expect(file.res.headers.get('Content-Type')).toBe('application/octet-stream');
    expect(file.res.headers.get('Content-Disposition')).toBe(`attachment; filename="${a.id}.apkg"`);
    expect(new TextEncoder().encode(file.data)[0]).toBe(0x50);

    const txt = await call(env, 'GET', pathOf(`${bt.url}withdrawn.txt`), { now: NOW + 1 });
    expect(txt.res.headers.get('Content-Type')).toMatch(/^text\/plain/);
    expect(txt.data).toBe(`${gone.id}\n`);

    expect((await call(env, 'GET', pathOf(`${bt.url}${late.id}.apkg`), { now: NOW + 1 })).status).toBe(404);
    expect((await call(env, 'GET', pathOf(`${bt.url}${gone.id}.apkg`), { now: NOW + 1 })).status).toBe(404);

    // 快照之后撤回：文件 404，清单里也不再列。
    await withKey(env, 'DELETE', b, { now: NOW + 2 });
    expect((await call(env, 'GET', pathOf(`${bt.url}${b.id}.apkg`), { now: NOW + 3 })).status).toBe(404);
    expect((await call(env, 'GET', pathOf(bt.url), { now: NOW + 3 })).data.files.map((f) => f.donorId)).toEqual([a.id]);

    // 下一批只带尚未报告的撤回（b），gone 已报告过。
    const next = await batch(env, NOW + 4);
    expect(next).toMatchObject({ donors: 2, withdrawn: 1 });
    expect((await call(env, 'GET', pathOf(`${next.url}withdrawn.txt`), { now: NOW + 4 })).data).toBe(`${b.id}\n`);

    // 过期 / 乱写的 token。
    expect((await call(env, 'GET', pathOf(bt.url), { now: NOW + 30 * DAY })).status).toBe(404);
    expect((await call(env, 'GET', `/d/srs-donations/${'0'.repeat(64)}/`, { now: NOW })).status).toBe(404);
    expect((await call(env, 'GET', '/d/srs-donations/nope/', { now: NOW })).status).toBe(404);
  });

  it('统计接口', async () => {
    const env = makeEnv();
    await put(env, donor(40), apkg(40), { reviews: '1000', cards: '10' });
    await put(env, donor(41), apkg(60), { reviews: '3000', cards: '20' });
    await withKey(env, 'DELETE', donor(41));
    const bt = await batch(env);
    const r = await call(env, 'GET', '/v1/admin/srs-donations', { headers: basic, now: NOW + 1 });
    expect(r.status).toBe(200);
    expect(r.data).toMatchObject({ donors: 1, reviews: 1000, cards: 10, bytes: 40, pendingWithdrawals: 0 });
    expect(r.data.pool).toEqual({ usedBytes: 40, quotaBytes: poolQuota(env, 'donation') });
    expect(r.data.batches).toEqual([{ createdAt: NOW, expiresAt: NOW + 30 * DAY, donors: 1, withdrawn: 1, url: bt.url }]);
  });
});

describe('公开统计 GET /v1/srs-donations/stats', () => {
  const stats = (env, opts = {}) => call(env, 'GET', '/v1/srs-donations/stats', { now: NOW, ...opts });

  it('无记录：{donors:0, reviews:0}，无需 Authorization，no-store', async () => {
    const env = makeEnv();
    const r = await stats(env);
    expect(r.status).toBe(200);
    expect(r.data).toEqual({ donors: 0, reviews: 0 });
    expect(r.res.headers.get('Cache-Control')).toBe('no-store');
  });

  it('两次上传后合计；撤回后减少', async () => {
    const env = makeEnv();
    await put(env, donor(500), apkg(), { reviews: '1000', cards: '10' });
    await put(env, donor(501), apkg(), { reviews: '3000', cards: '20' });
    expect((await stats(env)).data).toEqual({ donors: 2, reviews: 4000 });
    await withKey(env, 'DELETE', donor(501));
    expect((await stats(env)).data).toEqual({ donors: 1, reviews: 1000 });
  });

  it('非 GET → 405', async () => {
    const env = makeEnv();
    for (const m of ['POST', 'PUT', 'DELETE']) {
      expect((await call(env, m, '/v1/srs-donations/stats', { now: NOW })).status).toBe(405);
    }
  });
});
