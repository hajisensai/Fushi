import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/web_browser/web_browser_settings_page.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_web_browser.dart';
import 'package:fushi/src/settings/settings_schema_web_browser_extension.dart';
import 'package:fushi/src/web_browser/features/extension_host/web_browser_extension_storage.dart';
import 'package:fushi/src/web_browser/features/extension_host/web_browser_extension_storage_provider.dart';
import 'package:fushi/src/web_browser/features/extension_host/web_browser_extension_strings.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

/// 统一「浏览器设置」：浏览器本身 + 浏览器扩展各组。扩展各组的键名 / 缺省值以扩展为准，
/// 改值写进 app 内浏览器的扩展存储（页内脚本读的同一份）；宽屏双栏、窄屏下钻。
void main() {
  late Map<String, String> en;

  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.en);
    en = parseWebBrowserExtensionEnglishLocale(
      File('assets/browser_extension/locales/en.js').readAsStringSync(),
    );
  });

  setUp(() => WebBrowserExtensionStrings.instance.debugSet(en));
  tearDown(WebBrowserExtensionStrings.instance.debugReset);

  Future<AppModel> appModelFor(FushiDatabase db) async {
    final PreferencesRepository prefsRepo = PreferencesRepository(db);
    await prefsRepo.loadFromDb();
    final Directory tempDir = Directory.systemTemp.createTempSync(
      'fushi_web_browser_settings_',
    );
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    return _TestAppModel()
      ..wireLocalAudioForTesting(
        prefsRepo: prefsRepo,
        databaseDirectory: tempDir,
      )
      ..wireDatabaseForTesting(db);
  }

  Future<AppModel> pumpPage(
    WidgetTester tester, {
    required Size size,
    WebBrowserSettingsGroup? group,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final FushiDatabase db = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    addTearDown(db.close);
    final AppModel appModel = await appModelFor(db);
    final ThemeNotifier themeNotifier =
        ThemeNotifier(db, () => const TextTheme())
          ..loadFromPrefsSnapshot(<String, String>{
            'design_system': PrefCodec.encode('auto'),
            'app_theme_key': PrefCodec.encode('system-theme'),
            'brightness_mode': PrefCodec.encode('system'),
            'custom_theme_seed': PrefCodec.encode(0xFF1F4959),
          });
    appModel.themeNotifier = themeNotifier;
    addTearDown(themeNotifier.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[appProvider.overrideWith((Ref ref) => appModel)],
        child: TranslationProvider(
          child: MaterialApp(
            theme: ThemeData(
              useMaterial3: true,
              platform: TargetPlatform.android,
              extensions: <ThemeExtension<dynamic>>[
                FushiDesignSystemTheme(themeNotifier.designSystemTheme),
              ],
            ),
            home: WebBrowserSettingsPage(initialGroup: group),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    return appModel;
  }

  WebBrowserExtensionStorage storageOf(WidgetTester tester) =>
      ProviderScope.containerOf(
        tester.element(find.byType(WebBrowserSettingsPage)),
      ).read(webBrowserExtensionStorageProvider);

  Map<String, Object?> stored(AppModel appModel) {
    final Object? raw = appModel.prefsRepo.getPref(
      kWebBrowserExtensionStoragePref,
      defaultValue: '',
    );
    return raw is String && raw.isNotEmpty
        ? jsonDecode(raw) as Map<String, Object?>
        : <String, Object?>{};
  }

  testWidgets('改扩展设置：写穿扩展存储并发出变更（打开着的标签页据此收到 onChanged）', (
    WidgetTester tester,
  ) async {
    final AppModel appModel = await pumpPage(
      tester,
      size: const Size(1280, 900),
      group: WebBrowserSettingsGroup.subtitle,
    );
    final List<Map<String, WebBrowserExtensionStorageChange>> changes =
        <Map<String, WebBrowserExtensionStorageChange>>[];
    final WebBrowserExtensionStorage storage = storageOf(tester);
    final StreamSubscription<Map<String, WebBrowserExtensionStorageChange>>
    sub = storage.changes.listen(changes.add);
    addTearDown(sub.cancel);

    final Finder row = find.text(en['opt_subtitleReplaceNative_title']!);
    expect(row, findsOneWidget);
    await tester.tap(row);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(stored(appModel)['subtitleReplaceNative'], isTrue);
    expect(changes, hasLength(1));
    expect(changes.single['subtitleReplaceNative']!.newValue, isTrue);
    expect(changes.single['subtitleReplaceNative']!.hadOld, isFalse);

    // 外部写入（页内脚本 / 播放器菜单）：设置页就地重画成新值。
    await tester.runAsync(
      () => storage.set(<String, Object?>{'subtitleReplaceNative': false}),
    );
    await tester.pump();
    final Switch toggle = tester.widget<Switch>(
      find.descendant(
        of: find.ancestor(of: row, matching: find.byType(Row)).first,
        matching: find.byType(Switch),
      ),
    );
    expect(toggle.value, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('宽屏：左侧分组导航 + 右侧当前组，切组只换右栏', (WidgetTester tester) async {
    await pumpPage(tester, size: const Size(1280, 900));

    expect(
      find.byKey(const ValueKey<String>('web_browser_settings.nav')),
      findsOneWidget,
    );
    // 默认落在「通用」：浏览器本身的行在右栏。
    expect(find.text(t.web_browser_tab_style), findsOneWidget);
    // 扩展各组都在左栏（文案来自扩展字典）。
    for (final String key in <String>[
      'opt_group_lookup',
      'opt_group_subtitle',
      'opt_group_subtitle_style',
      'opt_group_appearance',
      'opt_group_shortcut',
      'opt_group_advanced',
    ]) {
      expect(find.text(en[key]!), findsOneWidget, reason: key);
    }

    await tester.tap(find.text(en['opt_group_subtitle_style']!));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));

    expect(find.text(t.web_browser_tab_style), findsNothing);
    expect(
      find.textContaining(en['opt_subtitleStyleFontScale_title']!),
      findsWidgets,
    );
    // 导航仍在：是换右栏，不是推新页。
    expect(
      find.byKey(const ValueKey<String>('web_browser_settings.nav')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏：分组总览列表，点一组下钻到它的设置页', (WidgetTester tester) async {
    await pumpPage(tester, size: const Size(400, 860));

    expect(
      find.byKey(const ValueKey<String>('web_browser_settings.nav')),
      findsNothing,
    );
    expect(find.text(t.web_browser_tab_style), findsNothing);
    final Finder subtitles = find.text(en['opt_group_subtitle']!);
    expect(subtitles, findsOneWidget);

    await tester.tap(subtitles);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));

    expect(find.text(en['opt_subtitleReplaceNative_title']!), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('扩展取值与扩展源码一致', () {
    const String root = '../tools/browser-extension';

    test('开关缺省值 = options.js settingDefaults；没搬的项都登记了原因', () {
      final String src = File('$root/options.js').readAsStringSync();
      final String block = RegExp(
        r'const settingDefaults = Object\.freeze\(\{([\s\S]*?)\n\}\);',
      ).firstMatch(src)!.group(1)!;
      final Map<String, bool> defaults = <String, bool>{
        for (final RegExpMatch m in RegExp(
          r'^\s*([A-Za-z]+): (true|false),',
          multiLine: true,
        ).allMatches(block))
          m.group(1)!: m.group(2) == 'true',
      };
      expect(defaults, isNotEmpty);
      final Map<String, bool?> ours = <String, bool?>{};
      final Set<String> covered = <String>{};
      for (final WebBrowserExtensionSettingsGroup g
          in WebBrowserExtensionSettingsGroup.values) {
        for (final SettingsSection s in g.destination().sections) {
          for (final SettingsItem item in s.items) {
            final String key = item.id.replaceFirst(
              'web_browser.extension.',
              '',
            );
            covered.add(key);
            if (item is SettingsSwitchItem) ours[key] = item.defaultValue;
          }
        }
      }
      for (final MapEntry<String, bool?> e in ours.entries) {
        if (!defaults.containsKey(e.key)) continue;
        // 复合开关（覆盖层 × 总门）没有单一缺省值。
        if (e.key == kWebBrowserExtensionOverlayKey) continue;
        expect(e.value, defaults[e.key], reason: e.key);
      }
      final String omitted = kWebBrowserExtensionOmittedSettings.keys.join(' ');
      for (final String key in defaults.keys) {
        expect(
          covered.contains(key) || omitted.contains(key),
          isTrue,
          reason: '扩展设置 $key 既没搬进 app 也没登记不搬的原因',
        );
      }
    });

    test('字幕样式缺省 / 区间、字体栈、快捷键默认键 = 扩展源码', () {
      final String style = File('$root/subtitle-style.js').readAsStringSync();
      for (final MapEntry<String, Object> e
          in kWebBrowserSubtitleStyleDefaults.entries) {
        final String v = e.value is String ? "'${e.value}'" : '${e.value}';
        expect(style, contains('${e.key}: $v,'), reason: e.key);
      }
      for (final MapEntry<String, (int, int)> e
          in kWebBrowserSubtitleStyleLimits.entries) {
        expect(
          style,
          contains('${e.key}: [${e.value.$1}, ${e.value.$2}]'),
          reason: e.key,
        );
      }
      for (final String f in kWebBrowserSubtitleFontSuggestions) {
        expect(style, contains("'$f'"), reason: f);
      }
      final String shortcuts = File(
        '$root/video-shortcuts.js',
      ).readAsStringSync();
      for (final (String action, String _, String _, String combo)
          in kWebBrowserVideoShortcuts) {
        expect(shortcuts, contains("'$action': '$combo'"), reason: action);
      }
      final String palette = File('$root/theme-palette.js').readAsStringSync();
      for (final (String key, String label)
          in kWebBrowserExtensionPalettePresets) {
        expect(palette, contains("key: '$key'"), reason: key);
        expect(palette, contains("labelKey: '$label'"), reason: label);
      }
    });

    test('字幕样式：规整与扩展同律，回到全默认即删键', () async {
      final _MemoryPrefs prefs = _MemoryPrefs();
      final WebBrowserExtensionStorage storage = WebBrowserExtensionStorage(
        prefs: prefs,
      );
      addTearDown(storage.dispose);
      expect(
        normalizeWebBrowserSubtitleStyle(<String, Object?>{
          'fontScale': 999,
          'boxWidth': 7,
          'boxHeight': 0,
          'fontWeight': 640,
          'textColor': 'ABC',
          'shadow': 'weird',
        }),
        containsPair('fontScale', 300),
      );
      final Map<String, Object> n = normalizeWebBrowserSubtitleStyle(
        <String, Object?>{'boxWidth': 7, 'fontWeight': 640, 'textColor': 'ABC'},
      );
      expect(n['boxWidth'], 20);
      expect(n['fontWeight'], 600);
      expect(n['textColor'], '#aabbcc');

      await writeWebBrowserSubtitleStyleField(storage, 'fontScale', 150);
      expect(
        (storage.get(<String>['subtitleStyle'])['subtitleStyle']!
            as Map)['fontScale'],
        150,
      );
      await writeWebBrowserSubtitleStyleField(storage, 'fontScale', 100);
      expect(storage.get(<String>['subtitleStyle']), isEmpty);
    });

    test('快捷键：录入组合按扩展格式存，改回默认即删项', () async {
      final _MemoryPrefs prefs = _MemoryPrefs();
      final WebBrowserExtensionStorage storage = WebBrowserExtensionStorage(
        prefs: prefs,
      );
      addTearDown(storage.dispose);
      final String combo = webBrowserShortcutComboFromKey(
        PhysicalKeyboardKey.keyJ,
        ctrl: true,
        alt: false,
        shift: true,
      );
      expect(combo, 'Ctrl+Shift+KeyJ');
      expect(formatWebBrowserShortcutCombo(combo), 'Ctrl+Shift+J');
      expect(
        formatWebBrowserShortcutCombo('Ctrl+Shift+BracketLeft'),
        'Ctrl+Shift+[',
      );
      await writeWebBrowserShortcutCombo(storage, 'copy-cue', combo);
      expect(storage.get(<String>['videoShortcutKeys']), <String, Object?>{
        'videoShortcutKeys': <String, Object?>{'copy-cue': 'Ctrl+Shift+KeyJ'},
      });
      expect(
        resolveWebBrowserShortcutCombos(
          storage.get(<String>['videoShortcutKeys'])['videoShortcutKeys'],
        )['copy-cue'],
        'Ctrl+Shift+KeyJ',
      );
      await writeWebBrowserShortcutCombo(
        storage,
        'copy-cue',
        'Ctrl+Shift+KeyZ',
      );
      expect(storage.get(<String>['videoShortcutKeys']), isEmpty);
    });
  });
}

class _MemoryPrefs implements PrefStore {
  final Map<String, dynamic> values = <String, dynamic>{};

  @override
  dynamic getPref(String key, {dynamic defaultValue}) =>
      values.containsKey(key) ? values[key] : defaultValue;

  @override
  Future<void> setPref(String key, dynamic value) async => values[key] = value;
}

class _TestAppModel extends AppModel {
  _TestAppModel() : super(testPlatformServices());

  @override
  Locale get appLocale => const Locale('en', 'US');
}
