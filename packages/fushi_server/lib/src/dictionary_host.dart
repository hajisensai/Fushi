/// 无头服务端的词典引擎：把 C++ fushidicts（与 app 同一份原生库、同一份 Dart 封装
/// [FushiDicts]）装进服务端，给互联对端提供查词（`/api/lookup/dictionary`）、
/// 词典媒体（`/api/media/dictionary`）与查词历史。
///
/// 词典本身经互联推送进来（`/api/library/dictionaries`，[LocalLibraryHostService]
/// 落 DB 元数据 + 资源目录），这里只负责「DB 里有哪些词典 → 引擎装哪些」与查询。
/// 与 app 的 `AppModel._rebuildDictPathsCache` / `searchDictionary` /
/// `_AppModelRemoteLookupService` 一一对应；差别只在数据来源（服务端没有
/// DictionaryRepository 的内存缓存，直接读 DB）与没有 UI 侧的远端回落。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_anki/fushi_anki_core.dart' show ankiDictionaryMediaCacheDirPath, ankiDictionaryMediaCacheFilename;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary_core.dart';
import 'package:fushi_engine/dictionary/dictionary_engine_hooks.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';
import 'package:fushi_server/src/native_libs.dart';
import 'package:path/path.dart' as p;

/// 词典引擎原生库路径的环境变量覆盖（与 `FUSHI_P2P_LIB` 同一约定）。
const String kFushiDictsLibEnv = 'FUSHI_DICTS_LIB';

/// 变形表目录（含 `manifest.json` + `<lang>.json`）的环境变量覆盖。
const String kFushiTransformsDirEnv = 'FUSHI_TRANSFORMS_DIR';

/// app 的 `DictionaryMediaType.uniqueKey`（查词搜索历史的 historyKey，冻结）。
const String kDictionarySearchHistoryKey = 'dictionary_media_type';

/// 查词输入上限（与 app 的 `kMaxLookupInputChars` 同值）：超长串先截断再清洗。
const int kServerMaxLookupInputChars = 2000;

/// 一条词典在引擎分桶时需要的信息（与 app 的 `DictPathEntry` 同形）。
typedef ServerDictPathEntry = ({String type, String path, bool exists, bool hidden, bool hasKanji});

/// 把词典分桶成引擎要的四组路径（与 app 的 `bucketDictPaths` 同一规则）：
/// 隐藏的 freq / pitch / kanji 不进引擎（它们没有渲染期隐藏过滤）；term 在结果生成时
/// 按隐藏过滤，所以隐藏的 term 仍进桶；不存在的目录跳过；含汉字记录的 term 词典
/// （metadata `hasKanji`）同时进 kanji 桶。
({List<String> term, List<String> freq, List<String> pitch, List<String> kanji}) bucketServerDictPaths(
  List<ServerDictPathEntry> entries,
) {
  final List<String> term = <String>[];
  final List<String> freq = <String>[];
  final List<String> pitch = <String>[];
  final List<String> kanji = <String>[];
  for (final ServerDictPathEntry e in entries) {
    if (!e.exists) continue;
    switch (e.type) {
      case 'kanji':
        if (!e.hidden) kanji.add(e.path);
      case 'frequency':
        if (!e.hidden) freq.add(e.path);
      case 'pitch':
        if (!e.hidden) pitch.add(e.path);
      default:
        term.add(e.path);
        if (e.hasKanji && !e.hidden) kanji.add(e.path);
    }
  }
  return (term: term, freq: freq, pitch: pitch, kanji: kanji);
}

/// 查词前的查询串清洗（app `normalizeSearchTerm` 的服务端版）：截断 → 换行折空格 →
/// emoji 换空格 → 首尾标点 / 符号剥离 → 孤立代理项换空格，顺序固定。
///
/// app 的 emoji 正则来自 `remove_emoji` 包（Flutter app 依赖），这里用 Unicode
/// `Extended_Pictographic` 属性代替；首尾的 emoji 本就落在 `\p{S}` 里被剥掉。
String normalizeServerSearchTerm(String term) {
  String s = term;
  final List<int> runes = s.runes.toList();
  if (runes.length > kServerMaxLookupInputChars) {
    s = String.fromCharCodes(runes.take(kServerMaxLookupInputChars));
  }
  s = s.replaceAll('\n', ' ');
  s = s.replaceAll(_emojiRegex, ' ');
  s = s.replaceAll(_punctuationRegex, '');
  s = s.replaceAll(_loneSurrogateRegex, ' ');
  return s;
}

final RegExp _emojiRegex = RegExp(r'\p{Extended_Pictographic}', unicode: true);
final RegExp _punctuationRegex = RegExp(r'^[\p{P}\p{S}]+|[\p{P}\p{S}]+$', unicode: true);
final RegExp _loneSurrogateRegex = RegExp('[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?:[^\uD800-\uDBFF]|^)[\uDC00-\uDFFF]');

/// 单个汉字（按码点数）——只有这种查询才额外查汉字词典桶（与 app `isSingleKanji` 同）。
bool isSingleKanjiTerm(String text) {
  final List<int> runes = text.runes.toList();
  if (runes.length != 1) return false;
  final int cp = runes.single;
  return (cp >= 0x4E00 && cp <= 0x9FFF) ||
      (cp >= 0x3400 && cp <= 0x4DBF) ||
      (cp >= 0x20000 && cp <= 0x2A6DF) ||
      (cp >= 0x2A700 && cp <= 0x2EBEF) ||
      (cp >= 0x30000 && cp <= 0x3134F) ||
      (cp >= 0xF900 && cp <= 0xFAFF) ||
      (cp >= 0x2F800 && cp <= 0x2FA1F);
}

/// 引擎装载用的词典视图（一次 DB 读的快照）。
class _DictionarySnapshot {
  const _DictionarySnapshot({required this.termOrder, required this.hidden});

  /// term 词典按用户排序的名单（结果生成按它排）。
  final List<String> termOrder;

  /// 在日语下被隐藏的词典名（结果生成时过滤）。
  final Set<String> hidden;
}

class ServerDictionaryHost {
  ServerDictionaryHost({
    required this.db,
    required this.dictionaryResourceRoot,
    String? libraryPath,
    Directory? transformsDir,
  }) : _libraryPath = libraryPath ?? resolveFushiDictsLibraryPath(),
       _transformsDir = transformsDir ?? resolveTransformsDirectory();

  final FushiDatabase db;
  final Directory dictionaryResourceRoot;
  final String? _libraryPath;
  final Directory? _transformsDir;

  bool _available = false;
  String? _unavailableReason;
  _DictionarySnapshot _snapshot = const _DictionarySnapshot(termOrder: <String>[], hidden: <String>{});
  int _loadedCount = 0;

  /// 引擎是否可用（原生库加载成功）。不可用时互联的查词 / 词典媒体路由不接线。
  bool get available => _available;

  /// 不可用的原因（给日志 / WebUI）；可用时为 null。
  String? get unavailableReason => _unavailableReason;

  /// 当前装进引擎的词典数（四桶合计，不去重）。
  int get loadedCount => _loadedCount;

  /// 实际使用的原生库路径（null = 按平台默认裸名加载）。
  String? get libraryPath => _libraryPath;

  /// 加载原生库、预载变形表、按 DB 装载词典。原生库加载不了返回 false 并记下原因，
  /// 服务端照常起（词典只是存储中转，查词不可用）。
  Future<bool> start() async {
    FushiDicts.nativeLibraryPath = _libraryPath;
    try {
      // 空引擎探一次原生库：dlopen / 符号缺失在这里暴露，而不是在第一次查词时。
      FushiDicts.initializeTyped();
    } catch (e, st) {
      _available = false;
      _unavailableReason =
          'fushidicts 原生库加载失败'
          '（${_libraryPath ?? 'libfushidicts_ffi 裸名'}）：$e';
      engineLog.log('ServerDictionaryHost.start', e, st);
      return false;
    }
    _available = true;
    _unavailableReason = null;
    // 删 / 覆盖词典目录前释放映射（BUG-1756），与 app 的装配一致。
    releaseDictionaryMappings = FushiDicts.releaseAllMappings;
    await _preloadTransforms();
    await refresh();
    return true;
  }

  Future<void> _preloadTransforms() async {
    final Directory? dir = _transformsDir;
    if (dir == null) {
      engineLog.logDiagnostic(
        'ServerDictionaryHost',
        '没找到变形表目录（设 $kFushiTransformsDirEnv 或随包放 share/fushi/transforms），'
            '查词不做去屈折',
      );
      return;
    }
    await FushiDicts.preloadTransformsFrom((String assetKey) {
      // 资源键形如 `assets/transforms/<file>`，只取文件名，落到目录内。
      return File(p.join(dir.path, p.basename(assetKey))).readAsString();
    });
  }

  /// 按 DB 当前的词典元数据重载引擎（导入 / 删除词典后由库服务回调）。
  Future<void> refresh() async {
    if (!_available) return;
    final List<DictionaryMetaRow> rows = await db.getAllDictionaryMetadata()
      ..sort((DictionaryMetaRow a, DictionaryMetaRow b) => a.order.compareTo(b.order));
    final List<ServerDictPathEntry> entries = <ServerDictPathEntry>[];
    final List<String> termOrder = <String>[];
    final Set<String> hidden = <String>{};
    for (final DictionaryMetaRow r in rows) {
      final String dir = p.join(dictionaryResourceRoot.path, r.name);
      final bool isHidden = _decodeStringList(r.hiddenLanguagesJson).contains('ja');
      if (isHidden) hidden.add(r.name);
      if (r.type == 'term') termOrder.add(r.name);
      entries.add((
        type: r.type,
        path: dir,
        exists: Directory(dir).existsSync(),
        hidden: isHidden,
        hasKanji: _decodeStringMap(r.metadataJson)['hasKanji'] == 'true',
      ));
    }
    final b = bucketServerDictPaths(entries);
    FushiDicts.initializeTyped(termPaths: b.term, freqPaths: b.freq, pitchPaths: b.pitch, kanjiPaths: b.kanji);
    _snapshot = _DictionarySnapshot(termOrder: termOrder, hidden: hidden);
    _loadedCount = b.term.length + b.freq.length + b.pitch.length + b.kanji.length;
    engineLog.logDiagnostic(
      'ServerDictionaryHost',
      'loaded ${b.term.length} term / ${b.freq.length} freq / '
          '${b.pitch.length} pitch / ${b.kanji.length} kanji dictionaries',
    );
  }

  static List<String> _decodeStringList(String raw) {
    try {
      final Object? v = jsonDecode(raw);
      return v is List ? <String>[for (final Object? e in v) '$e'] : const <String>[];
    } on FormatException {
      return const <String>[];
    }
  }

  static Map<String, String> _decodeStringMap(String raw) {
    try {
      final Object? v = jsonDecode(raw);
      return v is Map
          ? <String, String>{for (final MapEntry<Object?, Object?> e in v.entries) '${e.key}': '${e.value}'}
          : const <String, String>{};
    } on FormatException {
      return const <String, String>{};
    }
  }

  /// 查一个词：与 app `searchDictionary(useCache: false, allowRemoteLookup: false)`
  /// 同一条链路——清洗 → FFI lookup（上限 = 词头预算）→ [buildResultFromLookup] +
  /// [buildPopupJsonFromLookup]（隐藏词典在源头剔除）→ 单汉字附汉字词典结果。
  /// 无结果返回 null。
  DictionarySearchResult? search(String rawTerm, {required int maximumTerms}) {
    if (!_available) return null;
    final String term = normalizeServerSearchTerm(rawTerm);
    if (term.trim().isEmpty) return null;
    final List<FushiKanjiResult> kanji = isSingleKanjiTerm(term)
        ? FushiDicts.instance.queryKanji(term)
        : const <FushiKanjiResult>[];
    final List<FushiLookupResult> results = FushiDicts.instance.lookup(term, maxResults: maximumTerms);
    if (results.isEmpty) {
      if (kanji.isEmpty) return null;
      return DictionarySearchResult(searchTerm: term, kanjiResults: kanji);
    }
    final _DictionarySnapshot snap = _snapshot;
    final DictionarySearchResult built = buildResultFromLookup(
      searchTerm: term,
      results: results,
      maximumTerms: maximumTerms,
      dictionaryOrder: snap.termOrder,
    );
    final DictionarySearchResult result = built.withKanjiResults(kanji);
    result.popupJson = buildPopupJsonFromLookup(
      results: results,
      maximumTerms: maximumTerms,
      hiddenDictionaries: snap.hidden,
      dictionaryOrder: snap.termOrder,
    );
    if (result.entries.isEmpty && result.kanjiResults.isEmpty) return null;
    return result;
  }

  /// 只要弹窗 JSON 的快路径（浏览器扩展 `popupOnly`），不物化 DictionaryEntry。
  RemoteDictionaryPopupLookup? searchPopup(String rawTerm, {required int maximumTerms}) {
    if (!_available) return null;
    final String term = normalizeServerSearchTerm(rawTerm);
    if (term.trim().isEmpty) return null;
    final List<FushiLookupResult> results = FushiDicts.instance.lookup(term, maxResults: maximumTerms);
    if (results.isEmpty) return null;
    int bestLength = 0;
    for (final FushiLookupResult r in results) {
      if (r.matched.length > bestLength) bestLength = r.matched.length;
    }
    final _DictionarySnapshot snap = _snapshot;
    return RemoteDictionaryPopupLookup(
      popupJson: buildPopupJsonFromLookup(
        results: results,
        maximumTerms: maximumTerms,
        hiddenDictionaries: snap.hidden,
        dictionaryOrder: snap.termOrder,
      ),
      bestLength: bestLength,
    );
  }

  /// 词典媒体字节（外字 / 音调图），给 `/api/media/dictionary` 与制卡落缓存。
  Uint8List? mediaFile(String dictionary, String path) {
    if (!_available || !FushiDicts.isInitialized) return null;
    return FushiDicts.instance.getMediaFile(dictionary, path);
  }

  /// 制卡前把载荷里登记的词典媒体（`[{dictionary, path}]` JSON 串）落进 Anki 媒体
  /// 缓存，制卡渲染从那里读字节（与 app 的 `writeDictionaryMediaCache` 同一约定）。
  /// 取不到的条目只留痕跳过（该条退回 alt 文本），不阻断制卡。
  Future<void> writeDictionaryMediaCache(String dictionaryMediaJson) async {
    if (dictionaryMediaJson.isEmpty || dictionaryMediaJson == '[]') return;
    final Object? decoded;
    try {
      decoded = jsonDecode(dictionaryMediaJson);
    } on FormatException catch (e) {
      engineLog.logDiagnostic('ServerDictionaryHost.media', 'payload JSON 解析失败: $e');
      return;
    }
    if (decoded is! List || decoded.isEmpty) return;
    final Directory dir = Directory(ankiDictionaryMediaCacheDirPath());
    if (!dir.existsSync()) dir.createSync(recursive: true);
    for (final Object? raw in decoded) {
      if (raw is! Map) continue;
      final String dict = raw['dictionary']?.toString() ?? '';
      final String path = raw['path']?.toString() ?? '';
      if (dict.isEmpty || path.isEmpty) continue;
      final File file = File(p.join(dir.path, ankiDictionaryMediaCacheFilename(dict, path)));
      if (file.existsSync()) continue;
      final Uint8List? bytes = mediaFile(dict, path);
      if (bytes == null || bytes.isEmpty) {
        engineLog.logDiagnostic('ServerDictionaryHost.media', '词典「$dict」取不到媒体字节: $path');
        continue;
      }
      await file.writeAsBytes(bytes, flush: true);
    }
  }
}

/// 互联查词 service：查词走 [ServerDictionaryHost]，单词音频服务端不提供
/// （服务端不做查词发音，见 README；`/api/lookup/audio` 恒回「未命中」）。
class ServerRemoteLookupService implements FushiRemoteLookupService, FushiRemotePopupLookupService {
  ServerRemoteLookupService(this.dictionaries);

  final ServerDictionaryHost dictionaries;

  @override
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async => dictionaries.search(term, maximumTerms: maximumTerms);

  @override
  Future<RemoteDictionaryPopupLookup?> searchDictionaryPopup({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async => dictionaries.searchPopup(term, maximumTerms: maximumTerms);

  @override
  Future<RemoteAudioLookup?> lookupAudio({required String expression, required String reading}) async => null;
}

/// 查词历史（浏览器扩展 / 对端 `record: true`）落服务端 DB：与 app 同两张表——
/// `dictionary_history`（完整结果，按词去重、保留最近 [maximumResults] 条）与
/// `search_history_items`（historyKey = [kDictionarySearchHistoryKey]，保留最近
/// [maximumSearchTerms] 条）。写入串行，[idle] 等全部落库。
class ServerRemoteHistoryService implements FushiRemoteHistoryService {
  ServerRemoteHistoryService(this.db, {this.maximumResults = 10, this.maximumSearchTerms = 60});

  final FushiDatabase db;
  final int maximumResults;
  final int maximumSearchTerms;
  Future<void> _tail = Future<void>.value();

  /// 已排队的历史写入全部落库后完成。
  Future<void> get idle => _tail;

  @override
  void recordHistory(DictionarySearchResult result) {
    if (result.searchTerm.trim().isEmpty) return;
    _tail = _tail.then((_) => _write(result)).catchError((Object e, StackTrace st) {
      engineLog.log('ServerRemoteHistoryService.recordHistory', e, st);
    });
  }

  Future<void> _write(DictionarySearchResult result) async {
    final String term = result.searchTerm;
    await db.upsertSearchHistoryItem(
      SearchHistoryItemsCompanion.insert(
        historyKey: kDictionarySearchHistoryKey,
        searchTerm: term,
        uniqueKey: '$kDictionarySearchHistoryKey/$term',
      ),
    );
    await db.trimSearchHistory(kDictionarySearchHistoryKey, maximumSearchTerms);
    if (result.entries.isEmpty) return;
    final List<String> kept = <String>[];
    for (final DictionaryHistoryRow row in await db.getAllDictionaryHistory()) {
      final String? rowTerm = _searchTermOf(row.resultJson);
      if (rowTerm == term) continue;
      kept.add(row.resultJson);
    }
    kept.add(result.toJson());
    final List<String> tail = kept.length > maximumResults ? kept.sublist(kept.length - maximumResults) : kept;
    await db.replaceAllDictionaryHistory(<DictionaryHistoryCompanion>[
      for (int i = 0; i < tail.length; i++) DictionaryHistoryCompanion.insert(position: i, resultJson: tail[i]),
    ]);
  }

  static String? _searchTermOf(String resultJson) {
    try {
      final Object? v = jsonDecode(resultJson);
      return v is Map ? v['searchTerm']?.toString() : null;
    } on FormatException {
      return null;
    }
  }
}

/// 原生库路径：`FUSHI_DICTS_LIB` > bundle 布局（`bin/../lib/` 等）> null（裸名）。
String? resolveFushiDictsLibraryPath({Map<String, String>? environment, String? executablePath}) {
  final String? env = (environment ?? Platform.environment)[kFushiDictsLibEnv];
  if (env != null && env.trim().isNotEmpty) return env.trim();
  return locateBundledLibrary(fushiDictsLibraryName(), executablePath: executablePath);
}

/// 变形表目录：`FUSHI_TRANSFORMS_DIR` > bundle 里的 `share/fushi/transforms` >
/// 源码树里的 `fushi/assets/transforms`（`dart run` 开发态）。都没有返回 null。
Directory? resolveTransformsDirectory({Map<String, String>? environment, String? executablePath, Uri? scriptUri}) {
  final String? env = (environment ?? Platform.environment)[kFushiTransformsDirEnv];
  final String exeDir = p.dirname(executablePath ?? Platform.resolvedExecutable);
  final List<String> candidates = <String>[
    if (env != null && env.trim().isNotEmpty) env.trim(),
    p.normalize(p.join(exeDir, '..', 'share', 'fushi', 'transforms')),
    p.join(exeDir, 'transforms'),
  ];
  final Uri script = scriptUri ?? Platform.script;
  if (script.isScheme('file')) {
    // packages/fushi_server/bin/<script>.dart → 仓库根/fushi/assets/transforms
    candidates.add(
      p.normalize(p.join(p.dirname(script.toFilePath()), '..', '..', '..', 'fushi', 'assets', 'transforms')),
    );
  }
  for (final String c in candidates) {
    if (File(p.join(c, 'manifest.json')).existsSync()) return Directory(c);
  }
  return null;
}
