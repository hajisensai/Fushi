## BUG-1140 · 跨章翻页耗时实测与提速（遮罩口径）

- **报告**：2026-07-27（用户：实机检测并优化跨章性能，无用守卫什么的删掉 / 追加：遮罩这算跨章里面）
- **真实性**：✅ 真性能问题（非崩溃）。用户感知的「跨章」= 遮罩（`!_readerContentReady` 时盖住整页的 `ColoredBox`，`reader_hibiki_page.dart:2366`）从出现到撤掉的整段时间。

### 测量（先有数据再动手）

新增两件可复用的测量设施，默认关闭、生产零开销：

- `hibiki/lib/src/reader/reader_chapter_perf_trace.dart` —— Dart 侧分段计时（`ReaderChapterPerfTrace`），在跨章链路每个边界打点：
  `loadUrl → docLoad(onLoadStop) → sasayakiCues → buildSetupScript → evalSetupScript → caretReanchor → audiobookBridge → highlights → jsInitRestore → overlayGone`。
- JS 侧 `hoshiReader.perfMark/perfSnapshot`（`reader_pagination_scripts.dart`）—— 把 WebView 内部那段再拆成
  `js.initSync / js.images / js.offsets / js.restore`，连同浏览器 navigation timing（`responseEnd/DOMContentLoaded/load`）随 `onRestoreComplete` 回传。
- `hibiki/integration_test/reader_cross_chapter_perf_itest.dart` —— Windows 离屏实机 itest，驱动走**生产通道**
  （JS 侧 `onBoundarySwipe` handler，与用户滚轮翻到章末发出的是同一事件），8 章 fixture 前进 7 次 + 后退 7 次，
  每次断言落点正确（前进落章首 / 后退落章末 / 章节文件确实换了），再输出各段中位数。

### 实测结果（Windows 离屏，14 次跨章中位数，**同口径**）

before = 三项优化临时回退、测量探针保留（`xchapter-before-overlay`）；after = `xchapter-opt03`。

| 段 | before | after |
|---|---|---|
| docLoad（WebView 装载到 load 事件） | 37ms | 32ms |
| evalSetupScript（注入 setup 脚本） | 28ms | 24ms |
| jsInitRestore（JS initialize + 恢复） | 29ms | 13ms |
| └ js.restore（恢复滚动那一步） | 36ms | **19ms** |
| overlayGone（状态就绪 → 遮罩真正撤掉） | 13ms | 21ms |
| setupChars（注入脚本字符数） | 211407 | **145162** |
| **total（遮罩口径）** | **125ms** | **101ms（-19%）** |

**`overlayGone` 单段不可比**：它测的是「状态翻真 → 下一帧」的等待，长短取决于恢复完成落在帧周期的哪个相位
（before 恢复得晚、恰好贴近帧边界，反而等得短）。可比的是 total。因此第三项修复（恢复收尾挪到遮罩帧之后）
的实测收益落在噪声内——机理成立（不让 DB 查询与 JS 往返挤在遮罩撤除之前），但**不宣称它的数字**。
确定的收益来自 `js.restore` 的 -17ms（删掉的那层空等）。

证据：`.codex-test/windows-itest/xchapter-{base02,base03,base04,opt01,opt02,opt03,before-overlay,rebased}/command.log`（不入库）。
before / after 两轮均在无并发负载下跑。`xchapter-rebased`（rebase 到含 PR#453 的 develop 后复测）与定向测试
并发跑，`docLoad`/total 被 CPU 争用抬高，只用于确认「落点仍全绿 + 优化仍生效」（`js.restore` 20ms、
`jsInitRestore` 14ms 与 after 一致），其 total 不作性能结论。

### 根因（三处，都是「等待」而非「计算」）

1. **`_settleAndNotify` 两层硬编码 `setTimeout(16)` = 固定 32ms 空等**（`reader_pagination_scripts.dart`）。
   分页版第一层重设落点（有实义），**第二层什么都不做**；连续版更甚——**两层都不做任何事**，纯空等 32ms 才
   通知 Dart。落点在第一层已被 `setPagePosition` 同步写死，再等一帧不改变任何结果，只是让遮罩多留一帧。
2. **恢复收尾挤在遮罩撤除的同一轮事件循环里**（`navigation.part.dart _onRestoreComplete`）。收藏高亮
   （一次 DB 查询 + 两次 `evaluateJavascript`）、有声书图片锚点复位、进度刷新与轮询、诊断探针——没有一项
   决定「新章能不能看见」，却每项都 await 一次 DB 或 JS 往返，把遮罩撤除那一帧的绘制往后推。
3. **setup 脚本带着全部中文注释跨 IPC 传输**（`webview.part.dart _buildReaderSetupScript`）。

### 修复

1. 删掉 `_settleAndNotify` 的第二层空等（分页版保留「等一帧再重设落点」的防 reflow 语义，连续版收敛成单层）。
2. `_onRestoreComplete` 里的收尾工作整体挪进 `addPostFrameCallback` —— 遮罩按时撤、用户先看到新章，收尾照旧全执行
   （语义变化仅「晚一帧」）。**这一项的实测收益落在噪声内**（见上文 `overlayGone` 说明），保留是因为机理成立。
3. 新增 `ReaderScriptCompactor`（`lib/src/reader/reader_script_compactor.dart`），注入前剥离整行注释与空行：
   **整份 setup 脚本 211407 → 145162 字符（-31%，实测 `setupChars`）**。如实记录：Windows 桌面上这一项
   **没有转化为时间收益**（`evalSetupScript` 28→24ms 在噪声内）——该段耗时由 IPC 固定开销 + JS 编译主导，
   不由注释体积主导。
   保留的理由是字节数确实减少（移动端 WebView 的 JS 编组更贵），**但移动端未实测，不宣称收益**。

#### 审查后续（PR#461 非阻塞意见收口）

4. **`ReaderScriptCompactor` 的模板态跟踪换成真正的词法扫描**（根因修复，非加守卫）。
   初版按「本行未转义反引号的奇偶」翻转模板态，把写在**注释 / 引号串 / 正则**里的反引号也算进去——
   任何人在 JS 注释里写一个反引号，就会把后续真模板串当成代码区、剥掉模板里的空行/数据行，
   CI 全绿而线上白屏。现在是单遍词法状态机：行注释 / 块注释 / 单双引号串 / 模板串（含 `${}` 嵌套）/
   正则字面量各自成状态，反引号只在代码区计数。另外开了 `scansCleanly()` 供守卫自检（扫完必须回到
   干净顶层）。选改算法而不是只加守卫：守卫只能阻止语料变脏，改算法才能让“注释里写反引号”从默认
   危险变成默认安全（仓库红线：根因修复优先于特例分支）。
5. **延后一帧的收尾块补上 `_navigateGeneration` 代际守卫**。之前只有 `mounted`；收尾晚一帧执行时
   可能已起新导航，`_refreshProgress()` 会把旧章位置写进新导航。现在与同文件既有约定一致：入口快照
   代际、回调里比对，被顶掉就整体丢弃。
6. **JS 侧 perf 埋点受同一个开关控制**。之前 Dart 侧 `ReaderChapterPerfTrace.enabled` 只 gate 了消费端，
   JS 侧 `perfMark` / `perfSnapshot`（含 `JSON.stringify` 与 `getEntriesByType('navigation')`）无条件执行，
   且快照字符串每章过一次 platform channel。现在两个 shell 在注入期把 `_perfOn` 写死（`shellScript(
   perfTraceEnabled:)` ← `ReaderChapterPerfTrace.enabled`），生产路径上两个函数立即 early-return。

### 顺带删掉的无用守卫

- `_startContentReadyTimeout` 超时回调里那行 `_isNavigatingToChapter = false;` —— 与紧随其后的
  `_failNavigation()` 内部完全重复，注释自陈「保留作源码守卫锚点」。守卫测试
  `reader_content_ready_timeout_unwind_guard_static_test.dart` 的断言②改为钉真正的不变量
  （`_failNavigation` 内部清 `_isNavigatingToChapter` / `_restoreInFlight` / completer），删掉重复行后守卫依然成立。

**没有删**的守卫（查证后确认不是无用）：TODO-1229 那套跨章冷却窗 / 在飞守卫对应用户复诉三次的「跳两章」；
`[xchapter]` 系列诊断埋点被 `test/reader/diagnostic_logging_guard_test.dart` 明确钉住（跨章 bug 的取证来源）。

### 追加一轮：带插图的章（用户复诉「体感至少 0.5s」）

**首轮测量的盲区**：合成 fixture 的「图片章」用的是内联 SVG，解码几乎免费，于是 `js.images` 恒为
0ms、`docLoad` 也测不到图片这一段——101ms 只代表纯文本章。用户指出带图跨章体感远不止这个数。

补了真实体量的素材（`integration_test/helpers/generate_test_image.dart` 生成 1600×2400 RGB PNG，
渐变叠低频噪声：像素数决定解码成本、噪声决定压缩后体积），`EpubGenerator(withRealImages: true)`
追加两章——纯整页插图章（3 张）与图文混排章（4 张）。实测（Windows 离屏 itest、debug build、
同机同书、18 次跨章的单点值，非中位数）：

| 章 | 原始 | 改后 |
|---|---|---|
| 图文混排章 首次（4 张插图）**遮罩时长** | **849ms**（docLoad 717ms） | **101ms**（docLoad 29ms） |
| 纯整页插图章 首次（3 张插图）**遮罩时长** | **879ms**（docLoad 689ms） | 355~541ms（不稳定，见下） |
| total 中位数 | 184ms | **132ms** |

**这个数字的性质必须说清楚，别当成 8 倍加速**：849→101ms 量的是「遮罩出现到撤除」，而本轮
修复的本质是**把插图解码从遮罩之前挪到遮罩之后**——总的读盘+解码工作量一点没少，只是不再
串在「新章可见」的关键路径上。用户拿到的是「翻页立刻见到文字」，插图在章内异步补上；
不是「机器少干了 8 倍的活」。诚实的表述是：**跨章遮罩时长 849→101ms（插图解码转入章内异步）**。
`total 中位数 184→132ms` 才是覆盖全部章型的整体口径，收益远没有标题数字那么夸张。

**根因**：`nav.dcl` 只有 15~20ms 而 `nav.load` 687~717ms——DOM 早就解析完了，剩下 670ms 全是在等
图片读盘+解码，而遮罩正好盖住这整段（setup 脚本挂在 `window.load` 之后才注入）。

`initialize` 里 TODO-1074 那段本来就想给每张 `<img>` 挂 `loading="lazy"`，理由写的正是「不再拖住
window.load」——**但它跑得太晚**：脚本在 `load` 之后注入，浏览器早已按标签原始属性把整章图片
（含离屏的）全部加载完毕。那行 lazy 迟到了一整个加载周期，只是给一笔已经付掉的账贴标签。

**修复**：
1. `ReaderResourceSanitizer.markImagesLazy` —— 把 lazy/decoding 的判定上移到 **Dart 生成 HTML 时**
   写进标签，属性才对本次加载生效。保持 eager 的例外与 JS 侧同款且更保守（这里 eager 的集合是
   JS 侧的超集，不会出现「Dart 挂 lazy 而 JS 想 eager」的倒挂）：纯图片章整章 eager（分页几何要靠
   插图真实撑开，TODO-1349）、`gaiji` 内联小图 eager、原书已写 `loading=` 的尊重原值。
2. `_prefetchAdjacentChapterImages` —— 跨章落地后用隐藏 `new Image()` 把**阅读方向上**下一章的
   插图按同样 URL 请求一遍，走同一个拦截器与同一份缓存条目（图片响应本就带 `max-age=3600`）。
   **位置很关键**：必须挂在遮罩撤除之后的收尾块；第一版挂在 `_onChapterLoadComplete`（遮罩之前），
   parse 整章 HTML + 读几张大 PNG 全压在热路径上，实测把 `jsInitRestore` 顶到 520ms、
   `overlayGone` 顶到 312ms——成本只是换了个口袋。挪到遮罩后即回落到 36ms / 69ms。
   预热带**配额**（`_kImagePrefetchMaxCount` 4 张 / `_kImagePrefetchMaxBytes` 8MB，按磁盘字节计），
   方向由 `_beginNavigation` 采样（倒着读时预热上一章，而不是刚离开的那一章）。
3. **迟到图片的语义重锚**（`reader_pagination_scripts.dart` `registerImageLateAnchor` /
   `reapplyImageLateAnchor`）—— 第 1 条把「插图未 decode」变成了恢复时刻的**常态**，于是恢复
   把语义锚（char / progress / fragment）换算成 scrollTop 时用的是「插图 0×0」的塌缩布局；
   插图随后 load、几何后移，冻结的 scrollTop 指向别的内容，进度轮询还会把这个漂掉的读数落库。
   原有的 `__imgReanchorProgress` 只覆盖章首(0)/章末(≥0.99) 两个粗粒度分支，中段 progress 与
   精确字符锚**完全裸奔**。现在三种锚全部登记，图片 load 后按同一个语义锚重算落点——终态与
   「插图本来就在」等价；重锚走既有 `onReaderScroll` 通道把**修正后**的位置落库。
   用户翻页（`paginate`）清资格，不把已翻走的位置拽回。
4. 合并前导插图（TODO-1339）的 eager 改成**显式** `loading="eager"` 属性，不再依赖
   `markImagesLazy` 与 `_injectMergedChapterImages` 的调用顺序。

**未解决 / 如实说明**：纯整页插图章仍要 355~541ms 且不稳定。它按设计不能挂 lazy（分页几何依赖插图
真实尺寸），只能靠预热覆盖，而预热是否命中取决于用户在上一章停留多久、以及 WebView 缓存是否保留
（实测同章二次进入有时 109ms 命中、有时 330ms 未命中，样本内不稳定）。要根治仍得让 setup 脚本不等
`window.load`（见下「仍未做」第一项）——那样图片解码与恢复可以并行，而不是串行等完再开始。

图文混排章的 101ms **是否依赖预热命中**同样没有单独拆开量：itest 里每次跨章后停留 1500ms
（判据是 settle 尾沿 + 450ms 跨章冷却窗，不是「等预热跑完」），快速连翻 / 目录跳转时预热必然
不命中，那种情况下的数字未单独测量。**不要**把 itest 的等待时长调长去凑一个更好看的稳态数字。

守卫：`test/reader/chapter_jump_late_load_reanchor_test.dart`（三种语义锚都登记 + 翻页清资格 +
load 回调分派顺序）、`test/reader/reader_image_lazy_pipeline_guard_test.dart`（Dart 侧 lazy 流水线
——既有三条图片守卫全是扫 JS 源码的，管不到 Dart 侧这份判定）、
`test/reader/reader_image_lazy_markup_test.dart`（`markImagesLazy` 字符串改写）。
行为端：`integration_test/reader_cross_chapter_perf_itest.dart` 的「中段落点回归」用例
（真实退出重进 → 图文混排插图章中段锚 → 重进落点偏差必须在一页之内）。

### 仍未做（下一步，风险与收益都更大）

- ~~`evalSetupScript` 剩余 ~24ms 是每次跨章重新编译整份引擎 JS~~ —— **这条机理经探针实测为假，已作废**。
  拆开测的结果：**平台通道固定往返 ~7.5ms**（发 2 字符 7.5ms vs 发 147459 字符 9.0ms —— 载荷相关成本只有
  ~1.5ms）、**JS 编译 ~1.0ms**、**执行 ~6ms**。也就是说这段耗时的大头是**一次跨进程往返**，不是编译，
  更不是字节数。
  推论：任何「让 WebView 复用编译结果」的方案（`<script src>` 外链 / UserScript 注册一次）**收益上限只有
  1.5~2.5ms**，占跨章总时长的 1~2%——不值得为它引入外链资源、强缓存与失效约定这套复杂度。
  另有一条平台事实：`CustomSchemeResponse` 只有 `data` / `contentType` / `contentEncoding` 三个字段、
  **没有 headers**，本仓 `_loadResourceWithCustomScheme` 正是把带 `Cache-Control` 的 `response.headers`
  整个丢掉——**iOS/macOS 上强缓存在类型层面就无法表达**，那条路在移动端必然每章 cache miss。
  真正值得下手的是**减少每次跨章 `evaluateJavascript` 的往返次数**，以及 `docLoad`。
- `docLoad` 32ms 里有相当一部分是在等 `window.load`（含全部子资源）：`nav.dcl` 中位数 13ms vs `nav.load` 19ms。
  引擎若能在 DOMContentLoaded 就位，这段可与子资源加载并行。
- 更彻底的方案是「下一章预渲染」（双 WebView 交替），可把顺序阅读的跨章压到一帧，但内存与状态同步成本高。
- **连续 shell 的那层 16ms 仍是时间赌**（只是从 32ms 减半）：它没有分页 shell 那种「同步写落点」
  可供推理的 program-order 保证。后果有界（最多遮罩早撤一帧、闪一帧未落定的滚动位置，不污染
  持久化位置）。**日后若有人报「跨章闪一下」，第一嫌疑就是这里**；正解是在 notify 前同步
  re-assert 一次 scrollTop（对齐分页 shell 的 `setPagePosition` 做法），把它也升级成 program-order 保证。

- **[x] ① 已修复** — `_settleAndNotify` 空等 + 恢复收尾延后 + 注入脚本压缩（本 PR）
- **[x] ② 已加自动化测试** — 三层：
  - `hibiki/test/reader/reader_script_compactor_test.dart`（40 项，CI 单测门内）——词法地雷用例 +
    **全部**真实注入载荷（selection / longPressDrag / caret / 分页 / 连续 / VN 三种 shell +
    **最终拼装脚本**）的“只删空行与整行注释 / 幂等 / 扫完干净”，并用 node `--check` 真解析
    压缩前后的脚本（无 node 时 skip）。
  - `hibiki/test/pages/reader_cross_chapter_settle_guard_static_test.dart`（3 项）——源码扫描钉住
    “空等不得加回来 / 分页 settle 仍是先同步写落点再通知 / 延后一帧的收尾带代际守卫”。
  - `hibiki/integration_test/reader_cross_chapter_perf_itest.dart`（实机分段计时 + 14 次跨章落点断言；
    **不进 CI 单测门**，故有上面两层兜底）。
- **备注**：性能优化，非崩溃 bug。`test/pages` + `test/reader` 定向全绿；期间修正一处因改动而失效的
  源码守卫定位串（`reader_fixed_layout_blank_cloak_guard_static_test`）。
  `reader_init_page_width_guard_static_test` 零改动——它的两个定位串不受本改动影响（早先文档称“改了两处”是误记）。
