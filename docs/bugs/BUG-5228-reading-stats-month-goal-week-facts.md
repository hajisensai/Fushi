## BUG-5228 · 阅读统计页字数环回退到月目标时只读本周数据，漏掉本月更早的字数
- **报告**：2026-11-22（外部审计 2026-11-22 项目审查 HBK-AUDIT-219，PR #4120）
- **真实性**：✅ 真 bug。统计页「今天」字数环用 `studyGoalStatsCharsGoal` 选目标，没有每日字数目标时会回退到周 / 月字数目标（`fushi/lib/src/stats/study_goals.dart:660`），分子交给与首页 / 小组件同一个 `computeStudyGoals`；但喂进去的全域日面固定只读本周（修前 `fushi/lib/src/pages/implementations/reading_statistics_page.dart:277` `StatFactsScope.since(_window.weekFromKey)`）。月目标的窗口是本月 1 日至今，本周之前的字数没读进来，统计页的环比首页 / 小组件少。
- **[x] ① 已修复** — 读日面的起点改由那条字数目标自己的周期窗口决定：`study_goals.dart` 新增 `studyGoalStatsCharsFactsFrom(goal, todayKey)`（= `studyGoalWindowStart(goal.period, today)`，没有字数目标时只要今天），统计页加载时先选目标再按它定读取范围；分子计算仍是首页同一个 `computeStudyGoals`，不另写一套。
- **[x] ② 已加自动化测试** — `fushi/test/pages/home_dashboard_page_test.dart`「HBK-AUDIT-219：阅读统计页字数环回退到月目标时…」（真统计页 widget：只设月字数目标，本月 1 日在本周之前时在那天记 500 字，环心读数须含它）；`fushi/test/stats/study_goal_period_test.dart`「HBK-AUDIT-219：统计页字数环读日面的起点…」（固定日期，日 / 周 / 月 / 无目标四种起点）。
- **备注**：widget 用例依赖当天日期，月初几天本月 1 日落在本周内时只验同口径；纯函数用例固定日期兜底。
