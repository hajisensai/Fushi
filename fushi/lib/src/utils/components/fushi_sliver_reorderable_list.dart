import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_reorderable_column.dart';

/// 懒建的竖向「拖拽重排」sliver：[FushiReorderableColumn] 的 sliver 形态，给行数可能
/// 上千的列表用（已装在线源：批量装完整个 keiyoushi 仓库就是一千多行）。
///
/// **为什么不能继续用 [FushiReorderableColumn]**：它是 `Stack` + `Flex`，挂进
/// `SliverToBoxAdapter` 后视口没法裁掉屏外行——每一行都实体化、布局、绘制并留在
/// 合成树里（#E5IZOyVcbm：浏览页空闲时 PictureLayer×6593 / OpacityLayer×4395 /
/// ClipPathLayer×1098，正是约 1100 行已装源每行「1 剪裁 + 若干透明 + 若干图」）。
/// 这里换成 [SliverList.builder]，只建视口 + 缓存区里的那十几行。
///
/// **拖拽怎么在懒建列表里成立**（与 [FushiReorderableColumn] 同样不借 Overlay，
/// 所以祖先 `Transform.scale`（`FushiAppUiScale`）下零漂移，BUG-778）：
/// - 识别器归**列表 State** 持有，行只用 [Listener] 把按下事件交给它：被拖行滚出
///   缓存区被回收时拖拽不断（识别器不随行 dispose）。
/// - 被拖行就在自己的槽位里抬起（[FushiReorderDragProxy] 的浮起观感），指针越过
///   相邻行的中线就和它换位——判据只看**已布局的相邻行**的屏幕矩形
///   （`getTransformTo(null)` 连祖先缩放一起换算），屏外行不需要测高。
/// - 指针进入视口上 / 下边缘带时按帧步进滚动（同 [FushiReorderableColumn]），新露出的
///   行布局后即参与换位。
///
/// 起拖时机同 [FushiReorderableColumn]：鼠标 / 触控板 / 笔越过拖动阈值即拖，触摸屏
/// 长按再拖（[touchDragEnabled] 为 false 时触屏手势全留给外层）。
class FushiSliverReorderableList extends StatefulWidget {
  const FushiSliverReorderableList({
    required this.itemCount,
    required this.itemBuilder,
    required this.keyForIndex,
    required this.onReorder,
    this.spacing = 0,
    this.feedbackBorderRadius,
    this.touchDragEnabled = true,
    super.key,
  });

  final int itemCount;

  /// 行内容（不含拖拽监听；开关 / 按钮照常可点）。
  final FushiReorderItemBuilder itemBuilder;

  /// 行身份：懒建列表按它找回元素（换位时行 State 跟着行走，不按下标复用）。
  final FushiReorderKeyBuilder keyForIndex;

  /// 「item[from] 移到最终下标 to」，松手时提交一次；取消拖拽不提交。
  final FushiReorderCallback onReorder;

  /// 相邻行间距（由列表插入，不涂进抬起行的浮起面）。
  final double spacing;

  /// 抬起行浮起面的圆角；null 走设计系统默认。
  final BorderRadius? feedbackBorderRadius;

  /// 触摸屏是否参与重排（长按起拖）。
  final bool touchDragEnabled;

  @override
  State<FushiSliverReorderableList> createState() =>
      _FushiSliverReorderableListState();
}

class _FushiSliverReorderableListState
    extends State<FushiSliverReorderableList> {
  /// 显示顺序：display 位置 → 原始 index（拖拽中实时变化；不拖时恒等）。
  late List<int> _display;

  /// 每行的测量 GlobalKey，按行身份索引（不按下标）。只有已建的行有 context。
  final Map<Key, GlobalKey> _rowKeys = <Key, GlobalKey>{};

  int? _dragOriginal;
  int _dragStartDi = 0;

  /// 按下时记下的行（识别器的 onStart 只给坐标，不给是哪一行）。
  int? _pendingOriginal;

  /// 刚换过位、新布局还没出来：这期间相邻行的矩形是旧的，换位判据等布局后再跑。
  bool _awaitingLayout = false;

  ScrollableState? _scrollable;
  Offset _lastPointerGlobal = Offset.zero;
  double _autoScrollStepSigned = 0;
  bool _autoScrollScheduled = false;

  static const double _autoScrollEdge = 64.0;
  static const double _autoScrollStep = 16.0;

  static const Set<PointerDeviceKind> _immediateDragDevices =
      <PointerDeviceKind>{
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
        PointerDeviceKind.unknown,
      };

  static const Set<PointerDeviceKind> _delayedDragDevices = <PointerDeviceKind>{
    PointerDeviceKind.touch,
  };

  late final ImmediateMultiDragGestureRecognizer _immediate =
      ImmediateMultiDragGestureRecognizer(
        supportedDevices: _immediateDragDevices,
      )..onStart = _onMultiDragStart;

  late final DelayedMultiDragGestureRecognizer _delayed =
      DelayedMultiDragGestureRecognizer(supportedDevices: _delayedDragDevices)
        ..onStart = _onMultiDragStart;

  @override
  void initState() {
    super.initState();
    _resetDisplay();
  }

  @override
  void didUpdateWidget(covariant FushiSliverReorderableList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.itemCount != widget.itemCount) {
      _resetDisplay();
      _stopAutoScroll();
      _dragOriginal = null;
      _pendingOriginal = null;
    }
  }

  @override
  void dispose() {
    _immediate.dispose();
    _delayed.dispose();
    super.dispose();
  }

  void _resetDisplay() {
    _display = List<int>.generate(widget.itemCount, (int i) => i);
    final Set<Key> live = <Key>{
      for (int i = 0; i < widget.itemCount; i++) widget.keyForIndex(i),
    };
    _rowKeys.removeWhere((Key k, _) => !live.contains(k));
  }

  GlobalKey _rowKeyOf(int original) =>
      _rowKeys.putIfAbsent(widget.keyForIndex(original), GlobalKey.new);

  /// 已布局行的屏幕矩形（连祖先缩放一起换算）；行没建 / 没布局返回 null。
  Rect? _screenRectOf(int original) {
    final RenderObject? ro = _rowKeys[widget.keyForIndex(original)]
        ?.currentContext
        ?.findRenderObject();
    if (ro is! RenderBox || !ro.attached || !ro.hasSize) return null;
    return MatrixUtils.transformRect(
      ro.getTransformTo(null),
      Offset.zero & ro.size,
    );
  }

  void _onPointerDown(int original, PointerDownEvent event) {
    if (_dragOriginal != null) return;
    _pendingOriginal = original;
    // 两个识别器各自按 supportedDevices 过滤，不支持的设备直接忽略。
    _immediate.addPointer(event);
    if (widget.touchDragEnabled) _delayed.addPointer(event);
  }

  Drag? _onMultiDragStart(Offset globalPosition) {
    final int? original = _pendingOriginal;
    if (original == null || _dragOriginal != null) return null;
    final int di = _display.indexOf(original);
    if (di < 0) return null;
    _scrollable = context.findAncestorStateOfType<ScrollableState>();
    _lastPointerGlobal = globalPosition;
    setState(() {
      _dragOriginal = original;
      _dragStartDi = di;
    });
    return _SliverReorderDrag(
      onUpdate: _updateDrag,
      onEnd: _endDrag,
      onCancel: _cancelDrag,
    );
  }

  void _updateDrag(Offset globalPosition) {
    final int? dragged = _dragOriginal;
    if (dragged == null) return;
    _lastPointerGlobal = globalPosition;
    _maybeAutoScroll(globalPosition);
    if (_awaitingLayout) return;
    final double pointer = globalPosition.dy;
    int di = _display.indexOf(dragged);
    bool moved = false;
    // 向下：越过下一行中线就与它换位。只有被拖行之前的行会因换位而移动，下一行
    // 的旧矩形在同一轮里仍然有效，所以快速拖过多行时可以连续换。
    while (di + 1 < _display.length) {
      final Rect? next = _screenRectOf(_display[di + 1]);
      if (next == null || pointer <= next.center.dy) break;
      _display
        ..removeAt(di)
        ..insert(di + 1, dragged);
      di++;
      moved = true;
    }
    if (!moved) {
      while (di > 0) {
        final Rect? previous = _screenRectOf(_display[di - 1]);
        if (previous == null || pointer >= previous.center.dy) break;
        _display
          ..removeAt(di)
          ..insert(di - 1, dragged);
        di--;
        moved = true;
      }
    }
    if (!moved) return;
    _awaitingLayout = true;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      _awaitingLayout = false;
      if (mounted && _dragOriginal != null) _updateDrag(_lastPointerGlobal);
    });
  }

  void _endDrag() {
    final int? dragged = _dragOriginal;
    if (dragged == null) return;
    _stopAutoScroll();
    final int from = _dragStartDi;
    final int to = _display.indexOf(dragged);
    setState(() {
      _dragOriginal = null;
      _pendingOriginal = null;
      _display = List<int>.generate(widget.itemCount, (int i) => i);
    });
    if (to != from) widget.onReorder(from, to);
  }

  void _cancelDrag() {
    if (_dragOriginal == null) return;
    _stopAutoScroll();
    _pendingOriginal = null;
    if (!mounted) {
      _dragOriginal = null;
      return;
    }
    setState(() {
      _dragOriginal = null;
      _display = List<int>.generate(widget.itemCount, (int i) => i);
    });
  }

  void _maybeAutoScroll(Offset globalPosition) {
    final ScrollableState? sc = _scrollable;
    if (sc == null || !sc.mounted || sc.position.axis != Axis.vertical) {
      _autoScrollStepSigned = 0;
      return;
    }
    final RenderObject? ro = sc.context.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize) {
      _autoScrollStepSigned = 0;
      return;
    }
    final ScrollPosition pos = sc.position;
    final Rect viewport = MatrixUtils.transformRect(
      ro.getTransformTo(null),
      Offset.zero & ro.size,
    );
    final double pointer = globalPosition.dy;
    double step = 0;
    if (pointer < viewport.top + _autoScrollEdge &&
        pos.pixels > pos.minScrollExtent) {
      step = -_autoScrollStep;
    } else if (pointer > viewport.bottom - _autoScrollEdge &&
        pos.pixels < pos.maxScrollExtent) {
      step = _autoScrollStep;
    }
    _autoScrollStepSigned = step;
    if (step != 0 && !_autoScrollScheduled) {
      _autoScrollScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback(_autoScrollTick);
    }
  }

  void _autoScrollTick(Duration _) {
    _autoScrollScheduled = false;
    if (!mounted || _dragOriginal == null || _autoScrollStepSigned == 0) return;
    final ScrollableState? sc = _scrollable;
    if (sc == null || !sc.mounted) return;
    final ScrollPosition pos = sc.position;
    final double next = (pos.pixels + _autoScrollStepSigned).clamp(
      pos.minScrollExtent,
      pos.maxScrollExtent,
    );
    if (next != pos.pixels) pos.jumpTo(next);
    _updateDrag(_lastPointerGlobal);
  }

  void _stopAutoScroll() {
    _autoScrollStepSigned = 0;
    _scrollable = null;
  }

  @override
  Widget build(BuildContext context) {
    final Map<Key, int> displayIndexOf = <Key, int>{
      for (int di = 0; di < _display.length; di++)
        widget.keyForIndex(_display[di]): di,
    };
    return SliverList.builder(
      itemCount: _display.length,
      findChildIndexCallback: (Key key) => displayIndexOf[key],
      itemBuilder: (BuildContext context, int di) {
        final int original = _display[di];
        Widget content = KeyedSubtree(
          key: _rowKeyOf(original),
          child: widget.itemBuilder(context, original),
        );
        if (_dragOriginal == original) {
          content = FushiReorderDragProxy(
            borderRadius: widget.feedbackBorderRadius,
            child: content,
          );
        }
        return Listener(
          key: widget.keyForIndex(original),
          behavior: HitTestBehavior.translucent,
          onPointerDown: (PointerDownEvent event) =>
              _onPointerDown(original, event),
          child: Padding(
            padding: EdgeInsets.only(top: di > 0 ? widget.spacing : 0),
            child: content,
          ),
        );
      },
    );
  }
}

/// 把识别器的拖拽回调桥接到列表 State（全局坐标）。
class _SliverReorderDrag extends Drag {
  _SliverReorderDrag({
    required this.onUpdate,
    required this.onEnd,
    required this.onCancel,
  });

  final void Function(Offset globalPosition) onUpdate;
  final VoidCallback onEnd;
  final VoidCallback onCancel;

  @override
  void update(DragUpdateDetails details) => onUpdate(details.globalPosition);

  @override
  void end(DragEndDetails details) => onEnd();

  @override
  void cancel() => onCancel();
}
