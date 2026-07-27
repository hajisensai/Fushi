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

证据：`.codex-test/windows-itest/xchapter-{base02,base03,base04,opt01,opt02,opt03,before-overlay}/command.log`（不入库）。

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
   **注入字节 171KB → 118KB（-31%）**。如实记录：Windows 桌面上这一项**没有转化为时间收益**
   （`evalSetupScript` 27→24ms 在噪声内）——该段耗时由 IPC 固定开销 + JS 编译主导，不由注释体积主导。
   保留的理由是字节数确实减少（移动端 WebView 的 JS 编组更贵），**但移动端未实测，不宣称收益**。

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

- **[x] ① 已修复** — `_settleAndNotify` 空等 + 恢复收尾延后 + 注入脚本压缩（本 PR）
- **[x] ② 已加自动化测试** — `hibiki/integration_test/reader_cross_chapter_perf_itest.dart`（实机分段计时 +
  14 次跨章落点断言）、`hibiki/test/reader/reader_script_compactor_test.dart`（5 项，含真实注入脚本语义等价）
- **备注**：性能优化，非崩溃 bug。`test/pages` + `test/reader` 定向全绿（期间修正两处因改动而失效的源码守卫
  定位串：`reader_init_page_width_guard_static_test`、`reader_fixed_layout_blank_cloak_guard_static_test`）。
