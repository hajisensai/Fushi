import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/models/theme_notifier.dart';
import 'package:hibiki/src/utils/app_ui_scale.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_platform.dart';

HibikiDatabase _testDb() {
  return HibikiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

void main() {
  late HibikiDatabase db;
  late ThemeNotifier notifier;

  TextTheme textThemeBuilder() => const TextTheme();

  setUp(() async {
    db = _testDb();
    notifier = ThemeNotifier(db, textThemeBuilder);
    await Future<void>.delayed(Duration.zero);
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    notifier.dispose();
    await db.close();
  });

  group('ThemeNotifier presets', () {
    test('has 6 built-in theme presets', () {
      expect(ThemeNotifier.themePresets.length, 6);
      expect(ThemeNotifier.themePresets.containsKey('light-theme'), true);
      expect(ThemeNotifier.themePresets.containsKey('dark-theme'), true);
    });

    test('themeLabel returns localized labels for known keys', () {
      final label = ThemeNotifier.themeLabel('light-theme');
      expect(label, isNotEmpty);
    });

    test('themeLabel returns raw key for unknown keys', () {
      expect(ThemeNotifier.themeLabel('unknown-key'), 'unknown-key');
    });
  });

  group('ThemeNotifier defaults', () {
    test('default appThemeKey is system-theme', () {
      expect(notifier.appThemeKey, 'system-theme');
    });

    test('default brightnessMode is system', () {
      expect(notifier.brightnessMode, 'system');
    });

    test('default themeMode is system', () {
      expect(notifier.themeMode, ThemeMode.system);
    });

    test('default appUiScale is 100 percent', () {
      expect(notifier.appUiScale, 1.0);
    });

    test('theme returns valid ThemeData', () {
      expect(notifier.theme, isA<ThemeData>());
      expect(notifier.theme.useMaterial3, true);
    });

    test('darkTheme returns valid ThemeData', () {
      expect(notifier.darkTheme, isA<ThemeData>());
      expect(notifier.darkTheme.colorScheme.brightness, Brightness.dark);
    });

    test('default customThemeSeed is teal', () {
      expect(notifier.customThemeSeed, const Color(0xFF1F4959));
    });

    test('custom color prefs default to null', () {
      expect(notifier.customThemeFontColor, isNull);
      expect(notifier.customThemeBackgroundColor, isNull);
      expect(notifier.customThemeSelectionColor, isNull);
      expect(notifier.customThemePrimaryColor, isNull);
      expect(notifier.customThemeSecondaryColor, isNull);
      expect(notifier.customThemeTertiaryColor, isNull);
      expect(notifier.customThemeContainerColor, isNull);
      expect(notifier.customThemeSasayakiColor, isNull);
      expect(notifier.customThemeLinkColor, isNull);
    });
  });

  group('ThemeNotifier setters', () {
    test('setAppThemeKey persists and changes theme', () async {
      int notifyCount = 0;
      notifier.addListener(() => notifyCount++);
      await notifier.setAppThemeKey('dark-theme');
      expect(notifier.appThemeKey, 'dark-theme');
      expect(notifier.brightnessMode, 'dark');
      expect(notifyCount, greaterThan(0));
    });

    test('setBrightnessMode persists and notifies', () async {
      int notifyCount = 0;
      notifier.addListener(() => notifyCount++);
      await notifier.setBrightnessMode('dark');
      expect(notifier.brightnessMode, 'dark');
      expect(notifier.themeMode, ThemeMode.dark);
      expect(notifier.isDarkMode, true);
      expect(notifyCount, 1);
    });

    test('setAppUiScale clamps to 30-300 percent, persists, and notifies',
        () async {
      int notifyCount = 0;
      notifier.addListener(() => notifyCount++);

      await notifier.setAppUiScale(3.5);
      expect(notifier.appUiScale, 3.0);
      expect(notifyCount, 1);

      final ThemeNotifier reloaded = ThemeNotifier(db, textThemeBuilder);
      addTearDown(reloaded.dispose);
      await reloaded.refreshFromDb();
      expect(reloaded.appUiScale, 3.0);

      await notifier.setAppUiScale(0.2);
      expect(notifier.appUiScale, 0.3);
    });

    test('setCustomThemeSeed persists color', () async {
      await notifier.setCustomThemeSeed(const Color(0xFFFF0000));
      expect(notifier.customThemeSeed, const Color(0xFFFF0000));
    });

    test('custom color prefs round-trip through DB', () async {
      await notifier.setCustomThemeFontColor(const Color(0xFFAABBCC));
      expect(notifier.customThemeFontColor, const Color(0xFFAABBCC));

      await notifier.setCustomThemeFontColor(null);
      expect(notifier.customThemeFontColor, isNull);
    });

    test('applyCustomTheme sets all fields at once', () async {
      await notifier.applyCustomTheme(
        seed: const Color(0xFFFF5500),
        brightnessMode: 'dark',
        fontColor: const Color(0xFFFFFFFF),
        primaryColor: const Color(0xFF0000FF),
      );
      expect(notifier.appThemeKey, 'custom-theme');
      expect(notifier.brightnessMode, 'dark');
      expect(notifier.customThemeSeed, const Color(0xFFFF5500));
      expect(notifier.customThemeFontColor, const Color(0xFFFFFFFF));
      expect(notifier.customThemePrimaryColor, const Color(0xFF0000FF));
    });

    test('material design system keeps the real platform', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await notifier.setDesignSystem('material');

      expect(notifier.theme.platform, TargetPlatform.windows);
      expect(notifier.darkTheme.platform, TargetPlatform.windows);
    });
  });

  group('ThemeNotifier.buildColorScheme', () {
    test('builds light scheme', () {
      final cs = notifier.buildColorScheme(Brightness.light);
      expect(cs.brightness, Brightness.light);
    });

    test('builds dark scheme', () {
      final cs = notifier.buildColorScheme(Brightness.dark);
      expect(cs.brightness, Brightness.dark);
    });

    test('custom theme uses custom primary color', () async {
      await notifier.applyCustomTheme(
        seed: const Color(0xFFFF0000),
        brightnessMode: 'light',
        primaryColor: const Color(0xFF00FF00),
      );
      final cs = notifier.buildColorScheme(Brightness.light);
      expect(cs.primary, const Color(0xFF00FF00));
    });
  });

  group('ThemeNotifier.refreshFromDb', () {
    test('picks up externally written prefs', () async {
      await db.setPref('brightness_mode', PrefCodec.encode('dark'));
      await notifier.refreshFromDb();
      expect(notifier.brightnessMode, 'dark');
    });
  });

  group('buildHibikiColorScheme', () {
    test('returns base scheme when no overrides', () {
      final cs = buildHibikiColorScheme(
        seedColor: const Color(0xFF1F4959),
        brightness: Brightness.light,
      );
      expect(cs.brightness, Brightness.light);
    });

    test('applies primary override', () {
      final cs = buildHibikiColorScheme(
        seedColor: const Color(0xFF1F4959),
        brightness: Brightness.light,
        primary: const Color(0xFF00FF00),
      );
      expect(cs.primary, const Color(0xFF00FF00));
    });

    test('applies secondary with derived container', () {
      final cs = buildHibikiColorScheme(
        seedColor: const Color(0xFF1F4959),
        brightness: Brightness.light,
        secondary: const Color(0xFFFF0000),
      );
      expect(cs.secondary, const Color(0xFFFF0000));
      expect(cs.secondaryContainer, isNot(equals(cs.secondary)));
    });
  });

  group('ThemeNotifier.designSystemTheme reflects design_system pref', () {
    test(
        'design_system=cupertino → designSystemTheme is cupertino and is '
        'injected into ThemeData.extensions', () {
      notifier.loadFromPrefsSnapshot(<String, String>{
        'design_system': PrefCodec.encode('cupertino'),
      });

      expect(notifier.designSystem, 'cupertino');
      expect(notifier.designSystemTheme, HibikiDesignSystem.cupertino);

      final HibikiDesignSystemTheme? lightExt =
          notifier.theme.extension<HibikiDesignSystemTheme>();
      expect(lightExt, isNotNull);
      expect(lightExt!.designSystem, HibikiDesignSystem.cupertino);

      final HibikiDesignSystemTheme? darkExt =
          notifier.darkTheme.extension<HibikiDesignSystemTheme>();
      expect(darkExt, isNotNull);
      expect(darkExt!.designSystem, HibikiDesignSystem.cupertino);
    });

    test('design_system=material → designSystemTheme is material', () {
      notifier.loadFromPrefsSnapshot(<String, String>{
        'design_system': PrefCodec.encode('material'),
      });

      expect(notifier.designSystem, 'material');
      expect(notifier.designSystemTheme, HibikiDesignSystem.material);
      expect(
        notifier.theme.extension<HibikiDesignSystemTheme>()!.designSystem,
        HibikiDesignSystem.material,
      );
    });

    test('absent design_system → defaults to auto', () {
      notifier.loadFromPrefsSnapshot(<String, String>{});

      expect(notifier.designSystem, 'auto');
      expect(notifier.designSystemTheme, HibikiDesignSystem.auto);
      expect(
        notifier.theme.extension<HibikiDesignSystemTheme>()!.designSystem,
        HibikiDesignSystem.auto,
      );
    });

    test('explicit design_system=auto → designSystemTheme is auto', () {
      notifier.loadFromPrefsSnapshot(<String, String>{
        'design_system': PrefCodec.encode('auto'),
      });

      expect(notifier.designSystem, 'auto');
      expect(notifier.designSystemTheme, HibikiDesignSystem.auto);
    });

    test('unknown design_system value → falls through to auto', () {
      notifier.loadFromPrefsSnapshot(<String, String>{
        'design_system': PrefCodec.encode('fluent'),
      });

      expect(notifier.designSystem, 'fluent');
      expect(notifier.designSystemTheme, HibikiDesignSystem.auto);
    });
  });

  group('ThemeNotifier.appUiScale reflects app_ui_scale pref', () {
    test('app_ui_scale=1.5 → appUiScale is the in-range normalized value', () {
      notifier.loadFromPrefsSnapshot(<String, String>{
        'app_ui_scale': PrefCodec.encode(1.5),
      });

      expect(notifier.appUiScale, 1.5);
      expect(notifier.appUiScale, HibikiAppUiScale.normalize(1.5));
    });

    test('out-of-range app_ui_scale=5.0 → clamped to maxScale (3.0)', () {
      notifier.loadFromPrefsSnapshot(<String, String>{
        'app_ui_scale': PrefCodec.encode(5.0),
      });

      expect(HibikiAppUiScale.maxScale, 3.0);
      expect(notifier.appUiScale, HibikiAppUiScale.maxScale);
      expect(notifier.appUiScale, 3.0);
    });

    test('below-range app_ui_scale=0.1 → clamped to minScale (0.3)', () {
      notifier.loadFromPrefsSnapshot(<String, String>{
        'app_ui_scale': PrefCodec.encode(0.1),
      });

      expect(HibikiAppUiScale.minScale, 0.3);
      expect(notifier.appUiScale, HibikiAppUiScale.minScale);
      expect(notifier.appUiScale, 0.3);
    });

    test('absent app_ui_scale → defaults to defaultScale (1.0)', () {
      notifier.loadFromPrefsSnapshot(<String, String>{});

      expect(HibikiAppUiScale.defaultScale, 1.0);
      expect(notifier.appUiScale, HibikiAppUiScale.defaultScale);
      expect(notifier.appUiScale, 1.0);
    });

    test('app_ui_scale stored as int → still normalized as double', () {
      notifier.loadFromPrefsSnapshot(<String, String>{
        'app_ui_scale': PrefCodec.encode(2),
      });

      expect(notifier.appUiScale, 2.0);
    });
  });
}
