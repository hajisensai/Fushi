// 安装统计：客户端每天一次的心跳与开发者处理台的统计数据（表结构见 migrations/0011_install_stats.sql）。
//
//   POST /v1/ping  {installId, version, platform, channel} → 204
//
// installId 是客户端随机生成的 UUID v4（不挂账户、不挂设备硬件），只用来按天去重。服务端不存 IP：
// 限流靠 Workers Rate Limiting binding（worker.js 里按 IP 过 AUTH_LIMITER），不落 D1。
// 同一安装同一天的第二次心跳只读一次 install_days 就返回，不写库、不扣预算；当天第一次心跳扣
// 'ping' 日预算 1 次，再写两行（install_days 插一行、installs upsert 一行）。随机伪造 installId 刷量
// 受 binding（每 IP 每分钟 10 次）和 'ping' 日预算双重限制，超了 503，不影响榜单与反馈。
//
// 反馈与安装的关联：反馈提交时客户端可带 installId（勾选「附带设备信息」才带），存在 feedback.install_id。
// 开发者处理台据此展示该安装的版本轨迹、同一安装的其它反馈，以及修复版本是否已装上（installTrail）。
// installId 是客户端自报的，可伪造——处理台展示时与设备信息一样标注。

import { HttpError, utcDateKey } from './util.js';
import { spend } from './budget.js';

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

/** POST /v1/ping。当天已记过 → 什么都不写。 */
export async function recordPing(env, body, now) {
  const p = normalizePing(body);
  const day = utcDateKey(now);
  const seen = await env.DB.prepare('SELECT 1 AS x FROM install_days WHERE day = ?1 AND install_id = ?2')
    .bind(day, p.installId).first();
  if (seen) return;
  await spend(env, 'ping', 1, now);
  await env.DB.batch([
    env.DB.prepare(
      `INSERT OR IGNORE INTO install_days (day, install_id, platform, channel, version)
       VALUES (?1, ?2, ?3, ?4, ?5)`,
    ).bind(day, p.installId, p.platform, p.channel, p.version),
    env.DB.prepare(
      `INSERT INTO installs (install_id, first_seen, last_seen, platform, channel, version)
       VALUES (?1, ?2, ?2, ?3, ?4, ?5)
       ON CONFLICT (install_id) DO UPDATE SET
         last_seen = MAX(last_seen, ?2), platform = ?3, channel = ?4, version = ?5`,
    ).bind(p.installId, now, p.platform, p.channel, p.version),
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
 */
export async function installStats(env, now) {
  const today = utcDateKey(now);
  const since = (days) => utcDateKey(now - (days - 1) * DAY_MS);
  const distinct = async (days) => (await env.DB.prepare(
    'SELECT COUNT(DISTINCT install_id) AS n FROM install_days WHERE day >= ?1',
  ).bind(since(days)).first()).n;
  const platformCols = PING_PLATFORMS.map((p) => `SUM(platform = '${p}') AS ${p}`).join(', ');
  const daily = (await env.DB.prepare(
    `SELECT day, COUNT(*) AS n, ${platformCols} FROM install_days
     WHERE day >= ?1 GROUP BY day ORDER BY day DESC`,
  ).bind(since(INSTALL_LIMITS.dailyRows)).all()).results;
  const fresh = (await env.DB.prepare(
    `SELECT strftime('%Y-%m-%d', first_seen / 1000, 'unixepoch') AS day, COUNT(*) AS n FROM installs
     WHERE first_seen >= ?1 GROUP BY day`,
  ).bind(Date.parse(`${since(INSTALL_LIMITS.dailyRows)}T00:00:00Z`)).all()).results;
  const newByDay = Object.fromEntries(fresh.map((r) => [r.day, r.n]));
  const activeSince = now - 30 * DAY_MS;
  const dist = async (col, limit) => countBy((await env.DB.prepare(
    `SELECT ${col}, COUNT(*) AS n FROM installs WHERE last_seen >= ?1
     GROUP BY ${col} ORDER BY n DESC, ${col} LIMIT ${limit}`,
  ).bind(activeSince).all()).results, col);
  return {
    today,
    dau: daily.find((r) => r.day === today)?.n ?? 0,
    wau: await distinct(7),
    mau: await distinct(30),
    total: (await env.DB.prepare('SELECT COUNT(*) AS n FROM installs').first()).n,
    daily: daily.map((r) => ({
      day: r.day,
      n: r.n,
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
export async function installTrail(env, installId, feedbackId) {
  if (!installId) return null;
  const install = await env.DB.prepare('SELECT * FROM installs WHERE install_id = ?1').bind(installId).first();
  const versions = (await env.DB.prepare(
    `SELECT version, MIN(day) AS first_day, MAX(day) AS last_day FROM install_days
     WHERE install_id = ?1 GROUP BY version ORDER BY first_day`,
  ).bind(installId).all()).results;
  const related = (await env.DB.prepare(
    `SELECT id, title, status, created_at FROM feedback
     WHERE install_id = ?1 AND id != ?2 ORDER BY created_at DESC LIMIT ?3`,
  ).bind(installId, feedbackId, INSTALL_LIMITS.relatedFeedback).all()).results;
  return {
    installId,
    install: install
      ? {
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
