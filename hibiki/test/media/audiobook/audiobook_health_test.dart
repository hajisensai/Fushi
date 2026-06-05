import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

void main() {
  group('AudiobookHealth.fromRatePct', () {
    test('0% → failed', () {
      final h = AudiobookHealth.fromRatePct(ratePct: 0);
      expect(h.kind, HealthKind.failed);
      expect(h.ratePct, 0);
    });

    test('negative → failed with raw value preserved', () {
      final h = AudiobookHealth.fromRatePct(ratePct: -5);
      expect(h.kind, HealthKind.failed);
      expect(h.ratePct, -5);
    });

    test('79% → partial', () {
      final h = AudiobookHealth.fromRatePct(ratePct: 79);
      expect(h.kind, HealthKind.partial);
      expect(h.ratePct, 79);
    });

    test('80% → ok (threshold)', () {
      final h = AudiobookHealth.fromRatePct(ratePct: 80);
      expect(h.kind, HealthKind.ok);
      expect(h.ratePct, 80);
    });

    test('100% → ok', () {
      final h = AudiobookHealth.fromRatePct(ratePct: 100);
      expect(h.kind, HealthKind.ok);
      expect(h.ratePct, 100);
    });

    test('50% → partial', () {
      final h = AudiobookHealth.fromRatePct(ratePct: 50);
      expect(h.kind, HealthKind.partial);
    });

    test('preserves reason', () {
      final h = AudiobookHealth.fromRatePct(ratePct: 0, reason: 'no audio');
      expect(h.reason, 'no audio');
    });

    test('preserves measuredAt', () {
      final t = DateTime(2025, 1, 1);
      final h = AudiobookHealth.fromRatePct(ratePct: 90, measuredAt: t);
      expect(h.measuredAt, t);
    });
  });

  group('AudiobookHealth factory constructors', () {
    test('notApplicable has correct kind', () {
      final h = AudiobookHealth.notApplicable(reason: 'synthetic');
      expect(h.kind, HealthKind.notApplicable);
      expect(h.reason, 'synthetic');
      expect(h.ratePct, isNull);
    });

    test('failed has zero ratePct and reason', () {
      final h = AudiobookHealth.failed(reason: 'file not found');
      expect(h.kind, HealthKind.failed);
      expect(h.ratePct, 0);
      expect(h.reason, 'file not found');
    });

    test('unrun has epoch measuredAt', () {
      final h = AudiobookHealth.unrun();
      expect(h.kind, HealthKind.unrun);
      expect(h.measuredAt, DateTime.fromMillisecondsSinceEpoch(0));
      expect(h.ratePct, isNull);
    });
  });

  group('AudiobookHealth.okThreshold', () {
    test('threshold is 80', () {
      expect(AudiobookHealth.okThreshold, 80);
    });
  });

  group('AudiobookHealth.packInto / fromAudiobook round-trip', () {
    Audiobook makeAb() {
      return Audiobook()
        ..bookKey = 'test'
        ..alignmentFormat = 'srt'
        ..alignmentPath = '/a.srt';
    }

    test('ok round-trip preserves all fields', () {
      final original = AudiobookHealth.fromRatePct(
        ratePct: 95,
        reason: '100/105 cues matched (window=200)',
        measuredAt: DateTime(2026, 1, 1),
      );
      final ab = makeAb();
      original.packInto(ab);

      expect(ab.healthKindRaw, 'ok');
      expect(ab.matchRatePct, 95);
      expect(ab.healthReason, contains('window=200'));
      expect(ab.healthMeasuredAt, DateTime(2026, 1, 1));

      final restored = AudiobookHealth.fromAudiobook(ab);
      expect(restored.kind, HealthKind.ok);
      expect(restored.ratePct, 95);
      expect(restored.reason, original.reason);
      expect(restored.measuredAt, DateTime(2026, 1, 1));
    });

    test('failed round-trip preserves reason', () {
      final original = AudiobookHealth.failed(reason: 'file not found');
      final ab = makeAb();
      original.packInto(ab);

      final restored = AudiobookHealth.fromAudiobook(ab);
      expect(restored.kind, HealthKind.failed);
      expect(restored.ratePct, 0);
      expect(restored.reason, 'file not found');
    });

    test('null healthKindRaw returns unrun', () {
      final ab = makeAb();
      ab.healthKindRaw = null;

      final h = AudiobookHealth.fromAudiobook(ab);
      expect(h.kind, HealthKind.unrun);
    });

    test('unknown healthKindRaw falls back to unrun', () {
      final ab = makeAb();
      ab.healthKindRaw = 'nonexistent_kind';

      final h = AudiobookHealth.fromAudiobook(ab);
      expect(h.kind, HealthKind.unrun);
    });

    test('corrupted matchRatePct (>100) is clamped to null', () {
      final ab = makeAb();
      ab.healthKindRaw = 'ok';
      ab.matchRatePct = 33554526;
      ab.healthMeasuredAt = DateTime(2026, 1, 1);

      final h = AudiobookHealth.fromAudiobook(ab);
      expect(h.kind, HealthKind.ok);
      expect(h.ratePct, isNull);
    });

    test('negative matchRatePct is clamped to null', () {
      final ab = makeAb();
      ab.healthKindRaw = 'failed';
      ab.matchRatePct = -1;

      final h = AudiobookHealth.fromAudiobook(ab);
      expect(h.ratePct, isNull);
    });

    test('null healthMeasuredAt falls back to epoch', () {
      final ab = makeAb();
      ab.healthKindRaw = 'partial';
      ab.matchRatePct = 50;
      ab.healthMeasuredAt = null;

      final h = AudiobookHealth.fromAudiobook(ab);
      expect(h.measuredAt, DateTime.fromMillisecondsSinceEpoch(0));
    });

    test('notApplicable round-trip', () {
      final original = AudiobookHealth.notApplicable(reason: 'synthetic');
      final ab = makeAb();
      original.packInto(ab);

      final restored = AudiobookHealth.fromAudiobook(ab);
      expect(restored.kind, HealthKind.notApplicable);
      expect(restored.ratePct, isNull);
      expect(restored.reason, 'synthetic');
    });
  });
}
