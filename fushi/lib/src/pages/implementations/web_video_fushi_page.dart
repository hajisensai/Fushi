import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show FushiRubySpan;
import 'package:media_kit_video/media_kit_video.dart'
    show defaultEnterNativeFullscreen, defaultExitNativeFullscreen;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/focus/page_focus_ownership.dart';
import 'package:fushi/src/utils/components/fushi_adaptive_action_strip.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart'
    show fushiTopBarActionsBudget;
import 'package:fushi/src/focus/panel_focus_scope.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_m3e_chrome.dart';
import 'package:fushi/src/media/video/video_m3e_panel_theme.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_current_line_copy.dart';
import 'package:fushi/src/media/video/video_player_shortcuts.dart';
import 'package:fushi/src/media/video/video_subtitle_jump_panel.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi/src/media/video/video_watch_tracker.dart';
import 'package:fushi/src/media/video/web_video_bridge.dart';
import 'package:fushi/src/media/video/web_video_hosting.dart';
import 'package:fushi/src/media/video/web_video_session.dart';
import 'package:fushi/src/media/video/underlay_composition.dart'
    show underlayCompositionSupported;
import 'package:fushi/src/media/video/web_video_shaders.dart';
import 'package:fushi/src/media/video/video_shader_tier.dart';
import 'package:fushi/src/lookup/global_lookup_controller.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/mining/galgame_audio_encode.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';
import 'package:fushi/src/mining/immersion_capture_channel.dart'
    show ImmersionCaptureResult, transcodeClipToCapture;
import 'package:fushi/src/mining/immersion_mining_engine.dart';
import 'package:fushi/src/mining/mining_image_mode_target.dart';
import 'package:fushi/src/mining/web_mine_clip.dart';
import 'package:fushi_engine/mining/immersion_mining_request.dart';
import 'package:fushi/src/mining/web_mine_idle.dart';
import 'package:fushi/src/mining/web_mine_queue_store.dart';
import 'package:fushi/src/mining/web_mine_replay.dart';
import 'package:fushi/src/media/video/web_mine_auto_status.dart';
import 'package:fushi/src/media/video/web_mine_return_state.dart';
import 'package:fushi/src/pages/implementations/dictionary_page_mixin.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart'
    show MinePopupResult;
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart'
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
    show
        VideoFushiPage,
        miningClipTimeMs,
        resolveVideoLookupAnchorCue,
        subtitleLookupTerm;
import 'package:fushi/src/pages/implementations/subtitle_workbench_page.dart'
    show AppSubtitleWorkbenchHost;
import 'package:fushi/src/media/video/subtitle/remote_online_subtitle_search.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_search_seed.dart';
import 'package:fushi/src/media/video/video_remote_binding_support.dart';
import 'package:fushi/src/media/video/video_resource_check.dart'
    show isLocalVideoResourceMissing;
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/sync/video_remote_host.dart';
import 'package:fushi_engine/media/video/youtube_source_resolver.dart'
    show youtubeVideoIdOrNull;
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart'
    show RemoteMineResult;
import 'package:fushi_engine/sync/immersion_mine_payload.dart';
import 'package:fushi_engine/sync/video_remote_service.dart';
import 'package:path/path.dart' as p;
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/window_fullscreen_hosts.dart'
    show WindowFullscreenHost;
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show videoRemotePositionEpisodeAtPrefKey, videoRemotePositionEpisodePrefKey;
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart'
    show adaptivePageRoute;
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi/src/utils/components/fushi_desktop_title_bar.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/window_caption_channel.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/lookup_dismiss_barrier.dart';
import 'package:fushi/src/utils/overlay_entry_lifecycle.dart';
import 'package:fushi/src/webview/webview_death_guard.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
import 'package:fushi/src/utils/components/fushi_loading_view.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/webview/web_payload_limits.dart';

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
    this.returnHostingAfterMining,
    this.idleAutoMining = false,
    this.mineReturnState,
    this.closeAfterMining = false,
    super.key,
  });

  /// 本页是后台空闲自动制卡打开的（[WebMineBackgroundRunner]：用户没开着播放页）：
  /// 跑完 / 让位 / 放弃后直接关页，不恢复播放状态。
  final bool closeAfterMining;

  /// 打开后画面一就绪就自动跑本书的制卡队列（4K 窗口宿主档「切到内置档制卡」的交接）。
  final bool autoRunMineQueue;

  /// 非 null = 本页是制卡交接（窗口宿主档 / 原生播放器页帧不可截，换到内置档重放）：跑完 /
  /// 停止 / 让位后原地换回这一档，并把 [mineReturnState] 带回去。
  final WebVideoHosting? returnHostingAfterMining;

  /// 交接的这一轮是**空闲自动制卡**（有输入即让位、只用静音录音）；false = 用户点的。
  final bool idleAutoMining;

  /// 重放前用户的播放状态（站点字幕轨 / 音轨 / 位置）。交接页：重放按其中的音轨录音，结束后
  /// 带回原档；非交接页（被换回来的那一页）：画面就绪后原样恢复。见 [WebMineReturnState]。
  final WebMineReturnState? mineReturnState;

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

  /// 可捕获（内置档）WebView2 环境：与原生播放器页的网页档共用同一份单例（同一 user data
  /// folder 只能有一套浏览器参数），实现见 [webVideoCapturableEnvironment]。
  static String capturableUserDataFolder() =>
      webVideoCapturableUserDataFolder();

  static Future<WebViewEnvironment> capturableEnvironment() =>
      webVideoCapturableEnvironment();

  /// 打开本页的唯一入口：路由层包 [FushiAppUiScaleNeutralizer]（WebView2 是平台纹理，
  /// 落在缩放画布里会被栅格化再放大 → 糊；与 `VideoFushiPage.neutralized` 同理）。
  static Widget neutralized({
    required String bookUid,
    required VideoBookRepository repo,
    bool autoRunMineQueue = false,
    WebVideoHosting? hosting,
    WebVideoHosting? returnHostingAfterMining,
    bool idleAutoMining = false,
    WebMineReturnState? mineReturnState,
    bool closeAfterMining = false,
  }) => FushiAppUiScaleNeutralizer(
    child: WebVideoFushiPage(
      bookUid: bookUid,
      repo: repo,
      autoRunMineQueue: autoRunMineQueue,
      hosting: hosting,
      returnHostingAfterMining: returnHostingAfterMining,
      idleAutoMining: idleAutoMining,
      mineReturnState: mineReturnState,
      closeAfterMining: closeAfterMining,
    ),
  );

  /// 窗口宿主档（4K）环境：同上，见 [webVideoWindowedEnvironment]。
  static String windowedUserDataFolder() => webVideoWindowedUserDataFolder();

  static Future<WebViewEnvironment> windowedEnvironment() =>
      webVideoWindowedEnvironment();

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

  @override
  Future<Uint8List?> frame() async {
    try {
      return await _page._web
          ?.takeScreenshot(
            screenshotConfiguration: ScreenshotConfiguration(
              compressFormat: CompressFormat.JPEG,
              quality: 85,
            ),
          )
          .timeout(const Duration(seconds: 2));
    } catch (e) {
      ErrorLogService.instance.logDiagnostic('web_video', 'frame: $e');
      return null;
    }
  }
}

/// 一句卡最终用的图片 / 音频（[_WebVideoFushiPageState._resolveCardMedia]）。
typedef _WebMineCardMedia = ({
  VideoMiningImageMode imageMode,
  Uint8List? cover,
  String coverName,
  Uint8List? audio,
  List<String> warnings,
});

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

  /// 本页站点（登录 cookie 进出都按它的 host）；环境准备好之前为 null。
  Uri? _siteUri;
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

  /// 用户（或手机遥控）显式关了字幕：[_reselectTrack] 不再自动挑轨。
  bool _subtitlesOff = false;

  /// 手机遥控绑定（[_registerRemote]）；null = 没登记（制卡交接页 / 已离页）。
  VideoRemotePlaybackBinding? _remoteBinding;
  final VideoRemoteCueCache _remoteCueCache = VideoRemoteCueCache();

  /// 播放控制意图计数（[_seekMs] / [_play] / [_pause] 等每次 +1），手机遥控的 `controlRevision`。
  int _remoteControlRevision = 0;

  /// 手机试听的终点（播放器轴毫秒）：播到就暂停；null = 没在试听。
  int? _remotePreviewEndMs;

  /// 手机「在线搜索字幕」的执行体（候选按 id 记在里面，随本页释放）。
  late final RemoteOnlineSubtitleSearch _remoteOnlineSubtitles =
      RemoteOnlineSubtitleSearch(
        registry: _appModel.subtitleSearchRegistry,
        preferredLanguageFor: AppSubtitleWorkbenchHost(
          _appModel,
        ).preferredLanguageFor,
        saveDirectory: AppPaths.videoSubtitlesDirectory,
      );
  String _videoKey = '';
  WebVideoPlaybackState? _state;

  /// WebView 自己报的当前地址（导航回调给的，可信）；页面上报的 href 对它核主机。
  String? _webViewUrl;

  /// M3E 顶栏胶囊的显隐（[VideoM3eChromeSlide] 的输入）：本页顶栏只随全屏整体卸载，
  /// 挂载即可见；每次（重新）挂载都从上方弹入。
  final ValueNotifier<bool> _m3eChromeVisible = ValueNotifier<bool>(true);

  /// M3E 顶栏三枚下拉菜单钮：外观归 [VideoM3eIconButton]，菜单经这些 key 弹出
  /// （见 [_m3eMenuButton]）。
  final GlobalKey<PopupMenuButtonState<WebVideoHosting>> _hostingMenuKey =
      GlobalKey<PopupMenuButtonState<WebVideoHosting>>();
  final GlobalKey<PopupMenuButtonState<VideoShaderTier>> _shaderMenuKey =
      GlobalKey<PopupMenuButtonState<VideoShaderTier>>();
  final GlobalKey<PopupMenuButtonState<String>> _trackMenuKey =
      GlobalKey<PopupMenuButtonState<String>>();

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

  /// 本轮是空闲自动制卡（静音重放、有输入即让位），不是用户点的。
  bool _mineAuto = false;

  /// 空闲自动制卡给用户看的状态胶囊（结果态留到用户关掉）。
  WebMineAutoStatus? _autoStatus;

  /// 空闲判定 + 让位（仅 Windows：判据是 `GetLastInputInfo`，静音录音也只有 Windows）。
  WebMineIdleScheduler? _idleScheduler;

  /// 内置档第一次开播时查一次上次崩溃留下的「会话音量被压低」残留（见
  /// [LoopbackGalAudioSource.restoreDuckedSessions]）。
  bool _duckResidueChecked = false;

  /// 空闲交接页在 WebView 建出来之前就起好的静音采集（站点一加载就会自动播放，等开跑再
  /// 压低就外放了几秒）。开跑时由 [_startReplayAudio] 接手；没开跑就离页由 dispose 停掉。
  ({LoopbackGalAudioSource source, PcmFormat format})? _preStartedAudio;
  Future<void>? _preStartFuture;

  /// 最近一次静音采集起不来的原因码（[LoopbackGalAudioSource.lastStartError]）。
  String? _silentStartError;

  /// 本页静音采集因暂时性原因（找不到进程 / 忙）失败过：本页不再自动开跑。系统不支持
  /// 则是进程级的 [WebMineIdleScheduler.silentCaptureUnavailable]。
  bool _autoGaveUp = false;

  /// [_closeAfterMining] 已经关过页（让位 / 放弃 / 跑完可能先后都走到收尾）。
  bool _closedAfterMining = false;

  /// 空闲自动制卡页（交接页 / 后台制卡页）的开跑截止：页面开了却一直没开跑（加载失败、
  /// 站点停在登录 / 选人页、打开时队列已被别处跑空）就按放弃收尾，不让一页无人值守的
  /// 网页视频挂到用户回来、也不让后台调度卡在这一本上。
  Timer? _autoStartDeadline;

  /// 本页是制卡宿主（交接页 / 后台制卡页），不是用户自己在看的那一页：WebView 一建好
  /// 就要静音（站点会自动播放），也不做用户本人才有的「会话音量残留还原」。
  bool get _isMiningHost =>
      widget.returnHostingAfterMining != null || widget.closeAfterMining;

  /// 自动制卡已触发、但还在起音频 / 读队列（[_mineRunning] 尚未置位）时用户回来了：
  /// 开跑那一刻直接让位。
  bool _autoYieldRequested = false;

  /// 本轮重放前用户的状态（交接页取 [WebVideoFushiPage.mineReturnState]，原页取开跑时的快照）。
  WebMineReturnState? _replayOrigin;

  /// 待恢复的播放状态：画面就绪后由 [_applyPendingRestore] 逐拍对齐（站点轨清单可能晚到）。
  WebMineReturnState? _pendingRestore;
  DateTime? _pendingRestoreDeadline;
  DateTime? _lastRestoreActionAt;
  bool _restoreNavigated = false;

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
  ModuleId? get popupDockModule => ModuleId.video;

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
    if (widget.idleAutoMining) {
      _autoStartDeadline = Timer(kWebMineAutoStartTimeout, _onAutoStartTimeout);
    }
    unawaited(_initGuarded());
  }

  /// 空闲自动制卡页到点仍没开跑：整轮放弃（交接页换回原档，后台制卡页关页）。
  void _onAutoStartTimeout() {
    if (!mounted || _autoRunTriggered || _mineRunning) return;
    _autoRunTriggered = true;
    ErrorLogService.instance.log(
      'web_video.mineQueue',
      'idle auto mining never started: '
          'row=${_row != null} hasVideo=${_state?.hasVideo ?? false} '
          'pending=$_minePending fail=$_failReason',
    );
    _finishMining(auto: true, status: const WebMineAutoUnavailable());
  }

  /// [_init] 的异常边界：任何未预期失败都落进已有的**带 AppBar** 失败态，
  /// 而不是把用户锁在无出口的加载态里。
  Future<void> _initGuarded() async {
    try {
      await _init();
    } catch (e, st) {
      // release 版 Windows 上 stdout 无人接收，debugPrint 等于丢弃——而 BUG-2230
      // 的立论就是「异常无归宿」。给了用户归宿（失败终态）就不能把诊断也扔了：
      // WebViewEnvironment.create 失败 / 资源缺失 / cookie 拷贝 IO 错这三类根因
      // 只有落进 error_log 才区分得出来。
      ErrorLogService.instance.log('web_video', 'init failed: $e', st);
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
    _unregisterRemote();
    _autoStartDeadline?.cancel();
    // 本页里登录的站点会话抄回 app 内浏览器（登录入口主要在浏览器，BUG-3801）。
    final Uri? site = _siteUri;
    if (site != null) unawaited(syncWebVideoLoginToBrowser(site));
    _idleScheduler?.dispose();
    // 交接页没开跑就离开：停掉预起的静音采集（native 随即还原会话音量）。
    unawaited(_preStartedAudio?.source.stop());
    _preStartedAudio = null;
    if (_ownsGlobalLookupOnHidden &&
        identical(
          GlobalLookupController.instance.onHidden,
          _onGlobalLookupHidden,
        )) {
      GlobalLookupController.instance.onHidden = _prevGlobalLookupOnHidden;
    }
    unawaited(_watchTracker?.stop());
    // 后台制卡页的播放全是机器驱动（站点自动播放 + 逐句重放），不是用户的续播点。
    if (!widget.closeAfterMining) unawaited(_flushPosition());
    final OverlayEntry? entry = _popupOverlayEntry;
    if (entry != null) {
      removeAndDisposeOwnedOverlayEntry(entry);
      _popupOverlayEntry = null;
    }
    if (_fullscreen && Platform.isWindows) {
      // 全屏中退页：runner 拥有的窗口全屏态不随路由消失，这里必须亲手退出，
      // 否则回到书架的是一扇没有标题栏、盖着任务栏的巨窗。
      unawaited(WindowCaptionChannel.setFullscreen(false));
      FushiDesktopTitleBar.setContentFullscreen(owner: this, enabled: false);
    }
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    _popup.dispose();
    _searchRequests.dispose();
    _m3eChromeVisible.dispose();
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
    // 注入脚本 / 环境 / cookie 与原生播放器页的网页档同一套实现（web_video_session.dart）。
    final UnmodifiableListView<UserScript> scripts =
        await loadWebVideoUserScripts(
          softwareDrm: _softwareDrm,
          hideNativeSubtitles: _hideNativeSubtitles,
          domOverlay: _windowed,
          keyBridgeScript: webVideoKeyBridgeScript(_appModel.shortcutRegistry),
        );
    _env = _windowed
        ? await WebVideoFushiPage.windowedEnvironment()
        : await WebVideoFushiPage.capturableEnvironment();
    if (!mounted) return;
    _siteUri = uri;
    // 两档都抄：内置档是制卡队列重放的宿主，只抄窗口档时它永远拿不到浏览器 / 播放页里的
    // 登录态，点「制作队列中的卡片」就落到站点登录页（BUG-3801）。
    await _copyLoginCookiesFromBuiltin(uri);
    if (!mounted) return;
    unawaited(_refreshFavoriteCache());
    unawaited(_refreshMinePending());
    setState(() {
      _row = row;
      _userScripts = scripts;
    });
    if (Platform.isWindows) _startIdleScheduler();
    _registerRemote();
    // 被制卡交接换回来的这一页：画面就绪后把重放前的集 / 轨 / 位置还原。
    if (widget.returnHostingAfterMining == null) {
      _beginRestore(widget.mineReturnState);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _seedWarmPopup());
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
    final String? next = _subtitlesOff
        ? null
        : chooseWebVideoTrackKey(
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
    final WebVideoPlaybackState? state = parseWebVideoStatePayload(
      msg,
      webViewUrl: _webViewUrl,
    );
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
    final int? previewEnd = _remotePreviewEndMs;
    if (pos != null && previewEnd != null && pos >= previewEnd) {
      // 手机试听的那段放到终点：停下（与原生播放器 playRangeMs 到点暂停同义）。试听自己的
      // 收尾不是「有人动过播放」，不走计数的 [_pause]（与扩展 remotePlayRange 同）。
      _remotePreviewEndMs = null;
      unawaited(_js('window.__fushiWebVideo.pause()'));
    }
    if (pos != null) {
      _controller.applyExternalPlaybackState(
        positionMs: pos,
        playing: state.isPlaying,
        durationMs: state.durationMs,
      );
      // 队列重放期间的 seek/播放是机器驱动，不算观看进度、不计观看时长；后台制卡页
      // 整页都是机器驱动（开跑前站点自动播放、跑完到关页之间停在最后一句），同理。
      if (!_mineRunning && !widget.closeAfterMining) {
        _maybePersistPosition(pos);
        _syncWatchTracker(state.isPlaying);
      }
    }
    if (fullscreenChanged) {
      _fullscreen = state.fullscreen;
      if (mounted) setState(() {});
    }
    if (!_duckResidueChecked &&
        state.isPlaying &&
        !_mineRunning &&
        !_isMiningHost &&
        !_windowed &&
        Platform.isWindows) {
      // 用户自己开播时内置档会话若还停在 -100 dB（上次静音重放中途进程被杀），就地还原。
      _duckResidueChecked = true;
      unawaited(
        LoopbackGalAudioSource.restoreDuckedSessions(
          WebVideoFushiPage.capturableUserDataFolder(),
        ),
      );
    }
    _applyPendingRestore(state);
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

  // 播放控制意图都记一笔 [_remoteControlRevision]（手机遥控据此判断查词期间电脑上有没有
  // 人动过播放，语义同 [VideoPlayerController.remoteControlRevision]）。
  Future<void> _seekMs(int ms) {
    _remoteControlRevision++;
    return _js('window.__fushiWebVideo.seek($ms)');
  }

  Future<void> _play() {
    _remoteControlRevision++;
    return _js('window.__fushiWebVideo.play()');
  }

  Future<void> _pause() {
    _remoteControlRevision++;
    return _js('window.__fushiWebVideo.pause()');
  }

  Future<void> _togglePlay() {
    _remoteControlRevision++;
    return _js('window.__fushiWebVideo.toggle()');
  }

  Future<void> _setRate(double rate) {
    _remoteControlRevision++;
    return _js('window.__fushiWebVideo.setRate($rate)');
  }

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
          onWriteError: (Object e, StackTrace st) => ErrorLogService.instance
              .log('StudyClock.write(web-video)', e, st),
        ),
        loadCoverage: () =>
            db.getPref(videoWatchCoveragePrefKey(widget.bookUid)),
        saveCoverage: (String json) =>
            db.setPref(videoWatchCoveragePrefKey(widget.bookUid), json),
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
    if (n == 0 &&
        widget.idleAutoMining &&
        !_autoRunTriggered &&
        !_mineRunning) {
      // 空闲自动制卡页打开时队列已被别处跑空：没东西可做，直接收尾（同 [_runMineQueue]
      // 读到空队列），不留一页无人值守的网页视频。
      _autoRunTriggered = true;
      _finishMining(auto: true, status: null);
      return;
    }
    _maybeAutoRunMineQueue();
  }

  void _maybeAutoRunMineQueue() {
    if (!widget.autoRunMineQueue || _autoRunTriggered || _mineRunning) return;
    if (_minePending == 0 || !(_state?.hasVideo ?? false)) return;
    _autoRunTriggered = true;
    unawaited(_runMineQueue(auto: widget.idleAutoMining));
  }

  // ── 空闲自动制卡（web_mine_idle.dart）──────────────────────────────────

  void _startIdleScheduler() {
    final WebMineIdleScheduler scheduler = WebMineIdleScheduler(
      canStart: _canStartIdleMining,
      onIdle: _onIdleForMining,
      onUserActive: _onUserActiveDuringMining,
    );
    _idleScheduler = scheduler;
    scheduler.start();
    // 空闲交接打开的本页：这一轮从打开起就算自动制卡，交接途中来了输入也要让位。
    if (widget.idleAutoMining) scheduler.adoptRun();
  }

  /// 用户已暂停（本页没在播）、队列非空、画面就绪；交接页自己的那一轮由
  /// [_maybeAutoRunMineQueue] 起，不归这里。
  bool _canStartIdleMining() =>
      mounted &&
      widget.returnHostingAfterMining == null &&
      !widget.closeAfterMining &&
      !_mineRunning &&
      !WebMineIdleScheduler.silentCaptureUnavailable &&
      !_autoGaveUp &&
      _minePending > 0 &&
      _row != null &&
      (_state?.hasVideo ?? false) &&
      !(_state?.isPlaying ?? false);

  void _onIdleForMining() {
    if (_windowed) {
      // 窗口宿主档的帧不可截：换到内置档静音重放，跑完换回来。
      unawaited(
        _reopen(
          hosting: WebVideoHosting.builtin,
          autoRunMineQueue: true,
          returnHostingAfterMining: WebVideoHosting.windowed,
          idleAutoMining: true,
          mineReturnState: _currentReturnState(),
        ),
      );
      return;
    }
    unawaited(_runMineQueue(auto: true));
  }

  /// 用户回来了：在跑就录完当前这句即停；交接页还没开跑就直接换回原档。
  void _onUserActiveDuringMining() {
    if (_mineRunning) {
      if (_mineAuto) _mineStopRequested = true;
      return;
    }
    _autoYieldRequested = true;
    if (widget.idleAutoMining && !_autoRunTriggered) {
      _autoRunTriggered = true;
      _finishMining(auto: true, status: null);
    }
  }

  /// 一轮重放结束（手动 / 自动都走这里）：交接页换回原档并带回重放前的状态（胶囊会随页消失，
  /// 改发 Toast）；原页留结果胶囊。[status] null = 没东西可做（队列已空），不打扰用户。
  void _finishMining({required bool auto, required WebMineAutoStatus? status}) {
    if (auto) _idleScheduler?.runFinished();
    if (widget.closeAfterMining) {
      _closeAfterMining(auto: auto, status: status);
      return;
    }
    final WebVideoHosting? back = widget.returnHostingAfterMining;
    if (back == null) {
      if (mounted && status != null) setState(() => _autoStatus = status);
      return;
    }
    switch (status) {
      case WebMineAutoFinished(:final int ok, :final int failed):
        FushiToast.show(
          msg: auto
              ? t.web_video_mine_auto_finished(ok: ok, failed: failed)
              : t.web_video_mine_queue_finished(ok: ok, failed: failed),
        );
      case WebMineAutoUnavailable():
        FushiToast.show(msg: t.web_video_mine_auto_unavailable);
      case WebMineAutoRunning() || null:
        break;
    }
    unawaited(
      _reopen(
        hosting: back,
        mineReturnState: widget.mineReturnState ?? _replayOrigin,
      ),
    );
  }

  /// 后台空闲自动制卡打开的页：跑出结果才发 Toast（用户可能不在场，回来时看得到），
  /// 然后关页交还给 [WebMineBackgroundRunner]。只关一次。
  void _closeAfterMining({
    required bool auto,
    required WebMineAutoStatus? status,
  }) {
    if (_closedAfterMining) return;
    _closedAfterMining = true;
    if (status case WebMineAutoFinished(
      :final int ok,
      :final int failed,
    ) when ok + failed > 0) {
      FushiToast.show(
        msg: auto
            ? t.web_video_mine_auto_finished(ok: ok, failed: failed)
            : t.web_video_mine_queue_finished(ok: ok, failed: failed),
      );
    }
    if (!mounted) return;
    // 关的是本页这条路由，不是导航栈顶：用户不在场时栈顶可能另有东西（maybePop 会弹错，
    // 本页留着、后台调度一直以为在跑）。
    final ModalRoute<Object?>? route = ModalRoute.of(context);
    if (route == null) return;
    final NavigatorState navigator = Navigator.of(context);
    if (route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
  }

  /// 当前播放状态的快照（站点还没报状态时 null）。
  WebMineReturnState? _currentReturnState() {
    final WebVideoPlaybackState? state = _state;
    return state == null ? null : WebMineReturnState.of(state);
  }

  /// 站点字幕轨：空串 = 关掉（glue 选 none 轨）。
  Future<void> _selectSiteTextTrack(String id) =>
      _js('window.__fushiWebVideo.selectNetflixTrack(${jsonEncode(id)})');

  Future<void> _selectSiteAudioTrack(String id) =>
      _js('window.__fushiWebVideo.selectNetflixAudioTrack(${jsonEncode(id)})');

  /// 每句重放前把站点调成「录音用」的样子：字幕轨关掉（截帧不带字幕——CSS 藏字幕层之外再兜
  /// 一道，站点换了字幕层类名也不漏），音轨对齐用户重放前在听的那条（整页导航 / 交接后站点会
  /// 按账号默认重选）。
  Future<void> _prepareSiteForReplay() async {
    await _setNativeSubtitlesHidden(true);
    final WebVideoPlaybackState? state = _state;
    if (state == null) return;
    if (state.siteTrackCurrent.isNotEmpty) await _selectSiteTextTrack('');
    final String audio = _replayOrigin?.siteAudioTrack ?? '';
    if (audio.isEmpty ||
        audio == state.siteAudioTrackCurrent ||
        !state.siteAudioTracks.any((WebVideoSiteTrack t) => t.id == audio)) {
      return;
    }
    await _selectSiteAudioTrack(audio);
    // 切音轨要重新缓冲：等站点报回新音轨再开录（最多 3 秒，超时照录，warning 里看得到）。
    final DateTime until = DateTime.now().add(const Duration(seconds: 3));
    while (mounted && DateTime.now().isBefore(until)) {
      if (_state?.siteAudioTrackCurrent == audio) return;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  /// 原页一轮结束：把重放前的集 / 轨 / 位置原样还回去（[_applyPendingRestore] 逐拍对齐）。
  void _beginRestore(WebMineReturnState? want) {
    if (want == null) return;
    _pendingRestore = want;
    _pendingRestoreDeadline = DateTime.now().add(const Duration(seconds: 30));
    _lastRestoreActionAt = null;
    _restoreNavigated = false;
    final WebVideoPlaybackState? state = _state;
    if (state != null) _applyPendingRestore(state);
  }

  /// 每拍站点状态到来时对齐一次（动作之间至少隔 1 秒，等站点把上一个动作报回来）。
  void _applyPendingRestore(WebVideoPlaybackState state) {
    final WebMineReturnState? want = _pendingRestore;
    if (want == null || _mineRunning) return;
    final DateTime now = DateTime.now();
    if (now.isAfter(_pendingRestoreDeadline ?? now)) {
      _pendingRestore = null;
      return;
    }
    if (!state.hasVideo) return;
    final WebMineRestorePlan plan = planWebMineRestore(want, state);
    if (webMineRestoreDone(plan)) {
      _pendingRestore = null;
      return;
    }
    final DateTime? last = _lastRestoreActionAt;
    if (last != null && now.difference(last) < const Duration(seconds: 1)) {
      return;
    }
    _lastRestoreActionAt = now;
    final String? href = plan.navigateHref;
    if (href != null) {
      if (_restoreNavigated) return;
      _restoreNavigated = true;
      unawaited(
        _web?.loadUrl(urlRequest: URLRequest(url: WebUri(href))) ??
            Future<void>.value(),
      );
      return;
    }
    final String? text = plan.selectTextTrack;
    if (text != null) unawaited(_selectSiteTextTrack(text));
    final String? audio = plan.selectAudioTrack;
    if (audio != null) unawaited(_selectSiteAudioTrack(audio));
    final int? seek = plan.seekMs;
    if (seek != null) unawaited(_seekMs(seek));
  }

  /// 制卡交接页：WebView 控制器一建好（浏览器进程已在、站点还没播起来）就开静音采集，
  /// 之后 Chromium 新建的音频会话一出现就被压低（站点自动播放不外放）。
  Future<void> _preStartSilentAudio() async {
    final LoopbackGalAudioSource silent = LoopbackGalAudioSource(
      userDataFolder: WebVideoFushiPage.capturableUserDataFolder(),
      silent: true,
    );
    final PcmFormat? format = await silent.start();
    if (!mounted) {
      await silent.stop();
      return;
    }
    if (format == null) {
      ErrorLogService.instance.log(
        'web_video.mineQueue',
        'silent pre-start failed: ${silent.lastStartError}',
      );
      _noteSilentStartFailure(silent.lastStartError);
      // 手动交接照跑（开跑时退回整机混音）；只有空闲自动这一轮整轮放弃、换回原档。
      if (widget.idleAutoMining && !_autoRunTriggered && !_mineRunning) {
        _autoRunTriggered = true;
        _finishMining(auto: true, status: const WebMineAutoUnavailable());
      }
      return;
    }
    _preStartedAudio = (source: silent, format: format);
  }

  /// 静音采集起不来：系统不支持 → 进程级不再自动制卡；其余（找不到进程 / 忙）只让本页放弃。
  void _noteSilentStartFailure(String? code) {
    if (code == 'unsupported') {
      WebMineIdleScheduler.silentCaptureUnavailable = true;
    } else {
      _autoGaveUp = true;
    }
  }

  /// 重放的音频来源。优先静音进程树（只录内置档 WebView2、不出扬声器）；起不来时
  /// 手动跑退回整机混音（会外放、混进别的声音，与改动前同一行为），自动跑回 null（放弃，
  /// 绝不在用户不在场时外放）。非 Windows 一律 null（只截帧）。
  Future<({LoopbackGalAudioSource source, PcmFormat? format})?>
  _startReplayAudio({required bool auto}) async {
    await _preStartFuture;
    final ({LoopbackGalAudioSource source, PcmFormat format})? pre =
        _preStartedAudio;
    if (pre != null) {
      _preStartedAudio = null;
      return (source: pre.source, format: pre.format);
    }
    final LoopbackGalAudioSource silent = LoopbackGalAudioSource(
      userDataFolder: WebVideoFushiPage.capturableUserDataFolder(),
      silent: true,
    );
    final PcmFormat? silentFormat = Platform.isWindows
        ? await silent.start()
        : null;
    if (silentFormat != null) return (source: silent, format: silentFormat);
    if (Platform.isWindows) {
      ErrorLogService.instance.log(
        'web_video.mineQueue',
        'silent capture unavailable: ${silent.lastStartError}',
      );
    }
    _silentStartError = silent.lastStartError;
    if (auto) return null;
    final LoopbackGalAudioSource mix = LoopbackGalAudioSource();
    return (source: mix, format: await mix.start());
  }

  /// 队列行属于别的视频（换集后入队的）：先导航过去等画面就绪。
  Future<bool> _navigateForMining(WebMineQueueRow row) async {
    final InAppWebViewController? web = _web;
    if (web == null) return false;
    await web.loadUrl(urlRequest: URLRequest(url: WebUri(row.href)));
    final DateTime until = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(until)) {
      if (!mounted || _mineStopRequested) return false;
      if (_videoKey == row.videoKey && (_state?.hasVideo ?? false)) {
        // 画面就绪可能早于 onLoadStop；开录前再挂一次（页面侧按 style id 幂等）。
        await _setPlayerChromeHidden(true);
        await _prepareSiteForReplay();
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return false;
  }

  /// 逐句重放落卡。[auto] = 空闲自动制卡：只用静音录音（起不来就整轮放弃）、用户一有
  /// 输入就录完当前这句即停、结果留在状态胶囊里。
  Future<void> _runMineQueue({bool auto = false}) async {
    if (_mineRunning || _row == null) {
      if (auto) _idleScheduler?.runFinished();
      return;
    }
    // 交接页的输入可能早于这一轮（adoptRun 已记下），只有原页的新一轮才清零。
    if (auto && !widget.idleAutoMining) {
      _autoYieldRequested = false;
    }
    final List<WebMineQueueRow> rows = await _mineQueue.pending(widget.bookUid);
    if (!mounted) return;
    if (rows.isEmpty) {
      if (!auto) FushiToast.show(msg: t.web_video_mine_queue_empty);
      _finishMining(auto: auto, status: null);
      return;
    }
    // 先起音频再接管页面：静音模式在握手返回前就把会话压低了，之后的 seek / 播放不出声。
    final ({LoopbackGalAudioSource source, PcmFormat? format})? audio =
        await _startReplayAudio(auto: auto);
    if (!mounted) {
      await audio?.source.stop();
      return;
    }
    if (audio == null) {
      _noteSilentStartFailure(_silentStartError);
      _finishMining(auto: true, status: const WebMineAutoUnavailable());
      return;
    }
    final LoopbackGalAudioSource loopback = audio.source;
    final PcmFormat? format = audio.format;
    int ok = 0;
    int failed = 0;
    _replayOrigin = widget.mineReturnState ?? _currentReturnState();
    _pendingRestore = null;
    // try 紧跟在采集起好之后：之后任何一步抛出，finally 都会停采集（还原会话音量）、
    // 复位运行态。
    try {
      setState(() {
        _mineRunning = true;
        _mineAuto = auto;
        _mineStopRequested = auto && _autoYieldRequested;
        _mineProgress = (done: 0, total: rows.length);
        _autoStatus = WebMineAutoRunning(
          done: 0,
          total: rows.length,
          auto: auto,
        );
      });
      unawaited(_watchTracker?.stop());
      if (_popup.hasVisiblePopup) _popNestedPopupAt(0);
      // 封面不带站点控制栏（Dart 驱动的 seek/pause 会让控件浮出来）；字幕轨关掉、音轨对齐。
      await _setPlayerChromeHidden(true);
      await _prepareSiteForReplay();
      final String tempDir = (await getTemporaryDirectory()).path;
      final MiningMediaCompression compression = MiningMediaCompression.resolve(
        imageTier: _appModel.miningImageQuality,
        audioTier: _appModel.miningAudioQuality,
        format: _appModel.videoMiningAnimatedFormat,
      );
      // 图片模式按目标模板生效（模板不原样渲染图片字段时片段改动图），录之前定下：
      // 动图 / 片段模式要在重放期间连续采帧，静图模式只截中点一张。
      final VideoMiningImageMode imageMode = await resolveTargetMiningImageMode(
        _appModel.videoMiningImageMode,
        repo: ref.read(ankiRepositoryProvider),
      );
      final WebMineReplayRunner runner = WebMineReplayRunner(
        host: _WebMineHost(this),
        captureFrames: !imageMode.isStill,
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
            imageMode,
          );
          if (error == null) {
            ok++;
          } else {
            failed++;
          }
        }
        if (mounted) {
          setState(() {
            _mineProgress = (done: ok + failed, total: rows.length);
            _autoStatus = WebMineAutoRunning(
              done: ok + failed,
              total: rows.length,
              auto: auto,
            );
          });
        }
      }
    } finally {
      // 先停采集（native 随即把压低的会话音量还原），再还原站点外观与播放状态。
      await loopback.stop();
      await _setPlayerChromeHidden(false);
      await _setNativeSubtitlesHidden(_hideNativeSubtitles);
      if (mounted) {
        setState(() {
          _mineRunning = false;
          _mineAuto = false;
          _mineProgress = null;
        });
        // 原页：集 / 字幕轨 / 音轨 / 位置原样还回去；交接页把它带回原档（[_finishMining]）。
        if (widget.returnHostingAfterMining == null &&
            !widget.closeAfterMining) {
          _beginRestore(_replayOrigin);
        }
        unawaited(_refreshMinePending());
      }
    }
    _finishMining(
      auto: auto,
      status: WebMineAutoFinished(
        ok: ok,
        failed: failed,
        remaining: rows.length - ok - failed,
        auto: auto,
      ),
    );
  }

  /// 抓到的媒体 + 行里冻结的字段 → 沉浸制卡引擎。返回 null = 成功；否则失败原因
  /// （已写进队列行 error 列）。
  Future<String?> _mineQueuedRow(
    WebMineQueueRow row,
    WebMineReplayCapture cap,
    MiningMediaCompression compression,
    String tempDir,
    VideoMiningImageMode imageMode,
  ) async {
    final String? title = _row?.title;
    final _WebMineCardMedia media = await _resolveCardMedia(
      cap,
      compression,
      tempDir,
      imageMode,
    );
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
          imageMode: media.imageMode,
          providedCoverBytes: media.cover,
          providedCoverName: media.coverName,
          providedAudioBytes: media.audio,
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
    final List<String> warnings = <String>[...cap.warnings, ...media.warnings];
    await _mineQueue.markDone(
      row.id,
      noteId: outcome.noteId,
      warning: warnings.isEmpty ? null : warnings.join(','),
    );
    return null;
  }

  /// 重放抓到的媒体 → 卡上的图片 / 音频。动图 / 片段模式把帧序列与句子音频合成中间
  /// 片段，再走与浏览器扩展录制片段同一条 [transcodeClipToCapture] 出音画同步片段或
  /// 动图；任何一步失败都退回中点那张封面（记 warning，不让整张卡失败）。
  Future<_WebMineCardMedia> _resolveCardMedia(
    WebMineReplayCapture cap,
    MiningMediaCompression compression,
    String tempDir,
    VideoMiningImageMode imageMode,
  ) async {
    final _WebMineCardMedia still = (
      imageMode: VideoMiningImageMode.currentFrame,
      cover: cap.cover,
      coverName: 'web_video_cover.png',
      audio: cap.audio,
      warnings: const <String>[],
    );
    if (imageMode.isStill || cap.frames.length < 2) return still;
    // 片段 = 画面 + 句子声音一个文件；没录到音就没有片段可言，改出动图（与引擎
    // 「不要音频 + 视频片段」同一降级目标）。
    final VideoMiningImageMode mode = imageMode.isVideoClip && cap.audio == null
        ? VideoMiningImageMode.gif
        : imageMode;
    final Uint8List? clip = await composeWebMineClip(
      capture: cap,
      audioExtension: immersionMiningAudioExtension(),
      tempDir: tempDir,
    );
    if (clip == null) {
      return (
        imageMode: still.imageMode,
        cover: still.cover,
        coverName: still.coverName,
        audio: still.audio,
        warnings: const <String>['clip_compose_failed'],
      );
    }
    final ImmersionCaptureResult res = await transcodeClipToCapture(
      clip,
      durationMs: cap.clipDurationMs,
      compression: compression,
      tempDir: tempDir,
      imageMode: mode,
      format: _appModel.videoMiningAnimatedFormat,
      stillFormat: _appModel.videoMiningStillFormat,
      clipFormat: _appModel.videoMiningClipFormat,
    );
    final Uint8List? cover = res.gifBytes;
    if (!res.ok || cover == null) {
      ErrorLogService.instance.log(
        'web_video.mineClip',
        'transcode failed: ${res.error}',
      );
      return (
        imageMode: still.imageMode,
        cover: still.cover,
        coverName: still.coverName,
        audio: still.audio,
        warnings: const <String>['clip_transcode_failed'],
      );
    }
    if (res.coverIsVideo) {
      // 片段自带句子音频：引擎把同一个文件既当封面又当音频。
      return (
        imageMode: VideoMiningImageMode.videoClip,
        cover: cover,
        coverName: 'web_video_clip.${res.clipFormat.fileExtension}',
        audio: null,
        warnings: const <String>[],
      );
    }
    return (
      imageMode: VideoMiningImageMode.gif,
      cover: cover,
      coverName: 'web_video_clip.${res.animatedFormat.fileExtension}',
      // 动图模式用回取的原始编码音频，不吃转码那一遍的二次压缩。
      audio: cap.audio ?? res.audioBytes,
      warnings: const <String>[],
    );
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

  /// 快捷键「复制当前台词」（_Eb0txdN4H，与视频页同口径）：正在显示的那句，句间
  /// 空隙里回落到最近查词 / 当前句。
  void _copyCurrentSubtitle() {
    final String? text = videoCurrentLineCopyText(
      activeCues: _controller.activeCues,
      fallback: _controller.currentCue ?? _lastLookupCue,
    );
    if (text == null) return;
    _appModel.copyToClipboard(text);
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
      return r.toJson();
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

  /// 两档各用独立环境（浏览器参数不同 → 独立 user data folder → 独立 cookie 罐）：把其它视频
  /// 环境与 app 内浏览器已登录的站点 cookie 复制到本页环境（[kWebVideoLoginCookieSources]，
  /// 本页自己那份跳过），用户不用登录两次。尽力而为，失败只记日志（站点会要求登录）。
  Future<void> _copyLoginCookiesFromBuiltin(Uri uri) async {
    final WebViewEnvironment? to = _env;
    if (to == null) return;
    await copyWebVideoLoginCookies(uri: uri, to: to);
  }

  /// 切宿主档 / 交接制卡：同一本书原地重开。
  ///
  /// 切到 4K 窗口档且引擎能做底层合成时，交给原生播放器页（[VideoFushiPage] 的网页档：
  /// 站点画面垫在原生控件下面，控件与本地视频完全同一套）；否则（内置档 / 原版引擎上的
  /// 窗口档）原地重开本页。
  Future<void> _reopen({
    required WebVideoHosting hosting,
    bool autoRunMineQueue = false,
    WebVideoHosting? returnHostingAfterMining,
    bool idleAutoMining = false,
    WebMineReturnState? mineReturnState,
  }) async {
    if (!mounted) return;
    final bool nativePage =
        hosting == WebVideoHosting.windowed &&
        !autoRunMineQueue &&
        await underlayCompositionSupported();
    if (!context.mounted) return;
    await Navigator.of(context).pushReplacement(
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => nativePage
            ? VideoFushiPage.neutralized(
                bookUid: widget.bookUid,
                repo: widget.repo,
                webReturnState: mineReturnState,
              )
            : WebVideoFushiPage.neutralized(
                bookUid: widget.bookUid,
                repo: widget.repo,
                hosting: hosting,
                autoRunMineQueue: autoRunMineQueue,
                returnHostingAfterMining: returnHostingAfterMining,
                idleAutoMining: idleAutoMining,
                mineReturnState: mineReturnState,
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
      _handleListLookup(listHit.cue, listHit.graphemeIndex, listHit.anchorRect);
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
    // BUG-2953：浮层自带导航层，弹窗里唤出的菜单画在浮层之上（见 LookupOverlayNavigator）。
    return LookupOverlayNavigator(
      child: FushiAppUiScaleNeutralizer(
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
                        // BUG-2770：触摸半边未设置时所有平台默认开。
                        touchSwipeEnabled:
                            ReaderFushiSource.instance.enableTouchSwipeToClose,
                        sensitivity:
                            ReaderFushiSource.instance.dismissSwipeSensitivity,
                        // 弹窗可见时 barrier 吃掉全部指针，页面根收不到——「浮窗矩形
                        // 之外」按鼠标非主键这半边只能在这里接（见钩子文档）。
                        onNonPrimaryButtonDown:
                            onDismissBarrierNonPrimaryButton,
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
                      onPush:
                          (
                            String text,
                            Rect rect,
                            List<FushiRubySpan> rubySpans,
                          ) => pushNestedPopup(
                            query: text,
                            selectionRect: rect,
                            controller: _popup,
                            autoRead: true,
                            rubySpans: rubySpans,
                          ),
                      onPop: _popNestedPopupAt,
                    ),
                  ...buildParkedRealmLayers(screen: screen, controller: _popup),
                ],
              );
            },
          ),
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
      // 网页视频页没有 media_kit 帧可取（画面在 WebView 里），两条截图动作同样落空。
      screenshotSubtitled: noop,
      ocrFrame: noop,
      toggleFullscreen: () => unawaited(_toggleFullscreen()),
      // 内置网页播放器没有小窗：画面是站点自己的播放器在 WebView2 里渲染的，
      // 把主窗缩成小窗只会得到一个塞不下网页布局的窗口，系统画中画更拿不到这条
      // 纹理。诚实 no-op（与本页其它拿不到的能力同待遇，见 toggleShaderCompare）。
      toggleMiniWindow: noop,
      // 没有小窗自然也没有小窗 chrome。
      toggleMiniChrome: noop,
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
      // 重播类动作一律起播（Dbd86l4kA-，与本地视频页同口径）；只跳不播的是
      // previousSubtitle / nextSubtitle。
      replayCurrentSubtitle: () {
        final AudioCue? cue = _controller.currentCue ?? _lastLookupCue;
        if (cue != null) unawaited(_seekMs(cue.startMs).then((_) => _play()));
      },
      replayPreviousSubtitle: () =>
          unawaited(_seekToCueOffset(-1).then((_) => _play())),
      // 复制当前台词（_Eb0txdN4H）；网页视频页没有副字幕轨（副字幕遮蔽同为 noop）。
      copyCurrentSubtitle: _copyCurrentSubtitle,
      copyCurrentSecondarySubtitle: noop,
      // 循环当前句依赖本地播放器的位置 tick 回绕，网页视频页（WebView 播放）不支持。
      toggleLoopCurrentSubtitle: noop,
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

  /// 本页全屏的唯一执行体：F 键 / 全屏按钮 / F11（[buildVideoPlayerShortcutsFromRegistry]
  /// 把 `globalToggleFullscreen` 映射到这里，BUG-2462）三者同路。
  ///
  /// Windows 走 runner 自有的保边框全屏 [WindowCaptionChannel.setFullscreen]
  /// （BUG-1933）：media_kit 的 `defaultEnterNativeFullscreen` 与 window_manager 同技法
  /// ——剥 `WS_CAPTION|WS_THICKFRAME` 迫使 DWM 重建窗口 visual，Flutter 子窗图层缺席
  /// 一帧、露出表面色（浅色主题 = 白帧）。BUG-1933 当初只改了 app 根 F11 与视频页
  /// 两个入口，本页被漏掉，F 键一直闪白；F11 改由本页接管后（BUG-2462）连 F11 也
  /// 落回了那条路。与 `fullscreen.part.dart` 同序：进入前先藏 app frame，退出时
  /// 等 runner 同步还原窗口矩形后再亮出 frame（早亮会在退出过程闪一下标题栏）。
  /// macOS / Linux 保留 media_kit 默认回调。
  Future<void> _toggleFullscreen() async {
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) return;
    final bool enter = !_fullscreen;
    setState(() => _fullscreen = enter);
    if (Platform.isWindows) {
      if (enter) {
        FushiDesktopTitleBar.setContentFullscreen(owner: this, enabled: true);
        await WindowCaptionChannel.setFullscreen(true);
      } else {
        await WindowCaptionChannel.setFullscreen(false);
        FushiDesktopTitleBar.setContentFullscreen(owner: this, enabled: false);
      }
    } else {
      try {
        if (enter) {
          await defaultEnterNativeFullscreen();
        } else {
          await defaultExitNativeFullscreen();
        }
      } catch (e) {
        ErrorLogService.instance.log('web_video', 'fullscreen: $e');
      }
    }
    _focusOwnership.reclaimAfterFrame(FocusReclaimCause.chromeToggled);
  }

  void _selectTrack(String? key) {
    _subtitlesOff = key == null;
    _activeTrackKey = key;
    _reselectTrack();
  }

  // ── 手机遥控 ───────────────────────────────────────────────────────────
  //
  // 与原生播放器页同一个遥控宿主协议（[VideoRemotePlaybackBinding]）：播放动作变成页面 JS，
  // 句子列表 / 试听 / 制卡时间窗走共用件（video_remote_binding_support.dart）。制卡交接页
  // （跑队列的机器驱动重放）不登记——那边的播放不归手机管。

  /// 会话身份：书 + 站点视频（站内换片 = 新会话）。
  String _remoteIdentity() => '${widget.bookUid}|$_videoKey';

  void _registerRemote() {
    if (widget.autoRunMineQueue || widget.returnHostingAfterMining != null) {
      return;
    }
    final VideoRemotePlaybackBinding binding = VideoRemotePlaybackBinding(
      identity: _remoteIdentity,
      title: () {
        final VideoBookRow? row = _row;
        return row == null ? '' : _barTitle(row);
      },
      bookUid: () => widget.bookUid,
      sectionIndex: () => 0,
      cues: () => _remoteCueCache.read(
        primary: _controller.cues,
        primaryDelayMs: _controller.delayMs,
        key: _activeTrackKey ?? '',
      ),
      state: () => <String, Object?>{
        'positionMs': _state?.positionMs ?? 0,
        'durationMs': _state?.durationMs ?? 0,
        'playing': _state?.isPlaying ?? false,
        'speed': _state?.rate ?? 1.0,
        'controlRevision': _remoteControlRevision,
        'primaryTrack': _activeTrackKey,
        'secondaryTrack': null,
        'primaryDelayMs': _controller.delayMs,
        'secondaryDelayMs': 0,
        'volume': ((_state?.volume ?? 1.0) * 100).round(),
        'episodeIndex': 0,
        'episodeCount': 0,
        'caret': 'none',
      },
      command: _runRemoteCommand,
      mine: _mineRemoteCue,
      previewAudio: (VideoRemoteCue anchor, int startMs, int endMs) async {
        final ({int clipStartMs, int clipEndMs}) window = _remoteMiningWindow(
          anchor,
          startMs,
          endMs,
        );
        if (window.clipEndMs <= window.clipStartMs) return false;
        _requireRemoteControllable();
        _remotePreviewEndMs = window.clipEndMs;
        await _seekMs(window.clipStartMs);
        await _play();
        return true;
      },
      stopAudio: () async {
        _remotePreviewEndMs = null;
        await _pause();
      },
      openFavorite: _openRemoteFavorite,
      addListener: _controller.addListener,
      removeListener: _controller.removeListener,
      favoritesChanged: _refreshFavoriteCache,
      setVolume: (int volume) {
        _requireRemoteControllable();
        _remoteControlRevision++;
        return _js(
          'window.__fushiWebVideo.setVolume(${(volume / 100).clamp(0.0, 1.0)},'
          ' false)',
        );
      },
      subtitleTracks: () async => _remoteSubtitleOptions(),
      selectSubtitleTrack: _selectRemoteSubtitleOption,
      searchSubtitles: (String? query, int? episode) =>
          _remoteOnlineSubtitles.search(
            RemoteOnlineSubtitleContext(
              seriesQuery: _row?.title ?? '',
              seed: const SubtitleSearchSeed(),
            ),
            query: query,
            episode: episode,
          ),
      downloadSubtitle: _downloadRemoteSubtitle,
      close: () async {
        if (!mounted) throw const VideoRemoteException(409, 'no_video');
        if (!await Navigator.of(context).maybePop()) {
          throw const VideoRemoteException(409, 'host_busy');
        }
      },
    );
    final VideoRemotePlaybackBinding? previous = _remoteBinding;
    _remoteBinding = binding;
    _appModel.videoRemoteHost.register(binding);
    if (previous != null) _appModel.videoRemoteHost.unregister(previous);
  }

  void _unregisterRemote() {
    final VideoRemotePlaybackBinding? binding = _remoteBinding;
    if (binding != null) _appModel.videoRemoteHost.unregister(binding);
    _remoteBinding = null;
  }

  /// 制卡队列在重放时播放归机器驱动：手机的播放类动作一律回「电脑忙」。
  void _requireRemoteControllable() {
    if (!mounted) throw const VideoRemoteException(409, 'no_video');
    if (_mineRunning) throw const VideoRemoteException(409, 'host_busy');
  }

  Future<void> _runRemoteCommand(
    String action,
    Map<String, dynamic> body,
  ) async {
    _requireRemoteControllable();
    switch (action) {
      case 'play':
        await _play();
      case 'pause':
        await _pause();
      case 'seek':
      case 'seekCue':
        final int position = (body['positionMs'] as num).toInt();
        final int? duration = _state?.durationMs;
        _remotePreviewEndMs = null;
        await _seekMs(position.clamp(0, duration ?? position));
        if (action == 'seekCue') await _play();
      default:
        throw const VideoRemoteException(400, 'invalid_action');
    }
  }

  /// 试听 / 制卡共用的时间窗：加首尾留白后按调轴换到播放器轴。
  ({int clipStartMs, int clipEndMs}) _remoteMiningWindow(
    VideoRemoteCue anchor,
    int startMs,
    int endMs,
  ) {
    final ({int startMs, int endMs}) padded = videoRemotePaddedMiningRange(
      startMs: startMs,
      endMs: endMs,
      cues: _controller.cues,
      headPadMs: _appModel.miningAudioHeadPadMs,
      tailPadMs: _appModel.miningAudioTailPadMs,
    );
    return (
      clipStartMs: miningClipTimeMs(padded.startMs, anchor.delayMs),
      clipEndMs: miningClipTimeMs(padded.endMs, anchor.delayMs),
    );
  }

  /// 手机字幕轨列表：与顶栏字幕菜单同一份（当前站点视频采到的轨 + 手机下载的字幕）。
  List<VideoRemoteSubtitleOption> _remoteSubtitleOptions() =>
      <VideoRemoteSubtitleOption>[
        for (final WebVideoTrack track in _currentVideoTracks())
          VideoRemoteSubtitleOption(
            id: videoRemoteSubtitleOptionId(track.key),
            label: track.isLive ? t.web_video_track_live : track.lang,
            kind: track.key.contains('|download:') ? 'external' : 'embedded',
            selected: track.key == _activeTrackKey,
            selectable: true,
          ),
      ];

  Future<void> _selectRemoteSubtitleOption(String? id) async {
    if (!mounted) throw const VideoRemoteException(409, 'no_video');
    if (id == null) {
      _selectTrack(null);
      return;
    }
    for (final WebVideoTrack track in _currentVideoTracks()) {
      if (videoRemoteSubtitleOptionId(track.key) == id) {
        _selectTrack(track.key);
        return;
      }
    }
    throw const VideoRemoteException(404, 'subtitle_track_missing');
  }

  /// 手机在线下载的字幕：解析成 cue、作为当前站点视频的一条轨登记并选中（本页字幕都按
  /// 「站点视频 → 轨」管，[_reselectTrack] 按轨重灌 controller）。下载期间站内换了片就
  /// 回 409 `session_changed`，不把上一个视频的字幕挂到新视频上。
  Future<VideoRemoteSubtitleApply> _downloadRemoteSubtitle(String id) async {
    final String identity = _remoteIdentity();
    final String path = await _remoteOnlineSubtitles.download(id);
    final List<AudioCue> cues = await loadVideoRemoteSubtitleFile(
      path,
      widget.bookUid,
    );
    return () async {
      if (!mounted) throw const VideoRemoteException(409, 'no_video');
      if (_remoteIdentity() != identity) {
        throw const VideoRemoteException(409, 'session_changed');
      }
      if (cues.isEmpty) {
        throw const VideoRemoteException(409, 'subtitle_track_unavailable');
      }
      final String name = p.basename(path);
      final String key = '$_videoKey|download:$name';
      _tracks[key] = WebVideoTrack(
        key: key,
        videoKey: _videoKey,
        lang: name,
        cues: cues,
      );
      _selectTrack(key);
    };
  }

  /// 手机点开收藏：本书的收藏就地跳到那句并播放；别的书交给视频页打开（与原生播放器页
  /// 同一入口，它按书的片源自己分流到本地 / 远端 / 网页档）。
  Future<void> _openRemoteFavorite(FavoriteSentence favorite) async {
    final String? uid = favorite.bookKey;
    if (uid == null || uid.isEmpty) {
      throw const VideoRemoteException(404, 'favorite_source_unavailable');
    }
    if (uid == widget.bookUid) {
      _requireRemoteControllable();
      final VideoRemoteCue cue = matchVideoRemoteFavoriteCue(
        _remoteCueCache.read(
          primary: _controller.cues,
          primaryDelayMs: _controller.delayMs,
          key: _activeTrackKey ?? '',
        ),
        favorite,
      );
      await _seekMs(miningClipTimeMs(cue.startMs, cue.delayMs));
      await _play();
      return;
    }
    final VideoBookRow? row = await widget.repo.getByBookUid(uid);
    if (row == null || await isLocalVideoResourceMissing(row.videoPath)) {
      throw const VideoRemoteException(404, 'favorite_source_unavailable');
    }
    if (!context.mounted) throw const VideoRemoteException(409, 'no_video');
    _unregisterRemote();
    unawaited(
      Navigator.of(context).pushReplacement(
        adaptivePageRoute<void>(
          context: context,
          builder: (_) => VideoFushiPage.neutralized(
            bookUid: uid,
            repo: widget.repo,
            initialRemoteFavorite: favorite,
            initialEpisodeIndex: favorite.sectionIndex,
            initialSubtitleListVisible: false,
          ),
        ),
      ),
    );
  }

  /// 遥控制卡：与本页制卡同两条路。YouTube 按视频 id + 时间窗（与手机试听同一个窗）从真实
  /// 视频流裁音频与画面、当场出卡；其它站点冻结字段与字幕时间窗进本页制卡队列，之后在可
  /// 捕获档逐句重放落卡（手机收到「已收下」）。
  Future<Map<String, Object?>> _mineRemoteCue(
    VideoRemoteCue cue,
    Map<String, dynamic> request,
    VideoRemoteMineSelection selection,
  ) async {
    final VideoBookRow? row = _row;
    if (!mounted || row == null) {
      throw const VideoRemoteException(409, 'no_video');
    }
    final VideoRemoteMineRequest parsed = parseVideoRemoteMineRequest(request);
    final String sentence = videoRemoteMineSentence(selection, parsed.sentence);
    final String href = _state?.href.isNotEmpty == true
        ? _state!.href
        : row.videoPath;
    final String? youtubeId = youtubeVideoIdOrNull(href);
    if (youtubeId != null) {
      final ({int clipStartMs, int clipEndMs}) window = _remoteMiningWindow(
        cue,
        selection.startMs,
        selection.endMs,
      );
      final RemoteMineResult res = await _appModel
          .createRemoteMiningService()
          .mineImmersion(
            ImmersionMinePayload(
              fields: parsed.fields,
              sentence: sentence,
              cueSentence: selection.cueSentence,
              documentTitle: _barTitle(row),
              youtubeVideoId: youtubeId,
              clipStartMs: window.clipStartMs,
              clipEndMs: window.clipEndMs,
            ),
          );
      return <String, Object?>{
        'success': res.result == 'success',
        if (res.result == 'duplicate') 'duplicate': true,
        if (res.result != 'success' && res.result != 'duplicate')
          'error': 'mining_failed',
      };
    }
    await _mineQueue.enqueue(
      bookUid: widget.bookUid,
      videoKey: _videoKey,
      href: href,
      cueStartMs: selection.startMs,
      cueEndMs: selection.endMs,
      sentence: sentence,
      cueSentence: selection.cueSentence,
      fields: parsed.fields,
    );
    await _refreshMinePending();
    if (mounted) {
      FushiToast.show(msg: t.web_video_mine_queued(count: _minePending));
    }
    return <String, Object?>{
      ...const MinePopupResult.queued().toJson(),
      'success': true,
    };
  }

  // ── build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncPopupOverlay());
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool m3e = videoM3eChrome(context);
    // 失败 / 加载态的页底：M3E（非墨水屏）深色模式与播放页同一块黑底、日间模式是
    // 面板方案的浅色 surface（[videoM3ePanelBackdrop]），正文进面板主题；
    // Apple / 墨水屏保持主题页底（墨水屏不铺大面积黑）。
    final Color? stateBackground = videoM3ePanelNeutral(context)
        ? videoM3ePanelBackdrop(cs)
        : null;
    final String? fail = _failReason;
    if (fail != null) {
      return Scaffold(
        appBar: _buildChromeBar(cs: cs),
        backgroundColor: stateBackground,
        // 加载失败走统一空状态（M3E error 色块 / Apple ContentUnavailableView），
        // 不再是光秃秃一行居中文字。
        body: VideoM3ePanelTheme(
          child: FushiPlaceholderMessage(
            icon: FushiIcons.error,
            message: fail,
            tone: FushiPlaceholderTone.error,
          ),
        ),
      );
    }
    final VideoBookRow? row = _row;
    final UnmodifiableListView<UserScript>? scripts = _userScripts;
    if (row == null || scripts == null) {
      // BUG-2230：加载态也必须带 AppBar（= 返回键）。出口不是内容的一部分、不随内容
      // 存亡（漫画页 manga_fushi_page 早已是这个口径）：本页的正常退出入口在
      // [_buildAppBar]，而那只挂在下面的**就绪**分支上；WebView2 环境创建 / 资源加载
      // 慢或悬挂时，桌面端没有系统返回键，用户就被钉在这个转圈上。M3E 下这条「AppBar」
      // 是只有返回胶囊的顶栏（[_buildChromeBar]）。
      return Scaffold(
        appBar: _buildChromeBar(cs: cs),
        backgroundColor: stateBackground,
        body: const VideoM3ePanelTheme(child: FushiLoadingView()),
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
          // Apple：页面底是 surface、只有画面区垫黑——顶栏（FushiAppBar，恒透明）
          // 画在 Scaffold 底色上，整页黑底会让它变成黑条（标题按 onSurface 取色，
          // 浅色主题下黑字压黑底看不见）。M3E：顶栏是与原生播放器同一套深色浮动
          // 胶囊，整页黑底，胶囊浮在画面上方的黑带里。
          backgroundColor: m3e ? Colors.black : cs.surface,
          appBar: _fullscreen ? null : _buildChromeBar(row: row, cs: cs),
          body: Row(
            children: <Widget>[
              Expanded(
                child: ColoredBox(
                  color: Colors.black,
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
                              hoverLookupModifier: ReaderFushiSource
                                  .instance
                                  .hoverLookupModifier,
                              hitTester: _subtitleHitTester,
                              isCueFavorited: _isCueFavorited,
                              fontFamily: _appModel.subtitleFontFamily,
                            ),
                          ),
                        ),
                      // 空闲自动制卡状态（窗口宿主档不画：WebView2 自绘盖在 Flutter 叠层上，
                      // 那一档的自动制卡也是换到内置档跑的）。截帧走 WebView 自己的
                      // CapturePreview，不含 Flutter 叠层，胶囊不会进封面。
                      if (!_windowed)
                        PositionedDirectional(
                          top: 12,
                          start: 16,
                          end: 16,
                          child: Center(
                            child: WebMineAutoStatusChip(
                              status: _autoStatus,
                              onDismiss: () =>
                                  setState(() => _autoStatus = null),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (_listVisible) _listPanelEntrance(_buildListPanel(cs)),
            ],
          ),
        ),
      ),
    );
    return WindowFullscreenHost(child: page);
  }

  // ── 顶栏 chrome ───────────────────────────────────────────────────────

  /// M3E 顶栏图标钮直径（与原生播放器 `_m3eButtonExtent` 的 1x 档同值）。
  static const double _kM3eBarExtent = 40;

  /// M3E 顶栏黑带高度：48 高的胶囊（40 钮 + 上下各 4）+ 上下各 8 的呼吸。
  static const double _kM3eStripHeight = 64;

  /// 顶栏的唯一出口。Apple 设计系统沿用 [FushiAppBar]（与改动前相同）；其余（M3E，
  /// 含墨水屏）与原生播放器同一套浮动胶囊——「返回 + 标题」一枚、右侧按钮组一枚
  /// （[VideoM3eFloatingSurface] + [VideoM3eIconButton]）。
  ///
  /// [row] 为 null = 失败 / 加载态：只有返回（BUG-2230 的出口，不随内容存亡）。
  ///
  /// 胶囊排在画面**上方**的黑带里而不是压在画面上：窗口宿主档的 WebView2 自己绘制，
  /// Flutter 叠层画不到它上面（见 [_windowed]），浮在画面上的胶囊在那一档会被盖住。
  PreferredSizeWidget _buildChromeBar({
    VideoBookRow? row,
    required ColorScheme cs,
  }) {
    if (!videoM3eChrome(context)) {
      return row == null ? FushiAppBar() : _buildAppBar(row, cs);
    }
    return PreferredSize(
      preferredSize: const Size.fromHeight(_kM3eStripHeight),
      child: _buildM3eTopBar(row),
    );
  }

  /// 当前视频的可选字幕轨（有 cue 的才列）。
  List<WebVideoTrack> _currentVideoTracks() => <WebVideoTrack>[
    for (final WebVideoTrack t in _tracks.values)
      if (t.videoKey == _videoKey && t.cues.isNotEmpty) t,
  ];

  String _barTitle(VideoBookRow row) =>
      _state?.title.isNotEmpty == true ? _state!.title : row.title;

  List<PopupMenuEntry<WebVideoHosting>> _hostingMenuItems(
    BuildContext context,
  ) => <PopupMenuEntry<WebVideoHosting>>[
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
  ];

  /// 超分档只有内置档有（窗口档画面归硬件 DRM，碰不到帧）。low = mpv 内置缩放档，
  /// 网页帧没有 mpv 缩放器，这里不列。
  List<PopupMenuEntry<VideoShaderTier>> _shaderMenuItems(
    BuildContext context,
  ) => <PopupMenuEntry<VideoShaderTier>>[
    for (final VideoShaderTierSpec spec in shaderTiersFor())
      if (spec.tier != VideoShaderTier.low)
        CheckedPopupMenuItem<VideoShaderTier>(
          value: spec.tier,
          checked: spec.tier == _shaderTier,
          child: Text(_shaderTierLabel(spec.tier)),
        ),
  ];

  List<PopupMenuEntry<String>> _trackMenuItems(BuildContext context) {
    final List<WebVideoTrack> mine = _currentVideoTracks();
    return <PopupMenuEntry<String>>[
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
    ];
  }

  /// 制卡队列钮的字形：待制卡数徽标压在卡片图标上。
  Widget _minePendingGlyph() => FushiBadgeControl.count(
    count: _minePending,
    isLabelVisible: _minePending > 0,
    child: const FushiIcon(FushiIcons.ankiCard),
  );

  void _toggleNativeSubtitlesHidden() {
    setState(() => _hideNativeSubtitles = !_hideNativeSubtitles);
    unawaited(_setNativeSubtitlesHidden(_hideNativeSubtitles));
  }

  void _openBuiltinForMining() => unawaited(
    _reopen(
      hosting: WebVideoHosting.builtin,
      autoRunMineQueue: true,
      returnHostingAfterMining: WebVideoHosting.windowed,
      mineReturnState: _currentReturnState(),
    ),
  );

  /// M3E 顶栏：黑带里的两枚浮动胶囊，挂载时从上方弹入（[VideoM3eChromeSlide]，
  /// 与原生播放器顶栏同一根弹簧；墨水屏 / 减弱动态效果下直接到位）。
  Widget _buildM3eTopBar(VideoBookRow? row) {
    final FushiTypography type = context.fushiType;
    // 胶囊前景跟胶囊底走（随 app 日间 / 深色模式，墨水屏恒白）。
    final Color fg = videoM3eChromeForegroundOf(context);
    final ({int done, int total})? progress = row == null
        ? null
        : _mineProgress;
    final String title = row == null ? '' : _barTitle(row);
    final Widget back = FushiTooltip(
      message: t.back,
      child: VideoM3eIconButton(
        icon: const FushiIcon(FushiIcons.back),
        onPressed: () => unawaited(Navigator.of(context).maybePop()),
        extent: _kM3eBarExtent,
      ),
    );
    final bool hasText = title.isNotEmpty || progress != null;
    final Widget? titleBlock = !hasText
        ? null
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (title.isNotEmpty)
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: type.titleMediumEmphasized.copyWith(
                    color: fg,
                    height: 1.25,
                  ),
                ),
              if (progress != null)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    SizedBox(
                      width: 96,
                      child: FushiLinearProgressIndicator(
                        value: progress.total <= 0
                            ? null
                            : progress.done / progress.total,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        t.web_video_mine_queue_running(
                          done: progress.done,
                          total: progress.total,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: type.bodySmall.tabular.copyWith(
                          color: fg.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          );
    final Widget titlePill = VideoM3eFloatingSurface(
      enabled: true,
      padding: titleBlock == null
          ? const EdgeInsets.all(4)
          : const EdgeInsets.fromLTRB(4, 4, 16, 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          back,
          if (titleBlock != null) ...<Widget>[
            const SizedBox(width: 8),
            Flexible(child: titleBlock),
          ],
        ],
      ),
    );
    final List<FushiAdaptiveAction> actions = row == null
        ? const <FushiAdaptiveAction>[]
        : _webBarActions(m3e: true);
    return SafeArea(
      bottom: false,
      child: SizedBox(
        height: _kM3eStripHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: VideoM3eChromeSlide(
            enabled: true,
            visible: _m3eChromeVisible,
            hiddenOffset: const Offset(0, -16),
            // 动作默认全部平铺，窄窗放不下才收进「⋯」（用户 2026-10-06）：预算 =
            // 整行宽扣掉返回胶囊、标题保底与间距，再扣动作胶囊自己的内边距 8。
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints box) => Row(
                children: <Widget>[
                  Expanded(
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: titlePill,
                    ),
                  ),
                  if (actions.isNotEmpty) ...<Widget>[
                    const SizedBox(width: 8),
                    VideoM3eFloatingSurface(
                      enabled: true,
                      padding: const EdgeInsets.all(4),
                      child: FushiAdaptiveActionStrip(
                        key: const ValueKey<String>('web-video-top-actions'),
                        moreKey: const ValueKey<String>(
                          'web-video-top-actions-more',
                        ),
                        foldFromStart: true,
                        maxWidth:
                            fushiTopBarActionsBudget(
                              maxWidth: box.maxWidth,
                              leadingCount: 1,
                              hasTitle: true,
                            ) -
                            8,
                        actions: actions,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 顶栏动作（M3E 与 Apple 同一组、同一顺序）。列表**末尾优先级最高**
  /// （[FushiAdaptiveActionStrip.foldFromStart]）：窗口窄到放不下时先收进
  /// 「⋯」的是最左的宿主 / 超分档，全屏与字幕列表最后收。[m3e] 决定平铺形态：
  /// true = M3E 浮动胶囊里的 [VideoM3eIconButton]，false = Apple 顶栏的
  /// [FushiIconButtonControl] / [FushiPopupMenuButton]。
  List<FushiAdaptiveAction> _webBarActions({required bool m3e}) {
    Widget iconButton({
      required String tooltip,
      required Widget icon,
      required VoidCallback? onPressed,
      bool selected = false,
      VideoM3eButtonTone tone = VideoM3eButtonTone.neutral,
    }) => m3e
        ? _m3eIconAction(
            tooltip: tooltip,
            icon: icon,
            onPressed: onPressed,
            selected: selected,
            tone: tone,
          )
        : FushiIconButtonControl(
            tooltip: tooltip,
            icon: icon,
            onPressed: onPressed,
          );

    // 子菜单型动作收进「⋯」时就地展开：标题行 + 原菜单项（选中回调包成 value）。
    List<PopupMenuEntry<VoidCallback>> folded<T>(
      String header,
      List<PopupMenuEntry<T>> entries,
      void Function(T value) onSelected,
    ) => <PopupMenuEntry<VoidCallback>>[
      PopupMenuItem<VoidCallback>(
        enabled: false,
        height: 28,
        child: Text(header, style: Theme.of(context).textTheme.labelSmall),
      ),
      for (final PopupMenuEntry<T> e in entries)
        if (e is CheckedPopupMenuItem<T>)
          CheckedPopupMenuItem<VoidCallback>(
            value: () => onSelected(e.value as T),
            checked: e.checked,
            enabled: e.enabled,
            child: e.child,
          )
        else if (e is PopupMenuItem<T>)
          PopupMenuItem<VoidCallback>(
            value: () => onSelected(e.value as T),
            enabled: e.enabled && e.value != null,
            child: e.child,
          ),
    ];

    Widget menu<T>({
      required GlobalKey<PopupMenuButtonState<T>> menuKey,
      required String tooltip,
      required IconData icon,
      required PopupMenuItemBuilder<T> itemBuilder,
      required PopupMenuItemSelected<T> onSelected,
      bool selected = false,
    }) => m3e
        ? _m3eMenuButton<T>(
            menuKey: menuKey,
            tooltip: tooltip,
            icon: icon,
            itemBuilder: itemBuilder,
            onSelected: onSelected,
            selected: selected,
          )
        : FushiPopupMenuButton<T>(
            tooltip: tooltip,
            icon: FushiIcon(FushiIcons.resolve(icon, filled: selected)),
            onSelected: onSelected,
            itemBuilder: itemBuilder,
          );

    return <FushiAdaptiveAction>[
      FushiAdaptiveAction(
        icon: _windowed ? FushiIcons.tv : FushiIcons.video,
        label: t.web_video_hosting_menu,
        onPressed: null,
        inlineBuilder: (BuildContext _) => menu<WebVideoHosting>(
          menuKey: _hostingMenuKey,
          tooltip: t.web_video_hosting_menu,
          icon: _windowed ? FushiIcons.tv : FushiIcons.video,
          itemBuilder: _hostingMenuItems,
          onSelected: (WebVideoHosting h) => unawaited(_switchHosting(h)),
        ),
        foldedEntries: (BuildContext c) => folded<WebVideoHosting>(
          t.web_video_hosting_menu,
          _hostingMenuItems(c),
          (WebVideoHosting h) => unawaited(_switchHosting(h)),
        ),
      ),
      if (!_windowed)
        FushiAdaptiveAction(
          icon: FushiIcons.ai,
          label: t.video_shader_tier_off,
          onPressed: null,
          selected: _shaderActive,
          inlineBuilder: (BuildContext _) => menu<VideoShaderTier>(
            menuKey: _shaderMenuKey,
            tooltip: t.video_shader_tier_off,
            icon: FushiIcons.ai,
            selected: _shaderActive,
            itemBuilder: _shaderMenuItems,
            onSelected: (VideoShaderTier tier) =>
                unawaited(_selectShaderTier(tier)),
          ),
          foldedEntries: (BuildContext c) => folded<VideoShaderTier>(
            t.video_shader_tier_off,
            _shaderMenuItems(c),
            (VideoShaderTier tier) => unawaited(_selectShaderTier(tier)),
          ),
        ),
      if (_windowed)
        // 窗口宿主档不能录/截（画面归硬件 DRM）：队列交给内置档重放。
        FushiAdaptiveAction(
          icon: FushiIcons.ankiCard,
          label: t.web_video_mine_switch_builtin(count: _minePending),
          onPressed: _minePending == 0 ? null : _openBuiltinForMining,
          inlineBuilder: (BuildContext _) => iconButton(
            tooltip: t.web_video_mine_switch_builtin(count: _minePending),
            icon: _minePendingGlyph(),
            onPressed: _minePending == 0 ? null : _openBuiltinForMining,
          ),
        )
      else if (_mineRunning)
        FushiAdaptiveAction(
          icon: FushiIcons.stop,
          label: t.web_video_mine_queue_stop,
          onPressed: () => _mineStopRequested = true,
          inlineBuilder: (BuildContext _) => iconButton(
            tooltip: t.web_video_mine_queue_stop,
            icon: const FushiIcon(FushiIcons.stop),
            tone: VideoM3eButtonTone.error,
            onPressed: () => _mineStopRequested = true,
          ),
        )
      else
        FushiAdaptiveAction(
          icon: FushiIcons.ankiCard,
          label: t.web_video_mine_queue_run,
          onPressed: _minePending == 0
              ? null
              : () => unawaited(_runMineQueue()),
          inlineBuilder: (BuildContext _) => iconButton(
            tooltip: t.web_video_mine_queue_run,
            icon: _minePendingGlyph(),
            onPressed: _minePending == 0
                ? null
                : () => unawaited(_runMineQueue()),
          ),
        ),
      FushiAdaptiveAction(
        icon: FushiIcons.subtitles,
        label: t.web_video_track_menu,
        onPressed: null,
        selected: _activeTrackKey != null,
        inlineBuilder: (BuildContext _) => menu<String>(
          menuKey: _trackMenuKey,
          tooltip: t.web_video_track_menu,
          icon: FushiIcons.subtitles,
          selected: _activeTrackKey != null,
          itemBuilder: _trackMenuItems,
          onSelected: _selectTrack,
        ),
        foldedEntries: (BuildContext c) => folded<String>(
          t.web_video_track_menu,
          _trackMenuItems(c),
          _selectTrack,
        ),
      ),
      FushiAdaptiveAction(
        icon: _hideNativeSubtitles
            ? FushiIcons.visibilityOff
            : FushiIcons.visibility,
        label: t.web_video_hide_native_subtitles,
        onPressed: _toggleNativeSubtitlesHidden,
        selected: _hideNativeSubtitles,
        inlineBuilder: (BuildContext _) => iconButton(
          tooltip: t.web_video_hide_native_subtitles,
          icon: FushiIcon(
            _hideNativeSubtitles
                ? FushiIcons.visibilityOff
                : FushiIcons.visibility,
          ),
          selected: _hideNativeSubtitles,
          onPressed: _toggleNativeSubtitlesHidden,
        ),
      ),
      FushiAdaptiveAction(
        icon: FushiIcons.listView,
        label: t.video_subtitle_list,
        onPressed: _toggleList,
        selected: _listVisible,
        inlineBuilder: (BuildContext _) => iconButton(
          tooltip: t.video_subtitle_list,
          icon: FushiIcon(
            FushiIcons.resolve(FushiIcons.listView, filled: _listVisible),
          ),
          selected: _listVisible,
          onPressed: _toggleList,
        ),
      ),
      FushiAdaptiveAction(
        icon: FushiIcons.fullscreen,
        label: t.video_control_fullscreen,
        onPressed: () => unawaited(_toggleFullscreen()),
        inlineBuilder: (BuildContext _) => iconButton(
          tooltip: t.video_control_fullscreen,
          icon: const FushiIcon(FushiIcons.fullscreen),
          onPressed: () => unawaited(_toggleFullscreen()),
        ),
      ),
    ];
  }

  /// M3E 顶栏的一枚图标钮（tooltip + [VideoM3eIconButton]）。
  Widget _m3eIconAction({
    required String tooltip,
    required Widget icon,
    required VoidCallback? onPressed,
    bool selected = false,
    VideoM3eButtonTone tone = VideoM3eButtonTone.neutral,
  }) => FushiTooltip(
    message: tooltip,
    child: VideoM3eIconButton(
      icon: icon,
      onPressed: onPressed,
      extent: _kM3eBarExtent,
      selected: selected,
      tone: tone,
    ),
  );

  /// M3E 顶栏的下拉菜单钮。外观、Tab 聚焦、Enter / 手柄 A 触发都归
  /// [VideoM3eIconButton]；菜单仍由 [FushiPopupMenuButton] 弹出（锚点 / 动效 / 方向键
  /// 与其它菜单同一套），按钮经 [menuKey] 调 `showButtonMenu`。触发器本身
  /// `enabled: false` 只为不再在按钮外叠一层可聚焦的 InkWell（双焦点停靠）。
  ///
  /// 菜单在面板中性深色主题（[VideoM3ePanelTheme]）下弹出，与播放器其它浮层同色；
  /// 按钮本身换回页面主题，tonal 配色与其它顶栏钮同一种子。
  Widget _m3eMenuButton<T>({
    required GlobalKey<PopupMenuButtonState<T>> menuKey,
    required String tooltip,
    required IconData icon,
    required PopupMenuItemBuilder<T> itemBuilder,
    required PopupMenuItemSelected<T> onSelected,
    bool selected = false,
  }) {
    final ThemeData chromeTheme = Theme.of(context);
    return VideoM3ePanelTheme(
      child: FushiPopupMenuButton<T>(
        key: menuKey,
        enabled: false,
        tooltip: tooltip,
        onSelected: onSelected,
        itemBuilder: itemBuilder,
        child: Theme(
          data: chromeTheme,
          child: VideoM3eIconButton(
            icon: FushiIcon(FushiIcons.resolve(icon, filled: selected)),
            onPressed: () => menuKey.currentState?.showButtonMenu(),
            extent: _kM3eBarExtent,
            selected: selected,
          ),
        ),
      ),
    );
  }

  /// 字幕列表侧板的进场：从右侧弹入（spatial 弹簧；墨水屏 / 减弱动态效果下时长归零
  /// 直接到位）。只做位移不做宽度动画——画面区是 WebView2，逐帧改尺寸代价高。
  Widget _listPanelEntrance(Widget panel) {
    final FushiSpringSpec spring = context.fushiMotion.spatialDefault;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: spring.duration,
      curve: spring.curve,
      child: panel,
      builder: (BuildContext context, double v, Widget? child) =>
          Transform.translate(offset: Offset((1 - v) * 32, 0), child: child),
    );
  }

  /// Apple 设计系统的顶栏（[FushiAppBar]，与改动前同一结构；字形换成语义图标，
  /// Apple 下由 [FushiIcon] 自动映射 SF 风格）。
  PreferredSizeWidget _buildAppBar(VideoBookRow row, ColorScheme cs) {
    final ({int done, int total})? progress = _mineProgress;
    return FushiAppBar(
      title: Text(
        progress != null
            ? t.web_video_mine_queue_running(
                done: progress.done,
                total: progress.total,
              )
            : _barTitle(row),
        overflow: TextOverflow.ellipsis,
      ),
      actions: <Widget>[
        // 同 M3E 顶栏：动作默认全部平铺，窄窗放不下才收进「⋯」。
        FushiAdaptiveActionStrip(
          key: const ValueKey<String>('web-video-top-actions'),
          moreKey: const ValueKey<String>('web-video-top-actions-more'),
          foldFromStart: true,
          reservedWidth: FushiAdaptiveActionStrip.titleBarReservedWidth,
          actions: _webBarActions(m3e: false),
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
        if (_isMiningHost && !_windowed && Platform.isWindows) {
          // 控制器建好 = 浏览器进程已在；站点还没加载完、还没自动播放。后台制卡页同样
          // 要预起：它没有交接档，但站点照样一加载就带声音自动播放。
          _preStartFuture ??= _preStartSilentAudio();
        }
        unawaited(_applyShaderTier());
        controller.addJavaScriptHandler(
          handlerName: kWebVideoJsHandler,
          callback: limitWebPayload(
            kWebVideoJsHandler,
            kWebPayloadLargeMaxChars,
            _onJsMessage,
          ),
        );
        controller.addJavaScriptHandler(
          handlerName: kWebVideoKeyBridgeHandler,
          callback: limitWebPayload(
            kWebVideoKeyBridgeHandler,
            kWebPayloadTinyMaxChars,
            (List<dynamic> args) {
              _onKeyToken(args);
              return null;
            },
          ),
        );
      },
      onUpdateVisitedHistory:
          (InAppWebViewController _, WebUri? url, bool? __) =>
              _webViewUrl = url?.toString() ?? _webViewUrl,
      onLoadStop: (InAppWebViewController controller, WebUri? url) {
        _webViewUrl = url?.toString() ?? _webViewUrl;
        unawaited(
          _setNativeSubtitlesHidden(_hideNativeSubtitles || _mineRunning),
        );
        // BUG-2260：队列换集走 loadUrl 整页重载，上一份文档里的 chrome 隐藏 <style> 随之消失，
        // 之后每张卡都带控制条/分级提示。隐藏态归 Dart 所有，新文档就绪时按 _mineRunning 重挂。
        unawaited(_setPlayerChromeHidden(_mineRunning));
        unawaited(_js('window.__fushiWebVideo.replayCues()'));
        unawaited(_syncDomSubtitles());
      },
      onWebContentProcessDidTerminate: (InAppWebViewController _) =>
          unawaited(_deathGuard.handleWebContentTerminated()),
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
        initialTapLookup: _appModel.videoSubtitleListTapLookup,
        onTapLookupChanged: (bool value) =>
            unawaited(_appModel.setVideoSubtitleListTapLookup(value)),
        initialFilter: videoSubtitleListFilterFromName(
          _appModel.videoSubtitleListFilter,
        ),
        onFilterChanged: (VideoSubtitleListFilter value) =>
            unawaited(_appModel.setVideoSubtitleListFilter(value.name)),
        initialFontScaleIndex: _appModel.videoSubtitleListFontScaleIndex,
        onFontScaleIndexChanged: (int value) =>
            unawaited(_appModel.setVideoSubtitleListFontScaleIndex(value)),
        hoverAutoLookupEnabled: ReaderFushiSource.instance.hoverAutoLookup,
        hoverLookupModifier: ReaderFushiSource.instance.hoverLookupModifier,
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
