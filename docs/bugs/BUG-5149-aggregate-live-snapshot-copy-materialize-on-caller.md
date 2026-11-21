## BUG-5149 · aggregate-live-snapshot-copy-materialize-on-caller
- **报告**：2026-11-22（PR #4062 独立审查：BUG-5102 / HBK-AUDIT-028 修复后的残余，审计原文要求「大块解码、快照合并和编码放在同一后台所有者，轻量结果回传」）
- **真实性**：✅ 真问题（性能 / UI 卡顿，量级比 BUG-5102 修前小一个数量级）。BUG-5102 把互联聚合的编解码与合并 / 差集挪进了 `AggregatePureRunner`，但每一步都是一次性 `Isolate.run`，整份快照要在调用方与后台之间来回拷，且下面几段整份快照的 O(N) 工作仍在调用方 isolate（app 里即 UI isolate）：
  - 每次后台计算的入参（本地 materialize 结果、合并结果、上行快照）以消息深拷贝送进新 isolate：一轮互联同步 3 次（`packages/fushi_engine/lib/sync/aggregate_sync_service.dart` `_planLiveFoldOff` / `_foldDeltaOff` / `_outgoingIfChangedOff`），4 万行 / 族实测每次 35～50 ms 停在调用方（BUG-5102 的 bench）；上行编码这一跳修前 48 ms、修后 44 ms，基本没省——拷进去的成本与编码本身同量级。
  - `materializeLocalSnapshot`（`aggregate_sync_service.dart:1322`，调用点 :348 与锁内 `foldIntoLocal` :1858）把 DB 行组装成整份快照在调用方。
  - `filterTombstoned`（调用点 :362 / :395）按墓碑逐行裁剪整份合并结果在调用方。
  - host GET（`packages/fushi_engine/lib/sync/fushi_sync_server/sync_state.part.dart:53`）`getAggregateSnapshot` 在 host（app 内即 UI）isolate 组装快照，再整份拷进后台编码。
- **[ ] ① 未修复** — 根治方向：聚合同步整体（DB 读取 + 折叠 + 墓碑裁剪 + 编码）交给一个常驻后台所有者，调用方只搬报文体字节、拿回「是否写回 / 是否 PUT」这类轻量结果。候选：drift 后台 isolate（`computeWithDatabase`，库已是 `NativeDatabase.createInBackground`，见 `packages/fushi_core/lib/src/database/database.dart:366`）或按「Rust 胖核心」规则收编进 `native/fushi_*`。属架构取舍（写锁 `localApplyLock` 现为调用方 isolate 内的锁、跨 isolate 后语义要重定），动手前先定方向。
- **[ ] ② 未加自动化测试** — 修时补：一轮互联同步调用方 isolate 内不出现整份快照的组装 / 裁剪 / 拷贝（按 hop 计数或调用方最大停顿上限的 bench 断言）。
- **备注**：BUG-5102 的「备注」段原先只在已修复条目里提到残余，索引上是 ✅，不会被跟踪，故单开本条。云通道（`SyncAssetStore.getJsonAsset` / `putJsonAsset`）各后端的快照 JSON 编解码同样在调用方，一并在此处理。
