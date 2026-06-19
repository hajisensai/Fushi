import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
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
import 'package:hibiki/src/media/audiobook/mining_sentence_draft.dart';
import 'package:hibiki/src/media/drag_drop/drop_classification.dart';
import 'package:hibiki/src/media/drag_drop/hibiki_file_drop_target.dart';
import 'package:hibiki/src/media/video/dandanplay_client.dart';
import 'package:hibiki/src/media/video/video_episode_start_policy.dart';
import 'package:hibiki/src/media/video/m3u8_playlist.dart';
import 'package:hibiki/src/media/video/video_asbplayer_config.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/media/video/video_control_customization.dart';
import 'package:hibiki/src/media/video/video_control_layout_edit_overlay.dart';
import 'package:hibiki/src/media/video/video_control_popover_placement.dart';
import 'package:hibiki/src/media/video/video_controls_focus_gate.dart';
import 'package:hibiki/src/media/video/video_controls_theme_pair.dart';
import 'package:hibiki/src/media/video/video_danmaku_model.dart';
import 'package:hibiki/src/media/video/video_danmaku_overlay.dart';
import 'package:hibiki/src/media/video/video_danmaku_source.dart';
import 'package:hibiki/src/media/video/video_favorite_sentences_panel.dart';
import 'package:hibiki/src/media/video/video_filename_parser.dart';
import 'package:hibiki/src/media/video/video_immersive_mode.dart';
import 'package:hibiki/src/media/video/video_mpv_config.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/media/video/video_screenshot_filename.dart';
import 'package:hibiki/src/startup/exit_flush_registry.dart';
import 'package:hibiki/src/media/video/video_player_shortcuts.dart';
import 'package:hibiki/src/media/video/video_shader_manager.dart';
import 'package:hibiki/src/media/video/video_shader_tier.dart';
import 'package:hibiki/src/media/video/video_chapter_panel.dart';
import 'package:hibiki/src/media/video/video_chapter_markers.dart';
import 'package:hibiki/src/media/video/video_clip_exporter.dart';
import 'package:hibiki/src/media/video/video_side_panel.dart';
import 'package:hibiki/src/media/video/video_subtitle_style.dart';
import 'package:hibiki/src/media/video/video_watch_tracker.dart';
import 'package:hibiki/src/pages/implementations/jimaku_subtitle_dialog.dart';
import 'package:hibiki/src/media/video/video_quick_settings_sheet.dart';
import 'package:hibiki/src/media/video/video_sidecar.dart';
import 'package:hibiki/src/media/video/video_subtitle_jump_panel.dart';
import 'package:hibiki/src/media/video/video_subtitle_overlay.dart';
import 'package:hibiki/src/media/video/video_subtitle_selection.dart';
import 'package:hibiki/src/media/video/video_subtitle_source.dart';
import 'package:hibiki/src/media/video/video_volume_overlays.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:hibiki/src/pages/implementations/dictionary_page_mixin.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart'
    show MinePopupResult;
import 'package:hibiki/src/pages/implementations/stat_activity.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/remote_video_client.dart';
import 'package:hibiki/src/utils/app_ui_scale.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:hibiki/src/platform/screen_brightness_controller.dart';
import 'package:hibiki/src/utils/misc/platform_utils.dart';
import 'package:hibiki/src/utils/misc/hibiki_toast.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';
import 'package:hibiki/src/utils/components/hibiki_icon_button.dart';

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
///
/// 制卡取 cue 的纯函数：按播放位置 [positionMs] 解析「用户正在学的那条字幕句」，
/// 供 [VideoHibikiPage] 制卡裁真实句子音频段用（TODO-104b / BUG-188）。
///
/// **为什么不直接复用 [VideoPlayerController.currentCue]**：`currentCue` 被字幕显示
/// 语义独占——句间静音 gap / 末句之后必须清成 null（真实字幕在时间窗结束后就该消失，
/// BUG-074）。用户常在「字幕刚消失的那一瞬」（已暂停、字幕条已撤但查词浮层还在）制卡，
/// 此刻 `currentCue == null`，制卡链路（`_lastLookupCue ?? currentCue`）拿不到 cue →
/// 句子音频字段空。这是**数据所有权冲突**：同一个 `_currentCue` 既服务 UI 显示又被制卡
/// 复用。本函数让制卡走**独立的按位置解析**，不复用被 gap 清空的 UI 状态。
///
/// 解析规则（与字幕显示同一 [effectiveSubtitlePositionMs] 坐标系，保证裁的就是用户看到
/// 的那句）：
/// 1. [JsonAlignmentParser.findCueIndex] 精确命中（位置落在某条 cue 的 `[startMs, endMs]`
///    闭区间内）→ 返回该 cue（与字幕显示期一致，不改正常路径）。
/// 2. 命中 -1（gap / 早于首句）→ floor 回退：取「起点 `startMs <= effectivePos` 的最后一条
///    cue」=用户最后看到、正在学的那句。
/// 3. floor 也无（位置早于全部 cue，一句都没起播过）/ 空 cue → 返回 null，制卡诚实留空。
AudioCue? resolveMiningCueForPosition({
  required List<AudioCue> cues,
  required int positionMs,
  required int delayMs,
}) {
  final int idx = resolveMiningCueIndexForPosition(
    cues: cues,
    positionMs: positionMs,
    delayMs: delayMs,
  );
  return idx >= 0 ? cues[idx] : null;
}

/// 同 [resolveMiningCueForPosition]，但返回**下标**而非 cue 对象（一句都没起播过 / 空 cue
/// 返回 -1）。跨字幕制卡（TODO-102）按下「开始/结束」时要记录 cue 的**下标**来界定区间，
/// 而单句制卡只要 cue 对象——两者共用同一套「精确命中 → floor 兜底」解析，避免漂移。
int resolveMiningCueIndexForPosition({
  required List<AudioCue> cues,
  required int positionMs,
  required int delayMs,
}) {
  if (cues.isEmpty) return -1;
  final int effectivePos = effectiveSubtitlePositionMs(positionMs, delayMs);
  // 1. 精确命中：位置落在某条 cue 的时间窗内（与字幕显示期同一判据）。
  final int hit = JsonAlignmentParser.findCueIndex(
    cues: cues,
    positionMs: effectivePos,
  );
  if (hit >= 0) return hit;
  // 2. gap / 末句后：floor 找「起点 <= 当前位置」的最后一条 cue（用户最后看到的那句）。
  //    [cues] 由 [VideoPlayerController.setCues] 保证按 startMs 升序，可二分。
  int lo = 0;
  int hi = cues.length;
  while (lo < hi) {
    final int mid = (lo + hi) >>> 1;
    if (cues[mid].startMs <= effectivePos) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  // 3. 位置早于全部 cue（lo - 1 < 0）：一句都没起播过，诚实返回 -1。
  return lo - 1;
}

@visibleForTesting
String videoFavoriteCacheKey({
  required String text,
  required int? startMs,
  required int? episodeIndex,
  required bool isPlaylist,
}) {
  final int? normalizedEpisodeIndex = isPlaylist ? episodeIndex : null;
  return startMs == null
      ? 'legacy|$text'
      : 'cue|${normalizedEpisodeIndex ?? 'single'}|$startMs|$text';
}

class VideoHibikiPage extends ConsumerStatefulWidget {
  const VideoHibikiPage({
    required this.bookUid,
    required this.repo,
    this.initialCueStartMs,
    this.initialEpisodeIndex,
    this.initialSubtitleListVisible = false,
    super.key,
  })  : remoteInfo = null,
        remoteClient = null;

  VideoHibikiPage.remote({
    required RemoteVideoInfo info,
    required this.repo,
    required RemoteVideoClient client,
    this.initialCueStartMs,
    this.initialEpisodeIndex,
    this.initialSubtitleListVisible = false,
    super.key,
  })  : bookUid = info.id,
        remoteInfo = info,
        remoteClient = client;

  final String bookUid;
  final VideoBookRepository repo;
  final RemoteVideoInfo? remoteInfo;
  final RemoteVideoClient? remoteClient;
  final int? initialCueStartMs;
  final int? initialEpisodeIndex;
  final bool initialSubtitleListVisible;

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
    int? initialCueStartMs,
    int? initialEpisodeIndex,
    bool initialSubtitleListVisible = false,
  }) =>
      HibikiAppUiScaleNeutralizer(
        child: VideoHibikiPage(
          bookUid: bookUid,
          repo: repo,
          initialCueStartMs: initialCueStartMs,
          initialEpisodeIndex: initialEpisodeIndex,
          initialSubtitleListVisible: initialSubtitleListVisible,
        ),
      );

  static Widget neutralizedRemote({
    required RemoteVideoInfo info,
    required VideoBookRepository repo,
    required RemoteVideoClient client,
    int? initialCueStartMs,
    int? initialEpisodeIndex,
    bool initialSubtitleListVisible = false,
  }) =>
      HibikiAppUiScaleNeutralizer(
        child: VideoHibikiPage.remote(
          info: info,
          repo: repo,
          client: client,
          initialCueStartMs: initialCueStartMs,
          initialEpisodeIndex: initialEpisodeIndex,
          initialSubtitleListVisible: initialSubtitleListVisible,
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

  /// 长按横向拖动连续调速的映射系数（TODO-338）：每 px 横向位移改变多少倍速。
  /// 200px ≈ 1.0x，故拖半屏（~600px）≈ ±3x，覆盖 [longPressDragMinSpeed]..
  /// [longPressDragMaxSpeed] 全程而手感不过敏。
  static const double longPressDragSpeedPerPixel = 1.0 / 200.0;

  /// 长按拖动调速的下/上限（TODO-338）。
  static const double longPressDragMinSpeed = 0.5;
  static const double longPressDragMaxSpeed = 4.0;

  /// 把长按拖动的横向位移映射成目标倍速（TODO-338，纯函数供单测）：以 [baseSpeed]
  /// （长按固定加速速）为基准，[dx]（相对长按起点的横向位移，右正左负）按
  /// [longPressDragSpeedPerPixel] 线性加减，clamp 到 [longPressDragMinSpeed]..
  /// [longPressDragMaxSpeed]，再 snap 到 0.1x 步进。向右拖加速、向左减速。
  @visibleForTesting
  static double longPressDragSpeedFor(double baseSpeed, double dx) {
    final double target = (baseSpeed + dx * longPressDragSpeedPerPixel).clamp(
      longPressDragMinSpeed,
      longPressDragMaxSpeed,
    );
    return (target * 10).roundToDouble() / 10;
  }

  @override
  ConsumerState<VideoHibikiPage> createState() => _VideoHibikiPageState();
}

class _VideoOsdMessage {
  const _VideoOsdMessage({required this.message, this.icon, this.progress});

  final String message;
  final IconData? icon;
  final double? progress;
}

enum _VideoLevelHudKind { leftBrightness, rightVolume }

class _VideoLevelHudState {
  const _VideoLevelHudState({required this.kind, required this.value});

  final _VideoLevelHudKind kind;
  final double value;
}

/// 集成测试钩子（仅测试用）：对当前 [VideoHibikiPage] 的 [State] 读播放位置 /
/// 驱动真实播放，验证「退出→再进续播」链路而不暴露页面私有字段。State 以
/// [VideoHibikiTestHooks] 形式按接口暴露，测试经 `tester.state` 拿到后 `as` 转型。
@visibleForTesting
abstract class VideoHibikiTestHooks {
  /// 当前播放位置（毫秒）；未就绪为 null。
  int? get debugPositionMs;

  /// 当前 controller 读到的内封章节数量。
  int get debugChapterCount;

  /// 当前 controller 读到的媒体时长（毫秒）；未就绪为 null/0。
  int? get debugDurationMs;

  /// 测试直接打开章节侧栏，避免用坐标/私有控件路径模拟点击。
  void debugShowChapterPanel();

  /// 开始真实播放（驱动 libmpv），让位置自然前进。
  Future<void> debugPlay();
}

// TODO-314：字幕跳转列表不再走 overlay 面板系统，改 push-aside（[_subtitleListVisible]
// / [_videoWithSubtitlePanel]），把画面真挤窄到左侧而非浮层遮挡。故此枚举不再含字幕列表项。
enum _VideoSidePanelKind {
  speed,
  settings,
  favoriteSentences,
  subtitleSources,
  audioTracks,
  chapters,
}

class _VideoSidePanelState {
  const _VideoSidePanelState({
    required this.kind,
    required this.alignment,
  });

  final _VideoSidePanelKind kind;
  final Alignment alignment;
}

enum _VideoControlPopoverKind { volume, speed }

class _VideoControlPopoverPlacement {
  const _VideoControlPopoverPlacement({
    required this.targetAnchor,
    required this.followerAnchor,
    required this.gapDirection,
  });

  final Alignment targetAnchor;
  final Alignment followerAnchor;

  /// 浮层相对按钮锚点的「让位」方向单位向量（TODO-560）：向上弹为 (0,-1)、向下弹为
  /// (0,1)、向左弹为 (-1,0)、向右弹为 (1,0)。渲染时乘以 gap 得到 [CompositedTransformFollower]
  /// 的 offset，使浮层始终朝画面内侧离开按钮（旧实现只会 (0,-gap) 恒向上）。
  final Offset gapDirection;
}

class _VideoHibikiPageState extends ConsumerState<VideoHibikiPage>
    with DictionaryPageMixin, WidgetsBindingObserver
    implements VideoHibikiTestHooks {
  // 控制条尺寸基线（界面缩放 ×1.0 时的值）。视频页整页被
  // [HibikiAppUiScaleNeutralizer] 中和回 scale=1.0（保证 WebView 查词坐标一致），
  // 故 media_kit 控制条不会自动吃全局「界面大小」——这些基线再乘 [_videoUiScale]
  // 暴露成下面的实例 getter，让顶/底栏图标、按钮条高度、播放键与查词弹窗同一口径
  // 随界面缩放一起放大缩小（TODO-067）。
  static const double _videoButtonBarHeightBase = 56;
  static const double _videoControlIconSizeBase = 32;
  static const double _videoPlayPauseIconSizeBase = 36;
  static const double _videoControlTitleFontSizeBase = 16;

  /// 按钮条触摸高度，随界面大小缩放（TODO-067）。
  double get _videoButtonBarHeight => _videoButtonBarHeightBase * _videoUiScale;

  /// 顶/底栏控制图标尺寸，随界面大小缩放（TODO-067）。与查词弹窗 ×appUiScale 同口径。
  double get _videoControlIconSize => _videoControlIconSizeBase * _videoUiScale;

  /// 中央播放/暂停键尺寸，随界面大小缩放（TODO-067）。
  double get _videoPlayPauseIconSize =>
      _videoPlayPauseIconSizeBase * _videoUiScale;

  /// 移动控制条底部留白基线（BUG-184）：进度条 / 底部按钮条不贴屏幕物理底边。
  ///
  /// media_kit 的 [MaterialVideoControlsThemeData] 构造器把 `seekBarMargin` 默认成
  /// [EdgeInsets.zero]、`bottomButtonBarMargin` 默认成只有左右无底部（与导出常量
  /// [kDefaultMaterialVideoControlsThemeData] 那套含 `bottom: 42` 的留白不同）。本页
  /// 直接 new 主题、未传这两个 margin 时，进度条会落在 `bottom: 0` 紧贴屏幕最底——
  /// 在 Android 上看起来「进度条在最下面」（被手势条/物理边缘吞掉，非控制条惯例位置）。
  /// 这个基线把进度条与按钮条整体抬离最底，再叠加 [_videoBottomSystemInset] 的系统
  /// 导航栏/手势栏 inset。
  static const double _videoBottomChromeBaseline = 24;

  /// 移动控制条进度条与底部按钮条之间的竖直间距基线（TODO-156/BUG-217）。media_kit
  /// 把进度条与底部按钮条放在**同一个** `Stack(alignment: bottomCenter)`，两者都按
  /// `bottom` 对齐；本页原先把 `seekBarMargin.bottom` 与 `bottomButtonBarMargin.bottom`
  /// 设成同一基线 → 进度条落到按钮条同一基线上、与按钮重叠（手机上「按钮没在进度条
  /// 下面」）。把 `seekBarMargin.bottom` 抬高 = 按钮条高 + 本间距，让进度条整体落在
  /// 按钮条上方。随界面大小缩放（[_videoUiScale]）。
  static const double _videoSeekBarButtonGapBase = 8;

  /// 移动控制条进度条触摸热区高度基线（TODO-157/BUG-218）。media_kit 默认
  /// `seekBarContainerHeight=36`，对准才滑得到；抬高扩大可命中热区。随界面缩放。
  /// 热区向上长（[_mobileControlsTheme] 把进度条整体抬到按钮条上方），不向下侵入
  /// 系统边缘手势区。
  static const double _videoSeekBarContainerHeightBase = 52;

  /// 移动控制条进度条拖动滑块尺寸基线（TODO-157/BUG-218）。media_kit 默认 12.8；
  /// 抬高让滑块更易对准。随界面缩放。
  static const double _videoSeekBarThumbSizeBase = 18;

  /// 移动控制条进度条轨道高度基线（TODO-157/BUG-218）。media_kit 默认 2.4；抬高让
  /// 轨道更醒目、更易滑。随界面缩放。
  static const double _videoSeekBarTrackHeightBase = 5;
  static const double _videoControlPopoverGapBase = 8;

  /// 进度条与按钮条竖直间距，随界面大小缩放（TODO-156）。
  double get _videoSeekBarButtonGap =>
      _videoSeekBarButtonGapBase * _videoUiScale;

  /// 进度条触摸热区高度，随界面大小缩放（TODO-157）。
  double get _videoSeekBarContainerHeight =>
      _videoSeekBarContainerHeightBase * _videoUiScale;

  /// 进度条拖动滑块尺寸，随界面大小缩放（TODO-157）。
  double get _videoSeekBarThumbSize =>
      _videoSeekBarThumbSizeBase * _videoUiScale;

  /// 进度条轨道高度，随界面大小缩放（TODO-157）。
  double get _videoSeekBarTrackHeight =>
      _videoSeekBarTrackHeightBase * _videoUiScale;

  static const Duration _videoDoubleClickInterval = Duration(milliseconds: 400);
  static const double _videoDoubleClickSlop = 48;

  /// 章节刻度层（TODO-432）淡入淡出时长：对齐 media_kit 控制条默认
  /// `controlsTransitionDuration`（300ms，本页未覆盖），使刻度与 seek bar 同步显隐。
  static const Duration _videoChromeFadeDuration = Duration(milliseconds: 300);

  /// 唤醒控制条用的合成 hover 设备 id（[_pokeControlsVisible]）。取一个不与真实
  /// 鼠标/触控设备号冲突的固定值，使重复派发落在同一逻辑设备上。
  static const int _syntheticHoverDevice = 0x6869626B; // 'hibk'

  /// 合成 hover 位置的 ±1px 抖动开关（TODO-148/BUG-215）。Flutter `MouseTracker`
  /// 对**同一设备落在同一坐标**的连续 hover 会去重（位置没变就不再回调 onHover），
  /// 连按快进 / 跳句时 [_pokeControlsVisible] 每次都派发到控制条**固定中心点**，第二
  /// 次起 media_kit 的 `MouseRegion.onHover` 不再触发、隐藏 `Timer` 不续命，控制条
  /// 仍只活 2 秒就消失。每次派发翻转此标志、把 x 偏 ±1px，使坐标始终变化，强制
  /// MouseTracker 每次都回调 onHover 续命。仅 1px 抖动不会偏出控制条命中区。
  bool _pokeParity = false;
  static const double _volumeStep = 5.0;

  /// media_kit 移动控制条竖滑（左=亮度 / 右=音量）的灵敏度（TODO-172/BUG-230）。
  /// media_kit 公式是 `value -= delta.dy / verticalGestureSensitivity`——值越大越
  /// 不敏感。其默认 100（满量程仅需约 100px 竖向拖动，太敏感，轻轻一划就拉满 / 归零）。
  /// 抬到 320（灵敏度降到约 1/3，满量程约需 320px 拖动），符合用户「太灵敏」反馈。
  /// 仅移动端有此竖滑手势，传给 [_mobileControlsTheme]；桌面 [_desktopControlsTheme]
  /// 无此手势、不设此参数（诚实降级）。
  static const double _videoVerticalGestureSensitivity = 320.0;

  // TODO-057: 视频左半区竖滑调屏幕亮度、右半区竖滑调音量。手势 + 指示器复用
  // media_kit 移动控制条竖滑手势接线见 [_mobileControlsTheme]；亮度落设备背光经
  // 此 controller 且诚实门控，音量是播放器能力，不跟随亮度能力门控。
  final ScreenBrightnessController _brightness =
      ScreenBrightnessController.instance;

  /// 进入视频时的系统屏幕亮度快照（移动端）。退出播放器 [restore] 写回，防止把
  /// 用户系统亮度永久留在拖动后的值（iOS 系统级亮度尤其要还原）。null=尚未取到。
  double? _enterBrightness;

  int get _asbSeekMs => _asbConfig.seekSeconds * 1000;
  double get _speedStep => _asbConfig.speedStep;

  ColorScheme _videoChromeColorScheme(BuildContext context) =>
      Theme.of(context).colorScheme;

  /// 顶栏标题字号，随界面大小缩放（TODO-067），与图标按钮同口径。
  double get _videoControlTitleFontSize =>
      _videoControlTitleFontSizeBase * _videoUiScale;

  TextStyle _videoControlTitleStyle(ColorScheme cs) =>
      TextStyle(color: cs.onSurface, fontSize: _videoControlTitleFontSize);

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
  int get debugChapterCount => _controller?.chapters.length ?? 0;

  @override
  int? get debugDurationMs => _controller?.durationMs;

  @override
  void debugShowChapterPanel() {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    _showChapterPanel(controller);
  }

  @override
  Future<void> debugPlay() async => _controller?.play();

  VideoPlayerController? _controller;
  VideoPlayerController? _chapterListenerController;
  VoidCallback? _chapterListener;
  bool _failed = false;
  String? _title;
  List<VideoDanmakuItem> _danmakuItems = const <VideoDanmakuItem>[];
  int _danmakuLoadSeq = 0;

  /// 顶栏标题的响应式来源（BUG-120）。顶栏文字渲染在 media_kit 控制条主题里，全屏是
  /// 推到根 navigator 的独立路由、进入时**快照捕获**当时的主题（含标题字符串），页面
  /// `setState` 不会重建全屏路由 → 全屏换集后标题停在旧集。改用 [ValueNotifier] + 顶栏
  /// `ValueListenableBuilder` 监听：它在全屏路由内也会随 notifier 变化自重建，标题跟上。
  final ValueNotifier<String?> _titleNotifier = ValueNotifier<String?>(null);

  /// 字幕跳转列表面板的可见性（TODO-069；asbplayer 式 transcript 面板）。
  ///
  /// 用 [ValueNotifier] 而非 setState：面板渲染在 media_kit controls builder 内的
  /// [Stack]（[_buildVideoControlsInner]），全屏是推到根 navigator 的独立路由、不随
  /// 本页 setState 重建（与标题 [_titleNotifier] 同源，BUG-120）。监听 notifier 才能
  /// 让窗口与全屏两种场景都随 L 键 / 入口按钮翻转可见。
  final ValueNotifier<bool> _subtitleListVisible = ValueNotifier<bool>(false);
  final ValueNotifier<_VideoSidePanelState?> _videoSidePanel =
      ValueNotifier<_VideoSidePanelState?>(null);
  final ValueNotifier<_VideoControlPopoverKind?> _videoControlPopover =
      ValueNotifier<_VideoControlPopoverKind?>(null);
  final Map<String, LayerLink> _controlPopoverItemLinks = <String, LayerLink>{};
  final Map<String, GlobalKey> _controlPopoverTargetKeys =
      <String, GlobalKey>{};
  LayerLink? _activeControlPopoverLink;
  _VideoControlPopoverPlacement? _activeControlPopoverPlacement;
  VideoControlSlot? _activeControlPopoverSourceSlot;
  VideoControlItem? _activeControlPopoverSourceItem;
  bool _controlPopoverAnchorHovered = false;
  bool _controlPopoverPanelHovered = false;
  bool _controlPopoverPinned = false;
  Timer? _controlPopoverHideTimer;

  /// 画面内控制布局编辑模式（TODO-440）。用 [ValueNotifier] 而非普通 setState：
  /// 叠层渲染在 media_kit controls builder 里，全屏路由同样需要即时开关。
  final ValueNotifier<bool> _videoControlEditMode = ValueNotifier<bool>(false);

  /// 当前 9 槽控制按钮布局的响应式来源（TODO-466）。
  ///
  /// 保存「画面上编辑」草稿后，窗口页 setState 能刷新普通页面树，但全屏路由和
  /// media_kit controls builder 是独立子树；只改字段/落偏好会让当前控制层继续用旧
  /// theme 快照。用 notifier 推进当前布局，并在 controls builder 内重建控制主题，
  /// 窗口与全屏都能立即反映新槽位。
  final ValueNotifier<VideoControlLayout> _controlLayoutNotifier =
      ValueNotifier<VideoControlLayout>(VideoControlLayout.currentChrome);

  List<SubtitleSource> _subtitleMenuSources = const <SubtitleSource>[];
  bool _subtitleMenuLoading = false;

  /// 当前视频是否有内封章节（TODO-424）：控制条章节入口按钮的显隐门控。章节列表是
  /// [VideoPlayerController.refreshChapters] open 后**异步**填充的，故缓存这个布尔并由
  /// [_onControllerChaptersChanged] 监听 controller 通知刷新——章节就绪后触发一次
  /// setState 让按钮出现（控制条主题在 build 里构造一次，不监听 controller 不会自重建）。
  bool _hasChapters = false;

  /// 锁定 / 沉浸模式（TODO-101）。开启后：鼠标移动 / 单击不再唤起 media_kit 控制条
  /// （顶/底栏按钮全部不弹），视频纯画面播放；但查词（点字幕字符）与所有键盘 / 手柄
  /// 快捷键（上下句、seek、字幕列表、播放暂停等）仍照常工作。痛点：「每次鼠标查词就
  /// 弹按钮有点烦」。
  ///
  /// 用 [ValueNotifier] 而非 setState：锁定态要在 media_kit controls builder 内的
  /// [Stack]（[_buildVideoControlsInner]）里 gate `AdaptiveVideoControls` 的指针、并驱动
  /// 常驻解锁按钮的显隐；全屏是推到根 navigator 的独立路由、不随本页 setState 重建
  /// （与 [_titleNotifier] / [_subtitleListVisible] 同源，BUG-120）。监听 notifier 才能
  /// 让窗口与全屏两种场景都随锁屏按钮 / 快捷键翻转。
  final ValueNotifier<bool> _immersiveLocked = ValueNotifier<bool>(false);

  /// 视频内角标通知（mpv 式 OSD）。取代会从屏幕底部弹出、遮挡控制条、且与 mpv 等
  /// 播放器观感割裂的 Material SnackBar（用户要求改成 mpv 那样的左上角短暂提示）。
  /// null=不显示。渲染在 [_buildVideoControls] 的 controls overlay 里，故窗口/全屏
  /// 都显示；[IgnorePointer] 包裹，绝不拦截点击（不破坏单击暂停 / 拖放 / 字幕查词）。
  final ValueNotifier<_VideoOsdMessage?> _osdNotifier =
      ValueNotifier<_VideoOsdMessage?>(null);

  /// OSD 自动消失定时器（每次 [_showOsd] 重置）。
  Timer? _osdTimer;

  /// Page-level level HUD value (0..100). Null means hidden.
  final ValueNotifier<_VideoLevelHudState?> _levelHudNotifier =
      ValueNotifier<_VideoLevelHudState?>(null);

  /// Auto-hide timer for the page-level level HUD.
  Timer? _levelHudTimer;

  /// media_kit 底部控制条 **真实** 可见性（TODO-364）——单一真相源，由 media_kit 自己的
  /// 控制条 State 在每次 `visible` 变化时推进来。
  ///
  /// 历史根因（TODO-129 旧实现）：media_kit 把控制条可见性 `visible` 与隐藏 `Timer` 藏在
  /// 私有 State，旧 Hibiki 侧另建一份 **镜像** [_videoControlsVisible] + 一个独立隐藏
  /// `Timer`（已删）复刻同一套触发源喂给字幕避让。两套 `Timer` 各自计时、
  /// 各入口（hover / 移动 tap / 键盘 poke）独立维护 → 镜像与真实控制条 **相位会反**：
  /// 进度条起落动画中又来一次操作时，镜像翻成与真实可见态相反，字幕避让方向就反了
  /// （用户：「进度条起来下去同时其他操作字幕行为相反，让他们用同一个变量」）。
  ///
  /// 修复：vendored media_kit_video fork 给两套控制主题加 `visibilityNotifier`，控制条
  /// State 每次改 `visible` 都推进本 notifier（见 third_party/media_kit_video/PATCHES.md）。
  /// 本字段即那唯一真相源，字幕避让消费它派生出的 [_videoControlsVisible]，彻底消除独立
  /// 镜像 + 第二个 `Timer` 的相位漂移。窗口 / 全屏复用同一 controls builder，故两套主题
  /// 都注入同一个 notifier。
  final ValueNotifier<bool> _mediaKitControlsVisible =
      ValueNotifier<bool>(false);

  /// 字幕避让真正消费的控制条可见性（TODO-129/364）。**单一写入点** =
  /// [_applyControlsVisibilityFromMediaKit]：它把 media_kit 真实可见性
  /// （[_mediaKitControlsVisible]）按沉浸锁 / 侧栏 / 字幕列表门控取下限派生进来。不再有
  /// 任何入口直接乐观翻它（那是 TODO-364 相位反的根因），故它恒等于「真实可见态 且 无遮挡
  /// overlay」。
  ///
  /// 用 [ValueNotifier] 而非 setState：字幕 overlay 在 media_kit controls builder 内的
  /// [Stack]（[_buildVideoControlsInner]），全屏是推到根 navigator 的独立路由、不随本页
  /// setState 重建（与 [_titleNotifier] / [_immersiveLocked] 同源，BUG-120）。监听
  /// notifier 才能让窗口与全屏两种场景字幕都随控制条显隐上顶 / 落回。
  final ValueNotifier<bool> _videoControlsVisible = ValueNotifier<bool>(false);

  /// 鼠标当前是否悬停在右 / 左浮动学习按钮 rail 上（BUG-283）。
  ///
  /// 根因：rail 按钮是 opaque 的 [IconButton]，叠在 media_kit 桌面控制条那个**全画面**
  /// hover-tracking [MouseRegion] 之上。鼠标移到 rail 按钮上时，Flutter MouseTracker 把
  /// 最顶命中切到按钮 → media_kit 的 `MouseRegion.onExit` 触发 → 它**立即**把 `visible`
  /// 置 false（见 media_kit `material_desktop.dart` 的 `onExit`）→ [_videoControlsVisible]
  /// 派生为 false → rail [SizedBox.shrink] 消失 → 鼠标位置下方重新变成 media_kit region →
  /// `onEnter` 把 visible 拉回 true → rail 重现 → 鼠标又落按钮上 → 每帧级别快速闪烁。
  ///
  /// 修复（消除特殊情况，而非去抖/延迟掩盖）：rail 的显隐判据改为
  /// `[_videoControlsVisible] || 鼠标正悬在 rail 上`。鼠标进 rail 即置本标记 true，rail 在
  /// hover 期间永不被 media_kit 的瞬时 visible 抖动收走 → 振荡根除。进 rail 同时
  /// [_pokeControlsVisible] 喂合成 hover 给 media_kit（其自身设计的续命路径），底层控制条
  /// 也跟着保持，观感统一。仅桌面有 hover 语义（移动端无，[ValueNotifier] 恒 false 不影响）。
  final ValueNotifier<bool> _railHovered = ValueNotifier<bool>(false);

  /// 视频左侧常驻锁 / 解锁按钮（TODO-126）的可见性。非沉浸态显示锁图标（进入沉浸）、
  /// 沉浸态显示解锁图标（退出沉浸）——两态用同一枚侧边按钮（[_buildSideLockButton]）。
  ///
  /// 与 [_videoControlsVisible] 同样走「hover / tap 唤起 + 2s 自动淡出」时序，但**独立于
  /// 它**：沉浸态下 [_markControlsVisible] 被锁强制 false（防 media_kit 控制条弹出），若解
  /// 锁按钮复用 [_videoControlsVisible] 就会被一起 gate 成永久淡出、再也唤不回（用户就没有
  /// 可见退出口了）。故另起一份不被锁 gate 的可见性源 [_pokeLockButton]，保证沉浸态解锁按钮
  /// 无操作淡出后仍能被鼠标移动 / 触屏唤回。Esc / Shift+L 始终可解锁（守卫已钉），淡出不
  /// 影响这两条退出口。用 [ValueNotifier] 让全屏路由也随之翻转（与 [_immersiveLocked] /
  /// [_videoControlsVisible] 同源，BUG-120）。初始 true：开页先显示让用户发现锁按钮，2s 淡出。
  final ValueNotifier<bool> _lockButtonVisible = ValueNotifier<bool>(true);

  /// 鼠标是否正悬在侧边锁 / 解锁（沉浸）按钮上（TODO-388，BUG-294）。
  ///
  /// 根因：侧边锁按钮的可见性走 [_lockButtonVisible] + [_pokeLockButton] 的 2s 自动淡出
  /// 定时器，唤起只发生在「鼠标在视频区移动」时（[_videoControlsHoverWrap] 的 onHover →
  /// [_pokeLockButton]）。一旦鼠标**静止悬停在按钮本身**上，不再有 hover 事件续命定时器，
  /// 2s 后按钮就在光标正下方淡出消失——与用户报告「沉浸按钮鼠标放上去会消失」一致。
  /// 屏幕右侧 rail 按钮用 [_railHovered] + [_railHoverKeepAlive] 解决同类问题（hover 期间
  /// 顶住显示、永不被自动淡出收走）。本字段把同一机制套到锁按钮上：鼠标进按钮置 true 顶住
  /// 可见、移出置 false 让可见性回落到 [_lockButtonVisible] 的自然淡出。仅桌面有 hover。
  final ValueNotifier<bool> _lockButtonHovered = ValueNotifier<bool>(false);

  /// 侧边锁 / 解锁按钮自动淡出定时器（TODO-126）。每次 [_pokeLockButton] 唤起重置。
  Timer? _lockButtonHideTimer;

  /// OS 鼠标光标是否应隐藏的单一真相源（TODO-318 / BUG-258）。
  ///
  /// 根因：media_kit 自己用 `MouseRegion(cursor: none)`（`hideMouseOnControlsRemoval`）在
  /// 控制条淡出时隐藏光标，但 hibiki 把 overlay chrome（锁按钮 rail / OSD / 字幕跳转面板等）
  /// 叠在 media_kit 之上 → 最上层 MouseRegion 的 cursor 解析胜出 → 鼠标放到这些 chrome 上时
  /// 光标重现；沉浸锁态下 [IgnorePointer] 又剥了 media_kit 的 region，光标更无人隐藏。
  ///
  /// 解法：在 controls 子树最外层（[_videoControlsHoverWrap]）包一个 `MouseRegion(cursor:
  /// none)`，由本 notifier 驱动统一胜出，盖过所有 chrome。隐藏时机镜像 controls 自动隐藏
  /// 2s 计时 + 沉浸锁态；真实鼠标移动经 [_handleVideoControlsHover] 自然唤回（置 false）。
  /// 用 [ValueNotifier] 让全屏路由也响应（与 [_videoControlsVisible] / [_immersiveLocked]
  /// 同源，BUG-120）。仅桌面有 OS 光标语义；移动端 [_videoControlsHoverWrap] 透传 child。
  final ValueNotifier<bool> _cursorHidden = ValueNotifier<bool>(false);

  /// 翻转 OS 光标隐藏单一真相源（TODO-318）。仅桌面生效（移动端无 OS 光标）。
  void _setCursorHidden(bool hidden) {
    if (!_isDesktopVideoControls) return;
    _cursorHidden.value = hidden;
  }

  /// 在视频左上角短暂显示一条 OSD 通知（约 2.6s 后自动消失）。mounted-safe，可在
  /// `await` 之后直接调（取代各处 `ScaffoldMessenger.showSnackBar`）。
  void _showOsd(String message, {IconData? icon, double? progress}) {
    if (!mounted) return;
    _osdNotifier.value = _VideoOsdMessage(
      message: message,
      icon: icon,
      progress: progress?.clamp(0.0, 1.0).toDouble(),
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

  /// 全屏路由当前是否在栈上：进全屏置位、全屏路由 future 完成（任意退出路径：
  /// Esc / F / 按钮 / 双击 / 系统返回）复位。
  ///
  /// 这是窗口侧 controls 在全屏期间必须卸载（[VideoControlsFocusGate]）的唯一依据：
  /// 全屏路由会用**同一个** [_videoFocusNode] 再挂一个 [Focus]，若窗口侧 controls
  /// 不卸载，退全屏时全屏侧 Focus dispose 的 detach 会把节点从焦点树摘除，窗口侧
  /// 只剩 stale attachment、永远不再 reparent → 节点永久孤儿、此后所有
  /// [_refocusVideo]（含每个菜单/对话框关闭后的归还）全部静默失效——这正是
  /// 「设置/导入/点外部后快捷键失灵」在打过逐点 refocus 补丁后仍复发的共同根因
  /// （TODO-040/042）。
  bool _videoFullscreenActive = false;

  /// 当前在栈上的全屏路由（[_videoFullscreenActive] 为真时非 null）。
  /// [_reclaimVideoFocusIfOwned] 用它判定全屏期间「键盘所有者路由」是否被
  /// 对话框/遮罩压住（`isCurrent`），避免切窗返回时抢走全屏内对话框的焦点。
  PageRoute<void>? _videoFullscreenRoute;

  /// 观看统计采集器（观看时长 + 字幕字数 + 完成标记）；首次 load 建，dispose 释放。
  VideoWatchTracker? _watchTracker;

  /// 进程退出 flush 回调引用（TODO-086/BUG-191）：initState 登记到
  /// [ExitFlushRegistry]，dispose 注销。保证未落库的播放位置 + 观看统计在
  /// exit(0) 前写穿。
  ExitFlushCallback? _exitFlushCallback;

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

  /// TODO-270 E「查词窗口多句合一制卡」(乙方案·视频车道)：会话级制卡草稿缓冲。弹窗点
  /// 「+句」把当前正查字幕句（[_lastLookupSentence]）+ 其 cue 的画面/音频时间窗推进
  /// 这里，连续查多句累积；制卡（[onMineEntry] / [onUpdateEntry]）时把草稿全部句 +
  /// 当前句用 [MiningSentenceDraft.composeText] 合成 sentence 字段、用
  /// [MiningSentenceDraft.composeAudioRange] 合并成「首句起→末句止」的单一区间（GIF +
  /// 音频共用，与字幕列表多选 [_selectedMiningCueStarts] 同观感，但属不同入口）。制卡
  /// 成功或关闭整条查词浮层栈后清空。视频所有 cue 同属一个视频文件，故区间合并恒成功
  /// （[MiningSentenceDraft] 把 [AudioPlaybackRange.audioFileIndex] 当文件键，视频统一
  /// 用 0）。reader/有声书车道（[ReaderHibikiPage] 的 `_miningDraft`）共用同一草稿模型。
  final MiningSentenceDraft _miningDraft = MiningSentenceDraft();

  /// TODO-393「上 N 句 / 下 N 句」上下文选择（视频车道）：弹窗选「上 N 句 / 下 N 句」
  /// 把当前正查字幕句之前/之后的 N 条 cue 作上下文整体设置进本视频会话级制卡草稿，
  /// 返回上下文句总数（上 N + 下 N）。mixin 的 [buildNestedPopupLayer] 据此非空回调让
  /// popup 渲染上下文选择器。
  @override
  Future<int> Function(int prevCount, int nextCount)?
      get onSetSentenceContextToDraft => _setSentenceContextToDraft;

  /// 把一条 cue 的画面/音频时间窗转成草稿可合并的区间。视频所有 cue 同属一个视频文件，
  /// [audioFileIndex] 统一用 0（合并恒成功，取 min start / max end）。null cue → null
  /// 区间（草稿据此退化为只合文本，不静默拼坏区间）。
  AudioPlaybackRange? _cueRange(AudioCue? cue) {
    if (cue == null) return null;
    return AudioPlaybackRange(
      audioFileIndex: 0,
      startMs: cue.startMs,
      endMs: cue.endMs,
    );
  }

  /// 以当前查词 cue（[_lastLookupCue]）为锚，在 [VideoPlayerController.cues]（按 startMs
  /// 升序）里取它之前 [prevCount] 条、之后 [nextCount] 条作上下文，整体设进草稿（覆盖
  /// 上次选择，不累积）。无 cue / 无控制器时清空上下文返回 0。
  Future<int> _setSentenceContextToDraft(int prevCount, int nextCount) async {
    final VideoPlayerController? controller = _controller;
    final AudioCue? anchor = _lastLookupCue;
    if (controller == null || anchor == null) {
      _miningDraft.setContext();
      return _miningDraft.length;
    }
    final List<AudioCue> cues = controller.cues;
    final int idx = cues.indexOf(anchor);
    if (idx < 0) {
      _miningDraft.setContext();
      return _miningDraft.length;
    }
    final int prevStart = (idx - prevCount).clamp(0, idx);
    final List<MiningDraftSentence> prev = <MiningDraftSentence>[
      for (int i = prevStart; i < idx; i++)
        MiningDraftSentence(
            sentence: cues[i].text, audioRange: _cueRange(cues[i])),
    ];
    final int nextEnd = (idx + 1 + nextCount).clamp(idx + 1, cues.length);
    final List<MiningDraftSentence> next = <MiningDraftSentence>[
      for (int i = idx + 1; i < nextEnd; i++)
        MiningDraftSentence(
            sentence: cues[i].text, audioRange: _cueRange(cues[i])),
    ];
    _miningDraft.setContext(prev: prev, next: next);
    return _miningDraft.length;
  }

  /// TODO-382「+句」可撤销（视频车道）：弹窗点「清空已加句子」清掉本会话累积的全部草稿
  /// 句，回传清空后的句数（恒 0）。不动字幕列表「选入词卡」的 cue 选择集（两套独立机制）。
  @override
  Future<int> Function()? get onClearSentenceDraftToDraft =>
      _clearSentenceDraft;

  Future<int> _clearSentenceDraft() async {
    _miningDraft.clear();
    return _miningDraft.length;
  }

  /// 「本次查词浮层是我们因查词而主动暂停了正在播放的视频」标记。
  ///
  /// 查词暂停 / 关浮层恢复与阅读器 [ReaderHibikiPage] 同源：浮层打开时若视频在播放则
  /// 暂停（让用户读词），浮层栈**全部关闭**后再自动恢复播放。video 页用
  /// [DictionaryPageMixin]（没有 reader 的 `onAllPopupsDismissed` 钩子），故用本标记 +
  /// 在 [_popNestedPopupAt] 这唯一的关栈汇聚点恢复，覆盖遮罩点击 / 返回键 / 浮层
  /// 滑动·Esc 全部关闭路径。仅当查词前视频确在播放才置位，避免把查词前本就暂停的
  /// 视频自动播起来；递归查词（已暂停，`isPlaying==false`）不会覆写它（BUG-072）。
  bool _pausedForLookup = false;

  /// 当前查词所在字幕句是否已被收藏（驱动查词浮层顶部收藏星标的实心/空心）。每次
  /// [_lookupAt] 成功后据 [_lastLookupSentence] 异步刷新。视频句子收藏走与书内同一
  /// [FavoriteSentenceRepository]（preferences JSON），来源标 [kFavoriteSentenceSourceVideo]。
  bool _currentVideoSentenceIsFavorited = false;

  /// 本视频已收藏句锚点的缓存集合（驱动字幕跳转列表行内收藏星标的实心/空心，TODO-152
  /// 子A）。同步查询需要（[VideoSubtitleJumpPanel.isCueFavorited] 每次重建调用），故缓存
  /// 而非每行异步查 DB。打开列表面板时 [_refreshFavoritedCueCache] 从 repo 拉一次，
  /// 行内收藏 toggle 后增量更新。新条目按 `bookUid + cue.startMs` 匹配；旧条目没有
  /// startMs 时保留 text-only 兼容键。
  final Set<String> _favoritedVideoSentences = <String>{};
  final Set<int> _selectedMiningCueStarts = <int>{};

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

  bool _autoAdvanceInFlight = false;
  String? _lastPrewarmedEpisodePath;

  /// 底部菜单（剧集/轨道/倍速/设置/字幕源）重入守卫：为真时已有一个 sheet 在开/在显，
  /// 快速重复点击不再叠开第二个。开 sheet 前置真，sheet 关闭（whenComplete）或异步早
  /// 返回时复位。修「点菜单/字幕点快了弹出两个」。
  bool _videoSheetOpen = false;

  /// 音量控件显示真相源（0..100，静音时为 0）（TODO-377 / TODO-438）。
  ///
  /// 底栏音量控件在 TODO-438 后只保留固定尺寸图标锚点（[_buildVolumeButton]），hover /
  /// click / tap 打开锚定按钮上方的紧凑浮层。底栏本身不内联滑条、不随 hover 改宽，仍保持
  /// 零布局位移。
  ///
  /// [VideoPlayerController.setVolume] 不发 [ChangeNotifier] 通知，控制条也不监听
  /// controller 的音量变化重建，故用本 notifier 作显示真相源：所有改音量入口（滑条拖动 /
  /// 滚轮 / 键盘音量键 / 静音切换 / media_kit 移动端竖滑）统一经 [_syncVolumeDisplay]
  /// 写它，[ValueListenableBuilder] 只重建音量图标 / 浮层子树，不重建整条。
  final ValueNotifier<double> _volumeDisplay = ValueNotifier<double>(100);

  /// 当前 video book 的可听音量记忆（0..100）。播放列表按整张 video book 共享；
  /// 每集仍只独立保存播放进度。
  double _playbackVolume = 100.0;
  double? _pendingVolumePersist;
  Timer? _volumePersistDebounce;
  double? _pendingSpeedPersist;
  Timer? _speedPersistDebounce;

  /// 换集加载代际计数：每次 [_loadEpisode] 自增并捕获本次序号；其慢路径（ffmpeg
  /// 枚举字幕源 + 解析 cue）跑完后若序号已被后续切集取代，则放弃应用，避免「播放中
  /// 途快速切集时旧的慢加载落地后覆盖新集字幕/视频」（用户报：切到第4集字幕/音画
  /// 对不上，疑似中途切换；本机不可复现，加此守卫兜底竞态）。
  int _episodeLoadSeq = 0;

  /// 当前播放的视频文件绝对路径（枚举字幕源用）；未 load 时为 null。
  String? _currentVideoPath;

  /// 远端模式（[_isRemote]）下 host 下发并下载到本地临时文件的那条外挂字幕路径；
  /// 无 host 字幕时为 null。远端没有本地视频文件，字幕菜单不能走 [_currentVideoPath]
  /// 的同目录枚举（恒 null → 早返回 → 点了没反应，#2），故单独记下这条 host 字幕，
  /// 让远端字幕菜单可在「关闭 / host 字幕 / 本地导入」三者间切换。
  String? _remoteSubtitlePath;
  List<RemoteVideoEmbeddedSubtitleTrack> _remoteEmbeddedSubtitleTracks =
      const <RemoteVideoEmbeddedSubtitleTrack>[];

  /// 当前选中的字幕源持久化值（外挂路径 / `embedded:<n>` / null=关闭）；
  /// 用于字幕源菜单高亮当前项。
  String? _currentSubtitleSource;

  /// 当前选中的音轨 id（libmpv `AudioTrack.id`）；null=未选过跟随默认。
  /// 多集换集时复用同一值（用户选了日语音轨，每集都用日语）。
  String? _currentAudioTrackId;

  bool _clipExportMarking = false;
  bool _clipExporting = false;
  int? _clipExportStartMs;
  String? _clipExportStartPath;
  int? _clipExportStartAudioStreamIndex;
  int _clipExportGeneration = 0;

  /// 音画延迟（毫秒）：字幕 cue 同步偏移，跨重启保留；换集复用同一值。
  int _delayMs = 0;

  /// 播放倍速：用户在设置面板调，跨重启保留；换集复用同一值（速度记忆）。
  double _playbackSpeed = 1.0;
  double? _longPressPreviousSpeed;

  /// 长按拖动调速的基准速（长按起点的固定加速速，TODO-338）。非空表示正处于一次长按
  /// 调速手势中；横向拖动以此为基准连续加减，松手清空。
  double? _longPressDragBaseSpeed;

  /// 当前字幕外观（全局偏好快照；设置面板改动后刷新）。
  VideoSubtitleStyle _subtitleStyle = VideoSubtitleStyle.defaults;
  VideoAsbplayerConfig _asbConfig = VideoAsbplayerConfig.defaults;

  /// Live 9-slot control button layout (TODO-274/312 phase 2). This is loaded
  /// from / saved to [AppModel.videoControlLayout], which shares the legacy pref
  /// key and auto-migrates old v1 blobs via [VideoControlLayout.decode]. The
  /// getter reads [_controlLayoutNotifier] so the current controls builder can
  /// rebuild immediately after [_setVideoControlLayout].
  VideoControlLayout get _controlLayout => _controlLayoutNotifier.value;

  /// 桌面端是否把原生窗口锁定为当前视频比例。移动端窗口不可改尺寸。
  /// 初始 false 与偏好默认对齐（回归修复）：偏好快照在 init 赋值前不主动锁窗口，
  /// 消除「赋值前 stale true 抢锁」的瞬态窗口。
  bool _lockWindowAspectRatio = false;
  double? _appliedWindowAspectRatio;

  /// 画面缩放/比例模式（窗口 + 全屏 [Video] fit 共用；TODO-152 子B）。新安装默认
  /// contain/适应；init 时读全局偏好快照，已有用户偏好 cover/fill 会按原值恢复，
  /// 设置面板改动经 [_setVideoFitMode] 落盘 + setState 重建 Video。
  VideoFitMode _videoFitMode = VideoFitMode.contain;

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
    _subtitleListVisible.value = widget.initialSubtitleListVisible;
    // TODO-364 单一真相源：字幕避让可见性恒由 media_kit 真实可见性
    // （[_mediaKitControlsVisible]）+ 三个门控派生。订阅这四个输入，任一变化即重派生
    // [_videoControlsVisible]，杜绝旧镜像与真实控制条相位反。
    _mediaKitControlsVisible.addListener(_applyControlsVisibilityFromMediaKit);
    _immersiveLocked.addListener(_applyControlsVisibilityFromMediaKit);
    _videoSidePanel.addListener(_applyControlsVisibilityFromMediaKit);
    _videoControlPopover.addListener(_applyControlsVisibilityFromMediaKit);
    _subtitleListVisible.addListener(_applyControlsVisibilityFromMediaKit);
    _videoControlEditMode.addListener(_applyControlsVisibilityFromMediaKit);
    WidgetsBinding.instance.addObserver(this);
    _exitFlushCallback = ExitFlushRegistry.instance.register(
      _flushAllForProcessExit,
    );
    // TODO-057: 进入视频即快照系统屏幕亮度（移动端），供亮度手势初值与退出还原；
    // 桌面 no-op。
    unawaited(_ensureEnterBrightness());
    // TODO-099: 进入视频页强制横屏（移动端），退出 [dispose] 还原；桌面 no-op。
    unawaited(_lockLandscapeForVideo());
    // TODO-158/BUG-219: 进入视频页显式持有「沉浸隐藏系统栏」所有权（移动端）。原先
    // 只靠 [AppModel.openMedia] 在打开媒体时一次性设 immersiveSticky（书 / 视频共用
    // 入口），从不重申 → 后台返回 / 通知栏交互 / 全屏路由后系统栏残留。退出由
    // [AppModel.closeMedia] 的 setHomeShellSystemUiMode 还原；桌面 no-op。
    unawaited(_applyVideoImmersiveMode());
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
        unawaited(_flushPersistedVideoSpeed());
        unawaited(_flushPersistedVideoVolume());
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        // 真后台 / 熄屏：落库 + 暂停观看计时器，避免把后台时长计入。stop() 内部先 flush
        // 退出瞬间的部分窗口（≤60s）再 cancel，不丢已观看时长。
        unawaited(_controller?.flushPosition());
        unawaited(_flushPersistedVideoSpeed());
        unawaited(_flushPersistedVideoVolume());
        _watchTracker?.stop();
      case AppLifecycleState.resumed:
        // 回前台：重启观看计时器（start() 重置 _tickStart=now，下一窗从此刻起算）。
        _watchTracker?.start();
        // TODO-158/BUG-219: 回前台重申沉浸隐藏系统栏（移动端）。后台 / 通知栏下拉 /
        // 多任务切回后 Android 会把系统栏恢复显示，immersiveSticky 只在进入时设一次
        // 不会自动复申 → 这里主动重设，保证「一直隐藏」。桌面 no-op。
        unawaited(_applyVideoImmersiveMode());
        // 切窗 / 系统对话框返回（TODO-040 ①）：窗口重新激活时若键盘所有权仍属
        // 本页（页面或其全屏路由是当前路由、无查词浮层），把焦点收回视频——
        // OS 层焦点丢失后 Flutter 不保证归还到原节点。
        _reclaimVideoFocusIfOwned();
      case AppLifecycleState.detached:
        break;
    }
  }

  /// 进程退出统一 flush（TODO-086/BUG-191）。把当前播放位置写穿（[flushPosition]
  /// 读 libmpv position，退出期 player 仍存活，安全），并 stop 观看计时器把退出
  /// 瞬间的部分观看窗口落库。两步都 await，退出路径据此保证统计/进度在 exit(0)
  /// 前提交。未 load（无 controller / tracker）时 no-op 安全。
  Future<void> _flushAllForProcessExit() async {
    await _flushPersistedVideoSpeed();
    await _flushPersistedVideoVolume();
    await _controller?.flushPosition();
    await _watchTracker?.stop();
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
    _playbackVolume = _readPersistedVolume();
    _subtitleStyle = VideoSubtitleStyle.decode(appModel.videoSubtitleStyle);
    _asbConfig = VideoAsbplayerConfig.decode(appModel.videoAsbplayerConfig);
    _controlLayoutNotifier.value = appModel.videoControlLayout;
    _lockWindowAspectRatio = appModel.videoLockWindowAspectRatio;
    _videoFitMode = appModel.videoFitMode;

    // 解析播放列表（若有）。非空则按 currentEpisode 载对应集；否则走单视频路径。
    final String? playlistJson = row.playlistJson;
    if (playlistJson != null && playlistJson.isNotEmpty) {
      final List<dynamic> raw = jsonDecode(playlistJson) as List<dynamic>;
      _episodes = raw
          .map((dynamic e) => PlaylistEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    }

    if (_episodes.isNotEmpty) {
      final int idx = (widget.initialEpisodeIndex ?? row.currentEpisode)
          .clamp(0, _episodes.length - 1);
      if (widget.initialEpisodeIndex != null && idx != row.currentEpisode) {
        unawaited(widget.repo.updateCurrentEpisode(widget.bookUid, idx));
      }
      // 每集各记自己的进度：恢复到 currentEpisode 那集的 entry.positionMs
      // （取代旧的「整个 VideoBook 一个 lastPositionMs」）。
      await _loadEpisode(
        idx,
        initialPositionMs:
            widget.initialCueStartMs ?? _episodes[idx].positionMs,
        startIntent: widget.initialCueStartMs == null
            ? EpisodeStartIntent.initialOpen
            : EpisodeStartIntent.explicitCue,
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
    _playbackVolume = _readPersistedVolume();
    _subtitleStyle = VideoSubtitleStyle.decode(appModel.videoSubtitleStyle);
    _asbConfig = VideoAsbplayerConfig.decode(appModel.videoAsbplayerConfig);
    _controlLayoutNotifier.value = appModel.videoControlLayout;

    try {
      final RemoteVideoStreamUrls urls = await client.remoteVideoStreamUrls(
        info.id,
      );
      _remoteEmbeddedSubtitleTracks = urls.embeddedSubtitleTracks;
      String? externalSub;
      List<AudioCue> cues = const <AudioCue>[];
      if (urls.subtitleUrl != null) {
        final Directory temp = await getTemporaryDirectory();
        final File subtitle = File(
          p.join(
            temp.path,
            _remoteSubtitleTempFileName(info.id, urls.subtitleFileName),
          ),
        );
        await client.getRemoteVideoSubtitle(info.id, subtitle);
        externalSub = subtitle.path;
        _remoteSubtitlePath = subtitle.path;
        cues = await _loadExternalSubtitleCues(subtitle.path, info.id);
      }
      await _applyLoad(
        videoPath: null,
        mediaUri: urls.streamUrl,
        cues: cues,
        title: info.title,
        // TODO-559: 远端断点恢复——读 per-book prefs 存的上次位置（无则 0 从头）。
        initialPositionMs: _readPersistedRemotePosition(),
        startIntent: EpisodeStartIntent.initialOpen,
        externalSubtitlePath: externalSub,
      );
    } catch (e, stack) {
      debugPrint('[VideoHibikiPage] remote video load failed: $e\n$stack');
      if (mounted) setState(() => _failed = true);
    }
  }

  /// per-book 播放倍速偏好 key（速度记忆，跨重启保留）。
  String get _speedPrefKey => 'video_speed_${widget.bookUid}';

  /// per-book 播放音量偏好 key（音量记忆，播放列表按整张 video book 共享）。
  String get _volumePrefKey => 'video_volume_${widget.bookUid}';

  /// 读 per-book 持久化倍速（无则 1.0）。
  double _readPersistedSpeed() {
    final double v =
        (appModel.prefsRepo.getPref(_speedPrefKey, defaultValue: 1.0) as num)
            .toDouble();
    return v.clamp(0.25, 4.0);
  }

  /// 读 per-book 持久化音量（无则 100）。
  double _readPersistedVolume() {
    final Object? raw =
        appModel.prefsRepo.getPref(_volumePrefKey, defaultValue: 100.0);
    final double v = raw is num
        ? raw.toDouble()
        : double.tryParse(raw?.toString() ?? '') ?? 100.0;
    return v.clamp(0.0, 100.0).toDouble();
  }

  /// per-book 远端视频断点位置偏好 key（TODO-559）。
  ///
  /// 在线远端视频（[_isRemote]）在 client 本地 DB 没有 VideoBooks 行（书架不收录
  /// 远端在线视频，[home_video_page._openRemote] 直接 push 播放页不 upsert），因此
  /// 本地视频走 `VideoBooks.lastPositionMs` 的进度链路对远端不可用。沿用 speed/volume
  /// 同款 per-book prefs 范式（落 Drift `preferences` 表，跨重启保留），key 用稳定的
  /// `widget.bookUid`（= 远端 `RemoteVideoInfo.id` = host 端文件名派生的 bookUid，
  /// 每次列举不变，见 app_model_library_host_service `RemoteVideoInfo.id = row.bookUid`），
  /// 避免为远端在线视频建 VideoBooks 行污染书架 / 触发资产 GC / 同步逻辑。
  String get _remotePositionPrefKey =>
      'video_remote_position_${widget.bookUid}';

  /// 读 per-book 远端断点位置（无则 0，从头）。
  int _readPersistedRemotePosition() {
    final Object? raw =
        appModel.prefsRepo.getPref(_remotePositionPrefKey, defaultValue: 0);
    final int v =
        raw is num ? raw.toInt() : int.tryParse(raw?.toString() ?? '') ?? 0;
    return v < 0 ? 0 : v;
  }

  /// 远端视频断点位置持久化（controller 每秒至多一次回调 / flush / dispose）。
  ///
  /// 与本地 [_persistPosition] 对应：远端无播放列表（[_episodes] 恒空）也无 DB 行，
  /// 按稳定 bookUid 落 prefs。controller 用 `widget.bookUid` 调 [onPositionWrite]，
  /// 故回调 [uid] 即构造 [_remotePositionPrefKey] 用的同一 bookUid。
  Future<void> _persistRemotePosition(String uid, int posMs) =>
      appModel.prefsRepo.setPref('video_remote_position_$uid', posMs);

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
          int? graphicStreamIndex,
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
      initialPositionMs: widget.initialCueStartMs ?? row.lastPositionMs,
      startIntent: widget.initialCueStartMs == null
          ? EpisodeStartIntent.initialOpen
          : EpisodeStartIntent.explicitCue,
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
    //
    // BUG-165: 换集（[crossEpisode]）时该捷径必须只接管**真正住在别处的导入字幕**
    // ——若持久化路径与新集视频**同目录**，那是上一集自带的同目录 sidecar
    // （如 `EP01.ja.srt`），不能原样沿用到 `EP02`，否则字幕卡在上一集。故换集时改用
    // [shouldReusePersistedSubtitleAcrossEpisode]（按目录归属区分），同目录 sidecar 落
    // 回下面的同目录枚举 + [pickEpisodeSubtitleSource] 按新集名重新匹配。单视频恢复
    // （非换集）同一视频本就该恢复同一字幕，保持原 [isImportedExternalSubtitlePath] 判定。
    final bool takeImportedShortcut = crossEpisode
        ? shouldReusePersistedSubtitleAcrossEpisode(persisted, videoPath)
        : isImportedExternalSubtitlePath(persisted);
    if (takeImportedShortcut && File(persisted).existsSync()) {
      final SubtitleSource external = SubtitleSource.external(
        externalPath: persisted,
        label: p.basename(persisted),
      );
      final List<AudioCue> cues = await loadCuesForSource(
        external,
        videoPath,
        widget.bookUid,
      );
      if (cues.isNotEmpty) {
        return (
          persisted: external.toPersistedValue(),
          cues: cues,
          graphicStreamIndex: null,
        );
      }
      // 文件在但解析空（坏字幕）：落回下面的同目录枚举，别让一个坏导入挡住别的源。
    }

    final List<SubtitleSource> sources = await listAllSubtitleSources(
      videoPath,
      langCode: _targetLangCode,
    );
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

    final List<AudioCue> cues = await loadCuesForSource(
      chosen,
      videoPath,
      widget.bookUid,
    );
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
    required List<AudioCue> currentCues,
  }) async {
    final List<SubtitleSource> sources = await listAllSubtitleSources(
      videoPath,
      langCode: _targetLangCode,
    );
    return includeCurrentPersistedSubtitleForMenu(
      sources,
      videoPath: videoPath,
      bookUid: widget.bookUid,
      currentSubtitleSource: currentSubtitleSource,
      currentCues: currentCues,
    );
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
    required EpisodeStartIntent startIntent,
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
      debugPrint(
        '[video-episode] superseded: ep$index seq=$seq '
        'cur=$_episodeLoadSeq — skip apply',
      );
      return;
    }
    // 诊断（用户报「切到第4集字幕/音画对不上」，本机不可复现）：记录实际选中的字幕源
    // 与解析出的 cue 数 + 首句，便于真机切集后回看日志锁定是否选错源/空 cue/错集。
    debugPrint(
      '[video-episode] load ep$index "${episode.title}" '
      'path=${episode.path} subSrc=$externalSub cues=${cues.length}'
      '${cues.isNotEmpty ? ' first=[${cues.first.startMs}ms]${cues.first.text}' : ''}',
    );

    _currentEpisode = index;
    await _applyLoad(
      videoPath: episode.path,
      cues: cues,
      title: episode.title,
      initialPositionMs: initialPositionMs,
      startIntent: startIntent,
      externalSubtitlePath: externalSub,
      renderGraphicStreamIndex: graphicStreamIndex,
    );
  }

  /// 探测视频同目录 sidecar 字幕并解析为 cue（无则 null）。
  ///
  /// 按 app 学习语言优先（学日语 → `.ja.srt > .ja.ass > … > .srt > .ass …`，
  /// 见 [findSidecarSubtitle]）；按扩展名路由统一字幕 parser。IO + 解析失败静默返回 null。
  Future<({String path, List<AudioCue> cues})?> _detectSidecar(
    String videoPath,
    String bookUid,
  ) async {
    final String? sidecarPath = findSidecarSubtitle(
      videoPath,
      langCode: _targetLangCode,
    );
    if (sidecarPath == null) return null;
    try {
      final SubtitleFormat? format = subtitleFormatForPath(sidecarPath);
      if (format == null) return null;
      final String text = await readTextWithEncoding(File(sidecarPath));
      final List<AudioCue> cues = await parseSubtitleContentAsync(
        format,
        content: text,
        bookUid: bookUid,
      );
      if (cues.isEmpty) return null;
      return (path: sidecarPath, cues: cues);
    } catch (e) {
      debugPrint('[VideoHibikiPage] sidecar parse failed: $e');
      return null;
    }
  }

  Future<void> _loadDanmakuForVideo(String? videoPath) async {
    final int seq = ++_danmakuLoadSeq;
    if (mounted) {
      setState(() => _danmakuItems = const <VideoDanmakuItem>[]);
    }
    if (videoPath == null || !appModel.videoDanmakuEnabled) return;

    final String? sidecarPath = findDanmakuSidecar(videoPath);
    if (sidecarPath != null) {
      final VideoDanmakuLoadResult local =
          await loadDanmakuSidecarFile(File(sidecarPath));
      if (seq != _danmakuLoadSeq || !mounted) return;
      if (local.tooLarge) {
        debugPrint(
          '[VideoDanmaku] local sidecar too large: ${local.sourcePath}',
        );
      } else if (local.items.isNotEmpty) {
        setState(() => _danmakuItems = local.items);
        debugPrint(
          '[VideoDanmaku] loaded ${local.items.length} local comments '
          'from ${local.sourcePath}',
        );
        return;
      } else if (local.error != null) {
        debugPrint('[VideoDanmaku] local sidecar parse failed: ${local.error}');
      }
    }

    if (!appModel.videoDanmakuOnlineEnabled) return;
    final File file = File(videoPath);
    if (!file.existsSync()) return;
    final DandanplayClient client = DandanplayClient();
    try {
      DandanplayFetchResult result;
      final int? savedEpisodeId =
          appModel.getVideoDanmakuEpisodeId(widget.bookUid);
      if (savedEpisodeId != null) {
        final DandanplayMatch cached =
            DandanplayMatch(episodeId: savedEpisodeId);
        final List<VideoDanmakuItem> cachedItems =
            await client.fetchCommentsForMatch(cached);
        if (cachedItems.isNotEmpty) {
          result = DandanplayFetchResult(
            status: DandanplayFetchStatus.hit,
            items: cachedItems,
            match: cached,
          );
        } else {
          result = await client.fetchBestDanmakuForFile(file);
        }
      } else {
        result = await client.fetchBestDanmakuForFile(file);
      }
      if (seq != _danmakuLoadSeq || !mounted) return;
      if (result.status == DandanplayFetchStatus.hit &&
          result.items.isNotEmpty) {
        final int? episodeId = result.match?.episodeId;
        if (episodeId != null) {
          await appModel.setVideoDanmakuEpisodeId(widget.bookUid, episodeId);
        }
        if (seq != _danmakuLoadSeq || !mounted) return;
        setState(() => _danmakuItems = result.items);
        debugPrint(
          '[VideoDanmaku] loaded ${result.items.length} Dandanplay comments '
          'episode=${episodeId ?? savedEpisodeId}',
        );
      } else {
        debugPrint(
          '[VideoDanmaku] online fallback: ${result.status} '
          'matches=${result.matches.length}',
        );
      }
    } catch (e) {
      debugPrint('[VideoDanmaku] online load failed: $e');
    } finally {
      client.close();
    }
  }

  void _clearDanmakuForCurrentVideo() {
    ++_danmakuLoadSeq;
    if (!mounted) {
      _danmakuItems = const <VideoDanmakuItem>[];
      return;
    }
    setState(() => _danmakuItems = const <VideoDanmakuItem>[]);
  }

  Future<void> _setVideoDanmakuEnabled(bool value) async {
    await appModel.setVideoDanmakuEnabled(value);
    if (!mounted) return;
    if (value) {
      unawaited(_loadDanmakuForVideo(_currentVideoPath));
    } else {
      _clearDanmakuForCurrentVideo();
    }
  }

  Future<void> _setVideoDanmakuOnlineEnabled(bool value) async {
    await appModel.setVideoDanmakuOnlineEnabled(value);
    if (!mounted) return;
    if (appModel.videoDanmakuEnabled) {
      unawaited(_loadDanmakuForVideo(_currentVideoPath));
    } else {
      setState(() {});
    }
  }

  Future<void> _setVideoDanmakuMaxActive(int value) async {
    await appModel.setVideoDanmakuMaxActive(value);
    if (!mounted) return;
    setState(() {});
  }

  Future<List<AudioCue>> _loadExternalSubtitleCues(
    String path,
    String bookUid,
  ) async {
    try {
      final SubtitleFormat? format = subtitleFormatForPath(path);
      if (format == null) return const <AudioCue>[];
      final String text = await readTextWithEncoding(File(path));
      return await parseSubtitleContentAsync(
        format,
        content: text,
        bookUid: bookUid,
      );
    } catch (e) {
      debugPrint('[VideoHibikiPage] external subtitle parse failed: $e');
      return const <AudioCue>[];
    }
  }

  void _handlePlaybackCompleted() {
    if (_autoAdvanceInFlight) return;
    if (!mounted) return;
    final int? nextEpisode = nextPlaylistIndexAfterCompletion(
      _episodes,
      _currentEpisode,
    );
    if (nextEpisode == null) return;
    _autoAdvanceInFlight = true;
    unawaited(() async {
      try {
        if (!mounted) return;
        await _switchEpisode(
          nextEpisode,
          intent: EpisodeStartIntent.autoAdvance,
        );
      } catch (e, stack) {
        debugPrint('[VideoHibikiPage] auto-advance failed: $e\n$stack');
      } finally {
        _autoAdvanceInFlight = false;
      }
    }());
  }

  /// 共享 load 装配：复用或新建 controller，载入视频 + cue，挂位置持久化回调。
  Future<void> _applyLoad({
    required String? videoPath,
    String? mediaUri,
    required List<AudioCue> cues,
    required String title,
    required int initialPositionMs,
    required EpisodeStartIntent startIntent,
    String? externalSubtitlePath,
    int? renderGraphicStreamIndex,
  }) async {
    final VideoPlayerController controller =
        _controller ?? VideoPlayerController();
    final VideoMpvConfig mpvConfig = VideoMpvConfig.decode(
      appModel.videoMpvConfig,
    );
    // 解析启用的 mpv 着色器为绝对路径（桌面 libmpv 生效，移动端最终静默）。
    // 「画质增强」主开关关闭时保留持久化勾选，但运行时旁路所有 shader。
    final List<String> shaderPaths = mpvConfig.highQuality
        ? await resolveEnabledShaderPaths(
            decodeEnabledShaders(appModel.videoShadersEnabled),
          )
        : const <String>[];
    controller.setOnCompleted(_handlePlaybackCompleted);
    try {
      await controller.load(
        bookUid: widget.bookUid,
        videoFile: videoPath == null ? null : File(videoPath),
        mediaUri: mediaUri,
        cues: cues,
        initialPositionMs: initialPositionMs,
        startIntent: startIntent,
        initialSpeed: _playbackSpeed,
        initialVolume: _playbackVolume,
        externalSubtitlePath: externalSubtitlePath,
        renderGraphicStreamIndex: renderGraphicStreamIndex,
        shaderPaths: shaderPaths,
        mpvConfig: mpvConfig,
        autoPlay: true,
        onEmbeddedSubtitleAutoLoad: _handleEmbeddedSubtitleAutoLoad,
      );
    } catch (e, stack) {
      debugPrint('[VideoHibikiPage] video load failed: $e\n$stack');
      if (_controller == null) controller.dispose();
      if (mounted) setState(() => _failed = true);
      return;
    }
    _syncVolumeDisplay(controller.volume);
    // 应用持久化的音画延迟（换集复用同一值；load 不重置 delay）。
    controller.setDelayMs(_delayMs);
    controller.setPauseAtSubtitleEnd(_asbConfig.pauseAtSubtitleEnd);
    // TODO-559: 远端断点保存——远端无 DB 行，按 bookUid 落 prefs（原为 null 不存）。
    controller.onPositionWrite =
        _isRemote ? _persistRemotePosition : _persistPosition;
    if (!mounted) {
      if (_controller == null) controller.dispose();
      return;
    }
    controller.removeListener(_syncWindowAspectRatioLock);
    controller.addListener(_syncWindowAspectRatioLock);
    _attachControllerChapterListener(controller);
    // 标题先推给响应式 notifier，让全屏路由顶栏（不随页面 setState 重建）也跟上（BUG-120）。
    _titleNotifier.value = title;
    // 音量控件显示真相源对齐 controller 实际音量（换集复用同一 controller，TODO-377/438）。
    _syncVolumeDisplay(controller.volume);
    final bool clipExportSourceChanged = _currentVideoPath != videoPath;
    setState(() {
      if (clipExportSourceChanged) _clearClipExportState();
      _controller = controller;
      _hasChapters = controller.chapters.isNotEmpty;
      _title = title;
      _failed = false;
      _currentVideoPath = videoPath;
      // 外挂字幕路径即持久化值；内嵌自动加载（externalSubtitlePath==null）时
      // 当前选中由 _currentSubtitleSource 保留（菜单切换时再写）。
      _currentSubtitleSource = externalSubtitlePath ?? _currentSubtitleSource;
    });
    _syncControllerChapterAvailability(controller);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refocusVideo();
    });
    _syncWindowAspectRatioLock();

    // 视频就绪后预热查词浮层（BUG-094）：seed 一个常驻隐藏热 WebView，全程复用，
    // 查词不再每次冷加载白屏。放成功分支（缺书/错误态不预热，无视频无需查词）。
    _seedWarmPopup();
    // TODO-301/BUG-264: fill the favorited-sentence cache once on video
    // open so the bottom subtitle overlay's favorite star
    // ([_isCueFavorited] reads [_favoritedVideoSentences]) shows for
    // already-favorited cues even before the subtitle list is ever opened.
    unawaited(_refreshFavoritedCueCache());
    if (videoPath != null) {
      // TODO-011: large REMUX containers can spend many seconds demuxing text
      // embedded subtitles on the first switch. Start the shared cache fill
      // only after playback has opened so UI/video startup is not blocked.
      unawaited(prewarmEmbeddedSubtitleCache(videoPath));
      unawaited(_loadDanmakuForVideo(videoPath));
    } else {
      unawaited(_loadDanmakuForVideo(null));
    }
    _prewarmNextEpisodeSubtitleCache();

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
          dateKey: dateKey,
          hour: hour,
          deltaMs: deltaMs,
        ),
      )
        ..attach(controller)
        ..start();
    }

    // 恢复用户选过的音轨（含多集换集复用）：audioTracks 在 player open 后才填充，
    // 延迟一拍再读，按 id 匹配；找不到（轨不存在/未选过）就跳过保留 libmpv 默认。
    unawaited(_restoreAudioTrack(controller));
  }

  void _handleEmbeddedSubtitleAutoLoad(
    DefaultEmbeddedSubtitleLoadResult result,
  ) {
    if (!mounted) return;
    if (result.status == DefaultEmbeddedSubtitleLoadStatus.loaded) {
      final SubtitleSource? source = result.source;
      if (source != null) {
        setState(() => _currentSubtitleSource = source.toPersistedValue());
      }
      return;
    }
    if (!result.shouldNotifyFailure) return;
    final String label = result.source?.label ?? t.video_menu_subtitle_track;
    _showOsd(t.video_subtitle_load_failed(label: label));
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
  String _encodeEpisodes() =>
      jsonEncode(_episodes.map((PlaylistEntry e) => e.toJson()).toList());

  void _prewarmNextEpisodeSubtitleCache() {
    final String? path = nextPlaylistPathToPrewarm(
      entries: _episodes,
      currentIndex: _currentEpisode,
      lastPrewarmedPath: _lastPrewarmedEpisodePath,
    );
    if (path == null) return;
    _lastPrewarmedEpisodePath = path;
    unawaited(prewarmEmbeddedSubtitleCache(path));
  }

  String _safeFileName(String input) =>
      input.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');

  String _remoteSubtitleTempFileName(String videoId, String? hostFileName) {
    final String fallback = 'hibiki_remote_${_safeFileName(videoId)}.srt';
    if (hostFileName == null || hostFileName.trim().isEmpty) return fallback;
    final String baseName = p.basename(hostFileName.trim());
    if (subtitleFormatForPath(baseName) == null) return fallback;
    final String stem = _safeFileName(p.basenameWithoutExtension(baseName));
    final String safeStem = stem.isEmpty ? _safeFileName(videoId) : stem;
    return 'hibiki_remote_$safeStem${p.extension(baseName)}';
  }

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
    _showOsd(
      t.video_audio_track_switched(
        label: _trackLabel(track.title, track.language, track.id),
      ),
    );
  }

  /// 切到第 [index] 集：保存当前集进度 → 持久化 currentEpisode → 按 [intent]
  /// 决定目标集保存位置是否恢复 + 重新 load 新集字幕。
  ///
  /// 当前集进度由 125ms tick 经 [_persistPosition] 已实时记进 `_episodes[当前集]`
  /// 并落库；切集前再补记一次当前播放位置（覆盖 tick 整秒节流的尾差），确保下次
  /// 回到本集精确续播。
  Future<void> _switchEpisode(
    int index, {
    required EpisodeStartIntent intent,
  }) async {
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
      startIntent: intent,
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
                    : Text(
                        '${i + 1}',
                        style: TextStyle(
                          color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                        ),
                      ),
                title: Text(
                  _episodes[i].title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _switchEpisode(i, intent: EpisodeStartIntent.listSelect);
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

  /// 翻转字幕跳转列表面板可见性（TODO-069/TODO-314；裸 L 键 / 控制条入口按钮）。
  ///
  /// asbplayer 式 transcript 面板：右侧出现当前视频的所有字幕句子，点某句 → seek 到该
  /// 句对应画面。**走 push-aside 布局**（[_videoWithSubtitlePanel] / [_subtitleListVisible]，
  /// `Row[Expanded(video), 面板列]`）真把画面挤窄到左侧、不浮层遮挡（TODO-314 根因：此前误经
  /// `_showVideoSidePanel(subtitleList)` 进 overlay 系统，push-aside 成死代码）。与其它浮层
  /// 互斥：开字幕列表先关任何打开的浮层（[_videoSidePanel]）。打开时唤醒控制条让用户看到入口。
  void _toggleSubtitleJumpList() {
    final bool next = !_subtitleListVisible.value;
    if (next) {
      _clearRailHover();
      // 与浮层互斥：开 push-aside 字幕列表前关掉任何打开的浮层（设置/音轨/倍速等）。
      _hideVideoControlEditOverlay(revealControls: false);
      _subtitleListVisible.value = true;
      if (_videoSidePanel.value != null) {
        _hideVideoSidePanel();
      }
      // TODO-566：打开字幕列表时不再异步整表重查收藏 DB。收藏缓存
      // _favoritedVideoSentences 是单一真相源：视频 load 时由收藏缓存刷新方法预填
      // 一次，之后列表行 toggle / 查词浮层 toggle 都增量维护它。原先打开面板时再异步
      // 刷新一次，让面板先以旧缓存渲染、DB 往返后才 setState 重建，已收藏行的实心星标
      // 要「等一会」才出现。改为纯读已填充缓存 → 星标随面板同帧 O(1) 渲染，无异步延迟。
      _markControlsVisible(false);
      _refocusVideo();
    } else {
      _clearSelectedMiningCues();
      _subtitleListVisible.value = false;
      _pokeControlsVisible();
      _refocusVideo();
    }
  }

  /// 点字幕跳转列表里某句：seek 到该 cue 起点（复用现成 [VideoPlayerController.skipToCue]）
  /// 并唤醒控制条。不关面板——用户常连点多句逐句跳，保持列表常驻（与 asbplayer 一致）。
  void _handleSubtitleJumpTap(AudioCue cue) {
    _pokeControlsVisible();
    unawaited(_controller?.skipToCue(cue));
  }

  /// 点字幕跳转列表里某句的文本 → 从点击命中的字符起查词（TODO-340，修 TODO-278 的
  /// 「恒从句首」回归）。复用底部字幕字符点击的同一条查词链路 [_lookupAt]（暂停视频 →
  /// 推与阅读器 / 词典页同款查词浮层），[graphemeIndex] 为列表项点击位置命中的 grapheme
  /// 下标（与底部字幕逐字查词同语义），[charRect] 为被点字符的屏幕矩形供浮层定位。
  /// 沉浸锁不允许查词时早返回（与字幕字符点击 [_handleSubtitleLookupTap] 同门控）。
  void _handleSubtitleListLookup(
    AudioCue cue,
    int graphemeIndex,
    Rect charRect,
  ) {
    if (!_immersiveAllowsLookup) return;
    final String sentence = cue.text;
    if (sentence.trim().isEmpty) return;
    unawaited(_lookupAt(sentence, graphemeIndex, charRect));
  }

  /// 翻转锁定 / 沉浸模式（TODO-101；锁屏按钮 / Shift+L 快捷键 / 常驻解锁按钮共用）。
  ///
  /// 进入：抑制 media_kit 控制条对鼠标 hover / 点击的响应（[_buildVideoControlsInner]
  /// 里 gate `AdaptiveVideoControls` 的指针），顶/底栏按钮不再弹；查词与快捷键不受影响。
  /// 退出：恢复控制条响应，并 [_pokeControlsVisible] 立刻把控制条唤回一次（给用户「已解锁」
  /// 的即时反馈，且 poke 在解锁后才放行）。可见性走 [_immersiveLocked]（[ValueNotifier]，
  /// 全屏路由也生效）。
  void _toggleImmersiveLock() {
    final bool next = !_immersiveLocked.value;
    _clearRailHover();
    _immersiveLocked.value = next;
    // 翻转后把视频左侧锁 / 解锁按钮唤回一次（TODO-126）：进入沉浸即露出解锁口、退出沉浸
    // 即露出锁按钮，给用户即时反馈；随后照常 2s 淡出。
    _pokeLockButton();
    if (next) {
      _showOsd(t.video_immersive_locked, icon: Icons.lock_outline);
      // 锁定后 media_kit 控制条不再弹（指针被 IgnorePointer 挡），镜像同步收起、字幕
      // 落回用户位置基线（无控制条可遮挡，不需避让；TODO-129）。
      // _markControlsVisible(false) 在锁态分支里会同时 _setCursorHidden(true)（TODO-318）。
      _markControlsVisible(false);
    } else {
      _showOsd(t.video_immersive_unlocked, icon: Icons.lock_open_outlined);
      // 解锁瞬间把控制条唤回（poke 在 _immersiveLocked 复位后才放行），让用户立刻
      // 看到顶/底栏回来、确认已退出沉浸模式。光标也同步唤回（即时反馈，TODO-318）。
      _setCursorHidden(false);
      _pokeControlsVisible();
    }
  }

  VideoImmersiveMode get _videoImmersiveMode => appModel.videoImmersiveMode;

  bool get _immersiveAllowsFullControls =>
      !_immersiveLocked.value || _videoImmersiveMode == VideoImmersiveMode.full;

  bool get _immersiveAllowsDoubleTapSeek =>
      !_immersiveLocked.value ||
      _videoImmersiveMode == VideoImmersiveMode.full ||
      _videoImmersiveMode == VideoImmersiveMode.seekAndLookup;

  bool get _immersiveAllowsLookup =>
      !_immersiveLocked.value ||
      _videoImmersiveMode == VideoImmersiveMode.full ||
      _videoImmersiveMode == VideoImmersiveMode.seekAndLookup ||
      _videoImmersiveMode == VideoImmersiveMode.lookupOnly;

  void _runWhenImmersiveAllowsFullControls(VoidCallback action) {
    if (!_immersiveAllowsFullControls) return;
    action();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final ExitFlushCallback? exitFlush = _exitFlushCallback;
    if (exitFlush != null) {
      ExitFlushRegistry.instance.unregister(exitFlush);
      _exitFlushCallback = null;
    }
    _volumePersistDebounce?.cancel();
    unawaited(_flushPersistedVideoVolume());
    _speedPersistDebounce?.cancel();
    unawaited(_flushPersistedVideoSpeed());
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
    _volumeDisplay.dispose();
    _watchTracker?.dispose();
    _watchTracker = null;
    _controller?.removeListener(_syncWindowAspectRatioLock);
    _detachControllerChapterListener();
    _controller?.setOnCompleted(null);
    unawaited(_clearWindowAspectRatioLock());
    // TODO-057: 退出播放器还原屏幕亮度——把进页快照写回（iOS 系统级亮度），未
    // 取过快照时 Android 侧设回「跟随系统」(-1)。防止把用户系统亮度永久留在拖动后值。
    unawaited(_brightness.restore(previous: _enterBrightness));
    // TODO-099: 退出视频页还原屏幕方向允许态（移动端），不把其他页锁死在横屏；桌面 no-op。
    unawaited(_restoreOrientationOnExit());
    _clearClipExportState();
    _controller?.dispose();
    _videoFocusNode.dispose();
    _titleNotifier.dispose();
    // TODO-364：先摘控制条可见性派生监听，再 dispose 各 notifier（监听回调读多个 notifier，
    // 顺序错会在 dispose 后回调里触碰已释放对象）。
    _mediaKitControlsVisible
        .removeListener(_applyControlsVisibilityFromMediaKit);
    _immersiveLocked.removeListener(_applyControlsVisibilityFromMediaKit);
    _videoSidePanel.removeListener(_applyControlsVisibilityFromMediaKit);
    _videoControlPopover.removeListener(_applyControlsVisibilityFromMediaKit);
    _subtitleListVisible.removeListener(_applyControlsVisibilityFromMediaKit);
    _videoControlEditMode.removeListener(_applyControlsVisibilityFromMediaKit);
    _subtitleListVisible.dispose();
    _videoSidePanel.dispose();
    _controlPopoverHideTimer?.cancel();
    _videoControlPopover.dispose();
    _videoControlEditMode.dispose();
    _controlLayoutNotifier.dispose();
    _immersiveLocked.dispose();
    _lockButtonHideTimer?.cancel();
    _lockButtonVisible.dispose();
    _lockButtonHovered.dispose();
    _osdTimer?.cancel();
    _osdNotifier.dispose();
    _levelHudTimer?.cancel();
    _levelHudNotifier.dispose();
    _mediaKitControlsVisible.dispose();
    _videoControlsVisible.dispose();
    _railHovered.dispose();
    _cursorHidden.dispose();
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
  /// 调用即覆盖全部入口。查词浮层（[_popup]）活动期间不 refocus（用户在查词，不应让
  /// 空格控制视频）；浮层栈**全空**时由关栈汇聚点 [_popNestedPopupAt] 统一收回。
  ///
  /// 前提：[_videoFocusNode] 必须仍在焦点树上。全屏期间窗口侧 controls 经
  /// [VideoControlsFocusGate] 卸载，保证退全屏后节点被窗口侧重新 attach——否则
  /// 节点是孤儿时本方法只会静默挂起（这正是 TODO-040 修掉的根因）。
  void _refocusVideo() {
    if (!mounted) return;
    // 仅当播放器已就绪（Video 已挂载）才请求焦点；否则节点未 attach，requestFocus 无意义。
    if (_controller == null) return;
    _videoFocusNode.requestFocus();
  }

  /// 「视频应当持有键盘」的统一回收判据：键盘所有者路由（窗口模式=本页路由，
  /// 全屏期间=全屏路由）是当前路由、且无可见查词浮层时，把焦点收回
  /// [_videoFocusNode]。被设置对话框 / 菜单 / 导入遮罩压住（所有者路由非 current）
  /// 时不抢焦点——那些覆盖层关闭时各自的 `whenComplete` / `await` 返回点会归还。
  void _reclaimVideoFocusIfOwned() {
    if (!mounted || _hasVisiblePopup) return;
    final ModalRoute<Object?>? owner =
        _videoFullscreenActive ? _videoFullscreenRoute : ModalRoute.of(context);
    if (owner != null && !owner.isCurrent) return;
    _refocusVideo();
  }

  /// 把 media_kit 控制条「唤醒」并重置其自动隐藏计时（BUG-175 ②）。
  ///
  /// 根因：media_kit 的 [MaterialDesktopVideoControls] / [MaterialVideoControls]
  /// 把控制条可见性与隐藏 `Timer`（`controlsHoverDuration`）藏在私有 State 里，**只**
  /// 在鼠标 `MouseRegion.onHover`/`onEnter` 或拖动进度条时重置；键盘快捷键
  /// （上下句快进 / ±秒 seek）与编程 seek 都不触发重置 → 用户一直按键快进，控制条
  /// 仍只活 2 秒就消失，得反复呼出。media_kit 不暴露任何「重置计时」公开 API。
  ///
  /// 这里不绕开症状、而是驱动 media_kit **自己设计的**重置路径：往控制条区域中心派发
  /// 一个合成 [PointerHoverEvent]，命中其 `MouseRegion` → `onHover()` → 重置隐藏
  /// `Timer` 并翻可见。等价于「用户把鼠标移到了控制条上」，与键盘交互语义一致。
  /// 仅桌面有 hover 语义（移动端 controls 用 tap 唤起、各按钮 onPressed 自带反馈，
  /// 无此问题），故仅桌面派发。[_videoControlsContext] 是 controls 子树 context
  /// （全屏复用同一 builder 时为全屏子树），其 RenderBox 即控制条命中区。
  void _pokeControlsVisible() {
    if (!_isDesktopVideoControls) return;
    // 强压制态下不派合成 hover，避免控制条和 rail 被 poke 拉回。
    if (_immersiveLocked.value) return;
    if (_videoSidePanel.value != null) return;
    if (_subtitleListVisible.value) return;
    if (_videoControlEditMode.value) return;
    final BuildContext? ctx = _videoControlsContext;
    if (ctx == null || !ctx.mounted) return;
    final RenderObject? renderObject = ctx.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return;
    final Offset center = renderObject.localToGlobal(
      renderObject.size.center(Offset.zero),
    );
    // ±1px 抖动 x 坐标（TODO-148/BUG-215）：连续派发到同一坐标会被 MouseTracker
    // 去重、media_kit onHover 不再触发；每次翻转让坐标始终变化，强制每次都续命
    // 隐藏定时。1px 仍稳落控制条命中区内。
    _pokeParity = !_pokeParity;
    final Offset pokePosition = Offset(
      center.dx + (_pokeParity ? 1.0 : -1.0),
      center.dy,
    );
    GestureBinding.instance.handlePointerEvent(
      PointerHoverEvent(
        position: pokePosition,
        // 复用一个稳定的合成设备 id，避免与真实鼠标/触控设备冲突。
        device: _syntheticHoverDevice,
        kind: PointerDeviceKind.mouse,
      ),
    );
    // 不再在 Hibiki 侧另翻镜像可见性（TODO-364）：刚派发的合成 hover 会命中 media_kit
    // 自己的 MouseRegion → 其 onHover 翻 `visible=true` 并重置 **它唯一的** 隐藏 Timer、
    // 把真实可见性推进 [_mediaKitControlsVisible]，由 [_applyControlsVisibilityFromMediaKit]
    // 派生进 [_videoControlsVisible]。键盘 / seek 唤起控制条时字幕跟着上顶，且与真实控制条
    // 同相位（旧实现这里直接翻镜像 + 另起 Timer 是相位反的根因）。
  }

  /// media_kit 控制条自动隐藏时长，与两端控制主题的 `controlsHoverDuration` 同源（2s）。
  static const Duration _videoControlsHoverDuration = Duration(seconds: 2);

  /// 控制条 / 侧边锁按钮 / 浮动 rail 的显隐淡入淡出时长（TODO-435），单一真相源。
  /// 与 media_kit 的 `controlsTransitionDuration` 默认对齐：桌面 150ms、移动 300ms。
  /// [_desktopControlsTheme] / [_mobileControlsTheme] / [_buildSideLockButton] /
  /// [_buildVideoSideActionRail] 都读它，将来调一处全部跟随，不再各写各的 200ms。
  Duration get _videoControlsTransitionDuration => _isDesktopVideoControls
      ? const Duration(milliseconds: 150)
      : const Duration(milliseconds: 300);

  /// 当前是否有承载光标操作的 overlay 打开（设置 / 音轨等浮层 [_videoSidePanel]，或
  /// 字幕跳转列表 [_subtitleListVisible]，TODO-329）。有 overlay 时光标不该被沉浸 /
  /// 自动隐藏定时吃掉（用户要在 overlay 上操作）；纯沉浸锁（无 overlay）静止超时仍隐藏
  /// 画面光标（BUG-258）。
  bool get _hasVideoOverlay =>
      _videoSidePanel.value != null ||
      _videoControlPopover.value != null ||
      _subtitleListVisible.value ||
      _videoControlEditMode.value;

  bool get _videoSideActionRailStronglySuppressed =>
      _videoSidePanel.value != null ||
      _subtitleListVisible.value ||
      _videoControlEditMode.value;

  void _clearRailHover() {
    if (_railHovered.value) {
      _railHovered.value = false;
    }
  }

  /// 控制条避让可见性的 **唯一派生 / 写入点**（TODO-364）。
  ///
  /// 输入只有两类真相：①media_kit 控制条自己推来的真实可见性
  /// （[_mediaKitControlsVisible]，由 vendored fork 的 `visibilityNotifier` 在每次
  /// `visible` 变化时推送）②Hibiki 侧三个遮挡门控（沉浸锁 [_immersiveLocked] / 侧栏
  /// [_videoSidePanel] / 字幕跳转列表 [_subtitleListVisible]）。门控成立时控制条本被
  /// [IgnorePointer] 挡掉 / 被 overlay 盖住，字幕不该避让 → 强制 false；否则字幕避让恒
  /// 等于真实可见态。任何这五个输入变化都重跑本函数（在 [initState] 订阅），故
  /// [_videoControlsVisible] 永不与真实控制条相位反（消除旧镜像 + 第二个 Timer 的漂移）。
  ///
  /// 同时承接两个跟随控制条显隐的副作用（旧 `_markControlsVisible` 内的逻辑）：
  /// - 门控隐藏控制条时关闭音量 popover（TODO-337，其锚点随控制条消失）；
  /// - OS 光标隐藏（TODO-318 / BUG-258）：控制条不可见且无 overlay → 隐藏画面光标
  ///   （镜像 media_kit `hideMouseOnControlsRemoval`）；可见或有 overlay → 显示。真实鼠标
  ///   移动经 [_handleVideoControlsHover] 仍随时唤回光标，不被本派生压制。
  void _applyControlsVisibilityFromMediaKit() {
    if (!mounted) return;
    final bool gated = _immersiveLocked.value ||
        _videoSidePanel.value != null ||
        _subtitleListVisible.value ||
        _videoControlEditMode.value;
    final bool visible = !gated && _mediaKitControlsVisible.value;
    _videoControlsVisible.value = visible;
    if (!visible && _videoControlPopover.value != null) {
      _hideControlPopover();
    }
    // 音量 / 倍速轻浮层随控制条整体显隐；控制条消失时锚点也消失，浮层立即关闭。
    // 光标：可见 → 显示；不可见但有 overlay（用户要在 overlay 上操作）→ 显示；不可见且
    // 无 overlay（纯沉浸 / 自动淡出）→ 隐藏（保 BUG-258 / 镜像 hideMouseOnControlsRemoval）。
    _setCursorHidden(!visible && !_hasVideoOverlay);
  }

  /// 收起控制条可见性的兼容入口（TODO-364 后只接受 `false`）。沉浸锁 / 开侧栏 / 开字幕
  /// 列表的调用方在翻转各自门控 [ValueNotifier] 后调本方法，立即重派生
  /// [_videoControlsVisible]（门控订阅本就会触发，但同帧调用确保即时收起、不等微任务）。
  /// 不再接受「乐观翻 true」——可见性由 media_kit 真实态唯一决定（[_pokeControlsVisible]
  /// / 真实 hover 经 media_kit 自己唤起并推送），杜绝旧镜像与真实控制条相位反。
  void _markControlsVisible(bool visible) {
    if (!mounted) return;
    assert(
      !visible,
      '_markControlsVisible 仅用于门控收起（false）；唤起交给 media_kit 真实可见性（TODO-364）',
    );
    _applyControlsVisibilityFromMediaKit();
  }

  /// 桌面鼠标移出视频区：光标交还系统 / 外部（TODO-318）。控制条的隐藏由 media_kit
  /// 自己的 `onExit` 决定并推送 [_mediaKitControlsVisible]，不在 Hibiki 侧另判（TODO-364）。
  void _onVideoControlsHoverExit() {
    if (!mounted) return;
    _setCursorHidden(false);
  }

  bool _isSyntheticControlsHover(PointerEvent event) =>
      event.device == _syntheticHoverDevice;

  void _handleVideoControlsHover(PointerEvent event) {
    if (!_isSyntheticControlsHover(event)) {
      // 真实鼠标移动 → 唤回光标（TODO-318）。合成 poke（键盘/seek 续命）不强制显示光标，
      // 否则键盘连按快进会让本该隐藏的光标常驻。沉浸锁态也借此唤回光标找解锁按钮。
      _setCursorHidden(false);
    }
    // 控制条可见性不在此翻（TODO-364）：本 hover 包裹层 `opaque:false`，真实鼠标 hover 会
    // 继续下探命中 media_kit 自己的 MouseRegion → 其 onHover 翻 `visible` 并推送
    // [_mediaKitControlsVisible]，字幕避让由 [_applyControlsVisibilityFromMediaKit] 派生，
    // 与真实控制条同相位。
    _pokeLockButton();
  }

  void _handleVideoControlsHoverExit(PointerEvent event) {
    if (_isSyntheticControlsHover(event)) return;
    _onVideoControlsHoverExit();
  }

  /// 鼠标进 / 出**字幕盒**（BUG-283）。字幕盒覆盖在 media_kit 控制条之上：鼠标停字幕上
  /// 读字 / 查词时，控制条 2s 自动隐藏会让 media_kit 的 `hideMouseOnControlsRemoval` 把
  /// 画面光标隐藏（再叠上 hibiki 顶层 [_cursorHidden] 的 cursor:none）——用户报「鼠标放
  /// 字幕上消失」。hover 字幕时唤回光标（[_setCursorHidden]false 让顶层胜出层让位）并
  /// [_pokeControlsVisible] 续命控制条（避免 media_kit `mount=false` 让它自己的 cursor 置
  /// none）；移出由 media_kit / 自动隐藏定时按既有路径接管，不强制改光标。仅桌面有 OS 光标
  /// 语义，[_setCursorHidden] / [_pokeControlsVisible] 内部已各自桌面门控。
  void _handleSubtitleHover(bool hovering) {
    if (!mounted || !hovering) return;
    _setCursorHidden(false);
    _pokeControlsVisible();
  }

  /// 唤回视频左侧锁 / 解锁按钮并重置 2s 自动淡出（TODO-126）。鼠标移动（hover）/ 触屏点画面
  /// 时调用。**不被锁 gate**（与 [_markControlsVisible] 不同）——沉浸态解锁按钮要能淡出后再
  /// 被唤回，否则用户失去可见退出口。Esc / Shift+L 始终另有退出路径，不依赖此可见性。
  void _pokeLockButton() {
    if (!mounted) return;
    _lockButtonVisible.value = true;
    _lockButtonHideTimer?.cancel();
    _lockButtonHideTimer = Timer(_videoControlsHoverDuration, () {
      if (mounted) _lockButtonVisible.value = false;
    });
  }

  /// 是否当前用 media_kit 桌面控制条（仅桌面三端有 hover 自动隐藏语义）。
  bool get _isDesktopVideoControls {
    switch (Theme.of(context).platform) {
      case TargetPlatform.windows:
      case TargetPlatform.macOS:
      case TargetPlatform.linux:
        return true;
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        return false;
    }
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
    // TODO-393 / BUG-缓存串味：每次新查词都从「只制当前句」起步，丢弃上一个词的
    // 「上 N 句 / 下 N 句」上下文选择。热槽 WebView 复用使弹窗 DOM 不重载，草稿若不
    // 在此清空，上一个词攒的上下文会带到下一个词的卡（用户报「弹窗会缓存」）。
    _miningDraft.clear();
    // 制卡要裁「用户正在学的那句」的真实声轨音频。currentCue 在字幕 gap / 末句后被
    // 清成 null（BUG-074 字幕条该消失），而查词往往就发生在字幕刚消失那一瞬——若直接
    // 取 currentCue，制卡时句子音频字段会空（TODO-104b / BUG-188）。故 null 时按当前
    // 播放位置独立解析最近一条 cue（只读 controller，不复用被 gap 清空的 UI 状态）。
    _lastLookupCue = controller.currentCue ??
        resolveMiningCueForPosition(
          cues: controller.cues,
          positionMs: controller.positionMs ?? 0,
          delayMs: controller.delayMs,
        );
    await pushNestedPopup(
      query: term,
      selectionRect: charRect,
      controller: _popup,
      replaceStack: true,
      reuseWarmSlot: true,
      autoRead: true,
    );
    debugPrint(
      '[video-lookup] popup ready in ${swLookup.elapsedMilliseconds}ms term="$term"',
    );
    // 刷新查词浮层顶部收藏星标：判定当前字幕句是否已收藏（异步，不阻塞弹窗）。
    unawaited(_refreshVideoSentenceFavorite());
  }

  /// 当前查词字幕句的收藏键：视频句子把 cue.startMs 兼容写入
  /// [FavoriteSentence.normCharOffset]，用 `bookUid + startMs` 指回时间轴；没有 cue 的
  /// 旧条目继续以 `text + bookUid` 兼容匹配。
  Future<void> _refreshVideoSentenceFavorite() async {
    final String sentence = _lastLookupSentence;
    final AudioCue? cue = _lastLookupCue;
    if (sentence.isEmpty) {
      if (mounted && _currentVideoSentenceIsFavorited) {
        setState(() => _currentVideoSentenceIsFavorited = false);
      }
      return;
    }
    final bool favorited = (await _matchingVideoFavorites(
      sentence,
      cue,
    ))
        .isNotEmpty;
    if (mounted && favorited != _currentVideoSentenceIsFavorited) {
      setState(() => _currentVideoSentenceIsFavorited = favorited);
    }
  }

  /// 收藏/取消收藏当前查词所在的字幕句（视频端，TODO-047 ④）。来源标
  /// [kFavoriteSentenceSourceVideo]、记 [dateKey]=今日键，使其计入视频统计的「收藏语句」
  /// 卡片，并能在收藏夹页按视频来源展示。不恢复 BUG-123 删除的单词 ☆ 按钮——这是
  /// 句子收藏星标，与书内 [ReaderHibikiPage] 的 buildPopupAudioControls 星标同语义。
  Future<void> _toggleFavoriteSentenceForVideo() async {
    final String sentence = _lastLookupSentence;
    if (sentence.isEmpty) {
      HibikiToast.show(msg: t.no_sentence_selected);
      return;
    }
    final AudioCue? cue = _lastLookupCue;
    final FavoriteSentenceRepository repo = FavoriteSentenceRepository(
      appModel.database,
    );
    if (_currentVideoSentenceIsFavorited) {
      for (final FavoriteSentence fav in await _matchingVideoFavorites(
        sentence,
        cue,
      )) {
        await repo.removeById(fav.id);
      }
      if (mounted) {
        setState(() {
          _currentVideoSentenceIsFavorited = false;
          if (cue != null) {
            _favoritedVideoSentences.remove(_videoFavoriteCacheKey(
              sentence,
              cue.startMs,
              _currentEpisode,
            ));
          }
          _favoritedVideoSentences.remove(
            _videoFavoriteCacheKey(sentence, null, null),
          );
        });
      }
      HibikiToast.show(msg: t.favorite_removed);
      return;
    }
    await repo.add(
      FavoriteSentence(
        // 视频标题尚未加载（_title==null）时回退到 bookUid，保证 bookTitle 永远非空
        // ——收藏夹页 / 统计页都按 bookTitle 展示来源行，空标题会显示成空白条目。
        text: sentence,
        bookTitle: _title ?? widget.bookUid,
        createdAt: DateTime.now(),
        bookKey: widget.bookUid,
        sectionIndex: _currentEpisode,
        normCharOffset: cue?.startMs,
        normCharLength: cue == null
            ? null
            : (cue.endMs - cue.startMs).clamp(0, 1 << 31).toInt(),
        source: kFavoriteSentenceSourceVideo,
        dateKey: statTodayKey(),
      ),
    );
    if (mounted) {
      setState(() {
        _currentVideoSentenceIsFavorited = true;
        _favoritedVideoSentences.add(_videoFavoriteCacheKey(
          sentence,
          cue?.startMs,
          _episodes.isEmpty ? null : _currentEpisode,
        ));
      });
    }
    HibikiToast.show(msg: t.favorite_added);
  }

  /// 从字幕跳转列表面板行内复制某句文本到剪贴板（TODO-152 子A）。不暂停 / 不查词。
  void _copyCueText(AudioCue cue) {
    final String text = cue.text.trim();
    if (text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
    HibikiToast.show(msg: t.copied_to_clipboard);
  }

  /// 字幕跳转列表面板某句是否已收藏（同步，读缓存 [_favoritedVideoSentences]）。
  bool _isCueFavorited(AudioCue cue) {
    final String text = cue.text.trim();
    return _favoritedVideoSentences.contains(_videoFavoriteCacheKey(
          text,
          cue.startMs,
          _episodes.isEmpty ? null : _currentEpisode,
        )) ||
        _favoritedVideoSentences
            .contains(_videoFavoriteCacheKey(text, null, null));
  }

  /// 从字幕跳转列表面板行内 toggle 某句收藏（TODO-152 子A）。与查词浮层收藏走同一
  /// [FavoriteSentenceRepository]，视频句键优先用 `bookUid + cue.startMs`，并兼容旧
  /// text-only 条目。toggle 后更新缓存集；若恰好是当前查词句，
  /// 同步 [_currentVideoSentenceIsFavorited] 让浮层星标也刷新。
  Future<void> _toggleFavoriteCueForVideo(AudioCue cue) async {
    final String sentence = cue.text.trim();
    if (sentence.isEmpty) return;
    final FavoriteSentenceRepository repo = FavoriteSentenceRepository(
      appModel.database,
    );
    final bool wasFavorited = _isCueFavorited(cue);
    if (wasFavorited) {
      for (final FavoriteSentence fav in await _matchingVideoFavorites(
        sentence,
        cue,
      )) {
        await repo.removeById(fav.id);
      }
    } else {
      await repo.add(
        FavoriteSentence(
          text: sentence,
          bookTitle: _title ?? widget.bookUid,
          createdAt: DateTime.now(),
          bookKey: widget.bookUid,
          sectionIndex: _currentEpisode,
          normCharOffset: cue.startMs,
          normCharLength: (cue.endMs - cue.startMs).clamp(0, 1 << 31).toInt(),
          source: kFavoriteSentenceSourceVideo,
          dateKey: statTodayKey(),
        ),
      );
    }
    if (!mounted) return;
    setState(() {
      if (wasFavorited) {
        _favoritedVideoSentences
          ..remove(_videoFavoriteCacheKey(
            sentence,
            cue.startMs,
            _episodes.isEmpty ? null : _currentEpisode,
          ))
          ..remove(_videoFavoriteCacheKey(sentence, null, null));
      } else {
        _favoritedVideoSentences.add(_videoFavoriteCacheKey(
          sentence,
          cue.startMs,
          _episodes.isEmpty ? null : _currentEpisode,
        ));
      }
      // 列表 toggle 的若是当前查词那句，同步浮层星标态（两处共用同一收藏记录）。
      if (sentence == _lastLookupSentence.trim()) {
        _currentVideoSentenceIsFavorited = !wasFavorited;
      }
    });
    HibikiToast.show(msg: wasFavorited ? t.favorite_removed : t.favorite_added);
  }

  /// 拉本视频已收藏句填充 [_favoritedVideoSentences]（打开字幕跳转列表前调一次）。
  /// 只取本 bookKey + video 来源那批，按 `text` 建集供同步查询。
  Future<void> _refreshFavoritedCueCache() async {
    final FavoriteSentenceRepository repo = FavoriteSentenceRepository(
      appModel.database,
    );
    final List<FavoriteSentence> all = await repo.getAll();
    if (!mounted) return;
    setState(() {
      _favoritedVideoSentences
        ..clear()
        ..addAll(
          all
              .where(
                (FavoriteSentence s) =>
                    s.bookKey == widget.bookUid &&
                    s.source == kFavoriteSentenceSourceVideo,
              )
              .map(
                (FavoriteSentence s) => _videoFavoriteCacheKey(
                  s.text.trim(),
                  s.normCharOffset,
                  s.sectionIndex,
                ),
              ),
        );
    });
  }

  String _videoFavoriteCacheKey(String text, int? startMs, int? episodeIndex) =>
      videoFavoriteCacheKey(
        text: text,
        startMs: startMs,
        episodeIndex: episodeIndex,
        isPlaylist: _episodes.isNotEmpty,
      );

  Future<List<FavoriteSentence>> _matchingVideoFavorites(
    String sentence,
    AudioCue? cue,
  ) async {
    final String text = sentence.trim();
    final List<FavoriteSentence> all = await FavoriteSentenceRepository(
      appModel.database,
    ).getAll();
    final int? episodeIndex = _episodes.isEmpty ? null : _currentEpisode;
    return all
        .where(
          (FavoriteSentence s) =>
              s.source == kFavoriteSentenceSourceVideo &&
              s.bookKey == widget.bookUid &&
              s.text.trim() == text &&
              (cue == null
                  ? s.normCharOffset == null
                  : (s.normCharOffset == cue.startMs &&
                          (_episodes.isEmpty ||
                              s.sectionIndex == episodeIndex)) ||
                      (s.normCharOffset == null && s.sectionIndex == null)),
        )
        .toList();
  }

  /// 查词浮层顶部「收藏当前字幕句」星标行（覆写 [DictionaryPageMixin.buildPopupHeaderFor]）。
  /// 仅顶层（[index] == 0，真查词那句）显示；嵌套递归查词层（index > 0）不属于某条字幕句，
  /// 返回 null。星标实心=已收藏，空心=未收藏，点击 toggle。
  @override
  Widget? buildPopupHeaderFor(int index) {
    if (index != 0) return null;
    final ThemeData theme =
        appModel.overrideDictionaryTheme ?? Theme.of(context);
    return Material(
      type: MaterialType.transparency,
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: theme.dividerColor, width: 0.5),
          ),
        ),
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            HibikiIconButton(
              key: const Key('video_favorite_sentence_button'),
              // tooltip 用「句子收藏」（已有 i18n），描述按钮职责；不复用 toast 文案
              // favorite_added/removed——那是动作结果提示，做静态 tooltip 会反向误导。
              tooltip: t.collection_sentence,
              icon: _currentVideoSentenceIsFavorited
                  ? Icons.star
                  : Icons.star_border,
              size: 20,
              enabledColor: _currentVideoSentenceIsFavorited
                  ? theme.colorScheme.primary
                  : null,
              onTap: _toggleFavoriteSentenceForVideo,
            ),
          ],
        ),
      ),
    );
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
      _handleSubtitleLookupTap(hit.sentence, hit.graphemeIndex, hit.charRect);
      return;
    }
    _popNestedPopupAt(0);
  }

  void _handleSubtitleLookupTap(
    String sentence,
    int graphemeIndex,
    Rect charRect,
  ) {
    if (!_immersiveAllowsLookup) return;
    unawaited(_lookupAt(sentence, graphemeIndex, charRect));
  }

  void _popNestedPopupAt(int index) {
    debugPrint(
      '[video-lookup] dismiss popup index=$index '
      'visibleTop=$_topVisiblePopupIndex',
    );
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
    final bool stackEmpty = !_hasVisiblePopup;
    if (VideoHibikiPage.shouldResumeAfterLookupDismiss(
      // "Effectively empty" = no visible popup; the hidden warm slot doesn't
      // block resume.
      stackEmpty: stackEmpty,
      pausedForLookup: _pausedForLookup,
    )) {
      _pausedForLookup = false;
      unawaited(_controller?.play());
    }
    // 浮层栈全空 = 查词结束，键盘所有权回到视频。浮层 WebView（原生控件）/遮罩
    // 夺走的焦点不会自动归还；这里与「恢复播放」共用同一个关栈汇聚点，覆盖点遮罩 /
    // 返回键 / Esc / 滑动全部关闭路径（TODO-040 ①「点了外面后快捷键失灵」的查词
    // 浮层分支）。
    if (stackEmpty) {
      // TODO-270 E：整条查词浮层栈关闭 = 一次「查词会话」结束，丢弃未制卡的多句草稿
      // （避免下次查词带着上次没用掉的累积句）。制卡成功已在 onMineEntry/onUpdateEntry
      // 清过，这里兜住「攒了几句但没制卡就关掉」的情况（与 reader onAllPopupsDismissed
      // 同语义；视频用 DictionaryPageMixin 没有该钩子，故在关栈汇聚点清）。点同句另一
      // 字 / 字幕条另一句切换查词走 _lookupAt(replaceStack)，栈不空，草稿不被清。
      _miningDraft.clear();
      _refocusVideo();
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
            final Size screen = Size(
              constraints.maxWidth,
              constraints.maxHeight,
            );
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
  bool _isCueSelectedForCard(AudioCue cue) =>
      _selectedMiningCueStarts.contains(cue.startMs);

  void _toggleCueSelectedForCard(AudioCue cue) {
    setState(() {
      if (!_selectedMiningCueStarts.add(cue.startMs)) {
        _selectedMiningCueStarts.remove(cue.startMs);
      }
    });
  }

  void _clearSelectedMiningCues() {
    if (_selectedMiningCueStarts.isEmpty) return;
    setState(_selectedMiningCueStarts.clear);
  }

  AudioCue? _selectedMiningCueForCard(VideoPlayerController controller) {
    return buildSelectedSubtitleCueContext(
      cues: controller.cues,
      selectedStartMs: _selectedMiningCueStarts,
    );
  }

  /// 视频制卡/覆盖共用的「解析这一张卡的区间 + 文本」。把三个并存入口收口成一处，避免
  /// [onMineEntry] / [onUpdateEntry] 两份漂移：
  /// - **字幕列表多选**（TODO-102，[_selectedMiningCueStarts] 非空）优先：用
  ///   [buildSelectedSubtitleCueContext] 合成的单段区间 + join 文本，**不掺查词草稿**。
  /// - 否则**查词窗口多句合一草稿**（TODO-270 E）：当前 cue 取「lookup 缓存 → currentCue
  ///   → 按位置解析」多段兜底（含 gap，BUG-188）；文本用 [MiningSentenceDraft.composeText]
  ///   合并草稿全部句 + 当前句，区间用 [MiningSentenceDraft.composeAudioRange] 合并成首句
  ///   起→末句止（草稿空时等价于单句原行为：trim 文本 + 单 cue 区间）。
  ///
  /// [usedSelectedCue] 回传「本次是否走了字幕列表多选」，供成功后清多选用。
  ({
    int clipStartMs,
    int clipEndMs,
    String sentence,
    String? cueSentence,
    bool usedSelectedCue
  }) _resolveVideoMiningRange(VideoPlayerController controller) {
    final AudioCue? selectedCue = _selectedMiningCueForCard(controller);
    if (selectedCue != null) {
      // 字幕列表多选（独立入口）：单段区间就是合成 cue 的时间窗，文本即其 join。
      return (
        clipStartMs: selectedCue.startMs,
        clipEndMs: selectedCue.endMs,
        sentence: selectedCue.text,
        cueSentence: selectedCue.text,
        usedSelectedCue: true,
      );
    }

    // 查词窗口多句合一（TODO-270 E）。当前 cue 多段兜底（含 gap，BUG-188）。
    final AudioCue? cue = _lastLookupCue ??
        controller.currentCue ??
        resolveMiningCueForPosition(
          cues: controller.cues,
          positionMs: controller.positionMs ?? 0,
          delayMs: controller.delayMs,
        );
    // 草稿全部句 + 当前查词句合成 sentence（草稿空 → 单句 _lastLookupSentence trim）。
    final String mergedSentence = _miningDraft.composeText(_lastLookupSentence);
    // 草稿全部句区间 + 当前 cue 区间合并成首句起→末句止（草稿空 → 单 cue 区间）。
    final AudioPlaybackRange? mergedRange = _miningDraft.composeAudioRange(
      cue == null
          ? null
          : AudioPlaybackRange(
              audioFileIndex: 0,
              startMs: cue.startMs,
              endMs: cue.endMs,
            ),
    );
    return (
      clipStartMs: mergedRange?.startMs ?? cue?.startMs ?? 0,
      clipEndMs: mergedRange?.endMs ?? cue?.endMs ?? 0,
      // 多句时 cueSentence 用合并文本与 sentence 一致；草稿空时退回单 cue 文本作 fallback。
      cueSentence: _miningDraft.isEmpty ? cue?.text : mergedSentence,
      sentence: mergedSentence,
      usedSelectedCue: false,
    );
  }

  @override
  Future<MinePopupResult> onMineEntry(Map<String, String> fields) async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return const MinePopupResult();

    final ({
      int clipStartMs,
      int clipEndMs,
      String sentence,
      String? cueSentence,
      bool usedSelectedCue,
    }) range = _resolveVideoMiningRange(controller);

    final MinePopupResult result = await _mineVideoCard(
      fields: fields,
      // 音频/封面区间 = 合并后的首句起→末句止（单句即该 cue 时间窗，两端相等→不抽）。
      clipStartMs: range.clipStartMs,
      clipEndMs: range.clipEndMs,
      sentence: range.sentence,
      cueSentence: range.cueSentence,
    );
    // result.ankiConnect 是「制卡成功」信号（两后端成功时都置 true；noteId 仅
    // AnkiConnect 非空，故清选中句不能以 noteId 为判据，否则 AnkiDroid 成功也不清）。
    if (result.ankiConnect) {
      if (range.usedSelectedCue) {
        _clearSelectedMiningCues();
      } else {
        // TODO-270 E：合并卡已落地 → 清空多句草稿（popup.js 同事件把角标清零，两端在
        // 同一事件归零、不漂移）。下一次查词从空草稿重新累积。
        _miningDraft.clear();
      }
    }
    return result;
  }

  /// TODO-270 D：覆盖「最新制的那张卡」（[noteId]）。视频页覆写了 [onMineEntry] 绕过
  /// mixin，故覆盖路径也在本页复用视频媒体链路（GIF 封面 + 区间音频），按 id 真实
  /// 覆盖而非删旧建新（[_mineVideoCard] 的 `updateNoteId` 分支）。覆盖同样吃多句合一
  /// 草稿（合并卡=一张卡，天然吃覆盖，与 270-D 正交）；覆盖成功后清空草稿。
  @override
  Future<MinePopupResult> onUpdateEntry(
    int noteId,
    Map<String, String> fields,
  ) async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return const MinePopupResult();

    final ({
      int clipStartMs,
      int clipEndMs,
      String sentence,
      String? cueSentence,
      bool usedSelectedCue,
    }) range = _resolveVideoMiningRange(controller);

    final MinePopupResult result = await _mineVideoCard(
      fields: fields,
      clipStartMs: range.clipStartMs,
      clipEndMs: range.clipEndMs,
      sentence: range.sentence,
      cueSentence: range.cueSentence,
      updateNoteId: noteId,
    );
    if (result.ankiConnect) {
      if (range.usedSelectedCue) {
        _clearSelectedMiningCues();
      } else {
        _miningDraft.clear();
      }
    }
    return result;
  }

  /// 视频制卡/覆盖的落卡链路（单句 [onMineEntry]/[onUpdateEntry] 走这里）：把音频/封面
  /// 区间 `[clipStartMs, clipEndMs]`（单句即该 cue 的时间窗）抽成 GIF + 音频片段，配
  /// [sentence]/[cueSentence]/[fields] 经 [BaseAnkiRepository] 生成**一张**卡，回 OSD。
  /// [updateNoteId] 为空时新制一张（计入视频统计），非空时按 id 覆盖那张卡（不计入统计、
  /// 走 [BaseAnkiRepository.updateMinedNote]）。返回 [MinePopupResult]：成功带回 note id
  /// （新制时来自 addNote，覆盖时即 [updateNoteId]），让弹窗保持「最新可改」第三态。
  /// 区间非正（`clipEndMs <= clipStartMs`，如无 cue）时不抽媒体、回退当前帧截图作封面。
  Future<MinePopupResult> _mineVideoCard({
    required Map<String, String> fields,
    required int clipStartMs,
    required int clipEndMs,
    required String sentence,
    String? cueSentence,
    int? updateNoteId,
  }) async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return const MinePopupResult();
    final BaseAnkiRepository repo = ref.read(ankiRepositoryProvider);
    final Directory tmp = await getTemporaryDirectory();
    final String? videoPath = controller.videoPath;
    final bool hasRange = clipEndMs > clipStartMs;

    // 视频卡片封面 → coverPath（→`{book-cover}`）：优先把**区间时间段**导出成循环 GIF
    // （单句=该 cue 时间窗；跨字幕=整段区间）。桌面走系统 ffmpeg、移动端走捆绑 ffmpeg-kit
    // （resolveFfmpegBackend）；无区间 / 导出失败（ffmpeg 真不可用等）时回退当前帧截图。
    String? coverPath;
    String? gifFailure;
    if (hasRange && videoPath != null) {
      coverPath = await extractClipGifViaFfmpeg(
        inputPath: videoPath,
        startMs: clipStartMs,
        endMs: clipEndMs,
        outputPath: '${tmp.path}/video_mine_clip.gif',
        onFailure: (String summary) {
          gifFailure = summary;
        },
      );
    }
    if (coverPath == null) {
      if (gifFailure != null) {
        debugPrint('[VideoHibiki] mine: GIF clip export failed: $gifFailure');
      }
      final Uint8List? shot = await controller.screenshot();
      if (shot != null && shot.isNotEmpty) {
        final File f = File('${tmp.path}/video_mine_shot.jpg');
        await f.writeAsBytes(shot);
        coverPath = f.path;
      }
    }

    // 区间音频片段（桌面 ffmpeg 按时间裁，映射到当前选中音轨）→ sasayakiAudioPath。
    // 跨字幕时这就是 [startCue.startMs, endCue.endMs] 一整段（不逐句抽再拼，TODO-102）。
    String? audioPath;
    String? audioFailure;
    if (hasRange && videoPath != null) {
      audioPath = await extractAudioSegmentViaFfmpeg(
        inputPath: videoPath,
        startMs: clipStartMs,
        endMs: clipEndMs,
        outputPath: '${tmp.path}/video_mine_audio.aac',
        audioStreamIndex: controller.currentAudioStreamIndex,
        onFailure: (String summary) {
          audioFailure = summary;
        },
      );
      // BUG-296 / TODO-390: sentence-audio "should-have-but-failed" visibility,
      // symmetric with reader BUG-172. hasRange means this card was supposed to
      // carry sentence audio, but ffmpeg returned null (ffmpeg unavailable on
      // device / current audio track undecodable / interleaved container read
      // failure) so the card's {sasayaki-audio}/SentenceAudio renders empty.
      // This used to be a fully silent drop (user sees "card created" with no
      // sentence audio and no way to diagnose - exactly the TODO-390 blind spot
      // behind repeated "Hibiki deck has no sentence audio" reports). Treat it
      // like the reader/audiobook path: surface the root cause and abort this
      // mining attempt rather than creating a "successful" no-audio card.
      if (audioPath == null) {
        debugPrint(
          '[VideoHibiki] mine: sentence-audio clip failed for range '
          '[$clipStartMs,$clipEndMs] '
          '(audioStreamIndex=${controller.currentAudioStreamIndex}; '
          '${audioFailure ?? 'ffmpeg returned null'}).',
        );
        if (mounted) {
          _showOsd(t.card_export_failed_detail(
            reason: audioFailure == null
                ? 'sentence audio export failed'
                : 'sentence audio export failed: $audioFailure',
          ));
        }
        return const MinePopupResult();
      }
    }

    final AnkiMiningContext miningContext = AnkiMiningContext(
      sentence: sentence,
      cueSentence: cueSentence,
      documentTitle: _title,
      coverPath: coverPath,
      sasayakiAudioPath: audioPath,
      // TODO-115: 视频来源 → 卡片追加 `video` 分类标签（本页覆写了 onMineEntry，
      // 绕过 DictionaryPageMixin 的 source 注入，故在此显式指定）。
      source: AnkiMiningSource.video,
    );
    final MineOutcome outcome = updateNoteId == null
        ? await repo.mineEntry(
            rawPayloadJson: jsonEncode(fields),
            context: miningContext,
          )
        : await repo.updateMinedNote(
            noteId: updateNoteId,
            rawPayloadJson: jsonEncode(fields),
            context: miningContext,
          );
    final MinePopupResult result = outcome.result == MineResult.success
        ? MinePopupResult(ankiConnect: true, noteId: outcome.noteId)
        : const MinePopupResult();
    if (!context.mounted) return result;
    // 牌组名仅 success 需要（避免给失败分支白白 loadSettings）。
    final String deckName = outcome.result == MineResult.success
        ? (await repo.loadSettings()).selectedDeckName ?? ''
        : '';
    // overwrite=true（updateNoteId 非空）→ 收口产 card_overwritten + record=false；
    // 新制 → card_exported + record=true（消息/记账判定统一在 describeMineOutcome）。
    final described = describeMineOutcome(
      outcome,
      deckName: deckName,
      overwrite: updateNoteId != null,
    );
    // 新制成功计入视频统计（dictionarySourceType=video）；覆盖 record=false 故不记账。
    // 本页覆写了 onMineEntry、绕过基类成功分支，故在此显式记账（与 mixin 同一路径）。
    if (described.record) unawaited(recordMined());
    _showOsd(described.message);
    return result;
  }

  /// 弹音轨菜单（顶栏 ♪ 按钮共用）。
  void _showAudioTrackMenu(
    VideoPlayerController _, {
    VideoControlSlot? sourceSlot,
  }) {
    _showVideoSidePanel(
      _VideoSidePanelKind.audioTracks,
      sourceSlot: sourceSlot,
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
  /// ② 普通左右方向键 = 时间 seek（±seekSeconds 秒，TODO-090）；Ctrl+←/→ = 上/下一句
  ///    字幕。上一句太远（gap > seekSeconds 秒）时 Ctrl+← 退化成回退 seekSeconds 秒（TODO-085）。
  /// 其余键（空格/媒体键/J·I/F）按 media_kit 默认语义用底层 [Player] 重建，避免
  /// 覆盖后丢默认行为。全屏相关 helper 需 controls 子树内 context，用 [_videoControlsContext]。
  Map<ShortcutActivator, VoidCallback> _videoKeyboardShortcuts(
    VideoPlayerController controller,
  ) {
    return buildVideoPlayerShortcutsFromRegistry(
      appModel.shortcutRegistry,
      VideoPlayerShortcutActions(
        togglePlayPause: () => _runWhenImmersiveAllowsFullControls(
          () => unawaited(controller.playOrPause()),
        ),
        play: () => _runWhenImmersiveAllowsFullControls(
          () => unawaited(controller.play()),
        ),
        pause: () => _runWhenImmersiveAllowsFullControls(
          () => unawaited(controller.pause()),
        ),
        // Ctrl+←/→ = 上/下一句字幕（TODO-090）。上一句太远时 Ctrl+← 退化成回退
        // seekSeconds 秒（TODO-085），决策集中在 [skipToPrevCueOrSeekBack]；无 cue
        // 时也直接当回退键。下一句保持纯句子跳（无 cue 时前进 seekSeconds 秒）。
        // 每次跳句都唤醒控制条并重置自动隐藏计时（BUG-175 ②）：键盘交互不触发
        // media_kit 的 hover 重置，不主动 poke 的话控制条只活 2 秒就消失。
        previousSubtitle: () {
          _runWhenImmersiveAllowsFullControls(() {
            _pokeControlsVisible();
            unawaited(
              controller.skipToPrevCueOrSeekBack(
                seekSeconds: _asbConfig.seekSeconds,
              ),
            );
          });
        },
        nextSubtitle: () {
          _runWhenImmersiveAllowsFullControls(() {
            _pokeControlsVisible();
            // 无字幕时前进 seekSeconds 秒、有字幕时跳下一句，决策集中在
            // [skipToNextCueOrSeekForward]（与 previousSubtitle 的
            // skipToPrevCueOrSeekBack 对称，TODO-073）。
            unawaited(
              controller.skipToNextCueOrSeekForward(
                seekSeconds: _asbConfig.seekSeconds,
              ),
            );
          });
        },
        // 普通 ←/→ = 时间 seek（±seekSeconds 秒，TODO-090），与 J/A·I/D 同语义。
        seekBackward: () => _runWhenImmersiveAllowsFullControls(() {
          _pokeControlsVisible();
          unawaited(controller.seekRelative(-_asbSeekMs));
        }),
        seekForward: () => _runWhenImmersiveAllowsFullControls(() {
          _pokeControlsVisible();
          unawaited(controller.seekRelative(_asbSeekMs));
        }),
        toggleShaderCompare: () => _runWhenImmersiveAllowsFullControls(
          () => unawaited(_toggleShaderCompare()),
        ),
        volumeUp: () => _runWhenImmersiveAllowsFullControls(
          () => unawaited(_adjustVolume(_volumeStep)),
        ),
        volumeDown: () => _runWhenImmersiveAllowsFullControls(
          () => unawaited(_adjustVolume(-_volumeStep)),
        ),
        toggleMute: () => _runWhenImmersiveAllowsFullControls(
          () => unawaited(_toggleMute()),
        ),
        speedUp: () => _runWhenImmersiveAllowsFullControls(
          () => unawaited(_adjustSpeed(_speedStep)),
        ),
        speedDown: () => _runWhenImmersiveAllowsFullControls(
          () => unawaited(_adjustSpeed(-_speedStep)),
        ),
        resetSpeed: () => _runWhenImmersiveAllowsFullControls(
          () => unawaited(_setSpeed(1.0)),
        ),
        previousFrame: () => _runWhenImmersiveAllowsFullControls(
          () => unawaited(controller.frameStep(forward: false)),
        ),
        nextFrame: () => _runWhenImmersiveAllowsFullControls(
          () => unawaited(controller.frameStep(forward: true)),
        ),
        screenshot: () => _runWhenImmersiveAllowsFullControls(
          () => unawaited(_saveScreenshot()),
        ),
        toggleFullscreen: () => _runWhenImmersiveAllowsFullControls(() {
          final BuildContext? ctx = _videoControlsContext;
          if (ctx != null && ctx.mounted) {
            unawaited(_toggleVideoFullscreen(ctx));
          }
        }),
        // 'L' = 开/关字幕跳转列表（TODO-069）。
        toggleSubtitleList: () => _runWhenImmersiveAllowsFullControls(
          _toggleSubtitleJumpList,
        ),
        // Shift+L = 切换锁定 / 沉浸模式（TODO-101）。
        toggleImmersiveLock: _toggleImmersiveLock,
        // 'B' = 翻转字幕模糊（TODO-134：从内层独立 CallbackShortcuts 并入注册表）。
        toggleSubtitleBlur: () => _runWhenImmersiveAllowsFullControls(
          () => unawaited(_toggleSubtitleBlur()),
        ),
        toggleFavoriteSentence: () => _runWhenImmersiveAllowsFullControls(
          () => unawaited(_toggleFavoriteCurrentCue()),
        ),
        replayCurrentSubtitle: () => _runWhenImmersiveAllowsFullControls(
          () => unawaited(_replayCurrentCueAndPokeControls()),
        ),
        // 重播上一句（TODO-378，BUG-287，默认 Shift+R）：纯句子后退到上一条 cue 起点
        // 并播放（skipToPrevCue，不退化回退）。与「上一句字幕」(Ctrl+←) 区分——后者
        // gap 太远时按 BUG-185/TODO-085 退化时间 seek，是用户另一项有意设计，不动它。
        replayPreviousSubtitle: () => _runWhenImmersiveAllowsFullControls(
          () => unawaited(_replayPreviousCueAndPokeControls()),
        ),
        showFavoriteSentences: () => _runWhenImmersiveAllowsFullControls(
          _showFavoriteSentencesPanel,
        ),
        // 内封章节上/下一章（TODO-424，默认 PageUp/PageDown）：seek 到相邻章起点，
        // 无章节时 controller no-op。跳章后唤醒控制条（与跳句同范式，BUG-175）。
        previousChapter: () => _runWhenImmersiveAllowsFullControls(() {
          _pokeControlsVisible();
          unawaited(controller.previousChapter());
        }),
        nextChapter: () => _runWhenImmersiveAllowsFullControls(() {
          _pokeControlsVisible();
          unawaited(controller.nextChapter());
        }),
        escape: () {
          if (_videoControlEditMode.value) {
            _hideVideoControlEditOverlay(revealControls: false);
            return;
          }
          // 字幕跳转列表开着时，Esc 先关它（不退页 / 不退全屏）——逐级退出，符合直觉。
          // 锁定 / 沉浸模式开着时，Esc 先解锁（最外层沉浸态，逐级退出，TODO-101）。
          // push-aside 字幕列表（TODO-314）与浮层是两条独立可见性，分别关闭。
          if (_subtitleListVisible.value) {
            _toggleSubtitleJumpList();
            return;
          }
          if (_videoSidePanel.value != null) {
            _hideVideoSidePanel();
            return;
          }
          if (_immersiveLocked.value) {
            _toggleImmersiveLock();
            return;
          }
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
  /// 上/下一句走 cue 导航（无字幕/转场段对称回退/前进，
  /// [VideoPlayerController.skipToPrevCueOrSeekBack]/[VideoPlayerController.skipToNextCueOrSeekForward]）。
  Future<void> _toggleVideoFullscreen(BuildContext context) {
    // BUG-221: 移动端永不进 media_kit 全屏路由（横屏沉浸态即唯一形态）。统一在此单一收口
    // no-op，杜绝任何入口（双击 / 全屏按钮 / 快捷键 / 右键菜单）把移动端推进全屏路由——
    // 全屏路由会带来「退全屏弹回竖屏」与「全屏 PopScope 吞第一次返回的两段式退出」。桌面
    // 不受影响（窗口全屏走 native window，返回行为本就合理）。
    if (isMobilePlatform) return Future<void>.value();
    return isFullscreen(context)
        ? _exitVideoFullscreen(context)
        : _pushNeutralizedVideoFullscreen(context);
  }

  Future<void> _pushNeutralizedVideoFullscreen(BuildContext context) async {
    if (_videoFullscreenTransitioning || isFullscreen(context)) return;
    if (!context.mounted) return;
    _videoFullscreenTransitioning = true;
    final VideoStateInheritedWidget inherited = VideoStateInheritedWidget.of(
      context,
    );
    final VideoState stateValue = inherited.state;
    final contextNotifierValue = inherited.contextNotifier;
    final videoViewParametersNotifierValue =
        inherited.videoViewParametersNotifier;
    final VideoController controllerValue = stateValue.widget.controller;
    // 字幕跳转列表「真 push-aside」（TODO-121）在全屏路由里也要包裹自建的 Video，需本页
    // 持有的 [VideoPlayerController]（face：cues / currentCueIndex / skipToCue）。全屏只在
    // 播放中触发、_controller 必非空，缺失则退化为不包面板（画面占满，等价旧全屏）。
    final VideoPlayerController? playerController = _controller;
    final Future<void> Function() enterNativeFullscreen =
        stateValue.widget.onEnterFullscreen;
    final Future<void> Function() exitNativeFullscreen =
        stateValue.widget.onExitFullscreen;
    final MaterialVideoControlsTheme? mobileTheme =
        MaterialVideoControlsTheme.maybeOf(context);
    final MaterialDesktopVideoControlsTheme? desktopTheme =
        MaterialDesktopVideoControlsTheme.maybeOf(context);

    try {
      // 先置位再 push：同一帧里窗口侧 controls 经 [VideoControlsFocusGate] 卸载、
      // 全屏侧 controls 挂载，保证共享 [_videoFocusNode] 任意时刻只被一个 Focus
      // 持有（见 _videoFullscreenActive 的文档）。
      if (mounted) setState(() => _videoFullscreenActive = true);
      final PageRouteBuilder<void> fullscreenRoute = PageRouteBuilder<void>(
        pageBuilder: (_, __, ___) => Material(
          child: HibikiAppUiScaleNeutralizer(
            child: MaterialVideoControlsTheme(
              normal:
                  mobileTheme?.normal ?? kDefaultMaterialVideoControlsThemeData,
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
                  videoViewParametersNotifier: videoViewParametersNotifierValue,
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
                        builder:
                            (BuildContext _, VideoViewParameters params, __) {
                          final Widget fullscreenVideo = Video(
                            controller: controllerValue,
                            width: null,
                            height: null,
                            // 全屏 fit 跟随窗口同一 [_videoFitMode] 偏好（TODO-152 子B），
                            // 不再用 notifier 默认 `params.fit`（contain）——保证用户选的
                            // 画面比例在窗口与全屏一致。其余 params 字段（fill/alignment
                            // /aspectRatio 等）照旧走 notifier。
                            fit: videoFitModeToBoxFit(_videoFitMode),
                            fill: params.fill,
                            alignment: params.alignment,
                            aspectRatio: params.aspectRatio,
                            filterQuality: params.filterQuality,
                            controls: params.controls,
                            wakelock: false,
                            // 全屏路由也显式禁用内置 SubtitleView（TODO-080/092，
                            // BUG-190）。虽然与窗口侧共享同一
                            // videoViewParametersNotifier（窗口侧已设 visible:false 会
                            // 传播过来），但这里不依赖隐式传播，直接覆盖成 visible:false
                            // 消除「全屏路由快照时窗口侧 didUpdate 尚未把配置写进
                            // notifier」的时机竞态——字幕在全屏也只由可点 overlay 承载。
                            subtitleViewConfiguration:
                                const SubtitleViewConfiguration(visible: false),
                            focusNode: params.focusNode,
                            onEnterFullscreen: enterNativeFullscreen,
                            onExitFullscreen: exitNativeFullscreen,
                          );
                          // 字幕跳转列表「真 push-aside」（TODO-121）：全屏路由自建的
                          // Video 同样包进 Row[Expanded(Video), 面板列]，面板可见时全屏
                          // 画面真挤窄、不被遮（与窗口侧 [_buildVideoBody] 同一 helper）。
                          if (playerController == null) return fullscreenVideo;
                          return _videoWithSubtitlePanel(
                            playerController,
                            fullscreenVideo,
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
      );
      _videoFullscreenRoute = fullscreenRoute;
      // 全屏路由关闭的唯一汇聚点：Esc / F / 全屏按钮 / 双击 / 系统返回全部
      // 经由路由 future 完成，无论哪条退出路径都在这里复位 + 归还焦点。
      Navigator.of(
        context,
        rootNavigator: true,
      ).push<void>(fullscreenRoute).whenComplete(_onVideoFullscreenRouteClosed);
      await enterNativeFullscreen();
    } finally {
      _videoFullscreenTransitioning = false;
      // post-frame：等全屏路由 build 完、共享节点被全屏侧 Focus attach+reparent 之后
      // 再 requestFocus。同步调用可能跑在路由 build 之前——随后的 reparent 会把
      // primary focus 丢给全屏路由的 ModalScope，进全屏后快捷键直接死掉（实测见
      // video_fullscreen_focus_gate_test.dart 的机制复现）。
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _refocusVideo());
      }
    }
  }

  /// 全屏路由从栈上消失后：复位 [_videoFullscreenActive] 让窗口侧 controls 重挂
  /// （其 [Focus] 在 initState 重新 attach [_videoFocusNode]），并在重挂完成的
  /// 下一帧把键盘焦点收回视频。这是所有退全屏路径共用的收口，替代在每个退出
  /// 入口各补一次 refocus。
  void _onVideoFullscreenRouteClosed() {
    _videoFullscreenRoute = null;
    if (!mounted) return;
    setState(() => _videoFullscreenActive = false);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refocusVideo());
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
      // 焦点归还由 [_onVideoFullscreenRouteClosed]（路由 future 收口）负责：
      // 此刻窗口侧 controls 可能尚未重挂，节点仍是孤儿，这里 refocus 只是兜底。
      if (mounted) _refocusVideo();
    }
  }

  Widget _buildFullscreenButton({required bool desktop}) {
    // BUG-221: 移动端不提供全屏按钮。移动端视频全程横屏沉浸（[_lockLandscapeForVideo] +
    // [_applyVideoImmersiveMode]），画面已占满，「全屏」无额外语义；进 media_kit 全屏路由
    // 反而引入「退全屏弹回竖屏 + 两段式返回」（全屏路由吞第一次返回）。移动端永不进全屏，
    // 故隐藏入口（与双击不再全屏、[_toggleVideoFullscreen] 移动端 no-op 一致）。
    if (isMobilePlatform) return const SizedBox.shrink();
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

  Widget _controlPopoverAnchor({
    required _VideoControlPopoverKind kind,
    required LayerLink link,
    required bool desktop,
    required Widget child,
    VideoControlSlot? sourceSlot,
    VideoControlItem? sourceItem,
  }) {
    final GlobalKey? targetKey = sourceSlot == null || sourceItem == null
        ? null
        : _controlPopoverTargetKeyFor(sourceSlot, sourceItem);
    Widget anchored = CompositedTransformTarget(
      key: targetKey,
      link: link,
      child: child,
    );
    if (!desktop) return anchored;
    return MouseRegion(
      opaque: false,
      onEnter: (_) {
        _controlPopoverAnchorHovered = true;
        _showControlPopover(
          kind,
          popoverLink: link,
          sourceSlot: sourceSlot,
          sourceItem: sourceItem,
        );
      },
      onHover: (_) {
        _controlPopoverAnchorHovered = true;
        _pokeControlsVisible();
      },
      onExit: (_) {
        _controlPopoverAnchorHovered = false;
        _scheduleControlPopoverHide();
      },
      child: anchored,
    );
  }

  /// 底栏音量入口（TODO-438）：底栏只保留图标锚点，hover/click/tap 打开上方轻浮层。
  ///
  /// 滑条值仍经 [_volumeDisplay] 驱动；所有改音量入口（浮层滑条 / 滚轮 / 键盘音量键 /
  /// 静音切换 / media_kit 移动竖滑）统一经 [_syncVolumeDisplay] 写它，保持显示与 controller
  /// 单一真相同步。按钮自身不含 [Slider]，故 hover 不会改变底栏几何。
  Widget _buildVolumeButton(
    VideoPlayerController controller, {
    required bool desktop,
    required VideoControlSlot slot,
  }) {
    final LayerLink popoverLink =
        _controlPopoverLinkFor(slot, VideoControlItem.volume);
    final Widget volumeButton = ValueListenableBuilder<double>(
      valueListenable: _volumeDisplay,
      builder: (BuildContext context, double value, Widget? child) {
        return Tooltip(
          message: t.shortcut_action_video_toggle_mute,
          child: desktop
              ? MaterialDesktopCustomButton(
                  icon:
                      Icon(_volumeIconFor(value), size: _videoControlIconSize),
                  onPressed: () => _toggleControlPopover(
                    _VideoControlPopoverKind.volume,
                    popoverLink: popoverLink,
                    sourceSlot: slot,
                    sourceItem: VideoControlItem.volume,
                  ),
                )
              : MaterialCustomButton(
                  icon:
                      Icon(_volumeIconFor(value), size: _videoControlIconSize),
                  onPressed: () => _toggleControlPopover(
                    _VideoControlPopoverKind.volume,
                    popoverLink: popoverLink,
                    sourceSlot: slot,
                    sourceItem: VideoControlItem.volume,
                  ),
                ),
        );
      },
    );
    final Widget anchored = _controlPopoverAnchor(
      kind: _VideoControlPopoverKind.volume,
      link: popoverLink,
      desktop: desktop,
      sourceSlot: slot,
      sourceItem: VideoControlItem.volume,
      child: volumeButton,
    );
    if (!desktop) return anchored;
    return Listener(
      onPointerSignal: (PointerSignalEvent event) {
        if (event is PointerScrollEvent) {
          _onVolumeWheel(controller, event.scrollDelta.dy);
        }
      },
      child: anchored,
    );
  }

  LayerLink _controlPopoverLinkFor(
    VideoControlSlot slot,
    VideoControlItem item,
  ) {
    final String key = _controlPopoverKeyFor(slot, item);
    return _controlPopoverItemLinks.putIfAbsent(key, LayerLink.new);
  }

  GlobalKey _controlPopoverTargetKeyFor(
    VideoControlSlot slot,
    VideoControlItem item,
  ) {
    final String key = _controlPopoverKeyFor(slot, item);
    return _controlPopoverTargetKeys.putIfAbsent(
      key,
      () => GlobalKey(debugLabel: 'video-control-popover-target-$key'),
    );
  }

  String _controlPopoverKeyFor(VideoControlSlot slot, VideoControlItem item) =>
      '${slot.storageValue}:${item.storageValue}';

  /// 计算音量 / 倍速轻浮层相对触发按钮的锚定（TODO-560）。
  ///
  /// 弹出**方向**由按钮所在槽位决定（[videoControlPopoverDirectionForSlot]），音量与
  /// 倍速共用同一套方向逻辑：底栏向上、顶栏向下、左 / 右侧栏向右 / 左。旧实现对倍速恒
  /// 返回「向上居中」，导致按钮被放进顶栏 / 侧栏后浮层仍往上弹、与按钮脱节。
  ///
  /// 方向决定 [CompositedTransformFollower] 的 target/follower [Alignment]（让浮层贴在
  /// 按钮的内侧边）与 [gapDirection]（offset 的让位方向）。横向 / 纵向对齐沿弹出轴取按钮
  /// 同侧（左槽左对齐、右槽右对齐），跨轴取按钮中心，再由
  /// [resolveVideoControlPopoverPlacement] 做越界 clamp。
  _VideoControlPopoverPlacement _controlPopoverPlacementFor(
    _VideoControlPopoverKind kind,
    VideoControlSlot? sourceSlot,
  ) {
    final VideoControlPopoverDirection direction =
        videoControlPopoverDirectionForSlot(sourceSlot);
    switch (direction) {
      case VideoControlPopoverDirection.up:
        // 浮层底边贴按钮顶边；横向取按钮同侧（左/右/中）对齐。
        final (Alignment target, Alignment follower) = switch (sourceSlot) {
          VideoControlSlot.bottomLeft => (
              Alignment.topLeft,
              Alignment.bottomLeft,
            ),
          VideoControlSlot.bottomRight => (
              Alignment.topRight,
              Alignment.bottomRight,
            ),
          _ => (Alignment.topCenter, Alignment.bottomCenter),
        };
        return _VideoControlPopoverPlacement(
          targetAnchor: target,
          followerAnchor: follower,
          gapDirection: const Offset(0, -1),
        );
      case VideoControlPopoverDirection.down:
        // 浮层顶边贴按钮底边；横向取按钮同侧对齐。
        final (Alignment target, Alignment follower) = switch (sourceSlot) {
          VideoControlSlot.topLeft => (
              Alignment.bottomLeft,
              Alignment.topLeft,
            ),
          VideoControlSlot.topRight => (
              Alignment.bottomRight,
              Alignment.topRight,
            ),
          _ => (Alignment.bottomCenter, Alignment.topCenter),
        };
        return _VideoControlPopoverPlacement(
          targetAnchor: target,
          followerAnchor: follower,
          gapDirection: const Offset(0, 1),
        );
      case VideoControlPopoverDirection.right:
        // 左侧栏：浮层左边贴按钮右边，竖向居中。
        return const _VideoControlPopoverPlacement(
          targetAnchor: Alignment.centerRight,
          followerAnchor: Alignment.centerLeft,
          gapDirection: Offset(1, 0),
        );
      case VideoControlPopoverDirection.left:
        // 右侧栏：浮层右边贴按钮左边，竖向居中。
        return const _VideoControlPopoverPlacement(
          targetAnchor: Alignment.centerLeft,
          followerAnchor: Alignment.centerRight,
          gapDirection: Offset(-1, 0),
        );
    }
  }

  double _controlPopoverPreferredWidthFor(_VideoControlPopoverKind kind) {
    return switch (kind) {
      _VideoControlPopoverKind.volume => 220 * _videoUiScale,
      _VideoControlPopoverKind.speed => 220 * _videoUiScale,
    };
  }

  double _controlPopoverWidthFor(
    _VideoControlPopoverKind kind,
    double maxWidth,
  ) {
    final double boundedMax = math.max(0, maxWidth);
    if (boundedMax == 0) return 0;
    final double preferred = _controlPopoverPreferredWidthFor(kind);
    final double minimum = math.min(160 * _videoUiScale, boundedMax);
    return preferred.clamp(minimum, boundedMax).toDouble();
  }

  Rect? _activeControlPopoverTargetRect(BuildContext overlayContext) {
    final VideoControlSlot? slot = _activeControlPopoverSourceSlot;
    final VideoControlItem? item = _activeControlPopoverSourceItem;
    if (slot == null || item == null) return null;

    final BuildContext? targetContext =
        _controlPopoverTargetKeys[_controlPopoverKeyFor(slot, item)]
            ?.currentContext;
    final RenderObject? targetObject = targetContext?.findRenderObject();
    final RenderObject? overlayObject = overlayContext.findRenderObject();
    if (targetObject is! RenderBox || overlayObject is! RenderBox) {
      return null;
    }
    if (!targetObject.attached ||
        !overlayObject.attached ||
        !targetObject.hasSize) {
      return null;
    }

    final Offset topLeft = overlayObject.globalToLocal(
      targetObject.localToGlobal(Offset.zero),
    );
    return topLeft & targetObject.size;
  }

  double _controlPopoverAnchoredLeft({
    required Rect targetRect,
    required double width,
    required _VideoControlPopoverPlacement placement,
  }) {
    final double targetFraction = (placement.targetAnchor.x + 1) / 2;
    final double followerFraction = (placement.followerAnchor.x + 1) / 2;
    final double targetX = targetRect.left + targetRect.width * targetFraction;
    return targetX - width * followerFraction;
  }

  void _toggleControlPopover(
    _VideoControlPopoverKind kind, {
    required LayerLink popoverLink,
    VideoControlSlot? sourceSlot,
    VideoControlItem? sourceItem,
  }) {
    if (_videoControlPopover.value == kind && _controlPopoverPinned) {
      _hideControlPopover();
      return;
    }
    _showControlPopover(
      kind,
      popoverLink: popoverLink,
      pinned: true,
      sourceSlot: sourceSlot,
      sourceItem: sourceItem,
    );
  }

  void _showControlPopover(
    _VideoControlPopoverKind kind, {
    required LayerLink popoverLink,
    bool pinned = false,
    VideoControlSlot? sourceSlot,
    VideoControlItem? sourceItem,
  }) {
    if (!mounted || _videoSheetOpen) return;
    _controlPopoverHideTimer?.cancel();
    _activeControlPopoverLink = popoverLink;
    _activeControlPopoverPlacement =
        _controlPopoverPlacementFor(kind, sourceSlot);
    _activeControlPopoverSourceSlot = sourceSlot;
    _activeControlPopoverSourceItem = sourceItem;
    if (_videoControlPopover.value != kind) {
      _controlPopoverPinned = pinned;
    } else if (pinned) {
      _controlPopoverPinned = true;
    }
    _hideVideoControlEditOverlay(revealControls: false);
    if (_subtitleListVisible.value) {
      _clearSelectedMiningCues();
      _subtitleListVisible.value = false;
    }
    if (_videoSidePanel.value != null) {
      _videoSidePanel.value = null;
    }
    _videoControlPopover.value = kind;
    _pokeControlsVisible();
    _refocusVideo();
  }

  void _hideControlPopover() {
    _controlPopoverHideTimer?.cancel();
    _controlPopoverPinned = false;
    _activeControlPopoverLink = null;
    _activeControlPopoverPlacement = null;
    _activeControlPopoverSourceSlot = null;
    _activeControlPopoverSourceItem = null;
    if (_videoControlPopover.value != null) {
      _videoControlPopover.value = null;
    }
  }

  void _scheduleControlPopoverHide() {
    _controlPopoverHideTimer?.cancel();
    if (_controlPopoverPinned) return;
    _controlPopoverHideTimer = Timer(const Duration(milliseconds: 180), () {
      if (_controlPopoverAnchorHovered || _controlPopoverPanelHovered) return;
      _hideControlPopover();
    });
  }

  Widget _controlPopoverHoverKeepAlive({required Widget child}) {
    if (!_isDesktopVideoControls) return child;
    return MouseRegion(
      opaque: false,
      onEnter: (_) {
        _controlPopoverPanelHovered = true;
        _pokeControlsVisible();
      },
      onHover: (_) {
        _controlPopoverPanelHovered = true;
        _pokeControlsVisible();
      },
      onExit: (_) {
        _controlPopoverPanelHovered = false;
        _scheduleControlPopoverHide();
      },
      child: child,
    );
  }

  Widget _buildVideoControlPopoverOverlay(VideoPlayerController controller) {
    return Positioned.fill(
      child: ValueListenableBuilder<_VideoControlPopoverKind?>(
        valueListenable: _videoControlPopover,
        builder: (BuildContext context, _VideoControlPopoverKind? kind, _) {
          if (kind == null) return const SizedBox.shrink();
          final LayerLink? link = _activeControlPopoverLink;
          if (link == null) return const SizedBox.shrink();
          return LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final _VideoControlPopoverPlacement placement =
                  _activeControlPopoverPlacement ??
                      _controlPopoverPlacementFor(kind, null);
              final double gap = _videoControlPopoverGapBase * _videoUiScale;
              final Rect? targetRect = _activeControlPopoverTargetRect(context);
              final VideoControlSlot? sourceSlot =
                  _activeControlPopoverSourceSlot;
              // 横向越界 clamp 对音量与倍速同样适用（TODO-560）：倍速浮层此前完全不走
              // resolve，放进顶/侧栏后既不换方向也不修横向。
              final VideoControlPopoverPlacement? resolved =
                  sourceSlot != null && targetRect != null
                      ? resolveVideoControlPopoverPlacement(
                          playerBounds: Offset.zero &
                              Size(
                                constraints.maxWidth,
                                constraints.maxHeight,
                              ),
                          targetRect: targetRect,
                          preferredWidth:
                              _controlPopoverPreferredWidthFor(kind),
                          sourceSlot: sourceSlot,
                          gap: gap,
                          minWidth: 160 * _videoUiScale,
                        )
                      : null;
              final double width = resolved?.width ??
                  _controlPopoverWidthFor(kind, constraints.maxWidth);
              // 仅竖向弹（顶/底栏）需要横向修正把宽浮层拉回画面内；侧栏弹时横向由
              // gapDirection 的 gap 提供，不叠加 dx（否则与 gap 双重位移）。
              final bool verticalPopover = placement.gapDirection.dx == 0;
              final double dx =
                  !verticalPopover || resolved == null || targetRect == null
                      ? 0
                      : resolved.left -
                          _controlPopoverAnchoredLeft(
                            targetRect: targetRect,
                            width: width,
                            placement: placement,
                          );
              return Stack(
                children: <Widget>[
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: _hideControlPopover,
                      child: const SizedBox.expand(),
                    ),
                  ),
                  CompositedTransformFollower(
                    link: link,
                    showWhenUnlinked: false,
                    targetAnchor: placement.targetAnchor,
                    followerAnchor: placement.followerAnchor,
                    // 让位方向随槽位变（TODO-560）：底栏 (0,-gap) 向上、顶栏 (0,gap) 向下、
                    // 侧栏 (±gap,0) 向左/右；竖向弹时再叠加 dx 横向修正。
                    offset: placement.gapDirection * gap + Offset(dx, 0),
                    child: _controlPopoverHoverKeepAlive(
                      child: _buildVideoControlPopoverContent(
                        kind,
                        controller,
                        width: width,
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildVideoControlPopoverContent(
    _VideoControlPopoverKind kind,
    VideoPlayerController controller, {
    required double width,
  }) {
    switch (kind) {
      case _VideoControlPopoverKind.volume:
        return _buildVolumePopover(width: width);
      case _VideoControlPopoverKind.speed:
        return _buildSpeedPopover(width: width);
    }
  }

  Widget _buildControlPopoverFrame({
    required double width,
    required Widget child,
  }) {
    final ColorScheme cs = _videoChromeColorScheme(context);
    return Material(
      color: Colors.transparent,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.7)),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: cs.shadow.withValues(alpha: 0.28),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints.tightFor(width: width),
          child: Padding(
            padding: EdgeInsets.all(10 * _videoUiScale),
            child: child,
          ),
        ),
      ),
    );
  }

  Widget _buildVolumePopover({required double width}) {
    return ValueListenableBuilder<double>(
      valueListenable: _volumeDisplay,
      builder: (BuildContext context, double value, Widget? child) {
        final double clamped = value.clamp(0.0, 100.0).toDouble();
        final ColorScheme cs = _videoChromeColorScheme(context);
        return VideoVolumePopoverCard(
          width: width,
          value: clamped,
          uiScale: _videoUiScale,
          colorScheme: cs,
          icon: _volumeIconFor(clamped),
          tooltip: t.shortcut_action_video_toggle_mute,
          onToggleMute: () => unawaited(_toggleMute()),
          onChanged: _setVolumeFromSlider,
        );
      },
    );
  }

  double _nearestSpeedPreset(double value, List<double> presets) {
    double nearest = presets.first;
    double nearestDistance = (value - nearest).abs();
    for (final double preset in presets.skip(1)) {
      final double distance = (value - preset).abs();
      if (distance < nearestDistance) {
        nearest = preset;
        nearestDistance = distance;
      }
    }
    return nearest;
  }

  Widget _buildSpeedPopover({required double width}) {
    final ColorScheme cs = _videoChromeColorScheme(context);
    final List<double> speedPresets = _speedMenuPresets();
    final double sliderValue = _playbackSpeed.clamp(0.5, 2.0).toDouble();
    return _buildControlPopoverFrame(
      width: width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.speed, color: cs.primary, size: 20 * _videoUiScale),
              SizedBox(width: 8 * _videoUiScale),
              Expanded(
                child: Text(
                  '${_playbackSpeed.toStringAsFixed(1)}x',
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 14 * _videoUiScale,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => unawaited(_setSpeed(1.0)),
                child: const Text('1.0x'),
              ),
            ],
          ),
          Slider(
            value: sliderValue,
            min: 0.5,
            max: 2.0,
            divisions: speedPresets.length > 1 ? speedPresets.length - 1 : null,
            label: '${_playbackSpeed.toStringAsFixed(1)}x',
            onChanged: (double value) {
              final double next = _nearestSpeedPreset(value, speedPresets);
              unawaited(_setSpeed(next));
            },
          ),
        ],
      ),
    );
  }

  /// 滑条拖动写音量：即时写 controller + OSD + 同步显示真相源（TODO-377）。
  void _setVolumeFromSlider(double value) {
    final double next = value.clamp(0.0, 100.0).toDouble();
    unawaited(_applyUserVideoVolume(next));
  }

  /// 桌面：悬停音量控件时滚轮调音量（向上滚增、向下滚减，[_volumeStep] 步进）。滚轮
  /// 的 [scrollDelta] 向下为正，故取负号让「上滚 = 增大」符合直觉。
  void _onVolumeWheel(VideoPlayerController controller, double scrollDeltaY) {
    final double delta = scrollDeltaY > 0 ? -_volumeStep : _volumeStep;
    unawaited(_adjustVolume(delta));
  }

  /// 同步音量显示真相源（[_volumeDisplay]）→ 驱动音量图标与浮层滑条重建。
  /// 所有改音量入口（滑条 / 滚轮 / 键盘音量键 / 静音切换 / media_kit 移动竖滑）统一调它。
  void _syncVolumeDisplay(double volume) {
    _volumeDisplay.value = volume.clamp(0.0, 100.0).toDouble();
  }

  /// 应用一次用户真实音量变化。默认持久化；M 静音传 [persist]=false，只更新显示和 HUD。
  Future<void> _applyUserVideoVolume(
    double volume, {
    bool persist = true,
    bool applyToController = true,
  }) async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    final double clamped = volume.clamp(0.0, 100.0).toDouble();
    _syncVolumeDisplay(clamped);
    if (mounted) _showVolumeOsd(clamped);
    if (applyToController) {
      await controller.setVolume(clamped);
    }
    if (persist) {
      _playbackVolume = clamped;
      _queuePersistVideoVolume(clamped);
    }
  }

  void _queuePersistVideoVolume(double volume) {
    _pendingVolumePersist = volume.clamp(0.0, 100.0).toDouble();
    _volumePersistDebounce?.cancel();
    _volumePersistDebounce = Timer(const Duration(milliseconds: 350), () {
      unawaited(_flushPersistedVideoVolume());
    });
  }

  Future<void> _flushPersistedVideoVolume() async {
    final double? pending = _pendingVolumePersist;
    if (pending == null) return;
    _volumePersistDebounce?.cancel();
    _volumePersistDebounce = null;
    _pendingVolumePersist = null;
    await appModel.prefsRepo.setPref(_volumePrefKey, pending);
  }

  MaterialDesktopVideoControlsThemeData _desktopControlsTheme(
    VideoPlayerController controller,
    VideoControlLayout layout,
  ) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return MaterialDesktopVideoControlsThemeData(
      // 无操作 2 秒后控制条自动隐藏（TODO-056，media_kit 默认 3 秒偏长）。
      controlsHoverDuration: const Duration(seconds: 2),
      // 控制条淡入淡出时长（TODO-435）：与侧边锁按钮 / 浮动 rail 读同一真相源
      // [_videoControlsTransitionDuration]，让三者同速淡入淡出（值等于 media_kit
      // 桌面默认 150ms，显式写出后改一处全部跟随）。
      controlsTransitionDuration: _videoControlsTransitionDuration,
      // TODO-364：media_kit 控制条把它**真实**的 `visible` 推进这个 notifier，字幕避让
      // 唯一消费它（见 [_mediaKitControlsVisible] / [_applyControlsVisibilityFromMediaKit]），
      // 不再另建镜像 + 第二个 Timer（旧实现两套计时相位反 = 本 BUG 根因）。
      visibilityNotifier: _mediaKitControlsVisible,
      // TODO-565：进度条（seek bar）经 media_kit 内部 player.seek 绕过 controller 的
      // seekMs 统一清除点，用户开始拖动时清掉「主动跳转目标」快照——否则点字幕行后
      // 的在途 seek 宽限窗口内拖进度条到更早句，会被误 snap 回旧目标句。fork 的 seek
      // bar 把内部 onSeekStart 与本回调合并调用（third_party/media_kit_video）。
      onSeekStart: () => controller.clearSeekTargetSnap(),
      // 控制条隐藏时一并隐藏鼠标光标（默认 false 会让光标常驻，BUG-106）。
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
      // 视频内顶栏（替代被删的 Scaffold AppBar，BUG-102）：左右按钮和标题均从用户布局
      // slot 渲染；标题仍监听 _titleNotifier。
      topButtonBar: <Widget>[
        _topBarSlotGroup(
          VideoControlSlot.topLeft,
          controller,
          layout: layout,
          desktop: true,
        ),
        _topBarTitle(),
        _topBarSlotGroup(
          VideoControlSlot.topRight,
          controller,
          layout: layout,
          desktop: true,
        ),
      ],
      bottomButtonBar: <Widget>[
        // 三区 Stack 布局把 play 钉在几何中心（BUG-257）：左时间 / 右尾部按钮 / 居中
        // seek 簇。±10s 带可见标注（旧底栏只有 tooltip，用户看不懂图标）。media_kit 把
        // bottomButtonBar 放进 Row，用单个 [Expanded] 占满整宽承接绝对定位布局。
        // 进度/时长文字吃「界面大小」（TODO-128）、5 键带 Tooltip（BUG-247）均在
        // [_centeredBottomControlBar] 内保留。
        Expanded(
          child: _centeredBottomControlBar(controller, desktop: true),
        ),
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
    VideoControlLayout layout,
  ) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    // 进度条 / 底部按钮条的底部留白（BUG-184）：基线 + 系统导航栏/手势栏 inset，
    // 让进度条回到「底部按钮条同一基线、抬离屏幕物理最底」的控制条惯例位置，而不是
    // 用 media_kit 构造器默认的 `bottom: 0` 贴在屏幕最下面。
    final double bottomChromeInset =
        _videoBottomChromeBaseline + _videoBottomSystemInset();
    // 进度条抬到底部按钮条上方（TODO-156/BUG-217）：media_kit 把进度条与按钮条放同一
    // 个 bottomCenter Stack、都按 bottom 对齐，进度条 bottom 必须 = 按钮条底部基线 +
    // 按钮条高 + 间距，否则两者落同一基线重叠。保留 [bottomChromeInset]（BUG-184 抬离
    // 系统栏）作为按钮条基线，进度条偏移叠加其上。
    final double seekBarBottom =
        bottomChromeInset + _videoButtonBarHeight + _videoSeekBarButtonGap;
    return MaterialVideoControlsThemeData(
      // 无操作 2 秒后控制条自动隐藏（TODO-056，media_kit 默认 3 秒偏长）。
      controlsHoverDuration: const Duration(seconds: 2),
      // 控制条淡入淡出时长（TODO-435）：与侧边锁按钮 / 浮动 rail 读同一真相源
      // [_videoControlsTransitionDuration]，让三者同速淡入淡出（值等于 media_kit
      // 移动默认 300ms，显式写出后改一处全部跟随）。
      controlsTransitionDuration: _videoControlsTransitionDuration,
      // TODO-364：移动控制条的真实 `visible`（含 onTap toggle）推进同一个 notifier，字幕避让
      // 唯一消费它，移动端不再用 Hibiki 镜像独立 toggle（旧实现并发操作时方向反 = 本 BUG 根因）。
      visibilityNotifier: _mediaKitControlsVisible,
      // TODO-565：进度条（seek bar）经 media_kit 内部 player.seek 绕过 controller 的
      // seekMs 统一清除点，用户开始拖动时清掉「主动跳转目标」快照——否则点字幕行后
      // 的在途 seek 宽限窗口内拖进度条到更早句，会被误 snap 回旧目标句。fork 的 seek
      // bar 把内部 onSeekStart 与本回调合并调用（third_party/media_kit_video）。
      onSeekStart: () => controller.clearSeekTargetSnap(),
      // TODO-057: 启用 media_kit 移动控制条内建的「左半区竖滑调亮度 / 右半区竖滑
      // 调音量」手势，指示器由 Hibiki 的左右百分比 HUD 接管。仅移动端有此控制条；桌面走
      // [_desktopControlsTheme]（无此手势，屏幕亮度本就不可控，诚实降级）。不开
      // seekGesture（横滑 seek 超范围，且与既有 seek 键 085/090 / 双击全屏语义重叠）。
      // 单击暂停 / 字幕点击查词不受影响：media_kit 的竖直 drag 与 tap 同一手势 arena，
      // 纯点击时 drag 不启动。亮度回调经 [ScreenBrightnessController]（桌面 no-op）。
      volumeGesture: true,
      volumeIndicatorBuilder: (BuildContext _, double __) =>
          const SizedBox.shrink(),
      brightnessGesture: _brightness.canControl,
      brightnessIndicatorBuilder: (BuildContext _, double __) =>
          const SizedBox.shrink(),
      // 竖滑灵敏度降到约 1/3（TODO-172/BUG-230）：media_kit 默认 100 太敏感，轻划即
      // 拉满亮度/音量。值越大越不敏感（见 [_videoVerticalGestureSensitivity]）。
      verticalGestureSensitivity: _videoVerticalGestureSensitivity,
      seekGesture: false,
      onVolumeChanged: _onMediaKitVolumeChanged,
      onBrightnessChanged: _onMediaKitBrightnessChanged,
      initialVolume: (controller.volume / 100.0).clamp(0.0, 1.0).toDouble(),
      initialBrightness: _enterBrightness,
      onBrightnessReset: () =>
          unawaited(_brightness.restore(previous: _enterBrightness)),
      // 进度条抬到按钮条上方（TODO-156）：bottom = 按钮条基线 + 按钮条高 + 间距，
      // 不再与按钮条同基线重叠。
      seekBarMargin: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: seekBarBottom,
      ),
      // 底部按钮条留在系统栏上方基线（沿用 media_kit 默认的左右 16/8）。
      bottomButtonBarMargin: EdgeInsets.only(
        left: 16,
        right: 8,
        bottom: bottomChromeInset,
      ),
      // 进度条触摸热区 / 滑块 / 轨道整体抬高（TODO-157/BUG-218）：media_kit 默认
      // seekBarContainerHeight=36 / seekBarThumbSize=12.8 / seekBarHeight=2.4 在手机上
      // 太细、难命中（手指比默认热区窄，滑不到 / 拖不动）。改用随界面缩放的基线放大
      // 命中区与可视轨道。三者由 [_videoSeekBarButtonGap] 把进度条整体抬到按钮条上方
      // 后才有竖直空间承接更高的热区（向上长，不向下侵入系统边缘手势区）。
      seekBarContainerHeight: _videoSeekBarContainerHeight,
      seekBarThumbSize: _videoSeekBarThumbSize,
      seekBarHeight: _videoSeekBarTrackHeight,
      seekBarPositionColor: cs.primary,
      seekBarThumbColor: cs.primary,
      buttonBarButtonColor: cs.primary,
      buttonBarHeight: _videoButtonBarHeight,
      buttonBarButtonSize: _videoControlIconSize,
      primaryButtonBar: const <Widget>[],
      // 视频内顶栏（替代被删的 Scaffold AppBar，BUG-102）：左右按钮和标题均从用户布局
      // slot 渲染；标题仍监听 _titleNotifier。
      topButtonBar: <Widget>[
        _topBarSlotGroup(
          VideoControlSlot.topLeft,
          controller,
          layout: layout,
          desktop: false,
        ),
        _topBarTitle(),
        _topBarSlotGroup(
          VideoControlSlot.topRight,
          controller,
          layout: layout,
          desktop: false,
        ),
      ],
      bottomButtonBar: <Widget>[
        // 三区 Stack 布局把 play 钉在几何中心（BUG-257）：左时间 / 右尾部按钮 / 居中
        // seek 簇，与桌面同源（[_centeredBottomControlBar]）。±10s 带可见标注、5 键带
        // Tooltip（BUG-247）、上/下一句走动态 cue 导航（无字幕段对称回退/前进，TODO-073/
        // TODO-119/BUG-198，动态 _asbConfig.seekSeconds 不写死）均在 helper 内保留。
        Expanded(
          child: _centeredBottomControlBar(controller, desktop: false),
        ),
      ],
    );
  }

  /// TODO-399 decision 3b: every chip-renderable button (learning keys PLUS the
  /// transport / nav keys: play/pause, seek +/-, cue nav, screenshot, subtitle /
  /// audio track, episode list, fullscreen) that the user placed into [slot],
  /// in order. Non-chip special renders ([volume], [title],
  /// [positionIndicator]) stay on their dedicated render paths.
  List<VideoControlItem> _slotChipItems(VideoControlSlot slot) {
    return <VideoControlItem>[
      for (final VideoControlItem item in _controlLayout.itemsIn(slot))
        if (item.isChipRenderable &&
            item != VideoControlItem.volume &&
            _shouldRenderControlItem(item))
          item,
    ];
  }

  List<Widget> _bottomSlotButtons(
    VideoControlSlot slot,
    VideoPlayerController controller, {
    required bool desktop,
    required bool roomyBottomBar,
  }) {
    final List<VideoControlItem> rawItems = _controlLayout.itemsIn(slot);
    return <Widget>[
      for (final VideoControlItem item in _slotChipItems(slot))
        _buildBottomSlotButton(
          item,
          controller,
          desktop: desktop,
          slot: slot,
          roomyBottomBar: roomyBottomBar,
        ),
      if (rawItems.contains(VideoControlItem.volume))
        _buildVolumeButton(controller, desktop: desktop, slot: slot),
    ];
  }

  Widget _topBarTitle() {
    if (!_controlLayout.itemsIn(VideoControlSlot.topCenter).contains(
          VideoControlItem.title,
        )) {
      return const Spacer();
    }
    return Expanded(
      // 标题走 ValueListenableBuilder（BUG-120）：全屏路由不随页面 setState 重建，
      // 监听 _titleNotifier 才能在全屏换集后刷新标题。Align 固定标题起点：
      // topRight 清空时不靠右侧空白占位撑布局，已有按钮未清空时仍保持原有 Row 顺序。
      child: _topBarTitleText(
        alignment: AlignmentDirectional.centerStart,
      ),
    );
  }

  Widget _topBarInlineTitle(VideoControlSlot slot) {
    final bool alignEnd = slot == VideoControlSlot.topRight;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 8 * _videoUiScale),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 220 * _videoUiScale),
        child: _topBarTitleText(
          alignment: alignEnd
              ? AlignmentDirectional.centerEnd
              : AlignmentDirectional.centerStart,
        ),
      ),
    );
  }

  Widget _topBarTitleText({required AlignmentGeometry alignment}) {
    return Align(
      alignment: alignment,
      child: ValueListenableBuilder<String?>(
        valueListenable: _titleNotifier,
        builder: (BuildContext _, String? title, __) => Text(
          title ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: alignment == AlignmentDirectional.centerEnd
              ? TextAlign.end
              : TextAlign.start,
          style: _videoControlTitleStyle(_videoChromeColorScheme(context)),
        ),
      ),
    );
  }

  Widget _buildBottomSlotButton(
    VideoControlItem item,
    VideoPlayerController controller, {
    required bool desktop,
    required VideoControlSlot slot,
    required bool roomyBottomBar,
  }) {
    final VideoControlButton? legacy = item.legacyButton;
    if (legacy != null) {
      return _buildVideoControlButton(
        controller,
        legacy,
        desktop: desktop,
        slot: slot,
      );
    }
    switch (item) {
      case VideoControlItem.playPause:
        return Tooltip(
          message: t.video_bottom_play_pause,
          child: desktop
              ? MaterialDesktopPlayOrPauseButton(
                  iconSize: _videoPlayPauseIconSize,
                )
              : MaterialPlayOrPauseButton(iconSize: _videoPlayPauseIconSize),
        );
      case VideoControlItem.previousCue:
        return Tooltip(
          message: t.video_bottom_prev_cue,
          child: desktop
              ? MaterialDesktopCustomButton(
                  icon: Icon(Icons.skip_previous, size: _videoControlIconSize),
                  onPressed: () => _skipCueAndPokeControls(forward: false),
                )
              : MaterialCustomButton(
                  icon: Icon(Icons.skip_previous, size: _videoControlIconSize),
                  onPressed: () => _skipCueAndPokeControls(forward: false),
                ),
        );
      case VideoControlItem.nextCue:
        return Tooltip(
          message: t.video_bottom_next_cue,
          child: desktop
              ? MaterialDesktopCustomButton(
                  icon: Icon(Icons.skip_next, size: _videoControlIconSize),
                  onPressed: () => _skipCueAndPokeControls(forward: true),
                )
              : MaterialCustomButton(
                  icon: Icon(Icons.skip_next, size: _videoControlIconSize),
                  onPressed: () => _skipCueAndPokeControls(forward: true),
                ),
        );
      case VideoControlItem.seekBackward:
        if (roomyBottomBar) {
          return _seekLabelButton(
            icon: Icons.fast_rewind_rounded,
            label: t.video_bottom_seek_back_label,
            tooltip: t.video_bottom_seek_back,
            color: Theme.of(context).colorScheme.primary,
            onPressed: () => _seekRelative(-10000),
          );
        }
        return _plainSlotButton(item, controller, desktop: desktop, slot: slot);
      case VideoControlItem.seekForward:
        if (roomyBottomBar) {
          return _seekLabelButton(
            icon: Icons.fast_forward_rounded,
            label: t.video_bottom_seek_forward_label,
            tooltip: t.video_bottom_seek_forward,
            color: Theme.of(context).colorScheme.primary,
            onPressed: () => _seekRelative(10000),
          );
        }
        return _plainSlotButton(item, controller, desktop: desktop, slot: slot);
      case VideoControlItem.fullscreen:
        return _buildFullscreenButton(desktop: desktop);
      case VideoControlItem.back:
      case VideoControlItem.immersiveLock:
      case VideoControlItem.screenshot:
      case VideoControlItem.clipExport:
      case VideoControlItem.subtitleTrack:
      case VideoControlItem.audioTrack:
      case VideoControlItem.previousEpisode:
      case VideoControlItem.nextEpisode:
      case VideoControlItem.episodeList:
      case VideoControlItem.previousChapter:
      case VideoControlItem.nextChapter:
      case VideoControlItem.chapterList:
        return _plainSlotButton(item, controller, desktop: desktop, slot: slot);
      case VideoControlItem.volume:
      case VideoControlItem.title:
      case VideoControlItem.positionIndicator:
      case VideoControlItem.speed:
      case VideoControlItem.subtitleList:
      case VideoControlItem.favoriteSentence:
      case VideoControlItem.favoriteSentences:
      case VideoControlItem.settings:
        return const SizedBox.shrink();
    }
  }

  Widget _plainSlotButton(
    VideoControlItem item,
    VideoPlayerController controller, {
    required bool desktop,
    required VideoControlSlot slot,
  }) {
    final Widget icon = Icon(
      _videoControlItemIcon(item),
      size: _videoControlIconSize,
    );
    return Tooltip(
      message: _videoControlItemTooltip(item),
      child: desktop
          ? MaterialDesktopCustomButton(
              icon: icon,
              onPressed: () => _activateVideoControlItem(
                item,
                controller,
                sourceSlot: slot,
              ),
            )
          : MaterialCustomButton(
              icon: icon,
              onPressed: () => _activateVideoControlItem(
                item,
                controller,
                sourceSlot: slot,
              ),
            ),
    );
  }

  bool _shouldRenderControlItem(VideoControlItem item) {
    switch (item) {
      case VideoControlItem.previousEpisode:
      case VideoControlItem.nextEpisode:
      case VideoControlItem.episodeList:
        return _isPlaylist;
      case VideoControlItem.previousChapter:
      case VideoControlItem.nextChapter:
      case VideoControlItem.chapterList:
        return _hasChapters;
      case VideoControlItem.volume:
      case VideoControlItem.title:
      case VideoControlItem.positionIndicator:
        return false;
      case VideoControlItem.back:
      case VideoControlItem.immersiveLock:
      case VideoControlItem.speed:
      case VideoControlItem.subtitleList:
      case VideoControlItem.favoriteSentence:
      case VideoControlItem.favoriteSentences:
      case VideoControlItem.settings:
      case VideoControlItem.playPause:
      case VideoControlItem.seekBackward:
      case VideoControlItem.seekForward:
      case VideoControlItem.previousCue:
      case VideoControlItem.nextCue:
      case VideoControlItem.fullscreen:
      case VideoControlItem.screenshot:
      case VideoControlItem.clipExport:
      case VideoControlItem.subtitleTrack:
      case VideoControlItem.audioTrack:
        return true;
    }
  }

  /// TODO-421 phase 1: render the buttons the user placed into the **top** slots
  /// ([VideoControlSlot.topLeft] / [topRight]) as media_kit chrome buttons so
  /// they live INSIDE the fixed top bar row (`topButtonBar`), not in a separate
  /// floating strip below it. The user picked "Top bar (left/right)" expecting
  /// the real top bar, so the buttons are injected into the same [topButtonBar]
  /// array as the back / title / track-track chrome — they inherit the theme's
  /// `buttonBarButtonColor` / `buttonBarButtonSize` and fade in / out with the
  /// rest of the controls (a plain Hibiki [IconButton] would not).
  ///
  /// Renders **every** chip-renderable item in the slot ([_slotChipItems]), not
  /// just the five learning keys: the customization editor's palette
  /// ([VideoControlItem.customizableItems]) lets users drop transport / nav keys
  /// (screenshot, audio track, seek, …) into the top slots too, so filtering to
  /// learning keys here would silently drop those placements off the player after
  /// the floating top rail is removed. The shared [_activateVideoControlItem]
  /// dispatcher handles both learning and transport / nav activation.
  ///
  /// The whole slot is one flex child of the fixed top bar. In particular,
  /// [VideoControlSlot.topRight] must stay a single right-aligned button group:
  /// if every button is injected as its own [Flexible] child of the outer row,
  /// Flutter spreads the right-side buttons toward the title/middle on narrow
  /// windows. The group scrolls horizontally when squeezed, so buttons remain
  /// reachable without painting past the edge.
  Widget _topBarSlotGroup(
    VideoControlSlot slot,
    VideoPlayerController controller, {
    required VideoControlLayout layout,
    required bool desktop,
  }) {
    final List<VideoControlItem> rawItems = layout.itemsIn(slot);
    final List<VideoControlItem> items = <VideoControlItem>[
      for (final VideoControlItem item in rawItems)
        if (item == VideoControlItem.title ||
            (item.isChipRenderable && _shouldRenderControlItem(item)))
          item,
    ];
    if (items.isEmpty) return const SizedBox.shrink();

    Widget buttonFor(VideoControlItem item) {
      final LayerLink? popoverLink = item == VideoControlItem.speed
          ? _controlPopoverLinkFor(slot, item)
          : null;
      final Widget button = Tooltip(
        message: _videoControlItemTooltip(item),
        child: desktop
            ? MaterialDesktopCustomButton(
                icon: Icon(
                  _videoControlItemIcon(item),
                  size: _videoControlIconSize,
                ),
                onPressed: () => _activateVideoControlItem(
                  item,
                  controller,
                  popoverLink: popoverLink,
                  sourceSlot: slot,
                ),
              )
            : MaterialCustomButton(
                icon: Icon(
                  _videoControlItemIcon(item),
                  size: _videoControlIconSize,
                ),
                onPressed: () => _activateVideoControlItem(
                  item,
                  controller,
                  popoverLink: popoverLink,
                  sourceSlot: slot,
                ),
              ),
      );
      if (popoverLink == null) return button;
      return _controlPopoverAnchor(
        kind: _VideoControlPopoverKind.speed,
        link: popoverLink,
        desktop: desktop,
        sourceSlot: slot,
        sourceItem: VideoControlItem.speed,
        child: button,
      );
    }

    return Flexible(
      fit: FlexFit.loose,
      child: Align(
        alignment: slot == VideoControlSlot.topRight
            ? Alignment.centerRight
            : Alignment.centerLeft,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          reverse: slot == VideoControlSlot.topRight,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: slot == VideoControlSlot.topRight
                ? MainAxisAlignment.end
                : MainAxisAlignment.start,
            children: <Widget>[
              for (final VideoControlItem item in items)
                if (item == VideoControlItem.title)
                  _topBarInlineTitle(slot)
                else
                  buttonFor(item),
            ],
          ),
        ),
      ),
    );
  }

  String get _clipExportTooltip {
    if (_clipExporting) return t.video_clip_exporting;
    if (_clipExportMarking) return t.video_clip_export_stop;
    return t.video_clip_export_start;
  }

  IconData get _clipExportIcon {
    if (_clipExporting) return Icons.hourglass_top;
    if (_clipExportMarking) return Icons.stop_circle_outlined;
    return Icons.movie_creation_outlined;
  }

  /// Icon for any chip-renderable [VideoControlItem] (learning + transport/nav).
  IconData _videoControlItemIcon(VideoControlItem item) {
    final VideoControlButton? legacy = item.legacyButton;
    if (legacy != null) return _videoControlButtonIcon(legacy);
    switch (item) {
      case VideoControlItem.playPause:
        return Icons.play_arrow_rounded;
      case VideoControlItem.back:
        return Icons.arrow_back;
      case VideoControlItem.immersiveLock:
        return _immersiveLocked.value
            ? Icons.lock_outline
            : Icons.lock_open_outlined;
      case VideoControlItem.seekBackward:
        return Icons.fast_rewind;
      case VideoControlItem.seekForward:
        return Icons.fast_forward;
      case VideoControlItem.previousCue:
        return Icons.skip_previous;
      case VideoControlItem.nextCue:
        return Icons.skip_next;
      case VideoControlItem.fullscreen:
        return Icons.fullscreen;
      case VideoControlItem.screenshot:
        return Icons.photo_camera_outlined;
      case VideoControlItem.clipExport:
        return _clipExportIcon;
      case VideoControlItem.subtitleTrack:
        return Icons.subtitles;
      case VideoControlItem.audioTrack:
        return Icons.audiotrack;
      case VideoControlItem.previousEpisode:
        return Icons.skip_previous;
      case VideoControlItem.nextEpisode:
        return Icons.skip_next;
      case VideoControlItem.episodeList:
        return Icons.playlist_play;
      case VideoControlItem.previousChapter:
        return Icons.first_page;
      case VideoControlItem.nextChapter:
        return Icons.last_page;
      case VideoControlItem.chapterList:
        return Icons.format_list_numbered;
      // Non-chip special renders never reach here (filtered by isChipRenderable).
      case VideoControlItem.volume:
      case VideoControlItem.title:
      case VideoControlItem.positionIndicator:
      case VideoControlItem.speed:
      case VideoControlItem.subtitleList:
      case VideoControlItem.favoriteSentence:
      case VideoControlItem.favoriteSentences:
      case VideoControlItem.settings:
        return Icons.tune;
    }
  }

  /// Tooltip for any chip-renderable [VideoControlItem].
  String _videoControlItemTooltip(VideoControlItem item) {
    final VideoControlButton? legacy = item.legacyButton;
    if (legacy != null) return _videoControlButtonTooltip(legacy);
    switch (item) {
      case VideoControlItem.playPause:
        return t.video_control_play_pause;
      case VideoControlItem.back:
        return MaterialLocalizations.of(context).backButtonTooltip;
      case VideoControlItem.immersiveLock:
        return _immersiveLocked.value
            ? t.video_immersive_unlock
            : t.video_menu_lock;
      case VideoControlItem.seekBackward:
        return t.video_control_seek_backward;
      case VideoControlItem.seekForward:
        return t.video_control_seek_forward;
      case VideoControlItem.previousCue:
        return t.video_control_previous_cue;
      case VideoControlItem.nextCue:
        return t.video_control_next_cue;
      case VideoControlItem.fullscreen:
        return t.video_control_fullscreen;
      case VideoControlItem.screenshot:
        return t.video_control_screenshot;
      case VideoControlItem.clipExport:
        return _clipExportTooltip;
      case VideoControlItem.subtitleTrack:
        return t.video_control_subtitle_track;
      case VideoControlItem.audioTrack:
        return t.video_control_audio_track;
      case VideoControlItem.previousEpisode:
        return t.video_prev_episode;
      case VideoControlItem.nextEpisode:
        return t.video_next_episode;
      case VideoControlItem.episodeList:
        return t.video_control_episode_list;
      case VideoControlItem.previousChapter:
        return t.shortcut_action_video_previous_chapter;
      case VideoControlItem.nextChapter:
        return t.shortcut_action_video_next_chapter;
      case VideoControlItem.chapterList:
        return t.video_chapters;
      case VideoControlItem.volume:
      case VideoControlItem.title:
      case VideoControlItem.positionIndicator:
      case VideoControlItem.speed:
      case VideoControlItem.subtitleList:
      case VideoControlItem.favoriteSentence:
      case VideoControlItem.favoriteSentences:
      case VideoControlItem.settings:
        return '';
    }
  }

  /// Activate any chip-renderable [VideoControlItem] (rail tap handler). Learning
  /// keys go through the legacy dispatcher; transport / nav keys call the same
  /// page methods the media_kit chrome uses, so behaviour is identical wherever
  /// the user places the button.
  void _activateVideoControlItem(
    VideoControlItem item,
    VideoPlayerController controller, {
    LayerLink? popoverLink,
    VideoControlSlot? sourceSlot,
  }) {
    final VideoControlButton? legacy = item.legacyButton;
    if (legacy != null) {
      _activateVideoControlButton(
        legacy,
        popoverLink: popoverLink,
        sourceSlot: sourceSlot,
      );
      return;
    }
    switch (item) {
      case VideoControlItem.back:
        unawaited(_handleBackOrExit());
        break;
      case VideoControlItem.immersiveLock:
        _toggleImmersiveLock();
        break;
      case VideoControlItem.playPause:
        unawaited(controller.playOrPause());
        break;
      case VideoControlItem.seekBackward:
        unawaited(_seekRelative(-10000));
        break;
      case VideoControlItem.seekForward:
        unawaited(_seekRelative(10000));
        break;
      case VideoControlItem.previousCue:
        unawaited(controller.skipToPrevCueOrSeekBack(
          seekSeconds: _asbConfig.seekSeconds,
        ));
        break;
      case VideoControlItem.nextCue:
        unawaited(controller.skipToNextCueOrSeekForward(
          seekSeconds: _asbConfig.seekSeconds,
        ));
        break;
      case VideoControlItem.fullscreen:
        _runWhenImmersiveAllowsFullControls(() {
          final BuildContext? ctx = _videoControlsContext;
          if (ctx != null && ctx.mounted) {
            unawaited(_toggleVideoFullscreen(ctx));
          }
        });
        break;
      case VideoControlItem.screenshot:
        unawaited(_saveScreenshot());
        break;
      case VideoControlItem.clipExport:
        unawaited(_toggleClipExport());
        break;
      case VideoControlItem.subtitleTrack:
        unawaited(
          _showSubtitleSourceMenu(controller, sourceSlot: sourceSlot),
        );
        break;
      case VideoControlItem.audioTrack:
        _showAudioTrackMenu(controller, sourceSlot: sourceSlot);
        break;
      case VideoControlItem.previousEpisode:
        if (_isPlaylist && _currentEpisode > 0) {
          _switchEpisode(
            _currentEpisode - 1,
            intent: EpisodeStartIntent.manualPrevious,
          );
        }
        break;
      case VideoControlItem.nextEpisode:
        if (_isPlaylist && _currentEpisode < _episodes.length - 1) {
          _switchEpisode(
            _currentEpisode + 1,
            intent: EpisodeStartIntent.manualNext,
          );
        }
        break;
      case VideoControlItem.episodeList:
        _showEpisodeList();
        break;
      case VideoControlItem.previousChapter:
        _pokeControlsVisible();
        unawaited(controller.previousChapter());
        break;
      case VideoControlItem.nextChapter:
        _pokeControlsVisible();
        unawaited(controller.nextChapter());
        break;
      case VideoControlItem.chapterList:
        _showChapterPanel(controller, sourceSlot: sourceSlot);
        break;
      // Non-chip / handled-by-legacy items never reach here.
      case VideoControlItem.volume:
      case VideoControlItem.title:
      case VideoControlItem.positionIndicator:
      case VideoControlItem.speed:
      case VideoControlItem.subtitleList:
      case VideoControlItem.favoriteSentence:
      case VideoControlItem.favoriteSentences:
      case VideoControlItem.settings:
        break;
    }
  }

  /// 底栏传输组：`[−10s][上一句][play][下一句][+10s]`，[play] 钉在几何正中（BUG-257）。
  ///
  /// 根因：旧底栏 `[时间] Spacer [seek 簇] Spacer [尾部按钮…]` 用两个 [Spacer] 在「时间」
  /// 与「尾部按钮」间均分，尾部按钮越多 seek 簇离整条几何中心越远 → play 偏左。改用 [Stack]
  /// 三区绝对定位：左区时间、右区尾部按钮、[Center] 居中 seek 簇，play 恒处几何中心、两侧
  /// seek 对称，与尾部按钮数量无关。桌面/移动共用本布局（仅控件类型与播放暂停按钮不同）。
  Widget _centeredBottomControlBar(
    VideoPlayerController controller, {
    required bool desktop,
  }) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool roomyBottomBar = _hasRoomyVideoBottomBar();
    final Widget positionIndicator = desktop
        ? MaterialDesktopPositionIndicator(
            style: TextStyle(
              height: 1.0,
              fontSize: 12.0 * _videoUiScale,
              color: cs.primary,
            ),
          )
        : MaterialPositionIndicator(
            style: TextStyle(
              height: 1.0,
              fontSize: 12.0 * _videoUiScale,
              color: cs.primary,
            ),
          );
    final List<Widget> rightCluster = <Widget>[
      ..._bottomSlotButtons(
        VideoControlSlot.bottomRight,
        controller,
        desktop: desktop,
        roomyBottomBar: roomyBottomBar,
      ),
    ];
    // seek 传输簇（居中绝对定位）：从 bottomCenter slot 取真实顺序。默认仍是
    // `[−10s][上一句][play][下一句][+10s]`，移动后不再硬编码重复。
    final Widget transport = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ..._bottomSlotButtons(
          VideoControlSlot.bottomCenter,
          controller,
          desktop: desktop,
          roomyBottomBar: roomyBottomBar,
        ),
      ],
    );
    // 左区：时间指示器 + bottomLeft slot 按钮。与中心簇绝对独立，宽度变化不挤偏 play。
    final List<Widget> leftCluster = <Widget>[
      if (_controlLayout
          .itemsIn(VideoControlSlot.bottomLeft)
          .contains(VideoControlItem.positionIndicator))
        positionIndicator,
      ..._bottomSlotButtons(
        VideoControlSlot.bottomLeft,
        controller,
        desktop: desktop,
        roomyBottomBar: roomyBottomBar,
      ),
    ];
    return Stack(
      alignment: Alignment.center,
      children: <Widget>[
        // 居中传输簇：play 恒处整条底栏几何中心。
        Center(child: transport),
        // 左区：时间指示器 + bottomLeft 自定义按钮。
        Align(
          alignment: Alignment.centerLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: leftCluster,
          ),
        ),
        // 右区：自定义按钮 + 音量 + 全屏（宽度变化不挤偏 play）。
        Align(
          alignment: Alignment.centerRight,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: rightCluster,
          ),
        ),
      ],
    );
  }

  /// 带可见标注的 seek 按钮（图标 + `−10s`/`+10s`）。media_kit 的 `MaterialCustomButton`
  /// 只接受单 icon、无可见文字，用户看不懂图标（BUG-257）；这里用 [InkWell] 自绘
  /// 图标 + 紧凑标注，颜色对齐 `buttonBarButtonColor`（cs.primary），仍带 [Tooltip]。
  Widget _seekLabelButton({
    required IconData icon,
    required String label,
    required String tooltip,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        customBorder: const StadiumBorder(),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 6 * _videoUiScale,
            vertical: 4 * _videoUiScale,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: _videoControlIconSize * 0.82, color: color),
              SizedBox(width: 2 * _videoUiScale),
              Text(
                label,
                style: TextStyle(
                  height: 1.0,
                  fontSize: 11.0 * _videoUiScale,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVideoControlButton(
    VideoPlayerController controller,
    VideoControlButton button, {
    required bool desktop,
    required VideoControlSlot slot,
  }) {
    final LayerLink? popoverLink = button == VideoControlButton.speed
        ? _controlPopoverLinkFor(slot, VideoControlItem.speed)
        : null;
    final Widget icon = Icon(
      _videoControlButtonIcon(button),
      size: _videoControlIconSize,
    );
    final Widget controlButton = desktop
        ? MaterialDesktopCustomButton(
            icon: icon,
            onPressed: () => _activateVideoControlButton(
              button,
              popoverLink: popoverLink,
              sourceSlot: slot,
            ),
          )
        : MaterialCustomButton(
            icon: icon,
            onPressed: () => _activateVideoControlButton(
              button,
              popoverLink: popoverLink,
              sourceSlot: slot,
            ),
          );
    if (popoverLink == null) return controlButton;
    return _controlPopoverAnchor(
      kind: _VideoControlPopoverKind.speed,
      link: popoverLink,
      desktop: desktop,
      sourceSlot: slot,
      sourceItem: VideoControlItem.speed,
      child: controlButton,
    );
  }

  IconData _videoControlButtonIcon(VideoControlButton button) {
    switch (button) {
      case VideoControlButton.speed:
        return Icons.speed;
      case VideoControlButton.subtitleList:
        return Icons.format_list_bulleted;
      case VideoControlButton.favoriteSentence:
        return Icons.star_border_rounded;
      case VideoControlButton.favoriteSentences:
        return Icons.collections_bookmark_outlined;
      case VideoControlButton.settings:
        return Icons.tune;
    }
  }

  String _videoControlButtonTooltip(VideoControlButton button) {
    switch (button) {
      case VideoControlButton.speed:
        return t.video_control_speed;
      case VideoControlButton.subtitleList:
        return t.video_control_subtitle_list;
      case VideoControlButton.favoriteSentence:
        return t.video_control_favorite_sentence;
      case VideoControlButton.favoriteSentences:
        return t.video_control_favorite_sentences;
      case VideoControlButton.settings:
        return t.video_control_settings;
    }
  }

  void _activateVideoControlButton(
    VideoControlButton button, {
    LayerLink? popoverLink,
    VideoControlSlot? sourceSlot,
  }) {
    switch (button) {
      case VideoControlButton.speed:
        _showSpeedMenu(popoverLink: popoverLink, sourceSlot: sourceSlot);
        break;
      case VideoControlButton.subtitleList:
        _toggleSubtitleJumpList();
        break;
      case VideoControlButton.favoriteSentence:
        unawaited(_toggleFavoriteCurrentCue());
        break;
      case VideoControlButton.favoriteSentences:
        _showFavoriteSentencesPanel(sourceSlot: sourceSlot);
        break;
      case VideoControlButton.settings:
        _showPlayerSettings(sourceSlot: sourceSlot);
        break;
    }
  }

  bool _hasRoomyVideoBottomBar() => MediaQuery.of(context).size.width >= 600;

  /// 系统底部安全区 inset（BUG-184）：Android 手势导航条 / 物理导航栏的高度，用来把
  /// 进度条与底部按钮条抬离系统栏。视频打开后走 immersiveSticky 隐藏导航栏，多数情况下
  /// 这个值是 0（基线 [_videoBottomChromeBaseline] 仍保证进度条不贴最底）；从屏幕底缘
  /// 滑出唤回导航条时它转为非零，进度条随之上移避开。读 [MediaQuery.viewPadding]（物理
  /// 安全区）而非 `padding`（会被 immersive 模式抹平），且不受软键盘弹出影响。
  double _videoBottomSystemInset() => MediaQuery.of(context).viewPadding.bottom;

  /// 字幕动态避让的「进度条上缘」高度（BUG-238）：控制条可见时字幕底缘对它取下限
  /// （`max(bottomPadding, reserve)`，见 [VideoSubtitleOverlay]）。由当前平台真实控制条
  /// 几何加总（同名 getter 已 ×[_videoUiScale]），故随界面缩放一起变大——旧默认常量 56
  /// 既不随缩放、又低于默认基线 75，移动端 `max(75,56)=75` 把字幕留在被抬高的进度条
  /// 下面被遮。桌面进度条骑按钮行上沿 → 只让一个按钮行高（保 BUG-228 观感）；移动端
  /// 进度条整体被 [_mobileControlsTheme] 抬到按钮行上方 → 让出其热区上缘（≈140×缩放）。
  double _subtitleControlsBottomReserve() {
    return videoSubtitleControlsReserve(
      isDesktop: _isDesktopVideoControls,
      buttonBarHeight: _videoButtonBarHeight,
      seekBarButtonGap: _videoSeekBarButtonGap,
      seekBarContainerHeight: _videoSeekBarContainerHeight,
      bottomChromeBaseline: _videoBottomChromeBaseline,
      bottomSystemInset: _videoBottomSystemInset(),
    );
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

  /// 键盘音量键 / 滚轮调音量：交给 controller 的 [VideoPlayerController.adjustVolume]
  /// 算（base = 静音时 0，否则当前有效音量），用其**返回的确定新音量**刷新 OSD/显示，
  /// 不再自己 `controller.volume + delta`（[VideoPlayerController.volume] 读 libmpv
  /// 异步滞后的 `state.volume`，这条歧义路径会让连续按键叠加在旧值上，TODO-433）。
  Future<void> _adjustVolume(double delta) async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    final double next = await controller.adjustVolume(delta);
    await _applyUserVideoVolume(next);
  }

  /// 静音切换：用 controller 的 [VideoPlayerController.toggleMute] **返回的确定目标音量**
  /// 刷新 OSD/底栏图标/滑条——取消静音返回静音前音量、静音返回 0。不再读
  /// [VideoPlayerController.volume]（取消静音那一帧 libmpv 的 `state.volume` 仍是 0，
  /// 读它会让显示卡在 0、恢复不了音量，正是 TODO-433 bug2）。
  Future<void> _toggleMute() async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    final double next = await controller.toggleMute();
    await _applyUserVideoVolume(
      next,
      persist: false,
      applyToController: false,
    );
  }

  void _showLevelHud(_VideoLevelHudKind kind, double value) {
    if (!mounted) return;
    final double clamped = value.clamp(0.0, 100.0).toDouble();
    _levelHudNotifier.value = _VideoLevelHudState(
      kind: kind,
      value: clamped,
    );
    _levelHudTimer?.cancel();
    _levelHudTimer = Timer(const Duration(milliseconds: 1600), () {
      if (!mounted) return;
      _levelHudNotifier.value = null;
    });
  }

  void _showVolumeOsd(double volume) {
    _showLevelHud(_VideoLevelHudKind.rightVolume, volume);
  }

  void _showBrightnessOsd(double brightness) {
    _showLevelHud(_VideoLevelHudKind.leftBrightness, brightness);
  }

  /// media_kit 移动控制条的「右半区竖滑调音量」回调（TODO-057）。media_kit
  /// 已做好区域判定、逐帧累积与 clamp，传入 [value] 为 0..1。我们只把它转成现有
  /// 音量通道的 0..100 并复用 [VideoPlayerController.setVolume]——与 TODO-044 方向键
  /// 音量、音量条 UI 同一条 setter，不另开并行状态。可见反馈由页面级 level HUD 接管；
  /// media_kit 内部 indicator builder 仅返回空占位，避免 200ms 内部动画与页面 HUD 叠影。
  void _onMediaKitVolumeChanged(double value) {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    final double pct = (value.clamp(0.0, 1.0) * 100.0).toDouble();
    unawaited(_applyUserVideoVolume(pct));
  }

  /// media_kit 移动控制条的「左半区竖滑调屏幕亮度」回调（TODO-057）。[value] 为
  /// 0..1，经 [ScreenBrightnessController] 写设备背光（Android 窗口级 / iOS 系统级）。
  /// 桌面 [ScreenBrightnessController.canControl] 为 false → 静默 no-op（且我们不在
  /// 桌面控制条启用该手势，见 [_desktopControlsTheme] 不传回调），诚实降级。
  void _onMediaKitBrightnessChanged(double value) {
    if (!_brightness.canControl) return;
    final double clamped = value.clamp(0.0, 1.0).toDouble();
    _showBrightnessOsd(clamped * 100.0);
    unawaited(_brightness.setBrightness(clamped));
  }

  /// 进入视频时取一次系统屏幕亮度快照（移动端）作为亮度手势初值与退出还原值；
  /// 退出（[dispose]）把它写回，防止把用户系统亮度永久留在拖动后的值。
  Future<void> _ensureEnterBrightness() async {
    if (_enterBrightness != null || !_brightness.canControl) return;
    final double? current = await _brightness.currentBrightness();
    if (current == null) return;
    _enterBrightness = current;
    // 重建让 [_mobileControlsTheme] 把真实 initialBrightness 喂给 media_kit，
    // 否则首次亮度拖动会从其默认 0.5 起跳（而非用户当前实际亮度）。
    if (mounted) setState(() {});
  }

  /// TODO-099: 进入视频页时锁横屏（移动端）。只锁本页，不动全 app
  /// 默认方向策略（保护竖排小说能竖屏）；退出由 [_restoreOrientationOnExit] 还原。
  /// 桌面门控 no-op（桌面窗口不走设备方向）。
  Future<void> _lockLandscapeForVideo() async {
    if (!isMobilePlatform) return;
    await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  /// TODO-158/BUG-219: 视频页持有「沉浸隐藏系统栏」所有权（移动端）。在 [initState]
  /// 显式设、在 [didChangeAppLifecycleState] 的 `resumed` 重申，让系统栏在视频期间
  /// **持续隐藏**，而非只靠 [AppModel.openMedia] 打开媒体时一次性设、从不复申。
  ///
  /// 用 [SystemUiMode.immersiveSticky]（与 openMedia 既有基线一致）：上划仍可临时
  /// 唤出系统栏，但随后自动重隐；配合 `resumed` 重申覆盖后台返回 / 通知栏交互后的
  /// 残留。严格限本页：不动 openMedia（书 / 视频共用入口，竖排小说由 reader 自设
  /// edgeToEdge 覆盖、首页由 setHomeShellSystemUiMode 接管），退出由 [AppModel.closeMedia]
  /// 的 setHomeShellSystemUiMode 统一还原。桌面门控 no-op（桌面无系统栏）。
  Future<void> _applyVideoImmersiveMode() async {
    if (!isMobilePlatform) return;
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  /// BUG-221: media_kit 全屏「进入」回调，**替换** media_kit 默认
  /// [defaultEnterNativeFullscreen]。窗口侧与自建全屏路由的 [Video] 都传这个，
  /// 经由 media_kit 的 `state.widget.onEnterFullscreen` 链路生效。
  ///
  /// 移动端：语义与 [_lockLandscapeForVideo] + [_applyVideoImmersiveMode] 一致——
  /// 只允许两个横屏 + 沉浸隐栏，**永不 `setPreferredOrientations([])`**（病根是
  /// media_kit 默认退全屏时放开全部方向把设备弹回竖屏）。
  ///
  /// 桌面：**保留** media_kit 默认 [defaultEnterNativeFullscreen]，它经 MethodChannel
  /// `Utils.EnterNativeFullscreen` 把 OS 窗口切真原生全屏（覆盖任务栏）。桌面分支不碰
  /// 设备方向，无竖屏问题；之前若在桌面 no-op 会悄悄砍掉桌面「全屏 = OS 窗口真全屏」
  /// （改动前窗口侧 Video 未传回调、落 media_kit 默认 = 桌面真全屏），属本修复范围外的
  /// 桌面回归，故桌面转调默认回调原样保留。
  Future<void> _enterVideoNativeFullscreen() async {
    if (!isMobilePlatform) return defaultEnterNativeFullscreen();
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.immersiveSticky,
      overlays: <SystemUiOverlay>[],
    );
    await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  /// BUG-221: media_kit 全屏「退出」回调，**替换** media_kit 默认
  /// [defaultExitNativeFullscreen]。
  ///
  /// 移动端：media_kit 默认退全屏时调 `setPreferredOrientations([])` 放开全部方向
  /// （含竖屏/倒置），让设备转回竖屏 = 用户感知的「竖屏模式」。本回调退全屏时**仍只允许
  /// 两个横屏**（视频页全程横屏，方向唯一拥有者），系统栏保持沉浸隐藏（与窗口态一致，
  /// 不在退全屏瞬间闪回系统栏）。真正放开方向交给退页时的 [_restoreOrientationOnExit]。
  ///
  /// 桌面：**保留** media_kit 默认 [defaultExitNativeFullscreen]（MethodChannel
  /// `Utils.ExitNativeFullscreen` 把 OS 窗口还原回非全屏），与进入回调对称。桌面分支不碰
  /// 设备方向，无竖屏问题。
  Future<void> _exitVideoNativeFullscreen() async {
    if (!isMobilePlatform) return defaultExitNativeFullscreen();
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.immersiveSticky,
      overlays: <SystemUiOverlay>[],
    );
    await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  /// TODO-099: 退出视频页时还原为 app 默认允许态（竖屏 + 两个横屏，
  /// 与 [main] 初始化一致），而非空列表（空列表会放开 4 向含倒置）。在
  /// 同步 [dispose] 里可靠还原，不把阅读器 / 首页锁死在横屏。桌面门控 no-op。
  Future<void> _restoreOrientationOnExit() async {
    if (!isMobilePlatform) return;
    await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  /// 设置播放倍速：先乐观刷新 UI，再下发 controller；只有持久化走 trailing debounce。
  Future<void> _setSpeed(double speed, {bool persist = true}) async {
    final double clamped = speed.clamp(0.25, 4.0).toDouble();
    final bool changed = (clamped - _playbackSpeed).abs() >= 0.001;
    if (!changed && !persist) return;
    if (changed) {
      _playbackSpeed = clamped;
      if (mounted) setState(() {});
      await _controller?.setSpeed(clamped);
    }
    if (persist) {
      _queuePersistVideoSpeed(clamped);
    }
  }

  void _queuePersistVideoSpeed(double speed) {
    _pendingSpeedPersist = speed.clamp(0.25, 4.0).toDouble();
    _speedPersistDebounce?.cancel();
    _speedPersistDebounce = Timer(const Duration(milliseconds: 350), () {
      unawaited(_flushPersistedVideoSpeed());
    });
  }

  Future<void> _flushPersistedVideoSpeed() async {
    final double? pending = _pendingSpeedPersist;
    if (pending == null) return;
    _speedPersistDebounce?.cancel();
    _speedPersistDebounce = null;
    _pendingSpeedPersist = null;
    await appModel.prefsRepo.setPref(_speedPrefKey, pending);
  }

  void _handleVideoLongPressStart(LongPressStartDetails details) {
    if (_videoSheetOpen || _longPressPreviousSpeed != null) return;
    _longPressPreviousSpeed = _playbackSpeed;
    final double speed = _asbConfig.longPressSpeed;
    // 长按拖动以固定加速速为基准（TODO-338）：拖动位移在此基础上连续加减。
    _longPressDragBaseSpeed = speed;
    unawaited(_setSpeed(speed, persist: false));
    _showOsd('${speed.toStringAsFixed(1)}x', icon: Icons.speed);
  }

  /// 长按后横向拖动连续调速（TODO-338）：向右拖加速、向左减速，以长按固定加速速
  /// [_longPressDragBaseSpeed] 为基准，按 [_kLongPressDragSpeedPerPixel] 线性映射横向
  /// 位移，clamp 到 [_kLongPressDragMinSpeed]..[_kLongPressDragMaxSpeed]，松手恢复原速
  /// （[_handleVideoLongPressEnd]）。位移用相对长按起点的 [localOffsetFromOrigin]。
  void _handleVideoLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    final double? base = _longPressDragBaseSpeed;
    if (base == null) return;
    // 0.1x 步进（避免每像素抖动；_setSpeed 内另有 0.001 去重）。
    final double snapped = VideoHibikiPage.longPressDragSpeedFor(
      base,
      details.localOffsetFromOrigin.dx,
    );
    if ((snapped - _playbackSpeed).abs() < 0.001) return;
    unawaited(_setSpeed(snapped, persist: false));
    _showOsd('${snapped.toStringAsFixed(1)}x', icon: Icons.speed);
  }

  void _handleVideoLongPressEnd(LongPressEndDetails details) {
    final double? previous = _longPressPreviousSpeed;
    _longPressPreviousSpeed = null;
    _longPressDragBaseSpeed = null;
    if (previous == null) return;
    unawaited(_setSpeed(previous, persist: false));
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

  /// 切画面缩放/比例模式（TODO-152 子B）：落盘 + setState 重建窗口 Video（fit 换算变化）。
  /// 全屏路由的 Video 在其 builder 内读 [_videoFitMode] 经 [videoFitModeToBoxFit] 换算，
  /// 故全屏在栈上时本 setState 不重建它，但下次进全屏/退回窗口都跟随新偏好。
  Future<void> _setVideoFitMode(VideoFitMode mode) async {
    if (_videoFitMode == mode) return;
    _videoFitMode = mode;
    await appModel.setVideoFitMode(mode);
    if (mounted) setState(() {});
  }

  /// Persist + apply a new 9-slot control button layout (TODO-274/312 phase 2).
  /// This is the single write path the quick-settings editor calls; it stores
  /// the v3 layout (same pref key, auto-migrating old v1/v2 blobs). Keep the
  /// notifier update before persistence so the active controls rebuild
  /// immediately after quick settings or the on-player editor saves.
  Future<void> _setVideoControlLayout(VideoControlLayout layout) async {
    _controlLayoutNotifier.value = layout;
    await appModel.setVideoControlLayout(layout);
    if (mounted) setState(() {});
  }

  void _showVideoControlEditOverlay() {
    if (_videoSheetOpen) return;
    _clearRailHover();
    if (_subtitleListVisible.value) {
      _clearSelectedMiningCues();
      _subtitleListVisible.value = false;
    }
    if (_videoSidePanel.value != null) {
      _videoSidePanel.value = null;
    }
    _videoControlEditMode.value = true;
    _markControlsVisible(false);
    _refocusVideo();
  }

  void _hideVideoControlEditOverlay({bool revealControls = true}) {
    if (!_videoControlEditMode.value) return;
    _videoControlEditMode.value = false;
    if (revealControls) _pokeControlsVisible();
    _refocusVideo();
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

  void _attachControllerChapterListener(VideoPlayerController controller) {
    if (_chapterListenerController == controller && _chapterListener != null) {
      return;
    }
    _detachControllerChapterListener();
    void listener() => _onControllerChaptersChanged(controller);
    _chapterListenerController = controller;
    _chapterListener = listener;
    controller.addListener(listener);
  }

  void _detachControllerChapterListener() {
    final VideoPlayerController? controller = _chapterListenerController;
    final VoidCallback? listener = _chapterListener;
    if (controller != null && listener != null) {
      controller.removeListener(listener);
    }
    _chapterListenerController = null;
    _chapterListener = null;
  }

  /// controller 通知监听（TODO-424）：章节是 open 后异步填充的，就绪后翻转
  /// [_hasChapters] 触发一次 setState，让控制条章节入口按钮出现 / 消失（换集换成无章节
  /// 的片时也跟着隐藏）。只在「有无章节」真变化时 setState，避免 cue 同步等高频通知抖动。
  void _onControllerChaptersChanged(VideoPlayerController controller) {
    _syncControllerChapterAvailability(controller);
  }

  void _syncControllerChapterAvailability(VideoPlayerController controller) {
    if (!mounted) return;
    if (_controller != controller) return;
    final bool hasChapters = controller.chapters.isNotEmpty;
    if (hasChapters == _hasChapters) return;
    setState(() => _hasChapters = hasChapters);
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

  /// **一键画质档位应用**（无/低/中/高/极高）：原子写两套正交状态——mpv 内置缩放开关
  /// （[highQuality] → videoMpvConfig）+ GLSL 启用集（[enabledNames] →
  /// videoShadersEnabled），再一次性 applyMpvConfig + applyShaders 实时生效。
  ///
  /// 着色器文件已由着色器视图在调用本方法前下载到目录；这里只负责持久化 + 应用。
  /// highQuality 关时旁路 GLSL（与既有 onApplyShaders/onMpvConfigChanged 同语义）。
  Future<void> _applyShaderTier(
    bool highQuality,
    List<String> enabledNames,
  ) async {
    final VideoMpvConfig cfg = VideoMpvConfig.decode(
      appModel.videoMpvConfig,
    ).copyWith(highQuality: highQuality);
    await appModel.setVideoMpvConfig(VideoMpvConfig.encode(cfg));
    await appModel.setVideoShadersEnabled(encodeEnabledShaders(enabledNames));
    await _controller?.applyMpvConfig(cfg);
    final List<String> paths = highQuality
        ? await resolveEnabledShaderPaths(enabledNames)
        : const <String>[];
    await _controller?.applyShaders(paths);
  }

  /// 着色器「对比原画」：切换旁路态（临时关掉着色器看原画，再切回），保留启用集。
  /// B：缺效果预览/对比——桌面控制条对比按钮 + `C` 快捷键都走这里，OSD 提示当前态。
  Future<void> _toggleShaderCompare() async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    final bool bypassed = await controller.toggleShaderBypass();
    if (!mounted) return;
    _showOsd(
      bypassed
          ? t.video_shader_showing_original
          : t.video_shader_showing_shaded,
    );
  }

  /// 相对当前位置 seek（±[deltaMs]，底部胶囊条 / 快捷键共用）。每次都唤醒控制条并
  /// 重置自动隐藏计时（BUG-175 ②；底部 ±10 按钮是 tap，media_kit 也不重置计时）。
  Future<void> _seekRelative(int deltaMs) async {
    _pokeControlsVisible();
    await _controller?.seekRelative(deltaMs);
  }

  /// 跳上/下一句并唤醒控制条（底部胶囊条「上/下一句」按钮，BUG-175 ②）。
  /// [forward] true=下一句、false=上一句。
  Future<void> _skipCueAndPokeControls({required bool forward}) async {
    _pokeControlsVisible();
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    // 无字幕/转场段：下一句前进 seekSeconds 秒(TODO-073)、上一句对称回退
    // seekSeconds 秒(TODO-119，BUG-198)。两侧都不再在没字幕时 no-op 卡住。
    await (forward
        ? controller.skipToNextCueOrSeekForward(
            seekSeconds: _asbConfig.seekSeconds,
          )
        : controller.skipToPrevCueOrSeekBack(
            seekSeconds: _asbConfig.seekSeconds,
          ));
  }

  AudioCue? _currentCueForAction() {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return null;
    return controller.currentCue ??
        resolveMiningCueForPosition(
          cues: controller.cues,
          positionMs: controller.positionMs ?? 0,
          delayMs: _delayMs,
        );
  }

  Future<void> _toggleFavoriteCurrentCue() async {
    final AudioCue? cue = _currentCueForAction();
    if (cue == null || cue.text.trim().isEmpty) {
      HibikiToast.show(msg: t.no_sentence_selected);
      return;
    }
    _pokeControlsVisible();
    await _toggleFavoriteCueForVideo(cue);
  }

  Future<void> _replayCurrentCueAndPokeControls() async {
    final AudioCue? cue = _currentCueForAction();
    if (cue == null) return;
    _pokeControlsVisible();
    await _controller?.skipToCue(cue);
  }

  /// 重播上一句（TODO-378，BUG-287）：跳到上一条 cue 起点并播放，**不**退化成回退几秒
  /// （走纯 [VideoPlayerController.skipToPrevCue]，与底栏「上一句」按钮同语义）。
  Future<void> _replayPreviousCueAndPokeControls() async {
    _pokeControlsVisible();
    await _controller?.skipToPrevCue();
  }

  Future<void> _toggleClipExport() async {
    if (_clipExporting) {
      _showOsd(t.video_clip_exporting);
      return;
    }

    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    if (_isRemote || _currentVideoPath == null) {
      _showOsd(t.video_clip_export_remote_download_required);
      return;
    }

    if (!_clipExportMarking) {
      final int? positionMs = controller.positionMs;
      if (positionMs == null) {
        _showOsd(t.video_clip_export_invalid_range);
        return;
      }
      setState(() {
        _clipExportGeneration++;
        _clipExportMarking = true;
        _clipExportStartMs = positionMs;
        _clipExportStartPath = _currentVideoPath;
        _clipExportStartAudioStreamIndex = controller.currentAudioStreamIndex;
      });
      _showOsd(t.video_clip_export_start);
      return;
    }

    final int? startMs = _clipExportStartMs;
    final String? startPath = _clipExportStartPath;
    final int? endMs = controller.positionMs;
    if (startMs == null ||
        startPath == null ||
        endMs == null ||
        startPath != _currentVideoPath) {
      setState(_clearClipExportState);
      _showOsd(t.video_clip_export_source_changed);
      return;
    }
    if (endMs <= startMs) {
      setState(_clearClipExportState);
      _showOsd(t.video_clip_export_invalid_range);
      return;
    }

    final int generation = _clipExportGeneration;
    final int? audioStreamIndex = _clipExportStartAudioStreamIndex;
    final String outputPath = await _clipExportOutputPath(
      inputPath: startPath,
      startMs: startMs,
      endMs: endMs,
    );
    if (!mounted) {
      await _deleteClipOutput(outputPath);
      return;
    }
    if (generation != _clipExportGeneration || _currentVideoPath != startPath) {
      await _deleteClipOutput(outputPath);
      if (mounted) {
        setState(_clearClipExportState);
        _showOsd(t.video_clip_export_source_changed);
      }
      return;
    }
    setState(() => _clipExporting = true);
    _showOsd(t.video_clip_exporting);

    final VideoClipExportResult result = await exportVideoClipViaFfmpeg(
      inputPath: startPath,
      startMs: startMs,
      endMs: endMs,
      outputPath: outputPath,
      audioStreamIndex: audioStreamIndex,
    );

    if (!mounted) {
      await _deleteClipOutput(result.outputPath ?? outputPath);
      return;
    }
    if (generation != _clipExportGeneration || _currentVideoPath != startPath) {
      await _deleteClipOutput(result.outputPath ?? outputPath);
      if (mounted) {
        setState(_clearClipExportState);
        _showOsd(t.video_clip_export_source_changed);
      }
      return;
    }

    setState(_clearClipExportState);
    final String? exported = result.outputPath;
    if (result.isSuccess && exported != null) {
      _showOsd(t.video_clip_exported(path: exported));
      if (!(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
        await Share.shareXFiles(<XFile>[
          XFile(exported),
        ], subject: p.basename(exported));
      }
    } else {
      _showOsd(t.video_clip_export_failed(
        reason: _clipExportFailureReason(result),
      ));
    }
    _refocusVideo();
  }

  void _clearClipExportState() {
    _clipExportGeneration++;
    _clipExportMarking = false;
    _clipExporting = false;
    _clipExportStartMs = null;
    _clipExportStartPath = null;
    _clipExportStartAudioStreamIndex = null;
  }

  Future<String> _clipExportOutputPath({
    required String inputPath,
    required int startMs,
    required int endMs,
  }) async {
    final Directory docs = await getApplicationDocumentsDirectory();
    final Directory dir = Directory(p.join(docs.path, 'video_clips'));
    final String rawStem = _safeFileName(p.basenameWithoutExtension(inputPath));
    final String stem = rawStem.isEmpty ? 'video' : rawStem;
    final String ext = p.extension(inputPath).isEmpty
        ? '.mkv'
        : p.extension(inputPath).toLowerCase();
    final String name =
        '${stem}_${_clipExportTimeToken(startMs)}-${_clipExportTimeToken(endMs)}$ext';
    return p.join(dir.path, name);
  }

  String _clipExportTimeToken(int ms) {
    final int totalSeconds = ms ~/ 1000;
    final int hours = totalSeconds ~/ 3600;
    final int minutes = (totalSeconds % 3600) ~/ 60;
    final int seconds = totalSeconds % 60;
    final int millis = ms % 1000;
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(hours)}${two(minutes)}${two(seconds)}_'
        '${millis.toString().padLeft(3, '0')}';
  }

  String _clipExportFailureReason(VideoClipExportResult result) {
    switch (result.failure) {
      case VideoClipExportFailure.invalidRange:
        return t.video_clip_export_invalid_range;
      case VideoClipExportFailure.inputMissing:
        return t.video_clip_export_input_missing;
      case VideoClipExportFailure.ffmpegUnavailable:
        return t.video_clip_export_ffmpeg_unavailable;
      case VideoClipExportFailure.ffmpegFailed:
        return t.video_clip_export_ffmpeg_failed;
      case VideoClipExportFailure.outputMissing:
        return t.video_clip_export_output_missing;
      case null:
        return t.video_clip_export_ffmpeg_failed;
    }
  }

  Future<void> _deleteClipOutput(String? path) async {
    if (path == null) return;
    try {
      final File file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// 截当前帧存为图片：桌面弹保存对话框，移动端走系统分享（参照 log_exporter
  /// 的平台分流）。复用 [VideoPlayerController.screenshot]（制卡同源，JPEG）。
  Future<void> _saveScreenshot() async {
    final VideoPlayerController? controller = _controller;
    final Uint8List? bytes = await controller?.screenshot();
    if (bytes == null) {
      _showScreenshotFailure('no frame available');
      return;
    }
    File? tmp;
    final bool isDesktop =
        Platform.isWindows || Platform.isMacOS || Platform.isLinux;
    try {
      final String defaultScreenshotName = videoScreenshotBaseName(
        sourcePathOrTitle: _screenshotSourcePathOrTitle(),
        positionMs: controller?.positionMs ?? 0,
        capturedAt: DateTime.now(),
      );
      final Directory tmpDir = await getTemporaryDirectory();
      final String screenshotName = uniqueVideoScreenshotBaseName(
        defaultScreenshotName,
        exists: (String name) => File(p.join(tmpDir.path, name)).existsSync(),
      );
      tmp = File(p.join(tmpDir.path, screenshotName));
      await tmp.writeAsBytes(bytes);
      if (isDesktop) {
        final String? savePath = await FilePicker.platform.saveFile(
          dialogTitle: t.video_screenshot,
          fileName: screenshotName,
          type: FileType.custom,
          allowedExtensions: <String>['jpg'],
        );
        if (savePath != null) {
          final String finalPath = _uniqueScreenshotSavePath(savePath);
          await tmp.copy(finalPath);
          _showOsd(t.video_screenshot_saved_to(path: finalPath));
        }
      } else {
        await Share.shareXFiles(<XFile>[
          XFile(tmp.path, mimeType: 'image/jpeg'),
        ], subject: screenshotName);
        _showOsd(t.video_screenshot_ready(file: screenshotName));
      }
    } catch (e, stack) {
      debugPrint('[VideoHibikiPage] screenshot save failed: $e\n$stack');
      _showScreenshotFailure(e);
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

  String _screenshotSourcePathOrTitle() {
    final String? currentVideoPath = _currentVideoPath;
    if (currentVideoPath != null && currentVideoPath.trim().isNotEmpty) {
      return currentVideoPath;
    }
    final String? title = _title ?? widget.remoteInfo?.title;
    if (title != null && title.trim().isNotEmpty) return title;
    return 'video';
  }

  String _uniqueScreenshotSavePath(String savePath) {
    final String desiredPath =
        p.extension(savePath).isEmpty ? '$savePath.jpg' : savePath;
    return uniqueVideoScreenshotPath(
      desiredPath,
      exists: (String path) => File(path).existsSync(),
    );
  }

  void _showScreenshotFailure(Object reason) {
    final String text = reason.toString().trim();
    _showOsd(
      t.video_screenshot_failed_reason(
        reason: text.isEmpty ? 'unknown error' : text,
      ),
    );
  }

  /// 弹快捷倍速浮层（TODO-438）：有按钮触发源时锚定 speed 按钮、按其槽位自适应方向
  /// （TODO-560：[sourceSlot] 决定上/下/左/右弹），复用 [_speedMenuPresets] 与
  /// [_setSpeed]。右键菜单没有稳定按钮锚点，退回可见 side panel，避免打开
  /// showWhenUnlinked=false 的不可见 follower。
  void _showSpeedMenu({LayerLink? popoverLink, VideoControlSlot? sourceSlot}) {
    if (popoverLink == null) {
      _showVideoSidePanel(_VideoSidePanelKind.speed);
      return;
    }
    _toggleControlPopover(
      _VideoControlPopoverKind.speed,
      popoverLink: popoverLink,
      sourceSlot: sourceSlot,
      sourceItem: VideoControlItem.speed,
    );
  }

  List<double> _speedMenuPresets() {
    final Set<double> values = <double>{};
    for (double speed = 0.5; speed <= 2.0001; speed += _speedStep) {
      values.add(double.parse(speed.toStringAsFixed(2)));
    }
    values.add(1.0);
    return values.toList()..sort();
  }

  Widget _buildSpeedSidePanel() {
    final ColorScheme cs = _videoChromeColorScheme(context);
    final List<double> speedPresets = _speedMenuPresets();
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: speedPresets.length,
      itemBuilder: (BuildContext ctx, int i) {
        final double speed = speedPresets[i];
        final bool selected = (speed - _playbackSpeed).abs() < 0.001;
        return ListTile(
          dense: true,
          title: Text('${speed}x'),
          trailing: selected ? Icon(Icons.check, color: cs.primary) : null,
          onTap: () => unawaited(_setSpeed(speed)),
        );
      },
    );
  }

  /// 弹视频播放设置面板：与阅读器同款 master-detail（宽窗左分类固定 + 右详情独立
  /// 滚动，窄窗降级单列 push）。桌面经 [HibikiDialogFrame]（maxWidth 900）进入分栏，
  /// 移动端走 bottom sheet。所有项都不是 schema 项，经回调即时生效 + 持久化 + 实时
  /// 预览（见 [_setDelayMs] / [_setSpeed] / [_persistSubtitleStyle]）。关闭后把键盘
  /// 焦点还给 Video（覆盖层夺焦后不会自动归还），恢复空格等快捷键。
  Widget _buildVideoQuickSettingsSheet() {
    return VideoQuickSettingsSheet(
      initialDelayMs: _delayMs,
      initialSpeed: _playbackSpeed,
      initialSubtitleBlur: appModel.videoSubtitleBlur,
      initialSubtitleStyle: _subtitleStyle,
      uiScale: _videoUiScale,
      initialAsbConfig: _asbConfig,
      onSetDelay: _setDelayMs,
      onPreviewSpeed: (double v) => _setSpeed(v, persist: false),
      onSetSpeed: _setSpeed,
      onToggleSubtitleBlur: _toggleSubtitleBlur,
      onAsbConfigChanged: _setAsbConfig,
      onSubtitleStylePreview: (VideoSubtitleStyle s) {
        if (mounted) setState(() => _subtitleStyle = s);
      },
      onSubtitleStyleCommit: _persistSubtitleStyle,
      // 着色器/mpv 配置改为面板内嵌（不再弹独立对话框，见 VideoQuickSettingsSheet）：
      // 着色器勾选 → 持久化启用集 + 解析绝对路径 + 实时应用；mpv 配置即改即生效。
      initialShadersEnabled: decodeEnabledShaders(appModel.videoShadersEnabled),
      onApplyShaders: (List<String> enabledNames) async {
        await appModel.setVideoShadersEnabled(
          encodeEnabledShaders(enabledNames),
        );
        final VideoMpvConfig cfg = VideoMpvConfig.decode(
          appModel.videoMpvConfig,
        );
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
                decodeEnabledShaders(appModel.videoShadersEnabled),
              )
            : const <String>[];
        await _controller?.applyShaders(paths);
      },
      initialLockWindowAspectRatio: _lockWindowAspectRatio,
      onLockWindowAspectRatioChanged: _setLockWindowAspectRatio,
      initialVideoFitMode: _videoFitMode,
      onVideoFitModeChanged: _setVideoFitMode,
      initialImmersiveMode: appModel.videoImmersiveMode,
      onImmersiveModeChanged: appModel.setVideoImmersiveMode,
      initialDanmakuEnabled: appModel.videoDanmakuEnabled,
      initialDanmakuOnlineEnabled: appModel.videoDanmakuOnlineEnabled,
      initialDanmakuMaxActive: appModel.videoDanmakuMaxActive,
      onDanmakuEnabledChanged: _setVideoDanmakuEnabled,
      onDanmakuOnlineEnabledChanged: _setVideoDanmakuOnlineEnabled,
      onDanmakuMaxActiveChanged: _setVideoDanmakuMaxActive,
      // 「从本机 mpv 导入」找不到时用户手动指定的 mpv 目录，记住下次优先扫。
      initialMpvShaderDir: appModel.videoMpvShaderDir,
      onMpvShaderDirChanged: (String dir) => appModel.setVideoMpvShaderDir(dir),
      // 一键画质档位：原子落「mpv 内置缩放开关 + 启用集」并实时应用（着色器文件由
      // 着色器视图在回调前已下载到目录）。统一在此一处写两套 pref，消除两回调顺序耦合。
      onSelectShaderTier:
          (VideoShaderTier tier, bool highQuality, List<String> enabledNames) =>
              _applyShaderTier(highQuality, enabledNames),
      initialControlLayout: _controlLayout,
      onControlLayoutChanged: _setVideoControlLayout,
      onEditControlsOnscreen: _showVideoControlEditOverlay,
      // TODO-554：触屏无右键菜单兜底，禁止把「设置」按钮拖入 hidden 移除，
      // 否则用户进不去设置/控件编辑器、无法加回，软锁死。
      isTouchControls: !_isDesktopVideoControls,
    );
  }

  void _showPlayerSettings({VideoControlSlot? sourceSlot}) {
    _showVideoSidePanel(
      _VideoSidePanelKind.settings,
      sourceSlot: sourceSlot,
    );
  }

  Alignment _sidePanelAlignmentForSlot(VideoControlSlot? sourceSlot) {
    switch (sourceSlot) {
      case VideoControlSlot.topLeft:
      case VideoControlSlot.bottomLeft:
      case VideoControlSlot.screenLeft:
        return Alignment.centerLeft;
      case VideoControlSlot.topRight:
      case VideoControlSlot.bottomRight:
      case VideoControlSlot.screenRight:
      case VideoControlSlot.bottomCenter:
      case VideoControlSlot.topCenter:
      case VideoControlSlot.hidden:
      case null:
        return Alignment.centerRight;
    }
  }

  void _showVideoSidePanel(
    _VideoSidePanelKind kind, {
    VideoControlSlot? sourceSlot,
  }) {
    if (_videoSheetOpen) return;
    _clearRailHover();
    _hideVideoControlEditOverlay(revealControls: false);
    _hideControlPopover();
    _videoSidePanel.value = _VideoSidePanelState(
      kind: kind,
      alignment: _sidePanelAlignmentForSlot(sourceSlot),
    );
    // 与 push-aside 字幕列表互斥（TODO-314）：开任何浮层都先关字幕列表。
    if (_subtitleListVisible.value) {
      _clearSelectedMiningCues();
      _subtitleListVisible.value = false;
    }
    // BUG-253：开面板时不再唤起背景控制条（旧 [_pokeControlsVisible]），而是立刻把
    // 已经在显示的 media_kit 控制条 / 右侧 rail 镜像收起，避免它们冒在面板后面。
    // 面板开着期间 [_markControlsVisible] / [_pokeControlsVisible] 都被门控成不可见。
    _markControlsVisible(false);
    _refocusVideo();
  }

  void _hideVideoSidePanel() {
    _videoSidePanel.value = null;
    // BUG-253：面板关闭后唤回一次控制条（poke 在 [_videoSidePanel] 复位为 null 之后才
    // 放行），给用户「面板已关、控制条回来了」的即时反馈，与解锁沉浸态的范式一致。
    _pokeControlsVisible();
    _refocusVideo();
  }

  String _videoSidePanelTitle(_VideoSidePanelKind kind) {
    switch (kind) {
      case _VideoSidePanelKind.speed:
        return t.video_setting_speed;
      case _VideoSidePanelKind.settings:
        return t.video_settings_title;
      case _VideoSidePanelKind.favoriteSentences:
        return t.video_favorite_sentences;
      case _VideoSidePanelKind.subtitleSources:
        return t.video_menu_subtitle_track;
      case _VideoSidePanelKind.audioTracks:
        return t.video_audio_track;
      case _VideoSidePanelKind.chapters:
        return t.video_chapters;
    }
  }

  double _videoSidePanelWidth(_VideoSidePanelKind kind) {
    switch (kind) {
      case _VideoSidePanelKind.settings:
        return 560;
      case _VideoSidePanelKind.favoriteSentences:
      case _VideoSidePanelKind.chapters:
        return 420;
      case _VideoSidePanelKind.subtitleSources:
      case _VideoSidePanelKind.audioTracks:
      case _VideoSidePanelKind.speed:
        return 320;
    }
  }

  Widget _buildVideoSidePanelChild(
    _VideoSidePanelKind kind,
    VideoPlayerController controller,
  ) {
    switch (kind) {
      case _VideoSidePanelKind.speed:
        return _buildSpeedSidePanel();
      case _VideoSidePanelKind.settings:
        return _buildVideoQuickSettingsSheet();
      case _VideoSidePanelKind.favoriteSentences:
        return _buildFavoriteSentencesSidePanel();
      case _VideoSidePanelKind.subtitleSources:
        return _buildSubtitleSourcesSidePanel(controller);
      case _VideoSidePanelKind.audioTracks:
        return _buildAudioTracksSidePanel(controller);
      case _VideoSidePanelKind.chapters:
        return _buildChapterSidePanel(controller);
    }
  }

  Widget _buildVideoSidePanelOverlay(VideoPlayerController controller) {
    return Positioned.fill(
      child: ValueListenableBuilder<_VideoSidePanelState?>(
        valueListenable: _videoSidePanel,
        builder: (
          BuildContext context,
          _VideoSidePanelState? panelState,
          __,
        ) {
          if (panelState == null) return const SizedBox.shrink();
          final Widget panelContent = _buildVideoSidePanelContent(
            panelState,
            controller,
          );
          // BUG-254：面板打开时在面板「后面 / 左侧空白」铺一层全屏不可见 barrier，
          // 点面板之外任意位置 → [_hideVideoSidePanel] 关闭面板。barrier 用
          // [HitTestBehavior.opaque] 吃掉点击，**不**冒泡到下方控制条 [Listener]，
          // 因此点空白只关面板、不会触发暂停 / 全屏（与 [_handleVideoPointerUp] 的侧栏
          // 早返回门控一致）。面板本体是不透明 Material、在 Stack 上层，点面板内部命中
          // 面板自身、到不了 barrier，故只有点外部才关闭。
          return Stack(
            fit: StackFit.expand,
            children: <Widget>[
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _hideVideoSidePanel,
              ),
              panelContent,
            ],
          );
        },
      ),
    );
  }

  /// 单纯构造侧栏面板的「内容 + 定位」部分（不含 BUG-254 的点外关闭 barrier）。
  /// 字幕跳转列表已改 push-aside（TODO-314），不再经此 overlay 路径。
  Widget _buildVideoSidePanelContent(
    _VideoSidePanelState panelState,
    VideoPlayerController controller,
  ) {
    final _VideoSidePanelKind kind = panelState.kind;
    final Widget panel = VideoTranslucentSidePanel(
      title: _videoSidePanelTitle(kind),
      width: _videoSidePanelWidth(kind),
      alignment: panelState.alignment,
      onClose: _hideVideoSidePanel,
      child: _buildVideoSidePanelChild(kind, controller),
    );
    if (kind != _VideoSidePanelKind.settings) return panel;
    return HibikiAppUiScale(
      scale: _videoUiScale,
      child: panel,
    );
  }

  Widget _buildSubtitleSourcesSidePanel(VideoPlayerController controller) {
    final ColorScheme cs = _videoChromeColorScheme(context);
    final String? hostSub = _remoteSubtitlePath;
    final List<Widget> rows = <Widget>[
      if (_subtitleMenuLoading) const LinearProgressIndicator(),
      // TODO-573：「自动获取字幕(Jimaku)」对本地和远端视频都显示。Jimaku 只需要一个
      // 番名 query + 一个本地落盘目录；远端流没有本地视频文件（_currentVideoPath 恒
      // null），但有 host 下发的标题（_title / remoteInfo.title）可作 query，下载的
      // srt 文件经 _applyRemoteSubtitle 内存应用即可（与远端「本地导入字幕」同链路）。
      // 唯一前提是能算出非空 query，见 _jimakuQuery()。
      if (_jimakuQuery() != null)
        ListTile(
          leading: const Icon(Icons.cloud_download_outlined),
          title: Text(t.video_jimaku_fetch),
          enabled: !_subtitleLoadingShown,
          onTap: _subtitleLoadingShown
              ? null
              : () => unawaited(_openJimakuDialog(controller)),
        ),
      ListTile(
        leading: const Icon(Icons.file_open_outlined),
        title: Text(t.video_subtitle_import_file),
        enabled: !_subtitleLoadingShown,
        onTap: _subtitleLoadingShown
            ? null
            : () => unawaited(
                  _isRemote
                      ? _pickAndImportRemoteSubtitle(controller)
                      : _pickAndImportSubtitle(controller),
                ),
      ),
      const Divider(height: 1),
      ListTile(
        leading: const Icon(Icons.subtitles_off),
        title: Text(t.video_subtitle_off),
        selected: _currentSubtitleSource == null,
        selectedColor: cs.primary,
        enabled: !_subtitleLoadingShown,
        onTap: _subtitleLoadingShown
            ? null
            : () => unawaited(
                  _isRemote
                      ? _clearRemoteSubtitle(controller)
                      : _selectSubtitleOff(controller),
                ),
      ),
      if (_isRemote && hostSub != null)
        ListTile(
          leading: const Icon(Icons.cloud_done_outlined),
          title: Text(t.video_subtitle_remote_host),
          subtitle: Text(p.basename(hostSub)),
          selected: _currentSubtitleSource == hostSub,
          selectedColor: cs.primary,
          enabled: !_subtitleLoadingShown,
          onTap: _subtitleLoadingShown
              ? null
              : () => unawaited(_applyRemoteSubtitle(controller, hostSub)),
        ),
      if (_isRemote)
        for (final RemoteVideoEmbeddedSubtitleTrack track
            in _remoteEmbeddedSubtitleTracks)
          ListTile(
            leading: Icon(
              track.isText
                  ? Icons.movie_filter_outlined
                  : Icons.image_not_supported_outlined,
            ),
            title: Text(_remoteEmbeddedSubtitleLabel(track)),
            subtitle: Text(
              track.isText
                  ? (track.fileName ?? track.codec)
                  : t.video_subtitle_import_unsupported,
            ),
            enabled: track.isText && !_subtitleLoadingShown,
            selected:
                _currentSubtitleSource == _remoteEmbeddedSubtitleSource(track),
            selectedColor: cs.primary,
            onTap: track.isText && !_subtitleLoadingShown
                ? () => unawaited(
                      _applyRemoteEmbeddedSubtitle(controller, track),
                    )
                : null,
          ),
      if (!_isRemote)
        for (final SubtitleSource source in _subtitleMenuSources)
          ListTile(
            leading: Icon(
              source.isGraphicEmbedded
                  ? Icons.image_outlined
                  : (source.isEmbedded ? Icons.movie : Icons.subtitles),
            ),
            title: Text(source.label),
            subtitle: source.isGraphicEmbedded
                ? Text(t.video_subtitle_graphic_hint)
                : null,
            selected: subtitleSourceMatchesPersistedForMenu(
              source,
              _currentSubtitleSource,
            ),
            selectedColor: cs.primary,
            enabled: !_subtitleLoadingShown,
            onTap: _subtitleLoadingShown
                ? null
                : () => unawaited(_selectSubtitleSource(controller, source)),
          ),
    ];
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: rows,
    );
  }

  Widget _buildAudioTracksSidePanel(VideoPlayerController controller) {
    final ColorScheme cs = _videoChromeColorScheme(context);
    final List<AudioTrack> tracks = controller.audioTracks;
    if (tracks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            t.video_audio_track,
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: tracks.length,
      itemBuilder: (BuildContext _, int i) {
        final AudioTrack track = tracks[i];
        final String label = _trackLabel(
          track.title,
          track.language,
          track.id,
        );
        final bool selected = _currentAudioTrackId == track.id;
        return ListTile(
          dense: true,
          leading: const Icon(Icons.audiotrack),
          title: Text(label),
          selected: selected,
          selectedColor: cs.primary,
          trailing: selected ? Icon(Icons.check, color: cs.primary) : null,
          onTap: () => unawaited(_selectAudioTrack(controller, track)),
        );
      },
    );
  }

  /// 进度条（seek bar）章节刻度层（TODO-432）：在 seek bar 同一几何上画每章一条竖线。
  ///
  /// media_kit 的 seek bar 不暴露注入自定义子层的钩子（其 build 写死 Stack：轨道 + 缓冲 +
  /// 进度 + 滑块），故刻度只能作为 controls Stack 里独立的 [Positioned] 兄弟层叠上去。几何
  /// 对齐（与 [_mobileControlsTheme] / [_desktopControlsTheme] 喂给 media_kit 的同一套值
  /// 同源）：水平左右各内缩 16px 对齐 `seekBarMargin`（轨道宽 = 控件区宽 − 32），竖直由纯
  /// 函数 [videoSeekBarTrackBand] 按平台算出刻度带的 `bottom`/`height`（移动端进度条被抬到
  /// 按钮条上方、桌面骑在按钮行上沿）。[VideoChapterMarkers] 内部把 [VideoChapter.start] /
  /// 总时长换算成 `[0,1)` 比例画线（[chapterMarkerFractions]）。
  ///
  /// 仅当前视频有内封章节（[_hasChapters]）时挂；可见性随控制条（[_videoControlsVisible]）
  /// 与 seek bar 同步淡入淡出。SafeArea 吃全屏路由的系统安全区，与 media_kit 控制条
  /// `padding`（全屏 = MediaQuery.padding）对齐，保证窗口 / 全屏两条路径都不错位。
  Widget _buildChapterMarkersOverlay(VideoPlayerController controller) {
    if (!_hasChapters) return const SizedBox.shrink();
    // 刻度竖线高度：比轨道再高一截（约轨道高 + 8px×缩放），让标记探出轨道上下、清晰可见，
    // 但不至于像整条容器那样高出一大块。
    final double tickHeight = _videoSeekBarTrackHeight + 8.0 * _videoUiScale;
    final ({double bottom, double height}) band = videoSeekBarTrackBand(
      isDesktop: _isDesktopVideoControls,
      buttonBarHeight: _videoButtonBarHeight,
      seekBarButtonGap: _videoSeekBarButtonGap,
      seekBarContainerHeight: _videoSeekBarContainerHeight,
      seekBarTrackHeight: _videoSeekBarTrackHeight,
      bottomChromeBaseline: _videoBottomChromeBaseline,
      bottomSystemInset: _videoBottomSystemInset(),
      tickHeight: tickHeight,
    );
    final ColorScheme cs = _videoChromeColorScheme(context);
    return Positioned.fill(
      child: SafeArea(
        // 全屏安全区与 media_kit 控制条 padding 对齐；窗口态安全区为 0 不影响。
        child: ValueListenableBuilder<bool>(
          valueListenable: _videoControlsVisible,
          builder: (BuildContext _, bool controlsVisible, __) {
            return IgnorePointer(
              child: AnimatedOpacity(
                opacity: controlsVisible ? 1.0 : 0.0,
                duration: _videoChromeFadeDuration,
                child: Padding(
                  // 水平内缩 16px 对齐 seekBarMargin；竖直由 band 锚定到 seek bar 轨道。
                  padding: EdgeInsets.only(
                    left: 16,
                    right: 16,
                    bottom: band.bottom,
                  ),
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: SizedBox(
                      height: band.height,
                      width: double.infinity,
                      child: VideoChapterMarkers(
                        controller: controller,
                        // 高对比刻度色：进度条用 primary，刻度改用 onSurface 让它在
                        // 已播 / 未播段都可见（避免与 primary 进度填充同色被吞）。
                        color: cs.onSurface.withValues(alpha: 0.7),
                        thickness: 2.0 * _videoUiScale,
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// 内封章节面板（TODO-424）：列出 [controller] 的章节，点击跳转，高亮当前章。
  /// 当前章由 [controller] 的播放位置对照各章起点同步算出（[VideoPlayerController
  /// .chapterIndexForPosition]），无需异步轮询 libmpv `chapter`。
  Widget _buildChapterSidePanel(VideoPlayerController controller) {
    final int current = controller.chapterIndexForPosition(
      controller.positionMs ?? 0,
    );
    return VideoChapterPanel(
      controller: controller,
      currentIndex: current,
      colorScheme: _videoChromeColorScheme(context),
      emptyHint: t.video_chapters_empty,
      onTapChapter: (VideoChapter chapter) {
        _pokeControlsVisible();
        unawaited(controller.seekToChapter(chapter.index));
      },
    );
  }

  /// 打开章节面板（控制条章节按钮 / 快捷键共用）。
  void _showChapterPanel(
    VideoPlayerController _, {
    VideoControlSlot? sourceSlot,
  }) {
    _showVideoSidePanel(
      _VideoSidePanelKind.chapters,
      sourceSlot: sourceSlot,
    );
  }

  Widget _buildFavoriteSentencesSidePanel() {
    return FutureBuilder<List<FavoriteSentence>>(
      future: FavoriteSentenceRepository(appModel.database).getAll(),
      builder: (BuildContext context,
          AsyncSnapshot<List<FavoriteSentence>> snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        return VideoFavoriteSentencesPanel(
          currentBookKey: widget.bookUid,
          currentEpisode: _currentEpisode,
          sentences: snapshot.data ?? const <FavoriteSentence>[],
          emptyLabel: t.video_favorite_sentences_empty,
          onTapSentence: (FavoriteSentence sentence) {
            final int? startMs = sentence.normCharOffset;
            if (startMs != null) {
              _pokeControlsVisible();
              unawaited(_controller?.seekMs(startMs));
            }
          },
        );
      },
    );
  }

  void _showFavoriteSentencesPanel({VideoControlSlot? sourceSlot}) {
    _showVideoSidePanel(
      _VideoSidePanelKind.favoriteSentences,
      sourceSlot: sourceSlot,
    );
  }

  /// 弹「字幕源」菜单：枚举当前视频的全部字幕源（内嵌轨 + 同目录外挂文件）+
  /// 顶部「关闭字幕」项。选某源 → 解析成 cue → 切 overlay + 持久化 + SnackBar。
  ///
  /// 这是运行时覆盖；默认 load 行为（自动 sidecar 优先 + 内嵌兜底）不变。
  Future<void> _showSubtitleSourceMenu(
    VideoPlayerController controller, {
    VideoControlSlot? sourceSlot,
  }) async {
    if (_videoSheetOpen) return;
    if (_isRemote) {
      setState(() {
        _subtitleMenuSources = const <SubtitleSource>[];
        _subtitleMenuLoading = false;
      });
      _showVideoSidePanel(
        _VideoSidePanelKind.subtitleSources,
        sourceSlot: sourceSlot,
      );
      return;
    }
    final String? videoPath = _currentVideoPath;
    if (videoPath == null) {
      setState(() {
        _subtitleMenuSources = const <SubtitleSource>[];
        _subtitleMenuLoading = false;
      });
      _showVideoSidePanel(
        _VideoSidePanelKind.subtitleSources,
        sourceSlot: sourceSlot,
      );
      return;
    }

    setState(() {
      _subtitleMenuSources = const <SubtitleSource>[];
      _subtitleMenuLoading = true;
    });
    _showVideoSidePanel(
      _VideoSidePanelKind.subtitleSources,
      sourceSlot: sourceSlot,
    );
    final List<SubtitleSource> sources;
    try {
      sources = await _subtitleSourcesForMenu(
        videoPath: videoPath,
        currentSubtitleSource: _currentSubtitleSource,
        currentCues: controller.cues,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _subtitleMenuLoading = false);
      return;
    }
    if (!mounted) return;
    setState(() {
      _subtitleMenuSources = sources;
      _subtitleMenuLoading = false;
    });
  }

  /// Jimaku 搜索用的番名 query。能算出非空 query 时返回它，否则返回 null
  /// （= 字幕菜单不显示「自动获取字幕」入口）。
  ///
  /// - 本地视频（[_currentVideoPath] 非空）：用文件名解析出的 series（番名）。
  /// - 远端视频（[_isRemote]，无本地文件名）：用 host 下发的标题
  ///   `_title ?? remoteInfo.title`（= host 库里的 VideoBook.title，本身就是番名/
  ///   系列名）。再过一道 [parseVideoFilename]，标题里带集数/扩展名时也能收敛成 series。
  String? _jimakuQuery() {
    final String? videoPath = _currentVideoPath;
    if (videoPath != null && videoPath.trim().isNotEmpty) {
      final String series =
          parseVideoFilename(p.basename(videoPath)).series.trim();
      return series.isEmpty ? null : series;
    }
    if (_isRemote) {
      final String title = (_title ?? widget.remoteInfo?.title ?? '').trim();
      if (title.isEmpty) return null;
      final String series = parseVideoFilename(title).series.trim();
      return series.isEmpty ? title : series;
    }
    return null;
  }

  /// 打开「自动获取字幕（Jimaku）」对话框：用番名（[_jimakuQuery]）搜 → 下载到
  /// `<appDocs>/video_subtitles/` → 应用。
  ///
  /// - 本地视频：构造外挂 [SubtitleSource] 经 [_selectSubtitleSource] 持久化链路应用。
  /// - 远端视频（[_isRemote]）：没有本地 DB 行，按远端契约只在内存里应用，经
  ///   [_applyRemoteSubtitle]（与远端「本地导入字幕」同一不落 DB 的链路）。
  ///
  /// 真实拉取需有效 Jimaku API key + 联网（验证待用户）。
  Future<void> _openJimakuDialog(VideoPlayerController controller) async {
    final String? query = _jimakuQuery();
    if (query == null) return;
    final Directory docs = await getApplicationDocumentsDirectory();
    final String saveDir = p.join(docs.path, 'video_subtitles');
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
    if (_isRemote) {
      // 远端：内存应用，不写本地 DB（_applyRemoteSubtitle 自带 cue 为空时的失败提示
      // + 成功 OSD），不叠加额外提示。
      await _applyRemoteSubtitle(controller, downloaded);
      return;
    }
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

  /// 远端模式：弹文件选择器挑字幕 → 直接在内存里应用到当前流（不拷盘、不持久化）。
  Future<void> _pickAndImportRemoteSubtitle(
    VideoPlayerController controller,
  ) async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['srt', 'vtt', 'ass', 'ssa'],
      allowMultiple: false,
    );
    _refocusVideo();
    final String? path = result?.files.single.path;
    if (path == null) return;
    if (subtitleFormatForPath(path) == null) {
      _showOsd(t.video_subtitle_import_unsupported);
      return;
    }
    await _applyRemoteSubtitle(controller, path);
  }

  /// 远端模式：把 [path] 字幕文件解析成 cue 并切到 overlay（仅内存，不写本地 DB）。
  /// 解析空 cue（坏字幕 / 图形轨）时诚实告知失败、不切换。
  Future<void> _applyRemoteSubtitle(
    VideoPlayerController controller,
    String path, {
    String? selectedSource,
    String? label,
  }) async {
    final String displayLabel = label ?? p.basename(path);
    _showSubtitleLoadingOverlay();
    final List<AudioCue> cues;
    try {
      cues = await _loadExternalSubtitleCues(path, widget.bookUid);
    } finally {
      _hideSubtitleLoadingOverlay();
    }
    if (!mounted) return;
    if (cues.isEmpty) {
      _showOsd(t.video_subtitle_load_failed(label: displayLabel));
      return;
    }
    controller.setCues(cues);
    await controller.selectSubtitleTrack(SubtitleTrack.no());
    if (!mounted) return;
    setState(() => _currentSubtitleSource = selectedSource ?? path);
    _showOsd(t.video_subtitle_switched(label: displayLabel));
  }

  String _remoteEmbeddedSubtitleSource(
    RemoteVideoEmbeddedSubtitleTrack track,
  ) =>
      'embedded:${track.streamIndex}';

  String _remoteEmbeddedSubtitleLabel(RemoteVideoEmbeddedSubtitleTrack track) {
    final List<String> parts = <String>[
      if ((track.language ?? '').isNotEmpty) track.language!,
      if ((track.title ?? '').isNotEmpty) track.title!,
      track.codec,
    ];
    return 'Embedded ${track.streamIndex}: ${parts.join(' / ')}';
  }

  Future<void> _applyRemoteEmbeddedSubtitle(
    VideoPlayerController controller,
    RemoteVideoEmbeddedSubtitleTrack track,
  ) async {
    if (!track.isText) {
      _showOsd(t.video_subtitle_import_unsupported);
      return;
    }
    final RemoteVideoClient? client = widget.remoteClient;
    final RemoteVideoInfo? info = widget.remoteInfo;
    if (client == null || info == null) return;
    final Directory temp = await getTemporaryDirectory();
    final File subtitle = File(
      p.join(
        temp.path,
        _remoteSubtitleTempFileName(
          info.id,
          track.fileName ?? 'embedded_${track.streamIndex}.srt',
        ),
      ),
    );
    await client.getRemoteVideoSubtitle(
      info.id,
      subtitle,
      embeddedStreamIndex: track.streamIndex,
    );
    final String source = _remoteEmbeddedSubtitleSource(track);
    await _applyRemoteSubtitle(
      controller,
      subtitle.path,
      selectedSource: source,
      label: _remoteEmbeddedSubtitleLabel(track),
    );
  }

  /// 远端模式：关闭字幕（清空 cue overlay + 关 libmpv 字幕轨；仅内存，不写本地 DB）。
  Future<void> _clearRemoteSubtitle(VideoPlayerController controller) async {
    controller.setCues(const <AudioCue>[]);
    await controller.selectSubtitleTrack(SubtitleTrack.no());
    if (!mounted) return;
    setState(() => _currentSubtitleSource = null);
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
    debugPrint(
      '[hibiki-drop] [video-playback] classified '
      'subtitles=${files.subtitles.length} audios=${files.audios.length} '
      'videos=${files.videos.length} books=${files.books.length} '
      'dictionaries=${files.dictionaries.length} unknown=${files.unknown.length}',
    );
    final String? sub = firstSubtitlePath(paths);
    if (sub != null) {
      unawaited(_importExternalSubtitle(controller, sub));
      return;
    }
    if (files.subtitles.isNotEmpty) {
      debugPrint('[hibiki-drop] [video-playback] intent=unsupportedSubtitle');
      _showOsd(t.video_subtitle_import_unsupported);
      return;
    }
    if (files.audios.isNotEmpty && files.videos.isEmpty) {
      debugPrint('[hibiki-drop] [video-playback] intent=unsupportedAudio');
      _showOsd(t.video_drop_audio_unsupported);
      return;
    }
    if (files.hasAny) {
      debugPrint('[hibiki-drop] [video-playback] intent=unsupportedSurface');
      _showOsd(t.video_drop_subtitle_only);
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
    debugPrint(
      '[hibiki-drop] [video-playback] externalSubtitle imported '
      'path=$dest',
    );
  }

  /// 字幕抽取/解析当前是否在进行。状态显示在右侧半透明字幕源面板里，画面仍可见；
  /// 底层 ffmpeg/文件解析 Future 目前没有取消契约，关闭面板只是不再打断观看。
  bool _subtitleLoadingShown = false;

  /// 在字幕源侧栏里展示非阻塞加载状态（BUG-104：大容器内嵌字幕 demux 可达数十秒）。
  void _showSubtitleLoadingOverlay() {
    if (_subtitleLoadingShown || !mounted) return;
    setState(() => _subtitleLoadingShown = true);
    if (_videoSidePanel.value?.kind != _VideoSidePanelKind.subtitleSources) {
      _showVideoSidePanel(_VideoSidePanelKind.subtitleSources);
    }
  }

  /// 关闭字幕抽取加载状态。配对 [_showSubtitleLoadingOverlay]，幂等，并在下一帧把
  /// 键盘焦点还给视频，避免文件选择器/外部对话框返回后快捷键悬空。
  void _hideSubtitleLoadingOverlay() {
    if (!_subtitleLoadingShown) return;
    if (mounted) {
      setState(() => _subtitleLoadingShown = false);
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
      final bool shown = await controller.selectEmbeddedGraphicTrack(
        source.streamIndex!,
      );
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
          ? Center(child: Icon(Icons.error_outline, color: cs.error, size: 48))
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
      debugLabel: 'video-playback-page',
      onDrop: (List<String> paths, Offset _) {
        _handlePlaybackDrop(controller, paths);
      },
      child: child,
    );
  }

  void _handleVideoPointerUp(PointerUpEvent event) {
    // 点视频区任意位置 = 用户把交互意图交还播放器：顺手收回键盘焦点（TODO-040 ①
    // 「点了外面/焦点丢失后」的恢复路径——与原生播放器一致，点一下画面即恢复键盘）。
    // 查词浮层打开时点击被根 Overlay barrier 拦截、到不了这里，guard 仅兜底；点
    // 控制条按钮随后弹出的菜单/对话框会再夺焦，其 whenComplete 自会归还，不冲突。
    if (!_hasVisiblePopup) _refocusVideo();
    // 触屏点画面唤回视频左侧锁 / 解锁按钮（TODO-126）。沉浸态下控制条指针被 gate，但本
    // 外层 Listener 在 gate 之外仍收到指针，故沉浸态点画面也能唤回解锁按钮（移动端无 hover）。
    _pokeLockButton();
    // 侧栏（设置 / 字幕列表 / 音轨等）打开时，点面板本身不应被误判成「点画面」（BUG-246）：
    // 侧栏 overlay 是本 Stack 的子节点，但本外层 [Listener] 用 translucent 命中行为，仍会
    // 收到落在面板上的 pointer-up；若放行下方逻辑，连续两次点面板会被 400ms/48px 双击判据
    // 误判成「双击画面」→ 桌面触发 [_toggleVideoFullscreen]、移动触发暂停。这里对齐沉浸锁
    // 的早返回门控：任意侧栏开着时一律不参与控制条 toggle / 双击 / 暂停 / 全屏判定，并清掉
    // 双击追踪，避免关闭面板后残留时间戳被下一次真点画面误配成双击。
    if (_videoSidePanel.value != null) {
      _lastVideoPointerUpAt = null;
      _lastVideoPointerUpPosition = null;
      return;
    }
    final BuildContext? controlsContext = _videoControlsContext;
    if (controlsContext == null ||
        !controlsContext.mounted ||
        _isVideoChromePointer(controlsContext, event.position)) {
      _lastVideoPointerUpAt = null;
      _lastVideoPointerUpPosition = null;
      return;
    }

    // 移动端点画面（非控制条按钮）的控制条显隐 toggle 不再在 Hibiki 侧另做镜像
    // （TODO-364）：本外层 [Listener] 是 translucent，同一次点击会继续命中下方 media_kit
    // 移动控制条自己的手势层 → 其 `onTap` 翻 `visible` 并推送 [_mediaKitControlsVisible]，
    // 字幕避让由 [_applyControlsVisibilityFromMediaKit] 派生，与真实控制条同相位（旧实现在此
    // 用 Hibiki 镜像独立 toggle，与 media_kit 各自计时 → 并发操作时方向反，是本 BUG 根因）。

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
    if (_immersiveLocked.value && !_immersiveAllowsDoubleTapSeek) {
      return;
    }
    // TODO-173/BUG-231: 双击左/右区先尝试快进/快退（或跳上/下一句）。落在左 / 右
    // 区（且双击行为已开启）则在此早返回。未锁定或 full 模式下，中带（中间 1/3）
    // 落空继续走下方平台分流，保留 BUG-221 的双击暂停（移动）/ 全屏（桌面）。
    final bool doubleTapHandled =
        _handleDoubleTapSeek(controlsContext, event.position);
    if (doubleTapHandled) return;
    // seekAndLookup 锁定态只允许左右双击 seek + 查词；配置为 0、点中带或布局不可判定时
    // 必须消费掉双击，不能漏到暂停 / 全屏 fallback。
    if (_immersiveLocked.value &&
        _videoImmersiveMode == VideoImmersiveMode.seekAndLookup) {
      return;
    }
    // BUG-221: 双击命中（中带）后按平台分流。
    // - 移动端：双击 = 播放/暂停。原先双击 → [_toggleVideoFullscreen] → media_kit 全屏路由，
    //   退出时弹回竖屏，用户感知为「双击 = 竖屏」。移动端横屏沉浸态即唯一形态、无「全屏」
    //   语义，双击应等同原生播放器的暂停手势。
    // - 桌面：保留双击全屏（窗口全屏有意义，走 native window 不碰设备方向）。
    if (_isDesktopVideoControls) {
      unawaited(_toggleVideoFullscreen(controlsContext));
    } else {
      unawaited(_controller?.playOrPause() ?? Future<void>.value());
    }
  }

  /// 双击左 / 右区快退 / 快进（TODO-173/BUG-231）。返回 true=已处理（左 / 右区），
  /// 调用方应早返回、不再走平台默认的暂停 / 全屏；false=落在中带（中间 1/3）或功能
  /// 关闭，调用方继续走 BUG-221 的暂停 / 全屏分流。
  ///
  /// 用 [_videoControlsContext] 的 [RenderBox] 把双击点 [globalPosition] 换成本地坐标
  /// 拿 dx 与可视区宽度（复用 [_isVideoChromePointer] 的 `globalToLocal` 范式），按
  /// 三等分判定：左 1/3 → 后退、右 1/3 → 前进、中间 1/3 → 中带（保留暂停 / 全屏）。
  /// [VideoAsbplayerConfig.doubleTapSeekSeconds]：0=关（整体跳过分区）、3/5/10=相对
  /// seek 该秒数、[VideoAsbplayerConfig.kDoubleTapSubtitle]=跳上 / 下一句。
  bool _handleDoubleTapSeek(
    BuildContext controlsContext,
    Offset globalPosition,
  ) {
    final int action = _asbConfig.doubleTapSeekSeconds;
    if (action == 0) return false; // 关：双击全部走暂停/全屏（向后兼容默认）。
    final RenderObject? renderObject = controlsContext.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return false;
    final double width = renderObject.size.width;
    if (width <= 0) return false;
    final double localDx = renderObject.globalToLocal(globalPosition).dx;
    final bool left = localDx < width / 3;
    final bool right = localDx > width * 2 / 3;
    if (!left && !right) return false; // 中带：落空，交回平台分流。
    final bool forward = right;
    if (action == VideoAsbplayerConfig.kDoubleTapSubtitle) {
      // 字幕模式：双击左/右 = 跳上/下一句（无字幕段回退/前进 seekSeconds 秒，TODO-119/073）。
      unawaited(_skipCueAndPokeControls(forward: forward));
      _showOsd(
        forward ? t.video_double_tap_next_cue : t.video_double_tap_prev_cue,
        icon: forward ? Icons.fast_forward : Icons.fast_rewind,
      );
    } else {
      // 秒数模式：相对 seek ±action 秒。
      final int deltaMs = (forward ? action : -action) * 1000;
      unawaited(_seekRelative(deltaMs));
      _showOsd(
        '${forward ? '+' : '-'}${action}s',
        icon: forward ? Icons.fast_forward : Icons.fast_rewind,
      );
    }
    return true;
  }

  bool _isVideoChromePointer(
    BuildContext controlsContext,
    Offset globalPosition,
  ) {
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

  /// 桌面右键 = 视频上下文菜单（TODO-048c）。右键松手处 [globalPosition] 作锚点弹
  /// [showMenu] PopupMenu，项全部复用既有动作 helper（不重造）。锚定到
  /// [_videoControlsContext]——它在全屏期间是全屏路由子树的 context（见
  /// [_buildVideoControlsInner] / [VideoControlsFocusGate]），故 showMenu 找到的是
  /// 全屏路由的 Overlay，菜单在窗口与全屏两种场景都能正确浮出（与字幕跳转列表 /
  /// 锁定层同源的全屏安全范式，TODO-069/101）。移动端无次按钮、此回调不触发，且
  /// 这里再门控一次（[_isDesktopVideoControls]）双保险。右键菜单含完整播放控制，沉浸锁
  /// 仅 full 模式允许打开；seekAndLookup / lookupOnly / unlockOnly 均不能绕过四段 gate。
  ///
  /// 界面缩放坐标对齐（BUG-260）：视频页整页被 [HibikiAppUiScaleNeutralizer] 中和回
  /// 净缩放=1 的**真实视口空间**（见 [VideoHibikiPage.neutralized]），故
  /// [_videoControlsContext] 的 RenderBox 在真实屏幕坐标系；而 [showMenu] 把
  /// [RelativeRect] 解读为路由 **Overlay** 的坐标系——该 Overlay 在全局
  /// [HibikiAppUiScale] 的 `FittedBox(BoxFit.fill)` 之内＝缩放后的画布空间。两套坐标差
  /// 一个 factor=scale，原实现直接拿 controls 盒子的 `globalToLocal` 当锚点（真实空间），
  /// 界面大小≠100% 时菜单偏离鼠标 factor≈scale（用户报「调界面大小后右键菜单不在鼠标处」）。
  ///
  /// 修复与查词浮层（[_lookupAt]/[_buildPopupOverlay]）同范式：不读 scale 数值逆算
  /// （界面大小「自动」模式下生效 scale 由视口/平台动态算出，≠ `appModel.appUiScale`），
  /// 而用 `localToGlobal(..., ancestor: overlay)` 把右键点从 controls 盒子的本地（真实）
  /// 空间沿真实渲染变换链一路映射到 **Overlay 盒子** 坐标系——其间的 FittedBox 缩放被
  /// render transform 链自动吸收，对任意 scale（含自动模式）都自洽、无残差；缩放=1 时
  /// `ancestor` 变换为单位阵，与原行为逐像素等价（向后兼容）。
  void _handleSecondaryTap(Offset globalPosition) {
    if (!_isDesktopVideoControls) return;
    if (!_immersiveAllowsFullControls) return;
    final VideoPlayerController? controller = _controller;
    final BuildContext? ctx = _videoControlsContext;
    if (controller == null || ctx == null || !ctx.mounted) return;
    final RenderObject? renderObject = ctx.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return;
    // showMenu 用 [ctx] 最近的 Navigator（rootNavigator:false）的 Overlay 作菜单宿主；
    // [RelativeRect] 须落在该 Overlay 的坐标系。取同一个 Overlay 的 RenderBox 作变换
    // 目标，使锚点与菜单宿主同系（FittedBox 缩放残差被 ancestor 变换吸收，BUG-260）。
    final RenderObject? overlayObject =
        Overlay.of(ctx).context.findRenderObject();
    if (overlayObject is! RenderBox || !overlayObject.hasSize) return;
    // 右键点：globalPosition 先回 controls 本地（真实空间），再沿真实渲染变换链映射到
    // Overlay 坐标系（吃掉中和器还原 + 全局 FittedBox 缩放的所有变换）。
    final Offset localInControls = renderObject.globalToLocal(globalPosition);
    final Offset anchor = renderObject.localToGlobal(
      localInControls,
      ancestor: overlayObject,
    );
    final Size overlaySize = overlayObject.size;
    final RelativeRect position = RelativeRect.fromLTRB(
      anchor.dx,
      anchor.dy,
      overlaySize.width - anchor.dx,
      overlaySize.height - anchor.dy,
    );
    unawaited(
      showMenu<VoidCallback>(
        context: ctx,
        position: position,
        items: _buildVideoContextMenuItems(controller),
      ).then((VoidCallback? action) {
        action?.call();
        // 菜单关闭后把键盘焦点还给 Video（覆盖层夺焦后不会自动归还，与其它 sheet
        // 同样的 _refocusVideo 收尾）。点中项时其 helper 可能再弹 sheet 并各自归还，
        // 不冲突；未点中（点外部关闭）时这一下把焦点收回。
        _refocusVideo();
      }),
    );
  }

  /// 构造桌面右键上下文菜单项（TODO-048c）。每项 value 是该项动作回调，菜单关闭后由
  /// [_handleSecondaryTap] 统一执行——避免在 onTap 里立刻 pop 再异步执行的时序问题。
  /// 项集对齐桌面控制条按钮（播放/暂停、全屏、速度、字幕轨、音轨、截图、字幕列表、
  /// 锁定、跨字幕制卡），全部复用既有 helper。
  ///
  /// 着色器「对比原画」已从右键菜单移除（BUG-261，用户要求）：该功能改只走 `C` 快捷键
  /// （`ShortcutAction.videoToggleShaderCompare`，见 video_player_shortcuts.dart）与设置页
  /// 进入。[_toggleShaderCompare] 方法与 `C` 接线保留，只删右键这一项；右键不再依赖
  /// 「是否启用着色器」的判定（原 `_hasShadersEnabled` getter 随该项一并移除）。
  List<PopupMenuEntry<VoidCallback>> _buildVideoContextMenuItems(
    VideoPlayerController controller,
  ) {
    PopupMenuItem<VoidCallback> item(
      IconData icon,
      String label,
      VoidCallback onSelected,
    ) {
      return PopupMenuItem<VoidCallback>(
        value: onSelected,
        child: Row(
          children: <Widget>[
            Icon(icon, size: _videoControlIconSize),
            const SizedBox(width: 12),
            Expanded(child: Text(label)),
          ],
        ),
      );
    }

    return <PopupMenuEntry<VoidCallback>>[
      item(
        Icons.play_arrow,
        t.video_menu_play_pause,
        () => unawaited(controller.playOrPause()),
      ),
      item(Icons.fullscreen, t.video_menu_fullscreen, () {
        final BuildContext? ctx = _videoControlsContext;
        if (ctx != null && ctx.mounted) {
          unawaited(_toggleVideoFullscreen(ctx));
        }
      }),
      item(Icons.speed, t.video_setting_speed, _showSpeedMenu),
      const PopupMenuDivider(),
      item(
        Icons.subtitles,
        t.video_menu_subtitle_track,
        () => _showSubtitleSourceMenu(controller),
      ),
      item(
        Icons.format_list_bulleted,
        t.video_subtitle_list,
        _toggleSubtitleJumpList,
      ),
      item(
        Icons.collections_bookmark_outlined,
        t.video_favorite_sentences,
        _showFavoriteSentencesPanel,
      ),
      item(
        Icons.audiotrack,
        t.video_audio_track,
        () => _showAudioTrackMenu(controller),
      ),
      const PopupMenuDivider(),
      item(Icons.photo_camera_outlined, t.video_screenshot, _saveScreenshot),
      item(
        Icons.movie_creation_outlined,
        t.video_clip_export,
        () => unawaited(_toggleClipExport()),
      ),
      item(Icons.lock_outline, t.video_menu_lock, _toggleImmersiveLock),
      // 设置入口（TODO-389）：右键菜单补一项打开视频设置侧栏，与桌面右侧 rail 的
      // `VideoControlButton.settings` 走同一个 [_showPlayerSettings]（→
      // [_showVideoSidePanel](_VideoSidePanelKind.settings)）。图标用 `Icons.tune`
      // 与可配置 settings 按钮（[_controlButtonIcon] 的 VideoControlButton.settings 分支）
      // 保持一致；标签复用既有 `video_settings_title`（侧栏标题同 key，见
      // [_videoSidePanelTitle]）。
      item(Icons.tune, t.video_settings_title, _showPlayerSettings),
    ];
  }

  /// 视频本体：media_kit [Video] + 可点字幕 overlay。查词浮层栈不在这里渲染——它走
  /// 根 Overlay（[_syncPopupOverlay] / [_buildPopupOverlay]），以便全屏时浮在全屏
  /// 路由之上。每次 build 在 post-frame 同步根 Overlay 与当前栈。
  Widget _buildVideoBody(
    VideoPlayerController controller,
    VideoController videoController,
  ) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncPopupOverlay());
    final ({
      MaterialVideoControlsThemeData mobile,
      MaterialDesktopVideoControlsThemeData desktop,
    }) controlsTheme = _currentVideoControlsTheme(
      controller,
      _controlLayout,
    );
    // 两层主题嵌套：[AdaptiveVideoControls] 按平台互斥择一渲染（桌面读 Desktop
    // 主题、移动读 Material 主题），故同时提供两套互不干扰，让字幕/音轨/设置入口
    // 在桌面、移动、全屏三种场景都可达。嵌套顺序不影响——各自被对应平台 controls 读取。
    // 'B' 切换字幕模糊（TODO-134）现已并入可重映射注册表（video scope），随其它视频键
    // 一起经 media_kit 的 keyboardShortcuts 整表安装，不再需要本页内层的独立
    // CallbackShortcuts；press-edge-only（includeRepeats:false）由
    // buildVideoPlayerShortcutsFromRegistry 对该 action 保留。
    return VideoControlsThemePair(
      mobile: controlsTheme.mobile,
      desktop: controlsTheme.desktop,
      // 字幕跳转列表「真 push-aside」（TODO-121）：面板可见时把 Video 包进
      // Row[Expanded(Video), 面板列]，画面真挤窄、不被遮（见 [_videoWithSubtitlePanel]）。
      child: _videoWithSubtitlePanel(
        controller,
        Video(
          controller: videoController,
          // 用本页持有的 FocusNode 替换 Video 内置的匿名节点，以便覆盖层（对话框 /
          // bottom sheet / 文件选择器）关闭后能主动把键盘焦点还给它，恢复空格等内置
          // 快捷键（见 [_refocusVideo]）。
          focusNode: _videoFocusNode,
          // 禁用 media_kit 内置 SubtitleView（TODO-080/092，BUG-190）：字幕统一由
          // [VideoSubtitleOverlay] 单层承载（cue 同步 + 逐字查词）。SubtitleView 默认
          // visible:true，会把 libmpv 解析的字幕渲染成一整块不可点 Text（白字 +
          // 0xaa000000 半透明黑底），叠在可点 overlay 之上 → 点字幕穿透到 media_kit
          // 自己的手势层（落句首词/点不到句中/呼出键盘，080-3）、随字幕轨异步刷新时有
          // 时无（080-1 随机透明）、横竖屏 Video 子树重建时残留黑底（092）。这里显式
          // visible:false 让 video_texture.dart 的 `if(...visible && ...)` 不渲染
          // SubtitleView；窗口与全屏共享 videoViewParametersNotifier，全屏路由侧再显式
          // 覆盖一次（不靠隐式传播，消除快照时机竞态）。
          subtitleViewConfiguration: const SubtitleViewConfiguration(
            visible: false,
          ),
          // 窗口模式画面缩放/比例由用户偏好 [_videoFitMode] 决定（TODO-152 子B），
          // 新安装默认 [VideoFitMode.contain] → `BoxFit.contain` 保持比例完整适应；
          // 已有用户偏好 [cover]/[fill] 会按持久化值恢复；
          // 不会被新安装初始值覆盖。
          // 根因背景：media_kit 默认 `BoxFit.contain` 在「媒体框宽高比 ≠ 视频宽高比」时
          // 两侧补黑。桌面虽有窗口比例锁（[_syncWindowAspectRatioLock] → window_manager
          // `setAspectRatio`），但其 Windows 实现只在用户**拖动窗口边框**时（WM_SIZING）
          // 约束比例、不矫正当前窗口尺寸 → 非全屏非最大化的当前窗口若比例不等于视频，
          // contain 仍留黑边（平台限制）。用户改选 [VideoFitMode.cover] 即铺满并裁切
          // 超出边缘（比例锁稳态下窗口贴合视频比例 → cover≈contain 几乎不裁）；
          // [VideoFitMode.fill] 则拉伸填满。
          // 字幕是独立 overlay 层（[VideoSubtitleOverlay]，不在 [Video] 内）不受裁切影响。
          // 全屏路由的 Video 在其 builder 内读同一 [_videoFitMode] 换算，跟随同偏好。
          fit: videoFitModeToBoxFit(_videoFitMode),
          // letterbox/pillarbox 填充色固定纯黑（TODO-053）：cover 稳态下无外围，但
          // 视频解码前 / 极端比例残留边缘仍按播放器惯例用黑底，不跟随主题 surface。
          fill: Colors.black,
          // 字幕 overlay + 拖拽挂载都包进 controls builder：media_kit 全屏推独立 root
          // 路由并复用同一 controls，故 overlay 随全屏一起进路由，全屏时字幕仍显示且
          // 可点查词、拖字幕也能挂载（见 [_buildVideoControls]）。
          controls: (VideoState state) =>
              _buildVideoControls(state, controller),
          // BUG-221: 替换 media_kit 默认全屏方向回调，禁止移动端退全屏时
          // `setPreferredOrientations([])` 弹回竖屏。自建全屏路由（[_pushNeutralizedVideoFullscreen]）
          // 经 `state.widget.onEnterFullscreen`/`onExitFullscreen` 取的就是这俩，故窗口侧设
          // 一次即覆盖全部全屏方向行为。移动端门控在 helper 内（只锁横屏，永不放开方向）；
          // 桌面转调 media_kit 默认回调，保留「全屏 = OS 窗口真全屏」（不碰设备方向）。
          onEnterFullscreen: _enterVideoNativeFullscreen,
          onExitFullscreen: _exitVideoNativeFullscreen,
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
    //
    // [VideoControlsFocusGate]：全屏路由在栈上时卸载窗口侧本子树（全屏侧实例因
    // 能看到 FullscreenInheritedWidget 不受影响），保证共享 [_videoFocusNode]
    // 任意时刻只被一个 Focus 持有——否则退全屏后节点被摘成永久孤儿、全部快捷键
    // 死亡（见 gate 的类文档，TODO-040/042 根因）。顺带保证 [_videoControlsContext]
    // 在全屏期间必是全屏子树的 context（窗口侧 Builder 不再运行），Esc/F 的
    // isFullscreen 判定不会被窗口侧重建覆写。
    return VideoControlsFocusGate(
      fullscreenRouteActive: _videoFullscreenActive,
      child: _buildVideoControlsInner(state, controller),
    );
  }

  ({
    MaterialVideoControlsThemeData mobile,
    MaterialDesktopVideoControlsThemeData desktop,
  }) _currentVideoControlsTheme(
    VideoPlayerController controller,
    VideoControlLayout layout,
  ) {
    return (
      mobile: _mobileControlsTheme(controller, layout),
      desktop: _desktopControlsTheme(controller, layout),
    );
  }

  /// 桌面 hover 追踪层（TODO-129）：覆盖整个视频控制区，镜像 media_kit 自己的
  /// `MouseRegion.onEnter/onHover/onExit` 翻 [_videoControlsVisible]，让字幕动态避让进度
  /// 条。`opaque:false`：不阻断 hover hit-test 继续下探到 media_kit 的 `MouseRegion`，
  /// 故 media_kit 控制条仍照常被鼠标唤起、字幕逐字查词 / 点击不受影响（与字幕层
  /// BUG-198 同款 non-opaque 纪律）。仅桌面挂 hover；移动端无 hover 语义，可见性走
  /// [_handleVideoPointerUp] 的点画面 toggle，故透传 child 零开销。本层与字幕 overlay
  /// 同在 controls builder 内，全屏复用同一 builder → 窗口与全屏共用同一追踪。
  Widget _videoControlsHoverWrap({required Widget child}) {
    if (!_isDesktopVideoControls) return child;
    return MouseRegion(
      opaque: false,
      // 鼠标移动也唤回视频左侧锁 / 解锁按钮（TODO-126）。[_pokeLockButton] 不被锁 gate
      // （[_markControlsVisible] 在沉浸态强制 false），故沉浸态解锁按钮淡出后能被鼠标唤回。
      // onExit 不立即收起锁按钮——交给 [_pokeLockButton] 的 2s 计时器自然淡出（无操作淡出）。
      onEnter: _handleVideoControlsHover,
      onHover: _handleVideoControlsHover,
      onExit: _handleVideoControlsHoverExit,
      child: child,
    );
  }

  /// OS 光标隐藏统一胜出层（TODO-318 / BUG-258）。放在 controls Stack **最顶层**
  /// （front-most），cursor 解析按 front-to-back 取第一个非 defer：故隐藏时本层 `none`
  /// 胜过下方所有 chrome（锁按钮 rail / 字幕面板 / OSD 等）的 click cursor。`opaque:false`
  /// 不阻断指针下探（按钮 hover / 点击照常到下层 chrome），故不回归 BUG-198 hover 穿透；
  /// `IgnorePointer` 在不隐藏时彻底让出（cursor: defer 透明）。仅桌面有 OS 光标，移动端
  /// 调用方根本不挂本层。
  Widget _buildCursorOverlay() {
    return Positioned.fill(
      child: ValueListenableBuilder<bool>(
        valueListenable: _cursorHidden,
        builder: (BuildContext _, bool hidden, __) {
          if (!hidden) return const SizedBox.shrink();
          return const MouseRegion(
            opaque: false,
            cursor: SystemMouseCursors.none,
          );
        },
      ),
    );
  }

  /// [_buildVideoControls] 的实体（gate 之内）：拖放目标 + controls + 字幕 overlay
  /// + OSD。
  Widget _buildVideoControlsInner(
    VideoState state,
    VideoPlayerController controller,
  ) {
    return ValueListenableBuilder<VideoControlLayout>(
      valueListenable: _controlLayoutNotifier,
      builder: (BuildContext context, VideoControlLayout layout, _) {
        final ({
          MaterialVideoControlsThemeData mobile,
          MaterialDesktopVideoControlsThemeData desktop,
        }) controlsTheme = _currentVideoControlsTheme(controller, layout);
        return VideoControlsThemePair(
          mobile: controlsTheme.mobile,
          desktop: controlsTheme.desktop,
          child: _videoControlsHoverWrap(
            child: HibikiFileDropTarget(
              debugLabel: 'video-playback-controls',
              onDrop: (List<String> paths, Offset _) {
                _handlePlaybackDrop(controller, paths);
              },
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerUp: _handleVideoPointerUp,
                // 桌面右键 = 视频上下文菜单（TODO-048c）。GestureDetector 只接管次按钮
                // （右键）的 tap，左键双击全屏仍走外层 Listener.onPointerUp（两路指针语义互不
                // 干扰）。onSecondaryTapUp 提供右键松手处的 globalPosition 作 showMenu 锚点。
                // 移动端无次按钮、永不触发，但 [_handleSecondaryTap] 内再门控一次（双保险）。
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onSecondaryTapUp: (TapUpDetails details) =>
                      _handleSecondaryTap(details.globalPosition),
                  onLongPressStart: _handleVideoLongPressStart,
                  onLongPressMoveUpdate: _handleVideoLongPressMoveUpdate,
                  onLongPressEnd: _handleVideoLongPressEnd,
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
                            // 锁定 / 沉浸模式（TODO-101）：用 IgnorePointer 拦掉送往 media_kit
                            // controls 的所有指针事件——其 MouseRegion.onHover/onEnter 收不到
                            // 鼠标移动 → 控制条不再被唤起（顶/底栏按钮不弹）。IgnorePointer 只
                            // 过滤指针，不影响键盘：media_kit 的 CallbackShortcuts + Focus 是
                            // MouseRegion 的祖先（见 media_kit material_desktop.dart），快捷键照常
                            // 收键；字幕逐字查词由更上层 [VideoSubtitleOverlay] 承载（在本 Stack
                            // AdaptiveVideoControls 之上），点字幕仍能查词。可见性走 ValueNotifier
                            // 让全屏路由也响应（BUG-120 同源）。
                            //
                            // 侧栏 / 字幕列表打开时也一并 gate（BUG-253 / TODO-329）：overlay 盖在
                            // 控制条上，但 media_kit 自己的 MouseRegion 仍会在鼠标移过透明背景区时
                            // 把控制条弹回到 overlay 后面，且其 `hideMouseOnControlsRemoval` 会在
                            // 控制条 2s 自动收起后隐藏视频区光标（用户报「沉浸/锁屏下鼠标放字幕被
                            // 隐藏」的画面区分支）。把 [IgnorePointer] 同时绑 [_videoSidePanel] 与
                            // [_subtitleListVisible]，overlay 期间 media_kit 收不到 hover → 背景控制条
                            // 不再冒出来、其 cursor:none 也不接管光标。键盘仍不受影响（同上）。
                            return ListenableBuilder(
                              listenable: Listenable.merge(
                                <Listenable>[
                                  _immersiveLocked,
                                  _videoSidePanel,
                                  _subtitleListVisible,
                                  _videoControlEditMode,
                                ],
                              ),
                              builder: (BuildContext _, __) => IgnorePointer(
                                ignoring: _immersiveLocked.value ||
                                    _videoSidePanel.value != null ||
                                    _subtitleListVisible.value ||
                                    _videoControlEditMode.value,
                                child: AdaptiveVideoControls(state),
                              ),
                            );
                          },
                        ),
                      ),
                      // 进度条章节刻度层（TODO-432）：叠在 seek bar 同一几何上画每章一条竖线。
                      // IgnorePointer 纯视觉、不拦 seek bar 拖动；随控制条显隐、仅有章节时画。
                      _buildChapterMarkersOverlay(controller),
                      Positioned.fill(
                        child: VideoDanmakuOverlay(
                          items: _danmakuItems,
                          enabled: appModel.videoDanmakuEnabled,
                          maxActive: appModel.videoDanmakuMaxActive,
                          positionMs: () => controller.positionMs ?? 0,
                        ),
                      ),
                      Positioned.fill(
                        child: VideoSubtitleOverlay(
                          controller: controller,
                          onCharTap: _handleSubtitleLookupTap,
                          onHoverChanged: _handleSubtitleHover,
                          hitTester: _subtitleHitTester,
                          // 当前句已收藏时在字幕盒角标实心星（TODO-301）。读同一收藏缓存
                          // [_favoritedVideoSentences]（[_isCueFavorited]）；收藏 / 取消收藏
                          // 后 setState 触发本 builder 重建，标记即时更新。
                          isCueFavorited: _isCueFavorited,
                          blurEnabled: appModel.videoSubtitleBlur,
                          fontSize: _subtitleStyle.fontSize,
                          textColor: _subtitleStyle.resolveTextColor(
                            _subtitleTextColor(
                                _videoChromeColorScheme(context)),
                          ),
                          fontWeight:
                              _subtitleStyle.resolveFontWeight(_videoUiScale),
                          shadowColor: _subtitleStyle.resolveShadowColor(
                            _subtitleShadowColor(
                                _videoChromeColorScheme(context)),
                          ),
                          shadowThickness:
                              _subtitleStyle.resolveShadowThickness(
                            _videoUiScale,
                          ),
                          backgroundColor:
                              _subtitleStyle.resolveBackgroundColor(
                            _subtitleBackgroundColor(
                              _videoChromeColorScheme(context),
                            ),
                          ),
                          backgroundOpacity: _subtitleStyle.backgroundOpacity,
                          bottomPadding: _subtitleStyle.bottomPadding,
                          // 控制条可见性驱动动态避让（TODO-129）：进度条出现时字幕底缘对
                          // 进度条上缘取下限（max，非加法——BUG-226 防顶飞）、隐藏落回。全屏
                          // 复用同一 builder + ValueNotifier，故窗口与全屏都跟随（BUG-120 同源）。
                          controlsVisible: _videoControlsVisible,
                          // 进度条上缘距视频底边的真实高度（按平台控制条几何加总 + 随界面
                          // 缩放，BUG-238）。旧默认常量 56 既不随缩放、又低于默认基线 75 →
                          // 移动端 `max(75, 56)=75` 把字幕留在被抬高的进度条下面被遮（用户报
                          // 「只动一点点」）。显式传入真实几何，移动端 reserve ≈ 140×缩放 >
                          // 75 才真正抬升盖过进度条；桌面仍只让一个按钮行高（保 BUG-228 观感）。
                          controlsBottomReserve:
                              _subtitleControlsBottomReserve(),
                          fontFamily: appModel.appFontFamily,
                        ),
                      ),
                      _buildOsdOverlay(),
                      _buildLevelHudOverlay(),
                      _buildVideoSideActionRail(controller),
                      _buildVideoSidePanelOverlay(controller),
                      _buildVideoControlPopoverOverlay(controller),
                      ValueListenableBuilder<bool>(
                        valueListenable: _videoControlEditMode,
                        builder: (BuildContext _, bool editing, __) {
                          if (!editing) return const SizedBox.shrink();
                          return Positioned.fill(
                            child: VideoControlLayoutEditOverlay(
                              layout: layout,
                              onLayoutChanged: _setVideoControlLayout,
                              onClose: _hideVideoControlEditOverlay,
                              // TODO-554：触屏保留「设置」按钮入口不可移除。
                              isTouchControls: !_isDesktopVideoControls,
                            ),
                          );
                        },
                      ),
                      // TODO-318：光标隐藏统一胜出层放 Stack 最顶（front-most），隐藏时其
                      // cursor:none 胜过下方所有 chrome 的 click cursor；桌面才挂（移动端无 OS 光标）。
                      if (_isDesktopVideoControls) _buildCursorOverlay(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 给浮动 rail 的按钮列套「hover 保活」MouseRegion（BUG-283）。`opaque:false`：不阻断
  /// 指针下探到下层 chrome / media_kit（按钮点击、画面 hover 不受影响，沿用 BUG-198 的
  /// non-opaque 纪律）。鼠标进按钮列即置 [_railHovered]=true → rail 显隐判据据此保持显示，
  /// 杜绝「opaque 按钮遮挡 media_kit MouseRegion 触发 onExit → 收 rail → 重新 onEnter」的
  /// 闪烁振荡；同时 [_pokeControlsVisible] 喂合成 hover 让底层控制条一并保活（media_kit 自
  /// 身设计的续命路径）。移出按钮列置 false，rail 可见性回落到 [_videoControlsVisible]，鼠标
  /// 落回画面会命中 media_kit region 自然续命、2s 后随控制条一起淡出。仅桌面挂（移动端无
  /// hover，透传 child 零开销）。
  Widget _railHoverKeepAlive({required Widget child}) {
    if (!_isDesktopVideoControls) return child;
    return MouseRegion(
      opaque: false,
      onEnter: (_) {
        _railHovered.value = true;
        _pokeControlsVisible();
      },
      onHover: (_) {
        // 鼠标在按钮列内移动时持续保活：续命 media_kit 控制条隐藏定时，避免停留期 timer
        // 到期把底层控制条收走（rail 本身由 [_railHovered] 顶住、不受影响）。
        _railHovered.value = true;
        _pokeControlsVisible();
      },
      onExit: (_) => _railHovered.value = false,
      child: child,
    );
  }

  /// 给侧边锁 / 解锁（沉浸）按钮套「hover 保活」MouseRegion（TODO-388，BUG-294）。与
  /// [_railHoverKeepAlive] 同款：`opaque:false` 不阻断指针下探（按钮点击 / 画面 hover 不受
  /// 影响），鼠标进按钮置 [_lockButtonHovered]=true 顶住可见、并 [_pokeLockButton] 续命自动
  /// 淡出定时；移出置 false，可见性回落到 [_lockButtonVisible] 的 2s 自然淡出。仅桌面挂
  /// （移动端无 hover，透传 child 零开销，沿用 [_railHoverKeepAlive] 的纪律）。
  Widget _lockButtonHoverKeepAlive({required Widget child}) {
    if (!_isDesktopVideoControls) return child;
    return MouseRegion(
      opaque: false,
      onEnter: (_) {
        _lockButtonHovered.value = true;
        _pokeLockButton();
      },
      onHover: (_) {
        _lockButtonHovered.value = true;
        _pokeLockButton();
      },
      onExit: (_) => _lockButtonHovered.value = false,
      child: child,
    );
  }

  /// 浮动侧栏（TODO-274/312 phase 2）：把 screenLeft / screenRight 两个屏幕侧槽
  /// （竖直居中浮条）的自定义按钮分别渲染。默认配置右侧保留学习按钮，左侧承接
  /// 可调整的沉浸锁；用户把按钮拖到任一侧后按真实 slot 显示。
  ///
  /// TODO-421 phase 1：topLeft / topRight 两个顶部槽不再渲染成「固定顶栏下方的浮动竖条」
  /// ——用户嫌它名不副实（选「Top bar (左/右)」却落在顶栏下方）。改为把这两槽的按钮注入
  /// 固定顶栏行本身（[_topBarSlotGroup] → [_desktopControlsTheme] / [_mobileControlsTheme]
  /// 的 `topButtonBar`），此处只剩屏幕左 / 右两条浮条。
  Widget _buildVideoSideActionRail(VideoPlayerController controller) {
    Widget right({bool immersiveOnly = false}) => _buildVideoSideRailFor(
          controller,
          VideoControlSlot.screenRight,
          Alignment.centerRight,
          const EdgeInsets.only(right: 12),
          immersiveOnly: immersiveOnly,
        );
    Widget left({bool immersiveOnly = false}) => _buildVideoSideRailFor(
          controller,
          VideoControlSlot.screenLeft,
          Alignment.centerLeft,
          const EdgeInsets.only(left: 12),
          immersiveOnly: immersiveOnly,
        );
    return Positioned.fill(
      // rail 的显隐由「控制条可见」**或**「鼠标正悬在 rail 上」决定（BUG-283）：后者保证
      // hover 期间 rail 永不被 media_kit 控制条的瞬时 visible 抖动收走，根除 opaque 按钮
      // 遮挡 media_kit MouseRegion 触发 onExit → 收 rail → 重新 onEnter 的闪烁振荡。
      child: ListenableBuilder(
        listenable: Listenable.merge(<Listenable>[
          _videoControlsVisible,
          _railHovered,
          _immersiveLocked,
          _videoSidePanel,
          _subtitleListVisible,
          _videoControlEditMode,
        ]),
        builder: (BuildContext context, __) {
          final bool controlsVisible = _videoControlsVisible.value;
          final bool railHovered = _railHovered.value;
          if (_videoSidePanel.value != null) {
            return const SizedBox.shrink();
          }
          if (_immersiveLocked.value) {
            final bool lockOnSideRail =
                _slotChipItems(VideoControlSlot.screenLeft)
                        .contains(VideoControlItem.immersiveLock) ||
                    _slotChipItems(VideoControlSlot.screenRight)
                        .contains(VideoControlItem.immersiveLock);
            if (!lockOnSideRail) {
              return Stack(children: <Widget>[_buildSideLockButton()]);
            }
            return Stack(
              children: <Widget>[
                left(immersiveOnly: true),
                right(immersiveOnly: true),
              ],
            );
          }
          if (_videoSideActionRailStronglySuppressed) {
            return const SizedBox.shrink();
          }
          if (!controlsVisible && !railHovered) return const SizedBox.shrink();
          return Stack(
            children: <Widget>[left(), right()],
          );
        },
      ),
    );
  }

  /// 单条浮动侧栏：渲染 [slot] 槽的学习按钮成一列圆形按钮，靠 [alignment] 贴边。
  /// 槽为空返回空白（不占位）。
  ///
  /// TODO-388：rail 按钮与其它控件一致地吃「界面大小」+「主题」（之前硬编码
  /// `Colors.black`/`Colors.white` 背景与图标、且 `IconButton` 不传 `iconSize` →
  /// 永远默认 24px、不随 appUiScale 缩放，也不随主题色变）。改为图标尺寸走
  /// [_videoControlIconSize]（base × [_videoUiScale]），背景 / 图标走
  /// [_videoChromeColorScheme]（与侧边锁按钮 [_buildSideLockButton] 同源），让左 / 右
  /// 浮动 rail 与底栏 / 顶栏 / 侧边锁按钮在缩放与配色上完全统一。
  Widget _buildVideoSideRailFor(
    VideoPlayerController controller,
    VideoControlSlot slot,
    AlignmentGeometry alignment,
    EdgeInsetsGeometry padding, {
    bool immersiveOnly = false,
  }) {
    // TODO-399 decision 3b: rails render EVERY chip-renderable item the user
    // placed here (learning + transport/nav keys), not just the five learning
    // keys. Rails are pure custom overlays with no media_kit chrome, so adding
    // transport keys here never collides / doubles with the bottom bar.
    final List<VideoControlItem> items = <VideoControlItem>[
      for (final VideoControlItem item in _slotChipItems(slot))
        if (!immersiveOnly || item == VideoControlItem.immersiveLock) item,
    ];
    if (items.isEmpty) return const SizedBox.shrink();
    final ColorScheme cs = _videoChromeColorScheme(context);

    Widget buttonFor(VideoControlItem item) {
      final LayerLink? popoverLink = item == VideoControlItem.speed
          ? _controlPopoverLinkFor(slot, item)
          : null;
      final Widget button = Material(
        color: cs.surface.withValues(alpha: 0.55),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: IconButton(
          tooltip: _videoControlItemTooltip(item),
          iconSize: _videoControlIconSize,
          icon: Icon(_videoControlItemIcon(item)),
          color: cs.onSurface,
          onPressed: () => _activateVideoControlItem(
            item,
            controller,
            popoverLink: popoverLink,
            sourceSlot: slot,
          ),
        ),
      );
      if (popoverLink == null) return button;
      return _controlPopoverAnchor(
        kind: _VideoControlPopoverKind.speed,
        link: popoverLink,
        desktop: _isDesktopVideoControls,
        sourceSlot: slot,
        sourceItem: VideoControlItem.speed,
        child: button,
      );
    }

    return Align(
      alignment: alignment,
      child: SafeArea(
        child: Padding(
          padding: padding,
          // 只在真正的按钮列上挂 keep-alive hover（不是整片 Positioned.fill）——否则鼠标
          // 在画面任意处都会被当成「悬在 rail 上」、rail 永不淡出（BUG-283）。
          child: _railHoverKeepAlive(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (final VideoControlItem item in items) ...<Widget>[
                  buttonFor(item),
                  if (item != items.last) const SizedBox(height: 8),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 把 [video]（media_kit `Video` 控件）与字幕跳转列表面板组成「真 push-aside」横向
  /// 布局（TODO-121，asbplayer 同款）。面板可见时返回 `Row[Expanded(video), 面板列]`：
  /// `Expanded` 收窄 `Video` 的 `Container` 宽度 → libmpv 纹理的 `FittedBox` 真正缩窄
  /// （画面整体左移、不被遮），而面板作为同级兄弟列占右侧固定宽度（不再 overlay 盖画面）。
  /// 隐藏时面板列宽收成 0、`Video` 占满整行（像素级等价于无面板的旧布局）。
  ///
  /// 窗口与全屏两条路径都各自调本函数包裹自己那棵 `Video`（窗口在 [_buildVideoBody]，
  /// 全屏在 [_pushNeutralizedVideoFullscreen] 自建的全屏路由里）——media_kit 全屏推独立
  /// root 路由、复用同一 controls builder，但 `Video` 控件由我们两处分别构建，故两路径
  /// 都能真挤窄、且字幕 overlay（在 `Video` controls 内 `Positioned.fill`）随收窄后的
  /// `Video` 区自动受限，不会画到被挤走的右侧或飘上面板。
  ///
  /// 可见性走 [_subtitleListVisible]（[ValueNotifier]，全屏路由也响应，BUG-120 同源）。
  /// 面板列宽按界面宽取 ~28%（横屏右侧栏，clamp 240..420），参照 asbplayer / YouTube
  /// transcript 侧栏占比。
  Widget _videoWithSubtitlePanel(
    VideoPlayerController controller,
    Widget video,
  ) {
    return ValueListenableBuilder<bool>(
      valueListenable: _subtitleListVisible,
      builder: (BuildContext _, bool visible, __) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: visible
                  // BUG-256：push-aside 字幕列表开着时，在画面区叠一层不可见 barrier，
                  // 点画面/外部 → 关列表（除控制条字幕按钮外的明确关闭入口）。barrier 用
                  // [HitTestBehavior.opaque] 吃掉点击、不冒泡到下方控制条 [Listener]，故点
                  // 画面只关列表、不触发暂停/全屏（与 overlay 面板的点外关闭一致）。
                  ? Stack(
                      fit: StackFit.expand,
                      children: <Widget>[
                        video,
                        Positioned.fill(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              _clearSelectedMiningCues();
                              _subtitleListVisible.value = false;
                              _pokeControlsVisible();
                              _refocusVideo();
                            },
                          ),
                        ),
                      ],
                    )
                  : video,
            ),
            _subtitleJumpSidePanel(controller, visible),
          ],
        );
      },
    );
  }

  /// [_videoWithSubtitlePanel] 的右侧面板列。用 [AnimatedSize] 让列宽在 0 ↔ panelWidth
  /// 之间平滑伸缩（画面被挤窄/还原也跟着动），可见时渲染 [VideoSubtitleJumpPanel]，隐藏
  /// 时宽度收成 0（[ClipRect] 裁掉收缩中溢出的内容，避免动画期文字越界）。[OverflowBox]
  /// 把面板内容固定在 panelWidth、不随收缩中的列宽被挤压，故伸缩动画里文字布局稳定。
  Widget _subtitleJumpSidePanel(
    VideoPlayerController controller,
    bool visible,
  ) {
    final ColorScheme cs = _videoChromeColorScheme(context);
    final double screenWidth = MediaQuery.sizeOf(context).width;
    final double panelWidth = (screenWidth * 0.28).clamp(240.0, 420.0);
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      alignment: Alignment.centerLeft,
      child: SizedBox(
        width: visible ? panelWidth : 0,
        child: visible
            ? ClipRect(
                child: OverflowBox(
                  alignment: Alignment.centerLeft,
                  minWidth: panelWidth,
                  maxWidth: panelWidth,
                  child: SafeArea(
                    left: false,
                    child: VideoSubtitleJumpPanel(
                      key: const ValueKey<String>('video-subtitle-jump-panel'),
                      controller: controller,
                      onTapCue: _handleSubtitleJumpTap,
                      onLookupCue: _handleSubtitleListLookup,
                      onCopyCue: _copyCueText,
                      onFavoriteCue: _toggleFavoriteCueForVideo,
                      isCueFavorited: _isCueFavorited,
                      isCueSelectedForCard: _isCueSelectedForCard,
                      onToggleCueSelection: _toggleCueSelectedForCard,
                      onClearCueSelection: _clearSelectedMiningCues,
                      onClose: () {
                        _clearSelectedMiningCues();
                        _subtitleListVisible.value = false;
                      },
                      colorScheme: cs,
                      title: t.video_subtitle_list,
                      emptyHint: t.video_subtitle_list_empty,
                      loadingHint: t.video_subtitle_list_loading,
                      fontSize: 14 * _videoUiScale,
                      width: panelWidth,
                    ),
                  ),
                ),
              )
            : const SizedBox.shrink(),
      ),
    );
  }

  Widget _buildRightVolumeIndicator(double volume) {
    final ColorScheme cs = _videoChromeColorScheme(context);
    final double clamped = volume.clamp(0.0, 100.0).toDouble();
    final Color textColor = _osdTextColor(cs);
    final double scale = _videoUiScale;
    return IgnorePointer(
      child: VideoLevelHudCard(
        value: clamped,
        uiScale: scale,
        icon: _volumeIconFor(clamped),
        alignment: Alignment.centerRight,
        minimum: EdgeInsets.only(
          left: 16,
          top: 16,
          right: 76 * scale,
          bottom: 16,
        ),
        surfaceColor: _osdSurfaceColor(cs),
        textColor: textColor,
        shadowColor: cs.shadow,
        frameKey: videoVolumeHudFrameKey,
        progressKey: videoVolumeHudProgressKey,
      ),
    );
  }

  Widget _buildLeftBrightnessIndicator(double brightness) {
    final ColorScheme cs = _videoChromeColorScheme(context);
    final double clamped = brightness.clamp(0.0, 100.0).toDouble();
    final Color textColor = _osdTextColor(cs);
    final double scale = _videoUiScale;
    return IgnorePointer(
      child: VideoLevelHudCard(
        value: clamped,
        uiScale: scale,
        icon: _brightnessIconFor(clamped),
        alignment: Alignment.centerLeft,
        minimum: EdgeInsets.only(
          left: 76 * scale,
          top: 16,
          right: 16,
          bottom: 16,
        ),
        surfaceColor: _osdSurfaceColor(cs),
        textColor: textColor,
        shadowColor: cs.shadow,
        frameKey: videoBrightnessHudFrameKey,
        progressKey: videoBrightnessHudProgressKey,
      ),
    );
  }

  Widget _buildLevelHudOverlay() {
    return Positioned.fill(
      child: IgnorePointer(
        child: ValueListenableBuilder<_VideoLevelHudState?>(
          valueListenable: _levelHudNotifier,
          builder: (BuildContext _, _VideoLevelHudState? hud, __) {
            return AnimatedSwitcher(
              duration: const Duration(milliseconds: 160),
              child: hud == null
                  ? const SizedBox.shrink()
                  : switch (hud.kind) {
                      _VideoLevelHudKind.leftBrightness =>
                        _buildLeftBrightnessIndicator(hud.value),
                      _VideoLevelHudKind.rightVolume =>
                        _buildRightVolumeIndicator(hud.value),
                    },
            );
          },
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
                                horizontal: 12,
                                vertical: 8,
                              ),
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
                                              backgroundColor: _osdTextColor(
                                                cs,
                                              ).withValues(alpha: 0.25),
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

  /// 视频左侧锁 / 解锁按钮（TODO-126，前身 TODO-101 左上角常驻解锁层 [_buildLockOverlay]）。
  /// 移到**视频正左边、垂直居中**，像侧边锁：
  ///   - 非沉浸态（[_immersiveLocked] 为 false）：图标显示**开着的锁** [Icons.lock_open_outlined]
  ///     （未锁状态），点击进入沉浸（取代原 topButtonBar 里的锁按钮，TODO-101）。跟随 hover /
  ///     tap 唤起、2s 自动淡出，不再占顶栏。
  ///   - 沉浸态（true）：图标显示**关着的锁** [Icons.lock_outline]（已锁状态），点击退出沉浸。
  ///     这是沉浸态下唯一常驻可见 chrome，作为清晰可发现的默认退出口；其余 chrome 全被抑制。
  ///
  /// 图标是**状态语义**（锁住=闭锁图标），与悬浮字幕锁 / OSD（[_toggleImmersiveLock] 里
  /// 锁定用 [Icons.lock_outline] / 解锁用 [Icons.lock_open_outlined]）/ Android FloatingLyricService
  /// / Windows floating_lyric_window 统一（TODO-153/BUG-216，原先反成「动作提示」语义=锁住却
  /// 显示开锁，与用户预期相反）。tooltip 仍是**动作语义**（锁住时「点击解锁」合理）。
  ///
  /// 可见性走独立的 [_lockButtonVisible]（[_pokeLockButton] 唤回，不被锁 gate）：无操作 2s 后
  /// 淡出（[AnimatedOpacity]），鼠标移动 / 触屏点画面唤回。淡出后 [IgnorePointer] 不拦点击，
  /// 但 Esc / Shift+L 始终可解锁（守卫已钉）——故淡出不会让用户失去退出口。
  ///
  /// 它是 controls Stack 里独立的 [Positioned] 兄弟层（不在 gate `AdaptiveVideoControls`
  /// 的 [IgnorePointer] 之内），故沉浸态下仍可点。可见性走 [ValueNotifier]，全屏路由也响应
  /// （与字幕跳转面板 / OSD 同源，BUG-120）。
  Widget _buildSideLockButton() {
    final ColorScheme cs = _videoChromeColorScheme(context);
    final double iconSize = _videoControlIconSize;
    return Positioned(
      left: 0,
      top: 0,
      bottom: 0,
      child: SafeArea(
        child: Align(
          alignment: Alignment.centerLeft,
          child: ValueListenableBuilder<bool>(
            valueListenable: _immersiveLocked,
            builder: (BuildContext _, bool locked, __) {
              // TODO-388（BUG-294）：可见性 = 自动淡出 [_lockButtonVisible] **或** 鼠标正悬
              // 在按钮上 [_lockButtonHovered]（与屏幕右侧 rail 的 _videoControlsVisible ||
              // _railHovered 判据同款）。hover 期间永远顶住显示，根除「鼠标静止在按钮上、2s
              // 定时器仍把它从光标正下方淡出」的消失 bug。
              return ListenableBuilder(
                listenable: Listenable.merge(<Listenable>[
                  _lockButtonVisible,
                  _lockButtonHovered,
                ]),
                builder: (BuildContext __, ___) {
                  final bool visible =
                      _lockButtonVisible.value || _lockButtonHovered.value;
                  return IgnorePointer(
                    ignoring: !visible,
                    child: AnimatedOpacity(
                      opacity: visible ? 1.0 : 0.0,
                      // TODO-435：与 media_kit 控制条同源的淡入淡出时长 + 曲线，
                      // 让锁按钮与控制条一致地淡入淡出（旧实现 200ms + 默认 linear）。
                      duration: _videoControlsTransitionDuration,
                      curve: Curves.easeInOut,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 8),
                        // hover 保活：鼠标进按钮置 [_lockButtonHovered]=true 顶住显示 +
                        // [_pokeLockButton] 续命淡出定时器；移出置 false 回落到自然淡出。
                        // 与屏幕右侧 rail 的 [_railHoverKeepAlive] 同款（用户要求「改成和屏幕
                        // 右侧按钮一样」）。
                        child: _lockButtonHoverKeepAlive(
                          child: Material(
                            color: cs.surface.withValues(alpha: 0.55),
                            shape: const CircleBorder(),
                            clipBehavior: Clip.antiAlias,
                            child: IconButton(
                              tooltip: locked
                                  ? t.video_immersive_unlock
                                  : t.video_menu_lock,
                              iconSize: iconSize,
                              color: cs.onSurface,
                              // 状态语义（TODO-153/BUG-216）：锁住=闭锁图标、未锁=开锁图标。
                              icon: Icon(
                                locked
                                    ? Icons.lock_outline
                                    : Icons.lock_open_outlined,
                              ),
                              onPressed: _toggleImmersiveLock,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              );
            },
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

  IconData _brightnessIconFor(double brightness) {
    if (brightness < 33) return Icons.brightness_low;
    if (brightness < 67) return Icons.brightness_medium;
    return Icons.brightness_high;
  }
}
