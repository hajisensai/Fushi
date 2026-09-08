import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/video_library_scrape_sweep.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_dialog.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart';
import 'package:fushi_core/fushi_core.dart';

const SourceLibraryRow _source = SourceLibraryRow(
  id: 1,
  label: 'Anime',
  mediaKind: 'video',
  transport: 'local',
  rootPath: '/videos',
  recursive: true,
  videoGroupingMode: 'series',
  mediaCount: 1500,
  sortOrder: 0,
  createdAt: 1,
);

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

VideoPendingScrapeWork _pending(int index) => VideoPendingScrapeWork(
      source: _source,
      work: VideoSourceScrapeWork(
        source: _source,
        title: 'Unmatched video $index',
        members: <VideoBookRow>[
          VideoBookRow(
            bookUid: 'video-$index',
            title: 'Unmatched video $index',
            videoPath: '/videos/video-$index.mkv',
            lastPositionMs: 0,
            currentEpisode: 0,
            delayMs: 0,
          ),
        ],
      ),
    );

Future<void> _open(
  WidgetTester tester,
  VideoSourceScrapeTaskController controller,
  Future<List<VideoPendingScrapeWork>> Function() load,
) async {
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(
      useMaterial3: true,
      fontFamily: const bool.fromEnvironment('CAPTURE_WORKFLOW_UI')
          ? 'WorkflowTest'
          : null,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff426957)),
    ),
    home: Builder(
        builder: (BuildContext context) => Scaffold(
              body: TextButton(
                onPressed: () => unawaited(showVideoSourceScrapeTaskPanel(
                  context: context,
                  controller: controller,
                  loadRuns: () async => const <VideoSourceScrapeRunRow>[],
                  loadPendingWorks: load,
                )),
                child: const Text('Open tasks'),
              ),
            )),
  ));
  await tester.tap(find.text('Open tasks'));
  await tester.pumpAndSettle();
  await tester
      .tap(find.byKey(const ValueKey<String>('video-source-tab-pending')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('1500 pending works are lazy and accessible at a narrow viewport',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    if (const bool.fromEnvironment('CAPTURE_WORKFLOW_UI')) {
      final Uint8List bytes =
          File('C:/Windows/Fonts/segoeui.ttf').readAsBytesSync();
      await (FontLoader('WorkflowTest')
            ..addFont(Future<ByteData>.value(
              ByteData.sublistView(bytes),
            )))
          .load();
      final Uint8List icons = File(
        'build/unit_test_assets/fonts/MaterialIcons-Regular.otf',
      ).readAsBytesSync();
      await (FontLoader('MaterialIcons')
            ..addFont(Future<ByteData>.value(
              ByteData.sublistView(icons),
            )))
          .load();
    }
    final VideoSourceScrapeTaskController controller =
        VideoSourceScrapeTaskController(_IdleRunner());
    addTearDown(controller.dispose);
    await _open(tester, controller,
        () async => List<VideoPendingScrapeWork>.generate(1500, _pending));
    expect(tester.takeException(), isNull);
    expect(find.text('Unmatched video 0'), findsOneWidget);
    expect(find.text('Unmatched video 1499'), findsNothing);
    final Finder list =
        find.byKey(const PageStorageKey<String>('video-source-pending-list'));
    final ScrollableState scrollable = tester.state<ScrollableState>(
        find.descendant(of: list, matching: find.byType(Scrollable)).first);
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    await tester.pumpAndSettle();
    // The extent estimate settles after the last lazily built rows are measured.
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.text('Unmatched video 1499'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('CAPTURE_WORKFLOW_UI')) {
      scrollable.position.jumpTo(0);
      await tester.pumpAndSettle();
      await expectLater(find.byType(AlertDialog),
          matchesGoldenFile('../../.codex-test/video-task-center-narrow.png'));
      await tester.binding.setSurfaceSize(const Size(1100, 800));
      await tester.pumpAndSettle();
      await expectLater(find.byType(AlertDialog),
          matchesGoldenFile('../../.codex-test/video-task-center-wide.png'));
    }
  });

  testWidgets('a pending-list failure offers an actual reload',
      (WidgetTester tester) async {
    final VideoSourceScrapeTaskController controller =
        VideoSourceScrapeTaskController(_IdleRunner());
    addTearDown(controller.dispose);
    int calls = 0;
    await _open(tester, controller, () async {
      if (++calls == 1) throw StateError('offline');
      return <VideoPendingScrapeWork>[_pending(7)];
    });
    expect(find.text('Could not load this list. Try again.'), findsOneWidget);
    await tester.tap(find.text('Reload'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('Unmatched video 7'), findsOneWidget);
    expect(find.text('Could not load this list. Try again.'), findsNothing);
  });

  testWidgets('a slower prior refresh cannot restore stale pending works',
      (WidgetTester tester) async {
    final VideoSourceScrapeTaskController controller =
        VideoSourceScrapeTaskController(_IdleRunner());
    addTearDown(controller.dispose);
    final Completer<List<VideoPendingScrapeWork>> older =
        Completer<List<VideoPendingScrapeWork>>();
    int calls = 0;
    await _open(tester, controller, () {
      if (++calls == 2) return older.future;
      return Future<List<VideoPendingScrapeWork>>.value(
        <VideoPendingScrapeWork>[_pending(calls == 1 ? 1 : 7)],
      );
    });
    await controller.scrapeSource(_source);
    await tester.pump();
    await controller.scrapeSource(_source);
    await tester.pumpAndSettle();
    expect(find.text('Unmatched video 7'), findsOneWidget);
    older.complete(<VideoPendingScrapeWork>[_pending(9)]);
    await tester.pumpAndSettle();
    expect(find.text('Unmatched video 7'), findsOneWidget);
    expect(find.text('Unmatched video 9'), findsNothing);
  });
}
