## BUG-3247 · 顶栏动作紧跟返回键时自适应溢出少算 8px 提前收进溢出菜单
- **报告**：2026-10-10（PR #2040 审查遗留疑点复核时发现）
- **真实性**：✅ 真 bug（与审查原疑点方向相反）。原疑点「leading 为空时预算多加 8px」不成立：`fushiTopBarActionsBudget` 末尾减的 8 是行尾动作组前的间距，`actionsFollowLeading` 时 Row 里没有这段间距（有前置胶囊时其后的 8 已计入 leading slot；没有前置胶囊时动作组就是行首），加回 8 后预算恰好 = 实际可用宽。真正的问题是这个 +8 只加在带字排法（`inlineLabels`）的预算里（`fushi/lib/src/utils/components/fushi_floating_toolbar.dart:1046`），默认的自适应溢出路径 `_visibleFor`（`fushi_floating_toolbar.dart:1105`）没加：紧跟返回键排时预算比实际少 8，宽度只差几像素时把本该平铺的动作收进「⋯」，违背「默认展开、空间不足才收起」。
- **[x] ① 已修复** — 两条测宽路径共用 `_actionsBudget(maxWidth, hasTitle:)`，follow 且无标题时加回 8（与 build 里 `follow` 判据一致）。提交 fix(ui): share the follow-leading action budget across both top bar fit paths
- **[x] ② 已加自动化测试** — `fushi/test/widgets/fushi_floating_top_bar_adaptive_overflow_test.dart`「actionsFollowLeading 的宽度预算与排法一致」（有前置胶囊恰好放得下不收起——修复前红；无前置胶囊预算 = 整行宽，少 1px 收起且不溢出）。
- **备注**：
