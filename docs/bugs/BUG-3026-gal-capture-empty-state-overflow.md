## BUG-3026 · 采集设置线程栏 M3E 空态在 1400x900 窗口溢出
- **报告**：2026-10-06（PR #1984 CI：`test/pages/gal_capture_setup_lookup_priority_test.dart` 三条红）
- **真实性**：✅ 真 bug。b96bbe2（M3E 采集设置对话框）把线程栏的空态从一行 `Text` 换成 `FushiPlaceholderMessage`（72px 色块 + 标题 + 页边距）；在 1400×900 的常见桌面窗口里线程栏 `Expanded` 只剩约 120px，空态 Column 被约束到 87.6px 高，`fushi_placeholder_message.dart:163` 的 Column 溢出 24px（黄黑条纹）。根因在调用点 `fushi/lib/src/pages/implementations/gal_capture_setup_dialog.dart` `_buildThreadPane` 的空态分支：把固有高度不小的空态直接塞进可能很矮的 `Expanded`。
- **[x] ① 已修复** — `gal_capture_setup_dialog.dart` `_buildThreadPane` 空态外包 LayoutBuilder + SingleChildScrollView + minHeight（95fbe107cc5）
- **[x] ② 已加自动化测试** — 既有 `fushi/test/pages/gal_capture_setup_lookup_priority_test.dart`（1400×900 下 `takeException()` 为 null，三条转绿）
- **备注**：修法：空态外包 `LayoutBuilder` + `SingleChildScrollView` + `ConstrainedBox(minHeight: maxHeight)`——放得下时照常居中，放不下时可滚动，不裁、不溢出。没改共享组件 `FushiPlaceholderMessage`（它也被放进 `IntrinsicWidth` 一类容器，组件内挂 `LayoutBuilder` 会在那些场景抛错）。
