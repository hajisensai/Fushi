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
