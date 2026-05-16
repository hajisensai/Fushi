import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/audiobook_health.dart';

void main() {
  group('AudiobookHealth.fromRatePct', () {
    test('0% → failed', () {
      final h = AudiobookHealth.fromRatePct(ratePct: 0);
      expect(h.kind, HealthKind.failed);
      expect(h.ratePct, 0);
    });

    test('negative → failed', () {
      final h = AudiobookHealth.fromRatePct(ratePct: -5);
      expect(h.kind, HealthKind.failed);
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
}
