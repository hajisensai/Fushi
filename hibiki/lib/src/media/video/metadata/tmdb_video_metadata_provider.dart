library;

import 'package:hibiki/src/media/video/metadata/video_metadata_json.dart';
import 'package:hibiki/src/media/video/metadata/video_metadata_models.dart';
import 'package:hibiki/src/media/video/metadata/video_metadata_provider.dart';
import 'package:hibiki/src/media/video/metadata/video_metadata_transport.dart';
import 'package:hibiki/src/media/video/scraper/title_normalizer.dart';
import 'package:http/http.dart' as http;

class TmdbVideoMetadataProvider
    implements VideoMetadataProvider, VideoMetadataExtrasProvider {
  TmdbVideoMetadataProvider({
    String apiKey = '',
    String accessToken = '',
    http.Client? client,
    VideoMetadataHttpClient? transport,
    this.baseUrl = 'https://api.themoviedb.org/3',
    this.imageBaseUrl = 'https://image.tmdb.org/t/p/original',
    this.language = 'zh-CN',
  })  : assert(client == null || transport == null),
        _apiKey = apiKey.trim(),
        _accessToken = accessToken.trim(),
        _transport = transport ?? VideoMetadataHttpClient(client: client),
        _ownsTransport = transport == null;

  final String _apiKey;
  final String _accessToken;
  final VideoMetadataHttpClient _transport;
  final bool _ownsTransport;
  final String baseUrl;
  final String imageBaseUrl;
  final String language;

  @override
  VideoMetadataProviderKind get providerKind => VideoMetadataProviderKind.tmdb;

  @override
  bool get isAvailable => _apiKey.isNotEmpty || _accessToken.isNotEmpty;

  @override
  Future<List<VideoMetadataWork>> search(
    VideoMetadataSearchRequest request,
  ) async {
    _requireAvailable();
    // TMDB 的搜索会命中原名、译名和别名，但响应 title/name 只投影成请求的
    // language。严格匹配若只看 zh-CN 响应，会把通过英文别名命中的
    // `Himouto! Umaru-chan` 错误拒绝，因为返回行只剩中文名和日文原名。
    // 在同一 TMDB 主源内合并常用动画元数据语言的展示名，仍由上层 exact gate
    // 决定是否自动应用；这不是跨 provider fallback，也不放宽成模糊匹配。
    final List<String> languages = <String>[
      language,
      'en-US',
      'ja-JP',
      'zh-CN',
    ].fold<List<String>>(<String>[], (List<String> values, String value) {
      if (value.trim().isNotEmpty && !values.contains(value)) values.add(value);
      return values;
    });
    final Map<String, VideoMetadataWork> merged = <String, VideoMetadataWork>{};
    for (int languageIndex = 0;
        languageIndex < languages.length;
        languageIndex++) {
      final String responseLanguage = languages[languageIndex];
      final Map<String, Object?> payload;
      try {
        payload = await _getObject(
          '/search/multi',
          operation: 'TMDB search ($responseLanguage)',
          query: <String, String>{
            'query': request.title,
            if (request.year != null) 'year': '${request.year}',
            'page': '1',
            'language': responseLanguage,
          },
          cacheKey: 'tmdb:search:${request.mediaKind.name}:'
              '${request.title}:${request.year}:$responseLanguage',
        );
      } on Object {
        // 配置语言是主请求；它失败时维持原有失败语义。补充语言只负责别名，
        // 单个补充请求失败不得抹掉已经取得的主响应。
        if (languageIndex == 0) rethrow;
        continue;
      }
      for (final Object? node in metadataList(payload['results'])) {
        final Map<String, Object?>? item = metadataObject(node);
        if (item == null) continue;
        final VideoMetadataWork? work = _mapSearchWork(item);
        if (work == null || work.kind != request.mediaKind) continue;
        final String? id = work.ids
            .where((VideoMetadataId value) => value.type == 'tmdb')
            .map((VideoMetadataId value) => value.value)
            .firstOrNull;
        if (id == null) continue;
        final String key = '${work.kind.name}:$id';
        merged.update(
          key,
          (VideoMetadataWork existing) =>
              _mergeLocalizedSearchWork(existing, work),
          ifAbsent: () => work,
        );
      }
    }
    final String normalizedQuery = TitleNormalizer.normalize(request.title);
    final List<VideoMetadataWork> exact = <VideoMetadataWork>[];
    final List<VideoMetadataWork> remaining = <VideoMetadataWork>[];
    for (final VideoMetadataWork work in merged.values) {
      final bool matches = <String?>[
        work.title,
        work.originalTitle,
        ...work.aliases,
      ].any((String? value) =>
          value != null && TitleNormalizer.normalize(value) == normalizedQuery);
      (matches ? exact : remaining).add(work);
    }
    return <VideoMetadataWork>[...exact, ...remaining]
        .take(request.limit)
        .toList(growable: false);
  }

  VideoMetadataWork _mergeLocalizedSearchWork(
    VideoMetadataWork primary,
    VideoMetadataWork localized,
  ) {
    final List<String> aliases = metadataUniqueStrings(<String?>[
      ...primary.aliases,
      localized.title,
      localized.originalTitle,
      ...localized.aliases,
    ]).where((String value) => value != primary.title).toList();
    return primary.copyWith(aliases: aliases);
  }

  @override
  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup) async {
    _validateLookup(lookup);
    final String path = lookup.mediaKind == VideoMetadataMediaKind.tv
        ? '/tv/${lookup.externalId}'
        : '/movie/${lookup.externalId}';
    final Map<String, Object?>? payload = await _getObjectOrNull(
      path,
      operation: 'TMDB ${lookup.mediaKind.name} details',
      query: const <String, String>{
        'append_to_response':
            'external_ids,credits,images,content_ratings,release_dates,keywords',
        'include_image_language': 'zh,en,null',
      },
      cacheKey: 'tmdb:work:${lookup.mediaKind.name}:${lookup.externalId}',
    );
    if (payload == null) return null;
    final VideoMetadataWork work = _mapDetailedWork(payload, lookup.mediaKind);
    return lookup.episodeGroupId == null
        ? work
        : work.copyWith(episodeGroupId: lookup.episodeGroupId);
  }

  @override
  Future<List<VideoMetadataSeason>> fetchSeasons(
    VideoMetadataLookup lookup,
  ) async {
    _validateLookup(lookup);
    if (lookup.mediaKind != VideoMetadataMediaKind.tv) {
      return const <VideoMetadataSeason>[];
    }
    final VideoMetadataWork? work = await fetchWork(lookup);
    if (work == null) return const <VideoMetadataSeason>[];

    final List<VideoMetadataSeason> seasons = <VideoMetadataSeason>[];
    for (final VideoMetadataSeason summary in work.seasons) {
      final Map<String, Object?>? payload = await _getObjectOrNull(
        '/tv/${lookup.externalId}/season/${summary.seasonNumber}',
        operation: 'TMDB season details',
        query: const <String, String>{
          'append_to_response': 'aggregate_credits,images,external_ids',
          'include_image_language': 'zh,en,null',
        },
        cacheKey: 'tmdb:season:${lookup.externalId}:${summary.seasonNumber}',
      );
      if (payload != null) {
        seasons.add(_mapSeason(payload, summary.seasonNumber));
      } else {
        seasons.add(summary);
      }
    }
    return seasons;
  }

  @override
  Future<List<VideoMetadataEpisode>> fetchEpisodes(
    VideoMetadataLookup lookup, {
    required int seasonNumber,
  }) async {
    _validateLookup(lookup);
    if (lookup.mediaKind != VideoMetadataMediaKind.tv) {
      return const <VideoMetadataEpisode>[];
    }
    final Map<String, Object?>? payload = await _getObjectOrNull(
      '/tv/${lookup.externalId}/season/$seasonNumber',
      operation: 'TMDB season episodes',
      query: const <String, String>{
        'append_to_response': 'aggregate_credits,images,external_ids',
        'include_image_language': 'zh,en,null',
      },
      cacheKey: 'tmdb:season:${lookup.externalId}:$seasonNumber',
    );
    if (payload == null) return const <VideoMetadataEpisode>[];
    return _mapEpisodes(payload, seasonNumber);
  }

  @override
  Future<List<VideoMetadataExtra>> fetchExtras(
    VideoMetadataLookup lookup,
  ) async {
    _validateLookup(lookup);
    final String media =
        lookup.mediaKind == VideoMetadataMediaKind.tv ? 'tv' : 'movie';
    final Map<String, Object?>? payload = await _getObjectOrNull(
      '/$media/${lookup.externalId}/videos',
      operation: 'TMDB videos',
      cacheKey: 'tmdb:videos:$media:${lookup.externalId}',
    );
    final List<VideoMetadataExtra> result = <VideoMetadataExtra>[];
    for (final Object? node in metadataList(payload?['results'])) {
      final Map<String, Object?>? item = metadataObject(node);
      final String? key = metadataString(item?['key']);
      final String? title = metadataString(item?['name']);
      final String? site = metadataString(item?['site']);
      if (key == null || title == null || site == null) continue;
      final String normalizedSite = site.toLowerCase();
      final String? url = switch (normalizedSite) {
        'youtube' => 'https://www.youtube.com/watch?v=$key',
        'vimeo' => 'https://vimeo.com/$key',
        _ => null,
      };
      if (url == null) continue;
      final String type = metadataString(item?['type'])?.toLowerCase() ?? '';
      final VideoMetadataExtraKind kind = switch (type) {
        'trailer' => VideoMetadataExtraKind.trailer,
        'teaser' => VideoMetadataExtraKind.teaser,
        'clip' => VideoMetadataExtraKind.clip,
        'featurette' => VideoMetadataExtraKind.featurette,
        'behind the scenes' => VideoMetadataExtraKind.behindTheScenes,
        _ => VideoMetadataExtraKind.extra,
      };
      result.add(VideoMetadataExtra(
        kind: kind,
        title: title,
        provider: providerKind,
        providerVideoId: key,
        site: site,
        remoteUrl: url,
        thumbnailUrl: normalizedSite == 'youtube'
            ? 'https://i.ytimg.com/vi/$key/hqdefault.jpg'
            : null,
        official: item?['official'] == true,
        language: metadataString(item?['iso_639_1']),
        publishedAt: metadataString(item?['published_at']),
        order: result.length,
      ));
    }
    return result;
  }

  /// 拉取单集完整详情。来源协调器可只对本地实际存在的集调用，避免整季逐集放大
  /// 请求；相比季列表响应，本端点额外提供 external_ids、credits 与 still 图组。
  Future<VideoMetadataEpisode?> fetchEpisode(
    VideoMetadataLookup lookup, {
    required int seasonNumber,
    required int episodeNumber,
  }) async {
    _validateLookup(lookup);
    if (lookup.mediaKind != VideoMetadataMediaKind.tv) return null;
    final Map<String, Object?>? payload = await _getObjectOrNull(
      '/tv/${lookup.externalId}/season/$seasonNumber/episode/$episodeNumber',
      operation: 'TMDB episode details',
      query: const <String, String>{
        'append_to_response': 'external_ids,credits,images',
        'include_image_language': 'zh,en,null',
      },
      cacheKey:
          'tmdb:episode:${lookup.externalId}:$seasonNumber:$episodeNumber',
    );
    return payload == null
        ? null
        : _mapEpisode(payload, seasonNumber, episodeNumber);
  }

  VideoMetadataWork? _mapSearchWork(Map<String, Object?> item) {
    final String? type = metadataString(item['media_type']);
    final VideoMetadataMediaKind? kind = switch (type) {
      'tv' => VideoMetadataMediaKind.tv,
      'movie' => VideoMetadataMediaKind.movie,
      _ => null,
    };
    final String? id = metadataInt(item['id'])?.toString();
    if (kind == null || id == null) return null;
    final String? title = kind == VideoMetadataMediaKind.tv
        ? metadataString(item['name'])
        : metadataString(item['title']);
    if (title == null) return null;
    final String? originalTitle = kind == VideoMetadataMediaKind.tv
        ? metadataString(item['original_name'])
        : metadataString(item['original_title']);
    final String? premiered = kind == VideoMetadataMediaKind.tv
        ? metadataString(item['first_air_date'])
        : metadataString(item['release_date']);
    return VideoMetadataWork(
      provider: providerKind,
      kind: kind,
      title: title,
      originalTitle: originalTitle == title ? null : originalTitle,
      tagline: metadataString(item['tagline']),
      aliases: metadataUniqueStrings(<String?>[originalTitle])
          .where((String alias) => alias != title)
          .toList(),
      year: metadataYear(premiered),
      premiered: premiered,
      endDate: kind == VideoMetadataMediaKind.tv
          ? metadataString(item['last_air_date'])
          : null,
      plot: metadataString(item['overview']),
      rating: _positiveDouble(item['vote_average']),
      ratingVotes: _positiveInt(item['vote_count']),
      ids: <VideoMetadataId>[
        VideoMetadataId(type: 'tmdb', value: id, isDefault: true),
      ],
      images: _mapPrimaryImages(item),
      rawPayload: item,
    );
  }

  VideoMetadataWork _mapDetailedWork(
    Map<String, Object?> item,
    VideoMetadataMediaKind kind,
  ) {
    final String id = '${metadataInt(item['id']) ?? item['id']}';
    final String title = (kind == VideoMetadataMediaKind.tv
            ? metadataString(item['name'])
            : metadataString(item['title'])) ??
        id;
    final String? originalTitle = kind == VideoMetadataMediaKind.tv
        ? metadataString(item['original_name'])
        : metadataString(item['original_title']);
    final String? premiered = kind == VideoMetadataMediaKind.tv
        ? metadataString(item['first_air_date'])
        : metadataString(item['release_date']);
    final Map<String, Object?> external =
        metadataObject(item['external_ids']) ?? const <String, Object?>{};
    final String? imdbId =
        metadataString(item['imdb_id']) ?? metadataString(external['imdb_id']);
    final List<VideoMetadataId> ids = <VideoMetadataId>[
      VideoMetadataId(type: 'tmdb', value: id, isDefault: imdbId == null),
      if (imdbId != null)
        VideoMetadataId(type: 'imdb', value: imdbId, isDefault: true),
      if (metadataInt(external['tvdb_id']) case final int tvdbId)
        VideoMetadataId(type: 'tvdb', value: '$tvdbId'),
    ];
    final List<VideoMetadataSeason> seasons = <VideoMetadataSeason>[];
    for (final Object? node in metadataList(item['seasons'])) {
      final Map<String, Object?>? season = metadataObject(node);
      final int? number = metadataInt(season?['season_number']);
      if (season == null || number == null) continue;
      final String? airDate = metadataString(season['air_date']);
      seasons.add(VideoMetadataSeason(
        seasonNumber: number,
        title: metadataString(season['name']) ?? 'Season $number',
        airDate: airDate,
        year: metadataYear(airDate),
        episodeCount: _positiveInt(season['episode_count']),
        ids: <VideoMetadataId>[
          if (metadataInt(season['id']) case final int seasonId)
            VideoMetadataId(type: 'tmdb', value: '$seasonId'),
        ],
        images: <VideoMetadataImage>[
          if (metadataString(season['poster_path']) case final String path)
            VideoMetadataImage(
              kind: VideoMetadataImageKind.cover,
              url: '$imageBaseUrl$path',
              provider: providerKind,
              seasonNumber: number,
            ),
        ],
      ));
    }
    final List<int> runtimes = <int>[
      for (final Object? value in metadataList(item['episode_run_time']))
        if (_positiveInt(value) case final int runtime) runtime,
    ];
    return VideoMetadataWork(
      provider: providerKind,
      kind: kind,
      title: title,
      originalTitle: originalTitle == title ? null : originalTitle,
      aliases: metadataUniqueStrings(<String?>[originalTitle])
          .where((String alias) => alias != title)
          .toList(),
      year: metadataYear(premiered),
      premiered: premiered,
      plot: metadataString(item['overview']),
      rating: _positiveDouble(item['vote_average']),
      ratingVotes: _positiveInt(item['vote_count']),
      runtimeMinutes: kind == VideoMetadataMediaKind.movie
          ? _positiveInt(item['runtime'])
          : (runtimes.isEmpty ? null : runtimes.first),
      contentRating: _contentRating(item, kind),
      status: metadataString(item['status']),
      originalLanguage: metadataString(item['original_language']),
      homepage: metadataString(item['homepage']),
      seasonCount: kind == VideoMetadataMediaKind.tv
          ? _positiveInt(item['number_of_seasons'])
          : null,
      episodeCount: kind == VideoMetadataMediaKind.tv
          ? _positiveInt(item['number_of_episodes'])
          : null,
      genres: _names(item['genres']),
      studios: <String>{
        ..._names(item['production_companies']),
        ..._names(item['networks']),
      }.toList(),
      countries: <String>{
        ..._names(item['production_countries']),
        for (final Object? country in metadataList(item['origin_country']))
          if (metadataString(country) case final String value) value,
      }.toList(),
      keywords: _keywordNames(item['keywords']),
      ids: ids,
      credits: _mapCredits(item['credits']),
      images: _dedupeImages(<VideoMetadataImage>[
        ..._mapPrimaryImages(item),
        ..._mapImageSet(item['images']),
      ]),
      seasons: seasons,
      rawPayload: item,
    );
  }

  VideoMetadataSeason _mapSeason(
    Map<String, Object?> item,
    int fallbackSeasonNumber,
  ) {
    final int seasonNumber =
        metadataInt(item['season_number']) ?? fallbackSeasonNumber;
    final String? airDate = metadataString(item['air_date']);
    final List<VideoMetadataEpisode> episodes =
        _mapEpisodes(item, seasonNumber);
    return VideoMetadataSeason(
      seasonNumber: seasonNumber,
      title: metadataString(item['name']) ?? 'Season $seasonNumber',
      plot: metadataString(item['overview']),
      airDate: airDate,
      year: metadataYear(airDate),
      episodeCount: episodes.length,
      rating: _positiveDouble(item['vote_average']),
      ids: <VideoMetadataId>[
        if (metadataInt(item['id']) case final int id)
          VideoMetadataId(type: 'tmdb', value: '$id'),
        ..._externalIds(item['external_ids']),
      ],
      images: _dedupeImages(<VideoMetadataImage>[
        ..._mapSeasonPrimaryImages(item, seasonNumber),
        ..._mapImageSet(item['images'], seasonNumber: seasonNumber),
      ]),
      episodes: episodes,
    );
  }

  List<VideoMetadataEpisode> _mapEpisodes(
    Map<String, Object?> season,
    int fallbackSeasonNumber,
  ) {
    final List<VideoMetadataEpisode> episodes = <VideoMetadataEpisode>[];
    for (final Object? node in metadataList(season['episodes'])) {
      final Map<String, Object?>? item = metadataObject(node);
      final int? episodeNumber = metadataInt(item?['episode_number']);
      if (item == null || episodeNumber == null) continue;
      final int seasonNumber =
          metadataInt(item['season_number']) ?? fallbackSeasonNumber;
      episodes.add(_mapEpisode(item, seasonNumber, episodeNumber));
    }
    episodes.sort((VideoMetadataEpisode a, VideoMetadataEpisode b) =>
        a.episodeNumber.compareTo(b.episodeNumber));
    return episodes;
  }

  VideoMetadataEpisode _mapEpisode(
    Map<String, Object?> item,
    int fallbackSeasonNumber,
    int fallbackEpisodeNumber,
  ) {
    final int seasonNumber =
        metadataInt(item['season_number']) ?? fallbackSeasonNumber;
    final int episodeNumber =
        metadataInt(item['episode_number']) ?? fallbackEpisodeNumber;
    final String? airDate = metadataString(item['air_date']);
    final List<VideoMetadataImage> stills = <VideoMetadataImage>[
      if (metadataString(item['still_path']) case final String path)
        VideoMetadataImage(
          kind: VideoMetadataImageKind.thumb,
          url: '$imageBaseUrl$path',
          provider: providerKind,
          voteAverage: metadataDouble(item['vote_average']),
          voteCount: metadataInt(item['vote_count']),
          seasonNumber: seasonNumber,
          episodeNumber: episodeNumber,
        ),
      ..._mapImageNodes(
        metadataObject(item['images'])?['stills'],
        VideoMetadataImageKind.thumb,
        seasonNumber: seasonNumber,
        episodeNumber: episodeNumber,
      ),
    ];
    return VideoMetadataEpisode(
      seasonNumber: seasonNumber,
      episodeNumber: episodeNumber,
      // Empty means the provider did not return a real title. The NFO builder
      // omits empty fields instead of inventing an episode name.
      title: metadataString(item['name']) ?? '',
      plot: metadataString(item['overview']),
      airDate: airDate,
      year: metadataYear(airDate),
      rating: _positiveDouble(item['vote_average']),
      ratingVotes: _positiveInt(item['vote_count']),
      runtimeMinutes: _positiveInt(item['runtime']),
      ids: <VideoMetadataId>[
        if (metadataInt(item['id']) case final int id)
          VideoMetadataId(type: 'tmdb', value: '$id', isDefault: true),
        ..._externalIds(item['external_ids']),
      ],
      credits: <VideoMetadataCredit>[
        ..._mapCrew(metadataList(item['crew'])),
        ..._mapCast(metadataList(item['guest_stars']), guest: true),
      ],
      images: _dedupeImages(stills),
    );
  }

  List<VideoMetadataCredit> _mapCredits(Object? value) {
    final Map<String, Object?> credits =
        metadataObject(value) ?? const <String, Object?>{};
    return <VideoMetadataCredit>[
      ..._mapCrew(metadataList(credits['crew'])),
      ..._mapCast(metadataList(credits['cast'])),
    ];
  }

  List<VideoMetadataCredit> _mapCrew(List<Object?> nodes) {
    final List<VideoMetadataCredit> credits = <VideoMetadataCredit>[];
    for (final Object? node in nodes) {
      final Map<String, Object?>? item = metadataObject(node);
      final String? name = metadataString(item?['name']);
      if (item == null || name == null) continue;
      final String job = metadataString(item['job'])?.toLowerCase() ?? '';
      final String department =
          metadataString(item['department'])?.toLowerCase() ?? '';
      final VideoMetadataCreditKind? kind = job.contains('director')
          ? VideoMetadataCreditKind.director
          : (job.contains('writer') ||
                  job.contains('screenplay') ||
                  department == 'writing')
              ? VideoMetadataCreditKind.writer
              : null;
      if (kind == null) continue;
      credits.add(VideoMetadataCredit(
        kind: kind,
        person: _mapPerson(item, name),
        department: metadataString(item['department']),
        job: metadataString(item['job']),
        providerCreditId: metadataString(item['credit_id']),
        order: metadataInt(item['order']) ?? credits.length,
      ));
    }
    return credits;
  }

  List<VideoMetadataCredit> _mapCast(
    List<Object?> nodes, {
    bool guest = false,
  }) {
    final List<VideoMetadataCredit> credits = <VideoMetadataCredit>[];
    for (final Object? node in nodes) {
      final Map<String, Object?>? item = metadataObject(node);
      final String? name = metadataString(item?['name']);
      if (item == null || name == null) continue;
      final String? characterName = metadataString(item['character']);
      credits.add(VideoMetadataCredit(
        kind: guest
            ? VideoMetadataCreditKind.guest
            : VideoMetadataCreditKind.actor,
        person: _mapPerson(item, name),
        character: characterName == null
            ? null
            : VideoMetadataCharacter(name: characterName),
        roleName: characterName,
        providerCreditId: metadataString(item['credit_id']),
        order: metadataInt(item['order']) ?? credits.length,
      ));
    }
    return credits;
  }

  VideoMetadataPerson _mapPerson(Map<String, Object?> item, String name) {
    final String? id = metadataInt(item['id'])?.toString();
    final String? path = metadataString(item['profile_path']);
    return VideoMetadataPerson(
      id: id,
      name: name,
      originalName: metadataString(item['original_name']),
      gender: metadataInt(item['gender']),
      profileUrl: path == null ? null : '$imageBaseUrl$path',
      ids: <VideoMetadataId>[
        if (id != null) VideoMetadataId(type: 'tmdb', value: id),
      ],
    );
  }

  List<VideoMetadataImage> _mapPrimaryImages(Map<String, Object?> item) =>
      <VideoMetadataImage>[
        if (metadataString(item['poster_path']) case final String path)
          VideoMetadataImage(
            kind: VideoMetadataImageKind.cover,
            url: '$imageBaseUrl$path',
            provider: providerKind,
          ),
        if (metadataString(item['backdrop_path']) case final String path)
          VideoMetadataImage(
            kind: VideoMetadataImageKind.backdrop,
            url: '$imageBaseUrl$path',
            provider: providerKind,
          ),
      ];

  List<VideoMetadataImage> _mapSeasonPrimaryImages(
    Map<String, Object?> item,
    int seasonNumber,
  ) =>
      <VideoMetadataImage>[
        if (metadataString(item['poster_path']) case final String path)
          VideoMetadataImage(
            kind: VideoMetadataImageKind.cover,
            url: '$imageBaseUrl$path',
            provider: providerKind,
            seasonNumber: seasonNumber,
          ),
      ];

  List<VideoMetadataImage> _mapImageSet(
    Object? value, {
    int? seasonNumber,
  }) {
    final Map<String, Object?> images =
        metadataObject(value) ?? const <String, Object?>{};
    final List<VideoMetadataImage> result = <VideoMetadataImage>[
      ..._mapImageNodes(
        images['posters'],
        VideoMetadataImageKind.cover,
        seasonNumber: seasonNumber,
      ),
      ..._mapImageNodes(
        images['backdrops'],
        VideoMetadataImageKind.backdrop,
        seasonNumber: seasonNumber,
      ),
      ..._mapImageNodes(
        images['logos'],
        VideoMetadataImageKind.logo,
        seasonNumber: seasonNumber,
        skipSvg: true,
      ),
    ];
    result.sort(_compareTmdbImages);
    return result;
  }

  List<VideoMetadataImage> _mapImageNodes(
    Object? value,
    VideoMetadataImageKind kind, {
    int? seasonNumber,
    int? episodeNumber,
    bool skipSvg = false,
  }) {
    final List<VideoMetadataImage> result = <VideoMetadataImage>[];
    for (final Object? node in metadataList(value)) {
      final Map<String, Object?>? item = metadataObject(node);
      final String? path = metadataString(item?['file_path']);
      if (item == null || path == null) continue;
      if (skipSvg && path.toLowerCase().endsWith('.svg')) continue;
      result.add(VideoMetadataImage(
        kind: kind,
        url: '$imageBaseUrl$path',
        provider: providerKind,
        language: metadataString(item['iso_639_1']),
        voteAverage: metadataDouble(item['vote_average']),
        voteCount: metadataInt(item['vote_count']),
        seasonNumber: seasonNumber,
        episodeNumber: episodeNumber,
      ));
    }
    return result;
  }

  List<VideoMetadataId> _externalIds(Object? value) {
    final Map<String, Object?> ids =
        metadataObject(value) ?? const <String, Object?>{};
    return <VideoMetadataId>[
      if (metadataString(ids['imdb_id']) case final String id)
        VideoMetadataId(type: 'imdb', value: id),
      if (metadataInt(ids['tvdb_id']) case final int id)
        VideoMetadataId(type: 'tvdb', value: '$id'),
    ];
  }

  List<VideoMetadataImage> _dedupeImages(
    Iterable<VideoMetadataImage> images,
  ) {
    final Map<String, VideoMetadataImage> result =
        <String, VideoMetadataImage>{};
    for (final VideoMetadataImage image in images) {
      final String key = <Object?>[
        image.kind.name,
        image.seasonNumber,
        image.episodeNumber,
        image.url,
      ].join(':');
      result[key] = image;
    }
    return result.values.toList();
  }

  int _compareTmdbImages(VideoMetadataImage a, VideoMetadataImage b) {
    final int rating = (b.voteAverage ?? -1).compareTo(a.voteAverage ?? -1);
    if (rating != 0) return rating;
    final int votes = (b.voteCount ?? -1).compareTo(a.voteCount ?? -1);
    if (votes != 0) return votes;
    return a.url.compareTo(b.url);
  }

  List<String> _names(Object? value) => <String>[
        for (final Object? node in metadataList(value))
          if (metadataObject(node) case final Map<String, Object?> item)
            if (metadataString(item['name']) case final String name) name,
      ];

  List<String> _keywordNames(Object? value) {
    final Map<String, Object?>? node = metadataObject(value);
    return _names(node?['results'] ?? node?['keywords']);
  }

  String? _contentRating(
    Map<String, Object?> item,
    VideoMetadataMediaKind kind,
  ) {
    if (kind == VideoMetadataMediaKind.tv) {
      final Map<String, Object?>? ratings =
          metadataObject(item['content_ratings']);
      return _pickCertification(metadataList(ratings?['results']));
    }
    final Map<String, Object?>? dates = metadataObject(item['release_dates']);
    for (final String country in const <String>['CN', 'US', 'JP']) {
      for (final Object? node in metadataList(dates?['results'])) {
        final Map<String, Object?>? group = metadataObject(node);
        if (metadataString(group?['iso_3166_1']) != country) continue;
        for (final Object? release in metadataList(group?['release_dates'])) {
          final String? rating =
              metadataString(metadataObject(release)?['certification']);
          if (rating != null) return rating;
        }
      }
    }
    return null;
  }

  String? _pickCertification(List<Object?> values) {
    for (final String country in const <String>['CN', 'US', 'JP']) {
      for (final Object? node in values) {
        final Map<String, Object?>? item = metadataObject(node);
        if (metadataString(item?['iso_3166_1']) != country) continue;
        final String? rating = metadataString(item?['rating']);
        if (rating != null) return rating;
      }
    }
    return null;
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
      _uri(path, query),
      headers: _headers,
      operation: operation,
      cacheKey: cacheKey,
    );
    return response.decodeJsonObject(operation: operation);
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

  Uri _uri(String path, Map<String, String> query) {
    final Map<String, String> parameters = <String, String>{
      'language': language,
      ...query,
      if (_apiKey.isNotEmpty) 'api_key': _apiKey,
    };
    return Uri.parse('$baseUrl$path').replace(queryParameters: parameters);
  }

  Map<String, String> get _headers => <String, String>{
        'Accept': 'application/json',
        if (_accessToken.isNotEmpty) 'Authorization': 'Bearer $_accessToken',
      };

  void _requireAvailable() {
    if (!isAvailable) {
      throw const VideoMetadataProviderUnavailable(
        VideoMetadataProviderKind.tmdb,
        'TMDB API key or read access token is not configured',
      );
    }
  }

  void _validateLookup(VideoMetadataLookup lookup) {
    _requireAvailable();
    if (lookup.provider != providerKind || lookup.externalId.trim().isEmpty) {
      throw ArgumentError.value(lookup, 'lookup', 'Not a TMDB lookup');
    }
  }

  @override
  void close() {
    if (_ownsTransport) _transport.close();
  }
}
