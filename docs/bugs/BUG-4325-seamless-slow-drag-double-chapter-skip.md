## BUG-4325 · 连续模式无缝衔接：章节交界处按住慢拖跨一章落到下下章（无缝晋升与边界拉动两个换章所有者叠加）
- **报告**：2026-11-08（用户反馈 R7k887yaJI 重开，Android 3.3.0-debug.24790：「无缝衔接有 bug，在章节之间长按缓慢滑动屏幕，会飞速跳到下下章；下滑阻尼低和中都发生」）。关联 BUG-4239（f6fbacf0e9 提交信息里写的 BUG-4222，后被 settle 改号；三档切章阻尼）与无缝衔接功能 #3049（设计 `docs/specs/2026-11-07-continuous-seamless-chapters-design.md`）。
- **真实性**：✅ 真 bug，真 Chromium + CDP 真触摸复现（见②探针）。根因是无缝模式下**有两个换章所有者**：
  1. 无缝模块：用户滚动使视口中心越过邻章边界 `HYSTERESIS` 就在文档内晋升邻章并回调 `onSeamlessChapterActivated`，Dart 同步把 `_currentChapter` 换成新章（develop `fushi/lib/src/reader/reader_seamless_chapters_script.dart:620`、`:666-675`；`fushi/lib/src/pages/implementations/reader_fushi/seamless.part.dart` `_onSeamlessChapterActivated`）。
  2. 连续 shell 的触摸边界控制器：在手势**起点**按**文档**物理尽头记 pin（develop `fushi/lib/src/reader/reader_pagination_scripts.dart:4808`），松手时只要手指从 pin 起又推了 `continuousTurnPullPx` 就回传 `onBoundarySwipe`（`:4913`），Dart 由 `_handlePageTurnLimit` 从**当下**的 `_currentChapter` 再跨一章。滚轮试滚（`reader_fushi/webview.part.dart` 正文 wheel 监听）与按键 `paginate` 的 `limit` 同样按文档尽头判边界、交 Dart 换章。
  复现路径：停在章末（下一章还在挂载，文档尽头 = 活动章末）→ 按住、慢慢上推（起点已贴尽头，标准 / 低阻尼都会记 pin）→ 挂载中途落地，正文继续滚进下一章，越过迟滞带被晋升（换一章）→ 松手时边界控制器按起点 pin 判「拉过边界」再回传 `onBoundarySwipe` → Dart 从已经换过的章号再跨一章 = 下下章。探针在修复前实测：`seamless=[[2,1,1]]` 之后紧跟 `boundary=[["forward"]]`，标准、低两档都复现。第二个形态：文档尽头挂着一个短到视口中心越不过迟滞带的邻章（标题页 / 单图章）时，边界拉动 / 按键翻页把换章交给 Dart 整章重载，而不是由无缝模块晋升（不跳两章，但违背「无缝模式下换章只由无缝机制负责」）。
  原工单推测的「`isAtEnd` 包装回落原实现触发换章」不成立：`isAtEnd` 只被进度快照（`fushiProgressDetails` 的 atEnd 钳位、`getLastVisibleCharOffset`）消费，不在任何换章路径上。
- **[x] ① 已修复** — 文档内换章收成**一个所有者**，结构上互斥（不是时间窗去重）：
  - 连续 shell 新增两个默认实现：`chapterTurnEpoch()` 恒 0、`claimBoundaryTurn(direction)` 恒 false（shell 自己从不在文档内换章，换章一律交 Dart）。无缝模块装饰它们：计数 = 晋升序号 `S.seq`；认领交 `S.claimBoundaryTurn`——这一侧邻章已挂 → 晋升并对齐（前进到章首、后退到章末，落点与整章重载一致）；邻章正在挂载 / 模块正在启动 → 归模块（挂好后照常滚过去）；书首尾、挂载失败、启动失败 → 不认领，退回原整章重载。
  - 三条「到尽头就换章」的通道换章前都先问认领：触摸边界控制器 `_bEnd`（另外比对手势起点记下的 `chapterTurnEpoch`，这次手势里文档内已换过章就到此为止，pin 已不描述当前章的边界）、正文滚轮试滚、连续 `paginate` 的 `limit`（认领后回 `scrolled`）。
  - Dart `onBoundarySwipe` handler：边界意图相对发出时的章号，截图 await 前记 `fromChapter`，其间 `_currentChapter` 被无缝晋升换掉就丢弃这次意图。
- **[x] ② 已加自动化测试** —
  - 真 Chromium：`tool/reader_pitch_headless/continuous_seamless_chapters_probe.mjs` 新增 `runSlowDragLateMount`（标准 / 低阻尼：起点贴文档尽头、下一章挂载延迟 900 ms、CDP 真触摸 4px/30ms 慢拖 → 只换一章、无 `onBoundarySwipe`）与 `runShortNeighborBoundaryPull`（短邻章边界拉动由模块晋升、按键 paginate 在尽头被认领不回 limit）。本机实测：修复前 5 条 FAIL，修复后全部 68 条 OK（引擎产物是本机 systemTemp 里 2026-11-09 的 `fushi_full_engine_continuous.js` 按本次改动打补丁，未重新跑 dump 测试生成）。
  - `fushi/test/reader/continuous_seamless_chapters_test.dart` 新组「无缝模式是文档内换章的唯一所有者」：shell 默认实现、模块装饰、认领分支、触摸 / 滚轮 / paginate 三条通道认领在回传之前、Dart handler 的章号意图守卫。
  - `fushi/test/reader/reader_pagination_scripts_test.dart`：连续 paginate 返回契约随改。
- **备注**：Dart 测试未在本分支运行（本批次统一在合并后验证）。没有真机复测（Android WebView 上「长按」可能先触发选词，选词拖动时触摸边界控制器本就不换章——TODO-1317）。只在 continuous 模式生效；paginated / vn 不装无缝模块，`chapterTurnEpoch` / `claimBoundaryTurn` 只加在连续 shell，翻页与 VN shell 的换章路径未改。
