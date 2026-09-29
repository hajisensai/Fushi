## BUG-2771 · 每次打开 app 视频资料重新加载且刮削期间严重卡顿
- **报告**：2026-09-29（用户：每次打开 app 资料都在重新加载、期间卡顿，要等它加载完才能用；刮削 / 加载资料的过程本身也很卡）
- **真实性**：✅ 真 bug（沿代码路径静态定位，未在真机计时）。四个叠加的根因：
  1. **外壳整页重建**：`VideoSourceScrapeTaskController._publish`（`packages/fushi_engine/lib/media/video/metadata/video_source_scrape_task.dart`）每条进度都 `notifyListeners`，ED2K 每读 1 MiB 一条；`HomePage._onVideoSourceScrapeTaskChanged`（`fushi/lib/src/pages/implementations/home_page.dart`）无条件 `setState`，保活 tab 在 Offstage 里照样 build——视频库每次重做整库分组排序，一个 1.5 GB 文件约一千多次全树重建。
  2. **每次启动重刮**：`VideoLibraryScrapeSweep._attemptedWorkKeys` / `_refreshedAt` / `_lastRefreshProbeAt`（`video_library_scrape_sweep.dart`）只在内存里，查无 / 歧义的作品每次启动都重新联网刮一轮（排 AniDB 限流），哈希查询失败的文件（`anidb_hash_identity_service.dart` 失败不落 `anidb_file_identities`）经 `_hashBacklog` 每次启动整份重读算 ED2K，过期刷新失败的作品每次再刷 20 部。
  3. **启动索引无效写 + 无条件刷新**：`VideoSourceMetadataIndexer._indexUnlocked`（`fushi/lib/src/media/video/metadata/video_source_metadata_indexer.dart`）对带 NFO 的已有作品每次解析每集 NFO 并整部 `store.apply` 重写、特典每次删一次插一次；`HomePage._backfillVideoMetadataWorks` 只要跑过就 `changed = true` 整页刷新视频库。
  4. **批次期间库页反复全量重载**：`HomeVideoPage._onScrapePresentationChanged` 只有 300 ms 尾沿防抖，AniDB 3 秒一条的节奏下每部作品触发多次 `_refresh()`（书架全表 + 十几张映射表 + 封面回填）再加一次 `_refreshPendingScrape()`（全来源重新规划 + 逐作品查身份）。
- **[x] ① 已修复** — 分支 `pr/video-metadata-startup-perf`：
  - controller 只节流「仅文案变化」的进度通知（250 ms + 尾沿），阶段 / 作品 / 计数 / 确认立即通知；HomePage 只在 `isBusy` / 有无待确认两态翻转时 `setState`。
  - 新增 `VideoScrapeSweepLedger`（`<support>/video_scrape_sweep_ledger.json`，设备本地）：「自动试过」7 天内不重试（配置指纹变了作废）、刷新时刻与 TMDB 探针时刻跨进程；批次在跑时 sweep 直接回上一份待确认清单。
  - indexer 对已有作品先只 stat NFO：没比作品行新就跳过解析与重写；特典绑定没变不写；`index()` 返回是否真写库，HomePage 据此决定刷不刷。
  - 视频库批次中改 2 秒定距节流、不做封面回填 / 待确认重算，批次忙 → 闲时补一次完整刷新。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/metadata/video_source_scrape_task_test.dart`（哈希字节进度节流 + 尾沿 + 阶段立即通知）、`video_library_scrape_sweep_test.dart`（账本跨实例：不重刮 / 配置变了重试 / 过期重试 / 刷新与探针跨进程 / 损坏账本；批次中回缓存清单）、`video_source_metadata_indexer_test.dart`（二次索引零写入并返回 false；NFO 未改不重写、改了重新吃进）。
- **备注**：AniDB anime XML 仍在 UI isolate 解析（每部作品一次、被 3 秒限流隔开，非主因），未改；哈希失败本身仍不落 `anidb_file_identities`，只是不再每次启动重排——下次（7 天后或配置变更）自动重试时仍会重算一次 ED2K。未在真机上计时验证。
