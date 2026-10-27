import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/media.dart';
import 'package:fushi/src/media/media_cover_source.dart';
import 'package:fushi/src/media/video/video_library_overview.dart'
    show formatVideoPosition;
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/media/music/music_output_backend.dart'
    show MusicPlayItem;
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/module_registry.dart' show moduleOfHomeTab;
import 'package:fushi/src/pages/implementations/fushi_web_browser_page.dart'
    show fushiWebBrowserRoute, openFushiWebBrowser;
import 'package:fushi/src/pages/implementations/music/music_cover.dart'
    show MusicEmbeddedCoverCache;
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_recent_destinations.dart';
import 'package:fushi/src/settings/settings_schema.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/web_browser/data/web_browser_store.dart';
import 'package:fushi/src/web_browser/data/web_browser_store_provider.dart';
import 'package:fushi/src/web_browser/web_browser_prefs.dart'
    show webBrowserRestoreTabs;
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
        FushiDatabase,
        MediaCollectionRow,
        MediaKind,
        MusicAlbumRow,
        MusicTrackRow,
        VideoBookRow,
        VideoMetadataImageRow,
        VideoMetadataWorkRow,
        VideoDownloadJobLifecycle,
        VideoDownloadJobRow;
import 'package:fushi_engine/srs/srs_db_store.dart' show SrsDeckSummary;
import 'package:fushi_engine/media/collections/shelf_sort.dart'
    show ShelfReadStatus, classifyShelfReadStatus;
import 'package:fushi_dictionary/fushi_dictionary.dart'
    show Dictionary, DictionarySearchResult, JapaneseLanguage;
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:material_ui/material_ui.dart';
import 'package:transparent_image/transparent_image.dart';

/// 速览卡最多列几个「最近」条目。
const int _kPeekRecentCount = 4;

/// 列表式速览（查词 / 网页 / 设置）最多列几行：一行只有一行字高，比封面排得多。
const int _kPeekListCount = 5;

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
/// 游戏四个库页给「继续」+「最近」；复习给「继续」= 第一个还有待复习卡的顶层
/// 牌组（与首页复习条「开始复习」同一个 [SrsDeckListData.firstRootWithWork]）、
/// 「最近」= 其余顶层牌组；浏览给下载任务：「继续」= 最近更新的进行中任务（带
/// 进度），「最近」= 其余最近更新的任务（2026-10-25 用户「侧边栏预览给复习和
/// 浏览加一下」）。2026-10-26 用户「所有的都支持一下」补齐其余目的地：首页 =
/// 书 / 漫画 / 视频 / 游戏按最近时刻混排（与 dashboard「继续」同口径，关掉的
/// 模块不进）；音乐 = 正在播放 + 最近播放（按专辑折叠）；查词 = 查词历史（没有
/// 历史时列已装词典）；网页 = 上次的标签页 + 浏览历史；设置 = 最近打开的分类
/// （还没打开过时列前几个分类）。
///
/// 口径对齐首页 dashboard 的「继续」区：书按 `reader_positions.updatedAt` 排、
/// 只把「在读」的书当继续项（与首页同一判据 [classifyShelfReadStatus]）；视频按最后播放时刻；
/// 游戏按最后游玩时刻、没有完成度。打开方式也与首页同：书 / 漫画进阅读器、
/// 视频进播放页、游戏切到游戏库（首页同样不直接启动游戏）。
AdaptiveNavPeek homeNavPeekFor(
  HomeTab tab, {
  required WidgetRef ref,
  required AppModel appModel,
  required BuildContext Function() contextOf,
  required VideoBookRepository Function() videoRepo,
  required ValueChanged<HomeTab> goToTab,
  required VoidCallback openDownloads,
}) {
  switch (tab) {
    case HomeTab.home:
      return AdaptiveNavPeek(
        load: () => _loadHome(
          ref: ref,
          appModel: appModel,
          contextOf: contextOf,
          videoRepo: videoRepo(),
          goToTab: goToTab,
        ),
      );
    case HomeTab.books:
    case HomeTab.manga:
      return AdaptiveNavPeek(
        load: () async => (await _loadBooks(
          ref: ref,
          appModel: appModel,
          manga: tab == HomeTab.manga,
        )).toData(),
      );
    case HomeTab.video:
      return AdaptiveNavPeek(
        load: () async => (await _loadVideos(
          appModel: appModel,
          repo: videoRepo(),
          contextOf: contextOf,
        )).toData(),
      );
    case HomeTab.games:
      return AdaptiveNavPeek(
        load: () async => (await _loadGames(
          appModel: appModel,
          open: () => goToTab(HomeTab.games),
        )).toData(),
      );
    case HomeTab.music:
      return AdaptiveNavPeek(
        load: () => _loadMusic(
          appModel: appModel,
          openMusic: () => goToTab(HomeTab.music),
        ),
      );
    case HomeTab.dictionaries:
      return AdaptiveNavPeek(
        load: () => _loadDictionary(
          appModel: appModel,
          openDictionary: () => goToTab(HomeTab.dictionaries),
        ),
      );
    case HomeTab.web:
      return AdaptiveNavPeek(
        load: () =>
            _loadWeb(ref: ref, appModel: appModel, contextOf: contextOf),
      );
    case HomeTab.settings:
      return AdaptiveNavPeek(
        load: () => _loadSettings(
          ref: ref,
          appModel: appModel,
          contextOf: contextOf,
          openSettings: () => goToTab(HomeTab.settings),
        ),
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
  }
}

Future<NavPeekFeed> _loadBooks({
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
  NavPeekTimed timed(NavPeekUnit<MediaItem> unit) => (
    at: recentOf(unit.item),
    entry: entryOf(unit.item, collection: unit.collectionName),
  );
  return NavPeekFeed(
    resume: resume == null ? null : timed(resume),
    recent: units
        .where((NavPeekUnit<MediaItem> unit) => !identical(unit, resume))
        .take(_kPeekRecentCount)
        .map(timed)
        .toList(),
  );
}

Future<NavPeekFeed> _loadVideos({
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
  NavPeekTimed unitEntry(NavPeekUnit<VideoBookRow> unit) => (
    at: unit.item.lastPlayedAt ?? 0,
    entry: entryOf(
      unit.item,
      collection: unit.collectionName,
      collectionCover: unit.collectionId == null
          ? null
          : covers[unit.collectionId],
    ),
  );
  return NavPeekFeed(
    resume: shown.isEmpty ? null : unitEntry(shown.first),
    recent: shown.skip(1).map(unitEntry).toList(),
  );
}

Future<NavPeekFeed> _loadGames({
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
  NavPeekTimed entryOf(GalgameEntry g) {
    final String? cover = g.coverPath;
    return (
      at: g.lastPlayedMs,
      entry: AdaptiveNavPeekEntry(
        title: g.displayName,
        cover: cover == null || cover.isEmpty || !File(cover).existsSync()
            ? null
            : resolveMediaCoverImage(kind: MediaKind.game, localPath: cover),
        onOpen: open,
      ),
    );
  }

  return NavPeekFeed(
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

/// 一个速览条目连同它的最近时刻（首页把各模块按时刻混排要用）。
typedef NavPeekTimed = ({int at, AdaptiveNavPeekEntry entry});

/// 单个库模块的速览结果（带时刻；[toData] 给该模块自己的卡）。
class NavPeekFeed {
  const NavPeekFeed({this.resume, this.recent = const <NavPeekTimed>[]});

  final NavPeekTimed? resume;
  final List<NavPeekTimed> recent;

  AdaptiveNavPeekData toData() => AdaptiveNavPeekData(
    resume: resume?.entry,
    recent: <AdaptiveNavPeekEntry>[
      for (final NavPeekTimed e in recent) e.entry,
    ],
  );
}

/// 把各模块的速览混成首页那一张：「继续」= 各模块继续项里最近的那个，「最近」=
/// 其余条目（含别的模块的继续项）按时刻倒序取前 [_kPeekRecentCount] 个。
AdaptiveNavPeekData mergeNavPeekFeeds(List<NavPeekFeed> feeds) {
  final List<NavPeekTimed> resumes = <NavPeekTimed>[
    for (final NavPeekFeed f in feeds)
      if (f.resume case final NavPeekTimed r) r,
  ]..sort((NavPeekTimed a, NavPeekTimed b) => b.at - a.at);
  final NavPeekTimed? resume = resumes.firstOrNull;
  final List<NavPeekTimed> rest = <NavPeekTimed>[
    ...resumes.skip(1),
    for (final NavPeekFeed f in feeds) ...f.recent,
  ]..sort((NavPeekTimed a, NavPeekTimed b) => b.at - a.at);
  return AdaptiveNavPeekData(
    resume: resume?.entry,
    recent: <AdaptiveNavPeekEntry>[
      for (final NavPeekTimed e in rest.take(_kPeekRecentCount)) e.entry,
    ],
  );
}

Future<AdaptiveNavPeekData> _loadHome({
  required WidgetRef ref,
  required AppModel appModel,
  required BuildContext Function() contextOf,
  required VideoBookRepository videoRepo,
  required ValueChanged<HomeTab> goToTab,
}) async {
  bool enabled(HomeTab tab) {
    final ModuleId? module = moduleOfHomeTab(tab);
    return module == null || appModel.moduleVisibility.isEnabled(module);
  }

  final List<NavPeekFeed> feeds = await Future.wait(<Future<NavPeekFeed>>[
    if (enabled(HomeTab.books))
      _loadBooks(ref: ref, appModel: appModel, manga: false),
    if (enabled(HomeTab.manga))
      _loadBooks(ref: ref, appModel: appModel, manga: true),
    if (enabled(HomeTab.video))
      _loadVideos(appModel: appModel, repo: videoRepo, contextOf: contextOf),
    if (enabled(HomeTab.games))
      _loadGames(appModel: appModel, open: () => goToTab(HomeTab.games)),
  ]);
  return mergeNavPeekFeeds(feeds);
}

/// 音乐：「继续」= 正在播放的曲目（点了切到音乐库，播放条在那里）；没在播时
/// 是最近播放的那张专辑（点了从那首接着整张播）。「最近」= 其余最近播放过的
/// 专辑（同一张专辑只占一格，由最近播的那首代表）。
Future<AdaptiveNavPeekData> _loadMusic({
  required AppModel appModel,
  required VoidCallback openMusic,
}) async {
  final FushiDatabase db = appModel.database;
  final MusicPlayerEngine engine = appModel.musicSession.engine;
  final List<MusicTrackRow> played = await db.listRecentlyPlayedMusicTracks(
    limit: 30,
  );
  final Map<String, MusicAlbumRow?> albums = <String, MusicAlbumRow?>{};
  Future<MusicAlbumRow?> albumOf(String? uid) async {
    if (uid == null) return null;
    if (albums.containsKey(uid)) return albums[uid];
    return albums[uid] = await db.getMusicAlbum(uid);
  }

  Future<void> playFrom(MusicTrackRow track, MusicAlbumRow? album) async {
    final String? uid = track.albumUid;
    final List<MusicTrackRow> tracks = uid == null
        ? <MusicTrackRow>[track]
        : sortAlbumTracks(await db.listMusicTracks(albumUid: uid));
    final int index = tracks.indexWhere(
      (MusicTrackRow t) => t.trackUid == track.trackUid,
    );
    await engine.playQueue(
      <MusicPlayItem>[
        for (final MusicTrackRow t in tracks) musicPlayItemOf(t, album: album),
      ],
      startIndex: index < 0 ? 0 : index,
      context: uid == null ? MusicQueueContext.mixed : MusicQueueContext.album,
    );
  }

  Future<AdaptiveNavPeekEntry> entryOf(MusicTrackRow track) async {
    final MusicAlbumRow? album = await albumOf(track.albumUid);
    return AdaptiveNavPeekEntry(
      title: album?.title ?? track.title,
      cover: await _musicCover(db, track: track, album: album),
      subtitle: album == null ? track.artistCredit : track.title,
      onOpen: () => unawaited(playFrom(track, album)),
    );
  }

  String unitKey(MusicTrackRow t) => t.albumUid ?? t.trackUid;
  final Set<String> seen = <String>{};
  final List<MusicTrackRow> units = <MusicTrackRow>[
    for (final MusicTrackRow t in played)
      if (seen.add(unitKey(t))) t,
  ];

  final MusicPlayItem? current = engine.current;
  AdaptiveNavPeekEntry? resume;
  if (current != null) {
    final MusicTrackRow? track = await db.getMusicTrack(current.trackUid);
    if (track != null) {
      final MusicAlbumRow? album = await albumOf(track.albumUid);
      resume = AdaptiveNavPeekEntry(
        title: track.title,
        cover: await _musicCover(db, track: track, album: album),
        subtitle: <String>[
          if (track.artistCredit ?? album?.albumArtistCredit
              case final String artist)
            artist,
          ?album?.title,
        ].join(' · '),
        onOpen: openMusic,
      );
      units.removeWhere((MusicTrackRow t) => unitKey(t) == unitKey(track));
    }
  } else if (units.isNotEmpty) {
    resume = await entryOf(units.removeAt(0));
  }
  return AdaptiveNavPeekData(
    resume: resume,
    resumeLabel: current == null ? null : t.music_now_playing,
    recent: <AdaptiveNavPeekEntry>[
      for (final MusicTrackRow track in units.take(_kPeekRecentCount))
        await entryOf(track),
    ],
  );
}

/// 曲目 / 专辑封面，顺序与 `MusicCover` 一致：专辑目录封面（本地文件或服务器
/// 地址）→ 内嵌封面（专辑指定的那首，否则这首自己）→ null。
Future<ImageProvider?> _musicCover(
  FushiDatabase db, {
  required MusicTrackRow track,
  required MusicAlbumRow? album,
}) async {
  final String? file = album?.coverPath;
  if (file != null && file.isNotEmpty) {
    if (file.startsWith('http://') || file.startsWith('https://')) {
      return AppHttpImage(file);
    }
    if (File(file).existsSync()) return resizedFileImage(File(file));
  }
  String? embeddedPath = track.hasEmbeddedCover ? track.path : null;
  final String? coverTrackUid = album?.coverTrackUid;
  if (coverTrackUid != null && coverTrackUid != track.trackUid) {
    embeddedPath =
        (await db.getMusicTrack(coverTrackUid))?.path ?? embeddedPath;
  }
  if (embeddedPath == null) return null;
  final Uint8List? bytes = await MusicEmbeddedCoverCache.instance.load(
    embeddedPath,
  );
  return bytes == null ? null : MemoryImage(bytes);
}

/// 查词：最近查过的词（点了直接在查词页查这个词，与悬浮字幕点词同一条显式查词
/// 路径）。还没查过词时列已装的词典，点了打开查词页。
Future<AdaptiveNavPeekData> _loadDictionary({
  required AppModel appModel,
  required VoidCallback openDictionary,
}) async {
  final List<DictionarySearchResult> history = appModel.dictionaryHistory;
  if (history.isNotEmpty) {
    final Set<String> seen = <String>{};
    final List<DictionarySearchResult> latest = <DictionarySearchResult>[
      for (final DictionarySearchResult r in history.reversed)
        if (seen.add(r.searchTerm)) r,
    ];
    return AdaptiveNavPeekData(
      listLayout: true,
      recentLabel: t.lookup_history_title,
      recent: <AdaptiveNavPeekEntry>[
        for (final DictionarySearchResult r in latest.take(_kPeekListCount))
          AdaptiveNavPeekEntry(
            title: r.searchTerm,
            icon: FushiIcons.history,
            subtitle: switch (r.entries.firstOrNull?.reading) {
              final String reading
                  when reading.isNotEmpty && reading != r.searchTerm =>
                reading,
              _ => null,
            },
            onOpen: () {
              DesktopLookupService.instance.triggerLookup(r.searchTerm);
              appModel.requestHomeDictionaryTab();
            },
          ),
      ],
    );
  }
  final Map<String, String> names = appModel.dictRepo.displayNameOverrides;
  return AdaptiveNavPeekData(
    listLayout: true,
    recentLabel: t.nav_peek_dictionaries,
    recent: <AdaptiveNavPeekEntry>[
      for (final Dictionary d
          in appModel.dictRepo.termDictionaries
              .where((Dictionary d) => !d.isHidden(JapaneseLanguage.instance))
              .take(_kPeekListCount))
        AdaptiveNavPeekEntry(
          title: names[d.name] ?? d.name,
          onOpen: openDictionary,
        ),
    ],
  );
}

/// 网页：「继续」= 上次的标签页会话（点了打开浏览器按会话恢复、落在上次的前台
/// 标签上——不是再开一个同地址的新标签）；「最近」= 浏览历史。
Future<AdaptiveNavPeekData> _loadWeb({
  required WidgetRef ref,
  required AppModel appModel,
  required BuildContext Function() contextOf,
}) async {
  final WebBrowserStore store = ref.read(webBrowserStoreProvider);
  final WebBrowserSession? session = webBrowserRestoreTabs(appModel.prefsRepo)
      ? await store.loadSession()
      : null;
  final List<WebBrowserSessionTab> tabs =
      session?.tabs ?? const <WebBrowserSessionTab>[];
  final WebBrowserSessionTab? active =
      tabs
          .where((WebBrowserSessionTab e) => e.id == session?.activeTabId)
          .firstOrNull ??
      tabs.firstOrNull;
  String titleOf(String title, Uri url) =>
      title.trim().isNotEmpty ? title.trim() : url.host;
  final Set<String> seen = <String>{?active?.url.toString()};
  final List<WebBrowserHistoryEntry> history = <WebBrowserHistoryEntry>[
    for (final WebBrowserHistoryEntry h in await store.history(limit: 20))
      if (seen.add(h.url.toString())) h,
  ];
  return AdaptiveNavPeekData(
    listLayout: true,
    recentLabel: t.web_browser_history_title,
    resume: active == null
        ? null
        : AdaptiveNavPeekEntry(
            title: titleOf(active.title, active.url),
            icon: FushiIcons.tab,
            subtitle: active.url.host,
            onOpen: () {
              final BuildContext context = contextOf();
              if (!context.mounted) return;
              unawaited(
                Navigator.of(
                  context,
                ).push<void>(fushiWebBrowserRoute(context, '')),
              );
            },
          ),
    recent: <AdaptiveNavPeekEntry>[
      for (final WebBrowserHistoryEntry h in history.take(_kPeekListCount))
        AdaptiveNavPeekEntry(
          title: titleOf(h.title, h.url),
          icon: FushiIcons.history,
          subtitle: h.url.host,
          onOpen: () {
            final BuildContext context = contextOf();
            if (!context.mounted) return;
            unawaited(openFushiWebBrowser(context, h.url));
          },
        ),
    ],
  );
}

/// 设置：最近打开的一级分类（设备本地记录）；还没打开过时列前几个分类。点了
/// 切到设置并打开该分类。
Future<AdaptiveNavPeekData> _loadSettings({
  required WidgetRef ref,
  required AppModel appModel,
  required BuildContext Function() contextOf,
  required VoidCallback openSettings,
}) async {
  final BuildContext context = contextOf();
  if (!context.mounted) return const AdaptiveNavPeekData();
  final SettingsContext settingsContext = SettingsContext(
    context: context,
    appModel: appModel,
    ref: ref,
    readerSource: ReaderFushiSource.instance,
    refresh: () {},
  );
  final List<SettingsDestination> visible = buildSettingsSchema(
    settingsContext,
  ).where((SettingsDestination d) => d.isVisible(settingsContext)).toList();
  final Map<SettingsDestinationId, SettingsDestination> byId =
      <SettingsDestinationId, SettingsDestination>{
        for (final SettingsDestination d in visible) d.id: d,
      };
  final List<SettingsDestination> recent = <SettingsDestination>[
    for (final SettingsDestinationId id in readSettingsRecentDestinations(
      appModel.prefsRepo,
    ))
      ?byId[id],
  ];
  final List<SettingsDestination> shown = (recent.isEmpty ? visible : recent)
      .take(_kPeekListCount)
      .toList();
  return AdaptiveNavPeekData(
    listLayout: true,
    recentLabel: recent.isEmpty ? t.nav_peek_categories : null,
    recent: <AdaptiveNavPeekEntry>[
      for (final SettingsDestination d in shown)
        AdaptiveNavPeekEntry(
          title: d.title,
          icon: d.icon,
          onOpen: () {
            openSettings();
            settingsDestinationRequest.value = d.id;
          },
        ),
    ],
  );
}
