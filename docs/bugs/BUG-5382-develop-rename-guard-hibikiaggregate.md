## BUG-5382 · develop 旧代号守卫红：书级变更闸门另抄了一份聚合快照后缀表（含 `.hibikiaggregate`）
- **报告**：2026-11-24（release.yml run 45318894341，fe7110dbb7；f8f2847179 / 31b0a46cf4 同样红）
- **真实性**：✅ 真红。`fushi_rename_guard_test` 的「.hibiki* 资产扩展名」命中 `fushi/lib/src/sync/book_change_gate.dart:48`（#4346 书级变更清单新增的 `aggregateSnapshotDeviceOf`）。
  `.hibikiaggregate` 不是新造的名字：它是 W9-4 改名前 Hibiki 时代聚合快照的冻结后缀，云根迁移原样保留，读侧必须继续认；写侧一律 `.fushiaggregate`（`packages/fushi_engine/lib/sync/aggregate_sync_service.dart` 只写 `ownAssetName`），debug 通道从没写出过新的旧后缀文件，无需额外兼容。
- **根因** `fushi/lib/src/sync/book_change_gate.dart:45-55`：旧版客户端检测要从聚合快照名解析设备 id，没有复用引擎里唯一持有新旧后缀口径的 `aggregate_sync_service.dart`（`_aggregateAssetSuffix` / `_legacyAggregateAssetSuffix`），而是在 app 侧另抄一份后缀表。守卫白名单只圈定持兼容读入口的文件，第二份口径自然被判残留。
- **[x] ① 已修复** — 不加白名单：解析函数 `aggregateSnapshotDeviceOf` 挪进 `packages/fushi_engine/lib/sync/aggregate_sync_service.dart`，直接用那两个私有后缀常量；`book_change_gate.dart` 删掉自己的副本，`sync_orchestrator/book_change.part.dart` 用引擎版。后缀口径回到单一来源。
- **[x] ② 已加自动化测试** — `fushi/test/sync/sync_book_change_gate_test.dart`「聚合快照名 → 设备 id」：新旧后缀都识别、空设备 / 非快照名为 null；守卫本身 `fushi/test/tools/fushi_rename_guard_test.dart` 转绿。
- **备注**：同 PR 修 BUG-5383（import 环）。
