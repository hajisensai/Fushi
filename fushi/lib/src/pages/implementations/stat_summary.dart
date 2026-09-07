import 'dart:math' as math;

import 'package:fushi/src/pages/implementations/stat_activity.dart';
import 'package:fushi/src/pages/implementations/stat_charts.dart';
import 'package:fushi/src/pages/implementations/stat_trends.dart';
import 'package:fushi_core/fushi_core.dart';

/// 「范围与趋势」折线图的指标维度：字数 / 时长 / 速度。
/// 参考设计顶部图的指标切换（macOS 统计页）。
enum StatTrendMetric { chars, time, speed }

/// 纯函数：把一个趋势点按 [metric] 映射成折线图纵轴的原始值。
/// - [StatTrendMetric.chars]：字数（原值）。
/// - [StatTrendMetric.time]：分钟（ms / 60000，用 double 保留精度）。
/// - [StatTrendMetric.speed]：阅读速度 cph（复用 [StatTrendPoint.cph]）。
double trendMetricValue(StatTrendPoint p, StatTrendMetric metric) {
  switch (metric) {
    case StatTrendMetric.chars:
      return p.chars.toDouble();
    case StatTrendMetric.time:
      return p.ms / 60000.0;
    case StatTrendMetric.speed:
      return p.cph;
  }
}

/// 纯函数：把 [metric] 下的纵轴值格式化为坐标轴标签。
String trendMetricAxisLabel(double v, StatTrendMetric metric) {
  switch (metric) {
    case StatTrendMetric.chars:
      return formatStatCharsAxis(v.round());
    case StatTrendMetric.time:
      // v 已是分钟。
      final int minutes = v.round();
      if (minutes >= 60) return '${(minutes / 60).toStringAsFixed(1)}h';
      return '${minutes}m';
    case StatTrendMetric.speed:
      return formatStatCphAxis(v);
  }
}

/// 纯函数：连续阅读天数（streak）。
///
/// [activeDayKeys] 是有阅读记录的 dateKey 集合（形如 `2026-06-07`），[now] 为参考
/// 时刻。从今天开始逐日回溯：若今天无记录但昨天有，则从昨天起算（当天尚未阅读不
/// 中断连击）；否则从今天起算。遇到第一个无记录的日子停止。
int computeReadingStreak(Set<String> activeDayKeys, DateTime now) {
  if (activeDayKeys.isEmpty) return 0;
  // 「今日」按统计日边界（可配重置时刻）取 key，之后全走 key 算术，不合成午夜。
  final String todayKey = statDateKey(now);
  final String yesterdayKey = FushiDatabase.statDateKeyPlusDays(todayKey, -1);
  // 起点：今天有记录从今天算；否则昨天有记录从昨天算；都没有则 streak=0。
  String cursor;
  if (activeDayKeys.contains(todayKey)) {
    cursor = todayKey;
  } else if (activeDayKeys.contains(yesterdayKey)) {
    cursor = yesterdayKey;
  } else {
    return 0;
  }
  int streak = 0;
  while (activeDayKeys.contains(cursor)) {
    streak++;
    cursor = FushiDatabase.statDateKeyPlusDays(cursor, -1);
  }
  return streak;
}

/// 纯函数：本周相对上周的百分比变化（week-over-week）。
///
/// [thisWeek] / [lastWeek] 为同一指标（字数或时长ms）的两周聚合值。上周为 0（无基线，
/// 例如新用户或上周没读）时返回 `null`——此时「涨了 ∞%」没有意义，调用方应改为不显示
/// 环比，而不是显示一个爆表数字。正常返回带符号的百分比（正=涨、负=跌）。
double? computeWeekOverWeekPercent(int thisWeek, int lastWeek) {
  if (lastWeek == 0) return null;
  return (thisWeek - lastWeek) / lastWeek * 100.0;
}

/// 环比展示上限（百分比）。上周 1 字、本周 1 万字的「↑999900%」没有信息量
/// （BUG-2224），≥ 此值一律显示 `↑>999%`。
const int kWeekOverWeekPercentCap = 999;

/// 纯函数：KPI 条的环比文案。基期为 0 → `—`（无基线，不是「涨 ∞%」）；
/// ≥ [kWeekOverWeekPercentCap] → `↑>999%`；其余 `↑12%` / `↓8%`（四舍五入到整数）。
String formatWeekOverWeekDelta(int thisWeek, int lastWeek) {
  final double? pct = computeWeekOverWeekPercent(thisWeek, lastWeek);
  if (pct == null) return '—';
  if (pct >= kWeekOverWeekPercentCap) return '↑>$kWeekOverWeekPercentCap%';
  return '${pct >= 0 ? '↑' : '↓'}${pct.abs().round()}%';
}

/// 纯函数：近期「日均字数」= 窗口内**有阅读的天**的平均字数。
///
/// BUG-892 后续：KPI 条的「日均」旧实现是**终身**均值（总字数 ÷ 历史全部活跃天），近期
/// 读得多、历史含大量低产/零星活跃日时会被拉低，与同屏的「今日 / 本周 / 30 天字符图」
/// （都近期口径）对不上、显得偏低。改用与字符图**同一窗口**（传入 [recentDays] 即
/// `_dailyData`，最近 30 天）、且按**活跃日**（chars>0）取均值——正是字符图里非零柱的
/// 平均高度，直观可对齐。窗口内无活跃日返回 0。
int dailyAverageChars(List<StatDayData> recentDays) {
  int total = 0;
  int activeDays = 0;
  for (final StatDayData d in recentDays) {
    if (d.chars > 0) {
      total += d.chars;
      activeDays++;
    }
  }
  if (activeDays == 0) return 0;
  return (total / activeDays).round();
}

/// 纯函数：目标环填充比例，裁剪到 [0, 1]。[goal] <= 0 时返回 0（避免除零）。
double goalFraction(num value, num goal) {
  if (goal <= 0) return 0;
  final double f = value / goal;
  if (f < 0) return 0;
  if (f > 1) return 1;
  return f;
}

/// 「最快 / 最慢日」条目：日期键 + 当日阅读速度（cph）。
class StatExtremeDay {
  const StatExtremeDay({required this.dateKey, required this.cph});
  final String dateKey;
  final double cph;
}

/// 「速度摘要」聚合结果（参考设计底部卡）。所有字段从每日数据纯函数算出；
/// 无法计算的用 null 表示（UI 层降级为占位符）。
class SpeedSummary {
  const SpeedSummary({
    required this.weightedAvgCph,
    required this.typicalDayCph,
    required this.recentActiveDays,
    required this.recentActiveWindow,
    required this.deltaPercent,
    required this.fastestDay,
    required this.slowestDay,
  });

  /// 加权均速：全窗口 sum(chars) / sum(hours)。无有效时长（窗口总时长不足
  /// 最小样本门槛 [kMinCphSampleMs]）时为 0。
  final double weightedAvgCph;

  /// 典型日：有阅读的各天 cph 的中位数。无有效样本时为 null。
  final double? typicalDayCph;

  /// 近 [recentActiveWindow] 天里有阅读的天数。
  final int recentActiveDays;
  final int recentActiveWindow;

  /// 较前一等长窗口的加权均速变化百分比（+12% 记作 12.0）。
  /// 前窗口均速为 0 或数据不足时为 null。
  final double? deltaPercent;

  /// 有阅读的各天里 cph 最高 / 最低的一天。无样本时为 null。
  final StatExtremeDay? fastestDay;
  final StatExtremeDay? slowestDay;
}

/// 纯函数：从每日数据（升序，含零值日）算出「速度摘要」。
///
/// [daily] 通常是最近 30 天（reading_statistics_page 的 `_dailyData`）。
/// - 加权均速：全窗口 chars/hours。
/// - 典型日：非零 cph 中位数。
/// - 近 7 活跃日：末 [recentWindow] 天里 chars>0 的天数。
/// - 变化%：末 [compareWindow] 天加权均速 vs 其前 [compareWindow] 天加权均速。
/// - 最快 / 最慢日：非零 cph 的极值日。
SpeedSummary computeSpeedSummary(
  List<StatDayData> daily, {
  int recentWindow = 7,
  int compareWindow = 14,
}) {
  int totalChars = 0;
  int totalMs = 0;
  final List<StatExtremeDay> nonZeroDays = <StatExtremeDay>[];
  for (final StatDayData d in daily) {
    totalChars += d.chars;
    totalMs += d.ms;
    // BUG-1107：旧门槛仅 `ms>0 && chars>0`，几秒钟的脏行（幻象字数 + 近零时长）
    // 外推出「1619597 字/时」并霸占「最快日」。[computeCph] 现内建最小样本时长
    // 门槛（kMinCphSampleMs = 1 分钟），不足返回 null → 该日不参与典型日中位数
    // 与最快/最慢日极值。
    final double? dayCph = computeCph(d.chars, d.ms);
    if (dayCph != null && d.chars > 0) {
      nonZeroDays.add(StatExtremeDay(dateKey: d.dateKey, cph: dayCph));
    }
  }
  final double weighted = computeCph(totalChars, totalMs) ?? 0;

  // 典型日：非零 cph 中位数。
  double? typical;
  if (nonZeroDays.isNotEmpty) {
    final List<double> cphs =
        nonZeroDays.map((StatExtremeDay e) => e.cph).toList()..sort();
    final int n = cphs.length;
    typical = n.isOdd ? cphs[n ~/ 2] : (cphs[n ~/ 2 - 1] + cphs[n ~/ 2]) / 2.0;
  }

  // 近 recentWindow 活跃日。
  final int recentStart = math.max(0, daily.length - recentWindow);
  int recentActive = 0;
  for (int i = recentStart; i < daily.length; i++) {
    if (daily[i].chars > 0) recentActive++;
  }

  // 变化%：末 compareWindow 天加权均速 vs 前 compareWindow 天。
  double? delta;
  if (daily.length >= compareWindow * 2) {
    final int len = daily.length;
    final List<StatDayData> recent = daily.sublist(len - compareWindow);
    final List<StatDayData> prev =
        daily.sublist(len - compareWindow * 2, len - compareWindow);
    final double recentCph = _windowWeightedCph(recent);
    final double prevCph = _windowWeightedCph(prev);
    if (prevCph > 0) {
      delta = (recentCph - prevCph) / prevCph * 100.0;
    }
  }

  // 最快 / 最慢日。
  StatExtremeDay? fastest;
  StatExtremeDay? slowest;
  for (final StatExtremeDay e in nonZeroDays) {
    if (fastest == null || e.cph > fastest.cph) fastest = e;
    if (slowest == null || e.cph < slowest.cph) slowest = e;
  }

  return SpeedSummary(
    weightedAvgCph: weighted,
    typicalDayCph: typical,
    recentActiveDays: recentActive,
    recentActiveWindow: recentWindow,
    deltaPercent: delta,
    fastestDay: fastest,
    slowestDay: slowest,
  );
}

/// 一个窗口内的加权均速（sum chars / sum hours）。窗口总时长不足最小样本
/// 门槛时视为 0（无有效速度，调用方 `prevCph > 0` 判据自然跳过环比）。
double _windowWeightedCph(List<StatDayData> window) {
  int chars = 0;
  int ms = 0;
  for (final StatDayData d in window) {
    chars += d.chars;
    ms += d.ms;
  }
  return computeCph(chars, ms) ?? 0;
}
