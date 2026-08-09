import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/common.dart' show CommonDatabase;

Future<FushiDatabase> _openDb() async {
  final FushiDatabase db = FushiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (CommonDatabase rawDb) =>
          rawDb.execute('PRAGMA foreign_keys = ON'),
    ),
  );
  addTearDown(db.close);
  return db;
}

VideoDownloadJobsCompanion _job(
  String id, {
  String fingerprint = 'embedded/default',
  String? torrentHash,
  int priority = 0,
  int maxAttempts = 3,
  String stage = VideoDownloadJobStage.enqueue,
}) =>
    VideoDownloadJobsCompanion.insert(
      jobId: id,
      resourceProvider: 'nyaa',
      selectedResourceId: 'resource-$id',
      magnetUri: Value<String?>('magnet:?xt=urn:btih:$id'),
      torrentHash: Value<String?>(torrentHash),
      metadataProvider: const Value<String?>('anilist'),
      externalId: Value<String?>('media-$id'),
      mediaKind: 'tv',
      discoveryCategory: const Value<String?>('anime'),
      title: 'Show $id',
      year: const Value<int?>(2026),
      season: const Value<int?>(1),
      backendKind: 'embedded',
      backendProfileId: const Value<String?>('default'),
      fingerprint: fingerprint,
      stage: Value<String>(stage),
      priority: Value<int>(priority),
      maxAttempts: Value<int>(maxAttempts),
      createdAt: 10,
      updatedAt: 10,
    );

VideoDownloadSubscriptionsCompanion _subscription(
  String id, {
  String mode = 'ongoing',
  int? nextCheckAt,
}) =>
    VideoDownloadSubscriptionsCompanion.insert(
      subscriptionId: id,
      resourceProvider: 'nyaa',
      metadataProvider: const Value<String?>('anilist'),
      externalId: Value<String?>('media-$id'),
      mediaKind: 'tv',
      discoveryCategory: const Value<String?>('anime'),
      title: 'Show $id',
      searchQuery: 'Show $id',
      mode: Value<String>(mode),
      backendKind: 'embedded',
      backendProfileId: const Value<String?>('default'),
      fingerprint: 'embedded/default',
      nextCheckAt: Value<int?>(nextCheckAt),
      createdAt: 10,
      updatedAt: 10,
    );

void main() {
  test('job CRUD/watch and child tables preserve fields then cascade',
      () async {
    final FushiDatabase db = await _openDb();
    final List<List<VideoDownloadJobRow>> emissions =
        <List<VideoDownloadJobRow>>[];
    final subscription = db.watchVideoDownloadJobs().listen(emissions.add);
    addTearDown(subscription.cancel);
    await pumpEventQueue();
    expect(emissions.single, isEmpty);

    await db.upsertVideoDownloadJob(_job('job-1'));
    await pumpEventQueue();
    final VideoDownloadJobRow job = (await db.getVideoDownloadJob('job-1'))!;
    expect(job.lifecycle, VideoDownloadJobLifecycle.active);
    expect(job.stage, VideoDownloadJobStage.enqueue);
    expect(job.subtitlePolicy, 'bestEffort');
    expect(job.backendProfileId, 'default');
    expect(emissions.last.single.jobId, 'job-1');

    await db.upsertVideoDownloadJobFile(
      VideoDownloadJobFilesCompanion.insert(
        jobId: 'job-1',
        backendFileIndex: const Value<int?>(0),
        originalRelativePath: 'Show/Show 01.mkv',
        currentRelativePath: 'Show/Show 01.mkv',
        kind: const Value<String>('video'),
        season: const Value<int?>(1),
        episode: const Value<int?>(1),
        sizeBytes: const Value<int?>(1000),
        createdAt: 11,
        updatedAt: 11,
      ),
    );
    final VideoDownloadJobFileRow file =
        (await db.getVideoDownloadJobFiles('job-1')).single;
    await db.upsertVideoDownloadJobSubtitle(
      VideoDownloadJobSubtitlesCompanion.insert(
        subtitleId: 'sub-1',
        jobId: 'job-1',
        jobFileId: Value<int?>(file.id),
        provider: 'jimaku',
        language: const Value<String?>('zh'),
        episode: const Value<int?>(1),
        createdAt: 12,
        updatedAt: 12,
      ),
    );
    expect(await db.getVideoDownloadJobSubtitles('job-1'), hasLength(1));

    await db.deleteVideoDownloadJob('job-1');
    expect(await db.getVideoDownloadJobFiles('job-1'), isEmpty);
    expect(await db.getVideoDownloadJobSubtitles('job-1'), isEmpty,
        reason: '删任务必须由 FK cascade 清掉文件和字幕状态');
  });

  test('claim and retry use lease fields without overloading lifecycle/stage',
      () async {
    final FushiDatabase db = await _openDb();
    await db.upsertVideoDownloadJob(_job(
      'retry-job',
      maxAttempts: 2,
      stage: VideoDownloadJobStage.download,
    ));

    final VideoDownloadJobRow first = (await db.claimNextVideoDownloadJob(
      workerId: 'worker-a',
      nowAt: 100,
      leaseDurationMs: 50,
    ))!;
    expect(first.lifecycle, VideoDownloadJobLifecycle.active);
    expect(first.stage, VideoDownloadJobStage.download);
    expect(first.claimedBy, 'worker-a');
    expect(first.attemptCount, 0, reason: '正常 claim/轮询不消耗重试预算');
    expect(
      await db.claimNextVideoDownloadJob(
        workerId: 'worker-b',
        nowAt: 120,
        leaseDurationMs: 50,
      ),
      isNull,
    );

    expect(
      await db.retryVideoDownloadJob(
        jobId: 'retry-job',
        workerId: 'worker-a',
        error: 'temporary',
        nowAt: 130,
        nextAttemptAt: 200,
      ),
      isTrue,
    );
    final VideoDownloadJobRow waiting =
        (await db.getVideoDownloadJob('retry-job'))!;
    expect(waiting.lifecycle, VideoDownloadJobLifecycle.active);
    expect(waiting.stage, VideoDownloadJobStage.download);
    expect(waiting.claimedBy, isNull);
    expect(waiting.nextAttemptAt, 200);

    expect(
      await db.claimNextVideoDownloadJob(
        workerId: 'worker-b',
        nowAt: 199,
        leaseDurationMs: 50,
      ),
      isNull,
    );
    final VideoDownloadJobRow second = (await db.claimNextVideoDownloadJob(
      workerId: 'worker-b',
      nowAt: 200,
      leaseDurationMs: 50,
    ))!;
    expect(second.attemptCount, 1);
    expect(
      await db.retryVideoDownloadJob(
        jobId: 'retry-job',
        workerId: 'worker-b',
        error: 'permanent',
        nowAt: 210,
        nextAttemptAt: 300,
      ),
      isTrue,
    );
    final VideoDownloadJobRow failed =
        (await db.getVideoDownloadJob('retry-job'))!;
    expect(failed.lifecycle, VideoDownloadJobLifecycle.failed);
    expect(failed.stage, VideoDownloadJobStage.download);
    expect(failed.attemptCount, 2);
    expect(failed.completedAt, 210);
  });

  test('stage CAS, release and needsAttention preserve orthogonal state',
      () async {
    final FushiDatabase db = await _openDb();
    await db.upsertVideoDownloadJob(
      _job('stage-job').copyWith(attemptCount: const Value<int>(2)),
    );
    await db.claimNextVideoDownloadJob(
      workerId: 'worker-a',
      nowAt: 20,
      leaseDurationMs: 20,
    );

    expect(
      await db.advanceVideoDownloadJobStage(
        jobId: 'stage-job',
        workerId: 'wrong-worker',
        stage: VideoDownloadJobStage.download,
        nowAt: 21,
      ),
      isFalse,
    );
    expect(
      await db.advanceVideoDownloadJobStage(
        jobId: 'stage-job',
        workerId: 'worker-a',
        stage: VideoDownloadJobStage.download,
        progress: 0.25,
        backendTaskId: 'task-1',
        torrentHash: 'hash-1',
        observedSavePath: r'D:\downloads\Show',
        targetRelativeRoot: 'Show (2026)',
        nowAt: 22,
      ),
      isTrue,
    );
    final VideoDownloadJobRow advanced =
        (await db.getVideoDownloadJob('stage-job'))!;
    expect(advanced.lifecycle, VideoDownloadJobLifecycle.active);
    expect(advanced.stage, VideoDownloadJobStage.download);
    expect(advanced.stageProgress, 0.25);
    expect(advanced.attemptCount, 0, reason: '成功推进到新阶段后，应重置该阶段的错误重试预算');
    expect(advanced.claimedBy, isNull);
    expect(advanced.nextAttemptAt, 22);
    expect(
      await db.findVideoDownloadJobByFingerprintAndTorrentHash(
        advanced.fingerprint,
        'hash-1',
      ),
      isNotNull,
    );

    await db.claimNextVideoDownloadJob(
      workerId: 'worker-b',
      nowAt: 22,
      leaseDurationMs: 20,
    );
    expect(
      await db.releaseVideoDownloadJobClaim(
        jobId: 'stage-job',
        workerId: 'worker-b',
        nowAt: 23,
        nextAttemptAt: 50,
      ),
      isTrue,
    );
    expect(
      await db.claimNextVideoDownloadJob(
        workerId: 'worker-c',
        nowAt: 49,
        leaseDurationMs: 20,
      ),
      isNull,
    );
    await db.claimNextVideoDownloadJob(
      workerId: 'worker-c',
      nowAt: 50,
      leaseDurationMs: 20,
    );
    expect(
      await db.markVideoDownloadJobNeedsAttention(
        jobId: 'stage-job',
        workerId: 'worker-c',
        error: 'choose destination',
        nowAt: 51,
      ),
      isTrue,
    );
    final VideoDownloadJobRow attention =
        (await db.getVideoDownloadJob('stage-job'))!;
    expect(attention.lifecycle, VideoDownloadJobLifecycle.needsAttention);
    expect(attention.stage, VideoDownloadJobStage.download);
    expect(attention.claimedBy, isNull);
  });

  test('fingerprint only deduplicates a known torrent hash', () async {
    final FushiDatabase db = await _openDb();
    await db.upsertVideoDownloadJob(_job('unknown-a'));
    await db.upsertVideoDownloadJob(_job('unknown-b'));
    expect(await db.getVideoDownloadJobs(), hasLength(2),
        reason: 'enqueue 前 hash 为空，不能把同一后端的任务互相吞掉');

    await db.upsertVideoDownloadJob(
      _job('known-a', fingerprint: 'same-backend', torrentHash: 'abc'),
    );
    await expectLater(
      db.upsertVideoDownloadJob(
        _job('known-b', fingerprint: 'same-backend', torrentHash: 'abc'),
      ),
      throwsA(anything),
      reason: 'hash 已知后，同后端同 torrent 必须幂等去重',
    );
    await db.upsertVideoDownloadJob(
      _job('known-c', fingerprint: 'same-backend', torrentHash: 'def'),
    );
  });

  test('subscription lease/retry, oneShot fulfillment and item dedup',
      () async {
    final FushiDatabase db = await _openDb();
    await db.upsertVideoDownloadSubscription(
      _subscription('one-shot', mode: 'oneShot'),
    );
    final VideoDownloadSubscriptionRow claimed =
        (await db.claimNextVideoDownloadSubscription(
      workerId: 'sub-worker',
      nowAt: 100,
      leaseDurationMs: 50,
    ))!;
    expect(claimed.claimedBy, 'sub-worker');
    expect(
      await db.completeVideoDownloadSubscriptionCheck(
        subscriptionId: 'one-shot',
        workerId: 'sub-worker',
        checkedAt: 110,
        nextCheckAt: 1000,
        matchedAt: 109,
        fulfillOneShot: true,
      ),
      isTrue,
    );
    final VideoDownloadSubscriptionRow fulfilled =
        (await db.getVideoDownloadSubscription('one-shot'))!;
    expect(fulfilled.enabled, isFalse);
    expect(fulfilled.fulfilledAt, 110);
    expect(fulfilled.lastMatchedAt, 109);

    await db.upsertVideoDownloadSubscriptionItem(
      VideoDownloadSubscriptionItemsCompanion.insert(
        subscriptionId: 'one-shot',
        logicalItemKey: 'S01E01',
        resourceProvider: 'nyaa',
        selectedResourceId: 'release-a',
        title: 'Show 01',
        season: const Value<int?>(1),
        episode: const Value<int?>(1),
        discoveredAt: 111,
        updatedAt: 111,
      ),
    );
    await db.upsertVideoDownloadSubscriptionItem(
      VideoDownloadSubscriptionItemsCompanion.insert(
        subscriptionId: 'one-shot',
        logicalItemKey: 'S01E01',
        resourceProvider: 'nyaa',
        selectedResourceId: 'release-b',
        title: 'Show 01 v2',
        season: const Value<int?>(1),
        episode: const Value<int?>(1),
        discoveredAt: 112,
        updatedAt: 112,
      ),
    );
    final List<VideoDownloadSubscriptionItemRow> items =
        await db.getVideoDownloadSubscriptionItems('one-shot');
    expect(items, hasLength(1));
    expect(items.single.selectedResourceId, 'release-b',
        reason: '同一逻辑集只能保留一个选中 release');
    await expectLater(
      db.upsertVideoDownloadSubscriptionItem(
        VideoDownloadSubscriptionItemsCompanion.insert(
          subscriptionId: 'one-shot',
          logicalItemKey: 'S01E02',
          resourceProvider: 'nyaa',
          selectedResourceId: 'release-b',
          title: 'Show 02',
          discoveredAt: 113,
          updatedAt: 113,
        ),
      ),
      throwsA(anything),
      reason: '同一 provider/resource 不能伪装成两个逻辑集',
    );

    await db.upsertVideoDownloadSubscription(
      _subscription('ongoing', nextCheckAt: 200),
    );
    expect(
      await db.claimNextVideoDownloadSubscription(
        workerId: 'sub-worker',
        nowAt: 199,
        leaseDurationMs: 50,
      ),
      isNull,
    );
    await db.claimNextVideoDownloadSubscription(
      workerId: 'sub-worker',
      nowAt: 200,
      leaseDurationMs: 50,
    );
    expect(
      await db.retryVideoDownloadSubscriptionCheck(
        subscriptionId: 'ongoing',
        workerId: 'sub-worker',
        error: 'provider timeout',
        failedAt: 210,
        nextCheckAt: 300,
      ),
      isTrue,
    );
    final VideoDownloadSubscriptionRow retrying =
        (await db.getVideoDownloadSubscription('ongoing'))!;
    expect(retrying.retryCount, 1);
    expect(retrying.claimedBy, isNull);
    expect(retrying.nextCheckAt, 300);

    await db.deleteVideoDownloadSubscription('one-shot');
    expect(await db.getVideoDownloadSubscriptionItems('one-shot'), isEmpty);
  });

  test('database constraints reject transient URLs and mixed state axes',
      () async {
    final FushiDatabase db = await _openDb();
    await expectLater(
      db.upsertVideoDownloadJob(
        _job('http-job').copyWith(
          magnetUri:
              const Value<String?>('https://indexer/token/metainfo.torrent'),
        ),
      ),
      throwsA(anything),
      reason: 'Torznab 临时 URL/token 不得持久化',
    );

    await db.upsertVideoDownloadJob(_job('valid'));
    await expectLater(
      db.updateVideoDownloadJob(
        'valid',
        const VideoDownloadJobsCompanion(
          lifecycle: Value<String>('running'),
        ),
      ),
      throwsA(anything),
    );
    await expectLater(
      db.updateVideoDownloadJob(
        'valid',
        const VideoDownloadJobsCompanion(
          stage: Value<String>('completed'),
        ),
      ),
      throwsA(anything),
    );
  });
}
