// 防 Cloudflare 超额计费的熔断器。
//
// Workers Free 计划超额只会报错、不会扣费；但 D1 / R2 在付费计划或绑定了支付方式时按量计费，
// 所以服务端自己设两道硬上限，默认值都低于免费额度：
//   - 全局日预算（budgets 表，UTC 日）：写入行数 / 媒体上传次数 / 注册数。超了返回 503，次日自动恢复。
//   - R2 总存储配额（media_usage 单行）：超了拒收新图片（507），删除图片时归还。
// 预算用 env 覆盖：BUDGET_WRITE_ROWS / BUDGET_MEDIA / BUDGET_REGISTER / BUDGET_EMAIL / BUDGET_FEEDBACK / MEDIA_QUOTA_BYTES。

import { HttpError, utcDateKey } from './util.js';

/** D1 免费额度 10 万行写入/天；留两成余量给限流计数、防重放记录与定时快照。 */
/** email 默认 90：低于 Resend 免费额度 100 封/天。 */
/** feedback 默认 300：每天新反馈条数上限（附件另扣 media）。 */
export const DEFAULT_BUDGETS = { write_rows: 80000, media: 3000, register: 2000, email: 90, feedback: 300 };
/** R2 免费额度 10 GB；默认只用 8 GB。 */
export const DEFAULT_MEDIA_QUOTA_BYTES = 8 * 1024 * 1024 * 1024;

export function budgetLimit(env, kind) {
  const v = Number(env[`BUDGET_${kind.toUpperCase()}`]);
  return Number.isFinite(v) && v > 0 ? v : DEFAULT_BUDGETS[kind];
}

export function mediaQuota(env) {
  const v = Number(env.MEDIA_QUOTA_BYTES);
  return Number.isFinite(v) && v > 0 ? v : DEFAULT_MEDIA_QUOTA_BYTES;
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

/** 预占 R2 字节；超过配额抛 507 media_quota（条件 UPDATE，原子）。 */
export async function reserveMediaBytes(env, bytes) {
  const res = await env.DB.prepare(
    'UPDATE media_usage SET bytes = bytes + ?1 WHERE id = 1 AND bytes + ?1 <= ?2',
  ).bind(bytes, mediaQuota(env)).run();
  if (res.meta.changes !== 1) throw new HttpError(507, 'media_quota');
}

export async function releaseMediaBytes(env, bytes) {
  if (bytes <= 0) return;
  await env.DB.prepare('UPDATE media_usage SET bytes = MAX(0, bytes - ?1) WHERE id = 1').bind(bytes).run();
}

/** 删除 R2 对象并归还配额（先 head 取大小；head 是 B 类操作，免费额度 1000 万次/月）。 */
export async function deleteMedia(env, keys) {
  const list = (Array.isArray(keys) ? keys : [keys]).filter(Boolean);
  if (list.length === 0) return;
  let freed = 0;
  for (const key of list) {
    const head = await env.MEDIA.head(key);
    if (head) freed += head.size;
  }
  await env.MEDIA.delete(list);
  await releaseMediaBytes(env, freed);
}

/** 清掉 7 天前的预算行（scheduled）。 */
export async function purgeBudgets(env, now) {
  await env.DB.prepare('DELETE FROM budgets WHERE day < ?1').bind(utcDateKey(now - 7 * 24 * 3600 * 1000)).run();
}
