/// Plex Media Server（PMS）协议层：HTTP 封装 + URL 构造 + JSON→DTO 纯函数解析。
///
/// 纯 Dart（无 Flutter / 插件），app 侧的 `PlexVideoClient` 把这里的 DTO 适配成
/// `MediaServerBrowser` / `RemoteVideoClient` 契约；无头服务端将来也可直接复用。
///
/// 协议事实（与 Jellyfin 家族的差异点）：
/// - 所有请求带 `Accept: application/json`，PMS 才回 JSON（缺省是 XML）；响应顶层
///   恒为 `{"MediaContainer": {...}}`。
/// - 认证是 `X-Plex-Token`（头或查询参数都认），另有一组 `X-Plex-*` 客户端身份头
///   （[PlexClientInfo]）。播放 / 封面 / 字幕 URL 交给 libmpv 与图片解码器时没有头
///   通道，所以这些 URL **带查询参数 token**——诊断日志 / 错误上报一律经
///   `redactCredentialsInText`（`x-plex-token` 已登记）脱敏。
/// - 时间单位是**毫秒**（`duration` / `viewOffset`），`lastViewedAt` / `addedAt`
///   是 epoch **秒**。
/// - 分页走 `X-Plex-Container-Start` / `X-Plex-Container-Size`（查询参数形态），
///   分页时 MediaContainer 才带 `totalSize`。
/// - 取流 v1 只做 direct play：`Part.key`（`/library/parts/{id}/{ts}/file.ext`）+
///   token 直出原文件，libmpv 自己解；不走 `/video/:/transcode/universal`。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:fushi_engine/media/metadata/credential_redaction.dart'
    show redactCredentialsInText;
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:fushi_engine/utils/net/url_input_normalizer.dart';

/// PMS 客户端身份（`X-Plex-*` 头）。[clientIdentifier] 每安装稳定、持久化——plex.tv
/// 的「已授权设备」列表与服务器仪表盘都按它归并本客户端。
class PlexClientInfo {
  const PlexClientInfo({
    required this.clientIdentifier,
    this.product = kPlexProduct,
    this.version = '1.0',
    String? platform,
    this.deviceName = kPlexProduct,
  }) : _platform = platform;

  static const String kPlexProduct = 'Fushi';

  final String clientIdentifier;
  final String product;
  final String version;
  final String? _platform;
  final String deviceName;

  /// `X-Plex-Platform`：缺省按当前 OS 取 Plex 自己的写法（`Windows` / `iOS` …）。
  String get platform =>
      _platform ?? plexPlatformName(Platform.operatingSystem);

  /// 身份头（不含 token / Accept）。
  Map<String, String> get headers => <String, String>{
    'X-Plex-Client-Identifier': clientIdentifier,
    'X-Plex-Product': product,
    'X-Plex-Version': version,
    'X-Plex-Platform': platform,
    'X-Plex-Device': platform,
    'X-Plex-Device-Name': deviceName,
  };
}

/// `Platform.operatingSystem` → Plex 惯用的平台名。
String plexPlatformName(String operatingSystem) => switch (operatingSystem) {
  'windows' => 'Windows',
  'macos' => 'macOS',
  'ios' => 'iOS',
  'android' => 'Android',
  'linux' => 'Linux',
  _ => operatingSystem,
};

/// PMS / plex.tv 返回非 2xx。
class PlexApiException implements Exception {
  const PlexApiException(this.statusCode, this.path);

  final int statusCode;
  final String path;

  @override
  String toString() => 'PlexApiException($statusCode, $path)';
}

/// 一个媒体库（`/library/sections` 的 `Directory`）。
class PlexSection {
  const PlexSection({
    required this.key,
    required this.title,
    required this.type,
  });

  /// 库 key（数字字符串）。与条目 ratingKey 是**两个 id 空间**，数字可以撞。
  final String key;
  final String title;

  /// `movie` / `show` / `artist` / `photo`。
  final String type;

  bool get isVideo => type == 'movie' || type == 'show';
}

/// 一条媒体流（`Media[].Part[].Stream[]`）。只有单条目详情才带。
class PlexStream {
  const PlexStream({
    required this.id,
    required this.streamType,
    this.codec,
    this.index,
    this.language,
    this.languageCode,
    this.title,
    this.displayTitle,
    this.key,
    this.selected = false,
  });

  final int id;

  /// 1 视频 / 2 音频 / 3 字幕。
  final int streamType;
  final String? codec;

  /// 容器内流号（ffprobe 序）；外挂字幕文件没有。
  final int? index;
  final String? language;
  final String? languageCode;
  final String? title;
  final String? displayTitle;

  /// 外挂（sidecar）字幕的下载路径 `/library/streams/{id}`；容器内的轨没有。
  final String? key;
  final bool selected;

  bool get isSubtitle => streamType == 3;

  /// 外挂字幕文件（PMS 只对 sidecar 给 `key`，可直接下载原文件）。
  bool get isExternal => key != null && key!.isNotEmpty;

  static const Set<String> _textCodecs = <String>{
    'srt',
    'subrip',
    'ass',
    'ssa',
    'vtt',
    'webvtt',
    'mov_text',
    'tx3g',
    'text',
    'smi',
    'sami',
  };

  /// 文本字幕（图形轨 pgs / vobsub / dvb 不算）。
  bool get isTextSubtitle =>
      isSubtitle && _textCodecs.contains((codec ?? '').toLowerCase());
}

/// 一个媒体文件分片（`Media[].Part[]`）。
class PlexPart {
  const PlexPart({
    required this.id,
    required this.key,
    this.file,
    this.sizeBytes,
    this.container,
    this.streams = const <PlexStream>[],
  });

  final int id;

  /// direct play 路径（`/library/parts/{id}/{ts}/file.ext`）。
  final String key;
  final String? file;
  final int? sizeBytes;
  final String? container;
  final List<PlexStream> streams;
}

/// 一个媒体版本（`Media[]`）。
class PlexMedia {
  const PlexMedia({required this.id, this.durationMs, required this.parts});

  final int id;
  final int? durationMs;
  final List<PlexPart> parts;
}

/// PMS 条目（`Metadata[]`）：电影 / 剧 / 季 / 集 / 合集 / 片段。
class PlexMetadata {
  const PlexMetadata({
    required this.ratingKey,
    required this.type,
    required this.title,
    this.key,
    this.originalTitle,
    this.summary,
    this.year,
    this.durationMs,
    this.viewOffsetMs = 0,
    this.viewCount = 0,
    this.lastViewedAtMs = 0,
    this.thumb,
    this.art,
    this.hasClearLogo = false,
    this.parentRatingKey,
    this.parentTitle,
    this.parentIndex,
    this.parentThumb,
    this.parentArt,
    this.grandparentRatingKey,
    this.grandparentTitle,
    this.grandparentThumb,
    this.grandparentArt,
    this.index,
    this.leafCount,
    this.viewedLeafCount,
    this.childCount,
    this.rating,
    this.genres = const <String>[],
    this.media = const <PlexMedia>[],
  });

  final String ratingKey;

  /// `movie` / `show` / `season` / `episode` / `collection` / `clip` / …
  final String type;
  final String title;
  final String? key;
  final String? originalTitle;
  final String? summary;
  final int? year;
  final int? durationMs;
  final int viewOffsetMs;
  final int viewCount;

  /// `lastViewedAt`（秒）→ 毫秒；0 = 从未看过。
  final int lastViewedAtMs;
  final String? thumb;
  final String? art;
  final bool hasClearLogo;

  /// 集 → 季；季 → 剧。
  final String? parentRatingKey;
  final String? parentTitle;

  /// 集所属季的季号。
  final int? parentIndex;
  final String? parentThumb;
  final String? parentArt;

  /// 集 → 剧。
  final String? grandparentRatingKey;
  final String? grandparentTitle;
  final String? grandparentThumb;
  final String? grandparentArt;

  /// 集号（集）/ 季号（季）。
  final int? index;

  /// 剧 / 季的总集数与已看集数。
  final int? leafCount;
  final int? viewedLeafCount;

  /// 剧的季数。
  final int? childCount;

  /// 评分（`audienceRating` 优先，缺省 `rating`）。
  final double? rating;
  final List<String> genres;
  final List<PlexMedia> media;

  /// 首个媒体版本的首个分片（direct play 源）。
  PlexPart? get primaryPart {
    for (final PlexMedia m in media) {
      if (m.parts.isNotEmpty) return m.parts.first;
    }
    return null;
  }

  /// 首个分片里的全部流（详情才有）。
  List<PlexStream> get streams => primaryPart?.streams ?? const <PlexStream>[];
}

/// 一页条目 + 服务器总数。
class PlexMetadataPage {
  const PlexMetadataPage({
    required this.items,
    required this.totalSize,
    required this.rawCount,
  });

  final List<PlexMetadata> items;

  /// `totalSize`（分页时 PMS 才给；缺省 = 本页条数）。
  final int totalSize;

  /// 服务器本页实际返回的行数（翻页起点按它推，不按 [items] 过滤后的长度）。
  final int rawCount;
}

/// PMS 的 HTTP 封装。一个实例 = 一台服务器的一条连接地址 + 一个 token。
class PlexApi {
  PlexApi({
    required this.serverUrl,
    required this.token,
    required this.clientInfo,
    http.Client? client,
  }) : _client = client ?? createAppHttpIoClient();

  /// 归一化后的服务器根 URL（含 scheme、无尾斜杠）。
  final String serverUrl;

  /// 访问这台服务器的 token（分享给本账号的服务器与账号 token 不同，取
  /// plex.tv resources 里该服务器自己的 `accessToken`）。
  final String token;
  final PlexClientInfo clientInfo;
  final http.Client _client;

  /// 单个小请求的响应超时（与 JellyfinApi 同口径）。
  static const Duration kRequestTimeout = Duration(seconds: 15);

  /// 进度上报等写操作走库插件标识（PMS 约定值）。
  static const String kLibraryIdentifier = 'com.plexapp.plugins.library';

  /// 查询参数里 token 的名字（URL 脱敏清单按小写登记为 `x-plex-token`）。
  static const String kTokenParam = 'X-Plex-Token';

  /// 归一化用户输入的服务器地址：折全角、补 scheme（缺省 http）、去尾斜杠。
  /// 与 JellyfinApi.normalizeServerUrl 同口径（PMS 缺省端口 32400 也常是局域网 IP）。
  static String normalizeServerUrl(String raw) {
    String url = normalizeUrlInput(raw);
    if (url.isEmpty) return url;
    final RegExpMatch? scheme = RegExp(
      r'^(https?)://',
      caseSensitive: false,
    ).firstMatch(url);
    if (scheme == null) {
      url = 'http://$url';
    } else if (scheme.group(1) != scheme.group(1)!.toLowerCase()) {
      url = '${scheme.group(1)!.toLowerCase()}://${url.substring(scheme.end)}';
    }
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  Map<String, String> get headers => <String, String>{
    'Accept': 'application/json',
    ...clientInfo.headers,
    'X-Plex-Token': token,
  };

  Uri uri(String path, [Map<String, String>? query]) {
    final Uri base = Uri.parse('$serverUrl$path');
    if (query == null || query.isEmpty) return base;
    return base.replace(
      queryParameters: <String, String>{...base.queryParameters, ...query},
    );
  }

  /// 给交给播放器 / 图片解码器的 URL 附 token（它们没有头通道）。
  String withToken(String path, [Map<String, String>? query]) =>
      uri(path, <String, String>{...?query, kTokenParam: token}).toString();

  Future<http.Response> _send(
    String method,
    String path, [
    Map<String, String>? query,
  ]) async {
    try {
      final http.Request req = http.Request(method, uri(path, query));
      req.headers.addAll(headers);
      final http.StreamedResponse streamed = await _client
          .send(req)
          .timeout(kRequestTimeout);
      final http.Response res = await http.Response.fromStream(
        streamed,
      ).timeout(kRequestTimeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw PlexApiException(res.statusCode, path);
      }
      return res;
    } on http.ClientException catch (e) {
      // 凭据脱敏在异常构造侧（见 credential_redaction.dart 文件头）。
      throw Exception(redactCredentialsInText(e.toString()));
    }
  }

  /// GET + 取 `MediaContainer`。非 JSON 抛 [FormatException]。
  Future<Map<String, Object?>> getContainer(
    String path, [
    Map<String, String>? query,
  ]) async {
    final http.Response res = await _send('GET', path, query);
    return parseContainer(jsonDecode(utf8.decode(res.bodyBytes)));
  }

  /// 服务器身份（`/identity`，需要 token 的服务器也放行）：返回 machineIdentifier。
  Future<String> identity() async {
    final Map<String, Object?> c = await getContainer('/identity');
    return _str(c['machineIdentifier']) ?? '';
  }

  /// 服务器自报名（`/`，要 token）：`friendlyName`。
  Future<String?> friendlyName() async {
    final Map<String, Object?> c = await getContainer('/');
    return _str(c['friendlyName']);
  }

  Future<List<PlexSection>> sections() async =>
      parseSections(await getContainer('/library/sections'));

  static Map<String, String> _paging(int start, int size) => <String, String>{
    'X-Plex-Container-Start': '$start',
    'X-Plex-Container-Size': '$size',
  };

  /// 库内条目（`/library/sections/{key}/all`）。[type] 过滤 PMS 类型号
  /// （1 电影 / 2 剧 / 4 集），null = 库缺省（电影库出电影、剧集库出剧）。
  Future<PlexMetadataPage> sectionItems(
    String sectionKey, {
    int start = 0,
    int size = 60,
    String? sort,
    int? type,
  }) async => parseMetadataPage(
    await getContainer('/library/sections/$sectionKey/all', <String, String>{
      ..._paging(start, size),
      if (sort != null) 'sort': sort,
      if (type != null) 'type': '$type',
    }),
  );

  /// 子级（剧 → 季、季 → 集、合集 → 成员）。季清单带 `excludeAllLeaves=1`，否则
  /// PMS 会塞一条「全部集」伪季。
  Future<PlexMetadataPage> children(
    String ratingKey, {
    int start = 0,
    int size = 200,
  }) async => parseMetadataPage(
    await getContainer(
      '/library/metadata/$ratingKey/children',
      <String, String>{..._paging(start, size), 'excludeAllLeaves': '1'},
    ),
  );

  /// 一部剧的全部集（跨季，按季集号）。
  Future<PlexMetadataPage> allLeaves(
    String ratingKey, {
    int start = 0,
    int size = 100,
  }) async => parseMetadataPage(
    await getContainer(
      '/library/metadata/$ratingKey/allLeaves',
      _paging(start, size),
    ),
  );

  /// 单条目详情（带 Media / Part / Stream 全量）。不存在抛 [StateError]。
  Future<PlexMetadata> metadata(String ratingKey) async {
    final PlexMetadataPage page = parseMetadataPage(
      await getContainer('/library/metadata/$ratingKey'),
    );
    if (page.items.isEmpty) {
      throw StateError('Plex item $ratingKey not found');
    }
    return page.items.first;
  }

  /// 「继续观看」hub（新版 PMS）。
  Future<List<PlexMetadata>> continueWatching({int size = 20}) async =>
      parseMetadataPage(
        await getContainer('/hubs/continueWatching/items', _paging(0, size)),
      ).items;

  /// 首页 On Deck hub（新版 PMS 的形态）。
  Future<List<PlexMetadata>> hubsOnDeck({int size = 20}) async =>
      parseMetadataPage(
        await getContainer('/hubs/home/onDeck', _paging(0, size)),
      ).items;

  /// 旧版 On Deck（全服务器）。
  Future<List<PlexMetadata>> libraryOnDeck({int size = 20}) async =>
      parseMetadataPage(
        await getContainer('/library/onDeck', _paging(0, size)),
      ).items;

  /// 最近添加：[sectionKey] null = 全服务器。
  Future<List<PlexMetadata>> recentlyAdded({
    String? sectionKey,
    int size = 20,
  }) async => parseMetadataPage(
    await getContainer(
      sectionKey == null
          ? '/library/recentlyAdded'
          : '/library/sections/$sectionKey/recentlyAdded',
      _paging(0, size),
    ),
  ).items;

  /// 全服务器搜索（`/hubs/search`），按 hub 摊平；只留 [types] 里的条目类型。
  Future<List<PlexMetadata>> searchHubs(
    String query, {
    int limit = 100,
    Set<String> types = const <String>{'movie', 'show'},
  }) async {
    final Map<String, Object?> c = await getContainer(
      '/hubs/search',
      <String, String>{'query': query, 'limit': '$limit'},
    );
    return <PlexMetadata>[
      for (final PlexMetadata m in parseMetadataPage(c).items)
        if (types.contains(m.type)) m,
    ];
  }

  /// 播放进度 / 状态上报（`/:/timeline`）。[state] 取 `playing` / `paused` /
  /// `stopped`；PMS 据此更新 viewOffset，接近片尾的 stopped 会自动判已看。
  Future<void> timeline({
    required String ratingKey,
    required String state,
    required int timeMs,
    int? durationMs,
  }) async {
    await _send('GET', '/:/timeline', <String, String>{
      'ratingKey': ratingKey,
      'key': '/library/metadata/$ratingKey',
      'identifier': kLibraryIdentifier,
      'state': state,
      'time': '$timeMs',
      if (durationMs != null && durationMs > 0) 'duration': '$durationMs',
    });
  }

  /// 标记已看。
  Future<void> scrobble(String ratingKey) async {
    await _send('GET', '/:/scrobble', <String, String>{
      'identifier': kLibraryIdentifier,
      'key': ratingKey,
    });
  }

  /// 取消已看。
  Future<void> unscrobble(String ratingKey) async {
    await _send('GET', '/:/unscrobble', <String, String>{
      'identifier': kLibraryIdentifier,
      'key': ratingKey,
    });
  }

  /// direct play 直链：`Part.key` + token（v1 不走转码）。
  String partUrl(String partKey, {bool download = false}) =>
      withToken(partKey, download ? <String, String>{'download': '1'} : null);

  /// 外挂字幕文件直链（`/library/streams/{id}`）。
  String streamFileUrl(String streamKey) => withToken(streamKey);

  /// 服务器侧缩放的图片 URL（`/photo/:/transcode`）。[imagePath] 是条目的
  /// `thumb` / `art` 之类服务器内路径；宽高是**上限框**，PMS 保持比例缩进去。
  String photoTranscodeUrl(
    String imagePath, {
    required int width,
    required int height,
  }) => withToken('/photo/:/transcode', <String, String>{
    'width': '$width',
    'height': '$height',
    'minSize': '0',
    'upscale': '0',
    'url': imagePath,
  });

  /// 拉取字节（封面）。
  Future<Uint8List> fetchBytes(String url) async {
    try {
      final http.Response res = await _client
          .get(Uri.parse(url), headers: headers)
          .timeout(kRequestTimeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw PlexApiException(res.statusCode, Uri.parse(url).path);
      }
      return res.bodyBytes;
    } on http.ClientException catch (e) {
      throw Exception(redactCredentialsInText(e.toString()));
    }
  }

  /// 流式下载到 [dest]（整片 / 字幕）。[cancelSignal] 完成后在下一个数据块到达时
  /// 中止并抛 [cancelledError] 的返回值（缺省 [StateError]）；失败删半截文件。
  Future<void> downloadToFile(
    String url,
    File dest, {
    void Function(double progress)? onProgress,
    void Function(int received, int? total)? onBytes,
    Future<void>? cancelSignal,
    Exception Function()? cancelledError,
  }) async {
    bool cancelled = false;
    cancelSignal?.then((_) => cancelled = true, onError: (_) {});
    try {
      final http.Request req = http.Request('GET', Uri.parse(url));
      req.headers.addAll(headers);
      final http.StreamedResponse res = await _client
          .send(req)
          .timeout(kRequestTimeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw PlexApiException(res.statusCode, Uri.parse(url).path);
      }
      final int? total = res.contentLength;
      int received = 0;
      final IOSink sink = dest.openWrite();
      bool ok = false;
      try {
        await for (final List<int> chunk in res.stream) {
          if (cancelled) {
            final Exception? custom = cancelledError?.call();
            if (custom != null) throw custom;
            throw StateError('Plex download cancelled');
          }
          sink.add(chunk);
          received += chunk.length;
          onBytes?.call(received, total);
          if (total != null && total > 0) onProgress?.call(received / total);
        }
        ok = true;
      } finally {
        await sink.close();
        if (!ok) {
          try {
            dest.deleteSync();
          } catch (_) {
            // best-effort：删不掉也不盖住原始失败。
          }
        }
      }
    } on http.ClientException catch (e) {
      throw Exception(redactCredentialsInText(e.toString()));
    }
  }

  void close() => _client.close();

  // ── 纯 JSON 解析（离线可测） ─────────────────────────────────────────

  /// 顶层 `{"MediaContainer": {...}}` → 容器 map；形状不对返回空 map。
  static Map<String, Object?> parseContainer(Object? decoded) {
    if (decoded is Map) {
      final Object? c = decoded['MediaContainer'];
      if (c is Map) return c.cast<String, Object?>();
    }
    return <String, Object?>{};
  }

  static List<PlexSection> parseSections(Map<String, Object?> container) =>
      <PlexSection>[
        for (final Object? raw
            in (container['Directory'] as List?) ?? const <Object?>[])
          if (raw is Map)
            PlexSection(
              key: _str(raw['key']) ?? '',
              title: _str(raw['title']) ?? '',
              type: _str(raw['type']) ?? '',
            ),
      ];

  /// `Metadata` 列表 + hub 形态（`Hub[].Metadata`，搜索 / 首页 hub）一起摊平。
  static PlexMetadataPage parseMetadataPage(Map<String, Object?> container) {
    final List<PlexMetadata> items = <PlexMetadata>[];
    int raw = 0;
    void addAll(Object? list) {
      if (list is! List) return;
      for (final Object? entry in list) {
        if (entry is! Map) continue;
        raw++;
        final PlexMetadata? m = parseMetadata(entry.cast<String, Object?>());
        if (m != null) items.add(m);
      }
    }

    addAll(container['Metadata']);
    for (final Object? hub
        in (container['Hub'] as List?) ?? const <Object?>[]) {
      if (hub is Map) addAll(hub['Metadata']);
    }
    return PlexMetadataPage(
      items: items,
      totalSize: _int(container['totalSize']) ?? raw,
      rawCount: raw,
    );
  }

  /// 单条 `Metadata`；缺 ratingKey 返回 null。
  static PlexMetadata? parseMetadata(Map<String, Object?> json) {
    final String? ratingKey = _str(json['ratingKey']);
    if (ratingKey == null || ratingKey.isEmpty) return null;
    final int? lastViewedAt = _int(json['lastViewedAt']);
    bool hasClearLogo = false;
    for (final Object? image in (json['Image'] as List?) ?? const <Object?>[]) {
      if (image is Map && image['type'] == 'clearLogo') hasClearLogo = true;
    }
    return PlexMetadata(
      ratingKey: ratingKey,
      type: _str(json['type']) ?? '',
      title: _str(json['title']) ?? '',
      key: _str(json['key']),
      originalTitle: _str(json['originalTitle']),
      summary: _nonEmpty(_str(json['summary'])),
      year: _int(json['year']),
      durationMs: _int(json['duration']),
      viewOffsetMs: _int(json['viewOffset']) ?? 0,
      viewCount: _int(json['viewCount']) ?? 0,
      lastViewedAtMs: lastViewedAt == null ? 0 : lastViewedAt * 1000,
      thumb: _nonEmpty(_str(json['thumb'])),
      art: _nonEmpty(_str(json['art'])),
      hasClearLogo: hasClearLogo,
      parentRatingKey: _str(json['parentRatingKey']),
      parentTitle: _str(json['parentTitle']),
      parentIndex: _int(json['parentIndex']),
      parentThumb: _nonEmpty(_str(json['parentThumb'])),
      parentArt: _nonEmpty(_str(json['parentArt'])),
      grandparentRatingKey: _str(json['grandparentRatingKey']),
      grandparentTitle: _str(json['grandparentTitle']),
      grandparentThumb: _nonEmpty(_str(json['grandparentThumb'])),
      grandparentArt: _nonEmpty(_str(json['grandparentArt'])),
      index: _int(json['index']),
      leafCount: _int(json['leafCount']),
      viewedLeafCount: _int(json['viewedLeafCount']),
      childCount: _int(json['childCount']),
      rating: _double(json['audienceRating']) ?? _double(json['rating']),
      genres: <String>[
        for (final Object? g in (json['Genre'] as List?) ?? const <Object?>[])
          if (g is Map && _str(g['tag']) != null) _str(g['tag'])!,
      ],
      media: <PlexMedia>[
        for (final Object? m in (json['Media'] as List?) ?? const <Object?>[])
          if (m is Map) _parseMedia(m.cast<String, Object?>()),
      ],
    );
  }

  static PlexMedia _parseMedia(Map<String, Object?> json) => PlexMedia(
    id: _int(json['id']) ?? 0,
    durationMs: _int(json['duration']),
    parts: <PlexPart>[
      for (final Object? p in (json['Part'] as List?) ?? const <Object?>[])
        if (p is Map && _str(p['key']) != null)
          PlexPart(
            id: _int(p['id']) ?? 0,
            key: _str(p['key'])!,
            file: _str(p['file']),
            sizeBytes: _int(p['size']),
            container: _str(p['container']),
            streams: <PlexStream>[
              for (final Object? s
                  in (p['Stream'] as List?) ?? const <Object?>[])
                if (s is Map)
                  PlexStream(
                    id: _int(s['id']) ?? 0,
                    streamType: _int(s['streamType']) ?? 0,
                    codec: _str(s['codec']),
                    index: _int(s['index']),
                    language: _str(s['language']),
                    languageCode: _str(s['languageCode']),
                    title: _str(s['title']),
                    displayTitle: _str(s['displayTitle']),
                    key: _nonEmpty(_str(s['key'])),
                    selected: s['selected'] == true || s['selected'] == 1,
                  ),
            ],
          ),
    ],
  );

  static String? _str(Object? v) => switch (v) {
    final String s => s,
    final num n => n.toString(),
    _ => null,
  };

  static String? _nonEmpty(String? v) => v == null || v.isEmpty ? null : v;

  static int? _int(Object? v) => switch (v) {
    final int i => i,
    final num n => n.toInt(),
    final String s => int.tryParse(s),
    _ => null,
  };

  static double? _double(Object? v) => switch (v) {
    final num n => n.toDouble(),
    final String s => double.tryParse(s),
    _ => null,
  };
}
