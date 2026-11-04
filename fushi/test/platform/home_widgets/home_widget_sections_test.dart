import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/platform/home_widgets/home_widget_live_activities.dart';
import 'package:fushi/src/platform/home_widgets/home_widget_sections.dart';

void main() {
  const int minute = 60 * 1000;
  const int hour = 60 * minute;
  // 2026-11-04 10:00 UTC；SRS 日边界放在 UTC 04:00（可配重置时刻，不是零点）。
  final int now = DateTime.utc(2026, 11, 4, 10).millisecondsSinceEpoch;
  int dayIndexOf(int ms) => DateTime.fromMillisecondsSinceEpoch(
    ms,
    isUtc: true,
  ).subtract(const Duration(hours: 4)).difference(DateTime.utc(2026)).inDays;
  final int boundary = DateTime.utc(2026, 11, 5, 4).millisecondsSinceEpoch;

  group('buildSrsDueTimeline', () {
    test(
      'first entry is now; learning steps ripen; day boundary adds reviews',
      () {
        final List<SrsDueStep> steps = buildSrsDueTimeline(
          nowMs: now,
          dueNow: 10,
          learningDueAts: <int>[
            now + 5 * minute + 3000,
            now + 2 * hour,
            now - 1,
          ],
          dayIndexOf: dayIndexOf,
          reviewsDueNextDay: 30,
        );
        expect(steps.first, (at: now, due: 10));
        expect(steps[1], (at: now + 6 * minute, due: 11)); // 合并到下一整分钟
        expect(steps[2], (at: now + 2 * hour, due: 12));
        expect(steps[3], (at: boundary, due: 42));
        expect(steps, hasLength(4));
      },
    );

    test('no change → only the now entry', () {
      final List<SrsDueStep> steps = buildSrsDueTimeline(
        nowMs: now,
        dueNow: 0,
        learningDueAts: const <int>[],
        dayIndexOf: dayIndexOf,
        reviewsDueNextDay: 0,
      );
      expect(steps, <SrsDueStep>[(at: now, due: 0)]);
    });

    test('many steps collapse to hours and stay under maxSteps', () {
      final List<SrsDueStep> steps = buildSrsDueTimeline(
        nowMs: now,
        dueNow: 0,
        learningDueAts: <int>[
          for (int i = 1; i <= 300; i++) now + i * 4 * minute,
        ],
        dayIndexOf: dayIndexOf,
        reviewsDueNextDay: 5,
        maxSteps: 40,
      );
      expect(steps.length, lessThanOrEqualTo(41));
      for (final SrsDueStep s in steps.skip(1)) {
        expect(s.at % hour, 0, reason: 'collapsed to whole hours');
      }
      for (int i = 1; i < steps.length; i++) {
        expect(steps[i].due, greaterThan(steps[i - 1].due));
      }
    });
  });

  test('estimateSrsMinutes uses measured pace, clamped', () {
    expect(estimateSrsMinutes(0), 0);
    expect(estimateSrsMinutes(48), 8); // 默认 10 s / 张
    expect(estimateSrsMinutes(48, averageMsPerCard: 6000), 5);
    expect(estimateSrsMinutes(1, averageMsPerCard: 1), 1);
  });

  group('buildStudyNumbers', () {
    List<String> keys() => <String>[
      for (int i = 111; i >= 0; i--)
        DateTime.utc(
          2026,
          11,
          4,
        ).subtract(Duration(days: i)).toIso8601String().substring(0, 10),
    ];

    test('today not studied → dashed today, streak breaks tomorrow', () {
      final List<String> k = keys();
      final Map<String, int> ms = <String, int>{
        k[110]: 40 * minute,
        k[109]: 10 * minute,
      };
      final HomeWidgetStudyNumbers n = buildStudyNumbers(
        last112Keys: k,
        amountOf: (String d) => (dateKey: d, ms: ms[d] ?? 0, chars: 0),
        streakOf: (Set<String> active) => active.length,
        activeDayKeys: ms.keys.toSet(),
        inWeek: (String d) => k.indexOf(d) >= 105,
        weekCards: 3,
      );
      expect(n.studiedToday, isFalse);
      expect(n.last7.last, -1);
      expect(n.last7[5], 1.0);
      expect(n.last7[4], 0.25);
      expect(n.heat.last, -1);
      expect(n.heat[110], 3);
      expect(n.heat[109], 1);
      expect(n.weekMs, 50 * minute);
      expect(n.streakTomorrow, 0);
      expect(n.last7Tomorrow.last, -1);
      expect(n.last7Tomorrow[4], 1.0);
    });

    test('today studied keeps the streak across midnight', () {
      final List<String> k = keys();
      final HomeWidgetStudyNumbers n = buildStudyNumbers(
        last112Keys: k,
        amountOf: (String d) =>
            (dateKey: d, ms: d == k.last ? 90 * minute : 0, chars: 1200),
        streakOf: (Set<String> active) => 17,
        activeDayKeys: <String>{k.last},
        inWeek: (_) => true,
        weekCards: 0,
      );
      expect(n.heat.last, 4);
      expect(n.last7.last, 1.0);
      expect(n.streakTomorrow, 17);
      expect(n.last7Tomorrow[5], 1.0);
    });
  });

  test('dailyRotationIndex is stable within a day', () {
    final int a = dailyRotationIndex(dateKey: '2026-11-04', count: 37);
    expect(dailyRotationIndex(dateKey: '2026-11-04', count: 37), a);
    expect(a, inInclusiveRange(0, 36));
    expect(dailyRotationIndex(dateKey: '2026-11-04', count: 0), -1);
  });

  test('stripCardFieldHtml keeps ruby base text only', () {
    expect(
      stripCardFieldHtml(
        '<ruby>猫<rp>(</rp><rt>ねこ</rt><rp>)</rp></ruby>が<b>好き</b><br>です',
      ),
      '猫が好き です',
    );
  });

  test('playbackWallClock maps media time to wall clock at speed', () {
    final DateTime t = DateTime.fromMillisecondsSinceEpoch(1000000 * 1000);
    final ({double startedAt, double endsAt})? c = playbackWallClock(
      position: const Duration(seconds: 30),
      duration: const Duration(seconds: 90),
      speed: 1.5,
      now: t,
    );
    expect(c!.startedAt, 1000000 - 20);
    expect(c.endsAt, 1000000 - 20 + 60);
    expect(
      playbackWallClock(
        position: Duration.zero,
        duration: Duration.zero,
        speed: 1,
        now: t,
      ),
      isNull,
    );
  });
}
