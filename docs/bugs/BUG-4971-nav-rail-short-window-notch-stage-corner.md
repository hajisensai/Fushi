## BUG-4971 · 窗口矮时左侧导航栏排不开，选中项缺口贴到底部和内容区左下圆角撞出缺口
- **报告**：2026-11-20（用户：11-20 反馈截图 29，Windows 约 830×717 逻辑像素，深色，设置页；「位置不够改一下这个」）
- **真实性**：✅ 真 bug。沿代码路径核实：
  - 缺口错位：镂空脊侧栏的列表视口底边只离侧栏底 12（`fushi/lib/src/utils/adaptive/adaptive_navigation.dart:1207`，原 `EdgeInsetsDirectional.fromSTEB(..., 12)`），缺口按视口截住（`fushi/lib/src/utils/adaptive/nav_rail/nav_rail_look.part.dart:178`），再往下画 24 的内凹圆角；而舞台起始边左下大圆角占 44×1.25=55 高（`nav_rail_look.part.dart:331` 的 `_RailStageCornerPainter` 在这一段补侧栏色）。当前项被挤到最底部时缺口连同内凹圆角伸进舞台圆角区，被补角的侧栏色盖掉一块 → 红箭头处的缺口 / 错位。窗口够高时 Column 顶对齐，末项不会贴底，所以只在矮窗口出现。
  - 排不开：侧栏行距写死（收起 52+上下 4 = 60、展开 56），不看可用高度，矮窗口只能滚、头像下露出半截条目。
- **[x] ① 已修复** — 根因修：镂空脊列表视口与侧栏底边之间留出「舞台圆角高 + 内凹圆角 + bleed」（`_kRailNotchBottomInset`），顶部余量也移到视口外；缺口按视口外扩 bleed 截住，截住后仍完整落在舞台直边上。行距随可用高度切紧凑档（收起 60→52、展开 56→48，命中区仍 ≥48dp），还放不下才滚动，不裁条目。（提交见 PR）
- **[x] ② 已加自动化测试** — `fushi/test/widgets/nav_rail_short_window_test.dart`：收起 / 展开 × 717 / 600 / 480 / 400 高，选中末项时缺口完整且不伸进舞台上下圆角、每一项都能滚进视口、无 overflow；矮窗口行距变紧凑且 ≥48。
- **备注**：像素证据见 PR（widget test 渲染，深色 / 浅色各一张）。真 app 肉眼复测待补（本 PR 只做了 widget 真实像素渲染）。
