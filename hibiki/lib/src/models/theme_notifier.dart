import 'dart:io';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:material_color_utilities/material_color_utilities.dart';

import 'package:hibiki/src/models/app_model.dart';

Color _readableOnColor(Color color) {
  return ThemeData.estimateBrightnessForColor(color) == Brightness.dark
      ? Colors.white
      : Colors.black;
}

Color _deriveContainer(Color role, Brightness brightness) {
  final Color target =
      brightness == Brightness.dark ? Colors.black : Colors.white;
  return Color.lerp(role, target, brightness == Brightness.dark ? 0.7 : 0.85)!;
}

ColorScheme buildHibikiColorScheme({
  required Color seedColor,
  required Brightness brightness,
  Color? primary,
  Color? secondary,
  Color? tertiary,
  Color? primaryContainer,
}) {
  final ColorScheme base = ColorScheme.fromSeed(
    seedColor: seedColor,
    brightness: brightness,
  );
  final Color? secContainer =
      secondary != null ? _deriveContainer(secondary, brightness) : null;
  final Color? terContainer =
      tertiary != null ? _deriveContainer(tertiary, brightness) : null;
  return base.copyWith(
    primary: primary ?? base.primary,
    onPrimary: primary != null ? _readableOnColor(primary) : base.onPrimary,
    secondary: secondary ?? base.secondary,
    onSecondary:
        secondary != null ? _readableOnColor(secondary) : base.onSecondary,
    secondaryContainer: secContainer ?? base.secondaryContainer,
    onSecondaryContainer: secContainer != null
        ? _readableOnColor(secContainer)
        : base.onSecondaryContainer,
    tertiary: tertiary ?? base.tertiary,
    onTertiary: tertiary != null ? _readableOnColor(tertiary) : base.onTertiary,
    tertiaryContainer: terContainer ?? base.tertiaryContainer,
    onTertiaryContainer: terContainer != null
        ? _readableOnColor(terContainer)
        : base.onTertiaryContainer,
    primaryContainer: primaryContainer ?? base.primaryContainer,
    onPrimaryContainer: primaryContainer != null
        ? _readableOnColor(primaryContainer)
        : base.onPrimaryContainer,
  );
}

class ThemeNotifier extends ChangeNotifier {
  ThemeNotifier(this._db, this._textThemeBuilder);

  final HibikiDatabase _db;
  final TextTheme Function() _textThemeBuilder;
  final Map<String, String> _prefs = {};

  CorePalette? _systemPalette;

  Color? get systemPrimaryColor =>
      _systemPalette != null ? Color(_systemPalette!.primary.get(40)) : null;

  Future<void> refreshSystemPalette() async {
    try {
      _systemPalette = await DynamicColorPlugin.getCorePalette();
    } catch (_) {
      _systemPalette = null;
    }
    if (appThemeKey == 'system-theme') notifyListeners();
  }

  void loadFromPrefsSnapshot(Map<String, String> snapshot) {
    _prefs
      ..clear()
      ..addAll(snapshot);
  }

  Future<void> refreshFromDb() async {
    final all = await _db.getAllPrefs();
    _prefs
      ..clear()
      ..addAll(all);
    notifyListeners();
  }

  dynamic _get(String key, {dynamic defaultValue}) {
    final raw = _prefs[key];
    if (raw == null) {
      if (defaultValue != null) _set(key, defaultValue);
      return defaultValue;
    }
    return PrefCodec.decode(raw, defaultValue);
  }

  Future<void> _set(String key, dynamic value) async {
    final String strVal = PrefCodec.encode(value);
    _prefs[key] = strVal;
    await _db.setPref(key, strVal);
  }

  // ── Theme presets ──────────────────────────────────────────────────

  static const Map<String, ({Color seed, Brightness brightness})> themePresets =
      {
    'light-theme': (seed: Color(0xFF1F4959), brightness: Brightness.light),
    'ecru-theme': (seed: Color(0xFF8B7355), brightness: Brightness.light),
    'water-theme': (seed: Color(0xFF4A7C8F), brightness: Brightness.light),
    'gray-theme': (seed: Color(0xFF5C6B73), brightness: Brightness.dark),
    'dark-theme': (seed: Color(0xFF1F4959), brightness: Brightness.dark),
    'black-theme': (seed: Color(0xFF263238), brightness: Brightness.dark),
  };

  static const _themeLabelKeys = {
    'light-theme': 'theme_light',
    'ecru-theme': 'theme_ecru',
    'water-theme': 'theme_water',
    'gray-theme': 'theme_gray',
    'dark-theme': 'theme_dark',
    'black-theme': 'theme_black',
  };

  static String themeLabel(String key) {
    switch (_themeLabelKeys[key]) {
      case 'theme_light':
        return t.theme_light;
      case 'theme_ecru':
        return t.theme_ecru;
      case 'theme_water':
        return t.theme_water;
      case 'theme_gray':
        return t.theme_gray;
      case 'theme_dark':
        return t.theme_dark;
      case 'theme_black':
        return t.theme_black;
      default:
        return key;
    }
  }

  // ── Theme getters ────────────────────────────────────────────────

  String get appThemeKey {
    final String key = _get('app_theme_key', defaultValue: '');
    if (key.isEmpty ||
        (!themePresets.containsKey(key) &&
            key != 'custom-theme' &&
            key != 'system-theme')) {
      return 'system-theme';
    }
    return key;
  }

  String get brightnessMode {
    final String mode = _get('brightness_mode', defaultValue: '');
    if (mode.isNotEmpty) return mode;
    final key = appThemeKey;
    if (key == 'system-theme') return 'system';
    if (key == 'custom-theme') return customThemeDark ? 'dark' : 'light';
    final preset = themePresets[key];
    if (preset != null) {
      return preset.brightness == Brightness.dark ? 'dark' : 'light';
    }
    return 'system';
  }

  // ── Design system override ────────────────────────────────────────

  String get designSystem => _get('design_system', defaultValue: 'auto');

  Future<void> setDesignSystem(String value) async {
    await _set('design_system', value);
    notifyListeners();
  }

  TargetPlatform? get _overridePlatform {
    switch (designSystem) {
      case 'material':
        return TargetPlatform.android;
      case 'cupertino':
        return TargetPlatform.iOS;
      default:
        return null;
    }
  }

  bool get isDarkMode {
    switch (brightnessMode) {
      case 'light':
        return false;
      case 'dark':
        return true;
      default:
        return WidgetsBinding.instance.platformDispatcher.platformBrightness ==
            Brightness.dark;
    }
  }

  ThemeMode get themeMode {
    switch (brightnessMode) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  Color get _seedColor {
    if (appThemeKey == 'custom-theme') return customThemeSeed;
    return themePresets[appThemeKey]?.seed ?? const Color(0xFF1F4959);
  }

  ThemeData get theme => _buildThemeData(Brightness.light);
  ThemeData get darkTheme => _buildThemeData(Brightness.dark);

  ColorScheme buildColorScheme(Brightness brightness) {
    if (appThemeKey == 'system-theme' && _systemPalette != null) {
      return _systemPalette!.toColorScheme(brightness: brightness);
    }
    final bool useCustomRoles = appThemeKey == 'custom-theme';
    return buildHibikiColorScheme(
      seedColor: _seedColor,
      brightness: brightness,
      primary: useCustomRoles ? customThemePrimaryColor : null,
      secondary: useCustomRoles ? customThemeSecondaryColor : null,
      tertiary: useCustomRoles ? customThemeTertiaryColor : null,
      primaryContainer: useCustomRoles ? customThemeContainerColor : null,
    );
  }

  ThemeData _buildThemeData(Brightness brightness) {
    final cs = buildColorScheme(brightness);
    final TextTheme tt = _textThemeBuilder();
    return ThemeData(
      useMaterial3: true,
      platform: _overridePlatform,
      colorScheme: cs,
      textTheme: tt,
      appBarTheme: const AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 3.0,
        centerTitle: false,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateColor.resolveWith((states) {
          return states.contains(WidgetState.selected)
              ? cs.primary
              : cs.onSurfaceVariant;
        }),
        trackColor: WidgetStateColor.resolveWith((states) {
          return states.contains(WidgetState.selected)
              ? cs.primaryContainer
              : cs.surfaceContainerHighest;
        }),
        trackOutlineColor: WidgetStateColor.resolveWith((states) {
          return states.contains(WidgetState.selected)
              ? Colors.transparent
              : cs.outline;
        }),
      ),
      navigationBarTheme: NavigationBarThemeData(
        elevation: 0,
        labelTextStyle: WidgetStateProperty.all(tt.labelSmall),
      ),
      popupMenuTheme: PopupMenuThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
        ),
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      listTileTheme: const ListTileThemeData(),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(
          borderSide: BorderSide(color: cs.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: cs.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: cs.primary, width: 2),
        ),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness:
            brightness == Brightness.light ? WidgetStateProperty.all(3) : null,
        thumbVisibility: WidgetStateProperty.all(true),
      ),
      sliderTheme: SliderThemeData(
        thumbColor: cs.primary,
        activeTrackColor: cs.primary,
        inactiveTrackColor: cs.outlineVariant,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    );
  }

  // ── Custom theme prefs ─────────────────────────────────────────────

  Color get customThemeSeed {
    final int v = _get('custom_theme_seed', defaultValue: 0xFF1F4959);
    return Color(v);
  }

  Future<void> setCustomThemeSeed(Color color) async {
    await _set('custom_theme_seed', color.toARGB32());
  }

  bool get customThemeDark =>
      _get('custom_theme_dark', defaultValue: false) as bool;

  Future<void> setCustomThemeDark(bool dark) async {
    await _set('custom_theme_dark', dark);
  }

  Color? get customThemeFontColor => _colorPref('custom_theme_font_color');
  Future<void> setCustomThemeFontColor(Color? c) =>
      _setColorPref('custom_theme_font_color', c);

  Color? get customThemeBackgroundColor => _colorPref('custom_theme_bg_color');
  Future<void> setCustomThemeBackgroundColor(Color? c) =>
      _setColorPref('custom_theme_bg_color', c);

  Color? get customThemeSelectionColor =>
      _colorPref('custom_theme_selection_color');
  Future<void> setCustomThemeSelectionColor(Color? c) =>
      _setColorPref('custom_theme_selection_color', c);

  Color? get customThemePrimaryColor =>
      _colorPref('custom_theme_primary_color');
  Future<void> setCustomThemePrimaryColor(Color? c) =>
      _setColorPref('custom_theme_primary_color', c);

  Color? get customThemeSecondaryColor =>
      _colorPref('custom_theme_secondary_color');
  Future<void> setCustomThemeSecondaryColor(Color? c) =>
      _setColorPref('custom_theme_secondary_color', c);

  Color? get customThemeTertiaryColor =>
      _colorPref('custom_theme_tertiary_color');
  Future<void> setCustomThemeTertiaryColor(Color? c) =>
      _setColorPref('custom_theme_tertiary_color', c);

  Color? get customThemeContainerColor =>
      _colorPref('custom_theme_container_color');
  Future<void> setCustomThemeContainerColor(Color? c) =>
      _setColorPref('custom_theme_container_color', c);

  Color? get customThemeSasayakiColor =>
      _colorPref('custom_theme_sasayaki_color');
  Future<void> setCustomThemeSasayakiColor(Color? c) =>
      _setColorPref('custom_theme_sasayaki_color', c);

  Color? get customThemeLinkColor => _colorPref('custom_theme_link_color');
  Future<void> setCustomThemeLinkColor(Color? c) =>
      _setColorPref('custom_theme_link_color', c);

  Color? _colorPref(String key) {
    final int v = _get(key, defaultValue: 0);
    if (v == 0) return null;
    return Color(v);
  }

  Future<void> _setColorPref(String key, Color? color) async {
    await _set(key, color?.toARGB32() ?? 0);
  }

  // ── Setters ───────────────────────────────────────────────────────

  Future<void> setAppThemeKey(String key) async {
    await _set('app_theme_key', key);
    if (key == 'system-theme') {
      await setBrightnessMode('system');
      return;
    }
    final preset = themePresets[key];
    if (preset != null) {
      await setBrightnessMode(
          preset.brightness == Brightness.dark ? 'dark' : 'light');
      return;
    }
    notifyListeners();
    _persistSplashColor();
  }

  Future<void> setBrightnessMode(String mode) async {
    await _set('brightness_mode', mode);
    notifyListeners();
    _persistSplashColor();
  }

  Future<void> applyCustomTheme({
    required Color seed,
    required String brightnessMode,
    Color? fontColor,
    Color? backgroundColor,
    Color? selectionColor,
    Color? primaryColor,
    Color? secondaryColor,
    Color? tertiaryColor,
    Color? containerColor,
    Color? sasayakiColor,
    Color? linkColor,
  }) async {
    await setCustomThemeSeed(seed);
    await setCustomThemeDark(brightnessMode == 'dark');
    await setCustomThemeFontColor(fontColor);
    await setCustomThemeBackgroundColor(backgroundColor);
    await setCustomThemeSelectionColor(selectionColor);
    await setCustomThemePrimaryColor(primaryColor);
    await setCustomThemeSecondaryColor(secondaryColor);
    await setCustomThemeTertiaryColor(tertiaryColor);
    await setCustomThemeContainerColor(containerColor);
    await setCustomThemeSasayakiColor(sasayakiColor);
    await setCustomThemeLinkColor(linkColor);
    await _set('app_theme_key', 'custom-theme');
    await setBrightnessMode(brightnessMode);
  }

  // ── Splash ────────────────────────────────────────────────────────

  static const _splashChannel = HibikiChannels.splash;

  void _persistSplashColor() {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    final brightness = isDarkMode ? Brightness.dark : Brightness.light;
    final surface = buildColorScheme(brightness).surface;
    _splashChannel.invokeMethod('setSplashColor', {
      'color': surface.toARGB32(),
      'isDark': isDarkMode,
    }).catchError((_) {});
  }
}

final themeProvider = ChangeNotifierProvider<ThemeNotifier>((ref) {
  final appModel = ref.watch(appProvider);
  return appModel.themeNotifier;
});
