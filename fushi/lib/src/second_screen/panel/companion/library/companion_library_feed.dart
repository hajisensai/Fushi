import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/companion/modules/library_companion_schema.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_panel_session.dart';
import 'package:material_ui/material_ui.dart';

/// Browse mode's data (Library tab, S5): every page asks the main engine
/// (`library.*` requests, see `library_companion_schema.dart`), one fetch at
/// a time per feed. A refresh while a fetch runs marks the data stale: the
/// running fetch's (outdated) result is dropped and exactly one more fetch
/// runs.

Map<String, Object?> companionLibraryReplyObject(Object? reply) {
  if (reply is! Map) {
    throw const CompanionRequestException('unexpected library reply');
  }
  return <String, Object?>{
    for (final MapEntry<Object?, Object?> e in reply.entries)
      if (e.key is String) e.key! as String: e.value,
  };
}

/// The fetch loop shared by the feeds: [refresh] runs one fetch at a time;
/// a call during a fetch makes the loop run once more and drops the result
/// it was waiting for.
abstract class CompanionLibraryFeedBase extends ChangeNotifier {
  CompanionLibraryFeedBase(this.session);

  final CompanionPanelSession session;

  bool _fetching = false;
  bool _stale = false;
  bool _disposed = false;
  bool _failed = false;
  String? _error;

  /// The last fetch failed (older data, if any, is still shown).
  bool get failed => _failed;

  /// The main engine's error text of the last failed fetch (e.g. a media
  /// server that is offline).
  String? get error => _error;

  /// A fetch is running.
  bool get fetching => _fetching;

  bool get disposed => _disposed;

  /// Runs one request and applies its reply (called by [refresh]).
  @protected
  Future<void> fetchOnce();

  /// Loads the data again (see the class doc for overlapping calls).
  Future<void> refresh() async {
    if (_fetching) {
      _stale = true;
      return;
    }
    _fetching = true;
    do {
      _stale = false;
      try {
        await fetchOnce();
        if (_stale || _disposed) continue;
        _failed = false;
        _error = null;
      } on CompanionRequestException catch (e) {
        if (_stale || _disposed) continue;
        _failed = true;
        _error = e.message;
      }
    } while (_stale && !_disposed);
    _fetching = false;
    notify();
  }

  /// True when a reply that just arrived is outdated (a newer refresh was
  /// asked for, or the feed is gone).
  @protected
  bool get outdated => _stale || _disposed;

  /// After a failed load: shows the loading state again and reloads.
  Future<void> retry() {
    if (_failed) {
      _failed = false;
      _error = null;
      notify();
    }
    return refresh();
  }

  @protected
  void notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// A single reply: Browse's Home (`library.home`) or an item's details
/// (`library.details`).
class CompanionLibraryValueFeed<T extends Object>
    extends CompanionLibraryFeedBase {
  CompanionLibraryValueFeed._(
    super.session, {
    required String method,
    required Map<String, Object?> args,
    required T Function(Map<String, Object?> json) parse,
  }) : _method = method,
       _args = args,
       _parse = parse;

  static CompanionLibraryValueFeed<CompanionLibraryHome> home(
    CompanionPanelSession session,
  ) => CompanionLibraryValueFeed<CompanionLibraryHome>._(
    session,
    method: CompanionRequestMethods.libraryHome,
    args: const <String, Object?>{},
    parse: CompanionLibraryHome.fromJson,
  );

  static CompanionLibraryValueFeed<CompanionLibraryDetails> details(
    CompanionPanelSession session,
    String ref,
  ) => CompanionLibraryValueFeed<CompanionLibraryDetails>._(
    session,
    method: CompanionRequestMethods.libraryDetails,
    args: <String, Object?>{CompanionLibraryArgs.ref: ref},
    parse: CompanionLibraryDetails.fromJson,
  );

  final String _method;
  final Map<String, Object?> _args;
  final T Function(Map<String, Object?> json) _parse;

  T? _value;

  /// The last loaded value; null until the first fetch returns.
  T? get value => _value;

  /// Nothing to show yet and no failure.
  bool get loading => _value == null && !failed;

  /// Replaces the value (e.g. a details page after `library.markFinished`).
  void replace(T value) {
    _value = value;
    notify();
  }

  @override
  Future<void> fetchOnce() async {
    final Object? reply = await session.request(_method, _args);
    if (outdated) return;
    _value = _parse(companionLibraryReplyObject(reply));
  }
}

/// A paged list: a section / container (`library.list`) or the search over
/// everything (`library.search`). [loadMore] appends the next page;
/// [refresh] reloads from the start, keeping as many items as were loaded
/// (up to [CompanionLibraryArgs.maxPageSize]).
class CompanionLibraryListFeed extends CompanionLibraryFeedBase {
  CompanionLibraryListFeed.section(
    super.session, {
    required this.section,
    this.parent,
  }) : search = false;

  /// Browse's "Search everything" (set the query with [setQuery]).
  CompanionLibraryListFeed.search(super.session)
    : section = CompanionLibrarySection.home,
      parent = null,
      search = true;

  final CompanionLibrarySection section;

  /// The container's ref ([CompanionLibraryItem.ref]); null = the section's
  /// top level.
  final String? parent;

  /// `library.search` instead of `library.list`.
  final bool search;

  String _query = '';
  List<CompanionLibraryItem>? _items;
  bool _hasMore = false;
  String? _title;
  int? _total;

  /// Where the next page starts (`CompanionLibraryPage.followingOffset`:
  /// media servers page by server rows, not by items shown).
  int _nextOffset = 0;
  bool _loadingMore = false;
  bool _moreFailed = false;

  /// Bumps on every refresh, so a page that a refresh overtook is dropped.
  int _generation = 0;

  String get query => _query;

  /// Loaded items; null until the first page returns.
  List<CompanionLibraryItem>? get items => _items;

  bool get hasMore => _hasMore;

  /// The container's title (parent lists).
  String? get title => _title;

  int? get total => _total;

  bool get loadingMore => _loadingMore;

  /// The last [loadMore] failed.
  bool get moreFailed => _moreFailed;

  /// Nothing to show yet and no failure.
  bool get loading => _items == null && !failed;

  /// Filters this list ([search] feeds: searches) and reloads from the
  /// first page.
  Future<void> setQuery(String query) {
    if (query != _query) {
      _query = query;
      // A different filter: the old pages do not apply.
      _items = null;
      _hasMore = false;
      _nextOffset = 0;
      _total = null;
      notify();
    }
    return refresh();
  }

  Map<String, Object?> _args(int offset, int limit) => <String, Object?>{
    if (!search) CompanionLibraryArgs.section: section.wire,
    if (!search) CompanionLibraryArgs.parent: ?parent,
    if (search || _query.isNotEmpty) CompanionLibraryArgs.query: _query,
    CompanionLibraryArgs.offset: offset,
    CompanionLibraryArgs.limit: limit,
  };

  String get _method => search
      ? CompanionRequestMethods.librarySearch
      : CompanionRequestMethods.libraryList;

  @override
  Future<void> fetchOnce() async {
    // A page still on its way belongs to the old list: dropped.
    _generation++;
    _loadingMore = false;
    // Reload the span already loaded (at least one page).
    final int loaded = _items == null ? 0 : _nextOffset;
    final int limit = loaded.clamp(
      CompanionLibraryArgs.pageSize,
      CompanionLibraryArgs.maxPageSize,
    );
    final Object? reply = await session.request(_method, _args(0, limit));
    if (outdated) return;
    final CompanionLibraryPage page = CompanionLibraryPage.fromJson(
      companionLibraryReplyObject(reply),
    );
    _items = page.items;
    _hasMore = page.hasMore;
    _nextOffset = page.followingOffset;
    _title = page.title ?? _title;
    _total = page.total;
    _moreFailed = false;
  }

  /// Appends the next page (no-op while loading or when nothing is left).
  Future<void> loadMore() async {
    final List<CompanionLibraryItem>? items = _items;
    if (items == null || !_hasMore || _loadingMore || fetching || disposed) {
      return;
    }
    final int generation = _generation;
    _loadingMore = true;
    _moreFailed = false;
    notify();
    try {
      final Object? reply = await session.request(
        _method,
        _args(_nextOffset, CompanionLibraryArgs.pageSize),
      );
      if (disposed || generation != _generation) return;
      final CompanionLibraryPage page = CompanionLibraryPage.fromJson(
        companionLibraryReplyObject(reply),
      );
      _items = <CompanionLibraryItem>[...items, ...page.items];
      _hasMore = page.hasMore;
      _nextOffset = page.followingOffset;
      _total = page.total ?? _total;
    } on CompanionRequestException {
      if (disposed || generation != _generation) return;
      _moreFailed = true;
    } finally {
      if (generation == _generation) _loadingMore = false;
      notify();
    }
  }

  /// [item] replaced in place (after `library.markFinished`).
  void replaceItem(CompanionLibraryItem item) {
    final List<CompanionLibraryItem>? items = _items;
    if (items == null) return;
    _items = <CompanionLibraryItem>[
      for (final CompanionLibraryItem i in items) i.ref == item.ref ? item : i,
    ];
    notify();
  }
}

/// Local cover files of items whose cover is not local yet
/// ([CompanionLibraryItem.hasRemoteCover]): asked once per ref
/// (`library.cover`), results cached, including "no cover".
class CompanionLibraryCovers extends ChangeNotifier {
  CompanionLibraryCovers(this.session);

  final CompanionPanelSession session;
  final Map<String, String?> _paths = <String, String?>{};
  final Set<String> _asking = <String>{};
  bool _disposed = false;

  /// The cover file of [item]: its own [CompanionLibraryItem.coverPath], or
  /// the cached `library.cover` result (asked for on the first call).
  String? coverOf(CompanionLibraryItem item) {
    final String? own = item.coverPath;
    if (own != null && own.isNotEmpty) return own;
    if (!item.hasRemoteCover) return null;
    if (_paths.containsKey(item.ref)) return _paths[item.ref];
    if (_asking.add(item.ref)) unawaited(_ask(item.ref));
    return null;
  }

  Future<void> _ask(String ref) async {
    String? path;
    try {
      final Object? reply = await session.request(
        CompanionRequestMethods.libraryCover,
        <String, Object?>{CompanionLibraryArgs.ref: ref},
      );
      path = reply is String && reply.isNotEmpty ? reply : null;
    } on CompanionRequestException {
      // No cover for this ref (the placeholder stays); not asked again.
      path = null;
    }
    _asking.remove(ref);
    _paths[ref] = path;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Covers shared by every Browse page.
final ChangeNotifierProvider<CompanionLibraryCovers>
companionLibraryCoversProvider = ChangeNotifierProvider<CompanionLibraryCovers>(
  (Ref ref) => CompanionLibraryCovers(ref.watch(companionPanelSessionProvider)),
);

/// Keeps a Browse page's feeds in step with the main engine: a
/// `libraryChanged` ping marks every feed stale; the shown one reloads at
/// once while the page is visible (its tab and mode are shown and no page is
/// pushed over it), the others when they are shown.
mixin CompanionLibraryLive<W extends StatefulWidget> on State<W> {
  CompanionPanelSession? _liveSession;
  int _revision = 0;
  bool _visible = false;
  final Set<CompanionLibraryFeedBase> _staleFeeds =
      <CompanionLibraryFeedBase>{};

  /// Every feed of the page.
  List<CompanionLibraryFeedBase> get liveFeeds;

  /// The feed the page shows right now (null = none).
  CompanionLibraryFeedBase? get shownFeed;

  /// The page is on screen.
  bool get liveVisible => _visible;

  /// Starts following [session]; every feed starts stale (loads when shown).
  void startLive(CompanionPanelSession session) {
    _liveSession = session;
    _revision = session.libraryRevision;
    _staleFeeds.addAll(liveFeeds);
    session.addListener(_onSession);
  }

  /// [feed] (new, or with changed arguments) needs a load when shown.
  void markStale(CompanionLibraryFeedBase feed) => _staleFeeds.add(feed);

  /// Takes [feed] out of the stale set (the caller loads it itself).
  bool takeStale(CompanionLibraryFeedBase feed) => _staleFeeds.remove(feed);

  void _onSession() {
    final CompanionPanelSession session = _liveSession!;
    if (session.libraryRevision == _revision) return;
    _revision = session.libraryRevision;
    _staleFeeds.addAll(liveFeeds);
    syncLive();
  }

  /// Reloads the shown feed if it is stale and the page is visible.
  void syncLive() {
    if (!_visible) return;
    final CompanionLibraryFeedBase? feed = shownFeed;
    if (feed != null && _staleFeeds.remove(feed)) unawaited(feed.refresh());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true);
    syncLive();
  }

  @override
  void dispose() {
    _liveSession?.removeListener(_onSession);
    super.dispose();
  }
}
