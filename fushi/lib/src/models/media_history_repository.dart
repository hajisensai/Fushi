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

  // ── row conversion（v80：身份/时刻/进度是列，其余走 snapshot JSON。
  // 编解码复用 MediaItem 的 json_serializable 生成码——key 集只在生成码一处
  // 定义，MediaItem 加字段自动跟上（review-reuse-1）。身份/进度/能力位不进
  // snapshot：写侧剥掉，读侧从列注回。）─────────────────────────────────

  /// snapshot 不承载的键（列化字段 + 运行时推导的能力位 + 废弃的自增 id）。
  static const List<String> _columnedKeys = <String>[
    'id',
    'mediaIdentifier',
    'mediaTypeIdentifier',
    'mediaSourceIdentifier',
    'position',
    'duration',
    'canDelete',
    'canEdit',
  ];

  static MediaItem _rowToMediaItem(MediaOpenHistoryRow r) {
    Map<String, dynamic> snapshot;
    try {
      snapshot = jsonDecode(r.snapshotJson) as Map<String, dynamic>;
    } catch (_) {
      snapshot = <String, dynamic>{};
    }
    final MediaItem item = MediaItem.fromJson(<String, dynamic>{
      'title': '',
      ...snapshot,
      'mediaIdentifier': r.mediaId,
      'mediaTypeIdentifier': r.mediaType,
      'mediaSourceIdentifier': r.mediaSource,
      'position': r.position,
      'duration': r.duration,
      // v80：能力位不再持久化，运行时按 source 语义推导。全部现存构造点取
      // canDelete:false / canEdit:true（历史条目可改覆盖标题、删除走
      // removeFromReadingList 语义），照实注入（review5-7：此前硬编码成了
      // 反值，会砍掉自定义标题覆盖并凭空长出删除动作）。
      'canDelete': false,
      'canEdit': true,
    });
    return item;
  }

  static MediaOpenHistoryCompanion _mediaItemToCompanion(MediaItem item) {
    final Map<String, dynamic> snapshot = item.toJson()
      ..removeWhere((String key, Object? value) =>
          value == null || _columnedKeys.contains(key));
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
