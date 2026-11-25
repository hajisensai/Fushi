import 'dart:async' show Timer, unawaited;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:fushi/src/utils/misc/platform_utils.dart'
    show HorizontalDragScrollable, longPressTolerantHitSlop;
import 'package:material_ui/material_ui.dart';

/// 标签 chip 的拖动重排入口：所有指针都是**长按才起拖**（BUG-4899 / BUG-5066 /
/// BUG-5174）。
///
/// 交互约定：按下就拖 = 横滚标签条，按住不动满长按时长再拖 = 重排，不动松开 =
/// 单击筛选；鼠标与触屏一致，chip 左侧没有拖动柄。
///
/// 鼠标为什么以前长按拖不动（BUG-4899 根因）：Flutter 对鼠标的 hit slop 只有
/// 1 px（`kPrecisePointerHitSlop`），原生 [DelayedMultiDragGestureRecognizer] 在
/// 500 ms 计时里位移超 1 px 就自行认输，`Scrollable` 的横拖识别器也是 1 px 就
/// 认领，手一抖长按就输给横滚。本件的长按识别改用 [longPressTolerantHitSlop]
/// （鼠标取 `kTouchSlop`）容忍抖动；标签条外层的 [HorizontalDragScrollable] 传
/// `mouseDragController`，鼠标横滚用同一门槛起滚，两边判据一致、互不误伤。
///
/// 落点由调用方 chip 上的 `DragTarget<T>` 接，本件只负责「起拖」。
class FushiTagChipDraggable<T extends Object> extends LongPressDraggable<T> {
  const FushiTagChipDraggable({
    required T super.data,
    required super.feedback,
    required super.child,
    super.childWhenDragging,
    super.key,
  });

  @override
  DelayedMultiDragGestureRecognizer createRecognizer(
    GestureMultiDragStartCallback onStart,
  ) =>
      _LongPressTolerantMultiDragGestureRecognizer(delay: delay)
        ..onStart = (Offset position) {
          final Drag? result = onStart(position);
          if (result != null && hapticFeedbackOnStart) {
            unawaited(HapticFeedback.selectionClick());
          }
          return result;
        };
}

/// 长按计时内的位移门槛取 [longPressTolerantHitSlop] 的长按多指拖动识别器。
class _LongPressTolerantMultiDragGestureRecognizer
    extends DelayedMultiDragGestureRecognizer {
  _LongPressTolerantMultiDragGestureRecognizer({super.delay});

  @override
  MultiDragPointerState createNewPointerState(PointerDownEvent event) =>
      _LongPressTolerantPointerState(
        event.position,
        delay,
        event.kind,
        gestureSettings,
      );

  @override
  String get debugDescription => 'long multidrag (tolerant slop)';
}

/// 与 Flutter 的 `_DelayedPointerState` 同构，只是门槛换成
/// [longPressTolerantHitSlop]。
class _LongPressTolerantPointerState extends MultiDragPointerState {
  _LongPressTolerantPointerState(
    super.initialPosition,
    Duration delay,
    super.kind,
    super.gestureSettings,
  ) {
    _timer = Timer(delay, _delayPassed);
  }

  Timer? _timer;
  GestureMultiDragStartCallback? _starter;

  double get _slop => longPressTolerantHitSlop(kind, gestureSettings);

  void _delayPassed() {
    _timer = null;
    final GestureMultiDragStartCallback? starter = _starter;
    if (starter != null) {
      _starter = null;
      starter(initialPosition);
    } else {
      resolve(GestureDisposition.accepted);
    }
  }

  void _ensureTimerStopped() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void accepted(GestureMultiDragStartCallback starter) {
    if (_timer == null) {
      starter(initialPosition);
    } else {
      _starter = starter;
    }
  }

  @override
  void checkForResolutionAfterMove() {
    // 已被竞技场判胜、等计时满再起拖：此时的位移不再改判。
    if (_timer == null) return;
    final Offset? delta = pendingDelta;
    if (delta != null && delta.distance > _slop) {
      resolve(GestureDisposition.rejected);
      _ensureTimerStopped();
    }
  }

  @override
  void dispose() {
    _ensureTimerStopped();
    super.dispose();
  }
}
