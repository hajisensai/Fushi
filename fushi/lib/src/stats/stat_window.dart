import 'package:fushi_core/fushi_core.dart';

/// 统计窗口阈值的**唯一**定义（v92 统计域重构）。
///
/// 此前四处各写一遍 `statDateKey(now - 7d)` / `- 30d` 并用 `>=` 比较：「近 7 天」
/// 实际含 8 个自然日、「近 30 天」含 31 天，而环比的「上周」窗口 `[now-14d, now-7d)`
/// 恰 7 天——本周系统性偏大、环比结构性偏正（阅读页 / 视频页 / 游戏页 / 首页各一份，
/// 还互相不一致）。这里只有一个定义：`days(n)` = 含今日在内的 **恰 n 个自然日**。
///
/// dateKey 是零填充的 `yyyy-MM-dd`，字典序即时间序，比较全走字符串。
///
/// 「今日」的边界不是本地午夜而是 [FushiDatabase.statDayResetHour]（用户可配的
/// 整点，默认 0）：`todayKey` 与所有「N 天前」都从 [FushiDatabase.statDateKeyOf]
/// 派生再做 key 算术，不得再用 `DateTime(y, m, d)` 合成本地午夜当今日——
/// 重置时刻 = 4 点时凌晨 2 点仍属「昨日」，合成午夜会把它错切到日历今日。
class StatWindow {
  StatWindow(DateTime now)
    : todayKey = FushiDatabase.statDateKeyOf(now),
      weekFromKey = _keyDaysAgo(now, 6),
      prevWeekFromKey = _keyDaysAgo(now, 13),
      monthFromKey = _keyDaysAgo(now, 29),
      _now = now;

  final DateTime _now;

  /// 今日。
  final String todayKey;

  /// 近 7 天窗口起点（含）：`[weekFromKey, todayKey]` 恰 7 天。
  final String weekFromKey;

  /// 上一个 7 天窗口起点（含）：`[prevWeekFromKey, weekFromKey)` 恰 7 天，与本周不重叠。
  final String prevWeekFromKey;

  /// 近 30 天窗口起点（含）：`[monthFromKey, todayKey]` 恰 30 天。
  final String monthFromKey;

  bool isToday(String dateKey) => dateKey == todayKey;

  bool inWeek(String dateKey) =>
      dateKey.compareTo(weekFromKey) >= 0 && dateKey.compareTo(todayKey) <= 0;

  bool inPrevWeek(String dateKey) =>
      dateKey.compareTo(prevWeekFromKey) >= 0 &&
      dateKey.compareTo(weekFromKey) < 0;

  bool inMonth(String dateKey) =>
      dateKey.compareTo(monthFromKey) >= 0 && dateKey.compareTo(todayKey) <= 0;

  /// 含今日在内最近 [n] 天的 dateKey，升序（图表补齐空日期用）。
  List<String> lastDayKeys(int n) => <String>[
    for (int i = n - 1; i >= 0; i--) _keyDaysAgo(_now, i),
  ];

  /// 到下一个统计日边界（[FushiDatabase.statDayResetHour] 整点）的时长（恒 > 0）。
  /// 统计页 / 首页用它排一次性 Timer：跨边界后整页重聚合，让加载时的窗口与卡片
  /// 谓词永远是同一个 [StatWindow]（BUG-2219：此前聚合用加载时刻、卡片谓词在点击
  /// 时现算，跨午夜后「今日」卡的数和明细对不上）。按日历取下一个边界时刻
  /// （DST 切换日不是恰 24h）。
  static Duration untilNextStatDayBoundary(DateTime now) =>
      FushiDatabase.untilNextStatDayBoundary(now);

  static String _keyDaysAgo(DateTime now, int days) =>
      FushiDatabase.statDateKeyPlusDays(
        FushiDatabase.statDateKeyOf(now),
        -days,
      );
}
