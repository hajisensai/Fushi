## BUG-970 · 统计页每日/每周目标从未设置时无任何设置入口
- **报告**：2026-07-21（用户：）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/pages/implementations/reading_statistics_page.dart:649-651` —— `_buildGoalPanel()` 在 `dailyGoal <= 0 && weeklyGoal <= 0` 时 `return const SizedBox.shrink()`，整块目标卡（含右上唯一的 `Icons.edit` 编辑入口 line 682-686）一起隐藏；而调 `_editGoals()` 的入口**只存在于该卡内部**（全文件仅 line 685 一处调用），页面顶栏 actions（line 352-364）只有刷新/清空。结果：全新安装、从未设过目标的用户，卡片不渲染 → 无任何 UI 能首次设置目标（先有鸡还是先有蛋）。TODO-1046 的「零视觉变化」意图把设置入口本身也一并藏没了。
- **[x] ① 已修复** —— 把目标设置入口提到页面顶栏 `HibikiPageScaffold.actions`（`Icons.flag_outlined`，tooltip 复用现成 `t.stat_goal_set`，`onTap: _editGoals`），与刷新/清空并列，**不受目标是否为 0 影响，始终可见**。目标卡仍保持两目标皆 0 时 `SizedBox.shrink()`（不破坏 TODO-1046 的零视觉变化红线）与卡内快捷 `Icons.edit`。提交见分支 `worktree-reading-goal-entry-bug970`。
- **[x] ② 已加自动化测试** —— `hibiki/test/pages/reading_statistics_goal_card_static_test.dart` 新增守卫：顶栏 actions 含 `Icons.flag_outlined` + `onTap: _editGoals` 的目标入口，且该入口位于 scaffold `actions`（`body:` 之前），不被任何 `dailyGoal`/`weeklyGoal` 条件包裹 —— 坐实首次设置入口恒可达。
- **备注**：复用 `stat_goal_set` 文案，不新增 i18n key。
