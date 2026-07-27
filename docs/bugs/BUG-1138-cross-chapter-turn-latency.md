## BUG-1138 · 跨章翻页耗时实测与提速（遮罩口径）

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

### 仍未做（下一步，风险与收益都更大）

- `evalSetupScript` 剩余 ~24ms 是**每次跨章重新编译整份引擎 JS**：`evaluateJavascript` 的字符串没有 V8 code
  cache。正解是把引擎改成 `<script src>` 外链（走 hoshi.local 拦截器 + 强缓存）或 UserScript 注册一次，
  让 WebView 复用编译结果。阻碍：`initialize` 的参数化程度很高（insets / pageWidth / progress / charOffset /
  fragment / sasayakiCues 每次导航都可能不同），要先把 per-nav 参数从脚本里剥成运行时读取。
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
