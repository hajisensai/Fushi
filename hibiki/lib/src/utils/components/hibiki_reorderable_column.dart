import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// 行内容构造器：返回**不含任何拖拽监听**的纯行内容（开关/按钮照常可点）。
typedef HibikiReorderItemBuilder = Widget Function(
    BuildContext context, int index);

/// 为某个 index 返回稳定 Key（行身份，用于测高与浮层复制）。
typedef HibikiReorderKeyBuilder = Key Function(int index);

/// 「item[from] 移到最终下标 to」——调用方实现为 `removeAt(from); insert(to, item)`。
typedef HibikiReorderCallback = void Function(int from, int to);

/// 自实现的竖向「拖拽重排」列表，专为运行在祖先 [Transform.scale]
/// （`HibikiAppUiScale` 的浏览器式整体缩放）之下而设计。
///
/// **起拖时机按输入设备区分**（修「Win 端鼠标必须长按等待才能拖动排序」）：
/// - 鼠标 / 触控板 / 触控笔等精确指针 → [ImmediateMultiDragGestureRecognizer]，
///   按下左键移动即拖（桌面用户「按住左键就能拖」的预期）。
/// - 触摸屏 → [DelayedMultiDragGestureRecognizer]（默认 `kLongPressTimeout` ~500ms），
///   保留长按起拖，快速滑动仍交给外层列表滚动。
/// 旧实现用 `GestureDetector.onLongPress*`，对所有平台一律强制长按，桌面鼠标也得等。
///
/// **为什么不用 `ReorderableListView`**：Flutter SDK 的拖拽代理
/// （`reorderable_list.dart` 的 `_DragItemProxy`）用「全局坐标 − overlay 原点」的
/// 纯平移把代理放进 Overlay 本地坐标系、不认祖先缩放变换；当整棵树被 `Transform.scale`
/// 缩放时，代理实际落点按 `(1−s)×(指针到 overlay 原点距离)` 漂移、缩小时一拖即飞出屏幕。
/// 这是 SDK 对 Transform 内 Reorderable/Draggable 的已知坐标缺陷，app 内改不了那段数学。
///
/// **本组件如何同时做到「视觉随缩放一致」+「拖拽零偏移」**：
/// - 不借助任何 Overlay。拖拽中的浮层复制就渲染在本列表自身的 [Stack] 里
///   （`Positioned`，列表本地坐标），随整棵子树被祖先 `Transform.scale` 统一缩放
///   → 视觉与其余缩放界面完全一致。
/// - 所有指针坐标都用本列表 `RenderBox.globalToLocal(globalPosition)` 转成**本地坐标**
///   再定位浮层。`globalToLocal` 自动消掉祖先的任意缩放/平移，故浮层在任意缩放系数下
///   都精确跟手、零偏移（无 SDK 的全局↔本地空间错配）。
///
/// 上下箭头按钮等其它重排路径不受影响（它们直接改父列表 + setState）。
class HibikiReorderableColumn extends StatefulWidget {
  const HibikiReorderableColumn({
    required this.itemCount,
    required this.itemBuilder,
    required this.keyForIndex,
    required this.onReorder,
    super.key,
  });

  final int itemCount;
  final HibikiReorderItemBuilder itemBuilder;
  final HibikiReorderKeyBuilder keyForIndex;

  /// 「item[from] 移到最终下标 to」。起拖时机按输入设备区分（见类注释）：
  /// 鼠标等精确指针按下即拖，触摸屏长按（`kLongPressTimeout`）再拖。
  final HibikiReorderCallback onReorder;

  @override
  State<HibikiReorderableColumn> createState() =>
      _HibikiReorderableColumnState();
}

class _HibikiReorderableColumnState extends State<HibikiReorderableColumn> {
  /// 显示顺序：display 位置 → 原始 index（拖拽中实时变化；提交后重置为恒等）。
  late List<int> _display;

  /// 每个原始 index 的测高 GlobalKey（行身份稳定，用于读高度）。
  final Map<int, GlobalKey> _rowKeys = <int, GlobalKey>{};

  /// 本列表根 [Stack] 的 key，用于 `globalToLocal` 把指针转成本地坐标。
  final GlobalKey _rootKey = GlobalKey();

  int? _dragOriginal; // 正在拖拽的原始 index（null = 未拖拽）
  int _dragStartDi = 0; // 起拖时被拖行的 display 下标（提交 from，不依赖「起始必恒等」）
  double _feedbackTop = 0; // 浮层复制的本地 Y（列表本地坐标）
  double _grabDy = 0; // 抓取点相对被拖行顶部的本地偏移
  final Map<int, double> _heights = <int, double>{}; // 原始 index → 行高

  @override
  void initState() {
    super.initState();
    _resetDisplay();
  }

  @override
  void didUpdateWidget(covariant HibikiReorderableColumn oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.itemCount != widget.itemCount) {
      _resetDisplay();
      _dragOriginal = null;
    }
  }

  void _resetDisplay() {
    _display = List<int>.generate(widget.itemCount, (int i) => i);
    for (int i = 0; i < widget.itemCount; i++) {
      _rowKeys.putIfAbsent(i, () => GlobalKey());
    }
    // itemCount 缩减后修剪陈旧 key/高度，避免无界增长。
    _rowKeys.removeWhere((int i, _) => i >= widget.itemCount);
    _heights.removeWhere((int i, _) => i >= widget.itemCount);
  }

  double _localY(Offset globalPosition) {
    final RenderObject? ro = _rootKey.currentContext?.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize) return globalPosition.dy;
    return ro.globalToLocal(globalPosition).dy;
  }

  /// 读取当前各行高度（长按起始时行已布局，可同步读 GlobalKey 的 size）。
  void _measureHeights() {
    for (int i = 0; i < widget.itemCount; i++) {
      final RenderObject? ro = _rowKeys[i]?.currentContext?.findRenderObject();
      if (ro is RenderBox && ro.hasSize) {
        _heights[i] = ro.size.height;
      }
    }
  }

  double _heightOf(int original) => _heights[original] ?? 0;

  /// display 位置 di 的槽顶（按当前 _display 累加高度）。
  double _slotTop(int di) {
    double top = 0;
    for (int k = 0; k < di; k++) {
      top += _heightOf(_display[k]);
    }
    return top;
  }

  double get _totalHeight {
    double h = 0;
    for (final int oi in _display) {
      h += _heightOf(oi);
    }
    return h;
  }

  void _startDrag(int original, Offset globalPosition) {
    _measureHeights();
    final int di = _display.indexOf(original);
    final double top = _slotTop(di);
    final double localY = _localY(globalPosition);
    setState(() {
      _dragOriginal = original;
      _dragStartDi = di;
      _grabDy = (localY - top).clamp(0.0, _heightOf(original));
      _feedbackTop = top;
    });
  }

  void _updateDrag(Offset globalPosition) {
    final int? dragged = _dragOriginal;
    if (dragged == null) return;
    final double draggedH = _heightOf(dragged);
    final double maxTop = (_totalHeight - draggedH).clamp(0.0, double.infinity);
    final double newTop =
        (_localY(globalPosition) - _grabDy).clamp(0.0, maxTop);

    // 浮层中心落在哪个槽 → 目标 display 下标。
    final double centerY = newTop + draggedH / 2;
    int target = _display.length - 1;
    double acc = 0;
    for (int di = 0; di < _display.length; di++) {
      final double h = _heightOf(_display[di]);
      if (centerY < acc + h / 2) {
        target = di;
        break;
      }
      acc += h;
    }

    final int currentDi = _display.indexOf(dragged);
    setState(() {
      _feedbackTop = newTop;
      if (target != currentDi) {
        _display.removeAt(currentDi);
        _display.insert(target, dragged);
      }
    });
  }

  void _endDrag() {
    final int? dragged = _dragOriginal;
    if (dragged == null) return;
    final int from = _dragStartDi; // 起拖时的 display 下标（= 父列表中的起始位置）
    final int to = _display.indexOf(dragged);
    setState(() {
      _dragOriginal = null;
      _display = List<int>.generate(widget.itemCount, (int i) => i);
    });
    if (to != from) widget.onReorder(from, to);
  }

  @override
  Widget build(BuildContext context) {
    final int? dragged = _dragOriginal;
    return Stack(
      key: _rootKey,
      children: <Widget>[
        Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (int di = 0; di < _display.length; di++)
              _buildSlot(_display[di]),
          ],
        ),
        if (dragged != null)
          Positioned(
            top: _feedbackTop,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Material(
                elevation: 6,
                color: Theme.of(context).colorScheme.surface,
                child: widget.itemBuilder(context, dragged),
              ),
            ),
          ),
      ],
    );
  }

  /// 鼠标/触控板/触控笔等**精确指针**：按下移动即拖（桌面「按住左键就能拖」）。
  static const Set<PointerDeviceKind> _immediateDragDevices =
      <PointerDeviceKind>{
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.unknown,
  };

  /// 触摸屏：长按起拖（避免与列表滚动争用，快速滑动仍交给滚动）。
  static const Set<PointerDeviceKind> _delayedDragDevices = <PointerDeviceKind>{
    PointerDeviceKind.touch,
  };

  /// 两套 MultiDrag 识别器共用的起拖入口：识别器一旦在手势竞技场胜出就回调，
  /// 返回 [_ReorderDrag] 把后续 update/end/cancel 桥接到全局坐标拖拽逻辑。
  Drag _onMultiDragStart(int original, Offset globalPosition) {
    _startDrag(original, globalPosition);
    return _ReorderDrag(onUpdate: _updateDrag, onEnd: _endDrag);
  }

  Widget _buildSlot(int original) {
    final Widget content = KeyedSubtree(
      key: _rowKeys[original],
      child: widget.itemBuilder(context, original),
    );
    // 被拖行在原位保留高度但透明（充当随实时重排移动的「空位」），可见的是浮层复制。
    final Widget slot = _dragOriginal == original
        ? Opacity(opacity: 0.0, child: content)
        : content;
    // 稳定 key（行身份）：拖拽中 _display 重排时，Flutter 据此保留同一
    // RawGestureDetector 元素与其活跃的识别器，拖拽不中断。
    return RawGestureDetector(
      key: widget.keyForIndex(original),
      behavior: HitTestBehavior.translucent,
      gestures: <Type, GestureRecognizerFactory>{
        // 鼠标等精确指针：按下即拖（修 Win 端必须长按等待才能排序）。
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
        // 触摸屏：长按再拖。
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
}

/// 把 [MultiDragGestureRecognizer] 的拖拽回调桥接到 [_HibikiReorderableColumnState]
/// 的全局坐标拖拽逻辑（`_startDrag`/`_updateDrag`/`_endDrag` 都吃全局坐标，
/// 内部再用 `globalToLocal` 消祖先缩放）。
class _ReorderDrag extends Drag {
  _ReorderDrag({required this.onUpdate, required this.onEnd});

  final void Function(Offset globalPosition) onUpdate;
  final VoidCallback onEnd;

  @override
  void update(DragUpdateDetails details) => onUpdate(details.globalPosition);

  @override
  void end(DragEndDetails details) => onEnd();

  @override
  void cancel() => onEnd();
}
