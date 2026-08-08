import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/metadata/video_metadata_models.dart';
import 'package:hibiki/src/media/video/metadata/video_metadata_provider.dart';
import 'package:hibiki/src/media/video/metadata/video_metadata_resolver.dart';

void main() {
  group('VideoMetadataResolver strict single-source gate', () {
    test('confirmed binding wins without issuing a search', () async {
      final _FakeProvider provider = _FakeProvider(
        kind: VideoMetadataProviderKind.tmdb,
        works: <String, VideoMetadataWork>{
          '42': _work(id: '42', title: 'Confirmed'),
        },
      );
      final VideoMetadataResolution result = await VideoMetadataResolver(
        registry: VideoMetadataProviderRegistry(<VideoMetadataProvider>[
          provider,
        ]),
      ).resolve(VideoMetadataResolveRequest(
        selectedProvider: VideoMetadataProviderKind.tmdb,
        mediaKind: VideoMetadataMediaKind.tv,
        titleCandidates: const <String>['Wrong title'],
        confirmedLookup: const VideoMetadataLookup(
          provider: VideoMetadataProviderKind.tmdb,
          externalId: '42',
          mediaKind: VideoMetadataMediaKind.tv,
        ),
      ));

      expect(result.status, VideoMetadataResolutionStatus.matched);
      expect(result.method, VideoMetadataResolutionMethod.confirmed);
      expect(result.work?.title, 'Confirmed');
      expect(provider.searchCalls, 0);
    });

    test('explicit provider id wins before title search', () async {
      final _FakeProvider provider = _FakeProvider(
        kind: VideoMetadataProviderKind.tmdb,
        works: <String, VideoMetadataWork>{
          '99': _work(id: '99', title: 'Explicit'),
        },
      );
      final VideoMetadataResolution result = await VideoMetadataResolver(
        registry: VideoMetadataProviderRegistry(<VideoMetadataProvider>[
          provider,
        ]),
      ).resolve(VideoMetadataResolveRequest(
        selectedProvider: VideoMetadataProviderKind.tmdb,
        mediaKind: VideoMetadataMediaKind.tv,
        titleCandidates: const <String>['Show [tmdbid=99] S01E01'],
      ));

      expect(result.status, VideoMetadataResolutionStatus.matched);
      expect(result.method, VideoMetadataResolutionMethod.explicitId);
      expect(result.lookup?.externalId, '99');
      expect(provider.searchCalls, 0);
    });

    test('search requires exact normalized title, type, year and season',
        () async {
      final VideoMetadataWork accepted = _work(
        id: '1',
        title: '無職転生',
        aliases: const <String>['无职转生'],
        year: 2021,
        seasons: <VideoMetadataSeason>[
          VideoMetadataSeason(seasonNumber: 2, title: '第二季'),
        ],
      );
      final _FakeProvider provider = _FakeProvider(
        kind: VideoMetadataProviderKind.tmdb,
        searchResults: <VideoMetadataWork>[
          accepted,
          _work(id: '2', title: '无职转生', year: 2023),
          _work(id: '3', title: '无职转生：外传', year: 2021),
          _work(
            id: '4',
            title: '无职转生',
            year: 2021,
            mediaKind: VideoMetadataMediaKind.movie,
          ),
        ],
        works: <String, VideoMetadataWork>{'1': accepted},
      );
      final VideoMetadataResolution result = await VideoMetadataResolver(
        registry: VideoMetadataProviderRegistry(<VideoMetadataProvider>[
          provider,
        ]),
      ).resolve(VideoMetadataResolveRequest(
        selectedProvider: VideoMetadataProviderKind.tmdb,
        mediaKind: VideoMetadataMediaKind.tv,
        titleCandidates: const <String>['无职转生'],
        year: 2021,
        seasonNumber: 2,
      ));

      expect(result.status, VideoMetadataResolutionStatus.matched);
      expect(result.lookup?.externalId, '1');
      expect(provider.searchCalls, 1);
    });

    test('multiple exact candidates are returned for manual confirmation',
        () async {
      final VideoMetadataWork first = _work(id: '1', title: '86', year: 2021);
      final VideoMetadataWork second = _work(id: '2', title: '８６', year: 2021);
      final _FakeProvider provider = _FakeProvider(
        kind: VideoMetadataProviderKind.tmdb,
        searchResults: <VideoMetadataWork>[first, second],
        works: <String, VideoMetadataWork>{'1': first, '2': second},
      );

      final VideoMetadataResolution result = await VideoMetadataResolver(
        registry: VideoMetadataProviderRegistry(<VideoMetadataProvider>[
          provider,
        ]),
      ).resolve(VideoMetadataResolveRequest(
        selectedProvider: VideoMetadataProviderKind.tmdb,
        mediaKind: VideoMetadataMediaKind.tv,
        titleCandidates: const <String>['86'],
        year: 2021,
      ));

      expect(result.status, VideoMetadataResolutionStatus.ambiguous);
      expect(result.candidates, hasLength(2));
    });

    test('detail aliases recover romanized titles omitted by search summary',
        () async {
      final VideoMetadataWork summary =
          _work(id: '77', title: '无职转生', year: 2021);
      final VideoMetadataWork details = _work(
        id: '77',
        title: '无职转生 ～到了异世界就拿出真本事～',
        aliases: const <String>[
          'Mushoku Tensei: Isekai Ittara Honki Dasu',
        ],
        year: 2021,
      );
      final _FakeProvider provider = _FakeProvider(
        kind: VideoMetadataProviderKind.tmdb,
        searchResults: <VideoMetadataWork>[summary],
        works: <String, VideoMetadataWork>{'77': details},
      );

      final VideoMetadataResolution result = await VideoMetadataResolver(
        registry: VideoMetadataProviderRegistry(<VideoMetadataProvider>[
          provider,
        ]),
      ).resolve(VideoMetadataResolveRequest(
        selectedProvider: VideoMetadataProviderKind.tmdb,
        mediaKind: VideoMetadataMediaKind.tv,
        titleCandidates: const <String>[
          'Mushoku Tensei Isekai Ittara Honki Dasu',
        ],
        year: 2021,
      ));

      expect(result.status, VideoMetadataResolutionStatus.matched);
      expect(result.work?.title, contains('无职转生'));
    });

    test('valid provider candidates are kept for confirmation on title miss',
        () async {
      final VideoMetadataWork candidate =
          _work(id: '88', title: '本地化标题', year: 2021);
      final _FakeProvider provider = _FakeProvider(
        kind: VideoMetadataProviderKind.tmdb,
        searchResults: <VideoMetadataWork>[candidate],
        works: <String, VideoMetadataWork>{'88': candidate},
      );

      final VideoMetadataResolution result = await VideoMetadataResolver(
        registry: VideoMetadataProviderRegistry(<VideoMetadataProvider>[
          provider,
        ]),
      ).resolve(VideoMetadataResolveRequest(
        selectedProvider: VideoMetadataProviderKind.tmdb,
        mediaKind: VideoMetadataMediaKind.tv,
        titleCandidates: const <String>['Unmatched romanized title'],
        year: 2021,
      ));

      expect(result.status, VideoMetadataResolutionStatus.ambiguous);
      expect(result.candidates.single.title, '本地化标题');
      expect(result.reason, contains('manual'));
    });

    test('Bangumi sequel title uses parsed base title plus season gate',
        () async {
      final VideoMetadataWork sequel = VideoMetadataWork(
        provider: VideoMetadataProviderKind.bangumi,
        kind: VideoMetadataMediaKind.tv,
        title: 'Work 2nd Season',
        year: 2024,
        ids: const <VideoMetadataId>[
          VideoMetadataId(type: 'bangumi', value: '22'),
        ],
      );
      final _FakeProvider provider = _FakeProvider(
        kind: VideoMetadataProviderKind.bangumi,
        searchResults: <VideoMetadataWork>[sequel],
        works: <String, VideoMetadataWork>{'22': sequel},
      );

      final VideoMetadataResolution result = await VideoMetadataResolver(
        registry: VideoMetadataProviderRegistry(<VideoMetadataProvider>[
          provider,
        ]),
      ).resolve(VideoMetadataResolveRequest(
        selectedProvider: VideoMetadataProviderKind.bangumi,
        mediaKind: VideoMetadataMediaKind.tv,
        titleCandidates: const <String>['Work S02'],
        year: 2024,
        seasonNumber: 2,
      ));

      expect(result.status, VideoMetadataResolutionStatus.matched);
      expect(result.lookup?.externalId, '22');
    });

    test('unconfigured selected provider fails before network', () async {
      final VideoMetadataResolution result = await VideoMetadataResolver(
        registry:
            VideoMetadataProviderRegistry(const <VideoMetadataProvider>[]),
      ).resolve(VideoMetadataResolveRequest(
        selectedProvider: VideoMetadataProviderKind.douban,
        mediaKind: VideoMetadataMediaKind.movie,
        titleCandidates: const <String>['Movie'],
      ));

      expect(
        result.status,
        VideoMetadataResolutionStatus.providerUnavailable,
      );
    });
  });

  test('parseExplicitVideoMetadataIds recognizes supported URLs and tokens',
      () {
    final List<VideoMetadataLookup> values = parseExplicitVideoMetadataIds(
      const <String>[
        'https://www.themoviedb.org/tv/1399-game-of-thrones',
        'bgm.tv/subject/253',
        'https://anilist.co/anime/11061/HUNTERHUNTER-2011/',
        '[doubanid=1292052]',
        '{[tmdbid=777;type=tv;g=5f8f42adf5c6b90036f0f123]}',
        '86',
      ],
      fallbackMediaKind: VideoMetadataMediaKind.tv,
    );

    expect(
      values
          .map((VideoMetadataLookup value) =>
              '${value.provider.name}:${value.externalId}:${value.mediaKind.name}')
          .toList(),
      <String>[
        'tmdb:1399:tv',
        'bangumi:253:tv',
        'anilist:11061:tv',
        'douban:1292052:tv',
        'tmdb:777:tv',
      ],
    );
    expect(values.last.episodeGroupId, '5f8f42adf5c6b90036f0f123');
  });
}

VideoMetadataWork _work({
  required String id,
  required String title,
  List<String> aliases = const <String>[],
  int? year,
  VideoMetadataMediaKind mediaKind = VideoMetadataMediaKind.tv,
  List<VideoMetadataSeason> seasons = const <VideoMetadataSeason>[],
}) =>
    VideoMetadataWork(
      provider: VideoMetadataProviderKind.tmdb,
      kind: mediaKind,
      title: title,
      aliases: aliases,
      year: year,
      ids: <VideoMetadataId>[
        VideoMetadataId(type: 'tmdb', value: id, isDefault: true),
      ],
      seasons: seasons,
    );

class _FakeProvider implements VideoMetadataProvider {
  _FakeProvider({
    required this.kind,
    this.searchResults = const <VideoMetadataWork>[],
    this.works = const <String, VideoMetadataWork>{},
  });

  final VideoMetadataProviderKind kind;
  final List<VideoMetadataWork> searchResults;
  final Map<String, VideoMetadataWork> works;
  int searchCalls = 0;

  @override
  VideoMetadataProviderKind get providerKind => kind;

  @override
  bool get isAvailable => true;

  @override
  Future<List<VideoMetadataWork>> search(
    VideoMetadataSearchRequest request,
  ) async {
    searchCalls++;
    return searchResults;
  }

  @override
  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup) async =>
      works[lookup.externalId];

  @override
  Future<List<VideoMetadataSeason>> fetchSeasons(
    VideoMetadataLookup lookup,
  ) async =>
      works[lookup.externalId]?.seasons ?? const <VideoMetadataSeason>[];

  @override
  Future<List<VideoMetadataEpisode>> fetchEpisodes(
    VideoMetadataLookup lookup, {
    required int seasonNumber,
  }) async =>
      const <VideoMetadataEpisode>[];

  @override
  void close() {}
}
