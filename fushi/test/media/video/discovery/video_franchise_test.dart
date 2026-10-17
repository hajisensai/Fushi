// 「整套下载」的系列解析：TMDB collection 拿剧场版，按系列名找同名剧集。
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/metadata/mal_video_metadata_provider.dart'
    show MalRelatedWorks, MalRelation;
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/discovery/video_franchise.dart';

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

  test('同名剧集要同类别、同原语言：别国同名剧不收', () async {
    VideoDiscoveryItem tv(String id, String language) => VideoDiscoveryItem(
      reference: VideoMediaReference(
        providerId: 'tmdb',
        mediaId: id,
        mediaKind: VideoMetadataMediaKind.tv,
        discoveryCategory: VideoDiscoveryCategory.anime,
        title: 'Monster',
        year: 2004,
      ),
      metadataWork: VideoMetadataWork(
        provider: VideoMetadataProviderKind.tmdb,
        kind: VideoMetadataMediaKind.tv,
        title: 'Monster',
        originalLanguage: language,
      ),
    );
    final VideoDiscoveryItem anchor = tv('1', 'ja');
    final _FakeSource source = _FakeSource(
      series: <String, List<VideoDiscoveryItem>>{
        'Monster': <VideoDiscoveryItem>[
          anchor,
          tv('2', 'ko'),
          _item('3', 'Monster', kind: VideoMetadataMediaKind.tv, year: 1990),
        ],
      },
    );
    final VideoFranchise franchise = (await resolveVideoFranchise(
      source,
      anchor,
    ))!;
    expect(
      franchise.series.map((VideoDiscoveryItem e) => e.reference.mediaId),
      <String>['3', '1'],
      reason: '韩剧 Monster 被原语言挡掉；原语言未知的照收',
    );
  });

  test('锚点名占满时 collection 系列名仍拿去搜剧集', () async {
    final VideoDiscoveryItem anchor = VideoDiscoveryItem(
      reference: VideoMediaReference(
        providerId: 'mal',
        mediaId: '9',
        mediaKind: VideoMetadataMediaKind.movie,
        discoveryCategory: VideoDiscoveryCategory.anime,
        title: 'Name A',
        originalTitle: 'Name B',
        aliases: <String>['Name C', 'Name D'],
      ),
    );
    final _FakeSource source = _FakeSource(
      hits: <String, List<TmdbCollectionHit>>{
        'Name A': const <TmdbCollectionHit>[
          TmdbCollectionHit(id: 5, name: 'Name A Collection'),
        ],
      },
      collections: <int, TmdbCollection>{
        5: TmdbCollection(
          id: 5,
          name: 'Franchise Collection',
          movies: <VideoDiscoveryItem>[],
        ),
      },
    );
    await resolveVideoFranchise(source, anchor);
    expect(source.seriesQueries, contains('Franchise'));
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

  test('合并去重看别名与外部 id：TMDB / MAL 同一部电影只留一条', () {
    final VideoDiscoveryItem tmdbMovie = VideoDiscoveryItem(
      reference: VideoMediaReference(
        providerId: 'tmdb',
        mediaId: '500',
        mediaKind: VideoMetadataMediaKind.movie,
        discoveryCategory: VideoDiscoveryCategory.anime,
        title: '名侦探柯南：贝克街的亡灵',
        originalTitle: '劇場版 名探偵コナン ベイカー街の亡霊',
        year: 2002,
        tmdbId: 500,
      ),
    );
    final VideoDiscoveryItem malByAlias = VideoDiscoveryItem(
      reference: VideoMediaReference(
        providerId: 'mal',
        mediaId: '600',
        mediaKind: VideoMetadataMediaKind.movie,
        discoveryCategory: VideoDiscoveryCategory.anime,
        title: '名探偵コナン ベイカー街の亡霊',
        aliases: const <String>['劇場版 名探偵コナン ベイカー街の亡霊'],
        year: 2002,
      ),
    );
    final VideoDiscoveryItem malById = VideoDiscoveryItem(
      reference: VideoMediaReference(
        providerId: 'mal',
        mediaId: '601',
        mediaKind: VideoMetadataMediaKind.movie,
        discoveryCategory: VideoDiscoveryCategory.anime,
        title: 'Totally Different Romanization',
        externalIds: const <String, String>{'tmdb': '500'},
      ),
    );
    final VideoFranchise merged = mergeVideoFranchises(<VideoFranchise?>[
      VideoFranchise(
        name: 'Conan',
        series: const <VideoDiscoveryItem>[],
        movies: <VideoDiscoveryItem>[tmdbMovie],
      ),
      VideoFranchise(
        name: 'Conan',
        series: const <VideoDiscoveryItem>[],
        movies: <VideoDiscoveryItem>[malByAlias, malById],
      ),
    ])!;
    expect(merged.movies.single.reference.mediaId, '500');
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

    test('只认去后缀后完全相等：前缀相同的别的系列不收', () {
      expect(matches('Superman Collection', 'Up'), isFalse);
      expect(matches('Up Collection', 'Up'), isTrue);
      expect(matches('Crayon Shin-chan Collection', 'Doraemon'), isFalse);
      expect(matches('Air Bud Collection', 'Air'), isFalse);
      expect(matches('Monster High Collection', 'Monster'), isFalse);
    });
  });
  group('resolveMalFranchise', () {
    MalRelatedWorks node(
      int id,
      String title,
      String type,
      int year,
      List<MalRelation> relations, {
      int? runtime,
    }) => MalRelatedWorks(
      work: VideoMetadataWork(
        provider: VideoMetadataProviderKind.mal,
        kind: type == 'Movie'
            ? VideoMetadataMediaKind.movie
            : VideoMetadataMediaKind.tv,
        title: title,
        year: year,
        runtimeMinutes: runtime,
        ids: <VideoMetadataId>[
          VideoMetadataId(type: 'mal', value: '$id', isDefault: true),
        ],
      ),
      malType: type,
      relations: relations,
    );

    test('沿续作 / 外传 / 重制走；OVA、PV 不收；Other / Spin-off 不走', () async {
      final _FakeMal mal = _FakeMal(<int, MalRelatedWorks>{
        1: node(1, 'Doraemon', 'TV', 2005, const <MalRelation>[
          MalRelation(relation: 'Side story', malId: 2),
          MalRelation(relation: 'Alternative version', malId: 3),
          MalRelation(relation: 'Other', malId: 9),
          MalRelation(relation: 'Spin-off', malId: 8),
        ]),
        2: node(2, 'Movie 1980', 'Movie', 1980, const <MalRelation>[
          MalRelation(relation: 'Sequel', malId: 4),
          MalRelation(relation: 'Parent story', malId: 1),
        ]),
        3: node(3, 'Doraemon 1979', 'TV', 1979, const <MalRelation>[]),
        4: node(4, 'Movie 1981', 'Movie', 1981, const <MalRelation>[
          MalRelation(relation: 'Side story', malId: 5),
        ]),
        5: node(5, 'Bonus OVA', 'OVA', 1982, const <MalRelation>[]),
        8: node(8, 'Spin-off', 'TV', 2010, const <MalRelation>[]),
        9: node(9, 'Crossover', 'Movie', 2011, const <MalRelation>[]),
      });
      final VideoFranchise franchise = (await resolveMalFranchise(
        mal,
        _item(
          '1',
          'Doraemon',
          kind: VideoMetadataMediaKind.tv,
          provider: 'mal',
        ),
      ))!;
      expect(
        franchise.series.map((VideoDiscoveryItem e) => e.reference.mediaId),
        <String>['3', '1'],
      );
      expect(
        franchise.movies.map((VideoDiscoveryItem e) => e.reference.mediaId),
        <String>['2', '4'],
      );
      expect(mal.fetched, isNot(contains(8)));
      expect(mal.fetched, isNot(contains(9)));
      expect(franchise.truncated, isFalse);
    });

    // BUG-2937：一批走满不是「到此为止」——交出到目前为止的结果和续查入口，
    // 接着走直到图走完。
    test('BUG-2937 一批走满就交出，经 more 从断点接着走完', () async {
      final _FakeMal mal = _FakeMal(<int, MalRelatedWorks>{
        for (int i = 1; i <= 10; i++)
          i: node(i, 'Movie $i', 'Movie', 1980 + i, <MalRelation>[
            MalRelation(relation: 'Sequel', malId: i + 1),
          ]),
      });
      final VideoFranchise first = (await resolveMalFranchise(
        mal,
        _item('1', 'Movie 1', provider: 'mal'),
        batchSize: 3,
      ))!;
      expect(first.movies, hasLength(3));
      expect(mal.fetched, <int>[1, 2, 3]);
      expect(first.more, isNotNull);
      expect(first.truncated, isFalse, reason: '没走完但能接着走，不是失败');

      final (:VideoFranchise last, :int batches) = await _drain(first);
      // 每一批交的是到目前为止的全部，不只是新增的。
      expect(last.movies, hasLength(10));
      // 第 11 部不存在（404 → null）也要请求一次才知道。
      expect(mal.fetched, <int>[for (int i = 1; i <= 11; i++) i]);
      expect(batches, 4);
      expect(last.more, isNull);
      expect(last.truncated, isFalse);
    });

    // BUG-2935：MAL 上哆啦A梦的真实关系形状（2026-10-04 核对 MAL 页面）。2005 版
    // 只挂 26 部剧场版 + 1 部 TV Special 的外传，没有指回 1979 版的前传；1979 版挂
    // 26 部剧场版 + 11 部特别篇的外传、前作 1973 版。从 2005 版出发要经新剧场版的
    // 「Alternative version」（重制）走到旧剧场版，再经「Parent story」回到 1979 版。
    // 共 67 个节点——旧上限 60 会截掉最后 7 个，且不留任何标记。截掉的是剧场版还是
    // 特别篇取决于 MAL 关联的返回顺序（这张图里恰好全是特别篇），所以只钉「必然没走完」。
    Map<int, MalRelatedWorks> doraemonGraph() {
      const int tv2005 = 8687, tv1979 = 2471, tv1973 = 1973;
      List<int> range(int from, int count) => <int>[
        for (int i = 0; i < count; i++) from + i,
      ];
      final List<int> newMovies = range(3001, 26);
      final List<int> oldMovies = range(2001, 26);
      final List<int> oldSpecials = range(2101, 11);
      return <int, MalRelatedWorks>{
        tv2005: node(tv2005, 'Doraemon (2005)', 'TV', 2005, <MalRelation>[
          for (final int id in newMovies)
            MalRelation(relation: 'Side story', malId: id),
          const MalRelation(relation: 'Side story', malId: 3100),
        ]),
        3100: node(
          3100,
          'TV Special 2005',
          'TV Special',
          2007,
          const <MalRelation>[],
        ),
        for (int i = 0; i < newMovies.length; i++)
          newMovies[i]: node(
            newMovies[i],
            'New Movie $i',
            'Movie',
            2006 + i,
            <MalRelation>[
              const MalRelation(relation: 'Parent story', malId: tv2005),
              // 前 10 部是旧片重制。
              if (i < 10)
                MalRelation(
                  relation: 'Alternative version',
                  malId: oldMovies[i],
                ),
            ],
          ),
        tv1979: node(tv1979, 'Doraemon (1979)', 'TV', 1979, <MalRelation>[
          const MalRelation(relation: 'Prequel', malId: tv1973),
          const MalRelation(relation: 'Sequel', malId: tv2005),
          for (final int id in <int>[...oldMovies, ...oldSpecials])
            MalRelation(relation: 'Side story', malId: id),
        ]),
        tv1973: node(tv1973, 'Doraemon (1973)', 'TV', 1973, const <MalRelation>[
          MalRelation(relation: 'Sequel', malId: tv1979),
        ]),
        for (int i = 0; i < oldMovies.length; i++)
          oldMovies[i]: node(oldMovies[i], 'Old Movie $i', 'Movie', 1980 + i, <
            MalRelation
          >[
            const MalRelation(relation: 'Parent story', malId: tv1979),
            if (i < 10)
              MalRelation(relation: 'Alternative version', malId: newMovies[i]),
          ]),
        for (int i = 0; i < oldSpecials.length; i++)
          oldSpecials[i]: node(
            oldSpecials[i],
            'Old Special $i',
            'Special',
            1981 + i,
            const <MalRelation>[
              MalRelation(relation: 'Parent story', malId: tv1979),
            ],
          ),
      };
    }

    test('哆啦A梦（从 2005 版出发）：分批走完，收全 52 部剧场版与三部 TV', () async {
      final _FakeMal mal = _FakeMal(doraemonGraph());
      final VideoFranchise first = (await resolveMalFranchise(
        mal,
        _item(
          '8687',
          'Doraemon (2005)',
          kind: VideoMetadataMediaKind.tv,
          provider: 'mal',
        ),
      ))!;
      expect(mal.fetched, hasLength(kVideoFranchiseMalBatch));
      final (:VideoFranchise last, :int batches) = await _drain(first);
      expect(batches, 2);
      expect(last.movies, hasLength(52));
      expect(
        last.series.map((VideoDiscoveryItem e) => e.reference.mediaId),
        <String>['1973', '2471', '8687'],
      );
      expect(last.truncated, isFalse);
      expect(mal.fetched, hasLength(67));
    });

    test('BUG-2937 哆啦A梦在第 60 个请求处分批：不标 truncated，续查后一部不少', () async {
      // 旧做法：上限 60 撞上就停、标 truncated（BUG-2935），用户拿到半张清单。
      final _FakeMal mal = _FakeMal(doraemonGraph());
      final VideoFranchise first = (await resolveMalFranchise(
        mal,
        _item(
          '8687',
          'Doraemon (2005)',
          kind: VideoMetadataMediaKind.tv,
          provider: 'mal',
        ),
        batchSize: 60,
      ))!;
      expect(mal.fetched, hasLength(60));
      expect(first.truncated, isFalse);
      expect(first.more, isNotNull);
      final (:VideoFranchise last, batches: _) = await _drain(first);
      expect(last.movies, hasLength(52));
      expect(mal.fetched, hasLength(67));
      expect(mal.fetched.toSet(), hasLength(67), reason: '续查不重复请求');
    });

    test('合并：任一份 truncated，结果就是 truncated', () {
      const VideoFranchise complete = VideoFranchise(
        name: 'Doraemon',
        series: <VideoDiscoveryItem>[],
        movies: <VideoDiscoveryItem>[],
      );
      const VideoFranchise partial = VideoFranchise(
        name: 'Doraemon',
        series: <VideoDiscoveryItem>[],
        movies: <VideoDiscoveryItem>[],
        truncated: true,
      );
      expect(
        mergeVideoFranchises(<VideoFranchise?>[complete, partial])!.truncated,
        isTrue,
      );
      expect(
        mergeVideoFranchises(<VideoFranchise?>[complete, null])!.truncated,
        isFalse,
      );
    });

    test('BUG-2937 合并保留续查入口：TMDB + MAL 第一批合并后仍能接着查', () {
      Future<VideoFranchise> rest() async => const VideoFranchise(
        name: 'Doraemon',
        series: <VideoDiscoveryItem>[],
        movies: <VideoDiscoveryItem>[],
      );
      const VideoFranchise tmdb = VideoFranchise(
        name: 'Doraemon Collection',
        series: <VideoDiscoveryItem>[],
        movies: <VideoDiscoveryItem>[],
      );
      final VideoFranchise mal = VideoFranchise(
        name: 'Doraemon',
        series: const <VideoDiscoveryItem>[],
        movies: const <VideoDiscoveryItem>[],
        more: rest,
      );
      final VideoFranchise merged = mergeVideoFranchises(<VideoFranchise?>[
        tmdb,
        mal,
      ])!;
      expect(merged.more, same(rest));
      expect(merged.name, 'Doraemon Collection');
      expect(merged.withoutMore().more, isNull);
      expect(mergeVideoFranchises(<VideoFranchise?>[tmdb, null])!.more, isNull);
    });

    test('锚点没有 MAL 身份：按标题搜，只认标题完全一致的', () async {
      final _FakeMal mal = _FakeMal(
        <int, MalRelatedWorks>{
          7: node(7, 'Doraemon', 'TV', 2005, const <MalRelation>[]),
        },
        search: <String, List<VideoMetadataWork>>{
          'Doraemon': <VideoMetadataWork>[
            VideoMetadataWork(
              provider: VideoMetadataProviderKind.mal,
              kind: VideoMetadataMediaKind.tv,
              title: 'Doraemon: Nobita',
              ids: const <VideoMetadataId>[
                VideoMetadataId(type: 'mal', value: '99'),
              ],
            ),
            VideoMetadataWork(
              provider: VideoMetadataProviderKind.mal,
              kind: VideoMetadataMediaKind.tv,
              title: 'Doraemon',
              ids: const <VideoMetadataId>[
                VideoMetadataId(type: 'mal', value: '7'),
              ],
            ),
          ],
        },
      );
      final VideoFranchise franchise = (await resolveMalFranchise(
        mal,
        _item('100', 'Doraemon', kind: VideoMetadataMediaKind.tv),
      ))!;
      expect(franchise.series.single.reference.mediaId, '7');
    });

    test('走到一半请求失败：停下并交出已收集的', () async {
      final _FakeMal mal = _FakeMal(<int, MalRelatedWorks>{
        1: node(1, 'Movie 1', 'Movie', 1980, const <MalRelation>[
          MalRelation(relation: 'Sequel', malId: 2),
        ]),
        2: node(2, 'Movie 2', 'Movie', 1981, const <MalRelation>[
          MalRelation(relation: 'Sequel', malId: 3),
        ]),
      }, failOn: 3);
      final VideoFranchise franchise = (await resolveMalFranchise(
        mal,
        _item('1', 'Movie 1', provider: 'mal'),
      ))!;
      expect(franchise.movies, hasLength(2));
      expect(franchise.truncated, isTrue);
      expect(franchise.more, isNull, reason: '失败就停，不再续查');
    });

    test('BUG-2936 第一个请求就失败：空清单也要标没走完，而不是「没有同系列」', () async {
      final VideoFranchise franchise = (await resolveMalFranchise(
        _FakeMal(const <int, MalRelatedWorks>{}, failOn: 1),
        _item('1', 'Doraemon', provider: 'mal'),
      ))!;
      expect(franchise.length, 0);
      expect(franchise.truncated, isTrue);
    });

    test('BUG-2936 短于长片下限的 Movie 是同映短片，不收；片长未知照收', () async {
      // MAL 2471 的 Side story 里，剧场版之间夹着「Ken-chan no Bouken」
      // 「Boku, Momotarou no Nanna no Sa」、The☆Doraemons 等 15–30 分钟短片，
      // 类型同样是 Movie。
      final _FakeMal mal = _FakeMal(<int, MalRelatedWorks>{
        1: node(1, 'Doraemon (1979)', 'TV', 1979, const <MalRelation>[
          MalRelation(relation: 'Side story', malId: 2),
          MalRelation(relation: 'Side story', malId: 3),
          MalRelation(relation: 'Side story', malId: 4),
          MalRelation(relation: 'Side story', malId: 5),
        ]),
        2: node(
          2,
          'Doraemon Movie 01',
          'Movie',
          1980,
          const <MalRelation>[],
          runtime: 92,
        ),
        3: node(
          3,
          'Ken-chan no Bouken',
          'Movie',
          1981,
          const <MalRelation>[],
          runtime: 15,
        ),
        4: node(
          4,
          'Exactly forty minutes',
          'Movie',
          1982,
          const <MalRelation>[],
          runtime: kVideoFranchiseMinFeatureMinutes,
        ),
        5: node(5, 'Unknown runtime', 'Movie', 1983, const <MalRelation>[]),
      });
      final VideoFranchise franchise = (await resolveMalFranchise(
        mal,
        _item(
          '1',
          'Doraemon (1979)',
          kind: VideoMetadataMediaKind.tv,
          provider: 'mal',
        ),
      ))!;
      expect(
        franchise.movies.map((VideoDiscoveryItem e) => e.reference.mediaId),
        <String>['2', '4', '5'],
      );
      expect(franchise.truncated, isFalse);
    });

    test('同名新旧版按年份选起点', () async {
      VideoMetadataWork hit(String id, int year) => VideoMetadataWork(
        provider: VideoMetadataProviderKind.mal,
        kind: VideoMetadataMediaKind.tv,
        title: 'Hunter x Hunter',
        year: year,
        ids: <VideoMetadataId>[VideoMetadataId(type: 'mal', value: id)],
      );
      final _FakeMal mal = _FakeMal(
        <int, MalRelatedWorks>{
          11: node(11, 'Hunter x Hunter', 'TV', 2011, const <MalRelation>[]),
        },
        search: <String, List<VideoMetadataWork>>{
          'Hunter x Hunter': <VideoMetadataWork>[
            hit('136', 1999),
            hit('11', 2011),
          ],
        },
      );
      final VideoFranchise franchise = (await resolveMalFranchise(
        mal,
        _item(
          '9',
          'Hunter x Hunter',
          kind: VideoMetadataMediaKind.tv,
          year: 2011,
        ),
      ))!;
      expect(franchise.series.single.reference.mediaId, '11');
    });

    test('搜不到 MAL 身份 → null', () async {
      expect(
        await resolveMalFranchise(
          _FakeMal(const <int, MalRelatedWorks>{}),
          _item('100', 'Nothing', kind: VideoMetadataMediaKind.tv),
        ),
        isNull,
      );
    });
  });
}

/// 沿 [VideoFranchise.more] 一直续查到底；`batches` 含第一批。
Future<({VideoFranchise last, int batches})> _drain(
  VideoFranchise first,
) async {
  VideoFranchise current = first;
  int batches = 1;
  for (
    Future<VideoFranchise> Function()? more = current.more;
    more != null;
    more = current.more
  ) {
    current = await more();
    batches++;
  }
  return (last: current, batches: batches);
}

class _FakeMal implements VideoFranchiseRelationSource {
  _FakeMal(
    this.works, {
    this.search = const <String, List<VideoMetadataWork>>{},
    this.failOn,
  });

  final int? failOn;

  final Map<int, MalRelatedWorks> works;
  final Map<String, List<VideoMetadataWork>> search;
  final List<int> fetched = <int>[];

  @override
  Future<MalRelatedWorks?> fetchRelatedWorks(String malId) async {
    final int id = int.parse(malId);
    fetched.add(id);
    if (id == failOn) throw StateError('jikan 504');
    return works[id];
  }

  @override
  Future<List<VideoMetadataWork>> searchAnime(String title) async =>
      search[title] ?? const <VideoMetadataWork>[];
}
