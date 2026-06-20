import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:hibiki/src/utils/misc/lru_cache.dart';

/// Plain repository over the dictionary tables. It is intentionally NOT a
/// [ChangeNotifier]: it never called notifyListeners and nothing ever
/// subscribed to it, so the reactive base was dead theatre. AppModel pokes its
/// own ad-hoc notifiers after mutations instead (HBK-AUDIT-065).
class DictionaryRepository {
  DictionaryRepository(this._db, {VoidCallback? onCacheRebuild})
      : _onCacheRebuild = onCacheRebuild;

  final HibikiDatabase _db;
  final VoidCallback? _onCacheRebuild;

  List<Dictionary> _dictionariesCache = [];
  final List<DictionarySearchResult> _dictionaryHistoryResults = [];
  final LruCache<String, DictionarySearchResult> _dictionarySearchCache =
      LruCache<String, DictionarySearchResult>(2000);
  final LruCache<String, List<HoshiLookupResult>> _ffiLookupCache =
      LruCache<String, List<HoshiLookupResult>>(2000);

  // ── getters ──────────────────────────────────────────────────────────

  List<Dictionary> get dictionaries => List.unmodifiable(_dictionariesCache);

  List<Dictionary> get termDictionaries =>
      _dictionariesCache.where((d) => d.type == DictionaryType.term).toList();

  List<Dictionary> get freqDictionaries => _dictionariesCache
      .where((d) => d.type == DictionaryType.frequency)
      .toList();

  List<Dictionary> get pitchDictionaries =>
      _dictionariesCache.where((d) => d.type == DictionaryType.pitch).toList();

  List<Dictionary> get kanjiDictionaries =>
      _dictionariesCache.where((d) => d.type == DictionaryType.kanji).toList();

  List<DictionarySearchResult> get dictionaryHistory =>
      List.unmodifiable(_dictionaryHistoryResults);

  // ── loadFromDb ───────────────────────────────────────────────────────

  Future<void> loadFromDb() async {
    final dictRows = await _db.getAllDictionaryMetadata();
    _dictionariesCache = dictRows.map(_rowToDictionary).toList()
      ..sort((a, b) => a.order.compareTo(b.order));

    _dictionaryHistoryResults.clear();
    final histRows = await _db.getAllDictionaryHistory();
    for (final row in histRows) {
      try {
        _dictionaryHistoryResults
            .add(DictionarySearchResult.fromJson(row.resultJson));
      } catch (e, stack) {
        ErrorLogService.instance.log('DictRepo.historyLoad', e, stack);
        debugPrint('[Hibiki] skipping corrupted dictionary history: $e');
      }
    }
  }

  // ── row conversion ───────────────────────────────────────────────────

  static Dictionary _rowToDictionary(DictionaryMetaRow r) {
    Map<String, String> metadata;
    List<String> hiddenLanguages;
    List<String> collapsedLanguages;
    try {
      metadata = Map<String, String>.from(jsonDecode(r.metadataJson));
    } catch (e, stack) {
      ErrorLogService.instance.log('_rowToDictionary.metadata', e, stack);
      metadata = {};
    }
    try {
      hiddenLanguages = List<String>.from(jsonDecode(r.hiddenLanguagesJson));
    } catch (e, stack) {
      ErrorLogService.instance
          .log('_rowToDictionary.hiddenLanguages', e, stack);
      hiddenLanguages = [];
    }
    try {
      collapsedLanguages =
          List<String>.from(jsonDecode(r.collapsedLanguagesJson));
    } catch (e, stack) {
      ErrorLogService.instance
          .log('_rowToDictionary.collapsedLanguages', e, stack);
      collapsedLanguages = [];
    }
    return Dictionary(
      name: r.name,
      formatKey: r.formatKey,
      order: r.order,
      type: DictionaryType.values.firstWhere(
        (e) => e.name == r.type,
        orElse: () => DictionaryType.term,
      ),
      metadata: metadata,
      hiddenLanguages: hiddenLanguages,
      collapsedLanguages: collapsedLanguages,
    );
  }

  static DictionaryMetadataCompanion _dictionaryToCompanion(Dictionary d) {
    return DictionaryMetadataCompanion(
      name: Value(d.name),
      formatKey: Value(d.formatKey),
      order: Value(d.order),
      type: Value(d.type.name),
      metadataJson: Value(jsonEncode(d.metadata)),
      hiddenLanguagesJson: Value(jsonEncode(d.hiddenLanguages)),
      collapsedLanguagesJson: Value(jsonEncode(d.collapsedLanguages)),
    );
  }

  // ── dictionary metadata CRUD ─────────────────────────────────────────

  Future<void> persistDictionary(Dictionary dictionary) async {
    final idx = _dictionariesCache.indexWhere((d) => d.name == dictionary.name);
    if (idx >= 0) {
      _dictionariesCache[idx] = dictionary;
    } else {
      _dictionariesCache.add(dictionary);
      _dictionariesCache.sort((a, b) => a.order.compareTo(b.order));
    }
    _onCacheRebuild?.call();
    await _db.upsertDictionaryMeta(_dictionaryToCompanion(dictionary));
  }

  Future<void> updateDictionaryOrder(List<Dictionary> newDictionaries) async {
    final updatedNames = newDictionaries.map((d) => d.name).toSet();
    final others =
        _dictionariesCache.where((d) => !updatedNames.contains(d.name));
    _dictionariesCache = [...others, ...newDictionaries]
      ..sort((a, b) => a.order.compareTo(b.order));
    _onCacheRebuild?.call();
    // Reordering changes the effective merge order of search results, so any
    // previously cached lookup would replay the stale order on the next
    // (cache-hit) query. Drop the search caches here — single source of truth
    // so no caller can forget — mirroring the delete/hidden paths (BUG-355,
    // BUG-171/BUG-177). The native engine itself is already reloaded via the
    // _onCacheRebuild callback above.
    clearDictionaryResultsCache();
    for (final dictionary in newDictionaries) {
      await _db.upsertDictionaryMeta(_dictionaryToCompanion(dictionary));
    }
  }

  void toggleDictionaryCollapsed(Dictionary dictionary, String languageCode) {
    if (dictionary.collapsedLanguages.contains(languageCode)) {
      dictionary.collapsedLanguages = [...dictionary.collapsedLanguages]
        ..remove(languageCode);
    } else {
      dictionary.collapsedLanguages = [
        ...dictionary.collapsedLanguages,
        languageCode,
      ];
    }
    persistDictionary(dictionary);
  }

  void toggleDictionaryHidden(Dictionary dictionary, String languageCode) {
    if (dictionary.hiddenLanguages.contains(languageCode)) {
      dictionary.hiddenLanguages = [...dictionary.hiddenLanguages]
        ..remove(languageCode);
    } else {
      dictionary.hiddenLanguages = [
        ...dictionary.hiddenLanguages,
        languageCode,
      ];
    }
    persistDictionary(dictionary);
  }

  bool hasDictionaryNamed(String name) =>
      _dictionariesCache.any((d) => d.name == name);

  static final RegExp _dateSuffixPattern = RegExp(r'\s*\[\d{4}-\d{2}-\d{2}\]$');

  /// Strips trailing date brackets: "JMdict [2026-05-17]" → "JMdict".
  static String baseName(String name) =>
      name.replaceFirst(_dateSuffixPattern, '').trim();

  /// Finds an existing dictionary whose base name matches [newName]'s but
  /// whose full name differs (i.e. a different dated version, or one has a
  /// date suffix and the other does not).
  Dictionary? findUpdatable(String newName) {
    final String newBase = baseName(newName);
    if (newBase.isEmpty) return null;
    for (final Dictionary d in _dictionariesCache) {
      if (d.name == newName) continue;
      if (baseName(d.name) == newBase) return d;
    }
    return null;
  }

  Future<void> deleteDictionaryMeta(String name) async {
    _dictionariesCache.removeWhere((d) => d.name == name);
    await _db.deleteDictionaryMeta(name);
  }

  void removeDictionaryFromCache(String name) {
    _dictionariesCache.removeWhere((d) => d.name == name);
  }

  void clearDictionariesCache() {
    _dictionariesCache.clear();
  }

  // ── search cache ─────────────────────────────────────────────────────

  void clearDictionaryResultsCache() {
    _dictionarySearchCache.clear();
    _ffiLookupCache.clear();
  }

  DictionarySearchResult? getCachedSearch(String searchTerm) =>
      _dictionarySearchCache[searchTerm];

  void cacheSearchResult(String searchTerm, DictionarySearchResult result) {
    _dictionarySearchCache[searchTerm] = result;
  }

  List<HoshiLookupResult>? getCachedFfiLookup(String searchTerm) =>
      _ffiLookupCache[searchTerm];

  void cacheFfiLookup(String searchTerm, List<HoshiLookupResult> results) {
    _ffiLookupCache[searchTerm] = results;
  }

  // ── dictionary history ───────────────────────────────────────────────

  void addHistoryResult(DictionarySearchResult result, int maximumItems) {
    if (result.entries.isEmpty || result.searchTerm.isEmpty) return;

    _dictionaryHistoryResults
        .removeWhere((r) => r.searchTerm == result.searchTerm);
    _dictionaryHistoryResults.add(result);

    while (_dictionaryHistoryResults.length > maximumItems) {
      _dictionaryHistoryResults.removeAt(0);
    }

    _persistDictionaryHistory();
  }

  void updateDictionaryResultScrollIndex({
    required DictionarySearchResult result,
    required int newIndex,
  }) {
    result.scrollPosition = newIndex;
    _persistDictionaryHistory();
  }

  Future<void> clearDictionaryHistory() async {
    await _db.clearDictionaryHistory();
    _dictionaryHistoryResults.clear();
  }

  Future<void> _persistDictionaryHistory() async {
    final swPersist = Stopwatch()..start();
    final items = <DictionaryHistoryCompanion>[];
    for (int i = 0; i < _dictionaryHistoryResults.length; i++) {
      items.add(DictionaryHistoryCompanion.insert(
        position: i,
        resultJson: _dictionaryHistoryResults[i].toJson(),
      ));
    }
    final swSerialize = swPersist.elapsedMilliseconds;
    await _db.replaceAllDictionaryHistory(items);
    swPersist.stop();
    debugPrint(
        '[dict-perf] persistHistory: serialize=${swSerialize}ms dbWrite=${swPersist.elapsedMilliseconds - swSerialize}ms total=${swPersist.elapsedMilliseconds}ms items=${items.length}');
  }

  /// Release in-memory caches. Replaces the inherited ChangeNotifier.dispose
  /// that AppModel.dispose still calls (HBK-AUDIT-065).
  void dispose() {
    _dictionariesCache = const [];
    _dictionaryHistoryResults.clear();
    _dictionarySearchCache.clear();
    _ffiLookupCache.clear();
  }
}
