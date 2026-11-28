# 架构审计：downloads-torrent

2026-11-28 只读审计 + 独立反驳核验的原始结论。总方案见 [../../specs/2026-11-28-architecture-redesign.md](../../specs/2026-11-28-architecture-redesign.md)。

## 现状

下载中心与 BT 现在是两套任务系统同时在跑。旧的一套是 app 侧的 JSON 计划：`AnimeDownloadPlanStore`、`AnimeDownloadService` 和 `AnimeDownloadSubscriptionService`，番剧对话框和旧订阅还在往里写新计划。新的一套是引擎侧的 Drift 持久管线：`VideoDownloadPipelineService`（6070 行）和 `VideoDownloadSubscriptionService`。这两套之间靠启动时每次都跑的 `VideoDownloadLegacyImporter` 衔接。后端统一在 `TorrentBackend` 接口后面，有 qB、内置引擎的 worker 代理、`fushi_host` 远程三种实现，外加 7 个可选能力接口和运行期能力位。状态在各层之间以 qB 词汇的字符串流转，由两套解码表分别解读。内置引擎的 resume 保留集合由 app 从 JSON 计划、任务表、远程租约三处手工拼出，服务端只拼后两处，还靠 null 哨兵加启动顺序注释防止 resume 被删光。观测全是轮询：管线每 5 秒一次，每个任务各自全量列一次种子；任务面板 3 秒、详情 2 秒、旧服务 3 到 20 秒、服务端维护 20 秒，各自独立去拉后端。app 和 fushi_server 各自手工装配管线：app 侧这部分在 17474 行的 `app_model` 里约 800 行，服务端在 `download_host`；管线构造参数里约 20 个可空钩子，服务端漏接了好几个（BUG-5160 就是这一类）。整理命名（`Season XX` / `SxxEyy`）在下载整理器、文件名整理、库在场判定和管线里各写了一份。

## dual-download-job-systems

**旧 JSON 计划系统与 Drift 持久管线并行存活，启动时的「一次性」迁移器每次都把新写的计划再导一遍**

- 类型：补丁叠补丁；规模 XL；价值 high；改持久化 / wire、用户可见
- 核验：成立

证据：

- fushi/lib/src/models/app_model.dart:9474-9541 先 _importLegacyVideoDownloads，再起 AnimeDownloadService(store: AnimeDownloadPlanStore) 和 AnimeDownloadSubscriptionService，然后才 _startVideoDownloadPipeline：两套状态机同进程常驻
- fushi/lib/src/pages/implementations/anime_download_dialog.dart:1247-1263 番剧对话框至今新建 AnimeDownloadPlan 并 store.save，再直接 backend.addTorrent，绕过管线
- fushi/lib/src/media/torrent/anime_download_subscription.dart:668-697 旧订阅 checkAll 仍按集生成 JSON 计划并直接 addTorrent
- fushi/lib/src/media/torrent/video_download_legacy_importer.dart:118-160 注释写的是 One-time importer，但扫描的就是 AnimeDownloadPlanStore 正在写的 baseDir/plans（anime_download_plan.dart:419-481），没有完成标记，每次启动都会把上次会话新写的计划导进 Drift 并归档
- fushi/lib/src/media/torrent/anime_download_service.dart:269-457 独立 Timer.periodic（20 秒，活跃时 3 秒），自己判完成、入库、字幕；docs/bugs 里有 20 个 bug 指向它

机制：schema v78 迁到 Drift 管线时只加了导入器，没有删旧的写入端：番剧对话框和旧订阅还在产出 JSON 计划。于是一条下载在本次会话由旧服务驱动，下次启动又被导入成管线任务，生命周期、完成判定、字幕、入库各有两份实现，而且内置引擎的维护 tick 也挂在旧服务的 onTick 上（BUG-5160 正是因此在服务端缺失）。

根本方案：删除整套 JSON 计划系统：anime_download_service.dart、anime_download_plan.dart、anime_download_subscription.dart、anime_download_importer.dart、anime_download_subtitle_resolver.dart，以及 app_model 中 _animeDownloadService / _animeDownloadPlanStore / _refreshAnimeDownloadPlanIds 相关装配和 ctl_anime_download_routes。番剧对话框改成构造 VideoDownloadEnqueueRequest 交给 pipeline.enqueue（边下边播用管线的 sequential 选项加 importNow 等价命令）；旧订阅并入 VideoDownloadSubscriptionService。Jimaku 字幕意图作为任务的字幕策略字段落库，由管线的字幕阶段消费。VideoDownloadLegacyImporter 只在库里没有「legacy_import_done」标记时运行，运行后写标记；保留到下个大版本后连同 legacy_import_* 目录处理一起删除。以后新增任何下载入口只能调用 pipeline.enqueue，这一点用守卫测试禁止 fushi/lib 中出现 TorrentBackend.addTorrent 直接调用（只允许管线和引擎包）。

要动：fushi/lib/src/media/torrent/anime_download_service.dart；fushi/lib/src/media/torrent/anime_download_plan.dart；fushi/lib/src/media/torrent/anime_download_subscription.dart；fushi/lib/src/media/torrent/video_download_legacy_importer.dart；fushi/lib/src/pages/implementations/anime_download_dialog.dart；fushi/lib/src/ops/ctl_anime_download_routes.dart；fushi/lib/src/models/app_model.dart；packages/fushi_engine/lib/media/video/download/video_download_pipeline_service.dart

核验说明：已验证。app_model.dart:9476 先调 _importLegacyVideoDownloads，9487 构造 AnimeDownloadService(store) 并 start，9525 构造 AnimeDownloadSubscriptionService 并 start，9551 才 _startVideoDownloadPipeline，两套服务同进程常驻。写 JSON 计划的入口至今都在：anime_download_dialog.dart:1247-1263 store.save 后在 1272 addTorrent；anime_download_subscription.dart:681 planStore.save 后在 697 addTorrent。video_download_legacy_importer.dart:136-137 扫的正是 baseDir/plans 和 subscriptions，入库后归档。效果是：本会话新写的计划由旧服务驱动，下次启动被导进 Drift 改由管线接手，同一条下载中途换了驱动方。另外审计漏了两个写入端：download_actions.dart:150-185（通用磁链推送：AnimeDownloadPlan + store.save + addTorrent + 调 animeDownloadService.tick），以及 anime_download_dialog.dart:2942 的 _retryPlan。

方案风险：(1) 漏掉了 download_actions.dart 的通用磁链推送和 dialog:2942 的重试路径，还有 browse_page.dart:1007 的 DownloadTaskSource.legacy 分流、media_collection_detail_page.dart:1890/1968、media_link_opener.dart:74 这几个对话框入口。(2) 「legacy_import_done 标记后不再运行」只有在所有写入端都删掉之后才安全；如果先加标记、后删写入端，旧入口在过渡期写的计划会永远没人导入。顺序必须是先删写入端、再加标记。(3) 计划里的 Jimaku 意图（jimakuEntryId / subtitlePending / subtitleAlignPending）要先确认管线的字幕阶段能消费，才能删 JimakuPlanSubtitleResolver；有声书 / 游戏这类 discoveryImporter 和 bookImporter 的入库语义也要对齐。这一点未验证。(4) 守卫写成「禁止 fushi/lib 里出现 addTorrent」时，要给 interconnect_torrent_engine_backend.dart（它是后端实现）留白名单。

修正后的方案（以此为准）：方向不变，执行顺序改为：① 列全所有 AnimeDownloadPlan 写入端（dialog 的新建与 _retryPlan、download_actions.pushGenericMagnet、旧订阅 checkAll），逐个改成 pipeline.enqueue，内容类型（书 / 有声书 / 游戏）和字幕意图先作为管线请求字段落库；② 旧写入端删干净后，导入器在库中写完成标记，标记之前仍每次启动都跑；③ 再删除 AnimeDownloadService / 旧订阅 / 计划存储以及 ctl_anime_download_routes；④ 加守卫：fushi/lib 中 addTorrent 只允许出现在后端实现文件里。

## resume-keepset-hand-union

**内置引擎 resume 保留集合由调用方手工拼集合差剪枝，app 和服务端拼法不同，靠 null 哨兵加启动顺序注释防止删光，每个 tick 还要全量重读**

- 类型：守卫代替结构；规模 L；价值 high；改持久化 / wire
- 核验：部分成立

证据：

- fushi/lib/src/models/app_model.dart:10176-10187 _refreshAnimeDownloadPlanIds = JSON 计划 loadAll（目录 walk + 逐个 JSON 解码）+ loadEmbeddedTorrentResumeIds + 租约 hashes，每个 tick 调一次（10885）
- packages/fushi_server/lib/src/download_host.dart:269-273 服务端 _embeddedKeepIds 只有任务行 + 租约两项，与 app 拼法不同
- packages/fushi_engine/lib/media/video/download/video_download_pipeline_service.dart:917-926 loadEmbeddedTorrentResumeIds 每次全量 getAllMediaSources + getVideoDownloadJobs
- fushi/lib/src/models/app_model.dart:9476-9485 写着「顺序不可调换」的启动注释，以及 8985-8991 的 null 哨兵说明：顺序一错就把用户所有 .resume 删光
- fushi/lib/src/models/app_model.dart:10189-10198 租约变更时还要同步把新租约并进集合，否则其间的周期快照会剪掉远程任务；data_root_migrator.dart:1796-1802 的 resume 目录派生要手工与 app_model 的 'anime_downloads' 保持一致（BUG-3541）

机制：剪枝语义是「resume 目录减去调用方给的保留集合」。保留集合没有单一所有者，每个持有种子的子系统（计划、任务、租约）都必须记得把自己并进去；漏一个、早到一次、空集合与未加载混淆，都会静默销毁续传数据。所以只能靠哨兵、顺序注释和同步补丁来防。

根本方案：把「谁持有这颗种子」做成显式的持久登记：在 Drift 加一张 torrent_retention(hash, owner_kind, owner_id) 表（owner_kind 取 job / peer_lease），或者由 EmbeddedTorrentHost 自己维护一份 retention 清单。任务入队、租约登记时 retain，任务删除、取消做种、租约撤销时 release；最后一个 owner release 时，在同一个命令里 removeTorrent 并删掉 .resume。剪枝改为只处理「无 owner 且已显式 release」的条目，不再做集合差，restoreFromResume 恢复目录里全部 resume。这样就删掉 _animeDownloadPlanIds 哨兵、_refreshAnimeDownloadPlanIds、_onPeerTorrentLeasesChanged 的并集补丁、download_host._embeddedKeepIds、loadEmbeddedTorrentResumeIds / legacyEmbeddedTorrentResumeIds，以及 dispose(keepIds:) / saveResumeSnapshot(keepIds) 的参数。resume 目录、下载根这类路径由引擎侧一个 DownloadDataLayout 常量派生，app、迁移器、存储统计都引用它，不再各写一遍字面量。以后新增一种持有者只需新增一个 owner_kind。

要动：packages/fushi_engine/lib/media/torrent/embedded_torrent_host.dart；packages/fushi_engine/lib/media/torrent/embedded_torrent_host_client.dart；packages/fushi_engine/lib/media/video/download/video_download_pipeline_service.dart；packages/fushi_server/lib/src/download_host.dart；fushi/lib/src/models/app_model.dart；fushi/lib/src/storage/data_root_migrator.dart；fushi/lib/src/storage/download_layout.dart；packages/fushi_core (新表)

核验说明：现象已验证：app_model.dart:10176-10187 每次调用都 loadAll JSON 计划，再加任务行和租约（10832/10846/10885 都会调用）；10189-10198 是租约变更时的并集补丁；embedded_torrent_host.dart:356-363 是 null 哨兵；pipeline:917-926 每次全量 getAllMediaSources + getVideoDownloadJobs。但「app 和服务端拼法不同」本身不是缺陷：服务端没有 JSON 计划，download_host.dart:269-273 少拼一项是正确的。真正的病根是 JSON 计划系统还活着（见上一条），一旦删掉它，两端的拼法自然一致。

方案风险：(1) 方案里「restoreFromResume 恢复目录里全部 resume」与 BUG-1053 的边界冲突：app_model.dart:9541-9548 要求只有存在「属于现存任务」的 resume 时才建 session（不绑端口、不起 DHT）。崩溃留下的孤儿 resume，或者 owner 已删但 .resume 还没删掉的文件，会被重新拉起，相当于复活用户已删除的种子。(2) 新表上线需要回填：现有用户的 .resume 没有任何 owner 行，首次升级要按当前的集合差结果回填 owner，否则不是全删就是全留。(3) 租约 owner 是远端设备发起的，撤销语义在 PeerTorrentLeaseStore 里，必须保证租约撤销和 retention 释放在同一个事务里完成。(4) 加新表要升 schema，属于持久化改动。

修正后的方案（以此为准）：先完成上一条（删 JSON 计划系统），这样保留集合只剩「任务行 + 租约」两个来源，两端的拼法自动统一。在此基础上由 EmbeddedTorrentHost 持有一份 retention 登记（Drift 表 torrent_retention(hash, owner_kind, owner_id)）：首次迁移时按当前集合差的结果回填；任务和租约的生命周期事件里同事务 retain / release；剪枝改成删除「无 owner」的 resume，restore 只恢复「有 owner」的条目，保持 BUG-1053 的边界。resume 目录路径收成一个引擎侧常量，app、迁移器（data_root_migrator.dart:1796-1802）、存储统计统一引用它。

## poll-fanout-full-list

**每个消费者各自轮询后端全量种子列表，管线每个任务各列一次，复杂度 O(任务数 × 种子数)**

- 类型：性能；规模 L；价值 high；不改外部行为
- 核验：部分成立

证据：

- packages/fushi_engine/lib/media/video/download/video_download_pipeline_service.dart:2351-2364 _findBackendTorrent 为了找一个 hash 调全量 _listBackendTorrentsForJobs（qB 是一次 /torrents/info HTTP，内置引擎是一次 worker isolate 往返的全量 status）
- packages/fushi_engine/lib/media/video/download/video_download_pipeline_service.dart:2491-2501 + 3076-3080 每 5 秒 drain 最多 8 个任务，每个 _observeDownload 各调一次 _findBackendTorrent
- fushi/lib/src/pages/implementations/video_download_jobs_panel.dart:1068,1120-1149 面板每 3 秒再走一遍 loadTaskSnapshots（按后端分组全量列，pipeline:2375-2417）
- fushi/lib/src/pages/implementations/torrent_detail_dialog.dart:102,171 详情每 2 秒轮询；anime_download_service.dart:405-420 旧服务 3 秒 / 20 秒；download_host.dart:372 服务端 20 秒维护

机制：后端抽象只提供拉取式的 listTorrents，没有共享的观测层。每个新功能（管线观测、面板指标、详情、旧服务、维护）都自建一个 Timer 去拉全量，同一时刻同一后端被并发重复读取。依据来自代码路径推断，未见实测记录；BUG-3577 记载过内置引擎在 UI isolate 上同步拉取导致卡死，说明这条路径代价不低。

根本方案：在 fushi_engine 引入 TorrentObservationHub：每个后端绑定（按 kind / profile / fingerprint 分）一个实例，持有唯一的轮询循环，发出 Stream<Map<hash, TorrentSnapshot>>，并提供同步的 latest 视图。节奏自适应：有订阅者或有活跃下载时快，否则慢。内置引擎由 worker isolate 根据 libtorrent alert 主动推送差量，不再响应全量拉取，符合「一条事件 / 快照 stream」的规定。管线的 _observeDownload 改为读 hub.latest[hash]，下一次 wake 由 hub 的状态变化事件触发，不再固定 5 秒；面板、详情、维护都订阅同一个 hub。这样删掉 _findBackendTorrent、loadTaskSnapshots 里的分组拉取，以及面板和详情的 Timer.periodic。以后新增一个观测方只需订阅 hub，并用守卫禁止 fushi/lib 里出现直接调用 listTorrents。

要动：packages/fushi_engine/lib/media/torrent/torrent_backend.dart；packages/fushi_engine/lib/media/torrent/embedded_torrent_worker.dart；packages/fushi_engine/lib/media/torrent/embedded_torrent_host_client.dart；packages/fushi_engine/lib/media/video/download/video_download_pipeline_service.dart；fushi/lib/src/pages/implementations/video_download_jobs_panel.dart；fushi/lib/src/pages/implementations/torrent_detail_dialog.dart；packages/fushi_server/lib/src/download_host.dart

核验说明：已验证：pipeline:2351-2364 的 _findBackendTorrent 为了找一个 hash 调全量 backend.listTorrents()，并在 3076 的 _observeDownload 中逐任务调用；_drain（2491）每轮最多处理 8 个任务。loadTaskSnapshots（2375-2417）已经按后端分组、每组只列一次，所以面板这条路径不是 O(任务数×种子数)，问题只出在管线观测这一处。量级来自代码推断，未见实测。

方案风险：(1) 「内置引擎由 worker isolate 根据 libtorrent alert 推送差量」很可能需要给 native/fushi_torrent 新增导出。按仓库规则，已有 C++ 模块只扩展、不改写，所以方案要写明只加 C ABI 导出、不重构 C++；要不要做应先评估收益。(2) qB 已有 /api/v2/sync/maindata 增量接口和 torrents/info?hashes= 过滤，方案没提。(3) 守卫「禁止 fushi/lib 直接调用 listTorrents」会误伤 interconnect 后端实现和 anime_download_dialog 的重试路径，后者要随第一条一起删掉。

修正后的方案（以此为准）：两步走。第一步低成本：TorrentBackend.listTorrents 增加 hashes 过滤（qB 走 ?hashes=，内置引擎在 worker 内过滤），并在 _drain 每轮按后端绑定只列一次，把结果分给本轮各任务。第二步再做 TorrentObservationHub：每个绑定一个轮询循环、自适应节奏，面板、详情、管线、维护都订阅它。只有实测证明轮询有代价时，才给内置引擎加推送式导出。

## app-server-download-runtime-fork

**app 与 fushi_server 各自手工装配下载运行时：约 20 个可空钩子，服务端漏接的部分静默降级；后端选择规则也写了四五份**

- 类型：app / 服务端各写一套；规模 XL；价值 high；用户可见
- 核验：部分成立

证据：

- fushi/lib/src/models/app_model.dart:9855-9910 app 传了 skipDownloadExtras、onBackendTaskAdded（resume checkpoint）、onDiscCollectionImported、onReleaseAudioImported、onReleaseCompanionsRelocated、updateFeed 等钩子
- packages/fushi_server/lib/src/download_host.dart:410-438 服务端一个都没传；pipeline:3163-3165 注释明说「没装配开关（服务端）= 从不跳过特典」，于是同一张 preferences 表里的 videoDownloadSkipExtras 在服务端无效（preferences_repository.dart:3984）
- docs/bugs/BUG-5160-server-torrent-upload-off-ignored.md:4 同类先例：上传策略、限速、维护 tick、resume 落盘只在 app 侧由 AnimeDownloadService.onTick 驱动，服务端从未生效
- fushi/lib/src/models/app_model.dart:10992-11014 _torrentBackendFor 在内置引擎不可用时静默退到 qB，而 9766-9785 _createExactTorrentBackend 返回 null；readyVideoDownloadBackend（9663）、_peerLendableTorrentConfig（10207）、服务端 _resolveEngine（download_host.dart:337-352）各有一套选择判据；服务端 _qbBackend（261-267）不带 tracker 订阅

机制：引擎只提供了 VideoDownloadPipelineService 这个零件，没有「下载运行时」这一层组合。管线的每个新能力都以可空钩子的形式加入，宿主不接也能编译通过，结果就是静默缺功能。维护 tick、保留集合、后端选择与构造也都留给宿主各写一份，于是 app 与服务端不断出现分叉 bug。

根本方案：在 fushi_engine 新建 DownloadRuntime（纯 Dart），统一组合后端解析、TorrentObservationHub、管线、订阅服务、内置引擎维护时钟（由 EmbeddedTorrentHost 自己持有 tick，不挂在任何服务的 onTick 上）和 retention。宿主只实现一个 DownloadRuntimeHost 端口接口，所有成员都必填：没有该能力的宿主必须显式返回 Unsupported 实现（例如服务端的 discArtwork: NoDiscArtwork），新增能力时两边都编译不过，不会再静默漏接。偏好类开关（skipExtras、字幕语言）由 runtime 直接读共享 preferences 表，不作为钩子传入。后端选择收进 engine 内一个纯函数 resolveTorrentBackend(config, capabilities) 加一个工厂（统一带 tracker 订阅），删掉 app 的 _torrentBackendFor / createTorrentBackend / _createExactTorrentBackend 三套，以及服务端的 _resolveEngine / _qbBackend。app_model 里约 800 行下载装配、download_host.dart 的 _startPipeline / _maintenanceTick / _embeddedKeepIds 都缩成构造 DownloadRuntime 并传入端口。

要动：packages/fushi_engine/lib/media/video/download/video_download_pipeline_service.dart；packages/fushi_engine/lib/media/torrent/embedded_torrent_host.dart；packages/fushi_server/lib/src/download_host.dart；fushi/lib/src/models/app_model.dart；packages/fushi_engine/lib/media/torrent/qb_torrent_backend.dart

核验说明：已验证：pipeline 构造器 1063-1084 有大量可空钩子；download_host.dart:410-438 没有传 skipDownloadExtras、onBackendTaskAdded、onDiscCollectionImported、onReleaseAudioImported、onReleaseCompanionsRelocated、updateFeed、videoCoversDirectory；pipeline:3163-3165 注释明说服务端从不跳过特典。后端选择在 download_host.dart:337-352 和 app 侧各写一套。证据有过时的部分：BUG-5160 已修复，修复方案把配置下发收成 EmbeddedTorrentHostClient.postConfig、把维护扫描收成 postMaintenanceSweep，服务端也起了 20 秒维护定时器（download_host.dart:368-373）。所以「维护 tick 只在 app 侧」已不成立，剩下的只是两端各持有一个定时器。

方案风险：(1) 「所有端口必填，没有能力的宿主显式返回 Unsupported」方向正确，但有几个钩子（onDiscCollectionImported 写原盘封面、updateFeed）依赖 app 的 UI / 库能力，服务端的 Unsupported 实现必须保证业务结果一致，不能悄悄丢掉入库。(2) 「runtime 直接读共享 preferences 表」要确认 fushi_engine 能访问 fushi_core 的偏好仓储，且不引入 package:fushi 依赖；engine 包禁止 import app。(3) 后端选择收成纯函数时，要保留 app 侧「内置引擎不可用时退到 qB」与「精确后端返回 null」这两种语义的差别：一个用于投递新任务，一个用于认领已有任务，不能合并成一个行为。

修正后的方案（以此为准）：DownloadRuntime + 必填端口的方向成立。修正：维护时钟直接由 EmbeddedTorrentHost 持有（BUG-5160 已经把扫描本身收成一处，剩下的只是定时器）；后端解析拆成 resolveForEnqueue 和 resolveExact 两个纯函数，并共用一个带 tracker 订阅的工厂；偏好开关通过 engine 内的偏好端口读取。

## stringly-torrent-state

**种子状态以 qB 词汇字符串在各层流转，有两套解码表互不一致，持久化回填路径造出解码表不认识的值**

- 类型：成类 bug；规模 M；价值 medium；改持久化 / wire、用户可见
- 核验：成立

证据：

- packages/fushi_engine/lib/media/torrent/torrent_backend.dart:163-186 isComplete / isFailure 用 _seedingStates / _errorStates 两个字符串集合判定，不含内置引擎的 seeding / finished，只能靠 progress 兜底
- packages/fushi_engine/lib/media/torrent/torrent_task_display.dart:47-93 另一张 switch 表把字符串折叠成 TorrentDisplayStatus，未知值归 unknown
- packages/fushi_engine/lib/media/torrent/embedded_torrent_backend.dart:603-609 内置引擎把暂停态合成为 qB 词 pausedDL / pausedUP 来迁就这两张表
- packages/fushi_engine/lib/media/video/download/video_download_pipeline_service.dart:404-413 _persistedTorrentState 返回 'completed' 和 job.stage（如 organize），两个值都不在显示表里；经 388 行进入 VideoDownloadJobDetails 后，torrent_detail_dialog.dart:522 显示为 unknown，即没有实时数据的已完成或整理中任务没有状态段（代码路径推断，未实测）

机制：抽象层没有把后端状态规范化，只透传原始字符串。每个消费方各写一张「哪些字符串算什么」的表，每个产生方又要猜消费方认哪些词。新后端或新路径（持久化回填、远程 wire）一产出新词，就静默落进 unknown 或判错完成态。

根本方案：在 TorrentSnapshot 增加必填字段 TorrentPhase phase（enum：metadata、checking、queued、downloading、stalled、paused、seeding、finished、moving、error），由各后端适配器在边界处唯一转换一次（QbTorrentBackend 映射 qB 词汇，内置引擎映射 state_label 加暂停 flag，remote wire 传 phase.name）。isComplete / isFailure / torrentDisplayStatusFor 都改为对 enum 做穷尽 switch，编译器保证覆盖完整；删掉两个字符串集合和合成 pausedDL / pausedUP 的补丁。_persistedTorrentState 改成由 lifecycle / stage 映射到 phase。原始 state 字符串只保留为诊断字段。远程 wire 新增 phase 键，旧对端缺这个键时在 wire 解码处用同一个 qB 映射函数兜底，这个映射全局只此一处。

要动：packages/fushi_engine/lib/media/torrent/torrent_backend.dart；packages/fushi_engine/lib/media/torrent/torrent_task_display.dart；packages/fushi_engine/lib/media/torrent/qb_torrent_backend.dart；packages/fushi_engine/lib/media/torrent/embedded_torrent_backend.dart；packages/fushi_engine/lib/media/torrent/remote_torrent_wire.dart；packages/fushi_engine/lib/media/video/download/video_download_pipeline_service.dart；fushi/lib/src/pages/implementations/torrent_detail_dialog.dart

核验说明：已验证。torrent_backend.dart:163-186 的 _seedingStates 不含内置引擎的 seeding / finished，只能靠 progress 兜底；torrent_task_display.dart:47-93 是另一张表，未知值归 unknown；embedded_torrent_backend.dart:603-609 合成 pausedDL / pausedUP 来迁就这两张表；pipeline:404-413 的 _persistedTorrentState 返回 'completed' 和 job.stage（如 organize），两者都不在显示表里，会落进 unknown。显示层后果是代码推断，未实测。

方案风险：远程 wire 必须继续发原始 state 字符串，旧对端只认 state。phase 只能作为新增键，解码时缺失才按 qB 映射兜底，方案已经写到这一点。TorrentSnapshot 加必填字段会波及所有测试 fake 的构造，属于机械改动。

## pipeline-god-object-special-branches

**VideoDownloadPipelineService 6070 行：原盘、并列多电影、电影改剧集等特例以 BUG 编号分支散布在各阶段，阶段内反复全表扫描**

- 类型：上帝对象；规模 XL；价值 high；不改外部行为
- 核验：部分成立

证据：

- packages/fushi_engine/lib/media/video/download/video_download_pipeline_service.dart 全文件 6070 行一个类；BUG-4245（原盘）的特例分支分布在 640、801、1392、3184、4126、4250、5021、5194、5217、5515、5549 等至少 11 处
- 同文件 4291、5084、5254、5803 是 BUG-2007（一个种子多部电影）分支，3420、3996 是 BUG-2760（电影任务改成剧集），2652、2737、2761 是 BUG-2755（来源失效改绑）
- 同文件 736、780、1566、3513、5333 在各个操作里全量 getVideoDownloadJobs() 再在 Dart 内过滤；1566-1575 对每个兄弟任务再逐个 getVideoDownloadJobFiles（N+1）
- docs/bugs 下有 58 份 bug 文档引用这个文件

机制：发布载荷的形态（散装视频、原盘、多部并列作品、合集包）没有建模成类型，只在各阶段里用 if 判断，于是每支持一种新形态，就要在入队、补齐、整理、字幕、入库、删除、在场判定各阶段各加一个分支。阶段之间也没有边界，查询按需临时写，只能全表扫描。

根本方案：按阶段拆成独立处理器：EnqueueStage、MaterializeStage、DownloadObserveStage、OrganizeStage、SubtitleStage、ImportStage、CleanupStage，由一张 stage 到 handler 的登记表驱动；VideoDownloadPipelineService 只保留租约、调度和登记表。发布形态建成 sealed ReleasePayload（LooseVideos / DiscRelease / SiblingWorks / SeriesPack），由 organize 阶段产出，后续阶段对它做穷尽 switch，原盘逻辑集中在 DiscRelease 一个类里，不再散在 11 处。全表扫描改成 fushi_core 里的定向查询（按 sourceId、按 seriesKey、按 torrentHash，并配索引），文件行批量 getVideoDownloadJobFilesForJobs(ids)。以后新增一种发布形态只加一个 ReleasePayload 子类，编译器会指出所有需要处理的阶段。

要动：packages/fushi_engine/lib/media/video/download/video_download_pipeline_service.dart；packages/fushi_engine/lib/media/video/download/video_download_organizer.dart；packages/fushi_core/lib/src/database/database_video_domain.part.dart

核验说明：已验证：文件共 6070 行；BUG-4245 出现 13 处、BUG-2007 出现 4 处；getVideoDownloadJobs() 全量扫描出现在 736、780、923、1566、2152、3513、5333。但 1566-1575 所谓的 N+1 只对 fingerprint、provider、hash 都相同的兄弟任务才逐个查文件行，实际 N 很小，不是性能热点。拆成多个阶段处理器的方案本身合理。

方案风险：(1) sealed ReleasePayload 由 organize 阶段产出，但 enqueue / materialize 阶段在整理之前就需要按形态分支（例如原盘在下载前的文件选择和特典跳过），payload 不能只在 organize 阶段才出现，必须在 materialize 拿到元数据后就产出并落库。这样会新增持久列，方案标 changesPersistenceOrWire=false 不准确。(2) 新增索引和定向查询需要升 schema。

修正后的方案（以此为准）：拆阶段的方向保留，修正两点：ReleasePayload 在 materialize（元数据到齐）时产出并持久化，后续阶段读取；定向查询配套 schema 迁移加索引，按 fingerprint / torrentHash / targetSourceId 查。

## backend-capability-double-layer

**后端能力用 7 个可选接口加 is 探测表达，所有实现都实现了全部接口，又叠了一层运行期能力位，两层判据要同时检查**

- 类型：守卫代替结构；规模 M；价值 medium；改持久化 / wire
- 核验：部分成立

证据：

- packages/fushi_engine/lib/media/torrent/torrent_backend.dart:44-68,190-210,318-355 共 TorrentMetainfoBackend、TorrentPausedMetainfoBackend、TorrentTrackerMutationBackend、TorrentRemovalBackend、TorrentPauseBackend、TorrentDetailBackend、TorrentBulkFilePriorityBackend 7 个可选接口
- packages/fushi_engine/lib/media/torrent/qb_torrent_backend.dart:8-14、embedded_torrent_backend.dart:23-29、embedded_torrent_host_client.dart:278-284（以及 interconnect_torrent_engine_backend.dart）都实现了同一整组接口
- torrent_backend.dart:198-206 注释要求「类型探测过了也要看 pauseControlAvailable 这一位，否则按钮点了永远失败」；pipeline:3171 写成 `backend is! TorrentDetailBackend || !backend.detailAvailable`，download_host.dart:256-258 也是同样的双判
- packages/fushi_engine/lib/media/torrent/remote_torrent_wire.dart:107-117 torrentEngineFeaturesOf 用 is 推导 wire 能力，而所有后端的 is 恒为真，导致真实能力（DLL 符号缺失、旧 qB）没有反映在 wire 上（代码推断）

机制：能力实际是运行期事实（DLL 版本、qB 版本、远端特性），却用静态类型来表达，于是又补了运行期 bool。调用方必须记得两层都查，漏查任何一层就是「按钮永远失败」这类 bug。

根本方案：TorrentBackend 只保留一个接口，所有方法都在上面，并新增 `TorrentBackendCapabilities get capabilities`（不可变值对象，Set<TorrentEngineFeature>），由后端从 DLL 符号探测、qB 版本探测或远端 features 填充。不支持的方法返回结构化的 Unsupported 结果，不靠抛异常。删掉 7 个可选接口、pauseControlAvailable / detailAvailable，torrentEngineFeaturesOf 直接序列化 capabilities。消费方统一写 `backend.capabilities.has(feature)`，并用守卫禁止对 Torrent*Backend 做 is 探测。以后新增一项能力只需在 enum 里加一个值，再由各后端填写。

要动：packages/fushi_engine/lib/media/torrent/torrent_backend.dart；packages/fushi_engine/lib/media/torrent/qb_torrent_backend.dart；packages/fushi_engine/lib/media/torrent/embedded_torrent_backend.dart；packages/fushi_engine/lib/media/torrent/embedded_torrent_host_client.dart；packages/fushi_engine/lib/media/torrent/remote_torrent_wire.dart；fushi/lib/src/sync/interconnect_torrent_engine_backend.dart；fushi/lib/src/pages/implementations/torrent_detail_dialog.dart；packages/fushi_server/lib/src/download_host.dart

核验说明：双层判据属实：pipeline:1783、1841、1950、2118、2801、3171 和 download_host.dart:257-258 都是 is 探测加运行期能力位一起判。但「真实能力没有反映在 wire 上」只说对一半：remote_torrent_wire.dart:37-38、53-54、87-88 已经单独传了 pauseControlAvailable 和 detailAvailable，DLL 过旧导致的暂停 / 详情缺失是会上 wire 的；只有 metainfo、trackers、bulkPriority 等项按 is 推导，恒为真。另外 torrent_backend.dart:190-192 的注释写明，拆成可选接口是有意设计，为的是让只读 fake 不必伪造支持。

方案风险：(1) wire 兼容：旧对端只认 features 集合加 pauseControlAvailable / detailAvailable 这两个键，新版本必须继续发这几个键。(2) 「不支持的方法返回 Unsupported 结果、不抛异常」会改变所有 fake 和调用方的返回类型，改动面比标的 M 大。

修正后的方案（以此为准）：保留统一的 capabilities 值对象，但不必删掉全部可选接口：TorrentBackend 增加 capabilities，消费方只查 capabilities，is 探测只留给测试 fake。wire 上的 features 由 capabilities 序列化，同时继续发 pauseControlAvailable / detailAvailable 以兼容旧对端。

## organize-naming-duplicated

**整理与重命名的命名规则（Season XX、SxxEyy、作品目录、新旧替身字符）在下载整理器、文件名整理、库在场判定和管线里各写一份**

- 类型：缺单一登记源；规模 S；价值 medium；不改外部行为
- 核验：部分成立

证据：

- packages/fushi_engine/lib/media/video/download/video_download_organizer.dart:653-658 直接拼 'Season $season' 和 '$displayRoot - S${season}E$episode'
- packages/fushi_engine/lib/media/video/organize/video_filename_organize.dart:79-81,102 另有 canonicalVideoSeasonDirectoryName 和一份 SxxEyy 拼接，注释写着「与下载整理器同一形态」，靠人工对齐
- packages/fushi_engine/lib/media/video/download/video_library_presence.dart:21-22,60 在场判定又拼一份 S..E.. 前缀；video_download_pipeline_service.dart:5994-5996 通知用的 _episodeLabel 再拼一份
- video_download_organizer.dart:46-75 新旧非法字符替身两套规则（legacyUnderscoreNames），要逐条任务判断沿用哪套

机制：规范库布局没有单一模块，下载、库整理、在场判定各自实现，一致性只靠注释约定。改动一处（例如特典季、多季、替身字符），另外几处就会分叉，造成同一作品拆进两个目录，或在场判定匹配不上。

根本方案：在 fushi_engine/media/video/ 下建 video_library_naming.dart 作为唯一真相源，提供 seasonDirectoryName、episodeToken(SxxEyy)、episodeFileName、workDirectoryName(title, year, {legacy})、parseEpisodeToken。下载整理器、文件名整理、在场判定、管线标签全部改用它，删掉各处的 padLeft 拼接；canonicalVideoSeasonDirectoryName 移入这个模块。再加一个往返性质测试：parse(format(x)) == x，同时覆盖新旧两种替身规则。以后改命名规则只改这一个文件。

要动：packages/fushi_engine/lib/media/video/download/video_download_organizer.dart；packages/fushi_engine/lib/media/video/organize/video_filename_organize.dart；packages/fushi_engine/lib/media/video/download/video_library_presence.dart；packages/fushi_engine/lib/media/video/download/video_download_pipeline_service.dart

核验说明：已验证：video_download_organizer.dart:653-658 手写 'Season $season' 和 S..E..；video_filename_organize.dart:79-81 的 canonicalVideoSeasonDirectoryName 注释写着「与下载整理器同一形态」，靠人工对齐，而下载整理器没有引用它（全仓只有 organize 和 organize_service 两处引用）。但 video_library_presence.dart:21-22 的 videoEpisodeKey 不是文件命名规则，而是订阅条目 logicalItemKey 和任务文件判重用的持久键，不应和磁盘命名规则绑在一个模块里联动。

方案风险：videoEpisodeKey 是持久化键，属于冻结格式，不能因为改了磁盘命名规则而跟着变。新旧替身字符规则（legacyUnderscoreNames）决定已有用户的磁盘目录名，统一后也必须逐字节兼容旧目录。

修正后的方案（以此为准）：建 video_library_naming.dart，只统一磁盘布局（季目录名、SxxEyy 文件名、作品目录名及新旧替身字符规则），下载整理器、文件名整理、管线通知标签都改为引用它。videoEpisodeKey 作为冻结的持久键单独保留，可以复用同一个补零 helper，但要注释说明格式冻结。加往返测试，并覆盖已有目录名逐字节一致。

## 核验补充（审计漏掉的）

- fushi/lib/src/pages/implementations/download_actions.dart:150-185：通用磁链推送（发现页书、有声书、游戏等 contentKind）也在新建 AnimeDownloadPlan + store.save + addTorrent，并调 animeDownloadService.tick。这类非视频下载完全不经过 Drift 管线，删除 JSON 计划系统时最容易漏掉，审计没有列出
- fushi/lib/src/pages/implementations/anime_download_dialog.dart:2925-2950：_retryPlan 直接 addTorrent，失败后又调 listTorrents 自行判断，这是旧系统的另一条手写状态路径
- 迁移语义缺口（推测，未验证）：在旧服务驱动下已进入半程的计划（subtitlePending / subtitleAlignPending、discovery contentKind）下次启动被 VideoDownloadLegacyImporter 导入后，管线是否保留 Jimaku 字幕意图和非视频入库语义，需要逐字段核对 _importPlanFile；如果丢失，就是每次重启都可能发生的静默降级
- fushi/lib/src/models/app_model.dart:9541-9548 与 BUG-1053 的边界（只有存在属于现存任务的 resume 才建 session）依赖同一份保留集合，任何 retention 重构都必须保住这个边界，审计的根本方案没有考虑到
