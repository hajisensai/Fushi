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
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:fushi/src/utils/cover_image.dart' show resizedFileImage;
import 'package:fushi/utils.dart' show adaptivePageRoute, t;
import 'package:fushi_core/fushi_core.dart'
    show
        MediaCollectionRow,
        MediaKind,
        VideoBookRow,
        VideoMetadataImageRow,
        VideoMetadataWorkRow,
        VideoDownloadJobLifecycle,
        VideoDownloadJobRow;
import 'package:fushi_engine/srs/srs_db_store.dart' show SrsDeckSummary;
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
  HomeTab.browse => MaterialShapes.sunny,
  HomeTab.dictionaries => MaterialShapes.gem,
  HomeTab.srs => MaterialShapes.pentagon,
  HomeTab.games => MaterialShapes.cookie7Sided,
  HomeTab.web => MaterialShapes.flower,
  HomeTab.settings => MaterialShapes.cookie12Sided,
};

/// 首页侧栏悬停速览卡的数据源（[AdaptiveNavItem.peek]）：书 / 漫画 / 视频 /
/// 游戏四个库页给「继续」+「最近」；复习给「继续」= 第一个还有待复习卡的顶层
/// 牌组（与首页复习条「开始复习」同一个 [SrsDeckListData.firstRootWithWork]）、
/// 「最近」= 其余顶层牌组；浏览给下载任务：「继续」= 最近更新的进行中任务（带
/// 进度），「最近」= 其余最近更新的任务（2026-10-25 用户「侧边栏预览给复习和
/// 浏览加一下」）。其余目的地没有速览（null，名称走 tooltip）。
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
  required VoidCallback openDownloads,
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
        load: () => _loadVideos(
          appModel: appModel,
          repo: videoRepo(),
          contextOf: contextOf,
        ),
      );
    case HomeTab.games:
      return AdaptiveNavPeek(
        load: () =>
            _loadGames(appModel: appModel, open: () => goToTab(HomeTab.games)),
      );
    case HomeTab.srs:
      return AdaptiveNavPeek(
        load: () => _loadSrsDecks(
          ref: ref,
          contextOf: contextOf,
          openDecks: () => goToTab(HomeTab.srs),
        ),
      );
    case HomeTab.browse:
      return AdaptiveNavPeek(
        load: () =>
            _loadDownloads(appModel: appModel, openDownloads: openDownloads),
      );
    case HomeTab.home:
    case HomeTab.dictionaries:
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

  final _NavPeekCollections collections = await _loadCollections(appModel);
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
  AdaptiveNavPeekEntry entryOf(MediaItem item, {String? collection}) {
    final String itemTitle = ReaderFushiSource.instance
        .getDisplayTitleFromMediaItem(item);
    final ImageProvider image = ReaderFushiSource.instance
        .getDisplayThumbnailFromMediaItem(appModel: appModel, item: item);
    final bool noCover =
        image is MemoryImage && identical(image.bytes, kTransparentImage);
    final double? progress = item.duration > 0
        ? (item.position / item.duration).clamp(0.0, 1.0)
        : null;
    return AdaptiveNavPeekEntry(
      title: collection ?? itemTitle,
      cover: noCover ? null : image,
      progress: progress,
      subtitle: _peekSubtitle(
        collection == null ? null : itemTitle,
        progress == null ? null : '${(progress * 100).round()}%',
      ),
      onOpen: () => unawaited(
        appModel.openMedia(
          ref: ref,
          mediaSource: item.getMediaSource(appModel: appModel),
          item: item,
        ),
      ),
    );
  }

  // 与书架同一份折叠：同一系列 / 合集只占一项，由其最近读过的那本代表
  // （2026-10-25 用户「侧栏预览系列和合集没正确显示」：此前逐本列，同一系列
  // 的几卷各占一格、标题是单卷名）。合集身份键与书架同为 `epub|<uid>`。
  final List<NavPeekUnit<MediaItem>> units = foldNavPeekByCollection<MediaItem>(
    recentFirst: read,
    compositeKeyOf: (MediaItem item) {
      final String key = keyOf(item);
      return MediaKind.epub.compositeKey(uidByKey[key] ?? key);
    },
    primaryCollectionIdByEntry: collections.primaryByEntry,
    collectionsById: collections.byId,
  );
  final NavPeekUnit<MediaItem>? resume = units
      .where(
        (NavPeekUnit<MediaItem> unit) =>
            classifyShelfReadStatus(
              completed: completed.contains(keyOf(unit.item)),
              position: unit.item.position,
              duration: unit.item.duration,
            ) ==
            ShelfReadStatus.reading,
      )
      .firstOrNull;
  return AdaptiveNavPeekData(
    resume: resume == null
        ? null
        : entryOf(resume.item, collection: resume.collectionName),
    recent: units
        .where((NavPeekUnit<MediaItem> unit) => !identical(unit, resume))
        .take(_kPeekRecentCount)
        .map(
          (NavPeekUnit<MediaItem> unit) =>
              entryOf(unit.item, collection: unit.collectionName),
        )
        .toList(),
  );
}

Future<AdaptiveNavPeekData> _loadVideos({
  required AppModel appModel,
  required VideoBookRepository repo,
  required BuildContext Function() contextOf,
}) async {
  final _NavPeekCollections collections = await _loadCollections(appModel);
  final List<VideoBookRow> rows =
      (await repo.listForShelf())
          .where((VideoBookRow v) => (v.lastPlayedAt ?? 0) > 0)
          .toList()
        ..sort(
          (VideoBookRow a, VideoBookRow b) =>
              (b.lastPlayedAt ?? 0) - (a.lastPlayedAt ?? 0),
        );
  AdaptiveNavPeekEntry entryOf(
    VideoBookRow v, {
    String? collection,
    ImageProvider? collectionCover,
  }) {
    final String? cover = v.coverPath;
    return AdaptiveNavPeekEntry(
      title: collection ?? v.title,
      cover:
          collectionCover ??
          (cover == null || cover.isEmpty || !File(cover).existsSync()
              ? null
              : resolveMediaCoverImage(
                  kind: MediaKind.video,
                  localPath: cover,
                )),
      subtitle: _peekSubtitle(
        collection == null ? null : v.title,
        v.lastPositionMs > 0 ? formatVideoPosition(v.lastPositionMs) : null,
      ),
      onOpen: () {
        final BuildContext context = contextOf();
        if (!context.mounted) return;
        unawaited(
          openLocalVideoBook(context: context, repo: repo, bookUid: v.bookUid),
        );
      },
    );
  }

  // 多季 / 合集与视频库同一份折叠（身份键 `video|<bookUid>`）。
  final List<NavPeekUnit<VideoBookRow>> units =
      foldNavPeekByCollection<VideoBookRow>(
        recentFirst: rows,
        compositeKeyOf: (VideoBookRow v) =>
            MediaKind.video.compositeKey(v.bookUid),
        primaryCollectionIdByEntry: collections.primaryByEntry,
        collectionsById: collections.byId,
      );
  // 合集项用合集自己的封面（与视频库合集卡同一条链），不是最近那一集的抽帧
  // 截图——否则一排都是分集画面，认不出是哪部剧（2026-10-25 用户「视频没有
  // 看到系列」）。只查要显示的那几个合集。
  final List<NavPeekUnit<VideoBookRow>> shown = units
      .take(_kPeekRecentCount + 1)
      .toList();
  final Map<int, ImageProvider> covers = <int, ImageProvider>{};
  for (final NavPeekUnit<VideoBookRow> unit in shown) {
    final int? cid = unit.collectionId;
    if (cid == null || covers.containsKey(cid)) continue;
    final ImageProvider? cover = await _videoCollectionCover(
      appModel,
      collections.byId[cid]!,
    );
    if (cover != null) covers[cid] = cover;
  }
  AdaptiveNavPeekEntry unitEntry(NavPeekUnit<VideoBookRow> unit) => entryOf(
    unit.item,
    collection: unit.collectionName,
    collectionCover: unit.collectionId == null
        ? null
        : covers[unit.collectionId],
  );
  return AdaptiveNavPeekData(
    resume: shown.isEmpty ? null : unitEntry(shown.first),
    recent: shown.skip(1).map(unitEntry).toList(),
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

/// 复习速览的副行：「新卡 3 · 学习中 1 · 到期 20」，只列非零的计数；三个都为
/// 零（今天已复习完）时为 null。口径与牌组列表 / 首页复习条同一份计数。
String? srsNavPeekCountsLabel({
  required int newCount,
  required int learnCount,
  required int reviewCount,
}) {
  final List<String> parts = <String>[
    if (newCount > 0) '${t.srs_count_new} $newCount',
    if (learnCount > 0) '${t.srs_count_learn} $learnCount',
    if (reviewCount > 0) '${t.srs_count_review} $reviewCount',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

Future<AdaptiveNavPeekData> _loadSrsDecks({
  required WidgetRef ref,
  required BuildContext Function() contextOf,
  required VoidCallback openDecks,
}) async {
  final SrsDeckListData? data = await ref.read(srsDeckListProvider.future);
  if (data == null) return const AdaptiveNavPeekData();
  // provider 已按牌组列表的口径藏掉空的默认牌组（[srsVisibleDecks]）。
  final List<SrsDeckSummary> roots = data.decks
      .where((SrsDeckSummary d) => d.depth == 0)
      .toList();
  AdaptiveNavPeekEntry entryOf(SrsDeckSummary deck) {
    final bool hasWork = deck.newCount + deck.learnCount + deck.reviewCount > 0;
    return AdaptiveNavPeekEntry(
      title: deck.fullName,
      subtitle:
          srsNavPeekCountsLabel(
            newCount: deck.newCount,
            learnCount: deck.learnCount,
            reviewCount: deck.reviewCount,
          ) ??
          t.home_srs_panel_done,
      // 有待复习的卡就直接进这个牌组的复习页（同首页复习条）；今天已复习完
      // 的牌组进复习里没卡可看，改为打开牌组列表。
      onOpen: hasWork
          ? () => srsRunLogged('HomeNavPeek.srsReview', () async {
              final BuildContext context = contextOf();
              if (!context.mounted) return;
              await Navigator.of(context).push<void>(
                adaptivePageRoute<void>(
                  context: context,
                  builder: (BuildContext context) => SrsReviewPage(
                    deckId: deck.deck.id,
                    deckName: deck.fullName,
                  ),
                ),
              );
              if (context.mounted) bumpSrsRevision(ref);
            })
          : openDecks,
    );
  }

  final SrsDeckSummary? resume = data.firstRootWithWork;
  // 牌组没有封面：列表式（名称 + 今日计数），「继续」写成「开始复习」，
  // 其余牌组列在「牌组」下（2026-10-25 用户「复习不知道显示的是什么，要显示
  // 牌组之类的」）。
  return AdaptiveNavPeekData(
    listLayout: true,
    resumeLabel: t.home_srs_panel_start,
    recentLabel: t.nav_peek_decks,
    resume: resume == null ? null : entryOf(resume),
    recent: roots
        .where((SrsDeckSummary d) => d.deck.id != resume?.deck.id)
        .take(_kPeekRecentCount)
        .map(entryOf)
        .toList(),
  );
}

Future<AdaptiveNavPeekData> _loadDownloads({
  required AppModel appModel,
  required VoidCallback openDownloads,
}) async {
  final List<VideoDownloadJobRow> jobs =
      (await appModel.database.getVideoDownloadJobs()).toList()..sort(
        (VideoDownloadJobRow a, VideoDownloadJobRow b) =>
            b.updatedAt - a.updatedAt,
      );
  AdaptiveNavPeekEntry entryOf(VideoDownloadJobRow job) {
    final String? cover = job.coverUrl;
    final double progress = job.lifecycle == VideoDownloadJobLifecycle.completed
        ? 1
        : job.stageProgress.clamp(0.0, 1.0).toDouble();
    return AdaptiveNavPeekEntry(
      title: job.title,
      cover: cover == null || cover.isEmpty ? null : AppHttpImage(cover),
      progress: progress,
      subtitle: '${(progress * 100).round()}%',
      onOpen: openDownloads,
    );
  }

  final VideoDownloadJobRow? resume = jobs
      .where(
        (VideoDownloadJobRow j) =>
            j.lifecycle == VideoDownloadJobLifecycle.active,
      )
      .firstOrNull;
  return AdaptiveNavPeekData(
    resume: resume == null ? null : entryOf(resume),
    recent: jobs
        .where((VideoDownloadJobRow j) => !identical(j, resume))
        .take(_kPeekRecentCount)
        .map(entryOf)
        .toList(),
  );
}

/// 速览里的一个展示单元：散条目，或一个合集（由它最近的那个成员 [item] 代表，
/// [collectionName] 是合集名）。
@immutable
class NavPeekUnit<T> {
  const NavPeekUnit({
    required this.item,
    this.collectionId,
    this.collectionName,
  });

  final T item;

  /// null = 散条目。
  final int? collectionId;
  final String? collectionName;
}

/// 把按最近排好的 [recentFirst] 按所属合集折叠：同一合集只留最靠前（最近）的
/// 成员，单元顺序 = 各单元最近成员的出现顺序。归属判据与库页折叠同一份
/// （[primaryCollectionIdByEntry] 的主折叠合集；合集已删的孤儿引用退回散条目）。
List<NavPeekUnit<T>> foldNavPeekByCollection<T>({
  required List<T> recentFirst,
  required String Function(T item) compositeKeyOf,
  required Map<String, int> primaryCollectionIdByEntry,
  required Map<int, MediaCollectionRow> collectionsById,
}) {
  final Set<int> seen = <int>{};
  final List<NavPeekUnit<T>> units = <NavPeekUnit<T>>[];
  for (final T item in recentFirst) {
    final int? cid = primaryCollectionIdByEntry[compositeKeyOf(item)];
    final MediaCollectionRow? collection = cid == null
        ? null
        : collectionsById[cid];
    if (collection == null) {
      units.add(NavPeekUnit<T>(item: item));
    } else if (seen.add(collection.id)) {
      units.add(
        NavPeekUnit<T>(
          item: item,
          collectionId: collection.id,
          collectionName: collection.name,
        ),
      );
    }
  }
  return units;
}

/// 合集速览的副行：「第 3 卷标题 · 42%」；缺哪段就不拼哪段。
String? _peekSubtitle(String? member, String? progress) {
  final List<String> parts = <String>[
    if (member != null) member,
    if (progress != null) progress,
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// 速览折叠用的合集映射（一次读两张表）。
class _NavPeekCollections {
  const _NavPeekCollections({required this.byId, required this.primaryByEntry});

  final Map<int, MediaCollectionRow> byId;
  final Map<String, int> primaryByEntry;
}

Future<_NavPeekCollections> _loadCollections(AppModel appModel) async {
  final List<MediaCollectionRow> rows = await appModel.database
      .getAllMediaCollections();
  return _NavPeekCollections(
    byId: <int, MediaCollectionRow>{
      for (final MediaCollectionRow c in rows) c.id: c,
    },
    primaryByEntry: await appModel.database.getPrimaryCollectionIdByEntry(),
  );
}

/// 视频合集的封面，顺序与视频库合集卡一致：合集自己的封面文件（手选 / 刮削 /
/// 下载导入写的 `cover_path`）→ 刮削作品的海报（cover / poster，本地文件优先、
/// 没有落盘就走远端地址）→ null（调用方退回成员封面）。
Future<ImageProvider?> _videoCollectionCover(
  AppModel appModel,
  MediaCollectionRow collection,
) async {
  final String? own = collection.coverPath;
  if (own != null && own.isNotEmpty && File(own).existsSync()) {
    return resizedFileImage(File(own));
  }
  final VideoMetadataWorkRow? work = await appModel.database
      .resolveVideoMetadataWorkForCollection(collection.id);
  if (work == null) return null;
  final List<VideoMetadataImageRow> images =
      (await appModel.database.getVideoMetadataImages(workId: work.id)).toList()
        ..sort(
          (VideoMetadataImageRow a, VideoMetadataImageRow b) =>
              a.position.compareTo(b.position),
        );
  for (final String kind in const <String>['cover', 'poster']) {
    for (final VideoMetadataImageRow row in images) {
      if (row.kind != kind) continue;
      final String? local = row.localPath;
      if (local != null && local.isNotEmpty && File(local).existsSync()) {
        return resizedFileImage(File(local));
      }
      if (row.remoteUrl.isNotEmpty) return AppCachedHttpImage(row.remoteUrl);
    }
  }
  return null;
}
