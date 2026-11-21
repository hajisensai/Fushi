## BUG-5140 · 首页「今日」格选了周 / 月主目标却显示第一条每日目标
- **报告**：2026-11-22（外部审计 Codex 2026-11-21 PR 审查 HBK-AUDIT-021，PR #3980）
- **真实性**：✅ 真 bug。设置「主目标」候选是全部目标记录（`fushi/lib/src/settings/settings_schema_study_goals.dart:557` `optionsBuilder` 列 `appModel.studyGoals`），而首页聚焦版式先按「左右滑动」缺省值 `daily` 只留每日目标（`fushi/lib/src/pages/implementations/home_dashboard_page.dart` `_todayGoals`，修前 4542 行），再在过滤后的列表里找主目标（同文件 `_todayGoalIndex`，修前 4532 行）：周 / 月主目标被过滤掉 → `indexWhere` 得 -1 → 落到第 0 页，显示第一条每日目标的环和进度。两项设置各自一套选择规则，互相矛盾。
- **[x] ① 已修复** — 选择规则只写一次：`fushi/lib/src/stats/study_goal_record.dart` 新增纯函数 `studyGoalTodayPages`（页 = 滑动范围内的目标 ∪ 主目标，记录顺序；没有每日目标时退回全部）与 `studyGoalTodayPageIndex`；首页 `_todayGoals` / `_todayGoalIndex` 改为只调它们。
- **[x] ② 已加自动化测试** — `fushi/test/stats/study_goal_record_test.dart`「today pages (HBK-AUDIT-021)」（周 / 月主目标与每日目标共存、无 / 失效主目标、全部范围、无每日目标）；`fushi/test/pages/home_dashboard_page_test.dart`「HBK-AUDIT-021 今日格：…周主目标照样显示、与每日目标共存」（真首页 widget：起始页是周主目标、两个圆点、月目标不进页）。
- **备注**：左右滑动会把滑到的那页写成主目标（PR 原设计）。范围是「每日」时滑离周 / 月主目标后，它不再是主目标，也就不在滑动范围里；要再看它需在设置里重选或把范围改成「全部目标」。这是两项设置共用一个偏好的既有语义，未改。真机未复测。
