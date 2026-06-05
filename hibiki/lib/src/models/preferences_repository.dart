import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'package:hibiki/src/models/audio_source_config.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:hibiki/src/utils/player/blur_options.dart';

class PreferencesRepository extends ChangeNotifier {
  PreferencesRepository(this._db);

  final HibikiDatabase _db;
  final Map<String, String> _prefCache = {};

  Future<void> loadFromDb() async {
    final all = await _db.getAllPrefs();
    _prefCache
      ..clear()
      ..addAll(all);
  }

  Map<String, String> get prefsSnapshot =>
      Map<String, String>.unmodifiable(_prefCache);

  Future<void> refreshFromDb() async {
    await loadFromDb();
    notifyListeners();
  }

  dynamic getPref(String key, {dynamic defaultValue}) {
    final raw = _prefCache[key];
    if (raw == null) {
      return defaultValue;
    }
    return PrefCodec.decode(raw, defaultValue);
  }

  Future<void> setPref(String key, dynamic value) async {
    final String strVal = PrefCodec.encode(value);
    _prefCache[key] = strVal;
    await _db.setPref(key, strVal);
  }

  bool containsKey(String key) => _prefCache.containsKey(key);

  // ── player preferences ───────────────────────────────────────────────

  bool get isPlayerListeningComprehensionMode =>
      getPref('player_listening_comprehension_mode', defaultValue: false)
          as bool;

  void togglePlayerListeningComprehensionMode() async {
    await setPref('player_listening_comprehension_mode',
        !isPlayerListeningComprehensionMode);
    notifyListeners();
  }

  bool get isPlayerOrientationPortrait =>
      getPref('player_orientation_portrait', defaultValue: false) as bool;

  void togglePlayerOrientationPortrait() async {
    await setPref('player_orientation_portrait', !isPlayerOrientationPortrait);
    notifyListeners();
  }

  bool get isStretchToFill =>
      getPref('stretch_to_fill_screen', defaultValue: false) as bool;

  void toggleStretchToFill() async {
    await setPref('stretch_to_fill_screen', !isStretchToFill);
    notifyListeners();
  }

  bool get playerHardwareAcceleration =>
      getPref('player_hardware_acceleration', defaultValue: true) as bool;

  void setPlayerHardwareAcceleration({required bool value}) async {
    await setPref('player_hardware_acceleration', value);
    notifyListeners();
  }

  bool get playerBackgroundPlay =>
      getPref('player_background_play', defaultValue: true) as bool;

  void setPlayerBackgroundPlay({required bool value}) async {
    await setPref('player_background_play', value);
    notifyListeners();
  }

  bool get showSubtitlesInNotification =>
      getPref('player_subtitle_notification', defaultValue: true) as bool;

  void setShowSubtitlesInNotification({required bool value}) async {
    await setPref('player_subtitle_notification', value);
    notifyListeners();
  }

  bool get playerUseOpenSLES =>
      getPref('player_use_opensles', defaultValue: true) as bool;

  void setPlayerUseOpenSLES({required bool value}) async {
    await setPref('player_use_opensles', value);
    notifyListeners();
  }

  // ── search & dictionary display ──────────────────────────────────────

  bool get autoSearchEnabled =>
      getPref('auto_search', defaultValue: true) as bool;

  void toggleAutoSearchEnabled() async {
    await setPref('auto_search', !autoSearchEnabled);
    notifyListeners();
  }

  bool get remoteLookupEnabled =>
      getPref('remote_lookup_enabled', defaultValue: false) as bool;

  Future<void> setRemoteLookupEnabled(bool value) async {
    await setPref('remote_lookup_enabled', value);
    notifyListeners();
  }

  final int defaultSearchDebounceDelay = 100;

  int get searchDebounceDelay => getPref('auto_search_debounce_delay',
      defaultValue: defaultSearchDebounceDelay) as int;

  void setSearchDebounceDelay(int debounceDelay) async {
    await setPref('auto_search_debounce_delay', debounceDelay);
    notifyListeners();
  }

  final double defaultDictionaryFontSize = 16;

  double get dictionaryFontSize => getPref('dictionary_entry_font_size',
      defaultValue: defaultDictionaryFontSize) as double;

  void setDictionaryFontSize(double fontSize) async {
    await setPref('dictionary_entry_font_size', fontSize);
    notifyListeners();
  }

  final double defaultPopupMaxWidth = 400;

  double get popupMaxWidth =>
      getPref('popup_max_width', defaultValue: defaultPopupMaxWidth) as double;

  void setPopupMaxWidth(double width) async {
    await setPref('popup_max_width', width);
    notifyListeners();
  }

  final double defaultPopupMaxHeight = 360;

  double get popupMaxHeight =>
      getPref('popup_max_height', defaultValue: defaultPopupMaxHeight)
          as double;

  void setPopupMaxHeight(double height) async {
    await setPref('popup_max_height', height);
    notifyListeners();
  }

  final int defaultDoubleTapSeekDuration = 5000;

  int get doubleTapSeekDuration => getPref('double_tap_seek_duration',
      defaultValue: defaultDoubleTapSeekDuration) as int;

  void setDoubleTapSeekDuration(int value) async {
    await setPref('double_tap_seek_duration', value);
    notifyListeners();
  }

  bool get isFirstTimeSetup =>
      getPref('first_time_setup', defaultValue: true) as bool;

  void setFirstTimeSetupFlag() async {
    await setPref('first_time_setup', false);
  }

  final int defaultMaximumDictionaryTermsInResult = 10;

  int get maximumTerms => getPref('maximum_terms',
      defaultValue: defaultMaximumDictionaryTermsInResult) as int;

  void setMaximumTerms(int value) async {
    await setPref('maximum_terms', value);
    notifyListeners();
  }

  // ── home tab ─────────────────────────────────────────────────────────

  int get currentHomeTabIndex =>
      getPref('current_home_tab_index', defaultValue: 0) as int;

  Future<void> setCurrentHomeTabIndex(int index) async {
    await setPref('current_home_tab_index', index);
  }

  bool get reverseNavigationBar =>
      getPref('reverse_navigation_bar', defaultValue: false) as bool;

  void toggleReverseNavigationBar() async {
    await setPref('reverse_navigation_bar', !reverseNavigationBar);
    notifyListeners();
  }

  bool get reverseReaderBottomBar =>
      getPref('reverse_reader_bottom_bar', defaultValue: false) as bool;

  void toggleReverseReaderBottomBar() async {
    await setPref('reverse_reader_bottom_bar', !reverseReaderBottomBar);
    notifyListeners();
  }

  /// 实验性「视频」功能开关：开启后首页出现「视频」底栏 tab，并放出视频导入入口。
  /// 默认关闭——视频播放/查词/制卡虽已落地，但作为实验功能默认隐藏（见
  /// docs/specs/2026-06-05-video-subsystem-plan.md）。
  bool get experimentalVideoEnabled =>
      getPref('experimental_video_enabled', defaultValue: false) as bool;

  Future<void> setExperimentalVideoEnabled(bool value) async {
    await setPref('experimental_video_enabled', value);
    notifyListeners();
  }

  /// 启用的 mpv 着色器（JSON 字符串数组的文件名，相对着色器目录）。空串=未启用。
  /// 解析/编码见 video_shader_manager.dart 的 encode/decodeEnabledShaders。
  String get videoShadersEnabled =>
      getPref('video_shaders_enabled', defaultValue: '') as String;

  Future<void> setVideoShadersEnabled(String json) async {
    await setPref('video_shaders_enabled', json);
    notifyListeners();
  }

  /// Jimaku（jimaku.cc）API key：自动获取日语字幕用（用户在视频字幕菜单里填）。
  String get jimakuApiKey =>
      getPref('jimaku_api_key', defaultValue: '') as String;

  Future<void> setJimakuApiKey(String key) async {
    await setPref('jimaku_api_key', key);
    notifyListeners();
  }

  // ── transcript ───────────────────────────────────────────────────────

  bool get isTranscriptPlayerMode =>
      getPref('is_transcript_player_mode', defaultValue: false) as bool;

  void toggleTranscriptPlayerMode() async {
    await setPref('is_transcript_player_mode', !isTranscriptPlayerMode);
    notifyListeners();
  }

  bool get isTranscriptOpaque =>
      getPref('is_transcript_opaque', defaultValue: false) as bool;

  void toggleTranscriptOpaque() async {
    await setPref('is_transcript_opaque', !isTranscriptOpaque);
    notifyListeners();
  }

  bool get subtitleTimingsShown =>
      getPref('subtitle_timings_shown', defaultValue: true) as bool;

  void toggleSubtitleTimingsShown() async {
    await setPref('subtitle_timings_shown', !subtitleTimingsShown);
    notifyListeners();
  }

  // ── tags & card export ───────────────────────────────────────────────

  String get savedTags => getPref('saved_tags', defaultValue: '') as String;

  void setSavedTags(String value) async {
    await setPref('saved_tags', value);
  }

  bool get autoAddBookNameToTags =>
      getPref('auto_add_book_name_to_tags', defaultValue: true) as bool;

  void toggleAutoAddBookNameToTags() async {
    await setPref('auto_add_book_name_to_tags', !autoAddBookNameToTags);
    notifyListeners();
  }

  bool get deduplicatePitchAccents =>
      getPref('deduplicate_pitch_accents', defaultValue: true) as bool;

  void toggleDeduplicatePitchAccents() async {
    await setPref('deduplicate_pitch_accents', !deduplicatePitchAccents);
    notifyListeners();
  }

  bool get harmonicFrequency =>
      getPref('harmonic_frequency', defaultValue: true) as bool;

  void toggleHarmonicFrequency() async {
    await setPref('harmonic_frequency', !harmonicFrequency);
    notifyListeners();
  }

  bool get showExpressionTags =>
      getPref('show_expression_tags', defaultValue: false) as bool;

  void toggleShowExpressionTags() async {
    await setPref('show_expression_tags', !showExpressionTags);
    notifyListeners();
  }

  bool get collapseDictionaries =>
      getPref('collapse_dictionaries', defaultValue: true) as bool;

  void toggleCollapseDictionaries() async {
    await setPref('collapse_dictionaries', !collapseDictionaries);
    notifyListeners();
  }

  // ── custom CSS ───────────────────────────────────────────────────────

  Map<String, String> get customDictCSS {
    final raw = getPref('custom_dict_css', defaultValue: '') as String;
    if (raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (e, stack) {
      ErrorLogService.instance
          .log('PreferencesRepository.customDictCSS.decode', e, stack);
    }
    return {};
  }

  String getCustomCSSForDict(String dictName) => customDictCSS[dictName] ?? '';

  Future<void> setCustomCSSForDict(String dictName, String css) async {
    final map = customDictCSS;
    if (css.isEmpty) {
      map.remove(dictName);
    } else {
      map[dictName] = css;
    }
    await setPref('custom_dict_css', jsonEncode(map));
  }

  String get globalDictCSS =>
      getPref('global_dict_css', defaultValue: '') as String;

  Future<void> setGlobalDictCSS(String css) async {
    await setPref('global_dict_css', css);
  }

  // ── audio sources ────────────────────────────────────────────────────

  static const List<String> defaultAudioSources = [
    'https://hoshi-reader.manhhaoo-do.workers.dev/?term={term}&reading={reading}',
  ];

  List<String> get audioSources {
    final result = getPref('audio_sources', defaultValue: defaultAudioSources);
    if (result is List<String>) return result;
    if (result is List) return result.cast<String>();
    return List<String>.from(defaultAudioSources);
  }

  List<AudioSourceConfig> get audioSourceConfigs {
    final result = getPref('audio_source_configs', defaultValue: null);
    if (result is List) {
      final configs = result
          .whereType<Map>()
          .map((Map json) => AudioSourceConfig.fromJson(
                Map<String, dynamic>.from(json),
              ))
          .where((AudioSourceConfig source) =>
              source.kind != AudioSourceKind.remoteAudio ||
              (source.url?.isNotEmpty ?? false))
          .toList();
      if (configs.isNotEmpty) return _withDefaultAudioSources(configs);
    }
    return _withDefaultAudioSources(
      AudioSourceConfig.fromLegacyUrls(audioSources),
    );
  }

  List<AudioSourceConfig> _withDefaultAudioSources(
    List<AudioSourceConfig> sources,
  ) {
    final bool hasHibikiRemote = sources.any(
      (AudioSourceConfig source) => source.kind == AudioSourceKind.hibikiRemote,
    );
    if (hasHibikiRemote) return sources;
    return <AudioSourceConfig>[
      AudioSourceConfig.hibikiRemote(),
      ...sources,
    ];
  }

  void setAudioSources(List<String> sources) async {
    await setPref('audio_sources', sources);
    notifyListeners();
  }

  Future<void> setAudioSourceConfigs(List<AudioSourceConfig> sources) async {
    await setPref(
      'audio_source_configs',
      sources.map((AudioSourceConfig source) => source.toJson()).toList(),
    );
    await setPref(
      'audio_sources',
      sources
          .where((AudioSourceConfig source) =>
              source.kind == AudioSourceKind.remoteAudio && source.enabled)
          .map((AudioSourceConfig source) => source.url ?? '')
          .where((String url) => url.isNotEmpty)
          .toList(),
    );
    notifyListeners();
  }

  // ── UI visibility ────────────────────────────────────────────────────

  bool get showPlayBar => getPref('show_play_bar', defaultValue: true) as bool;

  void toggleShowPlayBar() async {
    await setPref('show_play_bar', !showPlayBar);
    notifyListeners();
  }

  bool get showMediaNotification =>
      getPref('show_media_notification', defaultValue: true) as bool;

  void toggleShowMediaNotification() async {
    await setPref('show_media_notification', !showMediaNotification);
    notifyListeners();
  }

  Future<void> setShowMediaNotification(bool value) async {
    await setPref('show_media_notification', value);
    notifyListeners();
  }

  bool get showFloatingLyric =>
      getPref('show_floating_lyric', defaultValue: false) as bool;

  Future<void> setShowFloatingLyric(bool value) async {
    await setPref('show_floating_lyric', value);
    notifyListeners();
  }

  double get floatingLyricFontSize =>
      getPref('floating_lyric_font_size', defaultValue: 20.0) as double;

  Future<void> setFloatingLyricFontSize(double value) async {
    await setPref('floating_lyric_font_size', value.clamp(8, 64).toDouble());
    notifyListeners();
  }

  bool get showFloatingDict =>
      getPref('show_floating_dict', defaultValue: false) as bool;

  // ── update preferences ───────────────────────────────────────────────

  bool get updateNeverRemind =>
      getPref('update_never_remind', defaultValue: false) as bool;

  Future<void> setUpdateNeverRemind(bool value) async {
    await setPref('update_never_remind', value);
    notifyListeners();
  }

  bool get updateAutoInstall =>
      getPref('update_auto_install', defaultValue: false) as bool;

  Future<void> setUpdateAutoInstall(bool value) async {
    await setPref('update_auto_install', value);
    notifyListeners();
  }

  bool get updateBetaChannel =>
      getPref('update_beta_channel', defaultValue: false) as bool;

  Future<void> setUpdateBetaChannel(bool value) async {
    await setPref('update_beta_channel', value);
    notifyListeners();
  }

  bool get updateDebugChannel =>
      getPref('update_debug_channel', defaultValue: false) as bool;

  Future<void> setUpdateDebugChannel(bool value) async {
    await setPref('update_debug_channel', value);
    notifyListeners();
  }

  // ── bookmarks flag ───────────────────────────────────────────────────

  bool get populateBookmarksFlag =>
      getPref('populate_bookmarks', defaultValue: false) as bool;

  void setPopulateBookmarksFlag() async {
    await setPref('populate_bookmarks', true);
  }

  // ── blur options ─────────────────────────────────────────────────────

  static const _defaultBlurJson =
      '{"w":200,"h":200,"l":-1,"t":-1,"r":0,"g":0,"b":0,"o":0,"br":5,"v":false}';

  BlurOptions get blurOptions {
    final String raw =
        getPref('blur_options_json', defaultValue: _defaultBlurJson) as String;
    try {
      final Map<String, dynamic> m =
          Map<String, dynamic>.from(jsonDecode(raw) as Map);
      return BlurOptions(
        width: (m['w'] as num).toDouble(),
        height: (m['h'] as num).toDouble(),
        left: (m['l'] as num).toDouble(),
        top: (m['t'] as num).toDouble(),
        color: Color.fromRGBO(
          (m['r'] as num).toInt(),
          (m['g'] as num).toInt(),
          (m['b'] as num).toInt(),
          (m['o'] as num).toDouble(),
        ),
        blurRadius: (m['br'] as num).toDouble(),
        visible: m['v'] as bool,
      );
    } catch (_) {
      return BlurOptions(
        width: 200,
        height: 200,
        left: -1,
        top: -1,
        color: Colors.black.withValues(alpha: 0),
        blurRadius: 5,
        visible: false,
      );
    }
  }

  Future<void> setBlurOptions(BlurOptions options) async {
    final String json = jsonEncode(<String, dynamic>{
      'w': options.width,
      'h': options.height,
      'l': options.left,
      't': options.top,
      'r': options.color.red,
      'g': options.color.green,
      'b': options.color.blue,
      'o': options.color.opacity,
      'br': options.blurRadius,
      'v': options.visible,
    });
    await setPref('blur_options_json', json);
    notifyListeners();
  }

  // ── per-media-item audio index ───────────────────────────────────────

  int getMediaItemPreferredAudioIndex(String uniqueKey) =>
      getPref('audio_index/$uniqueKey', defaultValue: 0) as int;

  void setMediaItemPreferredAudioIndex(String uniqueKey, int index) async {
    await setPref('audio_index/$uniqueKey', index);
  }

  // ── anki deck/model selection ────────────────────────────────────────

  String get lastSelectedDeckName =>
      getPref('last_selected_deck', defaultValue: 'Default') as String;

  Future<void> setLastSelectedDeck(String deckName) async {
    await setPref('last_selected_deck', deckName);
  }

  String? get lastSelectedModel => getPref('last_selected_model');

  Future<void> setLastSelectedModelName(String modelName) async {
    await setPref('last_selected_model', modelName);
    notifyListeners();
  }

  // ── low memory mode (raw pref only; side effect in AppModel) ─────────

  bool get lowMemoryMode =>
      getPref('low_memory_mode', defaultValue: false) as bool;
}
