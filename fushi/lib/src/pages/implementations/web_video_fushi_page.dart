import 'dart:async';
import 'dart:collection';
import 'dart:convert';
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
import 'package:fushi/src/media/video/web_video_hosting.dart';
import 'package:fushi/src/media/video/web_video_shaders.dart';
import 'package:fushi/src/media/video/video_shader_tier.dart';
import 'package:fushi/src/lookup/global_lookup_controller.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/mining/galgame_audio_encode.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';
import 'package:fushi/src/mining/immersion_mining_engine.dart';
import 'package:fushi/src/mining/immersion_mining_request.dart';
import 'package:fushi/src/mining/web_mine_queue_store.dart';
import 'package:fushi/src/mining/web_mine_replay.dart';
import 'package:fushi/src/pages/implementations/dictionary_page_mixin.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart'
    show MinePopupResult;
import 'package:fushi/src/utils/misc/desktop_audio_clipper.dart'
    show MiningMediaCompression;
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:path_provider/path_provider.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_input_bridge.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/stat_activity.dart'
    show statTodayKey;
import 'package:fushi/src/pages/implementations/video_fushi_page.dart'
    show resolveVideoLookupAnchorCue, subtitleLookupTerm;
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/window_fullscreen_hosts.dart'
    show WindowFullscreenHost;
import 'package:fushi/src/sync/fushi_library_host_service.dart'
    show videoRemotePositionEpisodeAtPrefKey, videoRemotePositionEpisodePrefKey;
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart'
    show adaptivePageRoute;
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
    this.autoRunMineQueue = false,
    this.hosting,
    super.key,
  });

  /// 打开后画面一就绪就自动跑本书的制卡队列（4K 窗口宿主档「切到内置档制卡」的交接）。
  final bool autoRunMineQueue;

  /// 宿主档；null = 读用户偏好 [kWebVideoHostingPrefKey]（缺省内置档）。见 [WebVideoHosting]。
  final WebVideoHosting? hosting;

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
    bool autoRunMineQueue = false,
    WebVideoHosting? hosting,
  }) => FushiAppUiScaleNeutralizer(
    child: WebVideoFushiPage(
      bookUid: bookUid,
      repo: repo,
      autoRunMineQueue: autoRunMineQueue,
      hosting: hosting,
    ),
  );

  /// 窗口宿主档（4K）环境：**不带** `--disable-direct-composition`（硬件 PlayReady 的受保护输出
  /// 要走 DComp overlay），带 fork 的窗口宿主哨兵；浏览器参数与可捕获环境不同 → 必须独立 user
  /// data folder（同目录的环境参数必须逐字一致）→ 独立 cookie 罐，登录态由页面从内置档复制。
  static Future<WebViewEnvironment>? _windowedEnv;

  static String windowedUserDataFolder() {
    // 硬件 PlayReady（MF CDM）要求 profile 住在 %LOCALAPPDATA% 下：真机实测 profile 放在仓库目录
    // （itest 隔离根）时 Netflix 报 D7702-1003，同一份代码 profile 挪到 LOCALAPPDATA 即起播；
    // 生产默认路径本来就在 LOCALAPPDATA（capturableUserDataFolder），itest 用此覆盖指到
    // LOCALAPPDATA 下的独立测试目录（不碰用户真实 profile）。
    final String? override =
        Platform.environment['FUSHI_WEB_VIDEO_4K_USER_DATA_FOLDER'];
    if (override != null && override.isNotEmpty) return override;
    return '${capturableUserDataFolder()}-4k';
  }

  static Future<WebViewEnvironment> windowedEnvironment() {
    return _windowedEnv ??= WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(
        userDataFolder: windowedUserDataFolder(),
        additionalBrowserArguments:
            '--autoplay-policy=no-user-gesture-required '
            '$kWebVideoWindowedHostingSentinel',
      ),
    );
  }

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

  /// 制卡队列真机钩子：把当前 cue（无则位置附近最近一条）按弹窗制卡同一路径入队，
  /// 回队列行 id；`debugRunMineQueue` 跑完整个队列（重放录音/截帧 → 引擎）后返回
  /// 一次重放抓到的媒体大小与 warning（引擎落卡结果看队列行 status/error）。
  @visibleForTesting
  static Future<int?> Function(Map<String, String> fields)?
  debugEnqueueCurrentCue;
  @visibleForTesting
  static Future<List<WebMineReplayCapture>> Function()? debugRunMineQueue;

  /// P2：fork 是否确认超分着色器链已启用；切档钩子供同一时刻做开/关对照截图。
  @visibleForTesting
  static bool Function()? debugShaderActive;
  @visibleForTesting
  static Future<void> Function(VideoShaderTier tier)? debugSelectShaderTier;

  @override
  ConsumerState<WebVideoFushiPage> createState() => _WebVideoFushiPageState();
}

/// 队列重放的宿主适配：位置/播放态取页面状态轮询，seek/播/停走页面 JS，截图走 CDP。
class _WebMineHost implements WebMineReplayHost {
  _WebMineHost(this._page);

  final _WebVideoFushiPageState _page;

  @override
  int? get positionMs => _page._state?.positionMs;

  @override
  bool get isPlaying => _page._state?.isPlaying ?? false;

  @override
  Future<void> seek(int ms) => _page._seekMs(ms);

  @override
  Future<void> play() => _page._play();

  @override
  Future<void> pause() => _page._pause();

  @override
  Future<Uint8List?> screenshot() async {
    try {
      return await _page._web?.takeScreenshot().timeout(
        const Duration(seconds: 8),
      );
    } catch (e) {
      ErrorLogService.instance.log('web_video', 'screenshot: $e');
      return null;
    }
  }
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

  /// 宿主档（`_init` 从参数 / 偏好解析）。窗口宿主档下 WebView2 自己绘制：Flutter 叠层
  /// 画不到它上面，字幕层走页面 DOM、查词走顶层窗口、制卡只入队。
  WebVideoHosting _hosting = WebVideoHosting.builtin;
  bool get _windowed => _hosting == WebVideoHosting.windowed;

  /// 软件 DRM 垫片只在可捕获的内置档有意义；窗口宿主档就是为硬件 DRM 开的。
  bool get _softwareDrm => widget.softwareDrm && !_windowed;

  /// 超分档（计划 P2，仅内置档）：与 mpv 页同一套 Anime4K 文件，经 fork 的 libplacebo 通道跑在
  /// 页面帧上。`_shaderActive` = fork 确认已启用（DLL 缺失 / 窗口档 / 解析失败都为 false）。
  VideoShaderTier _shaderTier = VideoShaderTier.off;
  bool _shaderActive = false;
  Object? _viewId;

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

  /// 自动制卡队列（schema v90 `web_mine_queue`）：观看时入队，本页可捕获档逐句重放落卡。
  late final WebMineQueueStore _mineQueue = WebMineQueueStore(
    _appModel.database,
  );
  int _minePending = 0;
  bool _mineRunning = false;
  bool _mineStopRequested = false;
  ({int done, int total})? _mineProgress;
  bool _autoRunTriggered = false;

  /// 真机钩子收集：非 null 时每句重放抓到的媒体都记一份（只在 debugRunMineQueue 内）。
  List<WebMineReplayCapture>? _debugCaptures;

  /// 窗口宿主档接管 [GlobalLookupController.onHidden] 前的原值（dispose 归还）。
  void Function()? _prevGlobalLookupOnHidden;
  bool _ownsGlobalLookupOnHidden = false;

  void _onGlobalLookupHidden() {
    if (_pausedForLookup) {
      _pausedForLookup = false;
      unawaited(_play());
    }
  }

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
  bool onDictionaryPopupInputToken(String token) {
    final ShortcutAction? action = resolveDictionaryPopupInputToken(
      registry: _appModel.shortcutRegistry,
      token: token,
      scope: ShortcutScope.video,
    );
    if (action == null) return false;
    _popNestedPopupAt(_popup.lastVisibleIndex);
    return true;
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
      WebVideoFushiPage
          .debugEnqueueCurrentCue = (Map<String, String> fields) async {
        final List<AudioCue> cues = _controller.cues;
        final int pos = _state?.positionMs ?? 0;
        final AudioCue? cue =
            _controller.currentCue ??
            (cues.isEmpty ? null : cues[nearestCueIndexAtOrBefore(cues, pos)]);
        if (cue == null) return null;
        _lastLookupCue = cue;
        await onMineEntry(fields);
        final List<WebMineQueueRow> rows = await _mineQueue.pending(
          widget.bookUid,
        );
        return rows.isEmpty ? null : rows.last.id;
      };
      WebVideoFushiPage.debugRunMineQueue = () async {
        _debugCaptures = <WebMineReplayCapture>[];
        await _runMineQueue();
        return _debugCaptures ?? const <WebMineReplayCapture>[];
      };
      WebVideoFushiPage.debugShaderActive = () => _shaderActive;
      WebVideoFushiPage.debugSelectShaderTier = _selectShaderTier;
      return true;
    }());
    // BUG-2230：`_init` 的异常必须有归宿。它是 fire-and-forget，内部又有几处**真会抛**
    // 的 await（`rootBundle.loadString` 资源缺失、`WebViewEnvironment.create` 在 WebView2
    // Runtime 缺失 / 用户数据目录被占用时直接抛、`_copyLoginCookiesFromBuiltin` 的 IO）。
    // 从前抛出后 `_failReason` 恒 null、`_row` 恒 null ⇒ 页面永久停在**无 AppBar 的转圈**
    // 分支上，桌面端没有系统返回键 ⇒ 用户进来就出不去（与 BUG-2229 同构）。
    unawaited(_initGuarded());
  }

  /// [_init] 的异常边界：任何未预期失败都落进已有的**带 AppBar** 失败态，
  /// 而不是把用户锁在无出口的加载态里。
  Future<void> _initGuarded() async {
    try {
      await _init();
    } catch (e, st) {
      debugPrint('WebVideoFushiPage init failed: $e\n$st');
      if (!mounted) return;
      setState(() => _failReason = t.video_load_failed_generic);
    }
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
      WebVideoFushiPage.debugEnqueueCurrentCue = null;
      WebVideoFushiPage.debugRunMineQueue = null;
      WebVideoFushiPage.debugShaderActive = null;
      WebVideoFushiPage.debugSelectShaderTier = null;
      return true;
    }());
    _mineStopRequested = true;
    if (_ownsGlobalLookupOnHidden &&
        identical(
          GlobalLookupController.instance.onHidden,
          _onGlobalLookupHidden,
        )) {
      GlobalLookupController.instance.onHidden = _prevGlobalLookupOnHidden;
    }
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
    _hosting =
        widget.hosting ??
        webVideoHostingFromPref(
          _appModel.prefsRepo.getPref(kWebVideoHostingPrefKey),
        );
    _shaderTier = webVideoShaderTierFromPref(
      _appModel.prefsRepo.getPref(kWebVideoShaderTierPrefKey),
    );
    if (_windowed) {
      // TODO-1233 预留的钩子：顶层查词窗口被用户真正关掉 → 恢复因查词暂停的播放
      //（与内置档弹窗关闭时的 BUG-072 语义一致）。dispose 归还原值。
      _prevGlobalLookupOnHidden = GlobalLookupController.instance.onHidden;
      GlobalLookupController.instance.onHidden = _onGlobalLookupHidden;
      _ownsGlobalLookupOnHidden = true;
    }
    final List<String> assets = <String>[
      // 垫片必须排第一：站点脚本一跑就会抓走原始 EME 函数引用。
      if (_softwareDrm) kWebVideoEmeShimAsset,
      ...webVideoBridgeAssetsForHost(uri.host),
      kWebVideoAdaptersAsset,
      kWebVideoProvidersAsset,
      kWebVideoGlueAsset,
      if (_windowed) kWebVideoDomSubtitlesAsset,
    ];
    final List<String> sources = <String>[];
    for (final String asset in assets) {
      sources.add(await rootBundle.loadString(asset));
    }
    sources.add(_keyBridgeScript());
    _env = _windowed
        ? await WebVideoFushiPage.windowedEnvironment()
        : await WebVideoFushiPage.capturableEnvironment();
    if (!mounted) return;
    if (_windowed) await _copyLoginCookiesFromBuiltin(uri);
    if (!mounted) return;
    unawaited(_refreshFavoriteCache());
    unawaited(_refreshMinePending());
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
      case 'lookup':
        unawaited(_onDomLookup(msg));
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
    // 窗口宿主档：页面 DOM 字幕层从 store 重读同一轨（live 轨边看边长也要跟）。
    if (_windowed) unawaited(_syncDomSubtitleTrack());
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
      // 队列重放期间的 seek/播放是机器驱动，不算观看进度、不计观看时长。
      if (!_mineRunning) {
        _maybePersistPosition(pos);
        _syncWatchTracker(state.isPlaying);
      }
    }
    if (fullscreenChanged) {
      _fullscreen = state.fullscreen;
      if (mounted) setState(() {});
    }
    _maybeAutoRunMineQueue();
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
  Future<void> _setPlayerChromeHidden(bool hidden) =>
      _js('window.__fushiWebVideo.setPlayerChromeHidden($hidden)');

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
        bookUid: widget.bookUid,
        // v92：观看时长 + 字幕字数走唯一时钟 StudyClock（活跃态 = 正在播放，由
        // tracker 挂上）。与本地视频页同一构造——网页档只是换了播放宿主，统计
        // 语义不该因此分叉。
        clock: StudyClock(
          database: db,
          mediaKind: kActivityMediaVideo,
          mediaKey: widget.bookUid,
          title: row.title,
          accrual: StudyAccrual.explicit,
          onWriteError: (Object e, StackTrace st) =>
              ErrorLogService.instance.log('StudyClock.write(web-video)', e, st),
        ),
        loadCoverage: () => db.getPref(videoWatchCoveragePrefKey(widget.bookUid)),
        saveCoverage: (String json) =>
            db.setPref(videoWatchCoveragePrefKey(widget.bookUid), json),
        markCompleted: (String uid) =>
            db.markVideoCompleted(uid, DateTime.now()),
      )..attach(_controller);
      _watchTracker = tracker;
    }
    if (playing) {
      tracker.start();
    } else {
      unawaited(tracker.stop());
    }
  }

  // ── 自动制卡队列（计划 P3）────────────────────────────────────────────────

  /// 观看时点「制卡」**只入队**：观看档可能是硬件 DRM 的 4K 窗口宿主（画面不可捕获、无本地
  /// 媒体源），录不了句子音频/截不了帧。之后在本页（可捕获的 1080p 内置档）按队列逐句重放
  /// 录音 + 截帧再落卡。行里冻结点击那一刻的 Anki 字段（词典释义等）与 cue 时间窗。
  /// 无锚点 cue（还没查过词 / 无字幕轨）时退回 mixin 的纯字段制卡，行为与改动前一致。
  @override
  Future<MinePopupResult> onMineEntry(Map<String, String> fields) async {
    final AudioCue? cue = _lastLookupCue ?? _controller.currentCue;
    final VideoBookRow? row = _row;
    if (cue == null || row == null) return super.onMineEntry(fields);
    await _enqueueMine(fields, cue, row);
    FushiToast.show(msg: t.web_video_mine_queued(count: _minePending));
    // 卡还没真落地：不把弹窗按钮画成 ✓（弹窗侧「未知结局不重画」契约，TODO-448）。
    return const MinePopupResult();
  }

  Future<void> _enqueueMine(
    Map<String, String> fields,
    AudioCue cue,
    VideoBookRow row,
  ) async {
    final String fieldSentence = (fields['sentence'] ?? '').trim();
    await _mineQueue.enqueue(
      bookUid: widget.bookUid,
      videoKey: _videoKey,
      href: _state?.href.isNotEmpty == true ? _state!.href : row.videoPath,
      cueStartMs: cue.startMs,
      cueEndMs: cue.endMs,
      sentence: fieldSentence.isEmpty ? cue.text.trim() : fieldSentence,
      cueSentence: cue.text,
      fields: fields,
    );
    await _refreshMinePending();
  }

  Future<void> _refreshMinePending() async {
    final int n = await _mineQueue.pendingCount(widget.bookUid);
    if (!mounted) return;
    setState(() => _minePending = n);
    _maybeAutoRunMineQueue();
  }

  void _maybeAutoRunMineQueue() {
    if (!widget.autoRunMineQueue || _autoRunTriggered || _mineRunning) return;
    if (_minePending == 0 || !(_state?.hasVideo ?? false)) return;
    _autoRunTriggered = true;
    unawaited(_runMineQueue());
  }

  /// 队列行属于别的视频（换集后入队的）：先导航过去等画面就绪。
  Future<bool> _navigateForMining(WebMineQueueRow row) async {
    final InAppWebViewController? web = _web;
    if (web == null) return false;
    await web.loadUrl(urlRequest: URLRequest(url: WebUri(row.href)));
    final DateTime until = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(until)) {
      if (!mounted || _mineStopRequested) return false;
      if (_videoKey == row.videoKey && (_state?.hasVideo ?? false)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return false;
  }

  Future<void> _runMineQueue() async {
    if (_mineRunning || _row == null) return;
    final List<WebMineQueueRow> rows = await _mineQueue.pending(widget.bookUid);
    if (!mounted) return;
    if (rows.isEmpty) {
      FushiToast.show(msg: t.web_video_mine_queue_empty);
      return;
    }
    setState(() {
      _mineRunning = true;
      _mineStopRequested = false;
      _mineProgress = (done: 0, total: rows.length);
    });
    final int? resumePos = _state?.positionMs;
    unawaited(_watchTracker?.stop());
    if (_popup.hasVisiblePopup) _popNestedPopupAt(0);
    // 封面不带站点控制栏（Dart 驱动的 seek/pause 会让控件浮出来）。
    await _setPlayerChromeHidden(true);
    // WASAPI loopback（整机混音，60 s 环形缓冲）；非 Windows / 插件缺失 → null → 只截帧。
    final LoopbackGalAudioSource loopback = LoopbackGalAudioSource();
    final PcmFormat? format = await loopback.start();
    final String tempDir = (await getTemporaryDirectory()).path;
    final MiningMediaCompression compression = MiningMediaCompression.resolve(
      imageTier: _appModel.miningImageQuality,
      audioTier: _appModel.miningAudioQuality,
      format: _appModel.videoMiningAnimatedFormat,
    );
    final WebMineReplayRunner runner = WebMineReplayRunner(
      host: _WebMineHost(this),
      audioSource: format == null ? null : loopback,
      encodeAudio: (GalAudioSlice slice) => pcmSliceToAacBytes(
        pcm: slice.pcm,
        format: slice.format,
        tempDir: tempDir,
        outputExtension: immersionMiningAudioExtension(),
        audioChannels: compression.audioChannels,
        audioBitrate: compression.audioBitrate,
      ),
    );
    int ok = 0;
    int failed = 0;
    try {
      for (final WebMineQueueRow row in rows) {
        if (!mounted || _mineStopRequested) break;
        if (row.videoKey != _videoKey && !await _navigateForMining(row)) {
          await _mineQueue.markFailed(row.id, 'navigate_timeout');
          failed++;
        } else {
          final WebMineReplayCapture cap = await runner.capture(
            cueStartMs: row.cueStartMs,
            cueEndMs: row.cueEndMs,
          );
          _debugCaptures?.add(cap);
          final String? error = await _mineQueuedRow(
            row,
            cap,
            compression,
            tempDir,
          );
          if (error == null) {
            ok++;
          } else {
            failed++;
          }
        }
        if (mounted) {
          setState(
            () => _mineProgress = (done: ok + failed, total: rows.length),
          );
        }
      }
    } finally {
      await loopback.stop();
      await _setPlayerChromeHidden(false);
      if (mounted) {
        setState(() {
          _mineRunning = false;
          _mineProgress = null;
        });
        if (resumePos != null) unawaited(_seekMs(resumePos));
        unawaited(_refreshMinePending());
      }
    }
    FushiToast.show(
      msg: t.web_video_mine_queue_finished(ok: ok, failed: failed),
    );
  }

  /// 抓到的媒体 + 行里冻结的字段 → 沉浸制卡引擎。返回 null = 成功；否则失败原因
  /// （已写进队列行 error 列）。
  Future<String?> _mineQueuedRow(
    WebMineQueueRow row,
    WebMineReplayCapture cap,
    MiningMediaCompression compression,
    String tempDir,
  ) async {
    final String? title = _row?.title;
    final ImmersionMiningResult res;
    try {
      res = await ImmersionMiningEngine().mine(
        ImmersionMiningRequest(
          fields: decodeWebMineFields(row.fieldsJson),
          clipStartMs: row.cueStartMs,
          clipEndMs: row.cueEndMs,
          sentence: row.sentence,
          cueSentence: row.cueSentence,
          documentTitle: title,
          source: AnkiMiningSource.video,
          bookTitleTag: _appModel.autoAddBookNameToTags
              ? BaseAnkiRepository.sanitizeTitleTag(title)
              : null,
          providedCoverBytes: cap.cover,
          providedCoverName: 'web_video_cover.png',
          providedAudioBytes: cap.audio,
          providedAudioName:
              'web_video_audio.${immersionMiningAudioExtension()}',
          // 录不到音（无 loopback / 站点静音）也出截图卡：用户排队等的是这张卡，
          // 缺音频记进行 warning 而不是整行报废。
          requireAudio: false,
          stillFormat: _appModel.videoMiningStillFormat,
        ),
        compression: compression,
        tempDir: tempDir,
        repo: ref.read(ankiRepositoryProvider),
      );
    } catch (e, st) {
      ErrorLogService.instance.log('web_video.mineQueue', e, st);
      await _mineQueue.markFailed(row.id, '$e');
      return '$e';
    }
    if (res.aborted) {
      final String reason = res.abortReason ?? 'aborted';
      await _mineQueue.markFailed(row.id, reason);
      return reason;
    }
    final Object? outcome = res.outcome;
    if (outcome is! MineOutcome) {
      await _mineQueue.markFailed(row.id, 'no_outcome');
      return 'no_outcome';
    }
    final described = describeMineOutcome(outcome);
    if (!described.success) {
      await _mineQueue.markFailed(row.id, described.message);
      return described.message;
    }
    if (described.record) unawaited(recordMined());
    await _mineQueue.markDone(
      row.id,
      noteId: outcome.noteId,
      warning: cap.warnings.isEmpty ? null : cap.warnings.join(','),
    );
    return null;
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

  /// 字幕列表行内复制。走 [AppModel.copyToClipboard]：写剪贴板 + 按平台决定要不要
  /// 弹「已复制」toast（Android 13+ 系统自带提示，不重复）。网页视频页没有视频页那套
  /// OSD，此前这里复制完毫无反馈。
  /// 返回是否真的写了剪贴板（[VideoSubtitleJumpPanel.onCopyCue] 的契约）：空句不算
  /// 成功，面板据此决定要不要把行内按钮切成 ✓。
  bool _copyCue(AudioCue cue) {
    final String text = cue.text.trim();
    if (text.isEmpty) return false;
    _appModel.copyToClipboard(text);
    return true;
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
    if (_windowed) {
      // Flutter 弹窗会被 WebView2 子窗口盖住：列表面板点词也走顶层查词窗口（无屏幕锚点 →
      // 回落光标定位）。
      await GlobalLookupController.instance.lookupText(
        term,
        sentence: sentence,
        autoRead: true,
        miningHandler: _mineFromGlobalLookup,
      );
      return;
    }
    await pushNestedPopup(
      query: term,
      selectionRect: charRect,
      controller: _popup,
      replaceStack: true,
      reuseWarmSlot: true,
      autoRead: true,
    );
  }

  // ── 窗口宿主档：DOM 字幕层点词 → 顶层查词窗口 ────────────────────────────

  Future<void> _onDomLookup(Map<dynamic, dynamic> msg) async {
    final WebVideoLookupRequest? req = parseWebVideoLookupPayload(msg);
    if (req == null) return;
    if (req.isHover && !ReaderFushiSource.instance.hoverAutoLookup) return;
    final String term = subtitleLookupTerm(req.sentence, req.graphemeIndex);
    if (term.isEmpty) return;
    if (!req.isHover && _controller.isPlaying) {
      _pausedForLookup = true;
      unawaited(_pause());
    }
    AudioCue? cue;
    for (final AudioCue c in _controller.cues) {
      if (c.startMs == req.cueStartMs && c.text == req.sentence) {
        cue = c;
        break;
      }
    }
    _lastLookupCue = cue ?? _controller.currentCue;
    await GlobalLookupController.instance.lookupText(
      term,
      sentence: req.sentence,
      anchorScreenRect: webVideoLookupAnchorScreenRect(req),
      autoRead: true,
      miningHandler: _mineFromGlobalLookup,
    );
  }

  /// 顶层查词窗口里点「制卡」：与弹窗同一条入队路径，回 popup.js 形状的结果（卡未落地 →
  /// ankiConnect=false + 提示文案，浮窗不画 ✓）。无锚点 cue 时退回纯字段制卡。
  Future<Map<String, Object?>> _mineFromGlobalLookup({
    required Map<String, String> fields,
    int? updateNoteId,
  }) async {
    final AudioCue? cue = _lastLookupCue ?? _controller.currentCue;
    final VideoBookRow? row = _row;
    if (cue == null || row == null) {
      final MinePopupResult r = await super.onMineEntry(fields);
      return <String, Object?>{
        'ankiConnect': r.ankiConnect,
        'noteId': r.noteId,
        if (r.duplicate) 'duplicate': true,
      };
    }
    await _enqueueMine(fields, cue, row);
    return <String, Object?>{
      'ankiConnect': false,
      'message': t.web_video_mine_queued(count: _minePending),
    };
  }

  Future<void> _syncDomSubtitleTrack() {
    final String key = jsonEncode(_activeTrackKey ?? '');
    return _js('window.__fushiDomSubs && window.__fushiDomSubs.setTrack($key)');
  }

  /// DOM 字幕层的样式 / 悬停查词 / 延迟 / 显隐一次同步（页面加载完、切换显隐、调轴后）。
  Future<void> _syncDomSubtitles() async {
    if (!_windowed) return;
    final String font = jsonEncode(_appModel.subtitleFontFamily);
    await _js(
      'window.__fushiDomSubs && ('
      'window.__fushiDomSubs.setStyle({fontFamily: $font}),'
      'window.__fushiDomSubs.setHoverAuto('
      '${ReaderFushiSource.instance.hoverAutoLookup}),'
      'window.__fushiDomSubs.setDelay(${_controller.delayMs}),'
      'window.__fushiDomSubs.setEnabled(${!_overlayHidden}))',
    );
    await _syncDomSubtitleTrack();
  }

  /// 窗口宿主档用独立环境（浏览器参数不同 → 独立 user data folder → 独立 cookie 罐）：把内置档
  /// 已登录的站点 cookie 复制过来，用户不用登录两次。尽力而为，失败只记日志（站点会要求登录）。
  Future<void> _copyLoginCookiesFromBuiltin(Uri uri) async {
    final WebViewEnvironment? to = _env;
    if (to == null) return;
    try {
      final WebViewEnvironment from =
          await WebVideoFushiPage.capturableEnvironment();
      final WebUri url = WebUri('${uri.scheme}://${uri.host}/');
      final List<Cookie> cookies = await CookieManager.instance(
        webViewEnvironment: from,
      ).getCookies(url: url);
      final CookieManager dst = CookieManager.instance(webViewEnvironment: to);
      for (final Cookie c in cookies) {
        await dst.setCookie(
          url: url,
          name: c.name,
          value: c.value.toString(),
          domain: c.domain,
          path: c.path ?? '/',
          // 会话 cookie 不带 expires（fork 已把 CDP 的秒转成毫秒、会话回 null）。
          expiresDate: c.isSessionOnly == true ? null : c.expiresDate,
          isSecure: c.isSecure,
          isHttpOnly: c.isHttpOnly,
        );
      }
    } catch (e) {
      ErrorLogService.instance.log('web_video', 'cookie copy: $e');
    }
  }

  /// 切宿主档 / 交接制卡：同一本书原地重开本页。
  Future<void> _reopen({
    required WebVideoHosting hosting,
    bool autoRunMineQueue = false,
  }) async {
    if (!mounted) return;
    await Navigator.of(context).pushReplacement(
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => WebVideoFushiPage.neutralized(
          bookUid: widget.bookUid,
          repo: widget.repo,
          hosting: hosting,
          autoRunMineQueue: autoRunMineQueue,
        ),
      ),
    );
  }

  // ── 超分档（计划 P2，内置档）────────────────────────────────────────────

  Future<void> _applyShaderTier() async {
    if (_windowed || _viewId == null) return;
    bool ok = false;
    try {
      final List<String> texts = await loadWebVideoShaderTexts(_shaderTier);
      final bool accepted = await applyWebVideoShaders(_viewId, texts);
      ok = accepted && texts.isNotEmpty;
      // 诊断（进 error_log）：档位 / 文本数 / fork 是否收下——三者分别对应文件缺失、
      // DLL 缺失、通道不通，真机排障时不用猜。
      ErrorLogService.instance.log(
        'web_video',
        'shaders tier=${_shaderTier.name} texts=${texts.length} '
            'accepted=$accepted viewId=$_viewId',
      );
    } catch (e) {
      ErrorLogService.instance.log('web_video', 'shaders: $e');
    }
    if (!mounted) return;
    setState(() => _shaderActive = ok);
  }

  Future<void> _selectShaderTier(VideoShaderTier tier) async {
    _shaderTier = tier;
    await _appModel.prefsRepo.setPref(kWebVideoShaderTierPrefKey, tier.name);
    await _applyShaderTier();
  }

  String _shaderTierLabel(VideoShaderTier tier) => switch (tier) {
    VideoShaderTier.off => t.video_shader_tier_off,
    VideoShaderTier.low => t.video_shader_tier_low,
    VideoShaderTier.medium => t.video_shader_tier_medium,
    VideoShaderTier.high => t.video_shader_tier_high,
    VideoShaderTier.ultra => t.video_shader_tier_ultra,
  };

  Future<void> _switchHosting(WebVideoHosting hosting) async {
    if (hosting == _hosting) return;
    await _appModel.prefsRepo.setPref(kWebVideoHostingPrefKey, hosting.name);
    await _flushPosition();
    await _reopen(hosting: hosting);
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
                      // 弹窗可见时 barrier 吃掉全部指针，页面根收不到——「浮窗矩形
                      // 之外」按鼠标非主键这半边只能在这里接（见钩子文档）。
                      onNonPrimaryButtonDown: onDismissBarrierNonPrimaryButton,
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
                ...buildParkedRealmLayers(screen: screen, controller: _popup),
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
      toggleSubtitleHide: () {
        setState(() => _overlayHidden = !_overlayHidden);
        unawaited(_syncDomSubtitles());
      },
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
      // BUG-2230：加载态也必须带 AppBar（= 返回键）。出口不是内容的一部分、不随内容
      // 存亡（漫画页 manga_fushi_page 早已是这个口径）：本页的正常退出入口在
      // [_buildAppBar]，而那只挂在下面的**就绪**分支上；WebView2 环境创建 / 资源加载
      // 慢或悬挂时，桌面端没有系统返回键，用户就被钉在这个转圈上。
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    // 网页流媒体页属于视频模块，同样是**窗口全屏的合法宿主**（见
    // [WindowFullscreenHosts]）。上面两条早退分支（加载失败 / 尚未就绪）故意不声明：
    // 那两种状态下页面还没有内容，没有可全屏的东西。
    final Widget page = CallbackShortcuts(
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
                    if (!_overlayHidden && !_windowed)
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
    return WindowFullscreenHost(child: page);
  }

  PreferredSizeWidget _buildAppBar(VideoBookRow row, ColorScheme cs) {
    final List<WebVideoTrack> mine = <WebVideoTrack>[
      for (final WebVideoTrack t in _tracks.values)
        if (t.videoKey == _videoKey && t.cues.isNotEmpty) t,
    ];
    final ({int done, int total})? progress = _mineProgress;
    return AppBar(
      title: Text(
        progress != null
            ? t.web_video_mine_queue_running(
                done: progress.done,
                total: progress.total,
              )
            : (_state?.title.isNotEmpty == true ? _state!.title : row.title),
        overflow: TextOverflow.ellipsis,
      ),
      actions: <Widget>[
        PopupMenuButton<WebVideoHosting>(
          tooltip: t.web_video_hosting_menu,
          icon: Icon(_windowed ? Icons.four_k_outlined : Icons.hd_outlined),
          onSelected: (WebVideoHosting h) => unawaited(_switchHosting(h)),
          itemBuilder: (BuildContext context) =>
              <PopupMenuEntry<WebVideoHosting>>[
                CheckedPopupMenuItem<WebVideoHosting>(
                  value: WebVideoHosting.builtin,
                  checked: !_windowed,
                  child: Text(t.web_video_hosting_builtin),
                ),
                CheckedPopupMenuItem<WebVideoHosting>(
                  value: WebVideoHosting.windowed,
                  checked: _windowed,
                  child: Text(t.web_video_hosting_windowed),
                ),
              ],
        ),
        if (!_windowed)
          // 超分档只有内置档有（窗口档画面归硬件 DRM，碰不到帧）。low = mpv 内置缩放档，
          // 网页帧没有 mpv 缩放器，这里不列。
          PopupMenuButton<VideoShaderTier>(
            tooltip: t.video_shader_tier_off,
            icon: Icon(
              _shaderActive
                  ? Icons.auto_fix_high
                  : Icons.auto_fix_high_outlined,
            ),
            onSelected: (VideoShaderTier tier) =>
                unawaited(_selectShaderTier(tier)),
            itemBuilder: (BuildContext context) =>
                <PopupMenuEntry<VideoShaderTier>>[
                  for (final VideoShaderTierSpec spec in kVideoShaderTiers)
                    if (spec.tier != VideoShaderTier.low)
                      CheckedPopupMenuItem<VideoShaderTier>(
                        value: spec.tier,
                        checked: spec.tier == _shaderTier,
                        child: Text(_shaderTierLabel(spec.tier)),
                      ),
                ],
          ),
        if (_windowed)
          // 窗口宿主档不能录/截（画面归硬件 DRM）：队列交给内置档重放。
          IconButton(
            tooltip: t.web_video_mine_switch_builtin(count: _minePending),
            icon: Badge.count(
              count: _minePending,
              isLabelVisible: _minePending > 0,
              child: const Icon(Icons.auto_awesome_motion_outlined),
            ),
            onPressed: _minePending == 0
                ? null
                : () => unawaited(
                    _reopen(
                      hosting: WebVideoHosting.builtin,
                      autoRunMineQueue: true,
                    ),
                  ),
          )
        else if (_mineRunning)
          IconButton(
            tooltip: t.web_video_mine_queue_stop,
            icon: const Icon(Icons.stop_circle_outlined),
            onPressed: () => _mineStopRequested = true,
          )
        else
          IconButton(
            tooltip: t.web_video_mine_queue_run,
            icon: Badge.count(
              count: _minePending,
              isLabelVisible: _minePending > 0,
              child: const Icon(Icons.auto_awesome_motion_outlined),
            ),
            onPressed: _minePending == 0
                ? null
                : () => unawaited(_runMineQueue()),
          ),
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
        _viewId = controller.platform.id;
        unawaited(_applyShaderTier());
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
        unawaited(_syncDomSubtitles());
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
