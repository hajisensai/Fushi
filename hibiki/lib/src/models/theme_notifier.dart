import 'dart:async';
import 'dart:io';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_platform.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:material_color_utilities/material_color_utilities.dart';

import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/utils/app_ui_scale.dart';

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

/// Resolve the `system-theme` [ColorScheme] from whatever the OS actually
/// exposed.
///
/// `DynamicColorPlugin.getCorePalette()` only returns a non-null [palette] on
/// Android (it reads `@android:color/system_*`). On Windows / macOS / Linux it
/// is always null, and the OS theme color is instead exposed through
/// `getAccentColor()`. The canonical dynamic_color path (see its own
/// `DynamicColorBuilder`) is therefore: prefer the full [palette]; otherwise
/// seed from the OS [accent]; and only when the OS exposes neither, fall back
/// to [fallbackSeed]. Missing this [accent] branch is exactly why `system-theme`
/// never followed the Windows accent color at startup (BUG-090).
ColorScheme buildSystemThemeColorScheme({
  required Brightness brightness,
  required Color fallbackSeed,
  CorePalette? palette,
  Color? accent,
}) {
  if (palette != null) {
    return palette.toColorScheme(brightness: brightness);
  }
  return ColorScheme.fromSeed(
    seedColor: accent ?? fallbackSeed,
    brightness: brightness,
  );
}

ColorScheme buildHibikiColorScheme({
  required Color seedColor,
  required Brightness brightness,
  DynamicSchemeVariant variant = DynamicSchemeVariant.tonalSpot,
  Color? primary,
  Color? secondary,
  Color? tertiary,
  Color? primaryContainer,
}) {
  final ColorScheme base = ColorScheme.fromSeed(
    seedColor: seedColor,
    brightness: brightness,
    dynamicSchemeVariant: variant,
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

  static const String appUiScaleModeAuto = 'auto';
  static const String appUiScaleModeCustom = 'custom';

  final HibikiDatabase _db;
  final TextTheme Function() _textThemeBuilder;
  final Map<String, String> _prefs = {};
  double _autoAppUiScale = HibikiAppUiScale.defaultScale;

  CorePalette? _systemPalette;
  // OS accent color, the only system-color signal Windows / macOS / Linux
  // expose (getCorePalette is Android-only there). Used to seed `system-theme`
  // when [_systemPalette] is null (BUG-090).
  Color? _systemAccentColor;

  Color? get systemPrimaryColor {
    if (_systemPalette != null) return Color(_systemPalette!.primary.get(40));
    return _systemAccentColor;
  }

  Future<void> refreshSystemPalette() async {
    CorePalette? palette;
    try {
      palette = await DynamicColorPlugin.getCorePalette();
    } catch (_) {
      palette = null;
    }
    // Android yields a full palette; elsewhere it is null, so fall back to the
    // OS accent color (the canonical dynamic_color path).
    Color? accent;
    if (palette == null) {
      try {
        accent = await DynamicColorPlugin.getAccentColor();
      } catch (_) {
        accent = null;
      }
    }
    _systemPalette = palette;
    _systemAccentColor = accent;
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

  // Pure read. Theme getters (theme/darkTheme/themeMode) run inside
  // MaterialApp.build(); previously an absent key triggered a fire-and-forget
  // DB write (_set) from the getter, a side effect on every first build
  // (HBK-AUDIT-022). Defaults are returned without persisting; a value is only
  // written when explicitly set via a setter.
  dynamic _get(String key, {dynamic defaultValue}) {
    final raw = _prefs[key];
    if (raw == null) return defaultValue;
    return PrefCodec.decode(raw, defaultValue);
  }

  Future<void> _set(String key, dynamic value) async {
    final String strVal = PrefCodec.encode(value);
    _prefs[key] = strVal;
    await _db.setPref(key, strVal);
  }

  // ── Theme presets ──────────────────────────────────────────────────

  static const Map<String,
          ({Color seed, Brightness brightness, DynamicSchemeVariant variant})>
      themePresets = {
    'light-theme': (
      seed: Color(0xFF1F4959),
      brightness: Brightness.light,
      variant: DynamicSchemeVariant.tonalSpot,
    ),
    'ecru-theme': (
      seed: Color(0xFF8B7355),
      brightness: Brightness.light,
      variant: DynamicSchemeVariant.tonalSpot,
    ),
    'water-theme': (
      seed: Color(0xFF4A7C8F),
      brightness: Brightness.light,
      variant: DynamicSchemeVariant.tonalSpot,
    ),
    // The three dark presets share near-identical tonalSpot output (all collapse
    // to teal #8bd0ef on near-black), so each gets a distinct M3 scheme variant
    // to stay visibly apart (TODO-100):
    'gray-theme': (
      // Neutral: a real neutral-grey primary (~#bac9d1), no teal cast.
      seed: Color(0xFF5C6B73),
      brightness: Brightness.dark,
      variant: DynamicSchemeVariant.neutral,
    ),
    'dark-theme': (
      // TonalSpot: the teal Hibiki brand colour (~#8ad0ee).
      seed: Color(0xFF1F4959),
      brightness: Brightness.dark,
      variant: DynamicSchemeVariant.tonalSpot,
    ),
    'black-theme': (
      // Vibrant indigo: blue-violet primary (~#bac3ff) on a blue-tinted surface;
      // seed bumped to indigo so vibrant has a hue to express.
      seed: Color(0xFF3F51B5),
      brightness: Brightness.dark,
      variant: DynamicSchemeVariant.vibrant,
    ),
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

  HibikiDesignSystem get designSystemTheme {
    switch (designSystem) {
      case 'material':
        return HibikiDesignSystem.material;
      case 'cupertino':
        return HibikiDesignSystem.cupertino;
      default:
        return HibikiDesignSystem.auto;
    }
  }

  static String normalizeAppUiScaleMode(String value) {
    return value == appUiScaleModeCustom
        ? appUiScaleModeCustom
        : appUiScaleModeAuto;
  }

  // TODO-374: 界面大小不再有「自动/自定义」模式开关，只有一个用户可拖的具体百分比
  // （持久值 `app_ui_scale`）。
  //
  // 「是否已经把合适值落盘」的判据是 [_isAppUiScaleSeeded]：只要存在一个非旧 auto
  // 模式下的 `app_ui_scale` 持久值，就认定用户面对的是一个具体可调数值，永不再自动
  // 改写它。首启（或旧 auto 用户首次进入）则由 [resolveAppUiScaleForViewport] 用当时
  // 视口算出的合适值落盘成 `app_ui_scale`，等价于他们原本看到的 auto 效果，不突变。
  //
  // 向后兼容（Never break userspace）：
  // - 旧 custom 用户（`app_ui_scale_mode='custom'` 或 legacy 只存过 `app_ui_scale`）：
  //   持久值就是他们手动选的值，保持不变、不重新种子。
  // - 旧 auto 用户（`app_ui_scale_mode='auto'`）：当时 auto 忽略任何 `app_ui_scale`
  //   旧值、按视口实时算；首次进入按当时屏幕算出合适值落盘成具体数值，覆盖那个被
  //   忽略的陈旧值（这才等价于他们原本看到的 auto 效果）。
  bool get _isAppUiScaleSeeded {
    if (!_prefs.containsKey('app_ui_scale')) return false;
    // 旧 auto 用户的 app_ui_scale 是被忽略的陈旧值，视为「未种子」，首次进入重算落盘。
    final Object? mode = _get('app_ui_scale_mode');
    if (mode is String && normalizeAppUiScaleMode(mode) == appUiScaleModeAuto) {
      return false;
    }
    return true;
  }

  /// 当前持久化的界面大小（首启种子完成后此即唯一权威值）。
  double get customAppUiScale {
    final Object value = _get(
      'app_ui_scale',
      defaultValue: HibikiAppUiScale.defaultScale,
    );
    if (value is num) return HibikiAppUiScale.normalize(value.toDouble());
    return HibikiAppUiScale.defaultScale;
  }

  /// 最近一次按视口算出的「合适」自动值，仅用作首启种子与种子前的临时显示，不再是
  /// 用户可见的独立模式。
  double get autoAppUiScale => _autoAppUiScale;

  double get appUiScale {
    if (_isAppUiScaleSeeded) return customAppUiScale;
    // 种子前（首启 / 旧 auto 用户尚未拿到视口）：先按已算出的自动值显示，
    // resolveAppUiScaleForViewport 拿到真实视口后会把它落盘成具体数值。
    return autoAppUiScale;
  }

  /// 在拥有真实视口的渲染层调用：算出当时屏幕的「合适」缩放；若界面大小尚未种子
  /// （首启或旧 auto 用户），把该合适值落盘成具体可调的 `app_ui_scale`，此后界面大小
  /// 永远是一个用户可拖的数值。返回当前应生效的 [appUiScale]。
  double resolveAppUiScaleForViewport({
    required Size viewport,
    required TargetPlatform platform,
  }) {
    _autoAppUiScale = HibikiAppUiScale.automaticScaleForViewport(
      viewport: viewport,
      platform: platform,
    );
    if (!_isAppUiScaleSeeded) {
      // 首启种子：把当时屏幕算出的合适值落盘成具体百分比并清掉旧模式键，转为纯具体值。
      // 先同步置内存 _prefs（见 _seedAppUiScale），使本帧 appUiScale 立刻返回种子值。
      unawaited(_seedAppUiScale(_autoAppUiScale));
      return _autoAppUiScale;
    }
    return appUiScale;
  }

  Future<void> _seedAppUiScale(double value) async {
    final double normalized = HibikiAppUiScale.normalize(value);
    // 立刻更新内存值，使同帧 _isAppUiScaleSeeded / appUiScale 反映已种子（_db 写是
    // async，先同步置内存避免本帧/下一帧重复种子）。
    _prefs['app_ui_scale'] = PrefCodec.encode(normalized);
    _prefs.remove('app_ui_scale_mode');
    await _db.setPref('app_ui_scale', PrefCodec.encode(normalized));
    // 清掉旧 auto 模式键，避免下次启动又被判为未种子（旧 auto 用户路径）。
    await _db.deletePref('app_ui_scale_mode');
    notifyListeners();
  }

  Future<void> setAppUiScale(double value) async {
    await _set('app_ui_scale', HibikiAppUiScale.normalize(value));
    // 用户显式拖动即落具体值；清掉任何残留旧模式键，确保此后判为已种子。
    _prefs.remove('app_ui_scale_mode');
    await _db.deletePref('app_ui_scale_mode');
    notifyListeners();
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

  // The M3 scheme variant for the active preset. Presets differ here so the
  // three dark presets (gray/dark/black) stay visually distinct (TODO-100);
  // custom / system fall back to tonalSpot (their own seed/role overrides /
  // OS palette already differentiate them).
  DynamicSchemeVariant get _variant {
    return themePresets[appThemeKey]?.variant ?? DynamicSchemeVariant.tonalSpot;
  }

  ThemeData get theme => _buildThemeData(Brightness.light);
  ThemeData get darkTheme => _buildThemeData(Brightness.dark);

  ColorScheme buildColorScheme(Brightness brightness) {
    if (appThemeKey == 'system-theme') {
      return buildSystemThemeColorScheme(
        brightness: brightness,
        palette: _systemPalette,
        accent: _systemAccentColor,
        fallbackSeed: _seedColor,
      );
    }
    final bool useCustomRoles = appThemeKey == 'custom-theme';
    return buildHibikiColorScheme(
      seedColor: _seedColor,
      brightness: brightness,
      variant: _variant,
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
      colorScheme: cs,
      textTheme: tt,
      extensions: <ThemeExtension<dynamic>>[
        HibikiDesignSystemTheme(designSystemTheme),
      ],
      appBarTheme: const AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      switchTheme: SwitchThemeData(
        thumbIcon: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.selected)
              ? const Icon(Icons.check, size: 14)
              : null;
        }),
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
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        labelTextStyle: WidgetStateProperty.all(tt.labelSmall),
      ),
      popupMenuTheme: PopupMenuThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
        ),
      ),
      listTileTheme: const ListTileThemeData(),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: cs.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: cs.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
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
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: cs.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        showDragHandle: true,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        surfaceTintColor: Colors.transparent,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        elevation: 0,
        highlightElevation: 0,
        backgroundColor: cs.primaryContainer,
        foregroundColor: cs.onPrimaryContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
        side: BorderSide(color: cs.outlineVariant),
        selectedColor: cs.secondaryContainer,
        showCheckmark: false,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: const StadiumBorder(),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: const StadiumBorder(),
          side: BorderSide(color: cs.outline),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: const StadiumBorder(),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: cs.outlineVariant,
        thickness: 0.5,
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

  // TODO-928: 自定义主题不再拥有自己的明暗真值。删掉 `brightnessMode` 参数后，
  // applyCustomTheme 只落 seed + 角色色 + `app_theme_key='custom-theme'`，**不再写**
  // `custom_theme_dark`、**不再写** `brightness_mode`。切到自定义主题保留用户当前的
  // 全局明暗（浅色态切自定义=浅色，深色态=深色），明暗变体由
  // buildHibikiColorScheme(seed, brightness) 在 light/dark 各自从 seed 派生。
  // 想改明暗用全局的 brightness 选择器，自带/自定义一视同仁。
  //
  // 向后兼容（Never break userspace）：老用户历史一直双写过 `brightness_mode`，故其
  // 全局明暗持久值仍在、不回归；`customThemeDark` getter + brightnessMode 的 custom
  // 回退（:260）保留为纯只读兜底，只是不再产生新值。
  Future<void> applyCustomTheme({
    required Color seed,
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
    notifyListeners();
    _persistSplashColor();
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
    }).catchError((Object e) {
      debugPrint('[theme] setSplashColor failed: $e');
    });
  }
}

final themeProvider = ChangeNotifierProvider<ThemeNotifier>((ref) {
  final appModel = ref.watch(appProvider);
  return appModel.themeNotifier;
});
