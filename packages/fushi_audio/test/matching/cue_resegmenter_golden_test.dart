// CueSentenceResegmenter 整条链路对拍：位置对齐（编辑距离 DP）搬进
// native/fushi_compute（`ffc_text_align_positions`，整本一次调用）之后，重切结果必须与
// 搬之前逐位一致。夹具 fixtures/cue_resegmenter_golden.json 由旧 Dart `_alignPositions`
// 在 160 个合成用例（support/synthetic_match_corpus.dart，cue 用
// support/reseg_golden_support.dart 补确定性 token 时间）× 两档 maxAlignCells（默认
// 400000 / 40，后者让大部分模糊命中走按比例退化分支）上生成，记规范化输出的 SHA-256。
// BUG-3530 改了匹配器（重切的输入）：种子 96/112/142 的匹配结果随之变化，这三个种子的
// 期望值按新匹配结果重算，重切算法本身未动。
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_compute/fushi_compute.dart';
import 'package:test/test.dart';

import 'support/reseg_golden_support.dart';
import 'support/synthetic_match_corpus.dart';

void main() {
  final Map<String, Object?> fixture =
      jsonDecode(
            File(
              'test/matching/fixtures/cue_resegmenter_golden.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  final List<Map<String, Object?>> cases = <Map<String, Object?>>[
    for (final Object? e in fixture['cases']! as List<Object?>)
      e! as Map<String, Object?>,
  ];

  test('夹具覆盖全部合成用例 × 两档 maxAlignCells', () {
    expect(cases.length, kSyntheticMatchCaseCount * 2);
  });

  for (final Map<String, Object?> w in cases) {
    final int seed = w['seed']! as int;
    final int cells = w['maxAlignCells']! as int;
    test('合成用例 #$seed maxAlignCells=$cells 与旧 Dart 实现逐位一致', () {
      final SyntheticMatchCase c = buildSyntheticMatchCase(seed);
      expect(c.inputHash, w['inputHash'], reason: '语料漂移，夹具需用旧实现重生成');
      final MatchResult matched = EpubSrtMatcher.match(
        sections: c.sections,
        cues: c.cues,
      );
      final CueResegmentResult r = CueSentenceResegmenter(maxAlignCells: cells)
          .resegment(
            sections: c.sections,
            cues: withSyntheticTokens(c.cues),
            result: matched,
          );
      expect(r.cues.length, w['cuesOut']);
      expect(r.stats.toString(), w['stats']);
      expect(ffcSha256Bytes(utf8.encode(describeResegment(r))), w['sha256']);
    });
  }
}
