## BUG-1699 · 互联对端合集在客户端库页不成组显示
- **报告**：2026-08-17（用户：互联合集不显示）
- **真实性**：✅ 真 bug。序列化链（host DB → `RemoteBookInfo`/`RemoteVideoInfo.collection` → `/api/library/*` → 客户端 fromJson）本身是通的；断在三层叠加：
  1. **视频页折叠映射不重载（主因）**：合集同步把 host 合集落进本地 `MediaCollections`/`MediaCollectionItems` 后，`app_model.dart` 的 `refreshAfterSyncRun` 只 `ReaderMediaType.instance.refreshTab()` 刷书架；视频页 `home_video_page.dart` 的 `_collectionsById`/`_primaryCollectionByEntry`/`_memberSortIndex` 只在 initState/_refresh/_pullToRefresh 加载（`_loadLibraryMaps`），后台落库的合集不改视频 uid 集合 → 映射停在首帧快照 → `_resolveLocalCollectionId` 恒 null → host 合集恒散卡，直到下拉刷新或重启。防抖轻量合集路径（`sync_auto_trigger.dart` `_runCollectionsSync`）更是连书架的 refreshTab 都不发。
  2. **合集同步可能整轮不发生**：`sync_orchestrator.dart` 流水线里合集段排在 `SyncManager.syncAllBooks` 之后，而书阶段是全流水线唯一没有自带 try/catch 的阶段——书阶段一抛（非鉴权类阶段级异常），合集/墓碑段整轮到不了；纯客户端设备的合集 watcher 只监听本机合集表写入，从不触发轻量路径。
  3. **书架兜底顺序**：`reader_fushi_history_page.dart` host 归属 `(name,type)` 解析不到本地合集时 `continue` 直接散卡，跳过了「按本地已同步透传成员行救回」的云盘兜底分支（用户改过本地合集名 / 合集清单晚到时误伤）。
- **[x] ① 已修复** —
  - 数据层单一事件源：`FushiDatabase.watchCollectionTablesChanged()`（`packages/fushi_core/lib/src/database/database_library.part.dart`，手动 StreamController + tableUpdates，规避 BUG-834 keyed watch 挂测试），视频页与书架页订阅它（300ms 合并窗口）重载折叠映射——任何写入者（互联/云合集同步、备份导入、合集编辑）落库即自动重组，消除「谁写库谁记得通知页面」的逐路登记模式。
  - `sync_orchestrator.dart` 书阶段加护栏：非鉴权异常记 `report.errors('books: …')` 后流水线继续；`SyncAuthError` 照旧放行（manual_sync_ui 靠它登出重登，TODO-836/BUG-1323 承重契约）。
  - 书架 host 归属解析失败改为落入已同步归属兜底（不再 continue 跳过）。
- **[x] ② 已加自动化测试** —
  - `fushi/test/database/media_collections_dao_test.dart`：watchCollectionTablesChanged 两表写入均 emit。
  - `fushi/test/pages/home_video_remote_collection_membership_test.dart` / `reader_remote_collection_membership_test.dart`：合集同步落库后页面自动重组（无需下拉/重启）；书架 host 名解析不到时透传成员行救回。
  - `fushi/test/sync/sync_orchestrator_collections_test.dart`：书阶段抛非鉴权异常 → run() 不抛、errors 记账、合集照常拉回。
  - `fushi/test/sync/fushi_sync_server_video_test.dart` / `fushi_sync_server_books_test.dart`：端点层字段裁剪不得丢 `collection`（此前零断言）。
- **备注**：`RemoteAudiobookInfo`/`RemoteLocalAudioInfo` 无 collection 字段（有声书靠 books 域 `srt|uid` 三键回退，BUG-812），非本 bug 范围。
