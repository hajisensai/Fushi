import 'package:fushi/src/media/audiobook/mining_audio_clip.dart'
    show applyMiningAudioEdgeAdjust;
import 'package:fushi_anki/fushi_anki_core.dart' show MiningRequestOverrides;
import 'package:fushi_audio/fushi_audio.dart' show AudioPlaybackRange;
import 'package:fushi_engine/mining/immersion_mining_request.dart'
    show VideoMiningImageMode;

/// 视频车道「高级制卡」的纯逻辑：覆盖项怎么落到这张卡的区间 / 图片方式上。
///
/// 抽成独立库而不是留在 `video_fushi_page.dart` 的 part 里：写卡（`_onMineEntryImpl`）
/// 与对话框里的试听 / 区间描述必须调**同一个**函数（BUG-2196 ② 的教训：两处各算一遍
/// 迟早漂开），而纯函数放在这里才能不起页面就单测。

/// 一张视频卡的区间 + 文本（`_resolveVideoMiningRange` 的产物）。时刻都在播放器轴。
typedef VideoMiningRange = ({
  int clipStartMs,
  int clipEndMs,
  int stillFrameAtMs,
  String sentence,
  String? cueSentence,
});

/// 把本次覆盖项叠到宿主算好的区间上：
/// * 起止偏移加在**最终**音频 / 动图窗上（首尾留白与 A/V 偏移之后），见
///   [applyMiningAudioEdgeAdjust]。没有窗（无 cue 的 `0..0` 哨兵）不动——那是下游
///   「不抽媒体」的信号，加了偏移就会凭空变出一段区间。
/// * `coverFrameAtMs`（用户逐帧挪过的封面帧）替换静帧时刻。
///
/// [overrides] 为 null（普通一键制卡）时原样返回。
VideoMiningRange applyVideoMiningOverrides(
  VideoMiningRange range,
  MiningRequestOverrides? overrides,
) {
  if (overrides == null) return range;
  int clipStartMs = range.clipStartMs;
  int clipEndMs = range.clipEndMs;
  if (overrides.hasAudioDelta && clipEndMs > clipStartMs) {
    final AudioPlaybackRange adjusted = applyMiningAudioEdgeAdjust(
      AudioPlaybackRange(
        audioFileIndex: 0,
        startMs: clipStartMs,
        endMs: clipEndMs,
      ),
      startDeltaMs: overrides.audioStartDeltaMs,
      endDeltaMs: overrides.audioEndDeltaMs,
    );
    clipStartMs = adjusted.startMs;
    clipEndMs = adjusted.endMs;
  }
  return (
    clipStartMs: clipStartMs,
    clipEndMs: clipEndMs,
    stillFrameAtMs: overrides.coverFrameAtMs ?? range.stillFrameAtMs,
    sentence: range.sentence,
    cueSentence: range.cueSentence,
  );
}

/// 覆盖项里的图片方式（wire 字符串）严格解析：认不出返回 null（= 用设置）。
///
/// 不用 [VideoMiningImageMode.fromWireName]：它把未知值当成默认的视频片段，那是偏好
/// 层的语义；一份坏掉的覆盖项不该悄悄把用户的设置换成片段。
VideoMiningImageMode? parseVideoMiningImageModeOverride(String? wireName) {
  if (wireName == null) return null;
  for (final VideoMiningImageMode mode in VideoMiningImageMode.values) {
    if (mode.wireName == wireName) return mode;
  }
  return null;
}

/// 这张卡实际交给引擎的图片方式。
///
/// * 覆盖项给了就用它，否则用设置 [preferred]。
/// * 打了码（`mosaic` 非空）：动图 / 片段改成「字幕开头」静帧——打码只对静图所见即所得。
/// * 「查词时画面」且用户逐帧挪过封面帧（`coverFrameAtMs`）：挪过的帧不是当前解码帧，
///   改成按时刻抽帧（引擎的 [VideoMiningImageMode.subtitleStart] 就是「在静帧时刻抽
///   一帧」，时刻已由 [applyVideoMiningOverrides] 换成用户挪到的那一刻）。
/// * [forceSubtitleStart]（手机遥控制卡：电脑的「当前画面」不是手机用户看到的那一刻）
///   与原逻辑一致，同样换成按时刻抽。
///
/// 模板不支持视频片段时的降级不在这里——引擎按目标笔记类型判（落卡前才知道写进哪种
/// 模板），这里只决定用户要什么。
VideoMiningImageMode resolveVideoMiningImageMode({
  required VideoMiningImageMode preferred,
  MiningRequestOverrides? overrides,
  bool forceSubtitleStart = false,
}) {
  final VideoMiningImageMode requested =
      parseVideoMiningImageModeOverride(overrides?.videoImageMode) ?? preferred;
  // 打了码只能出静图（引擎同一判据兜底）：动图 / 片段改按时刻抽「字幕开头」那一帧。
  final VideoMiningImageMode mode =
      (overrides?.hasMosaic ?? false) && !requested.isStill
      ? VideoMiningImageMode.subtitleStart
      : requested;
  if (mode != VideoMiningImageMode.currentFrame) return mode;
  if (forceSubtitleStart || overrides?.coverFrameAtMs != null) {
    return VideoMiningImageMode.subtitleStart;
  }
  return mode;
}

/// 对话框里这个来源可选的图片方式（「不要」由对话框另给）。
///
/// * 没有时间窗（无字幕 cue）：动图 / 字幕开头 / 片段都无从谈起，只剩查词时画面。
/// * 片段要「可裁的源 + 时间窗」；模板确定不渲染片段（[templateRendersClip] == false）
///   时也去掉。null = 判定不了（Anki 没开等），保留——引擎落卡前会再按目标模板判一次。
List<VideoMiningImageMode> advancedMiningVideoImageModes({
  required bool hasClipWindow,
  required bool hasMediaSource,
  required bool? templateRendersClip,
}) {
  if (!hasClipWindow) {
    return const <VideoMiningImageMode>[VideoMiningImageMode.currentFrame];
  }
  final bool clipAvailable = hasMediaSource && templateRendersClip != false;
  return <VideoMiningImageMode>[
    VideoMiningImageMode.gif,
    if (clipAvailable) VideoMiningImageMode.videoClip,
    VideoMiningImageMode.currentFrame,
    VideoMiningImageMode.subtitleStart,
  ];
}

/// 对话框的默认图片方式：设置值在可选项里就用它；不在（片段不可用 / 没有时间窗）时
/// 换成引擎在同样情况下实际会出的那种，让「恢复默认」显示的就是一键「+」的结果。
VideoMiningImageMode advancedMiningDefaultVideoImageMode(
  VideoMiningImageMode preferred,
  List<VideoMiningImageMode> modes,
) {
  if (modes.contains(preferred)) return preferred;
  if (preferred.isVideoClip && modes.contains(VideoMiningImageMode.gif)) {
    return VideoMiningImageMode.gif;
  }
  return modes.first;
}

/// 逐帧挪动的步长（毫秒）。[fps] 取自 mpv `container-fps`；读不到 / 不合理时按 24fps。
int videoFrameStepMsForFps(double? fps) {
  final double effective = fps == null || !fps.isFinite || fps < 1 || fps > 480
      ? 24
      : fps;
  final int step = (1000 / effective).round();
  return step < 1 ? 1 : step;
}

/// 对话框打开时落的在线流缓冲副本（播放器轴 [`coveredStartMs`, `coveredEndMs`]）能不能
/// 直接交给这次制卡：写卡要抽的整段（静帧时刻与音频 / 动图窗的并集）都在里面才行。
/// 用户在对话框里加了句子、窗口超出副本时返回 false，制卡照旧在确认那一刻另落副本。
bool advancedMiningSnapshotCovers({
  required int coveredStartMs,
  required int coveredEndMs,
  required int clipStartMs,
  required int clipEndMs,
  required int stillFrameAtMs,
}) {
  final int needStart = stillFrameAtMs < clipStartMs
      ? stillFrameAtMs
      : clipStartMs;
  return clipEndMs > clipStartMs &&
      coveredStartMs <= needStart &&
      coveredEndMs >= clipEndMs;
}
