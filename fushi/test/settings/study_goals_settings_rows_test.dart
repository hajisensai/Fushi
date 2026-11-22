// 设置 › 目标「我的目标」（第五轮）：按语言分组、组头折叠、组内上移下移重排落库、
// 删除 + 撤销回到组内原位、行标题用白话写目标值与周期。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    show Override, ProviderScope;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/settings/settings_schema_study_goals.dart';
import 'package:fushi/src/srs/srs_providers.dart'
    show srsMiningToReviewProvider;
import 'package:fushi/src/stats/study_goal_record.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/test_platform_services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late AppModel appModel;
  late Directory storeDir;

  final List<StudyGoal> seed = <StudyGoal>[
    StudyGoal(
      id: 'zh-reading',
      metric: StudyGoalId.reading,
      period: StudyGoalPeriod.daily,
      target: 60,
      language: 'zh',
    ),
    StudyGoal(
      id: 'ja-reading',
      metric: StudyGoalId.reading,
      period: StudyGoalPeriod.daily,
      target: 60,
      language: 'ja',
    ),
    StudyGoal(
      id: 'all-watch',
      metric: StudyGoalId.watching,
      period: StudyGoalPeriod.daily,
      target: 120,
    ),
    StudyGoal(
      id: 'zh-total',
      metric: StudyGoalId.total,
      period: StudyGoalPeriod.daily,
      target: 30,
      language: 'zh',
    ),
    StudyGoal(
      id: 'mined',
      metric: StudyGoalId.mined,
      period: StudyGoalPeriod.daily,
      target: 10,
    ),
    StudyGoal(
      id: 'zh-chars',
      metric: StudyGoalId.chars,
      period: StudyGoalPeriod.weekly,
      target: 28000,
      language: 'zh-Hans',
    ),
  ];

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocaleSettings.setLocale(AppLocale.en);
    StudyGoalGroupBlock.collapsedGroups.clear();
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('fushi_goal_rows');
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    await appModel.setStudyGoals(seed);
  });

  tearDown(() async {
    await db.close();
    if (storeDir.existsSync()) storeDir.deleteSync(recursive: true);
  });

  Finder byKey(String key) => find.byKey(ValueKey<String>(key));

  List<String> ids() => <String>[
    for (final StudyGoal g in appModel.studyGoals) g.id,
  ];

  Future<void> pumpRows(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        // 复习数不参与这里的断言：不走内置复习统计。
        overrides: <Override>[
          srsMiningToReviewProvider.overrideWithValue(false),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (BuildContext context, StateSetter setState) =>
                    SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: buildStudyGoalRows(
                          context,
                          appModel,
                          () => setState(() {}),
                        ),
                      ),
                    ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  double topOf(WidgetTester tester, String key) =>
      tester.getTopLeft(byKey(key)).dy;

  Future<void> press(WidgetTester tester, String key) async {
    await tester.ensureVisible(byKey(key));
    await tester.pumpAndSettle();
    await tester.tap(byKey(key));
    await tester.pumpAndSettle();
  }

  testWidgets('groups: languages by first appearance → all → any', (
    WidgetTester tester,
  ) async {
    await pumpRows(tester);
    final List<double> tops = <double>[
      for (final String g in <String>['zh', 'ja', 'all', 'any'])
        topOf(tester, 'study-goal-group-toggle-$g'),
    ];
    expect(tops, orderedEquals(<double>[...tops]..sort()));
    // 「只算简体」的中文目标在「中文」组里，组内保持列表先后。
    final double zhHeader = topOf(tester, 'study-goal-group-toggle-zh');
    final double jaHeader = topOf(tester, 'study-goal-group-toggle-ja');
    for (final String id in <String>['zh-reading', 'zh-total', 'zh-chars']) {
      final double top = topOf(tester, 'study-goal-row-$id');
      expect(top, greaterThan(zhHeader));
      expect(top, lessThan(jaHeader));
    }
    expect(
      topOf(tester, 'study-goal-row-zh-reading'),
      lessThan(topOf(tester, 'study-goal-row-zh-total')),
    );
    expect(
      topOf(tester, 'study-goal-row-mined'),
      greaterThan(topOf(tester, 'study-goal-group-toggle-any')),
    );
    // 行标题：目标值与周期用白话写在一起。
    expect(find.text('Reading — 1 hr / day'), findsNWidgets(2));
    expect(find.text('Characters — 28,000 / week'), findsOneWidget);
    expect(find.text('3 goals'), findsOneWidget);
    expect(find.text('1 goal'), findsNWidgets(3));
    expect(find.textContaining('Only '), findsOneWidget);
    // 副标题的进度：与小组件同一个紧凑格式化（单位在标题里，不重复）+ 状态。
    expect(find.textContaining('0 / 28K · '), findsOneWidget);
  });

  testWidgets('arrows that cannot move are hidden, not just greyed out', (
    WidgetTester tester,
  ) async {
    await pumpRows(tester);
    // 灰掉的箭头在墨水屏上和可用的一样黑：移不动的方向不画（只占位、行尾对齐）。
    Visibility arrow(String key) => tester.widget<Visibility>(
      find.ancestor(of: byKey(key), matching: find.byType(Visibility)).first,
    );
    expect(arrow('study-goal-up-zh-reading').visible, isFalse);
    expect(arrow('study-goal-down-zh-reading').visible, isTrue);
    expect(arrow('study-goal-up-zh-chars').visible, isTrue);
    expect(arrow('study-goal-down-zh-chars').visible, isFalse);
    // 组里只有一条：两个方向都不画。
    expect(arrow('study-goal-up-mined').visible, isFalse);
    expect(arrow('study-goal-down-mined').visible, isFalse);
  });

  testWidgets('group header collapses and expands its rows', (
    WidgetTester tester,
  ) async {
    await pumpRows(tester);
    expect(byKey('study-goal-row-zh-total'), findsOneWidget);
    await press(tester, 'study-goal-group-toggle-zh');
    expect(byKey('study-goal-row-zh-total'), findsNothing);
    expect(byKey('study-goal-row-ja-reading'), findsOneWidget);
    expect(StudyGoalGroupBlock.collapsedGroups, <String>{'zh'});
    await press(tester, 'study-goal-group-toggle-zh');
    expect(byKey('study-goal-row-zh-total'), findsOneWidget);
  });

  testWidgets('move down / up reorders inside the group and persists', (
    WidgetTester tester,
  ) async {
    await pumpRows(tester);
    await press(tester, 'study-goal-down-zh-reading');
    // 只在「中文」组占着的位置之间挪：别的组的目标位置不动。
    expect(ids(), <String>[
      'zh-total',
      'ja-reading',
      'all-watch',
      'zh-reading',
      'mined',
      'zh-chars',
    ]);
    expect(
      topOf(tester, 'study-goal-row-zh-total'),
      lessThan(topOf(tester, 'study-goal-row-zh-reading')),
    );
    await press(tester, 'study-goal-up-zh-chars');
    expect(ids(), <String>[
      'zh-total',
      'ja-reading',
      'all-watch',
      'zh-chars',
      'mined',
      'zh-reading',
    ]);
    final PreferencesRepository fresh = PreferencesRepository(db);
    await tester.runAsync(fresh.loadFromDb);
    expect(fresh.studyGoals.map((StudyGoal g) => g.id), ids());
  });

  testWidgets('delete then undo puts the goal back in its group slot', (
    WidgetTester tester,
  ) async {
    await pumpRows(tester);
    await press(tester, 'study-goal-row-zh-total');
    await press(tester, 'study-goal-delete');
    expect(ids(), isNot(contains('zh-total')));
    expect(byKey('study-goal-row-zh-total'), findsNothing);
    expect(find.text('2 goals'), findsOneWidget);
    await press(tester, 'study-goal-undo-delete');
    expect(ids(), <String>[
      'zh-reading',
      'ja-reading',
      'all-watch',
      'zh-total',
      'mined',
      'zh-chars',
    ]);
    expect(
      topOf(tester, 'study-goal-row-zh-total'),
      lessThan(topOf(tester, 'study-goal-row-zh-chars')),
    );
  });
}
