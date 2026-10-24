// 有声书转录 cue 后处理迁到上游 fushi-subtitles 之后的回归：冻结向量
// （fixtures/asr_cue_post_vectors.json）由迁移前本仓的实现（hajisensai/fushi#2491 head
// 202a13554a：CueEnergySnapper.snap → refineEdges → CueFragmentMerger.merge →
// CueDisplayMargins.apply）在 AudioCue / MatchResult 上算出。这里走现在的
// postProcessTranscribedCues（上游 AsrCuePostProcessor，fcp_* 编在 fushi_compute 里），
// 逐条核对起止、文本、token 偏移与个数、匹配区间与四个计数。
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_asr_subtitles/asr_subtitles.dart'
    show AsrCuePostLibrary, kAsrCuePostSymbols;
import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:fushi_compute/fushi_compute.dart';
import 'package:fushi_engine/media/audiobook/asr_cue_post_host.dart';
import 'package:test/test.dart';

import 'asr_cue_post_vector_inputs.dart';

List<AudioCue> _cues(PostCase c) => <AudioCue>[
  for (final PostCue p in c.cues)
    AudioCue()
      ..bookKey = 'b'
      ..chapterHref = ''
      ..sentenceIndex = 0
      ..textFragmentId = ''
      ..text = p.text
      ..startMs = p.startMs
      ..endMs = p.endMs
      ..audioFileIndex = p.audioFileIndex
      ..tokenTiming = p.offsetsMs == null
          ? null
          : CueTokenTiming(
              tokens: List<String>.filled(p.offsetsMs!.length, 't'),
              offsetsMs: p.offsetsMs!,
            ),
];

MatchResult _result(PostCase c) {
  final List<CueMatch> ms = <CueMatch>[
    for (final PostCue p in c.cues)
      p.sectionIndex < 0
          ? CueMatch.unmatched
          : CueMatch(
              cueSentenceIndex: 0,
              sectionIndex: p.sectionIndex,
              normCharStart: p.normCharStart,
              normCharEnd: p.normCharEnd,
              score: 1,
            ),
  ];
  return MatchResult(
    matches: ms,
    totalCues: ms.length,
    matchedCues: ms.where((CueMatch m) => m.matched).length,
  );
}

void main() {
  final Map<String, Object?> fixture =
      jsonDecode(
            File(
              'test/media/audiobook/fixtures/asr_cue_post_vectors.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  final Map<String, Map<String, Object?>> want = <String, Map<String, Object?>>{
    for (final Object? e in fixture['cases']! as List<Object?>)
      (e! as Map<String, Object?>)['id']! as String: e as Map<String, Object?>,
  };

  test('fushi_compute 导出上游 crate 的全部 fcp_* 符号，清单与上游绑定一致', () {
    expect(kFushiComputeLinkedCuePostSymbols, kAsrCuePostSymbols);
    final FushiCompute compute = FushiCompute.require();
    for (final String symbol in kAsrCuePostSymbols) {
      expect(compute.providesSymbol(symbol), isTrue, reason: symbol);
    }
    expect(AsrCuePostLibrary.bindError(compute.library), isNull);
  });

  for (final PostCase c in postCases()) {
    test('迁移前实现的冻结向量：${c.id}', () {
      final Map<String, Object?> w = want[c.id]!;
      final TranscribedCuePostResult r = postProcessTranscribedCues(
        cues: _cues(c),
        result: _result(c),
        energy: c.energy,
      );
      expect(r.snappedBoundaries, w['snapped']);
      expect(r.refinedEdges, w['refined']);
      expect(r.mergedFragments, w['merged']);
      expect(r.displayMarginEdges, w['margins']);
      expect(r.result.totalCues, r.cues.length);
      expect(<Object?>[
        for (int i = 0; i < r.cues.length; i++)
          <Object?>[
            r.cues[i].startMs,
            r.cues[i].endMs,
            r.cues[i].text,
            r.cues[i].tokenTiming?.offsetsMs,
            r.cues[i].tokenTiming?.tokens.length,
            r.result.matches[i].sectionIndex,
            r.result.matches[i].normCharStart,
            r.result.matches[i].normCharEnd,
          ],
      ], w['cues']);
    });
  }

  test('没有包络：只合并，计时统计为 null；没有可并的就原样返回同一个列表', () {
    final PostCase c = postCases().first;
    final List<AudioCue> cues = _cues(c);
    final TranscribedCuePostResult merged = postProcessTranscribedCues(
      cues: cues,
      result: _result(c),
      energy: null,
    );
    expect(merged.snappedBoundaries, isNull);
    expect(merged.displayMarginEdges, isNull);
    expect(merged.mergedFragments, 1);

    final List<AudioCue> single = <AudioCue>[cues.last];
    final MatchResult one = MatchResult(
      matches: <CueMatch>[CueMatch.unmatched],
      totalCues: 1,
      matchedCues: 0,
    );
    final TranscribedCuePostResult same = postProcessTranscribedCues(
      cues: single,
      result: one,
      energy: Int8List(0),
    );
    expect(identical(same.cues, single), isTrue);
    expect(identical(same.result, one), isTrue);
  });

  test('匹配条数与 cue 对不上：不合并', () {
    final PostCase c = postCases().first;
    final TranscribedCuePostResult r = postProcessTranscribedCues(
      cues: _cues(c),
      result: const MatchResult(
        matches: <CueMatch>[],
        totalCues: 0,
        matchedCues: 0,
      ),
      energy: null,
    );
    expect(r.mergedFragments, 0);
    expect(r.cues, hasLength(c.cues.length));
  });
}
