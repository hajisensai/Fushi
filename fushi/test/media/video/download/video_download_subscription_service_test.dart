import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/common.dart' show CommonDatabase;

import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/torrent/torrent_backend.dart';
import 'package:fushi/src/media/torrent/video_resource_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi/src/media/video/download/video_download_subscription_service.dart';
import 'package:fushi/src/media/video/download/video_resource_registry.dart';

const int _nowAt = 1000;

Future<FushiDatabase> _openDatabase() async {
  final FushiDatabase database = FushiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (CommonDatabase raw) => raw.execute('PRAGMA foreign_keys = ON'),
    ),
  );
  addTearDown(database.close);
  return database;
}

Future<int> _insertVideoSource(FushiDatabase database) =>
    database.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Managed videos',
        mediaKind: 'video',
        rootPath: r'D:\Videos',
        createdAt: _nowAt,
      ),
    );

Future<void> _insertSubscription(
  FushiDatabase database, {
  required String id,
  required int sourceId,
  required String resourceProvider,
  required String mediaKind,
  required String discoveryCategory,
  required Map<String, Object?> filters,
  String mode = 'ongoing',
  int? startAfterEpisode,
  int? season,
}) =>
    database.upsertVideoDownloadSubscription(
      VideoDownloadSubscriptionsCompanion.insert(
        subscriptionId: id,
        resourceProvider: resourceProvider,
        metadataProvider: const Value<String?>('anilist'),
        externalId: Value<String?>('media-$id'),
        mediaKind: mediaKind,
        discoveryCategory: Value<String?>(discoveryCategory),
        title: 'Example Show',
        season: Value<int?>(season),
        searchQuery: 'Example Show',
        filterJson: Value<String>(jsonEncode(filters)),
        mode: Value<String>(mode),
        startAfterEpisode: Value<int?>(startAfterEpisode),
        backendKind: 'embedded',
        backendProfileId: const Value<String?>('embedded'),
        fingerprint: 'backend-fingerprint',
        category: const Value<String?>('fushi-video'),
        targetSourceId: Value<int?>(sourceId),
        createdAt: _nowAt,
        updatedAt: _nowAt,
        nextCheckAt: const Value<int?>(_nowAt),
      ),
    );

Future<String> _persistFakeJob(
  FushiDatabase database,
  VideoDownloadEnqueueRequest request,
  String jobId,
) async {
  await database.upsertVideoDownloadJob(
    VideoDownloadJobsCompanion.insert(
      jobId: jobId,
      resourceProvider: persistedVideoResourceProviderId(request.resource),
      selectedResourceId: request.resource.remoteId,
      resourceTitle: Value<String?>(request.resource.title),
      torrentHash: Value<String?>(request.resource.infoHash),
      metadataProvider: Value<String?>(request.media.providerId),
      externalId: Value<String?>(request.media.mediaId),
      mediaKind: request.media.mediaKind.name,
      discoveryCategory: Value<String?>(request.media.discoveryCategory.name),
      title: request.media.title,
      season: Value<int?>(request.media.season),
      backendKind: request.backendIdentity.kind,
      backendProfileId: Value<String?>(request.backendIdentity.profileId),
      fingerprint: request.backendIdentity.fingerprint,
      category: Value<String?>(request.backendIdentity.category),
      targetSourceId: Value<int?>(request.targetSourceId),
      subtitlePolicy: Value<String>(request.subtitlePolicy.name),
      createdAt: _nowAt,
      updatedAt: _nowAt,
    ),
  );
  return jobId;
}

VideoDownloadSubscriptionService _service({
  required FushiDatabase database,
  required VideoResourceProvider provider,
  required VideoDownloadSubscriptionEnqueue enqueue,
  Duration checkInterval = const Duration(minutes: 15),
  Duration leaseDuration = const Duration(minutes: 2),
  int autoRetryBudget = kVideoDownloadSubscriptionAutoRetryBudget,
  DateTime Function()? now,
}) {
  final VideoDownloadSubscriptionService service =
      VideoDownloadSubscriptionService(
    database: database,
    resourceRegistry: VideoResourceRegistry(<VideoResourceProvider>[provider]),
    enqueue: enqueue,
    workerId: 'subscription-test-worker',
    checkInterval: checkInterval,
    leaseDuration: leaseDuration,
    autoRetryBudget: autoRetryBudget,
    now: now ?? () => DateTime.fromMillisecondsSinceEpoch(_nowAt),
  );
  addTearDown(service.dispose);
  return service;
}

void main() {
  test(
      'Nyaa strict rules include the selected first episode and persist outbox',
      () async {
    final FushiDatabase database = await _openDatabase();
    final int sourceId = await _insertVideoSource(database);
    await _insertSubscription(
      database,
      id: 'anime',
      sourceId: sourceId,
      resourceProvider: 'nyaa',
      mediaKind: 'tv',
      discoveryCategory: 'anime',
      season: 1,
      startAfterEpisode: 1,
      filters: <String, Object?>{
        'strict': true,
        'releaseGroup': 'SubsPlease',
        'resolution': '1080p',
        'trustedOnly': true,
        'nyaaCategory': '1_2',
      },
    );
    final _FakeResourceProvider provider = _FakeResourceProvider(
      id: 'nyaa',
      candidates: <VideoResourceCandidate>[
        _candidate(remoteId: 'old', episode: 1),
        _candidate(remoteId: 'wrong-group', episode: 2, group: 'Other'),
        _candidate(
            remoteId: 'wrong-resolution', episode: 2, resolution: '720p'),
        _candidate(remoteId: 'untrusted', episode: 2, trusted: false),
        _candidate(remoteId: 'episode-2-low', episode: 2, seeders: 2),
        _candidate(remoteId: 'episode-2-best', episode: 2, seeders: 20),
        _candidate(remoteId: 'episode-3', episode: 3, seeders: 5),
      ],
    );
    final List<VideoDownloadEnqueueRequest> enqueued =
        <VideoDownloadEnqueueRequest>[];
    final VideoDownloadSubscriptionService service = _service(
      database: database,
      provider: provider,
      enqueue: (VideoDownloadEnqueueRequest request) async {
        final List<VideoDownloadSubscriptionItemRow> outbox =
            await database.getVideoDownloadSubscriptionItems('anime');
        expect(
          outbox.any(
            (VideoDownloadSubscriptionItemRow item) =>
                item.selectedResourceId == request.resource.remoteId &&
                item.status == VideoDownloadSubscriptionItemStatus.discovered,
          ),
          isTrue,
          reason: 'enqueue 外部动作前必须先持久化逻辑集选择',
        );
        enqueued.add(request);
        return _persistFakeJob(
          database,
          request,
          'job-${enqueued.length}',
        );
      },
    );

    await service.checkNow();

    expect(service.checkInterval, const Duration(minutes: 15));
    expect(
      enqueued
          .map((VideoDownloadEnqueueRequest value) => value.resource.remoteId),
      <String>['old', 'episode-2-best', 'episode-3'],
    );
    final List<VideoDownloadSubscriptionItemRow> items =
        await database.getVideoDownloadSubscriptionItems('anime');
    expect(
      items.map(
          (VideoDownloadSubscriptionItemRow value) => value.logicalItemKey),
      <String>['S01E01', 'S01E02', 'S01E03'],
    );
    expect(
      items.every(
        (VideoDownloadSubscriptionItemRow item) =>
            item.status == VideoDownloadSubscriptionItemStatus.queued &&
            item.jobId != null,
      ),
      isTrue,
    );
    final VideoDownloadSubscriptionRow row =
        (await database.getVideoDownloadSubscription('anime'))!;
    expect(
        row.nextCheckAt, _nowAt + const Duration(minutes: 15).inMilliseconds);
    expect(row.retryCount, 0);
    expect(row.lastError, isNull);
  });

  /// BUG-1746：订阅曾把「派过任务」（jobId != null）当成「这一集搞定了」。
  /// 任务被取消或失败之后 jobId 依然挂在条目上，旧判据每轮都 continue，那一集
  /// 就再也不会被下——用户看到的是「订阅只下了中间几集」，而面板上毫无异常。
  /// 实测现场：某条订阅 13 集里 ep01/02 卡在「内置下载引擎运行时缺失」、
  /// ep03-08 被取消，全部再没重试过。
  ///
  /// 分界线按「是谁决定不下的」划：系统故障该重试，用户取消该尊重。
  group('BUG-1746 订阅重试判据', () {
    /// 跑一轮订阅检查，返回本轮入队的 remoteId。
    ///
    /// [atMs] 必须随轮次前进：`_drain()` 只认领**已到期**的订阅
    /// （`claimNextVideoDownloadSubscription(nowAt:)`），第一轮跑完
    /// `nextCheckAt = 当前 + checkInterval`。若两轮用同一个时刻，第二轮根本
    /// 认领不到订阅、整轮空转——那样「没有重复入队」的断言会变成假绿，
    /// 测的是「压根没跑」而不是「跑了但正确地没派」。
    Future<List<String>> runRound(
      FushiDatabase database, {
      required List<String> alreadyEnqueued,
      required int atMs,
    }) async {
      final List<String> enqueued = <String>[];
      final VideoDownloadSubscriptionService service = _service(
        database: database,
        now: () => DateTime.fromMillisecondsSinceEpoch(atMs),
        provider: _FakeResourceProvider(
          id: 'nyaa',
          candidates: <VideoResourceCandidate>[
            _candidate(remoteId: 'ep-1', episode: 1),
          ],
        ),
        enqueue: (VideoDownloadEnqueueRequest request) async {
          enqueued.add(request.resource.remoteId);
          return _persistFakeJob(
            database,
            request,
            'job-${alreadyEnqueued.length + enqueued.length}',
          );
        },
      );
      await service.checkNow();
      return enqueued;
    }

    /// 第二轮的时刻：第一轮的 nextCheckAt 之后。
    const int secondRoundAt = _nowAt + 3600 * 1000;

    Future<FushiDatabase> seed() async {
      final FushiDatabase database = await _openDatabase();
      final int sourceId = await _insertVideoSource(database);
      await _insertSubscription(
        database,
        id: 'anime',
        sourceId: sourceId,
        resourceProvider: 'nyaa',
        mediaKind: 'tv',
        discoveryCategory: 'anime',
        season: 1,
        startAfterEpisode: 1,
        filters: <String, Object?>{
          'strict': true,
          'releaseGroup': 'SubsPlease',
          'resolution': '1080p',
          'trustedOnly': true,
          'nyaaCategory': '1_2',
        },
      );
      return database;
    }

    /// 直接改 lifecycle：生产里由流水线/用户操作写，这里只关心订阅怎么读它。
    Future<void> setLifecycle(
      FushiDatabase database,
      String jobId,
      String lifecycle,
    ) =>
        database.customStatement(
          'UPDATE video_download_jobs SET lifecycle = ? WHERE job_id = ?',
          <Object?>[lifecycle, jobId],
        );

    /// 「重新派」的落地形式是**恢复既有任务**，不是再造一份：任务表对
    /// (fingerprint, resourceProvider, selectedResourceId) 没有唯一约束，克隆
    /// 会在持续性故障下每轮堆一条死任务行。
    Future<void> expectRevivedInPlace(FushiDatabase database) async {
      final List<VideoDownloadJobRow> jobs =
          await database.getVideoDownloadJobs();
      expect(jobs, hasLength(1), reason: '恢复既有任务，不能克隆出第二条任务行');
      expect(jobs.single.jobId, 'job-1');
      expect(jobs.single.lifecycle, VideoDownloadJobLifecycle.active,
          reason: '故障态的既有任务必须被放回 active，这一集才会真的继续下');
      final VideoDownloadSubscriptionItemRow item =
          (await database.getVideoDownloadSubscriptionItems('anime')).single;
      expect(item.jobId, 'job-1', reason: '条目仍绑在同一条任务上');
      expect(item.status, VideoDownloadSubscriptionItemStatus.queued);
    }

    test('needsAttention（系统故障）的一集会在下一轮被恢复', () async {
      final FushiDatabase database = await seed();
      final List<String> first =
          await runRound(database, alreadyEnqueued: <String>[], atMs: _nowAt);
      expect(first, <String>['ep-1'], reason: '第一轮应正常入队');

      await setLifecycle(
        database,
        'job-1',
        VideoDownloadJobLifecycle.needsAttention,
      );

      final List<String> second =
          await runRound(database, alreadyEnqueued: first, atMs: secondRoundAt);
      expect(second, isEmpty,
          reason: 'needsAttention 的后端 torrent 可能还在跑，再派一份同 magnet 的'
              '任务会让两条工作流指向同一个 infohash');
      await expectRevivedInPlace(database);
    });

    test('failed 的一集同样会被恢复', () async {
      final FushiDatabase database = await seed();
      final List<String> first =
          await runRound(database, alreadyEnqueued: <String>[], atMs: _nowAt);
      expect(first, <String>['ep-1']);

      await setLifecycle(database, 'job-1', VideoDownloadJobLifecycle.failed);

      expect(
          await runRound(database, alreadyEnqueued: first, atMs: secondRoundAt),
          isEmpty,
          reason: 'failed 是系统侧的失败，不是用户意图；但恢复既有任务即可，'
              '不需要克隆');
      await expectRevivedInPlace(database);
    });

    test('用户取消（cancelled）的一集不会被订阅自动补回来', () async {
      final FushiDatabase database = await seed();
      final List<String> first =
          await runRound(database, alreadyEnqueued: <String>[], atMs: _nowAt);
      expect(first, <String>['ep-1']);

      await setLifecycle(
        database,
        'job-1',
        VideoDownloadJobLifecycle.cancelled,
      );

      expect(
          await runRound(database, alreadyEnqueued: first, atMs: secondRoundAt),
          isEmpty,
          reason: 'cancelled 是用户明确说不要这一集；自动补回来的话用户永远取消不掉');
    });

    test('active / completed 的一集不重复入队（原行为不变）', () async {
      for (final String lifecycle in <String>[
        VideoDownloadJobLifecycle.active,
        VideoDownloadJobLifecycle.completed,
      ]) {
        final FushiDatabase database = await seed();
        final List<String> first =
            await runRound(database, alreadyEnqueued: <String>[], atMs: _nowAt);
        expect(first, <String>['ep-1']);

        await setLifecycle(database, 'job-1', lifecycle);

        expect(
            await runRound(database,
                alreadyEnqueued: first, atMs: secondRoundAt),
            isEmpty,
            reason: '$lifecycle 的任务仍算数，重复入队会造重复下载');
      }
    });
  });

  /// PR#915 修 BUG-1746 时拆掉了 `if (item.jobId != null) return true;`，但没有
  /// 补上替代闸门，于是留下两个新缺陷：
  ///
  /// - **克隆风暴**：复用循环对 failed / needsAttention 的旧任务 `continue`，
  ///   落到 `pipeline.enqueue` —— 而 enqueue 每次调用都
  ///   `generateVideoDownloadInstallationId()` 生成全新 jobId，`VideoDownloadJobs`
  ///   对 (fingerprint, resourceProvider, selectedResourceId) / torrentHash 没有
  ///   任何唯一约束。生产 checkInterval 是 15 分钟，一个持续性故障（实测例：
  ///   内置下载引擎运行时缺失）≈ 每集每天 96 条死任务行，面板永不收敛。
  /// - **同 torrent 双任务**：needsAttention 是「需要用户处理的可恢复状态」，
  ///   backendTaskId 还在、后端 torrent 可能仍在跑，再派一份同 magnet 的任务会
  ///   让两条持久工作流指向同一个 infohash，各自 organize/import。
  ///
  /// 修法是「恢复既有任务 + 持久上限」，上限的账本落在任务自己的 attemptCount
  /// 上（内存计数进程重启就归零，等于没有上限）。
  group('订阅自动重派恢复既有任务并受持久上限约束', () {
    /// 压到 2 只是为了少跑两轮；生产真值是
    /// [kVideoDownloadSubscriptionAutoRetryBudget]。
    const int autoRetryBudget = 2;

    /// 每轮之间要真的前进时钟：`_drain()` 只认领已到期的订阅，同一时刻跑第二轮
    /// 会整轮空转，「没有克隆」的断言就变成假绿（测的是「压根没跑」）。
    int roundAt(int round) => _nowAt + round * 3600 * 1000;

    Future<FushiDatabase> seed() async {
      final FushiDatabase database = await _openDatabase();
      final int sourceId = await _insertVideoSource(database);
      await _insertSubscription(
        database,
        id: 'anime',
        sourceId: sourceId,
        resourceProvider: 'nyaa',
        mediaKind: 'tv',
        discoveryCategory: 'anime',
        season: 1,
        startAfterEpisode: 1,
        filters: <String, Object?>{
          'strict': true,
          'releaseGroup': 'SubsPlease',
          'resolution': '1080p',
          'trustedOnly': true,
          'nyaaCategory': '1_2',
        },
      );
      return database;
    }

    /// 模拟「故障没排除」：把这一集当前的任务打回故障态。生产里由流水线写，
    /// 这里只关心订阅怎么读它。
    Future<void> breakJob(
      FushiDatabase database,
      String jobId,
      String lifecycle,
    ) =>
        database.customStatement(
          'UPDATE video_download_jobs SET lifecycle = ? WHERE job_id = ?',
          <Object?>[lifecycle, jobId],
        );

    /// 跑一轮检查。[enqueuedJobIds] 累积**真的新建了任务**的 jobId —— 判克隆看
    /// 它，不要只看任务总数：两者只有在缺陷存在时才会分叉。
    Future<void> runRound(
      FushiDatabase database, {
      required int round,
      required List<String> enqueuedJobIds,
    }) async {
      final VideoDownloadSubscriptionService service = _service(
        database: database,
        autoRetryBudget: autoRetryBudget,
        now: () => DateTime.fromMillisecondsSinceEpoch(roundAt(round)),
        provider: _FakeResourceProvider(
          id: 'nyaa',
          candidates: <VideoResourceCandidate>[
            _candidate(remoteId: 'ep-1', episode: 1),
          ],
        ),
        enqueue: (VideoDownloadEnqueueRequest request) async {
          final String jobId = 'job-${enqueuedJobIds.length + 1}';
          enqueuedJobIds.add(jobId);
          return _persistFakeJob(database, request, jobId);
        },
      );
      await service.checkNow();
    }

    test('持续故障下任务行数不随轮次增长', () async {
      final FushiDatabase database = await seed();
      final List<String> enqueuedJobIds = <String>[];
      await runRound(database, round: 0, enqueuedJobIds: enqueuedJobIds);
      expect(enqueuedJobIds, <String>['job-1'], reason: '第一轮应正常入队');

      for (int round = 1; round <= 5; round++) {
        await breakJob(
          database,
          'job-1',
          VideoDownloadJobLifecycle.needsAttention,
        );
        await runRound(database, round: round, enqueuedJobIds: enqueuedJobIds);
      }

      expect(enqueuedJobIds, <String>['job-1'],
          reason: '后续每一轮都必须走「恢复既有任务」，不能再 enqueue 一份克隆');
      expect(await database.getVideoDownloadJobs(), hasLength(1),
          reason: '15 分钟一轮的持续故障不能每轮往面板堆一条死任务行');
    });

    test('恢复的是既有任务：jobId 不变、生命周期回到 active', () async {
      final FushiDatabase database = await seed();
      final List<String> enqueuedJobIds = <String>[];
      await runRound(database, round: 0, enqueuedJobIds: enqueuedJobIds);
      await breakJob(database, 'job-1', VideoDownloadJobLifecycle.failed);
      final VideoDownloadJobRow before =
          (await database.getVideoDownloadJobs()).single;

      await runRound(database, round: 1, enqueuedJobIds: enqueuedJobIds);

      final VideoDownloadJobRow after =
          (await database.getVideoDownloadJobs()).single;
      expect(after.jobId, before.jobId, reason: '恢复的必须是同一条任务，不是新任务');
      expect(after.lifecycle, VideoDownloadJobLifecycle.active);
      expect(after.attemptCount, greaterThan(before.attemptCount),
          reason: '自动重派要消耗持久预算，否则上限无从计数');
      expect(after.stage, before.stage,
          reason: '不倒回 enqueue：后端任务可能还在跑，别把同一个种子推第二遍');
      final VideoDownloadSubscriptionItemRow item =
          (await database.getVideoDownloadSubscriptionItems('anime')).single;
      expect(item.jobId, before.jobId);
      expect(item.status, VideoDownloadSubscriptionItemStatus.queued);
    });

    test('needsAttention 期间不会造出指向同一个 torrent 的第二条任务', () async {
      final FushiDatabase database = await seed();
      final List<String> enqueuedJobIds = <String>[];
      await runRound(database, round: 0, enqueuedJobIds: enqueuedJobIds);
      await breakJob(
        database,
        'job-1',
        VideoDownloadJobLifecycle.needsAttention,
      );

      await runRound(database, round: 1, enqueuedJobIds: enqueuedJobIds);

      final List<VideoDownloadJobRow> jobs =
          await database.getVideoDownloadJobs();
      final String? torrentHash = jobs.single.torrentHash;
      expect(torrentHash, isNotNull, reason: '这条用例要真的有 infohash 才有意义');
      expect(
        jobs.where(
          (VideoDownloadJobRow job) => job.torrentHash == torrentHash,
        ),
        hasLength(1),
        reason: 'qBittorrent 按 infohash 去重，两条任务会各自 organize/import '
            '同一份文件',
      );
    });

    test('借满自动重派预算后停在 needsAttention 等用户处理', () async {
      final FushiDatabase database = await seed();
      final List<String> enqueuedJobIds = <String>[];
      await runRound(database, round: 0, enqueuedJobIds: enqueuedJobIds);

      for (int round = 1; round <= autoRetryBudget; round++) {
        await breakJob(
          database,
          'job-1',
          VideoDownloadJobLifecycle.needsAttention,
        );
        await runRound(database, round: round, enqueuedJobIds: enqueuedJobIds);
        expect((await database.getVideoDownloadJobs()).single.lifecycle,
            VideoDownloadJobLifecycle.active,
            reason: '预算内的第 $round 次自动重派应当成功');
      }

      await breakJob(
        database,
        'job-1',
        VideoDownloadJobLifecycle.needsAttention,
      );
      await runRound(
        database,
        round: autoRetryBudget + 1,
        enqueuedJobIds: enqueuedJobIds,
      );

      final VideoDownloadJobRow job =
          (await database.getVideoDownloadJobs()).single;
      expect(job.lifecycle, VideoDownloadJobLifecycle.needsAttention,
          reason: '预算借满后必须停下等人处理，不能无限自动重试');
      expect(enqueuedJobIds, <String>['job-1'],
          reason: '停下不等于换个方式重来：也不许改走 enqueue 造克隆');
    });

    /// [附] `_managedEpisodeKeys` 原本只排除 cancelled/failed，**保留了
    /// needsAttention**。于是一条卡在 needsAttention、但文件已经下好的任务，会在
    /// 文件级把自己的订阅条目判成「已经有人管」而走 `_markItemSkipped` —— 那是个
    /// 终态写入，此后 `subscriptionItemStillClaimed` 永远返回 true，这一集被静默
    /// 判了永久跳过（needsAttention 这一半在这条路径上根本没人再管）。
    test('needsAttention 任务已下好的文件不会把这一集静默判成永久跳过', () async {
      final FushiDatabase database = await seed();
      final List<String> enqueuedJobIds = <String>[];
      await runRound(database, round: 0, enqueuedJobIds: enqueuedJobIds);

      // 这条任务已经把 S01E01 下好了，但整条任务卡在「需要用户处理」。
      await database.upsertVideoDownloadJobFile(
        VideoDownloadJobFilesCompanion.insert(
          jobId: 'job-1',
          originalRelativePath: 'Example.S01E01.mkv',
          currentRelativePath: 'Example.S01E01.mkv',
          kind: const Value<String>('video'),
          season: const Value<int?>(1),
          episode: const Value<int?>(1),
          status: const Value<String>(VideoDownloadJobFileStatus.downloaded),
          createdAt: _nowAt,
          updatedAt: _nowAt,
        ),
      );
      await breakJob(
        database,
        'job-1',
        VideoDownloadJobLifecycle.needsAttention,
      );

      await runRound(database, round: 1, enqueuedJobIds: enqueuedJobIds);

      final VideoDownloadSubscriptionItemRow item =
          (await database.getVideoDownloadSubscriptionItems('anime')).single;
      expect(item.status, isNot(VideoDownloadSubscriptionItemStatus.skipped),
          reason: 'skipped 是终态写入，这一集会被永久判跳过，'
              '而它其实只是卡在需要用户处理的任务上');
      expect(item.status, VideoDownloadSubscriptionItemStatus.queued);
      expect((await database.getVideoDownloadJobs()).single.lifecycle,
          VideoDownloadJobLifecycle.active,
          reason: '正确的处理是恢复这条卡住的任务，让它把文件走完 import');
    });

    test('用户在面板重试后自动预算恢复（人工干预是唯一的复位入口）', () async {
      final FushiDatabase database = await seed();
      final List<String> enqueuedJobIds = <String>[];
      await runRound(database, round: 0, enqueuedJobIds: enqueuedJobIds);
      for (int round = 1; round <= autoRetryBudget + 1; round++) {
        await breakJob(
          database,
          'job-1',
          VideoDownloadJobLifecycle.needsAttention,
        );
        await runRound(database, round: round, enqueuedJobIds: enqueuedJobIds);
      }
      expect((await database.getVideoDownloadJobs()).single.lifecycle,
          VideoDownloadJobLifecycle.needsAttention);

      // 面板的重试按钮（`_canRetry` 正是针对 needsAttention / failed）。
      expect(
        await database.retryVideoDownloadJobByUser(
          jobId: 'job-1',
          nowAt: roundAt(autoRetryBudget + 2),
        ),
        isTrue,
      );
      await breakJob(
        database,
        'job-1',
        VideoDownloadJobLifecycle.needsAttention,
      );
      await runRound(
        database,
        round: autoRetryBudget + 3,
        enqueuedJobIds: enqueuedJobIds,
      );

      expect((await database.getVideoDownloadJobs()).single.lifecycle,
          VideoDownloadJobLifecycle.active,
          reason: 'retryVideoDownloadJobByUser 把 attemptCount 清零，'
              '自动预算随之复位——不需要第二处状态');
    });
  });

  test('anime roman numeral title uses the canonical third-season key',
      () async {
    final FushiDatabase database = await _openDatabase();
    final int sourceId = await _insertVideoSource(database);
    await _insertSubscription(
      database,
      id: 'mushoku-iii',
      sourceId: sourceId,
      resourceProvider: 'nyaa',
      mediaKind: 'tv',
      discoveryCategory: 'anime',
      startAfterEpisode: 1,
      filters: <String, Object?>{
        'strict': true,
        'releaseGroup': 'Erai-raws',
        'resolution': '1080p',
        'trustedOnly': true,
      },
    );
    final List<VideoDownloadEnqueueRequest> enqueued =
        <VideoDownloadEnqueueRequest>[];
    final VideoDownloadSubscriptionService service = _service(
      database: database,
      provider: _FakeResourceProvider(
        id: 'nyaa',
        candidates: <VideoResourceCandidate>[
          _candidate(
            remoteId: 'mushoku-iii-02',
            mediaTitle: '[Erai-raws] Mushoku Tensei III: '
                'Isekai Ittara Honki Dasu - 02 [1080p]',
            group: 'Erai-raws',
          ),
        ],
      ),
      enqueue: (VideoDownloadEnqueueRequest request) async {
        enqueued.add(request);
        return _persistFakeJob(database, request, 'mushoku-iii-job');
      },
    );

    await service.checkNow();

    expect(enqueued, hasLength(1));
    expect(enqueued.single.media.season, 3);
    expect(enqueued.single.media.episode, 2);
    final VideoDownloadSubscriptionItemRow item =
        (await database.getVideoDownloadSubscriptionItems('mushoku-iii'))
            .single;
    expect(item.logicalItemKey, 'S03E02');
    expect(item.season, 3);
    expect(item.episode, 2);
  });

  test('confirmed local episode is skipped before another release is enqueued',
      () async {
    final FushiDatabase database = await _openDatabase();
    final int sourceId = await _insertVideoSource(database);
    await _insertSubscription(
      database,
      id: 'local-episode',
      sourceId: sourceId,
      resourceProvider: 'nyaa',
      mediaKind: 'tv',
      discoveryCategory: 'anime',
      startAfterEpisode: 1,
      filters: <String, Object?>{
        'strict': true,
        'releaseGroup': 'Erai-raws',
        'resolution': '1080p',
        'trustedOnly': true,
      },
    );
    final int collectionId = await database.createMediaCollection(
      'Mushoku Tensei III',
      collectionType: 'playlist',
    );
    await database.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value<String>('video/mushoku-iii-s03e02'),
        title: const Value<String>('Mushoku Tensei III - S03E02'),
        videoPath: const Value<String>(r'D:\Videos\Mushoku.S03E02.mkv'),
        sourceId: Value<int?>(sourceId),
      ),
    );
    await database.addToCollection(
      collectionId,
      MediaKind.video,
      'video/mushoku-iii-s03e02',
    );
    final int workId = await database.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        collectionId: Value<int?>(collectionId),
        mediaType: 'tv',
        title: 'Mushoku Tensei III',
        updatedAt: _nowAt,
      ),
    );
    await database.replaceVideoMetadataProviderIdentities(
      workId: workId,
      identities: <VideoMetadataProviderIdentitiesCompanion>[
        VideoMetadataProviderIdentitiesCompanion.insert(
          identityKey: 'work:$workId:anilist',
          provider: 'anilist',
          externalId: 'media-local-episode',
          isPrimary: const Value<bool>(true),
          updatedAt: _nowAt,
        ),
      ],
    );
    int enqueueCount = 0;
    final VideoDownloadSubscriptionService service = _service(
      database: database,
      provider: _FakeResourceProvider(
        id: 'nyaa',
        candidates: <VideoResourceCandidate>[
          _candidate(
            remoteId: 'duplicate-s03e02',
            mediaTitle: '[Erai-raws] Mushoku Tensei III: '
                'Isekai Ittara Honki Dasu - 02 [1080p]',
            group: 'Erai-raws',
          ),
        ],
      ),
      enqueue: (VideoDownloadEnqueueRequest _) async {
        enqueueCount++;
        return 'unexpected-job';
      },
    );

    await service.checkNow();

    expect(enqueueCount, 0);
    final VideoDownloadSubscriptionItemRow item =
        (await database.getVideoDownloadSubscriptionItems('local-episode'))
            .single;
    expect(item.logicalItemKey, 'S03E02');
    expect(item.status, VideoDownloadSubscriptionItemStatus.skipped);
    expect(item.jobId, isNull);
  });

  test('explicit Nyaa backfill traverses beyond 100 releases continuously',
      () async {
    final FushiDatabase database = await _openDatabase();
    final int sourceId = await _insertVideoSource(database);
    await _insertSubscription(
      database,
      id: 'anime-backfill',
      sourceId: sourceId,
      resourceProvider: 'nyaa',
      mediaKind: 'tv',
      discoveryCategory: 'anime',
      season: 1,
      startAfterEpisode: 70,
      filters: <String, Object?>{
        'strict': true,
        'releaseGroup': 'SubsPlease',
        'resolution': '1080p',
        'trustedOnly': true,
      },
    );
    final List<VideoResourceCandidate> firstPage = <VideoResourceCandidate>[
      _candidate(remoteId: 'p1-100-low', episode: 100, seeders: 1),
      ...List<VideoResourceCandidate>.generate(
        74,
        (int index) {
          final int episode = 127 + index;
          return _candidate(
            remoteId: 'p1-$episode',
            episode: episode,
            seeders: episode,
          );
        },
      ),
    ];
    final List<VideoResourceCandidate> secondPage = <VideoResourceCandidate>[
      ...List<VideoResourceCandidate>.generate(
        56,
        (int index) {
          final int episode = 71 + index;
          return _candidate(
            remoteId: 'p2-$episode',
            episode: episode,
            seeders: episode == 100 ? 500 : episode,
          );
        },
      ),
      _candidate(
        remoteId: 'p2-101-wrong-group',
        episode: 101,
        group: 'Other',
        seeders: 9999,
      ),
    ];
    final _FakeResourceProvider provider = _FakeResourceProvider(
      id: 'nyaa',
      resultsByPage: <int, ProviderBatchResult<VideoResourceCandidate>>{
        1: ProviderBatchResult<VideoResourceCandidate>.success(firstPage),
        2: ProviderBatchResult<VideoResourceCandidate>.success(secondPage),
      },
    );
    final List<VideoDownloadEnqueueRequest> enqueued =
        <VideoDownloadEnqueueRequest>[];
    final VideoDownloadSubscriptionService service = _service(
      database: database,
      provider: provider,
      enqueue: (VideoDownloadEnqueueRequest request) async {
        enqueued.add(request);
        return _persistFakeJob(
          database,
          request,
          'backfill-job-${enqueued.length}',
        );
      },
    );

    await service.checkNow();

    expect(provider.requestedPages, <int>[1, 2]);
    expect(provider.requestedLimits, everyElement(75));
    expect(enqueued, hasLength(130));
    final List<int> episodes = enqueued
        .map((VideoDownloadEnqueueRequest request) => request.media.episode!)
        .toList()
      ..sort();
    expect(episodes, List<int>.generate(130, (int index) => index + 71));
    expect(
      enqueued
          .singleWhere(
            (VideoDownloadEnqueueRequest request) =>
                request.media.episode == 100,
          )
          .resource
          .remoteId,
      'p2-100',
      reason: '同一 SxxExx 必须跨页选严格规则内的最佳版本且只入队一次',
    );
    expect(
      enqueued
          .singleWhere(
            (VideoDownloadEnqueueRequest request) =>
                request.media.episode == 101,
          )
          .resource
          .remoteId,
      'p2-101',
      reason: '后续页的高做种错误发布组不能绕过严格版本锁定',
    );
    final List<VideoDownloadSubscriptionItemRow> items =
        await database.getVideoDownloadSubscriptionItems('anime-backfill');
    expect(items, hasLength(130));
    expect(
      items
          .map((VideoDownloadSubscriptionItemRow item) => item.logicalItemKey)
          .toSet(),
      hasLength(130),
    );
  });

  test('a repeated full provider page stops pagination without duplicate jobs',
      () async {
    final FushiDatabase database = await _openDatabase();
    final int sourceId = await _insertVideoSource(database);
    await _insertSubscription(
      database,
      id: 'anime-repeat-page',
      sourceId: sourceId,
      resourceProvider: 'nyaa',
      mediaKind: 'tv',
      discoveryCategory: 'anime',
      season: 1,
      filters: <String, Object?>{
        'strict': true,
        'releaseGroup': 'SubsPlease',
        'resolution': '1080p',
        'trustedOnly': true,
      },
    );
    final List<VideoResourceCandidate> repeated =
        List<VideoResourceCandidate>.generate(
      75,
      (int index) => _candidate(
        remoteId: 'repeat-${index + 1}',
        episode: index + 1,
      ),
    );
    final _FakeResourceProvider provider = _FakeResourceProvider(
      id: 'nyaa',
      resultsByPage: <int, ProviderBatchResult<VideoResourceCandidate>>{
        1: ProviderBatchResult<VideoResourceCandidate>.success(repeated),
        2: ProviderBatchResult<VideoResourceCandidate>.success(repeated),
      },
    );
    int enqueueCount = 0;
    final VideoDownloadSubscriptionService service = _service(
      database: database,
      provider: provider,
      enqueue: (VideoDownloadEnqueueRequest request) async {
        enqueueCount++;
        return _persistFakeJob(database, request, 'repeat-job-$enqueueCount');
      },
    );

    await service.checkNow();

    expect(provider.requestedPages, <int>[1, 2]);
    expect(enqueueCount, 75);
    expect(
      await database.getVideoDownloadSubscriptionItems('anime-repeat-page'),
      hasLength(75),
    );
  });

  test('full changing pages stop at the bounded per-check safety limit',
      () async {
    final FushiDatabase database = await _openDatabase();
    final int sourceId = await _insertVideoSource(database);
    await _insertSubscription(
      database,
      id: 'anime-page-cap',
      sourceId: sourceId,
      resourceProvider: 'nyaa',
      mediaKind: 'tv',
      discoveryCategory: 'anime',
      season: 1,
      filters: <String, Object?>{
        'strict': true,
        'releaseGroup': 'SubsPlease',
        'resolution': '1080p',
        'trustedOnly': true,
      },
    );
    final Map<int, ProviderBatchResult<VideoResourceCandidate>> pages =
        <int, ProviderBatchResult<VideoResourceCandidate>>{};
    for (int page = 1; page <= 20; page++) {
      pages[page] = ProviderBatchResult<VideoResourceCandidate>.success(
        List<VideoResourceCandidate>.generate(75, (int index) {
          final int release = page * 100 + index;
          return _FakeResourceCandidate(
            providerId: 'nyaa',
            instanceId: 'nyaa.si',
            remoteId: 'page-$page-release-$index',
            title: '[SubsPlease] Example Show - 1 [1080p]',
            infoHash: release.toRadixString(16).padLeft(40, '0'),
            releaseGroup: 'SubsPlease',
            resolution: '1080p',
            trusted: true,
            seeders: release,
            category: '1_2',
          );
        }),
      );
    }
    final _FakeResourceProvider provider = _FakeResourceProvider(
      id: 'nyaa',
      resultsByPage: pages,
    );
    int enqueueCount = 0;
    final VideoDownloadSubscriptionService service = _service(
      database: database,
      provider: provider,
      enqueue: (VideoDownloadEnqueueRequest request) async {
        enqueueCount++;
        return _persistFakeJob(database, request, 'page-cap-job');
      },
    );

    await service.checkNow();

    expect(provider.requestedPages, List<int>.generate(20, (int i) => i + 1));
    expect(enqueueCount, 1, reason: '1,500 个版本仍只能生成一个 S01E01 逻辑项');
  });

  test(
      'oneShot reconciles a persisted job after crash and never enqueues twice',
      () async {
    final FushiDatabase database = await _openDatabase();
    final int sourceId = await _insertVideoSource(database);
    await _insertSubscription(
      database,
      id: 'movie',
      sourceId: sourceId,
      resourceProvider: 'torznab:indexer-a',
      mediaKind: 'movie',
      discoveryCategory: 'movie',
      mode: 'oneShot',
      filters: <String, Object?>{
        'strict': true,
        'quality': '1080p',
        'source': 'WEB-DL',
        'codec': 'HEVC',
        'language': 'Dual Audio',
      },
    );
    final VideoResourceCandidate candidate = _candidate(
      providerId: 'torznab',
      instanceId: 'indexer-a',
      remoteId: 'movie-release',
      mediaTitle: 'Example Movie 1080p WEB-DL x265 Dual-Audio',
      episode: null,
      group: null,
      resolution: null,
      category: 'movies',
    );
    await database.upsertVideoDownloadSubscriptionItem(
      VideoDownloadSubscriptionItemsCompanion.insert(
        subscriptionId: 'movie',
        logicalItemKey: 'movie',
        resourceProvider: 'torznab:indexer-a',
        selectedResourceId: candidate.remoteId,
        torrentHash: Value<String?>(candidate.infoHash),
        title: candidate.title,
        discoveredAt: _nowAt,
        updatedAt: _nowAt,
      ),
    );
    await database.upsertVideoDownloadJob(
      VideoDownloadJobsCompanion.insert(
        jobId: 'persisted-job',
        resourceProvider: 'torznab:indexer-a',
        selectedResourceId: candidate.remoteId,
        torrentHash: Value<String?>(candidate.infoHash),
        metadataProvider: const Value<String?>('anilist'),
        externalId: const Value<String?>('media-movie'),
        mediaKind: 'movie',
        discoveryCategory: const Value<String?>('movie'),
        title: 'Example Movie',
        backendKind: 'embedded',
        backendProfileId: const Value<String?>('embedded'),
        fingerprint: 'backend-fingerprint',
        category: const Value<String?>('fushi-video'),
        targetSourceId: Value<int?>(sourceId),
        createdAt: _nowAt,
        updatedAt: _nowAt,
      ),
    );
    int enqueueCount = 0;
    final VideoDownloadSubscriptionService service = _service(
      database: database,
      provider: _FakeResourceProvider(
        id: 'torznab',
        candidates: <VideoResourceCandidate>[candidate],
      ),
      enqueue: (VideoDownloadEnqueueRequest _) async {
        enqueueCount++;
        return 'unexpected-job';
      },
    );

    await service.checkNow();

    expect(enqueueCount, 0);
    final VideoDownloadSubscriptionItemRow item =
        (await database.getVideoDownloadSubscriptionItems('movie')).single;
    expect(item.jobId, 'persisted-job');
    expect(item.status, VideoDownloadSubscriptionItemStatus.queued);
    final VideoDownloadSubscriptionRow subscription =
        (await database.getVideoDownloadSubscription('movie'))!;
    expect(subscription.enabled, isFalse);
    expect(subscription.fulfilledAt, _nowAt);
  });

  test('Torznab selected codec and language never silently downgrade',
      () async {
    final FushiDatabase database = await _openDatabase();
    final int sourceId = await _insertVideoSource(database);
    await _insertSubscription(
      database,
      id: 'strict-tv',
      sourceId: sourceId,
      resourceProvider: 'torznab:indexer-a',
      mediaKind: 'tv',
      discoveryCategory: 'tv',
      season: 1,
      filters: <String, Object?>{
        'strict': true,
        'quality': '1080p',
        'source': 'WEB-DL',
        'codec': 'HEVC',
        'language': 'Dual Audio',
      },
    );
    int enqueueCount = 0;
    final VideoDownloadSubscriptionService service = _service(
      database: database,
      provider: _FakeResourceProvider(
        id: 'torznab',
        candidates: <VideoResourceCandidate>[
          _candidate(
            providerId: 'torznab',
            instanceId: 'indexer-a',
            remoteId: 'downgraded',
            mediaTitle: 'Example Show S01E02 1080p WEB-DL AVC Japanese',
            episode: null,
            group: null,
            resolution: null,
          ),
        ],
      ),
      enqueue: (VideoDownloadEnqueueRequest _) async {
        enqueueCount++;
        return 'unexpected-job';
      },
    );

    await service.checkNow();

    expect(enqueueCount, 0);
    expect(
      await database.getVideoDownloadSubscriptionItems('strict-tv'),
      isEmpty,
    );
  });

  test('provider errors use exponential retry and redact credential URLs',
      () async {
    final FushiDatabase database = await _openDatabase();
    final int sourceId = await _insertVideoSource(database);
    await _insertSubscription(
      database,
      id: 'retry',
      sourceId: sourceId,
      resourceProvider: 'nyaa',
      mediaKind: 'tv',
      discoveryCategory: 'anime',
      filters: <String, Object?>{
        'strict': true,
        'releaseGroup': 'SubsPlease',
        'resolution': '1080p',
        'trustedOnly': true,
      },
    );
    final VideoDownloadSubscriptionService service = _service(
      database: database,
      provider: _FakeResourceProvider(
        id: 'nyaa',
        result: ProviderBatchResult<VideoResourceCandidate>.failure(
          const ExternalProviderFailure(
            providerId: 'nyaa',
            operation: 'search',
            kind: ExternalProviderFailureKind.network,
            message: 'request failed https://example.test/?apikey=top-secret',
            retryable: true,
          ),
        ),
      ),
      enqueue: (VideoDownloadEnqueueRequest _) async => 'unused',
    );

    await service.checkNow();

    final VideoDownloadSubscriptionRow first =
        (await database.getVideoDownloadSubscription('retry'))!;
    expect(first.retryCount, 1);
    expect(
        first.nextCheckAt, _nowAt + const Duration(minutes: 15).inMilliseconds);
    expect(first.lastError, contains('<redacted>'));
    expect(first.lastError, isNot(contains('top-secret')));
    expect(first.claimedBy, isNull);
  });

  test('start triggers an immediate due check', () async {
    final FushiDatabase database = await _openDatabase();
    final int sourceId = await _insertVideoSource(database);
    await _insertSubscription(
      database,
      id: 'startup',
      sourceId: sourceId,
      resourceProvider: 'torznab:indexer-a',
      mediaKind: 'movie',
      discoveryCategory: 'movie',
      mode: 'oneShot',
      filters: <String, Object?>{'strict': true, 'quality': '1080p'},
    );
    final VideoResourceCandidate candidate = _candidate(
      providerId: 'torznab',
      instanceId: 'indexer-a',
      remoteId: 'startup-release',
      mediaTitle: 'Example Movie 1080p',
      episode: null,
      group: null,
      resolution: null,
    );
    final VideoDownloadSubscriptionService service = _service(
      database: database,
      provider: _FakeResourceProvider(
        id: 'torznab',
        candidates: <VideoResourceCandidate>[candidate],
      ),
      enqueue: (VideoDownloadEnqueueRequest request) =>
          _persistFakeJob(database, request, 'startup-job'),
    );

    service.start();
    for (int attempt = 0; attempt < 20; attempt++) {
      final VideoDownloadSubscriptionRow row =
          (await database.getVideoDownloadSubscription('startup'))!;
      if (row.fulfilledAt != null) break;
      await pumpEventQueue();
    }

    final VideoDownloadSubscriptionRow row =
        (await database.getVideoDownloadSubscription('startup'))!;
    expect(row.fulfilledAt, _nowAt);
    expect(row.enabled, isFalse);
  });

  test('long provider search renews the subscription lease', () async {
    final FushiDatabase database = await _openDatabase();
    final int sourceId = await _insertVideoSource(database);
    await _insertSubscription(
      database,
      id: 'lease-heartbeat',
      sourceId: sourceId,
      resourceProvider: 'torznab:indexer-a',
      mediaKind: 'movie',
      discoveryCategory: 'movie',
      mode: 'oneShot',
      filters: <String, Object?>{'strict': true, 'quality': '1080p'},
    );
    final _FakeResourceProvider provider = _FakeResourceProvider(
      id: 'torznab',
      pauseSearch: true,
      candidates: <VideoResourceCandidate>[
        _candidate(
          providerId: 'torznab',
          instanceId: 'indexer-a',
          remoteId: 'lease-release',
          mediaTitle: 'Example Movie 1080p',
          episode: null,
          group: null,
          resolution: null,
        ),
      ],
    );
    addTearDown(provider.releaseSearch);
    final VideoDownloadSubscriptionService service = _service(
      database: database,
      provider: provider,
      enqueue: (VideoDownloadEnqueueRequest request) =>
          _persistFakeJob(database, request, 'lease-job'),
      leaseDuration: const Duration(milliseconds: 90),
      now: DateTime.now,
    );

    final Future<void> check = service.checkNow();
    await provider.searchEntered.future.timeout(const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 240));

    final VideoDownloadSubscriptionRow held =
        (await database.getVideoDownloadSubscription('lease-heartbeat'))!;
    expect(held.claimedBy, 'subscription-test-worker');
    expect(
      held.claimExpiresAt,
      greaterThan(DateTime.now().millisecondsSinceEpoch),
    );
    final VideoDownloadSubscriptionRow? stolen =
        await database.claimNextVideoDownloadSubscription(
      workerId: 'competing-subscription-worker',
      nowAt: DateTime.now().millisecondsSinceEpoch,
      leaseDurationMs: 1000,
    );
    expect(stolen, isNull);

    provider.releaseSearch();
    await check;
    final VideoDownloadSubscriptionRow completed =
        (await database.getVideoDownloadSubscription('lease-heartbeat'))!;
    expect(completed.claimedBy, isNull);
    expect(completed.enabled, isFalse);
    expect(completed.fulfilledAt, isNotNull);
  });

  test('a failed completion CAS does not overwrite the new lease owner',
      () async {
    final FushiDatabase database = await _openDatabase();
    final int sourceId = await _insertVideoSource(database);
    await _insertSubscription(
      database,
      id: 'lost-subscription-lease',
      sourceId: sourceId,
      resourceProvider: 'torznab:indexer-a',
      mediaKind: 'movie',
      discoveryCategory: 'movie',
      mode: 'oneShot',
      filters: <String, Object?>{'strict': true, 'quality': '1080p'},
    );
    final _FakeResourceProvider provider = _FakeResourceProvider(
      id: 'torznab',
      pauseSearch: true,
      candidates: <VideoResourceCandidate>[
        _candidate(
          providerId: 'torznab',
          instanceId: 'indexer-a',
          remoteId: 'lost-lease-release',
          mediaTitle: 'Example Movie 1080p',
          episode: null,
          group: null,
          resolution: null,
        ),
      ],
    );
    addTearDown(provider.releaseSearch);
    final VideoDownloadSubscriptionService service = _service(
      database: database,
      provider: provider,
      enqueue: (VideoDownloadEnqueueRequest request) =>
          _persistFakeJob(database, request, 'lost-lease-job'),
    );

    final Future<void> check = service.checkNow();
    await provider.searchEntered.future.timeout(const Duration(seconds: 2));
    await database.updateVideoDownloadSubscription(
      'lost-subscription-lease',
      const VideoDownloadSubscriptionsCompanion(
        claimedBy: Value<String?>('competing-subscription-worker'),
        claimExpiresAt: Value<int?>(_nowAt + 60000),
        updatedAt: Value<int>(_nowAt),
      ),
    );
    provider.releaseSearch();
    await check;

    final VideoDownloadSubscriptionRow row = (await database
        .getVideoDownloadSubscription('lost-subscription-lease'))!;
    expect(row.claimedBy, 'competing-subscription-worker');
    expect(row.enabled, isTrue);
    expect(row.retryCount, 0);
    expect(row.lastError, isNull);
  });
}

VideoResourceCandidate _candidate({
  String providerId = 'nyaa',
  String instanceId = 'nyaa.si',
  required String remoteId,
  int? episode,
  String? mediaTitle,
  String? group = 'SubsPlease',
  String? resolution = '1080p',
  bool trusted = true,
  int seeders = 10,
  String category = '1_2',
}) =>
    _FakeResourceCandidate(
      providerId: providerId,
      instanceId: instanceId,
      remoteId: remoteId,
      title: mediaTitle ?? '[SubsPlease] Example Show - $episode [1080p]',
      infoHash: remoteId.hashCode
          .abs()
          .toRadixString(16)
          .padLeft(40, '0')
          .substring(0, 40),
      releaseGroup: group,
      resolution: resolution,
      trusted: trusted,
      seeders: seeders,
      category: category,
    );

class _FakeResourceCandidate extends VideoResourceCandidate {
  _FakeResourceCandidate({
    required String providerId,
    required String instanceId,
    required String remoteId,
    required String title,
    required String infoHash,
    required String? releaseGroup,
    required String? resolution,
    required bool trusted,
    required int seeders,
    required String category,
  }) : super(
          providerId: providerId,
          providerInstanceId: instanceId,
          remoteId: remoteId,
          title: title,
          providerPriority: 10,
          infoHash: infoHash,
          releaseGroup: releaseGroup,
          resolution: resolution,
          trusted: trusted,
          seeders: seeders,
          category: category,
        );
}

class _FakeResourceProvider implements VideoResourceProvider {
  _FakeResourceProvider({
    required this.id,
    List<VideoResourceCandidate> candidates = const <VideoResourceCandidate>[],
    ProviderBatchResult<VideoResourceCandidate>? result,
    Map<int, ProviderBatchResult<VideoResourceCandidate>> resultsByPage =
        const <int, ProviderBatchResult<VideoResourceCandidate>>{},
    bool pauseSearch = false,
  })  : _result = result ??
            ProviderBatchResult<VideoResourceCandidate>.success(candidates),
        _resultsByPage = resultsByPage,
        _searchGate = pauseSearch ? Completer<void>() : null;

  @override
  final String id;

  /// 测试替身不限域：本套件断言的是订阅调度，不该再依赖「id 恰好叫 torznab」
  /// 这种间接门控。
  @override
  Set<VideoDiscoveryCategory> get categories =>
      const <VideoDiscoveryCategory>{};

  final ProviderBatchResult<VideoResourceCandidate> _result;
  final Map<int, ProviderBatchResult<VideoResourceCandidate>> _resultsByPage;
  final Completer<void>? _searchGate;
  final Completer<void> searchEntered = Completer<void>();
  final List<int> requestedPages = <int>[];
  final List<int> requestedLimits = <int>[];

  void releaseSearch() {
    final Completer<void>? gate = _searchGate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  @override
  int get priority => 10;

  @override
  Future<ProviderBatchResult<VideoResourceCandidate>> search(
    VideoResourceSearchRequest request,
  ) async {
    requestedPages.add(request.page);
    requestedLimits.add(request.limit);
    if (!searchEntered.isCompleted) searchEntered.complete();
    await _searchGate?.future;
    return _resultsByPage[request.page] ?? _result;
  }

  @override
  Future<TorrentAddPayload> resolve(VideoResourceCandidate candidate) async =>
      TorrentMagnetPayload(
        magnetUri: 'magnet:?xt=urn:btih:${candidate.infoHash}',
        torrentId: candidate.infoHash,
      );

  @override
  void close() {}
}
