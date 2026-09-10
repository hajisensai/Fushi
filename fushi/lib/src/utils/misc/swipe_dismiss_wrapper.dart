import 'package:flutter/material.dart';

import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show einkSafeDuration;

/// TODO-407/716 单一真相：查词弹窗"水平滑动关闭"的位移阈值（px）。
///
/// [sensitivity] 越高（越灵敏）阈值越小：0.6（默认）≈ 94px，1.0 → 30px，0 → 190px。
/// 被 [SwipeDismissWrapper]（弹窗顶栏可拖区）与 `base_source_page` 的全屏 barrier
/// （桌面拖正文关一层，TODO-716）共用，避免两份魔法数漂移。
double swipeDismissThreshold(double sensitivity) =>
    30 + (1.0 - sensitivity) * 160;

/// 查词弹窗「滑动关闭」松手补间时长的**唯一**入口——两个滑关实现（本文件的
/// [SwipeDismissWrapper]＝弹窗顶栏可拖区与独立查词窗整窗，以及
/// `dictionary_popup_layer.dart` 的 `_BodySwipeDismissDetector`＝弹窗正文横拖）
/// 都必须经这里取时长，别再各自写三元。
///
/// 两条归零来源：
///   * 用户显式关掉「弹窗关闭动画」（`popup_dismiss_animation`，设置 › 查词）——
///     用户诉求就是「滑动关闭那段动画能单独关掉」，而不是只能靠开墨水屏模式顺带关；
///   * 墨水屏模式（[einkSafeDuration]）——慢刷新屏上这段 200ms 位移+淡出是一串灰阶
///     残影，此前是唯一的关闭途径。
///
/// [Duration.zero] 的 `animateTo` 当帧就 complete，`onDismiss` 仍在完成回调里触发，
/// 关窗时序不变，只是不再画中间帧。
///
/// 墨水屏那条**只归零补间**：跟手期的 `Transform.translate` 保留，手指按住时仍有方向
/// 反馈（BUG-2283 备注）。用户显式关掉开关那条更强，见 [popupSwipeDismissIsInstant]。
Duration popupDismissAnimationDuration(
  BuildContext context,
  Duration duration,
) {
  if (!ReaderFushiSource.instance.popupDismissAnimation) {
    return Duration.zero;
  }
  return einkSafeDuration(context, duration);
}

/// 用户显式关掉「弹窗关闭动画」（`popup_dismiss_animation`）时，滑关**整条**都不画：
///
///   * 跟手期不再 `Transform.translate` + 淡出——手指按住拖动时弹窗一动不动；
///   * 抬手那一刻按累计横向位移判 [swipeDismissThreshold]：过了当帧 `onDismiss`，
///     没过就原地留着（无 spring-back 补间可弹——本来就没动过）。
///
/// 判定时机仍在**抬手**，与 Hoshi Reader Android 一致：那边的滑关只监听
/// `touchstart`/`touchend`、不听 `touchmove`（`LookupPopupHtml.kt`），拖动期间弹窗零
/// 位移，抬手过阈值就直接 `dismiss()`，全链路无补间、无 exit transition。
///
/// BUG-2405 只把松手后的补间归零，跟手位移原样留着，于是开关关掉后拖动仍看得见弹窗
/// 跟着手指滑一段才消失——与「弹窗关闭动画」这个名字和「关掉则瞬间关闭」的副标题
/// 不符（BUG-2439）。
bool popupSwipeDismissIsInstant() =>
    !ReaderFushiSource.instance.popupDismissAnimation;

// BUG-1757：`BarrierSwipeDismissTracker` 已迁到 `lookup_dismiss_barrier.dart`，
// 并入唯一的 barrier 构造入口 [LookupDismissBarrier]。页面不再自己持有 tracker、
// 更不再把横拖挂进手势竞技场（那会堵死 barrier 下面的 platform view 滚动）。
// 本文件只保留阈值公式 [swipeDismissThreshold] 与弹窗**本体**的滑关包装。

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

  /// 用户关掉「弹窗关闭动画」= 整条滑关不画（[popupSwipeDismissIsInstant]）：跟手期
  /// 不重绘、不位移，抬手过阈值当帧关。**用时取值**，与补间时长同理（在设置里翻开关
  /// 只触发 rebuild，缓存到字段会留着上一次的值）。
  bool get _instant => popupSwipeDismissIsInstant();

  @override
  void initState() {
    super.initState();
    _controller =
        AnimationController(vsync: this, duration: _kSwipeSlideDuration)
          ..addListener(_onAnimTick)
          ..addStatusListener(_onAnimStatus);
  }

  /// 松手补间的时长**用时取值**，不缓存。
  ///
  /// 曾经写在 `didChangeDependencies` 里，但那只在**依赖**（这里是 `Theme`）变化时重跑：
  /// 用户在设置里翻「弹窗关闭动画」只触发 rebuild、不触发 `didChangeDependencies`，
  /// 于是控制器一直留着上一次的 200ms——开关要等到下次主题切换或弹窗重建才生效，
  /// 表现成「关了没用」的空开关。取值改在每次启动补间前一刻，两条来源（用户开关 /
  /// 墨水屏）都当场生效，不依赖任何重建时机。
  void _applyDismissDuration() {
    _controller.duration = popupDismissAnimationDuration(
      context,
      _kSwipeSlideDuration,
    );
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
    // instant：跟手期一帧都不重画（[build] 也不会挂 Transform/Opacity），弹窗按住不动。
    if (_decided && _isHorizontal && mounted && !_instant) {
      setState(() {});
    }
  }

  void _finishDrag() {
    if (_instant) {
      // 抬手当帧判定：过阈值直接关（无滑出补间），没过就复位（没动过，无 spring-back）。
      final bool passed =
          _decided && _isHorizontal && _dragX.abs() > _threshold;
      // 不置 [_dismissing]：instant 没有「已滑出、等宿主移除」的退场帧要保住，留着它
      // 反而会在宿主复用同一 child 时把 [_beginDrag] 永久锁死（那条复位靠 child 换身份）。
      _reset();
      if (passed) widget.onDismiss();
      return;
    }
    _applyDismissDuration();
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
    final bool active =
        !_instant && ((_decided && _isHorizontal) || _dismissing);
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
          // instant：没有跟手位移也没有退场补间，[Transform]/[Opacity] 一层都不套——
          // 弹窗要么原样在，要么当帧消失。
          if (_instant) return widget.child;
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
