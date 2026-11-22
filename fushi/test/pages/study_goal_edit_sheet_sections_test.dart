// 目标编辑面板（第五轮）：四段顺序（统计什么 → 哪种语言 → 多少 → 多久一次）、
// 周期说明、目标值校验（空 / 0 / 时长超过一个周期）与保存按钮联动。
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
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart'
    show FushiFilledButton;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/stats/stat_facts.dart' show StatFact;
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/test_platform_services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late AppModel appModel;
  late Directory storeDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocaleSettings.setLocale(AppLocale.en);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('fushi_goal_sections');
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    await appModel.setStudyGoals(const <StudyGoal>[]);
  });

  tearDown(() async {
    StatWindow.weekStartDay = DateTime.monday;
    await db.close();
    if (storeDir.existsSync()) storeDir.deleteSync(recursive: true);
  });

  Future<StudyGoalSheetData> fakeData(StudyGoalHost _) async =>
      StudyGoalSheetData(
        candidateLanguages: const <String>['ja', 'zh'],
        daily: const <StatFact>[],
        mediaLanguages: const <String, String>{},
        window: StatWindow(DateTime(2026, 11, 20)),
      );

  Finder byKey(String key) => find.byKey(ValueKey<String>(key));

  Future<void> open(WidgetTester tester, {StudyGoal? goal}) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () => showStudyGoalEditSheet(
                  context,
                  appModel,
                  goal: goal,
                  loadData: fakeData,
                ),
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

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.ensureVisible(byKey(key));
    await tester.pumpAndSettle();
    await tester.tap(byKey(key));
    await tester.pumpAndSettle();
  }

  Future<void> typeTarget(WidgetTester tester, String text) async {
    await tester.enterText(
      find.descendant(
        of: byKey('study-goal-target-field'),
        matching: find.byType(EditableText),
      ),
      text,
    );
    await tester.pumpAndSettle();
  }

  bool saveEnabled(WidgetTester tester) =>
      tester.widget<FushiFilledButton>(byKey('study-goal-save')).onPressed !=
      null;

  testWidgets('four sections in order: what → language → amount → period', (
    WidgetTester tester,
  ) async {
    await open(tester);
    final List<double> tops = <double>[
      for (final String label in <String>[
        t.study_goal_sheet_section_what,
        t.study_goal_sheet_section_language,
        t.study_goal_sheet_section_amount,
        t.study_goal_sheet_how_often,
        t.study_goal_sheet_active_days,
      ])
        tester.getTopLeft(find.text(label)).dy,
    ];
    expect(tops, orderedEquals(<double>[...tops]..sort()));
    expect(byKey('study-goal-presets-hint'), findsOneWidget);
    expect(find.text(t.study_goal_sheet_period_daily_hint), findsOneWidget);
  });

  testWidgets('period hint explains each period; active days for all', (
    WidgetTester tester,
  ) async {
    StatWindow.weekStartDay = DateTime.sunday;
    await open(tester);
    expect(byKey('study-goal-days'), findsOneWidget);
    expect(find.text(t.study_goal_sheet_active_days_hint), findsOneWidget);
    await tapKey(tester, 'study-goal-period-weekly');
    expect(
      find.text(t.study_goal_sheet_period_weekly_hint(day: 'Sunday')),
      findsOneWidget,
    );
    // 周 / 月目标也能限定生效日：提示换成「按这些日子摊」。
    expect(byKey('study-goal-days'), findsOneWidget);
    expect(
      find.text(t.study_goal_sheet_active_days_split_hint),
      findsOneWidget,
    );
    await tapKey(tester, 'study-goal-period-monthly');
    expect(find.text(t.study_goal_sheet_period_monthly_hint), findsOneWidget);
    expect(byKey('study-goal-days'), findsOneWidget);
  });

  testWidgets('language section hidden for mined; script row for Chinese', (
    WidgetTester tester,
  ) async {
    await open(tester);
    await tapKey(tester, 'study-goal-language-zh');
    expect(byKey('study-goal-script'), findsOneWidget);
    await tapKey(tester, 'study-goal-metric-mined');
    expect(byKey('study-goal-language'), findsNothing);
    expect(find.text(t.study_goal_sheet_section_language), findsNothing);
  });

  testWidgets('validation: empty / zero blocks saving with a message', (
    WidgetTester tester,
  ) async {
    await open(tester);
    expect(saveEnabled(tester), isTrue);
    await typeTarget(tester, '');
    expect(find.text(t.study_goal_sheet_target_invalid), findsOneWidget);
    expect(saveEnabled(tester), isFalse);
    await typeTarget(tester, '0');
    expect(find.text(t.study_goal_sheet_target_invalid), findsOneWidget);
    expect(saveEnabled(tester), isFalse);
    await typeTarget(tester, '12a3');
    // 只收数字：非数字字符被过滤掉。
    expect(find.text(t.study_goal_sheet_target_invalid), findsNothing);
    expect(saveEnabled(tester), isTrue);
  });

  testWidgets('validation: time longer than the period', (
    WidgetTester tester,
  ) async {
    await open(tester);
    await tapKey(tester, 'study-goal-metric-reading');
    await typeTarget(tester, '${kStudyGoalMaxMinutesDaily + 1}');
    expect(find.text(t.study_goal_sheet_target_over_day), findsOneWidget);
    expect(saveEnabled(tester), isFalse);
    await tapKey(tester, 'study-goal-period-weekly');
    expect(find.text(t.study_goal_sheet_target_over_day), findsNothing);
    expect(saveEnabled(tester), isTrue);
    await typeTarget(tester, '${kStudyGoalMaxMinutesWeekly + 1}');
    expect(find.text(t.study_goal_sheet_target_over_week), findsOneWidget);
    await tapKey(tester, 'study-goal-period-monthly');
    expect(saveEnabled(tester), isTrue);
    await typeTarget(tester, '${kStudyGoalMaxMinutesMonthly + 1}');
    expect(find.text(t.study_goal_sheet_target_over_month), findsOneWidget);
    expect(saveEnabled(tester), isFalse);
    // 数量目标没有上限。
    await tapKey(tester, 'study-goal-metric-chars');
    await typeTarget(tester, '999999');
    expect(saveEnabled(tester), isTrue);
  });
}
