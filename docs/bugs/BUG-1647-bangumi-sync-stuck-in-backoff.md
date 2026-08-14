## BUG-1647 · Bangumi 同步失败后卡在退避窗口且无自动重试，只能手动同步
- **报告**：2026-08-14（用户：Bangumi 同步一直要手动同步才生效）
- **真实性**：✅ 真 bug。自动同步全仓只有两个触发点：启动一次（`fushi/lib/src/models/app_model.dart:2236` 的 `syncNow()`）+ 完成事件当下一次（`media_tracking_service.dart` `_enqueueAndSync`）。发送失败的行被 `MediaTrackingRepository.markFailed`（`media_tracking_repository.dart:1043`）推进 30s..6h 指数退避后，`dueUpdates`（同文件 :970）按 `nextAttemptAt` 把它过滤掉，而**没有任何定时器在退避到期时再拉一轮**：失败行只能等下一个完成事件碰巧到来且恰好已出窗口，否则永远要靠设置页/首页「立即同步」（`force=true` → `retryAllNow` 清退避）。看完一集那一刻网络抖一下，该集就再也不会自动同步——与用户症状完全同形。
- **[x] ① 已修复** — `MediaTrackingService` 每轮同步收尾时查 outbox 最早 `nextAttemptAt`（新增 `MediaTrackingRepository.earliestNextAttemptAt()`），挂一只 `Timer` 到点自动 `syncNow()`；下一轮同步开始即作废旧定时器，未配置令牌/零待办不挂。顺带覆盖单轮 20 条上限的积压续跑（剩余行 `nextAttemptAt=0` → 最小 5s 延迟续一轮）。`AppModel` 两处重建服务实例前先 `dispose()` 取消旧定时器。提交：（待填）
- **[x] ② 已加自动化测试** — `fushi/test/media/tracking/media_tracking_service_test.dart`「退避到期自动重试（BUG-1647）」组 3 例：失败后按 ~30s 退避安排重试且到期触发即重发成功；下一轮同步取消旧定时器、零待办不再安排；未配置令牌不安排。定时器工厂可注入（`TrackingRetryTimerFactory`），断言确定性。
- **备注**：不动 schema、不动 i18n。手动「立即同步」语义不变（仍是唯一会 `retryAllNow` 清退避的入口）；自动重试只是让退避表到期后真的有人来发。
