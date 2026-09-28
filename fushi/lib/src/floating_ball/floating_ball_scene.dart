/// 悬浮球的「场景按钮」：页面登记自己的按钮，全局悬浮球取当前路由上的那一组。
///
/// 页面在自己的树里放一个零尺寸的 [FloatingBallScene]；它挂载时把按钮登记进
/// [FloatingBallSceneRegistry]，卸载时撤掉。宿主（`AppFloatingBallHost`）取
/// **当前路由**（[ModalRoute.isCurrent]）上最后登记的那一组——被别的页面盖住的
/// 页面虽然还挂着，它的按钮不会出现。路由切换经 [floatingBallRouteObserver]
/// 通知宿主重算。
library;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart';

/// 一组登记中的场景按钮。
class _SceneEntry {
  _SceneEntry(this.state);

  final _FloatingBallSceneState state;

  List<ReaderHeaderAction> get actions => state.widget.actions;
  bool get hidesBall => state.widget.hideBall;

  bool get isCurrent {
    if (!state.mounted) return false;
    final ModalRoute<Object?>? route = ModalRoute.of(state.context);
    // 不在任何路由里（直接挂在根上）视为当前。
    return route == null || route.isCurrent;
  }
}

/// 当前生效的场景（宿主每次重建读一次）。
class FloatingBallSceneSnapshot {
  const FloatingBallSceneSnapshot({
    required this.actions,
    required this.hidesBall,
  });

  static const FloatingBallSceneSnapshot none = FloatingBallSceneSnapshot(
    actions: <ReaderHeaderAction>[],
    hidesBall: false,
  );

  final List<ReaderHeaderAction> actions;

  /// 页面要求此刻不显示悬浮球（例如全屏播放锁定时）。
  final bool hidesBall;
}

/// 进程级场景登记表。
class FloatingBallSceneRegistry extends ChangeNotifier {
  FloatingBallSceneRegistry._();

  static final FloatingBallSceneRegistry instance =
      FloatingBallSceneRegistry._();

  final List<_SceneEntry> _entries = <_SceneEntry>[];
  bool _notifyScheduled = false;

  /// 当前路由上最后登记的场景；没有则 [FloatingBallSceneSnapshot.none]。
  FloatingBallSceneSnapshot get current {
    for (int i = _entries.length - 1; i >= 0; i--) {
      final _SceneEntry entry = _entries[i];
      if (!entry.isCurrent) continue;
      return FloatingBallSceneSnapshot(
        actions: entry.actions,
        hidesBall: entry.hidesBall,
      );
    }
    return FloatingBallSceneSnapshot.none;
  }

  void _add(_SceneEntry entry) {
    _entries.add(entry);
    _scheduleNotify();
  }

  void _remove(_FloatingBallSceneState state) {
    _entries.removeWhere((_SceneEntry e) => identical(e.state, state));
    _scheduleNotify();
  }

  /// 路由变了：同一批登记的「当前」归属可能换人。
  void routeChanged() => _scheduleNotify();

  /// 登记 / 撤销发生在页面 build 期（initState / didUpdateWidget / dispose），
  /// 此时宿主不能 setState。帧内推到本帧末尾；空闲期（无帧在跑）直接通知——
  /// idle 相位排的帧后回调在没有别的重建时永远不会跑。
  void _scheduleNotify() {
    if (_notifyScheduled) return;
    final SchedulerPhase phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      notifyListeners();
      return;
    }
    _notifyScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _notifyScheduled = false;
      notifyListeners();
    });
  }

  @visibleForTesting
  void debugReset() {
    _entries.clear();
    _notifyScheduled = false;
  }
}

/// 页面放进自己树里的零尺寸登记器。
class FloatingBallScene extends StatefulWidget {
  const FloatingBallScene({
    required this.actions,
    this.hideBall = false,
    this.child = const SizedBox.shrink(),
    super.key,
  });

  /// 本页的场景按钮（排在全局按钮前面）。
  final List<ReaderHeaderAction> actions;

  /// true 时本页此刻不显示悬浮球。
  final bool hideBall;

  final Widget child;

  @override
  State<FloatingBallScene> createState() => _FloatingBallSceneState();
}

class _FloatingBallSceneState extends State<FloatingBallScene> {
  final FloatingBallSceneRegistry _registry =
      FloatingBallSceneRegistry.instance;

  @override
  void initState() {
    super.initState();
    _registry._add(_SceneEntry(this));
  }

  @override
  void didUpdateWidget(FloatingBallScene oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 页面每次重建都会给出新的闭包；只有看得见的差异（按钮增减、图标 / 文案
    // 变化，例如播放 ⇄ 暂停）才值得让宿主重建。
    if (oldWidget.hideBall != widget.hideBall ||
        !sameFloatingBallActions(oldWidget.actions, widget.actions)) {
      _registry._scheduleNotify();
    }
  }

  @override
  void dispose() {
    _registry._remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 两组按钮在外观上是否一致（图标、文案、key、可用态、顺序）。闭包不参与比较：页面
/// 每次重建都给新闭包，指向的却是同一个 State 方法。
bool sameFloatingBallActions(
  List<ReaderHeaderAction> a,
  List<ReaderHeaderAction> b,
) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i].icon != b[i].icon ||
        a[i].label != b[i].label ||
        a[i].key != b[i].key ||
        (a[i].onPressed == null) != (b[i].onPressed == null)) {
      return false;
    }
  }
  return true;
}

/// 挂进 `MaterialApp.navigatorObservers`：路由进出时让宿主重算当前场景。
class FloatingBallRouteObserver extends NavigatorObserver {
  FloatingBallRouteObserver(this._registry);

  final FloatingBallSceneRegistry _registry;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _registry.routeChanged();

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _registry.routeChanged();

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _registry.routeChanged();

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _registry.routeChanged();
}

final FloatingBallRouteObserver floatingBallRouteObserver =
    FloatingBallRouteObserver(FloatingBallSceneRegistry.instance);
