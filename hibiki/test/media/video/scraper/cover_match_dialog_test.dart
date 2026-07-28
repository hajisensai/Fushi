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
    // 完整异常串直接可见：异常类型 + 底层主机名都在界面上，不只在错误日志里。
    expect(
      find.byWidgetPredicate((Widget w) =>
          w is SelectableText &&
          (w.data ?? '').contains('ScrapeNetworkException') &&
          (w.data ?? '').contains('api.bgm.tv')),
      findsOneWidget,
    );
    // 一键复制上报入口。
    expect(find.text(t.copy_error), findsOneWidget);
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
    expect(
      find.byWidgetPredicate(
          (Widget w) => w is SelectableText && (w.data ?? '').contains('502')),
      findsOneWidget,
    );
  });

  // 合集入口（collectionName 非 null）与单集入口的默认口径不同。合集入口下默认不勾
  // 「应用到全合集」意味着只改 seed 那一集，而 seed 只是首个可解析成员、未必是合集卡
  // 上显示的封面——用户会看到「点了半天毫无变化」，以为功能坏了。

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
        applyCover: (String coverPath) =>
            db.updateMediaCollectionCoverPath(collectionId, coverPath),
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

    await tester.tap(find.text(t.video_scrape_use).first);
    await tester.pumpAndSettle();
    expect(service.appliedUids, <String>['video/my_anime']);
  });
}
