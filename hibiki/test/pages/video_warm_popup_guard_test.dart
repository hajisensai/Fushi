import 'package:flutter_test/flutter_test.dart';

import 'video_hibiki_page_source_corpus.dart';

/// BUG-094 source guard: VideoHibikiPage seeds one persistent hidden warm popup
/// slot and reuses it for every lookup, so the popup WebView is never cold-loaded
/// per lookup (the white flash that lasted "until the auto-read audio finished").
/// VideoHibikiPage drives media_kit, so its lookup/pause/resume/overlay behaviour
/// can't be widget-tested headlessly; these guards lock the wiring instead.
///
/// Post-unification the popup stack is owned by the shared
/// [DictionaryPopupController]; the warm-slot seed/reuse/hide-and-keep semantics
/// now live in the controller (behaviourally covered by
/// dictionary_popup_controller_test.dart + dictionary_page_mixin_warm_slot_test.dart).
void main() {
  // TODO-590 batch13: `_lookupAt`（含 `reuseWarmSlot: true`）已搬进
  // lookup_favorite.part.dart，改读合并语料。
  test('video seeds and reuses a persistent warm popup slot', () {
    final String src = readVideoHibikiSource();

    // A persistent hidden warm slot is seeded once the video loads successfully
    // via the shared controller (skipped in low memory inside the controller).
    expect(src, contains('void _seedWarmPopup()'));
    expect(src, contains('_popup.seedWarmSlot()'),
        reason: 'seeding must delegate to the shared controller');
    expect(src, contains('DictionaryPopupController('),
        reason: 'controller constructed (with the low-memory budget)');
    expect(src, contains('appModel.lowMemoryMode'),
        reason: 'low-memory budget threaded into the controller');
    expect(src, contains('_seedWarmPopup();'),
        reason: 'the video success path must seed the warm slot');

    // Top lookups reuse that warm slot instead of recreating the WebView.
    expect(src, contains('reuseWarmSlot: true'),
        reason:
            '_lookupAt must reuse the warm slot, not cold-load a new WebView');
  });

  test('closing hides-and-keeps the warm slot; resume/back key off visibility',
      () {
    final String src = readVideoHibikiSource();

    // Close delegates to the controller, which hides-and-keeps the warm slot
    // (rather than clearing it). The video also clears the warm WebView's text
    // selection on close.
    expect(src, contains('_popup.dismissAt(index)'));
    expect(src, contains('_popup.entries.first.isWarmSlot'));

    // The persistent warm slot keeps the stack non-empty, so resume + back must
    // key off "no VISIBLE popup", not "stack empty" — else BUG-072 resume never
    // fires and back never exits the page.
    expect(src, contains('bool get _hasVisiblePopup'));
    // TODO-040 hoisted the emptiness check into a local (shared by resume +
    // keyboard-focus reclaim); it must still derive from !_hasVisiblePopup.
    expect(src, contains('final bool stackEmpty = !_hasVisiblePopup;'),
        reason:
            'resume-after-dismiss must treat the hidden warm slot as empty');
    expect(src, contains('stackEmpty: stackEmpty'),
        reason: 'resume must key off the visible-popup-derived emptiness');
    expect(src, contains('if (_hasVisiblePopup)'),
        reason: 'back/exit + dismiss barrier must ignore the hidden warm slot');
    expect(src, isNot(contains('stackEmpty: _popup.entries.isEmpty')),
        reason:
            'must not resume off raw stack emptiness with a warm slot present');
  });
}
