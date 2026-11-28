# 架构审计：storage-display

2026-11-28 只读审计 + 独立反驳核验的原始结论。总方案见 [../../specs/2026-11-28-architecture-redesign.md](../../specs/2026-11-28-architecture-redesign.md)。

## 现状

存储占用由 fushi/lib/src/storage/storage_usage_service.dart 一个 1600 行的扫描器负责。它的类目是手写的 StorageCategoryId 枚举（15 个），配一张手写的 documents 子目录表 kStorageCategoryDocumentsChildren。这张表靠守卫测试和 AppPaths.fushiOwnedDocumentsEntries（迁移白名单）互相对齐。support 根没有白名单：除 ocr_models、asr_jobs、sync-data 外，所有子项都兜底进「数据库与内部数据」，并且只读。缓存根按平台门控，桌面恒为 0。
能不能删、怎么删，分散在好几处：kDeletableEntryCategories、kDirectlyDeletableEntryKinds、kClearAllCacheCategories、isStorageEntryDeletable，以及 storage_usage_actions.dart 和 storage_usage_view.dart 里两个按 StorageEntryKind 写的 switch。Anime4K 和互联「旧版残留」在页面上各有专门的分支。
DB 支撑的明细（书、有声书、词典、视频）由扫描器自己按各所有者的落盘规则反推路径，例如哈希目录和明文目录两种形态并存。每次打开页面、每次 ctl 的 ls 或 rm，都要把全部根整树 stat 一遍：约 15 次串行 Isolate.run，没有缓存也没有增量。启动诊断 storage_footprint_log.dart 另有一个独立的遍历器。
对外入口有三处：设置页、ctl 的 storage.cli.* 条目、/api/admin/storage/usage 路由（CLI `fushi storage usage` 调的就是它）。三处的输入不一致。fushi_server 完全没有占用接口。
BUG-1870/1893/1905/1979/2096/3894/5187/5536 八条历史都出自同一组机制：手写清单漂移、扫描器替所有者猜路径、可删性按类目硬编码，以及扫描量大、重活落在 UI isolate。

## storage-area-registry

**磁盘目录归属靠多份手写清单互相对齐，support 根约 26 个子系统兜底成「数据库·只读」**

- 类型：缺单一登记源；规模 L；价值 high；用户可见
- 核验：成立

证据：

- fushi/lib/src/storage/storage_usage_service.dart:489-550 kStorageCategoryDocumentsChildren 手写 documents 子目录到类目的映射，注释说要靠守卫测试与 AppPaths 白名单「全覆盖对齐」
- fushi/lib/src/storage/app_paths.dart:1490-1540 fushiOwnedDocumentsEntries 是另一份手写的同名清单（迁移用），每新增一个子系统，两份都要改
- fushi/test/storage/storage_usage_service_test.dart:76-91 与 fushi/test/storage/documents_whitelist_guard_test.dart:25-30 两个守卫兜底这个不变量；后者只认 documentsSubdirectory('x') / appDirectory.path,'x' 等 3 种字面量形态，换个写法就漏
- fushi/lib/src/storage/storage_usage_service.dart:1146-1215 _scanDatabase 把 support 根全部直接子项（只排除 ocr_models / asr_jobs / sync-data）铺成 readOnly。实测 support 下的派生点有 tts_cache（tts_services.dart:138）、remote_lookup_audio_cache（fushi_remote_lookup_client.dart:128）、asr_models（gal_loopback_voice_detector.dart:173）、gpt_sovits（gpt_sovits_local_engine.dart:164）、irodori_tts、gpu_runtime（gpu_acceleration.dart:130）、logs、torrent、leaderboard、feedback 等约 26 个。缓存和可重下的模型全被标成「数据库·只读」，删不掉
- 'asr_jobs' 字面量出现在 5 个所有者文件里（apple_speech_transcription_service.dart:65、cloud_whisper_transcription_service.dart:360、video_subtitle_pipeline.dart:239、music_asr_subtitle_sink.dart:47、music_plugin_asr_audio.dart:41）；storage_usage_service.dart:552 的 kAsrJobsSupportChild 只是一份镜像常量，所有者并不引用它
- BUG-1905（总计=类目之和，白名单漏什么就静默少算什么）、BUG-2096（类目根之下没有明细）、BUG-1870（support 根逐文件铺开）是同一机制先后发作了三次

机制：「哪个目录属于谁、什么性质」这件事没有登记源。所有者用字面量 p.join(root, 'x') 自己派生目录，扫描器和迁移器各维护一份清单去反推，再拿守卫测试兜两份清单的一致性。support 根和缓存根连清单都没有，于是按「兜底类目」处理。新增一个存东西的子系统时，默认结果是被算错类、删不掉或者漏统计，只有守卫恰好能匹配那种字面量写法时才会报错。

根本方案：在 packages/fushi_engine（纯 Dart，app 和 fushi_server 共用）新建 storage/storage_areas.dart，定义 `enum StorageArea`：每个值声明 root（documents / support / appCache）、relativePath、category、lifecycle（userData / libraryContent / derived / cache / redownloadable / control）、migratesWithDataRoot、cleaner（可选，见下一条）。所有者一律通过 `StorageArea.x.resolve(roots)` 拿目录，不再手写字面量。
从它派生、并删除手写版：AppPaths.fushiOwnedDocumentsEntries（改成按 migratesWithDataRoot 过滤的 getter）、kStorageCategoryDocumentsChildren、kAsrJobsSupportChild / kOcrModelsSupportChild / kInterconnectSyncDataSupportChild、scanCategories 里的 switch。support 根也按登记扫；登记表之外的东西进「未归类」类目，并在诊断里报出名字，不再兜进 database。
以后新增一个存储子系统，只在 StorageArea 加一个值。守卫换成 custom_lint / 源码守卫：禁止在 StorageArea 之外写 p.join(<documents|support|temp 根>, '<字面量>')。documents_whitelist_guard_test 与「类目全覆盖」测试随之删除，枚举的穷尽性由类型系统保证。

要动：packages/fushi_engine/lib/storage/（新）；fushi/lib/src/storage/app_paths.dart；fushi/lib/src/storage/storage_usage_service.dart；各 support/documents 子目录所有者（asr / tts / ocr / sync / torrent 等约 30 处派生点）；fushi/test/storage/documents_whitelist_guard_test.dart

核验说明：已验证：storage_usage_service.dart:489-550 的 kStorageCategoryDocumentsChildren 与 app_paths.dart:1490-1540 的 fushiOwnedDocumentsEntries 是两份手写清单，storage_usage_service_test.dart:76-91 用「互为全集」断言把它们钉在一起（注释原话「逼着给它选一个存储类目——否则存储页总量会漏账」）。_scanDatabase（:1146-1215）列 support 根的直接子项，只排除 ocr_models / asr_jobs / sync-data / 快照；其余子项走 _childEntries，按 :1288-1292 的逻辑，database 不在 kDeletableEntryCategories 里，所以都是 readOnly。support 下的字面量派生点逐一核实存在：tts_services.dart:138 tts_cache、fushi_remote_lookup_client.dart:128、gal_loopback_voice_detector.dart:173 asr_models、gpt_sovits_local_engine.dart:164、gpu_acceleration.dart:130。'asr_jobs' 字面量在 5 个所有者文件里各写一份（apple_speech:65、cloud_whisper:360、video_subtitle_pipeline:239、music_asr_subtitle_sink:47、music_plugin_asr_audio:41），kAsrJobsSupportChild（:552）确实没有被这些所有者引用。「约 26 个」这个数没有逐个点名，属于推测量级，但机制成立。docs/specs 下没有存储登记表的设计，查不到「这是有意设计」的反证。

方案风险：① fushiOwnedDocumentsEntries 不只给存储页用，还是迁移 / Android 迷途库合并 / 库见证的判据（app_paths.dart:668-697、android_stray_library_merge.dart:26-38、android_library_db_witness.dart:121-137），而且有刻意排除项：video_clips、桌面导出目录 Hibiki 不随根搬。登记表必须带精确的 migratesWithDataRoot 标志和冻结旧名别名（hoshi_books、hibikiExport、kLegacy* 常量），不能改名或丢项；类目改名也不能动磁盘目录名（冻结规则）。② 把一个硬编码 enum 放进 fushi_engine，就要它列出 galgame loopback、gpu_runtime 这类纯 app 子系统，等于把 app 知识倒灌进引擎。更合适的是引擎只定义 StorageArea 类型和注册表，app 与 server 各自装配注册（同时满足 fushi_engine 禁 import package:fushi）。代价是穷尽性不再由 enum 保证，要靠「未登记即进未归类 + 诊断上报」兜。③ 源码守卫只能拦「根 + 第一段字面量」，所有者在自己区域内的子路径（asr_jobs/music_subtitles/out）仍然是字面量，守卫的匹配范围要写清楚。④ support 下一些东西现在显示为只读，登记后会变成可删（比如 asr_models、gpt_sovits 的运行时）。删的时候所有者可能正持有文件句柄（模型已加载），删除必须走所有者原语，这一条要和 cleanup-policy-scatter 一并设计。

修正后的方案（以此为准）：引擎层（fushi_engine）只定义 StorageArea 值类型，字段为 id、root、relativePath、legacyNames、category、lifecycle、migratesWithDataRoot，外加一个 StorageAreaRegistry。app 和 fushi_server 各自在装配期 register 自己的区域，所有者从自己登记的那个 area 取目录。fushiOwnedDocumentsEntries 改由 registry 中「documents 根 + migratesWithDataRoot」的区域派生，并且要逐项对齐现有集合：先加一个一次性等价断言测试，再删手写版。documents / support / cache 三个根下未登记的直接子项进「未归类」类目并写诊断日志。守卫只拦「AppPaths 根 + 第一段字面量」。

## cleanup-policy-scatter

**可删性与删除方式散在 4 个集合和 2 个 switch 里，且自相矛盾：封面和浏览器登录态可以被裸删**

- 类型：守卫代替结构；规模 L；价值 high；用户可见
- 核验：成立

证据：

- fushi/lib/src/storage/storage_usage_service.dart:182-191 kDeletableEntryCategories 把 covers、web 列为「删了不会留下悬空引用」，产出 derivedFile 明细，走裸删
- fushi/lib/src/settings/storage_usage_actions.dart:495-509 kClearAllCacheCategories 的注释自己写着 covers 里有用户手动设的封面（CoverOrigin.manual，music_albums.cover_path 指着），web 是浏览器登录态和 Cookie，都是用户数据。两份集合对同一个目录的性质判断相反
- storage_usage_service.dart:196-199 kDirectlyDeletableEntryKinds 和 kDeletableEntryCategories 是「同一件事的两个面」，BUG-1979 审查补修时专门加了守卫钉住它们一致
- storage_usage_actions.dart:224-231 isStorageEntryDeletable 与 :235-305 deleteStorageEntry 按 kind 写 switch；storage_usage_view.dart:300-313 确认文案又按 kind 写一遍 switch，:318、:902-916 再给 interconnectLegacyFileBox 单独加分支
- storage_usage_view.dart:776-778 着色器类目上挂了 Anime4K 专用的删除按钮（anime4kBytesProvider / anime4kDelete 单独一条链路）。settings_schema_storage.dart 里 SRS 保留副本又是另一个独立的删除入口，存储明细里看不到它
- BUG-1870 ③ 首轮黑名单式判据差点删掉活的恢复 sidecar，是同一机制造成的丢数据险情

机制：「这块数据能不能删、谁来删、删之前要满足什么条件」本该是目录所有者的知识，现在被存储页用类目级布尔集合加 kind switch 重新编码了一遍，而且编码了好几次。每加一种可清理数据，就要新增一个 StorageEntryKind，再把 6 处同步改一遍。判据写在类目这个粒度，太粗，所以会把用户数据和缓存划成同一个结论。

根本方案：在 StorageArea 上挂 `StorageCleaner` 接口，由所有者实现：`Future<StorageDeleteOutcome> delete(StorageEntry)`、`ValueListenable<String?> blockedReason`（例如互联 host 正在运行）、`String confirmBody()`、`bool includedInClearAllCache`。lifecycle==cache 的区域默认用 bare-delete cleaner；userData / libraryContent 的区域只能挂所有者自己的原语（书走 deleteBook、词典走 deleteDictionary、快照走 deleteDatabaseSnapshotFiles、互联走 pruneDeadInterconnectFileBox、Anime4K 走它的清单删除、SRS 保留副本走它的 retained-delete）。
删除：kDeletableEntryCategories、kDirectlyDeletableEntryKinds、kClearAllCacheCategories、StorageEntryKind 里的删除语义、deleteStorageEntry / isStorageEntryDeletable / 视图里的 3 个 switch、Anime4K 和互联的专门分支。条目只带 cleaner 引用。
以后新增一种可清理数据，只在所有者那里实现一个 cleaner，并在 StorageArea 上声明。结构保证：lifecycle 是 userData 的区域，类型上不允许挂 bare-delete cleaner（构造期断言或 sealed 类型）。

要动：fushi/lib/src/storage/storage_usage_service.dart；fushi/lib/src/settings/storage_usage_actions.dart；fushi/lib/src/pages/implementations/storage_usage_view.dart；fushi/lib/src/settings/settings_schema_storage.dart；fushi/lib/src/ops/ctl_settings_body_storage.dart

核验说明：已验证：kDeletableEntryCategories（storage_usage_service.dart:182-191）的判据写的是「删了不会留下悬空引用」，并把 covers / web / shaders 列为派生或缓存；kClearAllCacheCategories 的注释（storage_usage_actions.dart:495-506）却写明 covers 里有 CoverOrigin.manual、game_covers 会进备份，web 是登录态 Cookie 和用户存档，mpv_shaders 里混着用户自己导入的着色器。app_paths.dart 也注明 music_albums.cover_path 指向 music_covers。所以「删了不留悬空引用」这个前提对 music_covers 不成立，对手动封面和用户着色器则是裸删用户数据（虽然删前有逐条确认，丢的东西仍然找不回）。kind 上的 switch 确实分散在三处：isStorageEntryDeletable :224、deleteStorageEntry :235-305、view 的 :300-318。Anime4K 走单独链路（view:62-63、443-468；video_shader_downloader.dart:687-701），而它的文件就在 mpv_shaders 里，同时又是 shaders 类目下的 derivedFile 明细，同一批文件有两条删除路径。两份集合的「有意分层」（逐条删 vs 一键清）确实是刻意设计，但 kDeletableEntryCategories 自己的判据文字与事实不符，所以判 confirmed。

方案风险：lifecycle 挂在区域（目录）这一级仍然太粗：同一个 video_covers 里有自动抓的封面（缓存），也有 CoverOrigin.manual（用户数据）；mpv_shaders 里既有可重下的 Anime4K，也有用户导入的文件。可删性必须由所有者在条目级判定（covers 要查 DB 的 origin），否则 sealed 类型只是把错误从 6 处挪到 1 处。cleaner 的 confirmBody 返回 String，会把 i18n 拉进引擎层，应改成返回 key 或语义枚举，由 UI 层翻译。ctl 的 rm 和 server 共用 cleaner 时，blockedReason 判据（例如互联 host 正在运行）必须在执行端再判一次，不能只在 UI 上判。

修正后的方案（以此为准）：在 StorageArea 上挂所有者实现的 StorageAreaOwner，它负责枚举条目，并给每个条目返回 deletability：no / confirm / cacheBulk，外加删除原语。区域级 lifecycle 只作为默认值。covers 的所有者按 CoverOrigin 把手动封面标成 no，或者在条目上明确标成用户数据。Anime4K 收编为 shaders 所有者给出的一个聚合条目，删掉页面上的专用按钮和 anime4kBytesProvider / anime4kDelete 透传。确认文案返回语义枚举加参数，由 UI 层渲染。

## scanner-rederives-owner-paths

**扫描器替书、有声书、词典、视频的所有者反推落盘路径，镜像规则只能靠「逐字节一致」测试守着**

- 类型：镜像状态；规模 M；价值 high；不改外部行为
- 核验：成立

证据：

- storage_usage_service.dart:734 audiobookPersistDirPath 是 AudiobookStorage.ensurePersistDir 哈希规则的镜像；storage_usage_service_test.dart:93 专门有一个用例「与 AudiobookStorage 真实落盘目录逐字节一致」来防漂移
- storage_usage_service.dart:409 resolveBookStoragePaths 加 :369 _dedupeNestedPaths 把「DB 路径 ∪ 哈希目录」两种落盘形态在扫描侧拼起来（BUG-1893：sync_asset_package_service.dart 用明文目录，而扫描端只认哈希目录）
- storage_usage_actions.dart:357-452 loadStorageBookRefs / storageAudioPathsOf 在存储层自己解析 audioRoot / audioPathsJson 这两个有声书列
- storage_usage_service.dart:879-886 _scanBooks 在 UI isolate 上对每本书调 resolveBookStoragePaths；BUG-5536 的整窗冻结（O(n²) canonicalize，占主 isolate 72% 样本）就出在这里
- storage_usage_service.dart:573-650 subtitleJobEntriesSync / kSubtitleJobOutputDirNames 又把 ASR 任务目录的内部布局（disc_out / out）写了一遍

机制：明细条目（一本书占多少）的路径集合只有所有者知道，但接口没有让所有者交出来，于是扫描器按所有者现有的落盘约定去猜。所有者一改落盘方式（同步导入改成明文目录、文件列表模式、引用外部文件），扫描器就悄悄少算，每次都要在扫描侧补一个特例。去嵌套这类计算还因此落到了 UI isolate。

根本方案：StorageArea 可以声明 `entryEnumerator`，由所有者实现：在后台 isolate 里给出 `(id, title, ownedPaths, externalPaths)`。书和有声书由 ReaderFushiSource / AudiobookStorage 一侧提供，路径直接取自它们写入时用的同一套函数；ASR 任务由 asr 模块提供；词典由词典模块提供。
扫描器只做两件事：把路径求和，再用「直接子项减去已认领」生成孤儿行（BUG-2096 的通用机制留在扫描器里，作为结构）。
删除：audiobookPersistDirPath 镜像和它的逐字节守卫、resolveBookStoragePaths 中的形态推断、storageAudioPathsOf、subtitleJobEntriesSync。以后所有者改落盘方式，只改它自己的 enumerator。

要动：fushi/lib/src/storage/storage_usage_service.dart；fushi/lib/src/settings/storage_usage_actions.dart；fushi/lib/src/media/audiobook/；packages/fushi_engine/lib/media/video/subtitle/asr_proofread/；fushi/lib/src/media/sources/reader_fushi_source.dart

核验说明：已验证：audiobookPersistDirPath 在 storage_usage_service.dart:737，resolveBookStoragePaths 在 :409，它在 :418 调用哈希目录推导，在 :425-429 去嵌套。_scanBooks 在 :879-886 对每本书调 resolveBookStoragePaths，这一步在 :893 的 _run 之前、跑在调用方 isolate 上。BUG-5536 第 7 行原文确认根因就在这里（主 isolate 72% 样本），修法只是把复杂度降下来，计算仍留在 UI isolate。BUG-1893 记录的就是扫描侧补「DB 路径 ∪ 哈希目录」这个特例。kAsrJobsSupportChild 与所有者字面量各自独立，结论同 storage-area-registry。

方案风险：所有者的 enumerator 要在后台 isolate 跑，就需要 DB 行（书目、有声书 audioPathsJson）。drift 查询结果要拷回发起 isolate，所以要么在后台 isolate 开 DB 连接（和主连接并存，要确认 drift 多连接与 WAL 的约束），要么主 isolate 取瘦投影后只把字符串送过去。BUG-5187 已经证明，整行读进 UI isolate 本身就是卡点。另外 externalPaths（引用外部文件）不计入总量但要显示，这个契约 enumerator 必须保留。

## full-walk-no-cache

**每次打开页面、每次 ctl ls / rm 都把数十 GB 全树 stat 一遍，同一棵树另有 3 个独立遍历器**

- 类型：性能；规模 L；价值 high；用户可见
- 核验：部分成立

证据：

- storage_usage_service.dart:805-862 scanCategories 每个类目单独 await 一次 _run(Isolate.run)，约 15 次串行起 isolate，没有任何结果缓存
- storage_usage_service.dart:662-692 directorySizeSync 每次都用 listSync(recursive) 整树遍历；BUG-5536 记录的用户数据是 docs 16.5 GB 加 support 17 GB、sync-data 3.6 万个文件，修复后扫一次仍要 5.3-5.6 s
- fushi/lib/src/ops/ctl_settings_body_storage.dart:28-29、:56、:76-80 的 categories ls、entries ls、entries rm 各自调 scanAllStorageCategories 全量重扫；删一条明细就要先全量扫一遍
- fushi/lib/src/diagnostics/storage_footprint_log.dart:84-149 measureStorageFootprint 是第二个独立的递归遍历器，启动 20 s 后把同一批根再走一遍
- storage_usage_service.dart:801 measureInterconnectSyncData（fushi_engine）是第三个；:1500-1534 scanBundledComponents 是第四个，候选清单还是硬编码的（:1511-1518）
- BUG-5187 / BUG-5536 两次「开存储页卡顿」都是在这条全量路径上逐点补的（瘦投影、去嵌套降复杂度）

机制：占用被当成「调用时现算」的值，而不是一份有生命周期的快照。所以每个消费者（页面、ctl、诊断日志）都各自从零开始遍历，每次遍历又按类目拆成多次 isolate 往返。性能问题只能逐点抠常数。

根本方案：把它做成一个长驻的占用快照服务：一个后台 worker 一次遍历全部已登记区域，产出按 StorageArea 和顶层子项分层的 size index。每个目录节点记 (mtime, bytes)，下次扫描时 mtime 没变的子树直接复用。按架构硬规则，这类计算型子系统应放进 Rust 胖核心（例如 native/fushi_storage：粗粒度命令 scan(areas) / invalidate(area)，外加一条快照 stream）；如果判断收益不足，至少放在 fushi_engine 的单个长驻 isolate 里，主 isolate 只收结果。
各所有者写盘或删除后调用 invalidate(area)（cleaner 执行完自动调）。页面、ctl、server、诊断日志都订阅同一份快照，删除后只重扫受影响的区域。
删除：directorySizeSync / _childEntriesSync / _pathsSizeSync、measureStorageFootprint 的遍历部分（改成消费快照，再加 Android 外部目录这个区域）、ctl rm 前的全量重扫。

要动：fushi/lib/src/storage/storage_usage_service.dart；fushi/lib/src/diagnostics/storage_footprint_log.dart；fushi/lib/src/ops/ctl_settings_body_storage.dart；native/（新 crate，或 packages/fushi_engine/lib/storage/）

核验说明：已验证的部分：scanCategories（:805-862）对每个类目串行 await 一次 _run，没有缓存。ctl 的 categories ls / entries ls / entries rm（ctl_settings_body_storage.dart:34-35、:50、:74、:79-81）每次都全量重扫，rm 之前也要整扫一遍。storage_footprint_log.dart:90-133 是独立的递归 listSync 遍历器。measureInterconnectSyncData、scanBundledComponents 也各自单独遍历。cache 和 backups 两个类目已经共用一次列举（:845-850），审计没提这一点，但它不影响结论。不成立的部分：根本方案里「目录节点记 (mtime, bytes)，mtime 不变的子树直接复用」是错的。目录的 mtime 只在直接子项增删或改名时变，深层文件增删不会改变祖先目录的 mtime；文件原地追加（DB、WAL、.part 续传、日志）连父目录的 mtime 都不改，Windows 上同样如此。按这个规则复用子树，会把正在增长的 sync-data、下载、日志算成旧值，比现在的「慢但准」更糟，是一种新的静默少算。

方案风险：① 拿 mtime 做增量剪枝，语义上会漏算（见 reason）。② 迁 Rust：目录求和是 IO 型而非计算型，「Rust 胖核心」规则针对的是计算型子系统。为此新开 native crate 会带来五端构建和 FFI 成本，收益主要来自遍历次数减少和缓存，与语言关系不大；要迁先拿实测数据说话（规则原文：「存量 Dart 只因实测性能问题才搬」）。③ 长驻快照要处理过期问题：所有者写盘后不调 invalidate，就会显示旧值。所以只能做到「invalidate 加 TTL 加用户手动刷新」，不能宣称结构性一致。

修正后的方案（以此为准）：做一个单一的后台扫描服务（在 fushi_engine 里，单个长驻 isolate 或一次 Isolate.run 跑完所有区域，不按类目拆成多次往返），对外给出按区域分层的快照。缓存只按区域粒度失效：cleaner 执行后、所有者写入后调 invalidate(area)，另外有页面刷新入口，不做基于 mtime 的子树复用。ctl 的 rm 直接用最近一次快照里的条目，删除前只对该条目的 paths 再 stat 一次，不再全量重扫。storage_footprint_log 改成消费同一份快照，并补上 Android 外部目录区域。是否下沉 Rust，等单次遍历合并后仍有实测瓶颈再议。

## three-surfaces-diverge

**占用数据有三个对外入口、各算各的口径，fushi_server 完全没有**

- 类型：app / 服务端各写一套；规模 M；价值 medium；改持久化 / wire、用户可见
- 核验：部分成立

证据：

- fushi/lib/src/ops/ctl_data_routes.dart:1387-1408 /api/admin/storage/usage 传 books: const []、不传 videos、不传词典显示名。注释说「明细要书目清单，组装逻辑在设置 schema 里，CLI 不复制」，但这条已经过时：StorageUsageActions.of 已经抽出来，ctl 条目就在用它
- fushi/lib/src/ops/ctl_settings_body_storage.dart:28-29 storage.cli.* 条目走 StorageUsageActions 全量输入，和上面那条路由对同一台机器给出不同的明细与可删数
- packages/fushi_cli/lib/src/commands/data_commands.dart:309-314 `fushi storage usage` 调的是前者（/api/admin/storage/usage），说明里写着「同设置 › 存储」，但口径并不同
- packages/fushi_server/lib/src/admin/admin_api.dart 里 grep 不到 storage usage 路由，WebUI 没有占用页；server 自己的 torrent / sync-data / 媒体库目录（server_paths.dart:44）无从查看占用
- storage_usage_view.dart:60-95、:352-369 StorageUsageView 有 16 个构造参数：fromActions 把 StorageUsageActions 拆开逐个传入，_actions 再拼回去，同一份接线在 widget 里存了一份镜像

机制：占用的组装逻辑（输入取数加扫描）住在 app 的设置层，没有引擎层的「占用报告」API。每个新入口只能自己挑一部分输入去喂扫描器，于是口径漂移，server 也就干脆没有这个能力。

根本方案：在 fushi_engine 定义 `StorageUsageReport producer(StorageHost host)`。StorageHost 提供根目录解析和已登记区域（各所有者的 enumerator / cleaner），app 和 fushi_server 各自装配一个 host。
三个入口都改成消费同一个 report：app 设置页、ctl 的 storage.cli.*、/api/admin/storage/usage，fushi_server 的 admin API 和 WebUI 也加同一条路由（同一个 op 描述）。删除 ctl_data_routes.dart:1387-1408 的手写组装。StorageUsageView 改成只接收 report stream 和 cleaner 调度器，去掉 16 参透传和 _actions 镜像。
以后加一个入口只消费 report；加一种数据只改登记源。server 侧缺口登记进 docs/agent/server-parity-gaps.md，直到补齐。

要动：packages/fushi_engine/lib/storage/；fushi/lib/src/ops/ctl_data_routes.dart；fushi/lib/src/ops/ctl_settings_body_storage.dart；packages/fushi_server/lib/src/admin/admin_api.dart；packages/fushi_cli/lib/src/commands/data_commands.dart；fushi/lib/src/pages/implementations/storage_usage_view.dart

核验说明：成立的部分：ctl_data_routes.dart:1387-1408 的路由传入 books: const []、不传 videos，注释「CLI 不复制」已经过时，ctl_settings_body_storage.dart:28-35 早就复用了 StorageUsageActions.of。fushi_server 的 admin_api.dart 里 grep 不到任何存储占用路由，server 这块确实缺失。StorageUsageView 先由 fromActions 拆开（:73-95），再经 _actions 拼回（:353-365），存了一份镜像接线，属实。不成立的部分：「口径不同」。这条路由只输出类目合计 bytes，而合计按类目根下直接子项求和（_scanBooks 的 :893-935 用 _sumChildBytes(children)，注释写着「总量按目录整树（含孤儿），明细按 DB 已知的书」），与传不传 books / videos 无关。所以 `fushi storage usage` 和设置页给出的类目合计一致，CLI 说明里的「同设置 › 存储」对合计这一层成立。差别只在 CLI 不输出明细和可删数，是信息少，不是口径冲突。

方案风险：给 server 加路由属于新增 wire 能力，要同步写 op 描述，并登记进 server-parity-gaps.md。server 的存储区域（torrent、sync-data、媒体库，见 server_paths.dart）和 app 的不同，所以 StorageHost 必须由 server 自己装配区域，不能直接复用 app 的类目表。i18n 标题不能进引擎层的 report，report 只带类目 id，标题由各端渲染。

## unowned-temp-root

**临时文件没有 Fushi 专属根：140 个文件直接调系统 temp，桌面缓存统计只能恒为 0，macOS 靠平台特判**

- 类型：守卫代替结构；规模 L；价值 medium；用户可见
- 核验：成立

证据：

- grep 统计：fushi/lib 与 packages/*/lib 里 getTemporaryDirectory() / tempRootDirectory() / Directory.systemTemp 共 211 处，分布在 140 个文件
- storage_usage_service.dart:1305-1316 _defaultCacheRoots 加 :1549-1604 resolveStorageCacheRoots 按 sandboxedMobile / macOS / sharedTempDesktop 三分支门控；桌面直接返回空
- docs/bugs/BUG-3894-macos-storage-shared-caches.md 备注写明「把 macOS 临时根整体迁到专属子目录是更大的改动（40+ 处直接调 getTemporaryDirectory()），未做」；BUG-1905 备注写明桌面 Fushi 自己的临时文件「只能再引入一份白名单」，所以放弃统计
- BUG-1979：备份包落在共享 temp，只能靠文件名正则从缓存里分流出来（storage_usage_service.dart:1352 _scanBackups）

机制：临时文件的落点交给各处直接调平台 API 决定，而平台 temp 在桌面和 macOS 上是全系统共享的。统计和清理没法区分哪些是 Fushi 的，只能用平台 if 加文件名正则加「宁少报」的取舍去绕。

根本方案：在 AppPaths（及 engine_paths）提供唯一的 `appScratchDirectory(purpose)` = <平台 temp>/fushi-<实例>/<purpose>，所有平台统一由 Fushi 独占，并登记为 StorageArea（lifecycle=cache）。用源码守卫禁止在 AppPaths 之外调 getTemporaryDirectory / Directory.systemTemp（file_picker 等第三方产物在导入完成后搬进 scratch 区或删除）。
然后删除 StorageCacheRootPlatform 的三分支和 _scanBackups 的正则分流（备份包改落 scratch/backup_export 区，自然成为一个区域）。桌面的缓存统计和「一键清缓存」随之可用。

要动：fushi/lib/src/storage/app_paths.dart；packages/fushi_engine/lib/foundation/engine_paths.dart；约 140 个调用 temp 的文件；fushi/lib/src/storage/storage_usage_service.dart

核验说明：已验证：fushi/lib 与 packages/*/lib 里有 140 个文件调用 getTemporaryDirectory() / tempRootDirectory() / Directory.systemTemp，其中前者与 systemTemp 共 199 处，tempRootDirectory() 12 处，合计 211 处，与审计一致。BUG-3894 备注原文写着「把 macOS 临时根整体迁到专属子目录是更大的改动（40+ 处直接调 getTemporaryDirectory()），未做」，按自身口径这是一份已知、未登记的分期欠账。resolveStorageCacheRoots（:1585）按平台三分支门控，_scanBackups（:1352）靠文件名分流备份包，都属实。

方案风险：① 第三方插件（file_picker、image_picker、path_provider 的消费方、mpv、WebView）会自己往平台 temp 写东西，这部分源码守卫管不到，只能在导入完成后清理，桌面上这部分统计会永远缺一块，方案应该写明这一点。② iOS / Android 的平台 temp 和缓存目录本来就是 app 私有的，系统也会清，迁到 fushi-<实例> 子目录对这两端没有好处；跨平台统一时别在移动端多套一层而丢掉系统托管语义。③ 「实例」这个名字要按 naming.md 定，不能和 Hibiki 等冻结的旧名冲突。存量放在共享 temp 里的旧文件，迁移后再也统计不到，需要一次性清理或者接受不再统计。

## 核验补充（审计漏掉的）

- Anime4K 的文件在 mpv_shaders 里（video_shader_downloader.dart:687-701 调 mpvShaderDirectory），而 shaders 类目在 kDeletableEntryCategories 中（storage_usage_service.dart:186）。同一批文件因此有两条删除路径：一条是逐条 derivedFile 裸删，另一条是 Anime4K 专用按钮按清单删。用户自导入的着色器同样能被裸删（kClearAllCacheCategories 的注释 storage_usage_actions.dart:505 自己也承认 mpv_shaders 里混着用户着色器）。这是可删性放在类目这一级判定的直接后果，审计只把 Anime4K 当成 UI 上的一个特殊分支来提。
- kDeletableEntryCategories 的文档判据「删了不留悬空引用」（storage_usage_service.dart:161-163）与事实不符：music_albums.cover_path 指向 music_covers（app_paths.dart 白名单注释），手动封面在 DB 里有 CoverOrigin.manual 记录。逐条裸删会留下悬空的 cover_path，并把手动设置的封面永久丢掉。这已经是现存的丢数据路径，不只是设计问题，建议按 bug 流程单独登记。
- BUG-5536 只把 _dedupeNestedPaths 的复杂度降了下来，resolveBookStoragePaths 仍在 UI isolate 上对每本书运行（storage_usage_service.dart:879-886，位于 :893 的 _run 之前）；BUG-5187 备注里指出的约 12 次逐类目 setState 整页重建，至今未处理也未登记。这两条都是「逐点补」之后留下的、已知未修的尾巴。
