## BUG-3623 · manga-turn-queue-silent-stall
- **报告**：2026-10-20（用户：Windows 上漫画用滚轮没办法翻页，或者说特别卡，重新进就好了）
- **真实性**：⚠️ 现象可信、根因未定。证据：`~/Documents/study_diag_log.txt` 里《志乃と恋 3》14:56:04–14:57:15、15:02:04–15:02:42 两段有连续输入（clock start/stop）却零 `+2p` 翻页记录；`error_log.txt` 同时段无任何漫画报错 → 不是异常，是静默挂起。结构性风险点：`MangaTurnQueue.drain`（`fushi/lib/src/media/manga/reader/manga_fushi_page.dart`）串行 `await applyStep`，`_applyMangaTurnStep` 内 `evaluateJavascript` / `_tryPanelTurn` / `_onReachedChapterEdge` / `_replaceSpreadOcr`，以及 `_loadInitialWindow` 的 `loadData`，任一永不返回都会让 `_draining` / `_navigating` 永久为 true，之后所有翻页只累加 `pendingDelta`、不再消费，直到重进页面。已排除：Windows fork 的 JS→Dart `callHandler` 是全异步回调（`packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview.cpp:772-806`），不会与 drain 中的 `evaluateJavascript` 互锁；JS 滚轮路径（`_wheelLock` / `_wheelPan`）无永久卡死态。
- **[ ] ① 未修复** — 本轮只加诊断（只记录不干预）：翻页步骤 / 换窗加载超过 5 秒未返回，向 error_log 写 `MangaFushiPage.turnStall`（卡住的阶段 `turnWithinPage` / `panelTurn` / `chapterEdge` / `applyTranslate` / `replaceOcr` / `loadData` / `awaitDocumentGeneration` + spread / navigating / switchingChapter / pendingDelta / draining）。复现后按该条定根因再修。
- **[ ] ② 未加自动化测试** — 根因定位后补。
- **备注**：
