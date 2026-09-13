import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart'
    show VideoSourceScrapeWork;

void main() {
  SourceLibraryRow source(int id) => SourceLibraryRow(
        id: id,
        label: 'source-$id',
        mediaKind: 'video',
        transport: 'local',
        rootPath: 'D:/source-$id',
        recursive: true,
        videoGroupingMode: 'series',
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

  test('后台任务首次通知时已进入 busy，任务入口可立即显示', () async {
    final _BlockingRunner runner = _BlockingRunner();
    final VideoSourceScrapeTaskController controller =
        VideoSourceScrapeTaskController(runner);
    final List<bool> busySnapshots = <bool>[];
    controller.addListener(() => busySnapshots.add(controller.isBusy));

    final Future<SourceScrapeReport> future =
        controller.scrapeSource(source(1));
    expect(busySnapshots, isNotEmpty);
    expect(busySnapshots.first, isTrue);

    runner.release();
    await future;
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

  // ── 手动指定作品的排队语义（早先第二条请求直接被拒，UI 只好把整屏按钮灰掉）──

  test('same titles retain separate stable identities through the queue',
      () async {
    final _ManualRunner runner = _ManualRunner();
    final VideoSourceScrapeTaskController controller =
        VideoSourceScrapeTaskController(runner);
    addTearDown(controller.dispose);
    final Future<SourceScrapeReport> first = controller.rescrapeWorkWithLookup(
      source: source(1),
      workTitle: 'same',
      workStableKey: 'book:a',
      lookup: _lookup('1'),
    );
    expect(
        controller.isManualRequestPending(
            sourceId: 1, workTitle: 'same', workStableKey: 'book:b'),
        isFalse);
    final Future<SourceScrapeReport> second = controller.rescrapeWorkWithLookup(
      source: source(1),
      workTitle: 'same',
      workStableKey: 'book:b',
      lookup: _lookup('2'),
    );
    expect(controller.queuedManualRequests.single.workStableKey, 'book:b');
    runner.release('same');
    await first;
    await second;
    expect(runner.stableKeys, <String?>['book:a', 'book:b']);
  });

  test('连续提交的手动重刮按提交顺序串行执行，不再拒绝第二条', () async {
    final _ManualRunner runner = _ManualRunner();
    final VideoSourceScrapeTaskController controller =
        VideoSourceScrapeTaskController(runner);

    final Future<SourceScrapeReport> first = controller.rescrapeWorkWithLookup(
      source: source(1),
      workTitle: 'work-a',
      lookup: _lookup('1'),
    );
    final Future<SourceScrapeReport> second = controller.rescrapeWorkWithLookup(
      source: source(1),
      workTitle: 'work-b',
      lookup: _lookup('2'),
    );
    final Future<SourceScrapeReport> third = controller.rescrapeWorkWithLookup(
      source: source(1),
      workTitle: 'work-c',
      lookup: _lookup('3'),
    );

    // 第一条立刻占门，其余两条排队——而不是像以前那样抛 StateError。
    await pumpEventQueue();
    expect(runner.started, <String>['work-a']);
    expect(controller.queuedManualRequestCount, 2);
    expect(controller.activeManualRequest?.workTitle, 'work-a');
    expect(
      controller.isManualRequestPending(sourceId: 1, workTitle: 'work-c'),
      isTrue,
    );
    expect(
      controller.isManualRequestPending(sourceId: 1, workTitle: 'work-z'),
      isFalse,
    );
    expect(
      controller.isManualRequestPending(sourceId: 2, workTitle: 'work-c'),
      isFalse,
      reason: '队列身份含来源 id，不同来源的同名作品不能互相冒认',
    );

    runner.release('work-a');
    expect(await first, isA<SourceScrapeReport>());
    await pumpEventQueue();
    expect(runner.started, <String>['work-a', 'work-b']);
    expect(controller.queuedManualRequestCount, 1);

    runner.release('work-b');
    await second;
    await pumpEventQueue();
    expect(runner.started, <String>['work-a', 'work-b', 'work-c']);

    runner.release('work-c');
    await third;
    expect(controller.isBusy, isFalse);
    expect(controller.queuedManualRequestCount, 0);
    expect(controller.activeManualRequest, isNull);
  });

  test('每条手动重刮的 Future 拿到的是它自己那一条的报告', () async {
    final _ManualRunner runner = _ManualRunner();
    final VideoSourceScrapeTaskController controller =
        VideoSourceScrapeTaskController(runner);

    final Future<SourceScrapeReport> first = controller.rescrapeWorkWithLookup(
      source: source(1),
      workTitle: 'work-a',
      lookup: _lookup('1'),
    );
    final Future<SourceScrapeReport> second = controller.rescrapeWorkWithLookup(
      source: source(2),
      workTitle: 'work-b',
      lookup: _lookup('2'),
    );

    await pumpEventQueue();
    runner.release('work-a');
    runner.release('work-b');

    expect((await first).sourceIds, <int>[1]);
    expect((await second).sourceIds, <int>[2]);
  });

  test('批次占门期间提交的手动重刮排队，批次结束后自动接棒', () async {
    final _ManualRunner runner = _ManualRunner();
    final VideoSourceScrapeTaskController controller =
        VideoSourceScrapeTaskController(runner);

    final Future<SourceScrapeReport> batch = controller.scrapeSource(source(1));
    expect(controller.isRunning, isTrue);

    final Future<SourceScrapeReport> manual = controller.rescrapeWorkWithLookup(
      source: source(1),
      workTitle: 'work-a',
      lookup: _lookup('1'),
    );
    await pumpEventQueue();
    expect(runner.started, isEmpty, reason: '批次还占着门，手动请求必须等');
    expect(controller.queuedManualRequestCount, 1);

    runner.releaseBatch();
    await batch;
    await pumpEventQueue();
    expect(
      runner.started,
      <String>['work-a'],
      reason: '门一空就接棒，不该等到下一次用户交互',
    );

    runner.release('work-a');
    await manual;
    expect(controller.isBusy, isFalse);
  });

  test('取消会作废还没开始的手动重刮，而不是让它们随后自己跑起来', () async {
    final _ManualRunner runner = _ManualRunner();
    final VideoSourceScrapeTaskController controller =
        VideoSourceScrapeTaskController(runner);

    final Future<SourceScrapeReport> first = controller.rescrapeWorkWithLookup(
      source: source(1),
      workTitle: 'work-a',
      lookup: _lookup('1'),
    );
    final Future<SourceScrapeReport> queued = controller.rescrapeWorkWithLookup(
      source: source(1),
      workTitle: 'work-b',
      lookup: _lookup('2'),
    );
    await pumpEventQueue();
    expect(controller.queuedManualRequestCount, 1);

    controller.cancel();
    await expectLater(queued, throwsA(isA<VideoSourceScrapeCancelled>()));
    expect(controller.queuedManualRequestCount, 0);

    runner.release('work-a');
    await first.then<void>((_) {}, onError: (_, __) {});
    await pumpEventQueue();
    expect(
      runner.started,
      <String>['work-a'],
      reason: '被取消的那条永远不该开跑',
    );
  });

  test('控制器释放时挂着的手动重刮以错误结束，不会永远等下去', () async {
    final _ManualRunner runner = _ManualRunner();
    final VideoSourceScrapeTaskController controller =
        VideoSourceScrapeTaskController(runner);

    unawaited(controller
        .rescrapeWorkWithLookup(
          source: source(1),
          workTitle: 'work-a',
          lookup: _lookup('1'),
        )
        .then<void>((_) {}, onError: (_, __) {}));
    final Future<SourceScrapeReport> queued = controller.rescrapeWorkWithLookup(
      source: source(1),
      workTitle: 'work-b',
      lookup: _lookup('2'),
    );
    await pumpEventQueue();

    controller.dispose();
    await expectLater(queued, throwsA(isA<StateError>()));
  });

  test('撤回中间的排队请求保留当前与后续任务', () async {
    final _ManualRunner runner = _ManualRunner();
    final VideoSourceScrapeTaskController controller =
        VideoSourceScrapeTaskController(runner);
    addTearDown(controller.dispose);
    final Future<SourceScrapeReport> first = controller.rescrapeWorkWithLookup(
      source: source(1),
      workTitle: 'first',
      lookup: _lookup('1'),
    );
    final Future<SourceScrapeReport> removed =
        controller.rescrapeWorkWithLookup(
      source: source(1),
      workTitle: 'removed',
      lookup: _lookup('2'),
    );
    final Future<SourceScrapeReport> last = controller.rescrapeWorkWithLookup(
      source: source(1),
      workTitle: 'last',
      lookup: _lookup('3'),
    );
    final Future<void> cancelled = expectLater(
      removed,
      throwsA(isA<VideoSourceScrapeCancelled>()),
    );
    final VideoSourceScrapeManualRequest request =
        controller.queuedManualRequests.first;
    expect(controller.cancelQueuedManualRequest(request), isTrue);
    await cancelled;
    expect(controller.cancelQueuedManualRequest(request), isFalse);
    expect(controller.queuedManualRequests.single.workTitle, 'last');
    expect(
        controller.cancelQueuedManualRequest(controller.activeManualRequest!),
        isFalse);
    runner.release('first');
    await first;
    await pumpEventQueue();
    expect(runner.started, <String>['first', 'last']);
    runner.release('last');
    await last;
    expect(controller.queuedManualRequests, isEmpty);
  });

  test('取消正在执行的手动任务发布 cancelled 而不是 failed', () async {
    final _ManualRunner runner = _ManualRunner();
    final VideoSourceScrapeTaskController controller =
        VideoSourceScrapeTaskController(runner);
    addTearDown(controller.dispose);
    final Future<SourceScrapeReport> active = controller.rescrapeWorkWithLookup(
      source: source(1),
      workTitle: 'active',
      lookup: _lookup('1'),
    );
    controller.cancel();
    runner.release('active');
    expect((await active).cancelled, isTrue);
    expect(controller.progress.phase, VideoSourceScrapePhase.cancelled);
    expect(controller.isBusy, isFalse);
  });

  test('runner 不支持手动绑定时立即报错，不进队列', () async {
    final _BlockingRunner runner = _BlockingRunner();
    final VideoSourceScrapeTaskController controller =
        VideoSourceScrapeTaskController(runner);

    await expectLater(
      controller.rescrapeWorkWithLookup(
        source: source(1),
        workTitle: 'work-a',
        lookup: _lookup('1'),
      ),
      throwsA(isA<StateError>()),
    );
    expect(controller.queuedManualRequestCount, 0);
    expect(controller.isBusy, isFalse);
  });
}

VideoMetadataLookup _lookup(String externalId) => VideoMetadataLookup(
      provider: VideoMetadataProviderKind.anidb,
      externalId: externalId,
      mediaKind: VideoMetadataMediaKind.tv,
    );

/// 既是批次 runner 又支持手动绑定：手动重刮按 workTitle 单独开闸，
/// 这样测试能精确观察「谁开跑了、谁还在队列里」。
class _ManualRunner
    implements VideoSourceScrapeRunner, VideoSourceScrapeManualBinding {
  final List<String> started = <String>[];
  final List<String?> stableKeys = <String?>[];
  final Map<String, Completer<void>> _gates = <String, Completer<void>>{};
  final Completer<void> _batchGate = Completer<void>();

  void release(String workTitle) {
    final Completer<void> gate =
        _gates.putIfAbsent(workTitle, Completer<void>.new);
    if (!gate.isCompleted) gate.complete();
  }

  void releaseBatch() {
    if (!_batchGate.isCompleted) _batchGate.complete();
  }

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
    await _batchGate.future;
    cancellationToken.throwIfCancelled();
    return SourceScrapeReport(
      sourceIds: <int>[source.id],
      totalWorks: 1,
      succeededWorks: 1,
    );
  }

  @override
  Future<List<VideoSourceScrapeConfirmationCandidate>> searchManualCandidates({
    SourceLibraryRow? source,
    required String workTitle,
    String? workStableKey,
    required String query,
  }) async =>
      const <VideoSourceScrapeConfirmationCandidate>[];

  @override
  Future<VideoMetadataWork?> fetchWorkForLookup(VideoMetadataLookup lookup) =>
      Future<VideoMetadataWork?>.value(null);

  @override
  Future<SourceScrapeReport> rescrapeWorkWithLookup({
    required SourceLibraryRow source,
    required String workTitle,
    String? workStableKey,
    required VideoMetadataLookup lookup,
    required VideoSourceScrapeCancellationToken cancellationToken,
    required VideoSourceScrapeProgressCallback onProgress,
  }) async {
    started.add(workTitle);
    stableKeys.add(workStableKey);
    await _gates.putIfAbsent(workTitle, Completer<void>.new).future;
    cancellationToken.throwIfCancelled();
    return SourceScrapeReport(
      sourceIds: <int>[source.id],
      totalWorks: 1,
      succeededWorks: 1,
    );
  }
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
    List<VideoSourceScrapeWork>? plannedWorks,
    String runScope = 'source',
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
    List<VideoSourceScrapeWork>? plannedWorks,
    String runScope = 'source',
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
