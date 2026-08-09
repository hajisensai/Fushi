import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// BUG-260: the dictionary popup must refine the coarse native mouse-wheel step
/// into a finer, smoother per-pixel scroll. Without a custom wheel listener the
/// WebView's native page scroll steps a fixed, large number of CSS px per notch,
/// and the injected `documentElement.style.zoom` amplifies that (a layout-px
/// scroll moves px*zoom on screen). These guard the popup.js asset itself.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String js;

  setUpAll(() async {
    js = await rootBundle.loadString('assets/popup/popup.js');
  });

  double parseNumberConstant(String name) {
    final match =
        RegExp('const\\s+$name\\s*=\\s*([0-9]+(?:\\.[0-9]+)?);').firstMatch(js);
    expect(match, isNotNull, reason: '$name must be a numeric JS constant.');
    return double.parse(match!.group(1)!);
  }

  test('installs a non-passive wheel listener that preventDefaults', () {
    // The native coarse step is only suppressible from a non-passive listener.
    expect(js, contains("document.addEventListener('wheel'"));
    expect(js, contains('passive: false'));
    expect(js, contains('e.preventDefault()'));
  });

  test('drives the scroll through window.scrollBy (finer than native step)',
      () {
    expect(js, contains('window.scrollBy('));
    // BUG-870: the per-frame factor is now device-dependent (coarse mouse notch
    // vs fine touchpad); the coarse-mouse factor is still POPUP_WHEEL_PIXEL_FACTOR.
    expect(js, contains('POPUP_WHEEL_PIXEL_FACTOR'));
    expect(js, contains('deltaPx * factor'));
  });

  test('uses a balanced coarse-mouse factor below the native step', () {
    final factor = parseNumberConstant('POPUP_WHEEL_PIXEL_FACTOR');

    expect(factor, greaterThanOrEqualTo(0.4),
        reason: 'The old 0.24 factor moved only about 24px per mouse notch and '
            'felt too slow in the app-external lookup window.');
    expect(factor, lessThan(0.65),
        reason: 'The refined path must remain clearly below the native full '
            'step so one notch does not become chunky again.');
  });

  // BUG-870: POPUP_WHEEL_PIXEL_FACTOR is only for a COARSE mouse notch. A precision
  // touchpad / hi-res wheel reports small pixel deltas; the handler must classify
  // a small pixel-mode frame as a fine device and scroll it ~1:1 (factor 1.0),
  // otherwise coarse-mouse taming makes touchpad scrolling too slow. A gesture
  // latches its device class so a large mid-fling frame is not mis-tamed.
  test('classifies fine devices and scrolls them ~1:1 (BUG-870)', () {
    final trackpadFactor = parseNumberConstant('POPUP_WHEEL_TRACKPAD_FACTOR');
    expect(trackpadFactor, greaterThanOrEqualTo(0.9),
        reason: 'a fine device (touchpad / hi-res wheel) must scroll close to '
            '1:1, not be downscaled like a coarse mouse notch');

    final notchPx = parseNumberConstant('POPUP_WHEEL_MOUSE_NOTCH_PX');
    expect(notchPx, greaterThanOrEqualTo(30),
        reason: 'the threshold must sit above slow touchpad frames');
    expect(notchPx, lessThan(100),
        reason: 'and below a WebView2/Chromium mouse notch (≈100px)');

    // The per-frame factor is chosen by device class, not applied universally.
    expect(js, contains('const fineFrame ='));
    expect(js, contains('_popupWheelFineDevice'),
        reason: 'the gesture must latch its device class to avoid mis-taming a '
            'large mid-fling touchpad frame');
    expect(js, contains('const coarseMouseNotch ='));
    expect(js, contains('? POPUP_WHEEL_PIXEL_FACTOR'));
    expect(js, contains(': POPUP_WHEEL_TRACKPAD_FACTOR'));
  });

  test('caps a single wheel notch to avoid large device deltas jumping', () {
    final maxVisualStep = parseNumberConstant('POPUP_WHEEL_MAX_VISUAL_STEP');

    expect(maxVisualStep, greaterThanOrEqualTo(72));
    expect(maxVisualStep, lessThanOrEqualTo(180));
    expect(js, contains('popupClampWheelVisualStep'));
    expect(js, contains('Math.sign(step)'));
    expect(js, contains('POPUP_WHEEL_MAX_VISUAL_STEP'));
  });

  test('normalizes deltaMode (LINE/PAGE -> pixels)', () {
    expect(js, contains('popupWheelDeltaToPixels'));
    expect(js, contains('DOM_DELTA_LINE'));
    expect(js, contains('DOM_DELTA_PAGE'));
    expect(js, contains('e.deltaMode'));
  });

  test('compensates for the injected CSS zoom so the step is zoom-independent',
      () {
    // popupContentZoom is set on document.documentElement.style.zoom; the wheel
    // step must divide by it (V px on screen needs V/zoom layout px).
    expect(js, contains('popupCurrentZoom'));
    expect(js, contains('document.documentElement.style.zoom'));
    // BUG-688: the popup.js is shared with the browser extension where the
    // scroll surface is the shadow host; in-app resolves to null scroller and
    // keeps dividing by the documentElement zoom exactly as before.
    expect(js, contains('/ popupCurrentZoom(scroller)'));
  });

  test('leaves inner vertically-scrollable containers to native scroll', () {
    // Nested scroll regions (description overlay, glossary y-overflow) must keep
    // native scroll until they hit a boundary — only the main document scroll is
    // refined, not stolen.
    expect(js, contains('popupAncestorAbsorbsVerticalWheel'));
    // BUG-688: the target is resolved through composedPath so the walk also
    // works from inside the extension shadow root; in-app it equals e.target.
    final absorbCheck = js.indexOf(
        'popupAncestorAbsorbsVerticalWheel(__fushiEventTarget(e), deltaPx)');
    final preventDefault = js.indexOf('e.preventDefault()', absorbCheck);
    expect(absorbCheck, greaterThanOrEqualTo(0));
    expect(preventDefault, greaterThan(absorbCheck));
  });

  test('ignores ctrl+wheel zoom gestures and predominantly-horizontal scroll',
      () {
    expect(js, contains('e.ctrlKey'));
    // TODO-1387: the horizontal-reject predicate was tightened from a coarse
    // `deltaY <= deltaX` early-return to a strict lead plus a jitter margin, so
    // equal-magnitude and jittery-vertical touchpad frames still scroll instead
    // of being dropped. The old bare `<=` reject must be gone.
    expect(js.contains('Math.abs(e.deltaY) <= Math.abs(e.deltaX)'), isFalse,
        reason: 'the coarse <= horizontal reject dropped touchpad vertical '
            'frames that carried horizontal jitter (TODO-1387); it must be gone');
    expect(js, contains('POPUP_WHEEL_HORIZONTAL_MARGIN'));
    expect(js, contains('absX > absY + POPUP_WHEEL_HORIZONTAL_MARGIN'));
  });

  // TODO-1387: a precision touchpad reports deltaMode=PIXEL with a tiny
  // fractional deltaY; after the 0.24 factor and the zoom divide each frame is a
  // fraction of a layout pixel. Without a cross-event accumulator the fraction
  // was lost every frame (preventDefault killed native scroll while the popup
  // advanced ~0px), so slow touchpad scrolling froze ("时好时坏"). The handler
  // must carry the sub-pixel remainder and emit only whole pixels. Behavioural
  // proof (real scroll displacement) lives in popup_wheel_scroll_behavior_test.
  test('carries the sub-pixel wheel remainder across events (TODO-1387)', () {
    expect(js, contains('_popupWheelResidual'),
        reason:
            'the wheel handler must keep a sub-pixel remainder accumulator');
    expect(js, contains('const step = Math.trunc(_popupWheelResidual);'),
        reason:
            'only the whole-pixel part may be emitted; the fraction carries');
    expect(js, contains('POPUP_WHEEL_RESIDUAL_IDLE_MS'),
        reason: 'a stale remainder must be reset after an idle gap');
    // The emitted scroll must be the truncated integer, never the raw fractional
    // layout step (regression: scrollBy(fraction) loses the sub-pixel each frame).
    expect(js, contains("scroller.scrollBy({ top: step, behavior: 'auto' })"));
    expect(js, contains("window.scrollBy({ top: step, behavior: 'auto' })"));
  });
}
