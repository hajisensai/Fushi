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

  double get _threshold => 30 + (1.0 - widget.sensitivity) * 160;
  double get _decisionDistance => 10 + (1.0 - widget.sensitivity) * 20;

  void _reset() {
    setState(() {
      _dragX = 0;
      _dragY = 0;
      _decided = false;
      _isHorizontal = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerMove: (e) {
        _dragX += e.delta.dx;
        _dragY += e.delta.dy;
        if (!_decided &&
            (_dragX.abs() > _decisionDistance ||
                _dragY.abs() > _decisionDistance)) {
          _decided = true;
          _isHorizontal = _dragX.abs() > _dragY.abs() * 2.5;
        }
        if (_decided && _isHorizontal) {
          setState(() {});
        }
      },
      onPointerUp: (_) {
        if (_decided && _isHorizontal && _dragX.abs() > _threshold) {
          widget.onDismiss();
        }
        _reset();
      },
      onPointerCancel: (_) => _reset(),
      child: Transform.translate(
        offset: Offset(_decided && _isHorizontal ? _dragX : 0, 0),
        child: Opacity(
          opacity: _decided && _isHorizontal
              ? (1 - (_dragX.abs() / 300)).clamp(0.3, 1.0)
              : 1.0,
          child: widget.child,
        ),
      ),
    );
  }
}
