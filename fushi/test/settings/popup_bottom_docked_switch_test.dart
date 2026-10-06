import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/settings/material_settings_renderer.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/fake_platform_services.dart';
import '../helpers/test_platform_services.dart';

/// TODO-108：底部固定弹窗开关的专项 widget 测试——验证 lookup 设置页确实渲染该开关、
/// 默认 OFF，且切换后真写穿偏好（[AppModel.popupBottomDocked] → prefsRepo → DB）。
/// 与 dictionary_popup_layer_test.dart 的纯函数测试互补（一个证开关、一个证位置算法）。
FushiDatabase _testDb() {
  return FushiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

Future<AppModel> _prefsBackedAppModel(
  FushiDatabase db, {
  PlatformServices? platform,
}) async {
  final PreferencesRepository prefsRepo = PreferencesRepository(db);
  await prefsRepo.loadFromDb();
  final Directory tempDir =
      Directory.systemTemp.createTempSync('hibiki_popup_dock_');
  addTearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });
  return AppModel(platform ?? testPlatformServices())
    ..wireLocalAudioForTesting(prefsRepo: prefsRepo, databaseDirectory: tempDir)
    ..wireDatabaseForTesting(db);
}

Widget _harness(FushiDatabase db, AppModel appModel) {
  final ThemeNotifier themeNotifier = ThemeNotifier(db, () => const TextTheme())
    ..loadFromPrefsSnapshot(<String, String>{
      'design_system': PrefCodec.encode('material'),
      'app_theme_key': PrefCodec.encode('system-theme'),
      'brightness_mode': PrefCodec.encode('system'),
      'custom_theme_seed': PrefCodec.encode(0xFF1F4959),
    });
  appModel.themeNotifier = themeNotifier;
  addTearDown(themeNotifier.dispose);

  return ProviderScope(
    overrides: <Override>[
      appProvider.overrideWith((Ref ref) => appModel),
    ],
    child: MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        platform: TargetPlatform.android,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF386A58)),
        extensions: <ThemeExtension<dynamic>>[
          FushiDesignSystemTheme(themeNotifier.designSystemTheme),
        ],
      ),
      home: Consumer(
        builder: (BuildContext context, WidgetRef ref, _) {
          final SettingsContext sctx = SettingsContext(
            context: context,
            appModel: ref.read(appProvider),
            ref: ref,
            readerSource: ReaderFushiSource.instance,
            refresh: () {},
          );
          final SettingsDestination lookup =
              buildSettingsSchema(sctx).firstWhere(
            (SettingsDestination d) => d.id == SettingsDestinationId.lookup,
          );
          return MaterialSettingsRenderer().buildDetailPage(
            settingsContext: sctx,
            destination: lookup,
          );
        },
      ),
    ),
  );
}

void main() {
  // 「弹窗窗口」section 现在默认折叠，会把行移出树；本测试直查该 section 的行，
  // 强制全展开还原（见 debugSettingsForceExpandAllSections）。
  setUp(() => debugSettingsForceExpandAllSections = true);
  tearDown(() => debugSettingsForceExpandAllSections = false);

  testWidgets(
      'lookup settings exposes a Bottom-docked popup switch (default OFF)',
      (WidgetTester tester) async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final AppModel appModel = await _prefsBackedAppModel(db);

    await tester.pumpWidget(_harness(db, appModel));
    await tester.pump(const Duration(milliseconds: 100));

    expect(appModel.popupBottomDocked, isFalse, reason: '默认跟随被查词位置（OFF）');

    Finder rowFinder() => find.byWidgetPredicate(
          (Widget w) =>
              w is AdaptiveSettingsSwitchRow &&
              w.title == t.popup_bottom_docked,
        );

    expect(rowFinder(), findsOneWidget, reason: 'lookup 设置页须渲染底部固定弹窗开关');
    final AdaptiveSettingsSwitchRow row =
        tester.widget<AdaptiveSettingsSwitchRow>(rowFinder());
    expect(row.value, isFalse, reason: '开关初始为 OFF');
    expect(row.icon, Icons.vertical_align_bottom_outlined);
  });

  testWidgets('toggling the switch writes popup_bottom_docked through to prefs',
      (WidgetTester tester) async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final AppModel appModel = await _prefsBackedAppModel(db);

    await tester.pumpWidget(_harness(db, appModel));
    await tester.pump(const Duration(milliseconds: 100));

    Finder rowFinder() => find.byWidgetPredicate(
          (Widget w) =>
              w is AdaptiveSettingsSwitchRow &&
              w.title == t.popup_bottom_docked,
        );

    // 切到 ON：onChanged 走 appModel.setPopupBottomDocked → prefsRepo → DB。
    tester.widget<AdaptiveSettingsSwitchRow>(rowFinder()).onChanged!(true);
    await tester.pump(const Duration(milliseconds: 50));

    expect(appModel.popupBottomDocked, isTrue, reason: '切 ON 后内存值翻转');
    final dynamic stored = await db.getPref('popup_bottom_docked');
    expect(stored, isNotNull, reason: 'ON 写穿到偏好 DB');

    // 再切回 OFF：可逆，且写穿。
    tester.widget<AdaptiveSettingsSwitchRow>(rowFinder()).onChanged!(false);
    await tester.pump(const Duration(milliseconds: 50));
    expect(appModel.popupBottomDocked, isFalse, reason: '可切回 OFF');
  });

  // ---- 底部停靠按模块细分（小说 / 漫画 / 视频 / 游戏）----

  PlatformServices platformOf({required bool windows, required bool ios}) =>
      fakePlatformServices(
        isWindows: windows,
        isDesktop: windows,
        isIOS: ios,
        isAndroid: false,
      );

  Finder moduleRow(ModuleId module) {
    final String title = switch (module) {
      ModuleId.books => t.popup_bottom_docked_books,
      ModuleId.manga => t.popup_bottom_docked_manga,
      ModuleId.video => t.popup_bottom_docked_video,
      ModuleId.games => t.popup_bottom_docked_games,
      _ => throw StateError('$module'),
    };
    return find.byWidgetPredicate(
      (Widget w) => w is AdaptiveSettingsSwitchRow && w.title == title,
    );
  }

  testWidgets('module dock switches stay hidden while the master switch is OFF',
      (WidgetTester tester) async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final AppModel appModel = await _prefsBackedAppModel(
      db,
      platform: platformOf(windows: true, ios: false),
    );

    await tester.pumpWidget(_harness(db, appModel));
    await tester.pump(const Duration(milliseconds: 100));

    for (final ModuleId module
        in PreferencesRepository.kPopupBottomDockedModules) {
      expect(moduleRow(module), findsNothing, reason: '总开关关着时不出 $module 的细分开关');
    }
  });

  testWidgets(
      'master ON shows novels/manga/video/games switches (default ON) and '
      'toggling one only turns docking off in that module',
      (WidgetTester tester) async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final AppModel appModel = await _prefsBackedAppModel(
      db,
      platform: platformOf(windows: true, ios: false),
    );
    await appModel.setPopupBottomDocked(true);

    await tester.pumpWidget(_harness(db, appModel));
    await tester.pump(const Duration(milliseconds: 100));

    for (final ModuleId module
        in PreferencesRepository.kPopupBottomDockedModules) {
      expect(moduleRow(module), findsOneWidget, reason: '$module 细分开关须渲染');
      expect(
        tester.widget<AdaptiveSettingsSwitchRow>(moduleRow(module)).value,
        isTrue,
        reason: '默认开：升级用户打开总开关时行为不变',
      );
      expect(appModel.popupBottomDockedFor(module), isTrue);
    }

    tester
        .widget<AdaptiveSettingsSwitchRow>(moduleRow(ModuleId.video))
        .onChanged!(false);
    await tester.pump(const Duration(milliseconds: 50));

    expect(appModel.popupBottomDockedIn(ModuleId.video), isFalse);
    expect(await db.getPref('popup_bottom_docked_video'), isNotNull,
        reason: '细分开关写穿到偏好 DB');
    expect(appModel.popupBottomDockedFor(ModuleId.video), isFalse,
        reason: '视频页不再停靠');
    expect(appModel.popupBottomDockedFor(ModuleId.books), isTrue,
        reason: '其余模块不受影响');
    expect(appModel.popupBottomDockedFor(null), isTrue,
        reason: '不属于四个模块的宿主（查词页等）只听总开关');

    await appModel.setPopupBottomDocked(false);
    for (final ModuleId module
        in PreferencesRepository.kPopupBottomDockedModules) {
      expect(appModel.popupBottomDockedFor(module), isFalse,
          reason: '总开关关掉后任何模块都不停靠');
    }
  });

  testWidgets('iOS games (stream only) keeps the dock switch',
      (WidgetTester tester) async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final AppModel appModel = await _prefsBackedAppModel(
      db,
      platform: platformOf(windows: false, ios: true),
    );
    await appModel.setPopupBottomDocked(true);

    await tester.pumpWidget(_harness(db, appModel));
    await tester.pump(const Duration(milliseconds: 100));

    expect(moduleRow(ModuleId.games), findsOneWidget);
    expect(moduleRow(ModuleId.books), findsOneWidget);
    expect(moduleRow(ModuleId.manga), findsOneWidget);
    expect(moduleRow(ModuleId.video), findsOneWidget);
  });

  testWidgets('a module turned off in Feature modules hides its dock switch',
      (WidgetTester tester) async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final AppModel appModel = await _prefsBackedAppModel(
      db,
      platform: platformOf(windows: true, ios: false),
    );
    await appModel.setPopupBottomDocked(true);
    await appModel.setModuleEnabled(ModuleId.manga, false);

    await tester.pumpWidget(_harness(db, appModel));
    await tester.pump(const Duration(milliseconds: 100));

    expect(moduleRow(ModuleId.manga), findsNothing);
    expect(moduleRow(ModuleId.books), findsOneWidget);
    expect(moduleRow(ModuleId.games), findsOneWidget);
  });
}
