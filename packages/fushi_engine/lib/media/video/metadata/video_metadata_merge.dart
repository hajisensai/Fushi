/// 多来源结果合并规则（对标 Jellyfin `MergeBaseItemData`）：先到者（主源）
/// 标量独占、后到者只补空；集合类并集去重；简介 / 标语按首选语言可被补充源覆盖。
/// 主源可以是 MAL 也可以是 TMDB（对称）。兼容旧 AniDB 资料对象；文件哈希身份
/// 不因此变为新的主资料源。
library;

import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/scraper/title_normalizer.dart';

/// 有序合并：先到者（[primary]）标量独占、后到者（[supplement]）只补空；
/// genres / studios / countries / keywords / aliases 取并集去重；
/// `plot` / `tagline` 语言感知：primary 文本不是首选语言而 supplement 是首选
/// 语言时用 supplement。[preferredLanguage] 为 BCP-47（如 `zh-CN`），`null`
/// 时退化成「空才补」。两边同一 provider 时原样返回。
VideoMetadataWork supplementVideoMetadata(
  VideoMetadataWork primary,
  VideoMetadataWork? supplement, {
  String? preferredLanguage,
}) {
  if (supplement == null || primary.provider == supplement.provider) {
    return primary;
  }
  final bool preferSupplementText = _preferSupplementText(
    primary.provider,
    supplement.provider,
    preferredLanguage,
  );
  return primary.copyWith(
    originalTitle: primary.originalTitle ?? supplement.originalTitle,
    tagline: _pickText(
      primary.tagline,
      supplement.tagline,
      preferSupplement: preferSupplementText,
    ),
    aliases: _unionStrings(primary.aliases, supplement.aliases),
    year: primary.year ?? supplement.year,
    premiered: primary.premiered ?? supplement.premiered,
    endDate: primary.endDate ?? supplement.endDate,
    plot: _pickText(
      primary.plot,
      supplement.plot,
      preferSupplement: preferSupplementText,
    ),
    rating: primary.rating ?? supplement.rating,
    ratingVotes: primary.ratingVotes ?? supplement.ratingVotes,
    runtimeMinutes: primary.runtimeMinutes ?? supplement.runtimeMinutes,
    contentRating: primary.contentRating ?? supplement.contentRating,
    status: primary.status ?? supplement.status,
    originalLanguage: primary.originalLanguage ?? supplement.originalLanguage,
    homepage: primary.homepage ?? supplement.homepage,
    episodeGroupId: primary.episodeGroupId ?? supplement.episodeGroupId,
    ids: _mergeIds(primary.ids, supplement.ids),
    seasonCount: primary.seasonCount ?? supplement.seasonCount,
    episodeCount: primary.episodeCount ?? supplement.episodeCount,
    genres: _unionStrings(primary.genres, supplement.genres),
    studios: _unionStrings(primary.studios, supplement.studios),
    countries: _unionStrings(primary.countries, supplement.countries),
    keywords: _unionStrings(primary.keywords, supplement.keywords),
    credits: _mergeCredits(primary.credits, supplement.credits),
    seasons: _mergeSeasons(primary.seasons, supplement.seasons),
    images: _mergeImagesFillingMissing(primary.images, supplement.images),
    extras: _mergeExtras(primary.extras, supplement.extras),
  );
}

/// 兼容旧调用方：等价 `supplementVideoMetadata(primary, tmdb)`；primary 已是
/// TMDB 时原样返回（同 provider 短路）。不做语言感知。
VideoMetadataWork supplementVideoMetadataWithTmdb(
  VideoMetadataWork primary,
  VideoMetadataWork? tmdb,
) =>
    supplementVideoMetadata(primary, tmdb);

/// 各 provider 返回文本（简介 / 标语）的语言约定：Jikan synopsis 恒英文；
/// TMDB 按请求 locale 返回，即调用方传入的首选语言；其它源未知（不覆盖）。
String? _providerTextLanguage(
  VideoMetadataProviderKind provider,
  String? preferredLanguage,
) =>
    switch (provider) {
      VideoMetadataProviderKind.mal => 'en',
      VideoMetadataProviderKind.tmdb => preferredLanguage,
      _ => null,
    };

/// Jellyfin `ResultLanguage` 规则：primary 文本已是首选语言、或 supplement
/// 文本不是首选语言 → 沿用先到者优先；只有 primary 非首选且 supplement 首选
/// 才让补充源覆盖。
bool _preferSupplementText(
  VideoMetadataProviderKind primary,
  VideoMetadataProviderKind supplement,
  String? preferredLanguage,
) {
  final bool primaryPreferred = _matchesPreferredLanguage(
    _providerTextLanguage(primary, preferredLanguage),
    preferredLanguage,
  );
  final bool supplementPreferred = _matchesPreferredLanguage(
    _providerTextLanguage(supplement, preferredLanguage),
    preferredLanguage,
  );
  return !primaryPreferred && supplementPreferred;
}

/// 照 Jellyfin `MetadataLanguageUtils.MatchesPreferredLanguage`：任一为空即
/// 不匹配；否则只比较主子标签（`zh-CN` 与 `zh` 同语言）。
bool _matchesPreferredLanguage(String? language, String? preferredLanguage) {
  final String? actual = _primaryLanguageSubtag(language);
  final String? preferred = _primaryLanguageSubtag(preferredLanguage);
  return actual != null && preferred != null && actual == preferred;
}

String? _primaryLanguageSubtag(String? tag) {
  final String trimmed = tag?.trim().toLowerCase() ?? '';
  if (trimmed.isEmpty) return null;
  final String primary = trimmed.split(RegExp(r'[-_]')).first;
  return primary.isEmpty ? null : primary;
}

String? _pickText(
  String? primary,
  String? supplement, {
  required bool preferSupplement,
}) {
  final String? first = preferSupplement ? supplement : primary;
  final String? second = preferSupplement ? primary : supplement;
  return _isBlank(first) ? second : first;
}

bool _isBlank(String? value) => value == null || value.trim().isEmpty;

/// 集合并集：primary 原样在前，supplement 只追加 primary 里没有的项。去重键用
/// `TitleNormalizer.normalize`（全半角、繁简、大小写、装饰符号折叠），避免
/// `Sci-Fi` / `Sci Fi`、`动作` / `動作` 这种同义标签在合并后成对出现。
List<String> _unionStrings(
  Iterable<String> primary,
  Iterable<String> supplement,
) {
  final List<String> result = primary.toList();
  final Set<String> seen = <String>{
    for (final String value in result) _unionKey(value),
  };
  for (final String value in supplement) {
    if (value.trim().isEmpty) continue;
    if (seen.add(_unionKey(value))) result.add(value);
  }
  return result;
}

String _unionKey(String value) {
  final String normalized = TitleNormalizer.normalize(value);
  return normalized.isEmpty ? value.trim().toLowerCase() : normalized;
}

List<VideoMetadataExtra> _mergeExtras(
  Iterable<VideoMetadataExtra> primary,
  Iterable<VideoMetadataExtra> supplement,
) {
  final Map<String, VideoMetadataExtra> result = <String, VideoMetadataExtra>{};
  for (final VideoMetadataExtra extra in <VideoMetadataExtra>[
    ...primary,
    ...supplement,
  ]) {
    final String key = extra.providerVideoId == null
        ? '${extra.remoteUrl}|${extra.title}'
        : '${extra.provider?.name}|${extra.providerVideoId}';
    result.putIfAbsent(key, () => extra);
  }
  return result.values.toList(growable: false);
}

/// AniDB 等单作品响应以 season=1 表示当前作品。若本地文件已明确是
/// 续季，只把这种单季结果重映射到本地季号，再与 TMDB 的全剧骨架合并。
/// 多季响应或本来就匹配的季号保持不动，避免猜测真实全剧编排。
VideoMetadataWork remapStandaloneVideoMetadataSeason(
  VideoMetadataWork work,
  int? localSeasonNumber,
) {
  if (localSeasonNumber == null ||
      localSeasonNumber <= 1 ||
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

/// 每个层级/图种只选一张（背景图可多张）。
///
/// 印着片名的图种（见 [kLanguageFirstImageKinds]）先按 [languageOrder]（本语言
/// → en → 无语言 → 其它），同语言内再按评分、票数、likes；背景图 / 分集剧照 /
/// 横版图是画面不是文字，语言标签只表示「上面有没有印片名」，仍按评分优先、语言
/// 只作同分兜底（与修复前一致）。
///
/// [languageOrder] 必填：它此前有个 `['zh','en','']` 的默认值，而唯一调用点从不
/// 传值——于是无论用户是谁、资料语言是什么，海报永远中文优先。默认值把「忘了接线」
/// 伪装成了「有意的排序策略」，所以这里不再留默认值，强迫调用方说出用哪种语言。
/// 派生用 `VideoMetadataLanguages.imageLanguages`。
List<VideoMetadataImage> selectVideoMetadataImages({
  required Iterable<VideoMetadataImage> primary,
  required List<String> languageOrder,
  int maxBackdrops = 3,
}) {
  assert(maxBackdrops > 0);
  final Map<String, List<VideoMetadataImage>> primaryGroups = _groupImages(
    primary,
  );
  final List<VideoMetadataImage> selected = <VideoMetadataImage>[];
  for (final List<VideoMetadataImage> preferred in primaryGroups.values) {
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

/// 图上印着片名文字、语言标签有实际含义的图种：这些按资料语言优先选。
///
/// 是「图种的属性」而不是「除背景图之外的一切」：分集剧照（`thumb`）和横版图
/// （`landscape`）与背景图一样是画面，TMDB 给剧照打的语言标签不代表上面有字，
/// 按语言优先会让一张 0 票的 `en` 剧照压住 8 分的无标签剧照。
const Set<VideoMetadataImageKind> kLanguageFirstImageKinds =
    <VideoMetadataImageKind>{
  VideoMetadataImageKind.cover,
  VideoMetadataImageKind.logo,
  VideoMetadataImageKind.banner,
  VideoMetadataImageKind.disc,
  VideoMetadataImageKind.clearart,
};

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

  final int language =
      languageRank(a.language).compareTo(languageRank(b.language));
  // 海报 / logo 上印的是片名，用户选了资料语言就是要那种文字的图：语言先于
  // 评分，否则一张高分外语海报永远压住本语言海报（用户设 ja 仍拿到中文海报，
  // 就是这条路径）。画面类图种评分继续做主。
  if (kLanguageFirstImageKinds.contains(a.kind) && language != 0) {
    return language;
  }
  final int rating = (b.voteAverage ?? -1).compareTo(a.voteAverage ?? -1);
  if (rating != 0) return rating;
  final int votes = (b.voteCount ?? -1).compareTo(a.voteCount ?? -1);
  if (votes != 0) return votes;
  if (language != 0) return language;
  final int likes = (b.likes ?? -1).compareTo(a.likes ?? -1);
  if (likes != 0) return likes;
  return a.url.compareTo(b.url);
}
