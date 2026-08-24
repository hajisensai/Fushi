## BUG-1824 · 查词页根Overlay卸载时先dispose仍登记的OverlayEntry
- **报告**：2026-08-23（`iPhone pay` / iOS 26.6 物理机综合导入用例完成真实查词后，在 test teardown 卸载页面）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/home_dictionary_page.dart:298-304` 把 `OverlayEntry.mounted` 误当“仍登记在 Overlay”：根 Overlay/opaque cover 可先卸载 entry 的 widget 子树，使 `mounted=false`，但 entry 的私有 `_overlay` 仍非空；代码因此跳过 `remove()` 后直接 `dispose()`，触发 Flutter `'_overlay == null'` 断言。视频页同一 ownership 模式位于 `video_fushi_page.dart:3642-3649,4289-4297`。
- **[x] ① 已修复** — 查词/视频 owned entry 无条件 remove 后 dispose；提交 `bb1f2ddf7`。
- **[x] ② 已加自动化测试** — `overlay_entry_lifecycle_test.dart` 与 iPhone 综合导入 teardown GREEN；RED 曾在 `_HomeDictionaryPageState.dispose` 抛错、exit 1。
- **备注**：新增 `removeAndDisposeOwnedOverlayEntry` 收口“字段非空即仍由 State 独占登记”的契约，查词页和视频页都无条件先 remove 再 dispose；Windows-only Texthooker 不在本次 Apple 平台范围，未修改。
