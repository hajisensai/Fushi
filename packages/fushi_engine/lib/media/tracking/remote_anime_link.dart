/// Linking an episode played from a media server (Jellyfin / Emby) to a
/// tracking provider, from the IDs the server already has. Never from a title.
library;

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/video/metadata/anime_identity_mapping.dart';

/// What a media server says about one finished episode (or movie).
final class RemoteAnimeEpisode {
  const RemoteAnimeEpisode({
    required this.mediaKey,
    required this.title,
    required this.episodeNumber,
    this.seasonNumber,
    this.isMovie = false,
    this.seasonIds = const <String, String>{},
    this.seriesIds = const <String, String>{},
    this.seasonEpisodeCount,
    this.seriesId,
    this.seriesTitle = '',
    this.serverName = '',
  });

  /// Stable key for this server item (server + user + item id).
  final String mediaKey;

  /// Shown in the tracking settings, e.g. "Frieren S1E3".
  final String title;

  /// Episode number inside its season (1 for a movie).
  final int episodeNumber;

  /// Season number; null when the server has none. 0 = specials.
  final int? seasonNumber;
  final bool isMovie;

  /// Server `ProviderIds` of the season, keys lowercased.
  final Map<String, String> seasonIds;

  /// Server `ProviderIds` of the series (or the movie itself), keys lowercased.
  final Map<String, String> seriesIds;

  /// Episodes in this season on the server, when known.
  final int? seasonEpisodeCount;

  /// The server's id of the series (episodes only), when known: episodes
  /// of one season share a link ([remoteAnimeGroupKey]).
  final String? seriesId;

  /// The series name as the server has it ('' = unknown).
  final String seriesTitle;

  /// The server's own name ('' = unknown). Never its address: see
  /// [remoteServerShownName].
  final String serverName;
}

final RegExp _ipv4Address = RegExp(r'^\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?$');
final RegExp _ipv6Address = RegExp(
  r'^\[?[0-9a-fA-F]*:[0-9a-fA-F:.]*\]?(?::\d+)?$',
);
final RegExp _dottedHostName = RegExp(
  r'^[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)+\.?(?::\d+)?$',
);

/// [name] as a media server's name for the user, or '' when it is empty or
/// is a network address (URL, IP address, `host.domain`, `localhost`).
///
/// Tracking shows where a remembered episode was played by the server's name
/// only: an address is private (a LAN IP in a screenshot) and says nothing a
/// name does not, so nothing is shown in its place. Older rows stored the
/// host when the server had no name; this hides them too.
String remoteServerShownName(String name) {
  final String value = name.trim();
  if (value.isEmpty ||
      value.contains('://') ||
      value.contains('/') ||
      value.toLowerCase() == 'localhost' ||
      _ipv4Address.hasMatch(value) ||
      _ipv6Address.hasMatch(value) ||
      _dottedHostName.hasMatch(value)) {
    return '';
  }
  return value;
}

/// The key one hand-made link covers: the season of the series on this
/// server login (`<login>|series:<id>|season:<n>`, the series title when the
/// server gave no id), or the item itself for a movie or an episode with
/// neither. The login is [RemoteAnimeEpisode.mediaKey] without its last
/// `|item` part.
String remoteAnimeGroupKey(RemoteAnimeEpisode episode) {
  final String key = episode.mediaKey.trim();
  if (episode.isMovie) return key;
  final int bar = key.lastIndexOf('|');
  final String login = bar > 0 ? key.substring(0, bar) : key;
  final String season = 'season:${episode.seasonNumber ?? 1}';
  final String seriesId = episode.seriesId?.trim() ?? '';
  if (seriesId.isNotEmpty) return '$login|series:$seriesId|$season';
  final String title = episode.seriesTitle.trim().toLowerCase();
  if (title.isNotEmpty) return '$login|title:$title|$season';
  return key;
}

/// The server's item id inside an episode key ([RemoteAnimeEpisode.mediaKey]
/// is `<login>|<item id>`, see the clients' `trackingKeyFor`). A library row
/// added from that server has this id as its `bookUid`.
String remoteAnimeItemId(String mediaKey) {
  final String key = mediaKey.trim();
  final int bar = key.lastIndexOf('|');
  return bar >= 0 ? key.substring(bar + 1) : key;
}

/// Offline cross-site anime IDs (Fribb anime-lists), as plain functions so the
/// tracking code does not own the catalog.
final class AnimeCrossIds {
  const AnimeCrossIds({
    required this.entryForAnidb,
    required this.entriesForTmdbTv,
    required this.entriesForTvdb,
    required this.entriesForTmdbMovie,
  });

  final Future<AnimeIdentityEntry?> Function(int anidbId) entryForAnidb;
  final Future<List<AnimeIdentityEntry>> Function(int tmdbId) entriesForTmdbTv;
  final Future<List<AnimeIdentityEntry>> Function(int tvdbId) entriesForTvdb;
  final Future<List<AnimeIdentityEntry>> Function(int tmdbMovieId)
  entriesForTmdbMovie;
}

/// Id types a [RemoteAnimeCandidate] can carry.
abstract final class RemoteAnimeIdType {
  static const String anilist = 'anilist';
  static const String mal = 'mal';
}

/// One way to name the episode on a tracker.
///
/// [sameSeason]: the id stands for exactly this server season, so the server
/// season's episode count must equal the tracker's when both are known.
typedef RemoteAnimeCandidate = ({
  String idType,
  int id,
  int episode,
  bool sameSeason,
});

int? _positiveId(String? raw) {
  final int? value = int.tryParse(raw?.trim() ?? '');
  return value != null && value > 0 ? value : null;
}

/// Ways to name [episode] on a tracker, best first:
///
/// 1. the season's own AniList / MAL / AniDB id (AniDB through [crossIds]);
/// 2. the same ids on the series, only for season 1 or a movie (a series id
///    names its first season);
/// 3. the series' TMDB / TVDB id + season + episode, through the offline
///    season offsets in [crossIds] (default Jellyfin libraries only have these);
///    a movie's TMDB movie id when the offline list has exactly one entry.
///
/// Specials (season 0) and unnumbered episodes give nothing.
Future<List<RemoteAnimeCandidate>> remoteAnimeCandidates(
  RemoteAnimeEpisode episode, {
  AnimeCrossIds? crossIds,
}) async {
  final int number = episode.isMovie ? 1 : episode.episodeNumber;
  final int? season = episode.seasonNumber;
  if (number <= 0 || (!episode.isMovie && season == 0)) {
    return const <RemoteAnimeCandidate>[];
  }
  final List<RemoteAnimeCandidate> out = <RemoteAnimeCandidate>[];

  Future<void> addDirect(Map<String, String> ids) async {
    final int? anilist = _positiveId(ids['anilist']);
    if (anilist != null) {
      out.add((
        idType: RemoteAnimeIdType.anilist,
        id: anilist,
        episode: number,
        sameSeason: true,
      ));
    }
    final int? mal = _positiveId(ids['mal'] ?? ids['myanimelist']);
    if (mal != null) {
      out.add((
        idType: RemoteAnimeIdType.mal,
        id: mal,
        episode: number,
        sameSeason: true,
      ));
    }
    final int? anidb = _positiveId(ids['anidb']);
    if (anidb != null && crossIds != null) {
      final AnimeIdentityEntry? entry = await _guard<AnimeIdentityEntry?>(
        () => crossIds.entryForAnidb(anidb),
      );
      if (entry != null) _addEntry(out, entry, number, sameSeason: true);
    }
  }

  await addDirect(episode.seasonIds);
  if (episode.isMovie || season == null || season == 1) {
    await addDirect(episode.seriesIds);
  }

  if (episode.isMovie && crossIds != null) {
    final int? tmdb = _positiveId(episode.seriesIds['tmdb']);
    if (tmdb != null) {
      final List<AnimeIdentityEntry>? entries =
          await _guard<List<AnimeIdentityEntry>>(
            () => crossIds.entriesForTmdbMovie(tmdb),
          );
      if (entries != null && entries.length == 1) {
        _addEntry(out, entries.single, 1, sameSeason: true);
      }
    }
  }

  if (!episode.isMovie && season != null && crossIds != null) {
    final int? tmdb = _positiveId(episode.seriesIds['tmdb']);
    if (tmdb != null) {
      final List<AnimeIdentityEntry>? entries = await _guard(
        () => crossIds.entriesForTmdbTv(tmdb),
      );
      _addSeasonOffset(
        out,
        entries ?? const <AnimeIdentityEntry>[],
        season: season,
        episode: number,
        seasonOf: (AnimeIdentityEntry e) => e.tmdbSeason,
        offsetOf: (AnimeIdentityEntry e) => e.tmdbEpisodeOffset,
      );
    }
    final int? tvdb = _positiveId(episode.seriesIds['tvdb']);
    if (tvdb != null) {
      final List<AnimeIdentityEntry>? entries = await _guard(
        () => crossIds.entriesForTvdb(tvdb),
      );
      _addSeasonOffset(
        out,
        entries ?? const <AnimeIdentityEntry>[],
        season: season,
        episode: number,
        seasonOf: (AnimeIdentityEntry e) => e.tvdbSeason,
        offsetOf: (AnimeIdentityEntry e) => e.tvdbEpisodeOffset,
      );
    }
  }
  return out;
}

/// The offline catalog downloads on first use; a failure only drops that path.
Future<T?> _guard<T>(Future<T> Function() lookup) async {
  try {
    return await lookup();
  } catch (error, stackTrace) {
    engineLog.log('remoteAnimeCandidates.crossIds', error, stackTrace);
    return null;
  }
}

void _addEntry(
  List<RemoteAnimeCandidate> out,
  AnimeIdentityEntry entry,
  int episode, {
  required bool sameSeason,
}) {
  final int? anilist = entry.anilistId;
  if (anilist != null && anilist > 0) {
    out.add((
      idType: RemoteAnimeIdType.anilist,
      id: anilist,
      episode: episode,
      sameSeason: sameSeason,
    ));
    return;
  }
  // Several MAL ids for one AniDB entry = no single answer.
  if (entry.malIds.length == 1) {
    out.add((
      idType: RemoteAnimeIdType.mal,
      id: entry.malIds.single,
      episode: episode,
      sameSeason: sameSeason,
    ));
  }
}

/// Server season [season] episode [episode] -> the catalog entry whose season
/// starts last before it. Two entries starting at the same place = ambiguous,
/// nothing is added.
void _addSeasonOffset(
  List<RemoteAnimeCandidate> out,
  List<AnimeIdentityEntry> entries, {
  required int season,
  required int episode,
  required int? Function(AnimeIdentityEntry entry) seasonOf,
  required int? Function(AnimeIdentityEntry entry) offsetOf,
}) {
  AnimeIdentityEntry? best;
  int bestOffset = -1;
  bool tied = false;
  for (final AnimeIdentityEntry entry in entries) {
    if (entry.isMovie || seasonOf(entry) != season) continue;
    final int offset = offsetOf(entry) ?? 0;
    if (offset < 0 || offset >= episode) continue;
    if (offset > bestOffset) {
      best = entry;
      bestOffset = offset;
      tied = false;
    } else if (offset == bestOffset) {
      tied = true;
    }
  }
  if (best == null || tied) return;
  _addEntry(out, best, episode - bestOffset, sameSeason: false);
}
