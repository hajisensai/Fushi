import 'dart:async';
import 'dart:convert';

import 'package:fushi_engine/media/video/metadata/video_metadata_transport.dart';

/// Cross-service identifiers only. This catalog supplies no anime metadata and
/// deliberately does not infer episode/season equivalence across services.
class AnimeIdentityMappingResult {
  AnimeIdentityMappingResult({required this.anidbId, required Set<int> malIds})
      : malIds = Set<int>.unmodifiable(malIds);

  final int anidbId;
  final Set<int> malIds;
  int? get confirmedMalId => malIds.length == 1 ? malIds.single : null;
  bool get isAmbiguous => malIds.length > 1;
}

/// Fribb anime-lists 一行的跨站身份：以 AniDB 条目为粒度，附带 TVDB/TMDB 的
/// 季号与集偏移（`season` / `episode_offset` 对象里按站点取值）。
class AnimeIdentityEntry {
  AnimeIdentityEntry({
    required this.anidbId,
    required Set<int> malIds,
    this.anilistId,
    this.tvdbId,
    this.tmdbId,
    this.tmdbSeason,
    this.tmdbEpisodeOffset,
    this.tvdbSeason,
    this.tvdbEpisodeOffset,
    this.type,
    this.tmdbIsMovieNamespace = false,
  }) : malIds = Set<int>.unmodifiable(malIds);

  final int anidbId;
  final Set<int> malIds;
  final int? anilistId;
  final int? tvdbId;
  final int? tmdbId;
  final int? tmdbSeason;
  final int? tmdbEpisodeOffset;
  final int? tvdbSeason;
  final int? tvdbEpisodeOffset;
  final String? type;

  /// [tmdbId] 取自 `themoviedb_id.movie`（TMDB 电影命名空间）而非 `.tv`。
  final bool tmdbIsMovieNamespace;

  /// 是否按 TMDB 电影处理：`themoviedb_id` 自己给出的命名空间优先（它是这条
  /// 映射的直接事实），其次才看 Fribb 的 `type` 字段。
  bool get isMovie => tmdbIsMovieNamespace || type?.toUpperCase() == 'MOVIE';

  AnimeIdentityMappingResult toMappingResult() =>
      AnimeIdentityMappingResult(anidbId: anidbId, malIds: malIds);
}

class AnimeIdentityMapping {
  AnimeIdentityMapping({
    VideoMetadataHttpClient? httpClient,
    this.cacheTtl = const Duration(hours: 24),
    this.maxResponseBytes = 16 * 1024 * 1024,
    DateTime Function()? now,
  })  : _http = httpClient ?? VideoMetadataHttpClient(),
        _ownsHttp = httpClient == null,
        _now = now ?? DateTime.now;

  static final Uri sourceUri = Uri.parse(
    'https://raw.githubusercontent.com/Fribb/anime-lists/master/anime-list-full.json',
  );
  final VideoMetadataHttpClient _http;
  final bool _ownsHttp;
  final DateTime Function() _now;
  final Duration cacheTtl;
  final int maxResponseBytes;
  _AnimeIdentityCatalog? _catalog;
  DateTime? _expiresAt;
  Future<_AnimeIdentityCatalog>? _loading;

  Future<AnimeIdentityMappingResult> lookupAnidb(int animeId) async {
    if (animeId <= 0) throw ArgumentError.value(animeId, 'animeId');
    final _AnimeIdentityCatalog catalog = await _load();
    return AnimeIdentityMappingResult(
      anidbId: animeId,
      malIds: catalog.byAnidb[animeId]?.malIds ?? const <int>{},
    );
  }

  Future<AnimeIdentityEntry?> entryForAnidb(int anidbId) async {
    if (anidbId <= 0) throw ArgumentError.value(anidbId, 'anidbId');
    return (await _load()).byAnidb[anidbId];
  }

  /// 反向索引：同一 MAL 条目可能对应多个 AniDB 条目（如 TV 与其特典拆条）。
  Future<List<AnimeIdentityEntry>> entriesForMal(int malId) async {
    if (malId <= 0) throw ArgumentError.value(malId, 'malId');
    return (await _load()).byMal[malId] ?? const <AnimeIdentityEntry>[];
  }

  /// 同一 TMDB 剧集下的全部季条目（不含电影），按 `tmdbEpisodeOffset` 升序。
  Future<List<AnimeIdentityEntry>> entriesForTmdbTv(int tmdbId) async {
    if (tmdbId <= 0) throw ArgumentError.value(tmdbId, 'tmdbId');
    return (await _load()).byTmdbTv[tmdbId] ?? const <AnimeIdentityEntry>[];
  }

  Future<_AnimeIdentityCatalog> _load() async {
    if (_catalog != null && _expiresAt!.isAfter(_now())) return _catalog!;
    if (_loading != null) return _loading!;
    final Future<_AnimeIdentityCatalog> pending = _download();
    _loading = pending;
    try {
      final _AnimeIdentityCatalog catalog = await pending;
      _catalog = catalog;
      _expiresAt = _now().add(cacheTtl);
      return catalog;
    } finally {
      _loading = null;
    }
  }

  Future<_AnimeIdentityCatalog> _download() async {
    final VideoMetadataHttpResponse response = await _http.get(
      sourceUri,
      operation: 'Anime identity mapping',
    );
    // Bound decoding and retained catalog size. The shared HTTP transport owns
    // response buffering; do not cache another copy of its raw body here.
    if (response.body.length > maxResponseBytes ||
        utf8.encode(response.body).length > maxResponseBytes) {
      throw const FormatException('Anime identity mapping exceeds size limit');
    }
    final Object? decoded =
        response.decodeJson(operation: 'Anime identity mapping');
    if (decoded is! List) {
      throw const FormatException('Anime identity mapping must be a list');
    }
    return _AnimeIdentityCatalog.fromRows(decoded);
  }

  void close() {
    if (_ownsHttp) _http.close();
  }
}

class _AnimeIdentityCatalog {
  const _AnimeIdentityCatalog({
    required this.byAnidb,
    required this.byMal,
    required this.byTmdbTv,
  });

  final Map<int, AnimeIdentityEntry> byAnidb;
  final Map<int, List<AnimeIdentityEntry>> byMal;
  final Map<int, List<AnimeIdentityEntry>> byTmdbTv;

  /// 同一 anidb_id 出现多行时合并：`mal_id` 取并集，其余字段首个合法值生效；
  /// 非法值（非正数、小数、乱字符串）静默跳过。
  static _AnimeIdentityCatalog fromRows(List<Object?> rows) {
    final Map<int, _EntryBuilder> builders = <int, _EntryBuilder>{};
    for (final Object? row in rows) {
      if (row is! Map) continue;
      final int? aid = _positiveId(row['anidb_id']);
      if (aid == null) continue;
      final _EntryBuilder builder = builders[aid] ??= _EntryBuilder(aid);
      final int? mal = _positiveId(row['mal_id']);
      if (mal != null) builder.malIds.add(mal);
      builder.anilistId ??= _positiveId(row['anilist_id']);
      builder.tvdbId ??= _positiveId(row['tvdb_id']);
      // 实测 Fribb `anime-list-full.json`（39304 行）：`themoviedb_id` **恒为
      // 对象**，`{"tv": 209867}`（7092 行）或 `{"movie": [128]}`（1363 行，
      // movie 侧的值还是数组），从不出现裸数字；`tvdb_id` 才是 TVDB 键
      // （`thetvdb_id` 零命中）。按裸数字 / 错键名解析会让 tmdbId 与 tvdbId
      // 恒为 null，多季对齐与 TMDB id 接力全部静默失效。
      final Object? tmdb = row['themoviedb_id'];
      builder.tmdbId ??= _firstPositiveId(_field(tmdb, 'tv'));
      final int? tmdbMovie = _firstPositiveId(_field(tmdb, 'movie'));
      if (builder.tmdbId == null && tmdbMovie != null) {
        builder.tmdbId = tmdbMovie;
        builder.tmdbIsMovieNamespace = true;
      }
      final Object? season = row['season'];
      final Object? offset = row['episode_offset'];
      builder.tmdbSeason ??= _nonNegativeInt(_field(season, 'tmdb'));
      builder.tvdbSeason ??= _nonNegativeInt(_field(season, 'tvdb'));
      builder.tmdbEpisodeOffset ??= _nonNegativeInt(_field(offset, 'tmdb'));
      builder.tvdbEpisodeOffset ??= _nonNegativeInt(_field(offset, 'tvdb'));
      final Object? type = row['type'];
      if (type is String && type.trim().isNotEmpty) {
        builder.type ??= type.trim();
      }
    }
    final Map<int, AnimeIdentityEntry> byAnidb = <int, AnimeIdentityEntry>{};
    final Map<int, List<AnimeIdentityEntry>> byMal =
        <int, List<AnimeIdentityEntry>>{};
    final Map<int, List<AnimeIdentityEntry>> byTmdbTv =
        <int, List<AnimeIdentityEntry>>{};
    for (final _EntryBuilder builder in builders.values) {
      final AnimeIdentityEntry entry = builder.build();
      byAnidb[entry.anidbId] = entry;
      for (final int mal in entry.malIds) {
        (byMal[mal] ??= <AnimeIdentityEntry>[]).add(entry);
      }
      final int? tmdb = entry.tmdbId;
      if (tmdb != null && !entry.isMovie) {
        (byTmdbTv[tmdb] ??= <AnimeIdentityEntry>[]).add(entry);
      }
    }
    for (final List<AnimeIdentityEntry> entries in byMal.values) {
      entries.sort(_byAnidbId);
    }
    for (final List<AnimeIdentityEntry> entries in byTmdbTv.values) {
      entries.sort(_byTmdbOrder);
    }
    return _AnimeIdentityCatalog(
      byAnidb: byAnidb,
      byMal: byMal,
      byTmdbTv: byTmdbTv,
    );
  }

  static int _byAnidbId(AnimeIdentityEntry a, AnimeIdentityEntry b) =>
      a.anidbId.compareTo(b.anidbId);

  static int _byTmdbOrder(AnimeIdentityEntry a, AnimeIdentityEntry b) {
    final int offset =
        (a.tmdbEpisodeOffset ?? 0).compareTo(b.tmdbEpisodeOffset ?? 0);
    if (offset != 0) return offset;
    final int season = (a.tmdbSeason ?? 0).compareTo(b.tmdbSeason ?? 0);
    if (season != 0) return season;
    return a.anidbId.compareTo(b.anidbId);
  }

  static Object? _field(Object? container, String key) =>
      container is Map ? container[key] : null;
}

class _EntryBuilder {
  _EntryBuilder(this.anidbId);

  final int anidbId;
  final Set<int> malIds = <int>{};
  int? anilistId;
  int? tvdbId;
  int? tmdbId;
  int? tmdbSeason;
  int? tmdbEpisodeOffset;
  int? tvdbSeason;
  int? tvdbEpisodeOffset;
  String? type;

  /// [tmdbId] 取自 `themoviedb_id.movie` 而非 `.tv`：该 id 属于 TMDB 的电影
  /// 命名空间，即便 `type` 字段缺失也不能按剧集去 `/tv/{id}` 拉。
  bool tmdbIsMovieNamespace = false;

  AnimeIdentityEntry build() => AnimeIdentityEntry(
        anidbId: anidbId,
        malIds: malIds,
        anilistId: anilistId,
        tvdbId: tvdbId,
        tmdbId: tmdbId,
        tmdbSeason: tmdbSeason,
        tmdbEpisodeOffset: tmdbEpisodeOffset,
        tvdbSeason: tvdbSeason,
        tvdbEpisodeOffset: tvdbEpisodeOffset,
        type: type,
        tmdbIsMovieNamespace: tmdbIsMovieNamespace,
      );
}

int? _positiveId(Object? value) {
  final int? id = _intOf(value);
  return id != null && id > 0 ? id : null;
}

/// Fribb 的 id 值可能是标量，也可能是数组（`themoviedb_id.movie` 实测就是
/// `[128]`）。数组取第一个合法正整数；多值时后面的丢弃——一个 anidb 条目
/// 指向多个 TMDB 电影不构成可自动采用的唯一映射。
int? _firstPositiveId(Object? value) {
  if (value is List) {
    for (final Object? item in value) {
      final int? id = _positiveId(item);
      if (id != null) return id;
    }
    return null;
  }
  return _positiveId(value);
}

int? _nonNegativeInt(Object? value) {
  final int? number = _intOf(value);
  return number != null && number >= 0 ? number : null;
}

int? _intOf(Object? value) {
  if (value is int) return value;
  if (value is String) return int.tryParse(value.trim());
  return null;
}
