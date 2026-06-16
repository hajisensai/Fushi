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
    // A small fraction of the raw delta per notch keeps each notch fine.
    expect(js, contains('POPUP_WHEEL_PIXEL_FACTOR'));
    expect(js, contains('* POPUP_WHEEL_PIXEL_FACTOR'));
  });

  test('uses a browser-like wheel pixel factor below the old coarse step', () {
    final factor = parseNumberConstant('POPUP_WHEEL_PIXEL_FACTOR');

    expect(factor, greaterThanOrEqualTo(0.12),
        reason: 'The factor must stay positive enough for touchpad inertia and '
            'long dictionary entries to remain usable.');
    expect(factor, lessThan(0.35),
        reason: 'TODO-460 asks for a smaller per-notch distance than the old '
            'BUG-260 factor.');
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
    expect(js, contains('/ popupCurrentZoom()'));
  });

  test('leaves inner vertically-scrollable containers to native scroll', () {
    // Nested scroll regions (description overlay, glossary y-overflow) must keep
    // native scroll until they hit a boundary — only the main document scroll is
    // refined, not stolen.
    expect(js, contains('popupAncestorAbsorbsVerticalWheel'));
    final absorbCheck =
        js.indexOf('popupAncestorAbsorbsVerticalWheel(e.target, deltaPx)');
    final preventDefault = js.indexOf('e.preventDefault()', absorbCheck);
    expect(absorbCheck, greaterThanOrEqualTo(0));
    expect(preventDefault, greaterThan(absorbCheck));
  });

  test('ignores ctrl+wheel zoom gestures and pure horizontal scroll', () {
    expect(js, contains('e.ctrlKey'));
    expect(js, contains('Math.abs(e.deltaY) <= Math.abs(e.deltaX)'));
  });
}
