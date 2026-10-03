import 'package:flutter/gestures.dart' show kPrimaryButton, kTouchSlop;
import 'package:flutter/material.dart';

import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

/// 按压反馈：手指 / 鼠标按下时内容轻微缩小，松手带一点回弹放回。
///
/// 为什么不用 `GestureDetector.onTapDown`：那会把这一层拉进手势竞技场，和内层
/// `InkWell` / 外层横滑翻页、长按多选抢判定。这里只挂 [Listener]，只**旁观**原始
/// 指针事件，不参与竞技、不吞事件——内层的点击 / 长按 / 拖拽语义一概不变。
///
/// 滑动不缩：按下后移动超过 [kTouchSlop] 视为滚动 / 拖拽起手，立即放回。否则在
/// 书架上竖滑时，手指下的那张封面会跟着「瘪」一下，像是误触。
///
/// 墨水屏与「减弱动态效果」下（[fushiMotionEnabled]）直接返回 [child]，不建
/// controller、不重绘。
class FushiPressScale extends StatefulWidget {
  const FushiPressScale({
    required this.child,
    super.key,
    this.enabled = true,
    this.scale = FushiMotion.pressScale,
  });

  final Widget child;

  /// false 时原样返回 [child]（不可点的卡片、多选态等）。
  final bool enabled;

  /// 按下时的缩放倍数。
  final double scale;

  @override
  State<FushiPressScale> createState() => _FushiPressScaleState();
}

class _FushiPressScaleState extends State<FushiPressScale>
    with SingleTickerProviderStateMixin {
  // initState 里建而不是 `late final` 懒建：从没被按过的卡直到 dispose 才第一次
  // 访问 controller，那时 element 已 deactivate，AnimationController 查
  // TickerMode 祖先会抛「Looking up a deactivated widget's ancestor is unsafe」
  // （FushiHoverLift 踩过同一个坑）。
  late final AnimationController _press;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _press = AnimationController(
      vsync: this,
      duration: FushiMotion.micro,
      reverseDuration: FushiMotion.short,
    );
    _scale = Tween<double>(begin: 1, end: widget.scale).animate(
      CurvedAnimation(
        parent: _press,
        curve: FushiMotion.standard,
        reverseCurve: FushiMotion.release.flipped,
      ),
    );
  }

  Offset? _downPosition;

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  void _onDown(PointerDownEvent event) {
    // 只认主键：右键 / 中键是菜单与平移，不是「按下这张卡」。
    if (event.buttons != kPrimaryButton) return;
    _downPosition = event.position;
    _press.forward();
  }

  void _onMove(PointerMoveEvent event) {
    final Offset? origin = _downPosition;
    if (origin == null) return;
    if ((event.position - origin).distance > kTouchSlop) _release();
  }

  void _release() {
    _downPosition = null;
    if (_press.status == AnimationStatus.dismissed) return;
    _press.reverse();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || !fushiMotionEnabled(context)) return widget.child;
    return Listener(
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: (_) => _release(),
      onPointerCancel: (_) => _release(),
      child: ScaleTransition(scale: _scale, child: widget.child),
    );
  }
}
