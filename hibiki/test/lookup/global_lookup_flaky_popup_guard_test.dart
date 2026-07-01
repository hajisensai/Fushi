import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1079 / BUG-503 — app-external (Windows) global lookup popup "sometimes
/// does not appear" root-cause guards (source scan).
///
/// The overlay is a real top-level WebView2 window. The flake was a timing /
/// lifecycle-ownership problem, not a platform limit:
///   A. the overlay WebView2 was created lazily on the first ShowAt and NEVER
///      prewarmed, so the first hotkey raced a cold create chain (>450ms);
///   B. reveal fell back to a BLIND 450ms timeout that could reveal a
///      not-yet-loaded surface as a blank window;
///   C. the host's lastBBoxKey de-dup could swallow a new lookup's first
///      overlaySize (the reveal driver) when its bbox equalled the previous;
///   D. native visible_/revealed_ and Dart _revealed drifted across lookups.
///
/// These guards lock the fix wiring at the strongest layer this harness can
/// reach (source scan); the real WebView2 cold-start timing is a device/visual
/// (Category-A) item verified on hardware by the integration owner.
void main() {
  String read(String p) => File(p).readAsStringSync();

  group('A — overlay WebView2 is prewarmed off-screen (own ownership)', () {
    test('Dart channel exposes prewarmWebView', () {
      final String ch = read('lib/src/lookup/global_lookup_channel.dart');
      expect(ch.contains("invokeMethod<void>('prewarmWebView'"), isTrue,
          reason: 'a dedicated prewarm channel method must exist');
    });

    test('controller triggers the prewarm from start()', () {
      final String c = read('lib/src/lookup/global_lookup_controller.dart');
      expect(c.contains('GlobalLookupChannel.prewarmWebView('), isTrue);
      expect(c.contains('_prewarmOverlay('), isTrue,
          reason: 'start() must kick the off-screen prewarm');
    });

    test('native window has a PrewarmWebView entry that navigates host.html',
        () {
      final String h = read('windows/runner/global_lookup_window.h');
      expect(h.contains('void PrewarmWebView('), isTrue);
      final String cpp = read('windows/runner/global_lookup_window.cpp');
      expect(cpp.contains('void GlobalLookupWindow::PrewarmWebView('), isTrue);
      // Prewarm builds the window + WebView2 (EnsureWebView navigates host.html)
      // and shows it OFF-SCREEN without arming visible_/the dismiss hooks.
      final int idx = cpp.indexOf('GlobalLookupWindow::PrewarmWebView(');
      final int end = cpp.indexOf('\n}\n', idx);
      final String body = cpp.substring(idx, end);
      expect(body.contains('EnsureWebView()'), isTrue);
      expect(body.contains('OffscreenX()'), isTrue);
      expect(body.contains('visible_ = false'), isTrue);
    });

    test('the channel dispatches prewarmWebView natively', () {
      final String fw = read('windows/runner/flutter_window.cpp');
      expect(fw.contains('method == "prewarmWebView"'), isTrue);
      expect(fw.contains('->PrewarmWebView('), isTrue);
    });
  });

  group('B — reveal fallback is READY-DRIVEN, not a blind 450ms timeout', () {
    late String c;
    setUpAll(() {
      c = read('lib/src/lookup/global_lookup_controller.dart');
    });

    test('a readiness query exists on the channel + native', () {
      final String ch = read('lib/src/lookup/global_lookup_channel.dart');
      expect(ch.contains("invokeMethod<bool>('isWebViewReady')"), isTrue);
      final String fw = read('windows/runner/flutter_window.cpp');
      expect(fw.contains('method == "isWebViewReady"'), isTrue);
      final String hpp = read('windows/runner/global_lookup_window.h');
      expect(hpp.contains('bool IsWebViewReady()'), isTrue);
    });

    test('the safety reveal confirms readiness before revealing', () {
      expect(c.contains('_scheduleReadyDrivenSafety('), isTrue);
      expect(c.contains('GlobalLookupChannel.isWebViewReady()'), isTrue,
          reason: 'the fallback must gate on isWebViewReady, not reveal blind');
    });

    test('the retired blind-timeout reveal is gone', () {
      // The old path revealed unconditionally on a 450ms Timer regardless of
      // readiness. That exact "SAFETY timeout" reveal must no longer exist.
      expect(c.contains("glog('reveal: SAFETY timeout"), isFalse,
          reason: 'the blind 450ms reveal must be replaced by the ready gate');
    });
  });

  group('C — host bbox de-dup is reset per new lookup', () {
    test('host resets lastBBoxKey when the root frame id changes', () {
      final String js = read('assets/popup/global_lookup_host.js');
      expect(js.contains('lastRootId'), isTrue,
          reason: 'the host must track the root id to detect a fresh lookup');
      // A changed root id clears the de-dup so the new card overlaySize fires.
      expect(
          js.contains('lastBBoxKey = ') && js.contains('rootId !== lastRootId'),
          isTrue);
    });
  });

  group('D — reveal state is reset from zero every lookup', () {
    test('_onHotKey issues an unconditional hide() up front', () {
      final String c = read('lib/src/lookup/global_lookup_controller.dart');
      final int fire = c.indexOf("glog('hotkey: FIRED');");
      final int capture =
          c.indexOf('SelectionCapture.captureForegroundSelection');
      expect(fire, greaterThanOrEqualTo(0));
      expect(capture, greaterThan(fire));
      // The hide() reset must sit between the hotkey firing and selection
      // capture, so native + Dart reveal state collapse to known-hidden first.
      final String prelude = c.substring(fire, capture);
      expect(prelude.contains('GlobalLookupChannel.hide();'), isTrue,
          reason:
              'each lookup must reset reveal state before showAt re-arms it');
    });
  });
}
