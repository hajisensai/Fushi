import 'package:fushi_core/fushi_core.dart';

/// 统计窗口阈值的**唯一**定义（v92 统计域重构）。
///
/// 此前四处各写一遍 `statDateKey(now - 7d)` / `- 30d` 并用 `>=` 比较：「近 7 天」
/// 实际含 8 个自然日、「近 30 天」含 31 天，而环比的「上周」窗口 `[now-14d, now-7d)`
/// 恰 7 天——本周系统性偏大、环比结构性偏正（阅读页 / 视频页 / 游戏页 / 首页各一份，
/// 还互相不一致）。这里只有一个定义：`days(n)` = 含今日在内的 **恰 n 个自然日**；
/// 「本周」= 自然周（起始日 = [weekStartDay]，缺省周一，2026-10-09；2026-11 起可在
/// 设置 › 目标 › 计数里改成周日 / 周六），上周 = 上周同期（与本周已过天数同长）。
///
/// dateKey 是零填充的 `yyyy-MM-dd`，字典序即时间序，比较全走字符串。
///
/// 「今日」的边界不是本地午夜而是 [FushiDatabase.statDayResetHour]（用户可配的
/// 整点，默认 0）：`todayKey` 与所有「N 天前」都从 [FushiDatabase.statDateKeyOf]
/// 派生再做 key 算术，不得再用 `DateTime(y, m, d)` 合成本地午夜当今日——
/// 重置时刻 = 4 点时凌晨 2 点仍属「昨日」，合成午夜会把它错切到日历今日。
class StatWindow {
  StatWindow(DateTime now) : this._(now, FushiDatabase.statDateKeyOf(now));

  StatWindow._(DateTime now, String today)
    : todayKey = today,
      weekFromKey = weekStartOf(today),
      prevWeekFromKey = FushiDatabase.statDateKeyPlusDays(
        weekStartOf(today),
        -7,
      ),
      prevWeekToKey = FushiDatabase.statDateKeyPlusDays(today, -7),
      monthFromKey = _keyDaysAgo(now, 29),
      _now = now;

  final DateTime _now;

  /// 本窗口的锚时刻（构造时传入的 now）。消费方按同一个窗口做「小时/分钟级」判据
  /// （近 7 天曲线的当日切片、活动流分组）时必须用它，不许现调 `DateTime.now()`
  /// ——那会让聚合与谓词落在两个时刻上，跨午夜时「今日」卡与明细对不上（BUG-2219）。
  DateTime get now => _now;

  /// 今日。
  final String todayKey;

  /// 本周起点（含）= 今日所在**自然周的第一天**（[weekStartOf]，统计日口径）：
  /// `[weekFromKey, todayKey]` 是本周已过的 1–7 天。与统计中心范围条「周」粒度
  /// （`StatRange`）同一口径——2026-10-09 起「本周」只有这一个意思（此前是滚动近
  /// 7 天，与范围条的「周」数字对不上）。滚动近 7 天用 [lastDayKeys]`(7)`。
  final String weekFromKey;

  /// 上周同期起点（含）= 上周的第一天。
  final String prevWeekFromKey;

  /// 上周同期终点（含）= 今日 - 7 天：`[prevWeekFromKey, prevWeekToKey]` 与本周
  /// 已过天数**同长**、不重叠（周三对比上周一至周三，环比不被「不满一周」拖成负数）。
  final String prevWeekToKey;

  /// 近 30 天窗口起点（含）：`[monthFromKey, todayKey]` 恰 30 天。
  final String monthFromKey;

  bool isToday(String dateKey) => dateKey == todayKey;

  bool inWeek(String dateKey) =>
      dateKey.compareTo(weekFromKey) >= 0 && dateKey.compareTo(todayKey) <= 0;

  bool inPrevWeek(String dateKey) =>
      dateKey.compareTo(prevWeekFromKey) >= 0 &&
      dateKey.compareTo(prevWeekToKey) <= 0;

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

  /// 一周从星期几开始（[DateTime.monday] / [DateTime.sunday] / [DateTime.saturday]…，
  /// 1–7）。偏好 `stat_week_start`（随 Profile）的镜像：AppModel 在偏好加载后、切
  /// Profile 与用户改设置时写这里，与 [FushiDatabase.statDayResetHour] 同一种做法
  /// ——它和日界一样是「统计日 key → 窗口」派生的输入，各处窗口谓词不该各自读偏好。
  static int weekStartDay = DateTime.monday;

  /// [dateKey] 所在自然周的第一天（dateKey 口径，周起始日 = [weekStartDay]）。
  /// [weekFromKey]、学习目标的周窗口（`study_goal_period.dart`，首页 / 小组件 / 统计
  /// 页同一个分子）与范围条的「周」都从这一处取，「本周」只有一个定义。
  static String weekStartOf(String dateKey) {
    final int weekday = FushiDatabase.statDateKeyToDay(dateKey).weekday;
    return FushiDatabase.statDateKeyPlusDays(dateKey, -dayOfWeek(weekday));
  }

  /// [weekday]（[DateTime.weekday]，1 = 周一 … 7 = 周日）在本周里是第几天
  /// （0 = 周起始日 [weekStartDay] … 6）。热力图的行、趋势的周桶、小组件热力图的
  /// 首行偏移都从这里取，不各自假设周一。
  static int dayOfWeek(int weekday) => (weekday - weekStartDay) % 7;

  /// [day]（日历日，本地午夜）所在自然周的第一天（本地午夜）。按日历日做加减，
  /// 不受夏令时切换影响。
  static DateTime weekStartOfDay(DateTime day) =>
      DateTime(day.year, day.month, day.day - dayOfWeek(day.weekday));

  static String _keyDaysAgo(DateTime now, int days) =>
      FushiDatabase.statDateKeyPlusDays(
        FushiDatabase.statDateKeyOf(now),
        -days,
      );
}
