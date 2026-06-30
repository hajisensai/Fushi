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
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/media/drag_drop/drop_classification.dart';
import 'package:hibiki/src/media/drag_drop/hibiki_file_drop_target.dart';
import 'package:hibiki/src/media/video/dandanplay_client.dart';
import 'package:hibiki/src/media/video/video_episode_start_policy.dart';
import 'package:hibiki/src/media/video/m3u8_playlist.dart';
import 'package:hibiki/src/media/video/url_stream_video.dart';
import 'package:hibiki/src/media/video/video_resource_check.dart';
import 'package:hibiki/src/media/video/video_seek_indicator_label.dart';
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
import 'package:hibiki/src/media/video/audio_energy_probe.dart';
import 'package:hibiki/src/media/video/subtitle_auto_align.dart';
import 'package:hibiki/src/media/video/video_chapter_markers.dart';
import 'package:hibiki/src/media/video/video_clip_exporter.dart';
import 'package:hibiki/src/media/video/video_episode_panel.dart';
import 'package:hibiki/src/media/video/video_side_panel.dart';
import 'package:hibiki/src/media/video/video_subtitle_style.dart';
import 'package:hibiki/src/media/video/video_thumbnail_preview_controller.dart';
import 'package:hibiki/src/media/video/video_thumbnail_preview_overlay.dart';
import 'package:hibiki/src/media/video/video_watch_tracker.dart';
import 'package:hibiki/src/pages/implementations/jimaku_subtitle_dialog.dart';
import 'package:hibiki/src/media/video/video_quick_settings_sheet.dart';
import 'package:hibiki/src/media/video/video_sidecar.dart';
import 'package:hibiki/src/media/video/video_subtitle_jump_panel.dart';
import 'package:hibiki/src/media/video/video_subtitle_obscure_mode.dart';
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
import 'package:hibiki/src/utils/misc/card_screenshot_downsampler.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:hibiki/src/platform/screen_brightness_controller.dart';
import 'package:hibiki/src/utils/misc/platform_utils.dart';
import 'package:hibiki/src/utils/misc/hibiki_toast.dart';
import 'package:hibiki/src/utils/misc/show_app_dialog.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';
import 'package:hibiki/src/utils/components/hibiki_icon_button.dart';

part 'video_hibiki/danmaku.part.dart';
part 'video_hibiki/clip_export.part.dart';
part 'video_hibiki/controls_visibility.part.dart';
part 'video_hibiki/episode.part.dart';
part 'video_hibiki/subtitle.part.dart';
part 'video_hibiki/controls_popover.part.dart';
part 'video_hibiki/volume_osd.part.dart';
part 'video_hibiki/chapter.part.dart';
part 'video_hibiki/audio_track.part.dart';
part 'video_hibiki/side_panel.part.dart';
part 'video_hibiki/controls_theme.part.dart';
part 'video_hibiki/speed.part.dart';
part 'video_hibiki/lookup_favorite.part.dart';
part 'video_hibiki/lookup_mining.part.dart';
part 'video_hibiki/fullscreen.part.dart';
part 'video_hibiki/layout.part.dart';

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

/// TODO-680 / BUG-392：把 cue 时间轴上的制卡区间反算回**播放器时间轴**。
///
/// cue 命中走 [effectiveSubtitlePositionMs]：`effective = playerPos - delayMs`，即
/// 文本字幕 cue 的 `startMs`/`endMs` 都是**字幕文件原始坐标**，制卡选句时用减法把
/// 播放位置换算到字幕坐标后再匹配（[resolveMiningCueIndexForPosition]）。但裁句子音频 /
/// 导出封面 GIF 是按**播放器时间轴**对视频文件抽取的——必须做与 [effectiveSubtitlePositionMs]
/// 相反方向的逆变换 `playerPos = subtitleTime + delayMs`，否则 `delayMs != 0` 时裁出来的
/// 音频/封面整体偏移 `delayMs`（裁的是字幕原始窗而非用户实际听到/看到的播放窗）。
///
/// 与 [VideoPlayerController.cueSeekTargetMs]（句子 seek 的逆变换）同一方向、同一真相源，
/// 只是这里作用于制卡裁剪区间。下界 clamp 到 0（播放时间不为负）。
@visibleForTesting
int miningClipTimeMs(int subtitleTimeMs, int delayMs) =>
    (subtitleTimeMs + delayMs).clamp(0, 1 << 30);

/// 判定一个**字位簇**（grapheme cluster）是否属于「拉丁单词字符」：拉丁字母
/// （含 café 的 é、连字号外的重音字母）或 ASCII 数字。用字位簇的首个码点的
/// Unicode `Script=Latin` 属性判定，故 NFC/NFD 的重音字母都按基字母（拉丁）归类。
/// CJK（汉字 / 假名 / 谚文）不是拉丁脚本，恒返回 false → 逐字查词行为不变。
bool _isLatinWordGrapheme(String grapheme) {
  if (grapheme.isEmpty) return false;
  return _kLatinWordCharRegExp.hasMatch(grapheme);
}

final RegExp _kLatinWordCharRegExp =
    RegExp(r'^[\p{Script=Latin}0-9]', unicode: true);

/// 点字幕第 [graphemeIndex] 个字位起的查词词面（TODO-916 症状③）。
///
/// 默认（CJK / 日文）行为：从被点字位一直取到**句尾**，逐字查词（与历史一致，
/// 不能套「延伸到词尾」——中日文按字 / 词查）。
///
/// 仅当**被点字位本身是拉丁单词字符**时，回退到该拉丁单词的**词首**并延伸到
/// **词尾**，返回整个单词。这样点 "hello" 的任意字母（含 'e' / 'o'）都返回
/// "hello"，而不是旧 `skip(index)` 的 "ello" 查不到（拉丁词非逐字、点中间字母
/// 取不到整词 → 查不到）。空格 / 标点 / 连字号 / CJK 都是词边界。
@visibleForTesting
String subtitleLookupTerm(String sentence, int graphemeIndex) {
  final List<String> graphemes = sentence.characters.toList();
  if (graphemeIndex < 0 || graphemeIndex >= graphemes.length) return '';
  // 非拉丁（CJK / 标点 / 空白）：维持历史「取到句尾逐字查」语义。
  if (!_isLatinWordGrapheme(graphemes[graphemeIndex])) {
    return graphemes.skip(graphemeIndex).join();
  }
  int start = graphemeIndex;
  while (start > 0 && _isLatinWordGrapheme(graphemes[start - 1])) {
    start--;
  }
  int end = graphemeIndex; // inclusive index of last word grapheme
  while (
      end + 1 < graphemes.length && _isLatinWordGrapheme(graphemes[end + 1])) {
    end++;
  }
  return graphemes.sublist(start, end + 1).join();
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

/// TODO-897：缺失资源对话框的用户选择。
enum _MissingResourceChoice { reimport, delete, cancel }

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

  /// 点查词浮层外的 dismiss barrier 命中了字幕字符时，是否应「换词」（对该字符重新查词、
  /// 替换可见浮层）而非「逐层关顶层」（TODO-758 / BUG-410，纯函数供单测）。
  ///
  /// 仅在**非嵌套**（[topVisibleIndex] <= 0：只有顶层可见，或仅剩隐藏热槽返回 -1）且确实
  /// 命中字幕字符（[hitSubtitle]）时才换词——单层查词点同句另一个字符切换查词是合理交互。
  /// 嵌套态（[topVisibleIndex] > 0，存在父层）下底部字幕仍清晰渲染、其字符矩形持续绑定，
  /// 用户点第 2+ 个窗外面常落在字幕文字上 → 若仍换词会把整栈替换掉，顶层窗没关而是被替换
  /// （位置相关、间歇）。故嵌套态点外一律返回 false（逐层关一层，与 reader dismissTopPopup
  /// 同语义）。
  @visibleForTesting
  static bool shouldSwitchWordOnBarrierTap({
    required int topVisibleIndex,
    required bool hitSubtitle,
  }) =>
      topVisibleIndex <= 0 && hitSubtitle;

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
  const _VideoOsdMessage({
    required this.message,
    this.icon,
    this.progress,
    this.prominent = false,
  });

  final String message;
  final IconData? icon;
  final double? progress;

  /// TODO-971：突出变体（制卡成功用）。普通 OSD 沿用音量/亮度同款左上角小角标，
  /// 太轻易被忽略；制卡成功这类用户主动操作的确认改成居中、更大字号、停留更久的
  /// 卡片，区别于被动的音量小角标。
  final bool prominent;
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
  subtitleSources,
  secondarySubtitleSources,
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
  ///
  /// TODO-740：原值 24 是叠加在系统手势安全区（[_videoBottomSystemInset]）之上的固定
  /// 额外留白，偏大，控制底栏离屏幕底端太远（YouTube/B 站只让系统手势安全区不加大基线）。
  /// 降到 8（极小呼吸距离、非 0 保守）：系统手势安全区仍由 [_videoBottomSystemInset]
  /// 独立兜底（不回归 BUG-184 手势条吞进度条），字幕避让走 [_subtitleControlsBottomReserve]
  /// 把本基线作为加总项之一，进度条下移字幕同步下移、相对关系不变（不遮挡）。
  static const double _videoBottomChromeBaseline = 8;

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
  /// 系统边缘手势区。TODO-971：原 52×缩放 的透明命中带过大，吞掉轨道上方一大片
  /// 区域的底部点击；收窄到 40（仍高于 media_kit 默认 36，保留易命中），缩短透明
  /// 命中带又不丢可命中性。
  static const double _videoSeekBarContainerHeightBase = 40;

  /// 移动控制条进度条拖动滑块尺寸基线（TODO-157/BUG-218）。media_kit 默认 12.8；
  /// 抬高让滑块更易对准。随界面缩放。
  static const double _videoSeekBarThumbSizeBase = 18;

  /// 移动控制条进度条轨道高度基线（TODO-157/BUG-218）。media_kit 默认 2.4；抬高让
  /// 轨道更醒目、更易滑。随界面缩放。
  static const double _videoSeekBarTrackHeightBase = 5;

  /// 字幕避让骑在可见进度条**轨道上缘**之上的呼吸间距基线（TODO-568）。media_kit 的
  /// 可见进度条轨道贴在触摸热区容器底缘（`bottomCenter`），轨道上方是大片透明命中区；
  /// reserve 抬到「轨道上缘 + 本间距」让字幕底缘恰骑进度条上方一点点（不被遮、也不像
  /// 旧版用整段热区高那样顶飞 ~47×缩放 的空白）。随界面缩放。
  static const double _videoSubtitleSeekBarBreathingBase = 8;
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

  /// 字幕避让骑在进度条轨道上缘之上的呼吸间距，随界面大小缩放（TODO-568）。
  double get _videoSubtitleSeekBarBreathingGap =>
      _videoSubtitleSeekBarBreathingBase * _videoUiScale;

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

  /// 合成 hover 派发去重旗（BUG-425）。[_pokeControlsVisible] 经
  /// [GestureBinding.handlePointerEvent] 派发合成 [PointerHoverEvent] 唤醒控制条，但派发
  /// 会同步进入 Flutter `MouseTracker.updateWithEvent` → 写 `_mouseStates[device]`。当
  /// poke 由 **MouseRegion 自己的 onEnter/onHover 回调**触发（rail / 锁按钮 keep-alive、
  /// 字幕盒 hover）时，这些回调本就跑在 `MouseTracker.updateAllDevices` 遍历 `_mouseStates`
  /// 的 `_deviceUpdatePhase` 内 → 合成派发在迭代期增删该 Map → release 构建抛
  /// `Concurrent modification during iteration: _Map len:2`（debug 是 `_debugDuringDeviceUpdate`
  /// 断言）。修复：合成派发恒经 [scheduleMicrotask] 延迟到当前调用栈（含 MouseTracker 迭代）
  /// 解开后再执行，绝不重入；此旗把同一微任务窗口内的多次 poke 折叠成一次派发（dedup）。
  bool _pokeDispatchScheduled = false;

  /// 待派发的合成 hover 事件（BUG-425）。[_pokeControlsVisible] 在命中区几何有效时同步构造，
  /// [_dispatchPokeHover] 在微任务里取出派发。每次 poke 刷新为最新抖动位置，连按时去重为单
  /// 次派发但派发的仍是最新位置（保 TODO-148/BUG-215 的去重续命）。
  PointerHoverEvent? _pendingPokeHover;
  static const double _volumeStep = 5.0;

  /// media_kit 移动控制条竖滑（左=亮度 / 右=音量）的灵敏度（TODO-172/BUG-230）。
  /// media_kit 公式是 `value -= delta.dy / verticalGestureSensitivity`——值越大越
  /// 不敏感。其默认 100（满量程仅需约 100px 竖向拖动，太敏感，轻轻一划就拉满 / 归零）。
  /// 抬到 320（灵敏度降到约 1/3，满量程约需 320px 拖动），符合用户「太灵敏」反馈。
  /// 仅移动端有此竖滑手势，传给 [_mobileControlsTheme]；桌面 [_desktopControlsTheme]
  /// 无此手势、不设此参数（诚实降级）。
  static const double _videoVerticalGestureSensitivity = 320.0;

  /// TODO-916 症状①：media_kit 移动控制条横滑 seek 的灵敏度（仅移动端有此手势，
  /// 桌面走鼠标拖进度条 + 键盘 seek 键 085/090，不接横滑）。media_kit 公式是
  /// `seconds = -(diff.dx * duration / horizontalGestureSensitivity)`——按视频时长
  /// 比例换算（不是固定 ±N 秒），值越大越不敏感。沿用 fork 默认 1000：满 1000 逻辑
  /// 像素横拖 = 整段时长，手机屏宽 ~400dp 拖满全屏宽约 = 时长的 40%，与主流播放器
  /// （bilibili/YouTube）的比例制横拖手感一致。HUD 文本格式见
  /// [VideoSeekIndicatorLabel]。
  static const double _videoHorizontalGestureSensitivity = 1000.0;

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

  /// 进度条 hover 缩略图预览调度器（TODO-669，方案 A）。仅桌面本地文件视频时创建；
  /// 移动端 / 远端流为 null（不取帧，仅经 [_onSeekBarHover] 走 timestampOnly）。
  /// 换集（视频路径变）时重建（绑新离屏取帧器），页面 dispose 时一并销毁。
  VideoThumbnailPreviewController? _thumbnailPreview;
  OffscreenVideoFrameGrabber? _thumbnailGrabber;
  VideoPlayerController? _chapterListenerController;
  VoidCallback? _chapterListener;
  bool _failed = false;

  /// TODO-897：本地视频资源缺失（被移动 / 删除 / 所在盘未挂载）。置位后
  /// [_buildScaffold] 在转圈判据之前短路成「资源缺失」态，不再无限转圈。
  bool _missingResource = false;

  /// 缺失态对应的 video book 行（用于复用 [_confirmMissingResourceDelete] 的删除
  /// 序列：删条目要 coverPath / subtitleSource / videoPath 三参数）。仅本地路径
  /// 缺失时置；远端 / 流不进缺失态故恒 null。
  VideoBookRow? _missingRow;

  /// 本次 _init 加载到的 video book 行（单视频 / 播放列表共用，远端为 null）。
  /// 缺失态删除序列复用其 coverPath / subtitleSource / videoPath。
  VideoBookRow? _bookRow;
  String? _title;

  /// 播放列表（系列）名（TODO-761，方案 B）。仅当本视频是播放列表（多集，
  /// [_isPlaylist] 为真）时记 [VideoBookRow.title]（系列名）；单视频 / 远端视频
  /// 保持 null。制卡时 [DictionaryPageMixin] 的 `documentTitle` 据此拼成
  /// 「系列名 - 剧集名」，老 Anki 卡片模板的 `{document-title}` 自动带上系列名，
  /// 无需改模板。**只用于制卡 documentTitle**，不影响播放器标题栏（仍是剧集名 [_title]）。
  String? _playlistTitle;
  List<VideoDanmakuItem> _danmakuItems = const <VideoDanmakuItem>[];
  int _danmakuLoadSeq = 0;

  /// 库内 part 文件（extension）改状态的入口：扩展不被视作 State 子类实例成员，
  /// 直接调 @protected 的 setState 会报 invalid_use_of_protected_member。由本 State
  /// 子类持有的这个转发器统一承接，零行为变化（仅转发）。
  void _rebuild(VoidCallback fn) => setState(fn);

  /// 同 [_rebuild]：库内 part（extension）调 [DictionaryPageMixin] 的 @protected
  /// [recordMined] 会报 invalid_use_of_protected_member（扩展不算 State 子类实例
  /// 成员）。由本 State 子类持有的这个转发器统一承接，零行为变化（仅转发）。
  Future<void> _recordMinedForVideo() => recordMined();

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

  /// 剧集列表 push-aside 侧栏可见性（TODO-638）。剧集列表此前是
  /// `showModalBottomSheet`（底部弹层），与其它侧栏（字幕列表 push-aside、设置 /
  /// 倍速等 overlay）显示风格不一致。改成与字幕列表同款的 push-aside 侧栏后，可见性
  /// 同样用 [ValueNotifier]（全屏路由也响应，与 [_subtitleListVisible] 同源，BUG-120）。
  /// 与字幕列表互斥：同一时刻右栏只占其一，开一个先关另一个（避免两侧栏分占右栏）。
  final ValueNotifier<bool> _episodeListVisible = ValueNotifier<bool>(false);
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

  /// 自动连播倒计时剩余秒数（TODO-639）。null=没有倒计时；非空时画面右下角显示
  /// 「N 秒后播放下一集 · 取消」可点 overlay，归零后进下一集。与 [_osdNotifier] 分开：
  /// 这个 overlay 必须可点（取消按钮），不能套 [IgnorePointer]。
  final ValueNotifier<int?> _autoAdvanceCountdownNotifier =
      ValueNotifier<int?>(null);

  /// 自动连播倒计时定时器（每秒 -1，归零触发进下一集）。
  Timer? _autoAdvanceCountdownTimer;

  /// 倒计时进入的目标集索引（[_cancelAutoAdvanceCountdown] / 归零推进时用）。
  int? _autoAdvanceCountdownTarget;

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

  /// 系统栏（状态/导航/手势栏）**当前是否真正可见**（TODO-658/BUG-383）。视频页进入即
  /// [SystemUiMode.immersiveSticky] 隐藏系统栏，故默认 `false`。由 [SystemChrome.
  /// setSystemUIChangeCallback] 在系统栏可见性变化时回写（仅移动端注册）。
  ///
  /// 这是 [_videoBottomSystemInset] 是否计入底部系统 inset 的**唯一权威开关**：
  /// `MediaQuery.viewPadding.bottom` / `padding.bottom` 在 targetSdk 35 强制 edge-to-edge
  /// + **手势导航**下，即便 immersiveSticky 已隐藏导航栏，仍上报手势条物理高度（引擎
  /// `getInsets(systemBars())` 在手势导航下照单全收，见 Flutter #170640，且 padding 与
  /// viewPadding 在无键盘时同源 = 换字段不解决问题）→ 旧实现把这段恒非零的 inset 永久
  /// 叠进进度条/字幕/刻度带几何，进度条被顶高到屏幕中上部（BUG-370 当初只重申
  /// immersiveSticky 是治标，inset 仍非零）。改读系统栏**真实可见性**：隐栏（沉浸态，
  /// 常态）→ inset=0，进度条回到惯例 `基线+按钮条+间距`；导航栏真显示（三键导航 / 手势条
  /// 临时唤出）→ 计入 inset 避开它（保 BUG-184「导航栏可见时进度条上移避让」本意）。
  bool _systemBarsVisible = false;

  /// 注册系统栏可见性回调（仅移动端）。immersiveSticky 隐栏 → `false`；上划临时唤回 /
  /// 三键导航显示 → `true`。回写 [_systemBarsVisible] 并 `setState` 重建进度条/字幕/刻度
  /// 几何（[_mobileControlsTheme] / [_subtitleControlsBottomReserve] / 章节刻度带均在
  /// build 期读 [_videoBottomSystemInset]）。桌面无系统栏语义，不注册。
  void _registerSystemBarsVisibilityCallback() {
    if (!isMobilePlatform) return;
    SystemChrome.setSystemUIChangeCallback(
      (bool systemOverlaysAreVisible) async {
        if (!mounted) return;
        if (_systemBarsVisible == systemOverlaysAreVisible) return;
        setState(() => _systemBarsVisible = systemOverlaysAreVisible);
      },
    );
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

  /// TODO-382「+句」可撤销（视频车道）：弹窗点「清空已加句子」清掉本会话累积的全部草稿
  /// 句，回传清空后的句数（恒 0）。不动字幕列表「选入词卡」的 cue 选择集（两套独立机制）。
  @override
  Future<int> Function()? get onClearSentenceDraftToDraft =>
      _clearSentenceDraft;

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

  /// 当前选中的字幕源持久化值（外挂路径 / `embedded:<n>` / `off:`=用户显式关闭哨兵
  /// （[SubtitleSource.offSentinel]，TODO-818） / null=无偏好或远端清字幕）；用于字幕
  /// 源菜单高亮当前项。
  String? _currentSubtitleSource;

  /// 当前选中的副字幕源持久化值（TODO-857 视频双字幕 Path A）：与
  /// [_currentSubtitleSource] 同款四态编码（外挂路径 / `embedded:<n>` / `off:` /
  /// null）。副字幕由 libmpv `secondary-sid` 自渲染（不进 cue 流，不可查词），与主
  /// 字幕独立；首版仅支持内嵌轨。用于副字幕源菜单高亮当前项。
  String? _currentSecondarySubtitleSource;

  /// 当前选中的音轨 id（libmpv `AudioTrack.id`）；null=未选过跟随默认。
  /// 多集换集时复用同一值（用户选了日语音轨，每集都用日语）。
  String? _currentAudioTrackId;

  bool _clipExportMarking = false;
  bool _clipExporting = false;
  int? _clipExportStartMs;
  String? _clipExportStartPath;
  int? _clipExportStartAudioStreamIndex;
  // 标记起点时快照的真实音轨条数，作 ffmpeg `-map 0:a:N` 的下标上界（BUG-345）。
  int? _clipExportStartAudioStreamCount;
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
    _popup = DictionaryPopupController(
      lowMemory: false,
      onLookupStackDepthChanged: recordLookupStackDepth,
    );
    _subtitleListVisible.value = widget.initialSubtitleListVisible;
    // TODO-364 单一真相源：字幕避让可见性恒由 media_kit 真实可见性
    // （[_mediaKitControlsVisible]）+ 三个门控派生。订阅这四个输入，任一变化即重派生
    // [_videoControlsVisible]，杜绝旧镜像与真实控制条相位反。
    _mediaKitControlsVisible.addListener(_applyControlsVisibilityFromMediaKit);
    _immersiveLocked.addListener(_applyControlsVisibilityFromMediaKit);
    _videoSidePanel.addListener(_applyControlsVisibilityFromMediaKit);
    _videoControlPopover.addListener(_applyControlsVisibilityFromMediaKit);
    _subtitleListVisible.addListener(_applyControlsVisibilityFromMediaKit);
    _episodeListVisible.addListener(_applyControlsVisibilityFromMediaKit);
    _videoControlEditMode.addListener(_applyControlsVisibilityFromMediaKit);
    // TODO-973：手柄沉浸（全局单一真相源 AppModel.gamepadImmersiveActive）也作为
    // 控制条压制门控之一。但**不能在 initState 订阅**——读 appModel 会强制构造
    // AppModel（错误态 smoke 用未初始化 AppModel，platformServicesProvider 未 override
    // 会抛）。与上面 lowMemory 同范式：留到成功路径 [_seedWarmPopup]（缺书/错误态无
    // 视频无控制条，本就无需此门控）再 attach，dispose 按 [_gamepadImmersiveListenerAttached]
    // 守卫摘除。
    // TODO-611：侧栏面板锁定不持久化。面板一关闭就把锁复位为 false，下次重开默认未锁
    // ——锁生命周期绑定可见性，关闭路径无需逐个复位。
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
    // TODO-658/BUG-383: 监听系统栏真实可见性，喂 [_videoBottomSystemInset] 的门控
    // （隐栏归零、可见才避让），根治手势导航下进度条被恒非零 viewPadding 顶高。
    _registerSystemBarsVisibilityCallback();
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
    _bookRow = row;

    // 记录持久化的字幕源（菜单高亮当前项用）+ 音轨偏好（换集复用）+ 音画延迟
    // （跨重启保留）+ 播放倍速（per-book 偏好，速度记忆）。
    _currentSubtitleSource = row.subtitleSource;
    _currentSecondarySubtitleSource = row.secondarySubtitleSource;
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
      // TODO-761（方案 B）：确认是播放列表（多集）后记系列名（[VideoBookRow.title]），
      // 制卡 documentTitle 据此拼「系列名 - 剧集名」。单视频 / 远端不进此分支，保持 null。
      _playlistTitle = row.title;
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
    _currentSubtitleSource = null;
    _currentSecondarySubtitleSource = null;
    _currentAudioTrackId = null;
    _delayMs = 0;
    _playbackSpeed = _readPersistedSpeed();
    _playbackVolume = _readPersistedVolume();
    _subtitleStyle = VideoSubtitleStyle.decode(appModel.videoSubtitleStyle);
    _asbConfig = VideoAsbplayerConfig.decode(appModel.videoAsbplayerConfig);
    _controlLayoutNotifier.value = appModel.videoControlLayout;

    // TODO-885: 远端播放列表——把 host 下发的 episodes 映射成 _episodes（path 留空，
    // 切集靠 episodeIndex 向 host 重新建流），复用既有 _isPlaylist / 剧集面板 / 上下集。
    final int startIndex = info.isPlaylist
        ? (widget.initialEpisodeIndex ?? info.currentEpisode)
            .clamp(0, info.episodes.length - 1)
        : 0;
    if (info.isPlaylist) {
      _episodes = <PlaylistEntry>[
        for (final RemoteVideoEpisode ep in info.episodes)
          PlaylistEntry(title: ep.title, path: ''),
      ];
    }
    await _loadRemoteEpisode(
      startIndex,
      startIntent: EpisodeStartIntent.initialOpen,
      // 起播集恢复其按集断点（host 真相 vs 本地 prefs 取较新者）。
      initialPositionMsOverride:
          _resolveRemoteInitialPositionMs(info, startIndex),
    );
  }

  /// 载入远端第 [index] 集（TODO-885）：向 host 按 episodeIndex 换流式 url + 字幕，
  /// 复用 [_applyLoad]。单视频 [index]==0。慢路径（下字幕）期间若已切走则放弃应用。
  Future<void> _loadRemoteEpisode(
    int index, {
    required EpisodeStartIntent startIntent,
    int? initialPositionMsOverride,
  }) async {
    final RemoteVideoInfo info = widget.remoteInfo!;
    final RemoteVideoClient client = widget.remoteClient!;
    final int seq = ++_episodeLoadSeq;
    final int initialPositionMs = initialPositionMsOverride ??
        _readPersistedRemotePositionForEpisode(index);
    try {
      final RemoteVideoStreamUrls urls = await client.remoteVideoStreamUrls(
        info.id,
        episodeIndex: index,
      );
      _remoteEmbeddedSubtitleTracks = urls.embeddedSubtitleTracks;
      String? externalSub;
      List<AudioCue> cues = const <AudioCue>[];
      if (urls.subtitleUrl != null) {
        final Directory temp = await getTemporaryDirectory();
        final File subtitle = File(
          p.join(
            temp.path,
            _remoteSubtitleTempFileName(
              '${info.id}_ep$index',
              urls.subtitleFileName,
            ),
          ),
        );
        await client.getRemoteVideoSubtitle(
          info.id,
          subtitle,
          episodeIndex: index,
        );
        externalSub = subtitle.path;
        _remoteSubtitlePath = subtitle.path;
        cues = await _loadExternalSubtitleCues(subtitle.path, info.id);
      }
      if (seq != _episodeLoadSeq || !mounted) return;
      _currentEpisode = index;
      await _applyLoad(
        videoPath: null,
        mediaUri: urls.streamUrl,
        cues: cues,
        title: info.title,
        initialPositionMs: initialPositionMs,
        startIntent: startIntent,
        externalSubtitlePath: externalSub,
      );
    } catch (e, stack) {
      debugPrint(
        '[VideoHibikiPage] remote episode $index load failed: $e\n$stack',
      );
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

  /// 读 per-book/per-episode 远端断点位置（无则 0，从头）。
  ///
  /// 在线远端视频（[_isRemote]）在 client 本地 DB 没有 VideoBooks 行（书架不收录
  /// 远端在线视频，[home_video_page._openRemote] 直接 push 播放页不 upsert），因此本地
  /// 视频走 `VideoBooks.lastPositionMs` 的进度链路对远端不可用。沿用 speed/volume 同款
  /// per-book prefs 范式（落 Drift `preferences` 表，跨重启保留），key 用稳定的
  /// `widget.bookUid`（= 远端 `RemoteVideoInfo.id`，每次列举不变）。TODO-885：
  /// [episodeIndex]>0 用按集 key（`#ep<index>` 后缀），0 回退整书 key（向后兼容单视频 /
  /// 旧 TODO-559 prefs）。
  int _readPersistedRemotePositionForEpisode(int episodeIndex) {
    final Object? raw = appModel.prefsRepo.getPref(
        videoRemotePositionEpisodePrefKey(widget.bookUid, episodeIndex),
        defaultValue: 0);
    final int v =
        raw is num ? raw.toInt() : int.tryParse(raw?.toString() ?? '') ?? 0;
    return v < 0 ? 0 : v;
  }

  /// 读 per-book/per-episode 远端断点的本地「最后更新时间」（无则 0）。TODO-653 冲突解决用。
  int _readPersistedRemotePositionAtForEpisode(int episodeIndex) {
    final Object? raw = appModel.prefsRepo.getPref(
        videoRemotePositionEpisodeAtPrefKey(widget.bookUid, episodeIndex),
        defaultValue: 0);
    final int v =
        raw is num ? raw.toInt() : int.tryParse(raw?.toString() ?? '') ?? 0;
    return v < 0 ? 0 : v;
  }

  /// 远端视频开播位置（TODO-653/885）：在 host 真相（[info] 随清单带回的整书 positionMs，
  /// 仅对起播集 [episodeIndex]==currentEpisode 有意义）与本地按集 prefs 之间「取较新时间
  /// 戳」（[resolveVideoPositionSync]）。host 进度新于本地时跨设备恢复；本地新于 host 时
  /// 不被旧 host 回退。非起播集只用本地按集 prefs（host 清单只带整书/当前集进度）。
  int _resolveRemoteInitialPositionMs(RemoteVideoInfo info, int episodeIndex) {
    // host 的 info.positionMs 是整书/当前集进度，只对 host 的 currentEpisode 那集叠加；
    // 其它集 host 没带进度 → 退本地按集 prefs。
    final bool hostProgressApplies =
        !info.isPlaylist || episodeIndex == info.currentEpisode;
    final ({int positionMs, int updatedAtMs}) winner = resolveVideoPositionSync(
      localPositionMs: _readPersistedRemotePositionForEpisode(episodeIndex),
      localUpdatedAtMs: _readPersistedRemotePositionAtForEpisode(episodeIndex),
      remotePositionMs: hostProgressApplies ? info.positionMs : 0,
      remoteUpdatedAtMs: hostProgressApplies ? info.positionUpdatedAtMs : 0,
    );
    return winner.positionMs < 0 ? 0 : winner.positionMs;
  }

  /// 远端视频断点位置持久化（controller 每秒至多一次回调 / flush / dispose）。
  ///
  /// 与本地 [_persistPosition] 对应：远端无播放列表（[_episodes] 恒空）也无 DB 行，
  /// 按稳定 bookUid 落 prefs（离线时仍可恢复）。controller 用 `widget.bookUid` 调
  /// [onPositionWrite]，故回调 [uid] 即构造 [_remotePositionPrefKey] 用的同一 bookUid。
  ///
  /// TODO-653：同时把进度 best-effort 上报到 host（跨设备同步真相源）。上报失败
  /// （离线 / 旧 host 无端点）只记日志不抛——本地 prefs 已写，不阻塞播放也不丢进度。
  Future<void> _persistRemotePosition(String uid, int posMs) async {
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    final int clamped = posMs < 0 ? 0 : posMs;
    // TODO-885: 按当前集 key 落库 + 上报（_currentEpisode 是状态真相；单视频恒 0 回退
    // 整书 key，与旧 prefs 兼容）。
    final int episodeIndex = _currentEpisode;
    await appModel.prefsRepo
        .setPref(videoRemotePositionEpisodePrefKey(uid, episodeIndex), clamped);
    await appModel.prefsRepo
        .setPref(videoRemotePositionEpisodeAtPrefKey(uid, episodeIndex), nowMs);
    final RemoteVideoClient? client = widget.remoteClient;
    if (client == null) return;
    try {
      await client.putRemoteVideoPosition(
        uid,
        clamped,
        nowMs,
        episodeIndex: episodeIndex,
      );
    } catch (e) {
      debugPrint('[VideoHibikiPage] remote position upload failed: $e');
    }
  }

  /// 载入单视频（无播放列表）：优先用 DB 已存 cue；否则先尝试恢复用户上次选的
  /// 字幕源（[row.subtitleSource] 跨重启保留），无匹配再退默认 sidecar 探测。
  Future<void> _loadSingle(VideoBookRow row) async {
    List<AudioCue> cues = await widget.repo.loadCues(widget.bookUid);
    String? externalSub = row.subtitleSource;
    int? graphicStreamIndex;

    // TODO-818：用户显式关闭字幕。哨幕短路两个自动重选向量（sidecar 探测 + 内嵌轨
    // 抽取），externalSub 保持哨兵原样传给 _applyLoad，恢复后仍是关闭态。
    if (SubtitleSource.isOff(row.subtitleSource)) {
      cues = const <AudioCue>[];
    } else if (cues.isEmpty) {
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

    // TODO-818：用户显式关闭字幕（哨兵存在 video book 的 subtitleSource 上，作用域与
    // 选具体源一致——按整张 video book 持久化，各集共享）。哨兵短路两个自动重选向量
    // （sidecar 探测 + 内嵌轨抽取），externalSub 保持哨兵传给 _applyLoad 维持关闭态。
    if (SubtitleSource.isOff(subtitleSource)) {
      externalSub = subtitleSource;
    } else {
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

      // ② 无偏好 / 无匹配：退默认 sidecar 探测。图形轨恢复时 cues 虽空但
      // externalSub 已置（embedded:<n>），不能让 sidecar 覆盖掉画面字幕选择（BUG-122）。
      if (cues.isEmpty && externalSub == null) {
        final ({String path, List<AudioCue> cues})? sidecar =
            await _detectSidecar(episode.path, widget.bookUid);
        if (sidecar != null) {
          cues = sidecar.cues;
          externalSub = sidecar.path;
        }
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

  /// 共享 load 装配：复用或新建 controller，载入视频 + cue，挂位置持久化回调。
  /// 单 URL 流（TODO-850 阶段①）的防盗链 header（Referer/User-Agent 等）。仅当远端
  /// client 是 [UrlStreamVideoClient] 时取其 [UrlStreamVideoClient.httpHeaderFields]；
  /// 其它远端/本地播放恒返回空 map（[applyHttpHeaderFieldsToPlayer] 据此 no-op，
  /// 既有播放路径零影响）。
  Map<String, String> get _streamHttpHeaderFields {
    final RemoteVideoClient? client = widget.remoteClient;
    if (client is UrlStreamVideoClient) return client.httpHeaderFields;
    return const <String, String>{};
  }

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
    // TODO-897：本地视频资源缺失（被移动 / 删除 / 所在盘未挂载）前置短路。
    // libmpv 对失效本地路径静默失败（不抛、不回调），下面的 try/catch 与页级
    // spinner 都救不了→media_kit 自带缓冲圈无限转。故在 controller.load 之前判定：
    // 缺失则不 load，置缺失态（[_buildScaffold] 在转圈判据前短路）+ 弹中性对话框。
    // 远端 / 流（videoPath==null 或 http(s) URL）天然豁免（见 video_resource_check）。
    if (await isLocalVideoResourceMissing(videoPath)) {
      debugPrint('[VideoHibikiPage] local video resource missing: $videoPath');
      ErrorLogService.instance.log(
        'VideoHibiki.diag',
        '[VIDEO-DIAG] local video resource missing: $videoPath',
      );
      if (!mounted) return;
      setState(() {
        _failed = false;
        _missingResource = true;
        _missingRow = _bookRow;
        _title = title;
        _titleNotifier.value = title;
      });
      await _promptMissingResource(title);
      return;
    }
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
    // TODO-984：把控制器诊断行接到错误日志服务（用户可在「错误日志」页查看 / 上传）。
    // 现场定位 Android「闪烁 + 空白无画面」（realme 8 / Android 11）——其他 app 播同文件
    // 正常，疑点在 hwdec / 纹理 surface / 解码出帧。诊断行带 `[VIDEO-DIAG]` 前缀便于筛选。
    controller.onDiagLog = (String message) {
      ErrorLogService.instance.log('VideoHibiki.diag', message);
    };
    ErrorLogService.instance.log(
      'VideoHibiki.diag',
      '[VIDEO-DIAG] _applyLoad: title=$title videoPath=$videoPath '
          'mediaUri=$mediaUri cues=${cues.length} '
          'initialPositionMs=$initialPositionMs '
          'externalSubtitlePath=$externalSubtitlePath '
          'renderGraphicStreamIndex=$renderGraphicStreamIndex '
          'fitMode=$_videoFitMode platform=${Platform.operatingSystem}',
    );
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
        // TODO-818：externalSubtitlePath 为「显式关闭」哨兵时，禁止 controller 后台
        // 自动抽取内嵌文本轨成 cue（否则关了字幕重启又被内嵌轨自动选上）。
        subtitleExplicitlyOff: SubtitleSource.isOff(externalSubtitlePath),
        renderGraphicStreamIndex: renderGraphicStreamIndex,
        shaderPaths: shaderPaths,
        mpvConfig: mpvConfig,
        httpHeaderFields: _streamHttpHeaderFields,
        autoPlay: true,
        onEmbeddedSubtitleAutoLoad: _handleEmbeddedSubtitleAutoLoad,
      );
    } catch (e, stack) {
      debugPrint('[VideoHibikiPage] video load failed: $e\n$stack');
      ErrorLogService.instance
          .log('VideoHibiki.diag', '[VIDEO-DIAG] controller.load() threw: $e');
      ErrorLogService.instance.log('VideoHibiki.load', e, stack);
      if (_controller == null) controller.dispose();
      if (mounted) setState(() => _failed = true);
      return;
    }
    // TODO-984：load() 正常返回（未抛）——记一行让日志能区分「load 抛异常失败」与
    // 「load 返回了但画面仍空白」（后者疑点在解码出帧 / 纹理，看控制器 [VIDEO-DIAG] 行）。
    ErrorLogService.instance.log(
      'VideoHibiki.diag',
      '[VIDEO-DIAG] controller.load() returned ok: '
          'durationMs=${controller.durationMs} '
          'videoWidth=${controller.videoWidth} '
          'videoHeight=${controller.videoHeight} '
          'videoController=${controller.videoController != null}',
    );
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
      _missingResource = false;
      _missingRow = null;
      _currentVideoPath = videoPath;
      // externalSubtitlePath 即持久化值：外挂路径 / `embedded:<n>` / `off:`（显式关闭
      // 哨兵，TODO-818）都按原样写进 _currentSubtitleSource 供菜单高亮。内嵌自动加载
      // （externalSubtitlePath==null）时当前选中由 _currentSubtitleSource 保留（菜单
      // 切换时再写）。
      _currentSubtitleSource = externalSubtitlePath ?? _currentSubtitleSource;
    });
    _syncControllerChapterAvailability(controller);
    // TODO-669：建立 / 重置进度条 hover 缩略图预览（桌面本地文件实时取帧；远端流 /
    // 移动端降级）。在 _currentVideoPath 更新后调，按新路径绑离屏取帧器。
    _setupThumbnailPreview(videoPath);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refocusVideo();
    });
    // BUG-370：视频就绪后重申沉浸隐藏系统栏（移动端）。沉浸模式在 initState 只申一次，
    // 而**远端视频**要先 await 网络流地址 + 下字幕才 load，controller 就绪得晚——若
    // immersiveSticky 在等待期被系统 / 用户触屏临时唤回导航栏，首个带进度条的帧会读到
    // 非零 MediaQuery.viewPadding.bottom（[_videoBottomSystemInset]），把进度条 / 字幕
    // 整体抬高（用户报「远端进度条偏高、字幕被顶高显大」；本地 load 快、过了这个窗口故
    // 正常）。在 controller 就绪即重隐导航栏，让 inset 回零、几何归位。对称惠及本地远端、
    // 不碰 BUG-184 的 inset 几何（导航栏真可见时进度条仍正确避让）。桌面 no-op。
    unawaited(_applyVideoImmersiveMode());
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
    // TODO-857：恢复用户选过的副字幕轨（libmpv secondary-sid 自渲染）。与主
    // 字幕独立，仅内嵌轨；其内部 _waitUntilSubtitleTracksReady 等轨就绪。
    unawaited(_restoreSecondarySubtitle(controller));
  }

  /// TODO-897：本地视频资源缺失时弹中性对话框（资源位置变化 → 重新导入 / 删除条目 /
  /// 取消）。措辞中性、不诱导直删；删除走二次确认 [_confirmMissingResourceDelete]。
  ///
  /// 误删缓解（Never-break-userspace 红线）：外接盘 / 网络盘未挂载时 `exists()` 也
  /// 返 false（误报缺失）。故①文案中性（「位置可能变化或磁盘未连接」），不预设是
  /// 「文件被删」；②「取消」是默认 / 主动作（停在缺失态，可重连磁盘后退页重进），
  /// 「删除」是次要、且本身再过一道 [video_delete_confirm] 二次确认；③播放列表
  /// （多集）单集缺失不提供删除（删除粒度只有整张 video book，删一整部太重），
  /// 只给「重新导入 / 取消」（M1，见计划待定夺 #3）。
  Future<void> _promptMissingResource(String title) async {
    final NavigatorState nav = Navigator.of(context);
    final VideoBookRow? row = _missingRow;
    // 仅单视频条目（非播放列表、非远端）提供「删除条目」；缺 row 也不提供删除。
    final bool canDelete = row != null && !_isPlaylist && !_isRemote;
    final _MissingResourceChoice? choice =
        await showAppDialog<_MissingResourceChoice>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(t.video_resource_missing_title),
        content: Text(t.video_resource_missing_message(title: title)),
        actions: <Widget>[
          // 取消 = 默认 / 主动作：不删任何东西，停在缺失态。
          TextButton(
            onPressed: () => Navigator.pop(ctx, _MissingResourceChoice.cancel),
            child: Text(t.dialog_cancel),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(ctx, _MissingResourceChoice.reimport),
            child: Text(t.video_resource_missing_reimport),
          ),
          // 删除是次要动作（非默认、不染红强调），且后接二次确认。
          if (canDelete)
            TextButton(
              onPressed: () =>
                  Navigator.pop(ctx, _MissingResourceChoice.delete),
              child: Text(t.dialog_delete),
            ),
        ],
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case _MissingResourceChoice.reimport:
        // M1：退回视频库，由用户在库内重新导入（最小落地，零新依赖）。
        nav.pop();
      case _MissingResourceChoice.delete:
        await _confirmMissingResourceDelete(row!);
      case _MissingResourceChoice.cancel:
      case null:
        // 停在缺失态（不转圈）。可重连磁盘 / 移回文件后退页重进。
        break;
    }
  }

  /// 缺失态删除：二次确认后复用 home_video_page._confirmDelete 的删除序列
  /// （deleteVideoBook + reclaimDeletedVideoBookAssets + compactAfterVideoDeleteBestEffort），
  /// 删完退回视频库。与库内删除粒度 / 资产回收完全一致，不重写删除逻辑。
  Future<void> _confirmMissingResourceDelete(VideoBookRow row) async {
    final NavigatorState nav = Navigator.of(context);
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(t.video_delete_title),
        content: Text(t.video_delete_confirm(title: row.title)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.dialog_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              t.dialog_delete,
              style: TextStyle(color: Theme.of(ctx).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final String? deletedCoverPath = row.coverPath;
    final String? deletedSubtitlePath = row.subtitleSource;
    final String deletedVideoPath = row.videoPath;
    await widget.repo.deleteVideoBook(row.bookUid);
    await widget.repo.reclaimDeletedVideoBookAssets(
      deletedBookUid: row.bookUid,
      deletedCoverPath: deletedCoverPath,
      deletedSubtitlePath: deletedSubtitlePath,
      deletedVideoPath: deletedVideoPath,
    );
    await widget.repo.compactAfterVideoDeleteBestEffort();
    if (mounted) nav.pop();
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
  /// playlistJson（每集各记自己的进度，换集互不干扰）。单视频：写
  /// VideoBook.lastPositionMs，并镜像到 `video_remote_position_<uid>` +
  /// `video_remote_position_at_<uid>` prefs（TODO-816 断点②）。
  ///
  /// 镜像目的：host 本机播放此视频时，client 拉清单经 host 的 getVideoPosition 读的是
  /// prefs 键空间；若本机播放只写 lastPositionMs / playlistJson 不写 prefs，host 自看
  /// 进度就进不了同步读取键 → client 拿不到（用户报「服务端看了视频，客户端再看进度是
  /// 0」）。镜像后与远端 resume 路径（[_persistRemotePosition]）统一键空间。TODO-885：
  /// 播放列表也按集镜像到 `video_remote_position_<uid>#ep<N>`，让 client 按集恢复 host
  /// 自看进度（与远端剧集列表的按集 key 同源）。
  Future<void> _persistPosition(String uid, int posMs) async {
    final int clamped = posMs < 0 ? 0 : posMs;
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    if (_episodes.isEmpty) {
      await widget.repo.updatePosition(uid, posMs);
      await appModel.prefsRepo
          .setPref(videoRemotePositionEpisodePrefKey(uid, 0), clamped);
      await appModel.prefsRepo
          .setPref(videoRemotePositionEpisodeAtPrefKey(uid, 0), nowMs);
      return;
    }
    _episodes = updateEntryPosition(_episodes, _currentEpisode, posMs);
    await widget.repo.updatePlaylistJson(uid, _encodeEpisodes());
    // TODO-885: 按当前集镜像到远端进度键空间，client 据此按集恢复 host 自看进度。
    await appModel.prefsRepo.setPref(
        videoRemotePositionEpisodePrefKey(uid, _currentEpisode), clamped);
    await appModel.prefsRepo.setPref(
        videoRemotePositionEpisodeAtPrefKey(uid, _currentEpisode), nowMs);
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
    // TODO-658/BUG-383: 摘除系统栏可见性回调（全局单例，避免退页后仍回调已释放 State）。
    if (isMobilePlatform) {
      unawaited(SystemChrome.setSystemUIChangeCallback(null));
    }
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
    // TODO-669：销毁缩略图预览（作废在途取帧 + 销毁离屏 Player + 释放末帧）。
    _disposeThumbnailPreview();
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
    _episodeListVisible.removeListener(_applyControlsVisibilityFromMediaKit);
    _videoControlEditMode.removeListener(_applyControlsVisibilityFromMediaKit);
    // TODO-973：手柄沉浸 notifier 归 AppModel 所有（生命周期长于本页），必须在本页
    // dispose 时摘掉本页注册的监听，否则页面销毁后它仍会回调 [_applyControlsVisibility
    // FromMediaKit] 触碰下面即将 dispose 的本地 notifier。仅当成功路径真挂过才摘除
    // （[_gamepadImmersiveListenerAttached]）——错误态从未 attach，也绝不读 appModel。
    if (_gamepadImmersiveListenerAttached) {
      appModel.gamepadImmersiveActive
          .removeListener(_applyControlsVisibilityFromMediaKit);
    }
    _subtitleListVisible.dispose();
    _episodeListVisible.dispose();
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
    _autoAdvanceCountdownTimer?.cancel();
    _autoAdvanceCountdownNotifier.dispose();
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
      _episodeListVisible.value ||
      _videoControlEditMode.value;

  // BUG-371：字幕跳转列表是 **push-aside** 侧栏（[_videoWithSubtitlePanel] 的
  // `Row[Expanded(video), 面板列]`，TODO-314），把画面挤窄到左侧、**不遮挡**叠在画面上
  // 的左 / 右浮动操作 rail。故强压制门控**不含**字幕列表显隐——开字幕列表时左 / 右控制
  // 按钮应继续可见可用（用户：「字幕列表只是侧边栏，左边的按钮应该还可以换出」）。仅真正盖在
  // 控制条之上的 overlay（[_videoSidePanel] 设置 / 音轨 / 倍速等）和编辑态才压制。
  bool get _videoSideActionRailStronglySuppressed =>
      _videoSidePanel.value != null || _videoControlEditMode.value;

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

  /// seek bar hover 回调（TODO-669）：fork 桌面 seek bar 把 hover 比例（轨道内宽
  /// 权威值，null = onExit）回调到这里。仅桌面 theme 接此回调（移动端触屏无 hover）。
  ///
  /// 转发到取帧调度器：[fraction]==null → 隐藏浮层（作废在途取帧）；否则即时更新
  /// 浮层位置 + 时间戳，桌面本地文件（[_thumbnailPreview] 已建）取帧、远端流 /
  /// 取帧器缺失则 timestampOnly。调度器为 null（理论上桌面恒有，防御）时静默忽略。
  void _onSeekBarHover(double? fraction) {
    final VideoThumbnailPreviewController? preview = _thumbnailPreview;
    if (preview == null) return;
    // 远端流无离屏取帧器 → desktop:false 让调度器走 timestampOnly（只显时间戳）。
    final bool canGrab = _thumbnailGrabber != null;
    preview.request(fraction, desktop: canGrab);
  }

  /// 在 [load] 成功后建立 / 重置缩略图预览（TODO-669）。仅桌面构造调度器；本地
  /// 文件视频额外构造离屏取帧器（实时取帧），远端流不构造取帧器（走 timestampOnly）。
  /// 视频路径变（换集）时销毁旧取帧器 + 调度器、按新路径重建。
  void _setupThumbnailPreview(String? videoPath) {
    if (!_isDesktopVideoControls) {
      // 移动端：完全不创建（零新增运行时、零行为变化）。
      _disposeThumbnailPreview();
      return;
    }
    // 路径未变且已建好 → 复用（避免每次 load 重建离屏 Player）。
    final bool pathChanged = _thumbnailGrabber?.videoPath != videoPath;
    if (_thumbnailPreview != null && !pathChanged) return;

    _disposeThumbnailPreview();

    // 远端流（http/s）或无本地路径 → 不建离屏取帧器（调度器仍建，走 timestampOnly）。
    final bool isLocalFile = videoPath != null &&
        !_isRemote &&
        Uri.tryParse(videoPath)?.scheme != 'http' &&
        Uri.tryParse(videoPath)?.scheme != 'https';
    final OffscreenVideoFrameGrabber? grabber =
        isLocalFile ? OffscreenVideoFrameGrabber(videoPath: videoPath) : null;
    _thumbnailGrabber = grabber;
    _thumbnailPreview = VideoThumbnailPreviewController(
      grabber: grabber != null
          ? grabber.grab
          // 无取帧器（远端流）：取帧函数恒返回 null，调度器据此 timestampOnly。
          : (int _) async => null,
      durationMsProvider: () => _controller?.durationMs ?? 0,
    );
  }

  void _disposeThumbnailPreview() {
    _thumbnailPreview?.dispose();
    _thumbnailPreview = null;
    _thumbnailGrabber?.dispose();
    _thumbnailGrabber = null;
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
  /// 是否已把本页的可见性派生监听挂到全局 [AppModel.gamepadImmersiveActive]。
  /// 仅成功路径（[_seedWarmPopup]）attach，dispose 据此守卫摘除——错误态从不读 appModel。
  bool _gamepadImmersiveListenerAttached = false;

  void _seedWarmPopup() {
    if (!mounted) return;
    // 成功路径调用，此刻 AppModel 必已初始化 → 安全读取真实 lowMemory 设入 controller
    // （seedWarmSlot/dismissAt 据此决定是否保留热槽）。
    _popup.lowMemory = appModel.lowMemoryMode;
    // TODO-973：手柄沉浸门控的订阅也在此成功路径挂载（此刻 appModel 必已初始化）。
    if (!_gamepadImmersiveListenerAttached) {
      appModel.gamepadImmersiveActive
          .addListener(_applyControlsVisibilityFromMediaKit);
      _gamepadImmersiveListenerAttached = true;
    }
    setState(() => _popup.seedWarmSlot());
    _syncPopupOverlay();
  }

  /// 查词浮层打开时，点根 Overlay 全屏 dismiss barrier 的处理：**非嵌套**（只有顶层可见）
  /// 时若点到同句另一个字幕字符则**切换查词**（对该字符走 [_lookupAt]：已暂停故不重复暂停、
  /// 不清 [_pausedForLookup]，`replaceStack` 替换可见浮层）→ 保持暂停、弹窗切到新词；否则
  /// （命中空白/控件区，或处于嵌套态）[_popNestedPopupAt] 逐层关并据 [_pausedForLookup]
  /// 恢复播放。门控判据见 [VideoHibikiPage.shouldSwitchWordOnBarrierTap]。
  ///
  /// 根因 1（BUG-???，用户报）：barrier 全屏盖在字幕之上、抢走点击 → 单层查词点同句第二个
  /// 词只会关栈+恢复播放。barrier 先反查字幕字符命中即可「点词换词、保持暂停」。
  /// 根因 2（TODO-758 / BUG-410）：嵌套查词时底部字幕仍清晰渲染、字符矩形持续绑定，点第
  /// 2+ 个窗外面常落在字幕文字上 → 无条件反查会 `replaceStack` 把整栈替换掉（顶层窗没关而是
  /// 被换成新词）。故反查仅在 [_topVisiblePopupIndex] <= 0（非嵌套）时生效。
  void _onDismissBarrierTap(Offset globalPos) {
    // TODO-758 / BUG-410: 「点字幕换词」仅在非嵌套（只有顶层可见 / 仅剩隐藏热槽）时保留——
    // 单层查词点同句另一个字符切换查词是合理交互。嵌套态（存在父层）下底部字幕仍清晰渲染、
    // 其字符矩形持续绑定，点第 2+ 个窗外面常落在字幕文字上；若仍走反查会 replaceStack 把整栈
    // 替换掉（顶层窗没关而是被换成新词）。故仅当 [shouldSwitchWordOnBarrierTap] 为真才反查。
    final SubtitleCharHit? hit = _subtitleHitTester.hitTest(globalPos);
    if (VideoHibikiPage.shouldSwitchWordOnBarrierTap(
      topVisibleIndex: _topVisiblePopupIndex,
      hitSubtitle: hit != null,
    )) {
      _handleSubtitleLookupTap(hit!.sentence, hit.graphemeIndex, hit.charRect);
      return;
    }
    // TODO-834（反转 TODO-720 / BUG-403）：点**所有弹窗外**的真空白 = 一次性清整栈
    // （[_popNestedPopupAt(0)] → controller.dismissAt(0) 保留隐藏热槽 BUG-092，并在关栈
    // 汇聚点触发会话收尾：恢复播放 / 清草稿 / 收回焦点）。落在字幕文字上的反查门控
    // [shouldSwitchWordOnBarrierTap]（TODO-758 / BUG-410）保持不变，已在上方先判。
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
  /// 方法体搬到 [_VideoLookupMining] part（TODO-590 batch14），@override 留瘦转发器。
  @override
  Future<MinePopupResult> onMineEntry(Map<String, String> fields) =>
      _onMineEntryImpl(fields);

  /// TODO-270 D：覆盖「最新制的那张卡」（[noteId]）。视频页覆写了 [onMineEntry] 绕过
  /// mixin，故覆盖路径也在本页复用视频媒体链路（GIF 封面 + 区间音频），按 id 真实
  /// 覆盖而非删旧建新（[_mineVideoCard] 的 `updateNoteId` 分支）。覆盖同样吃多句合一
  /// 草稿（合并卡=一张卡，天然吃覆盖，与 270-D 正交）；覆盖成功后清空草稿。
  /// 方法体搬到 [_VideoLookupMining] part（TODO-590 batch14），@override 留瘦转发器。
  @override
  Future<MinePopupResult> onUpdateEntry(
    int noteId,
    Map<String, String> fields,
  ) =>
      _onUpdateEntryImpl(noteId, fields);

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
        // TODO-840 Part B：Shift+B 循环遮蔽三态；H 开/关「隐藏主字幕」。
        cycleSubtitleObscure: () => _runWhenImmersiveAllowsFullControls(
          () => unawaited(_cycleSubtitleObscure()),
        ),
        toggleSubtitleHide: () => _runWhenImmersiveAllowsFullControls(
          () => unawaited(_toggleSubtitleHide()),
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
          // TODO-638：剧集列表 push-aside 侧栏开着时，Esc 先关它（逐级退出）。
          if (_episodeListVisible.value) {
            _closeEpisodeList();
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
    return Flexible(
      // TODO-642：标题用 Flexible(loose) 而非 Expanded(=FlexFit.tight)。tight 会强迫
      // 标题填满它分到的那 1/3 顶栏宽，把左右按钮组（同为 Flexible loose）挤进窄滚动
      // 区，导致右上角按钮被裁/要横滑才看得到。loose 让标题只占自身需要的宽、把剩余
      // 空间优先让给按钮组；标题已有 maxLines:1 + ellipsis，窄窗时优雅截断不溢出。
      fit: FlexFit.loose,
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
      case VideoControlButton.settings:
        _showPlayerSettings(sourceSlot: sourceSlot);
        break;
    }
  }

  bool _hasRoomyVideoBottomBar() => MediaQuery.of(context).size.width >= 600;

  /// 系统底部安全区 inset（BUG-184 / TODO-658·BUG-383）：导航栏 / 手势条**真正可见时**
  /// 的物理高度，用来把进度条与底部按钮条抬离系统栏。视频打开后走 immersiveSticky 隐藏
  /// 导航栏，常态下系统栏不可见 → 返回 0（基线 [_videoBottomChromeBaseline] 仍保证进度条
  /// 不贴最底）；导航栏真显示（三键导航 / 上划临时唤出）时返回 `viewPadding.bottom`，进度
  /// 条随之上移避开（保 BUG-184 本意）。
  ///
  /// **为何先判 [_systemBarsVisible] 而非直接读 inset**（TODO-658 根因）：targetSdk 35
  /// 强制 edge-to-edge + 手势导航下，`viewPadding.bottom`（与 `padding.bottom` 同源，仅
  /// 差键盘）即便 immersiveSticky 已隐栏仍恒上报手势条高度，单读 inset 会把进度条永久顶高
  /// （BUG-370）。故用 [SystemChrome.setSystemUIChangeCallback] 喂的真实可见性当门控：隐栏
  /// 时直接归零，可见时才取物理 inset。桌面 [_systemBarsVisible] 恒 false（不注册回调）→
  /// 始终 0，桌面无系统栏，符合预期。
  double _videoBottomSystemInset() =>
      _systemBarsVisible ? MediaQuery.of(context).viewPadding.bottom : 0.0;

  /// 系统顶部安全区 inset（BUG-463）：把视频内顶栏（media_kit 控制条 [topButtonBar]）
  /// 抬离状态栏 / 刘海，否则顶栏左右按钮被遮挡、点不到（用户报「顶栏的按钮会被挡住」）。
  ///
  /// **为何顶栏需要而底栏另有 helper**：fork 的 [MaterialVideoControls] 只在**全屏**时给
  /// 顶栏 Column 套 `MediaQuery.padding` 顶部内缩（material.dart 的
  /// `isFullscreen ? MediaQuery.padding : EdgeInsets.zero`），窗口态外层 padding 恒
  /// `EdgeInsets.zero`。而移动端视频**永不进 media_kit 全屏路由**（BUG-221，
  /// [_toggleVideoFullscreen] 移动端 no-op）→ 顶栏始终落在窗口分支、顶部 inset 从不生效，
  /// 顶栏按钮永远贴 `y=0`，被状态栏 / 刘海盖住。故在 [_mobileControlsTheme] 的
  /// `topButtonBarMargin.top` 显式补这一段，与底栏 [_videoBottomSystemInset] 对称。
  ///
  /// **为何读 `padding` 而非 `viewPadding`**（避免 BUG-370 式过度内缩）：
  /// immersiveSticky 隐栏后 `viewPadding.top` 仍恒上报状态栏区高度，单读它会把顶栏永久
  /// 顶低一段空白。`padding.top` 在隐栏且无顶部刘海时收敛到 0、有刘海时为刘海高、状态栏
  /// 被上划临时唤出时为状态栏高——正是顶栏需要避让的真实物理 inset。桌面无系统栏语义，
  /// [_isDesktopVideoControls] 恒走桌面 theme（不调本 helper），且桌面 `padding` 亦为 0。
  ///
  /// 左 / 右用 `max(16, padding.left/right)`：与浮动侧栏 [_mergeRailSafeAreaPadding] 同款
  /// 逐边取 max——横屏刘海手机（cutout 落在短边 = 左 / 右）下顶栏左 / 右按钮也避开刘海，
  /// 又不在无刘海时把默认 16 叠加成双重留白。几何收敛进纯函数 [videoTopBarMargin]
  /// （页面与测试同源调用）。
  EdgeInsets _videoTopBarMargin() =>
      videoTopBarMargin(MediaQuery.of(context).padding);

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
      // TODO-568：用**可见轨道高** + 呼吸间距（而非整段触摸热区高），字幕底缘骑在可见
      // 进度条上方一点点、不顶飞那 ~47×缩放 的透明命中区空白。
      seekBarTrackHeight: _videoSeekBarTrackHeight,
      subtitleBreathingGap: _videoSubtitleSeekBarBreathingGap,
      bottomChromeBaseline: _videoBottomChromeBaseline,
      bottomSystemInset: _videoBottomSystemInset(),
    );
  }

  /// 设置音画延迟（毫秒）：即时调 controller（字幕 cue 同步偏移立即生效，BUG-373：
  /// controller 侧 [VideoPlayerController.setDelayMs] 已立即重算当前 cue + notify）+
  /// 持久化到 VideoBook.delayMs（换集复用、跨重启保留）+ 刷新面板显示 + 左上角 OSD
  /// 即时反馈（BUG-373：与调速 [Icons.speed] 同范式，让快速设置面板外也看得到调整生效）。
  Future<void> _setDelayMs(int delayMs) async {
    final int clamped = delayMs.clamp(-600000, 600000);
    if (clamped == _delayMs) return;
    _delayMs = clamped;
    _controller?.setDelayMs(clamped);
    // BUG-373：左上角 OSD 即时反馈。带显式正负号（与面板内 +N ms 回显一致），
    // 让用户在不打开快速设置面板时也能看到字幕同步已调整、调多少。
    final String signed = clamped >= 0 ? '+$clamped' : '$clamped';
    _showOsd(
      t.video_subtitle_delay_osd(ms: signed),
      icon: Icons.sync_outlined,
    );
    await widget.repo.updateDelayMs(widget.bookUid, clamped);
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
    _clearRailHover();
    if (_subtitleListVisible.value) {
      _clearSelectedMiningCues();
      _subtitleListVisible.value = false;
    }
    // TODO-638：开任何浮层都关掉 push-aside 剧集列表（与字幕列表同处右栏，互斥）。
    if (_episodeListVisible.value) {
      _episodeListVisible.value = false;
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

  /// 持久化字幕外观并刷新 overlay（纯 Flutter overlay，不碰 mpv）。
  Future<void> _persistSubtitleStyle(VideoSubtitleStyle style) async {
    _subtitleStyle = style;
    await appModel.setVideoSubtitleStyle(VideoSubtitleStyle.encode(style));
    if (mounted) setState(() {});
  }

  /// 切换字幕模糊（'B' 热键 + 设置面板共用）。TODO-840 Part B：在「模糊」与「不遮蔽」
  /// 之间切换——若当前是模糊则关掉，否则置为模糊（从隐藏态按 B 也回到模糊，符合「B 管
  /// 模糊」直觉）。隐藏态由 [_toggleSubtitleHide] / [_cycleSubtitleObscure] 管理。
  Future<void> _toggleSubtitleBlur() async {
    final VideoSubtitleObscureMode next =
        appModel.videoSubtitleObscureMode == VideoSubtitleObscureMode.blur
            ? VideoSubtitleObscureMode.none
            : VideoSubtitleObscureMode.blur;
    await _setSubtitleObscureMode(next);
  }

  /// 循环字幕遮蔽三态（Shift+B，TODO-840 Part B）：不遮蔽 → 模糊 → 隐藏 → …。
  Future<void> _cycleSubtitleObscure() async {
    await _setSubtitleObscureMode(appModel.videoSubtitleObscureMode.next);
  }

  /// 开/关「隐藏主字幕」（H，TODO-840 Part B）：隐藏态按 H 回到不遮蔽，否则置为隐藏。
  Future<void> _toggleSubtitleHide() async {
    final VideoSubtitleObscureMode next =
        appModel.videoSubtitleObscureMode == VideoSubtitleObscureMode.hide
            ? VideoSubtitleObscureMode.none
            : VideoSubtitleObscureMode.hide;
    await _setSubtitleObscureMode(next);
  }

  /// 落盘字幕遮蔽模式并刷新页面 overlay（热键 + 快速设置面板共用，TODO-840 Part B）。
  Future<void> _setSubtitleObscureMode(VideoSubtitleObscureMode mode) async {
    await appModel.setVideoSubtitleObscureMode(mode);
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
      initialSubtitleObscureMode: appModel.videoSubtitleObscureMode,
      initialSubtitleStyle: _subtitleStyle,
      uiScale: _videoUiScale,
      initialAsbConfig: _asbConfig,
      onSetDelay: _setDelayMs,
      // TODO-701 阶段1：仅当当前有字幕 cue + 视频本地路径时给自动对轴按钮（否则
      // 无可对齐对象/无音频源），否则置 null 让面板不显示该按钮。
      onAutoAlign: (_controller?.cues.isNotEmpty ?? false) &&
              (_controller?.videoPath?.isNotEmpty ?? false)
          ? _autoAlignSubtitle
          : null,
      onPreviewSpeed: (double v) => _setSpeed(v, persist: false),
      onSetSpeed: _setSpeed,
      onSetSubtitleObscureMode: _setSubtitleObscureMode,
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

  /// 字幕抽取/解析当前是否在进行。状态显示在右侧半透明字幕源面板里，画面仍可见；
  /// 底层 ffmpeg/文件解析 Future 目前没有取消契约，关闭面板只是不再打断观看。
  bool _subtitleLoadingShown = false;

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
          // TODO-897：本地资源缺失态——必须在转圈判据之前短路（缺失时不调 load，
          // _controller 维持 null 也会落进下面的 spinner 分支无限转圈）。
          : _missingResource
              ? _buildMissingResourceBody(cs)
              : (controller == null || videoController == null)
                  ? const Center(child: CircularProgressIndicator())
                  : _withPageSpaceOverride(
                      controller,
                      _pageDropTarget(
                        controller,
                        _buildVideoBody(controller, videoController),
                      ),
                    ),
    );
  }

  /// TODO-897：本地资源缺失态正文（不转圈）。中性图标 + 文案 + 「重新导入 / 删除
  /// 条目（仅单视频）」按钮，对应 [_promptMissingResource] 的选项；首帧若对话框
  /// 被取消，用户仍能从这里再次触发。
  Widget _buildMissingResourceBody(ColorScheme cs) {
    final VideoBookRow? row = _missingRow;
    final bool canDelete = row != null && !_isPlaylist && !_isRemote;
    final String title = _title ?? row?.title ?? '';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.video_file_outlined, color: cs.error, size: 48),
            const SizedBox(height: 16),
            Text(
              t.video_resource_missing_message(title: title),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: <Widget>[
                FilledButton.tonal(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(t.video_resource_missing_reimport),
                ),
                if (canDelete)
                  TextButton(
                    onPressed: () =>
                        unawaited(_confirmMissingResourceDelete(row)),
                    child: Text(t.dialog_delete),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 页内局部「裸空格 = 播放/暂停」覆盖（TODO-755，回归 c152fcd91）。
  ///
  /// 全局导航层（[wrapWithGlobalNavigation]）无条件把裸空格中和成
  /// [DoNothingIntent]（`global_navigation.dart`，[DoNothingAction.consumesKey]
  /// 为 true → 真消费按键），使焦点确认永不走空格。视频空格的正常路径是
  /// media_kit 桌面 controls 的 `keyboardShortcuts`（[_videoKeyboardShortcuts]），
  /// 但那只在 [_videoFocusNode]（或 controls 内置 Focus）**精确持焦**时才生效；
  /// 一旦焦点落在视频页子树里其它节点（关对话框/菜单后短暂失焦、点了非视频区控件
  /// 等），裸空格就会上浮到全局 [DoNothingIntent] 被吞掉 → 「按了没反应」。
  ///
  /// 本层是页内局部 [CallbackShortcuts]，位于全局 [DoNothingIntent] 之下、离视频
  /// 更近：只要焦点落在视频页子树内**任意**节点，裸空格都先被这层消费、永不下沉到
  /// 全局中和层。与阅读器 [resolveReaderSpaceOverride] / 有声书 audiobookPlayPause
  /// 同范式——只在本页子树内覆盖裸空格，不碰全局中和（非视频界面空格仍被中和，
  /// 不破坏 TODO-112「空格不确认焦点」）。media_kit 的 `keyboardShortcuts` 在精确
  /// 持焦时是更近作用域、先消费，故两者不冲突；本层只是「焦点在视频页子树但不精确
  /// 在 [_videoFocusNode]」时的兜底。语义与注册表 [_videoKeyboardShortcuts] 的
  /// `togglePlayPause` 完全一致（经 [_runWhenImmersiveAllowsFullControls] 尊重
  /// 沉浸锁门控），不引入特例分支。
  Widget _withPageSpaceOverride(
    VideoPlayerController controller,
    Widget child,
  ) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.space): () =>
            _runWhenImmersiveAllowsFullControls(
              () => unawaited(controller.playOrPause()),
            ),
      },
      child: child,
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
}
