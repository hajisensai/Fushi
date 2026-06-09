import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:window_manager/window_manager.dart';

import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/anki/anki_view_model.dart';
import 'package:hibiki/src/media/drag_drop/drop_classification.dart';
import 'package:hibiki/src/media/drag_drop/hibiki_file_drop_target.dart';
import 'package:hibiki/src/media/video/m3u8_playlist.dart';
import 'package:hibiki/src/media/video/video_asbplayer_config.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/media/video/video_controls_theme_pair.dart';
import 'package:hibiki/src/media/video/video_filename_parser.dart';
import 'package:hibiki/src/media/video/video_mpv_config.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/media/video/video_player_shortcuts.dart';
import 'package:hibiki/src/media/video/video_shader_manager.dart';
import 'package:hibiki/src/media/video/video_subtitle_style.dart';
import 'package:hibiki/src/media/video/video_watch_tracker.dart';
import 'package:hibiki/src/pages/implementations/jimaku_subtitle_dialog.dart';
import 'package:hibiki/src/media/video/video_quick_settings_sheet.dart';
import 'package:hibiki/src/media/video/video_sidecar.dart';
import 'package:hibiki/src/media/video/video_subtitle_overlay.dart';
import 'package:hibiki/src/media/video/video_subtitle_source.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:hibiki/src/pages/implementations/dictionary_page_mixin.dart';
import 'package:hibiki/src/pages/implementations/stat_activity.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/remote_video_client.dart';
import 'package:hibiki/src/utils/app_ui_scale.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:hibiki/src/utils/misc/platform_utils.dart';
import 'package:hibiki/src/utils/misc/show_app_dialog.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_widgets.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';

/// 视频页：media_kit 播放器 + 可点击字幕 overlay（点词查词 + 制卡）。
///
/// 装配：[VideoPlayerController.load] 打开视频 + cue 同步 → [Stack] 叠
/// [Video]（media_kit 桌面控制：播放/进度/音量/全屏 + 顶栏字幕轨/音轨切换）
/// 与 [VideoSubtitleOverlay]（逐字符可点）。
///
/// 查词浮层与阅读器/词典页**统一**：点字幕字符 → [_lookupAt] 经
/// [DictionaryPageMixin] 的 [pushNestedPopup] 推入 [DictionaryPopupLayer] 浮层
/// （popup.html WebView，与书内/词典页同款：递归查词 + 单词发音 + auto-read +
/// 制卡），并用被点字符的屏幕 rect 定位。制卡走 mixin 的 [onMineEntry]——视频页
/// 覆写它注入视频专属上下文：当前帧截图 coverPath + 当前字幕 cue 的音频片段
/// （裁**当前选中音轨**）sasayakiAudioPath + 例句 sentence + 单词发音
/// （popup.js 已把 `{audio}` 写进 fields）。
///
/// 全屏：media_kit 全屏是独立 root 路由，复用同一 `controls` builder，故
/// [VideoSubtitleOverlay] 包进 controls builder（[_buildVideoControls]）随全屏
/// 一起进路由，保证全屏时字幕仍显示且可点查词。
///
/// 查词浮层用**根 Overlay**（`Overlay.of(context, rootOverlay: true)`）渲染，而非本页
/// `Stack`——这样全屏（media_kit 推到根 navigator 的独立路由）时浮层也能浮在全屏画面
/// **之上**，窗口/全屏统一一套。根 Overlay 在 [HibikiAppUiScale] 的 `FittedBox` 之内
/// （挂在 `MaterialApp.builder`），其坐标空间是**缩放后的小画布（view/s）**；若浮层直接在
/// 此渲染，其词典 WebView 会按小画布尺寸栅格化、再被外层 `FittedBox` 拉大 → **字糊**
/// （与 BUG-039 阅读器同源；BUG-051）。故 [_buildPopupOverlay] 把整棵浮层子树用
/// [HibikiAppUiScaleNeutralizer] 中和回**真实视口尺寸、净缩放=1**，WebView 按原生像素密度
/// 渲染 → 清晰。中和后浮层坐标系即真实屏幕空间（净变换=1），与 `localToGlobal` 的字符
/// rect 同系，故 [_lookupAt] **直接**用该屏幕 rect 定位（不再 ÷s 换算到画布），界面任意
/// 缩放下定位都不偏。
class VideoHibikiPage extends ConsumerStatefulWidget {
  const VideoHibikiPage({
    required this.bookUid,
    required this.repo,
    super.key,
  })  : remoteInfo = null,
        remoteClient = null;

  VideoHibikiPage.remote({
    required RemoteVideoInfo info,
    required this.repo,
    required RemoteVideoClient client,
    super.key,
  })  : bookUid = info.id,
        remoteInfo = info,
        remoteClient = client;

  final String bookUid;
  final VideoBookRepository repo;
  final RemoteVideoInfo? remoteInfo;
  final RemoteVideoClient? remoteClient;

  /// 打开视频播放页的**唯一入口**：在路由层用 [HibikiAppUiScaleNeutralizer] 把整页中和
  /// （与阅读器 [ReaderHibikiSource.buildLaunchPage] 同范式）。
  ///
  /// 根因（用户报「视频没画面」）：全局 [HibikiAppUiScale] 用 `FittedBox(BoxFit.fill)` 把
  /// 整棵子树渲染进一个缩放画布再拉大；media_kit 的 [Video] 在桌面是平台 Texture，落在
  /// 缩放画布里会被栅格化再放大 → 糊甚至空白（无画面）。阅读器早已在路由层中和，视频页
  /// 此前三个 push 点都漏了这层 → 用户调过界面缩放后视频就没画面。统一收口到这里，让
  /// [Video] 的 Texture 落在净缩放=1 的真实视口、按原生密度渲染，并杜绝再漏第四处。
  static Widget neutralized({
    required String bookUid,
    required VideoBookRepository repo,
  }) =>
      HibikiAppUiScaleNeutralizer(
        child: VideoHibikiPage(bookUid: bookUid, repo: repo),
      );

  static Widget neutralizedRemote({
    required RemoteVideoInfo info,
    required VideoBookRepository repo,
    required RemoteVideoClient client,
  }) =>
      HibikiAppUiScaleNeutralizer(
        child: VideoHibikiPage.remote(
          info: info,
          repo: repo,
          client: client,
        ),
      );

  /// 查词浮层关闭后是否应恢复播放：仅当浮层栈**已全部关闭**（[stackEmpty]）且本次确实
  /// 是因查词而由我们暂停了正在播放的视频（[pausedForLookup]）。两条件缺一不可——关掉
  /// 递归查词的子层但父层仍在（栈非空）不恢复；查词前本就暂停的视频（未置位）也不恢复。
  /// 纯函数：与 [_VideoHibikiPageState._popNestedPopupAt] 共用，供单测直接验证（BUG-072）。
  @visibleForTesting
  static bool shouldResumeAfterLookupDismiss({
    required bool stackEmpty,
    required bool pausedForLookup,
  }) =>
      stackEmpty && pausedForLookup;

  @override
  ConsumerState<VideoHibikiPage> createState() => _VideoHibikiPageState();
}

class _VideoOsdMessage {
  const _VideoOsdMessage({
    required this.message,
    this.icon,
    this.progress,
  });

  final String message;
  final IconData? icon;
  final double? progress;
}

/// 集成测试钩子（仅测试用）：对当前 [VideoHibikiPage] 的 [State] 读播放位置 /
/// 驱动真实播放，验证「退出→再进续播」链路而不暴露页面私有字段。State 以
/// [VideoHibikiTestHooks] 形式按接口暴露，测试经 `tester.state` 拿到后 `as` 转型。
@visibleForTesting
abstract class VideoHibikiTestHooks {
  /// 当前播放位置（毫秒）；未就绪为 null。
  int? get debugPositionMs;

  /// 开始真实播放（驱动 libmpv），让位置自然前进。
  Future<void> debugPlay();
}

class _VideoHibikiPageState extends ConsumerState<VideoHibikiPage>
    with DictionaryPageMixin, WidgetsBindingObserver
    implements VideoHibikiTestHooks {
  static const double _videoButtonBarHeight = 56;
  static const double _videoControlIconSize = 32;
  static const double _videoPlayPauseIconSize = 36;
  static const Duration _videoDoubleClickInterval = Duration(milliseconds: 400);
  static const double _videoDoubleClickSlop = 48;
  static const int _subtitleOffsetStepMs = 100;
  static const double _volumeStep = 5.0;

  int get _asbSeekMs => _asbConfig.seekSeconds * 1000;
  double get _speedStep => _asbConfig.speedStep;

  ColorScheme _videoChromeColorScheme(BuildContext context) =>
      Theme.of(context).colorScheme;

  TextStyle _videoControlTitleStyle(ColorScheme cs) => TextStyle(
        color: cs.onSurface,
        fontSize: 16,
      );

  Color _subtitleTextColor(ColorScheme cs) => cs.onSurface;
  Color _subtitleShadowColor(ColorScheme cs) => cs.shadow;
  Color _subtitleBackgroundColor(ColorScheme cs) => cs.surface;
  double get _videoUiScale => appModel.appUiScale;

  Color _osdSurfaceColor(ColorScheme cs) =>
      cs.inverseSurface.withValues(alpha: 0.82);

  Color _osdTextColor(ColorScheme cs) => cs.onInverseSurface;

  @override
  int? get debugPositionMs => _controller?.positionMs;

  @override
  Future<void> debugPlay() async => _controller?.play();

  VideoPlayerController? _controller;
  bool _failed = false;
  String? _title;

  /// 顶栏标题的响应式来源（BUG-120）。顶栏文字渲染在 media_kit 控制条主题里，全屏是
  /// 推到根 navigator 的独立路由、进入时**快照捕获**当时的主题（含标题字符串），页面
  /// `setState` 不会重建全屏路由 → 全屏换集后标题停在旧集。改用 [ValueNotifier] + 顶栏
  /// `ValueListenableBuilder` 监听：它在全屏路由内也会随 notifier 变化自重建，标题跟上。
  final ValueNotifier<String?> _titleNotifier = ValueNotifier<String?>(null);

  /// 视频内角标通知（mpv 式 OSD）。取代会从屏幕底部弹出、遮挡控制条、且与 mpv 等
  /// 播放器观感割裂的 Material SnackBar（用户要求改成 mpv 那样的左上角短暂提示）。
  /// null=不显示。渲染在 [_buildVideoControls] 的 controls overlay 里，故窗口/全屏
  /// 都显示；[IgnorePointer] 包裹，绝不拦截点击（不破坏单击暂停 / 拖放 / 字幕查词）。
  final ValueNotifier<_VideoOsdMessage?> _osdNotifier =
      ValueNotifier<_VideoOsdMessage?>(null);

  /// OSD 自动消失定时器（每次 [_showOsd] 重置）。
  Timer? _osdTimer;

  /// 在视频左上角短暂显示一条 OSD 通知（约 2.6s 后自动消失）。mounted-safe，可在
  /// `await` 之后直接调（取代各处 `ScaffoldMessenger.showSnackBar`）。
  void _showOsd(String message, {IconData? icon, double? progress}) {
    if (!mounted) return;
    _osdNotifier.value = _VideoOsdMessage(
      message: message,
      icon: icon,
      progress: progress == null ? null : progress.clamp(0.0, 1.0).toDouble(),
    );
    _osdTimer?.cancel();
    _osdTimer = Timer(const Duration(milliseconds: 2600), () {
      _osdNotifier.value = null;
    });
  }

  /// media_kit [Video] 的键盘焦点节点。media_kit 的 `Video` 自带 FocusNode + 内置
  /// 快捷键（空格=播放/暂停、方向键=快进/快退/音量等）。本页把这个节点提到 State 持有，
  /// 是为了在任何**会夺走窗口键盘焦点的覆盖层**（对话框 / bottom sheet / 系统文件选择器）
  /// 关闭后，能主动把焦点还给 [Video]——否则那些覆盖层关闭后焦点悬空，空格等快捷键失灵
  /// （根因：FilePicker 打开系统对话框抢走焦点，关闭后不会自动归还）。见 [_refocusVideo]。
  final FocusNode _videoFocusNode = FocusNode(debugLabel: 'videoKeyboard');

  /// media_kit controls 子树内的 [BuildContext]（在 [_buildVideoControls] 用 [Builder]
  /// 捕获）。覆盖默认键盘快捷键时，全屏相关 helper（[isFullscreen]/[toggleFullscreen]/
  /// [exitFullscreen]）必须用 controls 子树内的 context 才能找到 media_kit 的
  /// `FullscreenInheritedWidget` / `VideoStateInheritedWidget`——本页 build 的 context 是
  /// 它们的祖先，传进去会查不到。故捕获一个后代 context 供 Escape/F 快捷键用。
  BuildContext? _videoControlsContext;
  DateTime? _lastVideoPointerUpAt;
  Offset? _lastVideoPointerUpPosition;
  bool _videoFullscreenTransitioning = false;

  /// 观看统计采集器（观看时长 + 字幕字数 + 完成标记）；首次 load 建，dispose 释放。
  VideoWatchTracker? _watchTracker;

  /// 查词浮层栈（与阅读器/词典页同款，由共享 [DictionaryPopupController] 管理）。
  /// 在 initState 安全读取一次 lowMemory 构造——不可放字段初始化器懒读 appModel，
  /// 否则首次访问可能落在 dispose/deactivate 的 postframe（element 树不稳定）→ ref.read 抛错。
  late final DictionaryPopupController _popup;

  /// 字幕字符命中句柄：查词浮层的 dismiss barrier 用它反查「点到的是不是另一个字幕
  /// 字符」，是则切换查词、保持暂停（见 [_onDismissBarrierTap] / [VideoSubtitleHitTester]）。
  final VideoSubtitleHitTester _subtitleHitTester = VideoSubtitleHitTester();

  /// 承载查词浮层栈的根 Overlay 入口；非空时浮层栈渲染在根 Overlay（窗口/全屏统一，
  /// 全屏时浮在 media_kit 全屏路由之上）。栈空时移除、栈变化时 `markNeedsBuild`。
  OverlayEntry? _popupOverlayEntry;

  /// 最近一次查词所在字幕句（整条 cue 文本）；[onMineEntry] 制卡时作 sentence。
  /// 点字符查词时即时记录，确保制卡例句是「点词那一刻的那句字幕」。
  String _lastLookupSentence = '';

  /// 最近一次字幕查词所在 cue。制卡可能发生在弹窗打开后数秒，此时视频播放位置可能已
  /// 变化；GIF / sasayaki 音频必须仍然导出点词那句，而不是制卡瞬间的 currentCue。
  AudioCue? _lastLookupCue;

  /// 「本次查词浮层是我们因查词而主动暂停了正在播放的视频」标记。
  ///
  /// 查词暂停 / 关浮层恢复与阅读器 [ReaderHibikiPage] 同源：浮层打开时若视频在播放则
  /// 暂停（让用户读词），浮层栈**全部关闭**后再自动恢复播放。video 页用
  /// [DictionaryPageMixin]（没有 reader 的 `onAllPopupsDismissed` 钩子），故用本标记 +
  /// 在 [_popNestedPopupAt] 这唯一的关栈汇聚点恢复，覆盖遮罩点击 / 返回键 / 浮层
  /// 滑动·Esc 全部关闭路径。仅当查词前视频确在播放才置位，避免把查词前本就暂停的
  /// 视频自动播起来；递归查词（已暂停，`isPlaying==false`）不会覆写它（BUG-072）。
  bool _pausedForLookup = false;

  // ── DictionaryPageMixin 必需的抽象成员 ──────────────────────────────
  @override
  AppModel get mixinAppModel => appModel;

  @override
  ThemeData get mixinTheme => Theme.of(context);

  // 视频页的收藏/制卡计入视频统计（而非书籍统计）。
  @override
  String get dictionarySourceType => kStatSourceVideo;

  /// 多集播放列表（单视频导入时为空）。
  List<PlaylistEntry> _episodes = const <PlaylistEntry>[];

  /// 当前集索引（[_episodes] 下标）；单视频恒 0。
  int _currentEpisode = 0;

  /// 底部菜单（剧集/轨道/倍速/设置/字幕源）重入守卫：为真时已有一个 sheet 在开/在显，
  /// 快速重复点击不再叠开第二个。开 sheet 前置真，sheet 关闭（whenComplete）或异步早
  /// 返回时复位。修「点菜单/字幕点快了弹出两个」。
  bool _videoSheetOpen = false;

  /// 换集加载代际计数：每次 [_loadEpisode] 自增并捕获本次序号；其慢路径（ffmpeg
  /// 枚举字幕源 + 解析 cue）跑完后若序号已被后续切集取代，则放弃应用，避免「播放中
  /// 途快速切集时旧的慢加载落地后覆盖新集字幕/视频」（用户报：切到第4集字幕/音画
  /// 对不上，疑似中途切换；本机不可复现，加此守卫兜底竞态）。
  int _episodeLoadSeq = 0;

  /// 当前播放的视频文件绝对路径（枚举字幕源用）；未 load 时为 null。
  String? _currentVideoPath;

  /// 当前选中的字幕源持久化值（外挂路径 / `embedded:<n>` / null=关闭）；
  /// 用于字幕源菜单高亮当前项。
  String? _currentSubtitleSource;

  /// 当前选中的音轨 id（libmpv `AudioTrack.id`）；null=未选过跟随默认。
  /// 多集换集时复用同一值（用户选了日语音轨，每集都用日语）。
  String? _currentAudioTrackId;

  /// 音画延迟（毫秒）：字幕 cue 同步偏移，跨重启保留；换集复用同一值。
  int _delayMs = 0;

  /// 播放倍速：用户在设置面板调，跨重启保留；换集复用同一值（速度记忆）。
  double _playbackSpeed = 1.0;

  /// 当前字幕外观（全局偏好快照；设置面板改动后刷新）。
  VideoSubtitleStyle _subtitleStyle = VideoSubtitleStyle.defaults;
  VideoAsbplayerConfig _asbConfig = VideoAsbplayerConfig.defaults;

  /// 桌面端是否把原生窗口锁定为当前视频比例。移动端窗口不可改尺寸。
  bool _lockWindowAspectRatio = true;
  double? _appliedWindowAspectRatio;

  bool get _isPlaylist => _episodes.length > 1;

  /// 缓存的 [AppModel] 引用。`appProvider` 是单例（实例不变），在 [initState] 一次
  /// 性读取并缓存。**不能**每次 `ref.read(appProvider)`：浮层层（[buildNestedPopupLayer]）
  /// 在 `LayoutBuilder` 回调里访问 `mixinAppModel`，而 widget 失活（deactivated）后
  /// `ref.read` 会抛「Looking up a deactivated widget's ancestor is unsafe」。缓存实例
  /// 后即使 widget 已失活也安全（BUG: 视频查词关页时崩溃）。
  late final AppModel _appModel = ref.read(appProvider);

  AppModel get appModel => _appModel;

  bool get _isRemote => widget.remoteInfo != null;

  /// app 当前目标学习语言代码（如 `'ja'`/`'ko'`），用于 sidecar 字幕语言优先检测。
  String get _targetLangCode => appModel.targetLanguage.locale.languageCode;

  @override
  void initState() {
    super.initState();
    // 不在 initState 读 appModel.lowMemoryMode（它读 prefsRepo，未初始化会抛；
    // 错误态 smoke 用未初始化 AppModel）。先建空 controller，真实 lowMemory 留到
    // _seedWarmPopup（成功路径、必已初始化）再设——与 base_source_page 同范式。
    _popup = DictionaryPopupController(lowMemory: false);
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  /// app 进后台（[AppLifecycleState.inactive]/`.paused`/`.hidden`）时把当前播放
  /// 位置 **await 落库**：dispose 在硬杀进程时不会跑，周期保存是 fire-and-forget
  /// 且后台定时器会挂起。趁 controller 仍存活把退出瞬间位置写穿（对齐阅读器
  /// `_syncAndFlushPosition`）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.inactive:
        // inactive 仅瞬态过渡（通知栏下拉 / 多任务切换）：落库即可，不停观看计时
        // （频繁误停丢真实时长）；clamp（[isContinuousWatchGap]）兜底任何残留异常间隔。
        unawaited(_controller?.flushPosition());
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        // 真后台 / 熄屏：落库 + 暂停观看计时器，避免把后台时长计入。stop() 内部先 flush
        // 退出瞬间的部分窗口（≤60s）再 cancel，不丢已观看时长。
        unawaited(_controller?.flushPosition());
        _watchTracker?.stop();
      case AppLifecycleState.resumed:
        // 回前台：重启观看计时器（start() 重置 _tickStart=now，下一窗从此刻起算）。
        _watchTracker?.start();
      case AppLifecycleState.detached:
        break;
    }
  }

  Future<void> _init() async {
    if (_isRemote) {
      await _initRemote();
      return;
    }
    final VideoBookRow? row = await widget.repo.getByBookUid(widget.bookUid);
    if (row == null) {
      if (mounted) setState(() => _failed = true);
      return;
    }

    // 记录持久化的字幕源（菜单高亮当前项用）+ 音轨偏好（换集复用）+ 音画延迟
    // （跨重启保留）+ 播放倍速（per-book 偏好，速度记忆）。
    _currentSubtitleSource = row.subtitleSource;
    _currentAudioTrackId = row.audioTrackId;
    _delayMs = row.delayMs;
    _playbackSpeed = _readPersistedSpeed();
    _subtitleStyle = VideoSubtitleStyle.decode(appModel.videoSubtitleStyle);
    _asbConfig = VideoAsbplayerConfig.decode(appModel.videoAsbplayerConfig);
    _lockWindowAspectRatio = appModel.videoLockWindowAspectRatio;

    // 解析播放列表（若有）。非空则按 currentEpisode 载对应集；否则走单视频路径。
    final String? playlistJson = row.playlistJson;
    if (playlistJson != null && playlistJson.isNotEmpty) {
      final List<dynamic> raw = jsonDecode(playlistJson) as List<dynamic>;
      _episodes = raw
          .map((dynamic e) => PlaylistEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    }

    if (_episodes.isNotEmpty) {
      final int idx = row.currentEpisode.clamp(0, _episodes.length - 1);
      // 每集各记自己的进度：恢复到 currentEpisode 那集的 entry.positionMs
      // （取代旧的「整个 VideoBook 一个 lastPositionMs」）。
      await _loadEpisode(
        idx,
        initialPositionMs: _episodes[idx].positionMs,
        subtitleSource: row.subtitleSource,
      );
      return;
    }

    // 单视频路径（无播放列表）。
    await _loadSingle(row);
  }

  Future<void> _initRemote() async {
    final RemoteVideoInfo info = widget.remoteInfo!;
    final RemoteVideoClient client = widget.remoteClient!;
    _currentSubtitleSource = null;
    _currentAudioTrackId = null;
    _delayMs = 0;
    _playbackSpeed = _readPersistedSpeed();
    _subtitleStyle = VideoSubtitleStyle.decode(appModel.videoSubtitleStyle);

    try {
      final RemoteVideoStreamUrls urls =
          await client.remoteVideoStreamUrls(info.id);
      String? externalSub;
      List<AudioCue> cues = const <AudioCue>[];
      if (urls.subtitleUrl != null) {
        final Directory temp = await getTemporaryDirectory();
        final File subtitle = File(p.join(
          temp.path,
          'hibiki_remote_${_safeFileName(info.id)}.srt',
        ));
        await client.getRemoteVideoSubtitle(info.id, subtitle);
        externalSub = subtitle.path;
        cues = await _loadExternalSubtitleCues(subtitle.path, info.id);
      }
      await _applyLoad(
        videoPath: null,
        mediaUri: urls.streamUrl,
        cues: cues,
        title: info.title,
        initialPositionMs: 0,
        externalSubtitlePath: externalSub,
      );
    } catch (e, stack) {
      debugPrint('[VideoHibikiPage] remote video load failed: $e\n$stack');
      if (mounted) setState(() => _failed = true);
    }
  }

  /// per-book 播放倍速偏好 key（速度记忆，跨重启保留）。
  String get _speedPrefKey => 'video_speed_${widget.bookUid}';

  /// 读 per-book 持久化倍速（无则 1.0）。
  double _readPersistedSpeed() {
    final double v =
        (appModel.prefsRepo.getPref(_speedPrefKey, defaultValue: 1.0) as num)
            .toDouble();
    return v.clamp(0.25, 4.0);
  }

  /// 载入单视频（无播放列表）：优先用 DB 已存 cue；否则先尝试恢复用户上次选的
  /// 字幕源（[row.subtitleSource] 跨重启保留），无匹配再退默认 sidecar 探测。
  Future<void> _loadSingle(VideoBookRow row) async {
    List<AudioCue> cues = await widget.repo.loadCues(widget.bookUid);
    String? externalSub = row.subtitleSource;
    int? graphicStreamIndex;

    if (cues.isEmpty) {
      // ① 优先恢复持久化的字幕源（精确匹配本视频的同一源）。
      if (row.subtitleSource != null && row.subtitleSource!.isNotEmpty) {
        final ({
          String persisted,
          List<AudioCue> cues,
          int? graphicStreamIndex
        })? restored = await _restorePersistedSubtitle(
          videoPath: row.videoPath,
          persisted: row.subtitleSource,
          crossEpisode: false,
        );
        if (restored != null) {
          cues = restored.cues;
          externalSub = restored.persisted;
          graphicStreamIndex = restored.graphicStreamIndex;
        }
      }
      // ② 无持久化 / 无匹配：退默认 sidecar 探测。
      if (cues.isEmpty && externalSub == null) {
        final ({String path, List<AudioCue> cues})? sidecar =
            await _detectSidecar(row.videoPath, widget.bookUid);
        if (sidecar != null) {
          cues = sidecar.cues;
          externalSub = sidecar.path;
        }
      }
    }
    await _applyLoad(
      videoPath: row.videoPath,
      cues: cues,
      title: row.title,
      initialPositionMs: row.lastPositionMs,
      externalSubtitlePath: externalSub,
      renderGraphicStreamIndex: graphicStreamIndex,
    );
  }

  /// 尝试用持久化偏好 [persisted] 在 [videoPath] 的可用字幕源里选一个并加载 cue。
  ///
  /// [crossEpisode]=false（单视频重启恢复）：用 [SubtitleSource.matchesPersisted]
  /// 精确匹配同一源。[crossEpisode]=true（播放列表换集）：用
  /// [pickEpisodeSubtitleSource] 按「同类偏好」（内嵌同 streamIndex / 外挂同语言
  /// 后缀）从新集源里选。
  ///
  /// 返回所选源的「实际持久化值 + 解析出的 cue」；无匹配 / 解析空 cue 返回 null
  /// （调用方退默认 sidecar）。返回的 persisted 用作 [_applyLoad] 的
  /// externalSubtitlePath（内嵌源也走 `embedded:<n>` 字符串，与既有约定一致）。
  Future<({String persisted, List<AudioCue> cues, int? graphicStreamIndex})?>
      _restorePersistedSubtitle({
    required String videoPath,
    required String? persisted,
    required bool crossEpisode,
  }) async {
    if (persisted == null || persisted.isEmpty) return null;

    // BUG-132: 用户手动导入 / Jimaku 下载的外挂字幕被拷到 `<appDocs>/video_subtitles/`，
    // **不在剧集目录里**，而 [listAllSubtitleSources] 只扫视频同目录 + 内封轨 → 播放
    // 列表换集/重进时匹配不到，导致「退出后字幕又要重新导入」。这类源的持久化值就是
    // 它自己的绝对路径，且与剧集无关——只要文件还在磁盘上就按路径直接加载，无需经
    // listAllSubtitleSources 的同目录枚举。单视频路径已由 `_loadSingle` 的 loadCues
    // 命中、走不到这里；本捷径主要救播放列表（只存源指针不存 cue）。
    if (isImportedExternalSubtitlePath(persisted) &&
        File(persisted).existsSync()) {
      final SubtitleSource external = SubtitleSource.external(
        externalPath: persisted,
        label: p.basename(persisted),
      );
      final List<AudioCue> cues =
          await loadCuesForSource(external, videoPath, widget.bookUid);
      if (cues.isNotEmpty) {
        return (
          persisted: external.toPersistedValue(),
          cues: cues,
          graphicStreamIndex: null,
        );
      }
      // 文件在但解析空（坏字幕）：落回下面的同目录枚举，别让一个坏导入挡住别的源。
    }

    final List<SubtitleSource> sources =
        await listAllSubtitleSources(videoPath, langCode: _targetLangCode);
    if (sources.isEmpty) return null;

    final SubtitleSource? chosen = crossEpisode
        ? pickEpisodeSubtitleSource(persisted, sources)
        : _firstMatching(sources, persisted);
    if (chosen == null) return null;

    // 图形内封轨（PGS 等位图）无文本 cue：返回 graphicStreamIndex，让 [_applyLoad]
    // 经 libmpv 画面渲染恢复（不走 loadCues→空→误退 sidecar）（BUG-122）。
    if (chosen.isGraphicEmbedded) {
      return (
        persisted: chosen.toPersistedValue(),
        cues: const <AudioCue>[],
        graphicStreamIndex: chosen.streamIndex,
      );
    }

    final List<AudioCue> cues =
        await loadCuesForSource(chosen, videoPath, widget.bookUid);
    if (cues.isEmpty) return null;
    return (
      persisted: chosen.toPersistedValue(),
      cues: cues,
      graphicStreamIndex: null,
    );
  }

  /// 字幕菜单来源：保留当前视频枚举结果，再只补入「当前视频已持久化」的导入字幕。
  Future<List<SubtitleSource>> _subtitleSourcesForMenu({
    required String videoPath,
    required String? currentSubtitleSource,
  }) async {
    final List<SubtitleSource> sources =
        await listAllSubtitleSources(videoPath, langCode: _targetLangCode);
    if (currentSubtitleSource == null ||
        !isImportedExternalSubtitlePath(currentSubtitleSource) ||
        !File(currentSubtitleSource).existsSync()) {
      return sources;
    }

    if (sources.any((SubtitleSource source) =>
        _sameExternalSubtitlePath(source, currentSubtitleSource))) {
      return sources;
    }

    final SubtitleSource source = SubtitleSource.external(
      externalPath: currentSubtitleSource,
      label: p.basename(currentSubtitleSource),
    );
    final List<AudioCue> cues =
        await loadCuesForSource(source, videoPath, widget.bookUid);
    if (cues.isEmpty) return sources;

    sources.add(source);
    return sources;
  }

  bool _subtitleSourceSelectedForMenu(
    SubtitleSource source,
    String? currentSubtitleSource,
  ) {
    if (source.matchesPersisted(currentSubtitleSource)) return true;
    if (currentSubtitleSource == null ||
        !isImportedExternalSubtitlePath(currentSubtitleSource)) {
      return false;
    }
    return _sameExternalSubtitlePath(source, currentSubtitleSource);
  }

  bool _sameExternalSubtitlePath(
    SubtitleSource source,
    String currentSubtitleSource,
  ) {
    if (source.isEmbedded || source.externalPath == null) return false;
    return _subtitlePathKey(source.externalPath!) ==
        _subtitlePathKey(currentSubtitleSource);
  }

  String _subtitlePathKey(String path) {
    final String key = p.canonicalize(path);
    return Platform.isWindows ? key.toLowerCase() : key;
  }

  /// 在 [sources] 中找第一个 [matchesPersisted] 命中的源（精确恢复用）。
  SubtitleSource? _firstMatching(
    List<SubtitleSource> sources,
    String persisted,
  ) {
    for (final SubtitleSource s in sources) {
      if (s.matchesPersisted(persisted)) return s;
    }
    return null;
  }

  /// 载入播放列表第 [index] 集：先按上次选择的「同类偏好」选新集字幕源
  /// （[subtitleSource] 是上次持久化的偏好），无匹配再退默认 sidecar 探测。
  ///
  /// cue 不存 DB——每集 load 时按文件动态解析（播放列表各集字幕是外部文件，本就随
  /// 磁盘存在；存 DB 只会与磁盘真相重复且引入跨集 book_uid 错配）。
  Future<void> _loadEpisode(
    int index, {
    int initialPositionMs = 0,
    String? subtitleSource,
  }) async {
    if (index < 0 || index >= _episodes.length) return;
    final PlaylistEntry episode = _episodes[index];
    // 本次加载的代际序号；慢路径跑完后据此判断是否已被后续切集取代。
    final int seq = ++_episodeLoadSeq;

    List<AudioCue> cues = const <AudioCue>[];
    String? externalSub;
    int? graphicStreamIndex;

    // ① 按上次偏好（同类）选新集字幕源：内嵌同 streamIndex / 外挂同语言后缀。
    if (subtitleSource != null && subtitleSource.isNotEmpty) {
      final ({
        String persisted,
        List<AudioCue> cues,
        int? graphicStreamIndex
      })? restored = await _restorePersistedSubtitle(
        videoPath: episode.path,
        persisted: subtitleSource,
        crossEpisode: true,
      );
      if (restored != null) {
        cues = restored.cues;
        externalSub = restored.persisted;
        graphicStreamIndex = restored.graphicStreamIndex;
      }
    }

    // ② 无偏好 / 无匹配：退默认 sidecar 探测。图形轨恢复时 cues 虽空但 externalSub
    // 已置（embedded:<n>），不能让 sidecar 覆盖掉画面字幕选择（BUG-122）。
    if (cues.isEmpty && externalSub == null) {
      final ({String path, List<AudioCue> cues})? sidecar =
          await _detectSidecar(episode.path, widget.bookUid);
      if (sidecar != null) {
        cues = sidecar.cues;
        externalSub = sidecar.path;
      }
    }

    // 慢路径（ffmpeg 枚举 + cue 解析）期间若已被后续切集取代，放弃应用避免覆盖新集。
    if (seq != _episodeLoadSeq || !mounted) {
      debugPrint('[video-episode] superseded: ep$index seq=$seq '
          'cur=$_episodeLoadSeq — skip apply');
      return;
    }
    // 诊断（用户报「切到第4集字幕/音画对不上」，本机不可复现）：记录实际选中的字幕源
    // 与解析出的 cue 数 + 首句，便于真机切集后回看日志锁定是否选错源/空 cue/错集。
    debugPrint('[video-episode] load ep$index "${episode.title}" '
        'path=${episode.path} subSrc=$externalSub cues=${cues.length}'
        '${cues.isNotEmpty ? ' first=[${cues.first.startMs}ms]${cues.first.text}' : ''}');

    _currentEpisode = index;
    await _applyLoad(
      videoPath: episode.path,
      cues: cues,
      title: episode.title,
      initialPositionMs: initialPositionMs,
      externalSubtitlePath: externalSub,
      renderGraphicStreamIndex: graphicStreamIndex,
    );
  }

  /// 探测视频同目录 sidecar 字幕并解析为 cue（无则 null）。
  ///
  /// 按 app 学习语言优先（学日语 → `.ja.srt > .ja.ass > … > .srt > .ass …`，
  /// 见 [findSidecarSubtitle]）；按扩展名路由 [SrtParser] / [AssParser]。IO + 解析
  /// 失败静默返回 null。
  Future<({String path, List<AudioCue> cues})?> _detectSidecar(
    String videoPath,
    String bookUid,
  ) async {
    final String? sidecarPath =
        findSidecarSubtitle(videoPath, langCode: _targetLangCode);
    if (sidecarPath == null) return null;
    try {
      final String text = await readTextWithEncoding(File(sidecarPath));
      final List<AudioCue> cues = sidecarPath.toLowerCase().endsWith('.ass')
          ? AssParser.parseString(content: text, bookKey: bookUid)
          : SrtParser.parseString(content: text, bookKey: bookUid);
      if (cues.isEmpty) return null;
      return (path: sidecarPath, cues: cues);
    } catch (e) {
      debugPrint('[VideoHibikiPage] sidecar parse failed: $e');
      return null;
    }
  }

  Future<List<AudioCue>> _loadExternalSubtitleCues(
    String path,
    String bookUid,
  ) async {
    try {
      final String text = await readTextWithEncoding(File(path));
      return path.toLowerCase().endsWith('.ass')
          ? AssParser.parseString(content: text, bookKey: bookUid)
          : SrtParser.parseString(content: text, bookKey: bookUid);
    } catch (e) {
      debugPrint('[VideoHibikiPage] external subtitle parse failed: $e');
      return const <AudioCue>[];
    }
  }

  /// 共享 load 装配：复用或新建 controller，载入视频 + cue，挂位置持久化回调。
  Future<void> _applyLoad({
    required String? videoPath,
    String? mediaUri,
    required List<AudioCue> cues,
    required String title,
    required int initialPositionMs,
    String? externalSubtitlePath,
    int? renderGraphicStreamIndex,
  }) async {
    final VideoPlayerController controller =
        _controller ?? VideoPlayerController();
    final VideoMpvConfig mpvConfig =
        VideoMpvConfig.decode(appModel.videoMpvConfig);
    // 解析启用的 mpv 着色器为绝对路径（桌面 libmpv 生效，移动端最终静默）。
    // 「画质增强」主开关关闭时保留持久化勾选，但运行时旁路所有 shader。
    final List<String> shaderPaths = mpvConfig.highQuality
        ? await resolveEnabledShaderPaths(
            decodeEnabledShaders(appModel.videoShadersEnabled))
        : const <String>[];
    try {
      await controller.load(
        bookUid: widget.bookUid,
        videoFile: videoPath == null ? null : File(videoPath),
        mediaUri: mediaUri,
        cues: cues,
        initialPositionMs: initialPositionMs,
        initialSpeed: _playbackSpeed,
        externalSubtitlePath: externalSubtitlePath,
        renderGraphicStreamIndex: renderGraphicStreamIndex,
        shaderPaths: shaderPaths,
        mpvConfig: mpvConfig,
        autoPlay: true,
      );
    } catch (e, stack) {
      debugPrint('[VideoHibikiPage] video load failed: $e\n$stack');
      if (_controller == null) controller.dispose();
      if (mounted) setState(() => _failed = true);
      return;
    }
    // 应用持久化的音画延迟（换集复用同一值；load 不重置 delay）。
    controller.setDelayMs(_delayMs);
    controller.setPauseAtSubtitleEnd(_asbConfig.pauseAtSubtitleEnd);
    controller.onPositionWrite = _isRemote ? null : _persistPosition;
    controller.removeListener(_syncWindowAspectRatioLock);
    controller.addListener(_syncWindowAspectRatioLock);
    if (!mounted) {
      if (_controller == null) controller.dispose();
      return;
    }
    // 标题先推给响应式 notifier，让全屏路由顶栏（不随页面 setState 重建）也跟上（BUG-120）。
    _titleNotifier.value = title;
    setState(() {
      _controller = controller;
      _title = title;
      _failed = false;
      _currentVideoPath = videoPath;
      // 外挂字幕路径即持久化值；内嵌自动加载（externalSubtitlePath==null）时
      // 当前选中由 _currentSubtitleSource 保留（菜单切换时再写）。
      _currentSubtitleSource = externalSubtitlePath ?? _currentSubtitleSource;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refocusVideo();
    });
    _syncWindowAspectRatioLock();

    // 视频就绪后预热查词浮层（BUG-094）：seed 一个常驻隐藏热 WebView，全程复用，
    // 查词不再每次冷加载白屏。放成功分支（缺书/错误态不预热，无视频无需查词）。
    _seedWarmPopup();
    if (videoPath != null) {
      // TODO-011: large REMUX containers can spend many seconds demuxing text
      // embedded subtitles on the first switch. Start the shared cache fill
      // only after playback has opened so UI/video startup is not blocked.
      unawaited(prewarmEmbeddedSubtitleCache(videoPath));
    }

    // 首次 load 建观看统计采集器；换片复用同一 controller 实例，已 attach 不重建。
    if (!_isRemote && _watchTracker == null) {
      final HibikiDatabase db = appModel.database;
      _watchTracker = VideoWatchTracker(
        title: title,
        bookUid: widget.bookUid,
        // dateKey 由采集器决定（字幕字数=当下日期；观看时长=各桶各自日期），直接透传，
        // 不在此另算「今日」——否则跨午夜的 flush 会与小时日志的日归属不一致。
        addStat: (String t, String dateKey, int chars, int ms) => unawaited(
          db.addVideoWatchStatistic(
            title: t,
            dateKey: dateKey,
            subtitleChars: chars,
            watchTimeMs: ms,
          ),
        ),
        markCompleted: (String uid) =>
            db.markVideoCompleted(uid, DateTime.now()),
        addHourly: (String dateKey, int hour, int deltaMs) =>
            db.addVideoHourlyWatchTime(
                dateKey: dateKey, hour: hour, deltaMs: deltaMs),
      )
        ..attach(controller)
        ..start();
    }

    // 恢复用户选过的音轨（含多集换集复用）：audioTracks 在 player open 后才填充，
    // 延迟一拍再读，按 id 匹配；找不到（轨不存在/未选过）就跳过保留 libmpv 默认。
    unawaited(_restoreAudioTrack(controller));
  }

  /// 位置持久化（controller 每秒至多一次回调）。
  ///
  /// 播放列表：把进度记到**当前集**的 [PlaylistEntry.positionMs] 并回写整段
  /// playlistJson（每集各记自己的进度，换集互不干扰）。单视频：仍走
  /// VideoBook.lastPositionMs 不变。
  Future<void> _persistPosition(String uid, int posMs) async {
    if (_episodes.isEmpty) {
      await widget.repo.updatePosition(uid, posMs);
      return;
    }
    _episodes = updateEntryPosition(_episodes, _currentEpisode, posMs);
    await widget.repo.updatePlaylistJson(uid, _encodeEpisodes());
  }

  /// 把当前 [_episodes] 序列化回 playlistJson（带各集 positionMs）。
  String _encodeEpisodes() => jsonEncode(
        _episodes.map((PlaylistEntry e) => e.toJson()).toList(),
      );

  String _safeFileName(String input) =>
      input.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');

  /// 若有持久化音轨偏好 [_currentAudioTrackId]，在 [controller] 的 audioTracks 里
  /// 按 id 匹配并切换，恢复用户上次选的音轨（退出重进 / 换集复用）。
  ///
  /// audioTracks 在 libmpv `open` 后才**逐步**填充，时机随设备/首帧不定。旧实现固定
  /// 等 300ms 后**单次**匹配，列表此刻常仍为空 → 匹配不到、且不重试 → 用户报「音频
  /// 切换退出重进又得重新弄」。改为**有界轮询**：每 200ms 重试，最多 ~4s，直到列表里
  /// 出现目标轨再切；期间换片/卸载（`_controller != controller`）即放弃。
  Future<void> _restoreAudioTrack(VideoPlayerController controller) async {
    final String? wantId = _currentAudioTrackId;
    if (wantId == null || wantId.isEmpty) return;
    for (int attempt = 0; attempt < 20; attempt++) {
      if (!mounted || _controller != controller) return;
      for (final AudioTrack track in controller.audioTracks) {
        if (track.id == wantId) {
          await controller.selectAudioTrack(track);
          return;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  /// 选中某音轨：切轨 + 持久化 id（换集复用）+ SnackBar。
  Future<void> _selectAudioTrack(
    VideoPlayerController controller,
    AudioTrack track,
  ) async {
    await controller.selectAudioTrack(track);
    await widget.repo.updateAudioTrackId(widget.bookUid, track.id);
    if (!mounted) return;
    setState(() => _currentAudioTrackId = track.id);
    _showOsd(t.video_audio_track_switched(
      label: _trackLabel(track.title, track.language, track.id),
    ));
  }

  /// 切到第 [index] 集：保存当前集进度 → 持久化 currentEpisode → 用**目标集自己
  /// 保存的进度**作为起播位置（不再归零）+ 重新 load 新集字幕。
  ///
  /// 当前集进度由 125ms tick 经 [_persistPosition] 已实时记进 `_episodes[当前集]`
  /// 并落库；切集前再补记一次当前播放位置（覆盖 tick 整秒节流的尾差），确保下次
  /// 回到本集精确续播。
  Future<void> _switchEpisode(int index) async {
    if (index < 0 || index >= _episodes.length) return;
    if (index == _currentEpisode) return;

    // 切前补记当前集精确位置（tick 只整秒写，补这一下避免丢尾部几百 ms）。
    final int? curPos = _controller?.positionMs;
    if (curPos != null) {
      _episodes = updateEntryPosition(_episodes, _currentEpisode, curPos);
      await widget.repo.updatePlaylistJson(widget.bookUid, _encodeEpisodes());
    }

    await widget.repo.updateCurrentEpisode(widget.bookUid, index);
    // 换集：清空字幕去重集，新集字幕从头计（完成标记按整本书不变）。
    _watchTracker?.onEpisodeChanged();
    // 把上次选择的字幕偏好带进新集（同类应用：内嵌同轨 / 外挂同语言后缀）。
    await _loadEpisode(
      index,
      initialPositionMs: _episodes[index].positionMs,
      subtitleSource: _currentSubtitleSource,
    );
  }

  void _showEpisodeList() {
    if (_videoSheetOpen) return;
    _videoSheetOpen = true;
    // sheet 关闭后把键盘焦点还给 Video（覆盖层夺焦后不会自动归还）。
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.7,
          ),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: _episodes.length,
            itemBuilder: (BuildContext _, int i) {
              final bool selected = i == _currentEpisode;
              return ListTile(
                selected: selected,
                selectedColor: Theme.of(ctx).colorScheme.primary,
                leading: selected
                    ? const Icon(Icons.play_arrow)
                    : Text('${i + 1}',
                        style: TextStyle(
                            color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
                title: Text(
                  _episodes[i].title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _switchEpisode(i);
                },
              );
            },
          ),
        ),
      ),
    ).whenComplete(() {
      _videoSheetOpen = false;
      _refocusVideo();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // 先把根 Overlay 浮层 entry 摘除/释放，再 clear 浮层栈：entry 一旦移除就不会再被
    // 根 Overlay 重建 _buildPopupOverlay，杜绝销毁期用失效 State 重建浮层（退视频红屏）。
    final OverlayEntry? entry = _popupOverlayEntry;
    if (entry != null) {
      // remove() asserts if already detached（路由先 pop 时根 Overlay 可能已摘除）。
      if (entry.mounted) entry.remove();
      entry.dispose();
      _popupOverlayEntry = null;
    }
    _popup.clear();
    _watchTracker?.dispose();
    _watchTracker = null;
    _controller?.removeListener(_syncWindowAspectRatioLock);
    unawaited(_clearWindowAspectRatioLock());
    _controller?.dispose();
    _videoFocusNode.dispose();
    _titleNotifier.dispose();
    _osdTimer?.cancel();
    _osdNotifier.dispose();
    super.dispose();
  }

  /// 退出视频 / 退全屏的销毁期保护（BUG-121）。根 Overlay 的查词浮层 entry 跨路由生存，
  /// 比本 State 活得久；路由 pop 当帧本 State 先 `deactivate`，随后**同帧 layout 阶段**
  /// 根 Overlay 的 [LayoutBuilder] 仍会重建 entry → 内层经 `appModel`(ref.read) / `mixinTheme`
  /// (Theme.of) 做祖先查找，而 deactivated element 上的查找不安全 → 抛异常红屏。
  /// `OverlayEntry.remove()` 在 build/layout 阶段会延迟到 post-frame，摘除来不及拦本帧；
  /// 故置位此标志，让浮层 builder 在销毁期一律空渲染（[_buildPopupOverlay]）。
  bool _overlayInert = false;

  @override
  void deactivate() {
    _overlayInert = true;
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    // GlobalKey 重挂等重新激活场景：恢复正常渲染，下次 build 的 _syncPopupOverlay 重建浮层。
    _overlayInert = false;
  }

  /// 把键盘焦点还给 media_kit [Video]，恢复其内置快捷键（空格=播放/暂停等）。
  ///
  /// 在任何会盖在视频上 / 夺走窗口焦点的覆盖层（对话框、bottom sheet、系统文件选择器）
  /// 关闭后调用——这些覆盖层关闭后 Flutter 不会自动把焦点还给 [Video] 的 FocusNode，
  /// 导致空格等快捷键失灵（BUG：导入着色器后空格失灵）。统一在覆盖层的 `await` 返回点
  /// 调用即覆盖全部入口。查词浮层（[_popup]）**不**在此 refocus：浮层活动期间用户在
  /// 查词，不应让空格控制视频；浮层关闭由其自身路径处理。
  void _refocusVideo() {
    if (!mounted) return;
    // 仅当播放器已就绪（Video 已挂载）才请求焦点；否则节点未 attach，requestFocus 无意义。
    if (_controller == null) return;
    _videoFocusNode.requestFocus();
  }

  /// 点字幕第 [graphemeIndex] 个字符：暂停 → 从该位置起取词 → 推入与阅读器/词典页
  /// 同款的 [DictionaryPopupLayer] 浮层（定位到被点字符的屏幕 [charRect] 附近）。
  ///
  /// [charRect] 来自字符 box 的 `localToGlobal`，是 [HibikiAppUiScale] 缩放后的**真实
  /// 屏幕坐标**。浮层子树经 [_buildPopupOverlay] 的 [HibikiAppUiScaleNeutralizer] 中和回
  /// 真实视口空间（净变换=1），其坐标系即真实屏幕空间，故这里**直接**用 [charRect] 定位、
  /// 不再换算到缩放画布——界面任意缩放下定位都不偏（BUG-051）。
  ///
  /// 查词/递归查词/单词发音/auto-read/制卡全部走 [DictionaryPageMixin]，与书内一致。
  Future<void> _lookupAt(
    String sentence,
    int graphemeIndex,
    Rect charRect,
  ) async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    final Stopwatch swLookup = Stopwatch()..start();
    final String term = sentence.characters.skip(graphemeIndex).join();
    debugPrint('[video-lookup] tap idx=$graphemeIndex term="$term"');
    // 先判空再暂停：空词不弹浮层，不能暂停后无浮层可关→恢复路径永不触发（卡暂停）。
    if (term.isEmpty) return;
    // 仅当视频正在播放才暂停并标记，浮层全关后据此恢复（BUG-072）。查词前本就
    // 暂停 / 递归查词（已暂停）时 isPlaying==false，不暂停也不覆写标记。
    // 性能（弹窗弹出慢）：暂停是副作用，不该卡住弹窗推送。media_kit/libmpv 的
    // pause() 在桌面有 IPC 往返延迟，原先 `await` 把第一次查词的弹窗整整推迟一个
    // 暂停耗时。改为先置标记、fire-and-forget 暂停，弹窗立刻推。
    if (controller.isPlaying) {
      _pausedForLookup = true;
      unawaited(controller.pause());
    }
    _lastLookupSentence = sentence;
    _lastLookupCue = controller.currentCue;
    await pushNestedPopup(
      query: term,
      selectionRect: charRect,
      controller: _popup,
      replaceStack: true,
      reuseWarmSlot: true,
      autoRead: true,
    );
    debugPrint(
        '[video-lookup] popup ready in ${swLookup.elapsedMilliseconds}ms term="$term"');
  }

  /// 关闭查词浮层栈中第 [index] 层及其之上（点遮罩 / 返回 / 浮层滑动·Esc 都汇聚到此）。
  ///
  /// 关栈后若整栈已空且本次是因查词暂停了播放，则恢复播放——这是恢复播放的唯一汇聚点，
  /// 覆盖所有关闭路径（BUG-072）。
  /// True while any popup layer is actually visible (the persistent warm slot,
  /// BUG-094, sits hidden in the stack between lookups so it never counts).
  bool get _hasVisiblePopup => _popup.hasVisiblePopup;

  /// Index of the top-most visible popup layer, or -1 when only the hidden warm
  /// slot remains.
  int get _topVisiblePopupIndex => _popup.lastVisibleIndex;

  /// BUG-094: seed one persistent, hidden warm popup slot on open so its
  /// [DictionaryPopupWebView] cold-loads popup.html/JS/CSS ONCE while idle and
  /// is reused warm for every lookup — no per-lookup cold-load (white flash) in
  /// the video player. Low-memory mode keeps no warm slot (disposes on close).
  void _seedWarmPopup() {
    if (!mounted) return;
    // 成功路径调用，此刻 AppModel 必已初始化 → 安全读取真实 lowMemory 设入 controller
    // （seedWarmSlot/dismissAt 据此决定是否保留热槽）。
    _popup.lowMemory = appModel.lowMemoryMode;
    setState(() => _popup.seedWarmSlot());
    _syncPopupOverlay();
  }

  /// 查词浮层打开时，点根 Overlay 全屏 dismiss barrier 的处理：若点到了同句的另一个
  /// 字幕字符，则**切换查词**（对该字符走 [_lookupAt]：已暂停故不重复暂停、不清
  /// [_pausedForLookup]，`replaceStack` 替换可见浮层）→ 保持暂停、弹窗切到新词；否则
  /// 点的是空白/控件区，[_popNestedPopupAt] 关栈并据 [_pausedForLookup] 恢复播放。
  ///
  /// 根因（用户报）：barrier 全屏盖在字幕之上、抢走点击 → 点同句第二个词只会关栈+恢复
  /// 播放，查不了第二个词。barrier 先反查字幕字符命中即可「点词换词、保持暂停」。
  void _onDismissBarrierTap(Offset globalPos) {
    final SubtitleCharHit? hit = _subtitleHitTester.hitTest(globalPos);
    if (hit != null) {
      unawaited(_lookupAt(hit.sentence, hit.graphemeIndex, hit.charRect));
      return;
    }
    _popNestedPopupAt(0);
  }

  void _popNestedPopupAt(int index) {
    debugPrint('[video-lookup] dismiss popup index=$index '
        'visibleTop=$_topVisiblePopupIndex');
    // Hide-and-keep the warm slot instead of clearing it, so its loaded WebView
    // survives for the next lookup (BUG-094): closing index 0 hides the warm
    // slot + drops children; closing a child drops from there up.
    // controller.dismissAt 已实现「index 0 保留并隐藏热槽 / 否则裁该层及之上」；
    // 这里额外清掉热槽 WebView 的选区（原 UI 副作用）。
    if (index <= 0 &&
        _popup.entries.isNotEmpty &&
        _popup.entries.first.isWarmSlot) {
      _popup.entries.first.webViewKey.currentState?.clearSelection();
    }
    setState(() => _popup.dismissAt(index));
    if (VideoHibikiPage.shouldResumeAfterLookupDismiss(
      // "Effectively empty" = no visible popup; the hidden warm slot doesn't
      // block resume.
      stackEmpty: !_hasVisiblePopup,
      pausedForLookup: _pausedForLookup,
    )) {
      _pausedForLookup = false;
      unawaited(_controller?.play());
    }
  }

  Widget _buildNestedPopupLayer(int index, Size screen) {
    return buildNestedPopupLayer(
      index: index,
      screen: screen,
      controller: _popup,
      onPush: (String text, Rect rect) {
        // 递归查词不属于某条字幕句：制卡例句仍用最近一次字幕句。
        // [rect] 已是中和后浮层坐标（父浮层 pos + WebView 局部 rect 叠出，均在同一
        // 真实视口空间），直接复用，无需任何缩放换算。
        pushNestedPopup(
          query: text,
          selectionRect: rect,
          controller: _popup,
          autoRead: true,
        );
      },
      onPop: _popNestedPopupAt,
    );
  }

  /// 把查词浮层栈同步到根 Overlay：栈非空且未插入则插入、栈空则移除、否则
  /// `markNeedsBuild` 刷新。在 [build] 的 post-frame 调，使根 Overlay 总是反映
  /// 当前栈（[DictionaryPageMixin] 的 push/pop 都走 `setState` → 重 build → 本同步）。
  ///
  /// 用根 Overlay（而非本页 `Stack`）的原因：media_kit 全屏是推到根 navigator 的独立
  /// 路由，本页 `Stack` 会被全屏路由盖住；根 Overlay 浮在所有路由之上，窗口/全屏统一。
  void _syncPopupOverlay() {
    if (!mounted) return;
    if (_popup.entries.isEmpty) {
      final OverlayEntry? entry = _popupOverlayEntry;
      if (entry != null) {
        if (entry.mounted) entry.remove();
        entry.dispose();
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

  /// 根 Overlay 里的查词浮层栈内容：透明遮罩（点击关栈）+ 各层 [DictionaryPopupLayer]。
  ///
  /// 根 Overlay 在 [HibikiAppUiScale] 的 `FittedBox` 之内＝缩放后的小画布，浮层 WebView
  /// 在此栅格化再被拉大会字糊（BUG-051）。用 [HibikiAppUiScaleNeutralizer] 把整棵浮层
  /// 子树中和回真实视口尺寸、净缩放=1，WebView 按原生密度渲染＝清晰。中和后 `screen`
  /// （内层 [LayoutBuilder] 约束）即真实视口，与 [_lookupAt] 直接传入的 `localToGlobal`
  /// 屏幕 rect 同坐标系（净变换=1），定位自洽。
  Widget _buildPopupOverlay(BuildContext overlayContext) {
    // 这个 entry 插在根 Overlay（跨路由生存，比本页 State 活得久）。退出视频 / 退全屏
    // 时根 Overlay 可能在本 State 已 deactivate/dispose 之后重建此 entry——彼时再读
    // State 的 `context` / `appModel`(ref.read) 会抛异常 → Flutter ErrorWidget 红屏
    // （用户报「退视频红屏」）。故：State 失效就不渲染浮层；Theme 也改用 entry 自己的
    // `overlayContext`（与本 entry 同寿命）而非借用更短命的 State `context`。
    if (!mounted || _overlayInert) return const SizedBox.shrink();
    return HibikiAppUiScaleNeutralizer(
      child: Theme(
        data: appModel.overrideDictionaryTheme ?? Theme.of(overlayContext),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            // LayoutBuilder 的 builder 在 layout 阶段运行，可能晚于本 State 的 deactivate
            // （退视频/退全屏同帧）；此刻读 appModel(ref.read)/mixinTheme 会做失效祖先查找
            // 抛异常红屏（BUG-121）。销毁期标志置位则空渲染兜底。
            if (!mounted || _overlayInert) return const SizedBox.shrink();
            final Size screen =
                Size(constraints.maxWidth, constraints.maxHeight);
            return Stack(
              // BUG-135: 隐藏热槽被停到屏幕右外侧（buildNestedPopupLayer），默认
              // Clip.hardEdge 会把它裁掉 → 原生 WebView 可能不再渲染、丢失预热。用
              // Clip.none 让它在屏外照常栅格化保持温热（不盖任何控件）。
              clipBehavior: Clip.none,
              children: <Widget>[
                // Dismiss barrier while a popup is visible OR a lookup is
                // searching (搜索→就绪才显示：搜索期浮层还没显示，barrier 仍要拦点击
                // 并支持点同句另一字切换查词)。仅剩隐藏热槽时不拦，放行给视频。
                if (_hasVisiblePopup || _popup.isSearchingUi)
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      // onTapUp（带坐标）而非 onTap：点到同句另一个字幕字符时切换查词
                      // 并保持暂停，点其它区域才 dismiss + 恢复（见 _onDismissBarrierTap）。
                      onTapUp: (TapUpDetails d) =>
                          _onDismissBarrierTap(d.globalPosition),
                      child: const ColoredBox(color: Colors.transparent),
                    ),
                  ),
                // 搜索期加载占位卡（与书内同观感：就绪才显示真正浮层）。
                if (_popup.isSearchingUi && _popup.pendingRect != null)
                  buildPopupLoadingPlaceholder(
                    rect: _popup.pendingRect!,
                    screen: screen,
                  ),
                for (int i = 0; i < _popup.entries.length; i++)
                  _buildNestedPopupLayer(i, screen),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 制卡（覆写 [DictionaryPageMixin.onMineEntry]）：在词典 [fields]（已含单词
  /// 发音 `{audio}`、例句字段等）基础上，注入视频专属上下文——当前帧截图
  /// coverPath（→`{book-cover}`）+ 当前字幕 cue 的音频片段（裁**当前选中音轨**）
  /// sasayakiAudioPath（→`{sasayaki-audio}`）+ 例句 sentence。复用现有 Anki 字段。
  @override
  Future<bool> onMineEntry(Map<String, String> fields) async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return false;
    final BaseAnkiRepository repo = ref.read(ankiRepositoryProvider);
    final Directory tmp = await getTemporaryDirectory();

    final AudioCue? cue = _lastLookupCue ?? controller.currentCue;
    final String? videoPath = controller.videoPath;

    // 视频卡片封面 → coverPath（→`{book-cover}`）：优先把**当前 cue 时间段**导出成
    // 循环 GIF（用户要的「cue 时间段的动图」，比制卡瞬间的随机暂停帧更贴所学这句）。
    // 桌面走系统 ffmpeg、移动端走捆绑 ffmpeg-kit（resolveFfmpegBackend）；无 cue /
    // 导出失败（ffmpeg 真不可用等）时回退当前帧截图。
    String? coverPath;
    if (cue != null && videoPath != null && cue.endMs > cue.startMs) {
      coverPath = await extractClipGifViaFfmpeg(
        inputPath: videoPath,
        startMs: cue.startMs,
        endMs: cue.endMs,
        outputPath: '${tmp.path}/video_mine_clip.gif',
      );
    }
    if (coverPath == null) {
      final Uint8List? shot = await controller.screenshot();
      if (shot != null && shot.isNotEmpty) {
        final File f = File('${tmp.path}/video_mine_shot.jpg');
        await f.writeAsBytes(shot);
        coverPath = f.path;
      }
    }

    // 当前字幕 cue 的音频片段（桌面 ffmpeg 按时间裁，映射到当前选中音轨）
    // → sasayakiAudioPath。
    String? audioPath;
    if (cue != null && videoPath != null) {
      audioPath = await extractAudioSegmentViaFfmpeg(
        inputPath: videoPath,
        startMs: cue.startMs,
        endMs: cue.endMs,
        outputPath: '${tmp.path}/video_mine_audio.aac',
        audioStreamIndex: controller.currentAudioStreamIndex,
      );
    }

    final AnkiMiningContext miningContext = AnkiMiningContext(
      sentence: _lastLookupSentence,
      cueSentence: cue?.text,
      documentTitle: _title,
      coverPath: coverPath,
      sasayakiAudioPath: audioPath,
    );
    final MineOutcome outcome = await repo.mineEntry(
      rawPayloadJson: jsonEncode(fields),
      context: miningContext,
    );
    if (!context.mounted) return outcome.result == MineResult.success;
    final String message;
    switch (outcome.result) {
      case MineResult.success:
        final AnkiSettings settings = await repo.loadSettings();
        message = t.card_exported(deck: settings.selectedDeckName ?? '');
      case MineResult.duplicate:
        message = t.card_duplicate;
      case MineResult.notConfigured:
        message = t.card_export_not_configured;
      case MineResult.error:
        message = logMineFailure(outcome);
    }
    _showOsd(message);
    return outcome.result == MineResult.success;
  }

  /// 弹音轨菜单（顶栏 ♪ 按钮共用）。
  void _showAudioTrackMenu(VideoPlayerController controller) {
    _showTrackMenu(
      controller.audioTracks
          .map((AudioTrack tr) => (
                label: _trackLabel(tr.title, tr.language, tr.id),
                onSelected: () => _selectAudioTrack(controller, tr),
              ))
          .toList(),
    );
  }

  /// 退出/返回汇聚点：浮层栈有可见层先关栈（一层层退），否则 await 落库后真正
  /// pop 路由。[PopScope] 与 Escape 快捷键共用，保证两条退出路径行为一致。
  ///
  /// 只有 VISIBLE 浮层拦截 back；常驻隐藏的热槽（BUG-094）让栈非空但不得吞掉退出。
  Future<void> _handleBackOrExit() async {
    if (_hasVisiblePopup) {
      _popNestedPopupAt(_topVisiblePopupIndex);
      return;
    }
    final NavigatorState nav = Navigator.of(context);
    await _controller?.flushPosition();
    if (mounted) nav.pop();
  }

  /// 桌面键盘快捷键，整表覆盖 media_kit 默认（[MaterialDesktopVideoControlsThemeData.
  /// keyboardShortcuts] 是整表替换、无合并）。覆盖动机：
  /// ① 默认 Escape 只 `exitFullscreen`，非全屏时是空操作 → 用户按 Esc 退不出视频页
  ///    （本页 [PopScope] 自管退出，但收不到事件：media_kit 的 CallbackShortcuts 在
  ///    本页外层 CallbackShortcuts 的内层，先吞掉 Escape）。改为非全屏退页、全屏退
  ///    全屏。
  /// ② 默认左右方向键是 ±2 秒 seek，用户要「上下句字幕」（无 cue 时回退 asbplayer 3 秒）。
  /// 其余键（空格/媒体键/J·I/F）按 media_kit 默认语义用底层 [Player] 重建，避免
  /// 覆盖后丢默认行为。全屏相关 helper 需 controls 子树内 context，用 [_videoControlsContext]。
  Map<ShortcutActivator, VoidCallback> _videoKeyboardShortcuts(
    VideoPlayerController controller,
  ) {
    return buildVideoPlayerShortcuts(
      VideoPlayerShortcutActions(
        togglePlayPause: () => unawaited(controller.playOrPause()),
        play: () => unawaited(controller.play()),
        pause: () => unawaited(controller.pause()),
        // 左右方向键 = 上下句字幕（无字幕 cue 时回退 asbplayer 默认 ±3 秒 seek）。
        previousSubtitle: () => unawaited(
          controller.cues.isEmpty
              ? controller.seekRelative(-_asbSeekMs)
              : controller.skipToPrevCue(),
        ),
        nextSubtitle: () => unawaited(
          controller.cues.isEmpty
              ? controller.seekRelative(_asbSeekMs)
              : controller.skipToNextCue(),
        ),
        seekBackward: () => unawaited(controller.seekRelative(-_asbSeekMs)),
        seekForward: () => unawaited(controller.seekRelative(_asbSeekMs)),
        toggleShaderCompare: () => unawaited(_toggleShaderCompare()),
        volumeUp: () => unawaited(_adjustVolume(_volumeStep)),
        volumeDown: () => unawaited(_adjustVolume(-_volumeStep)),
        toggleMute: () => unawaited(_toggleMute()),
        speedUp: () => unawaited(_adjustSpeed(_speedStep)),
        speedDown: () => unawaited(_adjustSpeed(-_speedStep)),
        resetSpeed: () => unawaited(_setSpeed(1.0)),
        previousFrame: () => unawaited(controller.frameStep(forward: false)),
        nextFrame: () => unawaited(controller.frameStep(forward: true)),
        screenshot: () => unawaited(_saveScreenshot()),
        toggleFullscreen: () {
          final BuildContext? ctx = _videoControlsContext;
          if (ctx != null && ctx.mounted) {
            unawaited(_toggleVideoFullscreen(ctx));
          }
        },
        escape: () {
          final BuildContext? ctx = _videoControlsContext;
          if (ctx != null && ctx.mounted && isFullscreen(ctx)) {
            unawaited(_exitVideoFullscreen(ctx));
          } else {
            unawaited(_handleBackOrExit());
          }
        },
      ),
    );
  }

  /// media_kit 桌面控制主题。底部胶囊条改成居中传输组
  /// `[−10s][上一句][暂停][下一句][+10s]`（清空中央 primaryButtonBar 避免重复），
  /// 左端进度、右端全屏；顶栏右侧放 截图/字幕/音轨/倍速/设置 图标（参照截图）。
  /// 上/下一句走 cue 导航（[VideoPlayerController.skipToPrevCue]/[skipToNextCue]）。
  Future<void> _toggleVideoFullscreen(BuildContext context) {
    return isFullscreen(context)
        ? _exitVideoFullscreen(context)
        : _pushNeutralizedVideoFullscreen(context);
  }

  Future<void> _pushNeutralizedVideoFullscreen(BuildContext context) async {
    if (_videoFullscreenTransitioning || isFullscreen(context)) return;
    if (!context.mounted) return;
    _videoFullscreenTransitioning = true;
    final VideoStateInheritedWidget inherited =
        VideoStateInheritedWidget.of(context);
    final VideoState stateValue = inherited.state;
    final contextNotifierValue = inherited.contextNotifier;
    final videoViewParametersNotifierValue =
        inherited.videoViewParametersNotifier;
    final VideoController controllerValue = stateValue.widget.controller;
    final Future<void> Function() enterNativeFullscreen =
        stateValue.widget.onEnterFullscreen;
    final Future<void> Function() exitNativeFullscreen =
        stateValue.widget.onExitFullscreen;
    final MaterialVideoControlsTheme? mobileTheme =
        MaterialVideoControlsTheme.maybeOf(context);
    final MaterialDesktopVideoControlsTheme? desktopTheme =
        MaterialDesktopVideoControlsTheme.maybeOf(context);

    try {
      Navigator.of(context, rootNavigator: true).push<void>(
        PageRouteBuilder<void>(
          pageBuilder: (_, __, ___) => Material(
            child: HibikiAppUiScaleNeutralizer(
              child: MaterialVideoControlsTheme(
                normal: mobileTheme?.normal ??
                    kDefaultMaterialVideoControlsThemeData,
                fullscreen: mobileTheme?.fullscreen ??
                    kDefaultMaterialVideoControlsThemeDataFullscreen,
                child: MaterialDesktopVideoControlsTheme(
                  normal: desktopTheme?.normal ??
                      kDefaultMaterialDesktopVideoControlsThemeData,
                  fullscreen: desktopTheme?.fullscreen ??
                      kDefaultMaterialDesktopVideoControlsThemeDataFullscreen,
                  child: VideoStateInheritedWidget(
                    state: stateValue,
                    contextNotifier: contextNotifierValue,
                    videoViewParametersNotifier:
                        videoViewParametersNotifierValue,
                    disposeNotifiers: false,
                    child: FullscreenInheritedWidget(
                      parent: stateValue,
                      child: VideoStateInheritedWidget(
                        state: stateValue,
                        contextNotifier: contextNotifierValue,
                        videoViewParametersNotifier:
                            videoViewParametersNotifierValue,
                        disposeNotifiers: false,
                        child: ValueListenableBuilder<VideoViewParameters>(
                          valueListenable: videoViewParametersNotifierValue,
                          builder: (
                            BuildContext _,
                            VideoViewParameters params,
                            __,
                          ) {
                            return Video(
                              controller: controllerValue,
                              width: null,
                              height: null,
                              fit: params.fit,
                              fill: params.fill,
                              alignment: params.alignment,
                              aspectRatio: params.aspectRatio,
                              filterQuality: params.filterQuality,
                              controls: params.controls,
                              wakelock: false,
                              subtitleViewConfiguration:
                                  params.subtitleViewConfiguration,
                              focusNode: params.focusNode,
                              onEnterFullscreen: enterNativeFullscreen,
                              onExitFullscreen: exitNativeFullscreen,
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
        ),
      );
      await enterNativeFullscreen();
    } finally {
      _videoFullscreenTransitioning = false;
      if (mounted) _refocusVideo();
    }
  }

  Future<void> _exitVideoFullscreen(BuildContext context) async {
    if (_videoFullscreenTransitioning || !isFullscreen(context)) return;
    if (!context.mounted) return;
    _videoFullscreenTransitioning = true;
    try {
      await Navigator.of(context).maybePop();
      if (context.mounted) {
        FullscreenInheritedWidget.of(context).parent.refreshView();
      }
    } finally {
      _videoFullscreenTransitioning = false;
      if (mounted) _refocusVideo();
    }
  }

  Widget _buildFullscreenButton({required bool desktop}) {
    return Builder(
      builder: (BuildContext buttonContext) {
        final Widget icon = Icon(
          isFullscreen(buttonContext)
              ? Icons.fullscreen_exit
              : Icons.fullscreen,
          size: _videoControlIconSize,
        );
        return desktop
            ? MaterialDesktopCustomButton(
                icon: icon,
                onPressed: () =>
                    unawaited(_toggleVideoFullscreen(buttonContext)),
              )
            : MaterialCustomButton(
                icon: icon,
                onPressed: () =>
                    unawaited(_toggleVideoFullscreen(buttonContext)),
              );
      },
    );
  }

  Widget _buildVolumeButton(
    VideoPlayerController controller, {
    required bool desktop,
  }) {
    if (desktop) {
      return const MaterialDesktopVolumeButton(
        iconSize: _videoControlIconSize,
      );
    }
    return MaterialCustomButton(
      icon:
          Icon(_volumeIconFor(controller.volume), size: _videoControlIconSize),
      onPressed: () => _showVolumeMenu(controller),
    );
  }

  MaterialDesktopVideoControlsThemeData _desktopControlsTheme(
    VideoPlayerController controller,
  ) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool roomyBottomBar = _hasRoomyVideoBottomBar();
    return MaterialDesktopVideoControlsThemeData(
      // 控制条 3s 后自动隐藏时一并隐藏鼠标光标（默认 false 会让光标常驻，BUG-106）。
      hideMouseOnControlsRemoval: true,
      // 单击画面 = 播放/暂停（media_kit 桌面默认 false，故此前点画面毫无反应，
      // BUG-130）。字幕字符点击在更上层 [VideoSubtitleOverlay] 的 opaque GestureDetector
      // 独立处理、不会冒泡到这里，故启用后点字幕仍是查词、点空白区才暂停，不冲突。
      playAndPauseOnTap: true,
      toggleFullscreenOnDoublePress: false,
      seekBarPositionColor: cs.primary,
      seekBarThumbColor: cs.primary,
      buttonBarButtonColor: cs.primary,
      buttonBarHeight: _videoButtonBarHeight,
      buttonBarButtonSize: _videoControlIconSize,
      keyboardShortcuts: _videoKeyboardShortcuts(controller),
      primaryButtonBar: const <Widget>[],
      // 视频内顶栏（替代被删的 Scaffold AppBar，BUG-102）：左侧返回 + 标题，右侧
      // 剧集导航（playlist）+ 截图/字幕/音轨/倍速/设置。
      topButtonBar: <Widget>[
        MaterialDesktopCustomButton(
          icon: const Icon(Icons.arrow_back, size: _videoControlIconSize),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        Expanded(
          // 标题走 ValueListenableBuilder（BUG-120）：全屏路由不随页面 setState 重建，
          // 监听 _titleNotifier 才能在全屏换集后刷新标题。
          child: ValueListenableBuilder<String?>(
            valueListenable: _titleNotifier,
            builder: (BuildContext _, String? title, __) => Text(
              title ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _videoControlTitleStyle(_videoChromeColorScheme(context)),
            ),
          ),
        ),
        if (_isPlaylist) ...<Widget>[
          MaterialDesktopCustomButton(
            icon: const Icon(Icons.skip_previous, size: _videoControlIconSize),
            onPressed: () {
              if (_currentEpisode > 0) _switchEpisode(_currentEpisode - 1);
            },
          ),
          MaterialDesktopCustomButton(
            icon: const Icon(Icons.skip_next, size: _videoControlIconSize),
            onPressed: () {
              if (_currentEpisode < _episodes.length - 1) {
                _switchEpisode(_currentEpisode + 1);
              }
            },
          ),
          MaterialDesktopCustomButton(
            icon: const Icon(Icons.playlist_play, size: _videoControlIconSize),
            onPressed: _showEpisodeList,
          ),
        ],
        MaterialDesktopCustomButton(
          icon: const Icon(
            Icons.photo_camera_outlined,
            size: _videoControlIconSize,
          ),
          onPressed: _saveScreenshot,
        ),
        MaterialDesktopCustomButton(
          icon: const Icon(Icons.subtitles, size: _videoControlIconSize),
          onPressed: () => _showSubtitleSourceMenu(controller),
        ),
        MaterialDesktopCustomButton(
          icon: const Icon(Icons.audiotrack, size: _videoControlIconSize),
          onPressed: () => _showAudioTrackMenu(controller),
        ),
        MaterialDesktopCustomButton(
          icon: const Icon(Icons.speed, size: _videoControlIconSize),
          onPressed: _showSpeedMenu,
        ),
        // 着色器「对比原画」：仅在配置了启用着色器时出现，点一下/按 C 切换旁路看原画
        // （B：效果预览/对比）。着色器仅桌面 libmpv 生效，故只在桌面控制条放此按钮。
        if (_hasShadersEnabled)
          MaterialDesktopCustomButton(
            icon: const Icon(Icons.compare, size: _videoControlIconSize),
            onPressed: _toggleShaderCompare,
          ),
        MaterialDesktopCustomButton(
          icon: const Icon(Icons.tune, size: _videoControlIconSize),
          onPressed: _showPlayerSettings,
        ),
      ],
      bottomButtonBar: <Widget>[
        const MaterialDesktopPositionIndicator(),
        const Spacer(),
        if (roomyBottomBar)
          MaterialDesktopCustomButton(
            icon: const Icon(Icons.replay_10, size: _videoControlIconSize),
            onPressed: () => _seekRelative(-10000),
          ),
        MaterialDesktopCustomButton(
          icon: const Icon(Icons.skip_previous, size: _videoControlIconSize),
          onPressed: () => controller.skipToPrevCue(),
        ),
        const MaterialDesktopPlayOrPauseButton(
          iconSize: _videoPlayPauseIconSize,
        ),
        MaterialDesktopCustomButton(
          icon: const Icon(Icons.skip_next, size: _videoControlIconSize),
          onPressed: () => controller.skipToNextCue(),
        ),
        if (roomyBottomBar)
          MaterialDesktopCustomButton(
            icon: const Icon(Icons.forward_10, size: _videoControlIconSize),
            onPressed: () => _seekRelative(10000),
          ),
        const Spacer(),
        _buildVolumeButton(controller, desktop: true),
        _buildFullscreenButton(desktop: true),
      ],
    );
  }

  /// media_kit 移动控制主题（Android/iOS）：[AdaptiveVideoControls] 在移动端渲染
  /// [MaterialVideoControls]（读本主题），桌面端渲染 [MaterialDesktopVideoControls]
  /// （读 [MaterialDesktopVideoControlsTheme]），两套互斥，故两层主题都配置安全。
  ///
  /// 手机控制条：顶栏直接暴露截图、字幕、音轨、设置等常用入口，不再依赖右上角「⋮」
  /// 小目标；底栏窄屏时隐藏 10 秒跳转，宽屏/横屏/平板仍保留。
  MaterialVideoControlsThemeData _mobileControlsTheme(
    VideoPlayerController controller,
  ) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool roomyBottomBar = _hasRoomyVideoBottomBar();
    return MaterialVideoControlsThemeData(
      seekBarPositionColor: cs.primary,
      seekBarThumbColor: cs.primary,
      buttonBarButtonColor: cs.primary,
      buttonBarHeight: _videoButtonBarHeight,
      buttonBarButtonSize: _videoControlIconSize,
      primaryButtonBar: const <Widget>[],
      // 视频内顶栏（替代被删的 Scaffold AppBar，BUG-102）：左侧返回 + 标题，
      // 右侧只放手机上最常用且需要直接命中的入口。倍速仍可从设置进入。
      topButtonBar: <Widget>[
        MaterialCustomButton(
          icon: const Icon(Icons.arrow_back, size: _videoControlIconSize),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        Expanded(
          // 标题走 ValueListenableBuilder（BUG-120）：全屏路由不随页面 setState 重建，
          // 监听 _titleNotifier 才能在全屏换集后刷新标题。
          child: ValueListenableBuilder<String?>(
            valueListenable: _titleNotifier,
            builder: (BuildContext _, String? title, __) => Text(
              title ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _videoControlTitleStyle(_videoChromeColorScheme(context)),
            ),
          ),
        ),
        // 剧集列表（播放列表时）两端常驻。
        if (_isPlaylist)
          MaterialCustomButton(
            icon: const Icon(Icons.playlist_play, size: _videoControlIconSize),
            onPressed: _showEpisodeList,
          ),
        MaterialCustomButton(
          icon: const Icon(
            Icons.photo_camera_outlined,
            size: _videoControlIconSize,
          ),
          onPressed: _saveScreenshot,
        ),
        MaterialCustomButton(
          icon: const Icon(Icons.subtitles, size: _videoControlIconSize),
          onPressed: () => _showSubtitleSourceMenu(controller),
        ),
        MaterialCustomButton(
          icon: const Icon(Icons.audiotrack, size: _videoControlIconSize),
          onPressed: () => _showAudioTrackMenu(controller),
        ),
        MaterialCustomButton(
          icon: const Icon(Icons.tune, size: _videoControlIconSize),
          onPressed: _showPlayerSettings,
        ),
      ],
      bottomButtonBar: <Widget>[
        const MaterialPositionIndicator(),
        const Spacer(),
        if (roomyBottomBar)
          MaterialCustomButton(
            icon: const Icon(Icons.replay_10, size: _videoControlIconSize),
            onPressed: () => _seekRelative(-10000),
          ),
        MaterialCustomButton(
          icon: const Icon(Icons.skip_previous, size: _videoControlIconSize),
          onPressed: () => controller.skipToPrevCue(),
        ),
        const MaterialPlayOrPauseButton(iconSize: _videoPlayPauseIconSize),
        MaterialCustomButton(
          icon: const Icon(Icons.skip_next, size: _videoControlIconSize),
          onPressed: () => controller.skipToNextCue(),
        ),
        if (roomyBottomBar)
          MaterialCustomButton(
            icon: const Icon(Icons.forward_10, size: _videoControlIconSize),
            onPressed: () => _seekRelative(10000),
          ),
        const Spacer(),
        _buildVolumeButton(controller, desktop: false),
        _buildFullscreenButton(desktop: false),
      ],
    );
  }

  bool _hasRoomyVideoBottomBar() => MediaQuery.of(context).size.width >= 600;

  void _showTrackMenu(
    List<({String label, VoidCallback onSelected})> tracks,
  ) {
    if (_videoSheetOpen) return;
    _videoSheetOpen = true;
    // sheet 关闭后把键盘焦点还给 Video（覆盖层夺焦后不会自动归还）。
    showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext ctx) => ListView(
        shrinkWrap: true,
        children: tracks
            .map((({String label, VoidCallback onSelected}) o) => ListTile(
                  title: Text(o.label),
                  onTap: () {
                    o.onSelected();
                    Navigator.pop(ctx);
                  },
                ))
            .toList(),
      ),
    ).whenComplete(() {
      _videoSheetOpen = false;
      _refocusVideo();
    });
  }

  /// 设置音画延迟（毫秒）：即时调 controller（字幕 cue 同步偏移立即生效）+ 持久化
  /// 到 VideoBook.delayMs（换集复用、跨重启保留）+ 刷新面板显示。
  Future<void> _setDelayMs(int delayMs) async {
    final int clamped = delayMs.clamp(-600000, 600000);
    if (clamped == _delayMs) return;
    _delayMs = clamped;
    _controller?.setDelayMs(clamped);
    await widget.repo.updateDelayMs(widget.bookUid, clamped);
    if (mounted) setState(() {});
  }

  Future<void> _adjustSubtitleOffset(int deltaMs) async {
    assert(_subtitleOffsetStepMs > 0);
    await _setDelayMs(_delayMs + deltaMs);
  }

  void _showVolumeMenu(VideoPlayerController controller) {
    if (_videoSheetOpen) return;
    _videoSheetOpen = true;
    double volume = controller.volume.clamp(0.0, 100.0).toDouble();
    showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext ctx) {
        return StatefulBuilder(
          builder: (
            BuildContext ctx,
            StateSetter setModalState,
          ) {
            void setVolume(double value) {
              final double next = value.clamp(0.0, 100.0).toDouble();
              setModalState(() => volume = next);
              unawaited(controller.setVolume(next));
              if (mounted) _showVolumeOsd(next);
            }

            return SafeArea(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: Row(
                  children: <Widget>[
                    IconButton(
                      icon: Icon(_volumeIconFor(0)),
                      onPressed: () => setVolume(0),
                    ),
                    Expanded(
                      child: Slider(
                        value: volume,
                        min: 0,
                        max: 100,
                        divisions: 20,
                        onChanged: setVolume,
                      ),
                    ),
                    SizedBox(
                      width: 48,
                      child: Text(
                        '${volume.round()}%',
                        textAlign: TextAlign.end,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ).whenComplete(() {
      _videoSheetOpen = false;
      _refocusVideo();
    });
  }

  Future<void> _adjustVolume(double delta) async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    final double next = (controller.volume + delta).clamp(0.0, 100.0);
    await controller.setVolume(next);
    if (mounted) _showVolumeOsd(next);
  }

  Future<void> _toggleMute() async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    final bool muted = await controller.toggleMute();
    if (mounted) {
      _showVolumeOsd(muted ? 0 : controller.volume);
    }
  }

  void _showVolumeOsd(double volume) {
    final double clamped = volume.clamp(0.0, 100.0).toDouble();
    _showOsd(
      '${t.audio_volume}: ${clamped.round()}%',
      icon: _volumeIconFor(clamped),
      progress: clamped / 100.0,
    );
  }

  /// 设置播放倍速：即时调 controller + 持久化到 per-book 偏好（速度记忆）+ 刷新。
  Future<void> _setSpeed(double speed) async {
    final double clamped = speed.clamp(0.25, 4.0).toDouble();
    if ((clamped - _playbackSpeed).abs() < 0.001) return;
    _playbackSpeed = clamped;
    await _controller?.setSpeed(clamped);
    await appModel.prefsRepo.setPref(_speedPrefKey, clamped);
    if (mounted) setState(() {});
  }

  Future<void> _adjustSpeed(double delta) async {
    final double next = ((_playbackSpeed + delta) * 10).round() / 10;
    await _setSpeed(next);
  }

  Future<void> _setLockWindowAspectRatio(bool value) async {
    if (_lockWindowAspectRatio == value) return;
    _lockWindowAspectRatio = value;
    await appModel.setVideoLockWindowAspectRatio(value);
    await _syncWindowAspectRatioLock();
    if (mounted) setState(() {});
  }

  Future<void> _clearWindowAspectRatioLock() async {
    if (!isDesktopPlatform || _appliedWindowAspectRatio == null) return;
    _appliedWindowAspectRatio = null;
    try {
      await windowManager.setAspectRatio(0);
    } catch (e, stack) {
      ErrorLogService.instance.log('VideoHibiki.windowAspect.clear', e, stack);
    }
  }

  Future<void> _setAsbConfig(VideoAsbplayerConfig config) async {
    _asbConfig = config;
    _controller?.setPauseAtSubtitleEnd(config.pauseAtSubtitleEnd);
    await appModel.setVideoAsbplayerConfig(VideoAsbplayerConfig.encode(config));
    if (mounted) setState(() {});
  }

  Future<void> _syncWindowAspectRatioLock() async {
    if (!isDesktopPlatform) return;
    final VideoPlayerController? controller = _controller;
    if (!_lockWindowAspectRatio || controller == null) {
      await _clearWindowAspectRatioLock();
      return;
    }
    final int? width = controller.videoWidth;
    final int? height = controller.videoHeight;
    if (width == null || height == null || width <= 0 || height <= 0) return;
    final double aspectRatio = width / height;
    if (_appliedWindowAspectRatio != null &&
        (_appliedWindowAspectRatio! - aspectRatio).abs() < 0.0001) {
      return;
    }
    _appliedWindowAspectRatio = aspectRatio;
    try {
      await windowManager.setAspectRatio(aspectRatio);
    } catch (e, stack) {
      ErrorLogService.instance.log('VideoHibiki.windowAspect.set', e, stack);
    }
  }

  /// 持久化字幕外观并刷新 overlay（纯 Flutter overlay，不碰 mpv）。
  Future<void> _persistSubtitleStyle(VideoSubtitleStyle style) async {
    _subtitleStyle = style;
    await appModel.setVideoSubtitleStyle(VideoSubtitleStyle.encode(style));
    if (mounted) setState(() {});
  }

  /// 切换字幕模糊（'B' 热键 + 设置面板共用）。
  Future<void> _toggleSubtitleBlur() async {
    await appModel.setVideoSubtitleBlur(!appModel.videoSubtitleBlur);
    if (mounted) setState(() {});
  }

  /// 当前是否配置了启用着色器（决定是否显示「对比原画」按钮/快捷键的语义）。
  bool get _hasShadersEnabled =>
      decodeEnabledShaders(appModel.videoShadersEnabled).isNotEmpty;

  /// 着色器「对比原画」：切换旁路态（临时关掉着色器看原画，再切回），保留启用集。
  /// B：缺效果预览/对比——桌面控制条对比按钮 + `C` 快捷键都走这里，OSD 提示当前态。
  Future<void> _toggleShaderCompare() async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    final bool bypassed = await controller.toggleShaderBypass();
    if (!mounted) return;
    _showOsd(bypassed
        ? t.video_shader_showing_original
        : t.video_shader_showing_shaded);
  }

  /// 相对当前位置 seek（±[deltaMs]，底部胶囊条 / 快捷键共用）。
  Future<void> _seekRelative(int deltaMs) async {
    await _controller?.seekRelative(deltaMs);
  }

  /// 截当前帧存为图片：桌面弹保存对话框，移动端走系统分享（参照 log_exporter
  /// 的平台分流）。复用 [VideoPlayerController.screenshot]（制卡同源，JPEG）。
  Future<void> _saveScreenshot() async {
    final Uint8List? bytes = await _controller?.screenshot();
    if (bytes == null) {
      _showOsd(t.video_screenshot_failed);
      return;
    }
    final String name =
        'hibiki_${p.basenameWithoutExtension(_currentVideoPath ?? 'video')}.jpg';
    File? tmp;
    final bool isDesktop =
        Platform.isWindows || Platform.isMacOS || Platform.isLinux;
    try {
      final Directory tmpDir = await getTemporaryDirectory();
      tmp = File(p.join(tmpDir.path, name));
      await tmp.writeAsBytes(bytes);
      if (isDesktop) {
        final String? savePath = await FilePicker.platform.saveFile(
          dialogTitle: t.video_screenshot,
          fileName: name,
          type: FileType.custom,
          allowedExtensions: <String>['jpg'],
        );
        if (savePath != null) {
          await tmp.copy(savePath);
          _showOsd(t.video_screenshot_saved);
        }
      } else {
        await Share.shareXFiles(
          <XFile>[XFile(tmp.path, mimeType: 'image/jpeg')],
          subject: name,
        );
      }
    } catch (_) {
      _showOsd(t.video_screenshot_failed);
    } finally {
      // 桌面端清理临时文件；移动端分享需保留供系统面板异步读取。
      if (isDesktop && tmp != null) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
      _refocusVideo();
    }
  }

  /// 弹快捷倍速选择（底部小 sheet，复用 [_setSpeed] 与设置面板同档位）。
  void _showSpeedMenu() {
    if (_videoSheetOpen) return;
    _videoSheetOpen = true;
    final List<double> speedPresets = _speedMenuPresets();
    showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final double s in speedPresets)
              ListTile(
                dense: true,
                title: Text('${s}x'),
                trailing: (s - _playbackSpeed).abs() < 0.001
                    ? Icon(Icons.check,
                        color: Theme.of(ctx).colorScheme.primary)
                    : null,
                onTap: () {
                  _setSpeed(s);
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      ),
    ).whenComplete(() {
      _videoSheetOpen = false;
      _refocusVideo();
    });
  }

  List<double> _speedMenuPresets() {
    final Set<double> values = <double>{};
    for (double speed = 0.5; speed <= 2.0001; speed += _speedStep) {
      values.add(double.parse(speed.toStringAsFixed(2)));
    }
    values.add(1.0);
    return values.toList()..sort();
  }

  /// 弹视频播放设置面板：与阅读器同款 master-detail（宽窗左分类固定 + 右详情独立
  /// 滚动，窄窗降级单列 push）。桌面经 [HibikiDialogFrame]（maxWidth 900）进入分栏，
  /// 移动端走 bottom sheet。所有项都不是 schema 项，经回调即时生效 + 持久化 + 实时
  /// 预览（见 [_setDelayMs] / [_setSpeed] / [_persistSubtitleStyle]）。关闭后把键盘
  /// 焦点还给 Video（覆盖层夺焦后不会自动归还），恢复空格等快捷键。
  void _showPlayerSettings() {
    if (_videoSheetOpen) return;
    _videoSheetOpen = true;
    final Widget sheet = VideoQuickSettingsSheet(
      initialDelayMs: _delayMs,
      initialSpeed: _playbackSpeed,
      initialSubtitleBlur: appModel.videoSubtitleBlur,
      initialSubtitleStyle: _subtitleStyle,
      uiScale: _videoUiScale,
      initialAsbConfig: _asbConfig,
      onSetDelay: _setDelayMs,
      onSetSpeed: _setSpeed,
      onToggleSubtitleBlur: _toggleSubtitleBlur,
      onAsbConfigChanged: _setAsbConfig,
      onSubtitleOffsetChanged: _adjustSubtitleOffset,
      onSubtitleStylePreview: (VideoSubtitleStyle s) {
        if (mounted) setState(() => _subtitleStyle = s);
      },
      onSubtitleStyleCommit: _persistSubtitleStyle,
      // 着色器/mpv 配置改为面板内嵌（不再弹独立对话框，见 VideoQuickSettingsSheet）：
      // 着色器勾选 → 持久化启用集 + 解析绝对路径 + 实时应用；mpv 配置即改即生效。
      initialShadersEnabled: decodeEnabledShaders(appModel.videoShadersEnabled),
      onApplyShaders: (List<String> enabledNames) async {
        await appModel
            .setVideoShadersEnabled(encodeEnabledShaders(enabledNames));
        final VideoMpvConfig cfg =
            VideoMpvConfig.decode(appModel.videoMpvConfig);
        final List<String> paths = cfg.highQuality
            ? await resolveEnabledShaderPaths(enabledNames)
            : const <String>[];
        await _controller?.applyShaders(paths);
      },
      initialMpvConfig: VideoMpvConfig.decode(appModel.videoMpvConfig),
      onMpvConfigChanged: (VideoMpvConfig cfg) async {
        await appModel.setVideoMpvConfig(VideoMpvConfig.encode(cfg));
        await _controller?.applyMpvConfig(cfg);
        final List<String> paths = cfg.highQuality
            ? await resolveEnabledShaderPaths(
                decodeEnabledShaders(appModel.videoShadersEnabled))
            : const <String>[];
        await _controller?.applyShaders(paths);
      },
      initialLockWindowAspectRatio: _lockWindowAspectRatio,
      onLockWindowAspectRatioChanged: _setLockWindowAspectRatio,
      // 「从本机 mpv 导入」找不到时用户手动指定的 mpv 目录，记住下次优先扫。
      initialMpvShaderDir: appModel.videoMpvShaderDir,
      onMpvShaderDirChanged: (String dir) => appModel.setVideoMpvShaderDir(dir),
    );
    if (isDesktopPlatform) {
      showAppDialog<void>(
        context: context,
        builder: (_) => HibikiDialogFrame(
          // master-detail（左父菜单 + 右详情）需要更宽画布；窄于 640 的窗口由面板
          // 内部 LayoutBuilder 自动降级回单列 push（同阅读器）。
          maxWidth: 900,
          maxHeightFactor: 0.80,
          scrollable: false,
          child: sheet,
        ),
      ).whenComplete(() {
        _videoSheetOpen = false;
        _refocusVideo();
      });
    } else {
      adaptiveModalSheet<void>(
        context: context,
        builder: (_) => sheet,
      ).whenComplete(() {
        _videoSheetOpen = false;
        _refocusVideo();
      });
    }
  }

  /// 弹「字幕源」菜单：枚举当前视频的全部字幕源（内嵌轨 + 同目录外挂文件）+
  /// 顶部「关闭字幕」项。选某源 → 解析成 cue → 切 overlay + 持久化 + SnackBar。
  ///
  /// 这是运行时覆盖；默认 load 行为（自动 sidecar 优先 + 内嵌兜底）不变。
  Future<void> _showSubtitleSourceMenu(
    VideoPlayerController controller,
  ) async {
    if (_videoSheetOpen) return;
    _videoSheetOpen = true;
    final String? videoPath = _currentVideoPath;
    if (videoPath == null) {
      _videoSheetOpen = false;
      return;
    }

    final List<SubtitleSource> sources = await _subtitleSourcesForMenu(
      videoPath: videoPath,
      currentSubtitleSource: _currentSubtitleSource,
    );
    if (!context.mounted) {
      _videoSheetOpen = false;
      return;
    }

    // sheet 关闭后把键盘焦点还给 Video（覆盖层夺焦后不会自动归还）。
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.7,
          ),
          child: ListView(
            shrinkWrap: true,
            children: <Widget>[
              // 自动获取字幕（Jimaku）：用番名搜 → 下载 → 应用为外挂源。
              ListTile(
                leading: const Icon(Icons.cloud_download_outlined),
                title: Text(t.video_jimaku_fetch),
                onTap: () {
                  Navigator.pop(ctx);
                  _openJimakuDialog(controller);
                },
              ),
              // 从本地文件导入字幕：FilePicker 选 srt/ass/ssa/vtt → 拷到持久目录 →
              // 复用 _selectSubtitleSource 应用（解决 sidecar 名对不上 / 字幕在别目录）。
              ListTile(
                leading: const Icon(Icons.file_open_outlined),
                title: Text(t.video_subtitle_import_file),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickAndImportSubtitle(controller);
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.subtitles_off),
                title: Text(t.video_subtitle_off),
                selected: _currentSubtitleSource == null,
                selectedColor: Theme.of(ctx).colorScheme.primary,
                onTap: () {
                  Navigator.pop(ctx);
                  _selectSubtitleOff(controller);
                },
              ),
              for (final SubtitleSource source in sources)
                ListTile(
                  // 图形内封轨（PGS/DVD 等位图）用不同图标 + 副标题点明「画面显示·不可
                  // 查词」，让用户在点击前就分辨哪条能查词、哪条只是画面字幕（BUG-122）。
                  leading: Icon(
                    source.isGraphicEmbedded
                        ? Icons.image_outlined
                        : (source.isEmbedded ? Icons.movie : Icons.subtitles),
                  ),
                  title: Text(source.label),
                  subtitle: source.isGraphicEmbedded
                      ? Text(t.video_subtitle_graphic_hint)
                      : null,
                  selected: _subtitleSourceSelectedForMenu(
                    source,
                    _currentSubtitleSource,
                  ),
                  selectedColor: Theme.of(ctx).colorScheme.primary,
                  onTap: () {
                    Navigator.pop(ctx);
                    _selectSubtitleSource(controller, source);
                  },
                ),
            ],
          ),
        ),
      ),
    ).whenComplete(() {
      _videoSheetOpen = false;
      _refocusVideo();
    });
  }

  /// 打开「自动获取字幕（Jimaku）」对话框：用番名（文件名解析）搜 → 下载到
  /// `<appDocs>/video_subtitles/` → 构造外挂 [SubtitleSource] 复用既有 cue 加载/切换/
  /// 持久化链路应用。真实拉取需有效 Jimaku API key + 联网（验证待用户）。
  Future<void> _openJimakuDialog(VideoPlayerController controller) async {
    final String? videoPath = _currentVideoPath;
    if (videoPath == null) return;
    final Directory docs = await getApplicationDocumentsDirectory();
    final String saveDir = p.join(docs.path, 'video_subtitles');
    final String query = parseVideoFilename(p.basename(videoPath)).series;
    if (!context.mounted) return;
    final String? downloaded = await showDialog<String>(
      context: context,
      builder: (_) => JimakuSubtitleDialog(
        initialQuery: query,
        initialApiKey: appModel.jimakuApiKey,
        onApiKeyChanged: (String key) => appModel.setJimakuApiKey(key),
        saveDirectory: saveDir,
      ),
    );
    // Jimaku 对话框内含联网搜索/下载，会夺焦；关闭后把焦点还给 Video。
    _refocusVideo();
    if (downloaded == null || !context.mounted) return;
    final SubtitleSource source = SubtitleSource.external(
      externalPath: downloaded,
      label: p.basename(downloaded),
    );
    final bool applied = await _selectSubtitleSource(controller, source);
    // 仅在字幕真被应用（解析出 cue）时报「已下载并应用」；cue 为空时
    // _selectSubtitleSource 已弹失败提示，不再叠加误导性的成功提示。
    if (applied && mounted) {
      _showOsd(t.video_jimaku_downloaded);
    }
  }

  /// 弹系统文件选择器挑一个字幕文件（srt/ass/ssa/vtt）→ 经 [_importExternalSubtitle]
  /// 落盘并应用。FilePicker 会夺走视频键盘焦点，关闭后 [_refocusVideo] 归还。
  Future<void> _pickAndImportSubtitle(VideoPlayerController controller) async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['srt', 'vtt', 'ass', 'ssa'],
      allowMultiple: false,
    );
    _refocusVideo();
    final String? path = result?.files.single.path;
    if (path == null) return;
    await _importExternalSubtitle(controller, path);
  }

  /// 把用户挑选/拖入的外部字幕文件 [srcPath] 拷到持久化
  /// `<appDocs>/video_subtitles/`（与 Jimaku 下载同目录），构造外挂
  /// [SubtitleSource] 后经 [_selectSubtitleSource] 应用（复用 cue 解析/切换/
  /// 持久化/失败提示全链路）。
  ///
  /// 拷贝到持久目录而非直接用原路径：原文件可能在临时/缓存区或后续被移动，落盘后
  /// 持久化的 `subtitleSource` 路径才稳定可恢复。格式不支持或拷贝失败时弹提示、
  /// 不切换。源路径已在持久目录内时跳过自拷贝（File.copy 自拷会报错）。
  ///
  /// 落点是 `video_subtitles/<basename>`：同 basename 直接覆盖，是「当前集导入
  /// 覆盖」语义，有意不做去重——避免堆积同名副本，且换集恢复按文件名匹配，去重
  /// 后缀反而干扰匹配。
  /// 正在导入中的源路径（去重防护）。窗口模式下页级 + controls 内层两个拖放目标
  /// 可能对同一次拖放都触发 onDrop（BUG-133）；同一 srcPath 在途时忽略二次调用，
  /// 避免重复拷贝 / 重复弹加载遮罩 / 重复 SnackBar。
  final Set<String> _subtitleImportsInFlight = <String>{};

  Future<void> _importExternalSubtitle(
    VideoPlayerController controller,
    String srcPath,
  ) async {
    if (_currentVideoPath == null) return;
    if (_subtitleImportsInFlight.contains(srcPath)) return;
    _subtitleImportsInFlight.add(srcPath);
    try {
      await _importExternalSubtitleInner(controller, srcPath);
    } finally {
      _subtitleImportsInFlight.remove(srcPath);
    }
  }

  void _handlePlaybackDrop(
    VideoPlayerController controller,
    List<String> paths,
  ) {
    final DroppedFiles files = classifyDroppedFiles(paths);
    final String? sub = firstSubtitlePath(paths);
    if (sub != null) {
      unawaited(_importExternalSubtitle(controller, sub));
      return;
    }
    if (files.subtitles.isNotEmpty) {
      _showOsd(t.video_subtitle_import_unsupported);
      return;
    }
    if (files.audios.isNotEmpty && files.videos.isEmpty) {
      _showOsd(t.video_drop_audio_unsupported);
    }
  }

  /// [_importExternalSubtitle] 的实体（去重外壳已挡住并发同路径重入）。
  Future<void> _importExternalSubtitleInner(
    VideoPlayerController controller,
    String srcPath,
  ) async {
    if (subtitleFormatForPath(srcPath) == null) {
      _showOsd(t.video_subtitle_import_unsupported);
      return;
    }
    final Directory docs = await getApplicationDocumentsDirectory();
    final Directory destDir = Directory(p.join(docs.path, 'video_subtitles'));
    await destDir.create(recursive: true);
    final String dest = p.join(destDir.path, p.basename(srcPath));
    if (!p.equals(srcPath, dest)) {
      try {
        await File(srcPath).copy(dest);
      } catch (_) {
        if (!mounted) return;
        _showOsd(t.video_subtitle_import_failed);
        return;
      }
    }
    if (!mounted) return;
    final SubtitleSource source = SubtitleSource.external(
      externalPath: dest,
      label: p.basename(dest),
    );
    await _selectSubtitleSource(controller, source);
  }

  /// 字幕抽取加载遮罩当前是否已弹出（防重复 push / 防错 pop）。
  bool _subtitleLoadingShown = false;

  /// 弹出不可关的字幕抽取加载遮罩（BUG-104：大容器内嵌字幕 demux 可达数十秒）。
  void _showSubtitleLoadingOverlay() {
    if (_subtitleLoadingShown || !mounted) return;
    _subtitleLoadingShown = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black54,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
  }

  /// 关闭字幕抽取加载遮罩。配对 [_showSubtitleLoadingOverlay]，幂等。
  ///
  /// 这个遮罩是模态对话框、会夺走键盘焦点；media_kit 关闭覆盖层后**不会**自动把焦点
  /// 还给 [Video] 的 FocusNode（见 [_refocusVideo]）→ 关掉后空格等快捷键失灵（BUG-131：
  /// 导入字幕走 _pickAndImportSubtitle→_importExternalSubtitle→_selectSubtitleSource，
  /// 其中 _pickAndImportSubtitle 的 refocus 发生在本遮罩**之前**，遮罩一关焦点又悬空）。
  /// 故 pop 后在下一帧（让 pop 自身的焦点变更先落定）主动归还焦点给视频。
  void _hideSubtitleLoadingOverlay() {
    if (!_subtitleLoadingShown) return;
    _subtitleLoadingShown = false;
    if (mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      WidgetsBinding.instance.addPostFrameCallback((_) => _refocusVideo());
    }
  }

  /// 选中某字幕源：加载 cue → 切 overlay → 持久化 → SnackBar。
  /// 返回 true 表示字幕真被应用（解析出 cue 并切换/持久化）；false 表示空 cue
  /// 失败（已弹失败提示、未切换、未持久化、未覆盖当前可用字幕）。
  Future<bool> _selectSubtitleSource(
    VideoPlayerController controller,
    SubtitleSource source,
  ) async {
    final String? videoPath = _currentVideoPath;
    if (videoPath == null) return false;

    // BUG-122: 图形内封轨（PGS/DVD 等位图）无法转文本 cue（ffmpeg 抽 srt 直接报
    // bitmap→bitmap 拒绝），交给 libmpv 当画面字幕渲染：看得到、不可逐字查词。瞬时
    // 切轨、无需抽取，故不走加载遮罩 / loadCuesForSource。
    if (source.isGraphicEmbedded) {
      final bool shown =
          await controller.selectEmbeddedGraphicTrack(source.streamIndex!);
      if (!mounted) return false;
      if (!shown) {
        _showOsd(t.video_subtitle_load_failed(label: source.label));
        return false;
      }
      final String persisted = source.toPersistedValue();
      // 图形轨没有 cue，只落源指针（单视频也清掉旧 cue，避免上次文本 cue 残留把
      // overlay 又显示回来）；播放列表各集只存源指针，与文本分支一致。
      if (_episodes.isEmpty) {
        await widget.repo.saveSubtitleSelection(
          bookUid: widget.bookUid,
          subtitleSource: persisted,
          cues: const <AudioCue>[],
        );
      } else {
        await widget.repo.updateSubtitleSource(widget.bookUid, persisted);
      }
      if (!mounted) return false;
      setState(() => _currentSubtitleSource = persisted);
      _showOsd(t.video_subtitle_graphic_shown(label: source.label));
      return true;
    }

    // BUG-104: 内嵌字幕要从容器里 demux 抽取，大文件（如 27GB REMUX）首次可达
    // ~20s。期间给一个不可关的加载遮罩，否则底栏菜单一关、画面字幕没变，用户会以为
    // 「点了没反应、没切换过去」。抽取走单趟全轨缓存，同一视频后续切换瞬时命中。
    _showSubtitleLoadingOverlay();
    final List<AudioCue> cues;
    try {
      cues = await loadCuesForSource(source, videoPath, widget.bookUid);
    } finally {
      _hideSubtitleLoadingOverlay();
    }
    if (!mounted) return false;
    // 抽取/解析后无任何 cue（图形字幕、ffmpeg 缺失、轨损坏等）：诚实告知失败，
    // **不切换、不持久化**——避免谎报「已切换」却空屏，也避免用一个坏内封轨覆盖掉
    // 当前正常工作的字幕源（下次进来还是空）。
    if (cues.isEmpty) {
      _showOsd(t.video_subtitle_load_failed(label: source.label));
      return false;
    }
    controller.setCues(cues);
    // 选了文本字幕源就关掉 libmpv 画面字幕，避免与可点 overlay 双重渲染。
    await controller.selectSubtitleTrack(SubtitleTrack.no());

    final String persisted = source.toPersistedValue();
    // BUG-081: 单视频把解析出的 cue 落库，重进时 `_loadSingle` 的 `loadCues`
    // 直接命中，无需用户再手动加载。cue 与字幕源指针**原子**写入（事务），避免
    // 半落库导致下次恢复内容与源标签不一致。播放列表各集有意不存 cue（每集外部
    // 文件按磁盘动态解析，避免跨集 bookUid 错配，见 `_loadEpisode` 注释），故只
    // 写源指针。
    if (_episodes.isEmpty) {
      await widget.repo.saveSubtitleSelection(
        bookUid: widget.bookUid,
        subtitleSource: persisted,
        cues: cues,
      );
    } else {
      await widget.repo.updateSubtitleSource(widget.bookUid, persisted);
    }
    if (!mounted) return false;
    setState(() => _currentSubtitleSource = persisted);
    _showOsd(t.video_subtitle_switched(label: source.label));
    return true;
  }

  /// 关闭字幕：清空 cue overlay + 关 libmpv 字幕轨 + 持久化 null。
  Future<void> _selectSubtitleOff(VideoPlayerController controller) async {
    controller.setCues(const <AudioCue>[]);
    await controller.selectSubtitleTrack(SubtitleTrack.no());
    // BUG-081: 关字幕也要清掉单视频已落库的 cue，否则重进时 `loadCues` 命中旧
    // cue 又把字幕显示回来。cue 与源指针原子清空（事务）。播放列表不入 cue，只
    // 清源指针。
    if (_episodes.isEmpty) {
      await widget.repo.saveSubtitleSelection(
        bookUid: widget.bookUid,
        subtitleSource: null,
        cues: const <AudioCue>[],
      );
    } else {
      await widget.repo.updateSubtitleSource(widget.bookUid, null);
    }
    if (!mounted) return;
    setState(() => _currentSubtitleSource = null);
  }

  String _trackLabel(String? title, String? language, String id) {
    if ((title ?? '').isNotEmpty) return title!;
    if ((language ?? '').isNotEmpty) return language!;
    return id;
  }

  @override
  Widget build(BuildContext context) {
    final VideoPlayerController? controller = _controller;
    final VideoController? videoController = controller?.videoController;
    final ColorScheme cs = Theme.of(context).colorScheme;
    return PopScope(
      // 始终 `canPop: false` 自管退出：① 浮层栈非空时 back 先关栈（一层一层退），
      // 浮层在根 Overlay 退出视频路由不会自动清它，必须在 pop 前拦截；② 栈空真退出
      // 时，**先 await `flushPosition()` 把退出瞬间位置可靠落库再手动 pop**——否则只剩
      // controller.dispose() 里 fire-and-forget 的 `_forceSavePositionSync()`，drift
      // 写库 Future 与 Navigator 同步销毁 State 竞争、常写不完，导致「退出再进没回到
      // 上次位置」（对齐阅读器 `onWillPop` 先 await 落库再 pop 的做法）。
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? _) async {
        if (didPop) return;
        await _handleBackOrExit();
      },
      child: _buildScaffold(controller, videoController, cs),
    );
  }

  Widget _buildScaffold(
    VideoPlayerController? controller,
    VideoController? videoController,
    ColorScheme cs,
  ) {
    // 不再用 Scaffold AppBar：媒体播放器自带「视频内顶栏」（media_kit controls 的
    // topButtonBar），外层再叠一条 AppBar 等于两条顶栏、互相重复（BUG-102）。改为
    // 把返回/标题/剧集导航全部并入视频内顶栏（见 [_desktopControlsTheme] /
    // [_mobileControlsTheme]），与播放控制一起随鼠标/触摸显隐，单一顶栏。
    return Scaffold(
      backgroundColor: cs.surface,
      body: _failed
          ? Center(
              child: Icon(Icons.error_outline, color: cs.error, size: 48),
            )
          : (controller == null || videoController == null)
              ? const Center(child: CircularProgressIndicator())
              : _pageDropTarget(
                  controller,
                  _buildVideoBody(controller, videoController),
                ),
    );
  }

  /// 页级字幕拖放目标（BUG-133）。controls 内层也挂了一个（[_buildVideoControls]）供
  /// **全屏**用（media_kit 全屏是另推的根路由、复用同一 controls builder）；但窗口
  /// 模式下那个深埋在 media_kit `Video`→controls 子树里，实测 Windows OS 拖放在视频
  /// 区「完全没反应」。这里在页面顶层（与书架/视频库同款已验证可用的高层挂载点）再挂
  /// 一个，保证窗口模式可靠收到拖放；与内层重复触发由 [_importExternalSubtitle] 的
  /// 去重防护兜住。全屏时本页被全屏路由 Offstage、renderBox 尺寸归零 → 本目标不命中，
  /// 只剩内层生效，不会双触发。
  Widget _pageDropTarget(VideoPlayerController controller, Widget child) {
    return HibikiFileDropTarget(
      onDrop: (List<String> paths, Offset _) {
        _handlePlaybackDrop(controller, paths);
      },
      child: child,
    );
  }

  void _handleVideoPointerUp(PointerUpEvent event) {
    final BuildContext? controlsContext = _videoControlsContext;
    if (controlsContext == null ||
        !controlsContext.mounted ||
        _isVideoChromePointer(controlsContext, event.position)) {
      _lastVideoPointerUpAt = null;
      _lastVideoPointerUpPosition = null;
      return;
    }

    final DateTime now = DateTime.now();
    final DateTime? lastAt = _lastVideoPointerUpAt;
    final Offset? lastPosition = _lastVideoPointerUpPosition;
    _lastVideoPointerUpAt = now;
    _lastVideoPointerUpPosition = event.position;
    if (lastAt == null || lastPosition == null) return;
    if (now.difference(lastAt) > _videoDoubleClickInterval) return;
    if ((event.position - lastPosition).distance > _videoDoubleClickSlop) {
      return;
    }
    _lastVideoPointerUpAt = null;
    _lastVideoPointerUpPosition = null;
    unawaited(_toggleVideoFullscreen(controlsContext));
  }

  bool _isVideoChromePointer(
      BuildContext controlsContext, Offset globalPosition) {
    final RenderObject? renderObject = controlsContext.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return false;
    final Offset local = renderObject.globalToLocal(globalPosition);
    if (local.dx < 0 ||
        local.dy < 0 ||
        local.dx > renderObject.size.width ||
        local.dy > renderObject.size.height) {
      return false;
    }
    final EdgeInsets padding = MediaQuery.of(controlsContext).padding;
    final double topChromeBottom = padding.top + _videoButtonBarHeight;
    final double bottomChromeTop =
        renderObject.size.height - padding.bottom - _videoButtonBarHeight;
    return local.dy <= topChromeBottom || local.dy >= bottomChromeTop;
  }

  /// 视频本体：media_kit [Video] + 可点字幕 overlay。查词浮层栈不在这里渲染——它走
  /// 根 Overlay（[_syncPopupOverlay] / [_buildPopupOverlay]），以便全屏时浮在全屏
  /// 路由之上。每次 build 在 post-frame 同步根 Overlay 与当前栈。
  Widget _buildVideoBody(
    VideoPlayerController controller,
    VideoController videoController,
  ) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncPopupOverlay());
    final MaterialVideoControlsThemeData mobileControlsTheme =
        _mobileControlsTheme(controller);
    final MaterialDesktopVideoControlsThemeData desktopControlsTheme =
        _desktopControlsTheme(controller);
    // 两层主题嵌套：[AdaptiveVideoControls] 按平台互斥择一渲染（桌面读 Desktop
    // 主题、移动读 Material 主题），故同时提供两套互不干扰，让字幕/音轨/设置入口
    // 在桌面、移动、全屏三种场景都可达。嵌套顺序不影响——各自被对应平台 controls 读取。
    // 'B' 切换字幕模糊（asbplayer 同款热键）。包在 media_kit 内层 CallbackShortcuts
    // 之外：内层已消费空格/方向键/F 等，'B' 不在其默认绑定里 → 未被消费会冒泡到这层，
    // 故不与既有快捷键冲突，也不必重建 media_kit 那套含内部 helper 的默认绑定。
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        // includeRepeats:false——按住 B 不放时 OS key-repeat 会高频翻转模糊态并反复
        // 写偏好，只在按下沿触发一次。
        const SingleActivator(LogicalKeyboardKey.keyB, includeRepeats: false):
            () => unawaited(_toggleSubtitleBlur()),
      },
      child: VideoControlsThemePair(
        mobile: mobileControlsTheme,
        desktop: desktopControlsTheme,
        child: Video(
          controller: videoController,
          // 用本页持有的 FocusNode 替换 Video 内置的匿名节点，以便覆盖层（对话框 /
          // bottom sheet / 文件选择器）关闭后能主动把键盘焦点还给它，恢复空格等内置
          // 快捷键（见 [_refocusVideo]）。
          focusNode: _videoFocusNode,
          // 视频不满屏时的 letterbox/pillarbox 填充色吃主题 surface（默认黑边换成
          // 跟随主题的中性底色，与 Scaffold 背景一致，深浅主题统一）。
          fill: Theme.of(context).colorScheme.surface,
          // 字幕 overlay + 拖拽挂载都包进 controls builder：media_kit 全屏推独立 root
          // 路由并复用同一 controls，故 overlay 随全屏一起进路由，全屏时字幕仍显示且
          // 可点查词、拖字幕也能挂载（见 [_buildVideoControls]）。
          controls: (VideoState state) =>
              _buildVideoControls(state, controller),
        ),
      ),
    );
  }

  /// media_kit `controls` builder：默认桌面控制条 + 可点字幕 [VideoSubtitleOverlay]
  /// 叠加。返回的 widget 同时用于普通与全屏路由（media_kit 复用同一 builder），
  /// 故全屏时字幕一并显示。
  Widget _buildVideoControls(
    VideoState state,
    VideoPlayerController controller,
  ) {
    // 拖字幕文件到正在播放的视频上 → 即时挂载（asbplayer 式）。包在 controls
    // overlay 层（而非 [_buildVideoBody] 外层）：media_kit 全屏推独立 root 路由、
    // 复用同一 controls builder，故拖拽目标随全屏一起进路由——窗口与全屏两种场景
    // 用同一个目标都能挂载（覆盖 overlay 即视频可视区）。仅桌面三端启用
    // （[HibikiFileDropTarget] 内部门控），其余平台透传 child 零开销。只取第一个
    // 受支持字幕；拖入纯视频/图片等忽略。desktop_drop 只接管 OS 文件拖放、不吃
    // Flutter 指针事件，故内层字幕点击查词（onCharTap）不受影响；不夺焦故无需
    // _refocusVideo。
    return HibikiFileDropTarget(
      onDrop: (List<String> paths, Offset _) {
        _handlePlaybackDrop(controller, paths);
      },
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerUp: _handleVideoPointerUp,
        child: Stack(
          children: <Widget>[
            // Builder 捕获 media_kit controls 子树内的 context（[_videoControlsContext]），
            // 供覆盖后的键盘快捷键调用全屏 helper（isFullscreen/toggle/exitFullscreen）——
            // 本页 build context 是它们的祖先，找不到 media_kit 的 Fullscreen/VideoState
            // InheritedWidget。全屏复用同一 builder，故全屏路由会重新捕获其子树 context。
            Positioned.fill(
              child: Builder(
                builder: (BuildContext controlsContext) {
                  _videoControlsContext = controlsContext;
                  return AdaptiveVideoControls(state);
                },
              ),
            ),
            Positioned.fill(
              child: VideoSubtitleOverlay(
                controller: controller,
                onCharTap: _lookupAt,
                hitTester: _subtitleHitTester,
                blurEnabled: appModel.videoSubtitleBlur,
                fontSize: _subtitleStyle.fontSize,
                textColor: _subtitleStyle.resolveTextColor(
                    _subtitleTextColor(_videoChromeColorScheme(context))),
                fontWeight: _subtitleStyle.resolveFontWeight(_videoUiScale),
                shadowColor: _subtitleStyle.resolveShadowColor(
                    _subtitleShadowColor(_videoChromeColorScheme(context))),
                shadowThickness:
                    _subtitleStyle.resolveShadowThickness(_videoUiScale),
                backgroundColor: _subtitleStyle.resolveBackgroundColor(
                    _subtitleBackgroundColor(_videoChromeColorScheme(context))),
                backgroundOpacity: _subtitleStyle.backgroundOpacity,
                bottomPadding: _subtitleStyle.bottomPadding,
                fontFamily: appModel.appFontFamily,
              ),
            ),
            _buildOsdOverlay(),
          ],
        ),
      ),
    );
  }

  /// mpv 式左上角 OSD 通知层。监听 [_osdNotifier]，非空时淡入一条圆角半透明提示，
  /// 2.6s 后自动淡出。[IgnorePointer] 确保它从不拦截点击（单击暂停 / 拖放 / 字幕
  /// 查词都不受影响）。放在控制条上方一点（避开顶栏返回/标题），窗口与全屏复用。
  Widget _buildOsdOverlay() {
    final ColorScheme cs = _videoChromeColorScheme(context);
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: IgnorePointer(
          child: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 16, top: 52),
              child: ValueListenableBuilder<_VideoOsdMessage?>(
                valueListenable: _osdNotifier,
                builder: (BuildContext _, _VideoOsdMessage? osd, __) {
                  return AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: osd == null
                        ? const SizedBox.shrink()
                        : ConstrainedBox(
                            key: ValueKey<String>(osd.message),
                            constraints: BoxConstraints(
                              maxWidth: MediaQuery.sizeOf(context).width - 32,
                            ),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: _osdSurfaceColor(cs),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  if (osd.icon != null) ...<Widget>[
                                    Icon(
                                      osd.icon,
                                      size: 18,
                                      color: _osdTextColor(cs),
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                  Flexible(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: <Widget>[
                                        Text(
                                          osd.message,
                                          style: TextStyle(
                                            color: _osdTextColor(cs),
                                            fontSize: 14,
                                            height: 1.2,
                                          ),
                                        ),
                                        if (osd.progress != null) ...<Widget>[
                                          const SizedBox(height: 6),
                                          SizedBox(
                                            width: 112,
                                            child: LinearProgressIndicator(
                                              value: osd.progress,
                                              minHeight: 3,
                                              backgroundColor: _osdTextColor(cs)
                                                  .withValues(alpha: 0.25),
                                              valueColor:
                                                  AlwaysStoppedAnimation<Color>(
                                                _osdTextColor(cs),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  IconData _volumeIconFor(double volume) {
    if (volume <= 0) return Icons.volume_off;
    if (volume < 50) return Icons.volume_down;
    return Icons.volume_up;
  }
}
