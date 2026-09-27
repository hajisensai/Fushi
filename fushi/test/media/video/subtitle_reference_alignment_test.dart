import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/subtitle/embedded_reference_subtitle_sync.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_reference_alignment.dart';

/// 一集 24 分钟里的「开口时刻」：间隔 1.5–6 秒。
List<double> _speech(int seed, {double duration = 1440}) {
  final math.Random r = math.Random(seed);
  final List<double> out = <double>[];
  double t = 20 + r.nextDouble() * 10;
  while (t < duration - 10) {
    out.add(t);
    t += 1.5 + r.nextDouble() * 4.5;
  }
  return out;
}

/// 从同一份开口时刻派生一条字幕轨：抖动、按 [keep] 概率保留、另加 [extra] 比例的独有行，
/// 再用 [shift] 把「真时间」变成这条轨自己的时间。
List<double> _track(
  List<double> speech, {
  required int seed,
  double keep = 0.8,
  double extra = 0.2,
  double jitter = 0.12,
  double Function(double t)? shift,
}) {
  final math.Random r = math.Random(seed);
  final double Function(double) f = shift ?? (double t) => t;
  final List<double> out = <double>[
    for (final double t in speech)
      if (r.nextDouble() < keep) f(t + (r.nextDouble() * 2 - 1) * jitter),
  ];
  final int extras = (speech.length * extra).round();
  for (int i = 0; i < extras; i++) {
    out.add(f(speech.first + r.nextDouble() * (speech.last - speech.first)));
  }
  return uniqueCueStarts(out.where((double t) => t >= 0));
}

SubtitleReferenceTrack _ref(String label, List<double> starts) =>
    SubtitleReferenceTrack(label: label, starts: starts);

void main() {
  final List<double> truth = _speech(1);
  final List<double> english = _track(truth, seed: 11);

  group('fitSubtitleToReference', () {
    test('单一偏移：目标整体晚 3.2 秒 → 偏移 -3.2 并接受', () {
      final List<double> ja = _track(
        truth,
        seed: 21,
        shift: (double t) => t + 3.2,
      );
      final SubtitleReferenceFit fit = fitSubtitleToReference(
        english,
        ja,
        durationSeconds: 1440,
      );
      expect(fit.segments, hasLength(1));
      expect(fit.segments.single.offsetSeconds, closeTo(-3.2, 0.1));
      final SubtitleReferenceJudgement j = judgeSubtitleReferenceFit(
        fit,
        ref: english,
        sub: ja,
      );
      expect(j.strength, AlignmentStrength.accepted);
      expect(fit.excess, greaterThan(kSingleReferenceAutoExcess));
    });

    test('CM 断点：前半段 -2 秒、600 秒后 +8 秒 → 两段', () {
      final List<double> ja = _track(
        truth,
        seed: 22,
        shift: (double t) => t < 600 ? t - 2 : t + 8,
      );
      final SubtitleReferenceFit fit = fitSubtitleToReference(
        english,
        ja,
        durationSeconds: 1440,
      );
      expect(fit.segments, hasLength(2));
      expect(fit.segments[0].offsetSeconds, closeTo(2, 0.1));
      expect(fit.segments[1].offsetSeconds, closeTo(-8, 0.1));
      expect(fit.segments[0].splitSeconds, closeTo(600, 12));
      expect(
        judgeSubtitleReferenceFit(fit, ref: english, sub: ja).strength,
        AlignmentStrength.accepted,
      );
    });

    test('错集：另一集的字幕被拒绝', () {
      final List<double> otherEpisode = _track(_speech(2), seed: 23);
      final SubtitleReferenceFit fit = fitSubtitleToReference(
        english,
        otherEpisode,
        durationSeconds: 1440,
      );
      expect(
        judgeSubtitleReferenceFit(
          fit,
          ref: english,
          sub: otherEpisode,
        ).strength,
        AlignmentStrength.refused,
      );
    });

    test('帧率漂移（25 vs 23.976）不修，拒绝', () {
      final List<double> ja = _track(
        truth,
        seed: 24,
        shift: (double t) => t * 25 / 23.976,
      );
      final SubtitleReferenceFit fit = fitSubtitleToReference(
        english,
        ja,
        durationSeconds: 1440,
      );
      expect(
        judgeSubtitleReferenceFit(fit, ref: english, sub: ja).strength,
        AlignmentStrength.refused,
      );
    });

    test('参考只覆盖前 8 分钟 → 拒绝（其余时段从没被检查过）', () {
      final List<double> partial = english
          .where((double t) => t < 480)
          .toList();
      final List<double> ja = _track(
        truth,
        seed: 25,
        shift: (double t) => t + 1,
      );
      final SubtitleReferenceFit fit = fitSubtitleToReference(
        partial,
        ja,
        durationSeconds: 1440,
      );
      final SubtitleReferenceJudgement j = judgeSubtitleReferenceFit(
        fit,
        ref: partial,
        sub: ja,
      );
      expect(j.strength, AlignmentStrength.refused);
      expect(j.issue, AlignmentIssue.partialReferenceCoverage);
    });

    test('cue 太少：不可测，而不是高分', () {
      final SubtitleReferenceFit fit = fitSubtitleToReference(english, <double>[
        100,
        200,
      ], durationSeconds: 1440);
      expect(fit.excess, 0);
      expect(
        judgeSubtitleReferenceFit(
          fit,
          ref: english,
          sub: <double>[100, 200],
        ).issue,
        AlignmentIssue.tooFewCues,
      );
    });
  });

  group('alignment mapping', () {
    const List<AlignmentSegment> segments = <AlignmentSegment>[
      AlignmentSegment(splitSeconds: 100, offsetSeconds: 10),
      AlignmentSegment(splitSeconds: null, offsetSeconds: 0),
    ];

    test('断点按目标时间换算：split - offset', () {
      expect(alignmentOffsetAt(segments, 89.9), 10);
      expect(alignmentOffsetAt(segments, 90.0), 0);
    });

    test('负跳变区间里的 cue 无家可归', () {
      expect(alignmentRemovedSpans(segments).single, (lo: 90.0, hi: 100.0));
      expect(alignmentIsRemoved(segments, 95), isTrue);
      expect(alignmentIsRemoved(segments, 100), isFalse);
    });
  });

  group('decideSubtitleSync（多参考投票）', () {
    test('两条独立参考（断句不同）一致 → 自动写入，agreeing=2', () {
      final List<double> chinese = _track(
        truth,
        seed: 12,
        keep: 0.75,
        extra: 0.25,
      );
      final List<double> ja = _track(
        truth,
        seed: 26,
        shift: (double t) => t - 4.5,
      );
      final SubtitleSyncDecision d = decideSubtitleSync(
        subtitleStarts: ja,
        references: <SubtitleReferenceTrack>[
          _ref('eng', english),
          _ref('chi', chinese),
        ],
        durationSeconds: 1440,
      );
      expect(d.groups, hasLength(2));
      expect(d.kind, SubtitleSyncDecisionKind.autoApply);
      expect(d.agreeingGroups, 2);
      expect(d.segments.single.offsetSeconds, closeTo(4.5, 0.1));
    });

    test('同一时间模板的多语言轨合并成一票', () {
      final List<double> sameTemplate = english
          .map((double t) => t + 0.01)
          .toList();
      final List<List<SubtitleReferenceTrack>> groups = groupReferenceTracks(
        <SubtitleReferenceTrack>[
          _ref('eng', english),
          _ref('spa', sameTemplate),
        ],
      );
      expect(groups, hasLength(1));
      expect(groups.single, hasLength(2));
    });

    test('只有一组参考但证据很强 → 自动写入', () {
      final List<double> ja = _track(
        truth,
        seed: 27,
        shift: (double t) => t + 1.7,
      );
      final SubtitleSyncDecision d = decideSubtitleSync(
        subtitleStarts: ja,
        references: <SubtitleReferenceTrack>[_ref('eng', english)],
        durationSeconds: 1440,
      );
      expect(d.kind, SubtitleSyncDecisionKind.autoApply);
      expect(d.agreeingGroups, 1);
    });

    test('错集：所有参考都拒绝 → 原样', () {
      final SubtitleSyncDecision d = decideSubtitleSync(
        subtitleStarts: _track(_speech(3), seed: 28),
        references: <SubtitleReferenceTrack>[
          _ref('eng', english),
          _ref('chi', _track(truth, seed: 13)),
        ],
        durationSeconds: 1440,
      );
      expect(d.kind, SubtitleSyncDecisionKind.refused);
      expect(d.chosen, isNull);
    });

    test('cue 少于 30 条的轨（forced / 特效字）不当参考', () {
      final List<List<SubtitleReferenceTrack>> groups = groupReferenceTracks(
        <SubtitleReferenceTrack>[_ref('signs', english.take(20).toList())],
      );
      expect(groups, isEmpty);
    });
  });

  group('syncSubtitleBytesToReferences', () {
    test('外挂字幕解析不出时间 → subtitleUnreadable，原样', () {
      final Uint8List bytes = Uint8List.fromList('not a subtitle'.codeUnits);
      final EmbeddedReferenceSyncResult r = syncSubtitleBytesToReferences(
        subtitleBytes: bytes,
        references: <SubtitleReferenceTrack>[_ref('eng', english)],
      );
      expect(r.status, EmbeddedReferenceSyncStatus.subtitleUnreadable);
      expect(r.bytesForAutomaticPath, same(bytes));
    });

    test('没有可用参考 → noReference，原样', () {
      final StringBuffer srt = StringBuffer();
      for (int i = 0; i < 40; i++) {
        srt.write(
          '${i + 1}\n00:00:${(i + 10).toString().padLeft(2, '0')},000 --> '
          '00:00:${(i + 10).toString().padLeft(2, '0')},500\nline\n\n',
        );
      }
      final Uint8List bytes = Uint8List.fromList(srt.toString().codeUnits);
      final EmbeddedReferenceSyncResult r = syncSubtitleBytesToReferences(
        subtitleBytes: bytes,
        references: const <SubtitleReferenceTrack>[],
      );
      expect(r.status, EmbeddedReferenceSyncStatus.noReference);
      expect(r.bytesForAutomaticPath, same(bytes));
    });
  });
}
