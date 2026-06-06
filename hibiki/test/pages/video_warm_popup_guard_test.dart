import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-094 source guard: VideoHibikiPage seeds one persistent hidden warm popup
/// slot and reuses it for every lookup, so the popup WebView is never cold-loaded
/// per lookup (the white flash that lasted "until the auto-read audio finished").
/// VideoHibikiPage drives media_kit, so its lookup/pause/resume/overlay behaviour
/// can't be widget-tested headlessly; these guards lock the wiring instead. The
/// reuse contract itself is behaviourally covered by
/// dictionary_page_mixin_warm_slot_test.dart.
void main() {
  const String path = 'lib/src/pages/implementations/video_hibiki_page.dart';

  test('video seeds and reuses a persistent warm popup slot', () {
    final String src = File(path).readAsStringSync();

    // A persistent hidden warm slot is seeded once the video loads successfully
    // (skipped in low memory; skipped on the missing-book error path so no
    // appModel/WebView is touched there).
    expect(src, contains('void _seedWarmPopup()'));
    expect(src, contains('isWarmSlot: true'));
    expect(src, contains('appModel.lowMemoryMode'));
    expect(src, contains('_seedWarmPopup();'),
        reason: 'the video success path must seed the warm slot');

    // Top lookups reuse that warm slot instead of recreating the WebView.
    expect(src, contains('reuseWarmSlot: true'),
        reason:
            '_lookupAt must reuse the warm slot, not cold-load a new WebView');
  });

  test('closing hides-and-keeps the warm slot; resume/back key off visibility',
      () {
    final String src = File(path).readAsStringSync();

    // Close hides the warm slot (keeps its WebView) rather than clearing it.
    expect(src, contains('_popupStack.first.isWarmSlot'));
    expect(src, contains('..visible = false'));

    // The persistent warm slot keeps the stack non-empty, so resume + back must
    // key off "no VISIBLE popup", not "stack empty" — else BUG-072 resume never
    // fires and back never exits the page.
    expect(src, contains('bool get _hasVisiblePopup'));
    expect(src, contains('stackEmpty: !_hasVisiblePopup'),
        reason:
            'resume-after-dismiss must treat the hidden warm slot as empty');
    expect(src, contains('if (_hasVisiblePopup)'),
        reason: 'back/exit + dismiss barrier must ignore the hidden warm slot');
    expect(src, isNot(contains('stackEmpty: _popupStack.isEmpty')),
        reason:
            'must not resume off raw stack emptiness with a warm slot present');
  });
}
