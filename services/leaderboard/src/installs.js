// 安装统计：客户端每天一次的心跳与开发者处理台的统计数据（表结构见 migrations/0011_install_stats.sql、
// 0013_install_verified.sql）。
//
//   POST /v1/ping  {installId, version, platform, channel} → 204
//                  + 可选安装证明头 X-Fushi-Install-Key / -Time / -Sig / -Pow（见下）
//
// installId（2026-10-17 起，客户端 fushi_engine/lib/leaderboard/install_identity.dart）：
//   seed = HMAC-SHA256("fushi-install-id-v1", 系统机器标识)，P-256 私钥 = seed 映射到 [1, n−1]，
//   installId = SHA-256(公钥 SPKI) 前 16 字节按 UUID 排版、置 version=4 / variant=10。
//   同一台机器重装不变；**原始机器标识从不上传**，服务端只见到公钥与它的指纹。
//   取不到机器标识的设备回退到本机随机种子（重装即变）。旧客户端（2.10.0-debug 起）发的是
//   纯随机 UUID v4、不带证明头。
//
// 安装证明（verifyInstallProof）：带头 = 声称已验证，任何一项不对都 401（不静默降级）：
//   - Key：base64url(SPKI)，installId 必须 == installIdFromSpki(Key)（install_id_mismatch）；
//   - Time：epoch ms，|now − time| ≤ 5 分钟（stale_install_time）；
//   - Pow：nonce，sha256("fip1|<installId>|<nonce>") 前 INSTALL_POW_BITS 位为 0（install_pow_required）。
//     nonce 只绑 installId，客户端算一次永久复用，服务端每次只验一次哈希，所以每个已验证请求都要求它
//     （比「只在首次登记时要求」少一次查库、没有并发首登的竞态，效果相同：造一个新 id 至少付一次 PoW）；
//   - Sig：ECDSA P-256 / P1363，签 `fushi-install-v1\n` + auth.js 同一套签名串
//     （方法 + 路径 + 时刻 + 请求体哈希）（bad_install_signature）；签名串哈希登记进 used_sigs
//     （account_id = 'install:<installId>'），同一签名串第二次到达 401 install_replayed。
// 不带头 = 未验证（旧客户端 / 自报），照收但 verified = 0。统计页默认只数已验证安装，未验证另列。
// 已验证的安装行不会被未验证心跳改写（防止知道 id 的人用自报心跳篡改它的版本 / 平台）。
//
// 能防什么、不能防什么：服务端核验不了机器标识真假，任何人都能用随机种子造新安装——证明保证的是
// ①冒充不了已有安装（没有私钥签不出它的 id）②每造一个新 id 都要付钥匙生成 + PoW + 每 IP 限流的代价。
// 旧随机 id → 新 id 不做关联：旧 id 没有任何持有证明，接受「旧 → 新」声明等于让任何人把任意旧轨迹
// 嫁接到自己名下；旧 id 只在 2.10.0-debug 的心跳里存在过一天量级，按保留期自然过期。
//
// 服务端不存 IP：限流靠 Workers Rate Limiting binding（worker.js 里按 IP 过 AUTH_LIMITER），不落 D1。
// 心跳的处理顺序（recordPing）：先做证明的**无状态**检查（头齐全、id == fp(公钥)、时效、PoW，纯 CPU、
// 一次哈希），再读一次 install_days 看当天是否已记过——当天已有已验证记录、或这次本就是未验证的
// 重复心跳，就直接 204：不验签、不写 used_sigs、不写库、不扣预算。只有当天第一次（或把未验证升级成
// 已验证）才验签、登记签名串防重放、扣 'ping' 日预算 1 次、写两行。跳过验签不构成探测口：要过 fp
// 检查就得拿着该安装的公钥，而公钥只在本机与 TLS 内的请求头里，服务端不存、处理台不显示。
// 随机伪造 installId 刷量受 binding（每 IP 每分钟 10 次）和 'ping' 日预算双重限制，超了 503。
//
// 反馈与安装的关联：反馈提交时客户端可带 installId（勾选「附带设备信息」才带），存在 feedback.install_id；
// 同时出示了安装证明的记 feedback.install_verified = 1。反馈接口对证明**宽松**：证明验不过不拒收反馈
// （将来调难度 / 格式漂移不该让老客户端的反馈全部 401），而是丢掉这个不可信的 installId 只收反馈本身。
// 开发者处理台据此展示该安装的版本轨迹、同一安装的其它反馈，以及修复版本是否已装上（installTrail），
// 并标注是否已验证；已验证安装的轨迹只取已验证的心跳日与反馈，知道 id 的人塞不进未验证数据。

import { HttpError, b64urlDecode, hex, sha256, utcDateKey } from './util.js';
import { spend } from './budget.js';
import { SIG_WINDOW_MS, importPublicKey, signingString, verifySignature } from './auth.js';

const DAY_MS = 24 * 3600 * 1000;

export const INSTALL_LIMITS = {
  /** install_days / installs 保留天数（定时任务清理）。 */
  retentionDays: 400,
  /** 统计页的日活表显示多少天。 */
  dailyRows: 30,
  /** 版本分布最多列多少个版本。 */
  topVersions: 20,
  /** 反馈详情里同一安装的其它反馈最多列多少条。 */
  relatedFeedback: 20,
};

/** 发心跳的平台：iOS 不发（App Store Connect 自带分析），服务端也不收。 */
export const PING_PLATFORMS = ['android', 'windows', 'macos', 'linux'];
export const PING_CHANNELS = ['stable', 'beta', 'debug'];

const INSTALL_ID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

/** 工作量证明难度（前导 0 位数；与客户端 install_identity.dart `kInstallPowBits` 一致）。 */
export const INSTALL_POW_BITS = 18;
/** 安装签名串的域前缀（与账户签名区分，签名不能跨用途挪用）。 */
export const INSTALL_SIG_PREFIX = 'fushi-install-v1\n';
const INSTALL_POW_PREFIX = 'fip1|';
const POW_NONCE_RE = /^[0-9]{1,15}$/;
export const INSTALL_HEADERS = {
  key: 'X-Fushi-Install-Key',
  time: 'X-Fushi-Install-Time',
  sig: 'X-Fushi-Install-Sig',
  pow: 'X-Fushi-Install-Pow',
};

/** 公钥 SPKI → installId：SHA-256 前 16 字节按 UUID 排版，置 version=4 / variant=10。 */
export async function installIdFromSpki(spkiBytes) {
  const h = (await sha256(spkiBytes)).slice(0, 16);
  h[6] = (h[6] & 0x0f) | 0x40;
  h[8] = (h[8] & 0x3f) | 0x80;
  const x = hex(h);
  return `${x.slice(0, 8)}-${x.slice(8, 12)}-${x.slice(12, 16)}-${x.slice(16, 20)}-${x.slice(20)}`;
}

function leadingZeroBits(bytes, bits) {
  let remaining = bits;
  for (const b of bytes) {
    if (remaining <= 0) return true;
    if (remaining >= 8) {
      if (b !== 0) return false;
      remaining -= 8;
    } else {
      return (b >> (8 - remaining)) === 0;
    }
  }
  return remaining <= 0;
}

/** nonce 是否满足 installId 的工作量证明。 */
export async function installPowValid(installId, nonce, bits = INSTALL_POW_BITS) {
  if (typeof nonce !== 'string' || !POW_NONCE_RE.test(nonce)) return false;
  const digest = await sha256(new TextEncoder().encode(`${INSTALL_POW_PREFIX}${installId}|${nonce}`));
  return leadingZeroBits(digest, bits);
}

/**
 * 安装证明的无状态部分（不碰 D1、不验签）：没带证明头 → null；带了但格式 / 指纹 / 时效 / PoW 不对 → 抛 401；
 * 都对 → 返回给 [completeInstallProof] 用的解析结果。installId 必须已经过 normalizeInstallId。
 */
export async function parseInstallProof(request, installId, now) {
  const h = (name) => request.headers.get(name);
  const present = Object.values(INSTALL_HEADERS).filter((name) => h(name) !== null);
  if (present.length === 0) return null;
  if (present.length !== 4 || !installId) throw new HttpError(401, 'bad_install_proof');
  const spki = b64urlDecode(h(INSTALL_HEADERS.key));
  if (!spki || spki.length < 60 || spki.length > 120) throw new HttpError(401, 'bad_install_proof');
  if (await installIdFromSpki(spki) !== installId) throw new HttpError(401, 'install_id_mismatch');
  const time = Number(h(INSTALL_HEADERS.time));
  if (!Number.isSafeInteger(time)) throw new HttpError(401, 'bad_install_proof');
  if (Math.abs(now - time) > SIG_WINDOW_MS) throw new HttpError(401, 'stale_install_time');
  if (!await installPowValid(installId, h(INSTALL_HEADERS.pow))) throw new HttpError(401, 'install_pow_required');
  return { installId, spki, time, sig: h(INSTALL_HEADERS.sig) };
}

/** 证明的有状态部分：验签 + 签名串登记进 used_sigs 防重放。不对抛 401。 */
export async function completeInstallProof(env, request, proof, bodyBytes) {
  const { installId, spki, time } = proof;
  let publicKey;
  try {
    publicKey = await importPublicKey(spki);
  } catch {
    throw new HttpError(401, 'bad_install_proof');
  }
  const u = new URL(request.url);
  const msg = INSTALL_SIG_PREFIX + await signingString(request.method, u.pathname + u.search, time, bodyBytes);
  if (!await verifySignature(publicKey, proof.sig, msg)) {
    throw new HttpError(401, 'bad_install_signature');
  }
  // 去重键 = 签名串哈希（ECDSA 签名可延展，不能按签名值去重；同 auth.js）。
  const dedup = hex(await sha256(new TextEncoder().encode(msg)));
  const res = await env.DB
    .prepare('INSERT OR IGNORE INTO used_sigs (account_id, sig, time) VALUES (?1, ?2, ?3)')
    .bind(`install:${installId}`, dedup, time)
    .run();
  if (!res.meta || res.meta.changes !== 1) throw new HttpError(401, 'install_replayed');
}

/**
 * 完整核验，返回 true（已验证）/ false（没带证明头 = 未验证）。带了头但任何一项不对都抛 401。
 * installId 必须已经过 normalizeInstallId（null = 请求没带合法 installId，此时带证明头也算错）。
 */
export async function verifyInstallProof(env, request, installId, bodyBytes, now) {
  const proof = await parseInstallProof(request, installId, now);
  if (!proof) return false;
  await completeInstallProof(env, request, proof, bodyBytes);
  return true;
}
const VERSION_RE = /^[A-Za-z0-9.+-]{1,64}$/;

/** 合法的 installId（小写 UUID v4）原样返回，否则 null。 */
export function normalizeInstallId(v) {
  return typeof v === 'string' && INSTALL_ID_RE.test(v) ? v : null;
}

export function normalizePing(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw new HttpError(400, 'bad_json');
  const installId = normalizeInstallId(body.installId);
  if (!installId) throw new HttpError(400, 'bad_install_id');
  if (typeof body.version !== 'string' || !VERSION_RE.test(body.version)) throw new HttpError(400, 'bad_version');
  if (!PING_PLATFORMS.includes(body.platform)) throw new HttpError(400, 'bad_platform');
  if (!PING_CHANNELS.includes(body.channel)) throw new HttpError(400, 'bad_channel');
  return { installId, version: body.version, platform: body.platform, channel: body.channel };
}

/**
 * POST /v1/ping。request / bodyBytes 用来核验安装证明。顺序见文件头：无状态检查 → 查当天是否已记过
 * （已有已验证记录，或这次是未验证的重复心跳 → 直接返回，不验签、不写库、不扣预算）→ 验签 + 防重放 → 写。
 */
export async function recordPing(env, request, bodyBytes, body, now) {
  const p = normalizePing(body);
  const proof = await parseInstallProof(request, p.installId, now);
  const day = utcDateKey(now);
  const seen = await env.DB.prepare('SELECT verified FROM install_days WHERE day = ?1 AND install_id = ?2')
    .bind(day, p.installId).first();
  if (seen && (seen.verified === 1 || !proof)) return;
  if (proof) await completeInstallProof(env, request, proof, bodyBytes);
  const verified = proof ? 1 : 0;
  await spend(env, 'ping', 1, now);
  // 未验证的心跳不改写已验证的行（DO UPDATE 的 WHERE）；已验证的心跳可以把同 id 的未验证行升级。
  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO install_days (day, install_id, platform, channel, version, verified)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6)
       ON CONFLICT (day, install_id) DO UPDATE SET
         platform = ?3, channel = ?4, version = ?5, verified = ?6
       WHERE ?6 > install_days.verified`,
    ).bind(day, p.installId, p.platform, p.channel, p.version, verified),
    env.DB.prepare(
      `INSERT INTO installs (install_id, first_seen, last_seen, platform, channel, version, verified)
       VALUES (?1, ?2, ?2, ?3, ?4, ?5, ?6)
       ON CONFLICT (install_id) DO UPDATE SET
         last_seen = MAX(last_seen, ?2), platform = ?3, channel = ?4, version = ?5, verified = ?6
       WHERE ?6 >= installs.verified`,
    ).bind(p.installId, now, p.platform, p.channel, p.version, verified),
  ]);
}

/** 定时任务：清掉超出保留期的心跳记录。 */
export async function purgeInstallStats(env, now) {
  const cutoff = now - INSTALL_LIMITS.retentionDays * DAY_MS;
  await env.DB.prepare('DELETE FROM install_days WHERE day < ?1').bind(utcDateKey(cutoff)).run();
  await env.DB.prepare('DELETE FROM installs WHERE last_seen < ?1').bind(cutoff).run();
}

function countBy(rows, key) {
  return rows.map((r) => ({ key: r[key], n: r.n }));
}

/**
 * 统计页数据。日活按 UTC 日；「活跃安装」= 窗口内至少发过一次心跳的安装。
 * 版本 / 平台 / 通道分布取近 30 天活跃安装各自最近一次上报的值。
 *
 * 默认口径只数**已验证**安装（verified = 1，出示了安装证明）：未验证的心跳只来自 2.10.0-debug
 * 的旧客户端或自报伪造，混进去会让刷量直接抬高主数字。未验证的另给一组计数（unverified），
 * 统计页并列显示，旧客户端淘汰后它应当归零。
 */
export async function installStats(env, now) {
  const today = utcDateKey(now);
  const since = (days) => utcDateKey(now - (days - 1) * DAY_MS);
  const distinct = async (days, verified) => (await env.DB.prepare(
    'SELECT COUNT(DISTINCT install_id) AS n FROM install_days WHERE day >= ?1 AND verified = ?2',
  ).bind(since(days), verified).first()).n;
  const platformCols = PING_PLATFORMS.map((p) => `SUM(platform = '${p}' AND verified = 1) AS ${p}`).join(', ');
  const daily = (await env.DB.prepare(
    `SELECT day, SUM(verified = 1) AS n, SUM(verified = 0) AS unverified, ${platformCols} FROM install_days
     WHERE day >= ?1 GROUP BY day ORDER BY day DESC`,
  ).bind(since(INSTALL_LIMITS.dailyRows)).all()).results;
  const fresh = (await env.DB.prepare(
    `SELECT strftime('%Y-%m-%d', first_seen / 1000, 'unixepoch') AS day, COUNT(*) AS n FROM installs
     WHERE first_seen >= ?1 AND verified = 1 GROUP BY day`,
  ).bind(Date.parse(`${since(INSTALL_LIMITS.dailyRows)}T00:00:00Z`)).all()).results;
  const newByDay = Object.fromEntries(fresh.map((r) => [r.day, r.n]));
  const activeSince = now - 30 * DAY_MS;
  const dist = async (col, limit) => countBy((await env.DB.prepare(
    `SELECT ${col}, COUNT(*) AS n FROM installs WHERE last_seen >= ?1 AND verified = 1
     GROUP BY ${col} ORDER BY n DESC, ${col} LIMIT ${limit}`,
  ).bind(activeSince).all()).results, col);
  const totalOf = async (verified) => (await env.DB.prepare(
    'SELECT COUNT(*) AS n FROM installs WHERE verified = ?1',
  ).bind(verified).first()).n;
  const todayRow = daily.find((r) => r.day === today);
  return {
    today,
    dau: todayRow?.n ?? 0,
    wau: await distinct(7, 1),
    mau: await distinct(30, 1),
    total: await totalOf(1),
    unverified: {
      dau: todayRow?.unverified ?? 0,
      wau: await distinct(7, 0),
      mau: await distinct(30, 0),
      total: await totalOf(0),
    },
    daily: daily.map((r) => ({
      day: r.day,
      n: r.n ?? 0,
      unverified: r.unverified ?? 0,
      fresh: newByDay[r.day] ?? 0,
      platforms: Object.fromEntries(PING_PLATFORMS.map((p) => [p, r[p] ?? 0])),
    })),
    platforms: await dist('platform', PING_PLATFORMS.length),
    channels: await dist('channel', PING_CHANNELS.length),
    versions: await dist('version', INSTALL_LIMITS.topVersions),
  };
}

const VERSION_PARTS_RE = /^(\d+)\.(\d+)\.(\d+)(?:-(beta|debug)\.(\d+))?$/;

/**
 * 安装版本 [installed] 是否已包含发布版本 [release]：true / false / null（判断不了）。
 * 与 App 的判据同口径（update_checker_release.dart 的 isUpdateVersionNewer）的简化版：
 * 去掉 `+build` 后同串即包含；只比同一轨道（正式 / beta / debug）的版本，基版本高者更晚，
 * 同基按预发布尾号（release sequence）比；正式版同基没有序号 → 判断不了。
 */
export function versionIncludes(installed, release) {
  const strip = (v) => String(v || '').trim().replace(/\+.*$/, '');
  const a = strip(installed);
  const b = strip(release);
  if (!a || !b) return null;
  if (a === b) return true;
  const pa = VERSION_PARTS_RE.exec(a);
  const pb = VERSION_PARTS_RE.exec(b);
  if (!pa || !pb || (pa[4] || '') !== (pb[4] || '')) return null;
  for (let i = 1; i <= 3; i += 1) {
    if (Number(pa[i]) !== Number(pb[i])) return Number(pa[i]) > Number(pb[i]);
  }
  if (pa[5] === undefined || pb[5] === undefined) return null;
  return Number(pa[5]) >= Number(pb[5]);
}

/**
 * 反馈详情里的安装信息：最近一次心跳、版本轨迹（每个版本首末出现的日子）、同一安装的其它反馈。
 * 反馈没带 installId → null；带了但该安装从没发过心跳（关了统计 / 已过保留期）→ install 为 null。
 */
export async function installTrail(env, installId, feedbackId, feedbackVerified = false) {
  if (!installId) return null;
  const install = await env.DB.prepare('SELECT * FROM installs WHERE install_id = ?1').bind(installId).first();
  const installVerified = install?.verified === 1;
  // 未验证的反馈声称自己属于一个已验证安装：id 谁都能抄，不把那个安装的轨迹 / 其它反馈挂到它上面。
  if (installVerified && !feedbackVerified) {
    return {
      installId, verified: false, claimsVerifiedInstall: true, install: null, versions: [], related: [],
    };
  }
  // 已验证安装只取已验证的心跳日与反馈：知道 id 的人用自报心跳 / 反馈塞进来的数据不进轨迹。
  const onlyVerified = installVerified ? 1 : 0;
  const versions = (await env.DB.prepare(
    `SELECT version, MIN(day) AS first_day, MAX(day) AS last_day FROM install_days
     WHERE install_id = ?1 AND verified >= ?2 GROUP BY version ORDER BY first_day`,
  ).bind(installId, onlyVerified).all()).results;
  const related = (await env.DB.prepare(
    `SELECT id, title, status, created_at FROM feedback
     WHERE install_id = ?1 AND id != ?2 AND install_verified >= ?4 ORDER BY created_at DESC LIMIT ?3`,
  ).bind(installId, feedbackId, INSTALL_LIMITS.relatedFeedback, onlyVerified).all()).results;
  return {
    installId,
    // 这条反馈提交时是否出示了该安装的证明（签名 + PoW）。
    verified: Boolean(feedbackVerified),
    claimsVerifiedInstall: false,
    install: install
      ? {
        verified: install.verified === 1,
        firstSeen: install.first_seen,
        lastSeen: install.last_seen,
        platform: install.platform,
        channel: install.channel,
        version: install.version,
      }
      : null,
    versions: versions.map((v) => ({ version: v.version, firstDay: v.first_day, lastDay: v.last_day })),
    related: related.map((r) => ({ id: r.id, title: r.title, status: r.status, createdAt: r.created_at })),
  };
}
