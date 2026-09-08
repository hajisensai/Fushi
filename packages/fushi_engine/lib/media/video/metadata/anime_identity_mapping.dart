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
  Map<int, Set<int>>? _catalog;
  DateTime? _expiresAt;
  Future<Map<int, Set<int>>>? _loading;

  Future<AnimeIdentityMappingResult> lookupAnidb(int animeId) async {
    if (animeId <= 0) throw ArgumentError.value(animeId, 'animeId');
    final Map<int, Set<int>> catalog = await _load();
    return AnimeIdentityMappingResult(
      anidbId: animeId,
      malIds: catalog[animeId] ?? const <int>{},
    );
  }

  Future<Map<int, Set<int>>> _load() async {
    if (_catalog != null && _expiresAt!.isAfter(_now())) return _catalog!;
    if (_loading != null) return _loading!;
    final Future<Map<int, Set<int>>> pending = _download();
    _loading = pending;
    try {
      final Map<int, Set<int>> catalog = await pending;
      _catalog = catalog;
      _expiresAt = _now().add(cacheTtl);
      return catalog;
    } finally {
      _loading = null;
    }
  }

  Future<Map<int, Set<int>>> _download() async {
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
    final Map<int, Set<int>> catalog = <int, Set<int>>{};
    for (final Object? row in decoded) {
      if (row is! Map) continue;
      final int? aid = _positiveId(row['anidb_id']);
      final int? mal = _positiveId(row['mal_id']);
      if (aid == null || mal == null) continue;
      (catalog[aid] ??= <int>{}).add(mal);
    }
    return catalog;
  }

  static int? _positiveId(Object? value) {
    final int? id = value is int
        ? value
        : value is String
            ? int.tryParse(value)
            : null;
    return id != null && id > 0 ? id : null;
  }

  void close() {
    if (_ownsHttp) _http.close();
  }
}
