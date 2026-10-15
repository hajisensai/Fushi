// 复习模块（ModuleId.srs）默认关闭、自己打开才出现入口（用户 2026-10-14 拍板）。
//
// - 出厂默认：新偏好库里 moduleEnabled(srs) == false；外观开关的 defaultValue 同为
//   false，且有一句说明它是什么的副标题；
// - 底栏 / 侧栏：关着时没有「复习」tab，打开后出现在查词之后；
// - 挂真的 HomePage：默认看不到「复习」，在设置里打开后导航里出现。
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

  @override
  bool get isFirstTimeSetup => false;

  @override
  bool get onboardingCompleted => true;
}

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
    test('只有复习默认关，五端都存在（不是商店受限能力）', () {
      expect(ModuleId.srs.defaultEnabled, isFalse);
      for (final ModuleId m in ModuleId.values) {
        if (m == ModuleId.srs) continue;
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

    test('新偏好库：moduleEnabled(srs) 为 false，打开后读回 true', () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      final PreferencesRepository repo = PreferencesRepository(db);
      await repo.loadFromDb();
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
    test('外观 → 功能模块：复习在导航模块列表里、默认关，并说明它是什么', () {
      expect(homeTabOfModule(ModuleId.srs), HomeTab.srs);
      expect(ModuleId.srs.defaultEnabled, isFalse);
      expect(moduleNavIdentity(ModuleId.srs).label, t.nav_srs);
      expect(moduleSwitchHint(ModuleId.srs), t.srs_module_switch_hint);
      expect(moduleSwitchHint(ModuleId.books), isNull);
    });

    test('新手引导不提供复习方格、也不替用户写入', () {
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

    testWidgets('真 HomePage：默认看不到复习，在设置里打开后导航出现「复习」', (
      WidgetTester tester,
    ) async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      final PreferencesRepository prefsRepo = PreferencesRepository(db);
      await prefsRepo.loadFromDb();
      final Directory tmpDir = Directory.systemTemp.createTempSync(
        'fushi_srs_gating_',
      );
      addTearDown(() {
        try {
          tmpDir.deleteSync(recursive: true);
        } catch (_) {}
      });
      final _HostAppModel appModel = _HostAppModel(tmpDir)
        ..wireLocalAudioForTesting(
          prefsRepo: prefsRepo,
          databaseDirectory: tmpDir,
        )
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
      expect(find.text(t.nav_srs), findsNothing, reason: '默认关：不该有复习入口');

      await tester.runAsync(
        () => appModel.setModuleEnabled(ModuleId.srs, true),
      );
      await _settle(tester);
      expect(find.text(t.nav_srs), findsWidgets, reason: '打开模块后底栏 / 侧栏出现「复习」');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 10));
    });
  });
}
