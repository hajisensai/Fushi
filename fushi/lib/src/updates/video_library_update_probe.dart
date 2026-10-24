/// 媒体库里的在线视频作品自动补新集（2026-10-23）。
///
/// 两类入库作品都只是「入库那一刻」的快照：在线视频源（Aniyomi 扩展，
/// `anime_source_library.dart`）与媒体服务器的剧（`media_server_library.dart`）。
/// 这条探针挂在统一的 [UpdateCheckScheduler] 上（`UpdateFeedKind.videoEpisode`
/// 域，6 小时一轮），逐部作品向源 / 服务器重取集清单，交给各自既有的
/// `addMissing`（已在库的集跳过）补上新集，再把新集投进更新中心——与订阅下载
/// 到新集同一个域、同一种落点（`{bookUid, collectionId}` → 从媒体库打开那一集）。
///
/// **开关与提醒分开**（用户 2026-10-23 拍板）：要不要后台补集只看偏好
/// `video_library_auto_update`（调度器那一侧的门，见 `AppModel.startUpdateChecks`）；
/// 「番剧新集提醒」开关只决定补上的集进不进更新中心 / 发不发通知
/// （`UpdateFeedService.publishBatch` 自己按域开关丢弃）。
///
/// **串行**、单部失败只跳过这一部（与漫画探针同一纪律）。在线视频源**不主动拉起
/// Mihon 宿主**：本进程没用过在线视频源（[animeManager] 为 null）就跳过这一类，
/// 等用户用过之后的那一轮再查。
library;

import 'dart:convert' show jsonEncode;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/anime_source_video_path.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;
import 'package:fushi_engine/updates/update_feed_kind.dart';
import 'package:fushi_engine/updates/update_feed_port.dart';

import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/media/video/media_server/media_server_config.dart';
import 'package:fushi/src/media/video/media_server/media_server_library.dart';
import 'package:fushi/src/media/video/online/anime_source_library.dart';
import 'package:fushi/src/media/video/online/anime_source_video_client.dart';

/// 后台补集偏好（bool，默认 true）。
const String kVideoLibraryAutoUpdatePref = 'video_library_auto_update';

/// 跑一轮。返回这轮补上的集数（测试与日志用）。
Future<int> runVideoLibraryUpdateProbe({
  required FushiDatabase database,
  required UpdateFeedPublisher feed,
  required Future<List<MediaServerConfig>> Function() loadMediaServers,
  MihonManager? animeManager,
}) async {
  int total = 0;
  if (animeManager != null) {
    total += await _refreshAnimeSourceWorks(database, feed, animeManager);
  }
  total += await _refreshMediaServerWorks(database, feed, loadMediaServers);
  return total;
}

Future<int> _refreshAnimeSourceWorks(
  FushiDatabase database,
  UpdateFeedPublisher feed,
  MihonManager manager,
) async {
  // 一部作品取一份规格（同扩展、同源、同作品 URL 即同一部）。
  final List<AnimeSourceBookSpec> works = <AnimeSourceBookSpec>[];
  for (final VideoBookRow row in await database.allVideoBooks()) {
    if (!isAnimeSourceVideoPath(row.videoPath)) continue;
    final AnimeSourceBookSpec? spec = AnimeSourceBookSpec.tryParse(
      row.streamSpecJson,
    );
    if (spec == null || works.any(spec.sameWorkAs)) continue;
    works.add(spec);
  }
  if (works.isEmpty) return 0;
  // 只读库（不联网刷新仓库索引），与重开入库集同口径。
  await manager.reload();
  final AnimeSourceLibrary library = AnimeSourceLibrary(database: database);
  int total = 0;
  for (final AnimeSourceBookSpec spec in works) {
    AnimeSourceVideoClient? client;
    try {
      MangaOnlineSourceRow? sourceRow;
      for (final MangaOnlineSourceRow candidate in manager.sources) {
        if (candidate.extensionPackage == spec.extensionPackage &&
            candidate.sourceId == spec.sourceId &&
            candidate.enabled) {
          sourceRow = candidate;
          break;
        }
      }
      // 扩展卸载 / 停用：这一部查不了，跳过（重开时播放页会给明确提示）。
      if (sourceRow == null) continue;
      final MihonSourceContext context = await manager.contextForSource(
        sourceRow,
      );
      final List<MihonEpisode> episodes = await manager.animeRuntime
          .getEpisodes(
            context.extension,
            context.source,
            spec.anime,
            preferences: context.preferences,
          );
      // 源返回空清单多半是源挂了 / 被拦：不当成「没有新集」以外的任何信号。
      if (episodes.isEmpty) continue;
      client = AnimeSourceVideoClient(
        manager: manager,
        context: context,
        anime: spec.anime,
        episodes: sortEpisodesForPlayback(episodes),
      );
      final List<RemoteVideoInfo> added = await library.addMissing(client);
      total += added.length;
      await _publish(database, feed, spec.anime.title, added);
    } on Object catch (error) {
      debugPrint('[video-library-update] ${spec.anime.title} failed: $error');
    } finally {
      client?.dispose();
    }
  }
  return total;
}

Future<int> _refreshMediaServerWorks(
  FushiDatabase database,
  UpdateFeedPublisher feed,
  Future<List<MediaServerConfig>> Function() loadMediaServers,
) async {
  final MediaServerVideoLibrary library = MediaServerVideoLibrary(
    database: database,
  );
  final List<({String serverId, String workId})> works = await library
      .seriesWorksInLibrary();
  if (works.isEmpty) return 0;
  final Map<String, MediaServerBrowser> browsers =
      <String, MediaServerBrowser>{};
  for (final MediaServerConfig config in await loadMediaServers()) {
    browsers[config.sourceId] = config.buildBrowser();
  }
  int total = 0;
  for (final ({String serverId, String workId}) work in works) {
    // 那台服务器已登出：查不了，跳过。
    final MediaServerBrowser? browser = browsers[work.serverId];
    if (browser == null) continue;
    try {
      final MediaServerItem series = await browser.itemDetail(work.workId);
      if (series.type != MediaServerItemType.series) continue;
      final List<RemoteVideoInfo> added = await library.addMissing(
        browser,
        series,
      );
      total += added.length;
      await _publish(database, feed, series.name, added);
    } on Object catch (error) {
      debugPrint('[video-library-update] ${work.workId} failed: $error');
    }
  }
  return total;
}

/// 新集进更新中心：与订阅下载新集同一个域与落点（`{bookUid, collectionId}`），
/// 同一部作品合成一条通知（按合集分组）。
Future<void> _publish(
  FushiDatabase database,
  UpdateFeedPublisher feed,
  String workTitle,
  List<RemoteVideoInfo> added,
) async {
  if (added.isEmpty) return;
  final List<UpdateFeedDraft> drafts = <UpdateFeedDraft>[];
  for (final RemoteVideoInfo info in added) {
    final String? collectionName = info.collection?.collectionName;
    final MediaCollectionRow? collection = collectionName == null
        ? null
        : await database.getMediaCollectionByNaturalKey(
            collectionName,
            'playlist',
          );
    final int collectionId = collection?.id ?? 0;
    final VideoBookRow? row = await database.getVideoBookByBookUid(info.id);
    final String? imagePath = row?.coverPath ?? collection?.coverPath;
    drafts.add(
      UpdateFeedDraft(
        kind: UpdateFeedKind.videoEpisode,
        targetKey: videoEpisodeTargetKey(
          collectionId: collectionId,
          episodeKey: info.id,
        ),
        title: workTitle,
        subtitle: info.title,
        detailJson: jsonEncode(<String, Object?>{
          if (collection != null) 'collectionId': collection.id,
          'bookUid': info.id,
          'imagePath': ?imagePath,
        }),
        imagePath: imagePath,
        notificationGroup: collection == null
            ? null
            : 'collection:${collection.id}',
      ),
    );
  }
  await feed.publishBatch(UpdateFeedKind.videoEpisode, drafts);
}
