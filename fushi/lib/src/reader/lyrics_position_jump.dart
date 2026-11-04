import 'package:fushi_audio/fushi_audio.dart';

/// 把 cue 的 `fushi-cue://` 片段（**音频 matchable 坐标**）换算成章内**学习单位**
/// 区间；换算不出返回 null。阅读器侧的实现是 `_studyRangeForAudioFragment`
/// （开书恢复 / 目录锚点 / `cueStudyOffset` 同一条换算）。
typedef CueStudyRangeOf =
    ({int offset, int length})? Function(SubtitleRematchFragment fragment);

/// 歌词模式「进度跳转」：在 [cues] 里找离章内**学习单位**偏移 [studyOffset] 最近的
/// 句子 cue——覆盖它的那句；落在两句之间（标题 / 插图等没对齐的字）取其后第一句，
/// 章尾之后取最后一句。只认 `fushi-cue://` 家族（[SubtitleRematchCodec]），且只认
/// `sectionIndex == section` 的 cue；没有可比的 cue 返回 null。
///
/// [studyOffset] 来自阅读进度字数（学习单位），而片段里的 `normCharStart/End` 是音频
/// matchable 坐标：两者在章内有标点 / 空白 / ruby / 插图时逐渐偏离，越往章尾错得越多。
/// 所以每句先经 [studyRangeOf] 换成学习区间再比；换算不出的 cue 退回 matchable 区间
/// （与 `AudiobookPlayerController.sectionCueFrom(offsetOf:)` 同一口径）。
AudioCue? audioCueNearStudyOffset(
  Iterable<AudioCue> cues, {
  required int section,
  required int studyOffset,
  required CueStudyRangeOf studyRangeOf,
}) {
  AudioCue? after;
  int afterStart = 0;
  AudioCue? before;
  int beforeEnd = 0;
  for (final AudioCue cue in cues) {
    final SubtitleRematchFragment? frag = SubtitleRematchCodec.tryDecode(
      cue.textFragmentId,
    );
    if (frag == null || frag.sectionIndex != section) continue;
    final ({int offset, int length})? study = studyRangeOf(frag);
    final int start = study?.offset ?? frag.normCharStart;
    final int end = study == null
        ? frag.normCharEnd
        : study.offset + study.length;
    if (start <= studyOffset && end > studyOffset) return cue;
    if (start > studyOffset && (after == null || start < afterStart)) {
      after = cue;
      afterStart = start;
    }
    if (end <= studyOffset && (before == null || end > beforeEnd)) {
      before = cue;
      beforeEnd = end;
    }
  }
  return after ?? before;
}
