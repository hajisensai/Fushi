import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:fushi/src/models/game_stream_lookup_layout.dart';

/// Fitting the game stream's current line into its area: shared by the
/// stream page's rail and the companion panel on the second display, which
/// must not pull the whole stream page (WebRTC, receiver) into its process.

/// Largest font size in [floor]..[GameStreamLookupLayout.maxFitFontSize] at
/// which [text] laid out [width] wide stays within [height]. A line that does
/// not fit even at [floor] keeps [floor] (the area scrolls). Half-point steps.
double gameStreamFitLineFontSize({
  required String text,
  required TextStyle Function(double size) styleFor,
  required double width,
  required double height,
  required double floor,
  TextScaler textScaler = TextScaler.noScaling,
  TextDirection textDirection = TextDirection.ltr,
}) {
  final double ceiling = math.max(floor, GameStreamLookupLayout.maxFitFontSize);
  if (text.isEmpty || width <= 0 || height <= 0) return floor;
  final TextPainter painter = TextPainter(
    textScaler: textScaler,
    textDirection: textDirection,
  );
  bool fits(double size) {
    painter
      ..text = TextSpan(text: text, style: styleFor(size))
      ..layout(maxWidth: width);
    return painter.height <= height && painter.width <= width;
  }

  try {
    if (!fits(floor)) return floor;
    int lo = (floor * 2).ceil();
    int hi = (ceiling * 2).floor();
    if (lo >= hi || !fits(lo / 2)) return floor;
    if (fits(hi / 2)) return hi / 2;
    // Invariant: lo/2 fits, hi/2 does not.
    while (hi - lo > 1) {
      final int mid = (lo + hi) ~/ 2;
      if (fits(mid / 2)) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return math.max(floor, lo / 2);
  } finally {
    painter.dispose();
  }
}
