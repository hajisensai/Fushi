/// 用户授权的豆瓣元数据适配器。
///
/// 本实现只访问用户配置的合规端点，绝不包含 Frodo 私有签名、客户端密钥或移动端
/// User-Agent。端点需提供本文约定的中立 JSON（`/search`、`/works/{id}`、可选
/// seasons/episodes）；未同时配置 endpoint 与 bearer token 时 provider 不可用。
library;

import 'package:hibiki/src/media/video/metadata/video_metadata_json.dart';
import 'package:hibiki/src/media/video/metadata/video_metadata_models.dart';
import 'package:hibiki/src/media/video/metadata/video_metadata_provider.dart';
import 'package:hibiki/src/media/video/metadata/video_metadata_transport.dart';
import 'package:http/http.dart' as http;

class AuthorizedDoubanVideoMetadataProvider
    implements VideoMetadataProvider, VideoMetadataExtrasProvider {
  AuthorizedDoubanVideoMetadataProvider({
    required String endpoint,
    required String token,
    http.Client? client,
    VideoMetadataHttpClient? transport,
  })  : assert(client == null || transport == null),
        endpoint = endpoint.trim().replaceFirst(RegExp(r'/+$'), ''),
        _token = token.trim(),
        _transport = transport ?? VideoMetadataHttpClient(client: client),
        _ownsTransport = transport == null;

  final String endpoint;
  final String _token;
  final VideoMetadataHttpClient _transport;
  final bool _ownsTransport;

  @override
  VideoMetadataProviderKind get providerKind =>
      VideoMetadataProviderKind.douban;

  @override
  bool get isAvailable {
    final Uri? uri = Uri.tryParse(endpoint);
    return _token.isNotEmpty &&
        uri != null &&
        uri.host.isNotEmpty &&
        _isCredentialSafeEndpoint(uri);
  }

  /// Bearer credentials may cross the network only over TLS. Plain HTTP is
  /// limited to an explicit loopback bridge so a locally hosted, authorized
  /// adapter remains usable without exposing its token on the LAN or Internet.
  static bool _isCredentialSafeEndpoint(Uri uri) {
    if (uri.scheme.toLowerCase() == 'https') return true;
    if (uri.scheme.toLowerCase() != 'http') return false;
    final String host = uri.host.toLowerCase();
    return host == 'localhost' || host == '127.0.0.1' || host == '::1';
  }

  @override
  Future<List<VideoMetadataWork>> search(
    VideoMetadataSearchRequest request,
  ) async {
    _requireAvailable();
    final Map<String, Object?> payload = await _getObject(
      '/search',
      operation: 'Authorized Douban search',
      query: <String, String>{
        'query': request.title,
        'kind': request.mediaKind.name,
        if (request.year != null) 'year': '${request.year}',
        'limit': '${request.limit.clamp(1, 50)}',
      },
      cacheKey:
          'douban:search:${request.title}:${request.year}:${request.mediaKind.name}',
    );
    final List<Object?> items = metadataList(payload['items']).isNotEmpty
        ? metadataList(payload['items'])
        : metadataList(payload['data']);
    return <VideoMetadataWork>[
      for (final Object? node in items)
        if (metadataObject(node) case final Map<String, Object?> item)
          if (_mapWork(item) case final VideoMetadataWork work)
            if (work.kind == request.mediaKind) work,
    ];
  }

  @override
  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup) async {
    _validateLookup(lookup);
    final Map<String, Object?>? payload = await _getObjectOrNull(
      '/works/${Uri.encodeComponent(lookup.externalId)}',
      operation: 'Authorized Douban work',
      cacheKey: 'douban:work:${lookup.externalId}',
    );
    if (payload == null) return null;
    final Map<String, Object?> workPayload =
        metadataObject(payload['work']) ?? payload;
    final VideoMetadataWork? work = _mapWork(workPayload);
    if (work == null || work.kind == VideoMetadataMediaKind.movie) return work;
    final List<VideoMetadataSeason> seasons = await fetchSeasons(lookup);
    return work.copyWith(
      seasons: seasons.isEmpty ? work.seasons : seasons,
    );
  }

  @override
  Future<List<VideoMetadataSeason>> fetchSeasons(
    VideoMetadataLookup lookup,
  ) async {
    _validateLookup(lookup);
    if (lookup.mediaKind == VideoMetadataMediaKind.movie) {
      return const <VideoMetadataSeason>[];
    }
    final Map<String, Object?>? payload = await _getObjectOrNull(
      '/works/${Uri.encodeComponent(lookup.externalId)}/seasons',
      operation: 'Authorized Douban seasons',
      cacheKey: 'douban:seasons:${lookup.externalId}',
    );
    if (payload == null) return const <VideoMetadataSeason>[];
    final List<Object?> items = metadataList(payload['items']).isNotEmpty
        ? metadataList(payload['items'])
        : metadataList(payload['data']);
    final List<VideoMetadataSeason> seasons = <VideoMetadataSeason>[];
    for (final Object? node in items) {
      final Map<String, Object?>? item = metadataObject(node);
      final int? number = metadataInt(item?['seasonNumber'] ?? item?['season']);
      if (item == null || number == null) continue;
      final List<VideoMetadataEpisode> embedded = <VideoMetadataEpisode>[
        for (final Object? episode in metadataList(item['episodes']))
          if (metadataObject(episode) case final Map<String, Object?> value)
            if (_mapEpisode(value, number)
                case final VideoMetadataEpisode mapped)
              mapped,
      ];
      seasons.add(_mapSeason(item, number, embedded));
    }
    seasons.sort((VideoMetadataSeason a, VideoMetadataSeason b) =>
        a.seasonNumber.compareTo(b.seasonNumber));
    return seasons;
  }

  @override
  Future<List<VideoMetadataEpisode>> fetchEpisodes(
    VideoMetadataLookup lookup, {
    required int seasonNumber,
  }) async {
    _validateLookup(lookup);
    if (lookup.mediaKind == VideoMetadataMediaKind.movie) {
      return const <VideoMetadataEpisode>[];
    }
    final Map<String, Object?>? payload = await _getObjectOrNull(
      '/works/${Uri.encodeComponent(lookup.externalId)}/seasons/'
      '$seasonNumber/episodes',
      operation: 'Authorized Douban episodes',
      cacheKey: 'douban:episodes:${lookup.externalId}:$seasonNumber',
    );
    if (payload == null) return const <VideoMetadataEpisode>[];
    final List<Object?> items = metadataList(payload['items']).isNotEmpty
        ? metadataList(payload['items'])
        : metadataList(payload['data']);
    final List<VideoMetadataEpisode> episodes = <VideoMetadataEpisode>[
      for (final Object? node in items)
        if (metadataObject(node) case final Map<String, Object?> item)
          if (_mapEpisode(item, seasonNumber)
              case final VideoMetadataEpisode episode)
            episode,
    ];
    episodes.sort((VideoMetadataEpisode a, VideoMetadataEpisode b) =>
        a.episodeNumber.compareTo(b.episodeNumber));
    return episodes;
  }

  @override
  Future<List<VideoMetadataExtra>> fetchExtras(
    VideoMetadataLookup lookup,
  ) async =>
      const <VideoMetadataExtra>[];

  VideoMetadataWork? _mapWork(Map<String, Object?> item) {
    final String? id =
        metadataString(item['id']) ?? metadataInt(item['id'])?.toString();
    final String? title = metadataString(item['title']);
    if (id == null || title == null) return null;
    final VideoMetadataMediaKind kind =
        metadataString(item['kind'])?.toLowerCase() == 'movie'
            ? VideoMetadataMediaKind.movie
            : VideoMetadataMediaKind.tv;
    final String? premiered =
        metadataString(item['premiered']) ?? metadataString(item['airDate']);
    final String? originalTitle = metadataString(item['originalTitle']);
    return VideoMetadataWork(
      provider: providerKind,
      kind: kind,
      title: title,
      originalTitle: originalTitle,
      tagline: metadataString(item['tagline']),
      aliases: metadataUniqueStrings(<String?>[
        originalTitle,
        for (final Object? alias in metadataList(item['aliases']))
          metadataString(alias),
      ]).where((String alias) => alias != title).toList(),
      year: metadataInt(item['year']) ?? metadataYear(premiered),
      premiered: premiered,
      endDate: metadataString(item['endDate']),
      plot: metadataString(item['plot']) ?? metadataString(item['summary']),
      rating: metadataDouble(item['rating']),
      ratingVotes: metadataInt(item['ratingVotes']),
      runtimeMinutes: metadataInt(item['runtimeMinutes']),
      contentRating: metadataString(item['contentRating']),
      status: metadataString(item['status']),
      originalLanguage: metadataString(item['originalLanguage']),
      homepage: metadataString(item['homepage']),
      episodeGroupId: metadataString(item['episodeGroupId']),
      seasonCount: metadataInt(item['seasonCount']),
      episodeCount: metadataInt(item['episodeCount']),
      genres: _strings(item['genres']),
      studios: _strings(item['studios']),
      countries: _strings(item['countries']),
      keywords: _strings(item['keywords']),
      ids: <VideoMetadataId>[
        VideoMetadataId(type: 'douban', value: id, isDefault: true),
        ..._ids(item['ids'], skipType: 'douban'),
      ],
      credits: _credits(item['credits']),
      images: _images(item['images']),
      seasons: <VideoMetadataSeason>[
        for (final Object? node in metadataList(item['seasons']))
          if (metadataObject(node) case final Map<String, Object?> season)
            if (metadataInt(season['seasonNumber'] ?? season['season'])
                case final int number)
              _mapSeason(season, number, const <VideoMetadataEpisode>[]),
      ],
      rawPayload: item,
    );
  }

  VideoMetadataSeason _mapSeason(
    Map<String, Object?> item,
    int seasonNumber,
    List<VideoMetadataEpisode> episodes,
  ) {
    final String? airDate = metadataString(item['airDate']);
    return VideoMetadataSeason(
      seasonNumber: seasonNumber,
      title: metadataString(item['title']) ?? 'Season $seasonNumber',
      plot: metadataString(item['plot']),
      airDate: airDate,
      year: metadataInt(item['year']) ?? metadataYear(airDate),
      episodeCount: metadataInt(item['episodeCount']) ??
          (episodes.isEmpty ? null : episodes.length),
      rating: metadataDouble(item['rating']),
      ids: _ids(item['ids']),
      images: _images(item['images'], seasonNumber: seasonNumber),
      episodes: episodes,
    );
  }

  VideoMetadataEpisode? _mapEpisode(
    Map<String, Object?> item,
    int fallbackSeason,
  ) {
    final int seasonNumber =
        metadataInt(item['seasonNumber'] ?? item['season']) ?? fallbackSeason;
    final int? episodeNumber =
        metadataInt(item['episodeNumber'] ?? item['episode']);
    if (episodeNumber == null) return null;
    final String? airDate = metadataString(item['airDate']);
    return VideoMetadataEpisode(
      seasonNumber: seasonNumber,
      episodeNumber: episodeNumber,
      title: metadataString(item['title']) ?? '',
      plot: metadataString(item['plot']),
      airDate: airDate,
      year: metadataInt(item['year']) ?? metadataYear(airDate),
      absoluteNumber: metadataInt(item['absoluteNumber']),
      rating: metadataDouble(item['rating']),
      ratingVotes: metadataInt(item['ratingVotes']),
      runtimeMinutes: metadataInt(item['runtimeMinutes']),
      ids: _ids(item['ids']),
      credits: _credits(item['credits']),
      images: _images(
        item['images'],
        seasonNumber: seasonNumber,
        episodeNumber: episodeNumber,
      ),
    );
  }

  List<VideoMetadataId> _ids(Object? value, {String? skipType}) =>
      <VideoMetadataId>[
        for (final Object? node in metadataList(value))
          if (metadataObject(node) case final Map<String, Object?> item)
            if (metadataString(item['type']) case final String type)
              if (type.toLowerCase() != skipType)
                if (metadataString(item['value']) case final String id)
                  VideoMetadataId(
                    type: type.toLowerCase(),
                    value: id,
                    isDefault: metadataBool(
                          item['default'] ?? item['isDefault'],
                        ) ??
                        false,
                  ),
      ];

  List<VideoMetadataCredit> _credits(Object? value) {
    final List<VideoMetadataCredit> result = <VideoMetadataCredit>[];
    for (final Object? node in metadataList(value)) {
      final Map<String, Object?>? item = metadataObject(node);
      final Map<String, Object?>? person = metadataObject(item?['person']);
      final String? name = metadataString(person?['name']);
      final VideoMetadataCreditKind? kind = _creditKind(
        metadataString(item?['kind']),
      );
      if (item == null || person == null || name == null || kind == null) {
        continue;
      }
      final Map<String, Object?>? character = metadataObject(item['character']);
      result.add(VideoMetadataCredit(
        kind: kind,
        person: VideoMetadataPerson(
          id: metadataString(person['id']) ??
              metadataInt(person['id'])?.toString(),
          name: name,
          originalName: metadataString(person['originalName']),
          biography: metadataString(person['biography']),
          birthday: metadataString(person['birthday']),
          deathday: metadataString(person['deathday']),
          gender: metadataInt(person['gender']),
          placeOfBirth: metadataString(person['placeOfBirth']),
          profileUrl: metadataString(person['profileUrl']),
          ids: _ids(person['ids']),
        ),
        character:
            character == null || metadataString(character['name']) == null
                ? null
                : VideoMetadataCharacter(
                    id: metadataString(character['id']) ??
                        metadataInt(character['id'])?.toString(),
                    name: metadataString(character['name'])!,
                    originalName: metadataString(character['originalName']),
                    description: metadataString(character['description']),
                    imageUrl: metadataString(character['imageUrl']),
                    ids: _ids(character['ids']),
                  ),
        language: metadataString(item['language']),
        roleName: metadataString(item['roleName']),
        department: metadataString(item['department']),
        job: metadataString(item['job']),
        providerCreditId: metadataString(item['id']),
        order: metadataInt(item['order']) ?? result.length,
      ));
    }
    return result;
  }

  VideoMetadataCreditKind? _creditKind(String? value) => switch (value) {
        'director' => VideoMetadataCreditKind.director,
        'writer' => VideoMetadataCreditKind.writer,
        'actor' => VideoMetadataCreditKind.actor,
        'guest' => VideoMetadataCreditKind.guest,
        'voiceActor' || 'voice_actor' => VideoMetadataCreditKind.voiceActor,
        _ => null,
      };

  List<VideoMetadataImage> _images(
    Object? value, {
    int? seasonNumber,
    int? episodeNumber,
  }) {
    final List<VideoMetadataImage> images = <VideoMetadataImage>[];
    for (final Object? node in metadataList(value)) {
      final Map<String, Object?>? item = metadataObject(node);
      final String? url = metadataString(item?['url']);
      final VideoMetadataImageKind? kind =
          _imageKind(metadataString(item?['kind']));
      if (item == null || url == null || kind == null) continue;
      images.add(VideoMetadataImage(
        kind: kind,
        url: url,
        provider: providerKind,
        language: metadataString(item['language']),
        likes: metadataInt(item['likes']),
        voteAverage: metadataDouble(item['voteAverage']),
        voteCount: metadataInt(item['voteCount']),
        seasonNumber: seasonNumber,
        episodeNumber: episodeNumber,
      ));
    }
    return images;
  }

  VideoMetadataImageKind? _imageKind(String? value) => switch (value) {
        'cover' || 'poster' => VideoMetadataImageKind.cover,
        'backdrop' || 'fanart' => VideoMetadataImageKind.backdrop,
        'logo' => VideoMetadataImageKind.logo,
        'disc' => VideoMetadataImageKind.disc,
        'banner' => VideoMetadataImageKind.banner,
        'thumb' => VideoMetadataImageKind.thumb,
        'clearart' => VideoMetadataImageKind.clearart,
        'landscape' => VideoMetadataImageKind.landscape,
        _ => null,
      };

  List<String> _strings(Object? value) => metadataUniqueStrings(<String?>[
        for (final Object? node in metadataList(value)) metadataString(node),
      ]);

  Future<Map<String, Object?>> _getObject(
    String path, {
    required String operation,
    Map<String, String> query = const <String, String>{},
    required String cacheKey,
  }) async {
    final VideoMetadataHttpResponse response = await _transport.get(
      Uri.parse('$endpoint$path').replace(queryParameters: query),
      headers: <String, String>{
        'Accept': 'application/json',
        'Authorization': 'Bearer $_token',
      },
      operation: operation,
      cacheKey: cacheKey,
    );
    return response.decodeJsonObject(operation: operation);
  }

  Future<Map<String, Object?>?> _getObjectOrNull(
    String path, {
    required String operation,
    Map<String, String> query = const <String, String>{},
    required String cacheKey,
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

  void _requireAvailable() {
    if (!isAvailable) {
      throw const VideoMetadataProviderUnavailable(
        VideoMetadataProviderKind.douban,
        'An HTTPS authorized endpoint and bearer token are required '
        '(loopback HTTP is allowed for a local bridge)',
      );
    }
  }

  void _validateLookup(VideoMetadataLookup lookup) {
    _requireAvailable();
    if (lookup.provider != providerKind || lookup.externalId.trim().isEmpty) {
      throw ArgumentError.value(lookup, 'lookup', 'Not a Douban lookup');
    }
  }

  @override
  void close() {
    if (_ownsTransport) _transport.close();
  }
}
