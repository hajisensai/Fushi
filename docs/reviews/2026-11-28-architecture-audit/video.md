# 架构审计：video

2026-11-28 只读审计 + 独立反驳核验的原始结论。总方案见 [../../specs/2026-11-28-architecture-redesign.md](../../specs/2026-11-28-architecture-redesign.md)。

## 现状

播放页 `VideoFushiPage` 一共约 2.8 万行，几乎所有逻辑都压在一个 State 上：`_VideoFushiPageState` 本身在 video_fushi_page.dart:1708-15080，另外 36 个 part 文件都写成 `extension … on _VideoFushiPageState`，同读同写这一个 State 的私有字段。dispose 一处就 210 行（8425-8634）；fushi/test 下有 200 个测试文件靠读这个页面的源码字符串当守卫。本地、互联/媒体服务器远端、网页档、原盘导航、源回看五种后端，在同一个类里用 `_isRemote`(89 处)、`_webMode`(41)、`_discMenu`(49)、`isBlurayNavigationSession`(25) 来回分支，每种后端各写一套起播、续播、字幕挂载和进度落库。换集靠手写代际号判过期：`_episodeLoadSeq` 有 97 处比较，另有 16 个独立的 Seq/Generation 计数器，换集时逐个字段手动复位。`VideoPlayerController`（7616 行）每 125ms 轮询一次 media_kit 位置，「seek 落地」叠了四套靠拍数配额的启发式守卫；起因是 media_kit 1.2.6 不暴露 mpv 的 `playback-restart` 事件。字幕选择分主字幕、副字幕两套，再乘上各后端，函数成对复制；持久化值是带前缀的字符串（`embedded:` / `off:` / `hostsidecar:` / 绝对路径），16 个文件里约 90 处靠嗅前缀判断。观看进度同一件事落在 VideoBooks 行、`video_remote_position_*` / `_at_` 偏好镜像、`video_duration_ms_` 偏好、观看覆盖偏好四处，4 条写入路径的门槛各不相同。视频库页 `home_video_page.dart`（13847 行）在页面 State 里自己拼整个库的投影：订阅 6 条表监听，各带一套防抖和「后台过期」标记；一次刷新要整表读两遍 video_books 外加约 8 张表；封面回填这种后台维护也挂在页面上跑。fushi_engine 侧（字幕管线、刮削、仓库）本身结构尚可，问题主要在 app 层装配过重，以及多个真相源之间相互镜像。刮削子域（6453 行的 coordinator）这次没有深读，不在下面的结论里。

## video-progress-single-store

**观看进度写在 4 处、由 4 条写入路径维护，每种后端各自读写续播点：续播丢失 / 回写旧进度成了反复出现的一类 bug**

- 类型：缺单一登记源；规模 L；价值 high；改持久化 / wire
- 核验：成立

证据：

- fushi/lib/src/pages/implementations/video_fushi_page.dart:8172-8189 本地 `_persistLibraryPosition`：每秒一次 `repo.updatePosition` 加两次 `setPref`（`videoRemotePositionEpisodePrefKey` / `...AtPrefKey`），再加 `_persistKnownDuration` 写 `video_duration_ms_<uid>`，共 3~4 次互不相关的 DB 写，没有门槛
- fushi/lib/src/pages/implementations/video_fushi_page.dart:6413-6466 远端 `_persistRemotePosition`：另一套口径，<5000ms 不写（BUG-996），直播判定，合集用 keyUid 写行
- fushi/lib/src/pages/implementations/web_video_fushi_page.dart:1147-1164 网页视频页又一份 `_persistPosition`：门槛 `kWebVideoMinPersistPositionMs`，写入顺序是先 prefs 后行；video_fushi/episode.part.dart:324 页内网页档另走 `_persistWebPosition`
- fushi/lib/src/media/video/video_player_controller.dart:5857-5869 / 5884-5910 / 7601-7615 控制器里 tick、flushPosition、`_forceSavePositionSync` 三个写入点，各自重复判断 `mediaOpened` 和 `_isRestoringPast`
- packages/fushi_engine/lib/media/video/video_book_repository.dart:796-811 注释写明：全量同步时位置取行、时间戳取 `_at_` 偏好；清除进度必须两处一起改，否则会被同步灌回
- docs/bugs/BUG-5501-web-video-no-resume-position.md：网页档只写不读续播点；BUG-4304：开播读偏好内存缓存，sweep 却只写库；BUG-4430：host 清单和位置端点对同一断点算出不同的戳；BUG-1731：host 只写偏好不写行；BUG-996 / BUG-179 / BUG-2441：0 进度覆盖真实进度

机制：「这一集看到哪、什么时候看的、片长多少、看完没」没有单一的记录和写入口。位置在 VideoBooks 行，时间戳在偏好镜像，片长在每视频一个的偏好，看完状态在行和 `video_remote_completed_` 镜像。每种播放后端（本地 / 远端 / 网页页 / 页内网页档 / 原盘全部播放）各写一套写入与恢复逻辑，「哪些位置不算有效进度」的门槛也各写一份（无门槛 / 5s / kWebVideoMinPersistPositionMs / 恢复守护）。LWW 输入从不同的存储拼出来（行 + 偏好 + 清单），新增一种后端就要把读、写、门槛、镜像、同步各补一遍，漏一处就是一个新 bug。

根本方案：在 fushi_engine 新建 `media/video/progress/video_progress_store.dart`，类 `VideoProgressStore`。它持有唯一的不可变值类型 `VideoProgress{EpisodeKey key, int positionMs, int updatedAtMs, int? durationMs, int? completedAtMs}`，`EpisodeKey` 统一本地 uid、远端 (成员 id, 主机侧集号)、原盘 title 三种身份。只开三个入口：`record(key, pos, {source})`（内部合并成「每秒至多一次、每次一个事务」，有效进度门槛在这里只判一次：mediaOpened、恢复未落地、近起点、直播无时长）；`resumePoint(key, {remoteSnapshot})`（唯一的 LWW，host 清单、GET 端点、sweep 和客户端开播共用这一个函数）；`watch(keys)`（按 key 推送变化）。持久化方面，在 video_books 加 `position_updated_at`、`duration_ms` 两列（或建 `video_watch_progress` 表），取代 `video_remote_position_*` / `_at_*` / `video_duration_ms_*` 三组偏好镜像；冻结的旧键只在一次性迁移里读出写入新列，之后删除写入代码。删掉 video_fushi_page.dart 里的 `_persistLibraryPosition` / `_persistRemotePosition` / `_persistKnownDuration`、web_video_fushi_page.dart 的 `_persistPosition`、web_source.part 的 `_persistWebPosition`，以及控制器三个写入点里重复的守卫（控制器只上报「有效位置样本」）。fushi_server 的 host 端点和 sync_orchestrator 也改读这个 store。以后新增一种播放后端，只需提供一个 `EpisodeKey` 构造。守卫：`VideoProgress` 的构造函数私有，只有 store 能产出；DB 层的 `updateVideoBookPosition` 不再从 engine 导出，app 层就调不到旁路写入。

要动：packages/fushi_engine/lib/media/video/；packages/fushi_core/lib/src/database/database_video_domain.part.dart；fushi/lib/src/pages/implementations/video_fushi_page.dart；fushi/lib/src/pages/implementations/web_video_fushi_page.dart；fushi/lib/src/pages/implementations/video_fushi/web_source.part.dart；fushi/lib/src/media/video/video_player_controller.dart；packages/fushi_engine/lib/sync/local_library_host_service/videos.part.dart；fushi/lib/src/sync/

核验说明：已验证。本地 _persistLibraryPosition（video_fushi_page.dart:8172-8189）没有任何门槛，每秒一次 updatePosition 加 2 次 setPref 加 _persistKnownDuration。远端 _persistRemotePosition（6413-6466）有 5000ms 门槛和直播判定，并按 keyUid 写行。网页页 _persistPosition（web_video_fushi_page.dart:1147-1164）用 kWebVideoMinPersistPositionMs 门槛，先写 prefs 再写行。控制器 _maybeSavePosition / flushPosition（video_player_controller.dart:5857-5910）各自重复判断 mediaOpened 和 _isRestoringPast。video_book_repository.dart:796-811 的注释写明：同步时位置取行、时间戳取 `_at_` prefs，清除进度必须两处一起盖。多真相源属实，各后端的门槛口径不一也属实。

方案风险：1）`video_remote_position_*` / `_at_` 两组键是冻结的持久化名，而且旧版 peer 或 host 的 sync_orchestrator、互联 sweep 都直接读它们（`_syncVideoProgressLive`）。迁到新列以后，要么老版本互联对端读不到新进度，要么得长期双写。方案里「迁移后删写入代码」与跨版本互联兼容冲突，必须先确认 host wire 只走端点、不读对端 prefs。2）门槛是有意按后端区分的（远端 5s 是 BUG-996 的 LWW 防护，本地无门槛是为了允许真正回到片头），统一进 store 时要保留「按 source 取策略」，不能一刀切。3）漏了 `video_remote_completed_` 镜像（setWatched / clearWatchProgress）和 remote_video_resume.dart 的读侧（watchLocalRemoteVideoPositionsChanged、withLocalRemoteVideoPositions）。4）加列要走 fushi_core 的 schema 迁移和 drift 版本号。

修正后的方案（以此为准）：VideoProgressStore 照方案做，补三点。①record 带 `ProgressPolicy`（按后端和 source 决定最小有效位置、是否允许 0、是否直播），门槛逻辑只写一处，但策略不合并。②持久化：新增 video_books.position_updated_at / duration_ms 列，旧 prefs 键在兼容窗口内由 store 内部单点双写，等互联 wire 确认只走端点、老 host 版本下线后再删双写；completed 镜像一起收进来。③读侧把 remote_video_resume.dart 的前缀扫描和 sync_orchestrator 的「行 + `_at_`」拼装都改为调 store.resumePoint / snapshot。

## episode-session-lifecycle

**换集作用域靠 97 处 `_episodeLoadSeq` 手工比较和逐字段复位，作废的一程写到新一集上，同一机制已出过多次 bug**

- 类型：成类 bug；规模 L；价值 high；不改外部行为
- 核验：成立

证据：

- fushi/lib/src/pages/implementations/video_fushi_page.dart:5668 `final int seq = ++_episodeLoadSeq;` 之后逐个手动复位 `_remoteSubtitlePath`、`_remoteSidecarSubtitles`、`_youtubeVariants`、`_selectedYoutubeVariantIndex` 等十多个字段（5683-5705），每个 await 后再补 `if (seq != _episodeLoadSeq || !mounted) return;`
- grep 统计：`_episodeLoadSeq` 在 video_fushi_page.dart 出现 27 次、subtitle.part.dart 56 次、quality.part 6 次……合计 97 次；另有 `_remotePlaybackGeneration`(14)、`_danmakuLoadSeq`、`_openSubtitleGeneration`、`_clipExportGeneration`、`_primarySubtitleSelectSeq`、`_hlsDetectSeq`、`_themeSongLoadSeq` 等 16 个独立代际计数器
- fushi/lib/src/pages/implementations/video_fushi/subtitle.part.dart:4190-4210 与 4239-4250：各种 `_apply*PipelineSubtitleWhenDone` 的「仍是当前集」判据各写各的（seq+videoId+episodeIndex / seq+路径去角度）；web_source.part.dart:1651-1655 网页版只比 bookUid，不比 seq
- video_fushi_page.dart:4440 `_remotePositionKeyForIndex` 共 30 处调用，index、streamEpisodeIndex、keyUid 三种集身份混着传；fushi/test/pages/video_remote_episode_index_guard_test.dart:12-35 用正则扫描源码，钉住「client 调用只能传 streamEpisodeIndex」
- docs/bugs/BUG-4998（自动对轴结果写到换集后的视频）、BUG-4999（A 集晚到的失败盖住 B 集，`_applyLoad` 成功和失败分支都不看代际）、BUG-5105（`_recoverInterruptedStream` await 之后没再查代际）、BUG-3804（集序号传错，静默 404）

机制：「一集的播放会话」不是一个对象，它的状态散在页面 State 的几百个字段里。异步任务（取流、下字幕、抽能量、管线回调、缩略图、弹幕、主题曲）用 `mounted + seq` 手写过期判断，每加一个 await 就得记得补一行；换集时哪些字段属于「本集」，全凭作者记性逐个清。集身份有三种整数或元组表示，类型上没有区分，传错只能靠源码扫描守卫兜底。

根本方案：新建 `fushi/lib/src/media/video/session/video_episode_session.dart`：`VideoEpisodeSession` 持有本集的全部可变状态，包括字幕目录、远端旁挂、YouTube 画质档、导入字幕、弹幕、主题曲、自适应画质基线，以及值类型 `EpisodeIdentity{EpisodeKey progressKey, int hostEpisodeIndex, String? localPath}`。会话自带 `CancellationScope`，提供 `run<T>(Future<T> Function(SessionToken))` 和 `token.guard(future)`：会话 dispose 后，guard 过的 future 结果一律丢弃，晚到的失败也不会改页面状态。换集就是 `old.dispose(); current = VideoEpisodeSession(identity)`，不再逐字段复位。删除 `_episodeLoadSeq` 和那 16 个 Seq/Generation 计数器，以及 `_remotePositionKeyForIndex` 这类在页面里现算身份的 helper；`video_remote_episode_index_guard_test.dart` 这类源码扫描守卫改由类型保证（host 请求的参数类型就是 `HostEpisodeIndex`，传合集内下标编译不过）。以后新增一种本集状态或异步任务，只在会话类里加字段或 `run`。页面只读 `session.snapshot`（ValueListenable）。

要动：fushi/lib/src/pages/implementations/video_fushi_page.dart；fushi/lib/src/pages/implementations/video_fushi/episode.part.dart；fushi/lib/src/pages/implementations/video_fushi/subtitle.part.dart；fushi/lib/src/pages/implementations/video_fushi/quality.part.dart；fushi/lib/src/pages/implementations/video_fushi/web_source.part.dart；fushi/lib/src/pages/implementations/video_fushi/danmaku.part.dart；fushi/lib/src/media/video/

核验说明：已验证。`_episodeLoadSeq` 在 pages/implementations 下 grep 共 97 处，与审计一致。另有 _remotePositionKeyForIndex 三种集身份混用（_persistRemotePosition 里 keyUid / episodeIndex / _activeBookUid 混在一起，6430-6458），还要靠源码扫描守卫兜底。没有找到现成的会话对象或取消作用域。

方案风险：会话 dispose 只能丢弃 Dart 侧的结果，取消不了已经下发给 mpv 或 host 的副作用（loadfile、上报进度）。换集前的 flushPosition 必须在旧会话 dispose 之前、用旧身份写完，顺序要写进 API，比如 `await old.close(flush: true)`，否则会出现新的「写到新一集」。web_source.part 只比 bookUid，迁移时会让行为变严，要确认这样不破坏网页档内的档位切换（同集换档不应作废会话）。

修正后的方案（以此为准）：按方案执行，再明确两点：会话内区分「换档 / 换轨」（同一会话内的子代际）和「换集」（新会话）；换集流程固定为 `await old.close(flushProgress: true)` 之后再建新会话，flush 用 old.identity。

## subtitle-slot-typed-source

**字幕选择按「主/副 × 后端」成对复制，持久化源是带前缀的字符串，约 90 处嗅前缀；恢复和菜单两条路径反复脱节**

- 类型：缺单一登记源；规模 L；价值 high；不改外部行为
- 核验：成立

证据：

- fushi/lib/src/pages/implementations/video_fushi/subtitle.part.dart:1050 / 1076、1127 / 1145、2131 / 2446、2219 / 2496、1378 / 2673：`_applyRemoteSubtitleFileEntry` 与 `_applyRemoteSecondarySubtitleFileEntry` 等五对主/副函数，除目标槽外逐行相同
- subtitle.part.dart:4151 / 4190 / 4239 / 4596 与 web_source.part.dart:1645：5 个 `_apply*PipelineSubtitleWhenDone`（远端原盘 / 远端 / 本地 / 在线流 / 网页），收尾逻辑一样，「仍是当前集」判据和挂载方式各不相同
- packages/fushi_engine/lib/media/video/video_subtitle_source.dart:424-510：`SubtitleSource` 只建模 embedded / external 两态，host 旁挂、关闭、生成字幕都靠字符串前缀（`embeddedPrefix` / `hostSidecarPrefix` / `offSentinel`）；video_path_migration.dart:25-28 另抄了一份 `kEmbeddedSubtitlePrefix` / `kOffSubtitlePrefix`
- grep：`isEmbeddedPersisted` / `isHostSidecarPersisted` / `isOff` / `isImportedExternalSubtitlePath` / 前缀常量在 16 个文件约 90 处使用（subtitle.part 20、video_fushi_page 16、library_subtitle_fill 9……）
- docs/bugs/BUG-3928：副字幕恢复自己拼出缺 codec 的 `SubtitleSource.embedded`，和主字幕路径脱节；BUG-2094：菜单由三份来源拼成，只补了主字幕；BUG-3984：一个字段装两种语义；BUG-165：靠扩展名判断导入档；BUG-3103：图形轨恢复丢失

机制：字幕轨的身份没有类型，只是一个可以是路径、`embedded:<n>`、`off:`、`hostsidecar:<名>`、null 的字符串。每个消费点自己嗅前缀，再自己拼回 SubtitleSource（会丢 codec 和 label）。主字幕和副字幕是两个槽，却没有「槽」这层抽象，每条挂载链都写两遍；各后端（本地 / 互联 / 媒体服务器 / 网页 / 管线产物）又各写一遍。菜单列表、恢复、持久化三条路径各自从不同来源拼候选，改一处就和另外两处脱节。

根本方案：在 fushi_engine 定义 `sealed class SubtitleTrackRef`，分支为 EmbeddedText(streamIndex, codec, lang)、EmbeddedGraphic、LocalFile(path)、HostSidecar(fileName)、RemoteEmbedded(hostTrack)、Generated(path, jobKind)、Off。配一个 `SubtitleTrackRefCodec`，是持久化字符串和 ref 互转的唯一实现：wire 格式保持现有冻结编码不变，删掉 video_path_migration.dart 里那份重复前缀和各处的 `is*Persisted`。app 层新建 `SubtitleSlotController(slot: primary|secondary)`，两个实例共用同一套 select / restore / off / 管线结果落地代码。后端差异收进 `SubtitleTrackResolver` 接口（本地、互联、媒体服务器、网页各一个实现），只负责「ref → 可挂载物（cue 列表或 mpv 轨）」和「列出本集候选」。菜单、恢复、持久化都从同一个 `SubtitleTrackCatalog`（挂在 VideoEpisodeSession 上）读。这样能删掉 subtitle.part.dart 里那几对主/副函数和 5 个 PipelineWhenDone，归并成一个 `catalog.adoptGenerated(result)`。以后新增一种字幕来源：加一个 sealed 分支，加一个 resolver 方法，switch 不穷尽就编译不过。

要动：packages/fushi_engine/lib/media/video/video_subtitle_source.dart；packages/fushi_engine/lib/media/video/video_path_migration.dart；packages/fushi_engine/lib/media/video/subtitle/library_subtitle_fill.dart；packages/fushi_engine/lib/media/video/video_subtitle_inherit.dart；fushi/lib/src/pages/implementations/video_fushi/subtitle.part.dart；fushi/lib/src/pages/implementations/video_fushi/web_source.part.dart；fushi/lib/src/pages/implementations/video_fushi_page.dart；fushi/lib/src/media/video/remote_subtitle_catalog.dart

核验说明：已验证。video_path_migration.dart:25-28 确实又复制了一份 kEmbeddedSubtitlePrefix / kOffSubtitlePrefix，注释自称「四态编码」，而 video_subtitle_source.dart 另有 hostSidecar 等前缀，说明前缀表已经不止一份。主/副成对函数与 5 个 PipelineWhenDone 按审计给的行号属实（未逐行 diff，按函数名抽查）。

方案风险：Codec 必须对现存持久化值完全向后兼容，包括历史 bug 产生的畸形值（比如缺 codec 的 embedded:<n>、Windows 大小写路径），并且需要往返测试。video_path_migration 是库搬迁时改写路径的代码，必须改用同一个 codec 判断「是不是路径」，不能删了了事。图形字幕（PGS/VobSub OCR）的挂载方式和文本轨不同，resolver 要能返回「mpv 轨」和「OCR 叠加」两种可挂载物。

## seek-landing-patch-stack

**「seek 是否落地」叠了四套按 125ms 拍数配额的启发式守卫：外部事件缺失被逐个 bug 补丁化**

- 类型：补丁叠补丁；规模 L；价值 high；不改外部行为
- 核验：部分成立

证据：

- fushi/lib/src/media/video/video_player_controller.dart:286-307 `_seekSnapGraceTicksLeft`（skipToCue，16 拍）；:308-333 `_plainSeekTargetMs` / `_plainSeekGraceTicksLeft`（普通 seek）；:335-387 `_pendingSeekLandingMs` / `_seekSettledAdvanceMs` / `_pendingSeekDispatched` / `_pendingSeekToken`（BUG-2731，换档用）；:990-1021 `_restoreTargetMs` / `_restoreGuardTicksLeft = 80`（BUG-179 恢复守护）
- video_player_controller.dart:365-368 注释说明不用 mpv `seeking` 属性的原因：属性观测会合并 yes→no 翻转；fushi/lib/src/media/video/video_graphic_subtitle_ocr_overlay.dart:33-43 写明 media_kit 1.2.6 不暴露 `playback-restart`，于是 OCR 截帧也只能按 250/500/1000/2000ms 重试
- video_player_controller.dart:4374 位置来自 `Timer.periodic(125ms)` 轮询 `player.state.position`，四套守卫都以这一拍为计量单位
- docs/bugs/BUG-179、BUG-1288（恢复 seek 被 loadfile 覆盖）、BUG-2731（换档用了旧位置）、BUG-3488（暂停态宽限被耗尽）、BUG-796（seek 后旧字幕残留）、BUG-3561（暂停 OCR 截帧失败）

机制：播放器没有可靠的「这次 seek 已落地、新帧已显示」事件，于是每个需要这个事实的消费者（cue 快照、普通 seek 字幕、恢复进度、按当前位置重开流、OCR 截帧）各自从「轮询到的位置像不像目标」去猜，再配一个拍数上限防止永久卡住。四套状态机互相要让路（「与 _seekTargetCueIndex 互斥」「复用 _seekSnapGraceTicks 同一量级」），每出一个新场景就再加一套配额，常量随设备和片源调来调去。

根本方案：先在外部边界修掉根因。libmpv 支持 `mpv_create_weak_client(handle)`，可以得到独立的事件队列；在 native 侧（新 crate `native/fushi_mpv_events`，或在已 fork 的 third_party/media_kit_video 旁 fork media_kit 的 native player）订阅 `MPV_EVENT_SEEK` / `MPV_EVENT_PLAYBACK_RESTART` / `MPV_EVENT_FILE_LOADED`，经一条 Dart port stream 推出 `SeekEvent{requestId, phase: issued|restarted|failed}`。这一条的可行性是推测，需先在 Windows 和 Android 各验一次 weak client 和 media_kit 主客户端共存。在此基础上，控制器只保留一个 `SeekTracker`：单一的在途记录 `{id, from, target, kind}`，restart 事件到达即判落地。字幕快照、恢复守护、换档基线、OCR 截帧都订阅 `seekLanded`，不再各自猜。删除 `_seekSnapGraceTicksLeft` / `_plainSeek*` / `_pendingSeek*` / `_seekSettled*` / `_restoreGuard*` 及全部拍数常量，删除 kGraphicSubtitleOcrCaptureRetryDelays。网页后端和原盘导航后端按同一接口各自上报事件。以后新增一个需要「seek 后」时机的功能，只需订阅这一个 stream。

要动：fushi/lib/src/media/video/video_player_controller.dart；fushi/lib/src/media/video/video_graphic_subtitle_ocr_overlay.dart；fushi/lib/src/media/video/mpv_cache_snapshot.dart；third_party/media_kit_video/；native/（新增 mpv 事件桥或 fork media_kit）

核验说明：四套拍数守卫、125ms 轮询（video_player_controller.dart:4374）、_restoreGuardTicksLeft、OCR 重试都属实，根因（拿不到 playback-restart）也确实在外部边界。方案的可行性没有验证：media_kit 核心（package:media_kit）没有 fork，third_party 下只 fork 了 media_kit_video 和 libs_*；weak client 能否与 media_kit 主客户端在 Windows 和 Android 上共存、mpv 句柄能否拿到，审计自己也标了推测。

方案风险：1）新建 native crate 还是 fork media_kit 是硬依赖层面的大决策，并且要五端都出产物。iOS / macOS 的 libmpv 也必须能拿到 handle，否则得保留旧守卫做兼容，违反「搬了就删、不留回退」。2）网页后端（webview）和原盘导航后端没有 mpv 事件，方案里说的「按同一接口上报」需要各自另找真相源，网页端多半仍是启发式。3）恢复守护（BUG-179）防的是「loadfile 覆盖 seek」（BUG-1288），这需要 FILE_LOADED 与 seek 的先后关系，不只是 PLAYBACK_RESTART。

修正后的方案（以此为准）：分两步。①先只做 SeekTracker 收口：四套守卫归并成一个在途 seek 记录加一个落地判定函数（暂时仍用轮询启发式），消费方统一订阅 seekLanded，删掉各自的拍数配额。这一步本身无外部依赖，可以立刻做。②再做 spike：在 Windows / Android / macOS 用 media_kit 的 NativePlayer handle 建 weak client，订阅 PLAYBACK_RESTART / FILE_LOADED（mpv_wait_event 放在独立原生线程，经 NativePort 推送）。五端都验证通过后，把 SeekTracker 的判定源换成事件，删掉启发式。网页和原盘后端保留各自的判定实现。

## video-library-projection

**视频库页在 State 里自拼全库投影：播放时每秒写进度都会触发后台整表重读，刷新一次读 video_books 两遍外加约 8 张表，后台维护挂在页面上**

- 类型：性能；规模 L；价值 high；不改外部行为
- 核验：成立

证据：

- packages/fushi_core/lib/src/database/database_video_domain.part.dart:3483-3537 `watchVideoWatchProgressChanged`：每次 `tableUpdates(videoBooks)` 都整表 `select(videoBooks)`（全列，含 playlistJson），再拼签名字符串比较
- database_video_domain.part.dart:3415 起 `watchVideoBookUids`：同一表级通知再查一遍全部 book_uid；播放页每秒 `updatePosition`（video_fushi_page.dart:8180）就会触发这两条（根据代码路径推断，未实测）
- fushi/lib/src/pages/implementations/home_video_page.dart:646-690：`_videoUidsSub` / `_watchProgressSub` / `_remotePositionsSub` / `_collectionTablesSub` / `_scrapePresentationSub` / `_downloadSubscriptionsSub` 六条订阅，各带自己的 debounce Timer 和 `_*Stale` 标记；`_watchProgressStale` 只推迟页面重读，DB 侧的整表签名查询照样每秒执行
- home_video_page.dart:1755-1762 `_refresh` 调 `_listForShelf()`（video_book_repository.dart:664，整表读并做封面自愈）、`_loadLibraryMaps()`（:1853 起再 `db.allVideoBooks()`，并行读合集 / 来源 / 成员 / 观看统计 / 刮削图等）、`_maybeBackfillCovers()`；过滤、搜索、分组在 build 里做（:6303-6400）
- home_video_page.dart:2188-2240 封面回填（全库 listAll，逐行 File.exists，起 ffmpeg 子进程）挂在页面 State 上，`if (!mounted) return`；注释里有实测记录：它曾让「每次退出卡一两秒」
- docs/bugs/BUG-5330 / BUG-5331：首页、速览、视频页各写一套「继续观看」口径；BUG-3610、BUG-3491、BUG-1699：每多一种写入方，就多订阅一条表

机制：视频库没有一个由数据层维护的「库投影」。页面拿一次性 FutureBuilder 快照，自己去订阅每张相关的表，任何变化都整页重读、重新分组。drift 的表级失效分不清改的是进度列还是封面列，所以每个 watcher 都在 DB 侧整表重查后再在内存里去重。首页、速览、详情页各自再算一遍同样的派生（继续观看、合集折叠），后台维护任务的生命周期也绑在页面 mounted 上。

根本方案：在 fushi_engine 新建 `media/video/library/video_library_projection.dart`，`VideoLibraryProjection` 服务负责维护内存里的 `VideoLibrarySnapshot`：行、合集折叠、刮削展示、继续观看候选（把 `selectVideoContinueCandidates` 并进来）、远端占位合并。输入只走写入侧的领域事件：`VideoProgressStore.watch`（见 video-progress-single-store，按 uid 推变化）、导入/删除事件、合集变更事件、刮削日志游标。按 uid 做增量 patch，不再整表重读。对外只给一个 `Stream<VideoLibrarySnapshot>` 和纯函数 `query(snapshot, filters)`；首页、速览、视频库页、fushi_server 的库清单都读它。删掉 database_video_domain.part.dart 里的 `watchVideoWatchProgressChanged` 整表签名流，删掉 home_video_page 的六条订阅及其 debounce / stale 字段，以及 `_loadLibraryMaps` / `_listForShelf` 的页面级拼装。封面回填、封面路径自愈从 `listForShelf` 读路径和页面里挪进 engine 的 `VideoLibraryMaintenance`（启动后按队列在后台 isolate 跑，读路径上不再写库）。以后新增一种影响库显示的写入：发一个领域事件，或在投影里加一个 patch 分支。

要动：packages/fushi_engine/lib/media/video/video_book_repository.dart；packages/fushi_core/lib/src/database/database_video_domain.part.dart；fushi/lib/src/pages/implementations/home_video_page.dart；fushi/lib/src/pages/implementations/home_nav_peek.dart；fushi/lib/src/pages/implementations/home_dashboard_page.dart；fushi/lib/src/media/video/video_continue_watching.dart；packages/fushi_server/

核验说明：已验证。watchVideoWatchProgressChanged（database_video_domain.part.dart:3483-3537）每次 videoBooks 表级通知都整表 select 全列（含 playlistJson）后拼签名。播放期间每秒 updatePosition 都会触发它，_watchProgressStale 只推迟页面重读、拦不住 DB 侧查询（推断，未实测）。watchVideoBookUids 已优化为只选 uid 一列并合并在途查询，比审计说的轻，但同样每秒触发。home_video_page.dart:646-690 的多条订阅和 stale 标记属实。

方案风险：1）在 Dart engine 里常驻一份全库内存投影，与架构硬规则「Dart 不存镜像状态」的精神有张力。要么论证这属于持久化投影而非计算子系统，要么考虑把投影放在 DB 查询层（增量 SQL 视图），由行级变更驱动。2）这依赖 progress store 的按 key 推送；在它之前先做投影，仍得订阅表级通知。3）漏了 remote_video_resume.dart:180 的 watchLocalRemoteVideoPositionsChanged：它对 prefs 表每一次更新做 getPrefsByPrefix 全前缀扫描，播放时每秒 2 次 setPref 就扫两遍，扫描量随集数线性增长，还会被任何无关的偏好写触发。4）fushi_server 读同一投影，意味着投影要能在无 Flutter 的引擎里运行，这一点 engine 层满足。

修正后的方案（以此为准）：先落 progress store 的 watch(keys)，再建投影。投影里的派生（继续观看、合集折叠）做成纯函数，状态只保留「按 uid 增量 patch 的行缓存」，并说明它是 DB 的读缓存，不另立真相源。watchLocalRemoteVideoPositionsChanged 的 prefs 前缀扫描在 store 落地后一并删除。

## video-page-god-state

**播放页是约 2.8 万行的单一 State，36 个 extension part 共享私有字段；可测性差到要靠 200 个源码字符串扫描测试兜底**

- 类型：上帝对象；规模 XL；价值 medium；不改外部行为
- 核验：成立

证据：

- fushi/lib/src/pages/implementations/video_fushi_page.dart:640-676 引入 36 个 part，`_VideoFushiPageState` 本身在 1708-15080（约 13400 行），with `DictionaryPageMixin`、`WidgetsBindingObserver`，并实现 `VideoFushiTestHooks`
- video_fushi/*.part.dart 全部是 `extension _Xxx on _VideoFushiPageState`（如 quality.part.dart:16），没有自己的状态，直接改主 State 的字段；subtitle.part.dart 6401 行、web_source.part.dart 2299 行
- video_fushi_page.dart:8425-8634 dispose 有 210 行，手工按顺序拆几十个 notifier、订阅和 Timer（主文件里光顶层 `Timer?` / `StreamSubscription` 字段就有 14 个）
- grep：fushi/test 下 200 个测试文件对 video_fushi_page.dart / video_fushi/ 调 `readAsStringSync` 做源码扫描守卫，例如 fushi/test/pages/video_remote_episode_index_guard_test.dart:12-35、fushi/test/media/video/hls_seek_demuxer_offset_wiring_guard_test.dart:24
- `_isRemote` 89 处、`_webMode` 41 处、`_discMenu` 49 处、`isBlurayNavigationSession` 25 处：后端差异在同一个类里按 if 堆叠

机制：功能一直以「给同一个 State 再加一个 extension part」的方式长大。part 之间没有边界，任何功能都能读写任何字段，生命周期和拆除顺序全靠一个总 dispose 记着。行为无法隔开实例化测试，只能用正则扫描源码钉住「某函数里必须调用某参数」，这种守卫既脆弱又挡不住语义错误。后端差异也没有多态，每个功能都要自己判断当前是哪种后端。

根本方案：按职责拆成有自己状态的对象，页面退回成装配层。(1) `VideoPlaybackBackend` 接口，local / interconnect / mediaServer / web / disc 各一个实现，负责起播、取流、按集请求、上报、可用能力（画质 / 音轨 / 字幕候选）；页面里的 `_isRemote` / `_webMode` / `_discMenu` 分支全部改成调 backend 方法。(2) `VideoEpisodeSession`（见 episode-session-lifecycle）。(3) 功能控制器：`VideoLookupController`（查词、光标、收藏、制卡队列）、`VideoChromeController`（控制条显隐、OSD、全屏、小窗、竖屏）、`VideoQualityController`、`VideoDanmakuController`、`VideoClipExportController` 等，每个是 ChangeNotifier 或 ValueListenable，自带 dispose，各自可以单独实例化测试。(4) 视图拆成独立的 Widget 文件（M3E / Apple 两套 chrome 各自成文件，不再是 part），用 ListenableBuilder 只订阅自己那个控制器。删掉 36 个 extension part 和 `VideoFushiTestHooks` 后门，那 200 个源码扫描守卫改写为针对控制器 / backend 的行为测试后删除。以后新增功能：新建一个控制器文件，在装配处接线一行，不再改主 State。建议放在 episode-session、subtitle-slot、progress-store 三项之后做，那三项先抽走状态最重的部分。

要动：fushi/lib/src/pages/implementations/video_fushi_page.dart；fushi/lib/src/pages/implementations/video_fushi/；fushi/lib/src/media/video/；fushi/test/pages/；fushi/test/media/video/

核验说明：已验证。全部 part 加主文件加控制器约 6.3 万行（wc 合计 63482，含 home_video_page 和控制器）。fushi/test 下同时含 readAsStringSync 和 video_fushi 的文件有 234 个（粗口径，比审计的 200 只多不少）。主文件 `_isRemote` 有 25 处，审计的 89 处应是跨 part 合计，没有否证。

方案风险：删 200 多个源码扫描守卫，必须先有等价的行为测试覆盖每一条对应的 BUG 回归，不能整批删。部分守卫钉的是跨模块约束（如 hls_seek_demuxer_offset_wiring），不全是页面内部细节。VideoFushiTestHooks 被集成测试使用，删之前要迁移集成测试的驱动入口。拆出的 chrome Widget 仍要满足 MD3 / Apple 两套动效硬规则。

## playback-hold-set

**「谁暂停的、谁来续播」靠一堆布尔标记和组合判定函数，每加一个暂停来源就改一遍判定**

- 类型：守卫代替结构；规模 M；价值 medium；不改外部行为
- 核验：部分成立

证据：

- fushi/lib/src/pages/implementations/video_fushi_page.dart:2733 `_pausedForBackground`、:3678 `_pausedForLookup`；video_fushi/subtitle_text_edit.part.dart:66-84 局部 `wasPlaying`；控制器另有 `_remoteControlRevision` / `_automaticSubtitleEndHold`（video_player_controller.dart:5912-5945）
- video_fushi_page.dart:4813-4823 `_resumeAfterBackgroundIfNeeded` 调 `shouldResumeAfterBackground(pausedForBackground, pausedForLookup)`；video_fushi/lookup_favorite.part.dart:174-197 `_pauseForLookup` 不 await 暂停，`_companionLookupClosed` 调 `shouldResumeAfterLookupDismiss(stackEmpty, pausedForLookup, caretHoldsPause)`，判定参数随来源增多不断加长
- `_pausedForLookup` 在 6 个文件里被 19 处置位或清零（subtitle_caret.part.dart:95-115、disc_menu.part.dart:383、video_fushi_page.dart:9575 / 9845……），subtitle_caret.part.dart:329 注释记录过「_pausedForLookup 不复位导致永远卡在暂停」
- docs/bugs/BUG-4131（自动续播把已播完的片子从头重播：4 条续播路径各自直调 play）、BUG-2544（后台暂停的标记藏在 media_kit 私有字段里，回前台没人续播）

机制：「暂停持有」不是一等概念。每个会暂停播放的功能（查词浮层、选词光标、副屏查词、后台、编辑字幕对话框、手机遥控查词、句尾停）各记一个「暂停前在播吗」，续播时用手写谓词去组合「别人是否还持有暂停」。新来源要改所有相关谓词，漏改就会出现「自己播起来」或「永远停住」；fire-and-forget 的暂停和 EOF 之间的竞态也只能逐个修。

根本方案：在 `VideoPlayerController`（或 VideoEpisodeSession）里加 `PlaybackHoldSet`：`PlaybackHold acquire(HoldReason reason)` 在第一个持有者进来时记下 `wasPlaying` 和 `remoteControlRevision`，然后暂停；`hold.release({bool resume = true})` 在最后一个持有者释放、期间无用户显式控制（revision 没变）且不在自然播完处（`isAtNaturalEnd`）时才调 `resumePlayback`。查词、光标、副屏、后台、编辑对话框、遥控查词都改成持有或释放 hold。删掉 `_pausedForLookup`、`_pausedForBackground`、局部 `wasPlaying`、`shouldResumeAfterBackground` / `shouldResumeAfterLookupDismiss` 这些组合谓词。以后新增一个暂停来源：加一个 `HoldReason` 枚举值，在入口调 acquire、出口调 release。守卫：`VideoPlayerController.play()` 只对用户显式入口开放，自动续播只能经 HoldSet，别处没有直接调用的口子。

要动：fushi/lib/src/media/video/video_player_controller.dart；fushi/lib/src/pages/implementations/video_fushi_page.dart；fushi/lib/src/pages/implementations/video_fushi/lookup_favorite.part.dart；fushi/lib/src/pages/implementations/video_fushi/subtitle_caret.part.dart；fushi/lib/src/pages/implementations/video_fushi/subtitle_text_edit.part.dart；fushi/lib/src/pages/implementations/video_fushi/companion.part.dart；fushi/lib/src/media/video/video_remote_host.dart

核验说明：视频页的布尔标记组合判定属实（shouldResumeAfterLookupDismiss 在 video_fushi_page.dart:1286，_pausedForLookup 在 lookup_favorite / subtitle_caret / disc_menu 等多处被清零）。但审计把它当成视频域独有的问题，漏了同一模式在音乐和阅读器里各有一份：fushi/lib/src/media/music/lyrics/music_lookup_pause.dart:33-62 已有一个「查词暂停」小抽象，music_lyrics_page.dart:474 / 1003 / 1038、reader_fushi_page.dart:2929 和 reader_fushi/lookup.part.dart:88-118 又各写一份 _pausedForLookup。

方案风险：只在 VideoPlayerController 里做 HoldSet 会再造第三份实现，和 music_lookup_pause 并存。查词浮层、副屏查词是跨媒体的公共入口（DictionaryPageMixin），hold 应该是媒体无关的接口。「play() 只对用户显式入口开放」会碰到远端遥控（video_remote_host）和 EOF 自动连播这些合法的自动起播路径，需要分出单独的入口。

修正后的方案（以此为准）：在 fushi/lib/src/media/ 建媒体无关的 `PlaybackHoldSet`（接口只依赖 isPlaying / pause / resume / controlRevision / isAtNaturalEnd），视频、音乐、有声书或阅读器朗读三方共用。music_lookup_pause.dart 改成它的薄适配后删掉。DictionaryPageMixin 的查词入口统一 acquire(HoldReason.lookup)。自动连播和遥控走独立的 `autoAdvance` / `remoteCommand` 入口，不经 hold。

## 核验补充（审计漏掉的）

- fushi/lib/src/media/video/remote_video_resume.dart:180-210 的 watchLocalRemoteVideoPositionsChanged 订阅 prefs 表每一次更新，每次都 getPrefsByPrefix 全前缀扫描所有远端断点键。本地播放每秒 setPref 两次（video_fushi_page.dart:8181-8188），网页页也是（web_video_fushi_page.dart:1152-1159），所以视频库页常驻期间每秒至少扫描两遍，扫描量随集数增长；任何无关偏好写也会触发。这比审计点名的 watchVideoWatchProgressChanged 更隐蔽，审计没提到。
- 播放时每秒的位置持久化是 3 到 4 次彼此独立、未包事务的 DB 写（updatePosition 加 2 次 setPref 加 duration；video_fushi_page.dart:8178-8189、web_video_fushi_page.dart:1152-1161）。每次写各自产生一次表级通知，分别打到 videoBooks 和 prefs 两类 watcher 上，放大了上面两条整表或前缀重查。而且这几次写不是原子的：中途崩溃会留下「行已更新、`_at_` 戳是旧值」的不一致 LWW 输入。progress store 方案应明确「单事务、一次通知」。
- 「查词暂停 / 续播」的布尔标记模式在音乐（music_lookup_pause.dart:33、music_lyrics_page.dart:474）、阅读器（reader_fushi_page.dart:2929、reader_fushi/lookup.part.dart:88-118）、视频三处各有一份实现。这是跨域重复，不是视频页独有的问题，hold 抽象应放在媒体无关层。
- watchVideoWatchProgressChanged 的签名里仍拼 playlistJson?.hashCode（database_video_domain.part.dart:3501 附近），而 video_fushi_page.dart:8176 的注释说统一合集 Phase 3 以后 playlistJson 已经不存每集进度。这一列很可能是残留（推测），既让整表查询带上大字段，也可能因为无关的播放列表元数据变化误触发库页重读。
