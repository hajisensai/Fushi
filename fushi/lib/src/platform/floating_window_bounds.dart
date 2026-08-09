import 'dart:ui';

/// Clamps the top-left [origin] of a draggable floating window so that it can
/// never be dragged (or restored) entirely off the visible work area: at least
/// [minVisible] of the window stays inside [bounds] on every edge, so the user
/// can always grab it back. This is the algorithmic source of truth for
/// TODO-832 (悬浮字幕/词典浮层拖动越界). The native Win32 (cpp) and Android
/// (java) drag paths re-implement this exact formula; this Dart function exists
/// as the single tested truth table and is mirrored by source-scan guards.
///
/// Unit-system contract (load-bearing): [origin], [windowSize], [bounds] and
/// [minVisible] MUST all be expressed in the SAME unit system. On Windows that
/// is screen physical pixels (drag_anchor / new_x / rcWork, margin already run
/// through ScaleForDpi) — never mix in client DIP. On Android that is physical
/// pixels (layoutParams / getRawX / WindowMetrics, MIN_VISIBLE_DP already run
/// through dpToPx). This function does no unit conversion; the caller owns it.
///
/// Formula (越界时可见交集恰等于 minVisible):
///   x ∈ [bounds.left - (windowSize.width  - minVisible), bounds.right  - minVisible]
///   y ∈ [bounds.top  - (windowSize.height - minVisible), bounds.bottom - minVisible]
///
/// When the window is larger than [bounds] the lower clamp bound exceeds the
/// upper one; we clamp to the lower bound (top-left anchored) so the window is
/// never forcibly ejected and still keeps ≥ [minVisible] visible.
Offset clampFloatingWindowOrigin({
  required Offset origin,
  required Size windowSize,
  required Rect bounds,
  required double minVisible,
}) {
  // Keep minVisible sane: a window narrower/shorter than the requested margin
  // can at most show its whole extent, so cap the per-axis margin.
  final double marginX =
      minVisible < windowSize.width ? minVisible : windowSize.width;
  final double marginY =
      minVisible < windowSize.height ? minVisible : windowSize.height;

  final double minX = bounds.left - (windowSize.width - marginX);
  final double maxX = bounds.right - marginX;
  final double minY = bounds.top - (windowSize.height - marginY);
  final double maxY = bounds.bottom - marginY;

  final double clampedX = _clampInverted(origin.dx, minX, maxX);
  final double clampedY = _clampInverted(origin.dy, minY, maxY);
  return Offset(clampedX, clampedY);
}

/// Clamps [value] into [lo, hi]. When the window is bigger than the work area
/// `lo > hi`; in that degenerate case we anchor to `lo` (top-left) instead of
/// letting [num.clamp] throw on an inverted range.
double _clampInverted(double value, double lo, double hi) {
  if (lo > hi) {
    return lo;
  }
  if (value < lo) {
    return lo;
  }
  if (value > hi) {
    return hi;
  }
  return value;
}
