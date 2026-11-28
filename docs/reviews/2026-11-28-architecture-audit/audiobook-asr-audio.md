# 架构审计：audiobook-asr-audio

2026-11-28 只读审计 + 独立反驳核验的原始结论。总方案见 [../../specs/2026-11-28-architecture-redesign.md](../../specs/2026-11-28-architecture-redesign.md)。

## 现状

完成（只读审计，未改文件、未跑测试）。本域分四层：packages/fushi_audio（有声书仓库、cue 解析、EPUB↔字幕匹配，约 1.2 万行纯 Dart，匹配跑在 Isolate.run）、fushi/lib/src/media/audiobook（UI 与会话装配，6.1 万行，其中 audiobook_controller.dart 一个文件 3869 行）、asr_host（ASR 装配、模型目录、GPU 运行时、下载登记）、music（Rust 的 native/fushi_music 负责扫描、标签、歌词，fushi_engine 负责刮削编排）。有声书在数据层是两套实体：audiobooks 表按 bookKey 存，srt_books 表按 uid 存，EPUB 有声书另有一行配对的 srtbook_epub_<bookKey>。会话启动时由 AudiobookSessionLauncher._pickSource 临时决定用哪行，positionKey 也跟着在 bookKey 和 uid 之间切换。播放进度、调轴、倍速等存在 preferences KV 表里，键是 audiobook_pos_/pos_at_/delay_* 等前缀拼书键；备份、合并、profile、同步、host 各自手写 LIKE 前缀去筛这些键。播放同步靠 AudiobookPlayerController 里约 20 个布尔或可空旗标组成的隐式状态机，每个 tick 的 _updateCurrentCue 按顺序过 6 道旗标关卡。模型下载有 SharedModelDownloads、AsrModelDownloads、MangaOcrModelDownloads、GpuRuntimeStore、Irodori/Voicevox 安装器五六套登记与就绪判定；消费方各自写一遍「plan，没就绪就单飞下载，再 plan 复核」。音乐扫描本身已在 Rust + 后台 isolate 里，性能问题在 Dart 侧：远程扫描每次都重新串行下载全部 cue 和播放列表；刮削逐首串行，同专辑的发行和封面请求不复用。fushi-subtitles 的同一个 sha 在 4 份 pubspec 里手抄 7 处，再加 Cargo.toml、两份 Cargo.lock、补丁目录名，靠守卫测试兜一致性。性能结论都是读代码推出来的，没有实测；bug 类结论来自 docs/bugs 的根因段落。

## audiobook-dual-entity

**有声书是 audiobooks(bookKey) 与 srt_books(uid) 两套实体，EPUB 书还有一行配对的 srtbook_epub_<bookKey>，身份与进度键运行时临时裁决**

- 类型：缺单一登记源；规模 XL；价值 high；改持久化 / wire
- 核验：成立

证据：

- fushi/lib/src/media/audiobook/audiobook_session_launcher.dart:53-108 _pickSource：先查 Audiobook 行，没有可播音频再退到 SrtBook 行，并现场拼一个假 Audiobook()..bookKey = srtBook.uid，positionKey 在 bookKey 和 uid 之间切换
- packages/fushi_audio/lib/src/audiobook/srt_book_repository.dart:109-118 注释承认：同一批音频路径同时存在 audiobooks 行和配对 srt 行，只修好一行时会话会退到 srt 行按 uid 起播，结果「字幕不跟、进度归零」
- packages/fushi_engine/lib/media/import/epub_backed_srt_book.dart:18 epubBackedSrtBookUid = 'srtbook_epub_$bookKey'：同一本书的第二身份
- docs/bugs/BUG-1637（纯 SRT 书 bookKey 为空串，同步交集漏掉）、BUG-1338（删纯字幕书分两步、无墓碑）、BUG-3811（两表路径分叉，进度归零）、BUG-2551：同一机制至少出了 4 次
- 按书形态分支（srtBook != null / bookKey.isEmpty / alignmentFormat ==）散落在 fushi/lib 下 25 个以上文件，约 73 处，包括 sync、ops、书架、备份 path_rebase

机制：「有文本 / 无文本 / 漫画」三种形态没有用同一实体加形态字段表达，而是两张表外加一行配对。身份（bookKey 还是 uid）、音频路径、cue 归属都要在每个消费点重新判断用哪一行；任何只处理一张表的新代码（同步、删除、路径修复、备份）都会漏掉另一种形态。

根本方案：建一个统一的 audiobooks 实体：一个稳定的 audiobookId，加一个 sealed 的 AudiobookTextBinding（Epub(bookKey) / StandaloneSubtitle(srtPath) / Manga(manifest)），音频列表、cue 和进度都只挂在 audiobookId 上。由一次迁移把 srt_books 和 srtbook_epub_* 配对行并进来（旧列名冻结的话可以保留表名，只取消配对行）。AudiobookRepository 成为唯一的读写入口，并提供 resolveSession(audiobookId)；删掉 SrtBookRepository 的平行 CRUD、_pickSource 的双表回退、repairMovedPaths 的双表修复，以及同步 / 删除 / 备份里按 uid 和 bookKey 分别处理的分支。以后新增形态只给 TextBinding 加一个变体，switch 穷尽检查会让编译器指出所有要改的消费点。同步 wire 和 host 的 identity 改用 audiobookId。

要动：packages/fushi_audio/lib/src/audiobook/；packages/fushi_engine/lib/media/import/epub_backed_srt_book.dart；fushi/lib/src/media/audiobook/audiobook_session_launcher.dart；fushi/lib/src/sync/；packages/fushi_engine/lib/sync/；fushi/lib/src/pages/implementations/reader_history/books.part.dart；packages/fushi_core 数据库 schema

核验说明：已验证。audiobook_session_launcher.dart:53-108 的 _pickSource 先查 Audiobook 行，没有可播音频时退到 SrtBook 行，现场造 Audiobook()..bookKey=srtBook.uid，positionKey 也跟着在 bookKey 和 uid 之间切换。srt_book_repository.dart:109-118 的注释原文承认两行路径会分叉，结果「字幕不跟、进度归零」。epub_backed_srt_book.dart:4-11 写明配对行 srtbook_epub_<bookKey> 是 TODO-894 补上的：sync push 靠 srt_books.book_key 找配对行，缺了这一行整本书永不上传。也就是说第二身份是给同步打的补丁，不是有意的领域建模。需要更正的一点：_pickSource 的注释自称「会话来源的唯一裁决点」，会话入口确实只有一个；毛病出在数据模型上，不在多处裁决。

方案风险：1）srt_books.uid、srtbook_epub_* 和 bookKey 已写进互联 / host 的 wire（hasAudiobook 要求两表齐备，remote.part.dart 按 audiobook_pos_<uid> 写穿）、备份 zip 和 path_rebase 里。按 CLAUDE.md「存量持久化名冻结」，这些表名、列名、uid 形态都不能追改，新 audiobookId 只能作为新增列加进来。旧对端和旧备份传来的 bookKey / uid 必须能解析到 audiobookId，方案里没写这层兼容映射。2）remote 绑定（RemoteAudioBindingRepository 按 srtBook.uid 取）和合集继承（inheritPairedSrtCollections）也挂在配对行上，方案列的 touches 漏了这两处。3）规模是 XL，牵动同步协议，按规则应列取舍交用户拍板，不宜直接开工。

修正后的方案（以此为准）：保留 audiobooks 和 srt_books 两张表的名字和旧列，新增稳定的 audiobook_id 列和 text_binding 判别列（epub / standalone_srt / manga），由迁移给现有行回填。配对行 srtbook_epub_* 一律映射到同一个 audiobook_id。AudiobookRepository.resolveSession(audiobookId) 成为唯一读口，返回 sealed binding。同步、host 的 wire 继续收发旧的 bookKey / uid，进出边界时用一张 identity 映射表换算成 audiobook_id；等所有对端都支持新字段后，再停止写配对行。sync push 改成按 audiobook_id 找音频，不再依赖配对行，然后删掉 writeEpubBackedSrtBook 的补写。

## audiobook-position-untyped-prefs

**听书进度 / 调轴 / 倍速用 preferences KV 的「值 + 时间戳」两个键存，各子系统手写 LIKE 前缀，同类 bug 反复出现**

- 类型：成类 bug；规模 L；价值 high；改持久化 / wire
- 核验：部分成立

证据：

- packages/fushi_audio/lib/src/audiobook/audiobook_repository.dart:304-309 位置键和时间戳键是两个前缀；:337 updatePositionMs 在 BUG-4825 之后才合成一个事务
- packages/fushi_audio/lib/src/audiobook/audiobook_repository.dart:411-416 updateDelayMs 仍是两次独立的 setPrefTyped，和 BUG-4825 是同一个缺陷，还没修
- 前缀 audiobook_pos_ 被手写在 fushi/lib/src/sync/backup_service.dart:744/794/1100、backup_merge_engine.dart:2368-2379、backup_service/restore.part.dart:62、sync_repository.dart:1180、profile/profile_keys.dart:209、models/preference_keys.dart:1457、packages/fushi_engine/lib/sync/fushi_library_host_service.dart:2030
- 值是全书毫秒偏移，换音频或换 cue 后会失效：BUG-1679、BUG-3197 各打了一个 rebase / 归零补丁（audiobook_repository.dart:115、:352）
- 同一机制的 bug：BUG-471、1019（profile 把进度当设置吞掉）、1637、1679、2328、3197、4775（合并不受墓碑约束）、4825，共 8 个以上

机制：进度是一个带身份、带音频集版本、带时间戳的实体，现在被拆成若干字符串 KV。原子性、墓碑、排除过滤、profile 分类、同步 LWW 都得由每个消费方自己按前缀重新实现；漏一处就是一个新 bug。

根本方案：新增 audiobook_playback_state 表：audiobookId PK，存 fileIndex + fileOffsetMs（不用全书毫秒）、cueAnchor（cue id / 章节加字符锚）、audioSetRevision、speed、delayMs、followAudio、updatedAt，各字段 LWW 时间戳同行原子写。迁移把旧 prefs 搬过来并删除前缀。备份、合并、profile、同步、host 都把它当普通书库表，复用书库行已有的墓碑和 excludedBookKeys 子查询，删掉上面 8 处 LIKE 前缀和 rebaseStoredPositionForCueChange。换音频时只比较 audioSetRevision，不一致就按 cueAnchor 重新定位，不再做毫秒换算。用守卫禁止新代码出现 'audiobook_pos_' 字面量。

要动：packages/fushi_audio/lib/src/audiobook/audiobook_repository.dart；packages/fushi_core 数据库；fushi/lib/src/sync/backup_service.dart；fushi/lib/src/sync/backup_merge_engine.dart；fushi/lib/src/sync/sync_repository.dart；fushi/lib/src/profile/profile_keys.dart；packages/fushi_engine/lib/sync/fushi_library_host_service.dart

核验说明：已验证。updateDelayMs 在 audiobook_repository.dart:411-416 是两次独立的 setPrefTyped，和 BUG-4825 修好之前的 updatePositionMs 是同一个缺陷，确实还没修。前缀 audiobook_pos_ 手写的位置也属实：backup_service.dart:744/794/1100、backup_merge_engine.dart:2368/2379、restore.part.dart:62、profile_keys.dart:209、preference_keys.dart:1457，此外还有 remote.part.dart:2013/2388 和 sync_orchestrator/audiobooks.part.dart，比审计列的更多。不成立的部分：把 prefs 整体迁成新表并删掉前缀，和「偏好键冻结」规则冲突，而且这些键本身就是互联 LWW 的 wire 契约（interconnect_playback_position_sync.dart:524/712、sync_manager.dart:1255 的 runIfIntPrefUnchanged 直接按键名读写，host 远端也按真实键名拉取）。把值从全书毫秒改成 fileIndex+offset 会改变 wire 语义，旧对端读不懂。

方案风险：1）删前缀会破坏与旧版对端、旧备份的进度互通：host 的 remoteKey 写穿、云 SyncManager 都按键名操作。2）方案说「复用书库行已有的墓碑」，但合并引擎要先有 audiobookId，否则无行可挂，所以它依赖 dual-entity 先落地，方案里没写这个顺序。3）最便宜的根因修复（delay 对的原子写）被埋在 L 级重构里。

修正后的方案（以此为准）：分两步走。第一步立即做：把 updateDelayMs 改成和 updatePositionMs 一样的单事务「比较、写值、写戳」，speed / followAudio 如果参与 LWW 也同样处理；再把散落的 LIKE 前缀收敛成 fushi_audio 导出的一个 AudiobookPrefKeys 单一源（前缀常量、SQL 片段、分类判定），加守卫禁止其他文件出现 'audiobook_pos_' 字面量。第二步在 audiobookId 落地之后做：新增 audiobook_playback_state 表作为本机真相源，wire 和备份仍按旧键序列化（边界上做适配），旧 pref 键只作为对外兼容格式保留，不删。cueAnchor 作为新增字段与毫秒值并存，换音频时优先用它重新定位。

## audiobook-controller-flag-state-machine

**AudiobookPlayerController 用约 20 个布尔旗标拼出隐式状态机，seek / 跨章 / 激活恢复的时序 bug 一个旗标补一次**

- 类型：补丁叠补丁；规模 L；价值 high；不改外部行为
- 核验：成立

证据：

- fushi/lib/src/media/audiobook/audiobook_controller.dart:118-251、534-640 依次有 _outstandingActivationIssued、_stopRequested、_textLeadsRequested、_pausedAtPageEnd、_pageEndCrossArmed、_resumeMainAfterClip、_hasPlayedOnce、_forceNextReveal、_explicitNavigationRevealCue、_chapterTransition、_manualReaderOverrideCue、_explicitSeekInFlight、_explicitSeekPlatformOp、_crossChapterHeldForCallerSeek、_crossChapterDeferredToReceipt、_activationRestoreTarget 等，每个旗标注释里都写着对应的 BUG 编号
- audiobook_controller.dart:2448-2545 _updateCurrentCue 每个 tick 依次过 explicitSeek、platformPending、activationRestore、stopAtPosition、textLeads、chapterTransition 6 道关卡，顺序本身承载语义
- 该文件含 92 处 BUG-/TODO- 注释；同类时序 bug 有 BUG-061（三段跳）、112（暂停后跳两次）、2529（跨章守卫永不解除）、2961、3496、3798
- audiobook_controller.dart:604-620 注释承认平台 seek 回执可能永远不来，于是从计数器改成编号来绕开

机制：「现在谁拥有播放位置 / 视口」（用户 seek 中、平台载入中、跨章等 reader、文字领读停页、片段试听）这些互斥阶段没有显式建模。每个新场景就加一个旗标，在 tick 里加一道 early-return；旗标之间的组合和清理时机没人保证，只能靠测试逐个兜。

根本方案：把播放协调抽成纯 Dart 状态机，放在 fushi_engine 或 fushi_audio，不依赖 just_audio：sealed PlaybackPhase（Idle / ActivatingRestore(target) / Playing / ExplicitSeek(opId,targetCue) / CrossChapterPending(receipt) / ClipPreview(returnTo) / PageStop），输入是事件（PositionTick、SeekIssued、SeekAck(opId)、SectionRestored、UserNav、Pause…），输出是命令（seek、pause、requestCrossChapter、reveal(cue)、persist）。每个 phase 只接受合法事件，转移是纯函数，用表驱动测试覆盖。控制器只负责把 just_audio 事件喂进去、执行命令，reveal 判定（_forceNextReveal、explicitNavigationReveal、_hasPlayedOnce）合并成状态机输出的一个 RevealPolicy。删掉上面的旗标和 *ForTesting 判定函数。以后新增场景就是加一个 phase 或一种事件，switch 穷尽检查让漏掉的转移编译不过。按 UI 拆 controller，cue 索引和 tick 节流也一起移出。

要动：fushi/lib/src/media/audiobook/audiobook_controller.dart；fushi/lib/src/pages/implementations/reader_fushi/audiobook.part.dart；packages/fushi_audio 或 packages/fushi_engine/lib/media/audiobook/

核验说明：已验证。audiobook_controller.dart 共 3869 行，含 92 处 BUG-/TODO- 注释。实例级 bool 旗标至少有 18 个：:118 _outstandingActivationIssued、:124、:126、:168、:171、:192、:197、:251、:534、:539、:591、:604、:634、:639、:795、:833、:994、:2884，另有 _explicitSeekPlatformOp 编号、_activationRestoreTarget 等可空状态。_updateCurrentCue（:2448 起）依次过 explicitSeek、platformPending、activation、stopAt、textLeads、chapterTransition 几道 early-return，和审计描述一致。:604-625 的注释承认平台 seek 回执可能永远不来，所以从计数器改成编号。没有找到「有意这样设计」的文档。

方案风险：1）状态机放进 fushi_engine 可以（纯 Dart、不碰 flutter），但 cue 索引和 tick 节流是否属于「计算型子系统应由 Rust 持有」要先判断。cue 查找是 O(log n) 的轻计算，留在 Dart 合理，但应在方案里写明不搬 Rust 的理由，以免和胖核心规则冲突。2）reader 侧 audiobook.part.dart 与控制器之间的回调（notifySectionRestoreCompleted、翻页、图片章暂停 _imageChapterPauseActive、_readerDetached）也是状态输入，方案的事件清单漏了「reader 可见 / 分离」「图片章暂停」两类。3）阅读器类修复按规则要在 paginated / continuous / vn 三种模式都实机验证，重写时必须先补齐这些回归用例。

修正后的方案（以此为准）：按原方案做，补三点：事件集合要加 ReaderVisibilityChanged、ReaderDetached、ImageChapterPause；先把现有那些 *ForTesting 判定和 BUG 回归用例翻成状态机的表驱动测试，再切换实现；控制器拆分后，三种 view mode 各做一次真机复测。

## model-provisioning-duplicated

**模型下载与就绪判定有五六套登记表，消费方各自写一遍「plan → 下载 → 复核」**

- 类型：缺单一登记源；规模 L；价值 medium；不改外部行为
- 核验：部分成立

证据：

- fushi/lib/src/asr_host/shared_model_downloads.dart:24-60 SharedModelDownloads（单飞）；fushi/lib/src/asr_host/asr_model_downloads.dart:61-160 AsrModelDownloads 是叠在它上面的第二层登记（槽、进度、lastError、GPU 错误）
- fushi/lib/src/media/manga/ocr/manga_ocr_model_downloads.dart:37-80 MangaOcrModelDownloads 把同一套槽、进度归并、lastError 又写了一遍（注释自称与 ASR「同一套设计」）
- fushi/lib/src/asr_host/gpu_runtime_pack.dart:316-356 GpuRuntimeStore.isReady 自带 marker 加字节数判定；packages/fushi_engine/lib/tts/local/irodori_local_package.dart:510-794、voicevox_local_engine.dart:380-675 各有一套 InstallStep 和下载流程
- 「plan，!modelReady 就 join 共享下载，再 plan 复核」在 audiobook_auto_transcribe.dart:89-106、asr_transcribe_sheet.dart:777/858-875、video_subtitle_model_ports.dart:89-152、tts_render_runner.dart:907、manga_drama_track_service.dart:167 各写一份，进度累加（completedBytes / lastFileTotal）也各写一份
- 同机制 bug：BUG-3693（弹层持有下载，两个写者把 .part 写坏）、BUG-4128（就绪判定随显存预算翻转）、BUG-5292（歌曲档按推荐变体重下整套模型）

机制：「一份磁盘资产（文件清单 + 字节数 / sha + 就绪 marker）的安装、单飞、进度、失败原因」没有统一抽象。每个模型种类、每个入口页面各自持有一段流程；单飞键、就绪判据、GPU 附带下载的规则散在各处，所以修一处漏一处。

根本方案：在 fushi_engine 加一个纯 Dart 的 ModelAssetManager：各种类登记 ModelAssetSpec（id、目标目录、成员文件 + 字节数 / sha、依赖资产，比如 song 档依赖 mixed 档加分离模型、Windows 依赖 GPU 运行时），统一提供 status(id)（Ready / Partial / Missing / Installing(progress) / Failed(reason)）、ensure(id) 返回 Stream<ProvisionEvent>（单飞、依赖先装、装完复核）、cancel(id)，进度归并只写一次。ASR 的 plan 只负责选出资产 id（变体选择留在上游 planAsrEncoderVariant），然后交给 manager。删掉 SharedModelDownloads、AsrModelDownloads、MangaOcrModelDownloads 和各消费方手写的下载复核段；Irodori、Voicevox、GPU 运行时、MOSS 改成登记 spec（解压或运行安装脚本作为 spec 的 postInstall 钩子）。设置页、CLI（ctl_settings_model_routes）、弹层都只读 manager 的 ChangeNotifier 快照。以后新增模型只加一个 spec。

要动：fushi/lib/src/asr_host/；fushi/lib/src/media/manga/ocr/manga_ocr_model_downloads.dart；fushi/lib/src/media/audiobook/asr_transcribe_sheet.dart；fushi/lib/src/media/audiobook/audiobook_auto_transcribe.dart；fushi/lib/src/media/video/subtitle/video_subtitle_model_ports.dart；packages/fushi_engine/lib/tts/local/；fushi/lib/src/ops/ctl_settings_model_routes.dart

核验说明：重复部分已验证。SharedModelDownloads（shared_model_downloads.dart:24）负责单飞；AsrModelDownloads（asr_model_downloads.dart:61）在它之上再加槽位、进度、lastError、GPU 运行时；MangaOcrModelDownloads（manga_ocr_model_downloads.dart:37）的注释自称是同一套设计，但没有复用 SharedModelDownloads，它的 start() 在 :67 直接 listen 服务流。消费方的「plan、!modelReady、下载、再 plan 复核」在 audiobook_auto_transcribe.dart:89-106 和 video_subtitle_model_ports.dart 都能看到。审计有夸大的地方：SharedModelDownloads 已经是 ASR、MOSS 共用的单飞层（kZZmXQBv7E），不是完全没有单一源；ASR 的下载事件、清单和 asrModelPackFor 来自上游 fushi_asr_core。

方案风险：1）方案说设置页读 manager 的 ChangeNotifier，但 ChangeNotifier 属于 package:flutter/foundation，fushi_engine 禁止 import flutter。engine 侧只能暴露 Stream 或纯 Dart 快照，Listenable 适配要放在 app 层。2）ASR 的文件清单、sha、下载器（ModelDownloadEvent、downloadModel）属于上游，硬规则是「ASR 算法一律去上游改」。在本仓另立一份 ModelAssetSpec 描述 ASR 成员文件，会和上游清单形成新的双源。ASR spec 必须从上游 pack 派生，不能在本仓手写。3）Irodori / Voicevox 的安装含解压、运行脚本、版本迁移，统一成 postInstall 钩子后要保留各自的失败语义。

修正后的方案（以此为准）：在 fushi_engine 加纯 Dart 的 ModelAssetManager，只管单飞、依赖顺序、进度归并、lastError、取消，以及 status / ensure 的流接口。资产的成员和就绪判据由各 provider 实现一个接口：ASR provider 包上游的 pack 和 store，OCR、GPU 运行时、TTS 各写一个 adapter。app 层用一个 ChangeNotifier 外壳给 UI 和 CLI 读。MangaOcrModelDownloads 和 AsrModelDownloads 收敛成这个 manager 的视图，SharedModelDownloads 并入 manager。各消费方的「plan、下载、复核」收敛成 manager.ensure(assetIdFor(plan))。

## srt-listall-sync-stat-every-path

**书架每次列有声书都全表读两张表，并在主 isolate 上对每本书的每个音频文件做同步 stat**

- 类型：性能；规模 M；价值 medium；改持久化 / wire
- 核验：部分成立

证据：

- packages/fushi_audio/lib/src/audiobook/srt_book_repository.dart:86-90 listAll() 每次都先 await repairMovedPaths()
- srt_book_repository.dart:120-130 repairMovedPaths 读 getAllSrtBooks 加 getAllAudiobooks 两张全表，再逐行 _hasMissingPath
- srt_book_repository.dart:255-277 _anyMissing 对每行 jsonDecode(audioPathsJson)，再对每个音频路径调 probe；异常一律 catch (_) 返回 false
- packages/fushi_audio/lib/src/audiobook/audiobook_path_relocator.dart:62-63 defaultExists = FileSystemEntity.typeSync，是同步 IO
- fushi/lib/src/media/sources/reader_fushi_source.dart:128 书架来源直接调 SrtBookRepository(db).listAll()

机制：把「自愈旧数据根路径」这种一次性迁移挂在热路径（列书）上，用「每次都检查」代替「数据根变了才修」。代价是 O(书数 × 音频文件数) 次同步 stat 落在 UI isolate；多文件有声书库、外置盘、慢 FS 上会直接卡帧。这是读代码推出来的，没有实测。

根本方案：路径改成存相对数据根的相对路径（或在 audiobookId 实体上记 dataRootId），从源头消除「数据根搬家导致绝对路径失效」，repairMovedPaths 改为数据根变更 / 备份恢复时跑一次迁移（异步、后台 isolate）。listAll 只读库，不碰 FS；「是否缺文件」的健康状态放到后台扫描写库（已有 health 列），书架读列就行。删掉 listAll 里的自愈调用和每行 jsonDecode。

要动：packages/fushi_audio/lib/src/audiobook/srt_book_repository.dart；packages/fushi_audio/lib/src/audiobook/audiobook_path_relocator.dart；fushi/lib/src/media/sources/reader_fushi_source.dart；fushi/lib/src/sync/backup_service/path_rebase.part.dart

核验说明：现象已验证。listAll（srt_book_repository.dart:86-90）每次都先跑 repairMovedPaths；repairMovedPaths（:120-130）读两张全表，逐行用 _anyMissing 做 jsonDecode，再用 defaultExists，也就是 audiobook_path_relocator.dart:62-63 的同步 typeSync。srtBooksProvider（reader_fushi_source.dart:127-132）在调用方 isolate 上执行。但「挂在热路径上」是有意设计：:97-107 的注释论证了为什么不做一次性迁移（追不上已经迁完的设备、要多扛一个「跑过没」的标志、标志为真后再也不自愈），也写明了代价是「健康库每行几次 stat」。所以问题不是没想过，而是这个取舍的代价没有实测、可以改进。性能结论是推测，审计也说了没有实测。

方案风险：1）把绝对路径改存相对路径，会改变冻结列 audio_paths_json / audio_root 的语义，而且备份 path_rebase 和 Windows↔Android 合并依赖现有格式，属于高风险的持久化改动。2）改成「数据根变更时迁移一次」，会把注释里那几个被否决的理由重新引回来，方案没有回应这些理由。3）审计没注意到 srtBookMissingAudioUidsProvider（reader_fushi_source.dart:133-139）对同一批路径还会再探一遍。

修正后的方案（以此为准）：保留读侧自愈的语义，但做两处改动：探测移到后台 isolate，用 Isolate.run 收拢两表行的路径批量探 exists，返回断链 uid 和修复计划；同一次扫描的结果同时供 repair 和 srtBookMissingAudioUids 使用，一次探测两处复用。listAll 先返回库内数据，自愈完成后通过集合变更信号触发重算。改用相对路径的方案另作为持久化决策交用户拍板。

## music-scrape-per-track-no-memo

**音乐刮削逐首串行，每首新建一组 HTTP 客户端，同专辑的 recording / release / 封面请求不复用**

- 类型：性能；规模 M；价值 medium；用户可见
- 核验：部分成立

证据：

- fushi/lib/src/media/music/metadata/music_scrape_service.dart:396-400 每首都 _scraperFactory(...) 新建 MusicBrainz / AcoustID / CAA / VGMdb provider（新连接），:436 用完就 close
- music_scrape_service.dart:504-532 _scrapeLibraryInWork 对 todo 逐首 await scrapeTrack；:342-352 _serial 再串一层
- packages/fushi_engine/lib/media/music/metadata/music_metadata_resolver.dart:517-560 scrape()：每首都要 identify、fetchRecording、fetchReleaseCovers，外加最多 3 次 MV 查询，没有任何按 releaseId 的缓存
- packages/fushi_engine/lib/media/music/metadata/music_metadata_provider.dart:122-125 MusicBrainz 闸门 1100ms/次，而且 CAA 的 JSON 索引也走这个闸门
- music_scrape_service.dart:447-470 _maybeDownloadCover 按专辑下载封面，但是在每首的流程里触发，同专辑的前几首都会重复判断、重复请求

机制：刮削单位是「首」，而 MusicBrainz 的天然单位是「发行（专辑）」。在 1 req/s 的硬限速下，每首 5～7 个请求，同专辑 N 首重复取同一个 release 和封面索引，整库刮削时长随曲数线性放大，而且大部分时间花在重复请求上。依据是代码路径推断，加上限速常量，没有实测。

根本方案：刮削改成按专辑分组：listMusicTracksNeedingScrape 按 albumUid 分组，每组先确定 release（一首识别成功或 MBID 标签直接命中后，取 release 的 track list，按碟号 / 曲序 / 时长批量匹配组内其余曲目），release、封面、VGMdb 每组只取一次。provider 组在整次 scrapeLibrary 里只建一份，带进程内 LRU（recordingId → recording，releaseId → release / covers）。单首手动刮削走同一套缓存。删掉每首 new/close 和每首封面判断。

要动：fushi/lib/src/media/music/metadata/music_scrape_service.dart；packages/fushi_engine/lib/media/music/metadata/music_metadata_resolver.dart；packages/fushi_engine/lib/media/music/metadata/musicbrainz_provider.dart

核验说明：已验证：defaultMusicScraper（music_scrape_service.dart:73-88）每首都新建 MusicBrainz、AcoustID、CAA、VGMdb 四个 provider，用完在 :436/:425 close；_scrapeLibraryInWork（:504-532）逐首执行。审计漏掉了一点：VideoMetadataHttpClient 本来带进程内 30 分钟响应缓存（video_metadata_transport.dart:163/211-255，defaultCacheTtl 30min），provider 也都传了 cacheKey（musicbrainz_provider.dart:117、music_auxiliary_providers.dart:233/373）。真正的根因是缓存已经存在，却因为每首新建、close() 又会 _cache.clear()（:303-305）而完全失效，并不是「没有任何缓存」。审计关于封面的说法不成立：scrapeTrack 每首都从库里重读 album（:372-375 getMusicAlbum），第一首把封面下载成功、写入 coverPath 后，后续曲目会被 `album.coverPath == null` 挡住，不会重复下载；只有 fetchReleaseCovers 的 JSON 索引会按首重复请求。逐首串行（:340-352 的 _serial）是为了配合 MusicBrainz 1 req/s 限速，是有意设计。

方案风险：1）provider 每首新建是因为 sink（原始响应快照）按首绑定在 provider 构造参数 onRawResponse 上。要整次刮库共用一份 provider，就得把 sink 改成按调用传入，否则快照会串到别的曲目，方案没提到这一点。2）按专辑批量匹配 track list 会改变识别结论，属于用户可见变化（审计也标了 changesUserVisible），需要回归现有刮削测试。

修正后的方案（以此为准）：第一步是根因修复：scrapeLibrary 期间只建一份 MusicMetadataScraper，把 sink 改成 scrape(facts, sink: …) 按调用传入，让现有的 VideoMetadataHttpClient 缓存在整次刮库中生效，同专辑的 release / CAA 索引自然只请求一次。第二步可选：按 albumUid 分组，先用 release 的 track list 匹配，再对匹配不上的曲目逐首识别。这一步改变识别行为，要单独回归。

## remote-music-scan-refetch-cue-playlist

**远程音乐来源每次扫描都串行重新下载全部 .cue 和播放列表文件，不看 mtime**

- 类型：性能；规模 S；价值 medium；不改外部行为
- 核验：部分成立

证据：

- fushi/lib/src/media/music/music_library_scanner.dart:311-315 对所有 .cue 文件逐个 await bytes.readBytes，在 _ingest 拿到 knownFiles 之前就做，不判断 mtime / size
- music_library_scanner.dart:317-327 播放列表同样逐个串行 readBytes 加解析，每次扫描都做
- music_library_scanner.dart:393-411 _ingest 其实已经拿到了 known（path → mtime/size）用于跳过音频，但 cue 和播放列表绕开了这条路径
- music_library_scanner.dart:494-520 _importPlaylists 每次都全量 listMusicTracks() 再逐个导入，即使播放列表没变

机制：「增量」只在 Rust 扫描游标处理音频时实现；cue 和播放列表这两类辅助文件在 Dart 侧另走一条全量路径，没复用已知文件表。SFTP / WebDAV 上每个文件一次往返，串行执行，放大为扫描时延。这是读代码推出来的。

根本方案：把 cue 和播放列表也交给 Rust 远程游标（native/fushi_music/src/remote.rs 已有按需取区间的 need/serve 协议），在 known 未变时直接跳过；或者至少在 Dart 侧先拿 known 再按 mtime/size 过滤，并以有界并发取字节。播放列表导入记录源文件 mtime，未变不重导。删掉 scanRemoteSource 里的两段全量预读。

要动：fushi/lib/src/media/music/music_library_scanner.dart；packages/fushi_music/lib/src/music_scanner.dart；native/fushi_music/src/remote.rs

核验说明：已验证：scanRemoteSource（music_library_scanner.dart:311-327）在拿到 known 之前，就逐个串行 readBytes 全部 .cue 和播放列表，不做 mtime / size 过滤；_ingest（:393-411）里有 knownFiles，但 cue 和播放列表没有用上。不成立的部分：_importPlaylists 并不会每次重新导入。importMusicPlaylistFile（music_local_playlists.dart:143 起，约 :152-158）按路径派生 uid，已导入的直接返回 alreadyImported，每次只多一次 listMusicTracks 全表读（:500）。另外 reparseAll（解析器修订号变化）时需要全量重读，这是有意的。

方案风险：cue 内容会影响曲目切分。mtime 没变就跳过读取时，必须保证 Rust 侧对「没变的 cue」仍能沿用上次的切分结果，不能因为没传 cue 字节就把分轨曲目当成消失。reparseAll 为真时必须照旧全量读取。

修正后的方案（以此为准）：先在 Dart 侧取出 known，非 reparseAll 时对 mtime / size 都未变的 .cue 和播放列表跳过下载，Rust 游标对没传字节的 cue 沿用库内已有的分轨；变化的文件以有界并发读取。listMusicTracks 只在至少有一份播放列表需要导入时才读。

## fushi-subtitles-sha-multi-pin

**fushi-subtitles 的 sha 手抄 7 处 pubspec 外加 Cargo rev 和两份 lock，靠守卫测试兜一致**

- 类型：守卫代替结构；规模 S；价值 medium；不改外部行为
- 核验：部分成立

证据：

- fushi/pubspec.yaml:16-29、packages/fushi_engine/pubspec.yaml:51-63、packages/fushi_server/pubspec.yaml:49-58、pubspec.yaml:177-181 共 7 条 ref: 5284dbf0…
- 三个成员 pubspec 都是 resolution: workspace（fushi/pubspec.yaml:2、packages/fushi_engine/pubspec.yaml:2、packages/fushi_server/pubspec.yaml:2），根 pubspec.yaml:26 workspace，pub 只解析一次，根 dependency_overrides 已对全 workspace 生效
- native/fushi_compute/Cargo.toml:51-52 注释要求 rev 与七处 ref 一致；native/fushi_compute/Cargo.lock、native/fushi_ios_umbrella/Cargo.lock 各含一次该 sha
- fushi/test/build/git_dep_sha_single_source_guard_test.dart:5-22 起因是 sha 抬升时漏改两份 pubspec，导致解析成两个副本（2026-09-10 实测）；守卫只管 pubspec，不管 Cargo

机制：workspace 已经只有一次解析，成员 pubspec 却仍各自写完整的 git 源，于是一个事实有 7 个副本加 Cargo 两份。升级流程靠文档清单和事后守卫，不是靠结构保证。

根本方案：在根 pubspec.yaml 的 dependency_overrides 里给 fushi_asr_core / fushi_asr_subtitles / fushi_asr_onnx_ffi 各写一条 git 源（Dart 侧唯一真相源），三个成员 pubspec 改成 `fushi_asr_core: any` 之类的无源约束（这在 workspace 下可行是推测，需要 pub get 验证）。新增 tool/bump_fushi_subtitles.dart <sha>：改根 override 和 Cargo.toml rev，跑 cargo update -p fushi_asr_cue_post（两份 lock），重命名 ci/patches/git/fushi-subtitles-<sha>/，再跑 native_licenses。守卫收窄为「Cargo rev == 根 override ref，且成员 pubspec 不得含 fushi-subtitles url」。以后升级只跑一条命令。

要动：pubspec.yaml；fushi/pubspec.yaml；packages/fushi_engine/pubspec.yaml；packages/fushi_server/pubspec.yaml；native/fushi_compute/Cargo.toml；fushi/test/build/git_dep_sha_single_source_guard_test.dart；docs/agent/asr-assembly.md；tool/

核验说明：已验证：fushi/pubspec.yaml:21/31、fushi_engine/pubspec.yaml:57/65、fushi_server/pubspec.yaml:54/59、根 pubspec.yaml:182 共 7 处 ref，加上 Cargo.toml:52 和两份 Cargo.lock 各一处。三个成员都在根 workspace 列表里，根 pubspec 本身已有 dependency_overrides（:62），且已用 override 钉了 fushi_asr_core（:177-182）。审计有一处事实错误：守卫并非只管 pubspec。git_dep_sha_single_source_guard_test.dart:84-98 读取了 native/fushi_compute/Cargo.toml 的 rev 并纳入比对，补丁目录名也校验了；实际没覆盖的只有两份 Cargo.lock。

方案风险：成员改写成 `any` 后，就要靠根 override 提供 git 源。这样 fushi_engine 的约束不再自描述，依赖 workspace 才能解析；fushi_server 的 Docker 构建会 COPY 整个仓库（Dockerfile.source:28），这一点没问题。但 override 会掩盖版本冲突（pub 对 override 不做约束校验），并且所有 workspace 成员被强制使用同一源，这正是想要的效果，只是要写明。`any` 加 override 在 workspace 下能否解析，是推测，需要 pub get 实测。

修正后的方案（以此为准）：按方案做：三个包都放进根 dependency_overrides 用 git 源，成员只写 `any`（先用 pub get 验证）。用 tool/bump_fushi_subtitles.dart 一条命令改 override、Cargo rev、两份 lock、补丁目录。守卫在现有基础上补上 Cargo.lock 校验，并检查成员 pubspec 里不得再出现 fushi-subtitles 的 url。

## 核验补充（审计漏掉的）

- 音乐刮削真正的根因是已有缓存被架空：VideoMetadataHttpClient 自带 30 分钟进程内响应缓存（packages/fushi_engine/lib/media/video/metadata/video_metadata_transport.dart:163、:211-255），MusicBrainz、CAA、VGMdb 也都传了 cacheKey；但 defaultMusicScraper 每首新建一组（fushi/lib/src/media/music/metadata/music_scrape_service.dart:73-88、:396），close() 又会清缓存（video_metadata_transport.dart:303-305），缓存命中率为零。之所以每首新建，是因为原始响应 sink 绑在 provider 构造参数上（music_scrape_service.dart:396-400），修复点在 sink 改成按调用传入。
- 播放列表按路径 uid 判断已导入并直接跳过（fushi/lib/src/media/music/music_local_playlists.dart:143 起，outcome alreadyImported 约在 :158）。scanRemoteSource 传了 mtimeMs（music_library_scanner.dart:322），但导入侧看起来不用它判断变化，所以用户编辑过的播放列表文件可能永远不会更新进歌单。这是推测，需确认 importMusicPlaylistFile 是否比较 mtime。
- 书架对同一批有声书路径做两遍同步探盘：srtBooksProvider → listAll → repairMovedPaths 探一遍（packages/fushi_audio/lib/src/audiobook/srt_book_repository.dart:86-130），srtBookMissingAudioUidsProvider → SrtBookMissingAudio.probeMissingUids 再探一遍（fushi/lib/src/media/sources/reader_fushi_source.dart:133-139）。两处没有共用一次探测结果。
- EPUB 有声书的配对行 srtbook_epub_* 本质上是为同步 push 打的补丁：sync_orchestrator 和 syncAudiobookPackages 靠 srt_books.book_key 找配对行（packages/fushi_engine/lib/media/import/epub_backed_srt_book.dart:4-11），host 的 hasAudiobook 又要求两表齐备（同文件 BUG-1678 段）。双实体问题的根在同步层的身份判据，统一实体时必须先改这里，否则统一不了。
- git_dep_sha_single_source_guard_test.dart 不校验 native/fushi_compute/Cargo.lock 和 native/fushi_ios_umbrella/Cargo.lock 里的 sha（已验证，这两份 lock 各含一次 5284dbf0），lock 与 Cargo.toml 的 rev 不一致时守卫抓不到。
