import '../audiobook/audiobook_model.dart';
import 'anchor_gap_filler.dart';
import 'epub_srt_matcher.dart';

export 'epub_srt_matcher.dart'
    show EpubSection, CueMatch, MatchResult, ProbeResult;

/// 格式无关的 cue↔EPUB 模糊匹配器。
///
/// 上游 Sasayaki 只吃 SRT；hibiki 的 SRT/LRC/VTT/ASS 四个 parser 都归一化到
/// 同一份 [AudioCue] 列表，所以匹配逻辑与来源格式无关。底层复用
/// [EpubSrtMatcher]（Dice 系数模糊匹配，移植自 ttu-whispersync）。
class EpubCueMatcher {
  const EpubCueMatcher._();

  /// 第一遍 Dice 匹配之后的锚点间隙回填（见 [AnchorGapFiller]）。三个匹配入口
  /// 统一在这里过一遍，调用方拿到的 [MatchResult] 已含回填。
  static const AnchorGapFiller gapFiller = AnchorGapFiller();

  /// 在后台 isolate 里跑匹配。匹配 0..几秒到十几秒，不放 isolate 会 ANR。
  /// 回填只扫锚点间隙（合计几十到几百字），留在调用 isolate 里做。
  static Future<MatchResult> matchInIsolate({
    required List<EpubSection> sections,
    required List<AudioCue> cues,
    int searchWindow = EpubSrtMatcher.defaultSearchWindow,
    double similarityThreshold = EpubSrtMatcher.defaultSimilarityThreshold,
    int maxConsecutiveMisses = EpubSrtMatcher.defaultMaxConsecutiveMisses,
  }) async {
    final MatchResult core = await EpubSrtMatcher.matchInIsolate(
      sections: sections,
      cues: cues,
      searchWindow: searchWindow,
      similarityThreshold: similarityThreshold,
      maxConsecutiveMisses: maxConsecutiveMisses,
    );
    return gapFiller.fill(sections: sections, cues: cues, result: core);
  }

  /// 同步匹配，测试 / 小数据场景用。
  static MatchResult match({
    required List<EpubSection> sections,
    required List<AudioCue> cues,
    int searchWindow = EpubSrtMatcher.defaultSearchWindow,
    double similarityThreshold = EpubSrtMatcher.defaultSimilarityThreshold,
    int maxConsecutiveMisses = EpubSrtMatcher.defaultMaxConsecutiveMisses,
  }) {
    final MatchResult core = EpubSrtMatcher.match(
      sections: sections,
      cues: cues,
      searchWindow: searchWindow,
      similarityThreshold: similarityThreshold,
      maxConsecutiveMisses: maxConsecutiveMisses,
    );
    return gapFiller.fill(sections: sections, cues: cues, result: core);
  }

  /// 自动匹配默认的 window 候选集：3 档快速定位最优区间。
  static const List<int> defaultProbeWindows = <int>[50, 200, 350];

  /// 在 isolate 里对多档 window 探测，返回命中率最高的那档。perWindow 为空
  /// 或全为 0 返回 null（调用方应保留原值）。
  ///
  /// 各档命中率按第一遍（未回填）比较——回填只填锚点间隙，各档之间的差异
  /// 本来就体现在锚点上；返回的 [ProbeResult.bestResult] 已含回填。
  static Future<ProbeResult> probeInIsolate({
    required List<EpubSection> sections,
    required List<AudioCue> cues,
    List<int> windows = defaultProbeWindows,
    double similarityThreshold = EpubSrtMatcher.defaultSimilarityThreshold,
    int maxConsecutiveMisses = EpubSrtMatcher.defaultMaxConsecutiveMisses,
  }) async {
    final ProbeResult probe = await EpubSrtMatcher.probeInIsolate(
      sections: sections,
      cues: cues,
      windows: windows,
      similarityThreshold: similarityThreshold,
      maxConsecutiveMisses: maxConsecutiveMisses,
    );
    final MatchResult? best = probe.bestResult;
    if (best == null) return probe;
    return ProbeResult(
      perWindow: probe.perWindow,
      bestResult: gapFiller.fill(sections: sections, cues: cues, result: best),
    );
  }
}
