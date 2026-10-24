import 'dart:typed_data';

import 'package:fushi_asr_subtitles/asr_subtitles.dart'
    show
        AsrCuePostLibrary,
        AsrCuePostProcessor,
        AsrCuePostResult,
        AsrCuePostStage,
        AsrPostCue,
        AsrPostCueGroup;
import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:fushi_compute/fushi_compute.dart';

/// [postProcessTranscribedCues] 的结果。
typedef TranscribedCuePostResult = ({
  List<AudioCue> cues,
  MatchResult result,
  int? snappedBoundaries,
  int? refinedEdges,
  int mergedFragments,
  int? displayMarginEdges,
});

/// 本 isolate 里包装好的上游库：算法在上游 `fushi_asr_cue_post`（已编进 fushi_compute 原生库，
/// 见 `native/fushi_compute/Cargo.toml`），这里只把 fushi_compute 已加载的库交给它。每个 isolate
/// 各自加载（后台收尾 isolate 里也走这里）。
final AsrCuePostLibrary _cuePostLibrary = AsrCuePostLibrary.fromDynamicLibrary(
  FushiCompute.require().library,
  libraryPath: FushiCompute.require().libraryPath,
);

/// 设备端转录产物（已换正文）的落库前后处理：能量吸附 → 修边 → 句内碎片合并 → 跟读显示余量，
/// 算法在上游（hajisensai/fushi-subtitles `AsrCuePostProcessor`，整本书一次 FFI），这里只做
/// [AudioCue] / [CueMatch] 与上游类型之间的换算。
///
/// - [energy] 为 null（旧任务没写包络）时只跑合并，三个计时统计为 null；
/// - `result.matches` 与 [cues] 不一一对应时不合并（匹配信息对不上号）；
/// - 没有并掉任何一条时返回**同一个**列表与匹配结果，cue 就地改起止与 token 偏移；
///   有合并时返回新列表：没并的 cue 仍是原对象（就地改），并成的一条是新对象（书 / 章 / 句号 /
///   片段 id 取首条，文本与 token 首尾相接），匹配区间取首条起点、末条终点、分数取最低。
///
/// 原生库不可用抛 `FushiComputeUnavailableError` / `AsrCuePostUnavailableError`（硬依赖）。
TranscribedCuePostResult postProcessTranscribedCues({
  required List<AudioCue> cues,
  required MatchResult result,
  required Int8List? energy,
}) {
  final List<CueMatch> matches = result.matches;
  final bool canMerge = matches.length == cues.length;
  final Set<AsrCuePostStage> stages = <AsrCuePostStage>{
    if (energy != null) ...<AsrCuePostStage>{
      AsrCuePostStage.snap,
      AsrCuePostStage.refineEdges,
      AsrCuePostStage.displayMargins,
    },
    if (canMerge) AsrCuePostStage.mergeFragments,
  };
  final List<AsrPostCue> input = <AsrPostCue>[
    for (int i = 0; i < cues.length; i++)
      _toPostCue(cues[i], canMerge ? matches[i] : CueMatch.unmatched),
  ];
  final AsrCuePostResult post = AsrCuePostProcessor(
    library: _cuePostLibrary,
  ).process(input, energy ?? Int8List(0), stages: stages);

  final List<AudioCue> outCues = <AudioCue>[];
  final List<CueMatch> outMatches = <CueMatch>[];
  for (final AsrPostCueGroup g in post.groups) {
    if (!g.isMerged) {
      final AudioCue cue = cues[g.firstIndex];
      _writeBack(cue, g);
      outCues.add(cue);
      if (canMerge) outMatches.add(matches[g.firstIndex]);
      continue;
    }
    outCues.add(_joined(cues, g));
    outMatches.add(_joinedMatch(matches, g));
  }
  final bool merged = post.mergedFragments > 0;
  return (
    cues: merged ? outCues : cues,
    result: merged
        ? MatchResult(
            matches: outMatches,
            totalCues: outCues.length,
            matchedCues: outMatches.where((CueMatch m) => m.matched).length,
            gapFill: result.gapFill,
          )
        : result,
    snappedBoundaries: energy == null ? null : post.snappedBoundaries,
    refinedEdges: energy == null ? null : post.refinedEdges,
    mergedFragments: post.mergedFragments,
    displayMarginEdges: energy == null ? null : post.displayMarginEdges,
  );
}

AsrPostCue _toPostCue(AudioCue cue, CueMatch match) => AsrPostCue(
  startMs: cue.startMs,
  endMs: cue.endMs,
  audioFileIndex: cue.audioFileIndex,
  text: cue.text,
  tokenOffsetsMs: cue.tokenTiming?.offsetsMs,
  sectionIndex: match.sectionIndex,
  normCharStart: match.normCharStart,
  normCharEnd: match.normCharEnd,
);

/// 没并的 cue：就地写回起止；token 偏移有变才换一份（绝对发射时刻不变）。
void _writeBack(AudioCue cue, AsrPostCueGroup g) {
  cue.startMs = g.startMs;
  cue.endMs = g.endMs;
  final CueTokenTiming? t = cue.tokenTiming;
  final List<int>? offsets = g.tokenOffsetsMs;
  if (t == null || offsets == null || _sameInts(t.offsetsMs, offsets)) return;
  cue.tokenTiming = CueTokenTiming(tokens: t.tokens, offsetsMs: offsets);
}

AudioCue _joined(List<AudioCue> cues, AsrPostCueGroup g) {
  final AudioCue first = cues[g.firstIndex];
  final List<int>? offsets = g.tokenOffsetsMs;
  return AudioCue()
    ..bookKey = first.bookKey
    ..chapterHref = first.chapterHref
    ..sentenceIndex = first.sentenceIndex
    ..textFragmentId = first.textFragmentId
    ..text = g.text
    ..startMs = g.startMs
    ..endMs = g.endMs
    ..audioFileIndex = first.audioFileIndex
    ..tokenTiming = offsets == null
        ? null
        : CueTokenTiming(
            tokens: List<String>.unmodifiable(<String>[
              for (int i = g.firstIndex; i <= g.lastIndex; i++)
                ...cues[i].tokenTiming!.tokens,
            ]),
            offsetsMs: offsets,
          );
}

CueMatch _joinedMatch(List<CueMatch> matches, AsrPostCueGroup g) {
  final CueMatch first = matches[g.firstIndex];
  double score = first.score;
  for (int i = g.firstIndex + 1; i <= g.lastIndex; i++) {
    if (matches[i].score < score) score = matches[i].score;
  }
  return CueMatch(
    cueSentenceIndex: first.cueSentenceIndex,
    sectionIndex: first.sectionIndex,
    normCharStart: first.normCharStart,
    normCharEnd: matches[g.lastIndex].normCharEnd,
    score: score,
  );
}

bool _sameInts(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
