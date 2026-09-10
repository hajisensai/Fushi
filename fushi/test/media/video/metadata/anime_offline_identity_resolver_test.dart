import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/metadata/anidb_title_catalog.dart';
import 'package:fushi_engine/media/video/metadata/anime_identity_mapping.dart';
import 'package:fushi_engine/media/video/metadata/anime_offline_identity_resolver.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';

/// 离线标题索引阶段：AniDB 标题包唯一精确命中 → Fribb 换 MAL / TMDB id。
void main() {
  AniDbTitleSearchResult hit(
    int animeId,
    String title, {
    AniDbTitleMatchKind kind = AniDbTitleMatchKind.exact,
    String language = 'zh-Hans',
  }) {
    final AniDbTitle matched = AniDbTitle(
      value: title,
      type: 'official',
      language: language,
    );
    return AniDbTitleSearchResult(
      record: AniDbTitleRecord(animeId: animeId, titles: <AniDbTitle>[matched]),
      matchedTitle: matched,
      kind: kind,
      similarity: kind == AniDbTitleMatchKind.exact ? 1 : 0.8,
    );
  }

  AnimeIdentityEntry entry(
    int anidbId, {
    Set<int> malIds = const <int>{},
    int? tmdbId,
    String type = 'TV',
    int? tmdbSeason,
    int? tmdbEpisodeOffset,
  }) =>
      AnimeIdentityEntry(
        anidbId: anidbId,
        malIds: malIds,
        tmdbId: tmdbId,
        type: type,
        tmdbSeason: tmdbSeason,
        tmdbEpisodeOffset: tmdbEpisodeOffset,
      );

  AnimeOfflineIdentityResolver resolver({
    required Map<String, List<AniDbTitleSearchResult>> index,
    required Map<int, AnimeIdentityEntry> entries,
    List<String>? queries,
  }) =>
      AnimeOfflineIdentityResolver.custom(
        search: (String query) async {
          queries?.add(query);
          return index[query] ?? const <AniDbTitleSearchResult>[];
        },
        entryForAnidb: (int anidbId) async => entries[anidbId],
      );

  test('Chinese title resolves to MAL and TMDB ids without any search',
      () async {
    final List<String> queries = <String>[];
    final AnimeOfflineIdentityResolution result = await resolver(
      index: <String, List<AniDbTitleSearchResult>>{
        '葬送的芙莉莲': <AniDbTitleSearchResult>[hit(17617, '葬送的芙莉莲')],
      },
      entries: <int, AnimeIdentityEntry>{
        17617: entry(17617,
            malIds: <int>{52991},
            tmdbId: 209867,
            tmdbSeason: 1,
            tmdbEpisodeOffset: 0),
      },
      queries: queries,
    ).resolve(
      titleCandidates: <String>['葬送的芙莉莲', '动漫'],
      mediaKind: VideoMetadataMediaKind.tv,
    );
    expect(result.status, AnimeOfflineIdentityStatus.matched);
    final AnimeOfflineIdentity identity = result.identity!;
    expect(identity.anidbId, 17617);
    expect(identity.malId, 52991);
    expect(identity.tmdbId, 209867);
    expect(identity.matchedTitle, '葬送的芙莉莲');
    expect(queries, <String>['葬送的芙莉莲'], reason: '首个命中即停，不再查目录名');
    expect(
      identity.lookupFor(
          VideoMetadataProviderKind.mal, VideoMetadataMediaKind.tv),
      isA<VideoMetadataLookup>()
          .having((VideoMetadataLookup l) => l.externalId, 'id', '52991'),
    );
    expect(
      identity
          .lookupFor(VideoMetadataProviderKind.tmdb, VideoMetadataMediaKind.tv)
          ?.mediaKind,
      VideoMetadataMediaKind.tv,
    );
  });

  test('episode-label first candidate is skipped and the directory decides',
      () async {
    final AnimeOfflineIdentityResolution result = await resolver(
      index: <String, List<AniDbTitleSearchResult>>{
        '我推的孩子': <AniDbTitleSearchResult>[hit(17449, '我推的孩子')],
      },
      entries: <int, AnimeIdentityEntry>{
        17449: entry(17449, malIds: <int>{52034}, tmdbId: 203737),
      },
    ).resolve(
      titleCandidates: <String>['', '   ', '我推的孩子'],
      mediaKind: VideoMetadataMediaKind.tv,
    );
    expect(result.status, AnimeOfflineIdentityStatus.matched);
    expect(result.identity?.malId, 52034);
  });

  test('prefix and similar hits never decide', () async {
    final AnimeOfflineIdentityResolution result = await resolver(
      index: <String, List<AniDbTitleSearchResult>>{
        'Frieren': <AniDbTitleSearchResult>[
          hit(17617, 'Sousou no Frieren', kind: AniDbTitleMatchKind.prefix),
          hit(1, 'Frieren no Nanika', kind: AniDbTitleMatchKind.similar),
        ],
      },
      entries: <int, AnimeIdentityEntry>{
        17617: entry(17617, malIds: <int>{52991}),
      },
    ).resolve(
      titleCandidates: <String>['Frieren'],
      mediaKind: VideoMetadataMediaKind.tv,
    );
    expect(result.status, AnimeOfflineIdentityStatus.notFound);
  });

  test('two exact anime of the requested type is ambiguous, not a guess',
      () async {
    final AnimeOfflineIdentityResolution result = await resolver(
      index: <String, List<AniDbTitleSearchResult>>{
        'Hunter x Hunter': <AniDbTitleSearchResult>[
          hit(11, 'Hunter x Hunter', language: 'x-jat'),
          hit(8146, 'Hunter x Hunter', language: 'x-jat'),
        ],
      },
      entries: <int, AnimeIdentityEntry>{
        11: entry(11, malIds: <int>{136}),
        8146: entry(8146, malIds: <int>{11061}),
      },
    ).resolve(
      titleCandidates: <String>['Hunter x Hunter', 'Anime'],
      mediaKind: VideoMetadataMediaKind.tv,
    );
    expect(result.status, AnimeOfflineIdentityStatus.ambiguous);
    expect(result.reason, contains('11'));
    expect(result.reason, contains('8146'));
  });

  test('media type gate picks the TV entry over the movie of the same name',
      () async {
    final AnimeOfflineIdentityResolution result = await resolver(
      index: <String, List<AniDbTitleSearchResult>>{
        'Kimi no Na wa': <AniDbTitleSearchResult>[
          hit(11829, 'Kimi no Na wa', language: 'x-jat'),
          hit(99, 'Kimi no Na wa', language: 'x-jat'),
        ],
      },
      entries: <int, AnimeIdentityEntry>{
        11829:
            entry(11829, malIds: <int>{32281}, tmdbId: 372058, type: 'MOVIE'),
        99: entry(99, malIds: <int>{9}, tmdbId: 1, type: 'TV'),
      },
    ).resolve(
      titleCandidates: <String>['Kimi no Na wa'],
      mediaKind: VideoMetadataMediaKind.movie,
    );
    expect(result.status, AnimeOfflineIdentityStatus.matched);
    expect(result.identity?.anidbId, 11829);
    expect(result.identity?.isMovie, isTrue);
    expect(
      result.identity
          ?.lookupFor(VideoMetadataProviderKind.tmdb, VideoMetadataMediaKind.tv)
          ?.mediaKind,
      VideoMetadataMediaKind.movie,
      reason: 'TMDB 命名空间按 Fribb type 而不是本地猜测',
    );
  });

  test('entries without a mapping row keep the anidb id only', () async {
    final AnimeOfflineIdentityResolution result = await resolver(
      index: <String, List<AniDbTitleSearchResult>>{
        'Obscure': <AniDbTitleSearchResult>[hit(5, 'Obscure', language: 'en')],
      },
      entries: <int, AnimeIdentityEntry>{},
    ).resolve(
      titleCandidates: <String>['Obscure'],
      mediaKind: VideoMetadataMediaKind.tv,
    );
    expect(result.status, AnimeOfflineIdentityStatus.matched);
    expect(result.identity?.hasOnlineIdentity, isFalse);
    expect(
      result.identity
          ?.lookupFor(VideoMetadataProviderKind.mal, VideoMetadataMediaKind.tv),
      isNull,
    );
  });

  test('multiple MAL ids for one anidb entry leave malId unset', () async {
    final AnimeOfflineIdentityResolution result = await resolver(
      index: <String, List<AniDbTitleSearchResult>>{
        'Split': <AniDbTitleSearchResult>[hit(7, 'Split', language: 'en')],
      },
      entries: <int, AnimeIdentityEntry>{
        7: entry(7, malIds: <int>{1, 2}, tmdbId: 77),
      },
    ).resolve(
      titleCandidates: <String>['Split'],
      mediaKind: VideoMetadataMediaKind.tv,
    );
    expect(result.identity?.malId, isNull);
    expect(result.identity?.tmdbId, 77);
  });

  test('catalog failure is reported as unavailable, never thrown', () async {
    final AnimeOfflineIdentityResolution result =
        await AnimeOfflineIdentityResolver.custom(
      search: (String query) async =>
          throw const AniDbTitleCatalogException('download failed'),
      entryForAnidb: (int anidbId) async => null,
    ).resolve(
      titleCandidates: <String>['Anything'],
      mediaKind: VideoMetadataMediaKind.tv,
    );
    expect(result.status, AnimeOfflineIdentityStatus.unavailable);
    expect(result.reason, contains('download failed'));
  });
}
