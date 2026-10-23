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
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:material_ui/material_ui.dart';

/// 打开作品图谱另一端在本机的条目：各模块已有的那个出口，不另起页面。
///
/// - 视频合集 → 合集详情页（与「相关作品」打开已绑定合集同一形态）；
/// - 单个视频 → 播放器（属于合集就作为合集一集打开，与统计页 / ctl 同一口径）；
/// - 书 / 有声书 → 漫画进作品页，其余与书架点卡同一条 [AppModel.openMedia]；
/// - 游戏 → 游戏详情页；
/// - 音乐 → 音乐模块落地前没有本地条目（区块里恒为「未入库」灰卡，到不了这里）。
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
    case MediaLinkKind.musicAlbum:
    case MediaLinkKind.musicTrack:
      return;
  }
}
