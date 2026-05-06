import 'package:hibiki/src/media/audiobook/audio_text_normalizer.dart';
import 'package:hibiki/src/media/audiobook/audiobook_model.dart';
import 'package:hibiki/src/media/audiobook/sasayaki_match_codec.dart';

/// 播放区间：audioFileIndex + 时间范围。
class AudioPlaybackRange {
  const AudioPlaybackRange({
    required this.audioFileIndex,
    required this.startMs,
    required this.endMs,
  });

  final int audioFileIndex;
  final int startMs;
  final int endMs;
}

/// 从一组 [AudioCue] 中根据位置或文本定位播放区间。
///
/// 优先级：位置匹配（sasayaki:// 编码的 normChar 偏移）> 文本匹配（归一化子串）。
class CollectionAudioMatcher {
  CollectionAudioMatcher._();

  /// 查找与给定位置/文本最匹配的播放区间。
  ///
  /// - 位置匹配：[sectionIndex] + [normCharOffset]（+ 可选 [normCharLength]）
  /// - 文本兜底：[text]（当位置匹配无结果或参数缺失时使用）
  static AudioPlaybackRange? findPlaybackRange({
    required List<AudioCue> cues,
    int? sectionIndex,
    int? normCharOffset,
    int? normCharLength,
    String? text,
  }) {
    if (cues.isEmpty) return null;

    // 1) 位置匹配（优先）
    if (sectionIndex != null) {
      final int offset = normCharOffset ?? 0;
      final int length = normCharLength ?? 0;
      final int rangeEnd = length > 0 ? offset + length : 0;

      final List<AudioCue> hits = [];
      AudioCue? nearest;
      int bestDist = 1 << 30;

      for (final AudioCue cue in cues) {
        final SasayakiFragment? frag =
            SasayakiMatchCodec.tryDecode(cue.textFragmentId);
        if (frag == null || frag.sectionIndex != sectionIndex) continue;

        if (rangeEnd > 0) {
          // 有 normCharLength：区间重叠判断
          if (offset < frag.normCharEnd && rangeEnd > frag.normCharStart) {
            hits.add(cue);
          }
        } else {
          // 无 normCharLength（老数据）：单点命中
          if (frag.normCharStart <= offset && frag.normCharEnd > offset) {
            return AudioPlaybackRange(
              audioFileIndex: cue.audioFileIndex,
              startMs: cue.startMs,
              endMs: cue.endMs,
            );
          }
          final int dist = (frag.normCharStart - offset).abs();
          if (dist < bestDist) {
            bestDist = dist;
            nearest = cue;
          }
        }
      }

      if (hits.isNotEmpty) {
        return _mergeFirstContiguousSegment(hits);
      }

      if (nearest != null) {
        return AudioPlaybackRange(
          audioFileIndex: nearest.audioFileIndex,
          startMs: nearest.startMs,
          endMs: nearest.endMs,
        );
      }
    }

    // 2) 文本匹配（兜底）
    final String queryText = text ?? '';
    if (queryText.isEmpty) return null;

    // 2a) 精确文本匹配
    for (final AudioCue cue in cues) {
      if (cue.text == queryText) {
        return AudioPlaybackRange(
          audioFileIndex: cue.audioFileIndex,
          startMs: cue.startMs,
          endMs: cue.endMs,
        );
      }
    }

    // 2b) 归一化后相邻 cue 拼接子串匹配
    return _normalizedAdjacentMatch(cues, queryText);
  }

  /// 合并命中 cue 中第一个连续 audioFileIndex 段的时间范围。
  static AudioPlaybackRange _mergeFirstContiguousSegment(List<AudioCue> hits) {
    final int firstFileIdx = hits.first.audioFileIndex;
    int minMs = hits.first.startMs;
    int maxMs = hits.first.endMs;

    for (final AudioCue cue in hits) {
      if (cue.audioFileIndex != firstFileIdx) break;
      if (cue.startMs < minMs) minMs = cue.startMs;
      if (cue.endMs > maxMs) maxMs = cue.endMs;
    }

    return AudioPlaybackRange(
      audioFileIndex: firstFileIdx,
      startMs: minMs,
      endMs: maxMs,
    );
  }

  /// 归一化所有 cue.text 拼接后，在其中搜索 queryText 的归一化形式。
  static AudioPlaybackRange? _normalizedAdjacentMatch(
    List<AudioCue> cues,
    String queryText,
  ) {
    final String normQuery = AudioTextNormalizer.normalize(queryText);
    if (normQuery.isEmpty) return null;

    final List<String> normTexts = [];
    final List<int> cueStarts = [];
    final StringBuffer buf = StringBuffer();

    for (final AudioCue cue in cues) {
      cueStarts.add(buf.length);
      final String nt = AudioTextNormalizer.normalize(cue.text);
      normTexts.add(nt);
      buf.write(nt);
    }

    final String concat = buf.toString();
    final int found = concat.indexOf(normQuery);
    if (found < 0) return null;

    final int foundEnd = found + normQuery.length;

    int startIdx = cues.length - 1;
    int endIdx = 0;

    for (int i = 0; i < cues.length; i++) {
      final int cueStart = cueStarts[i];
      final int cueEnd = cueStart + normTexts[i].length;
      if (cueStart < foundEnd && cueEnd > found) {
        if (i < startIdx) startIdx = i;
        if (i > endIdx) endIdx = i;
      }
    }

    if (startIdx > endIdx) return null;

    final int fileIdx = cues[startIdx].audioFileIndex;
    int minMs = cues[startIdx].startMs;
    int maxMs = cues[startIdx].endMs;

    for (int i = startIdx + 1; i <= endIdx; i++) {
      if (cues[i].audioFileIndex != fileIdx) break;
      if (cues[i].startMs < minMs) minMs = cues[i].startMs;
      if (cues[i].endMs > maxMs) maxMs = cues[i].endMs;
    }

    return AudioPlaybackRange(
      audioFileIndex: fileIdx,
      startMs: minMs,
      endMs: maxMs,
    );
  }
}
