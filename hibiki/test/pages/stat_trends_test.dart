import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/stat_charts.dart';
import 'package:hibiki/src/pages/implementations/stat_trends.dart';

StatDayData _day(String dateKey, int chars, int ms) =>
    StatDayData(dateKey: dateKey)
      ..chars = chars
      ..ms = ms;

void main() {
  group('computeCph', () {
    test('chars per hour from chars + ms', () {
      // 3600 字 / 1 小时 = 3600 cph。
      expect(computeCph(3600, 3600000), closeTo(3600, 0.001));
      // 1800 字 / 0.5 小时 = 3600 cph。
      expect(computeCph(1800, 1800000), closeTo(3600, 0.001));
    });

    test('zero ms yields 0 (no div-by-zero)', () {
      expect(computeCph(500, 0), 0);
      expect(computeCph(0, 0), 0);
    });

    test('zero chars yields 0', () {
      expect(computeCph(0, 3600000), 0);
    });
  });

  group('isoWeekKey', () {
    test('mid-year date maps to ISO week', () {
      // 2026-06-15 是周一，属第 25 周。
      expect(isoWeekKey('2026-06-15'), '2026-W25');
      // 同周周日 2026-06-21 仍是第 25 周。
      expect(isoWeekKey('2026-06-21'), '2026-W25');
    });

    test('early January may belong to previous ISO year', () {
      // 2021-01-01 是周五，属 2020 年第 53 周（ISO）。
      expect(isoWeekKey('2021-01-01'), '2020-W53');
    });

    test('first ISO week of a year', () {
      // 2026-01-01 是周四 -> 2026 第 1 周。
      expect(isoWeekKey('2026-01-01'), '2026-W01');
    });

    test('malformed key returns input unchanged', () {
      expect(isoWeekKey('garbage'), 'garbage');
    });
  });

  group('monthKey', () {
    test('extracts YYYY-MM', () {
      expect(monthKey('2026-06-07'), '2026-06');
      expect(monthKey('2026-12-31'), '2026-12');
    });

    test('malformed key returns input unchanged', () {
      expect(monthKey('2026'), '2026');
    });
  });

  group('aggregateTrend', () {
    final List<StatDayData> daily = <StatDayData>[
      _day('2026-06-15', 100, 3600000), // W25
      _day('2026-06-16', 200, 3600000), // W25
      _day('2026-06-22', 300, 3600000), // W26
    ];

    test('daily granularity keeps every day', () {
      final List<StatTrendPoint> pts =
          aggregateTrend(daily, StatTrendGranularity.daily);
      expect(pts.length, 3);
      expect(pts[0].chars, 100);
      expect(pts[0].label, '06-15');
      expect(pts[2].bucketKey, '2026-06-22');
    });

    test('weekly granularity buckets by ISO week, sorted ascending', () {
      final List<StatTrendPoint> pts =
          aggregateTrend(daily, StatTrendGranularity.weekly);
      expect(pts.length, 2);
      expect(pts[0].bucketKey, '2026-W25');
      expect(pts[0].chars, 300); // 100 + 200
      expect(pts[0].ms, 7200000);
      expect(pts[0].label, 'W25');
      expect(pts[1].bucketKey, '2026-W26');
      expect(pts[1].chars, 300);
    });

    test('monthly granularity buckets by month', () {
      final List<StatDayData> twoMonths = <StatDayData>[
        _day('2026-05-31', 10, 0),
        _day('2026-06-01', 20, 0),
        _day('2026-06-15', 30, 0),
      ];
      final List<StatTrendPoint> pts =
          aggregateTrend(twoMonths, StatTrendGranularity.monthly);
      expect(pts.length, 2);
      expect(pts[0].bucketKey, '2026-05');
      expect(pts[0].chars, 10);
      expect(pts[0].label, '05');
      expect(pts[1].bucketKey, '2026-06');
      expect(pts[1].chars, 50);
    });

    test('cph getter on trend point uses aggregated chars/ms', () {
      final List<StatTrendPoint> pts =
          aggregateTrend(daily, StatTrendGranularity.weekly);
      // W25: 300 字 / 2 小时 = 150 cph。
      expect(pts[0].cph, closeTo(150, 0.001));
    });

    test('empty input yields empty', () {
      expect(aggregateTrend(<StatDayData>[], StatTrendGranularity.weekly),
          isEmpty);
    });
  });

  group('movingAverage', () {
    test('trailing average with full and partial windows', () {
      final List<double> out = movingAverage(<double>[1, 2, 3, 4], 2);
      // [1, (1+2)/2, (2+3)/2, (3+4)/2]
      expect(out, <double>[1.0, 1.5, 2.5, 3.5]);
    });

    test('window covers all earlier points when smaller than window', () {
      final List<double> out = movingAverage(<double>[2, 4, 6], 3);
      // [2, (2+4)/2, (2+4+6)/3]
      expect(out[0], 2.0);
      expect(out[1], 3.0);
      expect(out[2], 4.0);
    });

    test('window <= 1 returns a copy', () {
      final List<double> input = <double>[1, 2, 3];
      final List<double> out = movingAverage(input, 1);
      expect(out, input);
      expect(identical(out, input), isFalse);
    });

    test('empty input yields empty', () {
      expect(movingAverage(<double>[], 3), isEmpty);
    });
  });

  group('detectAnomalies', () {
    test('flags a clear outlier beyond mu + 2 sigma', () {
      // 一堆相近值 + 一个极端高值。
      final List<double> v = <double>[100, 102, 98, 101, 99, 1000];
      final List<bool> flags = detectAnomalies(v);
      expect(flags.last, isTrue);
      // 正常值不被标记。
      expect(flags.sublist(0, 5).any((bool b) => b), isFalse);
    });

    test('no anomalies when all values are similar', () {
      final List<bool> flags =
          detectAnomalies(<double>[100, 101, 99, 100, 102]);
      expect(flags.every((bool b) => !b), isTrue);
    });

    test('too few non-zero samples -> no flags', () {
      // 只有 2 个非零样本，不足 3 -> 全 false。
      expect(detectAnomalies(<double>[0, 5, 0, 9000]).every((bool b) => !b),
          isTrue);
    });

    test('zero values never flagged as anomalies', () {
      final List<double> v = <double>[100, 102, 98, 0, 101];
      final List<bool> flags = detectAnomalies(v);
      expect(flags[3], isFalse);
    });

    test('all-zero yields all false without crashing', () {
      expect(
          detectAnomalies(<double>[0, 0, 0, 0]).every((bool b) => !b), isTrue);
    });
  });

  group('bookProgressFraction', () {
    test('fills proportionally by the active sort metric', () {
      // 排序维度可为字数/时长/速度；纯函数只看传入的 metric 与 topMetric。
      expect(bookProgressFraction(50, 100), closeTo(0.5, 1e-9));
      expect(bookProgressFraction(100, 100), closeTo(1.0, 1e-9));
      expect(bookProgressFraction(0, 100), 0);
    });

    test('time metric (ms) and speed metric (cph) use same ratio rule', () {
      // 时长维度：30 分钟 / 60 分钟。
      expect(bookProgressFraction(1800000, 3600000), closeTo(0.5, 1e-9));
      // 速度维度：150 cph / 300 cph。
      expect(bookProgressFraction(150, 300), closeTo(0.5, 1e-9));
    });

    test('zero topMetric yields 0 (no div-by-zero when sort metric is 0)', () {
      // 例如按速度排序但第一名也无有效时长 -> topMetric 0。
      expect(bookProgressFraction(0, 0), 0);
      expect(bookProgressFraction(5, 0), 0);
    });

    test('clamps to [0, 1]', () {
      expect(bookProgressFraction(150, 100), 1);
      expect(bookProgressFraction(-10, 100), 0);
    });
  });
}
