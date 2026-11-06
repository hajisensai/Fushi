import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// 拖拽期间的边缘自动滚动区（拖到滚动视口边缘时视口自己滚）。
///
/// 为什么需要：`Draggable` 一旦拿起，指针被拖拽手势独占，外层 / 内层 ScrollView
/// 收不到滚动手势；视口外的 `DragTarget` 永远够不到（Wn1SZdlyhl：手机上控件布局
/// 编辑器靠下的槽位拖不过去）。Flutter 自带的 [EdgeDraggingAutoScroller]
/// （ReorderableList 用的就是它）只认 [ScrollableState] + 拖拽矩形，本组件负责把
/// 「哪些滚动视口参与、指针现在在哪、什么时候停」接到它上面，所有拖拽编辑器共用。
///
/// 用法：
/// - 用 [DragAutoScrollRegion] 包住整个编辑器（拖拽源与放置区都在它下面）。
///   [includeAncestorScrollable] 为 true 时，区外最近的竖向滚动视口（如设置页
///   ListView）也参与。
/// - 编辑器内部自己的滚动视口，在其**内容**外包一层 [DragAutoScrollTarget]
///   （它要位于该 Scrollable 之下才能找到它）。
/// - 每个 `Draggable` 在 `onDragUpdate` 里调 [DragAutoScrollRegion.maybeOf] 的
///   [DragAutoScrollRegionState.updateDrag]，在结束 / 取消时调
///   [DragAutoScrollRegionState.endDrag]。区自己也监听指针抬起 / 取消兜底停止：
///   拖动中源 chip 可能被重挂，`Draggable` 只在 mounted 时回调 onDragEnd。
class DragAutoScrollRegion extends StatefulWidget {
  const DragAutoScrollRegion({
    required this.child,
    this.includeAncestorScrollable = true,
    this.edgeExtent = 48,
    this.velocityScalar = 50,
    super.key,
  });

  final Widget child;

  /// 区外的竖向 Scrollable（由近及远**整条链**）是否参与自动滚动。
  final bool includeAncestorScrollable;

  /// 指针距视口边缘多近（逻辑像素）时开始滚。
  final double edgeExtent;

  /// 传给 [EdgeDraggingAutoScroller.velocityScalar]；与 ReorderableList 默认一致。
  final double velocityScalar;

  static DragAutoScrollRegionState? maybeOf(BuildContext context) =>
      context.findAncestorStateOfType<DragAutoScrollRegionState>();

  @override
  State<DragAutoScrollRegion> createState() => DragAutoScrollRegionState();
}

class DragAutoScrollRegionState extends State<DragAutoScrollRegion> {
  /// 区内注册的滚动视口，先注册的靠外；挑选时内层优先。
  final List<ScrollableState> _inner = <ScrollableState>[];

  /// 区外的竖向 Scrollable，由近及远。必须是整条链而不是最近一个：设置渲染器把
  /// 分组内容画成 `shrinkWrap` + 禁滚的 ListView，嵌在面板真正滚动的
  /// SingleChildScrollView 里——只取最近一个会拿到那个滚不动的内层，外层永远不滚
  /// （WJP1eLSfdx：播放器侧边栏「控制按钮」页，BUG-3985 修复在那里没生效）。
  List<ScrollableState> _ancestors = const <ScrollableState>[];
  final Map<ScrollableState, EdgeDraggingAutoScroller> _scrollers =
      <ScrollableState, EdgeDraggingAutoScroller>{};
  ScrollableState? _active;

  /// 是否正有拖拽在进行（只有拖拽期间才响应指针位置）。
  bool get dragging => _dragging;
  bool _dragging = false;

  /// 最近一次拖拽指针位置（全局）。自动滚动每走一步都要拿它重算拖拽矩形：
  /// [EdgeDraggingAutoScroller] 把矩形钉在**内容坐标**里，不重报的话视口追上
  /// 矩形就停（只滚出边缘带那几十像素）。手指停在边缘时也要一直滚下去。
  Offset? _lastPointer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ancestors = _resolveAncestors();
  }

  @override
  void didUpdateWidget(DragAutoScrollRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.includeAncestorScrollable !=
        widget.includeAncestorScrollable) {
      _ancestors = _resolveAncestors();
    }
  }

  List<ScrollableState> _resolveAncestors() {
    if (!widget.includeAncestorScrollable) return const <ScrollableState>[];
    final List<ScrollableState> chain = <ScrollableState>[];
    ScrollableState? next = Scrollable.maybeOf(context, axis: Axis.vertical);
    while (next != null) {
      chain.add(next);
      // 再往外只做查找、不登记依赖（依赖会记到别人的 element 上）；横向的跳过。
      next = next.context.findAncestorStateOfType<ScrollableState>();
      while (next != null &&
          axisDirectionToAxis(next.axisDirection) != Axis.vertical) {
        next = next.context.findAncestorStateOfType<ScrollableState>();
      }
    }
    return chain;
  }

  @override
  void dispose() {
    _stopAll();
    super.dispose();
  }

  void _register(ScrollableState scrollable) {
    if (!_inner.contains(scrollable)) _inner.add(scrollable);
  }

  void _unregister(ScrollableState scrollable) {
    _inner.remove(scrollable);
    _scrollers.remove(scrollable)?.stopAutoScroll();
    if (identical(_active, scrollable)) _active = null;
  }

  /// 拖拽中的指针移到了 [globalPosition]（全局坐标）。
  void updateDrag(Offset globalPosition) {
    _dragging = true;
    _lastPointer = globalPosition;
    final ScrollableState? target = _pickScrollable(globalPosition);
    if (!identical(target, _active)) {
      final ScrollableState? previous = _active;
      if (previous != null) _scrollers[previous]?.stopAutoScroll();
      _active = target;
    }
    if (target == null) return;
    final Rect? viewport = _globalRectOf(target);
    if (viewport == null) return;
    // 以指针为中心、边长 2×edgeExtent 的方块当拖拽矩形：指针进入边缘带时方块越过
    // 视口边，EdgeDraggingAutoScroller 便开始滚。方块不能比视口大（它会断言）。
    final double side = math.min(
      widget.edgeExtent * 2,
      math.min(viewport.width, viewport.height),
    );
    final Rect probe = Rect.fromCenter(
      center: globalPosition,
      width: side,
      height: side,
    );
    final EdgeDraggingAutoScroller scroller = _scrollers.putIfAbsent(
      target,
      () => EdgeDraggingAutoScroller(
        target,
        velocityScalar: widget.velocityScalar,
        onScrollViewScrolled: _handleAutoScrolled,
      ),
    );
    scroller.startAutoScrollIfNecessary(probe);
  }

  /// 自动滚动走了一步：按指针**当前**位置重报矩形（同 ReorderableList 的做法）。
  void _handleAutoScrolled() {
    final Offset? pointer = _lastPointer;
    if (!_dragging || pointer == null || !mounted) return;
    updateDrag(pointer);
  }

  /// 拖拽结束 / 取消：停止一切自动滚动。
  void endDrag() {
    _dragging = false;
    _lastPointer = null;
    _stopAll();
  }

  void _stopAll() {
    for (final EdgeDraggingAutoScroller scroller in _scrollers.values) {
      scroller.stopAutoScroll();
    }
    _active = null;
  }

  /// 挑出该滚的视口：包含指针、指针在它的边缘带内、且朝那个方向还有可滚余量。
  /// 内层优先，再由近及远看区外祖先（滚不动的会因没有可滚余量被跳过）。指针
  /// 不在任何视口边缘带时返回 null（不滚）——这样从视口外（如固定在上方的
  /// 调色板）开始拖时不会一拿起就把视口往回卷。
  ScrollableState? _pickScrollable(Offset globalPosition) {
    final List<ScrollableState> candidates = <ScrollableState>[
      ..._inner.reversed,
      ..._ancestors,
    ];
    for (final ScrollableState scrollable in candidates) {
      if (!scrollable.mounted) continue;
      final Rect? rect = _globalRectOf(scrollable);
      if (rect == null || !rect.contains(globalPosition)) continue;
      final ScrollPosition position = scrollable.position;
      if (!position.hasContentDimensions || !position.hasPixels) continue;
      final Axis axis = axisDirectionToAxis(scrollable.axisDirection);
      final double pointer = axis == Axis.vertical
          ? globalPosition.dy
          : globalPosition.dx;
      final double start = axis == Axis.vertical ? rect.top : rect.left;
      final double end = axis == Axis.vertical ? rect.bottom : rect.right;
      final bool reversed = axisDirectionIsReversed(scrollable.axisDirection);
      final bool nearStart = pointer - start <= widget.edgeExtent;
      final bool nearEnd = end - pointer <= widget.edgeExtent;
      // 视口「起点」（offset 变小的方向）在反向轴上位于末端。
      final bool canBack = position.pixels > position.minScrollExtent;
      final bool canForward = position.pixels < position.maxScrollExtent;
      final bool wantsBack = reversed ? nearEnd : nearStart;
      final bool wantsForward = reversed ? nearStart : nearEnd;
      if ((wantsBack && canBack) || (wantsForward && canForward)) {
        return scrollable;
      }
    }
    return null;
  }

  Rect? _globalRectOf(ScrollableState scrollable) {
    final RenderObject? render = scrollable.context.findRenderObject();
    if (render is! RenderBox || !render.hasSize || !render.attached) {
      return null;
    }
    return MatrixUtils.transformRect(
      render.getTransformTo(null),
      Offset.zero & render.size,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerUp: (PointerUpEvent _) => endDrag(),
      onPointerCancel: (PointerCancelEvent _) => endDrag(),
      child: widget.child,
    );
  }
}

/// 把所在的 Scrollable 注册进最近的 [DragAutoScrollRegion]：包在滚动视口的内容
/// 外面（例如 `SingleChildScrollView(child: DragAutoScrollTarget(child: ...))`）。
class DragAutoScrollTarget extends StatefulWidget {
  const DragAutoScrollTarget({required this.child, super.key});

  final Widget child;

  @override
  State<DragAutoScrollTarget> createState() => _DragAutoScrollTargetState();
}

class _DragAutoScrollTargetState extends State<DragAutoScrollTarget> {
  DragAutoScrollRegionState? _region;
  ScrollableState? _scrollable;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final DragAutoScrollRegionState? region = DragAutoScrollRegion.maybeOf(
      context,
    );
    final ScrollableState? scrollable = Scrollable.maybeOf(context);
    if (identical(region, _region) && identical(scrollable, _scrollable)) {
      return;
    }
    final ScrollableState? oldScrollable = _scrollable;
    if (oldScrollable != null) _region?._unregister(oldScrollable);
    _region = region;
    _scrollable = scrollable;
    if (region != null && scrollable != null) region._register(scrollable);
  }

  @override
  void dispose() {
    final ScrollableState? scrollable = _scrollable;
    if (scrollable != null) _region?._unregister(scrollable);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
