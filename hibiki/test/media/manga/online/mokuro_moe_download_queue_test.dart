import 'dart:async';
import 'dart:io';

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
  }) makeQueue({List<Duration>? backoff}) {
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
      retryBackoffOverride: backoff,
    );
    return (queue: queue, calls: calls, ctrls: ctrls);
  }

  /// 用户实际撞到的失败：mokuro.moe 连接超时（截图里的
  /// `SocketException: 信号灯超时已到 ... mokuro.moe:9253`）。
  const SocketException timeout =
      SocketException('信号灯超时时间已到', osError: OSError('timeout', 121));

  /// 退避全零的队列：Timer(Duration.zero) 在下一轮事件循环触发，pumpEventQueue 可等到。
  List<Duration> instantBackoff(int times) =>
      List<Duration>.filled(times, Duration.zero);

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

  group('自动重试（网络瞬断自己回来）', () {
    test('SocketException → waitingRetry，退避到期后自动重跑同一个任务', () async {
      final r = makeQueue(backoff: instantBackoff(3));
      r.queue.enqueue(seriesName: 'S', volumeNames: <String>['v1']);
      final MokuroMoeDownloadTask task = r.queue.tasks.single;

      r.ctrls[0].addError(timeout);
      await r.ctrls[0].close();
      await pumpEventQueue();

      // 不是终态：不能被「清除已完成」扫掉，也不算 finished。
      expect(task.autoRetries, 1);
      expect(task.isFinished, isFalse);
      r.queue.clearFinished();
      expect(r.queue.tasks, hasLength(1));
      // 退避到期后重跑，且仍是**同一个任务对象**（不新建行）。
      expect(r.calls, hasLength(2));
      expect(r.queue.tasks.single, same(task));
      expect(task.status, MokuroMoeTaskStatus.running);

      r.ctrls[1].add(doneEvent);
      await r.ctrls[1].close();
      await pumpEventQueue();
      expect(task.status, MokuroMoeTaskStatus.done);
      expect(r.queue.importedCount, 1);
      r.queue.dispose();
    });

    test('连续失败到上限后落 failed，不再无限重试', () async {
      final r = makeQueue(backoff: instantBackoff(2));
      r.queue.enqueue(seriesName: 'S', volumeNames: <String>['v1']);
      final MokuroMoeDownloadTask task = r.queue.tasks.single;

      for (int attempt = 0; attempt < 3; attempt++) {
        r.ctrls[attempt].addError(timeout);
        await r.ctrls[attempt].close();
        await pumpEventQueue();
      }

      expect(r.calls, hasLength(3), reason: '首跑 + 2 次自动重试');
      expect(task.status, MokuroMoeTaskStatus.failed);
      expect(task.autoRetries, 2);
      expect(task.error, contains('信号灯超时'));
      r.queue.dispose();
    });

    test('退避期间不占执行位：队列立刻去跑下一卷', () async {
      // 退避足够长，确保观察窗口内不会到期。
      final r = makeQueue(backoff: const <Duration>[Duration(minutes: 5)]);
      r.queue.enqueue(seriesName: 'S', volumeNames: <String>['v1', 'v2']);

      r.ctrls[0].addError(timeout);
      await r.ctrls[0].close();
      await pumpEventQueue();

      expect(r.queue.tasks[0].status, MokuroMoeTaskStatus.waitingRetry);
      expect(r.calls, hasLength(2));
      expect(r.queue.runningTask?.volumeName, 'v2');
      r.queue.dispose();
    });

    test('退避中取消：移出队列，且到期后不会被偷偷重排', () async {
      // 退避设短但非零：cancel 掐掉定时器后，即使等过这个时长也不该再起下载。
      final r =
          makeQueue(backoff: const <Duration>[Duration(milliseconds: 10)]);
      r.queue.enqueue(seriesName: 'S', volumeNames: <String>['v1']);
      final MokuroMoeDownloadTask task = r.queue.tasks.single;

      r.ctrls[0].addError(timeout);
      await r.ctrls[0].close();
      await pumpEventQueue();
      expect(task.status, MokuroMoeTaskStatus.waitingRetry);

      r.queue.cancel(task);
      expect(r.queue.tasks, isEmpty);

      await Future<void>.delayed(const Duration(milliseconds: 40));
      await pumpEventQueue();
      expect(r.calls, hasLength(1), reason: '取消后定时器必须已被掐掉');
      r.queue.dispose();
    });

    test('404 不自动重试（该卷就是没有，重试只是白等）；503 才重试', () async {
      final r = makeQueue(backoff: instantBackoff(3));
      r.queue.enqueue(seriesName: 'S', volumeNames: <String>['v1']);
      r.ctrls[0].addError(const MokuroMoeHttpException(404));
      await r.ctrls[0].close();
      await pumpEventQueue();
      expect(r.queue.tasks.single.status, MokuroMoeTaskStatus.failed);
      expect(r.calls, hasLength(1));
      r.queue.dispose();

      final r2 = makeQueue(backoff: instantBackoff(3));
      r2.queue.enqueue(seriesName: 'S', volumeNames: <String>['v1']);
      r2.ctrls[0].addError(const MokuroMoeHttpException(503));
      await r2.ctrls[0].close();
      await pumpEventQueue();
      expect(r2.calls, hasLength(2), reason: '服务端瞬时故障值得重试');
      r2.queue.dispose();
    });

    test('本地数据错误（坏 zip）不自动重试：重跑同一份坏数据不会变好', () async {
      final r = makeQueue(backoff: instantBackoff(3));
      r.queue.enqueue(seriesName: 'S', volumeNames: <String>['v1']);
      r.ctrls[0].addError(StateError('mokuro.moe CBZ is not a valid zip'));
      await r.ctrls[0].close();
      await pumpEventQueue();
      expect(r.queue.tasks.single.status, MokuroMoeTaskStatus.failed);
      expect(r.calls, hasLength(1));
      r.queue.dispose();
    });

    test('用户取消不触发自动重试', () async {
      final r = makeQueue(backoff: instantBackoff(3));
      r.queue.enqueue(seriesName: 'S', volumeNames: <String>['v1']);
      r.queue.cancel(r.queue.tasks.single);
      await pumpEventQueue();
      expect(r.queue.tasks.single.status, MokuroMoeTaskStatus.cancelled);
      expect(r.calls, hasLength(1));
      r.queue.dispose();
    });
  });

  group('手动重试（下载页的重试按钮）', () {
    test('failed 任务就地复活成排队态，不新建第二条同名行', () async {
      final r = makeQueue(backoff: const <Duration>[]);
      r.queue.enqueue(seriesName: 'S', volumeNames: <String>['v1']);
      final MokuroMoeDownloadTask task = r.queue.tasks.single;
      r.ctrls[0].addError(timeout);
      await r.ctrls[0].close();
      await pumpEventQueue();
      expect(task.status, MokuroMoeTaskStatus.failed);

      r.queue.retry(task);
      await pumpEventQueue();

      expect(r.queue.tasks, hasLength(1), reason: '失败行不该僵在列表里 + 多出一条新任务');
      expect(r.queue.tasks.single, same(task));
      expect(task.status, MokuroMoeTaskStatus.running);
      expect(task.error, isNull);
      expect(task.autoRetries, 0, reason: '用户点一次 = 重新拿满自动重试预算');
      expect(r.calls, hasLength(2));
      r.queue.dispose();
    });

    test('已取消的任务也能手动重试；done / 进行中是 no-op', () async {
      final r = makeQueue(backoff: const <Duration>[]);
      r.queue.enqueue(seriesName: 'S', volumeNames: <String>['v1', 'v2']);
      final MokuroMoeDownloadTask v1 = r.queue.tasks[0];
      final MokuroMoeDownloadTask v2 = r.queue.tasks[1];

      r.queue.cancel(v1);
      await pumpEventQueue();
      expect(v1.status, MokuroMoeTaskStatus.cancelled);
      expect(r.queue.runningTask, same(v2));

      // 进行中的任务：no-op（不打断当前下载）。
      r.queue.retry(v2);
      expect(v2.status, MokuroMoeTaskStatus.running);
      expect(r.calls, hasLength(2));

      r.queue.retry(v1);
      expect(v1.status, MokuroMoeTaskStatus.queued, reason: 'v2 还占着执行位，v1 排队等');

      r.ctrls[1].add(doneEvent);
      await r.ctrls[1].close();
      await pumpEventQueue();
      expect(r.calls, hasLength(3));
      expect(v1.status, MokuroMoeTaskStatus.running);

      // 已成功的任务：no-op。
      r.queue.retry(v2);
      expect(v2.status, MokuroMoeTaskStatus.done);
      expect(r.calls, hasLength(3));
      r.queue.dispose();
    });

    test('retryAllFailed 一次复活所有失败/取消任务并返回条数', () async {
      final r = makeQueue(backoff: const <Duration>[]);
      r.queue.enqueue(seriesName: 'S', volumeNames: <String>['v1', 'v2', 'v3']);
      // v1 失败、v2 取消、v3 成功。
      r.ctrls[0].addError(timeout);
      await r.ctrls[0].close();
      await pumpEventQueue();
      r.queue.cancel(r.queue.tasks[1]);
      await pumpEventQueue();
      r.ctrls[2].add(doneEvent);
      await r.ctrls[2].close();
      await pumpEventQueue();

      expect(r.queue.tasks[0].status, MokuroMoeTaskStatus.failed);
      expect(r.queue.tasks[1].status, MokuroMoeTaskStatus.cancelled);
      expect(r.queue.tasks[2].status, MokuroMoeTaskStatus.done);

      expect(r.queue.retryAllFailed(), 2);
      await pumpEventQueue();
      expect(r.queue.tasks[2].status, MokuroMoeTaskStatus.done,
          reason: '成功的不动');
      expect(r.queue.tasks, hasLength(3), reason: '仍是原来那三行');
      r.queue.dispose();
    });
  });
}
