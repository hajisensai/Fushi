import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-scan guard for BUG-871: Windows touchscreen finger-drag must scroll the
/// dictionary popup (and every other InAppWebView) WebView.
///
/// Root cause: injected touch (`SendPointerInput(PT_TOUCH)`) carried no
/// system-assigned primary contact, so Chromium never started a pan/scroll
/// manipulation from a finger drag — only discrete tap / long-press landed. The
/// fix flags the first active contact `POINTER_FLAG_PRIMARY` for its lifetime and
/// forwards a touch cancel as an up so a stranded primary id can never wedge the
/// next gesture.
///
/// The native window cannot run on the test host, so this pins the load-bearing
/// bits so a `pub get` re-vendor or refactor cannot silently regress them. Real
/// finger-drag scrolling still needs a Windows touchscreen to verify.
void main() {
  late String setPointerBody;
  late String customView;

  setUpAll(() {
    final String cpp = File(
      '../packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview.cpp',
    ).readAsStringSync();
    final int start = cpp.indexOf('void InAppWebView::setPointerUpdate');
    expect(start, greaterThanOrEqualTo(0),
        reason:
            'setPointerUpdate must exist in the vendored in_app_webview.cpp');
    final int end =
        cpp.indexOf('void InAppWebView::setPointerButtonState', start);
    expect(end, greaterThan(start),
        reason: 'setPointerButtonState must follow setPointerUpdate');
    setPointerBody = cpp.substring(start, end);

    customView = File(
      '../packages/flutter_inappwebview_windows/lib/src/in_app_webview/custom_platform_view.dart',
    ).readAsStringSync();
  });

  group('BUG-871 injected touch flags a primary contact', () {
    test('the first active contact is tracked and flagged PRIMARY', () {
      expect(setPointerBody.contains('primaryTouchPointerId_'), isTrue,
          reason: 'the first active touch contact must be tracked');
      expect(setPointerBody.contains('POINTER_FLAG_PRIMARY'), isTrue,
          reason: 'the primary contact must carry POINTER_FLAG_PRIMARY so '
              'Chromium recognises a pan/scroll manipulation');
      // Only the primary contact gets the flag; it is cleared on its own up.
      expect(
          setPointerBody.contains('pointer == primaryTouchPointerId_'), isTrue,
          reason: 'only the primary contact may carry the flag');
      expect(setPointerBody.contains('primaryTouchPointerId_ = -1'), isTrue,
          reason: 'the primary must be released on its up so a later gesture '
              'can claim it');
    });

    test('a cancelled touch is forwarded as an up (no stranded primary)', () {
      // onPointerCancel must send a pointer up for touch so the native primary
      // id is never stranded by a cancelled contact.
      final int cancel = customView.indexOf('onPointerCancel:');
      expect(cancel, greaterThanOrEqualTo(0),
          reason: 'onPointerCancel handler must exist');
      final int nextHandler = customView.indexOf('onPointerMove:', cancel);
      final String cancelBody = customView.substring(
          cancel, nextHandler > cancel ? nextHandler : customView.length);
      expect(cancelBody.contains('PointerDeviceKind.touch'), isTrue,
          reason: 'a cancelled touch must be handled distinctly');
      expect(cancelBody.contains('InAppWebViewPointerEventKind.up'), isTrue,
          reason: 'a cancelled touch must forward an up to the WebView');
    });
  });
}
