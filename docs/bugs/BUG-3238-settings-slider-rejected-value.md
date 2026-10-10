## BUG-3238 · 设置滑条松手后被拒绝的拖动值一直挂在滑块上
- **报告**：2026-10-10（PR #2034 审查遗留疑点）
- **真实性**：✅ 真 bug。`_KeyboardSlider` 松手（或键盘微调）后用 `_local` 保留拖动值，只在调用方 `value` 变化或恰好等于拖动值时才交还（`fushi/lib/src/utils/components/settings_shared.dart:3539`）。调用方拒绝新值（重建但 `value` 仍是旧值）时两个条件都不成立，滑块一直显示被拒绝的值，直到父级值下次变化。
- **[x] ① 已修复** — 松手 / 微调后调用方**第一次重建本控件**即交还：那次重建给出的 `value` 就是它的裁决（接受 = 新值，拒绝 / 钳制 = 旧值），不再要求值变化。提交在途、调用方尚未重建时仍保留拖动值（原设计的防弹回不变）。提交 fix(ui): hand a rejected slider value back to the caller on its next rebuild
- **[x] ② 已加自动化测试** — `fushi/test/widgets/settings_slider_release_bug3238_test.dart`（拒绝 → 回到调用方的值；修复前红。异步在途 → 保留拖动值、落地后显示新值）。
- **备注**：调用方拒绝后**完全不重建**的情况没有任何可观察信号可区分「提交在途」，按契约要求拒绝方重建（设置 schema 的 `_CommitOnReleaseSlider` 提交后都会 setState）。
