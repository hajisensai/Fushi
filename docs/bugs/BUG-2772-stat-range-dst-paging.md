## BUG-2772 · 统计范围「周」翻段在 DST 切换周翻不动 / 多跳一周
- **报告**：2026-09-29（代码审查：PR #1739 引入的统计中心范围条）
- **真实性**：✅ 真 bug（沿代码路径定位；node 在 `TZ=Europe/Berlin` / `America/New_York` 下复算同一时刻算术已复现）。根因：
  1. `fushi/lib/src/stats/stat_range.dart:146`（旧）`StatRange.shifted` 周模式 `statDateKeyToDay(fromKey).add(Duration(days: 7 * step))`：`statDateKeyToDay` 是本地午夜，DST 切换周不是 168 小时。秋季回拨周（EU 2026-10-19 起 / US 2026-10-26 起）「下一段」落到本周日 23:00，锚点仍在本周 → 翻不动；春季拨快周（EU 2026-03-30 / US 2026-03-09 所在周）「上一段」落到前前周周日 23:00 → 多跳一周。
  2. `fushi/lib/src/stats/stat_range.dart:121`（旧）`dayCount` 用两个本地午夜 `difference().inDays`：区间含春季切换日时只有 N 天减 1 小时，`inDays` 少算一天，`dayKeys` 少最后一天（图表缺末日、周 / 月合计漏一天）。
  - 同文件其它日期算术已排查：日 / 月 / 年翻段与区间解析都走 `DateTime(y, m, d ± n)` 构造或 `statDateKeyPlusDays`，是日历算术，不受 DST 影响；夹到今日是 dateKey 字典序比较，无问题。
- **[x] ① 已修复** — 分支 `fix/stat-range-dst`：周翻段改走 `FushiDatabase.statDateKeyPlusDays(fromKey, 7 * step)`（日历日算术）；新增纯函数 `statDateKeyDaysBetween`（UTC 日历上相减，只看年月日），`dayCount` 改用它。
- **[x] ② 已加自动化测试** — `fushi/test/stats/stat_range_test.dart` 的「BUG-2772 DST 切换周翻段 / 日数」组：EU / US 2026 年四个切换周的上下翻段、含切换日区间的 `dayCount` / `dayKeys`（有 DST 的宿主时区直接复现旧行为）；`statDateKeyDaysBetween` 键算术断言；源码守卫（`stat_range.dart` 不得出现 `Duration(days`，`.inDays` 只许出现在 UTC helper 里）——UTC 宿主上旧代码不出错，由守卫保证任何宿主时区都能拦住回归。
- **备注**：本机无 Dart/Flutter 工具链，本文件与索引行按 `tool/bug.dart` 骨架 / `buildIndexTable` 格式手写，测试与 analyze 未在本地执行；合入前请跑 `dart run tool/bug.dart reindex` / `check` 复核。
