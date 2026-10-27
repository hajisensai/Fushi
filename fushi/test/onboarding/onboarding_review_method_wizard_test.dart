// 真向导页走两条「复习方式」路径（所有者 2026-10-16）：
//
// - 默认（Fushi 复习，直接按下一步）：复习模块开、挖词目标 = Fushi 复习，Anki 配置 /
//   第一张 Anki 卡两步一概不出现，改出复习介绍；完成页给出「在哪复习 / 怎么导入 Anki
//   牌组」；
// - 展开「改用 Anki…」并选 Anki：挖词目标 = Anki、复习模块关，下一步就是原有的 Anki
//   配置步骤。
//
// 偏好走真的 PreferencesRepository（内存库），先跑一遍与 AppModel.initialise() 同一个
// 的老 / 新用户判定（全新安装 → 新用户）。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/srs/srs_mining_target.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/utils/misc/update_checker.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show Dictionary;
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../helpers/test_platform_services.dart';

class _HostAppModel extends AppModel {
  _HostAppModel(this._dir) : super(testPlatformServices());

  final Directory _dir;

  @override
  PackageInfo get packageInfo => PackageInfo(
    appName: 'Fushi',
    packageName: 'app.hibiki.reader',
    version: '1.0.0',
    buildNumber: '1',
  );

  @override
  Directory get appDirectory => _dir;

  @override
  Directory get temporaryDirectory => _dir;

  @override
  Directory get dictionaryResourceDirectory => _dir;

  @override
  Locale get appLocale => const Locale('en');

  @override
  void startUpdateChecks() {}

  @override
  bool get isDatabaseOpen => true;

  // 查词教程挑练习句子时读已装词典：本用例没有词典仓库。
  @override
  List<Dictionary> get dictionaries => const <Dictionary>[];
}

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<_HostAppModel> _pumpWizard(WidgetTester tester) async {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final PreferencesRepository prefs = PreferencesRepository(db);
  await tester.runAsync(() async {
    await prefs.loadFromDb();
    await prefs.settleSrsMiningTargetInstallDefault();
  });
  final Directory tmp = Directory.systemTemp.createTempSync(
    'fushi_onboarding_review_',
  );
  addTearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });
  final _HostAppModel app = _HostAppModel(tmp)
    // 欢迎页的明暗选择器读 themeNotifier。
    ..themeNotifier = ThemeNotifier(db, () => const TextTheme())
    ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: tmp)
    ..wireDatabaseForTesting(db);
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('window_manager'),
    (MethodCall call) async => call.method == 'isFocused' ? true : null,
  );
  tester.view.physicalSize = const Size(1280, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((ref) => app),
        platformServicesProvider.overrideWithValue(testPlatformServices()),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          navigatorKey: app.navigatorKey,
          home: const OnboardingWizardPage(),
        ),
      ),
    ),
  );
  await _settle(tester);
  return app;
}

/// 按「下一步」直到出现 [title]（向导每步的 hero 标题）；返回途经的 hero 标题。
Future<List<String>> _nextUntil(WidgetTester tester, String title) async {
  final List<String> seen = <String>[];
  for (int i = 0; i < 16; i++) {
    seen.addAll(
      tester
          .widgetList<OnboardingStepHero>(find.byType(OnboardingStepHero))
          .map((OnboardingStepHero h) => h.title),
    );
    if (find.text(title).evaluate().isNotEmpty) return seen;
    await tester.tap(find.text(t.onboarding_action_next));
    await _settle(tester);
  }
  fail('没走到「$title」，途经：$seen');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    UpdateChecker.disableAutoCheckForTesting = true;
    DesktopLookupService.instance.debugReset();
  });

  tearDown(() {
    UpdateChecker.disableAutoCheckForTesting = false;
    DesktopLookupService.instance.debugReset();
  });

  testWidgets('默认 Fushi 复习：模块开、目标 srs、Anki 步骤全部跳过', (
    WidgetTester tester,
  ) async {
    final _HostAppModel app = await _pumpWizard(tester);
    await _nextUntil(tester, t.onboarding_review_method_title);
    // Anki 收在折叠里，Fushi 复习直接呈现。
    expect(find.text(t.onboarding_review_fushi_title), findsOneWidget);
    expect(find.text(t.onboarding_review_anki_desc), findsNothing);

    final List<String> rest = await _nextUntil(
      tester,
      t.onboarding_finish_title,
    );
    expect(app.moduleEnabled(ModuleId.srs), isTrue);
    expect(app.srsMiningTarget, SrsMiningTarget.srs);
    expect(rest, isNot(contains(t.onboarding_step_anki_title)));
    expect(rest, isNot(contains(t.onboarding_step_first_anki_card_title)));
    expect(rest, contains(t.onboarding_srs_title));
    // 完成页：在哪复习、怎么导入已有 Anki 牌组。
    expect(find.text(t.onboarding_finish_next_title), findsOneWidget);
    expect(find.text(t.onboarding_finish_import_title), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 10));
  });

  testWidgets('选 Anki：目标 anki、复习模块关，下一步进原有 Anki 配置', (
    WidgetTester tester,
  ) async {
    final _HostAppModel app = await _pumpWizard(tester);
    await _nextUntil(tester, t.onboarding_review_method_title);

    await tester.tap(find.text(t.onboarding_review_anki_toggle));
    await _settle(tester);
    await tester.tap(find.text(t.onboarding_review_anki_desc));
    await _settle(tester);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    expect(app.srsMiningTarget, SrsMiningTarget.anki);
    expect(app.moduleEnabled(ModuleId.srs), isFalse);

    await tester.tap(find.text(t.onboarding_action_next));
    await _settle(tester);
    expect(find.text(t.onboarding_step_anki_title), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 10));
  });

  // 不学外语的用户：欢迎步选「只看书、看番、听书」，功能步里查词 / 制卡预先取消，
  // 走完向导时查词、制卡、复习三个模块都关，词典 / 制卡 / 复习相关步骤一个不出。
  testWidgets('只看媒体：查词 / 制卡 / 复习模块关，相关步骤全部跳过', (WidgetTester tester) async {
    final _HostAppModel app = await _pumpWizard(tester);
    expect(find.text(t.onboarding_purpose_title), findsOneWidget);
    await tester.tap(find.text(t.onboarding_purpose_media_title));
    await _settle(tester);

    await tester.tap(find.text(t.onboarding_action_next));
    await _settle(tester);
    expect(find.text(t.onboarding_features_title), findsOneWidget);
    bool tileSelected(String title) => tester
        .widgetList<OnboardingFeatureTile>(find.byType(OnboardingFeatureTile))
        .firstWhere((OnboardingFeatureTile tile) => tile.title == title)
        .selected;
    expect(tileSelected(t.settings_destination_card_creation), isFalse);
    expect(tileSelected(t.onboarding_feature_pack), isFalse);
    expect(tileSelected(t.onboarding_feature_books), isTrue);

    final List<String> rest = await _nextUntil(
      tester,
      t.onboarding_finish_title,
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    expect(app.moduleEnabled(ModuleId.lookup), isFalse);
    expect(app.moduleEnabled(ModuleId.cardCreation), isFalse);
    expect(app.moduleEnabled(ModuleId.srs), isFalse);
    expect(app.moduleEnabled(ModuleId.books), isTrue);
    expect(rest, isNot(contains(t.onboarding_step_pack_title)));
    expect(rest, isNot(contains(t.onboarding_review_method_title)));
    expect(rest, isNot(contains(t.onboarding_srs_title)));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 10));
  });

  // 反馈 VtbEJzUEYL：功能步「接下来配置」一节落在视口外，用户看不到就按了下一步。
  // 正文下方还有没看到的内容时，主按钮是「往下看」：按一下往下翻、不换步；翻到底
  // 才变回「下一步」。
  testWidgets('正文没看完时主按钮先往下翻，翻到底才换步', (WidgetTester tester) async {
    await _pumpWizard(tester);
    tester.view.physicalSize = const Size(1280, 560);
    await _settle(tester);
    final Finder next = find.byKey(const ValueKey<String>('onboarding_next'));
    Finder label(String text) =>
        find.descendant(of: next, matching: find.text(text));

    for (
      int i = 0;
      i < 12 && find.text(t.onboarding_features_title).evaluate().isEmpty;
      i++
    ) {
      await tester.tap(next);
      await _settle(tester);
    }
    expect(find.text(t.onboarding_features_title), findsOneWidget);
    expect(label(t.onboarding_action_scroll_more), findsOneWidget);
    ScrollPosition body() => tester
        .stateList<ScrollableState>(find.byType(Scrollable))
        .map((ScrollableState s) => s.position)
        .firstWhere(
          (ScrollPosition p) =>
              p.axis == Axis.vertical && p.maxScrollExtent > 0,
        );
    expect(body().pixels, 0);
    expect(body().extentAfter, greaterThan(kOnboardingMoreBelowSlop));

    int presses = 0;
    while (label(t.onboarding_action_scroll_more).evaluate().isNotEmpty) {
      await tester.tap(next);
      await _settle(tester);
      presses++;
      expect(presses, lessThan(10), reason: '一直翻不到底');
    }
    expect(presses, greaterThan(0));
    // 一直停在功能步：被翻的始终是同一个正文（最大滚动范围就是功能步的），
    // 而且已经翻到底。
    expect(body().pixels, body().maxScrollExtent);
    expect(body().extentAfter, lessThanOrEqualTo(kOnboardingMoreBelowSlop));
    expect(label(t.onboarding_action_next), findsOneWidget);

    await tester.tap(next);
    await _settle(tester);
    // 翻到底之后「下一步」才真的换步。
    expect(find.text(t.onboarding_features_setup_title), findsNothing);
    expect(find.text(t.onboarding_features_title), findsNothing);
    expect(find.byType(OnboardingStepHero), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 10));
  });
}
