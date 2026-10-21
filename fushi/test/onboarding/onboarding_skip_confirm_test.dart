// 「暂时跳过」新手引导要二次确认，确认键强制等 3 秒（用户 2026-10-21：手滑点了
// 跳过就找不回引导）。系统返回与跳过同义，走同一个确认。跳过只记「弹过」，不记
// 「走完」——首页的新手引导卡据此留着（homeOnboardingCardVisible）。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/pages/implementations/home_dashboard_widgets.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/platform/platform_providers.dart';
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
    'fushi_onboarding_skip_',
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
          // 宿主页：向导从它上面 push（与 HomePage 首启同形），pop 后回到这里。
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: Center(
                child: TextButton(
                  key: const ValueKey<String>('open-wizard'),
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      fullscreenDialog: true,
                      builder: (_) => const OnboardingWizardPage(),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await _settle(tester);
  // 模拟全新安装首帧：「弹过」与「走完」都是 false。
  await tester.runAsync(() async {
    await prefs.setOnboardingCompleted(value: false);
    await prefs.setOnboardingFinished(value: false);
  });
  await tester.tap(find.byKey(const ValueKey<String>('open-wizard')));
  await _settle(tester);
  expect(find.byType(OnboardingWizardPage), findsOneWidget);
  return app;
}

String get _countdownLabel => t.onboarding_skip_confirm_action;

Finder get _confirmAction =>
    find.byKey(const ValueKey<String>('fushi-confirm-countdown-action'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('跳过：确认键倒计时 3 秒内点不动，到点确认才关向导', (WidgetTester tester) async {
    final _HostAppModel app = await _pumpWizard(tester);

    await tester.tap(find.byKey(const ValueKey<String>('onboarding_skip')));
    await _settle(tester);
    expect(find.text(t.onboarding_skip_confirm_title), findsOneWidget);
    expect(find.text('$_countdownLabel (3)'), findsOneWidget);

    // 倒计时内点确认键：无效，对话框与向导都还在。
    // 时间线：对话框弹出后 _settle 已走 600 ms。
    await tester.tap(_confirmAction, warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text(t.onboarding_skip_confirm_title), findsOneWidget);
    expect(app.onboardingCompleted, isFalse);

    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('$_countdownLabel (2)'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text(_countdownLabel), findsOneWidget);

    await tester.tap(_confirmAction);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await _settle(tester);
    expect(find.byType(OnboardingWizardPage), findsNothing);
    expect(app.onboardingCompleted, isTrue);
    // 跳过 ≠ 走完：首页引导卡要留着。
    expect(app.onboardingFinished, isFalse);
  });

  testWidgets('跳过确认点取消：留在向导', (WidgetTester tester) async {
    await _pumpWizard(tester);
    await tester.tap(find.byKey(const ValueKey<String>('onboarding_skip')));
    await _settle(tester);
    await tester.tap(find.text(t.dialog_cancel));
    await _settle(tester);
    expect(find.text(t.onboarding_skip_confirm_title), findsNothing);
    expect(find.byType(OnboardingWizardPage), findsOneWidget);
  });

  testWidgets('系统返回不直接关向导，而是弹同一个跳过确认', (WidgetTester tester) async {
    await _pumpWizard(tester);
    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(find.text(t.onboarding_skip_confirm_title), findsOneWidget);
    expect(find.byType(OnboardingWizardPage), findsOneWidget);
    // 收尾：等倒计时走完再关掉对话框，不留挂着的 Timer。
    await tester.pump(const Duration(seconds: 3));
    await tester.tap(find.text(t.dialog_cancel));
    await _settle(tester);
  });

  group('homeOnboardingCardVisible', () {
    test('跳过了引导：库里有东西也显示', () {
      expect(
        homeOnboardingCardVisible(
          dismissed: false,
          onboardingFinished: false,
          libraryEmpty: false,
        ),
        isTrue,
      );
    });
    test('走完了引导但库还是空的：显示', () {
      expect(
        homeOnboardingCardVisible(
          dismissed: false,
          onboardingFinished: true,
          libraryEmpty: true,
        ),
        isTrue,
      );
    });
    test('走完了且有内容：不显示', () {
      expect(
        homeOnboardingCardVisible(
          dismissed: false,
          onboardingFinished: true,
          libraryEmpty: false,
        ),
        isFalse,
      );
    });
    test('点过「不再显示」：一律不显示', () {
      expect(
        homeOnboardingCardVisible(
          dismissed: true,
          onboardingFinished: false,
          libraryEmpty: true,
        ),
        isFalse,
      );
    });
  });
}
