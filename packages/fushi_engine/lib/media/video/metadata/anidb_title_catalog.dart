/// AniDB 官方动画标题目录。
///
/// 与 Shoko 的 `AniDBTitleHelper` 保持同一数据边界：标题识别只依赖 AniDB 每日
/// 标题包，不需要（也不允许伪造）HTTP API client 身份。目录在磁盘缓存 24 小时，
/// 更新先完整解压、解析并写入临时文件，再以 rename 替换；刷新失败时继续使用旧包。
///
/// 解压、解析、建索引整段都在后台 isolate 里跑（[Isolate.run]，结果经
/// `Isolate.exit` 零拷贝交回），且解析走 [XmlEventDecoder] 流式事件而不是整棵
/// `XmlDocument`：标题包解压后是几十 MB、十万级标题，之前在 UI isolate 上整段
/// 同步解析 + 建 DOM，手机上一次「按作品归类」导入就是数秒到数十秒的整机冻结，
/// DOM 的堆峰值还足以让低内存机被系统直接杀掉。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fushi_engine/media/video/scraper/title_normalizer.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart' show XmlException;
import 'package:xml/xml_events.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';

typedef AniDbCatalogNow = DateTime Function();

class AniDbTitle {
  AniDbTitle({
    required this.value,
    required this.type,
    required this.language,
  }) : normalizedValue = TitleNormalizer.normalize(value);

  final String value;

  /// AniDB title type as published by the title dump (`main`, `official`,
  /// `syn`, `short`, ...). It is deliberately not translated into UI terms.
  final String type;

  /// The unmodified `xml:lang` value from AniDB.
  final String language;

  /// Cached once when the daily dump is parsed. Search touches hundreds of
  /// thousands of titles, so normalizing the same strings per query would be
  /// the dominant cost even before fuzzy matching.
  final String normalizedValue;
}

class AniDbTitleRecord {
  AniDbTitleRecord({required this.animeId, required List<AniDbTitle> titles})
      : titles = List<AniDbTitle>.unmodifiable(titles);

  final int animeId;
  final List<AniDbTitle> titles;

  AniDbTitle? get mainTitle {
    for (final AniDbTitle title in titles) {
      if (title.type == 'main') return title;
    }
    return titles.isEmpty ? null : titles.first;
  }
}

enum AniDbTitleMatchKind { exact, prefix, similar }

class AniDbTitleSearchResult {
  const AniDbTitleSearchResult({
    required this.record,
    required this.matchedTitle,
    required this.kind,
    required this.similarity,
  });

  final AniDbTitleRecord record;
  final AniDbTitle matchedTitle;
  final AniDbTitleMatchKind kind;
  final double similarity;
}

class AniDbTitleCatalogException implements Exception {
  const AniDbTitleCatalogException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => cause == null
      ? 'AniDbTitleCatalogException: $message'
      : 'AniDbTitleCatalogException: $message ($cause)';
}

class AniDbTitleCatalog {
  AniDbTitleCatalog({
    http.Client? client,
    Directory? cacheDirectory,
    Uri? sourceUrl,
    AniDbCatalogNow? now,
    this.cacheTtl = const Duration(hours: 24),
    this.downloadTimeout = const Duration(seconds: 30),
  })  : _client = client ?? createAppHttpIoClient(),
        _ownsClient = client == null,
        _cacheDirectory = cacheDirectory,
        sourceUrl = sourceUrl ?? defaultSourceUrl,
        _now = now ?? DateTime.now;

  static final Uri defaultSourceUrl = Uri.parse(
    'https://anidb.net/api/anime-titles.xml.gz',
  );
  static const String cacheFileName = 'anidb-anime-titles.xml';
  static const String refreshMarkerFileName =
      'anidb-anime-titles.refresh-attempt';

  // The real title dump is comfortably below these bounds. The caps prevent a
  // bad mirror response or gzip bomb from being treated as trusted XML.
  static const int _maxCompressedBytes = 32 * 1024 * 1024;
  static const int _maxExpandedBytes = 128 * 1024 * 1024;
  static const int _maxAnimeRecords = 100000;
  static const int _maxTitlesPerAnime = 256;
  static const int _maxTitleLength = 2048;

  final http.Client _client;
  final bool _ownsClient;
  final Directory? _cacheDirectory;
  final AniDbCatalogNow _now;
  final Uri sourceUrl;
  final Duration cacheTtl;
  final Duration downloadTimeout;

  Map<int, AniDbTitleRecord>? _recordsByAnimeId;
  _AniDbTitleSearchIndex? _titleIndex;
  DateTime? _nextRefreshAt;
  Future<_LoadedTitleCatalog>? _loadFuture;
  bool _closed = false;

  Future<AniDbTitleRecord?> findByAnimeId(int animeId) async {
    if (animeId <= 0) return null;
    return (await _records())[animeId];
  }

  Future<List<AniDbTitleSearchResult>> search(
    String query, {
    int limit = 15,
  }) async {
    if (limit <= 0) return const <AniDbTitleSearchResult>[];
    final String normalizedQuery = TitleNormalizer.normalize(query);
    if (normalizedQuery.isEmpty) {
      return const <AniDbTitleSearchResult>[];
    }

    final Map<int, AniDbTitleRecord> records = await _records();
    final _AniDbTitleSearchIndex index =
        _titleIndex ??= _AniDbTitleSearchIndex(records);
    return index.search(normalizedQuery, limit: limit);
  }

  Future<Map<int, AniDbTitleRecord>> _records() async {
    _ensureOpen();
    final DateTime now = _now();
    final Map<int, AniDbTitleRecord>? cached = _recordsByAnimeId;
    final DateTime? nextRefresh = _nextRefreshAt;
    if (cached != null && nextRefresh != null && now.isBefore(nextRefresh)) {
      return cached;
    }

    final Future<_LoadedTitleCatalog> loading =
        _loadFuture ??= _loadFromDiskOrNetwork();
    try {
      final _LoadedTitleCatalog loaded = await loading;
      _ensureOpen();
      _recordsByAnimeId = loaded.parsed.records;
      // 索引随记录一起在后台 isolate 建好，这里只是接管，不再在 UI isolate
      // 上对十万级标题排序 / 切 n-gram。
      _titleIndex = loaded.parsed.index;
      _nextRefreshAt = loaded.nextRefreshAt;
      return loaded.parsed.records;
    } finally {
      if (identical(_loadFuture, loading)) _loadFuture = null;
    }
  }

  Future<_LoadedTitleCatalog> _loadFromDiskOrNetwork() async {
    final DateTime now = _now();
    final Directory directory = await _resolveCacheDirectory();
    await directory.create(recursive: true);
    final File cacheFile = File(p.join(directory.path, cacheFileName));
    await _recoverInterruptedReplacement(cacheFile);

    DateTime? modifiedAt;
    if (await cacheFile.exists()) {
      modifiedAt = await cacheFile.lastModified();
    }
    final bool isFresh = modifiedAt != null &&
        now.toUtc().difference(modifiedAt.toUtc()) < cacheTtl;

    if (isFresh) {
      try {
        final _ParsedTitleCatalog parsed = await _readCache(cacheFile);
        return _LoadedTitleCatalog(
          parsed: parsed,
          nextRefreshAt: modifiedAt.add(cacheTtl),
        );
      } on Object {
        // A fresh but corrupt cache is not useful. Download a fully validated
        // replacement before changing the live file.
      }
    }

    final File refreshMarker = File(
      p.join(directory.path, refreshMarkerFileName),
    );
    final DateTime? lastAttempt = await refreshMarker.exists()
        ? await refreshMarker.lastModified()
        : null;
    final Duration? sinceAttempt = lastAttempt == null
        ? null
        : now.toUtc().difference(lastAttempt.toUtc());
    final bool attemptedRecently = sinceAttempt != null &&
        (sinceAttempt.isNegative || sinceAttempt < cacheTtl);
    if (attemptedRecently) {
      if (await cacheFile.exists()) {
        try {
          return _LoadedTitleCatalog(
            parsed: await _readCache(cacheFile),
            nextRefreshAt: lastAttempt!.add(cacheTtl),
          );
        } on Object {
          // The persisted daily attempt still gates another download. Report
          // unavailable below instead of hammering AniDB after every restart.
        }
      }
      throw const AniDbTitleCatalogException(
        'AniDB title catalog refresh already attempted within 24 hours',
      );
    }

    Object? downloadError;
    try {
      await _recordRefreshAttempt(refreshMarker, now);
      final _DownloadedTitleCatalog downloaded = await _download();
      await _replaceAtomically(cacheFile, downloaded.cacheBytes);
      await cacheFile.setLastModified(now);
      if (await refreshMarker.exists()) await refreshMarker.delete();
      return _LoadedTitleCatalog(
        parsed: downloaded.parsed,
        nextRefreshAt: now.add(cacheTtl),
      );
    } catch (error) {
      downloadError = error;
    }

    // AniDB explicitly asks consumers not to download this large list more
    // than daily. A stale, parseable snapshot is preferable to losing search.
    if (await cacheFile.exists()) {
      try {
        return _LoadedTitleCatalog(
          parsed: await _readCache(cacheFile),
          nextRefreshAt: now.add(cacheTtl),
        );
      } on Object {
        // Report the refresh failure below; it is the actionable cause.
      }
    }
    if (downloadError is AniDbTitleCatalogException) throw downloadError;
    throw AniDbTitleCatalogException(
      'Unable to load the AniDB title catalog',
      downloadError,
    );
  }

  Future<Directory> _resolveCacheDirectory() async {
    final Directory? configured = _cacheDirectory;
    if (configured != null) return configured;
    final Directory support = await enginePaths.supportRootDirectory();
    return Directory(p.join(support.path, 'video_metadata', 'anidb'));
  }

  Future<void> _recordRefreshAttempt(File marker, DateTime now) async {
    try {
      await marker.writeAsString('', flush: true);
      await marker.setLastModified(now);
    } on Object catch (error) {
      throw AniDbTitleCatalogException(
        'Unable to persist the AniDB daily refresh gate',
        error,
      );
    }
  }

  Future<_DownloadedTitleCatalog> _download() async {
    final http.Response response;
    try {
      response = await _client.get(
        sourceUrl,
        headers: const <String, String>{
          'Accept': 'application/gzip, application/xml;q=0.9, */*;q=0.1',
        },
      ).timeout(downloadTimeout);
    } on Object catch (error) {
      throw AniDbTitleCatalogException(
        'AniDB title catalog download failed',
        error,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AniDbTitleCatalogException(
        'AniDB title catalog returned HTTP ${response.statusCode}',
      );
    }
    final Uint8List body = response.bodyBytes;
    if (body.isEmpty || body.length > _maxCompressedBytes) {
      throw const AniDbTitleCatalogException(
        'AniDB title catalog has an invalid compressed size',
      );
    }
    // \u89E3\u538B + \u89E3\u6790 + \u5EFA\u7D22\u5F15\u6574\u6BB5\u8FDB\u540E\u53F0 isolate\uFF1B\u538B\u7F29\u4F53\u7ECF TransferableTypedData
    // \u96F6\u62F7\u8D1D\u79FB\u4EA4\uFF0C\u4E0D\u5728 UI isolate \u4E0A\u518D\u78B0\u5B83\u3002\u78C1\u76D8\u7F13\u5B58\u76F4\u63A5\u843D\u4E0B\u8F7D\u5230\u7684\u539F\u59CB\u5B57\u8282
    // \uFF08\u901A\u5E38\u662F gzip\uFF0C\u51E0 MB\uFF09\uFF0C\u8BFB\u56DE\u65F6\u6309\u9B54\u6570\u5224\u65AD\u662F\u5426\u89E3\u538B\u2014\u2014\u4E0D\u518D\u628A\u51E0\u5341 MB \u7684
    // \u660E\u6587 XML \u5199\u8FDB\u624B\u673A\u5B58\u50A8\u3002
    final TransferableTypedData transferable = TransferableTypedData.fromList(
      <Uint8List>[body],
    );
    final _ParsedTitleCatalog parsed = await Isolate.run(
      () => _parseTitleCatalogBytes(transferable),
      debugName: 'anidb-title-catalog',
    );
    return _DownloadedTitleCatalog(cacheBytes: body, parsed: parsed);
  }

  Future<_ParsedTitleCatalog> _readCache(File cacheFile) async {
    final int length = await cacheFile.length();
    if (length <= 0 || length > _maxExpandedBytes) {
      throw const AniDbTitleCatalogException(
        'Cached AniDB title catalog has an invalid size',
      );
    }
    // \u6587\u4EF6\u5728\u540E\u53F0 isolate \u91CC\u6D41\u5F0F\u8BFB\u53D6\uFF0CUI isolate \u4E0D\u52A0\u8F7D\u6574\u4EFD\u7F13\u5B58\u3002
    final String path = cacheFile.path;
    return Isolate.run(
      () => _parseTitleCatalogFile(path),
      debugName: 'anidb-title-catalog',
    );
  }

  Future<void> _replaceAtomically(File target, List<int> bytes) async {
    final File temporary = File(
      '${target.path}.tmp.$pid.${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      try {
        await temporary.rename(target.path);
        return;
      } on FileSystemException {
        // Some Windows filesystems do not replace an existing path on rename.
        // Keep a recoverable backup across the two renames in that case.
      }

      final File backup = File('${target.path}.bak');
      if (await backup.exists()) await backup.delete();
      final bool hadTarget = await target.exists();
      if (hadTarget) await target.rename(backup.path);
      try {
        await temporary.rename(target.path);
      } catch (_) {
        if (hadTarget && await backup.exists() && !await target.exists()) {
          await backup.rename(target.path);
        }
        rethrow;
      }
      if (await backup.exists()) await backup.delete();
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> _recoverInterruptedReplacement(File target) async {
    if (await target.exists()) return;
    final File backup = File('${target.path}.bak');
    if (await backup.exists()) await backup.rename(target.path);
  }

  void _ensureOpen() {
    if (_closed) throw StateError('AniDbTitleCatalog is closed');
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _recordsByAnimeId = null;
    _titleIndex = null;
    _nextRefreshAt = null;
    if (_ownsClient) _client.close();
  }
}

bool _looksLikeGzip(List<int> bytes) =>
    bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b;

/// 后台 isolate 入口：解析刚下载的压缩体（或明文 XML）。
Future<_ParsedTitleCatalog> _parseTitleCatalogBytes(
  TransferableTypedData transferable,
) {
  final Uint8List bytes = transferable.materialize().asUint8List();
  return _parseTitleCatalogSource(
    Stream<List<int>>.value(bytes),
    isGzip: _looksLikeGzip(bytes),
  );
}

/// 后台 isolate 入口：流式读取磁盘缓存（压缩或明文均可）。
Future<_ParsedTitleCatalog> _parseTitleCatalogFile(String path) async {
  final File file = File(path);
  final RandomAccessFile handle = await file.open();
  final List<int> magic;
  try {
    magic = await handle.read(2);
  } finally {
    await handle.close();
  }
  return _parseTitleCatalogSource(file.openRead(),
      isGzip: _looksLikeGzip(magic));
}

/// 解压 → UTF-8 解码 → XML 事件流 → 记录 → 索引，全程分块，不把整份 XML
/// 明文或 DOM 留在内存里。异常一律收敛成 [AniDbTitleCatalogException]
/// 且 `cause` 只带字符串：它要跨 isolate 边界传回来。
Future<_ParsedTitleCatalog> _parseTitleCatalogSource(
  Stream<List<int>> source, {
  required bool isGzip,
}) async {
  int expandedBytes = 0;
  Stream<List<int>> expanded = isGzip ? source.transform(gzip.decoder) : source;
  expanded = expanded.map((List<int> chunk) {
    expandedBytes += chunk.length;
    if (expandedBytes > AniDbTitleCatalog._maxExpandedBytes) {
      throw const AniDbTitleCatalogException(
        'AniDB title catalog has an invalid expanded size',
      );
    }
    return chunk;
  });
  // validateNesting：错位的闭合标签必须像 DOM 版一样报「invalid XML」，而不是
  // 静默滑过去、解析出一份空目录。
  final Stream<XmlEvent> events = expanded
      .transform(utf8.decoder)
      .transform(XmlEventDecoder(validateNesting: true))
      .flatten();

  final _TitleCatalogBuilder builder = _TitleCatalogBuilder();
  try {
    await for (final XmlEvent event in events) {
      builder.accept(event);
    }
  } on AniDbTitleCatalogException {
    rethrow;
  } on XmlException catch (error) {
    throw AniDbTitleCatalogException(
      'AniDB title catalog contains invalid XML',
      error.toString(),
    );
  } on FormatException catch (error) {
    // gzip 与 UTF-8 解码器都抛 FormatException；哪一层坏了对调用方没有区别，
    // 都是「这份包不能用」。
    throw AniDbTitleCatalogException(
      'AniDB title catalog is not valid gzip / UTF-8 data',
      error.toString(),
    );
  } on Object catch (error) {
    throw AniDbTitleCatalogException(
      'Unable to parse the AniDB title catalog',
      error.toString(),
    );
  }
  if (expandedBytes == 0) {
    throw const AniDbTitleCatalogException(
      'AniDB title catalog has an invalid expanded size',
    );
  }
  final Map<int, AniDbTitleRecord> records = builder.finish();
  return _ParsedTitleCatalog(
    records: records,
    index: _AniDbTitleSearchIndex(records),
  );
}

/// 把 `<animetitles><anime aid><title type xml:lang>…` 的事件流累积成记录。
/// 与原 DOM 版保持同一套上限与过滤规则（记录数 / 每部标题数 / 标题长度 /
/// 同值同类型同语言去重）。
class _TitleCatalogBuilder {
  final Map<int, List<AniDbTitle>> _titlesByAnime = <int, List<AniDbTitle>>{};
  final List<String> _open = <String>[];
  bool _rootSeen = false;
  int _recordCount = 0;

  List<AniDbTitle>? _currentTitles;
  int _currentTitleCount = 0;
  bool _inTitle = false;
  String _titleType = '';
  String _titleLanguage = '';
  final StringBuffer _titleText = StringBuffer();

  void accept(XmlEvent event) {
    if (event is XmlDoctypeEvent) {
      // 只接受纯数据文档：DOCTYPE / ENTITY 声明一律视为不可信输入。
      throw const AniDbTitleCatalogException(
        'AniDB title catalog contains a forbidden declaration',
      );
    }
    if (event is XmlStartElementEvent) {
      _start(event);
    } else if (event is XmlEndElementEvent) {
      _end(event.localName);
    } else if (event is XmlTextEvent) {
      if (_inTitle) _titleText.write(event.value);
    } else if (event is XmlCDATAEvent) {
      if (_inTitle) _titleText.write(event.value);
    }
  }

  void _start(XmlStartElementEvent event) {
    final String name = event.localName;
    if (!_rootSeen) {
      _rootSeen = true;
      if (name != 'animetitles') {
        throw const AniDbTitleCatalogException(
          'AniDB title catalog has an unexpected root element',
        );
      }
    } else if (_open.length == 1 && name == 'anime') {
      _recordCount++;
      if (_recordCount > AniDbTitleCatalog._maxAnimeRecords) {
        throw const AniDbTitleCatalogException(
          'AniDB title catalog contains too many anime records',
        );
      }
      final int? animeId = int.tryParse(_attribute(event, 'aid') ?? '');
      _currentTitles = animeId == null || animeId <= 0
          ? null
          : _titlesByAnime.putIfAbsent(animeId, () => <AniDbTitle>[]);
      _currentTitleCount = 0;
    } else if (_open.length == 2 &&
        _open[1] == 'anime' &&
        name == 'title' &&
        _currentTitles != null) {
      _currentTitleCount++;
      if (_currentTitleCount > AniDbTitleCatalog._maxTitlesPerAnime) {
        throw const AniDbTitleCatalogException(
          'AniDB title catalog contains too many titles for one anime',
        );
      }
      _inTitle = true;
      _titleType = (_attribute(event, 'type') ?? '').trim().toLowerCase();
      _titleLanguage = _xmlLanguage(event);
      _titleText.clear();
    }
    // 自闭合元素（`<title/>` / `<anime/>`）只有 start 事件、没有 end 事件；
    // 必须先入栈再走 _end，否则 removeLast() 弹掉的是父级，之后整份目录静默截断。
    _open.add(name);
    if (event.isSelfClosing) _end(name);
  }

  void _end(String name) {
    if (_inTitle && name == 'title' && _open.length == 3) {
      _finishTitle();
    } else if (name == 'anime' && _open.length == 2) {
      _currentTitles = null;
    }
    if (_open.isNotEmpty) _open.removeLast();
  }

  void _finishTitle() {
    _inTitle = false;
    final List<AniDbTitle>? titles = _currentTitles;
    final String value = _titleText.toString().trim();
    _titleText.clear();
    if (titles == null) return;
    if (value.isEmpty || value.length > AniDbTitleCatalog._maxTitleLength) {
      return;
    }
    final String type = _titleType;
    final String language = _titleLanguage;
    if (type.isEmpty || language.isEmpty) return;
    final bool duplicate = titles.any(
      (AniDbTitle title) =>
          title.value == value &&
          title.type == type &&
          title.language == language,
    );
    if (!duplicate) {
      titles.add(AniDbTitle(value: value, type: type, language: language));
    }
  }

  Map<int, AniDbTitleRecord> finish() {
    final Map<int, AniDbTitleRecord> records = <int, AniDbTitleRecord>{};
    final List<int> animeIds = _titlesByAnime.keys.toList()..sort();
    for (final int animeId in animeIds) {
      final List<AniDbTitle> titles = _titlesByAnime[animeId]!;
      if (titles.isNotEmpty) {
        records[animeId] = AniDbTitleRecord(animeId: animeId, titles: titles);
      }
    }
    if (records.isEmpty) {
      throw const AniDbTitleCatalogException(
        'AniDB title catalog contains no usable records',
      );
    }
    return Map<int, AniDbTitleRecord>.unmodifiable(records);
  }

  static String? _attribute(XmlStartElementEvent event, String name) {
    for (final XmlEventAttribute attribute in event.attributes) {
      if (attribute.name == name) return attribute.value;
    }
    return null;
  }

  /// 与 DOM 版 `getAttribute('xml:lang') ?? getAttribute('lang', namespace: xml)`
  /// 同义：只认 XML 命名空间下的 lang，裸 `lang` 不算。
  static String _xmlLanguage(XmlStartElementEvent event) {
    for (final XmlEventAttribute attribute in event.attributes) {
      if (attribute.localName == 'lang' && attribute.namespacePrefix == 'xml') {
        return attribute.value.trim();
      }
    }
    return '';
  }
}

Set<String> _normalizedGrams(String value) {
  final List<int> runes =
      value.runes.where((int rune) => rune != 0x20).toList(growable: false);
  if (runes.isEmpty) return const <String>{};
  final int width = runes.length >= 3 ? 3 : runes.length;
  final int count = runes.length - width + 1;
  final int stride = count <= 48 ? 1 : (count / 48).ceil();
  return <String>{
    for (int offset = 0; offset < count; offset += stride)
      String.fromCharCodes(runes.sublist(offset, offset + width)),
    if ((count - 1) % stride != 0)
      String.fromCharCodes(runes.sublist(count - 1, count - 1 + width)),
  };
}

bool _isFuzzyCandidate(
  String query,
  Set<String> queryTokens,
  String candidate,
) {
  final int longer =
      query.length > candidate.length ? query.length : candidate.length;
  final int shorter =
      query.length < candidate.length ? query.length : candidate.length;
  if (longer == 0 || shorter / longer < 0.45) return false;
  if (candidate.contains(query) || query.contains(candidate)) return true;
  for (final String token in queryTokens) {
    if (token.length >= 2 && candidate.contains(token)) return true;
  }
  return shorter / longer >= 0.7 && query.runes.first == candidate.runes.first;
}

int _compareWithinRecord(
  AniDbTitleSearchResult left,
  AniDbTitleSearchResult right,
) {
  final int kind = left.kind.index.compareTo(right.kind.index);
  if (kind != 0) return kind;
  final int similarity = right.similarity.compareTo(left.similarity);
  if (similarity != 0) return similarity;
  return _titleTypePriority(
    left.matchedTitle.type,
  ).compareTo(_titleTypePriority(right.matchedTitle.type));
}

int _compareSearchResults(
  AniDbTitleSearchResult left,
  AniDbTitleSearchResult right,
) {
  final int within = _compareWithinRecord(left, right);
  if (within != 0) return within;
  final int titleLength = left.matchedTitle.value.length.compareTo(
    right.matchedTitle.value.length,
  );
  if (titleLength != 0) return titleLength;
  return left.record.animeId.compareTo(right.record.animeId);
}

int _titleTypePriority(String type) => switch (type) {
      'main' => 0,
      'official' => 1,
      'syn' || 'synonym' => 2,
      'short' => 3,
      _ => 4,
    };

class _AniDbIndexedTitle {
  const _AniDbIndexedTitle({required this.record, required this.title});

  final AniDbTitleRecord record;
  final AniDbTitle title;
}

/// Shoko builds a reusable fuzzy index for the daily title dump. This compact
/// Dart equivalent keeps exact/prefix lookups off the all-title scan and only
/// enters fuzzy scoring for a bounded n-gram candidate pool (with a first-rune
/// fallback for very short/no-overlap queries) after precise lookup fails. That
/// keeps normal library batches proportional to query results, rather than
/// `works × every AniDB title × Levenshtein`.
class _AniDbTitleSearchIndex {
  _AniDbTitleSearchIndex(Map<int, AniDbTitleRecord> records) {
    for (final AniDbTitleRecord record in records.values) {
      for (final AniDbTitle title in record.titles) {
        final String normalized = title.normalizedValue;
        if (normalized.isEmpty) continue;
        final _AniDbIndexedTitle entry = _AniDbIndexedTitle(
          record: record,
          title: title,
        );
        _sorted.add(entry);
        _exact.putIfAbsent(normalized, () => <_AniDbIndexedTitle>[]).add(entry);
        _byFirstRune
            .putIfAbsent(normalized.runes.first, () => <_AniDbIndexedTitle>[])
            .add(entry);
        for (final String gram in _normalizedGrams(normalized)) {
          _byGram.putIfAbsent(gram, () => <_AniDbIndexedTitle>[]).add(entry);
        }
      }
    }
    _sorted.sort((_AniDbIndexedTitle left, _AniDbIndexedTitle right) {
      final int title = left.title.normalizedValue.compareTo(
        right.title.normalizedValue,
      );
      return title != 0
          ? title
          : left.record.animeId.compareTo(right.record.animeId);
    });
  }

  static const int _maxPrefixEntries = 8192;

  final Map<String, List<_AniDbIndexedTitle>> _exact =
      <String, List<_AniDbIndexedTitle>>{};
  final Map<int, List<_AniDbIndexedTitle>> _byFirstRune =
      <int, List<_AniDbIndexedTitle>>{};
  final Map<String, List<_AniDbIndexedTitle>> _byGram =
      <String, List<_AniDbIndexedTitle>>{};
  final List<_AniDbIndexedTitle> _sorted = <_AniDbIndexedTitle>[];

  List<AniDbTitleSearchResult> search(
    String normalizedQuery, {
    required int limit,
  }) {
    final Set<_AniDbIndexedTitle> preciseEntries = <_AniDbIndexedTitle>{
      ...?_exact[normalizedQuery],
    };
    int cursor = _lowerBound(normalizedQuery);
    int visited = 0;
    while (cursor < _sorted.length && visited < _maxPrefixEntries) {
      final _AniDbIndexedTitle entry = _sorted[cursor++];
      if (!entry.title.normalizedValue.startsWith(normalizedQuery)) break;
      preciseEntries.add(entry);
      visited++;
    }
    if (preciseEntries.isNotEmpty) {
      return _rank(
        preciseEntries,
        limit: limit,
        kindFor: (_AniDbIndexedTitle entry) =>
            entry.title.normalizedValue == normalizedQuery
                ? AniDbTitleMatchKind.exact
                : AniDbTitleMatchKind.prefix,
        query: normalizedQuery,
      );
    }

    final Set<String> queryTokens = TitleNormalizer.tokens(
      normalizedQuery,
    ).toSet();
    final Map<_AniDbIndexedTitle, int> gramHits = <_AniDbIndexedTitle, int>{};
    for (final String gram in _normalizedGrams(normalizedQuery)) {
      for (final _AniDbIndexedTitle entry
          in _byGram[gram] ?? const <_AniDbIndexedTitle>[]) {
        gramHits.update(entry, (int value) => value + 1, ifAbsent: () => 1);
      }
    }
    final List<_AniDbIndexedTitle> candidates = gramHits.isEmpty
        ? (_byFirstRune[normalizedQuery.runes.first] ??
            const <_AniDbIndexedTitle>[])
        : (gramHits.keys.toList()
          ..sort(
            (_AniDbIndexedTitle left, _AniDbIndexedTitle right) =>
                gramHits[right]!.compareTo(gramHits[left]!),
          ));
    return _rank(
      candidates.take(20000).where(
            (_AniDbIndexedTitle entry) => _isFuzzyCandidate(
              normalizedQuery,
              queryTokens,
              entry.title.normalizedValue,
            ),
          ),
      limit: limit,
      kindFor: (_) => AniDbTitleMatchKind.similar,
      query: normalizedQuery,
      minimumSimilarity: 0.2,
    );
  }

  List<AniDbTitleSearchResult> _rank(
    Iterable<_AniDbIndexedTitle> entries, {
    required int limit,
    required AniDbTitleMatchKind Function(_AniDbIndexedTitle entry) kindFor,
    required String query,
    double minimumSimilarity = 0,
  }) {
    final Map<int, AniDbTitleSearchResult> bestByAnime =
        <int, AniDbTitleSearchResult>{};
    for (final _AniDbIndexedTitle entry in entries) {
      final AniDbTitleMatchKind kind = kindFor(entry);
      // query 与索引条目都已是归一化值，直接打分，不再逐字符重归一化。
      final double similarity = kind == AniDbTitleMatchKind.exact
          ? 1
          : TitleNormalizer.similarityNormalized(
              query,
              entry.title.normalizedValue,
            );
      if (similarity < minimumSimilarity) continue;
      final AniDbTitleSearchResult candidate = AniDbTitleSearchResult(
        record: entry.record,
        matchedTitle: entry.title,
        kind: kind,
        similarity: similarity,
      );
      final AniDbTitleSearchResult? existing =
          bestByAnime[entry.record.animeId];
      if (existing == null || _compareWithinRecord(candidate, existing) < 0) {
        bestByAnime[entry.record.animeId] = candidate;
      }
    }
    final List<AniDbTitleSearchResult> ranked = bestByAnime.values.toList()
      ..sort(_compareSearchResults);
    return ranked.take(limit).toList(growable: false);
  }

  int _lowerBound(String query) {
    int low = 0;
    int high = _sorted.length;
    while (low < high) {
      final int middle = low + ((high - low) >> 1);
      if (_sorted[middle].title.normalizedValue.compareTo(query) < 0) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }
}

/// 后台 isolate 解析产物：记录表 + 已建好的搜索索引，经 `Isolate.exit`
/// 整图移交回调用 isolate。
class _ParsedTitleCatalog {
  const _ParsedTitleCatalog({required this.records, required this.index});

  final Map<int, AniDbTitleRecord> records;
  final _AniDbTitleSearchIndex index;
}

class _LoadedTitleCatalog {
  const _LoadedTitleCatalog({
    required this.parsed,
    required this.nextRefreshAt,
  });

  final _ParsedTitleCatalog parsed;
  final DateTime nextRefreshAt;
}

class _DownloadedTitleCatalog {
  const _DownloadedTitleCatalog({
    required this.cacheBytes,
    required this.parsed,
  });

  /// 原样落盘的下载体（通常是 gzip）。
  final Uint8List cacheBytes;
  final _ParsedTitleCatalog parsed;
}
