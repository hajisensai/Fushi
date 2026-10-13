// 反馈视频附件（槽位 v0）：流式写 R2、魔数嗅探、长度封口、开发者 Range 播放 / 下载、到期清理。
import { gzipSync } from 'node:zlib';
import { describe, expect, it } from 'vitest';
import worker from '../src/worker.js';
import { BASE, call, lastCode, makeEnv, nextIp, pngHeader, registerUser } from './harness.js';
import { FEEDBACK_LIMITS, purgeFeedbackAttachments, purgeFeedbackVideos } from '../src/feedback.js';
import { mediaQuota, poolQuota, videoQuota } from '../src/budget.js';

const NOW = Date.UTC(2026, 9, 12, 12);
const DAY = 24 * 3600 * 1000;
const basic = { Authorization: `Basic ${btoa('admin:pw')}` };
const PNG = pngHeader(320, 640);

/** ISO BMFF 文件头（size + 'ftyp' + major brand）后补 0 到 n 字节；字节值带位置信息方便断言切片。 */
function bmff(brand = 'isom', n = 64) {
  const b = new Uint8Array(n);
  for (let i = 0; i < n; i++) b[i] = i & 0xff;
  b.set([0, 0, 0, 0x18], 0);
  b.set(new TextEncoder().encode(`ftyp${brand}`), 4);
  return b;
}
function webm(n = 64) {
  const b = new Uint8Array(n);
  b.set([0x1a, 0x45, 0xdf, 0xa3, 0x9f, 0x42, 0x86, 0x81, 0x01], 0);
  return b;
}
const MP4 = bmff('isom');

function submit(env, opts = {}) {
  return call(env, 'POST', '/v1/feedback', {
    body: { category: 'bug', title: `视频反馈 ${Math.random()}`, body: '录屏见附件' },
    headers: { 'CF-Connecting-IP': nextIp() },
    now: opts.now ?? NOW,
  });
}

function putVideo(env, f, bytes, { length = bytes.length, type = 'video/mp4', now = NOW, ticket = f.ticket, ip = null } = {}) {
  const headers = { 'X-Fushi-Ticket': ticket };
  if (ip !== null) headers['CF-Connecting-IP'] = ip;
  if (length !== null) headers['Content-Length'] = String(length);
  if (type !== null) headers['Content-Type'] = type;
  return call(env, 'PUT', `/v1/feedback/${f.id}/attachments/v0`, { body: bytes, headers, now });
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

/** 普通池（头像 / 封面 / 截图 / 日志）与视频池分开记账（budget.js MEDIA_POOLS）。 */
const mediaBytes = (env) => env.DB.raw.prepare('SELECT bytes FROM media_usage').get().bytes;
const videoBytes = (env) => env.DB.raw.prepare('SELECT video_bytes FROM media_usage').get().video_bytes;
const mediaSpent = (env) => env.DB.raw.prepare("SELECT COALESCE(SUM(used), 0) n FROM budgets WHERE kind = 'media'").get().n;
const row = (env, id) => env.DB.raw.prepare('SELECT * FROM feedback WHERE id = ?').get(id);

describe('视频上传', () => {
  it('成功：流式写 R2、条目 kind=video、类型按魔数嗅探（不信客户端头）、has_video=1、占配额', async () => {
    const env = makeEnv();
    const f = (await submit(env)).data;
    const r = await putVideo(env, f, MP4, { type: 'Video/MP4; codecs="avc1"' });
    expect(r.status).toBe(201);
    expect(r.data).toEqual({ slot: 'v0', kind: 'video', bytes: MP4.length });
    expect(env.MEDIA.lastPutWasStream).toBe(true);
    const rec = row(env, f.id);
    expect(rec.has_video).toBe(1);
    const [entry] = JSON.parse(rec.attachments);
    expect(entry).toMatchObject({ slot: 'v0', kind: 'video', bytes: MP4.length, type: 'video/mp4' });
    expect(entry.key).toMatch(new RegExp(`^f/${f.id}-v0-.+\\.mp4$`));
    const stored = env.MEDIA.store.get(entry.key);
    expect(stored.bytes).toEqual(MP4);
    expect(stored.httpMetadata.contentType).toBe('video/mp4');
    expect(videoBytes(env)).toBe(MP4.length);
    expect(mediaBytes(env)).toBe(0); // 视频不占普通池
    expect(mediaSpent(env)).toBe(1);

    // QuickTime 文件即使客户端声明 video/mp4，也按嗅探存成 video/quicktime / .mov；WebM 同理。
    const g = (await submit(env)).data;
    expect((await putVideo(env, g, bmff('qt  '), { type: 'video/mp4' })).status).toBe(201);
    const qt = JSON.parse(row(env, g.id).attachments)[0];
    expect(qt.type).toBe('video/quicktime');
    expect(qt.key).toMatch(/\.mov$/);
    const h = (await submit(env)).data;
    expect((await putVideo(env, h, webm(), { type: 'video/quicktime' })).status).toBe(201);
    const wm = JSON.parse(row(env, h.id).attachments)[0];
    expect(wm.type).toBe('video/webm');
    expect(wm.key).toMatch(/\.webm$/);

    // 反馈人详情只看到条目元数据。
    const d = await withTicket(env, 'GET', `/v1/feedback/${f.id}`, f.ticket);
    expect(d.data.attachments).toEqual([{ slot: 'v0', kind: 'video', bytes: MP4.length, type: 'video/mp4' }]);
  });

  it('读体之前就拒：缺 Content-Length 411、超限 413、类型不在白名单 415——都不扣预算不占配额', async () => {
    const env = makeEnv();
    const f = (await submit(env)).data;
    const noLen = await putVideo(env, f, MP4, { length: null });
    expect(noLen.status).toBe(411);
    expect(noLen.data.error).toBe('length_required');
    const big = await putVideo(env, f, MP4, { length: FEEDBACK_LIMITS.videoMaxBytes + 1 });
    expect(big.status).toBe(413);
    expect(big.data.error).toBe('body_too_large');
    expect((await putVideo(env, f, MP4, { length: 0 })).status).toBe(413);
    const badType = await putVideo(env, f, MP4, { type: 'image/png' });
    expect(badType.status).toBe(415);
    expect(badType.data.error).toBe('unsupported_video_type');
    expect((await putVideo(env, f, MP4, { type: null })).data.error).toBe('unsupported_video_type');
    // 魔数不对：只读了开头一块，同样不扣预算。
    const fake = await putVideo(env, f, PNG.slice(0, 32));
    expect(fake.status).toBe(415);
    expect(fake.data.error).toBe('not_a_video');
    expect(mediaSpent(env)).toBe(0);
    expect(mediaBytes(env)).toBe(0);
    expect(videoBytes(env)).toBe(0);
    expect(env.MEDIA.store.size).toBe(0);
    expect(row(env, f.id).has_video).toBe(0);
    // 槽位没被占，之后照常能传。
    expect((await putVideo(env, f, MP4)).status).toBe(201);
  });

  it('实际字节与声明不符 → 400 bad_length，归还配额、不留对象、槽位仍空', async () => {
    const env = makeEnv();
    const f = (await submit(env)).data;
    const short = await putVideo(env, f, MP4, { length: MP4.length + 100 });
    expect(short.status).toBe(400);
    expect(short.data.error).toBe('bad_length');
    const long = await putVideo(env, f, MP4, { length: MP4.length - 10 });
    expect(long.status).toBe(400);
    expect(long.data.error).toBe('bad_length');
    expect(videoBytes(env)).toBe(0);
    expect(env.MEDIA.store.size).toBe(0);
    expect(JSON.parse(row(env, f.id).attachments)).toEqual([]);
    expect(row(env, f.id).has_video).toBe(0);
    expect((await putVideo(env, f, MP4)).status).toBe(201);
    expect(videoBytes(env)).toBe(MP4.length);
  });

  it('补传窗口过期 403；同槽二次 409；别人的回执 404；与截图互不影响', async () => {
    const env = makeEnv();
    const f = (await submit(env)).data;
    const late = await putVideo(env, f, MP4, { now: NOW + FEEDBACK_LIMITS.attachWindowMs + 1 });
    expect(late.status).toBe(403);
    expect(late.data.error).toBe('attach_window_closed');
    const other = (await submit(env)).data;
    expect((await putVideo(env, f, MP4, { ticket: other.ticket })).status).toBe(404);
    expect((await withTicket(env, 'PUT', `/v1/feedback/${f.id}/attachments/s0`, f.ticket, { body: PNG })).status).toBe(201);
    expect((await putVideo(env, f, MP4)).status).toBe(201);
    const again = await putVideo(env, f, MP4);
    expect(again.status).toBe(409);
    expect(again.data.error).toBe('slot_taken');
    expect((await withTicket(env, 'PUT', `/v1/feedback/${f.id}/attachments/s1`, f.ticket, { body: PNG })).status).toBe(201);
    expect(JSON.parse(row(env, f.id).attachments).map((a) => a.slot)).toEqual(['s0', 'v0', 's1']);
    expect(mediaBytes(env)).toBe(2 * PNG.length);
    expect(videoBytes(env)).toBe(MP4.length);
  });

  it('并发：视频与截图同时补传互不作废；v0 被并发占了才 409 conflict 并删掉自己的对象、归还配额', async () => {
    const env = makeEnv({ d1DelayMs: 5 });
    const f = (await submit(env)).data;
    const [v, s] = await Promise.all([
      putVideo(env, f, MP4),
      withTicket(env, 'PUT', `/v1/feedback/${f.id}/attachments/s0`, f.ticket, { body: PNG }),
    ]);
    expect(v.status).toBe(201);
    expect(s.status).toBe(201);
    expect(JSON.parse(row(env, f.id).attachments).map((a) => a.slot).sort()).toEqual(['s0', 'v0']);

    const g = (await submit(env)).data;
    const both = await Promise.all([putVideo(env, g, MP4), putVideo(env, g, MP4)]);
    expect(both.map((r) => r.status).sort()).toEqual([201, 409]);
    expect(JSON.parse(row(env, g.id).attachments).filter((a) => a.slot === 'v0')).toHaveLength(1);
    const keys = [...env.MEDIA.store.keys()].filter((k) => k.startsWith(`f/${g.id}-v0-`));
    expect(keys).toHaveLength(1);
    // 输家的预占已归还：f 的视频 + 截图 + g 的一份视频。
    expect(mediaBytes(env)).toBe(PNG.length);
    expect(videoBytes(env)).toBe(2 * MP4.length);
  });
});

// ---- 视频配额池 ----

describe('视频配额池', () => {
  it('视频池默认 1 GiB、最多切走总配额一半；两池之和等于总配额', () => {
    const def = {};
    expect(videoQuota(def)).toBe(1024 * 1024 * 1024);
    expect(poolQuota(def, 'video') + poolQuota(def, 'media')).toBe(mediaQuota(def));
    const small = { MEDIA_QUOTA_BYTES: '1000', VIDEO_QUOTA_BYTES: '900' };
    expect(videoQuota(small)).toBe(500);
    expect(poolQuota(small, 'media')).toBe(500);
  });

  it('视频池满了：视频 507 video_quota、不留对象；截图 / 头像那份照常可传', async () => {
    const env = makeEnv({ VIDEO_QUOTA_BYTES: String(2 * MP4.length) });
    for (let i = 0; i < 2; i++) {
      expect((await putVideo(env, (await submit(env)).data, MP4)).status).toBe(201);
    }
    const f = (await submit(env)).data;
    const full = await putVideo(env, f, MP4);
    expect(full.status).toBe(507);
    expect(full.data.error).toBe('video_quota');
    expect(videoBytes(env)).toBe(2 * MP4.length);
    expect([...env.MEDIA.store.keys()].filter((k) => k.startsWith(`f/${f.id}-`))).toEqual([]);
    expect(row(env, f.id).has_video).toBe(0);
    // 普通池不受影响：同一条反馈的截图照传、别人的头像照传。
    expect((await withTicket(env, 'PUT', `/v1/feedback/${f.id}/attachments/s0`, f.ticket, { body: PNG })).status).toBe(201);
    const u = await registerUser(env, 'avatar', { now: NOW });
    const av = await call(env, 'PUT', '/v1/me/avatar', { key: u.key, account: u.id, body: PNG, now: NOW });
    expect(av.status).toBeLessThan(300);
    expect(mediaBytes(env)).toBe(2 * PNG.length);
  });

  it('普通池满了：截图 507 media_quota，视频照传（视频不吃普通池，也不被它挡）', async () => {
    const env = makeEnv({ MEDIA_QUOTA_BYTES: '100000', VIDEO_QUOTA_BYTES: '1000' });
    env.DB.raw.prepare('UPDATE media_usage SET bytes = ?').run(poolQuota(env, 'media'));
    const f = (await submit(env)).data;
    const shot = await withTicket(env, 'PUT', `/v1/feedback/${f.id}/attachments/s0`, f.ticket, { body: PNG });
    expect(shot.status).toBe(507);
    expect(shot.data.error).toBe('media_quota');
    expect((await putVideo(env, f, MP4)).status).toBe(201);
    expect(videoBytes(env)).toBe(MP4.length);
    expect(mediaBytes(env)).toBe(poolQuota(env, 'media'));
  });

  it('每 IP 每天视频字节有上限（按声明长度计、传失败不退）：超了 429，换个 IP 照传', async () => {
    const env = makeEnv();
    const f = (await submit(env)).data;
    const ip = '198.51.100.7';
    const big = FEEDBACK_LIMITS.videoMaxBytes;
    const attempts = Math.floor(FEEDBACK_LIMITS.videoBytesPerIpDay / big);
    expect(attempts).toBeGreaterThan(0);
    // 声明满额、实际只发 64 字节：每次都 400 bad_length，但当天字节额度照样记上。
    for (let i = 0; i < attempts; i++) {
      const r = await putVideo(env, f, MP4, { length: big, ip });
      expect(r.status).toBe(400);
      expect(r.data.error).toBe('bad_length');
    }
    const limited = await putVideo(env, f, MP4, { ip });
    expect(limited.status).toBe(429);
    expect(limited.data.error).toBe('rate_limited');
    expect(videoBytes(env)).toBe(0);
    expect(env.MEDIA.store.size).toBe(0);
    // 额度按 IP 算：别的 IP 不受影响；次日窗口重新计。
    expect((await putVideo(env, f, MP4, { ip: '198.51.100.8' })).status).toBe(201);
    const g = (await submit(env, { now: NOW + DAY })).data;
    expect((await putVideo(env, g, MP4, { ip, now: NOW + DAY })).status).toBe(201);
  });
});

// ---- 取视频 ----

function form(fields) {
  return new TextEncoder().encode(new URLSearchParams(fields).toString());
}
function page(env, method, path, { cookie, fields, headers = {}, ip } = {}) {
  const h = { 'CF-Connecting-IP': ip ?? nextIp(), ...headers };
  if (cookie) h.Cookie = cookie;
  if (method === 'POST') {
    h['Content-Type'] = 'application/x-www-form-urlencoded';
    h.Origin = BASE;
  }
  return call(env, method, path, { headers: h, body: fields ? form(fields) : undefined, now: NOW });
}
async function webCookie(env, user) {
  const ip = nextIp();
  await page(env, 'POST', '/dev/code', { fields: { email: user.email }, ip });
  const res = await page(env, 'POST', '/dev/login', { fields: { email: user.email, code: lastCode(env, user.email) }, ip });
  return res.res.headers.get('Set-Cookie').split(';')[0];
}

describe('取视频', () => {
  it('反馈人拿不到视频（ticket 也不行）', async () => {
    const env = makeEnv();
    const f = (await submit(env)).data;
    await putVideo(env, f, MP4);
    expect((await withTicket(env, 'GET', `/v1/feedback/${f.id}/attachments/v0`, f.ticket)).status).toBe(404);
  });

  it('开发者：整段 200 + Accept-Ranges；Range 206 正确切片；越界 416；download=1 作附件下载', async () => {
    const env = makeEnv();
    const dev = await makeDev(env);
    const f = (await submit(env)).data;
    await putVideo(env, f, MP4);
    const base = `/v1/dev/feedback/${f.id}/attachments/v0`;
    const get = (path, headers = {}) => call(env, 'GET', path, { key: dev.key, account: dev.id, headers, now: NOW });

    const full = await get(base);
    expect(full.status).toBe(200);
    expect(full.res.headers.get('Content-Type')).toBe('video/mp4');
    expect(full.res.headers.get('Accept-Ranges')).toBe('bytes');
    expect(full.res.headers.get('Content-Length')).toBe(String(MP4.length));
    expect(full.res.headers.get('Content-Disposition')).toBeNull();

    const slice = await call(env, 'GET', base, { key: dev.key, account: dev.id, headers: { Range: 'bytes=20-29' }, now: NOW });
    expect(slice.status).toBe(206);
    expect(slice.res.headers.get('Content-Range')).toBe(`bytes 20-29/${MP4.length}`);
    expect(slice.res.headers.get('Content-Length')).toBe('10');
    expect(slice.res.headers.get('Accept-Ranges')).toBe('bytes');
    expect(new TextEncoder().encode(slice.data)).toEqual(MP4.slice(20, 30));

    const open = await get(base, { Range: 'bytes=60-' });
    expect(open.status).toBe(206);
    expect(open.res.headers.get('Content-Range')).toBe(`bytes 60-63/${MP4.length}`);
    const suffix = await get(base, { Range: 'bytes=-4' });
    expect(suffix.res.headers.get('Content-Range')).toBe(`bytes 60-63/${MP4.length}`);
    const clamp = await get(base, { Range: 'bytes=62-999' });
    expect(clamp.res.headers.get('Content-Range')).toBe(`bytes 62-63/${MP4.length}`);
    const bad = await get(base, { Range: `bytes=${MP4.length}-` });
    expect(bad.status).toBe(416);
    expect(bad.res.headers.get('Content-Range')).toBe(`bytes */${MP4.length}`);
    // 多段 / 不认识的 Range 忽略，回整段。
    expect((await get(base, { Range: 'bytes=0-1,4-5' })).status).toBe(200);

    const dl = await get(`${base}?download=1`);
    expect(dl.status).toBe(200);
    expect(dl.res.headers.get('Content-Disposition')).toBe(`attachment; filename="fushi-${f.id}.mp4"`);
  });

  it('网页处理台：详情渲染 <video> + 下载链接（CSP 放行 media-src self）；附件路由转发 Range 与 download', async () => {
    const env = makeEnv();
    const dev = await makeDev(env);
    const f = (await submit(env)).data;
    await putVideo(env, f, MP4);
    const cookie = await webCookie(env, dev);
    const detail = await page(env, 'GET', `/dev/f/${f.id}`, { cookie });
    expect(detail.data).toContain(`<video controls preload="metadata" src="/dev/f/${f.id}/a/v0">`);
    expect(detail.data).toContain(`href="/dev/f/${f.id}/a/v0?download=1"`);
    expect(detail.data).toContain('下载视频（');
    expect(detail.res.headers.get('Content-Security-Policy')).toContain("media-src 'self'");
    const part = await page(env, 'GET', `/dev/f/${f.id}/a/v0`, { cookie, headers: { Range: 'bytes=0-15' } });
    expect(part.status).toBe(206);
    expect(part.res.headers.get('Content-Range')).toBe(`bytes 0-15/${MP4.length}`);
    const dl = await page(env, 'GET', `/dev/f/${f.id}/a/v0?download=1`, { cookie });
    expect(dl.res.headers.get('Content-Disposition')).toBe(`attachment; filename="fushi-${f.id}.mp4"`);
    // 没有视频的反馈不渲染视频块。
    const g = (await submit(env)).data;
    expect((await page(env, 'GET', `/dev/f/${g.id}`, { cookie })).data).not.toContain('<video');
  });
});

describe('视频到期清理', () => {
  it('结案 7 天后删；创建 30 天后未结案也删；未到期不删；只删视频、截图日志不动；配额归还', async () => {
    const env = makeEnv();
    const dev = await makeDev(env);
    const gz = new Uint8Array(gzipSync(Buffer.from('log\n')));
    const closed = (await submit(env)).data;
    const open = (await submit(env)).data;
    const young = (await submit(env, { now: NOW + 5 * DAY })).data;
    for (const f of [closed, open]) await putVideo(env, f, MP4);
    await putVideo(env, young, MP4, { now: NOW + 5 * DAY });
    await withTicket(env, 'PUT', `/v1/feedback/${closed.id}/attachments/s0`, closed.ticket, { body: PNG });
    await withTicket(env, 'PUT', `/v1/feedback/${closed.id}/attachments/log`, closed.ticket, { body: gz });
    const r = await call(env, 'POST', `/v1/dev/feedback/${closed.id}`, { key: dev.key, account: dev.id, body: { status: 'resolved' }, now: NOW });
    expect(r.status).toBe(200);
    expect(mediaBytes(env)).toBe(PNG.length + gz.length);
    expect(videoBytes(env)).toBe(3 * MP4.length);

    expect(await purgeFeedbackVideos(env, NOW + 7 * DAY - 1)).toBe(0);
    expect(await purgeFeedbackVideos(env, NOW + 7 * DAY + 1)).toBe(1);
    const c = row(env, closed.id);
    expect(c.has_video).toBe(0);
    expect(JSON.parse(c.attachments).map((a) => a.slot)).toEqual(['s0', 'log']);
    expect(c.updated_at).toBe(NOW); // 清理不刷新 updated_at（不打乱处理台排序）
    expect(videoBytes(env)).toBe(2 * MP4.length);
    expect(mediaBytes(env)).toBe(PNG.length + gz.length); // 截图日志不动
    expect(env.MEDIA.store.size).toBe(4);
    expect(row(env, open.id).has_video).toBe(1);

    expect(await purgeFeedbackVideos(env, NOW + 30 * DAY - 1)).toBe(0);
    expect(await purgeFeedbackVideos(env, NOW + 30 * DAY + 1)).toBe(1);
    expect(row(env, open.id).has_video).toBe(0);
    expect(JSON.parse(row(env, open.id).attachments)).toEqual([]);
    expect(row(env, open.id).status).toBe('open');
    expect(row(env, young.id).has_video).toBe(1);
    expect(videoBytes(env)).toBe(MP4.length);
    expect(mediaBytes(env)).toBe(PNG.length + gz.length);
    // 再跑一次没有可清的。
    expect(await purgeFeedbackVideos(env, NOW + 30 * DAY + 1)).toBe(0);
  });

  it('定时任务会调到视频清理；90 天附件清理清空列表时 has_video 一并归零', async () => {
    const env = makeEnv();
    const f = (await submit(env)).data;
    await putVideo(env, f, MP4);
    const realNow = Date.now;
    Date.now = () => NOW + 31 * DAY;
    try {
      await worker.scheduled({}, env);
    } finally {
      Date.now = realNow;
    }
    expect(row(env, f.id).has_video).toBe(0);
    expect(videoBytes(env)).toBe(0);

    // 直接把带视频的已结案行交给 90 天附件清理（视频清理没赶上时）。
    const dev = await makeDev(env);
    const g = (await submit(env)).data;
    await putVideo(env, g, MP4);
    await call(env, 'POST', `/v1/dev/feedback/${g.id}`, { key: dev.key, account: dev.id, body: { status: 'wont_fix' }, now: NOW });
    expect(await purgeFeedbackAttachments(env, NOW + FEEDBACK_LIMITS.attachmentRetentionMs + 1)).toBe(1);
    expect(row(env, g.id).has_video).toBe(0);
    expect(row(env, g.id).attachments).toBe('[]');
    expect(videoBytes(env)).toBe(0);
    expect(mediaBytes(env)).toBe(0);
  });
});
