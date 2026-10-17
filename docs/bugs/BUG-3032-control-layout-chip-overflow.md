## BUG-3032 · 阅读器按钮布局编辑器长文案胶囊撑破窄槽
- **报告**：2026-10-06（PR #1984 M3E wave 1 CI：`test/reader/reader_control_layout_test.dart` 宽窄两档 RenderFlex 溢出 17/130/73px）
- **真实性**：✅ 真 bug。`fushi/lib/src/reader/reader_control_layout_editor.dart` 的 `_ChipFace.build`（外层 `Row` 约 702 行）：胶囊是 `mainAxisSize.min` 的 Row，文字不可收缩，长文案（槽宽约 313px、长译文）超出槽宽即右溢。
- **[x] ① 已修复** — `4f96dd647dc`：胶囊主体与文字改 `Flexible` + 单行省略；拖动反馈层（Overlay 内无界宽）经 `LayoutBuilder` 带上源胶囊的最大宽度，避免 Flexible 遇无界约束断言。
- **[x] ② 已加自动化测试** — 既有 widget 测试 `fushi/test/reader/reader_control_layout_test.dart`「渲染舞台七槽…宽窄两档不溢出」即覆盖（900 / 360 宽 `takeException` 为 null），修复后转绿。
- **备注**：本波（未合并的 PR #1984）引入的回归，未进发布。
