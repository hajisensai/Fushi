import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/downloads/download_task_entry.dart';
import 'package:fushi/src/pages/implementations/video_download_jobs_panel.dart';
import 'package:fushi_core/fushi_core.dart';

/// 统一下载列表把四类任务归一成 [DownloadTaskEntry]，但它们的能力天然不齐。
/// 这批用例钉住的是「谁有什么」这个契约本身——批量操作按 [DownloadTaskActions]
/// 的槽位过滤选中集，槽位填错的后果是按钮点了静默无效，而不是编译期错误。
void main() {
  VideoDownloadJobRow job(
    String lifecycle, {
    String resourceProvider = 'nyaa:default',
  }) =>
      VideoDownloadJobRow(
        jobId: 'job-$lifecycle',
        resourceProvider: resourceProvider,
        selectedResourceId: 'resource',
        magnetUri: null,
        resourceTitle: null,
        torrentHash: null,
        metadataProvider: null,
        externalId: null,
        mediaKind: 'tv',
        discoveryCategory: null,
        title: 'title',
        year: null,
        season: null,
        coverUrl: null,
        backendKind: 'embedded',
        backendTaskId: null,
        backendProfileId: 'default',
        fingerprint: 'embedded-test',
        category: 'fushi-video',
        targetSourceId: null,
        collectionId: null,
        organizationPolicy: 'library',
        subtitlePolicy: 'bestEffort',
        observedSavePath: null,
        targetRelativeRoot: null,
        lifecycle: lifecycle,
        stage: VideoDownloadJobStage.download,
        stageProgress: 0.4,
        priority: 0,
        attemptCount: 0,
        maxAttempts: 3,
        nextAttemptAt: null,
        claimedBy: null,
        claimExpiresAt: null,
        lastError: null,
        createdAt: 1,
        updatedAt: 2,
        completedAt: null,
      );

  group('video job 动作判据', () {
    test('重试只对 failed / needsAttention 开放', () {
      expect(videoDownloadJobCanRetry(job(VideoDownloadJobLifecycle.failed)),
          isTrue);
      expect(
        videoDownloadJobCanRetry(job(VideoDownloadJobLifecycle.needsAttention)),
        isTrue,
      );
      expect(
        videoDownloadJobCanRetry(job(VideoDownloadJobLifecycle.active)),
        isFalse,
      );
      expect(
        videoDownloadJobCanRetry(job(VideoDownloadJobLifecycle.completed)),
        isFalse,
      );
    });

    test('legacy 导入报告不是可重跑任务', () {
      expect(
        videoDownloadJobCanRetry(
          job(
            VideoDownloadJobLifecycle.failed,
            resourceProvider: 'legacy-import-report',
          ),
        ),
        isFalse,
      );
    });

    test('cancelled 是「用户已暂停」：能恢复、不能再暂停', () {
      final VideoDownloadJobRow paused =
          job(VideoDownloadJobLifecycle.cancelled);
      expect(videoDownloadJobCanResume(paused), isTrue);
      expect(videoDownloadJobCanPause(paused), isFalse);
    });

    test('只有正在跑的任务能暂停', () {
      expect(
        videoDownloadJobCanPause(job(VideoDownloadJobLifecycle.active)),
        isTrue,
      );
      expect(
        videoDownloadJobCanPause(job(VideoDownloadJobLifecycle.completed)),
        isFalse,
      );
      expect(
        videoDownloadJobCanResume(job(VideoDownloadJobLifecycle.active)),
        isFalse,
      );
    });

    test('优先级只对还会被取走的任务有意义', () {
      expect(
        videoDownloadJobCanSetPriority(job(VideoDownloadJobLifecycle.active)),
        isTrue,
      );
      expect(
        videoDownloadJobCanSetPriority(
          job(VideoDownloadJobLifecycle.needsAttention),
        ),
        isTrue,
      );
      expect(
        videoDownloadJobCanSetPriority(
          job(VideoDownloadJobLifecycle.completed),
        ),
        isFalse,
        reason: '已完成的任务设优先级不会重新排队，露出来只会让人以为能插队',
      );
      expect(
        videoDownloadJobCanSetPriority(
          job(VideoDownloadJobLifecycle.cancelled),
        ),
        isFalse,
      );
    });
  });

  group('DownloadTaskActions 契约', () {
    test('默认不支持任何动作', () {
      const DownloadTaskActions actions = DownloadTaskActions.none;
      expect(actions.pause, isNull);
      expect(actions.cancel, isNull);
      expect(actions.resume, isNull);
      expect(actions.retry, isNull);
      expect(actions.clear, isNull);
      expect(actions.delete, isNull);
      expect(actions.setPriority, isNull);
    });

    test('entry 默认带 none，不必逐个来源显式传', () {
      final DownloadTaskEntry entry = DownloadTaskEntry(
        id: 'x',
        title: 'x',
        kind: DownloadTaskKind.video,
        status: DownloadTaskStatus.active,
        builder: (_) => const SizedBox.shrink(),
      );
      expect(identical(entry.actions, DownloadTaskActions.none), isTrue);
    });

    test('pause 与 cancel 是两个槽位，不可互相顶替', () {
      // 单跑道内存队列（mokuro / 直链）只有不可恢复的 cancel；torrent 侧才有
      // 可恢复的 pause。把两者合成一个槽位会让「继续」对前者静默无效。
      final DownloadTaskActions queueLike = DownloadTaskActions(
        cancel: () async {},
        retry: () async {},
        clear: () async {},
      );
      expect(queueLike.pause, isNull);
      expect(queueLike.resume, isNull);
      expect(queueLike.setPriority, isNull, reason: '单跑道队列没有调度器，优先级无从谈起');
    });

    test('只提供 clear 的来源不得被当成能删文件', () {
      final DownloadTaskActions clearOnly = DownloadTaskActions(
        clear: () async {},
      );
      expect(clearOnly.delete, isNull, reason: '把「移出列表」伪装成「删除」会让用户以为磁盘已经清干净了');
    });
  });
}
