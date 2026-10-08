import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// BUG-2953：根 Overlay 查词浮层的**自带导航层**——浮层里唤出的菜单必须画在浮层之上，
/// 而「返回」必须先关菜单、再关浮层。
///
/// ## 层级
///
/// 视频页 / 网页视频 / 首页词典 / texthooker 把整棵浮层子树用 `overlay.insert` 手动挂进
/// **根 Navigator 的 Overlay**（为了盖过 media_kit 全屏路由）。对 Navigator 来说这个
/// entry 是「外来户」：之后每次 push，`NavigatorState._flushHistoryUpdates` 都调
/// `overlay.rearrange(路由 entries)`，而 `OverlayState.rearrange` 把不在列表里的旧
/// entry 一律 `insertAll(_entries.length, old)`——**排到所有路由之上**。于是浮层里
/// 弹出的任何 route 型菜单（弹窗 WebView 右键「查词 / 复制」的 `showFushiMenu`、窄顶栏
/// 「⋯」溢出 `PopupMenuButton`）都推进同一个根 Navigator，渲染与命中都在浮层**之下**：
/// 用户报「视频里右键复制，选项跑到查词框后面去」。
///
/// 修法是让浮层与它唤出的菜单走同一套层级：浮层子树自己当一个 [Navigator] 的初始
/// 路由，`Navigator.of(浮层内 context)` 找到的就是它，菜单 route 落在**同一个 entry
/// 里、浮层之上**。不靠重新 insert / 延时，也不依赖调用方记得传 `useRootNavigator`。
///
/// ## 返回（系统返回键 / 预测性返回 / Esc / 手柄 B / 鼠标返回键）
///
/// 菜单住进内层 Navigator 之后，所有「返回」入口仍然只认根 Navigator：系统返回键经
/// `WidgetsApp.didPopRoute` → 根 `maybePop()`，落到页面自己的 `PopScope`（视频页
/// `_dismissTopForegroundLayer`）→ 把浮层连同菜单一起关掉，比改前多退了一级。改前
/// 菜单是根栈顶，返回只关菜单。现在统一成一个判据 [activeMenuNavigator]（最内层、栈上
/// 有可弹路由的查词导航器），所有返回入口**先问它**：
///
/// - 系统返回键：[installSystemBackInterceptor] 在 `runApp` **之前**注册一个
///   [WidgetsBindingObserver]。`WidgetsBinding.handlePopRoute` 按注册顺序问 observer，
///   它排在 `WidgetsApp` 之前，菜单开着时只 pop 菜单并认领，根 `maybePop()` 不会发生，
///   页面 `PopScope` 也就不会被触发。
/// - 预测性返回手势：菜单开着时在**根栈顶路由**上挂一个 `canPop: false` 的
///   [PopEntry]，该路由 `popGestureEnabled` 随之为假，页面不会跟手滑走；手势提交后
///   框架退化成普通返回（`handlePopRoute`），由上一条接住。菜单关掉立即摘除。
/// - Esc / 手柄 B / 用户改绑的「返回」键 / 鼠标返回键：`global_navigation.dart` 与
///   `gamepad_service.dart` 的根兜底在 `maybePop()` 根之前先 [popActiveMenu]。
///
/// ## 其余细节
///
/// - 初始路由是不带 barrier 的 [OverlayRoute]、`requestFocus: false`——挂上浮层不抢
///   媒体页焦点（焦点所有权见 docs/agent/focus-ownership.md），浮层没打开的区域照旧
///   对命中测试透明；Navigator 本身保持默认 `requestFocus`，菜单照常接管键盘。
/// - `clipBehavior: Clip.none`：浮层 Stack 依赖不裁剪让屏外热槽继续栅格化（BUG-135）。
/// - 宿主把它放在 `FushiAppUiScaleNeutralizer` **之外**：菜单仍渲染在缩放画布空间，
///   与改动前（根 Navigator）同系，`_showWindowsContextMenu` 的锚点算法不变。
/// - 对话框（`showAppDialog` 默认 `useRootNavigator: true`）不受影响，仍走
///   `DictionaryPageMixin.runWithLookupPopupHidden` 的让位约定。
class LookupOverlayNavigator extends StatefulWidget {
  const LookupOverlayNavigator({super.key, required this.child});

  /// 浮层子树（宿主 `_buildPopupOverlay` 原本直接返回的那棵）。
  final Widget child;

  /// 已挂载的查词导航层，按挂载先后排列（后挂的在上）。
  static final List<_LookupOverlayNavigatorState> _mounted =
      <_LookupOverlayNavigatorState>[];

  /// 最内层、栈上有可弹路由（菜单）的查词导航器；没有菜单开着时为 null。
  ///
  /// 所有「返回」入口的唯一判据：非 null 时返回只该关这一层菜单。
  static NavigatorState? get activeMenuNavigator {
    for (final _LookupOverlayNavigatorState state in _mounted.reversed) {
      final NavigatorState? navigator = state._navigatorKey.currentState;
      if (navigator != null && navigator.mounted && navigator.canPop()) {
        return navigator;
      }
    }
    return null;
  }

  /// 有菜单开着就 `maybePop` 最内层那一个并返回 true；否则什么都不做、返回 false，
  /// 调用方照旧走自己的返回逻辑（关浮层 / 退页）。
  ///
  /// 走 `maybePop` 而不是 `pop`：菜单路由自己的 `PopScope` / `barrierDismissible`
  /// 契约仍然先跑（内层只承载菜单，目前没有不可关闭的路由）。
  static bool popActiveMenu() {
    final NavigatorState? navigator = activeMenuNavigator;
    if (navigator == null) return false;
    navigator.maybePop();
    return true;
  }

  static _LookupMenuBackInterceptor? _interceptor;

  /// 安装系统返回键拦截（幂等）。**必须在 `runApp` 之前调用**：
  /// `WidgetsBinding.handlePopRoute` 按 observer 注册顺序询问，晚于 `WidgetsApp`
  /// 注册就轮不到它，系统返回会先被根 `maybePop()` 交给页面 `PopScope`。
  static void installSystemBackInterceptor() {
    if (_interceptor != null) return;
    final _LookupMenuBackInterceptor interceptor = _LookupMenuBackInterceptor();
    _interceptor = interceptor;
    WidgetsBinding.instance.addObserver(interceptor);
  }

  @override
  State<LookupOverlayNavigator> createState() => _LookupOverlayNavigatorState();
}

/// 系统返回键：菜单开着时只关菜单并认领，排在 `WidgetsApp` 之前（见
/// [LookupOverlayNavigator.installSystemBackInterceptor]）。
class _LookupMenuBackInterceptor with WidgetsBindingObserver {
  @override
  Future<bool> didPopRoute() =>
      SynchronousFuture<bool>(LookupOverlayNavigator.popActiveMenu());
}

class _LookupOverlayNavigatorState extends State<LookupOverlayNavigator> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  late final _LookupOverlayHostRoute _hostRoute = _LookupOverlayHostRoute(
    builder: (BuildContext _) => widget.child,
  );
  late final _MenuStackObserver _menuObserver = _MenuStackObserver(
    _syncRootBackGuard,
  );

  /// 菜单开着期间挂在根栈顶路由上的 `canPop: false` 守卫（预测性返回不跟手）。
  final _MenuOpenPopEntry _rootBackGuard = _MenuOpenPopEntry();
  ModalRoute<Object?>? _guardedRootRoute;

  @override
  void initState() {
    super.initState();
    LookupOverlayNavigator._mounted.add(this);
  }

  @override
  void didUpdateWidget(covariant LookupOverlayNavigator oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 宿主每次 markNeedsBuild 外层 entry 都会给一棵新子树；初始路由只建一次，
    // 这里把刷新转给它的 entry（同一 build 阶段内、自身后代，合法）。
    if (!identical(oldWidget.child, widget.child)) _hostRoute.markNeedsBuild();
  }

  @override
  void dispose() {
    LookupOverlayNavigator._mounted.remove(this);
    _releaseRootBackGuard();
    _rootBackGuard.dispose();
    super.dispose();
  }

  /// 内层栈变化后（菜单开 / 关）同步根栈顶的返回守卫。
  void _syncRootBackGuard() {
    final NavigatorState? inner = _navigatorKey.currentState;
    final bool menuOpen = inner != null && inner.canPop();
    if (!menuOpen) {
      _releaseRootBackGuard();
      return;
    }
    if (_guardedRootRoute != null || !mounted) return;
    final NavigatorState? root = Navigator.maybeOf(
      context,
      rootNavigator: true,
    );
    if (root == null || identical(root, inner)) return;
    Route<dynamic>? top;
    root.popUntil((Route<dynamic> route) {
      top = route;
      return true;
    });
    final Route<dynamic>? topRoute = top;
    if (topRoute is! ModalRoute<Object?>) return;
    topRoute.registerPopEntry(_rootBackGuard);
    _guardedRootRoute = topRoute;
  }

  void _releaseRootBackGuard() {
    final ModalRoute<Object?>? route = _guardedRootRoute;
    _guardedRootRoute = null;
    route?.unregisterPopEntry(_rootBackGuard);
  }

  @override
  Widget build(BuildContext context) {
    return Navigator(
      key: _navigatorKey,
      clipBehavior: Clip.none,
      observers: <NavigatorObserver>[_menuObserver],
      onGenerateInitialRoutes: (NavigatorState _, String __) => <Route<void>>[
        _hostRoute,
      ],
    );
  }
}

/// 内层栈每次增减都回调一次（菜单 push / pop / remove / replace）。
class _MenuStackObserver extends NavigatorObserver {
  _MenuStackObserver(this.onChanged);

  final VoidCallback onChanged;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      onChanged();

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      onChanged();

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      onChanged();

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      onChanged();
}

/// 根栈顶路由上的「菜单开着」守卫：只负责让 `popDisposition` / `popGestureEnabled`
/// 判成「不可直接弹出」。真正关菜单由 [LookupOverlayNavigator.popActiveMenu] 做；万一
/// 有入口绕过它直达根 `maybePop()`，这里不重复关菜单（页面 `PopScope` 会关浮层，菜单
/// 随浮层一起卸载）。
class _MenuOpenPopEntry extends PopEntry<Object?> {
  final ValueNotifier<bool> _canPop = ValueNotifier<bool>(false);

  @override
  ValueListenable<bool> get canPopNotifier => _canPop;

  @override
  void onPopInvokedWithResult(bool didPop, Object? result) {}

  void dispose() => _canPop.dispose();
}

/// [LookupOverlayNavigator] 的初始路由：只有一个承载浮层子树的 entry，无 modal
/// barrier、不请求焦点。
class _LookupOverlayHostRoute extends OverlayRoute<void> {
  _LookupOverlayHostRoute({required this.builder}) : super(requestFocus: false);

  final WidgetBuilder builder;
  OverlayEntry? _entry;

  @override
  Iterable<OverlayEntry> createOverlayEntries() => <OverlayEntry>[
    _entry = OverlayEntry(builder: builder, maintainState: true),
  ];

  void markNeedsBuild() => _entry?.markNeedsBuild();
}
