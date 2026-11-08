import 'package:flutter/foundation.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:material_ui/material_ui.dart';

/// A module control from the companion for the page that owns the context
/// (S3): [action] and [args] belong to that module.
typedef CompanionCommandHandler =
    void Function(String action, Map<String, Object?> args);

/// Shows a main-screen lookup on the companion (the bridge's `sendLookup`);
/// false when the companion did not take it.
typedef CompanionLookupSink =
    Future<bool> Function({
      required String text,
      int charIndex,
      String? sentence,
    });

/// The controller side of the companion (S6), bound by the companion bridge:
/// lets the main engine's controller lookup mode drive the companion's lookup
/// and focus without depending on the bridge / AppModel layer.
abstract interface class CompanionControllerSink {
  /// The companion's lookup is open (A mines instead of looking up again).
  bool get lookupOpen;

  /// Sends one of `CompanionLookupActions` to the open lookup. False when the
  /// companion did not take it.
  bool sendLookupAction(
    String action, [
    Map<String, Object?> args = const <String, Object?>{},
  ]);

  /// Sends one `CompanionPanelNav` step (R1 panel drive). False when the
  /// companion did not take it.
  bool sendPanelNav(String action);
}

class _Claim {
  _Claim({
    required this.owner,
    required this.context,
    required this.route,
    required this.onCommand,
    required this.onLookupCounted,
  });

  final Object owner;
  CompanionContext context;
  Route<Object?>? route;
  CompanionCommandHandler? onCommand;
  VoidCallback? onLookupCounted;
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
  CompanionContextRegistry({
    ValueListenable<HomeTab>? homeTab,
    ValueListenable<String?>? settingsHomeCategory,
  }) : _homeTab = homeTab,
       _settingsHomeCategory = settingsHomeCategory {
    _homeTab?.addListener(_recompute);
    _settingsHomeCategory?.addListener(_recompute);
    _current = _resolve();
  }

  final ValueListenable<HomeTab>? _homeTab;

  /// The category the settings home tab shows beside its list (two-pane
  /// layout); null on the plain category list.
  final ValueListenable<String?>? _settingsHomeCategory;
  final List<_Claim> _claims = <_Claim>[];

  /// The page route on top (dialogs and sheets above it do not count); null
  /// before the first push or when only the root route is up.
  Route<Object?>? _topPage;

  late _Resolved _current;
  int _snapshotRevision = 0;
  final ValueNotifier<bool> _active = ValueNotifier<bool>(false);

  /// The companion panel is up and wanted (mirrored by the companion bridge
  /// from `SecondScreenController.isActive`). Pages keep their snapshot
  /// timers and lookup routing off while this is false, so single-screen
  /// devices pay nothing.
  ValueListenable<bool> get active => _active;

  /// The companion bridge's mirror of `SecondScreenController.isActive`.
  void setActive(bool value) => _active.value = value;

  final ValueNotifier<bool> _lookupsOnCompanion = ValueNotifier<bool>(true);

  /// The user's "Lookups open on" setting (mirrored by the companion bridge
  /// from `SecondScreenController.lookupScreen`): true = the companion's
  /// Lookup tab (default), false = the page's in-page popup on top while the
  /// companion keeps its panels. Applies to every main-screen lookup that goes
  /// through [routeLookup] and to the controller lookup mode
  /// ([lookupController]). Lookups started on the panel itself (its
  /// transcript / subtitle / lyric / OCR text) never come through here and
  /// always open on the companion.
  ValueListenable<bool> get lookupsOnCompanion => _lookupsOnCompanion;

  void setLookupsOnCompanion(bool value) => _lookupsOnCompanion.value = value;

  /// Main-screen lookups go to the companion right now (it is up and the
  /// setting says so). One synchronous check for pages that want to skip
  /// work when they will show their own popup anyway.
  bool get routesLookups => _active.value && _lookupsOnCompanion.value;

  CompanionLookupSink? _lookupSink;

  /// Where [routeLookup] sends lookups (the companion bridge binds its
  /// `sendLookup` on start). Kept here so pages route lookups without
  /// depending on the bridge / AppModel layer.
  void bindLookupSink(CompanionLookupSink? sink) => _lookupSink = sink;

  /// Sends a lookup made on the main screen to the companion's Lookup tab.
  /// False when the companion is not in use, the user wants lookups on the
  /// main screen ([lookupsOnCompanion]) or the companion did not take it: the
  /// page shows its in-page popup exactly as on a single screen. Those paths
  /// are one synchronous check.
  Future<bool> routeLookup({
    required String text,
    int charIndex = -1,
    String? sentence,
  }) async {
    final CompanionLookupSink? sink = _lookupSink;
    if (!routesLookups || sink == null || text.trim().isEmpty) return false;
    return sink(text: text, charIndex: charIndex, sentence: sentence);
  }

  CompanionControllerSink? _controllerSink;

  /// The companion bridge's controller side (S6); null before the bridge
  /// starts. Use [controller] to reach it.
  void bindControllerSink(CompanionControllerSink? sink) =>
      _controllerSink = sink;

  /// The companion's controller side while the companion is up; null when it
  /// is not (controller lookup then falls back to the in-page popup and R1
  /// keeps its page binding).
  CompanionControllerSink? get controller =>
      _active.value ? _controllerSink : null;

  /// The companion's controller side for **lookup** follow-ups (mine, audio,
  /// entry moves, scroll, close): null when the companion is not up or the
  /// user wants lookups on the main screen ([lookupsOnCompanion]), so the
  /// controller lookup mode drives the in-page popup. R1 panel drive keeps
  /// using [controller].
  CompanionControllerSink? get lookupController =>
      routesLookups ? _controllerSink : null;

  /// The companion started one lookup: counts it through the context owner's
  /// lookup counter (the one its in-page popup uses). False when the owner
  /// has none (a route-level context, a page without lookups).
  bool countLookup() {
    final VoidCallback? count = _current.claim?.onLookupCounted;
    if (count == null) return false;
    count();
    return true;
  }

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
  /// claim's place). [route] is the owner's page route (null: always counts);
  /// a claim made before the route was known takes it on a later call.
  /// [onLookupCounted] counts one lookup made on the companion for this page
  /// ([countLookup]); pages pass the counter their in-page popup uses.
  void claim(
    Object owner,
    CompanionContext context, {
    Route<Object?>? route,
    CompanionCommandHandler? onCommand,
    VoidCallback? onLookupCounted,
  }) {
    for (final _Claim existing in _claims) {
      if (identical(existing.owner, owner)) {
        if (existing.context != context) existing.snapshot = null;
        existing.context = context;
        existing.onCommand = onCommand;
        existing.onLookupCounted = onLookupCounted;
        if (route != null) existing.route = route;
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
        onLookupCounted: onLookupCounted,
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
    final CompanionContext home = companionContextForHomeTab(_homeTab?.value);
    final String? category = _settingsHomeCategory?.value;
    if (home.kind == CompanionContextKind.settings && category != null) {
      return _Resolved(
        CompanionContext(
          CompanionContextKind.settings,
          settingsCategory: category,
        ),
        null,
      );
    }
    return _Resolved(home, null);
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
    _settingsHomeCategory?.removeListener(_recompute);
    _active.dispose();
    _lookupsOnCompanion.dispose();
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
  settingsHomeCategory: companionSettingsHomeCategory,
);

/// The settings category the settings home tab shows in its detail pane
/// (`SettingsDestinationId.name`, two-pane layout only; null otherwise). Set
/// by the settings home page; makes the home route's `settings` context name
/// that category, like a pushed settings page does with its claim.
final ValueNotifier<String?> companionSettingsHomeCategory =
    ValueNotifier<String?>(null);

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
