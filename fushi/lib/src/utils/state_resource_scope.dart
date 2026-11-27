import 'dart:async';

import 'package:material_ui/material_ui.dart';

/// State 持有的外部资源登记器：[initState] 里挂上的订阅 / 监听 / Timer / 观察者
/// 都经它登记，[dispose] 与「initState 半途抛错」这两条退场路径共用同一份撤销清单
/// （BUG-5604）。纯生命周期工具，与设计系统无关。
///
/// 为什么需要：initState 抛错时 Flutter 的 `Element.inflateWidget` 走
/// `_deactivateFailedChildSilently`——只调 [deactivate]，**永远不 unmount、不调
/// [dispose]**，`State.mounted` 也一直是 true。抛错点之前已挂上的订阅、监听和
/// Timer 于是成了孤儿：dispose 撤不掉，`mounted` 也挡不住，回调之后再读
/// `ref` / `context` 就撞「Looking up a deactivated widget's ancestor」断言，
/// 同时泄漏（BUG-5602 是视频库页上的一例）。
///
/// 本 mixin 做两件事：
/// 1. 登记 API：[ownSubscription] / [listenTo] / [ownTimer] / [onTeardown]。登记
///    发生在挂载**成功之后**（`addListener` 抛错就不登记，不会去撤一个没挂上的）。
/// 2. 判定挂载失败：框架在 `_firstBuild` 里 initState 返回后紧接着调第一次
///    [didChangeDependencies]；走到 [deactivate] 时还没见过它 = initState 半途抛错。
///    此时按登记的逆序撤销全部资源。
///
/// 撤不回来的是已经起跑的 Future（`unawaited(_load())`）：它们只认 `mounted`，而
/// 孤儿 State 的 `mounted` 恒为 true。所以首帧取数 / 后台任务一律放在 initState
/// **最后一步**起（BUG-5602 的做法）。不覆写 `mounted`：覆写后
/// `use_build_context_synchronously` 不再认它是 `State.mounted`，全部 async 闸门都会报警。
///
/// 正常退场时撤销在 `super.dispose()` 里跑（子类 dispose 通常最后才调 super），
/// 所以**只登记外部对象**（全局 notifier、仓库 stream、binding 观察者等）；本 State
/// 自己创建并 dispose 的 controller 上的监听不必登记，它们随 controller 一起死。
///
/// 撤销清单跑过之后（挂载失败 / 已 dispose）再登记的资源当场撤销：initState 里排的
/// `addPostFrameCallback` 在挂载失败后的那一帧仍会回调，回调里挂的订阅由此不会漏。
///
/// 已知边界：子类的 [didChangeDependencies] 覆写若在调 `super` **之前**抛错，
/// 本 mixin 仍按「挂载成功」处理（覆写一律先调 super，`@mustCallSuper` 有静态检查）；
/// 子类的 [deactivate] 覆写若在调 `super` 之前抛错，框架吞掉异常、撤销不会执行。
mixin StateResourceScope<T extends StatefulWidget> on State<T> {
  final List<VoidCallback> _teardowns = <VoidCallback>[];
  bool _sawFirstDependencies = false;
  bool _mountFailed = false;
  bool _closed = false;

  /// 登记一条流订阅：dispose 或挂载失败时 `cancel`。返回原订阅，便于存字段。
  @protected
  StreamSubscription<E> ownSubscription<E>(StreamSubscription<E> subscription) {
    _register(() => unawaited(subscription.cancel()));
    return subscription;
  }

  /// 给外部 [listenable] 挂 [listener]，挂上之后登记对应的 `removeListener`。
  @protected
  void listenTo(Listenable listenable, VoidCallback listener) {
    listenable.addListener(listener);
    _register(() => listenable.removeListener(listener));
  }

  /// 登记一个 Timer：dispose 或挂载失败时 `cancel`。返回原 Timer。
  @protected
  Timer ownTimer(Timer timer) {
    _register(timer.cancel);
    return timer;
  }

  /// 登记任意撤销动作（`removeObserver`、`AppLifecycleListener.dispose`、反注册等）。
  /// 资源挂上**之后**再调用。
  @protected
  void onTeardown(VoidCallback teardown) => _register(teardown);

  /// 撤销清单已经跑过（挂载失败 / 已 dispose）之后才登记的资源——典型是
  /// initState 里排的 `addPostFrameCallback` 在失败后那一帧仍会回调、挂上订阅——
  /// 当场撤销，不留孤儿。
  void _register(VoidCallback teardown) {
    if (_closed) {
      _runOne(teardown, phase: 'registered after release');
      return;
    }
    _teardowns.add(teardown);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sawFirstDependencies = true;
  }

  @override
  void deactivate() {
    super.deactivate();
    if (!_sawFirstDependencies && !_mountFailed) {
      // initState 半途抛错：框架不会再调 dispose，这里就是唯一的撤销时机。
      _mountFailed = true;
      _runTeardowns(phase: 'failed mount');
    }
  }

  @override
  void dispose() {
    _runTeardowns(phase: 'dispose');
    super.dispose();
  }

  void _runTeardowns({required String phase}) {
    _closed = true;
    // 逆序：后挂的先撤（后挂的资源可能依赖先挂的）。逐条隔离，一条抛错不影响其余，
    // 也不盖掉 initState 的原始错误；错误照常上报。
    final List<VoidCallback> pending = List<VoidCallback>.of(_teardowns);
    _teardowns.clear();
    for (final VoidCallback teardown in pending.reversed) {
      _runOne(teardown, phase: phase);
    }
  }

  void _runOne(VoidCallback teardown, {required String phase}) {
    try {
      teardown();
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'fushi',
          context: ErrorDescription(
            'while releasing a resource of $runtimeType ($phase)',
          ),
        ),
      );
    }
  }
}
