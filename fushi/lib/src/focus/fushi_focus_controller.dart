import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:fushi/src/focus/focus_geometry.dart';
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
    final FushiFocusTargetEntry? active = _currentEntry();
    if (active != null && active.context.mounted) return active.context;
    return fallbackNode.context ?? _rootContext;
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

  bool get activeIsOnlyFocusableInNearestScrollable {
    final FushiFocusTargetEntry? active = _currentEntry();
    if (active == null || !active.context.mounted) return false;
    final ScrollableState? activeScrollable = Scrollable.maybeOf(
      active.context,
    );
    if (activeScrollable == null) return false;
    for (final FushiFocusTargetEntry entry in _entries.values) {
      if (identical(entry, active) || !_entryCanFocus(entry)) continue;
      if (!entry.context.mounted) continue;
      if (identical(Scrollable.maybeOf(entry.context), activeScrollable)) {
        return false;
      }
    }
    return true;
  }

  void attach(BuildContext rootContext) {
    _rootContext = rootContext;
    if (!_attached) {
      FocusManager.instance.addListener(_handleFocusChange);
      _attached = true;
    }
    scheduleRepair();
  }

  void detach() {
    if (_attached) {
      FocusManager.instance.removeListener(_handleFocusChange);
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
    entry.focusNode.requestFocus();
    _activeId = id;
    _scheduleReveal(entry);
    notifyListeners();
    return true;
  }

  bool move(FushiFocusDirection direction) {
    final List<FushiFocusTargetEntry> targets = _focusableEntries();
    if (targets.isEmpty) {
      ensureFocus();
      return fallbackNode.hasPrimaryFocus;
    }

    final FushiFocusTargetEntry? active = _currentEntry();
    final int currentIndex = active == null ? -1 : targets.indexOf(active);
    if (active != null) {
      // Explicit directional anchor wins over geometry (see _directionalAnchors).
      // requestById reveals the target if it scrolled off-screen.
      final FushiFocusTargetEntry? anchored =
          _anchoredTarget(active.id, direction);
      if (anchored != null) return requestById(anchored.id);
      final _GeometricMoveResult geometric =
          _geometricTarget(active, targets, direction);
      if (!geometric.hasGeometry) {
        return _moveByReadingOrder(
          currentIndex: currentIndex,
          direction: direction,
          targets: targets,
        );
      }
      final FushiFocusTargetEntry? target = geometric.target;
      return target != null && requestById(target.id);
    }

    return _moveByReadingOrder(
      currentIndex: currentIndex,
      direction: direction,
      targets: targets,
    );
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

    final FushiFocusTargetEntry? active = _currentEntry();
    if (active != null && _entryCanFocus(active)) {
      active.focusNode.requestFocus();
      _activeId = active.id;
      _maybeRevealOnRepair(active);
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
      _maybeRevealOnRepair(landing);
      notifyListeners();
      return;
    }

    if (fallbackNode.canRequestFocus && fallbackNode.context != null) {
      fallbackNode.requestFocus();
    }
  }

  void _scheduleReveal(FushiFocusTargetEntry entry) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (entry.context.mounted && entry.focusNode.hasFocus) {
        FushiFocusScroll.ensureVisible(entry.context);
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
  void _maybeRevealOnRepair(FushiFocusTargetEntry entry) {
    if (FocusManager.instance.highlightMode != FocusHighlightMode.traditional) {
      return;
    }
    _scheduleReveal(entry);
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

  FushiFocusTargetEntry? _currentEntry() {
    final FocusNode? primary = FocusManager.instance.primaryFocus;
    for (final FushiFocusTargetEntry entry in _entries.values) {
      if (_entryCanFocus(entry) && identical(entry.focusNode, primary)) {
        _activeId = entry.id;
        return entry;
      }
    }
    if (_activeId == null) return null;
    final FushiFocusTargetEntry? active = _entries[_activeId!];
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
  ) {
    final Rect? aRect = globalRectOfContext(a.context);
    final Rect? bRect = globalRectOfContext(b.context);
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
    if (!context.mounted) return false;
    final ModalRoute<dynamic>? route = ModalRoute.of(context);
    return route == null || route.isCurrent;
  }

  _GeometricMoveResult _geometricTarget(
    FushiFocusTargetEntry active,
    List<FushiFocusTargetEntry> targets,
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
    final ScrollableState? activeScrollable =
        Scrollable.maybeOf(active.context);
    final Element? activeGroup = _nearestTraversalGroup(active.context);
    final Offset activeCenter = activeRect.center;
    FushiFocusTargetEntry? best;
    int bestSamePane = -1;
    int bestClears = -1;
    int bestBeam = -1;
    double bestAlong = double.infinity;
    double bestCross = double.infinity;
    const double epsilon = 2;

    for (final FushiFocusTargetEntry target in targets) {
      if (identical(target, active)) continue;
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
          beam = _overlap(activeRect.left, activeRect.right, targetRect.left,
              targetRect.right);
          clears = targetRect.bottom <= activeRect.top + epsilon;
          break;
        case FushiFocusDirection.down:
          ahead = dy > epsilon;
          along = dy;
          cross = dx.abs();
          beam = _overlap(activeRect.left, activeRect.right, targetRect.left,
              targetRect.right);
          clears = targetRect.top >= activeRect.bottom - epsilon;
          break;
        case FushiFocusDirection.left:
          ahead = dx < -epsilon;
          along = -dx;
          cross = dy.abs();
          beam = _overlap(activeRect.top, activeRect.bottom, targetRect.top,
              targetRect.bottom);
          clears = targetRect.right <= activeRect.left + epsilon;
          break;
        case FushiFocusDirection.right:
          ahead = dx > epsilon;
          along = dx;
          cross = dy.abs();
          beam = _overlap(activeRect.top, activeRect.bottom, targetRect.top,
              targetRect.bottom);
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
      final bool better = best == null ||
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
    if (!context.mounted) return null;
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
    required int currentIndex,
    required FushiFocusDirection direction,
    required List<FushiFocusTargetEntry> targets,
  }) {
    final int nextIndex = _nextIndex(
      currentIndex: currentIndex,
      direction: direction,
      count: targets.length,
    );
    return requestById(targets[nextIndex].id);
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
  const _GeometricMoveResult({
    required this.target,
    required this.hasGeometry,
  });

  const _GeometricMoveResult.noGeometry()
      : target = null,
        hasGeometry = false;

  final FushiFocusTargetEntry? target;
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
    final _FushiFocusScope? scope =
        context.dependOnInheritedWidgetOfExactType<_FushiFocusScope>();
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
    // 结构恒定（Focus → scope → child），enabled 只影响 scope 暴露的控制器：
    // 禁用时消费方拿到 null，走原生遍历路径；控制器实例保活，重新启用即恢复。
    return Focus(
      focusNode: _controller.fallbackNode,
      canRequestFocus: widget.enabled,
      skipTraversal: true,
      child: _FushiFocusScope(
        controller: widget.enabled ? _controller : null,
        child: widget.child,
      ),
    );
  }
}

class _FushiFocusScope extends InheritedNotifier<FushiFocusController> {
  const _FushiFocusScope({
    required this.controller,
    required super.child,
  }) : super(notifier: controller);

  /// null = 焦点导航禁用（FushiFocusRoot.enabled == false）。
  final FushiFocusController? controller;
}
