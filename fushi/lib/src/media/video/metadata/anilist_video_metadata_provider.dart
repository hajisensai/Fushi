library;

import 'package:fushi/src/media/video/metadata/video_metadata_json.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_transport.dart';
import 'package:http/http.dart' as http;

class AniListVideoMetadataProvider
    implements VideoMetadataProvider, VideoMetadataExtrasProvider {
  AniListVideoMetadataProvider({
    http.Client? client,
    VideoMetadataHttpClient? transport,
    this.endpoint = 'https://graphql.anilist.co',
  })  : assert(client == null || transport == null),
        _transport = transport ?? VideoMetadataHttpClient(client: client),
        _ownsTransport = transport == null;

  final VideoMetadataHttpClient _transport;
  final bool _ownsTransport;
  final String endpoint;

  @override
  VideoMetadataProviderKind get providerKind =>
      VideoMetadataProviderKind.anilist;

  @override
  bool get isAvailable => true;

  static const String _searchQuery = r'''
query ($search: String!, $perPage: Int!, $year: Int) {
  Page(perPage: $perPage) {
    media(search: $search, type: ANIME, seasonYear: $year, sort: SEARCH_MATCH) {
      id
      idMal
      format
      title { native romaji english }
      synonyms
      startDate { year month day }
      episodes
      duration
      averageScore
      popularity
      description(asHtml: false)
      genres
      countryOfOrigin
      coverImage { extraLarge large }
      bannerImage
      siteUrl
    }
  }
}
''';

  static const String _detailsQuery = r'''
query ($id: Int!) {
  Media(id: $id, type: ANIME) {
    id
    idMal
    format
    title { native romaji english }
    synonyms
    startDate { year month day }
    episodes
    duration
    averageScore
    popularity
    description(asHtml: false)
    genres
    countryOfOrigin
    coverImage { extraLarge large }
    bannerImage
    siteUrl
    studios(isMain: true) { nodes { id name } }
    externalLinks { id site url type }
    characters(page: 1, perPage: 50, sort: ROLE) {
      edges {
        role
        node { id name { full native } image { large medium } }
        voiceActors(language: JAPANESE, sort: RELEVANCE) {
          id
          name { full native }
          image { large medium }
        }
      }
    }
    staff(page: 1, perPage: 50, sort: RELEVANCE) {
      edges {
        role
        node { id name { full native } image { large medium } }
      }
    }
  }
}
''';

  @override
  Future<List<VideoMetadataWork>> search(
    VideoMetadataSearchRequest request,
  ) async {
    final Map<String, Object?> payload = await _query(
      _searchQuery,
      <String, Object?>{
        'search': request.title,
        'perPage': request.limit.clamp(1, 50),
        if (request.year != null) 'year': request.year,
      },
      operation: 'AniList search',
      cacheKey:
          'anilist:search:${request.title}:${request.year}:${request.mediaKind.name}',
    );
    final Map<String, Object?>? page = metadataObject(
      metadataObject(payload['data'])?['Page'],
    );
    final List<VideoMetadataWork> works = <VideoMetadataWork>[];
    for (final Object? node in metadataList(page?['media'])) {
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
    final int? id = int.tryParse(lookup.externalId);
    if (id == null) return null;
    final Map<String, Object?> payload = await _query(
      _detailsQuery,
      <String, Object?>{'id': id},
      operation: 'AniList details',
      cacheKey: 'anilist:work:$id',
    );
    final Map<String, Object?>? item =
        metadataObject(metadataObject(payload['data'])?['Media']);
    return item == null ? null : _mapWork(item, detailed: true);
  }

  @override
  Future<List<VideoMetadataSeason>> fetchSeasons(
    VideoMetadataLookup lookup,
  ) async {
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
        images: work.images,
      ),
    ];
  }

  @override
  Future<List<VideoMetadataEpisode>> fetchEpisodes(
    VideoMetadataLookup lookup, {
    required int seasonNumber,
  }) async {
    _validateLookup(lookup);
    // AniList 公开 GraphQL 只给总集数，不提供可靠的逐集标题、日期与简介。为避免把
    // 作品资料冒充集资料，这里明确返回空，由 TMDB 补充层提供真实 episode 数据。
    return const <VideoMetadataEpisode>[];
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
    final Map<String, Object?> titles =
        metadataObject(item['title']) ?? const <String, Object?>{};
    final String? native = metadataString(titles['native']);
    final String? romaji = metadataString(titles['romaji']);
    final String? english = metadataString(titles['english']);
    final String? title = native ?? romaji ?? english;
    if (id == null || title == null) return null;
    final VideoMetadataMediaKind kind =
        metadataString(item['format']) == 'MOVIE'
            ? VideoMetadataMediaKind.movie
            : VideoMetadataMediaKind.tv;
    final String? premiered = _date(item['startDate']);
    final Map<String, Object?> cover =
        metadataObject(item['coverImage']) ?? const <String, Object?>{};
    final String? coverUrl =
        metadataString(cover['extraLarge']) ?? metadataString(cover['large']);
    final String? bannerUrl = metadataString(item['bannerImage']);
    return VideoMetadataWork(
      provider: providerKind,
      kind: kind,
      title: title,
      originalTitle: native == title ? null : native,
      aliases: metadataUniqueStrings(<String?>[
        native,
        romaji,
        english,
        for (final Object? synonym in metadataList(item['synonyms']))
          metadataString(synonym),
      ]).where((String alias) => alias != title).toList(),
      year: metadataYear(premiered),
      premiered: premiered,
      plot: metadataStripHtml(metadataString(item['description'])),
      rating: _score(item['averageScore']),
      ratingVotes: _positiveInt(item['popularity']),
      runtimeMinutes: _positiveInt(item['duration']),
      episodeCount: _positiveInt(item['episodes']),
      genres: <String>[
        for (final Object? genre in metadataList(item['genres']))
          if (metadataString(genre) case final String value) value,
      ],
      studios: <String>[
        for (final Object? studio in metadataList(
          metadataObject(item['studios'])?['nodes'],
        ))
          if (metadataString(metadataObject(studio)?['name'])
              case final String value)
            value,
      ],
      countries: <String>[
        if (metadataString(item['countryOfOrigin']) case final String country)
          country,
      ],
      ids: <VideoMetadataId>[
        VideoMetadataId(type: 'anilist', value: id, isDefault: true),
        if (metadataInt(item['idMal']) case final int malId)
          VideoMetadataId(type: 'mal', value: '$malId'),
        ..._externalIds(item['externalLinks']),
      ],
      credits: detailed ? _credits(item) : const <VideoMetadataCredit>[],
      images: <VideoMetadataImage>[
        if (coverUrl != null)
          VideoMetadataImage(
            kind: VideoMetadataImageKind.cover,
            url: coverUrl,
            provider: providerKind,
          ),
        if (bannerUrl != null)
          VideoMetadataImage(
            kind: VideoMetadataImageKind.backdrop,
            url: bannerUrl,
            provider: providerKind,
          ),
        if (bannerUrl != null)
          VideoMetadataImage(
            kind: VideoMetadataImageKind.banner,
            url: bannerUrl,
            provider: providerKind,
          ),
      ],
      rawPayload: detailed ? item : null,
    );
  }

  List<VideoMetadataId> _externalIds(Object? value) {
    final List<VideoMetadataId> ids = <VideoMetadataId>[];
    for (final Object? node in metadataList(value)) {
      final Map<String, Object?>? item = metadataObject(node);
      final String site = metadataString(item?['site'])?.toLowerCase() ?? '';
      final String? url = metadataString(item?['url']);
      final Uri? uri = url == null ? null : Uri.tryParse(url);
      if (site.contains('imdb') && uri != null) {
        for (final String segment in uri.pathSegments) {
          if (RegExp(r'^tt\d+$').hasMatch(segment)) {
            ids.add(VideoMetadataId(type: 'imdb', value: segment));
            break;
          }
        }
      }
    }
    return ids;
  }

  List<VideoMetadataCredit> _credits(Map<String, Object?> item) {
    final List<VideoMetadataCredit> credits = <VideoMetadataCredit>[];
    final Map<String, Object?> characters =
        metadataObject(item['characters']) ?? const <String, Object?>{};
    for (final Object? edgeNode in metadataList(characters['edges'])) {
      final Map<String, Object?>? edge = metadataObject(edgeNode);
      final Map<String, Object?>? characterNode = metadataObject(edge?['node']);
      final String? characterName = _name(characterNode?['name']);
      if (edge == null || characterNode == null || characterName == null) {
        continue;
      }
      final String? characterId = metadataInt(characterNode['id'])?.toString();
      final Map<String, Object?> characterImage =
          metadataObject(characterNode['image']) ?? const <String, Object?>{};
      final VideoMetadataCharacter character = VideoMetadataCharacter(
        id: characterId,
        name: characterName,
        originalName: metadataString(
          metadataObject(characterNode['name'])?['native'],
        ),
        imageUrl: metadataString(characterImage['large']) ??
            metadataString(characterImage['medium']),
        ids: <VideoMetadataId>[
          if (characterId != null)
            VideoMetadataId(type: 'anilist', value: characterId),
        ],
      );
      for (final Object? actorNode in metadataList(edge['voiceActors'])) {
        final Map<String, Object?>? actor = metadataObject(actorNode);
        final String? actorName = _name(actor?['name']);
        if (actor == null || actorName == null) continue;
        credits.add(VideoMetadataCredit(
          kind: VideoMetadataCreditKind.voiceActor,
          person: _person(actor, actorName),
          character: character,
          language: 'ja',
          roleName: characterName,
          order: credits.length,
        ));
      }
    }

    final Map<String, Object?> staff =
        metadataObject(item['staff']) ?? const <String, Object?>{};
    for (final Object? edgeNode in metadataList(staff['edges'])) {
      final Map<String, Object?>? edge = metadataObject(edgeNode);
      final Map<String, Object?>? personNode = metadataObject(edge?['node']);
      final String? name = _name(personNode?['name']);
      final String role = metadataString(edge?['role'])?.toLowerCase() ?? '';
      if (edge == null || personNode == null || name == null) continue;
      final VideoMetadataCreditKind? kind = role.contains('director')
          ? VideoMetadataCreditKind.director
          : (role.contains('script') ||
                  role.contains('screenplay') ||
                  role.contains('series composition') ||
                  role.contains('writer'))
              ? VideoMetadataCreditKind.writer
              : null;
      if (kind == null) continue;
      credits.add(VideoMetadataCredit(
        kind: kind,
        person: _person(personNode, name),
        job: metadataString(edge['role']),
        order: credits.length,
      ));
    }
    return credits;
  }

  VideoMetadataPerson _person(Map<String, Object?> item, String name) {
    final String? id = metadataInt(item['id'])?.toString();
    final Map<String, Object?> names =
        metadataObject(item['name']) ?? const <String, Object?>{};
    final Map<String, Object?> images =
        metadataObject(item['image']) ?? const <String, Object?>{};
    return VideoMetadataPerson(
      id: id,
      name: name,
      originalName: metadataString(names['native']),
      profileUrl:
          metadataString(images['large']) ?? metadataString(images['medium']),
      ids: <VideoMetadataId>[
        if (id != null) VideoMetadataId(type: 'anilist', value: id),
      ],
    );
  }

  String? _name(Object? value) {
    final Map<String, Object?>? names = metadataObject(value);
    return metadataString(names?['native']) ?? metadataString(names?['full']);
  }

  String? _date(Object? value) {
    final Map<String, Object?>? date = metadataObject(value);
    final int? year = metadataInt(date?['year']);
    if (year == null) return null;
    final int? month = metadataInt(date?['month']);
    final int? day = metadataInt(date?['day']);
    return <String>[
      '$year',
      if (month != null) month.toString().padLeft(2, '0'),
      if (day != null) day.toString().padLeft(2, '0'),
    ].join('-');
  }

  double? _score(Object? value) {
    final int? score = metadataInt(value);
    return score != null && score > 0 ? score / 10 : null;
  }

  int? _positiveInt(Object? value) {
    final int? result = metadataInt(value);
    return result != null && result > 0 ? result : null;
  }

  Future<Map<String, Object?>> _query(
    String query,
    Map<String, Object?> variables, {
    required String operation,
    required String cacheKey,
  }) async {
    final VideoMetadataHttpResponse response = await _transport.postJson(
      Uri.parse(endpoint),
      headers: const <String, String>{'Accept': 'application/json'},
      body: <String, Object?>{'query': query, 'variables': variables},
      operation: operation,
      cacheKey: cacheKey,
    );
    final Map<String, Object?> payload =
        response.decodeJsonObject(operation: operation);
    final List<Object?> errors = metadataList(payload['errors']);
    if (errors.isNotEmpty) {
      final String message =
          metadataString(metadataObject(errors.first)?['message']) ??
              '${errors.first}';
      throw VideoMetadataNetworkException('$operation GraphQL error: $message');
    }
    return payload;
  }

  void _validateLookup(VideoMetadataLookup lookup) {
    if (lookup.provider != providerKind || lookup.externalId.trim().isEmpty) {
      throw ArgumentError.value(lookup, 'lookup', 'Not an AniList lookup');
    }
  }

  @override
  void close() {
    if (_ownsTransport) _transport.close();
  }
}
