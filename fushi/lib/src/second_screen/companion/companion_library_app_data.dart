import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/source_review_navigation.dart'
    show ExternalMediaNavigation;
import 'package:fushi/src/media/discovery/audiobookshelf_server_config.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/media_source.dart' show MediaItemAppLookup;
import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/media/kavita/kavita_server_config.dart';
import 'package:fushi/src/media/music/music_output_backend.dart'
    show MusicPlayItem;
import 'package:fushi/src/media/music/music_player_engine.dart'
    show MusicPlayerEngine, MusicPlaySource, MusicQueueContext;
import 'package:fushi/src/media/sources/manga_fushi_source.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/media/video/media_server/media_server_config.dart';
import 'package:fushi/src/media/video/video_folder_collection_policy.dart';
import 'package:fushi/src/media/video/video_watched_marks.dart'
    show setVideosWatched;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/ops/app_op_context.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/pages/implementations/audiobookshelf/audiobookshelf_item_page.dart'
    show AudiobookshelfItemDetailPage;
import 'package:fushi/src/pages/implementations/browse_page.dart'
    show BrowseNavigationRequest, BrowseTab, externalBrowseRequest;
import 'package:fushi/src/pages/implementations/dashboard_continue_logic.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart'
    show openLocalVideoBook;
import 'package:fushi/src/pages/implementations/media_server/media_server_browse_page.dart'
    show pushMediaServerPlayer;
import 'package:fushi/src/pages/implementations/media_server/media_server_routes.dart'
    show resumeMediaServerItem;
import 'package:fushi/src/pages/implementations/media_server/media_server_session.dart';
import 'package:fushi/src/platform/app_shortcut_router.dart'
    show unwindToHomeRoute;
import 'package:fushi/src/platform/widget_link_actions.dart'
    show openWidgetMusicPlayer, openWidgetStats;
import 'package:fushi/src/second_screen/companion/companion_context.dart';
import 'package:fushi/src/second_screen/companion/companion_covers.dart';
import 'package:fushi/src/second_screen/companion/companion_library_service.dart';
import 'package:fushi/src/second_screen/companion/companion_continue.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/companion/modules/library_companion_schema.dart';
import 'package:fushi/src/sync/remote_cover_cache.dart';
import 'package:fushi/src/sync/remote_cover_fetcher.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart'
    show adaptivePageRoute;
import 'package:fushi/src/utils/misc/dashboard_server_continue.dart'
    show ServerContinueCandidate;
import 'package:fushi/src/utils/misc/dashboard_server_continue_feed.dart'
    show ServerContinueFeed;
import 'package:fushi/src/utils/net/app_http_image.dart'
    show AppImageCacheManager;
import 'package:fushi_audio/fushi_audio.dart'
    show ReaderPosition, ReaderPositionRepository, SrtBook;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show JapaneseLanguage;
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_api.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_models.dart';
import 'package:fushi_engine/media/video/m3u8_playlist.dart'
    show playlistEpisodeCount;
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/stats/stat_facts.dart' show loadStatFacts;
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

/// [CompanionLibraryData] over the main app (main engine only): the library
/// providers (`fushiBooksProvider`, `srtBooksProvider`, the home dashboard's
/// continue rules), the repositories (videos, collections, music) and the
/// configured media servers through their existing clients. "Open" goes
/// through the paths the library cards use, after leaving whatever is on top
/// the normal way ([unwindToHomeRoute], the same unwind as the home-screen
/// widget links).
///
/// Sections:
/// - books / manga = `EpubBooks` rows (EPUB + PDF / manga format); an EPUB
///   with a paired audiobook is shown once, as the audiobook (the books shelf
///   does the same: its EPUB card is filtered, the SRT card stays).
/// - audiobooks = the local audiobooks of the books shelf (`SrtBooks`; they
///   open in the reader's audiobook view through the paired EPUB). Remote
///   audiobooks are Audiobookshelf servers in the Servers section.
/// - servers = Jellyfin / Plex (`MediaServerBrowser`: libraries → folders →
///   items, played through `pushMediaServerPlayer`), Audiobookshelf (libraries
///   → items, opened on its item page). Kavita has no listing the companion
///   can reuse outside its manga browse page: listed as "open on the main
///   screen" (the manga tab).
class AppCompanionLibraryData implements CompanionLibraryData {
  AppCompanionLibraryData(this._ref);

  final Ref _ref;

  AppModel get _app => _ref.read(appProvider);
  FushiDatabase get _db => _app.database;
  ModuleVisibility get _modules => _app.moduleVisibility;

  /// Media-server items seen in lists (details / open / siblings come from
  /// what the client already returned).
  final Map<String, _ServerItemCacheEntry> _serverItems =
      <String, _ServerItemCacheEntry>{};

  // ---- sections ------------------------------------------------------------

  @override
  bool isSectionEnabled(CompanionLibrarySection section) {
    final ModuleVisibility m = _modules;
    return switch (section) {
      CompanionLibrarySection.home => true,
      CompanionLibrarySection.books ||
      CompanionLibrarySection.audiobooks => m.isEnabled(ModuleId.books),
      CompanionLibrarySection.manga => m.isEnabled(ModuleId.manga),
      CompanionLibrarySection.video => m.isEnabled(ModuleId.video),
      CompanionLibrarySection.music => m.isEnabled(ModuleId.music),
      // Servers are browsed from the video / books / manga libraries.
      CompanionLibrarySection.servers =>
        m.isEnabled(ModuleId.video) ||
            m.isEnabled(ModuleId.books) ||
            m.isEnabled(ModuleId.manga),
    };
  }

  @override
  List<CompanionLibraryMainTarget> onlineTargets(
    CompanionLibrarySection section,
  ) {
    if (!_modules.isEnabled(ModuleId.browse)) {
      return const <CompanionLibraryMainTarget>[];
    }
    final (StoreRestrictedCapability, CompanionLibraryMainTarget)? online =
        switch (section) {
          CompanionLibrarySection.manga => (
            StoreRestrictedCapability.onlineMangaSource,
            CompanionLibraryMainTarget.onlineManga,
          ),
          CompanionLibrarySection.video => (
            StoreRestrictedCapability.onlineVideoSource,
            CompanionLibraryMainTarget.onlineVideo,
          ),
          CompanionLibrarySection.books => (
            StoreRestrictedCapability.onlineNovelSource,
            CompanionLibraryMainTarget.onlineNovels,
          ),
          _ => null,
        };
    if (online == null || !online.$1.isAvailable) {
      return const <CompanionLibraryMainTarget>[];
    }
    return <CompanionLibraryMainTarget>[online.$2];
  }

  // ---- books / manga / audiobooks -----------------------------------------

  @override
  Future<List<CompanionLibraryRecord>> books() async {
    final AppModel app = _app;
    final List<MediaItem> items = await _ref.read(
      fushiBooksProvider(JapaneseLanguage.instance).future,
    );
    final List<SrtBook> srtBooks = await _ref.read(srtBooksProvider.future);
    final Set<String> completed = await _ref.read(
      completedEpubBookKeysProvider.future,
    );
    final Map<String, int> lastRead = await _ref.read(
      bookLastReadAtProvider.future,
    );
    final Map<String, String> uidByKey = await _ref.read(
      epubBookUidByKeyProvider.future,
    );
    final Map<String, int> importedAt = <String, int>{
      for (final EpubBookMeta m in await _db.getEpubBookMetas())
        m.bookKey: m.importedAt,
    };
    final _Membership membership = await _bookMembership();
    final Map<String, MediaItem> byKey = <String, MediaItem>{};
    for (final MediaItem item in items) {
      final String? key = ReaderFushiSource.parseBookKey(item.mediaIdentifier);
      if (key != null) byKey[key] = item;
    }
    final Set<String> audiobookKeys = <String>{
      for (final SrtBook b in srtBooks)
        if (b.bookKey.isNotEmpty) b.bookKey,
    };
    final List<CompanionLibraryRecord> out = <CompanionLibraryRecord>[];
    for (final MediaItem item in items) {
      final String bookKey =
          ReaderFushiSource.parseBookKey(item.mediaIdentifier) ??
          item.mediaIdentifier;
      if (audiobookKeys.contains(bookKey)) continue;
      final bool manga =
          item.mediaSourceIdentifier == MangaFushiSource.kUniqueKey;
      final bool done = completed.contains(bookKey);
      final double? fraction = item.duration > 0 && item.position > 0
          ? (item.position / item.duration).clamp(0.0, 1.0)
          : null;
      final ({int collectionId, int sortIndex})? member =
          membership[MediaKind.epub.compositeKey(bookKey)];
      out.add(
        CompanionLibraryRecord(
          kind: manga
              ? CompanionLibraryItemKind.manga
              : CompanionLibraryItemKind.book,
          key: item.mediaIdentifier,
          title: ReaderFushiSource.instance.getDisplayTitleFromMediaItem(item),
          subtitle: item.author,
          progress: done ? null : fraction,
          progressLabel: done || fraction == null
              ? null
              : t.second_screen_library_data_progress_percent(
                  n: (fraction * 100).round(),
                ),
          finished: done,
          recentAt: lastReadAtForBookKey(lastRead, uidByKey, bookKey) ?? 0,
          addedAt: importedAt[bookKey] ?? 0,
          collectionId: member?.collectionId,
          sortIndex: member?.sortIndex,
          searchTitles: <String>[item.title],
          resolveCover: () async {
            final String path = companionMediaItemCoverPath(app, item);
            return path.isEmpty ? null : path;
          },
        ),
      );
    }
    for (final SrtBook book in srtBooks) {
      final MediaItem? epub = byKey[book.bookKey];
      final bool done =
          book.bookKey.isNotEmpty && completed.contains(book.bookKey);
      final double? fraction =
          epub != null && epub.duration > 0 && epub.position > 0
          ? (epub.position / epub.duration).clamp(0.0, 1.0)
          : null;
      final ({int collectionId, int sortIndex})? member =
          membership[MediaKind.srt.compositeKey(book.uid)];
      out.add(
        CompanionLibraryRecord(
          kind: CompanionLibraryItemKind.audiobook,
          key: book.bookKey.isNotEmpty
              ? ReaderFushiSource.mediaIdentifierFor(book.bookKey)
              : ReaderFushiSource.mediaIdentifierForSrtUid(book.uid),
          title: epub != null
              ? ReaderFushiSource.instance.getDisplayTitleFromMediaItem(epub)
              : book.title,
          subtitle: book.author ?? epub?.author,
          progress: done ? null : fraction,
          progressLabel: done || fraction == null
              ? null
              : t.second_screen_library_data_progress_percent(
                  n: (fraction * 100).round(),
                ),
          finished: done,
          recentAt: book.bookKey.isEmpty
              ? 0
              : lastReadAtForBookKey(lastRead, uidByKey, book.bookKey) ?? 0,
          addedAt: book.importedAt,
          collectionId: member?.collectionId,
          sortIndex: member?.sortIndex,
          searchTitles: <String>[book.title],
          resolveCover: () async {
            final String? own = book.coverPath;
            if (own != null && own.isNotEmpty && await File(own).exists()) {
              return own;
            }
            if (epub == null) return null;
            final String path = companionMediaItemCoverPath(app, epub);
            return path.isEmpty ? null : path;
          },
        ),
      );
    }
    return out;
  }

  /// `media_type|entry_key` → primary collection + its sort index (the raw
  /// primary membership the books shelf folds by).
  Future<_Membership> _bookMembership() async {
    final Map<String, int> primary = await _db.getPrimaryCollectionIdByEntry();
    return _membershipOf(primary, await _db.getAllCollectionItems());
  }

  static _Membership _membershipOf(
    Map<String, int> primary,
    List<MediaCollectionItemRow> items,
  ) {
    final _Membership out = <String, ({int collectionId, int sortIndex})>{};
    for (final MediaCollectionItemRow m in items) {
      final String key = '${m.mediaType}|${m.entryKey}';
      if (primary[key] == m.collectionId) {
        out[key] = (collectionId: m.collectionId, sortIndex: m.sortIndex);
      }
    }
    return out;
  }

  // ---- videos --------------------------------------------------------------

  Future<_VideoLibrary> _videoLibrary() async {
    final VideoBookRepository repo = VideoBookRepository(_db);
    final List<VideoBookRow> books = await repo.listForShelf();
    final List<MediaCollectionRow> collections = await _db
        .getAllMediaCollections();
    final List<MediaCollectionItemRow> items = await _db
        .getAllCollectionItems();
    final Map<String, int> primary = applyVideoFolderCollectionPolicy(
      primary: await _db.getPrimaryCollectionIdByEntry(),
      collections: collections,
      items: items,
      books: books,
      sources: await _db.getMediaSourcesByKind('video'),
    );
    final Map<String, int> watchedAt = await _db.getLatestStudyEndAtByMedia(
      kActivityMediaVideo,
    );
    final Map<String, VideoFileSpecRow> specs = await _db.videoFileSpecsByPath(
      <String>[for (final VideoBookRow v in books) v.videoPath],
    );
    return _VideoLibrary(
      books: books,
      collections: collections,
      membership: _membershipOf(primary, items),
      watchedAt: watchedAt,
      specs: specs,
    );
  }

  CompanionLibraryRecord _videoRecord(VideoBookRow v, _VideoLibrary lib) {
    final ({int collectionId, int sortIndex})? member =
        lib.membership[MediaKind.video.compositeKey(v.bookUid)];
    final bool done = v.completedAt != null;
    final DashboardVideoProgress progress = dashboardVideoContinueProgress(
      completed: done,
      positionMs: v.lastPositionMs,
      durationMs: lib.specs[v.videoPath]?.durationMs,
      currentEpisode: v.currentEpisode,
      playlistEpisodeCount: playlistEpisodeCount(v.playlistJson),
    );
    final int? episode = progress.episode;
    final int? percent = progress.percent;
    final int recent = <int>[
      v.lastPlayedAt ?? 0,
      lib.watchedAt[v.bookUid] ?? 0,
    ].reduce((int a, int b) => a > b ? a : b);
    return CompanionLibraryRecord(
      kind: CompanionLibraryItemKind.video,
      key: v.bookUid,
      title: v.title,
      progress: done ? null : progress.fraction,
      progressLabel: done
          ? null
          : episode != null
          ? t.second_screen_library_data_progress_episode(n: episode)
          : percent != null && percent > 0
          ? t.second_screen_library_data_progress_percent(n: percent)
          : null,
      finished: done,
      recentAt: recent,
      addedAt: v.localAddedAt ?? v.importedAt ?? 0,
      collectionId: member?.collectionId,
      sortIndex: member?.sortIndex,
      searchTitles: <String>[p.basename(v.videoPath)],
      resolveCover: () => dashboardVideoCoverPath(
        collectionCovers: const <String?>[],
        ownCover: v.coverPath,
        exists: (String path) => File(path).exists(),
      ),
    );
  }

  @override
  Future<List<CompanionLibraryRecord>> videos() async {
    final _VideoLibrary lib = await _videoLibrary();
    return <CompanionLibraryRecord>[
      for (final VideoBookRow v in lib.books) _videoRecord(v, lib),
    ];
  }

  @override
  Future<List<CompanionLibraryCollection>> collections(
    CompanionLibrarySection section,
  ) async => <CompanionLibraryCollection>[
    for (final MediaCollectionRow c in await _db.getAllMediaCollections())
      CompanionLibraryCollection(
        section: section,
        id: c.id,
        title: c.name,
        resolveCover: () => dashboardVideoCoverPath(
          collectionCovers: <String?>[c.coverPath],
          ownCover: null,
          exists: (String path) => File(path).exists(),
        ),
      ),
  ];

  // ---- music ---------------------------------------------------------------

  @override
  Future<CompanionMusicLibrary> music() async {
    final MusicLibrarySnapshot snap = await MusicLibrarySnapshot.load(_db);
    final Map<String, int> trackCount = <String, int>{};
    for (final MusicTrackRow t in snap.tracks) {
      final String? album = t.albumUid;
      if (album != null) trackCount[album] = (trackCount[album] ?? 0) + 1;
    }
    return CompanionMusicLibrary(
      albums: <CompanionLibraryRecord>[
        for (final MusicAlbumRow a in snap.albums)
          CompanionLibraryRecord(
            kind: CompanionLibraryItemKind.musicAlbum,
            key: a.albumUid,
            title: a.title,
            subtitle: a.albumArtistCredit,
            addedAt: a.addedAt,
            count: trackCount[a.albumUid],
            resolveCover: () => _existing(a.coverPath),
          ),
      ],
      artists: <CompanionLibraryRecord>[
        for (final MusicArtistRow a in snap.artists)
          CompanionLibraryRecord(
            kind: CompanionLibraryItemKind.musicArtist,
            key: a.artistUid,
            title: a.name,
          ),
      ],
      playlists: <CompanionLibraryRecord>[
        for (final MusicPlaylistRow p in snap.playlists)
          if (p.rulesJson == null)
            CompanionLibraryRecord(
              kind: CompanionLibraryItemKind.musicPlaylist,
              key: p.playlistUid,
              title: p.name,
            ),
      ],
      tracks: <CompanionLibraryRecord>[
        for (final MusicTrackRow t in snap.tracks)
          _trackRecord(t, snap.albumByUid[t.albumUid]),
      ],
    );
  }

  CompanionLibraryRecord _trackRecord(MusicTrackRow t, MusicAlbumRow? album) =>
      CompanionLibraryRecord(
        kind: CompanionLibraryItemKind.musicTrack,
        key: t.trackUid,
        title: t.title,
        subtitle: t.artistCredit ?? album?.albumArtistCredit,
        addedAt: t.addedAt,
        searchTitles: <String>[?album?.title],
        resolveCover: () => _existing(album?.coverPath),
      );

  @override
  Future<({String title, List<CompanionLibraryRecord> tracks})?> musicChildren(
    String ref,
  ) async {
    final CompanionLibraryItemKind? kind = CompanionLibraryRef.kindOf(ref);
    final String key = CompanionLibraryRef.keyOf(ref);
    final MusicLibrarySnapshot snap = await MusicLibrarySnapshot.load(_db);
    if (kind == CompanionLibraryItemKind.musicArtist) {
      String? name;
      for (final MusicArtistRow a in snap.artists) {
        if (a.artistUid == key) name = a.name;
      }
      if (name == null) return null;
      return (
        title: name,
        tracks: <CompanionLibraryRecord>[
          for (final MusicTrackRow t in await _db.listMusicTracksByArtist(key))
            _trackRecord(t, snap.albumByUid[t.albumUid]),
        ],
      );
    }
    MusicPlaylistRow? playlist;
    for (final MusicPlaylistRow p in snap.playlists) {
      if (p.playlistUid == key) playlist = p;
    }
    if (playlist == null) return null;
    final List<MusicPlaylistEntryRow> entries =
        await (_db.select(_db.musicPlaylistEntries)
              ..where(
                ($MusicPlaylistEntriesTable e) => e.playlistUid.equals(key),
              )
              ..orderBy(<OrderingTerm Function($MusicPlaylistEntriesTable)>[
                ($MusicPlaylistEntriesTable e) =>
                    OrderingTerm(expression: e.position),
              ]))
            .get();
    final Map<String, MusicTrackRow> byUid = <String, MusicTrackRow>{
      for (final MusicTrackRow t in snap.tracks) t.trackUid: t,
    };
    return (
      title: playlist.name,
      tracks: <CompanionLibraryRecord>[
        for (final MusicPlaylistEntryRow e in entries)
          if (byUid[e.trackUid] case final MusicTrackRow t)
            _trackRecord(t, snap.albumByUid[t.albumUid]),
      ],
    );
  }

  // ---- home ----------------------------------------------------------------

  @override
  Future<List<CompanionLibraryRecord>> continueRecords() async {
    final List<CompanionContinueCandidate> candidates =
        await collectCompanionContinueCandidates(
          _ref,
          facts: await loadStatFacts(_db, activityLimit: 0),
        );
    final List<SrtBook> srtBooks = await _ref.read(srtBooksProvider.future);
    final Set<String> audiobookIds = <String>{
      for (final SrtBook b in srtBooks)
        if (b.bookKey.isNotEmpty)
          ReaderFushiSource.mediaIdentifierFor(b.bookKey),
    };
    return <CompanionLibraryRecord>[
      for (final CompanionContinueCandidate c in candidates)
        if (c.id.isNotEmpty)
          CompanionLibraryRecord(
            kind: switch (c.item.kind) {
              CompanionContinueKind.video => CompanionLibraryItemKind.video,
              CompanionContinueKind.manga => CompanionLibraryItemKind.manga,
              CompanionContinueKind.book =>
                audiobookIds.contains(c.id)
                    ? CompanionLibraryItemKind.audiobook
                    : CompanionLibraryItemKind.book,
            },
            key: c.id,
            title: c.item.title,
            subtitle: c.item.subtitle.isEmpty ? null : c.item.subtitle,
            progress: c.item.progress,
            progressLabel: c.item.progress == null
                ? null
                : t.second_screen_library_data_progress_percent(
                    n: (c.item.progress! * 100).round(),
                  ),
            recentAt: c.recentAt,
            resolveCover: () async {
              final String path = await c.resolveCover?.call() ?? '';
              return path.isEmpty ? null : path;
            },
          ),
    ];
  }

  ServerContinueFeed get _feed => ServerContinueFeed.of(_db);

  @override
  List<CompanionLibraryRecord> continueServer() => <CompanionLibraryRecord>[
    for (final ServerContinueCandidate c in _feed.current)
      CompanionLibraryRecord(
        kind: CompanionLibraryItemKind.serverItem,
        key: '$_feedKey/${Uri.encodeComponent(c.key)}',
        title: c.title,
        subtitle: c.collectionName ?? c.serverName,
        progress: c.progress,
        progressLabel: c.badgeLabel,
        recentAt: c.recentMs,
        hasRemoteCover: c.coverUrl != null,
      ),
  ];

  // ---- servers -------------------------------------------------------------

  static const String _feedKey = 'feed';

  Future<List<MediaServerConfig>> _mediaServers() =>
      SyncRepository(_db).getMediaServers();

  List<AudiobookshelfServerConfig> _absServers() =>
      <AudiobookshelfServerConfig>[
        for (final AudiobookshelfServerConfig s
            in _app.prefsRepo.discoveryAudiobookshelfServers)
          if (s.enabled && s.isSignedIn) s,
      ];

  static String _mediaServerKey(MediaServerConfig c) =>
      '${c.kind.wireName}.${Uri.encodeComponent(c.sourceId)}';

  static String _absKey(AudiobookshelfServerConfig c) =>
      'abs.${Uri.encodeComponent(c.id)}';

  @override
  Future<List<CompanionLibraryRecord>> servers() async =>
      <CompanionLibraryRecord>[
        for (final MediaServerConfig c in await _mediaServers())
          CompanionLibraryRecord(
            kind: CompanionLibraryItemKind.server,
            key: _mediaServerKey(c),
            title: c.buildBrowser().displayName,
            subtitle: c.accountName,
          ),
        for (final AudiobookshelfServerConfig c in _absServers())
          CompanionLibraryRecord(
            kind: CompanionLibraryItemKind.server,
            key: _absKey(c),
            title: c.name,
            subtitle: 'Audiobookshelf',
          ),
        for (final KavitaServerConfig c in _app.prefsRepo.kavitaServers)
          CompanionLibraryRecord(
            kind: CompanionLibraryItemKind.mainOnly,
            key: CompanionLibraryMainTarget.libraryTab.wire,
            title: c.name,
            subtitle: 'Kavita · ${t.second_screen_library_data_server_on_main}',
            mainTarget: CompanionLibraryMainTarget.libraryTab,
          ),
      ];

  /// `<serverKey>[/<id>]` → (server key, rest).
  static (String, String?) _splitServerKey(String key) {
    final int slash = key.indexOf('/');
    return slash < 0
        ? (key, null)
        : (key.substring(0, slash), key.substring(slash + 1));
  }

  Future<MediaServerConfig?> _mediaServer(String serverKey) async {
    for (final MediaServerConfig c in await _mediaServers()) {
      if (_mediaServerKey(c) == serverKey) return c;
    }
    return null;
  }

  AudiobookshelfServerConfig? _abs(String serverKey) {
    for (final AudiobookshelfServerConfig c in _absServers()) {
      if (_absKey(c) == serverKey) return c;
    }
    return null;
  }

  @override
  Future<CompanionLibraryPage> serverChildren(
    String parentRef, {
    required String query,
    required int offset,
    required int limit,
  }) async {
    final CompanionLibraryItemKind? kind = CompanionLibraryRef.kindOf(
      parentRef,
    );
    final (String serverKey, String? id) = _splitServerKey(
      CompanionLibraryRef.keyOf(parentRef),
    );
    if (serverKey.startsWith('abs.')) {
      final AudiobookshelfServerConfig? server = _abs(serverKey);
      final AudiobookshelfApi? api = server == null
          ? null
          : _app.audiobookshelfApis.apiFor(server);
      if (server == null || api == null) {
        throw StateError('$parentRef is gone');
      }
      if (kind == CompanionLibraryItemKind.server) {
        final List<AudiobookshelfLibrary> libraries = <AudiobookshelfLibrary>[
          for (final AudiobookshelfLibrary l in await api.libraries())
            if (l.isBookLibrary) l,
        ];
        return _staticPage(
          <CompanionLibraryItem>[
            for (final AudiobookshelfLibrary l in libraries)
              CompanionLibraryItem(
                ref: CompanionLibraryRef.of(
                  CompanionLibraryItemKind.serverLibrary,
                  '$serverKey/${Uri.encodeComponent(l.id)}',
                ),
                kind: CompanionLibraryItemKind.serverLibrary,
                title: l.name,
              ),
          ],
          query,
          offset,
          limit,
          server.name,
        );
      }
      final String libraryId = Uri.decodeComponent(id ?? '');
      final List<AudiobookshelfItem> rows;
      final int pageOffset;
      bool hasMore = false;
      int? total;
      int? next;
      if (query.isNotEmpty) {
        // The library page's own search (server-side, not paged).
        rows = offset > 0
            ? const <AudiobookshelfItem>[]
            : await api.search(libraryId, query, limit: 60);
        pageOffset = offset;
      } else {
        final int page = offset ~/ limit;
        final AudiobookshelfItemPage result = await api.libraryItems(
          libraryId,
          page: page,
          limit: limit,
        );
        rows = result.items;
        pageOffset = page * limit;
        hasMore = result.hasMore;
        total = result.total;
        next = (page + 1) * limit;
      }
      final List<CompanionLibraryItem> items = <CompanionLibraryItem>[];
      for (final AudiobookshelfItem item in rows) {
        if (item.hasNoAudio) continue;
        final String ref = CompanionLibraryRef.of(
          CompanionLibraryItemKind.serverItem,
          '$serverKey/${Uri.encodeComponent(item.id)}',
        );
        _serverItems[ref] = _ServerItemCacheEntry.abs(server, api, item);
        items.add(
          CompanionLibraryItem(
            ref: ref,
            kind: CompanionLibraryItemKind.serverItem,
            title: item.title,
            subtitle: item.authorName,
            hasRemoteCover: true,
          ),
        );
      }
      return CompanionLibraryPage(
        items: items,
        offset: pageOffset,
        total: total,
        hasMore: hasMore,
        nextOffset: hasMore ? next : null,
      );
    }
    final MediaServerConfig? config = await _mediaServer(serverKey);
    if (config == null) throw StateError('$parentRef is gone');
    final MediaServerBrowser browser = config.buildBrowser();
    if (kind == CompanionLibraryItemKind.server) {
      return _staticPage(
        <CompanionLibraryItem>[
          for (final MediaServerLibrary l in await browser.listLibraries())
            CompanionLibraryItem(
              ref: CompanionLibraryRef.of(
                CompanionLibraryItemKind.serverLibrary,
                '$serverKey/${Uri.encodeComponent(l.id)}',
              ),
              kind: CompanionLibraryItemKind.serverLibrary,
              title: l.name,
            ),
        ],
        query,
        offset,
        limit,
        browser.displayName,
      );
    }
    final String parentId = Uri.decodeComponent(id ?? '');
    final MediaServerPage page = query.isNotEmpty
        ? await browser.search(query, startIndex: offset, limit: limit)
        : await browser.listChildren(
            parentId: parentId,
            startIndex: offset,
            limit: limit,
          );
    final List<CompanionLibraryItem> items = <CompanionLibraryItem>[];
    for (final MediaServerItem item in page.items) {
      final CompanionLibraryItemKind itemKind = item.isPlayable
          ? CompanionLibraryItemKind.serverItem
          : CompanionLibraryItemKind.serverFolder;
      final String ref = CompanionLibraryRef.of(
        itemKind,
        '$serverKey/${Uri.encodeComponent(item.id)}',
      );
      _serverItems[ref] = _ServerItemCacheEntry.media(browser, item, parentRef);
      final double? fraction = item.played
          ? null
          : (item.durationMs != null &&
                item.durationMs! > 0 &&
                item.positionMs > 0)
          ? (item.positionMs / item.durationMs!).clamp(0.0, 1.0)
          : null;
      items.add(
        CompanionLibraryItem(
          ref: ref,
          kind: itemKind,
          title: item.type == MediaServerItemType.episode
              ? mediaServerDisplayTitle(item)
              : item.name,
          subtitle: item.productionYear?.toString(),
          progress: fraction,
          finished: item.played,
          count: item.episodeCount ?? item.childCount,
          hasRemoteCover: browser.coverUrl(item.coverItem) != null,
        ),
      );
    }
    return CompanionLibraryPage(
      items: items,
      offset: offset,
      total: query.isNotEmpty ? null : page.totalCount,
      hasMore: page.hasMore,
      nextOffset: page.hasMore ? page.nextStartIndex : null,
    );
  }

  static CompanionLibraryPage _staticPage(
    List<CompanionLibraryItem> all,
    String query,
    int offset,
    int limit,
    String title,
  ) {
    final String needle = query.trim().toLowerCase();
    final List<CompanionLibraryItem> rows = needle.isEmpty
        ? all
        : <CompanionLibraryItem>[
            for (final CompanionLibraryItem i in all)
              if (i.title.toLowerCase().contains(needle)) i,
          ];
    final int start = offset > rows.length ? rows.length : offset;
    final int end = start + limit > rows.length ? rows.length : start + limit;
    return CompanionLibraryPage(
      items: rows.sublist(start, end),
      offset: start,
      total: rows.length,
      hasMore: end < rows.length,
      title: title,
    );
  }

  // ---- details -------------------------------------------------------------

  @override
  Future<CompanionDetailsSource?> details(String ref) async {
    final CompanionLibraryItemKind? kind = CompanionLibraryRef.kindOf(ref);
    final String key = CompanionLibraryRef.keyOf(ref);
    switch (kind) {
      case CompanionLibraryItemKind.book ||
          CompanionLibraryItemKind.manga ||
          CompanionLibraryItemKind.audiobook:
        return _bookDetails(ref, key);
      case CompanionLibraryItemKind.video:
        return _videoDetails(key);
      case CompanionLibraryItemKind.collection:
        return _collectionDetails(ref, key);
      case CompanionLibraryItemKind.musicAlbum:
        return _albumDetails(key);
      case CompanionLibraryItemKind.musicTrack:
        final MusicTrackRow? track = await _db.getMusicTrack(key);
        if (track == null) return null;
        final String? albumUid = track.albumUid;
        final MusicAlbumRow? album = albumUid == null
            ? null
            : await _db.getMusicAlbum(albumUid);
        return CompanionDetailsSource(
          record: _trackRecord(track, album),
          author: track.artistCredit ?? album?.albumArtistCredit,
          genres: <String>[?track.genre],
          year: track.year,
          series: album?.title,
          runtimeMinutes: track.durationMs == null
              ? null
              : (track.durationMs! / 60000).round(),
        );
      case CompanionLibraryItemKind.serverItem:
        return _serverItemDetails(ref);
      case CompanionLibraryItemKind.musicArtist ||
          CompanionLibraryItemKind.musicPlaylist ||
          CompanionLibraryItemKind.server ||
          CompanionLibraryItemKind.serverLibrary ||
          CompanionLibraryItemKind.serverFolder ||
          CompanionLibraryItemKind.mainOnly ||
          null:
        return null;
    }
  }

  Future<CompanionDetailsSource?> _bookDetails(String ref, String key) async {
    CompanionLibraryRecord? record;
    for (final CompanionLibraryRecord r in await books()) {
      if (r.ref == ref) record = r;
    }
    if (record == null) return null;
    final String bookKey = ReaderFushiSource.parseBookKey(key) ?? '';
    final EpubBookRow? row = bookKey.isEmpty
        ? null
        : await _db.getEpubBook(bookKey);
    final OnlineMangaLibraryEntry? online = row == null
        ? null
        : OnlineMangaLibraryEntry.tryParse(row.sourceMetadata);
    final ReaderPosition? position = row == null || row.uid.isEmpty
        ? null
        : await ReaderPositionRepository(_db).findByBookUid(row.uid);
    final List<CompanionEntrySource> entries;
    final CompanionEntriesKind? entriesKind;
    if (online != null) {
      // Sources list newest first; show reading order.
      final int? currentIndex = online.currentChapterIndex;
      final List<OnlineMangaChapter> chapters = online.chapters;
      entries = <CompanionEntrySource>[
        for (int i = chapters.length - 1; i >= 0; i--)
          CompanionEntrySource(
            id: chapters[i].key,
            title: chapters[i].name,
            finished: currentIndex != null && i > currentIndex,
            current: currentIndex == i,
          ),
      ];
      entriesKind = CompanionEntriesKind.chapters;
    } else if (row != null && record.kind != CompanionLibraryItemKind.manga) {
      entries = _tocEntries(row, position?.sectionIndex);
      entriesKind = CompanionEntriesKind.chapters;
    } else {
      entries = const <CompanionEntrySource>[];
      entriesKind = null;
    }
    final int? collectionId = record.collectionId;
    final CollectionScrapeMetaRow? scrape = collectionId == null
        ? null
        : await _db.getCollectionScrapeMeta(collectionId);
    return CompanionDetailsSource(
      record: record,
      author: online?.series.byline ?? row?.author,
      description: online?.series.description,
      genres: online?.series.genreLabels ?? const <String>[],
      rating: scrape?.rating,
      ratingVotes: scrape?.ratingCount,
      entriesKind: entriesKind,
      entries: entries,
      canOpen: bookKey.isNotEmpty,
      canMarkFinished: bookKey.isNotEmpty,
    );
  }

  /// TOC entries mapped onto spine sections (by href), the current one = the
  /// last entry at or before the saved section.
  static List<CompanionEntrySource> _tocEntries(
    EpubBookRow row,
    int? sectionIndex,
  ) {
    final String? tocJson = row.tocJson;
    if (tocJson == null || tocJson.isEmpty) {
      return const <CompanionEntrySource>[];
    }
    final Map<String, int> sectionByHref = <String, int>{};
    try {
      final List<dynamic> chapters =
          jsonDecode(row.chaptersJson) as List<dynamic>;
      for (int i = 0; i < chapters.length; i++) {
        final Object? href = (chapters[i] as Map<String, dynamic>)['href'];
        if (href is String) sectionByHref[href] = i;
      }
      final List<dynamic> toc = jsonDecode(tocJson) as List<dynamic>;
      final List<({String title, int? section})> items =
          <({String title, int? section})>[
            for (final dynamic e in toc)
              (
                title: ((e as Map<String, dynamic>)['title'] as String?) ?? '',
                section:
                    sectionByHref[((e['href'] as String?) ?? '')
                        .split('#')
                        .first],
              ),
          ];
      int current = -1;
      if (sectionIndex != null) {
        for (int i = 0; i < items.length; i++) {
          final int? s = items[i].section;
          if (s != null && s <= sectionIndex) current = i;
        }
      }
      return <CompanionEntrySource>[
        for (int i = 0; i < items.length; i++)
          if (items[i].title.trim().isNotEmpty)
            CompanionEntrySource(
              id: '$i',
              title: items[i].title,
              finished: current >= 0 && i < current,
              current: i == current,
            ),
      ];
    } on FormatException {
      return const <CompanionEntrySource>[];
    } on TypeError {
      return const <CompanionEntrySource>[];
    }
  }

  Future<CompanionDetailsSource?> _videoDetails(String bookUid) async {
    final _VideoLibrary lib = await _videoLibrary();
    VideoBookRow? row;
    for (final VideoBookRow v in lib.books) {
      if (v.bookUid == bookUid) row = v;
    }
    if (row == null) return null;
    final CompanionLibraryRecord record = _videoRecord(row, lib);
    final int? collectionId = record.collectionId;
    VideoMetadataWorkRow? work = collectionId == null
        ? null
        : await _db.resolveVideoMetadataWorkForCollection(collectionId);
    work ??= await _db.getVideoMetadataWorkByBook(bookUid);
    final List<VideoMetadataEpisodeRow> episodes = await _db
        .getVideoMetadataEpisodesByBook(bookUid);
    final VideoMetadataEpisodeRow? episode = episodes.isEmpty
        ? null
        : episodes.first;
    final CollectionScrapeMetaRow? scrape = collectionId == null
        ? null
        : await _db.getCollectionScrapeMeta(collectionId);
    return CompanionDetailsSource(
      record: record,
      description: _firstText(<String?>[
        episode?.overview,
        work?.overview,
        scrape?.summary,
      ]),
      rating: work?.rating ?? scrape?.rating,
      ratingVotes: work?.rating != null
          ? work?.ratingCount
          : scrape?.ratingCount,
      year: work?.year,
      originalTitle: work?.originalTitle,
      runtimeMinutes: episode?.runtimeMinutes ?? work?.runtimeMinutes,
      cast: work == null ? const <String>[] : await _cast(work.id),
      canMarkFinished: true,
    );
  }

  Future<CompanionDetailsSource?> _collectionDetails(
    String ref,
    String key,
  ) async {
    final int slash = key.indexOf('/');
    final CompanionLibrarySection section = CompanionLibrarySection.fromWire(
      key.substring(0, slash),
    );
    final int? id = int.tryParse(key.substring(slash + 1));
    if (id == null) return null;
    MediaCollectionRow? collection;
    for (final MediaCollectionRow c in await _db.getAllMediaCollections()) {
      if (c.id == id) collection = c;
    }
    if (collection == null) return null;
    final List<CompanionLibraryRecord> members =
        <CompanionLibraryRecord>[
          for (final CompanionLibraryRecord r
              in section == CompanionLibrarySection.video
                  ? await videos()
                  : await books())
            if (r.collectionId == id &&
                CompanionLibraryService.sectionOf(r.kind) == section)
              r,
        ]..sort(
          (CompanionLibraryRecord a, CompanionLibraryRecord b) =>
              (a.sortIndex ?? 0).compareTo(b.sortIndex ?? 0),
        );
    if (members.isEmpty) return null;
    final String? current = companionCollectionContinueKey(members);
    final bool video = section == CompanionLibrarySection.video;
    final Map<String, int> numbers = <String, int>{};
    final Map<String, int?> runtimes = <String, int?>{};
    final Map<String, String?> episodeTitles = <String, String?>{};
    final Map<String, VideoBookRow> rows = <String, VideoBookRow>{};
    if (video) {
      for (final VideoBookRow v in await VideoBookRepository(
        _db,
      ).listForShelf()) {
        rows[v.bookUid] = v;
      }
      for (final CompanionLibraryRecord m in members) {
        final List<VideoMetadataEpisodeRow> eps = await _db
            .getVideoMetadataEpisodesByBook(m.key);
        if (eps.isNotEmpty) {
          if (eps.first.episodeNumber case final int n) numbers[m.key] = n;
          runtimes[m.key] = eps.first.runtimeMinutes;
          episodeTitles[m.key] = eps.first.title;
        }
      }
    }
    final VideoMetadataWorkRow? work = video
        ? await _db.resolveVideoMetadataWorkForCollection(id)
        : null;
    final CollectionScrapeMetaRow? scrape = await _db.getCollectionScrapeMeta(
      id,
    );
    int index = 0;
    final List<CompanionEntrySource> entries = <CompanionEntrySource>[
      for (final CompanionLibraryRecord m in members)
        CompanionEntrySource(
          id: m.key,
          title: video && numbers[m.key] != null
              ? (episodeTitles[m.key] ?? '')
              : m.title,
          number: video ? (numbers[m.key] ?? ++index) : null,
          positionMs: video && !m.finished
              ? rows[m.key]?.lastPositionMs ?? 0
              : 0,
          runtimeMinutes: runtimes[m.key],
          finished: m.finished,
          current: m.key == current,
        ),
    ];
    final String? author = video ? null : members.first.subtitle;
    final CompanionLibraryRecord record = CompanionLibraryRecord(
      kind: CompanionLibraryItemKind.collection,
      key: key,
      title: collection.name,
      count: members.length,
      finished: members.every((CompanionLibraryRecord m) => m.finished),
      resolveCover: () async {
        final String? own = await dashboardVideoCoverPath(
          collectionCovers: <String?>[collection!.coverPath],
          ownCover: null,
          exists: (String path) => File(path).exists(),
        );
        if (own != null) return own;
        for (final CompanionLibraryRecord m in members) {
          final String? path = await m.resolveCover?.call();
          if (path != null) return path;
        }
        return null;
      },
    );
    return CompanionDetailsSource(
      record: record,
      author: author,
      description: _firstText(<String?>[work?.overview, scrape?.summary]),
      rating: work?.rating ?? scrape?.rating,
      ratingVotes: work?.rating != null
          ? work?.ratingCount
          : scrape?.ratingCount,
      year: work?.year,
      originalTitle: work?.originalTitle ?? scrape?.originalTitle,
      cast: work == null ? const <String>[] : await _cast(work.id),
      entriesKind: video
          ? CompanionEntriesKind.episodes
          : CompanionEntriesKind.items,
      entries: entries,
      canMarkFinished: video,
    );
  }

  Future<List<String>> _cast(int workId) async {
    final List<String> names = <String>[];
    for (final VideoMetadataCreditRow c in await _db.getVideoMetadataCredits(
      workId: workId,
    )) {
      if (!const <String>{
        'actor',
        'voice_actor',
        'cast',
      }.contains(c.creditKind)) {
        continue;
      }
      final VideoMetadataPersonRow? person = await _db.getVideoMetadataPerson(
        c.personKey,
      );
      final String name = person?.name.trim() ?? '';
      if (name.isNotEmpty && !names.contains(name)) names.add(name);
      if (names.length >= 6) break;
    }
    return names;
  }

  Future<CompanionDetailsSource?> _albumDetails(String albumUid) async {
    final MusicLibrarySnapshot snap = await MusicLibrarySnapshot.load(_db);
    final MusicAlbumRow? album = snap.albumByUid[albumUid];
    if (album == null) return null;
    final List<MusicTrackRow> tracks = snap.tracksOfAlbum(albumUid);
    final String? released = album.releaseDate;
    return CompanionDetailsSource(
      record: CompanionLibraryRecord(
        kind: CompanionLibraryItemKind.musicAlbum,
        key: album.albumUid,
        title: album.title,
        subtitle: album.albumArtistCredit,
        count: tracks.length,
        resolveCover: () => _existing(album.coverPath),
      ),
      author: album.albumArtistCredit,
      year: released == null || released.length < 4
          ? null
          : int.tryParse(released.substring(0, 4)),
      released: released,
      entriesKind: CompanionEntriesKind.tracks,
      entries: <CompanionEntrySource>[
        for (final MusicTrackRow t in tracks)
          CompanionEntrySource(
            id: t.trackUid,
            title: t.trackNo == null ? t.title : '${t.trackNo}. ${t.title}',
            durationMs: t.durationMs,
          ),
      ],
    );
  }

  Future<CompanionDetailsSource?> _serverItemDetails(String ref) async {
    final (String serverKey, String? _) = _splitServerKey(
      CompanionLibraryRef.keyOf(ref),
    );
    if (serverKey == _feedKey) {
      for (final CompanionLibraryRecord r in continueServer()) {
        if (r.ref == ref) return CompanionDetailsSource(record: r);
      }
      return null;
    }
    final _ServerItemCacheEntry? cached = _serverItems[ref];
    if (cached == null) return null;
    final MediaServerItem? item = cached.mediaItem;
    final AudiobookshelfItem? abs = cached.absItem;
    final CompanionLibraryRecord record = CompanionLibraryRecord(
      kind: CompanionLibraryItemKind.serverItem,
      key: CompanionLibraryRef.keyOf(ref),
      title: item != null
          ? (item.type == MediaServerItemType.episode
                ? mediaServerDisplayTitle(item)
                : item.name)
          : abs!.title,
      subtitle: abs?.authorName,
      finished: item?.played ?? false,
      hasRemoteCover: true,
    );
    if (item != null) {
      return CompanionDetailsSource(
        record: record,
        description: item.overview,
        genres: item.genres,
        rating: item.communityRating,
        year: item.productionYear,
        originalTitle: item.originalTitle,
        runtimeMinutes: item.durationMs == null
            ? null
            : (item.durationMs! / 60000).round(),
      );
    }
    final double? seconds = abs!.durationSeconds;
    return CompanionDetailsSource(
      record: record,
      author: abs.authorName,
      narrator: abs.narratorName,
      series: abs.seriesName,
      year: int.tryParse(abs.publishedYear ?? ''),
      runtimeMinutes: seconds == null ? null : (seconds / 60).round(),
    );
  }

  // ---- covers --------------------------------------------------------------

  @override
  Future<String?> cover(String ref) async {
    final CompanionLibraryItemKind? kind = CompanionLibraryRef.kindOf(ref);
    switch (kind) {
      case CompanionLibraryItemKind.serverItem ||
          CompanionLibraryItemKind.serverFolder:
        return _serverCover(ref);
      case CompanionLibraryItemKind.book ||
          CompanionLibraryItemKind.manga ||
          CompanionLibraryItemKind.audiobook:
        for (final CompanionLibraryRecord r in await books()) {
          if (r.ref == ref) return r.resolveCover?.call();
        }
        return null;
      case CompanionLibraryItemKind.video:
        for (final CompanionLibraryRecord r in await videos()) {
          if (r.ref == ref) return r.resolveCover?.call();
        }
        return null;
      case CompanionLibraryItemKind.musicAlbum:
        return _existing(
          (await _db.getMusicAlbum(CompanionLibraryRef.keyOf(ref)))?.coverPath,
        );
      case CompanionLibraryItemKind.musicTrack ||
          CompanionLibraryItemKind.musicArtist ||
          CompanionLibraryItemKind.musicPlaylist ||
          CompanionLibraryItemKind.collection ||
          CompanionLibraryItemKind.server ||
          CompanionLibraryItemKind.serverLibrary ||
          CompanionLibraryItemKind.mainOnly ||
          null:
        return null;
    }
  }

  /// A media-server cover as a local file: the same disk caches the library
  /// cards fill (`RemoteCoverImage` → [RemoteCoverCache] for Jellyfin / Plex,
  /// [AppImageCacheManager] for Audiobookshelf), fetched through the same
  /// client when not cached yet.
  Future<String?> _serverCover(String ref) async {
    final (String serverKey, String? rest) = _splitServerKey(
      CompanionLibraryRef.keyOf(ref),
    );
    if (serverKey == _feedKey) {
      final String candidateKey = Uri.decodeComponent(rest ?? '');
      for (final ServerContinueCandidate c in _feed.current) {
        if (c.key != candidateKey) continue;
        final String? url = c.coverUrl;
        if (url == null) return null;
        final String cacheKey = c.coverCacheKey ?? c.key;
        if (c.coverFetcher case final RemoteCoverFetcher fetcher?) {
          return _remoteCoverFile(
            '${fetcher.coverCacheNamespace}|$cacheKey',
            () => fetcher.fetchRemoteCover(url),
          );
        }
        return (await AppImageCacheManager().getSingleFile(
          url,
          key: cacheKey,
        )).path;
      }
      return null;
    }
    final _ServerItemCacheEntry? cached = _serverItems[ref];
    if (cached == null) return null;
    final MediaServerItem? item = cached.mediaItem;
    final MediaServerBrowser? browser = cached.browser;
    if (item != null && browser != null) {
      final MediaServerItem coverItem = item.coverItem;
      final String? url = browser.coverUrl(coverItem);
      if (url == null || url.isEmpty) return null;
      return _remoteCoverFile(
        '${browser.coverCacheNamespace}|${coverItem.id}:'
        '${MediaServerImageKind.primary.name}',
        () => browser.fetchRemoteCover(url),
      );
    }
    final AudiobookshelfItem? abs = cached.absItem;
    final AudiobookshelfApi? api = cached.absApi;
    final AudiobookshelfServerConfig? server = cached.absServer;
    if (abs == null || api == null || server == null) return null;
    return (await AppImageCacheManager().getSingleFile(
      api.coverUri(abs.id, width: 400).toString(),
      key: 'abs:${server.id}:${abs.id}',
    )).path;
  }

  static Future<String?> _remoteCoverFile(
    String cacheKey,
    Future<Uint8List> Function() fetch,
  ) async {
    final File? hit = await RemoteCoverCache.cachedFile(cacheKey);
    if (hit != null) return hit.path;
    final Uint8List bytes = await fetch();
    if (bytes.isEmpty) return null;
    await RemoteCoverCache.write(cacheKey, bytes);
    return (await RemoteCoverCache.cachedFile(cacheKey))?.path;
  }

  // ---- top / open ----------------------------------------------------------

  @override
  Future<CompanionLibraryRecord?> currentTop() async {
    final AppModel app = _app;
    final MediaItem? item = app.isMediaOpen ? app.currentMediaItem : null;
    if (item != null) {
      for (final CompanionLibraryRecord r in await books()) {
        if (r.key == item.mediaIdentifier) return r;
      }
    }
    final String? videoUid = ExternalMediaNavigation.instance.activeVideoUid;
    if (videoUid != null && videoUid.isNotEmpty) {
      final VideoBookRow? row = await VideoBookRepository(
        _db,
      ).getByBookUid(videoUid);
      if (row != null) {
        return CompanionLibraryRecord(
          kind: CompanionLibraryItemKind.video,
          key: row.bookUid,
          title: row.title,
          coverPath: row.coverPath,
        );
      }
    }
    return null;
  }

  @override
  Future<bool> returnToHome() async {
    final NavigatorState? navigator = _app.navigatorKey.currentState;
    if (navigator == null) return false;
    final ExternalMediaNavigation media = ExternalMediaNavigation.instance;
    bool atHome = false;
    await media.navigate(() async {
      await unwindToHomeRoute(navigator, media: media);
      atHome = navigator.mounted && !navigator.canPop();
    });
    return atHome;
  }

  WidgetRef _widgetRef() {
    final OpContext? op = appOpContext;
    if (op == null) throw StateError('the main screen is not ready');
    return op.ref;
  }

  BuildContext? get _context {
    final BuildContext? context = _app.navigatorKey.currentContext;
    return context != null && context.mounted ? context : null;
  }

  @override
  Future<bool> open(String ref, {String? entry}) async {
    final CompanionLibraryItemKind? kind = CompanionLibraryRef.kindOf(ref);
    final String key = CompanionLibraryRef.keyOf(ref);
    switch (kind) {
      case CompanionLibraryItemKind.book ||
          CompanionLibraryItemKind.manga ||
          CompanionLibraryItemKind.audiobook:
        return _openBook(
          key,
          audiobook: kind == CompanionLibraryItemKind.audiobook,
        );
      case CompanionLibraryItemKind.video:
        return _openVideo(entry ?? key);
      case CompanionLibraryItemKind.collection:
        final CompanionDetailsSource? details = await _collectionDetails(
          ref,
          key,
        );
        if (details == null) return false;
        String? target = entry;
        if (target == null) {
          for (final CompanionEntrySource e in details.entries) {
            if (e.current) target = e.id;
          }
          target ??= details.entries.isEmpty ? null : details.entries.first.id;
        }
        if (target == null) return false;
        return key.startsWith('${CompanionLibrarySection.video.wire}/')
            ? _openVideo(
                target,
                collectionId: int.tryParse(key.split('/').last),
              )
            : _openBook(target, audiobook: false);
      case CompanionLibraryItemKind.musicAlbum:
        return _playAlbum(key, startTrack: entry);
      case CompanionLibraryItemKind.musicTrack:
        final MusicTrackRow? track = await _db.getMusicTrack(key);
        final String? albumUid = track?.albumUid;
        if (track == null) return false;
        if (albumUid != null) return _playAlbum(albumUid, startTrack: key);
        await _app.musicSession.engine.playQueue(<MusicPlayItem>[
          musicPlayItemOf(track),
        ], context: MusicQueueContext.album);
        unawaited(openWidgetMusicPlayer(_app));
        return true;
      case CompanionLibraryItemKind.serverItem:
        return _openServerItem(ref);
      case CompanionLibraryItemKind.musicArtist ||
          CompanionLibraryItemKind.musicPlaylist ||
          CompanionLibraryItemKind.server ||
          CompanionLibraryItemKind.serverLibrary ||
          CompanionLibraryItemKind.serverFolder ||
          CompanionLibraryItemKind.mainOnly ||
          null:
        return false;
    }
  }

  /// The books shelf's card path ([AppModel.openMedia]; audiobooks through
  /// the reader source like `_openSrtBook`). Does not wait for the book to
  /// close.
  Future<bool> _openBook(
    String mediaIdentifier, {
    required bool audiobook,
  }) async {
    final List<MediaItem> items = await _ref.read(
      fushiBooksProvider(JapaneseLanguage.instance).future,
    );
    MediaItem? item;
    for (final MediaItem i in items) {
      if (i.mediaIdentifier == mediaIdentifier) item = i;
    }
    if (item == null) return false;
    await _app.openMedia(
      ref: _widgetRef(),
      mediaSource: audiobook
          ? ReaderFushiSource.instance
          : item.getMediaSource(appModel: _app),
      item: item,
      waitUntilClosed: false,
    );
    return true;
  }

  /// The video library's path ([openLocalVideoBook] with the playlist
  /// collection, like the home "continue" card).
  Future<bool> _openVideo(String bookUid, {int? collectionId}) async {
    final VideoBookRepository repo = VideoBookRepository(_db);
    final VideoBookRow? row = await repo.getByBookUid(bookUid);
    final BuildContext? context = _context;
    if (row == null || context == null) return false;
    final int? playlist =
        collectionId ??
        await resolveVideoPlaylistCollectionId(repo: repo, bookUid: bookUid);
    if (!context.mounted) return false;
    unawaited(
      openLocalVideoBook(
        context: context,
        repo: repo,
        bookUid: bookUid,
        playlistCollectionId: playlist,
      ),
    );
    return true;
  }

  /// The album page's "play" (from [startTrack] like tapping a track), then
  /// the player page on top (the mini bar's tap target).
  Future<bool> _playAlbum(String albumUid, {String? startTrack}) async {
    final MusicLibrarySnapshot snap = await MusicLibrarySnapshot.load(_db);
    final MusicAlbumRow? album = snap.albumByUid[albumUid];
    if (album == null) return false;
    final List<MusicTrackRow> tracks = snap.tracksOfAlbum(albumUid);
    if (tracks.isEmpty) return false;
    final int start = startTrack == null
        ? 0
        : tracks.indexWhere((MusicTrackRow t) => t.trackUid == startTrack);
    final MusicPlayerEngine engine = _app.musicSession.engine;
    await engine.playQueue(
      <MusicPlayItem>[
        for (final MusicTrackRow t in tracks) musicPlayItemOf(t, album: album),
      ],
      startIndex: start < 0 ? 0 : start,
      context: MusicQueueContext.album,
      source: MusicPlaySource.album(
        album.albumUid,
        title: album.title,
        cover: album.coverPath,
      ),
    );
    unawaited(openWidgetMusicPlayer(_app));
    return true;
  }

  Future<bool> _openServerItem(String ref) async {
    final BuildContext? context = _context;
    if (context == null) return false;
    final (String serverKey, String? rest) = _splitServerKey(
      CompanionLibraryRef.keyOf(ref),
    );
    if (serverKey == _feedKey) {
      final String candidateKey = Uri.decodeComponent(rest ?? '');
      for (final ServerContinueCandidate c in _feed.current) {
        if (c.key == candidateKey) {
          unawaited(c.open(context));
          return true;
        }
      }
      return false;
    }
    final _ServerItemCacheEntry? cached = _serverItems[ref];
    if (cached == null) return false;
    final MediaServerItem? item = cached.mediaItem;
    final MediaServerBrowser? browser = cached.browser;
    if (item != null && browser != null) {
      final MediaServerSession session = MediaServerSession(
        browser: browser,
        play: (BuildContext context, MediaServerPlayRequest request) =>
            pushMediaServerPlayer(
              context,
              request,
              repo: VideoBookRepository(_db),
            ),
      );
      resumeMediaServerItem(
        context,
        session,
        item,
        siblings: <MediaServerItem>[
          for (final _ServerItemCacheEntry e in _serverItems.values)
            if (e.parentRef == cached.parentRef && e.mediaItem != null)
              e.mediaItem!,
        ],
      );
      return true;
    }
    final AudiobookshelfItem? abs = cached.absItem;
    final AudiobookshelfApi? api = cached.absApi;
    final AudiobookshelfServerConfig? server = cached.absServer;
    if (abs == null || api == null || server == null) return false;
    unawaited(
      Navigator.of(context, rootNavigator: true).push<void>(
        adaptivePageRoute<void>(
          context: context,
          builder: (BuildContext _) =>
              AudiobookshelfItemDetailPage(server: server, api: api, item: abs),
        ),
      ),
    );
    return true;
  }

  // ---- writes --------------------------------------------------------------

  @override
  Future<bool> setFinished(String ref, {required bool finished}) async {
    final CompanionLibraryItemKind? kind = CompanionLibraryRef.kindOf(ref);
    final String key = CompanionLibraryRef.keyOf(ref);
    switch (kind) {
      case CompanionLibraryItemKind.book ||
          CompanionLibraryItemKind.manga ||
          CompanionLibraryItemKind.audiobook:
        // The shelf's "mark finished": EpubBooks.completedAt by bookKey.
        final String bookKey = ReaderFushiSource.parseBookKey(key) ?? '';
        if (bookKey.isEmpty) return false;
        await _db.setEpubBookCompleted(
          bookKey,
          finished ? DateTime.now() : null,
        );
        _ref.invalidate(completedEpubBookKeysProvider);
        return true;
      case CompanionLibraryItemKind.video:
        await setVideosWatched(
          db: _db,
          watched: finished,
          localUids: <String>[key],
        );
        return true;
      case CompanionLibraryItemKind.collection:
        if (!key.startsWith('${CompanionLibrarySection.video.wire}/')) {
          return false;
        }
        final int? id = int.tryParse(key.split('/').last);
        if (id == null) return false;
        await setVideosWatched(
          db: _db,
          watched: finished,
          localUids: <String>[
            for (final CompanionLibraryRecord r in await videos())
              if (r.collectionId == id) r.key,
          ],
        );
        return true;
      case CompanionLibraryItemKind.musicAlbum ||
          CompanionLibraryItemKind.musicTrack ||
          CompanionLibraryItemKind.musicArtist ||
          CompanionLibraryItemKind.musicPlaylist ||
          CompanionLibraryItemKind.server ||
          CompanionLibraryItemKind.serverLibrary ||
          CompanionLibraryItemKind.serverFolder ||
          CompanionLibraryItemKind.serverItem ||
          CompanionLibraryItemKind.mainOnly ||
          null:
        return false;
    }
  }

  @override
  Future<void> openOnMain(CompanionLibraryMainTarget target) async {
    if (target == CompanionLibraryMainTarget.statistics) {
      // Pushed over what is on top, like the home "Today" entry.
      unawaited(openWidgetStats(_app));
      return;
    }
    if (!await returnToHome()) return;
    final HomeTab tab = switch (target) {
      CompanionLibraryMainTarget.onlineManga ||
      CompanionLibraryMainTarget.onlineVideo ||
      CompanionLibraryMainTarget.onlineNovels => HomeTab.browse,
      CompanionLibraryMainTarget.dictionaries => HomeTab.dictionaries,
      CompanionLibraryMainTarget.statistics => HomeTab.home,
      CompanionLibraryMainTarget.libraryTab => _libraryTab(),
    };
    homeShellTabNotifier.value = tab;
    if (tab == HomeTab.browse) {
      externalBrowseRequest.value = BrowseNavigationRequest(BrowseTab.sources);
    }
  }

  /// The library tab of the context on top, else the manga tab (Kavita, the
  /// only server listed as main-screen only).
  HomeTab _libraryTab() => switch (companionContexts.current.library) {
    CompanionLibraryKind.books => HomeTab.books,
    CompanionLibraryKind.video => HomeTab.video,
    CompanionLibraryKind.music => HomeTab.music,
    CompanionLibraryKind.games => HomeTab.games,
    CompanionLibraryKind.manga || null => HomeTab.manga,
  };
}

typedef _Membership = Map<String, ({int collectionId, int sortIndex})>;

class _VideoLibrary {
  const _VideoLibrary({
    required this.books,
    required this.collections,
    required this.membership,
    required this.watchedAt,
    required this.specs,
  });

  final List<VideoBookRow> books;
  final List<MediaCollectionRow> collections;
  final _Membership membership;
  final Map<String, int> watchedAt;
  final Map<String, VideoFileSpecRow> specs;
}

class _ServerItemCacheEntry {
  _ServerItemCacheEntry.media(this.browser, this.mediaItem, this.parentRef)
    : absServer = null,
      absApi = null,
      absItem = null;

  _ServerItemCacheEntry.abs(this.absServer, this.absApi, this.absItem)
    : browser = null,
      mediaItem = null,
      parentRef = null;

  final MediaServerBrowser? browser;
  final MediaServerItem? mediaItem;
  final String? parentRef;
  final AudiobookshelfServerConfig? absServer;
  final AudiobookshelfApi? absApi;
  final AudiobookshelfItem? absItem;
}

/// The member a collection's Continue opens: the most recently watched /
/// read member still in progress, else the first unfinished member after
/// the last finished one, else the first. [members] in collection order.
String? companionCollectionContinueKey(List<CompanionLibraryRecord> members) {
  if (members.isEmpty) return null;
  CompanionLibraryRecord? inProgress;
  for (final CompanionLibraryRecord m in members) {
    if (m.finished || (m.progress ?? 0) <= 0) continue;
    if (inProgress == null || m.recentAt > inProgress.recentAt) inProgress = m;
  }
  if (inProgress != null) return inProgress.key;
  int lastFinished = -1;
  for (int i = 0; i < members.length; i++) {
    if (members[i].finished) lastFinished = i;
  }
  if (lastFinished + 1 < members.length) return members[lastFinished + 1].key;
  return members.first.key;
}

String? _firstText(List<String?> values) {
  for (final String? v in values) {
    final String text = v?.trim() ?? '';
    if (text.isNotEmpty) return text;
  }
  return null;
}

Future<String?> _existing(String? path) async =>
    path != null && path.isNotEmpty && await File(path).exists() ? path : null;
