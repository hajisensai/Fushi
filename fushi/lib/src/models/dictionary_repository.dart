import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import 'package:fushi/src/startup/exit_flush_registry.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/lru_cache.dart';

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
    // 退出前结算尚未进入 Drift 的 metadata 队列和 debounce 查词历史；
    // 否则 db.close 可能先于 metadata 队列里的第二笔写入。
    _exitFlush = ExitFlushRegistry.instance.register(flushPendingWritesNow);
  }

  final FushiDatabase _db;
  final VoidCallback? _onCacheRebuild;

  /// 低内存模式信号（读 pref，惰性求值：主进程构造发生在 prefs 加载之前，
  /// 只能在每次缓存写入时现查）。未接线（旧调用点/测试）时视为非低内存。
  final bool Function() _isLowMemory;
  late final ExitFlushCallback _exitFlush;

  static bool _neverLowMemory() => false;

  /// 查词缓存的估算字节上限（BUG 背景：单条 DictionarySearchResult 含
  /// popupJson 实测 54-231KB，纯条数 2000 封顶可涨到几百 MB 常驻）。条数
  /// 2000 保留作兜底；低内存模式收紧到 8MB，并在写入时随开关动态生效。
  static const int searchCacheMaxBytes = 32 << 20; // 32 MB
  static const int searchCacheMaxBytesLowMemory = 8 << 20; // 8 MB

  /// 原始引擎结果缓存（住在后台查词 isolate 里，见 `FushiDicts.lookupInBackground`）
  /// 的字节上限；由查词请求带过去，低内存开关随时生效。
  static const int ffiLookupCacheMaxBytes = 32 << 20; // 32 MB
  static const int ffiLookupCacheMaxBytesLowMemory = 8 << 20; // 8 MB
  // popupJson 已是可直接渲染的紧凑结果；单独给较小预算，避免与完整结果/raw FFI
  // 两个 32 MB LRU 叠加后放大常驻内存。8 MB 足以覆盖最近几十次常见查词。
  static const int popupSearchCacheMaxBytes = 8 << 20; // 8 MB
  static const int popupSearchCacheMaxBytesLowMemory = 2 << 20; // 2 MB

  List<Dictionary> _dictionariesCache = [];

  /// 查词热路径要的两样派生数据（被关掉的词典名、term 词典顺序）的缓存；null =
  /// 需要重算。凡是改动 [_dictionariesCache] 的地方都经 [_dictionariesChanged] 清掉它。
  ///
  /// 以前每次查词都经 [dictionaries] / [termDictionaries] 把全部词典深拷贝两三遍
  /// （那两个 getter 为了不外借已提交对象必须拷贝），只为了取名字。
  DictionaryLookupFilters? _lookupFilters;

  /// 查词结果缓存的代次：[clearDictionaryResultsCache] 每清一次 +1。
  ///
  /// 查词现在是异步的（后台 isolate）：一次查询在飞期间词典集合可能已经变了、缓存
  /// 已经清过。调用方在发起前记下代次，回来时代次没变才把结果写进缓存——否则清缓存
  /// 之后又被旧词典集合的结果写回来。
  int _resultsCacheEpoch = 0;
  Future<void> _metadataWrites = Future<void>.value();
  final List<DictionarySearchResult> _dictionaryHistoryResults = [];
  final LruCache<String, DictionarySearchResult> _dictionarySearchCache =
      LruCache<String, DictionarySearchResult>(
    2000,
    maxBytes: searchCacheMaxBytes,
    sizeOf: estimateDictionarySearchResultBytes,
  );
  final LruCache<String, DictionaryPopupCacheEntry> _popupSearchCache =
      LruCache<String, DictionaryPopupCacheEntry>(
    2000,
    maxBytes: popupSearchCacheMaxBytes,
    sizeOf: estimateDictionaryPopupCacheEntryBytes,
  );

  // ── getters ──────────────────────────────────────────────────────────

  // Dictionary is mutable. Never lend the committed objects to callers: even
  // a failed save must leave these synchronous getters at the last DB commit.
  List<Dictionary> get dictionaries => List.unmodifiable(_dictionariesCache.map(_copyDictionary));

  /// 改名投影（真名 -> 显示名，只含改过名的）。推导在
  /// [dictionaryDisplayNameOverridesOf] 单点完成。
  Map<String, String> get displayNameOverrides =>
      dictionaryDisplayNameOverridesOf(_dictionariesCache);

  List<Dictionary> get termDictionaries =>
      _dictionariesCache.where((d) => d.type == DictionaryType.term).map(_copyDictionary)
      .toList();

  List<Dictionary> get freqDictionaries => _dictionariesCache
      .where((d) => d.type == DictionaryType.frequency)
      .map(_copyDictionary)
      .toList();

  List<Dictionary> get pitchDictionaries =>
      _dictionariesCache.where((d) => d.type == DictionaryType.pitch).map(_copyDictionary)
      .toList();

  List<Dictionary> get kanjiDictionaries =>
      _dictionariesCache.where((d) => d.type == DictionaryType.kanji).map(_copyDictionary)
      .toList();

  /// 词典管理「汉字」分区：纯 kanji 词典 + 混合词典的汉字部分，按分区顺序。
  /// 成员与顺序的推导在 [kanjiSectionDictionariesOf]，引擎汉字桶用的是同一份。
  List<Dictionary> get kanjiSectionDictionaries =>
      kanjiSectionDictionariesOf(_dictionariesCache)
          .map(_copyDictionary)
          .toList();

  List<DictionarySearchResult> get dictionaryHistory =>
      List.unmodifiable(_dictionaryHistoryResults);

  /// 查词用的过滤与排序快照（不拷贝 [Dictionary] 对象，按需重算一次后复用）。
  ///
  /// 被关掉的词典与管理页「显示 / 隐藏」开关同一个判据：
  /// `isHidden(JapaneseLanguage.instance)`（与 `AppModel.hiddenDictionaryNames` 一致）。
  DictionaryLookupFilters get lookupFilters =>
      _lookupFilters ??= lookupFiltersOf(_dictionariesCache);

  /// [lookupFilters] 的推导本身：[dictionaries] 须已按管理页顺序（`order`）排好。
  /// 反馈 biLEesNqWb：按某个非激活配置的词典元数据查词（浏览器扩展所选配置）与
  /// App 自己查词共用这一份判据，不各写一套。
  static DictionaryLookupFilters lookupFiltersOf(
    List<Dictionary> dictionaries,
  ) => DictionaryLookupFilters(
    hiddenDictionaryNames: Set<String>.unmodifiable(<String>{
      for (final Dictionary d in dictionaries)
        if (d.isHidden(JapaneseLanguage.instance)) d.name,
    }),
    termDictionaryOrder: List<String>.unmodifiable(<String>[
      for (final Dictionary d in dictionaries)
        if (d.type == DictionaryType.term) d.name,
    ]),
  );

  /// `dictionary_metadata` 行 → 按管理页顺序排好的 [Dictionary] 列表（与
  /// [_applyMetadataRows] 装缓存同一套转换），供只读配置视图用。
  static List<Dictionary> dictionariesFromRows(List<DictionaryMetaRow> rows) =>
      (List<DictionaryMetaRow>.of(rows)..sort(
            (DictionaryMetaRow a, DictionaryMetaRow b) =>
                a.name.compareTo(b.name),
          ))
          .map(_rowToDictionary)
          .toList()
        ..sort((Dictionary a, Dictionary b) => a.order.compareTo(b.order));

  /// 见 [_resultsCacheEpoch]。
  int get resultsCacheEpoch => _resultsCacheEpoch;

  /// [_dictionariesCache] 的任何改动之后调用：作废由它派生的查词快照。
  void _dictionariesChanged() {
    _lookupFilters = null;
  }

  // ── loadFromDb ───────────────────────────────────────────────────────

  Future<void> loadFromDb() async {
    // 历史落库是 debounce 写穿：重载（启动 no-op / Profile 切换 TODO-1077）前
    // 先 flush pending 变更，保持「变更先于重载落库」的旧语义，防旧快照复活。
    await flushPendingWritesNow();
    _applyMetadataRows(await _db.getAllDictionaryMetadata());

    _dictionaryHistoryResults.clear();
    final histRows = await _db.getAllDictionaryHistory();
    for (final row in histRows) {
      try {
        _dictionaryHistoryResults
            .add(DictionarySearchResult.fromJson(row.resultJson));
      } catch (e, stack) {
        ErrorLogService.instance.log('DictRepo.historyLoad', e, stack);
        debugPrint('[Fushi] skipping corrupted dictionary history: $e');
      }
    }
  }

  /// 上一次从 DB 整表装载 dictionary_metadata 时读到的行（按 name 排序），供
  /// [reloadMetadataIfChangedInDb] 判断「别的进程改过没有」。null = 还没装载过。
  List<DictionaryMetaRow>? _loadedMetadataRows;

  void _applyMetadataRows(List<DictionaryMetaRow> rows) {
    final List<DictionaryMetaRow> sorted = List<DictionaryMetaRow>.of(rows)
      ..sort((DictionaryMetaRow a, DictionaryMetaRow b) =>
          a.name.compareTo(b.name));
    _loadedMetadataRows = sorted;
    _dictionariesCache = sorted.map(_rowToDictionary).toList()
      ..sort((a, b) => a.order.compareTo(b.order));
    _dictionariesChanged();
  }

  /// BUG-3662：Android app 外查词跑在独立的 `:popup` 进程里，它的词典缓存只在进程
  /// 冷启动时 [loadFromDb] 一次；主进程在「词典管理」里改顺序 / 启用 / 折叠 / 改名
  /// 只写 `dictionary_metadata` 表（不抬 `prefs_version`），常驻的热进程永远看不见，
  /// 用户只能杀掉 app 才生效。
  ///
  /// 本方法在每次热复用查词前读一遍这张小表（几十行），与上次装载的快照逐行比较
  /// （drift 行类型自带值相等），变了才换缓存并返回 true——调用方据此重载引擎、
  /// 清查词缓存。先排空本进程自己在途的元数据写，免得把自己写到一半的状态当成外部
  /// 改动读回来。
  Future<bool> reloadMetadataIfChangedInDb() async {
    Future<void> pending;
    do {
      pending = _metadataWrites;
      await pending;
    } while (!identical(pending, _metadataWrites));
    final List<DictionaryMetaRow> rows = await _db.getAllDictionaryMetadata();
    final List<DictionaryMetaRow> sorted = List<DictionaryMetaRow>.of(rows)
      ..sort((DictionaryMetaRow a, DictionaryMetaRow b) =>
          a.name.compareTo(b.name));
    if (_loadedMetadataRows != null &&
        listEquals(sorted, _loadedMetadataRows)) {
      return false;
    }
    _applyMetadataRows(sorted);
    return true;
  }

  // ── row conversion ───────────────────────────────────────────────────

  static Dictionary _rowToDictionary(DictionaryMetaRow r) {
    Map<String, String> metadata;
    List<String> hiddenLanguages;
    List<String> collapsedLanguages;
    List<String> expandedLanguages;
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
    try {
      expandedLanguages =
          List<String>.from(jsonDecode(r.expandedLanguagesJson));
    } catch (e, stack) {
      ErrorLogService.instance
          .log('_rowToDictionary.expandedLanguages', e, stack);
      expandedLanguages = [];
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
      expandedLanguages: expandedLanguages,
      languageOverride: r.languageOverride,
      displayName: r.displayName,
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
      expandedLanguagesJson: Value(jsonEncode(d.expandedLanguages)),
      languageOverride: Value(d.languageOverride),
      displayName: Value(d.displayName),
    );
  }

  // ── dictionary metadata CRUD ─────────────────────────────────────────

  /// Drain from lifecycle/exit boundaries, never from inside a metadata write.
  /// A rebuild callback may enqueue a migration, so one captured tail is not
  /// sufficient. The stable-tail check includes those follow-up commits.
  Future<void> flushPendingWritesNow() async {
    Future<void> pending;
    do {
      pending = _metadataWrites;
      await pending;
    } while (!identical(pending, _metadataWrites));
    await flushDictionaryHistoryNow();
  }

  static Dictionary _copyDictionary(Dictionary dictionary) =>
      dictionary.copyWith(metadata: Map<String, String>.of(dictionary.metadata))
        ..hiddenLanguages = List<String>.of(dictionary.hiddenLanguages)
        ..collapsedLanguages = List<String>.of(dictionary.collapsedLanguages)
        ..expandedLanguages = List<String>.of(dictionary.expandedLanguages);

  Future<void> _writeMetadata(Future<void> Function() write) {
    final Future<void> result = _metadataWrites.then((_) => write());
    // A failed operation is still returned to its caller, but must not poison
    // later writes. Rebuild callbacks may enqueue another write; never await
    // those callbacks' work from inside the current operation.
    _metadataWrites = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  void _publishDictionaries(List<Dictionary> dictionaries) {
    final Set<String> names = dictionaries.map((d) => d.name).toSet();
    _dictionariesCache = <Dictionary>[
      ..._dictionariesCache.where((d) => !names.contains(d.name)),
      ...dictionaries,
    ]..sort((a, b) => a.order.compareTo(b.order));
    _dictionariesChanged();
    try {
      _onCacheRebuild?.call();
    } finally {
      clearDictionaryResultsCache();
    }
  }

  Future<void> _commitDictionaries(List<Dictionary> dictionaries) async {
    if (dictionaries.isEmpty) return;
    await _db.transaction(() async {
      for (final Dictionary dictionary in dictionaries) {
        await _db.upsertDictionaryMeta(_dictionaryToCompanion(dictionary));
      }
    });
    _publishDictionaries(dictionaries);
  }

  Future<void> _editDictionary(
    Dictionary dictionary,
    void Function(Dictionary) edit,
  ) => _writeMetadata(() async {
    final Dictionary current = _dictionariesCache.firstWhere(
      (d) => d.name == dictionary.name,
      orElse: () => throw StateError(
        'Dictionary is no longer installed: ${dictionary.name}',
      ),
    );
    final Dictionary updated = _copyDictionary(current);
    edit(updated);
    await _commitDictionaries(<Dictionary>[updated]);
    // Existing controls may still hold their snapshot until the next rebuild.
    // Reflect a successful edit there only; failed writes never mutate it.
    dictionary
      ..order = updated.order
      ..displayName = updated.displayName
      ..languageOverride = updated.languageOverride
      ..hiddenLanguages = List<String>.of(updated.hiddenLanguages)
      ..collapsedLanguages = List<String>.of(updated.collapsedLanguages)
      ..expandedLanguages = List<String>.of(updated.expandedLanguages);
  });

  /// BUG-1492：写词典元数据 = 引擎里的词典集合变了。**引擎重载与查词缓存失效必须
  /// 同时发生**，否则新装/重导的词典虽然进了引擎，之前缓存的查询结果仍会被原样重放
  /// ——用户表现为「更新完这本词典就查不到词了，重新导入才好」（重新导入之所以「治
  /// 好」，只是因为 [DictionaryImportManager.importFromFile] 在**开头**清了一次缓存）。
  ///
  /// 缓存失效收在这里而不是留给每个调用方各自补：调用点已有 3 个（导入、
  /// hidden 切换、类型自愈迁移），少补一个就是一条静默的陈旧结果通路。
  Future<void> persistDictionary(Dictionary dictionary) {
    final Dictionary snapshot = _copyDictionary(dictionary);
    return _writeMetadata(() => _commitDictionaries(<Dictionary>[snapshot]));
  }

  /// 批量版 [persistDictionary]：一次缓存替换 + **一次**引擎重载 + 一次缓存失效。
  /// 启动期批量回填元数据用——逐本 [persistDictionary] 会让引擎连重载 N 次。
  Future<void> persistDictionaries(List<Dictionary> dictionaries) {
    final List<Dictionary> snapshots =
        dictionaries.map(_copyDictionary).toList();
    return _writeMetadata(() => _commitDictionaries(snapshots));
  }

  /// Apply startup metadata migrations to the latest committed dictionaries,
  /// rather than overwriting edits with snapshots captured before async IO.
  /// Returning null skips an already-migrated dictionary. Callbacks are
  /// synchronous and receive independent copies of the committed values.
  Future<void> updateDictionaryMetadata(
    Map<String, Dictionary? Function(Dictionary)> updates,
  ) {
    final changes = Map<String, Dictionary? Function(Dictionary)>.of(updates);
    return _writeMetadata(() async {
      final List<Dictionary> updated = <Dictionary>[];
      for (final Dictionary current in _dictionariesCache) {
        final change = changes[current.name];
        if (change == null) continue;
        final Dictionary? candidate = change(_copyDictionary(current));
        if (candidate != null) {
          if (candidate.name != current.name) {
            throw ArgumentError(
              'Metadata updates cannot rename dictionary keys',
            );
          }
          updated.add(_copyDictionary(candidate));
        }
      }
      await _commitDictionaries(updated);
    });
  }

  Future<void> updateDictionaryOrder(List<Dictionary> newDictionaries) {
    final Map<String, int> orders = {
      for (final Dictionary dictionary in newDictionaries)
        dictionary.name: dictionary.order,
    };
    return _writeMetadata(
      () => _commitDictionaries(<Dictionary>[
        for (final Dictionary current in _dictionariesCache)
          if (orders.containsKey(current.name))
            _copyDictionary(current)..order = orders[current.name]!,
      ]),
    );
  }

  /// 「汉字」分区的重排写入：[newDictionaries] 是该分区的新顺序。纯 kanji 词典写
  /// [Dictionary.order]；混合词典只写汉字部分自己的 [kDictKanjiOrderKey]，不动它在
  /// 「术语」分区的 order（见 [kDictKanjiHiddenKey] 的说明）。
  Future<void> updateKanjiSectionOrder(List<Dictionary> newDictionaries) {
    final Map<String, int> positions = <String, int>{
      for (int i = 0; i < newDictionaries.length; i++)
        newDictionaries[i].name: i,
    };
    return _writeMetadata(
      () => _commitDictionaries(<Dictionary>[
        for (final Dictionary current in _dictionariesCache)
          if (positions.containsKey(current.name))
            current.hasEmbeddedKanji
                ? _copyDictionary(current).copyWith(
                    metadata: <String, String>{
                      ...current.metadata,
                      kDictKanjiOrderKey: '${positions[current.name]!}',
                    },
                  )
                : (_copyDictionary(current)..order = positions[current.name]!),
      ]),
    );
  }

  /// 开关混合词典的汉字部分（[kDictKanjiHiddenKey]）。术语部分的开关不受影响。
  Future<void> setDictionaryKanjiPartHidden(
    Dictionary dictionary,
    bool hidden,
  ) =>
      updateDictionaryMetadata(<String, Dictionary? Function(Dictionary)>{
        dictionary.name: (Dictionary current) {
          final Map<String, String> metadata =
              Map<String, String>.of(current.metadata);
          if (hidden) {
            metadata[kDictKanjiHiddenKey] = 'true';
          } else {
            metadata.remove(kDictKanjiHiddenKey);
          }
          return current.copyWith(metadata: metadata);
        },
      });

  /// 用户手动指定这本词典的内容语言（BCP-47），null / 空串 = 恢复「自动」。
  ///
  /// 写完必须清查词结果缓存：词典语言只影响渲染（字体链 + structured content 的
  /// lang 标注），但那份 HTML 是缓存过的——不清的话用户改了语言要等缓存自然过期
  /// 才看得到变化（与 toggleDictionaryHidden 同款理由，BUG-171/BUG-177）。
  ///
  /// 词典管理页按「有效语言」分组、组内排序（[groupDictionariesByLanguage]）。
  /// 改完若换了组，这本词典在新组里排**最后**：序号取比其它所有词典都大的
  /// [dictionaryOrderTailOf]，混合词典的「汉字」分区序号一并挪到尾部。没换组
  /// （例如「自动 · ja」改成手动 `ja`）则位置不动。查词照旧查全部启用的词典，
  /// 语言只决定它在管理页里归哪组、以及渲染用的字体链。
  Future<void> setDictionaryLanguageOverride(
      Dictionary dictionary, String? language) {
    final String trimmed = language?.trim() ?? '';
    return _writeMetadata(() async {
      final Dictionary current = _dictionariesCache.firstWhere(
        (d) => d.name == dictionary.name,
        orElse: () => throw StateError(
          'Dictionary is no longer installed: ${dictionary.name}',
        ),
      );
      Dictionary updated = _copyDictionary(current)
        ..languageOverride = trimmed.isEmpty ? null : trimmed;
      if (dictionaryLanguageGroupOf(updated) !=
          dictionaryLanguageGroupOf(current)) {
        final int tail = dictionaryOrderTailOf(
          _dictionariesCache.where((d) => d.name != current.name),
        );
        updated = updated.copyWith(
          order: tail,
          metadata: updated.hasEmbeddedKanji
              ? <String, String>{
                  ...updated.metadata,
                  kDictKanjiOrderKey: '$tail',
                }
              : null,
        );
      }
      await _commitDictionaries(<Dictionary>[updated]);
      // 与 [_editDictionary] 同理：只在写入成功后把结果回填给调用方手里的快照。
      dictionary
        ..order = updated.order
        ..languageOverride = updated.languageOverride;
    });
  }

  /// 折叠三态的**唯一写入点**（BUG-2158）。两个名单在这里保持互斥。
  ///
  /// 修复前这里是个双态 toggle：只往 `collapsedLanguages` 里加/减，于是「不在名单
  /// 里」既是「展开」又是「继承」。全局 `collapse_dictionaries` 默认 true，用户对
  /// 自动展开窗口之外的词典点「展开」就等于什么都没做。老那个双态入口已**删除**
  /// 而不是与本方法并存——留着它就等于留着一条能写出「两个名单都不含」却自称
  /// 「已展开」的路径。
  Future<void> setDictionaryCollapseState(
    Dictionary dictionary,
    String languageCode,
    DictionaryCollapseState state,
  ) => _editDictionary(
    dictionary,
    (updated) => _applyCollapseState(updated, languageCode, state),
  );

  static void _applyCollapseState(
    Dictionary dictionary,
    String languageCode,
    DictionaryCollapseState state,
  ) {
    dictionary.collapsedLanguages = <String>[
      for (final String code in dictionary.collapsedLanguages)
        if (code != languageCode) code,
      if (state == DictionaryCollapseState.collapsed) languageCode,
    ];
    dictionary.expandedLanguages = <String>[
      for (final String code in dictionary.expandedLanguages)
        if (code != languageCode) code,
      if (state == DictionaryCollapseState.expanded) languageCode,
    ];
  }

  /// 改词典显示名。空 / 与真名相同 → 存 null（回到「没改过」，避免留一行等值
  /// 冗余，也让 `window.dictionaryDisplayNames` 的映射表只装真正改过的）。
  ///
  /// 只动 [Dictionary.displayName]。真名 [Dictionary.name] 是主键 + 磁盘目录名 +
  /// 引擎装载路径 + CSS/媒体/Anki token 的键，一律不动（见 `tables.dart` 的
  /// `displayName` 注释）。
  ///
  /// 仍清查词缓存：弹窗 HTML 是缓存产物，里面的词典名标题已经渲染进去了，不清
  /// 的话改完名要等缓存自然失效才看得到新名。
  Future<void> setDictionaryDisplayName(
      Dictionary dictionary, String? displayName) {
    final String trimmed = displayName?.trim() ?? '';
    return _editDictionary(dictionary, (updated) {
      updated.displayName =
          (trimmed.isEmpty || trimmed == updated.name) ? null : trimmed;
    });
  }

  /// 设置页那个一键按钮：继承 → 显式展开 → 显式折叠 → 继承。
  ///
  /// 起点是「继承」而不是「展开」，因为存量用户的每一本都是继承态；第一次点下去
  /// 得到「显式展开」，正是他们本来以为自己在做的那件事。
  Future<void> cycleDictionaryCollapseState(
      Dictionary dictionary, String languageCode) {
    const Map<DictionaryCollapseState, DictionaryCollapseState> next =
        <DictionaryCollapseState, DictionaryCollapseState>{
      DictionaryCollapseState.inherit: DictionaryCollapseState.expanded,
      DictionaryCollapseState.expanded: DictionaryCollapseState.collapsed,
      DictionaryCollapseState.collapsed: DictionaryCollapseState.inherit,
    };
    return _editDictionary(dictionary, (updated) {
      final DictionaryCollapseState state =
          next[updated.collapseStateForCode(languageCode)]!;
      _applyCollapseState(updated, languageCode, state);
    });
  }

  Future<void> toggleDictionaryHidden(
      Dictionary dictionary, String languageCode) => _editDictionary(dictionary, (updated) {
    _applyHiddenState(updated, languageCode,
        !updated.hiddenLanguages.contains(languageCode));
  });

  Future<void> setDictionaryHidden(
    Dictionary dictionary,
    String languageCode,
    bool hidden,
  ) => _editDictionary(dictionary,
      (updated) => _applyHiddenState(updated, languageCode, hidden));

  static void _applyHiddenState(
      Dictionary dictionary, String languageCode, bool hidden) {
    dictionary.hiddenLanguages = <String>[
      for (final String code in dictionary.hiddenLanguages)
        if (code != languageCode) code,
      if (hidden) languageCode,
    ];
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
      if (baseName(d.name) == newBase) return _copyDictionary(d);
    }
    return null;
  }

  /// BUG-1492：删词典元数据与 [persistDictionary] 对称——引擎必须立刻重载到「不含
  /// 这本」的集合，查词缓存必须失效。
  ///
  /// 旧实现只动内存 list + DB。**覆盖导入/在线更新**（`importFromFile` 的
  /// replaceExact / replaceOldVersion 分支）正是先删旧目录 + 删旧 meta、再把新包
  /// publish 到位，中间隔着一次整包落盘：这段窗口里引擎的 in-memory 索引还指着**已
  /// 被删除的目录**，此时任何一次查词都会拿到残缺结果并把它写进缓存。窗口本身由这里
  /// 的重载消除，窗口内被污染的缓存由收尾的 [persistDictionary] 清掉。
  Future<void> deleteDictionaryMeta(String name) => _writeMetadata(() async {
    await _db.deleteDictionaryMeta(name);
    _dictionariesCache.removeWhere((d) => d.name == name);
    _dictionariesChanged();
    _onCacheRebuild?.call();
    clearDictionaryResultsCache();
  });

  Future<void> clearDictionaryMetadata() => _writeMetadata(() async {
    await _db.clearAllDictionaryMeta();
    _dictionariesCache = <Dictionary>[];
    _dictionariesChanged();
    _onCacheRebuild?.call();
    clearDictionaryResultsCache();
  });

  /// 按当前 cache 重建 native 引擎（= 触发 `onCacheRebuild`）。
  /// 给 [deleteDictionaryDirectory] 当 `reloadEngine`：删目录前要把引擎清空以释放
  /// mmap view，删完得把剩下的词典装回去（BUG-1756）。
  void rebuildEngine() => _onCacheRebuild?.call();

  void removeDictionaryFromCache(String name) {
    _dictionariesCache.removeWhere((d) => d.name == name);
    _dictionariesChanged();
  }

  void clearDictionariesCache() {
    _dictionariesCache.clear();
    _dictionariesChanged();
  }

  // ── search cache ─────────────────────────────────────────────────────

  void clearDictionaryResultsCache() {
    _resultsCacheEpoch++;
    _dictionarySearchCache.clear();
    _popupSearchCache.clear();
    // 原始引擎结果缓存住在后台查词 isolate 里，已按引擎实例代次失效；这里对称地
    // 一并清掉，不让「清查词缓存」只清了一半。
    FushiDicts.clearBackgroundLookupCache();
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

  /// 后台查词 isolate 里原始引擎结果缓存此刻该用的字节上限（低内存开关现查）。
  int get ffiLookupCacheBudgetBytes =>
      _isLowMemory() ? ffiLookupCacheMaxBytesLowMemory : ffiLookupCacheMaxBytes;

  DictionaryPopupCacheEntry? getCachedPopupSearch(String cacheKey) =>
      _popupSearchCache[cacheKey];

  void cachePopupSearch(String cacheKey, DictionaryPopupCacheEntry result) {
    _popupSearchCache.maxBytes = _isLowMemory()
        ? popupSearchCacheMaxBytesLowMemory
        : popupSearchCacheMaxBytes;
    _popupSearchCache[cacheKey] = result;
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
  Future<void>? _historyWrite;
  int _historyGeneration = 0;

  /// 逐条序列化 memo（对象身份键，弱引用不阻回收）：历史 10 条里通常 9 条对象
  /// 与上次完全相同，flush 时只需序列化新增那条。就地变更字段（scrollPosition）
  /// 必须失效对应 memo。
  final Expando<String> _historyJsonMemo = Expando<String>('dictHistoryJson');

  /// [clearDictionaryHistory] / [dispose] 每次 +1。flush 的序列化在后台 isolate
  /// 里异步进行，回来时若期间清过历史，这份旧快照不得再写回（否则把已清的历史复活）。
  int _historyClearEpoch = 0;

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

  /// 从查词历史里移除一条（按查询串）。与 [addHistoryResult] 同一条防抖落库。
  void removeHistoryResult(String searchTerm) {
    final int before = _dictionaryHistoryResults.length;
    _dictionaryHistoryResults.removeWhere((r) => r.searchTerm == searchTerm);
    if (_dictionaryHistoryResults.length != before) {
      _schedulePersistDictionaryHistory();
    }
  }

  Future<void> clearDictionaryHistory() async {
    // 先取消 pending flush：清空之后再触发的旧快照写回会把已清历史复活。正在后台
    // 序列化、还没进 SQLite 的那份快照靠清除代次拦下（见 [_flushDictionaryHistory]）。
    _historyClearEpoch++;
    _cancelPendingHistoryPersist();
    await _db.clearDictionaryHistory();
    _dictionaryHistoryResults.clear();
  }

  /// Trailing debounce：连续查词只落库一次；[_historyPersistMaxDelay] 封顶，
  /// 防止 <300ms 间隔的连续查词把 flush 无限推迟（强杀丢整段）。
  void _schedulePersistDictionaryHistory() {
    _historyGeneration++;
    final DateTime now = DateTime.now();
    _historyDirtySince ??= now;
    _historyPersistTimer?.cancel();
    final bool capReached =
        now.difference(_historyDirtySince!) >= _historyPersistMaxDelay;
    _historyPersistTimer = Timer(
      capReached ? Duration.zero : _historyPersistDebounce,
      () => unawaited(flushDictionaryHistoryNow().catchError(
        (Object error, StackTrace stack) {
          // Keep dirty state for the next explicit flush or lookup. The timer
          // has no caller to receive a failure; lifecycle flushes still throw.
          ErrorLogService.instance.log('DictRepo.historyPersist', error, stack);
        },
      )),
    );
  }

  void _cancelPendingHistoryPersist() {
    _historyGeneration++;
    _historyPersistTimer?.cancel();
    _historyPersistTimer = null;
    _historyDirtySince = null;
  }

  /// 立即写穿 pending 的历史变更；无 pending 时 no-op。退出 flush
  /// （[ExitFlushRegistry]）与 [loadFromDb] 重载前对齐用。
  Future<void> flushDictionaryHistoryNow() async {
    while (_historyWrite != null || _historyDirtySince != null) {
      await (_historyWrite ?? _flushDictionaryHistory());
    }
  }

  Future<void> _flushDictionaryHistory() {
    // One in-flight snapshot at a time. A close must wait for it even after
    // the debounce timer fired, and failure must leave the snapshot retryable.
    _historyPersistTimer?.cancel();
    _historyPersistTimer = null;
    final int generation = _historyGeneration;
    final int clearEpoch = _historyClearEpoch;
    final List<DictionarySearchResult> snapshot =
        List<DictionarySearchResult>.of(_dictionaryHistoryResults);
    final List<String?> jsons = <String?>[
      for (final DictionarySearchResult r in snapshot) _historyJsonMemo[r],
    ];
    late final Future<void> writing;
    writing = _writeHistorySnapshot(snapshot, jsons, clearEpoch)
        .then<void>((bool written) {
          // A newer lookup, clear, or dispose supersedes this snapshot.
          if (written && _historyGeneration == generation) {
            _historyDirtySince = null;
          }
        })
        .whenComplete(() {
          if (identical(_historyWrite, writing)) _historyWrite = null;
        });
    _historyWrite = writing;
    return writing;
  }

  /// 序列化 [snapshot] 里还没有 memo 的条目并整表写入。返回是否真的写了。
  ///
  /// 序列化放在后台 isolate（[encodeDictionaryHistoryResults]）：真实词典上单条
  /// [DictionarySearchResult.toJson] 实测 0.26-1.5 MB、p50 28 ms / p90 44 ms（entries
  /// 是逐条 jsonEncode 后再整体 jsonEncode 的双层格式，持久化格式不能改），以前在
  /// UI isolate 上于查词后约 300 ms 跑一次，正好压在弹窗渲染 / 滚动上。
  Future<bool> _writeHistorySnapshot(
    List<DictionarySearchResult> snapshot,
    List<String?> jsons,
    int clearEpoch,
  ) async {
    final List<int> missing = <int>[
      for (int i = 0; i < snapshot.length; i++)
        if (jsons[i] == null) i,
    ];
    if (missing.isNotEmpty) {
      // 记下序列化时的 scrollPosition：后台序列化期间它被就地改了（已失效 memo、
      // 也已重新标脏），算出来的 JSON 照样写进这一份快照，但不能再记成 memo。
      final List<int> scrolls = <int>[
        for (final int i in missing) snapshot[i].scrollPosition,
      ];
      final List<String> encoded = await encodeDictionaryHistoryResults(<
          DictionarySearchResult>[for (final int i in missing) snapshot[i]]);
      for (int k = 0; k < missing.length; k++) {
        final DictionarySearchResult r = snapshot[missing[k]];
        jsons[missing[k]] = encoded[k];
        if (r.scrollPosition == scrolls[k]) {
          _historyJsonMemo[r] ??= encoded[k];
        }
      }
    }
    // 序列化期间清过历史 / 已 dispose：这份快照作废，不写（写了就是把已清的历史复活）。
    if (_historyClearEpoch != clearEpoch) return false;
    final List<DictionaryHistoryCompanion> items = <DictionaryHistoryCompanion>[
      for (int i = 0; i < snapshot.length; i++)
        DictionaryHistoryCompanion.insert(position: i, resultJson: jsons[i]!),
    ];
    // 从这里起与旧实现相同：本次写先入 drift 单连接 FIFO，后续 clear 的 DELETE
    // 后到后赢。
    await _db.replaceAllDictionaryHistory(items);
    return true;
  }

  /// Release in-memory caches. Replaces the inherited ChangeNotifier.dispose
  /// that AppModel.dispose still calls (HBK-AUDIT-065).
  void dispose() {
    _cancelPendingHistoryPersist();
    ExitFlushRegistry.instance.unregister(_exitFlush);
    _dictionariesCache = const [];
    _dictionariesChanged();
    _dictionaryHistoryResults.clear();
    _historyClearEpoch++;
    _resultsCacheEpoch++;
    _dictionarySearchCache.clear();
    _popupSearchCache.clear();
  }
}

// ── cache size estimation (top-level, unit-testable) ───────────────────
//
// 只服务 LruCache 的字节封顶决策，不追求精确 shallow-size：Dart String 为
// UTF-16，每字符按 2 字节计；每个对象/列表再加固定开销。宁可高估。

/// 每个 Dart 对象/列表头 + 字段引用的粗估固定开销（字节）。
const int _kObjectOverheadBytes = 64;

typedef DictionaryPopupCacheEntry = ({String popupJson, int bestLength});

/// 在一次性后台 isolate 里把 [results] 逐条 `toJson()`（查词历史落库用）。
///
/// 顶层函数：交给 `Isolate.run` 的闭包只捕获 [results]，不把仓库实例（持着数据库
/// 连接）拖过 isolate 边界。结果经 `Isolate.exit` 回传，不再拷贝。
Future<List<String>> encodeDictionaryHistoryResults(
  List<DictionarySearchResult> results,
) =>
    Isolate.run(
      () => <String>[
        for (final DictionarySearchResult r in results) r.toJson(),
      ],
      debugName: 'fushi-dict-history-json',
    );

/// 查词热路径要的词典过滤与排序快照（[DictionaryRepository.lookupFilters]）。
class DictionaryLookupFilters {
  const DictionaryLookupFilters({
    required this.hiddenDictionaryNames,
    required this.termDictionaryOrder,
  });

  /// 被用户关掉的词典名。
  final Set<String> hiddenDictionaryNames;

  /// term 词典的管理页顺序（真名）。
  final List<String> termDictionaryOrder;
}

int estimateDictionaryPopupCacheEntryBytes(DictionaryPopupCacheEntry entry) =>
    entry.popupJson.length * 2 + _kObjectOverheadBytes;

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
  for (final FushiKanjiResult kanji in result.kanjiResults) {
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
