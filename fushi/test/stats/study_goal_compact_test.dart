import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/platform/widget_snapshot.dart';
import 'package:fushi/src/stats/study_goals.dart';
import 'package:fushi_engine/stats/study_goal_language.dart'
    show StudyGoalUnitChoice;

/// 目标的紧凑外显（系统小组件格子 / 设置行共用）：数值对不重复单位、精度够分辨、
/// 状态 / 剩余量 / 百分比，以及语言 / 度量 / 周期分开的字段。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  StudyGoal goal(
    StudyGoalId metric,
    int target, {
    StudyGoalPeriod period = StudyGoalPeriod.daily,
    String? language,
  }) => StudyGoal(
    id: 'g',
    metric: metric,
    period: period,
    target: target,
    language: language,
  );

  /// 时长目标的 value / target 是毫秒（与 computeStudyGoals 一致）。
  StudyGoalProgress progress(StudyGoal g, int value, {bool restDay = false}) =>
      StudyGoalProgress(
        goal: g,
        value: value,
        target: g.metric.isTime ? g.target * 60000 : g.target,
        restDay: restDay,
      );

  StudyGoalCompactText text(
    StudyGoalProgress p, {
    StudyGoalUnitChoice unit = StudyGoalUnitChoice.auto,
    String languageTag = 'en',
  }) => studyGoalCompactText(p, unitChoice: unit, languageTag: languageTag);

  group('formatStudyGoalCount', () {
    test('below a thousand: all digits; thousands: K, truncated', () {
      expect(formatStudyGoalCount(950, languageTag: 'en'), '950');
      expect(formatStudyGoalCount(4000, languageTag: 'en'), '4K');
      expect(formatStudyGoalCount(14850, languageTag: 'en'), '14.8K');
      expect(formatStudyGoalCount(9960, languageTag: 'en'), '9.9K');
      expect(formatStudyGoalCount(1250000, languageTag: 'en'), '1.2M');
    });

    test('roundUp never shows less than what is left', () {
      expect(
        formatStudyGoalCount(1010, roundUp: true, languageTag: 'en'),
        '1.1K',
      );
      expect(formatStudyGoalCount(50, roundUp: true, languageTag: 'en'), '50');
    });

    test('CJK UI: myriads, digits with grouping below ten thousand', () {
      expect(formatStudyGoalCount(14800, languageTag: 'ja'), '1.4万');
      expect(formatStudyGoalCount(5000, languageTag: 'ja'), '5,000');
      expect(formatStudyGoalCount(28000, languageTag: 'zh-HK'), '2.8萬');
    });
  });

  group('studyGoalCompactPair', () {
    test('no units, value and target only', () {
      final ({String value, String target}) p = studyGoalCompactPair(
        14800,
        10000,
        isTime: false,
        languageTag: 'en',
      );
      expect('${p.value} / ${p.target}', '14.8K / 10K');
      final ({String value, String target}) q = studyGoalCompactPair(
        3600,
        4000,
        isTime: false,
        languageTag: 'en',
      );
      expect('${q.value} / ${q.target}', '3.6K / 4K');
    });

    test('enough precision: 9,950 / 10K never reads "10K / 10K"', () {
      final ({String value, String target}) p = studyGoalCompactPair(
        9950,
        10000,
        isTime: false,
        languageTag: 'en',
      );
      expect(p.value, isNot(p.target));
      expect(p.value, '9.9K');
      final ({String value, String target}) q = studyGoalCompactPair(
        10040,
        10000,
        isTime: false,
        languageTag: 'en',
      );
      expect('${q.value} / ${q.target}', '10.04K / 10K');
      final ({String value, String target}) r = studyGoalCompactPair(
        10000,
        10000,
        isTime: false,
        languageTag: 'en',
      );
      expect('${r.value} / ${r.target}', '10K / 10K');
    });

    test('three decimals still equal: full digits', () {
      final ({String value, String target}) p = studyGoalCompactPair(
        1000000,
        1000001,
        isTime: false,
        languageTag: 'en',
      );
      expect('${p.value} / ${p.target}', '1,000,000 / 1,000,001');
    });

    test('time: "1h 36m / 30m", whole hours without minutes', () {
      final ({String value, String target}) p = studyGoalCompactPair(
        96 * 60000,
        30 * 60000,
        isTime: true,
      );
      expect('${p.value} / ${p.target}', '1h 36m / 30m');
      expect(formatStudyGoalDuration(60 * 60000), '1h');
      expect(formatStudyGoalDuration(59 * 60000 + 59000), '59m');
      expect(formatStudyGoalDuration(30000, roundUp: true), '1m');
    });
  });

  group('state / percent / remaining', () {
    test('not started, in progress, completed, exceeded', () {
      final StudyGoal g = goal(StudyGoalId.chars, 10000);
      expect(progress(g, 0).state, StudyGoalState.notStarted);
      expect(progress(g, 400).state, StudyGoalState.inProgress);
      expect(progress(g, 10000).state, StudyGoalState.completed);
      expect(progress(g, 14800).state, StudyGoalState.exceeded);
      expect(progress(g, 14800).excess, 4800);
      expect(progress(g, 9600).remaining, 400);
    });

    test('percent is floored and capped: 99.8% is not 100%', () {
      final StudyGoal g = goal(StudyGoalId.chars, 1000);
      expect(progress(g, 998).percent, 99);
      expect(progress(g, 1000).percent, 100);
      expect(progress(g, 5000).percent, 100);
      expect(progress(g, 5000).fraction, 1);
    });

    test('rest day only while not done', () {
      final StudyGoal g = goal(StudyGoalId.reading, 60);
      expect(progress(g, 0, restDay: true).state, StudyGoalState.restDay);
      expect(
        progress(g, 60 * 60000, restDay: true).state,
        StudyGoalState.completed,
      );
    });
  });

  group('studyGoalCompactText', () {
    test('exceeded chars goal of a language: separate fields', () {
      final StudyGoalCompactText c = text(
        progress(goal(StudyGoalId.chars, 5000, language: 'ja'), 14800),
      );
      expect(c.language, '日本語');
      expect(c.metric, 'Characters');
      expect(c.period, '');
      expect(c.caption, 'Characters');
      expect(c.valueTarget, '14.8K / 5K');
      expect(c.status, '+9.8K');
      expect(c.remaining, '');
    });

    test('weekly and monthly: short period suffix', () {
      final StudyGoalCompactText w = text(
        progress(
          goal(
            StudyGoalId.chars,
            28000,
            period: StudyGoalPeriod.weekly,
            language: 'zh',
          ),
          27950,
        ),
      );
      expect(w.caption, 'Characters · Week');
      expect(w.valueTarget, '27.9K / 28K');
      expect(w.status, '50 left');
      expect(w.remaining, '50');
      final StudyGoalCompactText m = text(
        progress(
          goal(StudyGoalId.chars, 4000, period: StudyGoalPeriod.monthly),
          3600,
        ),
      );
      expect(m.language, 'All languages');
      expect(m.caption, 'Characters · Month');
      expect(m.valueTarget, '3.6K / 4K');
      expect(m.status, '400 left');
    });

    test('words unit: metric says Words, numbers stay unit-less', () {
      final StudyGoalCompactText c = text(
        progress(goal(StudyGoalId.chars, 2000, language: 'en'), 500),
      );
      expect(c.metric, 'Words');
      expect(c.valueTarget, '500 / 2K');
      expect(c.status, '1.5K left');
    });

    test('time goals: compact durations, remaining rounded up', () {
      final StudyGoalCompactText over = text(
        progress(goal(StudyGoalId.total, 30, language: 'zh'), 96 * 60000),
      );
      expect(over.valueTarget, '1h 36m / 30m');
      expect(over.status, '+1h 6m');
      final StudyGoalCompactText left = text(
        progress(goal(StudyGoalId.reading, 60), 36 * 60000 + 30000),
      );
      expect(left.valueTarget, '36m / 1h');
      expect(left.status, '24m left');
      // 超了不到一分钟：写「已完成」而不是「+0m」。
      final StudyGoalCompactText barely = text(
        progress(goal(StudyGoalId.reading, 60), 60 * 60000 + 20000),
      );
      expect(barely.status, 'Completed');
    });

    test('rest day and language-less metrics', () {
      final StudyGoalCompactText rest = text(
        progress(
          goal(StudyGoalId.reading, 60, language: 'ja'),
          0,
          restDay: true,
        ),
      );
      expect(rest.status, 'Rest day');
      final StudyGoalCompactText mined = text(
        progress(goal(StudyGoalId.mined, 10), 10),
      );
      expect(mined.language, '');
      expect(mined.metric, 'Cards mined');
      expect(mined.valueTarget, '10 / 10');
      expect(mined.status, 'Completed');
    });
  });
}
