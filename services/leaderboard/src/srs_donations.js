// SRS 复习历史捐赠（给 anki-rwkv 训练调度模型；设计 docs/specs/2026-11-26-srs-review-donation.md，迁移 0027 / 0029）。
//
// 身份：客户端由 profileUid 派生 donorId（32 位小写 hex）与 donorKey（64 位 hex，Bearer 凭据）。
// 服务端只存 key_hash = hex(sha256(donorKey 的小写形式按 UTF-8))；第一次上传的 key 认领该 donorId，
// 之后同一 donorId 的上传 / 查询 / 撤回都必须带同一把 key，否则 403 donor_key_mismatch。
//
// 接口：
//   PUT    /v1/srs-donations/:donorId   [Bearer donorKey] body = .apkg 原始字节（application/octet-stream，流式写 R2）
//          头 Content-Length（必须，≤ 64 MiB）、x-donation-reviews / x-donation-cards（非负整数）、
//          x-donation-app-version（可选，≤ 64 个 [A-Za-z0-9.+_-]）。魔数必须是 zip（PK\x03\x04）。
//          → 200 {donated: true, reviews, cards, updatedAt}（与 GET 同一形状，donationStatus）。同一 donorId 重传覆盖 R2 `srs-donations/<donorId>.apkg`。
//          限流：每 donorId 每小时 2 次（429 rate_limited）；每 IP 每 UTC 日 128 MiB（429 upload_quota_daily，
//          按声明长度计，传失败不退）；全局扣 media 日预算 1 次 + write_rows；字节占 budget.js 的捐赠专用池
//          （'donation'，media_usage.donation_bytes，DONATION_QUOTA_BYTES 默认 2 GiB，满了 507 donation_quota；
//          捐赠包永不过期，所以不与 30 天过期的反馈视频共池）。重传只预占比旧文件多出的字节，成功后归还
//          变小的差额；撤回归还整份。曾撤回的，删掉那条撤回记录（新文件在 feed 里取代它）。
//   GET    /v1/srs-donations/:donorId   [Bearer donorKey] → 200 {donated, reviews, cards, updatedAt}；无记录 {donated: false}
//   DELETE /v1/srs-donations/:donorId   [Bearer donorKey] → 删 R2 + 行、写撤回记录 → 200 {donated: false}；无记录也 200（不写撤回）
//   GET    /v1/srs-donations/stats      公开、无需鉴权 → 200 {donors, reviews}（捐赠者数 / 复习条数合计，无记录各为 0）；
//          其他方法 405。「捐赠者到 30 人提醒所有者」由所有者本地的 kaguya bot 轮询此接口完成，服务端不发通知。
//
// 管理（HTTP Basic，ADMIN_USER / ADMIN_PASS，admin.js checkBasicAuth）：
//   POST   /v1/admin/srs-donations/feeds      body {label} → 签发长期 feed 凭据（随机 32 字节 token，库里只存 sha256）
//          → 200 {id, label, createdAt, url, token}（token 明文只给这一次）。CLI：node scripts/srs_donation_feed.mjs create <label>
//   DELETE /v1/admin/srs-donations/feeds/:id  吊销（幂等）→ 200 {id, revokedAt}；不存在 404
//   GET    /v1/admin/srs-donations            → 统计 {donors, reviews, cards, bytes, pool: {usedBytes, quotaBytes},
//                                               withdrawals, feeds:[{id, label, createdAt, revokedAt}]}
//
// feed 下载（链接里的 token 即凭据，无其他认证；长期有效，吊销后 404；清单实时，不是快照）：
//   GET /d/srs-donations/<token>/                 JSON 清单 {format: 'fushi-srs-donation-feed', version: 1,
//                                                 files:[{donorId, reviews, cards, bytes, updatedAt, etag, url}],
//                                                 withdrawn:[{donorId, withdrawnAt}], withdrawnUrl}；带 ETag，
//                                                 If-None-Match 命中 304（定时轮询什么都没变时不传体）
//   GET /d/srs-donations/<token>/<donorId>.apkg   attachment / application/octet-stream，ETag = 清单里的 etag
//                                                 （If-None-Match 命中 304）；已撤回 / 不存在 → 404
//   GET /d/srs-donations/<token>/withdrawn.txt    全部撤回 ID，一行一个（带 ETag）
//
// 已知取舍：同一 donorId 两把不同 key 并发「首次上传」时，后到的那次在写行时才发现冲突（409 conflict），
// 但 R2 对象已被它覆盖；donorId 由 profileUid 派生，能撞上的人本就能拿到 donorKey，按 spec 接受。

import { HttpError, hex, json, sha256 } from './util.js';
import { DAY, HOUR, hit } from './ratelimit.js';
import { deleteMedia, poolUsage, releaseMediaBytes, reserveMediaBytes, spend } from './budget.js';
import { checkBasicAuth } from './admin.js';

export const SRS_DONATION_PATH = '/v1/srs-donations/';
export const SRS_DONATION_ADMIN_PATH = '/v1/admin/srs-donations';
export const SRS_DONATION_DOWNLOAD_PATH = '/d/srs-donations/';

export const SRS_DONATION_LIMITS = {
  /** 单个捐赠包上限 64 MiB（10 万条复习的脱敏包约几 MB）。 */
  maxBytes: 64 * 1024 * 1024,
  uploadsPerDonorHour: 2,
  /** 每 IP 每 UTC 日上传字节（两次满额）。 */
  bytesPerIpDay: 128 * 1024 * 1024,
  maxCount: 1e9,
};

/** 一次上传的估算写入行数（捐赠行 + 撤回清理 + 限流 / 预算计数）。 */
const UPLOAD_WRITE_ROWS = 8;
const DELETE_WRITE_ROWS = 4;
const POOL = 'donation';
const ZIP_MAGIC = [0x50, 0x4b, 0x03, 0x04];

export const DONOR_ID_RE = /^[0-9a-f]{32}$/;
const DONOR_KEY_RE = /^[0-9a-fA-F]{64}$/;
const FEED_TOKEN_RE = /^[0-9a-f]{64}$/;
/** feed 标签（发给了谁）：1–64 个可见字符。 */
const FEED_LABEL_RE = /^[^\u0000-\u001f\u007f]{1,64}$/;
const APP_VERSION_RE = /^[A-Za-z0-9.+_-]{1,64}$/;

const NO_STORE = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer' };

/**
 * 路径是否归本模块。
 * @param {string} path
 * @returns {boolean}
 */
export function isSrsDonationPath(path) {
  return path.startsWith(SRS_DONATION_PATH)
    || path === SRS_DONATION_ADMIN_PATH
    || path.startsWith(`${SRS_DONATION_ADMIN_PATH}/`)
    || path.startsWith(SRS_DONATION_DOWNLOAD_PATH);
}

/**
 * R2 键。
 * @param {string} donorId
 * @returns {string}
 */
export function donationKey(donorId) {
  return `srs-donations/${donorId}.apkg`;
}

/**
 * donorKey → 库里存的 key_hash。
 * @param {string} donorKey 64 位 hex（大小写不敏感）
 * @returns {Promise<string>}
 */
export async function donorKeyHash(donorKey) {
  return hex(await sha256(new TextEncoder().encode(donorKey.toLowerCase())));
}

/** 取 Bearer donorKey（格式不对 401 bad_donor_key）。 */
function bearerKey(request) {
  const m = /^Bearer\s+(\S+)$/i.exec(request.headers.get('Authorization') || '');
  if (!m || !DONOR_KEY_RE.test(m[1])) throw new HttpError(401, 'bad_donor_key');
  return m[1].toLowerCase();
}

/** 非负整数头（必须给）。 */
function countHeader(request, name, code) {
  const v = request.headers.get(name);
  if (v === null || !/^\d{1,10}$/.test(v.trim())) throw new HttpError(400, code);
  const n = Number(v.trim());
  if (n > SRS_DONATION_LIMITS.maxCount) throw new HttpError(400, code);
  return n;
}

async function readHead(reader, n) {
  const chunks = [];
  let len = 0;
  while (len < n) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
    len += value.byteLength;
  }
  const out = new Uint8Array(len);
  let at = 0;
  for (const c of chunks) {
    out.set(c, at);
    at += c.byteLength;
  }
  return out;
}

/** 把嗅探时已读走的头部与剩余流拼回一条流。 */
function rejoin(head, reader) {
  return new ReadableStream({
    start(controller) {
      if (head.length) controller.enqueue(head);
    },
    async pull(controller) {
      const { done, value } = await reader.read();
      if (done) controller.close();
      else controller.enqueue(value);
    },
    cancel(reason) {
      return reader.cancel(reason);
    },
  });
}

async function donorRow(env, donorId) {
  return env.DB.prepare(
    'SELECT donor_id, key_hash, bytes, reviews, cards, app_version, created_at, updated_at FROM srs_donations WHERE donor_id = ?1',
  ).bind(donorId).first();
}

/** 有记录时核对 key；返回行（无记录 null）。 */
async function authorizedRow(env, donorId, keyHash) {
  const row = await donorRow(env, donorId);
  if (row && row.key_hash !== keyHash) throw new HttpError(403, 'donor_key_mismatch');
  return row;
}

/**
 * PUT：流式写 R2。所有能在读体之前判的（id / key / 长度 / 计数头 / key 归属 / 每 donorId 限流）先判；
 * 魔数通过后才扣 IP 日额度、全局预算并预占配额池。R2 put 对同一键是原子替换：中途失败旧文件仍在。
 */
async function putDonation(env, request, donorId, now, ip) {
  const keyHash = await donorKeyHash(bearerKey(request));
  const declared = request.headers.get('Content-Length');
  if (declared === null || declared === '') throw new HttpError(411, 'length_required');
  const length = Number(declared);
  if (!/^\d+$/.test(declared) || length < ZIP_MAGIC.length || length > SRS_DONATION_LIMITS.maxBytes) {
    throw new HttpError(413, 'body_too_large');
  }
  const reviews = countHeader(request, 'x-donation-reviews', 'bad_reviews');
  const cards = countHeader(request, 'x-donation-cards', 'bad_cards');
  const versionRaw = (request.headers.get('x-donation-app-version') || '').trim();
  if (versionRaw && !APP_VERSION_RE.test(versionRaw)) throw new HttpError(400, 'bad_app_version');
  const appVersion = versionRaw || null;
  if (!request.body) throw new HttpError(400, 'bad_length');

  const existing = await authorizedRow(env, donorId, keyHash);
  await hit(env, `srsdon:${donorId}`, HOUR, SRS_DONATION_LIMITS.uploadsPerDonorHour, now);

  const reader = request.body.getReader();
  // 重传时旧文件的字节已在池里：只预占多出来的部分（R2 同键 put 是原子替换，不会同时存两份）。
  const oldBytes = existing && existing.bytes ? existing.bytes : 0;
  const extra = Math.max(0, length - oldBytes);
  let reserved = false;
  try {
    const head = await readHead(reader, ZIP_MAGIC.length);
    if (head.length < ZIP_MAGIC.length || ZIP_MAGIC.some((b, i) => head[i] !== b)) {
      throw new HttpError(415, 'not_a_zip');
    }
    await hit(env, `srsdon:ip:${ip}`, DAY, SRS_DONATION_LIMITS.bytesPerIpDay, now, length, 'upload_quota_daily');
    await spend(env, 'media', 1, now);
    await spend(env, 'write_rows', UPLOAD_WRITE_ROWS, now);
    if (extra > 0) {
      await reserveMediaBytes(env, extra, POOL);
      reserved = true;
    }
    // eslint-disable-next-line no-undef
    const body = rejoin(head, reader).pipeThrough(new FixedLengthStream(length));
    try {
      await env.MEDIA.put(donationKey(donorId), body, { httpMetadata: { contentType: 'application/octet-stream' } });
    } catch {
      throw new HttpError(400, 'bad_length');
    }
    // 新文件已就位：从这里起预占的字节归它，失败路径不再归还。
    reserved = false;
    const res = await env.DB.prepare(
      `INSERT INTO srs_donations (donor_id, key_hash, bytes, reviews, cards, app_version, created_at, updated_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7)
       ON CONFLICT (donor_id) DO UPDATE SET bytes = excluded.bytes, reviews = excluded.reviews, cards = excluded.cards,
         app_version = excluded.app_version, updated_at = excluded.updated_at
       WHERE srs_donations.key_hash = excluded.key_hash`,
    ).bind(donorId, keyHash, length, reviews, cards, appVersion, now).run();
    if (res.meta.changes !== 1) {
      // 并发首次上传撞上了别的 key（文件头「已知取舍」）：行归先到的那把 key，配额池可能记偏，接受。
      throw new HttpError(409, 'conflict');
    }
    if (oldBytes > length) await releaseMediaBytes(env, oldBytes - length, POOL);
    // 新文件在 feed 清单里取代撤回记录（消费方按 updatedAt 换新）。
    await env.DB.prepare('DELETE FROM srs_donation_withdrawals WHERE donor_id = ?1').bind(donorId).run();
    return json(donationStatus({ reviews, cards, updated_at: now }), 200, NO_STORE);
  } catch (e) {
    await reader.cancel().catch(() => {});
    if (reserved) await releaseMediaBytes(env, extra, POOL);
    throw e;
  }
}

/** 公开统计：捐赠者数与复习条数合计（所有者的 kaguya bot 轮询）。 */
async function publicStats(env) {
  const r = await env.DB.prepare('SELECT COUNT(*) AS donors, COALESCE(SUM(reviews), 0) AS reviews FROM srs_donations').first();
  return { donors: r.donors, reviews: r.reviews };
}

/**
 * 捐赠状态响应体：PUT 成功与 GET 共用这一个形状（客户端拿任一个都能直接当「当前状态」显示）。
 * @param {{reviews: number, cards: number, updated_at: number} | null} row
 */
function donationStatus(row) {
  if (!row) return { donated: false };
  return { donated: true, reviews: row.reviews, cards: row.cards, updatedAt: row.updated_at };
}

async function getDonation(env, request, donorId) {
  const keyHash = await donorKeyHash(bearerKey(request));
  const row = await authorizedRow(env, donorId, keyHash);
  return json(donationStatus(row), 200, NO_STORE);
}

async function deleteDonation(env, request, donorId, now) {
  const keyHash = await donorKeyHash(bearerKey(request));
  const row = await authorizedRow(env, donorId, keyHash);
  if (!row) return json({ donated: false }, 200, NO_STORE);
  await spend(env, 'write_rows', DELETE_WRITE_ROWS, now);
  await deleteMedia(env, donationKey(donorId), POOL);
  await env.DB.batch([
    env.DB.prepare('DELETE FROM srs_donations WHERE donor_id = ?1').bind(donorId),
    env.DB.prepare(
      `INSERT INTO srs_donation_withdrawals (donor_id, withdrawn_at) VALUES (?1, ?2)
       ON CONFLICT (donor_id) DO UPDATE SET withdrawn_at = excluded.withdrawn_at`,
    ).bind(donorId, now),
  ]);
  return json({ donated: false }, 200, NO_STORE);
}

function feedUrl(origin, token) {
  return `${origin}${SRS_DONATION_DOWNLOAD_PATH}${token}/`;
}

/** 管理请求体（JSON，≤ 4 KiB）。 */
async function adminJson(request) {
  const text = await request.text();
  if (text.length > 4096) throw new HttpError(413, 'body_too_large');
  if (!text) return {};
  try {
    const v = JSON.parse(text);
    return v && typeof v === 'object' ? v : {};
  } catch {
    throw new HttpError(400, 'bad_json');
  }
}

/**
 * 签发一个 feed 凭据：随机 32 字节 token，库里只存它的 sha256；明文只在这次响应里给。
 * @returns {Promise<{id: number, label: string, createdAt: number, url: string, token: string}>}
 */
export async function createDonationFeed(env, origin, label, now) {
  if (typeof label !== 'string' || !FEED_LABEL_RE.test(label)) throw new HttpError(400, 'bad_label');
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  const token = hex(bytes);
  const tokenHash = hex(await sha256(new TextEncoder().encode(token)));
  const row = await env.DB.prepare(
    'INSERT INTO srs_donation_feeds (label, token_hash, created_at) VALUES (?1, ?2, ?3) RETURNING id',
  ).bind(label, tokenHash, now).first();
  return { id: row.id, label, createdAt: now, url: feedUrl(origin, token), token };
}

/** 吊销 feed（幂等；不存在 404）。 */
async function revokeDonationFeed(env, id, now) {
  const row = await env.DB.prepare('SELECT id, revoked_at FROM srs_donation_feeds WHERE id = ?1').bind(id).first();
  if (!row) throw new HttpError(404, 'not_found');
  if (row.revoked_at === null) {
    await env.DB.prepare('UPDATE srs_donation_feeds SET revoked_at = ?2 WHERE id = ?1').bind(id, now).run();
    return { id, revokedAt: now };
  }
  return { id, revokedAt: row.revoked_at };
}

async function donationStats(env) {
  const s = await env.DB.prepare(
    `SELECT COUNT(*) AS donors, COALESCE(SUM(reviews), 0) AS reviews, COALESCE(SUM(cards), 0) AS cards,
       COALESCE(SUM(bytes), 0) AS bytes FROM srs_donations`,
  ).first();
  const w = await env.DB.prepare('SELECT COUNT(*) AS n FROM srs_donation_withdrawals').first();
  const feeds = (await env.DB.prepare(
    'SELECT id, label, created_at, revoked_at FROM srs_donation_feeds ORDER BY id',
  ).all()).results.map((f) => ({ id: f.id, label: f.label, createdAt: f.created_at, revokedAt: f.revoked_at }));
  const pool = await poolUsage(env, POOL);
  return { donors: s.donors, reviews: s.reviews, cards: s.cards, bytes: s.bytes, pool, withdrawals: w.n, feeds };
}

/** token → 有效（未吊销）的 feed；格式不对 / 不存在 / 已吊销一律 404（不区分，免得探测）。 */
async function liveFeed(env, token) {
  if (!FEED_TOKEN_RE.test(token)) throw new HttpError(404, 'not_found');
  const tokenHash = hex(await sha256(new TextEncoder().encode(token)));
  const f = await env.DB.prepare('SELECT id FROM srs_donation_feeds WHERE token_hash = ?1 AND revoked_at IS NULL')
    .bind(tokenHash).first();
  if (!f) throw new HttpError(404, 'not_found');
  return f;
}

/** 弱比较 If-None-Match（逗号分隔 / `*`）。 */
function etagMatches(request, etag) {
  const inm = request.headers.get('If-None-Match');
  if (!inm) return false;
  return inm.split(',').some((t) => {
    const v = t.trim().replace(/^W\//, '');
    return v === '*' || v === etag;
  });
}

const FEED_HEADERS = { 'X-Robots-Tag': 'noindex, nofollow', ...NO_STORE };

/** 带 ETag 的文本响应；If-None-Match 命中回 304。ETag = sha256(body) 前 32 位。 */
async function conditionalText(request, text, contentType) {
  const etag = `"${hex(await sha256(new TextEncoder().encode(text))).slice(0, 32)}"`;
  if (etagMatches(request, etag)) return new Response(null, { status: 304, headers: { ETag: etag, ...FEED_HEADERS } });
  return new Response(text, { headers: { 'Content-Type': contentType, ETag: etag, ...FEED_HEADERS } });
}

/** 文件 ETag：由捐赠行的 updated_at 与大小决定（每次重传 updated_at 都变），304 不必读 R2。 */
function fileEtag(d) {
  return `"${d.updated_at}-${d.bytes}"`;
}

/**
 * feed 清单：此刻的全部捐赠与全部撤回（实时，不是快照）。消费方定时拉（ETag 不变 = 什么都没变），
 * 按 donorId 比 updatedAt 只下变了的文件；`withdrawn` 里的、以及本地有而 `files` 里没有的，删掉。
 */
async function feedManifest(env, base) {
  const files = (await env.DB.prepare(
    'SELECT donor_id, reviews, cards, bytes, updated_at FROM srs_donations ORDER BY donor_id',
  ).all()).results.map((d) => ({
    donorId: d.donor_id,
    reviews: d.reviews,
    cards: d.cards,
    bytes: d.bytes,
    updatedAt: d.updated_at,
    etag: fileEtag(d),
    url: `${base}${d.donor_id}.apkg`,
  }));
  const withdrawn = (await env.DB.prepare(
    'SELECT donor_id, withdrawn_at FROM srs_donation_withdrawals ORDER BY donor_id',
  ).all()).results.map((w) => ({ donorId: w.donor_id, withdrawnAt: w.withdrawn_at }));
  return { format: 'fushi-srs-donation-feed', version: 1, files, withdrawn, withdrawnUrl: `${base}withdrawn.txt` };
}

async function downloadRoute(env, request, url) {
  const rest = url.pathname.slice(SRS_DONATION_DOWNLOAD_PATH.length);
  const m = /^([^/]+)(?:\/(.*))?$/.exec(rest);
  if (!m) throw new HttpError(404, 'not_found');
  await liveFeed(env, m[1]);
  const file = m[2] || '';
  const base = feedUrl(url.origin, m[1]);
  if (file === '') {
    const body = await feedManifest(env, base);
    return conditionalText(request, `${JSON.stringify(body, null, 2)}\n`, 'application/json; charset=utf-8');
  }
  if (file === 'withdrawn.txt') {
    const ids = (await env.DB.prepare('SELECT donor_id FROM srs_donation_withdrawals ORDER BY donor_id').all())
      .results.map((w) => w.donor_id);
    return conditionalText(request, ids.length ? `${ids.join('\n')}\n` : '', 'text/plain; charset=utf-8');
  }
  const f = /^([0-9a-f]{32})\.apkg$/.exec(file);
  if (!f) throw new HttpError(404, 'not_found');
  const donorId = f[1];
  const d = await donorRow(env, donorId);
  if (!d) throw new HttpError(404, 'not_found');
  const etag = fileEtag(d);
  if (etagMatches(request, etag)) return new Response(null, { status: 304, headers: { ETag: etag, ...FEED_HEADERS } });
  const obj = await env.MEDIA.get(donationKey(donorId));
  if (!obj) throw new HttpError(404, 'not_found');
  return new Response(obj.body, {
    headers: {
      'Content-Type': 'application/octet-stream',
      'Content-Length': String(obj.size),
      'Content-Disposition': `attachment; filename="${donorId}.apkg"`,
      ETag: etag,
      'Last-Modified': new Date(d.updated_at).toUTCString(),
      ...FEED_HEADERS,
    },
  });
}

/**
 * 本模块的全部路由；路径不归它返回 null。
 * @param {Request} request
 * @param {object} env
 * @param {URL} url
 * @param {number} now
 * @param {string} ip 限流键（worker.js clientIp，IPv6 按 /64）
 * @returns {Promise<Response|null>}
 */
export async function routeSrsDonations(request, env, url, now, ip) {
  const path = url.pathname;
  const method = request.method;
  if (path === `${SRS_DONATION_ADMIN_PATH}/feeds` && method === 'POST') {
    checkBasicAuth(request, env);
    const body = await adminJson(request);
    return json(await createDonationFeed(env, url.origin, body.label, now), 200, NO_STORE);
  }
  const feedId = /^\/v1\/admin\/srs-donations\/feeds\/(\d{1,12})$/.exec(path);
  if (feedId && method === 'DELETE') {
    checkBasicAuth(request, env);
    return json(await revokeDonationFeed(env, Number(feedId[1]), now), 200, NO_STORE);
  }
  if (path === SRS_DONATION_ADMIN_PATH && method === 'GET') {
    checkBasicAuth(request, env);
    return json(await donationStats(env), 200, NO_STORE);
  }
  if (path.startsWith(SRS_DONATION_DOWNLOAD_PATH) && method === 'GET') return downloadRoute(env, request, url);
  if (path === `${SRS_DONATION_PATH}stats`) {
    if (method !== 'GET') throw new HttpError(405, 'method_not_allowed');
    return json(await publicStats(env), 200, NO_STORE);
  }
  if (path.startsWith(SRS_DONATION_PATH)) {
    const donorId = path.slice(SRS_DONATION_PATH.length);
    if (!DONOR_ID_RE.test(donorId)) throw new HttpError(400, 'bad_donor_id');
    if (method === 'PUT') return putDonation(env, request, donorId, now, ip);
    if (method === 'GET') return getDonation(env, request, donorId);
    if (method === 'DELETE') return deleteDonation(env, request, donorId, now);
    throw new HttpError(405, 'method_not_allowed');
  }
  return null;
}
