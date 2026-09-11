import 'package:flutter/widgets.dart';

/// 在本子树所在的路由**从栈顶变成非栈顶**那一帧的帧末回调 [onLostTop]。
///
/// 「失去栈顶」两种来路都覆盖：本路由被 pop（自己的 `animation` 进入 reverse），或一条
/// 可衔接过渡的新路由压上来 / `pushReplacement` 替换本路由（`secondaryAnimation` 进入
/// forward）。判据不看动画状态本身，只把「本路由的两条动画有状态变化」当作重新评估的
/// 触发点，帧末再用 [ModalRoute.isCurrent]（由 Navigator 历史实时计算，不是 inherited
/// 快照）判 true → false 的边沿；所以一次失去栈顶只回调一次，重回栈顶再失去会再回调。
///
/// 为什么要一个独立叶子而不是让页面 State 自己 `ModalRoute.of`：`ModalRoute.of` 建立
/// 的是对整个 `_ModalScopeStatus` 的 inherited 依赖，任何弹窗 / 菜单压上来再弹走都会
/// 让依赖者重建——依赖者若是几千行的页面 State，就是每个弹窗两次整页 build。放在
/// 透传叶子上，重建只落在叶子自己。
///
/// 为什么在帧末而不是状态回调当场：状态变化由 `Navigator.pop / push` 同步触发，调用栈
/// 可能正在某个 `MouseRegion` 回调（MouseTracker 迭代）里；帧末回调不在 build /
/// finalize 锁内，且**早于** `RendererBinding` 在 `drawFrame` 之后才登记的 MouseTracker
/// 帧末重命中——合成指针类的清理放在这里，来不及污染下层页 / 新页（BUG-2453）。
///
/// 路由为 null（子树不在任何 [ModalRoute] 里，如测试直接 pumpWidget）时永不回调。
/// 零布局、零绘制，直接透传 [child]。
class RouteTopListener extends StatefulWidget {
  const RouteTopListener({
    super.key,
    required this.onLostTop,
    required this.child,
  });

  /// 本子树所在路由从栈顶变成非栈顶时（帧末）调用。须幂等：重回栈顶再失去会再调。
  final VoidCallback onLostTop;

  final Widget child;

  @override
  State<RouteTopListener> createState() => _RouteTopListenerState();
}

class _RouteTopListenerState extends State<RouteTopListener> {
  ModalRoute<Object?>? _route;

  /// 上次评估时本路由是否在栈顶；边沿判据的另一半。
  bool _wasTop = true;

  /// 同一帧内多次状态变化只排一个帧末评估。
  bool _evaluationScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ModalRoute<Object?>? route = ModalRoute.of(context);
    if (identical(route, _route)) return;
    _detach();
    _route = route;
    _wasTop = route?.isCurrent ?? true;
    route?.animation?.addStatusListener(_onStatus);
    route?.secondaryAnimation?.addStatusListener(_onStatus);
  }

  void _onStatus(AnimationStatus _) {
    if (_evaluationScheduled) return;
    _evaluationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _evaluationScheduled = false;
      if (!mounted) return;
      final ModalRoute<Object?>? route = _route;
      if (route == null) return;
      final bool isTop = route.isCurrent;
      final bool lost = _wasTop && !isTop;
      _wasTop = isTop;
      if (lost) widget.onLostTop();
    });
  }

  void _detach() {
    _route?.animation?.removeStatusListener(_onStatus);
    _route?.secondaryAnimation?.removeStatusListener(_onStatus);
    _route = null;
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
