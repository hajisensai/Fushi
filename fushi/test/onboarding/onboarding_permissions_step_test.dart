// 新手引导「系统权限」一步（用户 2026-10-21：安卓有些权限比如通知默认关着）：
// 紧跟功能选择出现；每项显示现状，点了走既有申请路径，回来后按真实查询结果
// 显示「已开启」。平台端口注入假实现，桌面 CI 上也跑得到这一步。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/onboarding/onboarding_steps.dart';
import 'package:fushi/src/onboarding/onboarding_system_permissions.dart';
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

Future<_HostAppModel> _pumpWizard(
  WidgetTester tester,
  OnboardingSystemPermissions permissions,
) async {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final PreferencesRepository prefs = PreferencesRepository(db);
  await tester.runAsync(() async {
    await prefs.loadFromDb();
    await prefs.settleSrsMiningTargetInstallDefault();
  });
  final Directory tmp = Directory.systemTemp.createTempSync(
    'fushi_onboarding_perm_',
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
                      builder: (_) =>
                          OnboardingWizardPage(systemPermissions: permissions),
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

class _FakePermissions implements OnboardingSystemPermissions {
  final Set<OnboardingSystemPermission> granted = <OnboardingSystemPermission>{
    OnboardingSystemPermission.storage,
  };
  final List<OnboardingSystemPermission> requested =
      <OnboardingSystemPermission>[];

  @override
  Future<bool> isGranted(OnboardingSystemPermission permission) async =>
      granted.contains(permission);

  @override
  Future<void> request(OnboardingSystemPermission permission) async {
    requested.add(permission);
    granted.add(permission);
  }
}

Finder _granted(OnboardingSystemPermission p) =>
    find.byKey(ValueKey<String>('onboarding-permission-granted-${p.name}'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('有系统权限的平台：权限一步紧跟功能选择；没有就不出', () {
    List<OnboardingStepId> seq({required bool permissions}) =>
        onboardingStepSequence(
          selected: kOnboardingDefaultCapabilities,
          browserExtensionAvailable: false,
          globalLookupAvailable: false,
          ankiReady: false,
          systemPermissionsAvailable: permissions,
        );
    final List<OnboardingStepId> android = seq(permissions: true);
    expect(
      android.indexOf(OnboardingStepId.permissions),
      android.indexOf(OnboardingStepId.features) + 1,
    );
    expect(
      seq(permissions: false),
      isNot(contains(OnboardingStepId.permissions)),
    );
  });

  testWidgets('权限一步：显示现状，点「通知」申请后变成已开启', (WidgetTester tester) async {
    final _FakePermissions permissions = _FakePermissions();
    await _pumpWizard(tester, permissions);

    for (int i = 0; i < 2; i++) {
      await tester.tap(find.text(t.onboarding_action_next));
      await _settle(tester);
    }
    expect(find.text(t.onboarding_step_permissions_title), findsOneWidget);
    // 进场即查询：存储已开、通知与悬浮窗没开。
    expect(_granted(OnboardingSystemPermission.storage), findsOneWidget);
    expect(_granted(OnboardingSystemPermission.notifications), findsNothing);
    expect(_granted(OnboardingSystemPermission.overlay), findsNothing);

    await tester.tap(find.text(t.onboarding_permission_notifications_label));
    await _settle(tester);
    expect(permissions.requested, <OnboardingSystemPermission>[
      OnboardingSystemPermission.notifications,
    ]);
    expect(_granted(OnboardingSystemPermission.notifications), findsOneWidget);

    // 已开启的行不可再点：不会重复申请。
    await tester.tap(
      find.text(t.onboarding_permission_notifications_label),
      warnIfMissed: false,
    );
    await _settle(tester);
    expect(permissions.requested, hasLength(1));
  });
}
