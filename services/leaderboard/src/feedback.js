// 用户反馈 + 开发者处理（设计：docs/specs/2026-10-08-feedback.md）。
//
// 反馈人（不要求账户；带签名提交时记下账户，开发者能看到昵称）：
//   POST /v1/feedback                         {category, title, body, contact?, meta?, reopenOf?, installId?} → 201 {id, ticket, ...}
//                                             installId：客户端安装 id（installs.js，勾选「附带设备信息」才带；不合法当没带）
//                                             可带安装证明头（X-Fushi-Install-*，installs.js verifyInstallProof）：
//                                             验过记 install_verified = 1；验不过不拒收反馈，丢掉这个不可信的
//                                             installId（不关联任何安装），反馈照常落库
//                                             reopenOf = {id, ticket}：「问题没解决，重新提交」，新反馈记 parent_id
//                                             submissionKey：客户端为「这一次提交」生成的随机密钥（32–64 位 base64url），
//                                             重试复用同一个。同一个 key 再来一次 → 原样回同一张回执（同 id、同 ticket），
//                                             不新建反馈、不再计限流 / 预算（见 createFeedback 幂等说明）
//   PUT  /v1/feedback/:id/attachments/:slot   [X-Fushi-Ticket] 原始字节；slot = log（gzip）/ s0..s2（截图）
//                                             / v0（视频 mp4 / mov / webm ≤ 50 MB，流式写 R2，见 putVideoAttachment）
//   POST /v1/feedback/status                  {items:[{id, ticket}] ≤ 50} → 各条进度摘要（凭据不对的条目不返回）
//   GET  /v1/feedback/mine?cursor&limit       [签名] 本账户提交过的反馈（跨设备看自己的工单），摘要 + 游标分页
//   GET  /v1/feedback/:id                     [凭据] 详情 + 时间线
//   POST /v1/feedback/:id/messages            [凭据] {body} 追加说明
//   GET  /v1/feedback/:id/attachments/:slot   [凭据] 本人取回自己的截图（s0..s2；日志 / 视频不回传）
//   POST /v1/feedback/:id/close               [凭据] 反馈人标记完成：open / in_progress → closed
//   [凭据] = X-Fushi-Ticket（本条回执），或提交时所用账户的签名（feedbackForReporter）；二者择一，
//   带了 ticket 就只认 ticket。匿名提交的反馈只能凭 ticket。补传附件（PUT）只认 ticket——签名要覆盖
//   整个请求体，视频没法边收边验。
//   PUT / DELETE /v1/feedback/:id/push        [凭据] {token, lang?} 登记 / 注销 APNs 推送令牌（feedback_push.js）
//
// 开发者（签名，账户 role = 'dev'；网页处理台 devconsole.js 复用同一组函数）：
//   GET  /v1/dev/feedback?status&cursor&limit&q   q：编号精确匹配，或标题 / 正文包含（LIKE）
//   GET  /v1/dev/feedback/:id
//   GET  /v1/dev/feedback/:id/attachments/:slot[?view=text|download=1]   日志可直接解压成文本；
//                                             视频支持 Range（浏览器拖进度条），download=1 作为附件下载
//   POST /v1/dev/feedback/:id                 {status?, reply?}
//   POST /v1/dev/feedback/:id/notes           {aiSummary?, devNote?}
//
// CI（Authorization: Bearer <env.FEEDBACK_CI_TOKEN>；没配该 secret 时一律 404，token 不对 401）：
//   POST /v1/ci/feedback/fixed                {sha, ids ≤ 50, scope: app|none} → {updated, unchanged, missing}
//                                             写修复 commit、fixed_in 重置；open / in_progress → resolved；
//                                             sha 与 scope 都没变的幂等跳过（进 unchanged，发布进度保留）
//   GET  /v1/ci/feedback/pending?channel&platform   → {items:[{id, sha}]}：scope app、180 天内、该通道平台未回填
//   POST /v1/ci/feedback/released             {channel, platform, version, ids:[{id, sha}] ≤ 500} → {updated}
//                                             只记最早包含修复的版本（已有记录不覆盖）；当前 fix_sha ≠ 该条 sha
//                                             （其间被重新标记修复）的静默跳过；只写 fixed_in，
//                                             不刷 dev_reply_at / updated_at（回填不是开发者回复）
// 反馈人 / 开发者接口的摘要都带 `fix`（null 或 {sha, scope, at, releases}，见 fixView）。
//
// ticket 是提交时服务端生成、只返回这一次的随机串；库里只存 SHA-256。ticket 泄露 = 那一条反馈
// 的进度可被看到 / 被追加回复，影响面只有这一条。附件只能在提交后 24 小时内补传，且每个槽位只收一次，
// 所以 ticket 也拿不来当无限网盘。反馈人取回附件同样只认本条的凭据，并且只给截图槽位（压缩日志
// 是开发者排查用的、视频太大省流量，都不回传给反馈人）；按单条反馈每小时限次，响应 no-store + CSP
// `default-src 'none'` + nosniff，内容在上传时已按魔数 / 宽高验过是真图片——上传窗口 24 小时、
// 每槽一次、单张 1.5 MiB、结案 90 天后清除，下载再多也装不进新东西，ticket 当不了网盘。
//
// 成本：提交按 IP 限流 + 全局日预算 feedback；附件扣 media 预算并预占 R2 配额；已结案 90 天的
// 附件由定时任务清掉（purgeFeedbackAttachments），只留文字记录。视频另有更短的保留期：创建 30 天
// 或结案 7 天（先到者）即删（purgeFeedbackVideos，按 has_video 部分索引有界读）。视频占单独的
// R2 配额池（budget.js 'video'，默认 1 GiB，满了 507 video_quota，不挤占头像 / 封面 / 截图那份），
// 并按上传 IP 每天限总字节数（videoBytesPerIpDay），一个 IP 不能独占视频池。
//
// 防投毒（feedback_guard.js）：伪装字符剥掉、提示注入 / 链接灌水 / 跨来源重复打标记（flags），
// 同来源同内容 1 小时内重复提交 409；截图按文件头宽高拒收解码炸弹，日志按 gzip ISIZE 拒收
// 解压后过大的、出文本时截流并加「不可信数据」页眉；服务端自记来源（origin）与客户端自报的
// meta 分开；单条反馈追加说明总数有上限。

import { HttpError, b64urlEncode, background, clampInt, hex, json, randomId, sha256, timingSafeEqual } from './util.js';
import { adjustSpend, deleteMedia, releaseMediaBytes, reserveMediaBytes, spend } from './budget.js';
import { sniffImage } from './media.js';
import { installTrail, normalizeInstallId, verifyInstallProof } from './installs.js';
import { DAY, HOUR, hit } from './ratelimit.js';
import { clearFeedbackPushTokens, notifyFeedbackUpdate, registerPushToken, unregisterPushToken } from './feedback_push.js';
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
  /** 视频附件（槽位 v0）单个上限。 */
  videoMaxBytes: 50 * 1024 * 1024,
  /**
   * 每个上传 IP 每天（UTC 日窗口）视频总字节上限（按声明长度计，传失败不退）：4 段满额视频。
   * 匿名每 IP 每小时能提 10 条反馈、每条一个 50 MB 视频，没有这一道时一个 IP 一小时就能占掉 500 MB。
   */
  videoBytesPerIpDay: 200 * 1024 * 1024,
  /** 视频在结案后保留多久（与创建后保留期取先到者）。 */
  videoRetentionAfterCloseMs: 7 * 24 * HOUR,
  /** 视频自创建起最多保留多久（未结案也删）。 */
  videoRetentionMs: 30 * 24 * HOUR,
  /** 「我的反馈」每页条数（默认 / 上限）。 */
  minePageDefault: 30,
  minePageMax: 50,
  /** CI：一次标记修复最多几条（一个 PR / commit 引用的反馈）。 */
  ciFixedIds: 50,
  /** CI：一次回填发布最多几条；pending 一次最多返回几条。 */
  ciReleasedIds: 500,
  ciPendingMax: 500,
  /** CI：标记修复超过这么久还没发布的不再回填（pending 不再列出）。 */
  ciPendingWindowMs: 180 * 24 * HOUR,
};

/** 修复追踪（迁移 0009）的取值域；接口与 scripts/feedback.mjs 共用。 */
export const FIX_SHA_RE = /^[0-9a-f]{40}$/;
export const FIX_SCOPES = ['app', 'none'];
export const RELEASE_CHANNELS = ['debug', 'beta', 'stable'];
export const RELEASE_PLATFORMS = ['android', 'windows', 'macos', 'ios', 'linux'];
export const RELEASE_VERSION_RE = /^[A-Za-z0-9.+-]{1,64}$/;

const SLOT_RE = /^(log|s[0-2]|v0)$/;
const VIDEO_SLOT = 'v0';
/** 视频上传时客户端声明的 Content-Type 白名单（存库的类型以魔数嗅探为准）。 */
const VIDEO_TYPES = ['video/mp4', 'video/webm', 'video/quicktime'];
const VIDEO_EXT = { 'video/mp4': 'mp4', 'video/quicktime': 'mov', 'video/webm': 'webm' };
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
  // 换行先归一成 \n：网页表单提交的是 CRLF，不归一的话一个换行按 2 个字计（浏览器 maxlength 按 1 个），
  // 网页与 App 存进去的同一段文字也会是两种换行。
  const stripped = stripHiddenChars(v.replace(/\r\n?/g, '\n')
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, ''));
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
  // 正文可空：很多反馈一句标题就说清了，强制写详情只会逼人填「无」（反馈 JHR0a8mT5M）。
  const text = cleanText(body.body, FEEDBACK_LIMITS.bodyMax, 'body', {}, sink);
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

/**
 * 反馈人接口的凭据：带了非空 X-Fushi-Ticket 就只认 ticket（与原先一致）；否则带 X-Fushi-Account 时
 * 验签（bytes = 已读的请求体，mutating = 写请求防重放），反馈须是该账户提交的。不存在、不是你的、
 * 匿名提交（account_id 为 NULL）、什么凭据都没带，一律 404（不区分，免得探测 id）。签名本身不对照常
 * 401（那是签名者的问题，与这条反馈存不存在无关）。
 */
export async function feedbackForReporter(request, env, id, io, bytes, { mutating = false } = {}) {
  const ticket = request.headers.get('X-Fushi-Ticket') || '';
  if (ticket) return feedbackForTicket(env, id, ticket);
  if (!request.headers.get('X-Fushi-Account') || !FEEDBACK_ID_RE.test(id || '')) {
    throw new HttpError(404, 'not_found');
  }
  const account = await io.auth(bytes, { mutating });
  const row = await env.DB.prepare('SELECT * FROM feedback WHERE id = ?1').bind(id).first();
  if (!row || row.account_id === null || row.account_id !== account.id) throw new HttpError(404, 'not_found');
  return row;
}

/**
 * 修复追踪的线格式：null（未标记修复）或 {sha, scope, at, releases}；releases =
 * {"<channel>": {"<platform>": {version, at}}}，只出白名单里的通道 / 平台，坏 JSON 当空。
 */
export function fixView(row) {
  if (!row.fix_sha) return null;
  let parsed = {};
  try {
    parsed = JSON.parse(row.fixed_in || '{}');
  } catch {
    parsed = {};
  }
  const releases = {};
  for (const ch of RELEASE_CHANNELS) {
    const per = parsed && typeof parsed === 'object' ? parsed[ch] : null;
    if (!per || typeof per !== 'object') continue;
    for (const pf of RELEASE_PLATFORMS) {
      const r = per[pf];
      if (r && typeof r === 'object' && typeof r.version === 'string') {
        (releases[ch] ||= {})[pf] = { version: r.version, at: typeof r.at === 'number' ? r.at : null };
      }
    }
  }
  return { sha: row.fix_sha, scope: row.fix_scope === 'none' ? 'none' : 'app', at: row.fix_at ?? null, releases };
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
    fix: fixView(row),
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
    ? await env.DB.prepare('SELECT id, nickname, discriminator, role FROM accounts WHERE id = ?1').bind(row.account_id).first()
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
    reporter: reporter
      ? { id: reporter.id, nickname: reporter.nickname, discriminator: reporter.discriminator, isDev: reporter.role === 'dev' }
      : null,
    attachments: publicAttachments(row),
    messages: await timeline(env, row.id),
    install: await installTrail(env, row.install_id, row.id, row.install_verified === 1),
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
  // 次数上限在这里只做提前拒收（省掉后面的限流 / 预算消耗）；真正的门是 INSERT 里的条件，
  // 先 COUNT 再 INSERT 两步之间并发的重新提交都会读到同一个旧计数。
  if (await reopenCount(env, parent.id) >= FEEDBACK_LIMITS.reopensPerFeedback) {
    throw new HttpError(429, 'too_many_reopens');
  }
  return parent;
}

async function reopenCount(env, parentId) {
  const n = await env.DB.prepare('SELECT COUNT(*) AS n FROM feedback WHERE parent_id = ?1').bind(parentId).first();
  return n.n;
}

/**
 * 反馈附带的安装：没带证明头 → 自报 id、未验证；证明验过 → 已验证；证明验不过 → 不记 id。
 * 只吞证明本身的 401（格式漂移 / 难度调整 / 伪造），D1 之类的真错误照常抛出。
 */
export async function feedbackInstall(env, request, body, bytes, now) {
  const installId = body && typeof body === 'object' ? normalizeInstallId(body.installId) : null;
  try {
    const verified = await verifyInstallProof(env, request, installId, bytes, now);
    return { installId, verified };
  } catch (e) {
    if (e instanceof HttpError && e.status === 401) return { installId: null, verified: false };
    throw e;
  }
}

const SUBMISSION_KEY_RE = /^[A-Za-z0-9_-]{32,64}$/;

/** 提交幂等键：没带 = null（旧客户端 / 网页表单照旧）；带了但格式不对直接 400，别悄悄失去幂等。 */
export function normalizeSubmissionKey(v) {
  if (v === undefined || v === null) return null;
  if (typeof v !== 'string' || !SUBMISSION_KEY_RE.test(v)) throw new HttpError(400, 'bad_submission_key');
  return v;
}

/** 库里只存幂等键的哈希（与 ticket 同理：拿到库也重放不出回执）。 */
async function submissionHash(key) {
  return hex(await sha256(new TextEncoder().encode(`fushi-feedback-submission\n${key}`)));
}

/**
 * 带幂等键的提交，ticket 由键派生（与 randomId(32) 同字母表同长度）。键是客户端本机生成的随机密钥、只经
 * TLS 发给服务端，等价于「客户端自己出 ticket」：知道键的只有提交者本人。这样重试时服务端不必存 ticket
 * 明文也能回出同一张回执。
 */
async function ticketFromSubmissionKey(key) {
  return b64urlEncode(await sha256(new TextEncoder().encode(`fushi-feedback-ticket\n${key}`))).slice(0, 32);
}

/** 同一个幂等键已经建过的反馈 → 原样回执；没有 → null。 */
async function replaySubmission(env, keyHash, key) {
  const row = await env.DB.prepare(
    'SELECT id, ticket_hash, status, created_at, updated_at, parent_id FROM feedback WHERE submission_hash = ?1',
  ).bind(keyHash).first();
  if (!row) return null;
  const ticket = await ticketFromSubmissionKey(key);
  // 构造上恒等；不等说明库里的行不是这把键建的，宁可拒收也不回一张打不开的回执。
  if (!timingSafeEqual(await ticketHash(ticket), row.ticket_hash)) throw new HttpError(409, 'submission_key_conflict');
  return {
    id: row.id, ticket, status: row.status, createdAt: row.created_at, updatedAt: row.updated_at,
    parentId: row.parent_id ?? null,
  };
}

/**
 * 建反馈。幂等（2026-10-17，BUG-3489 审查）：客户端带 submissionKey 时，同一个键只会建一条反馈——
 * 「请求其实到了、回执没收到」（超时 / 断网）或「回执收到了、本机落盘失败」之后重试，都拿回同一张回执，
 * 而不是再建一条重复反馈或撞上「重复反馈」409 丢掉回执。查重放在最前面：重放不经限流 / 预算 / 判重桶，
 * 也不再核原反馈状态（第一次已经核过）。两个同键请求并发时都可能没查到，由 submission_hash 唯一索引
 * 兜底：后到的 INSERT 撞约束 → 再查一次按重放回。
 */
export async function createFeedback(env, account, ip, body, now, origin = {}, install = undefined) {
  const sub = normalizeSubmission(body);
  const submissionKey = normalizeSubmissionKey(body.submissionKey);
  const keyHash = submissionKey ? await submissionHash(submissionKey) : null;
  if (keyHash) {
    const replay = await replaySubmission(env, keyHash, submissionKey);
    if (replay) return replay;
  }
  const installId = install ? install.installId : normalizeInstallId(body.installId);
  const installVerified = install ? install.verified : false;
  const parent = await reopenParent(env, body.reopenOf);
  const hash = await contentHash(sub);
  const source = account ? `acct:${account.id}` : `ip:${ip}`;
  // 重新提交常常原样带着原标题 / 正文：判重桶按原反馈分开，不撞上原反馈自己当初提交时的桶；
  // 但同一来源把同一条原反馈用同样内容连交两次（双击 / 重试）照样拒收。
  const dupBucket = parent
    ? `feedback:dup:${source}:${hash}:reopen:${parent.id}`
    : `feedback:dup:${source}:${hash}`;
  try {
    await hit(env, dupBucket, FEEDBACK_LIMITS.duplicateWindowMs, 1, now);
  } catch (e) {
    if (e instanceof HttpError && e.status === 429) {
      // 同键并发：另一个请求刚建完（判重桶比它先记上）→ 按重放回，不报重复。
      const replay = keyHash ? await replaySubmission(env, keyHash, submissionKey) : null;
      if (replay) return replay;
      throw new HttpError(409, 'duplicate_feedback');
    }
    throw e;
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
  const ticket = submissionKey ? await ticketFromSubmissionKey(submissionKey) : randomId(32);
  // 重新提交的次数上限做成条件 INSERT：计数与写入在同一条语句里，并发的重新提交不会一起越过上限。
  let res;
  try {
    res = await env.DB.prepare(
      `INSERT INTO feedback (id, ticket_hash, account_id, category, title, body, contact, meta, created_at, updated_at,
                             flags, content_hash, origin, parent_id, install_id, install_verified, submission_hash)
       SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?9, ?10, ?11, ?12, ?13, ?15, ?16, ?17
       WHERE ?13 IS NULL OR (SELECT COUNT(*) FROM feedback WHERE parent_id = ?13) < ?14`,
    ).bind(id, await ticketHash(ticket), account ? account.id : null, sub.category, sub.title, sub.body,
      sub.contact, sub.meta, now, JSON.stringify(flags), hash, JSON.stringify(origin), parent ? parent.id : null,
      FEEDBACK_LIMITS.reopensPerFeedback, installId, installId && installVerified ? 1 : 0, keyHash).run();
  } catch (e) {
    // 同键并发撞唯一索引：另一个请求已经建好了 → 按重放回。别的错误照常抛。
    const replay = keyHash && /UNIQUE/i.test(String(e && e.message))
      ? await replaySubmission(env, keyHash, submissionKey)
      : null;
    if (replay) return replay;
    throw e;
  }
  if (res.meta.changes !== 1) throw new HttpError(429, 'too_many_reopens');
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
  if (!await appendAttachment(env, row.id, entry, now)) {
    // 并发传同一槽位：输家删掉自己的对象。
    await deleteMedia(env, key);
    throw new HttpError(409, 'conflict');
  }
  return { slot, kind: k.kind, bytes: bytes.length };
}

/**
 * 条件追加附件条目：本槽位没被别的请求占掉才写入，返回是否写入。在 SQL 里追加而不是整列写回，
 * 只看本槽位——视频上传可能要几分钟，期间并发补传的截图与视频互不作废（整列比对时谁后提交谁 409）。
 */
async function appendAttachment(env, id, entry, now) {
  const res = await env.DB.prepare(
    `UPDATE feedback SET attachments = json_insert(attachments, '$[#]', json(?2)), updated_at = ?3,
       has_video = CASE WHEN ?5 = 'video' THEN 1 ELSE has_video END
     WHERE id = ?1 AND NOT EXISTS (
       SELECT 1 FROM json_each(feedback.attachments) WHERE json_extract(value, '$.slot') = ?4)`,
  ).bind(id, JSON.stringify(entry), now, entry.slot, entry.kind).run();
  return res.meta.changes === 1;
}

/** 视频魔数：ISO BMFF（offset 4 = 'ftyp'；major brand 'qt  ' = QuickTime）/ EBML（WebM）。认不出返回 null。 */
export function sniffVideo(head) {
  if (head.length < 16) return null;
  const ascii = (from, to) => String.fromCharCode(...head.subarray(from, to));
  if (ascii(4, 8) === 'ftyp') return ascii(8, 12) === 'qt  ' ? 'video/quicktime' : 'video/mp4';
  if (head[0] === 0x1a && head[1] === 0x45 && head[2] === 0xdf && head[3] === 0xa3) return 'video/webm';
  return null;
}

/** 从流里读出开头至少 n 字节（可能多读一块；流先结束就返回已读到的）。 */
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

/**
 * PUT /v1/feedback/:id/attachments/v0：视频直接把请求体流式写进 R2，不整读进内存（50 MB 进 Worker
 * 内存就是 128 MB 上限的一大半）。所有能在读体之前判的都先判（窗口 / 槽位 / 长度 / 类型），超限的
 * 请求不扣预算也不占配额；魔数只读开头一块。R2 put 要求流长度已知，经 FixedLengthStream（Workers
 * 运行时全局）按声明长度封口：实际字节多了少了流都会出错，归还配额、删掉半截对象，400 bad_length。
 * 魔数通过后才计费：先记上传 IP 当天的视频字节（超了 429 rate_limited），再扣 media 预算 1 次，最后在
 * 视频池按声明长度预占（满了 507 video_quota；与头像 / 封面 / 截图的普通池互不挤占）。
 */
export async function putVideoAttachment(env, row, request, now, ip) {
  if (now - row.created_at > FEEDBACK_LIMITS.attachWindowMs) throw new HttpError(403, 'attach_window_closed');
  const existing = parseAttachments(row);
  if (existing.some((a) => a.slot === VIDEO_SLOT)) throw new HttpError(409, 'slot_taken');
  const declared = request.headers.get('Content-Length');
  if (declared === null || declared === '') throw new HttpError(411, 'length_required');
  const length = Number(declared);
  if (!/^\d+$/.test(declared) || length <= 0 || length > FEEDBACK_LIMITS.videoMaxBytes) {
    throw new HttpError(413, 'body_too_large');
  }
  const ctype = (request.headers.get('Content-Type') || '').split(';')[0].trim().toLowerCase();
  if (!VIDEO_TYPES.includes(ctype)) throw new HttpError(415, 'unsupported_video_type');
  if (!request.body) throw new HttpError(400, 'bad_length');

  const reader = request.body.getReader();
  let reserved = false;
  let key = null;
  try {
    const head = await readHead(reader, 16);
    const type = sniffVideo(head);
    if (!type) throw new HttpError(415, 'not_a_video');
    // 按 IP 的日字节额度先于全局预算：超了的 IP 不消耗全站的 media 次数。
    await hit(env, `feedback:video:ip:${ip}`, DAY, FEEDBACK_LIMITS.videoBytesPerIpDay, now, length);
    await spend(env, 'media', 1, now);
    await reserveMediaBytes(env, length, 'video');
    reserved = true;
    key = `f/${row.id}-${VIDEO_SLOT}-${randomId(8)}.${VIDEO_EXT[type]}`;
    // eslint-disable-next-line no-undef
    const body = rejoin(head, reader).pipeThrough(new FixedLengthStream(length));
    try {
      await env.MEDIA.put(key, body, { httpMetadata: { contentType: type } });
    } catch {
      throw new HttpError(400, 'bad_length');
    }
    const entry = { slot: VIDEO_SLOT, kind: 'video', key, bytes: length, type };
    if (!await appendAttachment(env, row.id, entry, now)) {
      reserved = false; // deleteMedia 按对象实际大小归还
      await deleteMedia(env, key, 'video');
      throw new HttpError(409, 'conflict');
    }
    return { slot: VIDEO_SLOT, kind: 'video', bytes: length };
  } catch (e) {
    await reader.cancel().catch(() => {});
    if (reserved) {
      await releaseMediaBytes(env, length, 'video');
      if (key) await env.MEDIA.delete(key);
    }
    throw e;
  }
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

/** 游标 `<at>:<id>` → {at, id}；格式不对视为第一页。 */
function parseCursor(cursor) {
  if (typeof cursor !== 'string' || !/^\d+:[A-Za-z0-9_-]{1,16}$/.test(cursor)) return null;
  const i = cursor.indexOf(':');
  return { at: Number(cursor.slice(0, i)), id: cursor.slice(i + 1) };
}

/**
 * GET /v1/feedback/mine：签名账户提交过的反馈（换设备 / 重装后回执丢了也能找回自己的工单）。
 * 按创建时间倒序、游标 `<created_at>:<id>`，每页读 limit+1 行（走 idx_feedback_account_created）。
 * 每条只给反馈人视角的摘要（与 batchStatus 同形），不带风险标记 / 开发者批注 / 联系方式 / 设备信息。
 */
export async function mineList(env, account, { cursor, limit }) {
  const n = clampInt(limit, 1, FEEDBACK_LIMITS.minePageMax, FEEDBACK_LIMITS.minePageDefault);
  const after = parseCursor(cursor);
  const page = after
    ? 'AND (created_at < ?2 OR (created_at = ?2 AND id < ?3))'
    : 'AND ?2 IS NULL AND ?3 IS NULL';
  const rows = await env.DB.prepare(
    `SELECT id, parent_id, category, title, status, created_at, updated_at, dev_reply_at, user_reply_at
     FROM feedback WHERE account_id = ?1 ${page}
     ORDER BY created_at DESC, id DESC LIMIT ?4`,
  ).bind(account.id, after ? after.at : null, after ? after.id : null, n + 1).all();
  const items = rows.results.slice(0, n).map(summary);
  const last = rows.results[n - 1];
  return { items, next: rows.results.length > n ? `${last.created_at}:${last.id}` : null };
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
  // 结案后不会再有回复可推：推送令牌一并作废（App 侧同时注销，这里兜住没注销成的）。
  await clearFeedbackPushTokens(env, row.id);
}

/** 处理台搜索词 → LIKE 模式（转义 % _ \）。空串返回 null。 */
function searchTerm(q) {
  if (typeof q !== 'string') return null;
  const t = q.trim().slice(0, FEEDBACK_LIMITS.searchMax);
  if (!t) return null;
  return { exact: t, like: `%${t.replace(/[\\%_]/g, (c) => `\\${c}`)}%` };
}

/**
 * 开发者回复 / 改状态的写库语句，每条带自己的参数。devUpdate 与 scripts/feedback.mjs reply 执行同一份 SQL。
 * @param {{id: string, devId: string, reply: string, timelineStatus: string | null, status: string | null, now: number}} p
 *   reply 可为空串（只改状态）；timelineStatus = 时间线里记的新状态（没改状态为 null）；status = 改后的状态，
 *   null = 不改状态（UPDATE 不写 status 列，不会撤回并发的改状态）。
 * @returns {Array<[string, Array<string | number | null>]>}
 */
export function devReplyStatements({ id, devId, reply, timelineStatus, status, now }) {
  return [
    [`INSERT INTO feedback_messages (feedback_id, author, account_id, body, status, created_at)
      VALUES (?1, 'dev', ?2, ?3, ?4, ?5)`, [id, devId, reply, timelineStatus, now]],
    // status === null：只回复、不改状态。UPDATE 不碰 status 列——把早先读到的状态原样写回
    // 会在「读」与「写」之间别人结案时把它静默撤回（CLI 回复与处理台纯回复都踩过）。
    status === null
      ? ['UPDATE feedback SET dev_reply_at = ?2, updated_at = ?2 WHERE id = ?1', [id, now]]
      : ['UPDATE feedback SET status = ?2, dev_reply_at = ?3, updated_at = ?3 WHERE id = ?1', [id, status, now]],
  ];
}

/** 开发者回复正文的唯一清洗口径（接口与 CLI 共用）：剥伪装字符、限长；空白 → ''。 */
export function cleanDevReply(value) {
  return cleanText(value, FEEDBACK_LIMITS.replyMax, 'reply');
}

/**
 * 开发者处理：改状态和 / 或回复（两者至少一个）。写库之后在后台（[ctx].waitUntil）给反馈人的
 * iOS 设备发 APNs 推送（通用文案，不带正文），结案的顺带清掉推送令牌——见 feedback_push.js。
 * App 处理台（routeFeedback）与网页处理台（devconsole.js）都走这里，推送不会漏掉任一路径。
 */
export async function devUpdate(env, dev, row, body, now, ctx = null) {
  const status = body && body.status !== undefined && body.status !== null && body.status !== ''
    ? body.status : null;
  if (status !== null && !STATUSES.includes(status)) throw new HttpError(400, 'bad_status');
  const reply = cleanDevReply(body && body.reply);
  const changed = status !== null && status !== row.status;
  if (!changed && !reply) throw new HttpError(400, 'nothing_to_update');
  const statements = devReplyStatements({
    id: row.id, devId: dev.id, reply, timelineStatus: changed ? status : null, status: changed ? status : null, now,
  });
  await env.DB.batch(statements.map(([sql, args]) => env.DB.prepare(sql).bind(...args)));
  const after = changed ? status : row.status;
  await background(ctx, notifyFeedbackUpdate(env, row.id, {
    kind: reply ? 'reply' : 'status',
    closed: CLOSED_STATUSES.includes(after),
  }, now));
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
 * 本页反馈人里的开发者账户 id → {id, nickname}。开发者自己提的反馈在处理台要醒目标出（内部人员自测 /
 * 拍板意见，和外部用户报告分开看）。按本页出现的 account_id 走主键查，不扫 accounts 全表。
 * @param {Array<string | null>} accountIds
 * @returns {Promise<Map<string, {id: string, nickname: string}>>}
 */
async function devAccounts(env, accountIds) {
  const ids = [...new Set(accountIds.filter((x) => x !== null))];
  if (ids.length === 0) return new Map();
  const marks = ids.map((_, i) => `?${i + 1}`).join(', ');
  const rows = await env.DB.prepare(`SELECT id, nickname, role FROM accounts WHERE id IN (${marks})`).bind(...ids).all();
  return new Map(rows.results.filter((a) => a.role === 'dev').map((a) => [a.id, { id: a.id, nickname: a.nickname }]));
}

/**
 * 处理台列表：按最近变化倒序，游标 `<updated_at>:<id>`。status = 'active' 表示未结案（open + in_progress）。
 */
export async function devList(env, { status, cursor, limit, q }) {
  const n = clampInt(limit, 1, 100, 30);
  const after = parseCursor(cursor);
  const cols = 'id, category, title, status, created_at, updated_at, dev_reply_at, user_reply_at, account_id, attachments, flags, parent_id, '
    + 'fix_sha, fix_scope, fix_at, fixed_in, '
    // 列表只露一行预览：截 200 字，全文看详情（devView），省得一页 50 条整段下发。
    + 'substr(ai_summary, 1, 200) AS ai_summary, dev_note IS NOT NULL AS has_dev_note';
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
  const pageRows = rows.results.slice(0, n);
  const devs = await devAccounts(env, pageRows.map((r) => r.account_id));
  const list = pageRows.map((r) => ({
    ...devSummary(r),
    hasAccount: r.account_id !== null,
    devReporter: devs.get(r.account_id) ?? null,
    attachments: parseAttachments(r).length,
    aiSummary: r.ai_summary ?? null,
    hasDevNote: Boolean(r.has_dev_note),
    // 反馈人在开发者上次处理之后又说话了 → 处理台标「新消息」。
    awaitingDev: r.user_reply_at !== null && (r.dev_reply_at === null || r.user_reply_at > r.dev_reply_at),
  }));
  const last = rows.results[n - 1];
  return { items: list, next: rows.results.length > n ? `${last.updated_at}:${last.id}` : null };
}

/**
 * Range 头 → {offset, length}（单段：`bytes=a-b` / `bytes=a-` / `bytes=-n`）。没带或多段 / 格式不认识
 * 返回 null（按 RFC 9110 忽略，回整个文件）；越界抛 416。
 */
export function parseRange(header, size) {
  if (!header) return null;
  const m = /^bytes=(\d*)-(\d*)$/.exec(header.trim());
  if (!m || (m[1] === '' && m[2] === '')) return null;
  let start;
  let end;
  if (m[1] === '') {
    const n = Number(m[2]);
    if (n === 0) throw new HttpError(416, 'range_not_satisfiable');
    start = Math.max(0, size - n);
    end = size - 1;
  } else {
    start = Number(m[1]);
    end = m[2] === '' ? size - 1 : Math.min(Number(m[2]), size - 1);
  }
  if (start >= size || end < start) throw new HttpError(416, 'range_not_satisfiable');
  return { offset: start, length: end - start + 1 };
}

/**
 * 开发者取附件。日志可带 ?view=text 在服务端解压成纯文本（流式，不占内存）。视频支持单段 Range
 * （`<video>` 拖进度条只取需要的那段，不必整段 50 MB 下发），download = true 时作为附件下载。
 */
export async function attachmentResponse(env, row, slot, asText, { range = null, download = false } = {}) {
  const a = parseAttachments(row).find((x) => x.slot === slot);
  if (!a) throw new HttpError(404, 'not_found');
  if (a.kind === 'video') return videoResponse(env, row, a, range, download);
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

async function videoResponse(env, row, a, rangeHeader, download) {
  let range;
  try {
    range = parseRange(rangeHeader, a.bytes);
  } catch (e) {
    if (e instanceof HttpError && e.status === 416) {
      return new Response(null, {
        status: 416,
        headers: { 'Content-Range': `bytes */${a.bytes}`, 'Cache-Control': 'private, no-store' },
      });
    }
    throw e;
  }
  const obj = await env.MEDIA.get(a.key, range ? { range } : undefined);
  if (!obj) throw new HttpError(404, 'not_found');
  const headers = {
    'Cache-Control': 'private, no-store',
    'X-Content-Type-Options': 'nosniff',
    'Content-Type': a.type,
    'Accept-Ranges': 'bytes',
    'Content-Length': String(range ? range.length : a.bytes),
  };
  if (range) headers['Content-Range'] = `bytes ${range.offset}-${range.offset + range.length - 1}/${a.bytes}`;
  if (download) {
    headers['Content-Disposition'] = `attachment; filename="fushi-${row.id}.${VIDEO_EXT[a.type] || 'mp4'}"`;
  }
  return new Response(obj.body, { status: range ? 206 : 200, headers });
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
    // 视频与其它附件在不同的配额池，分开归还。
    const list = parseAttachments(row);
    await deleteMedia(env, list.filter((a) => a.kind !== 'video').map((a) => a.key));
    await deleteMedia(env, list.filter((a) => a.kind === 'video').map((a) => a.key), 'video');
    await env.DB.prepare('UPDATE feedback SET attachments = \'[]\', has_video = 0 WHERE id = ?1').bind(row.id).run();
  }
  return rows.results.length;
}

/**
 * 到期视频：创建满 30 天，或已结案满 7 天（以 updated_at 计，先到者）。只删视频对象（归还配额）、
 * 从附件列表去掉视频条目、has_video 归零；截图与日志按 purgeFeedbackAttachments 的 90 天口径另算。
 * 只读带视频的行（idx_feedback_video 部分索引），每次最多 limit 条。
 */
export async function purgeFeedbackVideos(env, now, limit = 20) {
  const rows = await env.DB.prepare(
    `SELECT id, attachments FROM feedback
     WHERE has_video = 1 AND (created_at < ?1
       OR (status IN ('resolved', 'wont_fix', 'duplicate', 'closed') AND updated_at < ?2))
     LIMIT ?3`,
  ).bind(now - FEEDBACK_LIMITS.videoRetentionMs, now - FEEDBACK_LIMITS.videoRetentionAfterCloseMs, limit).all();
  for (const row of rows.results) {
    const list = parseAttachments(row);
    await deleteMedia(env, list.filter((a) => a.kind === 'video').map((a) => a.key), 'video');
    // 条件更新：附件列表在这期间被改过就留给下一轮（对象已删，下一轮 head 不到不会重复归还配额）。
    await env.DB.prepare('UPDATE feedback SET attachments = ?2, has_video = 0 WHERE id = ?1 AND attachments = ?3')
      .bind(row.id, JSON.stringify(list.filter((a) => a.kind !== 'video')), row.attachments).run();
  }
  return rows.results.length;
}

// ---- CI：修复 → 打包 → 发布追踪（迁移 0009） ----

/** 修复 commit：40 位 hex，统一存小写。 */
export function normalizeFixSha(sha) {
  const s = typeof sha === 'string' ? sha.trim().toLowerCase() : '';
  if (!FIX_SHA_RE.test(s)) throw new HttpError(400, 'bad_sha');
  return s;
}

export function normalizeFixScope(scope) {
  if (scope === undefined || scope === null) return 'app';
  if (!FIX_SCOPES.includes(scope)) throw new HttpError(400, 'bad_scope');
  return scope;
}

/** ids：1..max 个合法反馈编号，去重保序；任一不合法整批 400。 */
function normalizeIds(ids, max) {
  if (!Array.isArray(ids) || ids.length === 0) throw new HttpError(400, 'bad_ids');
  if (ids.length > max) throw new HttpError(400, 'too_many_ids');
  for (const id of ids) if (typeof id !== 'string' || !FEEDBACK_ID_RE.test(id)) throw new HttpError(400, 'bad_id');
  return [...new Set(ids)];
}

/** channel / platform 白名单 → json 路径 `$.<channel>.<platform>`（只由白名单拼出，不含用户字符）。 */
function releasePath(channel, platform) {
  if (!RELEASE_CHANNELS.includes(channel)) throw new HttpError(400, 'bad_channel');
  if (!RELEASE_PLATFORMS.includes(platform)) throw new HttpError(400, 'bad_platform');
  return `$.${channel}.${platform}`;
}

/**
 * 单条「标记修复」的语句（参数 ?1 id、?2 sha、?3 scope、?4 now）。接口在 batch 里执行；
 * scripts/feedback.mjs fixed 把参数内联成字面量后走 wrangler 执行——同一份 SQL，不写两套判据。
 * 顺序有意：先按旧状态插时间线（只有 open / in_progress 才记 resolved 事件），再改行。
 * dev_reply_at 只在插了时间线的那一种情况刷新（与时间线同一个判据 FIX_REPORTED_STATUSES）：它是
 * 「开发者有新消息」的唯一时刻——App 拿它和 seenAt 比亮红点、处理台拿它和 user_reply_at 比判「新消息」。
 * 已结案的行只改 fix_*，刷新它会让反馈人看到红点却找不到新消息，也会冲掉反馈人追问的「新消息」。
 * 新的修复覆盖旧的：fix_* 全部重写，fixed_in 重置为 '{}'（旧 commit 的发布记录不适用于新 commit）。
 * 幂等：sha 与 scope 都和现有记录相同时两条语句都不命中（main 同步 develop、重跑 workflow 会重复登记，
 * 不幂等的话已回填的发布进度会被清空）——不改 fix_at / fixed_in、不插时间线、不刷 dev_reply_at / updated_at。
 */
const FIX_CHANGED = '(fix_sha IS NOT ?2 OR fix_scope IS NOT ?3)';
const FIX_REPORTED_STATUSES = "status IN ('open', 'in_progress')";
export const MARK_FIXED_SQL = [
  `INSERT INTO feedback_messages (feedback_id, author, account_id, body, status, created_at)
   SELECT id, 'dev', NULL, '', 'resolved', ?4 FROM feedback
   WHERE id = ?1 AND ${FIX_REPORTED_STATUSES} AND ${FIX_CHANGED}`,
  `UPDATE feedback SET fix_sha = ?2, fix_scope = ?3, fix_at = ?4, fixed_in = '{}',
     status = CASE WHEN ${FIX_REPORTED_STATUSES} THEN 'resolved' ELSE status END,
     dev_reply_at = CASE WHEN ${FIX_REPORTED_STATUSES} THEN ?4 ELSE dev_reply_at END,
     updated_at = ?4
   WHERE id = ?1 AND ${FIX_CHANGED}`,
];

/** 单条标记修复的参数（校验与归一化的唯一口径；CLI 也走这里）。 */
export function markFixedArgs(id, sha, scope, now) {
  if (typeof id !== 'string' || !FEEDBACK_ID_RE.test(id)) throw new HttpError(400, 'bad_id');
  return [id, normalizeFixSha(sha), normalizeFixScope(scope), Math.trunc(now)];
}

/** POST /v1/ci/feedback/fixed。 */
export async function ciMarkFixed(env, body, now) {
  if (!body || typeof body !== 'object') throw new HttpError(400, 'bad_json');
  const sha = normalizeFixSha(body.sha);
  const scope = normalizeFixScope(body.scope);
  const ids = normalizeIds(body.ids, FEEDBACK_LIMITS.ciFixedIds);
  // 每条：时间线一行 + 反馈一行 + 索引。
  await spend(env, 'write_rows', ids.length * 4, now);
  const stmts = ids.flatMap((id) => MARK_FIXED_SQL.map((sql) => env.DB.prepare(sql).bind(...markFixedArgs(id, sha, scope, now))));
  // 同一个 batch（同一事务）里再读一次存在的编号：UPDATE 命中 0 行既可能是「不存在」也可能是「没变」。
  stmts.push(env.DB.prepare('SELECT id FROM feedback WHERE id IN (SELECT value FROM json_each(?1))').bind(JSON.stringify(ids)));
  const res = await env.DB.batch(stmts);
  const exists = new Set(res.at(-1).results.map((r) => r.id));
  const updated = [];
  const unchanged = [];
  const missing = [];
  ids.forEach((id, i) => {
    if (res[i * 2 + 1].meta.changes === 1) updated.push(id);
    else if (exists.has(id)) unchanged.push(id);
    else missing.push(id);
  });
  return { updated, unchanged, missing };
}

/** GET /v1/ci/feedback/pending：还没回填到该通道 / 平台的「需要新 App」修复。 */
export async function ciPending(env, channel, platform, now) {
  const path = releasePath(channel, platform);
  const rows = await env.DB.prepare(
    `SELECT id, fix_sha FROM feedback
     WHERE fix_sha IS NOT NULL AND fix_scope = 'app' AND fix_at > ?1 AND json_extract(fixed_in, ?2) IS NULL
     ORDER BY fix_at LIMIT ?3`,
  ).bind(now - FEEDBACK_LIMITS.ciPendingWindowMs, path, FEEDBACK_LIMITS.ciPendingMax).all();
  return { items: rows.results.map((r) => ({ id: r.id, sha: r.fix_sha })) };
}

/** released 的 ids：1..max 个 {id, sha}；任一不合法整批 400；sha 转小写；同一 (id, sha) 去重。 */
function normalizeReleasedItems(items, max) {
  if (!Array.isArray(items) || items.length === 0) throw new HttpError(400, 'bad_ids');
  if (items.length > max) throw new HttpError(400, 'too_many_ids');
  const out = new Map();
  for (const it of items) {
    if (!it || typeof it !== 'object' || typeof it.id !== 'string' || !FEEDBACK_ID_RE.test(it.id)) {
      throw new HttpError(400, 'bad_id');
    }
    const sha = normalizeFixSha(it.sha);
    out.set(`${it.id}:${sha}`, { id: it.id, sha });
  }
  return [...out.values()];
}

/**
 * POST /v1/ci/feedback/released：只写尚未记录该通道 / 平台的行（保留最早包含修复的版本），
 * 且该行当前的 fix_sha 必须等于 CI 判定过祖先关系的那个 sha——pending 与 released 之间被重新
 * 标记修复（fixed_in 已重置）的行，旧 commit 的发布结果不能记到新 commit 上。不匹配的静默跳过。
 * 只写 fixed_in：自动回填不是开发者回复，不刷 dev_reply_at（否则处理台「新消息」判据
 * user_reply_at > dev_reply_at 被每个通道 / 平台的包冲掉，反馈人在别的平台也会反复亮红点却没有新消息），
 * 也不刷 updated_at（处理台按它排序；一条修复最多被回填 通道 × 平台 次，刷了会把旧单反复顶到最前，
 * 还会推迟结案附件的到期清理）。发布进度由 App 按本机通道 / 平台从 fix.releases 自己解读。
 */
export async function ciMarkReleased(env, body, now) {
  if (!body || typeof body !== 'object') throw new HttpError(400, 'bad_json');
  const path = releasePath(body.channel, body.platform);
  if (typeof body.version !== 'string' || !RELEASE_VERSION_RE.test(body.version)) throw new HttpError(400, 'bad_version');
  const items = normalizeReleasedItems(body.ids, FEEDBACK_LIMITS.ciReleasedIds);
  // 只改 fixed_in（不在任何索引里）：每条一行。
  const estimate = items.length;
  await spend(env, 'write_rows', estimate, now);
  const res = await env.DB.prepare(
    `UPDATE feedback SET fixed_in = json_set(fixed_in, ?2, json_object('version', ?3, 'at', ?4))
     WHERE id IN (SELECT json_extract(value, '$.id') FROM json_each(?1))
       AND fix_sha IS NOT NULL AND json_extract(fixed_in, ?2) IS NULL
       AND EXISTS (SELECT 1 FROM json_each(?1) j
                   WHERE json_extract(j.value, '$.id') = feedback.id AND json_extract(j.value, '$.sha') = feedback.fix_sha)`,
  ).bind(JSON.stringify(items), path, body.version, now).run();
  const updated = res.meta.changes;
  await adjustSpend(env, 'write_rows', updated - estimate, now);
  return { updated };
}

/** CI 鉴权：没配 FEEDBACK_CI_TOKEN 时整组接口当不存在（404）；token 不对 401。 */
function requireCi(request, env) {
  const token = typeof env.FEEDBACK_CI_TOKEN === 'string' ? env.FEEDBACK_CI_TOKEN : '';
  if (!token) throw new HttpError(404, 'not_found');
  const auth = request.headers.get('Authorization') || '';
  const given = auth.startsWith('Bearer ') ? auth.slice(7).trim() : '';
  if (!given || !timingSafeEqual(given, token)) throw new HttpError(401, 'unauthorized');
}

// ---- 路由（worker.js 在通用读 / 写分发之前调用） ----

const ID = '([A-Za-z0-9_-]{8,16})';
const RE = {
  submit: /^\/v1\/feedback$/,
  status: /^\/v1\/feedback\/status$/,
  mine: /^\/v1\/feedback\/mine$/,
  one: new RegExp(`^/v1/feedback/${ID}$`),
  attach: new RegExp(`^/v1/feedback/${ID}/attachments/([a-z0-9]{1,4})$`),
  messages: new RegExp(`^/v1/feedback/${ID}/messages$`),
  push: new RegExp(`^/v1/feedback/${ID}/push$`),
  close: new RegExp(`^/v1/feedback/${ID}/close$`),
  devList: /^\/v1\/dev\/feedback$/,
  devOne: new RegExp(`^/v1/dev/feedback/${ID}$`),
  devAttach: new RegExp(`^/v1/dev/feedback/${ID}/attachments/([a-z0-9]{1,4})$`),
  devNotes: new RegExp(`^/v1/dev/feedback/${ID}/notes$`),
  ciFixed: /^\/v1\/ci\/feedback\/fixed$/,
  ciPending: /^\/v1\/ci\/feedback\/pending$/,
  ciReleased: /^\/v1\/ci\/feedback\/released$/,
};

export function isFeedbackPath(path) {
  return path.startsWith('/v1/feedback') || path.startsWith('/v1/dev/') || path.startsWith('/v1/ci/feedback');
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
 *   ctx?: { waitUntil?: (p: Promise<any>) => void } | null,
 * }} io
 */
export async function routeFeedback(request, env, url, now, io) {
  const path = url.pathname;
  const method = request.method;
  const ticket = request.headers.get('X-Fushi-Ticket') || '';
  const noStore = { 'Cache-Control': 'no-store' };
  let m;

  // CI 接口：先验 token（没配 secret 时连路径是否存在都不暴露），再读请求体。
  if (path.startsWith('/v1/ci/feedback')) {
    requireCi(request, env);
    if (method === 'POST' && RE.ciFixed.test(path)) {
      return json(await ciMarkFixed(env, io.parse(await io.readBody(16 * 1024)), now), 200, noStore);
    }
    if (method === 'GET' && RE.ciPending.test(path)) {
      const q = url.searchParams;
      return json(await ciPending(env, q.get('channel'), q.get('platform'), now), 200, noStore);
    }
    if (method === 'POST' && RE.ciReleased.test(path)) {
      return json(await ciMarkReleased(env, io.parse(await io.readBody(64 * 1024)), now), 200, noStore);
    }
    return null;
  }

  if (method === 'POST' && RE.submit.test(path)) {
    const bytes = await io.readBody(16 * 1024);
    // 带签名 = 关联账户（验签失败照常 401，别静默降成匿名）。
    const account = request.headers.get('X-Fushi-Account') ? await io.auth(bytes, { mutating: true }) : null;
    const origin = requestOrigin(request, account !== null);
    const body = io.parse(bytes);
    const install = await feedbackInstall(env, request, body, bytes, now);
    return json(await createFeedback(env, account, io.ip, body, now, origin, install), 201, noStore);
  }
  if (method === 'POST' && RE.status.test(path)) {
    const bytes = await io.readBody(16 * 1024);
    return json(await batchStatus(env, io.parse(bytes)), 200, noStore);
  }
  // 「我的反馈」先于 RE.one 匹配（mine 只有 4 个字符，RE.one 要 8-16 位，本不会撞，这里显式排前）。
  if (method === 'GET' && RE.mine.test(path)) {
    const account = await io.auth(new Uint8Array(), {});
    const q = url.searchParams;
    return json(await mineList(env, account, { cursor: q.get('cursor'), limit: q.get('limit') }), 200, noStore);
  }
  const empty = new Uint8Array();
  if (method === 'GET' && (m = RE.one.exec(path))) {
    return json(await reporterView(env, await feedbackForReporter(request, env, m[1], io, empty)), 200, noStore);
  }
  if (method === 'POST' && (m = RE.close.exec(path))) {
    const bytes = await io.readBody(16 * 1024);
    const row = await feedbackForReporter(request, env, m[1], io, bytes, { mutating: true });
    await reporterClose(env, row, now);
    return json(await reporterView(env, await feedbackById(env, row.id)), 200, noStore);
  }
  if (method === 'GET' && (m = RE.attach.exec(path))) {
    return reporterAttachmentResponse(env, await feedbackForReporter(request, env, m[1], io, empty), m[2], now);
  }
  if (method === 'PUT' && (m = RE.attach.exec(path))) {
    // 补传只认 ticket：签名要覆盖整个请求体，视频没法边收边验。
    const row = await feedbackForTicket(env, m[1], ticket);
    // 视频不走 readBody：50 MB 不整读进内存，直接流式写 R2。
    if (m[2] === VIDEO_SLOT) return json(await putVideoAttachment(env, row, request, now, io.ip), 201, noStore);
    const bytes = await io.readBody(ATTACHMENT_MAX_BYTES);
    return json(await putAttachment(env, row, m[2], bytes, now), 201, noStore);
  }
  if (method === 'POST' && (m = RE.messages.exec(path))) {
    const bytes = await io.readBody(16 * 1024);
    const row = await feedbackForReporter(request, env, m[1], io, bytes, { mutating: true });
    await addReporterMessage(env, row, io.parse(bytes), now);
    return json(await reporterView(env, await feedbackById(env, row.id)), 201, noStore);
  }

  if ((method === 'PUT' || method === 'DELETE') && (m = RE.push.exec(path))) {
    // 与追加说明同一凭据：本机回执带 ticket，跨设备凭账户列出的条目（没有 ticket）用账户签名。
    const bytes = await io.readBody(4 * 1024);
    const row = await feedbackForReporter(request, env, m[1], io, bytes, { mutating: true });
    const body = io.parse(bytes);
    const out = method === 'PUT'
      ? await registerPushToken(env, row, body, now, { closed: CLOSED_STATUSES.includes(row.status) })
      : await unregisterPushToken(env, row, body);
    return json(out, 200, noStore);
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
    return attachmentResponse(env, await feedbackById(env, m[1]), m[2], url.searchParams.get('view') === 'text', {
      range: request.headers.get('Range'),
      download: url.searchParams.get('download') === '1',
    });
  }
  if (method === 'POST' && (m = RE.devOne.exec(path))) {
    const bytes = await io.readBody(16 * 1024);
    const dev = requireDev(await io.auth(bytes, { mutating: true }));
    const row = await feedbackById(env, m[1]);
    await devUpdate(env, dev, row, io.parse(bytes), now, io.ctx);
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
