import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/media/video/cover_ui/cover_match_dialog.dart';
import 'package:hibiki/src/media/video/scraper/alias_cache.dart';
import 'package:hibiki/src/media/video/scraper/bangumi_client.dart';
import 'package:hibiki/src/media/video/scraper/cover_meta_store.dart';
import 'package:hibiki/src/media/video/scraper/cover_downloader.dart';
import 'package:hibiki/src/media/video/scraper/cover_scraper_service.dart';
import 'package:hibiki/src/media/video/scraper/scraper_types.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/platform/platform_providers.dart';
import 'package:hibiki/src/platform/platform_services.dart';
import 'package:hibiki_core/hibiki_core.dart';
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
    super.coversDirectory,
  });

  final List<ScrapeCandidate> candidates;
  final List<String> appliedUids = <String>[];

  /// 逐次出队的搜索异常（非 null 即抛）。让「第一次失败 → 重试成功」可测。
  final List<Object?> searchErrors = <Object?>[];
  int searchCalls = 0;

  @override
  Future<List<ScrapeCandidate>> searchCandidates({
    required ScrapeSource source,
    required String keyword,
    int? year,
  }) async {
    searchCalls++;
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
    appliedUids.addAll(bookUids);
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

  late HibikiDatabase db;
  late VideoBookRepository repo;
  late Directory tmp;
  late AppModel appModel;
  late PlatformServices platformServices;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    repo = VideoBookRepository(db);
    tmp = await Directory.systemTemp.createTemp('hibiki_poster_match_');
    final PreferencesRepository prefs = PreferencesRepository(db);
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
    // 置信度徽标（高匹配）。
    expect(find.text(t.video_scrape_confidence_high), findsOneWidget);

    // 点「使用」→ 回调应用（桩为纯内存记账，pumpAndSettle 即可驱动）。
    await tester.tap(find.text(t.video_scrape_use).first);
    await tester.pumpAndSettle();

    expect(applied, isTrue);
    expect(service.appliedUids, <String>['video/my_anime']);
    // 弹窗应用后关闭。
    expect(find.text(t.video_scrape_use), findsNothing);
  });

  // BUG-1174：搜索失败曾被 `catch (_)` 吞成空表，界面显示「无匹配」——用户无从分辨
  // 「搜不到」与「搜不了」，也拿不到任何可上报的原因。失败必须有出口。
  testWidgets('BUG-1174 搜索失败出可见错误行（非「无匹配」）+ 可行动原因 + 落错误日志，且可重试',
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

  testWidgets('BUG-1174 源站带 HTTP 状态码时给出「源站报错」而非「检查网络」',
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
}
