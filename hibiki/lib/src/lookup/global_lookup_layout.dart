// 全局查词「级联弹窗定位」纯逻辑（TODO-867 阶段3 地基 P3c-B2）。
//
// 移植自 hoshi Android 的 `LookupPopupLayout.kt`（级联弹窗几何算法）。本文件**只**
// 包含一个纯函数 [computeFrameRect] + 不可变结果 [GlobalLookupFrameRect]：无
// Riverpod / 无 IO / 无平台依赖 / 无随机 / 无时钟——给定选区锚点矩形 + 屏幕尺寸 +
// 弹窗最大宽高 + 横竖排，算出该层弹窗的最终矩形。
//
// 坐标域铁律（P3c 计划复核 #3）：本函数全程在 **CSS / 逻辑像素**域计算，**绝不乘
// dpr**。Hoshi 原算法是 unit-agnostic 逻辑像素（不含任何 density 因子），与 host.js
// shell 同域。dpr 转换是后续 C++ 窗口几何 / 鼠标钩子边界的职责，不属于本纯函数。
//
// 与 Hoshi 的语义对照（逐方法移植 `LookupPopupLayout.kt:23-95`）：
//   - width()  : 横排 = min(屏宽 - screenBorderPadding*2, maxWidth)；
//                竖排 = min(max(左空间, 右空间) - screenBorderPadding, maxWidth)。
//   - height() : 横排 = min(max(上空间, 下空间) - screenBorderPadding, maxHeight)；
//                竖排 = maxHeight（不按上下空间收缩）。
//   - centerX(): 横排 = clamp(选区中心X) 进 [w/2 + 边距, 屏宽 - w/2 - 边距]；
//                竖排 = 放选区左/右侧（showOnRight 决定），clamp 进 [w/2, 屏宽 - w/2]。
//   - centerY(): 横排 = 放选区上/下（showBelow 决定），clamp 进 [h/2 + 边距, 屏高 - h/2 - 边距]；
//                竖排 = clamp(选区中心Y) 进 [h/2 + 边距, 屏高 - h/2 - 边距]。
//   - clampLikeIos(v, lo, hi) = max(lo, min(v, hi))。
//
// 语义偏差说明：Hoshi 的 `isFullWidth` / `topInset` / `bottomInset` 参数本切片**不
// 移植**（本步只交付基础级联定位地基，inset 退化为 0、非 full-width），后续接线时
// 若需要 system inset 再在调用方/扩展参数补，避免本地基过度设计。其余分支逐行忠实
// 移植。本函数返回 left/top（由 center - 半宽/半高换算）而非 Hoshi 的 centerX/centerY，
// 因下游 host.js shell 用 left/top 定位。

import 'dart:ui' show Rect;

/// 单层查词弹窗的最终矩形（CSS / 逻辑像素域，与 host.js shell 同域，**不含 dpr**）。
///
/// [left]/[top] 是弹窗左上角屏幕坐标；[width]/[height] 是弹窗实际尺寸（已按屏幕空间
/// 与 maxWidth/maxHeight 收敛）。
class GlobalLookupFrameRect {
  const GlobalLookupFrameRect({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  /// 弹窗左上角 X（CSS px）。
  final double left;

  /// 弹窗左上角 Y（CSS px）。
  final double top;

  /// 弹窗宽度（CSS px）。
  final double width;

  /// 弹窗高度（CSS px）。
  final double height;

  /// 弹窗中心 X（便于与 Hoshi centerX 对照 / 调试）。
  double get centerX => left + width / 2;

  /// 弹窗中心 Y（便于与 Hoshi centerY 对照 / 调试）。
  double get centerY => top + height / 2;

  @override
  bool operator ==(Object other) {
    return other is GlobalLookupFrameRect &&
        other.left == left &&
        other.top == top &&
        other.width == width &&
        other.height == height;
  }

  @override
  int get hashCode => Object.hash(left, top, width, height);

  @override
  String toString() {
    return 'GlobalLookupFrameRect(left: $left, top: $top, width: $width, '
        'height: $height)';
  }
}

/// 移植 hoshi `LookupPopupLayout.calculate()`：算出单层查词弹窗的最终矩形。
///
/// 所有入参 / 出参均为 **CSS / 逻辑像素**（不乘 dpr）。
/// - [selectionRect]：被查词 / 选区在屏幕上的锚点矩形（CSS px）。
/// - [screenW] / [screenH]：可用屏幕尺寸（CSS px）。
/// - [maxWidth] / [maxHeight]：弹窗最大宽高（如 popupMaxWidth × appUiScale，**不乘 dpr**）。
/// - [isVertical]：竖排书（true 时弹窗放选区左 / 右，否则放上 / 下）。
/// - [popupPadding]：弹窗与选区之间的间距（Hoshi popupPadding = 4）。
/// - [screenBorderPadding]：弹窗中心 clamp 的屏幕边界留白（Hoshi screenBorderPadding = 6）。
///
/// 横排：弹窗放选区上 / 下，下方空间不足则翻转到上方；中心 X 取选区中心并 clamp 进屏内。
/// 竖排：弹窗放选区左 / 右（右侧空间够则优先右），高度恒为 maxHeight；中心 Y 取选区中心并 clamp。
GlobalLookupFrameRect computeFrameRect({
  required Rect selectionRect,
  required double screenW,
  required double screenH,
  required double maxWidth,
  required double maxHeight,
  required bool isVertical,
  double popupPadding = 4,
  double screenBorderPadding = 6,
}) {
  final double selX = selectionRect.left;
  final double selY = selectionRect.top;
  final double selW = selectionRect.width;
  final double selH = selectionRect.height;

  // 选区四向可用空间（Hoshi spaceLeft/spaceRight/spaceAbove/spaceBelow，inset = 0）。
  final double spaceLeft = selX - popupPadding;
  final double spaceRight = screenW - selX - selW - popupPadding;
  final double spaceAbove = selY - popupPadding;
  final double spaceBelow = screenH - selY - selH - popupPadding;

  // --- width()（Hoshi LookupPopupLayout.kt:34-38）---
  final double width = isVertical
      ? _min(_max(spaceLeft, spaceRight) - screenBorderPadding, maxWidth)
      : _min(screenW - screenBorderPadding * 2, maxWidth);

  // --- height()（Hoshi :40-43）：竖排恒 maxHeight，横排按上下空间收缩 ---
  final double height = isVertical
      ? maxHeight
      : _min(_max(spaceAbove, spaceBelow) - screenBorderPadding, maxHeight);

  // --- centerX()（Hoshi :45-57）---
  final double centerX;
  if (isVertical) {
    // showOnRight（Hoshi :85）：右空间 >= 左空间，或右空间 >= maxWidth。
    final bool showOnRight = spaceRight >= spaceLeft || spaceRight >= maxWidth;
    final double rawX = showOnRight
        ? selX + selW + popupPadding + width / 2
        : selX - popupPadding - width / 2;
    centerX = _clampLikeIos(rawX, width / 2, screenW - width / 2);
  } else {
    final double rawX = selX + width / 2;
    centerX = _clampLikeIos(
      rawX,
      width / 2 + screenBorderPadding,
      screenW - width / 2 - screenBorderPadding,
    );
  }

  // --- centerY()（Hoshi :59-79）---
  final double centerY;
  if (isVertical) {
    final double rawY = selY + height / 2;
    centerY = _clampLikeIos(
      rawY,
      height / 2 + screenBorderPadding,
      screenH - height / 2 - screenBorderPadding,
    );
  } else {
    // showBelow（Hoshi :86）：下空间 >= 弹窗高则放下方，否则翻到上方。
    final bool showBelow = spaceBelow >= height;
    final double rawY = showBelow
        ? selY + selH + popupPadding + height / 2
        : selY - popupPadding - height / 2;
    centerY = _clampLikeIos(
      rawY,
      height / 2 + screenBorderPadding,
      screenH - height / 2 - screenBorderPadding,
    );
  }

  return GlobalLookupFrameRect(
    left: centerX - width / 2,
    top: centerY - height / 2,
    width: width,
    height: height,
  );
}

/// Hoshi `clampLikeIos(value, minimum, maximum) = max(minimum, min(value, maximum))`。
///
/// 注意是「先 min 后 max」的 iOS 式 clamp：当 minimum > maximum（弹窗比可用空间还大）时，
/// 结果落在 minimum，而非标准 clamp 的未定义行为——忠实保留 Hoshi 语义。
double _clampLikeIos(double value, double minimum, double maximum) {
  return _max(minimum, _min(value, maximum));
}

double _min(double a, double b) => a < b ? a : b;

double _max(double a, double b) => a > b ? a : b;
