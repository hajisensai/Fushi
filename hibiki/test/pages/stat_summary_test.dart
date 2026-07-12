import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/stat_charts.dart';
import 'package:hibiki/src/pages/implementations/stat_summary.dart';
import 'package:hibiki/src/pages/implementations/stat_trends.dart';

/// 造一个每日数据点（升序序列的一格）。
StatDayData _day(String dateKey, int chars, int ms) {
  final StatDayData d = StatDayData(dateKey: dateKey);
  d.chars = chars;
  d.ms = ms;
  return d;
}

String _key(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

void main() {
  group('goalFraction', () {
    test('partial progress', () {
      expect(goalFraction(500, 1000), closeTo(0.5, 1e-9));
    });
    test('caps at 1', () {
      expect(goalFraction(1500, 1000), 1.0);
    });
    test('goal <= 0 -> 0 (no divide by zero)', () {
      expect(goalFraction(500, 0), 0);
      expect(goalFraction(500, -10), 0);
    });
    test('negative value clamped to 0', () {
      expect(goalFraction(-5, 1000), 0);
    });
  });

  group('computeReadingStreak', () {
    final DateTime now = DateTime(2026, 6, 20, 10);
    String kBack(int daysAgo) =>
        _key(DateTime(2026, 6, 20).subtract(Duration(days: daysAgo)));

    test('empty -> 0', () {
      expect(computeReadingStreak(<String>{}, now), 0);
    });
    test('today + prior days counts consecutively', () {
      final Set<String> keys = <String>{kBack(0), kBack(1), kBack(2)};
      expect(computeReadingStreak(keys, now), 3);
    });
    test('today missing but yesterday present starts from yesterday', () {
      final Set<String> keys = <String>{kBack(1), kBack(2)};
      expect(computeReadingStreak(keys, now), 2);
    });
    test('gap stops the streak', () {
      final Set<String> keys = <String>{kBack(0), kBack(1), kBack(3)};
      expect(computeReadingStreak(keys, now), 2);
    });
    test('neither today nor yesterday -> 0', () {
      final Set<String> keys = <String>{kBack(2), kBack(3)};
      expect(computeReadingStreak(keys, now), 0);
    });
  });

  group('computeWeekOverWeekPercent', () {
    test('up: this week higher than last week', () {
      expect(computeWeekOverWeekPercent(1200, 1000), closeTo(20.0, 1e-9));
    });
    test('down: this week lower than last week', () {
      expect(computeWeekOverWeekPercent(800, 1000), closeTo(-20.0, 1e-9));
    });
    test('flat: equal weeks -> 0%', () {
      expect(computeWeekOverWeekPercent(1000, 1000), 0.0);
    });
    test('no baseline: last week 0 -> null (avoid infinite %)', () {
      expect(computeWeekOverWeekPercent(500, 0), isNull);
      expect(computeWeekOverWeekPercent(0, 0), isNull);
    });
    test('this week 0 with baseline -> -100%', () {
      expect(computeWeekOverWeekPercent(0, 1000), closeTo(-100.0, 1e-9));
    });
  });

  group('trendMetricValue', () {
    final StatTrendPoint p = StatTrendPoint(
        bucketKey: '2026-06-01', label: '06-01', chars: 3600, ms: 3600000);
    test('chars is raw count', () {
      expect(trendMetricValue(p, StatTrendMetric.chars), 3600);
    });
    test('time is minutes', () {
      expect(trendMetricValue(p, StatTrendMetric.time), closeTo(60, 1e-9));
    });
    test('speed is cph (3600 chars / 1h = 3600)', () {
      expect(trendMetricValue(p, StatTrendMetric.speed), closeTo(3600, 1e-6));
    });
  });

  group('trendMetricAxisLabel', () {
    test('time < 60 min shows minutes', () {
      expect(trendMetricAxisLabel(30, StatTrendMetric.time), '30m');
    });
    test('time >= 60 min shows hours', () {
      expect(trendMetricAxisLabel(90, StatTrendMetric.time), '1.5h');
    });
    test('chars uses compact axis', () {
      expect(trendMetricAxisLabel(12000, StatTrendMetric.chars), '1.2万');
    });
  });

  group('computeSpeedSummary', () {
    test('empty daily -> zero weighted, null typical/extremes', () {
      final SpeedSummary s = computeSpeedSummary(<StatDayData>[]);
      expect(s.weightedAvgCph, 0);
      expect(s.typicalDayCph, isNull);
      expect(s.fastestDay, isNull);
      expect(s.slowestDay, isNull);
      expect(s.deltaPercent, isNull);
      expect(s.recentActiveDays, 0);
    });

    test('weighted avg, typical median, fastest/slowest', () {
      // 三个非零日：cph 3600, 1800, 7200。
      final List<StatDayData> daily = <StatDayData>[
        _day('2026-06-01', 3600, 3600000), // 3600 cph
        _day('2026-06-02', 900, 1800000), // 1800 cph
        _day('2026-06-03', 7200, 3600000), // 7200 cph
      ];
      final SpeedSummary s = computeSpeedSummary(daily);
      // weighted = (3600+900+7200) chars / (1+0.5+1) h = 11700 / 2.5 = 4680
      expect(s.weightedAvgCph, closeTo(4680, 1e-6));
      // median of [1800, 3600, 7200] = 3600
      expect(s.typicalDayCph, closeTo(3600, 1e-6));
      expect(s.fastestDay!.dateKey, '2026-06-03');
      expect(s.fastestDay!.cph, closeTo(7200, 1e-6));
      expect(s.slowestDay!.dateKey, '2026-06-02');
      expect(s.slowestDay!.cph, closeTo(1800, 1e-6));
    });

    test('recent active days counts non-zero in last window', () {
      final List<StatDayData> daily = <StatDayData>[
        for (int i = 0; i < 10; i++)
          _day('2026-06-${(i + 1).toString().padLeft(2, '0')}',
              i >= 7 ? 100 : 0, i >= 7 ? 60000 : 0),
      ];
      // last 7 = indices 3..9; non-zero at 7,8,9 -> 3
      final SpeedSummary s = computeSpeedSummary(daily, recentWindow: 7);
      expect(s.recentActiveDays, 3);
    });

    test('delta percent compares last vs prev equal windows', () {
      // 4 天，compareWindow=2：前窗 [d0,d1] 均速，后窗 [d2,d3] 均速。
      final List<StatDayData> daily = <StatDayData>[
        _day('2026-06-01', 1000, 3600000), // 1000 cph
        _day('2026-06-02', 1000, 3600000), // prev window avg 1000
        _day('2026-06-03', 1200, 3600000),
        _day('2026-06-04', 1200, 3600000), // recent window avg 1200
      ];
      final SpeedSummary s = computeSpeedSummary(daily, compareWindow: 2);
      // (1200-1000)/1000*100 = 20%
      expect(s.deltaPercent, closeTo(20, 1e-6));
    });
  });
}
