# 架构审计：reader

2026-11-28 只读审计 + 独立反驳核验的原始结论。总方案见 [../../specs/2026-11-28-architecture-redesign.md](../../specs/2026-11-28-architecture-redesign.md)。

## 现状

小说/EPUB 阅读器是一个约 3.3 万行的单一 State：reader_fushi_page.dart 有 6576 行，_ReaderFushiPageState 从 2055 行一直写到 6536 行，约 312 个字段；另有 17 个 part 文件以 `extension on _ReaderFushiPageState` 的形式直接读写这些私有字段，其中 chrome 5116 行、webview 3752 行、audiobook 2476 行、lyrics 2256 行、navigation 2090 行。正文渲染全在 WebView 内的 JS 引擎里完成，这些 JS 以 Dart 字符串的形式手写在 fushi/lib/src/reader/ 下：pagination 5401 行（内含 _sharedJs、分页 shell、连续 shell），VN 4164 行，selection 4669 行，caret 1253 行。三种 view mode 是三份各自实现的 shell，没有共同接口，VN 靠 21 个 `typeof vn.X !== 'function'` 补丁对齐。Dart↔JS 之间约 95 个 addJavaScriptHandler，全是位置参数加手写解析；Dart→JS 方向是几十个手拼的 `xxxInvocation()` 字符串，外面包一层 `typeof === 'function'` 守卫，缺方法时静默成 no-op。阅读位置没有单一所有者，_lastProgress* 被 5 个文件里约 12 处直接赋值，再靠 _restoreInFlight、_readerContentReady、_isNavigatingToChapter 三个布尔旗，加 JS 的 _reanchorPending、250ms 的 _reanchorClearedAt 时间窗和 8s 兜底超时互相兜着。「退出再进回章首 / 位置漂移」这一类问题至少有 BUG-210/418/587/2652/2744/3431/2399/2207 等 8 条以上。字符坐标有多套口径：学习单位、可匹配字符、UTF-16、去 ruby 纯文本、搜索文本、分数进度。这些口径在 Rust（fushi_compute）、JS（selection/pagination/VN/highlight_bridge）、Dart 里各实现一份。EPUB 解析在 fushi_engine，但书模型的回退构建、逐章字数、TOC 锚点、chaptersJson 回写写在页面文件里；解压目录内的越界路径解析在本域手抄了 7 份。跨章时引擎源码（约 145KB）每章 evaluateJavascript 一次，BUG-1140 实测 evalSetupScript 约 24ms，占遮罩总时长 101ms 的四分之一；其后还有 caret、有声书桥、高亮桥、高亮应用几次串行往返。

## reading-position-multi-owner

**阅读位置没有单一所有者：_lastProgress* 被 12 处直接写，靠布尔旗、时间窗、超时互兜，「回章首 / 位置漂移」成类复发**

- 类型：成类 bug；规模 L；价值 high；不改外部行为
- 核验：部分成立

证据：

- fushi/lib/src/pages/implementations/reader_fushi_page.dart:2270-2341,2643-2720：_readerContentReady / _restoreInFlight / _isNavigatingToChapter / _initialCharOffset(End) / _lastProgress{Section,Value,CharOffset} / _scrollProgressInFlight / _reanchorClearedAt / _contentReadyTimer 全是 State 上的散字段
- grep 结果：_lastProgressValue/_lastProgressCharOffset 在 chrome.part:3357,3396、navigation.part:551,691,977,1103,1467,1631,1757、seamless.part:111、webview.part:2501 等约 12 处被直接赋值，分布在 5 个文件
- navigation.part.dart:356-372：_handleReaderScroll 先过 readerScrollWithinReanchorSettle，在 250ms 时间窗内丢弃 scroll，再排一次补刷（BUG-2227 为这个时间窗打的补丁）
- navigation.part.dart:1406-1513：_refreshProgress 里叠着 _restoreInFlight/_lyricsMode 早退、JS 旗 _reanchorPending 早退返 null、图片页兜底、_cueOwnsReadingPosition 分叉（BUG-3431 的「位置有两个所有者」）、上升沿补推 inset 这几层
- chrome.part.dart:1595-1740：三条重锚路径（缩放 / 恢复 / 样式）各自手动在 commit 后打 _reanchorClearedAt；注释写明 TODO-797 就是因为恢复路径漏打这个时间戳，退出再进固定回章首
- chrome.part.dart:30-38：_paginationInFlight 由三个旗合成，注释写明内容就绪靠 8s 兜底超时强制置真
- docs/bugs/BUG-418、BUG-587、BUG-2652、BUG-2744、BUG-3431、BUG-2399、BUG-2207、BUG-210 的根因都是「谁有权写位置、哪个时刻的样本可信」没有结构上的保证

机制：阅读位置这个事实被拆成 Dart 镜像字段、JS 引擎内部状态和 DB 三处。哪个样本可信（恢复中、重锚中、settle 尾沿、跟读中、歌词中、旧文档晚到）没有统一建模，每条写入路径各自加门控。新增一种瞬态（换样式、缩放、迟到图片、跟读）就要在 N 处补一个旗或时间窗，漏一处就回章首。时间窗（250ms）和超时（8s）本身也属于根因修复原则禁止的「延迟掩盖」。

根本方案：在 fushi_engine 新建纯 Dart 的 ReadingPositionMachine（reducer 加 sealed 事件，不 import Flutter），作为位置的唯一所有者。
- 输入事件：NavigationStarted(gen, target)、RestoreCompleted(gen, anchor)、RestoreFailed(gen)、ReanchorBegan(gen, reason)、ReanchorSettled(gen)、ViewportSampled(gen, docId, start, end, progress)、CueSampled(cueId, range)、LyricsEntered/Exited、AppBackgrounded。
- 状态：idle / restoring(gen) / reanchoring(gen) / following(cue) / lyrics，外加当前权威锚 {section, charStart, charEnd, fraction}。
- 输出：PersistDecision 和 UiProgress。
- 判据：旧 gen 或旧 docId 的样本、非 idle 态的视口样本，在类型层面就进不了「可落库」分支；settle 由 JS 的 ReanchorSettled 事件驱动，删掉 _reanchorClearedAt 250ms 时间窗和 8s 兜底超时。
取代并删除：State 上的 _lastProgress*、_initial*、_restoreInFlight、_readerContentReady、_isNavigatingToChapter、_reanchorClearedAt、_scrollProgress*，readerScrollWithinReanchorSettle / readerScrollProgressRefreshAllowed / readerUiScale/Restore/StyleReanchorAllowed 等门控纯函数，以及三条重锚路径里手打的时间戳。
以后新增一种瞬态，只在机器里加一个状态或事件。位置相关的真值表测试直接测 reducer，不再用源码字符串守卫。

要动：fushi/lib/src/pages/implementations/reader_fushi_page.dart；fushi/lib/src/pages/implementations/reader_fushi/navigation.part.dart；fushi/lib/src/pages/implementations/reader_fushi/chrome.part.dart；fushi/lib/src/pages/implementations/reader_fushi/webview.part.dart；fushi/lib/src/pages/implementations/reader_fushi/seamless.part.dart；fushi/lib/src/pages/implementations/reader_fushi/audiobook.part.dart；fushi/lib/src/reader/reader_pagination_scripts.dart；packages/fushi_engine/lib/epub/（新增 reading_position_machine.dart）

核验说明：证据属实（已验证）：chrome.part.dart:1611-1619、1658-1669、1726-1733 三条重锚路径各自手打 `_reanchorClearedAt = DateTime.now()`；chrome.part.dart:37 和 reader_fushi_page.dart:505-519 确实有 8s 内容就绪兜底，而且已经为「抖动把兜底一直往后推」打过绝对截止时刻的补丁；所列 BUG-210/418/587/2207/2399/2652/2744/3431 文件都在。方向成立。夸大的地方：8s 兜底防的是 JS 永远不回报（加载失败、WebView 崩溃）时页面卡死，不能简单算作「延迟掩盖」；250ms 窗口也是 B-3 去抖，盖的是 JS 在 settle 尾沿真实发出的 scroll 事件。

方案风险：1）方案说删掉 8s 兜底，但没给替代：JS 永远不发 ReanchorSettled / RestoreCompleted（脚本异常、WebView 渲染进程被杀、onLoadStop 不来）时，状态机会永远卡在 restoring，翻页门控全锁。需要一个 WebView 生命周期事件（onRenderProcessGone / onLoadError / 引擎 install 抛错）驱动的 Failed 态，而不是直接删掉。2）250ms 窗口能删的前提是 JS 保证 settle 之后不再发属于重锚的 scroll，也就是 scroll 事件得带上重锚代次。这要和 bridge-no-protocol 的信封 gen 一起落地，单独做位置机删不掉这个窗口。3）架构规则写的是「Dart 不存镜像状态」：位置机放在 Dart（fushi_engine）里，权威位置其实仍在 JS 引擎里，Dart 机器持有的是采样决策，不是真值。要写明它只管「哪个样本可落库」，不复制 JS 几何状态，否则就和规则冲突。4）DB 里的 char_offset / norm_char_offset 两列冻结，PersistDecision 只能映射到这两列，不能改列。

修正后的方案（以此为准）：ReadingPositionMachine 照建（纯 Dart reducer），补三点：① 增加 EngineLost / LoadFailed 事件（来源是 onLoadError、onRenderProcessGone、引擎 install 异常回报），由它把 restoring / reanchoring 收进 failed→idle，取代 8s 定时器，不能只删不替；② JS 发出的 ViewportSampled 和 ReanchorSettled 必须带 navigationGeneration 加 reanchorSeq，机器按 seq 丢弃 settle 之前的样本，之后才删 250ms 窗口（依赖 bridge 信封，两条同批做）；③ 机器只负责「样本可信与否、落库决策」，权威几何仍在 JS，持久化照旧写 char_offset / norm_char_offset 两列。

## js-shells-no-contract

**三种 view mode 是三份互不约束的 JS shell：方法签名分叉、VN 靠 21 个 typeof 补丁，缺方法时静默 no-op**

- 类型：缺单一登记源；规模 L；价值 high；不改外部行为
- 核验：成立

证据：

- fushi/lib/src/reader/reader_pagination_scripts.dart:3925 分页 scrollToCharOffset(charOffset, hintScroll) 与 :4801 连续 scrollToCharOffset(charOffset, endCharOffset, hintScroll) 签名不同；restoreToCharOffset 在 :3749 和 :4887 也一样不同
- reader_pagination_scripts.dart:3531 / :4580 / reader_visual_novel_scripts.dart:3175：calculateProgress、restoreProgress 等同名方法在三个 shell 里各写一份
- reader_visual_novel_scripts.dart:3592「host-compat shims (TODO-909)」，从 :3610 到 :4117 共 21 处 `if (typeof vn.X !== 'function') vn.X = ...` 在事后补接口
- reader_pagination_scripts.dart:918-1045：每个 xxxInvocation 都手写 `typeof window.fushiReader.X === 'function' ? ... : -1/null` 兜底，缺方法时只会静默返回默认值
- reader_visual_novel_scripts.dart:100：VN shell 自己又复制了一份 readerRegexNegated/normalizeText，没有复用 _sharedJs
- BUG-2261（VN 没实现 beginStyleReanchor，样式 CSS 被丢）、BUG-2576（VN restoreProgress 不认 0.99 章末约定）、BUG-1688（VN updatePageSize 忽略入参）、BUG-1743（shell 缺 scrollToSearchMatch）、BUG-2468（两个 shell 的 setChromeInsets 各漏一半），全是「某个 shell 没跟上」
- fushi/test/reader/reader_style_reanchor_both_shells_guard_test.dart:48-88 用 `script.contains('beginStyleReanchor: function')` 字符串守卫来兜接口是否齐全

机制：三个 shell 之间只有一份「隐式接口」：Dart 侧的 invocation 字符串和宿主假设。没有任何结构在安装时或编译时校验每个 shell 实现了全部方法、语义一致。为了不崩，所有调用点都加了 typeof 守卫，结果缺实现从「报错」退化成「静默错行为」。修一个 shell 时其他 shell 没有义务跟上，于是同一机制按 shell 逐个出 bug，再逐个补 shim 和字符串守卫。

根本方案：1. 把 JS 引擎从 Dart 字符串里搬出来，作为真 JS 源（见 reader-engine-js-as-strings 那条），在 assets/reader_engine/ 下按「core + mode strategy」重组：
   - core 持有文本索引、锚点采样、重锚两阶段、chrome inset、迟到图片锚、搜索、高亮这些与模式无关的能力，只实现一次；
   - 三个 mode 模块（paged / continuous / vn）只实现一个很小的几何策略接口：pageExtent、scrollToEdge(charOffset)、currentWindow()、snap 等；
   - core 在 install 时用接口表逐项断言策略方法齐全，缺了就抛错，并走 onRestoreFailed 回报，不再静默 no-op。
2. 接口用一份 .d.ts（或 JSDoc @typedef）加 tsc --checkJs 在 CI 上类型检查。
3. Dart 侧把 viewMode 从字符串（reader_settings.dart:500-512）改成 ReaderViewMode 枚举，只在一处映射到 mode 模块名。
取代并删除：VN 的 21 个 host-compat shim，各 invocation 里的 typeof 兜底，VN 里重复的正则，以及 *_both_shells_guard 一类靠 contains 判接口的守卫。
以后新增一个阅读器能力：写在 core 里，或在策略接口上加一项，tsc 会让三个 mode 都必须实现。

要动：fushi/lib/src/reader/reader_pagination_scripts.dart；fushi/lib/src/reader/reader_visual_novel_scripts.dart；fushi/lib/src/reader/reader_seamless_chapters_script.dart；fushi/lib/src/reader/reader_settings.dart；fushi/test/reader/*_both_shells_guard_test.dart

核验说明：已验证：reader_visual_novel_scripts.dart 里 `typeof vn.X !== 'function'` 恰好 21 处，BUG-2261/2576/1688/1743/2468 都是「某个 shell 没跟上」这一类。typeof 兜底让缺方法退化成静默 no-op，属实。

方案风险：1）viewMode 改枚举时，偏好键 'view_mode' 和取值 'paginated' / 'continuous' / 'vn' 是冻结的持久化名（reader_settings.dart:500），只能在读写边界做字符串↔枚举映射，值不能变。2）引入 tsc / eslint / esbuild 会给 CI 和 bootstrap 加上 Node 工具链依赖，影响 setup_worktree 和 dist 测试机，需要先确认（属于范围扩大）。3）core 在 install 时断言缺方法就抛错，这只是把问题推到运行时；要 CI 阶段就抓住，得靠 tsc 的接口类型，或在 headless 测试里对三种 mode 各 install 一次。

修正后的方案（以此为准）：同原方案，补两点：ReaderViewMode 枚举在 ReaderSettings 的 getter / setter 处与冻结字符串 'paginated' / 'continuous' / 'vn' 双向映射；接口齐全性的守卫放进已有的 reader_headless_shell_dump_test，对三种 mode 各 install 一次并断言策略表齐全，这样不依赖 Node 也能先落地，tsc 作为可选的第二层。

## bridge-no-protocol

**Dart↔JS 桥没有协议定义：约 95 个位置参数 handler 手写解析，文档代次只有 3 处校验，歌词 WebView 又复制了一套 handler**

- 类型：缺单一登记源；规模 L；价值 high；不改外部行为
- 核验：部分成立

证据：

- fushi/lib/src/pages/implementations/reader_fushi/webview.part.dart:2507-2720：onTextSelected / onTap / onShiftHover / onRestoreComplete 等 handler 用 `args[0] as String`、`args.length >= 3 && args[2] == true`、`_toDouble(args[0])` 这类位置下标手工解析
- webview.part.dart:2585-2614：只有 onRestoreComplete/onRestoreFailed 用 readerReportedNavigationGeneration(args, 1) 校验文档代次；grep 全目录只有 3 处，onReaderScroll / onTap / onSeamlessChapterActivated 等都不带文档身份
- docs/bugs/BUG-2399-reader-chapter-stale-progress.md：JS 往返途中跨章，旧文档的偏移被按新章换算后落库；_syncPositionFromWebViewProgress、_reloadWithCurrentSettings 也消费没有身份校验的结果
- fushi/lib/src/pages/implementations/reader_fushi/lyrics.part.dart:1742-1835：歌词 WebView 又注册了 onTextSelected / onSelectionMenu / onShiftHover / onTapEmpty / onReaderMouseHoldRepeat；与正文那份相比少了 hoverLookupSettledInvocation 的显式背压释放（webview.part.dart:2515-2533），两份已经开始分叉
- fushi/lib/src/reader/reader_pagination_scripts.dart:901-1045：Dart→JS 方向是手拼字符串，返回值是 dynamic，再由 chrome.part.dart 里的 _didScroll/_didConsumePageTurn 猜语义（chrome.part.dart:30-46 注释写明「null 被 _didScroll 误读成页边界 → 跳两章」）

机制：桥两端的消息名、参数位置、返回值形状、文档代次都没有单一定义。JS 端 callHandler 的实参和 Dart 端的下标解析靠人工对齐，返回值靠 dynamic 猜。每新开一个 WebView 宿主（歌词、spread），就把一批 handler 复制一遍。「晚到的旧文档消息」只能逐个 handler 补代次校验，BUG-2399 之类按 handler 逐条复发。

根本方案：1. 定义单一的桥协议登记源：一个 Dart 文件里放 sealed class ReaderJsEvent，每种消息一个子类、字段有类型，外加 ReaderJsCommand / ReaderJsResult。由代码生成器同时产出：
   - Dart 侧的 decode/encode；
   - JS 侧的 `fushiBridge.emit(type, payload)` 和 `fushiBridge.call(cmd, args)` 薄封装（JSDoc 类型与 Dart 同源）。
2. 线上只保留一个 handler（如 'fushiBridge'），信封固定为 {type, docId, gen, payload}。信封层统一丢弃 gen/docId 失配的消息，旧文档晚到在结构上进不来。
3. Dart→JS 一律经 `callAsyncJavaScript('fushiBridge.call', {cmd, args})`，返回 typed Result（ok / limit / notReady），取代 _didScroll 猜 null。
4. 歌词、spread 等宿主共用同一个 ReaderBridgeRouter，只声明自己订阅哪些事件、带哪个前置条件（如 lyricsMode），不再复制 handler 体。
取代并删除：webview.part / lyrics.part / navigation.part 里约 95 个 addJavaScriptHandler，pagination_scripts 里约 30 个 xxxInvocation 字符串函数，readerReportedNavigationGeneration 的逐点调用。
以后新增一种消息，只在协议登记文件里加一个子类。

要动：fushi/lib/src/pages/implementations/reader_fushi/webview.part.dart；fushi/lib/src/pages/implementations/reader_fushi/lyrics.part.dart；fushi/lib/src/pages/implementations/reader_fushi/navigation.part.dart；fushi/lib/src/pages/implementations/reader_fushi/chrome.part.dart；fushi/lib/src/reader/reader_pagination_scripts.dart；fushi/lib/src/reader/reader_selection_scripts.dart；fushi/lib/src/media/audiobook/lyrics_mode_html.dart；fushi/lib/src/media/audiobook/highlight_bridge.dart

核验说明：机制成立（已验证）：readerReportedNavigationGeneration 只有 3 处调用（webview.part.dart:2585、2604、3135），其余 handler 都用位置下标解析。数字夸大：reader_fushi/ 目录里实际 addJavaScriptHandler 是 webview.part 31 个加 lyrics.part 15 个，共 46 个，不是约 95 个（整个 fushi/lib 是 146 个）。歌词分叉属实：lyrics.part.dart:1743-1760 的 onTextSelected 没有 webview.part.dart:2510-2533 那段 hoverLookupSettledInvocation 的显式背压释放，lyrics.part.dart:1780 的 onShiftHover 同样直接 `_selectTextAt(fromHover: true)`。

方案风险：1）JS→Dart 只留一个 'fushiBridge' handler 并强制信封 gen/docId，会影响 lyrics_mode_html.dart、highlight_bridge.dart 以及全局查词浮层等别的 WebView 宿主（全仓 146 个 handler），迁移范围要按全仓算，不能只算 reader_fushi/。2）Dart→JS 改用 callAsyncJavaScript：Windows / Linux 的 flutter_inappwebview 实现是否支持，要逐平台核实（未验证）。3）「代码生成器同时产出 Dart 与 JS」会引入新的生成步骤，和「生成文件不入库」的现有纪律（strings.g.dart 那种做法）一起考虑。

修正后的方案（以此为准）：保留单一协议登记源、信封 {type, docId, gen, payload} 和共享 ReaderBridgeRouter 这几项。Dart→JS 先统一成一个 `fushiBridge.call(cmd, argsJson)`，经 evaluateJavascript 返回 JSON 的 typed Result（各平台都可用），callAsyncJavaScript 等平台核实后再换。歌词宿主的 hover 背压缺失作为 bug 先单独修（共用 router 前就会挂住悬停查词），不要等重构。

## reader-state-god-object

**_ReaderFushiPageState 是约 3.3 万行、312 个字段的上帝对象：17 个 part 以 extension 互相伸手，进度一变整页 setState**

- 类型：上帝对象；规模 XL；价值 high；不改外部行为
- 核验：成立

证据：

- wc -l：reader_fushi_page.dart 6576 行，加 17 个 part 合计 26863 行；_ReaderFushiPageState 从 :2055 写到 :6536
- grep：reader_fushi_page.dart 里约 312 个 `_xxx` 实例字段；chrome.part.dart:30、navigation.part.dart:20、webview.part.dart:38、audiobook.part.dart:143、lyrics.part.dart:188 等都是 `extension _X on _ReaderFushiPageState`，直接读写彼此的私有字段
- reader_fushi_page.dart:2208-2211：part 改状态只能经 _rebuild → setState(fn) 这一个整页转发器；全目录 _rebuild 调用 70 余处
- navigation.part.dart:1530-1536：滚动进度（节流 50ms）一变就 `_rebuild(() { _progressCurrentChars = ...; })`，触发 :4788 那棵整页 build（含 LayoutBuilder、Actions、Focus、PopScope、WebView 子树、chrome），这部分是代码路径推断，未实测帧耗时
- chrome.part.dart（5116 行）同时装着翻页、三条重锚编排、选区操作条 widget（:4781 ReaderSelectionActionItem、:4800 ReaderSelectionActionBar）、收藏、样式热更新等互不相干的职责

机制：拆文件时只做了「按行数切 part」，没有切状态，所有子域仍共享同一个私有字段空间和同一个 setState。依赖关系不可见、无法单测，任何子域改字段都可能影响其他子域的门控（见 reading-position-multi-owner 那条）。UI 刷新也没有粒度，进度条、顶栏、浮球都靠整页重建。

根本方案：按子域拆成独立的 controller 对象，每个 controller 自己持有状态、对外暴露 ValueListenable 或 Riverpod provider，页面 State 只负责装配：
- ReaderNavigationController：章节、导航、代次，接 reading-position-multi-owner 那条的 ReadingPositionMachine；
- ReaderWebViewHost：桥路由、资源拦截；
- ReaderChromeController：已有 reader_chrome_controller.dart，继续扩；
- ReaderAudiobookCoordinator、ReaderLyricsController、ReaderSelectionController、ReaderMiningController。
各 controller 之间只通过显式构造参数或事件流通信，禁止 extension on State。
进度、顶栏、页码等高频值改成 ValueListenableBuilder 或 select 局部订阅，整页 build 只在模式切换这类结构变化时发生。
取代并删除：17 个 `extension _X on _ReaderFushiPageState` part，_rebuild 转发器，以及 State 上的绝大部分字段。
守卫：给 reader_fushi/ 目录加一条 lint 或架构测试——禁止新增 `extension .* on _ReaderFushiPageState`，State 字段数只降不升。
分期：先拆 position/navigation 和 bridge（与另两条同步），再拆 audiobook/lyrics/mining。

要动：fushi/lib/src/pages/implementations/reader_fushi_page.dart；fushi/lib/src/pages/implementations/reader_fushi/*.part.dart；fushi/lib/src/reader/reader_chrome_controller.dart

核验说明：已验证：主文件 6576 行，17 个 part 合计约 2.6 万行，各 part 都是 `extension on _ReaderFushiPageState`，_rebuild( 全目录调用 74 处。进度变化时整页 setState 是代码路径推断（navigation.part.dart:1530 附近），帧耗时未实测，审计也已标明。

方案风险：整体拆分是 XL 级、横跨三条其他发现。拆 controller 时要防止只是把 extension 换成 controller 互相持有引用，耦合原样保留；守卫「State 字段数只降不升」需要一个能稳定数字段的实现（基于 analyzer，不要再写 contains 字符串守卫）。另外，焦点所有权（docs/agent/focus-ownership.md）在 Focus / Actions 树上的约束，拆分时要保持。

## reader-engine-js-as-strings

**约 1.6 万行阅读器 JS 以 Dart 字符串手写维护，每次跨章整段 evaluate 一次，靠 233 个读源码文本的守卫测试兜底**

- 类型：性能；规模 L；价值 high；不改外部行为
- 核验：部分成立

证据：

- fushi/lib/src/pages/implementations/reader_fushi/webview.part.dart:3500-3511：每章 onLoadStop 之后 `evaluateJavascript(source: engineSource + boot)`；webview.part.dart:1014-1020 注释承认注入通道和执行时刻都没改，单次往返约 7.5ms
- docs/bugs/BUG-1140-cross-chapter-turn-latency.md 的实测表：evalSetupScript 24ms，setupChars 145162，遮罩总计 101ms；JS 解析编译约占跨章时长的四分之一（Windows 离屏实测，移动端未测）
- webview.part.dart:3510-3531：注入之后串行 await _caretReanchor → _injectAudiobookBridge → HighlightBridge.inject → _applyChapterHighlights，每章至少 4 次额外往返
- fushi/lib/src/reader/reader_script_compactor.dart:1-15：为了减少传输量，专门写了一个剥注释的词法器，以绕过「JS 写在 Dart 字符串里」带来的问题
- reader_visual_novel_scripts.dart:100：非 raw 字符串里写 `\\p{Radical}` 这类双重转义；JS 没有 lint 和类型检查
- grep：fushi/test 下有 233 个测试以 readAsStringSync 读取 reader_fushi*.dart / reader_pagination_scripts.dart 源码做 contains/RegExp 守卫（例 test/pages/reader_cross_chapter_settle_guard_static_test.dart:29-57）

机制：JS 不是一等源码，没有模块、lint、类型和单测运行器，只能用 Dart 字符串拼起来、用字符串守卫钉住形状。注入方式是「每章文档加载完成后通过平台通道整段 eval」，浏览器的脚本缓存和代码缓存用不上，每章重新解析编译 14 万字符；其他桥脚本（高亮、有声书、caret）也各自再 eval 一次。

根本方案：1. 把引擎 JS 移到 fushi/assets/reader_engine/*.js（ES 模块），由构建步骤（esbuild）打成一个带内容哈希的 bundle，CI 跑 tsc --checkJs、eslint 和 headless Chrome 单测（已有 reader_headless_shell_dump_test 的基础）。
2. 注入方式改为：sanitizer（fushi_compute 的 buildChapterHtmlBytes headEnd）在每章 head 里写 `<script src="https://fushi.local/engine/<hash>.js">` 加一段内联 boot 配置；资源拦截器按哈希返回并带长 Cache-Control。浏览器可以缓存字节码，跨章不再走平台通道传 14 万字符。高亮、有声书、caret 桥都并进同一个 bundle，按 config 启用。
3. _onChapterLoadComplete 的多次串行往返合并成一次 boot 调用。
取代并删除：reader_pagination_scripts / visual_novel / selection / caret / seamless 里的 Dart 字符串常量，ReaderScriptCompactor，engineShell 的字符串拼装，以及大部分读源码文本的守卫测试（改成 JS 单测和 tsc）。
以后改 JS 只改 .js 文件。
顺带一条推测（未实测）：sanitizer 的同步 FFI（webview.part.dart:508、:714 的 _buildSanitizedChapterHtmlBytes）在 UI isolate 上处理整章字节，大章可能超过 1ms，应按架构规则移到后台 isolate，与预取合流。

要动：fushi/lib/src/reader/reader_pagination_scripts.dart；fushi/lib/src/reader/reader_visual_novel_scripts.dart；fushi/lib/src/reader/reader_selection_scripts.dart；fushi/lib/src/reader/reader_caret_scripts.dart；fushi/lib/src/reader/reader_script_compactor.dart；fushi/lib/src/media/audiobook/highlight_bridge.dart；fushi/lib/src/pages/implementations/reader_fushi/webview.part.dart；native/fushi_compute/src/parse/sanitize.rs；fushi/pubspec.yaml（assets）；fushi/test/**/reader_*_guard*_test.dart

核验说明：已验证：webview.part.dart:3509-3526 每章 onLoadStop 后 evaluateJavascript(engineSource + boot)；之后串行走 caretReanchor、_injectAudiobookBridge、HighlightBridge.inject、_applyChapterHighlights（3527-3545）。不过 webview.part.dart:1005-1019 的注释说明源码已经按 mode memoize，并实测平台通道固定往返约 7.5ms、与载荷大小几乎无关（2 字符 7.5ms，14.7 万字符 9.0ms）。所以 24ms 的 evalSetupScript 主要是往返加 JS 解析执行，传输字节不是重点；「跨章不再走平台通道传 14 万字符」的收益被夸大了。「浏览器会缓存字节码」属于推测：<script src> 的代码缓存在 WebView2 / WKWebView / Android WebView 上，对经拦截器返回的自定义 host 资源是否生效，都没有实测。合并成一次 boot 往返（减少往返次数）才是注释里已指出的真正收益点。

方案风险：1）改成 head 里 <script src> 后，执行时刻从 onLoadStop 之后变成解析阶段（在 body 和图片之前）。引擎的 install 依赖 DOM 已就绪和图片尺寸（BUG-3533 的 eager 图片），per-nav 配置（gen、charOffset、cue 列表）也得在 HTML 构建时就写进去。可是 HTML 有 LRU 缓存（_sanitizedHtmlCache，webview.part.dart:496），而 per-nav 配置每次导航都不同，写进 HTML 会让缓存失效，或者配置会过时。2）iOS / macOS 的 fushi.local 资源服务机制要核实，看 script 子资源能否走同一拦截路径（未验证）。3）shouldInterceptRequest 只在 Android 生效，其他平台走别的回调，长 Cache-Control 各平台的行为也不一样。4）引入 esbuild / tsc 同样需要 Node 工具链，属于范围扩大。

修正后的方案（以此为准）：分两步。① 先做与注入通道无关的改进：JS 移成真 .js 资源（构建时读进 const，或运行时 rootBundle 读一次再 memoize），加 lint 和 headless 单测，删 ReaderScriptCompactor 和字符串守卫；把 engine eval、caret、有声书桥、高亮注入、高亮应用合并成一次 evaluateJavascript（这是已实测的收益点）。② <script src> 加 HTTP 缓存作为可选实验：per-nav 配置仍然走 onLoadStop 后的一次 boot eval，不写进可缓存的 HTML；三端实测解析耗时确实下降后再切。

## char-coordinate-systems

**字符坐标有 5 套以上口径，用裸 int 传递、在 Rust / JS / Dart 各实现一份，跨坐标混用成类出 bug**

- 类型：缺单一登记源；规模 XL；价值 medium；不改外部行为
- 核验：部分成立

证据：

- packages/fushi_engine/lib/epub/epub_book.dart:178-196：chapterPlainText（去 ruby）和 chapterSearchText（不折叠空白，「与阅读器 JS scrollToSearchMatch 的 TreeWalker 同一坐标」）由 Rust ffc_parse_epub_chapter 产出，JS 再按自己的 TreeWalker 实现一遍
- fushi/lib/src/reader/reader_pagination_scripts.dart:1562 createTreeWalker 排除 rt/rp；reader_visual_novel_scripts.dart:100-110 另有一份 isMatchableChar 正则
- docs/bugs/BUG-2333-reader-favorite-coordinate-contract.md 根因：reader_selection_scripts.dart:1814 按学习单位计数，highlight_bridge.dart:166 按可匹配字符计数，收藏直接跨坐标使用；音频 UTF-16 坐标被拿学习单位总数去除
- docs/bugs/BUG-587：精确锚 char_offset 与分数 norm_char_offset 两套坐标不同步（reader_position_repository.dart:25）
- fushi/lib/src/pages/implementations/reader_fushi/audiobook.part.dart:609-621：_audioPositionIndexFor 每章从 html 重建 ReaderAudioPositionIndex（Dart 侧又一份文本遍历），并做 3 章 LRU
- fushi/test/reader/ 下 char_caliber_test、reader_audio_coordinate_contract_test、reader_favorite_coordinates_test.js、vn_lookup_audio_coordinates_test 等多份契约测试，在兜同一类问题

机制：「第 N 个字符」在学习单位、可匹配字符、UTF-16 码元、去 ruby 文本、搜索文本、分数进度之间没有类型区分，都是 int 或 double。每个消费方（JS 引擎、选区、高亮桥、有声书、统计、收藏）各自写一份遍历规则，规则稍有出入，或者拿错了坐标，就是一条新 bug，然后再补一份契约测试。

根本方案：1. 单一真相源：在 Rust（fushi_compute 的 epub 章扫描）产出每章一份 ChapterTextMap，里面有文本节点序列和各口径的累计偏移表（studyUnit / matchable / utf16 / searchText），各口径之间的映射只在这里定义。
2. Dart 侧用 extension type 区分坐标：StudyOffset / MatchableOffset / Utf16Offset / SearchOffset，互转只能经 ChapterTextMap 的方法，编译期禁止混用。
3. JS 引擎在 boot 时收到该章映射表的紧凑 TypedData，只做 DOM 节点到索引的定位，不再自带计数正则。
4. 有声书的 ReaderAudioPositionIndex 和统计口径（countStudyChars）都改成从 ChapterTextMap 派生。
取代并删除：JS 里各 shell 自带的 normalize/isMatchable 计数（含 VN 复制的那份），highlight_bridge 的计数，ReaderAudioPositionIndex.fromChapterHtml 的 Dart 遍历，以及大部分坐标契约测试（改成测 Rust 映射加类型）。
以后新增一种坐标口径，只在 Rust 映射表里加一列，再加一个 extension type。

要动：native/fushi_compute/src/parse/epub.rs；packages/fushi_engine/lib/epub/epub_book.dart；fushi/lib/src/reader/reader_pagination_scripts.dart；fushi/lib/src/reader/reader_visual_novel_scripts.dart；fushi/lib/src/reader/reader_selection_scripts.dart；fushi/lib/src/media/audiobook/highlight_bridge.dart；fushi/lib/src/reader/reader_audio_position.dart；fushi/lib/src/pages/implementations/reader_fushi/audiobook.part.dart

核验说明：多口径是真的（BUG-2333、BUG-587 文件存在；epub_book.dart 里有 chapterPlainText / chapterSearchText；多份契约测试在兜同一类问题）。但「JS 不再自带计数、只吃 Rust 映射表」的前提有问题：JS 面对的是净化后、注入后的 DOM（合并图片章、ruby 处理、cloak 样式等，见 webview.part.dart:561-580），Rust 解析时的文本节点序列不一定和运行时 DOM 的 TreeWalker 序列一一对应。

方案风险：映射表一旦和运行时 DOM 不同步（sanitizer 改动、mergeImage 吸收前章插图、浏览器规范化空白），所有消费方会一起错，比现在各自错更难发现。持久化里的 char_offset、norm_char_offset、收藏和高亮坐标是冻结的口径，新类型只能包住现有口径，不能改变它们的语义。

修正后的方案（以此为准）：保留 Dart 侧的 extension type 区分口径（低风险、收益直接）。单一真相源改为：由 sanitizer（Rust）在产出章节 HTML 的同一次扫描里生成映射表，保证映射与实际下发的 DOM 同源，而不是从解析期的模型生成。JS 侧保留一份共享计数实现（放进 core，删掉 VN 的复制），启动时与映射表总数对账，不一致就上报错误，而不是完全删掉 JS 计数。

## epub-model-logic-in-page

**EPUB 书模型逻辑散在页面文件里：解压目录越界解析手抄 7 份，回退建书、字数、TOC 锚点、chaptersJson 回写写在页面里，回退路径在 UI isolate 上同步读整本书**

- 类型：缺单一登记源；规模 M；价值 medium；不改外部行为
- 核验：成立

证据：

- packages/fushi_engine/lib/epub/epub_book.dart:152-158 已有 EpubBook.rootFilePath 作为越界解析的单一实现，但 reader_fushi/chrome.part.dart:181、webview.part.dart:225、:656、:801、reader_fushi_page.dart:4184、fushi/lib/src/reader/reader_collection_volumes.dart:205、epub_parser.dart:1286 都各自手写 `p.join + p.isWithin(p.canonicalize..) + p.normalize`
- webview.part.dart:650-655、:218-221 的注释（BUG-1218）记录过「三方 2:1 不一致」：一处用 canonicalize 建键，导致章节 LRU 永不命中、大小写敏感平台 404
- reader_fushi_page.dart:4141-4227 _buildBookFromDb：在 UI isolate 上对每章 `file.readAsStringSync()` 把整本书 HTML 读进内存；:4229-4252 _buildLegacyBook 在 UI isolate 上 listSync(recursive) 加逐文件 readAsStringSync（解析失败回退路径，按代码路径推断大书会卡顿）
- reader_fushi_page.dart:1474-1640：countChapterChars、persistRecomputedChapterCharCounts（DB 事务）、computeTocAnchorCharOffsets、parseBookOnly、插图表 isolate 调度这些书模型和持久化逻辑都写在 pages/implementations 下的页面文件里

机制：fushi_engine 只提供了解析器，「一本已导入的书怎么打开、资源路径怎么解析、字数口径怎么回写」没有收进引擎层的 BookSession，各调用点就地复制一份。复制品之间一旦漂移就出 BUG-1218 这类问题，也让回退路径没人管地跑在 UI isolate 上。

根本方案：在 fushi_engine/lib/epub/ 新建 OpenedEpubBook（或 EpubBookSession），一个对象统一负责：
- 打开书：主解析、DB 元数据回退、目录回退，全部在后台 isolate 里做；
- resolve(href) → EpubResolvedPath，唯一的越界判断和大小写规则，返回值是 extension type，资源服务、LRU 缓存键、图片查看器、合集卷都只接受这个类型；
- 章字数、TOC 锚点、chaptersJson 口径回写。
页面只调用这个对象，不再自己拼路径或读文件。
取代并删除：reader_fushi_page.dart 的 _buildBookFromDb、_buildLegacyBook、countChapterChars*、persistRecomputedChapterCharCounts、computeTocAnchorCharOffsets、parseBookOnly，以及上述 6 处手写路径解析。
守卫：架构测试禁止 epub 与 reader 目录下出现 `p.isWithin(p.canonicalize` 的新调用（只允许 resolver 内部使用）。
以后新增一种资源消费方，只用 resolve()。

要动：packages/fushi_engine/lib/epub/epub_book.dart；packages/fushi_engine/lib/epub/epub_parser.dart；packages/fushi_engine/lib/epub/（新增 opened_epub_book.dart）；fushi/lib/src/pages/implementations/reader_fushi_page.dart；fushi/lib/src/pages/implementations/reader_fushi/webview.part.dart；fushi/lib/src/pages/implementations/reader_fushi/chrome.part.dart；fushi/lib/src/reader/reader_collection_volumes.dart

核验说明：已验证：手写的 `p.isWithin(p.canonicalize(...))` 在 chrome.part.dart:181、webview.part.dart:225/656/801、reader_fushi_page.dart:4184、reader_collection_volumes.dart:205、epub_parser.dart:1286 等多处，而 epub_book.dart:156 已经有单一实现。_buildBookFromDb（reader_fushi_page.dart:4141）虽然是 async，但在 :4165 逐章 readAsStringSync；_buildLegacyBook 在 :4245 同样同步读，都跑在 UI isolate 上。

方案风险：epub_parser.dart:472/597-610 用的是 canonExtract 加 normalize 双重校验，以及父目录回溯的大小写处理，语义和其他几处不完全相同（BUG-1218 就是口径分歧造成的）。合一时要以 BUG-1218 的结论为准选定规则，并把 LRU 缓存键一并统一到 resolver 的返回值，否则会重演缓存永不命中的问题。fushi_engine 禁止 import flutter，后台 isolate 要用 Isolate.run，不能用 compute。

## 核验补充（审计漏掉的）

- 歌词宿主的悬停查词缺显式背压释放（实际 bug，不只是维护性问题）：fushi/lib/src/pages/implementations/reader_fushi/lyrics.part.dart:1743-1760 的 onTextSelected 没调 ReaderSelectionScripts.hoverLookupSettledInvocation / _settleHoverLookupJs，正文那份在 webview.part.dart:2510-2533 有。若歌词 WebView 注入的是同一份 selection 脚本（推测，未核实 lyrics_mode_html.dart 的注入内容），悬停查词释放就只靠 callHandler 的 Promise 回执，回执丢失时会挂住后续悬停查词。应先按 bug 流程单独修，不要等桥重构。
- 章节净化走同步 FFI，跑在资源拦截回调里：webview.part.dart:508 的 _buildAndCacheChapterHtml 在冷缓存时同步调 ReaderResourceSanitizer.buildChapterHtmlBytes（:561），并且就在 shouldInterceptRequest（:3243）的处理链上。大章可能超过 1ms，违反「>1 ms 放后台 isolate」的架构规则。审计只在 reader-engine-js-as-strings 里顺带写成推测，应单列一条并实测大章耗时。
- 8s 内容就绪兜底已经出过「抖动无限推迟」的补丁（reader_fushi_page.dart:505-519 改成绝对截止时刻），说明内容就绪本身缺一个来自 WebView 生命周期的失败信号（onLoadError / onRenderProcessGone 没接进位置状态）。这才是兜底定时器存在的根因，位置机方案必须把它补上。
- JS→Dart handler 散在全仓 146 处（fushi/lib 下 addJavaScriptHandler 总数），不只阅读器：其他 WebView 宿主（全局查词浮层、highlight_bridge、lyrics_mode_html）也各自手写位置参数解析。协议登记源的范围应按全仓设计，否则阅读器外的宿主会继续复制。
