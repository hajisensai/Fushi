## BUG-3048 · FushiPressMorph 停用后仍响应按钮状态回调，在已停用元素上查 Theme 断言
- **报告**：2026-10-06（PR #1984 CI：`fushi_expressive_controls_test` FushiToggleButton 用例报「Looking up a deactivated widget's ancestor is unsafe」）
- **真实性**：✅ 真 bug。按钮子树卸载时 InkWell 的 `TapGestureRecognizer.dispose` → `handleTapCancel` → `WidgetStatesController.update(pressed, false)`，监听者 `_FushiPressMorphState._onStates`（`fushi/lib/src/utils/components/glass/fushi_expressive.dart`）此时已停用但 `mounted` 仍为 true，`_setPressed` 里 `fushiExpressiveMotionEnabled(context)` → `Theme.of` 在停用元素上查祖先断言。按住按钮时它被移出树（导航走 / 列表刷新）即触发。`_FushiSplitButtonState`（`fushi_expressive_controls.dart`）自持两个 statesController，回调里同样查 context，同一缺陷。
- **[x] ① 已修复** — `FushiPressMorph` 在 `deactivate` 摘监听、`activate` 挂回并对齐（`fushi_expressive.dart:382`）；`FushiSplitButton` 记停用标记，停用期间不响应状态 / 开合回调，重新激活时对齐菜单开合（`fushi_expressive_controls.dart:529`）。提交 `e11c48323f3`。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/glass/fushi_expressive_controls_test.dart` 组「按住时移出树（BUG-3048）」：FushiFilledButton / FushiSplitButton 按住时移出树，断言无异常。
- **备注**：
