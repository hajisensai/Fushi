import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-scan guard for BUG-870: the Windows WebView2 fork must accumulate a
/// per-axis sub-unit remainder in [InAppWebView::sendScroll] instead of
/// truncating each scroll delta to a `short` independently.
///
/// Root cause: `static_cast<short>(delta * kScrollMultiplier)` rounds toward
/// zero with no cross-call carry. A precision touchpad delivers small per-frame
/// deltas; any frame whose scaled magnitude is < 1 became 0 and sent no wheel to
/// WebView2 at all — the dictionary popup "could not scroll" with a touchpad
/// while a mouse (delta≈20 → 120) worked. This is upstream of popup.js's
/// TODO-1387 sub-pixel carry: the wheel never even reached the DOM.
///
/// The native window cannot run on the test host, so this pins the load-bearing
/// bits of the fix so a `pub get` re-vendor or refactor cannot silently regress
/// it. Behaviour proof of the JS-side factor lives in
/// popup_wheel_scroll_behavior_test.js.
void main() {
  late String sendScrollBody;

  setUpAll(() {
    final String cpp = File(
      '../packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview.cpp',
    ).readAsStringSync();
    final int start = cpp.indexOf('void InAppWebView::sendScroll');
    expect(start, greaterThanOrEqualTo(0),
        reason: 'sendScroll must exist in the vendored in_app_webview.cpp');
    final int end = cpp.indexOf('void InAppWebView::setScrollDelta', start);
    expect(end, greaterThan(start),
        reason: 'setScrollDelta must follow sendScroll');
    sendScrollBody = cpp.substring(start, end);
  });

  group('BUG-870 native sendScroll carries a sub-unit remainder', () {
    test('reads a per-axis residual and carries the truncated fraction', () {
      // A precision touchpad's small deltas must accumulate across calls rather
      // than each truncating to 0.
      expect(sendScrollBody.contains('scrollResidualX_'), isTrue,
          reason: 'horizontal axis must carry its own sub-unit remainder');
      expect(sendScrollBody.contains('scrollResidualY_'), isTrue,
          reason: 'vertical axis must carry its own sub-unit remainder');
      expect(sendScrollBody.contains('residual = scaled - offset'), isTrue,
          reason: 'the truncated fraction must be kept for the next call');
    });

    test('skips sending a wheel only when the accumulated offset is still zero',
        () {
      // A sub-unit frame must return WITHOUT sending (offset 0), so the fraction
      // keeps accumulating instead of firing a spurious zero-delta wheel.
      expect(sendScrollBody.contains('if (offset == 0)'), isTrue,
          reason:
              'a sub-unit frame must carry its fraction and not send a 0 wheel');
    });

    test('does not truncate the raw delta directly to short (the old bug)', () {
      // The regression was `static_cast<short>(delta * kScrollMultiplier)` with
      // no residual — truncating each frame independently. The cast must now act
      // on the residual-accumulated `scaled` value, never on the raw product.
      expect(
        sendScrollBody
            .contains('static_cast<short>(delta * kScrollMultiplier)'),
        isFalse,
        reason: 'truncating the raw delta*multiplier drops small touchpad '
            'frames to 0 (BUG-870); it must accumulate a residual first',
      );
      expect(sendScrollBody.contains('static_cast<short>(scaled)'), isTrue,
          reason: 'the short cast must act on the residual-accumulated value');
    });
  });
}
