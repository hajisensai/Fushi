/// 多来源结果合并规则（对标 Jellyfin `MergeBaseItemData`）：先到者（主源）
/// 标量独占、后到者只补空；集合类并集去重；简介 / 标语按首选语言可被补充源覆盖。
/// 主源可以是 MAL 也可以是 TMDB（对称）。兼容旧 AniDB 资料对象；文件哈希身份
/// 不因此变为新的主资料源。
library;

import 'dart:math';
import 'package:fushi_engine/media/video/metadata/tmdb_episode_matcher.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/scraper/title_normalizer.dart';

/// 有序合并：先到者（[primary]）标量独占、后到者（[supplement]）只补空；
/// genres / studios / countries / keywords / aliases 取并集去重；
/// `plot` / `tagline` 语言感知：primary 文本不是首选语言而 supplement 是首选
/// 语言时用 supplement。[preferredLanguage] 为 BCP-47（如 `zh-CN`），`null`
/// 时退化成「空才补」。两边同一 provider 时原样返回。
///
/// [creditNames] 是合并前从**全部**来源收集的人名 / 角色名写法等价类（见
/// [VideoMetadataCreditNameBridge.fromWorks]）；多源依次合并时每一步都传同一份，
/// 人物身份判定才与合并顺序无关。不传时只按两边自身的写法比对（旧行为）。
VideoMetadataWork supplementVideoMetadata(
  VideoMetadataWork primary,
  VideoMetadataWork? supplement, {
  String? preferredLanguage,
  VideoMetadataCreditNameBridge creditNames =
      VideoMetadataCreditNameBridge.none,
}) {
  if (supplement == null || primary.provider == supplement.provider) {
    return primary;
  }
  final bool preferSupplementText = _preferSupplementText(
    primary.provider,
    supplement.provider,
    preferredLanguage,
  );
  final bool preferSupplementTitle = _preferSupplementTitle(
    primary.provider,
    supplement.provider,
    preferredLanguage,
  );
  final String title = preferSupplementTitle && !_isBlank(supplement.title)
      ? supplement.title
      : primary.title;
  final bool titleReplaced = title != primary.title;
  return primary.copyWith(
    title: title,
    // 换成译名后原文不能丢：主源自带原名优先，否则被换下来的主源标题就是原名。
    originalTitle: primary.originalTitle ??
        supplement.originalTitle ??
        (titleReplaced ? primary.title : null),
    tagline: _pickText(
      primary.tagline,
      supplement.tagline,
      preferSupplement: preferSupplementText,
    ),
    // 被换下来的主源标题进别名池：exact gate 与去重比的是 title / original /
    // aliases 三处，标题换语言不能让匹配面缩水。
    aliases: _unionStrings(
      <String>[...primary.aliases, if (titleReplaced) primary.title],
      supplement.aliases,
    ).where((String alias) => alias != title).toList(),
    romajiTitle: primary.romajiTitle ?? supplement.romajiTitle,
    englishTitle: primary.englishTitle ?? supplement.englishTitle,
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
    genres: _mergeLanguageTaggedStrings(
      primary.genres,
      supplement.genres,
      primaryLanguage:
          _providerTextLanguage(primary.provider, preferredLanguage),
      supplementLanguage:
          _providerTextLanguage(supplement.provider, preferredLanguage),
      preferredLanguage: preferredLanguage,
    ),
    studios: _unionStrings(primary.studios, supplement.studios),
    countries: _unionStrings(primary.countries, supplement.countries),
    keywords: _unionStrings(primary.keywords, supplement.keywords),
    credits: mergeVideoMetadataCredits(
      primary.credits,
      supplement.credits,
      names: creditNames,
    ),
    seasons: _mergeSeasons(
      primary.seasons,
      supplement.seasons,
      preferSupplementTitle: preferSupplementTitle,
      creditNames: creditNames,
    ),
    images: _mergeImagesFillingMissing(primary.images, supplement.images),
    extras: _mergeExtras(primary.extras, supplement.extras),
  );
}

/// 各 provider **标题**的语言约定（与简介的 [_providerTextLanguage] 分开：MAL
/// 简介恒英文，标题却按资料语言在日/英之间选）：
///  - TMDB：`name` 按请求 locale 投影 → 首选语言；
///  - MAL：只有日 / 英 / 罗马字，`ja` / `en` 时给的就是本语言，其它语言 MAL 没有
///    译名、落的是日文原文（见 `MalVideoMetadataProvider._pickByLanguage`）；
///  - 其它源：未知（返回 null，合并时**不动**主源标题——不明语言不能当「不是首选
///    语言」处理，AniDB 自己已按语言选过标题）。
String? _providerTitleLanguage(
  VideoMetadataProviderKind provider,
  String? preferredLanguage,
) {
  switch (provider) {
    case VideoMetadataProviderKind.tmdb:
      return preferredLanguage;
    case VideoMetadataProviderKind.mal:
      final String? subtag = _primaryLanguageSubtag(preferredLanguage);
      return subtag == 'ja' || subtag == 'en' ? subtag : 'ja';
    default:
      return null;
  }
}

/// 标题版 [_preferSupplementText]：主源标题语言**已知**且不是首选、补充源标题是
/// 首选 → 用补充源的。典型路径：资料语言 zh-CN、MAL 主源（日文原文）+ TMDB 补充
/// （中文译名）→ 标题换成中文，与同一趟刮到的中文简介、中文海报同一种语言。
bool _preferSupplementTitle(
  VideoMetadataProviderKind primary,
  VideoMetadataProviderKind supplement,
  String? preferredLanguage,
) {
  final String? primaryLanguage =
      _providerTitleLanguage(primary, preferredLanguage);
  if (primaryLanguage == null) return false;
  return !_matchesPreferredLanguage(primaryLanguage, preferredLanguage) &&
      _matchesPreferredLanguage(
        _providerTitleLanguage(supplement, preferredLanguage),
        preferredLanguage,
      );
}

/// 兼容旧调用方：等价 `supplementVideoMetadata(primary, tmdb)`；primary 已是
/// TMDB 时原样返回（同 provider 短路）。不做语言感知。
VideoMetadataWork supplementVideoMetadataWithTmdb(
  VideoMetadataWork primary,
  VideoMetadataWork? tmdb,
) =>
    supplementVideoMetadata(primary, tmdb);

/// 各 provider 返回文本（简介 / 标语）的语言约定：Jikan synopsis 恒英文；AniDB
/// description 也恒英文（Shoko 同样把它当 English，`DescriptionSourceOrder =
/// [TMDB, AniDB]` 让资料语言的 TMDB 简介优先）；TMDB 按请求 locale 返回，即调用
/// 方传入的首选语言；其它源未知（不覆盖）。标题不在此列：Shoko
/// `SeriesTitleSourceOrder = [AniDB, TMDB]`，AniDB 主源标题自己已按语言选过。
String? _providerTextLanguage(
  VideoMetadataProviderKind provider,
  String? preferredLanguage,
) =>
    switch (provider) {
      VideoMetadataProviderKind.mal => 'en',
      VideoMetadataProviderKind.anidb => 'en',
      // AniList 的 description / genres 只有英文（GraphQL 没有语言参数）。
      VideoMetadataProviderKind.anilist => 'en',
      VideoMetadataProviderKind.tmdb => preferredLanguage,
      _ => null,
    };

/// [provider] 返回的简介是否是资料语言 [preferredLanguage] 的文本（同
/// [_providerTextLanguage] 的约定）。发现列表合并多来源卡片时用它选简介：
/// 动画来源（MAL / AniList）排在主位，但它们的简介恒英文，资料语言是中文时
/// 必须让同组 TMDB 的中文简介顶上，而不是「主源有字就用主源」。
bool videoMetadataTextMatchesLanguage(
  VideoMetadataProviderKind provider,
  String? preferredLanguage,
) =>
    _matchesPreferredLanguage(
      _providerTextLanguage(provider, preferredLanguage),
      preferredLanguage,
    );

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

/// 带语言的标签集合（类型）合并：两边语言已知且不同，就**不**跨语言取并集——
/// 并集会把 `Drama` / `Slice of Life`（MAL）与 `アニメーション` / `コメディ`
/// （TMDB ja）混排成一行。取与资料语言一致的那一边；那一边为空才退回另一边；
/// 两边都不是资料语言时先到者（主源）优先。语言相同或任一未知时照旧取并集。
List<String> _mergeLanguageTaggedStrings(
  List<String> primary,
  List<String> supplement, {
  required String? primaryLanguage,
  required String? supplementLanguage,
  required String? preferredLanguage,
}) {
  final String? primarySubtag = _primaryLanguageSubtag(primaryLanguage);
  final String? supplementSubtag = _primaryLanguageSubtag(supplementLanguage);
  if (primarySubtag == null ||
      supplementSubtag == null ||
      primarySubtag == supplementSubtag) {
    return _unionStrings(primary, supplement);
  }
  final bool preferSupplement =
      !_matchesPreferredLanguage(primaryLanguage, preferredLanguage) &&
          _matchesPreferredLanguage(supplementLanguage, preferredLanguage);
  final List<String> first = preferSupplement ? supplement : primary;
  final List<String> second = preferSupplement ? primary : supplement;
  return List<String>.of(first.isNotEmpty ? first : second);
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

/// 一个 MAL cour 在 TMDB 剧里的位置：第 [tmdbSeason] 季、从第 [offset]+1 集起
/// （Fribb anime-lists 的 `season.tmdb` / `episode_offset.tmdb`）。
typedef TmdbSeasonSlice = ({int tmdbSeason, int offset});

/// MAL 一个 id = 一个 cour，映射表把它显式钉在 TMDB 剧的某一季某一段上。MAL
/// 分集缺失或不全（Jikan 对播出中的作品常给 0 集）时，从 TMDB 那一季切出
/// `(offset, offset + count]` 重编成 1..count 补进这个 cour 季；MAL 已有的集
/// 只补空（同 [_mergeEpisodes]）。这是映射表给的**显式**对应，不是拿 AniDB /
/// MAL 集号去猜 TMDB 集号。
///
/// [slices]：卡片季号 → 切片，须包含同一 TMDB 季里的**全部** cour（不只是本
/// 地出现的那几季），MAL 没给集数时才能用下一个 cour 的偏移当本段终点；找不到
/// 终点则切到季末。TMDB 那一季不存在 / 该段没有集时原样返回。
VideoMetadataWork fillSeasonsFromTmdbSlices(
  VideoMetadataWork primary,
  VideoMetadataWork? tmdb,
  Map<int, TmdbSeasonSlice> slices, {
  String? preferredLanguage,
}) {
  if (tmdb == null || slices.isEmpty || primary.seasons.isEmpty) {
    return primary;
  }
  final Map<int, VideoMetadataSeason> tmdbByNumber = <int, VideoMetadataSeason>{
    for (final VideoMetadataSeason season in tmdb.seasons)
      season.seasonNumber: season,
  };
  final bool preferSupplementTitle = _preferSupplementTitle(
    primary.provider,
    tmdb.provider,
    preferredLanguage,
  );
  bool changed = false;
  final List<VideoMetadataSeason> seasons = <VideoMetadataSeason>[
    for (final VideoMetadataSeason season in primary.seasons)
      if (slices[season.seasonNumber] case final TmdbSeasonSlice slice)
        if (tmdbByNumber[slice.tmdbSeason]
            case final VideoMetadataSeason tmdbSeason)
          _fillSeasonFromSlice(
            season,
            tmdbSeason,
            slice,
            end: _sliceEnd(season, slice, slices),
            preferSupplementTitle: preferSupplementTitle,
            onChanged: () => changed = true,
          )
        else
          season
      else
        season,
  ];
  return changed ? primary.copyWith(seasons: seasons) : primary;
}

/// 本段在 TMDB 季内的终点集号（含）：MAL 集数已知 → offset + count；否则同季
/// 里偏移更大的下一个 cour 的偏移；都没有 → null（到季末）。
int? _sliceEnd(
  VideoMetadataSeason season,
  TmdbSeasonSlice slice,
  Map<int, TmdbSeasonSlice> slices,
) {
  if (season.episodeCount case final int count when count > 0) {
    return slice.offset + count;
  }
  int? next;
  for (final TmdbSeasonSlice other in slices.values) {
    if (other.tmdbSeason != slice.tmdbSeason || other.offset <= slice.offset) {
      continue;
    }
    if (next == null || other.offset < next) next = other.offset;
  }
  return next;
}

VideoMetadataSeason _fillSeasonFromSlice(
  VideoMetadataSeason season,
  VideoMetadataSeason tmdbSeason,
  TmdbSeasonSlice slice, {
  required int? end,
  required bool preferSupplementTitle,
  required void Function() onChanged,
}) {
  final int seasonNumber = season.seasonNumber;
  final List<VideoMetadataEpisode> sliced = <VideoMetadataEpisode>[
    for (final VideoMetadataEpisode episode in tmdbSeason.episodes)
      if (episode.episodeNumber > slice.offset &&
          (end == null || episode.episodeNumber <= end))
        episode.copyWith(
          seasonNumber: seasonNumber,
          episodeNumber: episode.episodeNumber - slice.offset,
          images: <VideoMetadataImage>[
            for (final VideoMetadataImage image in episode.images)
              image.copyWith(
                seasonNumber: seasonNumber,
                episodeNumber: episode.episodeNumber - slice.offset,
              ),
          ],
        ),
  ];
  if (sliced.isEmpty) return season;
  onChanged();
  return season.copyWith(
    episodes: _mergeEpisodes(
      season.episodes,
      sliced,
      preferSupplementTitle: preferSupplementTitle,
    ),
    // 终点来自下一个 cour 的偏移时，段长就是集数；到季末的段（播出中的末
    // cour）集数仍未知。
    episodeCount:
        season.episodeCount ?? (end == null ? null : end - slice.offset),
  );
}

/// [enrichSeasonsByTmdbEpisodeMatch] 的结果：补过的作品 + 每个 (季, 集) 的评级。
typedef TmdbEpisodeMatchOutcome = ({
  VideoMetadataWork work,
  Map<(int, int), TmdbEpisodeMatchRating> ratings,
});

/// Shoko 式逐集匹配补充（`MatchAnidbToTmdbEpisodes` 的用法之一）：映射表没有
/// 给切片的 MAL cour 季，用它自己分集的标题 + 播出日在 TMDB 全部正片季里逐集
/// 找对应，对上的用 TMDB 集补空（分集 id / 简介 / 剧照 / 播出日）。已被
/// [fillSeasonsFromTmdbSlices] 切过的季（[skipSeasons]）不再匹配；已经被本作品
/// 其它季用掉的 TMDB 集不进候选池。
TmdbEpisodeMatchOutcome enrichSeasonsByTmdbEpisodeMatch(
  VideoMetadataWork primary,
  VideoMetadataWork? tmdb, {
  Set<int> skipSeasons = const <int>{},
  String? preferredLanguage,
  Map<(int, int), List<String>> candidateAliases =
      const <(int, int), List<String>>{},
}) {
  final Map<(int, int), TmdbEpisodeMatchRating> ratings =
      <(int, int), TmdbEpisodeMatchRating>{};
  if (tmdb == null || primary.seasons.isEmpty) {
    return (work: primary, ratings: ratings);
  }
  final List<VideoMetadataEpisode> pool = _unusedTmdbEpisodes(primary, tmdb);
  if (pool.isEmpty) return (work: primary, ratings: ratings);
  final bool preferSupplementTitle = _preferSupplementTitle(
    primary.provider,
    tmdb.provider,
    preferredLanguage,
  );
  final List<VideoMetadataSeason> seasons = <VideoMetadataSeason>[];
  for (final VideoMetadataSeason season in primary.seasons) {
    if (skipSeasons.contains(season.seasonNumber) ||
        season.seasonNumber == 0 ||
        season.episodes.isEmpty) {
      seasons.add(season);
      continue;
    }
    // 已经带 TMDB 分集 id 的集（同季号时 [_mergeSeasons] 按集号并上的）不再
    // 参与匹配，否则会被重配到别的 TMDB 集。
    final List<TmdbEpisodeMatchSource> sources = <TmdbEpisodeMatchSource>[
      for (final VideoMetadataEpisode episode in season.episodes)
        if (_tmdbEpisodeKeys(episode).isEmpty)
          TmdbEpisodeMatchSource(
            number: episode.episodeNumber,
            titles: <String>[episode.title],
            airDate: episode.airDate,
          ),
    ];
    final Map<int, TmdbEpisodeMatch> matches = sources.isEmpty
        ? const <int, TmdbEpisodeMatch>{}
        : matchEpisodesToTmdb(sources, pool,
            candidateAliases: candidateAliases);
    if (matches.isEmpty) {
      seasons.add(season);
      continue;
    }
    final Set<String> taken = <String>{};
    seasons.add(season.copyWith(
      episodes: <VideoMetadataEpisode>[
        for (final VideoMetadataEpisode episode in season.episodes)
          if (matches[episode.episodeNumber] case final TmdbEpisodeMatch match)
            () {
              ratings[(season.seasonNumber, episode.episodeNumber)] =
                  match.rating;
              taken.addAll(_tmdbEpisodeKeys(match.episode));
              return _mergeEpisode(
                episode,
                _renumberEpisode(
                    match.episode, season.seasonNumber, episode.episodeNumber),
                preferSupplementTitle: preferSupplementTitle,
              );
            }()
          else
            episode,
      ],
    ));
    pool.removeWhere((VideoMetadataEpisode episode) =>
        _tmdbEpisodeKeys(episode).any(taken.contains));
  }
  return (
    work: ratings.isEmpty ? primary : primary.copyWith(seasons: seasons),
    ratings: ratings,
  );
}

/// Shoko 主路径（AniDB 集 → TMDB 集）在本仓的形态：MAL cour 季**一集都没有**
/// （Jikan 对播出中的作品常给 0 集）又没有映射表切片时，用本地文件的 AniDB 文件
/// 身份里的集标题（英/罗马字/日文三种）在 TMDB 正片池里逐集找对应，对上的
/// TMDB 集按 **AniDB 集号** 落成该季的分集。集号本身不做跨站推断——只有标题
/// 核对通过的那几集才落，集号只是「这一集在 cour 里排第几」的位置。
///
/// [sourcesBySeason]：卡片季号 → 来源集（`number` = AniDB epno，`titles` =
/// AniDB 集标题）。已有分集的季不动。
TmdbEpisodeMatchOutcome fillEmptySeasonsFromEpisodeTitles(
  VideoMetadataWork primary,
  VideoMetadataWork? tmdb,
  Map<int, List<TmdbEpisodeMatchSource>> sourcesBySeason, {
  Map<(int, int), List<String>> candidateAliases =
      const <(int, int), List<String>>{},
}) {
  final Map<(int, int), TmdbEpisodeMatchRating> ratings =
      <(int, int), TmdbEpisodeMatchRating>{};
  if (tmdb == null || sourcesBySeason.isEmpty || primary.seasons.isEmpty) {
    return (work: primary, ratings: ratings);
  }
  final List<VideoMetadataEpisode> pool = _unusedTmdbEpisodes(primary, tmdb);
  if (pool.isEmpty) return (work: primary, ratings: ratings);
  final List<VideoMetadataSeason> seasons = <VideoMetadataSeason>[];
  for (final VideoMetadataSeason season in primary.seasons) {
    final List<TmdbEpisodeMatchSource>? sources =
        sourcesBySeason[season.seasonNumber];
    if (sources == null ||
        sources.isEmpty ||
        season.seasonNumber == 0 ||
        season.episodes.isNotEmpty) {
      seasons.add(season);
      continue;
    }
    final Map<int, TmdbEpisodeMatch> matches = Map<int, TmdbEpisodeMatch>.of(
        matchEpisodesToTmdb(sources, pool, candidateAliases: candidateAliases))
      // 这条路径的输入是 AniDB 文件身份的集标题、输出是「按 AniDB 集号落进 TMDB
      // 集」——只有标题真核对过的才能落。`firstAvailable` 是季锁定后的顺序兜底，
      // 标题没对上；Shoko 把它交用户核对界面，本仓没有那个界面，落库就是把错的
      // 剧照/简介静默写进分集行（「AniDB 集号不能未经验证套到 TMDB 集号」）。
      ..removeWhere((int _, TmdbEpisodeMatch match) =>
          match.rating == TmdbEpisodeMatchRating.firstAvailable);
    if (matches.isEmpty) {
      seasons.add(season);
      continue;
    }
    final Set<String> taken = <String>{};
    final List<VideoMetadataEpisode> episodes = <VideoMetadataEpisode>[
      for (final MapEntry<int, TmdbEpisodeMatch> entry in matches.entries)
        () {
          ratings[(season.seasonNumber, entry.key)] = entry.value.rating;
          taken.addAll(_tmdbEpisodeKeys(entry.value.episode));
          return _renumberEpisode(
              entry.value.episode, season.seasonNumber, entry.key);
        }(),
    ]..sort((VideoMetadataEpisode a, VideoMetadataEpisode b) =>
        a.episodeNumber.compareTo(b.episodeNumber));
    seasons.add(season.copyWith(episodes: episodes));
    pool.removeWhere((VideoMetadataEpisode episode) =>
        _tmdbEpisodeKeys(episode).any(taken.contains));
  }
  return (
    work: ratings.isEmpty ? primary : primary.copyWith(seasons: seasons),
    ratings: ratings,
  );
}

/// 一条「AniDB 集 → TMDB 集」链接：Shoko `CrossRef_AniDB_TMDB_Episode` 在本仓
/// 的即时形态（不落独立表——输入都在本地缓存里，重算是确定性的；落库的是
/// 成员最终绑到的分集行）。
class AnidbTmdbEpisodeLink {
  const AnidbTmdbEpisodeLink({
    required this.anidbEpisodeNumber,
    required this.tmdbEpisode,
    required this.rating,
    required this.cardKey,
  });

  /// AniDB 正片集号（epno）。
  final int anidbEpisodeNumber;

  /// 对上的 TMDB 集（**TMDB 自己的** 季/集号，未重编）。
  final VideoMetadataEpisode tmdbEpisode;
  final TmdbEpisodeMatchRating rating;

  /// 这一集在本卡片里的 (季, 集)；null = TMDB 那一季在卡片里没有对应（映射表
  /// 没给切片、卡片也没那一季），链接成立但落不下来。
  final (int, int)? cardKey;
}

/// [linkAnidbEpisodesToTmdb] 的结果：可能补了分集的作品 + 每个 AniDB 正片集号的
/// 链接 + 每个 AniDB 特典序号（`S3` → 3）的链接（落在卡片第 0 季）。
typedef AnidbEpisodeLinkOutcome = ({
  VideoMetadataWork work,
  Map<int, AnidbTmdbEpisodeLink> links,
  Map<int, AnidbTmdbEpisodeLink> specialLinks,
});

/// Shoko `MatchAnidbToTmdbEpisodes` 的主路径：本地文件的 AniDB 集身份（集号 +
/// 三语集标题 + 播出日）在 TMDB 剧**全部**正片季里逐集找对应，文件名给的季集
/// 不参与。对上的 TMDB 集再换算成本卡片的 (季, 集)：
///  1. 主源就是 TMDB → 卡片季 = TMDB 季，直接用；
///  2. 卡片里某一集已带这条 TMDB 分集 id（切片 / 合并 / 标题匹配时并进来的）
///     → 用那一集的 (季, 集)；
///  3. 映射表切片 [slices]（卡片季 → TMDB 第 S 季从第 O+1 集起）能覆盖 → 卡片
///     季 = 该切片、集 = TMDB 集号 − O，并把这条 TMDB 集补进卡片那一季（已有
///     同号集只补空）；
///  4. 都不行 → [AnidbTmdbEpisodeLink.cardKey] 为 null，调用方记说明。
///
/// `firstAvailable`（季锁定后的顺序兜底，标题/日期都没核对）**照样成链**——
/// Shoko `MatchAnidbToTmdbEpisodes` 第四遍「every match is accepted」，评级随
/// 链接落进分集行 `anidb_match_rating` 并在识别说明里标「顺序兜底」，用户能看出
/// 哪几集是猜的。[fillEmptySeasonsFromEpisodeTitles] 的输入不是文件身份，仍然丢弃。
AnidbEpisodeLinkOutcome linkAnidbEpisodesToTmdb(
  VideoMetadataWork primary,
  VideoMetadataWork? tmdb,
  List<TmdbEpisodeMatchSource> sources, {
  List<TmdbEpisodeMatchSource> specialSources =
      const <TmdbEpisodeMatchSource>[],
  Map<int, TmdbSeasonSlice> slices = const <int, TmdbSeasonSlice>{},
  Map<(int, int), List<String>> candidateAliases =
      const <(int, int), List<String>>{},
  String? preferredLanguage,
  Set<(int, int)> reservedCardKeys = const <(int, int)>{},
}) {
  final Map<int, AnidbTmdbEpisodeLink> links = <int, AnidbTmdbEpisodeLink>{};
  final Map<int, AnidbTmdbEpisodeLink> specialLinks =
      <int, AnidbTmdbEpisodeLink>{};
  AnidbEpisodeLinkOutcome none() =>
      (work: primary, links: links, specialLinks: specialLinks);
  final VideoMetadataWork? show =
      primary.provider == VideoMetadataProviderKind.tmdb ? primary : tmdb;
  if (show == null || (sources.isEmpty && specialSources.isEmpty)) {
    return none();
  }
  final bool tmdbPrimary = identical(show, primary);
  // 卡片里已带 TMDB 分集 id 的集：`tmdb:<id>` → (季, 集)。
  final Map<String, (int, int)> cardKeyByTmdbId = <String, (int, int)>{
    for (final VideoMetadataSeason season in primary.seasons)
      for (final VideoMetadataEpisode episode in season.episodes)
        for (final String key in _tmdbEpisodeKeys(episode))
          key: (season.seasonNumber, episode.episodeNumber),
  };
  // 一条 TMDB 集会落到卡片的哪个 (季, 集)（与下面成链时的换算同一口径）；
  // 用户钉死（UserVerified）的键从候选池里移除——Shoko 同样把已 UserVerified
  // 的 TMDB 集从候选里剔掉，自动链接不得抢用户钉的格。
  (int, int)? cardKeyOf(VideoMetadataEpisode tmdbEpisode) {
    if (tmdbPrimary) {
      return (tmdbEpisode.seasonNumber, tmdbEpisode.episodeNumber);
    }
    for (final String key in _tmdbEpisodeKeys(tmdbEpisode)) {
      if (cardKeyByTmdbId[key] case final (int, int) cardKey) return cardKey;
    }
    return _cardKeyFromSlices(primary, tmdbEpisode, slices);
  }

  final List<VideoMetadataEpisode> pool = <VideoMetadataEpisode>[
    for (final VideoMetadataSeason season in show.seasons)
      for (final VideoMetadataEpisode episode in season.episodes)
        if (reservedCardKeys.isEmpty ||
            !reservedCardKeys.contains(cardKeyOf(episode)))
          episode,
  ];
  if (pool.isEmpty) return none();
  final Map<int, TmdbEpisodeMatch> matches = sources.isEmpty
      ? const <int, TmdbEpisodeMatch>{}
      : matchEpisodesToTmdb(sources, pool, candidateAliases: candidateAliases);
  final Map<int, TmdbEpisodeMatch> specialMatches = specialSources.isEmpty
      ? const <int, TmdbEpisodeMatch>{}
      : matchSpecialsToTmdb(specialSources, pool,
          candidateAliases: candidateAliases);
  if (matches.isEmpty && specialMatches.isEmpty) return none();

  final bool preferSupplementTitle = _preferSupplementTitle(
    primary.provider,
    show.provider,
    preferredLanguage,
  );
  // 待补进卡片季的 TMDB 集（已重编成卡片 (季, 集)）。
  final Map<int, List<VideoMetadataEpisode>> inserts =
      <int, List<VideoMetadataEpisode>>{};
  for (final MapEntry<int, TmdbEpisodeMatch> entry in matches.entries) {
    final VideoMetadataEpisode tmdbEpisode = entry.value.episode;
    (int, int)? cardKey;
    if (tmdbPrimary) {
      cardKey = (tmdbEpisode.seasonNumber, tmdbEpisode.episodeNumber);
    } else {
      for (final String key in _tmdbEpisodeKeys(tmdbEpisode)) {
        cardKey = cardKeyByTmdbId[key];
        if (cardKey != null) break;
      }
      if (cardKey == null) {
        final (int, int)? sliced =
            _cardKeyFromSlices(primary, tmdbEpisode, slices);
        if (sliced != null) {
          cardKey = sliced;
          (inserts[sliced.$1] ??= <VideoMetadataEpisode>[])
              .add(_renumberEpisode(tmdbEpisode, sliced.$1, sliced.$2));
        }
      }
    }
    links[entry.key] = AnidbTmdbEpisodeLink(
      anidbEpisodeNumber: entry.key,
      tmdbEpisode: tmdbEpisode,
      rating: entry.value.rating,
      cardKey: cardKey,
    );
  }
  // 特典：TMDB 第 0 季就是卡片第 0 季（补充源整季并进来的 / TMDB 主源自带），
  // 卡片键 = (0, TMDB 集号)；卡片里没有第 0 季就先建一季只放对上的这几集。
  final bool hasSeasonZero =
      primary.seasons.any((VideoMetadataSeason s) => s.seasonNumber == 0);
  for (final MapEntry<int, TmdbEpisodeMatch> entry in specialMatches.entries) {
    final VideoMetadataEpisode tmdbEpisode = entry.value.episode;
    final (int, int) cardKey = (0, tmdbEpisode.episodeNumber);
    specialLinks[entry.key] = AnidbTmdbEpisodeLink(
      anidbEpisodeNumber: entry.key,
      tmdbEpisode: tmdbEpisode,
      rating: entry.value.rating,
      cardKey: cardKey,
    );
    final bool present = tmdbPrimary ||
        _tmdbEpisodeKeys(tmdbEpisode).any(cardKeyByTmdbId.containsKey);
    if (!present) {
      (inserts[0] ??= <VideoMetadataEpisode>[]).add(tmdbEpisode);
    }
  }
  if (inserts.isEmpty) {
    return (work: primary, links: links, specialLinks: specialLinks);
  }
  final List<VideoMetadataSeason> seasons = <VideoMetadataSeason>[
    for (final VideoMetadataSeason season in primary.seasons)
      if (inserts[season.seasonNumber] case final List<VideoMetadataEpisode> add)
        season.copyWith(
          episodes: _mergeEpisodes(
            season.episodes,
            add,
            preferSupplementTitle: preferSupplementTitle,
          ),
        )
      else
        season,
    if (!hasSeasonZero)
      if (inserts[0] case final List<VideoMetadataEpisode> add)
        VideoMetadataSeason(
        seasonNumber: 0,
        title: show.seasons
                .where((VideoMetadataSeason s) => s.seasonNumber == 0)
                .firstOrNull
                ?.title ??
            'Specials',
        episodes: _mergeEpisodes(
          const <VideoMetadataEpisode>[],
          add,
          preferSupplementTitle: preferSupplementTitle,
        ),
      ),
  ]..sort((VideoMetadataSeason a, VideoMetadataSeason b) =>
      a.seasonNumber.compareTo(b.seasonNumber));
  return (
    work: primary.copyWith(seasons: seasons),
    links: links,
    specialLinks: specialLinks,
  );
}

/// 按映射表切片把 TMDB (季, 集) 换算成卡片 (季, 集)：同一 TMDB 季里偏移最大且
/// 仍小于集号的切片；卡片那一季必须已存在（补集只补进已有的季），已知集数时
/// 集号还要落得进去。都不满足返回 null。
(int, int)? _cardKeyFromSlices(
  VideoMetadataWork primary,
  VideoMetadataEpisode tmdbEpisode,
  Map<int, TmdbSeasonSlice> slices,
) {
  int? bestSeason;
  int bestOffset = -1;
  for (final MapEntry<int, TmdbSeasonSlice> entry in slices.entries) {
    final TmdbSeasonSlice slice = entry.value;
    if (slice.tmdbSeason != tmdbEpisode.seasonNumber ||
        slice.offset >= tmdbEpisode.episodeNumber ||
        slice.offset <= bestOffset) {
      continue;
    }
    bestSeason = entry.key;
    bestOffset = slice.offset;
  }
  if (bestSeason == null) return null;
  final int episodeNumber = tmdbEpisode.episodeNumber - bestOffset;
  for (final VideoMetadataSeason season in primary.seasons) {
    if (season.seasonNumber != bestSeason) continue;
    final int? count = season.episodeCount;
    if (count != null && count > 0 && episodeNumber > count) return null;
    return (bestSeason, episodeNumber);
  }
  return null;
}

/// [tmdb] 的全部分集，去掉已经出现在 [primary] 某一季里的（按 TMDB 分集 id）。
List<VideoMetadataEpisode> _unusedTmdbEpisodes(
  VideoMetadataWork primary,
  VideoMetadataWork tmdb,
) {
  final Set<String> used = <String>{
    for (final VideoMetadataSeason season in primary.seasons)
      for (final VideoMetadataEpisode episode in season.episodes)
        ..._tmdbEpisodeKeys(episode),
  };
  return <VideoMetadataEpisode>[
    for (final VideoMetadataSeason season in tmdb.seasons)
      for (final VideoMetadataEpisode episode in season.episodes)
        if (!_tmdbEpisodeKeys(episode).any(used.contains)) episode,
  ];
}

Iterable<String> _tmdbEpisodeKeys(VideoMetadataEpisode episode) => <String>[
      for (final VideoMetadataId id in episode.ids)
        if (id.type.toLowerCase() == 'tmdb') 'tmdb:${id.value.trim()}',
    ];

/// 把一条 TMDB 集改成目标 (季, 集) 编号（含剧照的季/集号）。
VideoMetadataEpisode _renumberEpisode(
  VideoMetadataEpisode episode,
  int seasonNumber,
  int episodeNumber,
) =>
    episode.copyWith(
      seasonNumber: seasonNumber,
      episodeNumber: episodeNumber,
      images: <VideoMetadataImage>[
        for (final VideoMetadataImage image in episode.images)
          image.copyWith(
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
          ),
      ],
    );

List<VideoMetadataSeason> _mergeSeasons(
  Iterable<VideoMetadataSeason> primary,
  Iterable<VideoMetadataSeason> supplement, {
  bool preferSupplementTitle = false,
  VideoMetadataCreditNameBridge creditNames =
      VideoMetadataCreditNameBridge.none,
}) {
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
    result.add(matching == null
        ? season
        : _mergeSeason(
            season,
            matching,
            preferSupplementTitle: preferSupplementTitle,
            creditNames: creditNames,
          ));
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
  VideoMetadataSeason supplement, {
  required bool preferSupplementTitle,
  VideoMetadataCreditNameBridge creditNames =
      VideoMetadataCreditNameBridge.none,
}) =>
    primary.copyWith(
      plot: primary.plot ?? supplement.plot,
      airDate: primary.airDate ?? supplement.airDate,
      year: primary.year ?? supplement.year,
      episodeCount: primary.episodeCount ?? supplement.episodeCount,
      rating: primary.rating ?? supplement.rating,
      ids: _mergeIds(primary.ids, supplement.ids),
      images: _mergeImagesFillingMissing(primary.images, supplement.images),
      episodes: _mergeEpisodes(
        primary.episodes,
        supplement.episodes,
        preferSupplementTitle: preferSupplementTitle,
        creditNames: creditNames,
      ),
    );

List<VideoMetadataEpisode> _mergeEpisodes(
  Iterable<VideoMetadataEpisode> primary,
  Iterable<VideoMetadataEpisode> supplement, {
  required bool preferSupplementTitle,
  VideoMetadataCreditNameBridge creditNames =
      VideoMetadataCreditNameBridge.none,
}) {
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
    result.add(matching == null
        ? episode
        : _mergeEpisode(
            episode,
            matching,
            preferSupplementTitle: preferSupplementTitle,
            creditNames: creditNames,
          ));
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
  VideoMetadataEpisode supplement, {
  required bool preferSupplementTitle,
  VideoMetadataCreditNameBridge creditNames =
      VideoMetadataCreditNameBridge.none,
}) =>
    primary.copyWith(
      // 分集名与作品名同一条语言规则：作品标题换了译名，分集名不能还留原文——
      // 分集名会写穿进 video_books.title，显示层撤不回来。
      title: preferSupplementTitle && !_isBlank(supplement.title)
          ? supplement.title
          : primary.title,
      plot: primary.plot ?? supplement.plot,
      airDate: primary.airDate ?? supplement.airDate,
      year: primary.year ?? supplement.year,
      absoluteNumber: primary.absoluteNumber ?? supplement.absoluteNumber,
      rating: primary.rating ?? supplement.rating,
      ratingVotes: primary.ratingVotes ?? supplement.ratingVotes,
      runtimeMinutes: primary.runtimeMinutes ?? supplement.runtimeMinutes,
      ids: _mergeIds(primary.ids, supplement.ids),
      credits: mergeVideoMetadataCredits(
        primary.credits,
        supplement.credits,
        names: creditNames,
      ),
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

/// 人物关系并集：主表原序保留，补充表里同一条关系（同人、同角色、同类）只往
/// 主条目补空（照片、id、原名、简介），新关系追加到尾部。
///
/// 「同一条关系」跨源判定（BUG-2612 / BUG-2795）：
///  - 类别：actor / voiceActor 同组（MAL 声优是 `voiceActor`，TMDB 动画演员是
///    `actor`）；导演 / 编剧等职员按 kind 各自成组，不会被误并。
///  - 人名：比较 `name` 与 `originalName` 两个写法，**任一**相同即同一人——MAL
///    「Suzuki, Aina」与 TMDB `original_name`「Aina Suzuki」按词集合相同；汉字 /
///    假名名去空白与间隔号后比较（「鈴木 愛奈」=「鈴木愛奈」）。
///  - 角色：比较角色名 / 角色原名 / 去掉配音后缀的 roleName；两边角色名写法可比
///    （同一书写系统）却不相同 → 同一声优的另一个角色，不合并；写法不可比（英文
///    罗马字 vs 汉字假名）→ 由人名身份决定。
///
/// **身份不可判定时不追加**：补充条目与主表同组条目的人名没有任何共同书写系统
/// （MAL 只给罗马字「Suzuki, Aina」、TMDB 只给「鈴木愛奈」），那就既对不上、也
/// 没法证明是另一个人——追加就是同一批声优出现两遍。此时只保留主表（Jellyfin
/// `MergePeople` 同样只补已匹配的人）。主表该组为空时照旧整组补进来。
///
/// **写法桥**（[names]）：第三个来源的一条人物若同时带罗马字与原文名（AniList
/// `name.full` + `name.native`），这两个写法就是同一个人。把各来源这类等价关系
/// 预先收成 [VideoMetadataCreditNameBridge] 传进来，两边的人名 / 角色名都按等价
/// 类展开后再比——MAL 只有「Suzuki, Aina」、TMDB 只有「鈴木愛奈」也能认成同一人，
/// 并入主条目补齐照片与外部 id。没有桥时行为与上面一致。
List<VideoMetadataCredit> mergeVideoMetadataCredits(
  Iterable<VideoMetadataCredit> primary,
  Iterable<VideoMetadataCredit> supplement, {
  VideoMetadataCreditNameBridge names = VideoMetadataCreditNameBridge.none,
}) {
  final List<VideoMetadataCredit> result = primary.toList();
  final List<_CreditIdentity> identities = <_CreditIdentity>[
    for (final VideoMetadataCredit credit in result)
      _CreditIdentity.of(credit, names),
  ];
  final Map<String, Set<_NameScript>> primaryScriptsByGroup =
      <String, Set<_NameScript>>{};
  for (final _CreditIdentity identity in identities) {
    primaryScriptsByGroup
        .putIfAbsent(identity.group, () => <_NameScript>{})
        .addAll(identity.nameScripts);
  }
  // 追加条目的 order 接在主表之后：补充表（第二 cour / TMDB 汇总）各自从 0 起，
  // 落库后读侧 ORDER BY sortOrder 会让第二季配角与第一季主角交错。
  int nextOrder = result.isEmpty
      ? 0
      : result.map((VideoMetadataCredit c) => c.order).reduce(max) + 1;
  for (final VideoMetadataCredit credit in supplement) {
    final _CreditIdentity identity = _CreditIdentity.of(credit, names);
    final int existingIndex = identities.indexWhere(identity.sameCreditAs);
    if (existingIndex >= 0) {
      result[existingIndex] = _mergeCredit(result[existingIndex], credit);
      continue;
    }
    if (!identity.comparableWithGroup(primaryScriptsByGroup[identity.group])) {
      continue;
    }
    identities.add(identity);
    result.add(credit.copyWith(order: nextOrder++));
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

/// 名字的书写系统：只用来判断两个写法「能不能比」，不做转写。
enum _NameScript { latin, han, hangul }

final RegExp _latinLetter = RegExp(r'[A-Za-z\u00C0-\u024F]');
final RegExp _hanOrKana = RegExp(
    r'[\u3040-\u30FF\u31F0-\u31FF\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]');
final RegExp _hangul = RegExp(r'[\u1100-\u11FF\u3130-\u318F\uAC00-\uD7AF]');
final RegExp _cjkNameSeparators = RegExp(r'[\s,，、・·･=＝]+');
final RegExp _latinNameSeparators = RegExp(r'[,\s]+');

Set<_NameScript> _scriptsOf(String value) => <_NameScript>{
      if (_latinLetter.hasMatch(value)) _NameScript.latin,
      if (_hanOrKana.hasMatch(value)) _NameScript.han,
      if (_hangul.hasMatch(value)) _NameScript.hangul,
    };

/// 单个写法的比较键：汉字 / 假名 / 谚文名去掉空白与间隔号（「鈴木 愛奈」=
/// 「鈴木愛奈」，并按 [TitleNormalizer] 折叠繁简 / 全半角）；拉丁名按词集合比较
/// （「Hanae, Natsuki」= 「Natsuki Hanae」）。配音后缀先剥掉。
String _nameKey(String value) {
  final String trimmed = stripVoiceRoleSuffix(value);
  if (trimmed.isEmpty) return '';
  if (_hanOrKana.hasMatch(trimmed) || _hangul.hasMatch(trimmed)) {
    return TitleNormalizer.normalize(trimmed)
        .replaceAll(_cjkNameSeparators, '');
  }
  final List<String> words = trimmed
      .toLowerCase()
      .split(_latinNameSeparators)
      .where((String word) => word.isNotEmpty)
      .toList()
    ..sort();
  return words.join(' ');
}

Set<String> _nameKeys(Iterable<String?> values) => <String>{
      for (final String? value in values)
        if (value != null) _nameKey(value),
    }..remove('');

Set<_NameScript> _nameScriptsOf(Iterable<String?> values) => <_NameScript>{
      for (final String? value in values)
        if (value != null) ..._scriptsOf(value),
    };

/// 一条人物关系的跨源身份：类别组 + 人名全部写法 + 角色名全部写法。
class _CreditIdentity {
  _CreditIdentity._({
    required this.group,
    required this.names,
    required this.nameScripts,
    required this.characters,
    required this.characterScripts,
  });

  /// 人名 / 角色名各自按 [bridge] 的等价类展开；书写系统 = 原始写法的系统 ∪
  /// 桥带进来的写法的系统（没有桥时与只看原始写法完全一致）。
  factory _CreditIdentity.of(
    VideoMetadataCredit credit,
    VideoMetadataCreditNameBridge bridge,
  ) {
    final List<String?> names = _personNames(credit);
    final List<String?> characters = _characterNames(credit);
    final Set<String> nameKeys = _nameKeys(names);
    final Set<String> characterKeys = _nameKeys(characters);
    final Set<String> bridgedNames = bridge._expandPerson(nameKeys);
    final Set<String> bridgedCharacters = bridge._expandCharacter(
      characterKeys,
    );
    return _CreditIdentity._(
      group: switch (credit.kind) {
        VideoMetadataCreditKind.actor ||
        VideoMetadataCreditKind.voiceActor =>
          'cast',
        _ => credit.kind.name,
      },
      names: bridgedNames,
      nameScripts: <_NameScript>{
        ..._nameScriptsOf(names),
        ..._nameScriptsOf(bridgedNames.difference(nameKeys)),
      },
      characters: bridgedCharacters,
      characterScripts: <_NameScript>{
        ..._nameScriptsOf(characters),
        ..._nameScriptsOf(bridgedCharacters.difference(characterKeys)),
      },
    );
  }

  final String group;
  final Set<String> names;
  final Set<_NameScript> nameScripts;
  final Set<String> characters;
  final Set<_NameScript> characterScripts;

  bool sameCreditAs(_CreditIdentity other) =>
      group == other.group &&
      names.intersection(other.names).isNotEmpty &&
      _sameCharacterAs(other);

  /// 人名已确认同一人之后的角色判定：任一边没有角色 → 缺角色不构成「另一个
  /// 角色」的证据；有共同写法 → 同一角色；写法可比却不同 → 同一声优的另一个
  /// 角色；写法不可比 → 无法反证，按同一条关系合并（只补空，不改主表字段）。
  bool _sameCharacterAs(_CreditIdentity other) {
    if (characters.isEmpty || other.characters.isEmpty) return true;
    if (characters.intersection(other.characters).isNotEmpty) return true;
    return characterScripts.intersection(other.characterScripts).isEmpty;
  }

  /// 没匹配上的补充条目能否证明是「另一个人」：主表同组为空（只补空），或人名
  /// 与主表同组有共同书写系统（写法可比仍对不上）才算；否则身份不可判定。
  bool comparableWithGroup(Set<_NameScript>? groupScripts) {
    if (groupScripts == null || groupScripts.isEmpty || nameScripts.isEmpty) {
      return true;
    }
    return groupScripts.intersection(nameScripts).isNotEmpty;
  }
}

List<String?> _personNames(VideoMetadataCredit credit) => <String?>[
      credit.person.name,
      credit.person.originalName,
    ];

List<String?> _characterNames(VideoMetadataCredit credit) => <String?>[
      credit.roleName,
      credit.character?.name,
      credit.character?.originalName,
    ];

/// 「同一人 / 同一角色的全部已知写法」等价类，合并**之前**从所有来源一次收齐。
///
/// 一条人物关系自己带的几个写法（AniList `name.full` 罗马字 + `name.native`
/// 原文、TMDB `name` 译名 + `original_name`）就是同一个人的证据；这些证据跨条目
/// 按共同写法连通成等价类。合并时两边的名字都按等价类展开再比，于是 MAL 只有
/// 罗马字、TMDB 只有汉字也能经 AniList 认成同一人。先收集再合并，身份判定与
/// 来源合并顺序无关。
///
/// **有歧义的类不当桥**：一个类里出现两个没有任何条目直接并列过的原文（汉字 /
/// 假名 / 谚文）写法，说明罗马字同名的两个人被连到了一起（「Yuu Kobayashi」=
/// 小林ゆう / 小林優），这时整类不用——退回无桥行为（不追加证明不了的重复，也
/// 不误合并）。同一条目里并列的原文写法（TMDB 译名 + `original_name`）与罗马字
/// 拼法变体（Yu / Yuu）不算歧义。
class VideoMetadataCreditNameBridge {
  const VideoMetadataCreditNameBridge._(this._people, this._characters);

  /// 没有任何跨源写法证据：合并只按两边各自的写法比对。
  static const VideoMetadataCreditNameBridge none =
      VideoMetadataCreditNameBridge._(
    <String, Set<String>>{},
    <String, Set<String>>{},
  );

  /// 从全部来源的作品级与分集级人物关系收集写法等价类。
  factory VideoMetadataCreditNameBridge.fromWorks(
    Iterable<VideoMetadataWork> works,
  ) =>
      VideoMetadataCreditNameBridge.fromCredits(<VideoMetadataCredit>[
        for (final VideoMetadataWork work in works) ...<VideoMetadataCredit>[
          ...work.credits,
          for (final VideoMetadataSeason season in work.seasons)
            for (final VideoMetadataEpisode episode in season.episodes)
              ...episode.credits,
        ],
      ]);

  factory VideoMetadataCreditNameBridge.fromCredits(
    Iterable<VideoMetadataCredit> credits,
  ) {
    final _NameKeyUnion people = _NameKeyUnion();
    final _NameKeyUnion characters = _NameKeyUnion();
    for (final VideoMetadataCredit credit in credits) {
      people.join(_nameKeys(_personNames(credit)));
      characters.join(_nameKeys(_characterNames(credit)));
    }
    return VideoMetadataCreditNameBridge._(
      people.unambiguousClasses(),
      characters.unambiguousClasses(),
    );
  }

  /// 写法键 → 它所在的等价类（含自身）；不在任何类里的键不出现。
  final Map<String, Set<String>> _people;
  final Map<String, Set<String>> _characters;

  Set<String> _expandPerson(Set<String> keys) => _expand(_people, keys);

  Set<String> _expandCharacter(Set<String> keys) => _expand(_characters, keys);

  static Set<String> _expand(
    Map<String, Set<String>> classes,
    Set<String> keys,
  ) =>
      <String>{...keys, for (final String key in keys) ...?classes[key]};
}

/// 字符串并查集。
class _KeyUnion {
  final Map<String, String> parent = <String, String>{};

  String root(String key) {
    String node = key;
    for (String? up = parent[node]; up != null; up = parent[node]) {
      node = up;
    }
    return node;
  }

  void union(Iterable<String> keys) {
    if (keys.length < 2) return;
    final String anchor = root(keys.first);
    for (final String key in keys.skip(1)) {
      final String other = root(key);
      if (other != anchor) parent[other] = anchor;
    }
  }
}

/// 写法键的等价类收集：[_all] 连通全部写法；[_native] 只连「同一条目里直接
/// 并列」的原文写法（TMDB zh 的「铃木爱奈」+ `original_name`「鈴木愛奈」是同一
/// 人的直接证据）。一个类里的原文写法若分属两个以上 [_native] 组，就只是经
/// 罗马字同名间接连上的两个人——有歧义。
class _NameKeyUnion {
  final _KeyUnion _all = _KeyUnion();
  final _KeyUnion _native = _KeyUnion();

  /// 同一条目的全部写法并成一类。
  void join(Set<String> keys) {
    _all.union(keys);
    _native.union(keys.where(_isNativeKey).toList());
  }

  /// 每个键映射到所在类；原文写法分属多个直接证据组的类有歧义，丢弃。
  Map<String, Set<String>> unambiguousClasses() {
    final Map<String, Set<String>> byRoot = <String, Set<String>>{};
    for (final String key in _all.parent.keys) {
      final String root = _all.root(key);
      byRoot.putIfAbsent(root, () => <String>{root}).add(key);
    }
    return <String, Set<String>>{
      for (final Set<String> members in byRoot.values)
        if (members.where(_isNativeKey).map(_native.root).toSet().length <= 1)
          for (final String key in members) key: members,
    };
  }
}

bool _isNativeKey(String key) =>
    _hanOrKana.hasMatch(key) || _hangul.hasMatch(key);

/// TMDB 给配音角色的名字带 `(voice)` 后缀（「Frieren (voice)」），Shoko 入库
/// 时同样剥掉；这里给合并 key 与 provider 共用。
String stripVoiceRoleSuffix(String role) =>
    role.replaceFirst(_voiceRoleSuffix, '').trim();

final RegExp _voiceRoleSuffix =
    RegExp(r'\s*\(voice\)\s*$', caseSensitive: false);

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
/// 每类图保留几张（Shoko `TMDB.MaxAuto*`）：[maxPerKind] 没给的图种 1 张，
/// 0 = 不限；分集剧照（`thumb`）恒 1（Shoko `MaxAutoThumbnails = 1`）。
///
/// [mainLanguage]（作品原语，Shoko 图片语言序里的 `Main` 槽）插到 [languageOrder]
/// 的资料语言之后、英文之前：用户资料语言的图仍最先，其次是片子原语的图，再
/// 英文、再无字图——与 Shoko `[None, Main, English]` 相比多了「资料语言在前」这一
/// 层，这是本仓已定的产品行为（BUG：用户设 ja 却拿到中文海报）。同一 URL 只算
/// 一张（TMDB 详情的 `poster_path` 与 `images.posters` 会重复）。
List<VideoMetadataImage> selectVideoMetadataImages({
  required Iterable<VideoMetadataImage> primary,
  required List<String> languageOrder,
  Map<VideoMetadataImageKind, int> maxPerKind =
      const <VideoMetadataImageKind, int>{VideoMetadataImageKind.backdrop: 3},
  String? mainLanguage,
}) {
  final List<String> order = imageLanguageOrderWithMain(languageOrder,
      mainLanguage: mainLanguage);
  final Map<String, List<VideoMetadataImage>> primaryGroups = _groupImages(
    primary,
  );
  final List<VideoMetadataImage> selected = <VideoMetadataImage>[];
  for (final List<VideoMetadataImage> group in primaryGroups.values) {
    if (group.isEmpty) continue;
    final Set<String> seenUrls = <String>{};
    final List<VideoMetadataImage> preferred = <VideoMetadataImage>[
      for (final VideoMetadataImage image in group)
        if (seenUrls.add(image.url)) image,
    ]..sort((VideoMetadataImage a, VideoMetadataImage b) =>
        _compareImages(a, b, order));
    final VideoMetadataImageKind kind = preferred.first.kind;
    final int limit = kind == VideoMetadataImageKind.thumb
        ? 1
        : (maxPerKind[kind] ?? 1);
    selected.addAll(limit <= 0 ? preferred : preferred.take(limit));
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

/// 把作品原语（Shoko `Main`）插进图片语言序：资料语言之后、其余之前；已在序里
/// 或没给就原样返回。
List<String> imageLanguageOrderWithMain(
  List<String> languageOrder, {
  String? mainLanguage,
}) {
  final String main = mainLanguage?.trim().toLowerCase() ?? '';
  if (main.isEmpty ||
      languageOrder.any((String tag) => tag.toLowerCase() == main)) {
    return languageOrder;
  }
  if (languageOrder.isEmpty) return <String>[main];
  return <String>[languageOrder.first, main, ...languageOrder.skip(1)];
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
