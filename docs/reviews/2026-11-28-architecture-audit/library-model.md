# 架构审计：library-model

2026-11-28 只读审计 + 独立反驳核验的原始结论。总方案见 [../../specs/2026-11-28-architecture-redesign.md](../../specs/2026-11-28-architecture-redesign.md)。

## 现状

媒体库的扫描根统一登记在 fushi_core 的 media_sources 表，种类值域是 SourceLibraryKind（book/video/manga/music/game）。但这个枚举只装了落库串，各种类的行为靠调用方各自写 switch 或字符串比较来分派。app 侧的扫描器 fushi/lib/src/media/source_library/source_library_scanner.dart 有 4460 行，归类、垃圾过滤、去重、搬家识别、光盘、清单、纯音频交接、网络传输都写在这里，没有放进 fushi_engine。服务端 packages/fushi_server/lib/src/library_scanner.dart 自己另写了一套简化版：视频只按扩展名、书只收 .epub，有声书用了枚举里没有的 'audiobook' 串。两边共用的只有后来逐个下沉到引擎的零件（VideoFolderGroupCoordinator、BookSourceIndex、pruneMissing*、planMangaFolders）。各种类的「来源成员关系」存法也不一样：视频靠 video_books.sourceId 加路径，书、漫画、游戏、有声书靠 preferences 里的 JSON 索引加逐条日志，音乐在 music_tracks 的 deleted_at 里。缺失剪除也因宿主而异：服务端剪 video/book/manga/audiobook，app 对 video/book/manga 一律不剪（BUG-4055 待拍板），音乐软删，游戏自己对账。新建视频行的入口有十来个（扫描、导入对话框、外部打开、下载管线、首页、IPTV…），uid、去重、sidecar、封面各写一遍。封面回填这类入库后的增强挂在 HomeVideoPage 上，所以服务端只能在扫描循环里逐个串行抽帧。docs/bugs 里 BUG-2809/2812/2816/3574 都是「服务端扫描器落后于 app」，BUG-2979/4820/5530 都是视频搬家身份问题，BUG-4833 是 prefs 索引不具备事务性。这些都是同一组结构缺陷换个地方冒出来。

## dual-scanner-fork

**app 与 fushi_server 各写一套来源扫描器，归类判据只在 app 里有，服务端每次都要按 BUG 单补**

- 类型：app / 服务端各写一套；规模 XL；价值 high；用户可见
- 核验：成立

证据：

- fushi/lib/src/media/source_library/source_library_scanner.dart:864 isSourceScanJunkPath、:916 planScanFromFileList、:1128 classifySourceListingInBackground、:142 kScanBookExtensions={'epub','pdf'}：这些纯函数判据都写在 app 包里，引擎和服务端拿不到
- packages/fushi_server/lib/src/library_scanner.dart:316-323 视频根直接 dir.list(recursive) 后只按 _isVideo(:1352 扩展名) 过滤，不经过垃圾目录 / AppleDouble / 下载暂存目录过滤（app 在 :847 isSourceIncomingPath、:893 excludeSourceJunkEntries 里做了）
- packages/fushi_engine/lib/media/source_library/book_library_prune.dart:574 listEpubSourceFiles：服务端书根只收 .epub，同样不过滤垃圾条目；app 书源还收 pdf
- packages/fushi_server/lib/src/library_scanner.dart:196-252 scanAll 用字符串 switch 自成一路，没有 playlists / 蓝光 / DVD / 内容指纹搬家识别 / 纯音频交接（这些在 app 的 :2000-2134 视频分支里）
- docs/bugs/BUG-2812-headless-scan-never-scraped.md、BUG-2816-server-book-manga-prune.md、BUG-3574-manga-source-scan-skips-cbz-zip.md(根因 3：服务端 _scanManga 不收单文件卷)、BUG-2809：同一机制（服务端扫描器手写、落后于 app）至少出了 4 次，每次的修法都是「把某个零件下沉到引擎」

机制：扫描管线的主体（列目录 → 过滤 → 归类 → 去重 / 搬家 → 入库 → 归组 → 收尾）写在 Flutter app 包里。服务端依赖不了 app，只能自己重写一个简化版。之后 app 每加一条判据（垃圾目录、搬家、光盘、压缩包卷），服务端都静默落后，直到有人报 BUG 再单独下沉一个零件。没有任何结构强制两边走同一条流水线。

根本方案：在 fushi_engine 新建 media/library_scan/ 模块，放 LibraryScanEngine：输入是一个 SourceLibraryRow 加一个引擎层的 SourceFileSystem 接口（Local 实现放在引擎；SAF / iOS 书签 / SFTP / WebDAV / AList 这些带平台依赖的实现由 app 注入），输出 SourceScanSummary。planScanFromFileList / isSourceScanJunkPath / excludeSourceJunkEntries / ScanPlan 及各 Scan*Item 原样从 app 搬进引擎，各种类的导入阶段按 SourceKindSpec（见 kind-registry 条）拆成 per-kind 的 KindScanner。整个 server library_scanner.dart 的 _scanVideos/_scanBooks/_scanManga/_scanAudiobooks/_prune*Root 删除，只留 config 根到 media_sources 行的同步和 CLI 汇总输出。app 的 source_library_scanner.dart 缩到只剩注入（锁、进度 sourceScanActivity、音乐 / 游戏 / 转录端口）。以后新增判据只改引擎一处，两端自动一致。守卫：fushi_engine_purity_guard 加一条「packages/fushi_server/lib 下禁止出现 dir.list(recursive) 扫描媒体根」；再加一条跨宿主等价测试：同一份 fixture 目录分别走 app 装配和 server 装配，比对入库结果。

要动：packages/fushi_engine/lib/media/library_scan/ (新)；fushi/lib/src/media/source_library/source_library_scanner.dart；fushi/lib/src/media/source_library/source_file_system.dart；packages/fushi_server/lib/src/library_scanner.dart；packages/fushi_server/lib/src/admin/admin_api.dart

核验说明：已核实：source_library_scanner.dart 4460 行，:864 isSourceScanJunkPath、:888 excludeSourceJunkEntries、:916 planScanFromFileList、:1128 classifySourceListingInBackground、:142 kScanBookExtensions={'epub','pdf'} 都在 app 包里。fushi_server/lib/src/library_scanner.dart:316-323 用 dir.list(recursive) 后只按 _isVideo 过滤，没有垃圾和暂存目录过滤；:196-252 scanAll 按字符串 switch 分派。book_library_prune.dart:574 listEpubSourceFiles 只收 .epub，也没有 junk 过滤。服务端与 app 的共用部分确实只有逐个下沉到引擎的零件。

方案风险：「原样从 app 搬进引擎」走不通。source_library_scanner.dart:39 import 了 flutter/foundation，:76 用了 i18n 的 t，:74 引用 UI 的 portrait_cover_image，:112 用了 pdf_importer（pdfrx 插件），还依赖 sidecar_finder、drop_classification、music_audio_intake 等 app 文件。fushi_engine 禁止 flutter / 插件 / package:fushi，所以 PDF 导入、封面 UI、本地化文案、OCR 都必须改成端口注入，不能直接搬。另有两处问题。第一，守卫「server lib 禁止 dir.list(recursive)」太粗，服务端有正当的递归列目录（转写、清理等），会误伤；应当改成断言 server 的扫描入口只调 LibraryScanEngine。第二，跨宿主等价测试放在 app 测试里需要依赖 fushi_server，放在 server 测试里拿不到 app 注入，只能在 fushi_engine 层用同一 fixture 和两套注入配置来比对。

修正后的方案（以此为准）：保留 LibraryScanEngine 进 fushi_engine 的方向，但前提是先拆依赖：纯判据（junk / incoming / planScanFromFileList / ScanPlan）先下沉；PDF 导入、封面 UI、文案、OCR、音乐 / 游戏全部定义成引擎侧端口，app 用 pdfrx 等实现注入，server 注入无 PDF 或另行实现。守卫改成「packages/fushi_server/lib 里扫描媒体根只能经 LibraryScanEngine」，按符号检查，不按 API 形态拦。等价测试放在 fushi_engine，同一 fixture 分别用 app 风格和 server 风格的端口跑一遍。

## kind-registry

**SourceLibraryKind 只是一个值枚举，各种类的行为散在 switch、throw 和字符串比较里；有声书因此被挤成服务端私有串**

- 类型：缺单一登记源；规模 L；价值 high；不改外部行为
- 核验：成立

证据：

- packages/fushi_server/lib/src/library_scanner.dart:77-80 kAudiobookSourceMediaKind='audiobook'，注释原话：「加一个值要改 app 里所有穷举 switch」，所以绕开枚举落了裸串
- fushi/lib/src/media/source_library/source_library_scanner.dart:1839-1844 先用 dbValue 比较把 music/game 提前分流，到 :2163-2168 的穷举 switch 里再 throw StateError('routed to _scanMusicSource')
- packages/fushi_engine/lib/media/source_library/book_library_prune.dart:608-620 和 packages/fushi_server/lib/src/admin/admin_api.dart:850 的 switch 都对不处理的种类 throw ArgumentError / FormatException
- fushi/lib/src/pages/implementations/media_sources_view.dart:272,282,376,675,867,1078,1101,1220,1779,1989,2001,2339,2344 有 13 处 widget.mediaKind == 'video' / 'music' / 'book' 裸串判断，用来决定 UI 能力
- packages/fushi_server/lib/src/config/server_config.dart:20-34 kServerLibraryRootKinds 是另一张手写清单，fushi/lib/src/media/source_library/source_auto_scan.dart:68-75 的 sourceLibraryKindModule 又是一张种类到模块的 switch

机制：种类的能力（允许哪些传输、谁来剪除、是否归组、属于哪个模块、哪个宿主支持、UI 显示哪些控件）没有放在种类身上，每个消费点都靠 switch 或字符串比较现推。于是加一个种类要改 N 处；改不起就落裸串（audiobook）或写 throw 分支兜着。

根本方案：在 fushi_core（或 engine）新建 SourceKindSpec 注册表：枚举 SourceLibraryKind 每个值（补上 audiobook，dbValue 'audiobook' 与已落库串一致，不迁数据）带一份 const 描述，字段包括 module、allowedTransports、pruneStrategy、groupsSeries、groupingModes、remoteDomain、宿主能力位（hostSupport: app/server）、UI 能力位（supportsScrape、supportsAutoMusicIntake…）。media_sources_view 的 13 处裸串、source_auto_scan 的 module switch、server 的 kServerLibraryRootKinds（改成按 hostSupport 过滤）、book_library_prune / admin_api 里的 throw 分支，全部改为查 spec。扫描分派改成 spec.scanner 多态，不再写「提前分流 + switch 里 throw」。以后新增种类只加一个枚举值和一份 spec。守卫：lint 测试禁止 lib 下出现 mediaKind == '<字面串>'，并断言每个枚举值都有 spec。

要动：packages/fushi_core/lib/src/database/source_library_kind.dart；fushi/lib/src/pages/implementations/media_sources_view.dart；fushi/lib/src/media/source_library/source_auto_scan.dart；packages/fushi_server/lib/src/config/server_config.dart；packages/fushi_engine/lib/media/source_library/book_library_prune.dart；packages/fushi_server/lib/src/admin/admin_api.dart

核验说明：已核实：server library_scanner.dart:77-80 的注释原话就是「加一个值要改 app 里所有穷举 switch」。source_library_scanner.dart:1840 先把 music 分流出去，:2164-2168 又 throw StateError。book_library_prune.dart:608-620 有三个 throw ArgumentError。media_sources_view.dart 里 grep 到 `mediaKind == '` 共 13 处。server_config.dart:23-28 kServerLibraryRootKinds 是一张手写清单，并且有意不含 music（所有者 2026-10-28 决定延后）。

方案风险：一、枚举加 audiobook 之后 tryParse 不再返回 null，app 的新增来源选择器、自动扫描、穷举 switch 都会看到这个值，必须靠 hostSupport 把 app 侧挡住，否则等于偷偷给 app 加了「有声书根」这个用户可见能力，这件事应该和 audiobook-ingest 一起上拍板台。二、把 UI 能力位（supportsScrape 等）放进 fushi_core 是分层倒置，UI 能力应留在 app 侧的扩展或二级表，core 只放 module、transports、prune、hostSupport 这类领域属性。三、music 在服务端是刻意延后，hostSupport 要能表达这一点，不能因为有了注册表就顺手打开。四、source_library_kind_test 冻结的 dbValue 不能改，新增 'audiobook' 与已落库串逐字一致即可。

修正后的方案（以此为准）：SourceKindSpec 放在 fushi_core 或 engine，只含领域属性：module、allowedTransports、missingPolicy（按宿主取值）、groupsSeries、hostSupport{app,server}。UI 能力表放在 app 侧，按 SourceLibraryKind 做穷举 map，并加测试断言每个值都有条目。audiobook 进枚举之前，先等 audiobook-ingest 的拍板结论。

## source-membership-table

**来源与条目的成员关系按种类各存一套（video_books 列 / preferences JSON 加日志 / music_tracks），缺失剪除策略也因宿主而异**

- 类型：镜像状态；规模 L；价值 high；改持久化 / wire、用户可见
- 核验：部分成立

证据：

- packages/fushi_engine/lib/media/source_library/book_library_prune.dart:7-12 原话「补一张来源扫描索引…落 preferences 表的 media_source_scan_index_<sourceId> 键…不升 schema」；:44 又加了逐条日志键 ~ 前缀
- docs/bugs/BUG-4833-manga-source-index-lost-when-scan-killed.md：扫描中途被杀，索引丢失。修法是 fushi/lib/src/media/source_library/source_library_scanner.dart:517-520 每卷 checkpoint 写一次 prefs，在没有事务的存储上补了一层日志
- fushi/lib/src/media/source_library/game_source_scanner.dart:11-12,157-204 游戏来源也借用 BookSourceIndex 这个 prefs 键族，uid 字段里装的是 galgames.id
- fushi/lib/src/media/music/music_library_scanner.dart:464 音乐另走 softDeleteMissingMusicTracks；视频靠 video_books.sourceId 加路径（source_library_scanner.dart:3507-3525 整表载入后现建 Map）
- packages/fushi_engine/lib/media/video/video_library_prune.dart:11-13 原话「目前只有服务端…调用；app 本地视频来源重扫有意保留『暂缺』文件的行…见 BUG-4055 待拍板」：同一库在 server 上会被剪，在 app 上永远残留

机制：成员关系（哪个源的哪个相对路径对应哪个条目、最后一次见到时的指纹、是否被判非本类）本来是结构化、需要事务的数据，却按「不升 schema」原则塞进了 preferences JSON。每种媒体自己发明存法，原子性丢失靠日志来补，剪除逻辑也只能各写一版（pruneMissingVideoRows / pruneMissingBookRows / pruneAudiobookSource / 音乐软删 / 游戏对账），结果谁调用就是谁的策略。

根本方案：在 fushi_core 新建 source_entries 表：主键 (source_id, rel_path)，列包括 entry_role（primary/negative）、media_type、media_uid、size、mtime_ms、content_fp、state（present/missing）、first_missing_at、last_seen_scan_id，外键 source_id 级联删除。扫描引擎在一个事务里批量 upsert 本轮所见，再一句 UPDATE 把未见的标成 missing。缺失之后怎么处理由 SourceKindSpec.missingPolicy 决定，app 和 server 用同一份（BUG-4055 的拍板结果写进这一个地方，不再按宿主分叉）。迁移：一次性把 media_source_scan_index_* 和日志键读进新表，之后不再写这些键（键名冻结，只做读迁移）。被取代并删除的有：BookSourceIndex 的 prefs 存取与 journal / checkpoint、游戏来源对 BookSourceIndex 的借用、video_library_prune 与 book_library_prune 的枚举加对账两套实现（统一成按 source_entries 的 missing 查询）；音乐可以保留 Rust 侧的曲目表，但成员关系同样写 source_entries。守卫：schema 测试断言 preferences 里不再出现 media_source_scan_index_ 写入点。

要动：packages/fushi_core/lib/src/database/tables.dart；packages/fushi_core/lib/src/database/database.dart (migration)；packages/fushi_engine/lib/media/source_library/book_library_prune.dart；packages/fushi_engine/lib/media/video/video_library_prune.dart；fushi/lib/src/media/source_library/game_source_scanner.dart；fushi/lib/src/media/source_library/source_library_scanner.dart；packages/fushi_server/lib/src/library_scanner.dart

核验说明：证据属实：book_library_prune.dart:7-12 写了「不升 schema、落 preferences」，:44 有日志键；game_source_scanner 借用了 BookSourceIndex；音乐走软删。但「app 对 video 一律不剪（BUG-4055 待拍板）」的说法过时了：docs/bugs/BUG-4055 第 28 行起记着 2026-11-04 已拍板选 B，即保留行、刮削跳过，修在 video_library_scrape_sweep._plannedWorks。保留行是 #792 有意定下的语义（护移动盘 / 离线网络盘），有锁定测试 source_library_scanner_test.dart:803-819。服务端剪除也是有意的，有 pruneMissing 开关（library_scanner.dart:159,180），来自 BUG-2809 / BUG-2816。所以「按宿主分叉」是两个有意决定，不是补丁。真正的补丁是 video_library_prune.dart:11-13 那段过时注释。

方案风险：一、方案要求 missingPolicy「app 和 server 用同一份、不再按宿主分叉」，这会推翻 BUG-4055 B 和 #792 的语义（会丢观看进度），或者推翻服务端剪除，属于用户可见行为变化，需要上拍板台。二、新表 source_entries 以本机 source_id 为键，是设备本地状态。现在的 prefs 键在 profile_keys.dart:223-226 里被显式排除出 Profile 快照，新表同样要排除出 Profile 快照、跨设备同步和备份恢复（或者在恢复时重新绑定），否则恢复后会把已导入的卷重判。三、游戏的 uid 是 int 型 galgames.id，音乐在 fushi_music 里，media_uid 需要统一成字符串身份并带 media_type。四、prefs 键名冻结，只读迁移可以，迁移完后不写。

修正后的方案（以此为准）：source_entries 表方案保留，但 missingPolicy 写成 SourceKindSpec 里按宿主取值：app 侧视频沿用 BUG-4055 B 的「保留行，标记 missing」，server 侧沿用 pruneMissing 开关。state=missing 直接替代 sweep 的 _hasPresentMember 现场判定。若想统一两端策略，单独上拍板台。新表加入 Profile 快照、同步、备份的排除清单，并配守卫测试。

## video-intake-single-entry

**新建视频行的入口有十来个，uid、去重、搬家识别、sidecar、封面各写一遍，搬家身份 BUG 反复出现**

- 类型：成类 bug；规模 L；价值 high；不改外部行为
- 核验：部分成立

证据：

- packages/fushi_server/lib/src/library_scanner.dart:347-384 自己拼 uniqueVideoBookUid(singleVideoBookUid) + findSidecarSubtitle + saveVideoBook + 内联 extractVideoCover，没有搬家识别
- fushi/lib/src/media/source_library/source_library_scanner.dart:3576-3583,3666-3710 app 扫描器里有 videoRowMoveEvidence 和内容指纹搬家判定，然后再 saveVideoBook
- fushi/lib/src/media/video/video_import_dialog.dart:180-232 又一份 uniqueVideoBookUid + extractVideoCover + saveVideoBook；fushi/lib/src/media/video/external_video_ingest.dart:59-92 再一份；fushi/lib/src/pages/implementations/home_video_page.dart:4695,4810 UI 页面里直接 saveVideoBook；packages/fushi_engine/lib/media/video/download/video_download_pipeline_service.dart:5117 下载管线又一份
- docs/bugs/BUG-2979-video-moved-file-duplicate-row.md、BUG-4820-video-move-detection-rebinds-unrelated-file.md、以及代码注释里的 BUG-5530（source_library_scanner.dart 搬家 rebind）：同一个「视频身份 / 搬家」机制修了 3 次，每次都只修在 app 扫描器这一个入口上

机制：「一个媒体文件进库」没有唯一的入库原语，各入口自己调 repository.saveVideoBook，身份判定（路径归一、同名后缀、搬家正证据、指纹）和副作用（封面、规格、归组）由调用方自己拼。修一个入口，其余入口照样带着旧的身份缺陷。

根本方案：在 fushi_engine 新建 media/video/video_library_intake.dart，放 VideoLibraryIntake.admit(List<VideoAdmission>)。它接管身份解析（normalizeVideoPath → 已有行 → videoRowMoveEvidence / 指纹 → uniqueVideoBookUid）、sidecar 选择、事务落库，以及把封面 / 规格入列 enrichment 队列（见下一条），返回 created/reused/moved。扫描引擎、导入对话框、external_video_ingest、下载管线、home_video_page、IPTV / 媒体服务器 / 在线源全部改调它。repository.saveVideoBook 降为 intake 的私有实现，其他地方禁止直接调。守卫：测试按符号扫描，断言 lib 下 saveVideoBook( 只出现在 video_library_intake.dart 和 repository 里。以后身份规则只改 intake 一处。

要动：packages/fushi_engine/lib/media/video/video_library_intake.dart (新)；packages/fushi_engine/lib/media/video/video_book_repository.dart；fushi/lib/src/media/source_library/source_library_scanner.dart；fushi/lib/src/media/video/video_import_dialog.dart；fushi/lib/src/media/video/external_video_ingest.dart；fushi/lib/src/pages/implementations/home_video_page.dart；packages/fushi_engine/lib/media/video/download/video_download_pipeline_service.dart；packages/fushi_server/lib/src/library_scanner.dart

核验说明：机制成立：grep 到 saveVideoBook( 的生产调用分布在 15 个文件。审计漏列了 remote_disc_download.dart、iptv_playlist_import.dart、media_server_library.dart、anime_source_library.dart（2 处）、web_video_sites.dart，以及引擎里的 bluray_library_title.dart、dvd_library_title.dart、disc_library_import.dart。server library_scanner.dart:347-384 自己拼 uid、sidecar、save 和内联抽帧，这一点属实。

方案风险：一个 admit() 统一包办搬家识别和指纹并不合适。IPTV、媒体服务器、在线源（anime-source://）、网页视频的行是 isNetworkOnlyVideoPath 一类，没有本地文件身份，不能也不该走 normalizeVideoPath、指纹和搬家判定；光盘标题（bluray/dvd）的身份是盘根加标题号。强行塞进同一个原语，要么结果错，要么又在 intake 里长出特例分支。

修正后的方案（以此为准）：VideoLibraryIntake 按身份类别分成几个准入：admitLocalFiles（路径归一 → 已有行 → 搬家正证据 / 指纹 → uid → sidecar）、admitDiscTitles、admitRemoteReferences（只做 uid 去重和来源键）。三者共用同一个事务落库和 enrichment 入列。守卫照原方案：生产代码里的 saveVideoBook 只允许出现在 intake 和 repository，并把上面漏掉的 8 个调用点列进迁移清单。

## enrichment-owned-by-ui-and-no-incremental

**入库后增强（封面回填）挂在 HomeVideoPage 上，服务端只能在扫描里串行抽帧；每次扫描都全表载入，没有基于 mtime 的增量**

- 类型：性能；规模 L；价值 medium；改持久化 / wire
- 核验：部分成立

证据：

- fushi/lib/src/media/source_library/source_library_scanner.dart:3476-3488 注释（BUG-2569）：封面改由 HomeVideoPage._maybeBackfillCovers 按 watchVideoBookUids 回填，此前内联抽帧时 50 个文件理论上限是 50 分钟
- packages/fushi_server/lib/src/library_scanner.dart:378-384 服务端扫描循环里仍然逐文件串行 await extractVideoCover，正是 BUG-2569 在 app 上消掉的那个形态（服务端没有 HomeVideoPage 可挂）
- fushi/lib/src/media/source_library/source_library_scanner.dart:3507 和 :3763 每扫一个视频来源都 _videoRepo.listAll() 整表载入两次，:3532 再整表载入 allVideoContentFingerprints；:406 / :1228 书源每次 loadBookSourceRows 全表
- source_library_scanner.dart:1902-1931 每次都完整 listFiles 加全量归类，后面靠内存 Set 判断已入库；只有漫画负向表和服务端有声书签名用到了 size+mtime，视频、书、正向条目都没有增量（推测：大库开 auto_scan 时，每次回前台过了节流都要全表读一遍）

机制：增强阶段没有引擎层的作业队列，app 只好借 UI 页面的流监听来跑，服务端没有这个钩子就退回内联。扫描没有逐条目的指纹记录（见 source-membership-table），无法判断「这条没变」，只能每次把所有行读进内存重新比对。

根本方案：在 fushi_engine 新建 LibraryEnrichmentQueue，配一张持久作业表（media_uid、job_kind cover/specs/fingerprint/cue、attempts、last_error，替代会话级的 CoverBackfillLedger）。由宿主各起一个后台 worker 消费（app 放在 AppModel 装配，不放页面；server 放在 runtime）。VideoLibraryIntake 只负责入列。删除 HomeVideoPage._maybeBackfillCovers 和 server 的内联 extractVideoCover。扫描引擎借 source_entries 的 (size, mtime) 做增量：列目录后与本源条目比对，未变化的条目不碰任何媒体表；查询都按 source_id 限定，不再整表 listAll。守卫：引擎测试断言扫描阶段不调用 extractVideoCover，并对「未变化的重扫产生 0 次媒体表写入」做断言。

要动：packages/fushi_engine/lib/media/library_enrichment/ (新)；fushi/lib/src/pages/implementations/home_video_page.dart；packages/fushi_server/lib/src/library_scanner.dart；fushi/lib/src/media/source_library/source_library_scanner.dart；packages/fushi_core/lib/src/database/tables.dart

核验说明：已核实：source_library_scanner.dart:3507 和 :3763 有两次 _videoRepo.listAll()，:3535 有 allVideoContentFingerprints；server library_scanner.dart:378-384 在扫描循环里逐个 await extractVideoCover（受 extractCovers 开关控制）；CoverBackfillLedger 在 app 的 cover_backfill_ledger.dart，被 home_video_page 使用。「每次回前台都会全表读」属于推测，审计自己也标了推测，我没有复现。

方案风险：一、只用 (size, mtime) 判「未变化」不够。sidecar 字幕后加、同目录 cue 或封面变化都不会改视频本身的 mtime，所以比对必须覆盖整个归组单元，包括 sidecar。二、SMB / WebDAV / SAF / AList 的 mtime 精度和可靠性不一，有的会返回 0 或者全部相同。增量时要按传输方式回退，或者再加一个内容指纹。否则就是用「看着没变」去掩盖漏导入，违反根因原则。三、持久作业表会改 schema，同样是设备本地状态，要排除出同步和 Profile。

修正后的方案（以此为准）：增量单位是归组单元（视频及其 sidecar / 同目录附属），签名取成员的 (rel_path, size, mtime) 集合。传输方式声明 mtime 不可靠时退回全量比对（在 SourceKindSpec / transport 能力位里声明，不写特例）。作业队列方案保留。

## audiobook-ingest-two-models

**有声书入库有两种模型：app 在书源里挂 sidecar 加 R2–R5 配对，服务端单设 audiobook 根加目录签名**

- 类型：app / 服务端各写一套；规模 M；价值 medium；用户可见
- 核验：成立

证据：

- fushi/lib/src/media/source_library/source_library_scanner.dart:1361 _BookAudiobookPlan 与 :2705 _attachAudiobook：app 没有有声书根，有声书作为书源扫描的附属挂到 EPUB 上
- packages/fushi_server/lib/src/library_scanner.dart:944-1018 _scanAudiobooks（planAudiobookFolders + _AudiobookFolderState 签名 + 引用导入）和 :1250 _pruneAudiobookRoot：服务端是独立的根种类，app 读不懂（SourceLibraryKind.tryParse 返回 null）
- docs/agent/server-parity-gaps.md:232-250：服务端书根只认同名 sidecar，不做 app 的 R2–R5 配对；'audiobook' 这个值只有服务端用

机制：有声书在 app 是「书的附件」，在服务端是「独立的库」，两边各自演化出目录识别、配对和刷新签名。同一个文件夹放在两个宿主上，入库结果不同；跨宿主同步与互联也因此要处理两种形态。

根本方案：有声书在 SourceKindSpec 里只定义一次：要么是正式种类 audiobook，要么是 book 种类的 attachAudio 能力，二选一由用户拍板（这属于行为取舍，要进拍板台）。目录识别（planAudiobookFolders、classifyDiscoveryDirectory）、配对（book_audiobook_pairing R2–R5）和刷新签名统一放进引擎扫描管线的 AudiobookKindScanner。删除服务端 _scanAudiobooks/_refreshAudiobookFolder/_AudiobookFolderState 和 app 的 _BookAudiobookPlan 私有实现，签名记进 source_entries.content_fp。

要动：packages/fushi_server/lib/src/library_scanner.dart；fushi/lib/src/media/source_library/source_library_scanner.dart；packages/fushi_engine/lib/media/audiobook/；packages/fushi_core/lib/src/database/source_library_kind.dart；docs/agent/decision-board.md

核验说明：server-parity-gaps.md:232-250 原文写明：服务端书根只认同名 sidecar，R2-R5 配对在引擎的 book_audiobook_pairing.dart 里，但服务端没调用；'audiobook' 只在服务端使用。server library_scanner.dart:77-80 与 scanAll 里的 audiobook 分支属实。

方案风险：「app 的 _BookAudiobookPlan 私有实现」不准确：R2-R5 配对本身已经在引擎（engine/media/audiobook/book_audiobook_pairing.dart），app 只是装配层。真正分叉的是「谁调配对、以什么根种类调」。方案把二选一交给拍板台是正确的，符合外部输入和行为取舍规则。

## 核验补充（审计漏掉的）

- packages/fushi_engine/lib/media/video/video_library_prune.dart:11-13 的注释仍写「BUG-4055 待拍板」，实际 2026-11-04 已拍板选 B（docs/bugs/BUG-4055-app-video-scan-never-prunes-deleted-files.md:28）。于是「文件在不在」现在由三处各自判：video_library_scrape_sweep._plannedWorks 的 _hasPresentMember、server 的 prune 枚举、app 扫描的搬家正证据（source_library_scanner.dart:4238 注释）。这是 source_entries.state 本该统一掉的现场判定，审计没有点出
- fushi/lib/src/media/source_library/source_library_scanner.dart:74,76 扫描器 import 了 UI 组件 portrait_cover_image 和 i18n 的 t：扫描管线反向依赖 UI 层，比「没放进 engine」更根本，下沉前必须先拆
- server library_scanner.dart:329 每个视频根都 _videos.listAll() 整表载入（与 app 的 :3507 同一形态），整表载入不只是 app 的问题；多根服务端是 O(根数×总行数)
- 审计漏列 8 个 saveVideoBook 调用点：remote_disc_download.dart、iptv_playlist_import.dart、media_server_library.dart、anime_source_library.dart、web_video_sites.dart，以及引擎的 bluray_library_title.dart、dvd_library_title.dart、disc_library_import.dart。这些是网络引用和光盘标题两类身份，说明入库身份模型本身就不止一种
