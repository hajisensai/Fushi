// CueEnergySnapper 搬到 Rust 之后的回归：冻结向量（packages/fushi_compute/test/fixtures/
// signal_vectors.json 的 `snap` 段）由删除前的纯 Dart 实现生成，这里走真实的
// CueEnergySnapper → ffc_signal_* 链路，逐条核对起止与**全部** token 偏移（Dart 侧写回）。
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_audio/fushi_audio.dart';
import 'package:test/test.dart';

import '../../../fushi_compute/test/signal/signal_vector_inputs.dart';

List<AudioCue> _cues(List<SnapCue> cues) => <AudioCue>[
  for (final SnapCue c in cues)
    AudioCue()
      ..bookKey = 'b'
      ..chapterHref = ''
      ..sentenceIndex = 0
      ..textFragmentId = ''
      ..text = 'x'
      ..startMs = c.startMs
      ..endMs = c.endMs
      ..audioFileIndex = c.audioFileIndex
      ..tokenTiming = c.offsetsMs == null
          ? null
          : CueTokenTiming(
              tokens: List<String>.filled(c.offsetsMs!.length, 'x'),
              offsetsMs: c.offsetsMs!,
            ),
];

List<Object?> _state(List<AudioCue> cues) => <Object?>[
  for (final AudioCue c in cues)
    <Object?>[c.startMs, c.endMs, c.tokenTiming?.offsetsMs],
];

CueEnergySnapper _snapper(SnapParams p) => CueEnergySnapper(
  frameMs: p.frameMs,
  maxGapMs: p.maxGapMs,
  windowMs: p.windowMs,
  minValleyMs: p.minValleyMs,
  distancePenalty: p.distancePenalty,
  tailMs: p.tailMs,
  leadMs: p.leadMs,
  minDurationMs: p.minDurationMs,
  floorMarginDb: p.floorMarginDb,
  minThresholdDb: p.minThresholdDb,
  maxThresholdDb: p.maxThresholdDb,
  tokenGuardMs: p.tokenGuardMs,
  edgeMaxShiftMs: p.edgeMaxShiftMs,
  edgeMinVoiceMs: p.edgeMinVoiceMs,
  edgeLeadMs: p.edgeLeadMs,
  edgeTailMs: p.edgeTailMs,
);

void main() {
  final Map<String, Object?> fixture =
      jsonDecode(
            File(
              '../fushi_compute/test/fixtures/signal_vectors.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  final Map<String, Map<String, Object?>> want = <String, Map<String, Object?>>{
    for (final Object? e in fixture['snap']! as List<Object?>)
      (e! as Map<String, Object?>)['id']! as String: e as Map<String, Object?>,
  };

  for (final SnapCase c in snapCases()) {
    test('冻结向量：${c.id}', () {
      final Map<String, Object?> w = want[c.id]!;
      final CueEnergySnapper s = _snapper(c.params);

      final List<AudioCue> both = _cues(c.cues);
      expect(s.snap(both, c.energy), w['snapMoved']);
      expect(s.refineEdges(both, c.energy), w['thenRefineEdges']);
      expect(_state(both), w['snapThenRefine']);

      final List<AudioCue> snapOnly = _cues(c.cues);
      expect(s.snap(snapOnly, c.energy), w['snapOnlyMoved']);
      expect(_state(snapOnly), w['snapOnly']);

      final List<AudioCue> refineOnly = _cues(c.cues);
      expect(s.refineEdges(refineOnly, c.energy), w['refineOnlyEdges']);
      expect(_state(refineOnly), w['refineOnly']);
    });
  }
}
