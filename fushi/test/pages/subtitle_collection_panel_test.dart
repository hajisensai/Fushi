import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/download/video_subtitle_registry.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/pages/implementations/subtitle_collection_panel.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 合集批量面板（前身 `JimakuBatchDialog`，现走 registry）的状态门：
/// 搜索失败 → 提示 + 下载禁用；搜索中禁用、非空后开放；快速切系列时迟到的旧响应
/// 不覆盖新结果、DB 保留最新系列。
class _Cand extends VideoSubtitleCandidate {
  _Cand(String name, {required String source, int? episode})
    : super(
        providerId: 'fake',
        remoteId: '$source:$name',
        fileName: name,
        language: 'ja',
        providerPriority: 1,
        episode: episode,
        collectionId: source,
        collectionLabel: source,
      );
}

typedef _Search =
    Future<ProviderBatchResult<VideoSubtitleCandidate>> Function(
      VideoSubtitleSearchRequest request,
    );

class _FakeProvider implements VideoSubtitleProvider {
  _FakeProvider(this.onSearch);

  final _Search onSearch;

  @override
  String get id => 'fake';
  @override
  int get priority => 1;
  @override
  bool get allowsFreeProbeDownload => true;
  @override
  void close() {}
  @override
  Future<ProviderBatchResult<VideoSubtitleCandidate>> search(
    VideoSubtitleSearchRequest request,
  ) => onSearch(request);
  @override
  Future<VideoSubtitleDownload> download(VideoSubtitleCandidate candidate) =>
      throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late VideoBookRepository repo;
  late Directory tempDir;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = VideoBookRepository(db);
    tempDir = await Directory.systemTemp.createTemp('subtitle_collection_');
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<VideoBookRow> seedMember() async {
    await db.upsertVideoBook(
      const VideoBooksCompanion(
        bookUid: Value<String>('video/show-01'),
        title: Value<String>('Show - 01'),
        videoPath: Value<String>('C:/video/Show - 01.mkv'),
      ),
    );
    return (await repo.getByBookUid('video/show-01'))!;
  }

  Future<MediaCollectionRow> seedCollection({int? anilistId}) async {
    final int id = await db.createMediaCollection(
      'Show',
      collectionType: 'collection',
    );
    if (anilistId != null) await db.setMediaCollectionAnilistId(id, anilistId);
    return (await db.getMediaCollectionById(id))!;
  }

  Widget wrap({
    required MediaCollectionRow collection,
    required VideoBookRow member,
    required _Search onSearch,
    Future<http.Client> Function()? httpClientFactory,
  }) {
    final VideoSubtitleRegistry registry = VideoSubtitleRegistry(
      <VideoSubtitleProvider>[_FakeProvider(onSearch)],
    );
    return TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: SubtitleCollectionPanel(
            database: db,
            collection: collection,
            members: <VideoBookRow>[member],
            subtitleRegistry: () => registry,
            initialApiKey: 'test-key',
            onApiKeyChanged: (_) async {},
            saveDirectory: tempDir.path,
            onRemoteSubtitlePersist: (_, __) async {},
            httpClientFactory: httpClientFactory,
          ),
        ),
      ),
    );
  }

  /// 给合集挂一条已刮削的规范作品 + provider 身份行。
  Future<void> seedCanonicalWork({
    required int collectionId,
    required String mediaType,
    required String title,
    String? originalTitle,
    int? year,
    required Map<String, String> externalIds,
  }) async {
    final int workId = await db.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        collectionId: Value<int?>(collectionId),
        mediaType: mediaType,
        title: title,
        originalTitle: Value<String?>(originalTitle),
        year: Value<int?>(year),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    await db.replaceVideoMetadataProviderIdentities(
      workId: workId,
      identities: <VideoMetadataProviderIdentitiesCompanion>[
        for (final MapEntry<String, String> entry in externalIds.entries)
          VideoMetadataProviderIdentitiesCompanion.insert(
            identityKey: 'work:$workId:${entry.key}',
            workId: Value<int?>(workId),
            provider: entry.key,
            externalId: entry.value,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ),
      ],
    );
  }

  Finder downloadButton() =>
      find.byKey(const ValueKey<String>('subtitle-collection-download-all'));

  testWidgets('已刮削合集的首搜带规范身份：外部 id / 原名 / 年份全带，分类由 id 推（BUG-2008）', (
    WidgetTester tester,
  ) async {
    final VideoBookRow member = await seedMember();
    // 合集已绑 AniList = 面板 initState 会自动首搜。首搜必须等规范身份读回来，
    // 否则「刮过的合集」这条最常见路径永远还是裸显示名。
    final MediaCollectionRow collection = await seedCollection(anilistId: 21);
    await seedCanonicalWork(
      collectionId: collection.id,
      mediaType: 'tv',
      title: 'Show',
      originalTitle: '進撃の巨人',
      year: 2013,
      externalIds: <String, String>{
        'anidb': '8692',
        'anilist': '16498',
        'tmdb': '1429',
        'imdb': 'tt2560140',
      },
    );
    final List<VideoSubtitleSearchRequest> requests =
        <VideoSubtitleSearchRequest>[];
    await tester.pumpWidget(
      wrap(
        collection: collection,
        member: member,
        onSearch: (VideoSubtitleSearchRequest request) async {
          requests.add(request);
          return ProviderBatchResult<VideoSubtitleCandidate>.success(
            const <VideoSubtitleCandidate>[],
          );
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(requests, hasLength(1));
    final VideoMediaReference media = requests.single.media!;
    expect(media.anidbId, 8692);
    expect(media.tmdbId, 1429);
    expect(media.imdbId, 'tt2560140');
    expect(media.originalTitle, '進撃の巨人');
    expect(media.year, 2013);
    expect(media.discoveryCategory, VideoDiscoveryCategory.anime);
    // 用户没动过查询词 → 换成日文原名。
    expect(requests.single.effectiveQuery, '進撃の巨人');
    // 合集绑定的 AniList id 仍是检索键。
    expect(media.anilistId, 21);
  });

  testWidgets('真人剧合集不再写死 anime 分类（BUG-2008 / BUG-1694）', (
    WidgetTester tester,
  ) async {
    final VideoBookRow member = await seedMember();
    // 真人剧没有 AniList 身份：合集不绑 anilistId，刮削身份只有 tmdb/imdb。
    final MediaCollectionRow collection = await seedCollection();
    await seedCanonicalWork(
      collectionId: collection.id,
      mediaType: 'tv',
      title: 'Live Action Show',
      year: 2011,
      externalIds: <String, String>{'tmdb': '1396', 'imdb': 'tt0903747'},
    );
    Future<http.Client> factory() async {
      return MockClient((http.Request request) async {
        if (request.url.host == 'graphql.anilist.co') {
          return http.Response(
            jsonEncode(<String, Object?>{
              'data': <String, Object?>{
                'Page': <String, Object?>{'media': <Object?>[]},
              },
            }),
            200,
          );
        }
        return http.Response('not found', 404);
      });
    }

    final List<VideoSubtitleSearchRequest> requests =
        <VideoSubtitleSearchRequest>[];
    await tester.pumpWidget(
      wrap(
        collection: collection,
        member: member,
        httpClientFactory: factory,
        onSearch: (VideoSubtitleSearchRequest request) async {
          requests.add(request);
          return ProviderBatchResult<VideoSubtitleCandidate>.success(
            const <VideoSubtitleCandidate>[],
          );
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.video_jimaku_find_sources));
    await tester.pumpAndSettle();

    expect(requests, hasLength(1));
    final VideoMediaReference media = requests.single.media!;
    // 没有 anidb/anilist 身份 = 不是动画：Jimaku 的 anime 硬过滤必须走 false 档，
    // 写死 anime 会让真人剧合集一条字幕都搜不到（BUG-1694）。
    expect(media.discoveryCategory, VideoDiscoveryCategory.tv);
    // OpenSubtitles 的强键：imdb 直查，命中率与文本搜不在一个量级。
    expect(media.imdbId, 'tt0903747');
    expect(media.tmdbId, 1396);
    expect(media.year, 2011);
    expect(media.anilistId, isNull);
  });

  testWidgets('来源搜索失败 → 面板内提示，下载保持禁用', (WidgetTester tester) async {
    final VideoBookRow member = await seedMember();
    final MediaCollectionRow collection = await seedCollection(anilistId: 21);
    await tester.pumpWidget(
      wrap(
        collection: collection,
        member: member,
        onSearch: (_) async =>
            ProviderBatchResult<VideoSubtitleCandidate>.failure(
              const ExternalProviderFailure(
                providerId: 'fake',
                operation: 'search',
                kind: ExternalProviderFailureKind.unavailable,
                message: 'down',
                statusCode: 503,
              ),
            ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining(t.video_jimaku_search_failed), findsOneWidget);
    expect(tester.widget<FilledButton>(downloadButton()).onPressed, isNull);
  });

  testWidgets('搜索中禁用；返回非空候选后才开放下载', (WidgetTester tester) async {
    final VideoBookRow member = await seedMember();
    final MediaCollectionRow collection = await seedCollection(anilistId: 21);
    final Completer<ProviderBatchResult<VideoSubtitleCandidate>> pending =
        Completer<ProviderBatchResult<VideoSubtitleCandidate>>();
    await tester.pumpWidget(
      wrap(
        collection: collection,
        member: member,
        onSearch: (_) => pending.future,
      ),
    );
    await tester.pump();
    expect(find.text(t.video_jimaku_source_loading), findsWidgets);
    expect(tester.widget<FilledButton>(downloadButton()).onPressed, isNull);

    pending.complete(
      ProviderBatchResult<VideoSubtitleCandidate>.success(
        <VideoSubtitleCandidate>[
          _Cand('Show - 01.ja.srt', source: 'Source', episode: 1),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(downloadButton()).onPressed, isNotNull);
    expect(
      find.byKey(const ValueKey<String>('subtitle-source-fake:Source')),
      findsOneWidget,
    );
  });

  testWidgets('快速切系列时迟到旧响应不覆盖新来源，DB 也保留最新系列', (WidgetTester tester) async {
    final VideoBookRow member = await seedMember();
    final MediaCollectionRow collection = await seedCollection();
    final Completer<ProviderBatchResult<VideoSubtitleCandidate>> staleB =
        Completer<ProviderBatchResult<VideoSubtitleCandidate>>();
    int seriesACalls = 0;

    Future<http.Client> factory() async {
      return MockClient((http.Request request) async {
        if (request.url.host == 'graphql.anilist.co') {
          return http.Response(
            jsonEncode(<String, Object?>{
              'data': <String, Object?>{
                'Page': <String, Object?>{
                  'media': <Object?>[
                    <String, Object?>{
                      'id': 1,
                      'title': <String, Object?>{'romaji': 'Series A'},
                    },
                    <String, Object?>{
                      'id': 2,
                      'title': <String, Object?>{'romaji': 'Series B'},
                    },
                  ],
                },
              },
            }),
            200,
          );
        }
        return http.Response('not found', 404);
      });
    }

    await tester.pumpWidget(
      wrap(
        collection: collection,
        member: member,
        httpClientFactory: factory,
        onSearch: (VideoSubtitleSearchRequest request) {
          final int? id = request.media?.anilistId;
          if (id == 2) return staleB.future;
          seriesACalls++;
          final String label = seriesACalls == 1 ? 'A initial' : 'A latest';
          return Future<ProviderBatchResult<VideoSubtitleCandidate>>.value(
            ProviderBatchResult<VideoSubtitleCandidate>.success(
              <VideoSubtitleCandidate>[
                _Cand('Show - 01.ja.srt', source: label, episode: 1),
              ],
            ),
          );
        },
      ),
    );
    await tester.tap(find.text(t.video_jimaku_find_sources));
    await tester.pumpAndSettle();
    expect(find.textContaining('A initial'), findsOneWidget);

    await tester.tap(find.text('Series B'));
    await tester.pump();
    await tester.tap(find.text('Series A'));
    await tester.pumpAndSettle();
    expect(find.textContaining('A latest'), findsOneWidget);

    staleB.complete(
      ProviderBatchResult<VideoSubtitleCandidate>.success(
        <VideoSubtitleCandidate>[
          _Cand('Show - 01.ja.srt', source: 'B stale', episode: 1),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('B stale'), findsNothing);
    expect(find.textContaining('A latest'), findsOneWidget);
    expect((await db.getMediaCollectionById(collection.id))!.anilistId, 1);
  });

  testWidgets('选语言写合集列，选「全部」清空；偏好版本写列', (WidgetTester tester) async {
    final VideoBookRow member = await seedMember();
    final MediaCollectionRow collection = await seedCollection(anilistId: 21);
    await tester.pumpWidget(
      wrap(
        collection: collection,
        member: member,
        onSearch: (_) async =>
            ProviderBatchResult<VideoSubtitleCandidate>.success(
              <VideoSubtitleCandidate>[
                _Cand('Show - 01.ja.srt', source: 'Source', episode: 1),
              ],
            ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('日本語').first);
    await tester.tap(find.text('日本語').first);
    await tester.pumpAndSettle();
    expect(
      (await db.getMediaCollectionById(collection.id))!.subtitleLanguage,
      'ja',
    );
    await tester.ensureVisible(find.text(t.video_jimaku_language_all).first);
    await tester.tap(find.text(t.video_jimaku_language_all).first);
    await tester.pumpAndSettle();
    expect(
      (await db.getMediaCollectionById(collection.id))!.subtitleLanguage,
      isNull,
    );
  });

  group('groupSubtitleCollectionSources', () {
    test('按 provider:collectionId 分组，保持首次出现顺序，标签取合集名', () {
      final List<SubtitleCollectionSource> sources =
          groupSubtitleCollectionSources(<VideoSubtitleCandidate>[
            _Cand('a1.srt', source: 'A', episode: 1),
            _Cand('b1.srt', source: 'B', episode: 1),
            _Cand('a2.srt', source: 'A', episode: 2),
            _Cand('a.srt', source: 'A'),
          ]);
      expect(sources.map((SubtitleCollectionSource s) => s.key), <String>[
        'fake:A',
        'fake:B',
      ]);
      expect(sources.first.label, 'A');
      expect(sources.first.episodeCount, 2);
      expect(sources.first.index.unnumbered, hasLength(1));
      expect(sources.first.languages, <String>['ja']);
    });

    test('canRunSubtitleCollectionBatch：无来源 / 搜索中 / 下载中 / 空来源都禁用', () {
      final SubtitleCollectionSource source = groupSubtitleCollectionSources(
        <VideoSubtitleCandidate>[_Cand('a1.srt', source: 'A', episode: 1)],
      ).single;
      expect(
        canRunSubtitleCollectionBatch(
          selected: source,
          searching: false,
          running: false,
        ),
        isTrue,
      );
      expect(
        canRunSubtitleCollectionBatch(
          selected: null,
          searching: false,
          running: false,
        ),
        isFalse,
      );
      expect(
        canRunSubtitleCollectionBatch(
          selected: source,
          searching: true,
          running: false,
        ),
        isFalse,
      );
      expect(
        canRunSubtitleCollectionBatch(
          selected: source,
          searching: false,
          running: true,
        ),
        isFalse,
      );
    });
  });
}
