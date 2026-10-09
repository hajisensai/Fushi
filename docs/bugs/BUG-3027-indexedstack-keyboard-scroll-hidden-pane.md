## BUG-3027 · 键盘翻页滚到 IndexedStack 隐藏子区（Flutter 3.47 IndexedStack 不再包 Visibility）
- **报告**：2026-10-06（PR #1984 CI：`global_keyboard_scroll_test` 「IndexedStack 停在 index≥1 的子区」红）
- **真实性**：✅ 真 bug。Flutter 3.47 的 `IndexedStack.build`（`packages/flutter/lib/src/widgets/indexed_stack.dart`）不再给每个 child 包 `Visibility(visible: i == index)`，改包私有 `_VisibilityScope` + `ExcludeFocus`。`fushi/lib/src/focus/fushi_focus_scroll.dart` 的 `_hidesSubtree` 只按 widget 类型认 `Offstage` / `Visibility`，于是全局键盘 / 手柄翻页（PageDown / End 等）的目标解析会把 IndexedStack 里**隐藏**的子区当成可见：第 4 级兜底按树序取到第一个（隐藏的）列表去滚，可见列表不动。
- **[x] ① 已修复** — `_positionIsPresented` 与第 4 级兜底遍历对 Scrollable 的 context 再查 SDK 公开判据 `Visibility.of`（`Visibility` 与新 IndexedStack 都经 `_VisibilityScope` 上报），仍不对 IndexedStack 做按 index 的特例。提交 04038faed84。
- **[x] ② 已有自动化测试** — `fushi/test/shortcuts/global_keyboard_scroll_test.dart` 「审查返工：可见性判据 / IndexedStack 停在 index≥1 的子区」（升 3.47 前就在，升级后转红，修复后转绿）。
- **备注**：工具链升级（3.44 → 3.47）带出的回归，不是 M3E 改造本身引入。
