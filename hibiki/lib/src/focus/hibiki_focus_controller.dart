import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:hibiki/src/focus/hibiki_focus_scroll.dart';

@immutable
class HibikiFocusId {
  const HibikiFocusId(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is HibikiFocusId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

enum HibikiFocusDirection { up, down, left, right }

HibikiFocusDirection hibikiFocusDirectionFromTraversal(
  TraversalDirection direction,
) {
  switch (direction) {
    case TraversalDirection.up:
      return HibikiFocusDirection.up;
    case TraversalDirection.down:
      return HibikiFocusDirection.down;
    case TraversalDirection.left:
      return HibikiFocusDirection.left;
    case TraversalDirection.right:
      return HibikiFocusDirection.right;
  }
}

class HibikiFocusTargetEntry {
  const HibikiFocusTargetEntry({
    required this.id,
    required this.focusNode,
    required this.context,
    required this.enabled,
    required this.owner,
  });

  final HibikiFocusId id;
  final FocusNode focusNode;
  final BuildContext context;
  final bool enabled;
  final Object owner;

  bool get canFocus => enabled && focusNode.canRequestFocus;
}

class HibikiFocusController extends ChangeNotifier {
  HibikiFocusController()
      : fallbackNode = FocusNode(
          debugLabel: 'hibiki-focus-fallback',
          skipTraversal: true,
        );

  final FocusNode fallbackNode;
  final LinkedHashMap<HibikiFocusId, HibikiFocusTargetEntry> _entries =
      LinkedHashMap<HibikiFocusId, HibikiFocusTargetEntry>();

  BuildContext? _rootContext;
  HibikiFocusId? _activeId;
  bool _attached = false;
  bool _repairScheduled = false;

  BuildContext? get activeContext {
    final HibikiFocusTargetEntry? active = _currentEntry();
    if (active != null && active.context.mounted) return active.context;
    return fallbackNode.context ?? _rootContext;
  }

  HibikiFocusId? get activeId => _activeId;

  bool get activeIsOnlyFocusableInNearestScrollable {
    final HibikiFocusTargetEntry? active = _currentEntry();
    if (active == null || !active.context.mounted) return false;
    final ScrollableState? activeScrollable = Scrollable.maybeOf(
      active.context,
    );
    if (activeScrollable == null) return false;
    for (final HibikiFocusTargetEntry entry in _entries.values) {
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
    fallbackNode.dispose();
    _rootContext = null;
  }

  void register(HibikiFocusTargetEntry entry) {
    _entries[entry.id] = entry;
    // Recording the entry is the only synchronous work. Recomputing the active
    // focus is deferred to the post-frame repair: register() runs inside
    // didChangeDependencies, which for a lazily-built SliverList child fires
    // during a layout callback. Doing _handleFocusChange() here would call
    // ModalRoute.of()/notifyListeners() mid-build — illegal, and it explodes
    // when an off-screen focused sibling is being recycled (deactivated but not
    // yet unregistered) in the same pass. scheduleRepair() → ensureFocus() does
    // the same recomputation safely after the frame, and the FocusManager
    // listener handles every later focus change.
    scheduleRepair();
  }

  void unregister(HibikiFocusId id, FocusNode node, Object owner) {
    final HibikiFocusTargetEntry? current = _entries[id];
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

  bool requestById(HibikiFocusId id) {
    final HibikiFocusTargetEntry? entry = _entries[id];
    if (entry == null || !_entryCanFocus(entry)) return false;
    entry.focusNode.requestFocus();
    _activeId = id;
    _scheduleReveal(entry);
    notifyListeners();
    return true;
  }

  bool move(HibikiFocusDirection direction) {
    final List<HibikiFocusTargetEntry> targets = _focusableEntries();
    if (targets.isEmpty) {
      ensureFocus();
      return fallbackNode.hasPrimaryFocus;
    }

    final HibikiFocusTargetEntry? active = _currentEntry();
    final int currentIndex = active == null ? -1 : targets.indexOf(active);
    if (active != null) {
      final _GeometricMoveResult geometric =
          _geometricTarget(active, targets, direction);
      if (!geometric.hasGeometry) {
        return _moveByReadingOrder(
          currentIndex: currentIndex,
          direction: direction,
          targets: targets,
        );
      }
      final HibikiFocusTargetEntry? target = geometric.target;
      return target != null && requestById(target.id);
    }

    return _moveByReadingOrder(
      currentIndex: currentIndex,
      direction: direction,
      targets: targets,
    );
  }

  void ensureFocus() {
    final FocusNode? primary = FocusManager.instance.primaryFocus;
    if (_isUsablePrimary(primary)) {
      _handleFocusChange();
      return;
    }

    final HibikiFocusTargetEntry? active = _currentEntry();
    if (active != null && _entryCanFocus(active)) {
      active.focusNode.requestFocus();
      _activeId = active.id;
      _scheduleReveal(active);
      return;
    }

    final List<HibikiFocusTargetEntry> targets = _focusableEntries();
    if (targets.isNotEmpty) {
      targets.first.focusNode.requestFocus();
      _activeId = targets.first.id;
      _scheduleReveal(targets.first);
      notifyListeners();
      return;
    }

    if (fallbackNode.canRequestFocus && fallbackNode.context != null) {
      fallbackNode.requestFocus();
    }
  }

  void _scheduleReveal(HibikiFocusTargetEntry entry) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (entry.context.mounted && entry.focusNode.hasFocus) {
        HibikiFocusScroll.ensureVisible(entry.context);
      }
    });
  }

  void scheduleRepair() {
    if (_repairScheduled) return;
    _repairScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _repairScheduled = false;
      ensureFocus();
    });
  }

  HibikiFocusTargetEntry? _currentEntry() {
    final FocusNode? primary = FocusManager.instance.primaryFocus;
    for (final HibikiFocusTargetEntry entry in _entries.values) {
      if (_entryCanFocus(entry) && identical(entry.focusNode, primary)) {
        _activeId = entry.id;
        return entry;
      }
    }
    if (_activeId == null) return null;
    final HibikiFocusTargetEntry? active = _entries[_activeId!];
    if (active == null || !_entryCanFocus(active)) return null;
    return active;
  }

  List<HibikiFocusTargetEntry> _focusableEntries() {
    return _entries.values
        .where((HibikiFocusTargetEntry entry) => _entryCanFocus(entry))
        .toList(growable: false);
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
    for (final HibikiFocusTargetEntry entry in _entries.values) {
      if (identical(entry.focusNode, primary)) return _entryCanFocus(entry);
    }
    final BuildContext? context = primary.context;
    return context != null &&
        primary.canRequestFocus &&
        _isCurrentRoute(context);
  }

  bool _entryCanFocus(HibikiFocusTargetEntry entry) {
    return entry.canFocus && _isCurrentRoute(entry.context);
  }

  bool _isCurrentRoute(BuildContext context) {
    if (!context.mounted) return false;
    final ModalRoute<dynamic>? route = ModalRoute.of(context);
    return route == null || route.isCurrent;
  }

  _GeometricMoveResult _geometricTarget(
    HibikiFocusTargetEntry active,
    List<HibikiFocusTargetEntry> targets,
    HibikiFocusDirection direction,
  ) {
    final Rect? activeRect = _globalRectOf(active.context);
    if (activeRect == null) return const _GeometricMoveResult.noGeometry();
    final Offset activeCenter = activeRect.center;
    HibikiFocusTargetEntry? best;
    int bestBeam = -1;
    double bestAlong = double.infinity;
    double bestCross = double.infinity;
    const double epsilon = 2;

    for (final HibikiFocusTargetEntry target in targets) {
      if (identical(target, active)) continue;
      final Rect? targetRect = _globalRectOf(target.context);
      if (targetRect == null) continue;
      final Offset targetCenter = targetRect.center;
      final double dx = targetCenter.dx - activeCenter.dx;
      final double dy = targetCenter.dy - activeCenter.dy;

      final bool ahead;
      final double along;
      final double cross;
      final bool beam;
      switch (direction) {
        case HibikiFocusDirection.up:
          ahead = dy < -epsilon;
          along = -dy;
          cross = dx.abs();
          beam = _overlap(activeRect.left, activeRect.right, targetRect.left,
              targetRect.right);
          break;
        case HibikiFocusDirection.down:
          ahead = dy > epsilon;
          along = dy;
          cross = dx.abs();
          beam = _overlap(activeRect.left, activeRect.right, targetRect.left,
              targetRect.right);
          break;
        case HibikiFocusDirection.left:
          ahead = dx < -epsilon;
          along = -dx;
          cross = dy.abs();
          beam = _overlap(activeRect.top, activeRect.bottom, targetRect.top,
              targetRect.bottom);
          break;
        case HibikiFocusDirection.right:
          ahead = dx > epsilon;
          along = dx;
          cross = dy.abs();
          beam = _overlap(activeRect.top, activeRect.bottom, targetRect.top,
              targetRect.bottom);
          break;
      }
      if (!ahead) continue;

      final int beamScore = beam ? 1 : 0;
      final bool better = best == null ||
          beamScore > bestBeam ||
          (beamScore == bestBeam &&
              (along < bestAlong - epsilon ||
                  ((along - bestAlong).abs() <= epsilon && cross < bestCross)));
      if (better) {
        best = target;
        bestBeam = beamScore;
        bestAlong = along;
        bestCross = cross;
      }
    }
    return _GeometricMoveResult(target: best, hasGeometry: true);
  }

  bool _moveByReadingOrder({
    required int currentIndex,
    required HibikiFocusDirection direction,
    required List<HibikiFocusTargetEntry> targets,
  }) {
    final int nextIndex = _nextIndex(
      currentIndex: currentIndex,
      direction: direction,
      count: targets.length,
    );
    return requestById(targets[nextIndex].id);
  }

  static Rect? _globalRectOf(BuildContext context) {
    if (!context.mounted) return null;
    final RenderObject? renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return null;
    final Offset origin = renderObject.localToGlobal(Offset.zero);
    return origin & renderObject.size;
  }

  static bool _overlap(double aStart, double aEnd, double bStart, double bEnd) {
    return math.min(aEnd, bEnd) - math.max(aStart, bStart) > 0;
  }

  int _nextIndex({
    required int currentIndex,
    required HibikiFocusDirection direction,
    required int count,
  }) {
    if (currentIndex < 0) return 0;
    switch (direction) {
      case HibikiFocusDirection.down:
      case HibikiFocusDirection.right:
        return (currentIndex + 1).clamp(0, count - 1);
      case HibikiFocusDirection.up:
      case HibikiFocusDirection.left:
        return (currentIndex - 1).clamp(0, count - 1);
    }
  }

  void _handleFocusChange() {
    final FocusNode? primary = FocusManager.instance.primaryFocus;
    for (final HibikiFocusTargetEntry entry in _entries.values) {
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
class _GeometricMoveResult {
  const _GeometricMoveResult({
    required this.target,
    required this.hasGeometry,
  });

  const _GeometricMoveResult.noGeometry()
      : target = null,
        hasGeometry = false;

  final HibikiFocusTargetEntry? target;
  final bool hasGeometry;
}

class HibikiFocusRoot extends StatefulWidget {
  const HibikiFocusRoot({super.key, required this.child});

  final Widget child;

  static HibikiFocusController controllerOf(BuildContext context) {
    final _HibikiFocusScope? scope =
        context.dependOnInheritedWidgetOfExactType<_HibikiFocusScope>();
    assert(scope != null, 'No HibikiFocusRoot found in context');
    return scope!.controller;
  }

  static HibikiFocusController? maybeControllerOf(
    BuildContext context, {
    bool listen = true,
  }) {
    if (listen) {
      return context
          .dependOnInheritedWidgetOfExactType<_HibikiFocusScope>()
          ?.controller;
    }
    return context
        .getInheritedWidgetOfExactType<_HibikiFocusScope>()
        ?.controller;
  }

  @override
  State<HibikiFocusRoot> createState() => _HibikiFocusRootState();
}

class _HibikiFocusRootState extends State<HibikiFocusRoot> {
  late final HibikiFocusController _controller = HibikiFocusController();

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
    return Focus(
      focusNode: _controller.fallbackNode,
      canRequestFocus: true,
      skipTraversal: true,
      child: _HibikiFocusScope(
        controller: _controller,
        child: widget.child,
      ),
    );
  }
}

class _HibikiFocusScope extends InheritedNotifier<HibikiFocusController> {
  const _HibikiFocusScope({
    required HibikiFocusController controller,
    required super.child,
  })  : controller = controller,
        super(notifier: controller);

  final HibikiFocusController controller;
}
