import 'package:hibiki/src/media/audiobook/audiobook_model.dart';
import 'package:hibiki/src/media/audiobook/epub_srt_matcher.dart';

export 'package:hibiki/src/media/audiobook/epub_srt_matcher.dart'
    show EpubSection, CueMatch, MatchResult, ProbeResult;

/// 格式无关的 cue↔EPUB 模糊匹配器。
///
/// 上游 Sasayaki 只吃 SRT；hibiki 的 SRT/LRC/VTT/ASS 四个 parser 都归一化到
/// 同一份 [AudioCue] 列表，所以匹配逻辑与来源格式无关。底层复用
/// [EpubSrtMatcher]（Dice 系数模糊匹配，移植自 ttu-whispersync）。
class EpubCueMatcher {
  const EpubCueMatcher._();

  /// 在后台 isolate 里跑匹配。匹配 0..几秒到十几秒，不放 isolate 会 ANR。
  static Future<MatchResult> matchInIsolate({
    required List<EpubSection> sections,
    required List<AudioCue> cues,
    int searchWindow = EpubSrtMatcher.defaultSearchWindow,
    double similarityThreshold = EpubSrtMatcher.defaultSimilarityThreshold,
    int maxConsecutiveMisses = EpubSrtMatcher.defaultMaxConsecutiveMisses,
  }) {
    return EpubSrtMatcher.matchInIsolate(
      sections: sections,
      cues: cues,
      searchWindow: searchWindow,
      similarityThreshold: similarityThreshold,
      maxConsecutiveMisses: maxConsecutiveMisses,
    );
  }

  /// 同步匹配，测试 / 小数据场景用。
  static MatchResult match({
    required List<EpubSection> sections,
    required List<AudioCue> cues,
    int searchWindow = EpubSrtMatcher.defaultSearchWindow,
    double similarityThreshold = EpubSrtMatcher.defaultSimilarityThreshold,
    int maxConsecutiveMisses = EpubSrtMatcher.defaultMaxConsecutiveMisses,
  }) {
    return EpubSrtMatcher.match(
      sections: sections,
      cues: cues,
      searchWindow: searchWindow,
      similarityThreshold: similarityThreshold,
      maxConsecutiveMisses: maxConsecutiveMisses,
    );
  }

  /// 自动匹配默认的 window 候选集：3 档快速定位最优区间。
  static const List<int> defaultProbeWindows = <int>[50, 200, 350];

  /// 在 isolate 里对多档 window 探测，返回命中率最高的那档。perWindow 为空
  /// 或全为 0 返回 null（调用方应保留原值）。
  static Future<ProbeResult> probeInIsolate({
    required List<EpubSection> sections,
    required List<AudioCue> cues,
    List<int> windows = defaultProbeWindows,
    double similarityThreshold = EpubSrtMatcher.defaultSimilarityThreshold,
    int maxConsecutiveMisses = EpubSrtMatcher.defaultMaxConsecutiveMisses,
  }) {
    return EpubSrtMatcher.probeInIsolate(
      sections: sections,
      cues: cues,
      windows: windows,
      similarityThreshold: similarityThreshold,
      maxConsecutiveMisses: maxConsecutiveMisses,
    );
  }
}
