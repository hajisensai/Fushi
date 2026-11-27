import 'dart:async';

import 'package:flutter/scheduler.dart' show FrameCallback;
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
/// 2. 判定挂载失败：框架在 `_firstBuild` 里 initState 返回后**同步**紧接着调第一次
///    [didChangeDependencies]；没见过它就已经走到 [deactivate]、或者 initState 里排的
///    微任务跑起来时还没见过它 = 挂载半途抛错。此时按登记的逆序撤销全部资源。
///    两个触发点互为兜底：[deactivate] 是同步的、最早；但子类的 [deactivate] 覆写
///    若在调 `super` 之前抛错，框架（`_deactivateFailedSubtreeRecursively`）吞掉异常、
///    本 mixin 的 [deactivate] 不会执行——微任务不经过任何子类覆写，一定会跑到。
///
/// initState 里要排「首帧之后再做」的事一律用 [schedulePostFrame]：挂载失败后它不回调。
///
/// 撤不回来的是已经起跑的 Future（`unawaited(_load())`）：它们只认 `mounted`，而
/// 孤儿 State 的 `mounted` 恒为 true。所以首帧取数 / 后台任务一律放在 initState
/// **最后一步**起（BUG-5602 的做法）。不覆写 `mounted`：覆写后
/// `use_build_context_synchronously` 不再认它是 `State.mounted`，全部 async 闸门都会报警。
///
/// 正常退场时撤销默认在 `super.dispose()` 里跑（子类 dispose 通常最后才调 super），
/// 所以**只登记外部对象**（全局 notifier、仓库 stream、binding 观察者等）；本 State
/// 自己创建并 dispose 的 controller 上的监听不必登记，它们随 controller 一起死。
/// 撤销必须早于 dispose 里某一步（如先从宿主 detach 再 dispose 自有宿主、先注销
/// 再释放）时，在 dispose 的那个位置显式调 [releaseResources]：清单在那里跑完，
/// `super.dispose()` 里不再重复。只有个别撤销要卡在 dispose 的特定位置（进程级
/// 注册表的注销、显示态还原等，前后步骤有依赖）时，留住 [onTeardown] 返回的
/// [ScopedRelease]，在 dispose 原来的位置调它的 [ScopedRelease.release]：只跑一次，
/// 清单里随后跳过；挂载失败时它照常按登记逆序随清单撤。挂载失败时同一份清单照登记逆序跑——自有对象若
/// 在 initState 里创建、且需要在失败时一起释放，就把它的 dispose 也 [onTeardown]
/// 登记在依赖它的资源**之前**（逆序撤销 = 先撤依赖方、后释放它）。
///
/// 撤销清单跑过之后（挂载失败 / 已 dispose）再登记的资源当场撤销：initState 里排的
/// `addPostFrameCallback` 在挂载失败后的那一帧仍会回调，回调里挂的订阅由此不会漏。
///
/// 子类的 [didChangeDependencies] 覆写若在调 `super` 之前抛错，挂载同样失败，
/// 标记没被置上，按失败处理（正确）；覆写若根本不调 `super`（`@mustCallSuper`
/// 静态检查会拦），才会被误判为失败。
mixin StateResourceScope<T extends StatefulWidget> on State<T> {
  final List<ScopedRelease> _teardowns = <ScopedRelease>[];
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
  /// 资源挂上**之后**再调用。返回值只在 dispose 要把这一条卡在特定位置撤时才需要
  /// 留住（见 [ScopedRelease]）。
  @protected
  ScopedRelease onTeardown(VoidCallback teardown) => _register(teardown);

  /// 撤销清单已经跑过（挂载失败 / 已 dispose）之后才登记的资源——典型是
  /// initState 里排的 `addPostFrameCallback` 在失败后那一帧仍会回调、挂上订阅——
  /// 当场撤销，不留孤儿。
  ScopedRelease _register(VoidCallback teardown) {
    final ScopedRelease release = ScopedRelease._(teardown);
    if (_closed) {
      _runOne(release, phase: 'registered after release');
    } else {
      _teardowns.add(release);
    }
    return release;
  }

  @override
  void initState() {
    super.initState();
    // 兜底触发点：微任务不经过子类的 deactivate 覆写，挂载失败时一定会跑到。
    scheduleMicrotask(_checkFailedMount);
  }

  void _checkFailedMount() {
    if (!_sawFirstDependencies) _onFailedMount();
  }

  void _onFailedMount() {
    if (_mountFailed) return;
    // 挂载半途抛错：框架不会再调 dispose，这里就是唯一的撤销时机。
    _mountFailed = true;
    _runTeardowns(phase: 'failed mount');
  }

  /// 撤销清单是否已经跑过（挂载失败或已 dispose）。
  ///
  /// initState 里起跑的异步任务（撤不回来）在 await 之后用它当「代次」闸门：孤儿
  /// State 的 `mounted` 恒为 true 挡不住，这个挡得住。拿到要撤的产物（起好的服务、
  /// 打开的句柄）时 `if (!mounted || resourcesReleased)` 就当场释放、不再挂上。
  @protected
  bool get resourcesReleased => _closed;

  /// initState 里排的「首帧之后再做」：挂载半途抛错时框架照样会回调 post-frame
  /// 回调，而孤儿 State 的 `mounted` 恒为 true，回调里读 `ref` / `context` 即撞
  /// deactivated 断言（BUG-5604）。经这里排的回调在撤销清单跑过之后（挂载失败 /
  /// 已 dispose）直接跳过。
  @protected
  void schedulePostFrame(FrameCallback callback) {
    WidgetsBinding.instance.addPostFrameCallback((Duration timeStamp) {
      if (_closed) return;
      callback(timeStamp);
    });
  }

  /// 在 dispose 里的这个位置立刻撤销全部登记（见类注释「撤销必须早于」）；之后
  /// `super.dispose()` 不再重复，再登记的资源当场撤销。只该在 [dispose] 里调。
  @protected
  void releaseResources() => _runTeardowns(phase: 'dispose');

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sawFirstDependencies = true;
  }

  @override
  void deactivate() {
    super.deactivate();
    if (!_sawFirstDependencies) _onFailedMount();
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
    final List<ScopedRelease> pending = List<ScopedRelease>.of(_teardowns);
    _teardowns.clear();
    for (final ScopedRelease release in pending.reversed) {
      _runOne(release, phase: phase);
    }
  }

  void _runOne(ScopedRelease release, {required String phase}) {
    try {
      release.release();
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

/// [StateResourceScope.onTeardown] 登记的一条撤销。dispose 里需要把它卡在特定位置
/// 撤（前后步骤有依赖）时调 [release]；只跑一次，之后撤销清单里跳过它。挂载失败时
/// 它照常随清单按登记逆序撤。与设计系统无关。
final class ScopedRelease {
  ScopedRelease._(this._teardown);

  VoidCallback? _teardown;

  /// 已经撤过（无论是显式 [release] 还是随清单）。
  bool get isReleased => _teardown == null;

  /// 立刻执行这条撤销；重复调用无效果。
  void release() {
    final VoidCallback? teardown = _teardown;
    _teardown = null;
    teardown?.call();
  }
}
