import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:fushi_engine/media/collections/collection_season_groups.dart'
    show collectionGroupKeyForFilename, isMultiSeasonGrouped;
import 'package:fushi_engine/media/tracking/remote_anime_link.dart';
import 'package:fushi_engine/media/video/media_server_video_path.dart';
import 'package:fushi_engine/media/video/episode_near_end.dart';
import 'package:fushi_engine/media/video/scraper/filename_parser.dart';
import 'package:fushi_engine/media/video/video_duration_pref.dart';
import 'package:fushi_engine/mining/metadata/galgame_metadata_source.dart';
import 'package:fushi_engine/privacy/media_privacy.dart';
import 'package:fushi_core/fushi_core.dart';

const String kTrackingProviderBangumi = 'bangumi';

enum TrackingMediaType {
  book('book'),
  bookChapter('book_chapter'),
  video('video'),
  videoCollection('video_collection'),
  game('game'),

  /// An episode played from a media server (Jellyfin / Emby / Plex); the key
  /// is `RemoteAnimeEpisode.mediaKey`. Linked from server ids, or by hand.
  remoteVideo('remote_video'),

  /// A media server season (series + season on one server login); the key is
  /// `remoteAnimeGroupKey`. One link sends every episode of the season as
  /// its episode number; also a do-not-track key covering those episodes.
  remoteSeries('remote_series'),

  /// A book series collection (`media_collections.id`). Only a do-not-track
  /// key: it covers every book of the collection, also ones added later.
  bookCollection('book_collection');

  const TrackingMediaType(this.value);
  final String value;
}

/// 追踪键（`TrackingMediaType.value` + mediaKey）对应的作品是否被用户标成私密。
/// 私密作品不推进度、不建自动映射（自动映射会拿本地标题去 Bangumi 搜索）。
bool isTrackedMediaPrivate(
  MediaPrivacySnapshot privacy,
  String mediaType,
  String mediaKey,
) {
  if (mediaType == TrackingMediaType.book.value ||
      mediaType == TrackingMediaType.bookChapter.value) {
    return privacy.isBookPrivate(mediaKey);
  }
  if (mediaType == TrackingMediaType.video.value) {
    return privacy.isVideoPrivate(mediaKey);
  }
  if (mediaType == TrackingMediaType.videoCollection.value) {
    final int? collectionId = int.tryParse(mediaKey);
    return collectionId != null &&
        privacy.isVideoCollectionPrivate(collectionId);
  }
  if (mediaType == TrackingMediaType.game.value) {
    return privacy.isGamePrivate(mediaKey);
  }
  return false;
}

enum TrackingKind {
  anime('anime'),
  novel('novel'),
  manga('manga'),
  game('game');

  const TrackingKind(this.value);
  final String value;
}

/// Which kind a local book is tracked as. Fushi keeps manga and books in
/// separate sections, and the section decides: manga → [TrackingKind.manga];
/// EPUB, text and PDF (Books section) → [TrackingKind.novel].
TrackingKind trackingKindForBookFormat(BookFormat format) =>
    format == BookFormat.manga ? TrackingKind.manga : TrackingKind.novel;

/// Kinds a local book of [format] may be tracked as. A PDF can be a novel
/// (the default, [trackingKindForBookFormat]) or a manga: the user says which
/// when linking by hand, and the link keeps it (`kind`). Every other format
/// has its one kind.
List<TrackingKind> trackingKindsForBookFormat(BookFormat format) =>
    format == BookFormat.pdf
    ? const <TrackingKind>[TrackingKind.novel, TrackingKind.manga]
    : <TrackingKind>[trackingKindForBookFormat(format)];

/// A link of [kind] (`kind` value) fits a book of [format] (BUG-1318: a link
/// made while the book had another format must not send progress for the
/// wrong entry).
bool bookFormatTracksAs(BookFormat format, String kind) =>
    trackingKindsForBookFormat(
      format,
    ).any((TrackingKind value) => value.value == kind);

enum TrackingProgressMode {
  episode('episode'),
  chapter('chapter'),
  volume('volume'),

  /// 只同步收藏状态，没有话数/卷数进度。
  ///
  /// Bangumi 游戏条目 `eps`/`volumes` 恒为 0，唯一可写的是收藏 `type`。此模式下
  /// [MediaTrackingOutboxRow.progress] 存的**不是进度而是 Bangumi 收藏 type**
  /// （1 想玩 / 2 玩过 / 3 在玩 / 4 搁置 / 5 弃坑），由本字段唯一确定其解释方式，
  /// 与 episode/chapter/volume 决定 progress 落 `ep_status` 还是 `vol_status` 同构。
  status('status');

  const TrackingProgressMode(this.value);
  final String value;

  static TrackingProgressMode? tryParse(String value) {
    for (final TrackingProgressMode mode in TrackingProgressMode.values) {
      if (mode.value == value) return mode;
    }
    return null;
  }
}

typedef AutoVideoTrackingSource = ({
  String mediaTitle,
  String videoTitle,
  int? bangumiSubjectId,
  String? bangumiSubjectName,
  int? bangumiEpisodeCount,
});

typedef AutoBookTrackingSource = ({String title, String format});

/// One title match to store for review (`media_tracking_suggestions`).
typedef TrackingSuggestionDraft = ({
  int subjectId,
  String subjectName,
  TrackingKind subjectKind,
  double score,
  Map<String, Object?> details,
});

typedef AutoGameTrackingSource = ({String name, int? bangumiSubjectId});

/// Explicit identifiers of one local episode file, for providers that link by
/// ID instead of by title (AniList via MAL). [episodeNumber] counts inside the
/// MAL entry; [episodeCount] is the local season's count (null = unknown).
typedef VideoTrackingIds = ({
  int malAnimeId,
  int episodeNumber,
  int? episodeCount,
  String title,
});

typedef PersistedGameTrackingStatus = ({
  String gameId,
  String name,
  int? bangumiSubjectId,
  int status,
  int evidenceAt,
});

typedef CompletedVideoTrackingProgress = ({
  TrackingMediaType mediaType,
  String mediaKey,
  int localProgress,
  bool completed,
  int evidenceAt,
});

typedef PersistedBookTrackingProgress = ({
  String mediaKey,
  TrackingMediaType mediaType,
  int localProgress,
  bool completed,
  int evidenceAt,
});

typedef BookTrackingSnapshot = ({BookFormat format, int? chapterProgress});

/// Read state of one online manga series (Mihon / Aidoku / Kavita / web).
///
/// [highestChapter] is the highest chapter number read (decimals floored;
/// chapters without a number, or numbered 0 or below, are ignored); null when
/// no numbered chapter is read. [allRead] = every listed chapter is read.
/// [lastReadAt] = newest read time (ms), used as reconcile evidence because
/// marking chapters on the series page does not move the reader position.
typedef MangaReadProgress = ({
  int? highestChapter,
  bool allRead,
  int lastReadAt,
});

/// Supplied by the app (it owns the manga series format). Returns null for a
/// book that is not an online manga series (a local volume, an EPUB).
typedef MangaReadProgressResolver =
    Future<MangaReadProgress?> Function(EpubBookRow book);

/// 把书籍格式、映射模式和明确完成状态收敛成唯一的本地上报值。
///
/// PDF 没有可靠章节，chapter 模式返回 null（整条不发）。漫画的 chapter 进度只来自
/// [MangaReadProgress.highestChapter]（在线系列的已读最高话数），本地卷没有，同样
/// 为 null；绝不把页码当章数。volume 模式只在
/// [completed] 为 true 时把当前卷计入，未完成时用 -1 配合卷号 offset 仅保留此前卷数。
/// 即时阅读事件和持久化补发必须都走这里，避免两条入口再次漂开。
int? resolveBookTrackingLocalProgress({
  required BookFormat format,
  required TrackingProgressMode progressMode,
  required int? chapterProgress,
  required bool completed,
}) {
  switch (progressMode) {
    case TrackingProgressMode.chapter:
      return format == BookFormat.pdf ? null : chapterProgress;
    case TrackingProgressMode.volume:
      return completed ? 0 : -1;
    case TrackingProgressMode.episode:
    case TrackingProgressMode.status:
      return null;
  }
}

/// 本地已经产生过可同步进度、但尚未建立 Bangumi 映射的条目。
///
/// 这份列表专供 UI 明确指出「哪些需要手动关联」。它与映射表是互补关系，不把
/// “没有映射”误写成“没有看过/读过”。
class MediaTrackingUnlinkedItem {
  const MediaTrackingUnlinkedItem({
    required this.mediaType,
    required this.mediaKey,
    required this.mediaTitle,
    required this.kind,
    required this.lastActivityAt,
    this.source = '',
    this.itemCount = 1,
    this.episodeNumber,
    this.multiSeason = false,
    this.hasSuggestions = false,
    this.removedByUser = false,
  });

  final TrackingMediaType mediaType;
  final String mediaKey;
  final String mediaTitle;
  final TrackingKind kind;
  final int lastActivityAt;

  /// Where it was played when that is not this library (a media server's
  /// name); '' = the local library.
  final String source;

  /// Watched episodes one link covers (a media server season).
  final int itemCount;

  /// The episode this one item is, when known: a media server episode
  /// listed on its own (the server named no series), or a video whose file
  /// name says it ([videoEpisodeNumberForTracking]). A link of a single
  /// video sends its starting number as the episode, so this is the link's
  /// starting number; null otherwise.
  final int? episodeNumber;

  /// A video collection holding more than one season ([isMultiSeasonGrouped]):
  /// a site lists each season as its own entry, so one link for the whole
  /// collection could never send. The user splits it by season or links
  /// single episodes instead.
  final bool multiSeason;

  /// A site found possible matches that wait for the user's review
  /// (`media_tracking_suggestions`, not dismissed).
  final bool hasSuggestions;

  /// The user removed a link of this item by hand ([MediaTrackingRepository
  /// .rejectSubject]): automatic linking leaves it to the user on that site.
  final bool removedByUser;

  MediaTrackingUnlinkedItem _with({
    bool? hasSuggestions,
    bool? removedByUser,
  }) => MediaTrackingUnlinkedItem(
    mediaType: mediaType,
    mediaKey: mediaKey,
    mediaTitle: mediaTitle,
    kind: kind,
    lastActivityAt: lastActivityAt,
    source: source,
    itemCount: itemCount,
    episodeNumber: episodeNumber,
    multiSeason: multiSeason,
    hasSuggestions: hasSuggestions ?? this.hasSuggestions,
    removedByUser: removedByUser ?? this.removedByUser,
  );
}

/// The links of one site and their queued updates at one moment
/// ([MediaTrackingRepository.captureLinkState]).
final class TrackingLinkState {
  const TrackingLinkState({required this.mappings, required this.outbox});

  /// Link id -> link.
  final Map<int, MediaTrackingMappingRow> mappings;

  /// Link id -> its queued update.
  final Map<int, MediaTrackingOutboxRow> outbox;
}

/// Saving a link that could never send: one link for a video collection
/// that holds more than one season ([MediaTrackingUnlinkedItem.multiSeason]).
final class MultiSeasonCollectionLinkError extends StateError {
  MultiSeasonCollectionLinkError(this.collectionId)
    : super('video collection $collectionId holds more than one season');

  final String collectionId;
}

/// A library video added from a media server (`media-server://` rows: its
/// `bookUid` is the server's item id) is tracked only through its server
/// identity: the episode's `remote_video` link (from the server's ids) or
/// its season's `remote_series` link (by hand). It never has a `video` /
/// `video_collection` identity of its own, so it is never listed, linked or
/// sent twice (T1 F3).
bool isTrackedThroughMediaServer(VideoBookRow video) =>
    isMediaServerVideoPath(video.videoPath);

/// A hand link of a library row added from a media server, or of its
/// collection, whose server identity is not known yet: no episode of it was
/// watched to the end or marked watched, so its season cannot be named.
final class MediaServerLibraryLinkError extends StateError {
  MediaServerLibraryLinkError(this.mediaKey)
    : super('media server library item $mediaKey has no known season yet');

  final String mediaKey;
}

/// The server identities that track library rows added from a media server
/// ([MediaTrackingRepository.loadMediaServerLibraryCoverage]).
final class MediaServerLibraryCoverage {
  const MediaServerLibraryCoverage(this._byLibraryKey);

  static const MediaServerLibraryCoverage empty = MediaServerLibraryCoverage(
    <String, List<({TrackingMediaType type, String key})>>{},
  );

  /// `video|<uid>` / `video_collection|<id>` -> server keys, the season
  /// (`remote_series`) first when there is one.
  final Map<String, List<({TrackingMediaType type, String key})>>
  _byLibraryKey;

  /// The server keys that track library [mediaType] + [mediaKey]; empty for
  /// anything that is not a media server row (or not known yet).
  List<({TrackingMediaType type, String key})> keysOf(
    String mediaType,
    String mediaKey,
  ) =>
      _byLibraryKey['$mediaType|$mediaKey'] ??
      const <({TrackingMediaType type, String key})>[];
}

/// The episode number [video] stands for by its title (`S01E46`,
/// `Episode 46`, ` - 46`), the same parse automatic linking uses for a
/// single file; null when the title names none. A hand link of the video
/// starts there (its progress is the starting number).
int? videoEpisodeNumberForTracking(VideoBookRow video) {
  final int? episode = FilenameParser.parse(video.title).episode;
  return episode != null && episode > 0 ? episode : null;
}

final RegExp _ignoredBookTocLabel = RegExp(
  r'^(?:目次|目录|目錄|contents?|table\s+of\s+contents|扉|title\s+page|表紙|cover|奥付|版权|版權|colophon|口絵|イラスト|插图|插圖|あとがき|后记|後記|著者紹介)$',
  caseSensitive: false,
);

String _normalizeBookHref(String value) {
  String path = value.split('#').first.split('?').first.replaceAll(r'\', '/');
  try {
    path = Uri.decodeComponent(path);
  } on ArgumentError {
    // Malformed percent escapes are kept verbatim, matching EPUB navigation.
  }
  final List<String> parts = <String>[];
  for (final String part in path.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isNotEmpty) parts.removeLast();
      continue;
    }
    parts.add(part);
  }
  return parts.join('/').toLowerCase();
}

/// 将 EPUB spine 位置保守换算为目录中的逻辑章节数。
///
/// Bangumi 的 `ep_status` 是作品“话数”，不能直接使用 EPUB 的 XHTML/spine 数量。
/// 只把已经越过的 TOC 项计为完成；同一 XHTML 内的多个锚点要等离开该 XHTML（或
/// 整本完成）才一并计入，宁可稍晚同步也不提前虚报。
int estimateCompletedBookChapters({
  required String chaptersJson,
  required String? tocJson,
  required int sectionIndex,
  required bool sectionCompleted,
  required bool bookCompleted,
  required int fallbackProgress,
}) {
  if (tocJson == null || tocJson.trim().isEmpty) {
    return math.max(0, fallbackProgress);
  }
  try {
    final dynamic chaptersValue = jsonDecode(chaptersJson);
    final dynamic tocValue = jsonDecode(tocJson);
    if (chaptersValue is! List || tocValue is! List) {
      return math.max(0, fallbackProgress);
    }
    final Map<String, int> chapterIndexes = <String, int>{};
    for (int index = 0; index < chaptersValue.length; index++) {
      final dynamic item = chaptersValue[index];
      if (item is! Map) continue;
      final String href = '${item['href'] ?? ''}'.trim();
      if (href.isEmpty) continue;
      chapterIndexes.putIfAbsent(_normalizeBookHref(href), () => index);
    }
    final List<int> tocIndexes = <int>[];
    final Set<String> seen = <String>{};

    void collect(dynamic value) {
      if (value is! List) return;
      for (final dynamic item in value) {
        if (item is! Map) continue;
        final String label = '${item['title'] ?? item['label'] ?? ''}'.trim();
        final String href = '${item['href'] ?? ''}'.trim();
        final String normalizedHref = _normalizeBookHref(href);
        final int? index = chapterIndexes[normalizedHref];
        final String identity = '$normalizedHref\u0000$label';
        if (index != null &&
            !_ignoredBookTocLabel.hasMatch(label) &&
            seen.add(identity)) {
          tocIndexes.add(index);
        }
        collect(item['children']);
      }
    }

    collect(tocValue);
    if (tocIndexes.isEmpty) return math.max(0, fallbackProgress);
    if (bookCompleted) return tocIndexes.length;
    return tocIndexes
        .where(
          (int index) =>
              index < sectionIndex ||
              (sectionCompleted && index == sectionIndex),
        )
        .length;
  } on FormatException {
    return math.max(0, fallbackProgress);
  }
}

/// The do-not-track list at one moment (see `MediaTrackingIgnored`): which
/// keys are ignored, directly or through an ignored collection.
final class TrackingIgnoreIndex {
  const TrackingIgnoreIndex._({
    required Set<String> keys,
    required Set<String> videosInIgnoredCollections,
    required Set<String> booksInIgnoredCollections,
    Set<String> episodesInIgnoredSeasons = const <String>{},
  }) : _keys = keys,
       _videos = videosInIgnoredCollections,
       _books = booksInIgnoredCollections,
       _episodes = episodesInIgnoredSeasons;

  static const TrackingIgnoreIndex empty = TrackingIgnoreIndex._(
    keys: <String>{},
    videosInIgnoredCollections: <String>{},
    booksInIgnoredCollections: <String>{},
  );

  /// `type|key` of every row.
  final Set<String> _keys;

  /// Video `bookUid`s that are members of an ignored video collection.
  final Set<String> _videos;

  /// Book keys that are members of an ignored book collection.
  final Set<String> _books;

  /// Media server episode keys (`remote_video`) watched in an ignored
  /// season (`remote_series`), as remembered in
  /// `media_tracking_remote_episodes`.
  final Set<String> _episodes;

  bool get isEmpty => _keys.isEmpty;

  /// [mediaType] + [mediaKey] has a row of its own.
  bool isListed(String mediaType, String mediaKey) =>
      _keys.contains('$mediaType|$mediaKey');

  /// Nothing may be linked, queued or sent for this item: it is listed, or
  /// it is a member of a listed collection. A book's chapter companion
  /// (`book_chapter`, keyed by the book) follows its book.
  bool covers(String mediaType, String mediaKey) {
    if (_keys.isEmpty) return false;
    if (isListed(mediaType, mediaKey)) return true;
    if (mediaType == TrackingMediaType.video.value) {
      return _videos.contains(mediaKey);
    }
    if (mediaType == TrackingMediaType.bookChapter.value) {
      return isListed(TrackingMediaType.book.value, mediaKey) ||
          _books.contains(mediaKey);
    }
    if (mediaType == TrackingMediaType.book.value) {
      return _books.contains(mediaKey);
    }
    if (mediaType == TrackingMediaType.remoteVideo.value) {
      return _episodes.contains(mediaKey);
    }
    return false;
  }
}

/// The whole series an item belongs to, as a do-not-track key: a book's
/// series collection, a video's collection, a media server episode's season.
typedef TrackingSeriesRef = ({
  TrackingMediaType type,
  String key,
  String title,
});

/// Which series every local item belongs to at one moment (see
/// [MediaTrackingRepository.loadSeriesIndex]).
final class TrackingSeriesIndex {
  const TrackingSeriesIndex(this._byItem);

  static const TrackingSeriesIndex empty = TrackingSeriesIndex(
    <String, TrackingSeriesRef>{},
  );

  /// `type|key` of a book, video or media server episode -> its series.
  final Map<String, TrackingSeriesRef> _byItem;

  /// The series of [mediaType] + [mediaKey]; null when it is in none, or is
  /// a series itself. A chapter companion follows its book.
  TrackingSeriesRef? seriesOf(String mediaType, String mediaKey) {
    final String type = mediaType == TrackingMediaType.bookChapter.value
        ? TrackingMediaType.book.value
        : mediaType;
    return _byItem['$type|$mediaKey'];
  }
}

/// "Frieren S1" for a remembered media server episode's season (the
/// episode's own title when the server named no series).
String remoteSeasonTitle(MediaTrackingRemoteEpisodeRow row) {
  final String series = row.seriesTitle.trim();
  if (series.isEmpty) return row.title;
  final int? season = row.seasonNumber;
  return season == null ? series : '$series S$season';
}

/// `media_tracking_mappings.sent_progress` of a link made before v152:
/// nothing recorded (see the column).
const int kTrackingSentProgressLegacy = -1;

class PendingTrackingUpdate {
  const PendingTrackingUpdate({required this.outbox, required this.mapping});

  final MediaTrackingOutboxRow outbox;
  final MediaTrackingMappingRow mapping;
}

/// 外部媒体映射与可靠待同步队列的单一数据入口。
///
/// 队列按 mapping 合并成一行，进度只取最大值、完成状态只会 false→true；成功/失败回写
/// 都带 [MediaTrackingOutboxRow.updatedAt] 乐观锁，网络请求期间若来了更高进度，旧请求
/// 不能误删或覆盖新事件。
class MediaTrackingRepository {
  const MediaTrackingRepository(this._db);

  final FushiDatabase _db;

  /// 作品级私密标记快照（口径见 [MediaPrivacySnapshot]）。
  Future<MediaPrivacySnapshot> loadPrivacy() => MediaPrivacySnapshot.load(_db);

  /// The do-not-track list now. Collection rows are resolved to their
  /// current members, so a volume added to an ignored series later is
  /// covered as soon as it is in the collection.
  Future<TrackingIgnoreIndex> loadIgnoreIndex() async {
    final List<MediaTrackingIgnoredRow> rows = await _db
        .select(_db.mediaTrackingIgnored)
        .get();
    if (rows.isEmpty) return TrackingIgnoreIndex.empty;
    final Set<String> videoCollections = <String>{
      for (final MediaTrackingIgnoredRow row in rows)
        if (row.mediaType == TrackingMediaType.videoCollection.value)
          row.mediaKey,
    };
    final Set<String> bookCollections = <String>{
      for (final MediaTrackingIgnoredRow row in rows)
        if (row.mediaType == TrackingMediaType.bookCollection.value)
          row.mediaKey,
    };
    final List<int> collectionIds = <int>[
      for (final String key in <String>{
        ...videoCollections,
        ...bookCollections,
      })
        ?int.tryParse(key),
    ];
    final Set<String> seasons = <String>{
      for (final MediaTrackingIgnoredRow row in rows)
        if (row.mediaType == TrackingMediaType.remoteSeries.value) row.mediaKey,
    };
    final Set<String> episodes = <String>{
      if (seasons.isNotEmpty)
        for (final MediaTrackingRemoteEpisodeRow row in await (_db.select(
          _db.mediaTrackingRemoteEpisodes,
        )..where((t) => t.groupKey.isIn(seasons))).get())
          row.mediaKey,
    };
    final Set<String> videos = <String>{};
    final Set<String> books = <String>{};
    final String Function(String) bookKeyOf = bookCollections.isEmpty
        ? (String entryKey) => entryKey
        : await _bookKeyOfMember();
    if (collectionIds.isNotEmpty) {
      final List<MediaCollectionItemRow> members =
          await (_db.select(
                _db.mediaCollectionItems,
              )..where((t) => t.collectionId.isIn(collectionIds)))
              .get();
      for (final MediaCollectionItemRow member in members) {
        final String collection = member.collectionId.toString();
        if (member.mediaType == MediaKind.video.dbValue) {
          if (videoCollections.contains(collection)) videos.add(member.entryKey);
        } else if (member.mediaType != MediaKind.game.dbValue &&
            bookCollections.contains(collection)) {
          books.add(bookKeyOf(member.entryKey));
        }
      }
    }
    return TrackingIgnoreIndex._(
      keys: <String>{
        for (final MediaTrackingIgnoredRow row in rows)
          '${row.mediaType}|${row.mediaKey}',
      },
      videosInIgnoredCollections: videos,
      booksInIgnoredCollections: books,
      episodesInIgnoredSeasons: episodes,
    );
  }

  /// The do-not-track list, newest first.
  Future<List<MediaTrackingIgnoredRow>> listIgnored() =>
      (_db.select(_db.mediaTrackingIgnored)..orderBy(
            <OrderClauseGenerator<$MediaTrackingIgnoredTable>>[
              (t) =>
                  OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
              (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
            ],
          ))
          .get();

  /// Puts [mediaType] + [mediaKey] on the do-not-track list (already there:
  /// the first row is kept).
  Future<void> addIgnored({
    required TrackingMediaType mediaType,
    required String mediaKey,
    required String mediaTitle,
    TrackingKind? kind,
  }) => _db
      .into(_db.mediaTrackingIgnored)
      .insert(
        MediaTrackingIgnoredCompanion.insert(
          mediaType: mediaType.value,
          mediaKey: mediaKey,
          mediaTitle: Value<String>(mediaTitle),
          kind: Value<String?>(kind?.value),
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
        mode: InsertMode.insertOrIgnore,
      );

  /// Takes [mediaType] + [mediaKey] off the do-not-track list.
  Future<void> removeIgnored({
    required String mediaType,
    required String mediaKey,
  }) =>
      (_db.delete(_db.mediaTrackingIgnored)..where(
            (t) => t.mediaType.equals(mediaType) & t.mediaKey.equals(mediaKey),
          ))
          .go();

  /// The book key of a collection's book member. Members are keyed by the
  /// book's uid (v82); a row that still carries the book key is taken as it
  /// is.
  Future<String Function(String)> _bookKeyOfMember() async {
    final Map<String, String> byUid = <String, String>{
      for (final EpubBookMeta book in await _db.getEpubBookMetas())
        if (book.uid.isNotEmpty) book.uid: book.bookKey,
    };
    return (String entryKey) => byUid[entryKey] ?? entryKey;
  }

  /// How well [collection] stands for a book's series, best first: 0 = the
  /// series card the organiser made (`BookSeriesGrouper`, a `playlist` with
  /// origin `rule`, or the AI organiser's), 1 = a series-like collection
  /// (`collection`), 2 = any other collection the shelf shows the book in
  /// (a rule-made series the user edited is claimed as `user`).
  static int bookSeriesRank(MediaCollectionRow collection) =>
      collection.origin == CollectionOrigin.rule.dbValue ||
          collection.origin == CollectionOrigin.ai.dbValue
      ? 0
      : collection.collectionType == 'collection'
      ? 1
      : 2;

  static int _compareBookSeries(MediaCollectionRow a, MediaCollectionRow b) {
    final int byRank = bookSeriesRank(a).compareTo(bookSeriesRank(b));
    return byRank != 0 ? byRank : a.id.compareTo(b.id);
  }

  /// Collections that hold book [bookKey], best series first
  /// ([bookSeriesRank], then oldest): what "Don't track the series"
  /// ignores.
  Future<List<MediaCollectionRow>> bookSeriesCollections(String bookKey) async {
    final String uid = (await _db.getEpubBook(bookKey))?.uid ?? '';
    final List<MediaCollectionItemRow> items =
        await (_db.select(_db.mediaCollectionItems)..where(
              (t) =>
                  t.entryKey.isIn(<String>{bookKey, if (uid.isNotEmpty) uid}) &
                  t.mediaType.isNotIn(<String>[
                    MediaKind.video.dbValue,
                    MediaKind.game.dbValue,
                  ]),
            ))
            .get();
    if (items.isEmpty) return const <MediaCollectionRow>[];
    final List<MediaCollectionRow> collections =
        await (_db.select(_db.mediaCollections)..where(
              (t) => t.id.isIn(<int>{
                for (final MediaCollectionItemRow item in items)
                  item.collectionId,
              }),
            ))
            .get();
    return collections..sort(_compareBookSeries);
  }

  /// The series of every book (best [bookSeriesRank], then oldest), video
  /// (oldest collection holding it) and remembered media server episode
  /// (its season): what "Don't track the series" ignores from a member's
  /// row. Two queries plus the remembered episodes; no network.
  Future<TrackingSeriesIndex> loadSeriesIndex() async {
    final Map<int, MediaCollectionRow> collections = <int, MediaCollectionRow>{
      for (final MediaCollectionRow row in await _db.getAllMediaCollections())
        row.id: row,
    };
    final List<MediaCollectionItemRow> members =
        await (_db.select(_db.mediaCollectionItems)..orderBy(
              <OrderClauseGenerator<$MediaCollectionItemsTable>>[
                (t) => OrderingTerm(expression: t.collectionId),
              ],
            ))
            .get();
    final Map<String, TrackingSeriesRef> byItem = <String, TrackingSeriesRef>{};
    final String Function(String) bookKeyOf = await _bookKeyOfMember();
    final Map<String, MediaCollectionRow> bookSeries =
        <String, MediaCollectionRow>{};
    for (final MediaCollectionItemRow member in members) {
      final MediaCollectionRow? collection = collections[member.collectionId];
      if (collection == null || member.mediaType == MediaKind.game.dbValue) {
        continue;
      }
      if (member.mediaType == MediaKind.video.dbValue) {
        byItem.putIfAbsent(
          '${TrackingMediaType.video.value}|${member.entryKey}',
          () => (
            type: TrackingMediaType.videoCollection,
            key: collection.id.toString(),
            title: collection.name,
          ),
        );
      } else {
        final String key =
            '${TrackingMediaType.book.value}|${bookKeyOf(member.entryKey)}';
        final MediaCollectionRow? best = bookSeries[key];
        if (best == null || _compareBookSeries(collection, best) < 0) {
          bookSeries[key] = collection;
        }
      }
    }
    for (final MapEntry<String, MediaCollectionRow> entry
        in bookSeries.entries) {
      byItem[entry.key] = (
        type: TrackingMediaType.bookCollection,
        key: entry.value.id.toString(),
        title: entry.value.name,
      );
    }
    for (final MediaTrackingRemoteEpisodeRow row in await listRemoteEpisodes()) {
      if (row.isMovie || row.groupKey == row.mediaKey) continue;
      byItem.putIfAbsent(
        '${TrackingMediaType.remoteVideo.value}|${row.mediaKey}',
        () => (
          type: TrackingMediaType.remoteSeries,
          key: row.groupKey,
          title: remoteSeasonTitle(row),
        ),
      );
    }
    return TrackingSeriesIndex(byItem);
  }

  /// Remembers a media server episode watched to the end (watched again: the
  /// newest time and names win). Kept whether or not it is linked or
  /// ignored: it tells which season an episode belongs to (an ignored
  /// season pauses its episodes' links) and what a season link sends;
  /// "Needs attention" lists only the unlinked ones.
  Future<void> rememberRemoteEpisode(RemoteAnimeEpisode episode) {
    final String key = episode.mediaKey.trim();
    final MediaTrackingRemoteEpisodesCompanion row =
        MediaTrackingRemoteEpisodesCompanion.insert(
          mediaKey: key,
          groupKey: remoteAnimeGroupKey(episode),
          seriesTitle: Value<String>(episode.seriesTitle.trim()),
          title: episode.title.trim().isEmpty ? key : episode.title.trim(),
          seasonNumber: Value<int?>(episode.seasonNumber),
          episodeNumber: episode.episodeNumber,
          isMovie: Value<bool>(episode.isMovie),
          serverName: Value<String>(
            remoteServerShownName(episode.serverName),
          ),
          watchedAt: DateTime.now().millisecondsSinceEpoch,
        );
    return _db
        .into(_db.mediaTrackingRemoteEpisodes)
        .insert(
          row,
          onConflict: DoUpdate(
            (_) => row,
            target: <Column>[_db.mediaTrackingRemoteEpisodes.mediaKey],
          ),
        );
  }

  /// Every remembered media server episode, newest first.
  Future<List<MediaTrackingRemoteEpisodeRow>> listRemoteEpisodes() =>
      (_db.select(_db.mediaTrackingRemoteEpisodes)..orderBy(
            <OrderClauseGenerator<$MediaTrackingRemoteEpisodesTable>>[
              (t) =>
                  OrderingTerm(expression: t.watchedAt, mode: OrderingMode.desc),
            ],
          ))
          .get();

  /// The remembered episodes one link of [groupKey] covers.
  Future<List<MediaTrackingRemoteEpisodeRow>> remoteEpisodesOfGroup(
    String groupKey,
  ) => (_db.select(
    _db.mediaTrackingRemoteEpisodes,
  )..where((t) => t.groupKey.equals(groupKey))).get();

  /// Every site's link of book [bookKey] (not the chapter companions).
  Future<List<MediaTrackingMappingRow>> bookMappings(String bookKey) =>
      (_db.select(_db.mediaTrackingMappings)..where(
            (t) =>
                t.mediaType.equals(TrackingMediaType.book.value) &
                t.mediaKey.equals(bookKey),
          ))
          .get();

  /// Every site's link of one local item.
  Future<List<MediaTrackingMappingRow>> itemMappings({
    required TrackingMediaType mediaType,
    required String mediaKey,
  }) =>
      (_db.select(_db.mediaTrackingMappings)..where(
            (t) =>
                t.mediaType.equals(mediaType.value) &
                t.mediaKey.equals(mediaKey),
          ))
          .get();

  /// [provider] null = every provider (the historical behaviour).
  Future<List<MediaTrackingMappingRow>> listMappings({String? provider}) {
    final query = _db.select(_db.mediaTrackingMappings)
      ..orderBy([
        (t) => OrderingTerm(expression: t.kind),
        (t) => OrderingTerm(expression: t.mediaTitle),
      ]);
    if (provider != null) {
      query.where((t) => t.provider.equals(provider));
    }
    return query.get();
  }

  /// Videos, books and games with local progress that no tracking site is
  /// linked to ([provider] null), or that [provider] is not linked to.
  ///
  /// 视频合集优先于成员：同一季已经放进 playlist 时只提示一次合集，避免把十二集
  /// 全部写成十二条“需手动关联”。未归合集的已完成视频仍按单条列出。
  Future<List<MediaTrackingUnlinkedItem>> listUnlinkedHistory({
    String? provider,
  }) async {
    final Set<String> mapped = <String>{
      for (final MediaTrackingMappingRow row in await listMappings(
        provider: provider,
      ))
        '${row.mediaType}|${row.mediaKey}',
    };
    bool isMapped(TrackingMediaType type, String key) =>
        mapped.contains('${type.value}|$key');

    final List<VideoBookRow> videos = await _db.allVideoBooks();
    final Map<String, int> durations = await loadKnownVideoDurationsMs(_db);
    final Map<String, VideoBookRow> videosByUid = <String, VideoBookRow>{
      for (final VideoBookRow video in videos) video.bookUid: video,
    };
    final List<MediaCollectionRow> collections = await _db
        .getAllMediaCollections();
    final List<MediaCollectionItemRow> members = await _db
        .getAllCollectionItems();
    final Map<int, List<MediaCollectionItemRow>> videoMembersByCollection =
        <int, List<MediaCollectionItemRow>>{};
    for (final MediaCollectionItemRow member in members) {
      if (member.mediaType != MediaKind.video.dbValue) continue;
      videoMembersByCollection
          .putIfAbsent(member.collectionId, () => <MediaCollectionItemRow>[])
          .add(member);
    }
    // Rows added from a media server, and collections holding them, are
    // tracked through the server's identity (the remembered episodes below),
    // never as library videos ([isTrackedThroughMediaServer]).
    final Set<int> serverCollections = _mediaServerCollections(
      members,
      videosByUid,
    );

    final List<MediaTrackingUnlinkedItem> result =
        <MediaTrackingUnlinkedItem>[];
    final Set<String> videosCoveredByPlaylist = <String>{};
    for (final MediaCollectionRow collection in collections) {
      final String key = collection.id.toString();
      if (collection.collectionType != 'playlist' ||
          serverCollections.contains(collection.id) ||
          !isMapped(TrackingMediaType.videoCollection, key)) {
        continue;
      }
      for (final MediaCollectionItemRow member
          in videoMembersByCollection[collection.id] ??
              const <MediaCollectionItemRow>[]) {
        final VideoBookRow? video = videosByUid[member.entryKey];
        if (video != null && _videoWatchedAtMs(video, durations) != null) {
          videosCoveredByPlaylist.add(member.entryKey);
        }
      }
    }
    for (final MediaCollectionRow collection in collections) {
      if (collection.collectionType != 'playlist' ||
          serverCollections.contains(collection.id)) {
        continue;
      }
      final String key = collection.id.toString();
      if (isMapped(TrackingMediaType.videoCollection, key)) continue;
      final List<MediaCollectionItemRow> collectionMembers =
          videoMembersByCollection[collection.id] ??
          const <MediaCollectionItemRow>[];
      int lastCompletedAt = 0;
      final Set<String> completedMembers = <String>{};
      for (final MediaCollectionItemRow member in collectionMembers) {
        final VideoBookRow? video = videosByUid[member.entryKey];
        final int? watchedAt = video == null
            ? null
            : _videoWatchedAtMs(video, durations);
        if (watchedAt == null ||
            videosCoveredByPlaylist.contains(member.entryKey) ||
            isMapped(TrackingMediaType.video, member.entryKey)) {
          continue;
        }
        completedMembers.add(member.entryKey);
        lastCompletedAt = math.max(lastCompletedAt, watchedAt);
      }
      if (completedMembers.isEmpty) continue;
      videosCoveredByPlaylist.addAll(completedMembers);
      result.add(
        MediaTrackingUnlinkedItem(
          mediaType: TrackingMediaType.videoCollection,
          mediaKey: key,
          mediaTitle: collection.name,
          kind: TrackingKind.anime,
          lastActivityAt: lastCompletedAt,
          multiSeason: isMultiSeasonGrouped(<String>[
            for (final MediaCollectionItemRow member in collectionMembers)
              if (videosByUid[member.entryKey] case final VideoBookRow video)
                collectionGroupKeyForFilename(video.videoPath),
          ]),
        ),
      );
    }

    for (final VideoBookRow video in videos) {
      if (isTrackedThroughMediaServer(video)) continue;
      final int? watchedAt = _videoWatchedAtMs(video, durations);
      if (watchedAt == null ||
          videosCoveredByPlaylist.contains(video.bookUid) ||
          isMapped(TrackingMediaType.video, video.bookUid)) {
        continue;
      }
      result.add(
        MediaTrackingUnlinkedItem(
          mediaType: TrackingMediaType.video,
          mediaKey: video.bookUid,
          mediaTitle: video.title,
          kind: TrackingKind.anime,
          lastActivityAt: watchedAt,
          episodeNumber: videoEpisodeNumberForTracking(video),
        ),
      );
    }

    // v82：reader_positions 键 = 书 uid，按行 uid 直查（空 uid 视同无阅读记录）。
    final Map<String, ReaderPositionRow> positions =
        <String, ReaderPositionRow>{
          for (final ReaderPositionRow position
              in await _db.getAllReaderPositions())
            position.bookUid: position,
        };
    for (final EpubBookMeta book in await _db.getEpubBookMetas()) {
      final ReaderPositionRow? position = book.uid.isEmpty
          ? null
          : positions[book.uid];
      final DateTime? completedAt = book.completedAt;
      if ((position == null && completedAt == null) ||
          isMapped(TrackingMediaType.book, book.bookKey)) {
        continue;
      }
      result.add(
        MediaTrackingUnlinkedItem(
          mediaType: TrackingMediaType.book,
          mediaKey: book.bookKey,
          mediaTitle: book.title,
          kind: trackingKindForBookFormat(BookFormat.parseOrEpub(book.format)),
          lastActivityAt: math.max(
            position?.updatedAt ?? 0,
            completedAt?.millisecondsSinceEpoch ?? 0,
          ),
        ),
      );
    }

    // Games: only Bangumi tracks them.
    for (final GalgameRow game in await _db.getAllGalgames()) {
      if (game.playStatus <= 0 || isMapped(TrackingMediaType.game, game.id)) {
        continue;
      }
      result.add(
        MediaTrackingUnlinkedItem(
          mediaType: TrackingMediaType.game,
          mediaKey: game.id,
          mediaTitle: game.name,
          kind: TrackingKind.game,
          lastActivityAt: game.addedAt,
        ),
      );
    }

    // Media server episodes no site is linked to (neither the episode from
    // the server's ids nor its season by hand): one entry per season (one
    // link covers it), a movie on its own.
    final Map<String, List<MediaTrackingRemoteEpisodeRow>> remoteGroups =
        <String, List<MediaTrackingRemoteEpisodeRow>>{};
    for (final MediaTrackingRemoteEpisodeRow row in await listRemoteEpisodes()) {
      if (isMapped(TrackingMediaType.remoteVideo, row.mediaKey)) continue;
      remoteGroups
          .putIfAbsent(row.groupKey, () => <MediaTrackingRemoteEpisodeRow>[])
          .add(row);
    }
    // A season some of whose episodes are linked (by the server's ids):
    // a season link would not cover those, so the rest are listed one by
    // one, each as itself (T2 G6).
    // Links the user removed by hand, as `type|key` (any site).
    final Set<String> removed = <String>{
      for (final ({String provider, String type, String key}) r
          in await linksRemovedByUser())
        '${r.type}|${r.key}',
    };
    final Set<String> partlyLinkedSeasons = <String>{
      for (final MediaTrackingRemoteEpisodeRow row in await listRemoteEpisodes())
        if (isMapped(TrackingMediaType.remoteVideo, row.mediaKey) &&
            row.groupKey != row.mediaKey)
          row.groupKey,
    };
    final List<List<MediaTrackingRemoteEpisodeRow>> remoteEntries =
        <List<MediaTrackingRemoteEpisodeRow>>[
          for (final MapEntry<String, List<MediaTrackingRemoteEpisodeRow>>
              group in remoteGroups.entries)
            if (partlyLinkedSeasons.contains(group.key))
              for (final MediaTrackingRemoteEpisodeRow row in group.value)
                <MediaTrackingRemoteEpisodeRow>[row]
            else
              group.value,
        ];
    for (final List<MediaTrackingRemoteEpisodeRow> rows in remoteEntries) {
      final MediaTrackingRemoteEpisodeRow first = rows.first;
      final bool single =
          first.isMovie ||
          first.groupKey == first.mediaKey ||
          partlyLinkedSeasons.contains(first.groupKey);
      final String groupKey = single ? first.mediaKey : first.groupKey;
      final ({String key, List<MediaTrackingRemoteEpisodeRow> value}) group = (
        key: groupKey,
        value: rows,
      );
      final TrackingMediaType type = single
          ? TrackingMediaType.remoteVideo
          : TrackingMediaType.remoteSeries;
      if (isMapped(type, group.key)) continue;
      result.add(
        MediaTrackingUnlinkedItem(
          mediaType: type,
          mediaKey: group.key,
          mediaTitle: single ? first.title : remoteSeasonTitle(first),
          kind: TrackingKind.anime,
          lastActivityAt: group.value
              .map((MediaTrackingRemoteEpisodeRow row) => row.watchedAt)
              .reduce(math.max),
          source: remoteServerShownName(first.serverName),
          itemCount: group.value.length,
          // No season to link: the episode is the site's episode number.
          episodeNumber: single && !first.isMovie ? first.episodeNumber : null,
          // A season row: its own link, or one of its episodes' links, was
          // removed by hand.
          removedByUser:
              removed.contains('${type.value}|${group.key}') ||
              group.value.any(
                (MediaTrackingRemoteEpisodeRow row) => removed.contains(
                  '${TrackingMediaType.remoteVideo.value}|${row.mediaKey}',
                ),
              ),
        ),
      );
    }

    // Ignored items (and members of ignored collections) never need a link.
    final TrackingIgnoreIndex ignored = await loadIgnoreIndex();
    if (!ignored.isEmpty) {
      result.removeWhere(
        (MediaTrackingUnlinkedItem item) =>
            ignored.covers(item.mediaType.value, item.mediaKey),
      );
    }
    final Set<String> suggested = await itemsWithOpenSuggestions();
    if (suggested.isNotEmpty || removed.isNotEmpty) {
      for (int i = 0; i < result.length; i++) {
        final MediaTrackingUnlinkedItem item = result[i];
        final String id = '${item.mediaType.value}|${item.mediaKey}';
        if (!suggested.contains(id) && !removed.contains(id)) continue;
        if (item.removedByUser && !suggested.contains(id)) continue;
        result[i] = item._with(
          hasSuggestions: suggested.contains(id),
          removedByUser: item.removedByUser || removed.contains(id),
        );
      }
    }
    result.sort((MediaTrackingUnlinkedItem a, MediaTrackingUnlinkedItem b) {
      final int byTime = b.lastActivityAt.compareTo(a.lastActivityAt);
      return byTime != 0 ? byTime : a.mediaTitle.compareTo(b.mediaTitle);
    });
    return result;
  }

  Future<MediaTrackingMappingRow?> findMapping({
    required TrackingMediaType mediaType,
    required String mediaKey,
    String provider = kTrackingProviderBangumi,
  }) =>
      (_db.select(_db.mediaTrackingMappings)..where(
            (t) =>
                t.provider.equals(provider) &
                t.mediaType.equals(mediaType.value) &
                t.mediaKey.equals(mediaKey),
          ))
          .getSingleOrNull();

  Future<int> saveMapping({
    required TrackingMediaType mediaType,
    required String mediaKey,
    required String mediaTitle,
    required TrackingKind kind,
    required int subjectId,
    required String subjectName,
    required TrackingProgressMode progressMode,
    required int progressOffset,
    String provider = kTrackingProviderBangumi,
    String linkSource = 'manual',
    double? confidence,
  }) async {
    if (mediaKey.trim().isEmpty) {
      throw ArgumentError.value(mediaKey, 'mediaKey', 'must not be empty');
    }
    if (subjectId <= 0) {
      throw ArgumentError.value(subjectId, 'subjectId', 'must be positive');
    }
    if (progressOffset < 0) {
      throw ArgumentError.value(
        progressOffset,
        'progressOffset',
        'must be non-negative',
      );
    }
    final int now = DateTime.now().millisecondsSinceEpoch;
    final MediaTrackingMappingRow? existing = await findMapping(
      mediaType: mediaType,
      mediaKey: mediaKey,
      provider: provider,
    );
    if (existing == null) {
      return _db
          .into(_db.mediaTrackingMappings)
          .insert(
            MediaTrackingMappingsCompanion.insert(
              provider: Value<String>(provider),
              mediaType: mediaType.value,
              mediaKey: mediaKey,
              mediaTitle: mediaTitle,
              kind: kind.value,
              subjectId: subjectId,
              subjectName: subjectName,
              progressMode: progressMode.value,
              progressOffset: Value<int>(progressOffset),
              createdAt: now,
              updatedAt: now,
              linkSource: Value<String?>(linkSource),
              confidence: Value<double?>(confidence),
            ),
          );
    }
    // The same entry, unit and number again (T2 G13): the same link, so
    // what it already sent still stands and is not sent again.
    final bool sameLink =
        existing.subjectId == subjectId &&
        existing.kind == kind.value &&
        existing.progressMode == progressMode.value &&
        existing.progressOffset == progressOffset;
    await (_db.update(
      _db.mediaTrackingMappings,
    )..where((t) => t.id.equals(existing.id))).write(
      MediaTrackingMappingsCompanion(
        mediaTitle: Value<String>(mediaTitle),
        kind: Value<String>(kind.value),
        subjectId: Value<int>(subjectId),
        subjectName: Value<String>(subjectName),
        progressMode: Value<String>(progressMode.value),
        progressOffset: Value<int>(progressOffset),
        updatedAt: Value<int>(now),
        linkSource: Value<String?>(linkSource),
        confidence: Value<double?>(confidence),
        // A changed link starts over: the item's current progress goes to it.
        sentProgress: sameLink
            ? const Value<int?>.absent()
            : const Value<int?>(null),
        sentCompleted: sameLink
            ? const Value<bool>.absent()
            : const Value<bool>(false),
      ),
    );
    return existing.id;
  }

  /// 自动识别只能补空白，绝不覆盖用户已经确认或手工修正过的映射。
  ///
  /// 唯一键冲突用 `insertOrIgnore` 收敛并发：播放器完成回调、阅读 debounce 和设置页
  /// 手工保存可能同时到达；最终以先落库者为准，自动路径不会把人工选择改回去。
  Future<MediaTrackingMappingRow> saveMappingIfAbsent({
    required TrackingMediaType mediaType,
    required String mediaKey,
    required String mediaTitle,
    required TrackingKind kind,
    required int subjectId,
    required String subjectName,
    required TrackingProgressMode progressMode,
    required int progressOffset,
    String provider = kTrackingProviderBangumi,
    String? linkSource,
    double? confidence,
  }) async => (await insertMappingIfAbsent(
    mediaType: mediaType,
    mediaKey: mediaKey,
    mediaTitle: mediaTitle,
    kind: kind,
    subjectId: subjectId,
    subjectName: subjectName,
    progressMode: progressMode,
    progressOffset: progressOffset,
    provider: provider,
    linkSource: linkSource,
    confidence: confidence,
  )).row;

  /// [saveMappingIfAbsent], also saying whether this call made the link
  /// (`created`) or found one already there.
  Future<({MediaTrackingMappingRow row, bool created})> insertMappingIfAbsent({
    required TrackingMediaType mediaType,
    required String mediaKey,
    required String mediaTitle,
    required TrackingKind kind,
    required int subjectId,
    required String subjectName,
    required TrackingProgressMode progressMode,
    required int progressOffset,
    String provider = kTrackingProviderBangumi,
    String? linkSource,
    double? confidence,
  }) async {
    final MediaTrackingMappingRow? existing = await findMapping(
      mediaType: mediaType,
      mediaKey: mediaKey,
      provider: provider,
    );
    if (existing != null) return (row: existing, created: false);
    if (mediaKey.trim().isEmpty || subjectId <= 0 || progressOffset < 0) {
      throw ArgumentError('Invalid automatic media tracking mapping');
    }
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int rowId = await _db
        .into(_db.mediaTrackingMappings)
        .insert(
          MediaTrackingMappingsCompanion.insert(
            provider: Value<String>(provider),
            mediaType: mediaType.value,
            mediaKey: mediaKey,
            mediaTitle: mediaTitle,
            kind: kind.value,
            subjectId: subjectId,
            subjectName: subjectName,
            progressMode: progressMode.value,
            progressOffset: Value<int>(progressOffset),
            createdAt: now,
            updatedAt: now,
            linkSource: Value<String?>(linkSource),
            confidence: Value<double?>(confidence),
          ),
          mode: InsertMode.insertOrIgnore,
        );
    final MediaTrackingMappingRow? saved = await findMapping(
      mediaType: mediaType,
      mediaKey: mediaKey,
      provider: provider,
    );
    if (saved == null) {
      throw StateError('Automatic media tracking mapping was not persisted');
    }
    // insertOrIgnore: another caller may have saved it in between.
    return (row: saved, created: saved.id == rowId);
  }

  /// 播放完成时用于自动映射的本地事实。优先返回视频刮削已确认的 Bangumi id；
  /// TMDB/offlineDb/manualUrl 的 id 不是 Bangumi subject id，必须丢弃，不能串源误写。
  Future<AutoVideoTrackingSource?> loadAutoVideoSource({
    required String bookUid,
    int? collectionId,
  }) async {
    final VideoBookRow? video = await _db.getVideoBookByBookUid(bookUid);
    if (video == null) return null;
    final MediaCollectionRow? collection = collectionId == null
        ? null
        : await _db.getMediaCollectionById(collectionId);
    final VideoScrapeMetaRow? scrape = await _db.getVideoScrapeMeta(bookUid);
    final bool isBangumi = scrape?.source == kTrackingProviderBangumi;
    final String collectionTitle = collection?.name.trim() ?? '';
    // 条目名只能取**作品级**资料：v65 起集级刮削（TODO-2491）会把
    // video_scrape_meta.title 覆盖成集名（episodeNumber 非空即集级行），
    // 直接取会让追番映射顶着「第 3 话 某某」当条目名。集级行回退所属合集的
    // 刮削资料（同 subject 的作品名）；无合集资料则不给名（subjectId 仍在，
    // 映射功能不受影响，只是少个显示名）。
    String? bangumiSubjectName;
    if (isBangumi) {
      if (scrape!.episodeNumber == null) {
        bangumiSubjectName = scrape.title;
      } else if (collection != null) {
        final CollectionScrapeMetaRow? collectionScrape = await _db
            .getCollectionScrapeMeta(collection.id);
        if (collectionScrape?.source == kTrackingProviderBangumi) {
          bangumiSubjectName = collectionScrape!.title;
        }
      }
    }
    return (
      mediaTitle: collectionTitle.isEmpty ? video.title : collectionTitle,
      videoTitle: video.title,
      bangumiSubjectId: isBangumi
          ? int.tryParse(scrape!.subjectId.trim())
          : null,
      bangumiSubjectName: bangumiSubjectName,
      bangumiEpisodeCount: isBangumi ? scrape!.episodeCount : null,
    );
  }

  /// 合集 video 成员的分组键列——按各集 `videoPath` 文件名**现场派生**（分组是
  /// 文件名的纯函数、不落库，语义见 collection_season_groups.dart）。service 据此
  /// 判定「多季合集」并绕开结构性失真的合集级映射；存量合集零迁移即受保护。
  Future<List<String>> loadCollectionVideoGroupKeys(int collectionId) async {
    final List<MediaCollectionItemRow> items = await _db.getCollectionItems(
      collectionId,
    );
    final List<String> keys = <String>[];
    for (final MediaCollectionItemRow item in items) {
      if (item.mediaType != MediaKind.video.dbValue) continue;
      final VideoBookRow? video = await _db.getVideoBookByBookUid(
        item.entryKey,
      );
      if (video == null) continue;
      keys.add(collectionGroupKeyForFilename(video.videoPath));
    }
    return keys;
  }

  /// Collection [collectionId] holds more than one season: a link for the
  /// whole collection could never send (see
  /// [MediaTrackingUnlinkedItem.multiSeason]).
  Future<bool> isMultiSeasonVideoCollection(int collectionId) async =>
      isMultiSeasonGrouped(await loadCollectionVideoGroupKeys(collectionId));

  /// Links that can never send: a video collection link of a collection
  /// that holds more than one season (saved before the link dialog refused
  /// them, or the collection got a second season later). Shown under
  /// "Needs attention" so the user can remove them.
  ///
  /// Also a `video` / `video_collection` link of a library row added from a
  /// media server, or of a collection holding one: such rows send through
  /// their server identity only ([isTrackedThroughMediaServer]), so the link
  /// was made before that rule and never sends.
  Future<Set<int>> inertMappingIds() async {
    final Set<int> ids = await mediaServerLibraryMappingIds();
    final List<MediaTrackingMappingRow> rows =
        await (_db.select(_db.mediaTrackingMappings)..where(
              (t) =>
                  t.mediaType.equals(TrackingMediaType.videoCollection.value),
            ))
            .get();
    for (final MediaTrackingMappingRow row in rows) {
      if (ids.contains(row.id)) continue;
      final int? collectionId = int.tryParse(row.mediaKey);
      if (collectionId != null &&
          await isMultiSeasonVideoCollection(collectionId)) {
        ids.add(row.id);
      }
    }
    return ids;
  }

  /// `video` / `video_collection` links of a library row added from a media
  /// server, or of a collection holding one: they never send (the part of
  /// [inertMappingIds] that has this reason).
  Future<Set<int>> mediaServerLibraryMappingIds() async {
    final List<MediaTrackingMappingRow> rows =
        await (_db.select(_db.mediaTrackingMappings)..where(
              (t) => t.mediaType.isIn(<String>[
                TrackingMediaType.videoCollection.value,
                TrackingMediaType.video.value,
              ]),
            ))
            .get();
    return <int>{
      for (final MediaTrackingMappingRow row in rows)
        if (await isMediaServerLibraryItem(
          row.mediaType == TrackingMediaType.video.value
              ? TrackingMediaType.video
              : TrackingMediaType.videoCollection,
          row.mediaKey,
        ))
          row.id,
    };
  }

  /// [mediaType] + [mediaKey] is a library row added from a media server, or
  /// a video collection holding one ([isTrackedThroughMediaServer]).
  Future<bool> isMediaServerLibraryItem(
    TrackingMediaType mediaType,
    String mediaKey,
  ) async {
    if (mediaType == TrackingMediaType.video) {
      final VideoBookRow? video = await _db.getVideoBookByBookUid(mediaKey);
      return video != null && isTrackedThroughMediaServer(video);
    }
    if (mediaType != TrackingMediaType.videoCollection) return false;
    final int? collectionId = int.tryParse(mediaKey);
    if (collectionId == null) return false;
    for (final MediaCollectionItemRow item in await _db.getCollectionItems(
      collectionId,
    )) {
      if (item.mediaType != MediaKind.video.dbValue) continue;
      final VideoBookRow? video = await _db.getVideoBookByBookUid(
        item.entryKey,
      );
      if (video != null && isTrackedThroughMediaServer(video)) return true;
    }
    return false;
  }

  /// Collections holding a library row added from a media server.
  static Set<int> _mediaServerCollections(
    Iterable<MediaCollectionItemRow> members,
    Map<String, VideoBookRow> videosByUid,
  ) => <int>{
    for (final MediaCollectionItemRow member in members)
      if (member.mediaType == MediaKind.video.dbValue)
        if (videosByUid[member.entryKey] case final VideoBookRow video
            when isTrackedThroughMediaServer(video))
          member.collectionId,
  };

  /// Which server identities track the library rows added from a media
  /// server: a row whose episode was remembered (watched to the end or
  /// marked watched, [rememberRemoteEpisode]) is covered by that episode's
  /// key and its season's; a collection by its rows' keys; a row of such a
  /// collection that was not remembered yet by the collection's seasons.
  ///
  /// The row is found by the server's item id: a `media-server://` row's
  /// `bookUid` is the item id, and the episode's key ends with it
  /// ([remoteAnimeItemId]). Local reads only.
  Future<MediaServerLibraryCoverage> loadMediaServerLibraryCoverage() async {
    final Set<String> serverVideos = <String>{
      for (final VideoBookRow video in await _db.allVideoBooks())
        if (isTrackedThroughMediaServer(video)) video.bookUid,
    };
    if (serverVideos.isEmpty) return MediaServerLibraryCoverage.empty;
    final Map<String, List<({TrackingMediaType type, String key})>> byKey =
        <String, List<({TrackingMediaType type, String key})>>{};
    void add(String libraryKey, ({TrackingMediaType type, String key}) key) {
      final List<({TrackingMediaType type, String key})> keys = byKey
          .putIfAbsent(
            libraryKey,
            () => <({TrackingMediaType type, String key})>[],
          );
      if (keys.contains(key)) return;
      // The season first: a hand link of the row links the season.
      if (key.type == TrackingMediaType.remoteSeries) {
        keys.insert(0, key);
      } else {
        keys.add(key);
      }
    }

    for (final MediaTrackingRemoteEpisodeRow row in await listRemoteEpisodes()) {
      final String uid = remoteAnimeItemId(row.mediaKey);
      if (!serverVideos.contains(uid)) continue;
      final String videoKey = '${TrackingMediaType.video.value}|$uid';
      add(videoKey, (type: TrackingMediaType.remoteVideo, key: row.mediaKey));
      if (!row.isMovie && row.groupKey != row.mediaKey) {
        add(videoKey, (
          type: TrackingMediaType.remoteSeries,
          key: row.groupKey,
        ));
      }
    }
    final Map<int, List<String>> membersOf = <int, List<String>>{};
    for (final MediaCollectionItemRow member
        in await _db.getAllCollectionItems()) {
      if (member.mediaType != MediaKind.video.dbValue ||
          !serverVideos.contains(member.entryKey)) {
        continue;
      }
      membersOf
          .putIfAbsent(member.collectionId, () => <String>[])
          .add(member.entryKey);
    }
    for (final MapEntry<int, List<String>> collection in membersOf.entries) {
      final String collectionKey =
          '${TrackingMediaType.videoCollection.value}|${collection.key}';
      for (final String uid in collection.value) {
        for (final ({TrackingMediaType type, String key}) key
            in byKey['${TrackingMediaType.video.value}|$uid'] ??
                const <({TrackingMediaType type, String key})>[]) {
          add(collectionKey, key);
        }
      }
      final List<({TrackingMediaType type, String key})> seasons =
          <({TrackingMediaType type, String key})>[
            for (final ({TrackingMediaType type, String key}) key
                in byKey[collectionKey] ??
                    const <({TrackingMediaType type, String key})>[])
              if (key.type == TrackingMediaType.remoteSeries) key,
          ];
      if (seasons.isEmpty) continue;
      for (final String uid in collection.value) {
        final String videoKey = '${TrackingMediaType.video.value}|$uid';
        if (byKey.containsKey(videoKey)) continue;
        for (final ({TrackingMediaType type, String key}) season in seasons) {
          add(videoKey, season);
        }
      }
    }
    return MediaServerLibraryCoverage(byKey);
  }

  Future<AutoBookTrackingSource?> loadAutoBookSource(String bookKey) async {
    final EpubBookRow? book = await _db.getEpubBook(bookKey);
    if (book == null) return null;
    return (title: book.title, format: book.format);
  }

  /// The book row, for linking (titles, author, series metadata).
  Future<EpubBookRow?> loadBook(String bookKey) => _db.getEpubBook(bookKey);

  /// Stores title matches for the user to review. A subject already stored
  /// for this item (dismissed or not) is kept as it is.
  Future<void> saveSuggestions({
    required String provider,
    required TrackingMediaType mediaType,
    required String mediaKey,
    required List<TrackingSuggestionDraft> suggestions,
  }) async {
    if (suggestions.isEmpty) return;
    final int now = DateTime.now().millisecondsSinceEpoch;
    await _db.batch((Batch batch) {
      batch.insertAll(
        _db.mediaTrackingSuggestions,
        <MediaTrackingSuggestionsCompanion>[
          for (final TrackingSuggestionDraft draft in suggestions)
            MediaTrackingSuggestionsCompanion.insert(
              provider: provider,
              mediaType: mediaType.value,
              mediaKey: mediaKey,
              subjectId: draft.subjectId,
              subjectName: draft.subjectName,
              subjectKind: draft.subjectKind.value,
              score: draft.score,
              detailsJson: Value<String>(jsonEncode(draft.details)),
              createdAt: now,
            ),
        ],
        mode: InsertMode.insertOrIgnore,
      );
    });
  }

  /// Whether this item was ever given suggestions by [provider] (dismissed
  /// ones count: the title search is not repeated behind the user's back).
  Future<bool> hasSuggestions({
    required String provider,
    required TrackingMediaType mediaType,
    required String mediaKey,
  }) async {
    final MediaTrackingSuggestionRow? row =
        await (_db.select(_db.mediaTrackingSuggestions)
              ..where(
                (t) =>
                    t.provider.equals(provider) &
                    t.mediaType.equals(mediaType.value) &
                    t.mediaKey.equals(mediaKey),
              )
              ..limit(1))
            .getSingleOrNull();
    return row != null;
  }

  /// Records that the user rejected [subjectId] for this item (an unlinked
  /// link): a dismissed suggestion, so automatic linking leaves the item to
  /// the user from now on.
  Future<void> rejectSubject({
    required String provider,
    required TrackingMediaType mediaType,
    required String mediaKey,
    required int subjectId,
    required String subjectName,
    required String subjectKind,
  }) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    await _db
        .into(_db.mediaTrackingSuggestions)
        .insert(
          MediaTrackingSuggestionsCompanion.insert(
            provider: provider,
            mediaType: mediaType.value,
            mediaKey: mediaKey,
            subjectId: subjectId,
            subjectName: subjectName,
            subjectKind: subjectKind,
            score: 0,
            createdAt: now,
            dismissedAt: Value<int?>(now),
          ),
          // Score 0 marks a link the user removed ([linksRemovedByUser]); a
          // dismissed suggestion's score is never read again.
          onConflict: DoUpdate(
            (_) => MediaTrackingSuggestionsCompanion(
              score: const Value<double>(0),
              dismissedAt: Value<int?>(now),
            ),
            target: <Column<Object>>[
              _db.mediaTrackingSuggestions.provider,
              _db.mediaTrackingSuggestions.mediaType,
              _db.mediaTrackingSuggestions.mediaKey,
              _db.mediaTrackingSuggestions.subjectId,
            ],
          ),
        );
  }

  /// Items whose link the user removed by hand ([rejectSubject]), per site:
  /// automatic linking leaves them to the user there.
  Future<List<({String provider, String type, String key})>>
  linksRemovedByUser() async {
    final List<MediaTrackingSuggestionRow> rows =
        await (_db.select(_db.mediaTrackingSuggestions)..where(
              (t) => t.dismissedAt.isNotNull() & t.score.equals(0),
            ))
            .get();
    return <({String provider, String type, String key})>[
      for (final MediaTrackingSuggestionRow row in rows)
        (provider: row.provider, type: row.mediaType, key: row.mediaKey),
    ];
  }

  /// Forgets that the user removed [provider]'s link of this item
  /// ([rejectSubject]): a new hand link is the latest explicit action.
  Future<void> clearRemovedByUser({
    required String provider,
    required TrackingMediaType mediaType,
    required String mediaKey,
  }) =>
      (_db.delete(_db.mediaTrackingSuggestions)..where(
            (t) =>
                t.provider.equals(provider) &
                t.mediaType.equals(mediaType.value) &
                t.mediaKey.equals(mediaKey) &
                t.dismissedAt.isNotNull() &
                t.score.equals(0),
          ))
          .go();

  /// The user removed [provider]'s link of this item by hand
  /// ([linksRemovedByUser]).
  Future<bool> isLinkRemovedByUser({
    required String provider,
    required TrackingMediaType mediaType,
    required String mediaKey,
  }) async {
    final MediaTrackingSuggestionRow? row =
        await (_db.select(_db.mediaTrackingSuggestions)
              ..where(
                (t) =>
                    t.provider.equals(provider) &
                    t.mediaType.equals(mediaType.value) &
                    t.mediaKey.equals(mediaKey) &
                    t.dismissedAt.isNotNull() &
                    t.score.equals(0),
              )
              ..limit(1))
            .getSingleOrNull();
    return row != null;
  }

  /// Hides a suggestion for good (it stays stored, so the same match is not
  /// suggested again).
  Future<void> dismissSuggestion(int id) =>
      (_db.update(_db.mediaTrackingSuggestions)..where((t) => t.id.equals(id)))
          .write(
            MediaTrackingSuggestionsCompanion(
              dismissedAt: Value<int?>(DateTime.now().millisecondsSinceEpoch),
            ),
          );

  /// Suggestions for one item, best first; dismissed ones only when asked.
  Future<List<MediaTrackingSuggestionRow>> loadSuggestions({
    required TrackingMediaType mediaType,
    required String mediaKey,
    String? provider,
    bool includeDismissed = false,
  }) =>
      (_db.select(_db.mediaTrackingSuggestions)
            ..where(
              (t) =>
                  t.mediaType.equals(mediaType.value) &
                  t.mediaKey.equals(mediaKey) &
                  (provider == null
                      ? const Constant<bool>(true)
                      : t.provider.equals(provider)) &
                  (includeDismissed
                      ? const Constant<bool>(true)
                      : t.dismissedAt.isNull()),
            )
            ..orderBy(<OrderClauseGenerator<$MediaTrackingSuggestionsTable>>[
              (t) => OrderingTerm.desc(t.score),
            ]))
          .get();

  /// 游戏刮削源里的 Bangumi 条目 id。
  ///
  /// `galgame_sources.source` 用的是刮削源 key（`bgm`），与本层的 provider 名
  /// （`bangumi`）不是同一个值域，不能互相套用。VNDB 的 `externalId` 形如 `v12345`，
  /// 不是 Bangumi subject id，必须按 source 过滤后再解析。
  int? _bangumiSubjectIdOf(List<GalgameSourceRow> sources) {
    for (final GalgameSourceRow row in sources) {
      if (row.source != GalgameMetadataSource.bgm.key) continue;
      final int? id = int.tryParse((row.externalId ?? '').trim());
      if (id != null && id > 0) return id;
    }
    return null;
  }

  /// The MAL id + episode number of one local file, or null when the scraped
  /// data does not say so unambiguously.
  ///
  /// The database keeps one MAL cross-reference per work and no episode offset
  /// (an AniDB anime can map to several MAL entries), so this only answers when
  /// nothing can be off by a season or an offset:
  /// - the file is bound to exactly one regular episode (season number > 0);
  /// - its work has exactly one regular season (so the MAL id means it);
  /// - the MAL id is on that season, or on the work.
  /// The episode number is AniDB's own when it is a plain number (AniDB and MAL
  /// count one entry the same way), otherwise the scraped one. The caller must
  /// still check the provider's episode count against [episodeCount].
  Future<VideoTrackingIds?> loadVideoTrackingIds(String bookUid) async {
    final List<VideoMetadataEpisodeRow> episodes = await (_db.select(
      _db.videoMetadataEpisodes,
    )..where((t) => t.bookUid.equals(bookUid))).get();
    if (episodes.length != 1) return null;
    final VideoMetadataEpisodeRow episode = episodes.single;
    final VideoMetadataSeasonRow? season = await (_db.select(
      _db.videoMetadataSeasons,
    )..where((t) => t.id.equals(episode.seasonId))).getSingleOrNull();
    if (season == null || season.seasonNumber <= 0) return null;
    final List<VideoMetadataSeasonRow> regularSeasons =
        await (_db.select(_db.videoMetadataSeasons)..where(
              (t) =>
                  t.workId.equals(season.workId) &
                  t.seasonNumber.isBiggerThanValue(0),
            ))
            .get();
    if (regularSeasons.length != 1) return null;

    Future<int?> malOf(
      Expression<bool> Function($VideoMetadataProviderIdentitiesTable) owner,
    ) async {
      final VideoMetadataProviderIdentityRow? row = await (_db.select(
        _db.videoMetadataProviderIdentities,
      )..where((t) => owner(t) & t.provider.equals('mal'))).getSingleOrNull();
      final int? id = int.tryParse(row?.externalId.trim() ?? '');
      return id != null && id > 0 ? id : null;
    }

    final int? malId =
        await malOf((t) => t.seasonId.equals(season.id)) ??
        await malOf((t) => t.workId.equals(season.workId));
    if (malId == null) return null;
    final int? anidbNumber = int.tryParse(
      episode.anidbEpisodeNumber?.trim() ?? '',
    );
    final int number = anidbNumber ?? episode.episodeNumber;
    if (number <= 0) return null;
    final VideoMetadataWorkRow? work = await (_db.select(
      _db.videoMetadataWorks,
    )..where((t) => t.id.equals(season.workId))).getSingleOrNull();
    return (
      malAnimeId: malId,
      episodeNumber: number,
      episodeCount: season.episodeCount,
      title: work?.title ?? '',
    );
  }

  Future<AutoGameTrackingSource?> loadAutoGameSource(String gameId) async {
    final GalgameRow? game = await _db.getGalgame(gameId);
    if (game == null) return null;
    return (
      name: game.name,
      bangumiSubjectId: _bangumiSubjectIdOf(
        await _db.getGalgameSources(gameId),
      ),
    );
  }

  /// 返回自 [afterMs] 之后需要重新对齐的游戏收藏状态。
  ///
  /// 游戏状态是用户显式设置的离散值，正常路径在设置当下即时入队；本方法只兜两种
  /// 「事件已经发生过但当时发不出去」的情况：换账号后水位归零的全量重建，以及先设
  /// 状态、之后才刮到 Bangumi 条目或才建立映射。`galgames` 表没有「最后修改时刻」列，
  /// 因此 evidence 取 `max(mapping.updatedAt, addedAt)`——足以覆盖新增游戏与新建/
  /// 改动映射，状态本身的变更由即时入队负责，不依赖这里。
  Future<List<PersistedGameTrackingStatus>> loadPersistedGameTrackingStatus({
    required int afterMs,
    String provider = kTrackingProviderBangumi,
  }) async {
    final List<GalgameRow> games = await _db.getAllGalgames();
    if (games.isEmpty) return const <PersistedGameTrackingStatus>[];
    final Map<String, List<GalgameSourceRow>> sources = await _db
        .getAllGalgameSources();
    final Map<String, MediaTrackingMappingRow> mappings =
        <String, MediaTrackingMappingRow>{};
    for (final MediaTrackingMappingRow mapping in await listMappings(
      provider: provider,
    )) {
      if (mapping.mediaType != TrackingMediaType.game.value) continue;
      mappings[mapping.mediaKey] = mapping;
    }

    final List<PersistedGameTrackingStatus> result =
        <PersistedGameTrackingStatus>[];
    for (final GalgameRow game in games) {
      // 0 = 未设置：用户从没表态过，不能凭空往远端写一个收藏状态。
      if (game.playStatus <= 0) continue;
      final int evidenceAt = math.max(
        mappings[game.id]?.updatedAt ?? 0,
        game.addedAt,
      );
      if (evidenceAt <= afterMs) continue;
      result.add((
        gameId: game.id,
        name: game.name,
        bangumiSubjectId: _bangumiSubjectIdOf(
          sources[game.id] ?? const <GalgameSourceRow>[],
        ),
        status: game.playStatus,
        evidenceAt: evidenceAt,
      ));
    }
    return result;
  }

  /// 返回这本书「已读完多少章」，**null = 这本书没有章的概念，不要上报章进度**。
  ///
  /// 只有 `format='epub'` 的文字书有章。PDF / 漫画的 `chaptersJson` 是 `'[]'`、
  /// `tocJson` 是 null，阅读位置的 `sectionIndex` 存的是**页码**——旧实现在这里只
  /// 挡了 `'manga'`，PDF 一路走下去会在 [estimateCompletedBookChapters] 的
  /// 「无 toc 即早退」分支拿到 `fallbackProgress`，也就是把**当前页码当成已读章数**
  /// 报给 Bangumi。两个调用点（这里与下面 loadPersistedBookTrackingProgress）现在按
  /// 同一判据 [BookFormat.isPagedImageBook] 收口，缺一处就会重新漂开。
  Future<int?> loadBookChapterProgress({
    required String bookKey,
    required int fallbackProgress,
  }) async => (await loadBookTrackingSnapshot(
    bookKey: bookKey,
    fallbackProgress: fallbackProgress,
  )).chapterProgress;

  /// 读取即时上报所需的格式与逻辑章节快照。
  ///
  /// chapter/volume 的最终选择统一交给 [resolveBookTrackingLocalProgress]；这里仅把
  /// PDF/漫画的“无章节”事实表达成 null，并为 EPUB 计算逻辑 TOC 章节数。
  Future<BookTrackingSnapshot> loadBookTrackingSnapshot({
    required String bookKey,
    required int fallbackProgress,
    MangaReadProgressResolver? mangaProgress,
  }) async {
    final EpubBookRow? book = await _db.getEpubBook(bookKey);
    if (book == null) {
      return (
        format: BookFormat.epub,
        chapterProgress: math.max(0, fallbackProgress),
      );
    }
    final BookFormat format = BookFormat.parseOrEpub(book.format);
    if (format == BookFormat.manga) {
      return (
        format: format,
        chapterProgress: (await mangaProgress?.call(book))?.highestChapter,
      );
    }
    if (format.isPagedImageBook) {
      return (format: format, chapterProgress: null);
    }
    // v82：位置键 = 书 uid（行在手直接取；空 uid 视同无阅读记录）。
    final ReaderPositionRow? position = book.uid.isEmpty
        ? null
        : await _db.getReaderPosition(book.uid);
    if (position == null) {
      return (format: format, chapterProgress: math.max(0, fallbackProgress));
    }
    return (
      format: format,
      chapterProgress: estimateCompletedBookChapters(
        chaptersJson: book.chaptersJson,
        tocJson: book.tocJson,
        sectionIndex: position.sectionIndex,
        sectionCompleted: position.normCharOffset >= 9990,
        bookCompleted: book.completedAt != null,
        fallbackProgress: fallbackProgress,
      ),
    );
  }

  /// Whether [bookKey] counts as finished for tracking: an online manga series
  /// when every listed chapter is read, anything else when it is marked
  /// completed. (An online series row gets `completedAt` at the end of any
  /// chapter, so that flag says nothing about the series.)
  Future<bool> isBookFinishedForTracking({
    required String bookKey,
    MangaReadProgressResolver? mangaProgress,
  }) async {
    final EpubBookRow? book = await _db.getEpubBook(bookKey);
    if (book == null) return false;
    if (BookFormat.parseOrEpub(book.format) == BookFormat.manga) {
      final MangaReadProgress? progress = await mangaProgress?.call(book);
      if (progress != null) return progress.allRead;
    }
    return book.completedAt != null;
  }

  /// 返回自 [afterMs] 之后新增或重新映射的本地已完成视频进度。
  ///
  /// 旧版只在跨过 90% 阈值的瞬间发同步事件；状态语义修正后，已经完成且 outbox
  /// 早已清空的条目不会再自然触发。这里从本地「看完」事实（[_videoWatchedAtMs]）
  /// 重建一次增量，同时把 mapping.updatedAt 纳入 evidence，使“给旧完成条目
  /// 新增/修改映射”也会补发。
  Future<List<CompletedVideoTrackingProgress>>
  loadCompletedVideoTrackingProgress({
    required int afterMs,
    String provider = kTrackingProviderBangumi,
  }) async {
    final List<MediaTrackingMappingRow> mappings = await listMappings(
      provider: provider,
    );
    final List<CompletedVideoTrackingProgress> result =
        <CompletedVideoTrackingProgress>[];
    if (!mappings.any(
      (MediaTrackingMappingRow m) =>
          m.progressMode == TrackingProgressMode.episode.value,
    )) {
      return result;
    }
    final Map<String, int> durations = await loadKnownVideoDurationsMs(_db);

    for (final MediaTrackingMappingRow mapping in mappings) {
      if (mapping.progressMode != TrackingProgressMode.episode.value) {
        continue;
      }

      if (mapping.mediaType == TrackingMediaType.video.value) {
        final VideoBookRow? video = await _db.getVideoBookByBookUid(
          mapping.mediaKey,
        );
        // A media server row sends through its server identity only.
        final int? watchedAt =
            video == null || isTrackedThroughMediaServer(video)
            ? null
            : _videoWatchedAtMs(video, durations);
        if (watchedAt == null) continue;
        final int evidenceAt = math.max(mapping.updatedAt, watchedAt);
        if (evidenceAt <= afterMs) continue;
        result.add((
          mediaType: TrackingMediaType.video,
          mediaKey: mapping.mediaKey,
          localProgress: 0,
          completed: true,
          evidenceAt: evidenceAt,
        ));
        continue;
      }

      if (mapping.mediaType != TrackingMediaType.videoCollection.value) {
        continue;
      }
      final int? collectionId = int.tryParse(mapping.mediaKey);
      if (collectionId == null) continue;
      final List<MediaCollectionItemRow> items =
          (await _db.getCollectionItems(collectionId))
              .where(
                (MediaCollectionItemRow item) =>
                    item.mediaType == MediaKind.video.dbValue,
              )
              .toList(growable: false);
      final List<VideoBookRow?> videos = <VideoBookRow?>[
        for (final MediaCollectionItemRow item in items)
          await _db.getVideoBookByBookUid(item.entryKey),
      ];
      // A collection of media server rows sends through their server
      // identity only.
      if (videos.any(
        (VideoBookRow? video) =>
            video != null && isTrackedThroughMediaServer(video),
      )) {
        continue;
      }
      // 多季分组合集（分组按文件名现场派生，不落库）：整合集映射结构性失真
      // （Bangumi 一季一条目，合集下标当集数会把第二季完结报给第一季 subject）。
      // 补发跳过合集级映射，按集映射的补发由上面的 video 分支承担。
      if (isMultiSeasonGrouped(<String>[
        for (final VideoBookRow? video in videos)
          if (video != null) collectionGroupKeyForFilename(video.videoPath),
      ])) {
        continue;
      }
      int highestCompletedIndex = -1;
      int latestCompletedAt = 0;
      for (int index = 0; index < videos.length; index++) {
        final VideoBookRow? video = videos[index];
        final int? watchedAt = video == null
            ? null
            : _videoWatchedAtMs(video, durations);
        if (watchedAt == null) continue;
        highestCompletedIndex = index;
        latestCompletedAt = math.max(latestCompletedAt, watchedAt);
      }
      if (highestCompletedIndex < 0) continue;
      final int evidenceAt = math.max(mapping.updatedAt, latestCompletedAt);
      if (evidenceAt <= afterMs) continue;
      result.add((
        mediaType: TrackingMediaType.videoCollection,
        mediaKey: mapping.mediaKey,
        localProgress: highestCompletedIndex,
        completed: highestCompletedIndex == items.length - 1,
        evidenceAt: evidenceAt,
      ));
    }
    return result;
  }

  /// When [video] counts as watched (ms since epoch), or null when it does not.
  ///
  /// Playback stopped writing `completed_at` (BUG-3491), so the manual mark
  /// alone misses every episode finished since. Same rule as the app's
  /// collection progress (`CollectionMemberProgress.countsAsWatched`): the mark,
  /// or a saved position in the end zone of a known duration
  /// ([isEpisodePositionNearEnd]). The time of the latter is `lastPlayedAt`,
  /// written together with the position; 0 when an old row has none
  /// (BUG-4401).
  static int? _videoWatchedAtMs(
    VideoBookRow video,
    Map<String, int> durationsMs,
  ) {
    final DateTime? completedAt = video.completedAt;
    if (completedAt != null) return completedAt.millisecondsSinceEpoch;
    if (isEpisodePositionNearEnd(
      savedMs: video.lastPositionMs,
      durationMs: durationsMs[video.bookUid],
    )) {
      return video.lastPlayedAt ?? 0;
    }
    return null;
  }

  /// 从阅读位置和书籍完成标记恢复自 [afterMs] 之后的可靠阅读事件。
  ///
  /// chapter 模式按已完成章节数恢复；volume 模式在读时用 -1 配合卷号 offset，
  /// 只报告“此前卷数”，当前卷读完才用 0 把本卷计入，避免刚打开第 N 卷就误报 N 卷。
  Future<List<PersistedBookTrackingProgress>>
  loadPersistedBookTrackingProgress({
    required int afterMs,
    String provider = kTrackingProviderBangumi,
    MangaReadProgressResolver? mangaProgress,
  }) async {
    final List<MediaTrackingMappingRow> mappings = await listMappings(
      provider: provider,
    );
    final List<PersistedBookTrackingProgress> result =
        <PersistedBookTrackingProgress>[];
    for (final MediaTrackingMappingRow mapping in mappings) {
      final TrackingMediaType? mediaType =
          mapping.mediaType == TrackingMediaType.book.value
          ? TrackingMediaType.book
          : mapping.mediaType == TrackingMediaType.bookChapter.value
          ? TrackingMediaType.bookChapter
          : null;
      if (mediaType == null) continue;
      final EpubBookRow? book = await _db.getEpubBook(mapping.mediaKey);
      if (book == null) continue;
      // v82：mapping.mediaKey 是 bookKey（映射面貌冻结）；位置键 = 书 uid，
      // 从刚查到的行取（空 uid 视同无阅读记录）。
      final ReaderPositionRow? position = book.uid.isEmpty
          ? null
          : await _db.getReaderPosition(book.uid);
      final MangaReadProgress? manga =
          BookFormat.parseOrEpub(book.format) == BookFormat.manga
          ? await mangaProgress?.call(book)
          : null;
      final DateTime? completedAt = book.completedAt;
      if (position == null && completedAt == null && manga == null) continue;
      final int localEvidenceAt = math.max(
        math.max(
          position?.updatedAt ?? 0,
          completedAt?.millisecondsSinceEpoch ?? 0,
        ),
        manga?.lastReadAt ?? 0,
      );
      final int evidenceAt = math.max(mapping.updatedAt, localEvidenceAt);
      if (evidenceAt <= afterMs) continue;

      final bool isChapterCompanion =
          mediaType == TrackingMediaType.bookChapter;
      final bool completed = manga != null
          ? manga.allRead
          : completedAt != null;
      final BookFormat format = BookFormat.parseOrEpub(book.format);
      // BUG-1318: a link made while the book had another format (re-imported
      // as manga, or the reverse) must not send progress for the wrong entry.
      // Bangumi keeps its legacy behaviour.
      if (provider != kTrackingProviderBangumi &&
          !bookFormatTracksAs(format, mapping.kind)) {
        continue;
      }
      final TrackingProgressMode? storedMode = TrackingProgressMode.tryParse(
        mapping.progressMode,
      );
      final TrackingProgressMode? effectiveMode = isChapterCompanion
          ? TrackingProgressMode.chapter
          : storedMode;
      if (effectiveMode == null) continue;
      final int? chapterProgress = format == BookFormat.manga
          ? manga?.highestChapter
          : format.isPagedImageBook
          ? null
          : estimateCompletedBookChapters(
              chaptersJson: book.chaptersJson,
              tocJson: book.tocJson,
              sectionIndex: position?.sectionIndex ?? 0,
              sectionCompleted: (position?.normCharOffset ?? 0) >= 9990,
              bookCompleted: completed,
              fallbackProgress:
                  (position?.sectionIndex ?? 0) +
                  ((position?.normCharOffset ?? 0) >= 9990 ? 1 : 0),
            );
      final int? localProgress = resolveBookTrackingLocalProgress(
        format: format,
        progressMode: effectiveMode,
        chapterProgress: chapterProgress,
        completed: completed,
      );
      if (localProgress == null) continue;
      result.add((
        mediaKey: mapping.mediaKey,
        mediaType: mediaType,
        localProgress: localProgress,
        completed: isChapterCompanion ? false : completed,
        evidenceAt: evidenceAt,
      ));
    }
    return result;
  }

  /// Every link of [provider] and the queued update of each (a hand link
  /// is undone by comparing two of these, [restoreLinkState]).
  Future<TrackingLinkState> captureLinkState(String provider) async {
    final List<MediaTrackingMappingRow> mappings = await listMappings(
      provider: provider,
    );
    final List<int> ids = <int>[
      for (final MediaTrackingMappingRow row in mappings) row.id,
    ];
    final List<MediaTrackingOutboxRow> outbox = ids.isEmpty
        ? const <MediaTrackingOutboxRow>[]
        : await (_db.select(
            _db.mediaTrackingOutbox,
          )..where((t) => t.mappingId.isIn(ids))).get();
    return TrackingLinkState(
      mappings: <int, MediaTrackingMappingRow>{
        for (final MediaTrackingMappingRow row in mappings) row.id: row,
      },
      outbox: <int, MediaTrackingOutboxRow>{
        for (final MediaTrackingOutboxRow row in outbox) row.mappingId: row,
      },
    );
  }

  /// Puts the links that changed between [before] and [after] back the way
  /// they were in [before]: links added since are deleted (with what they
  /// queued and has not been sent), links changed or removed are written
  /// back with their old queued update (or none). Links nobody touched in
  /// between are left alone.
  Future<void> restoreLinkState({
    required TrackingLinkState before,
    required TrackingLinkState after,
  }) => _db.transaction(() async {
    for (final int id in after.mappings.keys) {
      if (!before.mappings.containsKey(id)) {
        await (_db.delete(
          _db.mediaTrackingMappings,
        )..where((t) => t.id.equals(id))).go();
      }
    }
    for (final MapEntry<int, MediaTrackingMappingRow> entry
        in before.mappings.entries) {
      final MediaTrackingMappingRow? now = after.mappings[entry.key];
      final MediaTrackingOutboxRow? queuedBefore = before.outbox[entry.key];
      if (now == entry.value && after.outbox[entry.key] == queuedBefore) {
        continue;
      }
      // An update, not INSERT OR REPLACE: replacing would delete the row
      // first and cascade to its queued update.
      final bool updated = await _db
          .update(_db.mediaTrackingMappings)
          .replace(entry.value);
      if (!updated) {
        await _db.into(_db.mediaTrackingMappings).insert(entry.value);
      }
      await (_db.delete(
        _db.mediaTrackingOutbox,
      )..where((t) => t.mappingId.equals(entry.key))).go();
      if (queuedBefore != null) {
        await _db.into(_db.mediaTrackingOutbox).insert(queuedBefore);
      }
    }
  });

  /// `type|key` of every local item with suggestions waiting for review on
  /// some site (not dismissed).
  Future<Set<String>> itemsWithOpenSuggestions() async {
    final List<MediaTrackingSuggestionRow> rows = await (_db.select(
      _db.mediaTrackingSuggestions,
    )..where((t) => t.dismissedAt.isNull())).get();
    return <String>{
      for (final MediaTrackingSuggestionRow row in rows)
        '${row.mediaType}|${row.mediaKey}',
    };
  }

  Future<void> deleteMapping(int id) async {
    final MediaTrackingMappingRow? mapping = await (_db.select(
      _db.mediaTrackingMappings,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (mapping == null) return;
    if (mapping.mediaType != TrackingMediaType.book.value) {
      await (_db.delete(
        _db.mediaTrackingMappings,
      )..where((t) => t.id.equals(id))).go();
      return;
    }
    await (_db.delete(_db.mediaTrackingMappings)..where(
          (t) =>
              t.provider.equals(mapping.provider) &
              t.mediaKey.equals(mapping.mediaKey) &
              t.mediaType.isIn(<String>[
                TrackingMediaType.book.value,
                TrackingMediaType.bookChapter.value,
              ]),
        ))
        .go();
  }

  /// 将本地 0-based [localProgress] 翻译为远端进度并入队。没有映射、或作品被标成
  /// 私密时返回 false；调用方据此无声跳过，播放/阅读主路径不受外部服务影响。
  ///
  /// [monotonic] 为 true（默认）时沿用“进度只增不减”的合并：观看/阅读进度天然单调，
  /// 取 max 可以让乱序到达的事件收敛到最新位置。收藏状态类事件必须传 false——它是
  /// 离散状态而非进度，取 max 会让「弃坑(5) → 在玩(3)」这种正当回退被永久吃掉，
  /// 用户再也改不回来。此时按最后写入者胜（LWW）覆盖。
  Future<bool> enqueueProgress({
    required TrackingMediaType mediaType,
    required String mediaKey,
    required int localProgress,
    required bool completed,
    bool monotonic = true,
    String provider = kTrackingProviderBangumi,
  }) async {
    final MediaTrackingMappingRow? mapping = await findMapping(
      mediaType: mediaType,
      mediaKey: mediaKey,
      provider: provider,
    );
    if (mapping == null) return false;
    if (isTrackedMediaPrivate(await loadPrivacy(), mediaType.value, mediaKey)) {
      return false;
    }
    // Do-not-track: the link stays, nothing is queued (taking the item off
    // the list queues its current progress, `MediaTrackingService.trackAgain`).
    if ((await loadIgnoreIndex()).covers(mediaType.value, mediaKey)) {
      return false;
    }
    final int progress = math.max(0, localProgress + mapping.progressOffset);
    final int now = DateTime.now().millisecondsSinceEpoch;
    await _db.transaction(() async {
      final MediaTrackingOutboxRow? existing = await (_db.select(
        _db.mediaTrackingOutbox,
      )..where((t) => t.mappingId.equals(mapping.id))).getSingleOrNull();
      if (existing == null) {
        // Already on the site (BUG-4396): what the link last sent covers this
        // event, so nothing is queued. Without this a replay after a restart
        // (the in-memory de-dup is empty then) sent the same progress again.
        if (_sentCovers(mapping, progress, completed, monotonic: monotonic)) {
          return;
        }
        await _db
            .into(_db.mediaTrackingOutbox)
            .insert(
              MediaTrackingOutboxCompanion.insert(
                mappingId: mapping.id,
                progress: progress,
                completed: Value<bool>(completed),
                updatedAt: now,
              ),
            );
        return;
      }
      final int mergedProgress = monotonic
          ? math.max(existing.progress, progress)
          : progress;
      final bool mergedCompleted = monotonic
          ? (existing.completed || completed)
          : completed;
      // 毫秒时钟可能在同一 tick 连收两次事件；乐观锁版本必须严格递增，不能只写 now。
      final int eventVersion = math.max(now, existing.updatedAt + 1);
      // A row held back for a hand link's Undo window ([holdQueued]) keeps
      // waiting: a new event must not send what the user may still undo.
      final int nextAttemptAt = _isHeld(existing, now)
          ? existing.nextAttemptAt
          : 0;
      await (_db.update(
        _db.mediaTrackingOutbox,
      )..where((t) => t.id.equals(existing.id))).write(
        MediaTrackingOutboxCompanion(
          progress: Value<int>(mergedProgress),
          completed: Value<bool>(mergedCompleted),
          // 新事件应立即可重试；同时清掉旧错误，UI 不展示已经过时的失败。
          attemptCount: const Value<int>(0),
          nextAttemptAt: Value<int>(nextAttemptAt),
          lastError: const Value<String?>(null),
          updatedAt: Value<int>(eventVersion),
        ),
      );
    });
    return true;
  }

  /// [row] waits for a hand link's Undo window ([holdQueued]): never tried
  /// yet and not due. Rows that failed wait for their backoff instead
  /// (`attemptCount` > 0).
  static bool _isHeld(MediaTrackingOutboxRow row, int nowMs) =>
      row.attemptCount == 0 && row.nextAttemptAt > nowMs;

  /// Holds the queued updates of [mappingIds] back until [untilMs] (a hand
  /// link's Undo window): nothing of them is sent before then unless
  /// [releaseHeld] lets them go. Stored on the queued row, so the hold ends
  /// by itself after a restart and nothing is lost.
  Future<void> holdQueued(Iterable<int> mappingIds, int untilMs) async {
    final List<int> ids = mappingIds.toList(growable: false);
    if (ids.isEmpty) return;
    await (_db.update(_db.mediaTrackingOutbox)..where(
          (t) => t.mappingId.isIn(ids) & t.attemptCount.equals(0),
        ))
        .write(MediaTrackingOutboxCompanion(nextAttemptAt: Value<int>(untilMs)));
  }

  /// Ends the hold ([holdQueued]) of [mappingIds] (null = every held row):
  /// they are due now. Rows backing off after a failure are left alone.
  Future<void> releaseHeld([Iterable<int>? mappingIds]) async {
    final List<int>? ids = mappingIds?.toList(growable: false);
    if (ids != null && ids.isEmpty) return;
    await (_db.update(_db.mediaTrackingOutbox)..where(
          (t) =>
              t.attemptCount.equals(0) &
              t.nextAttemptAt.isBiggerThanValue(0) &
              (ids == null
                  ? const Constant<bool>(true)
                  : t.mappingId.isIn(ids)),
        ))
        .write(const MediaTrackingOutboxCompanion(nextAttemptAt: Value<int>(0)));
  }

  /// [mapping]'s last send ([MediaTrackingMappingRow.sentProgress]) already
  /// says [progress] / [completed]: the same status for a `status` link,
  /// else at least this progress and done when this is done. Nothing
  /// recorded (null, or -1 for a link made before v152) covers nothing.
  static bool _sentCovers(
    MediaTrackingMappingRow mapping,
    int progress,
    bool completed, {
    required bool monotonic,
  }) {
    final int? sent = mapping.sentProgress;
    if (sent == null || sent < 0) return false;
    if (!monotonic ||
        mapping.progressMode == TrackingProgressMode.status.value) {
      return sent == progress && mapping.sentCompleted == completed;
    }
    return sent >= progress && (mapping.sentCompleted || !completed);
  }

  /// [provider] null = every provider. The sync coordinator always passes one,
  /// so one provider's backlog can never take another provider's batch slots,
  /// and a provider is never handed rows it does not own.
  ///
  /// [kinds] null = every kind; otherwise only rows whose mapping kind is
  /// listed (a kind the user switched off is left waiting, not sent).
  Future<List<PendingTrackingUpdate>> dueUpdates({
    int limit = 20,
    int? nowMs,
    String? provider,
    Iterable<TrackingKind>? kinds,
  }) async {
    final int now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    Expression<bool> filter = _db.mediaTrackingOutbox.nextAttemptAt
        .isSmallerOrEqualValue(now);
    if (provider != null) {
      filter = filter & _db.mediaTrackingMappings.provider.equals(provider);
    }
    if (kinds != null) {
      filter =
          filter &
          _db.mediaTrackingMappings.kind.isIn(
            kinds.map((TrackingKind kind) => kind.value),
          );
    }
    // Rows of ignored items wait untouched (paused) and take no batch slot.
    final List<int> paused = await ignoredMappingIds(provider: provider);
    if (paused.isNotEmpty) {
      filter = filter & _db.mediaTrackingOutbox.mappingId.isNotIn(paused);
    }
    final query =
        _db.select(_db.mediaTrackingOutbox).join(<Join>[
            innerJoin(
              _db.mediaTrackingMappings,
              _db.mediaTrackingMappings.id.equalsExp(
                _db.mediaTrackingOutbox.mappingId,
              ),
            ),
          ])
          ..where(filter)
          ..orderBy(<OrderingTerm>[
            OrderingTerm(expression: _db.mediaTrackingOutbox.updatedAt),
          ])
          ..limit(limit);
    final List<TypedResult> rows = await query.get();
    final List<PendingTrackingUpdate> updates = rows
        .map(
          (TypedResult row) => PendingTrackingUpdate(
            outbox: row.readTable(_db.mediaTrackingOutbox),
            mapping: row.readTable(_db.mediaTrackingMappings),
          ),
        )
        .toList(growable: false);
    if (updates.isEmpty) return updates;
    // 入队之后才被标成私密的作品：丢弃其待发行，绝不发出去（留着还会一直占发送名额）。
    final MediaPrivacySnapshot privacy = await loadPrivacy();
    if (privacy.isEmpty) return updates;
    final List<PendingTrackingUpdate> due = <PendingTrackingUpdate>[];
    final List<int> discarded = <int>[];
    for (final PendingTrackingUpdate u in updates) {
      if (isTrackedMediaPrivate(
        privacy,
        u.mapping.mediaType,
        u.mapping.mediaKey,
      )) {
        discarded.add(u.outbox.id);
      } else {
        due.add(u);
      }
    }
    if (discarded.isNotEmpty) {
      await (_db.delete(
        _db.mediaTrackingOutbox,
      )..where((t) => t.id.isIn(discarded))).go();
    }
    return due;
  }

  /// Ids of the links whose item is on the do-not-track list ([provider]
  /// null = every provider).
  Future<List<int>> ignoredMappingIds({String? provider}) async {
    final TrackingIgnoreIndex ignored = await loadIgnoreIndex();
    if (ignored.isEmpty) return const <int>[];
    return <int>[
      for (final MediaTrackingMappingRow row in await listMappings(
        provider: provider,
      ))
        if (ignored.covers(row.mediaType, row.mediaKey)) row.id,
    ];
  }

  /// 全部待同步行（**不**按 `nextAttemptAt` 过滤），带各自的映射。
  ///
  /// 与 [dueUpdates] 的区别是它服务于「展示」而不是「发送」：失败行退避最长 6 小时，
  /// 若 UI 也只看 due 的行，用户在退避窗口里看到的会是「零待办、零错误」，正好把
  /// 失败原因藏起来。按 updatedAt 倒序，最近的事件排在前面。
  ///
  /// [provider] null = every provider.
  Future<List<PendingTrackingUpdate>> allPending({
    int limit = 50,
    String? provider,
  }) async {
    final query =
        _db.select(_db.mediaTrackingOutbox).join(<Join>[
            innerJoin(
              _db.mediaTrackingMappings,
              _db.mediaTrackingMappings.id.equalsExp(
                _db.mediaTrackingOutbox.mappingId,
              ),
            ),
          ])
          ..orderBy(<OrderingTerm>[
            OrderingTerm(
              expression: _db.mediaTrackingOutbox.updatedAt,
              mode: OrderingMode.desc,
            ),
          ])
          ..limit(limit);
    if (provider != null) {
      query.where(_db.mediaTrackingMappings.provider.equals(provider));
    }
    final List<TypedResult> rows = await query.get();
    return rows
        .map(
          (TypedResult row) => PendingTrackingUpdate(
            outbox: row.readTable(_db.mediaTrackingOutbox),
            mapping: row.readTable(_db.mediaTrackingMappings),
          ),
        )
        .toList(growable: false);
  }

  /// Outbox rows whose mapping belongs to [provider].
  Expression<bool> _outboxOfProvider(String provider) =>
      _db.mediaTrackingOutbox.mappingId.isInQuery(
        _db.selectOnly(_db.mediaTrackingMappings)
          ..addColumns(<Expression<Object>>[_db.mediaTrackingMappings.id])
          ..where(_db.mediaTrackingMappings.provider.equals(provider)),
      );

  /// [provider] null = every provider.
  Future<int> pendingCount({String? provider}) async {
    final Expression<int> count = _db.mediaTrackingOutbox.id.count();
    final query = _db.selectOnly(_db.mediaTrackingOutbox)
      ..addColumns(<Expression>[count]);
    if (provider != null) {
      query.where(_outboxOfProvider(provider));
    }
    final TypedResult row = await query.getSingle();
    return row.read(count) ?? 0;
  }

  /// [sent] reached the site: the row goes (unless a newer event merged into
  /// it meanwhile, optimistic lock) and its link remembers what was sent
  /// ([MediaTrackingMappingRow.sentProgress]: the highest progress, the last
  /// status for a `status` link) for the catch-up.
  Future<void> markSucceeded(MediaTrackingOutboxRow sent) =>
      _db.transaction(() async {
        await (_db.delete(_db.mediaTrackingOutbox)..where(
              (t) => t.id.equals(sent.id) & t.updatedAt.equals(sent.updatedAt),
            ))
            .go();
        await _db.customUpdate(
          'UPDATE media_tracking_mappings SET '
          "sent_progress = CASE WHEN progress_mode = 'status' THEN ?1 "
          'ELSE MAX(COALESCE(sent_progress, -1), ?1) END, '
          "sent_completed = CASE WHEN progress_mode = 'status' THEN ?2 "
          'ELSE (sent_completed OR ?2) END '
          'WHERE id = ?3',
          variables: <Variable<Object>>[
            Variable<int>(sent.progress),
            Variable<bool>(sent.completed),
            Variable<int>(sent.mappingId),
          ],
          updates: <TableInfo<Table, Object?>>{_db.mediaTrackingMappings},
        );
      });

  /// Queued rows of [provider], keyed by mapping id (every row; the
  /// catch-up's "already on its way" check).
  Future<Map<int, MediaTrackingOutboxRow>> queuedByMapping({
    required String provider,
  }) async {
    final query = _db.select(_db.mediaTrackingOutbox).join(<Join>[
      innerJoin(
        _db.mediaTrackingMappings,
        _db.mediaTrackingMappings.id.equalsExp(
          _db.mediaTrackingOutbox.mappingId,
        ),
      ),
    ])..where(_db.mediaTrackingMappings.provider.equals(provider));
    return <int, MediaTrackingOutboxRow>{
      for (final TypedResult row in await query.get())
        row.readTable(_db.mediaTrackingOutbox).mappingId: row.readTable(
          _db.mediaTrackingOutbox,
        ),
    };
  }

  /// Forgets what [provider]'s links of [mediaTypes] were sent with (a new
  /// account: everything goes again).
  Future<void> clearSentProgress({
    required String provider,
    required Iterable<TrackingMediaType> mediaTypes,
  }) =>
      (_db.update(_db.mediaTrackingMappings)..where(
            (t) =>
                t.provider.equals(provider) &
                t.mediaType.isIn(
                  mediaTypes.map((TrackingMediaType type) => type.value),
                ),
          ))
          .write(
            const MediaTrackingMappingsCompanion(
              sentProgress: Value<int?>(null),
              sentCompleted: Value<bool>(false),
            ),
          );

  /// Takes [progress] / [completed] as already sent for link [mappingId]
  /// (a link made before v152 whose progress the old catch-up had covered).
  Future<void> adoptSentProgress(
    int mappingId, {
    required int progress,
    required bool completed,
  }) =>
      (_db.update(
        _db.mediaTrackingMappings,
      )..where((t) => t.id.equals(mappingId))).write(
        MediaTrackingMappingsCompanion(
          sentProgress: Value<int?>(progress),
          sentCompleted: Value<bool>(completed),
        ),
      );

  Future<void> markFailed(
    MediaTrackingOutboxRow sent,
    Object error, {
    int? nowMs,
  }) async {
    final int now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final int attempts = sent.attemptCount + 1;
    // 30s, 1m, 2m… 最长 6h；设置页“立即同步”会忽略此门槛主动重置。
    final int backoffSeconds = math.min(
      6 * 60 * 60,
      30 * math.pow(2, attempts - 1).toInt(),
    );
    final String message = error.toString();
    await (_db.update(_db.mediaTrackingOutbox)..where(
          (t) => t.id.equals(sent.id) & t.updatedAt.equals(sent.updatedAt),
        ))
        .write(
          MediaTrackingOutboxCompanion(
            attemptCount: Value<int>(attempts),
            nextAttemptAt: Value<int>(now + backoffSeconds * 1000),
            lastError: Value<String>(
              message.length <= 500 ? message : message.substring(0, 500),
            ),
          ),
        );
  }

  /// Rows the Activity log keeps (newest first; older ones are trimmed on
  /// write).
  static const int activityLimit = 500;

  /// Writes one Activity row for [update] (sent: [error] null; failed: the
  /// error) and trims the log to the newest [activityLimit] rows.
  Future<void> logActivity(
    PendingTrackingUpdate update, {
    Object? error,
    int? nowMs,
  }) async {
    final String? message = error?.toString();
    await _db.transaction(() async {
      await _db
          .into(_db.mediaTrackingActivity)
          .insert(
            MediaTrackingActivityCompanion.insert(
              provider: update.mapping.provider,
              mediaType: update.mapping.mediaType,
              mediaKey: update.mapping.mediaKey,
              mediaTitle: update.mapping.mediaTitle,
              kind: update.mapping.kind,
              progressMode: update.mapping.progressMode,
              progress: update.outbox.progress,
              completed: Value<bool>(update.outbox.completed),
              ok: message == null,
              error: Value<String?>(
                message == null || message.length <= 500
                    ? message
                    : message.substring(0, 500),
              ),
              createdAt: nowMs ?? DateTime.now().millisecondsSinceEpoch,
            ),
          );
      await _db.customStatement(
        'DELETE FROM media_tracking_activity WHERE id <= '
        '(SELECT id FROM media_tracking_activity ORDER BY id DESC '
        'LIMIT 1 OFFSET $activityLimit)',
      );
    });
  }

  /// The Activity log, newest first.
  Future<List<MediaTrackingActivityRow>> listActivity() =>
      (_db.select(_db.mediaTrackingActivity)
            ..orderBy(<OrderClauseGenerator<$MediaTrackingActivityTable>>[
              (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
            ])
            ..limit(activityLimit))
          .get();

  /// [provider] null = every provider (the settings page "Sync now").
  /// Only rows backing off after a failure: rows never tried are due anyway,
  /// except a hand link's held rows ([holdQueued]), which keep waiting for
  /// the user's Undo window.
  Future<void> retryAllNow({String? provider}) {
    final statement = _db.update(_db.mediaTrackingOutbox)
      ..where((t) => t.attemptCount.isBiggerThanValue(0));
    if (provider != null) {
      statement.where((_) => _outboxOfProvider(provider));
    }
    return statement.write(
      const MediaTrackingOutboxCompanion(nextAttemptAt: Value<int>(0)),
    );
  }

  /// 待同步行中最早的下次尝试时刻（毫秒）；outbox 为空时返回 null。
  ///
  /// 服务发送侧用它在每轮同步收尾时安排退避到期的自动重试（BUG-1647）。
  ///
  /// [sendable] null = every row. Otherwise provider id -> kinds it may send
  /// now; the coordinator passes only what can actually go out, because rows of
  /// a disconnected or disabled provider (or a kind switched off) must not keep
  /// re-arming the retry timer.
  Future<int?> earliestNextAttemptAt({
    Map<String, Iterable<TrackingKind>>? sendable,
  }) async {
    final Expression<int> earliest = _db.mediaTrackingOutbox.nextAttemptAt
        .min();
    final query = _db.selectOnly(_db.mediaTrackingOutbox)
      ..addColumns(<Expression<Object>>[earliest]);
    if (sendable != null) {
      Expression<bool> scope = const Constant<bool>(false);
      for (final MapEntry<String, Iterable<TrackingKind>> entry
          in sendable.entries) {
        scope =
            scope |
            (_db.mediaTrackingMappings.provider.equals(entry.key) &
                _db.mediaTrackingMappings.kind.isIn(
                  entry.value.map((TrackingKind kind) => kind.value),
                ));
      }
      query.where(
        _db.mediaTrackingOutbox.mappingId.isInQuery(
          _db.selectOnly(_db.mediaTrackingMappings)
            ..addColumns(<Expression<Object>>[_db.mediaTrackingMappings.id])
            ..where(scope),
        ),
      );
    }
    final TypedResult? row = await query.getSingleOrNull();
    return row?.read(earliest);
  }
}
