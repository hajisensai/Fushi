import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi_core/fushi_core.dart';

/// 根因回归：`enqueue` 阶段（排在别的下载后面等槽位）的任务原本被判成
/// 「该 torrent 已不在引擎中」。用户报障原话：「明明只是因为其他东西在下载」。
///
/// 判定顺序是关键——必须**先**问「它该不该已经在引擎里」，再问「引擎答没答」。
/// 反过来问，排队中的任务就会落进「引擎里找不到 → 丢了」那条分支。
VideoDownloadJobRow _job({
  required String stage,
  String? backendTaskId,
  String? torrentHash,
}) =>
    VideoDownloadJobRow(
      jobId: 'job-1',
      resourceProvider: 'nyaa:default',
      selectedResourceId: 'resource-1',
      magnetUri: null,
      resourceTitle: 'Some Release 1080p',
      torrentHash: torrentHash,
      metadataProvider: 'anilist',
      externalId: 'media-1',
      mediaKind: 'tv',
      discoveryCategory: 'anime',
      title: 'Some Show',
      year: 2026,
      season: 1,
      coverUrl: null,
      backendKind: 'embedded',
      backendTaskId: backendTaskId,
      backendProfileId: 'default',
      fingerprint: 'embedded-test',
      category: 'fushi-video',
      targetSourceId: null,
      collectionId: null,
      organizationPolicy: 'library',
      subtitlePolicy: 'bestEffort',
      observedSavePath: null,
      targetRelativeRoot: null,
      lifecycle: VideoDownloadJobLifecycle.active,
      stage: stage,
      stageProgress: 0,
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

void main() {
  group('resolveLiveDataAbsence', () {
    test('有实时快照时不缺数据', () {
      expect(
        resolveLiveDataAbsence(
          job: _job(stage: VideoDownloadJobStage.download),
          torrentId: 'abc',
          hasLiveSnapshot: true,
          backendOnline: true,
        ),
        VideoDownloadLiveDataAbsence.none,
      );
    });

    test('enqueue 阶段 = 还没交给下载器，即使已经有 hash 也不算丢失', () {
      expect(
        resolveLiveDataAbsence(
          // 截图里的真实形态：已经有信息哈希，但仍停在 enqueue。
          job: _job(
            stage: VideoDownloadJobStage.enqueue,
            torrentHash: 'abc',
          ),
          torrentId: 'abc',
          hasLiveSnapshot: false,
          backendOnline: true,
        ),
        VideoDownloadLiveDataAbsence.notHandedOff,
        reason: '排队等槽位被判成 missingFromBackend，就是本次修的那条误诊。',
      );
    });

    test('还没有后端任务 id 时也算还没交给下载器', () {
      expect(
        resolveLiveDataAbsence(
          job: _job(stage: VideoDownloadJobStage.download),
          torrentId: '',
          hasLiveSnapshot: false,
          backendOnline: true,
        ),
        VideoDownloadLiveDataAbsence.notHandedOff,
      );
    });

    test('已过入队阶段 + 后端在线 + 引擎里没有 = 真丢失', () {
      expect(
        resolveLiveDataAbsence(
          job: _job(
            stage: VideoDownloadJobStage.download,
            backendTaskId: 'abc',
          ),
          torrentId: 'abc',
          hasLiveSnapshot: false,
          backendOnline: true,
        ),
        VideoDownloadLiveDataAbsence.missingFromBackend,
      );
    });

    test('后端连不上时报后端离线，不冒充丢失', () {
      expect(
        resolveLiveDataAbsence(
          job: _job(
            stage: VideoDownloadJobStage.download,
            backendTaskId: 'abc',
          ),
          torrentId: 'abc',
          hasLiveSnapshot: false,
          backendOnline: false,
        ),
        VideoDownloadLiveDataAbsence.backendOffline,
      );
    });
  });
}
