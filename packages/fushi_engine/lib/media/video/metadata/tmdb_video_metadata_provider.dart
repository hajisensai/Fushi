library;

import 'package:fushi_engine/media/video/metadata/video_metadata_json.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_languages.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_merge.dart'
    show stripVoiceRoleSuffix;
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_transport.dart';
import 'package:fushi_engine/media/video/scraper/title_normalizer.dart';
import 'package:http/http.dart' as http;

/// TMDB changes API 能回看的最大跨度（Shoko `IncrementalChangesWindowDays` 同为
/// 14 天）；更早的变动只能整部重拉。
const Duration kTmdbChangesWindow = Duration(days: 14);

/// 单次 `/tv/changes` 请求允许的最大 start/end 跨度（TMDB 限 14 天）。
const Duration kTmdbChangesRequestWindow = Duration(days: 13);

class TmdbVideoMetadataProvider
    implements
        VideoMetadataProvider,
        VideoMetadataExtrasProvider,
        VideoMetadataEpisodeGroupProvider,
        VideoMetadataEpisodeAliasProvider {
  TmdbVideoMetadataProvider({
    String apiKey = '',
    String accessToken = '',
    http.Client? client,
    VideoMetadataHttpClient? transport,
    this.baseUrl = 'https://api.themoviedb.org/3',
    this.imageBaseUrl = 'https://image.tmdb.org/t/p/original',
    this.language = kFallbackVideoMetadataLocale,
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

  /// 本 provider 实例的资料语言（BCP-47）。构造期固定：换语言要换实例，见
  /// `VideoSourceScrapeCoordinator._createRegistry`。
  final String language;

  /// 由 [language] 派生的语言参数（图片语言、搜索别名语言）。文字与图片必须
  /// 同源：此前 `language` 有接线而图片语言写死 zh，用户设了 ja 得到日文简介 +
  /// 中文海报。
  VideoMetadataLanguages get _languages => VideoMetadataLanguages(language);

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
    // language。严格匹配若只看单一语言的响应，会把通过英文别名命中的
    // `Himouto! Umaru-chan` 错误拒绝，因为返回行只剩本地化名和日文原名。
    // 在同一 TMDB 主源内合并常用动画元数据语言的展示名，仍由上层 exact gate
    // 决定是否自动应用；这不是跨 provider fallback，也不放宽成模糊匹配。
    //
    // 兜底语言只有 en-US / ja-JP 两个领域事实，不再无条件追加 zh-CN：那是让每个
    // 非中文用户每次搜索白搭一次请求。中文目录名照样能识别——resolver 的 exact
    // 门在详情阶段再判一次，详情 aliases 含全部语言的 translations。
    final List<String> languages = _languages.searchLocales;
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
            if (request.includeAdult) 'include_adult': 'true',
          },
          cacheKey: 'tmdb:search:${request.mediaKind.name}:'
              '${request.title}:${request.year}:$responseLanguage'
              '${request.includeAdult ? ':adult' : ''}',
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
      query: <String, String>{
        // 剧集额外带 aggregate_credits：`credits` 对剧只给常驻主演（一季十来
        // 人），全剧所有登场角色的配音要看跨季汇总——Shoko 是逐集 credits 再按
        // (人, 角色) 归并，aggregate_credits 就是同一语义的服务端版本（BUG-2612）。
        'append_to_response':
            'external_ids,credits,images,content_ratings,release_dates,keywords,'
                'alternative_titles,translations'
                '${lookup.mediaKind == VideoMetadataMediaKind.tv ? ',aggregate_credits' : ''}',
        'include_image_language': _languages.tmdbIncludeImageLanguage,
      },
      cacheKey: 'tmdb:work:${lookup.mediaKind.name}:${lookup.externalId}',
    );
    if (payload == null) return null;
    VideoMetadataWork work = _mapDetailedWork(payload, lookup.mediaKind);
    // Shoko 图片语言序里的 `Main` = 片子原语。请求端按资料语言过滤图片，原语
    // 不在其中时（zh-CN 用户看日本动画）再按原语补拉一次 images（独立缓存键、
    // 轻量），否则原语海报根本进不了候选池。
    final String? original =
        VideoMetadataLanguages.primarySubtagOf(work.originalLanguage);
    if (original != null &&
        !_languages.imageLanguages
            .any((String tag) => tag.toLowerCase() == original)) {
      final Map<String, Object?>? images = await _getObjectOrNull(
        '$path/images',
        operation: 'TMDB ${lookup.mediaKind.name} images ($original)',
        query: <String, String>{'include_image_language': original},
        cacheKey:
            'tmdb:images:${lookup.mediaKind.name}:${lookup.externalId}:$original',
      );
      if (images != null) {
        final Set<String> known =
            work.images.map((VideoMetadataImage i) => i.url).toSet();
        work = work.copyWith(images: <VideoMetadataImage>[
          ...work.images,
          for (final VideoMetadataImage image in _mapImageSet(images))
            if (known.add(image.url)) image,
        ]);
      }
    }
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
    if (lookup.episodeGroupId case final String groupId) {
      return _mapEpisodeGroupSeasons(
        await _episodeGroupDetails(groupId),
      );
    }
    final VideoMetadataWork? work = await fetchWork(lookup);
    if (work == null) return const <VideoMetadataSeason>[];

    final List<VideoMetadataSeason> seasons = <VideoMetadataSeason>[];
    for (final VideoMetadataSeason summary in work.seasons) {
      final Map<String, Object?>? payload = await _getObjectOrNull(
        '/tv/${lookup.externalId}/season/${summary.seasonNumber}',
        operation: 'TMDB season details',
        query: <String, String>{
          'append_to_response': 'aggregate_credits,images,external_ids',
          'include_image_language': _languages.tmdbIncludeImageLanguage,
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
    if (lookup.episodeGroupId case final String groupId) {
      final List<VideoMetadataSeason> seasons = _mapEpisodeGroupSeasons(
        await _episodeGroupDetails(groupId),
      );
      for (final VideoMetadataSeason season in seasons) {
        if (season.seasonNumber == seasonNumber) return season.episodes;
      }
      return const <VideoMetadataEpisode>[];
    }
    final Map<String, Object?>? payload = await _getObjectOrNull(
      '/tv/${lookup.externalId}/season/$seasonNumber',
      operation: 'TMDB season episodes',
      query: <String, String>{
        'append_to_response': 'aggregate_credits,images,external_ids',
        'include_image_language': _languages.tmdbIncludeImageLanguage,
      },
      cacheKey: 'tmdb:season:${lookup.externalId}:$seasonNumber',
    );
    if (payload == null) return const <VideoMetadataEpisode>[];
    return _mapEpisodes(payload, seasonNumber);
  }

  /// Shoko 集级匹配比的是 en-US + 剧原语集名；本仓常规 hydrate 只拉资料语言一种。
  /// 这里按季补另外两种（与资料语言同主子标签的跳过），轻量请求（不带
  /// `append_to_response`），各自独立缓存键。集群/ 404 → 空表，不抛。
  @override
  Future<Map<int, List<String>>> fetchEpisodeTitleAliases(
    VideoMetadataLookup lookup, {
    required int seasonNumber,
  }) async {
    _validateLookup(lookup);
    if (lookup.mediaKind != VideoMetadataMediaKind.tv) {
      return const <int, List<String>>{};
    }
    final String own = VideoMetadataLanguages(language).primarySubtag;
    final VideoMetadataWork? work = await fetchWork(lookup);
    final String? original = work?.originalLanguage?.trim().toLowerCase();
    final List<String> languages = <String>[
      if (own != 'en') 'en-US',
      if (original != null &&
          original.isNotEmpty &&
          original != 'en' &&
          original != own)
        original,
    ];
    if (lookup.episodeGroupId case final String groupId) {
      // 备选排序下的季是分组：别名仍只能按**默认**季拉（TMDB 的季端点没有
      // 分组维度），再按分组里每集自带的默认 (季, 集) 换回分组集号。
      final Map<int, (int, int)> defaultKeys = <int, (int, int)>{};
      for (final Object? node
          in metadataList((await _episodeGroupDetails(groupId))?['groups'])) {
        final Map<String, Object?>? group = metadataObject(node);
        if (group == null || metadataInt(group['order']) != seasonNumber) {
          continue;
        }
        int index = 0;
        for (final Object? episodeNode in metadataList(group['episodes'])) {
          final Map<String, Object?>? episode = metadataObject(episodeNode);
          final int groupEpisode = (metadataInt(episode?['order']) ?? index) + 1;
          index++;
          final int? season = metadataInt(episode?['season_number']);
          final int? number = metadataInt(episode?['episode_number']);
          if (season == null || number == null) continue;
          defaultKeys[groupEpisode] = (season, number);
        }
      }
      final Map<int, Map<int, List<String>>> bySeason =
          <int, Map<int, List<String>>>{};
      for (final int season
          in defaultKeys.values.map(((int, int) key) => key.$1).toSet()) {
        bySeason[season] =
            await _seasonTitleAliases(lookup.externalId, season, languages);
      }
      return <int, List<String>>{
        for (final MapEntry<int, (int, int)> entry in defaultKeys.entries)
          if (bySeason[entry.value.$1]?[entry.value.$2]
              case final List<String> names)
            entry.key: names,
      };
    }
    return _seasonTitleAliases(lookup.externalId, seasonNumber, languages);
  }

  /// 默认季编号下一季各集在 [languages] 里的集名（集号 → 集名列表）。
  Future<Map<int, List<String>>> _seasonTitleAliases(
    String showId,
    int seasonNumber,
    List<String> languages,
  ) async {
    final Map<int, List<String>> aliases = <int, List<String>>{};
    for (final String code in languages) {
      final Map<String, Object?>? payload = await _getObjectOrNull(
        '/tv/$showId/season/$seasonNumber',
        operation: 'TMDB season titles ($code)',
        query: <String, String>{'language': code},
        cacheKey: 'tmdb:season:$showId:$seasonNumber:$code',
      );
      if (payload == null) continue;
      for (final Object? node in metadataList(payload['episodes'])) {
        final Map<String, Object?>? item = metadataObject(node);
        final int? number = metadataInt(item?['episode_number']);
        final String? name = metadataString(item?['name']);
        if (number == null || name == null || name.trim().isEmpty) continue;
        (aliases[number] ??= <String>[]).add(name);
      }
    }
    return aliases;
  }

  @override
  Future<List<VideoMetadataEpisodeGroupSummary>> listEpisodeGroups(
    VideoMetadataLookup lookup,
  ) async {
    _validateLookup(lookup);
    if (lookup.mediaKind != VideoMetadataMediaKind.tv) {
      return const <VideoMetadataEpisodeGroupSummary>[];
    }
    final Map<String, Object?>? payload = await _getObjectOrNull(
      '/tv/${lookup.externalId}/episode_groups',
      operation: 'TMDB episode groups',
      cacheKey: 'tmdb:episode-groups:${lookup.externalId}',
    );
    return <VideoMetadataEpisodeGroupSummary>[
      for (final Object? node in metadataList(payload?['results']))
        if (metadataObject(node) case final Map<String, Object?> summary)
          if (metadataString(summary['id']) case final String id)
            VideoMetadataEpisodeGroupSummary(
              id: id,
              name: metadataString(summary['name']) ?? id,
              type: metadataInt(summary['type']) ?? 0,
              description: metadataString(summary['description']),
              groupCount: metadataInt(summary['group_count']),
              episodeCount: metadataInt(summary['episode_count']),
            ),
    ];
  }

  @override
  Future<VideoMetadataLookup?> resolveEpisodeGroup(
    VideoMetadataLookup lookup, {
    required int seasonNumber,
    int? episodeCount,
  }) async {
    _validateLookup(lookup);
    if (lookup.mediaKind != VideoMetadataMediaKind.tv) return null;
    if (lookup.episodeGroupId != null) {
      final List<VideoMetadataSeason> seasons = _mapEpisodeGroupSeasons(
        await _episodeGroupDetails(lookup.episodeGroupId!),
      );
      return seasons.any(
              (VideoMetadataSeason value) => value.seasonNumber == seasonNumber)
          ? lookup
          : null;
    }
    final Map<String, Object?>? payload = await _getObjectOrNull(
      '/tv/${lookup.externalId}/episode_groups',
      operation: 'TMDB episode groups',
      cacheKey: 'tmdb:episode-groups:${lookup.externalId}',
    );
    VideoMetadataLookup? fallback;
    for (final Object? node in metadataList(payload?['results'])) {
      final Map<String, Object?>? summary = metadataObject(node);
      final String? groupId = metadataString(summary?['id']);
      if (summary == null || groupId == null) continue;
      // type=6 是 TMDB 的“季”顺序。其它自定义顺序可能也能碰巧出现同号，
      // 但不能替代本地 Sxx 的季语义。
      if (metadataInt(summary['type']) != 6) continue;
      final List<VideoMetadataSeason> seasons = _mapEpisodeGroupSeasons(
        await _episodeGroupDetails(groupId),
      );
      VideoMetadataSeason? matching;
      for (final VideoMetadataSeason season in seasons) {
        if (season.seasonNumber == seasonNumber) {
          matching = season;
          break;
        }
      }
      if (matching == null) continue;
      final VideoMetadataLookup candidate = VideoMetadataLookup(
        provider: lookup.provider,
        externalId: lookup.externalId,
        mediaKind: lookup.mediaKind,
        episodeGroupId: groupId,
      );
      fallback ??= candidate;
      if (episodeCount != null &&
          episodeCount > 0 &&
          matching.episodeCount == episodeCount) {
        return candidate;
      }
    }
    return fallback;
  }

  Future<Map<String, Object?>?> _episodeGroupDetails(String groupId) =>
      _getObjectOrNull(
        '/tv/episode_group/$groupId',
        operation: 'TMDB episode group details',
        cacheKey: 'tmdb:episode-group:$groupId',
      );

  List<VideoMetadataSeason> _mapEpisodeGroupSeasons(
    Map<String, Object?>? payload,
  ) {
    final List<VideoMetadataSeason> seasons = <VideoMetadataSeason>[];
    for (final Object? node in metadataList(payload?['groups'])) {
      final Map<String, Object?>? group = metadataObject(node);
      final int? seasonNumber = metadataInt(group?['order']);
      if (group == null || seasonNumber == null) continue;
      final List<VideoMetadataEpisode> episodes = <VideoMetadataEpisode>[];
      for (final Object? episodeNode in metadataList(group['episodes'])) {
        final Map<String, Object?>? episode = metadataObject(episodeNode);
        if (episode == null) continue;
        final int episodeNumber =
            (metadataInt(episode['order']) ?? episodes.length) + 1;
        episodes.add(_mapEpisode(
          <String, Object?>{
            ...episode,
            'season_number': seasonNumber,
            'episode_number': episodeNumber,
          },
          seasonNumber,
          episodeNumber,
        ));
      }
      seasons.add(VideoMetadataSeason(
        seasonNumber: seasonNumber,
        title: metadataString(group['name']) ?? 'Season $seasonNumber',
        episodeCount: episodes.length,
        ids: <VideoMetadataId>[
          if (metadataString(group['id']) case final String id)
            VideoMetadataId(type: 'tmdb_episode_group', value: id),
        ],
        episodes: episodes,
      ));
    }
    seasons.sort((VideoMetadataSeason a, VideoMetadataSeason b) =>
        a.seasonNumber.compareTo(b.seasonNumber));
    return seasons;
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
    if (lookup.episodeGroupId != null) {
      final List<VideoMetadataEpisode> episodes = await fetchEpisodes(
        lookup,
        seasonNumber: seasonNumber,
      );
      for (final VideoMetadataEpisode episode in episodes) {
        if (episode.episodeNumber == episodeNumber) return episode;
      }
      return null;
    }
    final Map<String, Object?>? payload = await _getObjectOrNull(
      '/tv/${lookup.externalId}/season/$seasonNumber/episode/$episodeNumber',
      operation: 'TMDB episode details',
      query: <String, String>{
        'append_to_response': 'external_ids,credits,images',
        'include_image_language': _languages.tmdbIncludeImageLanguage,
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
      aliases: metadataUniqueStrings(<String?>[
        originalTitle,
        ..._alternativeTitles(item, kind),
      ]).where((String alias) => alias != title).toList(),
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
      aliases: metadataUniqueStrings(<String?>[
        originalTitle,
        ..._alternativeTitles(item, kind),
      ]).where((String alias) => alias != title).toList(),
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
      credits: _mapWorkCredits(item),
      images: _dedupeImages(<VideoMetadataImage>[
        ..._mapPrimaryImages(item),
        ..._mapImageSet(item['images']),
      ]),
      seasons: seasons,
      rawPayload: item,
    );
  }

  List<String> _alternativeTitles(
    Map<String, Object?> item,
    VideoMetadataMediaKind kind,
  ) {
    final Map<String, Object?> alternative =
        metadataObject(item['alternative_titles']) ?? const <String, Object?>{};
    final List<Object?> alternativeNodes = metadataList(
      kind == VideoMetadataMediaKind.tv
          ? alternative['results']
          : alternative['titles'],
    );
    final Map<String, Object?> translations =
        metadataObject(item['translations']) ?? const <String, Object?>{};
    return metadataUniqueStrings(<String?>[
      for (final Object? node in alternativeNodes)
        metadataString(metadataObject(node)?['title']),
      for (final Object? node in metadataList(translations['translations']))
        if (metadataObject(node)?['data'] case final Map<String, Object?> data)
          kind == VideoMetadataMediaKind.tv
              ? metadataString(data['name'])
              : metadataString(data['title']),
    ]);
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

  /// 作品级人物表：剧集有 `aggregate_credits` 就用它（全季汇总，一人多角色
  /// 展开成多条、一人多职位展开成多条，`credits` 只补它没有的），电影只有
  /// `credits`。
  List<VideoMetadataCredit> _mapWorkCredits(Map<String, Object?> item) {
    final Map<String, Object?>? aggregate =
        metadataObject(item['aggregate_credits']);
    if (aggregate == null) return _mapCredits(item['credits']);
    final List<VideoMetadataCredit> credits = <VideoMetadataCredit>[
      ..._mapCrew(_flattenAggregate(aggregate['crew'], 'jobs', 'job')),
      ..._mapCast(_flattenAggregate(aggregate['cast'], 'roles', 'character')),
    ];
    final Set<String> seen = <String>{
      for (final VideoMetadataCredit credit in credits) _creditIdentity(credit),
    };
    for (final VideoMetadataCredit credit in _mapCredits(item['credits'])) {
      if (seen.add(_creditIdentity(credit))) credits.add(credit);
    }
    return credits;
  }

  /// `aggregate_credits` 把同一人的多条角色 / 职位收在 `roles[]` / `jobs[]` 里，
  /// 展平成与 `credits` 同形的条目（每条带自己的 `credit_id`），复用同一套映射。
  List<Object?> _flattenAggregate(
    Object? nodes,
    String listKey,
    String valueKey,
  ) =>
      <Object?>[
        for (final Object? node in metadataList(nodes))
          if (metadataObject(node) case final Map<String, Object?> person)
            for (final Object? entryNode in metadataList(person[listKey]))
              if (metadataObject(entryNode)
                  case final Map<String, Object?> entry)
                <String, Object?>{
                  ...person,
                  valueKey: entry[valueKey],
                  'credit_id': entry['credit_id'],
                },
      ];

  String _creditIdentity(VideoMetadataCredit credit) => <String>[
        credit.kind.name,
        credit.person.id ?? credit.person.name.toLowerCase(),
        (credit.roleName ?? credit.job ?? '').toLowerCase(),
      ].join('|');

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
      final String? rawCharacter = metadataString(item['character']);
      // 「Frieren (voice)」= 配音角色：与 MAL / AniDB 的声优同类，才能在合并
      // 层认成同一条关系、在详情页落进「配音」轨道；后缀剥掉（同 Shoko）。
      final bool voice = rawCharacter != null &&
          stripVoiceRoleSuffix(rawCharacter) != rawCharacter.trim();
      final String? stripped =
          rawCharacter == null ? null : stripVoiceRoleSuffix(rawCharacter);
      final String? characterName =
          stripped == null || stripped.isEmpty ? null : stripped;
      credits.add(VideoMetadataCredit(
        kind: guest
            ? VideoMetadataCreditKind.guest
            : voice
                ? VideoMetadataCreditKind.voiceActor
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

  /// TMDB `/tv/changes`：[since] 之后有资料变动的剧 id（Shoko
  /// `TmdbMetadataService.GetShowChangedItemsAsync` 的增量刷新输入）。TMDB 只给
  /// 最近 14 天、每次最多 14 天窗口、结果分页；这里按天切窗口逐页拉齐。
  /// 调用方拿它和本地已识别作品的 TMDB id 求交集，只重刷真变过的剧。
  Future<Set<int>> changedTvShowIds({
    required DateTime since,
    DateTime? until,
    int maxPages = 50,
  }) async {
    final DateTime end = (until ?? DateTime.now()).toUtc();
    DateTime start = since.toUtc();
    if (end.difference(start) > kTmdbChangesWindow) {
      start = end.subtract(kTmdbChangesWindow);
    }
    final Set<int> ids = <int>{};
    int pagesLeft = maxPages;
    DateTime windowStart = start;
    while (!windowStart.isAfter(end) && pagesLeft > 0) {
      final DateTime windowEnd = windowStart.add(kTmdbChangesRequestWindow);
      final DateTime clampedEnd = windowEnd.isAfter(end) ? end : windowEnd;
      for (int page = 1; pagesLeft > 0; page++) {
        pagesLeft--;
        final Map<String, Object?> payload = await _getObject(
          '/tv/changes',
          operation: 'TMDB tv changes',
          query: <String, String>{
            'start_date': _dateOnly(windowStart),
            'end_date': _dateOnly(clampedEnd),
            'page': '$page',
          },
          cacheKey:
              'tmdb:tv-changes:${_dateOnly(windowStart)}:${_dateOnly(clampedEnd)}:$page',
        );
        for (final Object? node in metadataList(payload['results'])) {
          final int? id = metadataInt(metadataObject(node)?['id']);
          if (id != null && id > 0) ids.add(id);
        }
        final int totalPages = metadataInt(payload['total_pages']) ?? 1;
        if (page >= totalPages) break;
      }
      windowStart = clampedEnd.add(const Duration(days: 1));
    }
    return ids;
  }

  static String _dateOnly(DateTime date) {
    final DateTime utc = date.toUtc();
    return '${utc.year.toString().padLeft(4, '0')}-'
        '${utc.month.toString().padLeft(2, '0')}-'
        '${utc.day.toString().padLeft(2, '0')}';
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
