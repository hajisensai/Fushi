import 'package:hibiki/src/media/audiobook/audiobook_model.dart';
import 'package:hibiki/src/media/audiobook/epub_srt_matcher.dart';

export 'package:hibiki/src/media/audiobook/epub_srt_matcher.dart'
    show EpubSection, CueMatch, MatchResult, ProbeResult;

/// 格式无关的 cue↔EPUB 精确匹配器。
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
  }) {
    return EpubSrtMatcher.matchInIsolate(
      sections: sections,
      cues: cues,
      searchWindow: searchWindow,
    );
  }

  /// 同步匹配，测试 / 小数据场景用。
  static MatchResult match({
    required List<EpubSection> sections,
    required List<AudioCue> cues,
    int searchWindow = EpubSrtMatcher.defaultSearchWindow,
  }) {
    return EpubSrtMatcher.match(
      sections: sections,
      cues: cues,
      searchWindow: searchWindow,
    );
  }

  /// 自动匹配默认的 window 候选集：覆盖 slider 全范围（50..350 step 50），
  /// 7 档在 isolate 里一次跑完，对典型日语小说 < 5 秒。
  static const List<int> defaultProbeWindows = <int>[
    50, 100, 150, 200, 250, 300, 350,
  ];

  /// 在 isolate 里对多档 window 探测，返回命中率最高的那档。perWindow 为空
  /// 或全为 0 返回 null（调用方应保留原值）。
  static Future<ProbeResult> probeInIsolate({
    required List<EpubSection> sections,
    required List<AudioCue> cues,
    List<int> windows = defaultProbeWindows,
  }) {
    return EpubSrtMatcher.probeInIsolate(
      sections: sections,
      cues: cues,
      windows: windows,
    );
  }
}
