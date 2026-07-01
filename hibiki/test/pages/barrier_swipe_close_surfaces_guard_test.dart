import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'video_hibiki_page_source_corpus.dart';

/// TODO-1052 (parent TODO-716 phase 2): the desktop "horizontal swipe over the
/// dismiss barrier closes one popup layer" gesture — first shipped on
/// reader/audiobook via base_source_page — is extended to the three surfaces
/// that own their OWN dismiss barrier (they do NOT extend BaseSourcePage):
/// video, home_dictionary and texthooker. This source-level guard locks the
/// wiring contract on all three so a future refactor cannot silently drop it:
///   - each barrier gates its onHorizontalDrag* handlers on
///     `ReaderHibikiSource.instance.enableSwipeToClose` (switch OFF => only tap,
///     old desktop behaviour, never-break);
///   - each routes the drag through the shared [BarrierSwipeDismissTracker]
///     (single source of truth, no threshold magic-number drift), passing the
///     live `dismissSwipeSensitivity`;
///   - an over-threshold drag closes ONE layer (layer-by-layer, like cursor
///     B/Esc), NOT the whole stack (tap on true blank still clears the stack).
///
/// The barrier-widget dismiss BEHAVIOUR (drag distance -> stack shrinks by one)
/// is exercised end-to-end for the shared implementation in
/// base_source_page_barrier_swipe_close_test.dart (which now runs through the
/// same tracker), and the tracker's pure math in
/// utils/barrier_swipe_dismiss_tracker_test.dart. These guards ensure the three
/// extra hosts actually reference that shared path.
String _read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

const String _homeDictionary =
    'lib/src/pages/implementations/home_dictionary_page.dart';
const String _texthooker = 'lib/src/pages/implementations/texthooker_page.dart';

/// Assert a source references the shared tracker and gates barrier drag on the
/// swipe-to-close preference, closing one layer (not clearing the stack).
void _assertBarrierSwipeWiring(String label, String src) {
  expect(src.contains('BarrierSwipeDismissTracker'), isTrue,
      reason: '$label must route barrier swipe through the shared tracker');
  expect(src.contains('onHorizontalDragStart:'), isTrue,
      reason: '$label barrier must handle onHorizontalDragStart');
  expect(src.contains('onHorizontalDragUpdate:'), isTrue,
      reason: '$label barrier must handle onHorizontalDragUpdate');
  expect(src.contains('onHorizontalDragEnd:'), isTrue,
      reason: '$label barrier must handle onHorizontalDragEnd');
  expect(
    src.contains('ReaderHibikiSource.instance.enableSwipeToClose'),
    isTrue,
    reason: '$label must gate barrier drag on enableSwipeToClose (switch OFF '
        '=> tap-only, never-break)',
  );
  expect(
    src.contains('ReaderHibikiSource.instance.dismissSwipeSensitivity'),
    isTrue,
    reason: '$label must feed the live dismissSwipeSensitivity to the tracker',
  );
}

void main() {
  group('barrier swipe-to-close wiring (video / home_dictionary / texthooker)',
      () {
    test(
        'video routes barrier drag through the shared tracker, closes one '
        'layer', () {
      final String src = readVideoHibikiSource();
      _assertBarrierSwipeWiring('video', src);
      // Over-threshold drag closes ONE layer (top visible index), never clears
      // the whole stack (clearing stays the onTapUp path).
      expect(
        src.contains('_popNestedPopupAt(_topVisiblePopupIndex)'),
        isTrue,
        reason: 'video barrier drag closes one layer (top visible index)',
      );
      // never-break: the existing tap-to-dismiss handler is untouched.
      expect(src.contains('onTapUp: (TapUpDetails d) =>'), isTrue,
          reason: 'video barrier still taps to dismiss (never-break)');
    });

    test(
        'home_dictionary routes barrier drag through the shared tracker, '
        'closes one layer', () {
      final String src = _read(_homeDictionary);
      _assertBarrierSwipeWiring('home_dictionary', src);
      expect(
        src.contains('_popNestedPopupAt(_popup.lastVisibleIndex)'),
        isTrue,
        reason: 'home_dictionary barrier drag closes one layer',
      );
      // never-break: existing tap clears the stack (onTap: _popNestedPopupAt(0)).
      expect(src.contains('onTap: () => _popNestedPopupAt(0)'), isTrue,
          reason:
              'home_dictionary barrier still taps to dismiss (never-break)');
    });

    test(
        'texthooker gains a dismiss barrier routing drag through the shared '
        'tracker, closes one layer', () {
      final String src = _read(_texthooker);
      _assertBarrierSwipeWiring('texthooker', src);
      expect(
        src.contains('popNestedPopupAt(_topVisiblePopupIndex, _popup)'),
        isTrue,
        reason: 'texthooker barrier drag closes one layer',
      );
      // texthooker previously had NO barrier; the new barrier renders only when
      // a popup is visible / searching (so it never blocks the text list).
      expect(
        src.contains('_popup.hasVisiblePopup || _popup.isSearchingUi'),
        isTrue,
        reason: 'texthooker barrier only renders while a popup is visible',
      );
    });
  });
}
