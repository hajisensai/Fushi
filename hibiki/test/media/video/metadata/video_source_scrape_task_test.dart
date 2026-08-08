import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/source_library/source_library_row.dart';
import 'package:hibiki/src/media/video/metadata/video_metadata_models.dart';
import 'package:hibiki/src/media/video/metadata/video_metadata_provider.dart';
import 'package:hibiki/src/media/video/metadata/video_source_scrape_task.dart';

void main() {
  SourceLibraryRow source(int id) => SourceLibraryRow(
        id: id,
        label: 'source-$id',
        mediaKind: 'video',
        transport: 'local',
        rootPath: 'D:/source-$id',
        recursive: true,
        configJson: null,
        mediaCount: 0,
        lastScannedAt: null,
        lastScanError: null,
        sortOrder: 0,
        createdAt: 1,
      );

  test('全部来源共用单批次锁，重复入口返回同一个任务', () async {
    final _BlockingRunner runner = _BlockingRunner();
    final VideoSourceScrapeTaskController controller =
        VideoSourceScrapeTaskController(runner);

    final Future<SourceScrapeReport> first =
        controller.scrapeAllSources(<SourceLibraryRow>[source(1), source(2)]);
    final Future<SourceScrapeReport> duplicate =
        controller.scrapeSource(source(9));
    expect(identical(first, duplicate), isTrue);
    expect(controller.isRunning, isTrue);

    runner.release();
    final SourceScrapeReport report = await first;
    expect(report.sourceIds, <int>[1, 2]);
    expect(runner.calls, <int>[1, 2]);
    expect(controller.progress.phase, VideoSourceScrapePhase.completed);
    expect(controller.isRunning, isFalse);
  });

  test('取消在作品边界生效并返回 cancelled 摘要', () async {
    final _BlockingRunner runner = _BlockingRunner();
    final VideoSourceScrapeTaskController controller =
        VideoSourceScrapeTaskController(runner);
    final Future<SourceScrapeReport> future =
        controller.scrapeSource(source(1));
    controller.cancel();
    runner.release();
    final SourceScrapeReport report = await future;
    expect(report.cancelled, isTrue);
    expect(controller.progress.phase, VideoSourceScrapePhase.cancelled);
  });

  test('来源扫描与联网刮削双向互斥', () async {
    final _BlockingRunner runner = _BlockingRunner();
    final VideoSourceScrapeTaskController controller =
        VideoSourceScrapeTaskController(runner);
    final Completer<void> scanGate = Completer<void>();

    final Future<void> scan = controller.runSourceScan<void>(
      1,
      () => scanGate.future,
    );
    expect(controller.isScanning, isTrue);
    expect(controller.scanningSourceId, 1);
    await expectLater(
      controller.scrapeSource(source(1)),
      throwsA(isA<StateError>()),
    );
    scanGate.complete();
    await scan;

    final Future<SourceScrapeReport> scrape =
        controller.scrapeSource(source(1));
    expect(controller.isRunning, isTrue);
    await expectLater(
      controller.runSourceScan<void>(2, () async {}),
      throwsA(isA<StateError>()),
    );
    runner.release();
    await scrape;
    expect(controller.isBusy, isFalse);
  });

  test('全部来源向每次来源刮削传递同一个批次上下文', () async {
    final _BlockingRunner runner = _BlockingRunner();
    final VideoSourceScrapeTaskController controller =
        VideoSourceScrapeTaskController(runner);

    final Future<SourceScrapeReport> future =
        controller.scrapeAllSources(<SourceLibraryRow>[
      source(1),
      source(2),
      source(3),
    ]);
    runner.release();
    await future;

    expect(runner.batchContexts, hasLength(3));
    expect(runner.batchContexts, everyElement(isNotNull));
    expect(
      runner.batchContexts.skip(1),
      everyElement(same(runner.batchContexts.first)),
    );
  });

  test('interactive 歧义确认会挂起任务，确认候选后继续完成', () async {
    final _ConfirmationRunner runner = _ConfirmationRunner();
    final VideoSourceScrapeTaskController controller =
        VideoSourceScrapeTaskController(runner);

    final Future<SourceScrapeReport> future = controller.scrapeSource(
      source(1),
      interactive: true,
    );
    expect(controller.isRunning, isTrue);
    expect(controller.pendingConfirmation, same(runner.confirmation));
    expect(controller.progress.confirmation, same(runner.confirmation));
    bool completed = false;
    future.whenComplete(() => completed = true);
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);

    controller.confirmPending(runner.candidate);
    final SourceScrapeReport report = await future;

    expect(runner.selected, same(runner.candidate));
    expect(report.succeededWorks, 1);
    expect(controller.pendingConfirmation, isNull);
    expect(controller.progress.phase, VideoSourceScrapePhase.completed);
  });
}

class _BlockingRunner implements VideoSourceScrapeRunner {
  final Completer<void> _gate = Completer<void>();
  final List<int> calls = <int>[];
  final List<VideoSourceScrapeBatchContext?> batchContexts =
      <VideoSourceScrapeBatchContext?>[];

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<SourceScrapeReport> scrapeSource(
    SourceLibraryRow source, {
    required VideoSourceScrapeCancellationToken cancellationToken,
    required VideoSourceScrapeProgressCallback onProgress,
    VideoSourceScrapeConfirmationCallback? onConfirmation,
    VideoSourceScrapeBatchContext? batchContext,
  }) async {
    calls.add(source.id);
    batchContexts.add(batchContext);
    await _gate.future;
    cancellationToken.throwIfCancelled();
    onProgress(VideoSourceScrapeProgress(
      phase: VideoSourceScrapePhase.applying,
      sourceId: source.id,
    ));
    return SourceScrapeReport(
      sourceIds: <int>[source.id],
      totalWorks: 1,
      succeededWorks: 1,
    );
  }
}

class _ConfirmationRunner implements VideoSourceScrapeRunner {
  _ConfirmationRunner()
      : candidate = VideoSourceScrapeConfirmationCandidate(
          lookup: const VideoMetadataLookup(
            provider: VideoMetadataProviderKind.tmdb,
            externalId: '42',
            mediaKind: VideoMetadataMediaKind.movie,
          ),
          work: VideoMetadataWork(
            provider: VideoMetadataProviderKind.tmdb,
            kind: VideoMetadataMediaKind.movie,
            title: 'Confirmed movie',
            ids: const <VideoMetadataId>[
              VideoMetadataId(type: 'tmdb', value: '42'),
            ],
          ),
        );

  final VideoSourceScrapeConfirmationCandidate candidate;
  VideoSourceScrapeConfirmationCandidate? selected;
  late VideoSourceScrapeConfirmation confirmation;

  @override
  Future<SourceScrapeReport> scrapeSource(
    SourceLibraryRow source, {
    required VideoSourceScrapeCancellationToken cancellationToken,
    required VideoSourceScrapeProgressCallback onProgress,
    VideoSourceScrapeConfirmationCallback? onConfirmation,
    VideoSourceScrapeBatchContext? batchContext,
  }) async {
    confirmation = VideoSourceScrapeConfirmation(
      sourceId: source.id,
      sourceLabel: source.label,
      localWorkTitle: 'Ambiguous movie',
      candidates: <VideoSourceScrapeConfirmationCandidate>[candidate],
    );
    selected = await onConfirmation!(confirmation);
    cancellationToken.throwIfCancelled();
    return SourceScrapeReport(
      sourceIds: <int>[source.id],
      totalWorks: 1,
      succeededWorks: selected == null ? 0 : 1,
      pendingConfirmations: selected == null ? 1 : 0,
    );
  }
}
