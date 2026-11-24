## BUG-5373 · 系列「不合并」偏好存本机合集 id 却随备份 / 设置同步出境
- **报告**：2026-11-24（来源：#4196 图书追踪系列关联审查遗留）
- **真实性**：✅ 真 bug。行号为 ec4b8dd51f：
  - `packages/fushi_engine/lib/media/tracking/media_tracking_service.dart:108,123` 键 `media_tracking_<site>_book_series_merge_declined_v1`；`:2936-2955` `declineSeriesMerge` / `_declinedSeriesMerges` 把用户点了「不合并」的系列卡 **本机合集自增 id**（逗号分隔）写进去。
  - 这个键没登记为设备本地：`fushi/lib/src/sync/pref_redaction_policy.dart:177` `isDeviceLocalOrCredential`（备份导出剔除 / 导入保留本机值、Profile 快照与分享、设置同步 `PortableSettingsPolicy` 经 `ProfileKeys.isExcludedPref` 共用的唯一谓词）只认 `SyncRepository.deviceLocalPrefKeys` 白名单与 `deviceLocalKeyPrefixes` 前缀；键中间夹着站点 id（插件站点不可枚举），两种都登记不了。
  - 影响：备份恢复到别的设备、或设置同步过去后，那台设备的同号合集是另一张系列卡——真该提示合并的卡被静默跳过，用户没点过「不合并」也看不到候选。同类先例：`book_scrape_ignored_works` 等本机 id 键（BUG-5283）登记在 `deviceLocalPrefKeys`。
- **[x] ① 已修复** — `PrefRedactionPolicy` 新增 `deviceLocalKeySuffixes`（按结尾认的设备本地状态，与前缀登记同一谓词）；引擎导出 `kTrackingSeriesMergeDeclinedPrefSuffix = '_book_series_merge_declined_v1'`，`TrackingProviderPrefKeys` 用它拼键（键名不变，存量值照读），策略按它登记。备份 / Profile / 设置同步 / ctl 设置读写全部经 `isDeviceLocalOrCredential`，一处登记全覆盖。
- **[x] ② 已加自动化测试** — `fushi/test/sync/tracking_series_merge_declined_device_local_test.dart`：插件站点与 Bangumi 冻结键都被三条谓词认作设备本地、同站点 `enabled` 键不被误伤；真实 `BackupService.createBackup` 导出的包里没有这两个键；恢复到别的设备保留那台设备自己的值、普通设置照常恢复。
- **备注**：
