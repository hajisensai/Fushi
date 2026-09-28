// 固定窗口计数限流（D1 原子 upsert + RETURNING）。
// 只用于低频写入口（注册按 IP、上传按账户）；读接口的限流交给 Cloudflare WAF 规则。

import { HttpError } from './util.js';

export const LIMITS = {
  registerPerIpHour: 5,
  shelfUploadPerHour: 12,
  mediaUploadPerHour: 60,
  socialWritePerHour: 120,
};

export async function hit(env, bucket, windowMs, limit, now) {
  const windowStart = Math.floor(now / windowMs) * windowMs;
  const row = await env.DB
    .prepare(
      `INSERT INTO rate_limits (bucket, window_start, count) VALUES (?1, ?2, 1)
       ON CONFLICT (bucket, window_start) DO UPDATE SET count = count + 1
       RETURNING count`,
    )
    .bind(bucket, windowStart)
    .first();
  if (row.count > limit) throw new HttpError(429, 'rate_limited');
}

/** 清掉早于 cutoff 的窗口（scheduled 里跑）。 */
export async function purgeRateLimits(env, cutoff) {
  await env.DB.prepare('DELETE FROM rate_limits WHERE window_start < ?1').bind(cutoff).run();
}
