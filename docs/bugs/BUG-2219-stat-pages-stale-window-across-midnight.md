## BUG-2219 · 统计页跨午夜后聚合窗口与卡片谓词不一致
- **报告**：2026-09-06（用户：审查「小说统计是否会出现异常」）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/pages/implementations/reading_statistics_page.dart:254-257`（`_computeAggregates` 用加载时 `now`）vs `:772-782`（`_buildSummaryCards` 点击时现算 `StatWindow(DateTime.now())` 传 `w.isToday` 给 sheet）；视频页 `:272`、游戏页 `:167` 同型。首页反向：`home_dashboard_page.dart:1994-1996` build 里现取 `todayKey`、分子仍是旧 `_dailyRows`。跨午夜后卡面「今日 N 字」、点开明细为空；首页目标环归零不再涨。无跨日定时刷新。
- **[x] ① 已修复** — 四个页面把本轮加载时的 `StatWindow` 存成字段（`_window` / `_statWindow`），聚合、「各来源」谓词、时段卡谓词、目标卡、近 7 日日均全部吃同一个；`StatWindow` 新增 `now` getter 与纯函数 `untilNextLocalMidnight`（按日历取次日 0 点，DST 日不是恰 24h），页面据此排一次性 `_midnightReload` Timer 整页重聚合（dispose 取消）。 提交：`bef9747e30`。
- **[x] ② 已加自动化测试** — `fushi/test/stats/stat_window_test.dart`（`untilNextLocalMidnight` 恒 > 0、23:59:59 → 1s、跨 DST 按日历）+ 源码守卫 `fushi/test/pages/stat_pages_single_window_guard_static_test.dart`（三个统计页 `_buildSummaryCards` 不得现算窗口、必须挂午夜 Timer；首页目标卡吃 `_statWindow`）。
- **备注**：
