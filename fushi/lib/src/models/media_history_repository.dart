import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/media_item.dart';

class MediaHistoryRepository extends ChangeNotifier {
  MediaHistoryRepository(
    this._db, {
    this.maximumSearchHistoryItems = 60,
    this.maximumMediaHistoryItems = 100,
    this.stashKey = 'stash',
  });

  final FushiDatabase _db;
  final int maximumSearchHistoryItems;
  final int maximumMediaHistoryItems;
  final String stashKey;

  List<MediaItem> _mediaItemsCache = [];
  final Map<String, List<String>> _searchHistoryCache = {};

  List<MediaItem> get mediaItems => List.unmodifiable(_mediaItemsCache);

  Future<void> loadFromDb() async {
    final miRows = await _db.getAllMediaOpenHistory();
    _mediaItemsCache = miRows.map(_rowToMediaItem).toList();

    _searchHistoryCache.clear();
    final shRows = await _db.getAllSearchHistoryItems();
    for (final row in shRows) {
      _searchHistoryCache
          .putIfAbsent(row.historyKey, () => [])
          .add(row.searchTerm);
    }
  }

  // ── row conversion（v80：身份/时刻/进度是列，其余走 snapshot JSON）─────

  static MediaItem _rowToMediaItem(MediaOpenHistoryRow r) {
    Map<String, dynamic> snapshot;
    try {
      snapshot = jsonDecode(r.snapshotJson) as Map<String, dynamic>;
    } catch (_) {
      snapshot = const <String, dynamic>{};
    }
    String? str(String key) =>
        snapshot[key] is String ? snapshot[key] as String : null;
    return MediaItem(
      mediaIdentifier: r.mediaId,
      title: str('title') ?? '',
      mediaTypeIdentifier: r.mediaType,
      mediaSourceIdentifier: r.mediaSource,
      position: r.position,
      duration: r.duration,
      // v80：能力位不再持久化，运行时按 source 语义推导——历史条目一律可删、
      // 不可编辑（与全部现存 source 的实际取值一致）。
      canDelete: true,
      canEdit: false,
      base64Image: str('base64Image'),
      imageUrl: str('imageUrl'),
      audioUrl: str('audioUrl'),
      author: str('author'),
      authorIdentifier: str('authorIdentifier'),
      extraUrl: str('extraUrl'),
      extra: str('extra'),
      sourceMetadata: str('sourceMetadata'),
    );
  }

  static MediaOpenHistoryCompanion _mediaItemToCompanion(MediaItem item) {
    final Map<String, Object?> snapshot = <String, Object?>{
      'title': item.title,
      if (item.base64Image != null) 'base64Image': item.base64Image,
      if (item.imageUrl != null) 'imageUrl': item.imageUrl,
      if (item.audioUrl != null) 'audioUrl': item.audioUrl,
      if (item.author != null) 'author': item.author,
      if (item.authorIdentifier != null)
        'authorIdentifier': item.authorIdentifier,
      if (item.extraUrl != null) 'extraUrl': item.extraUrl,
      if (item.extra != null) 'extra': item.extra,
      if (item.sourceMetadata != null) 'sourceMetadata': item.sourceMetadata,
    };
    return MediaOpenHistoryCompanion(
      mediaType: Value(item.mediaTypeIdentifier),
      mediaSource: Value(item.mediaSourceIdentifier),
      mediaId: Value(item.mediaIdentifier),
      openedAt: Value(DateTime.now().millisecondsSinceEpoch),
      position: Value(item.position),
      duration: Value(item.duration),
      snapshotJson: Value(jsonEncode(snapshot)),
    );
  }

  // ── media item CRUD ──────────────────────────────────────────────────

  Future<void> addMediaItem(MediaItem item) async {
    _mediaItemsCache.removeWhere((m) => m.uniqueKey == item.uniqueKey);
    _mediaItemsCache.insert(0, item);

    // v80：PK (mediaSource, mediaId) 即 uniqueKey 语义，upsert 天然覆盖旧行。
    await _db.upsertMediaOpenHistory(_mediaItemToCompanion(item));
    await _db.trimMediaHistory(
        item.mediaTypeIdentifier, maximumMediaHistoryItems);

    final rows = await _db.getAllMediaOpenHistory();
    _mediaItemsCache = rows.map(_rowToMediaItem).toList();
  }

  Future<void> updateMediaItem(MediaItem item) async {
    final idx =
        _mediaItemsCache.indexWhere((m) => m.uniqueKey == item.uniqueKey);
    if (idx >= 0) _mediaItemsCache[idx] = item;
    await _db.upsertMediaOpenHistory(_mediaItemToCompanion(item));
  }

  Future<void> removeFromReadingList(String mediaIdentifier) async {
    _mediaItemsCache.removeWhere((m) => m.mediaIdentifier == mediaIdentifier);
    await _db.deleteMediaOpenHistoryByMediaId(mediaIdentifier);
  }

  Future<void> deleteMediaItemById(MediaItem item) async {
    _mediaItemsCache.removeWhere((m) => m.uniqueKey == item.uniqueKey);
    await _db.deleteMediaOpenHistory(
        item.mediaSourceIdentifier, item.mediaIdentifier);
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
