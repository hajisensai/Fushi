/// What the Tracking page knows about a local item beyond its raw name,
/// loaded once per page snapshot (a few whole-table reads, no per-row I/O):
/// the names of the work it belongs to (scraped title, series card, media
/// server series) and whether its scraped metadata says anime or live
/// action. Rows then show the cleaned work title first and the raw name
/// second, and say "Live action" / "Video" instead of calling every video
/// anime (T1 F15).
library;

import 'dart:convert';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/local_title_clean.dart';

/// What a video's scraped metadata says it is.
enum TrackingVideoNature {
  /// Scraped from an anime database (AniDB, MyAnimeList, AniList, Bangumi),
  /// or a general database (TMDB, Douban) tagged as animation / anime.
  anime,

  /// Scraped from a general database (TMDB, Douban) whose genres and
  /// keywords say nothing about animation.
  liveAction,

  /// Not scraped, or nothing to tell from.
  unknown,
}

/// Scrape sources that only list anime (`ScrapeSource.name` /
/// `VideoMetadataProviderKind.name`).
const Set<String> _animeSources = <String>{
  'anidb',
  'mal',
  'anilist',
  'bangumi',
};

/// Scrape sources that list films and series of every kind.
const Set<String> _generalSources = <String>{'tmdb', 'douban'};

/// TMDB's "Animation" genre (id 16) in the languages its genre names come
/// in, and the "anime" keyword (genre names follow the scrape language).
const Set<String> _animationTags = <String>{
  'animation',
  'anime',
  'animación',
  'animação',
  'animazione',
  'animatie',
  'animacja',
  'animace',
  'анимация',
  'мультфильм',
  'アニメーション',
  'アニメ',
  '动画',
  '動畫',
  '动漫',
  '애니메이션',
  'แอนิเมชัน',
  'hoạt hình',
  'animasi',
};

/// The nature of a video scraped from [source] with tags [tagsJson] (the
/// `tags_json` column: `[{"name": ...}]`, genres and keywords).
TrackingVideoNature trackingVideoNatureOf({
  required String source,
  String? tagsJson,
}) {
  final String from = source.trim().toLowerCase();
  if (_animeSources.contains(from)) return TrackingVideoNature.anime;
  final List<String> tags = _tagNames(tagsJson);
  for (final String tag in tags) {
    if (_animationTags.contains(tag.trim().toLowerCase())) {
      return TrackingVideoNature.anime;
    }
  }
  if (_generalSources.contains(from) && tags.isNotEmpty) {
    return TrackingVideoNature.liveAction;
  }
  return TrackingVideoNature.unknown;
}

List<String> _tagNames(String? tagsJson) {
  if (tagsJson == null || tagsJson.trim().isEmpty) return const <String>[];
  try {
    final Object? decoded = jsonDecode(tagsJson);
    if (decoded is! List<Object?>) return const <String>[];
    return <String>[
      for (final Object? tag in decoded)
        if (tag is Map<String, Object?> && tag['name'] is String)
          tag['name']! as String,
    ];
  } on FormatException {
    return const <String>[];
  }
}

/// How a row names its kind (the kind filter offers the same).
enum TrackingRowKind { anime, liveAction, video, manga, novel, game }

/// The row kind of an item of [kind]. A video ([TrackingKind.anime]) is
/// "Live action" when its metadata says so, "Anime" when its metadata says
/// anime or it is [linked] (as anime), else the neutral "Video". Null for an
/// unknown kind (sign-in rows).
TrackingRowKind? trackingRowKindOf(
  TrackingKind? kind, {
  TrackingVideoNature nature = TrackingVideoNature.unknown,
  bool linked = false,
}) => switch (kind) {
  null => null,
  TrackingKind.manga => TrackingRowKind.manga,
  TrackingKind.novel => TrackingRowKind.novel,
  TrackingKind.game => TrackingRowKind.game,
  TrackingKind.anime => switch (nature) {
    TrackingVideoNature.liveAction => TrackingRowKind.liveAction,
    TrackingVideoNature.anime => TrackingRowKind.anime,
    TrackingVideoNature.unknown =>
      linked ? TrackingRowKind.anime : TrackingRowKind.video,
  },
};

/// What the page knows about one local item.
final class TrackingItemFacts {
  const TrackingItemFacts({
    this.workTitles = const <String>[],
    this.nature = TrackingVideoNature.unknown,
    this.scraped = false,
  });

  static const TrackingItemFacts none = TrackingItemFacts();

  /// Names of the work, best first ([trackingWorkTitlesFor]).
  final List<String> workTitles;
  final TrackingVideoNature nature;

  /// The item (or a collection holding it) has scraped metadata.
  final bool scraped;
}

/// [TrackingItemFacts] of every local item, by `type|key`.
final class TrackingRowFacts {
  const TrackingRowFacts(this._byItem);

  static const TrackingRowFacts empty = TrackingRowFacts(
    <String, TrackingItemFacts>{},
  );

  final Map<String, TrackingItemFacts> _byItem;

  TrackingItemFacts of(String mediaType, String mediaKey) =>
      _byItem['$mediaType|$mediaKey'] ?? TrackingItemFacts.none;
}

/// The title a row leads with for an item named [raw]: the best clean term
/// of the shared title clean-up, from the work's name when there is one
/// (the same text a link dialog searches first).
String trackingRowTitle(String raw, TrackingItemFacts facts) {
  for (final String work in facts.workTitles) {
    final String title = localTitleSearchCandidates(work).first.trim();
    if (title.isNotEmpty) return title;
  }
  final String title = localTitleSearchCandidates(raw).first.trim();
  return title.isEmpty ? raw.trim() : title;
}

/// [raw] when it says more than [title] (the row's second line), else null.
String? trackingRowRawName(String raw, String title) {
  final String value = raw.trim();
  if (value.isEmpty || value.toLowerCase() == title.trim().toLowerCase()) {
    return null;
  }
  return value;
}

/// Loads [TrackingRowFacts] for every video, video collection and media
/// server episode / season (books and games are named by their own titles).
Future<TrackingRowFacts> loadTrackingRowFacts(FushiDatabase database) async {
  final Map<String, VideoScrapeMetaRow> videoScrapes =
      <String, VideoScrapeMetaRow>{
        for (final VideoScrapeMetaRow row
            in await database.getAllVideoScrapeMeta())
          row.bookUid: row,
      };
  final Map<int, CollectionScrapeMetaRow> collectionScrapes =
      <int, CollectionScrapeMetaRow>{
        for (final CollectionScrapeMetaRow row
            in await database.getAllCollectionScrapeMeta())
          row.collectionId: row,
      };
  final Map<int, MediaCollectionRow> collections = <int, MediaCollectionRow>{
    for (final MediaCollectionRow row
        in await database.getAllMediaCollections())
      row.id: row,
  };
  final Map<String, List<int>> collectionsOfVideo = <String, List<int>>{};
  for (final MediaCollectionItemRow member
      in await database.getAllCollectionItems()) {
    if (member.mediaType != MediaKind.video.dbValue) continue;
    collectionsOfVideo
        .putIfAbsent(member.entryKey, () => <int>[])
        .add(member.collectionId);
  }
  final Map<String, TrackingItemFacts> out = <String, TrackingItemFacts>{};

  ({List<String> titles, TrackingVideoNature nature, bool scraped})
  collectionFacts(int id) {
    final CollectionScrapeMetaRow? scrape = collectionScrapes[id];
    return (
      titles: <String>[?scrape?.title, ?collections[id]?.name],
      nature: scrape == null
          ? TrackingVideoNature.unknown
          : trackingVideoNatureOf(
              source: scrape.source,
              tagsJson: scrape.tagsJson,
            ),
      scraped: scrape != null,
    );
  }

  List<String> distinct(Iterable<String> titles) {
    final List<String> result = <String>[];
    for (final String title in titles) {
      final String value = title.trim();
      if (value.isNotEmpty && !result.contains(value)) result.add(value);
    }
    return result;
  }

  for (final int id in collections.keys) {
    final ({List<String> titles, TrackingVideoNature nature, bool scraped})
    facts = collectionFacts(id);
    out['${TrackingMediaType.videoCollection.value}|$id'] = TrackingItemFacts(
      workTitles: distinct(facts.titles),
      nature: facts.nature,
      scraped: facts.scraped,
    );
  }
  final Set<String> videoKeys = <String>{
    ...videoScrapes.keys,
    ...collectionsOfVideo.keys,
  };
  for (final String uid in videoKeys) {
    final VideoScrapeMetaRow? scrape = videoScrapes[uid];
    final List<String> titles = <String>[
      // An episode-level row names the episode, not the work.
      if (scrape != null && scrape.episodeNumber == null) scrape.title,
    ];
    TrackingVideoNature nature = scrape == null
        ? TrackingVideoNature.unknown
        : trackingVideoNatureOf(
            source: scrape.source,
            tagsJson: scrape.tagsJson,
          );
    bool scraped = scrape != null;
    for (final int id in collectionsOfVideo[uid] ?? const <int>[]) {
      final ({List<String> titles, TrackingVideoNature nature, bool scraped})
      facts = collectionFacts(id);
      titles.addAll(facts.titles);
      if (nature == TrackingVideoNature.unknown) nature = facts.nature;
      scraped = scraped || facts.scraped;
    }
    out['${TrackingMediaType.video.value}|$uid'] = TrackingItemFacts(
      workTitles: distinct(titles),
      nature: nature,
      scraped: scraped,
    );
  }
  final Map<String, List<String>> remoteTitles = <String, List<String>>{};
  for (final MediaTrackingRemoteEpisodeRow row in await MediaTrackingRepository(
    database,
  ).listRemoteEpisodes()) {
    for (final String key in <String>[
      '${TrackingMediaType.remoteSeries.value}|${row.groupKey}',
      '${TrackingMediaType.remoteVideo.value}|${row.groupKey}',
      '${TrackingMediaType.remoteVideo.value}|${row.mediaKey}',
    ]) {
      remoteTitles.putIfAbsent(key, () => <String>[]).add(row.seriesTitle);
    }
  }
  for (final MapEntry<String, List<String>> entry in remoteTitles.entries) {
    out[entry.key] = TrackingItemFacts(workTitles: distinct(entry.value));
  }
  return TrackingRowFacts(out);
}
