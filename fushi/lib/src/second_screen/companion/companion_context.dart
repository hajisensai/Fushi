import 'package:flutter/foundation.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:material_ui/material_ui.dart';

/// A module control from the companion for the page that owns the context
/// (S3): [action] and [args] belong to that module.
typedef CompanionCommandHandler =
    void Function(String action, Map<String, Object?> args);

class _Claim {
  _Claim({
    required this.owner,
    required this.context,
    required this.route,
    required this.onCommand,
  });

  final Object owner;
  CompanionContext context;
  final Route<Object?>? route;
  CompanionCommandHandler? onCommand;
  Map<String, Object?>? snapshot;
}

/// Main engine: which context the top screen is in. The single source of
/// truth the companion bridge mirrors to the second screen.
///
/// Pages that have a companion panel **claim** the context while they are
/// open ([claim] / [release], or the [CompanionContextClaim] widget). Like the
/// floating ball's scenes, a claim only counts while its page is the top page:
/// the newest claim whose route is current (or is the top page under a
/// dialog) wins, so a reader under a pushed settings page does not own the
/// companion. Without such a claim the context comes from the route level: the
/// home shell's selected tab when the home route is on top
/// ([homeShellTabNotifier]: home / a library / settings / review), otherwise
/// [CompanionContextKind.none].
///
/// The registry always tracks (cheap, no I/O); whether anything is sent is
/// the bridge's call (`SecondScreenController.isActive`).
class CompanionContextRegistry extends ChangeNotifier {
  CompanionContextRegistry({ValueListenable<HomeTab>? homeTab})
    : _homeTab = homeTab {
    _homeTab?.addListener(_recompute);
    _current = _resolve();
  }

  final ValueListenable<HomeTab>? _homeTab;
  final List<_Claim> _claims = <_Claim>[];

  /// The page route on top (dialogs and sheets above it do not count); null
  /// before the first push or when only the root route is up.
  Route<Object?>? _topPage;

  late _Resolved _current;
  int _snapshotRevision = 0;

  /// The top screen's context.
  CompanionContext get current => _current.context;

  /// The page that owns [current]; null for a route-level context.
  Object? get currentOwner => _current.claim?.owner;

  /// The owner's last published snapshot (S3 module state); null when it has
  /// published none, or the context is route level.
  Map<String, Object?>? get currentSnapshot => _current.claim?.snapshot;

  /// Bumps on every snapshot the current owner publishes, so a listener can
  /// tell "new snapshot" from "context changed".
  int get snapshotRevision => _snapshotRevision;

  /// [owner] (a page) shows [context] on top. A new claim beats older ones;
  /// claiming again only updates the context and command handler (keeps the
  /// claim's place). [route] is the owner's page route (null: always counts).
  void claim(
    Object owner,
    CompanionContext context, {
    Route<Object?>? route,
    CompanionCommandHandler? onCommand,
  }) {
    for (final _Claim existing in _claims) {
      if (identical(existing.owner, owner)) {
        if (existing.context != context) existing.snapshot = null;
        existing.context = context;
        existing.onCommand = onCommand;
        _recompute();
        return;
      }
    }
    _claims.add(
      _Claim(
        owner: owner,
        context: context,
        route: route,
        onCommand: onCommand,
      ),
    );
    _recompute();
  }

  /// [owner]'s page closed: its claim (and snapshot) is gone.
  void release(Object owner) {
    final int before = _claims.length;
    _claims.removeWhere((_Claim c) => identical(c.owner, owner));
    if (_claims.length != before) _recompute();
  }

  /// Replaces [owner]'s module snapshot. Listeners hear about it only while
  /// [owner] owns the context.
  void publishSnapshot(Object owner, Map<String, Object?> data) {
    for (final _Claim c in _claims) {
      if (!identical(c.owner, owner)) continue;
      c.snapshot = data;
      if (identical(_current.claim, c)) {
        _snapshotRevision++;
        notifyListeners();
      }
      return;
    }
  }

  /// Hands a companion command to the current owner. False when the command
  /// was made for another context (it changed meanwhile) or nobody handles
  /// it.
  bool dispatchCommand(
    CompanionContextKind kind,
    String action,
    Map<String, Object?> args,
  ) {
    final _Claim? owner = _current.claim;
    final CompanionCommandHandler? handler = owner?.onCommand;
    if (owner == null || handler == null || owner.context.kind != kind) {
      return false;
    }
    handler(action, args);
    return true;
  }

  /// The navigator's top page changed ([CompanionContextRouteObserver]).
  void setTopPage(Route<Object?>? route) {
    _topPage = route;
    _recompute();
  }

  /// A route was pushed / popped above or below a claim: [Route.isCurrent]
  /// may have changed.
  void routesChanged() => _recompute();

  void _recompute() {
    final _Resolved next = _resolve();
    if (next.context == _current.context &&
        identical(next.claim, _current.claim)) {
      return;
    }
    _current = next;
    notifyListeners();
  }

  _Resolved _resolve() {
    for (int i = _claims.length - 1; i >= 0; i--) {
      final _Claim c = _claims[i];
      if (_counts(c.route)) return _Resolved(c.context, c);
    }
    final Route<Object?>? top = _topPage;
    if (top != null && !top.isFirst) {
      return const _Resolved(CompanionContext.none, null);
    }
    return _Resolved(companionContextForHomeTab(_homeTab?.value), null);
  }

  bool _counts(Route<Object?>? route) {
    if (route == null) return true;
    if (identical(route, _topPage)) return true;
    // Not yet (or no longer) in a navigator: not on screen.
    return route.isActive && route.isCurrent;
  }

  @override
  void dispose() {
    _homeTab?.removeListener(_recompute);
    super.dispose();
  }
}

class _Resolved {
  const _Resolved(this.context, this.claim);

  final CompanionContext context;
  final _Claim? claim;
}

/// The route-level context of a home shell tab.
CompanionContext companionContextForHomeTab(HomeTab? tab) => switch (tab) {
  null || HomeTab.home => const CompanionContext(CompanionContextKind.home),
  HomeTab.books => const CompanionContext(
    CompanionContextKind.library,
    library: CompanionLibraryKind.books,
  ),
  HomeTab.manga => const CompanionContext(
    CompanionContextKind.library,
    library: CompanionLibraryKind.manga,
  ),
  HomeTab.video => const CompanionContext(
    CompanionContextKind.library,
    library: CompanionLibraryKind.video,
  ),
  HomeTab.music => const CompanionContext(
    CompanionContextKind.library,
    library: CompanionLibraryKind.music,
  ),
  HomeTab.games => const CompanionContext(
    CompanionContextKind.library,
    library: CompanionLibraryKind.games,
  ),
  HomeTab.srs => const CompanionContext(CompanionContextKind.srs),
  HomeTab.settings => const CompanionContext(CompanionContextKind.settings),
  HomeTab.browse ||
  HomeTab.dictionaries ||
  HomeTab.web => CompanionContext.none,
};

/// App-wide registry (main engine), fed by [companionContextRouteObserver]
/// and the home shell's tab.
final CompanionContextRegistry companionContexts = CompanionContextRegistry(
  homeTab: homeShellTabNotifier,
);

/// Goes into `MaterialApp.navigatorObservers`: tells the registry which page
/// route is on top (dialogs / sheets above it do not change the context).
class CompanionContextRouteObserver extends NavigatorObserver {
  CompanionContextRouteObserver(this._registry);

  final CompanionContextRegistry _registry;
  Route<Object?>? _top;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute) {
      _setTop(route);
    } else {
      _registry.routesChanged();
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _leave(route, previousRoute);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _leave(route, previousRoute);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (identical(oldRoute, _top) && newRoute is PageRoute) {
      _setTop(newRoute);
    } else {
      _registry.routesChanged();
    }
  }

  void _leave(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (!identical(route, _top)) {
      _registry.routesChanged();
      return;
    }
    _setTop(previousRoute is PageRoute ? previousRoute : null);
  }

  void _setTop(Route<Object?>? route) {
    _top = route;
    _registry.setTopPage(route);
  }
}

final CompanionContextRouteObserver companionContextRouteObserver =
    CompanionContextRouteObserver(companionContexts);

/// Zero-layout widget a page puts in its tree to own the companion context
/// while it is the top page: claims on mount (with its page route), updates
/// when [companionContext] changes, releases on dispose.
class CompanionContextClaim extends StatefulWidget {
  const CompanionContextClaim({
    required this.companionContext,
    required this.child,
    this.onCommand,
    this.registry,
    super.key,
  });

  final CompanionContext companionContext;
  final CompanionCommandHandler? onCommand;

  /// Defaults to [companionContexts].
  final CompanionContextRegistry? registry;
  final Widget child;

  @override
  State<CompanionContextClaim> createState() => _CompanionContextClaimState();
}

class _CompanionContextClaimState extends State<CompanionContextClaim> {
  CompanionContextRegistry get _registry =>
      widget.registry ?? companionContexts;

  bool _claimed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_claimed) return;
    _claimed = true;
    _registry.claim(
      this,
      widget.companionContext,
      route: ModalRoute.of(context),
      onCommand: widget.onCommand,
    );
  }

  @override
  void didUpdateWidget(CompanionContextClaim oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.companionContext != widget.companionContext ||
        oldWidget.onCommand != widget.onCommand) {
      _registry.claim(
        this,
        widget.companionContext,
        onCommand: widget.onCommand,
      );
    }
  }

  @override
  void dispose() {
    _registry.release(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
