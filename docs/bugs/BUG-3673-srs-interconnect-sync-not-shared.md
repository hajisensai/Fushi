## BUG-3673 · Fushi SRS 通过互联同步不互通
- **报告**：2026-10-23（来源：用户群反馈，报告人哈吉千歳）
- **现象**：Fushi SRS 经互联同步，两台设备互不互通。
- **真实性**：✅ 真 bug。根因：同步目录按 profileUid 分（`srs_asset_store_directory.dart` 约 37 行）；每台设备首次随机生成各自的 uid（`packages/fushi_core/lib/src/database/database_srs.part.dart` 约 101 行）；设计规则 E 的新设备关联只在备份恢复里实现，互联路径没有。
- **[x] ① 已修复** — `db0a9e6dd8`（分支 claude/fushi-srs-improvements-f158f4，PR hajisensai/Fushi#2464）
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/srs/srs_profile_link_test.dart、srs_profile_link_sync_test.dart、fushi/test/sync/interconnect_srs_two_way_sync_test.dart`
- **备注**：无。
