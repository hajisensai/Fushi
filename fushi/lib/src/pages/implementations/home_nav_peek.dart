import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_render_service.dart'
    show isLocalMangaVolume;
import 'package:fushi/src/media/manga/audio/manga_audio_workbench_entry.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/sources/manga_fushi_source.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/media/media_cover_source.dart';
import 'package:fushi/src/media/nsfw/media_nsfw_cover.dart';
import 'package:fushi/src/media/privacy/media_visibility.dart';
import 'package:fushi_engine/privacy/media_nsfw.dart';
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
import 'package:fushi/src/pages/implementations/fushi_web_browser_page.dart'
    show fushiWebBrowserRoute, openFushiWebBrowser;
import 'package:fushi/src/pages/implementations/music/music_cover.dart'
    show MusicEmbeddedCoverCache;
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_destination_id.dart';
import 'package:fushi/src/settings/settings_recent_destinations.dart';
import 'package:fushi/src/settings/settings_schema.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/web_browser/data/web_browser_store.dart';
import 'package:fushi/src/web_browser/data/web_browser_store_provider.dart';
import 'package:fushi/src/web_browser/web_browser_prefs.dart'
    show webBrowserRestoreTabs;
import 'package:fushi/src/pages/implementations/home_video_page.dart'
    show openLocalVideoBook, openRemoteVideoStream;
import 'package:fushi/src/media/video/video_continue_watching.dart';
import 'package:fushi/src/media/video/video_duration_pref.dart'
    show videoDurationMsFromPref, videoDurationPrefKey;
import 'package:fushi/src/sync/remote_cover_image.dart';
import 'package:fushi/src/sync/remote_video_client.dart'
    show RemoteVideoClient, RemoteVideoSource;
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart'
    show SrsReviewCell;
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi_engine/media/collections/collection_cover.dart'
    show loadCollectionOwnCoverCandidates;
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:fushi/src/utils/cover_image.dart'
    show kLocalCoverDecodePixelWidth, resizedFileImage;
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi_core/fushi_core.dart'
    show
        FushiDatabase,
        MediaCollectionRow,
        MediaKind,
        MusicAlbumRow,
        MusicTrackRow,
        EpubBookRow,
        VideoBookRow,
        VideoMetadataImageRow,
        VideoMetadataWorkRow,
        VideoDownloadJobLifecycle,
        VideoDownloadJobRow,
        VideoFileSpecRow,
        kActivityMediaVideo;
import 'package:fushi_engine/srs/srs_db_store.dart' show SrsDeckSummary;
import 'package:fushi_engine/media/collections/shelf_sort.dart'
    show ShelfReadStatus, classifyShelfReadStatus;
import 'package:fushi_dictionary/fushi_dictionary.dart'
    show Dictionary, DictionarySearchResult, JapaneseLanguage;
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/pages/implementations/home_continue_compose.dart';
import 'package:fushi/src/pages/implementations/dashboard_continue_logic.dart'
    show DashboardVideoProgress, dashboardVideoContinueProgress;
import 'package:fushi/src/pages/implementations/home_dashboard_derived.dart'
    show HomeDashboardVideoIndex;
import 'package:fushi/src/sync/interconnect_sync_backend.dart'
    show InterconnectSyncBackend;
import 'package:fushi/src/utils/misc/dashboard_remote_continue_feed.dart'
    show RemoteContinueFeed;
import 'package:fushi/src/utils/misc/dashboard_remote_merge.dart'
    show RemoteContinueCandidate;
import 'package:fushi/src/utils/misc/dashboard_server_continue.dart'
    show ServerContinueCandidate;
import 'package:fushi/src/utils/misc/dashboard_server_continue_feed.dart'
    show ServerContinueFeed;
import 'package:fushi/src/utils/misc/dashboard_server_continue_gates.dart'
    show serverContinueGates;
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/media/collections/book_series_key.dart'
    show collectionMemberVolumeNumber;
import 'package:fushi_engine/media/video/m3u8_playlist.dart'
    show playlistEpisodeCount;
import 'package:fushi_engine/stats/stat_facts.dart'
    show StatFacts, StatFactsScope, loadStatFacts;
import 'package:material_ui/material_ui.dart';
import 'package:transparent_image/transparent_image.dart';
import 'package:fushi/src/media/media_source.dart';

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
/// 与 dashboard「继续」区同一份 [composeHomeContinue] 编排（含互联远端、服务器条目，
/// BUG-5260）；音乐 = 正在播放 + 最近播放（按专辑折叠）；查词 = 查词历史（没有
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
        coverMaterial: ShelfCoverMaterial.glossyBook,
        load: () async => (await _loadBooks(
          ref: ref,
          appModel: appModel,
          manga: tab == HomeTab.manga,
          contextOf: contextOf,
        )).toData(),
      );
    case HomeTab.video:
      return AdaptiveNavPeek(
        coverMaterial: ShelfCoverMaterial.glossyPoster,
        load: () async => (await _loadVideos(
          appModel: appModel,
          repo: videoRepo(),
          share: ref.read(videoContinueShareProvider),
          contextOf: contextOf,
          openVideoTab: () => goToTab(HomeTab.video),
        )).toData(),
      );
    case HomeTab.games:
      return AdaptiveNavPeek(
        coverMaterial: ShelfCoverMaterial.gameCase,
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

/// 速览卡封面的 NSFW 判定（拍板台 w04vrhUAaX）：「模糊 NSFW 封面」关着恒 false，
/// 否则按加载这一刻的快照判（速览每次展开都重新加载）。
Future<bool Function(MediaNsfwTarget target)> _loadNsfwJudge(
  AppModel appModel,
) async {
  if (!appModel.prefsRepo.blurNsfwCovers) return (MediaNsfwTarget _) => false;
  final MediaNsfwSnapshot snapshot = await MediaNsfwSnapshot.load(
    appModel.database,
  );
  return (MediaNsfwTarget target) => target.resolve(snapshot);
}

/// 漫画速览行的有声状态：做不了有声（在线章节 / 读不出）的不在表里。
enum _MangaPeekAudio { none, ready }

/// [bookKeys] 里每本漫画的有声状态（[_MangaPeekAudio]）。只查要显示的那几本。
Future<Map<String, _MangaPeekAudio>> _loadMangaPeekAudio(
  AppModel appModel,
  Iterable<String> bookKeys,
) async {
  final Map<String, _MangaPeekAudio> out = <String, _MangaPeekAudio>{};
  for (final String key in bookKeys) {
    final EpubBookRow? row = await appModel.database.getEpubBook(key);
    if (row == null || !isLocalMangaVolume(row)) continue;
    out[key] = await mangaHasAudio(appModel.database, key)
        ? _MangaPeekAudio.ready
        : _MangaPeekAudio.none;
  }
  return out;
}

Future<NavPeekFeed> _loadBooks({
  required WidgetRef ref,
  required AppModel appModel,
  required bool manga,
  required BuildContext Function() contextOf,
}) async {
  // 上锁（未解锁）的书不进预览（[MediaVisibility]，唯一的上锁过滤入口）。
  final MediaVisibility lockVisibility = await MediaVisibility.load(
    appModel.database,
  );
  final List<MediaItem> all = <MediaItem>[
    for (final MediaItem item in await ref.read(
      fushiBooksProvider(JapaneseLanguage.instance).future,
    ))
      if (ReaderFushiSource.parseBookKey(item.mediaIdentifier)
          case final String? key
          when key == null || !lockVisibility.hidesBook(key))
        item,
  ];
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
  final bool Function(MediaNsfwTarget) nsfw = await _loadNsfwJudge(appModel);
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
  // 漫画行的有声入口（2026-11-20 反馈 #6）：已有有声版常显「有声」签，没有的
  // 悬停 / 聚焦时给「加声音」打开有声漫画工作台。生成 / 导入受听书模块门控。
  Map<String, _MangaPeekAudio> audio = const <String, _MangaPeekAudio>{};
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
    final String bookKey = keyOf(item);
    final _MangaPeekAudio? audioState = audio[bookKey];
    final bool hasAudio = audioState == _MangaPeekAudio.ready;
    return AdaptiveNavPeekEntry(
      title: collection ?? itemTitle,
      cover: noCover ? null : image,
      blurCover: nsfw(MediaNsfwTarget.book(bookKey)),
      status: hasAudio ? t.manga_audio_workbench_has_audio : null,
      statusIcon: hasAudio ? FushiIcons.audio : null,
      statusTone: AdaptiveNavPeekStatusTone.active,
      action:
          audioState == _MangaPeekAudio.none &&
              MangaAudioWorkbenchEntry.isAvailable
          ? AdaptiveNavPeekAction(
              icon: FushiIcons.audio,
              label: t.manga_audio_workbench_add_sound,
              onPressed: () => unawaited(
                MangaAudioWorkbenchEntry.open(contextOf(), bookKey: bookKey),
              ),
            )
          : null,
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
  final List<NavPeekUnit<MediaItem>> recentUnits = units
      .where((NavPeekUnit<MediaItem> unit) => !identical(unit, resume))
      .take(_kPeekRecentCount)
      .toList();
  if (manga && appModel.moduleVisibility.isEnabled(ModuleId.listening)) {
    audio = await _loadMangaPeekAudio(appModel, <String>[
      if (resume != null) keyOf(resume.item),
      for (final NavPeekUnit<MediaItem> unit in recentUnits) keyOf(unit.item),
    ]);
  }
  NavPeekTimed timed(NavPeekUnit<MediaItem> unit) => (
    at: recentOf(unit.item),
    entry: entryOf(unit.item, collection: unit.collectionName),
  );
  return NavPeekFeed(
    resume: resume == null ? null : timed(resume),
    recent: recentUnits.map(timed).toList(),
  );
}

/// 速览「最近」里的一项：继续观看候选，或最近播放过、不在继续观看里的本地条目
/// （按合集折叠后的单元）。二者恰一非空。
typedef VideoNavPeekItem = ({
  VideoContinueCandidate? candidate,
  NavPeekUnit<VideoBookRow>? played,
});

/// 视频速览的编排（纯函数）：「继续」= 继续观看第一项（与视频首页首屏主卡同一份
/// [selectVideoContinueCandidates] 结果）；「最近」= 其余继续观看候选，再接最近播放
/// 过的其它本地条目（按合集折叠，已在继续观看里的合集 / 散片不再重复）。
({VideoContinueCandidate? resume, List<VideoNavPeekItem> recent})
planVideoNavPeek({
  required List<VideoContinueCandidate> candidates,
  required List<VideoBookRow> recentlyPlayed,
  required Map<String, int> primaryCollectionIdByEntry,
  required Map<int, MediaCollectionRow> collectionsById,
  int recentCount = _kPeekRecentCount,
}) {
  final Set<int> coveredCollections = <int>{};
  final Set<String> coveredUids = <String>{};
  for (final VideoContinueCandidate c in candidates) {
    switch (c) {
      case VideoContinueSeriesCandidate(:final MediaCollectionRow collection):
        coveredCollections.add(collection.id);
      case VideoContinueLocalCandidate(:final VideoBookRow book):
        coveredUids.add(book.bookUid);
      case VideoContinueRemoteCandidate(:final RemoteVideoInfo video):
        coveredUids.add(video.id);
    }
  }
  final List<NavPeekUnit<VideoBookRow>> played = <NavPeekUnit<VideoBookRow>>[
    for (final NavPeekUnit<VideoBookRow> unit
        in foldNavPeekByCollection<VideoBookRow>(
          recentFirst: recentlyPlayed,
          compositeKeyOf: (VideoBookRow v) =>
              MediaKind.video.compositeKey(v.bookUid),
          primaryCollectionIdByEntry: primaryCollectionIdByEntry,
          collectionsById: collectionsById,
        ))
      if (unit.collectionId == null
          ? !coveredUids.contains(unit.item.bookUid)
          : !coveredCollections.contains(unit.collectionId))
        unit,
  ];
  return (
    resume: candidates.firstOrNull,
    recent: <VideoNavPeekItem>[
      for (final VideoContinueCandidate c in candidates.skip(1))
        (candidate: c, played: null),
      for (final NavPeekUnit<VideoBookRow> unit in played)
        (candidate: null, played: unit),
    ].take(recentCount).toList(),
  );
}

Future<NavPeekFeed> _loadVideos({
  required AppModel appModel,
  required VideoBookRepository repo,
  required VideoContinueShare share,
  required BuildContext Function() contextOf,
  required VoidCallback openVideoTab,
}) async {
  final bool Function(MediaNsfwTarget) nsfw = await _loadNsfwJudge(appModel);
  final MediaVisibility lockVisibility = await MediaVisibility.load(
    appModel.database,
  );
  final VideoContinueLibrary library = await loadVideoContinueLibrary(
    appModel.database,
    listBooks: repo.listForShelf,
  );
  int? durationMsOf(String bookUid) => videoDurationMsFromPref(
    appModel.prefsRepo.getPref(videoDurationPrefKey(bookUid)),
  );
  final VideoContinueInputs inputs = library.inputs(durationMsOf: durationMsOf);
  // 上锁（未解锁）的视频与上锁合集里的视频不进速览（与视频页同口径）。
  bool hiddenByCollection(VideoBookRow b) {
    final int? cid = inputs.collectionIdByUid[b.bookUid];
    return cid != null && lockVisibility.hidesCollection(cid);
  }

  final List<VideoBookRow> visible = <VideoBookRow>[
    for (final VideoBookRow b in library.books)
      if (!lockVisibility.hidesVideo(b.bookUid) && !hiddenByCollection(b)) b,
  ];
  // 视频页已经算过就用它那份（同一项、同一顺序）；没开过视频页时按同一个纯函数
  // 现算，远端清单只用视频页取到的那份（速览本身不发网络请求）。
  final List<VideoContinueCandidate> candidates =
      share.candidates ??
      selectVideoContinueCandidates(
        local: visible,
        remote: visibleHomeRemoteVideos(
          remote: share.remoteVideos ?? const <RemoteVideoInfo>[],
          local: visible,
          primaryCollectionByEntry: library.primaryCollectionByEntry,
          visibility: lockVisibility,
          showRemoteEntries: appModel.prefsRepo.showRemoteEntries,
        ),
        inputs: inputs,
      );
  final List<VideoBookRow> recentlyPlayed =
      visible.where((VideoBookRow v) => (v.lastPlayedAt ?? 0) > 0).toList()
        ..sort(
          (VideoBookRow a, VideoBookRow b) =>
              (b.lastPlayedAt ?? 0) - (a.lastPlayedAt ?? 0),
        );
  final ({VideoContinueCandidate? resume, List<VideoNavPeekItem> recent}) plan =
      planVideoNavPeek(
        candidates: candidates,
        recentlyPlayed: recentlyPlayed,
        primaryCollectionIdByEntry: library.primaryCollectionByEntry,
        collectionsById: library.collectionsById,
      );
  final RemoteVideoSource? remoteSource = share.remoteSource;

  // 合集项用合集自己的封面（与视频库合集卡同一条链），不是最近那一集的抽帧
  // 截图——否则一排都是分集画面，认不出是哪部剧。只查要显示的那几个合集。
  final Map<int, ImageProvider> covers = <int, ImageProvider>{};
  Future<void> loadCover(int? cid) async {
    if (cid == null || covers.containsKey(cid)) return;
    final MediaCollectionRow? collection = library.collectionsById[cid];
    if (collection == null) return;
    final ImageProvider? cover = await _videoCollectionCover(
      appModel,
      collection,
    );
    if (cover != null) covers[cid] = cover;
  }

  for (final VideoContinueCandidate? c in <VideoContinueCandidate?>[
    plan.resume,
    for (final VideoNavPeekItem item in plan.recent) item.candidate,
  ]) {
    if (c is VideoContinueSeriesCandidate) await loadCover(c.collection.id);
  }
  for (final VideoNavPeekItem item in plan.recent) {
    await loadCover(item.played?.collectionId);
  }

  ImageProvider? localCover(VideoBookRow v) {
    final String? cover = v.coverPath;
    return cover == null || cover.isEmpty || !File(cover).existsSync()
        ? null
        : resolveMediaCoverImage(kind: MediaKind.video, localPath: cover);
  }

  ImageProvider? remoteCover(RemoteVideoInfo v) {
    final String? path = v.coverPath;
    if (path != null && path.isNotEmpty && File(path).existsSync()) {
      return resizedFileImage(File(path));
    }
    final String? url = v.coverUrl;
    final RemoteCoverFetcher? fetcher = remoteCoverFetcherFor(remoteSource);
    if (url == null || url.isEmpty || fetcher == null) return null;
    return ResizeImage(
      RemoteCoverImage(url, fetcher, cacheKey: v.id),
      width: kLocalCoverDecodePixelWidth,
      allowUpscaling: false,
    );
  }

  void openLocal(VideoBookRow v, {int? collectionId}) {
    final BuildContext context = contextOf();
    if (!context.mounted) return;
    unawaited(
      openLocalVideoBook(
        context: context,
        repo: repo,
        bookUid: v.bookUid,
        playlistCollectionId: collectionId,
      ),
    );
  }

  // 远端那集与视频页远端卡同一条流播入口；来源没有 live 能力（云盘）或清单已不
  // 可用时切到视频页，由视频页的下载 / 不可达提示接手。
  void openRemote(RemoteVideoInfo v) {
    final BuildContext context = contextOf();
    if (!context.mounted) return;
    final RemoteVideoSource? source = remoteSource;
    if (source is RemoteVideoClient) {
      unawaited(
        openRemoteVideoStream(
          context: context,
          repo: repo,
          client: source,
          video: v,
        ),
      );
    } else {
      openVideoTab();
    }
  }

  double? fraction(int positionMs, int? durationMs) =>
      positionMs <= 0 || durationMs == null || durationMs <= 0
      ? null
      : (positionMs / durationMs).clamp(0.0, 1.0);

  AdaptiveNavPeekEntry candidateEntry(VideoContinueCandidate c) {
    switch (c) {
      case VideoContinueSeriesCandidate():
        final VideoHomeSlot target = c.target;
        final int cid = c.collection.id;
        final VideoBookRow? local = target.local;
        final RemoteVideoInfo? remote = target.remote;
        return AdaptiveNavPeekEntry(
          title: c.title,
          subtitle: videoContinueSeriesSubtitle(c),
          blurCover:
              nsfw(MediaNsfwTarget.collection(cid)) ||
              (local != null && nsfw(MediaNsfwTarget.video(local.bookUid))),
          cover:
              covers[cid] ??
              (local != null ? localCover(local) : remoteCover(remote!)),
          progress:
              (local != null
                  ? fraction(local.lastPositionMs, durationMsOf(local.bookUid))
                  : fraction(remote!.positionMs, remote.durationMs)) ??
              c.completedCount / c.members.length,
          onOpen: () => local != null
              ? openLocal(local, collectionId: cid)
              : openRemote(remote!),
        );
      case VideoContinueLocalCandidate(:final VideoBookRow book):
        return AdaptiveNavPeekEntry(
          title: book.title,
          blurCover: nsfw(MediaNsfwTarget.video(book.bookUid)),
          cover: localCover(book),
          subtitle: t.video_watched_up_to(
            time: formatVideoPosition(book.lastPositionMs),
          ),
          progress: fraction(book.lastPositionMs, durationMsOf(book.bookUid)),
          onOpen: () => openLocal(book),
        );
      case VideoContinueRemoteCandidate(:final RemoteVideoInfo video):
        return AdaptiveNavPeekEntry(
          title: video.title,
          cover: remoteCover(video),
          subtitle: t.video_watched_up_to(
            time: formatVideoPosition(video.positionMs),
          ),
          progress: fraction(video.positionMs, video.durationMs),
          onOpen: () => openRemote(video),
        );
    }
  }

  AdaptiveNavPeekEntry playedEntry(NavPeekUnit<VideoBookRow> unit) {
    final VideoBookRow v = unit.item;
    final int? cid = unit.collectionId;
    final ImageProvider? collectionCover = cid == null ? null : covers[cid];
    return AdaptiveNavPeekEntry(
      title: unit.collectionName ?? v.title,
      // 这一集自己（含所在 NSFW 合集）；用的是合集封面时再看合集。
      blurCover:
          nsfw(MediaNsfwTarget.video(v.bookUid)) ||
          (collectionCover != null &&
              cid != null &&
              nsfw(MediaNsfwTarget.collection(cid))),
      cover: collectionCover ?? localCover(v),
      subtitle: _peekSubtitle(
        unit.collectionName == null ? null : v.title,
        v.lastPositionMs > 0 ? formatVideoPosition(v.lastPositionMs) : null,
      ),
      onOpen: () => openLocal(v, collectionId: cid),
    );
  }

  final VideoContinueCandidate? resume = plan.resume;
  return NavPeekFeed(
    resume: resume == null
        ? null
        : (at: resume.recentMs, entry: candidateEntry(resume)),
    recent: <NavPeekTimed>[
      for (final VideoNavPeekItem item in plan.recent)
        if (item.candidate case final VideoContinueCandidate c)
          (at: c.recentMs, entry: candidateEntry(c))
        else if (item.played case final NavPeekUnit<VideoBookRow> unit)
          (at: unit.item.lastPlayedAt ?? 0, entry: playedEntry(unit)),
    ],
  );
}

Future<NavPeekFeed> _loadGames({
  required AppModel appModel,
  required VoidCallback open,
}) async {
  final List<GalgameEntry> games = appModel.galgameRepo.games.isNotEmpty
      ? appModel.galgameRepo.games
      : await appModel.galgameRepo.load();
  final bool Function(MediaNsfwTarget) nsfw = await _loadNsfwJudge(appModel);
  final MediaVisibility lockVisibility = await MediaVisibility.load(
    appModel.database,
  );
  final List<GalgameEntry> played =
      games
          .where(
            (GalgameEntry g) =>
                g.lastPlayedMs > 0 && !lockVisibility.hidesGame(g.id),
          )
          .toList()
        ..sort(
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
        blurCover: nsfw(MediaNsfwTarget.game(g.id, adult: g.isNsfw)),
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
/// 到期那一项与牌组行同一份格式（[SrsReviewCell]），准备中再跟「(准备中)」。
String? srsNavPeekCountsLabel({
  required int newCount,
  required int learnCount,
  required int reviewCount,
  bool reviewPending = false,
  int? reviewMinutesLeft,
}) {
  final String? review = SrsReviewCell(
    due: reviewCount,
    pending: reviewPending,
    minutesLeft: reviewMinutesLeft,
  ).label(omitZero: true);
  final List<String> parts = <String>[
    if (newCount > 0) '${t.srs_count_new} $newCount',
    if (learnCount > 0) '${t.srs_count_learn} $learnCount',
    ?review,
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
    final bool hasWork =
        deck.newCount + deck.learnCount + deck.reviewCount > 0 ||
        deck.rwkvPending;
    return AdaptiveNavPeekEntry(
      title: deck.fullName,
      subtitle:
          srsNavPeekCountsLabel(
            newCount: deck.newCount,
            learnCount: deck.learnCount,
            reviewCount: deck.reviewCount,
            reviewPending: deck.rwkvPending,
            reviewMinutesLeft: deck.reviewMinutesLeft,
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
  final AdaptiveNavPeekEntry Function(VideoDownloadJobRow job) entryOf =
      navPeekDownloadEntry(openDownloads);
  final VideoDownloadJobRow? resume = jobs
      .where(
        (VideoDownloadJobRow j) =>
            j.lifecycle == VideoDownloadJobLifecycle.active,
      )
      .firstOrNull;
  return AdaptiveNavPeekData(
    resume: resume == null ? null : entryOf(resume),
    resumeLabel: t.download_task_lifecycle_active,
    recentLabel: t.nav_downloads,
    summary: navPeekDownloadSummary(jobs),
    recent: jobs
        .where((VideoDownloadJobRow j) => !identical(j, resume))
        .take(_kPeekRecentCount)
        .map(entryOf)
        .toList(),
  );
}

/// 下载任务的速览条目：标题是作品名，副行是具体资源名（同一部作品的不同集 /
/// 版本靠它区分——只有作品名时两条任务看起来是同一项），尾部状态签是进行中的
/// 百分比或生命周期（已完成 / 需要处理 / 已失败 / 已取消）。
AdaptiveNavPeekEntry Function(VideoDownloadJobRow job) navPeekDownloadEntry(
  VoidCallback openDownloads,
) => (VideoDownloadJobRow job) {
  final String? cover = job.coverUrl;
  final bool done = job.lifecycle == VideoDownloadJobLifecycle.completed;
  final double progress = done
      ? 1
      : job.stageProgress.clamp(0.0, 1.0).toDouble();
  final String? resource = job.resourceTitle?.trim();
  final (
    String status,
    AdaptiveNavPeekStatusTone tone,
  ) = switch (job.lifecycle) {
    VideoDownloadJobLifecycle.completed => (
      t.download_task_lifecycle_completed,
      AdaptiveNavPeekStatusTone.done,
    ),
    VideoDownloadJobLifecycle.needsAttention => (
      t.download_task_lifecycle_needs_attention,
      AdaptiveNavPeekStatusTone.attention,
    ),
    VideoDownloadJobLifecycle.failed => (
      t.download_task_lifecycle_failed,
      AdaptiveNavPeekStatusTone.error,
    ),
    VideoDownloadJobLifecycle.cancelled => (
      t.download_task_lifecycle_cancelled,
      AdaptiveNavPeekStatusTone.neutral,
    ),
    _ => ('${(progress * 100).round()}%', AdaptiveNavPeekStatusTone.active),
  };
  return AdaptiveNavPeekEntry(
    title: job.title,
    cover: cover == null || cover.isEmpty ? null : AppHttpImage(cover),
    progress: progress,
    subtitle: resource == null || resource.isEmpty
        ? (job.year == null ? null : '${job.year}')
        : resource,
    status: status,
    statusTone: tone,
    onOpen: openDownloads,
  );
};

/// 下载速览页头的概况：「活动 2 · 完成 35」，需要处理 / 失败的有才拼上。
String? navPeekDownloadSummary(List<VideoDownloadJobRow> jobs) {
  int count(String lifecycle) =>
      jobs.where((VideoDownloadJobRow j) => j.lifecycle == lifecycle).length;
  final int active = count(VideoDownloadJobLifecycle.active);
  final int attention =
      count(VideoDownloadJobLifecycle.needsAttention) +
      count(VideoDownloadJobLifecycle.failed);
  final int completed = count(VideoDownloadJobLifecycle.completed);
  if (jobs.isEmpty) return null;
  return <String>[
    t.download_summary_active(n: active),
    if (attention > 0)
      '${t.download_task_lifecycle_needs_attention} $attention',
    t.download_summary_completed(n: completed),
  ].join(' · ');
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

/// 视频合集的封面，顺序与视频库合集卡一致：自有层（合集自己的封面文件 → 原盘竖版
/// 盘面图，见 [loadCollectionOwnCoverCandidates]）→ 刮削作品的海报（cover /
/// poster，本地文件优先、没有落盘就走远端地址）→ null（调用方退回成员封面）。
Future<ImageProvider?> _videoCollectionCover(
  AppModel appModel,
  MediaCollectionRow collection,
) async {
  for (final String own in await loadCollectionOwnCoverCandidates(
    appModel.database,
    collection,
  )) {
    if (await File(own).exists()) return resizedFileImage(File(own));
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

/// 首页速览的编排（纯函数）：与首页 dashboard「继续」区同一份 [composeHomeContinue]
/// 结果、同一顺序——「继续」= 第一张卡，「最近」= 接下来的 [recentCount] 张
/// （2026-11-22 用户拍板「每张卡跟它打开的页面一致」，BUG-5260）。
({HomeContinueUnit? resume, List<HomeContinueUnit> recent}) planHomeNavPeek(
  List<HomeContinueUnit> units, {
  int recentCount = _kPeekRecentCount,
}) => (
  resume: units.firstOrNull,
  recent: units.skip(1).take(recentCount).toList(),
);

/// 首页速览：输入按首页 dashboard 载入的同一批表 / provider 现读，互联远端补位与
/// 服务器条目只读首页取好的进程级结果（[RemoteContinueFeed] / [ServerContinueFeed]，
/// 悬停不发网络请求），交给与 dashboard 同一个 [composeHomeContinue] 编排。
Future<AdaptiveNavPeekData> _loadHome({
  required WidgetRef ref,
  required AppModel appModel,
  required BuildContext Function() contextOf,
  required VideoBookRepository videoRepo,
  required ValueChanged<HomeTab> goToTab,
}) async {
  final FushiDatabase db = appModel.database;
  final ModuleVisibility modules = appModel.moduleVisibility;
  final bool videoOn = modules.isEnabled(ModuleId.video);
  final MediaVisibility lockVisibility = await MediaVisibility.load(db);
  final Future<List<MediaItem>> booksF = ref.read(
    fushiBooksProvider(JapaneseLanguage.instance).future,
  );
  final Future<Map<String, int>> lastReadF = ref.read(
    bookLastReadAtProvider.future,
  );
  final Future<Map<String, String>> uidByKeyF = ref.read(
    epubBookUidByKeyProvider.future,
  );
  final Future<Set<String>> completedF = ref.read(
    completedEpubBookKeysProvider.future,
  );
  final Future<List<VideoBookRow>> videosF = videoRepo.listForShelf();
  final Future<List<MediaCollectionRow>> collectionsF = db
      .getAllMediaCollections();
  final Future<Map<String, ({int collectionId, int sortIndex})>> membershipF =
      db.getLocalPrimaryCollectionMembership();
  final Future<List<GalgameEntry>> gamesF = appModel.galgameRepo.isLoaded
      ? Future<List<GalgameEntry>>.value(appModel.galgameRepo.games)
      : appModel.galgameRepo.load();
  // 视频的最近观看时刻（与首页同一份观看域事实；视频模块关着时视频卡本就出局）。
  final Future<Map<String, int>> watchAtF = videoOn
      ? loadStatFacts(
          db,
          scope: const StatFactsScope.domain(kActivityMediaVideo),
        ).then(
          (StatFacts facts) => homeContinueVideoWatchAtByUid(facts.dailyVideos),
        )
      : Future<Map<String, int>>.value(const <String, int>{});
  final bool Function(MediaNsfwTarget) nsfw = await _loadNsfwJudge(appModel);

  final List<MediaItem> books = <MediaItem>[
    for (final MediaItem item in await booksF)
      if (!homeContinueHidesBook(lockVisibility, item)) item,
  ];
  final List<VideoBookRow> videos = <VideoBookRow>[
    for (final VideoBookRow v in await videosF)
      if (!lockVisibility.hidesVideo(v.bookUid)) v,
  ];
  final List<GalgameEntry> games = <GalgameEntry>[
    for (final GalgameEntry g in await gamesF)
      if (!lockVisibility.hidesGame(g.id)) g,
  ];
  final Map<String, String> uidByKey = await uidByKeyF;
  final ({Map<String, int> primaryByEntry, Map<String, int> sortIndex})
  membership = splitPrimaryCollectionMembership(await membershipF);
  final Map<int, MediaCollectionRow> collectionsById =
      <int, MediaCollectionRow>{
        for (final MediaCollectionRow c in await collectionsF) c.id: c,
      };
  final RemoteContinueFeed remoteFeed = RemoteContinueFeed.of(db);
  final ({bool mediaServers, bool audiobookshelf, String signature}) gates =
      serverContinueGates(
        prefs: appModel.isPreferencesReady ? appModel.prefsRepo : null,
        visibility: modules,
      );
  int? durationMsOf(String bookUid) => videoDurationMsFromPref(
    appModel.prefsRepo.getPref(videoDurationPrefKey(bookUid)),
  );
  final List<HomeContinueUnit> units = composeHomeContinue(
    HomeContinueInputs(
      books: books,
      lastReadByUid: await lastReadF,
      epubUidByKey: uidByKey,
      completedBookKeys: await completedF,
      collectionEpubUidByKey: uidByKey,
      primaryCollectionByEntry: membership.primaryByEntry,
      memberSortIndex: membership.sortIndex,
      collectionNamesById: <int, String>{
        for (final MediaCollectionRow c in collectionsById.values) c.id: c.name,
      },
      videoIndex: HomeDashboardVideoIndex.build(
        videos: videos,
        primaryCollectionByEntry: membership.primaryByEntry,
        memberSortIndex: membership.sortIndex,
      ),
      videoWatchAtByUid: await watchAtF,
      videoDurationMsOf: durationMsOf,
      games: games,
      // 「显示远端条目」关着时首页不混排远端（首页取数前同一道门）。
      remote: appModel.prefsRepo.showRemoteEntries
          ? remoteFeed.current
          : const <RemoteContinueCandidate>[],
      server: ServerContinueFeed.of(db).current,
      mediaServerGate: gates.mediaServers,
      audiobookshelfGate: gates.audiobookshelf,
      isModuleEnabled: modules.isEnabled,
    ),
  );
  final ({HomeContinueUnit? resume, List<HomeContinueUnit> recent}) plan =
      planHomeNavPeek(units);
  final List<HomeContinueUnit> shown = <HomeContinueUnit>[
    ?plan.resume,
    ...plan.recent,
  ];

  // 视频进度条要总时长：只查要显示的本地文件（首页同一张探测缓存表）。
  final Map<String, VideoFileSpecRow> specs = await db
      .videoFileSpecsByPath(<String>[
        for (final HomeContinueUnit u in shown)
          if (u is HomeContinueVideoUnit) u.row.videoPath,
      ]);
  // 合集卡用合集自己的封面（与视频库合集卡同一条链），只查要显示的几个。
  final Map<int, ImageProvider> collectionCovers = <int, ImageProvider>{};
  for (final HomeContinueUnit u in shown) {
    if (u is! HomeContinueVideoUnit) continue;
    final MediaCollectionRow? collection = collectionsById[u.collectionId];
    if (collection == null || collectionCovers.containsKey(collection.id)) {
      continue;
    }
    final ImageProvider? cover = await _videoCollectionCover(
      appModel,
      collection,
    );
    if (cover != null) collectionCovers[collection.id] = cover;
  }
  final RemoteCoverFetcher? remoteFetcher = remoteCoverFetcherFor(
    InterconnectSyncBackend.instance,
  );

  ImageProvider? localCover(MediaKind kind, String? path) =>
      path == null || path.isEmpty || !File(path).existsSync()
      ? null
      : resolveMediaCoverImage(kind: kind, localPath: path);

  AdaptiveNavPeekEntry entryOf(HomeContinueUnit unit) {
    switch (unit) {
      case HomeContinueBookUnit(:final MediaItem item):
        final ImageProvider image = ReaderFushiSource.instance
            .getDisplayThumbnailFromMediaItem(appModel: appModel, item: item);
        final bool noCover =
            image is MemoryImage && identical(image.bytes, kTransparentImage);
        final int percent = item.duration > 0
            ? ((item.position / item.duration) * 100).clamp(0, 100).round()
            : 0;
        final int? ordinal = unit.memberOrdinal;
        final num? volume = ordinal == null
            ? null
            : collectionMemberVolumeNumber(
                title: unit.title,
                memberTitles: <String>[
                  for (final MediaItem m in unit.collectionMembers)
                    ReaderFushiSource.instance.getDisplayTitleFromMediaItem(m),
                ],
                memberOrdinal: ordinal,
              );
        final String? srtUid = ReaderFushiSource.parseSrtBookUid(
          item.mediaIdentifier,
        );
        final String? bookKey = ReaderFushiSource.parseBookKey(
          item.mediaIdentifier,
        );
        return AdaptiveNavPeekEntry(
          title: unit.displayTitle,
          cover: noCover ? null : image,
          blurCover: srtUid != null
              ? nsfw(MediaNsfwTarget.srtBook(srtUid))
              : bookKey != null && nsfw(MediaNsfwTarget.book(bookKey)),
          progress: percent / 100,
          subtitle: _peekSubtitle(
            unit.collectionName == null ? null : unit.title,
            volume != null ? t.home_continue_volume(n: volume) : '$percent%',
          ),
          onOpen: () => unawaited(
            appModel.openMedia(
              ref: ref,
              mediaSource: item.getMediaSource(appModel: appModel),
              item: item,
            ),
          ),
        );
      case HomeContinueVideoUnit(:final VideoBookRow row):
        final DashboardVideoProgress p = dashboardVideoContinueProgress(
          completed: row.completedAt != null,
          positionMs: row.lastPositionMs,
          durationMs: specs[row.videoPath]?.durationMs,
          currentEpisode: row.currentEpisode,
          playlistEpisodeCount: playlistEpisodeCount(row.playlistJson),
          collectionEpisode: unit.collectionEpisode,
          collectionEpisodeCount: unit.collectionEpisodeCount,
        );
        final int? episode = p.episode;
        final int? percent = p.percent;
        final int? positionMs = p.positionMs;
        final int? cid = unit.collectionId;
        final ImageProvider? collectionCover = cid == null
            ? null
            : collectionCovers[cid];
        return AdaptiveNavPeekEntry(
          title: unit.displayTitle,
          cover: collectionCover ?? localCover(MediaKind.video, row.coverPath),
          blurCover:
              nsfw(MediaNsfwTarget.video(row.bookUid)) ||
              (collectionCover != null &&
                  cid != null &&
                  nsfw(MediaNsfwTarget.collection(cid))),
          progress: p.fraction,
          subtitle: _peekSubtitle(
            unit.collectionName == null ? null : row.title,
            episode != null
                ? t.home_continue_episode(n: episode)
                : percent != null
                ? '$percent%'
                : (positionMs != null ? formatVideoPosition(positionMs) : null),
          ),
          onOpen: () {
            final BuildContext context = contextOf();
            if (!context.mounted) return;
            // 与首页卡同一条续播入口：合集成员带主合集 id（剧集面板 / 连播）。
            unawaited(
              openLocalVideoBook(
                context: context,
                repo: videoRepo,
                bookUid: row.bookUid,
                playlistCollectionId: membership
                    .primaryByEntry[MediaKind.video.compositeKey(row.bookUid)],
              ),
            );
          },
        );
      case HomeContinueGameUnit(:final GalgameEntry game):
        // 游戏卡切到游戏库（首页同样不直接启动游戏，BUG-1111）。
        return AdaptiveNavPeekEntry(
          title: unit.displayTitle,
          subtitle: unit.collectionName == null ? null : game.displayName,
          cover: localCover(MediaKind.game, game.coverPath),
          blurCover: nsfw(MediaNsfwTarget.game(game.id, adult: game.isNsfw)),
          onOpen: () => goToTab(HomeTab.games),
        );
      case HomeContinueRemoteUnit(:final RemoteContinueCandidate candidate):
        final String? url = candidate.coverUrl;
        return AdaptiveNavPeekEntry(
          title: unit.displayTitle,
          subtitle: _peekSubtitle(
            unit.collectionName == null ||
                    unit.collectionName == candidate.title
                ? null
                : candidate.title,
            remoteFeed.deviceName ?? t.home_remote_source,
          ),
          cover: url == null || url.isEmpty || remoteFetcher == null
              ? null
              : ResizeImage(
                  RemoteCoverImage(url, remoteFetcher, cacheKey: candidate.id),
                  width: kLocalCoverDecodePixelWidth,
                  allowUpscaling: false,
                ),
          progress: candidate.isVideo ? null : candidate.percent / 100,
          // 与首页远端卡同一落地：切到对应库页，远端占位卡在那里承接播放 / 下载。
          onOpen: () =>
              goToTab(candidate.isVideo ? HomeTab.video : HomeTab.books),
        );
      case HomeContinueServerUnit(:final ServerContinueCandidate candidate):
        final String? url = candidate.coverUrl;
        final RemoteCoverFetcher? fetcher = candidate.coverFetcher;
        return AdaptiveNavPeekEntry(
          title: unit.displayTitle,
          subtitle: _peekSubtitle(
            unit.collectionName == null ||
                    unit.collectionName == candidate.title
                ? null
                : candidate.title,
            candidate.serverName,
          ),
          cover: url == null || url.isEmpty
              ? null
              : fetcher != null
              ? RemoteCoverImage(
                  url,
                  fetcher,
                  cacheKey: candidate.coverCacheKey,
                )
              : AppCachedHttpImage(url, cacheKey: candidate.coverCacheKey),
          progress: candidate.progress,
          // 与首页服务器卡同一落地：媒体服务器起播，ABS 打开条目详情页。
          onOpen: () {
            final BuildContext context = contextOf();
            if (!context.mounted) return;
            unawaited(
              candidate.open(context).catchError((Object e, StackTrace stack) {
                ErrorLogService.instance.log(
                  'homeNavPeek.openServerContinue',
                  e,
                  stack,
                );
              }),
            );
          },
        );
    }
  }

  final HomeContinueUnit? resume = plan.resume;
  return AdaptiveNavPeekData(
    resume: resume == null ? null : entryOf(resume),
    recent: <AdaptiveNavPeekEntry>[
      for (final HomeContinueUnit u in plan.recent) entryOf(u),
    ],
  );
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
  final MediaVisibility lockVisibility = await MediaVisibility.load(db);
  final List<MusicTrackRow> played = <MusicTrackRow>[
    for (final MusicTrackRow t in await db.listRecentlyPlayedMusicTracks(
      limit: 30,
    ))
      if (t.albumUid == null || !lockVisibility.hidesMusicAlbum(t.albumUid!)) t,
  ];
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
  // 冷启动后历史在后台装载，落定前读到的空表不代表「没查过词」。
  await appModel.dictionaryHistoryLoaded;
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
