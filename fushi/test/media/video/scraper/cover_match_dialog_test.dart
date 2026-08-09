import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/metadata/credential_redaction.dart';
import 'package:fushi/src/media/metadata/scrape_cover_preview.dart';
import 'package:fushi/src/media/video/cover_ui/cover_match_dialog.dart';
import 'package:fushi/src/media/video/scraper/alias_cache.dart';
import 'package:fushi/src/media/video/scraper/collection_scrape_apply.dart';
import 'package:fushi/src/media/video/scraper/bangumi_client.dart';
import 'package:fushi/src/media/video/scraper/cover_meta_store.dart';
import 'package:fushi/src/media/video/scraper/cover_downloader.dart';
import 'package:fushi/src/media/video/scraper/cover_scraper_service.dart';
import 'package:fushi/src/media/video/scraper/scraper_types.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

import '../../../helpers/test_platform_services.dart';

final List<int> _fakePng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x01, 0x02, 0x03,
];

/// 桩 service：搜索返回固定候选、应用为纯内存记账（无真实网络/文件 IO，纯 microtask，
/// pumpAndSettle 即可驱动，避免 runAsync 触发 Image.network 真实请求挂起）。评分/解析
/// 仍走真实实现（置信度徽标真出）。
class _StubScraperService extends CoverScraperService {
  _StubScraperService({
    required super.repository,
    required super.coverMetaStore,
    required super.aliasCache,
    required super.bangumiClient,
    required super.coverDownloader,
    required this.candidates,
    required this.repo,
    super.coversDirectory,
    super.collectionCoversDirectory,
  });

  /// 与 super 的 repository 同一实例：桩的成员应用**真写穿 cover_path**，否则
  /// 「成员封面逐个未变」这条断言就是空转（写了也看不出来）。
  final VideoBookRepository repo;

  final List<ScrapeCandidate> candidates;
  final List<String> appliedUids = <String>[];

  /// 逐次出队的搜索异常（非 null 即抛）。让「第一次失败 → 重试成功」可测。
  final List<Object?> searchErrors = <Object?>[];
  final List<Object?> applyErrors = <Object?>[];
  int searchCalls = 0;

  /// 多源聚合用的**逐源**桩数据。非空时接管 [searchCandidates]，[candidates] /
  /// [searchErrors] 那条单源老路径不再生效——两套刻意不混用，否则「这条断言到底
  /// 命中哪条桩」要靠猜。
  final Map<ScrapeSource, List<ScrapeCandidate>> perSourceCandidates =
      <ScrapeSource, List<ScrapeCandidate>>{};

  /// 逐源失败注入：命中的源抛该异常，其余源照常返回候选。
  final Map<ScrapeSource, Object> perSourceErrors = <ScrapeSource, Object>{};

  /// 覆盖「本次构建有哪些可用源」。基类按注入的 client 是否为 null 推导，桩里不真
  /// 造 client，故直接给答案。
  List<ScrapeSource>? sourcesOverride;

  /// 记录每个源各被查了几次（断言「一次搜索把所有源都查了」）。
  final Map<ScrapeSource, int> searchCallsBySource = <ScrapeSource, int>{};

  @override
  List<ScrapeSource> get availableSearchSources =>
      sourcesOverride ?? super.availableSearchSources;

  @override
  Future<List<ScrapeCandidate>> searchCandidates({
    required ScrapeSource source,
    required String keyword,
    int? year,
  }) async {
    searchCalls++;
    searchCallsBySource[source] = (searchCallsBySource[source] ?? 0) + 1;
    if (perSourceCandidates.isNotEmpty || perSourceErrors.isNotEmpty) {
      final Object? error = perSourceErrors[source];
      if (error != null) Error.throwWithStackTrace(error, StackTrace.current);
      return perSourceCandidates[source] ?? const <ScrapeCandidate>[];
    }
    final Object? error =
        searchErrors.isEmpty ? null : searchErrors.removeAt(0);
    if (error != null) Error.throwWithStackTrace(error, StackTrace.current);
    return candidates;
  }

  @override
  Future<void> applyCandidateToBooks({
    required List<String> bookUids,
    required ScrapeCandidate candidate,
    String? aliasKey,
  }) async {
    final Object? error = applyErrors.isEmpty ? null : applyErrors.removeAt(0);
    if (error != null) Error.throwWithStackTrace(error, StackTrace.current);
    appliedUids.addAll(bookUids);
    // 真写穿：成员封面被刷这件事必须在 DB 上留下痕迹，断言才有牙。
    for (final String uid in bookUids) {
      await repo.updateCover(uid, 'stub-applied-${candidate.entryId}.jpg');
    }
  }
}

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_poster_match_pp');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => pathProviderDir.path,
    );
  });
  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (pathProviderDir.existsSync()) {
      pathProviderDir.deleteSync(recursive: true);
    }
  });

  late FushiDatabase db;
  late VideoBookRepository repo;
  late Directory tmp;
  late AppModel appModel;
  late PreferencesRepository prefs;
  late PlatformServices platformServices;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = VideoBookRepository(db);
    tmp = await Directory.systemTemp.createTemp('hibiki_poster_match_');
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    platformServices = testPlatformServices();
    appModel = AppModel(platformServices)
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: tmp);
  });

  tearDown(() async {
    await db.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  String bangumiBody() => jsonEncode(<String, Object?>{
        'data': <Object?>[
          <String, Object?>{
            'id': 42,
            'name': 'My Anime',
            'name_cn': 'My Anime',
            'images': <String, Object?>{'large': 'https://img/b42.png'},
            'platform': 'TV',
            'eps': 12,
            'date': '2021-04-01',
            'score': 8.2,
          },
        ],
      });

  _StubScraperService buildService() => _StubScraperService(
        repository: repo,
        coverMetaStore: CoverMetaStore(tmp),
        aliasCache: AliasCache(tmp),
        bangumiClient: BangumiClient(
          client: MockClient((http.Request req) async => http.Response(
                bangumiBody(),
                200,
                headers: const <String, String>{
                  'content-type': 'application/json'
                },
              )),
        ),
        coverDownloader: CoverDownloader(
          client: MockClient((http.Request req) async => http.Response.bytes(
                _fakePng,
                200,
                headers: const <String, String>{'content-type': 'image/png'},
              )),
        ),
        candidates: const <ScrapeCandidate>[
          ScrapeCandidate(
            source: ScrapeSource.bangumi,
            entryId: '42',
            title: 'My Anime',
            year: 2021,
            type: ScrapeEntryType.tv,
            episodeCount: 12,
            posterUrl: 'https://img/b42.png',
            ratingText: 'Bangumi 8.2',
          ),
        ],
        coversDirectory: tmp,
        collectionCoversDirectory: Directory(p.join(tmp.path, 'collections')),
        repo: repo,
      );

  Future<VideoBookRow> seed() async {
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value('video/my_anime'),
      title: const Value('My Anime raw filename'),
      videoPath: Value(p.join('anime', 'My Anime', 'My Anime - 01.mkv')),
    ));
    return (await repo.getByBookUid('video/my_anime'))!;
  }

  Widget wrap(Widget child) => ProviderScope(
        overrides: <Override>[
          platformServicesProvider.overrideWithValue(platformServices),
          appProvider.overrideWith((ref) => appModel),
        ],
        child: TranslationProvider(
          child: MaterialApp(home: Scaffold(body: child)),
        ),
      );

  testWidgets('冒烟：候选渲染 + 使用按钮回调应用封面', (WidgetTester tester) async {
    final VideoBookRow book = await seed();
    final _StubScraperService service = buildService();
    bool applied = false;

    // 经 showCoverMatchDialog 真开一个 dialog route（使 Navigator.pop 有路可退）。
    await tester.pumpWidget(wrap(
      Builder(
        builder: (BuildContext ctx) => Center(
          child: ElevatedButton(
            onPressed: () => showCoverMatchDialog(
              context: ctx,
              service: service,
              book: book,
              collectionMemberUids: <String>['video/my_anime'],
              onApplied: () => applied = true,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    // 预填 + 自动搜索（postFrame）→ 候选出现。
    await tester.pumpAndSettle();

    // 搜索框预填的是解析后的标题（而非原始文件名）。
    expect(find.widgetWithText(TextField, 'My Anime'), findsOneWidget);
    // 候选标题渲染。
    expect(find.text('My Anime'), findsWidgets);
    expect(
      tester.getSize(find.byType(ScrapeCoverPreview)),
      const Size(kScrapeCoverPreviewWidth, kScrapeCoverPreviewHeight),
    );
    // 左侧封面可点击打开大图，并可缩放、显式关闭。
    await tester.tap(find.byType(ScrapeCoverPreview));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('scrape_cover_large_preview')),
      findsOneWidget,
    );
    expect(find.byType(InteractiveViewer), findsOneWidget);
    await tester.tap(
      find.byKey(
        const ValueKey<String>('scrape_cover_large_preview_close'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('scrape_cover_large_preview')),
      findsNothing,
    );
    // 置信度徽标（高匹配）。
    expect(find.text(t.video_scrape_confidence_high), findsOneWidget);
    expect(find.textContaining('Bangumi #42'), findsOneWidget);

    // 点「使用」→ 回调应用（桩为纯内存记账，pumpAndSettle 即可驱动）。
    await tester.tap(find.text(t.video_scrape_use).first);
    await tester.pumpAndSettle();

    expect(applied, isTrue);
    expect(service.appliedUids, <String>['video/my_anime']);
    // 弹窗应用后关闭。
    expect(find.text(t.video_scrape_use), findsNothing);
  });

  // 契约变更（取代旧的两条 BUG-1234「切换来源 / TMDB key 输入」用例）：数据源选择器
  // 与 TMDB key 输入行已从弹窗移除——用户不再选源、也不在这里配 key（内置 key +
  // 设置页逃生口）。旧用例守的是已不存在的行为，故删除而非修补。
  testWidgets('多源聚合：一次搜索查全部可用源，候选合并进同一列表且无来源选择器', (WidgetTester tester) async {
    final VideoBookRow book = await seed();
    final _StubScraperService service = buildService();
    service.sourcesOverride = <ScrapeSource>[
      ScrapeSource.bangumi,
      ScrapeSource.tmdb,
      ScrapeSource.anilist,
      ScrapeSource.jikan,
    ];
    service.perSourceCandidates
      ..[ScrapeSource.bangumi] = const <ScrapeCandidate>[
        ScrapeCandidate(
          source: ScrapeSource.bangumi,
          entryId: '42',
          title: 'My Anime',
          posterUrl: 'https://img/b42.png',
        ),
      ]
      ..[ScrapeSource.tmdb] = const <ScrapeCandidate>[
        ScrapeCandidate(
          source: ScrapeSource.tmdb,
          entryId: '77',
          title: 'My Anime',
          posterUrl: 'https://img/t77.png',
        ),
      ]
      ..[ScrapeSource.anilist] = const <ScrapeCandidate>[
        ScrapeCandidate(
          source: ScrapeSource.anilist,
          entryId: '99',
          title: 'マイアニメ',
          posterUrl: 'https://img/a99.png',
        ),
      ]
      ..[ScrapeSource.jikan] = const <ScrapeCandidate>[
        ScrapeCandidate(
          source: ScrapeSource.jikan,
          entryId: '55',
          title: 'マイアニメ',
          posterUrl: 'https://img/j55.png',
        ),
      ];

    await tester.pumpWidget(wrap(CoverMatchDialog(
      service: service,
      book: book,
      collectionMemberUids: const <String>['video/my_anime'],
      onApplied: () {},
    )));
    await tester.pumpAndSettle();

    // 一次搜索 = 每个可用源各查一次（不是只查「当前选中的那个」）。
    expect(service.searchCallsBySource[ScrapeSource.bangumi], 1);
    expect(service.searchCallsBySource[ScrapeSource.tmdb], 1);
    expect(service.searchCallsBySource[ScrapeSource.anilist], 1);
    expect(service.searchCallsBySource[ScrapeSource.jikan], 1);

    // 四个源的候选同时在列表里（跨源不去重：同一部片的不同语言条目都要留）。
    //
    // 必须 scrollUntilVisible 而非直接 find：结果区是 ListView.separated（懒构建），
    // 四条候选高于弹窗可视区，末条根本没被 build——直接断言会把「渲染在下面」误判成
    // 「没合并进来」。断言顺序与排序后的列表顺序一致（同分按源顺序稳定排），故一路
    // 向下滚即可，不必来回找。
    final Finder resultList = find.byType(Scrollable).last;
    for (final String key in <String>[
      'cover_match_candidate_bangumi_42',
      'cover_match_candidate_tmdb_77',
      'cover_match_candidate_anilist_99',
      'cover_match_candidate_jikan_55',
    ]) {
      await tester.scrollUntilVisible(
        find.byKey(ValueKey<String>(key)),
        120,
        scrollable: resultList,
      );
      expect(find.byKey(ValueKey<String>(key)), findsOneWidget,
          reason: '$key 应出现在聚合列表里');
    }

    // 来源选择器必须不复存在——它正是本次要消除的那个「用户必须先做的选择」。
    expect(find.byType(SegmentedButton<ScrapeSource>), findsNothing);
  });

  testWidgets('多源聚合：部分源失败只降级，其余源候选照常展示且不出失败行', (WidgetTester tester) async {
    final VideoBookRow book = await seed();
    final _StubScraperService service = buildService();
    service.sourcesOverride = <ScrapeSource>[
      ScrapeSource.bangumi,
      ScrapeSource.tmdb,
    ];
    service.perSourceCandidates[ScrapeSource.bangumi] = const <ScrapeCandidate>[
      ScrapeCandidate(
        source: ScrapeSource.bangumi,
        entryId: '42',
        title: 'My Anime',
        posterUrl: 'https://img/b42.png',
      ),
    ];
    service.perSourceErrors[ScrapeSource.tmdb] =
        const ScrapeNetworkException('tmdb down', statusCode: 503);

    await tester.pumpWidget(wrap(CoverMatchDialog(
      service: service,
      book: book,
      collectionMemberUids: const <String>['video/my_anime'],
      onApplied: () {},
    )));
    await tester.pumpAndSettle();

    // 活着的源有结果 → 用户看到候选，而不是一句「搜索失败」（BUG-1176 分界的多源推广）。
    expect(
      find.byKey(const ValueKey<String>('cover_match_candidate_bangumi_42')),
      findsOneWidget,
    );
    expect(find.text(t.video_scrape_search_failed), findsNothing);
    expect(find.text(t.video_scrape_no_results), findsNothing);
  });

  testWidgets('多源聚合：全部源失败才出可见失败行', (WidgetTester tester) async {
    final VideoBookRow book = await seed();
    final _StubScraperService service = buildService();
    service.sourcesOverride = <ScrapeSource>[
      ScrapeSource.bangumi,
      ScrapeSource.tmdb,
    ];
    service.perSourceErrors
      ..[ScrapeSource.bangumi] = const ScrapeNetworkException('bangumi down')
      ..[ScrapeSource.tmdb] = const ScrapeNetworkException('tmdb down');

    await tester.pumpWidget(wrap(CoverMatchDialog(
      service: service,
      book: book,
      collectionMemberUids: const <String>['video/my_anime'],
      onApplied: () {},
    )));
    await tester.pumpAndSettle();

    // 全挂 = 真搜不了：出失败行 + 可行动原因，绝不塌缩成「无匹配」。
    expect(find.text(t.video_scrape_search_failed), findsOneWidget);
    expect(find.text(t.video_scrape_no_results), findsNothing);
  });

  testWidgets('BUG-1251 手动输入的标准标题作为置信度评分标题', (WidgetTester tester) async {
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value('video/noisy_playlist'),
      title: const Value('My Anime v2 播放列表'),
      videoPath: Value(
        p.join(
          'anime',
          'My Anime v2 播放列表',
          'My Anime v2 播放列表 - 01.mkv',
        ),
      ),
    ));
    final VideoBookRow book =
        (await repo.getByBookUid('video/noisy_playlist'))!;
    final _StubScraperService service = buildService();
    await tester.pumpWidget(wrap(CoverMatchDialog(
      service: service,
      book: book,
      collectionMemberUids: const <String>['video/noisy_playlist'],
      onApplied: () {},
    )));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'My Anime');
    await tester.tap(find.text(t.video_scrape_search));
    await tester.pumpAndSettle();

    expect(find.text(t.video_scrape_confidence_high), findsOneWidget);
    expect(find.text(t.video_scrape_confidence_low), findsNothing);
  });

  testWidgets('TODO-2284 应用失败直出完整脱敏详情，候选保留可重试', (WidgetTester tester) async {
    const String secret = 'SECRET_APPLY_KEY_123';
    final VideoBookRow book = await seed();
    final _StubScraperService service = buildService()
      ..applyErrors.add(
        const ScrapeNetworkException(
          'Poster request failed: ClientException: connection reset, '
          'uri=https://img.example/poster?size=original&api_key=$secret',
        ),
      );
    final int logsBefore = ErrorLogService.instance.entries.length;

    await tester.pumpWidget(wrap(CoverMatchDialog(
      service: service,
      book: book,
      collectionMemberUids: const <String>['video/my_anime'],
      onApplied: () {},
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text(t.video_scrape_use).first);
    await tester.pumpAndSettle();

    // 弹窗与候选都保留，用户可换候选或重试；失败不再只是一闪而过的两句 toast。
    expect(find.text(t.video_scrape_apply_failed), findsOneWidget);
    expect(find.text(t.video_scrape_use), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, t.video_scrape_use),
          )
          .onPressed,
      isNotNull,
    );
    expect(find.text(t.scrape_reason_network), findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey<String>('scrape_failure_detail_toggle')),
    );
    await tester.pumpAndSettle();
    final SelectableText detail =
        tester.widget<SelectableText>(find.byType(SelectableText));
    expect(detail.data, contains('Poster request failed'));
    expect(detail.data, contains('size=original'));
    expect(detail.data, contains('api_key=$kRedactedPlaceholder'));
    expect(detail.data, isNot(contains(secret)));

    // 错误日志与界面吃同一份脱敏详情，不能只堵 UI、让日志/上传继续漏。
    final List<ErrorLogEntry> added =
        ErrorLogService.instance.entries.sublist(logsBefore);
    final ErrorLogEntry applyLog = added.singleWhere(
      (ErrorLogEntry entry) =>
          entry.source == 'CoverMatchDialog.applyCandidate',
    );
    expect(applyLog.error, contains('api_key=$kRedactedPlaceholder'));
    expect(applyLog.error, isNot(contains(secret)));
  });

  // BUG-1176：搜索失败曾被 `catch (_)` 吞成空表，界面显示「无匹配」——用户无从分辨
  // 「搜不到」与「搜不了」，也拿不到任何可上报的原因。失败必须有出口。
  testWidgets('BUG-1176 搜索失败出可见错误行（非「无匹配」）+ 可行动原因 + 落错误日志，且可重试',
      (WidgetTester tester) async {
    final VideoBookRow book = await seed();
    final _StubScraperService service = buildService()
      ..searchErrors.add(const ScrapeNetworkException('transport down'));
    final int logsBefore = ErrorLogService.instance.entries.length;

    await tester.pumpWidget(wrap(CoverMatchDialog(
      service: service,
      book: book,
      collectionMemberUids: const <String>['video/my_anime'],
      onApplied: () {},
    )));
    await tester.pumpAndSettle();

    // 失败态可见，且**不是**「无匹配」空态。
    expect(find.text(t.video_scrape_search_failed), findsOneWidget);
    expect(find.text(t.video_scrape_no_results), findsNothing);
    // 无 statusCode = 没拿到可用响应 → 给「检查网络后重试」这一路可行动原因。
    expect(find.text(t.scrape_reason_network), findsOneWidget);
    // 原始原因落错误日志（用户可在「错误日志」页查看/上传）。
    final List<ErrorLogEntry> added =
        ErrorLogService.instance.entries.sublist(logsBefore);
    expect(
        added.any((ErrorLogEntry e) => e.source == 'CoverMatchDialog.search'),
        isTrue);

    // 再点「搜索」重试：失败行消失，候选正常渲染。
    await tester.tap(find.text(t.video_scrape_search));
    await tester.pumpAndSettle();
    expect(find.text(t.video_scrape_search_failed), findsNothing);
    expect(find.text(t.scrape_reason_network), findsNothing);
    expect(find.text(t.video_scrape_confidence_high), findsOneWidget);
    expect(service.searchCalls, 2);
  });

  testWidgets('BUG-1176 源站带 HTTP 状态码时给出「源站报错」而非「检查网络」',
      (WidgetTester tester) async {
    final VideoBookRow book = await seed();
    final _StubScraperService service = buildService()
      ..searchErrors.add(const ScrapeNetworkException('Bangumi search HTTP 503',
          statusCode: 503));

    await tester.pumpWidget(wrap(CoverMatchDialog(
      service: service,
      book: book,
      collectionMemberUids: const <String>['video/my_anime'],
      onApplied: () {},
    )));
    await tester.pumpAndSettle();

    expect(find.text(t.video_scrape_search_failed), findsOneWidget);
    expect(find.text(t.scrape_reason_server), findsOneWidget);
    expect(find.text(t.scrape_reason_network), findsNothing);
  });

  // BUG-1219：两句折叠文案（「检查网络」/「源站报错」）只回答「我该做什么」，不回答
  // 「到底怎么了」——用户拿不到状态码、主机名、底层 SocketException，只能换页翻错误
  // 日志。完整异常串必须留在出错的地方，并且可一键复制上报。
  testWidgets('BUG-1219 搜索失败在弹窗内直出完整技术详情 + 可复制', (WidgetTester tester) async {
    final VideoBookRow book = await seed();
    final _StubScraperService service = buildService()
      ..searchErrors.add(const ScrapeNetworkException(
          'Bangumi search request failed: SocketException: '
          "Failed host lookup: 'api.bgm.tv'"));

    await tester.pumpWidget(wrap(CoverMatchDialog(
      service: service,
      book: book,
      collectionMemberUids: const <String>['video/my_anime'],
      onApplied: () {},
    )));
    await tester.pumpAndSettle();

    // 折叠原因仍在（可行动指引不被详情取代）。
    expect(find.text(t.scrape_reason_network), findsOneWidget);
    // 详情**默认折叠**：普通断网场景不拿英文异常糊用户一脸。
    expect(find.byType(SelectableText), findsNothing);
    expect(find.text(t.copy_error), findsNothing);
    expect(find.text(t.scrape_failure_detail_show), findsOneWidget);

    // 一键展开后，完整异常串直接可见：异常类型 + 底层主机名都在界面上。
    await tester.tap(
        find.byKey(const ValueKey<String>('scrape_failure_detail_toggle')));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate((Widget w) =>
          w is SelectableText &&
          (w.data ?? '').contains('ScrapeNetworkException') &&
          (w.data ?? '').contains('api.bgm.tv')),
      findsOneWidget,
    );
    // 一键复制上报入口（展开后才出现）。
    expect(find.text(t.copy_error), findsOneWidget);
    expect(find.text(t.scrape_failure_detail_hide), findsOneWidget);
  });

  // 第三个源：离线库（ScrapeSource.offlineDb）失败抛的不是 ScrapeNetworkException，
  // 但同样必须能拿到完整详情——否则「离线库坏了」这条路仍然只剩一句没用的话。
  testWidgets('BUG-1219 离线库源失败同样能展开出完整详情', (WidgetTester tester) async {
    final VideoBookRow book = await seed();
    final _StubScraperService service = buildService()
      ..searchErrors
          .add(const FormatException('offline db slim cache: bad row field'));

    await tester.pumpWidget(wrap(CoverMatchDialog(
      service: service,
      book: book,
      collectionMemberUids: const <String>['video/my_anime'],
      onApplied: () {},
    )));
    await tester.pumpAndSettle();

    await tester.tap(
        find.byKey(const ValueKey<String>('scrape_failure_detail_toggle')));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate((Widget w) =>
          w is SelectableText &&
          (w.data ?? '').contains('offline db slim cache: bad row field')),
      findsOneWidget,
    );
  });

  testWidgets('BUG-1219 带状态码的失败同样直出完整详情（含状态码）', (WidgetTester tester) async {
    final VideoBookRow book = await seed();
    final _StubScraperService service = buildService()
      ..searchErrors.add(const ScrapeNetworkException('Bangumi search HTTP 502',
          statusCode: 502));

    await tester.pumpWidget(wrap(CoverMatchDialog(
      service: service,
      book: book,
      collectionMemberUids: const <String>['video/my_anime'],
      onApplied: () {},
    )));
    await tester.pumpAndSettle();

    expect(find.text(t.scrape_reason_server), findsOneWidget);
    await tester.tap(
        find.byKey(const ValueKey<String>('scrape_failure_detail_toggle')));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
          (Widget w) => w is SelectableText && (w.data ?? '').contains('502')),
      findsOneWidget,
    );
  });

  // BUG-1211：用户「匹配的是合集的封面，谁说应用到本机里面的视频了」。合集入口换的
  // 必须是合集自己那张封面，成员一个都不能动；「同时应用到本合集全部 N 集」这个设定
  // 在合集入口下必须不存在。
  testWidgets('BUG-1211 合集入口：只改合集自己的封面，N 个成员的封面逐个未变',
      (WidgetTester tester) async {
    final VideoBookRow book = await seed();
    final _StubScraperService service = buildService();
    // 构造一个 3 成员合集，每个成员先各有一张**不同**的既有封面（能被改动就一定看得出）。
    const List<String> members = <String>[
      'video/my_anime',
      'video/ep2',
      'video/ep3',
    ];
    final Map<String, String> coverBefore = <String, String>{};
    for (final String uid in members) {
      final String cover = p.join(tmp.path, '${uid.split('/').last}_old.jpg');
      File(cover).writeAsBytesSync(_fakePng);
      await db.upsertVideoBook(VideoBooksCompanion(
        bookUid: Value(uid),
        title: Value(uid),
        videoPath: Value(p.join('anime', 'My Anime', '$uid.mkv')),
        coverPath: Value(cover),
      ));
      coverBefore[uid] = cover;
    }
    final int collectionId =
        await db.createMediaCollection('我的合集', collectionType: 'collection');
    for (final String uid in members) {
      await db.addToCollection(collectionId, MediaKind.video, uid);
    }

    await tester.pumpWidget(wrap(CoverMatchDialog(
      service: service,
      book: book,
      // 合集入口不读成员表；即便误传整表也不得成为写入目标。
      collectionMemberUids: members,
      onApplied: () {},
      collection: CoverMatchCollectionTarget(
        id: collectionId,
        name: '我的合集',
        // BUG-1310 起注入的是整份刮削产物（封面 + 横版背景 + 条目资料），生产落库
        // 走 applyCollectionScrape。本用例锁的仍是 BUG-1211 那条不变量：合集入口
        // 只写合集自己，成员一个不碰。
        applyScrape: (
          CollectionScrapeResult result, {
          required String? confirmedTitle,
        }) =>
            applyCollectionScrape(
          db,
          collectionId,
          result,
          confirmedTitle: confirmedTitle,
        ),
      ),
    )));
    await tester.pumpAndSettle();

    // 标题分得清在给哪个合集换封面。
    expect(
      find.text(t.video_scrape_online_match_collection(name: '我的合集')),
      findsOneWidget,
    );
    // 「同时应用到本合集全部 N 集」在合集入口下彻底不出现（设定已删）。
    expect(
      find.byKey(const ValueKey<String>('cover_match_apply_collection')),
      findsNothing,
    );
    expect(find.textContaining(t.video_scrape_apply_to_collection(n: 3)),
        findsNothing);

    // 合集路径走**真实**下载器 + 真实落盘（不桩掉被测行为），故需 runAsync 放行真 IO。
    await tester.runAsync(() async {
      await tester.tap(find.text(t.video_scrape_use).first);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    // 只 pump 固定帧数不用 pumpAndSettle：候选列表里的海报缩略图是 Image.network，
    // 在测试环境里永不完成，pumpAndSettle 会一路等到超时（弹窗本身早就上来了）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // BUG-1310 复议：改名要单独确认。本用例锁的是 BUG-1211（封面写给谁），
    // 故选「保留当前名称」，让合集名那条路径整条不参与。
    expect(find.text(t.video_scrape_collection_rename_title), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text(t.video_scrape_collection_rename_keep));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();

    // ① 合集自己的封面真写穿 DB，且文件真落地。
    final MediaCollectionRow? row =
        await db.getMediaCollectionById(collectionId);
    expect(row, isNotNull);
    expect(row!.coverPath, isNotNull);
    expect(File(row.coverPath!).existsSync(), isTrue);
    expect(p.basename(row.coverPath!), '$collectionId.jpg');
    expect(p.basename(p.dirname(row.coverPath!)), 'collections');

    // ② 成员封面逐个未变——这正是用户纠正的那一点。
    for (final String uid in members) {
      final VideoBookRow? m = await repo.getByBookUid(uid);
      expect(m, isNotNull, reason: uid);
      expect(m!.coverPath, coverBefore[uid],
          reason: '$uid 的封面被改了：合集换封面绝不能写进成员（BUG-1211）');
    }
    // ③ 成员批量写入路径根本没被调用（不是「写了又写回去」）。
    expect(service.appliedUids, isEmpty);

    // ④ BUG-1310 契约 ①：拒绝改名 → 合集名一字不动，且不产生任何旧名同步墓碑
    //    （墓碑会被同步出去删掉其他设备上的旧名副本，那是不可撤销的）。
    expect(row.name, '我的合集');
    expect(
      await db.select(db.collectionMemberTombstones).get(),
      isEmpty,
      reason: '用户拒绝了改名，却写了合集墓碑 → 其他设备上的旧名副本会被删',
    );
  });

  // BUG-1310 复议：改名前必须弹确认，明示「旧名 → 新名」。这里锁**确认分支**：
  // 用户看过两行、点了「重命名」，名字才真被改写。
  testWidgets('BUG-1310 合集入口：改名前弹确认，确认后才改名', (WidgetTester tester) async {
    final VideoBookRow book = await seed();
    final _StubScraperService service = buildService();
    final int collectionId =
        await db.createMediaCollection('我的合集', collectionType: 'collection');
    await db.addToCollection(collectionId, MediaKind.video, book.bookUid);
    String? passedConfirmedTitle;

    await tester.pumpWidget(wrap(CoverMatchDialog(
      service: service,
      book: book,
      collectionMemberUids: <String>[book.bookUid],
      onApplied: () {},
      collection: CoverMatchCollectionTarget(
        id: collectionId,
        name: '我的合集',
        applyScrape: (
          CollectionScrapeResult result, {
          required String? confirmedTitle,
        }) {
          passedConfirmedTitle = confirmedTitle;
          return applyCollectionScrape(
            db,
            collectionId,
            result,
            confirmedTitle: confirmedTitle,
          );
        },
      ),
    )));
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      await tester.tap(find.text(t.video_scrape_use).first);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    // 同上：候选缩略图是永不完成的 Image.network，只能 pump 固定帧。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 弹窗两行都在：只显示新名的话用户无从判断这次改动是什么。
    expect(find.text(t.video_scrape_collection_rename_title), findsOneWidget);
    expect(
      find.text(t.video_scrape_collection_rename_from(name: '我的合集')),
      findsOneWidget,
      reason: '必须显示旧名，否则「旧名 → 新名」只剩一半',
    );
    expect(
      find.text(t.video_scrape_collection_rename_to(name: 'My Anime')),
      findsOneWidget,
    );

    await tester.runAsync(() async {
      await tester.tap(find.text(t.video_scrape_collection_rename_confirm));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();

    // 落库层拿到的正是用户眼前看到的那个名字（不是弹窗外另算一遍）。
    expect(passedConfirmedTitle, 'My Anime');
    final MediaCollectionRow? row =
        await db.getMediaCollectionById(collectionId);
    expect(row!.name, 'My Anime');
    expect(row.coverPath, isNotNull, reason: '确认改名不影响封面照常落地');
  });

  testWidgets('单集入口：标题不带合集名 + 默认只改这一集', (WidgetTester tester) async {
    final VideoBookRow book = await seed();
    final _StubScraperService service = buildService();

    await tester.pumpWidget(wrap(CoverMatchDialog(
      service: service,
      book: book,
      collectionMemberUids: const <String>[
        'video/my_anime',
        'video/ep2',
      ],
      onApplied: () {},
    )));
    await tester.pumpAndSettle();

    expect(find.text(t.video_scrape_online_match), findsOneWidget);
    final CheckboxListTile toggle = tester.widget<CheckboxListTile>(
      find.byKey(const ValueKey<String>('cover_match_apply_collection')),
    );
    expect(toggle.value, isFalse, reason: '他点的就是这一集，别替他改整个合集');
    expect(find.text(t.video_scrape_apply_to_collection_hint), findsOneWidget);

    await tester.tap(find.text(t.video_scrape_use).first);
    await tester.pumpAndSettle();
    expect(service.appliedUids, <String>['video/my_anime']);
  });
}
