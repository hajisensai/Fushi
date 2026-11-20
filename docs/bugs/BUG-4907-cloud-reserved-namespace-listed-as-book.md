## BUG-4907 · 云盘对比弹窗把 `__settings__` / `fushi-srs` 列成远端书、可被「删远端」整个删掉
- **报告**：2026-11-21（用户：开发者本人；BUG-4906 排查时发现，用户拍板要求查清并修）
- **真实性**：✅ 真 bug（行号为修复前 upstream/develop 76811fc25da）。`isReservedSyncFolderName`（`fushi/lib/src/sync/sync_orchestrator.dart:196-207`）逐个列保留命名空间名，漏了两个云通道真实会写的命名空间：可移植设置 `__settings__`（`settings_sync.dart:196`，`settings.part.dart:18` `ensureNamespace`）与复习同步 `fushi-srs`（`srs_location_store.dart:150`，`srs_profile_link.dart:235` 等 `ensureNamespace`）。三个列书入口都靠它排除：
  - 对比弹窗 `_fetchCompareData`（`sync_compare_dialog.dart:291-293`）：两个目录被当成远端书。里面没有 `.epub`，按 BUG-049 的规则成为「只剩元数据的远端书」——保留在列表里、行菜单带删除（`sync_compare_dialog.dart:2355-2366` → `_deleteRemote(isFolder: true)`），点一下就递归删掉云盘上**所有设备共用**的设置快照或整个复习同步集合（全部设备段 / 媒体 / 围栏）。
  - 云端书架 `CloudRemoteBookClient.listRemoteBooks`（`cloud_remote_book_client.dart:110-114`）：列出、并发探针一遍（无内容所以不上架，但每次多几次往返）。
  - 导入远端书 `importRemoteBooks`（`sync_orchestrator.dart:2266-2277`）：被当成待导入的远端书（无 `.epub` 被跳过）。
  互联通道不受影响（对比弹窗不列文件箱）。
- **[x] ① 已修复** — 保留命名空间判据收成一个真相源：引擎 `isReservedSyncNamespaceName`（`packages/fushi_engine/lib/sync/sync_reserved_namespaces.dart`，`__x__` 形状或 `fushi-srs`）；`isReservedSyncFolderName` 改为「空名或 `isReservedSyncNamespaceName`」，互联 host 的文件箱清理（BUG-4906）用同一个函数，两边不会再漂移。
- **[x] ② 已加自动化测试** — `fushi/test/sync/sync_compare_reserved_namespace_test.dart`（云盘根下有 `__settings__` / `fushi-srs` / `__pending_mines__` / 一本书时，对比弹窗只列那本书）；守卫 `fushi/test/sync/interconnect_file_box_prune_reserved_guard_test.dart` 扫源码里声明的全部同步命名空间常量，逐个要求 `isReservedSyncFolderName` 与 `isReservedSyncNamespaceName` 都认。
- **备注**：判据从「逐个列名」改成「`__x__` 形状」后，书名恰好是 `__xxx__` 形状的书（sanitize 后）不再出现在云盘对比弹窗里；实际书名几乎不可能是这个形状，换来的是新命名空间按约定起名即自动受保护。
