import 'dart:math' as math;

import 'package:flutter/rendering.dart';

/// Positions the non-modal selection action bar next to the selected text while
/// keeping it clear of the two grip hit boxes.
///
/// 锚点是**选区正文**（[selectionRect] = 选区首字的 rect，与原实现同源）：正常情况面板
/// 贴在选区首行上方一格 [gap]。手柄触控盒（[gripBoxes]）只是**要避开的障碍**，不再当作
/// 锚点 —— 把它当锚点会两头错：
///   - 横排时两球挂在字**下方**，并集的 `top` 落在正文里面，"放在并集上方"算出来就是
///     压在选区首行上；
///   - 竖排时起点球在字**上方**，页顶选区的"上方"永远放不下，于是翻到并集**底端**（末字
///     手柄下方），面板从选区头部掉到选区尾部下方（用户报「面板往下了」）。
///
/// 障碍必须**按单个球**算（[gripBoxes] 而不是并集）：两个球在竖排长选区里可以离得很远，
/// 用它们的外接矩形会让中间那一大片正文空白也变成障碍，面板于是被挤到 bbox 之外。
///
/// 保留本轮既有改进：子元件先测量（不用假定 48px 高度）；两个矩形在调用方经真实缩放链换
/// 成 Overlay 画布坐标，本类只做纯几何。
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

  /// 两端手柄 32px 触控盒（已映射，顺序无关）；空 = 没有手柄信息。
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

    bool fits(double top) => top >= minTop && top <= maxTop;
    // 面板既不能压住选区正文，也不能盖住任一手柄盒（两边都留一格 gap）。
    bool blocked(double top) {
      final Rect bar = Rect.fromLTWH(
        left,
        top,
        childSize.width,
        childSize.height,
      );
      if (bar.overlaps(selectionRect.inflate(gap))) return true;
      for (final Rect box in gripBoxes) {
        if (!box.isEmpty && bar.overlaps(box.inflate(gap))) return true;
      }
      return false;
    }

    // 1) 原实现的位置：选区首行上方一格 gap。
    double top = selectionRect.top - gap - childSize.height;
    bool placed = fits(top) && !blocked(top);
    // 2) 被手柄盒挡住：让到**最靠上那个**手柄盒上方 —— 仍贴着选区头部，不换边、不压字。
    if (!placed && gripBoxes.isNotEmpty) {
      double topmost = gripBoxes.first.top;
      for (final Rect box in gripBoxes) {
        topmost = math.min(topmost, box.top);
      }
      final double aboveGrips = topmost - gap - childSize.height;
      if (fits(aboveGrips) && !blocked(aboveGrips)) {
        top = aboveGrips;
        placed = true;
      }
    }
    // 3) 上方确实没有空间（页顶选区）：落到选区正文下方 + 手柄预留。基准是**正文底**，
    //    不是手柄盒底 —— 后者会把面板推到选区尾部。只有真与某个球相撞才让开。
    if (!placed) {
      top = selectionRect.bottom + handleReserve;
      if (blocked(top) && gripBoxes.isNotEmpty) {
        double lowest = gripBoxes.first.bottom;
        for (final Rect box in gripBoxes) {
          lowest = math.max(lowest, box.bottom);
        }
        top = lowest + gap;
      }
    }
    // 视口边缘只夹紧，绝不靠"翻到另一边"来逃避。
    top = top.clamp(minTop, maxTop);
    return Offset(left, top);
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
