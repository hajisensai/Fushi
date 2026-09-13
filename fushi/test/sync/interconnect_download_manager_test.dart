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
        run: (File target, {void Function(double progress)? onProgress}) async {
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
        run: (File target, {void Function(double progress)? onProgress}) async {
          runCalls += 1;
          await gate.future;
        },
      );
      // 第二次同 id 调用应被去重忽略，不再触发 run。
      await manager.startVideoDownload(
        id: 'v1',
        title: 'Video One',
        dest: dest('v1.mp4'),
        run: (File target, {void Function(double progress)? onProgress}) async {
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
          run: (File target, {void Function(double progress)? onProgress}) =>
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
              {void Function(double progress)? onProgress}) async {},
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
            {void Function(double progress)? onProgress}) async {},
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
        run: (File target, {void Function(double progress)? onProgress}) =>
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
            {void Function(double progress)? onProgress}) async {},
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
                      {void Function(double progress)? onProgress}) async {
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
}
