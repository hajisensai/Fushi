import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

// BUG-107: clicking a dictionary image opens a full-viewport lightbox
// (`.dict-image-lightbox`, the enlarged image with max-width/height:100% nearly
// fills the popup). The lightbox closes on a tap of the overlay, but the image
// itself used to carry `image.addEventListener('click', e => e.stopPropagation())`,
// which swallowed taps on the image — the only part the user can hit — so the
// lightbox was effectively unclosable (only the thin 16px padding margin worked).
// The preview has no in-image interaction, so the whole lightbox must be
// tap-to-close. Guard that no stopPropagation steals the image tap inside
// openImageLightbox.
void main() {
  test('image lightbox closes on any tap (no stopPropagation on the image)',
      () {
    // Mask JS comments at read time so neither the function-body window nor
    // the assertions below can be fooled by a comment. maskJsComments keeps
    // string / template / regex literal *content* intact and is
    // length-preserving, so the indexOf/substring offsets below still line up
    // with the real file.
    final String source =
        maskJsComments(File('assets/popup/popup.js').readAsStringSync());

    final int openIdx = source.indexOf('function openImageLightbox(');
    expect(openIdx, greaterThanOrEqualTo(0),
        reason: 'openImageLightbox not found in popup.js');
    final int endIdx = source.indexOf('\n}', openIdx);
    expect(endIdx, greaterThan(openIdx));
    final String body = source.substring(openIdx, endIdx);

    // The overlay (whole lightbox) must close on click.
    expect(body, contains("overlay.addEventListener('click'"),
        reason: 'lightbox overlay must close on tap');
    expect(body, contains('closeImageLightbox()'),
        reason: 'lightbox tap must call closeImageLightbox');

    // The image must NOT carry its own click handler — an
    // `image.addEventListener('click', …)` was used to stopPropagation, which
    // swallowed taps on the image (the only hittable part) and broke close.
    // `body` is already comment-masked (see the read above), so a comment
    // mentioning the old pattern cannot trip the guard.
    expect(body.contains("image.addEventListener('click'"), isFalse,
        reason:
            'the lightbox image must not have its own click handler — tapping '
            'the enlarged image (which fills the viewport) must bubble to the '
            'overlay and close the lightbox (BUG-107)');
    expect(body.contains('stopPropagation'), isFalse,
        reason: 'no stopPropagation inside openImageLightbox code (BUG-107)');
  });
}
