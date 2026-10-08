/// 悬浮球的「场景按钮」：页面登记自己能提供的按钮，全局悬浮球取当前路由上的那一组。
///
/// 页面在自己的树里放一个零尺寸的 [FloatingBallScene]；它挂载时把场景种类与按钮
/// （按 [FloatingBallScope.sceneButtonIds] 里的 id）登记进
/// [FloatingBallSceneRegistry]，卸载时撤掉。宿主（`AppFloatingBallHost`）取
/// **当前路由**（[ModalRoute.isCurrent]）上最后登记的那一组——被别的页面盖住的
/// 页面虽然还挂着，它的按钮不会出现——再按用户在 设置 → 悬浮球 里为这个场景勾选的
/// 按钮挑出要显示的。路由切换经 [floatingBallRouteObserver] 通知宿主重算。
library;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';
import 'package:fushi/src/floating_ball/floating_ball_config.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart';

/// 一组登记中的场景按钮。
class _SceneEntry {
  _SceneEntry(this.state);

  final _FloatingBallSceneState state;

  FloatingBallScope get scope => state.widget.scope;
  Map<String, ReaderHeaderAction> get actions => state.widget.actions;
  bool get hidesBall => state.widget.hideBall;
  List<String> get pinnedIds => state.widget.pinnedIds;

  bool get isCurrent {
    if (!state.mounted || !state._active) return false;
    final ModalRoute<Object?>? route = ModalRoute.of(state.context);
    // 不在任何路由里（直接挂在根上）视为当前。
    return route == null || route.isCurrent;
  }

  /// 场景所在的页面（路由）；不在路由里时用场景本身。
  Object get owner {
    if (!state.mounted || !state._active) return state;
    return ModalRoute.of(state.context) ?? state;
  }
}

/// 当前生效的场景（宿主每次重建读一次）。
class FloatingBallSceneSnapshot {
  const FloatingBallSceneSnapshot({
    required this.scope,
    required this.actions,
    required this.hidesBall,
    this.pinnedIds = const <String>[],
    this.owner,
  });

  /// 没有登记场景的页面：按「其它页面」的按钮配置。
  static const FloatingBallSceneSnapshot none = FloatingBallSceneSnapshot(
    scope: FloatingBallScope.general,
    actions: <String, ReaderHeaderAction>{},
    hidesBall: false,
  );

  /// 按哪个场景的按钮配置显示。
  final FloatingBallScope scope;

  /// 页面此刻能提供的专属按钮（id → 动作）；没提供的 id 即使勾选了也不显示。
  final Map<String, ReaderHeaderAction> actions;

  /// 页面要求此刻不显示悬浮球（例如全屏播放锁定时）。
  final bool hidesBall;

  /// 页面把自己的必需入口托付给球（[FloatingBallScene.pinnedIds]）：非空时这些
  /// 按钮不看勾选、恒在最上面，球也不给「关闭」键。
  final List<String> pinnedIds;

  /// 「这一次页面」的身份：场景所在的路由，没场景的页面取最上层的整页路由。
  /// 宿主据此判断用户是否已经离开了点「关闭悬浮球」的那个页面（离开即恢复）。
  /// 用路由而不是场景 State：页面上弹对话框时场景暂时不是当前，但人还在这页。
  final Object? owner;
}

/// 进程级场景登记表。
class FloatingBallSceneRegistry extends ChangeNotifier {
  FloatingBallSceneRegistry._();

  static final FloatingBallSceneRegistry instance =
      FloatingBallSceneRegistry._();

  final List<_SceneEntry> _entries = <_SceneEntry>[];
  bool _notifyScheduled = false;

  /// 根导航器上最上层的整页路由（对话框 / 弹层这类非整页路由不算）。
  Route<dynamic>? _topPage;

  /// 当前路由上最后登记的场景；没有则 [FloatingBallSceneSnapshot.none]。
  FloatingBallSceneSnapshot get current {
    for (int i = _entries.length - 1; i >= 0; i--) {
      final _SceneEntry entry = _entries[i];
      if (!entry.isCurrent) continue;
      return FloatingBallSceneSnapshot(
        scope: entry.scope,
        actions: entry.actions,
        hidesBall: entry.hidesBall,
        pinnedIds: entry.pinnedIds,
        owner: entry.owner,
      );
    }
    final Route<dynamic>? top = _topPage;
    if (top == null) return FloatingBallSceneSnapshot.none;
    return FloatingBallSceneSnapshot(
      scope: FloatingBallScope.general,
      actions: const <String, ReaderHeaderAction>{},
      hidesBall: false,
      owner: top,
    );
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

  /// 根导航器的最上层整页路由变了（[FloatingBallRouteObserver] 维护）。
  void _setTopPage(Route<dynamic>? route) => _topPage = route;

  Route<dynamic>? get _currentTopPage => _topPage;

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
    _topPage = null;
  }
}

/// 页面放进自己树里的零尺寸登记器。
class FloatingBallScene extends StatefulWidget {
  const FloatingBallScene({
    required this.scope,
    required this.actions,
    this.hideBall = false,
    this.pinnedIds = const <String>[],
    this.child = const SizedBox.shrink(),
    super.key,
  });

  /// 本页属于哪个场景（决定用哪一组按钮配置）。
  final FloatingBallScope scope;

  /// 本页此刻能提供的专属按钮，键是 [FloatingBallScope.sceneButtonIds] 里的 id。
  final Map<String, ReaderHeaderAction> actions;

  /// true 时本页此刻不显示悬浮球。
  final bool hideBall;

  /// 本页此刻把必需入口交给球接管（例如阅读器关掉了顶栏和底栏：返回 / 设置 /
  /// 开回栏只剩球上这一处）。这些 id 必须在 [actions] 里；宿主不看用户勾选、把它们
  /// 排在最上面，且不给「关闭悬浮球」——关掉球就等于把人关在页面里。
  final List<String> pinnedIds;

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
        oldWidget.scope != widget.scope ||
        !listEquals(oldWidget.pinnedIds, widget.pinnedIds) ||
        !sameFloatingBallActions(oldWidget.actions, widget.actions)) {
      _registry._scheduleNotify();
    }
  }

  /// 元素是否处于活动态。整棵子树被摘下（例如切换设计系统时外壳结构变化、
  /// GlobalKey 重挂）后到 dispose / 重新挂上之前，元素仍 mounted 但已停用：
  /// 这期间宿主重建若对它做 `ModalRoute.of`，会在停用元素上查祖先而断言，
  /// 并连锁成整屏红。停用期间登记项视为不在当前路由。
  bool _active = true;

  @override
  void deactivate() {
    _active = false;
    _registry._scheduleNotify();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _active = true;
    _registry._scheduleNotify();
  }

  @override
  void dispose() {
    _registry._remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 两组按钮在外观上是否一致（id、图标、文案、key、可用态）。闭包不参与比较：页面
/// 每次重建都给新闭包，指向的却是同一个 State 方法。
bool sameFloatingBallActions(
  Map<String, ReaderHeaderAction> a,
  Map<String, ReaderHeaderAction> b,
) {
  if (a.length != b.length) return false;
  for (final MapEntry<String, ReaderHeaderAction> entry in a.entries) {
    final ReaderHeaderAction? other = b[entry.key];
    final ReaderHeaderAction mine = entry.value;
    if (other == null ||
        mine.icon != other.icon ||
        mine.label != other.label ||
        mine.key != other.key ||
        (mine.onPressed == null) != (other.onPressed == null)) {
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
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute) _registry._setTopPage(route);
    _registry.routeChanged();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _popTopPage(route, previousRoute);
    _registry.routeChanged();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _popTopPage(route, previousRoute);
    _registry.routeChanged();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (identical(oldRoute, _registry._currentTopPage) &&
        newRoute is PageRoute) {
      _registry._setTopPage(newRoute);
    }
    _registry.routeChanged();
  }

  /// 最上层整页被弹掉：退回它下面的那一页（下面若是弹层就沿用不了，置空）。
  void _popTopPage(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (!identical(route, _registry._currentTopPage)) return;
    _registry._setTopPage(previousRoute is PageRoute ? previousRoute : null);
  }
}

final FloatingBallRouteObserver floatingBallRouteObserver =
    FloatingBallRouteObserver(FloatingBallSceneRegistry.instance);
