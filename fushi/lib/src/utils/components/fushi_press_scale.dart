import 'package:flutter/gestures.dart' show kPrimaryButton, kTouchSlop;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

/// 按压反馈：手指 / 鼠标按下时内容轻微缩小，松手以 M3E spatial fast 弹簧
/// 回弹放回（[FushiMotionScheme.spatialFast]；Apple 设计系统映射到 SwiftUI 弹簧）。
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
///
/// MD3 与 Apple（Cupertino）两套设计系统**都缩放**（所有者 2026-10-13 拍板：
/// Apple 下保留按压缩放）。本组件不按设计系统增删包装层——切换设计系统时返回的
/// 子树结构不变，[child] 里的 State 不会因此重建。某个调用点确有理由在 Apple
/// 下不缩放，就在调用点显式传 [enabled]，并在那里写明理由。
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
  //
  // M3E 弹簧（2026-10-05）：按下与松手都走 spatial fast 真实弹簧，控制器值
  // 直接就是缩放倍数（unbounded：回弹会短暂越过 1，有界控制器会把过冲截掉）。
  // 松手打断按下动画时沿用当前速度，不会「急停再弹」。
  late final AnimationController _press;

  @override
  void initState() {
    super.initState();
    _press = AnimationController.unbounded(vsync: this, value: 1);
  }

  /// 非 null = 当前有一次「按下」尚未放回；它是唯一的按压状态源。
  Offset? _downPosition;

  /// 按下时取好的弹簧：松手路径**不再碰 [context]**。指针事件按 hit-test 时记下的
  /// 渲染对象路径派发，与 widget 生命周期无关——点击回调里开了模态 / 原生对话框
  /// （Windows 的文件选择器会在指针事件派发途中泵一圈消息、跑帧）把本卡拆掉后，
  /// 这条路径上的 pointerUp 仍会到达已销毁的 State。此时读 `context` 会抛
  /// `Null check operator used on a null value`（ufzhkidhLr）。
  FushiSpringSpec? _releaseSpring;

  @override
  void dispose() {
    // 销毁后到达的 pointerUp / pointerCancel 在 _release 里因 _downPosition == null
    // 直接返回，不会再碰已 dispose 的控制器或 context。
    _downPosition = null;
    _releaseSpring = null;
    _press.dispose();
    super.dispose();
  }

  void _onDown(PointerDownEvent event) {
    // 只认主键：右键 / 中键是菜单与平移，不是「按下这张卡」。
    if (event.buttons != kPrimaryButton) return;
    final FushiSpringSpec spring = context.fushiMotion.spatialFast;
    _downPosition = event.position;
    _releaseSpring = spring;
    _press.fushiSpringTo(widget.scale, spring);
  }

  void _onMove(PointerMoveEvent event) {
    final Offset? origin = _downPosition;
    if (origin == null) return;
    if ((event.position - origin).distance > kTouchSlop) _release();
  }

  void _release() {
    if (_downPosition == null) return;
    final FushiSpringSpec? spring = _releaseSpring;
    _downPosition = null;
    _releaseSpring = null;
    if (spring != null) _press.fushiSpringTo(1, spring);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || !fushiMotionEnabled(context)) return widget.child;
    return Listener(
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: (_) => _release(),
      onPointerCancel: (_) => _release(),
      child: ScaleTransition(scale: _press, child: widget.child),
    );
  }
}
