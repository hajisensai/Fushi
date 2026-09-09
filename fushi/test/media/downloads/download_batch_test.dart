import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/downloads/download_batch.dart';
import 'package:fushi/src/media/downloads/download_task_entry.dart';

DownloadTaskEntry _task(String id, DownloadTaskActions actions) {
  return DownloadTaskEntry(
    id: id,
    title: id,
    kind: DownloadTaskKind.video,
    status: DownloadTaskStatus.active,
    actions: actions,
    builder: (_) => const SizedBox.shrink(),
  );
}

void main() {
  group('runDownloadTaskBatch', () {
    test('不支持该动作的条目计入 unsupported，不算失败', () async {
      final List<String> ran = <String>[];
      final DownloadBatchOutcome outcome = await runDownloadTaskBatch(
        tasks: <DownloadTaskEntry>[
          _task('a', DownloadTaskActions(retry: () async => ran.add('a'))),
          _task('b', DownloadTaskActions.none),
          _task('c', DownloadTaskActions(retry: () async => ran.add('c'))),
        ],
        action: DownloadBatchAction.retry,
      );
      expect(ran, <String>['a', 'c']);
      expect(outcome.done, 2);
      expect(outcome.unsupported, 1);
      expect(outcome.failed, 0);
    });

    test('单条抛错不中断整批，其余照常执行', () async {
      final List<String> ran = <String>[];
      final List<Object> errors = <Object>[];
      final DownloadBatchOutcome outcome = await runDownloadTaskBatch(
        tasks: <DownloadTaskEntry>[
          _task('a', DownloadTaskActions(cancel: () async => ran.add('a'))),
          _task(
            'boom',
            DownloadTaskActions(cancel: () async => throw StateError('boom')),
          ),
          _task('c', DownloadTaskActions(cancel: () async => ran.add('c'))),
        ],
        action: DownloadBatchAction.cancel,
        onError: (Object error, StackTrace _) => errors.add(error),
      );
      expect(ran, <String>['a', 'c'], reason: '中间那条炸了不该拦住后面的');
      expect(outcome.done, 2);
      expect(outcome.failed, 1);
      expect(outcome.unsupported, 0);
      expect(errors, hasLength(1));
    });

    test('串行执行：下一条开始前上一条必须已经结束', () async {
      int running = 0;
      int maxConcurrent = 0;
      Future<void> body() async {
        running++;
        maxConcurrent = running > maxConcurrent ? running : maxConcurrent;
        await Future<void>.delayed(Duration.zero);
        running--;
      }

      await runDownloadTaskBatch(
        tasks: <DownloadTaskEntry>[
          for (int i = 0; i < 4; i++)
            _task('t$i', DownloadTaskActions(pause: body)),
        ],
        action: DownloadBatchAction.pause,
      );
      expect(maxConcurrent, 1,
          reason: '并发会把一批操作变成一批竞态（同后端暂停/同表生命周期 CAS）');
    });

    test('deleteFiles 透传到每一条的 delete', () async {
      final List<bool> seen = <bool>[];
      await runDownloadTaskBatch(
        tasks: <DownloadTaskEntry>[
          _task(
            'a',
            DownloadTaskActions(
              delete: ({required bool deleteFiles}) async =>
                  seen.add(deleteFiles),
            ),
          ),
          _task(
            'b',
            DownloadTaskActions(
              delete: ({required bool deleteFiles}) async =>
                  seen.add(deleteFiles),
            ),
          ),
        ],
        action: DownloadBatchAction.delete,
        deleteFiles: true,
      );
      expect(seen, <bool>[true, true]);
    });

    test('空集返回空结果', () async {
      final DownloadBatchOutcome outcome = await runDownloadTaskBatch(
        tasks: const <DownloadTaskEntry>[],
        action: DownloadBatchAction.retry,
      );
      expect(outcome.isEmpty, isTrue);
    });

    test('pause 不会顶替 cancel：只有 cancel 的条目按不支持跳过', () async {
      final DownloadBatchOutcome outcome = await runDownloadTaskBatch(
        tasks: <DownloadTaskEntry>[
          _task('queue-like', DownloadTaskActions(cancel: () async {})),
        ],
        action: DownloadBatchAction.pause,
      );
      expect(outcome.done, 0);
      expect(outcome.unsupported, 1);
    });
  });

  group('countDownloadTasksSupporting', () {
    test('数的是真支持该动作的条数（按钮可用态判据）', () {
      final List<DownloadTaskEntry> tasks = <DownloadTaskEntry>[
        _task('a', DownloadTaskActions(retry: () async {})),
        _task('b', DownloadTaskActions(clear: () async {})),
        _task('c', DownloadTaskActions(retry: () async {})),
      ];
      expect(
        countDownloadTasksSupporting(tasks, DownloadBatchAction.retry),
        2,
      );
      expect(
        countDownloadTasksSupporting(tasks, DownloadBatchAction.clear),
        1,
      );
      expect(
        countDownloadTasksSupporting(tasks, DownloadBatchAction.pause),
        0,
        reason: '一条都不支持时按钮必须禁用，否则点下去只会弹「0 条已处理」',
      );
    });
  });
}
