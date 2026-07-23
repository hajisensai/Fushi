# 删除墓碑接线施工图（发布层 + 消费层）

> 供 Phase C/D 实现照抄。file:line 基准为本 worktree。现存基建见 `deletion_propagation.dart` + `database.dart:4727-4761`。

## 主同步入口
`SyncOrchestrator.run()` `sync_orchestrator.dart:322`；`isInterconnect = b is HibikiClientSyncBackend` `:338`。云 + 互联共用 `run()`，各阶段 `if(isInterconnect)` 分流。
子同步序列：books-content-live(:344) → syncAllBooks(:365) → conflicts(:386) → dictionaries(:388) → localaudio/audiobook/video(:393-404) → progress-live(:419-421) → aggregate(:426/:434) → **collections(:445-449)** → setLastSyncMs(:457) → return(:459)。
**墓碑两步落点：`:449`↔`:457` 之间**新增 `syncDeletionTombstones(report)`（云）/ `_syncDeletionTombstonesLive(report,b)`（互联）。`runCollectionsOnly()` `:532` 不挂墓碑（不宜高频弹）。

## 资产存取接口 `SyncAssetStore`（`sync_asset_store.dart`）
`SyncBackend implements SyncAssetStore` `sync_backend.dart:85`。墓碑只用：`ensureNamespace(name)` `:30` / `listChildren(nsId)` `:36` / `getJsonAsset(assetId)` `:57` / `putJsonAsset(ns,name,json)` `:60` / `deleteAsset(id)` `:70`。`AssetEntry{id,name,isFolder,sizeBytes?}` `:4-24`（遍历用 `e.name` 匹配、`e.id` 读）。
**必做**：`kSyncTombstonesNamespace='__tombstones__'` 加进 `isReservedSyncFolderName(...)` `sync_orchestrator.dart:88-94`，否则云端列书会把它当书导入。

## 发布配方（照 `deleteRemoteDictionaryAsset` `sync_orchestrator.dart:102-114`）
```
final ns = await backend.ensureNamespace(kSyncTombstonesNamespace);
for (row in await db.getSyncDeletionTombstones() where remotePublishedAt==0):
  await backend.putJsonAsset(ns, deletionTombstoneAssetName(row.mediaType,row.itemKey),
       deletionTombstoneJson(row.mediaType,row.itemKey,row.deletedAt));
  await db.markSyncDeletionPublished(row.mediaType,row.itemKey, now);
```

## 云模板 `syncCollections` `sync_orchestrator.dart:545-654`（照抄成 `syncDeletionTombstones`）
try包裹(:546) → ensureNamespace(:547) → SyncRepository(:549) → **预取 nextBaseline=now(:554)** → listChildren遍历+getJsonAsset(:561-602，坏文件进report.errors) → 读本地(:604) → 时钟回拨钳制(:606-609) → 折叠远端并集(:613) → **merge→墓碑改 computeDeletionPropagation** → apply(消费不在此删，候选塞report) → putJsonAsset回写门槛(:629-636) → 推进基线(:646-650)。
互联孪生 `_syncCollectionsLive` `:670-715`。

## 互联 host（`hibiki_sync_server.dart`）
路由分发 `_handleRequest` `:484`；合集端点注册 `:553-554`。**新增** `:555` 后 `if(reqPath=='/api/tombstones') return _handleTombstones(request,method);`（走已配对 Basic token）。
端点实现照 `_handleLibraryCollections` `:2153-2192`：GET → `db.getSyncDeletionTombstones()` → JSON 数组，`headers: application/json; charset=utf-8`（CJK 必带）。只需 GET，不需 POST。`HibikiLibraryHostService` 加 `listDeletionTombstones()`。

## 互联 client（`hibiki_client_sync_backend.dart`）
照 `getRemoteCollectionManifest()` `:849-863`（404→drain+null 老 host 降级）新增 `getRemoteDeletionTombstones()`，URL `/api/tombstones`，body 解 List → `parseDeletionTombstoneJson` 逐条。orchestrator 互联分支注入，照 `_syncAggregateLive` 注入 `getRemoteAggregate` `:490-502`。

## 消费基线（`sync_repository.dart`，防旧墓碑反复弹）
不用 SyncBaselines 表；走 Preferences KV。照合集三处：
1. 键 `_keyDeletionTombstonesBaselineMs='sync_deletion_tombstones_baseline_ms'`（近 `:97`）。
2. `getDeletionTombstonesBaselineMs()` / `setDeletionTombstonesBaselineMs(int)`（照 `:226-232`）。
3. 加进 `deviceLocalPrefKeys`（`:791-792`）——设备本地，不随备份跨设备恢复。
守卫：消费只喂 `deletedAt > baseline` 的远端墓碑；`remotePublishedAt`（DB 字段）用于发布去重。

## 确认弹窗回传（同步在无 context 后台锁里跑！）
触发全在 `sync_auto_trigger.dart` 的 `_autoSyncMutex.withLock`（无 BuildContext）：`_runAutoSyncAll` `:270`(锁:289)、`runManualFullSync` `:365`、关书单本 `_runAutoSync` `:544`。**不能在同步内 showDialog**。
回传通道：`typedef SyncReportCallback = void Function(SyncRunReport, SyncBackend)` `:67`；调用点 `_runAutoSyncAll:318` / 单本 `:616`。落地 `AppModel.presentAutoConflicts` `app_model.dart:473-487` 经全局 navigatorKey(`:522-526`)弹。委托 `SyncConflictPrompter.present` `sync_conflict_prompter.dart:51-80`（navigatorKey.currentContext null 安全 + 会话 snooze）。
**墓碑接法**：
1. `SyncRunReport` `sync_orchestrator.dart:144-211` 加 `List<DeletionPropagationCandidate> deletionCandidates=[]`（照 conflicts:181），`mergeFrom` `:196-210` 累加（照:209）。消费层填 deleteLocal 候选。
2. 新建 `DeletionPromptPrompter`（照 `sync_conflict_prompter.dart` 81行：navigatorKey+snooze+单飞）。
3. `AppModel.presentDeletionCandidates(report,backend)`（照 `presentAutoConflicts`），onReport 里与冲突并列调；background 路径不传（后台不弹）。

## 候选列表 UI（复用 `sync_compare_dialog.dart`）
`SyncCompareDialog` `:484`；ListView `:1008`；单项 `_buildEntry` `:1161-1293`（`HibikiCard` + `_directionIcon` `:1177` + Text ellipsis + overflow menu）。新建精简 `DeletionPromptDialog`：每候选一 `HibikiCard`+Checkbox（勾=本地也删），底「全选/删选中/取消」。弹出照 `sync_conflict_prompter.dart:66-73`（barrierDismissible:false）。
确认后调各实体 raw 删除（传「同步专用、不写新墓碑」标志）+ 删磁盘缓存 + `setDeletionTombstonesBaselineMs(nextBaseline)`；拒绝记会话 snooze。

## 施工次序
1. sync_repository 基线键/读写/deviceLocal
2. sync_orchestrator：保留文件夹 + syncDeletionTombstones/_live 孪生 + run()接线 + SyncRunReport.deletionCandidates
3. hibiki_sync_server：/api/tombstones + handler + HibikiLibraryHostService.listDeletionTombstones
4. hibiki_client_sync_backend：getRemoteDeletionTombstones (404→null)
5. UI：DeletionPromptPrompter + AppModel.presentDeletionCandidates + DeletionPromptDialog + onReport 接线
（+ Phase A 源端 scope 弹窗；+ Phase B 全实体写墓碑）
