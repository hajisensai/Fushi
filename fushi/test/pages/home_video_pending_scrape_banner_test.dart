import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/media/source_library/source_library_row.dart';
import 'package:fushi/src/media/video/metadata/video_library_scrape_sweep.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi/src/media/video/metadata/video_source_work_planner.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

/// BUG-2201：作品刮不出规范身份时**没有任何可见症状**——封面照样有（抽帧兜底那
/// 张），卡片照样进库，用户只会觉得「封面怎么是视频截图」，不知道有个待确认队列
/// 在等他。视频页顶部因此常驻一条提醒，数量为 0 时零高度。
///
/// BUG-2199：提醒条的数据端口同时是自动补刮的触发点，且必须挂在「库里多出条目」
/// 上——内置下载管线的 import 落库总是晚于进页面那一轮，只在进页面时跑一次的话，
/// 本次会话下载的作品永远等不到补刮。
class _IdleRunner implements VideoSourceScrapeRunner {
  @override
  Future<SourceScrapeReport> scrapeSource(
    SourceLibraryRow source, {
    required VideoSourceScrapeCancellationToken cancellationToken,
    required VideoSourceScrapeProgressCallback onProgress,
    VideoSourceScrapeConfirmationCallback? onConfirmation,
    VideoSourceScrapeBatchContext? batchContext,
    List<VideoSourceScrapeWork>? plannedWorks,
    String runScope = 'source',
  }) async =>
      SourceScrapeReport(sourceIds: <int>[source.id]);
}

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_pending_scrape_pp');
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
      try {
        pathProviderDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  late FushiDatabase db;
  late PlatformServices platformServices;
  late FakeAnkiRepository ankiRepository;
  late AppModel appModel;
  late VideoSourceScrapeTaskController controller;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory storeDir =
        Directory.systemTemp.createTempSync('hibiki_pending_scrape_store');
    platformServices = testPlatformServices();
    ankiRepository = FakeAnkiRepository();
    controller = VideoSourceScrapeTaskController(_IdleRunner());
    appModel = AppModel(platformServices)
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
  });

  tearDown(() async {
    controller.dispose();
    await db.close();
  });

  Future<int> addSource() => db.insertMediaSource(
        MediaSourcesCompanion.insert(
          label: 'A',
          mediaKind: 'video',
          rootPath: 'D:/A',
          createdAt: 1,
        ),
      );

  Future<void> addVideo(String uid, String path, int sourceId, String title) =>
      db.upsertVideoBook(VideoBooksCompanion(
        bookUid: Value<String>(uid),
        title: Value<String>(title),
        videoPath: Value<String>(path),
        sourceId: Value<int?>(sourceId),
      ));

  /// 真链路的端口：planner → 待确认判据 → 清单。`isEnabled: false` 让它只回传
  /// 清单、不真发批次（本用例断的是提醒，不是刮削本身）。
  ({
    Future<List<VideoPendingScrapeWork>> Function() load,
    List<int> callCount,
  }) makePort() {
    final VideoLibraryScrapeSweep sweep = VideoLibraryScrapeSweep(
      database: db,
      controller: controller,
      isEnabled: () => false,
    );
    final List<int> calls = <int>[0];
    return (
      load: () {
        calls[0]++;
        return sweep.sweepAndListPending();
      },
      callCount: calls,
    );
  }

  Widget buildApp(Future<List<VideoPendingScrapeWork>> Function()? load,
          {VoidCallback? onOpenScrapeTasks}) =>
      ProviderScope(
        overrides: <Override>[
          platformServicesProvider.overrideWithValue(platformServices),
          ankiRepositoryProvider.overrideWithValue(ankiRepository),
          appProvider.overrideWith((ref) => appModel),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: HomeVideoPage(
                repo: VideoBookRepository(db),
                section: VideoLibrarySection.allVideos,
                loadPendingScrapeWorks: load,
                onOpenScrapeTasks: onOpenScrapeTasks,
                scrapeTaskController: controller,
              ),
            ),
          ),
        ),
      );

  testWidgets('有作品没确认身份时，视频页顶部常驻提醒条并可点进确认队列', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final int sourceId = await addSource();
    await addVideo('movie-a', 'D:/A/Unscraped Movie (2020).mkv', sourceId,
        'Unscraped Movie');

    int opened = 0;
    await tester.pumpWidget(buildApp(
      makePort().load,
      onOpenScrapeTasks: () => opened++,
    ));
    await tester.pumpAndSettle();

    expect(
      find.text(t.video_library_scrape_pending_banner(count: 1)),
      findsOneWidget,
      reason: '刮不出身份是静默的，必须有一条看得见的提醒',
    );

    await tester.tap(
      find.widgetWithText(
        FilledButton,
        t.video_library_scrape_pending_banner_action,
      ),
    );
    await tester.pumpAndSettle();
    expect(opened, 1, reason: '提醒条要能直接进待确认队列');
  });

  testWidgets('全部作品都有身份时提醒条零高度', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final int sourceId = await addSource();
    await addVideo(
        'movie-a', 'D:/A/Scraped Movie (2020).mkv', sourceId, 'Scraped Movie');
    final int workId = await db.into(db.videoMetadataWorks).insert(
          VideoMetadataWorksCompanion.insert(
            bookUid: const Value<String?>('movie-a'),
            mediaType: 'movie',
            title: 'seeded',
            updatedAt: 1,
          ),
        );
    await db.into(db.videoMetadataProviderIdentities).insert(
          VideoMetadataProviderIdentitiesCompanion.insert(
            identityKey: 'work:$workId:anidb',
            workId: Value<int?>(workId),
            provider: 'anidb',
            externalId: '123',
            updatedAt: 1,
          ),
        );

    await tester.pumpWidget(buildApp(makePort().load));
    await tester.pumpAndSettle();

    expect(
      find.text(t.video_library_scrape_pending_banner(count: 1)),
      findsNothing,
    );
  });

  testWidgets('端口未接线时不显示提醒条', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final int sourceId = await addSource();
    await addVideo('movie-a', 'D:/A/Unscraped Movie (2020).mkv', sourceId,
        'Unscraped Movie');

    await tester.pumpWidget(buildApp(null));
    await tester.pumpAndSettle();

    expect(
      find.text(t.video_library_scrape_pending_banner(count: 1)),
      findsNothing,
    );
  });

  testWidgets('库里多出条目就地重算，不必切走再回来（BUG-2199）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final int sourceId = await addSource();
    await tester.pumpWidget(buildApp(makePort().load));
    await tester.pumpAndSettle();
    expect(
      find.text(t.video_library_scrape_pending_banner(count: 1)),
      findsNothing,
    );

    // 内置下载管线 import 落库走的就是这条 videoBooks uid 流：用户停在视频页
    // 不动，提醒也必须自己冒出来。
    await addVideo('movie-a', 'D:/A/Fresh Download (2023).mkv', sourceId,
        'Fresh Download');
    await tester.pumpAndSettle();

    expect(
      find.text(t.video_library_scrape_pending_banner(count: 1)),
      findsOneWidget,
      reason: '下载入库的作品必须当场进提醒，不能等到重启 app',
    );
  });
}
