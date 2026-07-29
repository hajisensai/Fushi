import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'package:hibiki/src/media/media_item.dart';

class MediaHistoryRepository extends ChangeNotifier {
  MediaHistoryRepository(
    this._db, {
    this.maximumSearchHistoryItems = 60,
    this.maximumMediaHistoryItems = 100,
    this.stashKey = 'stash',
  });

  final HibikiDatabase _db;
  final int maximumSearchHistoryItems;
  final int maximumMediaHistoryItems;
  final String stashKey;

  List<MediaItem> _mediaItemsCache = [];
  final Map<String, List<String>> _searchHistoryCache = {};

  List<MediaItem> get mediaItems => List.unmodifiable(_mediaItemsCache);

  Future<void> loadFromDb() async {
    final miRows = await _db.getAllMediaItems();
    _mediaItemsCache = miRows.map(_rowToMediaItem).toList();

    _searchHistoryCache.clear();
    final shRows = await _db.getAllSearchHistoryItems();
    for (final row in shRows) {
      _searchHistoryCache
          .putIfAbsent(row.historyKey, () => [])
          .add(row.searchTerm);
    }
  }

  // ── row conversion ───────────────────────────────────────────────────

  static MediaItem _rowToMediaItem(MediaItemRow r) {
    return MediaItem(
      id: r.id,
      mediaIdentifier: r.mediaIdentifier,
      title: r.title,
      mediaTypeIdentifier: r.mediaTypeIdentifier,
      mediaSourceIdentifier: r.mediaSourceIdentifier,
      position: r.position,
      duration: r.duration,
      canDelete: r.canDelete,
      canEdit: r.canEdit,
      base64Image: r.base64Image,
      imageUrl: r.imageUrl,
      audioUrl: r.audioUrl,
      author: r.author,
      authorIdentifier: r.authorIdentifier,
      extraUrl: r.extraUrl,
      extra: r.extra,
      sourceMetadata: r.sourceMetadata,
    );
  }

  static MediaItemsCompanion _mediaItemToCompanion(MediaItem item) {
    return MediaItemsCompanion(
      id: item.id != null ? Value(item.id!) : const Value.absent(),
      uniqueKey: Value(item.uniqueKey),
      mediaIdentifier: Value(item.mediaIdentifier),
      title: Value(item.title),
      mediaTypeIdentifier: Value(item.mediaTypeIdentifier),
      mediaSourceIdentifier: Value(item.mediaSourceIdentifier),
      position: Value(item.position),
      duration: Value(item.duration),
      canDelete: Value(item.canDelete),
      canEdit: Value(item.canEdit),
      base64Image: Value(item.base64Image),
      imageUrl: Value(item.imageUrl),
      audioUrl: Value(item.audioUrl),
      author: Value(item.author),
      authorIdentifier: Value(item.authorIdentifier),
      extraUrl: Value(item.extraUrl),
      extra: Value(item.extra),
      sourceMetadata: Value(item.sourceMetadata),
      importedAt: Value(DateTime.now().millisecondsSinceEpoch),
    );
  }

  // ── media item CRUD ──────────────────────────────────────────────────

  Future<void> addMediaItem(MediaItem item) async {
    _mediaItemsCache.removeWhere((m) => m.uniqueKey == item.uniqueKey);
    item.id = null;
    _mediaItemsCache.insert(0, item);

    await _db.deleteMediaItemByUniqueKey(item.uniqueKey);
    await _db.upsertMediaItem(_mediaItemToCompanion(item));
    await _db.trimMediaHistory(
        item.mediaTypeIdentifier, maximumMediaHistoryItems);

    final rows = await _db.getAllMediaItems();
    _mediaItemsCache = rows.map(_rowToMediaItem).toList();
  }

  Future<void> updateMediaItem(MediaItem item) async {
    final idx =
        _mediaItemsCache.indexWhere((m) => m.uniqueKey == item.uniqueKey);
    if (idx >= 0) _mediaItemsCache[idx] = item;
    await _db.upsertMediaItem(_mediaItemToCompanion(item));
  }

  Future<void> removeFromReadingList(String mediaIdentifier) async {
    _mediaItemsCache.removeWhere((m) => m.mediaIdentifier == mediaIdentifier);
    await _db.deleteMediaItemsByIdentifier(mediaIdentifier);
  }

  Future<void> deleteMediaItemById(MediaItem item) async {
    _mediaItemsCache.removeWhere((m) => m.id == item.id);
    if (item.id != null) {
      await _db.deleteMediaItemById(item.id!);
    }
  }

  /// Atomically applies a rebuilt book format and reconciles every persisted
  /// reader-history identity for the same stable `hoshi://book/<bookKey>`.
  ///
  /// The next cache is built from a full, deterministically ordered table read
  /// and published *inside* the transaction. A database, cache publication, or
  /// listener failure therefore rolls the database back; the outer catch also
  /// restores the exact pre-call cache if notification or commit fails.
  Future<void> applyBookFormatConversion({
    required String bookKey,
    required BookFormat format,
    required String epubPath,
    required int chapterCount,
    required String chaptersJson,
    String? coverPath,
    String? mangaReadingMode,
    FutureOr<void> Function()? afterHistoryDuplicatesDeletedForTesting,
  }) async {
    final List<MediaItem> previousCache = _mediaItemsCache;
    try {
      await _db.transaction(() async {
        final EpubBookRow? liveBook = await _db.getEpubBook(bookKey);
        if (liveBook == null) {
          throw StateError(
            'Cannot apply format conversion: book "$bookKey" no longer exists.',
          );
        }

        await _db.updateEpubBookFormat(
          bookKey,
          format: format,
          epubPath: epubPath,
          chapterCount: chapterCount,
          chaptersJson: chaptersJson,
          coverPath: coverPath,
          mangaReadingMode: mangaReadingMode,
        );
        await _db.reconcileBookMediaHistoryForFormat(
          bookKey,
          format,
          afterDuplicatesDeletedForTesting:
              afterHistoryDuplicatesDeletedForTesting,
        );

        final List<MediaItemRow> rows = await _db.getAllMediaItems();
        _mediaItemsCache = rows.map(_rowToMediaItem).toList(growable: false);
        _notifyListenersOrThrow();
      });
    } catch (error, stackTrace) {
      _mediaItemsCache = previousCache;
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// ChangeNotifier reports listener exceptions through [FlutterError] and
  /// otherwise treats notification as successful. Conversion cannot do that:
  /// a reported listener failure must escape the transaction so its writes are
  /// rolled back. The handler override exists only for this synchronous notify
  /// call and the captured original exception is rethrown with its stack.
  void _notifyListenersOrThrow() {
    FlutterErrorDetails? listenerFailure;
    final FlutterExceptionHandler? previousHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      listenerFailure ??= details;
    };
    try {
      notifyListeners();
    } finally {
      FlutterError.onError = previousHandler;
    }

    final FlutterErrorDetails? failure = listenerFailure;
    if (failure != null) {
      Error.throwWithStackTrace(
        failure.exception,
        failure.stack ?? StackTrace.current,
      );
    }
  }

  // ── media item queries ───────────────────────────────────────────────

  List<MediaItem> getMediaTypeHistory({required String mediaTypeKey}) {
    return _mediaItemsCache
        .where((m) => m.mediaTypeIdentifier == mediaTypeKey)
        .toList();
  }

  List<MediaItem> getMediaSourceHistory({required String mediaSourceKey}) {
    return _mediaItemsCache
        .where((m) => m.mediaSourceIdentifier == mediaSourceKey)
        .toList();
  }

  // ── search history ───────────────────────────────────────────────────

  Future<void> addToSearchHistory({
    required String historyKey,
    required String searchTerm,
  }) async {
    if (searchTerm.trim().isEmpty) return;

    final uk = '$historyKey/$searchTerm';
    final list = _searchHistoryCache.putIfAbsent(historyKey, () => []);
    list.remove(searchTerm);
    list.add(searchTerm);

    while (list.length > maximumSearchHistoryItems) {
      list.removeAt(0);
    }

    await _db.upsertSearchHistoryItem(SearchHistoryItemsCompanion.insert(
      historyKey: historyKey,
      searchTerm: searchTerm,
      uniqueKey: uk,
    ));
    await _db.trimSearchHistory(historyKey, maximumSearchHistoryItems);
  }

  Future<void> removeFromSearchHistory({
    required String historyKey,
    required String searchTerm,
  }) async {
    _searchHistoryCache[historyKey]?.remove(searchTerm);
    final uk = '$historyKey/$searchTerm';
    await _db.deleteSearchHistoryByUniqueKey(uk);
  }

  Future<void> clearSearchHistory({required String historyKey}) async {
    _searchHistoryCache.remove(historyKey);
    await _db.clearSearchHistory(historyKey);
  }

  List<String> getSearchHistory({required String historyKey}) {
    return List.unmodifiable(_searchHistoryCache[historyKey] ?? []);
  }

  bool isTermInSearchHistory({
    required String historyKey,
    required String searchTerm,
  }) {
    return _searchHistoryCache[historyKey]?.contains(searchTerm) ?? false;
  }

  // ── stash (data operations only; toast is in AppModel) ───────────────

  void addToStashData({required List<String> terms}) {
    for (final term in terms) {
      if (term.trim().isNotEmpty) {
        addToSearchHistory(historyKey: stashKey, searchTerm: term);
      }
    }
  }

  Future<void> removeFromStashData({required String term}) =>
      removeFromSearchHistory(historyKey: stashKey, searchTerm: term);

  void clearStash() => clearSearchHistory(historyKey: stashKey);

  List<String> getStash() => getSearchHistory(historyKey: stashKey);

  bool isTermInStash(String searchTerm) =>
      isTermInSearchHistory(historyKey: stashKey, searchTerm: searchTerm);
}
