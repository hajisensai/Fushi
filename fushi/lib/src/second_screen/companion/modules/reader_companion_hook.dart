import 'dart:async';

import 'package:fushi/src/second_screen/companion/companion_context.dart';
import 'package:fushi/src/second_screen/companion/companion_page_link.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/companion/modules/audiobook_companion_schema.dart';
import 'package:fushi/src/second_screen/companion/modules/reader_companion_schema.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:material_ui/material_ui.dart';

/// One bookmark as the companion lists it.
typedef ReaderCompanionBookmark = ({int id, String label, int chapter});

/// This book's reading today (the reader's statistics sheet numbers).
typedef ReaderCompanionStats = ({
  int todayMs,
  int todayChars,
  int todayLookups,
  int todayCards,
});

/// What the EPUB reader page gives its companion hook. Getters are cheap
/// (in-memory page state); the `load*` calls do I/O and run only while the
/// companion is up.
abstract interface class ReaderCompanionPage {
  bool get mounted;

  /// Null until the book is loaded.
  String? get bookTitle;

  /// The audiobook (lyrics) view is on with an audiobook attached: the page
  /// owns the `audiobook` context instead of `reader`.
  bool get audiobookView;

  /// Live reader state: every [ReaderCompanionKeys] except title / author /
  /// cover / bookmarks / stats (the hook adds those).
  Map<String, Object?> readerState();

  /// Live audiobook state: every [AudiobookCompanionKeys] except title /
  /// author / cover.
  Map<String, Object?> audiobookState();

  /// Author and local cover file (resolved once per book; file I/O).
  Future<({String? author, String? cover})> loadBookInfo();

  /// Bookmarks are possible (the book has a stable id).
  bool get bookmarksEnabled;

  Future<List<ReaderCompanionBookmark>> loadBookmarks();

  /// Fires when the bookmarks table changed (null: no database).
  Stream<void>? bookmarkChanges();

  Future<ReaderCompanionStats?> loadStats();

  Future<void> runReaderCommand(String action, Map<String, Object?> args);

  Future<void> runAudiobookCommand(String action, Map<String, Object?> args);
}

/// The reader page's end of the companion: claims `reader` (or `audiobook`
/// while the audiobook view is on), publishes a coarse snapshot ~1/s and
/// carries out the panel's commands.
///
/// Bookmarks, today's stats and the book info are loaded only while the
/// companion is active (bookmarks again on every bookmarks table change,
/// stats every [statsPeriod]); while it is not active no timer or
/// subscription exists, so paginated / continuous / vn reading on a single
/// screen pays nothing.
class ReaderCompanionHook {
  ReaderCompanionHook(
    this._page, {
    CompanionContextRegistry? registry,
    Duration period = const Duration(seconds: 1),
    this.statsPeriod = const Duration(minutes: 1),
  }) : _registry = registry ?? companionContexts,
       _link = CompanionPageLink(registry: registry, period: period);

  final ReaderCompanionPage _page;
  final CompanionContextRegistry _registry;
  final CompanionPageLink _link;
  final Duration statsPeriod;

  Route<Object?>? _route;
  CompanionContextKind? _kind;
  String? _title;
  bool _started = false;
  bool _disposed = false;

  ({String? author, String? cover})? _info;
  bool _infoLoading = false;
  List<ReaderCompanionBookmark> _bookmarks = const <ReaderCompanionBookmark>[];
  ReaderCompanionStats? _stats;
  StreamSubscription<void>? _bookmarkSub;
  Timer? _statsTimer;
  bool _loadsRunning = false;

  /// Book info / bookmarks / stats were requested since the companion
  /// became active (the first build with a loaded book asks for them).
  bool _loadedForActivation = false;

  /// The companion is up (cheap; gate companion-only work on it).
  bool get isActive => _link.isActive;

  /// Call from the page's `didChangeDependencies` (route known) and when the
  /// book loads or the view changes.
  void attach(Route<Object?>? route) {
    if (_disposed) return;
    _route = route ?? _route;
    if (!_started) {
      _started = true;
      _link.startSnapshots(_build);
      _registry.active.addListener(_onActiveChanged);
      _onActiveChanged();
    }
    _claimIfChanged(force: true);
  }

  /// Publish now (after a page turn, chapter change, audio state change).
  void publishNow() {
    if (_disposed || !_link.isActive) return;
    _link.publishNow();
  }

  void _claimIfChanged({bool force = false}) {
    final String? title = _page.bookTitle;
    final CompanionContextKind kind = _page.audiobookView
        ? CompanionContextKind.audiobook
        : CompanionContextKind.reader;
    if (!force && kind == _kind && title == _title) return;
    _kind = kind;
    _title = title;
    _link.claim(
      CompanionContext(kind, title: title),
      route: _route,
      onCommand: _onCommand,
    );
  }

  Map<String, Object?>? _build() {
    if (!_page.mounted) return null;
    final String? title = _page.bookTitle;
    if (title == null) return null;
    _claimIfChanged();
    if (!_loadedForActivation) {
      _loadedForActivation = true;
      unawaited(_loadAll());
    }
    final ({String? author, String? cover})? info = _info;
    if (_kind == CompanionContextKind.audiobook) {
      return <String, Object?>{
        ..._page.audiobookState(),
        AudiobookCompanionKeys.title: title,
        AudiobookCompanionKeys.author: info?.author,
        AudiobookCompanionKeys.cover: info?.cover,
      };
    }
    final ReaderCompanionStats? stats = _stats;
    return <String, Object?>{
      ..._page.readerState(),
      ReaderCompanionKeys.title: title,
      ReaderCompanionKeys.author: info?.author,
      ReaderCompanionKeys.cover: info?.cover,
      ReaderCompanionKeys.bookmarksEnabled: _page.bookmarksEnabled,
      ReaderCompanionKeys.bookmarks: <Map<String, Object?>>[
        for (final ReaderCompanionBookmark b in _bookmarks.take(
          ReaderCompanionKeys.maxBookmarks,
        ))
          <String, Object?>{
            ReaderCompanionKeys.bookmarkId: b.id,
            ReaderCompanionKeys.bookmarkLabel: b.label,
            ReaderCompanionKeys.bookmarkChapter: b.chapter,
          },
      ],
      ReaderCompanionKeys.stats: stats == null
          ? null
          : <String, Object?>{
              ReaderCompanionKeys.todayMs: stats.todayMs,
              ReaderCompanionKeys.todayChars: stats.todayChars,
              ReaderCompanionKeys.todayLookups: stats.todayLookups,
              ReaderCompanionKeys.todayCards: stats.todayCards,
            },
    };
  }

  void _onActiveChanged() {
    if (_disposed) return;
    if (_registry.active.value) {
      _bookmarkSub ??= _page.bookmarkChanges()?.listen(
        (_) => unawaited(_reloadBookmarks()),
      );
      _statsTimer ??= Timer.periodic(
        statsPeriod,
        (_) => unawaited(_reloadStats()),
      );
    } else {
      _loadedForActivation = false;
      unawaited(_bookmarkSub?.cancel());
      _bookmarkSub = null;
      _statsTimer?.cancel();
      _statsTimer = null;
    }
  }

  Future<void> _loadAll() async {
    if (_loadsRunning) return;
    _loadsRunning = true;
    try {
      await Future.wait(<Future<void>>[
        _loadInfo(),
        _reloadBookmarks(),
        _reloadStats(),
      ]);
    } finally {
      _loadsRunning = false;
    }
  }

  Future<void> _loadInfo() async {
    if (_info != null || _infoLoading || _page.bookTitle == null) return;
    _infoLoading = true;
    try {
      _info = await _page.loadBookInfo();
      publishNow();
    } catch (error, stack) {
      ErrorLogService.instance.log('ReaderCompanion.info', error, stack);
    } finally {
      _infoLoading = false;
    }
  }

  Future<void> _reloadBookmarks() async {
    if (_disposed || !_page.bookmarksEnabled) return;
    try {
      final List<ReaderCompanionBookmark> rows = await _page.loadBookmarks();
      if (_disposed) return;
      _bookmarks = rows;
      publishNow();
    } catch (error, stack) {
      ErrorLogService.instance.log('ReaderCompanion.bookmarks', error, stack);
    }
  }

  Future<void> _reloadStats() async {
    if (_disposed) return;
    try {
      final ReaderCompanionStats? stats = await _page.loadStats();
      if (_disposed) return;
      _stats = stats;
      publishNow();
    } catch (error, stack) {
      ErrorLogService.instance.log('ReaderCompanion.stats', error, stack);
    }
  }

  void _onCommand(String action, Map<String, Object?> args) =>
      unawaited(handleCommand(action, args));

  /// Runs one panel command on the page (only for the context it was meant
  /// for: the registry already checked the kind).
  Future<void> handleCommand(String action, Map<String, Object?> args) async {
    if (_disposed || !_page.mounted) return;
    try {
      if (_kind == CompanionContextKind.audiobook) {
        await _page.runAudiobookCommand(action, args);
      } else {
        await _page.runReaderCommand(action, args);
      }
    } catch (error, stack) {
      ErrorLogService.instance.log('ReaderCompanion.$action', error, stack);
    }
    publishNow();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_started) _registry.active.removeListener(_onActiveChanged);
    unawaited(_bookmarkSub?.cancel());
    _statsTimer?.cancel();
    _link.dispose();
  }
}
