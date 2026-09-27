// 「整套下载」的系列解析：TMDB collection 拿剧场版，按系列名找同名剧集。
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/discovery/video_franchise.dart';

VideoDiscoveryItem _item(
  String id,
  String title, {
  VideoMetadataMediaKind kind = VideoMetadataMediaKind.movie,
  int? year,
  String provider = 'tmdb',
  String? originalTitle,
}) => VideoDiscoveryItem(
  reference: VideoMediaReference(
    providerId: provider,
    mediaId: id,
    mediaKind: kind,
    discoveryCategory: VideoDiscoveryCategory.anime,
    title: title,
    originalTitle: originalTitle,
    year: year,
    tmdbId: provider == 'tmdb' ? int.tryParse(id) : null,
  ),
);

class _FakeSource implements VideoFranchiseSource {
  _FakeSource({
    this.available = true,
    this.hits = const <String, List<TmdbCollectionHit>>{},
    this.collections = const <int, TmdbCollection>{},
    this.movieCollections = const <int, int>{},
    this.series = const <String, List<VideoDiscoveryItem>>{},
  });

  final bool available;
  final Map<String, List<TmdbCollectionHit>> hits;
  final Map<int, TmdbCollection> collections;
  final Map<int, int> movieCollections;
  final Map<String, List<VideoDiscoveryItem>> series;
  final List<String> seriesQueries = <String>[];

  @override
  bool get isAvailable => available;

  @override
  Future<List<TmdbCollectionHit>> searchCollections(String query) async =>
      hits[query] ?? const <TmdbCollectionHit>[];

  @override
  Future<int?> movieCollectionId(int movieId) async =>
      movieCollections[movieId];

  @override
  Future<TmdbCollection?> fetchCollection(int collectionId) async =>
      collections[collectionId];

  @override
  Future<List<VideoDiscoveryItem>> searchSeries(String query) async {
    seriesQueries.add(query);
    return series[query] ?? const <VideoDiscoveryItem>[];
  }
}

void main() {
  final TmdbCollection doraemonMovies = TmdbCollection(
    id: 10,
    name: 'Doraemon Collection',
    movies: <VideoDiscoveryItem>[
      _item('1', 'Nobita no Kyouryuu', year: 1980),
      _item('2', 'Nobita no Kyouryuu 2006', year: 2006),
      _item('3', 'Stand by Me Doraemon', year: 2014),
    ],
  );

  test('剧集锚点：按名字找 collection，剧场版按年份排，剧集含锚点', () async {
    final VideoDiscoveryItem show = _item(
      '100',
      'Doraemon',
      kind: VideoMetadataMediaKind.tv,
      year: 2005,
    );
    final _FakeSource source = _FakeSource(
      hits: <String, List<TmdbCollectionHit>>{
        'Doraemon': const <TmdbCollectionHit>[
          TmdbCollectionHit(id: 10, name: 'Doraemon Collection'),
          // 以作品名开头但不是同一个系列名的也收（Doraemon ⊂ Doraemon Shorts…），
          // 与作品名毫无关系的不收。
          TmdbCollectionHit(id: 99, name: 'Crayon Shin-chan Collection'),
        ],
      },
      collections: <int, TmdbCollection>{10: doraemonMovies},
      series: <String, List<VideoDiscoveryItem>>{
        'Doraemon': <VideoDiscoveryItem>[
          show,
          _item('101', 'Doraemon', kind: VideoMetadataMediaKind.tv, year: 1979),
          _item('102', 'Doraemon Fans', kind: VideoMetadataMediaKind.tv),
        ],
      },
    );
    final VideoFranchise franchise = (await resolveVideoFranchise(
      source,
      show,
    ))!;
    expect(franchise.name, 'Doraemon');
    expect(
      franchise.movies.map((VideoDiscoveryItem e) => e.reference.year),
      <int>[1980, 2006, 2014],
    );
    expect(
      franchise.series.map((VideoDiscoveryItem e) => e.reference.mediaId),
      <String>['101', '100'],
      reason: '同名的 1979 / 2005 两部都收（按年份排），「Doraemon Fans」不收',
    );
  });

  test('电影锚点：belongs_to_collection 直接定系列，锚点不重复', () async {
    final _FakeSource source = _FakeSource(
      movieCollections: const <int, int>{1: 10},
      collections: <int, TmdbCollection>{10: doraemonMovies},
    );
    final VideoFranchise franchise = (await resolveVideoFranchise(
      source,
      doraemonMovies.movies.first,
    ))!;
    expect(franchise.movies, hasLength(3));
    expect(franchise.series, isEmpty);
    expect(
      source.seriesQueries,
      contains('Doraemon'),
      reason: '剧集那半用去掉 Collection 后缀的系列名去搜',
    );
  });

  test('MAL 来的锚点与 TMDB 搜出的同一部剧按标题 + 年份去重', () async {
    final VideoDiscoveryItem malShow = _item(
      '1234',
      'Doraemon',
      kind: VideoMetadataMediaKind.tv,
      year: 2005,
      provider: 'mal',
    );
    final _FakeSource source = _FakeSource(
      series: <String, List<VideoDiscoveryItem>>{
        'Doraemon': <VideoDiscoveryItem>[
          _item('100', 'Doraemon', kind: VideoMetadataMediaKind.tv, year: 2005),
        ],
      },
    );
    final VideoFranchise franchise = (await resolveVideoFranchise(
      source,
      malShow,
    ))!;
    expect(franchise.series, hasLength(1));
    expect(franchise.series.single.reference.providerId, 'mal');
  });

  test('来源不可用 → null', () async {
    expect(
      await resolveVideoFranchise(
        _FakeSource(available: false),
        doraemonMovies.movies.first,
      ),
      isNull,
    );
  });

  group('videoFranchiseCollectionMatches', () {
    bool matches(String name, String title) => videoFranchiseCollectionMatches(
      TmdbCollectionHit(id: 1, name: name),
      <String>[title],
    );

    test('去掉后缀后相等 / 以作品名开头', () {
      expect(matches('Doraemon Collection', 'Doraemon'), isTrue);
      expect(matches('哆啦A梦（系列）', '哆啦A梦'), isTrue);
      expect(matches('ドラえもん シリーズ', 'ドラえもん'), isTrue);
      expect(matches('Detective Conan Collection', 'Detective Conan'), isTrue);
    });

    test('短名字只认相等，无关系列不收', () {
      expect(matches('Superman Collection', 'Up'), isFalse);
      expect(matches('Up Collection', 'Up'), isTrue);
      expect(matches('Crayon Shin-chan Collection', 'Doraemon'), isFalse);
    });
  });
}
