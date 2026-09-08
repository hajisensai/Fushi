/// 离线标题索引阶段（设计稿 A2，HAMA 路线）：
///
/// 标题候选 → AniDB 每日标题包（保留所有语言，含 zh-Hans）**唯一精确命中** →
/// anidb id → Fribb anime-lists 换 MAL id / TMDB 剧 id / TMDB 季与集偏移。
///
/// 这一步不发任何搜索请求：中文目录名在这里就能定身份，不再依赖 Jikan
/// 搜索（MAL 没有中文标题，Jikan 搜索接口又常年 504）。命中后协调器按 id
/// 直拉详情，等价于 Jellyfin 的「有 ProviderIds 就不搜索」。
///
/// 规则照 Jellyfin AniDB 插件 / Taiga：只认 exact；同一标题命中多个 anime 且
/// 类型闸门筛不到唯一 → 视为歧义，**放弃**（不猜、不降级到 prefix / similar），
/// 交给后面的在线链与人工确认。
library;

import 'package:fushi/src/media/video/metadata/anidb_title_catalog.dart';
import 'package:fushi/src/media/video/metadata/anime_identity_mapping.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_provider.dart';

typedef AniDbTitleSearch = Future<List<AniDbTitleSearchResult>> Function(
  String query,
);
typedef AnimeIdentityEntryLookup = Future<AnimeIdentityEntry?> Function(
  int anidbId,
);

enum AnimeOfflineIdentityStatus { matched, ambiguous, notFound, unavailable }

/// 离线阶段得到的身份：anidb 一定有；MAL / TMDB 视 Fribb 覆盖而定。
class AnimeOfflineIdentity {
  const AnimeOfflineIdentity({
    required this.anidbId,
    required this.matchedTitle,
    required this.queryTitle,
    this.malId,
    this.tmdbId,
    this.isMovie = false,
    this.tmdbSeason,
    this.tmdbEpisodeOffset,
  });

  final int anidbId;
  final String matchedTitle;
  final String queryTitle;
  final int? malId;
  final int? tmdbId;
  final bool isMovie;
  final int? tmdbSeason;
  final int? tmdbEpisodeOffset;

  bool get hasOnlineIdentity => malId != null || tmdbId != null;

  /// 给某一家 provider 的 lookup；该家没有 id 时返回 null。MAL 单一 id 命名
  /// 空间由源返回真实类型；TMDB 按 Fribb 的 type 分 /movie 与 /tv。
  VideoMetadataLookup? lookupFor(
    VideoMetadataProviderKind provider,
    VideoMetadataMediaKind requestedKind,
  ) {
    switch (provider) {
      case VideoMetadataProviderKind.mal:
        final int? id = malId;
        if (id == null) return null;
        return VideoMetadataLookup(
          provider: provider,
          externalId: '$id',
          mediaKind: requestedKind,
        );
      case VideoMetadataProviderKind.tmdb:
        final int? id = tmdbId;
        if (id == null) return null;
        return VideoMetadataLookup(
          provider: provider,
          externalId: '$id',
          mediaKind: isMovie
              ? VideoMetadataMediaKind.movie
              : VideoMetadataMediaKind.tv,
        );
      case VideoMetadataProviderKind.anidb:
        return VideoMetadataLookup(
          provider: provider,
          externalId: '$anidbId',
          mediaKind: requestedKind,
        );
      default:
        return null;
    }
  }
}

class AnimeOfflineIdentityResolution {
  const AnimeOfflineIdentityResolution({
    required this.status,
    this.identity,
    this.reason,
  });

  const AnimeOfflineIdentityResolution.notFound()
      : this(status: AnimeOfflineIdentityStatus.notFound);

  final AnimeOfflineIdentityStatus status;
  final AnimeOfflineIdentity? identity;
  final String? reason;
}

class AnimeOfflineIdentityResolver {
  /// [ownsCatalog] / [ownsMapping] 为 true 时 [close] 会一并释放对应对象。
  AnimeOfflineIdentityResolver({
    required AniDbTitleCatalog catalog,
    required AnimeIdentityMapping mapping,
    int searchLimit = 25,
    bool ownsCatalog = false,
    bool ownsMapping = false,
  })  : search = ((String query) => catalog.search(query, limit: searchLimit)),
        entryForAnidb = mapping.entryForAnidb,
        _ownedCatalog = ownsCatalog ? catalog : null,
        _ownedMapping = ownsMapping ? mapping : null;

  /// 测试与装配用：直接注入两个查询函数。
  const AnimeOfflineIdentityResolver.custom({
    required this.search,
    required this.entryForAnidb,
  })  : _ownedCatalog = null,
        _ownedMapping = null;

  final AniDbTitleSearch search;
  final AnimeIdentityEntryLookup entryForAnidb;
  final AniDbTitleCatalog? _ownedCatalog;
  final AnimeIdentityMapping? _ownedMapping;

  void close() {
    _ownedCatalog?.close();
    _ownedMapping?.close();
  }

  /// 按候选顺序逐个标题查；第一个有 exact 命中的标题决定结果：唯一 → matched，
  /// 多个 → ambiguous（不再看后面的候选）。全部候选都没有 exact → notFound。
  /// 标题包 / 映射表拉不到 → unavailable（调用方跳过本阶段，不算失败）。
  Future<AnimeOfflineIdentityResolution> resolve({
    required List<String> titleCandidates,
    required VideoMetadataMediaKind mediaKind,
  }) async {
    try {
      for (final String rawTitle in titleCandidates) {
        final String title = rawTitle.trim();
        if (title.isEmpty) continue;
        final List<AniDbTitleSearchResult> results = await search(title);
        final Map<int, AniDbTitleSearchResult> exact =
            <int, AniDbTitleSearchResult>{};
        for (final AniDbTitleSearchResult result in results) {
          if (result.kind != AniDbTitleMatchKind.exact) continue;
          exact.putIfAbsent(result.record.animeId, () => result);
        }
        if (exact.isEmpty) continue;
        final List<_Candidate> candidates = <_Candidate>[
          for (final AniDbTitleSearchResult result in exact.values)
            _Candidate(result, await entryForAnidb(result.record.animeId)),
        ];
        // 类型闸门：请求电影就只留 MOVIE 条目，请求剧集就剔除 MOVIE；Fribb 没
        // 收录（entry == null）的条目类型未知，不剔除。
        final bool wantMovie = mediaKind == VideoMetadataMediaKind.movie;
        final List<_Candidate> gated = <_Candidate>[
          for (final _Candidate candidate in candidates)
            if (candidate.entry == null ||
                candidate.entry!.isMovie == wantMovie)
              candidate,
        ];
        if (gated.length != 1) {
          return AnimeOfflineIdentityResolution(
            status: AnimeOfflineIdentityStatus.ambiguous,
            reason: gated.isEmpty
                ? 'AniDB title "$title" matches only entries of another media type'
                : 'AniDB title "$title" matches ${gated.length} anime: '
                    '${gated.map((_Candidate c) => c.result.record.animeId).join(', ')}',
          );
        }
        final _Candidate single = gated.single;
        final AnimeIdentityEntry? entry = single.entry;
        return AnimeOfflineIdentityResolution(
          status: AnimeOfflineIdentityStatus.matched,
          identity: AnimeOfflineIdentity(
            anidbId: single.result.record.animeId,
            matchedTitle: single.result.matchedTitle.value,
            queryTitle: title,
            malId: entry != null && entry.malIds.length == 1
                ? entry.malIds.single
                : null,
            tmdbId: entry?.tmdbId,
            isMovie: entry?.isMovie ?? false,
            tmdbSeason: entry?.tmdbSeason,
            tmdbEpisodeOffset: entry?.tmdbEpisodeOffset,
          ),
        );
      }
      return const AnimeOfflineIdentityResolution.notFound();
    } on Object catch (error) {
      return AnimeOfflineIdentityResolution(
        status: AnimeOfflineIdentityStatus.unavailable,
        reason: error.toString(),
      );
    }
  }
}

class _Candidate {
  const _Candidate(this.result, this.entry);

  final AniDbTitleSearchResult result;
  final AnimeIdentityEntry? entry;
}
