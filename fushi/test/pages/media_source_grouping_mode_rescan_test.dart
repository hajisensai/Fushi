// BUG-4355（反馈 YUH015QaF2）：视频来源设置里把分组方式从「按文件夹」改成「按作品」，
// 修复前只写模式、等「下次扫描」再归组。可视频库折叠与刮削计划都是**即时**按来源当前
// 模式取舍的：按作品模式不再把成员折进目录合集，于是整部剧在「系列」页散成每集一张
// 卡，期间刮削还把每一集当一部作品去识别。
//
// 修复后 `MediaSourcesViewState.applyVideoGroupingMode` 写完模式立即走同一条扫描管线
// 重扫：本测试用真实磁盘目录 + 真实 SourceLibraryScanner 钉住「改完模式，库里已经按
// 新模式归好组」。
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';
import 'package:fushi/src/media/video/video_folder_collection_policy.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/media_sources_view.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart'
    show VideoSourceScrapeWork;
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:path/path.dart' as p;

import '../helpers/test_platform_services.dart';

FushiDatabase _memDb() => FushiDatabase.forTesting(
  NativeDatabase.memory(
    setup: (rawDb) => rawDb.execute('PRAGMA foreign_keys = ON'),
  ),
);

const MethodChannel _pathProvider = MethodChannel(
  'plugins.flutter.io/path_provider',
);

class _NoopScrapeRunner implements VideoSourceScrapeRunner {
  @override
  Future<SourceScrapeReport> scrapeSource(
    SourceLibraryRow source, {
    required VideoSourceScrapeCancellationToken cancellationToken,
    required VideoSourceScrapeProgressCallback onProgress,
    VideoSourceScrapeConfirmationCallback? onConfirmation,
    VideoSourceScrapeBatchContext? batchContext,
    List<VideoSourceScrapeWork>? plannedWorks,
    String runScope = 'source',
  }) async {
    return SourceScrapeReport(sourceIds: <int>[source.id]);
  }
}

void main() {
  late Directory tempDir;
  late FushiDatabase db;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('bug4323_grouping_mode');
    db = _memDb();
    AppPaths.debugResetDocumentsLayoutCache();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, null);
    AppPaths.debugResetDocumentsLayoutCache();
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  void mockPathProvider() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          _pathProvider,
          (MethodCall call) async => switch (call.method) {
            'getApplicationDocumentsDirectory' => p.join(
              tempDir.path,
              'documents',
            ),
            'getTemporaryDirectory' => p.join(tempDir.path, 'systemp'),
            'getApplicationSupportDirectory' => p.join(tempDir.path, 'support'),
            _ => null,
          },
        );
  }

  Future<MediaSourcesViewState> pumpView(
    WidgetTester tester, {
    VideoSourceScrapeTaskController? scrapeTaskController,
  }) async {
    final AppModel appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db);
    final GlobalKey<MediaSourcesViewState> viewKey =
        GlobalKey<MediaSourcesViewState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[appProvider.overrideWith((ref) => appModel)],
        child: MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: Size(420, 800)),
            child: Scaffold(
              body: SingleChildScrollView(
                child: MediaSourcesView(
                  key: viewKey,
                  mediaKind: 'video',
                  scrapeTaskController: scrapeTaskController,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return viewKey.currentState!;
  }

  Future<Map<String, int>> folded() async => applyVideoFolderCollectionPolicy(
    primary: await db.getPrimaryCollectionIdByEntry(),
    collections: await db.getAllMediaCollections(),
    items: await db.getAllCollectionItems(),
    books: await db.allVideoBooks(),
    sources: await db.getMediaSourcesByKind('video'),
  );

  testWidgets('按文件夹改按作品：保存即重扫，整部剧折进同一个作品合集', (WidgetTester tester) async {
    mockPathProvider();
    final Directory show = Directory(p.join(tempDir.path, '白莲花度假村'))
      ..createSync(recursive: true);
    for (int i = 1; i <= 6; i++) {
      File(
        p.join(show.path, '白莲花度假村.S01E0$i.2021.1080p.WEB-DL.mkv'),
      ).writeAsStringSync('fake-video-$i');
    }
    final String root = normalizeSourceRootPath(
      tempDir.path,
      transport: 'local',
    );
    final int sourceId = await db.insertMediaSource(
      MediaSourcesCompanion(
        label: const Value('TV'),
        mediaKind: const Value('video'),
        transport: const Value('local'),
        rootPath: Value(root),
        recursive: const Value(true),
        videoGroupingMode: const Value('folder'),
        sortOrder: const Value(0),
        createdAt: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
    final SourceLibraryRow folderRow = (await db.getMediaSourceById(sourceId))!;
    final SourceScanSummary first = (await tester.runAsync(
      () => SourceLibraryScanner(db).scan(folderRow),
    ))!;
    expect(first.error, isNull);
    final List<VideoBookRow> books = await VideoBookRepository(db).listAll();
    expect(books, hasLength(6));
    final Map<String, int> folderFold = await folded();
    expect(
      <int?>{
        for (final VideoBookRow book in books)
          folderFold['video|${book.bookUid}'],
      },
      hasLength(1),
      reason: '文件夹模式下整部剧本来就折成一张卡（用户说的「以前能聚合」）',
    );

    final MediaSourcesViewState state = await pumpView(tester);
    await tester.runAsync(
      () => state.applyVideoGroupingMode(folderRow, 'series'),
    );
    await tester.pumpAndSettle();

    final SourceLibraryRow after = (await db.getMediaSourceById(sourceId))!;
    expect(after.videoGroupingMode, 'series');
    final Map<String, int> seriesFold = await folded();
    final Set<int?> ids = <int?>{
      for (final VideoBookRow book in books)
        seriesFold['video|${book.bookUid}'],
    };
    expect(ids, hasLength(1), reason: '修复前只写模式不归组，这里是 6 张散卡（每集 null）');
    final int playlistId = ids.single!;
    expect(
      (await db.getMediaCollectionById(playlistId))!.collectionType,
      'playlist',
    );
  });

  testWidgets('模式没变不重扫', (WidgetTester tester) async {
    final DateTime staleScan = DateTime(2020, 1, 1);
    final int sourceId = await db.insertMediaSource(
      MediaSourcesCompanion(
        label: const Value('TV'),
        mediaKind: const Value('video'),
        transport: const Value('local'),
        rootPath: Value(
          normalizeSourceRootPath(tempDir.path, transport: 'local'),
        ),
        recursive: const Value(true),
        videoGroupingMode: const Value('series'),
        sortOrder: const Value(0),
        lastScannedAt: Value(staleScan),
        createdAt: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
    final SourceLibraryRow row = (await db.getMediaSourceById(sourceId))!;
    final MediaSourcesViewState state = await pumpView(tester);
    await tester.runAsync(() => state.applyVideoGroupingMode(row, 'series'));
    await tester.pumpAndSettle();
    expect(
      (await db.getMediaSourceById(sourceId))!.lastScannedAt,
      staleScan,
      reason: '只改刮削设置、不改分组方式时不该触发整源重扫',
    );
  });

  testWidgets('另一条扫描 / 刮削进行中：不改模式（否则又落进「模式已变、归组没跟」）', (
    WidgetTester tester,
  ) async {
    final int sourceId = await db.insertMediaSource(
      MediaSourcesCompanion(
        label: const Value('TV'),
        mediaKind: const Value('video'),
        transport: const Value('local'),
        rootPath: Value(
          normalizeSourceRootPath(tempDir.path, transport: 'local'),
        ),
        recursive: const Value(true),
        videoGroupingMode: const Value('folder'),
        sortOrder: const Value(0),
        createdAt: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
    final SourceLibraryRow row = (await db.getMediaSourceById(sourceId))!;
    final VideoSourceScrapeTaskController controller =
        VideoSourceScrapeTaskController(_NoopScrapeRunner());
    addTearDown(controller.dispose);
    final MediaSourcesViewState state = await pumpView(
      tester,
      scrapeTaskController: controller,
    );
    // 设置对话框开着期间，另一个来源的扫描开始了（_rescan 在 isBusy 时直接返回）。
    final Completer<void> otherScan = Completer<void>();
    final Future<void> running = controller.runSourceScan<void>(
      sourceId + 1,
      () => otherScan.future,
    );
    await tester.pump();
    expect(state.isBusy, isTrue);

    await tester.runAsync(() => state.applyVideoGroupingMode(row, 'series'));
    await tester.pump();
    expect(
      (await db.getMediaSourceById(sourceId))!.videoGroupingMode,
      'folder',
      reason: '忙时重扫跑不了，模式必须保持不变，不能只写模式不归组',
    );

    otherScan.complete();
    await tester.runAsync(() => running);
    await tester.pumpAndSettle();
  });
}
