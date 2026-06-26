import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/reader/font_catalog.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:path/path.dart' as p;

/// The three independent font targets a user can configure (TODO-049):
/// 软件系统字体 ([appUi]) / 小说正文字体 ([body]) / 词典字体 ([dictionary]).
/// Each maps to its own persisted `[{name,path,enabled}]` list; see
/// [ReaderSettings.fontKeyForTarget].
enum FontTarget {
  /// App-wide UI (ThemeData) font — menus, buttons, settings, etc.
  appUi,

  /// Novel/EPUB body text font, injected into the reader WebView CSS.
  body,

  /// Dictionary popup (definition/meaning) font.
  dictionary,
}

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

  /// TODO-362（PR#3 响应式页边距）：正文左右两侧默认各留白 2%（百分比 = vw），每行
  /// 因此变窄；上下默认 0%（垂直预留由 chrome inset + 字号决定，见
  /// `ReaderContentStyles`）。四个值是「单一真相」默认，被 `ReaderHibikiSource`
  /// 的 fallback 默认引用，避免三处来源（settings / source / aggregate）互相矛盾。
  static const double defaultMarginTopPercent = 0;
  static const double defaultMarginBottomPercent = 0;
  static const double defaultMarginLeftPercent = 2;
  static const double defaultMarginRightPercent = 2;

  /// 边距是百分比（vw/vh），CSS padding 不接受负值且过大会吃光正文；统一夹在
  /// `[0, 50]`，非有限值（NaN/∞）落 0。
  static double normalizeMarginPercent(double value) =>
      value.isFinite ? value.clamp(0, 50).toDouble() : 0;

  // ── Core persistence ──────────────────────────────────────────────

  Future<void> loadFromPrefsSnapshot(Map<String, String> snapshot) async {
    for (final MapEntry<String, String> entry in snapshot.entries) {
      if (!entry.key.startsWith(_prefix)) continue;
      final String shortKey = entry.key.substring(_prefix.length);
      _cache[shortKey] = _parseValue(entry.value);
    }
    await _migrateMargins();
    await _ensureFontCatalogState();
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

  /// TODO-368: 歌词字幕文字色，独立于主题色单独可调（参照视频字幕色）。存储为 ARGB
  /// int；`0`（完全透明，作为正文色永远无效）作哨兵 = 「未设置 / 跟随主题」，保持
  /// 向后兼容：未设过的用户落 0 → 消费端回退到主题文字色，与历史行为一致。
  int get lyricsTextColor => _get<int>('lyrics_text_color', 0);
  Future<void> setLyricsTextColor(int v) => _set<int>('lyrics_text_color', v);

  /// 清除自定义歌词色 → 回退跟随主题（哨兵 0）。
  Future<void> clearLyricsTextColor() => _set<int>('lyrics_text_color', 0);

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

  double get marginTop =>
      _get<double>('ttu_margin_top', defaultMarginTopPercent);
  Future<void> setMarginTop(double v) =>
      _set<double>('ttu_margin_top', normalizeMarginPercent(v));

  double get marginBottom =>
      _get<double>('ttu_margin_bottom', defaultMarginBottomPercent);
  Future<void> setMarginBottom(double v) =>
      _set<double>('ttu_margin_bottom', normalizeMarginPercent(v));

  double get marginLeft =>
      _get<double>('ttu_margin_left', defaultMarginLeftPercent);
  Future<void> setMarginLeft(double v) =>
      _set<double>('ttu_margin_left', normalizeMarginPercent(v));

  double get marginRight =>
      _get<double>('ttu_margin_right', defaultMarginRightPercent);
  Future<void> setMarginRight(double v) =>
      _set<double>('ttu_margin_right', normalizeMarginPercent(v));

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

  static int normalizeLookupAudioVolume(num value) =>
      value.round().clamp(0, 100).toInt();

  int get lookupAudioVolume =>
      _get<int>('lookup_audio_volume', 100).clamp(0, 100).toInt();
  Future<void> setLookupAudioVolume(num value) => _set<int>(
        'lookup_audio_volume',
        normalizeLookupAudioVolume(value),
      );

  double get dismissSwipeSensitivity =>
      _get<double>('dismiss_swipe_sensitivity', 0.6);
  Future<void> setDismissSwipeSensitivity(double v) =>
      _set<double>('dismiss_swipe_sensitivity', v);

  /// TODO-407②：查词弹窗是否允许"水平滑动关闭"（[SwipeDismissWrapper]）。桌面端
  /// （Windows/Linux）鼠标左键框选正文与滑动手势的位移序列同形，默认关闭滑动关闭、
  /// 用顶栏 X 兜底；触摸为主的平台（macOS/iOS/Android）默认开启。未持久化覆盖时
  /// 回退到 [defaultSwipeToClose]，让"换平台即取该平台默认"成立。
  bool get enableSwipeToClose => _get<bool>(
        'enable_swipe_to_close',
        defaultSwipeToClose(defaultTargetPlatform),
      );
  Future<void> setEnableSwipeToClose(bool v) =>
      _set<bool>('enable_swipe_to_close', v);

  /// 纯函数：某平台下查词弹窗"滑动关闭"的默认开关。Windows/Linux 默认 false
  /// （鼠标框选易误触），其余（macOS/iOS/Android/fuchsia）默认 true。
  static bool defaultSwipeToClose(TargetPlatform platform) =>
      !(platform == TargetPlatform.windows || platform == TargetPlatform.linux);

  /// 翻页滑动灵敏度系数（TODO-113）。1.0 = 默认手感；<1 更灵敏（更短的滑动即可
  /// 翻页），>1 更迟钝（需滑得更远）。系数缩放 JS 端 `_gestureEnd` 的基础距离阈值
  /// （72px / 快速短滑 36px），见 reader_hibiki_page.dart `_buildReaderSetupScript`。
  static double normalizeSwipePageTurnSensitivity(num value) =>
      value.toDouble().clamp(0.3, 2.0).toDouble();

  double get swipePageTurnSensitivity => normalizeSwipePageTurnSensitivity(
        _get<double>('swipe_page_turn_sensitivity', 1.0),
      );
  Future<void> setSwipePageTurnSensitivity(double v) => _set<double>(
        'swipe_page_turn_sensitivity',
        normalizeSwipePageTurnSensitivity(v),
      );

  /// 基础滑动翻页距离阈值（px）：纯距离触发 [baseDistPx]，配合速度的快速短滑触发
  /// [baseFastDistPx]。系数 1.0 时与旧硬编码值一致（72 / 36）。
  static const int baseSwipeDistPx = 72;
  static const int baseSwipeFastDistPx = 36;

  /// 把灵敏度系数 [sensitivity] 解析成 JS `_gestureEnd` 用的两个距离阈值（px）。
  /// 系数越大阈值越大（越迟钝，需滑得更远）；越小越灵敏。这是 reader 注入脚本与
  /// 守卫测试共用的单一真相，保证「改系数→阈值变」在 UI 与 JS 两侧一致（TODO-113）。
  static ({int dist, int fastDist}) swipePageTurnDistThresholds(
    double sensitivity,
  ) {
    final double s = normalizeSwipePageTurnSensitivity(sensitivity);
    return (
      dist: (baseSwipeDistPx * s).round().clamp(8, 600),
      fastDist: (baseSwipeFastDistPx * s).round().clamp(4, 600),
    );
  }

  /// 鼠标滚轮翻页的节流间隔（毫秒）：滚一下翻一页后，此时长内忽略后续滚轮事件。
  /// 越大翻页越慢。默认 450ms（旧实现写死 250ms，偏快）。
  int get wheelPageTurnInterval => _get<int>('wheel_page_turn_interval', 450);
  Future<void> setWheelPageTurnInterval(int v) =>
      _set<int>('wheel_page_turn_interval', v);

  bool get highlightOnTap => _get<bool>('highlight_on_tap', true);
  Future<void> toggleHighlightOnTap() =>
      _set<bool>('highlight_on_tap', !highlightOnTap);

  bool get showTopProgressBar => _get<bool>('show_top_progress_bar', true);
  Future<void> toggleShowTopProgressBar() =>
      _set<bool>('show_top_progress_bar', !showTopProgressBar);

  bool get keepScreenAwake => _get<bool>('keep_screen_awake', true);
  Future<void> toggleKeepScreenAwake() =>
      _set<bool>('keep_screen_awake', !keepScreenAwake);

  // TODO-728②：有声书底栏是否显示「当前句子」cue 文本（per-reader，每本书各自
  // 记忆）。默认 true = 现状（始终显示）；false = 隐藏 cue 文本但保留布局占位，
  // 底栏其它控件位置不动。
  bool get showBottomBarCue => _get<bool>('show_bottom_bar_cue', true);
  Future<void> toggleShowBottomBarCue() =>
      _set<bool>('show_bottom_bar_cue', !showBottomBarCue);

  // TODO-728: top reading-progress position (per-reader). One of
  // 'left' | 'center' | 'right'; default 'center' = current behavior
  // (centered between left/right 96px insets). Normalized on read so an
  // unexpected stored value degrades to 'center'.
  static String normalizeTopProgressPosition(String value) => switch (value) {
        'left' || 'center' || 'right' => value,
        _ => 'center',
      };

  String get topProgressPosition => normalizeTopProgressPosition(
      _get<String>('top_progress_position', 'center'));
  Future<void> setTopProgressPosition(String v) =>
      _set<String>('top_progress_position', normalizeTopProgressPosition(v));

  bool get tapEmptyToHideChrome => _get<bool>('tap_empty_hide_chrome', false);
  Future<void> toggleTapEmptyToHideChrome() =>
      _set<bool>('tap_empty_hide_chrome', !tapEmptyToHideChrome);

  bool get invertSwipeDirection => _get<bool>('invert_swipe_direction', true);
  Future<void> toggleInvertSwipeDirection() =>
      _set<bool>('invert_swipe_direction', !invertSwipeDirection);

  // TODO-120: 反转键盘方向键翻页方向（仅键盘方向键，与滑动反转独立）。
  // 默认 false = 现有行为（方向键跟随阅读方向）；true = 在最终方向上整体取反。
  bool get reverseArrowPageTurn => _get<bool>('reverse_arrow_page_turn', false);
  Future<void> toggleReverseArrowPageTurn() =>
      _set<bool>('reverse_arrow_page_turn', !reverseArrowPageTurn);

  // TODO-830: 反转有声书底栏 ⏮⏭ 前进/后退按钮的功能方向（per-reader，每本书
  // 各自记忆，与 invert_swipe_direction / reverse_arrow_page_turn 一致）。
  // 默认 false = 现有行为（左=上一句/快退、右=下一句/快进）；true = 左右功能互换。
  // 这是「功能反转」维度，与 reverseReaderBottomBar 的「位置镜像」维度严格正交。
  bool get invertAudiobookSkipDirection =>
      _get<bool>('invert_audiobook_skip_direction', false);
  Future<void> toggleInvertAudiobookSkipDirection() => _set<bool>(
      'invert_audiobook_skip_direction', !invertAudiobookSkipDirection);

  int get volumePageTurningSpeed => _get<int>('volume_page_turning_speed', 100);
  Future<void> setVolumePageTurningSpeed(int v) =>
      _set<int>('volume_page_turning_speed', v);

  // ── Custom fonts (catalog + per-target refs) ─────────────────────
  //
  // TODO-225 / TODO-221A: fonts now persist as a shared `font_catalog` plus
  // `font_targets` membership/order/enabled rows. The public list-shaped API is
  // intentionally kept stable for the current UI/rendering call sites.

  /// Persistence key for the legacy/body font list. Kept verbatim so existing
  /// user data migrates automatically.
  static const String fontKeyBody = 'custom_fonts';

  /// Persistence key for the app-wide UI (ThemeData) font list. New in TODO-049.
  static const String fontKeyAppUi = 'app_ui_fonts';

  /// Persistence key for the dictionary popup font list. New in TODO-049.
  static const String fontKeyDictionary = 'dict_fonts';

  /// Persistence key for the shared font catalog.
  static const String fontCatalogKey = 'font_catalog';

  /// Persistence key for target membership/order/enabled state.
  static const String fontTargetsKey = 'font_targets';

  static const List<String> _fontTargetKeys = <String>[
    fontKeyBody,
    fontKeyAppUi,
    fontKeyDictionary,
  ];

  bool get _hasAnyFontPrefs =>
      _cache.containsKey(fontCatalogKey) ||
      _cache.containsKey(fontTargetsKey) ||
      _fontTargetKeys.any(_cache.containsKey);

  /// Parses a legacy list stored under [key]. Malformed/missing data degrades
  /// to an empty list (logged), never throws.
  List<Map<String, dynamic>> _legacyFontListForKey(String key) {
    final dynamic value = _cache[key];
    if (value is! String) return <Map<String, dynamic>>[];
    try {
      return <Map<String, dynamic>>[
        for (final dynamic row in jsonDecode(value) as List<dynamic>)
          if (row is Map<dynamic, dynamic>) row.cast<String, dynamic>(),
      ];
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderSettings.fontList:$key', e, stack);
      return <Map<String, dynamic>>[];
    }
  }

  Map<String, List<Map<String, dynamic>>> _legacyFontListsByTarget() {
    return <String, List<Map<String, dynamic>>>{
      if (_cache.containsKey(fontKeyBody))
        fontKeyBody: _legacyFontListForKey(fontKeyBody),
      if (_cache.containsKey(fontKeyAppUi))
        fontKeyAppUi: _legacyFontListForKey(fontKeyAppUi),
      if (_cache.containsKey(fontKeyDictionary))
        fontKeyDictionary: _legacyFontListForKey(fontKeyDictionary),
    };
  }

  FontCatalogState? _readFontCatalogState() {
    final dynamic catalog = _cache[fontCatalogKey];
    final dynamic targets = _cache[fontTargetsKey];
    if (catalog is! String || targets is! String) return null;
    final FontCatalogState? state = FontCatalogState.tryParse(
      catalogJson: catalog,
      targetsJson: targets,
      targetKeys: _fontTargetKeys,
    );
    if (state == null) {
      ErrorLogService.instance.log(
        'ReaderSettings.fontCatalog',
        const FormatException('Invalid font_catalog/font_targets JSON'),
        StackTrace.current,
      );
    }
    return state;
  }

  FontCatalogState _fontCatalogState() {
    return _readFontCatalogState() ??
        FontCatalogState.fromLegacy(_legacyFontListsByTarget());
  }

  Future<FontCatalogState> _ensureFontCatalogState() async {
    final FontCatalogState? existing = _readFontCatalogState();
    if (existing != null) return existing;
    final FontCatalogState migrated = _hasAnyFontPrefs
        ? FontCatalogState.fromLegacy(_legacyFontListsByTarget())
        : FontCatalogState.empty();
    if (_hasAnyFontPrefs) {
      await _persistFontCatalogState(migrated, syncLegacyKeys: true);
    }
    return migrated;
  }

  Future<void> _persistFontCatalogState(
    FontCatalogState state, {
    required bool syncLegacyKeys,
  }) async {
    _cacheFontCatalogState(state, syncLegacyKeys: syncLegacyKeys);
    try {
      await _db.setPref(
        '$_prefix$fontCatalogKey',
        _cache[fontCatalogKey] as String,
      );
      await _db.setPref(
        '$_prefix$fontTargetsKey',
        _cache[fontTargetsKey] as String,
      );
      if (!syncLegacyKeys) return;
      for (final String key in _fontTargetKeys) {
        if (!state.hasTarget(key)) continue;
        await _db.setPref('$_prefix$key', _cache[key] as String);
      }
    } catch (e, stack) {
      ErrorLogService.instance
          .log('ReaderSettings.fontCatalog.write', e, stack);
      debugPrint('[ReaderSettings] write error: $e');
    }
  }

  void _cacheFontCatalogState(
    FontCatalogState state, {
    required bool syncLegacyKeys,
  }) {
    _cache[fontCatalogKey] = jsonEncode(state.toCatalogJson());
    _cache[fontTargetsKey] = jsonEncode(state.toTargetsJson());
    if (!syncLegacyKeys) return;
    for (final String key in _fontTargetKeys) {
      if (!state.hasTarget(key)) continue;
      _cache[key] = jsonEncode(state.fontListForTarget(key));
    }
  }

  List<Map<String, dynamic>> _fontListForTargetKey(String key) {
    final FontCatalogState state = _fontCatalogState();
    if (key != fontKeyBody &&
        !state.hasTarget(key) &&
        state.hasTarget(fontKeyBody)) {
      final FontCatalogState seeded = state.withTargetFonts(
        key,
        state.fontListForTarget(fontKeyBody),
      );
      _cacheFontCatalogState(seeded, syncLegacyKeys: true);
      return seeded.fontListForTarget(key);
    }
    return state.fontListForTarget(key);
  }

  /// Body (novel text) font list -- legacy `custom_fonts` key, unchanged.
  List<Map<String, dynamic>> get customFonts =>
      _fontListForTargetKey(fontKeyBody);

  /// App-wide UI (ThemeData) font list.
  List<Map<String, dynamic>> get appUiFonts =>
      _fontListForTargetKey(fontKeyAppUi);

  /// Dictionary popup font list.
  List<Map<String, dynamic>> get dictionaryFonts =>
      _fontListForTargetKey(fontKeyDictionary);

  /// Resolves the persisted font list for a [FontTarget].
  List<Map<String, dynamic>> fontsForTarget(FontTarget target) =>
      switch (target) {
        FontTarget.body => customFonts,
        FontTarget.appUi => appUiFonts,
        FontTarget.dictionary => dictionaryFonts,
      };

  /// CSS font-family string and @font-face declarations for the BODY fonts.
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

  /// Resolves the persistence key backing a [FontTarget].
  static String fontKeyForTarget(FontTarget target) => switch (target) {
        FontTarget.body => fontKeyBody,
        FontTarget.appUi => fontKeyAppUi,
        FontTarget.dictionary => fontKeyDictionary,
      };

  /// Persists the whole list for [target]. The body convenience overload
  /// [setCustomFonts] preserves the pre-split call sites unchanged.
  Future<void> setFontsForTarget(
    FontTarget target,
    List<Map<String, dynamic>> fonts,
  ) async {
    final FontCatalogState state = await _ensureFontCatalogState();
    final FontCatalogState updated = state.withTargetFonts(
      fontKeyForTarget(target),
      fonts,
    );
    await _persistFontCatalogState(updated, syncLegacyKeys: true);
  }

  Future<void> setCustomFonts(List<Map<String, dynamic>> fonts) =>
      setFontsForTarget(FontTarget.body, fonts);

  Future<void> addFontForTarget(
    FontTarget target, {
    required String name,
    String? path,
  }) async {
    final List<Map<String, dynamic>> list =
        List<Map<String, dynamic>>.from(fontsForTarget(target));
    list.add(<String, dynamic>{'name': name, 'path': path, 'enabled': true});
    await setFontsForTarget(target, list);
  }

  Future<void> removeFontForTarget(FontTarget target, int index) async {
    final List<Map<String, dynamic>> list =
        List<Map<String, dynamic>>.from(fontsForTarget(target));
    if (index < 0 || index >= list.length) return;
    list.removeAt(index);
    await setFontsForTarget(target, list);
  }

  Future<void> toggleFontForTarget(FontTarget target, int index) async {
    final List<Map<String, dynamic>> list =
        List<Map<String, dynamic>>.from(fontsForTarget(target));
    if (index < 0 || index >= list.length) return;
    list[index]['enabled'] = !(list[index]['enabled'] as bool? ?? true);
    await setFontsForTarget(target, list);
  }

  Future<void> reorderFontsForTarget(
    FontTarget target,
    int oldIndex,
    int newIndex,
  ) async {
    final List<Map<String, dynamic>> list =
        List<Map<String, dynamic>>.from(fontsForTarget(target));
    if (newIndex > oldIndex) newIndex--;
    if (oldIndex < 0 ||
        oldIndex >= list.length ||
        newIndex < 0 ||
        newIndex > list.length) {
      return;
    }
    final Map<String, dynamic> item = list.removeAt(oldIndex);
    list.insert(newIndex, item);
    await setFontsForTarget(target, list);
  }

  // Body-target convenience overloads kept for existing reader call sites.
  Future<void> addCustomFont({required String name, String? path}) =>
      addFontForTarget(FontTarget.body, name: name, path: path);

  Future<void> removeCustomFont(int index) =>
      removeFontForTarget(FontTarget.body, index);

  Future<void> toggleCustomFont(int index) =>
      toggleFontForTarget(FontTarget.body, index);

  Future<void> reorderCustomFonts(int oldIndex, int newIndex) =>
      reorderFontsForTarget(FontTarget.body, oldIndex, newIndex);
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
