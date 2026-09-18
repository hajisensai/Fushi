// 浏览器扩展「主题：跟随 / 浅色 / 深色」设置：查词请求体带 `colorScheme` 时，
// `AppModel.browserExtensionThemeColors` 按请求的明暗（而非 app 当前明暗）生成
// `--md-*` 等变量，并在 `--fushi-color-scheme` 回显实际采用的明暗；缺省跟随 app。
import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  // AppModel 构造时 DefaultCacheManager 经 path_provider 平台通道，单测 mock 掉。
  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_path_provider');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => pathProviderDir.path,
    );
  });
  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (pathProviderDir.existsSync()) {
      pathProviderDir.deleteSync(recursive: true);
    }
  });

  late FushiDatabase db;
  late PreferencesRepository prefs;
  late ThemeNotifier themeNotifier;
  late AppModel appModel;

  setUp(() async {
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    themeNotifier = ThemeNotifier(db, () => const TextTheme())
      ..loadFromPrefsSnapshot(<String, String>{
        'design_system': PrefCodec.encode('material'),
        'app_theme_key': PrefCodec.encode('system-theme'),
        'brightness_mode': PrefCodec.encode('light'),
        'custom_theme_seed': PrefCodec.encode(0xFF1F4959),
      });
    appModel = AppModel(testPlatformServices())
      ..themeNotifier = themeNotifier
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(
        prefsRepo: prefs,
        databaseDirectory:
            Directory.systemTemp.createTempSync('hibiki_ext_theme'),
      );
  });

  tearDown(() async {
    themeNotifier.dispose();
    prefs.dispose();
    await db.close();
  });

  test('缺省跟随 app 当前明暗（浅色 app → light）', () {
    expect(themeNotifier.isDarkMode, isFalse);
    final Map<String, String> vars = appModel.browserExtensionThemeColors(null);
    expect(vars['--fushi-color-scheme'], 'light');
  });

  test("请求 'dark' 时按深色生成：回显 dark 且 --md-* 与浅色不同", () {
    final Map<String, String> light =
        appModel.browserExtensionThemeColors('light');
    final Map<String, String> dark =
        appModel.browserExtensionThemeColors('dark');
    expect(light['--fushi-color-scheme'], 'light');
    expect(dark['--fushi-color-scheme'], 'dark');
    // 同一 seed 的明暗 scheme 至少在 surface / on-surface 上不同。
    expect(
        dark['--md-surface-container'], isNot(light['--md-surface-container']));
    expect(dark['--md-on-surface'], isNot(light['--md-on-surface']));
    expect(dark['--text-color'], isNot(light['--text-color']));
    expect(dark['--background-color'], isNot(light['--background-color']));
    // 显式 light 与「跟随（app 当前是浅色）」逐项一致：显式选项不是另一套色。
    expect(light, appModel.browserExtensionThemeColors(null));
  });
}
