## BUG-5453 · tracking-backoff-overflow-hot-loop
- **报告**：2026-11-25（用户：所有者，「今天更新后同步特别慢」）
- **真实性**：✅ 真 bug。用户真库（debug.32552）里 Bangumi 令牌过期的一行 outbox `attempt_count=11308`、`next_attempt_at` 等于上次尝试时刻；error_log 每 7 秒一条 `MediaTrackingService.sync` unauthorized。根因 `packages/fushi_engine/lib/media/tracking/media_tracking_repository.dart:3054`：退避 `30 * math.pow(2, attempts - 1)` 在第 ~60 次失败后 int 溢出成负数 / 0，`min(6h, …)` 得到 ≤0，行立即到期；`_scheduleBackoffRetry` 于是按 5 秒下限无限重挂，每轮还对整库视频 / 书 / 游戏进度做一遍对账并写活动日志，持续占 DB 与主 isolate。
- **[x] ① 已修复** — 移位次数先钳在 10（`30 << 10` 已超 6h）再取 `min(6h, …)`，退避永不溢出；存量已溢出的行下一次失败即落到 6 小时，无需迁移。
- **[x] ② 已加自动化测试** — `fushi/test/media/tracking/media_tracking_service_test.dart`「长期失败的行退避钳在 6 小时…」：58/59/63/64/11308 次失败各验 nextAttemptAt = now+6h，并验 401 后重试定时器挂在 >5h 而非 5 秒。
- **备注**：这条热循环约从 11-24 下午起持续；用户说的「复习卡 / 书架同步慢」是否全由它造成未单独量化（SRS 同步走 Rust 自己的库，只受主 isolate / CPU 争用影响），修复后若仍慢需按阶段计时再查。
