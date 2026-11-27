import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'package:fushi/src/utils/window_caption_channel.dart';

/// BUG-5591：声明「本路由此刻把整个窗口客户区盖成不透明像素」。
///
/// 与设计系统无关的纯状态层（不渲染任何东西）：认领期间 Windows runner 把主窗
/// 表面在 Mica 下也按不透明合成（[WindowCaptionChannel.acquireOpaqueContent]），
/// 全屏跳变的过渡快照于是留在视图底下，直到 DWM 合成出新尺寸的首帧——不再在那
/// 1–3 帧里露出整窗纯色材质。
///
/// 只在两件事同时成立时认领：
/// - [enabled]：调用方保证此刻整窗确实不透明（本地视频页：画面已挂上、黑底铺满，
///   不在网页档 / 回看横幅等可能半透明的状态）；
/// - 所在路由的入场动画已完成（`animation.status == completed`）：入场 / 退场过程
///   中下面的半透明首页还看得见，那时把表面改成不透明会让首页底下的材质变成实色。
///
/// 认领在下一帧之后才下发（画面那一帧已经铺满），放手立即下发（赶在半透明内容
/// 那一帧之前）；离树时放手。非 Windows 无副作用。
class OpaqueWindowContentClaim extends StatefulWidget {
  const OpaqueWindowContentClaim({
    required this.enabled,
    required this.child,
    super.key,
  });

  final bool enabled;
  final Widget child;

  @override
  State<OpaqueWindowContentClaim> createState() =>
      _OpaqueWindowContentClaimState();
}

class _OpaqueWindowContentClaimState extends State<OpaqueWindowContentClaim> {
  Animation<double>? _routeAnimation;
  bool _held = false;
  bool _acquireScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final Animation<double>? next = ModalRoute.of(context)?.animation;
    if (identical(next, _routeAnimation)) return;
    _routeAnimation?.removeStatusListener(_onRouteStatus);
    _routeAnimation = next;
    _routeAnimation?.addStatusListener(_onRouteStatus);
    _sync();
  }

  @override
  void didUpdateWidget(OpaqueWindowContentClaim oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) _sync();
  }

  void _onRouteStatus(AnimationStatus _) => _sync();

  bool get _wanted =>
      mounted &&
      widget.enabled &&
      _routeAnimation != null &&
      _routeAnimation!.status == AnimationStatus.completed;

  void _sync() {
    if (_wanted) {
      if (_held || _acquireScheduled) return;
      _acquireScheduled = true;
      SchedulerBinding.instance.addPostFrameCallback((Duration _) {
        _acquireScheduled = false;
        if (_held || !_wanted) return;
        _held = true;
        WindowCaptionChannel.acquireOpaqueContent();
      });
      SchedulerBinding.instance.ensureVisualUpdate();
      return;
    }
    if (_held) {
      _held = false;
      WindowCaptionChannel.releaseOpaqueContent();
    }
  }

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_onRouteStatus);
    if (_held) {
      _held = false;
      WindowCaptionChannel.releaseOpaqueContent();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
