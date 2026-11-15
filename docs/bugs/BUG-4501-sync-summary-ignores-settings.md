## BUG-4501 · sync-summary-ignores-settings
- **报告**：2026-11-15（应用内反馈 fRL7DLu0z4，Windows）：A 设备改设置并同步，B 设备再同步，设置确实同步过来了，但完成提示总是「无变化」。
- **真实性**：✅ 真 bug。`fushi/lib/src/sync/manual_sync_ui.dart:24-56`（修前）`summarizeSyncReport` 只数书 / 词典 / 有声书 / 字体 / 进度断点，不读 `SyncRunReport.settingsImported`（`sync_orchestrator.dart:374`，由 `sync_orchestrator/settings.part.dart:52` 累加）与 `serviceConfigsImported`；只同步了设置的一轮全部计数为 0，落到 `sync_now_no_changes`。发出方也没有任何「本机设置已发出」的计数。BUG-4302 只补了进度类。
- **[x] ① 已修复** — 摘要加三类：`↓N 项设置`（settingsImported）、`↑N 项设置`（新增 `SyncRunReport.settingsExported`）、`↓N 项服务配置`（serviceConfigsImported）。`settingsExported` 在本机快照真的回写时由 `countOutgoingSettingChanges`（`settings_sync.dart`）算：相对上一份已发布快照新增 / 改值的 key，扣掉本轮刚从对端采纳的 key（那只是回写合并结果）。`mergeFrom` 累加；不进 `needsLocalLibraryRefresh`（只影响远端）。新 i18n key 经 `i18n_sync.dart --add`。
- **[x] ② 已加自动化测试** — `fushi/test/sync/sync_summary_test.dart`（设置 / 服务配置各成一类、不再出现「无变化」）；`fushi/test/sync/portable_settings_sync_test.dart`（编排器两台设备：发布方 settingsExported=2、采纳方 0、改一项后 1、采纳回写 0、幂等轮 0）。
- **备注**：
