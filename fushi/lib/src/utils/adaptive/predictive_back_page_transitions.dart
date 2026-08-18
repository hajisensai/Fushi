import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Android 预测性返回（侧滑返回）的转场 + **手势记账**。
///
/// ## 为什么不用 Flutter 自带的 [PredictiveBackPageTransitionsBuilder]
///
/// Flutter 3.44 的自带实现把「手势开始 / 提交 / 取消」这三个平台事件**直接**转成
/// [NavigatorState.didStartUserGesture] / [NavigatorState.didStopUserGesture] 的
/// 全局计数增减（`widgets/routes.dart` 的 `TransitionRoute.handleStartBackGesture`
/// 与 `_handleDragEnd`），中间没有任何状态机去保证两者配对。而这个计数一旦失配，
/// 后果是**整个 app 永久不可点**：`_ModalScope` 用
/// `navigator.userGestureInProgress` 直接驱动 `IgnorePointer` 与
/// `focusScopeNode.canRequestFocus`（`widgets/routes.dart` 的
/// `_shouldIgnoreFocusRequest`），计数卡在 >0 时每一层路由都不再接收指针、也拿不到
/// 焦点——画面完全正常、动画照跑，但点哪都没反应，用户只能杀进程。
///
/// 实测（`test/utils/adaptive/predictive_back_gesture_accounting_test.dart` 把三条
/// 序列都固化成了用例）自带实现有三个失配口子：
///
/// 1. **重复 `startBackGesture`**（系统 / OEM 对一次手势重发起始事件）：每一次都
///    `didStartUserGesture()`，而 commit 只会 `didStopUserGesture()` 一次 → 计数
///    永久 >0 → 全 app 点击死。
/// 2. **手势进行中路由被程序化 `pop`**：框架把 `didStopUserGesture` 挂在路由动画的
///    status listener 上，路由随即被销毁、`AnimationController` 一并 dispose，那个
///    回调永远不会触发 → 计数永久 >0 → 全 app 点击死。
/// 3. **`commitBackGesture` 之后又来一个 `cancelBackGesture`**（同样是平台重发）：
///    第二次减法让计数变负，debug 下直接踩 `assert(_userGesturesInProgress > 0)`，
///    release 下静默为负，此后一次合法手势只能把它加回 0，预测返回动画整段失效。
///
/// 这三条都不是 app 能约束的：事件由 Android 平台层发出，序列在不同 OEM / 不同手势
/// 识别路径上并不保证严格配对。**能收敛的只有 app 这一侧**——所以这里不再让平台事件
/// 直接驱动全局计数，而是先过一个显式状态机（[_FushiPredictiveBackGestureDetectorState]
/// 的 `_holdsGesture`）：一次手势只认一次开始、一次结束，多余事件丢弃，路由在手势中
/// 途被销毁时补齐那次结束。计数由此恒定配对。
///
/// ## 观感
///
/// 手势期间路由动画仍由 `progress` 驱动（跟手），转场视觉走公开的
/// [FadeForwardsPageTransitionsBuilder]（Android 16 的默认页面转场）。与自带实现相比
/// 少了 shared-element 的圆角缩放观感，换来的是「侧滑返回不会把整个 app 点死」。
///
/// ## 清理条件
///
/// 这是针对上游缺陷的兼容层。Flutter 把上述三条序列的配对修进框架（`TransitionRoute`
/// 侧自带幂等 + dispose 兜底）之后，本文件可整体删除、`pageTransitionsTheme` 改回不
/// 指定 Android builder 即恢复自带观感。
class FushiPredictiveBackPageTransitionsBuilder extends PageTransitionsBuilder {
  /// 创建 Android 预测性返回转场。
  const FushiPredictiveBackPageTransitionsBuilder({this.backgroundColor});

  /// 转场期间露出的背景色，透传给 [FadeForwardsPageTransitionsBuilder]。
  final Color? backgroundColor;

  @override
  Duration get transitionDuration => const Duration(
        milliseconds:
            FadeForwardsPageTransitionsBuilder.kTransitionMilliseconds,
      );

  /// 下层路由的配合动画沿用 [FadeForwardsPageTransitionsBuilder] 的委托转场，
  /// 保证上层页面滑走时下层页面照常配合，不因本包装而丢失。
  @override
  DelegatedTransitionBuilder? get delegatedTransition =>
      FadeForwardsPageTransitionsBuilder(backgroundColor: backgroundColor)
          .delegatedTransition;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return _FushiPredictiveBackGestureDetector(
      route: route,
      child: FadeForwardsPageTransitionsBuilder(
        backgroundColor: backgroundColor,
      ).buildTransitions(
        route,
        context,
        animation,
        secondaryAnimation,
        child,
      ),
    );
  }
}

/// 把平台的预测性返回事件收敛成「一次手势 = 一次开始 + 一次结束」的状态机，再交给
/// [PredictiveBackRoute]。见 [FushiPredictiveBackPageTransitionsBuilder] 的类注释。
class _FushiPredictiveBackGestureDetector extends StatefulWidget {
  const _FushiPredictiveBackGestureDetector({
    required this.route,
    required this.child,
  });

  final PageRoute<dynamic> route;
  final Widget child;

  @override
  State<_FushiPredictiveBackGestureDetector> createState() =>
      _FushiPredictiveBackGestureDetectorState();
}

class _FushiPredictiveBackGestureDetectorState
    extends State<_FushiPredictiveBackGestureDetector>
    with WidgetsBindingObserver {
  /// 本 detector 是否正持有一次「已开始、尚未结束」的手势。
  ///
  /// 这是整个修复的核心状态：`didStartUserGesture` 只在它由 false 翻 true 时发生一次，
  /// `didStopUserGesture` 只在它由 true 翻 false 时发生一次（由路由内部完成，或在
  /// [dispose] 里兜底），因此平台重发事件、或路由被中途销毁，都不会让全局计数失配。
  bool _holdsGesture = false;

  /// 手势开始时所在的 [NavigatorState]。[dispose] 兜底时路由可能已经和 navigator
  /// 解绑（`route.navigator` 变 null），拿不到就无法把计数拉平，所以在开始时就记下。
  NavigatorState? _gestureNavigator;

  bool get _canStartGesture =>
      widget.route.isCurrent && widget.route.popGestureEnabled;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    // 手势进行中路由被销毁（典型：手势没结束就被程序化 pop / 路由栈被替换）。框架把
    // 那次 didStopUserGesture 挂在路由动画的 status listener 上，而 controller 已随
    // 路由 dispose，回调永不触发。这里补齐，否则全局计数永久 >0 = 全 app 点击死。
    if (_holdsGesture) {
      _holdsGesture = false;
      _releaseNavigatorGesture();
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 把 navigator 的手势计数减回去（仅在确实还持有时）。
  ///
  /// 必须延到帧末：本方法唯一的调用点是 [dispose]，而 element unmount 期间 widget 树
  /// 是锁定的，`didStopUserGesture` 会经 `userGestureInProgressNotifier` 触发
  /// `setState` → 直接调用就是「树锁定期 markNeedsBuild」。[ensureVisualUpdate] 不能省：
  /// 手势中途被打断时树可能已经静止，没有新帧就没有 post-frame 回调。
  void _releaseNavigatorGesture() {
    final NavigatorState? navigator = _gestureNavigator;
    _gestureNavigator = null;
    if (navigator == null) return;
    final WidgetsBinding binding = WidgetsBinding.instance;
    binding.addPostFrameCallback((Duration _) {
      if (!navigator.mounted) return;
      if (!navigator.userGestureInProgress) return;
      navigator.didStopUserGesture();
    });
    binding.ensureVisualUpdate();
  }

  // ── WidgetsBindingObserver：预测性返回事件入口 ─────────────────────────────

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    // 平台对同一次手势重发起始事件（口子 1）。已经持有手势就不再计一次开始，只把
    // 进度接上；仍然返回 true，保证后续 commit/cancel 依旧落到本 detector。
    if (_holdsGesture) {
      widget.route
          .handleUpdateBackGestureProgress(progress: 1 - backEvent.progress);
      return true;
    }
    // 系统返回键（非手势）与「本路由不允许手势返回」都不接管：交回框架走普通
    // pop 语义（例如首页设置 tab 的 PopScope 拦截切回来源 tab）。
    if (backEvent.isButtonEvent || !_canStartGesture) {
      return false;
    }
    _holdsGesture = true;
    _gestureNavigator = widget.route.navigator;
    widget.route.handleStartBackGesture(progress: 1 - backEvent.progress);
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    if (!_holdsGesture) return;
    widget.route
        .handleUpdateBackGestureProgress(progress: 1 - backEvent.progress);
  }

  @override
  void handleCommitBackGesture() {
    // 未持有手势时的 commit 是平台重发（口子 3）：丢弃，绝不二次减计数。
    if (!_holdsGesture) return;
    _holdsGesture = false;
    _gestureNavigator = null; // 结束由路由自身完成，不再需要兜底。
    widget.route.handleCommitBackGesture();
  }

  @override
  void handleCancelBackGesture() {
    if (!_holdsGesture) return;
    _holdsGesture = false;
    _gestureNavigator = null;
    widget.route.handleCancelBackGesture();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
