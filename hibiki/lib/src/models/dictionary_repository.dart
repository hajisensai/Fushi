import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

import 'package:hibiki/src/startup/exit_flush_registry.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:hibiki/src/utils/misc/lru_cache.dart';

/// Plain repository over the dictionary tables. It is intentionally NOT a
/// [ChangeNotifier]: it never called notifyListeners and nothing ever
/// subscribed to it, so the reactive base was dead theatre. AppModel pokes its
/// own ad-hoc notifiers after mutations instead (HBK-AUDIT-065).
class DictionaryRepository {
  DictionaryRepository(
    this._db, {
    VoidCallback? onCacheRebuild,
    bool Function()? isLowMemory,
  })  : _onCacheRebuild = onCacheRebuild,
        _isLowMemory = isLowMemory ?? _neverLowMemory {
    // 查词历史持久化改为 debounce 写穿后，进程退出前必须 flush pending 变更
    // （桌面点 X 快杀 / Android 退后台的保留式 flush 都走这条注册表）。
    _historyExitFlush =
        ExitFlushRegistry.instance.register(flushDictionaryHistoryNow);
  }

  final HibikiDatabase _db;
  final VoidCallback? _onCacheRebuild;

  /// 低内存模式信号（读 pref，惰性求值：主进程构造发生在 prefs 加载之前，
  /// 只能在每次缓存写入时现查）。未接线（旧调用点/测试）时视为非低内存。
  final bool Function() _isLowMemory;
  late final ExitFlushCallback _historyExitFlush;

  static bool _neverLowMemory() => false;

  /// 查词缓存的估算字节上限（BUG 背景：单条 DictionarySearchResult 含
  /// popupJson 实测 54-231KB，纯条数 2000 封顶可涨到几百 MB 常驻）。条数
  /// 2000 保留作兜底；低内存模式收紧到 8MB，并在写入时随开关动态生效。
  static const int searchCacheMaxBytes = 32 << 20; // 32 MB
  static const int searchCacheMaxBytesLowMemory = 8 << 20; // 8 MB
  static const int ffiLookupCacheMaxBytes = 32 << 20; // 32 MB
  static const int ffiLookupCacheMaxBytesLowMemory = 8 << 20; // 8 MB

  List<Dictionary> _dictionariesCache = [];
  final List<DictionarySearchResult> _dictionaryHistoryResults = [];
  final LruCache<String, DictionarySearchResult> _dictionarySearchCache =
      LruCache<String, DictionarySearchResult>(
    2000,
    maxBytes: searchCacheMaxBytes,
    sizeOf: estimateDictionarySearchResultBytes,
  );
  final LruCache<String, List<HoshiLookupResult>> _ffiLookupCache =
      LruCache<String, List<HoshiLookupResult>>(
    2000,
    maxBytes: ffiLookupCacheMaxBytes,
    sizeOf: estimateHoshiLookupResultsBytes,
  );

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
    // 历史落库是 debounce 写穿：重载（启动 no-op / Profile 切换 TODO-1077）前
    // 先 flush pending 变更，保持「变更先于重载落库」的旧语义，防旧快照复活。
    await flushDictionaryHistoryNow();
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
    // 低内存开关可在运行期翻转（AppModel.setLowMemoryMode），每次写入前
    // 现查并应用上限：调小会立即淘汰到预算内，翻回则恢复大上限。
    _dictionarySearchCache.maxBytes =
        _isLowMemory() ? searchCacheMaxBytesLowMemory : searchCacheMaxBytes;
    _dictionarySearchCache[searchTerm] = result;
  }

  List<HoshiLookupResult>? getCachedFfiLookup(String searchTerm) =>
      _ffiLookupCache[searchTerm];

  void cacheFfiLookup(String searchTerm, List<HoshiLookupResult> results) {
    _ffiLookupCache.maxBytes = _isLowMemory()
        ? ffiLookupCacheMaxBytesLowMemory
        : ffiLookupCacheMaxBytes;
    _ffiLookupCache[searchTerm] = results;
  }

  // ── dictionary history ───────────────────────────────────────────────

  /// 查词历史持久化的 trailing debounce 窗口与连续查词下的强制封顶。
  ///
  /// 性能背景：此前每次查词都在 UI isolate 上把**整份**历史（默认 10 条完整
  /// [DictionarySearchResult]，生产库实测单条 54-231KB、整表 ~1.36MB）同步
  /// toJson 再整表重写，序列化循环恰好卡在弹窗显示帧之前，是查词热路径上
  /// 10-100ms 的纯阻塞。现在 add 只改内存，落库走 debounce + 逐条 memo。
  static const Duration _historyPersistDebounce = Duration(milliseconds: 300);
  static const Duration _historyPersistMaxDelay = Duration(seconds: 2);

  Timer? _historyPersistTimer;
  DateTime? _historyDirtySince;

  /// 逐条序列化 memo（对象身份键，弱引用不阻回收）：历史 10 条里通常 9 条对象
  /// 与上次完全相同，flush 时只需序列化新增那条。就地变更字段（scrollPosition）
  /// 必须失效对应 memo。
  final Expando<String> _historyJsonMemo = Expando<String>('dictHistoryJson');

  void addHistoryResult(DictionarySearchResult result, int maximumItems) {
    if (result.entries.isEmpty || result.searchTerm.isEmpty) return;

    _dictionaryHistoryResults
        .removeWhere((r) => r.searchTerm == result.searchTerm);
    _dictionaryHistoryResults.add(result);

    while (_dictionaryHistoryResults.length > maximumItems) {
      _dictionaryHistoryResults.removeAt(0);
    }

    _schedulePersistDictionaryHistory();
  }

  void updateDictionaryResultScrollIndex({
    required DictionarySearchResult result,
    required int newIndex,
  }) {
    result.scrollPosition = newIndex;
    // scrollPosition 编进 resultJson，就地变更必须失效该条 memo。
    _historyJsonMemo[result] = null;
    _schedulePersistDictionaryHistory();
  }

  Future<void> clearDictionaryHistory() async {
    // 先取消 pending flush：清空之后再触发的旧快照写回会把已清历史复活。
    _cancelPendingHistoryPersist();
    await _db.clearDictionaryHistory();
    _dictionaryHistoryResults.clear();
  }

  /// Trailing debounce：连续查词只落库一次；[_historyPersistMaxDelay] 封顶，
  /// 防止 <300ms 间隔的连续查词把 flush 无限推迟（强杀丢整段）。
  void _schedulePersistDictionaryHistory() {
    final DateTime now = DateTime.now();
    _historyDirtySince ??= now;
    _historyPersistTimer?.cancel();
    final bool capReached =
        now.difference(_historyDirtySince!) >= _historyPersistMaxDelay;
    _historyPersistTimer = Timer(
      capReached ? Duration.zero : _historyPersistDebounce,
      () => unawaited(_flushDictionaryHistory()),
    );
  }

  void _cancelPendingHistoryPersist() {
    _historyPersistTimer?.cancel();
    _historyPersistTimer = null;
    _historyDirtySince = null;
  }

  /// 立即写穿 pending 的历史变更；无 pending 时 no-op。退出 flush
  /// （[ExitFlushRegistry]）与 [loadFromDb] 重载前对齐用。
  Future<void> flushDictionaryHistoryNow() async {
    if (_historyPersistTimer == null && _historyDirtySince == null) return;
    await _flushDictionaryHistory();
  }

  Future<void> _flushDictionaryHistory() async {
    _cancelPendingHistoryPersist();
    final items = <DictionaryHistoryCompanion>[];
    for (int i = 0; i < _dictionaryHistoryResults.length; i++) {
      final DictionarySearchResult r = _dictionaryHistoryResults[i];
      items.add(DictionaryHistoryCompanion.insert(
        position: i,
        resultJson: _historyJsonMemo[r] ??= r.toJson(),
      ));
    }
    // 序列化段与上面的取消/快照在同一同步区间内完成；此后 clear 等竞态由
    // drift 单连接 FIFO 保序（本次写先入队，后续 clear 的 DELETE 后到后赢）。
    await _db.replaceAllDictionaryHistory(items);
  }

  /// Release in-memory caches. Replaces the inherited ChangeNotifier.dispose
  /// that AppModel.dispose still calls (HBK-AUDIT-065).
  void dispose() {
    _cancelPendingHistoryPersist();
    ExitFlushRegistry.instance.unregister(_historyExitFlush);
    _dictionariesCache = const [];
    _dictionaryHistoryResults.clear();
    _dictionarySearchCache.clear();
    _ffiLookupCache.clear();
  }
}

// ── cache size estimation (top-level, unit-testable) ───────────────────
//
// 只服务 LruCache 的字节封顶决策，不追求精确 shallow-size：Dart String 为
// UTF-16，每字符按 2 字节计；每个对象/列表再加固定开销。宁可高估。

/// 每个 Dart 对象/列表头 + 字段引用的粗估固定开销（字节）。
const int _kObjectOverheadBytes = 64;

/// 粗估一条 [DictionarySearchResult] 的常驻字节数。大头是 [popupJson]
/// （实测 54-231KB）与各 entry 的 meaning JSON。
int estimateDictionarySearchResultBytes(DictionarySearchResult result) {
  int chars = result.searchTerm.length + (result.popupJson?.length ?? 0);
  int overhead = _kObjectOverheadBytes;
  for (final DictionaryEntry entry in result.entries) {
    chars += entry.dictionaryName.length +
        entry.word.length +
        entry.reading.length +
        entry.meaning.length +
        entry.extra.length;
    overhead += _kObjectOverheadBytes;
  }
  for (final HoshiKanjiResult kanji in result.kanjiResults) {
    chars += kanji.character.length +
        kanji.onyomi.length +
        kanji.kunyomi.length +
        kanji.radical.length +
        kanji.dictName.length;
    for (final String meaning in kanji.meanings) {
      chars += meaning.length;
    }
    overhead += _kObjectOverheadBytes;
  }
  return chars * 2 + overhead;
}

/// 粗估一次 FFI lookup 结果列表（[HoshiLookupResult]，已 marshal 成 Dart
/// 对象）的常驻字节数：把所有可得字符串长度按 UTF-16 累加 + 对象开销。
int estimateHoshiLookupResultsBytes(List<HoshiLookupResult> results) {
  int chars = 0;
  int overhead = _kObjectOverheadBytes; // 外层列表本身。
  for (final HoshiLookupResult result in results) {
    overhead += _kObjectOverheadBytes;
    chars += result.matched.length + result.deinflected.length;
    for (final HoshiTransformGroup group in result.trace) {
      overhead += _kObjectOverheadBytes;
      chars += group.name.length + group.description.length;
    }
    final HoshiTermResult term = result.term;
    chars += term.expression.length + term.reading.length + term.rules.length;
    for (final HoshiGlossaryEntry glossary in term.glossaries) {
      overhead += _kObjectOverheadBytes;
      chars += glossary.dictName.length +
          glossary.glossary.length +
          glossary.definitionTags.length +
          glossary.termTags.length;
    }
    for (final HoshiFrequencyEntry freq in term.frequencies) {
      overhead += _kObjectOverheadBytes;
      chars += freq.dictName.length;
      for (final HoshiFrequency f in freq.frequencies) {
        overhead += _kObjectOverheadBytes;
        chars += f.displayValue.length;
      }
    }
    for (final HoshiPitchEntry pitch in term.pitches) {
      overhead += _kObjectOverheadBytes + pitch.pitchPositions.length * 8;
      chars += pitch.dictName.length;
      for (final String transcription in pitch.transcriptions) {
        chars += transcription.length;
      }
    }
  }
  return chars * 2 + overhead;
}
