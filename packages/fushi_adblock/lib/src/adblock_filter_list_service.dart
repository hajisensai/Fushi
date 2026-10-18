import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 一份可订阅的过滤列表。
class AdblockFilterList {
  const AdblockFilterList({
    required this.id,
    required this.title,
    required this.url,
    this.defaultEnabled = true,
  });

  /// 稳定 id：落盘文件名、偏好里的选择集都用它（冻结，别改）。
  final String id;

  /// 展示名（列表官方名，不翻译）。
  final String title;

  /// 官方下载地址。
  final Uri url;

  /// 新安装时是否默认勾选。
  final bool defaultEnabled;
}

/// 内置的默认过滤列表（官方地址）。
///
/// - EasyList / EasyPrivacy：easylist.to 官方（GPL-3.0 / CC BY-SA 3.0 双许可，只下载使用、不随包分发）。
/// - AdGuard 中文 / 日文过滤器：AdGuard 官方 filters.adtidy.org 的 uBlock 语法变体
///   （adblock-rust 兼容 uBO 语法）。filter id 224 = Chinese、7 = Japanese。
final List<AdblockFilterList> kDefaultAdblockFilterLists =
    List<AdblockFilterList>.unmodifiable(<AdblockFilterList>[
      AdblockFilterList(
        id: 'easylist',
        title: 'EasyList',
        url: Uri.parse('https://easylist.to/easylist/easylist.txt'),
      ),
      AdblockFilterList(
        id: 'easyprivacy',
        title: 'EasyPrivacy',
        url: Uri.parse('https://easylist.to/easylist/easyprivacy.txt'),
      ),
      AdblockFilterList(
        id: 'adguard_chinese',
        title: 'AdGuard Chinese',
        url: Uri.parse(
          'https://filters.adtidy.org/extension/ublock/filters/224.txt',
        ),
      ),
      AdblockFilterList(
        id: 'adguard_japanese',
        title: 'AdGuard Japanese',
        url: Uri.parse(
          'https://filters.adtidy.org/extension/ublock/filters/7.txt',
        ),
      ),
    ]);

/// 按 id 查内置列表；未知 id 返回 null。
AdblockFilterList? adblockFilterListById(String id) {
  for (final AdblockFilterList list in kDefaultAdblockFilterLists) {
    if (list.id == id) return list;
  }
  return null;
}

/// 一次 HTTP 抓取的结果（条件请求命中 304 时 [body] 为 null）。
class AdblockFetchResponse {
  const AdblockFetchResponse({
    required this.statusCode,
    this.body,
    this.etag,
    this.lastModified,
  });

  final int statusCode;
  final String? body;
  final String? etag;
  final String? lastModified;
}

/// 可注入的下载函数：app 侧传经全应用代理装配的 client（`createAppHttpClient`），
/// 测试传假实现。[etag] / [lastModified] 非空时应带条件请求头。
typedef AdblockHttpFetcher =
    Future<AdblockFetchResponse> Function(
      Uri url, {
      String? etag,
      String? lastModified,
    });

/// 用 `dart:io` [HttpClient] 实现的默认下载器。[clientFactory] 缺省 `HttpClient.new`；
/// app 应传自己的工厂，否则下载绕过全应用代理设置。
AdblockHttpFetcher httpClientAdblockFetcher({
  HttpClient Function()? clientFactory,
  Duration timeout = const Duration(seconds: 60),
}) {
  return (Uri url, {String? etag, String? lastModified}) async {
    final HttpClient client = (clientFactory ?? HttpClient.new)();
    try {
      final HttpClientRequest req = await client.getUrl(url).timeout(timeout);
      req.headers.set(HttpHeaders.acceptEncodingHeader, 'gzip');
      if (etag != null && etag.isNotEmpty) {
        req.headers.set(HttpHeaders.ifNoneMatchHeader, etag);
      }
      if (lastModified != null && lastModified.isNotEmpty) {
        req.headers.set(HttpHeaders.ifModifiedSinceHeader, lastModified);
      }
      final HttpClientResponse resp = await req.close().timeout(timeout);
      final String? body = resp.statusCode == HttpStatus.ok
          ? await resp.transform(utf8.decoder).join().timeout(timeout)
          : null;
      if (body == null) await resp.drain<void>();
      return AdblockFetchResponse(
        statusCode: resp.statusCode,
        body: body,
        etag: resp.headers.value(HttpHeaders.etagHeader),
        lastModified: resp.headers.value(HttpHeaders.lastModifiedHeader),
      );
    } finally {
      client.close(force: true);
    }
  };
}

/// 一份列表在本地缓存里的元数据。
class AdblockListCacheInfo {
  const AdblockListCacheInfo({
    required this.id,
    required this.fetchedAt,
    required this.byteLength,
    this.etag,
    this.lastModified,
  });

  factory AdblockListCacheInfo.fromJson(Map<String, Object?> json) {
    return AdblockListCacheInfo(
      id: json['id'] as String? ?? '',
      fetchedAt: DateTime.fromMillisecondsSinceEpoch(
        (json['fetchedAt'] as num?)?.toInt() ?? 0,
        isUtc: true,
      ),
      byteLength: (json['byteLength'] as num?)?.toInt() ?? 0,
      etag: json['etag'] as String?,
      lastModified: json['lastModified'] as String?,
    );
  }

  final String id;

  /// 最近一次**成功核对**（200 新内容或 304 未变）的时刻；过期判断以它为准。
  final DateTime fetchedAt;
  final int byteLength;
  final String? etag;
  final String? lastModified;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'fetchedAt': fetchedAt.millisecondsSinceEpoch,
    'byteLength': byteLength,
    if (etag != null) 'etag': etag,
    if (lastModified != null) 'lastModified': lastModified,
  };

  AdblockListCacheInfo copyWith({DateTime? fetchedAt}) => AdblockListCacheInfo(
    id: id,
    fetchedAt: fetchedAt ?? this.fetchedAt,
    byteLength: byteLength,
    etag: etag,
    lastModified: lastModified,
  );
}

/// 一份列表这次是怎么拿到的。
enum AdblockListSource {
  /// 缓存未过期，直接用。
  cache,

  /// 下载了新内容。
  downloaded,

  /// 服务器回 304，缓存续期。
  notModified,

  /// 下载失败（离线等），退回到过期缓存。
  staleCache,

  /// 下载失败且没有缓存：这份列表本次缺席。
  missing,
}

/// 一份列表的加载结果。
class AdblockListLoadResult {
  const AdblockListLoadResult({
    required this.list,
    required this.source,
    this.text,
    this.info,
    this.error,
  });

  final AdblockFilterList list;
  final AdblockListSource source;

  /// 列表全文；[source] 为 [AdblockListSource.missing] 时为 null。
  final String? text;
  final AdblockListCacheInfo? info;

  /// 下载失败原因（成功时为 null）。
  final Object? error;
}

/// 过滤列表下载 / 落盘缓存 / 过期刷新。
///
/// 磁盘布局（[cacheDir] 下）：`lists/<id>.txt` 全文 + `lists/<id>.json` 元数据。
/// 过期策略：距上次成功核对超过 [maxAge] 才联网；联网带 ETag / Last-Modified 条件请求；
/// 联网失败时有缓存就用缓存（离线可用），没有缓存这份列表本次缺席，不抛。
class AdblockFilterListService {
  AdblockFilterListService({
    required this.cacheDir,
    AdblockHttpFetcher? fetcher,
    this.maxAge = const Duration(days: 4),
    DateTime Function()? clock,
  }) : _fetcher = fetcher ?? httpClientAdblockFetcher(),
       _clock = clock ?? DateTime.now;

  final Directory cacheDir;
  final Duration maxAge;
  final AdblockHttpFetcher _fetcher;
  final DateTime Function() _clock;

  Directory get _listsDir =>
      Directory('${cacheDir.path}${Platform.pathSeparator}lists');

  File _textFile(String id) =>
      File('${_listsDir.path}${Platform.pathSeparator}$id.txt');

  File _metaFile(String id) =>
      File('${_listsDir.path}${Platform.pathSeparator}$id.json');

  /// 读本地缓存元数据；没有 / 损坏返回 null。
  Future<AdblockListCacheInfo?> cacheInfo(AdblockFilterList list) async {
    final File meta = _metaFile(list.id);
    if (!meta.existsSync()) return null;
    try {
      final Object? json = jsonDecode(await meta.readAsString());
      if (json is! Map<String, Object?>) return null;
      final AdblockListCacheInfo info = AdblockListCacheInfo.fromJson(json);
      return _textFile(list.id).existsSync() ? info : null;
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  /// 读本地缓存全文；没有返回 null。
  Future<String?> readCached(AdblockFilterList list) async {
    final File f = _textFile(list.id);
    if (!f.existsSync()) return null;
    try {
      return await f.readAsString();
    } on FileSystemException {
      return null;
    }
  }

  /// 缓存是否已过期（没有缓存也算过期）。
  bool isStale(AdblockListCacheInfo? info) {
    if (info == null) return true;
    return _clock().toUtc().difference(info.fetchedAt) >= maxAge;
  }

  /// 逐份加载 [lists]：未过期用缓存，过期 / [force] 时联网核对。永不抛。
  Future<List<AdblockListLoadResult>> loadLists(
    List<AdblockFilterList> lists, {
    bool force = false,
  }) async {
    final List<AdblockListLoadResult> out = <AdblockListLoadResult>[];
    for (final AdblockFilterList list in lists) {
      out.add(await loadList(list, force: force));
    }
    return out;
  }

  /// 加载单份列表，规则见 [loadLists]。
  Future<AdblockListLoadResult> loadList(
    AdblockFilterList list, {
    bool force = false,
  }) async {
    final AdblockListCacheInfo? info = await cacheInfo(list);
    if (!force && !isStale(info)) {
      final String? text = await readCached(list);
      if (text != null) {
        return AdblockListLoadResult(
          list: list,
          source: AdblockListSource.cache,
          text: text,
          info: info,
        );
      }
    }
    try {
      final AdblockFetchResponse resp = await _fetcher(
        list.url,
        etag: info?.etag,
        lastModified: info?.lastModified,
      );
      if (resp.statusCode == HttpStatus.notModified && info != null) {
        final String? text = await readCached(list);
        if (text != null) {
          final AdblockListCacheInfo renewed = info.copyWith(
            fetchedAt: _clock().toUtc(),
          );
          await _writeMeta(renewed);
          return AdblockListLoadResult(
            list: list,
            source: AdblockListSource.notModified,
            text: text,
            info: renewed,
          );
        }
      }
      final String? body = resp.body;
      if (resp.statusCode != HttpStatus.ok || body == null) {
        throw HttpException('HTTP ${resp.statusCode}', uri: list.url);
      }
      if (!_looksLikeFilterList(body)) {
        throw const FormatException('response is not a filter list');
      }
      final AdblockListCacheInfo fresh = AdblockListCacheInfo(
        id: list.id,
        fetchedAt: _clock().toUtc(),
        byteLength: body.length,
        etag: resp.etag,
        lastModified: resp.lastModified,
      );
      await _writeAtomic(_textFile(list.id), body);
      await _writeMeta(fresh);
      return AdblockListLoadResult(
        list: list,
        source: AdblockListSource.downloaded,
        text: body,
        info: fresh,
      );
    } on Object catch (error) {
      final String? text = await readCached(list);
      if (text != null) {
        return AdblockListLoadResult(
          list: list,
          source: AdblockListSource.staleCache,
          text: text,
          info: info,
          error: error,
        );
      }
      return AdblockListLoadResult(
        list: list,
        source: AdblockListSource.missing,
        error: error,
      );
    }
  }

  /// 删掉某份列表的缓存（取消订阅时清理磁盘）。
  Future<void> evict(AdblockFilterList list) async {
    for (final File f in <File>[_textFile(list.id), _metaFile(list.id)]) {
      if (f.existsSync()) await f.delete();
    }
  }

  /// 粗判下载内容确实是过滤列表（防代理 / 门户页返回 HTML 被当规则吃进去）。
  static bool _looksLikeFilterList(String body) {
    final String head = body.length > 2048 ? body.substring(0, 2048) : body;
    final String trimmed = head.trimLeft().toLowerCase();
    if (trimmed.startsWith('<!doctype') || trimmed.startsWith('<html')) {
      return false;
    }
    return body.trim().isNotEmpty;
  }

  Future<void> _writeMeta(AdblockListCacheInfo info) =>
      _writeAtomic(_metaFile(info.id), jsonEncode(info.toJson()));

  Future<void> _writeAtomic(File target, String content) async {
    await target.parent.create(recursive: true);
    final File tmp = File('${target.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    if (target.existsSync()) await target.delete();
    await tmp.rename(target.path);
  }
}
