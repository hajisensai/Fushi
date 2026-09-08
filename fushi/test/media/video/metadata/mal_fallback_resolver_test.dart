import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_resolver.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_transport.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_config.dart';

void main() {
  test('MAL exact match wins and records MAL identity', () async {
    final _Provider mal = _Provider(VideoMetadataProviderKind.mal);
    final _Provider tmdb = _Provider(VideoMetadataProviderKind.tmdb);
    final VideoMetadataResolution result = await _resolve(mal, tmdb);
    expect(result.status, VideoMetadataResolutionStatus.matched);
    expect(result.providerKind, VideoMetadataProviderKind.mal);
    expect(result.lookup?.provider, VideoMetadataProviderKind.mal);
    expect(tmdb.searchCalls, 0);
  });

  for (final Object? failure in <Object?>[
    null,
    const VideoMetadataProviderUnavailable(
        VideoMetadataProviderKind.mal, '429'),
    TimeoutException('timeout'),
    const SocketException('offline'),
    const VideoMetadataNetworkException('rate limited', statusCode: 429),
  ]) {
    test('MAL failure $failure falls back to TMDB identity', () async {
      final _Provider mal = _Provider(VideoMetadataProviderKind.mal,
          empty: true, failure: failure);
      final _Provider tmdb = _Provider(VideoMetadataProviderKind.tmdb);
      final VideoMetadataResolution result = await _resolve(mal, tmdb);
      expect(result.status, VideoMetadataResolutionStatus.matched);
      expect(result.providerKind, VideoMetadataProviderKind.tmdb);
      expect(result.lookup?.provider, VideoMetadataProviderKind.tmdb);
      expect(result.lookup?.externalId, '42');
      expect(tmdb.searchCalls, 1);
    });
  }

  test('unregistered MAL falls back; dual failure retains both reasons',
      () async {
    final _Provider tmdb =
        _Provider(VideoMetadataProviderKind.tmdb, empty: true);
    final VideoMetadataResolution result = await _resolve(null, tmdb);
    expect(result.status, VideoMetadataResolutionStatus.providerUnavailable);
    expect(result.reason, contains('mal: mal is not configured'));
    expect(result.reason, contains('tmdb: No candidate'));
  });

  test('both not found remains not found', () async {
    final VideoMetadataResolution result = await _resolve(
      _Provider(VideoMetadataProviderKind.mal, empty: true),
      _Provider(VideoMetadataProviderKind.tmdb, empty: true),
    );
    expect(result.status, VideoMetadataResolutionStatus.notFound);
    expect(result.reason, contains('mal:'));
    expect(result.reason, contains('tmdb:'));
  });

  test('MAL ambiguity (two exact hits) lets a unique TMDB exact match decide',
      () async {
    final _Provider tmdb = _Provider(VideoMetadataProviderKind.tmdb);
    final VideoMetadataResolution result = await _resolve(
      _Provider(VideoMetadataProviderKind.mal, ambiguous: true),
      tmdb,
    );
    expect(result.status, VideoMetadataResolutionStatus.matched);
    expect(result.providerKind, VideoMetadataProviderKind.tmdb);
    expect(result.lookup?.externalId, '42');
    expect(tmdb.searchCalls, 1);
  });

  test('MAL review-only candidates (title mismatch) continue to TMDB',
      () async {
    // MAL 没有中文标题：中文目录名只能得到类型合格、标题不符的候选。旧链在这
    // 里就停了，TMDB 永远不被问；现在必须继续问兜底源。
    final _Provider tmdb = _Provider(VideoMetadataProviderKind.tmdb);
    final VideoMetadataResolution result = await _resolve(
      _Provider(VideoMetadataProviderKind.mal, title: 'Other'),
      tmdb,
    );
    expect(result.status, VideoMetadataResolutionStatus.matched);
    expect(result.providerKind, VideoMetadataProviderKind.tmdb);
    expect(tmdb.searchCalls, 1);
  });

  test('both sources ambiguous merges candidates with their own provider',
      () async {
    final VideoMetadataResolution result = await _resolve(
      _Provider(VideoMetadataProviderKind.mal, ambiguous: true),
      _Provider(VideoMetadataProviderKind.tmdb, title: 'Other'),
    );
    expect(result.status, VideoMetadataResolutionStatus.ambiguous);
    expect(result.candidates, hasLength(3));
    expect(
      result.candidates.map((VideoMetadataWork w) => w.provider).toSet(),
      <VideoMetadataProviderKind>{
        VideoMetadataProviderKind.mal,
        VideoMetadataProviderKind.tmdb,
      },
    );
    expect(result.providerKind, VideoMetadataProviderKind.mal);
    expect(result.reason, contains('mal:'));
    expect(result.reason, contains('tmdb:'));
  });

  test('MAL unavailable and TMDB ambiguous stays ambiguous', () async {
    final VideoMetadataResolution result = await _resolve(
      _Provider(VideoMetadataProviderKind.mal,
          failure: const SocketException('offline')),
      _Provider(VideoMetadataProviderKind.tmdb, ambiguous: true),
    );
    expect(result.status, VideoMetadataResolutionStatus.ambiguous);
    expect(result.providerKind, VideoMetadataProviderKind.tmdb);
    expect(result.candidates, hasLength(2));
  });

  test('TMDB primary falls back to MAL symmetrically', () async {
    final _Provider mal = _Provider(VideoMetadataProviderKind.mal);
    final _Provider tmdb =
        _Provider(VideoMetadataProviderKind.tmdb, empty: true);
    final VideoMetadataResolution result = await _resolve(
      mal,
      tmdb,
      selected: VideoMetadataProviderKind.tmdb,
    );
    expect(result.status, VideoMetadataResolutionStatus.matched);
    expect(result.providerKind, VideoMetadataProviderKind.mal);
    expect(tmdb.searchCalls, 1);
    expect(mal.searchCalls, 1);
  });

  test('TMDB primary accepts a persisted MAL identity as canonical', () async {
    final _Provider mal = _Provider(VideoMetadataProviderKind.mal);
    final _Provider tmdb = _Provider(VideoMetadataProviderKind.tmdb);
    final VideoMetadataResolution result = await _resolve(
      mal,
      tmdb,
      selected: VideoMetadataProviderKind.tmdb,
      confirmed: const VideoMetadataLookup(
        provider: VideoMetadataProviderKind.mal,
        externalId: '7',
        mediaKind: VideoMetadataMediaKind.tv,
      ),
    );
    expect(result.status, VideoMetadataResolutionStatus.matched);
    expect(result.method, VideoMetadataResolutionMethod.confirmed);
    expect(result.providerKind, VideoMetadataProviderKind.mal);
    expect(tmdb.searchCalls, 0);
  });

  test('single-source request never consults a second provider', () async {
    final _Provider tmdb = _Provider(VideoMetadataProviderKind.tmdb);
    final VideoMetadataResolution result = await _resolve(
      _Provider(VideoMetadataProviderKind.mal, empty: true),
      tmdb,
      singleSource: true,
    );
    expect(result.status, VideoMetadataResolutionStatus.notFound);
    expect(result.providerKind, VideoMetadataProviderKind.mal);
    expect(tmdb.searchCalls, 0);
  });

  test('programming errors propagate instead of triggering fallback', () async {
    final _Provider tmdb = _Provider(VideoMetadataProviderKind.tmdb);
    await expectLater(
        _resolve(
          _Provider(VideoMetadataProviderKind.mal, failure: StateError('bug')),
          tmdb,
        ),
        throwsStateError);
    expect(tmdb.searchCalls, 0);
  });

  for (final VideoMetadataProviderKind kind in <VideoMetadataProviderKind>[
    VideoMetadataProviderKind.mal,
    VideoMetadataProviderKind.tmdb,
  ]) {
    for (final bool confirmed in <bool>[true, false]) {
      test(
          '$kind locked identity confirmed=$confirmed never searches on failure',
          () async {
        final _Provider mal =
            _Provider(VideoMetadataProviderKind.mal, empty: true);
        final _Provider tmdb =
            _Provider(VideoMetadataProviderKind.tmdb, empty: true);
        final VideoMetadataResolution result = await _resolve(
          mal,
          tmdb,
          confirmed: confirmed
              ? VideoMetadataLookup(
                  provider: kind,
                  externalId: '99',
                  mediaKind: VideoMetadataMediaKind.tv,
                )
              : null,
          hints: confirmed ? <String>[] : <String>['${kind.name}=99'],
        );
        expect(result.status, VideoMetadataResolutionStatus.notFound);
        expect(result.providerKind, kind);
        expect(result.lookup?.externalId, '99');
        expect(mal.searchCalls, 0);
        expect(tmdb.searchCalls, 0);
      });
    }
  }

  test('unavailable confirmed source cannot switch identity', () async {
    final _Provider tmdb = _Provider(VideoMetadataProviderKind.tmdb);
    final VideoMetadataResolution result = await _resolve(
      null,
      tmdb,
      confirmed: const VideoMetadataLookup(
          provider: VideoMetadataProviderKind.mal,
          externalId: '42',
          mediaKind: VideoMetadataMediaKind.tv),
    );
    expect(result.status, VideoMetadataResolutionStatus.providerUnavailable);
    expect(tmdb.searchCalls, 0);
  });

  test('explicit TMDB ID is honored under MAL policy', () async {
    final _Provider mal = _Provider(VideoMetadataProviderKind.mal);
    final VideoMetadataResolution result = await _resolve(
      mal,
      _Provider(VideoMetadataProviderKind.tmdb),
      hints: <String>['tmdb=42'],
    );
    expect(result.providerKind, VideoMetadataProviderKind.tmdb);
    expect(result.method, VideoMetadataResolutionMethod.explicitId);
    expect(mal.searchCalls, 0);
  });

  test('legacy AniDB binding does not initiate an unregistered provider',
      () async {
    final _Provider mal = _Provider(VideoMetadataProviderKind.mal);
    final _Provider tmdb = _Provider(VideoMetadataProviderKind.tmdb);
    final VideoMetadataResolution result =
        await _resolve(mal, tmdb, hints: <String>['anidb=42']);
    expect(result.status, VideoMetadataResolutionStatus.providerUnavailable);
    expect(mal.searchCalls, 0);
    expect(tmdb.searchCalls, 0);
  });

  test('MAL single-entry season does not reject locally numbered sequel',
      () async {
    final VideoMetadataResolution result = await _resolve(
      _Provider(VideoMetadataProviderKind.mal),
      _Provider(VideoMetadataProviderKind.tmdb),
      season: 2,
    );
    expect(result.status, VideoMetadataResolutionStatus.matched);
    expect(result.providerKind, VideoMetadataProviderKind.mal);
  });

  test('explicit conflicting MAL season and media type still fail gates',
      () async {
    final VideoMetadataResolution seasonResult = await _resolve(
      _Provider(VideoMetadataProviderKind.mal, title: 'Show Season 3'),
      _Provider(VideoMetadataProviderKind.tmdb, empty: true),
      season: 2,
      title: 'Show Season 3',
    );
    expect(seasonResult.status, VideoMetadataResolutionStatus.notFound);
    final VideoMetadataResolution typeResult = await _resolve(
      _Provider(VideoMetadataProviderKind.mal, movie: true),
      _Provider(VideoMetadataProviderKind.tmdb, empty: true),
    );
    expect(typeResult.status, VideoMetadataResolutionStatus.notFound);
  });

  test('MAL URL, prefixed IDs and typed TMDB URL preserve identity', () {
    final List<VideoMetadataLookup> ids = parseExplicitVideoMetadataIds(
      <String>[
        'https://myanimelist.net/anime/42/Title',
        'mal=43',
        'www.myanimelist.net/anime/44',
        '86',
        'https://www.themoviedb.org/movie/45-title',
        'tmdb=46;type=tv',
        'tmdb:movie=47',
        'tmdb:tv=48'
      ],
      fallbackMediaKind: VideoMetadataMediaKind.tv,
    );
    expect(
        ids.map((VideoMetadataLookup id) =>
            '${id.provider.name}:${id.externalId}:${id.mediaKind.name}'),
        <String>[
          'mal:42:tv',
          'mal:43:tv',
          'mal:44:tv',
          'tmdb:45:movie',
          'tmdb:46:tv',
          'tmdb:47:movie',
          'tmdb:48:tv'
        ]);
  });

  for (final bool confirmed in <bool>[false, true]) {
    test(
        'MAL explicit identity uses actual TV type despite local movie guess confirmed=$confirmed',
        () async {
      final _Provider mal = _Provider(VideoMetadataProviderKind.mal);
      final VideoMetadataResolution result = await VideoMetadataResolver(
        registry: VideoMetadataProviderRegistry(<VideoMetadataProvider>[mal]),
      ).resolve(VideoMetadataResolveRequest(
        selectedProvider: VideoMetadataProviderKind.mal,
        mediaKind: VideoMetadataMediaKind.movie,
        titleCandidates: <String>['Unknown'],
        identityHints: confirmed ? <String>[] : <String>['mal=42'],
        confirmedLookup: confirmed
            ? const VideoMetadataLookup(
                provider: VideoMetadataProviderKind.mal,
                externalId: '42',
                mediaKind: VideoMetadataMediaKind.movie)
            : null,
      ));
      expect(result.status, VideoMetadataResolutionStatus.matched);
      expect(result.lookup?.mediaKind, VideoMetadataMediaKind.tv);
      expect(result.work?.kind, VideoMetadataMediaKind.tv);
      expect(mal.searchCalls, 0);
    });
  }

  test('explicit TMDB identity still enforces movie versus TV namespace',
      () async {
    final VideoMetadataResolution result = await VideoMetadataResolver(
      registry: VideoMetadataProviderRegistry(<VideoMetadataProvider>[
        _Provider(VideoMetadataProviderKind.tmdb),
      ]),
    ).resolve(VideoMetadataResolveRequest(
      selectedProvider: VideoMetadataProviderKind.mal,
      fallbackProvider: VideoMetadataProviderKind.tmdb,
      mediaKind: VideoMetadataMediaKind.movie,
      titleCandidates: <String>['Unknown'],
      identityHints: <String>['tmdb:movie=42'],
    ));
    expect(result.status, VideoMetadataResolutionStatus.notFound);
  });

  test('ordinary source names and lookalike domains are not explicit IDs', () {
    expect(
        parseExplicitVideoMetadataIds(<String>[
          '/tmp/mal-hash-coordinator-1234/Show.mkv',
          'anidb-export/Show.mkv',
          'tmdb-backup/Show.mkv',
          'https://fakeanidb.net/anime/42',
          'https://fakethemoviedb.org/movie/42',
        ], fallbackMediaKind: VideoMetadataMediaKind.movie),
        isEmpty);
  });

  test('year-bound search retries without year once per provider', () async {
    // MAL 带年搜空 → 去年份重搜仍空 → 才问 TMDB；TMDB 带年即命中，不重搜。
    final _Provider mal = _Provider(VideoMetadataProviderKind.mal, empty: true);
    final _Provider tmdb = _Provider(VideoMetadataProviderKind.tmdb);
    final VideoMetadataResolution result =
        await _resolve(mal, tmdb, year: 2024);
    expect(result.status, VideoMetadataResolutionStatus.matched);
    expect(result.providerKind, VideoMetadataProviderKind.tmdb);
    expect(mal.searchYears, <int?>[2024, null]);
    expect(tmdb.searchYears, <int?>[2024]);
  });

  test('numeric titles remain title searches', () async {
    final _Provider mal = _Provider(VideoMetadataProviderKind.mal, title: '86');
    final VideoMetadataResolution result = await _resolve(
        mal, _Provider(VideoMetadataProviderKind.tmdb),
        title: '86');
    expect(result.status, VideoMetadataResolutionStatus.matched);
    expect(result.method, VideoMetadataResolutionMethod.exactSearch);
    expect(mal.searchCalls, 1);
  });
}

/// 默认按生产双源策略：[selected] 为主源、另一家为兜底；[singleSource] = true
/// 时不传兜底（AniDB 之类的单源语义）。
Future<VideoMetadataResolution> _resolve(
  _Provider? mal,
  _Provider tmdb, {
  VideoMetadataLookup? confirmed,
  List<String> hints = const <String>[],
  int? season,
  int? year,
  String title = 'Show',
  VideoMetadataProviderKind selected = VideoMetadataProviderKind.mal,
  bool singleSource = false,
}) =>
    VideoMetadataResolver(
        registry: VideoMetadataProviderRegistry(
      <VideoMetadataProvider>[if (mal != null) mal, tmdb],
    )).resolve(VideoMetadataResolveRequest(
      selectedProvider: selected,
      fallbackProvider:
          singleSource ? null : videoMetadataFallbackProvider(selected),
      mediaKind: VideoMetadataMediaKind.tv,
      titleCandidates: <String>[title],
      confirmedLookup: confirmed,
      identityHints: hints,
      seasonNumber: season,
      year: year,
    ));

class _Provider implements VideoMetadataProvider {
  _Provider(this.providerKind,
      {this.empty = false,
      this.failure,
      this.ambiguous = false,
      this.title = 'Show',
      this.movie = false});
  @override
  final VideoMetadataProviderKind providerKind;
  final bool empty;
  final Object? failure;
  final bool ambiguous;
  final String title;
  final bool movie;
  int searchCalls = 0;
  final List<int?> searchYears = <int?>[];
  @override
  bool get isAvailable => true;
  VideoMetadataWork _work(String id) => VideoMetadataWork(
        provider: providerKind,
        kind: movie ? VideoMetadataMediaKind.movie : VideoMetadataMediaKind.tv,
        title: title,
        ids: <VideoMetadataId>[
          VideoMetadataId(type: providerKind.name, value: id)
        ],
      );
  @override
  Future<List<VideoMetadataWork>> search(
      VideoMetadataSearchRequest request) async {
    searchCalls++;
    searchYears.add(request.year);
    final Object? error = failure;
    if (error is Exception) throw error;
    if (error is Error) throw error;
    if (error != null) throw StateError('Unsupported fake failure');
    return empty
        ? <VideoMetadataWork>[]
        : <VideoMetadataWork>[_work('42'), if (ambiguous) _work('43')];
  }

  @override
  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup) async =>
      empty ? null : _work(lookup.externalId);
  @override
  Future<List<VideoMetadataSeason>> fetchSeasons(
          VideoMetadataLookup lookup) async =>
      <VideoMetadataSeason>[];
  @override
  Future<List<VideoMetadataEpisode>> fetchEpisodes(VideoMetadataLookup lookup,
          {required int seasonNumber}) async =>
      <VideoMetadataEpisode>[];
  @override
  void close() {}
}
