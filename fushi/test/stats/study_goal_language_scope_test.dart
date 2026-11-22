// 目标编辑面板（设计 A）：新建 / 编辑 / 删除走 AppModel 的记录表；复习 / 制卡
// 不分语言（不显示语言块）；预设随度量、周期、语言与单位换。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/study_goal_edit_sheet.dart';
import 'package:fushi/src/stats/stat_window.dart';
import 'package:fushi/src/stats/study_goal_host.dart';
import 'package:fushi/src/stats/study_goal_record.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive.dart'
    show FushiConnectedButtonGroup;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/stats/stat_facts.dart' show StatFact;
import 'package:fushi_engine/stats/study_goal_language.dart'
    show StudyGoalUnitChoice;
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/test_platform_services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late PreferencesRepository prefs;
  late AppModel appModel;
  late Directory storeDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocaleSettings.setLocale(AppLocale.en);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('fushi_goal_sheet');
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    // 从空记录表开始（不走旧偏好迁移）。
    await appModel.setStudyGoals(const <StudyGoal>[]);
  });

  tearDown(() async {
    await db.close();
    if (storeDir.existsSync()) storeDir.deleteSync(recursive: true);
  });

  Future<StudyGoalSheetData> fakeData(StudyGoalHost _) async =>
      StudyGoalSheetData(
        candidateLanguages: const <String>['ja', 'ko', 'en'],
        daily: const <StatFact>[],
        mediaLanguages: const <String, String>{},
        window: StatWindow(DateTime(2026, 10, 23)),
      );

  StudyGoalSheetResult? lastResult;

  Future<void> open(
    WidgetTester tester, {
    StudyGoal? goal,
    StudyGoalId metric = StudyGoalId.chars,
    String? language,
  }) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    lastResult = null;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () async {
                  lastResult = await showStudyGoalEditSheet(
                    context,
                    appModel,
                    goal: goal,
                    metric: metric,
                    language: language,
                    loadData: fakeData,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Finder byKey(String key) => find.byKey(ValueKey<String>(key));

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.ensureVisible(byKey(key));
    await tester.pumpAndSettle();
    await tester.tap(byKey(key));
    await tester.pumpAndSettle();
  }

  List<int?> presetValues(WidgetTester tester) => tester
      .widget<FushiConnectedButtonGroup<int>>(byKey('study-goal-presets'))
      .segments
      .map((ButtonSegment<int> s) => s.value)
      .toList();

  Finder targetField() => find.descendant(
    of: byKey('study-goal-target-field'),
    matching: find.byType(EditableText),
  );

  String targetText(WidgetTester tester) =>
      tester.widget<EditableText>(targetField()).controller.text;

  testWidgets('create: metric, period, language, target → new record', (
    WidgetTester tester,
  ) async {
    await open(tester);
    expect(byKey('study-goal-delete'), findsNothing);
    await tapKey(tester, 'study-goal-language-ja');
    await tapKey(tester, 'study-goal-period-monthly');
    await tester.enterText(targetField(), '250000');
    await tester.pumpAndSettle();
    await tapKey(tester, 'study-goal-save');

    expect(lastResult, StudyGoalSheetResult.saved);
    final StudyGoal saved = appModel.studyGoals.single;
    expect(saved.metric, StudyGoalId.chars);
    expect(saved.period, StudyGoalPeriod.monthly);
    expect(saved.language, 'ja');
    expect(saved.target, 250000);
    expect(saved.id, isNotEmpty);
  });

  testWidgets('edit keeps the id and replaces the record in place', (
    WidgetTester tester,
  ) async {
    final StudyGoal a = StudyGoal(
      id: 'a',
      metric: StudyGoalId.total,
      period: StudyGoalPeriod.daily,
      target: 30,
    );
    final StudyGoal b = StudyGoal(
      id: 'b',
      metric: StudyGoalId.chars,
      period: StudyGoalPeriod.daily,
      target: 5000,
      language: 'ja',
    );
    await appModel.setStudyGoals(<StudyGoal>[a, b]);
    await open(tester, goal: b);
    expect(targetText(tester), '5000');
    await tapKey(tester, 'study-goal-period-weekly');
    // 5000 是每日预设第二档 → 换周期后跟到每周预设第二档。
    expect(targetText(tester), '35000');
    await tapKey(tester, 'study-goal-save');

    expect(lastResult, StudyGoalSheetResult.saved);
    expect(appModel.studyGoals.map((StudyGoal g) => g.id), <String>['a', 'b']);
    final StudyGoal edited = appModel.studyGoals[1];
    expect(edited.period, StudyGoalPeriod.weekly);
    expect(edited.target, 35000);
    expect(edited.language, 'ja');
  });

  testWidgets('delete removes only that record', (WidgetTester tester) async {
    final StudyGoal a = StudyGoal(
      id: 'a',
      metric: StudyGoalId.mined,
      period: StudyGoalPeriod.daily,
      target: 10,
    );
    final StudyGoal b = StudyGoal(
      id: 'b',
      metric: StudyGoalId.reviews,
      period: StudyGoalPeriod.daily,
      target: 100,
    );
    await appModel.setStudyGoals(<StudyGoal>[a, b]);
    await open(tester, goal: a);
    await tapKey(tester, 'study-goal-delete');
    expect(lastResult, StudyGoalSheetResult.deleted);
    expect(appModel.studyGoals.map((StudyGoal g) => g.id), <String>['b']);
  });

  testWidgets('reviews / mined hide the language block', (
    WidgetTester tester,
  ) async {
    await open(tester, language: 'ja');
    expect(byKey('study-goal-language'), findsOneWidget);
    await tapKey(tester, 'study-goal-metric-reviews');
    expect(byKey('study-goal-language'), findsNothing);
    expect(presetValues(tester), <int>[50, 100, 150, 200]);
    await tapKey(tester, 'study-goal-metric-mined');
    expect(byKey('study-goal-language'), findsNothing);
    await tapKey(tester, 'study-goal-save');
    final StudyGoal saved = appModel.studyGoals.single;
    expect(saved.metric, StudyGoalId.mined);
    expect(saved.language, isNull, reason: 'mined goals are never scoped');
  });

  testWidgets('presets follow language and unit', (WidgetTester tester) async {
    await open(tester);
    expect(presetValues(tester), <int>[3000, 5000, 10000, 20000]);
    await tapKey(tester, 'study-goal-language-ko');
    expect(presetValues(tester), <int>[2000, 4000, 8000, 15000]);
    await tapKey(tester, 'study-goal-language-en');
    expect(presetValues(tester), <int>[1500, 3000, 6000, 12000]);
    expect(find.textContaining(t.stat_goal_unit_words), findsWidgets);
    await tapKey(tester, 'study-goal-period-monthly');
    expect(presetValues(tester), <int>[45000, 90000, 180000, 360000]);
  });

  testWidgets('a fixed unit overrides the language default', (
    WidgetTester tester,
  ) async {
    await appModel.setReadingGoalTextUnit(StudyGoalUnitChoice.chars);
    await open(tester, language: 'en');
    expect(presetValues(tester), <int>[3000, 5000, 10000, 20000]);
  });

  testWidgets('Chinese: one combined chip; script-only options under it', (
    WidgetTester tester,
  ) async {
    // 旧写法 zh-Hans 的格子语言 → 语言片只有一片「中文」，下面一排简繁选项。
    await open(tester, language: 'zh-Hans');
    expect(byKey('study-goal-language-zh'), findsOneWidget);
    expect(byKey('study-goal-language-zh-Hans'), findsNothing);
    expect(byKey('study-goal-script'), findsOneWidget);
    await tapKey(tester, 'study-goal-script-any');
    await tester.enterText(targetField(), '3000');
    await tester.pumpAndSettle();
    await tapKey(tester, 'study-goal-save');
    expect(appModel.studyGoals.single.language, 'zh');

    // 只算繁体：存成 zh-Hant（带 scriptExact 标记），读回来仍是只算繁体。
    await open(tester, language: 'zh');
    await tapKey(tester, 'study-goal-script-zh-Hant');
    await tester.enterText(targetField(), '4000');
    await tester.pumpAndSettle();
    await tapKey(tester, 'study-goal-save');
    expect(appModel.studyGoals.map((StudyGoal g) => g.language), <String?>[
      'zh',
      'zh-Hant',
    ]);
    // 日语没有文字之分：没有那一排。
    await open(tester, language: 'ja');
    expect(byKey('study-goal-script'), findsNothing);
  });
}
