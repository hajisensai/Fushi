import 'dart:collection';

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
    if (!entry.canFocus && entry.focusNode.hasPrimaryFocus) {
      scheduleRepair();
      return;
    }
    _handleFocusChange();
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
    if (entry == null || !entry.canFocus) return false;
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
    final int nextIndex = _nextIndex(
      currentIndex: currentIndex,
      direction: direction,
      count: targets.length,
    );
    return requestById(targets[nextIndex].id);
  }

  void ensureFocus() {
    final FocusNode? primary = FocusManager.instance.primaryFocus;
    if (_isUsablePrimary(primary)) {
      _handleFocusChange();
      return;
    }

    final HibikiFocusTargetEntry? active = _currentEntry();
    if (active != null && active.canFocus) {
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
      if (identical(entry.focusNode, primary)) {
        _activeId = entry.id;
        return entry;
      }
    }
    if (_activeId == null) return null;
    return _entries[_activeId!];
  }

  List<HibikiFocusTargetEntry> _focusableEntries() {
    return _entries.values
        .where((HibikiFocusTargetEntry entry) => entry.canFocus)
        .toList(growable: false);
  }

  bool _isUsablePrimary(FocusNode? primary) {
    if (primary == null) return false;
    if (identical(primary, fallbackNode)) return true;
    if (primary is FocusScopeNode) return false;
    if (primary.skipTraversal) return false;
    for (final HibikiFocusTargetEntry entry in _entries.values) {
      if (identical(entry.focusNode, primary)) return entry.canFocus;
    }
    return primary.context != null && primary.canRequestFocus;
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
        if (!entry.canFocus) {
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
