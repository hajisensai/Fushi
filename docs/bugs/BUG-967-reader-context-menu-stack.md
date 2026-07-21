## BUG-967 · Windows 查词弹窗后右键菜单位于底层且重复累加
- **报告**：2026-07-21（用户：）
- **真实性**：✅ 真 bug。`hibiki/lib/src/pages/implementations/reader_hibiki/chrome.part.dart:250` 由 `onSecondaryTapDown` fire-and-forget 调用，进入首次 JS await 前没有 single-flight 门控，连续右键可叠加多个 `PopupMenuRoute`；同时 Windows 原生 WebView2 弹层 surface 位于 Flutter route 上方，未先退回 warm slot 时新菜单会被压在底层。
- **[x] ① 已修复** — 本提交在 `reader_hibiki_page.dart:1090` 增加菜单在途状态，在首个 await 前加锁并由 `finally` 释放；确认选区有效后先 `_webviewPrunePopupStack(0)`，再显示唯一的 Flutter 右键菜单。
- **[x] ② 已加自动化测试** — `hibiki/test/reader/reader_context_selection_regression_guard_test.dart` 守卫加锁早于 JS await、WebView prune 早于 `showMenu`、菜单结束后必定解锁；聚焦测试 46/46 通过，`flutter analyze --no-pub` 0 问题。
- **备注**：前序实现已通过不抢前台的 Windows 阅读器集成矩阵 14/14；原始“右键菜单视觉层级”仍需前台人工肉眼操作，当前 PR 不自动抢占用户前台。
