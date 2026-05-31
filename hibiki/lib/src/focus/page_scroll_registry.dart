import 'package:flutter/widgets.dart';

/// App-level stack of the current page's primary scroll controller.
///
/// Why this exists (and why `PrimaryScrollController.maybeOf` is not enough):
/// the gamepad LB/RB page-scroll fallback runs from the focused widget's
/// context. On a *pure-display* page (e.g. reading statistics) there is nothing
/// focusable in the body, so focus rests on the single top-level
/// [HibikiFocusRoot] fallback node — which lives ABOVE every route, i.e. above
/// the page scaffold's [PrimaryScrollController]. `maybeOf` only walks
/// ancestors, so it can never reach a controller that sits *below* the focus.
///
/// Pages push their scroll controller here on mount and pop it on dispose; the
/// top of the stack is the visible route's controller, reachable regardless of
/// where focus currently sits in the tree.
class PageScrollRegistry {
  PageScrollRegistry._();

  static final List<ScrollController> _stack = <ScrollController>[];

  static void push(ScrollController controller) => _stack.add(controller);

  static void pop(ScrollController controller) => _stack.remove(controller);

  /// The top-most (visible route) controller, but only when it has exactly one
  /// attached scroll position — 0 means nothing to scroll, >1 is ambiguous and
  /// `.position` would throw. Returns null otherwise so the caller can fall
  /// back to a context-based lookup.
  static ScrollController? get current {
    if (_stack.isEmpty) return null;
    final ScrollController controller = _stack.last;
    return controller.positions.length == 1 ? controller : null;
  }

  @visibleForTesting
  static void debugClear() => _stack.clear();

  @visibleForTesting
  static int get debugDepth => _stack.length;
}
