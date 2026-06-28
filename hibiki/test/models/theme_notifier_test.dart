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

    test('each preset carries a scheme variant', () {
      for (final entry in ThemeNotifier.themePresets.entries) {
        expect(
          entry.value.variant,
          isA<DynamicSchemeVariant>(),
          reason: '${entry.key} 缺少 scheme variant 字段',
        );
      }
    });

    test('the three dark presets declare distinct variants (TODO-100)', () {
      expect(
        ThemeNotifier.themePresets['gray-theme']!.variant,
        DynamicSchemeVariant.neutral,
      );
      expect(
        ThemeNotifier.themePresets['dark-theme']!.variant,
        DynamicSchemeVariant.tonalSpot,
      );
      expect(
        ThemeNotifier.themePresets['black-theme']!.variant,
        DynamicSchemeVariant.vibrant,
      );
    });
  });

  group('ThemeNotifier dark preset distinctness (TODO-100)', () {
    // 用户报「三个暗色主题选择时完全看不出差别」：旧实现三个暗色预设经
    // tonalSpot 全部塌成同一套青色(#8bd0ef)+近黑背景。按预设各自的 variant
    // 应用后，primary 与 surface 必须各不相同，主题切换才看得出差别。撤掉
    // variant 接线(buildColorScheme 不传 _variant)本组立即转红。
    Future<ColorScheme> appliedScheme(String key) async {
      await notifier.setAppThemeKey(key);
      return notifier.buildColorScheme(Brightness.dark);
    }

    test('gray / dark / black applied schemes have distinct primary + surface',
        () async {
      final ColorScheme gray = await appliedScheme('gray-theme');
      final ColorScheme dark = await appliedScheme('dark-theme');
      final ColorScheme black = await appliedScheme('black-theme');

      expect(gray.primary, isNot(dark.primary));
      expect(dark.primary, isNot(black.primary));
      expect(gray.primary, isNot(black.primary));

      expect(gray.surface, isNot(black.surface));
      expect(dark.surface, isNot(black.surface));
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

    test('default appUiScale is 100 percent before a viewport is resolved', () {
      // TODO-374: 无任何持久值（首启）时，种子尚未发生，appUiScale 退回当前自动值
      // （视口未解析前 autoAppUiScale 默认 1.0）。
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

    test(
        'setAppUiScale persists a concrete value, clamps to 30-300 percent, '
        'and notifies', () async {
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

    test(
        'TODO-374: first launch seeds a suitable concrete scale and persists it',
        () async {
      // 首启：无任何持久值。第一次按真实视口解析时把合适值落盘成具体百分比。
      final double seeded = notifier.resolveAppUiScaleForViewport(
        viewport: const Size(1920, 1080),
        platform: TargetPlatform.windows,
      );
      expect(seeded, greaterThan(1.0), reason: '大屏的合适值应放大');
      // 同帧 appUiScale 立刻返回种子值（内存已写）。
      expect(notifier.appUiScale, seeded);

      // 落盘后重载也是同一具体值，不再随视口变化（已是用户可调的具体数值）。
      await Future<void>.delayed(Duration.zero);
      final ThemeNotifier reloaded = ThemeNotifier(db, textThemeBuilder);
      addTearDown(reloaded.dispose);
      await reloaded.refreshFromDb();
      expect(reloaded.customAppUiScale, seeded);

      final double afterResize = reloaded.resolveAppUiScaleForViewport(
        viewport: const Size(800, 600),
        platform: TargetPlatform.windows,
      );
      expect(afterResize, seeded, reason: '种子后界面大小是固定具体值，不随窗口大小自动改变');
    });

    test('TODO-374: an explicit user value is never overwritten by reseed',
        () async {
      await notifier.setAppUiScale(1.7);
      expect(notifier.appUiScale, 1.7);

      final double resolved = notifier.resolveAppUiScaleForViewport(
        viewport: const Size(800, 600),
        platform: TargetPlatform.windows,
      );
      expect(resolved, 1.7, reason: '已有具体值的用户不被重新种子覆盖');
      expect(notifier.autoAppUiScale, lessThan(1.0));
      expect(notifier.customAppUiScale, 1.7);
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
      // TODO-928: applyCustomTheme 不再带 brightnessMode 参数，也不写 brightness_mode。
      // 切到自定义保留当前全局明暗：先把全局设深色，应用自定义后仍是深色。
      await notifier.setBrightnessMode('dark');
      await notifier.applyCustomTheme(
        seed: const Color(0xFFFF5500),
        fontColor: const Color(0xFFFFFFFF),
        primaryColor: const Color(0xFF0000FF),
      );
      expect(notifier.appThemeKey, 'custom-theme');
      expect(notifier.brightnessMode, 'dark');
      expect(notifier.customThemeSeed, const Color(0xFFFF5500));
      expect(notifier.customThemeFontColor, const Color(0xFFFFFFFF));
      expect(notifier.customThemePrimaryColor, const Color(0xFF0000FF));
    });

    group('TODO-928 · 自定义主题跟随当前全局明暗', () {
      test('切到自定义不改 brightness_mode：当前深色态保持深色', () async {
        await notifier.setBrightnessMode('dark');
        await notifier.applyCustomTheme(seed: const Color(0xFFFF5500));
        expect(notifier.appThemeKey, 'custom-theme');
        expect(notifier.brightnessMode, 'dark');
        expect(notifier.themeMode, ThemeMode.dark);
        expect(notifier.isDarkMode, isTrue);
      });

      test('当前浅色态切自定义保持浅色', () async {
        await notifier.setBrightnessMode('light');
        await notifier.applyCustomTheme(seed: const Color(0xFFFF5500));
        expect(notifier.appThemeKey, 'custom-theme');
        expect(notifier.brightnessMode, 'light');
        expect(notifier.themeMode, ThemeMode.light);
        expect(notifier.isDarkMode, isFalse);
      });

      test('applyCustomTheme 不再写 custom_theme_dark（停止产生第二真值）', () async {
        await notifier.setBrightnessMode('light');
        await notifier.applyCustomTheme(seed: const Color(0xFFFF5500));
        // 未显式写过 custom_theme_dark，getter 仍是默认 false（只读兜底未被污染）。
        expect(notifier.customThemeDark, isFalse);
      });

      test('向后兼容：老深色自定义用户（brightness_mode=dark 已存）不回归明暗', () async {
        // 模拟老用户：历史 applyCustomTheme 双写过 brightness_mode 与 custom_theme_dark。
        await db.setPref('brightness_mode', PrefCodec.encode('dark'));
        await db.setPref('custom_theme_dark', PrefCodec.encode(true));
        await db.setPref('app_theme_key', PrefCodec.encode('custom-theme'));
        await notifier.refreshFromDb();
        expect(notifier.appThemeKey, 'custom-theme');
        expect(notifier.brightnessMode, 'dark');
        expect(notifier.isDarkMode, isTrue);
      });

      test('只读兜底：仅有 custom_theme_dark、无 brightness_mode 时仍判深色', () async {
        // 理论历史路径只写过 custom_theme_dark：brightnessMode 的 custom 回退（:260）
        // 继续读 customThemeDark 作纯兜底，老用户零回归。
        await db.setPref('custom_theme_dark', PrefCodec.encode(true));
        await db.setPref('app_theme_key', PrefCodec.encode('custom-theme'));
        await notifier.refreshFromDb();
        expect(notifier.brightnessMode, 'dark');
        expect(notifier.isDarkMode, isTrue);
      });
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

    test('absent app_ui_scale → defaults to defaultScale (1.0) before seeding',
        () {
      notifier.loadFromPrefsSnapshot(<String, String>{});

      expect(HibikiAppUiScale.defaultScale, 1.0);
      // 种子前（无视口解析）退回当前自动值，默认 1.0。
      expect(notifier.appUiScale, HibikiAppUiScale.defaultScale);
      expect(notifier.appUiScale, 1.0);
    });

    test('legacy app_ui_scale without mode is a concrete value (no reseed)',
        () {
      // 旧 custom 用户（只存过 app_ui_scale，无模式键）：视为已种子，值保留不变。
      notifier.loadFromPrefsSnapshot(<String, String>{
        'app_ui_scale': PrefCodec.encode(1.5),
      });

      expect(notifier.customAppUiScale, 1.5);
      expect(notifier.appUiScale, 1.5);

      final double resolved = notifier.resolveAppUiScaleForViewport(
        viewport: const Size(800, 600),
        platform: TargetPlatform.windows,
      );
      expect(resolved, 1.5, reason: 'legacy custom scale must stay effective');
      expect(notifier.autoAppUiScale, lessThan(1.0));
    });

    test('app_ui_scale stored as int → still normalized as double', () {
      notifier.loadFromPrefsSnapshot(<String, String>{
        'app_ui_scale': PrefCodec.encode(2),
      });

      expect(notifier.appUiScale, 2.0);
    });

    test(
        'TODO-374: legacy auto mode is reseeded from viewport on first resolve',
        () async {
      // 旧 auto 用户：模式键为 auto，存的 app_ui_scale 是被忽略的陈旧值。
      // 种子前视为未种子，appUiScale 退回自动值，不用那个陈旧值。
      notifier.loadFromPrefsSnapshot(<String, String>{
        'app_ui_scale_mode': PrefCodec.encode(ThemeNotifier.appUiScaleModeAuto),
        'app_ui_scale': PrefCodec.encode(2),
      });
      expect(notifier.appUiScale, HibikiAppUiScale.defaultScale,
          reason: '种子前旧 auto 用户不使用陈旧的 app_ui_scale 值');

      // 首次按真实视口解析：算出合适值并落盘成具体数值，覆盖陈旧值。
      final double seeded = notifier.resolveAppUiScaleForViewport(
        viewport: const Size(1920, 1080),
        platform: TargetPlatform.windows,
      );
      expect(seeded, greaterThan(1.0));
      expect(notifier.appUiScale, seeded);
      expect(notifier.appUiScale, isNot(2.0),
          reason: '旧 auto 用户被重新种子成当时屏幕的合适值，等价其原本看到的 auto 效果');

      // 让 fire-and-forget 的种子落盘完成，避免其在 tearDown 关库后才命中（测试侧时序）。
      await Future<void>.delayed(Duration.zero);
    });
  });
}
