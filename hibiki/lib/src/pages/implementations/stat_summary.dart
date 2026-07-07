import 'dart:math' as math;

import 'package:hibiki/src/pages/implementations/stat_activity.dart';
import 'package:hibiki/src/pages/implementations/stat_charts.dart';
import 'package:hibiki/src/pages/implementations/stat_trends.dart';

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
  final DateTime today = DateTime(now.year, now.month, now.day);
  final String todayKey = statDateKey(today);
  final String yesterdayKey =
      statDateKey(today.subtract(const Duration(days: 1)));
  // 起点：今天有记录从今天算；否则昨天有记录从昨天算；都没有则 streak=0。
  DateTime cursor;
  if (activeDayKeys.contains(todayKey)) {
    cursor = today;
  } else if (activeDayKeys.contains(yesterdayKey)) {
    cursor = today.subtract(const Duration(days: 1));
  } else {
    return 0;
  }
  int streak = 0;
  while (activeDayKeys.contains(statDateKey(cursor))) {
    streak++;
    cursor = cursor.subtract(const Duration(days: 1));
  }
  return streak;
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

  /// 加权均速：全窗口 sum(chars) / sum(hours)。无有效时长时为 0。
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
    if (d.ms > 0 && d.chars > 0) {
      nonZeroDays.add(
        StatExtremeDay(dateKey: d.dateKey, cph: computeCph(d.chars, d.ms)),
      );
    }
  }
  final double weighted = computeCph(totalChars, totalMs);

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

/// 一个窗口内的加权均速（sum chars / sum hours）。
double _windowWeightedCph(List<StatDayData> window) {
  int chars = 0;
  int ms = 0;
  for (final StatDayData d in window) {
    chars += d.chars;
    ms += d.ms;
  }
  return computeCph(chars, ms);
}
