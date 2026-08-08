library;

import 'package:hibiki/src/media/video/metadata/video_metadata_json.dart';
import 'package:hibiki/src/media/video/metadata/video_metadata_models.dart';
import 'package:hibiki/src/media/video/metadata/video_metadata_provider.dart';
import 'package:hibiki/src/media/video/metadata/video_metadata_transport.dart';
import 'package:http/http.dart' as http;

class BangumiVideoMetadataProvider
    implements VideoMetadataProvider, VideoMetadataExtrasProvider {
  BangumiVideoMetadataProvider({
    http.Client? client,
    VideoMetadataHttpClient? transport,
    this.baseUrl = 'https://api.bgm.tv/v0',
    this.accessToken = '',
    this.userAgent = 'hajisensai/hibiki/1.4.0 '
        '(https://github.com/hajisensai/hibiki)',
  })  : assert(client == null || transport == null),
        _transport = transport ?? VideoMetadataHttpClient(client: client),
        _ownsTransport = transport == null;

  final VideoMetadataHttpClient _transport;
  final bool _ownsTransport;
  final String baseUrl;
  final String accessToken;
  final String userAgent;

  @override
  VideoMetadataProviderKind get providerKind =>
      VideoMetadataProviderKind.bangumi;

  @override
  bool get isAvailable => true;

  @override
  Future<List<VideoMetadataWork>> search(
    VideoMetadataSearchRequest request,
  ) async {
    final VideoMetadataHttpResponse response = await _transport.postJson(
      Uri.parse('$baseUrl/search/subjects').replace(
        queryParameters: <String, String>{
          'limit': '${request.limit.clamp(1, 50)}',
        },
      ),
      headers: _headers,
      body: <String, Object?>{
        'keyword': request.title,
        'filter': <String, Object?>{
          'type': const <int>[2],
        },
      },
      operation: 'Bangumi search',
      cacheKey:
          'bangumi:search:${request.title}:${request.year}:${request.mediaKind.name}',
    );
    final Map<String, Object?> payload =
        response.decodeJsonObject(operation: 'Bangumi search');
    final List<VideoMetadataWork> works = <VideoMetadataWork>[];
    for (final Object? node in metadataList(payload['data'])) {
      final Map<String, Object?>? item = metadataObject(node);
      if (item == null) continue;
      final VideoMetadataWork? work = _mapWork(item, detailed: false);
      if (work != null && work.kind == request.mediaKind) works.add(work);
    }
    return works;
  }

  @override
  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup) async {
    _validateLookup(lookup);
    final Map<String, Object?>? payload = await _getObjectOrNull(
      '/subjects/${lookup.externalId}',
      operation: 'Bangumi subject details',
      cacheKey: 'bangumi:work:${lookup.externalId}',
    );
    if (payload == null) return null;
    final VideoMetadataWork? base = _mapWork(payload, detailed: true);
    if (base == null) return null;
    final List<VideoMetadataCredit> credits = await _fetchCredits(
      lookup.externalId,
    );
    final List<VideoMetadataEpisode> episodes =
        base.kind == VideoMetadataMediaKind.tv
            ? await fetchEpisodes(
                lookup.copyWithMediaKind(base.kind),
                seasonNumber: 1,
              )
            : const <VideoMetadataEpisode>[];
    return base.copyWith(
      credits: credits,
      seasons: base.kind == VideoMetadataMediaKind.tv
          ? <VideoMetadataSeason>[
              VideoMetadataSeason(
                seasonNumber: 1,
                title: base.title,
                airDate: base.premiered,
                year: base.year,
                episodeCount:
                    episodes.isEmpty ? base.episodeCount : episodes.length,
                ids: base.ids,
                images: base.images,
                episodes: episodes,
              ),
            ]
          : const <VideoMetadataSeason>[],
    );
  }

  @override
  Future<List<VideoMetadataSeason>> fetchSeasons(
    VideoMetadataLookup lookup,
  ) async {
    _validateLookup(lookup);
    final VideoMetadataWork? work = await fetchWork(lookup);
    return work?.seasons ?? const <VideoMetadataSeason>[];
  }

  @override
  Future<List<VideoMetadataEpisode>> fetchEpisodes(
    VideoMetadataLookup lookup, {
    required int seasonNumber,
  }) async {
    _validateLookup(lookup);
    if (lookup.mediaKind == VideoMetadataMediaKind.movie || seasonNumber != 1) {
      return const <VideoMetadataEpisode>[];
    }
    final List<VideoMetadataEpisode> episodes = <VideoMetadataEpisode>[];
    int offset = 0;
    while (true) {
      final Map<String, Object?> payload = await _getObject(
        '/episodes',
        operation: 'Bangumi episodes',
        query: <String, String>{
          'subject_id': lookup.externalId,
          'type': '0',
          'limit': '200',
          'offset': '$offset',
        },
        cacheKey: 'bangumi:episodes:${lookup.externalId}:$offset',
      );
      final List<Object?> data = metadataList(payload['data']);
      for (final Object? node in data) {
        final Map<String, Object?>? item = metadataObject(node);
        final double? sort = metadataDouble(item?['sort']);
        if (item == null || sort == null || sort <= 0 || sort % 1 != 0) {
          continue;
        }
        final int episodeNumber = sort.toInt();
        final String? airDate = metadataString(item['airdate']);
        episodes.add(VideoMetadataEpisode(
          seasonNumber: 1,
          episodeNumber: episodeNumber,
          title: metadataString(item['name_cn']) ??
              metadataString(item['name']) ??
              '',
          plot: metadataString(item['desc']),
          airDate: airDate,
          year: metadataYear(airDate),
          runtimeMinutes: _durationMinutes(item['duration']),
          ids: <VideoMetadataId>[
            if (metadataInt(item['id']) case final int id)
              VideoMetadataId(
                type: 'bangumi',
                value: '$id',
                isDefault: true,
              ),
          ],
        ));
      }
      offset += data.length;
      final int total = metadataInt(payload['total']) ?? offset;
      if (data.isEmpty || offset >= total) break;
    }
    episodes.sort((VideoMetadataEpisode a, VideoMetadataEpisode b) =>
        a.episodeNumber.compareTo(b.episodeNumber));
    return episodes;
  }

  @override
  Future<List<VideoMetadataExtra>> fetchExtras(
    VideoMetadataLookup lookup,
  ) async =>
      const <VideoMetadataExtra>[];

  VideoMetadataWork? _mapWork(
    Map<String, Object?> item, {
    required bool detailed,
  }) {
    final String? id = metadataInt(item['id'])?.toString();
    final String? originalTitle = metadataString(item['name']);
    final String? localizedTitle = metadataString(item['name_cn']);
    final String? title = localizedTitle ?? originalTitle;
    if (id == null || title == null) return null;
    final VideoMetadataMediaKind kind = _mediaKind(item);
    final String? premiered = metadataString(item['date']);
    final Map<String, Object?> images =
        metadataObject(item['images']) ?? const <String, Object?>{};
    final String? cover = metadataString(images['large']) ??
        metadataString(images['common']) ??
        metadataString(images['medium']);
    final List<String> aliases = <String>[
      if (originalTitle != null && originalTitle != title) originalTitle,
      ..._infoboxAliases(item['infobox']),
    ];
    return VideoMetadataWork(
      provider: providerKind,
      kind: kind,
      title: title,
      originalTitle: originalTitle == title ? null : originalTitle,
      aliases: metadataUniqueStrings(aliases),
      year: metadataYear(premiered),
      premiered: premiered,
      plot: metadataString(item['summary']),
      rating: _positiveDouble(
        metadataObject(item['rating'])?['score'] ?? item['score'],
      ),
      ratingVotes: _positiveInt(metadataObject(item['rating'])?['total']),
      episodeCount: _positiveInt(item['eps']),
      genres: <String>[
        for (final Object? node in metadataList(item['tags']))
          if (metadataString(metadataObject(node)?['name'])
              case final String name)
            name,
      ],
      studios: _infoboxValues(
        item['infobox'],
        const <String>{'动画制作', '動畫製作', '製作', '制作'},
      ),
      ids: <VideoMetadataId>[
        VideoMetadataId(type: 'bangumi', value: id, isDefault: true),
      ],
      images: <VideoMetadataImage>[
        if (cover != null)
          VideoMetadataImage(
            kind: VideoMetadataImageKind.cover,
            url: cover,
            provider: providerKind,
          ),
      ],
      rawPayload: detailed ? item : null,
    );
  }

  VideoMetadataMediaKind _mediaKind(Map<String, Object?> item) {
    final String platform = metadataString(item['platform'])?.toLowerCase() ??
        metadataString(item['type'])?.toLowerCase() ??
        '';
    return platform.contains('movie') ||
            platform.contains('剧场') ||
            platform.contains('劇場') ||
            platform.contains('映画')
        ? VideoMetadataMediaKind.movie
        : VideoMetadataMediaKind.tv;
  }

  Future<List<VideoMetadataCredit>> _fetchCredits(String subjectId) async {
    final List<VideoMetadataCredit> credits = <VideoMetadataCredit>[];
    final Map<String, Object?>? characters = await _getObjectOrNull(
      '/subjects/$subjectId/characters',
      operation: 'Bangumi characters',
      cacheKey: 'bangumi:characters:$subjectId',
    );
    for (final Object? node in _arrayPayload(characters)) {
      final Map<String, Object?>? item = metadataObject(node);
      final String? characterName = metadataString(item?['name']);
      if (item == null || characterName == null) continue;
      final String? characterId = metadataInt(item['id'])?.toString();
      final Map<String, Object?> characterImages =
          metadataObject(item['images']) ?? const <String, Object?>{};
      final VideoMetadataCharacter character = VideoMetadataCharacter(
        id: characterId,
        name: characterName,
        description: metadataString(item['summary']),
        imageUrl: metadataString(characterImages['large']) ??
            metadataString(characterImages['medium']),
        ids: <VideoMetadataId>[
          if (characterId != null)
            VideoMetadataId(type: 'bangumi', value: characterId),
        ],
      );
      for (final Object? actorNode in metadataList(item['actors'])) {
        final Map<String, Object?>? actor = metadataObject(actorNode);
        final String? actorName = metadataString(actor?['name']);
        if (actor == null || actorName == null) continue;
        final String? actorId = metadataInt(actor['id'])?.toString();
        final Map<String, Object?> actorImages =
            metadataObject(actor['images']) ?? const <String, Object?>{};
        credits.add(VideoMetadataCredit(
          kind: VideoMetadataCreditKind.voiceActor,
          person: VideoMetadataPerson(
            id: actorId,
            name: actorName,
            profileUrl: metadataString(actorImages['large']) ??
                metadataString(actorImages['medium']),
            ids: <VideoMetadataId>[
              if (actorId != null)
                VideoMetadataId(type: 'bangumi', value: actorId),
            ],
          ),
          character: character,
          language: metadataString(actor['career']),
          roleName: characterName,
          order: credits.length,
        ));
      }
    }

    final Map<String, Object?>? persons = await _getObjectOrNull(
      '/subjects/$subjectId/persons',
      operation: 'Bangumi persons',
      cacheKey: 'bangumi:persons:$subjectId',
    );
    for (final Object? node in _arrayPayload(persons)) {
      final Map<String, Object?>? item = metadataObject(node);
      final Map<String, Object?>? person =
          metadataObject(item?['person']) ?? item;
      final String? name = metadataString(person?['name']);
      final String relation = metadataString(item?['relation']) ?? '';
      if (person == null || name == null) continue;
      final VideoMetadataCreditKind? kind =
          _bangumiStaffKind(relation.toLowerCase());
      if (kind == null) continue;
      final String? id = metadataInt(person['id'])?.toString();
      final Map<String, Object?> images =
          metadataObject(person['images']) ?? const <String, Object?>{};
      credits.add(VideoMetadataCredit(
        kind: kind,
        person: VideoMetadataPerson(
          id: id,
          name: name,
          profileUrl: metadataString(images['large']) ??
              metadataString(images['medium']),
          ids: <VideoMetadataId>[
            if (id != null) VideoMetadataId(type: 'bangumi', value: id),
          ],
        ),
        job: relation,
        order: credits.length,
      ));
    }
    return credits;
  }

  VideoMetadataCreditKind? _bangumiStaffKind(String relation) {
    if (relation.contains('导演') ||
        relation.contains('監督') ||
        relation.contains('director')) {
      return VideoMetadataCreditKind.director;
    }
    if (relation.contains('脚本') ||
        relation.contains('劇本') ||
        relation.contains('编剧') ||
        relation.contains('series composition') ||
        relation.contains('writer')) {
      return VideoMetadataCreditKind.writer;
    }
    return null;
  }

  List<Object?> _arrayPayload(Map<String, Object?>? payload) {
    if (payload == null) return const <Object?>[];
    return metadataList(payload['data']).isNotEmpty
        ? metadataList(payload['data'])
        : metadataList(payload['items']);
  }

  List<String> _infoboxAliases(Object? value) => _infoboxValues(
        value,
        const <String>{'别名', '別名'},
      );

  List<String> _infoboxValues(Object? value, Set<String> acceptedKeys) {
    final List<String> values = <String>[];
    for (final Object? node in metadataList(value)) {
      final Map<String, Object?>? item = metadataObject(node);
      final String? key = metadataString(item?['key']);
      if (item == null || key == null || !acceptedKeys.contains(key)) continue;
      final Object? raw = item['value'];
      if (raw is String) {
        values.addAll(raw.split(RegExp(r'[/、,]')));
      } else {
        for (final Object? part in metadataList(raw)) {
          values.add(
            metadataString(metadataObject(part)?['v']) ??
                metadataString(part) ??
                '',
          );
        }
      }
    }
    return metadataUniqueStrings(values);
  }

  int? _durationMinutes(Object? value) {
    final String? text = metadataString(value);
    if (text == null) return null;
    final RegExpMatch? match = RegExp(r'(\d+)').firstMatch(text);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  int? _positiveInt(Object? value) {
    final int? parsed = metadataInt(value);
    return parsed != null && parsed > 0 ? parsed : null;
  }

  double? _positiveDouble(Object? value) {
    final double? parsed = metadataDouble(value);
    return parsed != null && parsed > 0 ? parsed : null;
  }

  Future<Map<String, Object?>> _getObject(
    String path, {
    required String operation,
    Map<String, String> query = const <String, String>{},
    String? cacheKey,
  }) async {
    final VideoMetadataHttpResponse response = await _transport.get(
      Uri.parse('$baseUrl$path').replace(queryParameters: query),
      headers: _headers,
      operation: operation,
      cacheKey: cacheKey,
    );
    final Object? decoded = response.decodeJson(operation: operation);
    if (decoded is List<Object?>) {
      return <String, Object?>{'data': decoded};
    }
    if (decoded is Map<String, Object?>) return decoded;
    throw VideoMetadataNetworkException(
      '$operation response is not an object or array',
      statusCode: response.statusCode,
    );
  }

  Future<Map<String, Object?>?> _getObjectOrNull(
    String path, {
    required String operation,
    Map<String, String> query = const <String, String>{},
    String? cacheKey,
  }) async {
    try {
      return await _getObject(
        path,
        operation: operation,
        query: query,
        cacheKey: cacheKey,
      );
    } on VideoMetadataNetworkException catch (error) {
      if (error.statusCode == 404) return null;
      rethrow;
    }
  }

  Map<String, String> get _headers => <String, String>{
        'Accept': 'application/json',
        'User-Agent': userAgent,
        if (accessToken.trim().isNotEmpty)
          'Authorization': 'Bearer ${accessToken.trim()}',
      };

  void _validateLookup(VideoMetadataLookup lookup) {
    if (lookup.provider != providerKind || lookup.externalId.trim().isEmpty) {
      throw ArgumentError.value(lookup, 'lookup', 'Not a Bangumi lookup');
    }
  }

  @override
  void close() {
    if (_ownsTransport) _transport.close();
  }
}

extension on VideoMetadataLookup {
  VideoMetadataLookup copyWithMediaKind(VideoMetadataMediaKind mediaKind) =>
      VideoMetadataLookup(
        provider: provider,
        externalId: externalId,
        mediaKind: mediaKind,
      );
}
