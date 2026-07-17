## BUG-868 · 开EPUB偶发卡住·内容就绪兜底超时漏复位导航态致翻页永久失效

- **报告**：2026-07-17（用户：）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/pages/implementations/reader_hibiki/navigation.part.dart:41-58`（`_startContentReadyTimeout` 超时回调）+ `chrome.part.dart:39-40`（`_paginationInFlight` getter）。
  - 内容就绪兜底看门狗 `_startContentReadyTimeout` 的超时回调只 `_rebuild(_readerContentReady = true)` 摘掉 loading 遮罩，**漏了复位** `_restoreInFlight` / `_isNavigatingToChapter` / `_restoreCompleter`。
  - 当 `window.hoshiReader` 偶发不回 `onRestoreComplete`（`webview.part.dart` 的 `onRestoreComplete` / `_onRestoreComplete` 从不被触发）时，遮罩被兜底摘掉、书**看似打开**，但 `_paginationInFlight = _restoreInFlight || !_readerContentReady || _isNavigatingToChapter` 因前两项恒真而恒真 → `_paginate` / `onBoundarySwipe` 的翻页 tick 全被守卫吞掉 → **翻页永久失效、进度不保存**。
  - 对比正常路径 `_onRestoreComplete`（navigation.part.dart:86-90）确实复位了这三者；兜底超时路径漏了。既有等待超时收尾 `_navigateToChapterAndWait`（navigation.part.dart:504-506）也证明这三者本该一起解开。
- **[x] ① 已修复** — `navigation.part.dart` 超时回调在强制 `_readerContentReady = true` 的同一路径补 `_isNavigatingToChapter = false` + `_failNavigation()`（清 `_restoreInFlight`、`complete(false)` 并清空 `_restoreCompleter`，放行等待方），与 `_navigateToChapterAndWait` 的等待超时收尾同构。提交见本轮 commit。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/reader_content_ready_timeout_unwind_guard_static_test.dart`：源码语料守卫，断言超时回调体内同时含 `_readerContentReady = true` / `_isNavigatingToChapter = false` / `_failNavigation()`，且 `_failNavigation` helper 仍清 `_restoreInFlight` 并 complete/清空 completer。删掉任一复位即红。ReaderHibikiPage 过重（WebView + 音频 + 全 ProviderContainer）无法在 widget test 可靠拉起跑该超时回调，故落最强可落地的源码层（与 reader_* 一系列 *_static_test 同纪律）。
- **备注**：根因分析由用户对着原始源码多次核对给出，本轮独立复核数据流后确认无误。修复不引入延迟/重试/吞异常，纯粹补齐兜底路径本该做的状态解锁。真机复测「反复开合同一 EPUB 直到触发兜底超时 toast，随后仍能翻页 + 退出重进进度保住」待用户在指定设备验证。
