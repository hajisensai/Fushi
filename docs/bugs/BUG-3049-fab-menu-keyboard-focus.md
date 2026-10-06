## BUG-3049 · FushiFabMenu 键盘展开后焦点留在 FAB：首帧菜单项不在树里，后帧回调 requestFocus 落空
- **报告**：2026-10-06（PR #1984 CI：`fushi_expressive_controls_test`「FushiFabMenu … Esc 收起焦点回 FAB」红，Enter 展开后 `fabFocus.hasFocus` 仍为 true）
- **真实性**：✅ 真 bug（交互契约）。`FushiFabMenuState._setOpen(true)` 在 FAB 有焦点时排后帧回调把焦点移进最近的菜单项；但菜单项的 `AnimatedBuilder` 在弹簧值 ≤ 0.001 时返回 `SizedBox.shrink()`，展开首帧弹簧还停在 0，菜单项（含其 FocusNode）不在树里，`requestFocus` 落在未挂载的节点上，焦点留在 FAB，键盘 / 手柄用户展开后无法直接上下遍历菜单项。只有「减少动画」下（瞬间展开）正常。
- **[x] ① 已修复** — 收起时才摘掉菜单项，展开途中（含首帧 visible 为 0）保留在树里（`fushi/lib/src/utils/components/glass/fushi_expressive_controls.dart:1243`）。提交见下。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/glass/fushi_expressive_controls_test.dart`「FushiFabMenu 点开展开菜单项、点项执行并收起；Esc 收起焦点回 FAB」（Enter 展开后焦点离开 FAB、Esc 收起后回到 FAB）。
- **备注**：
