import 'package:flutter/material.dart';
import 'package:hibiki/src/focus/focus_geometry.dart';

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

    // ON-SCREEN rects (both corners mapped) so the visibility test holds under
    // the app UI-scale Transform: `localToGlobal(Offset.zero) & size` would
    // under-measure each box's extent by the scale factor. See focus_geometry.
    final Rect widgetRect = globalRectOfBox(renderObject);
    final Rect viewportRect = globalRectOfBox(viewport);
    const double tolerance = 0.5;
    final bool fullyVisible = widgetRect.top >= viewportRect.top - tolerance &&
        widgetRect.bottom <= viewportRect.bottom + tolerance &&
        widgetRect.left >= viewportRect.left - tolerance &&
        widgetRect.right <= viewportRect.right + tolerance;
    if (fullyVisible) return;

    ensureVisible(context);
  }

  /// 把 [context] 最近的可滚动祖先按 viewport 的 [signedFraction] 比例滚动一段。
  ///
  /// 这是手柄"独立滚动通道"的唯一实现：D-pad 走到列表边缘（无几何焦点目标）时
  /// 接管滚动，与"焦点切换的 reveal 副作用"解耦。命中且仍能滚返回 true；
  /// 无 Scrollable 祖先 / 已到边界 / [wantAxis] 与滚动轴不匹配时返回 false。
  static bool scrollByViewportFraction(
    BuildContext context,
    AxisDirection? wantAxis,
    double signedFraction,
  ) {
    if (!context.mounted) return false;
    final ScrollableState? scrollable = Scrollable.maybeOf(context);
    if (scrollable == null) return false;
    final ScrollPosition position = scrollable.position;
    if (wantAxis != null && axisDirectionToAxis(wantAxis) != position.axis) {
      return false;
    }
    final double target =
        (position.pixels + position.viewportDimension * signedFraction)
            .clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((target - position.pixels).abs() < 0.5) return false;
    position.animateTo(
      target,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOutCubic,
    );
    return true;
  }

  /// 把 [context] 最近的 [PrimaryScrollController] 滚动 viewport 的
  /// [signedFraction] 比例。用于手柄 LB/RB 整页翻屏——纯展示零焦点页（统计/日志）
  /// 没有焦点几何目标，只能靠页面主滚动区翻屏。命中且仍能滚返回 true；无
  /// PrimaryScrollController / 无 client / 已到边界返回 false。
  static bool scrollPrimary(BuildContext context, double signedFraction) {
    final ScrollController? controller =
        PrimaryScrollController.maybeOf(context);
    if (controller == null) return false;
    return scrollController(controller, signedFraction);
  }

  /// Page a [controller] by the viewport [signedFraction]. Used by the gamepad
  /// LB/RB fallback via PageScrollRegistry so it works even when focus is the
  /// top-level fallback node (which has no PrimaryScrollController ancestor).
  /// Exactly one attached position required: 0 = nothing to scroll; >1 =
  /// ambiguous and `.position` would throw.
  static bool scrollController(
    ScrollController controller,
    double signedFraction,
  ) {
    if (controller.positions.length != 1) return false;
    final ScrollPosition position = controller.position;
    final double target =
        (position.pixels + position.viewportDimension * signedFraction)
            .clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((target - position.pixels).abs() < 0.5) return false;
    controller.animateTo(
      target,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOutCubic,
    );
    return true;
  }

  /// 方向 → viewport 比例正负号：down/right 为正（向后/下滚），up/left 为负。
  static double signedFractionFor(
      TraversalDirection direction, double fraction) {
    switch (direction) {
      case TraversalDirection.down:
      case TraversalDirection.right:
        return fraction;
      case TraversalDirection.up:
      case TraversalDirection.left:
        return -fraction;
    }
  }
}
