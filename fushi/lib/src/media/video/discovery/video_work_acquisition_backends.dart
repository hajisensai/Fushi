/// 「获取途径」四个渠道的后端实现（[VideoAcquisitionChannelBackend]）。
///
/// 每个后端只吃端口（取注册表 / 列来源 / 列服务器 / 按身份找本地作品），不直接碰
/// AppModel，单测给假端口即可；生产装配在 `home_page.dart` 的
/// `_videoWorkAcquisitionBackends` 一处，合规门也在那里决定传不传某个渠道。
library;

import 'package:flutter/widgets.dart';
import 'package:fushi/src/media/manga/mihon/mihon_enabled_sources.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/video/discovery/video_work_acquisition_controller.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/media/video/online/anime_source_detail_page.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_aggregate_search_view.dart'
    show MediaServerSearchOutcome, searchMediaServerSession;
import 'package:fushi/src/pages/implementations/media_server/media_server_routes.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_session.dart';
import 'package:fushi/src/storage/storage_usage_service.dart'
    show formatStorageBytes;
import 'package:fushi/src/utils/misc/bounded_concurrency.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart' show MangaOnlineSourceRow;
import 'package:fushi_engine/media/torrent/rss_search_provider.dart';
import 'package:fushi_engine/media/torrent/rss_search_site.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';

/// 按名称搜的渠道（在线源 / 媒体服务器）最多试几个查询词（标题 → 原名 → 别名）。
const int kVideoAcquisitionMaxSearchTitles = 2;

/// 每个来源 / 服务器最多列几条命中。
const int kVideoAcquisitionPerSourceLimit = 5;

// ---------------------------------------------------------------------------
// 媒体库
// ---------------------------------------------------------------------------

/// 媒体库渠道：「这部作品是否已在库」只问装配层注入的 [find]——生产接的是详情页
/// 「已在库 / 播放」同一个解析（按 provider 身份匹配本地作品，回落 AniList id
/// 匹配合集），两处不会出现一边说在库、一边找不到的分歧。
class LibraryAcquisitionBackend implements VideoAcquisitionChannelBackend {
  const LibraryAcquisitionBackend({required this.find});

  final Future<VideoAcquisitionHit?> Function(VideoMediaReference reference)
  find;

  @override
  VideoAcquisitionChannel get channel => VideoAcquisitionChannel.library;

  @override
  Future<VideoAcquisitionLookup> lookup(VideoMediaReference reference) async {
    final VideoAcquisitionHit? hit = await find(reference);
    return VideoAcquisitionLookup.hits(<VideoAcquisitionHit>[?hit]);
  }
}

// ---------------------------------------------------------------------------
// BT 搜索
// ---------------------------------------------------------------------------

/// [registry] 里有没有会参与 [category] 这类作品查询的来源。与
/// [VideoResourceRegistry.search] 的选源口径相同（注册了 = 配好且启用，再按
/// 域归属 [videoResourceProviderApplies] 取交集）。
///
/// [RssSearchProvider] 是例外：它对 registry 报「不限域」，在 search 里按每个站
/// 自己勾的视频域逐站裁，所以这里要下钻到站——只有某个已启用的站勾了 [category]
/// 才算这类作品「配好了」，否则只勾了电影的站会让动漫详情页误报「有来源」。
bool hasApplicableVideoResourceProvider(
  VideoResourceRegistry registry,
  VideoDiscoveryCategory? category,
) => registry.providers.any(
  (VideoResourceProvider provider) => provider is RssSearchProvider
      ? provider.sites.any(
          (RssSearchSiteConfig site) => site.appliesToVideo(category),
        )
      : videoResourceProviderApplies(provider, category),
);

/// BT 渠道：只走 [VideoResourceRegistry] 的公共接口。面板预览前几条资源与总数，
/// 真正的挑选 / 落地 / 提交仍在现有资源搜索页（[openSearch]）里完成。
class TorrentAcquisitionBackend implements VideoAcquisitionChannelBackend {
  const TorrentAcquisitionBackend({
    required this.registry,
    required this.openSearch,
    required this.configure,
    this.previewLimit = 3,
  });

  final VideoResourceRegistry? Function() registry;
  final VideoAcquisitionOpen openSearch;
  final VideoAcquisitionOpen configure;
  final int previewLimit;

  @override
  VideoAcquisitionChannel get channel => VideoAcquisitionChannel.torrent;

  @override
  Future<VideoAcquisitionLookup> lookup(VideoMediaReference reference) async {
    final VideoResourceRegistry? registry = this.registry();
    if (registry == null ||
        !hasApplicableVideoResourceProvider(
          registry,
          reference.discoveryCategory,
        )) {
      return VideoAcquisitionLookup.unconfigured(configure: configure);
    }
    final VideoResourceSearchResult result = await registry.search(
      VideoResourceSearchRequest(media: reference),
    );
    if (result.items.isEmpty &&
        result.successfulProviderCount == 0 &&
        result.failures.isNotEmpty) {
      throw result.failures.first;
    }
    return VideoAcquisitionLookup.hits(
      <VideoAcquisitionHit>[
        for (final VideoResourceCandidate candidate in result.items.take(
          previewLimit,
        ))
          VideoAcquisitionHit(
            id:
                '${persistedVideoResourceProviderId(candidate)}:'
                '${candidate.remoteId}',
            title: candidate.title,
            meta: <String>[
              if (candidate.sizeBytes case final int size when size > 0)
                formatStorageBytes(size),
              if (candidate.resolution case final String resolution) resolution,
              if (candidate.seeders > 0) '↑${candidate.seeders}',
            ],
          ),
      ],
      totalCount: result.items.length,
      failedSourceCount: result.sources
          .where((VideoResourceSourceReport report) => report.failed)
          .length,
      entry: openSearch,
    );
  }
}

// ---------------------------------------------------------------------------
// 按名称搜的多来源渠道（在线源 / 媒体服务器）共用
// ---------------------------------------------------------------------------

/// 一个可按名称搜索的来源。[search] 返回该来源对一个查询词的命中（已截断）。
class VideoAcquisitionSearchTarget {
  const VideoAcquisitionSearchTarget({
    required this.id,
    required this.name,
    required this.search,
  });

  final String id;
  final String name;
  final Future<List<VideoAcquisitionHit>> Function(String query) search;
}

/// 对每个来源依次试 [titles]，第一个有命中的为准；来源之间有界并发。全部来源都
/// 失败时抛出第一个错误，部分失败计入 failedSourceCount。
Future<VideoAcquisitionLookup> searchVideoAcquisitionTargets({
  required List<VideoAcquisitionSearchTarget> targets,
  required List<String> titles,
  required String logTag,
  int maxConcurrent = 4,
}) async {
  final List<List<VideoAcquisitionHit>> perTarget =
      List<List<VideoAcquisitionHit>>.filled(
        targets.length,
        const <VideoAcquisitionHit>[],
      );
  final List<Object> errors = <Object>[];
  await runBoundedTasks<int>(
    <int>[for (int i = 0; i < targets.length; i++) i],
    maxConcurrent: maxConcurrent,
    task: (int index) async {
      final VideoAcquisitionSearchTarget target = targets[index];
      try {
        for (final String title in titles) {
          final List<VideoAcquisitionHit> hits = await target.search(title);
          if (hits.isNotEmpty) {
            perTarget[index] = hits;
            return;
          }
        }
      } on Object catch (error, stack) {
        ErrorLogService.instance.log('$logTag[${target.name}]', error, stack);
        errors.add(error);
      }
    },
  );
  if (targets.isNotEmpty && errors.length == targets.length) {
    throw VideoAcquisitionChannelFailure(errors.first);
  }
  return VideoAcquisitionLookup.hits(<VideoAcquisitionHit>[
    for (final List<VideoAcquisitionHit> hits in perTarget) ...hits,
  ], failedSourceCount: errors.length);
}

// ---------------------------------------------------------------------------
// 在线源（Aniyomi）
// ---------------------------------------------------------------------------

/// 在线源渠道：在已启用的 Aniyomi 视频源上按作品标题搜。
class OnlineSourceAcquisitionBackend implements VideoAcquisitionChannelBackend {
  const OnlineSourceAcquisitionBackend({required this.targets, this.configure});

  /// 已启用的来源。空 = 渠道未配置。
  final Future<List<VideoAcquisitionSearchTarget>> Function() targets;
  final VideoAcquisitionOpen? configure;

  @override
  VideoAcquisitionChannel get channel => VideoAcquisitionChannel.onlineSource;

  @override
  Future<VideoAcquisitionLookup> lookup(VideoMediaReference reference) async {
    final List<VideoAcquisitionSearchTarget> sources = await targets();
    if (sources.isEmpty) {
      return VideoAcquisitionLookup.unconfigured(configure: configure);
    }
    return searchVideoAcquisitionTargets(
      targets: sources,
      titles: videoAcquisitionSearchTitles(
        reference,
        max: kVideoAcquisitionMaxSearchTitles,
      ),
      logTag: 'VideoAcquisition.onlineSource',
    );
  }
}

/// 生产：视频 Mihon 运行时上已启用的 Aniyomi 源（与浏览页同一份「已启用」口径
/// [enabledMangaOnlineSources]），命中点进 [AnimeSourceDetailPage]。
Future<List<VideoAcquisitionSearchTarget>> mihonAnimeAcquisitionTargets(
  MihonManager manager,
) async {
  // initialise 的最后一步是刷新扩展仓库，离线时会抛，但已装的来源在那之前就已
  // 读出——有来源就照常搜；一个来源都没读出来又抛了，才如实当「整个渠道失败」
  // 报，而不是伪装成「没装扩展」。
  Object? initError;
  try {
    await manager.initialise();
  } on Object catch (error) {
    initError = error;
  }
  final List<MangaOnlineSourceRow> rows = enabledMangaOnlineSources(manager);
  if (rows.isEmpty && initError != null) {
    throw VideoAcquisitionChannelFailure(initError);
  }
  return <VideoAcquisitionSearchTarget>[
    for (final MangaOnlineSourceRow row in rows)
      VideoAcquisitionSearchTarget(
        id: 'mihon:${row.extensionPackage}:${row.sourceId}',
        name: row.name,
        search: (String query) async {
          final MihonSourceContext context = await manager.contextForSource(
            row,
          );
          final MihonAnimePage page = await manager.animeRuntime.searchAnime(
            context.extension,
            context.source,
            page: 1,
            query: query,
            preferences: context.preferences,
          );
          return <VideoAcquisitionHit>[
            for (final MihonAnime anime in page.items.take(
              kVideoAcquisitionPerSourceLimit,
            ))
              VideoAcquisitionHit(
                id: 'mihon:${row.extensionPackage}:${row.sourceId}:${anime.url}',
                title: anime.title,
                subtitle: row.name,
                meta: <String>[if (row.language.isNotEmpty) row.language],
                open: (BuildContext buildContext) =>
                    Navigator.of(buildContext).push<void>(
                      adaptivePageRoute<void>(
                        context: buildContext,
                        builder: (_) => AnimeSourceDetailPage(
                          manager: manager,
                          sourceContext: context,
                          anime: anime,
                        ),
                      ),
                    ),
              ),
          ];
        },
      ),
  ];
}

// ---------------------------------------------------------------------------
// 媒体服务器
// ---------------------------------------------------------------------------

/// 媒体服务器渠道：在已配置的 Jellyfin / Emby / Plex 上按标题搜（与「搜索所有
/// 服务器」同一个 [searchMediaServerSession]），命中按卡片同款路由打开
/// （电影 / 剧进详情、集直接播）。
class MediaServerAcquisitionBackend implements VideoAcquisitionChannelBackend {
  const MediaServerAcquisitionBackend({required this.sessions, this.configure});

  final Future<List<MediaServerSession>> Function() sessions;
  final VideoAcquisitionOpen? configure;

  @override
  VideoAcquisitionChannel get channel => VideoAcquisitionChannel.mediaServer;

  @override
  Future<VideoAcquisitionLookup> lookup(VideoMediaReference reference) async {
    final List<MediaServerSession> servers = await sessions();
    if (servers.isEmpty) {
      return VideoAcquisitionLookup.unconfigured(configure: configure);
    }
    return searchVideoAcquisitionTargets(
      targets: <VideoAcquisitionSearchTarget>[
        for (final MediaServerSession session in servers)
          VideoAcquisitionSearchTarget(
            id: session.serverId,
            name: session.browser.displayName,
            search: (String query) => _searchServer(session, query),
          ),
      ],
      titles: videoAcquisitionSearchTitles(
        reference,
        max: kVideoAcquisitionMaxSearchTitles,
      ),
      logTag: 'VideoAcquisition.mediaServer',
    );
  }

  static Future<List<VideoAcquisitionHit>> _searchServer(
    MediaServerSession session,
    String query,
  ) async {
    final MediaServerSearchOutcome outcome = await searchMediaServerSession(
      session,
      query,
    );
    if (outcome.error case final Object error) {
      throw VideoAcquisitionChannelFailure(error);
    }
    final List<MediaServerItem> items = outcome.items;
    return <VideoAcquisitionHit>[
      for (final MediaServerItem item in items.take(
        kVideoAcquisitionPerSourceLimit,
      ))
        VideoAcquisitionHit(
          id: '${session.serverId}:${item.id}',
          title: item.name,
          subtitle: session.browser.displayName,
          meta: <String>[
            if (item.seriesName case final String series
                when series.isNotEmpty && series != item.name)
              series,
            if (item.productionYear case final int year) '$year',
          ],
          open: (BuildContext context) async =>
              openMediaServerItem(context, session, item, siblings: items),
        ),
    ];
  }
}
