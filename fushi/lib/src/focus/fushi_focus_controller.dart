import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:fushi/src/focus/focus_geometry.dart';
import 'package:fushi/src/focus/main_window_focus_gate.dart';
import 'package:fushi/src/focus/fushi_focus_scroll.dart';
import 'package:fushi/src/sync/desktop_foreground_guard.dart';

@immutable
class FushiFocusId {
  const FushiFocusId(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is FushiFocusId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

enum FushiFocusDirection { up, down, left, right }

FushiFocusDirection fushiFocusDirectionFromTraversal(
  TraversalDirection direction,
) {
  switch (direction) {
    case TraversalDirection.up:
      return FushiFocusDirection.up;
    case TraversalDirection.down:
      return FushiFocusDirection.down;
    case TraversalDirection.left:
      return FushiFocusDirection.left;
    case TraversalDirection.right:
      return FushiFocusDirection.right;
  }
}

class FushiFocusTargetEntry {
  const FushiFocusTargetEntry({
    required this.id,
    required this.focusNode,
    required this.context,
    required this.enabled,
    required this.owner,
    this.autoHome = true,
  });

  final FushiFocusId id;
  final FocusNode focusNode;
  final BuildContext context;
  final bool enabled;
  final Object owner;

  /// Whether PASSIVE focus auto-home (page entry / async reflow re-home) may
  /// land the cursor on this target. Interactive chrome that sits above the
  /// real content in reading order -- e.g. a collapsible settings section's
  /// fold/unfold header -- sets this false so auto-home prefers the first actual
  /// CONTENT row instead of stranding the cursor on a toggle. Such targets stay
  /// fully reachable by explicit directional navigation; only the unprompted
  /// initial landing skips them. Defaults true (ordinary rows/controls).
  final bool autoHome;

  bool get canFocus => enabled && focusNode.canRequestFocus;
}

/// 方向导航的一个候选落点。
///
/// 手柄焦点重写（2026-09-28）：方向引擎不再只认 [FushiFocusTarget] 登记过的
/// 目标，而是在**当前焦点作用域**（页面路由 / 对话框 / 菜单）里所有可聚焦的叶子
/// 节点上做几何选择。登记只负责**增强**：稳定 id（方向锚点、[requestById]）、
/// `autoHome`、以及正确的几何锚点 context。未登记的原生 Material 控件
/// （TextButton / ListTile / Switch / 对话框按钮……）用它自己的 [FocusNode.context]
/// 算几何——此前它们对引擎不可见，手柄会直接跳过它们或从陈旧的受管位置出发。
@immutable
class _FocusCandidate {
  const _FocusCandidate({
    required this.node,
    required this.context,
    this.entry,
  });

  final FocusNode node;

  /// 画框 / 几何 / 滚动共用的边界：受管目标用登记的锚点，原生节点用自身 context。
  final BuildContext context;

  /// 非 null = 受管目标。
  final FushiFocusTargetEntry? entry;

  bool get autoHome => entry?.autoHome ?? true;
}

class FushiFocusController extends ChangeNotifier {
  FushiFocusController()
    : fallbackNode = FocusNode(
        debugLabel: 'hibiki-focus-fallback',
        skipTraversal: true,
      );

  final FocusNode fallbackNode;
  final LinkedHashMap<FushiFocusId, FushiFocusTargetEntry> _entries =
      LinkedHashMap<FushiFocusId, FushiFocusTargetEntry>();

  // Directional anchors: an explicit `(sourceId, direction) -> targetId`
  // short-circuit consulted BEFORE geometric selection in [move]. It exists to
  // express intent that pure centre-to-centre geometry can't reach or would get
  // wrong -- e.g. a shelf's horizontal tag bar declaring "Down enters the grid's
  // first card" (the grid may be a different pane / partly off-screen) and
  // "Right from my last action jumps to the leftmost header icon" (a farther but
  // cleanly-clearing icon would otherwise beat the intended one). An anchor is a
  // PURE OPTION: if its target isn't currently a focusable entry it is ignored
  // and geometry runs unchanged, so scenes without anchors behave identically.
  final Map<_AnchorKey, FushiFocusId> _directionalAnchors =
      <_AnchorKey, FushiFocusId>{};

  BuildContext? _rootContext;
  FushiFocusId? _activeId;
  bool _attached = false;
  bool _repairScheduled = false;
  bool _repairMicrotaskScheduled = false;

  /// BUG-1619：有一次被动修复因为「主窗不在前台」被挡下了，欠着。
  ///
  /// 主窗真正回到前台时必须补上，否则用户切回来会发现整页没有焦点、键盘 /
  /// 手柄快捷键全不响应（正是 TODO-900 当初要修的症状）。
  bool _repairDeferredWhileBackgrounded = false;

  BuildContext? get activeContext {
    final _FocusCandidate? active = _currentCandidate(_candidates());
    if (active != null && _isLiveContext(active.context)) return active.context;
    return fallbackNode.context ?? _rootContext;
  }

  /// The visual geometry context for [focusNode].
  ///
  /// Managed composite controls register a render anchor around their whole
  /// interactive surface. Flutter's [FocusNode.context], however, belongs to
  /// the framework's internal [Focus] widget and can describe only an inset
  /// editable child (for example, [SearchBar]) or another implementation detail.
  /// Consumers that draw or reveal focus must use this registered anchor so the
  /// ring, directional geometry, and scroll target share one boundary.
  /// Unmanaged focus nodes keep their native context as the fallback.
  /// 几何**刻意不看** `canFocus`：这里回答的是「该画在哪个矩形上」，被 disable
  /// 的控件矩形依然有效。其余 4 处按节点身份找 entry 的地方（
  /// [primaryFocusIsManagedTarget] / `_currentCandidate` / `_isUsablePrimary` /
  /// `_handleFocusChange`）问的是「还能不能聚焦」，所以走 `_entryCanFocus`。
  /// 两个问题不同，判据不同是有意的，别顺手"统一"过来。
  BuildContext? geometryContextFor(FocusNode? focusNode) {
    if (focusNode == null) return null;
    for (final FushiFocusTargetEntry entry in _entries.values) {
      if (!identical(entry.focusNode, focusNode)) continue;
      // 一旦按节点身份认出这是受管控件，锚点不可用就**不画**（返回 null），
      // 而不是 continue 落到下面的 native context 回退——那等于「锚点暂时不可用
      // 就悄悄退回已知错位的内框」，画一个确定错的框比不画更糟。
      // `_isCurrentRoute` 第一行已经查过 `context.mounted`，这里不再重复。
      return _isCurrentRoute(entry.context) ? entry.context : null;
    }
    // 未受管：原样交回 Flutter 的 context。mounted 由消费侧各自把关
    // （`globalRectOfContext` 与 `FushiFocusScroll.ensureVisibleIfHidden` 都查），
    // 在这里再查一遍是空转：两个调用点都写着 `?? primaryFocus?.context`，
    // 返回 null 会被 `??` 把同一个 unmounted context 立刻递回去。
    return focusNode.context;
  }

  FushiFocusId? get activeId => _activeId;

  /// Whether the current [FocusManager.primaryFocus] is one of THIS controller's
  /// registered, focusable targets — i.e. focus actually sits on a directional-
  /// navigable control we manage, not on some unmanaged sink (e.g. the reader's
  /// reading-content [FocusNode], a popup scope, or a raw page key-event sink).
  ///
  /// The app-wide arrow-repeat handler uses this to decide whether holding an
  /// arrow should continue moving focus: it must NOT hijack a held arrow while
  /// focus rests on an unmanaged surface that owns the arrow for its own purpose
  /// (reader caret / page-turn), only continue movement between real managed
  /// controls.
  bool get primaryFocusIsManagedTarget {
    final FocusNode? primary = FocusManager.instance.primaryFocus;
    if (primary == null) return false;
    for (final FushiFocusTargetEntry entry in _entries.values) {
      if (identical(entry.focusNode, primary)) return _entryCanFocus(entry);
    }
    return false;
  }

  /// 当前路由上是否登记了**至少一个**可聚焦的受管目标。
  ///
  /// [move] 在零目标时走 [ensureFocus]：把焦点从页面自己的键事件 sink 踢到 app 级
  /// [fallbackNode]（兜底节点已持焦时才返回 true）。键盘方向键的「先移焦、无目标才
  /// 滚动」仲裁在零目标时根本不该调 [move]——纯展示页（统计 / 日志）上 ↑/↓ 必须
  /// 落到滚动，且不能顺手把持焦的页面 sink 废掉（页面快捷键从此收不到键），这个
  /// getter 就是那道门。
  ///
  /// 手柄焦点重写后，「目标」包括当前焦点作用域里未登记的原生控件（见
  /// [_FocusCandidate]）：只有原生按钮的对话框同样算有目标，方向键归焦点引擎。
  bool get hasFocusableTargets => _candidates().isNotEmpty;

  /// 当前主焦点是否停在方向引擎认得的一个落点上（受管目标或当前作用域里的原生
  /// 叶子控件）。键盘方向键的全局仲裁用它决定要不要接管：与手柄 D-pad 走同一个
  /// 候选集，键盘与手柄在混排页上不再各跑一套引擎。
  bool get primaryFocusIsNavigable {
    final FocusNode? primary = FocusManager.instance.primaryFocus;
    if (primary == null) return false;
    for (final _FocusCandidate candidate in _candidates()) {
      if (identical(candidate.node, primary)) return true;
    }
    return false;
  }

  bool get activeIsOnlyFocusableInNearestScrollable {
    final List<_FocusCandidate> candidates = _candidates();
    final _FocusCandidate? active = _currentCandidate(candidates);
    if (active == null || !_isLiveContext(active.context)) return false;
    final ScrollableState? activeScrollable = Scrollable.maybeOf(
      active.context,
    );
    if (activeScrollable == null) return false;
    for (final _FocusCandidate candidate in candidates) {
      if (identical(candidate.node, active.node)) continue;
      if (!_isLiveContext(candidate.context)) continue;
      if (identical(Scrollable.maybeOf(candidate.context), activeScrollable)) {
        return false;
      }
    }
    return true;
  }

  void attach(BuildContext rootContext) {
    _rootContext = rootContext;
    if (!_attached) {
      FocusManager.instance.addListener(_handleFocusChange);
      // BUG-1619：主窗回到前台就补一次修复。焦点闸门在关门期间让出了焦点，
      // 不补的话用户切回来整页没有焦点、键盘 / 手柄快捷键全不响应。
      // 与 [_handleFocusChange] 里那条 deferred 补票**并存**是有意的：这条走
      // window_manager 的窗口事件（可能因 channel 延迟晚到），那条走进程内的
      // FocusManager 通知（不依赖 channel），两条覆盖不同故障模式。
      mainWindowForegroundNotifier.addListener(_onMainWindowForegroundChanged);
      _attached = true;
    }
    scheduleRepair();
  }

  void _onMainWindowForegroundChanged() {
    if (!_attached || !mainWindowForegroundNotifier.value) return;
    _repairDeferredWhileBackgrounded = false;
    scheduleRepair();
  }

  void detach() {
    if (_attached) {
      FocusManager.instance.removeListener(_handleFocusChange);
      mainWindowForegroundNotifier.removeListener(
        _onMainWindowForegroundChanged,
      );
      _attached = false;
    }
    _entries.clear();
    _directionalAnchors.clear();
    fallbackNode.dispose();
    _rootContext = null;
  }

  void register(
    FushiFocusTargetEntry entry, {
    bool repairBeforeNextFrame = false,
  }) {
    _entries[entry.id] = entry;
    // By default, recording the entry is the only synchronous work. Recomputing
    // focus is deferred to the post-frame repair: register() runs inside
    // didChangeDependencies, which for a lazily-built SliverList child fires
    // during a layout callback. Doing _handleFocusChange() here would call
    // ModalRoute.of()/notifyListeners() mid-build — illegal, and it explodes
    // when an off-screen focused sibling is being recycled (deactivated but not
    // yet unregistered) in the same pass. scheduleRepair() → ensureFocus() does
    // the same recomputation safely after the frame, and the FocusManager
    // listener handles every later focus change.
    // Anchor-ready registrations already run in a post-frame callback. Coalesce
    // them into one microtask repair so all same-frame anchors are registered
    // before read-order selection runs, while still re-homing fallback focus
    // before the next frame.
    if (repairBeforeNextFrame) {
      scheduleRepairBeforeNextFrame();
      return;
    }
    scheduleRepair();
  }

  void unregister(FushiFocusId id, FocusNode node, Object owner) {
    final FushiFocusTargetEntry? current = _entries[id];
    if (current == null ||
        !identical(current.focusNode, node) ||
        !identical(current.owner, owner)) {
      return;
    }
    final bool wasActive =
        identical(FocusManager.instance.primaryFocus, node) || _activeId == id;
    _entries.remove(id);
    if (wasActive) {
      _activeId = null;
      scheduleRepair();
    }
  }

  /// Register an explicit directional short-circuit: pressing [direction] while
  /// [source] is the active target moves focus to [target] (revealing it if it
  /// scrolled off-screen), consulted before geometry in [move]. Re-registering
  /// the same `(source, direction)` overwrites. Type signatures are explicit so
  /// callers can register from a declarative widget without casts.
  void registerDirectionalAnchor(
    FushiFocusId source,
    FushiFocusDirection direction,
    FushiFocusId target,
  ) {
    _directionalAnchors[_AnchorKey(source, direction)] = target;
  }

  /// Remove a previously-registered anchor. No-op if the current mapping does
  /// not match [target] (so a stale unregister from a rebuilt widget cannot
  /// clobber a newer registration).
  void unregisterDirectionalAnchor(
    FushiFocusId source,
    FushiFocusDirection direction,
    FushiFocusId target,
  ) {
    final _AnchorKey key = _AnchorKey(source, direction);
    if (_directionalAnchors[key] == target) {
      _directionalAnchors.remove(key);
    }
  }

  /// The anchored target for the active [source] pressing [direction], but only
  /// when that target is a currently-focusable registered entry. Returns null
  /// when there is no anchor or its target is not (yet) focusable, so [move]
  /// cleanly falls through to geometry.
  FushiFocusTargetEntry? _anchoredTarget(
    FushiFocusId source,
    FushiFocusDirection direction,
  ) {
    final FushiFocusId? targetId =
        _directionalAnchors[_AnchorKey(source, direction)];
    if (targetId == null) return null;
    final FushiFocusTargetEntry? entry = _entries[targetId];
    if (entry == null || !_entryCanFocus(entry)) return null;
    return entry;
  }

  bool requestById(FushiFocusId id) {
    final FushiFocusTargetEntry? entry = _entries[id];
    if (entry == null || !_entryCanFocus(entry)) return false;
    return _focusCandidate(
      _FocusCandidate(
        node: entry.focusNode,
        context: entry.context,
        entry: entry,
      ),
    );
  }

  /// 显式输入（方向键 / 手柄 / 鼠标点选）把焦点落到 [candidate]：无条件 reveal，
  /// 这次输入本身就是可见焦点光标。
  bool _focusCandidate(_FocusCandidate candidate) {
    candidate.node.requestFocus();
    final FushiFocusId? id = candidate.entry?.id;
    _activeId = id;
    _scheduleReveal(candidate.context, candidate.node);
    if (id != null) notifyListeners();
    return true;
  }

  bool move(FushiFocusDirection direction) {
    final List<_FocusCandidate> targets = _candidates();
    if (targets.isEmpty) {
      ensureFocus();
      return fallbackNode.hasPrimaryFocus;
    }

    final _FocusCandidate? active = _currentCandidate(targets);
    if (active == null) {
      // 焦点不在任何落点上（刚进页 / 对话框刚弹出、主焦点停在路由 scope 或兜底
      // 节点上）：任意方向都落到阅读顺序的首个 autoHome 目标。旧实现取的是登记
      // 表的**插入顺序**首项且不看方向——首页上就是侧栏 rail 第一项。
      return _focusCandidate(_readOrderHome(targets));
    }

    final FushiFocusTargetEntry? activeEntry = active.entry;
    if (activeEntry != null) {
      // Explicit directional anchor wins over geometry (see _directionalAnchors).
      // requestById reveals the target if it scrolled off-screen.
      final FushiFocusTargetEntry? anchored = _anchoredTarget(
        activeEntry.id,
        direction,
      );
      if (anchored != null) return requestById(anchored.id);
    }
    final _GeometricMoveResult geometric = _geometricTarget(
      active,
      targets,
      direction,
    );
    if (!geometric.hasGeometry) {
      return _moveByReadingOrder(
        active: active,
        direction: direction,
        targets: targets,
      );
    }
    final _FocusCandidate? target = geometric.target;
    return target != null && _focusCandidate(target);
  }

  /// 方向引擎的候选集：当前焦点作用域里所有可聚焦叶子，受管目标带上登记信息。
  ///
  /// 作用域取主焦点所在的最近 [FocusScopeNode]（页面路由 / 对话框路由 / 菜单
  /// overlay / 页内面板），与 Flutter 自己的方向遍历同一边界：菜单打开时 D-pad
  /// 不会穿到菜单背后的页面行。主焦点不在可用节点上（null / 兜底节点 / 根 scope）
  /// 时取最顶层当前路由的 scope。
  ///
  /// 过滤规则：
  ///   · 受管目标：只看 [_entryCanFocus]（与改动前一致，含 disable / 非当前路由）；
  ///   · 原生节点：可聚焦、非 skipTraversal、祖先链允许遍历、在当前路由、有布局
  ///     过的非空矩形；
  ///   · 受管目标**内部**的原生节点丢弃——复合控件由登记的那一个节点代表；
  ///   · 自己还包着其它候选的原生节点（整页 / 整区键事件 sink）丢弃——它的矩形
  ///     覆盖整片区域，当成落点会把焦点「吸」到一个没有焦点环意义的容器上。
  List<_FocusCandidate> _candidates() {
    final FocusScopeNode? scope = _containmentScope();
    final Map<FocusNode, FushiFocusTargetEntry> managed =
        <FocusNode, FushiFocusTargetEntry>{};
    for (final FushiFocusTargetEntry entry in _entries.values) {
      if (_entryCanFocus(entry)) managed[entry.focusNode] = entry;
    }
    if (scope == null) {
      return <_FocusCandidate>[
        for (final FushiFocusTargetEntry entry in managed.values)
          _FocusCandidate(
            node: entry.focusNode,
            context: entry.context,
            entry: entry,
          ),
      ];
    }

    final List<_FocusCandidate> result = <_FocusCandidate>[];
    for (final FocusNode node in scope.descendants) {
      final FushiFocusTargetEntry? entry = managed[node];
      if (entry != null) {
        result.add(
          _FocusCandidate(node: node, context: entry.context, entry: entry),
        );
        continue;
      }
      if (!_isNativeCandidate(node, scope, managed)) continue;
      result.add(_FocusCandidate(node: node, context: node.context!));
    }

    // 丢掉包着其它候选的原生容器节点。
    final Set<FocusNode> containers = <FocusNode>{};
    for (final _FocusCandidate candidate in result) {
      for (final FocusNode ancestor in candidate.node.ancestors) {
        if (identical(ancestor, scope)) break;
        containers.add(ancestor);
      }
    }
    if (containers.isEmpty) return result;
    return result
        .where(
          (_FocusCandidate candidate) =>
              candidate.entry != null || !containers.contains(candidate.node),
        )
        .toList(growable: false);
  }

  bool _isNativeCandidate(
    FocusNode node,
    FocusScopeNode scope,
    Map<FocusNode, FushiFocusTargetEntry> managed,
  ) {
    if (node is FocusScopeNode) return false;
    if (identical(node, fallbackNode)) return false;
    if (!node.canRequestFocus || node.skipTraversal) return false;
    final BuildContext? context = node.context;
    if (context == null || !_isCurrentRoute(context)) return false;
    for (final FocusNode ancestor in node.ancestors) {
      if (identical(ancestor, scope)) break;
      if (!ancestor.descendantsAreTraversable) return false;
      // 受管复合控件内部的节点（例如 FushiFocusTarget 里包着的 Material 按钮自带
      // 的节点）由外层登记节点代表，不单独成为落点。
      if (managed.containsKey(ancestor)) return false;
    }
    final Rect? rect = globalRectOfContext(context);
    return rect != null && !rect.isEmpty;
  }

  /// 方向引擎的作用域边界，见 [_candidates]。
  FocusScopeNode? _containmentScope() {
    final FocusNode? primary = FocusManager.instance.primaryFocus;
    FocusScopeNode? scope;
    if (primary != null && !identical(primary, fallbackNode)) {
      scope = primary is FocusScopeNode ? primary : primary.enclosingScope;
    }
    if (scope == null ||
        identical(scope, FocusManager.instance.rootScope) ||
        scope.context == null ||
        !_isCurrentRoute(scope.context!)) {
      scope = _topRouteScope();
    }
    return scope;
  }

  /// 最顶层（最深一层 Navigator 的）当前路由的 [FocusScopeNode]。非当前路由的
  /// scope 由框架设为 skipTraversal、其 [ModalRoute.isCurrent] 为 false，都会被
  /// 滤掉；同一路由内的嵌套 scope（页内面板）取最外层那个。
  FocusScopeNode? _topRouteScope() {
    final Map<ModalRoute<dynamic>, FocusScopeNode> firstScopeOfRoute =
        <ModalRoute<dynamic>, FocusScopeNode>{};
    ModalRoute<dynamic>? lastRoute;
    for (final FocusNode node in FocusManager.instance.rootScope.descendants) {
      if (node is! FocusScopeNode) continue;
      final BuildContext? context = node.context;
      if (context == null || !_isLiveContext(context)) continue;
      final ModalRoute<dynamic>? route = ModalRoute.of(context);
      if (route == null || !route.isCurrent) continue;
      firstScopeOfRoute.putIfAbsent(route, () => node);
      lastRoute = route;
    }
    return lastRoute == null ? null : firstScopeOfRoute[lastRoute];
  }

  _FocusCandidate _readOrderHome(List<_FocusCandidate> targets) {
    final List<_FocusCandidate> ordered = _sortedByReadOrder(targets);
    return ordered.firstWhere(
      (_FocusCandidate candidate) => candidate.autoHome,
      orElse: () => ordered.first,
    );
  }

  List<_FocusCandidate> _sortedByReadOrder(List<_FocusCandidate> targets) {
    final List<_FocusCandidate> ordered = List<_FocusCandidate>.of(targets);
    ordered.sort(
      (_FocusCandidate a, _FocusCandidate b) =>
          _compareContextsByReadOrder(a.context, b.context),
    );
    return ordered;
  }

  void ensureFocus() {
    // BUG-1619：[ensureFocus] 是**被动焦点修复**的汇合点（attach / register /
    // unregister / scheduleRepair 全落这里），它下面每一条分支都会 requestFocus。
    //
    // 桌面版 Fushi 是多顶层窗口进程。主窗不在前台时（用户正在游戏 / 浏览器里，
    // 剪贴板查词面板浮在上面），Flutter 引擎会把 requestFocus 翻译成
    // SetFocus(FlutterView)，而 Win32 语义下 SetFocus(子窗) 会**连带激活它的
    // 顶层窗口** —— 主界面凭空盖住用户正在用的窗口。真机链路：拖面板顶栏结束
    // → windowMoved → setClipboardPanelRect → PreferencesRepository
    // .notifyListeners() → 首页重建 → 焦点目标重新 register → scheduleRepair
    // → 这里 → 主窗被抬到前台。
    //
    // 判据只挡**被动修复**：用户显式输入触发的 [move] / [requestById] 不经这里
    // 的早退（那时主窗必然已经是前台）。被挡下时记账，等主窗真的回到前台再补
    // 修一次（见 [_handleFocusChange]），否则切回来就没有焦点、快捷键全失效。
    if (!DesktopForegroundGuard.isMainWindowForeground()) {
      _repairDeferredWhileBackgrounded = true;
      return;
    }
    final FocusNode? primary = FocusManager.instance.primaryFocus;
    if (_isUsablePrimary(primary)) {
      _handleFocusChange();
      return;
    }

    final FushiFocusTargetEntry? active = _staleActiveEntry();
    if (active != null) {
      active.focusNode.requestFocus();
      _activeId = active.id;
      _maybeRevealOnRepair(active.context, active.focusNode);
      return;
    }

    final List<FushiFocusTargetEntry> targets = _focusableEntriesInReadOrder();
    if (targets.isNotEmpty) {
      // Passive auto-home prefers real content over interactive chrome (e.g. a
      // collapsible section's fold header): landing on a toggle above the first
      // row and then not revealing anything is a regression. Chrome stays
      // reachable by explicit navigation; fall back to it only when there is no
      // content target (a page of pure headers).
      final FushiFocusTargetEntry landing = targets.firstWhere(
        (FushiFocusTargetEntry entry) => entry.autoHome,
        orElse: () => targets.first,
      );
      landing.focusNode.requestFocus();
      _activeId = landing.id;
      _maybeRevealOnRepair(landing.context, landing.focusNode);
      notifyListeners();
      return;
    }

    // 手柄焦点重写：主焦点停在一个有落点的当前路由 / 菜单 scope 上（典型：只有
    // 原生按钮的对话框刚弹出、框架没 autofocus 任何按钮）时**原地不动**。旧实现
    // 在这里把焦点拽到 Navigator 之上的兜底节点——焦点被拖出对话框，此后 A 键
    // 的 ActivateIntent 无人处理、D-pad 从根 scope 乱跳。被动修复也不替用户选
    // 对话框按钮（Enter 误触发首个按钮比没焦点更糟）；第一次方向输入由 [move]
    // 按阅读顺序落到首个控件。
    if (primary is FocusScopeNode &&
        !identical(primary, FocusManager.instance.rootScope) &&
        primary.context != null &&
        _isCurrentRoute(primary.context!) &&
        _candidates().isNotEmpty) {
      return;
    }

    if (fallbackNode.canRequestFocus && fallbackNode.context != null) {
      fallbackNode.requestFocus();
    }
  }

  void _scheduleReveal(BuildContext context, FocusNode node) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_isLiveContext(context) && node.hasFocus) {
        FushiFocusScroll.ensureVisible(context);
      }
    });
  }

  // Reveal driven by PASSIVE focus repair (page entry, async reflow re-homing
  // the cursor) — gated to keyboard/gamepad highlight mode, mirroring
  // FushiFocusRing: the viewport follows focus only when there is a visible
  // focus cursor. In touch mode there is no cursor, so moving the scroll offset
  // to "reveal" a programmatically grabbed target is an unwanted jump — e.g.
  // the sync/backup page, whose async backend load reflows the list taller
  // after this reveal is scheduled, would scroll-center a now-lower row and
  // yank the page down on open. Explicit gamepad/keyboard navigation
  // (requestById/move) still reveals unconditionally — that input IS the
  // traditional-mode cursor.
  void _maybeRevealOnRepair(BuildContext context, FocusNode node) {
    if (FocusManager.instance.highlightMode != FocusHighlightMode.traditional) {
      return;
    }
    _scheduleReveal(context, node);
  }

  void scheduleRepair() {
    if (_repairScheduled) return;
    _repairScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _repairScheduled = false;
      ensureFocus();
    });
  }

  void scheduleRepairBeforeNextFrame() {
    if (_repairMicrotaskScheduled) return;
    _repairMicrotaskScheduled = true;
    scheduleMicrotask(() {
      _repairMicrotaskScheduled = false;
      if (_attached) {
        ensureFocus();
      }
    });
  }

  /// 真实主焦点对应的落点。
  ///
  /// 只有主焦点**不在任何可用节点上**（null / 兜底节点 / 路由 scope）时，才回退
  /// 到上一次的受管目标 [_activeId]。旧实现无条件回退：用户把焦点移到一个未登记
  /// 的原生控件后，方向键仍从上一个受管目标出发计算——按 ↑ 跳到倒数第二行、
  /// 打开下拉菜单按 D-pad 跳到菜单背后的页面行。
  _FocusCandidate? _currentCandidate(List<_FocusCandidate> candidates) {
    final FocusNode? primary = FocusManager.instance.primaryFocus;
    for (final _FocusCandidate candidate in candidates) {
      if (identical(candidate.node, primary)) {
        final FushiFocusId? id = candidate.entry?.id;
        if (id != null) _activeId = id;
        return candidate;
      }
    }
    if (_isUsablePrimary(primary)) return null;
    final FushiFocusTargetEntry? stale = _staleActiveEntry();
    if (stale == null) return null;
    for (final _FocusCandidate candidate in candidates) {
      if (identical(candidate.entry, stale)) return candidate;
    }
    return null;
  }

  /// 上一次的受管目标，仍可聚焦才返回。
  FushiFocusTargetEntry? _staleActiveEntry() {
    final FushiFocusId? id = _activeId;
    if (id == null) return null;
    final FushiFocusTargetEntry? active = _entries[id];
    if (active == null || !_entryCanFocus(active)) return null;
    return active;
  }

  List<FushiFocusTargetEntry> _focusableEntries() {
    return _entries.values
        .where((FushiFocusTargetEntry entry) => _entryCanFocus(entry))
        .toList(growable: false);
  }

  List<FushiFocusTargetEntry> _focusableEntriesInReadOrder() {
    final List<FushiFocusTargetEntry> targets = _focusableEntries();
    targets.sort(_compareEntriesByReadOrder);
    return targets;
  }

  int _compareEntriesByReadOrder(
    FushiFocusTargetEntry a,
    FushiFocusTargetEntry b,
  ) => _compareContextsByReadOrder(a.context, b.context);

  int _compareContextsByReadOrder(BuildContext a, BuildContext b) {
    final Rect? aRect = globalRectOfContext(a);
    final Rect? bRect = globalRectOfContext(b);
    if (aRect == null || bRect == null) {
      if (aRect == null && bRect == null) return 0;
      return aRect == null ? 1 : -1;
    }
    const double epsilon = 2;
    final double topDelta = aRect.top - bRect.top;
    if (topDelta.abs() > epsilon) return topDelta.sign.toInt();
    final double leftDelta = aRect.left - bRect.left;
    if (leftDelta.abs() > epsilon) return leftDelta.sign.toInt();
    return 0;
  }

  bool _isUsablePrimary(FocusNode? primary) {
    if (primary == null) return false;
    // The fallback (a skip-traversal, ring-less sink) is "usable" ONLY as a last
    // resort — when there is nothing real to focus (a pure-display page). When
    // focusable targets exist (e.g. a tab's content finished loading after the
    // cursor had fallen back), it must NOT count as usable, so ensureFocus()
    // re-homes onto a real target instead of stranding the cursor ring-less on
    // the fallback.
    if (identical(primary, fallbackNode)) return _focusableEntries().isEmpty;
    if (primary is FocusScopeNode) return false;
    if (primary.skipTraversal) return false;
    for (final FushiFocusTargetEntry entry in _entries.values) {
      if (identical(entry.focusNode, primary)) return _entryCanFocus(entry);
    }
    final BuildContext? context = primary.context;
    return context != null &&
        primary.canRequestFocus &&
        _isCurrentRoute(context);
  }

  bool _entryCanFocus(FushiFocusTargetEntry entry) {
    return entry.canFocus && _isCurrentRoute(entry.context);
  }

  bool _isCurrentRoute(BuildContext context) {
    if (!_isLiveContext(context)) return false;
    final ModalRoute<dynamic>? route = ModalRoute.of(context);
    return route == null || route.isCurrent;
  }

  _GeometricMoveResult _geometricTarget(
    _FocusCandidate active,
    List<_FocusCandidate> targets,
    FushiFocusDirection direction,
  ) {
    final Rect? activeRect = globalRectOfContext(active.context);
    if (activeRect == null) return const _GeometricMoveResult.noGeometry();
    // 面板身份：方向导航优先停留在同一视觉面板。主边界是最近的
    // FocusTraversalGroup —— home 外壳把侧栏 rail、正文 body、设置各包进独立
    // 的 group，所以无 Scrollable 的页头按钮与同样无 Scrollable 的 rail 仍判异
    // 面板（Down/Up 不会从内容/chrome 误入 rail）。同一 group 内再用非空
    // Scrollable 细分：宽屏设置主从布局里导航栏与详情各是独立 ListView，没有这条
    // 细分，详情里「设计系统」段控按 Down 会被纵向更近的左侧导航项「阅读」抢走。
    final ScrollableState? activeScrollable = Scrollable.maybeOf(
      active.context,
    );
    final Element? activeGroup = _nearestTraversalGroup(active.context);
    final Offset activeCenter = activeRect.center;
    _FocusCandidate? best;
    int bestSamePane = -1;
    int bestClears = -1;
    int bestBeam = -1;
    double bestAlong = double.infinity;
    double bestCross = double.infinity;
    const double epsilon = 2;

    for (final _FocusCandidate target in targets) {
      if (identical(target.node, active.node)) continue;
      final Rect? targetRect = globalRectOfContext(target.context);
      if (targetRect == null) continue;
      final bool samePane = _isSamePane(
        target.context,
        activeGroup: activeGroup,
        activeScrollable: activeScrollable,
      );
      final Offset targetCenter = targetRect.center;
      final double dx = targetCenter.dx - activeCenter.dx;
      final double dy = targetCenter.dy - activeCenter.dy;

      final bool ahead;
      final double along;
      final double cross;
      final bool beam;
      // `clears`: the candidate lies ENTIRELY past the source along the press
      // axis (its near edge is at/after the source's far edge). This separates
      // a genuine next-row/next-column target from one that merely sits beside
      // the source and is barely past its centre — e.g. on a keyboard, the key
      // directly BELOW `q` (`a`) overlaps `q` horizontally, so for a RIGHT
      // press it does NOT clear, while the same-row `w` does. Used as the top
      // ranking tier below so a barely-ahead, axis-overlapping diagonal never
      // beats the same-row neighbour.
      final bool clears;
      switch (direction) {
        case FushiFocusDirection.up:
          ahead = dy < -epsilon;
          along = -dy;
          cross = dx.abs();
          beam = _overlap(
            activeRect.left,
            activeRect.right,
            targetRect.left,
            targetRect.right,
          );
          clears = targetRect.bottom <= activeRect.top + epsilon;
          break;
        case FushiFocusDirection.down:
          ahead = dy > epsilon;
          along = dy;
          cross = dx.abs();
          beam = _overlap(
            activeRect.left,
            activeRect.right,
            targetRect.left,
            targetRect.right,
          );
          clears = targetRect.top >= activeRect.bottom - epsilon;
          break;
        case FushiFocusDirection.left:
          ahead = dx < -epsilon;
          along = -dx;
          cross = dy.abs();
          beam = _overlap(
            activeRect.top,
            activeRect.bottom,
            targetRect.top,
            targetRect.bottom,
          );
          clears = targetRect.right <= activeRect.left + epsilon;
          break;
        case FushiFocusDirection.right:
          ahead = dx > epsilon;
          along = dx;
          cross = dy.abs();
          beam = _overlap(
            activeRect.top,
            activeRect.bottom,
            targetRect.top,
            targetRect.bottom,
          );
          clears = targetRect.left >= activeRect.right - epsilon;
          break;
      }
      if (!ahead) continue;

      final int beamScore = beam ? 1 : 0;
      final int clearsScore = clears ? 1 : 0;
      final int samePaneScore = samePane ? 1 : 0;
      // Ranking, in priority order:
      //  0. `clears` — a candidate that lies ENTIRELY past the source on the press
      //     axis (a genuine next-row/next-column neighbour) beats one that merely
      //     sits diagonally beside the source. This MUST outrank `samePane`:
      //     pressing Left/Right on a full-width row (e.g. a settings switch) has
      //     no in-row same-pane neighbour, so its only same-pane "ahead"
      //     candidates are DIAGONAL (a swatch/segment a row up or down). A real
      //     directional neighbour in the OTHER pane — the nav rail, directly to
      //     the side and clearing the source — must win over that diagonal;
      //     otherwise Left on the switch jumps UP to the 主题 swatch row instead
      //     of escaping to the nav pane (BUG-015).
      //  1. `samePane` — among equally-clearing candidates, one in the SAME nearest
      //     Scrollable (same visual pane) beats a cross-pane one. In the wide
      //     settings list-detail the nav pane and the detail pane are separate
      //     ListViews; without this a Down press from a detail control lands on
      //     the vertically-closer nav item in the OTHER pane (both clear, so this
      //     tier keeps focus in-pane). Both-null (no Scrollable) counts as same,
      //     so scrollable-free pages keep the original behaviour.
      //  2. `along` — the immediately-next row/column wins even if cross-offset.
      //  3. `beam` — perpendicular overlap breaks an `along` tie.
      //  4. `cross` — centre offset breaks any remaining tie.
      final bool better =
          best == null ||
          clearsScore > bestClears ||
          (clearsScore == bestClears &&
              (samePaneScore > bestSamePane ||
                  (samePaneScore == bestSamePane &&
                      (along < bestAlong - epsilon ||
                          ((along - bestAlong).abs() <= epsilon &&
                              (beamScore > bestBeam ||
                                  (beamScore == bestBeam &&
                                      cross < bestCross)))))));
      if (better) {
        best = target;
        bestSamePane = samePaneScore;
        bestClears = clearsScore;
        bestBeam = beamScore;
        bestAlong = along;
        bestCross = cross;
      }
    }
    return _GeometricMoveResult(target: best, hasGeometry: true);
  }

  /// 目标是否与当前项同面板：① 必须同一最近 [FocusTraversalGroup]（不同组即异
  /// 面板，例如侧栏 rail vs 正文 body——两者都可能没有 Scrollable）；② 同一组内若
  /// 两者都在非空 Scrollable 且不同，则异面板（宽屏设置主从布局的导航栏与详情两条
  /// 独立 ListView）；任一方无 Scrollable（页头 chrome）时只看组，让无滚动的 chrome
  /// 与同组内容算同面板。两者皆无 FTG、皆无 Scrollable 时退化为旧行为（恒同面板，
  /// 纯展示页/无分栏页该档恒等，与改动前一致）。
  bool _isSamePane(
    BuildContext targetContext, {
    required Element? activeGroup,
    required ScrollableState? activeScrollable,
  }) {
    if (!identical(_nearestTraversalGroup(targetContext), activeGroup)) {
      return false;
    }
    final ScrollableState? targetScrollable = Scrollable.maybeOf(targetContext);
    if (activeScrollable == null || targetScrollable == null) return true;
    return identical(targetScrollable, activeScrollable);
  }

  /// 最近的 [FocusTraversalGroup] 元素（无则 null）——方向导航「面板」身份的主边界。
  /// 用 Element 标识（跨重建稳定，且一次 move() 内整棵树不会重建）而非 widget 实例。
  Element? _nearestTraversalGroup(BuildContext context) {
    if (!_isLiveContext(context)) return null;
    Element? group;
    context.visitAncestorElements((Element element) {
      if (element.widget is FocusTraversalGroup) {
        group = element;
        return false;
      }
      return true;
    });
    return group;
  }

  bool _moveByReadingOrder({
    required _FocusCandidate active,
    required FushiFocusDirection direction,
    required List<_FocusCandidate> targets,
  }) {
    final List<_FocusCandidate> ordered = _sortedByReadOrder(targets);
    final int currentIndex = ordered.indexWhere(
      (_FocusCandidate candidate) => identical(candidate.node, active.node),
    );
    final int nextIndex = _nextIndex(
      currentIndex: currentIndex,
      direction: direction,
      count: ordered.length,
    );
    return _focusCandidate(ordered[nextIndex]);
  }

  static bool _overlap(double aStart, double aEnd, double bStart, double bEnd) {
    return math.min(aEnd, bEnd) - math.max(aStart, bStart) > 0;
  }

  int _nextIndex({
    required int currentIndex,
    required FushiFocusDirection direction,
    required int count,
  }) {
    if (currentIndex < 0) return 0;
    switch (direction) {
      case FushiFocusDirection.down:
      case FushiFocusDirection.right:
        return (currentIndex + 1).clamp(0, count - 1);
      case FushiFocusDirection.up:
      case FushiFocusDirection.left:
        return (currentIndex - 1).clamp(0, count - 1);
    }
  }

  void _handleFocusChange() {
    // BUG-1619：主窗回到前台的补票口。FlutterView 重新拿到 OS 焦点会走到这里，
    // 此时把「后台期间欠下的那次被动修复」补上——这条路径覆盖同进程内从剪贴板
    // 面板切回主窗（那种切换不产生 AppLifecycleState.resumed，首页那条 resumed
    // 回收补不到）。
    if (_repairDeferredWhileBackgrounded &&
        DesktopForegroundGuard.isMainWindowForeground()) {
      _repairDeferredWhileBackgrounded = false;
      scheduleRepair();
    }
    final FocusNode? primary = FocusManager.instance.primaryFocus;
    for (final FushiFocusTargetEntry entry in _entries.values) {
      if (identical(entry.focusNode, primary)) {
        if (!_entryCanFocus(entry)) {
          scheduleRepair();
          return;
        }
        if (_activeId != entry.id) {
          _activeId = entry.id;
          notifyListeners();
        }
        return;
      }
    }
  }
}

@immutable
class _AnchorKey {
  const _AnchorKey(this.source, this.direction);

  final FushiFocusId source;
  final FushiFocusDirection direction;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _AnchorKey &&
          other.source == source &&
          other.direction == direction;

  @override
  int get hashCode => Object.hash(source, direction);
}

@immutable
class _GeometricMoveResult {
  const _GeometricMoveResult({required this.target, required this.hasGeometry});

  const _GeometricMoveResult.noGeometry() : target = null, hasGeometry = false;

  final _FocusCandidate? target;
  final bool hasGeometry;
}

class FushiFocusRoot extends StatefulWidget {
  const FushiFocusRoot({super.key, this.enabled = true, required this.child});

  final Widget child;

  /// False = 焦点导航系统关闭但**保持挂载**：[maybeControllerOf] 返回 null，
  /// 消费方据此走「无焦点根」的原生遍历路径（语义与根本不挂载时一致）。
  /// 恒定挂载的意义：切换实验开关不再改变树结构 → 整棵 app 子树的 Element
  /// 全保留（开关滑块动画、各页滚动位置不丢）。
  final bool enabled;

  static FushiFocusController controllerOf(BuildContext context) {
    final _FushiFocusScope? scope = context
        .dependOnInheritedWidgetOfExactType<_FushiFocusScope>();
    assert(scope?.controller != null, 'No FushiFocusRoot found in context');
    return scope!.controller!;
  }

  static FushiFocusController? maybeControllerOf(
    BuildContext context, {
    bool listen = true,
  }) {
    if (listen) {
      return context
          .dependOnInheritedWidgetOfExactType<_FushiFocusScope>()
          ?.controller;
    }
    return context
        .getInheritedWidgetOfExactType<_FushiFocusScope>()
        ?.controller;
  }

  @override
  State<FushiFocusRoot> createState() => _FushiFocusRootState();
}

class _FushiFocusRootState extends State<FushiFocusRoot> {
  late final FushiFocusController _controller = FushiFocusController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller.attach(context);
  }

  @override
  void dispose() {
    _controller.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 结构恒定（scope → Focus → child），enabled 只影响 scope 暴露的控制器：
    // 禁用时消费方拿到 null，走原生遍历路径；控制器实例保活，重新启用即恢复。
    //
    // scope 必须包在兜底 Focus **外面**：兜底节点的 context 就是这个 Focus 的
    // element，scope 若在它里面，主焦点落在兜底节点上时 `maybeControllerOf`
    // 返回 null——D-pad 于是走「无控制器」分支从根 scope 盲跳 nextFocus，绕过
    // 当前路由过滤，焦点可能跳到对话框背后的页面上。
    return _FushiFocusScope(
      controller: widget.enabled ? _controller : null,
      child: Focus(
        focusNode: _controller.fallbackNode,
        canRequestFocus: widget.enabled,
        skipTraversal: true,
        child: widget.child,
      ),
    );
  }
}

class _FushiFocusScope extends InheritedNotifier<FushiFocusController> {
  const _FushiFocusScope({required this.controller, required super.child})
    : super(notifier: controller);

  /// null = 焦点导航禁用（FushiFocusRoot.enabled == false）。
  final FushiFocusController? controller;
}

/// 上下文是否处于活动态：mounted 且其渲染对象仍挂在渲染树上。
///
/// 子树被摘下（切换设计系统时外壳结构变化、GlobalKey 重挂）到 dispose 之前，
/// 元素仍 mounted 却已停用；对它 `ModalRoute.of` / 取 size 会断言并连锁成整屏
/// 红。[Element.renderObject] 的取值不做生命周期断言，停用后其渲染对象已从树上
/// detach，以此判活。
bool _isLiveContext(BuildContext context) {
  if (!context.mounted) return false;
  final RenderObject? renderObject = (context as Element).renderObject;
  return renderObject != null && renderObject.attached;
}
