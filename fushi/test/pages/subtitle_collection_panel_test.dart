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
    bool withProvider = true,
  }) {
    final VideoSubtitleRegistry registry = VideoSubtitleRegistry(
      withProvider
          ? <VideoSubtitleProvider>[_FakeProvider(onSearch)]
          : const <VideoSubtitleProvider>[],
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

    // 上界不能丢：自动首搜 1 次 + 显式点「查找字幕」1 次，正好 2 次。放宽成
    // `isNotEmpty` 会让「同一次交互重复发搜」永远不再变红。
    expect(requests, hasLength(2));
    for (final VideoSubtitleSearchRequest request in requests) {
      final VideoMediaReference media = request.media!;
      // 没有 anidb/anilist 身份 = 不是动画：Jimaku 的 anime 硬过滤必须走 false 档，
      // 写死 anime 会让真人剧合集一条字幕都搜不到（BUG-1694）。
      expect(media.discoveryCategory, VideoDiscoveryCategory.tv);
      // OpenSubtitles 的强键：imdb 直查，命中率与文本搜不在一个量级。
      expect(media.imdbId, 'tt0903747');
      expect(media.tmdbId, 1396);
      expect(media.year, 2011);
      expect(media.anilistId, isNull);
    }
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
    // 第一轮由自动首搜发起（合集没绑系列 → 解析出 Series A 并搜它）。
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

  testWidgets('没绑 AniList 的合集也自动首搜：来源直接可选', (WidgetTester tester) async {
    final VideoBookRow member = await seedMember();
    // 不绑 anilistId、不 seed 规范作品 = initState 的 seedId 为 null。这条路径原来
    // **根本不发首搜**：用户打开面板只看到一排 `Icons.remove` 占位 + 灰掉的
    // 「下载全部」，得自己猜出要先点「查找字幕」。
    final MediaCollectionRow collection = await seedCollection();
    int searches = 0;
    await tester.pumpWidget(
      wrap(
        collection: collection,
        member: member,
        httpClientFactory: () async =>
            MockClient((_) async => http.Response('', 404)),
        onSearch: (_) async {
          searches++;
          return ProviderBatchResult<VideoSubtitleCandidate>.success(
            <VideoSubtitleCandidate>[
              _Cand('Show - 01.ja.srt', source: 'e1', episode: 1),
            ],
          );
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(searches, greaterThan(0), reason: '未绑系列的合集也必须发首搜');
    expect(
      find.byKey(const ValueKey<String>('subtitle-source-fake:e1')),
      findsOneWidget,
    );
    expect(tester.widget<FilledButton>(downloadButton()).onPressed, isNotNull);
  });

  /// AniList 模糊搜索返回 [ids] 里每个 id 一条候选，其余请求 404。
  ///
  /// 既有两条自动首搜用例的 mock 全部返回**空** media 列表，恰好绕开了
  /// 「命中候选之后怎么办」这条分支——那正是它能带着写库副作用溜进来的原因。
  Future<http.Client> Function() anilistHits(List<int> ids) {
    return () async => MockClient((http.Request request) async {
      if (request.url.host == 'graphql.anilist.co') {
        return http.Response(
          jsonEncode(<String, Object?>{
            'data': <String, Object?>{
              'Page': <String, Object?>{
                'media': <Object?>[
                  for (final int id in ids)
                    <String, Object?>{
                      'id': id,
                      'title': <String, Object?>{'romaji': 'Series $id'},
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

  testWidgets('自动首搜只搜不绑：模糊命中首条不写 media_collections.anilistId', (
    WidgetTester tester,
  ) async {
    final VideoBookRow member = await seedMember();
    // 自动首搜的前提就是合集没绑 AniList，所以「新 id != 旧 id」恒真——一旦这条
    // 路径会写库，用户**只是打开一次面板**就被粘性绑定，下次走 seedId 分支再也
    // 不重搜。真人剧合集尤其致命：它在 AniList 上没有条目，模糊搜索照样返回一部
    // 最像的动画，于是真人剧被永久绑到那部动画上。
    final MediaCollectionRow collection = await seedCollection();
    final List<VideoSubtitleSearchRequest> requests =
        <VideoSubtitleSearchRequest>[];
    await tester.pumpWidget(
      wrap(
        collection: collection,
        member: member,
        httpClientFactory: anilistHits(<int>[777]),
        onSearch: (VideoSubtitleSearchRequest request) async {
          requests.add(request);
          return ProviderBatchResult<VideoSubtitleCandidate>.success(
            <VideoSubtitleCandidate>[
              _Cand('Show - 01.ja.srt', source: 'e1', episode: 1),
            ],
          );
        },
      ),
    );
    await tester.pumpAndSettle();

    // 前置：这一版确实走到了「命中候选」那条分支——否则断言写库副作用是空转。
    expect(requests, hasLength(1));
    expect(requests.single.media!.anilistId, 777, reason: '命中的首条仍要用来搜');
    // 正题：搜归搜，一个字节都不许落库。
    expect(
      (await db.getMediaCollectionById(collection.id))!.anilistId,
      isNull,
      reason: '自动首搜不是用户的选择，不得粘性绑定合集身份',
    );
  });

  testWidgets('用户显式点选系列 → anilistId 才写进合集', (WidgetTester tester) async {
    final VideoBookRow member = await seedMember();
    final MediaCollectionRow collection = await seedCollection();
    await tester.pumpWidget(
      wrap(
        collection: collection,
        member: member,
        httpClientFactory: anilistHits(<int>[11, 22]),
        onSearch: (_) async =>
            ProviderBatchResult<VideoSubtitleCandidate>.success(
              <VideoSubtitleCandidate>[
                _Cand('Show - 01.ja.srt', source: 'e1', episode: 1),
              ],
            ),
      ),
    );
    await tester.pumpAndSettle();
    // 自动首搜之后仍然没绑（正向用例也得先钉死起点，否则分不清是谁写的）。
    expect((await db.getMediaCollectionById(collection.id))!.anilistId, isNull);

    await tester.tap(find.text('Series 22'));
    await tester.pumpAndSettle();

    expect(
      (await db.getMediaCollectionById(collection.id))!.anilistId,
      22,
      reason: '显式点选是用户的明确意图，绑定这条路径不得被拆没',
    );
  });

  testWidgets('首搜没结果：来源区说「没找到」而不是整块消失', (WidgetTester tester) async {
    final VideoBookRow member = await seedMember();
    final MediaCollectionRow collection = await seedCollection();
    await tester.pumpWidget(
      wrap(
        collection: collection,
        member: member,
        httpClientFactory: () async =>
            MockClient((_) async => http.Response('', 404)),
        onSearch: (_) async =>
            ProviderBatchResult<VideoSubtitleCandidate>.success(
              const <VideoSubtitleCandidate>[],
            ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder empty = find.byKey(
      const ValueKey<String>('subtitle-source-empty'),
    );
    expect(empty, findsOneWidget);
    expect(tester.widget<Text>(empty).data, t.video_jimaku_no_results);
    expect(tester.widget<FilledButton>(downloadButton()).onPressed, isNull);
  });

  testWidgets('一个字幕来源都没配：不自动发搜，来源区给引导', (WidgetTester tester) async {
    final VideoBookRow member = await seedMember();
    final MediaCollectionRow collection = await seedCollection();
    int searches = 0;
    await tester.pumpWidget(
      wrap(
        collection: collection,
        member: member,
        withProvider: false,
        httpClientFactory: () async =>
            MockClient((_) async => http.Response('', 404)),
        onSearch: (_) async {
          searches++;
          return ProviderBatchResult<VideoSubtitleCandidate>.success(
            const <VideoSubtitleCandidate>[],
          );
        },
      ),
    );
    await tester.pumpAndSettle();

    // 自动首搜在这条路径上只会立刻弹红色的「缺 API key」，所以不发；来源区改为
    // 明说要先点「查找字幕」，而不是像原来那样整块消失。
    expect(searches, 0);
    final Finder empty = find.byKey(
      const ValueKey<String>('subtitle-source-empty'),
    );
    expect(empty, findsOneWidget);
    expect(
      tester.widget<Text>(empty).data,
      t.video_subtitle_source_search_hint,
    );
  });

  testWidgets('底部操作条贴宿主底边：内容撑不满时不浮在列表尾巴上', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final VideoBookRow member = await seedMember();
    final MediaCollectionRow collection = await seedCollection();
    await tester.pumpWidget(
      wrap(
        collection: collection,
        member: member,
        httpClientFactory: () async =>
            MockClient((_) async => http.Response('', 404)),
        onSearch: (_) async =>
            ProviderBatchResult<VideoSubtitleCandidate>.success(
              const <VideoSubtitleCandidate>[],
            ),
      ),
    );
    await tester.pumpAndSettle();

    // 判据必须取**宿主**底边：`MainAxisSize.min` 时面板高度就等于内容高度，拿面板
    // 自己的底边去比按钮底边是两侧同源，恒真。
    final Rect host = tester.getRect(find.byType(Scaffold));
    final Rect button = tester.getRect(downloadButton());
    // 「宿主比内容高」得拿**内容自己的高度**来证：列表只有 1 个成员，`CustomScrollView`
    // 的可滚内容远短于 1400 的宿主，所以 `maxScrollExtent == 0`（撑不满、滚不动）。
    // 拿 `host.height > 1000` 当这个判据是恒真的——它只复述了 physicalSize。
    final ScrollableState scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    expect(
      scrollable.position.maxScrollExtent,
      0,
      reason: '内容必须撑不满宿主，否则「按钮贴底」无从谈起',
    );
    expect(host.bottom - button.bottom, lessThan(24));
  });
}
