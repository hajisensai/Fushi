import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/media.dart';
import 'package:fushi/src/media/media_cover_source.dart';
import 'package:fushi/src/media/video/video_library_overview.dart'
    show formatVideoPosition;
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart'
    show openLocalVideoBook;
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';
import 'package:fushi_core/fushi_core.dart' show MediaKind, VideoBookRow;
import 'package:fushi_engine/media/collections/shelf_sort.dart'
    show ShelfReadStatus, classifyShelfReadStatus;
import 'package:fushi_dictionary/fushi_dictionary.dart' show JapaneseLanguage;
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:material_ui/material_ui.dart';
import 'package:transparent_image/transparent_image.dart';

/// 速览卡最多列几个「最近」条目。
const int _kPeekRecentCount = 4;

/// 首页侧栏每个 [HomeTab] 的 M3E 专属形状（[AdaptiveNavItem.railShape]）：选中时
/// 图标背后由圆形变过来。各模块一个固定形状，看形状就知道在哪。
RoundedPolygon homeNavRailShapeFor(HomeTab tab) => switch (tab) {
  HomeTab.home => MaterialShapes.cookie4Sided,
  HomeTab.books => MaterialShapes.cookie9Sided,
  HomeTab.manga => MaterialShapes.clover4Leaf,
  HomeTab.video => MaterialShapes.softBurst,
  HomeTab.music => MaterialShapes.puffyDiamond,
  HomeTab.browse => MaterialShapes.sunny,
  HomeTab.dictionaries => MaterialShapes.gem,
  HomeTab.srs => MaterialShapes.pentagon,
  HomeTab.games => MaterialShapes.cookie7Sided,
  HomeTab.web => MaterialShapes.flower,
  HomeTab.settings => MaterialShapes.cookie12Sided,
};

/// 首页侧栏悬停速览卡的数据源（[AdaptiveNavItem.peek]）：书 / 漫画 / 视频 /
/// 游戏四个库页给「继续」+「最近」，其余目的地没有速览（null，名称走 tooltip）。
///
/// 口径对齐首页 dashboard 的「继续」区：书按 `reader_positions.updatedAt` 排、
/// 只把「在读」的书当继续项（与首页同一判据 [classifyShelfReadStatus]）；视频按最后播放时刻；
/// 游戏按最后游玩时刻、没有完成度。打开方式也与首页同：书 / 漫画进阅读器、
/// 视频进播放页、游戏切到游戏库（首页同样不直接启动游戏）。
AdaptiveNavPeek? homeNavPeekFor(
  HomeTab tab, {
  required WidgetRef ref,
  required AppModel appModel,
  required BuildContext Function() contextOf,
  required VideoBookRepository Function() videoRepo,
  required ValueChanged<HomeTab> goToTab,
}) {
  switch (tab) {
    case HomeTab.books:
    case HomeTab.manga:
      return AdaptiveNavPeek(
        load: () => _loadBooks(
          ref: ref,
          appModel: appModel,
          manga: tab == HomeTab.manga,
        ),
      );
    case HomeTab.video:
      return AdaptiveNavPeek(
        load: () => _loadVideos(repo: videoRepo(), contextOf: contextOf),
      );
    case HomeTab.games:
      return AdaptiveNavPeek(
        load: () =>
            _loadGames(appModel: appModel, open: () => goToTab(HomeTab.games)),
      );
    case HomeTab.home:
    case HomeTab.music:
    case HomeTab.browse:
    case HomeTab.dictionaries:
    case HomeTab.srs:
    case HomeTab.web:
    case HomeTab.settings:
      return null;
  }
}

Future<AdaptiveNavPeekData> _loadBooks({
  required WidgetRef ref,
  required AppModel appModel,
  required bool manga,
}) async {
  final List<MediaItem> all = await ref.read(
    fushiBooksProvider(JapaneseLanguage.instance).future,
  );
  final Map<String, int> lastReadByUid = await ref.read(
    bookLastReadAtProvider.future,
  );
  final Map<String, String> uidByKey = await ref.read(
    epubBookUidByKeyProvider.future,
  );
  final Set<String> completed = await ref.read(
    completedEpubBookKeysProvider.future,
  );
  String keyOf(MediaItem item) =>
      ReaderFushiSource.parseBookKey(item.mediaIdentifier) ??
      item.mediaIdentifier;
  int recentOf(MediaItem item) {
    final String key = keyOf(item);
    return lastReadByUid[uidByKey[key] ?? key] ?? 0;
  }

  final List<MediaItem> read =
      all
          .where(
            (MediaItem item) =>
                (item.mediaSourceIdentifier == MangaFushiSource.kUniqueKey) ==
                    manga &&
                recentOf(item) > 0,
          )
          .toList()
        ..sort((MediaItem a, MediaItem b) => recentOf(b) - recentOf(a));
  AdaptiveNavPeekEntry entryOf(MediaItem item) {
    final String title = ReaderFushiSource.instance
        .getDisplayTitleFromMediaItem(item);
    final ImageProvider image = ReaderFushiSource.instance
        .getDisplayThumbnailFromMediaItem(appModel: appModel, item: item);
    final bool noCover =
        image is MemoryImage && identical(image.bytes, kTransparentImage);
    final double? progress = item.duration > 0
        ? (item.position / item.duration).clamp(0.0, 1.0)
        : null;
    return AdaptiveNavPeekEntry(
      title: title,
      cover: noCover ? null : image,
      progress: progress,
      subtitle: progress == null ? null : '${(progress * 100).round()}%',
      onOpen: () => unawaited(
        appModel.openMedia(
          ref: ref,
          mediaSource: item.getMediaSource(appModel: appModel),
          item: item,
        ),
      ),
    );
  }

  final MediaItem? resume = read
      .where(
        (MediaItem item) =>
            classifyShelfReadStatus(
              completed: completed.contains(keyOf(item)),
              position: item.position,
              duration: item.duration,
            ) ==
            ShelfReadStatus.reading,
      )
      .firstOrNull;
  return AdaptiveNavPeekData(
    resume: resume == null ? null : entryOf(resume),
    recent: read
        .where((MediaItem item) => !identical(item, resume))
        .take(_kPeekRecentCount)
        .map(entryOf)
        .toList(),
  );
}

Future<AdaptiveNavPeekData> _loadVideos({
  required VideoBookRepository repo,
  required BuildContext Function() contextOf,
}) async {
  final List<VideoBookRow> rows =
      (await repo.listForShelf())
          .where((VideoBookRow v) => (v.lastPlayedAt ?? 0) > 0)
          .toList()
        ..sort(
          (VideoBookRow a, VideoBookRow b) =>
              (b.lastPlayedAt ?? 0) - (a.lastPlayedAt ?? 0),
        );
  AdaptiveNavPeekEntry entryOf(VideoBookRow v) {
    final String? cover = v.coverPath;
    return AdaptiveNavPeekEntry(
      title: v.title,
      cover: cover == null || cover.isEmpty || !File(cover).existsSync()
          ? null
          : resolveMediaCoverImage(kind: MediaKind.video, localPath: cover),
      subtitle: v.lastPositionMs > 0
          ? formatVideoPosition(v.lastPositionMs)
          : null,
      onOpen: () {
        final BuildContext context = contextOf();
        if (!context.mounted) return;
        unawaited(
          openLocalVideoBook(context: context, repo: repo, bookUid: v.bookUid),
        );
      },
    );
  }

  return AdaptiveNavPeekData(
    resume: rows.isEmpty ? null : entryOf(rows.first),
    recent: rows.skip(1).take(_kPeekRecentCount).map(entryOf).toList(),
  );
}

Future<AdaptiveNavPeekData> _loadGames({
  required AppModel appModel,
  required VoidCallback open,
}) async {
  final List<GalgameEntry> games = appModel.galgameRepo.games.isNotEmpty
      ? appModel.galgameRepo.games
      : await appModel.galgameRepo.load();
  final List<GalgameEntry> played =
      games.where((GalgameEntry g) => g.lastPlayedMs > 0).toList()..sort(
        (GalgameEntry a, GalgameEntry b) => b.lastPlayedMs - a.lastPlayedMs,
      );
  AdaptiveNavPeekEntry entryOf(GalgameEntry g) {
    final String? cover = g.coverPath;
    return AdaptiveNavPeekEntry(
      title: g.displayName,
      cover: cover == null || cover.isEmpty || !File(cover).existsSync()
          ? null
          : resolveMediaCoverImage(kind: MediaKind.game, localPath: cover),
      onOpen: open,
    );
  }

  return AdaptiveNavPeekData(
    resume: played.isEmpty ? null : entryOf(played.first),
    recent: played.skip(1).take(_kPeekRecentCount).map(entryOf).toList(),
  );
}
