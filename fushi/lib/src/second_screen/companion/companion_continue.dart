import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/m3u8_playlist.dart'
    show playlistEpisodeCount;
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/sources/manga_fushi_source.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/dashboard_continue_logic.dart';
import 'package:fushi/src/platform/widget_links.dart';
import 'package:fushi/src/second_screen/companion/companion_covers.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';

// The home dashboard's "continue" candidates in the main engine, shared by the
// daily summary (one Continue entry, `companion_main_services.dart`) and the
// Library tab's Continue row (`companion_library_app_data.dart`).

/// A library item that could be the summary's Continue entry.
class CompanionContinueCandidate {
  const CompanionContinueCandidate({
    required this.item,
    required this.recentAt,
    this.resolveCover,
    this.id = '',
  });

  final CompanionContinueItem item;

  /// The library identity: `MediaItem.mediaIdentifier` for books / manga,
  /// `VideoBooks.bookUid` for videos (the Library tab turns it into a ref).
  final String id;

  /// Last activity (epoch ms); the most recent candidate wins.
  final int recentAt;

  /// Looks up the cover file; only run for the winner (cover probing is I/O,
  /// possibly on a network drive, BUG-3756).
  final Future<String> Function()? resolveCover;
}

/// The candidate with the latest activity; null when there is none.
CompanionContinueCandidate? pickCompanionContinue(
  Iterable<CompanionContinueCandidate> candidates,
) {
  CompanionContinueCandidate? best;
  for (final CompanionContinueCandidate c in candidates) {
    if (best == null || c.recentAt > best.recentAt) best = c;
  }
  return best;
}

/// Everything in progress by the home dashboard's "continue" rules (books,
/// manga, videos of enabled modules), any order. Shared by the daily summary
/// (its one Continue entry) and the Library tab's Continue row. [facts]
/// gives the videos' watch times.
Future<List<CompanionContinueCandidate>> collectCompanionContinueCandidates(
  Ref ref, {
  required StatFacts facts,
}) async {
  final AppModel appModel = ref.read(appProvider);
  final ModuleVisibility modules = appModel.moduleVisibility;
  return <CompanionContinueCandidate>[
    if (modules.isEnabled(ModuleId.books) || modules.isEnabled(ModuleId.manga))
      ...await _bookCandidates(appModel),
    if (modules.isEnabled(ModuleId.video))
      ...await _videoCandidates(appModel.database, facts),
  ];
}

/// Books and manga in progress ([isDashboardContinueBook], the home
/// dashboard's rule), latest read time from `reader_positions`.
///
/// Read from the database on every collection, not through the home shelf's
/// providers ([fushiBooksProvider], [bookLastReadAtProvider], ...): those are
/// UI caches the reader refreshes in its exit hook (`closeMedia` ->
/// `onSourceExit`), several awaits after the top context already went back to
/// "none" and the summary was collected, so the summary showed the progress
/// from before the reading session. Collections are triggered by the
/// database's own change stream (`watchDashboardDataChanges`), so the data
/// they read must come from the same place.
Future<List<CompanionContinueCandidate>> _bookCandidates(
  AppModel appModel,
) async {
  final FushiDatabase db = appModel.database;
  final List<MediaItem> books = await ReaderFushiSource.instance.getBooksFromDb(
    appModel: appModel,
  );
  final Map<String, int> lastReadByUid = <String, int>{
    for (final ReaderPositionRow r in await db.getAllReaderPositions())
      r.bookUid: r.updatedAt,
  };
  final Map<String, String> uidByKey = <String, String>{
    for (final EpubBookMeta r in await db.getEpubBookMetas())
      if (r.uid.isNotEmpty) r.bookKey: r.uid,
  };
  final Set<String> completed = await db.getCompletedEpubBookKeys();
  final ModuleVisibility modules = appModel.moduleVisibility;
  final List<CompanionContinueCandidate> result =
      <CompanionContinueCandidate>[];
  for (final MediaItem item in books) {
    if (!isDashboardContinueBook(item, completed)) continue;
    final bool manga =
        item.mediaSourceIdentifier == MangaFushiSource.kUniqueKey;
    if (!modules.isEnabled(manga ? ModuleId.manga : ModuleId.books)) continue;
    final String bookKey =
        ReaderFushiSource.parseBookKey(item.mediaIdentifier) ??
        item.mediaIdentifier;
    final WidgetMediaKind linkKind = manga
        ? WidgetMediaKind.manga
        : WidgetMediaKind.book;
    result.add(
      CompanionContinueCandidate(
        item: CompanionContinueItem(
          kind: manga
              ? CompanionContinueKind.manga
              : CompanionContinueKind.book,
          title: ReaderFushiSource.instance.getDisplayTitleFromMediaItem(item),
          subtitle: item.author ?? '',
          progress: item.duration > 0 ? item.position / item.duration : null,
          link: WidgetContinueLink(
            kind: linkKind,
            id: item.mediaIdentifier,
          ).toUri(),
        ),
        recentAt: lastReadByUid[uidByKey[bookKey] ?? bookKey] ?? 0,
        resolveCover: () async => companionMediaItemCoverPath(appModel, item),
        id: item.mediaIdentifier,
      ),
    );
  }
  return result;
}

/// Videos in progress: a saved position and not finished (the home
/// dashboard's rule); latest watch time from today's stat facts.
Future<List<CompanionContinueCandidate>> _videoCandidates(
  FushiDatabase db,
  StatFacts facts,
) async {
  final List<VideoBookRow> videos = await VideoBookRepository(
    db,
  ).listForShelf();
  final List<VideoBookRow> watching = <VideoBookRow>[
    for (final VideoBookRow v in videos)
      if (v.lastPositionMs > 0 && v.completedAt == null) v,
  ];
  if (watching.isEmpty) return const <CompanionContinueCandidate>[];
  final Map<String, int> watchAt = <String, int>{};
  for (final StatFact w in facts.dailyVideos) {
    if (w.mediaKey.isEmpty) continue;
    if (w.lastActiveMs > (watchAt[w.mediaKey] ?? 0)) {
      watchAt[w.mediaKey] = w.lastActiveMs;
    }
  }
  final Map<String, VideoFileSpecRow> specs = await db.videoFileSpecsByPath(
    <String>[for (final VideoBookRow v in watching) v.videoPath],
  );
  return <CompanionContinueCandidate>[
    for (final VideoBookRow v in watching)
      CompanionContinueCandidate(
        item: CompanionContinueItem(
          kind: CompanionContinueKind.video,
          title: v.title,
          progress: dashboardVideoContinueProgress(
            completed: false,
            positionMs: v.lastPositionMs,
            durationMs: specs[v.videoPath]?.durationMs,
            currentEpisode: v.currentEpisode,
            playlistEpisodeCount: playlistEpisodeCount(v.playlistJson),
          ).fraction,
          link: WidgetContinueLink(
            kind: WidgetMediaKind.video,
            id: v.bookUid,
          ).toUri(),
        ),
        recentAt: watchAt[v.bookUid] ?? v.importedAt ?? 0,
        id: v.bookUid,
        resolveCover: () async =>
            await dashboardVideoCoverPath(
              collectionCovers: const <String?>[],
              ownCover: v.coverPath,
              exists: (String path) => File(path).exists(),
            ) ??
            '',
      ),
  ];
}
