## BUG-5063 · gen4 迁移对拍：4.7 GB 库第 7/10 步后 stats 两侧 log_id 集合不一致回滚
- **报告**：2026-11-21（应用内反馈 9G1OHF2dQe：复习库升级卡在 7/10 超过 30 分钟，随后对拍失败并回滚，srs.db 4.7 GB）
- **真实性**：⏳ 待复现。日志显示对拍报告里 stats 两侧 log_id 集合完全不同（各 162960 条），canonicalCounts 却一致，2387 张卡的重放列不一致，knownDifferences 为 0。推测根因在 `native/fushi_fsrs/src/store/gen4/compare.rs`（STAT_COLS 约 :535，stats 对拍约 :940-950）：带盐 / derived 别名的日志 ID 两侧写法不同，对拍前没有先归一。与 BUG-5056（a7e1258ca1、cb5d32859d，classRegisters 加事件副本）签名不同；用户跑的 30040 包早于 5056 修复。
- **[ ] ① 未修复** — 需要用户的 srs.db（或 srs4.db-migrating）副本，用 gen4_dryrun 复现；确认后在对拍前把两侧 log_id 过 CanonMap / 别名归一，报告补差异列与归一信息。
- **[ ] ② 未加自动化测试** — 复现后用最小化样本加 compare.rs 单测。
- **备注**：第 7/10 步重建 6.8M 条操作耗时 1537 秒，慢的问题另看。junction 路径显示不算 bug。
