/// AniDB 官方动画标题目录。
///
/// 与 Shoko 的 `AniDBTitleHelper` 保持同一数据边界：标题识别只依赖 AniDB 每日
/// 标题包，不需要（也不允许伪造）HTTP API client 身份。目录在磁盘缓存 24 小时，
/// 更新先完整解压、解析并写入临时文件，再以 rename 替换；刷新失败时继续使用旧包。
///
/// 解压、解析、建索引整段都在后台 isolate 里跑（[Isolate.run]）：之前在 UI isolate 上
/// 整段同步解析 + 建 DOM，手机上一次「按作品归类」导入就是数秒到数十秒的整机冻结。
/// 解析与索引在 Rust 计算内核里（`AniDbCatalogBuilderNative`，
/// native/fushi_compute/src/parse/anidb/）：后台 isolate 把 gzip 解压出的每一块原样喂给
/// 原生构建器（流式，不在 Dart 堆里留整份明文或 DOM），建好的目录驻留原生内存，句柄地址
/// 交回调用 isolate 接管；搜索是对该句柄的一次 FFI 调用。记录对象（[AniDbTitleRecord]）
/// 也在同一个后台 isolate 里一次物化：借出原生目录的扁平记录表（原生内存上的零拷贝视图，
/// 一次 FFI），整表解码成按 id 的 Map 随句柄经 Isolate.exit 交回——按 id 取记录与搜索命中
/// 取记录都只是一次 Map 查找，不逐条跨 FFI、也不在 UI isolate 上解码。
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart'
    show
        AniDbCatalogBuilderNative,
        AniDbCatalogNative,
        AniDbCatalogNativeError,
        AniDbNativeSearchHit;
import 'package:fushi_engine/media/video/scraper/title_normalizer.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:fushi_engine/foundation/engine_paths.dart';

typedef AniDbCatalogNow = DateTime Function();

class AniDbTitle {
  AniDbTitle({required this.value, required this.type, required this.language});

  AniDbTitle._catalog({
    required this.value,
    required this.type,
    required this.language,
    required String normalizedValue,
  }) : _normalizedValue = normalizedValue;

  final String value;

  /// AniDB title type as published by the title dump (`main`, `official`,
  /// `syn`, `short`, ...). It is deliberately not translated into UI terms.
  final String type;

  /// The unmodified `xml:lang` value from AniDB.
  final String language;

  String? _normalizedValue;

  /// [TitleNormalizer.normalize] of [value]. Catalog titles carry the value
  /// computed when the daily dump was indexed; other titles normalize lazily.
  String get normalizedValue =>
      _normalizedValue ??= TitleNormalizer.normalize(value);
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
  }) : _client = client ?? createAppHttpIoClient(),
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
  // bad mirror response or gzip bomb from being treated as trusted XML. The
  // per-record caps (100000 anime records, 256 titles per anime, 2048 UTF-16
  // units per title) live in the native builder (catalog.rs).
  static const int _maxCompressedBytes = 32 * 1024 * 1024;
  static const int _maxExpandedBytes = 128 * 1024 * 1024;

  final http.Client _client;
  final bool _ownsClient;
  final Directory? _cacheDirectory;
  final AniDbCatalogNow _now;
  final Uri sourceUrl;
  final Duration cacheTtl;
  final Duration downloadTimeout;

  AniDbCatalogNative? _catalog;
  Map<int, AniDbTitleRecord> _recordsById = const <int, AniDbTitleRecord>{};
  DateTime? _nextRefreshAt;
  Future<_LoadedTitleCatalog>? _loadFuture;
  bool _closed = false;

  Future<AniDbTitleRecord?> findByAnimeId(int animeId) async {
    if (animeId <= 0) return null;
    await _records();
    _ensureOpen();
    return _recordsById[animeId];
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

    final AniDbCatalogNative catalog = await _records();
    _ensureOpen();
    final List<AniDbNativeSearchHit> hits = catalog.search(
      normalizedQuery,
      limit,
    );
    return <AniDbTitleSearchResult>[
      for (final AniDbNativeSearchHit hit in hits) _result(hit),
    ];
  }

  /// 同一份目录里同一 id 总是同一个 [AniDbTitleRecord]（搜索结果的 matchedTitle 与
  /// record.titles 的元素是同一对象）。
  AniDbTitleSearchResult _result(AniDbNativeSearchHit hit) {
    final AniDbTitleRecord record = _recordsById[hit.animeId]!;
    return AniDbTitleSearchResult(
      record: record,
      matchedTitle: record.titles[hit.titleIndex],
      kind: AniDbTitleMatchKind.values[hit.kind],
      similarity: hit.similarity,
    );
  }

  Future<AniDbCatalogNative> _records() async {
    _ensureOpen();
    final DateTime now = _now();
    final AniDbCatalogNative? cached = _catalog;
    final DateTime? nextRefresh = _nextRefreshAt;
    if (cached != null && nextRefresh != null && now.isBefore(nextRefresh)) {
      return cached;
    }

    final Future<_LoadedTitleCatalog> loading = _loadFuture ??=
        _loadFromDiskOrNetwork();
    try {
      final _LoadedTitleCatalog loaded = await loading;
      _ensureOpen();
      final AniDbCatalogNative catalog = loaded.parsed.catalog;
      if (!identical(_catalog, catalog)) {
        // 换了一份目录：记录表跟着换，旧原生目录立即释放（所有调用都在本 isolate
        // 同步完成，不存在还在用旧句柄的 FFI 调用）。
        _catalog?.dispose();
        _catalog = catalog;
        _recordsById = loaded.parsed.records;
      }
      _nextRefreshAt = loaded.nextRefreshAt;
      return catalog;
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
    final bool isFresh =
        modifiedAt != null &&
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
    final bool attemptedRecently =
        sinceAttempt != null &&
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
      response = await _client
          .get(
            sourceUrl,
            headers: const <String, String>{
              'Accept': 'application/gzip, application/xml;q=0.9, */*;q=0.1',
            },
          )
          .timeout(downloadTimeout);
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
    // 解压 + 解析 + 建索引整段进后台 isolate；压缩体经 TransferableTypedData
    // 零拷贝移交，不在 UI isolate 上再碰它。磁盘缓存直接落下载到的原始字节
    // （通常是 gzip，几 MB），读回时按魔数判断是否解压——不再把几十 MB 的
    // 明文 XML 写进手机存储。
    final TransferableTypedData transferable = TransferableTypedData.fromList(
      <Uint8List>[body],
    );
    final _ParsedPayload payload = await Isolate.run(
      () => _parseTitleCatalogBytes(transferable),
      debugName: 'anidb-title-catalog',
    );
    return _DownloadedTitleCatalog(cacheBytes: body, parsed: payload.adopt());
  }

  Future<_ParsedTitleCatalog> _readCache(File cacheFile) async {
    final int length = await cacheFile.length();
    if (length <= 0 || length > _maxExpandedBytes) {
      throw const AniDbTitleCatalogException(
        'Cached AniDB title catalog has an invalid size',
      );
    }
    // 文件在后台 isolate 里流式读取，UI isolate 不加载整份缓存。
    final String path = cacheFile.path;
    final _ParsedPayload payload = await Isolate.run(
      () => _parseTitleCatalogFile(path),
      debugName: 'anidb-title-catalog',
    );
    return payload.adopt();
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
    _catalog?.dispose();
    _catalog = null;
    _recordsById = const <int, AniDbTitleRecord>{};
    _nextRefreshAt = null;
    if (_ownsClient) _client.close();
  }
}

bool _looksLikeGzip(List<int> bytes) =>
    bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b;

/// 后台 isolate 入口：解析刚下载的压缩体（或明文 XML），返回原生目录句柄地址与物化好的记录。
Future<_ParsedPayload> _parseTitleCatalogBytes(
  TransferableTypedData transferable,
) {
  final Uint8List bytes = transferable.materialize().asUint8List();
  return _parseTitleCatalogSource(
    Stream<List<int>>.value(bytes),
    isGzip: _looksLikeGzip(bytes),
  );
}

/// 后台 isolate 入口：流式读取磁盘缓存（压缩或明文均可），返回原生目录句柄地址与物化好的记录。
Future<_ParsedPayload> _parseTitleCatalogFile(String path) async {
  final File file = File(path);
  final RandomAccessFile handle = await file.open();
  final List<int> magic;
  try {
    magic = await handle.read(2);
  } finally {
    await handle.close();
  }
  return _parseTitleCatalogSource(
    file.openRead(),
    isGzip: _looksLikeGzip(magic),
  );
}

/// 解压 → 逐块喂给原生构建器（UTF-8 解码、XML 事件、记录、索引都在 Rust 里），
/// 全程分块。异常一律收敛成 [AniDbTitleCatalogException] 且 `cause` 只带字符串：
/// 它要跨 isolate 边界传回来。成功时返回目录句柄地址——原生内存是进程级的，地址
/// 在接管它的 isolate 里依然有效；由调用方 [_ParsedPayload.adopt] 恰好接管一次——以及
/// 在本 isolate 里从记录表一次物化好的全部记录。
Future<_ParsedPayload> _parseTitleCatalogSource(
  Stream<List<int>> source, {
  required bool isGzip,
}) async {
  int expandedBytes = 0;
  final Stream<List<int>> expanded = isGzip
      ? source.transform(gzip.decoder)
      : source;
  final AniDbCatalogBuilderNative builder = AniDbCatalogBuilderNative();
  try {
    try {
      await for (final List<int> chunk in expanded) {
        expandedBytes += chunk.length;
        if (expandedBytes > AniDbTitleCatalog._maxExpandedBytes) {
          throw const AniDbTitleCatalogException(
            'AniDB title catalog has an invalid expanded size',
          );
        }
        builder.add(chunk);
      }
      builder.close();
    } on AniDbTitleCatalogException {
      rethrow;
    } on AniDbCatalogNativeError catch (error) {
      throw _catalogException(error);
    } on FormatException catch (error) {
      // gzip 解码器抛 FormatException（UTF-8 坏数据由原生构建器报种类 6）；哪一层坏了
      // 对调用方没有区别，都是「这份包不能用」。
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
    final int address;
    try {
      address = builder.finish();
    } on AniDbCatalogNativeError catch (error) {
      throw _catalogException(error);
    }
    try {
      return _ParsedPayload(
        address,
        AniDbCatalogNative.borrow(address, _materializeRecords),
      );
    } catch (error) {
      AniDbCatalogNative.adopt(address).dispose();
      throw AniDbTitleCatalogException(
        'Unable to parse the AniDB title catalog',
        error.toString(),
      );
    }
  } finally {
    builder.dispose();
  }
}

/// 把整张记录表解码成按 id 的 [AniDbTitleRecord]（一次 FFI 借出记录表，之后纯 Dart）。
Map<int, AniDbTitleRecord> _materializeRecords(AniDbCatalogNative catalog) {
  final Map<int, AniDbTitleRecord> records = <int, AniDbTitleRecord>{};
  final int count = catalog.recordCount;
  for (int i = 0; i < count; i++) {
    final int animeId = catalog.animeIdAt(i);
    records[animeId] = AniDbTitleRecord(
      animeId: animeId,
      titles: catalog.recordTitlesAt(i, _catalogTitle),
    );
  }
  return records;
}

AniDbTitle _catalogTitle(
  String value,
  String type,
  String language,
  String normalized,
) => AniDbTitle._catalog(
  value: value,
  type: type,
  language: language,
  normalizedValue: normalized,
);

AniDbTitleCatalogException _catalogException(
  AniDbCatalogNativeError error,
) => switch (error.kind) {
  AniDbCatalogNativeError.forbiddenDeclaration =>
    const AniDbTitleCatalogException(
      'AniDB title catalog contains a forbidden declaration',
    ),
  AniDbCatalogNativeError.unexpectedRoot => const AniDbTitleCatalogException(
    'AniDB title catalog has an unexpected root element',
  ),
  AniDbCatalogNativeError.tooManyRecords => const AniDbTitleCatalogException(
    'AniDB title catalog contains too many anime records',
  ),
  AniDbCatalogNativeError.tooManyTitles => const AniDbTitleCatalogException(
    'AniDB title catalog contains too many titles for one anime',
  ),
  AniDbCatalogNativeError.invalidXml => AniDbTitleCatalogException(
    'AniDB title catalog contains invalid XML',
    error.detail,
  ),
  AniDbCatalogNativeError.invalidData => AniDbTitleCatalogException(
    'AniDB title catalog is not valid gzip / UTF-8 data',
    error.detail,
  ),
  AniDbCatalogNativeError.noUsableRecords => const AniDbTitleCatalogException(
    'AniDB title catalog contains no usable records',
  ),
  _ => AniDbTitleCatalogException(
    'Unable to parse the AniDB title catalog',
    error.toString(),
  ),
};

/// 后台 isolate 交回的解析产物：原生目录句柄地址 + 物化好的记录（经 Isolate.exit 原样移交）。
class _ParsedPayload {
  const _ParsedPayload(this.address, this.records);

  final int address;
  final Map<int, AniDbTitleRecord> records;

  /// 在调用 isolate 里接管句柄（每份产物恰好一次）。
  _ParsedTitleCatalog adopt() =>
      _ParsedTitleCatalog(AniDbCatalogNative.adopt(address), records);
}

/// 后台 isolate 解析产物在调用 isolate 里接管后的形态。
class _ParsedTitleCatalog {
  const _ParsedTitleCatalog(this.catalog, this.records);

  final AniDbCatalogNative catalog;
  final Map<int, AniDbTitleRecord> records;
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
