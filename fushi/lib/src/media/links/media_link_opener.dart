import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/media/collections/collection_episode_slot.dart';
import 'package:fushi/src/media/links/media_link_entries.dart';
import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/sources/manga_fushi_source.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/galgame_detail_page.dart';
import 'package:fushi/src/pages/implementations/media_collection_detail_page.dart';
import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/pages/implementations/music/music_album_page.dart';
import 'package:fushi/src/pages/implementations/music/music_track_detail_page.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/ai/ai_media_acquisition_assistant.dart'
    show AiMediaAcquisitionDomain;
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/video_resource_search_launcher.dart';
import 'package:fushi/src/pages/implementations/browse_online_sources_view.dart'
    show OnlineSourcesDomain;
import 'package:fushi/src/pages/implementations/discovery_ai_acquire_action.dart';

/// 「未入库」灰卡的「去搜」：交给各模块**已有**的获取入口，标题预填。返回 null =
/// 本平台 / 本配置没有可用入口（灰卡就只是灰卡，不渲染一个点了没去处的按钮）。
///
/// - 视频合集 / 单个视频：视频资源搜索页（[openVideoResourceSearch]，与合集详情页
///   「相关作品 › 去下载」同一个；灰卡只有标题，进手动身份模式），
///   门是「浏览」模块开着——该模块的 `availableOn` 已委托 `StoreRestrictedCapability`，
///   iOS 上恒关；
/// - 书 / 游戏：发现页同一个「AI 下载」入口（[discoveryAiAcquireAction]），合规门
///   （下载 / 外部发现）与 AI 模块门都在它里面，不在这里另写平台判断；
/// - 音乐：音乐模块落地前没有获取入口。
ValueChanged<String>? mediaLinkSearchAction({
  required BuildContext context,
  required WidgetRef ref,
  required MediaLinkKind kind,
}) {
  final AppModel appModel = ref.read(appProvider);
  switch (kind) {
    case MediaLinkKind.videoCollection:
    case MediaLinkKind.videoEpisode:
      if (!appModel.moduleVisibility.isEnabled(ModuleId.browse)) return null;
      return (String title) => unawaited(
        openVideoResourceSearch(
          context,
          appModel: ref.read(appProvider),
          initialQuery: title,
        ),
      );
    case MediaLinkKind.book:
    case MediaLinkKind.audiobook:
      return discoveryAiAcquireAction(
        context: context,
        readAppModel: () => ref.read(appProvider),
        domain: AiMediaAcquisitionDomain.novel,
        domainLabel: mediaLinkKindLabel(kind),
        onlineDomain: OnlineSourcesDomain.novel,
      );
    case MediaLinkKind.game:
      return discoveryAiAcquireAction(
        context: context,
        readAppModel: () => ref.read(appProvider),
        domain: AiMediaAcquisitionDomain.game,
        domainLabel: mediaLinkKindLabel(kind),
      );
    case MediaLinkKind.musicAlbum:
    case MediaLinkKind.musicTrack:
      return null;
  }
}

/// 打开作品图谱另一端在本机的条目：各模块已有的那个出口，不另起页面。
///
/// - 视频合集 → 合集详情页（与「相关作品」打开已绑定合集同一形态）；
/// - 单个视频 → 播放器（属于合集就作为合集一集打开，与统计页 / ctl 同一口径）；
/// - 书 / 有声书 → 漫画进作品页，其余与书架点卡同一条 [AppModel.openMedia]；
/// - 游戏 → 游戏详情页；
/// - 音乐曲目 → 曲目详情页（出现在哪些集 / 同一作品）；专辑 → 专辑页。
Future<void> openMediaLinkEntry({
  required BuildContext context,
  required WidgetRef ref,
  required MediaLinkEntry entry,
}) async {
  final AppModel appModel = ref.read(appProvider);
  final FushiDatabase db = appModel.database;
  final NavigatorState navigator = Navigator.of(context);
  final MediaLinkEndpoint e = entry.endpoint;
  switch (e.kind) {
    case MediaLinkKind.videoCollection:
      final int? id = collectionIdOfTagEntryKey(e.key);
      final MediaCollectionRow? target = id == null
          ? null
          : await db.getMediaCollectionById(id);
      if (target == null || !navigator.mounted) return;
      final VideoBookRepository repo = VideoBookRepository(db);
      unawaited(
        navigator.push<void>(
          adaptivePageRoute<void>(
            context: navigator.context,
            builder: (BuildContext pageContext) => MediaCollectionDetailPage(
              database: db,
              collection: target,
              loadEpisodes: () => loadCollectionEpisodeSlots(
                repository: repo,
                collectionId: target.id,
              ),
              onOpenEpisode: (VideoBookRow episode) {
                Navigator.of(pageContext).push<void>(
                  adaptivePageRoute<void>(
                    context: pageContext,
                    builder: (_) => VideoFushiPage.neutralized(
                      bookUid: episode.bookUid,
                      repo: repo,
                      playlistCollectionId: target.id,
                    ),
                  ),
                );
              },
              onChanged: () {},
            ),
          ),
        ),
      );
    case MediaLinkKind.videoEpisode:
      final VideoBookRepository repo = VideoBookRepository(db);
      final VideoBookRow? row = await repo.getByBookUid(e.key);
      if (row == null) return;
      final Map<String, int> primary = await db.getPrimaryCollectionIdByEntry();
      if (!navigator.mounted) return;
      unawaited(
        navigator.push<void>(
          adaptivePageRoute<void>(
            context: navigator.context,
            builder: (_) => VideoFushiPage.neutralized(
              bookUid: row.bookUid,
              repo: repo,
              playlistCollectionId:
                  primary[MediaKind.video.compositeKey(row.bookUid)],
            ),
          ),
        ),
      );
    case MediaLinkKind.book:
    case MediaLinkKind.audiobook:
      final MediaItem? item = await ReaderFushiSource.instance
          .mediaItemForBookKey(e.key);
      if (item == null || !navigator.mounted) return;
      if (item.mediaSourceIdentifier == MangaFushiSource.kUniqueKey) {
        unawaited(
          navigator.push<void>(
            adaptivePageRoute<void>(
              context: navigator.context,
              builder: (_) => MangaSeriesPage(
                target: ShelfMangaSeriesTarget(e.key, item: item),
              ),
            ),
          ),
        );
        return;
      }
      unawaited(
        appModel.openMedia(
          ref: ref,
          mediaSource: item.getMediaSource(appModel: appModel),
          item: item,
          waitUntilClosed: false,
        ),
      );
    case MediaLinkKind.game:
      unawaited(
        navigator.push<void>(
          adaptivePageRoute<void>(
            context: navigator.context,
            builder: (_) => GalgameDetailPage(gameId: e.key, initialTab: 0),
          ),
        ),
      );
    case MediaLinkKind.musicTrack:
      unawaited(
        navigator.push<void>(
          adaptivePageRoute<void>(
            context: navigator.context,
            builder: (_) => MusicTrackDetailPage(trackUid: e.key),
          ),
        ),
      );
    case MediaLinkKind.musicAlbum:
      final MusicAlbumRow? album = await db.getMusicAlbum(e.key);
      if (album == null) return;
      final List<MusicTrackRow> tracks = sortAlbumTracks(<MusicTrackRow>[
        for (final MusicTrackRow tr in await db.listMusicTracks(
          albumUid: album.albumUid,
        ))
          if (tr.deletedAt == null) tr,
      ]);
      final String? coverTrack = album.coverTrackUid;
      final String? embedded = coverTrack == null
          ? null
          : (await db.getMusicTrack(coverTrack))?.path;
      if (!navigator.mounted) return;
      unawaited(
        navigator.push<void>(
          adaptivePageRoute<void>(
            context: navigator.context,
            builder: (_) => MusicAlbumPage(
              album: album,
              tracks: tracks,
              embeddedCoverPath: embedded,
            ),
          ),
        ),
      );
  }
}
