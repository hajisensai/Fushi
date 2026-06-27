import 'package:flutter/material.dart';

/// TODO-407/716 单一真相：查词弹窗"水平滑动关闭"的位移阈值（px）。
///
/// [sensitivity] 越高（越灵敏）阈值越小：0.6（默认）≈ 94px，1.0 → 30px，0 → 190px。
/// 被 [SwipeDismissWrapper]（弹窗顶栏可拖区）与 `base_source_page` 的全屏 barrier
/// （桌面拖正文关一层，TODO-716）共用，避免两份魔法数漂移。
double swipeDismissThreshold(double sensitivity) =>
    30 + (1.0 - sensitivity) * 160;

/// TODO-890：松手滑出/弹回补间时长与曲线（与 [_BodySwipeDismissDetector] 同手感）。
const Duration _kSwipeSlideDuration = Duration(milliseconds: 200);

/// TODO-890：滑出目标位移 = 卡片宽 + 该边距，保证弹窗完全移出可视区。
const double _kSwipeSlideOutMargin = 24.0;

class SwipeDismissWrapper extends StatefulWidget {
  const SwipeDismissWrapper({
    required this.child,
    required this.onDismiss,
    this.sensitivity = 0.3,
    super.key,
  });
  final Widget child;
  final VoidCallback onDismiss;
  final double sensitivity;

  @override
  State<SwipeDismissWrapper> createState() => _SwipeDismissWrapperState();
}

class _SwipeDismissWrapperState extends State<SwipeDismissWrapper>
    with SingleTickerProviderStateMixin {
  double _dragX = 0;
  double _dragY = 0;
  bool _decided = false;
  bool _isHorizontal = false;

  /// Once dismissed, keep the outgoing frame translated/faded until the host
  /// removes or replaces this child. Resetting immediately causes a visible
  /// spring-back frame on hosts that hide the layer before rebuilding it.
  bool _dismissing = false;

  /// TODO-890：松手后驱动「补间滑出屏外 / 弹回原位」的控制器。过阈值时朝拖动方向
  /// 补间到 [_animTarget]（卡片宽 + 边距）再在完成回调里 [onDismiss]；未过阈值补间
  /// 回 0（spring-back）。控制器只在松手后跑，跟手期由指针事件直接驱动 [_dragX]。
  late final AnimationController _controller;
  double _animStart = 0;
  double _animTarget = 0;
  double _layerWidth = 0;

  double get _threshold => swipeDismissThreshold(widget.sensitivity);
  double get _decisionDistance => 10 + (1.0 - widget.sensitivity) * 20;

  @override
  void initState() {
    super.initState();
    _controller =
        AnimationController(vsync: this, duration: _kSwipeSlideDuration)
          ..addListener(_onAnimTick)
          ..addStatusListener(_onAnimStatus);
  }

  @override
  void didUpdateWidget(SwipeDismissWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_dismissing && !identical(oldWidget.child, widget.child)) {
      _controller.stop();
      _clearDragState();
      _dismissing = false;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onAnimTick() {
    final double next =
        _animStart + (_animTarget - _animStart) * _controller.value;
    if (next != _dragX && mounted) {
      setState(() => _dragX = next);
    }
  }

  void _onAnimStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    if (_dismissing) {
      // 弹窗已补间滑出屏外、不可见——此刻才真正关一层（避免 dismiss 与动画竞争）。
      widget.onDismiss();
      return;
    }
    // 未过阈值的 spring-back 补间已回到原位：复位决策/方向残留状态，否则下次拖动
    // 会带着上一手的 _decided / _isHorizontal（_dragX 已为 0 但谓词未清）。
    if (mounted) setState(_clearDragState);
  }

  void _clearDragState() {
    _dragX = 0;
    _dragY = 0;
    _decided = false;
    _isHorizontal = false;
  }

  void _reset() {
    if (!mounted || _dismissing) return;
    setState(_clearDragState);
  }

  void _beginDrag() {
    if (_dismissing) return;
    _controller.stop();
    _clearDragState();
  }

  void _handleDragDelta(Offset delta) {
    if (_dismissing) return;
    _dragX += delta.dx;
    _dragY += delta.dy;
    if (!_decided &&
        (_dragX.abs() > _decisionDistance ||
            _dragY.abs() > _decisionDistance)) {
      _decided = true;
      _isHorizontal = _dragX.abs() > _dragY.abs() * 2.5;
    }
    if (_decided && _isHorizontal && mounted) {
      setState(() {});
    }
  }

  void _finishDrag() {
    if (_decided && _isHorizontal && _dragX.abs() > _threshold) {
      // TODO-890：过阈值后不再 opacity 瞬灭，而是朝拖动方向补间滑出屏外（卡片宽 +
      // 边距）再在完成回调里 onDismiss——与 _BodySwipeDismissDetector 动画一致。
      final double width = _layerWidth > 0 ? _layerWidth : _dragX.abs();
      _animStart = _dragX;
      _animTarget =
          (_dragX.isNegative ? -1.0 : 1.0) * (width + _kSwipeSlideOutMargin);
      if (mounted) setState(() => _dismissing = true);
      _controller
        ..reset()
        ..animateTo(1.0, curve: Curves.easeOut);
      return;
    }
    // 未过阈值 / 非横滑：补间弹回原位（spring-back）。
    if (_decided && _isHorizontal && _dragX != 0 && mounted) {
      _animStart = _dragX;
      _animTarget = 0;
      _controller
        ..reset()
        ..animateTo(1.0, curve: Curves.easeOut);
      return;
    }
    _reset();
  }

  @override
  Widget build(BuildContext context) {
    final bool active = (_decided && _isHorizontal) || _dismissing;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _beginDrag(),
      onPointerMove: (e) => _handleDragDelta(e.delta),
      onPointerUp: (_) => _finishDrag(),
      onPointerCancel: (_) => _reset(),
      onPointerPanZoomStart: (_) => _beginDrag(),
      onPointerPanZoomUpdate: (e) => _handleDragDelta(e.panDelta),
      onPointerPanZoomEnd: (_) => _finishDrag(),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          if (constraints.maxWidth.isFinite) {
            _layerWidth = constraints.maxWidth;
          }
          // 退场期随位移淡出（对齐 _BodySwipeDismissDetector）：补间把 _dragX 推向
          // 「卡片宽 + 边距」屏外，opacity 同步从当前值趋近 0；中段卡片仍可见（介于
          // 0 与 1），朝屏外滑走而非瞬灭。归一分母用真实卡片宽 + 边距，无宽度回退 300。
          final double slideOutSpan =
              (_layerWidth > 0 ? _layerWidth : 300) + _kSwipeSlideOutMargin;
          return Transform.translate(
            offset: Offset(active ? _dragX : 0, 0),
            child: Opacity(
              opacity: _dismissing
                  ? (1 - (_dragX.abs() / slideOutSpan)).clamp(0.0, 1.0)
                  : (active ? (1 - (_dragX.abs() / 300)).clamp(0.3, 1.0) : 1.0),
              child: widget.child,
            ),
          );
        },
      ),
    );
  }
}
