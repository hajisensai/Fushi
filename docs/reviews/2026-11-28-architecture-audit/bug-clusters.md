# 架构审计：历史 bug 簇

从 `docs/bugs/` 归出的「同一机制反复出 bug」的簇。

## 互联/同步

多通道（互联+云盘/WebDAV）共用同一份全局状态或无逐通道隔离：缓存槽、folder 缓存、SRS 同步状态、401 登出、通道循环异常级联。簇内 1202/1576/3565/1578/1552/1604/1573/1569 等

bug：BUG-1202、BUG-1576、BUG-3565、BUG-1578、BUG-1552、BUG-1604、BUG-1573、BUG-1569、BUG-1560、BUG-1566

- BUG-1202: hibiki/lib/src/sync/remote_library_cache.dart:63（read 只按域 key 定位槽，槽里不带来源身份）+ :179（唯一失效订阅挂在 InterconnectSyncBackend.sessionIdentityRevision）
- BUG-1576: fushi/lib/src/sync/sync_repository.dart:86-87 sync_root_folder_id/sync_folder_cache 共用；sync_manager.dart:942-966 _restoreDriveCache/_persistDriveCache；sync_auto_trigger.dart:156-178 enabledSyncChannelBackends 同一把锁
- BUG-1578: interconnect_sync_backend.dart:33-110 候选探测、webdav_ops.dart:117-120 的 401 分支，裸穿 runManualFullSync 冒到 manual_sync_ui.dart:207
- BUG-1552: fushi/lib/src/sync/sync_auto_trigger.dart:365（改前）、:231 _runSyncChannel 自身无 try；sync_orchestrator.dart:468
- BUG-1604: sync_auto_trigger.dart:847（_runCollectionsSync）、:949（_runAutoSync per-book）仍无逐通道隔离
- BUG-1573: fushi_server_controller.dart _start() 旧 :244-308 在 try 之外；app_model.dart:5385-5386 unawaited(stop()); dispose()

## 互联/同步

host 侧写入口（进度/聚合 PUT）与本机整轮自动同步抢同一把全局锁 runExclusiveWithSync，对端 15s 超时但已落库 → 写入落地确认丢失 → 误判冲突；出站落地又无条件覆盖 host PUT；进度/位置纯 LWW 无三方冲突判定

bug：BUG-2717、BUG-3529、BUG-3528、BUG-3537、BUG-2506、BUG-3367、BUG-3743

- BUG-2717: fushi/lib/src/models/app_model.dart:655 把 runExclusive 接到 runExclusiveWithSync = sync_auto_trigger.dart:101/116 _autoSyncMutex；sync_state.part.dart:100 与 :132 包在 _runExclusive；interconnect_sync_backend.dart:199 15s requestTimeout，_sendBounded :210-222
- BUG-3529: packages/fushi_engine/lib/sync/local_library_host_service/books.part.dart:430 putBookProgress 写库包在 _runExclusive（注入 runExclusiveWithSync）
- BUG-3528: fushi/lib/src/sync/interconnect_book_progress_sync.dart:83-87 pushLocal 先 putRemoteBookProgress 再 recordBaseline，PUT 超时基线停在旧位置
- BUG-3537: books.part.dart:425 putBookProgress 只持窄锁 runExclusiveWithSyncStateApply，本机出站写口不拿这把锁
- BUG-2506: fushi/lib/src/sync/sync_orchestrator/books.part.dart _syncBookProgressLive 纯取较新时间戳 resolveBookProgressSync，胜者直接 upsertReaderPosition

## 互联/同步

删除意图（墓碑）在 host/client/通道间不一致：host 删书不写墓碑、client 推送复活已删书、bookKey 单向哈希使墓碑键对不上

bug：BUG-2945、BUG-3443、BUG-3815、BUG-3907、BUG-1566

- BUG-2945: packages/fushi_engine/lib/sync/local_library_host_service/books.part.dart:350 deleteBook 只调 deleteEpubBook(tombstone:true)（备份墓碑）；audiobooks.part.dart:216 deleteAudiobook 什么墓碑都不写
- BUG-3443: fushi/lib/src/pages/implementations/reader_history/remote.part.dart:101-104 bookKey 由对端 bookKey 单向哈希为 interconnect-…；tombstones.part.dart:23 用本机 r.bookKey 求交恒空
- BUG-3815: fushi/lib/src/sync/sync_orchestrator.dart:711 _syncBooksContentLive 先推送，:899 墓碑拉取排最后；library.part.dart:247 PUT 导入 → books.part.dart:283 importBook 不看墓碑；database_content_misc.part.dart:275-278 insertEpubBook 清墓碑

## 互联/配对

凭据/会话/地址是进程级单例或单槽，换配对、换地址、多对端后失效；错误原因逐层静默吞异常被压平成泛化文案

bug：BUG-1550、BUG-3147、BUG-3684、BUG-3675、BUG-2377、BUG-1553、BUG-1741、BUG-1693、BUG-1556、BUG-1562

- BUG-1550: fushi/lib/src/sync/sync_repository.dart:725（改前）所有对端地址共用一个偏好键；interconnect.part.dart:651；fushi_sync_server.dart:901 _issuePeerTokenOrFallback
- BUG-3147: interconnect.part.dart:2129 直接拿单例 InterconnectSyncBackend.instance 打 host 不先 restoreAuth
- BUG-2377: webdav_ops.dart:167/246/404 传输层抛 401，sync_backend.dart:85 凭据语义丢失；sync_error_messages.dart:75-77 只能按类型猜文案
- BUG-1553: fushi_sync_server.dart:942 _pairRateLimited() 返回 429；fushi_pair_v2_client.dart:128 只特判；interconnect.part.dart:656
- BUG-1741: fushi_tofu_probe.dart:46 on Object { return captured; }；fushi_ping_client.dart:76 on Object { return null; }；discovered_pairing_probe.dart:71/:74/:87 continue

## 媒体存储/数据根/搬迁

绝对路径散落在 DB 列/配置/第三方引擎里，数据根迁移、改名、备份恢复、沙箱漂移时靠人工逐处登记重基，漏一处就悬空（path_rebase_coverage 手工清单）

bug：BUG-1174、BUG-705、BUG-183、BUG-1575、BUG-2100、BUG-3540、BUG-3541、BUG-3542、BUG-3520、BUG-1115

- BUG-1174: 数据根迁移漏改 6 处路径：galgames.cover_path（tables.dart:1201，galgame_cover_resolver.dart:300-320）、video_books.subtitle_source/secondary_subtitle_source（tables.dart:487,492）
- BUG-705: hibiki/lib/src/storage/data_root_migrator.dart:803-815 与 backup_service.dart:2628 _rebaseFontPaths 各自重复一份 catalog+shadow 重基
- BUG-2100: fushi/lib/src/storage/data_root_migrator.dart:28 文件头把「移动端沙箱固定、不需要重基」写成设计前提 + app_paths.dart 无容器漂移处理
- BUG-3541: app_model.dart:5624 <documents>/anime_downloads/resume；fushi_torrent_ffi.cpp:1578-1623 ht_load_resume_dir 读 fast-resume 内 save_path
- BUG-3542: fushi/lib/src/storage/path_rebase_coverage.dart:516-518 登记为 externalUserPath，迁移器从不改写
- BUG-3540: video_book_repository.dart:611-673 migrateMediaPaths；video_download_pipeline_service.dart:2994-3003

## 媒体存储/数据根/搬迁

数据根迁移/移动书库的复制-校验-删源流程缺少事务与内容级核实，导致回滚或删源误删用户数据；以及书库位置锚点被别的进程/外部库清理冲掉

bug：BUG-564、BUG-1869、BUG-2071、BUG-2072、BUG-5375、BUG-5450、BUG-5456、BUG-5585、BUG-5492、BUG-5576、BUG-5570、BUG-4701

- BUG-2071: fushi/lib/src/storage/data_root_migrator.dart:653-660 deferredCopy 是 plan 级单个 bool，选择性 plan 混合 rename+copy
- BUG-2072: data_root_migrator.dart:312-316 抛错的 plan 从未进 done，已 rename 项随新根被删
- BUG-5585: data_root_migrator.dart:679-707 _copyTreeVerified 目标已有同名项照写；:711-726 _copyFileVerified 只在复制之后比字节数
- BUG-5456: app_paths.dart:726-741 firstAndroidMigrationTargetOnlyFile 只看相对路径不看内容；data_root.part.dart:397 newDocs.delete(recursive:true)
- BUG-5375: app_paths.dart:261 Android 书库位置锚点存 SharedPreferences，:popup 进程也跑 AppPaths.resolve()；sandbox_relocation.dart:68 台账路径不经磁盘核实就改写全库绝对路径
- BUG-5576: flutter_logs 2.2.8 LogsHelper.kt:114 exportPath 拼出 getExternalFilesDir(null)；RxLogs PLog.kt:545-546 deleteRecursively
- BUG-5570: fushi/lib/src/storage/library_sentinel.dart:237 哨兵 token 一致即判 intact 不看书库内容

## 媒体库扫描入库

来源扫描/导入循环无逐项失败隔离，且扫描器不过滤系统垃圾/不核实已入库内容，一项异常整批失败或静默记成 0

bug：BUG-2569、BUG-2570、BUG-3679、BUG-4831、BUG-5047、BUG-5569、BUG-1262、BUG-5280、BUG-5285

- BUG-2570: fushi/lib/src/media/source_library/source_library_scanner.dart:1060-1180 for (item in plan.videos) 整段只有 try/finally 没有 catch
- BUG-2569: source_library_scanner.dart:1124-1163 逐文件 extractVideoCover，video_cover_extractor.dart:365/:372 两段各 30s ffmpeg
- BUG-3679: source_file_system.dart:131 LocalSourceFileSystem.listFiles 根目录 exists()==false 返回空列表，扫描器记 mediaCount=0、lastScanError=null
- BUG-4831: source_library_scanner.dart:751/:784 只看扩展名归类；source_file_system.dart:194-220 await for 包 dir.list(recursive:true) 一个子目录 error 即整次失败
- BUG-5047: packages/fushi_engine/lib/media/manga/manga_folder_plan.dart:377；fushi_server library_scanner.dart:713；import_commands.dart:178/:345 各自一份分组入口
- BUG-5569: source_library_scanner.dart:2155-2172 _importBookItems 索引命中就走人不看受管内容；:2286-2300

## CLI/ctl/操作目录

ctl 与 app 两侧各自实现同一约定（状态目录/测试根/查词服务/路由前缀/UI-only 流程），无单一来源，漂移后静默打错实例或行为不一致

bug：BUG-4862、BUG-4321、BUG-4627、BUG-5123、BUG-4117、BUG-3744、BUG-4294、BUG-4295

- BUG-4862: packages/fushi_cli/lib/src/ctl_cli.dart:195 resolveCtlStateDir 没传 testRoot；app 侧 fushi/lib/src/platform/desktop/desktop_ctl_host.dart:103-107 传了
- BUG-4321: fushi/lib/src/ops/ctl_dictionary_routes.dart:383 与 :262 用 searchRemoteDictionaryForRequest(createRemoteLookupService())（host 替对端查词的服务）；ctl_video_player_routes.dart:276
- BUG-4627: packages/fushi_server/lib/src/admin/admin_srs.dart AdminSrs.route 新加 GET /api/admin/srs/decks 遮蔽 admin_srs_ctl.dart
- BUG-5123: 操作目录 fushi/lib/src/ops/ 只覆盖已写路由；manga_audio_import_flow.dart:37 pickAndImportMangaAudio 等 UI-only 流程无 ctl 路由
- BUG-4294: srs_review_page.dart 全文不订阅库变化信号；ctl_srs_routes.dart:51-57 bumpSrsRevision；srs_review_page.dart:1790 四处返回点各写各的重读
- BUG-4295: ctl_srs_routes.dart:79-82 与 srs_review_page.dart:449 readSrsStore 吞掉打开失败

## 存储占用显示

存储统计的根目录/类目清单是手工白名单，与真实磁盘占用对不上，缓存根归属判断错误（统计簇较小，约 5 条相邻）

bug：BUG-1905、BUG-2096、BUG-1870、BUG-1893、BUG-1979、BUG-3894、BUG-4377

- BUG-3894: fushi/lib/src/storage/storage_usage_service.dart _defaultCacheRoots macOS 分支把 AppPaths.tempRootDirectory() 当私有缓存扫，实为共享 ~/Library/Caches
- BUG-4377: fushi/lib/src/sync/remote_cover_cache.dart:34 _dir() 把路径解析与 create(recursive:true) 一起 memoize 进 _ensured，存储页清缓存后写入静默失败
- BUG-1905: 标题「存储统计漏算缓存根与白名单外顶层项：app 内 6.9GB vs 系统 13.68GB」（根因行未逐条核对）
