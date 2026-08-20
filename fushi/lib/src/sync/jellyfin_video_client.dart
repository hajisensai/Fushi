// Jellyfin / Emby 媒体服务器视频客户端。
//
// 两层结构：
// - [JellyfinApi]：薄 HTTP 封装（认证 / 视图 / 条目 / 进度上报 / URL 构造），
//   JSON→DTO 解析全部是纯静态方法，测试用 MockClient 离线覆盖。
// - [JellyfinVideoClient] `implements RemoteVideoClient`：把 Jellyfin 条目适配成
//   互联/云端同款的远端视频契约（列清单 / 整片下载 / 流播 URL / 外挂字幕 /
//   跨端断点），库页与播放页零新概念消费。
//
// 协议事实：
// - Jellyfin 与 Emby 的这批端点同源兼容（AuthenticateByName / Views / Items /
//   Videos/{id}/stream / Sessions/Playing/Stopped），一套实现双吃。
// - 播放路径的 [RemoteVideoStreamUrls] 没有 HTTP 头通道，所以流/图片/字幕 URL
//   一律用 `api_key` 查询参数自带认证（两家都支持），不依赖 header 注入。
// - 时间单位：服务器用 tick（100ns），1ms = 10000 ticks（[kTicksPerMs]）。
// - 断点：读走条目 UserData.PlaybackPositionTicks + UserData.LastPlayedDate
//   （服务器唯一的「位置更新时刻」，跨端 LWW 靠它才有得比）；写走
//   Sessions/Playing/Progress（周期心跳，10s 一档 = Jellyfin web 客户端口径），
//   只有真正停止播放才发 Sessions/Playing/Stopped。**别拿 Stopped 当心跳**：
//   它在接近片尾时会把条目标记为已播放并清空 resume 位置，还会把活动日志 /
//   webhook / Playback Reporting 统计刷成一堆假「播放已停止」。服务器端没有
//   「较新时间戳者胜」合并，语义是 last-write-wins；[putRemoteVideoPosition]
//   的 updatedAtMs 只在本端语境有意义，不上传。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha1;
import 'package:http/http.dart' as http;

import 'package:fushi/src/media/metadata/credential_redaction.dart'
    show redactCredentialsInText;
import 'package:fushi/src/sync/fushi_library_host_service.dart'
    show
        RemoteCollectionMembership,
        RemoteVideoEmbeddedSubtitleTrack,
        RemoteVideoInfo,
        RemoteVideoStreamUrls;
import 'package:fushi/src/sync/remote_cover_fetcher.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi/src/utils/net/app_http.dart';

/// 1 毫秒 = 10000 个 Jellyfin tick（100ns）。
const int kTicksPerMs = 10000;

/// 已登录 Jellyfin/Emby 服务器的持久化配置（落 SyncRepository 的
/// `sync_jellyfin_server` prefs 键；presence = 已启用，登出即删键）。
///
/// 令牌与互联 per-peer token 同款落 Drift prefs（不是明文红线的 configJson——
/// 该红线针对 MediaSources 行；prefs 是既有凭据落点，见 sync_repository.dart
/// 各后端凭据键）。
class JellyfinServerConfig {
  const JellyfinServerConfig({
    required this.serverUrl,
    required this.username,
    required this.userId,
    required this.accessToken,
    this.serverName,
  });

  /// 归一化后的服务器根 URL（[JellyfinApi.normalizeServerUrl] 口径）。
  final String serverUrl;
  final String username;
  final String userId;
  final String accessToken;
  final String? serverName;

  Map<String, Object?> toJson() => <String, Object?>{
        'serverUrl': serverUrl,
        'username': username,
        'userId': userId,
        'accessToken': accessToken,
        if (serverName != null) 'serverName': serverName,
      };

  static JellyfinServerConfig? fromJson(Map<String, dynamic> json) {
    final String serverUrl = (json['serverUrl'] as String?) ?? '';
    final String userId = (json['userId'] as String?) ?? '';
    final String accessToken = (json['accessToken'] as String?) ?? '';
    if (serverUrl.isEmpty || userId.isEmpty || accessToken.isEmpty) {
      return null;
    }
    return JellyfinServerConfig(
      serverUrl: serverUrl,
      username: (json['username'] as String?) ?? '',
      userId: userId,
      accessToken: accessToken,
      serverName: json['serverName'] as String?,
    );
  }

  /// 从配置构造可用客户端（每次取数新建实例，缓存身份见
  /// [JellyfinVideoClient.remoteLibrarySourceId]）。
  JellyfinVideoClient buildClient({http.Client? httpClient}) =>
      JellyfinVideoClient(
        api: JellyfinApi(
          serverUrl: serverUrl,
          accessToken: accessToken,
          client: httpClient,
        ),
        userId: userId,
      );
}

/// 认证成功的结果：访问令牌 + 用户 id + 服务器显示名。
class JellyfinAuthResult {
  const JellyfinAuthResult({
    required this.accessToken,
    required this.userId,
    this.serverName,
  });

  final String accessToken;
  final String userId;
  final String? serverName;
}

/// 一个媒体库视图（Jellyfin「媒体库」，如 电影 / 剧集 / 动漫）。
class JellyfinLibraryView {
  const JellyfinLibraryView({
    required this.id,
    required this.name,
    this.collectionType,
  });

  final String id;
  final String name;

  /// 'movies' | 'tvshows' | 'music' | 'books' | ... | null（混合）。
  final String? collectionType;

  /// 是否值得出现在视频域（音乐/图书/照片库不展示）。
  bool get isVideoish =>
      collectionType == null ||
      const <String>{'movies', 'tvshows', 'homevideos', 'musicvideos', 'mixed'}
          .contains(collectionType);
}

/// 条目里的一条字幕流（外挂或内嵌）。
class JellyfinSubtitleStream {
  const JellyfinSubtitleStream({
    required this.index,
    required this.codec,
    this.language,
    this.title,
    this.isExternal = false,
    this.isTextSubtitleStream = true,
  });

  final int index;
  final String codec;
  final String? language;
  final String? title;
  final bool isExternal;
  final bool isTextSubtitleStream;
}

/// 一个库条目（电影 / 剧 / 季 / 集 / 文件夹）。只保留视频域消费的字段。
class JellyfinItem {
  const JellyfinItem({
    required this.id,
    required this.name,
    required this.type,
    this.isFolder = false,
    this.seriesName,
    this.seasonNumber,
    this.episodeNumber,
    this.durationMs,
    this.hasPrimaryImage = false,
    this.positionMs = 0,
    this.playedPercentage,
    this.mediaSourceId,
    this.subtitleStreams = const <JellyfinSubtitleStream>[],
    this.hasTextSubtitle = false,
    this.sizeBytes,
    this.lastPlayedAtMs = 0,
    this.childCount,
    this.productionYear,
  });

  final String id;
  final String name;

  /// 'Movie' | 'Series' | 'Season' | 'Episode' | 'Folder' | 'BoxSet' | ...
  final String type;
  final bool isFolder;
  final String? seriesName;
  final int? seasonNumber;
  final int? episodeNumber;
  final int? durationMs;
  final bool hasPrimaryImage;

  /// 服务器端 resume 位置（UserData.PlaybackPositionTicks → ms）。
  final int positionMs;
  final double? playedPercentage;

  /// 默认媒体源 id（字幕流 URL 需要）。
  final String? mediaSourceId;
  final List<JellyfinSubtitleStream> subtitleStreams;

  /// 有**可下载文本**字幕（外挂或可提取的内嵌文本轨）。
  ///
  /// 刻意不等于服务器的 HasSubtitles：那面旗子把 PGS/DVDSub 这类图形轨也算上，
  /// 而消费端（[RemoteVideoInfo.hasSubtitle] -> getRemoteVideoSubtitle）只能下
  /// 文本轨，图形轨会抛。所以流表拿得到时以文本轨为准，只有服务器没给流表
  /// （未请求 MediaSources 字段）才回落那面粗粒度旗子。
  final bool hasTextSubtitle;

  /// 默认媒体源的文件字节数（MediaSources[0].Size）；服务器没给则 null。
  final int? sizeBytes;

  /// 服务器端断点的最后更新时刻（UserData.LastPlayedDate -> epoch 毫秒）。
  ///
  /// 0 = 服务器没给（从未播过 / 旧版本）。跨端进度 LWW 只认时间戳，恒 0 等于
  /// 本地恒胜——服务器断点永远读不回来。
  final int lastPlayedAtMs;
  final int? childCount;
  final int? productionYear;

  /// 可直接播放的叶子条目（电影/单集）。
  bool get isPlayableVideo => type == 'Movie' || type == 'Episode';

  /// 展示标题：单集拼上剧名与季集号（`剧名 S01E02 集名`），其余用条目名。
  String get displayTitle {
    if (type != 'Episode' || seriesName == null || seriesName!.isEmpty) {
      return name;
    }
    final String code = (seasonNumber != null && episodeNumber != null)
        ? ' S${seasonNumber.toString().padLeft(2, '0')}'
            'E${episodeNumber.toString().padLeft(2, '0')}'
        : '';
    return '$seriesName$code $name';
  }
}

/// 一页条目（`/Items` 的 TotalRecordCount 分页语义）。
class JellyfinItemsPage {
  const JellyfinItemsPage({required this.items, required this.totalCount});

  final List<JellyfinItem> items;
  final int totalCount;
}

/// Jellyfin HTTP 异常：状态码 + 端点，供 UI 按连接失败呈现。
class JellyfinApiException implements Exception {
  const JellyfinApiException(this.statusCode, this.endpoint);

  final int statusCode;
  final String endpoint;

  @override
  String toString() => 'JellyfinApiException($statusCode, $endpoint)';
}

/// 薄 HTTP 封装。所有 JSON 解析走纯静态方法（离线可测）。
class JellyfinApi {
  JellyfinApi({
    required this.serverUrl,
    this.accessToken,
    http.Client? client,
  }) : _client = client ?? createAppHttpIoClient();

  /// 归一化后的服务器根 URL（含 scheme、无尾斜杠）。
  final String serverUrl;

  /// 访问令牌；[authenticateByName] 成功后回填。
  String? accessToken;

  /// 单个小型请求（JSON / 认证 / 进度上报）的**响应**超时。
  ///
  /// [createAppHttpIoClient] 只带 20s **连接**超时——服务器 TCP 可连但不回响应
  /// （NAS 半死 / 反代挂起）时那层完全不触发：远端库页永久转圈，登录按钮的
  /// spinner 永远退不出来（jellyfin_settings_widget 的 _busy 不复位）。取 15s
  /// 与互联后端同口径（interconnect_sync_backend.dart 的 requestTimeout）。
  ///
  /// 只覆盖小请求：整片/字幕下载的 body 流刻意不挂整体超时（大文件会被误杀）。
  static const Duration kRequestTimeout = Duration(seconds: 15);

  /// [recursiveVideoItems] 的分页熔断上限。
  ///
  /// 不是业务上限，是防死循环：服务器给了错的 TotalRecordCount（或忽略
  /// StartIndex、每页恒返同一批）时，没有它就是无限循环 + 无限内存。
  static const int kMaxRecursiveItems = 20000;

  final http.Client _client;

  /// 归一化用户输入的服务器地址：补 scheme（缺省 http，局域网常态）、去尾斜杠。
  static String normalizeServerUrl(String raw) {
    String url = raw.trim();
    if (url.isEmpty) return url;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'http://$url';
    }
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  /// MediaBrowser 认证头（Jellyfin/Emby 通用；认证前无 Token 字段）。
  Map<String, String> get _headers => <String, String>{
        'Authorization': 'MediaBrowser Client="Hibiki", Device="Hibiki", '
            'DeviceId="hibiki-app", Version="1.0"'
            '${accessToken == null ? '' : ', Token="$accessToken"'}',
        'Content-Type': 'application/json',
      };

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$serverUrl$path').replace(queryParameters: query);

  Future<Map<String, Object?>> _getJson(
    String path, [
    Map<String, String>? query,
  ]) async {
    try {
      final http.Response res = await _client
          .get(_uri(path, query), headers: _headers)
          .timeout(kRequestTimeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw JellyfinApiException(res.statusCode, path);
      }
      final Object? decoded = jsonDecode(utf8.decode(res.bodyBytes));
      return decoded is Map<String, dynamic>
          ? decoded.cast<String, Object?>()
          : <String, Object?>{};
    } on http.ClientException catch (e) {
      // 凭据脱敏必须在异常构造侧（见 credential_redaction.dart 文件头）：
      // ClientException.toString() 把带 api_key 的整条 URL 塞进文本，而
      // ErrorLogService 存的就是 error.toString()，无脱敏落盘并可一键上传。
      throw Exception(redactCredentialsInText(e.toString()));
    }
  }

  /// 用户名/密码认证（POST /Users/AuthenticateByName），成功回填 [accessToken]。
  Future<JellyfinAuthResult> authenticateByName(
    String username,
    String password,
  ) async {
    final http.Response res = await _client
        .post(
          _uri('/Users/AuthenticateByName'),
          headers: _headers,
          body: jsonEncode(
              <String, String>{'Username': username, 'Pw': password}),
        )
        .timeout(kRequestTimeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw JellyfinApiException(res.statusCode, '/Users/AuthenticateByName');
    }
    final Object? decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final JellyfinAuthResult result = parseAuthResult(
        decoded is Map<String, dynamic>
            ? decoded.cast<String, Object?>()
            : <String, Object?>{});
    accessToken = result.accessToken;
    return result;
  }

  /// 用户可见的媒体库视图（GET /Users/{uid}/Views）。
  Future<List<JellyfinLibraryView>> views(String userId) async {
    final Map<String, Object?> json = await _getJson('/Users/$userId/Views');
    return parseViews(json);
  }

  /// 列 [parentId] 的直接子级（GET /Users/{uid}/Items，非递归，浏览用）。
  Future<JellyfinItemsPage> children({
    required String userId,
    String? parentId,
    int startIndex = 0,
    int limit = 200,
  }) async {
    final Map<String, Object?> json =
        await _getJson('/Users/$userId/Items', <String, String>{
      if (parentId != null) 'ParentId': parentId,
      'StartIndex': '$startIndex',
      'Limit': '$limit',
      'Fields': 'ChildCount,ProductionYear',
      'SortBy': 'IsFolder,SortName',
      'SortOrder': 'Ascending',
    });
    return parseItemsPage(json);
  }

  /// 递归列出 [parentId]（缺省全库）下所有可播视频叶子（电影 + 单集）。
  ///
  /// **真分页**：单发一次 + 硬上限的旧写法在 100 部番 x 12 集就到顶，第 2001 条
  /// 起永久不可见且无任何提示；TotalRecordCount 解出来却被丢弃、StartIndex 根本
  /// 没传。这里按 [pageSize] 逐页取到 StartIndex >= totalCount（或某页返空）为止，
  /// 熔断见 [kMaxRecursiveItems]。
  ///
  /// Fields 带 MediaSources：清单卡的「有无外挂字幕 / 文件大小」全靠它——缺了
  /// 这段，下载入库的 Jellyfin 视频永远进不了外挂字幕下载分支。
  Future<List<JellyfinItem>> recursiveVideoItems({
    required String userId,
    String? parentId,
    int pageSize = 500,
  }) async {
    final List<JellyfinItem> all = <JellyfinItem>[];
    int start = 0;
    while (start < kMaxRecursiveItems) {
      final Map<String, Object?> json =
          await _getJson('/Users/$userId/Items', <String, String>{
        if (parentId != null) 'ParentId': parentId,
        'Recursive': 'true',
        'IncludeItemTypes': 'Movie,Episode',
        'StartIndex': '$start',
        'Limit': '$pageSize',
        'Fields': 'ProductionYear,MediaSources',
        'SortBy': 'SortName',
        'SortOrder': 'Ascending',
      });
      final JellyfinItemsPage page = parseItemsPage(json);
      all.addAll(page.items);
      if (page.items.isEmpty) break;
      start += page.items.length;
      if (start >= page.totalCount) break;
    }
    return all;
  }

  /// 单条目详情（含 MediaSources/MediaStreams，字幕流选择用）。
  Future<JellyfinItem> itemDetail({
    required String userId,
    required String itemId,
  }) async {
    final Map<String, Object?> json =
        await _getJson('/Users/$userId/Items/$itemId');
    return parseItem(json);
  }

  /// 播放中的周期进度上报（POST /Sessions/Playing/Progress）。
  ///
  /// 无会话生命周期也会持久化 resume 位置，是 scrobbler 类客户端的通用做法；
  /// 与 [reportStopped] 的区别在**语义**：Progress 是「还在播」，Stopped 是
  /// 「不播了」。周期心跳必须走这条，节流档见
  /// [JellyfinVideoClient.kPositionReportIntervalMs]。
  Future<void> reportProgress({
    required String itemId,
    required int positionMs,
  }) async {
    final http.Response res = await _client
        .post(
          _uri('/Sessions/Playing/Progress'),
          headers: _headers,
          body: jsonEncode(<String, Object?>{
            'ItemId': itemId,
            'PositionTicks': positionMs * kTicksPerMs,
            'IsPaused': false,
          }),
        )
        .timeout(kRequestTimeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw JellyfinApiException(res.statusCode, '/Sessions/Playing/Progress');
    }
  }

  /// 停止播放上报（POST /Sessions/Playing/Stopped）。
  ///
  /// **只在真正停止播放时发**。服务器对它有额外副作用：接近片尾时把条目标记为
  /// 已播放并清空 resume 位置，并写活动日志 / 触发 webhook / 计一次 Playback
  /// Reporting。拿它当每秒心跳用 = 一集 24 分钟番刷约 1400 条假「播放已停止」，
  /// 统计作废。周期上报用 [reportProgress]。
  Future<void> reportStopped({
    required String itemId,
    required int positionMs,
  }) async {
    final http.Response res = await _client
        .post(
          _uri('/Sessions/Playing/Stopped'),
          headers: _headers,
          body: jsonEncode(<String, Object?>{
            'ItemId': itemId,
            'PositionTicks': positionMs * kTicksPerMs,
          }),
        )
        .timeout(kRequestTimeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw JellyfinApiException(res.statusCode, '/Sessions/Playing/Stopped');
    }
  }

  /// 直连播放流 URL（static=true 原文件直出，内嵌字幕/音轨全保留；`api_key`
  /// 查询参数自带认证——[RemoteVideoStreamUrls] 没有 HTTP 头通道）。
  String streamUrl(String itemId) =>
      '$serverUrl/Videos/$itemId/stream?static=true&api_key=${accessToken ?? ''}';

  /// 封面 URL（Primary 图；无图的条目由调用方按 hasPrimaryImage 过滤）。
  String imageUrl(String itemId) =>
      '$serverUrl/Items/$itemId/Images/Primary?api_key=${accessToken ?? ''}';

  /// 字幕流下载 URL（外挂或可提取文本内嵌轨都走这个端点）。
  String subtitleUrl({
    required String itemId,
    required String mediaSourceId,
    required int streamIndex,
    required String codec,
  }) {
    final String ext = _subtitleExt(codec);
    return '$serverUrl/Videos/$itemId/$mediaSourceId/Subtitles/$streamIndex'
        '/Stream.$ext?api_key=${accessToken ?? ''}';
  }

  static String _subtitleExt(String codec) {
    switch (codec.toLowerCase()) {
      case 'subrip':
      case 'srt':
        return 'srt';
      case 'ass':
      case 'ssa':
        return 'ass';
      case 'webvtt':
      case 'vtt':
        return 'vtt';
      default:
        // 图形字幕（pgs/dvdsub）无法转文本，调用方不应选到这里；兜底转 vtt。
        return 'vtt';
    }
  }

  /// 拉取 [url] 的全部字节（封面用）。非 2xx 抛 [JellyfinApiException]。
  Future<Uint8List> fetchBytes(String url) async {
    try {
      final http.Response res =
          await _client.get(Uri.parse(url), headers: _headers);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw JellyfinApiException(res.statusCode, Uri.parse(url).path);
      }
      return res.bodyBytes;
    } on http.ClientException catch (e) {
      // [url] 自带 api_key（见 imageUrl / streamUrl / subtitleUrl）——网络层失败
      // 时 ClientException.toString() 会把整条带令牌的 URL 泄进错误文本，而那条
      // 文本会无脱敏落进 ErrorLogService 并可一键上传。
      throw Exception(redactCredentialsInText(e.toString()));
    }
  }

  /// 通用下载：GET [url] 流式写入 [dest]，按 Content-Length 汇报进度。
  Future<void> downloadToFile(
    String url,
    File dest, {
    void Function(double progress)? onProgress,
  }) async {
    try {
      final http.Request req = http.Request('GET', Uri.parse(url));
      req.headers.addAll(_headers);
      // 只给「拿到响应头」挂超时；下面的 body 流刻意不挂整体超时——整片下载几十
      // 分钟是正常的，套上去就是误杀。
      final http.StreamedResponse res =
          await _client.send(req).timeout(kRequestTimeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw JellyfinApiException(res.statusCode, Uri.parse(url).path);
      }
      final int? total = res.contentLength;
      int received = 0;
      final IOSink sink = dest.openWrite();
      bool ok = false;
      try {
        await for (final List<int> chunk in res.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (total != null && total > 0) {
            onProgress?.call(received / total);
          }
        }
        ok = true;
      } finally {
        await sink.close();
        if (!ok) {
          try {
            dest.deleteSync();
          } catch (_) {
            // best-effort 清理半截文件：删不掉（文件被占 / 权限）时也不该盖住
            // 上面真正的失败原因，调用方拿到的仍是原始异常。
          }
        }
      }
    } on http.ClientException catch (e) {
      // 同 fetchBytes：[url] 带 api_key，异常文本必须在构造侧脱敏。
      throw Exception(redactCredentialsInText(e.toString()));
    }
  }

  void close() => _client.close();

  // ── 纯 JSON 解析（离线可测） ─────────────────────────────────────────

  static JellyfinAuthResult parseAuthResult(Map<String, Object?> json) {
    final Map<String, Object?> user =
        (json['User'] as Map?)?.cast<String, Object?>() ?? <String, Object?>{};
    return JellyfinAuthResult(
      accessToken: (json['AccessToken'] as String?) ?? '',
      userId: (user['Id'] as String?) ?? '',
      serverName: json['ServerName'] as String?,
    );
  }

  static List<JellyfinLibraryView> parseViews(Map<String, Object?> json) {
    final List<Object?> items = (json['Items'] as List?) ?? const <Object?>[];
    return <JellyfinLibraryView>[
      for (final Object? raw in items)
        if (raw is Map)
          JellyfinLibraryView(
            id: (raw['Id'] as String?) ?? '',
            name: (raw['Name'] as String?) ?? '',
            collectionType: raw['CollectionType'] as String?,
          ),
    ];
  }

  static JellyfinItemsPage parseItemsPage(Map<String, Object?> json) {
    final List<Object?> items = (json['Items'] as List?) ?? const <Object?>[];
    return JellyfinItemsPage(
      items: <JellyfinItem>[
        for (final Object? raw in items)
          if (raw is Map) parseItem(raw.cast<String, Object?>()),
      ],
      totalCount: (json['TotalRecordCount'] as num?)?.toInt() ?? items.length,
    );
  }

  static JellyfinItem parseItem(Map<String, Object?> json) {
    final Map<String, Object?> userData =
        (json['UserData'] as Map?)?.cast<String, Object?>() ??
            <String, Object?>{};
    final int? runTimeTicks = (json['RunTimeTicks'] as num?)?.toInt();
    final int positionTicks =
        (userData['PlaybackPositionTicks'] as num?)?.toInt() ?? 0;

    // 默认媒体源 + 字幕流：取 MediaSources[0]（direct play 与 stream URL 同源）。
    String? mediaSourceId;
    int? sizeBytes;
    final List<JellyfinSubtitleStream> subs = <JellyfinSubtitleStream>[];
    final List<Object?> sources =
        (json['MediaSources'] as List?) ?? const <Object?>[];
    if (sources.isNotEmpty && sources.first is Map) {
      final Map<String, Object?> src =
          (sources.first as Map).cast<String, Object?>();
      mediaSourceId = src['Id'] as String?;
      sizeBytes = (src['Size'] as num?)?.toInt();
      final List<Object?> streams =
          (src['MediaStreams'] as List?) ?? const <Object?>[];
      for (final Object? raw in streams) {
        if (raw is! Map) continue;
        final Map<String, Object?> s = raw.cast<String, Object?>();
        if (s['Type'] != 'Subtitle') continue;
        subs.add(JellyfinSubtitleStream(
          index: (s['Index'] as num?)?.toInt() ?? 0,
          codec: (s['Codec'] as String?) ?? '',
          language: s['Language'] as String?,
          title: s['DisplayTitle'] as String?,
          isExternal: (s['IsExternal'] as bool?) ?? false,
          isTextSubtitleStream: (s['IsTextSubtitleStream'] as bool?) ?? true,
        ));
      }
    }

    final Map<String, Object?> imageTags =
        (json['ImageTags'] as Map?)?.cast<String, Object?>() ??
            <String, Object?>{};

    return JellyfinItem(
      id: (json['Id'] as String?) ?? '',
      name: (json['Name'] as String?) ?? '',
      type: (json['Type'] as String?) ?? '',
      isFolder: (json['IsFolder'] as bool?) ?? false,
      seriesName: json['SeriesName'] as String?,
      seasonNumber: (json['ParentIndexNumber'] as num?)?.toInt(),
      episodeNumber: (json['IndexNumber'] as num?)?.toInt(),
      durationMs: runTimeTicks == null ? null : runTimeTicks ~/ kTicksPerMs,
      hasPrimaryImage: imageTags.containsKey('Primary'),
      positionMs: positionTicks ~/ kTicksPerMs,
      playedPercentage: (userData['PlayedPercentage'] as num?)?.toDouble(),
      mediaSourceId: mediaSourceId,
      subtitleStreams: subs,
      // 流表拿得到就以文本轨为准；拿不到（未请求 MediaSources 字段）才回落服务器
      // 的粗粒度 HasSubtitles——它把图形轨也算 true，见 [JellyfinItem.hasTextSubtitle]。
      hasTextSubtitle: subs.isEmpty
          ? ((json['HasSubtitles'] as bool?) ?? false)
          : subs.any((JellyfinSubtitleStream s) => s.isTextSubtitleStream),
      sizeBytes: sizeBytes,
      lastPlayedAtMs:
          DateTime.tryParse((userData['LastPlayedDate'] as String?) ?? '')
                  ?.millisecondsSinceEpoch ??
              0,
      childCount: (json['ChildCount'] as num?)?.toInt(),
      productionYear: (json['ProductionYear'] as num?)?.toInt(),
    );
  }
}

/// Jellyfin 服务器作为远端视频源：把条目适配成互联/云端同款契约。
///
/// [remoteLibrarySourceId] 按「服务器 + 用户」细分（不同服务器/不同账号 = 不同
/// 清单 = 不同缓存槽，见 remote_library_source.dart 的 BUG-1202 口径）。用户维度
/// 不能省：同机登出 A 登入 B，只按 URL 分槽会让 B 在 TTL 内看到 A 的库清单。
///
/// 「显示视频库」的结构表达：单集经 [RemoteCollectionMembership] 按剧名折叠成
/// playlist 合集卡（组内序 = 季×10000+集），复用库页既有的合集混排/上下集/
/// 剧集面板——不另造 Jellyfin 专属浏览层。
class JellyfinVideoClient implements RemoteVideoClient, RemoteCoverFetcher {
  JellyfinVideoClient({required this.api, required this.userId});

  final JellyfinApi api;
  final String userId;

  /// 缓存槽身份的**唯一**构造点。登出失效等「手里没有 client 实例」的调用方也
  /// 走这里，别再各自拼字面量——拼歪一个字符就是「以为清了、其实没清」。
  static String sourceIdFor({
    required String serverUrl,
    required String userId,
  }) =>
      'jellyfin:$serverUrl|$userId';

  @override
  String get remoteLibrarySourceId =>
      sourceIdFor(serverUrl: api.serverUrl, userId: userId);

  @override
  Future<Uint8List> fetchRemoteCover(String coverUrl) =>
      api.fetchBytes(coverUrl);

  /// 磁盘封面缓存命名空间（BUG-1693 口径：配对身份级）：服务器 + 用户。
  /// 换令牌（重新登录同账号）不变——封面没变别白白重下；换服务器/账号必变。
  @override
  String get coverCacheNamespace =>
      'jellyfin-${sha1.convert(utf8.encode('${api.serverUrl}|$userId'))}';

  /// 把一个条目适配成 [RemoteVideoInfo]（列表卡片消费）。
  ///
  /// [RemoteVideoInfo.hasSubtitle] 必须真实填：库页的下载入库路径用它做早返门
  /// （`if (!video.hasSubtitle) return ...`），吃默认 false 就等于「从 Jellyfin
  /// 下载的视频永远不下外挂字幕」，[getRemoteVideoSubtitle] 实现了也进不去。
  RemoteVideoInfo infoFromItem(JellyfinItem item) {
    final JellyfinSubtitleStream? subtitle = _defaultTextSubtitle(item);
    return RemoteVideoInfo(
      id: item.id,
      title: item.displayTitle,
      sizeBytes: item.sizeBytes,
      hasSubtitle: item.hasTextSubtitle,
      subtitleFileName:
          subtitle == null ? null : _subtitleFileName(item, subtitle),
      durationMs: item.durationMs,
      hasCover: item.hasPrimaryImage,
      coverUrl: item.hasPrimaryImage ? api.imageUrl(item.id) : null,
      positionMs: item.positionMs,
      positionUpdatedAtMs: item.lastPlayedAtMs,
      collection: _collectionOf(item),
    );
  }

  /// 「没指定轨时该下哪条字幕」的唯一判据：外挂文本轨优先，其次第一条文本轨；
  /// 无文本轨返回 null。清单卡的文件名与 [getRemoteVideoSubtitle] 共用它，避免
  /// 两处各写一遍挑轨规则再慢慢跑偏。
  static JellyfinSubtitleStream? _defaultTextSubtitle(JellyfinItem item) {
    JellyfinSubtitleStream? fallback;
    for (final JellyfinSubtitleStream s in item.subtitleStreams) {
      if (!s.isTextSubtitleStream) continue;
      if (s.isExternal) return s;
      fallback ??= s;
    }
    return fallback;
  }

  /// 单集 → 按剧名归入 playlist 合集（库页折叠成一张剧卡）；电影独立。
  static RemoteCollectionMembership? _collectionOf(JellyfinItem item) {
    final String? series = item.seriesName;
    if (item.type != 'Episode' || series == null || series.isEmpty) {
      return null;
    }
    return RemoteCollectionMembership(
      collectionName: series,
      collectionType: 'playlist',
      sortIndex: (item.seasonNumber ?? 0) * 10000 + (item.episodeNumber ?? 0),
    );
  }

  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() async {
    final List<JellyfinItem> items =
        await api.recursiveVideoItems(userId: userId);
    return <RemoteVideoInfo>[
      for (final JellyfinItem item in items)
        if (item.isPlayableVideo) infoFromItem(item),
    ];
  }

  @override
  Future<void> downloadRemoteVideo(
    String id,
    File dest, {
    void Function(double progress)? onProgress,
  }) =>
      api.downloadToFile(api.streamUrl(id), dest, onProgress: onProgress);

  @override
  Future<RemoteVideoStreamUrls> remoteVideoStreamUrls(
    String id, {
    int episodeIndex = 0,
  }) async {
    // Jellyfin 的每一集都是独立条目，episodeIndex 恒 0（多集语义不适用）。
    final JellyfinItem item = await api.itemDetail(userId: userId, itemId: id);
    final String? mediaSourceId = item.mediaSourceId;

    // 外挂文本字幕优先作为默认外挂轨；其余文本轨全部报给播放页的字幕轨选择器。
    JellyfinSubtitleStream? external;
    final List<RemoteVideoEmbeddedSubtitleTrack> tracks =
        <RemoteVideoEmbeddedSubtitleTrack>[];
    for (final JellyfinSubtitleStream s in item.subtitleStreams) {
      if (!s.isTextSubtitleStream || mediaSourceId == null) continue;
      final String url = api.subtitleUrl(
        itemId: id,
        mediaSourceId: mediaSourceId,
        streamIndex: s.index,
        codec: s.codec,
      );
      external ??= s.isExternal ? s : null;
      tracks.add(RemoteVideoEmbeddedSubtitleTrack(
        streamIndex: s.index,
        codec: s.codec,
        language: s.language,
        title: s.title,
        url: url,
        fileName: _subtitleFileName(item, s),
      ));
    }

    return RemoteVideoStreamUrls(
      streamUrl: api.streamUrl(id),
      subtitleUrl: external == null || mediaSourceId == null
          ? null
          : api.subtitleUrl(
              itemId: id,
              mediaSourceId: mediaSourceId,
              streamIndex: external.index,
              codec: external.codec,
            ),
      subtitleFileName:
          external == null ? null : _subtitleFileName(item, external),
      // direct play 是单条 muxed 流（自带音轨）。
      miningVideoHasAudio: true,
      embeddedSubtitleTracks: tracks,
    );
  }

  static String _subtitleFileName(JellyfinItem item, JellyfinSubtitleStream s) {
    final String ext = JellyfinApi._subtitleExt(s.codec);
    final String lang = (s.language ?? '').isEmpty ? '' : '.${s.language}';
    return '${item.displayTitle}$lang.$ext';
  }

  @override
  Future<void> getRemoteVideoSubtitle(
    String id,
    File dest, {
    int? embeddedStreamIndex,
    int episodeIndex = 0,
    void Function(double progress)? onProgress,
  }) async {
    final JellyfinItem item = await api.itemDetail(userId: userId, itemId: id);
    final String? mediaSourceId = item.mediaSourceId;
    if (mediaSourceId == null) {
      throw const FileSystemException('Jellyfin item has no media source');
    }
    JellyfinSubtitleStream? pick;
    if (embeddedStreamIndex == null) {
      pick = _defaultTextSubtitle(item);
    } else {
      for (final JellyfinSubtitleStream s in item.subtitleStreams) {
        if (s.isTextSubtitleStream && s.index == embeddedStreamIndex) {
          pick = s;
          break;
        }
      }
    }
    if (pick == null) {
      throw const FileSystemException('Jellyfin item has no text subtitle');
    }
    await api.downloadToFile(
      api.subtitleUrl(
        itemId: id,
        mediaSourceId: mediaSourceId,
        streamIndex: pick.index,
        codec: pick.codec,
      ),
      dest,
      onProgress: onProgress,
    );
  }

  @override
  Future<({int positionMs, int updatedAtMs})> remoteVideoPosition(
    String id, {
    int episodeIndex = 0,
  }) async {
    final JellyfinItem item = await api.itemDetail(userId: userId, itemId: id);
    // UserData.LastPlayedDate 就是服务器侧的「位置更新时刻」。恒报 0 会让
    // fushi_library_host_service 的 LWW（localUpdatedAtMs > remoteUpdatedAtMs）
    // 本地恒胜——「手机看一半回电脑接力」永远拿不到服务器断点。
    // 服务器没给（从未播过）时 lastPlayedAtMs 自然是 0，退回旧行为。
    return (positionMs: item.positionMs, updatedAtMs: item.lastPlayedAtMs);
  }

  /// 进度心跳的最小间隔。Jellyfin web 客户端就是 10s 一档。
  ///
  /// 调用方（video_fushi_page 的 _persistRemotePosition）是**每秒**级的位置回调；
  /// 不节流就是一集 24 分钟番打约 1400 次上报。
  static const int kPositionReportIntervalMs = 10000;

  int _lastReportAtMs = 0;

  /// 上一次上报的条目。换条目 = 换一次播放，节流窗口重开——否则切集后 10s 内的
  /// 第一次上报会被上一集的窗口白白吃掉。
  String _lastReportItemId = '';

  @override
  Future<void> putRemoteVideoPosition(
    String id,
    int positionMs,
    int updatedAtMs, {
    int episodeIndex = 0,
  }) async {
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    if (id == _lastReportItemId &&
        nowMs - _lastReportAtMs < kPositionReportIntervalMs) {
      return;
    }
    _lastReportAtMs = nowMs;
    _lastReportItemId = id;
    // 播放中的周期上报走 Progress，不是 Stopped（后者会标记已播放、清 resume
    // 位置并刷爆活动日志，见 [JellyfinApi.reportStopped]）。
    // last-write-wins（服务器无按时间戳合并）；updatedAtMs 不上传。
    await api.reportProgress(itemId: id, positionMs: positionMs);
  }

  void close() => api.close();
}
