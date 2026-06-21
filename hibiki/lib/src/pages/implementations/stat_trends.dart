import 'dart:math' as math;

import 'package:hibiki/src/pages/implementations/stat_charts.dart';

/// 趋势聚合的粒度：日 / 周 / 月。阅读统计与视频统计共用。
enum StatTrendGranularity { daily, weekly, monthly }

/// 一个趋势数据点（按某粒度聚合后）：标签 + 字数 + 时长 + 阅读速度（cph）。
/// [label] 是该桶在横轴上的简短标签（日=MM-DD，周=ISO 周号，月=YYYY-MM）。
/// [bucketKey] 是排序用的可字典序比较键（保证桶按时间升序）。
class StatTrendPoint {
  StatTrendPoint({
    required this.bucketKey,
    required this.label,
    required this.chars,
    required this.ms,
  });

  final String bucketKey;
  final String label;
  final int chars;
  final int ms;

  /// 该桶的阅读速度：字/小时（characters per hour）。时长为 0 时返回 0。
  double get cph => computeCph(chars, ms);
}

/// 纯函数：阅读速度（字/小时）。[ms] 为 0（无有效时长）时返回 0，避免除零。
/// 汇总卡、按书、趋势点都经此一处计算，口径统一。
double computeCph(int chars, int ms) {
  if (ms <= 0) return 0;
  return chars / (ms / 3600000.0);
}

/// 纯函数：把 `2026-06-07` 形式的 dateKey 解析成 (year, month, day)。
/// 非法格式返回 null。统计行 dateKey 由 statDateKey 生成，恒为零填充合法格式，
/// 但解析仍做防御。
({int year, int month, int day})? parseStatDateKey(String dateKey) {
  final List<String> parts = dateKey.split('-');
  if (parts.length != 3) return null;
  final int? y = int.tryParse(parts[0]);
  final int? m = int.tryParse(parts[1]);
  final int? d = int.tryParse(parts[2]);
  if (y == null || m == null || d == null) return null;
  if (m < 1 || m > 12 || d < 1 || d > 31) return null;
  return (year: y, month: m, day: d);
}

/// 纯函数：dateKey -> ISO 8601 周键 `YYYY-Www`（如 `2026-W25`）。
/// ISO 周：周一为一周首日，第 1 周是含当年第一个周四的那一周；故 1 月初的几天
/// 可能归属上一年的最后一周，年份用「ISO 周年」而非日历年。可字典序排序。
String isoWeekKey(String dateKey) {
  final parsed = parseStatDateKey(dateKey);
  if (parsed == null) return dateKey;
  final DateTime date = DateTime(parsed.year, parsed.month, parsed.day);
  // ISO weekday：周一=1 ... 周日=7。
  final int weekday = date.weekday;
  // 把日期挪到本周的周四（ISO 周年由周四所在年份决定）。
  final DateTime thursday = date.add(Duration(days: 4 - weekday));
  final int isoYear = thursday.year;
  // 该 ISO 周年第一个周四所在的 ISO 第 1 周。
  final DateTime jan1 = DateTime(isoYear, 1, 1);
  final DateTime firstThursday =
      jan1.add(Duration(days: (4 - jan1.weekday + 7) % 7));
  final int week = 1 + (thursday.difference(firstThursday).inDays ~/ 7);
  return '$isoYear-W${week.toString().padLeft(2, '0')}';
}

/// 纯函数：dateKey -> 月键 `YYYY-MM`（如 `2026-06`）。可字典序排序。
String monthKey(String dateKey) {
  final parsed = parseStatDateKey(dateKey);
  if (parsed == null) return dateKey;
  return '${parsed.year}-${parsed.month.toString().padLeft(2, '0')}';
}

/// 纯函数：把每日数据聚合到趋势点列表，按 [granularity] 决定桶大小。
/// [daily] 是按日期升序的 StatDayData（reading_statistics_page 的 _dailyData /
/// video 的 agg.daily 都已是升序 30 天）。空桶（chars==0 && ms==0）也保留以呈现
/// 完整时间轴。结果按 bucketKey 升序。
List<StatTrendPoint> aggregateTrend(
  List<StatDayData> daily,
  StatTrendGranularity granularity,
) {
  if (granularity == StatTrendGranularity.daily) {
    return daily
        .map((StatDayData d) => StatTrendPoint(
              bucketKey: d.dateKey,
              label:
                  d.dateKey.length >= 10 ? d.dateKey.substring(5) : d.dateKey,
              chars: d.chars,
              ms: d.ms,
            ))
        .toList();
  }

  final Map<String, StatTrendPoint> buckets = <String, StatTrendPoint>{};
  final List<String> order = <String>[];
  for (final StatDayData d in daily) {
    final String key = granularity == StatTrendGranularity.weekly
        ? isoWeekKey(d.dateKey)
        : monthKey(d.dateKey);
    final StatTrendPoint? existing = buckets[key];
    if (existing == null) {
      order.add(key);
      buckets[key] = StatTrendPoint(
        bucketKey: key,
        label: _trendLabel(key, granularity),
        chars: d.chars,
        ms: d.ms,
      );
    } else {
      buckets[key] = StatTrendPoint(
        bucketKey: key,
        label: existing.label,
        chars: existing.chars + d.chars,
        ms: existing.ms + d.ms,
      );
    }
  }
  order.sort();
  return order.map((String k) => buckets[k]!).toList();
}

/// 周/月桶的横轴短标签。周键 `2026-W25` 取 `W25`；月键 `2026-06` 取 `06`。
String _trendLabel(String bucketKey, StatTrendGranularity granularity) {
  if (granularity == StatTrendGranularity.weekly) {
    final int idx = bucketKey.indexOf('W');
    return idx >= 0 ? bucketKey.substring(idx) : bucketKey;
  }
  final int dash = bucketKey.indexOf('-');
  return dash >= 0 ? bucketKey.substring(dash + 1) : bucketKey;
}

/// 纯函数：简单移动平均（trailing，窗口 [window]）。
/// 第 i 个输出 = values[max(0,i-window+1)..i] 的均值（前期窗口不足时用已有数据）。
/// [window] <= 1 时原样返回拷贝。空输入返回空。
List<double> movingAverage(List<double> values, int window) {
  if (values.isEmpty) return <double>[];
  if (window <= 1) return List<double>.of(values);
  final List<double> out = List<double>.filled(values.length, 0);
  for (int i = 0; i < values.length; i++) {
    final int start = math.max(0, i - window + 1);
    double sum = 0;
    for (int j = start; j <= i; j++) {
      sum += values[j];
    }
    out[i] = sum / (i - start + 1);
  }
  return out;
}

/// 纯函数：异常日检测。对非零样本求均值 mu 与总体标准差 sigma，标记偏离
/// 超过 mu ± [sigmaMultiple]*sigma 的点为异常（true）。
/// 全零或有效样本 < 3 或 sigma==0 时不标记任何点（返回全 false），
/// 避免在数据稀疏时误报。
List<bool> detectAnomalies(List<double> values, {double sigmaMultiple = 2.0}) {
  final List<bool> flags = List<bool>.filled(values.length, false);
  final List<double> nonZero =
      values.where((double v) => v > 0).toList(growable: false);
  if (nonZero.length < 3) return flags;
  final double mu =
      nonZero.reduce((double a, double b) => a + b) / nonZero.length;
  double variance = 0;
  for (final double v in nonZero) {
    variance += (v - mu) * (v - mu);
  }
  variance /= nonZero.length;
  final double sigma = math.sqrt(variance);
  if (sigma == 0) return flags;
  final double hi = mu + sigmaMultiple * sigma;
  final double lo = mu - sigmaMultiple * sigma;
  for (int i = 0; i < values.length; i++) {
    final double v = values[i];
    if (v <= 0) continue; // 零值（无阅读）不算异常。
    if (v > hi || v < lo) flags[i] = true;
  }
  return flags;
}
