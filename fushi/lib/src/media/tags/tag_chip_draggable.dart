import 'dart:async' show unawaited;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:material_ui/material_ui.dart';

/// 标签 chip 的拖动重排入口：按指针类型分流（BUG-4899 / BUG-5066）。
///
/// - 鼠标 / 触控板：即时 [Draggable]（`ImmediateMultiDragGestureRecognizer`），
///   越过 hit slop 才起拖；按下不动松开仍是单击，chip 的点选筛选照常。
/// - 触屏 / 触控笔：[LongPressDraggable]，长按才起拖，短滑仍归外层横滚。
///
/// 为什么鼠标不能也走长按（BUG-4899 根因）：库页标签条是
/// `HorizontalDragScrollable` 包的横向 `ListView`，鼠标精确指针的 hit slop 只有
/// 1 px（`kPrecisePointerHitSlop`），长按 500 ms 计时里手一抖超过 1 px，
/// `DelayedMultiDragGestureRecognizer` 就自行认输，同一下位移让横滚胜出。即时
/// 版的 recognizer 比滚动区深，指针路由先到它，越过 slop 的同一帧先认领，横滚
/// 抢不到。代价：鼠标在 chip 上拖不再横滚标签条，横滚改走 Shift+滚轮（横向
/// `Scrollable` 只取滚轮 dx，裸滚轮不横滚）、触控板横扫和 chip 之间的空白处拖动。
///
/// 两条路径的设备集不重叠，互不进同一竞技场。落点由调用方 chip 上的
/// `DragTarget<T>` 接，本件只负责「起拖」。
class FushiTagChipDraggable<T extends Object> extends StatelessWidget {
  const FushiTagChipDraggable({
    required this.data,
    required this.feedback,
    required this.child,
    this.childWhenDragging,
    super.key,
  });

  /// 拖动携带的数据（标签行）。
  final T data;

  /// 跟手浮层。
  final Widget feedback;

  /// chip 本体（通常是包着 chip 的 `DragTarget<T>`）。
  final Widget child;

  /// 拖动中留在原位的占位；null 时原样显示 [child]。
  final Widget? childWhenDragging;

  /// 即时起拖的精确指针。
  static const Set<PointerDeviceKind> immediateDevices = <PointerDeviceKind>{
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
  };

  /// 长按起拖的指针（其余全部）。
  static const Set<PointerDeviceKind> longPressDevices = <PointerDeviceKind>{
    PointerDeviceKind.touch,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.unknown,
  };

  @override
  Widget build(BuildContext context) {
    return _ImmediateDeviceDraggable<T>(
      devices: immediateDevices,
      data: data,
      feedback: feedback,
      childWhenDragging: childWhenDragging,
      child: _LongPressDeviceDraggable<T>(
        devices: longPressDevices,
        data: data,
        feedback: feedback,
        childWhenDragging: childWhenDragging,
        child: child,
      ),
    );
  }
}

/// 只认 [devices] 的即时 [Draggable]。
class _ImmediateDeviceDraggable<T extends Object> extends Draggable<T> {
  const _ImmediateDeviceDraggable({
    required this.devices,
    required super.child,
    required super.feedback,
    super.data,
    super.childWhenDragging,
  });

  final Set<PointerDeviceKind> devices;

  @override
  MultiDragGestureRecognizer createRecognizer(
    GestureMultiDragStartCallback onStart,
  ) =>
      ImmediateMultiDragGestureRecognizer(supportedDevices: devices)
        ..onStart = onStart;
}

/// 只认 [devices] 的 [LongPressDraggable]（保留起拖触感反馈）。
class _LongPressDeviceDraggable<T extends Object>
    extends LongPressDraggable<T> {
  const _LongPressDeviceDraggable({
    required this.devices,
    required super.child,
    required super.feedback,
    super.data,
    super.childWhenDragging,
  });

  final Set<PointerDeviceKind> devices;

  @override
  DelayedMultiDragGestureRecognizer createRecognizer(
    GestureMultiDragStartCallback onStart,
  ) =>
      DelayedMultiDragGestureRecognizer(delay: delay, supportedDevices: devices)
        ..onStart = (Offset position) {
          final Drag? result = onStart(position);
          if (result != null && hapticFeedbackOnStart) {
            unawaited(HapticFeedback.selectionClick());
          }
          return result;
        };
}
