import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'video_hibiki_page_source_corpus.dart';

/// TODO-1052 (parent TODO-716 phase 2): the desktop "horizontal swipe over the
/// dismiss barrier closes one popup layer" gesture — first shipped on
/// reader/audiobook via base_source_page — is extended to the surfaces that own
/// their OWN dismiss barrier (they do NOT extend BaseSourcePage): video and
/// home_dictionary. This source-level guard locks the wiring contract so a
/// future refactor cannot silently drop it:
/// (texthooker was a third such surface; its page was removed when galgame
/// captions were unified into the lookup popup, so it is no longer guarded.)
///   - the barrier gates its onHorizontalDrag* handlers on
///     `ReaderHibikiSource.instance.enableSwipeToClose` (switch OFF => only tap,
///     old desktop behaviour, never-break);
///   - the drag routes through the shared [BarrierSwipeDismissTracker]
///     (single source of truth, no threshold magic-number drift), passing the
///     live `dismissSwipeSensitivity`;
///   - an over-threshold drag closes ONE layer (layer-by-layer, like cursor
///     B/Esc), NOT the whole stack (tap on true blank still clears the stack).
///
/// 2026-07-24 去重：video / home_dictionary 两页逐字相同的 barrier 滑动接线已上提到
/// `DictionaryPopupOverlayHostMixin`（dictionary_page_mixin.dart），故共享接线在
/// mixin 里守一份，两页守「确实混入该 mixin + 各自 tap 分叉未被顺手统一」。
///
/// The barrier-widget dismiss BEHAVIOUR (drag distance -> stack shrinks by one)
/// is exercised end-to-end for the shared implementation in
/// base_source_page_barrier_swipe_close_test.dart (which now runs through the
/// same tracker), and the tracker's pure math in
/// utils/barrier_swipe_dismiss_tracker_test.dart. These guards ensure the two
/// extra hosts actually reference that shared path.
String _read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

const String _homeDictionary =
    'lib/src/pages/implementations/home_dictionary_page.dart';
const String _dictionaryPageMixin =
    'lib/src/pages/implementations/dictionary_page_mixin.dart';

void main() {
  group('barrier swipe-to-close wiring (video / home_dictionary)', () {
    test(
        'shared overlay-host mixin routes barrier drag through the shared '
        'tracker, closes one layer', () {
      final String src = _read(_dictionaryPageMixin);
      expect(src.contains('BarrierSwipeDismissTracker'), isTrue,
          reason: 'mixin must route barrier swipe through the shared tracker');
      expect(src.contains('onHorizontalDragStart:'), isTrue,
          reason: 'barrier must handle onHorizontalDragStart');
      expect(src.contains('onHorizontalDragUpdate:'), isTrue,
          reason: 'barrier must handle onHorizontalDragUpdate');
      expect(src.contains('onHorizontalDragEnd:'), isTrue,
          reason: 'barrier must handle onHorizontalDragEnd');
      expect(
        src.contains('ReaderHibikiSource.instance.enableSwipeToClose'),
        isTrue,
        reason: 'must gate barrier drag on enableSwipeToClose (switch OFF '
            '=> tap-only, never-break)',
      );
      // 门控经钩子 popupBarrierSwipeToCloseEnabled（默认即上面的偏好来源）。
      expect(src.contains('popupBarrierSwipeToCloseEnabled'), isTrue,
          reason: 'drag handlers must be gated on the swipe-to-close hook');
      expect(
        src.contains('ReaderHibikiSource.instance.dismissSwipeSensitivity'),
        isTrue,
        reason: 'must feed the live dismissSwipeSensitivity to the tracker',
      );
      // Over-threshold drag closes ONE layer (top visible index), never clears
      // the whole stack (clearing stays the tap path).
      expect(
        src.contains(
            'popPopupLayerAt(popupOverlayController.lastVisibleIndex)'),
        isTrue,
        reason: 'barrier drag closes one layer (top visible index)',
      );
    });

    test('video mixes in the shared overlay host and keeps its tap fork', () {
      final String src = readVideoHibikiSource();
      expect(src.contains('DictionaryPopupOverlayHostMixin'), isTrue,
          reason: 'video must mix in the shared popup overlay host');
      // never-break: the existing coordinate-carrying tap-to-dismiss handler
      // is untouched (word-switch on subtitle hit, dismiss+resume elsewhere).
      expect(
        src.contains(
            '(TapUpDetails d) => _onDismissBarrierTap(d.globalPosition)'),
        isTrue,
        reason: 'video barrier still taps to dismiss via onTapUp (never-break)',
      );
      // video must not fall back to the mixin default onTap (clear-stack) —
      // both firing would double-handle a single tap.
      expect(src.contains('GestureTapCallback? get popupBarrierOnTap => null'),
          isTrue,
          reason: 'video overrides the default onTap off (onTapUp only)');
    });

    test('home_dictionary mixes in the shared overlay host, default tap clears',
        () {
      final String src = _read(_homeDictionary);
      expect(src.contains('DictionaryPopupOverlayHostMixin'), isTrue,
          reason: 'home_dictionary must mix in the shared popup overlay host');
      // never-break: home keeps the mixin default tap (clear stack) — the
      // default lives in the mixin as popPopupLayerAt(0).
      final String mixin = _read(_dictionaryPageMixin);
      expect(mixin.contains('popPopupLayerAt(0)'), isTrue,
          reason: 'mixin default barrier tap must clear the stack (home path)');
      expect(src.contains('popupBarrierOnTap'), isFalse,
          reason: 'home_dictionary must not override the default barrier tap');
    });
  });
}
