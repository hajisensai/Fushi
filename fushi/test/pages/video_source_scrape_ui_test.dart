import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/source_library/source_library_row.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_dialog.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi/src/pages/implementations/media_sources_view.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

FushiDatabase _memDb() => FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (rawDb) => rawDb.execute('PRAGMA foreign_keys = ON'),
      ),
    );

Future<int> _seedSource(
  FushiDatabase db, {
  required String mediaKind,
  String label = 'Anime',
}) =>
    db.insertMediaSource(
      MediaSourcesCompanion(
        label: Value<String>(label),
        mediaKind: Value<String>(mediaKind),
        transport: const Value<String>('local'),
        rootPath: Value<String>('/nonexistent/$mediaKind'),
        createdAt: Value<int>(DateTime.now().millisecondsSinceEpoch),
      ),
    );

Future<void> _pumpView(
  WidgetTester tester,
  FushiDatabase db, {
  required String mediaKind,
  Future<void> Function(SourceLibraryRow source)? onScrapeSource,
  Future<void> Function(
    SourceLibraryRow source,
    SourceScanSummary summary,
  )? onVideoScanCompleted,
  VideoSourceScrapeTaskController? scrapeTaskController,
}) async {
  final AppModel appModel = AppModel(testPlatformServices())
    ..wireDatabaseForTesting(db);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((ref) => appModel),
      ],
      child: MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: Size(900, 900)),
          child: Scaffold(
            body: MediaSourcesView(
              mediaKind: mediaKind,
              onScrapeSource: onScrapeSource,
              onVideoScanCompleted: onVideoScanCompleted,
              scrapeTaskController: scrapeTaskController,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _HoldingScrapeRunner implements VideoSourceScrapeRunner {
  final Completer<void> release = Completer<void>();
  int calls = 0;

  @override
  Future<SourceScrapeReport> scrapeSource(
    SourceLibraryRow source, {
    required VideoSourceScrapeCancellationToken cancellationToken,
    required VideoSourceScrapeProgressCallback onProgress,
    VideoSourceScrapeConfirmationCallback? onConfirmation,
    VideoSourceScrapeBatchContext? batchContext,
  }) async {
    calls++;
    onProgress(
      VideoSourceScrapeProgress(
        phase: VideoSourceScrapePhase.recognizing,
        sourceId: source.id,
        sourceLabel: source.label,
        currentWorkTitle: 'Example Show',
        current: 1,
        total: 3,
      ),
    );
    await release.future;
    return SourceScrapeReport(
      sourceIds: <int>[source.id],
      totalWorks: 3,
      succeededWorks: 3,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('video row exposes scrape/settings and shows live task progress',
      (WidgetTester tester) async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final int sourceId = await _seedSource(db, mediaKind: 'video');
    final _HoldingScrapeRunner runner = _HoldingScrapeRunner();
    final VideoSourceScrapeTaskController controller =
        VideoSourceScrapeTaskController(runner);
    addTearDown(controller.dispose);

    await _pumpView(
      tester,
      db,
      mediaKind: 'video',
      scrapeTaskController: controller,
      onScrapeSource: (SourceLibraryRow source) async {
        await controller.scrapeSource(source);
      },
    );

    expect(find.byTooltip('Scrape this source'), findsOneWidget);
    expect(find.byTooltip('Source scrape settings'), findsOneWidget);
    await tester.tap(find.byTooltip('Scrape this source'));
    await tester.pump();

    expect(runner.calls, 1);
    expect(find.textContaining('Matching · 1/3'), findsOneWidget);
    expect(find.textContaining('Example Show'), findsOneWidget);

    // 刮削期间重新扫描按钮不可用，不会改写 scan 记录。
    await tester.tap(find.byTooltip('Rescan'), warnIfMissed: false);
    await tester.pump();
    final SourceLibraryRow source = (await db.getMediaSourceById(sourceId))!;
    expect(source.lastScannedAt, isNull);

    runner.release.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('background task panel can close and reopen without cancelling',
      (WidgetTester tester) async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final int sourceId = await _seedSource(db, mediaKind: 'video');
    final SourceLibraryRow source = (await db.getMediaSourceById(sourceId))!;
    await db.insertVideoSourceScrapeRun(
      VideoSourceScrapeRunsCompanion.insert(
        sourceId: Value<int?>(sourceId),
        scope: 'source',
        status: 'completed',
        provider: const Value<String?>('tmdb'),
        succeededWorks: const Value<int>(2),
        startedAt: 1,
        updatedAt: 2,
        finishedAt: const Value<int?>(2),
      ),
    );
    final _HoldingScrapeRunner runner = _HoldingScrapeRunner();
    final VideoSourceScrapeTaskController controller =
        VideoSourceScrapeTaskController(runner);
    addTearDown(controller.dispose);

    Future<void> openPanel(BuildContext context) =>
        showVideoSourceScrapeTaskPanel(
          context: context,
          controller: controller,
          loadRuns: () => db.getVideoSourceScrapeRuns(limit: 20),
        );

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Column(
              children: <Widget>[
                TextButton(
                  onPressed: () {
                    unawaited(controller.scrapeSource(source));
                    unawaited(openPanel(context));
                  },
                  child: const Text('Start in background'),
                ),
                TextButton(
                  onPressed: () => unawaited(openPanel(context)),
                  child: const Text('Open tasks'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Start in background'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Background tasks'), findsOneWidget);
    expect(find.textContaining('Example Show'), findsOneWidget);
    expect(find.text('Recent tasks'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('video-source-scrape-run-1')),
        findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'CLOSE'));
    await tester.pumpAndSettle();
    expect(find.text('Background tasks'), findsNothing);
    expect(controller.isRunning, isTrue);

    await tester.tap(find.text('Open tasks'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('Example Show'), findsOneWidget);
    expect(controller.isRunning, isTrue);

    runner.release.complete();
    await tester.pumpAndSettle();
    expect(controller.isRunning, isFalse);
  });

  testWidgets('book and manga rows never expose video scrape controls',
      (WidgetTester tester) async {
    for (final String kind in <String>['book', 'manga']) {
      final FushiDatabase db = _memDb();
      await _seedSource(db, mediaKind: kind, label: kind);
      await _pumpView(
        tester,
        db,
        mediaKind: kind,
        onScrapeSource: (_) async {},
      );
      expect(find.byTooltip('Scrape this source'), findsNothing);
      expect(find.byTooltip('Source scrape settings'), findsNothing);
      await db.close();
    }
  });

  testWidgets('source settings persist provider and safe output toggles',
      (WidgetTester tester) async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final int sourceId = await _seedSource(db, mediaKind: 'video');
    await _pumpView(tester, db, mediaKind: 'video');

    await tester.tap(find.byTooltip('Source scrape settings'));
    await tester.pumpAndSettle();
    expect(find.text('Use global default'), findsOneWidget);

    await tester.tap(find.text('Use global default'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bangumi').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Scrape after scanning'));
    await tester.tap(find.text('Write image files'));
    await tester.tap(find.text('SAVE'));
    await tester.pumpAndSettle();

    final VideoSourceScrapeSettingRow settings =
        (await db.getVideoSourceScrapeSettings(sourceId))!;
    expect(settings.providerOverride, 'bangumi');
    expect(settings.autoAfterScan, isTrue);
    expect(settings.writeNfo, isTrue);
    expect(settings.writeImages, isFalse);
    expect(settings.fanartEnabled, isTrue);
    expect(settings.allowExternalOverwrite, isFalse);
  });

  testWidgets('latest persisted run replaces the scan-count subtitle',
      (WidgetTester tester) async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final int sourceId = await _seedSource(db, mediaKind: 'video');
    await db.insertVideoSourceScrapeRun(
      VideoSourceScrapeRunsCompanion.insert(
        sourceId: Value<int?>(sourceId),
        scope: 'source',
        status: 'completed',
        succeededWorks: const Value<int>(2),
        failedWorks: const Value<int>(1),
        pendingConfirmations: const Value<int>(1),
        startedAt: 1,
        updatedAt: 2,
        finishedAt: const Value<int?>(2),
      ),
    );

    await _pumpView(tester, db, mediaKind: 'video');
    expect(
      find.textContaining(
        'Last scrape (Completed): 2 succeeded, 1 pending, 1 failed',
      ),
      findsOneWidget,
    );
  });
}
