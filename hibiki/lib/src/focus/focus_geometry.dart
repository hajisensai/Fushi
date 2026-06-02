import 'package:flutter/widgets.dart';

/// A render box's bounds in GLOBAL (view) coordinates, accounting for any
/// scale/translation between the box and the view — notably HibikiAppUiScale's
/// app-level `Transform.scale` (the "界面大小" browser-style zoom).
///
/// It maps BOTH corners through [RenderBox.localToGlobal] so the rect carries
/// the control's ON-SCREEN size. The tempting `box.localToGlobal(Offset.zero) &
/// box.size` is WRONG under a non-identity scale: `localToGlobal` scales the
/// top-left, but `box.size` is the box's un-transformed LOCAL size, so the rect
/// pairs a scaled position with an unscaled size. That single mistake (shared by
/// the focus ring, directional-nav geometry, and the ensure-visible check)
/// shrank the focus ring on zoom-in and skewed nav between differently-sized
/// controls. At scale 1.0 (no transform) this equals `topLeft & size` exactly,
/// so default behaviour is unchanged.
///
/// Assumes no rotation between the box and the view — true for the app's single
/// axis-aligned `Transform.scale`. With rotation, `Rect.fromPoints` of two
/// opposite corners would not be the true bounding box.
Rect globalRectOfBox(RenderBox box) => Rect.fromPoints(
      box.localToGlobal(Offset.zero),
      box.localToGlobal(box.size.bottomRight(Offset.zero)),
    );

/// [globalRectOfBox] for the render object behind [context], or null when it has
/// no attached, laid-out [RenderBox] — an inactive/unmounted element, or a box
/// that has not been through layout. Guards `findRenderObject` so callers never
/// hit "Cannot get renderObject of inactive element" or a `localToGlobal`
/// assert on a detached box.
Rect? globalRectOfContext(BuildContext context) {
  if (!context.mounted) return null;
  final RenderObject? ro = context.findRenderObject();
  if (ro is! RenderBox || !ro.hasSize || !ro.attached) return null;
  return globalRectOfBox(ro);
}
