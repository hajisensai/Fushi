## BUG-3722 · 从 Anki 迁移后制卡仍走 Anki，无切换到 Fushi SRS 选项
- **报告**：2026-10-23（来源：用户群反馈，报告人哈吉千歳）
- **现象**：从 Anki 迁移后制卡仍走 Anki，迁移设置里没有「切换到 Fushi SRS」的选项。
- **真实性**：✅ 真 bug。根因：迁移设置只有 `switchCardTarget`；新增默认开启项，成功后写 `srs_mining_target` 并关闭 `mine_to_server`（`srs_anki_migration.dart`）。
- **[x] ① 已修复** — `db0a9e6dd8`（分支 claude/fushi-srs-improvements-f158f4，PR hajisensai/Fushi#2464）
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_anki_migration_test.dart、srs_anki_migration_setup_test.dart`
- **备注**：无。
