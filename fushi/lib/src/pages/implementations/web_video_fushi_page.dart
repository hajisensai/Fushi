import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:media_kit_video/media_kit_video.dart'
    show defaultEnterNativeFullscreen, defaultExitNativeFullscreen;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/focus/page_focus_ownership.dart';
import 'package:fushi/src/focus/panel_focus_scope.dart';
import 'package:fushi/src/focus/webview_key_bridge.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_player_shortcuts.dart';
import 'package:fushi/src/media/video/video_subtitle_jump_panel.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi/src/media/video/video_watch_tracker.dart';
import 'package:fushi/src/media/video/web_video_bridge.dart';
import 'package:fushi/src/pages/implementations/dictionary_page_mixin.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_input_bridge.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/stat_activity.dart'
    show statTodayKey;
import 'package:fushi/src/pages/implementations/video_fushi_page.dart'
    show resolveVideoLookupAnchorCue, subtitleLookupTerm;
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/sync/fushi_library_host_service.dart'
    show videoRemotePositionEpisodeAtPrefKey, videoRemotePositionEpisodePrefKey;
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi/src/utils/components/fushi_windows_title_bar.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/lookup_dismiss_barrier.dart';
import 'package:fushi/src/utils/overlay_entry_lifecycle.dart';
import 'package:fushi/src/webview/webview_death_guard.dart';

/// JS→Dart 单一 handler 名（glue 的 `HANDLER`），载荷按 `type` 分派。
const String kWebVideoJsHandler = 'fushiWebVideo';

/// WebView2 持焦时截获视频快捷键交回 Dart 的桥 handler 名。
const String kWebVideoKeyBridgeHandler = 'fushiWebVideoKeys';

/// 流媒体书断点写库的最小位置（与视频页远端分支 `_persistRemotePosition` 的 BUG-996 阈值
/// 同口径）：播放头不足 5 秒不算「看过」，不覆盖已有进度。
const int kWebVideoMinPersistPositionMs = 5000;

/// 内置网页播放器（Windows）：在 WebView2 里由站点自己的播放器播放（Netflix / YouTube /
/// TVer / B 站……），Fushi 只做「围绕视频」的那一层——字幕列表面板、画面字幕叠层逐词查词、
/// 收藏句、快捷键、进度/观看统计登记，全部复用现有视频页的组件与数据契约。
///
/// 字幕从哪来：与浏览器扩展**同一份** `subtitle-providers.js`（站点 bridge 抓整集明文字幕轨 +
/// HTML5 textTracks 收割 + DOM 采样 live 轨）在主世界 document-start 注入，胶水
/// `web_video_glue.js` 把 store 变化与播放态投给本页（契约见 [web_video_bridge.dart]）。
///
/// 画面帧归站点（PlayReady 硬件档受保护输出），本页不碰像素；超分 / 截图 / 录制走独立的
/// 制卡环境（计划 P2/P3），观看体验不受影响。
class WebVideoFushiPage extends ConsumerStatefulWidget {
  const WebVideoFushiPage({
    required this.bookUid,
    required this.repo,
    this.softwareDrm = true,
    super.key,
  });

  /// 书架流媒体书 uid（`video/stream/…`，与 mpv 视频页共用同一条 [VideoBooks] 行）。
  final String bookUid;
  final VideoBookRepository repo;

  /// 软件 DRM 档：Chrome UA + document-start EME 垫片（拒 PlayReady、Widevine 降软件级）。
  ///
  /// **默认 true，这不是降级而是唯一可行档**（2026-08-29 真机，见计划 §5.2）：fork 的显示链路是
  /// 对 WebView2 visual 的 WGC 捕获，硬件 PlayReady 在这条链路上直接报 Netflix D7703；软件档
  /// 给 Netflix 1080p（与 Chrome 关硬件加速同档），且帧可捕获 → 超分 / 截图 / 制卡全部可用。
  /// 传 false 只在 fork 将来有 HWND 窗口宿主模式（不经捕获）时才有意义。
  final bool softwareDrm;

  /// 可捕获 WebView2 环境单例：`--disable-direct-composition`。fork 的显示链路本身就是 WGC 捕获，
  /// Chromium 把 DRM 视频放进 DComp overlay 时纹理里是黑的（真机：默认环境视频区纯黑、加该参数
  /// 清晰可见）。environment 级参数不能运行期切换，且同 user data folder 的多个 env 参数必须逐字
  /// 一致，故用独立目录（独立 cookie 罐：站点登录在网页播放器里做一次即可）。
  static Future<WebViewEnvironment>? _capturableEnv;

  /// 目录：测试 runner 给了 `FUSHI_WEBVIEW2_USER_DATA_FOLDER` 就放它旁边（隔离），否则
  /// `%LOCALAPPDATA%\Fushi\WebVideoWebView2`（与 runner 的 OverlayUserDataFolder 命名法一致）。
  static String capturableUserDataFolder() {
    final String? testFolder =
        Platform.environment['FUSHI_WEBVIEW2_USER_DATA_FOLDER'];
    if (testFolder != null && testFolder.isNotEmpty) {
      return '$testFolder-webvideo';
    }
    final String base = Platform.environment['LOCALAPPDATA'] ?? '.';
    return '$base\\Fushi\\WebVideoWebView2';
  }

  static Future<WebViewEnvironment> capturableEnvironment() {
    return _capturableEnv ??= WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(
        userDataFolder: capturableUserDataFolder(),
        additionalBrowserArguments:
            '--autoplay-policy=no-user-gesture-required --disable-direct-composition',
      ),
    );
  }

  /// 打开本页的唯一入口：路由层包 [FushiAppUiScaleNeutralizer]（WebView2 是平台纹理，
  /// 落在缩放画布里会被栅格化再放大 → 糊；与 `VideoFushiPage.neutralized` 同理）。
  static Widget neutralized({
    required String bookUid,
    required VideoBookRepository repo,
  }) => FushiAppUiScaleNeutralizer(
    child: WebVideoFushiPage(bookUid: bookUid, repo: repo),
  );

  /// 集成测试钩子（debug/profile only，assert 注册；与 `HomePage.debugSelectTab` 同范式）：
  /// 离屏 / 非焦点下焦点驱动偶发不触发，真机验证用这些直达读状态 / 开列表 / seek。
  @visibleForTesting
  static WebVideoDebugSnapshot Function()? debugSnapshot;
  @visibleForTesting
  static VoidCallback? debugToggleList;
  @visibleForTesting
  static Future<void> Function(int ms)? debugSeek;

  /// 在站点页面里求值（诊断用：location / 标题 / 正文片段），返回 JSON 字符串。
  @visibleForTesting
  static Future<String?> Function(String js)? debugEvalJs;

  /// CDP 截图（页面 UI 可见；受保护视频区为黑），返回 PNG 字节。
  @visibleForTesting
  static Future<Uint8List?> Function()? debugScreenshot;

  @override
  ConsumerState<WebVideoFushiPage> createState() => _WebVideoFushiPageState();
}

/// [WebVideoFushiPage.debugSnapshot] 的只读快照。
typedef WebVideoDebugSnapshot = ({
  bool hasVideo,
  int? positionMs,
  bool playing,
  int trackCount,
  String? activeTrackKey,
  int cueCount,
  int currentCueIndex,
  String videoKey,
  bool listVisible,
});

class _WebVideoFushiPageState extends ConsumerState<WebVideoFushiPage>
    with DictionaryPageMixin {
  /// 缓存的 [AppModel]（浮层在 LayoutBuilder 回调里读，widget 失活后 `ref.read` 会抛）。
  late final AppModel _appModel = ref.read(appProvider);

  bool get _softwareDrm => widget.softwareDrm;

  /// 只当 cue 仓库 + 字幕定位器用的 controller：永不 [VideoPlayerController.load]，
  /// 位置 / 播放态经 [VideoPlayerController.applyExternalPlaybackState] 由页面 JS 注入。
  final VideoPlayerController _controller = VideoPlayerController();

  late final DictionaryPopupController _popup = DictionaryPopupController(
    lowMemory: false,
    onLookupStackDepthChanged: recordLookupStackDepth,
  );

  final VideoSubtitleHitTester _subtitleHitTester = VideoSubtitleHitTester();
  final VideoSubtitleListHitTester _listHitTester =
      VideoSubtitleListHitTester();
  final ValueNotifier<int> _searchRequests = ValueNotifier<int>(0);

  final FocusNode _focusNode = FocusNode(debugLabel: 'web-video-page');
  late final PageFocusOwnership _focusOwnership = PageFocusOwnership(
    node: _focusNode,
    canOwn: (FocusReclaimCause _) => mounted && !_popup.hasVisiblePopup,
  );

  late final WebViewDeathGuard _deathGuard = WebViewDeathGuard(
    surface: 'web_video',
    afterRebuild: () {
      if (mounted) setState(() {});
    },
  );

  InAppWebViewController? _web;
  VideoBookRow? _row;
  String? _failReason;
  WebViewEnvironment? _env;

  /// document-start 注入脚本（按导航 host 选 bridge），资产异步读取，就绪前不建 WebView。
  UnmodifiableListView<UserScript>? _userScripts;

  /// store 里所有轨（key = `videoKey|lang`）；当前视频身份 [_videoKey] 过滤后供面板选轨。
  final Map<String, WebVideoTrack> _tracks = <String, WebVideoTrack>{};
  String? _activeTrackKey;
  String _videoKey = '';
  WebVideoPlaybackState? _state;

  bool _listVisible = false;
  bool _hideNativeSubtitles = true;
  bool _overlayHidden = false;
  bool _fullscreen = false;

  bool _pausedForLookup = false;
  AudioCue? _lastLookupCue;

  OverlayEntry? _popupOverlayEntry;
  bool _overlayInert = false;

  int _lastPersistedSec = -1;
  VideoWatchTracker? _watchTracker;

  /// 本视频已收藏句缓存（`text|startMs`），列表面板星标同步读。
  final Set<String> _favoritedKeys = <String>{};

  @override
  AppModel get mixinAppModel => _appModel;

  @override
  ThemeData get mixinTheme => Theme.of(context);

  @override
  String get dictionarySourceType => kStatSourceVideo;

  @override
  ShortcutScope? get dictionaryPopupInputScope => ShortcutScope.video;

  @override
  Set<ShortcutAction> get dictionaryPopupForwardedActions => <ShortcutAction>{
    ...ShortcutAction.actionsForScope(ShortcutScope.video),
    ShortcutAction.globalBack,
  };

  @override
  void onDictionaryPopupInputToken(String token) {
    final ShortcutAction? action = resolveDictionaryPopupInputToken(
      registry: _appModel.shortcutRegistry,
      token: token,
      scope: ShortcutScope.video,
    );
    if (action == null) return;
    _popNestedPopupAt(_popup.lastVisibleIndex);
  }

  @override
  void initState() {
    super.initState();
    attachLookupCounter(_popup);
    _controller.addListener(_onControllerChanged);
    assert(() {
      WebVideoFushiPage.debugSnapshot = () => (
            hasVideo: _state?.hasVideo ?? false,
            positionMs: _state?.positionMs,
            playing: _state?.isPlaying ?? false,
            trackCount: _tracks.length,
            activeTrackKey: _activeTrackKey,
            cueCount: _controller.cues.length,
            currentCueIndex: _controller.currentCueIndex,
            videoKey: _videoKey,
            listVisible: _listVisible,
          );
      WebVideoFushiPage.debugToggleList = _toggleList;
      WebVideoFushiPage.debugSeek = _seekMs;
      WebVideoFushiPage.debugEvalJs = (String js) async {
        final Object? r = await _web?.evaluateJavascript(source: js);
        return r?.toString();
      };
      WebVideoFushiPage.debugScreenshot = () async => _web?.takeScreenshot();
      return true;
    }());
    unawaited(_init());
  }

  @override
  void dispose() {
    _overlayInert = true;
    assert(() {
      WebVideoFushiPage.debugSnapshot = null;
      WebVideoFushiPage.debugToggleList = null;
      WebVideoFushiPage.debugSeek = null;
      WebVideoFushiPage.debugEvalJs = null;
      WebVideoFushiPage.debugScreenshot = null;
      return true;
    }());
    unawaited(_watchTracker?.stop());
    unawaited(_flushPosition());
    final OverlayEntry? entry = _popupOverlayEntry;
    if (entry != null) {
      removeAndDisposeOwnedOverlayEntry(entry);
      _popupOverlayEntry = null;
    }
    if (_fullscreen && Platform.isWindows) {
      FushiWindowsTitleBar.setContentFullscreen(owner: this, enabled: false);
    }
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    _popup.dispose();
    _searchRequests.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // ── 初始化 ────────────────────────────────────────────────────────────

  Future<void> _init() async {
    final VideoBookRow? row = await widget.repo.getByBookUid(widget.bookUid);
    if (!mounted) return;
    if (row == null) {
      setState(() => _failReason = t.video_load_failed_not_found);
      return;
    }
    final Uri? uri = Uri.tryParse(row.videoPath);
    if (uri == null || uri.host.isEmpty) {
      setState(() => _failReason = t.video_load_failed_not_found);
      return;
    }
    final List<String> assets = <String>[
      // 垫片必须排第一：站点脚本一跑就会抓走原始 EME 函数引用。
      if (_softwareDrm) kWebVideoEmeShimAsset,
      ...webVideoBridgeAssetsForHost(uri.host),
      kWebVideoAdaptersAsset,
      kWebVideoProvidersAsset,
      kWebVideoGlueAsset,
    ];
    final List<String> sources = <String>[];
    for (final String asset in assets) {
      sources.add(await rootBundle.loadString(asset));
    }
    sources.add(_keyBridgeScript());
    _env = await WebVideoFushiPage.capturableEnvironment();
    if (!mounted) return;
    unawaited(_refreshFavoriteCache());
    setState(() {
      _row = row;
      _userScripts = UnmodifiableListView<UserScript>(<UserScript>[
        for (final String src in sources)
          UserScript(
            source: src,
            injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          ),
      ]);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _seedWarmPopup());
  }

  /// WebView2 持焦期间截获视频作用域全部键盘绑定（token 直接取注册表序列化形式，
  /// 用户改绑后重开本页即生效），交回 [_onKeyToken] 走同一份动作表。
  String _keyBridgeScript() {
    final Set<String> tokens = <String>{};
    for (final ShortcutAction action in <ShortcutAction>{
      ...ShortcutAction.actionsForScope(ShortcutScope.video),
      ShortcutAction.globalBack,
    }) {
      for (final InputBinding b
          in _appModel.shortcutRegistry.bindingsFor(action).keyboardBindings) {
        tokens.add(b.serialize());
      }
    }
    return webViewKeyBridgeScript(
      handlerName: kWebVideoKeyBridgeHandler,
      keys: tokens.toList(growable: false),
      forwardRepeats: false,
      stopPropagation: true,
    );
  }

  void _seedWarmPopup() {
    if (!mounted) return;
    _popup.lowMemory = _appModel.lowMemoryMode;
    setState(() => _popup.seedWarmSlot());
    _syncPopupOverlay();
  }

  // ── JS → Dart ─────────────────────────────────────────────────────────

  Future<Object?> _onJsMessage(List<dynamic> args) async {
    if (args.isEmpty || args.first is! Map) return null;
    final Map<dynamic, dynamic> msg = args.first as Map<dynamic, dynamic>;
    switch (msg['type']) {
      case 'track':
        _onTrack(msg);
      case 'state':
        _onState(msg);
      case 'seekDone':
        break;
    }
    return null;
  }

  void _onTrack(Map<dynamic, dynamic> msg) {
    final WebVideoTrack? track = parseWebVideoTrackPayload(
      msg,
      bookUid: widget.bookUid,
    );
    if (track == null) return;
    _tracks[track.key] = track;
    _reselectTrack();
  }

  /// 轨集 / 当前视频变化后重选当前轨并灌进 controller（同轨更新也要灌：live 轨边看边长）。
  void _reselectTrack() {
    final String? next = chooseWebVideoTrackKey(
      tracks: _tracks.values,
      videoKey: _videoKey,
      // v87 内容语言（用户手动指定的 BCP-47）作默认轨偏好；未指定则取首条整轨。
      preferredLanguage: _row?.language,
      current: _activeTrackKey,
    );
    final bool changed = next != _activeTrackKey;
    _activeTrackKey = next;
    final WebVideoTrack? track = next == null ? null : _tracks[next];
    _controller.setCues(track?.cues ?? const <AudioCue>[]);
    final int? pos = _state?.positionMs;
    if (pos != null) _controller.updateCueForPosition(pos);
    if (changed && mounted) setState(() {});
  }

  void _onState(Map<dynamic, dynamic> msg) {
    final WebVideoPlaybackState? state = parseWebVideoStatePayload(msg);
    if (state == null) return;
    final bool videoChanged = state.videoKey != _videoKey;
    final bool fullscreenChanged = state.fullscreen != _fullscreen;
    _state = state;
    if (videoChanged) {
      _videoKey = state.videoKey;
      _activeTrackKey = null;
      _reselectTrack();
    }
    final int? pos = state.positionMs;
    if (pos != null) {
      _controller.applyExternalPlaybackState(
        positionMs: pos,
        playing: state.isPlaying,
        durationMs: state.durationMs,
      );
      _maybePersistPosition(pos);
      _syncWatchTracker(state.isPlaying);
    }
    if (fullscreenChanged) {
      _fullscreen = state.fullscreen;
      if (mounted) setState(() {});
    }
  }

  void _onKeyToken(List<dynamic> args) {
    if (args.isEmpty) return;
    final String token = args.first.toString();
    final ShortcutAction? action = resolveDictionaryPopupInputToken(
      registry: _appModel.shortcutRegistry,
      token: token,
      scope: ShortcutScope.video,
    );
    if (action == null) return;
    if (_popup.hasVisiblePopup) {
      _popNestedPopupAt(_popup.lastVisibleIndex);
      return;
    }
    videoActionCallbacks(_shortcutActions())[action]?.call();
  }

  // ── Dart → JS ─────────────────────────────────────────────────────────

  Future<void> _js(String expression) async {
    final InAppWebViewController? web = _web;
    if (web == null) return;
    try {
      await web.evaluateJavascript(
        source:
            '(function(){try{return window.__fushiWebVideo&&'
            '($expression);}catch(e){return String(e);}})()',
      );
    } catch (e) {
      ErrorLogService.instance.log(
        'web_video',
        'evaluateJavascript failed: $e',
      );
    }
  }

  Future<void> _seekMs(int ms) => _js('window.__fushiWebVideo.seek($ms)');
  Future<void> _play() => _js('window.__fushiWebVideo.play()');
  Future<void> _pause() => _js('window.__fushiWebVideo.pause()');
  Future<void> _togglePlay() => _js('window.__fushiWebVideo.toggle()');
  Future<void> _setRate(double rate) =>
      _js('window.__fushiWebVideo.setRate($rate)');
  Future<void> _setNativeSubtitlesHidden(bool hidden) =>
      _js('window.__fushiWebVideo.setNativeSubtitlesHidden($hidden)');

  Future<void> _seekRelative(int deltaMs) {
    final int pos = _state?.positionMs ?? 0;
    return _seekMs((pos + deltaMs).clamp(0, 1 << 31));
  }

  Future<void> _seekToCueOffset(int delta) async {
    final List<AudioCue> cues = _controller.cues;
    if (cues.isEmpty) return;
    final int current = _controller.currentCueIndex;
    final int target = current < 0
        ? (delta < 0
              ? nearestCueIndexAtOrBefore(cues, _state?.positionMs ?? 0)
              : 0)
        : (current + delta).clamp(0, cues.length - 1);
    if (target < 0) return;
    await _seekMs(cues[target].startMs);
  }

  Future<void> _adjustRate(double delta) =>
      _setRate(((_state?.rate ?? 1.0) + delta).clamp(0.25, 4.0));

  // ── 进度 / 统计登记（与视频页远端分支同口径）──────────────────────────

  void _maybePersistPosition(int posMs) {
    final int sec = posMs ~/ 1000;
    if (sec == _lastPersistedSec) return;
    _lastPersistedSec = sec;
    unawaited(_persistPosition(posMs));
  }

  Future<void> _persistPosition(int posMs) async {
    if (posMs < kWebVideoMinPersistPositionMs || _row == null) return;
    final int now = DateTime.now().millisecondsSinceEpoch;
    try {
      await _appModel.prefsRepo.setPref(
        videoRemotePositionEpisodePrefKey(widget.bookUid, 0),
        posMs,
      );
      await _appModel.prefsRepo.setPref(
        videoRemotePositionEpisodeAtPrefKey(widget.bookUid, 0),
        now,
      );
      await widget.repo.updatePosition(widget.bookUid, posMs, playedAt: now);
    } catch (e) {
      ErrorLogService.instance.log('web_video', 'persist: $e');
    }
  }

  Future<void> _flushPosition() async {
    final int? pos = _state?.positionMs;
    if (pos == null) return;
    await _persistPosition(pos);
  }

  void _syncWatchTracker(bool playing) {
    final VideoBookRow? row = _row;
    if (row == null) return;
    VideoWatchTracker? tracker = _watchTracker;
    if (tracker == null) {
      final FushiDatabase db = _appModel.database;
      tracker = VideoWatchTracker(
        title: row.title,
        bookUid: widget.bookUid,
        recordFlush: (List<(String, int, int)> buckets) => db.recordWatchFlush(
          title: row.title,
          bookUid: widget.bookUid,
          buckets: buckets,
        ),
        addSubtitleChars: (String dateKey, int chars) => db.recordWatchFlush(
          title: row.title,
          bookUid: widget.bookUid,
          buckets: const <(String, int, int)>[],
          subtitleChars: chars,
          subtitleCharsDateKey: dateKey,
        ),
        markCompleted: (String uid) =>
            db.markVideoCompleted(uid, DateTime.now()),
        recordActivity:
            (
              String title,
              String uid,
              String dateKey,
              int timestampMs,
              int durationMs,
              int chars,
            ) => db.addActivityEvent(
              eventType: kActivityWatch,
              mediaType: kActivityMediaVideo,
              title: title,
              mediaKey: uid,
              dateKey: dateKey,
              timestampMs: timestampMs,
              durationMs: durationMs,
              charsDelta: chars,
            ),
      )..attach(_controller);
      _watchTracker = tracker;
    }
    if (playing) {
      tracker.start();
    } else {
      unawaited(tracker.stop());
    }
  }

  // ── 收藏句（与视频页同一 FavoriteSentenceRepository / 来源标记）───────────

  String _favKey(String text, int? startMs) => '$startMs|${text.trim()}';

  Future<void> _refreshFavoriteCache() async {
    final List<FavoriteSentence> all = await FavoriteSentenceRepository(
      _appModel.database,
    ).getAll();
    if (!mounted) return;
    setState(() {
      _favoritedKeys
        ..clear()
        ..addAll(
          all
              .where(
                (FavoriteSentence s) =>
                    s.bookKey == widget.bookUid &&
                    s.source == kFavoriteSentenceSourceVideo,
              )
              .map((FavoriteSentence s) => _favKey(s.text, s.normCharOffset)),
        );
    });
  }

  bool _isCueFavorited(AudioCue cue) =>
      _favoritedKeys.contains(_favKey(cue.text, cue.startMs)) ||
      _favoritedKeys.contains(_favKey(cue.text, null));

  Future<void> _toggleFavoriteCue(AudioCue cue) async {
    final String sentence = cue.text.trim();
    if (sentence.isEmpty) return;
    final FavoriteSentenceRepository repo = FavoriteSentenceRepository(
      _appModel.database,
    );
    if (_isCueFavorited(cue)) {
      final List<FavoriteSentence> all = await repo.getAll();
      for (final FavoriteSentence s in all) {
        if (s.bookKey == widget.bookUid &&
            s.source == kFavoriteSentenceSourceVideo &&
            s.text.trim() == sentence &&
            (s.normCharOffset == cue.startMs || s.normCharOffset == null)) {
          await repo.removeById(s.id);
        }
      }
    } else {
      await repo.add(
        FavoriteSentence(
          text: sentence,
          bookTitle: _row?.title ?? widget.bookUid,
          createdAt: DateTime.now(),
          bookKey: widget.bookUid,
          sectionIndex: null,
          normCharOffset: cue.startMs,
          normCharLength: (cue.endMs - cue.startMs).clamp(0, 1 << 31).toInt(),
          source: kFavoriteSentenceSourceVideo,
          dateKey: statTodayKey(),
        ),
      );
    }
    await _refreshFavoriteCache();
  }

  Future<void> _toggleFavoriteCurrent() async {
    final AudioCue? cue = _lastLookupCue ?? _controller.currentCue;
    if (cue == null) return;
    await _toggleFavoriteCue(cue);
  }

  void _copyCue(AudioCue cue) {
    final String text = cue.text.trim();
    if (text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
  }

  // ── 查词（与视频页 `_lookupAt` 同步骤）──────────────────────────────────

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  void _handleSubtitleLookupTap(
    String sentence,
    int graphemeIndex,
    Rect charRect,
    AudioCue? cue,
  ) {
    unawaited(_lookupAt(sentence, graphemeIndex, charRect, overrideCue: cue));
  }

  void _handleListLookup(AudioCue cue, int graphemeIndex, Rect charRect) {
    unawaited(_lookupAt(cue.text, graphemeIndex, charRect, overrideCue: cue));
  }

  Future<void> _lookupAt(
    String sentence,
    int graphemeIndex,
    Rect charRect, {
    AudioCue? overrideCue,
  }) async {
    final String term = subtitleLookupTerm(sentence, graphemeIndex);
    if (term.isEmpty) return;
    if (_controller.isPlaying) {
      _pausedForLookup = true;
      unawaited(_pause());
    }
    _lastLookupCue = resolveVideoLookupAnchorCue(
      overrideCue: overrideCue,
      currentCue: _controller.currentCue,
      cues: _controller.miningCues,
      positionMs: _controller.positionMs ?? 0,
      delayMs: _controller.miningDelayMs,
    );
    await pushNestedPopup(
      query: term,
      selectionRect: charRect,
      controller: _popup,
      replaceStack: true,
      reuseWarmSlot: true,
      autoRead: true,
    );
  }

  void _popNestedPopupAt(int index) {
    if (index <= 0 &&
        _popup.entries.isNotEmpty &&
        _popup.entries.first.isWarmSlot) {
      _popup.entries.first.webViewKey.currentState?.clearSelection();
    }
    setState(() => _popup.dismissAt(index));
    if (!_popup.hasVisiblePopup) {
      if (_pausedForLookup) {
        _pausedForLookup = false;
        unawaited(_play());
      }
      _focusOwnership.reclaim(FocusReclaimCause.popupDismissed);
    }
  }

  void _onDismissBarrierTap(Offset globalPos) {
    final SubtitleCharHit? hit = _subtitleHitTester.hitTest(
      globalPos,
      exactOnly: true,
    );
    if (hit != null && _popup.lastVisibleIndex <= 0) {
      _handleSubtitleLookupTap(
        hit.sentence,
        hit.graphemeIndex,
        hit.charRect,
        hit.cue,
      );
      return;
    }
    final SubtitleListHit? listHit = _listHitTester.hitTest(
      globalPos,
      exactOnly: true,
    );
    if (listHit != null) {
      _handleListLookup(listHit.cue, listHit.graphemeIndex, listHit.charRect);
      return;
    }
    _popNestedPopupAt(0);
  }

  void _syncPopupOverlay() {
    if (!mounted) return;
    if (_popup.entries.isEmpty) {
      final OverlayEntry? entry = _popupOverlayEntry;
      if (entry != null) {
        removeAndDisposeOwnedOverlayEntry(entry);
        _popupOverlayEntry = null;
      }
      return;
    }
    if (_popupOverlayEntry != null) {
      _popupOverlayEntry!.markNeedsBuild();
      return;
    }
    final OverlayState? overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final OverlayEntry entry = OverlayEntry(builder: _buildPopupOverlay);
    _popupOverlayEntry = entry;
    overlay.insert(entry);
  }

  Widget _buildPopupOverlay(BuildContext overlayContext) {
    if (!mounted || _overlayInert) return const SizedBox.shrink();
    return FushiAppUiScaleNeutralizer(
      child: Theme(
        data: _appModel.overrideDictionaryTheme ?? Theme.of(overlayContext),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            if (!mounted || _overlayInert) return const SizedBox.shrink();
            final Size screen = Size(
              constraints.maxWidth,
              constraints.maxHeight,
            );
            return Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                if (shouldShowLookupDismissBarrier(
                  hasVisiblePopup: _popup.hasVisiblePopup,
                  isSearching: _popup.isSearchingUi,
                  hiddenByDialog: lookupPopupHiddenByDialog,
                ))
                  Positioned.fill(
                    child: LookupDismissBarrier(
                      onTapDismiss: _onDismissBarrierTap,
                      onSwipeDismiss: () =>
                          _popNestedPopupAt(_popup.lastVisibleIndex),
                      swipeEnabled:
                          ReaderFushiSource.instance.enableSwipeToClose,
                      sensitivity:
                          ReaderFushiSource.instance.dismissSwipeSensitivity,
                    ),
                  ),
                if (_popup.isSearchingUi && _popup.pendingRect != null)
                  buildPopupLoadingPlaceholder(
                    rect: _popup.pendingRect!,
                    screen: screen,
                  ),
                for (int i = 0; i < _popup.entries.length; i++)
                  buildNestedPopupLayer(
                    index: i,
                    screen: screen,
                    controller: _popup,
                    onPush: (String text, Rect rect) => pushNestedPopup(
                      query: text,
                      selectionRect: rect,
                      controller: _popup,
                      autoRead: true,
                    ),
                    onPop: _popNestedPopupAt,
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  // ── 快捷键（与视频页同一注册表、同一动作集合）────────────────────────────

  VideoPlayerShortcutActions _shortcutActions() {
    void noop() {}
    return VideoPlayerShortcutActions(
      togglePlayPause: () => unawaited(_togglePlay()),
      play: () => unawaited(_play()),
      pause: () => unawaited(_pause()),
      previousSubtitle: () => unawaited(_seekToCueOffset(-1)),
      nextSubtitle: () => unawaited(_seekToCueOffset(1)),
      seekBackward: () => unawaited(_seekRelative(-5000)),
      seekForward: () => unawaited(_seekRelative(5000)),
      toggleShaderCompare: noop,
      volumeUp: () => unawaited(
        _js(
          '(function(){var v=document.querySelector("video");if(v)v.volume=Math.min(1,v.volume+0.1);return true;})()',
        ),
      ),
      volumeDown: () => unawaited(
        _js(
          '(function(){var v=document.querySelector("video");if(v)v.volume=Math.max(0,v.volume-0.1);return true;})()',
        ),
      ),
      toggleMute: () => unawaited(_js('window.__fushiWebVideo.toggleMute()')),
      speedUp: () => unawaited(_adjustRate(0.25)),
      speedDown: () => unawaited(_adjustRate(-0.25)),
      resetSpeed: () => unawaited(_setRate(1.0)),
      toggleHoldSpeed: noop,
      previousFrame: () => unawaited(_seekRelative(-40)),
      nextFrame: () => unawaited(_seekRelative(40)),
      screenshot: noop,
      toggleFullscreen: () => unawaited(_toggleFullscreen()),
      toggleSubtitleList: _toggleList,
      searchSubtitleList: () {
        if (!_listVisible) _toggleList();
        _searchRequests.value++;
      },
      toggleImmersiveLock: noop,
      toggleSubtitleBlur: noop,
      cycleSubtitleObscure: noop,
      toggleSubtitleHide: () =>
          setState(() => _overlayHidden = !_overlayHidden),
      cycleSecondarySubtitleObscure: noop,
      toggleSecondarySubtitleHide: noop,
      toggleFavoriteSentence: () => unawaited(_toggleFavoriteCurrent()),
      replayCurrentSubtitle: () {
        final AudioCue? cue = _controller.currentCue ?? _lastLookupCue;
        if (cue != null) unawaited(_seekMs(cue.startMs));
      },
      replayPreviousSubtitle: () => unawaited(_seekToCueOffset(-1)),
      previousChapter: noop,
      nextChapter: noop,
      openSubtitleAlign: noop,
      subtitleDelayIncrease: () =>
          _controller.setDelayMs(_controller.delayMs + 100),
      subtitleDelayDecrease: () =>
          _controller.setDelayMs(_controller.delayMs - 100),
      alignSubtitleToPrev: noop,
      alignSubtitleToNext: noop,
      enterCaret: noop,
      escape: _onEscape,
    );
  }

  Map<ShortcutActivator, VoidCallback> _keyboardShortcuts() =>
      guardVideoShortcutsWithPopupDismiss(
        buildVideoPlayerShortcutsFromRegistry(
          _appModel.shortcutRegistry,
          _shortcutActions(),
        ),
        isPopupVisible: () => _popup.hasVisiblePopup,
        dismissPopup: () => _popNestedPopupAt(_popup.lastVisibleIndex),
      );

  void _onEscape() {
    if (_popup.hasVisiblePopup) {
      _popNestedPopupAt(_popup.lastVisibleIndex);
    } else if (_fullscreen) {
      unawaited(_toggleFullscreen());
    } else if (_listVisible) {
      _toggleList();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  void _toggleList() {
    setState(() => _listVisible = !_listVisible);
    if (!_listVisible) _listHitTester.unbind();
  }

  Future<void> _toggleFullscreen() async {
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) return;
    final bool enter = !_fullscreen;
    setState(() => _fullscreen = enter);
    if (Platform.isWindows) {
      FushiWindowsTitleBar.setContentFullscreen(owner: this, enabled: enter);
    }
    try {
      if (enter) {
        await defaultEnterNativeFullscreen();
      } else {
        await defaultExitNativeFullscreen();
      }
    } catch (e) {
      ErrorLogService.instance.log('web_video', 'fullscreen: $e');
    }
    _focusOwnership.reclaimAfterFrame(FocusReclaimCause.chromeToggled);
  }

  void _selectTrack(String? key) {
    _activeTrackKey = key;
    _reselectTrack();
  }

  // ── build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncPopupOverlay());
    final ColorScheme cs = Theme.of(context).colorScheme;
    final String? fail = _failReason;
    if (fail != null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(child: Text(fail)),
      );
    }
    final VideoBookRow? row = _row;
    final UnmodifiableListView<UserScript>? scripts = _userScripts;
    if (row == null || scripts == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return CallbackShortcuts(
      bindings: _keyboardShortcuts(),
      child: Focus(
        focusNode: _focusNode,
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          appBar: _fullscreen ? null : _buildAppBar(row, cs),
          body: Row(
            children: <Widget>[
              Expanded(
                child: Stack(
                  children: <Widget>[
                    Positioned.fill(
                      child: KeyedSubtree(
                        key: _deathGuard.rebuildKey,
                        child: _buildWebView(row, scripts),
                      ),
                    ),
                    if (!_overlayHidden)
                      Positioned.fill(
                        child: IgnorePointer(
                          ignoring: _controller.currentCue == null,
                          child: VideoSubtitleOverlay(
                            controller: _controller,
                            onCharTap: _handleSubtitleLookupTap,
                            hoverAutoLookupEnabled:
                                ReaderFushiSource.instance.hoverAutoLookup,
                            hitTester: _subtitleHitTester,
                            isCueFavorited: _isCueFavorited,
                            fontFamily: _appModel.subtitleFontFamily,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (_listVisible) _buildListPanel(cs),
            ],
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(VideoBookRow row, ColorScheme cs) {
    final List<WebVideoTrack> mine = <WebVideoTrack>[
      for (final WebVideoTrack t in _tracks.values)
        if (t.videoKey == _videoKey && t.cues.isNotEmpty) t,
    ];
    return AppBar(
      title: Text(
        _state?.title.isNotEmpty == true ? _state!.title : row.title,
        overflow: TextOverflow.ellipsis,
      ),
      actions: <Widget>[
        PopupMenuButton<String>(
          tooltip: t.web_video_track_menu,
          icon: const Icon(Icons.subtitles_outlined),
          onSelected: _selectTrack,
          itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
            if (mine.isEmpty)
              PopupMenuItem<String>(
                enabled: false,
                child: Text(t.web_video_no_tracks),
              ),
            for (final WebVideoTrack track in mine)
              CheckedPopupMenuItem<String>(
                value: track.key,
                checked: track.key == _activeTrackKey,
                child: Text(track.isLive ? t.web_video_track_live : track.lang),
              ),
          ],
        ),
        IconButton(
          tooltip: t.web_video_hide_native_subtitles,
          icon: Icon(
            _hideNativeSubtitles
                ? Icons.closed_caption_disabled_outlined
                : Icons.closed_caption_outlined,
          ),
          onPressed: () {
            setState(() => _hideNativeSubtitles = !_hideNativeSubtitles);
            unawaited(_setNativeSubtitlesHidden(_hideNativeSubtitles));
          },
        ),
        IconButton(
          tooltip: t.video_subtitle_list,
          icon: Icon(
            _listVisible ? Icons.view_sidebar : Icons.view_sidebar_outlined,
          ),
          onPressed: _toggleList,
        ),
        IconButton(
          icon: const Icon(Icons.fullscreen),
          onPressed: () => unawaited(_toggleFullscreen()),
        ),
      ],
    );
  }

  Widget _buildWebView(
    VideoBookRow row,
    UnmodifiableListView<UserScript> scripts,
  ) {
    return InAppWebView(
      webViewEnvironment: _env,
      initialUrlRequest: URLRequest(url: WebUri(row.videoPath)),
      initialUserScripts: scripts,
      initialSettings: InAppWebViewSettings(
        // Windows 生效（fork put_UserAgent）。软件 DRM 档必须去掉 Edg/ 标记，否则
        // Netflix 只试 PlayReady、被垫片拒后不回落 Widevine。
        userAgent: _softwareDrm ? kWebVideoChromeUserAgent : null,
        javaScriptEnabled: true,
        sharedCookiesEnabled: true,
        mediaPlaybackRequiresUserGesture: false,
        disableContextMenu: true,
        supportZoom: false,
      ),
      onWebViewCreated: (InAppWebViewController controller) {
        _web = controller;
        controller.addJavaScriptHandler(
          handlerName: kWebVideoJsHandler,
          callback: _onJsMessage,
        );
        controller.addJavaScriptHandler(
          handlerName: kWebVideoKeyBridgeHandler,
          callback: (List<dynamic> args) {
            _onKeyToken(args);
            return null;
          },
        );
      },
      onLoadStop: (InAppWebViewController controller, WebUri? url) {
        unawaited(_setNativeSubtitlesHidden(_hideNativeSubtitles));
        unawaited(_js('window.__fushiWebVideo.replayCues()'));
      },
      onRenderProcessGone:
          (InAppWebViewController _, RenderProcessGoneDetail detail) =>
              unawaited(
                _deathGuard.handleDeath(
                  didCrash: detail.didCrash,
                  rendererPriorityAtExit: detail.rendererPriorityAtExit,
                ),
              ),
    );
  }

  Widget _buildListPanel(ColorScheme cs) {
    final double panelWidth = (MediaQuery.sizeOf(context).width * 0.32).clamp(
      280.0,
      480.0,
    );
    return PanelFocusScope(
      visible: true,
      restoreFocus: () =>
          _focusOwnership.reclaim(FocusReclaimCause.overlayClosed),
      child: VideoSubtitleJumpPanel(
        key: const ValueKey<String>('web-video-subtitle-jump-panel'),
        controller: _controller,
        onTapCue: (AudioCue cue) {
          _controller.skipToCue(cue);
          unawaited(_seekMs(cue.startMs));
        },
        onLookupCue: _handleListLookup,
        hitTester: _listHitTester,
        onCopyCue: _copyCue,
        onFavoriteCue: _toggleFavoriteCue,
        isCueFavorited: _isCueFavorited,
        fontFamily: _appModel.subtitleFontFamily,
        initialAutoScroll: _appModel.videoSubtitleListAutoScroll,
        onAutoScrollChanged: (bool value) =>
            unawaited(_appModel.setVideoSubtitleListAutoScroll(value)),
        initialFontScaleIndex: _appModel.videoSubtitleListFontScaleIndex,
        onFontScaleIndexChanged: (int value) =>
            unawaited(_appModel.setVideoSubtitleListFontScaleIndex(value)),
        hoverAutoLookupEnabled: ReaderFushiSource.instance.hoverAutoLookup,
        onClose: _toggleList,
        colorScheme: cs,
        title: t.video_subtitle_list,
        emptyHint: t.web_video_no_tracks,
        width: panelWidth,
        searchActivators: <ShortcutActivator>[
          for (final InputBinding b
              in _appModel.shortcutRegistry
                  .bindingsFor(ShortcutAction.videoSearchSubtitleList)
                  .keyboardBindings)
            b.toActivator(includeRepeats: false),
        ],
        searchRequests: _searchRequests,
      ),
    );
  }
}
