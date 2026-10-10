// 用户反馈 + 开发者处理（设计：docs/specs/2026-10-08-feedback.md）。
//
// 反馈人（不要求账户；带签名提交时记下账户，开发者能看到昵称）：
//   POST /v1/feedback                         {category, title, body, contact?, meta?, reopenOf?} → 201 {id, ticket, ...}
//                                             reopenOf = {id, ticket}：「问题没解决，重新提交」，新反馈记 parent_id
//   PUT  /v1/feedback/:id/attachments/:slot   [X-Fushi-Ticket] 原始字节；slot = log（gzip）/ s0..s2（截图）
//   POST /v1/feedback/status                  {items:[{id, ticket}] ≤ 50} → 各条进度摘要（凭据不对的条目不返回）
//   GET  /v1/feedback/:id                     [X-Fushi-Ticket] 详情 + 时间线
//   POST /v1/feedback/:id/messages            [X-Fushi-Ticket] {body} 追加说明
//   GET  /v1/feedback/:id/attachments/:slot   [X-Fushi-Ticket] 本人取回自己的截图（s0..s2；日志不回传）
//   POST /v1/feedback/:id/close               [X-Fushi-Ticket] 反馈人标记完成：open / in_progress → closed
//
// 开发者（签名，账户 role = 'dev'；网页处理台 devconsole.js 复用同一组函数）：
//   GET  /v1/dev/feedback?status&cursor&limit&q   q：编号精确匹配，或标题 / 正文包含（LIKE）
//   GET  /v1/dev/feedback/:id
//   GET  /v1/dev/feedback/:id/attachments/:slot[?view=text]   日志可直接解压成文本
//   POST /v1/dev/feedback/:id                 {status?, reply?}
//
// ticket 是提交时服务端生成、只返回这一次的随机串；库里只存 SHA-256。ticket 泄露 = 那一条反馈
// 的进度可被看到 / 被追加回复，影响面只有这一条。附件只能在提交后 24 小时内补传，且每个槽位只收一次，
// 所以 ticket 也拿不来当无限网盘。反馈人取回附件同样只认本条的 ticket，并且只给截图槽位（压缩日志
// 是开发者排查用的，不回传给持有 ticket 的任何人）；按单条反馈每小时限次，响应 no-store + CSP
// `default-src 'none'` + nosniff，内容在上传时已按魔数 / 宽高验过是真图片——上传窗口 24 小时、
// 每槽一次、单张 1.5 MiB、结案 90 天后清除，下载再多也装不进新东西，ticket 当不了网盘。
//
// 成本：提交按 IP 限流 + 全局日预算 feedback；附件扣 media 预算并预占 R2 配额；已结案 90 天的
// 附件由定时任务清掉（purgeFeedbackAttachments），只留文字记录。
//
// 防投毒（feedback_guard.js）：伪装字符剥掉、提示注入 / 链接灌水 / 跨来源重复打标记（flags），
// 同来源同内容 1 小时内重复提交 409；截图按文件头宽高拒收解码炸弹，日志按 gzip ISIZE 拒收
// 解压后过大的、出文本时截流并加「不可信数据」页眉；服务端自记来源（origin）与客户端自报的
// meta 分开；单条反馈追加说明总数有上限。

import { HttpError, b64urlEncode, clampInt, hex, json, randomId, sha256, timingSafeEqual } from './util.js';
import { deleteMedia, reserveMediaBytes, spend } from './budget.js';
import { sniffImage } from './media.js';
import { HOUR, hit } from './ratelimit.js';
import {
  LOG_MAX_DECOMPRESSED,
  LOG_UNTRUSTED_HEADER,
  acceptableDimensions,
  capStream,
  gzipDeclaredSize,
  imageDimensions,
  stripHiddenChars,
  textFlags,
} from './feedback_guard.js';

export const CATEGORIES = ['bug', 'suggestion', 'other'];
export const STATUSES = ['open', 'in_progress', 'resolved', 'wont_fix', 'duplicate', 'closed'];
/** 结案状态：附件到期清理、客户端不再轮询。 */
export const CLOSED_STATUSES = ['resolved', 'wont_fix', 'duplicate', 'closed'];

export const FEEDBACK_LIMITS = {
  titleMax: 120,
  bodyMax: 8000,
  contactMax: 200,
  replyMax: 4000,
  /** 开发者私有：AI 总结 / 开发者批改的字数上限（见 devSaveNotes）。 */
  aiSummaryMax: 4000,
  devNoteMax: 8000,
  metaMaxBytes: 4096,
  screenshots: 3,
  screenshotMaxBytes: 1536 * 1024,
  logMaxBytes: 2 * 1024 * 1024,
  /** 提交后多久内还能补传附件。 */
  attachWindowMs: 24 * HOUR,
  submitPerIpHour: 10,
  messagesPerFeedbackHour: 20,
  statusBatch: 50,
  /** 已结案多久后清掉附件。 */
  attachmentRetentionMs: 90 * 24 * HOUR,
  /** 单条反馈追加说明的累计上限（防止一张回执被拿来无限灌消息）。 */
  messagesPerFeedbackTotal: 100,
  /** 反馈人取回自己截图的次数上限（单条反馈每小时；详情页每次最多 3 张）。 */
  reporterDownloadsPerFeedbackHour: 60,
  /** 反馈人「标记完成」的次数上限（单条反馈每小时；正常只会点一次）。 */
  reporterClosePerFeedbackHour: 5,
  /** 处理台搜索词最长字数。 */
  searchMax: 100,
  /** 同一条反馈最多被重新提交几次（每次都要原反馈已结案，这里再兜一层总量）。 */
  reopensPerFeedback: 5,
  /** 同来源同内容重复提交的拒收窗口。 */
  duplicateWindowMs: HOUR,
  /** 跨来源同内容打 duplicate 标记的回看窗口。 */
  duplicateLookbackMs: 24 * HOUR,
};

const SLOT_RE = /^(log|s[0-2])$/;
const SCREENSHOT_SLOT_RE = /^s[0-2]$/;
export const FEEDBACK_ID_RE = /^[A-Za-z0-9_-]{8,16}$/;

/**
 * 用户文字：去控制字符（保留换行 / 制表）、NFC、剥伪装字符、去首尾空白。剥掉过伪装字符时
 * 把 sink.hidden 置 true（调用方据此打 hidden_chars 标记）。
 */
function cleanText(v, max, field, { required = false } = {}, sink = null) {
  if (v === undefined || v === null) v = '';
  if (typeof v !== 'string') throw new HttpError(400, `bad_${field}`);
  // eslint-disable-next-line no-control-regex
  const stripped = stripHiddenChars(v.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, ''));
  if (stripped.hidden && sink) sink.hidden = true;
  const s = stripped.text.trim();
  if (required && !s) throw new HttpError(400, `missing_${field}`);
  if ([...s].length > max) throw new HttpError(400, `${field}_too_long`);
  return s;
}

/** 客户端上报的设备 / 版本信息：只收一层「字符串 / 数字 / 布尔」键值，整体 ≤ 4KB。 */
export function normalizeMeta(meta) {
  if (meta === undefined || meta === null) return '{}';
  if (typeof meta !== 'object' || Array.isArray(meta)) throw new HttpError(400, 'bad_meta');
  const out = {};
  for (const [k, v] of Object.entries(meta)) {
    if (!/^[A-Za-z0-9_.-]{1,40}$/.test(k)) continue;
    if (typeof v === 'string') out[k] = v.slice(0, 500);
    else if (typeof v === 'number' && Number.isFinite(v)) out[k] = v;
    else if (typeof v === 'boolean') out[k] = v;
  }
  const s = JSON.stringify(out);
  if (new TextEncoder().encode(s).length > FEEDBACK_LIMITS.metaMaxBytes) throw new HttpError(400, 'meta_too_large');
  return s;
}

export function normalizeSubmission(body) {
  if (!body || typeof body !== 'object') throw new HttpError(400, 'bad_json');
  const category = CATEGORIES.includes(body.category) ? body.category : null;
  if (!category) throw new HttpError(400, 'bad_category');
  const sink = { hidden: false };
  const title = cleanText(body.title, FEEDBACK_LIMITS.titleMax, 'title', { required: true }, sink);
  const text = cleanText(body.body, FEEDBACK_LIMITS.bodyMax, 'body', { required: true }, sink);
  const contact = cleanText(body.contact, FEEDBACK_LIMITS.contactMax, 'contact', {}, sink);
  return {
    category,
    title,
    body: text,
    contact,
    meta: normalizeMeta(body.meta),
    flags: textFlags([title, text, contact], sink),
  };
}

/** 判重用的内容指纹：分类 + 标题 + 正文，小写、空白折叠。 */
export async function contentHash(sub) {
  const norm = (t) => t.toLowerCase().replace(/\s+/g, ' ').trim();
  return hex(await sha256(new TextEncoder().encode(`${sub.category}\n${norm(sub.title)}\n${norm(sub.body)}`)));
}

function parseFlags(row) {
  try {
    const list = JSON.parse(row.flags || '[]');
    return Array.isArray(list) ? list.filter((f) => typeof f === 'string') : [];
  } catch {
    return [];
  }
}

/**
 * 服务端自己看到的来源（与客户端自报的 meta 分开展示，伪造不了）：Cloudflare 判定的国家 / ASN、
 * User-Agent 前 200 字、是否带签名提交。
 */
export function requestOrigin(request, signed) {
  const cf = request.cf || {};
  const ua = stripHiddenChars(String(request.headers.get('User-Agent') || '')).text.slice(0, 200);
  return {
    country: typeof cf.country === 'string' ? cf.country : '',
    asn: typeof cf.asn === 'number' ? cf.asn : null,
    ua,
    signed,
  };
}

async function ticketHash(ticket) {
  return hex(await sha256(new TextEncoder().encode(String(ticket))));
}

function parseAttachments(row) {
  try {
    const list = JSON.parse(row.attachments || '[]');
    return Array.isArray(list) ? list : [];
  } catch {
    return [];
  }
}

function publicAttachments(row) {
  return parseAttachments(row).map((a) => ({ slot: a.slot, kind: a.kind, bytes: a.bytes, type: a.type }));
}

/** 读反馈行并核对 ticket；不存在与 ticket 不对一律 404（不区分，免得探测 id）。 */
export async function feedbackForTicket(env, id, ticket) {
  if (!FEEDBACK_ID_RE.test(id || '') || typeof ticket !== 'string' || !ticket) throw new HttpError(404, 'not_found');
  const row = await env.DB.prepare('SELECT * FROM feedback WHERE id = ?1').bind(id).first();
  if (!row || !timingSafeEqual(await ticketHash(ticket), row.ticket_hash)) throw new HttpError(404, 'not_found');
  return row;
}

export async function feedbackById(env, id) {
  if (!FEEDBACK_ID_RE.test(id || '')) throw new HttpError(404, 'not_found');
  const row = await env.DB.prepare('SELECT * FROM feedback WHERE id = ?1').bind(id).first();
  if (!row) throw new HttpError(404, 'not_found');
  return row;
}

function summary(row) {
  return {
    id: row.id,
    parentId: row.parent_id ?? null,
    category: row.category,
    title: row.title,
    status: row.status,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    devReplyAt: row.dev_reply_at ?? null,
    userReplyAt: row.user_reply_at ?? null,
  };
}

/** 开发者侧摘要：多带风险标记（反馈人侧不给，别教投毒者绕过）。 */
function devSummary(row) {
  return { ...summary(row), flags: parseFlags(row) };
}

/** 开发者私有批注（AI 总结 / 开发者批改）：只进开发者出口，反馈人接口永远不带。 */
function devNotes(row) {
  return {
    aiSummary: row.ai_summary ?? null,
    aiSummaryAt: row.ai_summary_at ?? null,
    devNote: row.dev_note ?? null,
    devNoteAt: row.dev_note_at ?? null,
  };
}

async function timeline(env, id) {
  const rows = await env.DB.prepare(
    `SELECT m.id, m.author, m.body, m.status, m.created_at, a.nickname
     FROM feedback_messages m LEFT JOIN accounts a ON a.id = m.account_id
     WHERE m.feedback_id = ?1 ORDER BY m.id`,
  ).bind(id).all();
  return rows.results.map((m) => ({
    id: m.id,
    author: m.author,
    body: m.body,
    status: m.status ?? null,
    createdAt: m.created_at,
    // 只露开发者昵称（反馈人自己的消息不需要名字）。
    nickname: m.author === 'dev' ? (m.nickname ?? null) : null,
  }));
}

/** 反馈人看到的详情：不含开发者内部字段（联系方式原样回给本人无妨，但设备信息不回传，省流量）。 */
/** 被重新提交成了哪几条（新的在后）。 */
async function reopenedAs(env, id) {
  const rows = await env.DB.prepare(
    'SELECT id FROM feedback WHERE parent_id = ?1 ORDER BY created_at, id',
  ).bind(id).all();
  return rows.results.map((r) => r.id);
}

export async function reporterView(env, row) {
  return {
    ...summary(row),
    reopenedAs: await reopenedAs(env, row.id),
    body: row.body,
    attachments: publicAttachments(row),
    messages: await timeline(env, row.id),
  };
}

export async function devView(env, row) {
  const reporter = row.account_id
    ? await env.DB.prepare('SELECT id, nickname, discriminator FROM accounts WHERE id = ?1').bind(row.account_id).first()
    : null;
  let meta = {};
  try {
    meta = JSON.parse(row.meta || '{}');
  } catch {
    meta = {};
  }
  let origin = {};
  try {
    origin = JSON.parse(row.origin || '{}');
  } catch {
    origin = {};
  }
  return {
    ...devSummary(row),
    ...devNotes(row),
    reopenedAs: await reopenedAs(env, row.id),
    body: row.body,
    contact: row.contact,
    meta,
    origin,
    reporter: reporter ? { id: reporter.id, nickname: reporter.nickname, discriminator: reporter.discriminator } : null,
    attachments: publicAttachments(row),
    messages: await timeline(env, row.id),
  };
}

/**
 * POST /v1/feedback。account 可为 null（匿名）；origin 见 [requestOrigin]。
 * 同一来源（账户或 IP）同一内容 1 小时内再交 → 409 duplicate_feedback；不同来源 24 小时内的
 * 同内容只打 duplicate:<先到的 id> 标记（可能是多人遇到同一问题，也可能是换 IP 灌水，交给人判）。
 */
/**
 * 「重新提交」的原反馈：凭它自己的 ticket 取（错一律 404，与其它 ticket 接口同口径）；原反馈须已结案
 * （开发者结案或反馈人标记完成），且被重新提交的次数有上限。没有 reopenOf 返回 null。
 */
async function reopenParent(env, reopenOf) {
  if (reopenOf === undefined || reopenOf === null) return null;
  if (typeof reopenOf !== 'object' || Array.isArray(reopenOf)) throw new HttpError(400, 'bad_reopen');
  const parent = await feedbackForTicket(env, reopenOf.id, reopenOf.ticket);
  if (!CLOSED_STATUSES.includes(parent.status)) throw new HttpError(409, 'parent_not_closed');
  const n = await env.DB.prepare('SELECT COUNT(*) AS n FROM feedback WHERE parent_id = ?1').bind(parent.id).first();
  if (n.n >= FEEDBACK_LIMITS.reopensPerFeedback) throw new HttpError(429, 'too_many_reopens');
  return parent;
}

export async function createFeedback(env, account, ip, body, now, origin = {}) {
  const sub = normalizeSubmission(body);
  const parent = await reopenParent(env, body.reopenOf);
  const hash = await contentHash(sub);
  const source = account ? `acct:${account.id}` : `ip:${ip}`;
  // 重新提交常常原样带着原标题 / 正文：不按「同来源同内容」拒收（每次都要原反馈已结案，另有次数上限）。
  if (!parent) {
    try {
      await hit(env, `feedback:dup:${source}:${hash}`, FEEDBACK_LIMITS.duplicateWindowMs, 1, now);
    } catch (e) {
      if (e instanceof HttpError && e.status === 429) throw new HttpError(409, 'duplicate_feedback');
      throw e;
    }
  }
  await hit(env, `feedback:ip:${ip}`, HOUR, FEEDBACK_LIMITS.submitPerIpHour, now);
  await spend(env, 'feedback', 1, now);
  await spend(env, 'write_rows', 8, now);
  // 与原反馈同内容不算「跨来源重复」（就是它自己）。
  const earlier = await env.DB.prepare(
    `SELECT id FROM feedback WHERE content_hash = ?1 AND created_at > ?2 AND id IS NOT ?3
     ORDER BY created_at LIMIT 1`,
  ).bind(hash, now - FEEDBACK_LIMITS.duplicateLookbackMs, parent ? parent.id : null).first();
  const flags = earlier ? [...sub.flags, `duplicate:${earlier.id}`] : sub.flags;
  const id = randomId(10);
  const ticket = randomId(32);
  await env.DB.prepare(
    `INSERT INTO feedback (id, ticket_hash, account_id, category, title, body, contact, meta, created_at, updated_at,
                           flags, content_hash, origin, parent_id)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?9, ?10, ?11, ?12, ?13)`,
  ).bind(id, await ticketHash(ticket), account ? account.id : null, sub.category, sub.title, sub.body,
    sub.contact, sub.meta, now, JSON.stringify(flags), hash, JSON.stringify(origin), parent ? parent.id : null).run();
  return { id, ticket, status: 'open', createdAt: now, updatedAt: now, parentId: parent ? parent.id : null };
}

function slotKind(slot, bytes) {
  if (slot === 'log') {
    if (bytes.length > FEEDBACK_LIMITS.logMaxBytes) throw new HttpError(413, 'body_too_large');
    // 日志必须是客户端压缩好的 gzip：服务端不替人存未压缩的大文本。
    if (bytes.length < 18 || bytes[0] !== 0x1f || bytes[1] !== 0x8b) throw new HttpError(415, 'not_gzip');
    // 解压炸弹：声明的解压后长度超限直接拒（声明可伪造，出文本时另有截流兜底）。
    if (gzipDeclaredSize(bytes) > LOG_MAX_DECOMPRESSED) throw new HttpError(413, 'log_too_large');
    return { kind: 'log', ext: 'log.gz', type: 'application/gzip' };
  }
  if (bytes.length > FEEDBACK_LIMITS.screenshotMaxBytes) throw new HttpError(413, 'body_too_large');
  const img = sniffImage(bytes);
  if (!img) throw new HttpError(415, 'not_an_image');
  // 解码炸弹：几 KB 的文件可以声明几万像素见方，开发者一打开就把 App / 浏览器撑爆。
  if (!acceptableDimensions(imageDimensions(bytes, img.ext))) throw new HttpError(415, 'bad_image_dimensions');
  return { kind: 'screenshot', ext: img.ext, type: img.type };
}

export const ATTACHMENT_MAX_BYTES = Math.max(FEEDBACK_LIMITS.logMaxBytes, FEEDBACK_LIMITS.screenshotMaxBytes);

/** PUT /v1/feedback/:id/attachments/:slot。同一槽位只收一次（重试拿到 409 slot_taken 即可视为已传）。 */
export async function putAttachment(env, row, slot, bytes, now) {
  if (!SLOT_RE.test(slot)) throw new HttpError(400, 'bad_slot');
  if (now - row.created_at > FEEDBACK_LIMITS.attachWindowMs) throw new HttpError(403, 'attach_window_closed');
  const existing = parseAttachments(row);
  if (existing.some((a) => a.slot === slot)) throw new HttpError(409, 'slot_taken');
  const k = slotKind(slot, bytes);
  await spend(env, 'media', 1, now);
  await reserveMediaBytes(env, bytes.length);
  const key = `f/${row.id}-${slot}-${randomId(8)}.${k.ext}`;
  await env.MEDIA.put(key, bytes, { httpMetadata: { contentType: k.type } });
  const entry = { slot, kind: k.kind, key, bytes: bytes.length, type: k.type };
  // 条件更新：附件列表没被别的请求改过才写入（并发传同一槽位时输家删掉自己的对象）。
  const res = await env.DB.prepare(
    'UPDATE feedback SET attachments = ?2, updated_at = ?3 WHERE id = ?1 AND attachments = ?4',
  ).bind(row.id, JSON.stringify([...existing, entry]), now, row.attachments).run();
  if (res.meta.changes !== 1) {
    await deleteMedia(env, key);
    throw new HttpError(409, 'conflict');
  }
  return { slot, kind: k.kind, bytes: bytes.length };
}

/** POST /v1/feedback/status：批量查进度（App 打开反馈中心时一次拉全）。 */
export async function batchStatus(env, body) {
  const items = body && Array.isArray(body.items) ? body.items : null;
  if (!items) throw new HttpError(400, 'bad_items');
  if (items.length > FEEDBACK_LIMITS.statusBatch) throw new HttpError(400, 'too_many_items');
  // 同一 id 可能带多张回执（客户端重复登记）：任一张对得上就算。
  const wanted = new Map();
  for (const it of items) {
    if (it && typeof it.id === 'string' && FEEDBACK_ID_RE.test(it.id) && typeof it.ticket === 'string') {
      if (!wanted.has(it.id)) wanted.set(it.id, []);
      wanted.get(it.id).push(it.ticket);
    }
  }
  if (wanted.size === 0) return { items: [] };
  const rows = await env.DB.prepare('SELECT * FROM feedback WHERE id IN (SELECT value FROM json_each(?1))')
    .bind(JSON.stringify([...wanted.keys()])).all();
  const out = [];
  for (const row of rows.results) {
    let ok = false;
    for (const t of wanted.get(row.id)) ok = timingSafeEqual(await ticketHash(t), row.ticket_hash) || ok;
    if (ok) out.push(summary(row));
  }
  return { items: out };
}

/** POST /v1/feedback/:id/messages：反馈人追加说明。结案后再追加会把状态拉回 open。 */
export async function addReporterMessage(env, row, body, now) {
  const sink = { hidden: false };
  const text = cleanText(body && body.body, FEEDBACK_LIMITS.replyMax, 'body', { required: true }, sink);
  await hit(env, `feedback:msg:${row.id}`, HOUR, FEEDBACK_LIMITS.messagesPerFeedbackHour, now);
  // 累计上限：原子地占一个名额，满了直接拒（不写消息）。
  const slot = await env.DB.prepare(
    'UPDATE feedback SET message_count = message_count + 1 WHERE id = ?1 AND message_count < ?2',
  ).bind(row.id, FEEDBACK_LIMITS.messagesPerFeedbackTotal).run();
  if (slot.meta.changes !== 1) throw new HttpError(429, 'too_many_messages');
  await spend(env, 'write_rows', 4, now);
  const reopen = CLOSED_STATUSES.includes(row.status) && row.status !== 'duplicate';
  // 只算这条消息新增的标记，合并在 SQL 里做：并发的两条追加说明各自读到的是旧行，
  // 用旧行算好再整列覆盖会互相冲掉对方的标记。
  const added = textFlags([text], sink);
  await env.DB.batch([
    env.DB.prepare(
      'INSERT INTO feedback_messages (feedback_id, author, body, status, created_at) VALUES (?1, \'user\', ?2, ?3, ?4)',
    ).bind(row.id, text, reopen ? 'open' : null, now),
    env.DB.prepare(
      `UPDATE feedback SET user_reply_at = ?2, updated_at = ?2,
         flags = CASE WHEN ?4 = '[]' THEN flags ELSE (
           SELECT json_group_array(value) FROM (
             SELECT value FROM json_each(feedback.flags) UNION SELECT value FROM json_each(?4)))
         END,
         status = CASE WHEN ?3 THEN 'open' ELSE status END
       WHERE id = ?1`,
    ).bind(row.id, now, reopen ? 1 : 0, JSON.stringify(added)),
  ]);
}

/** 反馈人能自己标记完成的状态（开发者已给出结论的不再让反馈人改）。 */
export const REPORTER_CLOSABLE = ['open', 'in_progress'];

/**
 * POST /v1/feedback/:id/close：反馈人凭本条 ticket 把自己的反馈标为已关闭（问题已解决 / 不再需要）。
 * 只做这一种状态变更、不收任何字段；时间线记一条 author = 'user'、status = 'closed' 的事件，
 * 处理台显示为「反馈人标记完成」。要重新打开，照旧追加说明（addReporterMessage 会把状态拉回 open）。
 */
export async function reporterClose(env, row, now) {
  await hit(env, `feedback:close:${row.id}`, HOUR, FEEDBACK_LIMITS.reporterClosePerFeedbackHour, now);
  if (!REPORTER_CLOSABLE.includes(row.status)) throw new HttpError(409, 'not_closable');
  // 条件更新：并发的开发者改状态 / 第二次点击不会被覆盖。
  const res = await env.DB.prepare(
    `UPDATE feedback SET status = 'closed', user_reply_at = ?2, updated_at = ?2
     WHERE id = ?1 AND status IN ('open', 'in_progress')`,
  ).bind(row.id, now).run();
  if (res.meta.changes !== 1) throw new HttpError(409, 'not_closable');
  await env.DB.prepare(
    'INSERT INTO feedback_messages (feedback_id, author, body, status, created_at) VALUES (?1, \'user\', \'\', \'closed\', ?2)',
  ).bind(row.id, now).run();
}

/** 处理台搜索词 → LIKE 模式（转义 % _ \）。空串返回 null。 */
function searchTerm(q) {
  if (typeof q !== 'string') return null;
  const t = q.trim().slice(0, FEEDBACK_LIMITS.searchMax);
  if (!t) return null;
  return { exact: t, like: `%${t.replace(/[\\%_]/g, (c) => `\\${c}`)}%` };
}

/** 开发者处理：改状态和 / 或回复（两者至少一个）。 */
export async function devUpdate(env, dev, row, body, now) {
  const status = body && body.status !== undefined && body.status !== null && body.status !== ''
    ? body.status : null;
  if (status !== null && !STATUSES.includes(status)) throw new HttpError(400, 'bad_status');
  const reply = cleanText(body && body.reply, FEEDBACK_LIMITS.replyMax, 'reply');
  const changed = status !== null && status !== row.status;
  if (!changed && !reply) throw new HttpError(400, 'nothing_to_update');
  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO feedback_messages (feedback_id, author, account_id, body, status, created_at)
       VALUES (?1, 'dev', ?2, ?3, ?4, ?5)`,
    ).bind(row.id, dev.id, reply, changed ? status : null, now),
    env.DB.prepare('UPDATE feedback SET status = ?2, dev_reply_at = ?3, updated_at = ?3 WHERE id = ?1')
      .bind(row.id, changed ? status : row.status, now),
  ]);
}

/**
 * 开发者私有批注：`aiSummary`（AI 代理回写）/ `devNote`（开发者批改），至少给一个；空串 = 清除。
 * 文字照常过 cleanText（剥伪装字符）。不写时间线、不动 updated_at / dev_reply_at——反馈人看不到，
 * 也不该因此亮「有新回复」或让条目在处理台列表里跳到最前。
 */
export const DEV_NOTE_FIELDS = [
  ['aiSummary', 'ai_summary', FEEDBACK_LIMITS.aiSummaryMax],
  ['devNote', 'dev_note', FEEDBACK_LIMITS.devNoteMax],
];

/** 批注文字的唯一清洗口径（接口与 scripts/feedback.mjs 共用）：空白 → null。 */
export function cleanDevNoteText(col, value) {
  const field = DEV_NOTE_FIELDS.find(([, c]) => c === col);
  if (!field) throw new Error(`unknown dev note column: ${col}`);
  return cleanText(value, field[2], col) || null;
}

export async function devSaveNotes(env, row, body, now) {
  const fields = DEV_NOTE_FIELDS
    .filter(([key]) => body && body[key] !== undefined && body[key] !== null);
  if (fields.length === 0) throw new HttpError(400, 'nothing_to_update');
  const sets = fields.map(([, col], i) => `${col} = ?${2 + 2 * i}, ${col}_at = ?${3 + 2 * i}`);
  const args = fields.flatMap(([key, col]) => {
    const text = cleanDevNoteText(col, body[key]);
    return text ? [text, now] : [null, null];
  });
  await env.DB.prepare(`UPDATE feedback SET ${sets.join(', ')} WHERE id = ?1`).bind(row.id, ...args).run();
}

/**
 * 处理台列表：按最近变化倒序，游标 `<updated_at>:<id>`。status = 'active' 表示未结案（open + in_progress）。
 */
export async function devList(env, { status, cursor, limit, q }) {
  const n = clampInt(limit, 1, 100, 30);
  let after = null;
  if (typeof cursor === 'string' && /^\d+:[A-Za-z0-9_-]{1,16}$/.test(cursor)) {
    const i = cursor.indexOf(':');
    after = { at: Number(cursor.slice(0, i)), id: cursor.slice(i + 1) };
  }
  const cols = 'id, category, title, status, created_at, updated_at, dev_reply_at, user_reply_at, account_id, attachments, flags, parent_id, '
    + 'ai_summary, dev_note IS NOT NULL AS has_dev_note';
  const page = after
    ? 'AND (updated_at < ?2 OR (updated_at = ?2 AND id < ?3))'
    : 'AND ?2 IS NULL AND ?3 IS NULL';
  // 搜索：编号精确匹配，或标题 / 正文包含（SQLite LIKE 对 ASCII 不分大小写）。
  const term = searchTerm(q);
  const search = term
    ? 'AND (id = ?5 OR title LIKE ?6 ESCAPE \'\\\' OR body LIKE ?6 ESCAPE \'\\\')'
    : 'AND ?5 IS NULL AND ?6 IS NULL';
  let sql;
  let first;
  if (status === 'flagged') {
    // 带风险标记的反馈（量小，按更新时间索引顺扫过滤即可）。
    sql = `SELECT ${cols} FROM feedback WHERE flags != '[]' ${page} ${search} ORDER BY updated_at DESC, id DESC LIMIT ?4`;
    first = null;
  } else if (status === 'active') {
    sql = `SELECT ${cols} FROM feedback WHERE status IN ('open', 'in_progress') ${page} ${search}
           ORDER BY updated_at DESC, id DESC LIMIT ?4`;
    first = null;
  } else if (STATUSES.includes(status)) {
    sql = `SELECT ${cols} FROM feedback WHERE status = ?1 ${page} ${search} ORDER BY updated_at DESC, id DESC LIMIT ?4`;
    first = status;
  } else {
    sql = `SELECT ${cols} FROM feedback WHERE (?1 IS NULL) ${page} ${search} ORDER BY updated_at DESC, id DESC LIMIT ?4`;
    first = null;
  }
  const rows = await env.DB.prepare(sql)
    .bind(first, after ? after.at : null, after ? after.id : null, n + 1,
      term ? term.exact : null, term ? term.like : null).all();
  const list = rows.results.slice(0, n).map((r) => ({
    ...devSummary(r),
    hasAccount: r.account_id !== null,
    attachments: parseAttachments(r).length,
    aiSummary: r.ai_summary ?? null,
    hasDevNote: Boolean(r.has_dev_note),
    // 反馈人在开发者上次处理之后又说话了 → 处理台标「新消息」。
    awaitingDev: r.user_reply_at !== null && (r.dev_reply_at === null || r.user_reply_at > r.dev_reply_at),
  }));
  const last = rows.results[n - 1];
  return { items: list, next: rows.results.length > n ? `${last.updated_at}:${last.id}` : null };
}

/** 开发者取附件。日志可带 ?view=text 在服务端解压成纯文本（流式，不占内存）。 */
export async function attachmentResponse(env, row, slot, asText) {
  const a = parseAttachments(row).find((x) => x.slot === slot);
  if (!a) throw new HttpError(404, 'not_found');
  const obj = await env.MEDIA.get(a.key);
  if (!obj) throw new HttpError(404, 'not_found');
  const headers = {
    'Cache-Control': 'private, no-store',
    'X-Content-Type-Options': 'nosniff',
  };
  if (a.kind === 'log' && asText) {
    const src = obj.body instanceof ReadableStream ? obj.body : new Response(obj.body).body;
    // 页眉先行（读者无论人还是 AI 都先看到「这是不可信数据」），解压结果截流防伪造 ISIZE 的炸弹。
    const header = new TextEncoder().encode(LOG_UNTRUSTED_HEADER);
    const body = src.pipeThrough(new DecompressionStream('gzip')).pipeThrough(capStream(LOG_MAX_DECOMPRESSED));
    const out = new ReadableStream({
      async start(controller) {
        controller.enqueue(header);
        const reader = body.getReader();
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          controller.enqueue(value);
        }
        controller.close();
      },
    });
    return new Response(out, {
      headers: { ...headers, 'Content-Type': 'text/plain; charset=utf-8' },
    });
  }
  return new Response(obj.body, {
    headers: {
      ...headers,
      'Content-Type': a.type,
      ...(a.kind === 'log' ? { 'Content-Disposition': `attachment; filename="fushi-${row.id}.log.gz"` } : {}),
    },
  });
}

/**
 * 反馈人取回自己的截图（调用方已用 feedbackForTicket 核对过 ticket）。日志槽位与不存在的槽位一律
 * 404（不区分，免得探测）；单条反馈按小时限次。
 */
export async function reporterAttachmentResponse(env, row, slot, now) {
  if (!SCREENSHOT_SLOT_RE.test(slot)) throw new HttpError(404, 'not_found');
  if (!parseAttachments(row).some((a) => a.slot === slot && a.kind === 'screenshot')) {
    throw new HttpError(404, 'not_found');
  }
  await hit(env, `feedback:get:${row.id}`, HOUR, FEEDBACK_LIMITS.reporterDownloadsPerFeedbackHour, now);
  const res = await attachmentResponse(env, row, slot, false);
  res.headers.set('Content-Security-Policy', "default-src 'none'");
  return res;
}

export function requireDev(account) {
  if (!account || account.role !== 'dev') throw new HttpError(403, 'not_developer');
  return account;
}

/** 已结案超过保留期的反馈：删 R2 附件、清空附件列表（每次定时任务最多处理 limit 条）。 */
export async function purgeFeedbackAttachments(env, now, limit = 20) {
  const rows = await env.DB.prepare(
    `SELECT id, attachments FROM feedback
     WHERE status IN ('resolved', 'wont_fix', 'duplicate', 'closed') AND attachments != '[]' AND updated_at < ?1
     LIMIT ?2`,
  ).bind(now - FEEDBACK_LIMITS.attachmentRetentionMs, limit).all();
  for (const row of rows.results) {
    await deleteMedia(env, parseAttachments(row).map((a) => a.key));
    await env.DB.prepare('UPDATE feedback SET attachments = \'[]\' WHERE id = ?1').bind(row.id).run();
  }
  return rows.results.length;
}

// ---- 路由（worker.js 在通用读 / 写分发之前调用） ----

const ID = '([A-Za-z0-9_-]{8,16})';
const RE = {
  submit: /^\/v1\/feedback$/,
  status: /^\/v1\/feedback\/status$/,
  one: new RegExp(`^/v1/feedback/${ID}$`),
  attach: new RegExp(`^/v1/feedback/${ID}/attachments/([a-z0-9]{1,4})$`),
  messages: new RegExp(`^/v1/feedback/${ID}/messages$`),
  close: new RegExp(`^/v1/feedback/${ID}/close$`),
  devList: /^\/v1\/dev\/feedback$/,
  devOne: new RegExp(`^/v1/dev/feedback/${ID}$`),
  devAttach: new RegExp(`^/v1/dev/feedback/${ID}/attachments/([a-z0-9]{1,4})$`),
  devNotes: new RegExp(`^/v1/dev/feedback/${ID}/notes$`),
};

export function isFeedbackPath(path) {
  return path.startsWith('/v1/feedback') || path.startsWith('/v1/dev/');
}

/**
 * @param {Request} request
 * @param {any} env
 * @param {URL} url
 * @param {number} now
 * @param {{
 *   ip: string,
 *   readBody: (max: number) => Promise<Uint8Array>,
 *   parse: (bytes: Uint8Array) => any,
 *   auth: (bytes: Uint8Array, opts: object) => Promise<any>,
 * }} io
 */
export async function routeFeedback(request, env, url, now, io) {
  const path = url.pathname;
  const method = request.method;
  const ticket = request.headers.get('X-Fushi-Ticket') || '';
  const noStore = { 'Cache-Control': 'no-store' };
  let m;

  if (method === 'POST' && RE.submit.test(path)) {
    const bytes = await io.readBody(16 * 1024);
    // 带签名 = 关联账户（验签失败照常 401，别静默降成匿名）。
    const account = request.headers.get('X-Fushi-Account') ? await io.auth(bytes, { mutating: true }) : null;
    const origin = requestOrigin(request, account !== null);
    return json(await createFeedback(env, account, io.ip, io.parse(bytes), now, origin), 201, noStore);
  }
  if (method === 'POST' && RE.status.test(path)) {
    const bytes = await io.readBody(16 * 1024);
    return json(await batchStatus(env, io.parse(bytes)), 200, noStore);
  }
  if (method === 'GET' && (m = RE.one.exec(path))) {
    return json(await reporterView(env, await feedbackForTicket(env, m[1], ticket)), 200, noStore);
  }
  if (method === 'POST' && (m = RE.close.exec(path))) {
    const row = await feedbackForTicket(env, m[1], ticket);
    await reporterClose(env, row, now);
    return json(await reporterView(env, await feedbackById(env, row.id)), 200, noStore);
  }
  if (method === 'GET' && (m = RE.attach.exec(path))) {
    return reporterAttachmentResponse(env, await feedbackForTicket(env, m[1], ticket), m[2], now);
  }
  if (method === 'PUT' && (m = RE.attach.exec(path))) {
    const row = await feedbackForTicket(env, m[1], ticket);
    const bytes = await io.readBody(ATTACHMENT_MAX_BYTES);
    return json(await putAttachment(env, row, m[2], bytes, now), 201, noStore);
  }
  if (method === 'POST' && (m = RE.messages.exec(path))) {
    const row = await feedbackForTicket(env, m[1], ticket);
    const bytes = await io.readBody(16 * 1024);
    await addReporterMessage(env, row, io.parse(bytes), now);
    return json(await reporterView(env, await feedbackById(env, row.id)), 201, noStore);
  }

  if (method === 'GET' && RE.devList.test(path)) {
    requireDev(await io.auth(new Uint8Array(), {}));
    const q = url.searchParams;
    return json(await devList(env, {
      status: q.get('status'), cursor: q.get('cursor'), limit: q.get('limit'), q: q.get('q'),
    }), 200, noStore);
  }
  if (method === 'GET' && (m = RE.devOne.exec(path))) {
    requireDev(await io.auth(new Uint8Array(), {}));
    return json(await devView(env, await feedbackById(env, m[1])), 200, noStore);
  }
  if (method === 'GET' && (m = RE.devAttach.exec(path))) {
    requireDev(await io.auth(new Uint8Array(), {}));
    return attachmentResponse(env, await feedbackById(env, m[1]), m[2], url.searchParams.get('view') === 'text');
  }
  if (method === 'POST' && (m = RE.devOne.exec(path))) {
    const bytes = await io.readBody(16 * 1024);
    const dev = requireDev(await io.auth(bytes, { mutating: true }));
    const row = await feedbackById(env, m[1]);
    await devUpdate(env, dev, row, io.parse(bytes), now);
    return json(await devView(env, await feedbackById(env, row.id)), 200, noStore);
  }
  if (method === 'POST' && (m = RE.devNotes.exec(path))) {
    const bytes = await io.readBody(64 * 1024);
    requireDev(await io.auth(bytes, { mutating: true }));
    const row = await feedbackById(env, m[1]);
    await devSaveNotes(env, row, io.parse(bytes), now);
    return json(await devView(env, await feedbackById(env, row.id)), 200, noStore);
  }
  return null;
}

/** 网页处理台会话 token（Cookie 值）；库里只存 SHA-256。 */
export function newSessionToken() {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return b64urlEncode(bytes);
}
