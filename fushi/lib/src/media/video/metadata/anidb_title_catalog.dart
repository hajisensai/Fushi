/// AniDB 官方动画标题目录。
///
/// 与 Shoko 的 `AniDBTitleHelper` 保持同一数据边界：标题识别只依赖 AniDB 每日
/// 标题包，不需要（也不允许伪造）HTTP API client 身份。目录在磁盘缓存 24 小时，
/// 更新先完整解压、解析并写入临时文件，再以 rename 替换；刷新失败时继续使用旧包。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi/src/media/video/scraper/title_normalizer.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/utils/net/app_http.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

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
      _recordsByAnimeId = loaded.records;
      _titleIndex = _AniDbTitleSearchIndex(loaded.records);
      _nextRefreshAt = loaded.nextRefreshAt;
      return loaded.records;
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
        final Map<int, AniDbTitleRecord> records = await _readCache(cacheFile);
        return _LoadedTitleCatalog(
          records: records,
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
            records: await _readCache(cacheFile),
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
      await _replaceAtomically(cacheFile, downloaded.xmlBytes);
      await cacheFile.setLastModified(now);
      if (await refreshMarker.exists()) await refreshMarker.delete();
      return _LoadedTitleCatalog(
        records: downloaded.records,
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
          records: await _readCache(cacheFile),
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
    final Directory support = await AppPaths.supportRootDirectory();
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
    final List<int> body = response.bodyBytes;
    if (body.isEmpty || body.length > _maxCompressedBytes) {
      throw const AniDbTitleCatalogException(
        'AniDB title catalog has an invalid compressed size',
      );
    }
    final List<int> expanded;
    try {
      expanded = _looksLikeGzip(body) ? gzip.decode(body) : body;
    } on Object catch (error) {
      throw AniDbTitleCatalogException(
        'AniDB title catalog is not valid gzip data',
        error,
      );
    }
    if (expanded.isEmpty || expanded.length > _maxExpandedBytes) {
      throw const AniDbTitleCatalogException(
        'AniDB title catalog has an invalid expanded size',
      );
    }
    final String xml = _decodeXml(expanded);
    return _DownloadedTitleCatalog(
      xmlBytes: utf8.encode(xml),
      records: _parseXml(xml),
    );
  }

  Future<Map<int, AniDbTitleRecord>> _readCache(File cacheFile) async {
    final int length = await cacheFile.length();
    if (length <= 0 || length > _maxExpandedBytes) {
      throw const AniDbTitleCatalogException(
        'Cached AniDB title catalog has an invalid size',
      );
    }
    final List<int> bytes = await cacheFile.readAsBytes();
    final List<int> expanded;
    try {
      expanded = _looksLikeGzip(bytes) ? gzip.decode(bytes) : bytes;
    } on Object catch (error) {
      throw AniDbTitleCatalogException(
        'Cached AniDB title catalog is invalid gzip data',
        error,
      );
    }
    if (expanded.length > _maxExpandedBytes) {
      throw const AniDbTitleCatalogException(
        'Cached AniDB title catalog is too large',
      );
    }
    return _parseXml(_decodeXml(expanded));
  }

  String _decodeXml(List<int> bytes) {
    try {
      final String value = utf8.decode(bytes);
      return value.startsWith('\uFEFF') ? value.substring(1) : value;
    } on FormatException catch (error) {
      throw AniDbTitleCatalogException(
        'AniDB title catalog is not valid UTF-8',
        error,
      );
    }
  }

  Map<int, AniDbTitleRecord> _parseXml(String xml) {
    if (RegExp(
      r'<!\s*(?:DOCTYPE|ENTITY)\b',
      caseSensitive: false,
    ).hasMatch(xml)) {
      throw const AniDbTitleCatalogException(
        'AniDB title catalog contains a forbidden declaration',
      );
    }

    final XmlDocument document;
    try {
      document = XmlDocument.parse(xml);
    } on XmlParserException catch (error) {
      throw AniDbTitleCatalogException(
        'AniDB title catalog contains invalid XML',
        error,
      );
    }
    final XmlElement root = document.rootElement;
    if (root.name.local != 'animetitles') {
      throw const AniDbTitleCatalogException(
        'AniDB title catalog has an unexpected root element',
      );
    }

    final Map<int, List<AniDbTitle>> titlesByAnime = <int, List<AniDbTitle>>{};
    int recordCount = 0;
    for (final XmlElement anime in root.findElements('anime')) {
      recordCount++;
      if (recordCount > _maxAnimeRecords) {
        throw const AniDbTitleCatalogException(
          'AniDB title catalog contains too many anime records',
        );
      }
      final int? animeId = int.tryParse(anime.getAttribute('aid') ?? '');
      if (animeId == null || animeId <= 0) continue;
      final List<AniDbTitle> titles = titlesByAnime.putIfAbsent(
        animeId,
        () => <AniDbTitle>[],
      );
      int titleCount = 0;
      for (final XmlElement element in anime.findElements('title')) {
        titleCount++;
        if (titleCount > _maxTitlesPerAnime) {
          throw const AniDbTitleCatalogException(
            'AniDB title catalog contains too many titles for one anime',
          );
        }
        final String value = element.innerText.trim();
        if (value.isEmpty || value.length > _maxTitleLength) continue;
        final String type =
            (element.getAttribute('type') ?? '').trim().toLowerCase();
        final String language = _xmlLanguage(element);
        if (type.isEmpty || language.isEmpty) continue;
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
    }

    final Map<int, AniDbTitleRecord> records = <int, AniDbTitleRecord>{};
    final List<int> animeIds = titlesByAnime.keys.toList()..sort();
    for (final int animeId in animeIds) {
      final List<AniDbTitle> titles = titlesByAnime[animeId]!;
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

String _xmlLanguage(XmlElement element) => (element.getAttribute('xml:lang') ??
        element.getAttribute(
          'lang',
          namespace: 'http://www.w3.org/XML/1998/namespace',
        ) ??
        '')
    .trim();

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
      final double similarity = kind == AniDbTitleMatchKind.exact
          ? 1
          : TitleNormalizer.similarity(query, entry.title.normalizedValue);
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

class _LoadedTitleCatalog {
  const _LoadedTitleCatalog({
    required this.records,
    required this.nextRefreshAt,
  });

  final Map<int, AniDbTitleRecord> records;
  final DateTime nextRefreshAt;
}

class _DownloadedTitleCatalog {
  const _DownloadedTitleCatalog({
    required this.xmlBytes,
    required this.records,
  });

  final List<int> xmlBytes;
  final Map<int, AniDbTitleRecord> records;
}
