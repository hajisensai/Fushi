// 复习模块（ModuleId.srs）的出厂默认与门控。
//
// 所有者 2026-10-16 起「默认就是 fushi srs」：新装默认开；升级上来的老用户由一次性
// 判定（PreferencesRepository.settleSrsMiningTargetInstallDefault）显式写成关、完全
// 静默（老用户不提醒）。判定之前一律按关读。
//
// - 出厂默认：ModuleId.defaultEnabled 全开；判定前的偏好库读关；外观开关有一句说明它是
//   什么的副标题；
// - 底栏 / 侧栏：关着时没有「复习」tab，打开后出现在查词之后；
// - 挂真的 HomePage：老用户升级后看不到「复习」、不弹任何引导 / 提示，在设置里打开后
//   导航里出现；新用户判定后直接看得到「复习」。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/onboarding/onboarding_steps.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/settings/settings_schema_appearance.dart';
import 'package:fushi/src/srs/srs_mining_target.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/utils/misc/update_checker.dart';
import 'package:fushi_core/fushi_core.dart';
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

  // isFirstTimeSetup / onboardingCompleted 不覆写：读真偏好，HomePage 首帧据它们决定
  // 弹不弹引导——「老用户不提醒」的断言要的正是这条真实路径。
}

class _Harness {
  _Harness(this.app, this.prefs);

  final _HostAppModel app;
  final PreferencesRepository prefs;
}

/// 挂真 HomePage：内存库 + 可选的老用户信号播种，再跑一次与 `AppModel.initialise()`
/// 同一个的老 / 新用户判定。
Future<_Harness> _pumpHome(
  WidgetTester tester, {
  Future<void> Function(PreferencesRepository prefs)? seed,
  Future<void> Function(PreferencesRepository prefs)? afterSettle,
}) async {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final PreferencesRepository prefsRepo = PreferencesRepository(db);
  await tester.runAsync(() async {
    await prefsRepo.loadFromDb();
    await seed?.call(prefsRepo);
    await prefsRepo.settleSrsMiningTargetInstallDefault();
    await afterSettle?.call(prefsRepo);
  });
  final Directory tmpDir = Directory.systemTemp.createTempSync(
    'fushi_srs_gating_',
  );
  addTearDown(() {
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {}
  });
  final _HostAppModel appModel = _HostAppModel(tmpDir)
    ..wireLocalAudioForTesting(prefsRepo: prefsRepo, databaseDirectory: tmpDir)
    ..wireDatabaseForTesting(db);
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('window_manager'),
    (MethodCall call) {
      if (call.method == 'isFocused') return Future<bool>.value(true);
      return Future<void>.value();
    },
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((ref) => appModel),
        platformServicesProvider.overrideWithValue(testPlatformServices()),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          navigatorKey: appModel.navigatorKey,
          home: const HomePage(),
        ),
      ),
    ),
  );
  await _settle(tester);
  return _Harness(appModel, prefsRepo);
}

/// 首页导航里「复习」入口：按名字找。默认底栏是相机模式条（#2462，纯图标）、收起
/// 侧栏纯图标（#2476），名字只保证进 tooltip 与无障碍语义；收起侧栏里带速览卡的
/// 目的地（#2543 起每个目的地都有）连 tooltip 都不叠——悬停弹的是速览卡，名称只在
/// Semantics label 与卡片标题里。所以文字 / tooltip / 语义名三处都认；漏认任一处，
/// 入口在而名字不画时会误判「没有入口」，「看不到」的断言也会恒真。material_ui 的
/// Tooltip 不是 SDK 旧 Tooltip，`find.byTooltip` 认不到。
Finder _srsNavEntry() => find.byWidgetPredicate(
  (Widget w) =>
      (w is Text && w.data == t.nav_srs) ||
      (w is Tooltip && w.message == t.nav_srs) ||
      (w is Semantics && w.properties.label == t.nav_srs),
);

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
  });

  group('出厂默认', () {
    test('出厂默认全开（含复习），复习五端都存在（不是商店受限能力）', () {
      for (final ModuleId m in ModuleId.values) {
        expect(m.defaultEnabled, isTrue, reason: '$m');
      }
      for (final (bool w, bool d, bool i, bool a) p
          in <(bool, bool, bool, bool)>[
            (true, true, false, false),
            (false, true, false, false),
            (false, false, true, false),
            (false, false, false, true),
          ]) {
        expect(
          ModuleId.srs.availableOn(
            isWindows: p.$1,
            isDesktop: p.$2,
            isIOS: p.$3,
            isAndroid: p.$4,
          ),
          isTrue,
        );
      }
    });

    test('新偏好库：判定前读关，新用户判定后读开，开关读回', () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      final PreferencesRepository repo = PreferencesRepository(db);
      await repo.loadFromDb();
      expect(repo.moduleEnabled(ModuleId.srs), isFalse, reason: '判定前按关');
      await repo.settleSrsMiningTargetInstallDefault();
      expect(repo.moduleEnabled(ModuleId.srs), isTrue, reason: '新装默认开');
      await repo.setModuleEnabled(ModuleId.srs, false);
      expect(repo.moduleEnabled(ModuleId.srs), isFalse);
      await repo.setModuleEnabled(ModuleId.srs, true);
      expect(repo.moduleEnabled(ModuleId.srs), isTrue);
      repo.dispose();
      await db.close();
    });

    test('偏好未就绪的 AppModel 同样判关（不 fail-open 露出复习）', () {
      final AppModel app = AppModel(testPlatformServices());
      expect(app.moduleEnabled(ModuleId.srs), isFalse);
      expect(app.moduleEnabled(ModuleId.books), isTrue);
    });

    // 复习有底栏 tab，所以它的开关在「导航模块」拖拽列表里（#2198 起有 tab 的
    // 模块不再是独立开关行）；列表行副标题与无 tab 开关行共用 moduleSwitchHint。
    test('外观 → 功能模块：复习在导航模块列表里，并说明它是什么', () {
      expect(homeTabOfModule(ModuleId.srs), HomeTab.srs);
      expect(moduleNavIdentity(ModuleId.srs).label, t.nav_srs);
      expect(moduleSwitchHint(ModuleId.srs), t.srs_module_switch_hint);
      expect(moduleSwitchHint(ModuleId.books), isNull);
    });

    test('新手引导不提供复习方格（由「复习方式」一步写入）', () {
      expect(onboardingFeatureOfModule(ModuleId.srs), isNull);
    });
  });

  group('导航', () {
    test('关着没有复习 tab；打开后紧跟查词', () {
      final ModuleVisibility off = ModuleVisibility(
        ModuleId.values.toSet()..remove(ModuleId.srs),
      );
      expect(homeActiveTabs(off), isNot(contains(HomeTab.srs)));
      final ModuleVisibility on = ModuleVisibility(ModuleId.values.toSet());
      final List<HomeTab> tabs = homeActiveTabs(on);
      expect(tabs.indexOf(HomeTab.srs), tabs.indexOf(HomeTab.dictionaries) + 1);
      expect(moduleOfHomeTab(HomeTab.srs), ModuleId.srs);
      expect(homeTabOfModule(ModuleId.srs), HomeTab.srs);
      expect(homeNavItemFor(HomeTab.srs).label, t.nav_srs);
    });

    testWidgets('真 HomePage：老用户升级后看不到复习、不弹任何引导或提示，打开后出现', (
      WidgetTester tester,
    ) async {
      final _Harness h = await _pumpHome(
        tester,
        seed: (PreferencesRepository prefs) async {
          // 老用户：首页跑过、引导完成过。
          await prefs.setPref('first_time_setup', false);
          await prefs.setOnboardingCompleted(value: true);
        },
      );
      expect(_srsNavEntry(), findsNothing, reason: '老用户：不该冒出复习入口');
      // 「老用户不提醒」：判定不弹引导、不弹对话框 / 底部弹层 / 横幅，也不把引导重新
      // 标回待完成。
      expect(find.byType(OnboardingWizardPage), findsNothing);
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(MaterialBanner), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(h.prefs.getPref('onboarding_completed'), isTrue);
      expect(h.prefs.getPref('first_time_setup'), isFalse);
      expect(h.app.srsMiningTarget, SrsMiningTarget.anki);

      await tester.runAsync(() => h.app.setModuleEnabled(ModuleId.srs, true));
      await _settle(tester);
      expect(_srsNavEntry(), findsWidgets, reason: '打开模块后底栏 / 侧栏出现「复习」');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 10));
    });

    testWidgets('真 HomePage：新用户判定后直接看得到复习', (WidgetTester tester) async {
      final _Harness h = await _pumpHome(
        tester,
        // 引导本身不在本用例范围：判定之后（新用户）把首启与引导标成已走完。
        afterSettle: (PreferencesRepository prefs) async {
          await prefs.setPref('first_time_setup', false);
          await prefs.setOnboardingCompleted(value: true);
        },
      );
      expect(_srsNavEntry(), findsWidgets, reason: '新装默认开');
      expect(h.app.srsMiningTarget, SrsMiningTarget.srs);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 10));
    });
  });
}
