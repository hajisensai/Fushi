// 有声书 cue 按句界重切（`CueSentenceResegmenter.resegment`，导入收尾的真实入口）的端到端
// 耗时：160 个合成用例（test/matching/support/synthetic_match_corpus.dart，cue 补确定性 token
// 时间）先匹配好，计时只含 resegment 本身——token 归一化的打包 / FFI / 拆回、编辑距离对齐、
// 建串切句全在里面。每轮把 160 个用例各跑一遍，预热一轮后取 5 轮中位数。
//
// 用法（在 packages/fushi_audio 下；AOT 更接近 app）：
//   dart compile exe benchmark/resegment_benchmark.dart -o <out>.exe && <out>.exe
import 'dart:io';

import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_compute/fushi_compute.dart';

import '../test/matching/support/reseg_golden_support.dart';
import '../test/matching/support/synthetic_match_corpus.dart';

void main() {
  FushiCompute.require();
  final List<(List<EpubSection>, List<AudioCue>, MatchResult)> inputs =
      <(List<EpubSection>, List<AudioCue>, MatchResult)>[];
  int cueCount = 0;
  int tokenCount = 0;
  for (int seed = 0; seed < kSyntheticMatchCaseCount; seed++) {
    final SyntheticMatchCase c = buildSyntheticMatchCase(seed);
    final MatchResult matched = EpubSrtMatcher.match(
      sections: c.sections,
      cues: c.cues,
    );
    final List<AudioCue> cues = withSyntheticTokens(c.cues);
    cueCount += cues.length;
    for (final AudioCue cue in cues) {
      tokenCount += cue.tokenTiming?.length ?? 0;
    }
    inputs.add((c.sections, cues, matched));
  }
  int checksum = 0;
  void round() {
    for (final (List<EpubSection>, List<AudioCue>, MatchResult) input
        in inputs) {
      checksum += const CueSentenceResegmenter()
          .resegment(sections: input.$1, cues: input.$2, result: input.$3)
          .cues
          .length;
    }
  }

  round();
  final List<int> us = <int>[];
  for (int i = 0; i < 5; i++) {
    final Stopwatch sw = Stopwatch()..start();
    round();
    us.add(sw.elapsedMicroseconds);
  }
  us.sort();
  stdout.writeln(
    'resegment x${inputs.length} cases ($cueCount cues, $tokenCount tokens): '
    '${(us[2] / 1000).toStringAsFixed(2)} ms median '
    '(min ${(us.first / 1000).toStringAsFixed(2)}, '
    'max ${(us.last / 1000).toStringAsFixed(2)}) checksum=$checksum',
  );
}
