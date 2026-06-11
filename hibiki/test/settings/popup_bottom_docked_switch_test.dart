import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/models/theme_notifier.dart';
import 'package:hibiki/src/settings/material_settings_renderer.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_schema.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_platform.dart';
import 'package:hibiki/src/utils/components/settings_shared.dart';
import 'package:hibiki_core/hibiki_core.dart';

import '../helpers/test_platform_services.dart';

/// TODO-108：底部固定弹窗开关的专项 widget 测试——验证 lookup 设置页确实渲染该开关、
/// 默认 OFF，且切换后真写穿偏好（[AppModel.popupBottomDocked] → prefsRepo → DB）。
/// 与 dictionary_popup_layer_test.dart 的纯函数测试互补（一个证开关、一个证位置算法）。
HibikiDatabase _testDb() {
  return HibikiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

Future<AppModel> _prefsBackedAppModel(HibikiDatabase db) async {
  final PreferencesRepository prefsRepo = PreferencesRepository(db);
  await prefsRepo.loadFromDb();
  final Directory tempDir =
      Directory.systemTemp.createTempSync('hibiki_popup_dock_');
  addTearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });
  return AppModel(testPlatformServices())
    ..wireLocalAudioForTesting(prefsRepo: prefsRepo, databaseDirectory: tempDir)
    ..wireDatabaseForTesting(db);
}

Widget _harness(HibikiDatabase db, AppModel appModel) {
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
          HibikiDesignSystemTheme(themeNotifier.designSystemTheme),
        ],
      ),
      home: Consumer(
        builder: (BuildContext context, WidgetRef ref, _) {
          final SettingsContext sctx = SettingsContext(
            context: context,
            appModel: ref.read(appProvider),
            ref: ref,
            readerSource: ReaderHibikiSource.instance,
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
  testWidgets(
      'lookup settings exposes a Bottom-docked popup switch (default OFF)',
      (WidgetTester tester) async {
    final HibikiDatabase db = _testDb();
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
    final HibikiDatabase db = _testDb();
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
}
