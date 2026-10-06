/// 视频发现页「简介语言不对」：动画卡片的主源是 AniList / MAL（简介恒英文），
/// 资料语言是中文时简介必须优先取 TMDB 的资料语言文本——列表合并、详情按 Fribb
/// 交叉引用补 TMDB、TMDB 自身空简介回落译本，三处各钉一条；外加来源 HTML 清洗。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/discovery/anime_tmdb_cross_reference.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_service.dart';
import 'package:fushi_engine/media/video/metadata/anime_identity_mapping.dart';
import 'package:fushi_engine/media/video/metadata/tmdb_video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_json.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_transport.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object payload) => http.Response(
  jsonEncode(payload),
  200,
  headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
);

VideoDiscoveryItem _animeItem({
  required VideoMetadataProviderKind provider,
  required String id,
  required String title,
  String? overview,
  int year = 2026,
  Map<String, String> extraIds = const <String, String>{},
}) {
  final VideoMetadataWork work = VideoMetadataWork(
    provider: provider,
    kind: VideoMetadataMediaKind.tv,
    title: title,
    year: year,
    plot: overview,
    ids: <VideoMetadataId>[
      VideoMetadataId(type: provider.name, value: id, isDefault: true),
      for (final MapEntry<String, String> entry in extraIds.entries)
        VideoMetadataId(type: entry.key, value: entry.value),
    ],
  );
  return VideoDiscoveryItem.fromMetadataWork(
    work: work,
    discoveryCategory: VideoDiscoveryCategory.anime,
    externalId: id,
  );
}

class _RecordingMetadataProvider implements VideoMetadataProvider {
  _RecordingMetadataProvider(this.kind, this.plot);

  final VideoMetadataProviderKind kind;
  final String plot;
  final List<VideoMetadataLookup> lookups = <VideoMetadataLookup>[];

  @override
  VideoMetadataProviderKind get providerKind => kind;

  @override
  bool get isAvailable => true;

  @override
  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup) async {
    lookups.add(lookup);
    return VideoMetadataWork(
      provider: kind,
      kind: lookup.mediaKind,
      title: '${kind.name} title',
      plot: plot,
    );
  }

  @override
  Future<List<VideoMetadataEpisode>> fetchEpisodes(
    VideoMetadataLookup lookup, {
    required int seasonNumber,
  }) async => const <VideoMetadataEpisode>[];

  @override
  Future<List<VideoMetadataSeason>> fetchSeasons(
    VideoMetadataLookup lookup,
  ) async => const <VideoMetadataSeason>[];

  @override
  Future<List<VideoMetadataWork>> search(
    VideoMetadataSearchRequest request,
  ) async => const <VideoMetadataWork>[];

  @override
  void close() {}
}

/// Fribb 全表的一行（《葬送のフリーレン》：MAL 52991 → TMDB tv 209867 第 1 季）。
final List<Object?> _fribbRows = <Object?>[
  <String, Object?>{
    'anidb_id': 17617,
    'mal_id': 52991,
    'themoviedb_id': <String, Object?>{'tv': 209867},
    'season': <String, Object?>{'tmdb': 1},
    'type': 'TV',
  },
  // 没有 TMDB id 的行不进紧凑索引。
  <String, Object?>{'anidb_id': 1, 'mal_id': 1},
];

class _FribbServer {
  _FribbServer({this.status = 200});

  final int status;
  final List<http.Request> requests = <http.Request>[];

  http.Client get client => MockClient((http.Request request) async {
    requests.add(request);
    if (status == 304) return http.Response('', 304);
    if (status != 200) return http.Response('boom', status);
    return http.Response(
      jsonEncode(_fribbRows),
      200,
      headers: <String, String>{
        'content-type': 'application/json',
        'etag': '"v1"',
        'last-modified': 'Mon, 05 Oct 2026 00:00:00 GMT',
      },
    );
  });
}

AnimeTmdbCrossReferenceStore _store(
  Directory directory,
  _FribbServer server, {
  DateTime Function()? now,
}) => AnimeTmdbCrossReferenceStore(
  directory: directory,
  now: now,
  httpClient: VideoMetadataHttpClient(
    client: server.client,
    maxAttempts: 1,
    sleep: (Duration _) async {},
  ),
);

Directory _tempDir() {
  final Directory directory = Directory.systemTemp.createTempSync(
    'fushi_crossref_',
  );
  addTearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });
  return directory;
}

void main() {
  group('list merge picks the overview in the metadata language', () {
    final VideoDiscoveryItem anilist = _animeItem(
      provider: VideoMetadataProviderKind.anilist,
      id: '11',
      title: 'Sousou no Frieren',
      overview: 'The adventure is over but life goes on for an elf mage.',
    );
    final VideoDiscoveryItem tmdb = _animeItem(
      provider: VideoMetadataProviderKind.tmdb,
      id: '209867',
      title: 'Sousou no Frieren',
      overview: '勇者一行人打倒魔王之后，精灵魔法使芙莉莲踏上了新的旅程。',
    );
    const VideoDiscoveryRequest request = VideoDiscoveryRequest(
      feed: VideoDiscoveryFeed.trending,
    );

    test('zh-CN: TMDB Chinese overview wins over the AniList primary', () {
      final List<VideoDiscoveryItem> merged = mergeVideoDiscoveryItems(
        <VideoDiscoveryItem>[anilist, tmdb],
        request: request,
        preferredLanguage: 'zh-CN',
      );
      expect(merged, hasLength(1));
      // 身份仍以动画来源为主（下载 / 刮削不受影响），只换简介。
      expect(merged.single.reference.providerId, 'anilist');
      expect(merged.single.overview, startsWith('勇者一行人'));
    });

    test('en-US keeps the primary source text', () {
      final List<VideoDiscoveryItem> merged = mergeVideoDiscoveryItems(
        <VideoDiscoveryItem>[anilist, tmdb],
        request: request,
        preferredLanguage: 'en-US',
      );
      expect(merged.single.overview, startsWith('The adventure'));
    });

    test('empty TMDB overview falls back to the English text, not blank', () {
      final List<VideoDiscoveryItem> merged = mergeVideoDiscoveryItems(
        <VideoDiscoveryItem>[
          anilist,
          _animeItem(
            provider: VideoMetadataProviderKind.tmdb,
            id: '209867',
            title: 'Sousou no Frieren',
          ),
        ],
        request: request,
        preferredLanguage: 'zh-CN',
      );
      expect(merged.single.overview, startsWith('The adventure'));
    });
  });

  group('Fribb MAL -> TMDB cross reference', () {
    AnimeIdentityEntry entry({
      required int anidb,
      int? tmdb,
      int? season,
      int? offset,
      bool movie = false,
    }) => AnimeIdentityEntry(
      anidbId: anidb,
      malIds: const <int>{52991},
      tmdbId: tmdb,
      tmdbSeason: season,
      tmdbEpisodeOffset: offset,
      tmdbIsMovieNamespace: movie,
    );

    test('unique first-season TMDB tv id is adopted', () {
      final VideoMetadataLookup? lookup = tmdbLookupFromIdentityEntries(
        <AnimeIdentityEntry>[
          entry(anidb: 17617, tmdb: 209867, season: 1, offset: 0),
          // 同 MAL 的特典条目挂在同一部剧的第 0 季：不构成歧义。
          entry(anidb: 18000, tmdb: 209867, season: 0),
        ],
        kind: VideoMetadataMediaKind.tv,
      );
      expect(lookup?.provider, VideoMetadataProviderKind.tmdb);
      expect(lookup?.externalId, '209867');
      expect(lookup?.mediaKind, VideoMetadataMediaKind.tv);
    });

    test('later seasons are not mapped to the whole-series TMDB entry', () {
      expect(
        tmdbLookupFromIdentityEntries(<AnimeIdentityEntry>[
          entry(anidb: 1, tmdb: 500, season: 2, offset: 12),
        ], kind: VideoMetadataMediaKind.tv),
        isNull,
      );
    });

    test('ambiguous or wrong-namespace ids are rejected', () {
      expect(
        tmdbLookupFromIdentityEntries(<AnimeIdentityEntry>[
          entry(anidb: 1, tmdb: 500, season: 1),
          entry(anidb: 2, tmdb: 600, season: 1),
        ], kind: VideoMetadataMediaKind.tv),
        isNull,
      );
      // 剧场版挂在剧特典季下的 tv id 不能当 /movie 用（BUG-2828）。
      expect(
        tmdbLookupFromIdentityEntries(<AnimeIdentityEntry>[
          entry(anidb: 1, tmdb: 500, season: 0),
        ], kind: VideoMetadataMediaKind.movie),
        isNull,
      );
      expect(
        tmdbLookupFromIdentityEntries(<AnimeIdentityEntry>[
          entry(anidb: 1, tmdb: 700, movie: true),
        ], kind: VideoMetadataMediaKind.movie)?.externalId,
        '700',
      );
    });
  });

  group('persisted MAL -> TMDB cross reference index', () {
    test(
      'lookups never hit the network; refresh persists a compact index',
      () async {
        final Directory directory = _tempDir();
        final _FribbServer server = _FribbServer();
        final AnimeTmdbCrossReferenceStore store = _store(directory, server);
        addTearDown(store.close);

        // 没有本地索引：查询返回 null，且不联网。
        expect(await store.entriesForMal(52991), isNull);
        expect(server.requests, isEmpty);

        final Future<void> updated = store.updates.first;
        expect(await store.refreshIfStale(), isTrue);
        await updated;
        expect(server.requests, hasLength(1));
        final List<AnimeIdentityEntry>? entries = await store.entriesForMal(
          52991,
        );
        expect(entries?.single.tmdbId, 209867);
        expect(entries?.single.tmdbSeason, 1);
        expect(await store.entriesForMal(1), isEmpty);

        final File file = File(
          '${directory.path}/${AnimeTmdbCrossReferenceStore.fileName}',
        );
        expect(file.existsSync(), isTrue);
        expect(file.readAsStringSync(), isNot(contains('anidb_id')));
      },
    );

    test('a restart reads the disk copy and does not download again', () async {
      final Directory directory = _tempDir();
      final AnimeTmdbCrossReferenceStore seed = _store(
        directory,
        _FribbServer(),
      );
      await seed.refreshIfStale();
      seed.close();

      final _FribbServer second = _FribbServer();
      final AnimeTmdbCrossReferenceStore restarted = _store(directory, second);
      addTearDown(restarted.close);
      expect((await restarted.entriesForMal(52991))?.single.tmdbId, 209867);
      expect(await restarted.refreshIfStale(), isFalse);
      expect(second.requests, isEmpty, reason: '一周内重启不再下载');
    });

    test('weekly check is conditional and keeps the index on 304', () async {
      final Directory directory = _tempDir();
      DateTime clock = DateTime(2026, 10, 5);
      final AnimeTmdbCrossReferenceStore seed = _store(
        directory,
        _FribbServer(),
        now: () => clock,
      );
      await seed.refreshIfStale();
      seed.close();

      clock = clock.add(const Duration(days: 8));
      final _FribbServer server = _FribbServer(status: 304);
      final AnimeTmdbCrossReferenceStore store = _store(
        directory,
        server,
        now: () => clock,
      );
      addTearDown(store.close);
      expect(await store.refreshIfStale(), isFalse);
      expect(server.requests.single.headers['If-None-Match'], '"v1"');
      expect(
        server.requests.single.headers['If-Modified-Since'],
        'Mon, 05 Oct 2026 00:00:00 GMT',
      );
      expect((await store.entriesForMal(52991))?.single.tmdbId, 209867);

      // 304 刷新了检查时间：再次启动不再发请求。
      final _FribbServer later = _FribbServer();
      final AnimeTmdbCrossReferenceStore again = _store(
        directory,
        later,
        now: () => clock,
      );
      addTearDown(again.close);
      expect(await again.refreshIfStale(), isFalse);
      expect(later.requests, isEmpty);
    });

    test('a failed download degrades silently and is not retried', () async {
      final _FribbServer server = _FribbServer(status: 503);
      final AnimeTmdbCrossReferenceStore store = _store(_tempDir(), server);
      addTearDown(store.close);

      expect(await store.refreshIfStale(), isFalse);
      expect(await store.entriesForMal(52991), isNull);
      expect(await store.refreshIfStale(), isFalse);
      expect(server.requests, hasLength(1), reason: '本进程失败过就不再重打');
    });

    test('a corrupt index file is treated as missing', () async {
      final Directory directory = _tempDir();
      File(
        '${directory.path}/${AnimeTmdbCrossReferenceStore.fileName}',
      ).writeAsStringSync('{not json');
      final AnimeTmdbCrossReferenceStore store = _store(
        directory,
        _FribbServer(),
      );
      addTearDown(store.close);
      expect(await store.entriesForMal(52991), isNull);
      expect(await store.refreshIfStale(), isTrue);
      expect((await store.entriesForMal(52991))?.single.tmdbId, 209867);
    });
  });

  group('loadDetails supplements AniList anime with TMDB via the index', () {
    List<VideoMetadataProvider> providers(_RecordingMetadataProvider tmdb) =>
        <VideoMetadataProvider>[
          _RecordingMetadataProvider(
            VideoMetadataProviderKind.anilist,
            'The adventure is over.',
          ),
          _RecordingMetadataProvider(
            VideoMetadataProviderKind.mal,
            'Elf mage Frieren and her courageous fellow adventurers...',
          ),
          tmdb,
        ];
    VideoDiscoveryItem item() => _animeItem(
      provider: VideoMetadataProviderKind.anilist,
      id: '154587',
      title: '葬送のフリーレン',
      overview: 'The adventure is over.',
      extraIds: const <String, String>{'mal': '52991'},
    );

    test('first open does not wait for the index; Chinese arrives after the '
        'background refresh', () async {
      final _FribbServer server = _FribbServer();
      final _RecordingMetadataProvider tmdb = _RecordingMetadataProvider(
        VideoMetadataProviderKind.tmdb,
        '勇者一行人打倒魔王之后的故事。',
      );
      final VideoDiscoveryService service = VideoDiscoveryService(
        providers: const <VideoDiscoveryProvider>[],
        metadataLocale: 'zh-CN',
        crossReference: _store(_tempDir(), server),
        closesProviders: true,
        metadataProviders: providers(tmdb),
      );
      addTearDown(service.close);
      final Future<void> updated = service.detailsUpdates.first;

      final VideoMetadataWork? first = await service.loadDetails(item());
      expect(tmdb.lookups, isEmpty, reason: '索引还没有时不等下载');
      expect(first?.plot, isNot(contains('勇者')));

      await updated;
      final VideoMetadataWork? second = await service.loadDetails(item());
      expect(tmdb.lookups.single.externalId, '209867');
      expect(tmdb.lookups.single.mediaKind, VideoMetadataMediaKind.tv);
      expect(second?.plot, '勇者一行人打倒魔王之后的故事。');
      expect(server.requests, hasLength(1));
    });

    test('English metadata language never touches the index', () async {
      final _FribbServer server = _FribbServer();
      final _RecordingMetadataProvider tmdb = _RecordingMetadataProvider(
        VideoMetadataProviderKind.tmdb,
        'unused',
      );
      final VideoDiscoveryService service = VideoDiscoveryService(
        providers: const <VideoDiscoveryProvider>[],
        metadataLocale: 'en-US',
        crossReference: _store(_tempDir(), server),
        closesProviders: true,
        metadataProviders: providers(tmdb),
      );
      addTearDown(service.close);

      final VideoMetadataWork? work = await service.loadDetails(item());

      expect(server.requests, isEmpty);
      expect(tmdb.lookups, isEmpty);
      // 英文资料语言：MAL 主源的英文简介本来就对。
      expect(
        work?.plot,
        'Elf mage Frieren and her courageous fellow adventurers...',
      );
    });
  });

  group('TMDB details overview', () {
    Map<String, Object?> payload({required String overview}) =>
        <String, Object?>{
          'id': 100,
          'name': '葬送的芙莉莲',
          'original_name': '葬送のフリーレン',
          'original_language': 'ja',
          'first_air_date': '2023-09-29',
          'overview': overview,
          'translations': <String, Object?>{
            'translations': <Object?>[
              <String, Object?>{
                'iso_639_1': 'en',
                'iso_3166_1': 'US',
                'data': <String, Object?>{'overview': 'English overview.'},
              },
              <String, Object?>{
                'iso_639_1': 'zh',
                'iso_3166_1': 'TW',
                'data': <String, Object?>{'overview': '繁體中文簡介。'},
              },
              <String, Object?>{
                'iso_639_1': 'ja',
                'iso_3166_1': 'JP',
                'data': <String, Object?>{'overview': '日本語のあらすじ。'},
              },
            ],
          },
        };
    const VideoMetadataLookup lookup = VideoMetadataLookup(
      provider: VideoMetadataProviderKind.tmdb,
      externalId: '100',
      mediaKind: VideoMetadataMediaKind.tv,
    );

    Future<({VideoMetadataWork? work, List<Uri> requests})> fetch(
      String language,
      String overview,
    ) async {
      final List<Uri> requests = <Uri>[];
      final TmdbVideoMetadataProvider provider = TmdbVideoMetadataProvider(
        apiKey: 'KEY',
        language: language,
        client: MockClient((http.Request request) async {
          requests.add(request.url);
          if (request.url.path.endsWith('/tv/100')) {
            return _json(payload(overview: overview));
          }
          return _json(<String, Object?>{});
        }),
      );
      final VideoMetadataWork? work = await provider.fetchWork(lookup);
      provider.close();
      return (work: work, requests: requests);
    }

    test('requests the metadata language and keeps its overview', () async {
      final ({VideoMetadataWork? work, List<Uri> requests}) result =
          await fetch('zh-CN', '简体中文简介。');
      expect(
        result.requests
            .firstWhere((Uri uri) => uri.path.endsWith('/tv/100'))
            .queryParameters['language'],
        'zh-CN',
      );
      expect(result.work?.plot, '简体中文简介。');
    });

    test(
      'empty zh-CN overview falls back to same-language translation',
      () async {
        final ({VideoMetadataWork? work, List<Uri> requests}) result =
            await fetch('zh-CN', '');
        expect(result.work?.plot, '繁體中文簡介。');
      },
    );

    test('no same-language translation falls back to en-US', () async {
      final ({VideoMetadataWork? work, List<Uri> requests}) result =
          await fetch('ko-KR', '');
      expect(result.work?.plot, 'English overview.');
    });

    test('cache key carries the language on a shared transport', () async {
      int detailRequests = 0;
      final VideoMetadataHttpClient transport = VideoMetadataHttpClient(
        client: MockClient((http.Request request) async {
          if (request.url.path.endsWith('/tv/100')) {
            detailRequests++;
            return _json(
              payload(
                overview: request.url.queryParameters['language'] == 'zh-CN'
                    ? '简体中文简介。'
                    : 'English overview.',
              ),
            );
          }
          return _json(<String, Object?>{});
        }),
      );
      final VideoMetadataWork? zh = await TmdbVideoMetadataProvider(
        apiKey: 'KEY',
        language: 'zh-CN',
        transport: transport,
      ).fetchWork(lookup);
      final VideoMetadataWork? en = await TmdbVideoMetadataProvider(
        apiKey: 'KEY',
        language: 'en-US',
        transport: transport,
      ).fetchWork(lookup);
      transport.close();

      expect(detailRequests, 2);
      expect(zh?.plot, '简体中文简介。');
      expect(en?.plot, 'English overview.');
    });
  });

  group('metadataStripHtml', () {
    test('strips AniList markup and decodes entities', () {
      expect(
        metadataStripHtml(
          'Frieren&#039;s <i>journey</i>.<br><br>\n<br>'
          'Tom &amp; Jerry&nbsp;&#x2014; &amp;lt;tag&amp;gt;<b>!</b>',
        ),
        "Frieren's journey.\n\nTom & Jerry — &lt;tag&gt;!",
      );
    });

    test('blank markup yields null', () {
      expect(metadataStripHtml('<br><i></i>'), isNull);
    });
  });
}
