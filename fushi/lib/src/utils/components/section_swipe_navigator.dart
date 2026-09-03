import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// 判定一次整页横滑成立的甩动速度下限（逻辑像素/秒）。
const double _kSwipeFlingVelocity = 300.0;

/// 低速拖拽也算数的最小累计横向位移（逻辑像素）。
const double _kSwipeDragDistance = 80.0;

/// 横滚行滚到边缘后继续拖、触发级联切区所需的出界深度（逻辑像素）。
const double _kCascadeOverscrollDistance = 56.0;

/// 库页分区的触屏横滑切换层。
///
/// 包在分区壳的保活栈（Offstage / IndexedStack）外面：手指横向甩动或长拖时按
/// [sections] 的 tab 视觉序切到相邻分区。方向遵循阅读方向——LTR 下向左划进右边
/// 的分区，RTL 自动反向。
///
/// 两条输入路径：
/// * **整页横滑**——本层的 HorizontalDrag recognizer。手势竞技场里子树的横向
///   滚动区（横滚行 / 页签条）先入场先赢，所以本层只接管落在纵向内容或空白处的
///   横滑，不抢行内滚动。
/// * **横滚行边缘级联**——被 [SectionSwipeCascade] 圈定的横向滚动区已滚到边缘
///   后继续同向拖，视为「越过本行、去相邻分区」。Bouncing（移动端，出界表达为
///   [ScrollUpdateNotification] 的 outOfRange）与 Clamping（Windows 触屏，出界
///   发 [OverscrollNotification]）两种物理都接。级联必须显式圈定：EditableText
///   也是横向 Scrollable 且内容不满时任何拖动都贴着边缘，搜索框里拖光标绝不能
///   翻页，页签条同理。
///
/// **刻意只接触屏 / 触笔**：鼠标横拖在桌面已有明确语义（`HorizontalDragScrollable`
/// 拖滚、卡片拖拽、扫选），滑动切区只属于触摸交互；桌面用户走页签点击 / 方向键。
/// [OverscrollNotification.dragDetails] 不带设备种类，所以级联的设备门在指针层
/// 记账（[Listener]），与 recognizer 的 `supportedDevices` 同一份判据。
class SectionSwipeNavigator<T extends Object> extends StatefulWidget {
  const SectionSwipeNavigator({
    required this.sections,
    required this.selected,
    required this.onSelect,
    required this.child,
    super.key,
  });

  /// 按 tab **视觉序**排列的分区值。[selected] 不在其中时本层不响应（如游戏页
  /// 的诊断分区不在页签序里）。
  final List<T> sections;

  /// 当前分区。真相在宿主壳，本层不持有第二份选中态。
  final T selected;

  /// 切到相邻分区，直接接宿主自己的 `_select`。
  final ValueChanged<T> onSelect;

  final Widget child;

  @override
  State<SectionSwipeNavigator<T>> createState() =>
      _SectionSwipeNavigatorState<T>();
}

class _SectionSwipeNavigatorState<T extends Object>
    extends State<SectionSwipeNavigator<T>> {
  /// 本次整页拖拽的累计横向位移。
  double _dragDx = 0;

  /// Clamping 物理下同一次拖拽的累计出界量（Bouncing 用绝对出界深度，不累计）。
  double _cascadeOverscroll = 0;

  /// 一次级联拖拽只切一次区：触发后置位，直到手指全部抬起才复位，防止手指继续
  /// 拖着把整排分区连环翻过去。
  bool _cascadeFired = false;

  /// 当前按下的触屏 / 触笔指针数。级联判据用它排除鼠标拖滚。
  int _touchLikePointers = 0;

  static bool _isTouchLike(PointerDeviceKind kind) =>
      kind == PointerDeviceKind.touch ||
      kind == PointerDeviceKind.stylus ||
      kind == PointerDeviceKind.invertedStylus;

  void _handlePointerDown(PointerDownEvent event) {
    if (_isTouchLike(event.kind)) _touchLikePointers += 1;
  }

  void _handlePointerUpOrCancel(PointerEvent event) {
    if (!_isTouchLike(event.kind)) return;
    if (_touchLikePointers > 0) _touchLikePointers -= 1;
    if (_touchLikePointers == 0) {
      _cascadeFired = false;
      _cascadeOverscroll = 0;
    }
  }

  /// 向逻辑前方（forward = tab 序的下一个）或后方切一格；越界即无事发生——
  /// 分区切换是瞬时的（保活栈没有过渡动画），端头不需要回弹反馈。
  void _step({required bool forward}) {
    final int index = widget.sections.indexOf(widget.selected);
    if (index < 0) return;
    final int target = index + (forward ? 1 : -1);
    if (target < 0 || target >= widget.sections.length) return;
    widget.onSelect(widget.sections[target]);
  }

  /// 物理向左划（delta < 0）在 LTR 里是「去右边的分区」= 逻辑前进；RTL 反向。
  void _stepByPhysicalDelta(double delta) {
    final bool forward = switch (Directionality.of(context)) {
      TextDirection.ltr => delta < 0,
      TextDirection.rtl => delta > 0,
    };
    _step(forward: forward);
  }

  void _handleDragStart(DragStartDetails details) {
    _dragDx = 0;
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    _dragDx += details.delta.dx;
  }

  void _handleDragEnd(DragEndDetails details) {
    final double velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() >= _kSwipeFlingVelocity) {
      _stepByPhysicalDelta(velocity);
    } else if (_dragDx.abs() >= _kSwipeDragDistance) {
      _stepByPhysicalDelta(_dragDx);
    }
    _dragDx = 0;
  }

  /// 级联的共同前置门：手指拖拽、横轴、来自被圈定的滚动区、本次拖拽尚未触发过。
  bool _cascadeEligible(BuildContext? scrollableContext, Axis axis) {
    return axis == Axis.horizontal &&
        !_cascadeFired &&
        _touchLikePointers > 0 &&
        scrollableContext != null &&
        SectionSwipeCascade.marks(scrollableContext);
  }

  /// 出界方向到分区方向的映射天然与 RTL 无关：滚动位置是逻辑坐标（RTL 的横向
  /// ListView 由框架自己反排），越过 max 边 = 本行内容已按阅读方向耗尽 = 前进。
  bool _handleOverscroll(OverscrollNotification notification) {
    if (notification.dragDetails == null) return false;
    if (!_cascadeEligible(notification.context, notification.metrics.axis)) {
      return false;
    }
    if (_cascadeOverscroll != 0 &&
        _cascadeOverscroll.sign != notification.overscroll.sign) {
      // 反向蹭动清零重计，来回小幅拖不该累计出假触发。
      _cascadeOverscroll = 0;
    }
    _cascadeOverscroll += notification.overscroll;
    if (_cascadeOverscroll.abs() >= _kCascadeOverscrollDistance) {
      final bool forward = _cascadeOverscroll > 0;
      _cascadeFired = true;
      _cascadeOverscroll = 0;
      _step(forward: forward);
    }
    return false;
  }

  bool _handleScrollUpdate(ScrollUpdateNotification notification) {
    if (notification.dragDetails == null) return false;
    final ScrollMetrics metrics = notification.metrics;
    if (!_cascadeEligible(notification.context, metrics.axis)) return false;
    if (!metrics.outOfRange) return false;
    final double beyond = metrics.pixels > metrics.maxScrollExtent
        ? metrics.pixels - metrics.maxScrollExtent
        : metrics.pixels - metrics.minScrollExtent;
    if (beyond.abs() >= _kCascadeOverscrollDistance) {
      _cascadeFired = true;
      _step(forward: beyond > 0);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _handlePointerDown,
      onPointerUp: _handlePointerUpOrCancel,
      onPointerCancel: _handlePointerUpOrCancel,
      child: NotificationListener<OverscrollNotification>(
        onNotification: _handleOverscroll,
        child: NotificationListener<ScrollUpdateNotification>(
          onNotification: _handleScrollUpdate,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            supportedDevices: const <PointerDeviceKind>{
              PointerDeviceKind.touch,
              PointerDeviceKind.stylus,
              PointerDeviceKind.invertedStylus,
            },
            onHorizontalDragStart: _handleDragStart,
            onHorizontalDragUpdate: _handleDragUpdate,
            onHorizontalDragEnd: _handleDragEnd,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// 圈定「参与边缘级联」的横向滚动区（见 [SectionSwipeNavigator]）。
///
/// 只包媒体横滚行这类**内容性**滚动区；文本框、页签条等控件性横向滚动绝不能包。
class SectionSwipeCascade extends InheritedWidget {
  const SectionSwipeCascade({required super.child, super.key});

  /// [scrollableContext]（滚动区自己的 context）所在子树是否被圈进级联。
  static bool marks(BuildContext scrollableContext) =>
      scrollableContext
          .getElementForInheritedWidgetOfExactType<SectionSwipeCascade>() !=
      null;

  @override
  bool updateShouldNotify(SectionSwipeCascade oldWidget) => false;
}
