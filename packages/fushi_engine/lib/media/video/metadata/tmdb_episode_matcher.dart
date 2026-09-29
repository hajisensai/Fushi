/// Shoko `TmdbLinkingService.MatchAnidbToTmdbEpisodes` 的 Dart 移植：把一组
/// 「来源集」（MAL cour 的分集，或 AniDB 文件身份里的集标题）逐集匹配到 TMDB
/// 剧的分集，**不做任何集号偏移算术**——只看标题相似度与播出日。
///
/// 与 Shoko 一致的部分：
///  - 候选池 = 全部非特典季的 TMDB 集；四轮从强到弱接受（`dateAndTitle` →
///    `title` → 除 `firstAvailable` 外全部 → 全部），每轮把已用掉的 TMDB 集移出池；
///  - 第二轮起把候选池收窄到已建立链接所在的季（`FilterToCurrentSeasons`）；
///  - 单集评分链 `TryExactTitleMatch → TryKindaTitleMatch → TryAirDateMatch →
///    TryAnyTitleMatch → TryNearestAirDateMatch(≤120 天) → FirstAvailable`；
///  - 弱评级相邻冒泡（`ReconcileEpisodeOrderInversions`）保证 TMDB (S,E) 顺序
///    与来源集号顺序一致。
///
/// 有意不同：`firstAvailable` 只在已有更强链接锁定了季之后才接受——Shoko 在
/// 一集都没对上时也会把 S1E1 起顺序填上去、交给用户核对；本仓没有那个核对
/// 界面，宁可留空交人工确认。
library;

import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/scraper/title_normalizer.dart';

/// 评级，按置信度从高到低（对应 Shoko `MatchRating`，去掉 `UserVerified`）。
enum TmdbEpisodeMatchRating {
  dateAndTitle,
  title,
  dateAndTitleKinda,
  date,
  titleKinda,
  dateKinda,
  firstAvailable,
  none,
}

/// 一条来源集：集号 + 可比较的标题（多语言都放进来）+ 播出日（`yyyy-MM-dd`）。
class TmdbEpisodeMatchSource {
  const TmdbEpisodeMatchSource({
    required this.number,
    required this.titles,
    this.airDate,
  });

  final int number;
  final List<String> titles;
  final String? airDate;
}

class TmdbEpisodeMatch {
  const TmdbEpisodeMatch({required this.episode, required this.rating});

  final VideoMetadataEpisode episode;
  final TmdbEpisodeMatchRating rating;
}

/// Shoko `MaxFallbackDifferenceInDays`。
const int kTmdbEpisodeMatchMaxFallbackDays = 120;

/// 逐集匹配。返回 `来源集号 → 匹配`，没对上的来源集不出现在结果里。
///
/// [tmdbEpisodes] 里 `seasonNumber == 0` 的特典不进候选池（来源集都是正片；
/// Shoko 对 AniDB 正片同样只在正片池里找）。
///
/// [candidateAliases]：`(季, 集) → 其它语言的集名`（Shoko 比的是 en-US + 原语，
/// 本仓 TMDB 常规 hydrate 只有资料语言一种，见 `VideoMetadataEpisodeAliasProvider`）。
Map<int, TmdbEpisodeMatch> matchEpisodesToTmdb(
  List<TmdbEpisodeMatchSource> sources,
  Iterable<VideoMetadataEpisode> tmdbEpisodes, {
  Map<(int, int), List<String>> candidateAliases =
      const <(int, int), List<String>>{},
}) =>
    _matchAgainstPool(
      sources,
      _pool(tmdbEpisodes, candidateAliases, specials: false),
      specials: false,
    );

/// 特典版：AniDB `S` 型集只在 TMDB 第 0 季池里找（Shoko `GetEpisodeList`：
/// `IsSpecialEpisode ? tmdbSpecialEpisodes : tmdbNormalEpisodes`），评分链到
/// `titleKinda` 为止——Shoko 对 special 关掉最近播出日（`!isSpecial &&
/// TryNearestAirDateMatch`）与顺序兜底（`!isSpecial && … FirstAvailable`）：
/// S0 是 OVA / 总集篇 / 短篇混排，与 AniDB `S` 序号无关，按序填进去只会错绑。
/// 来源集号是特典自己的序号（`S3` → 3）。C/T/P/O 型不进任何池（Shoko 同样只
/// 匹配 Episode + Special）。
Map<int, TmdbEpisodeMatch> matchSpecialsToTmdb(
  List<TmdbEpisodeMatchSource> sources,
  Iterable<VideoMetadataEpisode> tmdbEpisodes, {
  Map<(int, int), List<String>> candidateAliases =
      const <(int, int), List<String>>{},
}) =>
    _matchAgainstPool(
      sources,
      _pool(tmdbEpisodes, candidateAliases, specials: true),
      specials: true,
    );

List<_Candidate> _pool(
  Iterable<VideoMetadataEpisode> tmdbEpisodes,
  Map<(int, int), List<String>> candidateAliases, {
  required bool specials,
}) =>
    <_Candidate>[
      for (final VideoMetadataEpisode episode in tmdbEpisodes)
        if ((episode.seasonNumber == 0) == specials)
          _Candidate(
            episode,
            candidateAliases[(episode.seasonNumber, episode.episodeNumber)] ??
                const <String>[],
          ),
    ]..sort((_Candidate a, _Candidate b) {
        final int season =
            a.episode.seasonNumber.compareTo(b.episode.seasonNumber);
        return season != 0
            ? season
            : a.episode.episodeNumber.compareTo(b.episode.episodeNumber);
      });

Map<int, TmdbEpisodeMatch> _matchAgainstPool(
  List<TmdbEpisodeMatchSource> sources,
  List<_Candidate> pool, {
  required bool specials,
}) {
  final List<_Source> ordered = <_Source>[
    for (final TmdbEpisodeMatchSource source in sources) _Source(source),
  ]..sort((_Source a, _Source b) => a.source.number.compareTo(b.source.number));
  final Map<int, _Link> links = <int, _Link>{};
  final Set<_Candidate> used = <_Candidate>{};

  bool accepts(int pass, TmdbEpisodeMatchRating rating) => switch (pass) {
        1 => rating == TmdbEpisodeMatchRating.dateAndTitle,
        2 => rating.index <= TmdbEpisodeMatchRating.title.index,
        3 => rating.index <= TmdbEpisodeMatchRating.dateKinda.index,
        _ => rating != TmdbEpisodeMatchRating.none,
      };

  for (int pass = 1; pass <= 4; pass++) {
    final Set<int> lockedSeasons = <int>{
      for (final _Link link in links.values)
        link.candidate.episode.seasonNumber,
    };
    for (final _Source source in ordered) {
      if (links.containsKey(source.source.number)) continue;
      final List<_Candidate> candidates = <_Candidate>[
        for (final _Candidate candidate in pool)
          if (!used.contains(candidate) &&
              (pass == 1 ||
                  lockedSeasons.isEmpty ||
                  lockedSeasons.contains(candidate.episode.seasonNumber)))
            candidate,
      ];
      if (candidates.isEmpty) continue;
      final _Link? link = _bestMatch(
        source,
        candidates,
        anchor: _anchor(source, ordered, links),
        allowNearestAirDate: !specials,
        allowFirstAvailable: !specials && lockedSeasons.isNotEmpty,
      );
      if (link == null || !accepts(pass, link.rating)) continue;
      links[source.source.number] = link;
      used.add(link.candidate);
    }
  }
  _reconcileOrder(ordered, links);
  return <int, TmdbEpisodeMatch>{
    for (final MapEntry<int, _Link> entry in links.entries)
      entry.key: TmdbEpisodeMatch(
        episode: entry.value.candidate.episode,
        rating: entry.value.rating,
      ),
  };
}

class _Candidate {
  _Candidate(this.episode, List<String> aliases)
      : normalizedTitles = <String>{
          for (final String title in <String>[episode.title, ...aliases])
            if (TitleNormalizer.normalize(title) case final String normalized
                when normalized.isNotEmpty)
              normalized,
        }.toList(growable: false),
        airDate = _parseDate(episode.airDate);
  final VideoMetadataEpisode episode;
  final List<String> normalizedTitles;
  final DateTime? airDate;
}

class _Source {
  _Source(this.source)
      : normalizedTitles = <String>[
          for (final String title in source.titles)
            if (TitleNormalizer.normalize(title) case final String normalized
                when normalized.isNotEmpty && !_isGenericTitle(normalized))
              normalized,
        ],
        airDate = _parseDate(source.airDate);
  final TmdbEpisodeMatchSource source;
  final List<String> normalizedTitles;
  final DateTime? airDate;
}

class _Link {
  const _Link(this.candidate, this.rating);
  final _Candidate candidate;
  final TmdbEpisodeMatchRating rating;
}

/// Shoko `GetEpisodeTitleCandidates` 跳过 `Episode N` 这种泛标题。
bool _isGenericTitle(String normalized) =>
    RegExp(r'^(episode|ep|第)\s*\d+\s*(话|話|集)?$').hasMatch(normalized);

DateTime? _parseDate(String? text) {
  if (text == null || text.trim().isEmpty) return null;
  return DateTime.tryParse(text.trim());
}

int? _dayDiff(DateTime? a, DateTime? b) =>
    a == null || b == null ? null : a.difference(b).inDays.abs();

/// Shoko `ResolveAnchorSeason`：看来源集号相邻两侧已链接的 TMDB 季；两侧不同
/// （季边界）时取播出日更近的那一侧。额外带上「前一条链接的 TMDB 序」，顺序
/// 兜底只往它后面填。
_Anchor _anchor(_Source source, List<_Source> ordered, Map<int, _Link> links) {
  _Link? before;
  _Link? after;
  for (final _Source other in ordered) {
    final _Link? link = links[other.source.number];
    if (link == null) continue;
    if (other.source.number < source.source.number) {
      before = link;
    } else if (other.source.number > source.source.number && after == null) {
      after = link;
    }
  }
  final int? afterOrder =
      before == null ? null : _order(before.candidate.episode);
  if (before == null) {
    return _Anchor(after?.candidate.episode.seasonNumber, afterOrder);
  }
  if (after == null) {
    return _Anchor(before.candidate.episode.seasonNumber, afterOrder);
  }
  final int beforeSeason = before.candidate.episode.seasonNumber;
  final int afterSeason = after.candidate.episode.seasonNumber;
  if (beforeSeason == afterSeason) return _Anchor(beforeSeason, afterOrder);
  final int? toBefore = _dayDiff(source.airDate, before.candidate.airDate);
  final int? toAfter = _dayDiff(source.airDate, after.candidate.airDate);
  if (toBefore == null || toAfter == null) {
    return _Anchor(beforeSeason, afterOrder);
  }
  return _Anchor(toAfter < toBefore ? afterSeason : beforeSeason, afterOrder);
}

class _Anchor {
  const _Anchor(this.season, this.afterOrder);
  final int? season;

  /// 前一条已链接 TMDB 集的 (季, 集) 序；顺序兜底只取序号在它之后的候选。
  final int? afterOrder;
}

int _order(VideoMetadataEpisode e) => e.seasonNumber * 100000 + e.episodeNumber;

/// Shoko `TryFindAnidbAndTmdbMatch` + `SelectBestEpisodeMatch`。
_Link? _bestMatch(
  _Source source,
  List<_Candidate> candidates, {
  required _Anchor anchor,
  required bool allowNearestAirDate,
  required bool allowFirstAvailable,
}) {
  final int? anchorSeason = anchor.season;
  // 播出日 ±2 天内的候选，按日差、季、集排序（Shoko `CalculateAirDateProbability`）。
  final List<(_Candidate, int)> dated = <(_Candidate, int)>[
    for (final _Candidate candidate in candidates)
      if (_dayDiff(source.airDate, candidate.airDate) case final int diff
          when diff <= 2)
        (candidate, diff),
  ]..sort(((_Candidate, int) a, (_Candidate, int) b) {
      final int diff = a.$2.compareTo(b.$2);
      if (diff != 0) return diff;
      final int season =
          a.$1.episode.seasonNumber.compareTo(b.$1.episode.seasonNumber);
      return season != 0
          ? season
          : a.$1.episode.episodeNumber.compareTo(b.$1.episode.episodeNumber);
    });
  final Set<_Candidate> datedSet = <_Candidate>{
    for (final (_Candidate candidate, _) in dated) candidate,
  };

  // 标题：精确（归一化后相等或互为子串且长度差 <3）与「差不多」（相似度 ≥0.8
  // 且长度差 <6）——对应 Shoko `ExactMatch && LengthDifference < 3` /
  // `Distance < 0.2 && LengthDifference < 6`。
  _Candidate? exact;
  double exactScore = -1;
  _Candidate? kinda;
  double kindaScore = -1;
  for (final _Candidate candidate in candidates) {
    for (final String ct in candidate.normalizedTitles) {
      for (final String st in source.normalizedTitles) {
        final int lengthDifference = (st.length - ct.length).abs();
        final bool contained = st == ct || st.contains(ct) || ct.contains(st);
        if (contained && lengthDifference < 3) {
          // 同分时播出日也对上的优先。
          final double score = 1 + (datedSet.contains(candidate) ? 1 : 0);
          if (score > exactScore) {
            exactScore = score;
            exact = candidate;
          }
          continue;
        }
        final double similarity = TitleNormalizer.similarityNormalized(st, ct);
        if (similarity >= 0.8 && lengthDifference < 6) {
          final double score =
              similarity + (datedSet.contains(candidate) ? 1 : 0);
          if (score > kindaScore) {
            kindaScore = score;
            kinda = candidate;
          }
        }
      }
    }
  }
  if (exact != null) {
    return _Link(
      exact,
      datedSet.contains(exact)
          ? TmdbEpisodeMatchRating.dateAndTitle
          : TmdbEpisodeMatchRating.title,
    );
  }
  if (kinda != null && datedSet.contains(kinda)) {
    return _Link(kinda, TmdbEpisodeMatchRating.dateAndTitleKinda);
  }
  if (dated.isNotEmpty) {
    return _Link(dated.first.$1, TmdbEpisodeMatchRating.date);
  }
  if (kinda != null) return _Link(kinda, TmdbEpisodeMatchRating.titleKinda);
  // 最近播出日兜底：≤120 天，且限锚定季内（不跨季）；特典池关掉。
  if (allowNearestAirDate && source.airDate != null) {
    _Candidate? nearest;
    int nearestDiff = kTmdbEpisodeMatchMaxFallbackDays + 1;
    for (final _Candidate candidate in candidates) {
      if (anchorSeason != null &&
          candidate.episode.seasonNumber != anchorSeason) {
        continue;
      }
      final int? diff = _dayDiff(source.airDate, candidate.airDate);
      if (diff != null && diff < nearestDiff) {
        nearestDiff = diff;
        nearest = candidate;
      }
    }
    if (nearest != null) {
      return _Link(nearest, TmdbEpisodeMatchRating.dateKinda);
    }
  }
  // 顺序兜底：锚定季内、序号在前一条链接之后的第一个未用候选（Shoko 取池中
  // 第一个；本仓多了「在前一条链接之后」——否则 cour 中段一集没对上会被填成
  // 该季第 1 集）。
  if (allowFirstAvailable) {
    for (final _Candidate candidate in candidates) {
      if (anchorSeason != null &&
          candidate.episode.seasonNumber != anchorSeason) {
        continue;
      }
      if (anchor.afterOrder case final int after
          when _order(candidate.episode) <= after) {
        continue;
      }
      return _Link(candidate, TmdbEpisodeMatchRating.firstAvailable);
    }
  }
  return null;
}

/// Shoko `ReconcileEpisodeOrderInversions`：相邻两条来源集若都是弱评级
/// （date / dateKinda / firstAvailable）且 TMDB (S,E) 顺序倒置，交换之。
void _reconcileOrder(List<_Source> ordered, Map<int, _Link> links) {
  bool weak(TmdbEpisodeMatchRating rating) =>
      rating == TmdbEpisodeMatchRating.date ||
      rating == TmdbEpisodeMatchRating.dateKinda ||
      rating == TmdbEpisodeMatchRating.firstAvailable;
  bool swapped = true;
  while (swapped) {
    swapped = false;
    for (int i = 0; i + 1 < ordered.length; i++) {
      final int a = ordered[i].source.number;
      final int b = ordered[i + 1].source.number;
      final _Link? la = links[a];
      final _Link? lb = links[b];
      if (la == null || lb == null || !weak(la.rating) || !weak(lb.rating)) {
        continue;
      }
      if (_order(la.candidate.episode) > _order(lb.candidate.episode)) {
        links[a] = _Link(lb.candidate, la.rating);
        links[b] = _Link(la.candidate, lb.rating);
        swapped = true;
      }
    }
  }
}
