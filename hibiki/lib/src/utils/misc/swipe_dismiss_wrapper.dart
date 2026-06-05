import 'package:flutter/material.dart';

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

  /// 已命中关闭阈值、`onDismiss` 已触发：本浮层进入「退场」态，**不再回弹**。
  ///
  /// 闪回根因：松手命中阈值时若同步把 `_dragX` 归零（`_reset`），`Transform.translate`
  /// / `Opacity` 会瞬间把浮层拉回原位且满不透明——而 `onDismiss` 触发的浮层移除
  /// （video 页走 root Overlay 重建、有一帧延迟）尚未生效，于是「回弹到原位的满不
  /// 透明浮层」闪现一帧再消失＝用户看到的「闪回」。退场态锁住当前位移、把不透明度
  /// 压到 0（视觉上已滑出），由上层负责真正移除本子树，杜绝回弹帧。
  bool _dismissing = false;

  double get _threshold => 30 + (1.0 - widget.sensitivity) * 160;
  double get _decisionDistance => 10 + (1.0 - widget.sensitivity) * 20;

  @override
  void didUpdateWidget(SwipeDismissWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 退场态只在「本浮层正被滑掉、等上层把它从树上摘除」的一帧内有效。
    //
    // 两种关闭语义在松手那一帧的差异决定了这里必须复位：
    // - video 页：onDismiss 直接把浮层 OverlayEntry 移除 → 本 State 被弃用，
    //   didUpdateWidget 不会被调，`_dismissing` 保持＝退场帧不回弹（正确）。
    // - reader 页：onDismiss 只把 `visible=false`（Visibility 仍 maintainState），
    //   子树 child 会换新实例触发本回调；之后复用该浮层重新 `visible=true` 时也会
    //   再次触发。无论哪种，只要父级传入了新的 child，就说明浮层内容已被上层接管/
    //   复用，必须清掉退场态，否则复用后浮层会被永久压到 opacity 0＝不可见。
    if (_dismissing && !identical(oldWidget.child, widget.child)) {
      _dragX = 0;
      _dragY = 0;
      _decided = false;
      _isHorizontal = false;
      _dismissing = false;
    }
  }

  void _reset() {
    if (!mounted || _dismissing) return;
    setState(() {
      _dragX = 0;
      _dragY = 0;
      _decided = false;
      _isHorizontal = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool active = _decided && _isHorizontal;
    return Listener(
      onPointerMove: (e) {
        if (_dismissing) return;
        _dragX += e.delta.dx;
        _dragY += e.delta.dy;
        if (!_decided &&
            (_dragX.abs() > _decisionDistance ||
                _dragY.abs() > _decisionDistance)) {
          _decided = true;
          _isHorizontal = _dragX.abs() > _dragY.abs() * 2.5;
        }
        if (_decided && _isHorizontal && mounted) {
          setState(() {});
        }
      },
      onPointerUp: (_) {
        if (_decided && _isHorizontal && _dragX.abs() > _threshold) {
          // 退场态：锁住位移 + 透明度归 0（视觉滑出），再触发上层移除。绝不回弹。
          if (mounted) setState(() => _dismissing = true);
          widget.onDismiss();
          return;
        }
        _reset();
      },
      onPointerCancel: (_) => _reset(),
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
