import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// 视频画面「长按临时倍速」的手势会话：保证**每一次已开始的长按恰好收尾一次**。
///
/// 3sDHeyPQ-I（倍速徽章卡在画面上、只有重开视频才消失）的根因：页面只在
/// [GestureDetector.onLongPressEnd] 里清徽章 / 恢复倍速，可 [LongPressGestureRecognizer]
/// 在长按**已被接受之后**并不保证再回调任何东西——
///
/// - 指针被系统取消（[PointerCancelEvent]：窗口失焦 / 指针捕获被抢 / 系统手势）时，
///   它只在 `state == possible`（尚未接受）才回调 `onLongPressCancel`；接受后直接
///   `_reset()`，start 之后一个回调都没有；
/// - 识别器被销毁（长按途中画面层被重建进另一棵子树、换布局分支）同样没有回调；
/// - `onLongPressCancel` 本身只覆盖「还没开始就输掉」，接它修不了「开始之后」。
///
/// 所以「会话何时结束」不能只信识别器。本 widget 把会话绑到**发起它的那根指针**：
/// 外层 [Listener] 记下按下的主指针，长按开始时把会话钉到这根指针上；该指针的
/// 抬起 / 取消（指针层事件不经手势竞技场，一定会到）与识别器的 end 都汇到同一个
/// 幂等的 [_finish]，widget 销毁时若会话仍开着也收尾。三个出口谁先到算谁，其余空转。
class VideoLongPressSessionDetector extends StatefulWidget {
  const VideoLongPressSessionDetector({
    super.key,
    required this.onLongPressStart,
    required this.onLongPressMoveUpdate,
    required this.onLongPressEnd,
    required this.child,
  });

  /// 长按被接受（与 [GestureDetector.onLongPressStart] 同时机）。
  final GestureLongPressStartCallback onLongPressStart;

  /// 长按后拖动（仅会话进行中转发）。
  final GestureLongPressMoveUpdateCallback onLongPressMoveUpdate;

  /// 会话结束：正常松手、指针被取消、识别器被重置、widget 被销毁——每个已开始的
  /// 会话恰好回调一次。
  final VoidCallback onLongPressEnd;

  final Widget child;

  @override
  State<VideoLongPressSessionDetector> createState() =>
      _VideoLongPressSessionDetectorState();
}

class _VideoLongPressSessionDetectorState
    extends State<VideoLongPressSessionDetector> {
  /// 当前按下的指针（按下顺序）。长按识别器跟踪的是**第一根**按下的指针，会话也
  /// 只认它：多指触摸时第二根手指抬起不能把会话收掉。
  final List<int> _downPointers = <int>[];

  /// 会话绑定的指针；非 null = 会话进行中。
  int? _sessionPointer;

  /// 会话进行中但不知道是哪根指针（理论上不会发生：Listener 是识别器的祖先，按下
  /// 一定先记到账）。此时只能靠识别器 end / 销毁收尾。
  bool _sessionWithoutPointer = false;

  bool get _sessionActive => _sessionPointer != null || _sessionWithoutPointer;

  void _handlePointerDown(PointerDownEvent event) {
    _downPointers.add(event.pointer);
  }

  void _handlePointerEnded(PointerEvent event) {
    _downPointers.remove(event.pointer);
    if (_sessionPointer == event.pointer) _finish();
  }

  void _handleStart(LongPressStartDetails details) {
    // 上一次会话没收尾就又开始（不应发生）：先把旧的收掉，绝不叠两层。
    if (_sessionActive) _finish();
    if (_downPointers.isNotEmpty) {
      _sessionPointer = _downPointers.first;
    } else {
      _sessionWithoutPointer = true;
    }
    widget.onLongPressStart(details);
  }

  void _handleMoveUpdate(LongPressMoveUpdateDetails details) {
    if (!_sessionActive) return;
    widget.onLongPressMoveUpdate(details);
  }

  void _finish() {
    if (!_sessionActive) return;
    _sessionPointer = null;
    _sessionWithoutPointer = false;
    widget.onLongPressEnd();
  }

  @override
  void dispose() {
    if (_sessionActive) {
      _sessionPointer = null;
      _sessionWithoutPointer = false;
      // 卸载发生在树锁定期（finalizeTree），此刻回调里若 setState / 通知监听者会
      // 触发「树已锁定」断言；收尾推到当前帧结束后的微任务，回调仍一定执行。
      final VoidCallback onEnd = widget.onLongPressEnd;
      scheduleMicrotask(onEnd);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _handlePointerDown,
      onPointerUp: _handlePointerEnded,
      onPointerCancel: _handlePointerEnded,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onLongPressStart: _handleStart,
        onLongPressMoveUpdate: _handleMoveUpdate,
        onLongPressEnd: (LongPressEndDetails _) => _finish(),
        child: widget.child,
      ),
    );
  }
}
