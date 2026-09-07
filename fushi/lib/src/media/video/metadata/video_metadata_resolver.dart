/// MAL 主源、TMDB 兜底的严格视频资料识别器。
library;

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_transport.dart';
import 'package:fushi/src/media/video/scraper/filename_parser.dart';
import 'package:fushi/src/media/video/scraper/title_normalizer.dart';

enum VideoMetadataResolutionStatus {
  matched,
  ambiguous,
  notFound,
  providerUnavailable,
}

enum VideoMetadataResolutionMethod { confirmed, explicitId, exactSearch }

class VideoMetadataResolveRequest {
  VideoMetadataResolveRequest({
    required this.selectedProvider,
    required this.mediaKind,
    required List<String> titleCandidates,
    this.year,
    this.seasonNumber,
    this.episodeCount,
    this.confirmedLookup,
    List<String> identityHints = const <String>[],
  })  : titleCandidates = List<String>.unmodifiable(titleCandidates),
        identityHints = List<String>.unmodifiable(identityHints);

  final VideoMetadataProviderKind selectedProvider;
  final VideoMetadataMediaKind mediaKind;

  /// 按文件名、父目录、祖父目录的优先级传入；resolver 依次尝试，不混池降权。
  final List<String> titleCandidates;
  final int? year;
  final int? seasonNumber;
  final int? episodeCount;
  final VideoMetadataLookup? confirmedLookup;
  final List<String> identityHints;
}

class VideoMetadataResolution {
  VideoMetadataResolution({
    required this.status,
    this.method,
    this.work,
    this.lookup,
    this.providerKind,
    List<VideoMetadataWork> candidates = const <VideoMetadataWork>[],
    this.reason,
  }) : candidates = List<VideoMetadataWork>.unmodifiable(candidates);

  final VideoMetadataResolutionStatus status;
  final VideoMetadataResolutionMethod? method;
  final VideoMetadataWork? work;
  final VideoMetadataLookup? lookup;

  /// 真正给出结果的来源；MAL 未命中或不可用时可能为 TMDB。
  final VideoMetadataProviderKind? providerKind;
  final List<VideoMetadataWork> candidates;
  final String? reason;
}

class VideoMetadataProviderRegistry {
  VideoMetadataProviderRegistry(Iterable<VideoMetadataProvider> providers)
      : _providers = <VideoMetadataProviderKind, VideoMetadataProvider>{
          for (final VideoMetadataProvider provider in providers)
            provider.providerKind: provider,
        };

  final Map<VideoMetadataProviderKind, VideoMetadataProvider> _providers;

  VideoMetadataProvider? provider(VideoMetadataProviderKind kind) =>
      _providers[kind];

  void close() {
    for (final VideoMetadataProvider provider in _providers.values) {
      provider.close();
    }
  }
}

class VideoMetadataResolver {
  const VideoMetadataResolver({required this.registry});

  final VideoMetadataProviderRegistry registry;

  Future<VideoMetadataResolution> resolve(
    VideoMetadataResolveRequest request,
  ) async {
    // A confirmed or explicit identity locks the source, including TMDB under
    // the MAL-first policy. Failed IDs must never turn into a title search.
    final VideoMetadataLookup? confirmed = request.confirmedLookup;
    if (confirmed != null && _acceptsIdentity(confirmed.provider, request)) {
      return _attempt(
        confirmed.provider,
        () => _resolveLookup(
          confirmed,
          request,
          VideoMetadataResolutionMethod.confirmed,
        ),
        lookup: confirmed,
        method: VideoMetadataResolutionMethod.confirmed,
      );
    }
    final List<VideoMetadataLookup> explicit = parseExplicitVideoMetadataIds(
      <String>[...request.identityHints, ...request.titleCandidates],
      fallbackMediaKind: request.mediaKind,
    );
    for (final VideoMetadataLookup lookup in explicit) {
      if (!_acceptsIdentity(lookup.provider, request)) continue;
      return _attempt(
        lookup.provider,
        () => _resolveLookup(
          lookup,
          request,
          VideoMetadataResolutionMethod.explicitId,
        ),
        lookup: lookup,
        method: VideoMetadataResolutionMethod.explicitId,
      );
    }

    final List<VideoMetadataProviderKind> chain = <VideoMetadataProviderKind>[
      request.selectedProvider,
      if (request.selectedProvider == VideoMetadataProviderKind.mal)
        VideoMetadataProviderKind.tmdb,
    ];
    final List<VideoMetadataResolution> failures = <VideoMetadataResolution>[];
    for (final VideoMetadataProviderKind kind in chain) {
      final VideoMetadataResolution resolved = await _attempt(kind, () async {
        final VideoMetadataProvider? provider = registry.provider(kind);
        if (provider == null || !provider.isAvailable) {
          return VideoMetadataResolution(
            status: VideoMetadataResolutionStatus.providerUnavailable,
            providerKind: kind,
            reason: '${kind.name} is not configured',
          );
        }
        return _searchWithProvider(provider, request);
      });
      if (resolved.status == VideoMetadataResolutionStatus.matched ||
          resolved.status == VideoMetadataResolutionStatus.ambiguous) {
        return resolved;
      }
      failures.add(resolved);
    }
    if (failures.length == 1) return failures.single;
    return VideoMetadataResolution(
      status: failures.any((VideoMetadataResolution result) =>
              result.status ==
              VideoMetadataResolutionStatus.providerUnavailable)
          ? VideoMetadataResolutionStatus.providerUnavailable
          : VideoMetadataResolutionStatus.notFound,
      providerKind: failures.last.providerKind,
      reason: failures
          .map((VideoMetadataResolution result) =>
              '${result.providerKind?.name}: ${result.reason}')
          .join('; '),
    );
  }

  bool _acceptsIdentity(
    VideoMetadataProviderKind provider,
    VideoMetadataResolveRequest request,
  ) =>
      provider == request.selectedProvider ||
      (request.selectedProvider == VideoMetadataProviderKind.mal &&
          (provider == VideoMetadataProviderKind.tmdb ||
              provider == VideoMetadataProviderKind.anidb));

  Future<VideoMetadataResolution> _attempt(
    VideoMetadataProviderKind kind,
    Future<VideoMetadataResolution> Function() operation, {
    VideoMetadataLookup? lookup,
    VideoMetadataResolutionMethod? method,
  }) async {
    try {
      return await operation();
    } catch (error) {
      if (error is! VideoMetadataProviderUnavailable &&
          error is! VideoMetadataNetworkException &&
          error is! TimeoutException &&
          error is! SocketException &&
          error is! HttpException &&
          error is! TlsException &&
          error is! http.ClientException) {
        rethrow;
      }
      return VideoMetadataResolution(
        status: VideoMetadataResolutionStatus.providerUnavailable,
        providerKind: kind,
        lookup: lookup,
        method: method,
        reason: error.toString(),
      );
    }
  }

  Future<VideoMetadataResolution> _searchWithProvider(
    VideoMetadataProvider provider,
    VideoMetadataResolveRequest request,
  ) async {
    final Map<String, VideoMetadataWork> reviewCandidates =
        <String, VideoMetadataWork>{};
    final Map<String, VideoMetadataWork?> fetchedDetails =
        <String, VideoMetadataWork?>{};
    for (final String rawTitle in request.titleCandidates) {
      final String title = rawTitle.trim();
      if (title.isEmpty) continue;
      final Set<String> normalizedTitles = _normalizedTitles(title);
      if (normalizedTitles.isEmpty) continue;
      final List<VideoMetadataWork> searched = await provider.search(
        VideoMetadataSearchRequest(
          title: title,
          mediaKind: request.mediaKind,
          year: request.year,
          seasonNumber: request.seasonNumber,
        ),
      );
      final Map<String, VideoMetadataWork> exact =
          <String, VideoMetadataWork>{};
      for (final VideoMetadataWork candidate in searched) {
        if (!_passesTypeYearGate(candidate, request)) continue;
        final VideoMetadataLookup? lookup =
            _lookupForWork(candidate, provider.providerKind);
        if (lookup == null) continue;
        final String lookupKey = '${lookup.provider.name}:${lookup.externalId}';
        final bool summaryMatches =
            _matchesNormalizedTitle(candidate, normalizedTitles);
        if (provider.providerKind == VideoMetadataProviderKind.anidb &&
            !summaryMatches) {
          // AniDB's local titles dump already carries the searchable title and
          // alias set. Do not turn one fuzzy catalog query into up to fifteen
          // rate-limited HTTP detail requests merely to discover that the
          // title still does not match. Keep the catalog row available for
          // explicit user confirmation; the selected identity is hydrated by
          // the coordinator after confirmation.
          reviewCandidates.putIfAbsent(lookupKey, () => candidate);
          continue;
        }
        VideoMetadataWork? details = fetchedDetails.containsKey(lookupKey)
            ? fetchedDetails[lookupKey]
            : await provider.fetchWork(lookup);
        if (details != null) {
          details = await _validatedDetails(provider, lookup, details, request);
        }
        fetchedDetails[lookupKey] = details;
        if (details == null) {
          continue;
        }
        final VideoMetadataWork validated = details;
        // 搜索摘要常常只带当前语言标题。真正详情会带原名/别名；MoviePilot
        // 同样用 title/original/alias/translation 做严格清洗后比较，因此必须在
        // detail gate 之后再做一次标题判定，不能在摘要阶段把罗马字别名丢掉。
        if (summaryMatches ||
            _matchesNormalizedTitle(validated, normalizedTitles)) {
          exact[lookupKey] = validated;
        } else {
          // 类型、年份、季号都已验证，只剩标题无法唯一确认。后台自动任务仍不
          // 静默应用；手工任务把 provider 排序后的候选交给用户确认并持久绑定。
          reviewCandidates.putIfAbsent(lookupKey, () => validated);
        }
      }
      if (exact.length == 1) {
        final VideoMetadataWork work = exact.values.single;
        return VideoMetadataResolution(
          status: VideoMetadataResolutionStatus.matched,
          method: VideoMetadataResolutionMethod.exactSearch,
          work: work,
          lookup: _lookupForWork(work, provider.providerKind),
          providerKind: provider.providerKind,
        );
      }
      if (exact.length > 1) {
        return VideoMetadataResolution(
          status: VideoMetadataResolutionStatus.ambiguous,
          method: VideoMetadataResolutionMethod.exactSearch,
          candidates: exact.values.toList(),
          providerKind: provider.providerKind,
          reason: 'More than one candidate passed the strict match gate',
        );
      }
    }
    if (reviewCandidates.isNotEmpty) {
      return VideoMetadataResolution(
        status: VideoMetadataResolutionStatus.ambiguous,
        method: VideoMetadataResolutionMethod.exactSearch,
        candidates: reviewCandidates.values.toList(growable: false),
        providerKind: provider.providerKind,
        reason: 'Provider candidates require manual title confirmation',
      );
    }
    return VideoMetadataResolution(
      status: VideoMetadataResolutionStatus.notFound,
      providerKind: provider.providerKind,
      reason: 'No candidate passed title, type, year and season gates',
    );
  }

  Future<VideoMetadataResolution> _resolveLookup(
    VideoMetadataLookup lookup,
    VideoMetadataResolveRequest request,
    VideoMetadataResolutionMethod method,
  ) async {
    final VideoMetadataProvider? provider = registry.provider(lookup.provider);
    if (provider == null || !provider.isAvailable) {
      return VideoMetadataResolution(
        status: VideoMetadataResolutionStatus.providerUnavailable,
        method: method,
        lookup: lookup,
        providerKind: lookup.provider,
        reason: '${lookup.provider.name} is not configured',
      );
    }
    VideoMetadataWork? work = await provider.fetchWork(lookup);
    if (work == null) {
      return VideoMetadataResolution(
        status: VideoMetadataResolutionStatus.notFound,
        method: method,
        lookup: lookup,
        providerKind: provider.providerKind,
        reason: 'Explicit identity does not exist',
      );
    }
    // A confirmed binding or an explicit provider ID is authoritative. Local
    // filename/NFO year and season heuristics are search gates, not grounds to
    // reject a known AniDB identity (continuation seasons routinely differ).
    // MAL has one anime ID namespace across movie/TV. A known MAL identity
    // supplies its actual type; TMDB IDs remain locked to /movie or /tv.
    if (lookup.provider != VideoMetadataProviderKind.mal &&
        work.kind != request.mediaKind) {
      return VideoMetadataResolution(
        status: VideoMetadataResolutionStatus.notFound,
        method: method,
        lookup: lookup,
        providerKind: provider.providerKind,
        reason: 'Explicit identity has a different media type',
      );
    }
    return VideoMetadataResolution(
      status: VideoMetadataResolutionStatus.matched,
      method: method,
      work: work,
      lookup: _lookupForWork(work, provider.providerKind) ?? lookup,
      providerKind: provider.providerKind,
    );
  }

  bool _passesTypeYearGate(
    VideoMetadataWork candidate,
    VideoMetadataResolveRequest request,
  ) {
    if (candidate.kind != request.mediaKind) return false;
    if (request.year != null &&
        candidate.year != null &&
        candidate.year != request.year) {
      return false;
    }
    return true;
  }

  Future<VideoMetadataWork?> _validatedDetails(
    VideoMetadataProvider provider,
    VideoMetadataLookup lookup,
    VideoMetadataWork work,
    VideoMetadataResolveRequest request,
  ) async {
    if (work.kind != request.mediaKind) return null;
    if (request.year != null &&
        work.year != null &&
        work.year != request.year) {
      return null;
    }
    final int? seasonNumber = request.seasonNumber;
    if (seasonNumber == null || work.kind == VideoMetadataMediaKind.movie) {
      return work;
    }
    if (provider.providerKind == VideoMetadataProviderKind.anidb ||
        provider.providerKind == VideoMetadataProviderKind.mal) {
      final int? inferred = _inferredSeasonNumber(work);
      // AniDB and MAL IDs each represent one independently titled anime entry. Many
      // sequels (for example `K-ON!!`) carry no parseable "Season 2" token,
      // so an absent inferred number is unknown rather than season 1. Reject
      // only an explicit conflicting season; the coordinator later remaps the
      // single AniDB season to the locally parsed season number.
      return inferred == null || inferred == seasonNumber ? work : null;
    }
    if (work.seasons.any(
      (VideoMetadataSeason season) => season.seasonNumber == seasonNumber,
    )) {
      return work;
    }
    final List<VideoMetadataSeason> seasons =
        await provider.fetchSeasons(lookup);
    if (seasons.any(
      (VideoMetadataSeason season) => season.seasonNumber == seasonNumber,
    )) {
      return work;
    }
    if (provider case final VideoMetadataEpisodeGroupProvider groupProvider) {
      final VideoMetadataLookup? grouped =
          await groupProvider.resolveEpisodeGroup(
        lookup,
        seasonNumber: seasonNumber,
        episodeCount: request.episodeCount,
      );
      if (grouped != null) {
        return work.copyWith(episodeGroupId: grouped.episodeGroupId);
      }
    }
    return null;
  }
}

Set<String> _normalizedTitles(String value) {
  final Set<String> result = <String>{};
  final String direct = TitleNormalizer.normalize(value);
  if (direct.isNotEmpty) result.add(direct);
  final String parsed =
      TitleNormalizer.normalize(FilenameParser.parse(value).title);
  if (parsed.isNotEmpty) result.add(parsed);
  return result;
}

bool _matchesNormalizedTitle(
  VideoMetadataWork work,
  Set<String> normalizedTitles,
) {
  return <String?>[
    work.title,
    work.originalTitle,
    ...work.aliases,
  ].any(
    (String? value) =>
        value != null &&
        _normalizedTitles(value).any(normalizedTitles.contains),
  );
}

int? _inferredSeasonNumber(VideoMetadataWork work) {
  for (final String? title in <String?>[
    work.title,
    work.originalTitle,
    ...work.aliases,
  ]) {
    if (title == null) continue;
    final int? season = FilenameParser.parse(title).season;
    if (season != null) return season;
  }
  return null;
}

VideoMetadataLookup? _lookupForWork(
  VideoMetadataWork work,
  VideoMetadataProviderKind provider,
) {
  final String idType = provider.name;
  for (final VideoMetadataId id in work.ids) {
    if (id.type.toLowerCase() == idType && id.value.trim().isNotEmpty) {
      return VideoMetadataLookup(
        provider: provider,
        externalId: id.value,
        mediaKind: work.kind,
        episodeGroupId: work.episodeGroupId,
      );
    }
  }
  return null;
}

/// 从文件名、目录名或站点 URL 中读取明确 provider id。返回顺序与输入顺序一致，
/// 同 provider/id 去重。不会把不带 provider 前缀的纯数字误判成 id。
List<VideoMetadataLookup> parseExplicitVideoMetadataIds(
  Iterable<String> values, {
  required VideoMetadataMediaKind fallbackMediaKind,
}) {
  final List<VideoMetadataLookup> result = <VideoMetadataLookup>[];
  final Set<String> seen = <String>{};
  void add(
    VideoMetadataProviderKind provider,
    String id,
    VideoMetadataMediaKind mediaKind, {
    String? episodeGroupId,
  }) {
    final String normalizedId = id.trim();
    final String? normalizedGroup = episodeGroupId?.trim();
    final String key =
        '${provider.name}:$normalizedId:${mediaKind.name}:${normalizedGroup ?? ''}';
    if (normalizedId.isNotEmpty && seen.add(key)) {
      result.add(VideoMetadataLookup(
        provider: provider,
        externalId: normalizedId,
        mediaKind: mediaKind,
        episodeGroupId: provider == VideoMetadataProviderKind.tmdb &&
                normalizedGroup != null &&
                normalizedGroup.isNotEmpty
            ? normalizedGroup
            : null,
      ));
    }
  }

  for (final String raw in values) {
    final String value = raw.trim();
    if (value.isEmpty) continue;
    final String? declaredType = RegExp(
      r'(?:^|[;,\s])type\s*[:=]\s*(movie|tv)',
      caseSensitive: false,
    ).firstMatch(value)?.group(1)?.toLowerCase();
    final VideoMetadataMediaKind declaredKind = switch (declaredType) {
      'movie' => VideoMetadataMediaKind.movie,
      'tv' => VideoMetadataMediaKind.tv,
      _ => fallbackMediaKind,
    };
    final String? episodeGroupId = RegExp(
      r'(?:^|[;,\s])(?:g|group|episode[_-]?group)\s*[:=]\s*([A-Za-z0-9._-]+)',
      caseSensitive: false,
    ).firstMatch(value)?.group(1);
    final Uri? uri = Uri.tryParse(
      value.contains('://') ? value : 'https://$value',
    );
    if (uri != null && uri.host.isNotEmpty) {
      final String host = uri.host.toLowerCase().replaceFirst('www.', '');
      final List<String> path = uri.pathSegments;
      if (host == 'anidb.net' &&
          path.length >= 2 &&
          path[0] == 'anime' &&
          RegExp(r'^\d+$').hasMatch(path[1])) {
        add(VideoMetadataProviderKind.anidb, path[1], fallbackMediaKind);
      } else if (host == 'myanimelist.net' &&
          path.length >= 2 &&
          path[0] == 'anime' &&
          RegExp(r'^\d+$').hasMatch(path[1])) {
        add(VideoMetadataProviderKind.mal, path[1], fallbackMediaKind);
      } else if (host == 'themoviedb.org' && path.length >= 2) {
        final VideoMetadataMediaKind? kind = switch (path[0]) {
          'tv' => VideoMetadataMediaKind.tv,
          'movie' => VideoMetadataMediaKind.movie,
          _ => null,
        };
        final String? id = RegExp(r'^\d+').firstMatch(path[1])?.group(0);
        if (kind != null && id != null) {
          add(
            VideoMetadataProviderKind.tmdb,
            id,
            kind,
            episodeGroupId:
                uri.queryParameters['episode_group'] ?? episodeGroupId,
          );
        }
      } else if ((host == 'bgm.tv' ||
              host == 'bangumi.tv' ||
              host == 'chii.in') &&
          path.length >= 2 &&
          path[0] == 'subject' &&
          RegExp(r'^\d+$').hasMatch(path[1])) {
        add(VideoMetadataProviderKind.bangumi, path[1], fallbackMediaKind);
      } else if (host == 'anilist.co' &&
          path.length >= 2 &&
          path[0] == 'anime' &&
          RegExp(r'^\d+$').hasMatch(path[1])) {
        add(VideoMetadataProviderKind.anilist, path[1], fallbackMediaKind);
      } else if (host.endsWith('douban.com') &&
          path.length >= 2 &&
          path[0] == 'subject' &&
          RegExp(r'^\d+$').hasMatch(path[1])) {
        add(VideoMetadataProviderKind.douban, path[1], fallbackMediaKind);
      }
    }

    final RegExp pattern = RegExp(
      r'(?:^|[\[{(_\s.-])'
      r'(anidb|aid|mal|myanimelist|tmdb|tmdbid|douban|doubanid|bangumi|bgm|anilist)'
      r'(?:\s*:\s*(tv|movie)(?=\s*[:=_-]))?'
      r'\s*(?:id)?\s*[:=_-]\s*([A-Za-z0-9.-]+)',
      caseSensitive: false,
    );
    for (final RegExpMatch match in pattern.allMatches(value)) {
      final String source = match.group(1)!.toLowerCase();
      final String id = match.group(3)!;
      final VideoMetadataMediaKind tokenKind =
          switch (match.group(2)?.toLowerCase()) {
        'tv' => VideoMetadataMediaKind.tv,
        'movie' => VideoMetadataMediaKind.movie,
        _ => declaredKind,
      };
      final VideoMetadataProviderKind provider = switch (source) {
        'anidb' || 'aid' => VideoMetadataProviderKind.anidb,
        'mal' || 'myanimelist' => VideoMetadataProviderKind.mal,
        'tmdb' || 'tmdbid' => VideoMetadataProviderKind.tmdb,
        'douban' || 'doubanid' => VideoMetadataProviderKind.douban,
        'bangumi' || 'bgm' => VideoMetadataProviderKind.bangumi,
        _ => VideoMetadataProviderKind.anilist,
      };
      if ((provider == VideoMetadataProviderKind.mal ||
              provider == VideoMetadataProviderKind.anidb ||
              provider == VideoMetadataProviderKind.tmdb) &&
          !RegExp(r'^[0-9]+$').hasMatch(id)) {
        continue;
      }
      add(
        provider,
        id,
        tokenKind,
        episodeGroupId: episodeGroupId,
      );
    }
  }
  return result;
}
