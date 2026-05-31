import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/models/theme_notifier.dart';

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
}
