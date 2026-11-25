// 设置 › 目标按语言分组（第五轮）：分组规则、组内重排只动本组的位置、
// AppModel.reorderStudyGoals 是唯一的顺序写入口。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/stats/study_goal_groups.dart';
import 'package:fushi/src/stats/study_goal_record.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/test_platform_services.dart';

StudyGoal _goal(
  String id,
  StudyGoalId metric, {
  String? language,
  StudyGoalPeriod period = StudyGoalPeriod.daily,
}) => StudyGoal(
  id: id,
  metric: metric,
  period: period,
  target: 10,
  language: language,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final List<StudyGoal> goals = <StudyGoal>[
    _goal('mined', StudyGoalId.mined),
    _goal('zh-reading', StudyGoalId.reading, language: 'zh'),
    _goal('all-watch', StudyGoalId.watching),
    _goal('ja-reading', StudyGoalId.reading, language: 'ja-JP'),
    _goal('zh-hans-chars', StudyGoalId.chars, language: 'zh-Hans'),
    _goal('reviews', StudyGoalId.reviews),
    _goal('ja-chars', StudyGoalId.chars, language: 'ja'),
    _goal('all-chars', StudyGoalId.chars, period: StudyGoalPeriod.monthly),
  ];

  group('groupStudyGoals', () {
    test('languages by first appearance, then all, then any', () {
      final List<StudyGoalGroup> groups = groupStudyGoals(goals);
      expect(groups.map((StudyGoalGroup g) => g.id), <String>[
        'zh',
        'ja',
        kStudyGoalGroupAll,
        kStudyGoalGroupAny,
      ]);
      expect(groups.map((StudyGoalGroup g) => g.kind), <StudyGoalGroupKind>[
        StudyGoalGroupKind.language,
        StudyGoalGroupKind.language,
        StudyGoalGroupKind.allLanguages,
        StudyGoalGroupKind.anyLanguage,
      ]);
    });

    test('script variants and regional tags join their language', () {
      final List<StudyGoalGroup> groups = groupStudyGoals(goals);
      expect(groups[0].goalIds, <String>['zh-reading', 'zh-hans-chars']);
      expect(groups[1].goalIds, <String>['ja-reading', 'ja-chars']);
      expect(groups[1].language, 'ja');
    });

    test('reviews / mined form their own group, list order kept', () {
      final List<StudyGoalGroup> groups = groupStudyGoals(goals);
      expect(groups[2].goalIds, <String>['all-watch', 'all-chars']);
      expect(groups[3].goalIds, <String>['mined', 'reviews']);
    });

    test('empty groups are left out', () {
      expect(groupStudyGoals(const <StudyGoal>[]), isEmpty);
      expect(
        groupStudyGoals(<StudyGoal>[goals[0]]).map((StudyGoalGroup g) => g.id),
        <String>[kStudyGoalGroupAny],
      );
    });
  });

  group('reorderStudyGoalsInGroup', () {
    final List<String> allIds = <String>[for (final StudyGoal g in goals) g.id];

    test('moves only within the slots of the group', () {
      final List<String> next = reorderStudyGoalsInGroup(
        allIds: allIds,
        groupIds: const <String>['zh-reading', 'zh-hans-chars'],
        from: 1,
        to: 0,
      );
      expect(next, <String>[
        'mined',
        'zh-hans-chars',
        'all-watch',
        'ja-reading',
        'zh-reading',
        'reviews',
        'ja-chars',
        'all-chars',
      ]);
    });

    test('no-op and out of range return the same order', () {
      for (final (int, int) move in <(int, int)>[(0, 0), (0, 5), (-1, 0)]) {
        expect(
          reorderStudyGoalsInGroup(
            allIds: allIds,
            groupIds: const <String>['ja-reading', 'ja-chars'],
            from: move.$1,
            to: move.$2,
          ),
          allIds,
        );
      }
    });
  });

  group('AppModel.reorderStudyGoals', () {
    late FushiDatabase db;
    late AppModel appModel;
    late Directory storeDir;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      final PreferencesRepository prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
      storeDir = Directory.systemTemp.createTempSync('fushi_goal_groups');
      appModel = AppModel(testPlatformServices())
        ..wireDatabaseForTesting(db)
        ..wireLocalAudioForTesting(
          prefsRepo: prefs,
          databaseDirectory: storeDir,
        );
      await appModel.setStudyGoals(goals);
    });

    tearDown(() async {
      await db.close();
      if (storeDir.existsSync()) storeDir.deleteSync(recursive: true);
    });

    List<String> ids() => <String>[
      for (final StudyGoal g in appModel.studyGoals) g.id,
    ];

    test('persists the new order (read back from the repository)', () async {
      final List<String> next = reorderStudyGoalsInGroup(
        allIds: ids(),
        groupIds: const <String>['ja-reading', 'ja-chars'],
        from: 0,
        to: 1,
      );
      await appModel.reorderStudyGoals(next);
      expect(ids(), next);
      // 新开一份仓库从库里读：顺序真的落库了。
      final PreferencesRepository fresh = PreferencesRepository(db);
      await fresh.loadFromDb();
      expect(fresh.studyGoals.map((StudyGoal g) => g.id), next);
    });

    test('unknown ids ignored, missing ids kept at the end', () async {
      await appModel.reorderStudyGoals(const <String>[
        'ghost',
        'all-chars',
        'mined',
        'all-chars',
      ]);
      expect(ids(), <String>[
        'all-chars',
        'mined',
        'zh-reading',
        'all-watch',
        'ja-reading',
        'zh-hans-chars',
        'reviews',
        'ja-chars',
      ]);
      expect(appModel.studyGoals.length, goals.length);
    });
  });
}
