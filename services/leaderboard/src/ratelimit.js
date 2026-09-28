// 固定窗口计数限流（D1 原子 upsert + RETURNING）。
// 只用于低频写入口（注册按 IP、上传按账户）；读接口的限流交给 READ_LIMITER binding（worker.js）。

import { HttpError } from './util.js';

export const HOUR = 3600 * 1000;
export const DAY = 24 * HOUR;

export const LIMITS = {
  registerPerIpHour: 5,
  /** 首次同步 8000 条 = 16 批，一小时内要能传完。 */
  shelfUploadPerHour: 40,
  /**
   * 每账户每天估算写入行数上限：一个账户反复 reset 也吃不光全局预算。
   * 代价（如实）：D1 每写一行、每个受影响索引另计一行，8000 部的超大书架首次同步约 4 万行，
   * 会被拆到两三天里续传（客户端保存已推进的进度，遇 429 / 503 次日继续）；几百部的普通书架一次传完。
   */
  shelfRowsPerAccountDay: 20000,
  mediaUploadPerHour: 60,
  socialWritePerHour: 120,
};

/** 在 bucket 的当前窗口里累加 amount（默认 1），超过 limit 抛 429。 */
export async function hit(env, bucket, windowMs, limit, now, amount = 1) {
  const windowStart = Math.floor(now / windowMs) * windowMs;
  const row = await env.DB
    .prepare(
      `INSERT INTO rate_limits (bucket, window_start, count) VALUES (?1, ?2, ?3)
       ON CONFLICT (bucket, window_start) DO UPDATE SET count = count + ?3
       RETURNING count`,
    )
    .bind(bucket, windowStart, amount)
    .first();
  if (row.count > limit) throw new HttpError(429, 'rate_limited');
}

/** 清掉早于 cutoff 的限流窗口，以及已超出签名时效的防重放记录（scheduled 里跑）。 */
export async function purgeRateLimits(env, cutoff, sigCutoff) {
  await env.DB.batch([
    env.DB.prepare('DELETE FROM rate_limits WHERE window_start < ?1').bind(cutoff),
    env.DB.prepare('DELETE FROM used_sigs WHERE time < ?1').bind(sigCutoff),
  ]);
}
