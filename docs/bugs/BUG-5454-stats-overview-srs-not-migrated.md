## BUG-5454 · stats-overview-srs-not-migrated
- **报告**：2026-11-25（用户：应用内反馈 m2tUYgIijK，Windows 3.4.0+32563，正文空、截图为统计中心「总览」显示「加载出错 / 重试」）
- **真实性**：✅ 真 bug。该用户的复习库自 11-21 起一直处于 `SrsStoreNotMigrated(needsMigration)`（还没在复习页点「开始升级」）。统计中心总览 `_StatsOverviewTab._load` 为并进复习时长直接 `await srsStorageProvider.future`，代际状态抛出后整页走 catch → 「加载出错」，重试同样失败（日志 88 条 `StatsOverviewTab.load`，21:12 八秒内重试约 30 次）；「复习」tab `SrsStatisticsTab._loadOnce` 同样把它当加载失败（3 条）。
- **[x] ① 已修复** — 总览改经 `statsOverviewSrsStorage`（fushi/lib/src/pages/implementations/statistics_center_page.dart:176）：`SrsStoreOpenBlocked` / `SrsLegacyMainDatabasePending` 时返回 null，总览照常出阅读 / 观看 / 游戏、只是不并复习时长，其余错误照抛；「复习」tab 记下代际状态（fushi/lib/src/pages/implementations/srs_statistics_page.dart:244）改给 `SrsGenerationView`（迁移页 / 恢复页），都不再写错误日志。迁移提交后 `srsStoreProvider` 出值，tab 里现有的监听自动重载。
- **[x] ② 已加自动化测试** — fushi/test/pages/stats_srs_open_blocked_test.dart：四种代际状态返回 null、真错误照抛；「复习」tab 待升级时出迁移页与「开始升级」、没有「加载出错」。
- **备注**：用户怀疑这个错误拖慢了复习页打开。查过不是：未迁移判定在 Rust 侧只是几次文件存在检查 + 换代锁（native/fushi_fsrs/src/store/gen4/files.rs `open_gen4`），打开失败被 `srsStorageProvider`（FutureProvider）缓存，不会每次进复习页重开；该用户的复习页显示的就是迁移页。
