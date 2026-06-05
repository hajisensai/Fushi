import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:path/path.dart' as p;

/// All reader display/behavior settings, decoupled from the media source.
///
/// Reads/writes use the same Drift `preferences` table keys as the old
/// `ReaderTtuSource` so existing user settings migrate automatically.
/// Key format: `src:reader_ttu:<shortKey>`.
class ReaderSettings {
  ReaderSettings(this._db);

  final HibikiDatabase _db;
  final Map<String, dynamic> _cache = <String, dynamic>{};

  static const String _prefix = 'src:reader_ttu:';

  // ── Core persistence ──────────────────────────────────────────────

  Future<void> loadFromPrefsSnapshot(Map<String, String> snapshot) async {
    for (final MapEntry<String, String> entry in snapshot.entries) {
      if (!entry.key.startsWith(_prefix)) continue;
      final String shortKey = entry.key.substring(_prefix.length);
      _cache[shortKey] = _parseValue(entry.value);
    }
    await _migrateMargins();
  }

  /// Reload all settings from the database, e.g. after a profile switch.
  Future<void> refreshFromDb() async {
    _cache.clear();
    final Map<String, String> all = await _db.getAllPrefs();
    await loadFromPrefsSnapshot(all);
  }

  Future<void> _migrateMargins() async {
    final double? first = _cache['ttu_first_dimension_margin'] as double?;
    final double? second = _cache['ttu_second_dimension_margin'] as double?;
    if (first == null && second == null) return;
    if (!_cache.containsKey('ttu_margin_top')) {
      final double topBottom = first ?? 0;
      final double leftRight = second ?? 0;
      await _set<double>('ttu_margin_top', topBottom);
      await _set<double>('ttu_margin_bottom', topBottom);
      await _set<double>('ttu_margin_left', leftRight);
      await _set<double>('ttu_margin_right', leftRight);
    }
    _cache.remove('ttu_first_dimension_margin');
    _cache.remove('ttu_second_dimension_margin');
    _cache.remove('ttu_second_dimension_max');
    await _db.deletePref('${_prefix}ttu_first_dimension_margin');
    await _db.deletePref('${_prefix}ttu_second_dimension_margin');
    await _db.deletePref('${_prefix}ttu_second_dimension_max');
  }

  T _get<T>(String key, T defaultValue) {
    final dynamic value = _cache[key];
    if (value is T) return value;
    if (T == double && value is int) return value.toDouble() as T;
    _set<T>(key, defaultValue);
    return defaultValue;
  }

  Future<void> _set<T>(String key, T value) async {
    _cache[key] = value;
    try {
      await _db.setPref('$_prefix$key', value.toString());
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderSettings.write', e, stack);
      debugPrint('[ReaderSettings] write error: $e');
    }
  }

  static dynamic _parseValue(String raw) {
    if (raw == 'true') return true;
    if (raw == 'false') return false;
    final int? asInt = int.tryParse(raw);
    if (asInt != null) return asInt;
    final double? asDouble = double.tryParse(raw);
    if (asDouble != null) return asDouble;
    return raw;
  }

  // ── Display settings (same Hive keys as old ReaderTtuSource) ──────

  double get fontSize => _get<double>('ttu_font_size', 22);
  Future<void> setFontSize(double v) => _set<double>('ttu_font_size', v);

  double get lyricsFontSize => _get<double>('lyrics_font_size', 24);
  Future<void> setLyricsFontSize(double v) =>
      _set<double>('lyrics_font_size', v);

  double get lyricsMarginTop => _get<double>('lyrics_margin_top', 0);
  Future<void> setLyricsMarginTop(double v) =>
      _set<double>('lyrics_margin_top', v);

  double get lyricsMarginBottom => _get<double>('lyrics_margin_bottom', 0);
  Future<void> setLyricsMarginBottom(double v) =>
      _set<double>('lyrics_margin_bottom', v);

  double get lyricsMarginLeft => _get<double>('lyrics_margin_left', 0);
  Future<void> setLyricsMarginLeft(double v) =>
      _set<double>('lyrics_margin_left', v);

  double get lyricsMarginRight => _get<double>('lyrics_margin_right', 0);
  Future<void> setLyricsMarginRight(double v) =>
      _set<double>('lyrics_margin_right', v);

  double get lineHeight => _get<double>('ttu_line_height', 1.65);
  Future<void> setLineHeight(double v) => _set<double>('ttu_line_height', v);

  String get writingMode => _get<String>('ttu_writing_mode', 'vertical-rl');
  Future<void> setWritingMode(String v) => _set<String>('ttu_writing_mode', v);

  String get viewMode => _get<String>('ttu_view_mode', 'paginated');
  Future<void> setViewMode(String v) => _set<String>('ttu_view_mode', v);

  bool get isContinuousMode => viewMode == 'continuous';

  String get theme => _get<String>('ttu_theme', 'light-theme');
  Future<void> setTheme(String v) => _set<String>('ttu_theme', v);

  String get furiganaMode {
    final dynamic raw = _cache['ttu_hide_furigana'];
    final bool? legacy = raw is bool ? raw : null;
    if (legacy != null) {
      final String oldStyle =
          _get<String>('ttu_furigana_style', 'partial').toLowerCase();
      final String mode = legacy ? 'hide' : 'show';
      final String merged = normalizeFuriganaMode(
        (legacy && (oldStyle == 'partial' || oldStyle == 'toggle'))
            ? oldStyle
            : mode,
      );
      _set<String>('ttu_furigana_mode', merged);
      _cache.remove('ttu_hide_furigana');
      _db.deletePref('${_prefix}ttu_hide_furigana');
      _db.deletePref('${_prefix}ttu_furigana_style');
      return merged;
    }
    return normalizeFuriganaMode(
      _get<String>('ttu_furigana_mode', 'show'),
    );
  }

  Future<void> setFuriganaMode(String v) =>
      _set<String>('ttu_furigana_mode', normalizeFuriganaMode(v));

  double get textIndentation => _get<double>('ttu_text_indentation', 0);
  Future<void> setTextIndentation(double v) =>
      _set<double>('ttu_text_indentation', v);

  double get marginTop => _get<double>('ttu_margin_top', 0);
  Future<void> setMarginTop(double v) => _set<double>('ttu_margin_top', v);

  double get marginBottom => _get<double>('ttu_margin_bottom', 0);
  Future<void> setMarginBottom(double v) =>
      _set<double>('ttu_margin_bottom', v);

  double get marginLeft => _get<double>('ttu_margin_left', 0);
  Future<void> setMarginLeft(double v) => _set<double>('ttu_margin_left', v);

  double get marginRight => _get<double>('ttu_margin_right', 0);
  Future<void> setMarginRight(double v) => _set<double>('ttu_margin_right', v);

  int get pageColumns => _get<int>('ttu_page_columns', 0);
  Future<void> setPageColumns(int v) => _set<int>('ttu_page_columns', v);

  /// `off`, `on`, or `auto`.
  String get spreadMode => _get<String>('ttu_spread_mode', 'auto');
  Future<void> setSpreadMode(String v) => _set<String>('ttu_spread_mode', v);

  /// `ltr` or `rtl`.
  String get spreadDirection => _get<String>('ttu_spread_direction', 'rtl');
  Future<void> setSpreadDirection(String v) =>
      _set<String>('ttu_spread_direction', v);

  bool get enableVerticalFontKerning => _get<bool>('ttu_vert_kerning', false);
  Future<void> setEnableVerticalFontKerning(bool v) =>
      _set<bool>('ttu_vert_kerning', v);

  bool get enableFontVPAL => _get<bool>('ttu_font_vpal', false);
  Future<void> setEnableFontVPAL(bool v) => _set<bool>('ttu_font_vpal', v);

  String get verticalTextOrientation =>
      _get<String>('ttu_vert_text_orient', 'mixed');
  Future<void> setVerticalTextOrientation(String v) =>
      _set<String>('ttu_vert_text_orient', v);

  bool get enableTextJustification => _get<bool>('ttu_text_justify', false);
  Future<void> setEnableTextJustification(bool v) =>
      _set<bool>('ttu_text_justify', v);

  bool get prioritizeReaderStyles => _get<bool>('ttu_reader_styles', false);
  Future<void> setPrioritizeReaderStyles(bool v) =>
      _set<bool>('ttu_reader_styles', v);

  // ── Behavior settings ─────────────────────────────────────────────

  bool get autoReadOnLookup => _get<bool>('auto_read_on_lookup', true);
  Future<void> toggleAutoReadOnLookup() =>
      _set<bool>('auto_read_on_lookup', !autoReadOnLookup);

  double get dismissSwipeSensitivity =>
      _get<double>('dismiss_swipe_sensitivity', 0.6);
  Future<void> setDismissSwipeSensitivity(double v) =>
      _set<double>('dismiss_swipe_sensitivity', v);

  /// 鼠标滚轮翻页的节流间隔（毫秒）：滚一下翻一页后，此时长内忽略后续滚轮事件。
  /// 越大翻页越慢。默认 450ms（旧实现写死 250ms，偏快）。
  int get wheelPageTurnInterval => _get<int>('wheel_page_turn_interval', 450);
  Future<void> setWheelPageTurnInterval(int v) =>
      _set<int>('wheel_page_turn_interval', v);

  bool get highlightOnTap => _get<bool>('highlight_on_tap', true);
  Future<void> toggleHighlightOnTap() =>
      _set<bool>('highlight_on_tap', !highlightOnTap);

  bool get keepScreenAwake => _get<bool>('keep_screen_awake', true);
  Future<void> toggleKeepScreenAwake() =>
      _set<bool>('keep_screen_awake', !keepScreenAwake);

  bool get tapEmptyToHideChrome => _get<bool>('tap_empty_hide_chrome', false);
  Future<void> toggleTapEmptyToHideChrome() =>
      _set<bool>('tap_empty_hide_chrome', !tapEmptyToHideChrome);

  bool get invertSwipeDirection => _get<bool>('invert_swipe_direction', true);
  Future<void> toggleInvertSwipeDirection() =>
      _set<bool>('invert_swipe_direction', !invertSwipeDirection);

  int get volumePageTurningSpeed => _get<int>('volume_page_turning_speed', 100);
  Future<void> setVolumePageTurningSpeed(int v) =>
      _set<int>('volume_page_turning_speed', v);

  // ── Custom fonts ──────────────────────────────────────────────────

  List<Map<String, dynamic>> get customFonts {
    final String raw = _get<String>('custom_fonts', '[]');
    try {
      return (jsonDecode(raw) as List<dynamic>).cast<Map<String, dynamic>>();
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderSettings.customFonts', e, stack);
      return <Map<String, dynamic>>[];
    }
  }

  /// CSS font-family string and @font-face declarations for enabled fonts.
  ({String fontFamily, String fontFaces}) buildCustomFontCss() =>
      customFontCssForEntries(customFonts);

  static String normalizeFuriganaMode(String mode) =>
      switch (mode.toLowerCase()) {
        'show' || 'hide' || 'partial' || 'toggle' => mode.toLowerCase(),
        _ => 'show',
      };

  static String furiganaModeToStyle(String mode) =>
      switch (normalizeFuriganaMode(mode)) {
        'hide' => 'Hide',
        'partial' => 'Partial',
        'toggle' => 'Toggle',
        _ => 'Show',
      };

  static ({String fontFamily, String fontFaces}) customFontCssForEntries(
    Iterable<Map<String, dynamic>> fonts, {
    Iterable<String> allowedDirectories = const <String>[],
  }) {
    return ReaderCustomFontCss.build(
      fonts,
      allowedDirectories: allowedDirectories,
    );
  }

  Future<void> setCustomFonts(List<Map<String, dynamic>> fonts) =>
      _set<String>('custom_fonts', jsonEncode(fonts));

  Future<void> addCustomFont({required String name, String? path}) async {
    final List<Map<String, dynamic>> list =
        List<Map<String, dynamic>>.from(customFonts);
    list.add(<String, dynamic>{
      'name': name,
      'path': path,
      'enabled': true,
    });
    await setCustomFonts(list);
  }

  Future<void> removeCustomFont(int index) async {
    final List<Map<String, dynamic>> list =
        List<Map<String, dynamic>>.from(customFonts);
    if (index < 0 || index >= list.length) {
      return;
    }
    list.removeAt(index);
    await setCustomFonts(list);
  }

  Future<void> toggleCustomFont(int index) async {
    final List<Map<String, dynamic>> list =
        List<Map<String, dynamic>>.from(customFonts);
    if (index < 0 || index >= list.length) {
      return;
    }
    list[index]['enabled'] = !(list[index]['enabled'] as bool? ?? true);
    await setCustomFonts(list);
  }

  Future<void> reorderCustomFonts(int oldIndex, int newIndex) async {
    final List<Map<String, dynamic>> list =
        List<Map<String, dynamic>>.from(customFonts);
    if (newIndex > oldIndex) {
      newIndex--;
    }
    if (oldIndex < 0 ||
        oldIndex >= list.length ||
        newIndex < 0 ||
        newIndex > list.length) {
      return;
    }
    final Map<String, dynamic> item = list.removeAt(oldIndex);
    list.insert(newIndex, item);
    await setCustomFonts(list);
  }
}

class ReaderCustomFontCss {
  static ({String fontFamily, String fontFaces}) build(
    Iterable<Map<String, dynamic>> fonts, {
    Iterable<String> allowedDirectories = const <String>[],
  }) {
    final Set<String> allowedRoots = allowedDirectories
        .where((String path) => path.isNotEmpty)
        .map(p.canonicalize)
        .toSet();
    final Iterable<Map<String, dynamic>> enabled =
        fonts.where((e) => e['enabled'] as bool? ?? true);
    final List<String> families = <String>[];
    final List<String> faces = <String>[];
    for (final Map<String, dynamic> e in enabled) {
      final String? rawName = e['name'] as String?;
      if (rawName == null || rawName.isEmpty) continue;
      final String normalizedName = normalizedFontFamilyName(rawName);
      final String? fontPath = e['path'] as String?;
      if (fontPath == null) {
        families.add(cssFontFamilyName(normalizedName));
        continue;
      }
      final String? safePath =
          safeFontPath(fontPath, allowedRoots: allowedRoots);
      if (safePath == null) {
        continue;
      }
      families.add(cssFontFamilyName(normalizedName));
      final String uri = fontUrl(safePath);
      faces.add(
        '@font-face { font-family: ${cssFontFamilyName(normalizedName)}; '
        'src: url("$uri"); font-display: swap; }',
      );
    }
    return (
      fontFamily: families.join(', '),
      fontFaces: faces.join('\n'),
    );
  }

  static String normalizedFontFamilyName(String name) {
    return name.replaceAll('_', ' ').trim();
  }

  static String cssFontFamilyName(String name) {
    final String normalized = normalizedFontFamilyName(name);
    final String escaped =
        normalized.replaceAll('\\', r'\\').replaceAll('"', r'\"');
    return '"$escaped"';
  }

  static String? safeFontPath(
    String fontPath, {
    Iterable<String> allowedRoots = const <String>[],
  }) {
    final String canonicalPath = p.canonicalize(fontPath);
    final List<String> roots = allowedRoots
        .where((String root) => root.isNotEmpty)
        .map(p.canonicalize)
        .toList();
    if (roots.isNotEmpty &&
        !roots.any((String root) =>
            canonicalPath == root || p.isWithin(root, canonicalPath))) {
      return null;
    }
    return canonicalPath;
  }

  static String fontUrl(String path) =>
      'https://hoshi.local/fonts/${Uri.encodeComponent(path)}';
}
