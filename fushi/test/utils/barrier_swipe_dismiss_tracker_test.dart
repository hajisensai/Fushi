import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/lookup_dismiss_barrier.dart';
import 'package:fushi/src/utils/misc/swipe_dismiss_wrapper.dart';

/// TODO-1052: [BarrierSwipeDismissTracker] is the single source of truth for the
/// "horizontal drag over the full-screen dismiss barrier past a threshold closes
/// one popup layer" gesture shared by reader/audiobook (via base_source_page),
/// video, home_dictionary and texthooker.
///
/// BUG-1757 moved it next to [LookupDismissBarrier] and gave it the AXIS
/// DECISION that used to be delegated to the gesture arena, so the rule is
/// written in testable code instead of being implied by accept/reject timing.
/// (It is NOT what made content under the barrier unscrollable — the barrier
/// fill is opaque to hit-testing by design; see lookup_dismiss_barrier_test.dart.)
///
/// These unit tests lock the pure contract:
///   - accumulates signed horizontal deltas across an update sequence;
///   - `end` returns true only when |accumulated| exceeds the sensitivity-derived
///     threshold ([swipeDismissThreshold]); false otherwise;
///   - bidirectional: leftward (negative) drag past threshold also passes;
///   - `end` always resets (next gesture starts clean);
///   - `begin` resets a stale accumulator (cancelled/interleaved gestures);
///   - AXIS (BUG-1757): vertical / vertically-dominant drags never pass and are
///     abandoned permanently, even if the trajectory later swings horizontal.
void main() {
  group('BarrierSwipeDismissTracker', () {
    test('over-threshold rightward drag passes at default sensitivity 0.6', () {
      final BarrierSwipeDismissTracker t = BarrierSwipeDismissTracker();
      // default 0.6 threshold ~94px; accumulate 120px.
      t.begin(sensitivity: 0.6);
      for (int i = 0; i < 12; i++) {
        t.update(const Offset(10, 0));
      }
      expect(t.end(), isTrue);
    });

    test('below-threshold drag does NOT pass', () {
      final BarrierSwipeDismissTracker t = BarrierSwipeDismissTracker();
      t.begin(sensitivity: 0.6);
      t.update(const Offset(40, 0)); // < ~94px threshold at 0.6
      expect(t.end(), isFalse);
    });

    test('leftward (negative) over-threshold drag also passes (bidirectional)',
        () {
      final BarrierSwipeDismissTracker t = BarrierSwipeDismissTracker();
      t.begin(sensitivity: 0.6);
      for (int i = 0; i < 12; i++) {
        t.update(const Offset(-10, 0));
      }
      expect(t.end(), isTrue);
    });

    test('end resets the accumulator (next gesture starts clean)', () {
      final BarrierSwipeDismissTracker t = BarrierSwipeDismissTracker();
      t.begin(sensitivity: 0.6);
      t.update(const Offset(200, 0)); // clearly over threshold
      expect(t.end(), isTrue);
      // A fresh below-threshold gesture must not inherit the prior 200px.
      t.begin(sensitivity: 0.6);
      t.update(const Offset(20, 0));
      expect(t.end(), isFalse);
    });

    test('begin resets a stale accumulator (no end since last begin)', () {
      final BarrierSwipeDismissTracker t = BarrierSwipeDismissTracker();
      t.begin(sensitivity: 0.6);
      t.update(const Offset(200, 0));
      // Interrupted before end: a new gesture begins, discarding the 200px.
      t.begin(sensitivity: 0.6);
      t.update(const Offset(10, 0));
      expect(t.end(), isFalse);
    });

    test('higher sensitivity lowers the threshold (same drag can flip)', () {
      final BarrierSwipeDismissTracker t = BarrierSwipeDismissTracker();
      // 50px: below the 0.6 threshold (~94) but above the 1.0 threshold (30).
      t.begin(sensitivity: 0.6);
      t.update(const Offset(50, 0));
      expect(t.end(), isFalse);
      t.begin(sensitivity: 1.0);
      t.update(const Offset(50, 0));
      expect(t.end(), isTrue);
    });

    test('threshold is exclusive: exactly-at-threshold does not pass', () {
      final BarrierSwipeDismissTracker t = BarrierSwipeDismissTracker();
      final double threshold = swipeDismissThreshold(0.6);
      t.begin(sensitivity: 0.6);
      t.update(Offset(threshold, 0));
      expect(t.end(), isFalse,
          reason: 'end uses strict > threshold, matching mobile _dragX.abs()');
    });

    // ── BUG-1757: axis decision ───────────────────────────────────────────

    test('purely vertical drag never passes and is never marked horizontal',
        () {
      final BarrierSwipeDismissTracker t = BarrierSwipeDismissTracker();
      t.begin(sensitivity: 0.6);
      for (int i = 0; i < 20; i++) {
        t.update(const Offset(0, 20)); // 400px of scrolling
      }
      expect(t.debugIsHorizontal, isFalse);
      expect(t.end(), isFalse);
    });

    test('vertically-dominant diagonal drag is treated as scrolling, not swipe',
        () {
      final BarrierSwipeDismissTracker t = BarrierSwipeDismissTracker();
      t.begin(sensitivity: 0.6);
      // Real thumb scrolls drift sideways; 1:4 is nowhere near the 2.5x
      // horizontal dominance required, and the accumulated |dx| (150px) would
      // otherwise sail past the ~94px threshold and close a layer by accident.
      for (int i = 0; i < 30; i++) {
        t.update(const Offset(5, 20));
      }
      expect(t.debugIsHorizontal, isFalse);
      expect(t.end(), isFalse);
    });

    test('once decided vertical, a later horizontal swing cannot re-claim it',
        () {
      final BarrierSwipeDismissTracker t = BarrierSwipeDismissTracker();
      t.begin(sensitivity: 0.6);
      t.update(const Offset(0, 40)); // decides: vertical
      expect(t.debugIsHorizontal, isFalse);
      // The finger now yanks sideways well past the threshold. The layer must
      // NOT close: this gesture already belongs to the content underneath.
      for (int i = 0; i < 20; i++) {
        t.update(const Offset(20, 0));
      }
      expect(t.debugIsHorizontal, isFalse);
      expect(t.end(), isFalse);
    });

    test('horizontally-dominant diagonal drag still passes', () {
      final BarrierSwipeDismissTracker t = BarrierSwipeDismissTracker();
      t.begin(sensitivity: 0.6);
      // 4:1 horizontal dominance clears the 2.5x bar; |dx| = 160 > ~94.
      for (int i = 0; i < 20; i++) {
        t.update(const Offset(8, 2));
      }
      expect(t.debugIsHorizontal, isTrue);
      expect(t.end(), isTrue);
    });

    test('abort gives up the gesture permanently (multi-touch / cancel)', () {
      final BarrierSwipeDismissTracker t = BarrierSwipeDismissTracker();
      t.begin(sensitivity: 0.6);
      t.update(const Offset(60, 0));
      t.abort();
      t.update(const Offset(200, 0)); // ignored: not tracking
      expect(t.end(), isFalse);
    });

    test('update before begin is inert (no implicit tracking)', () {
      final BarrierSwipeDismissTracker t = BarrierSwipeDismissTracker();
      t.update(const Offset(200, 0));
      expect(t.end(), isFalse);
    });
  });
}
