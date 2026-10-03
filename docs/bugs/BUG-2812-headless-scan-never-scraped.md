## BUG-2812 · 无头服务端扫描入库的视频从不刮削
- **报告**：2026-09-30（用户：仓库所有者转述「无头服务器还没做完」；对照设计文档第 0 期逐项核对发现）
- **真实性**：✅ 真 bug。设计文档 `docs/specs/2026-09-08-fushi-server-headless-design.md` 第 0 期写明扫描器「视频经
  `VideoBookRepository` upsert + ffmpeg 封面 + 刮削协调器」，落地记录却标「四期全部落地」，实际三处断链：
  1. `packages/fushi_server/lib/src/library_scanner.dart` 的 `_scanVideos` 写行不带 `sourceId`、不把分集归成合集；
     刮削计划器 `VideoSourceWorkPlanner.plan`（`packages/fushi_engine/lib/media/video/metadata/video_source_work_planner.dart:74`）
     只认 `row.sourceId == source.id` + 合集成员关系，所以对服务端扫描进来的库规划出**零个**作品。
  2. 刮削协调器只在 `ServerDownloadHost.start`（`packages/fushi_server/lib/src/download_host.dart`）里建，而且解析不到
     torrent 后端时直接 return、根本不建；扫描之后没有任何人去刮。
  3. `HeadlessHost._buildLibraryService` 没传 `scrapeController`，客户端经互联发起的重刮 / 手动指定身份 / 分集排序
     （`local_library_host_service/video_metadata.part.dart`）在服务端恒返回空或 notPlanned。
  另：服务端没有 app 的内置 TMDB key（`fushi/lib/src/media/video/scraper/tmdb_default_key.dart` 是 app 本地密钥），
  TMDB key 只能从偏好表读，配置文件与 WebUI 都没有入口。
- **[x] ① 已修复** — 见本 PR 提交：
  - app 的 `VideoFolderGroupCoordinator` / `VideoSourceMetadataIndexer`（纯 Dart）下沉到 `fushi_engine`，app 与服务端共用；
  - 服务端视频根登记为本地 `media_sources` 行，入库带 `sourceId`，入库后归组（存量行由 `groupPaths` 回填来源）+ NFO 索引 +
    记来源扫描结果（与 app `SourceLibraryScanner` 视频分支同序）；
  - 新增 `packages/fushi_server/lib/src/video_scrape_host.dart`（`ServerVideoScrape`）：进程共享协调器 + 任务控制器 +
    `VideoLibraryScrapeSweep`（与 app HomePage 同一装配），下载管线、库服务 `scrapeController`、扫描后补刮共用；
  - 配置 `scan_scrape`（默认开）/ `tmdb_api_key`，WebUI 设置页与状态页、`scan --[no-]scrape`。
- **[x] ② 已加自动化测试** — `packages/fushi_server/test/library_scanner_scrape_test.dart`（7 条：来源登记 + sourceId +
  三集归一部作品、重扫不重复登记、旧版无来源存量行回填并归组、补刮带作品名问资料源、`scan_scrape: false` 不发请求、
  TMDB key 取值优先级、配置往返）。变异实测：去掉扫描器的归组 / 索引步骤，前两类与补刮用例共 3 条变红。
- **备注**：
  - 补刮只刮「从未认领过规范身份」的作品并按作品落盘记账，重复扫描不会整库重刮；查无 / 歧义的作品进待确认队列，
    由客户端经互联手动指定。
  - TMDB key 与资料语言改了要重启：协调器按启动快照构造，下载管线持有它，热换会让管线拿着已关闭的协调器。
  - 未做真机验证（真实 AniDB / TMDB 网络刮削）；测试用假资料源验证接线。
