import 'dart:async';

import 'package:flutter/scheduler.dart' show FrameCallback, SchedulerBinding;
import 'package:material_ui/material_ui.dart';

/// State 持有的外部资源登记器：生命周期方法（[initState]、[didChangeDependencies]、
/// [didUpdateWidget]）里挂上的订阅 / 监听 / Timer / 观察者 / 赋出去的回调都经它
/// 登记，[dispose] 与「元素被停用后再也不会 dispose」的几条孤儿路径共用同一份撤销
/// 清单（BUG-5604）。纯生命周期工具，与设计系统无关。
///
/// 为什么需要：Flutter 有三条路径只停用元素、**永远不 unmount、不调 [dispose]**，
/// `State.mounted` 也一直是 true：
/// 1. initState 抛错——`Element.inflateWidget` 走 `_deactivateFailedChildSilently`；
/// 2. 首次 didChangeDependencies 抛错——同上（它与 initState 同在 `_firstBuild` 里）；
/// 3. didUpdateWidget 抛错——父级 `ComponentElement.performRebuild` 的 catch 只对
///    旧子元素调一次 `deactivate()`（不递归、不进 inactive 列表）就换上 ErrorWidget，
///    旧子树整棵被丢掉。
/// 已挂上的订阅、监听和 Timer 于是成了孤儿：dispose 撤不掉，`mounted` 也挡不住，回调
/// 之后再读 `ref` / `context` 就撞「Looking up a deactivated widget's ancestor」断言，
/// 同时泄漏（BUG-5602 是视频库页上的一例）。
///
/// 本 mixin 做两件事：
/// 1. 登记 API：[ownSubscription] / [listenTo] / [ownTimer] / [onTeardown]。登记
///    发生在挂载**成功之后**（`addListener` 抛错就不登记，不会去撤一个没挂上的）。
///    带 `slot:` 时同一个槽位只保留最新一条：再登记先撤上一条（didUpdateWidget 换
///    controller、反复重排的 Timer 用它，清单不会越攒越长）。
/// 2. 判定孤儿并撤销：
///    - 没见过第一次 [didChangeDependencies] 就走到 [deactivate]（initState 抛错），
///      当场按登记逆序撤销；initState 里另排一个微任务兜底——子类的 [deactivate] 覆写
///      若在调 `super` 之前抛错，框架（`_deactivateFailedSubtreeRecursively`）吞掉
///      异常、本 mixin 的 [deactivate] 不会执行，微任务不经过任何子类覆写，一定会跑到；
///    - 其余停用：排一个帧后检查。正常停用在本帧 `finalizeTree` 里要么被 unmount
///      （调 dispose）、要么经 GlobalKey 重新 [activate]；帧后回调时仍处于停用态 = 上面
///      2、3 两条路径的孤儿，撤销本 State 及其子树里所有登记过的资源（路径 3 的子树
///      没被停用，也永远不会 dispose）。
///
/// 生命周期方法里要排「首帧之后再做」的事一律用 [schedulePostFrame]：成了孤儿之后它
/// 不回调。
///
/// 撤不回来的是已经起跑的 Future（`unawaited(_load())`）：它们只认 `mounted`，而
/// 孤儿 State 的 `mounted` 恒为 true。所以首帧取数 / 后台任务一律放在 initState
/// **最后一步**起（BUG-5602 的做法），拿到要撤的产物时用 [resourcesReleased] 把关。
/// 不覆写 `mounted`：覆写后 `use_build_context_synchronously` 不再认它是
/// `State.mounted`，全部 async 闸门都会报警。
///
/// 正常退场时撤销默认在 `super.dispose()` 里跑（子类 dispose 通常最后才调 super），
/// 所以**只登记外部对象**（全局 notifier、仓库 stream、binding 观察者等）；本 State
/// 自己创建并 dispose 的 controller 上的监听不必登记，它们随 controller 一起死。
/// 撤销必须早于 dispose 里某一步（如先从宿主 detach 再 dispose 自有宿主、先注销
/// 再释放）时，在 dispose 的那个位置显式调 [releaseResources]：清单在那里跑完，
/// `super.dispose()` 里不再重复。只有个别撤销要卡在 dispose 的特定位置（进程级
/// 注册表的注销、显示态还原等，前后步骤有依赖）时，留住 [onTeardown] 返回的
/// [ScopedRelease]，在 dispose 原来的位置调它的 [ScopedRelease.release]：只跑一次，
/// 并从清单里摘掉；成了孤儿时它照常按登记逆序随清单撤。自有对象若在 initState 里
/// 创建、且需要在孤儿路径上一起释放，就把它的 dispose 也 [onTeardown] 登记在依赖
/// 它的资源**之前**（逆序撤销 = 先撤依赖方、后释放它）。
///
/// 撤销清单跑过之后（孤儿 / 已 dispose）再登记的资源当场撤销。
///
/// 子类的 [didChangeDependencies] 覆写若在调 `super` 之前抛错，标记没被置上，走
/// initState 失败那一支（同样正确）；覆写若根本不调 `super`（`@mustCallSuper`
/// 静态检查会拦），才会被误判为失败。
mixin StateResourceScope<T extends StatefulWidget> on State<T> {
  final List<ScopedRelease> _teardowns = <ScopedRelease>[];
  final Map<Object, ScopedRelease> _slots = <Object, ScopedRelease>{};
  bool _sawFirstDependencies = false;
  bool _deactivated = false;
  bool _closed = false;

  /// 登记一条流订阅：dispose 或成了孤儿时 `cancel`。返回原订阅，便于存字段。
  /// [slot] 见类注释。
  @protected
  StreamSubscription<E> ownSubscription<E>(
    StreamSubscription<E> subscription, {
    Object? slot,
  }) {
    _register(() => unawaited(subscription.cancel()), slot: slot);
    return subscription;
  }

  /// 给外部 [listenable] 挂 [listener]，挂上之后登记对应的 `removeListener`。
  /// [slot] 见类注释（didUpdateWidget 换了 listenable 时用同一个槽位重挂即可，
  /// 旧的自动摘掉）。[listenable] 为 null = 这回没有要挂的：只把 [slot] 上的旧监听
  /// 摘掉（可选的 widget 参数从有变无）。
  @protected
  void listenTo(Listenable? listenable, VoidCallback listener, {Object? slot}) {
    if (listenable == null) {
      if (slot != null) _register(() {}, slot: slot);
      return;
    }
    listenable.addListener(listener);
    _register(() => listenable.removeListener(listener), slot: slot);
  }

  /// 登记一个 Timer：dispose 或成了孤儿时 `cancel`。返回原 Timer。反复重排的
  /// Timer 传 [slot]，重排时上一个自动取消。
  @protected
  Timer ownTimer(Timer timer, {Object? slot}) {
    _register(timer.cancel, slot: slot);
    return timer;
  }

  /// 登记任意撤销动作（`removeObserver`、`AppLifecycleListener.dispose`、反注册等）。
  /// 资源挂上**之后**再调用（或先登记一条「若挂着就摘」的撤销再挂）。返回值只在
  /// dispose 要把这一条卡在特定位置撤时才需要留住（见 [ScopedRelease]）。[slot] 见
  /// 类注释。
  @protected
  ScopedRelease onTeardown(VoidCallback teardown, {Object? slot}) =>
      _register(teardown, slot: slot);

  ScopedRelease _register(VoidCallback teardown, {Object? slot}) {
    if (slot != null) {
      final ScopedRelease? previous = _slots.remove(slot);
      if (previous != null) _runOne(previous, phase: 'slot replaced');
    }
    final ScopedRelease release = ScopedRelease._(teardown, _teardowns);
    if (_closed) {
      _runOne(release, phase: 'registered after release');
    } else {
      _teardowns.add(release);
      if (slot != null) _slots[slot] = release;
    }
    return release;
  }

  /// 立刻撤掉 [slot] 上登记的那一条（没有就什么都不做），之后该槽位为空。
  ///
  /// 手动「先摘旧的」一律走这里，不要再对同一个对象手写一次 remove：撤销清单收尾
  /// 时还会再摘一遍，有的对象重复摘会抛（`ImageStream` 最后一个监听摘掉后流即
  /// 销毁，再 `removeListener` 是 StateError）。
  @protected
  void releaseSlot(Object slot) {
    final ScopedRelease? previous = _slots.remove(slot);
    if (previous != null) _runOne(previous, phase: 'slot released');
  }

  @override
  void initState() {
    super.initState();
    // 兜底触发点：微任务不经过子类的 deactivate 覆写，挂载失败时一定会跑到。
    scheduleMicrotask(_checkFailedMount);
  }

  void _checkFailedMount() {
    if (!_sawFirstDependencies) _releaseOrphan(phase: 'failed mount');
  }

  /// 撤销清单是否已经跑过（成了孤儿或已 dispose）。
  ///
  /// initState 里起跑的异步任务（撤不回来）在 await 之后用它当「代次」闸门：孤儿
  /// State 的 `mounted` 恒为 true 挡不住，这个挡得住。拿到要撤的产物（起好的服务、
  /// 打开的句柄）时 `if (!mounted || resourcesReleased)` 就当场释放、不再挂上。
  @protected
  bool get resourcesReleased => _closed;

  /// 「首帧之后再做」：孤儿 State 的 `mounted` 恒为 true，post-frame 回调里读
  /// `ref` / `context` 即撞 deactivated 断言（BUG-5604）。经这里排的回调在撤销清单
  /// 跑过之后（孤儿 / 已 dispose）直接跳过；回调时本 State 仍处于停用态（正常停用到
  /// 帧后早已 dispose 或重新 activate）就按孤儿撤销后跳过。
  @protected
  void schedulePostFrame(FrameCallback callback) {
    WidgetsBinding.instance.addPostFrameCallback((Duration timeStamp) {
      if (_closed) return;
      if (_deactivated) {
        _releaseOrphan(phase: 'deactivated, never disposed');
        return;
      }
      callback(timeStamp);
    });
  }

  /// 「本帧构建完再做」（构建期内不能改 provider / setState 时）：代替裸
  /// `scheduleMicrotask`。撤销清单跑过之后（孤儿 / 已 dispose）或回调时本 State 仍处于
  /// 停用态（微任务在本帧 finalizeTree 之后才跑，此时还停用即孤儿）就跳过（BUG-5604）。
  @protected
  void scheduleScopedMicrotask(VoidCallback callback) {
    scheduleMicrotask(() {
      if (_closed || _deactivated) return;
      callback();
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
  void activate() {
    super.activate();
    _deactivated = false;
  }

  @override
  void deactivate() {
    super.deactivate();
    _deactivated = true;
    if (!_sawFirstDependencies) {
      _releaseOrphan(phase: 'failed mount');
      return;
    }
    // 首次 didChangeDependencies / didUpdateWidget 抛错的孤儿只能事后认：帧后仍停用。
    WidgetsBinding.instance.addPostFrameCallback(_checkOrphaned);
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  void _checkOrphaned(Duration _) {
    if (_closed || !_deactivated) return;
    _releaseOrphan(phase: 'deactivated, never disposed');
  }

  /// 撤本 State 的清单，再撤子树里登记过的资源：didUpdateWidget 抛错时父级只停用了
  /// 本元素自身，子树既没被停用、也永远不会 dispose。
  void _releaseOrphan({required String phase}) {
    if (_closed) return;
    _runTeardowns(phase: phase);
    void visit(Element element) {
      if (element is StatefulElement) {
        final State<StatefulWidget> state = element.state;
        if (state is StateResourceScope<StatefulWidget> && !state._closed) {
          state._runTeardowns(phase: 'orphaned ancestor ($phase)');
        }
      }
      element.visitChildren(visit);
    }

    (context as Element).visitChildren(visit);
  }

  @override
  void dispose() {
    _runTeardowns(phase: 'dispose');
    super.dispose();
  }

  void _runTeardowns({required String phase}) {
    _closed = true;
    _slots.clear();
    // 逆序：后挂的先撤（后挂的资源可能依赖先挂的）。逐条隔离，一条抛错不影响其余，
    // 也不盖掉原始错误；错误照常上报。
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
/// 撤（前后步骤有依赖）时调 [release]；只跑一次，并从撤销清单里摘掉。成了孤儿时它
/// 照常随清单按登记逆序撤。与设计系统无关。
final class ScopedRelease {
  ScopedRelease._(this._teardown, this._owner);

  VoidCallback? _teardown;
  List<ScopedRelease>? _owner;

  /// 已经撤过（无论是显式 [release]、槽位被顶替，还是随清单）。
  bool get isReleased => _teardown == null;

  /// 立刻执行这条撤销；重复调用无效果。
  void release() {
    final VoidCallback? teardown = _teardown;
    _teardown = null;
    _owner?.remove(this);
    _owner = null;
    teardown?.call();
  }
}
