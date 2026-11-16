import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/source_library/source_auto_scan.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart'
    show SourceScanSummary;
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart'
    show VideoSourceScrapeWork;

/// 来源「自动扫描」调度（拍板台 C_8oheua0H / ICOLa6LZLU / enSm2GOuFA）：每源开关、
/// 启动 / 回前台触发、串行限流 + 节流 + 去重，与手动「重新扫描」共用一条道。
SourceLibraryRow _row(
  int id, {
  String kind = 'book',
  DateTime? lastScannedAt,
}) => SourceLibraryRow(
  id: id,
  label: 'source $id',
  mediaKind: kind,
  transport: 'local',
  rootPath: '/media/$id',
  mediaCount: 0,
  lastScannedAt: lastScannedAt,
  recursive: true,
  videoGroupingMode: 'series',
  isPrivate: false,
  autoScan: true,
  sortOrder: id,
  createdAt: 0,
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
  }) async => SourceScrapeReport(sourceIds: <int>[source.id]);
}

void main() {
  late DateTime now;
  late List<SourceLibraryRow> candidates;
  late List<int> scanned;
  late SourceScanActivity activity;

  setUp(() {
    now = DateTime(2026, 11, 16, 12);
    candidates = <SourceLibraryRow>[];
    scanned = <int>[];
    activity = SourceScanActivity();
  });

  SourceAutoScanScheduler scheduler({
    Future<SourceAutoScanOutcome> Function(SourceLibraryRow row)? scan,
  }) => SourceAutoScanScheduler(
    loadCandidates: () async => List<SourceLibraryRow>.of(candidates),
    scan:
        scan ??
        (SourceLibraryRow row) async {
          expect(activity.activeSourceIds, <int>{
            row.id,
          }, reason: '扫描期间登记在占用表里，且同一时刻只有它一个');
          scanned.add(row.id);
          return SourceAutoScanOutcome.scanned;
        },
    activity: activity,
    now: () => now,
  );

  test('scans every due source once, serially, in source order', () async {
    candidates = <SourceLibraryRow>[
      _row(1),
      _row(
        2,
        kind: 'video',
        lastScannedAt: now.subtract(kSourceAutoScanMinInterval),
      ),
      _row(3, kind: 'music'),
    ];
    await scheduler().trigger(SourceAutoScanTrigger.startup);
    expect(scanned, <int>[1, 2, 3]);
    expect(activity.isIdle, isTrue);
  });

  test(
    'throttles: recently scanned sources are skipped until the interval passes',
    () async {
      candidates = <SourceLibraryRow>[
        _row(1, lastScannedAt: now.subtract(const Duration(minutes: 3))),
        _row(2),
      ];
      final SourceAutoScanScheduler s = scheduler();
      await s.trigger(SourceAutoScanTrigger.startup);
      expect(scanned, <int>[2], reason: '来源 1 三分钟前刚扫过（手动扫的也算）');

      // 桌面切窗口引起的高频 resumed：间隔内再触发什么都不扫（来源 2 记了尝试时刻，
      // 哪怕 lastScannedAt 没变）。
      now = now.add(const Duration(minutes: 1));
      await s.trigger(SourceAutoScanTrigger.resume);
      expect(scanned, <int>[2]);

      now = now.add(kSourceAutoScanMinInterval);
      await s.trigger(SourceAutoScanTrigger.resume);
      expect(scanned, <int>[2, 1, 2]);
    },
  );

  test('waits for a manual rescan holding the lane, then runs', () async {
    candidates = <SourceLibraryRow>[_row(1), _row(2)];
    final Completer<void> manual = Completer<void>();
    final Future<void> manualScan = activity.run(2, () => manual.future);

    final Future<void> auto = scheduler().trigger(SourceAutoScanTrigger.resume);
    await pumpEventQueue();
    expect(scanned, isEmpty, reason: '手动扫描占着道时自动扫描排队，不并发');

    manual.complete();
    await manualScan;
    await auto;
    expect(scanned, <int>[1], reason: '来源 2 入队时正在被手动扫，不重复入队');
  });

  test(
    'a source switched off (or removed) while queued is not scanned',
    () async {
      candidates = <SourceLibraryRow>[_row(1), _row(2)];
      final SourceAutoScanScheduler s = scheduler(
        scan: (SourceLibraryRow row) async {
          scanned.add(row.id);
          // 扫第一个的时候用户把第二个的开关关掉了。
          candidates.removeWhere((SourceLibraryRow r) => r.id == 2);
          return SourceAutoScanOutcome.scanned;
        },
      );
      await s.trigger(SourceAutoScanTrigger.startup);
      expect(scanned, <int>[1]);
    },
  );

  test('overlapping triggers do not enqueue a source twice', () async {
    candidates = <SourceLibraryRow>[_row(1), _row(2)];
    final Completer<void> gate = Completer<void>();
    final SourceAutoScanScheduler s = scheduler(
      scan: (SourceLibraryRow row) async {
        scanned.add(row.id);
        await gate.future;
        return SourceAutoScanOutcome.scanned;
      },
    );
    final Future<void> first = s.trigger(SourceAutoScanTrigger.startup);
    await pumpEventQueue();
    final Future<void> second = s.trigger(SourceAutoScanTrigger.resume);
    await pumpEventQueue();
    expect(s.queuedSourceIds, <int>[2]);
    gate.complete();
    await Future.wait(<Future<void>>[first, second]);
    expect(scanned, <int>[1, 2]);
  });

  test('a trigger landing while a dequeued source is being re-fetched does '
      'not enqueue it again', () async {
    // 出队后、开扫前那一下 await 重取候选的窗口：它既不在队列也还没进占用表。
    candidates = <SourceLibraryRow>[_row(1)];
    int loads = 0;
    final Completer<void> refetch = Completer<void>();
    final SourceAutoScanScheduler s = SourceAutoScanScheduler(
      loadCandidates: () async {
        loads++;
        if (loads == 2) await refetch.future; // drain 里出队后的那次重取
        return List<SourceLibraryRow>.of(candidates);
      },
      scan: (SourceLibraryRow row) async {
        scanned.add(row.id);
        return SourceAutoScanOutcome.scanned;
      },
      activity: activity,
      now: () => now,
    );
    final Future<void> first = s.trigger(SourceAutoScanTrigger.startup);
    await pumpEventQueue();
    expect(loads, 2, reason: '已出队，卡在重取');
    final Future<void> second = s.trigger(SourceAutoScanTrigger.resume);
    await pumpEventQueue();
    expect(s.queuedSourceIds, isEmpty, reason: '在途来源不再入队');
    refetch.complete();
    await Future.wait(<Future<void>>[first, second]);
    expect(scanned, <int>[1], reason: '不连扫两遍');
  });

  test(
    'a source manually scanned while queued is re-checked and skipped',
    () async {
      candidates = <SourceLibraryRow>[_row(1)];
      final Completer<void> manual = Completer<void>();
      // 别的来源（3）的手动扫描占着道，来源 1 排在后面。
      final Future<void> manualScan = activity.run(3, () => manual.future);
      final Future<void> auto = scheduler().trigger(
        SourceAutoScanTrigger.resume,
      );
      await pumpEventQueue();
      expect(scanned, isEmpty);
      // 排队期间用户把来源 1 也手动扫了一遍：lastScannedAt 刚更新。
      candidates = <SourceLibraryRow>[_row(1, lastScannedAt: now)];
      manual.complete();
      await manualScan;
      await auto;
      expect(scanned, isEmpty, reason: '开扫前按最新 lastScannedAt 重判到期');
    },
  );

  test('a deferred scan does not consume the throttle', () async {
    candidates = <SourceLibraryRow>[_row(1, kind: 'video')];
    SourceAutoScanOutcome next = SourceAutoScanOutcome.deferred;
    final SourceAutoScanScheduler s = scheduler(
      scan: (SourceLibraryRow row) async {
        scanned.add(row.id);
        return next;
      },
    );
    await s.trigger(SourceAutoScanTrigger.startup);
    next = SourceAutoScanOutcome.scanned;
    now = now.add(const Duration(minutes: 1));
    await s.trigger(SourceAutoScanTrigger.resume);
    expect(scanned, <int>[1, 1], reason: '上次被刮削门挡回，下一次触发立即重试');
    now = now.add(const Duration(minutes: 1));
    await s.trigger(SourceAutoScanTrigger.resume);
    expect(scanned, <int>[1, 1], reason: '这次真扫了，节流生效');
  });

  test(
    'an unexpected scan error is reported and does not stall the queue',
    () async {
      candidates = <SourceLibraryRow>[_row(1), _row(2)];
      final List<FlutterErrorDetails> reported = <FlutterErrorDetails>[];
      final FlutterExceptionHandler? previous = FlutterError.onError;
      FlutterError.onError = reported.add;
      addTearDown(() => FlutterError.onError = previous);
      await scheduler(
        scan: (SourceLibraryRow row) async {
          scanned.add(row.id);
          if (row.id == 1) throw StateError('boom');
          return SourceAutoScanOutcome.scanned;
        },
      ).trigger(SourceAutoScanTrigger.startup);
      expect(scanned, <int>[1, 2]);
      expect(reported, hasLength(1));
      expect(activity.isIdle, isTrue);
    },
  );

  test('dispose drops queued sources', () async {
    candidates = <SourceLibraryRow>[_row(1), _row(2)];
    late SourceAutoScanScheduler s;
    s = scheduler(
      scan: (SourceLibraryRow row) async {
        scanned.add(row.id);
        s.dispose();
        return SourceAutoScanOutcome.scanned;
      },
    );
    await s.trigger(SourceAutoScanTrigger.startup);
    expect(scanned, <int>[1]);
    await s.trigger(SourceAutoScanTrigger.resume);
    expect(scanned, <int>[1]);
  });

  test(
    'every source library kind maps to a module (all media support auto scan)',
    () {
      for (final SourceLibraryKind kind in SourceLibraryKind.values) {
        expect(
          sourceLibraryKindModule(kind.dbValue),
          isA<ModuleId>(),
          reason: '${kind.dbValue} 来源也要能自动扫描',
        );
      }
      expect(sourceLibraryKindModule('nope'), isNull);
    },
  );

  group('SourceScanActivity per-source lock', () {
    test(
      'two entry points scanning the same source run one after another',
      () async {
        final List<String> log = <String>[];
        final Completer<void> firstHold = Completer<void>();
        final Future<void> first = activity.run(1, () async {
          log.add('first start');
          await firstHold.future;
          log.add('first end');
        });
        final Future<void> second = activity.run(1, () async {
          log.add('second start');
        });
        await pumpEventQueue();
        expect(log, <String>['first start'], reason: '后到的等前一个扫完');
        firstHold.complete();
        await Future.wait(<Future<void>>[first, second]);
        expect(log, <String>['first start', 'first end', 'second start']);
        expect(activity.isIdle, isTrue);
      },
    );

    test('different sources do not block each other', () async {
      final Completer<void> hold = Completer<void>();
      final Future<void> first = activity.run(1, () => hold.future);
      bool ran = false;
      await activity.run(2, () async => ran = true);
      expect(ran, isTrue);
      expect(activity.activeSourceIds, <int>{1});
      hold.complete();
      await first;
    });

    test('a nested run on the held source is re-entrant', () async {
      final int result = await activity.run(
        1,
        () => activity.run(1, () async {
          expect(activity.activeSourceIds, <int>{1});
          return 7;
        }),
      );
      expect(result, 7);
      expect(activity.isIdle, isTrue);
    });
  });

  test('autoScanEligibleSources drops sources whose module is off, and '
      'everything when read-only', () {
    final List<SourceLibraryRow> rows = <SourceLibraryRow>[
      _row(1),
      _row(2, kind: 'video'),
      _row(3, kind: 'nope'),
    ];
    expect(
      autoScanEligibleSources(
        rows,
        readonly: false,
        isModuleEnabled: (ModuleId m) => m != ModuleId.video,
      ).map((SourceLibraryRow r) => r.id),
      <int>[1],
    );
    expect(
      autoScanEligibleSources(
        rows,
        readonly: true,
        isModuleEnabled: (ModuleId m) => true,
      ),
      isEmpty,
    );
  });

  group('runAutoSourceScan', () {
    SourceScanSummary summary(
      int id, {
      List<String> created = const <String>[],
    }) => SourceScanSummary(
      sourceId: id,
      mediaKind: 'video',
      discoveredPaths: const <String>[],
      importedMediaCount: created.length,
      createdVideoUids: created,
    );

    test(
      'non-video sources scan directly, never through the video gate',
      () async {
        final List<String> calls = <String>[];
        final SourceAutoScanOutcome outcome = await runAutoSourceScan(
          _row(1),
          scan: () async {
            calls.add('scan');
            return summary(1);
          },
          tryRunVideoScan: (int id, Future<SourceScanSummary> Function() s) {
            calls.add('gate');
            return s();
          },
          onVideoScanCreated: (SourceScanSummary s) async =>
              calls.add('scrape'),
          onVideoScanNoNew: () => calls.add('refresh'),
        );
        expect(outcome, SourceAutoScanOutcome.scanned);
        expect(calls, <String>['scan']);
      },
    );

    test('video source is deferred while the scrape gate is held', () async {
      final List<String> calls = <String>[];
      final SourceAutoScanOutcome outcome = await runAutoSourceScan(
        _row(1, kind: 'video'),
        scan: () async {
          calls.add('scan');
          return summary(1);
        },
        tryRunVideoScan: (int id, Future<SourceScanSummary> Function() s) =>
            null,
        onVideoScanCreated: (SourceScanSummary s) async => calls.add('scrape'),
        onVideoScanNoNew: () => calls.add('refresh'),
      );
      expect(outcome, SourceAutoScanOutcome.deferred);
      expect(calls, isEmpty, reason: '门被占时不扫、不串刮削、不刷新');
    });

    test(
      'video scan chains auto scrape only when new videos were created',
      () async {
        final List<String> calls = <String>[];
        Future<SourceAutoScanOutcome> run(List<String> created) =>
            runAutoSourceScan(
              _row(1, kind: 'video'),
              scan: () async => summary(1, created: created),
              tryRunVideoScan:
                  (int id, Future<SourceScanSummary> Function() s) {
                    calls.add('gate $id');
                    return s();
                  },
              onVideoScanCreated: (SourceScanSummary s) async =>
                  calls.add('scrape ${s.createdVideoUids.length}'),
              onVideoScanNoNew: () => calls.add('refresh'),
            );
        expect(await run(const <String>[]), SourceAutoScanOutcome.scanned);
        expect(calls, <String>['gate 1', 'refresh']);
        calls.clear();
        expect(
          await run(const <String>['v1', 'v2']),
          SourceAutoScanOutcome.scanned,
        );
        expect(calls, <String>['gate 1', 'scrape 2']);
      },
    );
  });

  group('VideoSourceScrapeTaskController.tryRunSourceScan', () {
    test('returns null instead of throwing while the gate is held', () async {
      final VideoSourceScrapeTaskController controller =
          VideoSourceScrapeTaskController(_NoopScrapeRunner());
      addTearDown(controller.dispose);
      final Completer<int> hold = Completer<int>();
      final Future<int>? first = controller.tryRunSourceScan(
        1,
        () => hold.future,
      );
      expect(first, isNotNull);
      expect(controller.scanningSourceId, 1);
      expect(controller.tryRunSourceScan(2, () async => 2), isNull);
      await expectLater(
        controller.runSourceScan(2, () async => 2),
        throwsStateError,
        reason: '手动入口的抛错语义不变',
      );
      hold.complete(7);
      expect(await first, 7);
      expect(controller.isScanning, isFalse);
      expect(await controller.tryRunSourceScan(3, () async => 3), 3);
    });
  });
}
