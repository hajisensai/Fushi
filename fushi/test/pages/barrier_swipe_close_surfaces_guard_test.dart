import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'video_fushi_page_source_corpus.dart';

/// TODO-1052 (parent TODO-716 phase 2): the "horizontal swipe over the dismiss
/// barrier closes one popup layer" gesture — first shipped on reader/audiobook
/// via base_source_page — is extended to the surfaces that own their OWN dismiss
/// barrier (they do NOT extend BaseSourcePage): video, home_dictionary and
/// texthooker.
///
/// BUG-1757 changed HOW that gesture is wired: each surface used to hand-roll
/// `GestureDetector(onTap* + onHorizontalDrag*)` over a transparent fill AND
/// carry its own [BarrierSwipeDismissTracker] plus three forwarding methods —
/// one gesture semantic copy-pasted four ways, with axis decision left entirely
/// to the gesture arena. Barrier construction is now the single primitive
/// [LookupDismissBarrier], which observes the drag through a raw [Listener]
/// (never enters the arena) and decides the axis in testable code.
///
/// NOTE — do not "fix" this into a scroll-through: the transparent fill is
/// opaque to hit-testing BY DESIGN (tapping the barrier is meant to close the
/// popup, not to reach the content). Measured in lookup_dismiss_barrier_test.dart:
/// a bare gesture-less ColoredBox already withholds every pointer event from a
/// PlatformViewSurface underneath. The recognizers were never what blocked it.
///
/// This guard asserts:
///   - each surface builds its barrier with [LookupDismissBarrier] (nobody
///     hand-rolls a GestureDetector barrier again);
///   - none of them hangs a PREFERENCE-GATED horizontal drag recognizer, which
///     is the exact shape of the old barrier wiring (a plain onHorizontalDrag
///     elsewhere is fine — video's subtitle-sidebar resize handle uses one);
///   - swipe stays gated on `ReaderFushiSource.instance.enableSwipeToClose`
///     (switch OFF => tap-only, old desktop behaviour, never-break);
///   - the live `dismissSwipeSensitivity` is fed in (single threshold source,
///     no magic-number drift);
///   - an over-threshold drag closes ONE layer (layer-by-layer, like cursor
///     B/Esc), NOT the whole stack (tap on true blank still clears the stack).
///
/// The barrier-widget dismiss BEHAVIOUR (drag distance -> stack shrinks by one,
/// vertical drag -> nothing) is exercised end-to-end in
/// base_source_page_barrier_swipe_close_test.dart, the primitive's own gesture
/// contract in lookup_dismiss_barrier_test.dart, and the tracker's pure
/// axis/threshold math in utils/barrier_swipe_dismiss_tracker_test.dart.
String _read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

/// `dart format` decides where to wrap arguments, so every assertion below runs
/// against whitespace-collapsed source. Without this, adding one character to a
/// line silently flips a guard from "checking" to "vacuously matching nothing".
String _flat(String src) => src.replaceAll(RegExp(r'\s+'), ' ');

/// The exact regressed shape: a horizontal drag recognizer **gated on the
/// swipe-to-close preference**, i.e. the dismiss barrier's. Deliberately not a
/// blanket ban on `onHorizontalDrag` — video legitimately uses one for the
/// 8px subtitle-sidebar resize handle, which covers no platform view.
final RegExp _barrierArenaDrag = RegExp(
    r'onHorizontalDrag\w*: ReaderFushiSource\.instance\.enableSwipeToClose');

/// A CONSTRUCTOR call to the primitive, with a left word boundary.
///
/// Mutation-tested: a bare `contains('LookupDismissBarrier(')` is satisfied by
/// the substring inside `shouldShowLookupDismissBarrier(` — which every one of
/// these surfaces calls right above its barrier. Replacing the real
/// `LookupDismissBarrier(` with a hand-rolled `GestureDetector(` then left the
/// guard GREEN. The boundary is what makes this guard able to fail at all.
final RegExp _primitiveCtor =
    RegExp(r'(?<![A-Za-z0-9_])LookupDismissBarrier\(');

const String _homeDictionary =
    'lib/src/pages/implementations/home_dictionary_page.dart';

const String _texthooker = 'lib/src/pages/implementations/texthooker_page.dart';

const String _baseSourcePage = 'lib/src/pages/base_source_page.dart';

/// Assert a source builds its barrier with the shared primitive, gates it on the
/// preference, feeds the live sensitivity, and no longer registers any
/// horizontal drag recognizer.
void _assertBarrierSwipeWiring(String label, String rawSrc) {
  final String src = _flat(rawSrc);
  // See [_primitiveCtor]: needs the word boundary, or
  // `shouldShowLookupDismissBarrier(` satisfies it vacuously.
  expect(_primitiveCtor.hasMatch(src), isTrue,
      reason: '$label must build its dismiss barrier with the shared '
          'LookupDismissBarrier primitive (BUG-1757)');
  // literal: 'onSwipeDismiss:'
  expect(src.contains('onSwipeDismiss:'), isTrue,
      reason: '$label must wire the barrier swipe-to-close callback');
  // literal: 'swipeEnabled: ReaderFushiSource.instance.enableSwipeToClose'
  expect(
    src.contains('swipeEnabled: ReaderFushiSource.instance.enableSwipeToClose'),
    isTrue,
    reason: '$label must gate barrier swipe on enableSwipeToClose (switch OFF '
        '=> tap-only, never-break)',
  );
  // literal: 'ReaderFushiSource.instance.dismissSwipeSensitivity'
  expect(
    src.contains('ReaderFushiSource.instance.dismissSwipeSensitivity'),
    isTrue,
    reason: '$label must feed the live dismissSwipeSensitivity to the barrier',
  );
  // The regressed construct itself. See [_barrierArenaDrag] for why this is
  // scoped to preference-gated drags rather than banning onHorizontalDrag.
  expect(
    _barrierArenaDrag.hasMatch(src),
    isFalse,
    reason: '$label must NOT hang a preference-gated horizontal drag '
        'recognizer on the dismiss barrier (BUG-1757). Route the swipe through '
        'LookupDismissBarrier, whose Listener never enters the gesture arena.',
  );
}

void main() {
  group('barrier swipe-to-close wiring (BUG-1757)', () {
    test('video builds the barrier with the shared primitive, closes one layer',
        () {
      final String src = _flat(readVideoFushiSource());
      _assertBarrierSwipeWiring('video', src);
      // Over-threshold drag closes ONE layer (top visible index), never clears
      // the whole stack (clearing stays the tap path).
      expect(
        src.contains('_popNestedPopupAt(_topVisiblePopupIndex)'),
        isTrue,
        reason: 'video barrier drag closes one layer (top visible index)',
      );
      // never-break: tap-to-dismiss still routes through the positional handler.
      expect(src.contains('onTapDismiss: _onDismissBarrierTap'), isTrue,
          reason: 'video barrier still taps to dismiss (never-break)');
    });

    test(
        'home_dictionary builds the barrier with the shared primitive, closes '
        'one layer', () {
      final String src = _flat(_read(_homeDictionary));
      _assertBarrierSwipeWiring('home_dictionary', src);
      expect(
        src.contains('_popNestedPopupAt(_popup.lastVisibleIndex)'),
        isTrue,
        reason: 'home_dictionary barrier drag closes one layer',
      );
      // never-break: tap still clears the stack from the root layer.
      expect(src.contains('onTapDismiss: (_) => _popNestedPopupAt(0)'), isTrue,
          reason:
              'home_dictionary barrier still taps to dismiss (never-break)');
    });

    test(
        'texthooker builds the barrier with the shared primitive, closes one '
        'layer', () {
      final String src = _flat(_read(_texthooker));
      _assertBarrierSwipeWiring('texthooker', src);
      expect(
        src.contains('popNestedPopupAt(_topVisiblePopupIndex, _popup)'),
        isTrue,
        reason: 'texthooker barrier drag closes one layer',
      );
    });

    test(
        'base_source_page (reader / audiobook) builds the barrier with the '
        'shared primitive', () {
      final String src = _flat(_read(_baseSourcePage));
      _assertBarrierSwipeWiring('base_source_page', src);
      expect(
        src.contains('onSwipeDismiss: dismissTopPopup'),
        isTrue,
        reason: 'base_source_page barrier drag closes one layer',
      );
      // never-break: TODO-1027 positional tap + BUG-861 hover/wheel hooks stay.
      expect(src.contains('onTapDismiss: onDismissBarrierTap'), isTrue,
          reason: 'reader barrier tap still forwards the global position');
      expect(src.contains('onPointerHover: onDismissBarrierHover'), isTrue,
          reason: 'reader barrier still forwards hover (BUG-861)');
      expect(src.contains('onPointerSignal: onDismissBarrierPointerSignal'),
          isTrue,
          reason: 'reader barrier still forwards wheel signals');
    });
  });
}
