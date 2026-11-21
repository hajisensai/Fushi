/// 首页小组件网格（spec `docs/specs/2026-11-15-home-widgets-design.md`）。
///
/// 按 [packHomeWidgets] 的装箱结果把每块放进固定尺寸的格子（行高
/// [homeWidgetRowExtent]、间距与库页色块同档 [kFushiCoverBlockSpacing]，RTL 镜像列）。
/// 增删 / 换位 / 换尺寸后各块按新装箱结果滑到新位置（时长只取 [FushiMotion]）。
///
/// 编辑态（[HomeWidgetGrid.editing]）：
/// - 组件内容不响应点击、不进焦点遍历；每块整体是一个焦点停靠点；
/// - 左上「−」移除；右下角是改尺寸的柄：拖动按格吸附（实时预览框 +「3×2」标签，
///   其余块按装箱结果让位，松手提交、进撤销栈），点按弹出尺寸选择网格
///   （[showHomeWidgetSizePicker]）；
/// - 长按拖动换位：拿起的块抬起跟手，原装箱位置画虚线占位，其余块按装箱让位；
/// - 键盘：Enter 拿起 / 放下；拿着时方向键移动（左右 = 列表前后一位，上下 = 装箱后
///   上 / 下一行最近的位置）；Shift+方向键逐格改宽 / 高；Delete 移除；Esc 放下（拿着
///   时）或退出编辑（没拿着时）。
/// - 手柄（经 [GamepadButtonIntent]，不认的键转发给祖先）：A 拿起 / 放下，拿着时
///   十字键移动；LB / RB 减 / 加宽，LT / RT 减 / 加高；X 移除；B 同 Esc。
/// - Apple 设计系统：编辑态轻微抖动（iOS 主屏式），「减少动态效果」/ 墨水屏下不抖；
///   墨水屏：编辑态实线框，拿起不缩放不加阴影、改为加粗边框。
///
/// 网格只认「可见」列表（不可用的组件由页面先滤掉），回调里的下标都是这份列表的下标。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/home_widget_layout.dart';
import 'package:fushi/src/pages/implementations/home_widget_size_picker.dart';
import 'package:fushi/src/shortcuts/gamepad_forwarding_action.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart'
    show GamepadButtonIntent;
import 'package:fushi/src/shortcuts/input_binding.dart' show GamepadButton;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_cover_block_layout.dart'
    show kFushiCoverBlockSpacing;
import 'package:fushi/src/focus/fushi_focus_scroll.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiTooltip;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 设置 › 导航与首页 ›「编辑首页」：置 true 后首页（切到首页 tab 时）进入编辑态并
/// 把它清回 false。
final ValueNotifier<bool> homeWidgetEditRequested = ValueNotifier<bool>(false);

/// 一块小组件的内容。格子是紧约束，内容按实际宽高（LayoutBuilder）自己排版。
typedef HomeWidgetCellBuilder =
    Widget Function(BuildContext context, HomeWidgetItem item);

/// 格子里一块小组件的测试 / 定位 key（可重复的组件按 [language] 区分，见
/// [homeWidgetSlot]）。
ValueKey<String> homeWidgetTileKey(HomeWidgetKind kind, {String? language}) =>
    ValueKey<String>('home-widget/${homeWidgetSlot(kind, language: language)}');

class HomeWidgetGrid extends StatefulWidget {
  const HomeWidgetGrid({
    super.key,
    required this.items,
    required this.grid,
    required this.editing,
    required this.cellBuilder,
    required this.labelOf,
    required this.onEnterEdit,
    required this.onExitEdit,
    required this.onMove,
    required this.onRemove,
    required this.onResize,
    this.onConfigure,
    this.revealSlot,
    this.onRevealed,
  });

  /// 可见组件，按布局顺序。
  final List<HomeWidgetItem> items;
  final HomeGridKind grid;
  final bool editing;
  final HomeWidgetCellBuilder cellBuilder;

  /// 组件名（读屏 / 提示用；可配置的组件带上配置）。
  final String Function(HomeWidgetItem item) labelOf;

  /// 非编辑态长按任意组件：进入编辑态。
  final VoidCallback onEnterEdit;

  /// 编辑态没拿着组件时按 Esc / B：退出编辑（落盘）。
  final VoidCallback onExitEdit;

  /// 把第 [from] 块挪到第 [to] 位（可见列表下标）。
  final void Function(int from, int to) onMove;

  /// 移除第 [index] 块。
  final void Function(int index) onRemove;

  /// 第 [index] 块改成 [size]（网格已钳进可调范围）。
  final void Function(int index, HomeWidgetSize size) onResize;

  /// 改第 [index] 块的配置（「语言目标」格的语言）；只对可重复的组件
  /// （[HomeWidgetKind.repeatable]）出现右上角标 / 手柄 Y / 菜单键。
  final void Function(int index)? onConfigure;

  /// 非空：下一帧把这块（[HomeWidgetItem.slot]）滚进视野（刚添加的组件），完成后
  /// 回调 [onRevealed]。
  final String? revealSlot;
  final VoidCallback? onRevealed;

  @override
  State<HomeWidgetGrid> createState() => _HomeWidgetGridState();
}

class _HomeWidgetGridState extends State<HomeWidgetGrid>
    with SingleTickerProviderStateMixin {
  final Map<String, FocusNode> _focusNodes =
      <String, FocusNode>{};
  final Map<String, GlobalKey> _tileKeys =
      <String, GlobalKey>{};
  final GlobalKey _stackKey = GlobalKey();

  /// 键盘 / 手柄拿起的组件。
  String? _lifted;

  /// 指针拖动中的组件、它当前的目标下标、跟手位置（网格坐标里的左上角）与按下点
  /// 在块内的偏移。
  String? _dragKind;
  int? _dragTarget;
  Offset _dragTopLeft = Offset.zero;
  Offset _dragGrab = Offset.zero;

  /// 拖右下角改尺寸中的组件、按下时的尺寸、累计位移（逻辑方向）与吸附后的目标。
  String? _resizeKind;
  HomeWidgetSize? _resizeStart;
  Offset _resizeDelta = Offset.zero;
  HomeWidgetSize? _resizePreview;

  /// 最近一次排版的单格宽 / 行高（拖角吸附用；只在 build 里写，不触发重建）。
  double _colWidth = 0;
  double _rowExtent = 0;

  /// Apple 编辑态抖动。
  late final AnimationController _jiggle = AnimationController(
    vsync: this,
    duration: FushiMotion.long,
  );

  FocusNode _nodeOf(String kind) => _focusNodes.putIfAbsent(
    kind,
    () => FocusNode(debugLabel: 'home-widget/$kind'),
  );

  GlobalKey _tileKeyOf(String kind) =>
      _tileKeys.putIfAbsent(kind, GlobalKey.new);

  @override
  void didUpdateWidget(HomeWidgetGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.editing) {
      _lifted = null;
      _dragKind = null;
      _dragTarget = null;
      _resizeKind = null;
      _resizePreview = null;
    }
    final Set<String> present = <String>{
      for (final HomeWidgetItem e in widget.items) e.slot,
    };
    if (_lifted != null && !present.contains(_lifted)) _lifted = null;
    _focusNodes.removeWhere((String k, FocusNode n) {
      if (present.contains(k)) return false;
      n.dispose();
      return true;
    });
    _tileKeys.removeWhere(
      (String k, GlobalKey _) => !present.contains(k),
    );
  }

  @override
  void dispose() {
    _jiggle.dispose();
    for (final FocusNode n in _focusNodes.values) {
      n.dispose();
    }
    super.dispose();
  }

  void _syncJiggle(bool on) {
    if (on) {
      if (!_jiggle.isAnimating) _jiggle.repeat(reverse: true);
    } else if (_jiggle.isAnimating || _jiggle.value != 0) {
      _jiggle
        ..stop()
        ..value = 0;
    }
  }

  void _scheduleReveal() {
    final String? kind = widget.revealSlot;
    if (kind == null) return;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      final BuildContext? tile = _tileKeys[kind]?.currentContext;
      if (tile != null) {
        FushiFocusScroll.ensureVisible(
          tile,
          duration: fushiMotionDuration(context, FushiMotion.medium),
          curve: FushiMotion.standard,
          alignment: 0.3,
        );
        _focusNodes[kind]?.requestFocus();
      }
      widget.onRevealed?.call();
    });
  }

  int _indexOf(String kind) =>
      widget.items.indexWhere((HomeWidgetItem e) => e.slot == kind);

  void _remove(String kind) {
    final int index = _indexOf(kind);
    if (index < 0) return;
    // 焦点交给后一块（没有就前一块），不让焦点掉出网格。
    final List<HomeWidgetItem> items = widget.items;
    final String? next = index + 1 < items.length
        ? items[index + 1].slot
        : (index > 0 ? items[index - 1].slot : null);
    if (_lifted == kind) _lifted = null;
    widget.onRemove(index);
    if (next != null) {
      WidgetsBinding.instance.addPostFrameCallback((Duration _) {
        if (mounted) _focusNodes[next]?.requestFocus();
      });
    }
  }

  bool _configurable(HomeWidgetItem item) =>
      widget.onConfigure != null && item.kind.repeatable;

  /// 改配置（「语言目标」格的语言）：角标点按、手柄 Y、键盘菜单键。
  void _configure(String kind) {
    final int index = _indexOf(kind);
    if (index < 0 || !_configurable(widget.items[index])) return;
    if (_lifted == kind) setState(() => _lifted = null);
    widget.onConfigure?.call(index);
  }

  KeyEventResult _onKey(String kind, KeyEvent event) {
    if (!widget.editing) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    final int index = _indexOf(kind);
    if (index < 0) return KeyEventResult.ignored;
    final bool lifted = _lifted == kind;
    if (event is KeyDownEvent) {
      if (key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter ||
          key == LogicalKeyboardKey.select) {
        setState(() => _lifted = lifted ? null : kind);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.escape) {
        _back(kind);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.delete ||
          key == LogicalKeyboardKey.backspace) {
        _remove(kind);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.contextMenu &&
          _configurable(widget.items[index])) {
        _configure(kind);
        return KeyEventResult.handled;
      }
    }
    final _Direction? direction = switch (key) {
      LogicalKeyboardKey.arrowLeft => _Direction.left,
      LogicalKeyboardKey.arrowRight => _Direction.right,
      LogicalKeyboardKey.arrowUp => _Direction.up,
      LogicalKeyboardKey.arrowDown => _Direction.down,
      _ => null,
    };
    if (direction == null) return KeyEventResult.ignored;
    if (HardwareKeyboard.instance.isShiftPressed) {
      // Shift+方向键：逐格改宽 / 高（左右按阅读方向，RTL 镜像）。
      final bool rtl = Directionality.of(context) == TextDirection.rtl;
      switch (direction) {
        case _Direction.left:
          _resizeBy(kind, dCols: rtl ? 1 : -1);
        case _Direction.right:
          _resizeBy(kind, dCols: rtl ? -1 : 1);
        case _Direction.up:
          _resizeBy(kind, dRows: -1);
        case _Direction.down:
          _resizeBy(kind, dRows: 1);
      }
      return KeyEventResult.handled;
    }
    if (!lifted) return KeyEventResult.ignored;
    _moveLifted(kind, direction);
    // 拿着时方向键只移动、不让焦点跑到别的块上。
    return KeyEventResult.handled;
  }

  /// Esc / B：拿着时放下，否则退出编辑。
  void _back(String kind) {
    if (_lifted == kind) {
      setState(() => _lifted = null);
    } else {
      widget.onExitEdit();
    }
  }

  /// 拿着的块按方向移动（左右 = 列表前后一位，上下 = 装箱后上 / 下一行最近处）。
  void _moveLifted(String kind, _Direction direction) {
    final int index = _indexOf(kind);
    if (index < 0) return;
    final bool rtl = Directionality.of(context) == TextDirection.rtl;
    final int target = switch (direction) {
      _Direction.left => index + (rtl ? 1 : -1),
      _Direction.right => index + (rtl ? -1 : 1),
      _Direction.up || _Direction.down => homeWidgetVerticalTarget(
        widget.items,
        index,
        widget.grid.columns,
        up: direction == _Direction.up,
      ),
    };
    final int clamped = target.clamp(0, widget.items.length - 1);
    if (clamped != index) widget.onMove(index, clamped);
  }

  /// 逐格改尺寸（键盘 Shift+方向键 / 手柄肩键扳机）。
  void _resizeBy(String kind, {int dCols = 0, int dRows = 0}) {
    final int index = _indexOf(kind);
    if (index < 0) return;
    final List<HomeWidgetItem> next = resizeHomeWidgetBy(
      widget.items,
      index,
      widget.grid,
      dCols: dCols,
      dRows: dRows,
    );
    if (identical(next, widget.items)) return;
    widget.onResize(index, next[index].size);
  }

  /// 手柄（[GamepadButtonIntent]，桌面轮询与 Android 原生按键同一条路）：编辑态下
  /// 消费 A / B / X / LB / RB / LT / RT（拿着时再加十字键），其余交还祖先。
  bool _onGamepad(String kind, GamepadButton button) {
    if (!widget.editing || _indexOf(kind) < 0) return false;
    final bool lifted = _lifted == kind;
    switch (button) {
      case GamepadButton.a:
        setState(() => _lifted = lifted ? null : kind);
        return true;
      case GamepadButton.b:
        _back(kind);
        return true;
      case GamepadButton.x:
        _remove(kind);
        return true;
      case GamepadButton.y when _configurable(widget.items[_indexOf(kind)]):
        _configure(kind);
        return true;
      case GamepadButton.lb:
        _resizeBy(kind, dCols: -1);
        return true;
      case GamepadButton.rb:
        _resizeBy(kind, dCols: 1);
        return true;
      case GamepadButton.lt:
        _resizeBy(kind, dRows: -1);
        return true;
      case GamepadButton.rt:
        _resizeBy(kind, dRows: 1);
        return true;
      case GamepadButton.dpadLeft when lifted:
        _moveLifted(kind, _Direction.left);
        return true;
      case GamepadButton.dpadRight when lifted:
        _moveLifted(kind, _Direction.right);
        return true;
      case GamepadButton.dpadUp when lifted:
        _moveLifted(kind, _Direction.up);
        return true;
      case GamepadButton.dpadDown when lifted:
        _moveLifted(kind, _Direction.down);
        return true;
      default:
        return false;
    }
  }

  // ── 改尺寸：拖右下角 / 点柄弹网格 ─────────────────────────────────────────

  void _resizeStartDrag(String kind) {
    final int index = _indexOf(kind);
    if (index < 0) return;
    final HomeWidgetSize start = clampHomeWidgetSize(
      widget.items[index].kind,
      widget.grid,
      widget.items[index].size,
    );
    setState(() {
      _lifted = null;
      _dragKind = null;
      _dragTarget = null;
      _resizeKind = kind;
      _resizeStart = start;
      _resizeDelta = Offset.zero;
      _resizePreview = start;
    });
  }

  void _resizeUpdateDrag(Offset delta) {
    final String? kind = _resizeKind;
    final HomeWidgetSize? start = _resizeStart;
    if (kind == null || start == null) return;
    final bool rtl = Directionality.of(context) == TextDirection.rtl;
    _resizeDelta += Offset(rtl ? -delta.dx : delta.dx, delta.dy);
    final int index = _indexOf(kind);
    if (index < 0) return;
    final HomeWidgetSize next = homeWidgetDragSize(
      kind: widget.items[index].kind,
      grid: widget.grid,
      start: start,
      dx: _resizeDelta.dx,
      dy: _resizeDelta.dy,
      columnExtent: _colWidth,
      rowExtent: _rowExtent,
      gap: kFushiCoverBlockSpacing,
    );
    if (next != _resizePreview) setState(() => _resizePreview = next);
  }

  void _resizeEndDrag({required bool commit}) {
    final String? kind = _resizeKind;
    final HomeWidgetSize? start = _resizeStart;
    final HomeWidgetSize? preview = _resizePreview;
    setState(() {
      _resizeKind = null;
      _resizeStart = null;
      _resizePreview = null;
      _resizeDelta = Offset.zero;
    });
    if (!commit || kind == null || preview == null || preview == start) {
      return;
    }
    final int index = _indexOf(kind);
    if (index >= 0) widget.onResize(index, preview);
  }

  Future<void> _openSizePicker(String kind) async {
    final int index = _indexOf(kind);
    if (index < 0) return;
    final HomeWidgetSize? picked = await showHomeWidgetSizePicker(
      context,
      kind: widget.items[index].kind,
      grid: widget.grid,
      current: widget.items[index].size,
      label: '${t.home_widget_resize} · ${widget.labelOf(widget.items[index])}',
    );
    if (picked == null || !mounted || !widget.editing) return;
    final int now = _indexOf(kind);
    if (now >= 0 && widget.items[now].size != picked) {
      widget.onResize(now, picked);
    }
    _focusNodes[kind]?.requestFocus();
  }

  // ── 指针拖动 ────────────────────────────────────────────────────────────

  void _dragStart(
    String kind,
    LongPressStartDetails details,
    Rect slot,
  ) {
    // 按在改尺寸柄上：柄自己接管（它的手势在竞技场里先赢），这里不起换位拖动。
    if (_resizeKind != null) return;
    setState(() {
      _lifted = null;
      _dragKind = kind;
      _dragTarget = _indexOf(kind);
      _dragGrab = details.localPosition;
      _dragTopLeft = slot.topLeft;
    });
  }

  void _dragUpdate(LongPressMoveUpdateDetails details, List<_Slot> displayed) {
    final RenderBox? box =
        _stackKey.currentContext?.findRenderObject() as RenderBox?;
    final String? kind = _dragKind;
    if (box == null || kind == null) return;
    final Offset local = box.globalToLocal(details.globalPosition);
    int? target = _dragTarget;
    for (final _Slot s in displayed) {
      if (s.rect.contains(local)) {
        target = s.kind == kind ? target : _indexOf(s.kind);
        break;
      }
    }
    if (displayed.isNotEmpty &&
        local.dy > displayed.map((_Slot s) => s.rect.bottom).reduce(math.max)) {
      target = widget.items.length - 1;
    }
    setState(() {
      _dragTopLeft = local - _dragGrab;
      _dragTarget = target;
    });
  }

  void _dragEnd() {
    final String? kind = _dragKind;
    final int? target = _dragTarget;
    setState(() {
      _dragKind = null;
      _dragTarget = null;
    });
    if (kind == null || target == null) return;
    final int from = _indexOf(kind);
    if (from >= 0 && from != target) widget.onMove(from, target);
  }

  @override
  Widget build(BuildContext context) {
    final bool motion = fushiMotionEnabled(context);
    final bool apple = isGlassDesign(context);
    _syncJiggle(widget.editing && apple && motion);
    _scheduleReveal();
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        const double gap = kFushiCoverBlockSpacing;
        final int columns = widget.grid.columns;
        final double rowExtent = homeWidgetRowExtent(widget.grid, width, gap);
        final double colWidth = (width - gap * (columns - 1)) / columns;
        _colWidth = colWidth;
        _rowExtent = rowExtent;
        final bool rtl = Directionality.of(context) == TextDirection.rtl;

        final String? dragKind = _dragKind;
        final int dragFrom = dragKind == null ? -1 : _indexOf(dragKind);
        List<HomeWidgetItem> shown = dragFrom >= 0 && _dragTarget != null
            ? moveHomeWidget(widget.items, dragFrom, _dragTarget!)
            : widget.items;
        // 拖角改尺寸中：按吸附后的目标尺寸装箱，其余块按结果让位。
        final String? resizeKind = _resizeKind;
        final HomeWidgetSize? resizePreview = _resizePreview;
        if (resizeKind != null && resizePreview != null) {
          final int at = shown.indexWhere(
            (HomeWidgetItem e) => e.slot == resizeKind,
          );
          if (at >= 0) {
            shown = <HomeWidgetItem>[...shown]
              ..[at] = shown[at].withSize(resizePreview);
          }
        }
        final HomeWidgetPacking packing = packHomeWidgets(shown, columns);
        Rect rectOf(HomeWidgetPlacement p) {
          final double w = p.cols * colWidth + (p.cols - 1) * gap;
          final double h = p.rows * rowExtent + (p.rows - 1) * gap;
          final double start = p.col * (colWidth + gap);
          final double left = rtl ? width - start - w : start;
          return Rect.fromLTWH(left, p.row * (rowExtent + gap), w, h);
        }

        final List<_Slot> slots = <_Slot>[
          for (final HomeWidgetPlacement p in packing.placements)
            _Slot(p.item.slot, rectOf(p)),
        ];
        final double height = packing.rowCount == 0
            ? 0
            : packing.rowCount * rowExtent + (packing.rowCount - 1) * gap;
        final Duration slide = fushiMotionDuration(context, FushiMotion.medium);
        final List<Widget> children = <Widget>[];
        Widget? dragged;
        Widget? resizeOverlay;
        for (int i = 0; i < packing.placements.length; i++) {
          final HomeWidgetPlacement p = packing.placements[i];
          final String kind = p.item.slot;
          final Rect rect = slots[i].rect;
          final Widget tile = _GridTile(
            key: _tileKeyOf(kind),
            item: p.item,
            index: i,
            grid: widget.grid,
            editing: widget.editing,
            lifted: _lifted == kind || dragKind == kind,
            jiggle: _jiggle,
            focusNode: _nodeOf(kind),
            label: widget.labelOf(p.item),
            onKey: (KeyEvent e) => _onKey(kind, e),
            onEnterEdit: widget.onEnterEdit,
            onRemove: () => _remove(kind),
            onConfigure: _configurable(p.item) ? () => _configure(kind) : null,
            onGamepad: (GamepadButton b) => _onGamepad(kind, b),
            resizing: resizeKind == kind,
            onOpenSizePicker: () => unawaited(_openSizePicker(kind)),
            onResizeStart: () => _resizeStartDrag(kind),
            onResizeUpdate: _resizeUpdateDrag,
            onResizeEnd: (bool commit) => _resizeEndDrag(commit: commit),
            onDragStart: (LongPressStartDetails d) => _dragStart(kind, d, rect),
            onDragUpdate: (LongPressMoveUpdateDetails d) =>
                _dragUpdate(d, slots),
            onDragEnd: _dragEnd,
            child: widget.cellBuilder(context, p.item),
          );
          if (resizeKind == kind && resizePreview != null) {
            resizeOverlay = AnimatedPositioned(
              key: const ValueKey<String>('home-widget-resize-preview'),
              duration: slide,
              curve: FushiMotion.standard,
              left: rect.left,
              top: rect.top,
              width: rect.width,
              height: rect.height,
              child: _ResizePreview(label: resizePreview.toString()),
            );
          }
          if (dragKind == kind) {
            // 原装箱位置画虚线占位，块本身跟手（画在最上层）。
            children.add(
              AnimatedPositioned(
                key: ValueKey<String>('home-widget-placeholder/$kind'),
                duration: slide,
                curve: FushiMotion.standard,
                left: rect.left,
                top: rect.top,
                width: rect.width,
                height: rect.height,
                child: const _DropPlaceholder(),
              ),
            );
            dragged = Positioned(
              key: ValueKey<String>('home-widget-slot/$kind'),
              left: _dragTopLeft.dx,
              top: _dragTopLeft.dy,
              width: rect.width,
              height: rect.height,
              child: tile,
            );
            continue;
          }
          children.add(
            AnimatedPositioned(
              key: ValueKey<String>('home-widget-slot/$kind'),
              duration: slide,
              curve: FushiMotion.standard,
              left: rect.left,
              top: rect.top,
              width: rect.width,
              height: rect.height,
              child: FushiStaggeredEntrance(index: i, child: tile),
            ),
          );
        }
        if (resizeOverlay != null) children.add(resizeOverlay);
        if (dragged != null) children.add(dragged);
        return FocusTraversalGroup(
          policy: ReadingOrderTraversalPolicy(),
          child: SizedBox(
            key: _stackKey,
            height: height,
            child: Stack(clipBehavior: Clip.none, children: children),
          ),
        );
      },
    );
  }
}

class _Slot {
  const _Slot(this.kind, this.rect);

  /// [HomeWidgetItem.slot]。
  final String kind;
  final Rect rect;
}

/// 一块小组件 + 编辑态的焦点 / 手势 / 角标装饰。
class _GridTile extends StatefulWidget {
  const _GridTile({
    super.key,
    required this.item,
    required this.index,
    required this.grid,
    required this.editing,
    required this.lifted,
    required this.jiggle,
    required this.focusNode,
    required this.label,
    required this.onKey,
    required this.onEnterEdit,
    required this.onRemove,
    this.onConfigure,
    required this.resizing,
    required this.onOpenSizePicker,
    required this.onResizeStart,
    required this.onResizeUpdate,
    required this.onResizeEnd,
    required this.onGamepad,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.child,
  });

  final HomeWidgetItem item;
  final int index;
  final HomeGridKind grid;
  final bool editing;
  final bool lifted;
  final Animation<double> jiggle;
  final FocusNode focusNode;
  final String label;
  final KeyEventResult Function(KeyEvent event) onKey;
  final VoidCallback onEnterEdit;
  final VoidCallback onRemove;

  /// 非空 = 可配置的组件：编辑态右上角标「设置」。
  final VoidCallback? onConfigure;

  /// 正在拖右下角改尺寸（柄高亮）。
  final bool resizing;
  final VoidCallback onOpenSizePicker;
  final VoidCallback onResizeStart;
  final ValueChanged<Offset> onResizeUpdate;

  /// 拖角结束：true = 松手提交，false = 取消。
  final ValueChanged<bool> onResizeEnd;

  /// 手柄键：true = 消费，false = 交还祖先。
  final bool Function(GamepadButton button) onGamepad;
  final ValueChanged<LongPressStartDetails> onDragStart;
  final ValueChanged<LongPressMoveUpdateDetails> onDragUpdate;
  final VoidCallback onDragEnd;
  final Widget child;

  @override
  State<_GridTile> createState() => _GridTileState();
}

class _GridTileState extends State<_GridTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final bool motion = fushiMotionEnabled(context);
    final bool editing = widget.editing;
    final HomeWidgetKind kind = widget.item.kind;
    final bool resizable = kind.resizableIn(widget.grid);
    const BorderRadius radius = FushiBorderRadius.card;

    Widget content = widget.child;
    if (editing) {
      // 编辑态：内容不响应点击（不误开书）、不进焦点遍历；整块是一个停靠点。
      content = ExcludeFocus(child: IgnorePointer(child: content));
    }

    if (editing) {
      final bool lifted = widget.lifted;
      final Color ring = tokens.surfaces.primary;
      // 角标挂在圆角外沿（iOS 主屏式）：圆点中心落在圆角弧上，不压组件标题与
      // 正文（先前 top/start 0 的角标盖住了「今日」「复习」等标题）。
      content = Stack(
        fit: StackFit.expand,
        clipBehavior: Clip.none,
        children: <Widget>[
          content,
          // 编辑态描边：墨水屏实线，其余虚线（拿起 / 聚焦时实线强调）。
          IgnorePointer(
            child: CustomPaint(
              painter: _OutlinePainter(
                color: (lifted || _focused)
                    ? ring
                    : ring.withValues(alpha: 0.45),
                width: lifted && eink ? 4 : (_focused || lifted ? 2.5 : 1.5),
                dashed: !eink && !lifted && !_focused,
                radius: radius,
              ),
            ),
          ),
          PositionedDirectional(
            top: -_kEditBadgeHang,
            start: -_kEditBadgeHang,
            child: _EditBadge(
              key: ValueKey<String>('home-widget-remove/${widget.item.slot}'),
              icon: FushiIcons.remove,
              tooltip: t.home_widget_remove,
              background: scheme.error,
              foreground: scheme.onError,
              onTap: widget.onRemove,
            ),
          ),
          if (widget.onConfigure case final VoidCallback configure)
            PositionedDirectional(
              top: -_kEditBadgeHang,
              end: -_kEditBadgeHang,
              child: _EditBadge(
                key: ValueKey<String>(
                  'home-widget-configure/${widget.item.slot}',
                ),
                icon: FushiIcons.language,
                tooltip: t.stat_goal_language,
                background: scheme.secondaryContainer,
                foreground: scheme.onSecondaryContainer,
                onTap: configure,
              ),
            ),
          if (resizable)
            PositionedDirectional(
              bottom: -_kEditBadgeHang,
              end: -_kEditBadgeHang,
              child: _ResizeHandle(
                key: ValueKey<String>('home-widget-resize/${widget.item.slot}'),
                tooltip: t.home_widget_resize,
                background: scheme.primary,
                foreground: scheme.onPrimary,
                active: widget.resizing,
                onTap: widget.onOpenSizePicker,
                onStart: widget.onResizeStart,
                onUpdate: widget.onResizeUpdate,
                onEnd: widget.onResizeEnd,
              ),
            ),
        ],
      );
      // 拿起：抬起缩放 + 阴影；墨水屏不缩放不加阴影（加粗边框已在描边里）。
      final bool raise = lifted && !eink;
      content = AnimatedScale(
        scale: raise ? 1.04 : 1,
        duration: fushiMotionDuration(context, FushiMotion.short),
        curve: FushiMotion.standard,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: radius,
            boxShadow: raise && motion
                ? const <BoxShadow>[
                    BoxShadow(
                      color: Color(0x55000000),
                      offset: Offset(0, 14),
                      blurRadius: 32,
                    ),
                  ]
                : const <BoxShadow>[],
          ),
          child: content,
        ),
      );
      // Apple：iOS 主屏式轻微抖动（相邻两块反相）；控制器只在允许动效时转。
      if (isGlassDesign(context) && !lifted) {
        final double sign = widget.index.isEven ? 1 : -1;
        final Widget still = content;
        content = AnimatedBuilder(
          animation: widget.jiggle,
          builder: (BuildContext context, Widget? child) => Transform.rotate(
            angle: (widget.jiggle.value - 0.5) * 0.024 * sign,
            child: child,
          ),
          child: still,
        );
      }
      content = RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: <Type, GestureRecognizerFactory>{
          LongPressGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
                () => LongPressGestureRecognizer(duration: kPressTimeout),
                (LongPressGestureRecognizer r) => r
                  ..onLongPressStart = widget.onDragStart
                  ..onLongPressMoveUpdate = widget.onDragUpdate
                  ..onLongPressEnd = ((LongPressEndDetails _) =>
                      widget.onDragEnd())
                  ..onLongPressCancel = widget.onDragEnd,
              ),
        },
        child: content,
      );
    } else {
      content = GestureDetector(
        onLongPress: widget.onEnterEdit,
        child: content,
      );
    }

    final HomeWidgetSize size = widget.item.size;
    // 手柄按钮经 GamepadButtonIntent 从焦点节点上溯；Actions 必须在 Focus 之上，
    // 不认的键显式转发给祖先（首页 LT/RT 换 tab 等），见 [GamepadButtonForwardingAction]。
    return Actions(
      actions: <Type, Action<Intent>>{
        GamepadButtonIntent: GamepadButtonForwardingAction(
          ancestorContext: context,
          handle: widget.onGamepad,
        ),
      },
      child: Focus(
        focusNode: widget.focusNode,
        canRequestFocus: editing,
        skipTraversal: !editing,
        onFocusChange: (bool focused) => setState(() => _focused = focused),
        onKeyEvent: (FocusNode _, KeyEvent event) => widget.onKey(event),
        child: Semantics(
          container: true,
          label: editing ? '${widget.label} · $size' : null,
          hint: editing ? t.home_widget_edit_hint : null,
          child: KeyedSubtree(
            key: homeWidgetTileKey(kind, language: widget.item.language),
            child: content,
          ),
        ),
      ),
    );
  }
}

/// 编辑角标向组件外挂出的距离：40 的命中框外挂 16，24 的圆点中心落在组件角内
/// 4dp 处（圆角弧上），命中框仍有 24×24 落在组件内（组件外那部分不接收命中）。
const double _kEditBadgeHang = 16;

/// 方向（键盘方向键 / 手柄十字键共用）。
enum _Direction { left, right, up, down }

/// 编辑态左上「−」角标：可见 24 圆，命中区 40；纯指针面，键盘 / 手柄走整块的
/// 按键（Delete / X）。
class _EditBadge extends StatelessWidget {
  const _EditBadge({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.background,
    required this.foreground,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final Color background;
  final Color foreground;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ExcludeFocus(
    child: Semantics(
      button: true,
      label: tooltip,
      excludeSemantics: true,
      onTap: onTap,
      child: FushiTooltip(
        message: tooltip,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SizedBox.square(
            dimension: 40,
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: background,
                  shape: BoxShape.circle,
                  boxShadow: const <BoxShadow>[
                    BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 4,
                      offset: Offset(0, 1),
                    ),
                  ],
                ),
                child: SizedBox.square(
                  dimension: 24,
                  child: Center(
                    child: FushiIcon(icon, size: 16, color: foreground),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// 编辑态右下角的改尺寸柄：可见 24 圆（拖动中放大高亮），命中区 40。
///
/// 按下即用 [EagerGestureRecognizer] 赢下手势竞技场——外层的长按换位与页面纵向
/// 滚动都拿不到这根指针，拖动不会变成滚页或换位；位移与抬起由 [Listener] 读原始
/// 指针事件：移动超过触摸阈值算拖角（[onStart] / [onUpdate] / [onEnd]），没移动就
/// 抬起算点按（[onTap] 弹尺寸网格）。键盘 / 手柄改尺寸走整块的按键。
class _ResizeHandle extends StatefulWidget {
  const _ResizeHandle({
    super.key,
    required this.tooltip,
    required this.background,
    required this.foreground,
    required this.active,
    required this.onTap,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
  });

  final String tooltip;
  final Color background;
  final Color foreground;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onStart;
  final ValueChanged<Offset> onUpdate;
  final ValueChanged<bool> onEnd;

  @override
  State<_ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends State<_ResizeHandle> {
  int? _pointer;
  Offset _travel = Offset.zero;
  bool _dragging = false;

  void _down(PointerDownEvent e) {
    if (_pointer != null) return;
    _pointer = e.pointer;
    _travel = Offset.zero;
    _dragging = false;
  }

  void _move(PointerMoveEvent e) {
    if (e.pointer != _pointer) return;
    if (!_dragging) {
      _travel += e.delta;
      if (_travel.distance < computeHitSlop(e.kind, null)) return;
      _dragging = true;
      widget.onStart();
      widget.onUpdate(_travel);
      return;
    }
    widget.onUpdate(e.delta);
  }

  void _up(PointerUpEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    if (_dragging) {
      _dragging = false;
      widget.onEnd(true);
    } else {
      widget.onTap();
    }
  }

  void _cancel(PointerCancelEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    if (_dragging) {
      _dragging = false;
      widget.onEnd(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool active = widget.active;
    return ExcludeFocus(
      child: Semantics(
        button: true,
        label: widget.tooltip,
        excludeSemantics: true,
        onTap: widget.onTap,
        child: FushiTooltip(
          message: widget.tooltip,
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeDownRight,
            child: RawGestureDetector(
              behavior: HitTestBehavior.opaque,
              gestures: <Type, GestureRecognizerFactory>{
                EagerGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                      EagerGestureRecognizer
                    >(
                      EagerGestureRecognizer.new,
                      (EagerGestureRecognizer _) {},
                    ),
              },
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: _down,
                onPointerMove: _move,
                onPointerUp: _up,
                onPointerCancel: _cancel,
                child: SizedBox.square(
                  dimension: 40,
                  child: Center(
                    child: AnimatedScale(
                      scale: active ? 1.25 : 1,
                      duration: fushiMotionDuration(context, FushiMotion.short),
                      curve: FushiMotion.standard,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: widget.background,
                          shape: BoxShape.circle,
                          boxShadow: const <BoxShadow>[
                            BoxShadow(
                              color: Color(0x33000000),
                              blurRadius: 4,
                              offset: Offset(0, 1),
                            ),
                          ],
                        ),
                        child: SizedBox.square(
                          dimension: 24,
                          child: Center(
                            child: FushiIcon(
                              FushiIcons.fullscreen,
                              size: 16,
                              color: widget.foreground,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 拖角改尺寸时目标格子上的预览框：主色实线框 + 淡底 + 居中「3×2」标签。
class _ResizePreview extends StatelessWidget {
  const _ResizePreview({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color primary = tokens.surfaces.primary;
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: primary.withValues(alpha: 0.10),
          borderRadius: FushiBorderRadius.card,
        ),
        child: CustomPaint(
          painter: _OutlinePainter(
            color: primary,
            width: 2.5,
            dashed: false,
            radius: FushiBorderRadius.card,
          ),
          child: Center(
            child: DecoratedBox(
              decoration: ShapeDecoration(
                color: scheme.primary,
                shape: const StadiumBorder(),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: Text(
                  label,
                  key: const ValueKey<String>('home-widget-resize-label'),
                  style: tokens.type.listTitle.copyWith(
                    color: scheme.onPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 拖动时原装箱位置的虚线占位。
class _DropPlaceholder extends StatelessWidget {
  const _DropPlaceholder();

  @override
  Widget build(BuildContext context) {
    final Color primary = FushiDesignTokens.of(context).surfaces.primary;
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: primary.withValues(alpha: 0.08),
          borderRadius: FushiBorderRadius.card,
        ),
        child: CustomPaint(
          painter: _OutlinePainter(
            color: primary,
            width: 2,
            dashed: !isEinkTheme(context),
            radius: FushiBorderRadius.card,
          ),
        ),
      ),
    );
  }
}

/// 圆角矩形描边（实线 / 虚线）。
class _OutlinePainter extends CustomPainter {
  const _OutlinePainter({
    required this.color,
    required this.width,
    required this.dashed,
    required this.radius,
  });

  final Color color;
  final double width;
  final bool dashed;
  final BorderRadius radius;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    final RRect rrect = radius.toRRect((Offset.zero & size).deflate(width / 2));
    if (!dashed) {
      canvas.drawRRect(rrect, paint);
      return;
    }
    final Path path = Path()..addRRect(rrect);
    const double dash = 7;
    const double space = 5;
    for (final PathMetric metric in path.computeMetrics()) {
      double d = 0;
      while (d < metric.length) {
        canvas.drawPath(
          metric.extractPath(d, math.min(d + dash, metric.length)),
          paint,
        );
        d += dash + space;
      }
    }
  }

  @override
  bool shouldRepaint(_OutlinePainter old) =>
      old.color != color ||
      old.width != width ||
      old.dashed != dashed ||
      old.radius != radius;
}
