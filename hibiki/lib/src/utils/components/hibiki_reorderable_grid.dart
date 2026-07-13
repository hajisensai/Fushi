import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// 网格单元内容构造器：返回**纯视觉**卡片内容（自身手势由本组件统一接管，
/// 调用方应把卡片包在 [IgnorePointer] 里避免内部 InkWell 的 long-press 与本组件的
/// 触摸长按拖拽争用手势竞技场——详见类注释）。
typedef HibikiReorderGridItemBuilder = Widget Function(
    BuildContext context, int index);

/// 为某个 index 返回稳定 Key（单元身份，拖拽中 display 重排时保留同一
/// RawGestureDetector 元素与其活跃识别器，拖拽不中断）。
typedef HibikiReorderGridKeyBuilder = Key Function(int index);

/// 「item[from] 移到最终下标 to」——调用方实现为 `removeAt(from); insert(to, item)`。
typedef HibikiReorderGridCallback = void Function(int from, int to);

/// 单元被激活（主指针轻点，未拖拽）——用于「点卡片打开条目」。
typedef HibikiReorderGridActivate = void Function(int index);

/// 单元请求上下文菜单：桌面鼠标右键（secondary tap）/ 触摸长按后原地松手（未拖动）。
/// [globalPosition] 为触发点全局坐标，供调用方 `showMenu` 定位。
typedef HibikiReorderGridContextMenu = void Function(
    int index, Offset globalPosition);

/// 自实现的**二维**「拖拽重排」网格，专为运行在祖先 [Transform.scale]
/// （`HibikiAppUiScale` 的浏览器式整体缩放）之下而设计。是
/// [HibikiReorderableColumn]（一维竖列）的 2D 姊妹件，同一套「浮层渲染在组件自身
/// [Stack]、指针 `globalToLocal` 消缩放」机制，差异只在几何：**均匀网格**（列数由
/// 调用方传入、每卡等宽等高），拖拽中实时腾位（display 重排），目标槽 = 浮层中心所在
/// 网格坑位。
///
/// **起拖时机按输入设备区分**（与 [HibikiReorderableColumn] 一致）：
/// - 鼠标 / 触控板 / 触控笔等精确指针 → [ImmediateMultiDragGestureRecognizer]，
///   按下移动即拖（桌面「按住左键就能拖」的预期）；右键（secondary tap）→ 上下文菜单。
/// - 触摸屏 → [LongPressGestureRecognizer]：长按后**移动**才起拖（重排），长按后
///   **原地松手**（未移动）→ 上下文菜单。触摸没有右键，故长按同时承载「拿起拖拽」与
///   「弹出菜单」，用是否移动过 slop 消歧——这是触摸端唯一自洽的编排。
///
/// **为什么不用 `ReorderableListView` / pub `ReorderableGridView`**（BUG-757）：
/// SDK/pub 的拖拽代理把浮层放进 [Overlay]，用「全局坐标 − overlay 原点」纯平移定位，
/// 不认祖先 [Transform.scale]；整棵树被缩放时代理落点按 `(1−s)×距离` 漂移、缩小时
/// 一拖即飞出屏幕。本组件不借助任何 Overlay：浮层复制渲染在本网格自身 [Stack]
/// （`Positioned`，本地坐标），随子树被祖先 `Transform.scale` 统一缩放 → 视觉与其余
/// 缩放界面一致；所有指针坐标都用本 [Stack] 的 `RenderBox.globalToLocal(globalPosition)`
/// 转成本地坐标，自动消掉祖先缩放/平移，浮层任意缩放系数下都精确跟手、零偏移。
class HibikiReorderableGrid extends StatefulWidget {
  const HibikiReorderableGrid({
    required this.itemCount,
    required this.crossAxisCount,
    required this.childAspectRatio,
    required this.itemBuilder,
    required this.keyForIndex,
    required this.onReorder,
    this.crossAxisSpacing = 0,
    this.mainAxisSpacing = 0,
    this.onActivateItem,
    this.onContextMenu,
    this.feedbackBorderRadius,
    super.key,
  });

  final int itemCount;

  /// 列数（每卡等宽等高，由调用方按可用宽度算好后传入）。
  final int crossAxisCount;

  /// 单元宽 / 单元高（如 160/260），用于从列宽推导行高。
  final double childAspectRatio;

  final HibikiReorderGridItemBuilder itemBuilder;
  final HibikiReorderGridKeyBuilder keyForIndex;

  /// 「item[from] 移到最终下标 to」。起拖时机按输入设备区分（见类注释）。
  final HibikiReorderGridCallback onReorder;

  final double crossAxisSpacing;
  final double mainAxisSpacing;

  /// 主指针轻点单元（未拖拽）回调（点卡片打开条目）；null = 不接管主轻点。
  final HibikiReorderGridActivate? onActivateItem;

  /// 上下文菜单回调（右键 / 触摸长按原地松手）；null = 不提供菜单。
  final HibikiReorderGridContextMenu? onContextMenu;

  /// 拖拽浮层复制的圆角（裁切到此半径）；null = 直角。
  final BorderRadius? feedbackBorderRadius;

  @override
  State<HibikiReorderableGrid> createState() => _HibikiReorderableGridState();
}

class _HibikiReorderableGridState extends State<HibikiReorderableGrid> {
  /// 显示顺序：display 位置 → 原始 index（拖拽中实时变化；提交后重置为恒等）。
  late List<int> _display;

  /// 本网格根 [Stack] 的 key，用于 `globalToLocal` 把指针转成本地坐标（消缩放）。
  final GlobalKey _rootKey = GlobalKey();

  int? _dragOriginal; // 正在拖拽的原始 index（null = 未拖拽 / 未起拖）
  int _dragStartDi = 0; // 起拖时被拖单元的 display 下标（提交 from）
  Offset _grab = Offset.zero; // 抓取点相对被拖单元左上角的本地偏移
  Offset _feedbackTopLeft = Offset.zero; // 浮层复制的本地左上角（列表本地坐标）

  // 当前布局几何（每次 build 由 LayoutBuilder 刷新）。
  double _cellW = 0;
  double _cellH = 0;

  // 触摸长按态：起拖前先记录、移动过 slop 才真正起拖，松手时据是否移动过决定
  // 「提交重排」还是「弹出上下文菜单」。
  int? _touchPendingOriginal;
  Offset _touchStartGlobal = Offset.zero;
  bool _touchMoved = false;

  // ── 拖拽近视口边缘自动滚动（本网格常挂在 SingleChildScrollView 内，成员超一屏时
  //    需能把浮层拖到视口外的槽位）。起拖时抓最近的祖先 [ScrollableState]，指针进入
  //    视口上/下边缘带就按帧步进 [ScrollPosition.jumpTo]，滚动后用最近一次指针全局
  //    坐标重跑 [_applyDragAt]（`globalToLocal` 已消滚动位移，浮层/目标槽随内容自洽）。
  //    无祖先 Scrollable（如离屏测试）时 [_scrollable] 为 null，整段降级为不滚动。──
  ScrollableState? _scrollable;
  Offset _lastPointerGlobal = Offset.zero;
  double _autoScrollStepSigned = 0; // 当前每帧步进（含方向）；0 = 不滚
  bool _autoScrollScheduled = false;

  /// 触发自动滚动的视口上/下边缘带宽（指针进入即滚）。
  static const double _autoScrollEdge = 64.0;

  /// 自动滚动每帧步进（像素）。
  static const double _autoScrollStep = 16.0;

  @override
  void initState() {
    super.initState();
    _resetDisplay();
  }

  @override
  void didUpdateWidget(covariant HibikiReorderableGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.itemCount != widget.itemCount) {
      _resetDisplay();
      _dragOriginal = null;
      _touchPendingOriginal = null;
    }
  }

  void _resetDisplay() {
    _display = List<int>.generate(widget.itemCount, (int i) => i);
  }

  int get _cols => widget.crossAxisCount < 1 ? 1 : widget.crossAxisCount;

  int get _rowCount =>
      widget.itemCount == 0 ? 0 : ((widget.itemCount + _cols - 1) ~/ _cols);

  double get _totalHeight {
    final int rows = _rowCount;
    if (rows == 0) return 0;
    return rows * _cellH + widget.mainAxisSpacing * (rows - 1);
  }

  Offset _localOffset(Offset globalPosition) {
    final RenderObject? ro = _rootKey.currentContext?.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize) return globalPosition;
    return ro.globalToLocal(globalPosition);
  }

  /// display 位置 di 的单元左上角（列主序：col = di%cols, row = di~/cols）。
  Offset _slotTopLeft(int di) {
    final int col = di % _cols;
    final int row = di ~/ _cols;
    return Offset(
      col * (_cellW + widget.crossAxisSpacing),
      row * (_cellH + widget.mainAxisSpacing),
    );
  }

  /// 浮层中心所在网格坑位 → 目标 display 下标（列/行各自 floor 后合成，clamp 到界内）。
  int _targetSlot(Offset feedbackTopLeft) {
    final Offset center = feedbackTopLeft + Offset(_cellW / 2, _cellH / 2);
    final double colStride = _cellW + widget.crossAxisSpacing;
    final double rowStride = _cellH + widget.mainAxisSpacing;
    int col = colStride <= 0 ? 0 : (center.dx / colStride).floor();
    int row = rowStride <= 0 ? 0 : (center.dy / rowStride).floor();
    col = col.clamp(0, _cols - 1);
    row = row.clamp(0, (_rowCount - 1).clamp(0, 1 << 30));
    final int di = row * _cols + col;
    return di.clamp(0, _display.length - 1);
  }

  /// 起拖：记录被拖单元、以起拖全局坐标算出抓取偏移、把浮层放到该单元当前槽位。
  void _beginDrag(int original, Offset startGlobal) {
    final int di = _display.indexOf(original);
    if (di < 0) return;
    final Offset slot = _slotTopLeft(di);
    final Offset startLocal = _localOffset(startGlobal);
    // 抓最近的祖先 Scrollable（不建依赖，避免每次页面滚动都重建本网格）；无则不滚。
    _scrollable = context.findAncestorStateOfType<ScrollableState>();
    _lastPointerGlobal = startGlobal;
    setState(() {
      _dragOriginal = original;
      _dragStartDi = di;
      _grab = Offset(
        (startLocal.dx - slot.dx).clamp(0.0, _cellW),
        (startLocal.dy - slot.dy).clamp(0.0, _cellH),
      );
      _feedbackTopLeft = slot;
    });
  }

  void _updateDrag(Offset globalPosition) {
    if (_dragOriginal == null) return;
    _lastPointerGlobal = globalPosition;
    _applyDragAt(globalPosition);
    _maybeAutoScroll(globalPosition);
  }

  /// 按给定全局指针坐标定位浮层 + 实时腾位（起拖后每次指针移动、以及自动滚动每帧
  /// 各调一次）。指针经根 [Stack] 的 `globalToLocal` 转本地坐标，自动消祖先缩放/滚动。
  void _applyDragAt(Offset globalPosition) {
    if (_dragOriginal == null) return;
    final Offset local = _localOffset(globalPosition);
    final double maxX =
        (_cols * _cellW + widget.crossAxisSpacing * (_cols - 1) - _cellW)
            .clamp(0.0, double.infinity);
    final double maxY = (_totalHeight - _cellH).clamp(0.0, double.infinity);
    final Offset topLeft = Offset(
      (local.dx - _grab.dx).clamp(0.0, maxX),
      (local.dy - _grab.dy).clamp(0.0, maxY),
    );
    final int target = _targetSlot(topLeft);
    final int currentDi = _display.indexOf(_dragOriginal!);
    setState(() {
      _feedbackTopLeft = topLeft;
      if (target != currentDi && target >= 0) {
        _display.removeAt(currentDi);
        _display.insert(target, _dragOriginal!);
      }
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
      _resetDisplay();
    });
    if (to != from && to >= 0) widget.onReorder(from, to);
  }

  /// 拖拽被取消（手势竞技场夺走指针 / 路由销毁）：放弃本次重排、复位原序，
  /// **不提交 onReorder**（中间态非用户最终意图）。守 mounted 防 dispose 期 setState。
  void _cancelDrag() {
    if (_dragOriginal == null) return;
    _stopAutoScroll();
    if (!mounted) {
      _dragOriginal = null;
      return;
    }
    setState(() {
      _dragOriginal = null;
      _resetDisplay();
    });
  }

  /// 指针近视口边缘则设定本帧步进并驱动帧循环；离开边缘带 / 到滚动界则停。
  void _maybeAutoScroll(Offset globalPosition) {
    final ScrollableState? sc = _scrollable;
    if (sc == null || !sc.mounted) {
      _autoScrollStepSigned = 0;
      return;
    }
    final RenderObject? ro = sc.context.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize) {
      _autoScrollStepSigned = 0;
      return;
    }
    final ScrollPosition pos = sc.position;
    final Rect viewport = ro.localToGlobal(Offset.zero) & ro.size;
    double step = 0;
    if (globalPosition.dy < viewport.top + _autoScrollEdge &&
        pos.pixels > pos.minScrollExtent) {
      step = -_autoScrollStep;
    } else if (globalPosition.dy > viewport.bottom - _autoScrollEdge &&
        pos.pixels < pos.maxScrollExtent) {
      step = _autoScrollStep;
    }
    _autoScrollStepSigned = step;
    if (step != 0 && !_autoScrollScheduled) {
      _autoScrollScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback(_autoScrollTick);
    }
  }

  /// 帧回调：滚动一步 → 用最近一次指针坐标重跑拖拽（浮层/目标槽随内容自洽）→
  /// 重新评估边缘带决定是否续帧。拖拽已结束 / 已 unmount / 已到滚动界即停。
  void _autoScrollTick(Duration _) {
    _autoScrollScheduled = false;
    if (!mounted || _dragOriginal == null || _autoScrollStepSigned == 0) return;
    final ScrollableState? sc = _scrollable;
    if (sc == null || !sc.mounted) return;
    final ScrollPosition pos = sc.position;
    final double next = (pos.pixels + _autoScrollStepSigned)
        .clamp(pos.minScrollExtent, pos.maxScrollExtent);
    if (next != pos.pixels) pos.jumpTo(next);
    _applyDragAt(_lastPointerGlobal);
    _maybeAutoScroll(_lastPointerGlobal);
  }

  void _stopAutoScroll() {
    _autoScrollStepSigned = 0;
    _scrollable = null;
  }

  // ── 触摸长按：起拖前先待命，移动过 slop 才起拖，原地松手→菜单 ──────────────
  void _touchLongPressStart(int original, LongPressStartDetails d) {
    _touchPendingOriginal = original;
    _touchStartGlobal = d.globalPosition;
    _touchMoved = false;
  }

  void _touchLongPressMove(int original, LongPressMoveUpdateDetails d) {
    if (_touchPendingOriginal != original) return;
    if (!_touchMoved) {
      if (d.offsetFromOrigin.distance <= kTouchSlop) return;
      _touchMoved = true;
      _beginDrag(original, _touchStartGlobal);
    }
    _updateDrag(d.globalPosition);
  }

  void _touchLongPressEnd(int original, LongPressEndDetails d) {
    if (_touchPendingOriginal != original) return;
    _touchPendingOriginal = null;
    if (_touchMoved) {
      _endDrag();
    } else {
      widget.onContextMenu?.call(original, d.globalPosition);
    }
    _touchMoved = false;
  }

  /// 触摸长按被系统取消（通知栏下拉 / 来电 / 切后台等发 PointerCancel，或竞技场把
  /// 指针夺走）：清待命态并复位本次拖拽，**不提交 onReorder**（中间态非用户最终意图）。
  /// 不接此路径时，取消后残留的 _touchPendingOriginal/_dragOriginal/_display 会留下幽灵
  /// 浮层，且下次起拖 _dragStartDi 在错乱 display 上取值 → onReorder 提交错误 from → 错序
  /// 写穿 DB。SDK 的 LongPressGestureRecognizer 在长按已接受（起拖中）时收到 PointerCancel
  /// 仍会回调 onLongPressCancel（state 仍为 possible），故此路径覆盖「拖拽中被系统取消」。
  void _touchLongPressCancel(int original) {
    if (_touchPendingOriginal != original) return;
    _touchPendingOriginal = null;
    _touchMoved = false;
    _cancelDrag(); // _dragOriginal==null（待命未移动即取消）时为 no-op
  }

  /// 鼠标等精确指针：按下移动即拖。
  Drag _onMouseDragStart(int original, Offset globalPosition) {
    _beginDrag(original, globalPosition);
    return _ReorderGridDrag(
      onUpdate: _updateDrag,
      onEnd: _endDrag,
      onCancel: _cancelDrag,
    );
  }

  static const Set<PointerDeviceKind> _immediateDragDevices =
      <PointerDeviceKind>{
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.unknown,
  };

  static const Set<PointerDeviceKind> _touchDragDevices = <PointerDeviceKind>{
    PointerDeviceKind.touch,
  };

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double totalW = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : (_cellW * _cols + widget.crossAxisSpacing * (_cols - 1));
        _cellW = (totalW - widget.crossAxisSpacing * (_cols - 1)) / _cols;
        if (_cellW < 0) _cellW = 0;
        _cellH = widget.childAspectRatio <= 0
            ? _cellW
            : _cellW / widget.childAspectRatio;
        final int? dragged = _dragOriginal;
        return SizedBox(
          width: totalW,
          height: _totalHeight,
          child: Stack(
            key: _rootKey,
            children: <Widget>[
              for (int di = 0; di < _display.length; di++)
                // key 必须放在 Stack 的**直接**子节点 [Positioned] 上：`_display` 拖拽
                // 重排时 Stack 据此按身份匹配元素、保留同一 RawGestureDetector 与其
                // 活跃拖拽识别器（否则 Positioned 无 key → 按位置匹配 → 内层带 key 的
                // 识别器被重建 → 活跃拖拽中断，第二次移动丢失）。
                Positioned.fromRect(
                  key: widget.keyForIndex(_display[di]),
                  rect: _slotTopLeft(di) & Size(_cellW, _cellH),
                  child: _buildCell(_display[di]),
                ),
              if (dragged != null)
                Positioned.fromRect(
                  key: const ValueKey<String>('__reorder_grid_feedback__'),
                  rect: _feedbackTopLeft & Size(_cellW, _cellH),
                  child: IgnorePointer(
                    child: Material(
                      elevation: 6,
                      color: Colors.transparent,
                      borderRadius: widget.feedbackBorderRadius,
                      clipBehavior: widget.feedbackBorderRadius != null
                          ? Clip.antiAlias
                          : Clip.none,
                      child: widget.itemBuilder(context, dragged),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCell(int original) {
    final Widget content = widget.itemBuilder(context, original);
    // 被拖单元在原位保留占位但透明（充当随实时重排移动的「空位」），可见的是浮层。
    final Widget slot = _dragOriginal == original
        ? Opacity(opacity: 0, child: content)
        : content;
    // 身份 key 已放在外层 [Positioned]（Stack 直接子节点）上，重排时保留本
    // RawGestureDetector 与其活跃识别器；此处不再重复挂 key。
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: <Type, GestureRecognizerFactory>{
        // 主轻点 → 激活；右键 secondary tap → 上下文菜单。
        TapGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
          () => TapGestureRecognizer(),
          (TapGestureRecognizer instance) {
            final HibikiReorderGridActivate? activate = widget.onActivateItem;
            final HibikiReorderGridContextMenu? menu = widget.onContextMenu;
            instance.onTap = activate == null ? null : () => activate(original);
            instance.onSecondaryTapUp = menu == null
                ? null
                : (TapUpDetails d) => menu(original, d.globalPosition);
          },
        ),
        // 鼠标等精确指针：按下即拖。
        ImmediateMultiDragGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<
                ImmediateMultiDragGestureRecognizer>(
          () => ImmediateMultiDragGestureRecognizer(
              supportedDevices: _immediateDragDevices),
          (ImmediateMultiDragGestureRecognizer instance) {
            instance.onStart =
                (Offset position) => _onMouseDragStart(original, position);
          },
        ),
        // 触摸屏：长按待命，移动过 slop 起拖，原地松手弹菜单。
        LongPressGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
          () => LongPressGestureRecognizer(supportedDevices: _touchDragDevices),
          (LongPressGestureRecognizer instance) {
            instance.onLongPressStart =
                (LongPressStartDetails d) => _touchLongPressStart(original, d);
            instance.onLongPressMoveUpdate = (LongPressMoveUpdateDetails d) =>
                _touchLongPressMove(original, d);
            instance.onLongPressEnd =
                (LongPressEndDetails d) => _touchLongPressEnd(original, d);
            // 系统取消指针（通知栏下拉/来电/切后台）→ 清待命 + 复位拖拽（防幽灵浮层
            // 与下次错序提交）。
            instance.onLongPressCancel = () => _touchLongPressCancel(original);
          },
        ),
      },
      child: slot,
    );
  }
}

/// 把 [MultiDragGestureRecognizer] 的拖拽回调桥接到 [_HibikiReorderableGridState]
/// 的全局坐标拖拽逻辑（内部再用 `globalToLocal` 消祖先缩放）。
class _ReorderGridDrag extends Drag {
  _ReorderGridDrag({
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
