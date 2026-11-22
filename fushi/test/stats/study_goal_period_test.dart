import 'package:test/test.dart';
import 'package:fushi/src/stats/stat_window.dart';
import 'package:fushi/src/stats/study_goal_period.dart';
import 'package:fushi/src/stats/study_goal_record.dart';
import 'package:fushi/src/stats/study_goals.dart'
    show studyGoalStatsCharsFactsFrom;

/// 目标周期的窗口：每日 = 当天；每周 = 本自然周（周一起，与 [StatWindow.inWeek] /
/// [StatWindow.weekStartOf] 同一个「本周」）；每月 = 本日历月 1 日起。
void main() {
  group('StudyGoalPeriod wire', () {
    test('round-trips every value', () {
      for (final StudyGoalPeriod p in StudyGoalPeriod.values) {
        expect(StudyGoalPeriod.fromWire(p.wire), p);
      }
    });

    test('missing / unknown wire falls back to daily', () {
      expect(StudyGoalPeriod.fromWire(null), StudyGoalPeriod.daily);
      expect(StudyGoalPeriod.fromWire(''), StudyGoalPeriod.daily);
      expect(StudyGoalPeriod.fromWire('yearly'), StudyGoalPeriod.daily);
    });
  });

  group('studyGoalWindowStart / Contains', () {
    test('daily = the day itself', () {
      expect(
        studyGoalWindowStart(StudyGoalPeriod.daily, '2026-08-29'),
        '2026-08-29',
      );
      expect(
        studyGoalWindowContains(
          StudyGoalPeriod.daily,
          '2026-08-29',
          '2026-08-28',
        ),
        isFalse,
      );
    });

    test('weekly = Monday..day (2026-08-29 is a Saturday)', () {
      expect(
        studyGoalWindowStart(StudyGoalPeriod.weekly, '2026-08-29'),
        '2026-08-24',
      );
      expect(
        studyGoalWindowStart(StudyGoalPeriod.weekly, '2026-08-24'),
        '2026-08-24',
      );
      // 周日仍属上周一开始的那周。
      expect(
        studyGoalWindowStart(StudyGoalPeriod.weekly, '2026-08-30'),
        '2026-08-24',
      );
      expect(
        studyGoalWindowStart(StudyGoalPeriod.weekly, '2026-08-29'),
        StatWindow.weekStartOf('2026-08-29'),
      );
      for (final (String key, bool inside) in <(String, bool)>[
        ('2026-08-23', false),
        ('2026-08-24', true),
        ('2026-08-29', true),
        ('2026-08-30', false), // 未来日期不算
      ]) {
        expect(
          studyGoalWindowContains(StudyGoalPeriod.weekly, '2026-08-29', key),
          inside,
          reason: key,
        );
      }
    });

    test('weekly window crosses a month boundary', () {
      // 2026-09-02 是周三 → 本周一 = 2026-08-31。
      expect(
        studyGoalWindowStart(StudyGoalPeriod.weekly, '2026-09-02'),
        '2026-08-31',
      );
    });

    test('monthly = 1st of the calendar month..day', () {
      expect(
        studyGoalWindowStart(StudyGoalPeriod.monthly, '2026-08-29'),
        '2026-08-01',
      );
      expect(
        studyGoalWindowStart(StudyGoalPeriod.monthly, '2026-09-01'),
        '2026-09-01',
      );
      expect(
        studyGoalWindowContains(
          StudyGoalPeriod.monthly,
          '2026-09-01',
          '2026-08-31',
        ),
        isFalse,
      );
      expect(
        studyGoalWindowContains(
          StudyGoalPeriod.monthly,
          '2026-12-31',
          '2026-12-01',
        ),
        isTrue,
      );
    });
  });

  group('week start (StatWindow.weekStartDay)', () {
    tearDown(() => StatWindow.weekStartDay = DateTime.monday);

    // 2026-08-29 是周六，2026-08-30 是周日。
    test('Sunday start: the week of a Saturday begins the Sunday before', () {
      StatWindow.weekStartDay = DateTime.sunday;
      expect(StatWindow.weekStartOf('2026-08-29'), '2026-08-23');
      expect(StatWindow.weekStartOf('2026-08-30'), '2026-08-30');
      expect(
        studyGoalWindowStart(StudyGoalPeriod.weekly, '2026-08-29'),
        '2026-08-23',
      );
    });

    test('Saturday start: a Saturday starts its own week', () {
      StatWindow.weekStartDay = DateTime.saturday;
      expect(StatWindow.weekStartOf('2026-08-29'), '2026-08-29');
      expect(StatWindow.weekStartOf('2026-08-28'), '2026-08-22');
      expect(
        studyGoalWindowContains(
          StudyGoalPeriod.weekly,
          '2026-08-30',
          '2026-08-28',
        ),
        isFalse,
      );
    });

    test('StatWindow.weekFromKey follows the week start', () {
      StatWindow.weekStartDay = DateTime.sunday;
      final StatWindow w = StatWindow(DateTime(2026, 8, 29, 12));
      expect(w.weekFromKey, '2026-08-23');
      expect(w.prevWeekFromKey, '2026-08-16');
      expect(w.inWeek('2026-08-23'), isTrue);
      expect(w.inWeek('2026-08-22'), isFalse);
    });
  });

  test('HBK-AUDIT-219：统计页字数环读日面的起点 = 那条目标自己周期窗口的起点', () {
    StudyGoal chars(StudyGoalPeriod period) => StudyGoal(
      id: period.wire,
      metric: StudyGoalId.chars,
      period: period,
      target: 1000,
    );
    // 2026-08-29 是周六：周窗口从 08-24（周一）起，月窗口从 08-01 起。
    expect(studyGoalStatsCharsFactsFrom(null, '2026-08-29'), '2026-08-29');
    expect(
      studyGoalStatsCharsFactsFrom(chars(StudyGoalPeriod.daily), '2026-08-29'),
      '2026-08-29',
    );
    expect(
      studyGoalStatsCharsFactsFrom(chars(StudyGoalPeriod.weekly), '2026-08-29'),
      studyGoalWindowStart(StudyGoalPeriod.weekly, '2026-08-29'),
    );
    expect(
      studyGoalStatsCharsFactsFrom(
        chars(StudyGoalPeriod.monthly),
        '2026-08-29',
      ),
      '2026-08-01',
    );
  });
}
