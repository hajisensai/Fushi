import 'package:flutter/material.dart';

/// TODO-407/716 单一真相：查词弹窗"水平滑动关闭"的位移阈值（px）。
///
/// [sensitivity] 越高（越灵敏）阈值越小：0.6（默认）≈ 94px，1.0 → 30px，0 → 190px。
/// 被 [SwipeDismissWrapper]（弹窗顶栏可拖区）与 `base_source_page` 的全屏 barrier
/// （桌面拖正文关一层，TODO-716）共用，避免两份魔法数漂移。
double swipeDismissThreshold(double sensitivity) =>
    30 + (1.0 - sensitivity) * 160;

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

class _SwipeDismissWrapperState extends State<SwipeDismissWrapper> {
  double _dragX = 0;
  double _dragY = 0;
  bool _decided = false;
  bool _isHorizontal = false;

  /// Once dismissed, keep the outgoing frame translated/faded until the host
  /// removes or replaces this child. Resetting immediately causes a visible
  /// spring-back frame on hosts that hide the layer before rebuilding it.
  bool _dismissing = false;

  double get _threshold => swipeDismissThreshold(widget.sensitivity);
  double get _decisionDistance => 10 + (1.0 - widget.sensitivity) * 20;

  @override
  void didUpdateWidget(SwipeDismissWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_dismissing && !identical(oldWidget.child, widget.child)) {
      _clearDragState();
      _dismissing = false;
    }
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
      if (mounted) setState(() => _dismissing = true);
      widget.onDismiss();
      return;
    }
    _reset();
  }

  @override
  Widget build(BuildContext context) {
    final bool active = _decided && _isHorizontal;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _beginDrag(),
      onPointerMove: (e) => _handleDragDelta(e.delta),
      onPointerUp: (_) => _finishDrag(),
      onPointerCancel: (_) => _reset(),
      onPointerPanZoomStart: (_) => _beginDrag(),
      onPointerPanZoomUpdate: (e) => _handleDragDelta(e.panDelta),
      onPointerPanZoomEnd: (_) => _finishDrag(),
      child: Transform.translate(
        offset: Offset(active ? _dragX : 0, 0),
        child: Opacity(
          opacity: _dismissing
              ? 0.0
              : (active ? (1 - (_dragX.abs() / 300)).clamp(0.3, 1.0) : 1.0),
          child: widget.child,
        ),
      ),
    );
  }
}
