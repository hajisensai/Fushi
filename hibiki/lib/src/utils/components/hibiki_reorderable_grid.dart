import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// 格子内容构造器：返回**不含任何拖拽监听**的纯卡片内容。注意网格把卡片包进
/// IgnorePointer（TODO-947：编辑排序态卡片只是拖拽把手，卡片内 onTap = 打开书必须
/// 落空），所以这里返回的卡片内手势不会触发——卡片只作视觉渲染。
typedef HibikiGridItemBuilder = Widget Function(
    BuildContext context, int index);

/// 为某个 index 返回稳定 Key（格子身份，用于拖拽中保留同一手势识别器元素）。
typedef HibikiGridKeyBuilder = Key Function(int index);

/// 「item[from] 移到最终下标 to」——调用方实现为 `removeAt(from); insert(to, item)`。
typedef HibikiGridReorderCallback = void Function(int from, int to);

/// 自实现的二维拖拽重排网格，是 [HibikiReorderableColumn] 的网格版（TODO-616 B2）。
/// 浮层渲染在本组件自身 Stack 内 + 全程 globalToLocal 把指针转本地坐标，在祖先
/// Transform.scale（HibikiAppUiScale 整体缩放）下零偏移跟手。
/// 几何契约：crossCount = max(1, floor(contentWidth / cellExtent))，调用方须把同一
/// cellExtent 喂给渲染层 SliverGridDelegateWithMaxCrossAxisExtent.maxCrossAxisExtent。
/// 2D 命中：浮层中心 → col/row → index = row*crossCount + col，末行不满列按
/// itemCount clamp(0, itemCount-1)（防 BUG-078 off-by-one）。
class HibikiReorderableGrid extends StatefulWidget {
  const HibikiReorderableGrid({
    required this.itemCount,
    required this.itemBuilder,
    required this.keyForIndex,
    required this.onReorder,
    required this.cellExtent,
    this.childAspectRatio,
    this.mainAxisExtent,
    this.crossAxisSpacing = 0,
    this.mainAxisSpacing = 0,
    this.padding = EdgeInsets.zero,
    this.feedbackBorderRadius,
    super.key,
  });

  final int itemCount;
  final HibikiGridItemBuilder itemBuilder;
  final HibikiGridKeyBuilder keyForIndex;

  /// item[from] 移到最终下标 to。鼠标等精确指针按下即拖，触摸屏长按再拖。
  final HibikiGridReorderCallback onReorder;

  /// 单格最大主轴外延（= 渲染层 maxCrossAxisExtent）。列数由 floor(width/cellExtent) 反推。
  final double cellExtent;

  /// 单格宽高比（= 渲染层 childAspectRatio）。与 [mainAxisExtent] 二选一：
  /// [mainAxisExtent] 非空时优先用固定高度，本字段被忽略。
  final double? childAspectRatio;

  /// 单格固定主轴（纵向）高度（= 渲染层 mainAxisExtent）。非空时单格高恒为此值
  /// （视频网格用 mainAxisExtent:200 固定高，不是 aspectRatio）。
  final double? mainAxisExtent;

  /// 横向格间距（= 渲染层 crossAxisSpacing）。
  final double crossAxisSpacing;

  /// 纵向格间距（= 渲染层 mainAxisSpacing）。
  final double mainAxisSpacing;

  /// 网格外边距（= 渲染层 padding）。命中坐标在扣 padding 后的内容区算。
  final EdgeInsets padding;

  /// 拖拽浮层圆角（裁切到此半径）；null 为直角。
  final BorderRadius? feedbackBorderRadius;

  @override
  State<HibikiReorderableGrid> createState() => _HibikiReorderableGridState();
}

class _HibikiReorderableGridState extends State<HibikiReorderableGrid> {
  /// 拖拽落点目标下标（命中实时更新；松手提交 onReorder(from,target)）。
  /// 不在拖拽中实时重排子列表（避免重排导致活跃手势识别器元素失效、end/cancel
  /// 丢失）——仅被拖卡片透明占位，其余卡片不动。
  int? _dropTarget;

  /// 本网格根 Stack 的 key，用于 globalToLocal 把指针转本地坐标 + 测尺寸。
  final GlobalKey _rootKey = GlobalKey();

  /// 驱动本网格自身滚动 + auto-scroll。
  final ScrollController _scrollController = ScrollController();

  /// 从已布局的格子 context 抓到的 ScrollableState（喂 EdgeDraggingAutoScroller，
  /// 它要 ScrollableState 而非 ScrollPosition）。格子在 GridView 的 viewport 内部，
  /// 其 Scrollable.of 命中本网格自己的 Scrollable。
  ScrollableState? _scrollableState;
  EdgeDraggingAutoScroller? _autoScroller;

  int? _dragOriginal; // 正在拖拽的原始 index（null = 未拖拽）
  int _dragStartDi = 0; // 起拖时被拖卡片的 display 下标（提交 from）
  Offset _grabOffset = Offset.zero; // 抓取点相对被拖格左上的本地偏移
  Offset _feedbackTopLeft = Offset.zero; // 浮层左上的本地坐标
  Size _cellSize = Size.zero; // 实测单格内容尺寸
  int _crossCount = 1; // 当前列数（布局期算）

  @override
  void initState() {
    super.initState();
  }

  @override
  void didUpdateWidget(covariant HibikiReorderableGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.itemCount != widget.itemCount) {
      _dragOriginal = null;
      _dropTarget = null;
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Offset _localOffset(Offset globalPosition) {
    final RenderObject? ro = _rootKey.currentContext?.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize) return globalPosition;
    return ro.globalToLocal(globalPosition);
  }

  double get _strideX => _cellSize.width + widget.crossAxisSpacing;
  double get _strideY => _cellSize.height + widget.mainAxisSpacing;

  /// 布局期算列数 + 单格尺寸（与渲染 delegate 同公式：内容区宽扣 padding/间距均分）。
  void _captureGeometry(double contentWidth) {
    final double innerWidth = contentWidth - widget.padding.horizontal;
    final int cross =
        (innerWidth / widget.cellExtent).floor().clamp(1, 1 << 30);
    final double cellWidth =
        (innerWidth - widget.crossAxisSpacing * (cross - 1)) / cross;
    final double cellHeight =
        widget.mainAxisExtent ?? (cellWidth / (widget.childAspectRatio ?? 1.0));
    _crossCount = cross;
    _cellSize = Size(cellWidth, cellHeight);
  }

  double get _scrollOffset =>
      _scrollController.hasClients ? _scrollController.offset : 0;

  /// 下标 index 的格左上（本地坐标，含 padding + 滚动偏移）。
  Offset _slotTopLeft(int index) {
    final int row = index ~/ _crossCount;
    final int col = index % _crossCount;
    return Offset(
      widget.padding.left + col * _strideX,
      widget.padding.top + row * _strideY - _scrollOffset,
    );
  }

  void _startDrag(int original, Offset globalPosition) {
    final Offset slot = _slotTopLeft(original);
    final Offset local = _localOffset(globalPosition);
    setState(() {
      _dragOriginal = original;
      _dragStartDi = original;
      _dropTarget = original;
      _grabOffset = Offset(
        (local.dx - slot.dx).clamp(0.0, _cellSize.width),
        (local.dy - slot.dy).clamp(0.0, _cellSize.height),
      );
      _feedbackTopLeft = slot;
    });
    final ScrollableState? scrollable = _scrollableState;
    if (scrollable != null) {
      _autoScroller = EdgeDraggingAutoScroller(
        scrollable,
        velocityScalar: 7,
      );
    }
  }

  void _updateDrag(Offset globalPosition) {
    final int? dragged = _dragOriginal;
    if (dragged == null) return;
    final Offset local = _localOffset(globalPosition);
    setState(() => _feedbackTopLeft = local - _grabOffset);

    // auto-scroll：浮层矩形撞上下边缘时滚动（转全局矩形喂 autoScroller）。
    final RenderObject? ro = _rootKey.currentContext?.findRenderObject();
    if (ro is RenderBox && ro.hasSize && _autoScroller != null) {
      final Offset topLeftGlobal = ro.localToGlobal(_feedbackTopLeft);
      _autoScroller!.startAutoScrollIfNecessary(topLeftGlobal & _cellSize);
    }

    // 2D 命中：浮层中心 → (col,row) → display 下标 → clamp itemCount（防 off-by-one）。
    final Offset center =
        _feedbackTopLeft + Offset(_cellSize.width / 2, _cellSize.height / 2);
    final double innerX = center.dx - widget.padding.left;
    final double innerY = center.dy - widget.padding.top + _scrollOffset;
    final int col = (innerX / _strideX).floor().clamp(0, _crossCount - 1);
    final int rawRow = (innerY / _strideY).floor();
    final int row = rawRow < 0 ? 0 : rawRow;
    final int target = (row * _crossCount + col).clamp(0, widget.itemCount - 1);
    if (target != _dropTarget) setState(() => _dropTarget = target);
  }

  void _endDrag() {
    final int? dragged = _dragOriginal;
    if (dragged == null) return;
    _autoScroller?.stopAutoScroll();
    final int from = _dragStartDi;
    final int to = _dropTarget ?? from;
    setState(() {
      _dragOriginal = null;
      _dropTarget = null;
    });
    if (to != from) widget.onReorder(from, to);
  }

  /// 拖拽取消：放弃本次重排、复位原序，不提交 onReorder。守 mounted 防 dispose 期 setState。
  void _cancelDrag() {
    if (_dragOriginal == null) return;
    _autoScroller?.stopAutoScroll();
    if (!mounted) {
      _dragOriginal = null;
      _dropTarget = null;
      return;
    }
    setState(() {
      _dragOriginal = null;
      _dropTarget = null;
    });
  }

  Drag _onMultiDragStart(int original, Offset globalPosition) {
    _startDrag(original, globalPosition);
    return _GridReorderDrag(
      onUpdate: _updateDrag,
      onEnd: _endDrag,
      onCancel: _cancelDrag,
    );
  }

  /// 鼠标/触控板/触控笔等精确指针：按下移动即拖。
  static const Set<PointerDeviceKind> _immediateDragDevices =
      <PointerDeviceKind>{
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.unknown,
  };

  /// 触摸屏：长按起拖。
  static const Set<PointerDeviceKind> _delayedDragDevices = <PointerDeviceKind>{
    PointerDeviceKind.touch,
  };

  Widget _buildCell(int original) {
    final Widget content = Builder(
      builder: (BuildContext cellContext) {
        // 首次布局时抓本网格 Scrollable（在 viewport 内部）喂 autoScroller。
        _scrollableState ??= Scrollable.maybeOf(cellContext);
        return widget.itemBuilder(cellContext, original);
      },
    );
    // TODO-947：编辑排序态下卡片只是拖拽把手——把渲染出的卡片包进 IgnorePointer，
    // 让卡片内的手势（书架/视频卡片的 InkWell.onTap = 打开书）完全不注册，干净点击
    // 不再穿透打开书；拖拽仍由本格外层 RawGestureDetector（translucent）独立接收指针。
    final Widget inert = IgnorePointer(child: content);
    // 被拖格在原位透明占位（随实时重排移动的空位），可见的是浮层复制。
    final Widget slot =
        _dragOriginal == original ? Opacity(opacity: 0.0, child: inert) : inert;
    return RawGestureDetector(
      key: widget.keyForIndex(original),
      behavior: HitTestBehavior.translucent,
      gestures: <Type, GestureRecognizerFactory>{
        ImmediateMultiDragGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<
                ImmediateMultiDragGestureRecognizer>(
          () => ImmediateMultiDragGestureRecognizer(
              supportedDevices: _immediateDragDevices),
          (ImmediateMultiDragGestureRecognizer instance) {
            instance.onStart =
                (Offset position) => _onMultiDragStart(original, position);
          },
        ),
        DelayedMultiDragGestureRecognizer: GestureRecognizerFactoryWithHandlers<
            DelayedMultiDragGestureRecognizer>(
          () => DelayedMultiDragGestureRecognizer(
              supportedDevices: _delayedDragDevices),
          (DelayedMultiDragGestureRecognizer instance) {
            instance.onStart =
                (Offset position) => _onMultiDragStart(original, position);
          },
        ),
      },
      child: slot,
    );
  }

  @override
  Widget build(BuildContext context) {
    final int? dragged = _dragOriginal;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        _captureGeometry(constraints.maxWidth);
        return Stack(
          key: _rootKey,
          children: <Widget>[
            GridView.builder(
              controller: _scrollController,
              padding: widget.padding,
              gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: widget.cellExtent,
                childAspectRatio: widget.childAspectRatio ?? 1.0,
                mainAxisExtent: widget.mainAxisExtent,
                crossAxisSpacing: widget.crossAxisSpacing,
                mainAxisSpacing: widget.mainAxisSpacing,
              ),
              itemCount: widget.itemCount,
              itemBuilder: (BuildContext context, int i) => _buildCell(i),
            ),
            if (dragged != null)
              Positioned(
                left: _feedbackTopLeft.dx,
                top: _feedbackTopLeft.dy,
                width: _cellSize.width,
                height: _cellSize.height,
                child: IgnorePointer(
                  child: Material(
                    elevation: 6,
                    color: Colors.transparent,
                    shape: widget.feedbackBorderRadius != null
                        ? RoundedRectangleBorder(
                            borderRadius: widget.feedbackBorderRadius!)
                        : null,
                    clipBehavior: widget.feedbackBorderRadius != null
                        ? Clip.antiAlias
                        : Clip.none,
                    child: widget.itemBuilder(context, dragged),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 把 MultiDragGestureRecognizer 的拖拽回调桥接到网格的全局坐标拖拽逻辑。
class _GridReorderDrag extends Drag {
  _GridReorderDrag({
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
