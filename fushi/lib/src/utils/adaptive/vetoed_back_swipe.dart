import 'dart:math' as math;

import 'package:flutter/gestures.dart' show HorizontalDragGestureRecognizer;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

/// 边缘热区宽度：与 Cupertino 原生返回手势（`_kBackGestureWidth`）一致。
const double _kEdgeWidth = 20;

/// 快速一甩即算「要返回」的速度阈值（屏宽 / 秒），与原生 `_kMinFlingVelocity` 一致。
const double _kCommitVelocity = 1;

/// 慢拖到屏宽的这个比例即算「要返回」。页面只做阻尼位移、不跟手 1:1 滑走，
/// 所以比原生的 0.5 宽松。
const double _kCommitFraction = 0.3;

/// 阻尼位移的渐近上限（逻辑像素）：拖得再远页面也只挪这么多，松手弹回。
const double _kMaxRubberBand = 56;

/// 该路由此刻是否属于「侧滑返回被页面否决」：页面挂了 `canPop: false` 的
/// [PopScope]（或其他 [PopEntry]），Cupertino 原生返回手势因此整个关掉
/// （`ModalRoute.popGestureEnabled` 为假）。
///
/// 其余让原生手势关掉的情况（首页、全屏对话框、局部历史、转场进行中、别的手势
/// 在进行）这里同样不接，保持原生语义。
bool isBackSwipeVetoed(PageRoute<dynamic> route) {
  if (!route.isCurrent || route.isFirst || route.fullscreenDialog) {
    return false;
  }
  if (route.willHandlePopInternally) return false;
  if (route.popDisposition != RoutePopDisposition.doNotPop) return false;
  final Animation<double>? animation = route.animation;
  if (animation == null || !animation.isCompleted) return false;
  final NavigatorState? navigator = route.navigator;
  if (navigator == null || navigator.userGestureInProgress) return false;
  return true;
}

/// 给 Cupertino 页面转场补上「被否决的侧滑返回」：页面用 `PopScope(canPop: false)`
/// 拦返回（未保存表单、批量选择、任务进行中…）时，Flutter 直接把 iOS 边缘侧滑
/// 整个关掉，用户右滑毫无反应、以为卡住了（拍板台 left3533）。这里在同一条边缘
/// 热区接住这次侧滑：页面带阻尼地跟手挪一点，松手弹回，够远 / 够快就调
/// [NavigatorState.maybePop]——与 Android 系统返回键、预测性返回被否决后的退化
/// 路径完全同一条，落到页面自己的 `PopScope.onPopInvokedWithResult`（例如弹
/// 「保存 / 放弃 / 取消」）。
///
/// 只在 [isBackSwipeVetoed] 为真时参与手势竞技场；其余时候原生返回手势照常
/// 接管，两者不会同时认领同一个指针。子树结构恒定（位移层恒在），状态切换不重挂
/// 页面。
class VetoedBackSwipe extends StatefulWidget {
  const VetoedBackSwipe({required this.route, required this.child, super.key});

  /// 承载本页的路由。
  final PageRoute<dynamic> route;

  /// 页面内容。
  final Widget child;

  @override
  State<VetoedBackSwipe> createState() => _VetoedBackSwipeState();
}

class _VetoedBackSwipeState extends State<VetoedBackSwipe>
    with SingleTickerProviderStateMixin {
  late final HorizontalDragGestureRecognizer _recognizer;

  /// 阻尼位移（逻辑像素，恒 ≥ 0，方向由 [Directionality] 决定）。
  late final AnimationController _offset;

  /// 本次拖动累计的逻辑距离（朝「返回」方向为正）。
  double _drag = 0;

  @override
  void initState() {
    super.initState();
    _offset = AnimationController(
      vsync: this,
      lowerBound: 0,
      upperBound: _kMaxRubberBand,
    );
    _recognizer = HorizontalDragGestureRecognizer(debugOwner: this)
      ..onStart = _handleDragStart
      ..onUpdate = _handleDragUpdate
      ..onEnd = _handleDragEnd
      ..onCancel = _handleDragCancel;
  }

  @override
  void dispose() {
    _recognizer.dispose();
    _offset.dispose();
    super.dispose();
  }

  double _toLogical(double value) => switch (Directionality.of(context)) {
    TextDirection.rtl => -value,
    TextDirection.ltr => value,
  };

  void _handlePointerDown(PointerDownEvent event) {
    if (isBackSwipeVetoed(widget.route)) _recognizer.addPointer(event);
  }

  void _handleDragStart(DragStartDetails details) {
    _drag = 0;
    _offset.stop();
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    _drag = math.max(0, _drag + _toLogical(details.primaryDelta ?? 0));
    if (!fushiMotionEnabled(context)) return;
    // 渐近阻尼：位移 = max · d / (d + max)，越拖越沉，永远到不了 max。
    _offset.value = _kMaxRubberBand * _drag / (_drag + _kMaxRubberBand);
  }

  void _handleDragEnd(DragEndDetails details) {
    final double width = context.size?.width ?? 0;
    final double velocity = width <= 0
        ? 0
        : _toLogical(details.velocity.pixelsPerSecond.dx) / width;
    final bool commit =
        velocity >= _kCommitVelocity ||
        (width > 0 && _drag >= width * _kCommitFraction);
    _settle();
    if (commit) widget.route.navigator?.maybePop();
  }

  void _handleDragCancel() => _settle();

  void _settle() {
    _drag = 0;
    if (_offset.value == 0) return;
    _offset.animateTo(
      0,
      duration: fushiMotionDuration(context, FushiMotion.medium),
      curve: FushiMotion.standard,
    );
  }

  @override
  Widget build(BuildContext context) {
    final double edge = math.max(_kEdgeWidth, switch (Directionality.of(
      context,
    )) {
      TextDirection.rtl => MediaQuery.paddingOf(context).right,
      TextDirection.ltr => MediaQuery.paddingOf(context).left,
    });
    return Stack(
      fit: StackFit.passthrough,
      children: <Widget>[
        AnimatedBuilder(
          animation: _offset,
          child: widget.child,
          builder: (BuildContext context, Widget? child) => Transform.translate(
            offset: Offset(_toLogical(_offset.value), 0),
            child: child,
          ),
        ),
        PositionedDirectional(
          start: 0,
          width: edge,
          top: 0,
          bottom: 0,
          child: Listener(
            onPointerDown: _handlePointerDown,
            behavior: HitTestBehavior.translucent,
          ),
        ),
      ],
    );
  }
}
