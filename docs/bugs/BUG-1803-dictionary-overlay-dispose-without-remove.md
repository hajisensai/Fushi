## BUG-1803 · 查词页根Overlay卸载时先dispose仍登记的OverlayEntry
- **报告**：2026-08-23（`iPhone pay` / iOS 26.6 物理机综合导入用例完成真实查词后，在 test teardown 卸载页面）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/home_dictionary_page.dart:298-304` 把 `OverlayEntry.mounted` 误当“仍登记在 Overlay”：根 Overlay/opaque cover 可先卸载 entry 的 widget 子树，使 `mounted=false`，但 entry 的私有 `_overlay` 仍非空；代码因此跳过 `remove()` 后直接 `dispose()`，触发 Flutter `'_overlay == null'` 断言。视频页同一 ownership 模式位于 `video_fushi_page.dart:3642-3649,4289-4297`。
- **[ ] ① 未修复** —
- **[ ] ② 未加自动化测试** — RED：物理机 `comprehensive_imports_test.dart` 完成查词截图后在 `_HomeDictionaryPageState.dispose` 抛错、exit 1；快速守卫 `fushi/test/utils/overlay_entry_lifecycle_test.dart` 先用 opaque entry 造出“`mounted=false` 但仍登记”的真实 Flutter 状态，修前缺少正确 helper，修后 1/1 GREEN。
- **备注**：新增 `removeAndDisposeOwnedOverlayEntry` 收口“字段非空即仍由 State 独占登记”的契约，查词页和视频页都无条件先 remove 再 dispose；Windows-only Texthooker 不在本次 Apple 平台范围，未修改。
