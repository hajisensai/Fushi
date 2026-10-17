// 防 Cloudflare 超额计费的熔断器。
//
// Workers Free 计划超额只会报错、不会扣费；但 D1 / R2 在付费计划或绑定了支付方式时按量计费，
// 所以服务端自己设两道硬上限，默认值都低于免费额度：
//   - 全局日预算（budgets 表，UTC 日）：写入行数 / 媒体上传次数 / 注册数。超了返回 503，次日自动恢复。
//   - R2 总存储配额（media_usage 单行）：超了拒收新图片（507），删除图片时归还。总配额分两池：
//     反馈视频单独一池（media_usage.video_bytes，默认 1 GiB），其余（头像 / 封面 / 反馈截图与日志）
//     用剩下的（media_usage.bytes）。视频单个 50 MB、能匿名上传，同一池的话几个 IP 就能把总配额
//     打满、让全站头像封面一起 507 上一个月；分池后视频满了只拒视频。
// 预算用 env 覆盖：BUDGET_WRITE_ROWS / BUDGET_MEDIA / BUDGET_REGISTER / BUDGET_EMAIL / BUDGET_FEEDBACK / BUDGET_PING /
// MEDIA_QUOTA_BYTES / VIDEO_QUOTA_BYTES。

import { HttpError, utcDateKey } from './util.js';

/** D1 免费额度 10 万行写入/天；留两成余量给限流计数、防重放记录与定时快照。 */
/** email 默认 90：低于 Resend 免费额度 100 封/天。 */
/** feedback 默认 300：每天新反馈条数上限（附件另扣 media）。 */
/**
 * ping 默认 4000：每天记入统计的安装数上限（installs.js；同一安装当天第二次心跳不扣）。每次记入
 * 连同索引与预算计数约写 5 行，最多约 2 万行；独立于 write_rows，刷量打满只停统计、不停榜单与反馈。
 * write_rows 已占 8 万，D1 免费额度 10 万行/天，所以默认值压在剩余两成以内；日活逼近上限时
 * 先升级 Workers 付费计划再用 BUDGET_PING 调高。
 */
export const DEFAULT_BUDGETS = { write_rows: 80000, media: 3000, register: 2000, email: 90, feedback: 300, ping: 4000 };
/** R2 免费额度 10 GB；默认只用 8 GB。 */
export const DEFAULT_MEDIA_QUOTA_BYTES = 8 * 1024 * 1024 * 1024;
/** 反馈视频池默认 1 GiB（从总配额里切出来，不另加）。 */
export const DEFAULT_VIDEO_QUOTA_BYTES = 1024 * 1024 * 1024;

/** 配额池 → media_usage 的列。列名只从这张表取，不拼外部输入。 */
export const MEDIA_POOLS = { media: 'bytes', video: 'video_bytes' };
/** 各池超额时的错误码（都是 507）。 */
const POOL_ERRORS = { media: 'media_quota', video: 'video_quota' };

export function budgetLimit(env, kind) {
  const v = Number(env[`BUDGET_${kind.toUpperCase()}`]);
  return Number.isFinite(v) && v > 0 ? v : DEFAULT_BUDGETS[kind];
}

export function mediaQuota(env) {
  const v = Number(env.MEDIA_QUOTA_BYTES);
  return Number.isFinite(v) && v > 0 ? v : DEFAULT_MEDIA_QUOTA_BYTES;
}

/** 视频池大小：VIDEO_QUOTA_BYTES（默认 1 GiB），最多切走总配额的一半，头像 / 封面那份永远留得下。 */
export function videoQuota(env) {
  const v = Number(env.VIDEO_QUOTA_BYTES);
  const want = Number.isFinite(v) && v > 0 ? v : DEFAULT_VIDEO_QUOTA_BYTES;
  return Math.min(want, Math.floor(mediaQuota(env) / 2));
}

/** 某个池的上限：视频池 = videoQuota；普通池 = 总配额减去视频池（两池之和不超过 MEDIA_QUOTA_BYTES）。 */
export function poolQuota(env, pool) {
  return pool === 'video' ? videoQuota(env) : mediaQuota(env) - videoQuota(env);
}

function poolColumn(pool) {
  const col = MEDIA_POOLS[pool];
  if (!col) throw new Error(`unknown media pool: ${pool}`);
  return col;
}

/** 从今天的全局预算里扣 amount；超了抛 503 daily_budget（已扣的不退——超额当天本就该停）。 */
export async function spend(env, kind, amount, now) {
  if (amount <= 0) return;
  const row = await env.DB.prepare(
    `INSERT INTO budgets (day, kind, used) VALUES (?1, ?2, ?3)
     ON CONFLICT (day, kind) DO UPDATE SET used = used + ?3
     RETURNING used`,
  ).bind(utcDateKey(now), kind, amount).first();
  if (row.used > budgetLimit(env, kind)) throw new HttpError(503, 'daily_budget', kind);
}

/** 按实际用量校正今天的预算（delta 可为负；不做超限判断——判断在写入之前的 spend 里）。 */
export async function adjustSpend(env, kind, delta, now) {
  if (!delta) return;
  await env.DB.prepare(
    `INSERT INTO budgets (day, kind, used) VALUES (?1, ?2, MAX(0, ?3))
     ON CONFLICT (day, kind) DO UPDATE SET used = MAX(0, used + ?3)`,
  ).bind(utcDateKey(now), kind, delta).run();
}

/**
 * 在 pool 里预占 R2 字节；超过该池上限抛 507（普通池 media_quota、视频池 video_quota）。条件 UPDATE，原子。
 * 只看本池的列：视频池满了不影响普通池，反之亦然。
 */
export async function reserveMediaBytes(env, bytes, pool = 'media') {
  const col = poolColumn(pool);
  const res = await env.DB.prepare(
    `UPDATE media_usage SET ${col} = ${col} + ?1 WHERE id = 1 AND ${col} + ?1 <= ?2`,
  ).bind(bytes, poolQuota(env, pool)).run();
  if (res.meta.changes !== 1) throw new HttpError(507, POOL_ERRORS[pool]);
}

/** 归还 pool 里的字节（必须与预占时同一个池）。 */
export async function releaseMediaBytes(env, bytes, pool = 'media') {
  if (bytes <= 0) return;
  const col = poolColumn(pool);
  await env.DB.prepare(`UPDATE media_usage SET ${col} = MAX(0, ${col} - ?1) WHERE id = 1`).bind(bytes).run();
}

/**
 * 删除 R2 对象并归还配额到 pool（先 head 取大小；head 是 B 类操作，免费额度 1000 万次/月）。
 * 一次调用里的 keys 必须同属一个池（反馈视频走 'video'，其余默认 'media'）。
 */
export async function deleteMedia(env, keys, pool = 'media') {
  const list = (Array.isArray(keys) ? keys : [keys]).filter(Boolean);
  if (list.length === 0) return;
  let freed = 0;
  for (const key of list) {
    const head = await env.MEDIA.head(key);
    if (head) freed += head.size;
  }
  await env.MEDIA.delete(list);
  await releaseMediaBytes(env, freed, pool);
}

/** 清掉 7 天前的预算行（scheduled）。 */
export async function purgeBudgets(env, now) {
  await env.DB.prepare('DELETE FROM budgets WHERE day < ?1').bind(utcDateKey(now - 7 * 24 * 3600 * 1000)).run();
}
