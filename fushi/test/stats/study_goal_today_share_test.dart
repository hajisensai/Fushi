import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/platform/widget_snapshot.dart';
import 'package:fushi/src/stats/stat_window.dart';
import 'package:fushi/src/stats/study_goal_period.dart';
import 'package:fushi/src/stats/study_goals.dart';
import 'package:fushi_engine/stats/study_goal_language.dart'
    show StudyGoalUnitChoice;

/// 周 / 月目标的「今日份额」（`computeStudyGoals` 里一次算好，首页 / 设置 / 小组件
/// 共用）：份额 = ceil(max(0, 目标 − 今天之前已做) / 今天起剩下的生效日)；进度差 =
/// 周期已做 − 按生效日线性摊到今天结束时的应做量；本周逐日柱条的数据。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => LocaleSettings.setLocale(AppLocale.en));
  tearDown(() => StatWindow.weekStartDay = DateTime.monday);

  StudyGoal goal(
    int target, {
    StudyGoalPeriod period = StudyGoalPeriod.weekly,
    StudyGoalId metric = StudyGoalId.chars,
    Set<int> days = const <int>{},
  }) => StudyGoal(
    id: 'g',
    metric: metric,
    period: period,
    target: target,
    activeWeekdays: days,
  );

  StudyGoalProgress run(
    StudyGoal g,
    String day, {
    Map<String, int> chars = const <String, int>{},
    Map<String, Map<WidgetImmersionCategory, int>> ms =
        const <String, Map<WidgetImmersionCategory, int>>{},
  }) => computeStudyGoals(
    goals: WidgetGoalsInput(goals: <StudyGoal>[g]),
    immersion: WidgetImmersionInput(charsByDay: chars, msByDay: ms),
    day: day,
    reviewsByDay: null,
  ).single;

  StudyGoalCompactText text(StudyGoalProgress p) => studyGoalCompactText(
    p,
    unitChoice: StudyGoalUnitChoice.auto,
    languageTag: 'en',
  );

  // 2026-11-16 周一 … 2026-11-22 周日。
  const String wed = '2026-11-18';

  group('window helpers', () {
    test('week end follows the week start; month end; DST day', () {
      expect(studyGoalWindowEnd(StudyGoalPeriod.weekly, wed), '2026-11-22');
      StatWindow.weekStartDay = DateTime.sunday;
      expect(studyGoalWindowStart(StudyGoalPeriod.weekly, wed), '2026-11-15');
      expect(studyGoalWindowEnd(StudyGoalPeriod.weekly, wed), '2026-11-21');
      StatWindow.weekStartDay = DateTime.saturday;
      expect(studyGoalWindowStart(StudyGoalPeriod.weekly, wed), '2026-11-14');
      expect(studyGoalWindowEnd(StudyGoalPeriod.weekly, wed), '2026-11-20');
      expect(studyGoalWindowEnd(StudyGoalPeriod.monthly, wed), '2026-11-30');
      expect(
        studyGoalWindowEnd(StudyGoalPeriod.monthly, '2028-02-03'),
        '2028-02-29',
      );
      // 2026-11-01（周日）美国夏令时结束：窗口仍是 7 个不同的日历日。
      StatWindow.weekStartDay = DateTime.sunday;
      expect(
        studyGoalWindowDays(StudyGoalPeriod.weekly, '2026-11-01'),
        <String>[
          '2026-11-01',
          '2026-11-02',
          '2026-11-03',
          '2026-11-04',
          '2026-11-05',
          '2026-11-06',
          '2026-11-07',
        ],
      );
    });
  });

  group('today share', () {
    test('catch-up after a missed day raises the share', () {
      // 周一漏掉，周二 10，周三（今天）5：剩 90 摊给周三起 5 天 = 18。
      final StudyGoalProgress p = run(
        goal(100),
        wed,
        chars: const <String, int>{'2026-11-17': 10, wed: 5},
      );
      expect(p.value, 15);
      expect(p.todayValue, 5);
      expect(p.todayShare, 18);
      expect(p.periodDaysLeft, 5);
      expect(p.todayState, StudyGoalState.inProgress);
      // 应做 100 × 3 / 7 = 42 → 落后 27。
      expect(p.pace, 15 - 42);
      expect(p.paceStatus, StudyGoalPace.behind);
      // 没漏的话份额更低：周一周二各做 15 → 剩 70 / 5 = 14。
      final StudyGoalProgress steady = run(
        goal(100),
        wed,
        chars: const <String, int>{'2026-11-16': 15, '2026-11-17': 15, wed: 14},
      );
      expect(steady.todayShare, 14);
      // 做完今天的份额：44 对应做 42，差距在 5% 内。
      expect(steady.paceStatus, StudyGoalPace.onTrack);
    });

    test('day strip: past shares as they were, today, projected future', () {
      final StudyGoalProgress p = run(
        goal(100),
        wed,
        chars: const <String, int>{'2026-11-17': 10, wed: 5},
      );
      expect(p.days.map((StudyGoalDay d) => d.dayKey).first, '2026-11-16');
      expect(p.days.map((StudyGoalDay d) => d.value).toList(), <int>[
        0,
        10,
        5,
        0,
        0,
        0,
        0,
      ]);
      // 周一 ceil(100/7)=15，周二 ceil(100/6)=17，周三 18；之后按今天结束时
      // 剩 85 摊给 4 天 = 22。
      expect(p.days.map((StudyGoalDay d) => d.share).toList(), <int>[
        15,
        17,
        18,
        22,
        22,
        22,
        22,
      ]);
      expect(p.days.where((StudyGoalDay d) => d.isToday).single.dayKey, wed);
      expect(p.days.where((StudyGoalDay d) => d.future).length, 4);
      expect(p.days.every((StudyGoalDay d) => d.active && d.inPeriod), isTrue);
    });

    test('week start Sunday / Saturday moves the window', () {
      StatWindow.weekStartDay = DateTime.sunday;
      // 周日 11-15 起；周三是第 4 天，剩 4 天（周三…周六）。
      final StudyGoalProgress sun = run(
        goal(100),
        wed,
        chars: const <String, int>{'2026-11-15': 20, '2026-11-14': 999},
      );
      expect(sun.value, 20);
      expect(sun.todayShare, 20);
      expect(sun.periodDaysLeft, 4);
      expect(sun.days.first.dayKey, '2026-11-15');
      StatWindow.weekStartDay = DateTime.saturday;
      final StudyGoalProgress sat = run(
        goal(100),
        wed,
        chars: const <String, int>{'2026-11-15': 20, '2026-11-14': 10},
      );
      // 周六 11-14 起：周三之前 30，剩 70 摊给周三…周五 3 天 = 24。
      expect(sat.value, 30);
      expect(sat.todayShare, 24);
      expect(sat.periodDaysLeft, 3);
    });

    test('rest day: share 0, not counted in days left', () {
      // 只在工作日生效；2026-11-21 周六。
      final StudyGoalProgress p = run(
        goal(100, days: const <int>{1, 2, 3, 4, 5}),
        '2026-11-21',
        chars: const <String, int>{'2026-11-16': 30, '2026-11-21': 4},
      );
      expect(p.todayRest, isTrue);
      expect(p.restDay, isFalse, reason: 'the week itself is not resting');
      expect(p.todayShare, 0);
      expect(p.todayValue, 4);
      expect(p.periodDaysLeft, 0);
      expect(p.todayState, StudyGoalState.restDay);
      expect(p.state, StudyGoalState.inProgress);
      expect(p.days.where((StudyGoalDay d) => !d.active).length, 2);
      // 生效日全过完了：应做 = 目标。
      expect(p.pace, 34 - 100);
      final StudyGoalCompactText t = text(p);
      expect(t.todayLine, 'Rest day · 66 behind');
      expect(t.periodLine, 'Week 34 / 100');
    });

    test('active weekdays split the target across those days only', () {
      // 周一三五生效，今天周三，周一做了 10：剩 90 摊给周三、周五 = 45。
      final StudyGoalProgress p = run(
        goal(100, days: const <int>{1, 3, 5}),
        wed,
        chars: const <String, int>{'2026-11-16': 10},
      );
      expect(p.todayShare, 45);
      expect(p.periodDaysLeft, 2);
      // 应做 100 × 2 / 3 = 66。
      expect(p.pace, 10 - 66);
      expect(p.days.map((StudyGoalDay d) => d.active).toList(), <bool>[
        true,
        false,
        true,
        false,
        true,
        false,
        false,
      ]);
    });

    test('over target: share 0, week done, ahead', () {
      final StudyGoalProgress p = run(
        goal(100),
        wed,
        chars: const <String, int>{'2026-11-16': 120, wed: 3},
      );
      expect(p.periodReached, isTrue);
      expect(p.todayShare, 0);
      expect(p.todayState, StudyGoalState.completed);
      expect(p.todayFraction, 1);
      expect(p.paceStatus, StudyGoalPace.ahead);
      expect(text(p).todayLine, 'Week done');
      expect(text(p).periodLine, 'Week 123 / 100');
    });

    test('today beyond its share: exceeded today, lower future shares', () {
      final StudyGoalProgress p = run(
        goal(70),
        wed,
        chars: const <String, int>{'2026-11-16': 10, '2026-11-17': 10, wed: 30},
      );
      // 剩 50 / 5 = 10；今天做了 30。
      expect(p.todayShare, 10);
      expect(p.todayState, StudyGoalState.exceeded);
      // 今天结束剩 20，摊给 4 天 = 5。
      expect(p.days.last.share, 5);
      expect(p.paceStatus, StudyGoalPace.ahead);
      expect(text(p).todayLine, '30 / 10 today · Ahead by 20');
      expect(text(p).periodLine, 'Week 50 / 70 · 5 days left');
    });

    test(
      'month end: last day takes the rest; strip days outside the month',
      () {
        final StudyGoalProgress p = run(
          goal(300, period: StudyGoalPeriod.monthly),
          '2026-11-30',
          chars: const <String, int>{'2026-11-01': 290, '2026-10-31': 500},
        );
        expect(p.value, 290);
        expect(p.todayShare, 10);
        expect(p.periodDaysLeft, 1);
        expect(text(p).periodLine, 'Month 290 / 300 · 1 day left');
        // 本周 = 11-30（周一）… 12-06：12 月的日子不在周期里。
        expect(p.days.first.dayKey, '2026-11-30');
        expect(p.days.where((StudyGoalDay d) => d.inPeriod).length, 1);
        expect(p.days.skip(1).every((StudyGoalDay d) => !d.active), isTrue);
      },
    );

    test('monthly mid-month: rolling share over the remaining days', () {
      // 11-18：之前 17 天做了 170；剩 830 摊给 18…30 共 13 天 = 64（向上取整）。
      final Map<String, int> chars = <String, int>{
        for (int d = 1; d <= 17; d++)
          '2026-11-${d.toString().padLeft(2, '0')}': 10,
      };
      final StudyGoalProgress p = run(
        goal(1000, period: StudyGoalPeriod.monthly),
        wed,
        chars: chars,
      );
      expect(p.todayShare, 64);
      expect(p.periodDaysLeft, 13);
      // 应做 1000 × 18 / 30 = 600。
      expect(p.pace, 170 - 600);
    });

    test('time goals round the share up to whole minutes', () {
      const int minute = 60000;
      final StudyGoalProgress p = run(
        goal(100, metric: StudyGoalId.total),
        '2026-11-16',
      );
      // ceil(100 / 7) = 15 分钟。
      expect(p.todayShare, 15 * minute);
      final StudyGoalProgress mid = run(
        goal(70, metric: StudyGoalId.total),
        wed,
        ms: <String, Map<WidgetImmersionCategory, int>>{
          '2026-11-16': <WidgetImmersionCategory, int>{
            WidgetImmersionCategory.reading: 20 * minute,
          },
          wed: <WidgetImmersionCategory, int>{
            WidgetImmersionCategory.reading: 4 * minute,
          },
        },
      );
      expect(mid.todayValue, 4 * minute);
      expect(mid.todayShare, 10 * minute);
      expect(text(mid).todayLine, startsWith('4m / 10m today'));
    });

    test('daily goals keep a single ring: share = target, no strip', () {
      final StudyGoalProgress p = run(
        goal(50, period: StudyGoalPeriod.daily),
        wed,
        chars: const <String, int>{wed: 20},
      );
      expect(p.splitsPeriod, isFalse);
      expect(p.todayValue, 20);
      expect(p.todayShare, 50);
      expect(p.days, isEmpty);
      expect(p.todayState, p.state);
      expect(text(p).todayLine, isEmpty);
    });
  });

  test('snapshot emits today / share / pace per goal', () {
    final Map<String, Object?> snap = buildWidgetSnapshot(
      day: wed,
      generatedAt: 1,
      labels: WidgetSnapshotLabels(const <String, String>{}),
      modules: const WidgetModulesInput(),
      media: const <WidgetMediaInput>[],
      srs: const WidgetSrsInput(),
      vocab: const <WidgetVocabInput>[],
      immersion: const WidgetImmersionInput(
        charsByDay: <String, int>{'2026-11-17': 10, wed: 5},
      ),
      goals: WidgetGoalsInput(
        goals: <StudyGoal>[goal(100)],
        compactOf: (StudyGoalProgress g) => text(g),
      ),
      formatTime: (int ms) => '${ms ~/ 60000}m',
      formatChars: (int n) => '$n',
      formatCount: (int n) => '$n',
      formatAge: (int ms) => '',
      weekdayLabel: (String k) => k,
      formatTimeLeft: (int ms) => '',
      categoryLabels: const <WidgetImmersionCategory, String>{},
    );
    final List<Object?> goals =
        jsonDecode(jsonEncode(snap['goals'])) as List<Object?>;
    final Map<String, Object?> g = goals.single! as Map<String, Object?>;
    expect(g['splits'], true);
    expect(g['todayValue'], '5');
    expect(g['todayShare'], '18');
    expect(g['todayState'], 'inProgress');
    expect(g['pace'], 'behind');
    expect(g['paceText'], '27 behind');
    expect(g['daysLeft'], 5);
    expect(g['todayLine'], '5 / 18 today · 27 behind');
    expect(g['todayShort'], '5 / 18 today');
    expect(g['periodLine'], 'Week 15 / 100 · 5 days left');
    // 旧字段照旧。
    expect(g['compact'], '15 / 100');
  });
}
