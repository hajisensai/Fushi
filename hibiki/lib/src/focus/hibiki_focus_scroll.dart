import 'package:flutter/material.dart';

class HibikiFocusScroll {
  const HibikiFocusScroll._();

  static void ensureVisible(BuildContext context) {
    if (!context.mounted) return;
    final ScrollableState? scrollable = Scrollable.maybeOf(context);
    if (scrollable == null) return;
    Scrollable.ensureVisible(
      context,
      alignment: 0.5,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOutCubic,
    );
  }

  static void ensureVisibleIfHidden(BuildContext context) {
    if (!context.mounted) return;
    final RenderObject? renderObject = context.findRenderObject();
    if (renderObject is! RenderBox ||
        !renderObject.hasSize ||
        !renderObject.attached) {
      return;
    }
    final ScrollableState? scrollable = Scrollable.maybeOf(context);
    if (scrollable == null) return;
    final RenderObject? viewport = scrollable.context.findRenderObject();
    if (viewport is! RenderBox || !viewport.hasSize || !viewport.attached) {
      return;
    }

    final Rect widgetRect =
        renderObject.localToGlobal(Offset.zero) & renderObject.size;
    final Rect viewportRect =
        viewport.localToGlobal(Offset.zero) & viewport.size;
    const double tolerance = 0.5;
    final bool fullyVisible = widgetRect.top >= viewportRect.top - tolerance &&
        widgetRect.bottom <= viewportRect.bottom + tolerance &&
        widgetRect.left >= viewportRect.left - tolerance &&
        widgetRect.right <= viewportRect.right + tolerance;
    if (fullyVisible) return;

    ensureVisible(context);
  }
}
