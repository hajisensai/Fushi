import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart'
    show RemoteLookupDictionaryConfig;

import 'package:fushi/src/startup/exit_flush_registry.dart';
import 'package:fushi/src/sync/sync_repository.dart'
    show SyncRepository, remoteDictionaryLookupHostIdsOf;
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
  }) : _onCacheRebuild = onCacheRebuild,
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

  /// 服务器托管词典（`remote_dictionary_metadata`）里**此刻参与查词**的那些：所属
  /// host 仍在配对列表里且开着「用这台服务器查词典」（[remoteDictionaryLookupHostIdsOf]）。
  /// 按 `order` 排好。没配对 / 关掉的 host 的行留在库里（重新配对时设置还在），只是
  /// 不进这里。
  List<RemoteDictionary> _remoteDictionariesCache = const <RemoteDictionary>[];

  /// [remoteDictionaries] 换了内容就 +1（重读目录 / 配置写入）。词典管理页据此重建；
  /// 静态是因为换库 / 切配置时 AppModel 会换掉仓库实例，页面监听不该跟着丢。
  static final ValueNotifier<int> remoteDictionariesRevision =
      ValueNotifier<int>(0);

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
  List<Dictionary> get dictionaries =>
      List.unmodifiable(_dictionariesCache.map(_copyDictionary));

  /// 改名投影（真名 -> 显示名，只含改过名的）。推导在
  /// [dictionaryDisplayNameOverridesOf] 单点完成。
  Map<String, String> get displayNameOverrides =>
      dictionaryDisplayNameOverridesOf(_dictionariesCache);

  List<Dictionary> get termDictionaries => _dictionariesCache
      .where((d) => d.type == DictionaryType.term)
      .map(_copyDictionary)
      .toList();

  List<Dictionary> get freqDictionaries => _dictionariesCache
      .where((d) => d.type == DictionaryType.frequency)
      .map(_copyDictionary)
      .toList();

  List<Dictionary> get pitchDictionaries => _dictionariesCache
      .where((d) => d.type == DictionaryType.pitch)
      .map(_copyDictionary)
      .toList();

  List<Dictionary> get kanjiDictionaries => _dictionariesCache
      .where((d) => d.type == DictionaryType.kanji)
      .map(_copyDictionary)
      .toList();

  /// 词典管理「汉字」分区：纯 kanji 词典 + 混合词典的汉字部分，按分区顺序。
  /// 成员与顺序的推导在 [kanjiSectionDictionariesOf]，引擎汉字桶用的是同一份。
  List<Dictionary> get kanjiSectionDictionaries => kanjiSectionDictionariesOf(
    _dictionariesCache,
  ).map(_copyDictionary).toList();

  List<DictionarySearchResult> get dictionaryHistory =>
      List.unmodifiable(_dictionaryHistoryResults);

  /// 本进程词典引擎此刻（最近一次排期装载）术语桶里的词典真名，由 `AppModel` 在
  /// 分桶（`bucketDictPaths`）之后登记（[noteEngineTermDictionaries]）。
  ///
  /// 「本机装着且开着」不等于「本机引擎里有」：引擎只装**激活配置**开着、且目录存在
  /// 并已物化的词典。按非激活配置查词（工作配置的查词视图）、目录缺失 / 未物化时，
  /// 元数据上开着的词典本机根本查不出来——本机与服务器结果合并去重必须以这份为准，
  /// 否则服务器那份被当成「本机已有」丢掉，词典整本从弹窗里消失。
  Set<String> get engineTermDictionaryNames => _engineTermDictionaryNames;
  Set<String> _engineTermDictionaryNames = const <String>{};

  /// 登记引擎术语桶的成员（见 [engineTermDictionaryNames]）。
  void noteEngineTermDictionaries(Iterable<String> names) {
    _engineTermDictionaryNames = Set<String>.unmodifiable(names);
  }

  /// 参与查词的服务器托管词典（见 [_remoteDictionariesCache]），按管理页顺序。
  /// [RemoteDictionary] 不可变，直接外借。
  List<RemoteDictionary> get remoteDictionaries =>
      List<RemoteDictionary>.unmodifiable(_remoteDictionariesCache);

  /// 本端生效配置（App 激活配置）对 [hostId] 这台 host 的词典选择，随远端查词请求发出
  /// （`dictionaries` 字段）。推导在 [remoteLookupConfigFor]；null = 没有可说的。
  RemoteLookupDictionaryConfig? filtersForHost(String hostId) =>
      remoteLookupConfigFor(
        dictionaries: _dictionariesCache,
        remoteDictionaries: _remoteDictionariesCache,
        hostId: hostId,
      );

  /// 查词用的过滤与排序快照（不拷贝 [Dictionary] 对象，按需重算一次后复用）。
  ///
  /// 被关掉的词典与管理页「显示 / 隐藏」开关同一个判据：
  /// `isHidden(JapaneseLanguage.instance)`（与 `AppModel.hiddenDictionaryNames` 一致）。
  DictionaryLookupFilters get lookupFilters => _lookupFilters ??=
      lookupFiltersOf(_dictionariesCache, _remoteDictionariesCache);

  /// [lookupFilters] 的推导本身：[dictionaries] 须已按管理页顺序（`order`）排好。
  /// 反馈 biLEesNqWb：按某个非激活配置的词典元数据查词（浏览器扩展所选配置）与
  /// App 自己查词共用这一份判据，不各写一套。
  ///
  /// [remoteDictionaries]：参与查词的服务器托管词典。与本机词典按 `order` 混排进
  /// [DictionaryLookupFilters.termDictionaryOrder]，关掉的进隐藏名单——管理页的一条
  /// 混排列表就是这一份顺序。与本机词典同名的服务器词典被本机那本**遮住**（本机行的
  /// 顺序 / 开关说了算，见 [_unshadowedRemote]）。
  /// [DictionaryLookupFilters.hasChineseTermDictionary] 只看本机词典：它决定本机引擎
  /// 这次查词要不要多产简繁变体，服务器词典不在本机引擎里。
  static DictionaryLookupFilters lookupFiltersOf(
    List<Dictionary> dictionaries, [
    List<RemoteDictionary> remoteDictionaries = const <RemoteDictionary>[],
  ]) {
    final List<RemoteDictionary> remote = _unshadowedRemote(
      dictionaries,
      remoteDictionaries,
    );
    return DictionaryLookupFilters(
      hiddenDictionaryNames: Set<String>.unmodifiable(<String>{
        for (final Dictionary d in dictionaries)
          if (d.isHidden(JapaneseLanguage.instance)) d.name,
        for (final RemoteDictionary r in remote)
          if (r.hidden) r.name,
      }),
      kanjiDictionaryNames: Set<String>.unmodifiable(<String>{
        for (final Dictionary d in dictionaries)
          if (d.type == DictionaryType.kanji) d.name,
      }),
      termDictionaryOrder: List<String>.unmodifiable(
        _mixedTermOrder(dictionaries, remote),
      ),
      hasChineseTermDictionary: dictionaries.any(
        (Dictionary d) =>
            d.type == DictionaryType.term &&
            !d.isHidden(JapaneseLanguage.instance) &&
            isChineseLanguageTag(d.effectiveSourceLanguage),
      ),
    );
  }

  /// 本端配置对 [hostId] 这台 host 的词典选择（远端查词请求的 `dictionaries` 字段）：
  /// * `order` = 本机词典 + 这台 host 的服务器词典按 `order` 混排的 term 顺序；
  /// * `excluded` = 两边被关掉的（本机按管理页开关，服务器词典按 [RemoteDictionary.hidden]）。
  ///
  /// 本机词典也进名单：host 上常有同名的同一本词典（设备推上去的），本机配置对它的
  /// 顺序 / 开关照样作数，目录还没刷新过时也是。host 没有的名字由 host 忽略。与本机
  /// 同名的服务器行被遮住（本机行说了算）。两个名单都空时返回 null = 不发这个字段，
  /// host 按它自己的默认（含管理员关掉的词典）——本端对这台 host 一无所知时不该替它
  /// 把默认关掉的词典打开。
  static RemoteLookupDictionaryConfig? remoteLookupConfigFor({
    required List<Dictionary> dictionaries,
    required List<RemoteDictionary> remoteDictionaries,
    required String hostId,
  }) {
    final List<RemoteDictionary> hostRows = _unshadowedRemote(dictionaries, <
      RemoteDictionary
    >[
      for (final RemoteDictionary r in remoteDictionaries)
        if (r.hostId == hostId) r,
    ]);
    final Set<String> excluded = <String>{
      for (final Dictionary d in dictionaries)
        if (d.isHidden(JapaneseLanguage.instance)) d.name,
      for (final RemoteDictionary r in hostRows)
        if (r.hidden) r.name,
    };
    final List<String> order = _mixedTermOrder(dictionaries, hostRows);
    if (excluded.isEmpty && order.isEmpty) return null;
    return RemoteLookupDictionaryConfig(
      excluded: Set<String>.unmodifiable(excluded),
      order: List<String>.unmodifiable(order),
    );
  }

  /// [remote] 去掉与本机词典同名的行（本机那本遮住它），多台 host 同名时只留排得最前
  /// 的一行（混排名单里一个名字只出现一次）。
  static List<RemoteDictionary> _unshadowedRemote(
    List<Dictionary> dictionaries,
    List<RemoteDictionary> remote,
  ) {
    final Set<String> seen = <String>{
      for (final Dictionary d in dictionaries) d.name,
    };
    final List<RemoteDictionary> sorted = List<RemoteDictionary>.of(remote)
      ..sort(RemoteDictionary.compareByOrder);
    return <RemoteDictionary>[
      for (final RemoteDictionary r in sorted)
        if (seen.add(r.name)) r,
    ];
  }

  /// 本机 term 词典与服务器 term 词典按 `order` 混排后的真名顺序。两边序号相同时本机
  /// 在前（稳定）。两张表在同一数轴上，任何改分区顺序的写入都经
  /// [_renumberSection] 把整个混排分区一起重编号，写过之后不会撞号；撞号只出现在
  /// 还没被这样写过的数据上（服务器词典刚刷新进来时 host 给的初始序号、旧版本只给
  /// 本机词典重编号留下的序号等）——本机在前与管理页 `mixDictionaryManagerRows` 的
  /// 归并规则一致，列表顺序仍是查词顺序。
  ///
  /// 被本机同名词典遮住的服务器行不参与重编号（[serverOnlySectionRows]），它们的
  /// `order` 会过时。这不会漏进查词序：遮住期间它们不进这份名单（[_unshadowedRemote]）；
  /// 遮住它的本机那本一删，[releaseCatalogRowsOf] 先把本机行的 `order` 与开关交给
  /// 各 host 上同名的目录行，服务器行在同一个位置接手，过时的序号从不重新露面——
  /// 否则拖过「两者」行、再删本机那份，服务器行会带着旧序号冒出来并与别的行撞号。
  static List<String> _mixedTermOrder(
    List<Dictionary> dictionaries,
    List<RemoteDictionary> remote,
  ) {
    final List<({int order, int source, int index, String name})> entries =
        <({int order, int source, int index, String name})>[
          for (int i = 0; i < dictionaries.length; i++)
            if (dictionaries[i].type == DictionaryType.term)
              (
                order: dictionaries[i].order,
                source: 0,
                index: i,
                name: dictionaries[i].name,
              ),
          for (int i = 0; i < remote.length; i++)
            if (remote[i].type == DictionaryType.term)
              (order: remote[i].order, source: 1, index: i, name: remote[i].name),
        ]..sort((a, b) {
          final int byOrder = a.order.compareTo(b.order);
          if (byOrder != 0) return byOrder;
          final int bySource = a.source.compareTo(b.source);
          return bySource != 0 ? bySource : a.index.compareTo(b.index);
        });
    final Set<String> seen = <String>{};
    return <String>[
      for (final e in entries)
        if (seen.add(e.name)) e.name,
    ];
  }

  /// 一个分区里单独成行的服务器词典（按管理页顺序）：类型是 [type]、不与**任何**本机
  /// 词典同名（本机那本遮住它）、多台 host 同名只留排得最前的一行。词典管理页的混排
  /// 列表（`mixDictionaryManagerRows`）与分区重编号（[_renumberSection]）共用这一份
  /// 成员规则——列表上画出来的行就是重编号写回的行。
  static List<RemoteDictionary> serverOnlySectionRows({
    required Iterable<Dictionary> allLocal,
    required List<RemoteDictionary> remote,
    required DictionaryType type,
  }) {
    final Set<String> localNames = <String>{
      for (final Dictionary d in allLocal) d.name,
    };
    final List<RemoteDictionary> sorted = List<RemoteDictionary>.of(remote)
      ..sort(RemoteDictionary.compareByOrder);
    final Set<String> seen = <String>{};
    return <RemoteDictionary>[
      for (final RemoteDictionary r in sorted)
        if (r.type == type && !localNames.contains(r.name) && seen.add(r.name))
          r,
    ];
  }

  /// 本机即将新建一本名为 [name] 的词典时它接管的服务器词典目录行：参与查词的 host
  /// 上同名、排得最前的那一行——管理页此前画的正是这一行。没有返回 null。
  RemoteDictionary? catalogRowTakenOverBy(String name) {
    for (final RemoteDictionary r in _remoteDictionariesCache) {
      if (r.name == name) return r;
    }
    return null;
  }

  /// 导入（文件 / 目录）新落库的词典 [name] 在混排分区里的位置与开关：
  /// * 替换旧本（重导 / 在线更新，[preservedSettings] 非空）：继承旧本的 `order` /
  ///   `hiddenLanguages`；
  /// * 全新的一本、但参与查词的 host 上有同名目录行（[catalogRowTakenOverBy]）：本机
  ///   这份原地接替那一行的 `order` 与开关——它一落库就遮住那一行，管理页上同一个
  ///   位置从「服务器」变成「两者」，查词顺序不变，而不是掉到分区末尾；
  /// * 否则排在两表最大值之后（[nextDictionaryOrder]）。
  ///
  /// 「下载到本机」走同步包导入，规则相同，见 [adoptCatalogPlacement]。
  ({int order, List<String> hiddenLanguages}) placementForImport(
    String name, {
    Dictionary? preservedSettings,
  }) {
    if (preservedSettings != null) {
      return (
        order: preservedSettings.order,
        hiddenLanguages: preservedSettings.hiddenLanguages,
      );
    }
    final RemoteDictionary? catalogRow = catalogRowTakenOverBy(name);
    if (catalogRow != null) {
      return (
        order: catalogRow.order,
        hiddenLanguages: catalogRow.hidden
            ? <String>[JapaneseLanguage.instance.languageCode]
            : const <String>[],
      );
    }
    return (order: nextDictionaryOrder, hiddenLanguages: const <String>[]);
  }

  /// 「下载到本机」刚把 [hostId] 上的 [name] 装进本机之后：本机这一行接替那条目录行
  /// 的 `order` 与开关（同 [placementForImport] 对文件导入的规则）。
  ///
  /// 下载走的是同步包导入（`SyncAssetPackageService.importDictionaryPackage`），包里
  /// 的 `order` / `hiddenLanguagesJson` 是 **host 自己**词典表里的值——另一条数轴、
  /// 另一个配置，照搬会让这本词典跳到管理页的随机位置。这里按本机目录行改写这两列
  /// （折叠 / 语言覆盖照原样写回），没有目录行（还没刷新过）就不动。返回是否改了。
  static Future<bool> adoptCatalogPlacement(
    FushiDatabase db, {
    required String hostId,
    required String name,
  }) async {
    RemoteDictionaryMetaRow? catalogRow;
    for (final RemoteDictionaryMetaRow r
        in await db.getAllRemoteDictionaryMetadata()) {
      if (r.hostId == hostId && r.name == name) catalogRow = r;
    }
    if (catalogRow == null) return false;
    DictionaryMetaRow? local;
    for (final DictionaryMetaRow r in await db.getAllDictionaryMetadata()) {
      if (r.name == name) local = r;
    }
    if (local == null) return false;
    final String code = JapaneseLanguage.instance.languageCode;
    final List<String> hidden = <String>[
      for (final String c in _decodeLanguageList(local.hiddenLanguagesJson))
        if (c != code) c,
      if (catalogRow.hidden) code,
    ];
    return await db.applyDictionaryMetaProfileColumns(
          name: name,
          order: catalogRow.order,
          hiddenLanguagesJson: jsonEncode(hidden),
          collapsedLanguagesJson: local.collapsedLanguagesJson,
          expandedLanguagesJson: local.expandedLanguagesJson,
          languageOverride: local.languageOverride,
        ) >
        0;
  }

  static List<String> _decodeLanguageList(String json) {
    try {
      final Object? decoded = jsonDecode(json);
      if (decoded is List) {
        return <String>[for (final Object? e in decoded) '$e'];
      }
    } on FormatException {
      // 坏 JSON 当空表：与 [_rowToDictionary] 读同一列时的容错一致。
    }
    return const <String>[];
  }

  /// 本机与服务器两张表里最大的 `order` + 1（两表都空为 1）：新导入的本机词典排在
  /// 混排分区最后，不会插到已有的服务器词典前面。
  int get nextDictionaryOrder {
    int? maxOrder;
    for (final Dictionary d in _dictionariesCache) {
      if (maxOrder == null || d.order > maxOrder) maxOrder = d.order;
    }
    for (final RemoteDictionary r in _remoteDictionariesCache) {
      if (maxOrder == null || r.order > maxOrder) maxOrder = r.order;
    }
    return maxOrder == null ? 1 : maxOrder + 1;
  }

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
    _applyRemoteRows(await _readRemoteSnapshot());

    _dictionaryHistoryResults.clear();
    final histRows = await _db.getAllDictionaryHistory();
    for (final row in histRows) {
      try {
        _dictionaryHistoryResults.add(
          DictionarySearchResult.fromJson(row.resultJson),
        );
      } catch (e, stack) {
        ErrorLogService.instance.log('DictRepo.historyLoad', e, stack);
        debugPrint('[Fushi] skipping corrupted dictionary history: $e');
      }
    }
  }

  /// 上一次从 DB 整表装载 dictionary_metadata 时读到的行（按 name 排序），供
  /// [reloadMetadataIfChangedInDb] 判断「别的进程改过没有」。null = 还没装载过。
  List<DictionaryMetaRow>? _loadedMetadataRows;

  /// 上一次装载服务器词典时的输入（全部目录行 + 参与查词的 host），同上用于判变。
  _RemoteSnapshot? _loadedRemoteSnapshot;

  /// 此刻参与远端词典查词的 host（[remoteDictionaryLookupHostIdsOf] 口径：配对列表里
  /// 已启用且开着「用这台服务器查词典」）。随服务器词典一起装载 / 重读——主进程跟随
  /// 配对列表广播（RemoteDictionaryCatalogService），弹窗进程在
  /// [reloadMetadataIfChangedInDb] 里对账。远端查词的总闸
  /// （`AppModel.remoteLookupEnabled`）就从这里派生，没有单独的全局开关。
  Set<String> get remoteLookupHostIds =>
      _loadedRemoteSnapshot?.hosts ?? const <String>{};

  /// 读服务器词典目录行与此刻参与查词的 host（配对列表是同一个库里的偏好，见
  /// [remoteDictionaryLookupHostIdsOf]）。
  Future<_RemoteSnapshot> _readRemoteSnapshot() async {
    final List<RemoteDictionaryMetaRow> rows = List<RemoteDictionaryMetaRow>.of(
      await _db.getAllRemoteDictionaryMetadata(),
    )..sort(_compareRemoteRows);
    final Set<String> hosts = remoteDictionaryLookupHostIdsOf(
      await SyncRepository(_db).getFushiClientUrls(),
    );
    return (rows: rows, hosts: hosts);
  }

  static int _compareRemoteRows(
    RemoteDictionaryMetaRow a,
    RemoteDictionaryMetaRow b,
  ) {
    final int byHost = a.hostId.compareTo(b.hostId);
    return byHost != 0 ? byHost : a.name.compareTo(b.name);
  }

  void _applyRemoteRows(_RemoteSnapshot snapshot) {
    _loadedRemoteSnapshot = snapshot;
    _remoteDictionariesCache = List<RemoteDictionary>.unmodifiable(
      remoteDictionariesFromRows(snapshot.rows, snapshot.hosts),
    );
    _dictionariesChanged();
    remoteDictionariesRevision.value++;
  }

  /// 目录行 → 参与查词的 [RemoteDictionary]（只留 [activeHostIds] 里的 host），按
  /// 管理页顺序排好。[ProfileRepository.loadSettingsView] 与本仓库共用这一份转换。
  static List<RemoteDictionary> remoteDictionariesFromRows(
    List<RemoteDictionaryMetaRow> rows,
    Set<String> activeHostIds,
  ) => <RemoteDictionary>[
    for (final RemoteDictionaryMetaRow r in rows)
      if (activeHostIds.contains(r.hostId)) RemoteDictionary.fromRow(r),
  ]..sort(RemoteDictionary.compareByOrder);

  /// 重读服务器词典目录与配对列表（目录刷新落库后、配对 / 「用它查词典」开关变化后
  /// 调）。排在元数据写入队列里，不会读到自己写到一半的状态。服务器词典不在本机
  /// 引擎里，不重载引擎、不清查词缓存。
  Future<void> reloadRemoteDictionaries() =>
      _writeMetadata(() async => _applyRemoteRows(await _readRemoteSnapshot()));

  void _applyMetadataRows(List<DictionaryMetaRow> rows) {
    final List<DictionaryMetaRow> sorted = List<DictionaryMetaRow>.of(rows)
      ..sort(
        (DictionaryMetaRow a, DictionaryMetaRow b) => a.name.compareTo(b.name),
      );
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
      ..sort(
        (DictionaryMetaRow a, DictionaryMetaRow b) => a.name.compareTo(b.name),
      );
    // 服务器词典的目录 / 配置列在主进程改了同样要跟上（它们只进过滤、不进本机引擎，
    // 不影响返回值——返回值的语义是「本机引擎的词典集合变了」）。
    final _RemoteSnapshot remote = await _readRemoteSnapshot();
    final _RemoteSnapshot? loadedRemote = _loadedRemoteSnapshot;
    if (loadedRemote == null ||
        !listEquals(remote.rows, loadedRemote.rows) ||
        !setEquals(remote.hosts, loadedRemote.hosts)) {
      _applyRemoteRows(remote);
    }
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
      ErrorLogService.instance.log(
        '_rowToDictionary.hiddenLanguages',
        e,
        stack,
      );
      hiddenLanguages = [];
    }
    try {
      collapsedLanguages = List<String>.from(
        jsonDecode(r.collapsedLanguagesJson),
      );
    } catch (e, stack) {
      ErrorLogService.instance.log(
        '_rowToDictionary.collapsedLanguages',
        e,
        stack,
      );
      collapsedLanguages = [];
    }
    try {
      expandedLanguages = List<String>.from(
        jsonDecode(r.expandedLanguagesJson),
      );
    } catch (e, stack) {
      ErrorLogService.instance.log(
        '_rowToDictionary.expandedLanguages',
        e,
        stack,
      );
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

  /// 元数据的唯一提交点：本机词典整行 upsert、服务器词典只写配置拥有的两列
  /// （[remote]），**同一个事务**——管理页一次混排重编号要么两张表一起落，要么都不落。
  /// 服务器词典不在本机引擎里：只有本机词典变了才重载引擎、清查词缓存。
  Future<void> _commitDictionaries(
    List<Dictionary> dictionaries, {
    List<RemoteDictionary> remote = const <RemoteDictionary>[],
  }) async {
    if (dictionaries.isEmpty && remote.isEmpty) return;
    await _db.transaction(() async {
      for (final Dictionary dictionary in dictionaries) {
        await _db.upsertDictionaryMeta(_dictionaryToCompanion(dictionary));
      }
      for (final RemoteDictionary r in remote) {
        final int updated = await _db.setRemoteDictionaryProfileColumns(
          hostId: r.hostId,
          name: r.name,
          order: r.order,
          hidden: r.hidden,
        );
        if (updated == 0) {
          throw StateError(
            'Server dictionary is no longer in the catalog: '
            '${r.hostId}/${r.name}',
          );
        }
      }
    });
    if (remote.isNotEmpty) _publishRemoteDictionaries(remote);
    if (dictionaries.isNotEmpty) _publishDictionaries(dictionaries);
  }

  void _publishRemoteDictionaries(List<RemoteDictionary> updated) {
    final Map<String, RemoteDictionary> byKey = <String, RemoteDictionary>{
      for (final RemoteDictionary r in updated) r.key: r,
    };
    _remoteDictionariesCache = List<RemoteDictionary>.unmodifiable(
      <RemoteDictionary>[
        for (final RemoteDictionary r in _remoteDictionariesCache)
          byKey[r.key] ?? r,
      ]..sort(RemoteDictionary.compareByOrder),
    );
    _dictionariesChanged();
    remoteDictionariesRevision.value++;
  }

  /// [candidate] 在缓存里的那一行（按 host + 真名）；不在（host 已不参与查词 / 行被
  /// 忘掉）抛 [StateError]，与本机词典「已卸载」同口径。
  RemoteDictionary _cachedRemote(RemoteDictionary candidate) =>
      _remoteDictionariesCache.firstWhere(
        (RemoteDictionary r) => r.key == candidate.key,
        orElse: () => throw StateError(
          'Server dictionary is not available: '
          '${candidate.hostId}/${candidate.name}',
        ),
      );

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
    final List<Dictionary> snapshots = dictionaries
        .map(_copyDictionary)
        .toList();
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

  /// 管理页重排的写入：[newDictionaries] 带着新的 [Dictionary.order]；
  /// [remoteDictionaries] 是同一次混排里服务器词典的新 [RemoteDictionary.order]（与本机
  /// 词典同一数轴）。两张表在 [_commitDictionaries] 的同一个事务里落库。
  Future<void> updateDictionaryOrder(
    List<Dictionary> newDictionaries, {
    List<RemoteDictionary> remoteDictionaries = const <RemoteDictionary>[],
  }) {
    final Map<String, int> orders = {
      for (final Dictionary dictionary in newDictionaries)
        dictionary.name: dictionary.order,
    };
    final List<RemoteDictionary> remote = List<RemoteDictionary>.of(
      remoteDictionaries,
    );
    return _writeMetadata(
      () => _commitDictionaries(
        <Dictionary>[
          for (final Dictionary current in _dictionariesCache)
            if (orders.containsKey(current.name))
              _copyDictionary(current)..order = orders[current.name]!,
        ],
        remote: <RemoteDictionary>[
          for (final RemoteDictionary r in remote)
            _cachedRemote(r).copyWith(order: r.order),
        ],
      ),
    );
  }

  /// 一个分区（术语 / 频率 / 音调；「汉字」分区见 [updateKanjiSectionOrder]）里本机
  /// 词典的新相对顺序 [newLocalOrder]，由仓库连同这个分区里的服务器词典一起重编号
  /// （[_renumberSection]），两张表同一事务落库。只取 [newLocalOrder] 的真名与先后，
  /// 词典的其它字段一律以缓存为准（调用方手里可能是旧快照）。
  ///
  /// [moved]：这次是把这一本挪了位置（ctl `position` / 单本移动）。给了它，挪动的
  /// 就只算这一本：服务器词典守在没动的本机词典旁边，不会被它带走。
  Future<void> reorderDictionarySection(
    List<Dictionary> newLocalOrder, {
    String? moved,
  }) {
    if (newLocalOrder.isEmpty) return Future<void>.value();
    final DictionaryType type = newLocalOrder.first.type;
    if (newLocalOrder.any((Dictionary d) => d.type != type)) {
      throw ArgumentError.value(
        newLocalOrder.map((Dictionary d) => d.name).toList(),
        'newLocalOrder',
        'must all be of one section type ($type)',
      );
    }
    final List<String> names = <String>[
      for (final Dictionary d in newLocalOrder) d.name,
    ];
    return _writeMetadata(() async {
      final _SectionWrites writes = _renumberSection(
        type,
        names,
        moved: moved,
      );
      await _commitDictionaries(writes.locals, remote: writes.remotes);
    });
  }

  /// 分区重编号的**唯一推导**：本机词典与服务器词典共用一条 `order` 数轴
  /// （[_mixedTermOrder]），只给本机词典重编号会让服务器词典在查词序里漂移
  /// （例：A0 B1 R2 C3 D4 里 A 改语言后本机重编成 B0 C1 D2 A3、R 还是 2，R 就从 C
  /// 之前跑到了 D 之后）。所以任何改分区顺序的写入（管理页 / ctl 重排、改语言换组）
  /// 都从这里出写入清单：
  ///
  /// 1. 现有混排分区 = 本机 [type] 词典 + [serverOnlySectionRows]，按 `order` 归并、
  ///    同序号本机在前（与管理页列表、[_mixedTermOrder] 同一规则）；
  /// 2. [newLocalOrder] 点名的本机词典按给定先后排；**没点名的行**（服务器词典、
  ///    没点名的本机词典）守在原来紧跟其后的那本点名词典之前（排在最后一本点名
  ///    词典之后的守在它之后）；[moved] 那本真的换了邻居时它不当锚点，落在新顺序里
  ///    它的前一本正后方（排第一则在分区最前）；
  /// 3. 整个混排分区按语言组首尾相接规范化（[concatenateLanguageGroupsOf]，与管理页
  ///    分组同一规则），按下标 0..n-1 重编号。
  ///
  /// 分区里没有服务器词典时结果与改造前逐字相同（= [newLocalOrder] 的规范顺序）。
  /// [replacing]：用它代替缓存里同名那本（改语言：分组按改完的语言算）。
  /// 只返回序号真的变了的行；「汉字」分区不混服务器词典（混合词典的汉字部分在那里
  /// 有独立序号），[type] 为 kanji 时只有本机词典。
  _SectionWrites _renumberSection(
    DictionaryType type,
    List<String> newLocalOrder, {
    String? moved,
    Dictionary? replacing,
  }) {
    final List<Dictionary> localSection = <Dictionary>[
      for (final Dictionary d in _dictionariesCache)
        if (d.type == type) d.name == replacing?.name ? replacing! : d,
    ];
    final Map<String, Dictionary> byName = <String, Dictionary>{
      for (final Dictionary d in localSection) d.name: d,
    };
    final Set<String> named = <String>{};
    final List<Dictionary> order = <Dictionary>[
      for (final String name in newLocalOrder)
        if (byName.containsKey(name) && named.add(name)) byName[name]!,
    ];
    if (order.isEmpty) {
      return (locals: const <Dictionary>[], remotes: const <RemoteDictionary>[]);
    }
    final List<RemoteDictionary> serverRows = type == DictionaryType.kanji
        ? const <RemoteDictionary>[]
        : serverOnlySectionRows(
            allLocal: _dictionariesCache,
            remote: _remoteDictionariesCache,
            type: type,
          );

    // 1. 现有混排分区（两边都已按 order 排好，同序号本机在前）。
    final List<_SectionRow> current = <_SectionRow>[];
    int i = 0;
    int j = 0;
    while (i < localSection.length || j < serverRows.length) {
      final bool takeLocal =
          j >= serverRows.length ||
          (i < localSection.length &&
              localSection[i].order <= serverRows[j].order);
      current.add(
        takeLocal
            ? _SectionRow.local(localSection[i++])
            : _SectionRow.remote(serverRows[j++]),
      );
    }

    // 2. [moved] 只在它真的换了邻居（点名词典之间的前后）时才不当锚点：没挪动的
    // 写回（ctl 位置不变只做规范化）不该把旁边的服务器词典挤开。只点名一本时它就是
    // 唯一的锚点。
    final List<String> namedBefore = <String>[
      for (final _SectionRow r in current)
        if (r.local != null && named.contains(r.local!.name)) r.local!.name,
    ];
    final List<String> namedAfter = <String>[
      for (final Dictionary d in order) d.name,
    ];
    String? at(List<String> list, int k) =>
        k >= 0 && k < list.length ? list[k] : null;
    String? relocated;
    if (moved != null && namedAfter.length > 1) {
      final int from = namedBefore.indexOf(moved);
      final int to = namedAfter.indexOf(moved);
      if (from >= 0 &&
          to >= 0 &&
          (at(namedBefore, from - 1) != at(namedAfter, to - 1) ||
              at(namedBefore, from + 1) != at(namedAfter, to + 1))) {
        relocated = moved;
      }
    }
    final Map<String, List<_SectionRow>> leading =
        <String, List<_SectionRow>>{};
    List<_SectionRow> pending = <_SectionRow>[];
    String? lastAnchor;
    for (final _SectionRow r in current) {
      final String? name = r.local?.name;
      if (name != null && named.contains(name)) {
        if (name == relocated) continue;
        leading[name] = pending;
        pending = <_SectionRow>[];
        lastAnchor = name;
      } else {
        pending.add(r);
      }
    }
    // order 非空且 relocated 之外至少还有一本点名词典，lastAnchor 一定有。
    final List<_SectionRow> trailing = pending;
    final List<_SectionRow> next = <_SectionRow>[
      for (final Dictionary d in order) ...<_SectionRow>[
        ...?leading[d.name],
        _SectionRow.local(d),
        if (d.name == lastAnchor) ...trailing,
      ],
    ];

    // 3. 语言组规范化 + 重编号；只出序号变了的行（[replacing] 的其它字段由调用方写）。
    final List<_SectionRow> canonical = concatenateLanguageGroupsOf<_SectionRow>(
      next,
      (_SectionRow r) => r.languageGroup,
    );
    final List<Dictionary> locals = <Dictionary>[];
    final List<RemoteDictionary> remotes = <RemoteDictionary>[];
    for (int k = 0; k < canonical.length; k++) {
      final _SectionRow r = canonical[k];
      final Dictionary? local = r.local;
      if (local != null) {
        if (local.order != k) locals.add(_copyDictionary(local)..order = k);
      } else if (r.remote!.order != k) {
        remotes.add(r.remote!.copyWith(order: k));
      }
    }
    return (locals: locals, remotes: remotes);
  }

  /// 开关一本服务器词典（激活配置拥有的 [RemoteDictionary.hidden]）。
  Future<void> setRemoteDictionaryHidden(
    RemoteDictionary dictionary,
    bool hidden,
  ) => _writeMetadata(
    () => _commitDictionaries(
      const <Dictionary>[],
      remote: <RemoteDictionary>[
        _cachedRemote(dictionary).copyWith(hidden: hidden),
      ],
    ),
  );

  /// 本机给一本服务器词典起显示名（v150，设备本地：不进配置快照、目录刷新不碰）。
  /// [displayName] 为空白或等于 host 上的显示名 / 真名时清掉，回到 host 的名字——
  /// 与本机词典 [setDictionaryDisplayName]「改回真名 = 清掉」同口径。
  Future<void> setRemoteDictionaryLocalDisplayName(
    RemoteDictionary dictionary,
    String? displayName,
  ) => _writeMetadata(() async {
    final RemoteDictionary current = _cachedRemote(dictionary);
    final String trimmed = displayName?.trim() ?? '';
    final String hostName = current.displayName?.trim() ?? '';
    final bool clear =
        trimmed.isEmpty || trimmed == current.name || trimmed == hostName;
    await _db.setRemoteDictionaryLocalDisplayName(
      hostId: current.hostId,
      name: current.name,
      localDisplayName: clear ? null : trimmed,
    );
    _applyRemoteRows(await _readRemoteSnapshot());
  });

  /// 忘掉一条服务器词典目录行（host 上已经没有它时 UI 的「忘掉」）。
  Future<void> forgetRemoteDictionary(String hostId, String name) =>
      _writeMetadata(() async {
        await _db.deleteRemoteDictionary(hostId, name);
        _applyRemoteRows(await _readRemoteSnapshot());
      });

  /// 删掉本机词典 [deleted] 之后的收尾，对**各 host**（含没开「用于查词」的）上同名的
  /// 目录行：
  /// * 已从 host 目录里消失（`missingSince != null`）的行忘掉——它们原本被本机那本
  ///   遮住，本机那本一删就会冒出来成为一条开着开关、只能「忘掉」的「服务器上已没
  ///   有」行；用户删的是一本词典，不该换来一条它从没在服务器上管理过的残行。
  /// * host 上还在的行留着（词典就此变成只在服务器上），并接手本机那行的 `order` 与
  ///   开关：遮住期间它们不参与分区重编号，序号早已过时（见 [_mixedTermOrder]）。
  ///   接手后管理页上同一个位置从「两者」变成「服务器」，查词顺序与开关不变。
  ///
  /// [deleted] 须在删本机行**之前**取（删完就读不到本机行的位置与开关了）。
  Future<void> releaseCatalogRowsOf(
    Iterable<({String name, int order, bool hidden})> deleted,
  ) {
    final Map<String, ({String name, int order, bool hidden})> byName =
        <String, ({String name, int order, bool hidden})>{
          for (final ({String name, int order, bool hidden}) d in deleted)
            d.name: d,
        };
    if (byName.isEmpty) return Future<void>.value();
    return _writeMetadata(() async {
      bool changed = false;
      await _db.transaction(() async {
        for (final RemoteDictionaryMetaRow r
            in await _db.getAllRemoteDictionaryMetadata()) {
          final ({String name, int order, bool hidden})? local = byName[r.name];
          if (local == null) continue;
          if (r.missingSince != null) {
            await _db.deleteRemoteDictionary(r.hostId, r.name);
            changed = true;
          } else if (r.order != local.order || r.hidden != local.hidden) {
            await _db.setRemoteDictionaryProfileColumns(
              hostId: r.hostId,
              name: r.name,
              order: local.order,
              hidden: local.hidden,
            );
            changed = true;
          }
        }
      });
      if (changed) _applyRemoteRows(await _readRemoteSnapshot());
    });
  }

  /// [releaseCatalogRowsOf] 的输入：本机词典 [dictionary] 此刻的位置与开关。
  static ({String name, int order, bool hidden}) catalogHandoverOf(
    Dictionary dictionary,
  ) => (
    name: dictionary.name,
    order: dictionary.order,
    hidden: dictionary.isHidden(JapaneseLanguage.instance),
  );

  /// 「两者」行的开关写入后，把同一开关写到**各 host**（含没开「用于查词」的）上同名
  /// 的目录行：这些行被本机那本遮住、不在 [remoteDictionaries] 里也照样要跟，否则
  /// 本机那份删掉（或那台 host 重新打开查词）后目录行带着旧开关冒出来。
  Future<void> setCatalogRowsHiddenNamed(String name, bool hidden) =>
      _writeMetadata(() async {
        bool changed = false;
        await _db.transaction(() async {
          for (final RemoteDictionaryMetaRow r
              in await _db.getAllRemoteDictionaryMetadata()) {
            if (r.name != name || r.hidden == hidden) continue;
            await _db.setRemoteDictionaryProfileColumns(
              hostId: r.hostId,
              name: r.name,
              order: r.order,
              hidden: hidden,
            );
            changed = true;
          }
        });
        if (changed) _applyRemoteRows(await _readRemoteSnapshot());
      });

  /// 忘掉一台 host 的全部服务器词典目录行（解除配对时选「忘掉设置」）。
  Future<void> forgetRemoteDictionaryHost(String hostId) =>
      _writeMetadata(() async {
        await _db.deleteRemoteDictionariesForHost(hostId);
        _applyRemoteRows(await _readRemoteSnapshot());
      });

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
  ) => updateDictionaryMetadata(<String, Dictionary? Function(Dictionary)>{
    dictionary.name: (Dictionary current) {
      final Map<String, String> metadata = Map<String, String>.of(
        current.metadata,
      );
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
  /// 改完若换了组，这本词典在新组里排**最后**，并且它所在的每个分区（自身类型的
  /// 分区；混合词典再加「汉字」分区）都按 [sectionAfterLanguageChange] 写回规范
  /// 顺序（各语言组按显示顺序首尾相接、按下标重编号）——管理页显示的顺序 ==
  /// 真实查词顺序。只给它一个「全局最大」序号不够：那会让它在查词序里排到
  /// 「未标注语言」组之后，而管理页把它画在未标注组之前。
  /// 没换组（例如「自动 · ja」改成手动 `ja`）则位置不动。查词照旧查全部启用的
  /// 词典，语言只决定它在管理页里归哪组、以及渲染用的字体链。
  Future<void> setDictionaryLanguageOverride(
    Dictionary dictionary,
    String? language,
  ) {
    final String trimmed = language?.trim() ?? '';
    return _writeMetadata(() async {
      final Dictionary current = _dictionariesCache.firstWhere(
        (d) => d.name == dictionary.name,
        orElse: () => throw StateError(
          'Dictionary is no longer installed: ${dictionary.name}',
        ),
      );
      final Dictionary updated = _copyDictionary(current)
        ..languageOverride = trimmed.isEmpty ? null : trimmed;
      final Map<String, Dictionary> writes = <String, Dictionary>{
        updated.name: updated,
      };
      final List<RemoteDictionary> remoteWrites = <RemoteDictionary>[];
      if (dictionaryLanguageGroupOf(updated) !=
          dictionaryLanguageGroupOf(current)) {
        // 分区成员与顺序取改之前的缓存（已按 order 排好），只把这本换成改完的。
        final List<Dictionary> after = <Dictionary>[
          for (final Dictionary d in _dictionariesCache)
            d.name == updated.name ? updated : d,
        ];
        // 两个分区都先按改之前的序号算好，再动任何序号（混合词典没有
        // kDictKanjiOrderKey 时汉字分区序号退回 order，先改 order 会带偏）。
        // 自身类型的分区与服务器词典混排：经 [_renumberSection] 连同服务器词典一起
        // 重编号（这本挪到新组最后），服务器词典守在原来的邻居旁边。
        final _SectionWrites? typeSection = updated.type == DictionaryType.kanji
            ? null
            : _renumberSection(
                updated.type,
                <String>[
                  for (final Dictionary d in sectionAfterLanguageChange(
                    <Dictionary>[
                      for (final Dictionary d in after)
                        if (d.type == updated.type) d,
                    ],
                    updated,
                  ))
                    d.name,
                ],
                moved: updated.name,
                replacing: updated,
              );
        final List<Dictionary>? kanjiSection = updated.isInKanjiSection
            ? sectionAfterLanguageChange(
                kanjiSectionDictionariesOf(after),
                updated,
              )
            : null;
        Dictionary writable(Dictionary d) =>
            writes.putIfAbsent(d.name, () => _copyDictionary(d));
        if (typeSection != null) {
          // 本机行是 [updated] / 缓存那本的拷贝（已带新序号），直接顶替。
          for (final Dictionary d in typeSection.locals) {
            writes[d.name] = d;
          }
          remoteWrites.addAll(typeSection.remotes);
        }
        if (kanjiSection != null) {
          // 「汉字」分区：纯 kanji 词典写 order，混合词典只写汉字部分的
          // kDictKanjiOrderKey（同 [updateKanjiSectionOrder]）。
          for (int i = 0; i < kanjiSection.length; i++) {
            final Dictionary target = writable(kanjiSection[i]);
            if (target.hasEmbeddedKanji) {
              writes[target.name] = target.copyWith(
                metadata: <String, String>{
                  ...target.metadata,
                  kDictKanjiOrderKey: '$i',
                },
              );
            } else {
              target.order = i;
            }
          }
        }
      }
      // 只写真的变了的：顺序没动的词典不进事务。
      await _commitDictionaries(<Dictionary>[
        for (final Dictionary d in writes.values)
          if (d.name == updated.name || _orderChanged(d)) d,
      ], remote: remoteWrites);
      final Dictionary committed = writes[updated.name]!;
      // 与 [_editDictionary] 同理：只在写入成功后把结果回填给调用方手里的快照。
      dictionary
        ..order = committed.order
        ..languageOverride = committed.languageOverride;
    });
  }

  /// [candidate] 的两个排序键（[Dictionary.order] / 汉字分区序号）与缓存里同名
  /// 那本是否不同。
  bool _orderChanged(Dictionary candidate) {
    final Dictionary current = _dictionariesCache.firstWhere(
      (Dictionary d) => d.name == candidate.name,
    );
    return current.order != candidate.order ||
        current.kanjiSectionOrder != candidate.kanjiSectionOrder;
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
    Dictionary dictionary,
    String? displayName,
  ) {
    final String trimmed = displayName?.trim() ?? '';
    return _editDictionary(dictionary, (updated) {
      updated.displayName = (trimmed.isEmpty || trimmed == updated.name)
          ? null
          : trimmed;
    });
  }

  /// 设置页那个一键按钮：继承 → 显式展开 → 显式折叠 → 继承。
  ///
  /// 起点是「继承」而不是「展开」，因为存量用户的每一本都是继承态；第一次点下去
  /// 得到「显式展开」，正是他们本来以为自己在做的那件事。
  Future<void> cycleDictionaryCollapseState(
    Dictionary dictionary,
    String languageCode,
  ) {
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
    Dictionary dictionary,
    String languageCode,
  ) => _editDictionary(dictionary, (updated) {
    _applyHiddenState(
      updated,
      languageCode,
      !updated.hiddenLanguages.contains(languageCode),
    );
  });

  Future<void> setDictionaryHidden(
    Dictionary dictionary,
    String languageCode,
    bool hidden,
  ) => _editDictionary(
    dictionary,
    (updated) => _applyHiddenState(updated, languageCode, hidden),
  );

  static void _applyHiddenState(
    Dictionary dictionary,
    String languageCode,
    bool hidden,
  ) {
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
    _dictionarySearchCache.maxBytes = _isLowMemory()
        ? searchCacheMaxBytesLowMemory
        : searchCacheMaxBytes;
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

    _dictionaryHistoryResults.removeWhere(
      (r) => r.searchTerm == result.searchTerm,
    );
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
      () => unawaited(
        flushDictionaryHistoryNow().catchError((
          Object error,
          StackTrace stack,
        ) {
          // Keep dirty state for the next explicit flush or lookup. The timer
          // has no caller to receive a failure; lifecycle flushes still throw.
          ErrorLogService.instance.log('DictRepo.historyPersist', error, stack);
        }),
      ),
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
      final List<String> encoded = await encodeDictionaryHistoryResults(
        <DictionarySearchResult>[for (final int i in missing) snapshot[i]],
      );
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
    _remoteDictionariesCache = const <RemoteDictionary>[];
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
) => Isolate.run(
  () => <String>[for (final DictionarySearchResult r in results) r.toJson()],
  debugName: 'fushi-dict-history-json',
);

/// 查词热路径要的词典过滤与排序快照（[DictionaryRepository.lookupFilters]）。
class DictionaryLookupFilters {
  const DictionaryLookupFilters({
    required this.hiddenDictionaryNames,
    required this.termDictionaryOrder,
    this.hasChineseTermDictionary = false,
    this.kanjiDictionaryNames = const <String>{},
    this.hiddenKanjiDictionaryNames = const <String>{},
  });

  /// 被用户关掉的词典名（术语开关：引擎排除集 + 结果源头过滤）。
  final Set<String> hiddenDictionaryNames;

  /// 本机的**纯汉字型**词典（`type == kanji`）真名。[forRequesterConfig] 据此从请求方
  /// 的排除名单里挑出要剔汉字结果的那些。
  final Set<String> kanjiDictionaryNames;

  /// 汉字结果要按名剔除的纯汉字型词典（交给 `FushiLookupRequest.hiddenKanjiDictionaries`）。
  ///
  /// 不能拿 [hiddenDictionaryNames] 过滤汉字结果：它是**术语**开关，混合词典可以
  /// 「术语关、汉字开」（BUG-3573），按它剔会误删那本的汉字条目。所以纯汉字词典的
  /// 排除单独成一个集合。App 自己查词时为空：本机关掉的纯汉字词典根本没装进汉字桶；
  /// 替对端查词时 = 请求方排除名单 ∩ [kanjiDictionaryNames]（[forRequesterConfig]）。
  final Set<String> hiddenKanjiDictionaryNames;

  /// term 词典的管理页顺序（真名）。
  final List<String> termDictionaryOrder;

  /// 启用中的 term 词典里是否有声明为中文的（[Dictionary.effectiveSourceLanguage]
  /// 经 [isChineseLanguageTag] 判定：手动指定语言优先，其次包内 `sourceLanguage`）。
  ///
  /// 查词来源语言未知时（首页 / 查词页独立查词：没有媒体页登记语言、全局默认内容语言
  /// 也没设）用它决定是否展开简繁变体（反馈 3FY6vTqwV-）——查词集合里有中文词典，
  /// 简繁拼写才有意义；没有就一个变体都不多产。不用来过滤词典（所有者否决过按语言
  /// 过滤查词，见 dictionary_language_groups.dart 文件头）。
  final bool hasChineseTermDictionary;

  /// 这份过滤的指纹（查词结果缓存键的命名空间用）：隐藏名单（排序后）+ term 顺序。
  /// 同一个词按两套过滤查出的结果不能共用缓存键（配置视图、请求方词典选择都靠它）。
  String get fingerprint {
    final List<String> hidden = hiddenDictionaryNames.toList()..sort();
    final List<String> hiddenKanji = hiddenKanjiDictionaryNames.toList()..sort();
    final String raw =
        '${hidden.join('\u0000')}\u0001${termDictionaryOrder.join('\u0000')}'
        '\u0001${hiddenKanji.join('\u0000')}';
    // FNV-1a 32 位 + 原串长度 + 两个条目数：哈希冲突会让两套过滤共用一个缓存键，
    // 拼上长度与条目数后要同时撞上四者才会串结果。
    int hash = 0x811c9dc5;
    for (final int unit in raw.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return '${hash.toRadixString(16)}.${raw.length}.'
        '${hidden.length}.${termDictionaryOrder.length}.${hiddenKanji.length}';
  }

  /// 替对端查词时按**请求方**的词典选择（[config]，远端查词请求的 `dictionaries` 字段）
  /// 改写本机这份过滤：
  /// * 隐藏 = [RemoteLookupDictionaryConfig.excluded]（请求方说了算，不叠本机开关）；
  /// * term 顺序 = `config.order` 里本机有的名字在前，其余本机 term 词典按本机顺序接在
  ///   后面（本机有而请求方没提到的词典照常参与，Fushi 新词典默认启用）；
  /// * 汉字结果剔除 = 排除名单里本机的纯汉字型词典（[hiddenKanjiDictionaryNames]）。
  ///
  /// 本机配置里关掉的词典根本没装进引擎（`dictionary_buckets.dart`），请求方要它也查
  /// 不到——这是 App 当 host 的固有限制，服务端 host 装载全部词典没有这个问题。
  DictionaryLookupFilters forRequesterConfig(
    RemoteLookupDictionaryConfig config,
  ) {
    final Set<String> local = termDictionaryOrder.toSet();
    final Set<String> seen = <String>{};
    return DictionaryLookupFilters(
      hiddenDictionaryNames: Set<String>.unmodifiable(config.excluded),
      termDictionaryOrder: List<String>.unmodifiable(<String>[
        for (final String name in config.order)
          if (local.contains(name) && seen.add(name)) name,
        for (final String name in termDictionaryOrder)
          if (seen.add(name)) name,
      ]),
      hasChineseTermDictionary: hasChineseTermDictionary,
      kanjiDictionaryNames: kanjiDictionaryNames,
      hiddenKanjiDictionaryNames: Set<String>.unmodifiable(
        config.excluded.intersection(kanjiDictionaryNames),
      ),
    );
  }
}

/// 服务器托管词典的一条目录行（`remote_dictionary_metadata`，见 `tables.dart` 的
/// `RemoteDictionaryMetadata`）在 App 里的不可变视图。
///
/// 身份 = ([hostId], [name])。目录列由 `RemoteDictionaryCatalogService` 刷新；
/// [order] / [hidden] 属于激活配置，经 [DictionaryRepository] 的元数据写入队列改。
@immutable
class RemoteDictionary {
  const RemoteDictionary({
    required this.hostId,
    required this.name,
    required this.type,
    required this.order,
    required this.lastSeenAt,
    this.hidden = false,
    this.formatKey,
    this.revision,
    this.displayName,
    this.sourceLanguage,
    this.missingSince,
    this.localDisplayName,
  });

  factory RemoteDictionary.fromRow(RemoteDictionaryMetaRow row) =>
      RemoteDictionary(
        hostId: row.hostId,
        name: row.name,
        type: dictionaryTypeFromName(row.type),
        order: row.order,
        hidden: row.hidden,
        lastSeenAt: row.lastSeenAt,
        formatKey: row.formatKey,
        revision: row.revision,
        displayName: row.displayName,
        sourceLanguage: row.sourceLanguage,
        missingSince: row.missingSince,
        localDisplayName: row.localDisplayName,
      );

  final String hostId;

  /// host 上的真名（查词请求按它点名）。
  final String name;
  final DictionaryType type;

  /// 与本机词典同一数轴的管理页顺序（配置拥有）。
  final int order;

  /// 这个配置是否关掉了它（配置拥有）。
  final bool hidden;
  final int lastSeenAt;
  final String? formatKey;
  final String? revision;
  final String? displayName;
  final String? sourceLanguage;

  /// 从 host 目录里消失的时刻；null = 上次刷新时还在。
  final int? missingSince;

  /// 本机给它起的显示名（v150，设备本地、不归配置）；null = 用 host 的 [displayName]。
  final String? localDisplayName;

  /// 用户可见的名字：本机起的名 > host 的显示名 > 真名。
  String get effectiveDisplayName {
    final String local = localDisplayName?.trim() ?? '';
    if (local.isNotEmpty) return local;
    final String host = displayName?.trim() ?? '';
    return host.isNotEmpty ? host : name;
  }

  /// host 上已经没有它了（设置保留，回来时原样生效）。
  bool get isMissing => missingSince != null;

  /// `<hostId>/<name>`：缓存 / 快照里的键（name 是目录名，不含 `/`）。
  String get key => '$hostId/$name';

  RemoteDictionary copyWith({int? order, bool? hidden}) => RemoteDictionary(
    hostId: hostId,
    name: name,
    type: type,
    order: order ?? this.order,
    hidden: hidden ?? this.hidden,
    lastSeenAt: lastSeenAt,
    formatKey: formatKey,
    revision: revision,
    displayName: displayName,
    sourceLanguage: sourceLanguage,
    missingSince: missingSince,
    localDisplayName: localDisplayName,
  );

  /// 管理页顺序；同序号按 host、真名稳定排开。
  static int compareByOrder(RemoteDictionary a, RemoteDictionary b) {
    final int byOrder = a.order.compareTo(b.order);
    if (byOrder != 0) return byOrder;
    final int byHost = a.hostId.compareTo(b.hostId);
    return byHost != 0 ? byHost : a.name.compareTo(b.name);
  }
}

/// 一台已配对、本机有它词典目录的 host（词典管理页「来源」条的一张卡片）。
@immutable
class RemoteDictionaryHostSource {
  const RemoteDictionaryHostSource({
    required this.hostId,
    required this.name,
    required this.lookupEnabled,
    required this.catalog,
  });

  /// [remoteDictionaryHostIdOf] 口径的 host 身份。
  final String hostId;

  /// 展示名（配对记下的设备名，没有时用地址）。
  final String name;

  /// 「用这台服务器查词典」此刻是否开着。
  final bool lookupEnabled;

  /// 这台 host 的全部目录行（各类型、含已缺席的），按管理页顺序。
  final List<RemoteDictionary> catalog;
}

/// [DictionaryRepository._renumberSection] 的写入清单：序号变了的本机词典与服务器词典。
typedef _SectionWrites = ({
  List<Dictionary> locals,
  List<RemoteDictionary> remotes,
});

/// 混排分区里的一行：本机词典或单独成行的服务器词典。
class _SectionRow {
  const _SectionRow.local(Dictionary this.local) : remote = null;
  const _SectionRow.remote(RemoteDictionary this.remote) : local = null;

  final Dictionary? local;
  final RemoteDictionary? remote;

  /// 归哪个语言组：与管理页 `DictionaryManagerRow.languageGroup` 同一判据（本机按
  /// [dictionaryLanguageGroupOf]，服务器行按 host 报的 `sourceLanguage`）。
  String? get languageGroup {
    final Dictionary? l = local;
    if (l != null) return dictionaryLanguageGroupOf(l);
    return canonicalDictionaryLanguageTag(remote!.sourceLanguage);
  }
}

/// [DictionaryRepository] 装载服务器词典的输入：全部目录行（按 host、真名排序）+
/// 参与查词的 host。
typedef _RemoteSnapshot = ({
  List<RemoteDictionaryMetaRow> rows,
  Set<String> hosts,
});

int estimateDictionaryPopupCacheEntryBytes(DictionaryPopupCacheEntry entry) =>
    entry.popupJson.length * 2 + _kObjectOverheadBytes;

/// 粗估一条 [DictionarySearchResult] 的常驻字节数。大头是 [popupJson]
/// （实测 54-231KB）与各 entry 的 meaning JSON。
int estimateDictionarySearchResultBytes(DictionarySearchResult result) {
  int chars = result.searchTerm.length + (result.popupJson?.length ?? 0);
  int overhead = _kObjectOverheadBytes;
  for (final DictionaryEntry entry in result.entries) {
    chars +=
        entry.dictionaryName.length +
        entry.word.length +
        entry.reading.length +
        entry.meaning.length +
        entry.extra.length;
    overhead += _kObjectOverheadBytes;
  }
  for (final FushiKanjiResult kanji in result.kanjiResults) {
    chars +=
        kanji.character.length +
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
