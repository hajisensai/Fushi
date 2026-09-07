import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/stat_charts.dart';
import 'package:fushi/src/pages/implementations/stat_summary.dart';
import 'package:fushi/src/pages/implementations/stat_trends.dart';
import 'package:fushi_core/fushi_core.dart';

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

    test('「今日」重置时刻 = 4：凌晨 2 点按昨日起算，不把日历今日当断档', () {
      FushiDatabase.statDayResetHour = 4;
      addTearDown(() => FushiDatabase.statDayResetHour = 0);
      // 06-19 / 06-18 有记录、日历 06-20 没有；现在是 06-20 02:00 → 统计日仍是 06-19，
      // streak 从「今日」(06-19) 起连 2 天；旧实现合成午夜会把 06-20 当今日、06-19 当
      // 昨日，同样得 2，但 06-19 / 06-17 这种就分叉——见下一断言。
      final DateTime now = DateTime(2026, 6, 20, 2);
      expect(computeReadingStreak(<String>{kBack(1), kBack(2)}, now), 2);
      // 06-19 有、06-18 没有、06-17 有：统计今日 = 06-19 → streak 1。
      expect(computeReadingStreak(<String>{kBack(1), kBack(3)}, now), 1);
      // 只有 06-17：统计今日 06-19、昨日 06-18 都没有 → 0（日历口径会把 06-19
      // 当昨日、也得 0；但 06-18 单独有时，统计口径是「昨日」→ 1，日历口径 → 0）。
      expect(computeReadingStreak(<String>{kBack(3)}, now), 0);
      expect(computeReadingStreak(<String>{kBack(2)}, now), 1);
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

  group('formatWeekOverWeekDelta（BUG-2224：环比封顶）', () {
    test('普通涨跌带箭头、四舍五入到整数', () {
      expect(formatWeekOverWeekDelta(1200, 1000), '↑20%');
      expect(formatWeekOverWeekDelta(800, 1000), '↓20%');
      expect(formatWeekOverWeekDelta(1000, 1000), '↑0%');
      expect(formatWeekOverWeekDelta(0, 1000), '↓100%');
    });
    test('基期 0 → —（不是 ∞ / 巨数）', () {
      expect(formatWeekOverWeekDelta(500, 0), '—');
      expect(formatWeekOverWeekDelta(0, 0), '—');
    });
    test('≥ 999% 封顶显示 ↑>999%', () {
      expect(formatWeekOverWeekDelta(99999, 1), '↑>999%');
      expect(formatWeekOverWeekDelta(10990, 1000), '↑>999%', reason: '恰 999%');
      expect(formatWeekOverWeekDelta(10980, 1000), '↑998%', reason: '998% 不封');
      expect(kWeekOverWeekPercentCap, 999);
    });
  });

  group('dailyAverageChars（活跃日均值，对齐字符图窗口）', () {
    test('只对有阅读的天取均值，零阅读日不摊薄', () {
      // 30 天窗口里 3 天有阅读（6000/4000/2000），其余 27 天为 0。
      final List<StatDayData> days = <StatDayData>[
        for (int i = 0; i < 27; i++) _day('d$i', 0, 0),
        _day('a', 6000, 0),
        _day('b', 4000, 0),
        _day('c', 2000, 0),
      ];
      // 活跃日均值 = 12000 / 3 = 4000（而非终身/日历口径的 12000/30=400，那才是「偏低」）。
      expect(dailyAverageChars(days), 4000);
    });

    test('无活跃日返回 0（不除零）', () {
      expect(dailyAverageChars(<StatDayData>[_day('x', 0, 0)]), 0);
      expect(dailyAverageChars(const <StatDayData>[]), 0);
    });

    test('四舍五入', () {
      final List<StatDayData> days = <StatDayData>[
        _day('a', 100, 0),
        _day('b', 101, 0),
      ];
      expect(dailyAverageChars(days), 101); // 201/2 = 100.5 → 101
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

    // BUG-1107：几秒钟的脏行（幻象字数 + 近零时长）不得进入极值/典型日样本。
    // 用户实况：「最快日 1619597 字/时 · 07-25」= 1.1 万字 ÷ 几十秒外推。
    test('sub-minute dirty day is excluded from fastest/typical (BUG-1107)',
        () {
      final List<StatDayData> daily = <StatDayData>[
        _day('2026-07-23', 3600, 3600000), // 3600 cph，正常日
        _day('2026-07-24', 1800, 1800000), // 3600 cph，正常日
        _day('2026-07-25', 11000, 25000), // 脏行：25 秒 → 旧口径 158 万 cph
      ];
      final SpeedSummary s = computeSpeedSummary(daily);
      // 脏日不进极值：最快日是正常日之一，而不是 07-25。
      expect(s.fastestDay!.dateKey, isNot('2026-07-25'));
      expect(s.fastestDay!.cph, lessThan(10000));
      // 脏日不进典型日中位数样本（只剩两个 3600 cph 样本）。
      expect(s.typicalDayCph, closeTo(3600, 1e-6));
    });

    test('a day with >= 1 minute still qualifies for extremes', () {
      final List<StatDayData> daily = <StatDayData>[
        _day('2026-07-20', 100, 60000), // 恰好 1 分钟 → 6000 cph，合法样本
        _day('2026-07-21', 3600, 3600000), // 3600 cph
      ];
      final SpeedSummary s = computeSpeedSummary(daily);
      expect(s.fastestDay!.dateKey, '2026-07-20');
      expect(s.slowestDay!.dateKey, '2026-07-21');
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
