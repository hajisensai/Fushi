import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/media/video/video_black_flicker_detector.dart';
import 'package:fushi/src/media/video/video_episode_start_policy.dart';
import 'package:fushi/src/startup/media_handle_registry.dart';
import 'package:fushi/src/media/video/video_lua_script_manager.dart';
import 'package:fushi/src/media/video/video_mpv_config.dart';
import 'package:fushi/src/media/video/video_playback_source.dart';
import 'package:fushi/src/media/video/video_shader_manager.dart';
import 'package:fushi/src/media/video/video_subtitle_source.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

@visibleForTesting
String mediaUriForVideoPath(String path) {
  final Uri? uri = Uri.tryParse(path);
  if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
    return uri.toString();
  }
  return File(path).uri.toString();
}

/// 字幕调轴：把播放位置 [posMs] 按字幕偏移 [delayMs] 平移成「查 cue 用的等效位置」。
///
/// 正 [delayMs]＝画面/音频先于文字（字幕显得早了）→ 往回拨位置，让字幕晚出现（整体延后）；
/// 负 [delayMs]＝字幕晚于画面 → 往前拨位置，让字幕提前。下界 clamp 到 0（位置不为负）。
/// 纯函数，无副作用，是 [VideoPlayerController.updateCueForPosition] 与单测的共享真相源。
int effectiveSubtitlePositionMs(int posMs, int delayMs) =>
    (posMs - delayMs).clamp(0, 1 << 30);

/// 「上一句」seek 决策结果（TODO-085，[VideoPlayerController.prevSeekDecisionFor] 返回）。
///
/// 三态：跳到某条 cue（句子 seek）／回退固定毫秒（时间 seek 退化）／无动作。
/// 用不可变值对象而非裸 record，便于在 [VideoPlayerController.skipToPrevCue] 与单测中
/// 明确区分意图。
@immutable
class PrevSeekDecision {
  const PrevSeekDecision._({this.cueIndex, this.timeSeekDeltaMs});

  /// 跳到第 [index] 条 cue（句子 seek）。
  const PrevSeekDecision.cue(int index) : this._(cueIndex: index);

  /// 回退（或前进）[deltaMs] 毫秒的相对时间 seek（TODO-085 退化分支恒为负）。
  const PrevSeekDecision.timeSeek(int deltaMs)
      : this._(timeSeekDeltaMs: deltaMs);

  /// 无可后退的上一句：不动（保持原 no-op 语义）。
  static const PrevSeekDecision none = PrevSeekDecision._();

  /// 目标 cue 下标；非 null 表示句子 seek。
  final int? cueIndex;

  /// 相对时间 seek 的毫秒偏移；非 null 表示时间 seek（退化分支）。
  final int? timeSeekDeltaMs;

  @override
  bool operator ==(Object other) =>
      other is PrevSeekDecision &&
      other.cueIndex == cueIndex &&
      other.timeSeekDeltaMs == timeSeekDeltaMs;

  @override
  int get hashCode => Object.hash(cueIndex, timeSeekDeltaMs);

  @override
  String toString() =>
      'PrevSeekDecision(cueIndex: $cueIndex, timeSeekDeltaMs: $timeSeekDeltaMs)';
}

/// mkv/mp4 内封章节（chapter）的一条记录（TODO-424）。只读值对象：序号 + 标题 +
/// 起始位置，由 [VideoPlayerController.refreshChapters] 从 libmpv `chapter-list`
/// 属性解析得到，章节面板渲染 + 跳转用。
///
/// [index] 是 libmpv `chapter` 属性的 0-based 章节下标（跳转时直接写回 `chapter`
/// 或 seek 到 [start]）；[title] 为容器里写的章节名（如 `Chapter 01`，可能为空，
/// 调用方据此回退成「章节 N」之类占位）；[start] 为该章在时间轴上的起点。
@immutable
class VideoChapter {
  const VideoChapter({
    required this.index,
    required this.title,
    required this.start,
  });

  /// 0-based 章节下标（对齐 libmpv `chapter` 属性）。
  final int index;

  /// 章节标题（容器里写的 `title`，可能为空字符串）。
  final String title;

  /// 章节在时间轴上的起点。
  final Duration start;

  @override
  bool operator ==(Object other) =>
      other is VideoChapter &&
      other.index == index &&
      other.title == title &&
      other.start == start;

  @override
  int get hashCode => Object.hash(index, title, start);

  @override
  String toString() =>
      'VideoChapter(index: $index, title: "$title", start: $start)';
}

/// 把 libmpv `chapter-list` 的扁平字符串属性解析成 [VideoChapter] 列表。纯函数。
///
/// media_kit 的 `NativePlayer.getProperty` 走 `mpv_get_property_string`，只能逐条读
/// **字符串**化的子属性（无 MPV_FORMAT_NODE 数组的高层封装）。libmpv 把章节暴露成：
/// - `chapter-list/count`：章节数（整数字符串，空/非法当 0，即「无章节」）；
/// - `chapter-list/N/title`：第 N 章标题（可能空字符串）；
/// - `chapter-list/N/time`：第 N 章起点**秒**（浮点字符串，如 `12.500`）。
///
/// [count] 为 `chapter-list/count` 原始字符串；[titleAt]/[timeAt] 是按下标取
/// `title`/`time` 子属性原始字符串的回调（[VideoPlayerController.refreshChapters]
/// 注入真实 `getProperty`，单测注入假数据）。无章节 / count 非法时返回空列表。
///
/// 时间解析：秒（浮点）→ 毫秒 [Duration]，下界 clamp 到 0（防御负值 / 非法）。抽成纯
/// 函数便于不依赖 libmpv 的单测（[VideoChapter] 解析与跳转决策都可纯测）。
List<VideoChapter> parseChapterList({
  required String count,
  required String Function(int index) titleAt,
  required String Function(int index) timeAt,
}) {
  final int total = int.tryParse(count.trim()) ?? 0;
  if (total <= 0) return const <VideoChapter>[];
  final List<VideoChapter> chapters = <VideoChapter>[];
  for (int i = 0; i < total; i++) {
    final double seconds = double.tryParse(timeAt(i).trim()) ?? 0.0;
    final int ms = (seconds * 1000).round();
    chapters.add(VideoChapter(
      index: i,
      title: titleAt(i),
      start: Duration(milliseconds: ms < 0 ? 0 : ms),
    ));
  }
  return chapters;
}

/// 纯函数：「上/下一章」目标章节下标决策（[VideoPlayerController.nextChapter] /
/// [VideoPlayerController.previousChapter] 用，抽出便于单测）。
///
/// [chapterCount] 为章节总数；[currentIndex] 为当前 `chapter`（libmpv 在首章之前可能
/// 返回 -1）；[forward] 为 true 取下一章、false 取上一章。
/// - 无章节（count <= 0）：返回 null（no-op）。
/// - forward：当前下标 + 1，越过末章返回 null（已在末章，不前进越界）；
///   currentIndex < 0（首章之前）时落首章（0）。
/// - backward：当前下标 - 1，早于首章返回 null（已在首章 / 首章之前，不后退越界）。
int? adjacentChapterIndex({
  required int chapterCount,
  required int currentIndex,
  required bool forward,
}) {
  if (chapterCount <= 0) return null;
  if (forward) {
    final int next = currentIndex < 0 ? 0 : currentIndex + 1;
    return next >= chapterCount ? null : next;
  }
  final int prev = currentIndex - 1;
  return prev < 0 ? null : prev;
}

/// 纯函数：按播放位置 [posMs] 求所在章节下标（起点 <= 位置的最后一章）。
/// 空列表 / 早于首章起点返回 -1。要求 [chapters] 按 [VideoChapter.start] 升序
/// （[parseChapterList] / libmpv `chapter-list` 天然升序）。章节面板高亮当前章用。
int chapterIndexForPositionIn(List<VideoChapter> chapters, int posMs) {
  int result = -1;
  for (int i = 0; i < chapters.length; i++) {
    if (chapters[i].start.inMilliseconds <= posMs) {
      result = i;
    } else {
      break;
    }
  }
  return result;
}

/// 视频播放控制器：用 media_kit 播放视频，并按字幕 cue 做 125ms 同步高亮。
///
/// cue 选择语义大体照搬有声书 [AudiobookPlayerController] 的 `_updateCurrentCue`：
/// endMs 闭区间、同句不重复 [notifyListeners]、delayMs 扣减位置。**关键差异**：
/// gap（[JsonAlignmentParser.findCueIndex] 返回 -1）时有声书保留上一句正文高亮，
/// 而视频底部字幕 overlay 必须清空——真实字幕在时间窗结束后就该消失（BUG-074）。
///
/// 与有声书的关键差异：位置来源不是 just_audio 的 positionStream，而是
/// [Timer.periodic]（125ms）读 `player.state.position`；播放后端是 media_kit
/// [Player]。
///
/// 设计约束（务必遵守）：
/// - [Player] / [VideoController] **延迟构造**：构造函数只初始化纯 cue 状态，
///   不 `new Player()`，因为测试宿主无 libmpv，构造即抛。真正实例化放在 [load]。
/// - cue 选择逻辑抽成可测的 [updateCueForPosition]，并经 [debugUpdateCueForPosition]
///   暴露给单测——单测只调 [setCues] + [debugUpdateCueForPosition]，不触发 Player。
class VideoPlayerController extends ChangeNotifier
    implements VideoPlaybackSource {
  Player? _player;
  VideoController? _videoController;

  /// TODO-1212：本控制器持有的 libmpv Player 在 [MediaHandleRegistry] 的句柄释放
  /// 登记（首次建 Player 时登记，[dispose] 注销）。数据根迁移前经注册表 `await`
  /// [_releaseMediaHandles] 真放掉底层文件句柄，避免同盘 rename 撞「文件被占用」。
  MediaHandleReleaseCallback? _mediaHandleRegistration;

  List<AudioCue> _cues = <AudioCue>[];
  AudioCue? _currentCue;
  int _currentCueIndex = -1;

  /// TODO-1312：当前**主字幕**活动集（区间 [startMs,endMs] 覆盖 effective 位置的所有
  /// cue 下标，升序）。[_currentCue]/[_currentCueIndex] 仍是「代表」单条（查词锚 / 跳句
  /// / 收藏默认 / 暂停到句尾用，语义不变），本集额外承载「同一时刻重叠的多条 cue 都要
  /// 渲染」——避免越过被选那条 end 落进 gap 时 overlay 闪烁 / 只显其一（重叠 cue 都显）。
  /// [_activeCueIndices] 是下标（进 [_cues]），[setCues] 换 cue 列表时必须复位（否则旧
  /// 下标对新 [_cues] 越界）。
  List<int> _activeCueIndices = const <int>[];

  /// TODO-1312：副字幕 cue 流。与主字幕 [_cues] 独立、同一 effective 位置各自求活动集，
  /// 一起交给 Flutter overlay 多层渲染（不再走 libmpv `secondary-sid` 自渲染）——副字幕
  /// 因此也可逐字符查词。空列表 = 无副字幕。按 startMs 升序（[setSecondaryCues] 保证）。
  List<AudioCue> _secondaryCues = <AudioCue>[];

  /// 副字幕当前活动集（下标进 [_secondaryCues]，升序）。[setSecondaryCues] /
  /// [clearSecondaryCues] 换列表时复位。
  List<int> _activeSecondaryCueIndices = const <int>[];

  /// 最近一次「主动跳转」([skipToCue]) 的目标 cue 下标；无主动跳转待落地时为 null。
  ///
  /// **修 TODO-565 字幕列表点击高亮 off-by-one。** 高亮真相源是「实时 position 经
  /// [JsonAlignmentParser.findCueIndex] 反推」（TODO-410 无状态推导）。但 BUG-259 的
  /// 前导余量（[kCueSeekPreRollMs]）故意把 [skipToCue] 的 seek 落点偏到目标句**之前**
  /// （`cue.startMs - 180ms`）以吸收关键帧吸附——听感对，但 seek 刚落地、position 还停
  /// 在 `[startMs-preRoll, startMs)` 这段 preRoll 引导窗口里时，[findCueIndex] 据实际
  /// 位置正确地报「在上一句区间 / gap」，于是高亮先闪上一句（N-1）才在 ~180ms 后随播放
  /// 自然进入目标句变 N，用户点第 N 行看到的就是「高亮上一句」。
  ///
  /// 修法不是绕过 preRoll（听感需要它），而是把「主动跳转目标」这个**已知事实**记下来：
  /// 在 [_syncCueForPosition] 里，当 position 仍落在目标句的 preRoll 引导窗口内时，把命中
  /// 下标 snap 回目标句；position 自然进入目标句、越过它、或被另一次跳转/seek 改写时清空，
  /// 之后恢复纯位置推导。只影响「点列表/上下句跳转后那一瞬」，不碰连续播放的自动跟随。
  int? _seekTargetCueIndex;

  /// 「在途 seek 宽限」剩余 tick 配额（仅 [_seekTargetCueIndex] 非空时有意义）。
  ///
  /// **修 TODO-565 复核退回的真机时序漏洞。** [skipToCue] 置 [_seekTargetCueIndex] 后
  /// `await seekMs(startMs-preRoll)` 是异步的，但 media_kit 的 `player.state.position`
  /// 不随 seek 同步更新（见本类 1481-1484 行注释，与 [_restoreTargetMs] 守护同一个 lag）。
  /// 125ms tick 在 seek 真落地前会先读到 **seek 之前的旧 position**：点靠后行时旧位置
  /// 远早于引导窗口 → [cueSnapIndex] 情形 2「远离窗口」清快照；点靠前行时旧位置已过目标
  /// 句首 → 情形 1 清快照。等真落点 `startMs-preRoll` 的 tick 到来，快照已被清 →
  /// [JsonAlignmentParser.findCueIndex] 反推 N-1 → off-by-one 真机复发。
  ///
  /// 根因：[cueSnapIndex] 的「远离窗口 → 清快照」无法区分「用户手动 seek 拉走（该清）」
  /// 与「[skipToCue] 自己的 seek 还在途、position 暂停在旧远处（不该清）」。
  ///
  /// 修法（沿用 [_restoreGuardTicksLeft] 有界宽限范式，**不碰** [cueSnapIndex] 几何）：
  /// 仅 [skipToCue] 路径在置目标时把配额充满；position **首次进入引导窗口之前**，若
  /// [cueSnapIndex] 判「远早于窗口」（情形 2）要清快照，先消耗一格宽限、改为保留快照并
  /// snap 回目标句（让快照撑到 seek 落地）。position 一旦首次进入引导窗口（情形 3）或
  /// 自然越过目标句首（情形 1）即作废宽限、恢复正常清除语义。配额耗尽（seek 永不落地，
  /// 慢设备 / libmpv 丢弃，对齐 BUG-179）也放弃保护，绝不永久把高亮钉在旧目标上。
  ///
  /// 用户**主动** seek（[seekRelative] / 收藏句直接 [seekMs]）走的是别的入口、不置本
  /// **cue-snap** 宽限，且 [seekRelative] 显式清宽限+快照——手动 seek 仍能立刻清快照，不被
  /// 本保护误连坐。（普通 seek 的在途 lag 由另一套 [_plainSeekTargetMs] 处理，见其注释。）
  int _seekSnapGraceTicksLeft = 0;

  /// 普通 seek（[seekRelative] / [seekToChapter] / 页面收藏句直接 [seekMs]，**非**
  /// [skipToCue]）的「在途目标位置」（ms，effective 前的原始播放位置）；null = 无在途普通 seek。
  ///
  /// **修「±秒等普通跳转到 gap 后旧字幕不消失（尤其暂停重听时）」。** media_kit 的
  /// `player.state.position` 不随 seek 同步更新（与 [_seekTargetCueIndex] 注释同一 lag），
  /// **暂停态更是长时间停在旧位置**（有声书 `AudiobookPlayerController._explicitSeekInFlight`
  /// 同结论：暂停态 positionStream 不推进、`seek` 仍吐旧位置）。125ms tick
  /// （[updateCueForPosition]）在 seek 落地前逐拍读到旧 position → [JsonAlignmentParser.findCueIndex]
  /// 反推旧句 → 旧字幕被反复确认、一直挂着。[skipToCue] 用 [_seekTargetCueIndex] 快照抑制了
  /// 这个 lag，但普通 seek 历史上**有意未置**保护（见 [_seekSnapGraceTicksLeft] 注释末段），
  /// 于是暴露本 bug。
  ///
  /// 修法对齐有声书 `_explicitSeekInFlight` 抑制范式：[seekMs] 一发 seek 就记下目标位置、
  /// 并立刻按目标位置**权威同步一次字幕**（直接调 [_syncCueForPosition]，不经 tick 的位置
  /// 调和），字幕即时反映跳转目的地（gap 则消失）；随后 tick 经 [_reconcileSeekInFlightPosition]
  /// 在 seek 落地前把「读到的旧 position」替换成目标位置——**暂停态无限期保持**（等按播放），
  /// **播放态给有界宽限**（[_plainSeekGraceTicksLeft]）等真实位置落定后放行。与 [skipToCue]
  /// 的 [_seekTargetCueIndex] 快照互斥（后者非空时本调和让路、不双重抑制；[skipToCue] 走
  /// [_rawSeekMs] 也不置本状态）。
  int? _plainSeekTargetMs;

  /// 普通 seek 在途宽限剩余 tick（仅**播放态**消耗；暂停态无限期保持目标、不计此配额）。
  /// 复用 [_seekSnapGraceTicks] 同一 2 秒量级：播放态真实位置通常一两拍即落定，配额耗尽
  /// （慢设备 / 永不落定）也放行真实位置，绝不永久把字幕钉在旧目标上。
  int _plainSeekGraceTicksLeft = 0;

  /// 音画延迟（毫秒）：正值表示"视频比文字先播"，查 cue 时把位置往回拨。
  int _delayMs = 0;

  /// 副字幕独立调轴（毫秒，TODO-2837 主副字幕分开调轴）。**null = 未单独设置 =
  /// 跟随 [_delayMs]**（与历史「主副共用一个 offset」行为一致）；非 null = 副字幕
  /// cue 流按此值独立求活动集（主副字幕轴不同源时各调各的）。副字幕恒为 Dart 文本
  /// cue 流（无图形轨形态），不涉及 libmpv `sub-delay`。
  int? _secondaryDelayMs;

  /// 当前字幕是否走 libmpv 画面渲染的**图形内封轨**（PGS/DVD 等位图，
  /// [selectEmbeddedGraphicTrack]）。图形字幕没有文本 cue，[_delayMs] 的 Dart 侧 cue
  /// 偏移对它无效，调轴必须下发到 libmpv `sub-delay`（BUG-301）。
  ///
  /// 仅 [selectEmbeddedGraphicTrack] 选轨成功置 true；[setCues]（非空文本 cue）/
  /// [selectSubtitleTrack]（关字幕 `no()`）/ [load]（换片复位）置 false。不用
  /// `_cues.isEmpty` 推断——图形轨与「无字幕的 OP 段」都是空 cue，会误判。
  bool _graphicSubtitleActive = false;

  /// 最近一次 [setSpeed] / [load] 之倍速；player 未实例化时供 [speed] getter 回退。
  double _lastSpeed = 1.0;

  /// 最近一次 [setVolume] 请求的「可听音量」（0..100）；player 未实例化时供 [volume]
  /// getter 回退。**这是音量目标的单一语义**：调音量就写它，与「静音前音量」无关。
  double _lastVolume = 100.0;

  /// 进入静音那一刻捕获的「静音前音量」（0..100），取消静音时恢复到它。
  ///
  /// 与 [_lastVolume] 分离是 TODO-433 的根因修复：旧实现让 [_lastVolume] 同时承担
  /// 「音量目标」和「静音前音量」两种语义——静音期间任何调音量都会改写它，导致
  /// ① 静音被无意解除（[setVolume] 的 `if(_lastVolume>0)_muted=false`）、
  /// ② 取消静音恢复到被污染后的值。本字段**只在进入静音那一刻写一次**，静音期间的
  /// [setVolume] / [adjustVolume] 一律不碰它，确保取消静音必回到确定的静音前音量。
  double _volumeBeforeMute = 100.0;

  bool _muted = false;
  bool _pauseAtSubtitleEnd = false;
  Future<void> Function()? _pauseAtSubtitleEndOverride;
  bool Function()? _pauseAtSubtitleEndIsPlayingOverride;
  Future<void> Function(int positionMs)? _pauseAtSubtitleEndSeekOverride;

  /// 测试注入：[replayCue] 的起播出口（生产为 null，走真 [play]）。无 [_player] 的
  /// 纯单测里 [play] 是 no-op，靠它断言「重播确实起播了」。
  Future<void> Function()? _replayPlayOverride;
  int? _lastSubtitleEndPauseCueIndex;

  /// 「只播这一句就停」的一次性目标 cue 下标（[replayCue] 置，句尾停下即消耗）；
  /// null = 无一次性请求。
  ///
  /// **与全局偏好 [_pauseAtSubtitleEnd] 正交**，故必须是独立字段而不是「临时把开关
  /// 打开、停下再关」：后者一旦停不下来（用户中途 seek 走 / 换片）就把用户的真实偏好
  /// 永久写反了。两者经 [_holdEnabledForCue] 汇成同一个句尾判定，句尾暂停的时序、
  /// seek 回句尾的落点、防重复停（[_lastSubtitleEndPauseCueIndex]）全部共用一套代码，
  /// 不产生第二条平行路径。
  ///
  /// **生命周期绝不能挂进 [_clearSeekTargetSnap]**（那是「主动跳转快照」的复位点）：
  /// 该方法在**自然播放越过目标句**时会被 [_applySeekTargetSnap] 自行调用，而那一刻
  /// 正是重播即将抵达句尾、最需要本字段存活的时刻——挂进去等于每次重播都在停下来
  /// 之前把自己清掉。因此只在**用户主动改变播放位置**的两个真实出口（[seekMs] /
  /// [_rawSeekMs]，后者覆盖 [skipToCue] 点别的句子）和换片换字幕（[setCues]）清。
  int? _oneShotHoldCueIndex;

  /// 当前启用的 mpv 着色器绝对路径（[load] 复用 / [applyShaders] 实时切换）。
  List<String> _shaderPaths = <String>[];

  /// 当前 mpv 配置（[load] 复用 / [applyMpvConfig] 实时切换）。
  VideoMpvConfig _mpvConfig = VideoMpvConfig.defaults;

  /// 当前 mpv 视频亮度（libmpv `brightness` 属性，范围 -100..100，0=原始）。桌面
  /// 左半区竖拖手势（TODO-754）在系统屏幕亮度不可控时改写它，给视频画面真实的亮
  /// 度反馈。player 未实例化 / 非 libmpv 后端时只保留此目标值，[load] 不复用（每片
  /// 重置，符合 mpv 默认）。
  int _videoBrightness = 0;

  Timer? _tick;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _completedSub;
  bool _completedFiredForLoad = false;
  VoidCallback? _onCompleted;

  bool _subtitleCuesLoading = false;

  /// 视频原始分辨率变化订阅（用于字幕 \pos letterbox 映射在分辨率到位后重定位）。
  StreamSubscription<int?>? _widthSub;
  StreamSubscription<int?>? _heightSub;

  /// TODO-1297：缓冲态变化订阅（始终挂，非诊断专用）。首开就绪判据
  /// [isReadyForFirstPaint] 依赖「缓冲结束」翻真，而缓冲结束可能不伴随宽高/播放态
  /// 变化，故单独订阅 `stream.buffering` 在其翻转时 [notifyListeners]，驱动页面
  /// 重新评估就绪并挂载 [Video]（否则只能等兜底定时器）。
  StreamSubscription<bool>? _bufferingReadySub;

  /// 媒体时长首次就绪订阅：duration > 0 是 media_kit/libmpv 已解析媒体头的真实信号。
  /// 章节读取和进度条章节刻度都依赖这个信号，而不是 open() 返回后的时间猜测。
  StreamSubscription<Duration>? _durationReadySub;

  /// BUG-739：当前音频输出设备变化订阅。libmpv `audio-device=auto` 在 OS 输出设备
  /// 切换时重建 ao，其软件 `volume` 属性可能被重置/衰减，media_kit 被动把降低值镜像
  /// 进 `state.volume`（[volume] getter 的真值来源）——反复切换设备使视频音量逐步变小
  /// 甚至归零。app 只在 [load] 与用户操作时下发音量、之后从不回补，故必须在设备切换后
  /// 把「音量目标」([_lastVolume] / 静音态) 重新下发（查词音频每次播放都重设绝对音量，
  /// 天然免疫）。**随 [Player] 生命周期挂一次**（首次建 Player 时挂、[dispose] 取消），
  /// 不随换集重挂——`stream.audioDevice` 在 media_kit 内部 `distinct` 去重，首个事件
  /// 回补当前 [_lastVolume]（默认 100）无害，[load] 随后会再设一次。
  StreamSubscription<AudioDevice>? _audioDeviceSub;

  /// 每次 [load] 递增。复用同一个 [Player] 换片时，单靠 player identity 无法区分
  /// 旧媒体的异步章节读取结果；token 让旧 load 的结果可被丢弃。
  int _loadToken = 0;

  String? _bookUid;

  /// 视频文件绝对路径；制卡时按 cue 时间裁字幕音频片段用。
  String? _videoPath;

  /// 当前视频的内封章节列表（TODO-424）；[load] 成功后由 [refreshChapters] 从 libmpv
  /// `chapter-list` 读取填充，无章节 / 非 libmpv 后端时为空。章节面板 / 跳转读它。
  List<VideoChapter> _chapters = const <VideoChapter>[];

  /// 上次持久化时的整秒位置；用于 [_maybeSavePosition] 节流到每秒至多一次。
  int _lastSavedSec = -1;

  /// 恢复 seek 的目标位置（毫秒）；非 null 表示「正在恢复上次进度，seek 尚未落地」。
  ///
  /// media_kit 在 `open(play:false)` 刚返回时 player 常未就绪（position/duration 仍
  /// 为 0），此刻 [load] 发出的 seek 会被丢弃；随后 125ms tick 读到 0 会经
  /// [_maybeSavePosition] 把 **0 持久化、覆盖掉真实进度**，导致「每次进去都回到 0」。
  /// 设此守护后，三个写入点（tick / [flushPosition] / [_forceSavePositionSync]）在
  /// position 追上目标（容差 1.5s）之前一律不写，position 追上后由 [_isRestoringPast]
  /// 清除守护、恢复正常持久化。
  int? _restoreTargetMs;

  /// 恢复守护剩余的宽限观测次数（仅 [_restoreTargetMs] 非空时有意义）。
  ///
  /// 旧实现的守护**只**靠「position 追上目标」清除（[_isRestoringPast]）。但 seek 在
  /// 慢设备 / 大文件 / 软解（Android 尤甚）上可能被 libmpv 丢弃或迟迟不落地：position
  /// 停在 0 附近从头播 → `posMs >= target-1500` 永不成立 → 守护**永久**不清 → 这一程
  /// 用户从头看的每一秒进度全被三个写入点跳过，退出时 [flushPosition] 也被跳过 →
  /// 表现为「安卓视频退出重进既没回到上次位置、这次的进度也没记住」（BUG-179）。
  ///
  /// 修法：给守护加一个**有界宽限**。每次写入点观测到「仍未追上目标」就消耗一格；
  /// 配额耗尽（[_restoreGuardGraceTicks] 格）说明 seek 实际未落地（恢复失败），
  /// 主动**放弃守护**让后续写入恢复正常——宁可这一程从 0 起记，也不再永久吞掉进度。
  /// 追上目标（正常恢复）仍立即清守护，配额不消耗到底。每次 [load] 设守护时重置。
  int _restoreGuardTicksLeft = 0;

  /// 恢复守护的宽限观测次数上限。守护检查 [_isRestoringPast] 由 125ms 周期 tick
  /// （[updateCueForPosition]→[_maybeSavePosition]）驱动，故配额按 tick 计：
  /// 80 次 × 125ms ≈ **10 秒** 仍未追上目标，即判定 seek 落地失败、放弃恢复守护。
  /// 取值需 > [_waitUntilSeekable] 的 5 秒上限，给慢设备留出 open→可 seek→seek 真正
  /// 反映到 position 的余量；退出路径的 [flushPosition]/[_forceSavePositionSync] 也各
  /// 消耗一格，配额宽裕到不会因正常退出误判。
  static const int _restoreGuardGraceTicks = 80;

  /// 「在途 seek 宽限」的 tick 配额上限（[_seekSnapGraceTicksLeft] 充值量）。
  ///
  /// 由 125ms tick（[updateCueForPosition]）消耗。配额需 ≥ media_kit `seek` 从请求到
  /// position 真反映出来的滞后窗口：常见容器关键帧吸附几十~几百 ms，慢设备 / 软解更久。
  /// 取 16 次 × 125ms = **2 秒**——足够覆盖绝大多数 seek 落地延迟，又远小于
  /// [_restoreGuardGraceTicks]（10 秒）：保护只覆盖「这一次跳转的 seek 在途」短瞬，
  /// 真落地后由「首次进入引导窗口」立即作废，不会拖到 2 秒。永不落地时 2 秒后放弃保护。
  static const int _seekSnapGraceTicks = 16;

  /// 普通 seek「落地判据」容差（ms）：播放态下真实 position 到达 `目标 − 本容差` 即判
  /// seek 落定、放行真实位置（普通 seek 无 preRoll、落点≈目标，取 250ms 足够吸收关键帧
  /// 吸附尾差与一拍 tick 推进）。见 [_reconcileSeekInFlightPosition]。
  static const int _kPlainSeekLandToleranceMs = 250;

  /// 位置持久化回调：整秒变化时调用，由上层（repository）落库。
  Future<void> Function(String bookUid, int positionMs)? onPositionWrite;

  /// TODO-1119：疑似「Windows 高显卡占用黑屏闪烁」运行时回调。页面（仅在 Windows）在
  /// [load] 前挂它；null 时**完全不采样**（零开销、零行为变化）。判据在
  /// [_blackFlickerDetector] 里，持续采样 libmpv 迟帧/丢帧计数器（经 getProperty，
  /// 独立于 msg-level 日志级别），连续多秒迟帧率超阈值即回调一次（每控制器生命周期一次）。
  void Function()? onSuspectedBlackFlicker;

  /// TODO-1119：黑闪判据（纯逻辑，见 [VideoBlackFlickerDetector]）。控制器生命周期内
  /// 只触发一次；换片（换集）只复位采样窗基线、不复位「已触发」。
  final VideoBlackFlickerDetector _blackFlickerDetector =
      VideoBlackFlickerDetector();

  /// 上次黑闪采样时刻（节流到 >=1s 一次），null=尚未采样过 / 换片后复位。
  DateTime? _lastFlickerSampleAt;

  /// 黑闪采样异步读属性期间的重入闸（防 125ms tick 叠发多次 getProperty）。
  bool _flickerSampleInFlight = false;

  /// hwdec 是否活跃的缓存（黑闪判据前置条件）：null=未查；查不到时 fail-open 视为活跃。
  bool? _flickerHwdecActive;

  @override
  AudioCue? get currentCue => _currentCue;

  @override
  int get currentCueIndex => _currentCueIndex;

  List<AudioCue> get cues => _cues;

  /// TODO-1312：当前主字幕活动集（重叠 cue 全渲染用）。overlay 据此把同一时刻区间覆盖
  /// 播放位置的所有 cue 竖排堆叠渲染；单条时与 [currentCue] 等价（退化成旧的一个字幕盒）。
  List<AudioCue> get activeCues => <AudioCue>[
        for (final int i in _activeCueIndices)
          if (i >= 0 && i < _cues.length) _cues[i],
      ];

  /// TODO-1312：副字幕全量 cue（诊断 / 测试用）；空 = 无副字幕。
  List<AudioCue> get secondaryCues => _secondaryCues;

  /// BUG-1592：制卡/上下文解析要用的「有效 cue 流」——主字幕流非空即主流，主流为空
  /// （用户把主字幕关掉、只开副字幕）时落到副字幕流。
  ///
  /// 为什么需要它：制卡的区间锚点、上下 N 句上下文历来只认 [cues] 一条流。主字幕关闭时
  /// 该流恒空 → 锚点 null → 制卡区间塌成 `0..0`：句子音频空、封面走 `atSeconds=0.0` 抽出
  /// 片头黑帧（用户报「制卡黑屏」）。副字幕本就是同构的 cue 流（TODO-1312 起与主字幕独立
  /// 求活动集、可逐字符查词），把「唯一的字幕流」这个隐含前提显式化即可，不加特例分支。
  List<AudioCue> get miningCues => _cues.isNotEmpty ? _cues : _secondaryCues;

  /// BUG-1592：[cue] 所属的那条流（按身份判定，主流优先）。两条流都不含它（列表面板的
  /// 合成 cue / 已换集的陈旧 cue）时回 [miningCues]，保持「至少落在当前有效流上」。
  List<AudioCue> cueStreamOwning(AudioCue cue) {
    if (_cues.any((AudioCue c) => identical(c, cue))) return _cues;
    if (_secondaryCues.any((AudioCue c) => identical(c, cue))) {
      return _secondaryCues;
    }
    return miningCues;
  }

  /// TODO-1312：副字幕当前活动集（overlay 副层渲染用，可查词）。
  List<AudioCue> get secondaryActiveCues => <AudioCue>[
        for (final int i in _activeSecondaryCueIndices)
          if (i >= 0 && i < _secondaryCues.length) _secondaryCues[i],
      ];

  VideoController? get videoController => _videoController;

  /// 视频文件绝对路径（制卡裁字幕音频用）；未 [load] 时为空。
  String? get videoPath => _videoPath;

  /// TODO-1000：制卡 ffmpeg 抽取源。本地=videoPath；YouTube 等流媒体用可 seek 的流 URL
  /// 覆盖（[setMiningSourceOverride]），使引擎能从流 URL 按时间戳裁 GIF/音频而不动前台播放器。
  String? _miningSourceOverride;

  /// 覆盖制卡抽取源（YouTube 流 URL 等）；传 null 还原为 [videoPath]。
  void setMiningSourceOverride(String? source) =>
      _miningSourceOverride = source;

  /// 制卡抽取源：优先覆盖源（流 URL），否则本地 [videoPath]。
  String? get miningSource => _miningSourceOverride ?? videoPath;

  /// TODO-1000：YouTube 分离流时视频流无音轨，制卡音频须从 audio-only 流裁。null =
  /// 用 [miningSource]（本地文件/muxed 自带音轨）。
  String? _miningAudioSourceOverride;

  /// 覆盖制卡音频抽取源（YouTube audio-only 流 URL）；传 null = 用 [miningSource]。
  void setMiningAudioSourceOverride(String? source) =>
      _miningAudioSourceOverride = source;

  /// 制卡音频抽取源；null 时引擎回落 [miningSource]。
  String? get miningAudioSource => _miningAudioSourceOverride;

  /// 测试可注入的播放态：widget 测试用的 controller 没有真实 [Player]
  /// （[_player]==null → isPlaying 恒 false），无法驱动「播放中才模糊」
  /// （BUG-199 听力沉浸）等以 [isPlaying] 为闸的逻辑。置非 null 时覆盖。
  bool? _debugIsPlayingOverride;

  /// 测试可见：模拟播放/暂停态（驱动字幕沉浸模糊门控等）。传 null 还原真实来源。
  @visibleForTesting
  void debugSetIsPlayingForTesting(bool? playing) {
    _debugIsPlayingOverride = playing;
    notifyListeners();
  }

  @override
  bool get isPlaying =>
      _debugIsPlayingOverride ?? (_player?.state.playing ?? false);

  /// 后台抽取/解析内封文本字幕 cue 是否仍在进行。
  bool get isSubtitleCuesLoading => _subtitleCuesLoading;

  /// 绑定媒体自然播放完毕后的回调。页面必须在 [load] 前设置，避免 EOF 竞态。
  void setOnCompleted(VoidCallback? callback) {
    _onCompleted = callback;
  }

  /// 当前播放位置（毫秒）；未 [load] 时为 null。换集前用它补记当前集精确进度
  /// （tick 整秒节流外的尾差）。
  @override
  int? get positionMs =>
      _debugPositionOverride ?? _player?.state.position.inMilliseconds;

  /// 测试可注入的播放位置（毫秒）：widget 测试无真实 [Player]（[positionMs] 恒 null），
  /// 无法驱动 `\fad`/`\fade` 按位置逐帧求不透明度。置非 null 时覆盖 [positionMs]（并经
  /// [_effectivePositionMs] 流入字幕淡变）。传 null 还原真实来源。
  int? _debugPositionOverride;

  @visibleForTesting
  void debugSetPositionForTesting(int? positionMs) {
    _debugPositionOverride = positionMs;
    notifyListeners();
  }

  int? get _effectivePositionMs {
    final int? pos = positionMs;
    return pos == null ? null : effectiveSubtitlePositionMs(pos, _delayMs);
  }

  /// 音画延迟校正后的等效播放位置（毫秒）；字幕 `\fad`/`\fade` 求「cue 内已播放时长」
  /// 用（= 本值 − cue.startMs）。未 [load] / 无位置时为 null。
  int? get effectivePositionMs => _effectivePositionMs;

  /// 测试可见：模拟媒体总时长（毫秒，驱动 seek bar 章节刻度按 start/duration 算比例，
  /// TODO-432）。传 null 还原真实来源（`_player.state.duration`）。
  @visibleForTesting
  void debugSetDurationForTesting(int? durationMs) {
    _debugDurationOverride = durationMs;
    notifyListeners();
  }

  int? _debugDurationOverride;

  /// 媒体总时长（毫秒）；未 [load] / 未解析媒体头时为 null。
  @override
  int? get durationMs =>
      _debugDurationOverride ?? _player?.state.duration.inMilliseconds;

  /// 测试注入的视频分辨率（widget 测试无真实解码帧；BUG-820 让 overlay 的
  /// 视频内容矩形几何可测）。生产恒 null。
  @visibleForTesting
  int? debugVideoWidthOverride;
  @visibleForTesting
  int? debugVideoHeightOverride;

  /// 视频原始分辨率（字幕 `\pos` letterbox 映射 + BUG-820 字号/描边缩放基准用）；
  /// 未解码时为 null。
  int? get videoWidth => debugVideoWidthOverride ?? _player?.state.width;
  int? get videoHeight => debugVideoHeightOverride ?? _player?.state.height;

  /// TODO-1276：首帧是否已解码出画（[videoWidth]/[videoHeight] 均为正）。
  ///
  /// 页面据此在**首开**时把页级加载态保持到首帧真正就绪再挂载 [Video]，杜绝页级
  /// 加载圈与 media_kit 自带缓冲圈接力显示成「转两次圈」（页级圈在 surface 底、
  /// media_kit 圈在纯黑底，用户看到转圈消失又出现）。libmpv 在 [VideoController]
  /// 创建后即向纹理解码出帧，宽高流就绪早于 Flutter 侧 [Video] 挂载，故此判据可靠。
  bool get hasFirstFrame => framePresent(videoWidth, videoHeight);

  /// 纯函数：宽高均为非空正数即视为首帧已出画。抽出便于守卫测试
  /// （media_kit 视频无法离屏跑，只能测这层判据逻辑）。
  @visibleForTesting
  static bool framePresent(int? width, int? height) =>
      width != null && width > 0 && height != null && height > 0;

  /// libmpv 当前是否处于缓冲态（`core-idle` / `paused-for-cache`）。media_kit 的
  /// 缓冲圈据同一 `player.state.buffering` 渲染，此处读同一真值让页面的首开就绪判据
  /// 与之对齐。未 [load]（无 player）时视为非缓冲。
  bool get isBuffering => _player?.state.buffering ?? false;

  /// TODO-1297：首帧解码出画**且**已不再缓冲——「首开可挂载 [Video]」的完整就绪判据。
  ///
  /// TODO-1276 只用 [hasFirstFrame]（宽高解码出画）当就绪判据，但**首帧已解码 != 可稳定
  /// 起播**：网络流常在解码出首帧（宽高就绪，[hasFirstFrame] 翻真）时仍在缓冲
  /// （`paused-for-cache`），页面据 [hasFirstFrame] 提前挂载 [Video] 后，media_kit
  /// 自带缓冲圈接着盖住画面——正是 TODO-1276 想消除的「第二个圈」，而进度条的
  /// 已缓冲填充（`demuxer-cache-time`）此刻已可见，用户看到「进度条显示已经缓冲了、
  /// 但还在加载」（TODO-1297）。故首开就绪必须叠加 [isBuffering] 取反：让 Hibiki 页级
  /// 上下文加载层（[VideoLoadingOverlay]，带返回按钮、绝不困死用户）覆盖整个
  /// 解码 + 缓冲窗口，直到有稳定帧且缓冲结束再让位给 media_kit，杜绝冗余第二个圈。
  bool get isReadyForFirstPaint =>
      readyForFirstPaint(videoWidth, videoHeight, isBuffering);

  /// 纯函数：首帧已出画且未在缓冲即视为首开可挂载。抽出便于守卫测试
  /// （media_kit 视频无法离屏跑，只能测这层判据逻辑）。
  @visibleForTesting
  static bool readyForFirstPaint(int? width, int? height, bool buffering) =>
      framePresent(width, height) && !buffering;

  /// 当前音画延迟（毫秒）；设置面板显示用。
  int get delayMs => _delayMs;

  /// 当前播放倍速；未 [load] 时回退最近一次 [setSpeed] 之值（构造默认 1.0）。
  double get speed => _player?.state.rate ?? _lastSpeed;

  double get volume => _player?.state.volume ?? _lastVolume;

  bool get muted => _muted;

  /// 当前 mpv 视频亮度（libmpv `brightness` 属性，-100..100，0=原始）。桌面左半区
  /// 竖拖手势在系统屏幕亮度不可控时改写它（TODO-754）。
  int get videoBrightness => _videoBrightness;

  /// 设置 mpv 视频亮度（libmpv `brightness` 属性，[value] clamp 到 -100..100）。
  ///
  /// 经 `player.platform`（NativePlayer）的 `setProperty` 下发，与
  /// [applyMpvConfigToPlayer] / [applySubtitleMpvPropertiesToPlayer] 同范式：非 libmpv
  /// 后端（无 `setProperty`）/ 属性不被接受时 best-effort 静默吞掉，不影响播放。写成
  /// 功能记入 [_videoBrightness] 供 getter 回读；未 [load] 时只记目标值。
  Future<void> setVideoBrightness(int value) async {
    final int clamped = value.clamp(-100, 100);
    _videoBrightness = clamped;
    final dynamic native = _player?.platform;
    if (native == null) return;
    try {
      await native.setProperty('brightness', clamped.toString());
    } catch (_) {
      // 非 libmpv / 属性不支持运行时设置：best-effort no-op（与配置/字幕属性同纪律）。
    }
  }

  /// 截取当前解码帧为 JPEG 字节（制卡截图用）。未 [load] 返回 null。
  Future<Uint8List?> screenshot() async {
    return _player?.screenshot(format: 'image/jpeg');
  }

  /// 当前视频可用的字幕轨（含内嵌轨）；未 [load] 时为空。
  ///
  /// 为运行时切换 + Phase 1 内嵌字幕功能预留；无法纯单测（需真实 libmpv
  /// player），靠 analyze 验证编译。
  List<SubtitleTrack> get subtitleTracks =>
      _player?.state.tracks.subtitle ?? const <SubtitleTrack>[];

  /// 当前选中字幕轨声明的语言（BCP-47 / ISO-639，视打包者而定）。没有轨、轨未声明
  /// 语言、或值是 mpv 的占位（`und` / `auto` / `no`）时返回 null。
  ///
  /// 用途：字幕字体链的第二档真值（用户对本视频手动指定 > **这里** > 全局默认）。
  /// 内嵌轨的 language 常被打包者写错或干脆不写，外挂 SRT 更是基本没有，所以它只能
  /// 当线索用，不能当唯一依据——这正是 VideoBooks.language 手动指定存在的理由。
  String? get currentSubtitleLanguage {
    final String? language = _player?.state.track.subtitle.language?.trim();
    if (language == null || language.isEmpty) return null;
    const Set<String> placeholders = <String>{'und', 'auto', 'no', 'unknown'};
    if (placeholders.contains(language.toLowerCase())) return null;
    return language;
  }

  /// 切换字幕轨（运行时 / Phase 1 预留）。未 [load] 时 no-op 安全。
  Future<void> selectSubtitleTrack(SubtitleTrack track) async {
    // 关字幕 / 切到文本 overlay 都经 `no()`（图形轨改走 [selectEmbeddedGraphicTrack]
    // 的裸 `player.setSubtitleTrack`，不经此处）→ 离开图形渲染，复位图形标志（BUG-301）。
    // 这是纯 Dart 同步状态，与 await 后的原生下发无关：必须在 player 空判 / await 之前
    // 无条件执行，否则未 [load] 时关字幕不复位标志（回归 BUG-301）。
    if (track.id == 'no') _graphicSubtitleActive = false;
    final Player? player = _player;
    if (player == null) return; // 未 load：原生下发 no-op，标志已复位即可。
    // 关字幕（`no()`）是高频路径（[_selectSubtitleOff]）：await libmpv 原生下发期间用户
    // 随时可能退出页面 / 换集，触发 [dispose]（`_loadToken++` + `unawaited(_player.dispose())`
    // 异步释放底层 libmpv NativePlayer + `_player = null`）。若仍向这里捕获的局部 [player]
    // 引用（已释放 / 已被新 load 接管的 handle）下发 setSubtitleTrack，就是原生
    // use-after-free（访问违例，AMD 更敏感）。与 [selectEmbeddedGraphicTrack] / [load]
    // 一致：await 前捕获 loadToken 快照，await 后用 [_isCurrentLoad] 双判据
    // （player identity + loadToken）重校验，过期立即放弃（TODO-409）。
    final int loadToken = _loadToken;
    await player.setSubtitleTrack(track);
    if (!_isCurrentLoad(player, loadToken)) return; // await 期间换片/销毁：放弃下发。
  }

  /// 把内嵌**图形**字幕轨（PGS/DVD 等位图，无法转文本 cue）交给 libmpv 当画面字幕
  /// 渲染——用户看得到字幕（不可逐字查词，BUG-122 选定的兜底）。
  ///
  /// [streamIndex] 是 ffmpeg `-map 0:s:N` 的相对序号，映射到 libmpv
  /// `tracks.subtitle`（`[auto, no, real0, real1…]` demux 顺序，去 auto/no 后第 N
  /// 条，与 [currentAudioStreamIndex] 同范式）。等字幕轨列表就绪后选轨并清空可点
  /// overlay（图形轨无文本）。选中返回 true；未 [load] / 轨未就绪 / 序号越界返回
  /// false（调用方据此提示失败）。
  Future<bool> selectEmbeddedGraphicTrack(int streamIndex) async {
    final Player? player = _player;
    if (player == null) return false;
    // 图形轨就绪等待最长 5s（[_waitUntilSubtitleTracksReady]），其后还有 3 次连续
    // 的原生下发（[setSubtitleTrack] + 两次 [applySubtitleMpvPropertiesToPlayer]）。
    // 这段窗口里用户随时可能退出页面 / 换集，触发 [dispose]（`_loadToken++` +
    // `unawaited(_player.dispose())` 异步释放底层 libmpv NativePlayer）。若仍用这里
    // 捕获的局部 [player] 引用向已释放 handle 下发 setProperty/setSubtitleTrack，就是
    // 原生 use-after-free（访问违例）。与本文件其它异步 mpv 路径
    // （[load] / [_refreshChaptersForLoad] 等）一致，**每个 await 后都用
    // [_isCurrentLoad] 双判据（player identity + loadToken）重校验**，过期立即放弃下发。
    final int loadToken = _loadToken;
    // 等**目标序号那条轨**解析就绪（不是「任意一条」），否则容器多轨逐条异步解析时
    // 越界早退放弃（TODO-1295 同款竞态，与副字幕一致）。
    await _waitUntilSubtitleTracksReady(player, minTrackCount: streamIndex + 1);
    if (!_isCurrentLoad(player, loadToken)) return false; // 等待期间换片/销毁。
    final List<SubtitleTrack> real = player.state.tracks.subtitle
        .where((SubtitleTrack t) => t.id != 'auto' && t.id != 'no')
        .toList(growable: false);
    if (streamIndex < 0 || streamIndex >= real.length) return false;
    // 图形字幕走 libmpv 画面渲染，清掉可点 overlay（无文本可查词）。
    setCues(const <AudioCue>[]);
    await player.setSubtitleTrack(real[streamIndex]);
    if (!_isCurrentLoad(player, loadToken)) return false; // 选轨后换片/销毁。
    // 图形 PGS 轨是 BUG-190 字幕抑制（sub-visibility=no）的唯一例外：位图字幕没有文本
    // cue，只能靠 libmpv 画面渲染。显式打开 sub-visibility=yes 覆盖 load 时设的 no，
    // 否则用户选了图形字幕却看不到（回归 BUG-122）。sub-auto 仍保持 no（轨由这里显式
    // 选定，不交给 mpv 自动选）。
    await applySubtitleMpvPropertiesToPlayer(
      player,
      buildGraphicSubtitleVisibilityProperties(),
    );
    if (!_isCurrentLoad(player, loadToken)) return false; // 设可见性后换片/销毁。
    // 进入图形轨渲染：标记图形模式，并把当前字幕调轴（[_delayMs]）下发到 libmpv
    // `sub-delay`——否则图形字幕忽略 Dart 侧 cue 偏移，调轴滑条对它无效（BUG-301）。
    _graphicSubtitleActive = true;
    await applySubtitleMpvPropertiesToPlayer(
      player,
      buildSubtitleDelayProperty(_delayMs),
    );
    return true;
  }

  /// 真实字幕轨（去掉 libmpv 的 `auto`/`no` 伪轨）条数。按 ffmpeg `0:s:N` 的
  /// demux 顺序索引第 N 条时用它判「目标序号已解析就绪」
  /// （[selectEmbeddedGraphicTrack] 的越界判据）。
  static int _realSubtitleCount(List<SubtitleTrack> subs) =>
      subs.where((SubtitleTrack t) => t.id != 'auto' && t.id != 'no').length;

  /// 等 [player] 的字幕轨列表解析出**至少 [minTrackCount] 条**真实轨（`open` 后
  /// 解析容器需要时间）。最多等 5 秒；已就绪立即返回，超时尽力继续（调用方自行判越界）。
  ///
  /// **TODO-1295 根因**：容器多条内嵌字幕轨是 `player.open` 后**逐条异步**解析的。
  /// 旧实现只要「任意一条」真实轨就绪就早退（`minTrackCount` 恒等于 1），选副字幕
  /// （第 2 条，`streamIndex=1`）时若这一刻只解析出第 1 条，`real.length==1`、
  /// `streamIndex >= real.length` 越界，按 index 选轨（如图形轨
  /// [selectEmbeddedGraphicTrack]）一次性放弃下发。故按 index 选轨的路径改传
  /// `minTrackCount: streamIndex + 1`，等到**目标序号那条轨真正解析就绪**（或超时）
  /// 才继续，消除「越界早退」竞态。默认 `minTrackCount = 1` 保持其它调用者（默认文本
  /// 字幕加载 [_loadEmbeddedSubtitleIfNeeded]）的「任意一条即可」旧行为不变。
  Future<void> _waitUntilSubtitleTracksReady(
    Player player, {
    int minTrackCount = 1,
  }) async {
    await waitForSubtitleTrackCount(
      currentRealCount: () => _realSubtitleCount(player.state.tracks.subtitle),
      changes: player.stream.tracks,
      minTrackCount: minTrackCount,
    );
  }

  /// [_waitUntilSubtitleTracksReady] 的纯就绪等待内核（可单测，不依赖真 libmpv）。
  ///
  /// 事件驱动：订阅 [changes]（每次字幕轨列表变化都会发一次），每次醒来用
  /// [currentRealCount] 复读**当前**真实轨数，直到 `>= [minTrackCount]` 立即完成；
  /// 最多等 [timeout]（默认 5s，明确的超时上界，不是硬延迟）。返回 true＝目标轨数
  /// 就绪，false＝超时仍不足（调用方据此按 `real.length` 越界返回 false）。
  ///
  /// **闭合 check-then-subscribe 竞态**：初始检查与 `listen` 注册之间轨列表可能已
  /// 增长（此后不再有新事件）。`state.tracks` 恒为当前值，故 `listen` 之后**立即
  /// 再复读一次**即可闭合竞态，无需轮询。
  @visibleForTesting
  Future<bool> waitForSubtitleTrackCount({
    required int Function() currentRealCount,
    required Stream<Object?> changes,
    required int minTrackCount,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (currentRealCount() >= minTrackCount) return true;
    final Completer<bool> ready = Completer<bool>();
    void checkReady() {
      if (!ready.isCompleted && currentRealCount() >= minTrackCount) {
        ready.complete(true);
      }
    }

    final StreamSubscription<Object?> sub =
        changes.listen((Object? _) => checkReady());
    checkReady(); // 复读闭合 check-then-subscribe 竞态。
    try {
      return await ready.future.timeout(timeout);
    } on TimeoutException {
      return currentRealCount() >= minTrackCount;
    } finally {
      await sub.cancel();
    }
  }

  /// 当前视频可用的音轨；未 [load] 时为空。
  List<AudioTrack> get audioTracks =>
      _player?.state.tracks.audio ?? const <AudioTrack>[];

  /// 切换音轨。未 [load] 时 no-op 安全。
  Future<void> selectAudioTrack(AudioTrack track) async {
    await _player?.setAudioTrack(track);
  }

  /// 当前选中音轨在「真实音轨列表」中的 0-based 序号（ffmpeg `-map 0:a:<idx>`
  /// 的 ordinal），用于制卡时把字幕音频片段裁到用户正在听的那条轨。
  ///
  /// libmpv 的 `tracks.audio` 是 `[auto, no, real0, real1…]`（demux 顺序），与
  /// ffmpeg `0:a:N` 的音频流顺序一致；当前选中轨取 `state.track.audio`。返回值是
  /// 选中轨在「去掉 auto/no 后的真实轨」里的下标。
  ///
  /// 返回 null 表示「跟随默认」（未选过具体轨，selected 为 auto/no，或单音轨视频）
  /// ——此时 ffmpeg 不加 `-map`，用其默认音频选择，与既有行为一致。
  int? get currentAudioStreamIndex {
    final Player? player = _player;
    if (player == null) return null;
    final AudioTrack selected = player.state.track.audio;
    if (selected.id == 'auto' || selected.id == 'no') return null;
    final List<AudioTrack> real = player.state.tracks.audio
        .where((AudioTrack t) => t.id != 'auto' && t.id != 'no')
        .toList(growable: false);
    // 单条真实轨时无需显式映射（ffmpeg 默认就选它），返回 null 保持简单。
    if (real.length <= 1) return null;
    final int idx = real.indexWhere((AudioTrack t) => t.id == selected.id);
    return idx < 0 ? null : idx;
  }

  /// 真实音轨（去掉 libmpv 的 auto/no 伪轨）条数；未 [load] 时为 0。
  ///
  /// 用作 ffmpeg `-map 0:a:N` 的下标上界（`N < count`）：mpv 把外挂音频也算进
  /// `tracks.audio`，其轨序号未必与 ffmpeg 容器内 `0:a:N` 一致，越界会让
  /// ffmpeg `Stream map matches no streams` 硬失败；裁剪前用此条数做边界校验，
  /// 越界则不加 `-map` 回退默认轨（BUG-345）。
  int get realAudioStreamCount {
    final Player? player = _player;
    if (player == null) return 0;
    return player.state.tracks.audio
        .where((AudioTrack t) => t.id != 'auto' && t.id != 'no')
        .length;
  }

  /// 设置 cue 列表：拷贝并按 startMs 升序排序（[JsonAlignmentParser.findCueIndex]
  /// 要求升序），重置当前 cue 状态。
  void setCues(List<AudioCue> cues) {
    _cues = List<AudioCue>.of(cues)
      ..sort((AudioCue a, AudioCue b) => a.startMs.compareTo(b.startMs));
    // 非空文本 cue → 切到可点 overlay 文本字幕，离开图形轨渲染（BUG-301）。空 cue
    // 不在此推断模式：可能是图形轨（[selectEmbeddedGraphicTrack] 先清空 cue 再选轨置
    // true）或无字幕段，故只在确有文本 cue 时复位图形标志。
    if (cues.isNotEmpty) _graphicSubtitleActive = false;
    _currentCue = null;
    _currentCueIndex = -1;
    // TODO-1312：换主 cue 列表复位活动集（旧下标对新 [_cues] 已失效、会越界）。
    _activeCueIndices = const <int>[];
    // 换字幕/换片（[load] 经此）复位主动跳转目标快照 + 在途 seek 宽限：旧目标下标对新
    // _cues 已失效，留着会让首个 tick 误 snap（TODO-565）。
    _clearSeekTargetSnap();
    // 同理复位一次性「只播这一句就停」请求与句尾防重复停记号：两者都是**旧 _cues 的
    // 下标**，对新列表已无意义，留着会让新片的某句被无缘无故停一次。
    _oneShotHoldCueIndex = null;
    _lastSubtitleEndPauseCueIndex = null;
    notifyListeners();
  }

  /// TODO-1312：设置**副字幕** cue 列表：拷贝并按 startMs 升序排序，复位副字幕活动集。
  /// 副字幕与主字幕独立、同一 effective 位置各自求活动集，一起交给 Flutter overlay 多层
  /// 渲染（不再走 libmpv `secondary-sid`）——副字幕因此也可逐字符查词。空列表 = 无副字幕。
  void setSecondaryCues(List<AudioCue> cues) {
    _secondaryCues = List<AudioCue>.of(cues)
      ..sort((AudioCue a, AudioCue b) => a.startMs.compareTo(b.startMs));
    _activeSecondaryCueIndices = const <int>[];
    notifyListeners();
  }

  /// TODO-1312：关闭副字幕（清空副字幕 cue 流 + 活动集）。幂等：本就无副字幕时不通知。
  void clearSecondaryCues() {
    if (_secondaryCues.isEmpty && _activeSecondaryCueIndices.isEmpty) return;
    _secondaryCues = <AudioCue>[];
    _activeSecondaryCueIndices = const <int>[];
    notifyListeners();
  }

  /// 设置副字幕独立调轴（毫秒，TODO-2837）。null = 清除独立值、回到跟随主字幕
  /// [_delayMs]；非 null clamp 到 ±600000（与 [setDelayMs] 同界）。
  ///
  /// 与 [setDelayMs] 的 BUG-373 同理：改完**立即按当前位置重算活动集并通知**，
  /// 暂停定格微调也即时反馈、不等 125ms tick。副字幕恒为 Dart 文本 cue 流，无
  /// libmpv `sub-delay` 参与（图形轨只存在于主字幕），故无需碰 player。
  void setSecondaryDelayMs(int? delayMs) {
    _secondaryDelayMs = delayMs?.clamp(-600000, 600000);
    final int? pos = positionMs;
    if (pos == null) return;
    _syncCueForPosition(pos, persistPosition: false);
  }

  /// 副字幕独立调轴原始值；null = 跟随主字幕（未单独设置）。
  int? get secondaryDelayMs => _secondaryDelayMs;

  /// 副字幕**生效**调轴（毫秒）：独立值优先，未设置时跟随主字幕 [_delayMs]。
  /// 副字幕活动集求解 / 制卡逆变换 / 片段字幕导出的共享真相源。
  int get effectiveSecondaryDelayMs => _secondaryDelayMs ?? _delayMs;

  /// [miningCues]（BUG-1592 有效 cue 流）对应的生效调轴：主流非空用主轨
  /// [_delayMs]，主流为空落副字幕流时用 [effectiveSecondaryDelayMs]。制卡按位置
  /// 解析锚点 / 裁剪逆变换必须与该流的 cue 命中同一根时间轴（TODO-2837）。
  int get miningDelayMs =>
      _cues.isNotEmpty ? _delayMs : effectiveSecondaryDelayMs;

  /// [cue] 所属流的生效调轴（按身份判定，镜像 [cueStreamOwning]）：主流 cue 用
  /// [_delayMs]、副流 cue 用 [effectiveSecondaryDelayMs]；两条流都不含它（列表
  /// 面板的合成 cue / 已换集的陈旧 cue）时回 [miningDelayMs]（与
  /// [cueStreamOwning] 的兜底同一口径）。
  int delayMsForCue(AudioCue cue) {
    if (_cues.any((AudioCue c) => identical(c, cue))) return _delayMs;
    if (_secondaryCues.any((AudioCue c) => identical(c, cue))) {
      return effectiveSecondaryDelayMs;
    }
    return miningDelayMs;
  }

  /// [cue] 所属流的**调轴校正后等效位置**（毫秒；未 [load] / 无位置时 null）。
  /// 字幕 overlay 的 ASS 动画（`\fad`/`\move`/`\t`）求「cue 内已播放时长」用——
  /// 副字幕独立调轴后主副两条流的等效时间轴可以不同，按 cue 分流取轴
  /// （TODO-2837；主轨等价于旧 [effectivePositionMs]）。
  int? effectivePositionMsForCue(AudioCue cue) {
    final int? pos = positionMs;
    if (pos == null) return null;
    return effectiveSubtitlePositionMs(pos, delayMsForCue(cue));
  }

  /// 设置音画延迟（毫秒），clamp 到 ±600000（±10 分钟）。
  ///
  /// 文本字幕（可点 overlay）的偏移由 [effectiveSubtitlePositionMs] 在 Dart 侧扣减
  /// 位置，无需碰 libmpv；图形内封字幕（PGS 等，[_graphicSubtitleActive]）由 libmpv
  /// 画面渲染，必须把延迟下发到 `sub-delay` 才生效（BUG-301）。非图形模式显式写
  /// `sub-delay=0` 复位，防上一段图形轨残留的 `sub-delay` 错位后续文本/无字幕渲染。
  ///
  /// BUG-373：文本字幕调延迟后**立即按当前位置重算当前 cue 并 [notifyListeners]**，
  /// 而非等下一个 125ms tick。否则暂停定格看一句字幕微调时，调整完要等 tick 才生效
  /// （暂停态连 tick 都不推进，更明显），表现为「调了没反馈」。重算用 [_syncCueForPosition]
  /// 且 `persistPosition: false`（调延迟不该触发位置持久化）。图形字幕走 libmpv `sub-delay`
  /// 即时渲染，不需要 Dart 侧重算。
  void setDelayMs(int delayMs) {
    _delayMs = delayMs.clamp(-600000, 600000);
    final Player? player = _player;
    if (player == null) return;
    unawaited(applySubtitleMpvPropertiesToPlayer(
      player,
      buildSubtitleDelayProperty(_subtitleDelayMpvMs),
    ));
    _resyncTextSubtitleAfterDelayChange(positionMs);
  }

  /// BUG-373：调延迟后对**文本字幕**立即按 [positionMs] 重算当前 cue 并 [notifyListeners]，
  /// 让正显示的字幕同帧按新偏移刷新，而非等下一个 125ms tick。图形字幕（libmpv `sub-delay`）
  /// 即时渲染、无需 Dart 侧重算，故 [_graphicSubtitleActive] 时跳过；[positionMs] 为 null
  /// （未 load）时无可重算位置，跳过。`persistPosition: false`：调延迟不应触发位置持久化。
  /// 是 [setDelayMs] 与单测 [debugSetDelayMsForTesting] 的共享重算真相源（DRY）。
  void _resyncTextSubtitleAfterDelayChange(int? positionMs) {
    if (_graphicSubtitleActive) return;
    if (positionMs == null) return;
    _syncCueForPosition(positionMs, persistPosition: false);
  }

  /// 测试钩子（BUG-373）：在**不实例化 [Player]**（宿主无 libmpv，[positionMs] 读不到）
  /// 的前提下，模拟真实 [setDelayMs] 改延迟后的文本字幕即时重算——设 [_delayMs] 后按显式
  /// 传入的 [positionMs] 跑与 [setDelayMs] **完全同一条** [_resyncTextSubtitleAfterDelayChange]
  /// 路径，供单测断言「暂停定格调延迟，当前 cue 立即按新偏移变化」。
  @visibleForTesting
  void debugSetDelayMsForTesting(int delayMs, {required int positionMs}) {
    _delayMs = delayMs.clamp(-600000, 600000);
    _resyncTextSubtitleAfterDelayChange(positionMs);
  }

  /// 下发到 libmpv `sub-delay` 的延迟（毫秒）。图形内封字幕走 libmpv 画面渲染，用
  /// 真实 [_delayMs]；文本字幕（可点 overlay）偏移已在 Dart 侧扣减，故 `sub-delay`
  /// 必须为 0（显式复位，防图形轨残留）。是 [setDelayMs] /
  /// [selectEmbeddedGraphicTrack] 决策与单测的共享真相源（BUG-301）。
  int get _subtitleDelayMpvMs => _graphicSubtitleActive ? _delayMs : 0;

  /// 当前启用的着色器绝对路径（设置界面回显用）。
  List<String> get shaderPaths => List<String>.unmodifiable(_shaderPaths);

  /// 运行时切换 mpv 着色器（设置面板 toggle 即时生效）。未 [load]（无 player）时只记下，
  /// 下次 [load] 应用。五平台 libmpv 后端均生效（移动端走 vo=gpu 渲染路径，非 no-op；
  /// 见 [applyShadersToPlayer] doc 的 media_kit 源码出处）；仅非 libmpv 后端 no-op。
  Future<void> applyShaders(List<String> absolutePaths) async {
    _shaderPaths = List<String>.of(absolutePaths);
    _shadersBypassed = false; // 改动启用集即恢复非旁路，按新集生效。
    final Player? player = _player;
    if (player == null) return;
    await applyShadersToPlayer(player, _shaderPaths);
  }

  /// 本 Player 实例已装载的 Lua 脚本绝对路径。mpv 无 unload-script，重复
  /// `load-script` 会实例化第二份脚本，故装载必须每 Player 实例幂等（见
  /// video_lua_script_manager.dart 文件头）。
  ///
  /// 去重集的作用域是**单个 Player 实例**，不是 controller：controller 存活期间
  /// Player 会被销毁重建（[_releaseMediaHandles] 为 TODO-1212 数据根迁移放句柄时
  /// `dispose` 掉旧 Player 并置 null，下次 [load] 在 `_player ?? Player()` 处建新的）。
  /// 若不随之清空，新 Player 会因「路径已在集合里」一条 `load-script` 都不发，脚本
  /// 静默失效直到退出重进视频页。故 Player 置 null 的每一处都必须 clear（对照：
  /// 着色器与 mpv 配置是无条件重发的，只有 Lua 走去重，漏清就是静默失效）。
  final Set<String> _loadedLuaScripts = <String>{};

  /// 装载 mpv Lua 脚本（设置面板开启开关 / [load] 均走此入口）。幂等：已装载
  /// 的路径跳过；未 [load]（无 player）时 no-op——脚本随下次 [load] 由页面
  /// 重新解析传入。关闭开关无法从运行中的实例卸载，只对之后新建的 Player 生效。
  Future<void> applyLuaScripts(List<String> absolutePaths) async {
    final Player? player = _player;
    if (player == null) return;
    final List<String> fresh = <String>[
      for (final String path in absolutePaths)
        if (_loadedLuaScripts.add(path)) path,
    ];
    if (fresh.isEmpty) return;
    await applyLuaScriptsToPlayer(player, fresh);
  }

  /// 着色器「对比原画」旁路态：true 时临时清空 libmpv 着色器（看原画），但**保留**
  /// 启用集 [_shaderPaths]，恢复时一键贴回。供效果对比用（B：缺效果预览/对比）。
  bool _shadersBypassed = false;
  bool get shadersBypassed => _shadersBypassed;

  /// 切换/设置着色器旁路（对比原画）。不改启用集，只切实际喂给 libmpv 的集合。
  /// 返回切换后的旁路态。无 player 时也记下，下次 [load] 据 [_shadersBypassed] 应用。
  Future<bool> setShaderBypass(bool bypass) async {
    _shadersBypassed = bypass;
    final Player? player = _player;
    if (player != null) {
      await applyShadersToPlayer(
        player,
        bypass ? const <String>[] : _shaderPaths,
      );
    }
    return _shadersBypassed;
  }

  /// 旁路态翻转（对比按钮/快捷键用）。
  Future<bool> toggleShaderBypass() => setShaderBypass(!_shadersBypassed);

  /// 运行时应用 mpv 配置（设置面板改动即时生效）。未 [load] 时只记下，下次 [load]
  /// 应用。五平台 libmpv 后端均生效；仅非 libmpv 后端 / 不支持的属性静默 no-op。
  Future<void> applyMpvConfig(VideoMpvConfig config) async {
    _mpvConfig = config;
    final Player? player = _player;
    if (player == null) return;
    await applyMpvConfigToPlayer(player, config);
  }

  /// 加载视频并开始播放准备：实例化 [Player] / [VideoController]、打开视频、
  /// 可选挂载外挂字幕、设置初速、seek 到初始位置、订阅播放态、启动 125ms tick。
  ///
  /// 测试宿主无 libmpv，**不要在单测里调用**（会因 `new Player()` 抛）。
  Future<void> load({
    required String bookUid,
    File? videoFile,
    String? mediaUri,
    required List<AudioCue> cues,
    int initialPositionMs = 0,
    required EpisodeStartIntent startIntent,
    double initialSpeed = 1.0,
    double initialVolume = 100.0,
    String? externalSubtitlePath,
    bool subtitleExplicitlyOff = false,
    int? renderGraphicStreamIndex,
    List<String> shaderPaths = const <String>[],
    List<String> luaScriptPaths = const <String>[],
    VideoMpvConfig mpvConfig = VideoMpvConfig.defaults,
    Map<String, String> httpHeaderFields = const <String, String>{},
    bool autoPlay = false,
    // TODO-1280：YouTube 等分离流（video-only 主流 + audio-only 外挂）的 audio-only 流 URL。
    // 必须在本次 load 内、恢复 seek + play() **之前**经 `audio-add ... select` 外挂，libmpv
    // 才会让它随首个 seek / 起播与视频时间轴同步；若等 load 返回后再挂（play 已开始），新加的
    // 音频 demuxer 从 0 起、不会自动 seek 到当前位置 → 无声，直到用户手动 seek 才重同步。null =
    // 无分离音轨（本地文件 / muxed 自带音轨）。
    String? externalAudioTrackUrl,
    void Function(DefaultEmbeddedSubtitleLoadResult result)?
        onEmbeddedSubtitleAutoLoad,
  }) async {
    assert(
      (videoFile == null) != (mediaUri == null),
      'Provide exactly one of videoFile or mediaUri.',
    );
    final int loadToken = ++_loadToken;
    _bookUid = bookUid;
    _videoPath = videoFile?.path;
    final String sourceUri = mediaUri ?? mediaUriForVideoPath(videoFile!.path);
    debugPrint('[video-load] cues=${cues.length} uri=$sourceUri');
    // TODO-1312：换片复位副字幕 cue 流（旧下标对新片失效；新集副字幕由页面
    // _restoreSecondarySubtitle 重挂）。在 setCues 之前复位，让 setCues 的单次
    // notify 已反映清空后的副字幕状态。
    _secondaryCues = <AudioCue>[];
    _activeSecondaryCueIndices = const <int>[];
    setCues(cues);
    _clearChaptersForNewLoad();
    // 换片（复用 player）复位图形字幕标志：新片默认非图形轨，仅当下面
    // [renderGraphicStreamIndex] 触发的 [selectEmbeddedGraphicTrack] 成功才重新置 true。
    // 这样复用 player 时上一段视频的图形轨 `sub-delay` 不会残留到新片（BUG-301）。
    // 不依赖 setCues(空) 复位——空 cue 也可能是图形轨场景。
    _graphicSubtitleActive = false;

    // 重复 load（换集）：取消上一次的 tick / 订阅，但**复用同一 Player /
    // VideoController**，不 dispose 重建。复用是关键（BUG-120）——media_kit 全屏是推到
    // 根 navigator 的独立路由，绑定的是「进入全屏那一刻」的 VideoController 实例；若每次
    // 换集 dispose+new VideoController，全屏路由仍绑在旧（已 dispose）实例上 → 全屏换集
    // 黑屏、00:00（退全屏看窗口侧新实例才正常）。复用后只 player.open 换片，全屏路由始终
    // 绑同一实例 → 新视频正常渲染；也是 media_kit 切播放列表的正规姿势。
    _tick?.cancel();
    _tick = null;
    // TODO-1119：换片复位黑闪采样窗基线（新片计数器从头；不复位「已触发」——每控制器
    // 生命周期只提示一次，换集不再重复弹）。
    _blackFlickerDetector.resetWindows();
    _lastFlickerSampleAt = null;
    _flickerHwdecActive = null;
    await _playingSub?.cancel();
    _playingSub = null;
    await _completedSub?.cancel();
    _completedSub = null;
    _completedFiredForLoad = false;
    await _widthSub?.cancel();
    _widthSub = null;
    await _heightSub?.cancel();
    _heightSub = null;
    await _bufferingReadySub?.cancel();
    _bufferingReadySub = null;
    await _durationReadySub?.cancel();
    _durationReadySub = null;
    _setSubtitleCuesLoading(false);

    // 裸 `Player()`：**必须保持 `PlayerConfiguration.pitch == false`（media_kit 默认）**
    // ——这是视频调速不闪退的根因不变量（TODO-116）。media_kit `setRate` 的分支由
    // `configuration.pitch` 决定（media_kit-1.2.6 `real.dart:817`）：
    //   - 开启该配置时：**每次调速**都 `_setPropertyString('af', 'scaletempo:scale=…')`
    //     重写 libmpv 用户音频滤镜链。这正是有声书在 Win 上反复重配 mpv af 滤镜图崩溃的
    //     那条路（TODO-070/BUG-070，已用 `JustAudioMediaKit.pitch=false` 修有声书侧）。
    //   - 关闭（默认）时：只 `_setPropertyDouble('speed', rate)`，不动 af 链 → 安全。
    // 视频走裸 `Player()`（不经 just_audio / JustAudioMediaKit），保音高靠在 `load` 里
    // 一次性设的 `audio-pitch-correction=yes`（VideoMpvConfig，[applyMpvConfigToPlayer]），
    // 与每次调速无关。**切勿**为「保音高」给这里的 `Player()` 传开启该配置的
    // `PlayerConfiguration`——那会让视频每次调速重写 af 滤镜图、在 Windows 上回归
    // TODO-070 的调速闪退。守卫：`fushi/test/media/video/video_speed_pitch_guard_test.dart`。
    final Player player = _player ?? Player();
    if (_player == null) {
      _player = player;
      // BUG-1545：**必须**把本次 load 的 hwdec 策略随 configuration 传进
      // [VideoController]。media_kit_video 的 `NativeVideoController.create` 把
      // `configuration.hwdec == null` 兜底成 **`'auto'`**，并在建控制器时立刻
      // `setProperties({'vo', 'hwdec', 'vid'})` 下发到 libmpv（vendored
      // `third_party/media_kit_video/lib/src/video_controller/native_video_controller/
      // real.dart:121,159`）。而本类下发用户策略的 [applyMpvConfigToPlayer] 排在
      // `player.open` **之后**（见本方法末尾），于是首个文件的视频解码链是拿 `auto`
      // 初始化的——`auto` 是 mpv 的**全量**硬解列表（含非 copy 的 `cuda` / `nvdec`），
      // 而 [VideoMpvConfig] 的合法值域只有 `{no, auto-safe, auto-copy}`
      // （`video_mpv_config.dart` 的 `hwdecs` 白名单），**从不允许 `auto`**。
      // Windows + NVIDIA 上这条 CUDA 分支会在解码链初始化时调 `cuInit()` /
      // `cuCtxCreate_v2()`，在 nvcuda64.dll 内部空指针解引用，**整个进程 0xC0000005
      // 闪退**（三份 minidump 栈完全一致）。传 configuration 让策略在**第一次属性
      // 下发**就生效，`auto` 再也不会到达 libmpv——消除时间窗本身，而不是事后覆盖。
      // 与 [buildMpvProperties] 用同一个 [resolvePlatformHwdec] 解析，两处取值恒一致
      // （Android 仍是 copy 变体，BUG-465 不回归）。
      //
      // BUG-1639：**光把 `auto` 换成 `auto-safe` 并不够** —— `auto-safe` 的白名单里
      // `nvdec` 就是 CUDA，而 Windows 上 media_kit 同样走 GL 纹理渲染、`d3d11va`
      // interop 必然建不出 device，于是必然回退到它，同一条 `cuCtxCreate_v2` 崩溃复发。
      // 故 [resolvePlatformHwdec] 现在在 Windows 下发不含 CUDA 的 `d3d11va` 候选列表，
      // 让 CUDA 后端从值域里消失（详见该函数注释与 `docs/bugs/BUG-1639-*.md`）。
      _videoController = VideoController(
        player,
        configuration: VideoControllerConfiguration(
          hwdec: resolvePlatformHwdec(mpvConfig.hwdec),
        ),
      );
      // TODO-1212：登记文件句柄释放（幂等，只在首次建 Player 时登记一次）。
      _mediaHandleRegistration ??=
          MediaHandleRegistry.instance.register(_releaseMediaHandles);
      // BUG-739：设备切换后回补音量目标（详见 [_audioDeviceSub] 字段注释）。随 Player
      // 生命周期挂一次；换集复用同一 Player 不重挂，避免叠加订阅。
      _audioDeviceSub = player.stream.audioDevice.listen((_) {
        final Player? current = _player;
        if (current == null) return;
        unawaited(current.setVolume(_muted ? 0.0 : _lastVolume));
      });
    }
    // 下面 8 处连续原生 FFI 下发（`open` / 网络缓存 / `setSubtitleTrack(no)` / 字幕抑制
    // / 着色器 / mpv 配置 / 音量 / 速率）全用方法开头捕获的局部 [player]。这些 await 缺口
    // 内用户随时可能退出页面 / 换集，触发 [dispose]（`_loadToken++` +
    // `unawaited(_player.dispose())` 异步释放底层 libmpv NativePlayer + `_player=null`）。
    // 恢复后若仍用捕获的 [player] 向已释放 handle 下发 = 原生 use-after-free（访问违例，
    // 0xc0000005）。与本文件 [_refreshChaptersForLoad] / [selectEmbeddedGraphicTrack] 一致，
    // **每个 await 后都用 [_isCurrentLoad] 双判据（player identity + loadToken）重校验**，
    // 过期立即 `return` 干净放弃后续下发（不留半初始化——下面的订阅/tick 尚未挂起）。
    // TODO-1000（BUG-528）：防盗链 header（YouTube 流的 User-Agent 等）**必须在 open 之前**
    // 随 Media 下发——googlevideo 对 UA 不匹配的首个请求返 403，libmpv open 即失败、
    // duration/position 永远 0（黑屏卡 loading）。media_kit 用 `on_load` hook 从 Media 缓存里
    // 取 httpHeaders 设 `http-header-fields` 后才真正打开 URL（media_kit-1.2.6 real.dart:2145），
    // 故 header 走 Media 构造参数才赶得上 open。open 后的 [applyHttpHeaderFieldsToPlayer] 保留，
    // 为随后（本方法内、seek/play 之前）外挂的 audio-only 音轨设全局属性（TODO-1280）。
    // 根治 BUG-801：libmpv 默认 `sub-auto=exact` 会在 `open()` 加载文件时**自动加载与视频
    // 同名的 sidecar 外挂字幕**（用户放在视频旁的 `<video>.ass/.srt`），把它选成字幕轨、
    // 经 media_kit 的原生 `SubtitleView` 渲染，与 Hibiki 自己解析同一 .ass 得到的可点
    // [VideoSubtitleOverlay] **叠成两条同句字幕**（原生较小钉底、overlay 较大随控制条避让）。
    // 抑制属性（下面 open 之后的 [buildSubtitleSuppressionProperties]）设 `sub-auto=no` 已**太迟**
    // ——sidecar 在 `open()` 那一刻就已随 `sub-auto=exact` 自动加载并选中。故必须在 **open 之前**
    // 下发 `sub-auto=no`，让 libmpv 从一开始就不自动加载 sidecar；字幕一律走 Hibiki 自己的解析
    // （sidecar/内嵌文本轨抽成 cue 走 overlay，图形 PGS 轨由 [selectEmbeddedGraphicTrack]
    // 显式选轨渲染，均不受 `sub-auto=no` 影响）。open 后仍再下发一次做兜底（内嵌轨 open 后异步
    // 就绪的重选竞态，BUG-190）。仅 libmpv 后端生效，非 libmpv 静默 no-op（见 helper）。
    await applySubtitleMpvPropertiesToPlayer(
      player,
      buildSubtitleSuppressionProperties(),
    );
    if (!_isCurrentLoad(player, loadToken)) return; // open 前抑制下发后换片/销毁。

    // BUG-1288：恢复位置必须在 **open 之前**作为加载参数（libmpv `start`）下发，而不是
    // 等 open 返回后再 seek。media_kit 的 `open()` 把真正触发加载的 `playlist-pos` 写在
    // 命令序列最后且不等它完成；open 后发的 seek 会被随后完成的 loadfile 按 `start`
    // （默认 0）覆盖 → 「闪过断点那一帧又跳回开头」。详见 [applyMpvStartPosition] 文档。
    //
    // 此处 duration 尚不可知，故按 intent 先算一次（[resolveEpisodeStart] 的 duration=null
    // 分支已把 manualPrevious/autoAdvance 归 0，不会给「本就该从头」的入口设 start）；
    // near-end 判定要等 open 后真实 duration，在下面复核并按需拉回 0。
    final int requestedStartMs = initialPositionMs < 0 ? 0 : initialPositionMs;
    final int preloadStartMs =
        resolveEpisodeStart(startIntent, requestedStartMs, null);
    final bool startArmed = await applyMpvStartPosition(player, preloadStartMs);
    if (!_isCurrentLoad(player, loadToken)) return; // start 下发后换片/销毁。

    // 装载 mpv Lua 脚本（开关开启时页面传入目录全集）。幂等：同一 Player 内已装载
    // 路径跳过，不会重复实例化脚本（见 [applyLuaScripts]）。
    //
    // **必须在 `open` 之前**：mpv 脚本的惯用入口是 `mp.register_event("start-file")` /
    // `"file-loaded"`，这两个事件由 loadfile 触发。装载晚于 `open` 时，本次 load 的
    // 文件事件在脚本注册回调之前就已经发完了——首个文件上所有基于文件加载事件的脚本
    // （autoload、按文件切 profile、自动字幕）全部空转，要换到下一集才开始生效，
    // 用户观感是「脚本时灵时不灵」。放在 open 前则脚本必然赶上首个 loadfile。
    // `NativePlayer.command` 自带 waitForInitialization，不需要额外等 Player 就绪。
    await applyLuaScripts(luaScriptPaths);
    if (!_isCurrentLoad(player, loadToken)) return; // 脚本装载后换片/销毁。

    await player.open(
      Media(
        sourceUri,
        httpHeaders: httpHeaderFields.isEmpty ? null : httpHeaderFields,
      ),
      play: false,
    );
    if (!_isCurrentLoad(player, loadToken)) return; // open 后换片/销毁。

    // 远端 http(s) 直传：注入网络缓存/预读调优（缓解 WiFi 抖动卡顿）。仅网络流生效，
    // 本地文件 no-op（见 [applyNetworkCachePropertiesToPlayer]）。media_kit 默认
    // network-timeout=5 / demuxer-max-bytes=32MiB 对局域网 WiFi 流偏紧。
    await applyNetworkCachePropertiesToPlayer(player, sourceUri);
    if (!_isCurrentLoad(player, loadToken)) return; // 网络缓存调优后换片/销毁。

    // 防盗链流（TODO-850 阶段①）：把用户填的 Referer/User-Agent 等注入
    // libmpv `http-header-fields`。仅 [httpHeaderFields] 非空时生效（普通流/本地文件
    // no-op），与上面的网络缓存调优同为”仅网络流才下发”的叠加属性，不改
    // 既有 `Media`/缓存判据（播放内核零改）。
    await applyHttpHeaderFieldsToPlayer(player, httpHeaderFields);
    if (!_isCurrentLoad(player, loadToken)) return; // header 注入后换片/销毁。

    // TODO-1280：YouTube 分离流的 audio-only 音轨在此 `audio-add ... select` 外挂。**必须在
    // 下面的恢复 seek + play() 之前**：libmpv 对 open 后运行中才 audio-add 的外挂音频不会自动
    // seek 到当前时间轴，故在起播/首个 seek 之前挂上，才能随起播（位置 0）或恢复 seek（跳到断点）
    // 与视频同步出声（修「初始无声、跳转后才有声」）。放在 header 注入之后——audio-only 流同走
    // googlevideo，UA 不匹配首个请求会 403（http-header-fields 已设为全局属性，audio-add 继承）。
    if (externalAudioTrackUrl != null && externalAudioTrackUrl.isNotEmpty) {
      await player.setAudioTrack(AudioTrack.uri(externalAudioTrackUrl));
      if (!_isCurrentLoad(player, loadToken)) return; // 外挂音轨后换片/销毁。
    }

    // 关闭 libmpv 画面字幕渲染——字幕统一走可点击 overlay（cue 同步 + 逐字查词）。
    // mkv 内嵌字幕会被 libmpv 默认渲染成画面像素（不可点）；用户点它会穿透到视频层
    // 触发暂停而非查词。故一律关 libmpv 字幕，由 overlay 承载所有字幕（外挂 sidecar
    // 与内嵌抽取的 cue 都走 overlay）。externalSubtitlePath 已在上层解析成 cues 传入。
    await player.setSubtitleTrack(SubtitleTrack.no());
    if (!_isCurrentLoad(player, loadToken)) return; // 关字幕后换片/销毁。
    // 根除「字幕轨异步就绪后被 mpv 自动重选」竞态（TODO-080/092，BUG-190）：上面的
    // setSubtitleTrack(no()) 只在「调用那一刻」清掉选轨，但字幕轨是 open 后异步解析就绪
    // 的，mpv 默认 sub-auto=exact 会在轨就绪后自动重选内嵌字幕轨、覆盖掉 no()，再经
    // sub-visibility 渲染成画面像素字幕，与 media_kit 内置 SubtitleView 一起叠在可点
    // overlay 上 → 字幕透明随机 / 点字幕穿透落空 / 横竖屏残留黑底。注入 sub-auto=no +
    // sub-visibility=no 让 libmpv 永不自动选轨、永不画画面字幕（图形 PGS 轨例外，
    // selectEmbeddedGraphicTrack 内会按需打开 sub-visibility）。
    await applySubtitleMpvPropertiesToPlayer(
      player,
      buildSubtitleSuppressionProperties(),
    );
    if (!_isCurrentLoad(player, loadToken)) return; // 字幕抑制后换片/销毁。

    // 应用启用的 mpv 着色器（Anime4K 等）。五平台 libmpv 后端均生效——移动端 media_kit
    // 走 vo=gpu 渲染路径，glsl-shaders 进管线（见 applyShadersToPlayer doc）；仅非 libmpv
    // 后端 no-op。
    _shaderPaths = List<String>.of(shaderPaths);
    await applyShadersToPlayer(player, _shaderPaths);
    if (!_isCurrentLoad(player, loadToken)) return; // 着色器下发后换片/销毁。

    // 应用 mpv 画质/解码配置（五平台 libmpv 生效；仅非 libmpv 后端 / 不支持属性 no-op）。
    _mpvConfig = mpvConfig;
    await applyMpvConfigToPlayer(player, _mpvConfig);
    if (!_isCurrentLoad(player, loadToken)) return; // mpv 配置下发后换片/销毁。

    initialVolume = initialVolume.clamp(0.0, 100.0).toDouble();
    _lastVolume = initialVolume;
    if (initialVolume > 0) _muted = false;
    await player.setVolume(initialVolume);
    if (!_isCurrentLoad(player, loadToken)) return; // 设音量后换片/销毁。

    _lastSpeed = initialSpeed;
    await player.setRate(initialSpeed);
    if (!_isCurrentLoad(player, loadToken)) return; // 设速率后换片/销毁。
    // 恢复上次位置。主路径已由上面的 `start` 加载参数（[applyMpvStartPosition]）完成
    // ——mpv 在 loadfile 时就定位到断点，不存在「加载完再 seek」的竞态。这里只做两件
    // 收尾：① 用真实 duration 复核 near-end（open 前不可知），命中则把 mpv 拉回 0；
    // ② 非 libmpv 后端（[startArmed] 为 false）回退到既有的 open 后 seek 路径。
    //
    // [_restoreTargetMs] 守护保留：它挡的是「seek 未落地期间用过渡期小值覆盖真实进度」，
    // 与本次修复正交，回退路径与慢设备仍需要它（BUG-179 的有界宽限一并保留）。
    int resolvedStartMs = preloadStartMs;
    if (resolvedStartMs > 0) {
      await _waitUntilSeekable(player);
      if (!_isCurrentLoad(player, loadToken)) return; // 等待期间换片：放弃这次恢复
      resolvedStartMs = resolveEpisodeStart(
        startIntent,
        requestedStartMs,
        player.state.duration.inMilliseconds,
      );
    }
    // `start` 是全局选项，会影响该 Player 后续每一次 loadfile（换集 / 画质切档复用同一
    // 实例）。本次定位已由 open 消费掉，立即复位，绝不让下一集继承上一集的起播秒数。
    if (startArmed) {
      await clearMpvStartPosition(player);
      if (!_isCurrentLoad(player, loadToken)) return; // 复位后换片/销毁。
    }
    if (resolvedStartMs > 0) {
      _restoreTargetMs = resolvedStartMs;
      _restoreGuardTicksLeft = _restoreGuardGraceTicks;
      // startArmed 时 mpv 已停在断点，这次 seek 是幂等对齐（position 已到位，守护会在
      // 首个 tick 立即解除）；非 libmpv 回退路径则靠它完成恢复。
      await player.seek(Duration(milliseconds: resolvedStartMs));
    } else {
      // near-end 复核翻转（open 前按断点设了 start，真实 duration 显示已快看完）：
      // mpv 此刻停在断点，必须显式拉回 0，否则用户看到的是「从结尾几秒开始」。
      if (startArmed) {
        await player.seek(Duration.zero);
        if (!_isCurrentLoad(player, loadToken)) return; // 拉回 0 后换片/销毁。
      }
      _restoreTargetMs = null;
      _restoreGuardTicksLeft = 0;
    }
    _syncCueForPosition(resolvedStartMs, persistPosition: false);

    // 订阅播放态翻转（包括播完自动暂停、焦点丢失），即时刷新 UI 图标。
    _playingSub = player.stream.playing.listen((_) {
      notifyListeners();
    });
    _completedSub = player.stream.completed.listen(_handleCompletedChanged);

    // 订阅视频原始分辨率变化：解码出分辨率后让 overlay 重新做 \pos letterbox 映射。
    _widthSub = player.stream.width.listen((_) {
      notifyListeners();
    });
    _heightSub = player.stream.height.listen((_) {
      notifyListeners();
    });

    // TODO-1297：缓冲态翻转即 notifyListeners，让页面首开就绪判据
    // [isReadyForFirstPaint]（首帧已出画且缓冲结束）能在缓冲结束时被重新评估。
    // 缓冲结束不一定伴随宽高/播放态变化，故必须独立驱动一次通知（否则页级加载层
    // 只能靠兜底定时器让位，用户在缓冲结束后仍多看一段 media_kit 缓冲圈）。
    _bufferingReadySub = player.stream.buffering.listen((_) {
      notifyListeners();
    });

    // 125ms 周期读位置，驱动 cue 同步（对齐有声书 createPositionStream 的节奏）。
    _tick = Timer.periodic(const Duration(milliseconds: 125), (_) {
      final Player? p = _player;
      if (p == null) return;
      updateCueForPosition(p.state.position.inMilliseconds);
      // TODO-1119：同一 tick 里顺带做黑闪采样（内部自节流到 >=1s、仅 Windows 挂了
      // 回调时才真正读属性），不新起定时器。
      _maybeSampleBlackFlicker(p, loadToken);
    });

    // 自动播放：进页面/换集后直接开播（用户偏好）。放在恢复 seek **之后**（否则
    // 先从 0 起播再跳到恢复位置，产生可见闪跳），且放在订阅播放态之后（让
    // stream.playing 监听捕获到起播事件、即时刷新 UI）。换片守卫用 [_isCurrentLoad]
    // 双判据：换集复用同一 player 实例时单判 `_player == player` 仍成立，会向已被新
    // load 接管的 player 误发 play()；loadToken 才能区分本次 load 是否仍当前（BUG-344）。
    if (autoPlay && _isCurrentLoad(player, loadToken)) {
      await player.play();
    }

    // 恢复「图形内封字幕」选择（BUG-122）：上次选的是 PGS 等位图轨，没有文本 cue，
    // 交给 libmpv 当画面字幕渲染。不阻塞首帧（轨列表 open 后才就绪，方法内等待）。
    // 与下面的「抽文本 cue 自动加载」互斥——图形轨没有可抽的文本。
    if (renderGraphicStreamIndex != null) {
      unawaited(selectEmbeddedGraphicTrack(renderGraphicStreamIndex));
    } else if (!subtitleExplicitlyOff &&
        (externalSubtitlePath == null || externalSubtitlePath.isEmpty) &&
        cues.isEmpty) {
      // 无外挂字幕且无 cue 时，桌面端后台抽内嵌文本字幕轨成可点击 cue（不阻塞首帧）。
      // TODO-818：用户显式关闭字幕（subtitleExplicitlyOff）时不触发此自动抽取，否则
      // 关了字幕重启又被内嵌轨自动选上。
      unawaited(_loadEmbeddedSubtitleIfNeeded(
        player: player,
        loadToken: loadToken,
        bookUid: bookUid,
        onResult: onEmbeddedSubtitleAutoLoad,
      ));
    }

    // 内封章节（TODO-424 / TODO-521）：等 duration 首次就绪后再读 libmpv
    // `chapter-list`。open() 返回时媒体头/章节元数据可能尚未解析完；duration > 0
    // 是真实 ready 信号。换集复用同一 player 时用 loadToken 丢弃旧媒体迟到结果。
    _refreshChaptersWhenDurationReady(player, loadToken);
  }

  bool _isCurrentLoad(Player player, int loadToken) =>
      _player == player && _loadToken == loadToken;

  /// TODO-1119：黑闪采样节流入口（每 125ms tick 调一次，内部自节流到 >=1s）。仅当页面
  /// 挂了 [onSuspectedBlackFlicker]（页面只在 Windows 挂）且尚未触发、且无在途读时才采样。
  void _maybeSampleBlackFlicker(Player player, int loadToken) {
    if (onSuspectedBlackFlicker == null) return;
    if (_blackFlickerDetector.hasFired) return;
    if (_flickerSampleInFlight) return;
    final DateTime now = DateTime.now();
    final DateTime? last = _lastFlickerSampleAt;
    if (last != null && now.difference(last).inMilliseconds < 1000) return;
    final int windowMs =
        last == null ? 1000 : now.difference(last).inMilliseconds;
    _lastFlickerSampleAt = now;
    _flickerSampleInFlight = true;
    unawaited(_sampleBlackFlicker(player, loadToken, windowMs));
  }

  /// TODO-1119：读一次 libmpv 迟帧/丢帧计数器喂判据。经 `player.platform`（NativePlayer）
  /// 的 `getProperty`——仅 libmpv 后端有效，属性读取**独立于 msg-level 日志级别**（故
  /// TODO-1232 诊断探针 log 级别卡 error 不影响本采样）。每个 await 后用 [_isCurrentLoad]
  /// 双判据重校验，过期立即放弃（防向已释放 NativePlayer 读属性 = 原生 UAF，与本文件其它
  /// 异步 mpv 路径一致）。任何属性不可读时静默按 0，绝不抛、不影响播放。
  Future<void> _sampleBlackFlicker(
    Player player,
    int loadToken,
    int windowMs,
  ) async {
    try {
      final dynamic native = player.platform;
      if (native == null) return; // 非 libmpv 后端：无属性可读。
      // hwdec 前置条件：黑闪与 GPU 硬解/共享纹理路径相关，只在硬解活跃时检测。只查一次并
      // 缓存；查不到时 fail-open（视为活跃，仍受 Windows-gate + 可关闭提示兜底）。
      if (_flickerHwdecActive == null) {
        try {
          final String hwdec =
              (await native.getProperty('hwdec-current')).toString();
          if (!_isCurrentLoad(player, loadToken)) return;
          final String v = hwdec.trim().toLowerCase();
          _flickerHwdecActive = v.isNotEmpty && v != 'no' && v != 'null';
        } catch (_) {
          _flickerHwdecActive = true; // fail-open：读不到 hwdec 也允许检测。
        }
      }
      if (_flickerHwdecActive == false) return; // 软解路径：不检测。

      int readCounter(Object? raw) {
        final int? n = int.tryParse(raw?.toString().trim() ?? '');
        return (n == null || n < 0) ? 0 : n;
      }

      int delayed = 0;
      int dropped = 0;
      try {
        delayed =
            readCounter(await native.getProperty('vo-delayed-frame-count'));
      } catch (_) {
        // 属性不可读：按 0（不致命）。
      }
      if (!_isCurrentLoad(player, loadToken)) return;
      try {
        dropped = readCounter(await native.getProperty('frame-drop-count'));
      } catch (_) {
        // 属性不可读：按 0（不致命）。
      }
      if (!_isCurrentLoad(player, loadToken)) return;

      final bool fired = _blackFlickerDetector.addSample(VideoFlickerSample(
        cumulativeLateFrames: delayed + dropped,
        windowMs: windowMs,
        playing: isPlaying,
      ));
      if (fired) {
        onSuspectedBlackFlicker?.call();
      }
    } finally {
      _flickerSampleInFlight = false;
    }
  }

  void _clearChaptersForNewLoad() {
    if (_chapters.isEmpty) return;
    _chapters = const <VideoChapter>[];
    notifyListeners();
  }

  void _refreshChaptersWhenDurationReady(Player player, int loadToken) {
    if (!_isCurrentLoad(player, loadToken)) return;
    final Duration currentDuration = player.state.duration;
    if (currentDuration > Duration.zero) {
      notifyListeners();
      unawaited(_refreshChaptersForLoad(player, loadToken));
      return;
    }
    _durationReadySub = player.stream.duration.listen((Duration duration) {
      if (!_isCurrentLoad(player, loadToken)) return;
      notifyListeners();
      if (duration <= Duration.zero) return;
      final StreamSubscription<Duration>? sub = _durationReadySub;
      _durationReadySub = null;
      unawaited(sub?.cancel());
      unawaited(_refreshChaptersForLoad(player, loadToken));
    });
  }

  void _handleCompletedChanged(bool completed) {
    if (!completed) return;
    if (_completedFiredForLoad) return;
    _completedFiredForLoad = true;
    _onCompleted?.call();
  }

  void _setSubtitleCuesLoading(bool loading) {
    if (_subtitleCuesLoading == loading) return;
    _subtitleCuesLoading = loading;
    notifyListeners();
  }

  /// 桌面端后台自动抽**第一条可转文本的**内嵌字幕轨 → cue → [setCues]，触发
  /// 可点击 overlay。
  ///
  /// 仅当无外挂字幕且当前无 cue 时由 [load] 末尾触发（调用方已门控）。移动端跳过
  /// （ffmpeg 不可用），无可用文本轨 / 失败静默返回，保留 libmpv 画面渲染兜底。
  ///
  /// **复用字幕菜单同一套 codec 感知逻辑**（[listAllSubtitleSources] +
  /// [loadCuesForSource]），不再硬编码 `.ass` / [AssParser] / streamIndex 0——
  /// 否则同一个 mp4（`mov_text`）菜单能出字幕、自动加载却静默失败（BUG-071 同源
  /// 不一致）。优先选能转文本 cue 的内嵌轨（跳过 pgs 等图形轨），都不行则不自动
  /// 加载。[listAllSubtitleSources] 的 langCode 只影响外挂字幕排序，这里只取内嵌
  /// 轨故传固定值。
  ///
  /// 抽字幕较慢（ffmpeg 跑几秒），故 [load] 用 `unawaited` 后台触发不阻塞播放；
  /// 抽完才 [setCues]，overlay 此时才出现。期间若发生重新 [load]（player /
  /// [loadToken] 变化）则丢弃旧结果，避免把上一段视频的字幕错挂到新视频。
  ///
  /// **首开瞬态争用重试（TODO-572）**：首次打开大容器（冷页缓存）时，本枚举
  /// （`ffmpeg -i`）与 [prewarmEmbeddedSubtitleCache] 的整轨抽取（`ffmpeg -map`）
  /// 及 libmpv 正在 demux 播放三方争用磁盘 IO，[probeEmbeddedSubtitleTracks] 可能
  /// 超时返回 0 轨 → `enumerationTimeout`，整条链路当「无内封字幕」处理，用户必须
  /// 退出重开（此时缓存命中 / 争用消退）才出字幕。BUG-303 仅放宽超时窗口未消除
  /// 时序，故此处对**瞬态失败**（枚举超时 / 失败 / 抽出空 cue——即「本该有字幕但
  /// 这次没拿到」）等 libmpv 字幕轨真实就绪信号（说明容器字幕区已 demux 进页缓存、
  /// 三方争用已消退）后**重试一次**，与 BUG-313 章节首载「等就绪信号重读」同构。
  /// 终态（无内封轨 / 无文本轨 / 文件缺失 / 已加载）不重试。
  Future<void> _loadEmbeddedSubtitleIfNeeded({
    required Player player,
    required int loadToken,
    required String bookUid,
    void Function(DefaultEmbeddedSubtitleLoadResult result)? onResult,
  }) async {
    // 桌面走系统 ffmpeg、移动端走捆绑 ffmpeg-kit（见 resolveFfmpegBackend），两端都能
    // 抽内封字幕，故不再按平台门控（早先「移动端无 ffmpeg」的限制已随捆绑解除）。
    // 真无 ffmpeg 时 listAllSubtitleSources 返回空、优雅降级，不会出错。
    final String? videoPath = _videoPath;
    if (videoPath == null) return;

    _setSubtitleCuesLoading(true);
    try {
      // 首开瞬态争用重试（TODO-572）：协调器先枚举加载一次，瞬态失败（枚举超时 /
      // 失败 / 空 cue）时等 libmpv 字幕轨真实就绪后重试一次。换片（含复用同一
      // player）期间用 player identity + loadToken 双判据丢弃旧结果。
      final DefaultEmbeddedSubtitleLoadResult result =
          await loadDefaultTextEmbeddedSubtitleCuesWithReadinessRetry(
        videoPath: videoPath,
        bookUid: bookUid,
        waitForReady: () => _waitUntilSubtitleTracksReady(player),
        isStillCurrent: () => _isCurrentLoad(player, loadToken),
      );
      if (!_isCurrentLoad(player, loadToken)) return;

      switch (result.status) {
        case DefaultEmbeddedSubtitleLoadStatus.loaded:
          debugPrint(
              '[video-embedded-sub] extracted ${result.cues.length} cues');
          setCues(result.cues);
          onResult?.call(result);
          return;
        case DefaultEmbeddedSubtitleLoadStatus.noEmbeddedTracks:
          debugPrint('[video-embedded-sub] no embedded subtitle track');
          onResult?.call(result);
          return;
        case DefaultEmbeddedSubtitleLoadStatus.noTextTrack:
          debugPrint('[video-embedded-sub] no text-capable embedded track');
          onResult?.call(result);
          return;
        case DefaultEmbeddedSubtitleLoadStatus.emptyCues:
          debugPrint('[video-embedded-sub] parsed 0 cues from embedded track');
          onResult?.call(result);
          return;
        case DefaultEmbeddedSubtitleLoadStatus.enumerationTimeout:
        case DefaultEmbeddedSubtitleLoadStatus.enumerationFailed:
        case DefaultEmbeddedSubtitleLoadStatus.missingFile:
          debugPrint(
            '[video-embedded-sub] default load skipped: ${result.status}',
          );
          onResult?.call(result);
          return;
      }
    } finally {
      if (_isCurrentLoad(player, loadToken)) {
        _setSubtitleCuesLoading(false);
      }
    }
  }

  @visibleForTesting
  Future<void> debugLoadEmbeddedSubtitleIfNeededForTesting({
    required Player player,
    required int loadToken,
    required String videoPath,
    required String bookUid,
    void Function(DefaultEmbeddedSubtitleLoadResult result)? onResult,
  }) async {
    _videoPath = videoPath;
    await _loadEmbeddedSubtitleIfNeeded(
      player: player,
      loadToken: loadToken,
      bookUid: bookUid,
      onResult: onResult,
    );
  }

  /// cue 同步核心：照搬有声书 `_updateCurrentCue` 语义。
  ///
  /// 1. 先 [_maybeSavePosition]（位置持久化不受 cue gap guard 影响）。
  /// 2. 空 cues 直接返回。
  /// 3. `effectiveMs = posMs - delayMs`，下界 clamp 到 0。
  /// 4. [JsonAlignmentParser.findCueIndex] 二分定位；返回 -1（gap / 早于首句）
  ///    时**清空**当前字幕（视频字幕在时间窗结束后应消失，BUG-074），仅在确有
  ///    字幕需清时 [notifyListeners]。
  /// 5. 命中下标与 [_currentCueIndex] 相同时不重复 [notifyListeners]。
  /// 6. 否则更新当前 cue 并通知。
  void updateCueForPosition(int posMs) {
    // 普通 seek 在途：把 tick 读到的滞后旧 position 调和成跳转目标位置（见
    // [_plainSeekTargetMs] / [_reconcileSeekInFlightPosition]），避免旧字幕被反复确认。
    _syncCueForPosition(_reconcileSeekInFlightPosition(posMs),
        persistPosition: true);
  }

  void _syncCueForPosition(int posMs, {required bool persistPosition}) {
    if (persistPosition) {
      _maybeSavePosition(posMs);
    }
    final int effectiveMs = effectiveSubtitlePositionMs(posMs, _delayMs);

    // TODO-1312：副字幕活动集（与主字幕独立求；空副字幕恒空集）。TODO-2837：副字幕
    // 用**自己的生效调轴**（[effectiveSecondaryDelayMs]，未单独设置时 == _delayMs，
    // 等价旧「同一 effective 位置」行为）求活动集——主副字幕轴不同源时各调各的。
    // 无论主字幕有无都要更新（副字幕可在无主字幕时单独显示），故放在主 cues 空判之前。
    final List<int> nextSecondary = _secondaryCues.isEmpty
        ? const <int>[]
        : JsonAlignmentParser.findActiveCueIndices(
            cues: _secondaryCues,
            positionMs:
                effectiveSubtitlePositionMs(posMs, effectiveSecondaryDelayMs),
            // 渲染集半开区间：相邻对白边界不产生「幻影重叠」→ 堆叠不弹跳（见
            // [JsonAlignmentParser.findActiveCueIndices] 的 endInclusive 说明）。
            endInclusive: false);
    bool changed = !_intListEquals(nextSecondary, _activeSecondaryCueIndices);
    if (changed) _activeSecondaryCueIndices = nextSecondary;

    if (_cues.isEmpty) {
      // 无主 cue：清主字幕代表 cue + 活动集残留，据 changed（含副字幕变化）决定是否通知。
      if (_currentCueIndex != -1 ||
          _currentCue != null ||
          _activeCueIndices.isNotEmpty) {
        _currentCueIndex = -1;
        _currentCue = null;
        _activeCueIndices = const <int>[];
        changed = true;
      }
      if (changed) notifyListeners();
      return;
    }

    int idx = JsonAlignmentParser.findCueIndex(
      cues: _cues,
      positionMs: effectiveMs,
    );
    // TODO-565：主动跳转（[skipToCue]）的 seek 落点因 preRoll 偏到目标句之前，落地后那一瞬
    // findCueIndex 据实际位置正确地报上一句/ gap。若仍在目标句的 preRoll 引导窗口内，把命中
    // 下标 snap 回目标句（消除「点第 N 行高亮 N-1」）；离开窗口（自然进入目标句 / 远早于窗口）
    // 时清快照、退回纯位置推导。
    idx = _applySeekTargetSnap(idx, effectiveMs);
    _rearmSubtitleEndPauseIfNeeded(effectiveMs);
    if (_shouldHoldAtSubtitleEnd(idx, effectiveMs)) {
      final AudioCue cue = _cues[_currentCueIndex];
      _pauseAndSeekForSubtitleEnd(cue, _currentCueIndex);
      return;
    }

    // TODO-1312：主字幕活动集（重叠 cue 全渲染）= 时间上区间覆盖 effective 的所有 cue，
    // 并入被 snap 选中的代表 cue（[skipToCue] preRoll 期间 idx 已 snap 到目标句、但它此刻
    // 可能还没到时间 → 也要渲染，与代表 cue「点跳即显」一致）。
    final List<int> nextActive = _activeRenderIndices(idx, effectiveMs);
    if (!_intListEquals(nextActive, _activeCueIndices)) {
      _activeCueIndices = nextActive;
      changed = true;
    }

    // Gap（两条字幕间的静音）或早于首句：清空**代表** cue。视频底部字幕 overlay 与
    // 有声书的「正文跟随高亮」语义不同——真实字幕在其时间窗 [startMs, endMs] 结束后就该
    // 消失，不能像高亮那样在 gap 里保留上一句（BUG-074）。findCueIndex 在 gap 返回 -1 正是
    // 「让上层清」的契约。此刻活动集若仍非空（重叠 cue 尚在时间窗内），overlay 继续渲染那些
    // cue（TODO-1312：越过被选那条 end 落 gap 不再整体清空 / 闪烁）。
    if (idx < 0) {
      if (_currentCueIndex != -1) {
        _pauseForSubtitleEnd();
        _currentCueIndex = -1;
        _currentCue = null;
        changed = true;
      }
      if (changed) notifyListeners();
      return;
    }
    if (idx != _currentCueIndex) {
      _currentCueIndex = idx;
      _currentCue = _cues[idx];
      debugPrint(
          '[video-cue] idx=$idx pos=${posMs}ms text="${_cues[idx].text}"');
      changed = true;
    }
    if (changed) notifyListeners();
  }

  /// TODO-1312：主字幕活动渲染集 = 时间活动集（[JsonAlignmentParser.findActiveCueIndices]）
  /// 并入被 snap 选中的代表 cue [primaryIdx]（若 >=0 且不在时间集里，多为 [skipToCue]
  /// preRoll 在途）。升序返回，供 overlay 竖排堆叠多字幕盒。
  List<int> _activeRenderIndices(int primaryIdx, int effectiveMs) {
    final List<int> byTime = JsonAlignmentParser.findActiveCueIndices(
      cues: _cues,
      positionMs: effectiveMs,
      // 渲染集半开区间：相邻对白边界（前条 endMs==后条 startMs）不再同时活跃，堆叠槽位
      // 不被幻影重叠污染 → 不弹跳。末条无后继时靠下方 primaryIdx（findCueIndex 闭区间）
      // 并入兜底，不会提前 1 tick 消失（见 findActiveCueIndices 的 endInclusive 说明）。
      endInclusive: false,
    );
    if (primaryIdx < 0 || byTime.contains(primaryIdx)) return byTime;
    final List<int> merged = <int>[...byTime, primaryIdx]..sort();
    return merged;
  }

  /// 两个 int 列表逐元素相等（活动集变化判据，避免每 125ms tick 无谓 [notifyListeners]）。
  static bool _intListEquals(List<int> a, List<int> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// 应用「主动跳转目标」snap（TODO-565 / BUG-378），并维护 [_seekTargetCueIndex] 生命周期。
  ///
  /// [findCueIdx] 是按实时位置反推的命中下标，[effectiveMs] 是 effective 字幕轴位置。
  /// 委托纯函数 [cueSnapIndex] 决策几何：落在 preRoll 引导窗口或目标句区间 `[startMs-preRoll,
  /// endMs]` 内 → 返回目标下标且保留快照（`keep=true`）；越过句尾 / 远早于窗口 → `keep=false`。
  /// 本方法再叠加**在途 seek 宽限**（[_seekSnapGraceTicksLeft]）这一时间维度：position 首次
  /// 真正落入目标句前，无论瞬态在目标句之前还是之后，都消耗宽限、保留快照、snap 回目标句
  /// （撑到 seek 真落地），落定后才按几何清快照。无副作用几何全在纯函数里。
  int _applySeekTargetSnap(int findCueIdx, int effectiveMs) {
    final int? target = _seekTargetCueIndex;
    if (target == null) return findCueIdx;
    if (target < 0 || target >= _cues.length) {
      _clearSeekTargetSnap();
      return findCueIdx;
    }
    final int targetStartMs = _cues[target].startMs;
    final int targetEndMs = _cues[target].endMs;
    final (int snappedIdx, bool keepSnapshot) = cueSnapIndex(
      findCueIndex: findCueIdx,
      effectiveMs: effectiveMs,
      targetIndex: target,
      targetStartMs: targetStartMs,
      targetEndMs: targetEndMs,
      preRollMs: kCueSeekPreRollMs,
    );
    if (keepSnapshot) {
      // 情形 3：position 落在 preRoll 引导窗口 [startMs-preRoll, startMs) 或目标句区间
      // [startMs, endMs] 内，seek 已落到目标句（含因关键帧吸附越句首落在句内）。作废在途
      // seek 宽限——之后再「远离窗口」就是真离开（越过句尾 / 手动 seek），该清。
      _seekSnapGraceTicksLeft = 0;
      return snappedIdx;
    }
    // keepSnapshot==false：cueSnapIndex 判 position 已离开目标句区间（情形 1 越句尾 / 情形 2
    // 远早于窗口）。但 **position 是否真正进入过目标句一次**（[_seekSnapGraceTicksLeft] 已被
    // 情形 3 清 0 = 进过；仍 > 0 = 在途、从未进过）决定该不该清快照：
    // - **在途（宽限 > 0，position 从未首次落入目标句）**：seek 尚未真落地，本 tick 读到的
    //   是 seek 在途的瞬态位置——可能在目标句**之前**（情形 2，旧 position）也可能在目标句
    //   **之后**（情形 1 越句尾：短句关键帧吸附越过整句 / media_kit seek 吐的中间高位置 /
    //   播放态点靠前句时旧 position 本就在更后的句）。两个方向都是「seek 还没落到目标句」，
    //   一律消耗一格宽限、保留快照、snap 回目标句（撑到 seek 真落地），不被瞬态顶到别的句 →
    //   消除「点第 N 句因 seek 在途瞬态高亮 N±k」的多跳/错位（BUG-378，对齐有声书
    //   [AudiobookPlayerController] 的 _explicitSeekInFlight 抑制范式）。
    // - **已落定（宽限 == 0，position 进过目标句后又越过句尾，情形 1）**：这是正常自然播放
    //   越过目标句，按 findCueIndex 命中下一句、清快照退回纯推导。
    // - **宽限耗尽**（连续在途 tick 用满配额仍没落定，慢设备 / libmpv 丢弃，对齐 BUG-179）：
    //   判定 seek 落地失败，放弃保护、清快照，绝不永久把高亮钉在旧目标上。
    // 注：情形 2 在途经 seekMs 的统一清除点（[_clearSeekTargetSnap]，宽限同时清 0）已先把
    // 「用户手动 seek 拉走」与「skipToCue 在途」分开——手动 seek 清快照后 target==null 提前
    // 返回，走不到这里，故这里的宽限保护只作用于 skipToCue 自己的在途 seek。
    if (_seekSnapGraceTicksLeft > 0) {
      _seekSnapGraceTicksLeft--;
      return target;
    }
    _clearSeekTargetSnap();
    return snappedIdx;
  }

  /// 清「主动跳转目标」快照（[_seekTargetCueIndex]）及其在途 seek 宽限配额，并一并清普通
  /// seek 在途状态（[_plainSeekTargetMs]）——退回纯位置推导。换字幕 / 换片 / 用户主动 seek /
  /// 自然越过目标句都汇到这里，作「seek 追踪状态」的统一复位点。
  void _clearSeekTargetSnap() {
    _seekTargetCueIndex = null;
    _seekSnapGraceTicksLeft = 0;
    _clearPlainSeekInFlight();
  }

  /// 记下普通 seek 的在途目标位置并充满播放态宽限（见 [_plainSeekTargetMs]）。
  void _beginPlainSeekInFlight(int targetMs) {
    _plainSeekTargetMs = targetMs;
    _plainSeekGraceTicksLeft = _seekSnapGraceTicks;
  }

  /// 清普通 seek 在途状态（目标位置 + 宽限），退回读真实 position。
  void _clearPlainSeekInFlight() {
    _plainSeekTargetMs = null;
    _plainSeekGraceTicksLeft = 0;
  }

  /// 普通 seek 在途位置调和（见 [_plainSeekTargetMs]）：tick 读到的 [rawPosMs] 在 seek
  /// 落地前是滞后的旧 position；据「已知目标位置」把它替换成目标位置，直到真实位置落定。
  /// - 与 [skipToCue] 快照（[_seekTargetCueIndex]）互斥：后者非空时让路，返回 [rawPosMs]；
  /// - 暂停态（positionStream 不推进）：无限期返回目标位置，让字幕停在目的地（gap 则消失）；
  /// - 播放态：真实位置到达 `目标 − [_kPlainSeekLandToleranceMs]` 即落定、放行真实位置；否则
  ///   消耗一格宽限继续返回目标，宽限耗尽（慢设备 / 永不落定）也放行真实位置。
  int _reconcileSeekInFlightPosition(int rawPosMs) {
    final int? target = _plainSeekTargetMs;
    if (target == null || _seekTargetCueIndex != null) return rawPosMs;
    if (!isPlaying) return target;
    if (rawPosMs >= target - _kPlainSeekLandToleranceMs) {
      _clearPlainSeekInFlight();
      return rawPosMs;
    }
    if (_plainSeekGraceTicksLeft > 0) {
      _plainSeekGraceTicksLeft--;
      return target;
    }
    _clearPlainSeekInFlight();
    return rawPosMs;
  }

  /// 公开清除入口（TODO-565 复核退回的必修项）：供**绕过 [seekMs]** 的 seek 路径手动
  /// 作废「主动跳转目标」快照。唯一调用方是页面层 media_kit 进度条（seek bar）——它在
  /// media_kit / vendored fork 内部直接调 `player.seek`，既不经本类 [seekMs]、也不向页面
  /// 层暴露 seek 目标（fork 的 onSeekStart 只透出「开始拖动」信号、无目标位置），故
  /// [seekMs] 的统一清除点覆盖不到它。页面层在**开始拖动**（fork onSeekStart）时调本方法补清，
  /// 避免「[skipToCue] 宽限窗口内拖进度条到更早句被误 snap 回旧目标」；拖动**落点**的字幕在途
  /// 保护由 [notifyExternalSeek] 承载（见其注释）。
  void clearSeekTargetSnap() {
    _clearSeekTargetSnap();
  }

  /// 外部 seek（media_kit 进度条拖动 / 点击，绕过 [seekMs] 直接 `player.seek`）**落点**通知：
  /// 页面在 fork 的 `onSeekEnd(target)` 回调里调本方法，补上与 [seekMs] 同款「普通 seek 在途
  /// 保护」——按 [targetMs] 权威同步一次字幕（gap 立即消失）+ 抑制随后 tick 的滞后旧 position
  /// （暂停无限保持 / 播放有界宽限），**但不重复 `player.seek`**（进度条内部已 seek）。
  ///
  /// 修「进度条拖到无字幕段后旧字幕不消失」（尤其暂停重听时）：进度条走 media_kit 内部 seek，
  /// [seekMs] 的权威同步 + 在途抑制覆盖不到它，旧字幕会被滞后旧 position 逐拍确认（同 BUG-796
  /// ±秒键根因）。本方法把同一保护补到进度条落点。
  void notifyExternalSeek(int targetMs) {
    final int clampedMs = targetMs.clamp(0, 1 << 30);
    _clearSeekTargetSnap();
    _beginPlainSeekInFlight(clampedMs);
    _syncCueForPosition(clampedMs, persistPosition: false);
  }

  /// 主动跳转目标 snap 的纯决策（TODO-565，越界判据 BUG-378 收紧到 endMs）。所有几何在
  /// effective 字幕轴上。落地判据用「越过目标句**尾** [targetEndMs]」而非「越过句**首**
  /// [targetStartMs]」——media_kit 关键帧吸附可能把 seek 落点推到目标句首之后；当目标句
  /// 很短、吸附幅度大于句长时，落点会越过整个目标句进入下一句（`eff > targetEndMs`），
  /// 此刻 [findCueIndex] 命中下一句（或 gap 的 -1）。旧判据 `eff >= targetStartMs` 把这种
  /// 「越过整句进了下一句」误当成「自然进入目标句、可信」而清快照，导致点第 N 句高亮 N+1
  /// （多跳一句）。收紧到 endMs 后，落点在 `[startMs-preRoll, endMs]` 区间（preRoll 引导窗口
  /// 内 **或** 目标句区间内）一律 snap 回目标句，只有真正越过句尾才清。
  ///
  /// 三种情形：
  /// 1. `effectiveMs > targetEndMs`：position 已自然越过目标句**尾**，[findCueIndex] 命中
  ///    下一句（或更后），主动跳转已落定/失效——用原命中下标，**清快照**（`keep=false`）。
  /// 2. `effectiveMs < targetStartMs - preRollMs`：position 远在 preRoll 引导窗口之前
  ///    （被别的 seek 拉走 / 跳转未落地），主动跳转已失效——用原命中下标，**清快照**。
  /// 3. 其余（`targetStartMs - preRollMs <= effectiveMs <= targetEndMs`）：落在 preRoll
  ///    引导窗口内、或目标句区间内，命中下标此刻可能是目标句之前那条 / gap 的 -1 / 因吸附
  ///    越句而成的下一句——一律 snap 回目标句，**保留快照**（`keep=true`）等 position 真正
  ///    越过句尾后再清。
  ///
  /// preRollMs 取负时按 0 处理（与 [cueSeekTargetMs] 同防御）。[targetEndMs] 退化为
  /// < `targetStartMs - preRoll` 的异常输入时窗口为空，任意 position 落情形 1/2 不误 snap。
  @visibleForTesting
  static (int snappedIndex, bool keepSnapshot) cueSnapIndex({
    required int findCueIndex,
    required int effectiveMs,
    required int targetIndex,
    required int targetStartMs,
    required int targetEndMs,
    required int preRollMs,
  }) {
    final int preRoll = preRollMs < 0 ? 0 : preRollMs;
    if (effectiveMs > targetEndMs) return (findCueIndex, false);
    if (effectiveMs < targetStartMs - preRoll) return (findCueIndex, false);
    return (targetIndex, true);
  }

  @visibleForTesting
  void debugUpdateCueForPosition(int posMs) => updateCueForPosition(posMs);

  @visibleForTesting
  void debugSyncInitialCueForPosition(int posMs) =>
      _syncCueForPosition(posMs, persistPosition: false);

  /// 测试钩子：在**不实例化 [Player]**（宿主无 libmpv）的前提下，把
  /// [VideoPlayerController] 摆成「load 后正处于恢复 seek 守护中」的状态，以驱动
  /// [_maybeSavePosition]→[_isRestoringPast] 的位置写入门控逻辑（BUG-179 恢复守护
  /// 有界宽限）。
  ///
  /// [bookUid] 模拟 [load] 设过的书 id（[_maybeSavePosition] 需非空才会写）；
  /// [restoreTargetMs] 模拟恢复目标（对齐 [load] 里 `_restoreTargetMs = initialPositionMs`），
  /// 同时按真实 [load] 路径重置宽限配额。设后用 [debugUpdateCueForPosition] 喂位置序列、
  /// 观测 [onPositionWrite] 的调用即可断言守护的「未追上跳过 / 追上恢复 / 宽限耗尽放弃」。
  @visibleForTesting
  void debugPrimeRestoreGuardForTesting({
    required String bookUid,
    required int restoreTargetMs,
  }) {
    _bookUid = bookUid;
    _restoreTargetMs = restoreTargetMs;
    _restoreGuardTicksLeft = _restoreGuardGraceTicks;
    _lastSavedSec = -1;
  }

  /// 测试可见：当前恢复守护是否仍生效（[_restoreTargetMs] 非空）。
  @visibleForTesting
  bool get debugRestoreGuardActive => _restoreTargetMs != null;

  /// 测试可见：恢复守护的宽限上限（断言用，避免测试硬编码数字与实现漂移）。
  @visibleForTesting
  static int get debugRestoreGuardGraceTicks => _restoreGuardGraceTicks;

  /// 测试可见：当前「主动跳转目标」快照下标（[_seekTargetCueIndex]）；null 表示无快照。
  /// 断言「在途 seek 的 stale tick 不清快照 / 宽限耗尽后清快照」用（TODO-565 时序）。
  @visibleForTesting
  int? get debugSeekTargetCueIndex => _seekTargetCueIndex;

  /// 测试可见：在途 seek 宽限的 tick 配额上限（[_seekSnapGraceTicks]，断言用，
  /// 避免测试硬编码数字与实现漂移）。
  @visibleForTesting
  static int get debugSeekSnapGraceTicks => _seekSnapGraceTicks;

  /// 测试可见：当前是否处于图形内封字幕（PGS 等）渲染模式（BUG-301）。
  @visibleForTesting
  bool get debugGraphicSubtitleActive => _graphicSubtitleActive;

  /// 测试可见：[setDelayMs] / [selectEmbeddedGraphicTrack] 会下发到 libmpv
  /// `sub-delay` 的延迟（毫秒）——图形模式用真实 delay，文本模式恒 0（BUG-301）。
  /// 宿主无 libmpv（[_player] 恒 null）时 mpv 属性下发被跳过，本 getter 让单测仍能
  /// 断言「按字幕源类型选了对的 sub-delay」这个决策。
  @visibleForTesting
  int get debugSubtitleDelayMpvMs => _subtitleDelayMpvMs;

  /// 测试可见：在不实例化 [Player]（宿主无 libmpv，[selectEmbeddedGraphicTrack]
  /// 选轨即返回 false）的前提下，模拟「已进入图形字幕渲染模式」，以驱动 [setDelayMs]
  /// 的图形/文本分流决策（BUG-301）。
  @visibleForTesting
  void debugSetGraphicSubtitleActiveForTesting(bool active) {
    _graphicSubtitleActive = active;
  }

  @visibleForTesting
  void debugHandleCompletedForTesting(bool completed) {
    _handleCompletedChanged(completed);
  }

  @visibleForTesting
  void debugResetCompletedForNewLoadForTesting() {
    _completedFiredForLoad = false;
  }

  @visibleForTesting
  Future<void> debugAttachCompletedStreamForTesting(
    Stream<bool> completedStream,
  ) async {
    await _completedSub?.cancel();
    _completedFiredForLoad = false;
    _completedSub = completedStream.listen(_handleCompletedChanged);
  }

  @visibleForTesting
  void debugSetSubtitleCuesLoadingForTesting(bool loading) {
    _setSubtitleCuesLoading(loading);
  }

  @visibleForTesting
  void debugSetPauseAtSubtitleEndForTesting({
    required bool enabled,
    bool Function()? isPlaying,
    required Future<void> Function() onPause,
    Future<void> Function(int positionMs)? onSeek,
    Future<void> Function()? onPlay,
  }) {
    _pauseAtSubtitleEnd = enabled;
    _pauseAtSubtitleEndOverride = onPause;
    _pauseAtSubtitleEndIsPlayingOverride = isPlaying;
    _pauseAtSubtitleEndSeekOverride = onSeek;
    _replayPlayOverride = onPlay;
    _lastSubtitleEndPauseCueIndex = null;
  }

  /// 等 [player] 进入可 seek 状态（`duration > 0` 表示已解析媒体头）。
  ///
  /// media_kit 在 `open(play:false)` 刚返回时常 duration/position 仍为 0，此刻 seek
  /// 会被丢弃；等首个非零 duration 再 seek 才可靠。最多等 5 秒，超时则尽力 seek
  /// （[_restoreTargetMs] 守护兜底，不会因没落地而把真实进度覆盖成 0）。
  Future<void> _waitUntilSeekable(Player player) async {
    if (player.state.duration > Duration.zero) return;
    try {
      await player.stream.duration
          .firstWhere((Duration d) => d > Duration.zero)
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // 超时/异常：尽力继续 seek。
    }
  }

  /// 恢复 seek 是否尚未落地：[_restoreTargetMs] 非 null 且当前 [posMs] 还在目标之前
  /// （过渡期小值/0）时返回 true，调用方应跳过持久化以免覆盖真实进度。
  ///
  /// 两条清除路径（任一满足都清守护、恢复正常持久化）：
  /// 1. **正常恢复**：position 追上目标（容差 1.5s）→ seek 已落地，立即清。
  /// 2. **恢复失败兜底**（BUG-179）：连续 [_restoreGuardGraceTicks] 次观测仍未追上
  ///    目标 → 判定 seek 实际未落地（被 libmpv 丢弃 / 慢设备迟迟不就绪，Android 尤甚），
  ///    主动放弃守护。否则守护会**永久**挡住整程位置写入，导致「这次进度也没记住」。
  ///    宽限只在「真处于守护中且这次仍没追上」时消耗，正常恢复路径不会触发。
  bool _isRestoringPast(int posMs) {
    final int? target = _restoreTargetMs;
    if (target == null) return false;
    if (posMs >= target - 1500) {
      _clearRestoreGuard();
      return false;
    }
    // 仍未追上目标：消耗一格宽限；耗尽则放弃守护（seek 落地失败兜底，BUG-179）。
    if (_restoreGuardTicksLeft > 0) {
      _restoreGuardTicksLeft--;
    }
    if (_restoreGuardTicksLeft <= 0) {
      _clearRestoreGuard();
      return false;
    }
    return true;
  }

  /// 清除恢复守护（target + 宽限计数一起归零），让位置写入恢复正常。
  void _clearRestoreGuard() {
    _restoreTargetMs = null;
    _restoreGuardTicksLeft = 0;
  }

  /// 整秒变化且 [_bookUid] 非空时，异步触发位置持久化（每秒至多一次）。
  void _maybeSavePosition(int posMs) {
    final String? bookUid = _bookUid;
    if (bookUid == null) return;
    // 恢复 seek 未落地：当前 position 是过渡期小值，写它会覆盖真实进度。跳过。
    if (_isRestoringPast(posMs)) return;
    final int sec = posMs ~/ 1000;
    if (sec == _lastSavedSec) return;
    _lastSavedSec = sec;
    unawaited(onPositionWrite?.call(bookUid, posMs));
  }

  /// 强制把**当前**播放位置经 [onPositionWrite] 写一次并 **await 到落库**，
  /// 绕过 [_maybeSavePosition] 的整秒节流。
  ///
  /// 周期保存只在整秒边界写，又是 fire-and-forget；用户退出（pop/dispose）那一刻
  /// 的最后几百毫秒进度（同一整秒内）会被节流吞掉，导致「退出再进没回到上次位置」。
  /// 退出前调本方法把退出瞬间的位置可靠写穿（对齐有声书
  /// [AudiobookPlayerController.flushPosition]）。
  ///
  /// 必须在 [Player] 仍存活时调用（[positionMs] 读 `_player.state.position`）：
  /// [VideoFushiPage.dispose] 先 `flushPosition()` 再 `dispose()`；换集前
  /// （[_switchEpisode]）也调一次记录当前集精确进度。未 [load]（无 player /
  /// 无 bookUid）时 no-op 安全。
  Future<void> flushPosition() async {
    final String? bookUid = _bookUid;
    final int? posMs = positionMs;
    if (bookUid == null || posMs == null) return;
    // 恢复 seek 未落地：退出瞬间的 position 仍是过渡期小值，写它会覆盖真实进度。跳过。
    if (_isRestoringPast(posMs)) return;
    _lastSavedSec = posMs ~/ 1000;
    await onPositionWrite?.call(bookUid, posMs);
  }

  /// 开始播放（未 load 时 no-op 安全）。
  Future<void> play() async {
    await _player?.play();
  }

  /// 暂停（未 load 时 no-op 安全）。
  Future<void> pause() async {
    await _player?.pause();
  }

  Future<void> playOrPause() async {
    await _player?.playOrPause();
  }

  Future<void> _mpvCommand(List<String> command) async {
    final dynamic native = _player?.platform;
    if (native == null) return;
    try {
      await native.command(command);
    } catch (_) {
      // Non-libmpv backends or unsupported commands are best-effort no-ops.
    }
  }

  /// mpv-style single-frame stepping. mpv requires playback to be paused first.
  Future<void> frameStep({required bool forward}) async {
    await pause();
    await _mpvCommand(<String>[forward ? 'frame-step' : 'frame-back-step']);
  }

  /// 读一条 libmpv 字符串属性（[property]），best-effort：非 libmpv 后端（无
  /// `getProperty`）/ 属性不存在 / 抛异常时返回 `''`。与 [_mpvCommand]（写命令）/
  /// [applyMpvConfigToPlayer]（写属性）同范式，只是方向相反——读 `chapter-list/*`、
  /// `chapter` 等章节属性（TODO-424）。
  Future<String> _getMpvProperty(String property) async {
    final dynamic native = _player?.platform;
    if (native == null) return '';
    try {
      final dynamic value = await native.getProperty(property);
      return value is String ? value : (value?.toString() ?? '');
    } catch (_) {
      return '';
    }
  }

  /// 当前视频的内封章节列表（TODO-424）；无章节 / 未 [load] 时为空。章节面板渲染用。
  List<VideoChapter> get chapters => List<VideoChapter>.unmodifiable(_chapters);

  /// 当前播放所在的章节下标（libmpv `chapter` 属性，0-based）；无章节 / 非 libmpv /
  /// 首章之前可能为负（章节面板据此高亮当前章；负/越界视为「无当前章」）。未 [load]
  /// 或解析失败时返回 null。
  Future<int?> currentChapterIndex() async {
    final String raw = await _getMpvProperty('chapter');
    if (raw.isEmpty) return null;
    return int.tryParse(raw.trim());
  }

  /// 从 libmpv 重新读取 `chapter-list` 填充 [_chapters]，读完 [notifyListeners]。
  ///
  /// 经 [_getMpvProperty]（`mpv_get_property_string`）逐条读 `chapter-list/count` +
  /// 每章 `title`/`time`，交给纯函数 [parseChapterList] 组装。仅 libmpv 后端（桌面
  /// 必生效；移动端走同一 libmpv 后端**预期一致**，但 media_kit 移动端是否暴露
  /// `chapter-list` 子属性字符串读取**待真机验**——失败时优雅降级成空列表，不影响
  /// 播放）。无 [_player] 时清空并返回。[load] 末尾、换集后调用。
  Future<void> refreshChapters() async {
    final Player? player = _player;
    if (player == null) {
      if (_chapters.isNotEmpty) {
        _chapters = const <VideoChapter>[];
        notifyListeners();
      }
      return;
    }
    await _refreshChaptersForLoad(player, _loadToken);
  }

  Future<void> _refreshChaptersForLoad(Player player, int loadToken) async {
    if (!_isCurrentLoad(player, loadToken)) return;
    final String countRaw = await _getMpvProperty('chapter-list/count');
    if (!_isCurrentLoad(player, loadToken)) return; // 读取期间换片 / 销毁：丢弃。
    final int total = int.tryParse(countRaw.trim()) ?? 0;
    if (total <= 0) {
      if (_chapters.isNotEmpty) {
        _chapters = const <VideoChapter>[];
        notifyListeners();
      }
      return;
    }
    // 逐条异步读 title/time 子属性（libmpv 属性读是异步的，纯函数 parseChapterList
    // 只覆盖「count + 同步解析」的单测路径，运行时按真实 getProperty 逐条组装）。
    final List<VideoChapter> chapters = <VideoChapter>[];
    for (int i = 0; i < total; i++) {
      final String title = await _getMpvProperty('chapter-list/$i/title');
      final String time = await _getMpvProperty('chapter-list/$i/time');
      if (!_isCurrentLoad(player, loadToken)) return; // 逐条读取期间换片：丢弃。
      final double seconds = double.tryParse(time.trim()) ?? 0.0;
      final int ms = (seconds * 1000).round();
      chapters.add(VideoChapter(
        index: i,
        title: title,
        start: Duration(milliseconds: ms < 0 ? 0 : ms),
      ));
    }
    _chapters = chapters;
    notifyListeners();
  }

  /// 按播放位置 [posMs] 同步算出所在章节下标（TODO-424）：起点 <= 位置的最后一章。
  /// 无章节 / 早于首章起点时返回 -1（章节面板据此「无高亮」）。供 UI 不依赖异步
  /// libmpv `chapter` 读取就能高亮当前章。
  int chapterIndexForPosition(int posMs) =>
      chapterIndexForPositionIn(_chapters, posMs);

  /// 跳到第 [index] 章（TODO-424）：seek 到该章起点。[index] 越界 / 无章节 / 未
  /// [load] 时 no-op 安全。用 seek 而非写 `chapter` 属性——seek 走与「上/下一句」同一
  /// 条经过验证的路径（[seekMs]，含 clamp），章节起点是精确时间戳，无需关键帧前导余量。
  Future<void> seekToChapter(int index) async {
    if (index < 0 || index >= _chapters.length) return;
    await seekMs(_chapters[index].start.inMilliseconds);
  }

  /// 跳到下一章（TODO-424）：已在末章 / 无章节时 no-op。当前章取自 libmpv `chapter`，
  /// 落在首章之前（负）时前进到首章。
  Future<void> nextChapter() async {
    await _seekAdjacentChapter(forward: true);
  }

  /// 跳到上一章（TODO-424）：已在首章 / 无章节时 no-op。
  Future<void> previousChapter() async {
    await _seekAdjacentChapter(forward: false);
  }

  /// 上/下一章共用：读当前 `chapter` → [adjacentChapterIndex] 决策目标 → [seekToChapter]。
  Future<void> _seekAdjacentChapter({required bool forward}) async {
    if (_chapters.isEmpty) return;
    final int current = (await currentChapterIndex()) ?? -1;
    final int? target = adjacentChapterIndex(
      chapterCount: _chapters.length,
      currentIndex: current,
      forward: forward,
    );
    if (target == null) return;
    await seekToChapter(target);
  }

  /// 测试可见：直接注入章节列表（不依赖 libmpv），驱动章节面板 widget 测试。
  @visibleForTesting
  void debugSetChaptersForTesting(List<VideoChapter> chapters) {
    _chapters = List<VideoChapter>.of(chapters);
    notifyListeners();
  }

  void setPauseAtSubtitleEnd(bool enabled) {
    _pauseAtSubtitleEnd = enabled;
    if (!enabled) {
      _lastSubtitleEndPauseCueIndex = null;
    }
  }

  /// 第 [cueIndex] 句是否该在句尾停：全局偏好开着（每句都停）**或**它正是一次性
  /// [replayCue] 的目标句。两个来源在此汇成单一判定，句尾时序只有一套实现。
  bool _holdEnabledForCue(int cueIndex) =>
      _pauseAtSubtitleEnd || _oneShotHoldCueIndex == cueIndex;

  /// 消耗一次性 hold（仅当它正指向 [cueIndex]）。停下即用完，避免用户之后自然播回
  /// 同一句时被再停一次。
  void _consumeOneShotHold(int cueIndex) {
    if (_oneShotHoldCueIndex == cueIndex) _oneShotHoldCueIndex = null;
  }

  /// 句尾落进 gap（下一拍无 cue）的暂停路径。此刻 [_currentCueIndex] 仍是**刚结束
  /// 那句**（调用点在把它清成 -1 之前），故一次性 hold 按它判定并消耗。
  void _pauseForSubtitleEnd() {
    final int endedCueIndex = _currentCueIndex;
    if (!_holdEnabledForCue(endedCueIndex)) return;
    _consumeOneShotHold(endedCueIndex);
    unawaited((_pauseAtSubtitleEndOverride ?? pause).call());
  }

  bool _shouldHoldAtSubtitleEnd(int nextCueIndex, int effectiveMs) {
    if (nextCueIndex < 0) return false;
    if (_currentCueIndex < 0 || _currentCueIndex >= _cues.length) {
      return false;
    }
    if (!_holdEnabledForCue(_currentCueIndex)) return false;
    if (nextCueIndex == _currentCueIndex) return false;
    final AudioCue cue = _cues[_currentCueIndex];
    if (effectiveMs <= cue.endMs) return false;
    if (_lastSubtitleEndPauseCueIndex == _currentCueIndex) return false;
    return _isPlayingForSubtitleEnd();
  }

  bool _isPlayingForSubtitleEnd() {
    final bool Function()? override = _pauseAtSubtitleEndIsPlayingOverride;
    if (override != null) return override();
    final Player? player = _player;
    if (player == null) return true;
    return player.state.playing;
  }

  void _pauseAndSeekForSubtitleEnd(AudioCue cue, int cueIndex) {
    _lastSubtitleEndPauseCueIndex = cueIndex;
    _consumeOneShotHold(cueIndex);
    unawaited(() async {
      await (_pauseAtSubtitleEndOverride ?? pause).call();
      final Future<void> Function(int positionMs) seekToEnd =
          _pauseAtSubtitleEndSeekOverride ?? seekMs;
      await seekToEnd(
        cueSeekTargetMs(cueStartMs: cue.endMs, delayMs: _delayMs),
      );
    }());
  }

  void _rearmSubtitleEndPauseIfNeeded(int effectiveMs) {
    final int? pausedCueIndex = _lastSubtitleEndPauseCueIndex;
    if (pausedCueIndex == null) return;
    if (pausedCueIndex < 0 || pausedCueIndex >= _cues.length) {
      _lastSubtitleEndPauseCueIndex = null;
      return;
    }
    if (effectiveMs < _cues[pausedCueIndex].endMs) {
      _lastSubtitleEndPauseCueIndex = null;
    }
  }

  /// 切换播放/暂停（未 load 时 no-op 安全）。
  Future<void> togglePlayPause() async {
    await _player?.playOrPause();
  }

  /// seek 到指定毫秒位置（未 load 时 no-op 安全）。
  ///
  /// **「主动跳转目标」快照的统一清除点（TODO-565 复核退回的必修项）。** 经本方法的
  /// 每一次 seek 都先清快照：章节跳转（[seekToChapter]）、相对 seek（[seekRelative]）、
  /// 收藏句直接跳转（页面层 `seekMs`）都汇于此（[seekMs] / [_rawSeekMs] 开头都调
  /// [_clearSeekTargetSnap]），落地前用户跳更早句不再被旧 [skipToCue] 目标误 snap 回去。
  /// **唯一例外是 [skipToCue] 自己**——它要在本 seek **之后**才置快照+宽限，故先调
  /// [_rawSeekMs]（在这里把上一个快照清掉）、再置自己的快照，绝不会被本清除点自清
  /// （见 [skipToCue] 注释）。进度条拖动经 media_kit 内部 `player.seek`
  /// 绕过本方法，由页面层 [clearSeekTargetSnap] 单独清（media_kit seek bar 不暴露回调）。
  ///
  /// 除清快照外，本方法还给普通 seek 挂「在途保护」（[_plainSeekTargetMs]）：一发 seek 就按
  /// 目标位置**权威同步一次字幕**（不等滞后的 player position），字幕即时反映跳转目的地（gap
  /// 则立即消失），随后 tick 经 [_reconcileSeekInFlightPosition] 抑制旧 position 的瞬态回跳，
  /// 修「±秒跳转到 gap 后旧字幕不消失」（尤其暂停重听时）。[skipToCue] 自带 cue-snap，走
  /// [_rawSeekMs] 不吃本保护，避免权威同步先把目标清成 preRoll gap、下一拍才 snap 回而闪烁。
  Future<void> seekMs(int positionMs) async {
    final int clampedMs = positionMs.clamp(0, 1 << 30);
    _clearSeekTargetSnap();
    // 用户主动改变播放位置 = 放弃「只播这一句就停」的意图（[_oneShotHoldCueIndex]）。
    _oneShotHoldCueIndex = null;
    _beginPlainSeekInFlight(clampedMs);
    // 权威同步：直接按目标位置算一次字幕（不经 tick 的位置调和），gap 则立即清空。
    _syncCueForPosition(clampedMs, persistPosition: false);
    await _player?.seek(Duration(milliseconds: clampedMs));
  }

  /// 直发 player seek（只清「主动跳转目标」快照，**不**置普通 seek 在途保护）——[skipToCue]
  /// 专用：它自带 [_seekTargetCueIndex] 快照抑制在途 lag，且需要本清除点先清上一次快照、再由
  /// 自己在 seek **之后**置新快照（见 [skipToCue] / [_clearSeekTargetSnap] 注释）。若改走会置
  /// 在途保护的 [seekMs]，seek 前的权威同步会先把目标句清成 preRoll 落点的 gap、下一拍才随
  /// 快照 snap 回目标，凭空多一次闪烁。
  Future<void> _rawSeekMs(int positionMs) async {
    _clearSeekTargetSnap();
    // 同 [seekMs]：跳到别的句（[skipToCue]）即放弃上一次「只播这一句就停」。
    // [replayCue] 是唯一例外——它在本方法**之后**才置自己的一次性 hold，与
    // [skipToCue] 置 [_seekTargetCueIndex] 的顺序契约完全同构，故不会被自清。
    _oneShotHoldCueIndex = null;
    await _player?.seek(Duration(milliseconds: positionMs.clamp(0, 1 << 30)));
  }

  /// 相对当前位置 seek（±[deltaMs]，如 ±10 秒），clamp 到 [0, duration]。
  /// 未 load（无位置）时 no-op 安全。
  Future<void> seekRelative(int deltaMs) async {
    // 用户主动相对 seek 是「离开当前跳转目标」的明确意图：立刻作废主动跳转快照 + 在途
    // seek 宽限，让下个 tick 按真实位置纯推导高亮，不被旧 [skipToCue] 目标误 snap
    // （TODO-565：手动 seek 与 skipToCue 不同路径，手动 seek 仍能清快照）。
    // 显式清此处**仍必要**：[positionMs] 为 null 时下面提前 return、走不到 [seekMs] 的
    // 统一清除点，靠这一句保证无 position（未 load）时快照也被清；有 position 时与
    // [seekMs] 的清除二次重叠、无害幂等。
    _clearSeekTargetSnap();
    final int? pos = positionMs;
    if (pos == null) return;
    await seekMs(clampSeekTargetMs(pos, deltaMs, durationMs));
  }

  /// 纯函数：相对 seek 目标 clamp 到 [0, duration]（duration 未知时只保证 >=0）。
  /// 抽出便于单测（[seekRelative] 本身需真实 player 无法纯测）。
  static int clampSeekTargetMs(int posMs, int deltaMs, int? durationMs) {
    final int target = posMs + deltaMs;
    if (target < 0) return 0;
    if (durationMs != null && durationMs > 0 && target > durationMs) {
      return durationMs;
    }
    return target;
  }

  /// 设置播放倍速（未 load 时也记下 [_lastSpeed]，下次 load 不丢）。
  Future<void> setSpeed(double rate) async {
    _lastSpeed = rate;
    await _player?.setRate(rate);
  }

  /// 设置可听音量（0..100）。写非零音量即解除静音（「从静音加音量 = 从 0 起音」
  /// 的合理语义）。**只写音量目标 [_lastVolume]，绝不碰 [_volumeBeforeMute]**——
  /// 静音期间调音量不污染「静音前音量」，取消静音仍回到确定值。
  Future<void> setVolume(double value) async {
    _lastVolume = value.clamp(0.0, 100.0).toDouble();
    if (_lastVolume > 0) _muted = false;
    await _player?.setVolume(_lastVolume);
  }

  /// 在当前**有效输出音量**（静音时为 0，否则为 [volume]）基础上增减 [delta] 并
  /// clamp 到 0..100，写穿 player，返回**确定的新音量**供 UI 直接刷新显示/OSD，
  /// 不必再去读异步滞后的 [volume]。从静音态加音量会经 [setVolume] 解除静音、从 0 起音。
  Future<double> adjustVolume(double delta) async {
    final double base = _muted ? 0.0 : volume;
    final double next = (base + delta).clamp(0.0, 100.0).toDouble();
    await setVolume(next);
    return next;
  }

  /// 切换静音，返回**取消静音后的有效目标音量**（静音返回 0，取消静音返回静音前音量），
  /// 供 UI 直接据此刷新图标/滑条/OSD——不再读异步滞后的 [volume]（取消静音那一帧
  /// libmpv 的 `state.volume` 仍是 0，读它会让显示停在 0，恢复不了，正是 TODO-433 bug2）。
  ///
  /// 进入静音：把当前真实可听音量快照进 [_volumeBeforeMute]（优先用 player 已生效的
  /// `state.volume>0`，否则回退最近请求的 [_lastVolume]），置 [_muted]，把 player 音量
  /// 压 0。**直接 `_player.setVolume(0)` 而非走 [setVolume(0)]**——后者会把音量目标
  /// [_lastVolume] 也改成 0，污染取消静音的恢复值。
  /// 取消静音：把 player 音量恢复到 [_volumeBeforeMute]，并经 [setVolume] 让音量目标
  /// 与静音态一致回到该值。
  Future<double> toggleMute() async {
    if (_muted) {
      // 取消静音：恢复到静音前音量（setVolume 内部会清 _muted）。
      await setVolume(_volumeBeforeMute);
      return _volumeBeforeMute;
    }
    // 进入静音：先快照当前可听音量，再压 0。
    final double live = _player?.state.volume ?? _lastVolume;
    _volumeBeforeMute =
        (live > 0 ? live : _lastVolume).clamp(0.0, 100.0).toDouble();
    _muted = true;
    await _player?.setVolume(0.0);
    return 0.0;
  }

  /// 句子跳转（上/下一句）的前导余量（毫秒）。
  ///
  /// media_kit / libmpv 的 [Player.seek] **不是帧精确**的：请求 seek 到某毫秒位置后，
  /// 播放器会把落点吸附到最近的可解码点（关键帧），而吸附**几乎总落在请求位置之后**
  /// 几十到几百毫秒。结果：按「上/下一句」精确 seek 到 `cue.startMs` 时，真正落点已
  /// 越过句首，听到的句子开头被吃掉 0.x 秒（BUG-259）。
  ///
  /// 修法是请求 seek 到 `cueStartMs - 前导余量`，让关键帧吸附后的实际落点回到句首或
  /// 略前，吸收吸附幅度。取 180ms 作经验值：足够吸收常见容器的关键帧间隔尾差，又不至于
  /// 大到把整句开头之前一大段静音/上一句尾巴也带进来；并由 [cueSeekTargetMs] 的「不早于
  /// 上一句起点」下界兜住，确保再大的余量也不会串到前一句。真机若仍偏，调此常量即可。
  static const int kCueSeekPreRollMs = 180;

  /// 跳到指定 cue 的起始位置。
  ///
  /// 用 [kCueSeekPreRollMs] 前导余量吸收 media_kit 关键帧吸附（BUG-259），并把下界
  /// 钳到「上一句起点」以免余量过大串回前一句。上一句起点经 [_prevCueStartMsBefore]
  /// 在升序 [_cues] 上二分求得（无上一句时为 null）。
  Future<void> skipToCue(AudioCue cue) async {
    // 解析目标下标（TODO-565）：seek 落点因 preRoll 偏到目标句之前，落地后那一瞬 position
    // 反推会判成上一句，靠这个快照让 [_syncCueForPosition] 在 preRoll 引导窗口内把高亮
    // snap 回目标句，消除「点第 N 行高亮 N-1」。解析不到下标（cue 不在 _cues）时为 null，
    // 退回纯位置推导。**在 seek 之前先算好**，避免下面 await 期间 _cues 被异步改写。
    final int? targetIndex = _resolveCueIndex(cue);
    // **顺序关键（TODO-565 复核退回的必修项）**：先 await [_rawSeekMs] 发出 seek——它开头
    // 会把**上一个**主动跳转快照清掉（统一清除点），故本句快照必须在它**之后**才置，否则会被
    // 自清成 off-by-one 又复发。await 与同步置快照在单线程事件循环里对后续 tick 等价可见
    // （tick 不会插在 await 与置快照之间读到半截状态）。用 [_rawSeekMs] 而非 [seekMs]：后者
    // 会挂普通 seek 在途保护 + 权威同步，与本路径自带的 cue-snap 抑制重复且会引入闪烁。
    await _rawSeekMs(cueSeekTargetMs(
      cueStartMs: cue.startMs,
      delayMs: _delayMs,
      preRollMs: kCueSeekPreRollMs,
      prevCueStartMs: _prevCueStartMsBefore(cue.startMs),
    ));
    _seekTargetCueIndex = targetIndex;
    // 充满在途 seek 宽限（TODO-565 复核退回的真机时序）：异步 seek 落地前 tick 会先读到
    // 旧 position，宽限让快照撑到落点，避免在途 stale tick 把快照提前清掉 → off-by-one。
    // 目标解析不到（cue 不在 _cues，_seekTargetCueIndex==null）时无需宽限，留 0。
    _seekSnapGraceTicksLeft =
        _seekTargetCueIndex == null ? 0 : _seekSnapGraceTicks;
  }

  /// 重播 [cue]：跳回句首并播放，**播到该句结尾自动暂停**（一次性）。
  ///
  /// 供查词浮层顶栏「重播本句」使用（听不清就地重听，不必手动倒回再按暂停）。
  ///
  /// 与 [skipToCue] 的差别只有两点：本方法会**主动起播**，并给这一句挂一次性
  /// [_oneShotHoldCueIndex]。句尾停下的判定、落点与防重复停完全复用「字幕结束暂停」
  /// 那套（[_shouldHoldAtSubtitleEnd] / [_pauseAndSeekForSubtitleEnd]），因此倍速、
  /// 字幕延迟（[_delayMs]）、关键帧吸附、seek 在途 lag 全部自动吃到同一份处理——
  /// **不是**在 UI 层按 `endMs - startMs` 起个定时器等句长（那种做法会被倍速、缓冲、
  /// 用户中途 seek 逐一打穿）。
  ///
  /// 一次性 hold 的作废由 [seekMs] / [_rawSeekMs] / [setCues] 负责：用户中途拖进度、
  /// 跳去别的句或换片，都立刻放弃「停在本句尾」的意图。全局偏好
  /// `字幕结束暂停`（[setPauseAtSubtitleEnd]）与本方法正交，互不改写。
  Future<void> replayCue(AudioCue cue) async {
    // 先 seek（内部 [_rawSeekMs] 会清掉上一次的一次性 hold），再置本次目标——顺序与
    // [skipToCue] 置 [_seekTargetCueIndex] 同构，故绝不会被自清。
    await skipToCue(cue);
    final int? targetIndex = _resolveCueIndex(cue);
    if (targetIndex != null) {
      _oneShotHoldCueIndex = targetIndex;
      // 这一句可能刚被句尾暂停过（全局开关开着时）。不清防重复记号的话，重播到句尾会
      // 被 [_shouldHoldAtSubtitleEnd] 的「停过就不再停」挡掉、直接播进下一句。
      _lastSubtitleEndPauseCueIndex = null;
    }
    // targetIndex == null（目标不在当前 cue 列表，换轨/换片竞态）：仍已 seek 到位，
    // 但没有可挂 hold 的下标，退化成「跳过去接着播」，不静默假装能停。
    // 两条分支共用同一个起播出口——分头调 play 会让退化路径绕开测试注入、也埋下
    // 「以后只改一处」的隐患。
    await (_replayPlayOverride ?? play).call();
  }

  /// 测试可见：当前一次性「只播这一句就停」目标下标（[_oneShotHoldCueIndex]）。
  @visibleForTesting
  int? get debugOneShotHoldCueIndex => _oneShotHoldCueIndex;

  /// 升序 cue 列表上按 `startMs` 二分求分界下标（要求 [cues] 已按 startMs 升序）：
  /// - [inclusive] 为 false：lower bound——返回首个 `startMs >= value` 的下标；
  /// - [inclusive] 为 true：upper bound——返回首个 `startMs > value` 的下标
  ///   （即「起点 <= value」的条数）。
  /// 全部更小 / 全部更大时相应返回 `cues.length` / 0。此前 [_resolveCueIndex] /
  /// [_prevCueStartMsBefore] / [prevCueIndexFor] gap 分支 / [_floorCueIndexByPosition]
  /// 各内联一份同形 `while (lo < hi)` 二分（仅比较符不同），收敛于此；各点的边界语义
  /// （首个 >= / 最后一个 < / 最后一个 <=）由调用方对返回值加减与判空表达。
  static int _cueStartMsBinaryBound(
    List<AudioCue> cues,
    int value, {
    required bool inclusive,
  }) {
    int lo = 0;
    int hi = cues.length;
    while (lo < hi) {
      final int mid = (lo + hi) >>> 1;
      final int startMs = cues[mid].startMs;
      if (inclusive ? startMs <= value : startMs < value) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// 求 [cue] 在升序 [_cues] 中的下标；优先按对象同一性（面板/导航传的就是 _cues 元素），
  /// 退而按 `startMs` 二分（防御性，cue 是等价副本时）。找不到返回 null。
  int? _resolveCueIndex(AudioCue cue) {
    final int direct = _cues.indexOf(cue);
    if (direct >= 0) return direct;
    // lower bound（首个 startMs >= cue.startMs），起点相等才算命中。
    final int lo = _cueStartMsBinaryBound(_cues, cue.startMs, inclusive: false);
    if (lo < _cues.length && _cues[lo].startMs == cue.startMs) return lo;
    return null;
  }

  /// 在升序 [_cues] 上求「起点严格早于 [cueStartMs] 的最后一条」的起点（即上一句起点）；
  /// 无更早的 cue 时返回 null。供 [skipToCue] 钳前导余量下界，避免 seek 串回前一句。
  int? _prevCueStartMsBefore(int cueStartMs) {
    // lower bound 左侧即「起点严格 < cueStartMs」的全部 cue，取其最后一条的起点。
    final int lo = _cueStartMsBinaryBound(_cues, cueStartMs, inclusive: false);
    return lo == 0 ? null : _cues[lo - 1].startMs;
  }

  /// 把 cue 时间轴上的目标点反算回播放器 seek 时间轴。
  ///
  /// cue 命中使用 [effectiveSubtitlePositionMs]：`effective = playerPos - delay`。
  /// 因此跳到某个 cue 起点/终点时必须做逆变换：`playerPos = cueTime + delay`。
  ///
  /// [preRollMs]：句子跳转的前导余量（>=0），在 cue 时间轴上把目标点往**前**移，吸收
  /// media_kit 关键帧吸附把落点推到句首之后的偏差（BUG-259）。默认 0 —— 字幕结束暂停
  /// （[_pauseAndSeekForSubtitleEnd] 用 `cueStartMs: cue.endMs`）等精确 seek 不能加余量，
  /// 否则会把暂停点拉回句中，故只有 [skipToCue] 传非零余量。
  ///
  /// [prevCueStartMs]：上一句起点（cue 时间轴，可空）。前导余量减完后下界钳到它，
  /// 保证再大的余量也不会把落点拉回上一句，避免「上/下一句」误带前句尾巴。
  @visibleForTesting
  static int cueSeekTargetMs({
    required int cueStartMs,
    required int delayMs,
    int preRollMs = 0,
    int? prevCueStartMs,
  }) {
    // 1) 在 cue 时间轴上扣前导余量，下界不为负。
    int cueTarget = cueStartMs - (preRollMs < 0 ? 0 : preRollMs);
    if (cueTarget < 0) cueTarget = 0;
    // 2) 不早于上一句起点（防止余量过大串回前一句）。
    if (prevCueStartMs != null && cueTarget < prevCueStartMs) {
      cueTarget = prevCueStartMs;
    }
    // 3) 逆变换到播放器轴并 clamp。
    return (cueTarget + delayMs).clamp(0, 1 << 30).toInt();
  }

  /// 跳到下一句 cue（已是最后一句时 no-op）。
  ///
  /// 目标索引经 [nextCueIndexFor] 决策，**完全按实时 [positionMs] 定位当前句再取
  /// 下一条**（TODO-410），不读滞后的 [_currentCueIndex]：句中按位置 floor 即当前
  /// 句，下一句 = floor+1（严格排除当前句，不会「下一句跳到当前句」）；落在句间
  /// gap（[updateCueForPosition] 在 gap 把 [_currentCueIndex] 清成 -1，BUG-074）
  /// 时同样按 floor 取它的下一条，绝不裸用 `-1 + 1`（=0）打回原点（BUG-175）；
  /// 早于首句时前进到首句（BUG-176/189）。
  Future<void> skipToNextCue() async {
    if (_cues.isEmpty) return;
    final int? next = nextCueIndexFor(
      cues: _cues,
      positionMs: _effectivePositionMs,
      anchorIndex: _seekTargetCueIndex,
    );
    if (next == null) return;
    await skipToCue(_cues[next]);
  }

  /// 跳到上一句 cue（已是第一句时 no-op）。
  ///
  /// 目标索引经 [prevCueIndexFor] 决策，**完全按实时 [positionMs] 定位**（TODO-410），
  /// 不读滞后的 [_currentCueIndex]：句中取当前句的前一条（严格排除当前句，方案 B）；
  /// 落在 gap（findCueIndex 返回 -1）时按 [positionMs] 二分回退到 gap 之前刚播完那条
  /// —— 旧实现裸用 `_currentCueIndex - 1`（=-2）在 gap 里恒越界 no-op，句子后退在静音
  /// 间隙完全失灵（BUG-175）。回到当前句句首「重播本句」是另一条独立路径
  /// （[skipToCue]，TODO-378/BUG-287），不走这里。
  Future<void> skipToPrevCue() async {
    if (_cues.isEmpty) return;
    final int? prev = prevCueIndexFor(
      cues: _cues,
      positionMs: _effectivePositionMs,
      anchorIndex: _seekTargetCueIndex,
    );
    if (prev == null) return;
    await skipToCue(_cues[prev]);
  }

  /// 跳上一句字幕。无 cue 时退化成回退 [seekSeconds] 秒（当回退键，让用户跨过没字幕的
  /// 转场段，TODO-119/BUG-198）；有 cue 时的行为由 [degradeFarCueToTimeSeek] 决定：
  ///
  /// - `false`（**默认**，按钮 / 手柄 / 双击 / 控制项语义，BUG-942）：**恒跳到相邻上一句**，
  ///   哪怕上一句距当前很远也不退化——「上一句字幕」按钮就该跳句，不该悄悄变成 3 秒 seek。
  /// - `true`（键盘 Ctrl+← 语义，TODO-085）：上一句起点距当前 > `seekSeconds` 秒时退化成
  ///   回退 `seekSeconds` 秒（方向键的 seek 心智；纯时间 seek 另有 ←/→）。
  ///
  /// 决策集中在纯函数 [prevSeekDecisionFor]。无 cue / 已在首句时 no-op 安全。
  Future<void> skipToPrevCueOrSeekBack({
    required int seekSeconds,
    bool degradeFarCueToTimeSeek = false,
  }) async {
    if (_cues.isEmpty) {
      // 无字幕：当回退键，直接回退 seekSeconds 秒（与页面层「无 cue 走时间 seek」一致，
      // 集中决策便于单测）。
      await seekRelative(-seekSeconds * 1000);
      return;
    }
    final PrevSeekDecision decision = prevSeekDecisionFor(
      cues: _cues,
      positionMs: _effectivePositionMs,
      seekSeconds: seekSeconds,
      anchorIndex: _seekTargetCueIndex,
      degradeFarCueToTimeSeek: degradeFarCueToTimeSeek,
    );
    if (decision.cueIndex != null) {
      await skipToCue(_cues[decision.cueIndex!]);
    } else if (decision.timeSeekDeltaMs != null) {
      await seekRelative(decision.timeSeekDeltaMs!);
    }
    // PrevSeekDecision.none：已在首句，保持 no-op（不强行回退到负位置）。
  }

  /// 「下一句」按钮 / 键盘用：跳到下一句字幕，但**无字幕时退化成前进 [seekSeconds]
  /// 秒**（TODO-073）。与 [skipToPrevCueOrSeekBack] 对称——后者无字幕时当回退键，这里
  /// 无字幕时当快进键。动机：用户报「OP 段没有字幕时按下一句字幕按钮，画面像回到开头
  /// 一样不前进」。根因是空 [_cues] 时旧的 [skipToNextCue] 直接 no-op，按钮毫无反应，
  /// 用户感知为「卡住 / 没动」；有字幕时 [skipToNextCue] 本就正确前进（[nextCueIndexFor]
  /// 在 OP gap 里二分定位首句、永不回原点，BUG-176）。
  ///
  /// 决策：
  /// - 空 [_cues]：前进 [seekSeconds] 秒（让用户能跨过没有字幕的 OP；下界 clamp 同
  ///   [seekRelative]，不会变成负位置 / 回开头）。
  /// - 有下一句 cue：跳到该 cue 起点（[skipToNextCue] 同源决策，OP gap 里也前进到首句）。
  /// - 已在末句之后（无下一句）：no-op（保持原位，**不**强行前进越过片尾）。
  Future<void> skipToNextCueOrSeekForward({required int seekSeconds}) async {
    if (_cues.isEmpty) {
      // 无字幕：下一句键当快进键，前进 seekSeconds 秒（与键盘 nextSubtitle 旧的
      // `cues.isEmpty ? seekRelative(+X)` 内联分支同语义，集中到此处便于单测 + 按钮共享）。
      await seekRelative(seekSeconds * 1000);
      return;
    }
    final int? next = nextCueIndexFor(
      cues: _cues,
      positionMs: _effectivePositionMs,
      anchorIndex: _seekTargetCueIndex,
    );
    // next == null：已在末句之后，无下一句 → 保持 no-op（不前进越过片尾，避免误跳到结尾）。
    if (next == null) return;
    await skipToCue(_cues[next]);
  }

  /// 纯函数：「下一句」目标索引（[skipToNextCue] 决策，抽出便于单测）。
  ///
  /// **唯一真相源是实时 [positionMs]**，不再读成员变量 `_currentCueIndex`（TODO-410）：
  /// 后者由 125ms tick 的 [updateCueForPosition] 异步更新，存在滞后窗口——用户 seek
  /// 进某句后 tick 尚未追平时，旧实现裸信 `_currentCueIndex` 会算出当前句本身（在该句
  /// 内 `_currentCueIndex` 仍停在上一句、`+1` 恰好等于当前句），表现为「下一句跳到当前
  /// 句」。改用 [_floorCueIndexByPosition] 按 `positionMs` 定位「当前/最近一条起点 <=
  /// 位置」的 cue（句中或 gap 都返回它），其下一条即真正的下一句，**严格排除当前句**。
  ///
  /// - 位置早于全部 cue（floor < 0）：下一句 = 首句（索引 0）。
  /// - floor 已是末句（floor + 1 越界）：返回 null（已无下一句，保持 BUG-176/189 边界）。
  ///
  /// 注意**不能**用 [JsonAlignmentParser.findCueIndex] 求 floor ——它在 gap 内（含
  /// 「末句之后」与「首句之前」）一律返回 -1，无法区分「早于首句」与「某句之后的
  /// gap」，会把后者也误当首句之前。这里需要 floor 语义而非命中语义。
  ///
  /// [anchorIndex]（TODO-571）：上一次主动跳转（[skipToCue]）落定的目标句下标，由
  /// 调用方传 [_seekTargetCueIndex]。非空且在范围内时，**直接 `anchor + 1`**，绕过按
  /// `positionMs` 反推 floor。根因：[skipToCue] 的 seek 落点因 [kCueSeekPreRollMs]
  /// 前导余量故意偏到目标句**之前** `startMs - preRoll`（BUG-259 听感）。连续按「下一
  /// 句」时，第二次读到的 `positionMs` 正是这个偏前落点，[_floorCueIndexByPosition]
  /// 据 `startMs <= pos` 把当前句反推成**目标句的上一句**，`+1` 又指回刚跳到的目标句
  /// → 表现为「下一句按了不动 / 原地」（与「上一句跳过头」对称）。锚定权威的「刚跳到
  /// 哪句」消除这层偏移。`anchor + 1` 越界（已是末句）返回 null，保持末句 no-op 边界。
  static int? nextCueIndexFor({
    required List<AudioCue> cues,
    required int? positionMs,
    int? anchorIndex,
  }) {
    if (cues.isEmpty) return null;
    if (anchorIndex != null && anchorIndex >= 0 && anchorIndex < cues.length) {
      // 锚定「上次主动跳到的目标句」：下一句严格 = anchor+1，不被 preRoll 偏前落点干扰。
      final int next = anchorIndex + 1;
      return next >= cues.length ? null : next;
    }
    final int floor = _floorCueIndexByPosition(cues, positionMs ?? 0);
    if (floor < 0) return 0; // 早于首句：下一句 = 首句。
    if (floor + 1 >= cues.length) return null; // floor 已是末句：无下一句。
    return floor + 1; // 排除当前句（floor），取下一条。
  }

  /// 纯函数：「上一句」目标索引（[skipToPrevCue] 决策，与 [nextCueIndexFor] 对称）。
  ///
  /// **唯一真相源是实时 [positionMs]**，不再读 `_currentCueIndex`（TODO-410，同
  /// [nextCueIndexFor]）。两种语义并存，按位置是否落在某句**时间窗内**区分：
  ///
  /// - **句中**（[JsonAlignmentParser.findCueIndex] 命中某句 `hit >= 0`，含句首
  ///   `pos == startMs`）：当前句 = hit，上一句 = `hit - 1`，**严格排除当前句**
  ///   （方案 B，与 [nextCueIndexFor] 对称）；hit == 0（已在首句）返回 null。回到
  ///   当前句句首「重播本句」是另一条独立路径（[skipToCue]），不走这里。
  /// - **gap / 早于首句**（findCueIndex 返回 -1）：此刻没有正在播放的句子，「上一句」=
  ///   gap 之前刚播完那条（最近一条起点 < 位置的 cue）；早于全部 cue 时落首句（索引 0）。
  ///   这保留了 TODO-085/119 转场 gap 回退决策赖以计算「上一句距当前多远」的参照。
  ///
  /// [anchorIndex]（TODO-571）：上一次主动跳转（[skipToCue]）落定的目标句下标，由
  /// 调用方传 [_seekTargetCueIndex]。非空且在范围内时，**直接 `anchor - 1`**，绕过按
  /// `positionMs` 反推。根因（与 [nextCueIndexFor] 对称）：[skipToCue] 落点因前导余量
  /// [kCueSeekPreRollMs] 偏到目标句**之前** `startMs - preRoll`（BUG-259 听感）。连续按
  /// 「上一句」时，第二次读到的 `positionMs` 是这个偏前落点，[JsonAlignmentParser.findCueIndex]
  /// 反推命中**目标句的上一句**（落点已退进上一句时间窗），`hit - 1` 于是跳到上上句
  /// → **跳过头**（跳到 N-2 而非相邻 N-1，正是用户报「感觉跳过头了」）。锚定权威的
  /// 「刚跳到哪句」消除偏移。`anchor - 1 < 0`（已在首句）返回 null，保持首句 no-op 边界。
  static int? prevCueIndexFor({
    required List<AudioCue> cues,
    required int? positionMs,
    int? anchorIndex,
  }) {
    if (cues.isEmpty) return null;
    if (anchorIndex != null && anchorIndex >= 0 && anchorIndex < cues.length) {
      // 锚定「上次主动跳到的目标句」：上一句严格 = anchor-1，不被 preRoll 偏前落点干扰。
      final int prev = anchorIndex - 1;
      return prev < 0 ? null : prev;
    }
    final int pos = positionMs ?? 0;
    // 句中（命中某句时间窗，含句首）：当前句 = hit，上一句 = hit-1，排除当前句。
    final int hit =
        JsonAlignmentParser.findCueIndex(cues: cues, positionMs: pos);
    if (hit >= 0) {
      return hit == 0 ? null : hit - 1; // 已在首句无上一句。
    }
    // gap / 早于首句：找起点 < 位置的最后一条（gap 之前刚播完那句）；位置正好压在
    // 某句起点上时由上面 hit 分支处理，这里恒落在 gap，故二分用严格 `<`（lower
    // bound，inclusive: false）；早于全部 cue 时落首句（索引 0）。
    final int lo = _cueStartMsBinaryBound(cues, pos, inclusive: false);
    return lo == 0 ? 0 : lo - 1;
  }

  /// 纯函数：asbplayer 式「字幕偏移对齐」——把**上一句 / 下一句**字幕的起点整体平移到
  /// 当前播放点 [positionMs]，返回应写入的**新 delayMs**；无相邻 cue（首/末句边界）或
  /// 位置未就绪时返回 null（调用方据此 no-op，不改延迟）。
  ///
  /// 与 z/x 的固定步进平移不同：这里按目标 cue 求**绝对**偏移，一键把整轨粗对齐到当前
  /// 台词时刻（再配合 z/x 微调）。「上一句 / 下一句」复用与 Ctrl+←/→ 跳句同一决策
  /// （[nextCueIndexFor] / [prevCueIndexFor]），认定的是同一条 cue，心智模型一致。
  ///
  /// 坐标系换算（与 controller 判 cue 命中同源）：cue 命中用等效位置
  /// `effective = playerPos - delay`（[effectiveSubtitlePositionMs]），故先把当前
  /// [positionMs] 去掉已应用的 [currentDelayMs] 得到**原始时间轴**位置 `effPos`，据此
  /// 找相邻 cue；再令目标 cue 恰好在此刻出现：`target.startMs + newDelay == positionMs`，
  /// 即 `newDelay = positionMs - target.startMs`。写穿仍走既有 setDelayMs（clamp + 落盘）。
  ///
  /// [next] 为 true 取下一句、false 取上一句。不传 anchorIndex（对轴不是主动跳转，
  /// 无 preRoll 偏前落点，纯按 effPos 反推即可）。
  static int? snapSubtitleDelayMs({
    required List<AudioCue> cues,
    required int? positionMs,
    required int currentDelayMs,
    required bool next,
  }) {
    if (cues.isEmpty || positionMs == null) return null;
    final int effPos = effectiveSubtitlePositionMs(positionMs, currentDelayMs);
    final int? idx = next
        ? nextCueIndexFor(cues: cues, positionMs: effPos)
        : prevCueIndexFor(cues: cues, positionMs: effPos);
    if (idx == null || idx < 0 || idx >= cues.length) return null;
    return positionMs - cues[idx].startMs;
  }

  /// 纯函数：「上一句」seek 决策。目标上一句由 [prevCueIndexFor] 决定；
  /// [degradeFarCueToTimeSeek] 控制「上一句太远」时的行为：
  ///
  /// - `true`（**默认**，键盘 Ctrl+← 语义，TODO-085）：目标上一句起点距当前位置 gap
  ///   大于 [seekSeconds] 秒时**退化成回退 [seekSeconds] 秒的时间 seek**，而不是一脚跳到
  ///   很远的上一句——对照用户诉求「如果上一句话距离很远了，左右键就回退到回退 3 秒的模式」。
  /// - `false`（按钮 / 手柄 / 双击 / 控制项语义，BUG-942）：**永远跳句**，不因太远退化——
  ///   「上一句字幕」按钮就该跳到相邻上一句。
  ///
  /// 具体：
  /// - 无上一句（已在首句 / 空列表）：返回 [PrevSeekDecision.none]（保持原 no-op 不强行 seek）。
  /// - `degradeFarCueToTimeSeek == false`，或 [seekSeconds] <= 0（阈值失效，防御性）：跳到该 cue。
  /// - 目标上一句起点距当前 `<= seekSeconds*1000` ms：跳到该 cue（句子 seek）。
  /// - 目标上一句起点距当前 `> seekSeconds*1000` ms：返回 [PrevSeekDecision.timeSeek]（回退 `seekSeconds` 秒）。
  static PrevSeekDecision prevSeekDecisionFor({
    required List<AudioCue> cues,
    required int? positionMs,
    required int seekSeconds,
    int? anchorIndex,
    bool degradeFarCueToTimeSeek = true,
  }) {
    final int? prev = prevCueIndexFor(
      cues: cues,
      positionMs: positionMs,
      anchorIndex: anchorIndex,
    );
    if (prev == null) return PrevSeekDecision.none;
    if (!degradeFarCueToTimeSeek || seekSeconds <= 0) {
      return PrevSeekDecision.cue(prev);
    }
    final int pos = positionMs ?? 0;
    final int gapMs = pos - cues[prev].startMs;
    final int thresholdMs = seekSeconds * 1000;
    if (gapMs > thresholdMs) {
      return PrevSeekDecision.timeSeek(-thresholdMs);
    }
    return PrevSeekDecision.cue(prev);
  }

  /// 二分求「起点 <= [positionMs] 的最后一条 cue」的下标（floor 语义）；位置早于
  /// 全部 cue 时返回 -1。要求 [cues] 已按 `startMs` 升序（[setCues] 保证）。
  static int _floorCueIndexByPosition(List<AudioCue> cues, int positionMs) {
    // upper bound（首个 startMs > positionMs）减一即 floor。
    return _cueStartMsBinaryBound(cues, positionMs, inclusive: true) - 1;
  }

  @override
  void dispose() {
    _loadToken++;
    // 退出前强制记录当前位置：周期保存的整秒节流会吞掉退出瞬间同一整秒内的最后
    // 几百毫秒进度。这里在 [_player] 仍存活时同步读位置并 fire-and-forget 写一次
    // （绕过节流），保证「退出再进恢复到上次位置」。可 await 的可靠落库由
    // [VideoFushiPage.dispose] 在调用本方法前先 [flushPosition] 完成。
    _forceSavePositionSync();
    _tick?.cancel();
    _tick = null;
    unawaited(_playingSub?.cancel());
    _playingSub = null;
    unawaited(_completedSub?.cancel());
    _completedSub = null;
    _onCompleted = null;
    unawaited(_widthSub?.cancel());
    _widthSub = null;
    unawaited(_heightSub?.cancel());
    _heightSub = null;
    unawaited(_bufferingReadySub?.cancel());
    _bufferingReadySub = null;
    unawaited(_durationReadySub?.cancel());
    _durationReadySub = null;
    unawaited(_audioDeviceSub?.cancel());
    _audioDeviceSub = null;
    // TODO-1212：注销文件句柄释放登记（迁移路径不再触达已销毁的本控制器）。
    final MediaHandleReleaseCallback? registration = _mediaHandleRegistration;
    if (registration != null) {
      MediaHandleRegistry.instance.unregister(registration);
      _mediaHandleRegistration = null;
    }
    // dispose 同步签名无法 await——底层 libmpv 释放 fire-and-forget（若迁移
    // 已先经 [_releaseMediaHandles] 放掉句柄并置 null，这里是 no-op）。
    unawaited(_player?.dispose());
    _player = null;
    _videoController = null;
    _loadedLuaScripts.clear(); // 与 [_releaseMediaHandles] 一致，防复用残留。
    _videoPath = null;
    _chapters = const <VideoChapter>[];
    super.dispose();
  }

  /// TODO-1212：可 await 的文件句柄释放（[MediaHandleRegistry] 迁移前调用）。
  /// 先 `await _player.dispose()` 真放掉底层 libmpv 视频/字幕文件句柄再返回，之后
  /// 数据根 rename 不会撞「文件被占用」。置 `_player=null` 使后续 [dispose] 的
  /// fire-and-forget 释放退化为 no-op（幂等，不会二次 dispose 同一 Player）。
  Future<void> _releaseMediaHandles() async {
    final Player? player = _player;
    if (player == null) return;
    _player = null;
    _videoController = null;
    _loadedLuaScripts.clear(); // 新 Player 必须重新 load-script（见字段注释）。
    await player.dispose();
  }

  /// 同步强制写一次当前位置（绕过整秒节流），供 [dispose] 兜底调用。
  /// [onPositionWrite] 的写库 Future 在此 fire-and-forget（dispose 不能 await）。
  void _forceSavePositionSync() {
    final String? bookUid = _bookUid;
    final int? posMs = positionMs;
    if (bookUid == null || posMs == null) return;
    // 恢复 seek 未落地：dispose 瞬间的 position 仍是过渡期小值，勿覆盖真实进度。
    if (_isRestoringPast(posMs)) return;
    _lastSavedSec = posMs ~/ 1000;
    unawaited(onPositionWrite?.call(bookUid, posMs));
  }
}
