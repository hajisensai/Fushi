## BUG-5589 · 启动后切模块掉帧：合集成员表被反复整表读进 UI isolate
- **报告**：2026-11-27（用户：「fushi 刚启动后，频繁操作比如左右滑动切换模块会掉帧严重。过一会稳定下来才正常」；多端都有）
- **真实性**：✅ 真 bug。用户真实库只读拷贝（`D:\hibiki-dev-data-perf3`）+ Windows profile 构建，
  `integration_test/home_tab_switch_perf_itest.dart`（新增 `FUSHI_PERF_WARMUP_MS` / `FUSHI_PERF_IDLE_PROBE_MS` /
  `FUSHI_PERF_IDLE_TRACE_AT_MS` / `FUSHI_PERF_IDLE_ONLY`）复现：
  - 首页出来后静置：前 10 秒 UI 线程每秒被堵 300～400 ms（单次最长 320 ms），之后安静；
  - 一边切模块：第 0、1 轮（约启动后 70 秒内）UI 线程被堵 5.7 s / 4.2 s，第 2 轮起近零——即「过一会稳定」。
  - timeline：`fushi.db` 的 drift 工作 isolate 1.5 秒内三次 `CopyMutableObjectGraph`（每次 25.5 万对象 / 27.9 MB），
    同 isolate group 1.5 秒 9 次老生代 GC。临时拦截器抓到 `SELECT * FROM media_collection_items`（85,042 行）
    12 秒内 8 次。库里 84,959 条视频成员几乎全是媒体服务器镜像的播放列表（3178 个），本机视频只有 244 部。
  - 根因：几条只按「库内视频 / 私密合集 / 自身种类」回答问题的路径，每次都整表读合集成员：
    - `packages/fushi_engine/lib/privacy/media_privacy.dart:53` `MediaPrivacySnapshot.load`（追踪补发 `_catchUp`
      每种媒体一次，启动 3 次）；
    - `packages/fushi_engine/lib/media/tracking/media_tracking_repository.dart` `listUnlinkedHistory`（启动 3 次）；
    - `packages/fushi_engine/lib/media/video/metadata/video_source_work_planner.dart` `plan` / `VideoLibraryPlanSnapshot.load`
      （启动索引每个来源一次）；
    - `packages/fushi_engine/lib/media/video/video_book_repository.dart` `multiMemberCollectionIds`：自动封面刮削一次一本、
      每本整表读一次（冷启动切模块期间 44 次）；
    - 书架 / 游戏页 `_loadShelfMaps` / `_loadCollectionMaps` 首次挂载的 `getPrimaryCollectionIdByEntry()` + `getAllCollectionItems()`。
- **[x] ① 已修复** — 只读真正用得到的行，答案与整表一致：
  - 私密快照只读私密 / 上锁合集的成员（同 `MediaLockSnapshot.load`），合集级视频私密改存「含私密视频的合集 id」；
  - 新增 `getCollectionItemsOfLibraryVideos` / `getCollectionsOfLibraryVideos`（含库内视频的合集，SQL 子查询收窄）
    给未关联清单与刮削计划；`getCollectionItemsOfVideos(uids)` 给逐本封面刮削；
  - `getPrimaryCollectionIdByEntry(kinds:)` + `getCollectionItemsOfKinds` 给书架（epub / srt）与游戏页（game）。
  - 效果（同库同构建，冷启动立刻切模块）：第 1 轮 UI 堵塞 4.2 s → 0.05 s；静置首 10 秒 3.6 s → 0.5 s（只剩第 0 秒）。
- **[x] ② 已加自动化测试** — `fushi/test/database/library_video_collection_scope_test.dart`（收窄查询的口径 + 私密快照合集级判定
  与整表时一致）；`video_library_scrape_sweep_test.dart` 读库次数计数改认主 FROM；`local_media_cover_perf_guard_test.dart`
  书架改认 `getCollectionItemsOfKinds(shelfKinds)`。
- **备注**：视频库页 `_loadLibraryMapsInner` 与作品关系图 `loadWorkGraphSnapshot` 首次挂载仍整表读一次——视频页要渲染
  播放列表卡片、确实要这些成员，没收；要再降得在 SQL 侧按卡片聚合，另开。Android / Apple 端未单独测速，根因在共享 Dart
  路径上，修法与平台无关。
