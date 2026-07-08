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

/// TODO-893 — 选出喂给 [computeFrameRect] 的「屏幕一维尺寸」(CSS px)。
///
/// 这是 symptom-2（嵌套子弹窗把父卡片顶出窗口顶部）修复的**接线真值**：
/// `_renderStack` 必须把**真实显示器工作区** [workDim] 喂给 [computeFrameRect]
/// 的 screenWidth/screenHeight，而**不是**离屏测量画布 [boundsDim]
/// (`_layoutBounds*`，仅约卡片 ~2×)。用测量画布时 spaceBelow 几乎恒 < height →
/// showBelow false → 每个子弹窗都向上级联，host 的 bbox-shift 再把整窗（含根卡片）
/// 上移，根卡片被顶出顶部。
///
/// 选择规则：工作区有效（native 报到 > 0）就用工作区；否则（native 未报 / 查询失败）
/// 退回测量画布；测量画布也无效时退回单卡片尺寸 [cardDim]（最末兜底）。
///
/// 纯函数（无 IO / 无平台 / 无状态），便于对「工作区优先」这条回归锁单测断言：
/// 一旦有人把实参改回 [boundsDim]，针对 workDim != boundsDim 的用例即转红。
double pickScreenDim(double workDim, double boundsDim, double cardDim) {
  if (workDim > 0) {
    return workDim;
  }
  if (boundsDim > 0) {
    return boundsDim;
  }
  return cardDim;
}

/// TODO-1231（BUG-583）——覆盖窗「原点棘轮」结果（CSS / 逻辑像素域，**不含 dpr**）。
///
/// [left]/[top] 是本次应用的窗口最小角（棘轮后：只向外移，绝不回内）；[width]/[height]
/// 是从该最小角覆盖到真实内容右下极值（maxRight/maxBottom）所需的窗口尺寸。
class RatchetedOverlayBox {
  const RatchetedOverlayBox({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  /// 棘轮后的窗口左上角 X（CSS px）。
  final double left;

  /// 棘轮后的窗口左上角 Y（CSS px）。
  final double top;

  /// 窗口宽度（CSS px，= maxRight - left）。
  final double width;

  /// 窗口高度（CSS px，= maxBottom - top）。
  final double height;

  @override
  bool operator ==(Object other) =>
      other is RatchetedOverlayBox &&
      other.left == left &&
      other.top == top &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(left, top, width, height);

  @override
  String toString() => 'RatchetedOverlayBox(left: $left, top: $top, '
      'width: $width, height: $height)';
}

/// TODO-1231（BUG-583）——覆盖窗最小角「只向外、不回内」棘轮（纯函数，CSS px，**不乘 dpr**）。
///
/// 症状根因：嵌套子弹窗向左/上级联时窗口最小角（bbox 原点）变负、根卡片靠 host 的
/// `commitLayerShift` 反向平移钉在光标处；子弹窗**消失**时窗口最小角要从负值回到 0，窗口
/// 先 `SetWindowPos` 移回、host 的补偿平移经 `ExecuteScript` 慢约 1 帧才跟上（跨 DWM /
/// WebView2 边界不可同帧原子提交），根卡片先跳后弹 =「消失第二个弹窗时闪」。把最小角**棘轮**
/// 成「本次会话见过的最外值」后，关子弹窗时窗口左上角与图层平移都不动，只有右下（远端）边收缩，
/// 根卡片零位移 → 关闭不闪。向右/下级联恒为 (0,0)，棘轮是 no-op，与旧行为逐字节一致。
///
/// - [left]/[top]/[width]/[height]：本帧 host 上报的**紧致** union bbox（CSS px）。
/// - [prevLeft]/[prevTop]：本会话此前已棘轮的最小角（`double.infinity` = 尚无约束，取本帧值）。
///
/// 返回的宽高按棘轮后的最小角到真实内容右下极值（maxRight = left + width，
/// maxBottom = top + height）重算，保证窗口仍覆盖真实内容，同时最小角绝不回内。
RatchetedOverlayBox ratchetOverlayOrigin({
  required double left,
  required double top,
  required double width,
  required double height,
  required double prevLeft,
  required double prevTop,
}) {
  final double maxRight = left + width;
  final double maxBottom = top + height;
  final double originLeft = left < prevLeft ? left : prevLeft;
  final double originTop = top < prevTop ? top : prevTop;
  return RatchetedOverlayBox(
    left: originLeft,
    top: originTop,
    width: maxRight - originLeft,
    height: maxBottom - originTop,
  );
}

/// TODO-1345（BUG-583 深层根因续）—— 覆盖窗「级联余量地板」纯函数（CSS px·不含 dpr）。
///
/// 返回 union bbox 最小角（origin）应预留到的**内侧余量地板**（`left`/`top` 均 <= 0）。
/// [GlobalLookupController] 在**根卡首次 reveal**把它经 renderStack payload 推给 host；
/// `global_lookup_host.js` `measureAndReport` 把 origin 外拉到至少这个地板 → 窗口首帧就
/// 覆盖后续**向左/上级联子卡**将占据的位置 → 子卡落地时 origin 已覆盖它，**绝不再移动
/// 窗口原点** → 无 `SetWindowPos` + `commitLayerShift` 的跨 DWM/WebView2 边界补偿 →
/// 钉住的父卡在子卡出现时**零位移**。BUG-583 前 4 轮只能把这次 origin 外移**掩盖**到与
/// 子卡出现同帧（那 1 帧父卡跳动仍被用户看见）；本地板把它从根上**消除**，把前 4 轮对
/// 向右/下级联达成的「origin 恒定、父卡零位移」扩展到向左/上。
///
/// 余量只朝**屏幕内侧**留（向左 / 向上），且被**双重夹紧**——绝不把窗口顶出屏幕左/上边
/// （否则 C++ `RevealStack` 的工作区 clamp 会把窗口原点移回内侧、而 `commitLayerShift`
/// 用的却是未 clamp 值 → 反而重引父卡位移）：
///   headroom = min(card, 光标到该侧边距离, 工作区维度 - card)，再取负。
/// 光标靠左/上边时该侧距离趋 0 → 余量趋 0（那侧本就不会向左/上级联·退化为修前几何·
/// Never break userspace）。向右/下级联恒不需要向左/上余量·地板对其为 no-op（保持 0）。
///
/// 纯函数（无 IO / 无平台 / 无状态 / 无 dpr），便于对「余量朝内侧且夹在屏内」单测锁定。
({double left, double top}) computeCascadeHeadroomSeed({
  required double cursorWorkX,
  required double cursorWorkY,
  required double screenWorkW,
  required double screenWorkH,
  required double cardW,
  required double cardH,
}) {
  return (
    left: -_cascadeHeadroom(cursorWorkX, screenWorkW, cardW),
    top: -_cascadeHeadroom(cursorWorkY, screenWorkH, cardH),
  );
}

/// 单轴级联余量幅度（>= 0·CSS px）。见 [computeCascadeHeadroomSeed] 的双重夹紧规则。
double _cascadeHeadroom(double cursorWork, double screenWork, double card) {
  if (cursorWork <= 0 || screenWork <= 0 || card <= 0) {
    return 0;
  }
  // 想留满一张卡的余量（单层向左/上级联子卡最远可达 ~1 张卡）。
  double headroom = card;
  // 夹紧①：不超过光标到该侧边的距离（否则窗口顶出屏幕该侧边）。
  if (cursorWork < headroom) {
    headroom = cursorWork;
  }
  // 夹紧②：窗口总跨度（card + headroom）不超过工作区维度（小屏兜底·同样防顶出对侧边）。
  final double onScreenRoom = screenWork - card;
  if (onScreenRoom < headroom) {
    headroom = onScreenRoom;
  }
  return headroom > 0 ? headroom : 0;
}
