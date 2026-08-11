## BUG-1579 · 合集与删除墓碑因果基线三方共用：对端移出被自己另一条通道撤销
- **报告**：2026-08-12（用户：审计）
- **真实性**：✅ 真 bug（沿双通道 sweep + host 收 POST 的真实代码路径核实）

### 根因（两条同形的因果轴）

**① 合集同步基线 `sync_collections_baseline_ms`**（`fushi/lib/src/sync/sync_repository.dart:96,237-243`）
被**三方**读写：

- 云通道：`fushi/lib/src/sync/sync_orchestrator.dart:788` 读 / `:829` 写；
- 互联 client 通道：`fushi/lib/src/sync/sync_orchestrator.dart:874` 读 / `:891` 写；
- 本机作为互联 host 收对端 POST：`fushi/lib/src/sync/app_model_library_host_service.dart:1640-1648`。

基线的语义是「本端相对**某一个远端**见过共享清单到什么时刻」，三条轴共用一个标量必然互相污染。
双通道下的具体后果：云通道刚把基线推到 T，互联对端推来的成员移出墓碑（`removedAt < T`）被
`fushi/lib/src/sync/collection_sync_engine.dart:150-215` 判成旧闻 → 按「活胜」**撤销**这次移出 →
再经 `putRemoteCollectionManifest` 回传给 host。用户的移出操作被自己另一条通道悄悄撤销。

**② 删除墓碑消费基线 `sync_deletion_tombstones_baseline_ms`**（`sync_repository.dart:135-137`）
被云（`sync_orchestrator.dart:1012-1033`）与互联（`:1084-1100`）共读，推进点
`fushi/lib/src/sync/deletion_prompt.dart:330-334` 按**单通道** high-water 推。**推送**基线早就是
互联专属的独立键（`sync_repository.dart:255-267`，注释写明「两个通道各记各的账」），消费侧却仍
是一份全局键，两边不对称。后果：用户在云通道的确认框里处理完一批删除、基线推到 T，互联对端此前
那批 `deletedAt < T` 的墓碑就此**永远不再弹确认**——那些条目留在本机，而用户以为「所有设备都删了」。

### 修复
两条基线都按 `SyncChannelScope`（BUG-1576 引入）分槽：

- 云 / 互联 client 各用自己后端反查出的槽位（`SyncOrchestrator._scope`）；
- host 侧用 `SyncChannelScope.host` 这条独立轴；
- `SyncRunReport.deletionTombstonesHighWaterMs` 由标量改成
  `deletionTombstonesHighWaterMsByScope`（`Map<scopeId, int>`），`mergeFrom` 逐槽位取 max
  ——手动同步会把两条通道的报告合并成一份，标量在那一刻就把「这个时刻相对哪个远端」丢了；
  `DeletionPromptPrompter.present` 改为逐槽位推进基线。

**迁移语义**：per-channel 键无值时**回落解耦前的全局键作初值**（读时 fallback，写侧只写本槽位，
旧键只读不写）。升级后第一轮不会把所有历史墓碑当成新闻重裁一遍，也不会把用户早已复核过的老墓碑
再逐条弹一遍。「回落到更高的基线」在两条轴上都是保守方向（少删、少弹）。
`SyncRepository.deviceLocalPrefKeys` 同步展开成「基名 × 全部槽位」，否则新键会随备份跨设备泄漏。

- **[x] ① 已修复** — 见本文件所在提交
- **[x] ② 已加自动化测试** — `fushi/test/sync/sync_channel_scope_test.dart`
  （三条轴互不影响 / 旧全局键作初值且只读不写 / 一条通道推进不压制另一条 / high-water 逐槽位
  merge / 设备本地键目录展开）；变异实测：把 `setCollectionsSyncBaselineMs` 改回写全局键 → 用例红。
- **备注**：与消费基线镜像对称的**推送**基线（互联专属）本就独立，此次不动。
