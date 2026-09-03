import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/download/subscription_check_schedule.dart';

/// 周三 15:00 UTC，作为「每周更新点」的基准。
final DateTime kBase = DateTime.utc(2026, 9, 2, 15);

int _ms(DateTime at) => at.millisecondsSinceEpoch;

List<int> _weeklySamples(int count, {Duration jitter = Duration.zero}) {
  return <int>[
    for (int i = 0; i < count; i++)
      _ms(kBase.subtract(Duration(days: 7 * i) - jitter * i)),
  ];
}

const SubscriptionCheckCadence kCadence = SubscriptionCheckCadence();

void main() {
  group('inferWeeklyReleasePhase', () {
    test('样本不足时不推断相位', () {
      expect(inferWeeklyReleasePhase(_weeklySamples(2)), isNull);
    });

    test('每周同一时刻的样本给出零离散度相位', () {
      final WeeklyReleasePhase? phase =
          inferWeeklyReleasePhase(_weeklySamples(3));
      expect(phase, isNotNull);
      expect(phase!.spread, Duration.zero);
      expect(phase.phaseMs, subscriptionWeekPhase(_ms(kBase)));
    });

    test('相位过于离散时拒绝推断', () {
      final List<int> scattered = <int>[
        _ms(kBase),
        _ms(kBase.subtract(const Duration(days: 7)).add(
              const Duration(hours: 8),
            )),
        _ms(kBase.subtract(const Duration(days: 14))),
      ];
      expect(inferWeeklyReleasePhase(scattered), isNull);
    });

    test('小抖动仍收敛到中位相位', () {
      final List<int> samples = <int>[
        _ms(kBase),
        _ms(kBase.subtract(const Duration(days: 7, minutes: -20))),
        _ms(kBase.subtract(const Duration(days: 14, minutes: 10))),
      ];
      final WeeklyReleasePhase? phase = inferWeeklyReleasePhase(samples);
      expect(phase, isNotNull);
      expect(phase!.spread, lessThanOrEqualTo(const Duration(minutes: 30)));
    });

    test('只取最近 maxSamples 条，陈旧的旧档期不再拖住相位', () {
      // 最近 5 条在新档期（周三 15:00），更早 3 条在旧档期（偏移 10 小时）。
      final List<int> samples = <int>[
        ..._weeklySamples(5),
        for (int i = 5; i < 8; i++)
          _ms(kBase.subtract(Duration(days: 7 * i, hours: -10))),
      ];
      final WeeklyReleasePhase? phase = inferWeeklyReleasePhase(samples);
      expect(phase, isNotNull);
      expect(phase!.spread, Duration.zero);
      expect(phase.phaseMs, subscriptionWeekPhase(_ms(kBase)));
    });

    test('乱序输入与降序输入等价', () {
      final List<int> ordered = _weeklySamples(4);
      final List<int> shuffled = <int>[
        ordered[2],
        ordered[0],
        ordered[3],
        ordered[1],
      ];
      expect(
        inferWeeklyReleasePhase(shuffled)!.phaseMs,
        inferWeeklyReleasePhase(ordered)!.phaseMs,
      );
    });
  });

  group('nextSubscriptionCheckDelay', () {
    Duration delayAt(DateTime now, {List<int>? samples, bool weekly = true}) {
      return nextSubscriptionCheckDelay(
        recentPublishedAtMs: samples ?? _weeklySamples(3),
        nowMs: _ms(now),
        weekly: weekly,
      );
    }

    test('样本不足退回均匀间隔', () {
      expect(
        delayAt(kBase, samples: _weeklySamples(2)),
        kCadence.baseInterval,
      );
    });

    test('非周期模式退回均匀间隔', () {
      expect(delayAt(kBase, weekly: false), kCadence.baseInterval);
    });

    test('相位离散退回均匀间隔', () {
      final List<int> scattered = <int>[
        _ms(kBase),
        _ms(kBase.subtract(const Duration(days: 7)).add(
              const Duration(hours: 8),
            )),
        _ms(kBase.subtract(const Duration(days: 14))),
      ];
      expect(delayAt(kBase, samples: scattered), kCadence.baseInterval);
    });

    test('预测点刚过（滞后余温）走热窗间隔', () {
      expect(
        delayAt(kBase.add(const Duration(minutes: 10))),
        kCadence.hotInterval,
      );
      expect(
        delayAt(kBase.add(const Duration(hours: 3, minutes: 59))),
        kCadence.hotInterval,
      );
    });

    test('预测点前的提前量内走热窗间隔', () {
      expect(
        delayAt(kBase.add(const Duration(days: 7, minutes: -20))),
        kCadence.hotInterval,
      );
    });

    test('热窗尾巴外即转冷窗', () {
      expect(
        delayAt(kBase.add(const Duration(hours: 4, minutes: 1))),
        kCadence.coldInterval,
      );
    });

    test('冷窗深处睡满冷窗封顶', () {
      expect(
        delayAt(kBase.add(const Duration(days: 3))),
        kCadence.coldInterval,
      );
    });

    test('临近热窗时只睡到热窗起点，不越过', () {
      // 距离下一个预测点 1 小时；热窗提前量 30 分钟 ⇒ 应只睡 30 分钟。
      expect(
        delayAt(kBase.add(const Duration(days: 7, hours: -1))),
        const Duration(minutes: 30),
      );
    });

    test('跨周边界的相位不会错算', () {
      // 让发布点贴近周相位原点（epoch 相位 0 = 周四 00:00 UTC）。
      final DateTime edge = DateTime.utc(2026, 9, 3, 0, 10);
      final List<int> samples = <int>[
        for (int i = 0; i < 3; i++) _ms(edge.subtract(Duration(days: 7 * i))),
      ];
      // 相位原点之前 20 分钟，仍应落在下一个预测点的提前量里。
      expect(
        delayAt(edge.subtract(const Duration(minutes: 20)), samples: samples),
        kCadence.hotInterval,
      );
    });

    test('任何输入下的睡眠都落在 [minInterval, coldInterval] 内', () {
      final List<int> samples = _weeklySamples(4);
      for (int minutes = 0; minutes < 7 * 24 * 60; minutes += 7) {
        final Duration delay = delayAt(
          kBase.add(Duration(minutes: minutes)),
          samples: samples,
        );
        expect(delay, greaterThanOrEqualTo(kCadence.minInterval));
        expect(delay, lessThanOrEqualTo(kCadence.coldInterval));
      }
    });

    test('冷窗里的睡眠永不越过热窗起点', () {
      final List<int> samples = _weeklySamples(4);
      final WeeklyReleasePhase phase = inferWeeklyReleasePhase(samples)!;
      for (int minutes = 0; minutes < 7 * 24 * 60; minutes++) {
        final DateTime now = kBase.add(Duration(minutes: minutes));
        if (isInsideReleaseHotWindow(phase, _ms(now))) continue;
        final int hotStart = nextSubscriptionPhasePoint(phase, _ms(now)) -
            kCadence.hotLead.inMilliseconds;
        final Duration delay = delayAt(now, samples: samples);
        expect(
          _ms(now) + delay.inMilliseconds,
          lessThanOrEqualTo(hotStart),
          reason: '冷窗第 $minutes 分钟睡过了热窗起点',
        );
      }
    });
  });

  group('isInsideReleaseHotWindow', () {
    test('一整周里热窗只覆盖预测点附近的一小段', () {
      final WeeklyReleasePhase phase =
          inferWeeklyReleasePhase(_weeklySamples(4))!;
      int hotMinutes = 0;
      for (int minutes = 0; minutes < 7 * 24 * 60; minutes++) {
        if (isInsideReleaseHotWindow(
          phase,
          _ms(kBase.add(Duration(minutes: minutes))),
        )) {
          hotMinutes++;
        }
      }
      // 提前 30 分钟 + 滞后 4 小时 = 270 分钟（含两端各一个采样点）。
      expect(hotMinutes, 271);
    });

    test('热窗两端边界与外侧一分钟', () {
      final WeeklyReleasePhase phase =
          inferWeeklyReleasePhase(_weeklySamples(4))!;
      bool hotAt(Duration offset) =>
          isInsideReleaseHotWindow(phase, _ms(kBase.add(offset)));

      expect(hotAt(const Duration(hours: 4)), isTrue);
      expect(hotAt(const Duration(hours: 4, minutes: 1)), isFalse);
      expect(hotAt(const Duration(days: 7, minutes: -30)), isTrue);
      expect(hotAt(const Duration(days: 7, minutes: -31)), isFalse);
    });
  });
}
