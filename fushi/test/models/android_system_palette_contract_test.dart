// ignore_for_file: deprecated_member_use
// HBK-AUDIT-030: real ThemeNotifier/AppModel -> extension consumer contracts.
// The mocked wire representation matches Android's Kotlin IntArray.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_color_utilities/material_color_utilities.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel dynamicColor = MethodChannel(
    'io.material.plugins/dynamic_color',
  );
  const MethodChannel paths = MethodChannel('plugins.flutter.io/path_provider');
  late Directory scratch;
  late FushiDatabase database;
  late PreferencesRepository prefs;
  late ThemeNotifier notifier;
  late AppModel model;
  late CorePalette palette;
  bool malformed = false;
  int accentRequests = 0;

  setUp(() async {
    scratch = Directory.systemTemp.createTempSync('fushi-round8-palette-');
    palette = CorePalette.of(0xFFCC3399);
    malformed = false;
    accentRequests = 0;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      paths,
      (MethodCall _) async => scratch.path,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(dynamicColor, (
      MethodCall call,
    ) async {
      if (call.method == 'getCorePalette') {
        // Android returns IntArray, decoded as Int32List. A plain Dart List
        // round-trips as List<Object?> and incorrectly exercises accent fallback.
        return Int32List.fromList(
          malformed ? <int>[0xFF112233] : palette.asList(),
        );
      }
      if (call.method == 'getAccentColor') {
        accentRequests++;
        return 0xFF006C52;
      }
      return null;
    });
    database = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(database);
    await prefs.loadFromDb();
    notifier = ThemeNotifier(database, () => const TextTheme())
      ..loadFromPrefsSnapshot(<String, String>{
        'design_system': PrefCodec.encode('material'),
        'app_theme_key': PrefCodec.encode('system-theme'),
        'brightness_mode': PrefCodec.encode('light'),
      });
    model = AppModel(testPlatformServices())
      ..themeNotifier = notifier
      ..wireDatabaseForTesting(database)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: scratch);
  });

  tearDown(() async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(dynamicColor, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, null);
    notifier.dispose();
    prefs.dispose();
    await database.close();
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  });

  test(
    'Android palette survives type migration and repeated resume is idempotent',
    () async {
      final CorePalette? decoded = await DynamicColorPlugin.getCorePalette();
      expect(
        decoded,
        isNotNull,
        reason: 'fixture must enter Android palette path',
      );
      expect(
        decoded!.asList(),
        palette.asList().map((int argb) => argb.toSigned(32)).toList(),
      );
      int notifications = 0;
      notifier.addListener(() => notifications++);
      await notifier.refreshSystemPalette();
      await notifier.refreshSystemPalette();
      expect(notifications, 1);
      expect(accentRequests, 0);
      final ColorScheme light = notifier.buildColorScheme(Brightness.light);
      final ColorScheme dark = notifier.buildColorScheme(Brightness.dark);
      expect(light.primary, Color(palette.primary.get(40)));
      expect(dark.primary, Color(palette.primary.get(80)));
      expect(
        notifier.activeSeedColor,
        isNull,
        reason: 'wallpaper palette cannot be reconstructed from one color',
      );
    },
  );

  test('invalid Android palette falls back to the platform accent', () async {
    malformed = true;
    await notifier.refreshSystemPalette();
    expect(accentRequests, 1);
    expect(notifier.systemPrimaryColor, const Color(0xFF006C52));
    expect(notifier.theme.colorScheme.brightness, Brightness.light);
    expect(notifier.activeSystemPaletteIdentity, isNull);
    expect(
      model.browserExtensionThemeColors('light')['--fushi-theme-seed'],
      isNotNull,
    );
  });

  // The historical round8 repro remains separately preserved. Exact
  // reconstruction without an opposite palette was too strong a contract;
  // missing data must instead remain unknown and use existing CSS fallback.
  test(
    'Android mirror contract: missing scheme stays explicitly unknown',
    () async {
      await notifier.refreshSystemPalette();
      expect(accentRequests, 0);
      expect(
        model.browserExtensionThemeColors('light')['--fushi-theme-seed'],
        isNull,
      );
      final Map<String, Object> first = <String, Object>{
        'light': model.browserExtensionThemeColors('light'),
        'dark': model.browserExtensionThemeColors('dark'),
      };
      final ProcessResult result = await Process.run('node', <String>[
        '../tool/review_repros/round8_android_palette_contract.mjs',
        jsonEncode(<String, Object>{'mode': 'unknown', 'first': first}),
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
  );

  test(
    'Android mirror contract: real palette identity invalidates stale opposite data',
    () async {
      await notifier.refreshSystemPalette();
      expect(accentRequests, 0);
      final Map<String, String> firstLight = model.browserExtensionThemeColors(
        'light',
      );
      final Map<String, Object> first = <String, Object>{
        'light': firstLight,
        'dark': model.browserExtensionThemeColors('dark'),
      };
      await notifier.refreshSystemPalette();
      expect(
        model.browserExtensionThemeColors('light')['--fushi-theme-palette-id'],
        firstLight['--fushi-theme-palette-id'],
        reason: 'unchanged OS palette retains identity',
      );
      palette = CorePalette.of(0xFF006C52);
      await notifier.refreshSystemPalette();
      final Map<String, Object> second = <String, Object>{
        'light': model.browserExtensionThemeColors('light'),
        'dark': model.browserExtensionThemeColors('dark'),
      };
      final ProcessResult result = await Process.run('node', <String>[
        '../tool/review_repros/round8_android_palette_contract.mjs',
        jsonEncode(<String, Object>{
          'mode': 'identity',
          'first': first,
          'second': second,
        }),
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
  );

  test('eink scheme identity invalidates previously colored mirrors', () async {
    await notifier.refreshSystemPalette();
    final String? colored = model.browserExtensionThemeColors(
      'light',
    )['--fushi-theme-palette-id'];
    expect(colored, isNotNull);
    await notifier.setEinkMode(true);
    final String? eink = model.browserExtensionThemeColors(
      'light',
    )['--fushi-theme-palette-id'];
    expect(eink, isNot(colored));
    expect(eink, isNotNull);
    expect(
      model.browserExtensionThemeColors('dark')['--fushi-theme-palette-id'],
      eink,
    );
    await notifier.setEinkMode(false);
    expect(
      model.browserExtensionThemeColors('light')['--fushi-theme-palette-id'],
      colored,
    );
  });
}
