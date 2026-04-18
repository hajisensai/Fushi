import 'package:hibiki/src/media/audiobook/audiobook_model.dart';
import 'package:hibiki/src/media/audiobook/epub_srt_matcher.dart';

export 'package:hibiki/src/media/audiobook/epub_srt_matcher.dart'
    show EpubSection, CueMatch, MatchResult;

/// 格式无关的 cue↔EPUB 模糊匹配器。
///
/// 上游 Sasayaki 只吃 SRT；hibiki 的 SRT/LRC/VTT/ASS 四个 parser 都归一化到
/// 同一份 [AudioCue] 列表，所以匹配逻辑与来源格式无关。现阶段实现直接复用
/// [EpubSrtMatcher]（同一算法，旧名沿用以避免测试面抖动）；新代码一律通过
/// [EpubCueMatcher] 入口调用，把 matcher 的"格式耦合"限制在文件名层面。
///
/// 输入：任意来源的 `List<AudioCue>` + 一份 EPUB 的 `List<EpubSection>`。
/// 输出：[MatchResult]，含 matchRate 与逐条命中偏移。
class EpubCueMatcher {
  const EpubCueMatcher._();

  /// 在后台 isolate 里跑匹配。匹配 0..几秒到十几秒，不放 isolate 会 ANR。
  static Future<MatchResult> matchInIsolate({
    required List<EpubSection> sections,
    required List<AudioCue> cues,
    int searchWindow = EpubSrtMatcher.defaultSearchWindow,
    double scoreThreshold = EpubSrtMatcher.defaultScoreThreshold,
    int rescueAfterMisses = EpubSrtMatcher.defaultRescueAfterMisses,
    double rescueThreshold = EpubSrtMatcher.defaultRescueThreshold,
  }) {
    return EpubSrtMatcher.matchInIsolate(
      sections: sections,
      cues: cues,
      searchWindow: searchWindow,
      scoreThreshold: scoreThreshold,
      rescueAfterMisses: rescueAfterMisses,
      rescueThreshold: rescueThreshold,
    );
  }

  /// 同步匹配，测试 / 小数据场景用。
  static MatchResult match({
    required List<EpubSection> sections,
    required List<AudioCue> cues,
    int searchWindow = EpubSrtMatcher.defaultSearchWindow,
    double scoreThreshold = EpubSrtMatcher.defaultScoreThreshold,
    int rescueAfterMisses = EpubSrtMatcher.defaultRescueAfterMisses,
    double rescueThreshold = EpubSrtMatcher.defaultRescueThreshold,
  }) {
    return EpubSrtMatcher.match(
      sections: sections,
      cues: cues,
      searchWindow: searchWindow,
      scoreThreshold: scoreThreshold,
      rescueAfterMisses: rescueAfterMisses,
      rescueThreshold: rescueThreshold,
    );
  }
}
