# 架构审计：manga-ocr

2026-11-28 只读审计 + 独立反驳核验的原始结论。总方案见 [../../specs/2026-11-28-architecture-redesign.md](../../specs/2026-11-28-architecture-redesign.md)。

## 现状

漫画阅读器是一个 WebView 宿主：`fushi/lib/src/media/manga/reader/manga_fushi_page.dart`（10257 行，State 里 114 个字段、36 个 bool 状态位，另有 6 个 part 文件经 `_s.` 伸手）同时管本地卷、书架在线章（Mihon / Kavita / 互联 / 网页漫画）、直读章、整卷 / 流式 OCR、超分、朗读、页图拦截转码，页面 DOM 与 25 个 `window.__manga*` 钩子拼在 `manga_overlay_html.dart`（4014 行 Dart 字符串）里，用 32 处 `evaluateJavascript` 直接驱动。进度有两张表：本地卷只写书级 `reader_positions`（sectionIndex 当页码），在线条目再写章级 `manga_chapter_states`，`reader_positions` 里存的是「当前章第几页」、不带章身份。互联 / 云 / Kavita / 对比弹窗每条同步通道都要各自判一遍「这本是不是章节式」（`raw['chaptered']`）。OCR 有 5 个引擎：本地 ONNX 在 fushi_engine，Lens / 系统 OCR 在 app 层，外部 mokuro 和配对 host 各走一路。每个引擎自带一套「枚举页 → 缓存目录 → 整卷命中回放 → 写 manga.json」，有两种逐页缓存格式（按页名的 `MangaOcrFilePageCache`、按页号的 `GoogleLensPageCache`），恢复逻辑靠手维护的前缀表去找。ONNX 推理有两套后端：app 用 vendored 的 `flutter_onnxruntime`（MethodChannel，带 19 个补丁），服务端用 fushi-subtitles 的 `asr_onnx_ffi`（dart:ffi）。PDF 转漫画在 UI isolate 上逐页用 pdfrx 渲染，再经 dart:ui 编码 PNG，所以只能在 app 里跑，fushi_server 一律回 unsupported。docs/bugs 里漫画 / OCR 相关的 bug 有 311 条，明显成簇的有：窗口文档代次与换章生命周期（≥9 条）、进度表与同步分叉（≥7 条）、OCR 缓存身份与恢复（≥8 条）、ONNX provider 与内存（≥6 条）。

## manga-progress-two-tables

**漫画进度分成书级 reader_positions 和章级 manga_chapter_states 两张表，本地卷与在线章各走一种，同步通道逐个补特例**

- 类型：成类 bug；规模 L；价值 high；改持久化 / wire
- 核验：成立

证据：

- fushi/lib/src/media/manga/reader/manga_fushi_page.dart:2563-2573 注释写明：initialPage 非空 = 章级进度定起始页、不读书级 reader_positions（那一行装的是上一章读到哪，BUG-1924）；null = 本地卷，按书级位置恢复
- fushi/lib/src/media/manga/reader/manga_fushi_page.dart:2755-2779 本地卷从 ReaderPositionRepository.findByBookUid 恢复；:3014-3024 书架章从 getMangaChapterState + resolveMangaChapterResumePoint 恢复，两条恢复判据互不相干
- fushi/lib/src/media/manga/reader/manga_fushi_page.dart:6900-6925 _persistPosition 在一个事务里先写书级（页码当 sectionIndex）再写章级（BUG-5358 补的原子性）；:4438-4460 _saveCurrentChapterState 又是只写章级的第二个入口
- fushi/lib/src/sync/interconnect_book_progress_sync.dart:140-146 hostBookKeyOf 用 raw['chaptered'] 把章节式漫画排除出书级同步；fushi/lib/src/sync/interconnect_manga_chapter_sync.dart:46-53 用同一个字符串旗标做反向判定，是第二套 key 换算
- docs/bugs/BUG-5352 / BUG-5358 / BUG-5359 / BUG-3371 / BUG-3246 / BUG-1924：键不一致、两表写入不原子、对比弹窗对章节式行抛异常、云通道把漫画按 EPUB 字符表折算成第 1 页、直接开书没走续读判据，根因都是同一份进度有两种表示

机制：漫画进度没有自己的模型：借了 EPUB 的 reader_positions（sectionIndex = 页码、charOffset = webtoon 千分比），后来加在线章节时又加了 manga_chapter_states。一本漫画的「当前位置」于是有两份真相，哪份算数取决于来源（本地卷还是书架在线条目、单卷还是 chaptered）。sync_manager、sync_compare_dialog、InterconnectBookProgressSync、InterconnectMangaChapterSync、Kavita sync、tracking 都得各自重新判一遍「这本漫画看哪张表」，判漏一处就出一个 BUG（5352 修了键，5358 修了原子性，5359 修了对比弹窗，3371 修了云通道）。

根本方案：漫画进度以 manga_chapter_states 为唯一真相源：本地卷视为「只有一章的作品」，章 key 取冻结的固定值（比如卷 bookKey 本身）；互联单卷、Kavita、Mihon 全部同构。新建 `MangaProgressStore`（fushi_engine 纯 Dart，读写都只经它），对外只给 `resume(bookUid)` 和 `save(bookUid, chapterKey, page, fraction, readAt)`。如果统计 / 首页继续阅读 / 旧 EPUB 通道仍需要书级 reader_positions，只由 save 在同一事务里派生写出，阅读器和同步方都不再直接写 reader_positions。同步统一走引擎已有的 `planMangaChapterStateSync`（按章 LWW），互联单卷与章节式合成一条通道，删掉 InterconnectBookProgressSync 里的漫画分支（hostBookKeyOf 的 chaptered 判定、_landInterconnectVolumeChapter）和 sync_compare_dialog 的 _rowSyncsBookProgress 特例；云通道导出 / 导入漫画只走章状态。存量本地卷做一次迁移：reader_positions 拷进 manga_chapter_states 的固定章 key。守卫：reader_positions 的写入点只允许出现在 MangaProgressStore 和 EPUB 阅读器里（源码守卫或把 Repository 构造器设为包内可见）；`raw['chaptered']` 收成 OnlineMangaLibraryEntry 的强类型字段。以后新增来源只需提供章 key，不用改任何同步方。

要动：fushi/lib/src/media/manga/reader/manga_fushi_page.dart；fushi/lib/src/sync/interconnect_book_progress_sync.dart；fushi/lib/src/sync/interconnect_manga_chapter_sync.dart；fushi/lib/src/sync/sync_compare_dialog.dart；fushi/lib/src/sync/sync_manager.dart；fushi/lib/src/media/kavita/kavita_manga_sync.dart；fushi/lib/src/media/collections/book_continue.dart；packages/fushi_engine/lib/sync/manga_chapter_progress_sync.dart；packages/fushi_core/lib/src/database/database_content_misc.part.dart

核验说明：已验证：manga_fushi_page.dart:2563-2573 的注释写明 initialPage 非空时走章级、为 null 时走书级（BUG-1924）；:6900-6925 _persistPosition 在一个事务里先写书级 reader_positions（sectionIndex=page、charOffset=webtoon 千分比），再写 manga_chapter_states；interconnect_book_progress_sync.dart:143/643 和 interconnect_manga_chapter_sync.dart:49 用同一个 raw['chaptered'] 字符串旗标做正反两次判定，:136-139 的注释也承认 reader_positions 不带章身份。book_continue.dart:24/273 还得另写一个 mergeMangaChapterReadRecency，把两张表的时间取大。「同一份进度有两种表示」这个判断成立。

方案风险：1）wire 兼容：单卷互联条目现在用对端键、按书级 reader_positions 和 host 同步（hostBookKeyOf 单卷分支）。host 可能是旧版 app 或 fushi_server，只认书级行。把单卷并进章级通道以后，新旧两端之间的进度就断了，方案里没有协议版本协商和双写过渡期。2）云同步、备份导出的旧客户端同样只读 reader_positions。3）方案说「需要时由 save 派生写出 reader_positions」，那书级行仍是一份可以被同步方从外部改写的副本，如果不同时禁止同步方直接落地书级行，又会回到两份真相。4）docs/specs/2026-09-12-manga-download-first-design.md 第 8 条拍板过「manga_chapter_states(bookUid, chapterKey) 零迁移、bookKey/uid 不变」，新方案给本地卷造固定章 key 并做迁移，属于对已拍板设计的变更，要过拍板台。5）把旗标做成 OnlineMangaLibraryEntry 的强类型字段时，raw 里的 'chaptered' 是冻结的 wire/持久化名，只能改读取方式，不能改名。

修正后的方案（以此为准）：保留「章状态是唯一真相源 + MangaProgressStore 单一读写口」这个方向，补三处：① 协议层加能力位（或协议版本）。对端声明支持章级进度时，单卷走章通道；不支持时仍按书级 reader_positions 同步，书级行只由 MangaProgressStore 从章状态派生写出，同步方落地书级行也必须经 Store 反向写章状态，不准直接写表。② 迁移改成惰性：读不到章状态时从 reader_positions 补出来再写回，不做一次性批量迁移，旧行保留到所有对端都升级。③ 本地卷用哪个固定章 key、要不要改那条「零迁移」拍板，先写进拍板台。

## manga-reader-god-state

**manga_fushi_page.dart 是 1 万行的上帝 State：换章 / 窗口文档 / 直读生命周期靠散落的 bool 和逐 await 复检，同一类竞态反复出 bug**

- 类型：上帝对象；规模 XL；价值 high；不改外部行为
- 核验：成立

证据：

- fushi/lib/src/media/manga/reader/manga_fushi_page.dart:1350 起，State 有 114 个字段，其中 36 个 bool 状态位（_switchingChapter、_navigating、_chapterNotDownloaded、_streamingChapter、_volumeOcrQueued、_volumeOcrNoEngine、_streamOcrBusy…）；全文 52 处 `if (!mounted) return`
- fushi/lib/src/media/manga/reader/manga_fushi_page.dart:3033-3052 直读失败时在一个 setState 里手工复位 _payload / _readAloud / _volumeOcrQueued / _volumeOcrNoEngine / _chapterNotDownloaded，换章要清哪些状态全靠逐个记住
- fushi/lib/src/media/manga/reader/manga_fushi_page.dart:3892/3945 用 _navigating 当导航锁，:4379/4433 用 _switchingChapter 当换章锁，两把锁之间没有结构关系；manga_window_load_gate.dart 是后来补出的第三把锁（代次凭据）
- fushi/lib/src/media/manga/reader/manga_fushi/read_aloud.part.dart:446 part 文件经 `_s._pageSession` 直接读宿主私有字段，6 个 part 共 2102 行都这样伸手
- docs/bugs BUG-1153 / 1170 / 1171 / 2884 / 3221 / 3222 / 5495 / 2101 / 1758：旧代窗口回调解开新锁、dispose 后写 notifier、换章不重装文档、换章期间排队步数落到新章、上一章闪第 0 页、就绪等页图，全是「旧章 / 旧窗口的异步尾巴改了新状态」

机制：「当前打开的是哪一章、哪一份窗口文档、哪一个页会话」没有建模成对象，而是散成几十个可变字段挂在同一个 State 上。换章 = 原地改字段，每段 async 链都要自己在每个 await 之后复检代次 / mounted / 锁。每修一个竞态就多一个 bool 或一张闸门（MangaWindowLoadGate、MangaTurnQueue.clear、_sourceLocatorApplied、_disposedDuringSourceReview），结构本身没变，下一条竞态照样写得出来。

根本方案：把阅读器拆成三层不可变会话对象，交给一个纯 Dart 控制器（ChangeNotifier 或 stream，不依赖 Widget）：① `MangaChapterSession`，一章一个实例，持 payload、spreads、MangaReaderSession、chapterKey、OCR 观察者，`close()` 一处释放；② `MangaWindowDocument`，一次 loadData 一个实例，持 generation、ready Completer、keptSpreads；③ `MangaReaderController`，持当前 ChapterSession 和导航状态机（enum：idle / loadingWindow / switchingChapter / failed），所有翻页输入都经它，按状态决定丢弃还是排队。换章就是新建 session、关掉旧 session，旧 session 的回调靠 identical(session, current) 天然失效，不再需要逐 await 复检和逐字段复位。State 只做装配和 build。OCR（整卷 / 流式）、超分、朗读、Kavita、companion 这些 part 改成持 controller 引用的独立组件，不再经 `_s.` 读私有字段。删掉 _switchingChapter / _navigating / _chapterNotDownloaded / _streamingChapter 等 bool，以及 manga_window_load_gate 外部的锁逻辑。守卫：控制器状态机用 sealed class 表达，非法组合（比如 switching 时还有 pending turn）在类型上就构造不出来；单测直接驱动控制器，不用起 WebView。新增来源或功能只加一个持 controller 的组件。

要动：fushi/lib/src/media/manga/reader/manga_fushi_page.dart；fushi/lib/src/media/manga/reader/manga_fushi/*.part.dart；fushi/lib/src/media/manga/reader/manga_window_load_gate.dart；fushi/lib/src/media/manga/reader/manga_jump_history.part.dart；fushi/lib/src/media/manga/reader/manga_reader_stream_ocr.dart；fushi/lib/src/media/manga/reader/manga_reader_auto_ocr.dart

核验说明：已验证：文件 10257 行；_persistPosition 和 _loadLocalPayload 的注释里，章级 / 书级、换章复位的分支都是手工维护的。BUG 簇（窗口代次、换章尾巴）与「换章是原地改字段」的结构对得上。114 个字段、36 个 bool 的具体数目没有逐个数，属推测，但量级可信。

方案风险：拆成控制器时要把 MangaWindowLoadGate 的代次凭据语义收进 MangaWindowDocument，不能删掉了事，旧窗口回调正是靠它失效的。part 文件里有焦点、快捷键相关逻辑（见 focus-ownership.md），迁移时焦点所有权不能散。XL 规模需要分期，每期都要在 paginated / webtoon 模式下做真机复测。

## ocr-engine-pipeline-per-engine-copy

**5 个 OCR 引擎各写一套整卷流水线和逐页缓存（两种格式），引擎身份散在 3 个 enum、字符串字面量和前缀常量里，缓存恢复靠手维护的表**

- 类型：缺单一登记源；规模 L；价值 high；改持久化 / wire
- 核验：部分成立

证据：

- fushi/lib/src/media/manga/manga_ocr_job_stream.dart:169-240（local）/ :306-345（lens）/ :400-430（system）：三段都是 enumerate 页 → 拼 `_pages/<签名>` 目录 → !onlyMissing 时丢缓存 → 逐页读缓存、整卷命中就回放 → 写 manga.json 并手写 engine 字符串；system 那段不处理 onlyMissing 丢缓存，三段行为已经开始不一致
- packages/fushi_engine/lib/ocr/manga_ocr_folder_job.dart:258-325 的 MangaOcrFilePageCache 按页名 + size + mtime 认页；fushi/lib/src/media/manga/ocr/google_lens_ocr_service.dart:438-547 的 GoogleLensPageCache 用页号命名文件（`000001.json`），每次 read 都要 statSync 算指纹（:541-547，主 isolate 上同步 IO）
- fushi/lib/src/media/manga/ocr/manga_ocr_cache_recovery.dart:15-29 kMangaOcrPageJsonCachePrefixes 注释自己写着「新增一个写这种逐页缓存的引擎时在这里加一行；漏了……（BUG-4827）」
- 引擎身份：fushi/lib/src/media/manga/ocr/manga_ocr_engine.dart:3-87 有 MangaOcrEngineId 和 MangaOcrEnginePreference 两个 enum 外加字符串映射；fushi/lib/src/ocr/screen_ocr_engine.dart:27-29 又有一套；manga_ocr_job_stream.dart:232/337、google_lens_ocr_service.dart:289、system_ocr_manga_service.dart:316、manga_ocr_folder_job.dart:99/567 手写 'local_onnx' / 'google_lens' / 'system_ocr'
- docs/bugs BUG-1173 / 1151 / 2519 / 3333 / 4815 / 4817 / 4827 / 1851：缓存签名不含模型身份、恢复漏引擎、Lens 补缺冒名采用别家页、取消写出假整卷、续传 mtime 永远对不上、onlyMissing 没人消费，都出在「每个引擎自己管缓存和产物」

机制：OCR 抽象只到「识别一页」这一层，没有覆盖「整卷任务」。缓存键、缓存格式、取消语义、onlyMissing、整卷命中探测、manga.json 署名、重开恢复都由各引擎复制实现，引擎身份也没有单一登记源。新增或修改一个引擎要同步改 job_stream 的分支、recovery 前缀表、metadata 字符串、settings / wizard 的 switch，漏一处就出一条缓存身份 bug。

根本方案：在 fushi_engine 新建一个与引擎无关的 `MangaOcrVolumeRunner`，独占整卷任务的全部共性：枚举页、`PageCacheKey`（页名 + 内容哈希或 size，不用 mtime，顺带根治 BUG-4817）、唯一一种逐页缓存格式（`MangaOcrPageCacheStore`，记录引擎描述符 + 签名）、onlyMissing / 重跑语义、取消时不写 manga.json、整卷完成后原子写 manga.json、重开恢复（直接枚举所有缓存目录，读目录里的描述符，不再按前缀猜）。各引擎只实现 `OcrPageEngine { MangaOcrEngineDescriptor get descriptor; Future<OcrPageResult> recognize(PageInput) }`。描述符是唯一登记源：sealed 的 `MangaOcrEngineDescriptor`，带 id、wire 名、签名构造、能力探测、是否逐页、所需模型。MangaOcrEnginePreference / ScreenOcrEngine 的字符串映射、kMangaOcrPageJsonCachePrefixes、各处 'local_onnx' 字面量都从它派生或删除。删掉 manga_ocr_job_stream.dart 里的 mangaOcrLocalEvents / LensEvents / SystemEvents 三份复制、GoogleLensPageCache、manga_ocr_cache_recovery 的前缀表。Lens / 系统 OCR 的识别实现仍留在 app 层（依赖平台通道），以 OcrPageEngine 注入，fushi_server 也能复用同一个 runner。以后新增引擎只写一个描述符加一个 recognize。旧缓存目录名属冻结持久化名，runner 读旧格式只做一次性迁移。

要动：packages/fushi_engine/lib/ocr/manga_ocr_folder_job.dart；packages/fushi_engine/lib/ocr/manga_ocr_service_impl.dart；fushi/lib/src/media/manga/manga_ocr_job_stream.dart；fushi/lib/src/media/manga/ocr/google_lens_ocr_service.dart；fushi/lib/src/media/manga/ocr/system_ocr_manga_service.dart；fushi/lib/src/media/manga/ocr/manga_ocr_cache_recovery.dart；fushi/lib/src/media/manga/ocr/manga_ocr_engine.dart；fushi/lib/src/ocr/screen_ocr_engine.dart；fushi/lib/src/media/manga/manga_ocr_engine_probe.dart；fushi/lib/src/media/manga/manga_ocr_wizard_dialog.dart

核验说明：成立的部分：manga_ocr_job_stream.dart 里 local / Lens / System 三段的编排确实重复（:306-330 和 :398-425 结构同构，System 的注释自己就写着「编排与 Lens 同构」）；manga_ocr_cache_recovery.dart:15-24 的前缀表就是手维护的登记表，注释也点名了 BUG-4827；GoogleLensPageCache 的 _fingerprint 每次调用都会 statSync（google_lens_ocr_service.dart:541-547）。不成立的部分：「system 那段不处理 onlyMissing，行为已经不一致」只对了一半。onlyMissing 已经传给 systemOcrRunner.ocrFolder（job_stream:421），system_ocr_manga_service.dart:231 在 onlyMissing 为 false 时不读缓存、逐页重识别并覆盖。差别只在旧缓存不会被预先清掉：重新识别中途取消时，未覆盖的旧页会在重开时被恢复。「主 isolate 上同步 IO」没有核实这条 stream 跑在哪个 isolate（事件类型名叫 MangaOcrBackgroundEvent），属推测。

方案风险：1）用内容哈希当 PageCacheKey，每次命中探测都要整页读文件算哈希，整卷几百页、反复探测时会比 stat 贵得多。size+mtime 是有意的廉价指纹，BUG-4817 的根因应先查清是 mtime 在哪条路径上被改了（解压、复制），再决定换不换键。2）旧缓存目录名（带版本号前缀）和 manga.json 里的 engine 署名字符串（'local_onnx' / 'google_lens' / 'system_ocr'）是冻结的持久化名，描述符必须原样产出这些字面量，不能改。3）fushi_server 复用 runner 时，Lens / 系统 OCR 在服务端不可用，描述符的能力探测要能表达「本 host 不支持」。

修正后的方案（以此为准）：保留 MangaOcrVolumeRunner + 描述符单一登记源这一部分。页键保留 relativeUrl+size+mtime，另加一个可选的内容哈希，只在 size 相同而 mtime 变了时才算，用来消除 BUG-4817 那类误判，不要每页每次都算哈希。重新识别（onlyMissing=false）时，所有引擎统一在 runner 里先清掉本引擎的缓存目录。描述符的 wire 名固定为现有的冻结字面量。

## onnx-two-backends-plugin-patch-stack

**ONNX 推理两套后端：app 用带 19 个补丁的 MethodChannel 插件（五端各一棵原生树），服务端已有 dart:ffi 后端**

- 类型：补丁叠补丁；规模 L；价值 high；不改外部行为
- 核验：部分成立

证据：

- fushi/pubspec.yaml:233 依赖 flutter_onnxruntime；fushi/lib/src/onnx/onnx_inference_ort.dart:1-60 是插件薄封装（EP 映射 + 张量转换），OCR 与 ASR 共用
- packages/fushi_server/pubspec.yaml:44-58 注释写明服务端 OCR / ASR 都用 fushi_asr_onnx_ffi（纯 Dart FFI 的 ORT，CPU / CUDA / DirectML），「app 侧不引 fushi_asr_onnx_ffi（Flutter 端走 flutter_onnxruntime 插件后端）」；packages/fushi_server/lib/src/ocr_session_factory.dart:1-60 为了在 FFI 后端补一个插件后端有的 resolveInputs 钩子，又另写了一层装饰器
- third_party/flutter_onnxruntime/PATCHES.md（462 行）:190「re-apply deltas #1–#19」，Windows 树带 delta 6–11、13、16，靠 onnxruntime_*_guard_test 守着重 vendor 不丢补丁
- docs/bugs/BUG-5508：Android 上张量经 StandardMessageCodec 在 Java 堆里存 2～5 份导致 OOM，修法是 delta 19 加 JNI 地址通路，相当于在插件里手工补出了一条 FFI；BUG-1149 / 1163 / 1968 / 2034 / 2050 是 DirectML provider 的探测、回退、错误码与 UTF-8 问题，都修在插件那一层

机制：一开始选了 MethodChannel 插件当推理后端，大块张量于是要跨平台通道、每个平台一套原生实现（Kotlin / Swift / C++）。后续的性能和 provider 问题只能逐平台改 vendored 插件，补丁越叠越多（19 个），还要守卫测试防止升级时丢失。服务端出于需要又引了 FFI 后端，同一个 OnnxSession 抽象于是有两份实现，行为差异（输入名对齐、provider 回退）要两边各补。

根本方案：app 也统一走 dart:ffi 直连 ORT C API 的单一后端（复用 fushi-subtitles 的 asr_onnx_ffi；如果 archive 版本约束挡路，先在上游解耦，ASR 算法本身不在本仓改）：张量在 Dart malloc / TypedData 与 ORT 之间零拷贝，大调用放后台 isolate，符合「FFI 大块传指针」的规则。移动端打包官方 onnxruntime 动态库（Android AAR 里的 libonnxruntime.so、iOS xcframework），开 CoreML / NNAPI EP；provider 探测、回退和错误码统一写在 FFI 层一处。输入名对齐（resolveOcrSessionInputs）放进共享工厂，删掉 server 的 OcrInputResolvingSessionFactory 装饰器。删除 third_party/flutter_onnxruntime 整棵目录、PATCHES.md、onnx_inference_ort.dart、ocr_inference_ort.dart 的插件分支和对应守卫测试。以后新增 EP 或改回退只改 FFI 层一处。需要先验证（推测）：iOS / Android 上直接 dlopen ORT 并启用 CoreML / NNAPI 在 App Store 合规和包体上可行。

要动：third_party/flutter_onnxruntime/；fushi/lib/src/onnx/onnx_inference_ort.dart；fushi/lib/src/ocr/ocr_inference_ort.dart；fushi/lib/src/asr_host/gpu_acceleration.dart；packages/fushi_server/lib/src/ocr_session_factory.dart；fushi/pubspec.yaml；fushi/test/onnx/

核验说明：已验证：packages/fushi_server/pubspec.yaml:44-49 的注释写明 app 用 flutter_onnxruntime 插件，服务端用 fushi_asr_onnx_ffi，并提到 archive 约束要靠 dependency_overrides 处理；PATCHES.md 有 462 行。两套后端加补丁栈的事实成立。但「移动端直接 dlopen ORT 并开 CoreML / NNAPI」的可行性、包体和合规，审计自己也标了推测，我也没有证据。

方案风险：1）asr_onnx_ffi 在上游 fushi-subtitles，按规则 ASR 相关改动要在上游做，archive 约束冲突要先在上游解。2）iOS 要自己打包 onnxruntime xcframework 并开 CoreML EP，Android 要打包带 NNAPI 的 so，这部分现在由插件的 Gradle / Pod 依赖代管，迁走后五端打包脚本、签名和 Android assembleRelease 都要重验。3）FFI 推理要在后台 isolate 跑才能不卡 UI，插件现在等于异步跑在平台线程上，迁移时漏了 isolate 会退化。4）删插件之前，DirectML 那几条 delta（BUG-1149/1163/1968/2034/2050 修的 provider 探测、回退、UTF-8 错误码）要逐条确认 FFI 层已有等价实现。

修正后的方案（以此为准）：方向保留。分两期：先在桌面端（Windows / Linux / macOS）把 app 切到 FFI 后端，对齐 DirectML 回退语义后删掉 Windows 树上的那批 delta；移动端先做包体 / 合规 / EP 可用性的实测验证，再决定迁不迁，验证通过前保留插件。

## manga-page-bytes-through-plugin-channel

**每张页图都由 Dart 读整文件、转码，再经 inappwebview 拦截回调整块过平台通道；页图 URL 身份靠查询串补丁防旧缓存**

- 类型：性能；规模 M；价值 medium；不改外部行为
- 核验：部分成立

证据：

- fushi/lib/src/media/manga/reader/manga_fushi_page.dart:3470-3582 _interceptRequest：pageSession.page() 或 File.readAsBytes() 读出整页字节，交给 _fitPageBytes 转码，再放进 WebResourceResponse.data 返回；Apple 端 :3638-3651 再包一层 CustomSchemeResponse
- fushi/lib/src/media/manga/reader/manga_fushi_page.dart:10018-10022 shouldInterceptRequest / onLoadResourceWithCustomScheme 都回到 Dart；Android 上这些字节经 MethodChannel 进 Java 堆（插件机制推断）
- fushi/lib/src/media/manga/reader/manga_fushi_page.dart:1160-1175 mangaImageUrl 注释：已下载章页名各章同形、响应带 max-age，所以要在 URL 上挂页会话代次 version 和卷身份 scope 才不复用旧章页图（BUG-2884 的补丁）
- docs/bugs/BUG-5495 备注：同一份日志里 Java OOM 发生在 StandardMessageCodec.readBytes（256 MB 堆）；BUG-5508 备注：崩溃日志里还有 inappwebview 2.4 MB 回包解码这个大户，修复没覆盖它

机制：WebView 拿页图的唯一来源是 Dart 拦截回调，所以每张原图 / 降采样 JPEG 都要从 Dart 堆拷进平台通道（Android 还要进 Java 堆），翻页高峰时多张并发。页图 URL 不是内容寻址，同名页在不同章 / 卷之间会撞缓存，只能在查询串里补 version / scope。性能结论来自代码路径推断加 BUG-5495 / 5508 的崩溃日志，没有专门的实测。

根本方案：页图改为从本机回环 HTTP 服务流式提供：一个 dart:io HttpServer 跑在后台 isolate，只绑 127.0.0.1，每次会话一个随机 token。URL 内容寻址，形如 `/p/<pageSessionId>/<pageIndex>?w=<fitWidth>&q=<quality>`，pageSessionId 由 MangaChapterSession 生成，天然区分章 / 卷，删掉 mangaImageUrl 里的 version / scope 补丁。服务端直接读文件或在线页缓存，用 fushi_compute 的 ffc_image_fit_jpeg 转码后写 socket，字节不经任何 MethodChannel。降采样 LRU（MangaPageFitter）随服务一起搬进后台 isolate，主 isolate 只发 URL。删掉 _interceptRequest 里的页图分支和 _loadMangaCustomScheme（Apple 端 WKWebView 对 http://127.0.0.1 子资源可以直接加载；若 ATS 限制，只需在 plist 里加 localhost 例外）。window 文档本身仍可用 loadData。以后加新的页来源（超分、在线页）只是服务里多一种 handler。

要动：fushi/lib/src/media/manga/reader/manga_fushi_page.dart；fushi/lib/src/media/manga/reader/manga_page_fit.dart；fushi/lib/src/media/manga/manga_overlay_html.dart；fushi/lib/src/media/manga/mihon/manga_page_provider.dart；fushi/lib/src/media/manga/reader/manga_fushi/upscale.part.dart

核验说明：问题部分成立：_interceptRequest 读出整页字节放进 WebResourceResponse.data，manga_fushi_page.dart:1160-1171 的注释也确认 version / scope 查询串是为防止 WebView 复用旧缓存补上的。但根本方案有硬伤：窗口文档用 loadData，baseUrl 是 https://kMangaHost/（:3917-3919），页面脚本在 manga_overlay_html.dart:1578 对页图做 ctx.getImageData。如果改成从 http://127.0.0.1 取子资源，一是 https 源加载 http 子资源会被 Android WebView 默认的 MIXED_CONTENT_NEVER_ALLOW 拦掉，二是跨源图片会污染 canvas，getImageData 直接抛 SecurityError。性能结论本身也只是推断，没有实测。

方案风险：方案会破坏 canvas 像素读取（:1578）和 https 源下的子资源加载，还需要 Android cleartext network_security_config 和 iOS ATS NSAllowsLocalNetworking 两处平台配置。Android 上任何本机 app 都能连 127.0.0.1 的端口，只靠 token 防护，攻击面比拦截器大。

修正后的方案（以此为准）：先实测（Android 真机翻页高峰时的 Java 堆和通道字节量），再定方案。如果确实要绕开通道：要么让窗口文档本身也从同一个回环源（http://127.0.0.1:<port>/?token=…）加载，保证同源，再补齐 cleartext / ATS 配置；要么留在拦截器里，但只回降采样后的小 JPEG，并按 pageSessionId 做内容寻址的 URL（这一点与 god-state 方案的 MangaChapterSession 一起做），以此消掉 version/scope 补丁。两种都不能让页图跨源。

## pdf-raster-dart-ui-app-only

**PDF 转漫画在 UI isolate 上逐页渲染并用 dart:ui 编 PNG：慢、页图体积大，且引擎和服务端都用不了**

- 类型：性能；规模 M；价值 medium；用户可见
- 核验：部分成立

证据：

- fushi/lib/src/pdf/pdf_engine.dart:135-200 renderPagePng：pdfrx 渲染出 BGRA 后经 ui.ImmutableBuffer → ImageDescriptor → Codec → Image.toByteData(png) 编码，依赖 dart:ui 和 Flutter 引擎
- fushi/lib/src/media/manga/book_format_rebuild.dart:336-362 _rasterizePdfPages 串行 for 循环逐页渲染、按 1600 宽（:55）存成 PNG，没有并发，也不在后台 isolate
- packages/fushi_server/lib/src/commands/import_commands.dart:17-19「引擎没有纯 Dart 的 PDF 导入（PdfImporter 靠 pdfrx 插件栅格化封面）」，PDF 一律报 unsupportedOnThisHost
- packages/fushi_compute/lib/src/image/fushi_compute_image.dart 已导出 ffc_image_rgba_fit_jpeg / ffc_image_bgra_to_rgba8_inplace / ffc_image_to_jpeg，原生编码能力早就有，PDF 路径没用上

机制：PDF 栅格化挂在 Flutter 插件和 dart:ui codec 上，没有下沉到纯 Dart 加 FFI 的引擎层。结果是导入时整本 PDF 在 UI isolate 上串行编 PNG（漫画页是照片类内容，PNG 体积通常是 JPEG 的数倍，属推测），fushi_server 和 fushi_engine 也拿不到这项能力，只能写 unsupported。

根本方案：在 fushi_compute（Rust）里加 pdfium 绑定，或至少让引擎直接 FFI 调用 pdfrx 自带的 libpdfium：给一个粗粒度命令 `ffc_pdf_rasterize(path, width, quality, outDir, progressPort)`，Rust 侧多线程逐页渲染并用已有的 JPEG 编码直接落盘，只经 dart_port 回报进度。PdfImporter 的封面、book_format_rebuild 的 PDF → 漫画、pdf_text_layer_backfill 都改调这个命令，放进 fushi_engine 让 fushi_server 共用，删掉 PdfEngine.bgraToPng 这条 dart:ui 编码链。已导入卷的 page_*.png 文件名属存量，不改；新导入的页可以写 .jpg（manga.json 里的 url 本来就按文件名记）。以后新增 PDF 衍生功能只调这一个命令。

要动：fushi/lib/src/pdf/pdf_engine.dart；fushi/lib/src/pdf/pdf_importer.dart；fushi/lib/src/media/manga/book_format_rebuild.dart；fushi/lib/src/media/manga/pdf_text_layer_backfill.dart；native/fushi_compute/src/；packages/fushi_compute/lib/src/；packages/fushi_server/lib/src/commands/import_commands.dart

核验说明：已验证：pdf_engine.dart 用 ui.ImmutableBuffer → ImageDescriptor → Codec → toByteData(png) 编码；book_format_rebuild.dart:336-362 串行逐页渲染并写出 page_*.png；服务端回 unsupported。但「在 UI isolate 上渲染」说重了：pdfrx 2.x 的 pdfium 调用在它自己的 worker 里跑，dart:ui 编码在引擎线程上完成，UI isolate 主要只是在 await。另外 fushi/pubspec.yaml:188-190 说明 pdfrx 钉在 2.4.5，pdfrx_engine 本身就是不依赖 Flutter 的纯 Dart FFI pdfium 绑定，所以不需要新写 Rust pdfium 绑定。

方案风险：在 Rust 里另起一份 pdfium 绑定，会和 pdfrx 自带的 libpdfium 形成两份 pdfium 动态库，打包和符号冲突都是风险。新导入的页改写 .jpg 是用户可见的产物变化（体积、画质），OCR 缓存指纹按 relativeUrl 记，不影响旧卷。

修正后的方案（以此为准）：引擎层直接依赖 pdfrx_engine（受版本钉约束的话，先解开 archive / image 的约束），渲染出 BGRA 后用 fushi_compute 已有的 ffc_image_bgra_to_rgba8_inplace + JPEG 编码落盘，放进 fushi_engine，app 和 fushi_server 共用，删掉 dart:ui 编码链。并发度按页面数和内存设上限。确实需要原生多线程整本渲染时，再评估把它下沉到 Rust。

## manga-js-bridge-untyped

**阅读器与页面 DOM 之间是无类型桥：4000 行 Dart 字符串里定义 25 个 window 钩子，宿主用 32 处拼 JSON 的 evaluateJavascript 调用它们**

- 类型：其他；规模 L；价值 medium；不改外部行为
- 核验：成立

证据：

- fushi/lib/src/media/manga/manga_overlay_html.dart（4014 行）里定义了 25 个 `window.__manga* =` 钩子；manga_bubble_focus_js.dart / manga_bubble_zoom_js.dart 另有 7 个
- fushi/lib/src/media/manga/reader/manga_fushi_page.dart:4485-4510 _replaceSpreadOcr 用 jsonEncode 拼出整段 JS，按字符串调用 `window.__mangaBubbleZoomClose`、`__mangaTextStripRefresh`；全文共 32 处 evaluateJavascript
- fushi/lib/src/media/manga/reader/manga_fushi_page.dart:5292-5300 / 7754-7760 / 7864-7868 / 7962-7968：JS → Dart 的回调各自 jsonDecode 再手工 `decoded['visiblePages']`，没有共享的消息类型
- BUG-5495 的就绪信号、BUG-3222 的首帧 transform 都要靠 node 跑真实脚本的测试和源码守卫来钉住「JS 里确实有这个钩子 / 这个调用」

机制：页面脚本是 Dart 里的字符串模板，两端契约（钩子名、参数形状、回调 payload）没有任何类型或单一定义，改一端时另一端只能靠搜索字符串去对；因此每次行为修复都得配一条源码守卫或 node 脚本测试来证明桥没断。

根本方案：把页面脚本搬成真正的资源文件（`fushi/assets/manga_reader/*.js`，像 assets/lnreader 那样），定义一个版本化的消息协议：Dart 端一份 sealed `MangaDocCommand` / `MangaDocEvent`（含 toJson / fromJson），JS 端只暴露一个入口 `window.__manga.dispatch(cmd)` 和一个回调 handler `onMangaEvent`。宿主只调 `_doc.send(MangaDocCommand.replaceOcr(...))`，32 处拼串的 evaluateJavascript 和各回调里的手工 jsonDecode 都删掉。用一份共享 schema（或 Dart 生成的 JS 常量表）保证两端命令名一致，替掉现在逐钩子的源码守卫。以后新增页面能力只是加一个 Command / Event 变体，漏处理会被 sealed switch 的穷尽检查报出来。宜与 manga-reader-god-state 的 MangaWindowDocument 一起做。

要动：fushi/lib/src/media/manga/manga_overlay_html.dart；fushi/lib/src/media/manga/manga_bubble_focus_js.dart；fushi/lib/src/media/manga/manga_bubble_zoom_js.dart；fushi/lib/src/media/manga/reader/manga_fushi_page.dart；fushi/lib/src/media/manga/reader/manga_fushi/*.part.dart

核验说明：已验证 manga_overlay_html.dart 有 4014 行，宿主侧确实用拼串的 evaluateJavascript 和手工 jsonDecode。32 / 25 这两个计数没有逐个核对。结论与仓库现状一致：现在这条桥靠 node 测试加源码守卫钉住。

方案风险：HTML 模板里可能插着运行时值（主题、l10n、设置），搬成静态 assets 后，这些值要改成初始化命令下发，否则首帧会闪。现有的 node 测试和守卫要迁到新的 dispatch 协议上，不能先删后补。

## nfkc-multiple-partial-copies

**NFKC 正规化有一份 4937 行的手写 Dart 常量表和三份「近似 NFKC」小映射，各写一套**

- 类型：缺单一登记源；规模 S；价值 low；不改外部行为
- 核验：成立

证据：

- fushi/lib/src/ocr/gal_lookup_ocr_unicode.dart:1-30 是 part 文件，整份就是 Unicode 15 NFKC 标量映射常量表（_ocrNfkcScalars），只在 fushi/lib/src/ocr/gal_lookup_calibration_ocr.dart:356 用到一次
- packages/fushi_engine/lib/leaderboard/work_refs.dart:29「这是 NFKC 在书名场景里最常见的一部分，不是完整 NFKC」
- fushi/lib/src/mining/galgame_text_process.dart:803「不是完整的 Unicode NFKC（Dart 标准库没有……）」；fushi/lib/src/utils/misc/collection_exporter.dart:575「不依赖 NFKC，用确定的小映射」

机制：Dart 标准库没有 String.normalize，各子系统需要时就各自手写一份局部映射，或者整表打进 Dart 源码。没有共享的正规化原语，口径（全角 / 半角、合成规则）各处不同，表也无法跟着 Unicode 版本统一升级。

根本方案：在 native/fushi_compute 加一个 `ffc_text_nfkc(utf8 ptr, len) -> utf8` 命令（基于 unicode-normalization crate，批量接口一次传整段文本，不逐字符跨边界），packages/fushi_compute 暴露 `nfkc(String)`。gal_lookup 校准 OCR 改用它，删掉 gal_lookup_ocr_unicode.dart 整个 part。work_refs / galgame_text_process / collection_exporter 的近似映射：经确认需要完整 NFKC 的改调它，刻意只要子集的保留，但把子集表收进 fushi_engine 的单一模块并写明与 NFKC 的差异。以后有新的正规化需求只调这一处。

要动：fushi/lib/src/ocr/gal_lookup_ocr_unicode.dart；fushi/lib/src/ocr/gal_lookup_calibration_ocr.dart；native/fushi_compute/src/text.rs；packages/fushi_compute/lib/src/；packages/fushi_engine/lib/leaderboard/work_refs.dart；fushi/lib/src/mining/galgame_text_process.dart；fushi/lib/src/utils/misc/collection_exporter.dart

核验说明：已验证：gal_lookup_ocr_unicode.dart 有 4937 行，只被 gal_lookup_calibration_ocr.dart 引用；native/fushi_compute 里 grep 不到 nfkc，没有现成原语；几处近似映射的注释也属实。价值低的判断合理。

方案风险：校准 OCR 的结果可能依赖固定的 Unicode 版本（注释写的是 Unicode 15），换成 crate 后要钉住 Unicode 版本，并用现有表做一次等价对拍。work_refs 是排行榜 / 书名键，口径一变已有的键就对不上了，只能保留子集，不能升级成完整 NFKC。

## 核验补充（审计漏掉的）

- 页图供给与 OCR 像素读取耦合在同一源上：manga_overlay_html.dart:1578 用 ctx.getImageData 读页图像素，窗口文档的 baseUrl 是 https://kMangaHost/（manga_fushi_page.dart:3917-3919）。页图来源的任何改造都受同源与 canvas 污染约束，审计的性能方案没有识别出这条约束。
- OCR 重新识别时清缓存的语义在引擎间不一致：Lens 在 job_stream:320 预先 discardMangaOcrPageCache，System 只在 runner 内不读缓存（system_ocr_manga_service.dart:231），旧页缓存残留。重新识别中途取消后重开书，未覆盖的旧页会被 manga_ocr_cache_recovery 当成本轮成果恢复回来。
- pdfrx 钉在 2.4.5（fushi/pubspec.yaml:188-190），起因是 >=2.4.6 经 pdfrx_engine→image 拉高 archive / xml 约束；fushi_server 的 fushi_asr_onnx_ffi 也有 archive 约束冲突（packages/fushi_server/pubspec.yaml:46-48）。archive 版本约束同时挡住了 PDF 下沉引擎和 ONNX 统一后端两条路线，应作为前置项先解，审计把它们当成独立问题。
- 进度方案与已拍板设计冲突：docs/specs/2026-09-12-manga-download-first-design.md 第 8 条拍板过 manga_chapter_states 零迁移、bookKey/uid 不变，审计的进度重构没有引用这份 spec，也没有把它列为待拍板事项。
