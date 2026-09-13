import 'package:flutter/material.dart';
import 'package:fushi/src/focus/focus_geometry.dart';
import 'package:fushi/src/focus/page_scroll_registry.dart';

class FushiFocusScroll {
  const FushiFocusScroll._();

  /// [alignment] 默认居中（0.5）。目录/章节这类「打开即定位」的场景常要偏上
  /// 一点（0.3），让当前行下面还能看见后续几行——给个参数，免得调用方为这一个
  /// 旋钮自己去写裸 `Scrollable.ensureVisible`（守卫
  /// focus_architecture_static_test 要求焦点驱动滚动只有这一个实现者）。
  static void ensureVisible(
    BuildContext context, {
    Duration duration = const Duration(milliseconds: 120),
    double alignment = 0.5,
  }) {
    if (!context.mounted) return;
    final ScrollableState? scrollable = Scrollable.maybeOf(context);
    if (scrollable == null) return;
    Scrollable.ensureVisible(
      context,
      alignment: alignment,
      duration: duration,
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
    return scrollPositionByViewportFraction(position, signedFraction);
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
    return scrollPositionByViewportFraction(
        controller.position, signedFraction);
  }

  /// 把一个已附着的 [position] 按 viewport 的 [signedFraction] 比例滚动一段。
  ///
  /// [scrollByViewportFraction] / [scrollController] / 页面级滚动动作最终都落到
  /// 这里：一份 clamp + 「已到边界返回 false」判据，三条入口不再各抄一遍。
  static bool scrollPositionByViewportFraction(
    ScrollPosition position,
    double signedFraction,
  ) {
    if (!position.hasPixels || !position.hasContentDimensions) return false;
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

  /// 把 [position] 滚到顶（[toEnd] 为 false）或滚到底（true）。已在该端返回 false。
  ///
  /// 懒构建列表的 `maxScrollExtent` 只是估计值，一次 End 未必真到最底——那是列表
  /// 自身的性质，用户再按一次即可，这里不做「循环追到底」的花活。
  static bool scrollPositionToEdge(ScrollPosition position,
      {required bool toEnd}) {
    if (!position.hasPixels || !position.hasContentDimensions) return false;
    final double target =
        toEnd ? position.maxScrollExtent : position.minScrollExtent;
    if ((target - position.pixels).abs() < 0.5) return false;
    position.animateTo(
      target,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
    );
    return true;
  }

  /// [position] 还能不能朝 [towardEnd] 指定的方向再滚动一点。
  static bool canScrollToward(ScrollPosition position,
      {required bool towardEnd}) {
    if (!position.hasPixels || !position.hasContentDimensions) return false;
    return towardEnd
        ? position.pixels < position.maxScrollExtent - 0.5
        : position.pixels > position.minScrollExtent + 0.5;
  }

  /// [position] 所在的滚动视图此刻是否真的呈现给用户：属于**当前**路由，且祖先
  /// 里没有藏起它的 `Offstage(offstage: true)` / 不可见的 [Visibility]。
  ///
  /// [PageScrollRegistry] 是一个栈：书架页登记的控制器在阅读器 / 对话框压上来之后
  /// 仍是栈顶且仍有 position（页面被 maintainState 保活）。不查路由就会把 Home/End
  /// 打到被盖住的页面上——用户看不见任何变化，却把书架偷偷滚走了。同理，
  /// `MediaLibraryShell` 对各视图「惰性构建 + Offstage 保活」：漫画库进过一次
  /// 「发现」再切回「书架」，栈顶仍是发现页（FushiPageScaffold）的控制器，不查
  /// Offstage 就会把可见书架晾着、去滚看不见的发现页。无路由（widget 测试直接
  /// pump 的宿主）视为当前。
  static bool _positionIsPresented(ScrollPosition position) {
    final BuildContext? context = position.context.notificationContext;
    if (context == null || !context.mounted) return false;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    bool hidden = false;
    context.visitAncestorElements((Element ancestor) {
      if (_hidesSubtree(ancestor.widget)) {
        hidden = true;
        return false;
      }
      return true;
    });
    return !hidden;
  }

  /// [widget] 是否把整棵子树藏起来了：`Offstage(offstage: true)`，或不可见的
  /// [Visibility]（它的 maintainSize 形态仍有几何，光看 Offstage 抓不到；而
  /// [IndexedStack] 的非当前 child 正是用它包的——SDK 里 IndexedStack 只是把每个
  /// child 裹一层 `Visibility(visible: i == index, maintainState/Size: true)`，
  /// 所以不需要也不能对 IndexedStack 自己做「按 index 挑子元素」的特例）。
  static bool _hidesSubtree(Widget widget) =>
      (widget is Offstage && widget.offstage) ||
      (widget is Visibility && !widget.visible);

  /// [canScrollToward] 且真的呈现在用户面前——阶梯前三级的统一准入。
  static bool _eligible(ScrollPosition position, {required bool towardEnd}) =>
      canScrollToward(position, towardEnd: towardEnd) &&
      _positionIsPresented(position);

  /// 解析「当前页面该被键盘 / 手柄 / 鼠标滚动动作滚的那个 ScrollPosition」。
  ///
  /// 这是全 app 页面级滚动动作（global scope 六件套：整屏 / 单步 / 到顶到底）的
  /// **唯一**目标解析器，四级阶梯，取第一个**仍能朝 [towardEnd] 方向滚**的：
  ///
  ///   1. [focusContext] 最近的**纵向** Scrollable —— 焦点在某个列表里时先滚它
  ///      （列表已到边缘时自然落到下一级，这就是「列表边缘接管」）；
  ///   2. [PageScrollRegistry.current] —— 页面主动登记过的主滚动区；
  ///   3. [focusContext] 的 [PrimaryScrollController] —— `primary: true` 的滚动视图；
  ///   4. **零登记兜底**：从 [navigator] 当前可见路由的子树里按 element 树顺序找
  ///      第一个纵向 Scrollable。跳过非当前路由（被整页 / 对话框盖住的页面不能被
  ///      滚）、`Offstage`（首页各 tab 靠它隐藏未选中者）、不可见的 `Visibility`
  ///      （[IndexedStack] 用它包非当前 child），并要求 viewport 真的与 Navigator
  ///      可见区域相交（排除 [PageView] / [TabBarView] 里已布局但滑到屏幕外的
  ///      相邻页）。
  ///
  /// 前三级是 2026-05 手柄 LB/RB 翻屏就有的路径；第 4 级是本次新增的兜底——
  /// 全仓只有 9 个页面登记 [PageScrollRegistry]，而桌面端的 ListView 默认**不**挂
  /// PrimaryScrollController（`PrimaryScrollController.shouldInherit` 只在移动端为
  /// 真），于是绝大多数页面此前对键盘滚动完全不可达。宁可每次按键做一遍 element
  /// 树遍历（一次按键、几千个 element、亚毫秒级），也不逐页手加登记。
  ///
  /// 找不到任何能滚的返回 null，调用方应放行按键（ignored）让更外层 / 框架接手。
  static ScrollPosition? resolveActivePageScrollable({
    required bool towardEnd,
    BuildContext? focusContext,
    NavigatorState? navigator,
  }) {
    if (focusContext != null && focusContext.mounted) {
      final ScrollableState? nearest =
          Scrollable.maybeOf(focusContext, axis: Axis.vertical);
      if (nearest != null &&
          _eligible(nearest.position, towardEnd: towardEnd)) {
        return nearest.position;
      }
    }
    final ScrollController? registered = PageScrollRegistry.current;
    if (registered != null &&
        _eligible(registered.position, towardEnd: towardEnd)) {
      return registered.position;
    }
    if (focusContext != null && focusContext.mounted) {
      final ScrollController? primary =
          PrimaryScrollController.maybeOf(focusContext);
      if (primary != null &&
          primary.positions.length == 1 &&
          _eligible(primary.position, towardEnd: towardEnd)) {
        return primary.position;
      }
    }
    if (navigator != null && navigator.mounted) {
      return _firstScrollableInCurrentRoute(navigator, towardEnd: towardEnd);
    }
    return null;
  }

  /// 第 4 级兜底的 element 树遍历，见 [resolveActivePageScrollable]。
  static ScrollPosition? _firstScrollableInCurrentRoute(
    NavigatorState navigator, {
    required bool towardEnd,
  }) {
    final Rect? stage = globalRectOfContext(navigator.context);
    if (stage == null) return null;
    ScrollPosition? found;

    void visit(Element element) {
      if (found != null) return;
      final Widget widget = element.widget;
      if (_hidesSubtree(widget)) return;
      if (widget is FocusScope) {
        // 每个 ModalRoute 的子树根部都是它自己的 FocusScope；非当前路由（被整页
        // 或对话框盖住）整棵剪掉——盖在下面的页面不能被滚。页面内部自己包的
        // FocusScope 解析到的仍是当前路由，照常下钻。
        final ModalRoute<dynamic>? route = ModalRoute.of(element);
        if (route != null && !route.isCurrent) return;
      }
      if (element is StatefulElement && element.state is ScrollableState) {
        final ScrollableState scrollable = element.state as ScrollableState;
        final ScrollPosition position = scrollable.position;
        if (position.axis == Axis.vertical &&
            canScrollToward(position, towardEnd: towardEnd) &&
            _viewportIsOnStage(scrollable.context, stage)) {
          found = position;
          return;
        }
        // 外层滚不动（NestedScrollView 头已收起 / 空壳容器）就继续往里找。
      }
      element.visitChildren(visit);
    }

    navigator.context.visitChildElements(visit);
    return found;
  }

  /// 滚动视图的 viewport 与 [stage]（Navigator 可见区域）有实际相交面积。
  static bool _viewportIsOnStage(BuildContext context, Rect stage) {
    final Rect? rect = globalRectOfContext(context);
    if (rect == null) return false;
    final Rect overlap = rect.intersect(stage);
    return overlap.width > 1 && overlap.height > 1;
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
