import 'package:flutter/gestures.dart'
    show
        PointerPanZoomEndEvent,
        PointerPanZoomStartEvent,
        PointerPanZoomUpdateEvent;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/misc/swipe_dismiss_threshold.dart';

// BUG-1757：`BarrierSwipeDismissTracker` 已迁到 `lookup_dismiss_barrier.dart`，
// 并入唯一的 barrier 构造入口 [LookupDismissBarrier]。页面不再自己持有 tracker、
// 更不再把横拖挂进手势竞技场（那会堵死 barrier 下面的 platform view 滚动）。
// 本文件只保留阈值公式 [swipeDismissThreshold] 与弹窗**本体**的滑关包装。

/// 查词弹窗的滑动关闭包装（弹窗顶栏可拖区与独立查词窗整窗）。
///
/// 用户 2026-11-06：横滑关弹窗时**弹窗一动不动**，抬手过阈值直接关（与点 × 同一条
/// 关闭路径），不再跟手平移 / 淡出 / 补间滑出。录屏里 Android 混合合成把原生 WebView
/// 单独挪走、Flutter 画的顶栏和卡框原地不动，看起来是「正文在框里横着滚」，让人以为
/// 弹窗能左右滚动。与 Hoshi Reader Android 一致：那边的滑关只监听 `touchstart` /
/// `touchend`，拖动期间弹窗零位移（`LookupPopupHtml.kt`）。原「弹窗关闭动画」开关
/// 随之删除——没有动画可开关了。
class SwipeDismissWrapper extends StatefulWidget {
  const SwipeDismissWrapper({
    required this.child,
    required this.onDismiss,
    this.sensitivity = 0.3,
    this.touchOnly = false,
    super.key,
  });
  final Widget child;
  final VoidCallback onDismiss;
  final double sensitivity;

  /// BUG-2770：只认触摸类指针（[isTouchLikePointer]），鼠标拖动与触控板 pan-zoom
  /// 一律不参与判定。宿主在「鼠标滑关关、触摸滑关开」时用这一档——Windows/Linux
  /// 未显式设置 `enable_swipe_to_close` 的默认状态：BUG-299 担心的鼠标框选误触仍被
  /// 挡住，触屏用户照样能像手机一样横滑关弹窗。
  final bool touchOnly;

  @override
  State<SwipeDismissWrapper> createState() => _SwipeDismissWrapperState();
}

class _SwipeDismissWrapperState extends State<SwipeDismissWrapper> {
  // 纯判定状态，不参与绘制：拖动期间不 setState、不重建。
  double _dragX = 0;
  double _dragY = 0;
  bool _decided = false;
  bool _isHorizontal = false;

  /// BUG-2770：[SwipeDismissWrapper.touchOnly] 下本轮是否由触摸类指针发起。非触摸
  /// 按下后的 move/up 一律忽略（否则鼠标拖动的位移仍会累进 [_dragX]）。
  bool _trackingAccepted = true;

  double get _threshold => swipeDismissThreshold(widget.sensitivity);
  double get _decisionDistance => 10 + (1.0 - widget.sensitivity) * 20;

  void _clearDragState() {
    _dragX = 0;
    _dragY = 0;
    _decided = false;
    _isHorizontal = false;
  }

  void _handleDragDelta(Offset delta) {
    _dragX += delta.dx;
    _dragY += delta.dy;
    if (!_decided &&
        (_dragX.abs() > _decisionDistance ||
            _dragY.abs() > _decisionDistance)) {
      _decided = true;
      _isHorizontal = _dragX.abs() > _dragY.abs() * 2.5;
    }
  }

  void _finishDrag() {
    final bool passed = _decided && _isHorizontal && _dragX.abs() > _threshold;
    _clearDragState();
    if (passed) widget.onDismiss();
  }

  /// BUG-2770：[SwipeDismissWrapper.touchOnly] 下只让触摸类指针开一轮；非 touchOnly
  /// 任何指针都开一轮。
  void _onPointerDown(PointerDownEvent event) {
    _trackingAccepted = !widget.touchOnly || isTouchLikePointer(event.kind);
    if (!_trackingAccepted) return;
    _clearDragState();
  }

  @override
  Widget build(BuildContext context) {
    final bool touchOnly = widget.touchOnly;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerMove: (PointerMoveEvent e) {
        if (_trackingAccepted) _handleDragDelta(e.delta);
      },
      onPointerUp: (PointerUpEvent _) {
        if (_trackingAccepted) _finishDrag();
      },
      onPointerCancel: (PointerCancelEvent _) {
        if (_trackingAccepted) _clearDragState();
      },
      // 触控板双指平移是鼠标半边（BUG-2770）：touchOnly 下整条不挂。
      onPointerPanZoomStart: touchOnly
          ? null
          : (PointerPanZoomStartEvent _) => _clearDragState(),
      onPointerPanZoomUpdate: touchOnly
          ? null
          : (PointerPanZoomUpdateEvent e) => _handleDragDelta(e.panDelta),
      onPointerPanZoomEnd: touchOnly
          ? null
          : (PointerPanZoomEndEvent _) => _finishDrag(),
      child: widget.child,
    );
  }
}
