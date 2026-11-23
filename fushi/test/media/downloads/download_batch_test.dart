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

class _FakeGroup implements DownloadTaskBatchGroup<String> {
  _FakeGroup({required this.failIndexes});

  final Set<int> failIndexes;
  int calls = 0;

  @override
  bool handlesBatchAction(DownloadBatchAction action) => true;

  @override
  Future<List<DownloadTaskBatchFailure?>> runBatch(
    DownloadBatchAction action,
    List<String> items,
  ) async {
    calls++;
    return <DownloadTaskBatchFailure?>[
      for (int i = 0; i < items.length; i++)
        failIndexes.contains(i)
            ? DownloadTaskBatchFailure(
                StateError('${items[i]} failed'),
                StackTrace.current,
              )
            : null,
    ];
  }
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

    test('失败逐条带上任务名与原因（BUG-5212）', () async {
      final DownloadBatchOutcome outcome = await runDownloadTaskBatch(
        tasks: <DownloadTaskEntry>[
          _task('ok', DownloadTaskActions(resume: () async {})),
          _task(
            'Doraemon',
            DownloadTaskActions(
              resume: () async => throw StateError('torrent gone'),
            ),
          ),
        ],
        action: DownloadBatchAction.resume,
      );
      expect(outcome.failed, 1);
      expect(outcome.failures.single.title, 'Doraemon');
      expect(outcome.failures.single.reason, contains('torrent gone'));
    });

    test('整批执行的组：失败按组内位置对回各自的任务名', () async {
      final _FakeGroup group = _FakeGroup(failIndexes: <int>{1});
      DownloadTaskEntry member(String id) => _task(
        id,
        DownloadTaskActions(
          resume: () async {},
          batchMember: DownloadTaskBatchMember<String>(group: group, item: id),
        ),
      );
      final DownloadBatchOutcome outcome = await runDownloadTaskBatch(
        tasks: <DownloadTaskEntry>[member('a'), member('b'), member('c')],
        action: DownloadBatchAction.resume,
      );
      expect(group.calls, 1);
      expect(outcome.done, 2);
      expect(
        outcome.failures.map((DownloadBatchFailedTask f) => f.title),
        <String>['b'],
      );
      expect(outcome.failures.single.reason, contains('b failed'));
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
      expect(maxConcurrent, 1, reason: '并发会把一批操作变成一批竞态（同后端暂停/同表生命周期 CAS）');
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
      expect(countDownloadTasksSupporting(tasks, DownloadBatchAction.retry), 2);
      expect(countDownloadTasksSupporting(tasks, DownloadBatchAction.clear), 1);
      expect(
        countDownloadTasksSupporting(tasks, DownloadBatchAction.pause),
        0,
        reason: '一条都不支持时按钮必须禁用，否则点下去只会弹「0 条已处理」',
      );
    });
  });

  group('downloadClearCompletedDisposition', () {
    Future<void> noop() async {}
    Future<void> noopDelete({required bool deleteFiles}) async {}

    final DownloadTaskEntry clearOnly = _task(
      'clear-only',
      DownloadTaskActions(clear: noop),
    );
    final DownloadTaskEntry deleteWithFiles = _task(
      'delete-with-files',
      DownloadTaskActions(delete: noopDelete, deletesFiles: true),
    );
    final DownloadTaskEntry deleteNoFiles = _task(
      'delete-no-files',
      DownloadTaskActions(delete: noopDelete),
    );
    final DownloadTaskEntry both = _task(
      'both',
      DownloadTaskActions(clear: noop, delete: noopDelete, deletesFiles: true),
    );

    test('不勾删除文件：有 clear 才清记录，否则不动（绝不调 delete）', () {
      expect(
        downloadClearCompletedDisposition(clearOnly, deleteFiles: false),
        DownloadClearCompletedDisposition.clearRecord,
      );
      expect(
        downloadClearCompletedDisposition(deleteWithFiles, deleteFiles: false),
        DownloadClearCompletedDisposition.untouched,
      );
      expect(
        downloadClearCompletedDisposition(deleteNoFiles, deleteFiles: false),
        DownloadClearCompletedDisposition.untouched,
      );
      expect(
        downloadClearCompletedDisposition(both, deleteFiles: false),
        DownloadClearCompletedDisposition.clearRecord,
      );
    });

    test('勾删除文件：兑现得了就删文件，否则退回清记录或不动', () {
      expect(
        downloadClearCompletedDisposition(clearOnly, deleteFiles: true),
        DownloadClearCompletedDisposition.clearRecordKeepFiles,
      );
      expect(
        downloadClearCompletedDisposition(deleteWithFiles, deleteFiles: true),
        DownloadClearCompletedDisposition.deleteFiles,
      );
      expect(
        downloadClearCompletedDisposition(deleteNoFiles, deleteFiles: true),
        DownloadClearCompletedDisposition.untouched,
        reason: 'deletesFiles=false 的 delete 删不删数据由来源决定，不碰',
      );
      expect(
        downloadClearCompletedDisposition(both, deleteFiles: true),
        DownloadClearCompletedDisposition.deleteFiles,
      );
    });

    test('runDownloadClearCompleted 分段计数，单条抛错计入 failed 不中断', () async {
      final DownloadClearCompletedOutcome outcome =
          await runDownloadClearCompleted(
            tasks: <DownloadTaskEntry>[
              clearOnly,
              deleteWithFiles,
              deleteNoFiles,
              _task(
                'throws',
                DownloadTaskActions(
                  delete: ({required bool deleteFiles}) async =>
                      throw StateError('boom'),
                  deletesFiles: true,
                ),
              ),
            ],
            deleteFiles: true,
          );
      expect(outcome.filesDeleted, 1);
      expect(outcome.clearedKeptFiles, 1);
      expect(outcome.untouched, 1);
      expect(outcome.failed, 1);
      expect(outcome.cleared, 0);
      expect(outcome.total, 4);
    });
  });
}
