import 'package:flutter/foundation.dart';

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

  /// 在后台 isolate 里跑「第一遍匹配 + 锚点间隙回填」。匹配 0..几秒到十几秒，
  /// 回填在 region 超大时曾达几十秒（上游审查 A1），两者都不能放在 UI isolate。
  /// 生产入口一律走这里或 [probeInIsolate]。
  static Future<MatchResult> matchInIsolate({
    required List<EpubSection> sections,
    required List<AudioCue> cues,
    int searchWindow = EpubSrtMatcher.defaultSearchWindow,
    double similarityThreshold = EpubSrtMatcher.defaultSimilarityThreshold,
    int maxConsecutiveMisses = EpubSrtMatcher.defaultMaxConsecutiveMisses,
  }) {
    final _MatchAndFillRequest req = _MatchAndFillRequest(
      sections: sections,
      cueTexts: <String>[for (final AudioCue c in cues) c.text],
      cueIndexes: <int>[for (final AudioCue c in cues) c.sentenceIndex],
      windows: <int>[searchWindow],
      similarityThreshold: similarityThreshold,
      maxConsecutiveMisses: maxConsecutiveMisses,
      gapFiller: gapFiller,
    );
    return compute(_matchAndFillEntrypoint, req);
  }

  /// 同步匹配 + 回填，**只给测试 / 小数据场景**：第一遍匹配对全书是 O(cue 数 ×
  /// 窗口)，回填对每串是 O(region × cue 长)，真实有声书（几千条 cue、十几万字）
  /// 在 UI isolate 上跑会卡住主线程；生产代码用 [matchInIsolate]。
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
  /// 本来就体现在锚点上；返回的 [ProbeResult.bestResult] 已含回填（回填也在
  /// 同一个 isolate 里做）。
  static Future<ProbeResult> probeInIsolate({
    required List<EpubSection> sections,
    required List<AudioCue> cues,
    List<int> windows = defaultProbeWindows,
    double similarityThreshold = EpubSrtMatcher.defaultSimilarityThreshold,
    int maxConsecutiveMisses = EpubSrtMatcher.defaultMaxConsecutiveMisses,
  }) {
    final _MatchAndFillRequest req = _MatchAndFillRequest(
      sections: sections,
      cueTexts: <String>[for (final AudioCue c in cues) c.text],
      cueIndexes: <int>[for (final AudioCue c in cues) c.sentenceIndex],
      windows: windows,
      similarityThreshold: similarityThreshold,
      maxConsecutiveMisses: maxConsecutiveMisses,
      gapFiller: gapFiller,
    );
    return compute(_probeAndFillEntrypoint, req);
  }
}

/// [EpubCueMatcher.matchInIsolate] / [EpubCueMatcher.probeInIsolate] 发给
/// 后台 isolate 的请求。cue 只带文本与序号（匹配只用这两样），[AnchorGapFiller]
/// 是纯数值的 const 对象，都能跨 isolate 传。
class _MatchAndFillRequest {
  const _MatchAndFillRequest({
    required this.sections,
    required this.cueTexts,
    required this.cueIndexes,
    required this.windows,
    required this.similarityThreshold,
    required this.maxConsecutiveMisses,
    required this.gapFiller,
  });

  final List<EpubSection> sections;
  final List<String> cueTexts;
  final List<int> cueIndexes;
  final List<int> windows;
  final double similarityThreshold;
  final int maxConsecutiveMisses;
  final AnchorGapFiller gapFiller;

  List<AudioCue> rebuildCues() => <AudioCue>[
        for (int i = 0; i < cueTexts.length; i++)
          (AudioCue()
            ..bookKey = ''
            ..chapterHref = ''
            ..sentenceIndex = cueIndexes[i]
            ..textFragmentId = ''
            ..text = cueTexts[i]
            ..startMs = 0
            ..endMs = 0
            ..audioFileIndex = 0),
      ];
}

MatchResult _matchAndFillEntrypoint(_MatchAndFillRequest req) {
  final List<AudioCue> cues = req.rebuildCues();
  final MatchResult core = EpubSrtMatcher.match(
    sections: req.sections,
    cues: cues,
    searchWindow: req.windows.single,
    similarityThreshold: req.similarityThreshold,
    maxConsecutiveMisses: req.maxConsecutiveMisses,
  );
  return req.gapFiller.fill(sections: req.sections, cues: cues, result: core);
}

ProbeResult _probeAndFillEntrypoint(_MatchAndFillRequest req) {
  final List<AudioCue> cues = req.rebuildCues();
  final ProbeResult probe = EpubSrtMatcher.probe(
    sections: req.sections,
    cues: cues,
    windows: req.windows,
    similarityThreshold: req.similarityThreshold,
    maxConsecutiveMisses: req.maxConsecutiveMisses,
  );
  final MatchResult? best = probe.bestResult;
  if (best == null) return probe;
  return ProbeResult(
    perWindow: probe.perWindow,
    bestResult: req.gapFiller.fill(
      sections: req.sections,
      cues: cues,
      result: best,
    ),
  );
}
