import 'dart:math' as math;

import 'package:flutter/rendering.dart';

/// Positions the non-modal action bar outside both selection grip hit targets.
/// The child is measured first: translated/scaled glyphs and large-text bars
/// must not rely on a fixed 48px height or a guessed writing-mode offset.
class ReaderSelectionToolbarLayout extends SingleChildLayoutDelegate {
  const ReaderSelectionToolbarLayout({
    required this.protectedRect,
    this.safeInsets = EdgeInsets.zero,
    this.gap = 8,
  });

  final Rect protectedRect;
  final EdgeInsets safeInsets;
  final double gap;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final double width = math.max(
      0,
      constraints.maxWidth - safeInsets.horizontal - 2 * gap,
    );
    // Unbounded child height preserves the toolbar's existing shrink-wrap
    // contract; the LayoutBuilder/Align must not fill the whole overlay.
    return BoxConstraints(minWidth: width, maxWidth: width);
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final double minTop = safeInsets.top + gap;
    final double maxTop = math.max(
      minTop,
      size.height - safeInsets.bottom - gap - childSize.height,
    );
    final double above = protectedRect.top - gap - childSize.height;
    final double below = protectedRect.bottom + gap;
    double top;
    if (above >= minTop && above <= maxTop) {
      top = above;
    } else if (below >= minTop && below <= maxTop) {
      top = below;
    } else {
      // An edge-clipped selection or a full-height range can leave neither
      // side large enough. Choose the edge with the smaller overlap; do not
      // blindly clamp the upper candidate across the start grip.
      double overlap(double candidate) => math.max(
        0,
        math.min(candidate + childSize.height, protectedRect.bottom + gap) -
            math.max(candidate, protectedRect.top - gap),
      );
      top = overlap(minTop) <= overlap(maxTop) ? minTop : maxTop;
    }
    return Offset(safeInsets.left + gap, top);
  }

  @override
  bool shouldRelayout(ReaderSelectionToolbarLayout oldDelegate) =>
      protectedRect != oldDelegate.protectedRect ||
      safeInsets != oldDelegate.safeInsets ||
      gap != oldDelegate.gap;
}
