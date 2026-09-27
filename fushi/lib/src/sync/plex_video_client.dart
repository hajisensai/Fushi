// Plex Media Server 视频客户端（媒体服务器分区的第二种实现）。
//
// 协议层（HTTP / URL / JSON 解析 / plex.tv PIN 登录）在引擎包
// `packages/fushi_engine/lib/media/video/media_server/plex/`，纯 Dart；本文件只做
// app 侧适配：
// - [PlexServerConfig]：`MediaServerConfig` 的 Plex 实现，与 Jellyfin 共用
//   `sync_jellyfin_servers` 列表键，JSON 带 `kind: plex`；
// - [PlexVideoClient]：`MediaServerBrowser` + `RemoteVideoClient`（+ 封面 / 详情 /
//   播放会话），把 PMS 的 库 → 剧 → 季 → 集 树按父级分页原样暴露，播放走既有
//   播放页，不另造播放路径。
//
// v1 边界（写明，不伪装）：
// - 取流只做 **direct play**：`Part.key` + token 直出原文件，libmpv 解；不走 PMS
//   转码（`/video/:/transcode/universal`），所以没有画质档（不实现
//   `RemoteVideoQualityLimit`），码率超带宽时只能靠 mpv 缓冲。
// - 字幕：外挂（sidecar）文本字幕经 `/library/streams/{id}` 下载原文件；容器内
//   文本轨 PMS 不给单独文件，[PlexVideoClient.getRemoteVideoSubtitle] 对它抛出，
//   播放页据此交给 libmpv 从直出流里解码（与 Jellyfin 兼容层 BUG-2590 同一条回落）。
// - 进度：`/:/timeline`（playing / paused / stopped，10 秒一档心跳），停止时位置
//   过 90% 显式 `/:/scrobble`；续播读条目 `viewOffset`。
// - 不参与「混排进视频库」（`jellyfin_show_in_library` 那条旧路径只认 Jellyfin）。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha1;
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:http/http.dart' as http;

import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/media/video/media_server/media_server_config.dart';
import 'package:fushi/src/media/video/media_server/media_server_search_match.dart';
import 'package:fushi/src/sync/remote_cover_fetcher.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi_engine/media/video/media_server/plex/plex_api.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show
        RemoteVideoEmbeddedSubtitleTrack,
        RemoteVideoInfo,
        RemoteVideoStreamUrls;

/// 一台已登录 Plex 服务器的持久化配置。
///
/// JSON **刻意不含** `serverUrl` / `userId` / `accessToken` 三个 Jellyfin 必填键：
/// 引入 `kind` 字段之前的旧版本按 Jellyfin 解析每一项，缺这三个键即判脏项丢弃，
/// 不会拿 Plex token 去打 Jellyfin 端点（降级只会「看不到这台 Plex」，不会误请求）。
/// token 与 Jellyfin 令牌同款落 Drift prefs（列表键在设备本地黑名单里，不随备份
/// 出境）。
class PlexServerConfig implements MediaServerConfig {
  const PlexServerConfig({
    required this.machineIdentifier,
    required this.token,
    required this.clientIdentifier,
    required this.connections,
    this.serverName,
    this.accountId = '',
    this.accountName = '',
    this.activeServerUrl = '',
  });

  /// PMS 的 machineIdentifier（plex.tv resources 的 `clientIdentifier` /
  /// `/identity`）：这台服务器的身份锚，换地址 / 换连接不变。
  final String machineIdentifier;

  /// 访问这台服务器的 token（分享服务器取 resources 给的服务器级 token）。
  final String token;

  /// 登录时用的 `X-Plex-Client-Identifier`（本机 per-install id）。
  final String clientIdentifier;

  /// 全部连接地址（已按 局域网 → 公网 → relay 排好；手填登录只有一条）。
  final List<String> connections;
  final String? serverName;

  /// plex.tv 账号 id；手填 token 且查不到账号时为空串。
  final String accountId;

  @override
  final String accountName;

  /// 当前走的连接；空串 = [connections] 首条。
  final String activeServerUrl;

  static const String _kMachineId = 'machineIdentifier';
  static const String _kToken = 'plexToken';
  static const String _kClientId = 'clientIdentifier';
  static const String _kConnections = 'connections';
  static const String _kServerName = 'serverName';
  static const String _kAccountId = 'plexAccountId';
  static const String _kAccountName = 'plexUsername';
  static const String _kActive = 'activeServerUrl';

  @override
  MediaServerKind get kind => MediaServerKind.plex;

  @override
  String get sourceId => PlexVideoClient.sourceIdFor(
    machineIdentifier: machineIdentifier,
    accountId: accountId,
  );

  @override
  List<String> get routeUrls => connections;

  @override
  String get effectiveServerUrl =>
      activeServerUrl.isNotEmpty && connections.contains(activeServerUrl)
      ? activeServerUrl
      : connections.first;

  @override
  PlexServerConfig withActiveRoute(String url) => PlexServerConfig(
    machineIdentifier: machineIdentifier,
    token: token,
    clientIdentifier: clientIdentifier,
    connections: connections,
    serverName: serverName,
    accountId: accountId,
    accountName: accountName,
    activeServerUrl: connections.contains(url) && url != connections.first
        ? url
        : '',
  );

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    MediaServerKind.jsonKey: MediaServerKind.plex.wireName,
    _kMachineId: machineIdentifier,
    _kToken: token,
    _kClientId: clientIdentifier,
    _kConnections: connections,
    if (serverName != null) _kServerName: serverName,
    if (accountId.isNotEmpty) _kAccountId: accountId,
    if (accountName.isNotEmpty) _kAccountName: accountName,
    if (activeServerUrl.isNotEmpty) _kActive: activeServerUrl,
  };

  /// 缺 machineIdentifier / token / clientIdentifier / 连接地址 = 脏项，返回 null。
  static PlexServerConfig? fromJson(Map<String, dynamic> json) {
    final String machineIdentifier = (json[_kMachineId] as String?) ?? '';
    final String token = (json[_kToken] as String?) ?? '';
    final String clientIdentifier = (json[_kClientId] as String?) ?? '';
    final List<String> connections = <String>[];
    for (final Object? raw
        in (json[_kConnections] as List?) ?? const <Object?>[]) {
      if (raw is! String) continue;
      final String url = PlexApi.normalizeServerUrl(raw);
      if (url.isNotEmpty && !connections.contains(url)) connections.add(url);
    }
    if (machineIdentifier.isEmpty ||
        token.isEmpty ||
        clientIdentifier.isEmpty ||
        connections.isEmpty) {
      return null;
    }
    return PlexServerConfig(
      machineIdentifier: machineIdentifier,
      token: token,
      clientIdentifier: clientIdentifier,
      connections: connections,
      serverName: json[_kServerName] as String?,
      accountId: (json[_kAccountId] as String?) ?? '',
      accountName: (json[_kAccountName] as String?) ?? '',
      activeServerUrl: PlexApi.normalizeServerUrl(
        (json[_kActive] as String?) ?? '',
      ),
    );
  }

  PlexVideoClient buildClient({http.Client? httpClient}) => PlexVideoClient(
    api: PlexApi(
      serverUrl: effectiveServerUrl,
      token: token,
      clientInfo: PlexClientInfo(clientIdentifier: clientIdentifier),
      client: httpClient,
    ),
    machineIdentifier: machineIdentifier,
    accountId: accountId,
    serverName: serverName,
  );

  @override
  MediaServerBrowser buildBrowser({http.Client? httpClient}) =>
      buildClient(httpClient: httpClient);
}

/// Plex 媒体服务器客户端。
class PlexVideoClient
    implements
        RemoteVideoClient,
        RemoteCoverFetcher,
        RemoteVideoDetailFetch,
        RemoteVideoPlaybackSession,
        RemoteVideoCollectionIsWork,
        MediaServerBrowser {
  PlexVideoClient({
    required this.api,
    required this.machineIdentifier,
    this.accountId = '',
    this.serverName,
  });

  final PlexApi api;
  final String machineIdentifier;
  final String accountId;
  final String? serverName;

  /// 库 id 前缀：PMS 的库 key 与条目 ratingKey 是两个 id 空间、数字会撞，
  /// [listChildren] 靠前缀分辨「列库」还是「列子级」。
  static const String kLibraryIdPrefix = 'lib:';

  /// 进度心跳最小间隔（与 Jellyfin 同 10 秒一档）。
  static const int kPositionReportIntervalMs = 10000;

  /// 停止位置达到时长的这个比例即显式标记已看（与 PMS 自身判定口径一致）。
  static const double kWatchedThreshold = 0.9;

  /// [listRemoteVideos] 的熔断上限与页间隔（防死循环 / 防爬虫特征，同 Jellyfin）。
  static const int kMaxEnumeratedItems = 20000;
  static const int kEnumerationPageSize = 200;
  static const Duration kPageInterval = Duration(milliseconds: 150);

  /// 缓存槽身份的唯一构造点（登出失效等无实例的调用方也走这里）。
  static String sourceIdFor({
    required String machineIdentifier,
    required String accountId,
  }) => 'plex:$machineIdentifier|$accountId';

  @override
  String get remoteLibrarySourceId =>
      sourceIdFor(machineIdentifier: machineIdentifier, accountId: accountId);

  @override
  String get coverCacheNamespace =>
      'plex-${sha1.convert(utf8.encode('$machineIdentifier|$accountId'))}';

  @override
  Future<Uint8List> fetchRemoteCover(String coverUrl) =>
      api.fetchBytes(coverUrl);

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

  // ── PlexMetadata → MediaServerItem 纯函数投影 ─────────────────────────

  /// PMS 条目类型 → 浏览契约类型；音乐 / 照片等非视频域返回 null（丢弃）。
  static MediaServerItemType? mediaServerTypeOf(PlexMetadata m) =>
      switch (m.type) {
        'movie' || 'clip' || 'video' => MediaServerItemType.movie,
        'show' => MediaServerItemType.series,
        'season' => MediaServerItemType.season,
        'episode' => MediaServerItemType.episode,
        'collection' || 'playlist' => MediaServerItemType.folder,
        _ => null,
      };

  static MediaServerItem mediaServerItemFrom(
    PlexMetadata m,
    MediaServerItemType type,
  ) {
    final bool isEpisode = type == MediaServerItemType.episode;
    final bool isSeason = type == MediaServerItemType.season;
    final bool isLeaf = isEpisode || type == MediaServerItemType.movie;
    final int? leafCount = m.leafCount;
    final int? viewedLeafCount = m.viewedLeafCount;
    final int? duration = m.durationMs;
    return MediaServerItem(
      id: m.ratingKey,
      name: m.title,
      type: type,
      originalTitle: m.originalTitle,
      seriesId: isEpisode
          ? m.grandparentRatingKey
          : (isSeason ? m.parentRatingKey : null),
      seriesName: isEpisode
          ? m.grandparentTitle
          : (isSeason ? m.parentTitle : null),
      seasonId: isEpisode ? m.parentRatingKey : null,
      seasonNumber: isEpisode ? m.parentIndex : (isSeason ? m.index : null),
      episodeNumber: isEpisode ? m.index : null,
      productionYear: m.year,
      durationMs: duration,
      positionMs: m.viewOffsetMs,
      lastPlayedAtMs: m.lastViewedAtMs,
      played: isLeaf
          ? m.viewCount > 0
          : (leafCount != null &&
                leafCount > 0 &&
                viewedLeafCount != null &&
                viewedLeafCount >= leafCount),
      playedPercentage:
          isLeaf && duration != null && duration > 0 && m.viewOffsetMs > 0
          ? m.viewOffsetMs * 100 / duration
          : null,
      // 剧的 childCount 是季数；季自己的子项数就是集数。
      childCount: m.childCount ?? (isSeason ? leafCount : null),
      episodeCount: isLeaf ? null : leafCount,
      unplayedChildCount: leafCount != null && viewedLeafCount != null
          ? leafCount - viewedLeafCount
          : null,
      hasCover: m.thumb != null,
      hasBackdrop: m.art != null,
      // 集的 thumb 就是 16:9 截图；电影 / 剧没有单独的横版缩略图。
      hasThumb: isEpisode && m.thumb != null,
      hasLogo: m.hasClearLogo,
      parentBackdropItemId: isEpisode
          ? (m.grandparentArt != null ? m.grandparentRatingKey : null)
          : (isSeason && m.parentArt != null ? m.parentRatingKey : null),
      overview: m.summary,
      communityRating: m.rating,
      genres: m.genres,
      hasSubtitle: m.streams.any((PlexStream s) => s.isTextSubtitle),
    );
  }

  static List<MediaServerItem> mediaServerItemsFrom(
    Iterable<PlexMetadata> items,
  ) => <MediaServerItem>[
    for (final PlexMetadata m in items)
      if (mediaServerTypeOf(m) case final MediaServerItemType type)
        mediaServerItemFrom(m, type),
  ];

  static MediaServerPage _pageFrom(PlexMetadataPage page, int startIndex) =>
      MediaServerPage(
        items: mediaServerItemsFrom(page.items),
        totalCount: page.totalSize,
        startIndex: startIndex,
        nextStartIndex: startIndex + page.rawCount,
      );

  static String? _sectionKeyOf(String? libraryId) =>
      libraryId != null && libraryId.startsWith(kLibraryIdPrefix)
      ? libraryId.substring(kLibraryIdPrefix.length)
      : null;

  /// [MediaServerSort] → PMS `sort` 参数。
  static String sortParamFor(MediaServerSort sort) => switch (sort) {
    MediaServerSort.name => 'titleSort',
    MediaServerSort.dateAdded => 'addedAt:desc',
    MediaServerSort.premiereDate => 'originallyAvailableAt:desc',
    MediaServerSort.communityRating => 'rating:desc',
  };

  static int _bySeasonThenEpisode(MediaServerItem a, MediaServerItem b) {
    final int sa = a.seasonNumber ?? 1 << 30;
    final int sb = b.seasonNumber ?? 1 << 30;
    if (sa != sb) return sa.compareTo(sb);
    final int ea = a.episodeNumber ?? 1 << 30;
    final int eb = b.episodeNumber ?? 1 << 30;
    return ea.compareTo(eb);
  }

  // ── MediaServerBrowser ─────────────────────────────────────────────

  @override
  Future<List<MediaServerLibrary>> listLibraries() async =>
      <MediaServerLibrary>[
        for (final PlexSection s in await api.sections())
          if (s.isVideo && s.key.isNotEmpty)
            MediaServerLibrary(
              id: '$kLibraryIdPrefix${s.key}',
              name: s.title,
              kind: s.type == 'show'
                  ? MediaServerLibraryKind.tvShows
                  : MediaServerLibraryKind.movies,
            ),
      ];

  @override
  Future<MediaServerPage> listChildren({
    required String? parentId,
    int startIndex = 0,
    int limit = kMediaServerPageSize,
    MediaServerSort sort = MediaServerSort.name,
  }) async {
    if (parentId == null) {
      // 服务器根：把视频库当文件夹列出来（PMS 没有「根」条目）。
      final List<MediaServerLibrary> libraries = await listLibraries();
      return MediaServerPage(
        items: <MediaServerItem>[
          for (final MediaServerLibrary l in libraries)
            MediaServerItem(
              id: l.id,
              name: l.name,
              type: MediaServerItemType.folder,
            ),
        ],
        totalCount: libraries.length,
        startIndex: 0,
      );
    }
    final String? sectionKey = _sectionKeyOf(parentId);
    final PlexMetadataPage page = sectionKey != null
        ? await api.sectionItems(
            sectionKey,
            start: startIndex,
            size: limit,
            sort: sortParamFor(sort),
          )
        : await api.children(parentId, start: startIndex, size: limit);
    return _pageFrom(page, startIndex);
  }

  @override
  Future<List<MediaServerItem>> listSeasons(String seriesId) async {
    final PlexMetadataPage page = await api.children(seriesId);
    return <MediaServerItem>[
      for (final MediaServerItem s in mediaServerItemsFrom(page.items))
        if (s.type == MediaServerItemType.season) s,
    ]..sort(_bySeasonThenEpisode);
  }

  @override
  Future<MediaServerPage> listEpisodes({
    required String seriesId,
    String? seasonId,
    int startIndex = 0,
    int limit = kMediaServerEpisodePageSize,
  }) async {
    final PlexMetadataPage page = seasonId != null
        ? await api.children(seasonId, start: startIndex, size: limit)
        : await api.allLeaves(seriesId, start: startIndex, size: limit);
    final MediaServerPage out = _pageFrom(page, startIndex);
    return MediaServerPage(
      items: <MediaServerItem>[
        for (final MediaServerItem e in out.items)
          if (e.type == MediaServerItemType.episode) e,
      ]..sort(_bySeasonThenEpisode),
      totalCount: out.totalCount,
      startIndex: out.startIndex,
      nextStartIndex: out.nextStartIndex,
    );
  }

  /// 首页装饰行：先问新版 hub，失败退回旧端点；两者都失败即空 + debugPrint
  /// （契约「装饰行失败即空」口径）。
  Future<List<MediaServerItem>> _rowOrEmpty(
    String what,
    List<Future<List<PlexMetadata>> Function()> attempts,
    bool Function(MediaServerItem item) keep,
    int limit,
  ) async {
    for (final Future<List<PlexMetadata>> Function() attempt in attempts) {
      try {
        return <MediaServerItem>[
          for (final MediaServerItem it in mediaServerItemsFrom(
            await attempt(),
          ))
            if (keep(it)) it,
        ].take(limit).toList();
      } catch (e) {
        debugPrint('[plex] $what attempt failed: $e');
      }
    }
    return const <MediaServerItem>[];
  }

  @override
  Future<List<MediaServerItem>> listResume({
    int limit = kMediaServerRowLimit,
  }) => _rowOrEmpty(
    'continue watching',
    <Future<List<PlexMetadata>> Function()>[
      () => api.continueWatching(size: limit),
      () => api.libraryOnDeck(size: limit),
    ],
    (MediaServerItem it) => it.isPlayable && it.positionMs > 0,
    limit,
  );

  @override
  Future<List<MediaServerItem>> listNextUp({
    int limit = kMediaServerRowLimit,
  }) => _rowOrEmpty(
    'on deck',
    <Future<List<PlexMetadata>> Function()>[
      () => api.hubsOnDeck(size: limit),
      () => api.libraryOnDeck(size: limit),
    ],
    (MediaServerItem it) =>
        it.type == MediaServerItemType.episode && it.positionMs == 0,
    limit,
  );

  @override
  Future<List<MediaServerItem>> listLatest({
    String? libraryId,
    int limit = kMediaServerRowLimit,
  }) => _rowOrEmpty(
    'recently added',
    <Future<List<PlexMetadata>> Function()>[
      () =>
          api.recentlyAdded(sectionKey: _sectionKeyOf(libraryId), size: limit),
    ],
    (MediaServerItem it) => true,
    limit,
  );

  /// 一次搜索向 PMS 要的条数上限（`/hubs/search` 不分页）。
  static const int kSearchLimit = 100;

  @override
  Future<MediaServerPage> search(
    String query, {
    int startIndex = 0,
    int limit = kMediaServerPageSize,
  }) async {
    final String term = query.trim();
    final List<String> tokens = mediaServerSearchTokens(term);
    if (tokens.isEmpty) return const MediaServerPage.empty();
    // `/hubs/search` 不分页：第一页即全部，之后的页恒空（hasMore=false）。
    if (startIndex > 0) {
      return MediaServerPage(
        items: const <MediaServerItem>[],
        totalCount: startIndex,
        startIndex: startIndex,
      );
    }
    final List<PlexMetadata> hits = await api.searchHubs(
      term,
      limit: kSearchLimit,
    );
    final List<MediaServerItem> matched = <MediaServerItem>[
      for (final MediaServerItem it in mediaServerItemsFrom(hits))
        if (mediaServerSearchMatches(tokens, it)) it,
    ];
    return MediaServerPage(
      items: rankMediaServerSearchHits(term, matched),
      totalCount: hits.length,
      startIndex: 0,
      nextStartIndex: hits.length,
    );
  }

  @override
  Future<MediaServerItem> itemDetail(String itemId) async {
    final PlexMetadata m = await api.metadata(itemId);
    final MediaServerItemType? type = mediaServerTypeOf(m);
    if (type == null) {
      throw ArgumentError.value(
        itemId,
        'itemId',
        'Plex item type "${m.type}" is outside the video domain',
      );
    }
    return mediaServerItemFrom(m, type);
  }

  @override
  String? coverUrl(
    MediaServerItem item, {
    int maxWidth = kMediaServerCoverMaxWidth,
    MediaServerImageKind kind = MediaServerImageKind.primary,
  }) {
    final (bool has, String image) = switch (kind) {
      MediaServerImageKind.primary => (item.hasCover, 'thumb'),
      MediaServerImageKind.backdrop => (item.hasBackdrop, 'art'),
      MediaServerImageKind.thumb => (item.hasThumb, 'thumb'),
      MediaServerImageKind.logo => (item.hasLogo, 'clearLogo'),
    };
    if (!has || item.id.startsWith(kLibraryIdPrefix)) return null;
    // 竖版主图给 2:3 的框，其余给方框；PMS 保持比例缩进框内。
    return api.photoTranscodeUrl(
      '/library/metadata/${item.id}/$image',
      width: maxWidth,
      height: kind == MediaServerImageKind.primary
          ? maxWidth * 3 ~/ 2
          : maxWidth,
    );
  }

  /// PMS 的库封面是服务器合成的拼图（带时间戳路径），不在 v1 范围：页面按契约
  /// 用库内条目回退。
  @override
  String? libraryCoverUrl(
    MediaServerLibrary library, {
    int maxWidth = kMediaServerCoverMaxWidth,
  }) => null;

  RemoteVideoInfo _remoteVideoInfoFor(
    MediaServerItem item, {
    int? sizeBytes,
    String? subtitleFileName,
  }) => RemoteVideoInfo(
    id: item.id,
    title: mediaServerDisplayTitle(item),
    sizeBytes: sizeBytes,
    hasSubtitle: item.hasSubtitle,
    subtitleFileName: subtitleFileName,
    durationMs: item.durationMs,
    hasCover: item.hasCover,
    coverUrl: coverUrl(item),
    positionMs: item.positionMs,
    positionUpdatedAtMs: item.lastPlayedAtMs,
    collection: mediaServerCollectionOf(item),
  );

  @override
  RemoteVideoInfo toRemoteVideoInfo(MediaServerItem item) {
    if (!item.isPlayable) {
      throw ArgumentError.value(
        item.type,
        'item',
        'only Movie / Episode leaves are playable',
      );
    }
    return _remoteVideoInfoFor(item);
  }

  /// 详情（带 Stream）→ [RemoteVideoInfo]，补文件大小与默认字幕文件名。
  RemoteVideoInfo infoFromMetadata(PlexMetadata m) {
    final MediaServerItem item = mediaServerItemFrom(
      m,
      mediaServerTypeOf(m) ?? MediaServerItemType.movie,
    );
    final PlexStream? subtitle = _defaultExternalSubtitle(m);
    return _remoteVideoInfoFor(
      item,
      sizeBytes: m.primaryPart?.sizeBytes,
      subtitleFileName: subtitle == null
          ? null
          : _subtitleFileName(item, subtitle),
    );
  }

  static PlexStream? _defaultExternalSubtitle(PlexMetadata m) {
    for (final PlexStream s in m.streams) {
      if (s.isTextSubtitle && s.isExternal) return s;
    }
    return null;
  }

  static String _subtitleExt(String? codec) =>
      switch ((codec ?? '').toLowerCase()) {
        'ass' || 'ssa' => 'ass',
        'vtt' || 'webvtt' => 'vtt',
        'smi' || 'sami' => 'smi',
        _ => 'srt',
      };

  static String _subtitleFileName(MediaServerItem item, PlexStream s) {
    final String code = s.languageCode ?? '';
    final String lang = code.isEmpty ? '' : '.$code';
    return '${mediaServerDisplayTitle(item)}$lang.${_subtitleExt(s.codec)}';
  }

  /// **纯函数**：容器内字幕轨按 `index`（ffprobe 流序 = libmpv demux 序）升序编
  /// 0 基序号；外挂文件不在容器里、不占号。键是 [PlexStream.id]。
  static Map<int, int> containerSubtitleOrdinals(List<PlexStream> streams) {
    final List<PlexStream> inContainer =
        streams
            .where(
              (PlexStream s) =>
                  s.isSubtitle && !s.isExternal && s.index != null,
            )
            .toList(growable: false)
          ..sort((PlexStream a, PlexStream b) => a.index!.compareTo(b.index!));
    return <int, int>{
      for (int i = 0; i < inContainer.length; i++) inContainer[i].id: i,
    };
  }

  // ── RemoteVideoClient ──────────────────────────────────────────────

  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() async {
    final List<RemoteVideoInfo> out = <RemoteVideoInfo>[];
    final Set<String> seen = <String>{};
    bool firstPage = true;
    for (final PlexSection section in await api.sections()) {
      if (!section.isVideo) continue;
      // 电影库列电影（type=1），剧集库直接列集（type=4），不必逐剧下钻。
      final int type = section.type == 'show' ? 4 : 1;
      int start = 0;
      while (out.length < kMaxEnumeratedItems) {
        if (!firstPage) await Future<void>.delayed(kPageInterval);
        firstPage = false;
        final PlexMetadataPage page = await api.sectionItems(
          section.key,
          start: start,
          size: kEnumerationPageSize,
          type: type,
        );
        for (final PlexMetadata m in page.items) {
          final MediaServerItemType? t = mediaServerTypeOf(m);
          if (t == null || !seen.add(m.ratingKey)) continue;
          final MediaServerItem item = mediaServerItemFrom(m, t);
          if (item.isPlayable) out.add(_remoteVideoInfoFor(item));
        }
        start += page.rawCount;
        if (page.rawCount == 0 || start >= page.totalSize) break;
      }
    }
    if (out.length >= kMaxEnumeratedItems) {
      debugPrint(
        '[plex] library enumeration truncated at $kMaxEnumeratedItems items',
      );
    }
    return out;
  }

  @override
  Future<RemoteVideoInfo> remoteVideoDetail(RemoteVideoInfo listInfo) async =>
      infoFromMetadata(await api.metadata(listInfo.id));

  @override
  Future<void> downloadRemoteVideo(
    String id,
    File dest, {
    void Function(double progress)? onProgress,
    void Function(int received, int? total)? onBytes,
    Future<void>? cancelSignal,
  }) async {
    final PlexPart part = _requirePart(await api.metadata(id), id);
    await api.downloadToFile(
      api.partUrl(part.key, download: true),
      dest,
      onProgress: onProgress,
      onBytes: onBytes,
      cancelSignal: cancelSignal,
      cancelledError: () => const RemoteDownloadCancelled(),
    );
  }

  static PlexPart _requirePart(PlexMetadata m, String id) {
    final PlexPart? part = m.primaryPart;
    if (part == null) {
      throw FileSystemException('Plex item has no playable part', id);
    }
    return part;
  }

  /// 起播时记下的时长（timeline 上报要带 duration，PMS 据此判已看）。
  final Map<String, int> _durations = <String, int>{};

  @override
  Future<RemoteVideoStreamUrls> remoteVideoStreamUrls(
    String id, {
    int episodeIndex = 0,
  }) async {
    // 每一集都是独立条目，episodeIndex 恒 0。
    final PlexMetadata m = await api.metadata(id);
    final PlexPart part = _requirePart(m, id);
    final int? duration = m.durationMs ?? m.media.firstOrNull?.durationMs;
    if (duration != null && duration > 0) _durations[id] = duration;
    final MediaServerItem item = mediaServerItemFrom(
      m,
      mediaServerTypeOf(m) ?? MediaServerItemType.movie,
    );
    final Map<int, int> ordinals = containerSubtitleOrdinals(part.streams);
    PlexStream? external;
    final List<RemoteVideoEmbeddedSubtitleTrack> tracks =
        <RemoteVideoEmbeddedSubtitleTrack>[];
    for (final PlexStream s in part.streams) {
      if (!s.isTextSubtitle) continue;
      if (s.isExternal) external ??= s;
      tracks.add(
        RemoteVideoEmbeddedSubtitleTrack(
          streamIndex: s.id,
          codec: s.codec ?? 'srt',
          language: s.languageCode ?? s.language,
          title: s.title ?? s.displayTitle,
          // 只有外挂文件 PMS 能单独给；容器内的轨交给 libmpv 从直出流解码。
          url: s.isExternal ? api.streamFileUrl(s.key!) : null,
          fileName: _subtitleFileName(item, s),
          containerTrackOrdinal: ordinals[s.id],
          isExternalFile: s.isExternal,
        ),
      );
    }
    return RemoteVideoStreamUrls(
      streamUrl: api.partUrl(part.key),
      subtitleUrl: external == null ? null : api.streamFileUrl(external.key!),
      subtitleFileName: external == null
          ? null
          : _subtitleFileName(item, external),
      miningVideoHasAudio: true,
      embeddedSubtitleTracks: tracks,
    );
  }

  @override
  Future<void> getRemoteVideoSubtitle(
    String id,
    File dest, {
    int? embeddedStreamIndex,
    int episodeIndex = 0,
    void Function(double progress)? onProgress,
  }) async {
    final PlexMetadata m = await api.metadata(id);
    PlexStream? pick;
    if (embeddedStreamIndex == null) {
      pick = _defaultExternalSubtitle(m);
    } else {
      for (final PlexStream s in m.streams) {
        if (s.isTextSubtitle && s.id == embeddedStreamIndex) {
          pick = s;
          break;
        }
      }
    }
    if (pick == null) {
      throw FileSystemException('Plex item has no text subtitle', id);
    }
    if (!pick.isExternal) {
      // 容器内轨 PMS 不单独出文件：抛出后播放页回落到 libmpv 解码直出流里的轨。
      throw FileSystemException(
        'Plex does not serve embedded subtitle streams as files',
        id,
      );
    }
    await api.downloadToFile(
      api.streamFileUrl(pick.key!),
      dest,
      onProgress: onProgress,
    );
  }

  @override
  Future<({int positionMs, int updatedAtMs})> remoteVideoPosition(
    String id, {
    int episodeIndex = 0,
  }) async {
    final PlexMetadata m = await api.metadata(id);
    return (positionMs: m.viewOffsetMs, updatedAtMs: m.lastViewedAtMs);
  }

  int _lastReportAtMs = 0;
  String _lastReportItemId = '';

  @visibleForTesting
  int? debugDurationOf(String id) => _durations[id];

  Future<void> _timeline(String id, String state, int positionMs) =>
      api.timeline(
        ratingKey: id,
        state: state,
        timeMs: positionMs,
        durationMs: _durations[id],
      );

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
    // PMS 语义是 last-write-wins；updatedAtMs 只在本端语境有意义，不上传。
    await _timeline(id, 'playing', positionMs);
  }

  @override
  Future<void> startRemoteVideoPlayback(String id, int positionMs) async {
    // 新一次播放：心跳窗口重开，第一条进度不被上一集的节流吃掉。
    _lastReportAtMs = 0;
    await _timeline(id, 'playing', positionMs);
  }

  @override
  Future<void> setRemoteVideoPlaybackPaused(
    String id,
    int positionMs, {
    required bool paused,
  }) => _timeline(id, paused ? 'paused' : 'playing', positionMs);

  @override
  Future<void> stopRemoteVideoPlayback(String id, int positionMs) async {
    final int? duration = _durations[id];
    await _timeline(id, 'stopped', positionMs);
    if (duration != null &&
        duration > 0 &&
        positionMs >= duration * kWatchedThreshold) {
      await api.scrobble(id);
    }
  }

  void close() => api.close();
}
