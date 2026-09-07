## BUG-2218 · 阅读器统计浮层今日/累计速度不套最小样本门槛
- **报告**：2026-09-06（用户：审查「小说统计是否会出现异常」）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/reader/reader_statistics_dialog.dart:277-284`：今日 / 累计 / 会话三张卡都走 `readingCharsPerHour`（无最小样本门槛），统计页走 `stat_trends.dart:38-41` 的 `computeCph`（< 60s 返 null 显示「-」）。同一天同一本书，浮层显示十万级字/时、统计页显示「-」；叠加 0 时长字数段（BUG-2210）更明显。
- **[x] ① 已修复** — 今日 / 累计卡改走 `readerBookSpeedLabel`（内部 `computeCph`，样本不足显示与统计页一致的「—」）；会话卡仍是实时秒表（开局即显 `0 / h`），`_metricCells` 加 `live` 参数分流。 提交：`bef9747e30`。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_statistics_dialog_test.dart`（`readerBookSpeedLabel` 样本不足显示「—」、足够时与 `computeCph` 同值；会话卡不受门槛影响）。
- **备注**：
