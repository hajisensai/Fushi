import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/download/manga_download_service.dart';
import 'package:fushi/src/media/manga/online/mokuro_moe_client.dart';
import 'package:fushi/src/media/manga/online/mokuro_moe_volume_downloader.dart';
import 'package:fushi_core/fushi_core.dart';

/// 假下载器：`run` 回传测试受控的事件流并记录 `(系列, 卷)`；`cancel` 只计数。
class _FakeDownloader extends MokuroMoeVolumeDownloader {
  _FakeDownloader(this.calls) : super(client: MokuroMoeClient());

  final List<(String, String)> calls;
  final StreamController<MokuroMoeVolumeDownloadEvent> ctrl =
      StreamController<MokuroMoeVolumeDownloadEvent>();
  int cancelCalls = 0;

  @override
  Stream<MokuroMoeVolumeDownloadEvent> run({
    required FushiDatabase db,
    required String seriesName,
    required String volumeName,
  }) {
    calls.add((seriesName, volumeName));
    return ctrl.stream;
  }

  @override
  void cancel() => cancelCalls++;

  Future<void> finish(MokuroMoeVolumeDownloadEvent last) async {
    ctrl.add(last);
    await ctrl.close();
  }

  Future<void> fail(Object error) async {
    ctrl.addError(error);
    await ctrl.close();
  }
}

const String _series = 'Series';
const String _vol1 = 'Series 01';
const String _vol2 = 'Series 02';

void main() {
  late FushiDatabase db;
  late List<Duration> waits;
  late List<(String, String)> calls;
  late List<_FakeDownloader> downloaders;

  int tick = 0;

  /// 时钟单调递增：`created_at` 与入队顺序一致，worker 领取顺序才可断言
  /// （同毫秒入队会退化成按 job_id 哈希排序）。
  MangaDownloadService build() => MangaDownloadService(
        database: db,
        serviceFor: (_) => throw UnimplementedError('章节任务不在本测试范围'),
        clock: () => DateTime.fromMillisecondsSinceEpoch(++tick),
        mokuroDownloader: () {
          final _FakeDownloader downloader = _FakeDownloader(calls);
          downloaders.add(downloader);
          return downloader;
        },
        wait: (Duration duration) async {
          waits.add(duration);
        },
      );

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    tick = 0;
    waits = <Duration>[];
    calls = <(String, String)>[];
    downloaders = <_FakeDownloader>[];
  });

  tearDown(() async {
    for (final _FakeDownloader downloader in downloaders) {
      if (!downloader.ctrl.isClosed) await downloader.ctrl.close();
    }
    await db.close();
  });

  String jobIdOf(String volume) => mangaDownloadJobId(
        kind: MangaDownloadJobKind.mokuroVolume,
        bookKey: mokuroMoeBookKey(_series),
        chapterKey: volume,
      );

  Future<MangaDownloadJobRow> row(String volume) async =>
      (await db.getMangaDownloadJob(jobIdOf(volume)))!;

  /// 轮询到条件为真（worker 是异步的，事件到落库之间隔着若干微任务）。
  Future<void> until(
    Future<bool> Function() condition, {
    String reason = '',
  }) async {
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!await condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('等待超时: $reason');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  Future<_FakeDownloader> downloaderAt(int index) async {
    await until(() async => downloaders.length > index,
        reason: '第 ${index + 1} 个下载器没被建出来');
    return downloaders[index];
  }

  test('两卷顺序执行：第一卷流没关第二卷不起；done 落行并计数，skippedExisting 不计', () async {
    final MangaDownloadService downloads = build();
    final ({MangaDownloadJobRow row, bool added}) first =
        await downloads.enqueueMokuroVolume(
      seriesName: _series,
      volumeName: _vol1,
    );
    expect(first.added, isTrue);
    expect(first.row.kind, MangaDownloadJobKind.mokuroVolume);
    expect(first.row.bookKey, 'mokuro:$_series');
    expect(first.row.chapterKey, _vol1);
    expect(first.row.runtime, kMokuroMoeDownloadRuntime);
    expect(first.row.title, _vol1, reason: '卷名已含系列名 → 直接用卷名');
    await downloads.enqueueMokuroVolume(seriesName: _series, volumeName: _vol2);
    await downloads.start();

    final _FakeDownloader d1 = await downloaderAt(0);
    expect(calls, <(String, String)>[(_series, _vol1)]);
    d1.ctrl.add(const MokuroMoeVolumeDownloadEvent(
      stage: MokuroMoeDownloadStage.importing,
      pagesDone: 1,
      pagesTotal: 4,
    ));
    await until(() async => (await row(_vol1)).pagesDone == 1);
    expect((await row(_vol1)).status, MangaDownloadJobStatus.running);
    expect((await row(_vol2)).status, MangaDownloadJobStatus.queued);
    expect(downloaders, hasLength(1), reason: '单 worker：第一卷没完第二卷不能起');
    expect(downloads.mokuroImportedCount.value, 0);

    await d1.finish(const MokuroMoeVolumeDownloadEvent(
      stage: MokuroMoeDownloadStage.done,
      bookKey: 'book-1',
    ));
    await until(
        () async => (await row(_vol1)).status == MangaDownloadJobStatus.done);
    final MangaDownloadJobRow done1 = await row(_vol1);
    expect(done1.completedAt, isNotNull);
    expect(done1.lastError, isNull);
    expect(downloads.mokuroImportedCount.value, 1);

    final _FakeDownloader d2 = await downloaderAt(1);
    expect(calls.last, (_series, _vol2));
    await d2.finish(const MokuroMoeVolumeDownloadEvent(
      stage: MokuroMoeDownloadStage.done,
      skippedExisting: true,
    ));
    await downloads.whenIdle;
    expect((await row(_vol2)).status, MangaDownloadJobStatus.done);
    expect(downloads.mokuroImportedCount.value, 1,
        reason: '已在库被 skip 的卷没有新书行，不计');
    expect(waits, isEmpty);
    downloads.dispose();
  });

  test('进度映射：CBZ 阶段记字节、导入阶段记页', () async {
    final MangaDownloadService downloads = build();
    await downloads.enqueueMokuroVolume(seriesName: _series, volumeName: _vol1);
    await downloads.start();
    final _FakeDownloader d1 = await downloaderAt(0);

    d1.ctrl.add(const MokuroMoeVolumeDownloadEvent(
      stage: MokuroMoeDownloadStage.downloadingCbz,
      receivedBytes: 512 * 1024,
      totalBytes: 1024 * 1024,
    ));
    await until(() async => (await row(_vol1)).pagesDone == 524288);
    expect((await row(_vol1)).pagesTotal, 1048576);

    d1.ctrl.add(const MokuroMoeVolumeDownloadEvent(
      stage: MokuroMoeDownloadStage.importing,
      pagesDone: 3,
      pagesTotal: 10,
    ));
    await until(() async => (await row(_vol1)).pagesDone == 3);
    expect((await row(_vol1)).pagesTotal, 10);

    // 没有可比进度的阶段（extracting / 总量未知的 CBZ）不动列。
    d1.ctrl.add(const MokuroMoeVolumeDownloadEvent(
      stage: MokuroMoeDownloadStage.extracting,
      receivedBytes: 99,
    ));
    d1.ctrl.add(const MokuroMoeVolumeDownloadEvent(
      stage: MokuroMoeDownloadStage.downloadingCbz,
      receivedBytes: 99,
    ));
    await d1.finish(const MokuroMoeVolumeDownloadEvent(
      stage: MokuroMoeDownloadStage.done,
      bookKey: 'book-1',
    ));
    await downloads.whenIdle;
    final MangaDownloadJobRow done = await row(_vol1);
    expect(done.status, MangaDownloadJobStatus.done);
    expect(done.pagesDone, 3);
    expect(done.pagesTotal, 10);
    downloads.dispose();
  });

  test('流抛异常 → 退避重跑，三次仍失败 → failed + last_error + attempt_count 3', () async {
    final MangaDownloadService downloads = build();
    final String jobId = (await downloads.enqueueMokuroVolume(
      seriesName: _series,
      volumeName: _vol1,
    ))
        .row
        .jobId;
    await downloads.start();

    for (int attempt = 0; attempt < kMangaDownloadMaxAttempts; attempt++) {
      final _FakeDownloader d = await downloaderAt(attempt);
      await d.fail(StateError('boom $attempt'));
    }
    await downloads.whenIdle;

    final MangaDownloadJobRow failed = (await db.getMangaDownloadJob(jobId))!;
    expect(failed.status, MangaDownloadJobStatus.failed);
    expect(failed.attemptCount, kMangaDownloadMaxAttempts);
    expect(failed.lastError, contains('boom 2'));
    expect(downloaders, hasLength(3), reason: '每次重试都新建一个下载器');
    expect(waits, <Duration>[
      kMangaDownloadRetryBackoff[0],
      kMangaDownloadRetryBackoff[1],
    ]);

    // retry：同一行复位 queued、attempt 归零、行数不变（BUG-1433 就地重试）。
    downloads.dispose(); // 不让 worker 立刻领走，好断言 queued 态。
    await downloads.retry(jobId);
    final List<MangaDownloadJobRow> rows = await db.listMangaDownloadJobs();
    expect(rows, hasLength(1));
    expect(rows.single.jobId, jobId);
    expect(rows.single.status, MangaDownloadJobStatus.queued);
    expect(rows.single.attemptCount, 0);
    expect(rows.single.lastError, isNull);

    // queued 的卷再入队：幂等，不新建行。
    final ({MangaDownloadJobRow row, bool added}) again =
        await downloads.enqueueMokuroVolume(
      seriesName: _series,
      volumeName: _vol1,
    );
    expect(again.added, isFalse);
    expect(again.row.jobId, jobId);
    expect(await db.listMangaDownloadJobs(), hasLength(1));
  });

  test(
      '执行中 cancel → 下载器 cancel 被调、流以 Cancelled 收尾 → 行 cancelled；retry 回 queued',
      () async {
    final MangaDownloadService downloads = build();
    final String jobId = (await downloads.enqueueMokuroVolume(
      seriesName: _series,
      volumeName: _vol1,
    ))
        .row
        .jobId;
    await downloads.start();
    final _FakeDownloader d1 = await downloaderAt(0);
    expect((await row(_vol1)).status, MangaDownloadJobStatus.running);

    await downloads.cancel(jobId);
    expect(d1.cancelCalls, 1, reason: '取消要真掐下载器，不是只改状态');
    await d1.fail(const MokuroMoeDownloadCancelled());
    await downloads.whenIdle;
    expect((await row(_vol1)).status, MangaDownloadJobStatus.cancelled);
    expect(waits, isEmpty, reason: '用户取消不走退避重试');

    downloads.dispose();
    await downloads.retry(jobId);
    final MangaDownloadJobRow retried = await row(_vol1);
    expect(retried.jobId, jobId);
    expect(retried.status, MangaDownloadJobStatus.queued);
    expect(retried.attemptCount, 0);
    expect(await db.listMangaDownloadJobs(), hasLength(1));
  });

  test('流没发 done 就正常关闭 → 行 cancelled（旧队列语义）', () async {
    final MangaDownloadService downloads = build();
    await downloads.enqueueMokuroVolume(seriesName: _series, volumeName: _vol1);
    await downloads.start();
    final _FakeDownloader d1 = await downloaderAt(0);
    d1.ctrl.add(const MokuroMoeVolumeDownloadEvent(
      stage: MokuroMoeDownloadStage.importing,
      pagesDone: 1,
      pagesTotal: 2,
    ));
    await d1.ctrl.close();
    await downloads.whenIdle;
    expect((await row(_vol1)).status, MangaDownloadJobStatus.cancelled);
    expect(downloads.mokuroImportedCount.value, 0);
    expect(waits, isEmpty);
    downloads.dispose();
  });

  test('clearFinished 只删 done / failed / cancelled', () async {
    final MangaDownloadService downloads = build();
    const List<String> volumes = <String>['a', 'b', 'c', 'd', 'e'];
    expect(
      await downloads.enqueueMokuroVolumes(
        seriesName: _series,
        volumeNames: volumes,
      ),
      5,
    );
    const List<String> statuses = <String>[
      MangaDownloadJobStatus.queued,
      MangaDownloadJobStatus.running,
      MangaDownloadJobStatus.done,
      MangaDownloadJobStatus.failed,
      MangaDownloadJobStatus.cancelled,
    ];
    for (int i = 0; i < volumes.length; i++) {
      await db.updateMangaDownloadJobStatus(
        jobIdOf(volumes[i]),
        status: statuses[i],
        updatedAt: i,
      );
    }
    await downloads.clearFinished();
    final List<MangaDownloadJobRow> left = await db.listMangaDownloadJobs();
    expect(
      left.map((MangaDownloadJobRow r) => r.chapterKey).toSet(),
      <String>{'a', 'b'},
    );
    expect(
      (await downloads.mokuroJobsForSeries(_series)).keys.toSet(),
      <String>{'a', 'b'},
    );
    downloads.dispose();
  });
}
