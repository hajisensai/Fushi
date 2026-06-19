import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'package:hibiki/src/media/video/dandanplay_client.dart';
import 'package:hibiki/src/media/video/video_danmaku_model.dart';
import 'package:hibiki/src/media/video/video_control_customization.dart';
import 'package:hibiki/src/media/video/video_immersive_mode.dart';
import 'package:hibiki/src/models/audio_source_config.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:hibiki/src/utils/player/blur_options.dart';

enum DesktopClipboardWindowMode {
  normal('normal'),
  lookup('lookup'),
  always('always');

  const DesktopClipboardWindowMode(this.storageValue);

  final String storageValue;

  static DesktopClipboardWindowMode fromStorage(String value) {
    for (final DesktopClipboardWindowMode mode
        in DesktopClipboardWindowMode.values) {
      if (mode.storageValue == value) return mode;
    }
    return DesktopClipboardWindowMode.normal;
  }
}

/// 视频画面缩放/比例模式（作用于 Flutter 层 [Video] widget 的 [BoxFit]，TODO-152 子B）。
///
/// 与 mpv 内置几何（`video_setting_mpv_aspect`/`zoom`/`panscan`）是两个不同层：这里只决定
/// 解码后的画面如何映射进媒体框，不改 mpv 渲染管线。窗口模式与全屏路由共用本偏好。
/// - [cover]：保持比例铺满媒体框、超出部分裁切（无 letterbox/pillarbox 黑边）。
/// - [contain]：默认。保持比例完整显示，比例不匹配时上下/左右补黑边（画面缩窄时
///   加黑，即用户要的「适应」）。
/// - [fill]：拉伸填满整个媒体框、不保持比例（变形）。
enum VideoFitMode {
  cover('cover'),
  contain('contain'),
  fill('fill');

  const VideoFitMode(this.storageValue);

  final String storageValue;

  static VideoFitMode fromStorage(String value) {
    for (final VideoFitMode mode in VideoFitMode.values) {
      if (mode.storageValue == value) return mode;
    }
    return VideoFitMode.contain;
  }
}

/// 把 [VideoFitMode] 映射成 Flutter [BoxFit]（纯函数，是窗口/全屏 [Video] fit 与单测的
/// 共享真相源）。穷举枚举无 default 分支，新增模式编译期强制补齐。
BoxFit videoFitModeToBoxFit(VideoFitMode mode) {
  switch (mode) {
    case VideoFitMode.cover:
      return BoxFit.cover;
    case VideoFitMode.contain:
      return BoxFit.contain;
    case VideoFitMode.fill:
      return BoxFit.fill;
  }
}

class PreferencesRepository extends ChangeNotifier {
  PreferencesRepository(this._db);

  static const String videoAnime4kPromptShownKey = 'video_anime4k_prompt_shown';

  final HibikiDatabase _db;
  final Map<String, String> _prefCache = {};

  Future<void> loadFromDb() async {
    final all = await _db.getAllPrefs();
    _prefCache
      ..clear()
      ..addAll(all);
    // 启动即把弹幕来源配置推进进程级静态，供播放页里无参构造的 DandanplayClient 读取
    // （它在 prefs 加载后才会被构造，故此处一次推送即可覆盖首次播放）。
    DandanplayConfig.current = DandanplayConfig.decode(
      getPref('video_danmaku_config', defaultValue: '') as String,
    );
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

  // ── yomitan-api server ───────────────────────────────────────────────

  bool get yomitanApiServerEnabled =>
      getPref('yomitan_api_server_enabled', defaultValue: false) as bool;

  Future<void> setYomitanApiServerEnabled(bool value) async {
    await setPref('yomitan_api_server_enabled', value);
    notifyListeners();
  }

  int get yomitanApiPort =>
      getPref('yomitan_api_port', defaultValue: 19633) as int;

  Future<void> setYomitanApiPort(int value) async {
    await setPref('yomitan_api_port', value);
    notifyListeners();
  }

  String get yomitanApiKey =>
      getPref('yomitan_api_key', defaultValue: '') as String;

  Future<void> setYomitanApiKey(String value) async {
    await setPref('yomitan_api_key', value);
    notifyListeners();
  }

  // ── 实验性：键盘/手柄焦点导航 ──────────────────────────────────────────
  // 整套自定义焦点导航（HibikiFocusRoot/Ring + 手柄/方向键焦点移动）默认关闭，
  // 关闭时回退到 Flutter 原生焦点遍历。空格不再确认焦点的行为不受此开关影响。

  bool get experimentalFocusNavigationEnabled =>
      getPref('experimental_focus_navigation_enabled', defaultValue: false)
          as bool;

  Future<void> setExperimentalFocusNavigationEnabled(bool value) async {
    await setPref('experimental_focus_navigation_enabled', value);
    notifyListeners();
  }

  // ── texthooker ───────────────────────────────────────────────────────

  static const String _texthookerDefaultUrls =
      'ws://localhost:6677\nws://localhost:9001\nws://localhost:2333';

  bool get texthookerEnabled =>
      getPref('texthooker_enabled', defaultValue: false) as bool;

  Future<void> setTexthookerEnabled(bool value) async {
    await setPref('texthooker_enabled', value);
    notifyListeners();
  }

  List<String> get texthookerUrls {
    final String raw = getPref(
      'texthooker_urls',
      defaultValue: _texthookerDefaultUrls,
    ) as String;
    return raw
        .split('\n')
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toList();
  }

  Future<void> setTexthookerUrls(List<String> urls) async {
    await setPref('texthooker_urls', urls.join('\n'));
    notifyListeners();
  }

  // ── desktop clipboard lookup ─────────────────────────────────────────

  bool get desktopClipboardEnabled =>
      getPref('desktop_clipboard_enabled', defaultValue: false) as bool;

  Future<void> setDesktopClipboardEnabled(bool value) async {
    await setPref('desktop_clipboard_enabled', value);
    notifyListeners();
  }

  bool get desktopClipboardAlwaysOnTop =>
      desktopClipboardWindowMode != DesktopClipboardWindowMode.normal;

  Future<void> setDesktopClipboardAlwaysOnTop(bool value) async {
    await setDesktopClipboardWindowMode(
      value
          ? DesktopClipboardWindowMode.lookup
          : DesktopClipboardWindowMode.normal,
    );
  }

  DesktopClipboardWindowMode get desktopClipboardWindowMode {
    final String saved = getPref(
      'desktop_clipboard_window_mode',
      defaultValue: '',
    ) as String;
    if (saved.isNotEmpty) {
      return DesktopClipboardWindowMode.fromStorage(saved);
    }
    final bool legacyAlwaysOnTop =
        getPref('desktop_clipboard_always_on_top', defaultValue: false) as bool;
    return legacyAlwaysOnTop
        ? DesktopClipboardWindowMode.lookup
        : DesktopClipboardWindowMode.normal;
  }

  Future<void> setDesktopClipboardWindowMode(
    DesktopClipboardWindowMode value,
  ) async {
    await setPref('desktop_clipboard_window_mode', value.storageValue);
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

  // Default OFF (smooth/animated popup scrolling). Instant (no-animation)
  // jump scrolling is an e-ink opt-in enabled only by the dedicated lookup
  // setting. getPref returns this default solely when the key was never set,
  // so existing users who already toggled the switch keep their stored value.
  bool get popupInstantScroll =>
      getPref('popup_instant_scroll', defaultValue: false) as bool;

  Future<void> setPopupInstantScroll(bool value) async {
    await setPref('popup_instant_scroll', value);
    notifyListeners();
  }

  // TODO-108：查词弹窗显示模式。默认 OFF（跟随被查词位置，即现状的左/右/上/下避让）。
  // ON 时弹窗固定为屏幕底部一条全宽面板，忽略选区位置——适合需要稳定固定弹窗落点的
  // 用户。getPref 仅在 key 从未写过时返回默认 false，已切过开关的用户保留其存值。
  bool get popupBottomDocked =>
      getPref('popup_bottom_docked', defaultValue: false) as bool;

  Future<void> setPopupBottomDocked(bool value) async {
    await setPref('popup_bottom_docked', value);
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

  bool get startupDefaultDictionaryTab =>
      getPref('startup_default_dictionary_tab', defaultValue: false) as bool;

  Future<void> setStartupDefaultDictionaryTab(bool value) async {
    await setPref('startup_default_dictionary_tab', value);
    notifyListeners();
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

  /// 启用的 mpv 着色器（JSON 字符串数组的文件名，相对着色器目录）。空串=未启用。
  /// 解析/编码见 video_shader_manager.dart 的 encode/decodeEnabledShaders。
  String get videoShadersEnabled =>
      getPref('video_shaders_enabled', defaultValue: '') as String;

  Future<void> setVideoShadersEnabled(String json) async {
    await setPref('video_shaders_enabled', json);
    notifyListeners();
  }

  /// 用户手动指定的本机 mpv 配置/着色器目录（「从本机 mpv 导入」自动找不到时指定后
  /// 记住，下次优先扫它）。空串=未指定，走自动候选目录。
  String get videoMpvShaderDir =>
      getPref('video_mpv_shader_dir', defaultValue: '') as String;

  Future<void> setVideoMpvShaderDir(String dir) async {
    await setPref('video_mpv_shader_dir', dir);
    notifyListeners();
  }

  /// 视频字幕模糊（听力沉浸）开关：默认关闭。开启后字幕默认打码，悬停/点击显形。
  bool get videoSubtitleBlur =>
      getPref('video_subtitle_blur', defaultValue: false) as bool;

  Future<void> setVideoSubtitleBlur(bool value) async {
    await setPref('video_subtitle_blur', value);
    notifyListeners();
  }

  /// 视频弹幕 overlay 开关：默认开启，只在有本地/在线弹幕源时显示。
  bool get videoDanmakuEnabled =>
      getPref('video_danmaku_enabled', defaultValue: true) as bool;

  Future<void> setVideoDanmakuEnabled(bool value) async {
    await setPref('video_danmaku_enabled', value);
    notifyListeners();
  }

  /// 是否在本地 sidecar 不可用时尝试在线 Dandanplay 精确匹配。
  bool get videoDanmakuOnlineEnabled =>
      getPref('video_danmaku_online_enabled', defaultValue: true) as bool;

  Future<void> setVideoDanmakuOnlineEnabled(bool value) async {
    await setPref('video_danmaku_online_enabled', value);
    notifyListeners();
  }

  int get videoDanmakuMaxActive => normalizeVideoDanmakuMaxActive(
        getPref(
          'video_danmaku_max_active',
          defaultValue: kDefaultVideoDanmakuMaxActive,
        ) as int,
      );

  Future<void> setVideoDanmakuMaxActive(int value) async {
    await setPref(
      'video_danmaku_max_active',
      normalizeVideoDanmakuMaxActive(value),
    );
    notifyListeners();
  }

  /// Dandanplay 弹幕来源配置（自建服务器地址 + 可选 API 凭据，JSON；见
  /// [DandanplayConfig]）。读时同步推送进程级 [DandanplayConfig.current]，使无参
  /// 构造的 [DandanplayClient]（播放页里）立即吃到配置，无需改播放页的构造调用点。
  DandanplayConfig get videoDanmakuConfig {
    final DandanplayConfig config = DandanplayConfig.decode(
      getPref('video_danmaku_config', defaultValue: '') as String,
    );
    DandanplayConfig.current = config;
    return config;
  }

  Future<void> setVideoDanmakuConfig(DandanplayConfig config) async {
    DandanplayConfig.current = config;
    await setPref('video_danmaku_config', DandanplayConfig.encode(config));
    notifyListeners();
  }

  int? getVideoDanmakuEpisodeId(String bookUid) {
    final int value = getPref(
      'video_danmaku_episode/$bookUid',
      defaultValue: 0,
    ) as int;
    return value > 0 ? value : null;
  }

  Future<void> setVideoDanmakuEpisodeId(String bookUid, int episodeId) async {
    await setPref('video_danmaku_episode/$bookUid', episodeId);
  }

  /// 桌面视频页按视频原始比例锁定原生窗口；移动端窗口不可改尺寸，不使用此项。
  ///
  /// 默认 false（回归修复）：用户没要求时不主动把 app 窗口尺寸贴成视频宽高比，
  /// 视频区适配走 [videoFitMode] 的 BoxFit；想锁窗口比例的用户可在设置里手动开启。
  bool get videoLockWindowAspectRatio =>
      getPref('video_lock_window_aspect_ratio', defaultValue: false) as bool;

  Future<void> setVideoLockWindowAspectRatio(bool value) async {
    await setPref('video_lock_window_aspect_ratio', value);
    notifyListeners();
  }

  /// 视频画面缩放/比例模式（窗口模式 + 全屏的 [Video] fit；默认 [VideoFitMode.contain]
  /// = 保持比例完整适应媒体框；已有 cover/fill 持久化值仍按原值恢复）。
  VideoFitMode get videoFitMode => VideoFitMode.fromStorage(
        getPref('video_fit_mode',
            defaultValue: VideoFitMode.contain.storageValue) as String,
      );

  Future<void> setVideoFitMode(VideoFitMode mode) async {
    await setPref('video_fit_mode', mode.storageValue);
    notifyListeners();
  }

  String get videoAsbplayerConfig =>
      getPref('video_asbplayer_config', defaultValue: '') as String;

  Future<void> setVideoAsbplayerConfig(String json) async {
    await setPref('video_asbplayer_config', json);
    notifyListeners();
  }

  VideoControlCustomization get videoControlCustomization =>
      VideoControlCustomization.decode(
        getPref('video_control_customization', defaultValue: '') as String,
      );

  Future<void> setVideoControlCustomization(
    VideoControlCustomization customization,
  ) async {
    await setPref('video_control_customization', customization.encode());
    notifyListeners();
  }

  /// 视频控制按钮 9-槽位布局（TODO-274/312 phase 2）。与 legacy
  /// [videoControlCustomization] 共用同一持久化键 `video_control_customization`：
  /// [VideoControlLayout.decode] 自动识别 v1（旧三档 placements）并迁移成 v2 槽位，
  /// 故老用户配置无损升级、不需要新 schema。新写入一律是 v2 JSON。
  VideoControlLayout get videoControlLayout => VideoControlLayout.decode(
        getPref('video_control_customization', defaultValue: '') as String,
      );

  Future<void> setVideoControlLayout(VideoControlLayout layout) async {
    await setPref('video_control_customization', layout.encode());
    notifyListeners();
  }

  /// 视频字幕外观（JSON；解析见 VideoSubtitleStyle.encode/decode）。空串=默认外观。
  String get videoSubtitleStyle =>
      getPref('video_subtitle_style', defaultValue: '') as String;

  Future<void> setVideoSubtitleStyle(String json) async {
    await setPref('video_subtitle_style', json);
    notifyListeners();
  }

  /// 视频 mpv 配置（JSON；解析见 VideoMpvConfig.encode/decode）。空串=默认全 mpv 默认值。
  String get videoMpvConfig =>
      getPref('video_mpv_config', defaultValue: '') as String;

  Future<void> setVideoMpvConfig(String json) async {
    await setPref('video_mpv_config', json);
    notifyListeners();
  }

  /// 侧边锁进入后的沉浸交互级别。旧库没有该 key 时默认仅查词，不需要迁移。
  VideoImmersiveMode get videoImmersiveMode => VideoImmersiveMode.fromStorage(
        getPref(
          'video_immersive_mode',
          defaultValue: VideoImmersiveMode.fallback.storageValue,
        ) as String,
      );

  Future<void> setVideoImmersiveMode(VideoImmersiveMode mode) async {
    await setPref('video_immersive_mode', mode.storageValue);
    notifyListeners();
  }

  /// Whether the first-use Anime4K recommendation prompt has been shown.
  bool get videoAnime4kPromptShown =>
      getPref(videoAnime4kPromptShownKey, defaultValue: false) as bool;

  Future<void> setVideoAnime4kPromptShown() async {
    await setPref(videoAnime4kPromptShownKey, true);
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
    // 纯新装（typed config 与 legacy audio_sources 两个 pref 都未写过）下，内置的
    // 远端音频源（hoshi-reader.manhhaoo worker）默认**关闭**：第三方私有远端服务不
    // 应未经用户同意就默认参与查词发音。一旦用户存过任一 pref（老用户/已配置过），
    // 走下面的 legacy 装配，按其保存值原样还原（fromLegacyUrls 默认 enabled，保留
    // 老用户已启用的 URL，向后兼容）。
    if (!containsKey('audio_source_configs') && !containsKey('audio_sources')) {
      return _withDefaultAudioSources(_defaultDisabledRemoteSources());
    }
    return _withDefaultAudioSources(
      AudioSourceConfig.fromLegacyUrls(audioSources),
    );
  }

  /// 新装默认远端音频源装配：把 [defaultAudioSources] 的 URL 装成 remoteAudio，但
  /// 全部标记为 disabled（新装默认不启用第三方远端发音）。
  List<AudioSourceConfig> _defaultDisabledRemoteSources() {
    return AudioSourceConfig.fromLegacyUrls(defaultAudioSources)
        .map((AudioSourceConfig source) => source.copyWith(enabled: false))
        .toList();
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

  bool get floatingLyricClickLookup =>
      getPref('floating_lyric_click_lookup', defaultValue: true) as bool;

  Future<void> setFloatingLyricClickLookup(bool value) async {
    await setPref('floating_lyric_click_lookup', value);
    notifyListeners();
  }

  // TODO-370: 悬浮字幕「按钮底色透明度」+「文字透明度」自定义。两值都是 0..100 的
  // 百分比，作用于基础 ARGB 的 alpha 通道——100 = 保持各主题原有观感（默认），调小变更
  // 透明。按钮底色基色按主题（深色白/浅色黑）随明暗变，故用百分比缩放其原 alpha 保证
  // 默认 100 时与历史像素一致；文字 alpha 默认满（100）。

  static int normalizeFloatingLyricOpacity(num value) =>
      value.round().clamp(0, 100).toInt();

  int get floatingLyricButtonBgOpacity => normalizeFloatingLyricOpacity(
        getPref('floating_lyric_button_bg_opacity', defaultValue: 100) as int,
      );

  Future<void> setFloatingLyricButtonBgOpacity(int value) async {
    await setPref(
      'floating_lyric_button_bg_opacity',
      normalizeFloatingLyricOpacity(value),
    );
    notifyListeners();
  }

  int get floatingLyricTextOpacity => normalizeFloatingLyricOpacity(
        getPref('floating_lyric_text_opacity', defaultValue: 100) as int,
      );

  Future<void> setFloatingLyricTextOpacity(int value) async {
    await setPref(
      'floating_lyric_text_opacity',
      normalizeFloatingLyricOpacity(value),
    );
    notifyListeners();
  }

  // TODO-576: 悬浮字幕/歌词条「背景透明度」自定义（0..100 百分比），作用于条本身的
  // 背景 ARGB alpha 通道。用户反馈默认背景太不透明、挡视野，故默认下调到 70（≈背景
  // 230/220 alpha ×0.7），既明显更透又保持可读；调小更透，调大更实。
  int get floatingLyricBgOpacity => normalizeFloatingLyricOpacity(
        getPref('floating_lyric_bg_opacity', defaultValue: 70) as int,
      );

  Future<void> setFloatingLyricBgOpacity(int value) async {
    await setPref(
      'floating_lyric_bg_opacity',
      normalizeFloatingLyricOpacity(value),
    );
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
