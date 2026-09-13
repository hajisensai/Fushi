## BUG-2224 · 统计环比无上限显示 ↑9999900%
- **报告**：2026-09-06（用户：审查「小说统计是否会出现异常」）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/pages/implementations/stat_summary.dart:75-78`（`computeWeekOverWeekPercent` 无上限）→ `reading_statistics_page.dart:608-613` 直接格式化：上周 1 字本周 10 万字显示「↑9999900%」。
- **[x] ① 已修复** — 新增纯函数 `formatWeekOverWeekDelta`：基期 0 → `—`（无基线不是涨 ∞%），≥ `kWeekOverWeekPercentCap`(999) → `↑>999%`，其余四舍五入整数；KPI 条改用它。 提交：`bef9747e30`。
- **[x] ② 已加自动化测试** — `fushi/test/pages/stat_summary_test.dart`（`formatWeekOverWeekDelta` 四类输入）。
- **备注**：
