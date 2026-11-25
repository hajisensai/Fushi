/// 媒体服务器入库作品的资料（BUG-5455）：从 Jellyfin / Emby / 飞牛 / Plex「加入
/// 媒体库」的剧 / 电影，用**服务器自己的**简介 / 原名 / 年份 / 评分 / 类型 / 海报 /
/// 背景 / logo / 分集名 / 分集简介 / 分集剧照，落进与刮削同一套规范资料表
/// （`video_metadata_*`，经 [VideoMetadataDatabaseStore.apply]），库里的合集详情页、
/// 首页卡因此与服务器详情页看到同一份资料。
///
/// 口径：
/// - 媒体服务器作品不在任何刮削计划里（`videoBookInScrapeScope` 只认本机文件），
///   服务器资料就是它唯一的资料来源，与本地 `.nfo` 同属「用户已有资料的离线兼容
///   输入」。作品主身份记 `mediaserver`（[VideoMetadataProviderKind.mediaserver]），
///   服务器给的 TMDB / AniDB / IMDb / TVDB ID 只作**非主**交叉引用；
/// - **只覆盖自己写的资料**：作品行已存在且主身份不是 `mediaserver`（用户 / 刮削 /
///   互联写过别的身份）时一律不动；用户在编辑对话框里锁住的字段由 `apply` 保留；
/// - 服务器图片 URL 带访问令牌（Jellyfin `api_key`），不能落库：图下载到
///   [VideoStorage.mediaServerImagesDir]，图行的 `remoteUrl` 存去掉令牌的地址，只当
///   身份键与兜底；
/// - 一切失败只记错误日志，绝不让「加入媒体库」失败。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha1;
import 'package:flutter/foundation.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_database_store.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_operation_gate.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart';
import 'package:fushi_engine/media/video/video_storage.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteCollectionMembership, RemoteVideoInfo;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/utils/misc/bounded_concurrency.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 服务器 `ProviderIds` 里落成交叉引用的键（小写）。其余（AniList 等已退役源）
/// 不落：退役源的身份不能被重新带进资料表。
const Set<String> kMediaServerCrossReferenceProviders = <String>{
  'tmdb',
  'anidb',
  'imdb',
  'tvdb',
};

/// 同时下载的资料图数（剧集一次入库几十张剧照）。
const int kMediaServerImageConcurrency = 4;

/// 资料图种类 → 文件名后缀。顺序无关，回收时逐个试删。
const List<VideoMetadataImageKind> kMediaServerImageKinds =
    <VideoMetadataImageKind>[
      VideoMetadataImageKind.cover,
      VideoMetadataImageKind.backdrop,
      VideoMetadataImageKind.logo,
      VideoMetadataImageKind.thumb,
    ];

/// 一条入库叶子：服务器条目 + 它在本机的入库行身份（`VideoBooks.bookUid`）。
typedef MediaServerLeafRow = ({MediaServerItem item, String bookUid});

/// 作品主身份的外部 id：服务器 + 作品 id（同一部剧在两台服务器上是两部作品）。
String mediaServerMetadataId(String serverId, String itemId) =>
    '$serverId/$itemId';

/// 一张媒体服务器资料图的本地文件名：`<sha1(服务器\n条目 id)>_<种类>.jpg`。
String mediaServerImageFileName(
  String serverId,
  String itemId,
  VideoMetadataImageKind kind,
) => '${sha1.convert(utf8.encode('$serverId\n$itemId'))}_${kind.name}.jpg';

/// 去掉访问令牌的图片地址（落库只存它）。Jellyfin / Emby 的令牌在 `api_key` /
/// `X-Emby-Token`，Plex 在 `X-Plex-Token`；其余常见名一并去掉。
String mediaServerImageIdentityUrl(String url) {
  final Uri? uri = Uri.tryParse(url);
  if (uri == null || !uri.hasQuery) return url;
  const Set<String> secrets = <String>{
    'api_key',
    'x-emby-token',
    'x-plex-token',
    'x-mediabrowser-token',
    'token',
    'access_token',
  };
  final Map<String, List<String>> kept = <String, List<String>>{
    for (final MapEntry<String, List<String>> entry
        in uri.queryParametersAll.entries)
      if (!secrets.contains(entry.key.toLowerCase())) entry.key: entry.value,
  };
  // `replace(queryParameters: null)` 保留原查询串：全被去掉时要显式清空。
  return kept.isEmpty
      ? uri.replace(query: '').toString().replaceFirst(RegExp(r'\?$'), '')
      : uri.replace(queryParameters: kept).toString();
}

/// 把服务器条目拼成中立资料模型（纯函数）。
///
/// [images] 是已经落盘的图：条目 id → 种类 → 去令牌地址（见
/// [mediaServerImageIdentityUrl]）；没落盘的图不进模型。[seasonNames] 是季号 →
/// 服务器季名（取不到为空串）。缺集号的叶子无法对齐到分集卡，不进分集表。
VideoMetadataWork buildMediaServerMetadataWork({
  required String serverId,
  required MediaServerItem work,
  required List<MediaServerItem> leaves,
  Map<int, String> seasonNames = const <int, String>{},
  Map<String, Map<VideoMetadataImageKind, String>> images =
      const <String, Map<VideoMetadataImageKind, String>>{},
}) {
  List<VideoMetadataImage> imagesOf(String itemId) => <VideoMetadataImage>[
    for (final MapEntry<VideoMetadataImageKind, String> entry
        in (images[itemId] ?? const <VideoMetadataImageKind, String>{}).entries)
      VideoMetadataImage(
        kind: entry.key,
        url: entry.value,
        provider: VideoMetadataProviderKind.mediaserver,
      ),
  ];
  final bool isSeries = work.type == MediaServerItemType.series;
  final Map<int, List<VideoMetadataEpisode>> episodesBySeason =
      <int, List<VideoMetadataEpisode>>{};
  if (isSeries) {
    for (final MediaServerItem leaf in leaves) {
      final int? number = leaf.episodeNumber;
      if (number == null) continue;
      final int season = leaf.seasonNumber ?? 1;
      (episodesBySeason[season] ??= <VideoMetadataEpisode>[]).add(
        VideoMetadataEpisode(
          seasonNumber: season,
          episodeNumber: number,
          title: leaf.name,
          plot: _nonEmpty(leaf.overview),
          year: leaf.productionYear,
          rating: _positive(leaf.communityRating),
          runtimeMinutes: _minutes(leaf.durationMs),
          ids: <VideoMetadataId>[
            VideoMetadataId(
              type: VideoMetadataProviderKind.mediaserver.name,
              value: mediaServerMetadataId(serverId, leaf.id),
            ),
          ],
          images: imagesOf(leaf.id),
        ),
      );
    }
  }
  final List<int> seasonNumbers = episodesBySeason.keys.toList()..sort();
  final String? original = _nonEmpty(work.originalTitle);
  return VideoMetadataWork(
    provider: VideoMetadataProviderKind.mediaserver,
    kind: isSeries ? VideoMetadataMediaKind.tv : VideoMetadataMediaKind.movie,
    title: work.name,
    originalTitle: original == work.name ? null : original,
    year: work.productionYear,
    plot: _nonEmpty(work.overview),
    rating: _positive(work.communityRating),
    runtimeMinutes: isSeries ? null : _minutes(work.durationMs),
    seasonCount: isSeries ? seasonNumbers.length : null,
    episodeCount: isSeries
        ? (work.episodeCount ??
              episodesBySeason.values.fold<int>(
                0,
                (int sum, List<VideoMetadataEpisode> e) => sum + e.length,
              ))
        : null,
    genres: work.genres,
    ids: <VideoMetadataId>[
      VideoMetadataId(
        type: VideoMetadataProviderKind.mediaserver.name,
        value: mediaServerMetadataId(serverId, work.id),
      ),
      for (final MapEntry<String, String> entry in work.providerIds.entries)
        if (kMediaServerCrossReferenceProviders.contains(
              entry.key.toLowerCase(),
            ) &&
            entry.value.trim().isNotEmpty)
          VideoMetadataId(
            type: entry.key.toLowerCase(),
            value: entry.value.trim(),
          ),
    ],
    images: imagesOf(work.id),
    seasons: <VideoMetadataSeason>[
      for (final int season in seasonNumbers)
        VideoMetadataSeason(
          seasonNumber: season,
          title: seasonNames[season] ?? '',
          episodeCount: episodesBySeason[season]!.length,
          episodes: episodesBySeason[season]!,
        ),
    ],
  );
}

String? _nonEmpty(String? value) {
  final String? trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

double? _positive(double? value) => value != null && value > 0 ? value : null;

int? _minutes(int? durationMs) => durationMs == null || durationMs <= 0
    ? null
    : (durationMs / Duration.millisecondsPerMinute).round();

/// 把服务器资料写进本机规范资料表（见文件头口径）。
class MediaServerMetadataSync {
  MediaServerMetadataSync(this.database)
    : store = VideoMetadataDatabaseStore(database);

  final FushiDatabase database;
  final VideoMetadataDatabaseStore store;

  /// 同步 [work]（剧或电影）的资料。[leaves] 是它全部入库叶子（含早已在库的），
  /// [membership] 是剧的合集归属（电影为 null）。失败只记日志。
  Future<void> sync(
    MediaServerBrowser browser,
    MediaServerItem work,
    List<MediaServerLeafRow> leaves, {
    RemoteCollectionMembership? membership,
  }) async {
    try {
      await _sync(browser, work, leaves, membership);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('MediaServerMetadataSync', error, stack);
    }
  }

  Future<void> _sync(
    MediaServerBrowser browser,
    MediaServerItem work,
    List<MediaServerLeafRow> leaves,
    RemoteCollectionMembership? membership,
  ) async {
    final VideoSourceScrapeWork? target = await _targetOf(
      work,
      leaves,
      membership,
    );
    if (target == null) return;
    if (!await _ownsMetadata(target)) return;
    final Map<int, String> seasonNames = work.type == MediaServerItemType.series
        ? await _seasonNames(browser, work)
        : const <int, String>{};
    final ({
      Map<String, Map<VideoMetadataImageKind, String>> urls,
      Map<String, String> localPaths,
    })
    images = await _downloadImages(browser, work, leaves);
    final List<MediaServerItem> items = <MediaServerItem>[
      for (final MediaServerLeafRow leaf in leaves) leaf.item,
    ];
    final VideoMetadataWork metadata = buildMediaServerMetadataWork(
      serverId: browser.serverId,
      work: work,
      leaves: items,
      seasonNames: seasonNames,
      images: images.urls,
    );
    final VideoScrapeOperationLease? lease =
        VideoScrapeOperationGate.tryEnterOperation();
    if (lease == null) throw VideoScrapeMaintenanceActiveError();
    try {
      final PersistedVideoMetadata persisted = await store.apply(
        target,
        metadata,
        episodeOverrides: <String, (int, int)>{
          for (final MediaServerLeafRow leaf in leaves)
            if (leaf.item.episodeNumber case final int episode)
              leaf.bookUid: (leaf.item.seasonNumber ?? 1, episode),
        },
      );
      if (images.localPaths.isNotEmpty) {
        await store.updateCanonicalImagePaths(
          persisted: persisted,
          metadata: metadata,
          localPathByRemoteUrl: images.localPaths,
        );
      }
    } finally {
      lease.release();
    }
  }

  /// 本机写入目标：剧 = 剧名合集 + 它的全部视频成员（含已下载到本机的集）；
  /// 电影 = 它自己那一行。
  Future<VideoSourceScrapeWork?> _targetOf(
    MediaServerItem work,
    List<MediaServerLeafRow> leaves,
    RemoteCollectionMembership? membership,
  ) async {
    if (membership == null) {
      if (leaves.length != 1) return null;
      final VideoBookRow? row = await database.getVideoBookByBookUid(
        leaves.single.bookUid,
      );
      if (row == null) return null;
      return VideoSourceScrapeWork(
        source: null,
        title: row.title,
        members: <VideoBookRow>[row],
      );
    }
    final MediaCollectionRow? collection = await database
        .getMediaCollectionByNaturalKey(
          membership.collectionName,
          membership.collectionType,
        );
    if (collection == null) return null;
    final List<VideoBookRow> members = <VideoBookRow>[];
    for (final MediaCollectionItemRow item in await database.getCollectionItems(
      collection.id,
    )) {
      if (item.mediaType != MediaKind.video.dbValue) continue;
      final VideoBookRow? row = await database.getVideoBookByBookUid(
        item.entryKey,
      );
      if (row != null) members.add(row);
    }
    if (members.isEmpty) return null;
    return VideoSourceScrapeWork(
      source: null,
      collection: collection,
      title: collection.name,
      members: members,
    );
  }

  /// 资料归不归服务器管：还没有作品行，或作品行的主身份就是 `mediaserver`。
  /// 别的主身份（刮削 / 互联 / 手动识别写的），或没有主身份的行（用户手填的
  /// 资料）都不碰。
  Future<bool> _ownsMetadata(VideoSourceScrapeWork target) async {
    final VideoMetadataWorkRow? row = target.collection == null
        ? await database.getVideoMetadataWorkByBook(
            target.members.single.bookUid,
          )
        : await database.getVideoMetadataWorkByCollection(
            target.collection!.id,
          );
    if (row == null) return true;
    final VideoMetadataProviderIdentityRow? primary =
        (await database.getVideoMetadataProviderIdentities(workId: row.id))
            .where((VideoMetadataProviderIdentityRow r) => r.isPrimary)
            .firstOrNull;
    return primary?.provider == VideoMetadataProviderKind.mediaserver.name;
  }

  Future<Map<int, String>> _seasonNames(
    MediaServerBrowser browser,
    MediaServerItem work,
  ) async {
    try {
      return <int, String>{
        for (final MediaServerItem season in await browser.listSeasons(work.id))
          if (season.seasonNumber case final int number) number: season.name,
      };
    } on Object catch (error) {
      // 季名只是标题装饰：取不到照样落分集资料。
      debugPrint('[media-server-metadata] seasons ${work.id}: $error');
      return const <int, String>{};
    }
  }

  /// 下载作品海报 / 背景 / logo 与各集剧照；已落盘的不重下。返回落盘成功的图：
  /// 条目 → 种类 → 去令牌地址，以及去令牌地址 → 本地路径。
  Future<
    ({
      Map<String, Map<VideoMetadataImageKind, String>> urls,
      Map<String, String> localPaths,
    })
  >
  _downloadImages(
    MediaServerBrowser browser,
    MediaServerItem work,
    List<MediaServerLeafRow> leaves,
  ) async {
    final List<(String, VideoMetadataImageKind, String)>
    wanted = <(String, VideoMetadataImageKind, String)>[
      for (final (MediaServerImageKind serverKind, VideoMetadataImageKind kind)
          in const <(MediaServerImageKind, VideoMetadataImageKind)>[
            (MediaServerImageKind.primary, VideoMetadataImageKind.cover),
            (MediaServerImageKind.backdrop, VideoMetadataImageKind.backdrop),
            (MediaServerImageKind.logo, VideoMetadataImageKind.logo),
          ])
        if (browser.coverUrl(
              work,
              kind: serverKind,
              maxWidth: serverKind == MediaServerImageKind.backdrop
                  ? 1920
                  : kMediaServerCoverMaxWidth,
            )
            case final String url when url.isNotEmpty)
          (work.id, kind, url),
      // 集自己的 Primary 是 16:9 剧照（见 [MediaServerItem.seriesCoverItemId]）。
      if (work.type == MediaServerItemType.series)
        for (final MediaServerLeafRow leaf in leaves)
          if (browser.coverUrl(leaf.item) case final String url
              when url.isNotEmpty)
            (leaf.item.id, VideoMetadataImageKind.thumb, url),
    ];
    final Map<String, Map<VideoMetadataImageKind, String>> urls =
        <String, Map<VideoMetadataImageKind, String>>{};
    final Map<String, String> localPaths = <String, String>{};
    if (wanted.isEmpty) return (urls: urls, localPaths: localPaths);
    final Directory dir = await VideoStorage.mediaServerImagesDir();
    await dir.create(recursive: true);
    await runBoundedTasks<(String, VideoMetadataImageKind, String)>(
      wanted,
      maxConcurrent: kMediaServerImageConcurrency,
      task: ((String, VideoMetadataImageKind, String) image) async {
        final (String itemId, VideoMetadataImageKind kind, String url) = image;
        final String path = p.join(
          dir.path,
          mediaServerImageFileName(browser.serverId, itemId, kind),
        );
        try {
          final File file = File(path);
          if (!await file.exists()) {
            final Uint8List bytes = await browser.fetchRemoteCover(url);
            if (bytes.isEmpty) return;
            final File partial = File('$path.part');
            await partial.writeAsBytes(bytes, flush: true);
            await partial.rename(path);
          }
          final String identity = mediaServerImageIdentityUrl(url);
          (urls[itemId] ??= <VideoMetadataImageKind, String>{})[kind] =
              identity;
          localPaths[identity] = path;
        } on Object catch (error) {
          // 一张图取不到不影响其余资料：库页对没有的图有回退。
          debugPrint('[media-server-metadata] image $itemId/$kind: $error');
        }
      },
    );
    return (urls: urls, localPaths: localPaths);
  }
}

/// 回收这些条目的资料图文件（作品移出媒体库时；行已删）。只删
/// [VideoStorage.mediaServerImagesDir] 里按 [mediaServerImageFileName] 派生的文件。
Future<void> deleteMediaServerImageFiles(
  String serverId,
  Iterable<String> itemIds,
) async {
  final Directory dir = await VideoStorage.mediaServerImagesDir();
  if (!await dir.exists()) return;
  for (final String itemId in itemIds) {
    for (final VideoMetadataImageKind kind in kMediaServerImageKinds) {
      final File file = File(
        p.join(dir.path, mediaServerImageFileName(serverId, itemId, kind)),
      );
      try {
        if (await file.exists()) await file.delete();
      } on FileSystemException catch (error) {
        debugPrint('[media-server-metadata] delete ${file.path}: $error');
      }
    }
  }
}

/// 把服务器上的观看状态补进本机入库行（BUG-5455）：服务器标了已看、本机还没
/// 看完 → 记看完（时刻用服务器的最近播放时刻）；服务器断点比本机新 → 采用服务器
/// 断点。只补不撤：本机已看完的不因服务器未看而取消（本机标记会经
/// `video_watched_marks` 回写服务器，两边最终一致）。互联同款口径：时刻用对端的，
/// 不冒充「本机刚看」。
Future<void> importMediaServerProgress(
  FushiDatabase database,
  List<MediaServerLeafRow> leaves,
) async {
  for (final MediaServerLeafRow leaf in leaves) {
    final VideoBookRow? row = await database.getVideoBookByBookUid(
      leaf.bookUid,
    );
    if (row == null) continue;
    final MediaServerItem item = leaf.item;
    final int serverAt = item.lastPlayedAtMs;
    final bool serverNewer = serverAt > 0 && serverAt > (row.lastPlayedAt ?? 0);
    if (item.played) {
      if (row.completedAt == null) {
        await database.setVideoBooksWatched(
          <String>[row.bookUid],
          serverAt > 0
              ? DateTime.fromMillisecondsSinceEpoch(serverAt)
              : DateTime.now(),
        );
      }
      if (serverNewer) {
        await database.updateVideoBookPosition(
          row.bookUid,
          0,
          playedAt: serverAt,
        );
      }
      continue;
    }
    if (item.positionMs > 0 && serverNewer) {
      await database.updateVideoBookPosition(
        row.bookUid,
        item.positionMs,
        playedAt: serverAt,
      );
    }
  }
}

/// [info] 的合集归属（剧集叶子有，电影没有）。
RemoteCollectionMembership? mediaServerMembershipOf(
  Iterable<RemoteVideoInfo> infos,
) {
  for (final RemoteVideoInfo info in infos) {
    if (info.collection case final RemoteCollectionMembership membership) {
      return membership;
    }
  }
  return null;
}
