import 'package:fushi_audio/fushi_audio.dart';

/// 有声书查词「按音频坐标反查 cue」的预解码索引（查词卡顿 P2）。
///
/// 旧实现每次查词都调 `sentenceAudioCuesForSection`（对全书 cue 逐条
/// [SubtitleRematchCodec.tryDecode] 过滤本章），再对过滤结果**再** decode 一遍比较区间——
/// 一次查词两轮全书解码。本索引对同一份 cue 列表、同一章只解码一次，查询退化为对整数
/// 区间的顺序扫描。
///
/// 语义与旧 `_findCueForOffset` 逐位相同：只收 decode 成功且 `sectionIndex` 等于本章的 cue，
/// 保持原列表顺序，返回**第一条** `normCharStart <= offset < normCharEnd` 的 cue（区间若有
/// 重叠，仍是列表序靠前者胜出）。
///
/// 失效：按 [source] 列表**身份**与章号判定（[matches]）。播放器的 `chapterCuesSnapshot`
/// 只在 `load` / 重设 cue 时整表替换、从不原地增删；原地改写 `textFragmentId` 的只有
/// `SubtitleRematchCodec.applyToCues`，它作用在重匹配 / 导入时从库里新读出来的 cue 列表上，
/// 写库后播放器重新 `load` 才拿到新列表（新实例）。所以「同一个 List 实例 + 同一章」即
/// 「同一份解码结果」。
class AudioCueOffsetIndex {
  AudioCueOffsetIndex._(this.source, this.sectionIndex, this._entries);

  /// 从播放器当前 cue 列表（全书，播放顺序）建出 [sectionIndex] 章的索引。
  factory AudioCueOffsetIndex.build(List<AudioCue> source, int sectionIndex) {
    final List<_CueSpan> entries = <_CueSpan>[];
    for (final AudioCue cue in source) {
      final SubtitleRematchFragment? frag = SubtitleRematchCodec.tryDecode(
        cue.textFragmentId,
      );
      if (frag == null || frag.sectionIndex != sectionIndex) continue;
      entries.add(_CueSpan(frag.normCharStart, frag.normCharEnd, cue));
    }
    return AudioCueOffsetIndex._(source, sectionIndex, entries);
  }

  /// 建索引时的 cue 列表（按身份比较）。
  final List<AudioCue> source;

  /// 建索引时的章号。
  final int sectionIndex;

  final List<_CueSpan> _entries;

  /// 本索引是否仍对应 [cues] 与 [section]。
  bool matches(List<AudioCue> cues, int section) =>
      identical(source, cues) && sectionIndex == section;

  /// 音频坐标 [matchableOffset] 所在的 cue；无命中返回 null。
  AudioCue? cueAt(int matchableOffset) {
    for (final _CueSpan span in _entries) {
      if (span.start <= matchableOffset && span.end > matchableOffset) {
        return span.cue;
      }
    }
    return null;
  }
}

class _CueSpan {
  const _CueSpan(this.start, this.end, this.cue);

  final int start;
  final int end;
  final AudioCue cue;
}
