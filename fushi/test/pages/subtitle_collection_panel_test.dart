import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_archive.dart'
    show SubtitleArchiveFormat;
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_content_language.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_version_groups.dart'
    show legacySubtitleVersionKeyOf, subtitleVersionKeyOf;
import 'package:fushi/src/pages/implementations/subtitle_collection_panel.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show FushiGlassMaterial, FushiGlassTheme;
import 'package:fushi_core/fushi_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import '../helpers/glass_unwrap.dart';

/// 合集批量面板（前身 `JimakuBatchDialog`，现走 registry）的状态门：
/// 搜索失败 → 提示 + 下载禁用；搜索中禁用、非空后开放；快速切系列时迟到的旧响应
/// 不覆盖新结果、DB 保留最新系列。
class _Cand extends VideoSubtitleCandidate {
  _Cand(
    String name, {
    required String source,
    int? episode,
    String language = 'ja',
  }) : super(
         providerId: 'fake',
         remoteId: '$source:$name',
         fileName: name,
         language: language,
         providerPriority: 1,
         episode: episode,
         collectionId: source,
         collectionLabel: source,
       );
}

/// 整季 ZIP 包候选。
class _PackCand extends VideoSubtitleCandidate {
  _PackCand(String name, {required String source})
    : super(
        providerId: 'fake',
        remoteId: '$source:$name',
        fileName: name,
        language: 'ja',
        providerPriority: 1,
        collectionId: source,
        collectionLabel: source,
        archiveFormat: SubtitleArchiveFormat.zip,
      );
}

/// 整季 RAR 包候选（本仓解不开）。
class _RarCand extends VideoSubtitleCandidate {
  _RarCand(String name, {required String source})
    : super(
        providerId: 'fake',
        remoteId: '$source:$name',
        fileName: name,
        language: 'ja',
        providerPriority: 1,
        collectionId: source,
        collectionLabel: source,
        archiveFormat: SubtitleArchiveFormat.rar,
      );
}

typedef _Search =
    Future<ProviderBatchResult<VideoSubtitleCandidate>> Function(
      VideoSubtitleSearchRequest request,
    );

typedef _Download =
    Future<VideoSubtitleDownload> Function(VideoSubtitleCandidate candidate);

class _FakeProvider implements VideoSubtitleProvider {
  _FakeProvider(this.onSearch, {this.onDownload});

  final _Search onSearch;
  final _Download? onDownload;

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
      onDownload?.call(candidate) ?? (throw UnimplementedError());
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
    _Download? onDownload,
    List<VideoBookRow>? members,
    Future<http.Client> Function()? httpClientFactory,
    bool withProvider = true,
    ThemeData? theme,
  }) {
    final VideoSubtitleRegistry registry = VideoSubtitleRegistry(
      withProvider
          ? <VideoSubtitleProvider>[
              _FakeProvider(onSearch, onDownload: onDownload),
            ]
          : const <VideoSubtitleProvider>[],
    );
    return TranslationProvider(
      child: MaterialApp(
        theme: theme,
        home: Scaffold(
          body: SubtitleCollectionPanel(
            database: db,
            collection: collection,
            members: members ?? <VideoBookRow>[member],
            subtitleRegistry: () async => registry,
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
    expect(
      tester
          .widget<FilledButton>(glassUnwrap<FilledButton>(downloadButton()))
          .onPressed,
      isNull,
    );
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
    expect(
      tester
          .widget<FilledButton>(glassUnwrap<FilledButton>(downloadButton()))
          .onPressed,
      isNull,
    );

    pending.complete(
      ProviderBatchResult<VideoSubtitleCandidate>.success(
        <VideoSubtitleCandidate>[
          _Cand('Show - 01.ja.srt', source: 'Source', episode: 1),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(glassUnwrap<FilledButton>(downloadButton()))
          .onPressed,
      isNotNull,
    );
    expect(
      find.byKey(const ValueKey<String>('subtitle-source-fake:Source')),
      findsOneWidget,
    );
  });

  testWidgets('批量某集下载被拒：行副标题说出原因（key 被拒 + 状态码），不是一句「下载失败」', (
    WidgetTester tester,
  ) async {
    // 默认 800×600 下成员列表在版本 / 设置区下面、还没被懒构建出来。
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
        onDownload: (_) async => throw const ExternalProviderFailure(
          providerId: 'fake',
          operation: 'download',
          kind: ExternalProviderFailureKind.unauthorized,
          message: 'denied',
          statusCode: 401,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(downloadButton());
    await tester.pumpAndSettle();

    final String reason = t.video_subtitle_error_with_code(
      msg: t.video_subtitle_error_key_rejected(provider: 'fake'),
      code: 401,
    );
    expect(
      find.text(reason),
      findsOneWidget,
      reason: '401 / 429 / 文件下架在批量里曾经长得一样',
    );
    expect(find.text(t.video_jimaku_download_failed), findsNothing);
  });

  testWidgets('整季包没下下来：没配上的集说出原因（状态码），不是一句「找不到字幕」', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final VideoBookRow member = await seedMember();
    // 两集：只有一集时未编号的包会被当成「唯一目标的单文件」直接下载，走不到
    // 「从整季包里按集号拆」这条路。
    await db.upsertVideoBook(
      const VideoBooksCompanion(
        bookUid: Value<String>('video/show-02'),
        title: Value<String>('Show - 02'),
        videoPath: Value<String>('C:/video/Show - 02.mkv'),
      ),
    );
    final VideoBookRow second = (await VideoBookRepository(
      db,
    ).getByBookUid('video/show-02'))!;
    final MediaCollectionRow collection = await seedCollection(anilistId: 21);
    await tester.pumpWidget(
      wrap(
        collection: collection,
        member: member,
        members: <VideoBookRow>[member, second],
        onSearch: (_) async =>
            ProviderBatchResult<VideoSubtitleCandidate>.success(
              <VideoSubtitleCandidate>[
                // 第 1 集有单集文件；第 2 集只能从整季包里拆。
                _Cand('Show - 01.ja.srt', source: 'Source', episode: 1),
                _PackCand('Show S1.zip', source: 'Source'),
              ],
            ),
        onDownload: (_) async => throw const ExternalProviderFailure(
          providerId: 'fake',
          operation: 'download',
          kind: ExternalProviderFailureKind.rateLimited,
          message: 'slow down',
          statusCode: 429,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(downloadButton());
    await tester.pumpAndSettle();

    expect(
      find.text(
        t.video_subtitle_error_with_code(
          msg: t.video_jimaku_no_results,
          code: 429,
        ),
      ),
      findsOneWidget,
      reason: '「包被限流没下下来」与「来源里真的没有这一集」曾经长得一样',
    );
  });

  testWidgets('批量跑起来后主按钮变「停止（1/2）」：点了之后手上那一集落盘，其余集标已跳过', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final VideoBookRow first = await seedMember();
    await db.upsertVideoBook(
      const VideoBooksCompanion(
        bookUid: Value<String>('video/show-02'),
        title: Value<String>('Show - 02'),
        videoPath: Value<String>('C:/video/Show - 02.mkv'),
      ),
    );
    final VideoBookRow second = (await repo.getByBookUid('video/show-02'))!;
    final MediaCollectionRow collection = await seedCollection(anilistId: 21);
    final Completer<VideoSubtitleDownload> pendingDownload =
        Completer<VideoSubtitleDownload>();
    final List<String> downloaded = <String>[];
    await tester.pumpWidget(
      wrap(
        collection: collection,
        member: first,
        members: <VideoBookRow>[first, second],
        onSearch: (_) async =>
            ProviderBatchResult<VideoSubtitleCandidate>.success(
              <VideoSubtitleCandidate>[
                _Cand('Show - 01.ja.srt', source: 'Source', episode: 1),
                _Cand('Show - 02.ja.srt', source: 'Source', episode: 2),
              ],
            ),
        onDownload: (VideoSubtitleCandidate c) {
          downloaded.add(c.fileName);
          return pendingDownload.future;
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(downloadButton());
    await tester.pump();
    await tester.pump();

    final Finder stopButton = find.byKey(
      const ValueKey<String>('subtitle-collection-stop'),
    );
    expect(downloadButton(), findsNothing);
    expect(
      find.text(t.video_subtitle_batch_stop(current: 1, total: 2)),
      findsOneWidget,
    );
    await tester.tap(stopButton);
    await tester.pump();
    expect(find.text(t.video_subtitle_batch_stopping), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(glassUnwrap<FilledButton>(stopButton))
          .onPressed,
      isNull,
      reason: '停止中不能重复点',
    );

    // 手上那一集照常收尾、落盘。
    pendingDownload.complete(
      VideoSubtitleDownload(
        bytes: utf8.encode('1\n00:00:01,000 --> 00:00:02,000\nx\n'),
        fileName: 'Show - 01.ja.srt',
        language: 'ja',
      ),
    );
    // 落盘与解析 cue 是真文件 IO，在 runAsync 里让它们跑完。
    for (int i = 0; i < 100 && stopButton.evaluate().isNotEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(downloaded, <String>['Show - 01.ja.srt'], reason: '第 2 集不再下载');
    expect(find.text(t.video_subtitle_batch_skipped), findsOneWidget);
    expect(
      find.text(t.video_subtitle_batch_stopped(done: 1, total: 2)),
      findsOneWidget,
    );
    expect(stopButton, findsNothing);
    expect(downloadButton(), findsOneWidget);
    expect(
      (await repo.getByBookUid('video/show-01'))!.subtitleSource,
      isNotNull,
    );
    expect((await repo.getByBookUid('video/show-02'))!.subtitleSource, isNull);
  });

  testWidgets('BUG-4799 批量途中在输入框回车不重搜：在跑的行状态与来源不被清掉', (
    WidgetTester tester,
  ) async {
    final VideoBookRow member = await seedMember();
    final MediaCollectionRow collection = await seedCollection(anilistId: 21);
    int searches = 0;
    final Completer<VideoSubtitleDownload> pendingDownload =
        Completer<VideoSubtitleDownload>();
    await tester.pumpWidget(
      wrap(
        collection: collection,
        member: member,
        onSearch: (_) async {
          searches++;
          return ProviderBatchResult<VideoSubtitleCandidate>.success(
            <VideoSubtitleCandidate>[
              _Cand('Show - 01.ja.srt', source: 'Source', episode: 1),
            ],
          );
        },
        onDownload: (_) => pendingDownload.future,
      ),
    );
    await tester.pumpAndSettle();
    final int searchesBefore = searches;
    await tester.tap(downloadButton());
    await tester.pump();
    await tester.pump();

    // 批量在跑（下载挂起）。与「查找字幕」按钮同一道闸：回车不得发起新一轮。
    final TextField queryField = tester.widget<TextField>(
      find.byWidgetPredicate(
        (Widget w) => w is TextField && w.controller?.text == 'Show',
      ),
    );
    queryField.onSubmitted!('Show');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(searches, searchesBefore, reason: '批量途中回车重搜会清掉行状态、换掉来源');
    expect(
      find.byKey(const ValueKey<String>('subtitle-source-fake:Source')),
      findsOneWidget,
    );

    pendingDownload.completeError(
      const ExternalProviderFailure(
        providerId: 'fake',
        operation: 'download',
        kind: ExternalProviderFailureKind.unavailable,
        message: 'down',
        statusCode: 503,
      ),
    );
    await tester.pumpAndSettle();
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

    test('canRunSubtitleCollectionBatch：只有能解开的整季包、没有单集文件的来源也能批量下载', () {
      // 成员行对这种来源预览「将从整季包中拆出」，批量（runSubtitleBatch）也确实会拆；
      // 修复前按钮只看单集索引，这里是灰的。
      final SubtitleCollectionSource packOnly = groupSubtitleCollectionSources(
        <VideoSubtitleCandidate>[_PackCand('season.zip', source: 'P')],
      ).single;
      expect(packOnly.index.isEmpty, isTrue);
      expect(packOnly.unpackablePackFormat, SubtitleArchiveFormat.zip);
      expect(
        canRunSubtitleCollectionBatch(
          selected: packOnly,
          searching: false,
          running: false,
        ),
        isTrue,
      );
      expect(
        canRunSubtitleCollectionBatch(
          selected: packOnly,
          searching: false,
          running: true,
        ),
        isFalse,
      );
    });

    test('canRunSubtitleCollectionBatch：只有解不开的整季包（RAR）仍禁用', () {
      final SubtitleCollectionSource rarOnly = groupSubtitleCollectionSources(
        <VideoSubtitleCandidate>[_RarCand('season.rar', source: 'R')],
      ).single;
      expect(rarOnly.unsupportedPackFormat, SubtitleArchiveFormat.rar);
      expect(
        canRunSubtitleCollectionBatch(
          selected: rarOnly,
          searching: false,
          running: false,
        ),
        isFalse,
      );
    });
  });

  group('rankSubtitleCollectionVersions（BUG-3998 聚合版本列表）', () {
    // Jimaku 12217 的形状：Nekomoe 只有第 1 集；Netflix 文件名带 ja；shincaps
    // 文件名不写语言。
    List<VideoSubtitleCandidate> growUpShow() => <VideoSubtitleCandidate>[
      _Cand(
        '[Nekomoe kissaten&LoliHouse] Grow Up Show - 01 [WebRip][JPN].ass',
        source: 'E',
        episode: 1,
      ),
      for (int ep = 1; ep <= 3; ep++) ...<VideoSubtitleCandidate>[
        _Cand(
          'グロウアップショウ.S01E0$ep.WEBRip.Netflix.ja[cc].srt',
          source: 'E',
          episode: ep,
        ),
        _Cand(
          '[shincaps] Grow Up Show - 0$ep (AT-X).ass',
          source: 'E',
          episode: ep,
          language: '',
        ),
      ],
    ];

    test('首行 = 自动会用的版本：正文判为日语后全季 ASS 排第一，并标出正文语言与覆盖', () {
      final List<VideoSubtitleCandidate> candidates = growUpShow();
      final SubtitleCollectionSource source = groupSubtitleCollectionSources(
        candidates,
      ).single;
      final String shincapsKey = subtitleVersionKeyOf(candidates[2]);
      final List<SubtitleCollectionVersion> versions =
          rankSubtitleCollectionVersions(
            source,
            targetEpisodes: <int>[1, 2, 3],
            probedLanguages: <String, SubtitleContentLanguage>{
              shincapsKey: SubtitleContentLanguage.japanese,
            },
          );
      expect(versions.first.group.key, shincapsKey);
      expect(versions.first.language, 'ja');
      expect(versions.first.contentLanguage, SubtitleContentLanguage.japanese);
      expect(versions.first.coveredEpisodes, <int>{1, 2, 3});
      expect(versions[1].group.releaseGroupTag, 'Netflix');
      expect(versions.last.coveredEpisodes, <int>{
        1,
      }, reason: 'Nekomoe 只覆盖第 1 集');
    });

    test('正文还没判出：未知语言的版本排在 ja 版本之后（与批量判据一致）', () {
      final SubtitleCollectionSource source = groupSubtitleCollectionSources(
        growUpShow(),
      ).single;
      final List<SubtitleCollectionVersion> versions =
          rankSubtitleCollectionVersions(
            source,
            targetEpisodes: <int>[1, 2, 3],
          );
      expect(versions.first.group.releaseGroupTag, 'Netflix');
      expect(versions.last.language, isNull);
    });
  });

  group('resolvePinnedSubtitleVersion（旧版本键迁移）', () {
    // 旧键组成的名字段只认发布组：无组名的 Netflix / Amazon 抽轨末段都是空串。
    final VideoSubtitleCandidate netflix = _Cand(
      'グロウアップショウ.S01E01.WEBRip.Netflix.ja[cc].srt',
      source: 'E',
      episode: 1,
    );
    final VideoSubtitleCandidate amazon = _Cand(
      'グロウアップショウ.S01E02.WEBRip.Amazon.ja[cc].srt',
      source: 'E',
      episode: 2,
    );
    List<SubtitleCollectionVersion> ranked(SubtitleCollectionSource s) =>
        rankSubtitleCollectionVersions(s, targetEpisodes: <int>[1, 2]);

    test('新键直接命中：不迁移', () {
      final List<SubtitleCollectionSource> sources =
          groupSubtitleCollectionSources(<VideoSubtitleCandidate>[netflix]);
      final String key = subtitleVersionKeyOf(netflix);
      expect(resolvePinnedSubtitleVersion(sources, key, rankedOf: ranked), (
        sourceKey: sources.single.key,
        versionKey: key,
        migrated: false,
      ));
    });

    test('旧键（无组名平台末段为空）落到 Netflix 版本，标记需改写', () {
      final String legacy = legacySubtitleVersionKeyOf(netflix);
      expect(legacy, isNot(subtitleVersionKeyOf(netflix)));
      final List<SubtitleCollectionSource> sources =
          groupSubtitleCollectionSources(<VideoSubtitleCandidate>[netflix]);
      expect(resolvePinnedSubtitleVersion(sources, legacy, rankedOf: ranked), (
        sourceKey: sources.single.key,
        versionKey: subtitleVersionKeyOf(netflix),
        migrated: true,
      ));
    });

    test('旧键拆成多个版本时取排名第一的那个', () {
      final List<SubtitleCollectionSource> sources =
          groupSubtitleCollectionSources(<VideoSubtitleCandidate>[
            amazon,
            netflix,
          ]);
      final String expected = ranked(sources.single).first.group.key;
      expect(
        resolvePinnedSubtitleVersion(
          sources,
          legacySubtitleVersionKeyOf(netflix),
          rankedOf: ranked,
        )?.versionKey,
        expected,
      );
    });

    test('都对不上：null（退回自动）', () {
      expect(
        resolvePinnedSubtitleVersion(
          groupSubtitleCollectionSources(<VideoSubtitleCandidate>[netflix]),
          'nope',
          rankedOf: ranked,
        ),
        isNull,
      );
    });
  });

  testWidgets('合集列里的旧版本键：搜索后选中 Netflix 版本并把列改写成新键', (
    WidgetTester tester,
  ) async {
    final VideoBookRow member = await seedMember();
    final MediaCollectionRow seeded = await seedCollection(anilistId: 21);
    final VideoSubtitleCandidate netflix = _Cand(
      'グロウアップショウ.S01E01.WEBRip.Netflix.ja[cc].srt',
      source: 'Source',
      episode: 1,
    );
    final VideoSubtitleCandidate ass = _Cand(
      '[Grp] Show - 01.ja.ass',
      source: 'Source',
      episode: 1,
    );
    await db.updateMediaCollectionSubtitleReleaseGroup(
      seeded.id,
      legacySubtitleVersionKeyOf(netflix),
    );
    final MediaCollectionRow collection = (await db.getMediaCollectionById(
      seeded.id,
    ))!;
    await tester.pumpWidget(
      wrap(
        collection: collection,
        member: member,
        onSearch: (_) async =>
            ProviderBatchResult<VideoSubtitleCandidate>.success(
              <VideoSubtitleCandidate>[netflix, ass],
            ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      (await db.getMediaCollectionById(collection.id))!.subtitleReleaseGroup,
      subtitleVersionKeyOf(netflix),
    );
    // 没静默退回「自动」（自动会挑 ASS）：成员行用的是点名的 Netflix 版本。
    // 成员行在版本列表下方的惰性 SliverList 里：两个版本 + 「自动」行把它推出
    // 800×600 视口，不滚过去它根本不会被 build。
    final Finder plannedNetflix = find.text(
      t.video_subtitle_collection_episode_planned(
        count: 1,
        version: 'Netflix · SRT · 日本語',
      ),
    );
    await tester.scrollUntilVisible(
      plannedNetflix,
      200,
      scrollable: find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(plannedNetflix, findsOneWidget);
  });

  testWidgets('聚合版本列表：点版本行写合集列，点「自动」清空', (WidgetTester tester) async {
    final VideoBookRow member = await seedMember();
    final MediaCollectionRow collection = await seedCollection(anilistId: 21);
    final VideoSubtitleCandidate srt = _Cand(
      'Show - 01.ja.srt',
      source: 'Source',
      episode: 1,
    );
    final VideoSubtitleCandidate ass = _Cand(
      '[Grp] Show - 01.ja.ass',
      source: 'Source',
      episode: 1,
    );
    await tester.pumpWidget(
      wrap(
        collection: collection,
        member: member,
        onSearch: (_) async =>
            ProviderBatchResult<VideoSubtitleCandidate>.success(
              <VideoSubtitleCandidate>[srt, ass],
            ),
      ),
    );
    await tester.pumpAndSettle();

    // 「自动」行写明会用哪个版本：同语言同覆盖，ASS 先于 SRT。
    expect(
      find.text(
        t.video_subtitle_collection_version_auto_detail(
          version: 'Grp · ASS · 日本語',
        ),
      ),
      findsOneWidget,
    );
    final Finder srtRow = find.byKey(
      ValueKey<String>('subtitle-version-${subtitleVersionKeyOf(srt)}'),
    );
    await tester.ensureVisible(srtRow);
    await tester.tap(srtRow);
    await tester.pumpAndSettle();
    expect(
      (await db.getMediaCollectionById(collection.id))!.subtitleReleaseGroup,
      subtitleVersionKeyOf(srt),
    );
    // 成员行跟着变成点名的版本。
    expect(
      find.text(
        t.video_subtitle_collection_episode_planned(
          count: 1,
          version:
              '${t.video_subtitle_collection_version_no_group} · SRT · 日本語',
        ),
      ),
      findsOneWidget,
    );

    final Finder autoRow = find.byKey(
      const ValueKey<String>('subtitle-source-fake:Source'),
    );
    await tester.ensureVisible(autoRow);
    await tester.tap(autoRow);
    await tester.pumpAndSettle();
    expect(
      (await db.getMediaCollectionById(collection.id))!.subtitleReleaseGroup,
      isNull,
    );
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
    expect(
      tester
          .widget<FilledButton>(glassUnwrap<FilledButton>(downloadButton()))
          .onPressed,
      isNotNull,
    );
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

  testWidgets('BUG-2713：成员是 S04E18 → 自动首搜按第四季的 AniList 条目检索', (
    WidgetTester tester,
  ) async {
    await db.upsertVideoBook(
      const VideoBooksCompanion(
        bookUid: Value<String>('video/rezero-s04e18'),
        title: Value<String>('Re Zero kara Hajimeru Isekai Seikatsu S04E18'),
        videoPath: Value<String>(
          'C:/video/[NanakoRaws] Re Zero kara Hajimeru Isekai Seikatsu '
          'S04E18 (AT-X TV 1080p HEVC AAC).mkv',
        ),
      ),
    );
    final VideoBookRow member = (await repo.getByBookUid(
      'video/rezero-s04e18',
    ))!;
    final MediaCollectionRow collection = await seedCollection();
    // 相关度首条恒为第一季（2026-09-26 实测 AniList 原样顺序）。
    Future<http.Client> factory() async => MockClient(
      (http.Request request) async => http.Response(
        jsonEncode(<String, Object?>{
          'data': <String, Object?>{
            'Page': <String, Object?>{
              'media': <Object?>[
                for (final (int id, String romaji) in const <(int, String)>[
                  (21355, 'Re:Zero kara Hajimeru Isekai Seikatsu'),
                  (108632, 'Re:Zero kara Hajimeru Isekai Seikatsu 2nd Season'),
                  (163134, 'Re:Zero kara Hajimeru Isekai Seikatsu 3rd Season'),
                  (189046, 'Re:Zero kara Hajimeru Isekai Seikatsu 4th Season'),
                ])
                  <String, Object?>{
                    'id': id,
                    'title': <String, Object?>{'romaji': romaji},
                  },
              ],
            },
          },
        }),
        200,
      ),
    );
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
            <VideoSubtitleCandidate>[
              _Cand('Show - 18.ja.srt', source: 'e1', episode: 18),
            ],
          );
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(requests, hasLength(1));
    expect(
      requests.single.media!.anilistId,
      189046,
      reason: '按第一季的 id 查 Jimaku 只会列出第一季的字幕',
    );
    expect(requests.single.effectiveSeason, 4);
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
    expect(
      tester
          .widget<FilledButton>(glassUnwrap<FilledButton>(downloadButton()))
          .onPressed,
      isNull,
    );
  });

  // BUG-3000：截图里 key 输入框明明有值，顶部却报「请先填写 Jimaku API key」——
  // 判据看的是「有没有 registry」而不是 key。key 填了还拿不到来源时，要说真实原因。
  testWidgets('BUG-3000 key 已填但没有任何来源：不再报「请先填写 key」', (
    WidgetTester tester,
  ) async {
    final VideoBookRow member = await seedMember();
    // 绑了系列 → 进页即直接搜来源（不经 AniList），走到无来源分支。
    final MediaCollectionRow collection = await seedCollection(anilistId: 21);
    await tester.pumpWidget(
      wrap(
        collection: collection,
        member: member,
        withProvider: false,
        httpClientFactory: () async =>
            MockClient((_) async => http.Response('', 404)),
        onSearch: (_) async =>
            ProviderBatchResult<VideoSubtitleCandidate>.success(
              const <VideoSubtitleCandidate>[],
            ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(t.video_jimaku_no_key),
      findsNothing,
      reason: 'initialApiKey 是 test-key：说「请先填写 key」是在骗用户',
    );
    expect(find.text(t.video_subtitle_sources_all_disabled), findsOneWidget);
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

  // 番剧匹配候选是**靠标题**区分的；同系列各季标题前缀相同，截成一行省略号后
  // 两个 chip 显示成同一串，用户无从选系列（应用内反馈 rB3cuyTXBr）。
  for (final (String design, ThemeData? theme) in <(String, ThemeData?)>[
    ('MD3', null),
    (
      'Apple',
      ThemeData(
        extensions: const <ThemeExtension<dynamic>>[
          FushiGlassTheme(FushiGlassMaterial.off, glassDesign: true),
        ],
      ),
    ),
  ]) {
    testWidgets('$design：番剧匹配候选标题完整显示，同前缀的季能区分', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(480, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const String season1 =
          'Tensei shitara Slime Datta Ken: Coleus no Yume to Kanata no '
          'Tomodachi';
      const String season2 =
          'Tensei shitara Slime Datta Ken: Coleus no Yume to Kanata no '
          'Tomodachi 2nd Season';
      final VideoBookRow member = await seedMember();
      final MediaCollectionRow collection = await seedCollection();
      await tester.pumpWidget(
        wrap(
          collection: collection,
          member: member,
          theme: theme,
          httpClientFactory: () async => MockClient((
            http.Request request,
          ) async {
            if (request.url.host != 'graphql.anilist.co') {
              return http.Response('not found', 404);
            }
            return http.Response(
              jsonEncode(<String, Object?>{
                'data': <String, Object?>{
                  'Page': <String, Object?>{
                    'media': <Object?>[
                      for (final (int id, String romaji)
                          in const <(int, String)>[(1, season1), (2, season2)])
                        <String, Object?>{
                          'id': id,
                          'title': <String, Object?>{'romaji': romaji},
                        },
                    ],
                  },
                },
              }),
              200,
            );
          }),
          onSearch: (_) async =>
              ProviderBatchResult<VideoSubtitleCandidate>.success(
                const <VideoSubtitleCandidate>[],
              ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      for (final String title in <String>[season1, season2]) {
        final Finder label = find.text(title);
        expect(label, findsOneWidget, reason: '候选 chip 必须渲染出来');
        final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
          label,
        );
        expect(
          paragraph.didExceedMaxLines,
          isFalse,
          reason: '「$title」被截断：同前缀的季在界面上无法区分',
        );
        // 整段标题都在面板宽度内（换行而不是溢出到屏外）。
        final Rect rect = tester.getRect(label);
        expect(rect.right, lessThanOrEqualTo(480));
      }
    });
  }
}
