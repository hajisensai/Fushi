import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/manga/manga_view_prefs.dart';
import 'package:fushi/src/media/torrent/anime_download_config.dart';
import 'package:fushi/src/media/video/dandanplay_client.dart';
import 'package:fushi/src/media/video/video_danmaku_model.dart';
import 'package:fushi/src/media/video/video_control_customization.dart';
import 'package:fushi/src/media/video/video_immersive_mode.dart';
import 'package:fushi/src/media/video/video_subtitle_obscure_mode.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/immersion_mining_request.dart'
    show MiningAnimatedFormat, VideoMiningImageMode;
import 'package:fushi/src/models/audio_source_config.dart';
import 'package:fushi/src/utils/misc/desktop_audio_clipper.dart'
    show MiningMediaCompression;
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/update_check_cache.dart';

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

/// 剪贴板查词去向（spec 2026-07-10 剪贴板独立弹窗）：
/// panel = 常驻悬浮面板（覆盖窗第二实例，仅 Windows，**默认**——用户 2026-07-10
/// 拍板：默认独立窗口而非主窗口）；main = 主窗查词 tab；transient = 光标处
/// 瞬态弹卡（复用全局查词覆盖窗，仅 Windows）。
/// 未知/空存值回退 panel（=默认）。非 Windows 平台覆盖窗不可用，去向路由
/// （resolveDesktopLookupConsumer）自动退回主窗 tab，行为不变。
enum DesktopClipboardDestination {
  main('main'),
  panel('panel'),
  transient('transient'),

  /// 真透明剪切板文字窗：剪贴板文本落进逐像素透明的悬浮文字窗（复用
  /// FloatingLyricWindow 第二实例，text-only），背景默认全透只露实心文字，点字
  /// 弹瞬态查词卡。VN/游戏 + Textractor 自动复制场景。Windows-only。
  textWindow('textWindow');

  const DesktopClipboardDestination(this.storageValue);

  final String storageValue;

  static DesktopClipboardDestination fromStorage(String value) {
    for (final DesktopClipboardDestination d
        in DesktopClipboardDestination.values) {
      if (d.storageValue == value) return d;
    }
    return DesktopClipboardDestination.panel;
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

  /// TODO-855: persisted monotonic counter, the cross-process change signal the
  /// separate :popup process reads via [readPrefsVersionFromDb] to decide
  /// whether to reload its warm-reuse pref cache, instead of unconditionally
  /// re-scanning the whole preferences table on every lookup. The bump itself
  /// lives at the single lowest write choke point [HibikiDatabase.setPref], so
  /// EVERY writer (this repository, ThemeNotifier, MediaSource, profile switch,
  /// sync/backup restore) advances it automatically. This is an alias to that
  /// DB-layer key so app-layer call sites (ProfileKeys, tests) share one truth.
  /// Excluded from profile snapshots (see ProfileKeys) so it stays app-global
  /// and monotonic.
  static const String prefsVersionKey = HibikiDatabase.prefsVersionKey;

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
    // [HibikiDatabase.setPref] also bumps the persisted prefs-version (TODO-855)
    // for any key other than the version key itself; no explicit bump needed
    // here. The in-memory [prefsVersion] getter intentionally does NOT track
    // that same-process bump — change detection is cross-process and goes
    // through [readPrefsVersionFromDb] / a full [loadFromDb] reload.
    await _db.setPref(key, strVal);
  }

  /// 一个**逻辑设置**由多个 key 承载时（三态投影成两个 bool 键、值 + 判别键……）的写入
  /// 入口：全部 key 一次性进内存缓存、再走 [HibikiDatabase.setPrefs] 的**单事务**落盘。
  ///
  /// 对比逐个 [setPref]：省掉每键一次事务提交（Windows/WAL 实测 12.3ms → 5.1ms），并且
  /// 消除「半个设置已落盘」的可观察窗口——:popup 进程不会读到 blur=true / hide 尚未写入
  /// 的中间态。同样重要的是**同步段**：返回的 Future 之前，缓存里所有 key 已是新值，故
  /// 调用方可以先刷 UI 再落盘，getter 立即返回一致的完整设置。
  Future<void> setPrefs(Map<String, dynamic> values) async {
    final Map<String, String> encoded = <String, String>{
      for (final MapEntry<String, dynamic> e in values.entries)
        e.key: PrefCodec.encode(e.value),
    };
    _prefCache.addAll(encoded);
    await _db.setPrefs(encoded);
  }

  /// The prefs-version value currently held in this process's in-memory cache,
  /// as last populated by [loadFromDb]/[refreshFromDb] (0 when never loaded).
  /// Cheap synchronous read; NOT a cross-process check and NOT advanced by this
  /// process's own [setPref] calls (the bump is sunk into the DB layer and only
  /// re-enters the cache on the next full reload). [AppModel] uses it solely to
  /// prime its watermark right after a reload; live change detection goes
  /// through [readPrefsVersionFromDb]. Stored as a PrefCodec int, so
  /// [PrefCodec.decode] tolerates both the tagged (`i:N`) and legacy raw (`N`)
  /// form.
  int get prefsVersion {
    final String? raw = _prefCache[prefsVersionKey];
    return raw == null ? 0 : PrefCodec.decode<int>(raw, 0);
  }

  /// Read the prefs-version straight from the DB (single indexed row lookup),
  /// bypassing this process's in-memory cache. The :popup process uses this to
  /// detect that the main app mutated a preference or switched profile while the
  /// warm-reuse popup was alive, without a full preferences-table reload.
  Future<int> readPrefsVersionFromDb() async {
    final String? raw = await _db.getPref(prefsVersionKey);
    return raw == null ? 0 : PrefCodec.decode<int>(raw, 0);
  }

  bool containsKey(String key) => _prefCache.containsKey(key);

  // ── player preferences ───────────────────────────────────────────────

  bool get playerHardwareAcceleration =>
      getPref('player_hardware_acceleration', defaultValue: true) as bool;

  void setPlayerHardwareAcceleration({required bool value}) async {
    await setPref('player_hardware_acceleration', value);
    notifyListeners();
  }

  /// TODO-702：有声书「退出阅读页后是否继续后台播放」。默认 **false** = 退出即停
  /// （detachReader 卸回调后 [AudiobookSession.stop] 真正止声/释放解码器，符合多数
  /// 用户「关掉书就别再响」的预期）。开启后退书只 detachReader、会话留在进程级常驻
  /// 持有者里继续后台播放（保 TODO-291 阶段2 的后台续播能力）。这是独立的偏好，
  /// **不复用**旧 `player_background_play` 死 pref（其代码通道已删除，复用会把语义
  /// 搅混）。getPref 仅在 key 从未写过时返回默认 false，已切过开关的用户保留其存值。
  bool get audiobookBackgroundPlay =>
      getPref('audiobook_background_play', defaultValue: false) as bool;

  Future<void> setAudiobookBackgroundPlay({required bool value}) async {
    await setPref('audiobook_background_play', value);
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

  // TODO-861②（移植 Hoshi `07b5c09`）：是否扫描非日文文本进选区/查词。默认 true =
  // 现状（注入端原硬编码 true）。关闭时选区遇非日文码点即停（见
  // reader_selection_scripts.dart 的 isDelimiter 消费端）。
  bool get scanNonJapaneseText =>
      getPref('scan_non_japanese_text', defaultValue: true) as bool;

  Future<void> setScanNonJapaneseText(bool value) async {
    await setPref('scan_non_japanese_text', value);
    notifyListeners();
  }

  // ── dictionary auto-update (TODO-861③, ported from Hoshi 94d0c41) ────
  //
  // 启动时 check-due 自动更新词典。interval 存 enum `.name`（daily/weekly/monthly），
  // lastUpdate 存上次完整成功检查的 ISO8601 字符串（'' = 从未成功检查）。沿用既有
  // 持久化 key 兼容旧数据。默认 autoUpdate=false（opt-in，
  // 向后兼容，不在升级后静默联网/自动下载重导词典；用户须主动开启）、weekly。
  // MVP 只做启动 check-due，无计费网络门控（本仓库无 connectivity 依赖）。

  bool get autoUpdateDictionaries =>
      getPref('auto_update_dictionaries', defaultValue: false) as bool;

  Future<void> setAutoUpdateDictionaries(bool value) async {
    await setPref('auto_update_dictionaries', value);
    notifyListeners();
  }

  /// 检查周期的持久化 `.name`（daily/weekly/monthly）。默认 'weekly'。
  String get dictionaryUpdateIntervalName =>
      getPref('dictionary_update_interval', defaultValue: 'weekly') as String;

  Future<void> setDictionaryUpdateIntervalName(String name) async {
    await setPref('dictionary_update_interval', name);
    notifyListeners();
  }

  /// 上次完整成功检查时间（ISO8601）；解析失败/未设 → null（= 从未成功检查）。
  DateTime? get lastDictionaryUpdateAt {
    final String raw =
        getPref('last_dictionary_update_at', defaultValue: '') as String;
    if (raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  Future<void> setLastDictionaryUpdateAt(DateTime when) async {
    await setPref('last_dictionary_update_at', when.toIso8601String());
    notifyListeners();
  }

  // ── 库页排序方式（排序交互重设计 2026-07-12）──────────────────────────

  /// 书架排序方式 `.name`（recent/title/imported）。默认 recent（=历史序，现状零变化）。
  String get shelfSortModeName =>
      getPref('shelf_sort_mode', defaultValue: 'recent') as String;

  Future<void> setShelfSortModeName(String name) async {
    await setPref('shelf_sort_mode', name);
    notifyListeners();
  }

  /// 视频库排序方式 `.name`。默认 recent（最近观看，用户拍板；一键可切回导入时间）。
  String get videoSortModeName =>
      getPref('video_sort_mode', defaultValue: 'recent') as String;

  Future<void> setVideoSortModeName(String name) async {
    await setPref('video_sort_mode', name);
    notifyListeners();
  }

  /// 已折叠的合集横排行 collectionId 集（书架/视频页共用；折叠 = 行只剩行头）。
  /// 逗号串存储；解析对空串/脏值宽容（tryParse 过滤）。
  Set<int> get collapsedCollectionIds {
    final String raw =
        getPref('collapsed_collection_ids', defaultValue: '') as String;
    return <int>{
      for (final String part in raw.split(','))
        if (int.tryParse(part) case final int id) id,
    };
  }

  Future<void> setCollapsedCollectionIds(Set<int> ids) async {
    final List<int> sorted = ids.toList()..sort();
    await setPref('collapsed_collection_ids', sorted.join(','));
    notifyListeners();
  }

  /// 游戏库合集横排行的折叠集（独立命名空间：同一个合集在书架折叠不应连带游戏库
  /// 折叠，两页各记各的）。存储格式与 [collapsedCollectionIds] 相同。
  Set<int> get gamesCollapsedCollectionIds {
    final String raw =
        getPref('games_collapsed_collection_ids', defaultValue: '') as String;
    return <int>{
      for (final String part in raw.split(','))
        if (int.tryParse(part) case final int id) id,
    };
  }

  Future<void> setGamesCollapsedCollectionIds(Set<int> ids) async {
    final List<int> sorted = ids.toList()..sort();
    await setPref('games_collapsed_collection_ids', sorted.join(','));
    notifyListeners();
  }

  /// 多端库联合视图（spec 2026-07-12 §2.1/§2.4）：书架/视频页主网格是否把「远端有、
  /// 本地无」的条目渲染成占位卡（云角标 + 远端封面，点击下载/流播）。**默认 true**——
  /// 用户拍板远端混排默认开。关闭时占位卡全部不渲染，两页只剩本地库。离线/未配对/
  /// 后端不可达时占位卡本就不出现（远端目录拉取失败态），与本开关正交。
  bool get showRemoteEntries =>
      getPref('show_remote_entries', defaultValue: true) as bool;

  Future<void> setShowRemoteEntries(bool value) async {
    await setPref('show_remote_entries', value);
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

  // ── galgame 游戏库（首页「游戏」tab）─────────────────────────────────────

  /// legacy：v55 之前用户添加的 galgame 列表（单一 JSON 数组落 KV 表）。
  ///
  /// 真相源自 v55 起是 Drift 表 `galgames`（迁移已一次性回填，见契约 §1.7），app 侧
  /// 读写走 `GalgameRepository`。这两个访问器**只**留作回滚兜底/诊断，新代码别再用。
  List<GalgameEntry> get legacyGalgames => decodeGalgameLibrary(
      getPref('galgame_library', defaultValue: '') as String);

  /// 见 [legacyGalgames]。
  Future<void> setLegacyGalgames(List<GalgameEntry> games) async {
    await setPref('galgame_library', encodeGalgameLibrary(games));
    notifyListeners();
  }

  /// 游戏库页的排序/筛选视图偏好（`GalgameLibraryView.encode()` 的 JSON 串）。
  /// 空串 = 默认视图。走现有偏好体系，不为一个视图状态新建表。
  String get galgameLibraryView =>
      getPref('galgame_library_view', defaultValue: '') as String;

  Future<void> setGalgameLibraryView(String encoded) async {
    await setPref('galgame_library_view', encoded);
    notifyListeners();
  }

  // ── desktop clipboard lookup ─────────────────────────────────────────

  /// 桌面剪贴板查词是否开启。默认 true：galgame UX 统一后，剪贴板 / galgame 台词都走同一条
  /// 查词去向路由（默认落悬浮查词面板），故桌面开箱即用无需先手动开开关。
  bool get desktopClipboardEnabled =>
      getPref('desktop_clipboard_enabled', defaultValue: true) as bool;

  Future<void> setDesktopClipboardEnabled(bool value) async {
    await setPref('desktop_clipboard_enabled', value);
    notifyListeners();
  }

  /// 剪切板复制后是否自动查词（默认 true=保持现状）。false 时剪切板面板只显示
  /// 复制到的句子文字（逐字可点），不自动 [searchDictionary]、不弹释义、不朗读；
  /// 用户点句中字才手动查（走面板既有 panelSentenceLookup 桥）。总开关
  /// [desktopClipboardEnabled] 仍决定「是否监听剪切板」，本开关只决定「监听到之后
  /// 自不自动查词」，两者正交。
  bool get desktopClipboardAutoLookup =>
      getPref('desktop_clipboard_auto_lookup', defaultValue: true) as bool;

  Future<void> setDesktopClipboardAutoLookup(bool value) async {
    await setPref('desktop_clipboard_auto_lookup', value);
    notifyListeners();
  }

  // TODO-1030 M0 — 全局查词（应用外）是否抓取选中文本周围的上下文句。默认 false：
  // 抓取要读前台应用的 UIA 文本，隐私敏感，用户显式开启才启用；关闭时全局查词只用
  // 剪贴板拿到的纯选中串（现状），不接触前台应用文本。
  bool get globalContextCaptureEnabled =>
      getPref('lookup.global_context_capture', defaultValue: false) as bool;

  Future<void> setGlobalContextCaptureEnabled(bool value) async {
    await setPref('lookup.global_context_capture', value);
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

  DesktopClipboardDestination get desktopClipboardDestination =>
      DesktopClipboardDestination.fromStorage(getPref(
        'desktop_clipboard_destination',
        defaultValue: '',
      ) as String);

  Future<void> setDesktopClipboardDestination(
    DesktopClipboardDestination value,
  ) async {
    await setPref('desktop_clipboard_destination', value.storageValue);
    notifyListeners();
  }

  // spec §6 真机修正（2026-07-10 第二轮）：透明机制改整窗 LWA_ALPHA（真透视，
  // 整窗含文字统一变淡）。85% 是「能看清底下游戏 + 面板正文可读」的平衡点；
  // 滑杆 50%-100% 可调。
  final double defaultClipboardPanelOpacity = 0.85;

  double get clipboardPanelOpacity => getPref('clipboard_panel_opacity',
      defaultValue: defaultClipboardPanelOpacity) as double;

  Future<void> setClipboardPanelOpacity(double value) async {
    await setPref('clipboard_panel_opacity', value);
    notifyListeners();
  }

  /// 真透明剪切板文字窗的**背景**不透明度。与 [clipboardPanelOpacity]（整窗
  /// LWA_ALPHA）不同：这里只影响窗口背景 alpha，文字始终实心。**默认 1.0 = 黑底**
  /// （用户实测拍板「先一律默认黑底白字」——纯透明+跟随主题的深色字在黑底上看不清）；
  /// 想要真透明把滑杆拉到 0（或点顶栏一键透明 ◐），文字始终白色实心。
  double get clipboardTextWindowBgOpacity => getPref(
        'clipboard_text_window_bg_opacity',
        defaultValue: 1.0,
      ) as double;

  Future<void> setClipboardTextWindowBgOpacity(double value) async {
    await setPref('clipboard_text_window_bg_opacity', value);
    notifyListeners();
  }

  /// 面板窗位置/尺寸记忆，格式 `x,y,w,h`（逻辑像素）；空 = 从未摆放（用默认位）。
  String get clipboardPanelRect =>
      getPref('clipboard_panel_rect', defaultValue: '') as String;

  Future<void> setClipboardPanelRect(String value) async {
    await setPref('clipboard_panel_rect', value);
    notifyListeners();
  }

  bool get clipboardPanelPinned =>
      getPref('clipboard_panel_pinned', defaultValue: true) as bool;

  Future<void> setClipboardPanelPinned(bool value) async {
    await setPref('clipboard_panel_pinned', value);
    notifyListeners();
  }

  /// 防截屏（剪贴板面板，Windows）—— 面板窗设 SetWindowDisplayAffinity
  /// (WDA_EXCLUDEFROMCAPTURE)，对用户可见但从截图 / 录屏 / 屏幕共享排除。
  /// 默认 false（用户要求默认关闭，2026-07；需要时面板栏 🛡 按钮或设置里打开）。
  bool get clipboardPanelBlockCapture =>
      getPref('clipboard_panel_block_capture', defaultValue: false) as bool;

  Future<void> setClipboardPanelBlockCapture(bool value) async {
    await setPref('clipboard_panel_block_capture', value);
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

  // 查词弹窗尺寸精细化（2026-07-13 设计）：app 外覆盖窗 / 浏览器扩展各自可「独立尺寸」。
  // 默认 independent=false → 跟随 app 内 popupMaxWidth/Height；用户显式解锁后用各自键。
  // 各自宽/高默认值等于 app 内默认（400×360），保证解锁瞬间不跳尺寸。

  bool get overlayLookupIndependentSize =>
      getPref('overlay_lookup_independent_size', defaultValue: false) as bool;

  Future<void> setOverlayLookupIndependentSize(bool value) async {
    await setPref('overlay_lookup_independent_size', value);
    notifyListeners();
  }

  double get overlayLookupMaxWidth =>
      getPref('overlay_lookup_max_width', defaultValue: defaultPopupMaxWidth)
          as double;

  void setOverlayLookupMaxWidth(double width) async {
    await setPref('overlay_lookup_max_width', width);
    notifyListeners();
  }

  double get overlayLookupMaxHeight =>
      getPref('overlay_lookup_max_height', defaultValue: defaultPopupMaxHeight)
          as double;

  void setOverlayLookupMaxHeight(double height) async {
    await setPref('overlay_lookup_max_height', height);
    notifyListeners();
  }

  bool get extensionPopupIndependentSize =>
      getPref('extension_popup_independent_size', defaultValue: false) as bool;

  Future<void> setExtensionPopupIndependentSize(bool value) async {
    await setPref('extension_popup_independent_size', value);
    notifyListeners();
  }

  double get extensionPopupMaxWidth =>
      getPref('extension_popup_max_width', defaultValue: defaultPopupMaxWidth)
          as double;

  void setExtensionPopupMaxWidth(double width) async {
    await setPref('extension_popup_max_width', width);
    notifyListeners();
  }

  double get extensionPopupMaxHeight =>
      getPref('extension_popup_max_height', defaultValue: defaultPopupMaxHeight)
          as double;

  void setExtensionPopupMaxHeight(double height) async {
    await setPref('extension_popup_max_height', height);
    notifyListeners();
  }

  // TODO-776: number of dictionary blocks rendered per row inside one entry's
  // glossary section (experimental). Default 1 = the classic single vertical
  // column; clamped to 1..4 both on read and write so a corrupt/out-of-range
  // stored value can never reach the CSS grid as an absurd column count.
  int get popupDictionaryColumns =>
      (getPref('popup_dictionary_columns', defaultValue: 1) as int).clamp(1, 4);

  /// TODO-1357: 用户是否显式设过弹窗列数。区分「从未设→用平台默认（桌面 2 / 移动 1，
  /// 在 [AppModel.popupDictionaryColumns] 解析）」与「显式设过→遵从其值」（三态）。
  bool get hasExplicitPopupDictionaryColumns =>
      containsKey('popup_dictionary_columns');

  Future<void> setPopupDictionaryColumns(int columns) async {
    await setPref('popup_dictionary_columns', columns.clamp(1, 4));
    notifyListeners();
  }

  // TODO-845: how many leading *rows* of dictionary blocks the lookup popup
  // auto-expands (force-open <details>) even when "collapse dictionaries" is on.
  // The unit is rows, not blocks: popup.js expands `rows × effective columns`
  // (see autoExpandCount there), so the expanded region is always whole top rows
  // and never fights the --dict-columns masonry. Default 1 preserves the
  // historical "only the first dictionary is expanded" behaviour, because the
  // default column count is 1 (1 row × 1 column === 1 block).
  //
  // The storage key keeps its legacy `popup_auto_expand_dictionaries` name so
  // existing stored values carry over untouched. Clamped to 0..6 on read and
  // write so a corrupt/out-of-range stored value can never reach popup.js as an
  // absurd expand threshold; the clamp range is identical to the lookup settings
  // slider min/max.
  int get popupAutoExpandDictionaries =>
      (getPref('popup_auto_expand_dictionaries', defaultValue: 1) as int)
          .clamp(0, 6);

  /// TODO-1357: 用户是否显式设过自动展开词典数（三态，同 [hasExplicitPopupDictionaryColumns]）。
  bool get hasExplicitPopupAutoExpandDictionaries =>
      containsKey('popup_auto_expand_dictionaries');

  Future<void> setPopupAutoExpandDictionaries(int count) async {
    await setPref('popup_auto_expand_dictionaries', count.clamp(0, 6));
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

  // BUG-1026：查词弹窗滚轮速度倍率。popup.js 的粗鼠标 notch 用 0.24 降速系数（BUG-260），
  // 部分用户觉得太慢；此倍率乘进 popup.js 的 factor（同乘粗鼠标 0.24 与触控板 1.0），
  // 作为统一「滚轮速度」旋钮。默认 1.0 与改前逐帧一致。clamp 0.5–5.0 防越界值把滚动放飞。
  // 一处存储驱动全部弹窗：in-app 三种弹窗经 popup_settings_injection 注入
  // window.__hoshiPopupWheelSpeed；浏览器扩展弹窗经查词响应 theme 的 --hibiki-wheel-speed 下发。
  double get popupWheelSpeed {
    final double v =
        (getPref('popup_wheel_speed', defaultValue: 1.0) as num).toDouble();
    return v.isFinite ? v.clamp(0.5, 5.0) : 1.0;
  }

  Future<void> setPopupWheelSpeed(double value) async {
    final double v = value.isFinite ? value.clamp(0.5, 5.0) : 1.0;
    await setPref('popup_wheel_speed', v);
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
  ///
  /// TODO-840 Part B：这是遮蔽模式三态的**历史 bool 投影**——[VideoSubtitleObscureMode.blur]
  /// / [VideoSubtitleObscureMode.hide] 都让本 getter 返回 true（旧版本回滚读到的就是
  /// 「开着遮蔽」、退化成模糊，不丢遮蔽意图）。真正的精确三态请读
  /// [videoSubtitleObscureMode]；本 getter 只是派生兼容层。
  bool get videoSubtitleBlur =>
      getPref('video_subtitle_blur', defaultValue: false) as bool;

  Future<void> setVideoSubtitleBlur(bool value) async {
    await setPref('video_subtitle_blur', value);
    notifyListeners();
  }

  /// 视频字幕「遮蔽模式」三态（TODO-840 Part B）：不遮蔽 / 模糊 / 隐藏。
  ///
  /// preferences 层 lazy 投影（非新 Drift schema）：历史键 `video_subtitle_blur`
  /// （[VideoSubtitleObscureMode.blurFlag]）+ 判别键 `video_subtitle_obscure_hide`
  /// （[VideoSubtitleObscureMode.hideFlag]）。还原走纯函数
  /// [VideoSubtitleObscureMode.fromFlags]，是读取与单测的共享真相源；写入两键一并落盘，
  /// 使旧版本只读历史键时退化成 blur。
  VideoSubtitleObscureMode get videoSubtitleObscureMode =>
      VideoSubtitleObscureMode.fromFlags(
        blurFlag: getPref('video_subtitle_blur', defaultValue: false) as bool,
        hideFlag:
            getPref('video_subtitle_obscure_hide', defaultValue: false) as bool,
      );

  /// 两个 key 是**同一个**三态设置，故走 [setPrefs] 单事务落盘（省一次事务提交，且
  /// 不留「blur 已落盘、hide 未落盘」的跨进程可观察中间态）。
  ///
  /// **刻意不 [notifyListeners]**（与本类多数 setter 不同，这是有意的例外）：遮蔽模式
  /// 只被视频页字幕层与视频设置面板读取，而 [AppModel] 把本仓库的通知转成全局广播
  /// （`prefsRepo.addListener(notifyListeners)`，且 `BasePageState.appModel` 是
  /// `ref.watch(appProvider)`）——每个 watch 者、包括当前路由下方仍挂载的首页/书架整棵
  /// 树都会跟着重建一次。B / Shift+B / H 是播放中的高频快捷键，为一个字幕开关重建整个
  /// app 正是「切换遮罩模式好卡」的主要成本。两个读取方各有自己的刷新路径：视频页
  /// `_setSubtitleObscureMode` 的 setState、设置面板 `_segmented` 的
  /// `settingsContext.refresh()`。**新增读取方必须自带刷新**，别在这里加回广播。
  Future<void> setVideoSubtitleObscureMode(
    VideoSubtitleObscureMode mode,
  ) async {
    await setPrefs(<String, dynamic>{
      'video_subtitle_blur': mode.blurFlag,
      'video_subtitle_obscure_hide': mode.hideFlag,
    });
  }

  /// 视频**副字幕**「遮蔽模式」三态（TODO-1382，镜像主字幕 [videoSubtitleObscureMode]）：
  /// 不遮蔽 / 模糊 / 隐藏，与主字幕相互独立。preferences 层 lazy 投影（非新 Drift
  /// schema）：键 `video_secondary_subtitle_blur`（[VideoSubtitleObscureMode.blurFlag]）
  /// + 判别键 `video_secondary_subtitle_obscure_hide`（[VideoSubtitleObscureMode.hideFlag]），
  /// 还原走同一纯函数 [VideoSubtitleObscureMode.fromFlags]（读取与单测共享真相源）。
  /// 默认 none：副字幕历史行为=正常显示、不遮蔽。
  VideoSubtitleObscureMode get videoSecondarySubtitleObscureMode =>
      VideoSubtitleObscureMode.fromFlags(
        blurFlag: getPref('video_secondary_subtitle_blur', defaultValue: false)
            as bool,
        hideFlag: getPref('video_secondary_subtitle_obscure_hide',
            defaultValue: false) as bool,
      );

  /// 单事务落盘 + 刻意不广播，理由与主字幕 [setVideoSubtitleObscureMode] 完全同构
  /// （Shift+G / Shift+H 同样是播放中高频快捷键）。
  Future<void> setVideoSecondarySubtitleObscureMode(
    VideoSubtitleObscureMode mode,
  ) async {
    await setPrefs(<String, dynamic>{
      'video_secondary_subtitle_blur': mode.blurFlag,
      'video_secondary_subtitle_obscure_hide': mode.hideFlag,
    });
  }

  /// 视频字幕列表「自动滚动到当前播放句」开关（TODO-613）：默认开启，与
  /// [VideoSubtitleJumpPanel] 头部自动滚动按钮一一对应。旧版本这是面板的纯内存状态、
  /// 每次打开都重置成开；现在落 Drift `preferences`，用户关掉后跨开关 / 跨重启都记住。
  /// getPref 仅在该 key 从未写过时返回默认 true，已切过开关的用户保留其存值。
  bool get videoSubtitleListAutoScroll =>
      getPref('video_subtitle_list_auto_scroll', defaultValue: true) as bool;

  Future<void> setVideoSubtitleListAutoScroll(bool value) async {
    await setPref('video_subtitle_list_auto_scroll', value);
    notifyListeners();
  }

  /// 视频字幕列表**行字号档位**（BUG-878）：档位下标（见 [VideoSubtitleJumpPanel] 的
  /// `_kFontScaleSteps`），默认 1（1.0x）。旧版本这是面板纯内存 State、每次重开都重置成
  /// 默认档；现在落 Drift `preferences`，用户放大后跨开关 / 跨重启都记住。仅在该 key 从未
  /// 写过时返回默认；越界由面板 seed 时 clamp（档位数组扩容后旧存值仍安全）。
  int get videoSubtitleListFontScaleIndex =>
      getPref('video_subtitle_list_font_scale_index', defaultValue: 1) as int;

  Future<void> setVideoSubtitleListFontScaleIndex(int value) async {
    await setPref('video_subtitle_list_font_scale_index', value);
    notifyListeners();
  }

  /// 视频字幕列表**面板宽度**（逻辑像素，BUG-877）：默认 0 = 未自定义，页面按屏宽自适应
  /// （`screenWidth*0.28` 钳制）算宽；用户拖拽面板左边缘把手改宽后存实际像素值，跨开关 /
  /// 跨重启都记住。0 语义即「跟随自适应」，故清除自定义只需存回 0。页面读取时对存值再做
  /// 一次 clamp（防跨设备屏宽差异下存值超出合理范围）。
  double get videoSubtitleListWidth =>
      (getPref('video_subtitle_list_width', defaultValue: 0) as num).toDouble();

  Future<void> setVideoSubtitleListWidth(double value) async {
    await setPref('video_subtitle_list_width', value);
    notifyListeners();
  }

  /// 播放列表自动连播开关（TODO-639）：默认开启。一集播完后，开则倒计时自动进下一集
  /// （倒计时期间可点「取消」按钮停在本集），关则停在本集结束不自动推进。
  /// getPref 仅在该 key 从未写过时返回默认 true，已切过开关的用户保留其存值。
  bool get videoAutoPlayNext =>
      getPref('video_auto_play_next', defaultValue: true) as bool;

  Future<void> setVideoAutoPlayNext(bool value) async {
    await setPref('video_auto_play_next', value);
    notifyListeners();
  }

  /// 视频条目自动刮削开关：默认开启。开则进视频页 / 新视频入库后后台静默拉条目
  /// 资料（封面 + 简介/评分/放送/标签），关则完全不发这些请求（已刮到的资料保留，
  /// 手动「重新刮削」仍可用）。给不希望库信息自动出网的用户一个明确的总闸——
  /// 自动化取代手动按钮后，没有开关就等于没得关。
  ///
  /// ⚠️ 出网面**不止 Bangumi**：`CoverScraperService._resolveBestDecision` 按代价
  /// 逐层兜底 离线库 → Bangumi → TMDB（随包内置 key，无需用户配置）→ AniList →
  /// Jikan/MAL，命中 high 即停。命中早的条目只碰 Bangumi，前几层都没把握的条目会把
  /// 解析出的标题依次发给全部四家。改这条链路时同步改本注释——「只发 Bangumi」的
  /// 旧描述会让用户以为总闸管的是一家。
  /// getPref 仅在该 key 从未写过时返回默认 true。
  bool get videoAutoScrape =>
      getPref('video_auto_scrape', defaultValue: true) as bool;

  Future<void> setVideoAutoScrape(bool value) async {
    await setPref('video_auto_scrape', value);
    notifyListeners();
  }

  /// TODO-1119 / BUG-545：用户是否已在「Windows 黑屏闪烁」运行时提示里点了「不再提示」。
  /// 默认 false = 允许提示。置 true 后播放器不再弹该运行时提示条（静态「已知问题」说明行
  /// 仍在画质设置里）。getPref 仅在该 key 从未写过时返回默认 false。
  bool get videoBlackFlickerNoticeSuppressed =>
      getPref('video_black_flicker_notice_suppressed', defaultValue: false)
          as bool;

  Future<void> setVideoBlackFlickerNoticeSuppressed(bool value) async {
    await setPref('video_black_flicker_notice_suppressed', value);
    notifyListeners();
  }

  /// 视频弹幕 overlay 开关：**默认关闭**，用户显式开启后才显示（且需有本地/在线弹幕源）。
  bool get videoDanmakuEnabled =>
      getPref('video_danmaku_enabled', defaultValue: false) as bool;

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

  /// qBittorrent WebUI 连接配置（地址/账密/分类，JSON；见 [QbConnectionConfig]）。
  /// 番剧下载走外部 qb 实例，本配置为空视为功能未启用。
  QbConnectionConfig? get qbConnectionConfig => decodeQbConnectionConfig(
        getPref('qb_connection_config', defaultValue: '') as String,
      );

  Future<void> setQbConnectionConfig(QbConnectionConfig? config) async {
    await setPref(
      'qb_connection_config',
      config == null ? '' : encodeQbConnectionConfig(config),
    );
    notifyListeners();
  }

  /// 是否已展示过「上传/做种」首用提示（默认 false = 未展示）。首次下载时弹
  /// 一次性对话框提醒上传默认关并询问是否开启（见下载对话框），之后置真不再弹。
  bool get torrentUploadIntroShown =>
      getPref('torrent_upload_intro_shown', defaultValue: false) as bool;

  Future<void> setTorrentUploadIntroShown() async {
    await setPref('torrent_upload_intro_shown', true);
  }

  /// 弹幕样式（字号/不透明度/速度/显示区域，JSON；见 [VideoDanmakuStyle]，TODO-1376）。
  /// 读盘经 [VideoDanmakuStyle.decode] 已 clamp 到合法区间。
  VideoDanmakuStyle get videoDanmakuStyle => VideoDanmakuStyle.decode(
        getPref('video_danmaku_style', defaultValue: '') as String,
      );

  Future<void> setVideoDanmakuStyle(VideoDanmakuStyle style) async {
    await setPref(
      'video_danmaku_style',
      VideoDanmakuStyle.encode(style.normalized()),
    );
    notifyListeners();
  }

  /// 弹幕屏蔽规则原始多行文本（每行一条，`/pattern/` 为正则，其余纯文本子串；
  /// 解析见 [parseVideoDanmakuBlockRules]，TODO-1376）。原样存文本，编译在消费端做。
  String get videoDanmakuBlockRulesText =>
      getPref('video_danmaku_block_rules', defaultValue: '') as String;

  Future<void> setVideoDanmakuBlockRulesText(String value) async {
    await setPref('video_danmaku_block_rules', value);
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

  /// 视频控制按钮 9-槽位布局（TODO-274/312 phase 2）。持久化键
  /// `video_control_customization` 沿用旧三档模型时期的键名：
  /// [VideoControlLayout.decode] 自动识别 v1（旧三档 placements）并迁移成 v2 槽位，
  /// 故老用户配置无损升级、不需要新 schema。新写入一律是 v2/v3 JSON。
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

  /// 是否尊重 .ass 字幕自带样式（字体 / 主色 / 描边 / 阴影，TODO-1105）。**默认 true**——
  /// 用户期望「默认尊重字幕自带样式」；关闭时字幕全走用户统一外观设置。
  bool get videoRespectAssStyle =>
      getPref('video_respect_ass_style', defaultValue: true) as bool;

  Future<void> setVideoRespectAssStyle(bool value) async {
    await setPref('video_respect_ass_style', value);
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

  /// 每系列（番名）记住的 Jimaku 字幕语言偏好：`{ "<series 小写归一>": "<langCode>" }`。
  ///
  /// 单一 JSON map 落 KV 表（避免每系列一个 key 撑爆表）；解析失败回退空 map
  /// （与 [customDictCSS] 同款容错）。
  Map<String, String> get jimakuPreferredLanguages {
    final String raw = getPref('jimaku_pref_langs', defaultValue: '') as String;
    if (raw.isEmpty) return <String, String>{};
    try {
      final dynamic decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((dynamic k, dynamic v) =>
            MapEntry<String, String>(k.toString(), v.toString()));
      }
    } catch (e, stack) {
      ErrorLogService.instance.log(
          'PreferencesRepository.jimakuPreferredLanguages.decode', e, stack);
    }
    return <String, String>{};
  }

  /// 记住某系列（[seriesKey]）选的字幕语言（[langCode]，读改写整 map）。
  Future<void> setJimakuPreferredLanguage(
      String seriesKey, String langCode) async {
    final Map<String, String> map = jimakuPreferredLanguages;
    map[seriesKey] = langCode;
    await setPref('jimaku_pref_langs', jsonEncode(map));
    notifyListeners();
  }

  /// Jimaku 默认字幕语言（`ja` / `zh` / `en` / `ko`；`''` = 不限，按语言权重默认排序）。
  ///
  /// [jimakuPreferredLanguages] 是**每系列**的记忆（用户在某部番里选过就记住那部），
  /// 本项是没有系列记忆时的全局默认，设置页统一配置，字幕对话框 / 番剧下载 /
  /// 批量匹配三处共用。
  String get jimakuDefaultLanguage =>
      getPref('jimaku_default_language', defaultValue: '') as String;

  Future<void> setJimakuDefaultLanguage(String langCode) async {
    await setPref('jimaku_default_language', langCode);
    notifyListeners();
  }

  /// 远端/流媒体视频用户手选的字幕来源（按 `<bookUid>#ep<index>` 记忆）：
  /// `{ "<key>": "<subtitleSource 四态编码>" }`。
  ///
  /// 远端视频没有本地 `VideoBooks` 行可写 `subtitleSource` 列，字幕退出即丢（用户报
  /// 「下载字幕没持久化退出影片就没了」的根因）。这里比照远端播放进度的 prefs 化范式，
  /// 用稳定的 `bookUid`（= `RemoteVideoInfo.id`）+ 集下标做 key 把选择落 KV，重进
  /// `_loadRemoteEpisode` 时优先重放。值是 `_currentSubtitleSource` 的四态编码：
  /// 本地已下载文件绝对路径 / host `subtitleUrl` / `embedded:<n>` / `off:` 哨兵。
  ///
  /// 单一 JSON map 落 KV 表；解析失败回退空 map（与 [jimakuPreferredLanguages] 同款容错）。
  Map<String, String> get remoteSubtitleSources {
    final String raw =
        getPref('video_remote_subtitle', defaultValue: '') as String;
    if (raw.isEmpty) return <String, String>{};
    try {
      final dynamic decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((dynamic k, dynamic v) =>
            MapEntry<String, String>(k.toString(), v.toString()));
      }
    } catch (e, stack) {
      ErrorLogService.instance
          .log('PreferencesRepository.remoteSubtitleSources.decode', e, stack);
    }
    return <String, String>{};
  }

  /// 远端字幕来源的记忆 key：`<bookUid>#ep<index>`。集下标 0（单集/整书）省略 `#ep`
  /// 后缀，与远端播放进度 key 的约定一致，避免单集视频徒增后缀。纯函数，便于单测。
  static String remoteSubtitleKey(String bookUid, int episodeIndex) =>
      episodeIndex > 0 ? '$bookUid#ep$episodeIndex' : bookUid;

  /// 读某远端视频（[bookUid] + [episodeIndex]）记住的字幕来源；无记忆返回 null。
  String? remoteSubtitleSource(String bookUid, {int episodeIndex = 0}) =>
      remoteSubtitleSources[remoteSubtitleKey(bookUid, episodeIndex)];

  /// 记住/清除某远端视频的字幕来源。[source] 为 null 时删除该 key（读改写整 map）。
  Future<void> setRemoteSubtitleSource(
    String bookUid,
    int episodeIndex,
    String? source,
  ) async {
    final Map<String, String> map = remoteSubtitleSources;
    final String key = remoteSubtitleKey(bookUid, episodeIndex);
    if (source == null) {
      if (!map.containsKey(key)) return;
      map.remove(key);
    } else {
      if (map[key] == source) return;
      map[key] = source;
    }
    await setPref('video_remote_subtitle', jsonEncode(map));
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

  // TODO-1650 制卡图片/GIF 清晰度档（0..3，见 [MiningMediaCompression.imageTiers]）。
  // 替代旧的单一「压缩」开关。未显式设过时从旧 `compress_mining_media` 布尔迁移：
  // 开(默认)→标准档 1（= TODO-646 现状，零行为破坏）；关→高清档 2。读写都夹到 0..3，
  // 防止损坏/越界值进到底层编码。
  int get miningImageQuality {
    final int? explicit =
        getPref('mining_image_quality', defaultValue: null) as int?;
    if (explicit != null) {
      return explicit.clamp(0, MiningMediaCompression.imageTierCount - 1);
    }
    final bool oldCompress =
        getPref('compress_mining_media', defaultValue: true) as bool;
    return oldCompress
        ? MiningMediaCompression.defaultImageTier
        : 2; // 旧「关闭压缩」= 高保真档 = 图片高清档 2
  }

  void setMiningImageQuality(int tier) async {
    await setPref('mining_image_quality',
        tier.clamp(0, MiningMediaCompression.imageTierCount - 1));
    notifyListeners();
  }

  // TODO-1650 制卡音频质量档（0..2，见 [MiningMediaCompression.audioTiers]）。未显式设过时
  // 从旧「压缩」开关迁移：开(默认)→标准档 0（单声道 64k，现状）；关→高音质档 1（立体声
  // 128k）。Android 句子音频本就无损 re-mux，不受此档影响。
  int get miningAudioQuality {
    final int? explicit =
        getPref('mining_audio_quality', defaultValue: null) as int?;
    if (explicit != null) {
      return explicit.clamp(0, MiningMediaCompression.audioTierCount - 1);
    }
    final bool oldCompress =
        getPref('compress_mining_media', defaultValue: true) as bool;
    return oldCompress
        ? MiningMediaCompression.defaultAudioTier
        : 1; // 旧「关闭压缩」= 高保真档 = 音频高音质档 1
  }

  void setMiningAudioQuality(int tier) async {
    await setPref('mining_audio_quality',
        tier.clamp(0, MiningMediaCompression.audioTierCount - 1));
    notifyListeners();
  }

  // 互联「制卡到服务端」开关：开启后所有 app 内制卡（查词/阅读器/视频）不落本地 Anki，
  // 而是把制卡内容 + 全部媒体字节转发给已配对主机，用主机的 Anki 后端 + 配置落卡。
  // 默认 false=本地制卡（现状零破坏）。目标主机复用互联客户端（远程查词的同一配对目标）。
  bool get mineToServer =>
      getPref('mine_to_server', defaultValue: false) as bool;

  Future<void> setMineToServer(bool value) async {
    await setPref('mine_to_server', value);
    notifyListeners();
  }

  // 视频制卡封面图片模式（GIF 动图 / 制卡时当前帧 / 字幕开头帧）。默认 gif=现状零破坏。
  // 存稳定字符串键（[VideoMiningImageMode.wireName]），解析未知值回退 gif（向后兼容）。
  VideoMiningImageMode get videoMiningImageMode =>
      VideoMiningImageMode.fromWireName(
          getPref('video_mining_image_mode', defaultValue: null) as String?);

  void setVideoMiningImageMode(VideoMiningImageMode mode) async {
    await setPref('video_mining_image_mode', mode.wireName);
    notifyListeners();
  }

  // galgame 场景卡封面模式，与视频**分开存**：视频的动图能拍出口型和动作，galgame
  // 画面在一句台词内基本静止，动图多半只是把同一帧存二十遍。两者的取舍不同，共用一
  // 个开关会逼用户为一边将就另一边。默认 gif=现状零破坏；galgame 没有「字幕区间」，
  // 故只在 gif / currentFrame 两档间取值，其余值按 [VideoMiningImageMode.isStill]
  // 归入静态截图。
  VideoMiningImageMode get galMiningImageMode =>
      VideoMiningImageMode.fromWireName(
          getPref('gal_mining_image_mode', defaultValue: null) as String?);

  void setGalMiningImageMode(VideoMiningImageMode mode) async {
    await setPref('gal_mining_image_mode', mode.wireName);
    notifyListeners();
  }

  // 动图**编码格式**，与上面两个「封面模式」正交：模式选「用不用动图 / 静态帧取哪一帧」，
  // 格式选「动图用什么编码」。视频与 gal 同样分开存，理由与 image mode 一致（两边画面
  // 特性不同，共用一个开关会逼用户为一边将就另一边）。
  //
  // 默认值不写在这里，由 [MiningAnimatedFormat.fromWireName] 对 null 给出（= avif），
  // 保证解析未知历史值与「从没设过」走同一条路径。
  MiningAnimatedFormat get videoMiningAnimatedFormat =>
      MiningAnimatedFormat.fromWireName(
          getPref('video_mining_animated_format', defaultValue: null)
              as String?);

  void setVideoMiningAnimatedFormat(MiningAnimatedFormat format) async {
    await setPref('video_mining_animated_format', format.wireName);
    notifyListeners();
  }

  MiningAnimatedFormat get galMiningAnimatedFormat =>
      MiningAnimatedFormat.fromWireName(
          getPref('gal_mining_animated_format', defaultValue: null) as String?);

  void setGalMiningAnimatedFormat(MiningAnimatedFormat format) async {
    await setPref('gal_mining_animated_format', format.wireName);
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

  /// Anki 本地音频服务器（local-audio-yomichan，默认端口 5050）的内置预设 URL。
  /// 用户装了该服务器后，在「管理音频来源」里打开开关即用；默认关闭——本地第三方
  /// 服务不经用户同意不参与查词发音（与 hibikiRemote / worker 默认源同策）。
  /// 由 [_withDefaultAudioSources] 对所有用户「缺则补」为一条 disabled 源。
  static const String ankiLocalAudioUrl =
      'http://localhost:5050/?term={term}&reading={reading}';

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
    final List<AudioSourceConfig> result = <AudioSourceConfig>[...sources];

    // hibikiRemote 恒在列首（缺则补），历史行为不变。
    final bool hasHibikiRemote = result.any(
      (AudioSourceConfig source) => source.kind == AudioSourceKind.hibikiRemote,
    );
    if (!hasHibikiRemote) {
      result.insert(0, AudioSourceConfig.hibikiRemote());
    }

    // Anki 本地音频服务器（5050）内置预设：对所有用户「缺则补」为一条 disabled 源，
    // 追加在列尾。用户装了服务器打开开关即用；删掉后下次读取会 disabled 重生，与
    // hibikiRemote 恒补策略一致（TODO-083 范式）。
    final bool hasAnki = result.any((AudioSourceConfig source) =>
        source.kind == AudioSourceKind.remoteAudio &&
        source.url == ankiLocalAudioUrl);
    if (!hasAnki) {
      result.add(AudioSourceConfig.remoteAudio(
        url: ankiLocalAudioUrl,
        label: 'Anki',
        enabled: false,
      ));
    }

    return result;
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

  // BUG-1095: galgame Hook 台词浮窗字号（逻辑 px）。以前这个值没有真值来源——native
  // 按浮窗高度对基准 30 做 0.9~2.5 倍缩放，于是「把浮窗拖高」和「把字放大」是同一个
  // 手势，用户「放不下想拖高」永远拖不出更多行。现在窗高只管窗高，字号是这条独立
  // 偏好。默认 30 == 旧基准在默认窗高（140dip）下的实际字号，没拖过窗的用户观感不变。
  static const double galHookTextFontSizeMin = 12.0;
  static const double galHookTextFontSizeMax = 72.0;
  static const double galHookTextFontSizeDefault = 30.0;

  double get galHookTextFontSize {
    final Object? stored = getPref(
      'gal_hook_text_font_size',
      defaultValue: galHookTextFontSizeDefault,
    );
    final double value =
        stored is num ? stored.toDouble() : galHookTextFontSizeDefault;
    return value.clamp(galHookTextFontSizeMin, galHookTextFontSizeMax);
  }

  Future<void> setGalHookTextFontSize(double value) async {
    await setPref(
      'gal_hook_text_font_size',
      value.clamp(galHookTextFontSizeMin, galHookTextFontSizeMax).toDouble(),
    );
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

  // TODO-708 P2: 悬浮字幕/歌词条「圆角半径」自定义（逻辑 dp）。0 = 平台原生默认观感
  // （Android 直角矩形背景 / Windows 14dp 圆角），确保默认不改动时视觉与历史一致；>0
  // 时两端都按该 dp 值渲染背景与按钮圆角。上界 48 足够覆盖胶囊化诉求。
  static const int floatingLyricCornerRadiusDefault = 0;
  static const int floatingLyricCornerRadiusMax = 48;

  static int normalizeFloatingLyricCornerRadius(num value) =>
      value.round().clamp(0, floatingLyricCornerRadiusMax).toInt();

  int get floatingLyricCornerRadius => normalizeFloatingLyricCornerRadius(
        getPref(
          'floating_lyric_corner_radius',
          defaultValue: floatingLyricCornerRadiusDefault,
        ) as int,
      );

  Future<void> setFloatingLyricCornerRadius(int value) async {
    await setPref(
      'floating_lyric_corner_radius',
      normalizeFloatingLyricCornerRadius(value),
    );
    notifyListeners();
  }

  // TODO-708 P2: 悬浮字幕/歌词条「宽度」自定义（逻辑 dp）。0 = 平台原生默认宽度
  // （Android 撑满屏宽 MATCH_PARENT / Windows 720dip 起始宽 + 可拖拽），默认不改动时
  // 视觉与历史一致；>0 时两端都按该 dp 值设窗口宽（居中）。范围 200..1200 覆盖窄条到
  // 宽横幅。
  static const int floatingLyricWidthDefault = 0;
  static const int floatingLyricWidthMin = 200;
  static const int floatingLyricWidthMax = 1200;

  /// 归一悬浮窗宽度：0 保持为「自动/平台默认」哨兵，其余夹到 [min, max]。
  static int normalizeFloatingLyricWidth(num value) {
    final int rounded = value.round();
    if (rounded <= 0) return 0;
    return rounded.clamp(floatingLyricWidthMin, floatingLyricWidthMax).toInt();
  }

  int get floatingLyricWidth => normalizeFloatingLyricWidth(
        getPref(
          'floating_lyric_width',
          defaultValue: floatingLyricWidthDefault,
        ) as int,
      );

  Future<void> setFloatingLyricWidth(int value) async {
    await setPref(
      'floating_lyric_width',
      normalizeFloatingLyricWidth(value),
    );
    notifyListeners();
  }

  // TODO-708 P4: 悬浮字幕/歌词条「上下文行数」——在当前行上下各显示 N 行前后文
  // （对称单值）。0 = 只当前行 = 今天的单行观感（默认），确保默认不改动时逐字节一致；
  // 1..3 时 Dart 端组装多行文本推给原生渲染（路线 A）。上界 3 足够铺满一小条上下文而
  // 不喧宾夺主；per-Profile 自动快照（不加排除集）。
  static const int floatingLyricContextLinesDefault = 0;
  static const int floatingLyricContextLinesMax = 3;

  static int normalizeFloatingLyricContextLines(num value) =>
      value.round().clamp(0, floatingLyricContextLinesMax).toInt();

  int get floatingLyricContextLines => normalizeFloatingLyricContextLines(
        getPref(
          'floating_lyric_context_lines',
          defaultValue: floatingLyricContextLinesDefault,
        ) as int,
      );

  Future<void> setFloatingLyricContextLines(int value) async {
    await setPref(
      'floating_lyric_context_lines',
      normalizeFloatingLyricContextLines(value),
    );
    notifyListeners();
  }

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

  /// 用户手填的「自定义更新代理」（`host:port`，空串=未设）。fake-ip/TUN 模式下系统
  /// 代理只写注册表、Dart HttpClient 读不到时的兜底入口（TODO-871/862）：非空时检查/下载
  /// 直接走它，优先于 env/GUI 系统代理。空串=清除（回退默认 env>GUI>DIRECT 逻辑）。
  String get updateCustomProxy =>
      getPref('update_custom_proxy', defaultValue: '') as String;

  Future<void> setUpdateCustomProxy(String value) async {
    await setPref('update_custom_proxy', value);
    notifyListeners();
  }

  /// 外部 mokuro CLI 可执行路径（漫画 OCR 后备；空串=未设）。内置 ONNX 引擎在本平台不可用
  /// 或用户偏好外部工具时，OCR 导入向导据此调用系统 mokuro（见 [ExternalMokuroRunner]）。
  /// 空串=未指定，运行时退回 `FUSHI_MOKURO` 环境变量 / PATH 探测。
  String get mangaExternalMokuroPath =>
      getPref('manga_external_mokuro_path', defaultValue: '') as String;

  Future<void> setMangaExternalMokuroPath(String value) async {
    await setPref('manga_external_mokuro_path', value);
    notifyListeners();
  }

  /// PC 漫画整卷 OCR 默认引擎。稳定字符串而非 enum index，避免重排枚举破坏偏好。
  /// `auto` 的解析顺序由漫画模块统一控制，且永不自动跨到 Google Lens。
  ///
  /// 出厂默认是 `google_lens`：整页识别的版面/竖排质量明显优于本地 ONNX，且不
  /// 依赖 1GB 级模型下载或桌面 mokuro CLI，是唯一「装完就能用」的引擎。这**不**
  /// 削弱隐私边界——真正的上传闸门是 [ensureGoogleLensDisclosure] 的逐设备一次性
  /// 同意弹窗，用户拒绝即不发任何字节；想彻底离线的用户把本偏好改回 `auto`，
  /// `auto` 的解析链依旧永不跨到 Lens。
  String get mangaOcrEnginePreference =>
      getPref('manga_ocr_engine_preference', defaultValue: 'google_lens')
          as String;

  Future<void> setMangaOcrEnginePreference(String value) async {
    await setPref('manga_ocr_engine_preference', value);
    notifyListeners();
  }

  String get mangaSpreadPreference =>
      getPref('manga_spread_preference', defaultValue: 'auto') as String;

  Future<void> setMangaSpreadPreference(String value) async {
    await setPref('manga_spread_preference', value);
    notifyListeners();
  }

  String get mangaReadingDirection =>
      getPref('manga_reading_direction', defaultValue: 'rtl') as String;

  Future<void> setMangaReadingDirection(String value) async {
    await setPref('manga_reading_direction', value);
    notifyListeners();
  }

  int get mangaZoomPercent =>
      getPref('manga_zoom_percent', defaultValue: 100) as int;

  Future<void> setMangaZoomPercent(int value) async {
    await setPref(
      'manga_zoom_percent',
      value.clamp(kMangaZoomMinPercent, kMangaZoomMaxPercent),
    );
    notifyListeners();
  }

  /// 滚轮/捏合缩放灵敏度倍率（百分比，100 = 基准）。
  int get mangaZoomSensitivity => getPref('manga_zoom_sensitivity',
      defaultValue: kMangaZoomSensitivityDefault) as int;

  Future<void> setMangaZoomSensitivity(int value) async {
    await setPref(
      'manga_zoom_sensitivity',
      value.clamp(kMangaZoomSensitivityMin, kMangaZoomSensitivityMax),
    );
    notifyListeners();
  }

  /// 翻页动画样式（`none` / `slide` / `fade`）。
  String get mangaPageAnimation => getPref('manga_page_animation',
      defaultValue: MangaPageAnimation.slide.key) as String;

  Future<void> setMangaPageAnimation(String value) async {
    await setPref('manga_page_animation', value);
    notifyListeners();
  }

  /// 音量键翻页（漫画阅读器）。默认开：与 EPUB 阅读器的音量键翻页一致。
  bool get mangaVolumeKeyPaging =>
      getPref('manga_volume_key_paging', defaultValue: true) as bool;

  Future<void> setMangaVolumeKeyPaging(bool value) async {
    await setPref('manga_volume_key_paging', value);
    notifyListeners();
  }

  /// 点击页面左右边缘翻页。默认开：触屏此前完全没有点击翻页手段。
  bool get mangaTapZonePaging =>
      getPref('manga_tap_zone_paging', defaultValue: true) as bool;

  Future<void> setMangaTapZonePaging(bool value) async {
    await setPref('manga_tap_zone_paging', value);
    notifyListeners();
  }

  /// 漫画「在线目录」站点根 URL（O1：mokuro.moe 目录源；`MokuroMoeClient` 消费，
  /// 空串/尾斜杠由 client 侧 `normalizeMokuroMoeBaseUrl` 归一回默认站点）。
  String get mangaOnlineCatalogBaseUrl =>
      getPref('manga_online_catalog_base_url',
          defaultValue: 'https://mokuro.moe') as String;

  Future<void> setMangaOnlineCatalogBaseUrl(String value) async {
    await setPref('manga_online_catalog_base_url', value);
    notifyListeners();
  }

  /// Whether the mokuro.moe internet catalog participates in manga browsing.
  /// Defaults to true to preserve the pre-source-toggle behaviour.
  bool get mangaOnlineCatalogEnabled =>
      getPref('manga_online_catalog_enabled', defaultValue: true) as bool;

  Future<void> setMangaOnlineCatalogEnabled(bool value) async {
    await setPref('manga_online_catalog_enabled', value);
    notifyListeners();
  }

  // 旧版单框 Gemini 云端识别的三对 getter/setter（`manga_cloud_ocr_enabled` /
  // `manga_cloud_ocr_api_key` / `manga_cloud_ocr_model`）随 PR#474 删掉框选补扫
  // 实现后已零消费方，本轮一并清掉（BUG-1164）。
  //
  // ⚠️ 存量设备的 Drift `preferences` 行**不删**（没有迁移方案就别动持久化数据），
  // 而 `manga_cloud_ocr_api_key` 仍然留在
  // `sync/pref_redaction_policy.dart` 的 `sensitiveKeys` 里 —— 老用户库里已经写
  // 过的那个 key 必须继续被备份/Profile 快照/Profile 分享三条出境通道剔除。
  // 删代码不等于删数据，脱敏名单不能跟着删。

  // galgame 窗口超分**不再有全局偏好**（BUG-1191）。原来的
  // `galgame_magpie_upscaling_mode` 是个一刀切开关，而超分该不该开完全取决于**这个
  // 游戏**的原生分辨率：同一个人手上既有 800×600 的老 gal，也有本身就 1080p 的新作。
  // 档位已改为每游戏一档，存在 galgame 库那一行（`galgames.upscaling_mode`）。
  //
  // v63 精确删除存量 `galgame_magpie_upscaling_mode` live 行及其 pref Profile
  // 副本，不迁移到任何游戏；旧 Profile apply/JSON import 也会拒绝它复活。全局值
  // 无法映射成「每个游戏各自开不开」，新结构仍一律从关闭起步，用户按游戏自己开。

  /// AniList/Nyaa/Jimaku requests: auto (env > enabled system proxy > direct),
  /// explicit direct, or a user-provided host:port proxy.
  String get downloadNetworkProxyMode =>
      getPref('download_network_proxy_mode', defaultValue: 'auto') as String;

  Future<void> setDownloadNetworkProxyMode(String value) async {
    await setPref('download_network_proxy_mode', value);
    notifyListeners();
  }

  String get downloadCustomProxy =>
      getPref('download_custom_proxy', defaultValue: '') as String;

  Future<void> setDownloadCustomProxy(String value) async {
    await setPref('download_custom_proxy', value);
    notifyListeners();
  }

  /// TODO-1961：内置下载引擎的下载根（新任务落点）。空串 = 未设置 → 用默认根
  /// `<documents>/anime_downloads/content`（与本 key 出现之前逐字节一致）。
  /// 设备本地路径，不进 Profile 快照（见 `ProfileKeys._excludedPrefKeys`）。
  String get downloadSaveRoot =>
      getPref('download_save_root', defaultValue: '') as String;

  Future<void> setDownloadSaveRoot(String value) async {
    await setPref('download_save_root', value);
    notifyListeners();
  }

  /// TODO-1961：用过的历史下载根（JSON 字符串数组，新的在前，见
  /// `encodeSaveRootHistory`）。**只**用于让改目录之前的旧任务在下载页仍被认出，
  /// 永不作为写入目标。旧任务不迁移是刻意的：迁移=移动几十 GB 且掐断做种。
  String get downloadSaveRootHistory =>
      getPref('download_save_root_history', defaultValue: '') as String;

  Future<void> setDownloadSaveRootHistory(String value) async {
    await setPref('download_save_root_history', value);
    notifyListeners();
  }

  /// TODO-1024 / BUG-479：上次更新检查结果缓存（解码后；无/畸形 → null）。检查时先读它
  /// 乐观即时反馈，网络刷新在后台跑完再写回——不再每次冷查 GitHub 才知道结果（恒快）。
  UpdateCheckCacheEntry? get updateCheckCache => UpdateCheckCacheEntry.decode(
        getPref(updateCheckCachePrefKey, defaultValue: '') as String,
      );

  /// 写回更新检查结果缓存（落 `preferences` 表单 key）。不 `notifyListeners`——缓存是
  /// 后台静默刷新的产物，不驱动 UI 重建，避免无谓 rebuild。
  Future<void> setUpdateCheckCache(UpdateCheckCacheEntry entry) =>
      setPref(updateCheckCachePrefKey, entry.encode());

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

  // ── reading goals (TODO-1046) ────────────────────────────────────────
  // Daily/weekly reading targets measured in characters. 0 = unset/off,
  // which the statistics page treats as "no goal" (goal card hidden). Read
  // and write clamped so a corrupt/out-of-range stored value can never reach
  // the progress UI as an absurd goal. Per-Profile (not excluded in
  // ProfileKeys), so each profile keeps its own targets.

  int get readingGoalDailyChars =>
      (getPref('reading_goal_daily_chars', defaultValue: 0) as int)
          .clamp(0, 1000000);

  Future<void> setReadingGoalDailyChars(int value) async {
    await setPref('reading_goal_daily_chars', value.clamp(0, 1000000));
    notifyListeners();
  }

  int get readingGoalWeeklyChars =>
      (getPref('reading_goal_weekly_chars', defaultValue: 0) as int)
          .clamp(0, 10000000);

  Future<void> setReadingGoalWeeklyChars(int value) async {
    await setPref('reading_goal_weekly_chars', value.clamp(0, 10000000));
    notifyListeners();
  }
}
