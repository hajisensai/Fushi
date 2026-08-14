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
/// - [fitHeightToAnchorSide]：横排时是否把卡高收进锚点较宽裕的一侧。根卡 / 游戏正文
///   卡保持 true；嵌套查词卡传 false，让卡片只在整个屏幕顶 / 底边界处收高，而不会被
///   父卡内的点击位置二次裁短。
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
  bool fitHeightToAnchorSide = true,
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
      : fitHeightToAnchorSide
          ? _min(_max(spaceAbove, spaceBelow) - screenBorderPadding, maxHeight)
          : _min(screenH - screenBorderPadding * 2, maxHeight);

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

/// TODO-1345（BUG-583 深层根因续 · TODO-1231/BUG-670 深层级联根治）—— 覆盖窗「级联
/// 余量地板」纯函数（CSS px·不含 dpr）。
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
/// TODO-1231（BUG-670）深层级联根治：预留幅度改为**光标到工作区该侧边缘的整段距离**
/// （reserve to the work-area edge），不再是 TODO-1345 的「一张卡」。因为
/// [computeFrameRect] 把**任意层级**的级联子卡（子 / 孙 / 曾孙…）都夹在工作区内（中心
/// clamp 进 `[w/2(+边距), screenW - w/2(-边距)]`），子卡最外边最远只能触到工作区该侧边。
/// 预留「一张卡」时，深层级联（孙卡·或高过一张卡的高卡）越过它 → origin 在该子卡
/// content-ready 那刻外移一次 → 跨 DWM/WebView2 补偿慢 ~1 帧 → 父卡残留 1 帧位移
/// （BUG-583 前几轮报告自陈的「深层级联罕见 1 帧残留」= 用户第六轮复诉）。预留**到边**
/// → origin 从首帧就覆盖所有层级的级联极值 → 任何深度的子卡落地都不再外移 origin →
/// 父卡**任意层级都零位移**。
///
/// 为何预留到边**安全**（不触发 C++ `RevealStack` 工作区 clamp 的失配）：地板把窗口原点
/// 恰好定在工作区该侧边（on-screen origin == `rcWork.left`/`top`），而这正是 C++ 左/上
/// clamp（`if (x < rcWork.left) x = rcWork.left`）的**目标值**——即便远端内容让窗口比屏
/// 还宽、C++ 先右/下再左/上双向 clamp，最终原点仍落在工作区边 == 本就意图值，故 origin
/// 与 `commitLayerShift` 用的 bbox 值一致，**绝无失配位移**。（反而是 TODO-1345 的
/// 「一张卡」地板在窗口过宽的退化场景才会失配：意图原点落在边内、C++ 却 clamp 到边 →
/// 差值即位移。）光标贴左/上边时该侧距离趋 0 → 余量趋 0（那侧本就不向左/上级联·退化为
/// 修前几何·Never break userspace）。
///
/// 纯函数（无 IO / 无平台 / 无状态 / 无 dpr），便于对「预留到边覆盖任意层级 + 夹在屏内」
/// 单测锁定。
({double left, double top}) computeCascadeHeadroomSeed({
  required double cursorWorkX,
  required double cursorWorkY,
  required double screenWorkW,
  required double screenWorkH,
}) {
  return (
    left: -_cascadeHeadroom(cursorWorkX, screenWorkW),
    top: -_cascadeHeadroom(cursorWorkY, screenWorkH),
  );
}

/// 单轴级联余量幅度（>= 0·CSS px）= 光标到工作区该侧边缘的整段距离（reserve to edge）。
/// 见 [computeCascadeHeadroomSeed] 的「预留到边即覆盖任意层级级联 + 恰落在 C++ clamp
/// 目标值故绝无失配」推导。TODO-1231（BUG-670）：由 TODO-1345 的「一张卡」改为整段。
double _cascadeHeadroom(double cursorWork, double screenWork) {
  if (cursorWork <= 0 || screenWork <= 0) {
    return 0;
  }
  // 预留到工作区该侧边：级联子卡（任意层级）最远只到该侧边，预留到边即全覆盖。
  double headroom = cursorWork;
  // 兜底夹紧：正常 cursorWork <= screenWork 恒成立（光标在工作区内）；防脏数据越界。
  if (headroom > screenWork) {
    headroom = screenWork;
  }
  return headroom > 0 ? headroom : 0;
}

/// TODO-1231（BUG-583/670 续·「弹窗生成在窗口外」）——根卡 shell 的窗口本地偏移
/// （CSS px·不含 dpr），把根卡整体钳进工作区。
///
/// 根因：根卡是整条级联里**唯一不经工作区 clamp 的卡**——级联子卡全部经
/// [computeFrameRect] 夹进工作区，而根卡恒被钉在 window-local (0,0)（= 光标 + 8 的
/// 屏幕位置）。历史上根卡的「进屏」由 C++ `Reveal`/`RevealStack` 的右/下边 clamp 滑动
/// **整个窗口**兜底；reserve-to-edge 地板（[computeCascadeHeadroomSeed]·BUG-670）把
/// 窗口原点钉死在工作区左上角、窗口尺寸夹到工作区大小之后，这两个 clamp 恒为 no-op
/// （正是该修复的「绝无失配」证明），根卡从此失去唯一的 fit-to-screen 机制：光标距
/// 右边缘 < 卡宽（或距底边 < 卡高）时，根卡越出工作区的部分被窗口右/下边（= 工作区
/// 边）整条裁掉——右下角极端情形几乎整卡不可见（「弹窗直接生成在窗口外面」）。
///
/// 修复 = 消除特殊情况：根卡与子卡同规则，在 Dart 布局域按**同一 iOS 式 clamp**
/// （[_clampLikeIos]，与 [computeFrameRect] 的中心 clamp 同语义）把根卡工作区位置
/// 夹进 `[0, screenWork - cardDim]`，返回相对光标锚点（= window-local 原点）的偏移：
///
///   offset = clampLikeIos(cursorWork, 0, screenWork - cardDim) - cursorWork
///
/// 性质（均有单测锁定）：
///   - 光标四周空间充足 → 偏移 (0,0)，逐字节等于修前几何（Never break userspace）。
///   - 靠右/下 → 偏移为负 = 恰好回退越界量，根卡贴边完整可见（与修前 C++ 窗口滑动
///     的落点一致）。
///   - offset >= -cursorWork 恒成立（clamp 下界 0）→ 根卡 window-local 位置恒 >=
///     reserve-to-edge 地板 → **窗口原点仍从首帧冻结**，BUG-670 的「父卡任意层级
///     零位移」保证不回退；根卡 local 为负时首帧走 v3 reveal-ready 门（held 到
///     commitLayerShift），不会先裁后跳。
///   - 卡比工作区还大（screenWork - cardDim < 0）→ clampLikeIos 落在下界 0 → 根卡
///     钉在工作区近边，远端裁切不可避免（屏幕物理极限）。
///   - [screenWork] <= 0（native 未上报工作区，cursorWork 同为 0）→ 偏移 0，退化为
///     修前几何。
///
/// 纯函数（无 IO / 无平台 / 无 dpr），Y 轴按卡**最大高**（cardH）悲观钳位——与
/// [computeFrameRect] 对子卡的悲观放置一致（内容实测高度是异步到达的，布局域只知上限）。
({double left, double top}) computeRootShellOffset({
  required double cursorWorkX,
  required double cursorWorkY,
  required double screenWorkW,
  required double screenWorkH,
  required double cardW,
  required double cardH,
}) {
  return (
    left: _rootShellAxisOffset(cursorWorkX, screenWorkW, cardW),
    top: _rootShellAxisOffset(cursorWorkY, screenWorkH, cardH),
  );
}

/// 单轴根卡偏移：把 `cursorWork`（根卡期望的工作区位置 = 光标+8）夹进
/// `[0, screenWork - cardDim]` 后与原位置作差。`screenWork <= 0` = 无工作区信息 →
/// 0（修前几何）。见 [computeRootShellOffset]。
double _rootShellAxisOffset(
    double cursorWork, double screenWork, double cardDim) {
  if (screenWork <= 0) {
    return 0;
  }
  return _clampLikeIos(cursorWork, 0, screenWork - cardDim) - cursorWork;
}
