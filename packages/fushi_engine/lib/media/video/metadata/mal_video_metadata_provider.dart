library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:fushi_engine/media/video/metadata/video_metadata_json.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_languages.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_transport.dart';

/// Endpoints whose optional credits could not be loaded for this work.
const String malIncompleteCreditEndpointsKey =
    'mal_incomplete_credit_endpoints';

/// MAL metadata delivered by the public, read-only Jikan v4 API.
class MalVideoMetadataProvider implements VideoMetadataProvider {
  MalVideoMetadataProvider({
    http.Client? client,
    VideoMetadataHttpClient? transport,
    this.endpoint = 'https://api.jikan.moe/v4',
    this.language = kFallbackVideoMetadataLocale,
    MalVideoMetadataRequestGate? requestGate,
  })  : assert(client == null || transport == null),
        _transport = transport ??
            VideoMetadataHttpClient(client: client, maxAttempts: 1),
        _ownsTransport = transport == null,
        _gate = requestGate ?? sharedRequestGate {
    if (_transport.maxAttempts != 1) {
      throw ArgumentError('MAL transport must use maxAttempts: 1');
    }
  }

  static final MalVideoMetadataRequestGate sharedRequestGate =
      MalVideoMetadataRequestGate();
  final VideoMetadataHttpClient _transport;
  final bool _ownsTransport;
  final MalVideoMetadataRequestGate _gate;
  final String endpoint;

  /// 资料语言（BCP-47），与 TMDB provider 同源。MAL 只有日文 / 英文 / 罗马字
  /// 三种标题：`ja` 取 `title_japanese`，`en` 取 `title_english`，其它语言 MAL
  /// 没有译名，先落**原文**（`title_japanese`），由合并层用按资料语言投影的
  /// TMDB 补充源换成译名（见 `supplementVideoMetadata` 的标题语言感知）。
  ///
  /// 此前无论资料语言是什么都把 `title_japanese` 写进 `title`——海报、简介按
  /// 资料语言走而标题恒日文，就是「刮削不同语言」的来源。
  final String language;

  /// [language] 的主子标签（`zh-CN` → `zh`）。
  String get _titleLanguage => VideoMetadataLanguages(language).primarySubtag;

  @override
  VideoMetadataProviderKind get providerKind => VideoMetadataProviderKind.mal;
  @override
  bool get isAvailable => true;

  @override
  Future<List<VideoMetadataWork>> search(
      VideoMetadataSearchRequest request) async {
    final Map<String, Object?> payload = await _get('anime', <String, String>{
      'q': request.title,
      'limit': '${request.limit.clamp(1, 25)}',
      if (request.mediaKind == VideoMetadataMediaKind.movie) 'type': 'movie',
      if (request.year != null) 'start_date': '${request.year}-01-01',
      if (request.year != null) 'end_date': '${request.year}-12-31',
    });
    return <VideoMetadataWork>[
      for (final Object? node in metadataList(payload['data']))
        if (metadataObject(node) case final Map<String, Object?> item)
          if (_work(item) case final VideoMetadataWork work)
            if (work.kind == request.mediaKind) work,
    ];
  }

  @override
  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup) async {
    final String id = _id(lookup);
    final Map<String, Object?> payload;
    try {
      payload = await _get('anime/$id/full');
    } on VideoMetadataNetworkException catch (error) {
      if (error.statusCode == 404) return null;
      rethrow;
    }
    final Map<String, Object?>? item = metadataObject(payload['data']);
    if (item == null) return null;
    final VideoMetadataWork? work = _work(item);
    if (work == null) return null;
    final List<String> incomplete = <String>[];
    final Map<String, Object?> characters =
        await _optionalCredits(id, 'characters', incomplete);
    final Map<String, Object?> staff =
        await _optionalCredits(id, 'staff', incomplete);
    return work.copyWith(
      credits: _credits(characters, staff),
      rawPayload: <String, Object?>{
        ...item,
        if (incomplete.isNotEmpty) malIncompleteCreditEndpointsKey: incomplete,
      },
    );
  }

  Future<Map<String, Object?>> _optionalCredits(
    String id,
    String endpoint,
    List<String> incomplete,
  ) async {
    try {
      return await _get('anime/$id/$endpoint');
    } on VideoMetadataNetworkException {
      incomplete.add(endpoint);
      return const <String, Object?>{};
    }
  }

  @override
  Future<List<VideoMetadataSeason>> fetchSeasons(
      VideoMetadataLookup lookup) async {
    final VideoMetadataWork? work = await fetchWork(lookup);
    if (work == null || work.kind == VideoMetadataMediaKind.movie) {
      return const <VideoMetadataSeason>[];
    }
    return <VideoMetadataSeason>[
      VideoMetadataSeason(
          seasonNumber: 1,
          title: work.title,
          airDate: work.premiered,
          year: work.year,
          episodeCount: work.episodeCount,
          ids: work.ids,
          images: work.images)
    ];
  }

  @override
  Future<List<VideoMetadataEpisode>> fetchEpisodes(VideoMetadataLookup lookup,
      {required int seasonNumber}) async {
    final String id = _id(lookup);
    // MAL assigns a separate work identity to each season. The resolver remaps
    // this source season to the explicitly bound local season.
    if (seasonNumber != 1 || lookup.mediaKind == VideoMetadataMediaKind.movie) {
      return const <VideoMetadataEpisode>[];
    }
    final Map<int, VideoMetadataEpisode> episodes =
        <int, VideoMetadataEpisode>{};
    for (int page = 1;; page++) {
      final Map<String, Object?> payload =
          await _get('anime/$id/episodes', <String, String>{'page': '$page'});
      for (final Object? node in metadataList(payload['data'])) {
        final Map<String, Object?>? item = metadataObject(node);
        final int? number = metadataInt(item?['mal_id']);
        // MAL 分集只有日文 / 英文（`title`）/ 罗马字三种；阶梯与作品标题同一
        // 规则：本语言有就用本语言，没有就落原文，由合并层换译名。
        final String? title = _pickByLanguage(
          japanese: metadataString(item?['title_japanese']),
          english: metadataString(item?['title']),
          romaji: metadataString(item?['title_romanji']),
        );
        if (item == null || number == null || number < 1 || title == null) {
          continue;
        }
        final String? aired = _date(item['aired']);
        episodes[number] = VideoMetadataEpisode(
            seasonNumber: 1,
            episodeNumber: number,
            absoluteNumber: number,
            title: title,
            airDate: aired,
            year: metadataYear(aired),
            // MAL episode votes use a five-point scale; work scores use ten.
            rating: metadataDouble(item['score']) == null
                ? null
                : metadataDouble(item['score'])! * 2,
            ids: <VideoMetadataId>[
              VideoMetadataId(
                  type: 'mal_episode', value: '$id/$number', isDefault: true)
            ]);
      }
      if (metadataBool(
              metadataObject(payload['pagination'])?['has_next_page']) !=
          true) {
        break;
      }
      if (page >= 100) {
        throw const VideoMetadataNetworkException(
            'MAL episode pagination exceeds 100 pages');
      }
    }
    return episodes.values.toList()
      ..sort((VideoMetadataEpisode a, VideoMetadataEpisode b) =>
          a.episodeNumber.compareTo(b.episodeNumber));
  }

  /// 按资料语言在 MAL 的三种标题里选一个：本语言有就用本语言；`en` 缺英文名时
  /// 退罗马字（同为拉丁字母）；其它语言 MAL 没有译名，落**原文**日文，让合并层用
  /// TMDB 的译名替换——而不是落罗马字：对没匹配上 TMDB 的作品，原文比罗马字
  /// 更接近「这部作品叫什么」。
  String? _pickByLanguage({
    required String? japanese,
    required String? english,
    required String? romaji,
  }) =>
      switch (_titleLanguage) {
        'ja' => japanese ?? romaji ?? english,
        'en' => english ?? romaji ?? japanese,
        _ => japanese ?? romaji ?? english,
      };

  VideoMetadataWork? _work(Map<String, Object?> item) {
    final int? id = metadataInt(item['mal_id']);
    final String? title = _pickByLanguage(
      japanese: metadataString(item['title_japanese']),
      english: metadataString(item['title_english']),
      romaji: metadataString(item['title']),
    );
    if (id == null || id <= 0 || title == null) return null;
    final String? premiered = _date(metadataObject(item['aired'])?['from']);
    final String? cover = _image(item);
    return VideoMetadataWork(
        provider: providerKind,
        kind: metadataString(item['type']) == 'Movie'
            ? VideoMetadataMediaKind.movie
            : VideoMetadataMediaKind.tv,
        title: title,
        originalTitle: metadataString(item['title_japanese']),
        // 三种标题全部进别名池（选中的那个被过滤掉）：exact gate 比的是
        // title / originalTitle / aliases，标题按语言换了，匹配面不能跟着缩。
        aliases: metadataUniqueStrings(<String?>[
          metadataString(item['title_japanese']),
          metadataString(item['title']),
          metadataString(item['title_english']),
          for (final Object? node in metadataList(item['titles']))
            metadataString(metadataObject(node)?['title']),
          for (final Object? node in metadataList(item['title_synonyms']))
            metadataString(node),
        ]).where((String alias) => alias != title).toList(),
        year: metadataInt(item['year']) ?? metadataYear(premiered),
        premiered: premiered,
        plot: metadataStripHtml(metadataString(item['synopsis'])),
        rating: metadataDouble(item['score']),
        ratingVotes: metadataInt(item['scored_by']),
        episodeCount: metadataInt(item['episodes']),
        runtimeMinutes: _minutes(metadataString(item['duration'])),
        genres: _names(item['genres']),
        studios: _names(item['studios']),
        ids: <VideoMetadataId>[
          VideoMetadataId(type: 'mal', value: '$id', isDefault: true)
        ],
        images: <VideoMetadataImage>[
          if (cover != null)
            VideoMetadataImage(
                kind: VideoMetadataImageKind.cover,
                url: cover,
                provider: providerKind)
        ]);
  }

  List<VideoMetadataCredit> _credits(
      Map<String, Object?> characters, Map<String, Object?> staff) {
    final List<VideoMetadataCredit> credits = <VideoMetadataCredit>[];
    for (final Object? node in metadataList(characters['data'])) {
      final Map<String, Object?>? item = metadataObject(node);
      final Map<String, Object?>? character =
          metadataObject(item?['character']);
      final String? name = metadataString(character?['name']);
      if (item == null || character == null || name == null) continue;
      final String? characterId = metadataInt(character['mal_id'])?.toString();
      for (final Object? actorNode in metadataList(item['voice_actors'])) {
        final Map<String, Object?>? actor = metadataObject(actorNode);
        if (metadataString(actor?['language']) != 'Japanese') continue;
        final VideoMetadataPerson? person =
            _person(metadataObject(actor?['person']));
        if (person == null) continue;
        credits.add(VideoMetadataCredit(
            kind: VideoMetadataCreditKind.voiceActor,
            person: person,
            character: VideoMetadataCharacter(
                id: characterId,
                name: name,
                imageUrl: _image(character),
                ids: <VideoMetadataId>[
                  if (characterId != null)
                    VideoMetadataId(type: 'mal', value: characterId)
                ]),
            language: 'ja',
            roleName: name,
            order: credits.length));
      }
    }
    for (final Object? node in metadataList(staff['data'])) {
      final Map<String, Object?>? item = metadataObject(node);
      final VideoMetadataPerson? person =
          _person(metadataObject(item?['person']));
      if (person == null) continue;
      for (final Object? position in metadataList(item?['positions'])) {
        final String? job = metadataString(position);
        final String lower = job?.toLowerCase() ?? '';
        final VideoMetadataCreditKind? kind = lower.contains('director')
            ? VideoMetadataCreditKind.director
            : lower.contains('script') ||
                    lower.contains('screenplay') ||
                    lower.contains('series composition')
                ? VideoMetadataCreditKind.writer
                : null;
        if (kind != null) {
          credits.add(VideoMetadataCredit(
              kind: kind, person: person, job: job, order: credits.length));
        }
      }
    }
    return credits;
  }

  VideoMetadataPerson? _person(Map<String, Object?>? item) {
    final String? name = metadataString(item?['name']);
    if (item == null || name == null) return null;
    final String? id = metadataInt(item['mal_id'])?.toString();
    return VideoMetadataPerson(
        id: id,
        name: name,
        profileUrl: _image(item),
        ids: <VideoMetadataId>[
          if (id != null) VideoMetadataId(type: 'mal', value: id)
        ]);
  }

  String? _image(Map<String, Object?> item) {
    final Map<String, Object?>? images = metadataObject(item['images']);
    final Map<String, Object?>? jpg = metadataObject(images?['jpg']);
    return metadataString(jpg?['large_image_url']) ??
        metadataString(jpg?['image_url']);
  }

  List<String> _names(Object? items) =>
      metadataUniqueStrings(metadataList(items).map(
          (Object? node) => metadataString(metadataObject(node)?['name'])));
  String? _date(Object? value) => metadataString(value)?.split('T').first;
  int? _minutes(String? duration) {
    if (duration == null) return null;
    final int hours = int.tryParse(
            RegExp(r'(\d+)\s*hr').firstMatch(duration)?.group(1) ?? '') ??
        0;
    final int minutes = int.tryParse(
            RegExp(r'(\d+)\s*min').firstMatch(duration)?.group(1) ?? '') ??
        0;
    return hours + minutes == 0 ? null : hours * 60 + minutes;
  }

  String _id(VideoMetadataLookup lookup) {
    final int? id = int.tryParse(lookup.externalId.trim());
    if (lookup.provider != providerKind || id == null || id <= 0) {
      throw ArgumentError.value(lookup, 'lookup', 'Not a MAL anime lookup');
    }
    return '$id';
  }

  Future<Map<String, Object?>> _get(String path, [Map<String, String>? query]) {
    final Uri uri =
        Uri.parse('${endpoint.replaceFirst(RegExp(r'/+$'), '')}/$path')
            .replace(queryParameters: query);
    return _gate.get(
        uri.toString(),
        () => _transport.get(uri,
            operation: 'MAL $path',
            headers: const <String, String>{'Accept': 'application/json'}));
  }

  @override
  void close() {
    if (_ownsTransport) _transport.close();
  }
}

/// One gate is shared by all production instances: <= 60 starts/minute,
/// coalesced concurrent reads, bounded cache, and server-directed cooldown.
class MalVideoMetadataRequestGate {
  MalVideoMetadataRequestGate(
      {VideoMetadataNow? now,
      VideoMetadataRetrySleep? sleep,
      this.interval = const Duration(seconds: 1),
      this.cacheTtl = const Duration(hours: 1)})
      : _now = now ?? DateTime.now,
        _sleep = sleep ?? Future<void>.delayed;
  final VideoMetadataNow _now;
  final VideoMetadataRetrySleep _sleep;
  final Duration interval;
  final Duration cacheTtl;
  DateTime? _nextStart;
  Future<void> _queue = Future<void>.value();
  final Map<String, ({DateTime expires, String body})> _cache =
      <String, ({DateTime expires, String body})>{};
  final Map<String, Future<String>> _pending = <String, Future<String>>{};

  Future<Map<String, Object?>> get(
      String key, Future<VideoMetadataHttpResponse> Function() request) async {
    final ({DateTime expires, String body})? cached = _cache[key];
    if (cached != null && cached.expires.isAfter(_now())) {
      return jsonDecode(cached.body) as Map<String, Object?>;
    }
    _cache.remove(key);
    final Future<String> future = _pending[key] ??= _load(key, request);
    try {
      return jsonDecode(await future) as Map<String, Object?>;
    } finally {
      if (identical(_pending[key], future)) _pending.remove(key);
    }
  }

  Future<String> _load(
      String key, Future<VideoMetadataHttpResponse> Function() request) async {
    final Completer<String> result = Completer<String>();
    _queue = _queue.then((_) async {
      try {
        final Duration wait = _nextStart?.difference(_now()) ?? Duration.zero;
        if (wait > Duration.zero) await _sleep(wait);
        _nextStart = _now().add(interval);
        final VideoMetadataHttpResponse response = await request();
        response.decodeJsonObject(operation: 'MAL');
        _cache.removeWhere(
            (String _, ({DateTime expires, String body}) entry) =>
                !entry.expires.isAfter(_now()));
        if (_cache.length >= 256) _cache.remove(_cache.keys.first);
        _cache[key] = (expires: _now().add(cacheTtl), body: response.body);
        result.complete(response.body);
      } catch (error, stack) {
        if (error is VideoMetadataNetworkException && error.statusCode == 429) {
          final DateTime cooldown =
              _now().add(error.retryAfter ?? const Duration(seconds: 60));
          if (_nextStart == null || cooldown.isAfter(_nextStart!)) {
            _nextStart = cooldown;
          }
        }
        result.completeError(error, stack);
      }
    });
    return result.future;
  }
}
