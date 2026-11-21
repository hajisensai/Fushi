import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/stats/study_goal_record.dart';

/// 学习目标记录（设计 A）：JSON 往返、容错解析、旧偏好迁移、规范化与排序。
void main() {
  StudyGoal goal(
    String id,
    StudyGoalId metric, {
    StudyGoalPeriod period = StudyGoalPeriod.daily,
    int target = 10,
    String? language,
    Set<int> days = const <int>{},
  }) => StudyGoal(
    id: id,
    metric: metric,
    period: period,
    target: target,
    language: language,
    activeWeekdays: days,
  );

  group('normalisation', () {
    test('reviews / mined never carry a language; blank = all languages', () {
      expect(goal('a', StudyGoalId.reviews, language: 'ja').language, isNull);
      expect(goal('a', StudyGoalId.mined, language: 'ja').language, isNull);
      expect(goal('a', StudyGoalId.chars, language: '  ').language, isNull);
      expect(goal('a', StudyGoalId.chars, language: ' ko ').language, 'ko');
    });

    test('target clamps to >= 1 and the metric maximum', () {
      expect(goal('a', StudyGoalId.chars, target: 0).target, 1);
      expect(
        goal('a', StudyGoalId.total, target: 1 << 30).target,
        kStudyGoalMaxMinutes,
      );
      expect(
        goal('a', StudyGoalId.chars, target: 1 << 30).target,
        kStudyGoalMaxCount,
      );
    });

    test('active days: every period; all seven = every day', () {
      expect(
        goal(
          'a',
          StudyGoalId.chars,
          days: const <int>{1, 2, 3, 4, 5, 6, 7},
        ).activeWeekdays,
        isEmpty,
      );
      expect(
        goal(
          'a',
          StudyGoalId.chars,
          period: StudyGoalPeriod.weekly,
          days: const <int>{1},
        ).activeWeekdays,
        <int>{1},
      );
      final StudyGoal weekdays = goal(
        'a',
        StudyGoalId.chars,
        days: const <int>{1, 2, 3, 4, 5},
      );
      // 2026-10-23 周五、2026-10-24 周六。
      expect(weekdays.isRestDay('2026-10-23'), isFalse);
      expect(weekdays.isRestDay('2026-10-24'), isTrue);
      expect(goal('b', StudyGoalId.chars).isRestDay('2026-10-24'), isFalse);
    });
  });

  group('JSON', () {
    test('round-trips every field', () {
      final List<StudyGoal> goals = <StudyGoal>[
        goal(
          'a',
          StudyGoalId.chars,
          target: 5000,
          language: 'ja',
          days: const <int>{1, 3},
        ),
        goal(
          'b',
          StudyGoalId.total,
          period: StudyGoalPeriod.monthly,
          target: 600,
        ),
        goal(
          'c',
          StudyGoalId.reviews,
          period: StudyGoalPeriod.weekly,
          target: 700,
        ),
      ];
      expect(decodeStudyGoals(encodeStudyGoals(goals)), goals);
    });

    test('missing / broken JSON → null (use the migration)', () {
      expect(decodeStudyGoals(''), isNull);
      expect(decodeStudyGoals('not json'), isNull);
      expect(decodeStudyGoals('{"a":1}'), isNull);
    });

    test('an empty list stays empty (the user deleted everything)', () {
      expect(decodeStudyGoals('[]'), isEmpty);
    });

    test('tolerant: skips bad entries and duplicate ids', () {
      final List<StudyGoal>? goals = decodeStudyGoals(
        '[{"id":"a","metric":"chars","period":"daily","target":100},'
        '"junk",'
        '{"id":"b","metric":"nope","period":"daily","target":1},'
        '{"id":"a","metric":"total","period":"daily","target":5},'
        '{"id":"c","metric":"mined","period":"yearly","target":3}]',
      );
      expect(goals!.map((StudyGoal g) => g.id), <String>['a', 'c']);
      expect(goals[0].metric, StudyGoalId.chars);
      expect(goals[1].period, StudyGoalPeriod.daily);
    });
  });

  group('legacy migration', () {
    test('one daily record per set goal, stable legacy ids', () {
      final List<StudyGoal> goals = migrateLegacyStudyGoals(
        totalMinutes: 30,
        reviews: 100,
        dailyChars: 3000,
        weeklyChars: 20000,
        language: 'ja',
      );
      expect(goals.map((StudyGoal g) => g.id), <String>[
        'legacy-total',
        'legacy-reviews',
        'legacy-chars',
      ]);
      expect(goals[0].language, 'ja');
      expect(goals[1].language, isNull, reason: 'reviews are never scoped');
      expect(goals[2].period, StudyGoalPeriod.daily);
      expect(goals[2].target, 3000);
    });

    test('weekly chars period migrates the weekly value', () {
      final StudyGoal chars = migrateLegacyStudyGoals(
        dailyChars: 3000,
        weeklyChars: 20000,
        charsPeriod: StudyGoalPeriod.weekly,
      ).single;
      expect(chars.period, StudyGoalPeriod.weekly);
      expect(chars.target, 20000);
      expect(chars.language, isNull);
    });

    test('nothing set → no records', () {
      expect(migrateLegacyStudyGoals(), isEmpty);
    });
  });

  test('script-tagged languages: old records → combined, marked ones stay', () {
    // 没有 scriptExact 标记 = 只按主语言匹配时期写的：意思是整门中文。
    final List<StudyGoal> old = decodeStudyGoals(
      '[{"id":"a","metric":"chars","period":"daily","target":10,"language":"zh-Hans"},'
      '{"id":"b","metric":"chars","period":"daily","target":10,"language":"zh-TW"},'
      '{"id":"c","metric":"chars","period":"daily","target":10,"language":"ja-JP"}]',
    )!;
    expect(old.map((StudyGoal g) => g.language), <String>['zh', 'zh', 'ja-JP']);
    // 新写的只算简体：带标记存，读回不变；整门中文不带标记。
    final StudyGoal hans = goal('h', StudyGoalId.chars, language: 'zh-Hans');
    expect(hans.toJson()['scriptExact'], isTrue);
    expect(
      goal('z', StudyGoalId.chars, language: 'zh').toJson(),
      isNot(contains('scriptExact')),
    );
    final List<StudyGoal> back = decodeStudyGoals(
      encodeStudyGoals(<StudyGoal>[hans]),
    )!;
    expect(back.single.language, 'zh-Hans');
    // 幂等：再存再读还是同样。
    expect(
      decodeStudyGoals(encodeStudyGoals(old))!.map((StudyGoal g) => g.language),
      <String>['zh', 'zh', 'ja-JP'],
    );
    // 旧逐项偏好迁移出的记录也是整门语言。
    expect(
      migrateLegacyStudyGoals(
        totalMinutes: 30,
        language: 'zh-Hant',
      ).single.language,
      'zh',
    );
  });

  test('sortStudyGoalsByPeriod: daily → weekly → monthly, stable', () {
    final List<StudyGoal> sorted = sortStudyGoalsByPeriod(<StudyGoal>[
      goal('m', StudyGoalId.chars, period: StudyGoalPeriod.monthly),
      goal('d1', StudyGoalId.chars),
      goal('w', StudyGoalId.chars, period: StudyGoalPeriod.weekly),
      goal('d2', StudyGoalId.total),
    ]);
    expect(sorted.map((StudyGoal g) => g.id), <String>['d1', 'd2', 'w', 'm']);
  });

  test('StudyGoalSwipeScope wire falls back to daily', () {
    expect(StudyGoalSwipeScope.fromWire('all'), StudyGoalSwipeScope.all);
    expect(StudyGoalSwipeScope.fromWire(null), StudyGoalSwipeScope.daily);
    expect(StudyGoalSwipeScope.fromWire('x'), StudyGoalSwipeScope.daily);
  });
}
