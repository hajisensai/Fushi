// Jellyfin / Emby 媒体服务器视频客户端。
//
// 两层结构：
// - [JellyfinApi]：薄 HTTP 封装（认证 / 视图 / 条目 / 进度上报 / URL 构造），
//   JSON→DTO 解析全部是纯静态方法，测试用 MockClient 离线覆盖。
// - [JellyfinVideoClient] `implements RemoteVideoClient`：把 Jellyfin 条目适配成
//   互联/云端同款的远端视频契约（列清单 / 整片下载 / 流播 URL / 外挂字幕 /
//   跨端断点），库页与播放页零新概念消费。同一个类还 `implements
//   MediaServerBrowser`（media_server_browser.dart）：把服务器的
//   媒体库 → 剧 → 季 → 集 树按父级分页原样暴露给浏览页，不再全库递归拍平。
//   两套契约共用一份 JSON 解析（[JellyfinApi.parseItem] → [JellyfinItem]），
//   浏览用的 [MediaServerItem] 只是它的纯函数投影
//   （[JellyfinVideoClient.mediaServerItemFrom]）。
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
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:http/http.dart' as http;

import 'package:fushi_engine/media/metadata/credential_redaction.dart'
    show redactCredentialsInText;
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/media/video/media_server/media_server_search_match.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show
        RemoteCollectionMembership,
        RemoteVideoEmbeddedSubtitleTrack,
        RemoteVideoInfo,
        RemoteVideoStreamUrls;
import 'package:fushi/src/sync/remote_cover_fetcher.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:fushi_engine/utils/net/url_input_normalizer.dart';

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
    this.libraryIds = const <String>[],
    this.deviceId = JellyfinApi.kLegacyDeviceId,
    this.alternateUrls = const <String>[],
    this.activeServerUrl = '',
  });

  /// 归一化后的服务器根 URL（[JellyfinApi.normalizeServerUrl] 口径）。
  ///
  /// 这是**登录时用的那条地址**，同时也是这台服务器在本机的身份锚
  /// （[JellyfinVideoClient.sourceIdFor] / 封面缓存命名空间 / 浏览页 PageStorage
  /// 键全都拿它拼）。多线路之后它**不再是请求一定走的地址**——请求走
  /// [effectiveServerUrl]；身份锚保持不变，切线路才不会把远端清单缓存槽、封面
  /// 缓存与浏览页状态一起切成另一台「新服务器」。
  final String serverUrl;

  /// 这台服务器的其它访问地址（线路）：局域网 / 公网 / 反代 / 内网穿透各一条，
  /// 归一化口径同 [serverUrl]、不含 [serverUrl] 本身、去重且保持用户添加顺序。
  /// 令牌按 DeviceId 归属、与地址无关，所以同一份 [accessToken] 在每条线路上都
  /// 直接可用，添加线路不需要重新登录。
  final List<String> alternateUrls;

  /// 当前请求走的线路；空串 = [serverUrl]。持久化只在它不等于 [serverUrl] 时
  /// 才写，旧配置读进来自然落到主地址。**必须**是 [routeUrls] 之一，不是的话
  /// [effectiveServerUrl] 回落主地址（线路被删了但 active 没同步清掉的防御）。
  final String activeServerUrl;

  /// 全部线路：主地址在首位，后面按添加顺序。
  List<String> get routeUrls => <String>[serverUrl, ...alternateUrls];

  /// 请求实际走的根 URL（[buildClient] 用它建 [JellyfinApi]）。
  String get effectiveServerUrl =>
      activeServerUrl.isNotEmpty && routeUrls.contains(activeServerUrl)
          ? activeServerUrl
          : serverUrl;
  final String username;
  final String userId;
  final String accessToken;
  final String? serverName;

  /// 登录时向服务器声明的设备身份（见 [JellyfinApi.deviceId]）。令牌与它绑定，
  /// 所以随配置持久化；旧配置没有该字段 → [JellyfinApi.kLegacyDeviceId]。
  final String deviceId;

  /// 要枚举的媒体库视图 id（BUG-1891）。**空 = 全部视频域媒体库**（由
  /// [JellyfinVideoClient.resolveEnumerationParents] 经 `/Users/{uid}/Views` +
  /// [JellyfinLibraryView.isVideoish] 解析），不是「整台服务器递归」——几十万
  /// 条目的公共 Emby 服上，整库递归 = 几十上百个重查询连发，观感与负载都和刮削
  /// 一样，还会撞服务器的滥用检测。库 id 是**每服务器**的 GUID，所以它落在
  /// 本配置的 JSON 里（登出即随键一起删），不进全局偏好表。
  final List<String> libraryIds;

  Map<String, Object?> toJson() => <String, Object?>{
        'serverUrl': serverUrl,
        'username': username,
        'userId': userId,
        'accessToken': accessToken,
        if (serverName != null) 'serverName': serverName,
        if (libraryIds.isNotEmpty) 'libraryIds': libraryIds,
        if (deviceId != JellyfinApi.kLegacyDeviceId) 'deviceId': deviceId,
        if (alternateUrls.isNotEmpty) 'alternateUrls': alternateUrls,
        if (activeServerUrl.isNotEmpty && activeServerUrl != serverUrl)
          'activeServerUrl': activeServerUrl,
      };

  static JellyfinServerConfig? fromJson(Map<String, dynamic> json) {
    final String serverUrl = (json['serverUrl'] as String?) ?? '';
    final String userId = (json['userId'] as String?) ?? '';
    final String accessToken = (json['accessToken'] as String?) ?? '';
    if (serverUrl.isEmpty || userId.isEmpty || accessToken.isEmpty) {
      return null;
    }
    // 与 _addRoute 同口径先归一化（手改 JSON / 备份还原带尾斜杠或大写 scheme
    // 时，否则 contains 不中、active 静默回落主地址）。
    final List<String> alternateUrls = normalizeAlternateUrls(
      serverUrl,
      <String>[
        for (final Object? raw
            in (json['alternateUrls'] as List?) ?? const <Object?>[])
          if (raw is String) JellyfinApi.normalizeServerUrl(raw),
      ],
    );
    return JellyfinServerConfig(
      serverUrl: serverUrl,
      username: (json['username'] as String?) ?? '',
      userId: userId,
      accessToken: accessToken,
      serverName: json['serverName'] as String?,
      libraryIds: <String>[
        for (final Object? raw in (json['libraryIds'] as List?) ?? const <Object?>[])
          if (raw is String && raw.isNotEmpty) raw,
      ],
      deviceId: ((json['deviceId'] as String?) ?? '').isEmpty
          ? JellyfinApi.kLegacyDeviceId
          : json['deviceId'] as String,
      alternateUrls: alternateUrls,
      activeServerUrl: JellyfinApi.normalizeServerUrl(
        (json['activeServerUrl'] as String?) ?? '',
      ),
    );
  }

  /// 这台服务器是否经 [url] 可达（登录地址或任一备用线路）。同一账号从任一线路
  /// 重新登录都算同一台——否则令牌过期时用公网地址再登一次会生成第二条记录
  /// （两个 sourceId / 两套封面 namespace / 两张卡）。
  bool ownsRoute(String url) => routeUrls.contains(url);

  /// 重新登录后的配置：身份锚（登录地址）、线路、库选择照旧，只换会话字段，
  /// 并把本次真正连通的 [signedInUrl] 设为当前线路（它是登录地址时 active 清空）。
  JellyfinServerConfig withRefreshedSession({
    required String username,
    required String accessToken,
    required String deviceId,
    required String signedInUrl,
    String? serverName,
  }) => JellyfinServerConfig(
    serverUrl: serverUrl,
    username: username,
    userId: userId,
    accessToken: accessToken,
    serverName: serverName ?? this.serverName,
    libraryIds: libraryIds,
    deviceId: deviceId,
    alternateUrls: alternateUrls,
  ).copyWithRoutes(activeServerUrl: signedInUrl);

  /// 备用线路清单的唯一整理点：去空、去重、剔掉与主地址 [serverUrl] 相同的项，
  /// 保持首次出现顺序。[fromJson]（旧 JSON 手改 / 备份还原）与 [copyWithRoutes]
  /// （UI 添加）都经这里，`routeUrls` 里才不会出现两条一样的线路。
  static List<String> normalizeAlternateUrls(
    String serverUrl,
    Iterable<String> urls,
  ) {
    final List<String> result = <String>[];
    for (final String url in urls) {
      if (url.isEmpty || url == serverUrl || result.contains(url)) continue;
      result.add(url);
    }
    return result;
  }

  /// 复制并替换要枚举的媒体库（设置页保存选择用）。
  JellyfinServerConfig copyWithLibraryIds(List<String> ids) =>
      JellyfinServerConfig(
        serverUrl: serverUrl,
        username: username,
        userId: userId,
        accessToken: accessToken,
        serverName: serverName,
        libraryIds: ids,
        deviceId: deviceId,
        alternateUrls: alternateUrls,
        activeServerUrl: activeServerUrl,
      );

  /// 复制并替换线路：[alternateUrls] 缺省不动；[activeServerUrl] 缺省不动，
  /// 但结果里 active 不在新的 [routeUrls] 内时（删掉了正在用的线路）回落主地址。
  JellyfinServerConfig copyWithRoutes({
    List<String>? alternateUrls,
    String? activeServerUrl,
  }) {
    final List<String> nextAlternates = alternateUrls == null
        ? this.alternateUrls
        : normalizeAlternateUrls(serverUrl, alternateUrls);
    final String requestedActive = activeServerUrl ?? this.activeServerUrl;
    final String nextActive =
        requestedActive == serverUrl || !nextAlternates.contains(requestedActive)
            ? ''
            : requestedActive;
    return JellyfinServerConfig(
      serverUrl: serverUrl,
      username: username,
      userId: userId,
      accessToken: accessToken,
      serverName: serverName,
      libraryIds: libraryIds,
      deviceId: deviceId,
      alternateUrls: nextAlternates,
      activeServerUrl: nextActive,
    );
  }

  /// 从配置构造可用客户端（每次取数新建实例，缓存身份见
  /// [JellyfinVideoClient.remoteLibrarySourceId]）。请求走当前线路
  /// [effectiveServerUrl]，身份锚仍是 [serverUrl]。
  JellyfinVideoClient buildClient({http.Client? httpClient}) =>
      JellyfinVideoClient(
        api: JellyfinApi(
          serverUrl: effectiveServerUrl,
          accessToken: accessToken,
          deviceId: deviceId,
          client: httpClient,
        ),
        userId: userId,
        libraryIds: libraryIds,
        serverName: serverName,
        identityServerUrl: serverUrl,
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
    this.hasPrimaryImage = false,
  });

  final String id;
  final String name;

  /// 'movies' | 'tvshows' | 'music' | 'books' | ... | null（混合）。
  final String? collectionType;

  /// 库视图自己有没有主图（`ImageTags.Primary`；Jellyfin 允许给媒体库配封面）。
  final bool hasPrimaryImage;

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
    this.originalTitle,
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
    this.recursiveItemCount,
    this.productionYear,
    this.seriesId,
    this.seasonId,
    this.played = false,
    this.unplayedChildCount,
    this.hasBackdrop = false,
    this.hasThumbImage = false,
    this.hasLogoImage = false,
    this.overview,
    this.communityRating,
    this.genres = const <String>[],
  });

  final String id;
  final String name;

  /// 'Movie' | 'Series' | 'Season' | 'Episode' | 'Folder' | 'BoxSet' | ...
  final String type;
  final bool isFolder;

  /// 原名（`OriginalTitle`）。Emby 要显式 `Fields=OriginalTitle` 才给，Jellyfin
  /// 缺省带；搜索把关（BUG-2608）按它和 [name] 一起匹配。
  final String? originalTitle;
  final String? seriesName;
  final int? seasonNumber;
  final int? episodeNumber;
  final int? durationMs;
  final bool hasPrimaryImage;

  /// 集 / 季所属的剧与集所属的季（`SeriesId` / `SeasonId`）。浏览页靠它们从
  /// 「继续观看 / 接下来看」的一集跳回剧与季，不用再按剧名字符串折叠。
  final String? seriesId;
  final String? seasonId;

  /// 服务器标记为已看完（`UserData.Played`）。
  final bool played;

  /// 容器的未看子项数（`UserData.UnplayedItemCount`）。
  final int? unplayedChildCount;

  /// 横版背景 / 横版缩略图 / logo 有无（`BackdropImageTags` 非空 /
  /// `ImageTags.Thumb` / `ImageTags.Logo`）。
  final bool hasBackdrop;
  final bool hasThumbImage;
  final bool hasLogoImage;

  /// 详情字段（`Overview` / `CommunityRating` / `Genres`）：清单请求不带对应
  /// Fields 时为空，单条目 `/Items/{id}` 全量返回。
  final String? overview;
  final double? communityRating;
  final List<String> genres;

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

  /// 递归子项数（`RecursiveItemCount`）。对剧 = 集数——[childCount] 对剧是**季数**
  /// （Emby 4.9 真机：ChildCount=1 / RecursiveItemCount=26），拿它当集数显示会得到
  /// 「全 1 话」。Emby 缺省就返回，Jellyfin 要在 Fields 里点名。
  final int? recursiveItemCount;
  final int? productionYear;

  /// 可直接播放的叶子条目（电影/单集）。
  bool get isPlayableVideo => type == 'Movie' || type == 'Episode';

  /// 可下钻的容器条目（剧 / 季 / 合集 / 文件夹）。
  ///
  /// 只在[JellyfinApi.recursiveVideoItems] 的层级回退里用（BUG-2567）：服务器忽略
  /// `Recursive` 时返回的就是这些，它们本身不可播，但下面挂着真正的叶子。
  /// 刻意不用服务器的 `IsFolder`——Emby 兼容实现对它的填法各不相同（本次实测
  /// UHD Media Server 的 Series 条目压根不带该字段），按类型名判定才稳。
  bool get isVideoContainer =>
      type == 'Series' ||
      type == 'Season' ||
      type == 'BoxSet' ||
      type == 'Folder' ||
      type == 'CollectionFolder';

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

/// 一次递归枚举的结果（BUG-1891）。
///
/// 单独一个类而不是裸 `List`：`kMaxRecursiveItems` 熔断此前是**静默截断**——几十万
/// 条目的服务器上用户拿到的是「前 20000 条」，却没有任何地方说过这件事，看起来就是
/// 「库里就这么多」。把截断事实与服务器报的总数一起带出来，调用方才有得报。
class JellyfinRecursiveResult {
  const JellyfinRecursiveResult({
    required this.items,
    required this.truncated,
    required this.totalCount,
  });

  final List<JellyfinItem> items;

  /// 是否撞上 [JellyfinApi.kMaxRecursiveItems] 提前收工（= 拿到的不是全部）。
  final bool truncated;

  /// 服务器报的 TotalRecordCount（多库枚举时为各库之和）。
  final int totalCount;
}

/// `POST /Items/{id}/PlaybackInfo` 的解析结果。
class JellyfinPlaybackInfo {
  const JellyfinPlaybackInfo({
    required this.playSessionId,
    required this.mediaSources,
    this.errorCode,
  });

  /// 本次播放的会话 id；服务器没给（兼容层）为 null。
  final String? playSessionId;

  /// 服务器拒绝播放时的错误码（`NotAllowed` / `RateLimitExceeded` …）。
  final String? errorCode;
  final List<JellyfinPlaybackMediaSource> mediaSources;
}

/// PlaybackInfo 里的一条媒体源及服务器对它的播放裁决。
class JellyfinPlaybackMediaSource {
  const JellyfinPlaybackMediaSource({
    required this.id,
    this.supportsDirectPlay = false,
    this.supportsDirectStream = false,
    this.supportsTranscoding = false,
    this.transcodingUrl,
    this.transcodingSubProtocol,
    this.container,
    this.bitrate,
  });

  final String id;
  final bool supportsDirectPlay;
  final bool supportsDirectStream;
  final bool supportsTranscoding;

  /// 服务器签发的转码 URL（相对根路径）；只在需要转码时给。
  final String? transcodingUrl;
  final String? transcodingSubProtocol;
  final String? container;
  final int? bitrate;
}

/// 一次播放的会话身份：Progress / Stopped / ActiveEncodings 清理都按它关联。
class JellyfinPlaybackSession {
  const JellyfinPlaybackSession({
    required this.itemId,
    required this.mediaSourceId,
    required this.playSessionId,
    required this.playMethod,
  });

  final String itemId;
  final String mediaSourceId;
  final String playSessionId;

  /// `DirectPlay` / `DirectStream` / `Transcode`（服务器的 PlayMethod 枚举名）。
  final String playMethod;

  bool get isTranscoding => playMethod == 'Transcode';
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
    this.deviceId = kLegacyDeviceId,
    http.Client? client,
  }) : _client = client ?? createAppHttpIoClient();

  /// 归一化后的服务器根 URL（含 scheme、无尾斜杠）。
  final String serverUrl;

  /// 服务器侧的设备身份（认证头 `DeviceId` / 会话 / 转码任务都按它归属）。
  ///
  /// 此前所有安装共用常量 [kLegacyDeviceId]：Emby / Jellyfin 按 DeviceId 归并
  /// 会话，两台设备（或退出再进的同一台）在服务器眼里是同一个「设备」互相顶掉，
  /// 转码任务也按它清理。新登录用本机 `SyncRepository.getOrCreateDeviceId`；令牌
  /// 与 DeviceId 绑定，所以它随 [JellyfinServerConfig] 一起持久化，旧配置继续用
  /// 旧常量、不逼用户重登。
  final String deviceId;

  /// 引入 per-install DeviceId 之前所有安装共用的常量；旧配置的兼容值。
  static const String kLegacyDeviceId = 'hibiki-app';

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
  ///
  /// BUG-1891：在几十万条目的服务器上它同时也是**静默截断**点，所以枚举结果现在
  /// 带 [JellyfinRecursiveResult.truncated]，调用方必须把这件事说出来。
  static const int kMaxRecursiveItems = 20000;

  /// 递归枚举**相邻两页之间**的最小间隔（BUG-1891）。
  ///
  /// 旧写法页与页之间零间隔：40 次重查询在几百毫秒内连发，正是 Emby / Jellyfin
  /// 滥用检测（以及公共服的风控）眼里的爬虫特征。150ms 对小库无感（3 页 = 300ms），
  /// 对大库则把突发压成稳定低速流。只插在页**之间**，第一页不等。
  static const Duration kPageInterval = Duration(milliseconds: 150);

  /// 层级回退（BUG-2567）一次枚举允许发出的请求数上限。
  ///
  /// 服务器忽略 `Recursive` 时拿不到「一次分页扫全库」这条便宜路径，成本回到
  /// **每部剧一发** `/Shows/{id}/Episodes`。剧多的库（实测公共服单库 4131 部剧）
  /// 照直走就是几千发连续请求 = 几十分钟 + 妥妥的爬虫特征，所以必须有硬预算。
  ///
  /// 400 的取法：够覆盖一个正常自建库（几百部剧），按 [kPageInterval] 铺开约 60s
  /// 节流成本；超出即带 [JellyfinRecursiveResult.truncated] 收工，由用户去设置里
  /// 点名要枚举的媒体库把范围收窄（那才是超大服务器的正解，见 BUG-1891）。
  static const int kMaxHierarchyRequests = 400;

  final http.Client _client;

  /// 归一化用户输入的服务器地址：折全角、补 scheme（缺省 http，局域网常态）、去尾斜杠。
  ///
  /// 全角必须在这里折：这个函数不走 `Uri`，纯字符串拼接，全角标点会**原样**进到
  /// 请求里（`http://192．168．1．10:8096`），失败时报成一个与真实原因无关的网络错误。
  /// 而 Jellyfin 地址是典型的局域网 IP，冒号加三个点，中文输入法下全中（BUG-1807）。
  static String normalizeServerUrl(String raw) {
    String url = normalizeUrlInput(raw);
    if (url.isEmpty) return url;
    // scheme 不分大小写（手机输入法 / 粘贴常给 `HTTP://`）：此前大小写敏感，
    // `HTTP://nas:8096` 会被再套一层成 `http://HTTP://nas:8096`，连接必失败。
    final RegExpMatch? scheme =
        RegExp(r'^(https?)://', caseSensitive: false).firstMatch(url);
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

  /// 连接探测（GET /System/Info/Public，无需认证）。登录前先走它：把「服务器根本
  /// 连不上 / 地址不对」与「账号密码错」分开——此前唯一的探测就是登录 POST 本身，
  /// 手机上失败只剩一个 2 秒的原生 toast，用户只能报「直接连不上」。
  /// 返回服务器自报名（`ServerName`），非 2xx 抛 [JellyfinApiException]，非 JSON
  /// 抛 [FormatException]（地址指向的不是媒体服务器 / 反代回了网页）。
  Future<String?> publicSystemInfo() async {
    final Map<String, Object?> json = await _getJson('/System/Info/Public');
    return json['ServerName'] as String?;
  }

  /// [error] 是否是「主机名解析失败」（`SocketException` 的 host lookup 失败 /
  /// getaddrinfo 错误码）。Android / iOS 不解析 `.local`（mDNS）与 Windows 计算机名
  /// （NetBIOS / LLMNR），而桌面能——用户在桌面填的主机名到手机上就是「直接连不上」，
  /// 要给「改用 IP」的提示。纯函数，离线可测。
  static bool isHostLookupFailure(Object error) {
    if (error is SocketException) {
      final String message = error.message.toLowerCase();
      if (message.contains('host lookup') || message.contains('lookup')) {
        return true;
      }
      final int? code = error.osError?.errorCode;
      // EAI_NONAME / WSAHOST_NOT_FOUND / EAI_AGAIN / EAI_NODATA。
      return code == 7 || code == 11001 || code == 8 || code == -2 || code == -3;
    }
    final String text = error.toString().toLowerCase();
    return text.contains('failed host lookup') ||
        text.contains('nodename nor servname');
  }

  /// MediaBrowser 认证头（Jellyfin/Emby 通用；认证前无 Token 字段）。
  ///
  /// 同一份头并发 `Authorization` 与 `X-Emby-Authorization` 两个名字：
  /// Jellyfin 10.11+ 只认 `Authorization`，Emby 与飞牛影视（fnOS 影视）等
  /// Jellyfin 兼容层只认 `X-Emby-Authorization`——缺它直接 400
  /// "X-Emby-Authorization is missing"（BUG-2254）。两家对未知头都宽容，
  /// 双发是在不引入服务器类型探测的前提下唯一同时覆盖两族的写法。
  static String authHeaderFor([
    String? accessToken,
    String deviceId = kLegacyDeviceId,
  ]) =>
      'MediaBrowser Client="Hibiki", Device="Hibiki", '
      'DeviceId="$deviceId", Version="1.0"'
      '${accessToken == null ? '' : ', Token="$accessToken"'}';

  Map<String, String> get _headers => <String, String>{
        'Authorization': authHeaderFor(accessToken, deviceId),
        'X-Emby-Authorization': authHeaderFor(accessToken, deviceId),
        'Content-Type': 'application/json',
      };

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$serverUrl$path').replace(queryParameters: query);

  /// GET + JSON 解码，不管顶层形状（`/Items/Latest` 回裸数组，其余回对象）。
  /// 非 JSON 响应体抛 [FormatException]——飞牛对不认识的路由回 SPA index.html
  /// 且状态 200（BUG-2254 备注④），这是那种情况唯一能被察觉的信号。
  Future<Object?> _getDecoded(
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
      return jsonDecode(utf8.decode(res.bodyBytes));
    } on http.ClientException catch (e) {
      // 凭据脱敏必须在异常构造侧（见 credential_redaction.dart 文件头）：
      // ClientException.toString() 把带 api_key 的整条 URL 塞进文本，而
      // ErrorLogService 存的就是 error.toString()，无脱敏落盘并可一键上传。
      throw Exception(redactCredentialsInText(e.toString()));
    }
  }

  Future<Map<String, Object?>> _getJson(
    String path, [
    Map<String, String>? query,
  ]) async {
    final Object? decoded = await _getDecoded(path, query);
    return decoded is Map<String, dynamic>
        ? decoded.cast<String, Object?>()
        : <String, Object?>{};
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

  /// `/Users/{uid}/Items` 的唯一请求构造点：浏览子级 / 递归枚举 / 搜索 / 剧集树
  /// 回退全走这里，查询参数的纪律只在一处维护：
  /// - [includeItemType] **单值**（BUG-2254：飞牛对逗号多值静默返 0 条）；
  /// - [fields] 缺省 `ProductionYear`，**不带 MediaSources**（BUG-1891）；
  /// - [sortBy] 单值（同 BUG-2254 的谨慎：`IsFolder,SortName` 这种多值在飞牛上
  ///   没验过，浏览排序不值得赌）。
  Future<JellyfinItemsPage> items({
    required String userId,
    String? parentId,
    bool recursive = false,
    String? includeItemType,
    String? searchTerm,
    int startIndex = 0,
    int limit = 200,
    String fields = 'ProductionYear',
    String sortBy = 'SortName',
    String sortOrder = 'Ascending',
  }) async {
    assert(!(includeItemType?.contains(',') ?? false),
        'IncludeItemTypes 必须单值（BUG-2254）');
    final Map<String, Object?> json =
        await _getJson('/Users/$userId/Items', <String, String>{
      if (parentId != null) 'ParentId': parentId,
      if (recursive) 'Recursive': 'true',
      if (includeItemType != null) 'IncludeItemTypes': includeItemType,
      if (searchTerm != null) 'SearchTerm': searchTerm,
      'StartIndex': '$startIndex',
      'Limit': '$limit',
      'Fields': fields,
      'SortBy': sortBy,
      'SortOrder': sortOrder,
    });
    return parseItemsPage(json);
  }

  /// 列 [parentId] 的直接子级（GET /Users/{uid}/Items，非递归，浏览用）。
  ///
  /// 不传 IncludeItemTypes：浏览要的是「这一层有什么」，剧 / 季 / 集 / 电影 /
  /// 文件夹都要；非视频域类型由消费端
  /// （[JellyfinVideoClient.mediaServerTypeOf]）滤掉，而不是在这里拼逗号多值
  /// （BUG-2254）。`ChildCount` 要显式要（Fields 门控），剧的集数 / 文件夹条目数
  /// 靠它。
  Future<JellyfinItemsPage> children({
    required String userId,
    String? parentId,
    int startIndex = 0,
    int limit = 200,
    String sortBy = 'SortName',
    String sortOrder = 'Ascending',
  }) =>
      items(
        userId: userId,
        parentId: parentId,
        startIndex: startIndex,
        limit: limit,
        fields: 'ChildCount,RecursiveItemCount,ProductionYear',
        sortBy: sortBy,
        sortOrder: sortOrder,
      );

  /// 一部剧的季清单（GET /Shows/{seriesId}/Seasons）。季是个位数，不分页；
  /// `ChildCount` 给每季集数。
  Future<JellyfinItemsPage> seasons({
    required String userId,
    required String seriesId,
  }) async {
    final Map<String, Object?> json =
        await _getJson('/Shows/$seriesId/Seasons', <String, String>{
      'UserId': userId,
      'Fields': 'ChildCount',
    });
    return parseItemsPage(json);
  }

  /// 一部剧（或其中一季）的集清单（GET /Shows/{seriesId}/Episodes），服务器
  /// 缺省按季集号升序；[seasonId] null = 整部剧。
  Future<JellyfinItemsPage> episodes({
    required String userId,
    required String seriesId,
    String? seasonId,
    int startIndex = 0,
    int limit = 100,
  }) async {
    final Map<String, Object?> json =
        await _getJson('/Shows/$seriesId/Episodes', <String, String>{
      'UserId': userId,
      if (seasonId != null) 'SeasonId': seasonId,
      'StartIndex': '$startIndex',
      'Limit': '$limit',
      'Fields': 'ProductionYear',
    });
    return parseItemsPage(json);
  }

  /// 「继续观看」（GET /Users/{uid}/Items/Resume）：服务器端有断点的视频叶子。
  Future<JellyfinItemsPage> resume({
    required String userId,
    int limit = 20,
  }) async {
    final Map<String, Object?> json =
        await _getJson('/Users/$userId/Items/Resume', <String, String>{
      'Limit': '$limit',
      'MediaTypes': 'Video',
    });
    return parseItemsPage(json);
  }

  /// 「接下来看」（GET /Shows/NextUp）：每部在看的剧的下一集。
  Future<JellyfinItemsPage> nextUp({
    required String userId,
    int limit = 20,
  }) async {
    final Map<String, Object?> json =
        await _getJson('/Shows/NextUp', <String, String>{
      'UserId': userId,
      'Limit': '$limit',
    });
    return parseItemsPage(json);
  }

  /// 「最近添加」（GET /Users/{uid}/Items/Latest）。
  ///
  /// 这条端点回的是**裸数组**而不是 `{Items, TotalRecordCount}`，解析单独走
  /// [parseItemList]；同时容忍对象形状（兼容层不一定照抄）。剧集库的新集会被
  /// 服务器折成 Series 容器返回（`GroupItems` 缺省 true）。
  Future<List<JellyfinItem>> latest({
    required String userId,
    String? parentId,
    int limit = 20,
  }) async {
    final Object? decoded =
        await _getDecoded('/Users/$userId/Items/Latest', <String, String>{
      if (parentId != null) 'ParentId': parentId,
      'Limit': '$limit',
    });
    if (decoded is List) return parseItemList(decoded);
    if (decoded is Map) {
      return parseItemList((decoded['Items'] as List?) ?? const <Object?>[]);
    }
    return const <JellyfinItem>[];
  }

  /// 递归列出 [parentId]（缺省全库）下所有可播视频叶子（电影 + 单集）。
  ///
  /// **类型过滤按单值拆成 Movie / Episode 两轮**（BUG-2254）：飞牛影视的
  /// `/Items` 不认 `IncludeItemTypes` 逗号多值——`Movie,Episode` 静默返回
  /// 0 条（单值 Movie / Episode 均正常），整台服务器在库页表现为「空库」。
  /// 原版 Jellyfin / Emby 对单值与多值语义一致，拆开发不留行为差异。两轮
  /// 各自独立分页，Movie 轮在前（集合名排序下 Episode 轮的分页窗口互不干扰）。
  ///
  /// **服务器完全不认 `Recursive` 时自动改走层级回退**（BUG-2567）：`UHD Media
  /// Server` 一类 Emby 兼容实现对 `/Users/{uid}/Items` 只返回 `ParentId` 的**直接
  /// 子级**，`Recursive` 与 `IncludeItemTypes` 一并忽略——剧集库于是只吐 `Series`
  /// 文件夹，全部通不过消费端的 `isPlayableVideo`，整库在影片页表现为空。首页即由
  /// [ignoresRecursiveEnumeration] 判定并转入 [_hierarchicalVideoItems] 自己走下去。
  /// 原版 Jellyfin / Emby 走不到这条分支，行为零变化。
  ///
  /// **真分页**：单发一次 + 硬上限的旧写法在 100 部番 x 12 集就到顶，第 2001 条
  /// 起永久不可见且无任何提示；TotalRecordCount 解出来却被丢弃、StartIndex 根本
  /// 没传。这里按 [pageSize] 逐页取到 StartIndex >= totalCount（或某页返空）为止，
  /// 熔断见 [kMaxRecursiveItems]——上限是**跨轮总额**（`all.length`），不是每轮
  /// 各 2 万：拆轮前上限就是「这次枚举最多拿 2 万条」，拆轮不该把它悄悄翻倍成
  /// 4 万条内存 + 80 次重查询。代价是 >2 万部电影的服务器上 Episode 轮一条都
  /// 拿不到——但那种库本来就该在设置里点名媒体库，而且 truncated 会报出来。
  ///
  /// **Fields 刻意不带 MediaSources**（BUG-1891）。它曾是为了让清单卡直接拿到
  /// 「有无外挂字幕 / 文件大小」，但那是这条请求真正昂贵的部分：服务器要为**每一
  /// 条**条目展开 MediaSource（Emby 侧还含外挂字幕文件的磁盘探测）。几十万条目的
  /// 服务器上，一进视频页就是几十上百个这种重查询连发 —— 用户看到的「一添加就开始
  /// 刮削、卡死、封号」正是它，与元数据刮削毫无关系。
  ///
  /// 代价与补偿：清单里的 `hasSubtitle` 退回服务器的粗粒度 `HasSubtitles`
  /// （把 PGS/DVDSub 图形轨也算 true，见 [JellyfinItem.hasTextSubtitle]），
  /// `sizeBytes` / `subtitleFileName` 为空。这三样在**单条目消费点**按需补齐：
  /// [JellyfinVideoClient.remoteVideoDetail]（[RemoteVideoDetailFetch] 能力）
  /// 打一次 `/Items/{id}` 拿全量 MediaSources，下载入库与信息弹窗都走它——功能
  /// 一件没砍，只是从「列表阶段 N 次重查询」改成「用到时 1 次」。
  Future<JellyfinRecursiveResult> recursiveVideoItems({
    required String userId,
    String? parentId,
    int pageSize = 500,
    Duration pageInterval = kPageInterval,
  }) async {
    final List<JellyfinItem> all = <JellyfinItem>[];
    int total = 0;
    bool truncated = false;
    // 飞牛不认逗号多值（BUG-2254），按单值各跑一轮完整分页；消费端按 id 去重
    // （listRemoteVideos 的 seen 集合），同一叶子在两轮都命中也不会重复。
    for (final String type in const <String>['Movie', 'Episode']) {
      int start = 0;
      while (true) {
        // 跨轮总额：Movie 轮已经把额度吃满时，Episode 轮一发都不打就判 truncated。
        // 至多超出最后一页的余量（不回切），调用方看 truncated 而不是数条数。
        if (all.length >= kMaxRecursiveItems) {
          truncated = true;
          break;
        }
        if (start > 0 && pageInterval > Duration.zero) {
          await Future<void>.delayed(pageInterval);
        }
        final JellyfinItemsPage page = await items(
          userId: userId,
          parentId: parentId,
          recursive: true,
          includeItemType: type,
          startIndex: start,
          limit: pageSize,
        );
        // BUG-2567：服务器把 Recursive/IncludeItemTypes 当没看见 → 这一页是库的
        // **直接子级**（一堆 Series/文件夹），叶子一个没有。继续分页只会把同一批
        // 容器拉完，而它们全部通不过 listRemoteVideos 的 isPlayableVideo 过滤，
        // 用户看到的就是「库里明明有片、影片页一片空白」。改走层级回退。
        if (start == 0 && ignoresRecursiveEnumeration(page)) {
          return _hierarchicalVideoItems(
            userId: userId,
            parentId: parentId,
            pageSize: pageSize,
            pageInterval: pageInterval,
          );
        }
        all.addAll(page.items);
        total += page.totalCount;
        if (page.items.isEmpty) break;
        start += page.items.length;
        if (start >= page.totalCount) break;
      }
      if (truncated) break;
    }
    return JellyfinRecursiveResult(
      items: all,
      truncated: truncated,
      totalCount: total < all.length ? all.length : total,
    );
  }

  /// 这一页是否证明「服务器忽略了 `Recursive` / `IncludeItemTypes`」（BUG-2567）。
  ///
  /// 判据：非空、**一个可播叶子都没有**、且至少有一个可下钻容器。
  /// 三个条件缺一不可——
  ///  * 非空：空页是「这个库真没东西」，不是能力缺失，回退只会白发请求；
  ///  * 无叶子：只要混进一条 Movie/Episode，就说明类型过滤至少部分生效，按原路
  ///    分页仍能拿到全部叶子，不必付层级回退那份贵得多的成本；
  ///  * 有容器：排除「服务器返回了一批我们不认识的类型」这种真·空结果。
  ///
  /// 实测触发者：`UHD Media Server 4.9.3.0`（Emby 兼容实现）——`/Users/{uid}/Items`
  /// 对 `ParentId` **只返回直接子级**，`Recursive=true` 与 `IncludeItemTypes` 一并
  /// 被忽略（向电影库要 Episode 返回 Movie，向剧集库要 Episode 返回 Series）。
  /// 同族的飞牛影视见 BUG-2254。原版 Jellyfin / Emby 不会命中本判据。
  static bool ignoresRecursiveEnumeration(JellyfinItemsPage page) =>
      page.items.isNotEmpty &&
      !page.items.any((JellyfinItem i) => i.isPlayableVideo) &&
      page.items.any((JellyfinItem i) => i.isVideoContainer);

  /// 一部剧的全部分集（GET /Shows/{seriesId}/Episodes）。
  ///
  /// 层级回退（BUG-2567）的主力：它**跨季一次返回**，所以一部剧只要一发请求，
  /// 不必先列季再逐季列集。Jellyfin / Emby / Emby 兼容实现都提供该端点，且实测
  /// 在「忽略 Recursive」的服务器上仍然正确分页（StartIndex/Limit 均生效）。
  Future<JellyfinItemsPage> seriesEpisodes({
    required String userId,
    required String seriesId,
    int startIndex = 0,
    int limit = 500,
  }) async {
    final Map<String, Object?> json =
        await _getJson('/Shows/$seriesId/Episodes', <String, String>{
      'UserId': userId,
      'StartIndex': '$startIndex',
      'Limit': '$limit',
      'Fields': 'ProductionYear',
    });
    return parseItemsPage(json);
  }

  /// 层级回退枚举（BUG-2567）：服务器不肯递归，就由客户端自己走下去。
  ///
  /// 广度优先，队列里只放容器：`Series` 一发 [seriesEpisodes] 取全部分集；其余
  /// 容器（季 / 合集 / 文件夹）用 [children] 列直接子级再入队。遇到的叶子随手收下。
  ///
  /// 三道闸，缺一不可：
  ///  * [kMaxHierarchyRequests]：请求数硬预算，防止几千部剧的库把一次「进影片页」
  ///    变成几十分钟的连发；
  ///  * [kMaxRecursiveItems]：条目数上限，与原路径同口径；
  ///  * `visited`：容器 id 去重。文件夹型媒体库出现环（或同一部剧挂在两个合集下）
  ///    时，没有它就是无限循环 + 无限内存。
  ///
  /// 任一闸触发都置 [JellyfinRecursiveResult.truncated]，由调用方把「拿到的不是
  /// 全部」这件事说出来，而不是静默给一半。
  Future<JellyfinRecursiveResult> _hierarchicalVideoItems({
    required String userId,
    String? parentId,
    required int pageSize,
    required Duration pageInterval,
  }) async {
    final List<JellyfinItem> leaves = <JellyfinItem>[];
    final List<JellyfinItem> queue = <JellyfinItem>[];
    final Set<String> visited = <String>{};
    int requests = 0;
    // 两个标志**不是**一回事，合并过一次就出过 bug：`truncated` 是「结果不完整，
    // 得报出去」，可以由单个容器失败触发，但那时其余容器仍必须照跑；
    // `budgetExhausted` 才是「别再发请求了」的停机条件。用一个变量兼任两职的话，
    // 第一部剧一失败就把整轮遍历掐断，剩下的剧全部消失。
    bool truncated = false;
    bool budgetExhausted = false;

    // 预算记账与节流的唯一出口：每一发请求都必须经过它，漏一处预算就形同虚设。
    Future<bool> spend() async {
      if (requests >= kMaxHierarchyRequests ||
          leaves.length >= kMaxRecursiveItems) {
        budgetExhausted = true;
        truncated = true;
        return false;
      }
      if (requests > 0 && pageInterval > Duration.zero) {
        await Future<void>.delayed(pageInterval);
      }
      requests++;
      return true;
    }

    // 收下一批条目：叶子进结果，容器进队列（已访问过的不重复入队）。
    void absorb(Iterable<JellyfinItem> items) {
      for (final JellyfinItem item in items) {
        if (item.isPlayableVideo) {
          leaves.add(item);
        } else if (item.isVideoContainer && item.id.isNotEmpty) {
          if (visited.add(item.id)) queue.add(item);
        }
      }
    }

    // 某个容器的直接子级（分页取全）。
    Future<void> drainChildren(String? id) async {
      int start = 0;
      while (true) {
        if (!await spend()) return;
        final JellyfinItemsPage page = await children(
          userId: userId,
          parentId: id,
          startIndex: start,
          limit: pageSize,
        );
        absorb(page.items);
        if (page.items.isEmpty) return;
        start += page.items.length;
        if (start >= page.totalCount) return;
      }
    }

    // 一部剧的全部分集（同样分页取全；跨季一次拿完，不必先列季）。
    Future<void> drainSeries(String seriesId) async {
      int start = 0;
      while (true) {
        if (!await spend()) return;
        final JellyfinItemsPage page = await seriesEpisodes(
          userId: userId,
          seriesId: seriesId,
          startIndex: start,
          limit: pageSize,
        );
        absorb(page.items);
        if (page.items.isEmpty) return;
        start += page.items.length;
        if (start >= page.totalCount) return;
      }
    }

    // 库根失败 = 这一轮真的什么都没有，照旧抛给调用方（与原路径同语义）。
    await drainChildren(parentId);

    // 单个容器失败**不是**整库失败。这条回退动辄几百发请求（原路径只有几发），
    // 撞上一次瞬断的概率高得多，而 listRemoteVideos 的异常一路冒到
    // `_loadRemoteVideos` 就是 `failed: true` = **整个远端库不渲染**——正是本 bug
    // 要修的那个形状。所以这里逐容器兜住：记一笔、标 truncated、接着走下一个。
    while (queue.isNotEmpty && !budgetExhausted) {
      final JellyfinItem container = queue.removeAt(0);
      try {
        if (container.type != 'Series') {
          // 季 / 合集 / 文件夹：列直接子级，子级里的剧再按剧走。
          await drainChildren(container.id);
          continue;
        }
        // 剧：一发拿全部分集。服务器不认这个端点（老实现 / 兼容层缺项）时回落列
        // 直接子级——不能让一次 404 把这部剧整个吞掉。
        try {
          await drainSeries(container.id);
        } catch (e) {
          debugPrint('[jellyfin] /Shows/${container.id}/Episodes failed, '
              'falling back to children(): $e');
          await drainChildren(container.id);
        }
      } catch (e) {
        truncated = true;
        debugPrint('[jellyfin] container ${container.id} '
            '(${container.type}) failed, skipping: $e');
      }
    }

    if (budgetExhausted) {
      debugPrint('[jellyfin] hierarchical enumeration hit its request budget '
          '($requests requests / ${leaves.length} items); pick specific '
          'libraries in settings to narrow it.');
    } else if (truncated) {
      // 预算没用完却不完整 = 有容器被跳过。两种原因写成两句，别让排查的人
      // 对着「stopped early」去查根本没触发的预算闸。
      debugPrint('[jellyfin] hierarchical enumeration finished with some '
          'containers skipped ($requests requests / ${leaves.length} items).');
    }
    return JellyfinRecursiveResult(
      items: leaves,
      truncated: truncated,
      totalCount: leaves.length,
    );
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

  /// 播放协商（POST /Items/{id}/PlaybackInfo）：把本客户端的 [buildDeviceProfile]
  /// 与码率 / 宽度上限交给服务器，由它决定这条媒体源是直播放（`SupportsDirectPlay`
  /// / `SupportsDirectStream`）还是转码（`TranscodingUrl`，HLS），并签发本次播放的
  /// `PlaySessionId`。Jellyfin web / Emby 官方 / Infuse 起播都先走这一步；此前本仓
  /// 手拼 `static=true` 直出 URL，服务器侧的码率限制、用户策略全被绕过，也没有会话
  /// 身份可供 Progress / Stopped 关联。
  ///
  /// 非 2xx 抛 [JellyfinApiException]，非 JSON 抛 [FormatException]——飞牛影视等兼容
  /// 层可能没有这个端点，调用方按此回落到直出 URL（见
  /// `JellyfinVideoClient._negotiatePlayback`）。
  Future<JellyfinPlaybackInfo> playbackInfo({
    required String userId,
    required String itemId,
    String? mediaSourceId,
    int startPositionMs = 0,
    int? maxStreamingBitrate,
    int? maxWidth,
  }) async {
    final http.Response res = await _client
        .post(
          _uri('/Items/$itemId/PlaybackInfo', <String, String>{
            'UserId': userId,
          }),
          headers: _headers,
          body: jsonEncode(buildPlaybackInfoRequest(
            userId: userId,
            mediaSourceId: mediaSourceId,
            startPositionMs: startPositionMs,
            maxStreamingBitrate: maxStreamingBitrate,
            maxWidth: maxWidth,
          )),
        )
        .timeout(kRequestTimeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw JellyfinApiException(res.statusCode, '/Items/$itemId/PlaybackInfo');
    }
    final Object? decoded = jsonDecode(utf8.decode(res.bodyBytes));
    return parsePlaybackInfo(decoded is Map<String, dynamic>
        ? decoded.cast<String, Object?>()
        : <String, Object?>{});
  }

  /// PlaybackInfo 请求体（纯函数，离线可测）。
  ///
  /// 直播放 / 直传 / 转码三个开关全开，让服务器按 profile 与上限裁决；
  /// `AllowVideoStreamCopy` / `AllowAudioStreamCopy` 让转码时能只 remux 不重编。
  static Map<String, Object?> buildPlaybackInfoRequest({
    required String userId,
    String? mediaSourceId,
    int startPositionMs = 0,
    int? maxStreamingBitrate,
    int? maxWidth,
  }) =>
      <String, Object?>{
        'UserId': userId,
        if (mediaSourceId != null) 'MediaSourceId': mediaSourceId,
        'StartTimeTicks': startPositionMs * kTicksPerMs,
        if (maxStreamingBitrate != null)
          'MaxStreamingBitrate': maxStreamingBitrate,
        'AutoOpenLiveStream': true,
        'EnableDirectPlay': true,
        'EnableDirectStream': true,
        'EnableTranscoding': true,
        'AllowVideoStreamCopy': true,
        'AllowAudioStreamCopy': true,
        'IsPlayback': true,
        'DeviceProfile': buildDeviceProfile(
          maxStreamingBitrate: maxStreamingBitrate,
          maxWidth: maxWidth,
        ),
      };

  /// 本客户端的 DeviceProfile（纯函数）。播放内核是 libmpv，容器 / 编解码基本无所
  /// 不能，所以直播放 profile 不限容器与编码（`Container` 留空 = 全部，Jellyfin 与
  /// Emby 的 ContainerHelper 都把空当通配）；转码只在服务器判定必须时发生
  /// （码率超上限 / 用户策略），走 HLS + h264 + aac。字幕：文本轨外挂取（本仓自己
  /// 的字幕 overlay 渲染），图形轨烧进转码流。
  static Map<String, Object?> buildDeviceProfile({
    int? maxStreamingBitrate,
    int? maxWidth,
  }) =>
      <String, Object?>{
        'Name': 'Hibiki',
        'MaxStreamingBitrate': maxStreamingBitrate ?? kUnlimitedBitrate,
        'MaxStaticBitrate': kUnlimitedBitrate,
        'MusicStreamingTranscodingBitrate': 320000,
        'DirectPlayProfiles': <Object?>[
          <String, Object?>{'Type': 'Video'},
          <String, Object?>{'Type': 'Audio'},
        ],
        'TranscodingProfiles': <Object?>[
          <String, Object?>{
            'Type': 'Video',
            'Container': 'ts',
            'Protocol': 'hls',
            'VideoCodec': 'h264',
            'AudioCodec': 'aac,mp3,ac3',
            'Context': 'Streaming',
            'MaxAudioChannels': '6',
            'MinSegments': 1,
            'BreakOnNonKeyFrames': true,
          },
          <String, Object?>{
            'Type': 'Audio',
            'Container': 'mp3',
            'AudioCodec': 'mp3',
            'Protocol': 'http',
            'Context': 'Streaming',
          },
        ],
        'CodecProfiles': <Object?>[
          if (maxWidth != null)
            <String, Object?>{
              'Type': 'Video',
              'Conditions': <Object?>[
                <String, Object?>{
                  'Condition': 'LessThanEqual',
                  'Property': 'Width',
                  'Value': '$maxWidth',
                  'IsRequired': false,
                },
              ],
            },
        ],
        'SubtitleProfiles': <Object?>[
          for (final String format in const <String>[
            'srt',
            'subrip',
            'ass',
            'ssa',
            'vtt',
            'webvtt',
          ])
            <String, Object?>{'Format': format, 'Method': 'External'},
          for (final String format in const <String>['pgssub', 'pgs', 'dvdsub'])
            <String, Object?>{'Format': format, 'Method': 'Encode'},
        ],
      };

  /// 「不限」码率的 profile 值（120 Mbps，与 Jellyfin web 的顶档一致）。
  static const int kUnlimitedBitrate = 120000000;

  static JellyfinPlaybackInfo parsePlaybackInfo(Map<String, Object?> json) {
    final List<JellyfinPlaybackMediaSource> sources =
        <JellyfinPlaybackMediaSource>[];
    final List<Object?> rawSources =
        (json['MediaSources'] as List?) ?? const <Object?>[];
    for (final Object? raw in rawSources) {
      if (raw is! Map) continue;
      final Map<String, Object?> src = raw.cast<String, Object?>();
      final String? id = src['Id'] as String?;
      if (id == null || id.isEmpty) continue;
      sources.add(JellyfinPlaybackMediaSource(
        id: id,
        supportsDirectPlay: (src['SupportsDirectPlay'] as bool?) ?? false,
        supportsDirectStream: (src['SupportsDirectStream'] as bool?) ?? false,
        supportsTranscoding: (src['SupportsTranscoding'] as bool?) ?? false,
        transcodingUrl: src['TranscodingUrl'] as String?,
        transcodingSubProtocol: src['TranscodingSubProtocol'] as String?,
        container: src['Container'] as String?,
        bitrate: (src['Bitrate'] as num?)?.toInt(),
      ));
    }
    return JellyfinPlaybackInfo(
      playSessionId: json['PlaySessionId'] as String?,
      errorCode: json['ErrorCode'] as String?,
      mediaSources: sources,
    );
  }

  /// 起播上报（POST /Sessions/Playing）：服务器由此建立会话，仪表盘「正在播放」、
  /// 后续 Progress / Stopped 的关联、转码任务的归属都靠它。
  Future<void> reportStarted({
    required JellyfinPlaybackSession session,
    required int positionMs,
  }) =>
      _postSession('/Sessions/Playing', <String, Object?>{
        ..._sessionBody(session.itemId, session),
        'PositionTicks': positionMs * kTicksPerMs,
        'IsPaused': false,
        'IsMuted': false,
        'CanSeek': true,
      });

  /// 播放中的周期进度上报（POST /Sessions/Playing/Progress）。
  ///
  /// 无会话生命周期也会持久化 resume 位置，是 scrobbler 类客户端的通用做法；
  /// 与 [reportStopped] 的区别在**语义**：Progress 是「还在播」，Stopped 是
  /// 「不播了」。周期心跳必须走这条，节流档见
  /// [JellyfinVideoClient.kPositionReportIntervalMs]。暂停 / 继续事件也走这条
  /// （`EventName` = pause / unpause，`IsPaused` 如实），服务器才知道用户停在那儿。
  Future<void> reportProgress({
    required String itemId,
    required int positionMs,
    JellyfinPlaybackSession? session,
    bool isPaused = false,
    String? eventName,
  }) =>
      _postSession('/Sessions/Playing/Progress', <String, Object?>{
        ..._sessionBody(itemId, session),
        'PositionTicks': positionMs * kTicksPerMs,
        'IsPaused': isPaused,
        if (eventName != null) 'EventName': eventName,
      });

  /// 转码任务清理（DELETE /Videos/ActiveEncodings）：停止播放后服务器不会立刻停
  /// ffmpeg，要客户端按 `(DeviceId, PlaySessionId)` 显式停，否则转码继续跑到服务器
  /// 自己的超时（几分钟）——下一次起播就与它抢 CPU，「卡 / 有时开不了」的来源之一。
  Future<void> stopActiveEncodings(String playSessionId) async {
    final http.Response res = await _client
        .delete(
          _uri('/Videos/ActiveEncodings', <String, String>{
            'DeviceId': deviceId,
            'PlaySessionId': playSessionId,
          }),
          headers: _headers,
        )
        .timeout(kRequestTimeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw JellyfinApiException(res.statusCode, '/Videos/ActiveEncodings');
    }
  }

  static Map<String, Object?> _sessionBody(
    String itemId,
    JellyfinPlaybackSession? session,
  ) =>
      <String, Object?>{
        'ItemId': itemId,
        if (session != null) ...<String, Object?>{
          'MediaSourceId': session.mediaSourceId,
          'PlaySessionId': session.playSessionId,
          'PlayMethod': session.playMethod,
        },
      };

  Future<void> _postSession(String path, Map<String, Object?> body) async {
    final http.Response res = await _client
        .post(_uri(path), headers: _headers, body: jsonEncode(body))
        .timeout(kRequestTimeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw JellyfinApiException(res.statusCode, path);
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
    JellyfinPlaybackSession? session,
  }) =>
      _postSession('/Sessions/Playing/Stopped', <String, Object?>{
        ..._sessionBody(itemId, session),
        'PositionTicks': positionMs * kTicksPerMs,
      });

  /// 直连播放流 URL（static=true 原文件直出，内嵌字幕/音轨全保留；`api_key`
  /// 查询参数自带认证——[RemoteVideoStreamUrls] 没有 HTTP 头通道）。
  ///
  /// `MediaSourceId` 必带（BUG-2254 ③）：飞牛影视对缺它的 `/Videos/{id}/stream`
  /// 一律 400，且**不能拿条目 id 充数**——MediaSource id 是与条目 id 互相独立的
  /// GUID（MediaSources[0].Id）。原版 Jellyfin / Emby 缺省时按条目 id 解析，显式
  /// 带上对三家都正确。播放器（mpv/media_kit）发请求没有头通道，令牌仍走
  /// `api_key`（飞牛在流/字幕端点对该参数实测有效——唯一带参传令牌的例外）。
  ///
  /// [playSessionId]（PlaybackInfo 签发）给了就连同 `DeviceId` 一起带上：服务器据此
  /// 把这条流归到会话，与 Jellyfin web 的直播放 URL 同形。
  String streamUrl(
    String itemId, {
    String? mediaSourceId,
    String? playSessionId,
  }) =>
      '$serverUrl/Videos/$itemId/stream?static=true'
      '${mediaSourceId == null ? '' : '&MediaSourceId=$mediaSourceId'}'
      '${playSessionId == null ? '' : '&PlaySessionId=${Uri.encodeQueryComponent(playSessionId)}&DeviceId=${Uri.encodeQueryComponent(deviceId)}'}'
      '&api_key=${accessToken ?? ''}';

  /// 服务器签发的转码 URL（PlaybackInfo 的 `TranscodingUrl`，Jellyfin / Emby 都给
  /// 相对根路径的形式、自带 api_key / PlaySessionId / DeviceId 等全部参数）补成
  /// 绝对 URL。
  String transcodingStreamUrl(String transcodingUrl) {
    if (transcodingUrl.startsWith('http://') ||
        transcodingUrl.startsWith('https://')) {
      return transcodingUrl;
    }
    return transcodingUrl.startsWith('/')
        ? '$serverUrl$transcodingUrl'
        : '$serverUrl/$transcodingUrl';
  }

  /// 封面 URL（缺省 Primary 图；无图的条目由调用方按 hasPrimaryImage 过滤）。
  ///
  /// [maxWidth] 给了就让服务器侧缩放（`maxWidth` + `quality=90`，Jellyfin 与
  /// Emby 都认）：清单卡拿原图是移动端（尤其 iOS）解码内存爆掉的候选之一——
  /// 一张 4K 海报解出来 30+ MB，一屏几十张就没了。不给则原样出原图（旧行为，
  /// 只剩测试与显式要原图的地方用）。
  ///
  /// 飞牛影视**不支持**该端点（任何认证都 404，兼容层未提供图片服务；官方对
  /// VidHub 接入的文档亦明示「不支持显示媒体库封面」）——飞牛上无封面属服务端
  /// 能力缺失，非缺陷（BUG-2254 备注③）；原版 Jellyfin / Emby 正常。
  String imageUrl(
    String itemId, {
    int? maxWidth,
    String imageType = 'Primary',
  }) =>
      '$serverUrl/Items/$itemId/Images/$imageType?'
      '${maxWidth == null ? '' : 'maxWidth=$maxWidth&quality=90&'}'
      'api_key=${accessToken ?? ''}';

  /// 字幕流下载 URL（外挂或可提取文本内嵌轨都走这个端点）。
  ///
  /// 飞牛影视**不支持**该端点（任何认证都回 SPA index.html）——飞牛上外挂字幕
  /// 取不到属服务端能力缺失，非缺陷（BUG-2254 备注④）；mkv 内嵌文本轨经 mpv
  /// 直读不受影响。原版 Jellyfin / Emby 正常。
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
      // Emby 4.9 把服务器名放在 User.ServerName 下，顶层没有 ServerName（真机实测
      // v1.uhdnow.com：顶层只有 ServerId），Jellyfin 两处都给。
      serverName:
          (json['ServerName'] as String?) ?? (user['ServerName'] as String?),
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
            hasPrimaryImage:
                (raw['ImageTags'] as Map?)?.containsKey('Primary') ?? false,
          ),
    ];
  }

  static JellyfinItemsPage parseItemsPage(Map<String, Object?> json) {
    final List<Object?> items = (json['Items'] as List?) ?? const <Object?>[];
    return JellyfinItemsPage(
      items: parseItemList(items),
      totalCount: (json['TotalRecordCount'] as num?)?.toInt() ?? items.length,
    );
  }

  /// 条目数组 → DTO（`{Items:[…]}` 的 Items 与 `/Items/Latest` 的裸数组共用）。
  static List<JellyfinItem> parseItemList(List<Object?> items) =>
      <JellyfinItem>[
        for (final Object? raw in items)
          if (raw is Map) parseItem(raw.cast<String, Object?>()),
      ];

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
    final List<Object?> backdropTags =
        (json['BackdropImageTags'] as List?) ?? const <Object?>[];
    final List<Object?> genres = (json['Genres'] as List?) ?? const <Object?>[];

    return JellyfinItem(
      id: (json['Id'] as String?) ?? '',
      name: (json['Name'] as String?) ?? '',
      type: (json['Type'] as String?) ?? '',
      isFolder: (json['IsFolder'] as bool?) ?? false,
      originalTitle: json['OriginalTitle'] as String?,
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
      recursiveItemCount: (json['RecursiveItemCount'] as num?)?.toInt(),
      productionYear: (json['ProductionYear'] as num?)?.toInt(),
      seriesId: json['SeriesId'] as String?,
      seasonId: json['SeasonId'] as String?,
      played: (userData['Played'] as bool?) ?? false,
      unplayedChildCount: (userData['UnplayedItemCount'] as num?)?.toInt(),
      hasBackdrop: backdropTags.isNotEmpty,
      hasThumbImage: imageTags.containsKey('Thumb'),
      hasLogoImage: imageTags.containsKey('Logo'),
      overview: json['Overview'] as String?,
      communityRating: (json['CommunityRating'] as num?)?.toDouble(),
      genres: <String>[
        for (final Object? g in genres)
          if (g is String && g.isNotEmpty) g,
      ],
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
///
/// 同时 `implements MediaServerBrowser`：浏览页按父级分页地走服务器自己的树，
/// 剧的身份（SeriesId）原样保留。**不拆成独立适配类**的理由：本仓的能力判据是
/// `client is <能力接口>`（[RemoteVideoDetailFetch] / [RemoteVideoPlaybackStop]
/// 都是这么挂在本类上的），`JellyfinServerConfig.buildClient()` 交出的这一个
/// 实例就该同时是播放 client 与浏览器，页面不必知道要另造一个包装再把
/// `playbackClient` 指回来。
class JellyfinVideoClient
    implements
        RemoteVideoClient,
        RemoteCoverFetcher,
        RemoteVideoDetailFetch,
        RemoteVideoPlaybackStop,
        RemoteVideoPlaybackSession,
        RemoteVideoQualityLimit,
        RemoteVideoCollectionIsWork,
        MediaServerBrowser {
  JellyfinVideoClient({
    required this.api,
    required this.userId,
    this.libraryIds = const <String>[],
    this.serverName,
    String? identityServerUrl,
  }) : identityServerUrl = identityServerUrl ?? api.serverUrl;

  final JellyfinApi api;
  final String userId;

  /// 这台服务器在本机的身份锚（= [JellyfinServerConfig.serverUrl]，登录时的主
  /// 地址）。[api.serverUrl] 是请求实际走的**当前线路**，多线路之后两者可以不同；
  /// 缓存槽身份 / 封面缓存命名空间只认这个，切线路不换身份。缺省 = api 的地址
  /// （单线路 / 直接 new 的测试路径两者天然相同）。
  final String identityServerUrl;

  /// 画质档（成熟客户端的「画质」菜单）。码率取 Jellyfin web 同一阶梯的常用几档，
  /// 宽度上限让服务器转码时真的缩到那一档，而不是只降码率不降分辨率。
  static const List<MediaServerQualityPreset> kQualityPresets =
      <MediaServerQualityPreset>[
    MediaServerQualityPreset(
        label: '1080p · 20 Mbps', maxBitrate: 20000000, maxWidth: 1920),
    MediaServerQualityPreset(
        label: '1080p · 10 Mbps', maxBitrate: 10000000, maxWidth: 1920),
    MediaServerQualityPreset(
        label: '720p · 6 Mbps', maxBitrate: 6000000, maxWidth: 1280),
    MediaServerQualityPreset(
        label: '720p · 3 Mbps', maxBitrate: 3000000, maxWidth: 1280),
    MediaServerQualityPreset(
        label: '480p · 1.5 Mbps', maxBitrate: 1500000, maxWidth: 854),
  ];

  @override
  List<MediaServerQualityPreset> get qualityPresets => kQualityPresets;

  /// -1 = 自动（不给上限，服务器允许时直播放原文件）。播放页在起播前按偏好写入。
  @override
  int qualityPresetIndex = -1;

  MediaServerQualityPreset? get _activeQualityPreset =>
      qualityPresetIndex >= 0 && qualityPresetIndex < kQualityPresets.length
          ? kQualityPresets[qualityPresetIndex]
          : null;

  /// 按条目 id 记录的在途播放会话（FIFO：同一条目「退出 → 立刻重开」时，旧页的
  /// Stopped 可能晚于新页的 PlaybackInfo 到达，先进先出才不会拿新会话去报旧停止）。
  final Map<String, List<JellyfinPlaybackSession>> _sessions =
      <String, List<JellyfinPlaybackSession>>{};

  JellyfinPlaybackSession? _latestSession(String itemId) {
    final List<JellyfinPlaybackSession>? list = _sessions[itemId];
    return list == null || list.isEmpty ? null : list.last;
  }

  @visibleForTesting
  JellyfinPlaybackSession? debugActiveSession(String itemId) =>
      _latestSession(itemId);

  /// 要枚举的媒体库视图 id；空 = 全部视频域媒体库（见
  /// [JellyfinServerConfig.libraryIds] 与 [resolveEnumerationParents]）。
  final List<String> libraryIds;

  /// 服务器自报名（登录响应的 `ServerName`，经 [JellyfinServerConfig.serverName]
  /// 传入）；null / 空时 [displayName] 回落主机名。
  final String? serverName;

  /// 缓存槽身份的**唯一**构造点。登出失效等「手里没有 client 实例」的调用方也
  /// 走这里，别再各自拼字面量——拼歪一个字符就是「以为清了、其实没清」。
  static String sourceIdFor({
    required String serverUrl,
    required String userId,
  }) =>
      'jellyfin:$serverUrl|$userId';

  @override
  String get remoteLibrarySourceId =>
      sourceIdFor(serverUrl: identityServerUrl, userId: userId);

  @override
  Future<Uint8List> fetchRemoteCover(String coverUrl) =>
      api.fetchBytes(coverUrl);

  /// 磁盘封面缓存命名空间（BUG-1693 口径：配对身份级）：服务器 + 用户。
  /// 换令牌（重新登录同账号）不变——封面没变别白白重下；换服务器/账号必变。
  @override
  String get coverCacheNamespace =>
      'jellyfin-${sha1.convert(utf8.encode('$identityServerUrl|$userId'))}';

  /// 把一个条目适配成 [RemoteVideoInfo]（列表卡片消费）。
  ///
  /// [RemoteVideoInfo.hasSubtitle] 必须真实填：库页的下载入库路径用它做早返门
  /// （`if (!video.hasSubtitle) return ...`），吃默认 false 就等于「从 Jellyfin
  /// 下载的视频永远不下外挂字幕」，[getRemoteVideoSubtitle] 实现了也进不去。
  ///
  /// 与 [toRemoteVideoInfo] 共用 [_remoteVideoInfoFor]：两条路径只差「详情里
  /// 才有的 MediaSources 派生字段」（文件大小 / 字幕文件名），其余字段一份映射。
  RemoteVideoInfo infoFromItem(JellyfinItem item) {
    final JellyfinSubtitleStream? subtitle = _defaultTextSubtitle(item);
    return _remoteVideoInfoFor(
      // 走到这里的都是视频叶子（listRemoteVideos 先按 isPlayableVideo 过滤；
      // 详情 / 播放路径的 id 都来自视频叶子）。真遇到投影不了的类型也按叶子处理
      // ——与改动前「从不看类型」的行为一致，不丢条目。
      mediaServerItemFrom(
        item,
        mediaServerTypeOf(item) ?? MediaServerItemType.movie,
      ),
      sizeBytes: item.sizeBytes,
      subtitleFileName:
          subtitle == null ? null : _subtitleFileName(item, subtitle),
    );
  }

  RemoteVideoInfo _remoteVideoInfoFor(
    MediaServerItem item, {
    int? sizeBytes,
    String? subtitleFileName,
  }) =>
      RemoteVideoInfo(
        id: item.id,
        title: displayTitleOf(item),
        sizeBytes: sizeBytes,
        hasSubtitle: item.hasSubtitle,
        subtitleFileName: subtitleFileName,
        durationMs: item.durationMs,
        hasCover: item.hasCover,
        coverUrl: coverUrl(item),
        positionMs: item.positionMs,
        positionUpdatedAtMs: item.lastPlayedAtMs,
        collection: _collectionOf(item),
      );

  // ── MediaServerBrowser：JellyfinItem → MediaServerItem 纯函数投影 ─────────

  /// 服务器条目类型 → 浏览契约类型；非视频域（Audio / MusicAlbum / Book /
  /// Photo…）返回 null，调用方据此丢弃。
  ///
  /// 白名单显式列出三家共同的视频域类型；`Video` / `MusicVideo` / `Trailer`
  /// 是家庭视频库 / 音乐视频库里的可播叶子，与 Movie 同走 `/Videos/{id}/stream`，
  /// 按 movie 投影。未知类型只要 `IsFolder` 就当可下钻的文件夹（服务器自定义的
  /// 容器类型不少），但已知的音乐 / 图书 / 照片容器先于这条兜底被拦下——
  /// 否则 MusicAlbum 会作为「文件夹」混进视频库浏览。
  static MediaServerItemType? mediaServerTypeOf(JellyfinItem item) {
    switch (item.type) {
      case 'Movie':
      case 'Video':
      case 'MusicVideo':
      case 'Trailer':
        return MediaServerItemType.movie;
      case 'Series':
        return MediaServerItemType.series;
      case 'Season':
        return MediaServerItemType.season;
      case 'Episode':
        return MediaServerItemType.episode;
      case 'Folder':
      case 'BoxSet':
      case 'CollectionFolder':
      case 'UserView':
      case 'Playlist':
        return MediaServerItemType.folder;
      case 'Audio':
      case 'AudioBook':
      case 'MusicAlbum':
      case 'MusicArtist':
      case 'MusicGenre':
      case 'Book':
      case 'Photo':
      case 'PhotoAlbum':
      case 'Person':
      case 'Genre':
      case 'Studio':
      case 'Year':
      case 'Channel':
      case 'TvChannel':
      case 'LiveTvChannel':
      case 'LiveTvProgram':
      case 'Program':
      case 'Recording':
        return null;
    }
    return item.isFolder ? MediaServerItemType.folder : null;
  }

  /// [JellyfinItem] → [MediaServerItem]（纯函数；[type] 由
  /// [mediaServerTypeOf] 决定，调用方先判 null）。字段一一对应，不再解析 JSON。
  static MediaServerItem mediaServerItemFrom(
    JellyfinItem item,
    MediaServerItemType type,
  ) =>
      MediaServerItem(
        id: item.id,
        name: item.name,
        type: type,
        originalTitle: item.originalTitle,
        seriesId: item.seriesId,
        seriesName: item.seriesName,
        seasonId: item.seasonId,
        // 季自己的序号在 IndexNumber 上；集的季号在 ParentIndexNumber 上。
        seasonNumber: type == MediaServerItemType.season
            ? item.episodeNumber
            : item.seasonNumber,
        episodeNumber:
            type == MediaServerItemType.season ? null : item.episodeNumber,
        productionYear: item.productionYear,
        durationMs: item.durationMs,
        positionMs: item.positionMs,
        lastPlayedAtMs: item.lastPlayedAtMs,
        played: item.played,
        playedPercentage: item.playedPercentage,
        childCount: item.childCount,
        episodeCount: item.recursiveItemCount,
        unplayedChildCount: item.unplayedChildCount,
        hasCover: item.hasPrimaryImage,
        hasBackdrop: item.hasBackdrop,
        hasThumb: item.hasThumbImage,
        hasLogo: item.hasLogoImage,
        overview: item.overview,
        communityRating: item.communityRating,
        genres: item.genres,
        hasSubtitle: item.hasTextSubtitle,
      );

  /// 只保留视频域条目的投影（[mediaServerTypeOf] 为 null 的丢掉）。
  static List<MediaServerItem> mediaServerItemsFrom(
    Iterable<JellyfinItem> items,
  ) =>
      <MediaServerItem>[
        for (final JellyfinItem item in items)
          if (mediaServerTypeOf(item) case final MediaServerItemType type)
            mediaServerItemFrom(item, type),
      ];

  /// 展示标题（与 [JellyfinItem.displayTitle] 同一口径：单集拼
  /// `剧名 S01E02 集名`，其余用条目名）。播放页的合集面板 / 通知栏都吃它。
  static String displayTitleOf(MediaServerItem item) {
    final String? series = item.seriesName;
    if (item.type != MediaServerItemType.episode ||
        series == null ||
        series.isEmpty) {
      return item.name;
    }
    final String code = item.episodeCode;
    return '$series${code.isEmpty ? '' : ' $code'} ${item.name}';
  }

  @override
  String get serverId => remoteLibrarySourceId;

  @override
  String get displayName {
    final String? name = serverName;
    if (name != null && name.trim().isNotEmpty) return name.trim();
    final String host = Uri.tryParse(api.serverUrl)?.host ?? '';
    return host.isEmpty ? api.serverUrl : host;
  }

  @override
  String get serverUrl => api.serverUrl;

  @override
  RemoteVideoClient get playbackClient => this;

  @override
  Future<List<MediaServerLibrary>> listLibraries() async {
    final List<JellyfinLibraryView> views = await api.views(userId);
    return <MediaServerLibrary>[
      for (final JellyfinLibraryView v in views)
        if (v.isVideoish && v.id.isNotEmpty)
          MediaServerLibrary(
            id: v.id,
            name: v.name,
            kind: switch (v.collectionType) {
              'movies' => MediaServerLibraryKind.movies,
              'tvshows' => MediaServerLibraryKind.tvShows,
              _ => MediaServerLibraryKind.mixed,
            },
            hasCover: v.hasPrimaryImage,
          ),
    ];
  }

  /// [MediaServerSort] → 服务器 `SortBy` / `SortOrder`（单值，BUG-2254 谨慎）。
  static ({String sortBy, String sortOrder}) sortParamsFor(
    MediaServerSort sort,
  ) =>
      switch (sort) {
        MediaServerSort.name => (sortBy: 'SortName', sortOrder: 'Ascending'),
        MediaServerSort.dateAdded => (
            sortBy: 'DateCreated',
            sortOrder: 'Descending'
          ),
        MediaServerSort.premiereDate => (
            sortBy: 'PremiereDate',
            sortOrder: 'Descending'
          ),
        MediaServerSort.communityRating => (
            sortBy: 'CommunityRating',
            sortOrder: 'Descending'
          ),
      };

  /// 服务器一页 → 契约一页：客户端滤掉非视频域类型后，下一页起点仍按服务器
  /// **实际返回的行数**推（被滤掉的条目在服务器那边照样占序号）。
  static MediaServerPage _pageFrom(JellyfinItemsPage page, int startIndex) =>
      MediaServerPage(
        items: mediaServerItemsFrom(page.items),
        totalCount: page.totalCount,
        startIndex: startIndex,
        nextStartIndex: startIndex + page.items.length,
      );

  @override
  Future<MediaServerPage> listChildren({
    required String? parentId,
    int startIndex = 0,
    int limit = kMediaServerPageSize,
    MediaServerSort sort = MediaServerSort.name,
  }) async {
    final ({String sortBy, String sortOrder}) s = sortParamsFor(sort);
    final JellyfinItemsPage page = await api.children(
      userId: userId,
      parentId: parentId,
      startIndex: startIndex,
      limit: limit,
      sortBy: s.sortBy,
      sortOrder: s.sortOrder,
    );
    return _pageFrom(page, startIndex);
  }

  /// `/Shows/*` 这族端点在飞牛等兼容层上不保证存在：HTTP 非 2xx，或 200 却回
  /// SPA index.html（jsonDecode 抛 [FormatException]，BUG-2254 备注④），都算
  /// 「端点不可用」，退回通用 `/Items` 树。**网络层异常不在此列**——那是真断网，
  /// 回退也一样断，照常抛给页面。
  static bool _isEndpointUnavailable(Object e) =>
      e is JellyfinApiException || e is FormatException;

  @override
  Future<List<MediaServerItem>> listSeasons(String seriesId) async {
    JellyfinItemsPage page;
    try {
      page = await api.seasons(userId: userId, seriesId: seriesId);
    } catch (e) {
      if (!_isEndpointUnavailable(e)) rethrow;
      debugPrint('[jellyfin] /Shows/$seriesId/Seasons unavailable ($e); '
          'falling back to /Items?ParentId=');
      page = await api.items(
        userId: userId,
        parentId: seriesId,
        includeItemType: 'Season',
        limit: 200,
        fields: 'ChildCount,RecursiveItemCount,ProductionYear',
      );
    }
    final List<MediaServerItem> seasons = <MediaServerItem>[
      for (final MediaServerItem s in mediaServerItemsFrom(page.items))
        if (s.type == MediaServerItemType.season) s,
    ];
    // 服务器已按季号给出；回退路径按 SortName 来的也统一按季号排（特典 / 未编号
    // 的季放最后），页面不用再管来源。
    seasons.sort(_bySeasonThenEpisode);
    return seasons;
  }

  @override
  Future<MediaServerPage> listEpisodes({
    required String seriesId,
    String? seasonId,
    int startIndex = 0,
    int limit = kMediaServerEpisodePageSize,
  }) async {
    JellyfinItemsPage page;
    try {
      page = await api.episodes(
        userId: userId,
        seriesId: seriesId,
        seasonId: seasonId,
        startIndex: startIndex,
        limit: limit,
      );
    } catch (e) {
      if (!_isEndpointUnavailable(e)) rethrow;
      debugPrint('[jellyfin] /Shows/$seriesId/Episodes unavailable ($e); '
          'falling back to recursive /Items?ParentId=');
      // 与全库枚举同一条已在三家验过的请求形态（递归 + 单值 Episode）；集不
      // 一定直接挂在季下（无季文件夹的剧由服务器造虚拟季），递归才全。
      page = await api.items(
        userId: userId,
        parentId: seasonId ?? seriesId,
        recursive: true,
        includeItemType: 'Episode',
        startIndex: startIndex,
        limit: limit,
      );
    }
    final MediaServerPage out = _pageFrom(page, startIndex);
    // 服务器（正路径）本就按季集号给；回退路径按 SortName 分页，页内再按季集号
    // 排一遍——跨页顺序回退路径不保证，那是兼容层的代价，不在这里伪装。
    final List<MediaServerItem> episodes = <MediaServerItem>[
      for (final MediaServerItem e in out.items)
        if (e.type == MediaServerItemType.episode) e,
    ]..sort(_bySeasonThenEpisode);
    return MediaServerPage(
      items: episodes,
      totalCount: out.totalCount,
      startIndex: out.startIndex,
      nextStartIndex: out.nextStartIndex,
    );
  }

  /// 季集号升序；缺号的排最后（保持稳定，别让特典插到正片中间）。
  static int _bySeasonThenEpisode(MediaServerItem a, MediaServerItem b) {
    final int sa = a.seasonNumber ?? 1 << 30;
    final int sb = b.seasonNumber ?? 1 << 30;
    if (sa != sb) return sa.compareTo(sb);
    final int ea = a.episodeNumber ?? 1 << 30;
    final int eb = b.episodeNumber ?? 1 << 30;
    return ea.compareTo(eb);
  }

  /// 首页装饰行的统一失败口径：失败即空 + debugPrint（见契约文件头）。
  Future<List<MediaServerItem>> _rowOrEmpty(
    String what,
    Future<List<JellyfinItem>> Function() fetch,
  ) async {
    try {
      return mediaServerItemsFrom(await fetch());
    } catch (e) {
      debugPrint('[jellyfin] $what failed, showing an empty row: $e');
      return const <MediaServerItem>[];
    }
  }

  @override
  Future<List<MediaServerItem>> listResume({
    int limit = kMediaServerRowLimit,
  }) =>
      _rowOrEmpty(
        '/Items/Resume',
        () async => (await api.resume(userId: userId, limit: limit)).items,
      );

  @override
  Future<List<MediaServerItem>> listNextUp({
    int limit = kMediaServerRowLimit,
  }) =>
      _rowOrEmpty(
        '/Shows/NextUp',
        () async => (await api.nextUp(userId: userId, limit: limit)).items,
      );

  @override
  Future<List<MediaServerItem>> listLatest({
    String? libraryId,
    int limit = kMediaServerRowLimit,
  }) =>
      _rowOrEmpty(
        '/Items/Latest',
        () => api.latest(userId: userId, parentId: libraryId, limit: limit),
      );

  /// 搜索按类型分轮的顺序：电影在前、剧在后（单值 IncludeItemTypes，BUG-2254）。
  static const List<String> kSearchRounds = <String>['Movie', 'Series'];

  /// 搜索向服务器一次要的行数。命中要在客户端再把关（BUG-2608），一发多要些
  /// 才不至于为凑一页反复往返；条目不带 MediaSources，100 行也就几十 KB。
  static const int kSearchServerPageSize = 100;

  /// 单次 [search] 最多扫多少服务器行。兼容层按字模糊时命中率可以低到 1%，
  /// 不封顶一次调用会把整个结果集扫穿；封顶后本页返回已有命中、`hasMore`
  /// 照常为 true，页面按 nextStartIndex 接着扫。
  static const int kSearchScanLimit = 500;

  @override
  Future<MediaServerPage> search(
    String query, {
    int startIndex = 0,
    int limit = kMediaServerPageSize,
  }) async {
    final String term = query.trim();
    final List<String> tokens = mediaServerSearchTokens(term);
    if (tokens.isEmpty) return const MediaServerPage.empty();
    // 把两轮结果当成一条拼接序列分页：cursor 是拼接序里的服务器行位置，跨过
    // 一整轮就落到下一轮的本地偏移。每轮都要问一次（哪怕已经凑够也 Limit=1
    // 只取总数），否则 totalCount 算不出、hasMore 无从判断。
    //
    // 服务器回来的行先过 [mediaServerSearchMatches]（BUG-2608：兼容层的
    // SearchTerm 按字模糊，搜「怪奇物语」回 121 部沾一个字的电影），凑够 [limit]
    // 条命中或扫满 [kSearchScanLimit] 行才停；nextStartIndex 永远是服务器行偏移。
    // 排序在两轮合并后做一次：精确同名的剧不能排在电影轮「沾边」命中之后。
    final List<MediaServerItem> hits = <MediaServerItem>[];
    int cursor = startIndex;
    int roundBase = 0;
    int total = 0;
    int scanned = 0;
    for (final String type in kSearchRounds) {
      // cursor 落在本轮之前 = 上一轮还没扫完就凑够了：本轮只问总数，cursor 不动。
      final bool inRound = cursor >= roundBase;
      int localStart = inRound ? cursor - roundBase : 0;
      int? roundTotal;
      while (true) {
        final bool enough = hits.length >= limit || scanned >= kSearchScanLimit;
        if (roundTotal != null && (enough || localStart >= roundTotal)) break;
        final JellyfinItemsPage page = await api.items(
          userId: userId,
          recursive: true,
          includeItemType: type,
          searchTerm: term,
          startIndex: localStart,
          limit: enough ? 1 : kSearchServerPageSize,
          fields: 'ProductionYear,OriginalTitle',
        );
        roundTotal = page.totalCount;
        if (enough || localStart >= roundTotal || page.items.isEmpty) break;
        scanned += page.items.length;
        hits.addAll(
          mediaServerItemsFrom(page.items)
              .where((MediaServerItem it) => mediaServerSearchMatches(tokens, it)),
        );
        localStart += page.items.length;
      }
      total += roundTotal;
      if (inRound) cursor = roundBase + localStart;
      roundBase += roundTotal;
    }
    return MediaServerPage(
      items: rankMediaServerSearchHits(term, hits),
      totalCount: total,
      startIndex: startIndex,
      nextStartIndex: cursor,
    );
  }

  @override
  Future<MediaServerItem> itemDetail(String itemId) async {
    // `/Users/{uid}/Items/{id}` 不看 Fields、全量返回（Overview / Genres /
    // MediaSources 都在），与播放路径用的是同一发请求，不另加参数。
    final JellyfinItem item = await api.itemDetail(userId: userId, itemId: itemId);
    final MediaServerItemType? type = mediaServerTypeOf(item);
    if (type == null) {
      throw ArgumentError.value(itemId, 'itemId',
          'Jellyfin item type "${item.type}" is outside the video domain');
    }
    return mediaServerItemFrom(item, type);
  }

  @override
  String? coverUrl(
    MediaServerItem item, {
    int maxWidth = kMediaServerCoverMaxWidth,
    MediaServerImageKind kind = MediaServerImageKind.primary,
  }) {
    final (bool has, String imageType) = switch (kind) {
      MediaServerImageKind.primary => (item.hasCover, 'Primary'),
      MediaServerImageKind.backdrop => (item.hasBackdrop, 'Backdrop'),
      MediaServerImageKind.thumb => (item.hasThumb, 'Thumb'),
      MediaServerImageKind.logo => (item.hasLogo, 'Logo'),
    };
    if (!has) return null;
    return api.imageUrl(item.id, maxWidth: maxWidth, imageType: imageType);
  }

  @override
  String? libraryCoverUrl(
    MediaServerLibrary library, {
    int maxWidth = kMediaServerCoverMaxWidth,
  }) =>
      library.hasCover ? api.imageUrl(library.id, maxWidth: maxWidth) : null;

  @override
  RemoteVideoInfo toRemoteVideoInfo(MediaServerItem item) {
    if (!item.isPlayable) {
      throw ArgumentError.value(
          item.type, 'item', 'only Movie / Episode leaves are playable');
    }
    return _remoteVideoInfoFor(item);
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
  static RemoteCollectionMembership? _collectionOf(MediaServerItem item) {
    final String? series = item.seriesName;
    if (item.type != MediaServerItemType.episode ||
        series == null ||
        series.isEmpty) {
      return null;
    }
    return RemoteCollectionMembership(
      collectionName: series,
      collectionType: 'playlist',
      sortIndex: (item.seasonNumber ?? 0) * 10000 + (item.episodeNumber ?? 0),
    );
  }

  /// 本次枚举要递归哪些 ParentId（BUG-1891）。
  ///
  /// 三档，从窄到宽：
  ///  1. 用户在设置里点了名（[libraryIds] 非空）→ 只递归这几个库；
  ///  2. 没点名 → 问 `/Users/{uid}/Views` 要媒体库清单，只留视频域的
  ///     （[JellyfinLibraryView.isVideoish] 滤掉音乐/图书/照片库）。**这是新的默认
  ///     行为**：可见结果与整库递归一致（`IncludeItemTypes=Movie,Episode` 本来就
  ///     只在视频库里有命中），但服务器不必再被要求扫非视频库；
  ///  3. Views 拿不到 / 为空（老服务器、权限、网络抖）→ 退回 `[null]`，即旧的整库
  ///     递归。宁可多扫也不能因为一次 Views 失败就让用户的库整个消失。
  ///
  /// 返回的元素允许为 null（= 不带 ParentId 的整库递归）。
  Future<List<String?>> resolveEnumerationParents() async {
    if (libraryIds.isNotEmpty) return List<String?>.from(libraryIds);
    try {
      final List<JellyfinLibraryView> views = await api.views(userId);
      final List<String?> videoish = <String?>[
        for (final JellyfinLibraryView v in views)
          if (v.isVideoish && v.id.isNotEmpty) v.id,
      ];
      if (videoish.isNotEmpty) return videoish;
    } catch (e) {
      debugPrint('[jellyfin] views() failed, falling back to whole-server '
          'recursion: $e');
    }
    return const <String?>[null];
  }

  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() async {
    final List<String?> parents = await resolveEnumerationParents();
    final List<RemoteVideoInfo> out = <RemoteVideoInfo>[];
    final Set<String> seen = <String>{};
    bool truncated = false;
    int totalCount = 0;
    for (final String? parentId in parents) {
      final JellyfinRecursiveResult page =
          await api.recursiveVideoItems(userId: userId, parentId: parentId);
      truncated = truncated || page.truncated;
      totalCount += page.totalCount;
      for (final JellyfinItem item in page.items) {
        // 同一条目可能同时属于两个被点名的库（混合库 / 嵌套文件夹），按 id 去重。
        if (!item.isPlayableVideo || !seen.add(item.id)) continue;
        out.add(infoFromItem(item));
      }
    }
    if (truncated) {
      // 静默截断是「以为拉全了、其实没有」——至少要在日志里看得见。
      debugPrint('[jellyfin] library enumeration truncated at '
          '${JellyfinApi.kMaxRecursiveItems} items (server reported '
          '$totalCount); pick specific libraries in settings to narrow it.');
    }
    return out;
  }

  /// [RemoteVideoDetailFetch]：打一次 `/Items/{id}` 把清单里省掉的重字段
  /// （MediaSources → 文件大小 / 精确文本字幕轨 / 字幕文件名）补齐。
  @override
  Future<RemoteVideoInfo> remoteVideoDetail(RemoteVideoInfo listInfo) async {
    final JellyfinItem item =
        await api.itemDetail(userId: userId, itemId: listInfo.id);
    return infoFromItem(item);
  }

  @override
  Future<void> downloadRemoteVideo(
    String id,
    File dest, {
    void Function(double progress)? onProgress,
  }) async {
    // 飞牛要求 stream 端点带 MediaSourceId（BUG-2254 ③），而下载入参只有条目
    // id：先打一次 /Items/{id} 拿 MediaSources[0].Id。原版 Jellyfin/Emby 上省这发
    // 也可（stream 缺省按条目 id 解析），取一次是为了三家走同一条正确路径。
    final JellyfinItem item = await api.itemDetail(userId: userId, itemId: id);
    await api.downloadToFile(
      api.streamUrl(id, mediaSourceId: item.mediaSourceId),
      dest,
      onProgress: onProgress,
    );
  }

  /// 起播协商：PlaybackInfo 拿服务器裁决 + 会话 id，得到真正该播的 URL。
  ///
  /// - 直播放 / 直传（libmpv 什么都能解，两者对本客户端都是 `static=true` 直出，
  ///   与 Jellyfin web 一致）→ 直出 URL 带 `PlaySessionId` / `DeviceId`；
  /// - 服务器判定必须转码（码率超上限 / 用户策略）→ 用它签发的 `TranscodingUrl`（HLS）；
  /// - **兼容层回落**：飞牛影视等 Jellyfin 兼容层可能没有 PlaybackInfo 端点（404 /
  ///   回 SPA HTML）。那是外部系统缺功能，不是本端错误：记日志后退回此前的手拼直出
  ///   URL（无会话）。影响范围只限该服务器（无码率协商、Progress 无会话身份），
  ///   服务器补上端点即自动恢复，不需要本端改动。网络类异常照常抛出（详情请求
  ///   同样会失败，不该只吞这一个）。
  Future<({String streamUrl, JellyfinPlaybackSession? session})>
      _negotiatePlayback(String id, JellyfinItem item) async {
    final MediaServerQualityPreset? preset = _activeQualityPreset;
    JellyfinPlaybackInfo info;
    try {
      info = await api.playbackInfo(
        userId: userId,
        itemId: id,
        mediaSourceId: item.mediaSourceId,
        maxStreamingBitrate: preset?.maxBitrate,
        maxWidth: preset?.maxWidth,
      );
    } on JellyfinApiException catch (e, st) {
      debugPrint('[jellyfin] PlaybackInfo unavailable ($e); direct stream');
      // 只有 404 / 405 / 501 才是「端点不存在」的兼容层回落；其它状态码（真 Emby
      // 因 DeviceProfile 形状拒绝的 400、服务器 500）同样退回直出以免打断播放，
      // 但不能只留一行 debugPrint——落错误日志让「协商静默失效」可被发现。
      if (e.statusCode != 404 && e.statusCode != 405 && e.statusCode != 501) {
        ErrorLogService.instance.log('JellyfinVideoClient.playbackInfo', e, st);
      }
      return (
        streamUrl: api.streamUrl(id, mediaSourceId: item.mediaSourceId),
        session: null,
      );
    } on FormatException catch (e) {
      debugPrint('[jellyfin] PlaybackInfo not JSON ($e); direct stream');
      return (
        streamUrl: api.streamUrl(id, mediaSourceId: item.mediaSourceId),
        session: null,
      );
    }
    final String? playSessionId = info.playSessionId;
    JellyfinPlaybackMediaSource? source;
    for (final JellyfinPlaybackMediaSource candidate in info.mediaSources) {
      if (candidate.id == item.mediaSourceId) {
        source = candidate;
        break;
      }
    }
    source ??= info.mediaSources.isEmpty ? null : info.mediaSources.first;
    if (source == null || playSessionId == null || playSessionId.isEmpty) {
      // 服务器没给可播的源 / 没签会话（ErrorCode 之类）：仍按直出尝试，让 mpv 的
      // 打开结果说话（页面对网络流有「压根没打开」判定与重试）。
      debugPrint(
        '[jellyfin] PlaybackInfo gave no playable source '
        '(error=${info.errorCode}); direct stream',
      );
      return (
        streamUrl: api.streamUrl(id, mediaSourceId: item.mediaSourceId),
        session: null,
      );
    }
    final String? transcodingUrl = source.transcodingUrl;
    final bool direct = source.supportsDirectPlay || source.supportsDirectStream;
    final JellyfinPlaybackSession session;
    final String streamUrl;
    if (direct || transcodingUrl == null || transcodingUrl.isEmpty) {
      session = JellyfinPlaybackSession(
        itemId: id,
        mediaSourceId: source.id,
        playSessionId: playSessionId,
        playMethod: source.supportsDirectPlay ? 'DirectPlay' : 'DirectStream',
      );
      streamUrl = api.streamUrl(
        id,
        mediaSourceId: source.id,
        playSessionId: playSessionId,
      );
    } else {
      session = JellyfinPlaybackSession(
        itemId: id,
        mediaSourceId: source.id,
        playSessionId: playSessionId,
        playMethod: 'Transcode',
      );
      streamUrl = api.transcodingStreamUrl(transcodingUrl);
    }
    (_sessions[id] ??= <JellyfinPlaybackSession>[]).add(session);
    return (streamUrl: streamUrl, session: session);
  }

  @override
  Future<RemoteVideoStreamUrls> remoteVideoStreamUrls(
    String id, {
    int episodeIndex = 0,
  }) async {
    // Jellyfin 的每一集都是独立条目，episodeIndex 恒 0（多集语义不适用）。
    final JellyfinItem item = await api.itemDetail(userId: userId, itemId: id);
    final String? mediaSourceId = item.mediaSourceId;
    final ({String streamUrl, JellyfinPlaybackSession? session}) playback =
        await _negotiatePlayback(id, item);

    // 外挂文本字幕优先作为默认外挂轨；其余文本轨全部报给播放页的字幕轨选择器。
    JellyfinSubtitleStream? external;
    final List<RemoteVideoEmbeddedSubtitleTrack> tracks =
        <RemoteVideoEmbeddedSubtitleTrack>[];
    final Map<int, int> ordinals = containerSubtitleOrdinals(
      item.subtitleStreams,
    );
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
        containerTrackOrdinal: ordinals[s.index],
      ));
    }

    return RemoteVideoStreamUrls(
      // 服务器裁决后的 URL：直出（带会话）/ 转码 HLS / 兼容层回落的手拼直出
      // （飞牛要求带 MediaSourceId，BUG-2254 ③；服务器没给流表时省略）。
      streamUrl: playback.streamUrl,
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
      // 转码 HLS 不带容器内字幕轨（profile 声明文本轨 External，服务器不烧），
      // 播放页的「交给 libmpv 自绘」回落只对直出原始容器有效（BUG-2590）。
      streamIsOriginalContainer: playback.session?.playMethod != 'Transcode',
    );
  }

  /// **纯函数**：`MediaStreams[].Index`（全局流号）→ 容器内字幕轨 0 基序号。
  ///
  /// 按 [JellyfinSubtitleStream.index] 升序（= ffprobe 流序 = libmpv demux 序）给
  /// 每条**容器内**字幕轨编号，图形轨也占号（libmpv `tracks.subtitle` 同样含它），
  /// 外挂文件（`IsExternal`）不在容器里、不占号。服务器抽不出文本时播放页据此
  /// 让 libmpv 直接渲染流里的那条轨（[RemoteVideoEmbeddedSubtitleTrack.containerTrackOrdinal]）。
  static Map<int, int> containerSubtitleOrdinals(
    List<JellyfinSubtitleStream> streams,
  ) {
    final List<JellyfinSubtitleStream> inContainer = streams
        .where((JellyfinSubtitleStream s) => !s.isExternal)
        .toList(growable: false)
      ..sort((JellyfinSubtitleStream a, JellyfinSubtitleStream b) =>
          a.index.compareTo(b.index));
    return <int, int>{
      for (int i = 0; i < inContainer.length; i++) inContainer[i].index: i,
    };
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
    await api.reportProgress(
      itemId: id,
      positionMs: positionMs,
      session: _latestSession(id),
      eventName: 'timeupdate',
    );
  }

  @override
  Future<void> startRemoteVideoPlayback(String id, int positionMs) async {
    final JellyfinPlaybackSession? session = _latestSession(id);
    // 兼容层没签会话：没有可开始的东西，服务器也不认无会话的 Start。
    if (session == null) return;
    // 起播即重开心跳窗口：新会话第一条 Progress 不该被上一次播放的节流吃掉。
    _lastReportAtMs = 0;
    await api.reportStarted(session: session, positionMs: positionMs);
  }

  @override
  Future<void> setRemoteVideoPlaybackPaused(
    String id,
    int positionMs, {
    required bool paused,
  }) =>
      api.reportProgress(
        itemId: id,
        positionMs: positionMs,
        session: _latestSession(id),
        isPaused: paused,
        eventName: paused ? 'pause' : 'unpause',
      );

  /// 播放真正停止时通知 Jellyfin，触发已播放判定与 webhook 等服务端副作用。
  ///
  /// 与 [putRemoteVideoPosition] 分开：后者是播放中的节流心跳，不能替代停止事件。
  /// 会话是转码的还要显式停服务器上的 ffmpeg（[JellyfinApi.stopActiveEncodings]），
  /// 否则它跑到服务器自己的超时为止、与下一次起播抢 CPU。
  @override
  Future<void> stopRemoteVideoPlayback(String id, int positionMs) async {
    final List<JellyfinPlaybackSession>? list = _sessions[id];
    final JellyfinPlaybackSession? session =
        list == null || list.isEmpty ? null : list.removeAt(0);
    if (list != null && list.isEmpty) _sessions.remove(id);
    try {
      await api.reportStopped(
        itemId: id,
        positionMs: positionMs,
        session: session,
      );
    } finally {
      if (session != null && session.isTranscoding) {
        await api.stopActiveEncodings(session.playSessionId);
      }
    }
  }

  void close() => api.close();
}
