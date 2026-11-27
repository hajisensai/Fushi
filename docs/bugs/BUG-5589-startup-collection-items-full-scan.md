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
- **[x] 第二轮（首次打开各模块）** — 临时拦截器按切 tab 时间戳归因，r0（首次进模块）剩下的大头是视频折叠归属：
  远端主机的视频也要归属，主归属查询收不窄（84,901 行，单条 427 ms），从前连同整表成员在 UI isolate 上解码。
  - 视频库页 / 首页继续观看 / 伴屏改走 `loadVideoLibraryMembership`（`video_continue_watching.dart`）：每条目一行
    主合集 + 组内序（`getPrimaryCollectionMembershipOfKind`）+ 本机视频自己的成员行（`getLibraryVideoMemberRows`），
    在一次性后台 isolate 里读库、套目录合集策略，结果经 `Isolate.exit` 交回；
  - 作品图 `loadWorkGraphSnapshot` 需要全部成员（收不窄），整体搬到后台 isolate（`loadWorkGraphSnapshotOffUi`）；
  - 侧栏书架速览只取 epub / srt 归属；播放页系列归属只读该视频的成员行（`memberRowsOfVideo`）；改名覆盖
    （`readOverrideTitlesByBookKey`）按前缀查偏好（`getPrefRowsByPrefix`），不整表读 1879 行。
  - 测试：`fushi/test/media/video/video_library_membership_test.dart`（新旧管线逐条对拍：目录 / 作品模式、
    远端视频、多合集、书视频混编，并走一遍真后台 isolate）；`work_graph_store_test.dart` 加后台建图与原地一致。
  - 效果（Windows，同库，冷启动立刻切模块，UI 线程堵塞合计）：r0 2071 ms → 1159 ms（首页 674 → 0、视频 231 → 74），
    r1 32 → 0。
- **平台验证**：
  - Android（小米平板 5 / nabu，同一份真实库拷进测试包内部存储，profile 包，冷启动立刻切模块，UI 线程堵塞合计）：
    第 0 / 1 / 2 轮 9.9 s / 6.5 s / 5.4 s → 4.3 s / 1.3 s / 1.6 s；第 3、4 轮两边都约 0.5～1.1 s（这台设备的底噪）。
    基线是当时的 `develop`（e18ab28），比修复分支的基点新几个提交。
  - macOS：未测成——Mac 访问 GitHub / pub.dev 不通，CocoaPods 拉依赖失败；根因在共享 Dart 路径上，与平台无关。
- **备注**：仍剩的首次开销——书架首次 575 ms、游戏 229 ms、复习 183 ms。书架的构成是连续多帧 `LAYOUT` 25～40 ms
  （首次排版书名等文本，第二轮归零）加并发 GC 标记，不是读库。`media_collections`（3185 行）每个模块首次挂载
  各读 1～3 次，单模块约 20～30 ms；进程级合集缓存要处理事务内读、跨 isolate 写入的失效，易读到旧数据，
  收益与风险不成比例，不做。
