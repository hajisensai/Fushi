import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/swipe_dismiss_wrapper.dart';

/// TODO-1052: [BarrierSwipeDismissTracker] is the single source of truth for the
/// "horizontal drag over the full-screen dismiss barrier past a threshold closes
/// one popup layer" gesture shared by reader/audiobook (via base_source_page),
/// video, home_dictionary and texthooker. Before this, base_source_page carried
/// a private `_barrierDragX` + three methods and every surface would have
/// duplicated the accumulate/threshold logic + magic numbers. These unit tests
/// lock the pure contract:
///   - accumulates signed horizontal deltas across an update sequence;
///   - `end` returns true only when |accumulated| exceeds the sensitivity-derived
///     threshold ([swipeDismissThreshold]); false otherwise;
///   - bidirectional: leftward (negative) drag past threshold also passes;
///   - `end` always resets the accumulator (next gesture starts clean);
///   - `begin` resets a stale accumulator (cancelled/interleaved gestures).
void main() {
  group('BarrierSwipeDismissTracker', () {
    test('over-threshold rightward drag passes at default sensitivity 0.6', () {
      final BarrierSwipeDismissTracker t = BarrierSwipeDismissTracker();
      // default 0.6 threshold ~94px; accumulate 120px.
      t.begin();
      for (int i = 0; i < 12; i++) {
        t.update(10);
      }
      expect(t.end(sensitivity: 0.6), isTrue);
    });

    test('below-threshold drag does NOT pass', () {
      final BarrierSwipeDismissTracker t = BarrierSwipeDismissTracker();
      t.begin();
      t.update(40); // < ~94px threshold at 0.6
      expect(t.end(sensitivity: 0.6), isFalse);
    });

    test('leftward (negative) over-threshold drag also passes (bidirectional)',
        () {
      final BarrierSwipeDismissTracker t = BarrierSwipeDismissTracker();
      t.begin();
      for (int i = 0; i < 12; i++) {
        t.update(-10);
      }
      expect(t.end(sensitivity: 0.6), isTrue);
    });

    test('end resets the accumulator (next gesture starts clean)', () {
      final BarrierSwipeDismissTracker t = BarrierSwipeDismissTracker();
      t.begin();
      t.update(200); // clearly over threshold
      expect(t.end(sensitivity: 0.6), isTrue);
      // A fresh below-threshold gesture must not inherit the prior 200px.
      t.begin();
      t.update(20);
      expect(t.end(sensitivity: 0.6), isFalse);
    });

    test('begin resets a stale accumulator (no update since last begin)', () {
      final BarrierSwipeDismissTracker t = BarrierSwipeDismissTracker();
      t.begin();
      t.update(200);
      // Interrupted before end: a new gesture begins, discarding the 200px.
      t.begin();
      t.update(10);
      expect(t.end(sensitivity: 0.6), isFalse);
    });

    test('higher sensitivity lowers the threshold (same drag can flip)', () {
      final BarrierSwipeDismissTracker t = BarrierSwipeDismissTracker();
      // 50px: below the 0.6 threshold (~94) but above the 1.0 threshold (30).
      t.begin();
      t.update(50);
      expect(t.end(sensitivity: 0.6), isFalse);
      t.begin();
      t.update(50);
      expect(t.end(sensitivity: 1.0), isTrue);
    });

    test('threshold is exclusive: exactly-at-threshold does not pass', () {
      final BarrierSwipeDismissTracker t = BarrierSwipeDismissTracker();
      final double threshold = swipeDismissThreshold(0.6);
      t.begin();
      t.update(threshold);
      expect(t.end(sensitivity: 0.6), isFalse,
          reason: 'end uses strict > threshold, matching mobile _dragX.abs()');
    });
  });
}
