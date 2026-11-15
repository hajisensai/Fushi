/// The local side of a manual tracking link: which local items can be linked,
/// with which kind and progress unit by default, and the search text a link
/// dialog starts with. Shared by the Tracking page's link dialog and the
/// control channel (`ctl_settings_body_tracking.dart`).
library;

import 'package:fushi/src/media/tracking/page/tracking_row_facts.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/collections/collection_season_groups.dart'
    show collectionGroupKeyForFilename, isMultiSeasonGrouped;
import 'package:fushi_engine/media/tracking/local_title_clean.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';

/// A local item that can be linked (video collection, video, book, game).
class MediaTrackingLocalTarget {
  const MediaTrackingLocalTarget({
    required this.type,
    required this.key,
    required this.title,
    TrackingKind? kind,
    List<TrackingKind>? kinds,
    this.initialOffset,
  }) : _kind = kind,
       _kinds = kinds;

  final TrackingMediaType type;
  final String key;
  final String title;
  final TrackingKind? _kind;
  final List<TrackingKind>? _kinds;

  /// Kinds the user may link it as (a PDF: novel or manga, see
  /// [trackingKindsForBookFormat]); one = no choice.
  List<TrackingKind> get kinds {
    final List<TrackingKind>? kinds = _kinds;
    return kinds == null || kinds.isEmpty ? <TrackingKind>[kind] : kinds;
  }

  /// This item linked as [kind] (one of [kinds]).
  MediaTrackingLocalTarget asKind(TrackingKind kind) =>
      MediaTrackingLocalTarget(
        type: type,
        key: key,
        title: title,
        kind: kind,
        kinds: _kinds,
        initialOffset: initialOffset,
      );

  /// The number a new link starts from when the item knows it (a single
  /// video or a media server episode listed on its own: its episode
  /// number, which is what such a link sends); null = the unit's default.
  final int? initialOffset;

  /// The kind the item is tracked as (a book's comes from its format).
  TrackingKind get kind => _kind ?? defaultTrackingKindFor(type);

  bool get isBook => type == TrackingMediaType.book;

  bool get isGame => type == TrackingMediaType.game;
}

/// Kinds a local item of [type] can be linked as.
List<TrackingKind> allowedTrackingKindsFor(TrackingMediaType type) =>
    switch (type) {
      TrackingMediaType.game => const <TrackingKind>[TrackingKind.game],
      TrackingMediaType.book => const <TrackingKind>[
        TrackingKind.novel,
        TrackingKind.manga,
      ],
      _ => const <TrackingKind>[TrackingKind.anime],
    };

/// Progress units a local item of [type] can count in.
List<TrackingProgressMode> allowedTrackingModesFor(TrackingMediaType type) =>
    switch (type) {
      TrackingMediaType.game => const <TrackingProgressMode>[
        TrackingProgressMode.status,
      ],
      TrackingMediaType.book => const <TrackingProgressMode>[
        TrackingProgressMode.chapter,
        TrackingProgressMode.volume,
      ],
      _ => const <TrackingProgressMode>[TrackingProgressMode.episode],
    };

/// The kind of a local item of [type] when nothing else says.
TrackingKind defaultTrackingKindFor(TrackingMediaType type) => switch (type) {
  TrackingMediaType.game => TrackingKind.game,
  TrackingMediaType.book => TrackingKind.novel,
  _ => TrackingKind.anime,
};

/// The progress unit of a new link for a local item of [type].
TrackingProgressMode defaultTrackingModeFor(TrackingMediaType type) =>
    switch (type) {
      TrackingMediaType.game => TrackingProgressMode.status,
      TrackingMediaType.book => TrackingProgressMode.volume,
      _ => TrackingProgressMode.episode,
    };

/// 进度模式的默认偏移：章节 / 收藏状态为 0，其余 1。
int defaultTrackingOffsetFor(TrackingProgressMode mode) =>
    mode == TrackingProgressMode.chapter || mode == TrackingProgressMode.status
    ? 0
    : 1;

/// 落库前的偏移：status 模式下 outbox.progress 存的是收藏 type 本身，任何非零
/// offset 都会把它算成另一个状态，必须钉死为 0；其余夹到 [0, 100000]。
int normalizeTrackingProgressOffset(TrackingProgressMode mode, int? raw) =>
    mode == TrackingProgressMode.status
    ? 0
    : (raw ?? defaultTrackingOffsetFor(mode)).clamp(0, 100000);

/// The search text a link dialog starts with for a local item titled
/// [title]: the best clean search term of the shared title clean-up (release
/// tags, a repeated series name and trailing volume numbers dropped), the
/// same term automatic linking searches first.
///
/// [workTitles] ([trackingWorkTitlesFor]) come first: a video's file name is
/// only the fallback when nothing names the work better.
String trackingInitialQuery(
  String title, {
  List<String> workTitles = const <String>[],
}) {
  for (final String work in workTitles) {
    final String query = localTitleSearchCandidates(work).first.trim();
    if (query.isNotEmpty) return query;
  }
  return localTitleSearchCandidates(title).first;
}

/// Names of the work a video target belongs to, better than its file name,
/// best first: a video's work-level scraped title, the scraped title and
/// the name of a collection holding it; a collection's scraped title and
/// name; a media server season's or episode's series title as the server
/// has it. Empty for books and games (their titles are already the work's).
Future<List<String>> trackingWorkTitlesFor(
  FushiDatabase database,
  TrackingMediaType type,
  String key,
) async => (await loadTrackingRowFacts(database)).of(type.value, key).workTitles;

/// Kinds the local item [type] + [key] may be linked as: a PDF book can be a
/// novel or a manga; anything else has one kind (empty = not a book, the
/// target's own kind applies).
Future<List<TrackingKind>> trackingKindChoicesFor(
  FushiDatabase database,
  TrackingMediaType type,
  String key,
) async {
  if (type != TrackingMediaType.book) return const <TrackingKind>[];
  final EpubBookRow? book = await database.getEpubBook(key);
  if (book == null) return const <TrackingKind>[];
  return trackingKindsForBookFormat(BookFormat.parseOrEpub(book.format));
}

/// Local items that can be linked by hand.
///
/// 多季合集（分组按各集文件名派生）不列为整合集映射目标：一季一条目，
/// 「整个多季合集 → 单个条目」结构性错位，建了也会被上报门控绕开。多季合集的上报走
/// 自动按集通道（季度感知刮削 + 季内集号），单集也仍可手动映射。
Future<List<MediaTrackingLocalTarget>> loadMediaTrackingLocalTargets(
  FushiDatabase database,
) async {
  final List<EpubBookRow> books = await database.getAllEpubBooks();
  final List<VideoBookRow> videos = await database.allVideoBooks();
  final List<GalgameRow> games = await database.getAllGalgames();
  final List<MediaCollectionRow> collections = await database
      .getAllMediaCollections();
  final List<MediaCollectionItemRow> members = await database
      .getAllCollectionItems();
  final Set<int> videoPlaylists = members
      .where((MediaCollectionItemRow row) => row.mediaType == 'video')
      .map((MediaCollectionItemRow row) => row.collectionId)
      .toSet();
  final Map<String, String> videoPathByUid = <String, String>{
    for (final VideoBookRow video in videos) video.bookUid: video.videoPath,
  };
  final Map<int, List<String>> groupKeysByCollection = <int, List<String>>{};
  for (final MediaCollectionItemRow row in members) {
    if (row.mediaType != 'video') continue;
    final String? path = videoPathByUid[row.entryKey];
    if (path == null) continue;
    groupKeysByCollection
        .putIfAbsent(row.collectionId, () => <String>[])
        .add(collectionGroupKeyForFilename(path));
  }
  return <MediaTrackingLocalTarget>[
    for (final MediaCollectionRow collection in collections)
      if (collection.collectionType == 'playlist' &&
          videoPlaylists.contains(collection.id) &&
          !isMultiSeasonGrouped(
            groupKeysByCollection[collection.id] ?? const <String>[],
          ))
        MediaTrackingLocalTarget(
          type: TrackingMediaType.videoCollection,
          key: collection.id.toString(),
          title: collection.name,
        ),
    for (final VideoBookRow video in videos)
      MediaTrackingLocalTarget(
        type: TrackingMediaType.video,
        key: video.bookUid,
        title: video.title,
        initialOffset: videoEpisodeNumberForTracking(video),
      ),
    for (final EpubBookRow book in books)
      MediaTrackingLocalTarget(
        type: TrackingMediaType.book,
        key: book.bookKey,
        title: book.title,
        kind: trackingKindForBookFormat(BookFormat.parseOrEpub(book.format)),
        kinds: trackingKindsForBookFormat(BookFormat.parseOrEpub(book.format)),
      ),
    for (final GalgameRow game in games)
      MediaTrackingLocalTarget(
        type: TrackingMediaType.game,
        key: game.id,
        title: game.name,
      ),
  ];
}
