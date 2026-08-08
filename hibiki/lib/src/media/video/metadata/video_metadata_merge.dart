/// 多来源结果合并规则：选定主源拥有展示资料，TMDB 只补规范身份/季集骨架，
/// Fanart 只补图片。纯函数，便于用 provider mock 锁定行为。
library;

import 'package:hibiki/src/media/video/metadata/video_metadata_models.dart';

VideoMetadataWork supplementVideoMetadataWithTmdb(
  VideoMetadataWork primary,
  VideoMetadataWork? tmdb,
) {
  if (tmdb == null || primary.provider == VideoMetadataProviderKind.tmdb) {
    return primary;
  }
  return primary.copyWith(
    kind: tmdb.kind,
    originalTitle: primary.originalTitle ?? tmdb.originalTitle,
    tagline: primary.tagline ?? tmdb.tagline,
    aliases: primary.aliases.isEmpty ? tmdb.aliases : primary.aliases,
    year: primary.year ?? tmdb.year,
    premiered: primary.premiered ?? tmdb.premiered,
    endDate: primary.endDate ?? tmdb.endDate,
    plot: primary.plot ?? tmdb.plot,
    rating: primary.rating ?? tmdb.rating,
    ratingVotes: primary.ratingVotes ?? tmdb.ratingVotes,
    runtimeMinutes: primary.runtimeMinutes ?? tmdb.runtimeMinutes,
    contentRating: primary.contentRating ?? tmdb.contentRating,
    status: primary.status ?? tmdb.status,
    originalLanguage: primary.originalLanguage ?? tmdb.originalLanguage,
    homepage: primary.homepage ?? tmdb.homepage,
    episodeGroupId: primary.episodeGroupId ?? tmdb.episodeGroupId,
    ids: _mergeIds(primary.ids, tmdb.ids),
    seasonCount: primary.seasonCount ?? tmdb.seasonCount,
    episodeCount: primary.episodeCount ?? tmdb.episodeCount,
    genres: primary.genres.isEmpty ? tmdb.genres : primary.genres,
    studios: primary.studios.isEmpty ? tmdb.studios : primary.studios,
    countries: primary.countries.isEmpty ? tmdb.countries : primary.countries,
    keywords: primary.keywords.isEmpty ? tmdb.keywords : primary.keywords,
    credits: _mergeCredits(primary.credits, tmdb.credits),
    seasons: _mergeSeasons(primary.seasons, tmdb.seasons),
    images: _mergeImagesFillingMissing(primary.images, tmdb.images),
  );
}

/// Bangumi/AniList 的单季响应以 season=1 表示当前作品。若本地文件已明确是
/// 续季，只把这种单季结果重映射到本地季号，再与 TMDB 的全剧骨架合并。
/// 多季响应或本来就匹配的季号保持不动，避免猜测真实全剧编排。
VideoMetadataWork remapStandaloneVideoMetadataSeason(
  VideoMetadataWork work,
  int? localSeasonNumber,
) {
  if (localSeasonNumber == null ||
      localSeasonNumber == 1 ||
      work.seasons.length != 1 ||
      work.seasons.single.seasonNumber != 1) {
    return work;
  }
  final VideoMetadataSeason season = work.seasons.single;
  VideoMetadataImage remapImage(VideoMetadataImage image) =>
      image.seasonNumber == 1
          ? image.copyWith(seasonNumber: localSeasonNumber)
          : image;
  return work.copyWith(
    images: <VideoMetadataImage>[
      for (final VideoMetadataImage image in work.images) remapImage(image),
    ],
    seasons: <VideoMetadataSeason>[
      season.copyWith(
        seasonNumber: localSeasonNumber,
        images: <VideoMetadataImage>[
          for (final VideoMetadataImage image in season.images)
            remapImage(image),
        ],
        episodes: <VideoMetadataEpisode>[
          for (final VideoMetadataEpisode episode in season.episodes)
            episode.copyWith(
              seasonNumber: localSeasonNumber,
              images: <VideoMetadataImage>[
                for (final VideoMetadataImage image in episode.images)
                  remapImage(image),
              ],
            ),
        ],
      ),
    ],
  );
}

List<VideoMetadataSeason> _mergeSeasons(
  Iterable<VideoMetadataSeason> primary,
  Iterable<VideoMetadataSeason> supplement,
) {
  final Map<int, VideoMetadataSeason> supplementByNumber =
      <int, VideoMetadataSeason>{
    for (final VideoMetadataSeason season in supplement)
      season.seasonNumber: season,
  };
  final List<VideoMetadataSeason> result = <VideoMetadataSeason>[];
  final Set<int> consumed = <int>{};
  for (final VideoMetadataSeason season in primary) {
    final VideoMetadataSeason? matching =
        supplementByNumber[season.seasonNumber];
    consumed.add(season.seasonNumber);
    result.add(matching == null ? season : _mergeSeason(season, matching));
  }
  for (final VideoMetadataSeason season in supplement) {
    if (!consumed.contains(season.seasonNumber)) result.add(season);
  }
  result.sort((VideoMetadataSeason a, VideoMetadataSeason b) =>
      a.seasonNumber.compareTo(b.seasonNumber));
  return result;
}

VideoMetadataSeason _mergeSeason(
  VideoMetadataSeason primary,
  VideoMetadataSeason supplement,
) =>
    primary.copyWith(
      plot: primary.plot ?? supplement.plot,
      airDate: primary.airDate ?? supplement.airDate,
      year: primary.year ?? supplement.year,
      episodeCount: primary.episodeCount ?? supplement.episodeCount,
      rating: primary.rating ?? supplement.rating,
      ids: _mergeIds(primary.ids, supplement.ids),
      images: _mergeImagesFillingMissing(primary.images, supplement.images),
      episodes: _mergeEpisodes(primary.episodes, supplement.episodes),
    );

List<VideoMetadataEpisode> _mergeEpisodes(
  Iterable<VideoMetadataEpisode> primary,
  Iterable<VideoMetadataEpisode> supplement,
) {
  final Map<int, VideoMetadataEpisode> supplementByNumber =
      <int, VideoMetadataEpisode>{
    for (final VideoMetadataEpisode episode in supplement)
      episode.episodeNumber: episode,
  };
  final List<VideoMetadataEpisode> result = <VideoMetadataEpisode>[];
  final Set<int> consumed = <int>{};
  for (final VideoMetadataEpisode episode in primary) {
    final VideoMetadataEpisode? matching =
        supplementByNumber[episode.episodeNumber];
    consumed.add(episode.episodeNumber);
    result.add(matching == null ? episode : _mergeEpisode(episode, matching));
  }
  for (final VideoMetadataEpisode episode in supplement) {
    if (!consumed.contains(episode.episodeNumber)) result.add(episode);
  }
  result.sort((VideoMetadataEpisode a, VideoMetadataEpisode b) =>
      a.episodeNumber.compareTo(b.episodeNumber));
  return result;
}

VideoMetadataEpisode _mergeEpisode(
  VideoMetadataEpisode primary,
  VideoMetadataEpisode supplement,
) =>
    primary.copyWith(
      plot: primary.plot ?? supplement.plot,
      airDate: primary.airDate ?? supplement.airDate,
      year: primary.year ?? supplement.year,
      absoluteNumber: primary.absoluteNumber ?? supplement.absoluteNumber,
      rating: primary.rating ?? supplement.rating,
      ratingVotes: primary.ratingVotes ?? supplement.ratingVotes,
      runtimeMinutes: primary.runtimeMinutes ?? supplement.runtimeMinutes,
      ids: _mergeIds(primary.ids, supplement.ids),
      credits: _mergeCredits(primary.credits, supplement.credits),
      images: _mergeImagesFillingMissing(primary.images, supplement.images),
    );

List<VideoMetadataId> _mergeIds(
  Iterable<VideoMetadataId> primary,
  Iterable<VideoMetadataId> supplement,
) {
  final List<VideoMetadataId> result = <VideoMetadataId>[];
  final Set<String> seen = <String>{};
  for (final VideoMetadataId id in <VideoMetadataId>[
    ...primary,
    ...supplement,
  ]) {
    final String key = '${id.type.toLowerCase()}:${id.value.trim()}';
    if (id.value.trim().isNotEmpty && seen.add(key)) result.add(id);
  }
  return result;
}

List<VideoMetadataCredit> _mergeCredits(
  Iterable<VideoMetadataCredit> primary,
  Iterable<VideoMetadataCredit> supplement,
) {
  final List<VideoMetadataCredit> result = primary.toList();
  final Map<String, int> indexByKey = <String, int>{
    for (int index = 0; index < result.length; index++)
      _creditKey(result[index]): index,
  };
  for (final VideoMetadataCredit credit in supplement) {
    final String key = _creditKey(credit);
    final int? existingIndex = indexByKey[key];
    if (existingIndex == null) {
      indexByKey[key] = result.length;
      result.add(credit);
    } else {
      result[existingIndex] = _mergeCredit(result[existingIndex], credit);
    }
  }
  return result;
}

VideoMetadataCredit _mergeCredit(
  VideoMetadataCredit primary,
  VideoMetadataCredit supplement,
) =>
    primary.copyWith(
      person: _mergePerson(primary.person, supplement.person),
      character: switch ((primary.character, supplement.character)) {
        (
          final VideoMetadataCharacter value,
          final VideoMetadataCharacter other
        ) =>
          _mergeCharacter(value, other),
        (final VideoMetadataCharacter value, null) => value,
        (null, final VideoMetadataCharacter value) => value,
        (null, null) => null,
      },
      language: primary.language ?? supplement.language,
      roleName: primary.roleName ?? supplement.roleName,
      department: primary.department ?? supplement.department,
      job: primary.job ?? supplement.job,
      providerCreditId: primary.providerCreditId ?? supplement.providerCreditId,
    );

VideoMetadataPerson _mergePerson(
  VideoMetadataPerson primary,
  VideoMetadataPerson supplement,
) =>
    primary.copyWith(
      id: primary.id ?? supplement.id,
      originalName: primary.originalName ?? supplement.originalName,
      biography: primary.biography ?? supplement.biography,
      birthday: primary.birthday ?? supplement.birthday,
      deathday: primary.deathday ?? supplement.deathday,
      gender: primary.gender ?? supplement.gender,
      placeOfBirth: primary.placeOfBirth ?? supplement.placeOfBirth,
      profileUrl: primary.profileUrl ?? supplement.profileUrl,
      ids: _mergeIds(primary.ids, supplement.ids),
    );

VideoMetadataCharacter _mergeCharacter(
  VideoMetadataCharacter primary,
  VideoMetadataCharacter supplement,
) =>
    primary.copyWith(
      id: primary.id ?? supplement.id,
      originalName: primary.originalName ?? supplement.originalName,
      description: primary.description ?? supplement.description,
      imageUrl: primary.imageUrl ?? supplement.imageUrl,
      ids: _mergeIds(primary.ids, supplement.ids),
    );

String _creditKey(VideoMetadataCredit credit) => <String>[
      credit.kind.name,
      _textKey(credit.person.name),
      _textKey(credit.roleName ?? credit.character?.name ?? ''),
    ].join('|');

String _textKey(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

List<VideoMetadataImage> _mergeImagesFillingMissing(
  Iterable<VideoMetadataImage> primary,
  Iterable<VideoMetadataImage> supplement,
) {
  final List<VideoMetadataImage> result = primary.toList();
  final Set<String> occupiedSlots = <String>{
    for (final VideoMetadataImage image in result) _imageSlotKey(image),
  };
  final Set<String> seenUrls = <String>{
    for (final VideoMetadataImage image in result) image.url,
  };
  for (final VideoMetadataImage image in supplement) {
    if (!occupiedSlots.contains(_imageSlotKey(image)) &&
        seenUrls.add(image.url)) {
      result.add(image);
    }
  }
  return result;
}

String _imageSlotKey(VideoMetadataImage image) => <Object?>[
      image.seasonNumber,
      image.episodeNumber,
      image.kind.name,
    ].join(':');

/// 每个层级/图种只选一张。Fanart 候选先占位；主源只补缺。Fanart 内按
/// `zh → en → 无语言 → 其它`，同语言按 likes；TMDB/主源按评分、票数。
List<VideoMetadataImage> selectVideoMetadataImages({
  required Iterable<VideoMetadataImage> primary,
  Iterable<VideoMetadataImage> fanart = const <VideoMetadataImage>[],
  List<String> languageOrder = const <String>['zh', 'en', ''],
  int maxBackdrops = 3,
}) {
  assert(maxBackdrops > 0);
  final Map<String, List<VideoMetadataImage>> fanartGroups =
      _groupImages(fanart);
  final Map<String, List<VideoMetadataImage>> primaryGroups =
      _groupImages(primary);
  final Set<String> keys = <String>{
    ...fanartGroups.keys,
    ...primaryGroups.keys,
  };
  final List<VideoMetadataImage> selected = <VideoMetadataImage>[];
  for (final String key in keys) {
    final List<VideoMetadataImage> preferred =
        fanartGroups[key] ?? primaryGroups[key] ?? const <VideoMetadataImage>[];
    if (preferred.isEmpty) continue;
    preferred.sort((VideoMetadataImage a, VideoMetadataImage b) =>
        _compareImages(a, b, languageOrder));
    final bool isBackdrop =
        preferred.first.kind == VideoMetadataImageKind.backdrop;
    selected.addAll(preferred.take(isBackdrop ? maxBackdrops : 1));
  }
  selected.sort((VideoMetadataImage a, VideoMetadataImage b) {
    final int bySeason = (a.seasonNumber ?? -1).compareTo(b.seasonNumber ?? -1);
    if (bySeason != 0) return bySeason;
    final int byEpisode =
        (a.episodeNumber ?? -1).compareTo(b.episodeNumber ?? -1);
    if (byEpisode != 0) return byEpisode;
    return a.kind.index.compareTo(b.kind.index);
  });
  return selected;
}

Map<String, List<VideoMetadataImage>> _groupImages(
  Iterable<VideoMetadataImage> images,
) {
  final Map<String, List<VideoMetadataImage>> grouped =
      <String, List<VideoMetadataImage>>{};
  for (final VideoMetadataImage image in images) {
    final String key = <Object?>[
      image.seasonNumber,
      image.episodeNumber,
      image.kind.name,
    ].join(':');
    grouped.putIfAbsent(key, () => <VideoMetadataImage>[]).add(image);
  }
  return grouped;
}

int _compareImages(
  VideoMetadataImage a,
  VideoMetadataImage b,
  List<String> languageOrder,
) {
  int languageRank(String? raw) {
    final String language = raw?.trim().toLowerCase() ?? '';
    for (int index = 0; index < languageOrder.length; index++) {
      if (language == languageOrder[index].toLowerCase()) return index;
    }
    return languageOrder.length;
  }

  final bool fanart = a.provider == VideoMetadataProviderKind.fanart &&
      b.provider == VideoMetadataProviderKind.fanart;
  if (fanart) {
    final int language =
        languageRank(a.language).compareTo(languageRank(b.language));
    if (language != 0) return language;
    final int likes = (b.likes ?? -1).compareTo(a.likes ?? -1);
    if (likes != 0) return likes;
  }
  final int rating = (b.voteAverage ?? -1).compareTo(a.voteAverage ?? -1);
  if (rating != 0) return rating;
  final int votes = (b.voteCount ?? -1).compareTo(a.voteCount ?? -1);
  if (votes != 0) return votes;
  final int language =
      languageRank(a.language).compareTo(languageRank(b.language));
  if (language != 0) return language;
  final int likes = (b.likes ?? -1).compareTo(a.likes ?? -1);
  if (likes != 0) return likes;
  return a.url.compareTo(b.url);
}
