import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_download_manager.dart';

void main() {
  group('InterconnectDownloadManager', () {
    late Directory dir;
    late InterconnectDownloadManager manager;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('hibiki-interconnect-mgr');
      manager = InterconnectDownloadManager();
    });

    tearDown(() async {
      manager.dispose();
      if (dir.existsSync()) {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    File dest(String name) => File('${dir.path}/$name');

    test('start → progress → completed updates the task snapshot', () async {
      final List<double?> seen = <double?>[];
      manager.addListener(() => seen.add(manager.progressFor('v1')));

      await manager.startVideoDownload(
        id: 'v1',
        title: 'Video One',
        dest: dest('v1.mp4'),
        run: (File target,
            {void Function(double progress)? onProgress,
            void Function(int received, int? total)? onBytes,
            Future<void>? cancelSignal}) async {
          onProgress?.call(0.25);
          onProgress?.call(0.75);
        },
      );

      final InterconnectDownloadTask task = manager.taskFor('v1')!;
      expect(task.status, InterconnectDownloadStatus.completed);
      expect(task.progress, 1);
      expect(manager.isRunning('v1'), isFalse);
      // 进度回调过程中观察到 0.25 / 0.75 的中间值。
      expect(seen.contains(0.25), isTrue);
      expect(seen.contains(0.75), isTrue);
    });

    test('duplicate start while running is ignored (one task)', () async {
      final Completer<void> gate = Completer<void>();
      var runCalls = 0;

      final Future<InterconnectDownloadTask> first = manager.startVideoDownload(
        id: 'v1',
        title: 'Video One',
        dest: dest('v1.mp4'),
        run: (File target,
            {void Function(double progress)? onProgress,
            void Function(int received, int? total)? onBytes,
            Future<void>? cancelSignal}) async {
          runCalls += 1;
          await gate.future;
        },
      );
      // 第二次同 id 调用应被去重忽略，不再触发 run。
      await manager.startVideoDownload(
        id: 'v1',
        title: 'Video One',
        dest: dest('v1.mp4'),
        run: (File target,
            {void Function(double progress)? onProgress,
            void Function(int received, int? total)? onBytes,
            Future<void>? cancelSignal}) async {
          runCalls += 1;
        },
      );
      expect(runCalls, 1);
      expect(manager.isRunning('v1'), isTrue);

      gate.complete();
      await first;
      expect(runCalls, 1);
      expect(manager.isRunning('v1'), isFalse);
    });

    test('failure records error status and rethrows', () async {
      await expectLater(
        manager.startVideoDownload(
          id: 'v1',
          title: 'Video One',
          dest: dest('v1.mp4'),
          run: (File target,
                  {void Function(double progress)? onProgress,
                  void Function(int received, int? total)? onBytes,
                  Future<void>? cancelSignal}) =>
              throw const SocketException('reset'),
        ),
        throwsA(isA<SocketException>()),
      );
      final InterconnectDownloadTask task = manager.taskFor('v1')!;
      expect(task.status, InterconnectDownloadStatus.failed);
      expect(task.error, isNotNull);
      expect(manager.isRunning('v1'), isFalse);
    });

    test('onComplete failure marks task failed (no silent half-done)',
        () async {
      await expectLater(
        manager.startVideoDownload(
          id: 'v1',
          title: 'Video One',
          dest: dest('v1.mp4'),
          run: (File target,
              {void Function(double progress)? onProgress,
              void Function(int received, int? total)? onBytes,
              Future<void>? cancelSignal}) async {},
          onComplete: (File f) => throw StateError('register failed'),
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        manager.taskFor('v1')!.status,
        InterconnectDownloadStatus.failed,
      );
    });

    test('task survives independent of any page: snapshot stays after run',
        () async {
      // 模拟「页面 dispose」=丢弃所有外部引用；manager 持有的任务状态仍在。
      await manager.startVideoDownload(
        id: 'v1',
        title: 'Video One',
        dest: dest('v1.mp4'),
        run: (File target,
            {void Function(double progress)? onProgress,
            void Function(int received, int? total)? onBytes,
            Future<void>? cancelSignal}) async {},
      );
      // 没有任何页面 State 参与；任务仍可从 app 级 manager 取到。
      expect(manager.taskFor('v1'), isNotNull);
      expect(manager.tasks.containsKey('v1'), isTrue);
    });

    test('clearTask removes finished tasks but not running ones', () async {
      final Completer<void> gate = Completer<void>();
      final Future<void> running = manager.startVideoDownload(
        id: 'run',
        title: 'Running',
        dest: dest('run.mp4'),
        run: (File target,
                {void Function(double progress)? onProgress,
                void Function(int received, int? total)? onBytes,
                Future<void>? cancelSignal}) =>
            gate.future,
      );
      // running 任务不可清除。
      manager.clearTask('run');
      expect(manager.taskFor('run'), isNotNull);

      await manager.startVideoDownload(
        id: 'done',
        title: 'Done',
        dest: dest('done.mp4'),
        run: (File target,
            {void Function(double progress)? onProgress,
            void Function(int received, int? total)? onBytes,
            Future<void>? cancelSignal}) async {},
      );
      manager.clearTask('done');
      expect(manager.taskFor('done'), isNull);

      gate.complete();
      await running;
    });

    // #6 合集整体下载：串行批。
    group('startBatch (collection download)', () {
      test('runs starters strictly one after another and counts results',
          () async {
        final List<String> order = <String>[];
        final Completer<void> firstGate = Completer<void>();
        Future<void> Function() starter(String id, {bool fail = false}) =>
            () => manager.startVideoDownload(
                  id: id,
                  title: id,
                  dest: dest('$id.mp4'),
                  run: (File target,
                      {void Function(double progress)? onProgress,
                      void Function(int received, int? total)? onBytes,
                      Future<void>? cancelSignal}) async {
                    order.add('start:$id');
                    if (id == 'a') await firstGate.future;
                    if (fail) throw StateError('boom $id');
                    order.add('end:$id');
                  },
                );

        final Future<InterconnectDownloadBatch> done = manager.startBatch(
          id: InterconnectDownloadManager.collectionBatchId(7),
          title: 'Series',
          starters: <Future<void> Function()>[
            starter('a'),
            starter('b', fail: true),
            starter('c'),
          ],
        );
        await Future<void>.delayed(Duration.zero);
        // a 还卡着时 b 绝不能起跑（串行）。
        expect(order, <String>['start:a']);
        expect(manager.isBatchRunning('collection:7'), isTrue);
        expect(manager.batchFor('collection:7')!.total, 3);
        firstGate.complete();

        final InterconnectDownloadBatch batch = await done;
        expect(order, <String>[
          'start:a',
          'end:a',
          'start:b',
          'start:c',
          'end:c',
        ]);
        expect(batch.completed, 2);
        expect(batch.failed, 1);
        expect(batch.isRunning, isFalse);
        // 成员失败原因仍在其自己的任务快照里，批不吞。
        expect(manager.taskFor('b')!.status, InterconnectDownloadStatus.failed);
        expect(manager.taskFor('b')!.error, isNotNull);
        expect(
            manager.taskFor('c')!.status, InterconnectDownloadStatus.completed);
      });

      // 合集卡整体进度：聚的是成员任务的真实进度，不是批计数（批只在整集结束
      // 时 +1，长片下载全程 0/N）。
      test('aggregateFor folds member tasks into one progress/state', () async {
        expect(manager.aggregateFor(<String>['a', 'b']), isNull,
            reason: '没有成员有任务 → null，合集卡不画角标');

        final Completer<void> gateA = Completer<void>();
        final Completer<void> gateC = Completer<void>();
        void Function(double)? reportC;
        final Future<InterconnectDownloadTask> a = manager.startVideoDownload(
          id: 'a',
          title: 'a',
          dest: dest('a.mp4'),
          run: (File target,
                  {void Function(double progress)? onProgress,
                  void Function(int received, int? total)? onBytes,
                  Future<void>? cancelSignal}) =>
              gateA.future,
        );
        await Future<void>.delayed(Duration.zero);
        InterconnectDownloadAggregate agg =
            manager.aggregateFor(<String>['a', 'b', 'c'])!;
        expect(agg.total, 1, reason: '分母只算有任务的成员');
        expect(agg.isRunning, isTrue);
        expect(agg.progress, 0, reason: '首个进度回报前计 0');

        gateA.complete();
        await a;
        final Future<InterconnectDownloadTask> b = manager.startVideoDownload(
          id: 'b',
          title: 'b',
          dest: dest('b.mp4'),
          run: (File target,
                  {void Function(double progress)? onProgress,
                  void Function(int received, int? total)? onBytes,
                  Future<void>? cancelSignal}) =>
              throw StateError('boom'),
        );
        await expectLater(b, throwsStateError);
        final Future<InterconnectDownloadTask> c = manager.startVideoDownload(
          id: 'c',
          title: 'c',
          dest: dest('c.mp4'),
          run: (File target,
              {void Function(double progress)? onProgress,
              void Function(int received, int? total)? onBytes,
              Future<void>? cancelSignal}) async {
            reportC = onProgress;
            await gateC.future;
          },
        );
        await Future<void>.delayed(Duration.zero);
        reportC!(0.4);
        agg = manager.aggregateFor(<String>['a', 'b', 'c'])!;
        expect(agg.total, 3);
        expect(agg.running, 1);
        expect(agg.failed, 1);
        expect(agg.isRunning, isTrue);
        // a 完成计 1、b 失败计 0、c 进行中计 0.4 → 1.4 / 3。
        expect(agg.progress, closeTo(1.4 / 3, 1e-9));

        gateC.complete();
        await c;
        agg = manager.aggregateFor(<String>['a', 'b', 'c'])!;
        expect(agg.isRunning, isFalse);
        expect(agg.isFailed, isTrue, reason: '全部结束且有失败 → 失败态');
        expect(agg.progress, closeTo(2 / 3, 1e-9));
      });

      test('duplicate startBatch while running returns the live batch',
          () async {
        final Completer<void> gate = Completer<void>();
        var starts = 0;
        Future<void> Function() blocked() => () async {
              starts += 1;
              await gate.future;
            };
        final Future<InterconnectDownloadBatch> first = manager.startBatch(
          id: 'collection:1',
          title: 'S',
          starters: <Future<void> Function()>[blocked()],
        );
        await Future<void>.delayed(Duration.zero);
        final InterconnectDownloadBatch again = await manager.startBatch(
          id: 'collection:1',
          title: 'S',
          starters: <Future<void> Function()>[blocked(), blocked()],
        );
        expect(again.total, 1, reason: '重复调用拿到的是正在跑的那批，不是新批');
        expect(starts, 1);
        gate.complete();
        await first;
      });
    });
  });

  // BUG-2944：传输原语每读一块就回报一次进度，此前每次都通知，订阅整个管理器的
  // 书架 / 媒体库页跟着每块整页重建，iOS 下载期间掉帧。
  group('progress notification throttle (BUG-2944)', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('hibiki-interconnect-thr');
    });

    tearDown(() async {
      if (dir.existsSync()) {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('sub-percent chunks within the interval do not notify', () async {
      int clock = 1000;
      final InterconnectDownloadManager manager =
          InterconnectDownloadManager(now: () => clock);
      addTearDown(manager.dispose);
      final List<InterconnectDownloadBadgeState?> badges =
          <InterconnectDownloadBadgeState?>[];
      int notifications = 0;
      manager.addListener(() {
        notifications += 1;
        badges.add(manager.badgeStateFor('v1'));
      });

      await manager.startVideoDownload(
        id: 'v1',
        title: 'Video One',
        dest: File('${dir.path}/v1.mp4'),
        run: (File target,
            {void Function(double progress)? onProgress,
            void Function(int received, int? total)? onBytes,
            Future<void>? cancelSignal}) async {
          // 1000 块，每块 1/100000：总共只走到 1%，时钟不动。
          for (int i = 1; i <= 1000; i++) {
            onBytes?.call(i, 100000);
          }
          // 时钟走过间隔，同百分比也要通知一次（字节数在变）。
          clock += InterconnectDownloadManager.progressNotifyIntervalMs;
          onBytes?.call(1001, 100000);
          // 百分比跨整数立即通知。
          onBytes?.call(50000, 100000);
        },
      );

      // 起跑 1 + 0%→1% 跨整数 1 + 间隔到期 1 + 跨到 50% 1 + 完成 1，
      // 远少于 1000 块的逐块通知。
      expect(notifications, lessThan(10));
      expect(
        badges
            .whereType<InterconnectDownloadBadgeState>()
            .map((InterconnectDownloadBadgeState b) => b.percent),
        containsAll(<int>[1, 50]),
      );
      final InterconnectDownloadTask task = manager.taskFor('v1')!;
      expect(task.status, InterconnectDownloadStatus.completed,
          reason: '状态变化不节流，完成必须通知到');
      expect(badges.last?.status, InterconnectDownloadStatus.completed);
    });

    test('badgeStateFor is value-equal while only bytes move', () async {
      final InterconnectDownloadManager manager = InterconnectDownloadManager();
      addTearDown(manager.dispose);
      final Completer<void> gate = Completer<void>();
      late void Function(int received, int? total) report;
      final Future<InterconnectDownloadTask> run = manager.startVideoDownload(
        id: 'v1',
        title: 'Video One',
        dest: File('${dir.path}/v1.mp4'),
        run: (File target,
            {void Function(double progress)? onProgress,
            void Function(int received, int? total)? onBytes,
            Future<void>? cancelSignal}) async {
          report = onBytes!;
          await gate.future;
        },
      );

      report(1000, 100000);
      final InterconnectDownloadBadgeState? a = manager.badgeStateFor('v1');
      report(1500, 100000);
      final InterconnectDownloadBadgeState? b = manager.badgeStateFor('v1');
      // 同为 1%：select 比较相等 → 卡片不重建。
      expect(a, equals(b));
      expect(a?.percent, 1);
      report(2000, 100000);
      expect(manager.badgeStateFor('v1'), isNot(equals(a)));

      gate.complete();
      await run;
    });
  });
}
