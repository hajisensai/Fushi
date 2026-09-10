import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_run_detail_dialog.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart';
import 'package:fushi/utils.dart';

class _ManualBindingRunner
    implements VideoSourceScrapeRunner, VideoSourceScrapeManualBinding {
  final List<String> boundTitles = <String>[];
  final List<VideoMetadataLookup> boundLookups = <VideoMetadataLookup>[];
  final List<String> queries = <String>[];
  final List<String?> searchedKeys = <String?>[];
  List<VideoSourceScrapeConfirmationCandidate> results =
      const <VideoSourceScrapeConfirmationCandidate>[];

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

  @override
  Future<List<VideoSourceScrapeConfirmationCandidate>> searchManualCandidates({
    required SourceLibraryRow source,
    required String workTitle,
    String? workStableKey,
    required String query,
  }) async {
    queries.add(query);
    searchedKeys.add(workStableKey);
    return results;
  }

  @override
  Future<SourceScrapeReport> rescrapeWorkWithLookup({
    required SourceLibraryRow source,
    required String workTitle,
    String? workStableKey,
    required VideoMetadataLookup lookup,
    required VideoSourceScrapeCancellationToken cancellationToken,
    required VideoSourceScrapeProgressCallback onProgress,
  }) async {
    boundTitles.add(workTitle);
    boundLookups.add(lookup);
    return SourceScrapeReport(
      sourceIds: <int>[source.id],
      totalWorks: 1,
      succeededWorks: 1,
    );
  }
}

void main() {
  testWidgets('ID preview requires selection and numeric titles stay titles',
      (WidgetTester tester) async {
    const SourceLibraryRow source = SourceLibraryRow(
        id: 1,
        label: 'Anime',
        mediaKind: 'video',
        transport: 'local',
        rootPath: '/videos',
        mediaCount: 0,
        recursive: true,
        videoGroupingMode: 'series',
        sortOrder: 0,
        createdAt: 1);
    final _ManualBindingRunner runner = _ManualBindingRunner();
    final VideoSourceScrapeTaskController controller =
        VideoSourceScrapeTaskController(runner);
    addTearDown(controller.dispose);
    VideoSourceScrapeConfirmationCandidate? selected;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (BuildContext context) => Scaffold(
                body: TextButton(
                    onPressed: () async {
                      selected = await showVideoSourceScrapeManualBindingDialog(
                          context: context,
                          controller: controller,
                          source: source,
                          workTitle: '86',
                          workStableKey: 'book:chosen');
                    },
                    child: const Text('Open'))))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final Finder search =
        find.byKey(const ValueKey<String>('video-source-manual-search'));
    final Finder query =
        find.byKey(const ValueKey<String>('video-source-manual-query'));
    await tester.tap(search);
    await tester.pumpAndSettle();
    expect(runner.queries, <String>['86']);
    expect(runner.searchedKeys, everyElement('book:chosen'));
    await tester.tap(find.text(t.video_source_scrape_manual_by_id).first);
    await tester.pumpAndSettle();
    await tester.enterText(query, '0');
    await tester.tap(search);
    await tester.pumpAndSettle();
    expect(find.text(t.video_source_scrape_manual_id_invalid), findsOneWidget);
    expect(runner.queries, <String>['86']);
    expect(runner.searchedKeys, everyElement('book:chosen'));
    runner.results = <VideoSourceScrapeConfirmationCandidate>[
      VideoSourceScrapeConfirmationCandidate(
          lookup: const VideoMetadataLookup(
              provider: VideoMetadataProviderKind.mal,
              externalId: '42',
              mediaKind: VideoMetadataMediaKind.tv),
          work: VideoMetadataWork(
              provider: VideoMetadataProviderKind.mal,
              kind: VideoMetadataMediaKind.tv,
              title: 'Confirmed work')),
    ];
    await tester.enterText(query, '42');
    await tester.tap(search);
    await tester.pumpAndSettle();
    expect(runner.queries.last, 'mal=42');
    expect(selected, isNull);
    expect(runner.boundLookups, isEmpty);
    expect(find.text('MAL · 42'), findsOneWidget);
    await tester.tap(
        find.byKey(const ValueKey<String>('video-source-candidate-mal-tv-42')));
    await tester.pumpAndSettle();
    expect(selected?.lookup.externalId, '42');
  });
}
