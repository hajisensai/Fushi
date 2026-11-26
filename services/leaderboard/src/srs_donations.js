// SRS 复习历史捐赠（给 anki-rwkv 训练调度模型；设计 docs/specs/2026-11-26-srs-review-donation.md，迁移 0027）。
//
// 身份：客户端由 profileUid 派生 donorId（32 位小写 hex）与 donorKey（64 位 hex，Bearer 凭据）。
// 服务端只存 key_hash = hex(sha256(donorKey 的小写形式按 UTF-8))；第一次上传的 key 认领该 donorId，
// 之后同一 donorId 的上传 / 查询 / 撤回都必须带同一把 key，否则 403 donor_key_mismatch。
//
// 接口：
//   PUT    /v1/srs-donations/:donorId   [Bearer donorKey] body = .apkg 原始字节（application/octet-stream，流式写 R2）
//          头 Content-Length（必须，≤ 64 MiB）、x-donation-reviews / x-donation-cards（非负整数）、
//          x-donation-app-version（可选，≤ 64 个 [A-Za-z0-9.+_-]）。魔数必须是 zip（PK\x03\x04）。
//          → 200 {donated: true, updatedAt}。同一 donorId 重传覆盖 R2 `srs-donations/<donorId>.apkg`。
//          限流：每 donorId 每小时 2 次（429 rate_limited）；每 IP 每 UTC 日 128 MiB（429 upload_quota_daily，
//          按声明长度计，传失败不退）；全局扣 media 日预算 1 次 + write_rows；字节占 budget.js 的「大附件」池
//          （'video'，满了 507 video_quota）。曾撤回、撤回尚未报告给作者的，删掉那条撤回记录。
//          成功后数捐赠者，第一次 ≥ 30 时写里程碑 donors_30 并后台 POST Discord webhook
//          （secret DONATION_NOTIFY_WEBHOOK，可选 DONATION_NOTIFY_MENTION；没配只记日志）。
//   GET    /v1/srs-donations/:donorId   [Bearer donorKey] → 200 {donated, reviews, cards, updatedAt}；无记录 {donated: false}
//   DELETE /v1/srs-donations/:donorId   [Bearer donorKey] → 删 R2 + 行、写撤回记录 → 200 {donated: false}；无记录也 200（不写撤回）
//
// 管理（HTTP Basic，ADMIN_USER / ADMIN_PASS，admin.js checkBasicAuth）：
//   POST   /v1/admin/srs-donations/batch → 快照当前全部捐赠 + 尚未报告的撤回 ID，签发随机 32 字节 token（30 天有效）
//          → 200 {url, token, expiresAt, donors, reviews, withdrawn}。CLI：node scripts/srs_donation_batch.mjs
//   GET    /v1/admin/srs-donations       → 统计 {donors, reviews, cards, bytes, pendingWithdrawals, milestones, batches}
//
// 批次下载（链接里的 token 即凭据，无其他认证；过期 404）：
//   GET /d/srs-donations/<token>/                 JSON 清单 {createdAt, expiresAt, files:[{donorId, reviews, cards, bytes,
//                                                 updatedAt, url}], withdrawn:[donorId], withdrawnUrl}
//                                                 （files 只列快照里、此刻仍未撤回的；值取当前行——快照后重传的给新文件）
//   GET /d/srs-donations/<token>/<donorId>.apkg   attachment / application/octet-stream；不在快照里或快照后已撤回 → 404
//   GET /d/srs-donations/<token>/withdrawn.txt    撤回 ID，一行一个
//
// 已知取舍：同一 donorId 两把不同 key 并发「首次上传」时，后到的那次在写行时才发现冲突（409 conflict），
// 但 R2 对象已被它覆盖；donorId 由 profileUid 派生，能撞上的人本就能拿到 donorKey，按 spec 接受。

import { HttpError, hex, json, sha256 } from './util.js';
import { DAY, HOUR, hit } from './ratelimit.js';
import { deleteMedia, releaseMediaBytes, reserveMediaBytes, spend } from './budget.js';
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
  batchTtlMs: 30 * DAY,
  milestoneDonors: 30,
  maxCount: 1e9,
};

/** 一次上传的估算写入行数（捐赠行 + 撤回清理 + 里程碑 + 限流 / 预算计数）。 */
const UPLOAD_WRITE_ROWS = 8;
const DELETE_WRITE_ROWS = 4;
const POOL = 'video';
const ZIP_MAGIC = [0x50, 0x4b, 0x03, 0x04];

export const DONOR_ID_RE = /^[0-9a-f]{32}$/;
const DONOR_KEY_RE = /^[0-9a-fA-F]{64}$/;
const BATCH_TOKEN_RE = /^[0-9a-f]{64}$/;
const APP_VERSION_RE = /^[A-Za-z0-9.+_-]{1,64}$/;
export const MILESTONE_DONORS_30 = 'donors_30';

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
async function putDonation(env, request, donorId, now, ctx, ip) {
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
  let reserved = false;
  try {
    const head = await readHead(reader, ZIP_MAGIC.length);
    if (head.length < ZIP_MAGIC.length || ZIP_MAGIC.some((b, i) => head[i] !== b)) {
      throw new HttpError(415, 'not_a_zip');
    }
    await hit(env, `srsdon:ip:${ip}`, DAY, SRS_DONATION_LIMITS.bytesPerIpDay, now, length, 'upload_quota_daily');
    await spend(env, 'media', 1, now);
    await spend(env, 'write_rows', UPLOAD_WRITE_ROWS, now);
    await reserveMediaBytes(env, length, POOL);
    reserved = true;
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
      // 并发首次上传撞上了别的 key（文件头「已知取舍」）：行归先到的那把 key，配额池可能多记一份，接受。
      throw new HttpError(409, 'conflict');
    }
    if (existing && existing.bytes) await releaseMediaBytes(env, existing.bytes, POOL);
    await env.DB.prepare('DELETE FROM srs_donation_withdrawals WHERE donor_id = ?1 AND reported_batch IS NULL')
      .bind(donorId).run();
    await checkMilestone(env, now, ctx);
    return json({ donated: true, updatedAt: now }, 200, NO_STORE);
  } catch (e) {
    await reader.cancel().catch(() => {});
    if (reserved) await releaseMediaBytes(env, length, POOL);
    throw e;
  }
}

/**
 * 捐赠者数第一次 ≥ 30：写里程碑（主键保证只一次），后台通知所有者。
 * @returns {Promise<boolean>} 本次是否刚达成
 */
async function checkMilestone(env, now, ctx) {
  const stats = await env.DB.prepare('SELECT COUNT(*) AS n, COALESCE(SUM(reviews), 0) AS r FROM srs_donations').first();
  if (stats.n < SRS_DONATION_LIMITS.milestoneDonors) return false;
  const ins = await env.DB.prepare(
    'INSERT INTO srs_donation_milestones (name, reached_at) VALUES (?1, ?2) ON CONFLICT (name) DO NOTHING',
  ).bind(MILESTONE_DONORS_30, now).run();
  if (ins.meta.changes !== 1) return false;
  const task = notifyMilestone(env, stats.r);
  if (ctx && ctx.waitUntil) ctx.waitUntil(task);
  else await task;
  return true;
}

/**
 * 里程碑通知正文（Discord webhook）。
 * @param {string|undefined} mention DONATION_NOTIFY_MENTION（如 `<@123>`），空则不加
 * @param {number} reviews
 * @returns {string}
 */
export function milestoneMessage(mention, reviews) {
  const prefix = mention && String(mention).trim() ? `${String(mention).trim()} ` : '';
  return `${prefix}SRS review donations reached ${SRS_DONATION_LIMITS.milestoneDonors} donors (${reviews} reviews). `
    + `Create a batch: POST ${SRS_DONATION_ADMIN_PATH}/batch`;
}

/** 不抛：webhook 失败 / 未配置只记日志。测试可用 env.DONATION_FETCH 换掉 fetch。 */
async function notifyMilestone(env, reviews) {
  const content = milestoneMessage(env.DONATION_NOTIFY_MENTION, reviews);
  if (!env.DONATION_NOTIFY_WEBHOOK) {
    console.log(`srs donation milestone (no DONATION_NOTIFY_WEBHOOK): ${content}`);
    return;
  }
  try {
    const doFetch = env.DONATION_FETCH || fetch;
    const res = await doFetch(env.DONATION_NOTIFY_WEBHOOK, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ content }),
    });
    if (!res.ok) console.log(`srs donation milestone webhook failed: HTTP ${res.status}`);
  } catch (e) {
    console.log(`srs donation milestone webhook failed: ${e && e.message ? e.message : e}`);
  }
}

async function getDonation(env, request, donorId) {
  const keyHash = await donorKeyHash(bearerKey(request));
  const row = await authorizedRow(env, donorId, keyHash);
  if (!row) return json({ donated: false }, 200, NO_STORE);
  return json({ donated: true, reviews: row.reviews, cards: row.cards, updatedAt: row.updated_at }, 200, NO_STORE);
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
      `INSERT INTO srs_donation_withdrawals (donor_id, withdrawn_at, reported_batch) VALUES (?1, ?2, NULL)
       ON CONFLICT (donor_id) DO UPDATE SET withdrawn_at = excluded.withdrawn_at, reported_batch = NULL`,
    ).bind(donorId, now),
  ]);
  return json({ donated: false }, 200, NO_STORE);
}

function batchUrl(origin, token) {
  return `${origin}${SRS_DONATION_DOWNLOAD_PATH}${token}/`;
}

/**
 * 生成批次：快照与「把未报告的撤回标成本批」在同一个 batch 里原子完成。
 * @returns {Promise<{url: string, token: string, expiresAt: number, donors: number, reviews: number, withdrawn: number}>}
 */
export async function createDonationBatch(env, origin, now) {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  const token = hex(bytes);
  const expiresAt = now + SRS_DONATION_LIMITS.batchTtlMs;
  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO srs_donation_batches (token, created_at, expires_at, donors_json, withdrawn_json)
       VALUES (?1, ?2, ?3,
         (SELECT json_group_array(json_object('donorId', donor_id, 'reviews', reviews, 'cards', cards, 'bytes', bytes,
            'updatedAt', updated_at)) FROM (SELECT * FROM srs_donations ORDER BY donor_id)),
         (SELECT json_group_array(donor_id) FROM
            (SELECT donor_id FROM srs_donation_withdrawals WHERE reported_batch IS NULL ORDER BY donor_id)))`,
    ).bind(token, now, expiresAt),
    env.DB.prepare('UPDATE srs_donation_withdrawals SET reported_batch = ?1 WHERE reported_batch IS NULL').bind(token),
  ]);
  const row = await env.DB.prepare('SELECT donors_json, withdrawn_json FROM srs_donation_batches WHERE token = ?1')
    .bind(token).first();
  const donors = JSON.parse(row.donors_json);
  return {
    url: batchUrl(origin, token),
    token,
    expiresAt,
    donors: donors.length,
    reviews: donors.reduce((s, d) => s + (d.reviews || 0), 0),
    withdrawn: JSON.parse(row.withdrawn_json).length,
  };
}

async function donationStats(env, origin, now) {
  const s = await env.DB.prepare(
    `SELECT COUNT(*) AS donors, COALESCE(SUM(reviews), 0) AS reviews, COALESCE(SUM(cards), 0) AS cards,
       COALESCE(SUM(bytes), 0) AS bytes FROM srs_donations`,
  ).first();
  const w = await env.DB.prepare('SELECT COUNT(*) AS n FROM srs_donation_withdrawals WHERE reported_batch IS NULL').first();
  const milestones = (await env.DB.prepare('SELECT name, reached_at FROM srs_donation_milestones ORDER BY name').all())
    .results.map((m) => ({ name: m.name, reachedAt: m.reached_at }));
  const batches = (await env.DB.prepare(
    `SELECT token, created_at, expires_at, json_array_length(donors_json) AS donors,
       json_array_length(withdrawn_json) AS withdrawn FROM srs_donation_batches ORDER BY created_at DESC LIMIT 24`,
  ).all()).results.map((b) => ({
    createdAt: b.created_at,
    expiresAt: b.expires_at,
    donors: b.donors,
    withdrawn: b.withdrawn,
    url: b.expires_at > now ? batchUrl(origin, b.token) : null,
  }));
  return { donors: s.donors, reviews: s.reviews, cards: s.cards, bytes: s.bytes, pendingWithdrawals: w.n, milestones, batches };
}

async function liveBatch(env, token, now) {
  if (!BATCH_TOKEN_RE.test(token)) throw new HttpError(404, 'not_found');
  const b = await env.DB.prepare('SELECT * FROM srs_donation_batches WHERE token = ?1').bind(token).first();
  if (!b || b.expires_at <= now) throw new HttpError(404, 'not_found');
  return b;
}

/** 快照里、此刻仍在库（未撤回）的捐赠行。 */
async function batchDonors(env, b) {
  return (await env.DB.prepare(
    `SELECT donor_id, reviews, cards, bytes, updated_at FROM srs_donations
     WHERE donor_id IN (SELECT json_extract(value, '$.donorId') FROM json_each(?1)) ORDER BY donor_id`,
  ).bind(b.donors_json).all()).results;
}

async function downloadRoute(env, url, now) {
  const rest = url.pathname.slice(SRS_DONATION_DOWNLOAD_PATH.length);
  const m = /^([^/]+)(?:\/(.*))?$/.exec(rest);
  if (!m) throw new HttpError(404, 'not_found');
  const b = await liveBatch(env, m[1], now);
  const file = m[2] || '';
  const base = batchUrl(url.origin, m[1]);
  if (file === '') {
    const files = (await batchDonors(env, b)).map((d) => ({
      donorId: d.donor_id,
      reviews: d.reviews,
      cards: d.cards,
      bytes: d.bytes,
      updatedAt: d.updated_at,
      url: `${base}${d.donor_id}.apkg`,
    }));
    const body = {
      format: 'fushi-srs-donation-batch',
      createdAt: b.created_at,
      expiresAt: b.expires_at,
      files,
      withdrawn: JSON.parse(b.withdrawn_json),
      withdrawnUrl: `${base}withdrawn.txt`,
    };
    return new Response(`${JSON.stringify(body, null, 2)}\n`, {
      headers: { 'Content-Type': 'application/json; charset=utf-8', 'X-Robots-Tag': 'noindex, nofollow', ...NO_STORE },
    });
  }
  if (file === 'withdrawn.txt') {
    const ids = JSON.parse(b.withdrawn_json);
    return new Response(ids.length ? `${ids.join('\n')}\n` : '', {
      headers: { 'Content-Type': 'text/plain; charset=utf-8', 'X-Robots-Tag': 'noindex, nofollow', ...NO_STORE },
    });
  }
  const f = /^([0-9a-f]{32})\.apkg$/.exec(file);
  if (!f) throw new HttpError(404, 'not_found');
  const donorId = f[1];
  const inSnapshot = JSON.parse(b.donors_json).some((d) => d.donorId === donorId);
  if (!inSnapshot || !(await donorRow(env, donorId))) throw new HttpError(404, 'not_found');
  const obj = await env.MEDIA.get(donationKey(donorId));
  if (!obj) throw new HttpError(404, 'not_found');
  return new Response(obj.body, {
    headers: {
      'Content-Type': 'application/octet-stream',
      'Content-Length': String(obj.size),
      'Content-Disposition': `attachment; filename="${donorId}.apkg"`,
      'X-Robots-Tag': 'noindex, nofollow',
      ...NO_STORE,
    },
  });
}

/**
 * 本模块的全部路由；路径不归它返回 null。
 * @param {Request} request
 * @param {object} env
 * @param {URL} url
 * @param {number} now
 * @param {object|undefined} ctx
 * @param {string} ip 限流键（worker.js clientIp，IPv6 按 /64）
 * @returns {Promise<Response|null>}
 */
export async function routeSrsDonations(request, env, url, now, ctx, ip) {
  const path = url.pathname;
  const method = request.method;
  if (path === `${SRS_DONATION_ADMIN_PATH}/batch` && method === 'POST') {
    checkBasicAuth(request, env);
    return json(await createDonationBatch(env, url.origin, now), 200, NO_STORE);
  }
  if (path === SRS_DONATION_ADMIN_PATH && method === 'GET') {
    checkBasicAuth(request, env);
    return json(await donationStats(env, url.origin, now), 200, NO_STORE);
  }
  if (path.startsWith(SRS_DONATION_DOWNLOAD_PATH) && method === 'GET') return downloadRoute(env, url, now);
  if (path.startsWith(SRS_DONATION_PATH)) {
    const donorId = path.slice(SRS_DONATION_PATH.length);
    if (!DONOR_ID_RE.test(donorId)) throw new HttpError(400, 'bad_donor_id');
    if (method === 'PUT') return putDonation(env, request, donorId, now, ctx, ip);
    if (method === 'GET') return getDonation(env, request, donorId);
    if (method === 'DELETE') return deleteDonation(env, request, donorId, now);
    throw new HttpError(405, 'method_not_allowed');
  }
  return null;
}
