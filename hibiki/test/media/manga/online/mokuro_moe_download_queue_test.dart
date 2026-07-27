import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/manga/online/mokuro_moe_client.dart';
import 'package:hibiki/src/media/manga/online/mokuro_moe_download_queue.dart';
import 'package:hibiki/src/media/manga/online/mokuro_moe_volume_downloader.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// [MokuroMoeDownloadQueue] 纯逻辑单测：注入 runner 绕网络/DB，验证顺序执行、
/// 状态迁移、importedCount 口径、失败继续、取消与去重（统一下载中心的队列
/// 契约——对话框关闭与否与这里无关）。
void main() {
  late HibikiDatabase db;

  setUp(() {
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  const MokuroMoeVolumeDownloadEvent doneEvent = MokuroMoeVolumeDownloadEvent(
    stage: MokuroMoeDownloadStage.done,
    bookKey: 'book-1',
  );

  ({
    MokuroMoeDownloadQueue queue,
    List<({String series, String volume})> calls,
    List<StreamController<MokuroMoeVolumeDownloadEvent>> ctrls,
  }) makeQueue() {
    final List<({String series, String volume})> calls =
        <({String series, String volume})>[];
    final List<StreamController<MokuroMoeVolumeDownloadEvent>> ctrls =
        <StreamController<MokuroMoeVolumeDownloadEvent>>[];
    final MokuroMoeDownloadQueue queue = MokuroMoeDownloadQueue(
      db: db,
      clientFactory: () => MokuroMoeClient(),
      runnerOverride: (
          {required String seriesName, required String volumeName}) {
        calls.add((series: seriesName, volume: volumeName));
        final StreamController<MokuroMoeVolumeDownloadEvent> c =
            StreamController<MokuroMoeVolumeDownloadEvent>();
        ctrls.add(c);
        return c.stream;
      },
    );
    return (queue: queue, calls: calls, ctrls: ctrls);
  }

  test('顺序执行：一次一卷，前一卷收尾后才起下一卷；done 计入 importedCount', () async {
    final r = makeQueue();
    final int added = r.queue.enqueue(
      seriesName: 'S',
      volumeNames: <String>['v1', 'v2'],
    );
    expect(added, 2);
    expect(r.calls, hasLength(1));
    expect(r.calls.single, (series: 'S', volume: 'v1'));
    expect(r.queue.runningTask?.volumeName, 'v1');
    expect(r.queue.tasks[1].status, MokuroMoeTaskStatus.queued);

    r.ctrls[0].add(doneEvent);
    await r.ctrls[0].close();
    await pumpEventQueue();

    expect(r.queue.tasks[0].status, MokuroMoeTaskStatus.done);
    expect(r.queue.importedCount, 1);
    expect(r.calls, hasLength(2));
    expect(r.calls[1], (series: 'S', volume: 'v2'));

    r.ctrls[1].add(doneEvent);
    await r.ctrls[1].close();
    await pumpEventQueue();
    expect(r.queue.importedCount, 2);
    expect(r.queue.hasUnfinished, isFalse);
    r.queue.dispose();
  });

  test('已在库跳过（skippedExisting）：任务 done 但不计 importedCount', () async {
    final r = makeQueue();
    r.queue.enqueue(seriesName: 'S', volumeNames: <String>['v1']);
    r.ctrls[0].add(const MokuroMoeVolumeDownloadEvent(
      stage: MokuroMoeDownloadStage.done,
      skippedExisting: true,
    ));
    await r.ctrls[0].close();
    await pumpEventQueue();
    expect(r.queue.tasks.single.status, MokuroMoeTaskStatus.done);
    expect(r.queue.importedCount, 0);
    r.queue.dispose();
  });

  test('单卷失败只标记该任务并继续下一卷（后台队列语义，不整队即停）', () async {
    final r = makeQueue();
    r.queue.enqueue(seriesName: 'S', volumeNames: <String>['v1', 'v2']);

    r.ctrls[0].addError(StateError('boom'));
    await r.ctrls[0].close();
    await pumpEventQueue();

    expect(r.queue.tasks[0].status, MokuroMoeTaskStatus.failed);
    expect(r.queue.tasks[0].error, contains('boom'));
    expect(r.calls, hasLength(2), reason: '失败后应继续起 v2');

    r.ctrls[1].add(doneEvent);
    await r.ctrls[1].close();
    await pumpEventQueue();
    expect(r.queue.tasks[1].status, MokuroMoeTaskStatus.done);
    expect(r.queue.importedCount, 1);
    r.queue.dispose();
  });

  test('取消：排队中任务直接移除；执行中任务标 cancelled 并继续下一卷', () async {
    final r = makeQueue();
    r.queue.enqueue(seriesName: 'S', volumeNames: <String>['v1', 'v2', 'v3']);

    // 排队中的 v3 → 直接出队。
    final MokuroMoeDownloadTask v3 = r.queue.tasks[2];
    r.queue.cancel(v3);
    expect(r.queue.tasks.map((MokuroMoeDownloadTask t) => t.volumeName),
        <String>['v1', 'v2']);

    // 执行中的 v1（注入 runner 无 cancel 通道）→ 掐订阅按取消收尾，起 v2。
    final MokuroMoeDownloadTask v1 = r.queue.tasks[0];
    r.queue.cancel(v1);
    await pumpEventQueue();
    expect(v1.status, MokuroMoeTaskStatus.cancelled);
    expect(r.calls, hasLength(2));
    expect(r.queue.runningTask?.volumeName, 'v2');
    r.queue.dispose();
  });

  test('去重：同卷未完成时重复入队被忽略；完成后可再次入队（续传/重试路径）', () async {
    final r = makeQueue();
    expect(r.queue.enqueue(seriesName: 'S', volumeNames: <String>['v1']), 1);
    expect(r.queue.enqueue(seriesName: 'S', volumeNames: <String>['v1']), 0);
    expect(r.queue.tasks, hasLength(1));

    r.ctrls[0].addError(StateError('boom'));
    await r.ctrls[0].close();
    await pumpEventQueue();

    // 失败已结束 → 允许重新入队重试。
    expect(r.queue.enqueue(seriesName: 'S', volumeNames: <String>['v1']), 1);
    expect(r.calls, hasLength(2));
    r.queue.dispose();
  });

  test('clearFinished 只清已结束任务，保留排队/执行中', () async {
    final r = makeQueue();
    r.queue.enqueue(seriesName: 'S', volumeNames: <String>['v1', 'v2']);
    r.ctrls[0].add(doneEvent);
    await r.ctrls[0].close();
    await pumpEventQueue();

    expect(r.queue.tasks, hasLength(2));
    r.queue.clearFinished();
    expect(r.queue.tasks.map((MokuroMoeDownloadTask t) => t.volumeName),
        <String>['v2']);
    r.queue.dispose();
  });
}
