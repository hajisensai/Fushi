import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
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

  /// 作品**形态**是否为电影：`themoviedb_id` 落在 movie 空间，或 Fribb `type`
  /// 是 MOVIE。只用于形态推断与类型闸门，**不能**拿来决定 [tmdbId] 属于
  /// /movie 还是 /tv——那是 [tmdbMediaKind] 的事。
  bool get isMovie => tmdbIsMovieNamespace || type?.toUpperCase() == 'MOVIE';

  /// [tmdbId] 所在的 TMDB 命名空间；没有 TMDB id 时为 null。
  ///
  /// 与 [isMovie] 不是一回事：TMDB 常把剧场版收成所属电视剧的第 0 季（特典），
  /// Fribb 于是给出 `type: MOVIE` + `themoviedb_id: {tv: N}`（实测 715 行，如
  /// リズと青い鳥 = anidb 13491 → tv 62564 吹响！上低音号）。把这种 tv id 按
  /// /movie/N 拉会命中同号的无关电影（BUG-2828），所以拼 TMDB lookup 只认这里。
  VideoMetadataMediaKind? get tmdbMediaKind => tmdbId == null
      ? null
      : tmdbIsMovieNamespace
      ? VideoMetadataMediaKind.movie
      : VideoMetadataMediaKind.tv;

  /// 按请求的形态给 TMDB id：命名空间对不上（剧场版挂在剧的特典季下）时为
  /// null，调用方据此回退标题补充，而不是把 tv id 当 movie id 用。
  int? tmdbIdFor(VideoMetadataMediaKind kind) =>
      tmdbMediaKind == kind ? tmdbId : null;

  AnimeIdentityMappingResult toMappingResult() =>
      AnimeIdentityMappingResult(anidbId: anidbId, malIds: malIds);
}

class AnimeIdentityMapping {
  AnimeIdentityMapping({
    VideoMetadataHttpClient? httpClient,
    this.cacheTtl = const Duration(hours: 24),
    this.maxResponseBytes = 16 * 1024 * 1024,
    DateTime Function()? now,
  }) : _http = httpClient ?? VideoMetadataHttpClient(),
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
    if (response.body.length > maxResponseBytes) {
      throw const FormatException('Anime identity mapping exceeds size limit');
    }
    // Fribb 全表是十几 MB JSON、近四万行：字节数复核、原生解析（fushi_compute，
    // 后台 isolate 自己加载库）与建三张索引整段进后台 isolate（结果经 Isolate.exit
    // 零拷贝交回）。之前这段在 UI isolate 同步跑，是「按作品归类」导入时整机卡住的
    // 一节。闭包只捕获局部变量，不能碰 `this`（HTTP client 跨不了 isolate）。
    final String body = response.body;
    final int statusCode = response.statusCode;
    final int limit = maxResponseBytes;
    return Isolate.run(
      () => _decodeIdentityCatalog(body, statusCode: statusCode, limit: limit),
      debugName: 'anime-identity-mapping',
    );
  }

  void close() {
    if (_ownsHttp) _http.close();
  }
}

/// 后台 isolate 入口：与 `VideoMetadataHttpResponse.decodeJson` 同一套错误语义
/// （坏 JSON → [VideoMetadataNetworkException]），只是不在 UI isolate 上跑。
_AnimeIdentityCatalog _decodeIdentityCatalog(
  String body, {
  required int statusCode,
  required int limit,
}) {
  final Uint8List bytes = utf8.encode(body);
  if (bytes.length > limit) {
    throw const FormatException('Anime identity mapping exceeds size limit');
  }
  final List<AnimeIdentityEntry> entries;
  try {
    entries = animeIdentityEntriesFromJsonUtf8(bytes);
  } on FfcFribbInvalidJson catch (error) {
    throw VideoMetadataNetworkException(
      'Anime identity mapping returned invalid JSON: $error',
      statusCode: statusCode,
    );
  } on FfcFribbNotAList {
    throw const FormatException('Anime identity mapping must be a list');
  }
  return _AnimeIdentityCatalog.fromEntries(entries);
}

/// Fribb `anime-list-full.json`（UTF-8 字节）→ 按 AniDB 条目归并后的身份条目，按
/// anidb_id 首次出现的顺序。与 [AnimeIdentityMapping] 同一套解析规则（发现页的紧凑
/// 交叉索引复用它，不另写一份字段解析）。
///
/// JSON 解析与逐行归并在 Rust（`native/fushi_compute/src/parse/fribb.rs`，原
/// `jsonDecode` + `fromRows` 的逐条照搬：同一 anidb_id 多行时 `mal_id` 取并集、其余字段
/// 首个合法值生效，非法值——非正数、小数、乱字符串——静默跳过）。不是合法 JSON 抛
/// [FfcFribbInvalidJson]，顶层不是数组抛 [FfcFribbNotAList]。
List<AnimeIdentityEntry> animeIdentityEntriesFromJsonUtf8(Uint8List utf8Json) =>
    <AnimeIdentityEntry>[
      for (final FfcFribbEntry e in FribbNative.instance.parseEntries(utf8Json))
        AnimeIdentityEntry(
          anidbId: e.anidbId,
          malIds: e.malIds.toSet(),
          anilistId: e.anilistId,
          tvdbId: e.tvdbId,
          tmdbId: e.tmdbId,
          tmdbSeason: e.tmdbSeason,
          tmdbEpisodeOffset: e.tmdbEpisodeOffset,
          tvdbSeason: e.tvdbSeason,
          tvdbEpisodeOffset: e.tvdbEpisodeOffset,
          type: e.type,
          tmdbIsMovieNamespace: e.tmdbIsMovieNamespace,
        ),
    ];

class _AnimeIdentityCatalog {
  const _AnimeIdentityCatalog({
    required this.byAnidb,
    required this.byMal,
    required this.byTmdbTv,
  });

  final Map<int, AnimeIdentityEntry> byAnidb;
  final Map<int, List<AnimeIdentityEntry>> byMal;
  final Map<int, List<AnimeIdentityEntry>> byTmdbTv;

  /// [entries] 已按 anidb_id 归并（[animeIdentityEntriesFromJsonUtf8]）。
  static _AnimeIdentityCatalog fromEntries(List<AnimeIdentityEntry> entries) {
    final Map<int, AnimeIdentityEntry> byAnidb = <int, AnimeIdentityEntry>{};
    final Map<int, List<AnimeIdentityEntry>> byMal =
        <int, List<AnimeIdentityEntry>>{};
    final Map<int, List<AnimeIdentityEntry>> byTmdbTv =
        <int, List<AnimeIdentityEntry>>{};
    for (final AnimeIdentityEntry entry in entries) {
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
    final int offset = (a.tmdbEpisodeOffset ?? 0).compareTo(
      b.tmdbEpisodeOffset ?? 0,
    );
    if (offset != 0) return offset;
    final int season = (a.tmdbSeason ?? 0).compareTo(b.tmdbSeason ?? 0);
    if (season != 0) return season;
    return a.anidbId.compareTo(b.anidbId);
  }
}
