// 打开反馈中心的入口闸：自动截图必须截「用户此刻停着的那一页」，不能截到页面转场
// 的中间帧（BUG-3097）。
//
// 截图本来就在 push 反馈中心**之前**截（`openFeedbackCenter`），但「之前」只保证了
// 不截到反馈中心自己的进场动画，没保证截的那一帧已经静止：
//
// - 悬浮球浮在导航之上，任何时候都点得到——第一次点击还在截图 / 反馈中心正在淡入时
//   再点一次，第二次截到的就是「反馈中心半透明叠在视频页上」的一帧，并且又压了一个
//   反馈中心进栈（用户随后在上面那个里提交，带的正是这张叠画）；
// - 从反馈中心按返回，它淡出的过程中下层页面已经能接收点击（Flutter 退场中的路由
//   IgnorePointer），这时再点首页 / 悬浮球的反馈入口，截到的同样是转场帧。
//
// 修法：①入口单飞——反馈中心从点击到被弹出期间只认第一次打开；②截图前等导航栈上所有
// 进出场动画走完，并等这一帧画完，再截。等的是动画状态事件，不是定时延迟。

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/scheduler.dart';
import 'package:fushi/src/feedback/feedback_diagnostics.dart';
import 'package:material_ui/material_ui.dart';

/// 记下导航栈上的路由（含正在退场、还没画完的），回答「现在有没有转场在跑」。
///
/// 只观察挂了它的那个 Navigator（根导航）；嵌套导航里的转场不在它的视野里。
class RouteTransitionTracker extends NavigatorObserver {
  /// 栈上的路由 + 已弹出但退场动画还没走完的路由。
  final Set<Route<dynamic>> _routes = <Route<dynamic>>{};

  /// 等「有变化」的人：任何导航事件都叫醒他们重新判断。
  final Set<Completer<void>> _wakers = <Completer<void>>{};

  /// 此刻有没有路由正在进场 / 退场。
  bool get isAnimating => _running().isNotEmpty;

  List<Animation<double>> _running() => <Animation<double>>[
    for (final Route<dynamic> route in _routes)
      if (route is TransitionRoute<dynamic> &&
          route.animation != null &&
          route.animation!.isAnimating)
        route.animation!,
  ];

  void _wake() {
    for (final Completer<void> c in _wakers.toList()) {
      if (!c.isCompleted) c.complete();
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
    _wake();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // 退场动画还在跑：先留着，等它 dismissed 再删——这期间截图要等。
    final Animation<double>? animation = route is TransitionRoute<dynamic>
        ? route.animation
        : null;
    if (animation == null || animation.status == AnimationStatus.dismissed) {
      _routes.remove(route);
    } else {
      void onStatus(AnimationStatus status) {
        if (status != AnimationStatus.dismissed) return;
        animation.removeStatusListener(onStatus);
        _routes.remove(route);
        _wake();
      }

      animation.addStatusListener(onStatus);
    }
    _wake();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _wake();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null) _routes.remove(oldRoute);
    if (newRoute != null) _routes.add(newRoute);
    _wake();
  }

  /// 等到没有转场在跑。返回值：是否真的等过（等过的话调用方还要等这一帧画完）。
  Future<bool> whenSettled() async {
    bool waited = false;
    while (true) {
      final List<Animation<double>> running = _running();
      if (running.isEmpty) return waited;
      waited = true;
      final Completer<void> change = Completer<void>();
      void onStatus(AnimationStatus _) {
        if (!change.isCompleted) change.complete();
      }

      for (final Animation<double> a in running) {
        a.addStatusListener(onStatus);
      }
      _wakers.add(change);
      try {
        await change.future;
      } finally {
        _wakers.remove(change);
        for (final Animation<double> a in running) {
          a.removeStatusListener(onStatus);
        }
      }
    }
  }
}

/// 反馈中心入口：单飞 + 截静止帧。
class FeedbackEntryGate {
  FeedbackEntryGate({required this.transitions, required this.capture});

  final RouteTransitionTracker transitions;
  final Future<Uint8List?> Function() capture;

  bool _open = false;

  /// 反馈中心是否已经开着（从点击打开到它被弹出）。
  bool get isOpen => _open;

  /// [captureScreen] 时先等转场走完、这一帧画完，再截图，然后 push [route] 造出的
  /// 页面。已经开着时直接忽略（不再截图、不再压第二个反馈中心）。
  Future<void> open(
    BuildContext context, {
    required bool captureScreen,
    required Route<void> Function(Uint8List? shot) route,
  }) async {
    if (_open) return;
    _open = true;
    try {
      Uint8List? shot;
      if (captureScreen) {
        if (await transitions.whenSettled()) {
          // 动画状态在帧的 transient 回调里变成静止，但这一帧的画面（退场路由
          // 已摘掉）要到本帧绘制后才有。
          await SchedulerBinding.instance.endOfFrame;
        }
        if (!context.mounted) return;
        shot = await capture();
      }
      if (!context.mounted) return;
      await Navigator.push(context, route(shot));
    } finally {
      _open = false;
    }
  }
}

/// 根导航上的转场跟踪（`main.dart` 的 navigatorObservers 里挂）。
final RouteTransitionTracker feedbackRouteTransitions =
    RouteTransitionTracker();

/// 首页按钮与悬浮球共用的反馈中心入口闸（经 `openFeedbackCenter`）。
final FeedbackEntryGate feedbackEntryGate = FeedbackEntryGate(
  transitions: feedbackRouteTransitions,
  capture: captureFeedbackScreenshot,
);
