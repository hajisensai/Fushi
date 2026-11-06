// 对拍：EpubSrtMatcher（算法主体在 native/fushi_compute）与旧 Dart 实现逐位一致。
//
// 夹具 fixtures/epub_srt_matcher_golden.json 是算法搬进 Rust 之前，旧 Dart 实现在
// 合成语料（support/synthetic_match_corpus.dart，160 个种子 × 3 组参数 + 三档窗口
// 探测）上的输出：每条 cue 的命中节 / 区间 / 分数（double 按最短往返十进制比字符串，
// 即逐位比较），以及锚点间隙回填后的结果。**不要用新实现重新生成它**——那样就不再
// 是对拍了。
//
// 原生库是硬依赖：找不到库（FUSHI_COMPUTE_LIB / 随包位置）时这里直接失败，不跳过。
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_audio/fushi_audio.dart';
import 'package:test/test.dart';

import 'support/golden_codec.dart';
import 'support/synthetic_match_corpus.dart';

void main() {
  final Map<String, dynamic> golden =
      jsonDecode(
            File(
              'test/matching/fixtures/epub_srt_matcher_golden.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final List<dynamic> cases = golden['cases'] as List<dynamic>;

  test('夹具覆盖全部合成种子', () {
    expect(cases.length, kSyntheticMatchCaseCount);
  });

  for (final dynamic raw in cases) {
    final Map<String, dynamic> c = raw as Map<String, dynamic>;
    final int seed = c['seed'] as int;
    test('合成用例 seed=$seed 与旧 Dart 实现逐位一致', () {
      final SyntheticMatchCase input = buildSyntheticMatchCase(seed);
      expect(
        input.inputHash,
        c['inputHash'],
        reason: '合成语料漂移：生成规则改了，夹具已不对应（只能用旧实现重新生成）',
      );
      for (final dynamic rc in c['configs'] as List<dynamic>) {
        final Map<String, dynamic> cfg = rc as Map<String, dynamic>;
        final MatchResult r = EpubSrtMatcher.match(
          sections: input.sections,
          cues: input.cues,
          searchWindow: cfg['window'] as int,
          similarityThreshold: (cfg['threshold'] as num).toDouble(),
          maxConsecutiveMisses: cfg['maxMisses'] as int,
        );
        expect(
          encodeMatchResultForGolden(r),
          cfg['match'],
          reason:
              'match window=${cfg['window']} th=${cfg['threshold']} '
              'misses=${cfg['maxMisses']}',
        );
        final MatchResult f = EpubCueMatcher.gapFiller.fill(
          sections: input.sections,
          cues: input.cues,
          result: r,
        );
        expect(encodeMatchResultForGolden(f), cfg['fill'], reason: 'fill');
      }
      final ProbeResult p = EpubSrtMatcher.probe(
        sections: input.sections,
        cues: input.cues,
        windows: const <int>[50, 200, 350],
      );
      final Map<String, dynamic> gp = c['probe'] as Map<String, dynamic>;
      expect(<String, String>{
        for (final MapEntry<int, double> e in p.perWindow.entries)
          '${e.key}': '${e.value}',
      }, gp['perWindow']);
      expect(
        p.bestResult == null ? null : encodeMatchResultForGolden(p.bestResult!),
        gp['best'],
      );
    });
  }
}
