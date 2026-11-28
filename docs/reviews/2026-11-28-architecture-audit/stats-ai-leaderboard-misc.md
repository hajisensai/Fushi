# 架构审计：stats-ai-leaderboard-misc

2026-11-28 只读审计 + 独立反驳核验的原始结论。总方案见 [../../specs/2026-11-28-architecture-redesign.md](../../specs/2026-11-28-architecture-redesign.md)。

## 现状

统计域的派生已在 BUG-4960/5203 搬进 Rust（ffc_stats_derive），但事实面没有任何常驻状态：每个消费者每次调用 loadStatFacts 都新起一次性 isolate、重连 drift、把多张历史表整读一遍，再整块塞进 Rust 做无状态派生；小组件、伴屏摘要、首页、导航速览和各统计页各自独立触发，没有共享缓存，也没有增量失效。AI 域：AiFeature 是枚举，设置页用穷尽 switch 列标题和图标，编译器会逼着补齐，所以「feature 分配登记重复」的怀疑不成立；真正分散的是 ai_chat_client.dart（2001 行）里按 AiWireProtocol 写的十来处 switch。自更新是全域最重的补丁堆：app 端 update_checker 是 6 个 part 合起来约 6500 行的库，再加 platform_updater.dart 2098 行，网络、下载、UI 混在一个导入 material_ui 的库里；它自带一套分片下载引擎，和通用的 SegmentedDownloader 并存；fushi_server 又另写了一套 release 选择和 digest 解析。平台通道没有单一协议定义：Dart 的 FushiChannels 靠注释要求与 Java 的 ChannelNames 手工同步，方法名在 Dart、C++、Swift、Java 各处都是裸字符串，「通道没注册到某个引擎 / controller」这类 bug 反复出现，每次靠新增一个源码守卫兜底。日志与诊断有十来个各自实现文件路径、轮转、读后清和折进错误日志的类，启动路径上在主 isolate 同步 IO，反馈汇总点也是手工逐个拼接。Worker 侧是 430 行的 if 链路由，限流、缓存、鉴权的选择散在 worker.js，Bearer 解析和角色判据在各模块里各写一份，triage 权限另立一张正则表与真实路由手工对齐；app 与 Worker 之间的线协议常量（反馈上限等）两边各写一份，靠 JS 测试用正则去读 Dart 源码比对。

## update-stack-fork

**自更新栈三处分叉：app 的 6500 行 part 库自带分片下载引擎，与通用下载器、fushi_server 各写一套 release 选择 / digest 解析**

- 类型：缺单一登记源；规模 XL；价值 high；不改外部行为
- 核验：部分成立

证据：

- fushi/lib/src/utils/misc/update_checker.dart:1-36 是 barrel library，靠 part 把 net/download/race/release/ui/headless 绑在一起共享私有作用域，并在同一个库里导入 material_ui、flutter_markdown 和 path_provider，网络层因此不能被 fushi_engine/fushi_server 复用
- wc：update_checker_*.dart 合计 6474 行，另有 platform_updater.dart 2098 行、flatpak_updater.dart 524 行；docs/bugs 里 66 份记录点名 update_checker / platform_updater，其中 23 份涉及通道
- fushi/lib/src/utils/misc/update_checker_download.dart:620-681 自定义 DownloadSegment/planDownloadSegments，:980-1062 是自写的分片下载 _downloadSegmented；与此同时 fushi/lib/src/utils/misc/segmented_downloader.dart:1-30（654 行）是另一套通用分片下载器，只给 recommended_pack 用
- fushi/lib/src/utils/misc/platform_updater.dart:102-110 `_assetSha256Digest` 与 packages/fushi_server/lib/src/self_update/server_release.dart:249-254 `normalizeSha256Digest` 逐行同构
- fushi/lib/src/utils/misc/update_checker_version.dart:20-43（draft/tag/prerelease 通道判据）与 server_release.dart:181-212 `pickServerUpdate`（draft/prerelease/rolling 判据）各写一套 GitHub release 选择
- BUG-277 / BUG-1875 / BUG-271：镜像回退先在更新检查里修，再到 Mihon、shader 下载各补一次，最后才收敛成 github_mirrors.dart

机制：更新功能最早写成一个 UI 类，之后按 TODO 一块块拆成 part，私有符号仍能跨 part 互相引用，网络、下载、UI 从来没有真正分层。能用的通用件（ResumableDownloader、github_mirrors）是在 bug 驱动下逐块下沉的，分片路径和 release 模型没跟着下沉。fushi_server 用不了带 Flutter 依赖的库，只好重写 release 选择。

根本方案：新建纯 Dart 的 packages/fushi_engine/lib/update/：①release_model.dart 作为唯一的 GitHub release 模型，统一 tag 规范化、通道准入（含嵌套合集）、资产命名 / sequence、digest 规范化，app 与 server 共用；②下载只保留一个引擎：把 segmented_downloader 下沉到 fushi_engine，合并 update_checker_download 的分片、续传、staging 元数据和 race 选源，ResumableDownloader 作为它的单流退化路径；③平台安装器（Android APK / Windows launcher / mac swap / Flatpak / server bundle swap）实现同一个 `UpdateInstaller` 接口，按平台各放一个文件，只在一个工厂里选平台。删除：update_checker_download.dart 中的分片实现、update_checker_race.dart 中重复的分段规划、platform_updater.dart 的 _assetSha256Digest、server_release.dart 的通道与 digest 判据。fushi/lib 只保留对话框、进度遮罩和 HeadlessUpdateFlow 的装配。以后新增一个平台只加一个 UpdateInstaller 实现，新增一个通道只改 release_model。守卫：fushi_engine 禁 Flutter 的现有规则会自动挡住 UI 渗回模型层；再加一条守卫，禁止 fushi/lib 与 fushi_server 出现 'tag_name' / 'digest' 字面量解析。

要动：fushi/lib/src/utils/misc/update_checker*.dart；fushi/lib/src/utils/misc/platform_updater.dart；fushi/lib/src/utils/misc/flatpak_updater.dart；fushi/lib/src/utils/misc/segmented_downloader.dart；packages/fushi_engine/lib/utils/misc/resumable_downloader.dart；packages/fushi_server/lib/src/self_update/；fushi/lib/src/updates/host_self_update_service.dart

核验说明：已验证：update_checker.dart:14-40 是 barrel library，在同一个库里导入 material_ui、flutter_markdown、path_provider、url_launcher；各 part 行数合计约 6474 行（download 1779、release 2063 等），platform_updater.dart 2098 行。platform_updater.dart:102-110 的 _assetSha256Digest 与 server_release.dart:249-254 的 normalizeSha256Digest 确实同构。update_checker_download.dart:620-681 有自己的 DownloadSegment/planDownloadSegments，同时 segmented_downloader.dart 只有 recommended_pack.dart 和 recommended_pack_download_controller.dart 两处使用。需要修正的地方：分片规划其实有三份，不是两份。segmented_downloader.dart:8 依赖 download_plan.dart 里的 DownloadPlan.ranged/single(:76-141)，它本身也是一套规划，还带 source_speed_ledger。这些通用件已经复用了 ResumableDownloader（segmented_downloader.dart:11、15 的 typedef 与之同形），所以不是完全各写一套。'release 选择两套' 只是部分成立：app 的通道判据要处理嵌套合集、manifest 的 per-asset version 印记（platform_updater.dart:112 起的 TODO-1205），server 处理的是 rolling，语义有差异，不能简单合并成一个函数。

方案风险：①segmented_downloader.dart 依赖 fushi/lib 里的 download_plan.dart 和 source_speed_ledger.dart，下沉到 fushi_engine 要连带搬走，而且要确认 source_speed_ledger 不依赖偏好或 Flutter。②update_checker_download 的 staging 元数据和续传落盘格式是磁盘上的冻结名（冷启动会接着续传旧的半截文件），合并引擎时必须读得懂旧的 staging 目录和 meta 文件，否则升级后第一次更新会丢掉已下载的部分。审计把 changesPersistenceOrWire 写成 false 是错的，至少要按「需兼容读」处理。③拟加的守卫要禁 'tag_name' / 'digest' 字面量，误伤会很大：Mihon、shader、recommended_pack 等其他 GitHub 资产路径也解析这些键。守卫应限定为「不得自行实现 release 通道判据」，或只扫 update / self_update 目录。④UpdateInstaller 接口要把 mac_update_handoff、update_handoff、update_landing 这类跨进程交接也纳入，不能只覆盖安装动作。

修正后的方案（以此为准）：保留三个目标：release_model 单一源、一个下载引擎、各平台各一个 UpdateInstaller。下载引擎以 segmented_downloader + download_plan + source_speed_ledger 为母体一起下沉到 fushi_engine，把 update_checker_download 的 planDownloadSegments 和 race 选源并进去。合并时提供一个旧 staging 元数据读取器，作为一次性迁移，读出来就转成新格式，不长期保留双格式。release_model 用参数化的通道策略同时表达 app 的 nested/manifest 印记和 server 的 rolling，不硬合成一个判据。守卫只限 fushi/lib/src/utils/misc/update_* 与 fushi_server/lib/src/self_update/ 不得自定义 digest 规范化与通道判据。

## stat-facts-no-resident-state

**统计事实面无状态：每个消费者每次都新起 isolate 全量读历史表，再整块塞进 Rust 重新派生，没有共享缓存，也没有增量失效**

- 类型：性能；规模 L；价值 high；不改外部行为
- 核验：部分成立

证据：

- packages/fushi_engine/lib/stats/stat_facts.dart:444-464 每次调用都 `Isolate.run`、`db.backgroundConnection()`，再在 :494-504 新建一个 FushiDatabase.shared 连接，用完就关
- stat_facts.dart:515-608 每次发出十余个读取：getAllReadingStatistics / getAllVideoWatchStatistics / getAllReadingHourlyLogs / getAllVideoHourlyLogs / getRecentActivityEvents(limit: 1<<31) / getStudySegments；fromDateKey 为空时读的是全部历史
- fushi/lib/src/platform/widget_snapshot_source.dart:166-171 订阅 watchDashboardDataChanges 和 srsRevision，:265-269 去抖 3 秒后执行 :312 `loadStatFacts(db, activityLimit: 0)`（全历史、不限范围）
- fushi/lib/src/second_screen/companion/companion_main_services.dart:84 与 companion_library_app_data.dart:561 伴屏摘要各自再做一次全量 loadStatFacts；home_dashboard_page.dart:1396、home_nav_peek.dart:1337 也各自加载
- fushi/lib/src/pages/implementations/reading_statistics_page.dart:273-283 同一个页面并发两次 loadStatFacts（book 域一次、since 一次），等于两个 isolate、两轮读表
- BUG-4960 / BUG-5203 / BUG-3034 / BUG-2976：统计和首页的卡顿已分多次修，每次只把一段计算挪进后台或 Rust，事实面的生命周期始终没动

机制：BUG-4960 只把派生算法搬进了 Rust（`ffc_stats_derive` 是无状态的纯函数），没有按「Rust 胖核心持有状态」把事实面本身做成常驻对象。每个调用方都把 loadStatFacts 当成「读一遍库」的普通函数，消费者越多、写入越频繁（阅读时 study_segments 会周期性写入），全量重读的次数越多。这一条是按代码路径推断的，没有实测数据：小组件、伴屏、首页三条订阅在学习过程中会被同一类表变更反复触发。

根本方案：把事实面做成 Rust 常驻状态（放在 native/fushi_compute 的 stats 模块，或新建 fushi_stats crate）：Rust 持有按日 / 按小时 / 会话的聚合，冷启动做一次全量建立；之后 Dart 在写 study_segments、galgame_sessions、activity_events 的同一个事务出口发一条粗粒度的 `stats_apply_delta`（一批行，TypedData），Rust 增量更新并递增 revision。对外只暴露 `stats_snapshot(scope, window)` 一个命令，外加一条 revision stream。Dart 侧用一个 `statFactsProvider(scope)` 按 revision 失效，小组件、伴屏、首页、统计页都从它取，不再自己调 loadStatFacts。删除：_loadStatFactsInBackground / _loadStatFactsOnConnection、每次调用都要做的整表打包（stat_derive.dart 的输入编码改为增量格式），以及各页面自建的「去抖后重读」。以后新增一种学习来源，只在 Rust 的 delta 适配和写入出口各加一处。守卫：除事实面模块外禁止直接调用 getAllReadingStatistics 等整表读取（lint 或源码守卫），让「页面自己扫全表」写不出来。

要动：packages/fushi_engine/lib/stats/stat_facts.dart；packages/fushi_engine/lib/stats/stat_derive.dart；native/fushi_compute/src/stats.rs；fushi/lib/src/platform/widget_snapshot_source.dart；fushi/lib/src/second_screen/companion/companion_main_services.dart；fushi/lib/src/pages/implementations/*statistics*_page.dart；fushi/lib/src/pages/implementations/home_dashboard_page.dart

核验说明：已验证：stat_facts.dart:444-464 每次调用都走 db.backgroundConnection() 和 Isolate.run，:494-504 用 FushiDatabase.shared 新建连接、用完关掉，整个仓库没有任何结果缓存或在途去重（grep 未发现 StatFacts 缓存）。reading_statistics_page.dart:273/279 确实并发两次。审计漏掉了不少调用点，实际有 20 多个：library_progress_reset.dart:85、ctl_settings_routes.dart:1005/1033、manga_fushi_page.dart:9209、reader_fushi/chrome.part.dart:3797、video_fushi/study_stats.part.dart:44、study_goal_edit_sheet.dart:118、settings_schema_study_goals.dart:644、study_diag_export.dart:36、galgame_home_page.dart:351、media_item_stats_dialog.dart:265、leaderboard/local_shelf.dart:111/233，以及 sync/local_library_host_service/sync_state.part.dart:66（同步只为取 activity rows 就整套派生一遍）。性能影响审计自己也标了是推测，没有实测；packages/fushi_engine/benchmark/stat_facts_main_isolate_benchmark.dart 已经存在，可以直接拿来量化，结论应以它为准。

方案风险：「在写入出口发 stats_apply_delta」这个方案漏掉了大量写路径：同步合并（sync_state 及 host 同步写入）、导入、library_progress_reset 清进度、删媒体、隐私可见性（media/privacy/media_visibility.dart）、Profile 归属与 legacy 可见性（legacyStatsVisibleTo）、SRS 复习格子（srs.db 是另一个库，由 srsRevision 驱动）、伴屏 / 服务端所在的其他进程写同一个库。手工给每个写出口打点，正是仓库禁止的那类「漏一处就错」的结构，Rust 常驻状态会和 DB 静默偏离。另外 scope 维度（book/video/game/mediaKey/fromDateKey）加 includeCounters、reviewsFrom、activityLimit 组合起来，常驻快照的 key 空间并不小。

修正后的方案（以此为准）：分两步。第一步：失效改由数据库自己驱动，不在写出口手工打点。用 drift 对事实表（study_segments、reading/video 统计、hourly logs、activity_events、galgame_sessions、可见性 / Profile 相关表）的 tableUpdates 流，加上 srsRevision，合成一个 statsRevision。再提供单一的 StatFactsService：按 (profile, scope, flags) 做在途去重并缓存最近结果，revision 变化才重算，所有调用方（含上面列出的 20 多处）都改走它。同时加守卫，禁止在 stats 模块之外直接调用 loadStatFacts 和 getAll* 整表读取。第二步：如果 benchmark 证明全量重建仍然是瓶颈，再把聚合常驻到 Rust，由 revision 触发增量，revision 出现跳变或来自外部进程的写入时整量重建，不依赖每个写出口手发 delta。

## platform-channel-no-contract

**平台通道没有单一协议定义：通道名和方法名在 Dart、C++、Swift、Java 各处是裸字符串，靠注释手工同步，注册遗漏一再出 bug，每次补一个源码守卫**

- 类型：成类 bug；规模 XL；价值 high；不改外部行为
- 核验：部分成立

证据：

- fushi/lib/src/utils/misc/channel_constants.dart:1-2 注释 `Java counterpart: app.fushi.reader.constants.ChannelNames — Both files MUST stay in sync`，同步全靠人
- 同一个 'app.fushi/window' 在 fushi/lib/src/utils/misc/shortcut_icon_sync.dart:150 和 fushi/lib/src/utils/window_caption_channel.dart:15 各定义一次，不在 FushiChannels 里；fushi/lib/src/platform/windows_ime_guard.dart:31 也是另立的字面量
- fushi/lib/src/platform 下 37 个文件直接 new MethodChannel，Dart 侧约 125 处 invokeMethod('字面量')；fushi/windows/runner/flutter_window.cpp:507-552 用 27 个 `call.method_name() == "..."` 的 if 链分发
- BUG-2075（macOS AppDelegate 强转失败，两个通道被静默跳过注册）和 BUG-3663（:popup 副引擎没注册 tts 通道）根因同一类；docs/bugs 里 18 份记录涉及 MissingPluginException，fushi/lib 里有 70 处 `on MissingPluginException` 兜底
- 为兜这类不变量已累积 6 个源码守卫：popup_engine_tts_channel_guard_test、anki_popup_engine_channel_guard_test、cross_app_audio_channel_wiring_guard_test、shortcut_channel_wiring_guard_test、android_selection_action_channel_guard_test、mihon_channel_reply_codec_guard_test

机制：通道契约只有 Dart 一侧（或一个注释）作为来源，原生侧按字符串手写分发和注册；哪个引擎 / 窗口需要哪些通道也没有清单。所以「漏注册」「名字拼错」「在副引擎上缺失」在编译期都发现不了，只能在运行时撞上 MissingPluginException，再由 try/catch 吞掉，或补一个正则守卫。

根本方案：引入单一的通道 IDL：用 pigeon 定义 fushi/pigeons/*.dart（或仓库自带的 JSON 清单加生成器），每个通道声明名字、方法、参数和返回类型，以及「要注册到哪些引擎」（main / popup / floating / companion）。生成 Dart 的类型化 API，加 Java/Kotlin、Swift、C++ 的 handler 接口和注册函数，每个引擎一个 `registerFushiChannels(engineKind, messenger)`。原生入口（MainActivity、FloatingDictPluginRegistrant、AppDelegate、flutter_window.cpp）只调这一处生成的注册函数，对应平台没实现时编译失败。删除：channel_constants.dart 与 Java 的 ChannelNames、各处字面量 MethodChannel 和 if 链分发、为通道写的那 6 个源码守卫，以及「平台未实现就吞 MissingPluginException」的兜底（改由生成代码显式声明 `unsupportedOn`）。以后新增一个方法只改 IDL，再实现生成出来的接口。

要动：fushi/lib/src/utils/misc/channel_constants.dart；fushi/lib/src/platform/；fushi/android/app/src/main/java/；fushi/macos/Runner/；fushi/ios/Runner/；fushi/windows/runner/flutter_window.cpp；fushi/test/**/*channel*guard_test.dart

核验说明：已验证：channel_constants.dart:1-2 的注释要求与 Java 的 ChannelNames 手工同步。'app.fushi/window' 在 shortcut_icon_sync.dart:150 和 window_caption_channel.dart:15 各写了一次字面量，dart_heartbeat.dart 也走这个通道；windows_ime_guard.dart:31 另立字面量。fushi/lib 里有 168 处 MissingPluginException（审计写的是 70，实际更多），仓库没有引入 pigeon。问题是真的。但「删除全部 MissingPluginException 兜底」不成立：其中相当一部分是有意的，用来应对 Linux / 某些平台根本没有该通道，以及测试环境；还有一部分来自第三方插件，IDL 管不到。

方案风险：①pigeon 生成的是 per-API 的 setUp(messenger)，不产出「哪个引擎注册哪些通道」的清单，engineKind 注册矩阵（main / popup / floating / companion）得自己写生成器。②原生侧现有部分方法是事件流或 EventChannel，以及 Windows runner 内部直接处理的消息（flutter_window.cpp 的 if 链里有窗口和 DPI 相关的同步调用，heartbeat 是高频调用），迁到 pigeon 后编解码和线程模型会变，需要逐个评估时延。③iOS 商店合规的三类能力不能通过「unsupportedOn」散写平台判断，必须仍以 store_compliance.dart 作为唯一判据。④那 6 个源码守卫只有在生成器真正覆盖了对应注册点之后才能删。

修正后的方案（以此为准）：建立仓库自带的通道清单作为唯一源，pigeon 可作为方法签名层，注册矩阵由自有生成器产出：声明 name、methods、engines、platforms。生成内容包括 Dart 常量与类型化 API、Java 的 ChannelNames、以及各平台 registerFushiChannels(engineKind)。不支持的平台在清单里声明，由生成的 Dart API 返回明确的 unsupported 结果，而不是在调用点 catch 吞掉。第三方插件的 MissingPluginException 兜底单独保留。先迁 FushiChannels、window、ime、tts 这些已出过注册 bug 的通道，迁完一个删一个对应守卫。

## diag-log-copy-paste

**诊断日志设施逐个复制：五个类各写一遍「定位原生证据文件→读后清→折进错误日志」，启动路径上全是主 isolate 同步 IO，反馈汇总也是手工拼接**

- 类型：缺单一登记源；规模 M；价值 medium；不改外部行为
- 核验：部分成立

证据：

- fushi/lib/src/utils/misc/code_integrity_log.dart:36-71 与 fushi/lib/src/utils/misc/wgc_capture_log.dart:41-79 的 readAndClear（existsSync→readAsStringSync→writeAsStringSync('')）和 foldIntoErrorLog 逐行同构；hang_watchdog_log.dart:55-92、present_watchdog.dart:113 是同一份代码的第三、第四个副本
- fushi/lib/main.dart:800-813 启动时逐个列出 WgcCaptureLog / PresentStallLog / HangWatchdogLog / CodeIntegrityLog / PreviousExitLog 的 foldIntoErrorLog，新增一种证据就要改 main.dart，并复制一个类
- fushi/lib/src/lookup/global_lookup_log.dart:57-83 每次 glog（全仓 154 处调用）都做同步 writeAsStringSync(append)，每 N 行再做 existsSync/lengthSync/renameSync，自己实现了一套轮转，没用 capped_log_file.dart 的 CappedLogFile（CappedLogFile 只被 video_diag_log 和 study_diag_log 两处使用）
- fushi/lib/src/feedback/feedback_diagnostics.dart:317-365 collectFeedbackLogText 手工拼 error / debug / glookup / video / dataLocation 各段；study_diag_log 和 storage_footprint_log 不在这里，各自另有导出入口（study_diag_export.dart）
- fushi/lib/src/diagnostics/previous_exit_log.dart 共 2531 行，Android ApplicationExitInfo（:758-1100）、Windows 崩溃摘要和事件日志（:1100-1460）、macOS .ips（:1461-1640）、iOS MetricKit（:1640-1720）、内存探针（:2039-2100）都堆在一个文件里

机制：每次排查一类原生崩溃 / 卡死（BUG-209、BUG-772、BUG-2588、BUG-5484……）都照抄上一个 *Log 类加一条证据通道，从来没有「诊断通道」这个抽象：路径解析、平台判定、轮转上限、读后清、归入错误还是诊断段、是否随反馈上传，每个类自己决定。

根本方案：新建 fushi/lib/src/diagnostics/diag_channels.dart，作为唯一登记表 `List<DiagChannel>`。每项声明：id、平台集合、文件定位（相对 LOCALAPPDATA / app 支持目录）、写入方（native / dart）、容量策略（CappedLogFile）、启动时是否读后清并折入、折入的严重度（error / diagnostic）、反馈节名，以及受哪个用户开关管。①所有 Dart 写入通道统一走一个后台 isolate 的 `DiagSink`（批量追加 + CappedLogFile 轮转），glog、VideoDiagLog、StudyDiagLog 只是它的 id；②启动时用一次 `foldNativeEvidence()` 在后台 isolate 遍历登记表，取代 main.dart 里那 5 行；③collectFeedbackLogText 改成遍历登记表异步生成各节（gzip 也在后台 isolate 做）；④previous_exit_log.dart 按平台拆成 `ExitEvidenceSource` 实现（android / windows / mac / ios），由同一登记表驱动。删除：WgcCaptureLog、CodeIntegrityLog、HangWatchdogLog、PresentStallLog 的 readAndClear/foldIntoErrorLog 副本、global_lookup_log.dart 的自写轮转、feedback_diagnostics 中的手工拼段。以后新增一种原生证据只在登记表加一项。

要动：fushi/lib/main.dart；fushi/lib/src/utils/misc/code_integrity_log.dart；fushi/lib/src/utils/misc/wgc_capture_log.dart；fushi/lib/src/utils/misc/hang_watchdog_log.dart；fushi/lib/src/utils/misc/present_watchdog.dart；fushi/lib/src/lookup/global_lookup_log.dart；fushi/lib/src/feedback/feedback_diagnostics.dart；fushi/lib/src/diagnostics/previous_exit_log.dart；fushi/lib/src/utils/misc/error_log_service.dart

核验说明：已验证：code_integrity_log.dart:36-71 与 wgc_capture_log.dart:41-79 的 readAndClear 和 foldIntoErrorLog 逐行同构，main.dart:798-813 逐个列出 5 个 fold 调用。差异本来就是一个参数：WGC 走 logDiagnostic，CodeIntegrity 走 log，登记表抽象是合理的。但 global_lookup_log.dart:8-19 的文件头写明了有意的约束：Dart glog 与 runner 的 NativeGlog 共写同一个文件，所以必须每行打开、追加、关闭，不能长期持有句柄，否则会覆盖原生写入的行；自写轮转也是为了配合这一点。不能把它简单归为没复用 CappedLogFile 的重复。启动时的同步 IO 只是几个小文件，代价有限。

方案风险：把 glog 改成后台 isolate 批量追加，会打乱它和原生 NativeGlog 在同一文件里的行序。而批量缓冲在进程崩溃时会丢掉最后几行，恰恰是查词 / hook 崩溃取证最需要的那几行。是否套用 CappedLogFile，要先确认它不长期持有句柄、换名时能容忍原生侧正开着文件。previous_exit_log 按平台拆分没问题，但 Android ApplicationExitInfo 等数据来自通道，拆分时不能改变 wire 格式。

修正后的方案（以此为准）：保留 DiagChannel 登记表，用于原生证据文件的统一定位、读后清、按 severity 折入、反馈分节，取代 main.dart 里那 5 行和那 4 个副本，并让 collectFeedbackLogText 遍历登记表（把 study_diag 和 storage_footprint 也纳入）。glog 保持同步、每行打开追加，只把轮转逻辑抽成和原生共写兼容的共享函数，不进后台批量 sink。

## app-worker-wire-contract-dup

**app 与 Worker 的线协议常量两边各写一份，靠 JS 测试用正则去读 Dart 源码比对**

- 类型：缺单一登记源；规模 S；价值 medium；不改外部行为
- 核验：成立

证据：

- packages/fushi_engine/lib/feedback/feedback_models.dart:23-48 FeedbackLimits（titleMax/bodyMax/screenshots/logMaxBytes/attachWindow/videoMaxBytes……），注释写着「必须与服务端 FEEDBACK_LIMITS 同值」
- services/leaderboard/src/feedback.js:104-125 FEEDBACK_LIMITS 同一组值又写一遍；feedback_guard.js 的 IMAGE_MAX_SIDE / IMAGE_MAX_PIXELS 对应 Dart 的 screenshotMaxSide / screenshotMaxPixels
- services/leaderboard/test/feedback_video.test.js:103 与 feedback_files.test.js:163 用 readFileSync 读 feedback_models.dart 源码，再按字面量正则核对，守卫的是本该由单一来源保证的不变量

机制：Worker（JS）和 app（Dart）之间没有共享的契约文件，每加一个上限 / 错误码就要两边手写；同值不变量只能靠「JS 测试解析 Dart 源码文本」来兜，一改格式守卫就失效或误报。

根本方案：新建 services/leaderboard/contract/feedback_limits.json（以后错误码表、排行 metric/window 枚举也放这里）作为唯一来源：Worker 直接 `import limits from '../contract/feedback_limits.json'`，Dart 侧由 tool 生成 packages/fushi_engine/lib/feedback/feedback_limits.g.dart（生成文件入库，CI 检查生成结果和 JSON 一致）。删除 feedback.js 和 feedback_models.dart 中手写的那组常量，以及两条读 Dart 源码的 JS 测试。以后新增一个上限只改 JSON。

要动：services/leaderboard/src/feedback.js；services/leaderboard/src/feedback_guard.js；packages/fushi_engine/lib/feedback/feedback_models.dart；services/leaderboard/test/feedback_video.test.js；services/leaderboard/test/feedback_files.test.js

核验说明：已验证：feedback.js:104-125 的 FEEDBACK_LIMITS 与 feedback_models.dart 的 FeedbackLimits 是同一组值；test/feedback_files.test.js:163 和 feedback_video.test.js:103 用 readFileSync 读 Dart 源码比对。需要注意的是，FEEDBACK_LIMITS 里混有大量只属于服务端的项（submitPerIpHour、devNoteMax、aiSummaryMax、attachmentRetentionMs、messageDeletesPerFeedbackHour 等），JSON 只应收 app 也要知道的那部分。

方案风险：JSON 若把服务端独有的限额也放进去，生成到 Dart 后会把服务端策略暴露给客户端，以后改这些值也会被迫跟着发 app 版本。生成器放在哪里要定好：fushi/tool/ 或仓库根 tool/，并接入现有的 CI 生成一致性检查。wrangler（esbuild）支持 import JSON，这部分可行。

修正后的方案（以此为准）：contract/feedback_limits.json 只收双方共享的上限（标题 / 正文 / 截图数与尺寸 / 日志 / 视频 / 补传窗口）。服务端独有的限额留在 feedback.js，用展开运算合并（...shared, submitPerIpHour…）。Dart 的生成文件入库，由 CI 比对 JSON 和生成结果；删掉那两条正则读 Dart 源码的测试。

## worker-route-table

**Worker 路由是 if 链，限流、缓存、鉴权的选择和权限表分散在各模块，Bearer 解析和角色判据重复手写**

- 类型：守卫代替结构；规模 M；价值 medium；不改外部行为
- 核验：部分成立

证据：

- services/leaderboard/src/worker.js:190-330 一条 if 链：每个分支各自选 READ_LIMITER / AUTH_LIMITER / ACCOUNT_LIMITER，各自决定是否 cachedRead、是否 authenticate；文件头 :7-48 的 API 表是手写注释，和代码之间没有约束
- services/leaderboard/src/ai_usage.js:40-46 requireUploadToken 与 feedback.js:1505-1510 requireCi 逐行相同（取 env token、截 'Bearer '、timingSafeEqual）；api_keys.js:93 和 srs_donations.js:106 又各写一条 Bearer 正则
- devconsole.js:296-317 TRIAGE_ROUTES 是独立于真实路由的一张正则权限表，与 routeDevConsole 的路由手工对齐；角色判据 `role === 'dev'` 分别写在 devconsole.js:315、feedback.js:454/1079/1309、decisions_api.js:39

机制：每个子模块各自提供 isXPath + routeX，并自带一套凭据解析；worker.js 只负责按顺序调用，再在调用前后插限流。限流档、缓存、凭据类型、允许的角色是每条路由的属性，却分散在三个地方，新增路由要改 worker.js、子模块和权限表三处，漏一处就是越权或绕过限流。

根本方案：新建 src/routes.js，作为唯一的声明式路由表：`{method, pattern, limiter: 'read'|'auth'|'account', cache: 'edge'|'none', auth: 'none'|'signature'|'signatureOptional'|{bearer:'ci'|'usage'|'decisionKey'|'feedbackKey'|'donor'}|'basicAdmin'|'devSession', roles?: ['dev','triage'], handler}`。worker.js 退化成一个统一分发器（匹配 → 限流 → 鉴权 → 角色检查 → 缓存包装 → handler）。src/credentials.js 实现所有凭据类型（一份 bearer() 解析和 envToken() 校验），roles.js 定义 dev/triage 能力。删除：requireCi / requireUploadToken / srs_donations 的 Bearer 解析副本、TRIAGE_ROUTES（改成路由表里的 roles 字段）、各模块的 isXPath，以及 worker.js 文件头的手写 API 表（改为从路由表生成文档）。以后新增接口只在 routes.js 加一行；测试遍历路由表，断言每条都声明了 limiter 和 auth。

要动：services/leaderboard/src/worker.js；services/leaderboard/src/feedback.js；services/leaderboard/src/devconsole.js；services/leaderboard/src/ai_usage.js；services/leaderboard/src/api_keys.js；services/leaderboard/src/srs_donations.js；services/leaderboard/src/decisions_api.js；services/leaderboard/src/feedback_api.js

核验说明：已验证：ai_usage.js:39-46 的 requireUploadToken 与 feedback.js:1505-1510 的 requireCi 逐行相同，api_keys.js:93 另写了一条 Bearer 正则，devconsole.js:296-317 的 TRIAGE_ROUTES 是一张独立的正则权限表。worker.js 共 430 行，审计说是 if 链，我没有逐行核对 :190-330，限流各分支自选这一点也未逐条验证。凭据重复和 triage 表与路由分离这两点成立。

方案风险：不同凭据的失败语义不一样，统一分发器必须原样保留：CI / usage 在没配 token 时返回 404（表示接口不存在），api_keys 统一返回 401 badCode（防止探测），decision key 返回 401 decision_key_required，客户端和 CI 脚本依赖这些错误码，属于 wire 契约。devconsole 是 HTML 加 cookie 会话加 CSRF 的形态，用 roles 字段替代 TRIAGE_ROUTES 时，还要保留「签拍板台密钥的请求在路由里再拒」这种 handler 内的二次判定。路由表还要能表达前缀匹配和流式上传（srs_donations 的 PUT 直接流式写 R2）。

修正后的方案（以此为准）：按原方案建 routes.js 和 credentials.js，凭据类型声明各自的「未配置 / 无效」错误码和状态码，由测试遍历路由表，断言每条都声明了 limiter、auth、错误码策略。TRIAGE_ROUTES 改成路由表里的 roles 字段，handler 内的细粒度拒绝保留。

## ai-wire-protocol-switch-scatter

**ai_chat_client.dart 按 AiWireProtocol 分散写了十来处 switch，三家协议的差异没有收进各自的适配器**

- 类型：上帝对象；规模 M；价值 low；不改外部行为
- 核验：成立

证据：

- packages/fushi_engine/lib/ai/ai_chat_client.dart 共 2001 行；协议 switch 分布在 :368（用量解析）、:711（取文本）、:767（请求 uri/payload）、:825（顶层键）、:882（模型列表 uri）、:1124（另一种请求形状）、:1157（回复键）、:1566（停止原因）、:1697（工具调用），另有 :63、:927 两处 `!= openAiCompatible` 特判
- docs/bugs 里 8 份记录点名 ai_chat_client，其中 BUG-3995 / BUG-4731 / BUG-5468 / BUG-5469 都是某个协议在某个环节（截断重试、模型元数据、推理档、输出上限）处理不一致

机制：协议是枚举，每个关注点（uri、payload、文本、用量、停止原因、工具调用、模型列表）在用到的地方就地 switch。给一个协议补一个能力时，要在大文件里逐处找对应分支，漏改的分支就成为「这家协议在 X 环节不对」的 bug。（AiFeature 的指派倒是用穷尽 switch，没有这个问题。）

根本方案：在 packages/fushi_engine/lib/ai/wire/ 建 `abstract interface class AiWireAdapter`（buildChatRequest / parseText / parseUsage / parseStopReason / parseToolCalls / modelsUri / supportsReasoning…），三家各一个文件实现，AiWireProtocol 只持有 `adapter` getter。AiChatClient 只保留传输、重试、限流和 key 轮换，不再出现任何 protocol switch。删除 ai_chat_client.dart 中所有按协议的分支。以后新增一家协议只加一个 adapter 文件和一个枚举值，接口方法由编译器强制实现。

要动：packages/fushi_engine/lib/ai/ai_chat_client.dart；packages/fushi_engine/lib/ai/ai_provider_config.dart

核验说明：已验证：ai_chat_client.dart 共 2001 行，在 :368、711、767、825、882、1124、1157、1566、1697 都有按 protocol 的 switch，:63、927 有 != openAiCompatible 的特判，与审计一致。这些 switch 表达式在 Dart 里是穷尽的，新增枚举值时编译器会报错；但同一协议在不同关注点上不一致（比如截断重试只给 openAi，见 :63）编译器发现不了，适配器接口的收益在这里。

方案风险：大体无。注意 :63、:927 是「只有 openAiCompatible 才支持某能力」的语义，在适配器里要做成显式的能力位（supportsX），不要默认实现成空操作，否则又会静默漏掉。

## 核验补充（审计漏掉的）

- 统计：sync_state.part.dart:66（packages/fushi_engine/lib/sync/local_library_host_service/）为了取 activity rows 调用整套 loadStatFacts，包括全部派生；library_progress_reset.dart:85、study_diag_export.dart:36、settings_schema_study_goals.dart:644 也都用 activityLimit:0 读全历史。审计列出的调用点不到实际的一半，统一入口方案必须覆盖这 20 多处。
- 统计：仓库里已有 packages/fushi_engine/benchmark/stat_facts_main_isolate_benchmark.dart，审计的性能结论没有用它量化，应以它的实测数据决定是否值得做 Rust 常驻聚合。
- 下载：分片规划实际有三份，update_checker_download.dart:647 的 planDownloadSegments、update_checker_race.dart:711 一带的调用，以及 fushi/lib/src/utils/misc/download_plan.dart:76-141 的 DownloadPlan（segmented_downloader 用）。审计只看到两份。
- 自更新：staging 与续传元数据是磁盘上的冻结格式，审计的 changesPersistenceOrWire=false 不对，合并下载引擎时需要读兼容或一次性迁移。
- 通道：fushi/lib 里 MissingPluginException 实际有 168 处（审计写 70），其中有平台缺失通道的有意兜底，也有第三方插件的兜底，需要分类处理，不能统一删除。
