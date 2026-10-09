import 'dart:math' as math;

import 'package:flutter/rendering.dart';

/// Positions the non-modal selection action bar next to the selected text while
/// keeping it clear of the two grip hit boxes.
///
/// 锚点是**选区正文**（[selectionRect] = 选区首字的 rect，与原实现同源）：首选位置是选区首行
/// 上方一格 [gap]。手柄触控盒（[gripBoxes]）是**要避开的障碍**，但**不参与定锚**，而且：
///   - 用两球的并集 bbox 当锚点：横排时并集 `top` 落在正文里（面板被算到正文上），竖排页顶
///     放不下时会翻到并集**底端**（末字球下方）—— 面板从选区头部掉到选区尾部下方；
///   - 用**所有球的全局 top/bottom** 判断"上方/下方"同样错：竖排跨列时（起点在右列中部、
///     终点在下一列顶部）两球的 y 顺序与选区起止顺序**相反**，末端球贴页顶就会被误判成
///     "选区头部上方没空间"，于是白白翻到下方。
///
/// 因此这里按**逐个球**的上下边界生成候选，选"合法（在视口内、且不与正文/任一球相交）"
/// 中离首选位置最近的那个；最后再对最终位置复验一次碰撞。只有当候选里**确实没有**合法
/// 位置时才显式降级到碰撞面积最小的候选 —— `clamp` 只用于把结果收进视口，绝不当作
/// "不撞障碍"的保证。
class ReaderSelectionToolbarLayout extends SingleChildLayoutDelegate {
  const ReaderSelectionToolbarLayout({
    required this.selectionRect,
    this.gripBoxes = const <Rect>[],
    this.safeInsets = EdgeInsets.zero,
    this.gap = 8,
    this.handleReserve = 40,
  });

  /// 选区正文锚点（选区首字 rect，已映射到 Overlay 画布空间）。
  final Rect selectionRect;

  /// 两端手柄 32px 触控盒（已映射；顺序无关，与选区起止顺序**无必然对应**）。
  final List<Rect> gripBoxes;

  final EdgeInsets safeInsets;
  final double gap;

  /// 面板落到选区下方时要为手柄留出的高度（32px 触控盒 + gap，与原实现一致）。
  final double handleReserve;

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
    final double left = safeInsets.left + gap;
    final double minTop = safeInsets.top + gap;
    final double maxTop = math.max(
      minTop,
      size.height - safeInsets.bottom - gap - childSize.height,
    );
    // 首选位置 = 原实现：选区首行上方一格 gap。
    final double preferred = selectionRect.top - gap - childSize.height;

    bool fits(double top) => top >= minTop && top <= maxTop;

    /// 面板与正文 / 任一手柄盒的相交总面积（两边都留一格 [gap] 才算不相交）。
    double overlapArea(double top) {
      final Rect bar = Rect.fromLTWH(
        left,
        top,
        childSize.width,
        childSize.height,
      );
      double area = _intersectionArea(bar, selectionRect.inflate(gap));
      for (final Rect box in gripBoxes) {
        if (box.isEmpty) continue;
        area += _intersectionArea(bar, box.inflate(gap));
      }
      return area;
    }

    // 候选 = 首选位置 + **每个球各自的**上下边 + 正文下方 + 视口两端（矮视口只剩边缘空隙时）。
    // 刻意不取所有球的全局 min/max：那正是跨列竖排被误判的来源。
    final List<double> candidates = <double>[preferred];
    for (final Rect box in gripBoxes) {
      if (box.isEmpty) continue;
      candidates.add(box.top - gap - childSize.height);
      candidates.add(box.bottom + gap);
    }
    candidates
      ..add(selectionRect.bottom + handleReserve)
      ..add(minTop)
      ..add(maxTop);

    // 1) 合法候选里取离首选位置最近的 —— 保证"只要存在无碰撞位置就不会压到字或球"。
    double? best;
    double bestDistance = double.infinity;
    for (final double candidate in candidates) {
      if (!fits(candidate)) continue;
      if (overlapArea(candidate) > 0) continue;
      final double distance = (candidate - preferred).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        best = candidate;
      }
    }
    if (best != null) return Offset(left, best);

    // 2) 一个合法位置都没有（障碍铺满可用区间，或视口比工具条还矮）：显式降级 ——
    //    先按碰撞面积、再按离首选位置的距离挑，最后才 clamp 进视口。
    double degraded = preferred.clamp(minTop, maxTop);
    double worstScore = double.infinity;
    for (final double candidate in candidates) {
      final double clamped = candidate.clamp(minTop, maxTop);
      final double score =
          overlapArea(clamped) + (clamped - preferred).abs() * 0.001;
      if (score < worstScore) {
        worstScore = score;
        degraded = clamped;
      }
    }
    return Offset(left, degraded);
  }

  static double _intersectionArea(Rect a, Rect b) {
    final double w = math.min(a.right, b.right) - math.max(a.left, b.left);
    final double h = math.min(a.bottom, b.bottom) - math.max(a.top, b.top);
    return (w > 0 && h > 0) ? w * h : 0;
  }

  @override
  bool shouldRelayout(ReaderSelectionToolbarLayout oldDelegate) =>
      selectionRect != oldDelegate.selectionRect ||
      !_sameBoxes(gripBoxes, oldDelegate.gripBoxes) ||
      safeInsets != oldDelegate.safeInsets ||
      gap != oldDelegate.gap ||
      handleReserve != oldDelegate.handleReserve;

  static bool _sameBoxes(List<Rect> a, List<Rect> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
