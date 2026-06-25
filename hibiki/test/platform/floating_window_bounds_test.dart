import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/platform/floating_window_bounds.dart';

/// Truth table for TODO-832 floating-window off-screen clamp. The native Win32
/// (ClampOriginToWorkArea) and Android (clampToScreen) paths re-implement this
/// same formula, pinned to this single tested source by source-scan guards.
void main() {
  // A simple "monitor": work area 0,0 → 1000,800 (one unit system, e.g. px).
  const Rect bounds = Rect.fromLTWH(0, 0, 1000, 800);
  const Size window = Size(300, 200);
  const double minVisible = 48;

  Offset clamp(Offset origin) => clampFloatingWindowOrigin(
        origin: origin,
        windowSize: window,
        bounds: bounds,
        minVisible: minVisible,
      );

  group('clampFloatingWindowOrigin', () {
    test('fully inside → unchanged', () {
      const Offset inside = Offset(400, 300);
      expect(clamp(inside), inside);
    });

    test('dragged off the right → exactly minVisible stays visible', () {
      // x pushed far right; right edge of window = clampedX + width.
      final Offset out = clamp(const Offset(5000, 300));
      // Visible width inside bounds = bounds.right - clampedX must equal minVisible.
      final double visible = bounds.right - out.dx;
      expect(visible, minVisible);
      expect(out.dy, 300);
    });

    test('dragged off the bottom → exactly minVisible stays visible', () {
      final Offset out = clamp(const Offset(400, 5000));
      final double visible = bounds.bottom - out.dy;
      expect(visible, minVisible);
      expect(out.dx, 400);
    });

    test('dragged off the left → exactly minVisible stays visible', () {
      final Offset out = clamp(const Offset(-5000, 300));
      // Right edge of window = clampedX + width; visible part inside = that
      // minus bounds.left, must equal minVisible.
      final double rightEdge = out.dx + window.width;
      expect(rightEdge - bounds.left, minVisible);
      expect(out.dy, 300);
    });

    test('dragged off the top → exactly minVisible stays visible', () {
      final Offset out = clamp(const Offset(400, -5000));
      final double bottomEdge = out.dy + window.height;
      expect(bottomEdge - bounds.top, minVisible);
      expect(out.dx, 400);
    });

    test('exact left/top boundary value does not jitter', () {
      // The most-off-left legal origin: bounds.left - (width - minVisible).
      final Offset edge =
          Offset(bounds.left - (window.width - minVisible), bounds.top);
      expect(clamp(edge), edge);
    });

    test('exact right/bottom boundary value does not jitter', () {
      final Offset edge =
          Offset(bounds.right - minVisible, bounds.bottom - minVisible);
      expect(clamp(edge), edge);
    });

    test('window wider than screen (margin still < window) keeps minVisible',
        () {
      // Window bigger than the work area but minVisible (48) is smaller than
      // both window and bounds, so the legal range stays valid (min < max) and
      // a normal clamp applies — it is NOT ejected to a corner.
      const Size huge = Size(2000, 1600);
      Offset clampHuge(Offset origin) => clampFloatingWindowOrigin(
            origin: origin,
            windowSize: huge,
            bounds: bounds,
            minVisible: minVisible,
          );
      // Pushed far off-right/bottom: clamps to the upper bound so exactly
      // minVisible stays inside on the right / bottom edge.
      final Offset out = clampHuge(const Offset(9999, 9999));
      expect(bounds.right - out.dx, minVisible);
      expect(bounds.bottom - out.dy, minVisible);
    });

    test(
        'degenerate inverted range (window wider than bounds, full window '
        'must show) anchors to lower bound without throwing', () {
      // minVisible >= windowSize caps the margin to windowSize, requiring the
      // whole window to be visible; when the window is also wider than the
      // bounds that is impossible (lo > hi) and we must anchor to lo
      // (bounds.left) instead of letting clamp throw on an inverted range.
      const Size wide = Size(60, 60); // wider than the tiny bounds below
      const Rect tinyBounds = Rect.fromLTWH(0, 0, 40, 40);
      final Offset out = clampFloatingWindowOrigin(
        origin: const Offset(999, 999),
        windowSize: wide,
        bounds: tinyBounds,
        minVisible: 100, // > windowSize → margin caps to 60 → full window
      );
      expect(out, const Offset(0, 0)); // anchored to bounds top-left
    });

    test('non-zero work-area origin (secondary monitor) clamps relative to it',
        () {
      // Monitor offset to the right: 1920,0 → 3520,900.
      const Rect monitor = Rect.fromLTWH(1920, 0, 1600, 900);
      Offset clampMon(Offset origin) => clampFloatingWindowOrigin(
            origin: origin,
            windowSize: window,
            bounds: monitor,
            minVisible: minVisible,
          );
      final Offset out = clampMon(const Offset(99999, 300));
      expect(monitor.right - out.dx, minVisible);
      final Offset left = clampMon(const Offset(-99999, 300));
      expect((left.dx + window.width) - monitor.left, minVisible);
    });
  });
}
