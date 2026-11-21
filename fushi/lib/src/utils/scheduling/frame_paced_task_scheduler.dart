// 调度器推迟低优先级任务时不再零延迟空转，改成等下一帧画完再看（BUG-4387 复发的根因修复）。
//
// Flutter 框架 `SchedulerBinding.handleEventLoopCallback`：队首任务被
// [SchedulerBinding.schedulingStrategy] 判「现在不跑」时仍 `return true`，`_runTasks`
// 于是 `Timer.run` 零延迟把自己重新排上。只要有一个真实动画（任何 repeat 的 ticker、
// 不定进度的转圈）一直挂着帧回调，一个 [Priority.idle] 任务就让主线程无限空转：每圈一条
// Dart 自发消息，Windows 嵌入层 `TaskRunnerWindow::WakeUp` 每条都 `PostMessage`，
// `GetMessage` 先取 posted 消息——鼠标、键盘、连同任务栏点图标时系统投来的窗口激活事件
// 全都排不上，窗口点不动、也唤不到前台。
//
// BUG-4387 只把主页背景动画登记成「常驻装饰」（[AmbientTickerProviderStateMixin]），别的
// 常驻动画照样触发同一条空转（2026-11-16 所有者本机 3.3.0-debug.27417：任务栏点 Fushi
// 不上前台，SetForegroundWindow 返回成功但主窗线程始终不处理激活，UI 线程栈 6/6 采样
// 都在 DispatchMessage → 引擎任务窗口 → Dart）。空转本身才是结构问题：被推迟的任务
// 在下一帧之前不可能变得可执行（策略看的就是帧回调），零延迟重查只有代价没有收益。
//
// 修法：包一层调度策略记下「这一圈推迟了」，[handleEventLoopCallback] 看到推迟就
// `return false` 停掉框架的零延迟重排，挂一个 post-frame 回调在下一帧之后重新驱动任务
// 循环。推迟期间每帧最多一次重查，队列有可执行任务时照常连续执行。

import 'dart:async';

import 'package:flutter/scheduler.dart';

/// 给 [SchedulerBinding] 用的 mixin：被推迟的任务按帧节拍重查，不做零延迟空转。
///
/// 只改「推迟时怎么等」，不改「什么时候算可以跑」——那仍由外部设进来的
/// [schedulingStrategy] 决定（生产是 `ambientAwareSchedulingStrategy`）。
mixin FramePacedTaskScheduler on SchedulerBinding {
  SchedulingStrategy _strategy = defaultSchedulingStrategy;

  /// 本类对外暴露的策略永远是这个观察包装；外部读回再设回来（测试里常见的
  /// save / restore）时据此识别，避免把包装包进包装里。
  late final SchedulingStrategy _observingStrategy = _observeStrategy;

  bool _deferredInThisCallback = false;
  bool _retryAfterFrameScheduled = false;

  @override
  SchedulingStrategy get schedulingStrategy => _observingStrategy;

  @override
  set schedulingStrategy(SchedulingStrategy value) {
    if (identical(value, _observingStrategy)) return;
    _strategy = value;
  }

  bool _observeStrategy({
    required int priority,
    required SchedulerBinding scheduler,
  }) {
    final bool allowed = _strategy(priority: priority, scheduler: scheduler);
    if (!allowed) _deferredInThisCallback = true;
    return allowed;
  }

  // 框架任务循环的唯一公开入口；它标 @visibleForTesting 只是为了让测试直接驱动。
  @override
  bool handleEventLoopCallback() {
    _deferredInThisCallback = false;
    // ignore: invalid_use_of_visible_for_testing_member
    final bool more = super.handleEventLoopCallback();
    if (!_deferredInThisCallback) return more;
    _retryAfterNextFrame();
    return false;
  }

  void _retryAfterNextFrame() {
    if (_retryAfterFrameScheduled) return;
    _retryAfterFrameScheduled = true;
    // 推迟只可能因为有帧回调挂着（策略看的就是它），所以下一帧一定会来；窗口不出帧
    // （最小化 / 隐藏）时任务一并等到恢复出帧——此前这段时间是满核空转。
    addPostFrameCallback((Duration _) {
      _retryAfterFrameScheduled = false;
      Timer.run(_pumpTasks);
    }, debugLabel: 'FramePacedTaskScheduler.retry');
  }

  void _pumpTasks() {
    // ignore: invalid_use_of_visible_for_testing_member
    if (handleEventLoopCallback()) Timer.run(_pumpTasks);
  }
}
