import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/discovery/discovery_download_queue.dart'
    show DiscoveryImportOutcome;
import 'package:fushi_engine/media/discovery/discovery_models.dart'
    show DiscoveryMediaKind;
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/torrent/torrent_metainfo.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_download_backend_identity.dart';
import 'package:fushi_engine/media/video/download/video_download_path_mapping.dart';
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi_engine/media/video/download/video_download_subtitle_language.dart';
import 'package:fushi_engine/media/video/download/video_media_reference_codec.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';
import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_resolver.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_transport.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_coordinator.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/media/video/subtitle/embedded_reference_subtitle_sync.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_alignment_backup.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi_engine/media/video/video_cover_extractor.dart';
import 'package:fushi_engine/updates/update_feed_kind.dart';
import 'package:fushi_engine/updates/update_feed_port.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

const String _torrentHash = '0123456789abcdef0123456789abcdef01234567';

/// 发现身份快照里的 MAL ID 优先于兼容保留的 AniDB ID。
VideoMediaReference _confirmedReference({
  VideoMetadataProviderKind provider = VideoMetadataProviderKind.mal,
  VideoMetadataMediaKind kind = VideoMetadataMediaKind.tv,
}) =>
    VideoMediaReference(
      providerId: 'anilist',
      mediaId: '100',
      mediaKind: kind,
      discoveryCategory: VideoDiscoveryCategory.anime,
      title: 'Show',
      originalTitle: 'ショー',
      aliases: const <String>['Show'],
      year: 2026,
      season: 1,
      anidbId: 42,
      anilistId: 100,
      externalIds: <String, String>{provider.name: '42'},
    );
const VideoDownloadBackendIdentity _expectedIdentity =
    VideoDownloadBackendIdentity(
  kind: 'embedded',
  profileId: 'embedded',
  fingerprint: 'installation-fingerprint',
);
const String _expectedCategory = 'fushi-video';
const VideoDownloadBackendTarget _expectedTarget = VideoDownloadBackendTarget(
  identity: _expectedIdentity,
  category: _expectedCategory,
);

void main() {
  test('持久化详情不依赖运行中的下载服务或后端', () async {
    final _FakeTorrentBackend backend = _FakeTorrentBackend(
      snapshots: <TorrentSnapshot>[_downloadingSnapshot(progress: 0.25)],
    );
    final _PipelineEnvironment environment =
        await _PipelineEnvironment.create(backend: backend);
    addTearDown(environment.close);
    final String jobId = await environment.service.enqueue(
      environment.enqueueRequest(),
    );
    final VideoDownloadJobRow job = await _waitForJob(
      environment.database,
      jobId,
      (VideoDownloadJobRow row) => row.stage == VideoDownloadJobStage.download,
    );

    final VideoDownloadJobDetails details =
        buildPersistedVideoDownloadJobDetails(
      job,
      await environment.database.getVideoDownloadJobFiles(jobId),
    );

    expect(details.backend, isNull);
    expect(details.snapshot.hash, _torrentHash);
    expect(details.snapshot.progress, 0.25);

    await deletePersistedVideoDownloadJob(
      database: environment.database,
      job: job,
      deleteFiles: false,
    );
    expect(await environment.database.getVideoDownloadJob(jobId), isNull);
  });

  test(
      'enqueue persists intent and verified hash before backend add side effect',
      () async {
    final _FakeTorrentBackend backend = _FakeTorrentBackend(
      snapshots: <TorrentSnapshot>[_downloadingSnapshot(progress: 0.25)],
      pauseAdd: true,
    );
    final _PipelineEnvironment environment =
        await _PipelineEnvironment.create(backend: backend);
    addTearDown(environment.close);
    VideoDownloadJobRow? intentAtAdd;
    backend.beforeAdd = () async {
      intentAtAdd = (await environment.database.getVideoDownloadJobs()).single;
    };

    final String jobId = await environment.service.enqueue(
      environment.enqueueRequest(),
    );
    await backend.addEntered.future.timeout(const Duration(seconds: 2));

    final VideoDownloadJobRow persisted = intentAtAdd!;
    expect(persisted.jobId, jobId);
    expect(persisted.lifecycle, VideoDownloadJobLifecycle.active);
    expect(persisted.stage, VideoDownloadJobStage.enqueue);
    expect(persisted.resourceProvider, 'nyaa:test-instance');
    expect(persisted.selectedResourceId, 'release-1');
    expect(persisted.torrentHash, _torrentHash);
    expect(persisted.fingerprint, _expectedIdentity.fingerprint);
    expect(persisted.category, _expectedCategory);
    expect(persisted.targetSourceId, environment.sourceId);

    backend.releaseAdd();
    final VideoDownloadJobRow downloading = await _waitForJob(
      environment.database,
      jobId,
      (VideoDownloadJobRow row) =>
          row.stage == VideoDownloadJobStage.download && row.claimedBy == null,
    );
    expect(downloading.stageProgress, 0.25);
  });

  test('embedded enqueue checkpoints resume before advancing to download',
      () async {
    final _FakeTorrentBackend backend = _FakeTorrentBackend(
      snapshots: <TorrentSnapshot>[_downloadingSnapshot(progress: 0.25)],
    );
    VideoDownloadJobRow? jobAtCheckpoint;
    late final _PipelineEnvironment environment;
    environment = await _PipelineEnvironment.create(
      backend: backend,
      onBackendTaskAdded: (VideoDownloadJobRow job) async {
        jobAtCheckpoint =
            await environment.database.getVideoDownloadJob(job.jobId);
      },
    );
    addTearDown(environment.close);

    final String jobId = await environment.service.enqueue(
      environment.enqueueRequest(),
    );
    await _waitForJob(
      environment.database,
      jobId,
      (VideoDownloadJobRow row) => row.stage == VideoDownloadJobStage.download,
    );

    expect(jobAtCheckpoint, isNotNull);
    expect(jobAtCheckpoint!.stage, VideoDownloadJobStage.enqueue);
    expect(jobAtCheckpoint!.torrentHash, _torrentHash);
  });

  test('enqueue persists the candidate magnet and skips re-search (BUG-1784)',
      () async {
    const String candidateMagnet =
        'magnet:?xt=urn:btih:$_torrentHash&dn=Show+S01E01'
        '&tr=udp%3A%2F%2Ftracker.example%3A1337%2Fannounce';
    final _FakeTorrentBackend backend = _FakeTorrentBackend(
      snapshots: <TorrentSnapshot>[_downloadingSnapshot(progress: 0.25)],
    );
    final _PipelineEnvironment environment = await _PipelineEnvironment.create(
      backend: backend,
      candidateMagnetUri: candidateMagnet,
    );
    addTearDown(environment.close);

    final String jobId = await environment.service.enqueue(
      environment.enqueueRequest(),
    );
    final VideoDownloadJobRow downloading = await _waitForJob(
      environment.database,
      jobId,
      (VideoDownloadJobRow row) => row.stage == VideoDownloadJobStage.download,
    );

    expect(downloading.magnetUri, candidateMagnet);
    // payload 从任务行磁链物化，物化不回索引器重搜/重解析。
    expect(environment.provider.searchCalls, 0);
    expect(environment.provider.resolveCalls, 0);
    expect(backend.addCalls, 1);
  });

  test(
      'legacy job without magnet recovers offline from its info hash '
      'when re-search misses (BUG-1784)', () async {
    final _FakeTorrentBackend backend = _FakeTorrentBackend(
      snapshots: <TorrentSnapshot>[_downloadingSnapshot(progress: 0.25)],
    );
    final _PipelineEnvironment environment = await _PipelineEnvironment.create(
      backend: backend,
    );
    addTearDown(environment.close);
    // 存量任务行形态：入队时没落磁链。索引器就算会搜空也不影响结果——BUG-1866
    // 起离线磁链是主路径，这条设置只是让「重搜找不回」这个历史前提留在用例里。
    environment.provider.returnEmptySearch = true;

    final String jobId = await environment.service.enqueue(
      environment.enqueueRequest(),
    );
    final VideoDownloadJobRow downloading = await _waitForJob(
      environment.database,
      jobId,
      (VideoDownloadJobRow row) => row.stage == VideoDownloadJobStage.download,
    );

    // 离线重建的磁链（info hash + 该索引器固定 tracker）落回任务行。
    expect(downloading.magnetUri, startsWith('magnet:?xt=urn:btih:'));
    expect(downloading.magnetUri, contains(_torrentHash));
    expect(environment.provider.resolveCalls, 0);
    expect(backend.addCalls, 1);
  });

  test(
      'public indexer job resolves offline without touching the network '
      '(BUG-1866)', () async {
    final _FakeTorrentBackend backend = _FakeTorrentBackend(
      snapshots: <TorrentSnapshot>[_downloadingSnapshot(progress: 0.25)],
    );
    final _PipelineEnvironment environment = await _PipelineEnvironment.create(
      backend: backend,
    );
    addTearDown(environment.close);
    // 原始失败路径：存量任务行没磁链，索引器又不可达。旧口径先联网重搜、抛了
    // 才兜底，那一次失败会把一个**还活着**的资源标成
    // `ExternalProviderFailure(kind=notFound)` 推到用户面前。
    environment.provider.failSearch = true;

    final String jobId = await environment.service.enqueue(
      environment.enqueueRequest(),
    );
    final VideoDownloadJobRow downloading = await _waitForJob(
      environment.database,
      jobId,
      (VideoDownloadJobRow row) => row.stage == VideoDownloadJobStage.download,
    );

    expect(downloading.magnetUri, contains(_torrentHash));
    expect(downloading.lastError, isNull);
    // 关键不变式：公共索引器的 payload 是任务行数据的纯函数，一次网络都不打。
    // 这条断言塌成 `searchCalls >= 0` 就等于把 BUG-1866 放回来了。
    expect(environment.provider.searchCalls, 0);
    expect(environment.provider.resolveCalls, 0);
    expect(backend.addCalls, 1);
  });

  test('long enqueue renews its lease and cannot be claimed by another worker',
      () async {
    final _FakeTorrentBackend backend = _FakeTorrentBackend(
      snapshots: <TorrentSnapshot>[_downloadingSnapshot(progress: 0.2)],
      pauseAdd: true,
    );
    final _PipelineEnvironment environment = await _PipelineEnvironment.create(
      backend: backend,
      leaseDuration: const Duration(milliseconds: 90),
    );
    addTearDown(environment.close);

    final String jobId = await environment.service.enqueue(
      environment.enqueueRequest(),
    );
    await backend.addEntered.future.timeout(const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 240));

    final VideoDownloadJobRow held =
        (await environment.database.getVideoDownloadJob(jobId))!;
    expect(held.claimedBy, 'pipeline-test-worker');
    expect(
      held.claimExpiresAt,
      greaterThan(DateTime.now().millisecondsSinceEpoch),
    );
    final VideoDownloadJobRow? stolen =
        await environment.database.claimNextVideoDownloadJob(
      workerId: 'competing-worker',
      nowAt: DateTime.now().millisecondsSinceEpoch,
      leaseDurationMs: 1000,
    );
    expect(stolen, isNull);

    backend.releaseAdd();
    final VideoDownloadJobRow downloading = await _waitForJob(
      environment.database,
      jobId,
      (VideoDownloadJobRow row) =>
          row.stage == VideoDownloadJobStage.download && row.claimedBy == null,
    );
    expect(downloading.lifecycle, VideoDownloadJobLifecycle.active);
  });

  test('a failed transition CAS stops a worker that lost its claim', () async {
    final _FakeTorrentBackend backend = _FakeTorrentBackend(pauseAdd: true);
    final _PipelineEnvironment environment =
        await _PipelineEnvironment.create(backend: backend);
    addTearDown(environment.close);

    final String jobId = await environment.service.enqueue(
      environment.enqueueRequest(),
    );
    await backend.addEntered.future.timeout(const Duration(seconds: 2));
    final int now = DateTime.now().millisecondsSinceEpoch;
    await environment.database.updateVideoDownloadJob(
      jobId,
      VideoDownloadJobsCompanion(
        claimedBy: const Value<String?>('competing-worker'),
        claimExpiresAt: Value<int?>(now + 60000),
        updatedAt: Value<int>(now),
      ),
    );
    backend.releaseAdd();
    await Future<void>.delayed(const Duration(milliseconds: 80));

    final VideoDownloadJobRow job =
        (await environment.database.getVideoDownloadJob(jobId))!;
    expect(job.stage, VideoDownloadJobStage.enqueue);
    expect(job.lifecycle, VideoDownloadJobLifecycle.active);
    expect(job.claimedBy, 'competing-worker');
    expect(job.attemptCount, 0);
    expect(job.lastError, isNull);
  });

  for (final ({String label, VideoDownloadBackendIdentity identity}) mismatch
      in <({String label, VideoDownloadBackendIdentity identity})>[
    (
      label: 'fingerprint',
      identity: const VideoDownloadBackendIdentity(
        kind: 'embedded',
        profileId: 'embedded',
        fingerprint: 'different-installation',
      ),
    ),
    (
      label: 'profile',
      identity: const VideoDownloadBackendIdentity(
        kind: 'embedded',
        profileId: 'another-profile',
        fingerprint: 'installation-fingerprint',
      ),
    ),
    (
      label: 'kind',
      identity: const VideoDownloadBackendIdentity(
        kind: 'qbittorrent',
        profileId: 'embedded',
        fingerprint: 'installation-fingerprint',
      ),
    ),
  ]) {
    test('backend ${mismatch.label} mismatch requires attention before enqueue',
        () async {
      final _FakeTorrentBackend backend = _FakeTorrentBackend();
      final _PipelineEnvironment environment =
          await _PipelineEnvironment.create(
        backend: backend,
        backendResolver: (_) async => VideoDownloadBackendBinding(
          backend: backend,
          identity: mismatch.identity,
        ),
      );
      addTearDown(environment.close);

      final String jobId = await environment.service.enqueue(
        environment.enqueueRequest(),
      );
      final VideoDownloadJobRow job = await _waitForJob(
        environment.database,
        jobId,
        (VideoDownloadJobRow row) =>
            row.lifecycle == VideoDownloadJobLifecycle.needsAttention,
      );

      expect(job.stage, VideoDownloadJobStage.enqueue);
      expect(job.lastError, contains('no longer matches this job'));
      expect(backend.prepareCategoryCalls, 0);
      expect(backend.addCalls, 0);
      expect(environment.provider.searchCalls, 0);
    });
  }

  test('改掉配置里的分类不会拦下已有任务，任务用自己那份分类投递', () async {
    // BUG-1879：分类曾被算进后端身份，用户在设置里把分类从 hibiki 改成 fushi
    // （或升级后默认分类漂移）会让全部在途任务当场判失配、卡死 needsAttention，
    // 重试还会再撞同一道门。分类是任务自己的投放位置，不是「这是哪台下载器」。
    const String jobCategory = 'hibiki';
    expect(jobCategory, isNot(_expectedCategory));

    final _FakeTorrentBackend backend = _FakeTorrentBackend(
      snapshots: <TorrentSnapshot>[_downloadingSnapshot(progress: 0.1)],
    );
    final _PipelineEnvironment environment = await _PipelineEnvironment.create(
      backend: backend,
      // 同一台下载器（身份没变），只是用户改了设置里的分类。
      backendResolver: (_) async => VideoDownloadBackendBinding(
        backend: backend,
        identity: _expectedIdentity,
      ),
    );
    addTearDown(environment.close);

    const String jobId = 'category-changed-job';
    await environment.insertJob(
      jobId: jobId,
      stage: VideoDownloadJobStage.enqueue,
      category: jobCategory,
    );

    environment.service.wake();
    final VideoDownloadJobRow job = await _waitForJob(
      environment.database,
      jobId,
      (VideoDownloadJobRow row) => row.stage == VideoDownloadJobStage.download,
    );

    expect(job.lifecycle, VideoDownloadJobLifecycle.active);
    expect(job.lastError, isNull);
    // 旧任务照旧投到它自己那个分类里——旧种子本来也还在那儿。
    expect(job.category, jobCategory);
    expect(backend.preparedCategories, contains(jobCategory));
    expect(backend.preparedCategories, isNot(contains(_expectedCategory)));
  });

  test('restart resumes persisted download stage without enqueueing again',
      () async {
    final _FakeTorrentBackend backend = _FakeTorrentBackend(
      snapshots: <TorrentSnapshot>[_completeSnapshot()],
      files: const <TorrentFileEntry>[
        TorrentFileEntry(
          name: 'Show.S01E01.mkv',
          size: 1024,
          progress: 1,
          index: 0,
        ),
      ],
    );
    int bindingCalls = 0;
    late _PipelineEnvironment environment;
    environment = await _PipelineEnvironment.create(
      backend: backend,
      backendResolver: (_) async {
        bindingCalls += 1;
        return VideoDownloadBackendBinding(
          backend: backend,
          identity: bindingCalls == 1
              ? _expectedIdentity
              : const VideoDownloadBackendIdentity(
                  kind: 'embedded',
                  profileId: 'embedded',
                  fingerprint: 'changed-after-download',
                ),
        );
      },
    );
    addTearDown(environment.close);
    const String jobId = 'resume-download-job';
    await environment.insertJob(
      jobId: jobId,
      stage: VideoDownloadJobStage.download,
      staleClaim: true,
    );

    environment.service.wake();
    final VideoDownloadJobRow job = await _waitForJob(
      environment.database,
      jobId,
      (VideoDownloadJobRow row) =>
          row.lifecycle == VideoDownloadJobLifecycle.needsAttention,
    );

    expect(job.stage, VideoDownloadJobStage.organize);
    expect(job.attemptCount, 0);
    expect(backend.addCalls, 0, reason: '恢复 download 阶段不得重复 add torrent');
    expect(backend.listTorrentsCalls, 1);
    final List<VideoDownloadJobFileRow> files =
        await environment.database.getVideoDownloadJobFiles(jobId);
    expect(files, hasLength(1));
    expect(files.single.status, VideoDownloadJobFileStatus.downloaded);
    expect(files.single.backendFileIndex, 0);
  });

  test('incomplete download releases poll claim without consuming retry budget',
      () async {
    final _FakeTorrentBackend backend = _FakeTorrentBackend(
      snapshots: <TorrentSnapshot>[_downloadingSnapshot(progress: 0.4)],
    );
    final _PipelineEnvironment environment =
        await _PipelineEnvironment.create(backend: backend);
    addTearDown(environment.close);
    const String jobId = 'poll-download-job';
    await environment.insertJob(
      jobId: jobId,
      stage: VideoDownloadJobStage.download,
    );

    environment.service.wake();
    final VideoDownloadJobRow job = await _waitForJob(
      environment.database,
      jobId,
      (VideoDownloadJobRow row) =>
          row.claimedBy == null && row.nextAttemptAt != null,
    );

    expect(job.lifecycle, VideoDownloadJobLifecycle.active);
    expect(job.stage, VideoDownloadJobStage.download);
    expect(job.stageProgress, 0.4);
    expect(job.attemptCount, 0);
    expect(job.lastError, isNull);
    expect(
        job.nextAttemptAt, greaterThan(DateTime.now().millisecondsSinceEpoch));
    expect(backend.addCalls, 0);
    expect(backend.listTorrentsCalls, 1);
  });

  test(
      'legacy job imports original files and copies staged subtitle without moving either',
      () async {
    final _FakeTorrentBackend backend = _FakeTorrentBackend(
      files: const <TorrentFileEntry>[
        TorrentFileEntry(
          name: 'Show.S01E01.mkv',
          size: 4,
          progress: 1,
          index: 0,
        ),
      ],
    );
    late _PipelineEnvironment environment;
    late Directory downloadDirectory;
    environment = await _PipelineEnvironment.create(
      backend: backend,
      backendResolver: (_) async => VideoDownloadBackendBinding(
        backend: backend,
        identity: _expectedIdentity,
        pathMappings: <VideoDownloadPathMapping>[
          VideoDownloadPathMapping(
            remoteRoot: '/downloads',
            localRoot: downloadDirectory.path,
          ),
        ],
      ),
    );
    addTearDown(environment.close);
    downloadDirectory = Directory(p.join(environment.root.path, 'legacy'));
    await downloadDirectory.create(recursive: true);
    final File video = File(
      p.join(downloadDirectory.path, 'Show.S01E01.mkv'),
    );
    await video.writeAsBytes(<int>[1, 2, 3, 4]);
    final File staged = File(p.join(environment.root.path, 'episode.zh.srt'));
    await staged.writeAsString('legacy subtitle');
    const String jobId = 'legacy-import-job';
    await environment.insertJob(
      jobId: jobId,
      stage: VideoDownloadJobStage.organize,
      organizationPolicy: 'legacy',
      observedSavePath: '/downloads',
      subtitlePolicy: VideoDownloadSubtitlePolicy.bestEffort,
      withoutTargetSource: true,
    );
    final int now = DateTime.now().millisecondsSinceEpoch;
    await environment.database.upsertVideoDownloadJobSubtitle(
      VideoDownloadJobSubtitlesCompanion.insert(
        subtitleId: 'legacy-subtitle-1',
        jobId: jobId,
        provider: 'jimaku',
        selectedSubtitleId: const Value<String?>('legacy:episode.zh.srt'),
        language: const Value<String?>('zh'),
        episode: const Value<int?>(1),
        originalFileName: const Value<String?>('episode.zh.srt'),
        stagedPath: Value<String?>(staged.path),
        status: const Value<String>(VideoDownloadJobSubtitleStatus.staged),
        createdAt: now,
        updatedAt: now,
      ),
    );

    environment.service.wake();
    final VideoDownloadJobRow completed = await _waitForJob(
      environment.database,
      jobId,
      (VideoDownloadJobRow row) =>
          row.lifecycle == VideoDownloadJobLifecycle.completed,
    );

    expect(completed.stage, VideoDownloadJobStage.import);
    expect(backend.renameFileCalls, 0);
    expect(backend.moveStorageCalls, 0);
    final VideoDownloadJobFileRow jobFile =
        (await environment.database.getVideoDownloadJobFiles(jobId)).single;
    expect(jobFile.finalAbsolutePath, video.path);
    expect(jobFile.status, VideoDownloadJobFileStatus.imported);
    final VideoBookRow book =
        (await environment.database.allVideoBooks()).single;
    expect(book.videoPath, video.path);
    expect(book.sourceId, isNull, reason: '旧任务保持手动导入的无来源语义');
    final File sidecar = File(
      p.join(downloadDirectory.path, 'Show.S01E01.zh.srt'),
    );
    expect(await sidecar.readAsString(), 'legacy subtitle');
    expect(await staged.exists(), isTrue, reason: '迁移不得消费旧 staging');
    final VideoDownloadJobSubtitleRow subtitle =
        (await environment.database.getVideoDownloadJobSubtitles(jobId)).single;
    expect(subtitle.status, VideoDownloadJobSubtitleStatus.placed);
    expect(subtitle.stagedPath, staged.path);
    expect(subtitle.finalPath, sidecar.path);
  });

  test('legacy subtitle never overwrites an existing sidecar', () async {
    final _FakeTorrentBackend backend = _FakeTorrentBackend(
      files: const <TorrentFileEntry>[
        TorrentFileEntry(
          name: 'Show.S01E01.mkv',
          size: 4,
          progress: 1,
          index: 0,
        ),
      ],
    );
    late _PipelineEnvironment environment;
    late Directory downloadDirectory;
    environment = await _PipelineEnvironment.create(
      backend: backend,
      backendResolver: (_) async => VideoDownloadBackendBinding(
        backend: backend,
        identity: _expectedIdentity,
        pathMappings: <VideoDownloadPathMapping>[
          VideoDownloadPathMapping(
            remoteRoot: '/downloads',
            localRoot: downloadDirectory.path,
          ),
        ],
      ),
    );
    addTearDown(environment.close);
    downloadDirectory = Directory(p.join(environment.root.path, 'legacy'));
    await downloadDirectory.create(recursive: true);
    await File(p.join(downloadDirectory.path, 'Show.S01E01.mkv'))
        .writeAsBytes(<int>[1, 2, 3, 4]);
    final File existing =
        File(p.join(downloadDirectory.path, 'Show.S01E01.ja.srt'));
    await existing.writeAsString('user edited subtitle');
    final File staged = File(p.join(environment.root.path, 'episode.zh.srt'));
    await staged.writeAsString('downloaded subtitle');
    const String jobId = 'legacy-no-overwrite-job';
    await environment.insertJob(
      jobId: jobId,
      stage: VideoDownloadJobStage.organize,
      organizationPolicy: 'legacy',
      observedSavePath: '/downloads',
      subtitlePolicy: VideoDownloadSubtitlePolicy.bestEffort,
      withoutTargetSource: true,
    );
    final int now = DateTime.now().millisecondsSinceEpoch;
    await environment.database.upsertVideoDownloadJobSubtitle(
      VideoDownloadJobSubtitlesCompanion.insert(
        subtitleId: 'legacy-subtitle-existing',
        jobId: jobId,
        provider: 'jimaku',
        language: const Value<String?>('zh'),
        episode: const Value<int?>(1),
        originalFileName: const Value<String?>('episode.zh.srt'),
        stagedPath: Value<String?>(staged.path),
        status: const Value<String>(VideoDownloadJobSubtitleStatus.staged),
        createdAt: now,
        updatedAt: now,
      ),
    );

    environment.service.wake();
    await _waitForJob(
      environment.database,
      jobId,
      (VideoDownloadJobRow row) =>
          row.lifecycle == VideoDownloadJobLifecycle.completed,
    );

    expect(await existing.readAsString(), 'user edited subtitle');
    expect(
      await File(p.join(downloadDirectory.path, 'Show.S01E01.zh.srt')).exists(),
      isFalse,
    );
    expect(await staged.exists(), isTrue);
    final VideoDownloadJobSubtitleRow subtitle =
        (await environment.database.getVideoDownloadJobSubtitles(jobId)).single;
    expect(subtitle.status, VideoDownloadJobSubtitleStatus.skipped);
    expect(subtitle.error, contains('sidecar already exists'));
  });

  test('source and observed roots can use different backend path mappings',
      () async {
    final _FakeTorrentBackend backend = _FakeTorrentBackend(
      files: const <TorrentFileEntry>[
        TorrentFileEntry(
          name: 'Show.S01E01.mkv',
          size: 4,
          progress: 1,
          index: 0,
        ),
      ],
    );
    late _PipelineEnvironment environment;
    late Directory downloadDirectory;
    environment = await _PipelineEnvironment.create(
      backend: backend,
      backendResolver: (_) async => VideoDownloadBackendBinding(
        backend: backend,
        identity: _expectedIdentity,
        pathMappings: <VideoDownloadPathMapping>[
          VideoDownloadPathMapping(
            remoteRoot: '/downloads',
            localRoot: downloadDirectory.path,
          ),
          VideoDownloadPathMapping(
            remoteRoot: '/media',
            localRoot: environment.root.path,
          ),
        ],
      ),
    );
    addTearDown(environment.close);
    downloadDirectory = Directory(p.join(environment.root.path, 'incoming'));
    await downloadDirectory.create(recursive: true);
    const String jobId = 'multi-path-mapping-job';
    await environment.insertJob(
      jobId: jobId,
      stage: VideoDownloadJobStage.organize,
      observedSavePath: '/downloads',
      subtitlePolicy: VideoDownloadSubtitlePolicy.none,
    );
    await environment.insertDownloadedFile(
      jobId: jobId,
      name: 'Show.S01E01.mkv',
      size: 4,
    );

    environment.service.wake();
    // P1 契约：anilist 身份不是 MAL/TMDB 规范身份 → import 后直接完成（进视频页
    // 待确认队列），不再被强制刮到 needsAttention。
    await _waitForJob(
      environment.database,
      jobId,
      (VideoDownloadJobRow row) =>
          row.lifecycle == VideoDownloadJobLifecycle.completed,
    );

    expect(backend.moveStoragePaths, <String>['/media']);
    expect(backend.renameFileCalls, 1);
  });

  test('organize validates observed path before backend storage side effects',
      () async {
    final _FakeTorrentBackend backend = _FakeTorrentBackend(
      files: const <TorrentFileEntry>[
        TorrentFileEntry(
          name: 'Show.S01E01.mkv',
          size: 4,
          progress: 1,
          index: 0,
        ),
      ],
    );
    late _PipelineEnvironment environment;
    environment = await _PipelineEnvironment.create(
      backend: backend,
      backendResolver: (_) async => VideoDownloadBackendBinding(
        backend: backend,
        identity: _expectedIdentity,
        pathMappings: <VideoDownloadPathMapping>[
          VideoDownloadPathMapping(
            remoteRoot: '/downloads',
            localRoot: p.join(environment.root.path, 'missing'),
          ),
          VideoDownloadPathMapping(
            remoteRoot: '/media',
            localRoot: environment.root.path,
          ),
        ],
      ),
    );
    addTearDown(environment.close);
    const String jobId = 'inaccessible-observed-path-job';
    await environment.insertJob(
      jobId: jobId,
      stage: VideoDownloadJobStage.organize,
      observedSavePath: '/downloads',
    );
    environment.service.wake();
    final VideoDownloadJobRow job = await _waitForJob(
      environment.database,
      jobId,
      (VideoDownloadJobRow row) =>
          row.lifecycle == VideoDownloadJobLifecycle.needsAttention,
    );
    expect(job.lastError, contains('not accessible'));
    expect(backend.renameFileCalls, 0);
    expect(backend.moveStorageCalls, 0);
  });

  test('organize requires a forward mapping for the managed source root',
      () async {
    final _FakeTorrentBackend backend = _FakeTorrentBackend(
      files: const <TorrentFileEntry>[
        TorrentFileEntry(
          name: 'Show.S01E01.mkv',
          size: 4,
          progress: 1,
          index: 0,
        ),
      ],
    );
    late _PipelineEnvironment environment;
    late Directory downloadDirectory;
    environment = await _PipelineEnvironment.create(
      backend: backend,
      backendResolver: (_) async => VideoDownloadBackendBinding(
        backend: backend,
        identity: _expectedIdentity,
        pathMappings: <VideoDownloadPathMapping>[
          VideoDownloadPathMapping(
            remoteRoot: '/downloads',
            localRoot: downloadDirectory.path,
          ),
        ],
      ),
    );
    addTearDown(environment.close);
    downloadDirectory = Directory(p.join(environment.root.path, 'incoming'));
    await downloadDirectory.create(recursive: true);
    const String jobId = 'unmapped-source-root-job';
    await environment.insertJob(
      jobId: jobId,
      stage: VideoDownloadJobStage.organize,
      observedSavePath: '/downloads',
    );
    environment.service.wake();
    final VideoDownloadJobRow job = await _waitForJob(
      environment.database,
      jobId,
      (VideoDownloadJobRow row) =>
          row.lifecycle == VideoDownloadJobLifecycle.needsAttention,
    );
    expect(job.lastError, contains('outside every backend path mapping'));
    expect(backend.renameFileCalls, 0);
    expect(backend.moveStorageCalls, 0);
  });

  test('unconfigured local backend mapping uses the filesystem anchor',
      () async {
    final _FakeTorrentBackend backend = _FakeTorrentBackend(
      files: const <TorrentFileEntry>[
        TorrentFileEntry(
          name: 'Show.S01E01.mkv',
          size: 4,
          progress: 1,
          index: 0,
        ),
      ],
    );
    final _PipelineEnvironment environment =
        await _PipelineEnvironment.create(backend: backend);
    addTearDown(environment.close);
    final Directory downloadDirectory =
        Directory(p.join(environment.root.path, 'incoming'));
    await downloadDirectory.create(recursive: true);
    const String jobId = 'default-identity-mapping-job';
    await environment.insertJob(
      jobId: jobId,
      stage: VideoDownloadJobStage.organize,
      observedSavePath: downloadDirectory.path,
      subtitlePolicy: VideoDownloadSubtitlePolicy.none,
    );
    await environment.insertDownloadedFile(
      jobId: jobId,
      name: 'Show.S01E01.mkv',
      size: 4,
    );

    environment.service.wake();
    // P1 契约：无 MAL/TMDB 身份 → import 后直接完成，见上一个用例的注释。
    await _waitForJob(
      environment.database,
      jobId,
      (VideoDownloadJobRow row) =>
          row.lifecycle == VideoDownloadJobLifecycle.completed,
    );

    final String absoluteSource =
        p.normalize(p.absolute(environment.root.path));
    final String anchor = p.rootPrefix(absoluteSource);
    final VideoDownloadPathMapping identity = VideoDownloadPathMapping.identity(
        anchor.isEmpty ? absoluteSource : anchor);
    expect(
      backend.moveStoragePaths,
      <String>[identity.localToRemote(environment.root.path)!],
    );
  });

  test('legacy embedded resume ids survive JSON archival until terminal state',
      () async {
    final _PipelineEnvironment environment = await _PipelineEnvironment.create(
      backend: _FakeTorrentBackend(),
    );
    addTearDown(environment.close);
    await environment.insertJob(
      jobId: 'legacy-resume-active',
      stage: VideoDownloadJobStage.download,
      organizationPolicy: 'legacy',
      backendKind: 'embedded',
    );

    expect(
      legacyEmbeddedTorrentResumeIds(
        await environment.database.getVideoDownloadJobs(),
        liveSourceIds: <int>{environment.sourceId},
      ),
      <String>{_torrentHash},
    );
    await environment.database.updateVideoDownloadJob(
      'legacy-resume-active',
      const VideoDownloadJobsCompanion(
        lifecycle: Value<String>(VideoDownloadJobLifecycle.completed),
      ),
    );
    final Set<String> idsAfterCompletion = legacyEmbeddedTorrentResumeIds(
      await environment.database.getVideoDownloadJobs(),
      liveSourceIds: <int>{environment.sourceId},
    );
    expect(idsAfterCompletion, isEmpty);
  });

  test('library embedded resume ids keep completed torrents available to seed',
      () async {
    final _PipelineEnvironment environment = await _PipelineEnvironment.create(
      backend: _FakeTorrentBackend(),
    );
    addTearDown(environment.close);
    await environment.insertJob(
      jobId: 'library-resume-completed',
      stage: VideoDownloadJobStage.scrape,
      organizationPolicy: 'library',
      backendKind: 'embedded',
    );
    await environment.database.updateVideoDownloadJob(
      'library-resume-completed',
      const VideoDownloadJobsCompanion(
        lifecycle: Value<String>(VideoDownloadJobLifecycle.completed),
      ),
    );

    expect(
      legacyEmbeddedTorrentResumeIds(
        await environment.database.getVideoDownloadJobs(),
        liveSourceIds: <int>{environment.sourceId},
      ),
      <String>{_torrentHash},
    );
  });

  test('manual subtitle selection is durable and resumes an actionable job',
      () async {
    final _PipelineEnvironment environment = await _PipelineEnvironment.create(
      backend: _FakeTorrentBackend(),
    );
    addTearDown(environment.close);
    const String jobId = 'manual-subtitle-job';
    await environment.insertJob(
      jobId: jobId,
      stage: VideoDownloadJobStage.download,
    );
    await environment.database.updateVideoDownloadJob(
      jobId,
      const VideoDownloadJobsCompanion(
        lifecycle: Value<String>(VideoDownloadJobLifecycle.needsAttention),
        lastError: Value<String?>('subtitle choice required'),
      ),
    );

    final String subtitleId = await environment.service.attachSubtitleSelection(
      jobId: jobId,
      candidate: _FakeSubtitleCandidate(),
      season: 1,
      episode: 2,
    );

    final VideoDownloadJobSubtitleRow selection =
        (await environment.database.getVideoDownloadJobSubtitles(jobId)).single;
    expect(selection.subtitleId, subtitleId);
    expect(selection.provider, 'opensubtitles');
    expect(selection.selectedSubtitleId, 'subtitle-42');
    expect(selection.season, 1);
    expect(selection.episode, 2);
    expect(selection.status, VideoDownloadJobSubtitleStatus.pending);
    final VideoDownloadJobRow job =
        (await environment.database.getVideoDownloadJob(jobId))!;
    expect(job.lifecycle, VideoDownloadJobLifecycle.active);
    expect(job.lastError, isNull);
  });

  group('per-work subtitle language', () {
    // 与「restart adopts…」用例同一套种子：任务停在 subtitle 阶段、磁盘上有一集
    // 已 organize 好的视频。不预置 resolving 行，让字幕阶段真的去搜。
    Future<_PipelineEnvironment> runSubtitleStage({
      required _FakeSubtitleProvider subtitleProvider,
      VideoDownloadSubtitleLanguageResolver? resolver,
      bool Function(VideoDownloadJobRow row)? until,
      List<String> preferredSubtitleLanguages = const <String>['ja'],
    }) async {
      final _PipelineEnvironment environment =
          await _PipelineEnvironment.create(
        backend: _FakeTorrentBackend(),
        subtitleProvider: subtitleProvider,
        subtitleLanguageResolver: resolver,
        preferredSubtitleLanguages: preferredSubtitleLanguages,
      );
      addTearDown(environment.close);
      const String jobId = 'per-work-language-job';
      await environment.insertJob(
        jobId: jobId,
        stage: VideoDownloadJobStage.subtitle,
      );
      await _seedOrganizedEpisode(environment, jobId);
      environment.service.wake();
      // bestEffort：候选校验不过也只是记「暂无字幕」，任务照样走到 completed。
      await _waitForJob(
        environment.database,
        jobId,
        until ??
            (VideoDownloadJobRow row) =>
                row.lifecycle == VideoDownloadJobLifecycle.completed,
      );
      return environment;
    }

    test('resolver language leads the request but does not narrow it',
        () async {
      final _FakeSubtitleProvider subtitleProvider = _FakeSubtitleProvider(
        bytes: Uint8List.fromList(<int>[49, 10, 50, 10]),
      );
      VideoDownloadSubtitleLanguageQuery? seen;
      await runSubtitleStage(
        subtitleProvider: subtitleProvider,
        resolver: (VideoDownloadSubtitleLanguageQuery query) {
          seen = query;
          return 'zh';
        },
      );
      // 按作品的语言提到首位（排序首选由 explicitLanguage 负责），但**不收窄**
      // 搜索面：它来自字幕工作台的筛选记忆，是「列出来给我看」的 UI 筛选器，不是
      // 「这部番只下这个语言」的下载策略。塞成唯一值会让该语言没字幕的任务一条都
      // 下不到（policy=required 时直接 needsAttention），而用户无处撤销。
      expect(subtitleProvider.lastRequest!.languages, <String>['zh', 'ja']);
      // 查询带的是任务行本身的字段，键与导入落库的合集名同源。
      expect(seen!.jobId, 'per-work-language-job');
      expect(seen!.title, 'Show');
      expect(seen!.year, 2026);
      expect(seen!.seriesKey, 'show (2026)');
      expect(seen!.metadataProvider, 'anilist');
      expect(seen!.externalId, '100');
    });

    test('全局「不限」时按作品的语言不把搜索面收成一个语言', () async {
      final _FakeSubtitleProvider subtitleProvider = _FakeSubtitleProvider(
        bytes: Uint8List.fromList(<int>[49, 10, 50, 10]),
      );
      await runSubtitleStage(
        subtitleProvider: subtitleProvider,
        preferredSubtitleLanguages: const <String>[],
        resolver: (_) => 'zh',
      );
      expect(
        subtitleProvider.lastRequest!.languages,
        isEmpty,
        reason: '全局不限就保持不限，否则该语言没字幕的作品一条都下不到',
      );
    });

    test('null from the resolver keeps the global languages', () async {
      final _FakeSubtitleProvider subtitleProvider = _FakeSubtitleProvider(
        bytes: Uint8List.fromList(<int>[49, 10, 50, 10]),
      );
      await runSubtitleStage(
        subtitleProvider: subtitleProvider,
        resolver: (_) => null,
      );
      expect(subtitleProvider.lastRequest!.languages, <String>['ja']);
    });

    test(
        'a throwing resolver surfaces as a stage error instead of silently '
        'falling back', () async {
      // 解析器读的是本进程内的偏好；它抛了就是偏好层坏了，不能伪装成「没记过
      // 语言」用全局语言下字幕——按阶段异常走可重试路径，错误落在任务行上。
      final _FakeSubtitleProvider subtitleProvider = _FakeSubtitleProvider(
        bytes: Uint8List.fromList(<int>[49, 10, 50, 10]),
      );
      final _PipelineEnvironment environment = await runSubtitleStage(
        subtitleProvider: subtitleProvider,
        resolver: (_) => throw StateError('preferences unavailable'),
        until: (VideoDownloadJobRow row) =>
            (row.lastError ?? '').contains('preferences unavailable'),
      );
      expect(subtitleProvider.searchCalls, 0);
      final VideoDownloadJobRow job = (await environment.database
          .getVideoDownloadJob('per-work-language-job'))!;
      expect(job.lifecycle, isNot(VideoDownloadJobLifecycle.completed));
      expect(job.stage, VideoDownloadJobStage.subtitle);
    });
  });

  test(
      'restart adopts an already-written resolving subtitle without duplicating it',
      () async {
    final Uint8List subtitleBytes = Uint8List.fromList(<int>[49, 10, 50, 10]);
    final _FakeSubtitleProvider subtitleProvider = _FakeSubtitleProvider(
      bytes: subtitleBytes,
    );
    final _PipelineEnvironment environment = await _PipelineEnvironment.create(
      backend: _FakeTorrentBackend(),
      subtitleProvider: subtitleProvider,
    );
    addTearDown(environment.close);
    const String jobId = 'subtitle-rename-crash-job';
    await environment.insertJob(
      jobId: jobId,
      stage: VideoDownloadJobStage.subtitle,
    );
    final Directory season = Directory(
      p.join(environment.root.path, 'Show (2026)', 'Season 01'),
    );
    await season.create(recursive: true);
    final File video = File(
      p.join(season.path, 'Show (2026) - S01E02.mkv'),
    );
    await video.writeAsBytes(<int>[0, 1, 2, 3], flush: true);
    final int now = DateTime.now().millisecondsSinceEpoch;
    await environment.database.upsertVideoDownloadJobFile(
      VideoDownloadJobFilesCompanion.insert(
        jobId: jobId,
        backendFileIndex: const Value<int?>(0),
        originalRelativePath: p.basename(video.path),
        currentRelativePath: p.basename(video.path),
        targetRelativePath: Value<String?>(p.basename(video.path)),
        finalAbsolutePath: Value<String?>(video.path),
        kind: const Value<String>('video'),
        season: const Value<int?>(1),
        episode: const Value<int?>(2),
        sizeBytes: Value<int?>(await video.length()),
        status: const Value<String>(VideoDownloadJobFileStatus.organized),
        createdAt: now,
        updatedAt: now,
      ),
    );
    final VideoDownloadJobFileRow jobFile =
        (await environment.database.getVideoDownloadJobFiles(jobId)).single;
    final File installed = File(
      p.join(season.path, 'Show (2026) - S01E02.zh-cn.srt'),
    );
    await installed.writeAsBytes(subtitleBytes, flush: true);
    await environment.database.upsertVideoDownloadJobSubtitle(
      VideoDownloadJobSubtitlesCompanion.insert(
        subtitleId: '$jobId:auto',
        jobId: jobId,
        jobFileId: Value<int?>(jobFile.id),
        provider: 'opensubtitles',
        selectedSubtitleId: const Value<String?>('subtitle-42'),
        language: const Value<String?>('zh-cn'),
        season: const Value<int?>(1),
        episode: const Value<int?>(2),
        originalFileName: const Value<String?>('Show.zh.srt'),
        stagedPath: Value<String?>('${installed.path}.$jobId.fushi.tmp'),
        finalPath: Value<String?>(installed.path),
        status: const Value<String>(
          VideoDownloadJobSubtitleStatus.resolving,
        ),
        createdAt: now,
        updatedAt: now,
      ),
    );

    environment.service.wake();
    // P1 契约：无 MAL/TMDB 身份 → import 后直接完成，字幕落位断言不受影响。
    await _waitForJob(
      environment.database,
      jobId,
      (VideoDownloadJobRow row) =>
          row.lifecycle == VideoDownloadJobLifecycle.completed,
    );

    final VideoDownloadJobSubtitleRow subtitle =
        (await environment.database.getVideoDownloadJobSubtitles(jobId)).single;
    expect(subtitle.status, VideoDownloadJobSubtitleStatus.placed);
    expect(subtitle.finalPath, installed.path);
    expect(subtitleProvider.searchCalls, 1);
    expect(subtitleProvider.downloadCalls, 1);
    final List<FileSystemEntity> sidecars = (await season.list().toList())
        .where((FileSystemEntity entity) =>
            entity is File && p.extension(entity.path) == '.srt')
        .toList(growable: false);
    expect(sidecars, hasLength(1));
    final List<MediaCollectionRow> collections =
        await environment.database.getAllMediaCollections();
    expect(collections.single.name, 'Show (2026)');
  });

  test(
      'restart adopts a previously aligned sidecar even if alignment would now differ',
      () async {
    final Uint8List subtitleBytes = Uint8List.fromList(<int>[49, 10, 50, 10]);
    final _FakeSubtitleProvider subtitleProvider = _FakeSubtitleProvider(
      bytes: subtitleBytes,
    );
    // 首跑写下的是对齐版（原稿登记在对齐备份里）；这一轮的对齐器给出不同结果
    // （开关变了 / 抽轨临时失败）。续跑必须认领首跑那份，不能另写 .fushiN。
    final Uint8List firstRunAligned = Uint8List.fromList(<int>[50, 10, 51, 10]);
    int alignerCalls = 0;
    final EnginePaths savedPaths = enginePaths;
    final Directory pathsRoot =
        await Directory.systemTemp.createTemp('fushi-align-backup-');
    enginePaths = FixedEnginePaths(
      documents: pathsRoot,
      support: pathsRoot,
      temp: pathsRoot,
    );
    addTearDown(() async {
      enginePaths = savedPaths;
      await pathsRoot.delete(recursive: true);
    });
    await saveSubtitleAlignmentOriginal(
      original: subtitleBytes,
      aligned: firstRunAligned,
    );
    final _PipelineEnvironment environment = await _PipelineEnvironment.create(
      backend: _FakeTorrentBackend(),
      subtitleProvider: subtitleProvider,
      subtitleAligner: (Uint8List bytes, String videoPath) async {
        alignerCalls++;
        return Uint8List.fromList(<int>[57, 10]);
      },
    );
    addTearDown(environment.close);
    const String jobId = 'subtitle-rename-crash-job';
    await environment.insertJob(
      jobId: jobId,
      stage: VideoDownloadJobStage.subtitle,
    );
    final Directory season = Directory(
      p.join(environment.root.path, 'Show (2026)', 'Season 01'),
    );
    await season.create(recursive: true);
    final File video = File(
      p.join(season.path, 'Show (2026) - S01E02.mkv'),
    );
    await video.writeAsBytes(<int>[0, 1, 2, 3], flush: true);
    final int now = DateTime.now().millisecondsSinceEpoch;
    await environment.database.upsertVideoDownloadJobFile(
      VideoDownloadJobFilesCompanion.insert(
        jobId: jobId,
        backendFileIndex: const Value<int?>(0),
        originalRelativePath: p.basename(video.path),
        currentRelativePath: p.basename(video.path),
        targetRelativePath: Value<String?>(p.basename(video.path)),
        finalAbsolutePath: Value<String?>(video.path),
        kind: const Value<String>('video'),
        season: const Value<int?>(1),
        episode: const Value<int?>(2),
        sizeBytes: Value<int?>(await video.length()),
        status: const Value<String>(VideoDownloadJobFileStatus.organized),
        createdAt: now,
        updatedAt: now,
      ),
    );
    final VideoDownloadJobFileRow jobFile =
        (await environment.database.getVideoDownloadJobFiles(jobId)).single;
    final File installed = File(
      p.join(season.path, 'Show (2026) - S01E02.zh-cn.srt'),
    );
    await installed.writeAsBytes(firstRunAligned, flush: true);
    await environment.database.upsertVideoDownloadJobSubtitle(
      VideoDownloadJobSubtitlesCompanion.insert(
        subtitleId: '$jobId:auto',
        jobId: jobId,
        jobFileId: Value<int?>(jobFile.id),
        provider: 'opensubtitles',
        selectedSubtitleId: const Value<String?>('subtitle-42'),
        language: const Value<String?>('zh-cn'),
        season: const Value<int?>(1),
        episode: const Value<int?>(2),
        originalFileName: const Value<String?>('Show.zh.srt'),
        stagedPath: Value<String?>('${installed.path}.$jobId.fushi.tmp'),
        finalPath: Value<String?>(installed.path),
        status: const Value<String>(
          VideoDownloadJobSubtitleStatus.resolving,
        ),
        createdAt: now,
        updatedAt: now,
      ),
    );

    environment.service.wake();
    // P1 契约：无 MAL/TMDB 身份 → import 后直接完成，字幕落位断言不受影响。
    await _waitForJob(
      environment.database,
      jobId,
      (VideoDownloadJobRow row) =>
          row.lifecycle == VideoDownloadJobLifecycle.completed,
    );

    final VideoDownloadJobSubtitleRow subtitle =
        (await environment.database.getVideoDownloadJobSubtitles(jobId)).single;
    expect(subtitle.status, VideoDownloadJobSubtitleStatus.placed);
    expect(subtitle.finalPath, installed.path);
    expect(subtitleProvider.searchCalls, 1);
    expect(subtitleProvider.downloadCalls, 1);
    final List<FileSystemEntity> sidecars = (await season.list().toList())
        .where((FileSystemEntity entity) =>
            entity is File && p.extension(entity.path) == '.srt')
        .toList(growable: false);
    expect(sidecars, hasLength(1));
    expect(await installed.readAsBytes(), firstRunAligned);
    expect(alignerCalls, 0);
    final List<MediaCollectionRow> collections =
        await environment.database.getAllMediaCollections();
    expect(collections.single.name, 'Show (2026)');
  });

  test(
      'sidecar extension follows the downloaded file name, not the pre-download guess',
      () async {
    // SubDL 这类打包源的候选名是 `<release>.srt` 猜测，解 zip 后才知道是 .ass；
    // 管线落盘的扩展名必须按 download.fileName 定。字节要过时轴校验，给真 cue。
    final Uint8List subtitleBytes = Uint8List.fromList(
      utf8.encode('1\n00:00:01,000 --> 00:00:02,000\nhi\n'),
    );
    final _FakeSubtitleProvider subtitleProvider = _FakeSubtitleProvider(
      bytes: subtitleBytes,
      downloadFileName: 'Show.S01E02.zh.ass',
    );
    final _PipelineEnvironment environment = await _PipelineEnvironment.create(
      backend: _FakeTorrentBackend(),
      subtitleProvider: subtitleProvider,
    );
    addTearDown(environment.close);
    const String jobId = 'subtitle-ext-from-download-job';
    await environment.insertJob(
      jobId: jobId,
      stage: VideoDownloadJobStage.subtitle,
    );
    final Directory season = Directory(
      p.join(environment.root.path, 'Show (2026)', 'Season 01'),
    );
    await season.create(recursive: true);
    final File video = File(
      p.join(season.path, 'Show (2026) - S01E02.mkv'),
    );
    await video.writeAsBytes(<int>[0, 1, 2, 3], flush: true);
    final int now = DateTime.now().millisecondsSinceEpoch;
    await environment.database.upsertVideoDownloadJobFile(
      VideoDownloadJobFilesCompanion.insert(
        jobId: jobId,
        backendFileIndex: const Value<int?>(0),
        originalRelativePath: p.basename(video.path),
        currentRelativePath: p.basename(video.path),
        targetRelativePath: Value<String?>(p.basename(video.path)),
        finalAbsolutePath: Value<String?>(video.path),
        kind: const Value<String>('video'),
        season: const Value<int?>(1),
        episode: const Value<int?>(2),
        sizeBytes: Value<int?>(await video.length()),
        status: const Value<String>(VideoDownloadJobFileStatus.organized),
        createdAt: now,
        updatedAt: now,
      ),
    );
    final VideoDownloadJobFileRow jobFile =
        (await environment.database.getVideoDownloadJobFiles(jobId)).single;
    final String guessedTarget = p.join(
      season.path,
      'Show (2026) - S01E02.zh-cn.srt',
    );
    await environment.database.upsertVideoDownloadJobSubtitle(
      VideoDownloadJobSubtitlesCompanion.insert(
        subtitleId: '$jobId:auto',
        jobId: jobId,
        jobFileId: Value<int?>(jobFile.id),
        provider: 'opensubtitles',
        selectedSubtitleId: const Value<String?>('subtitle-42'),
        language: const Value<String?>('zh-cn'),
        season: const Value<int?>(1),
        episode: const Value<int?>(2),
        originalFileName: const Value<String?>('Show.S01E02.zh.srt'),
        // 下载前按候选名猜出的 .srt 目标已持久化（resolving），进程重启后续跑：
        // 管线复用这一行，落盘扩展名仍要按下载后的真实文件名改成 .ass。
        stagedPath: Value<String?>('$guessedTarget.$jobId.fushi.tmp'),
        finalPath: Value<String?>(guessedTarget),
        status: const Value<String>(VideoDownloadJobSubtitleStatus.resolving),
        createdAt: now,
        updatedAt: now,
      ),
    );

    environment.service.wake();
    await _waitForJob(
      environment.database,
      jobId,
      (VideoDownloadJobRow row) =>
          row.lifecycle == VideoDownloadJobLifecycle.completed,
    );

    final VideoDownloadJobSubtitleRow subtitle =
        (await environment.database.getVideoDownloadJobSubtitles(jobId)).single;
    expect(subtitle.status, VideoDownloadJobSubtitleStatus.placed);
    expect(subtitle.originalFileName, 'Show.S01E02.zh.ass');
    expect(
      subtitle.finalPath,
      p.join(season.path, 'Show (2026) - S01E02.zh-cn.ass'),
    );
    expect(await File(subtitle.finalPath!).exists(), isTrue);
    expect(await File(guessedTarget).exists(), isFalse);
  });

  test('scrape never falls back to a same-title unrelated local work',
      () async {
    final _PipelineEnvironment environment = await _PipelineEnvironment.create(
      backend: _FakeTorrentBackend(),
    );
    addTearDown(environment.close);
    const String jobId = 'exact-scrape-path-job';
    // P1 起 scrape 阶段只对带 MAL/TMDB 规范身份的任务运行；本用例守的是
    // 「身份确认后也绝不按标题回退映射」，故显式带上 MAL 身份。
    await environment.insertJob(
      jobId: jobId,
      stage: VideoDownloadJobStage.scrape,
      identityJson: encodeVideoMediaReference(_confirmedReference()),
    );
    await environment.database.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value<String>('video/unrelated-show'),
        title: const Value<String>('Show'),
        videoPath: Value<String>(p.join(environment.root.path, 'Other.mkv')),
        sourceId: Value<int?>(environment.sourceId),
      ),
    );
    final int now = DateTime.now().millisecondsSinceEpoch;
    await environment.database.upsertVideoDownloadJobFile(
      VideoDownloadJobFilesCompanion.insert(
        jobId: jobId,
        backendFileIndex: const Value<int?>(0),
        originalRelativePath: 'Missing.mkv',
        currentRelativePath: 'Missing.mkv',
        finalAbsolutePath: Value<String?>(
          p.join(environment.root.path, 'Missing.mkv'),
        ),
        kind: const Value<String>('video'),
        status: const Value<String>(VideoDownloadJobFileStatus.imported),
        createdAt: now,
        updatedAt: now,
      ),
    );

    environment.service.wake();
    final VideoDownloadJobRow job = await _waitForJob(
      environment.database,
      jobId,
      (VideoDownloadJobRow row) =>
          row.lifecycle == VideoDownloadJobLifecycle.needsAttention,
    );

    // 导入路径在库里根本没有行：报的是「不在视频库里」而不是笼统的映射失败。
    expect(job.lastError, contains('missing from the video library'));
    expect(job.lastError, contains('Missing.mkv'));
  });

  for (final bool legacyAniDb in <bool>[false, true]) {
    test(
        'a scrape-stage job without a MAL/TMDB identity completes instead of '
        'getting pinned on needsAttention (legacy AniDB: $legacyAniDb)',
        () async {
      final _PipelineEnvironment environment =
          await _PipelineEnvironment.create(
        backend: _FakeTorrentBackend(),
      );
      addTearDown(environment.close);
      const String jobId = 'anilist-only-scrape-job';
      // insertJob 默认身份是 anilist:100 —— 修前它会被强制模糊刮到歧义卡死。
      await environment.insertJob(
        jobId: jobId,
        stage: VideoDownloadJobStage.scrape,
        identityJson: legacyAniDb
            ? encodeVideoMediaReference(VideoMediaReference(
                providerId: 'anidb',
                mediaId: '42',
                anidbId: 42,
                mediaKind: VideoMetadataMediaKind.tv,
                discoveryCategory: VideoDiscoveryCategory.anime,
                title: 'Show',
              ))
            : null,
      );

      environment.service.wake();
      await _waitForJob(
        environment.database,
        jobId,
        (VideoDownloadJobRow row) =>
            row.lifecycle == VideoDownloadJobLifecycle.completed,
      );
    });
  }

  for (final VideoMetadataProviderKind provider in <VideoMetadataProviderKind>[
    VideoMetadataProviderKind.mal,
    VideoMetadataProviderKind.tmdb,
  ]) {
    for (final VideoMetadataMediaKind kind in VideoMetadataMediaKind.values) {
      test(
          'enqueue snapshot passes confirmed ${provider.name} ${kind.name} lookup',
          () async {
        final _RecordingMetadataProvider recorder =
            _RecordingMetadataProvider(provider);
        final _PipelineEnvironment environment =
            await _PipelineEnvironment.create(
          backend: _FakeTorrentBackend(),
          metadataProvider: recorder,
        );
        addTearDown(environment.close);
        const String jobId = 'confirmed-scrape-job';
        await environment.insertJob(
          jobId: jobId,
          stage: VideoDownloadJobStage.scrape,
          mediaKind: kind.name,
          identityJson: encodeVideoMediaReference(
              _confirmedReference(provider: provider, kind: kind)),
        );
        final String videoPath = p.join(environment.root.path, 'Show.mkv');
        await environment.database.upsertVideoBook(
          VideoBooksCompanion(
            bookUid: const Value<String>('video/anidb-show'),
            title: const Value<String>('Show'),
            videoPath: Value<String>(videoPath),
            sourceId: Value<int?>(environment.sourceId),
          ),
        );
        final int now = DateTime.now().millisecondsSinceEpoch;
        await environment.database.upsertVideoDownloadJobFile(
          VideoDownloadJobFilesCompanion.insert(
            jobId: jobId,
            backendFileIndex: const Value<int?>(0),
            originalRelativePath: 'Show.mkv',
            currentRelativePath: 'Show.mkv',
            finalAbsolutePath: Value<String?>(videoPath),
            kind: const Value<String>('video'),
            status: const Value<String>(VideoDownloadJobFileStatus.imported),
            createdAt: now,
            updatedAt: now,
          ),
        );

        environment.service.wake();
        final VideoDownloadJobRow job = await _waitForJob(
          environment.database,
          jobId,
          (VideoDownloadJobRow row) =>
              row.lifecycle == VideoDownloadJobLifecycle.needsAttention,
        );

        expect(job.lastError, contains('recorded confirmed lookup'));
        expect(recorder.lookups, hasLength(1));
        expect(recorder.lookups.single.provider, provider);
        expect(recorder.lookups.single.externalId, '42');
        expect(recorder.lookups.single.mediaKind, kind);
        expect(recorder.searchCalls, 0);
      });
    }
  }
  test(
      'subscription import publishes a per-work episode update with frame, '
      'release info and published time', () async {
    final _RecordingUpdateFeed feed = _RecordingUpdateFeed();
    final List<String> extracted = <String>[];
    final Directory frames =
        await Directory.systemTemp.createTemp('fushi-episode-frames-');
    addTearDown(() => frames.delete(recursive: true));
    final _PipelineEnvironment environment = await _PipelineEnvironment.create(
      backend: _FakeTorrentBackend(),
      updateFeed: feed,
      coverExtractor: ({
        required String videoPath,
        required String bookUid,
        double atSeconds = 10.0,
      }) async {
        extracted.add(videoPath);
        final File frame = File(
          p.join(frames.path, '${bookUid.replaceAll('/', '_')}.jpg'),
        );
        await frame.create(recursive: true);
        return frame.path;
      },
    );
    addTearDown(environment.close);
    const String jobId = 'subscription-episode-job';
    await environment.insertJob(
      jobId: jobId,
      stage: VideoDownloadJobStage.import,
    );
    await environment.database.updateVideoDownloadJob(
      jobId,
      const VideoDownloadJobsCompanion(
        resourceTitle: Value<String?>(
          '[SubsPlease] Show - 02 (1080p) [A1B2C3D4].mkv',
        ),
      ),
    );
    const int publishedAt = 1_760_000_000_000;
    await environment.database.upsertVideoDownloadSubscription(
      VideoDownloadSubscriptionsCompanion.insert(
        subscriptionId: 'sub-1',
        resourceProvider: 'nyaa:test-instance',
        mediaKind: 'tv',
        title: 'Show',
        searchQuery: 'Show',
        backendKind: 'embedded',
        fingerprint: _expectedIdentity.fingerprint,
        createdAt: 1,
        updatedAt: 1,
      ),
    );
    await environment.database.upsertVideoDownloadSubscriptionItem(
      VideoDownloadSubscriptionItemsCompanion.insert(
        subscriptionId: 'sub-1',
        logicalItemKey: 's1e2',
        resourceProvider: 'nyaa:test-instance',
        selectedResourceId: 'release-1',
        title: 'Show - 02',
        season: const Value<int?>(1),
        episode: const Value<int?>(2),
        publishedAt: const Value<int?>(publishedAt),
        jobId: const Value<String?>(jobId),
        discoveredAt: 1,
        updatedAt: 1,
      ),
    );
    final int now = DateTime.now().millisecondsSinceEpoch;
    final String videoPath = p.join(
      environment.root.path,
      'Show (2026)',
      'Show S01E02.mkv',
    );
    await environment.database.upsertVideoDownloadJobFile(
      VideoDownloadJobFilesCompanion.insert(
        jobId: jobId,
        backendFileIndex: const Value<int?>(0),
        originalRelativePath: 'Show S01E02.mkv',
        currentRelativePath: 'Show S01E02.mkv',
        finalAbsolutePath: Value<String?>(videoPath),
        kind: const Value<String>('video'),
        season: const Value<int?>(1),
        episode: const Value<int?>(2),
        status: const Value<String>(VideoDownloadJobFileStatus.organized),
        createdAt: now,
        updatedAt: now,
      ),
    );

    environment.service.wake();
    await _waitForJob(
      environment.database,
      jobId,
      (VideoDownloadJobRow row) =>
          row.lifecycle == VideoDownloadJobLifecycle.completed,
    );

    expect(feed.batches, hasLength(1));
    expect(feed.batches.single.kind, UpdateFeedKind.videoEpisode);
    final UpdateFeedDraft draft = feed.batches.single.drafts.single;
    expect(draft.title, 'Show');
    expect(draft.subtitle, 'S01E02 · 1080p · SubsPlease');
    expect(draft.publishedAt, publishedAt);
    expect(extracted, <String>[videoPath]);
    expect(draft.imagePath, isNotNull);
    expect(File(draft.imagePath!).existsSync(), isTrue);
    final Map<String, Object?> detail =
        jsonDecode(draft.detailJson!) as Map<String, Object?>;
    expect(draft.notificationGroup, 'collection:${detail['collectionId']}');
    expect(detail['imagePath'], draft.imagePath);
    expect(detail['publishedAt'], publishedAt);
    // 抽的那帧顺手就是这集的书架封面。
    final VideoBookRow? book = await environment.database.getVideoBookByBookUid(
      detail['bookUid'] as String,
    );
    expect(book?.coverPath, draft.imagePath);
  });

  test(
      'a single confirmed tv episode imported by the pipeline maps back to its '
      'managed source for scraping', () async {
    // 用户 2026-09-21：视频发现下载单集番剧，下载完成后报「Imported media could
    // not be mapped exactly back to its managed source」。import 建的是单成员
    // 播放列表，scrape 阶段必须仍能按导入路径找回这部作品。
    final _PipelineEnvironment environment = await _PipelineEnvironment.create(
      backend: _FakeTorrentBackend(),
    );
    addTearDown(environment.close);
    const String jobId = 'single-episode-scrape-job';
    await environment.insertJob(
      jobId: jobId,
      stage: VideoDownloadJobStage.import,
      identityJson: encodeVideoMediaReference(_confirmedReference()),
    );
    final int now = DateTime.now().millisecondsSinceEpoch;
    final String videoPath = p.join(
      environment.root.path,
      'Show (2026)',
      '[Group] Show - 07 [WebRip 1080p HEVC-10bit AAC ASSx2].mkv',
    );
    await File(videoPath).create(recursive: true);
    await environment.database.upsertVideoDownloadJobFile(
      VideoDownloadJobFilesCompanion.insert(
        jobId: jobId,
        backendFileIndex: const Value<int?>(0),
        originalRelativePath: p.basename(videoPath),
        currentRelativePath: p.basename(videoPath),
        finalAbsolutePath: Value<String?>(videoPath),
        kind: const Value<String>('video'),
        season: const Value<int?>(1),
        episode: const Value<int?>(7),
        status: const Value<String>(VideoDownloadJobFileStatus.organized),
        createdAt: now,
        updatedAt: now,
      ),
    );

    environment.service.wake();
    // 测试环境没有 MAL/TMDB provider：能走到「主资料源不可用」就证明路径映射
    // 成功、lookup 进了协调器；「mapped exactly」才是这条 bug。
    final VideoDownloadJobRow job = await _waitForJob(
      environment.database,
      jobId,
      (VideoDownloadJobRow row) =>
          row.lifecycle == VideoDownloadJobLifecycle.needsAttention ||
          row.lifecycle == VideoDownloadJobLifecycle.completed,
    );
    expect(job.stage, VideoDownloadJobStage.scrape);
    expect(job.lastError, isNot(contains('mapped exactly')));
  });

  test(
      'a confirmed episode indexed first under another source is re-owned by '
      'the managed source and scraped', () async {
    // 扫描器（重叠来源 / 竞态）抢先按别的来源建了这一集的行：文件物理上就在
    // 托管来源根目录里，scrape 阶段按托管来源收口归属，而不是「映射不回来源」。
    final _PipelineEnvironment environment = await _PipelineEnvironment.create(
      backend: _FakeTorrentBackend(),
    );
    addTearDown(environment.close);
    final int otherSourceId = await environment.database.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Overlapping library',
        mediaKind: 'video',
        rootPath: environment.root.parent.path,
        createdAt: 1,
      ),
    );
    const String jobId = 'foreign-source-scrape-job';
    await environment.insertJob(
      jobId: jobId,
      stage: VideoDownloadJobStage.scrape,
      identityJson: encodeVideoMediaReference(_confirmedReference()),
    );
    final String videoPath = p.join(
      environment.root.path,
      'Show (2026)',
      'Show S01E07.mkv',
    );
    await environment.database.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value<String>('video/show-s01e07'),
        title: const Value<String>('Show S01E07'),
        videoPath: Value<String>(videoPath),
        sourceId: Value<int?>(otherSourceId),
      ),
    );
    final int now = DateTime.now().millisecondsSinceEpoch;
    await environment.database.upsertVideoDownloadJobFile(
      VideoDownloadJobFilesCompanion.insert(
        jobId: jobId,
        backendFileIndex: const Value<int?>(0),
        originalRelativePath: 'Show S01E07.mkv',
        currentRelativePath: 'Show S01E07.mkv',
        finalAbsolutePath: Value<String?>(videoPath),
        kind: const Value<String>('video'),
        status: const Value<String>(VideoDownloadJobFileStatus.imported),
        createdAt: now,
        updatedAt: now,
      ),
    );

    environment.service.wake();
    final VideoDownloadJobRow job = await _waitForJob(
      environment.database,
      jobId,
      (VideoDownloadJobRow row) =>
          row.lifecycle == VideoDownloadJobLifecycle.needsAttention,
    );
    // 测试环境没有 MAL/TMDB provider：走到「主资料源不可用」= 映射成功。
    expect(job.lastError, isNot(contains('mapped exactly')));
    expect(job.lastError?.toLowerCase(), contains('mal'));
    final VideoBookRow book = (await environment.database
        .getVideoBookByBookUid('video/show-s01e07'))!;
    expect(book.sourceId, environment.sourceId);
  });

  test(
      'scrape failing only because the metadata provider returned 504 is '
      'retried with backoff instead of parking on needsAttention', () async {
    final _PipelineEnvironment environment = await _PipelineEnvironment.create(
      backend: _FakeTorrentBackend(),
      metadataProvider: _GatewayTimeoutMalProvider(),
    );
    addTearDown(environment.close);
    const String jobId = 'transient-scrape-job';
    await environment.insertJob(
      jobId: jobId,
      stage: VideoDownloadJobStage.scrape,
      identityJson: encodeVideoMediaReference(_confirmedReference()),
    );
    final String videoPath = p.join(
      environment.root.path,
      'Show (2026)',
      'Show S01E01.mkv',
    );
    await environment.database.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value<String>('video/show-s01e01'),
        title: const Value<String>('Show S01E01'),
        videoPath: Value<String>(videoPath),
        sourceId: Value<int?>(environment.sourceId),
      ),
    );
    final int now = DateTime.now().millisecondsSinceEpoch;
    await environment.database.upsertVideoDownloadJobFile(
      VideoDownloadJobFilesCompanion.insert(
        jobId: jobId,
        backendFileIndex: const Value<int?>(0),
        originalRelativePath: 'Show S01E01.mkv',
        currentRelativePath: 'Show S01E01.mkv',
        finalAbsolutePath: Value<String?>(videoPath),
        kind: const Value<String>('video'),
        status: const Value<String>(VideoDownloadJobFileStatus.imported),
        createdAt: now,
        updatedAt: now,
      ),
    );

    environment.service.wake();
    final VideoDownloadJobRow job = await _waitForJob(
      environment.database,
      jobId,
      (VideoDownloadJobRow row) =>
          row.lifecycle == VideoDownloadJobLifecycle.needsAttention ||
          row.attemptCount > 0,
    );
    expect(job.lifecycle, VideoDownloadJobLifecycle.active,
        reason: '${job.lastError}');
    expect(job.stage, VideoDownloadJobStage.scrape);
    expect(job.attemptCount, 1);
    expect(job.nextAttemptAt, isNotNull);
    expect(job.lastError, contains('504'));
  });

  test(
      'provider still 504 on the last attempt: the download completes and '
      'the scrape is left to the library backfill (not failed)', () async {
    final _PipelineEnvironment environment = await _PipelineEnvironment.create(
      backend: _FakeTorrentBackend(),
      metadataProvider: _GatewayTimeoutMalProvider(),
    );
    addTearDown(environment.close);
    const String jobId = 'transient-scrape-exhausted-job';
    await environment.insertJob(
      jobId: jobId,
      stage: VideoDownloadJobStage.scrape,
      identityJson: encodeVideoMediaReference(_confirmedReference()),
    );
    final VideoDownloadJobRow inserted =
        (await environment.database.getVideoDownloadJob(jobId))!;
    await (environment.database.update(environment.database.videoDownloadJobs)
          ..where((tbl) => tbl.jobId.equals(jobId)))
        .write(
      VideoDownloadJobsCompanion(
        attemptCount: Value<int>(inserted.maxAttempts - 1),
      ),
    );
    final String videoPath = p.join(
      environment.root.path,
      'Show (2026)',
      'Show S01E01.mkv',
    );
    await environment.database.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value<String>('video/show-s01e01'),
        title: const Value<String>('Show S01E01'),
        videoPath: Value<String>(videoPath),
        sourceId: Value<int?>(environment.sourceId),
      ),
    );
    final int now = DateTime.now().millisecondsSinceEpoch;
    await environment.database.upsertVideoDownloadJobFile(
      VideoDownloadJobFilesCompanion.insert(
        jobId: jobId,
        backendFileIndex: const Value<int?>(0),
        originalRelativePath: 'Show S01E01.mkv',
        currentRelativePath: 'Show S01E01.mkv',
        finalAbsolutePath: Value<String?>(videoPath),
        kind: const Value<String>('video'),
        status: const Value<String>(VideoDownloadJobFileStatus.imported),
        createdAt: now,
        updatedAt: now,
      ),
    );

    environment.service.wake();
    final VideoDownloadJobRow job = await _waitForJob(
      environment.database,
      jobId,
      (VideoDownloadJobRow row) =>
          row.lifecycle != VideoDownloadJobLifecycle.active,
    );
    expect(job.lifecycle, VideoDownloadJobLifecycle.completed,
        reason: '${job.lastError}');
  });

  test(
      'a confirmed download into a folder-grouped source completes without '
      'a metadata scrape', () async {
    // 「按文件夹」来源只整理不刮削：计划器对它恒空，之前会把每条带身份的任务
    // 都报成「映射不回来源」。
    final _PipelineEnvironment environment = await _PipelineEnvironment.create(
      backend: _FakeTorrentBackend(),
    );
    addTearDown(environment.close);
    await (environment.database.update(environment.database.mediaSources)
          ..where((tbl) => tbl.id.equals(environment.sourceId)))
        .write(
      const MediaSourcesCompanion(
        videoGroupingMode: Value<String>('folder'),
      ),
    );
    const String jobId = 'folder-mode-scrape-job';
    await environment.insertJob(
      jobId: jobId,
      stage: VideoDownloadJobStage.scrape,
      identityJson: encodeVideoMediaReference(_confirmedReference()),
    );
    final String videoPath = p.join(environment.root.path, 'Show S01E07.mkv');
    await environment.database.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value<String>('video/folder-show'),
        title: const Value<String>('Show S01E07'),
        videoPath: Value<String>(videoPath),
        sourceId: Value<int?>(environment.sourceId),
      ),
    );
    final int now = DateTime.now().millisecondsSinceEpoch;
    await environment.database.upsertVideoDownloadJobFile(
      VideoDownloadJobFilesCompanion.insert(
        jobId: jobId,
        backendFileIndex: const Value<int?>(0),
        originalRelativePath: 'Show S01E07.mkv',
        currentRelativePath: 'Show S01E07.mkv',
        finalAbsolutePath: Value<String?>(videoPath),
        kind: const Value<String>('video'),
        status: const Value<String>(VideoDownloadJobFileStatus.imported),
        createdAt: now,
        updatedAt: now,
      ),
    );

    environment.service.wake();
    final VideoDownloadJobRow job = await _waitForJob(
      environment.database,
      jobId,
      (VideoDownloadJobRow row) =>
          row.lifecycle == VideoDownloadJobLifecycle.completed ||
          row.lifecycle == VideoDownloadJobLifecycle.needsAttention,
    );
    expect(job.lifecycle, VideoDownloadJobLifecycle.completed,
        reason: '${job.lastError}');
  });

  test('manual (non-subscription) import publishes no episode update',
      () async {
    final _RecordingUpdateFeed feed = _RecordingUpdateFeed();
    final _PipelineEnvironment environment = await _PipelineEnvironment.create(
      backend: _FakeTorrentBackend(),
      updateFeed: feed,
      coverExtractor: ({
        required String videoPath,
        required String bookUid,
        double atSeconds = 10.0,
      }) async =>
          fail('manual import must not extract a notification frame'),
    );
    addTearDown(environment.close);
    const String jobId = 'manual-episode-job';
    await environment.insertJob(
      jobId: jobId,
      stage: VideoDownloadJobStage.import,
    );
    final int now = DateTime.now().millisecondsSinceEpoch;
    await environment.database.upsertVideoDownloadJobFile(
      VideoDownloadJobFilesCompanion.insert(
        jobId: jobId,
        backendFileIndex: const Value<int?>(0),
        originalRelativePath: 'Show S01E02.mkv',
        currentRelativePath: 'Show S01E02.mkv',
        finalAbsolutePath: Value<String?>(
          p.join(environment.root.path, 'Show S01E02.mkv'),
        ),
        kind: const Value<String>('video'),
        season: const Value<int?>(1),
        episode: const Value<int?>(2),
        status: const Value<String>(VideoDownloadJobFileStatus.organized),
        createdAt: now,
        updatedAt: now,
      ),
    );

    environment.service.wake();
    await _waitForJob(
      environment.database,
      jobId,
      (VideoDownloadJobRow row) =>
          row.lifecycle == VideoDownloadJobLifecycle.completed,
    );
    expect(feed.batches, isEmpty);
  });

  group('subscriptionReleaseLabel', () {
    test('picks resolution and leading group, ignores hash brackets', () {
      expect(
        VideoDownloadPipelineService.subscriptionReleaseLabel(
          '[SubsPlease] Show - 02 (1080p) [A1B2C3D4].mkv',
        ),
        '1080p · SubsPlease',
      );
      expect(
        VideoDownloadPipelineService.subscriptionReleaseLabel(
          '[A1B2C3D4] Show 02 720P',
        ),
        '720P',
      );
      expect(
        VideoDownloadPipelineService.subscriptionReleaseLabel(
          '[1080p][Group] Show - 01',
        ),
        '1080p',
        reason: '首方括号就是分辨率时不当字幕组，否则副标题「1080p · 1080p」',
      );
      expect(
        VideoDownloadPipelineService.subscriptionReleaseLabel('Show 02'),
        isNull,
      );
      expect(
        VideoDownloadPipelineService.subscriptionReleaseLabel(null),
        isNull,
      );
    });
  });

  test(
      'a multi-movie torrent imports every standalone movie with its own '
      'title (BUG-2007)', () async {
    final _PipelineEnvironment environment = await _PipelineEnvironment.create(
      backend: _FakeTorrentBackend(),
    );
    addTearDown(environment.close);
    const String jobId = 'multi-movie-import-job';
    await environment.insertJob(
      jobId: jobId,
      stage: VideoDownloadJobStage.import,
      mediaKind: VideoMetadataMediaKind.movie.name,
    );
    final int now = DateTime.now().millisecondsSinceEpoch;
    // 故意让主片（最大文件）排在最后：主片判据是体积（与组织器抬正片一致），
    // 谁排在 files.first 不作数。
    final List<List<Object>> entries = <List<Object>>[
      <Object>['[A] Suzume [1080p].mkv', 150, 0],
      <Object>['[B] Suzume [720p].mkv', 140, 1],
      <Object>['[C] Aoi Hana [1080p].mkv', 130, 2],
      <Object>['Show (2026)/Show (2026).mkv', 200, 3],
    ];
    for (final List<Object> entry in entries) {
      final String rel = entry[0] as String;
      await environment.database.upsertVideoDownloadJobFile(
        VideoDownloadJobFilesCompanion.insert(
          jobId: jobId,
          backendFileIndex: Value<int?>(entry[2] as int),
          originalRelativePath: rel,
          currentRelativePath: rel,
          finalAbsolutePath: Value<String?>(
            p.joinAll(<String>[environment.root.path, ...rel.split('/')]),
          ),
          kind: const Value<String>('video'),
          sizeBytes: Value<int?>(entry[1] as int),
          status: const Value<String>(VideoDownloadJobFileStatus.organized),
          createdAt: now,
          updatedAt: now,
        ),
      );
    }

    environment.service.wake();
    // 默认身份是 anilist:100（无 MAL/TMDB）→ import 后直接完成（P1 契约）。
    await _waitForJob(
      environment.database,
      jobId,
      (VideoDownloadJobRow row) =>
          row.lifecycle == VideoDownloadJobLifecycle.completed,
    );

    final List<VideoBookRow> books = await environment.database.allVideoBooks();
    expect(books, hasLength(4));
    // 主片（最大文件）沿用 job.title；解析标题唯一的并列正片用解析结果；
    // 前編/後編 式的解析撞名退回整理后文件名——有损解析绝不承担唯一性。
    expect(
      books.map((VideoBookRow book) => book.title).toSet(),
      <String>{
        'Show',
        'Aoi Hana',
        '[A] Suzume [1080p]',
        '[B] Suzume [720p]',
      },
    );
  });

  test(
      'movie subtitle search only targets the main movie; sibling standalone '
      'movies wait for their own identities (BUG-2007)', () async {
    final Uint8List subtitleBytes = Uint8List.fromList(<int>[49, 10, 50, 10]);
    final _FakeSubtitleProvider subtitleProvider = _FakeSubtitleProvider(
      bytes: subtitleBytes,
    );
    final _PipelineEnvironment environment = await _PipelineEnvironment.create(
      backend: _FakeTorrentBackend(),
      subtitleProvider: subtitleProvider,
    );
    addTearDown(environment.close);
    const String jobId = 'multi-movie-subtitle-job';
    await environment.insertJob(
      jobId: jobId,
      stage: VideoDownloadJobStage.subtitle,
      mediaKind: VideoMetadataMediaKind.movie.name,
    );
    final Directory movieDir = Directory(
      p.join(environment.root.path, 'Show (2026)'),
    );
    await movieDir.create(recursive: true);
    final File main = File(p.join(movieDir.path, 'Show (2026).mkv'));
    await main.writeAsBytes(<int>[0, 1, 2, 3], flush: true);
    final File sibling = File(p.join(movieDir.path, 'Zoku Show.mkv'));
    await sibling.writeAsBytes(<int>[0, 1], flush: true);
    final int now = DateTime.now().millisecondsSinceEpoch;
    // 并列正片故意排在前面；主片 = 最大 sizeBytes。
    await environment.database.upsertVideoDownloadJobFile(
      VideoDownloadJobFilesCompanion.insert(
        jobId: jobId,
        backendFileIndex: const Value<int?>(0),
        originalRelativePath: 'Zoku Show.mkv',
        currentRelativePath: 'Zoku Show.mkv',
        finalAbsolutePath: Value<String?>(sibling.path),
        kind: const Value<String>('video'),
        sizeBytes: const Value<int?>(100),
        status: const Value<String>(VideoDownloadJobFileStatus.organized),
        createdAt: now,
        updatedAt: now,
      ),
    );
    await environment.database.upsertVideoDownloadJobFile(
      VideoDownloadJobFilesCompanion.insert(
        jobId: jobId,
        backendFileIndex: const Value<int?>(1),
        originalRelativePath: 'Show (2026).mkv',
        currentRelativePath: 'Show (2026).mkv',
        finalAbsolutePath: Value<String?>(main.path),
        kind: const Value<String>('video'),
        sizeBytes: const Value<int?>(400),
        status: const Value<String>(VideoDownloadJobFileStatus.organized),
        createdAt: now,
        updatedAt: now,
      ),
    );

    environment.service.wake();
    await _waitForJob(
      environment.database,
      jobId,
      (VideoDownloadJobRow row) =>
          row.lifecycle == VideoDownloadJobLifecycle.completed,
    );

    // 只搜了主片一次：并列正片拿 job 身份去搜只会装上主片的字幕，必须留给
    // 刮削后按各自规范身份的补齐链路。
    expect(subtitleProvider.searchCalls, 1);
    final List<VideoDownloadJobFileRow> files =
        await environment.database.getVideoDownloadJobFiles(jobId);
    final int mainFileId = files
        .singleWhere(
          (VideoDownloadJobFileRow row) =>
              row.originalRelativePath == 'Show (2026).mkv',
        )
        .id;
    for (final VideoDownloadJobSubtitleRow row
        in await environment.database.getVideoDownloadJobSubtitles(jobId)) {
      expect(row.jobFileId, mainFileId);
    }
  });

  test(
      'a multi-movie scrape binds the confirmed identity to the main movie '
      'instead of dropping it (BUG-2007)', () async {
    final _PipelineEnvironment environment = await _PipelineEnvironment.create(
      backend: _FakeTorrentBackend(),
    );
    addTearDown(environment.close);
    const String jobId = 'multi-movie-scrape-job';
    await environment.insertJob(
      jobId: jobId,
      stage: VideoDownloadJobStage.scrape,
      mediaKind: VideoMetadataMediaKind.movie.name,
      identityJson: encodeVideoMediaReference(_confirmedReference()),
    );
    final String mainPath = p.join(environment.root.path, 'Show Main.mkv');
    final String siblingPath = p.join(environment.root.path, 'Zoku Show.mkv');
    await environment.database.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value<String>('video/multi-main'),
        title: const Value<String>('Show Main'),
        videoPath: Value<String>(mainPath),
        sourceId: Value<int?>(environment.sourceId),
      ),
    );
    await environment.database.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value<String>('video/multi-sibling'),
        title: const Value<String>('Zoku Show'),
        videoPath: Value<String>(siblingPath),
        sourceId: Value<int?>(environment.sourceId),
      ),
    );
    final int now = DateTime.now().millisecondsSinceEpoch;
    await environment.database.upsertVideoDownloadJobFile(
      VideoDownloadJobFilesCompanion.insert(
        jobId: jobId,
        backendFileIndex: const Value<int?>(0),
        originalRelativePath: 'Zoku Show.mkv',
        currentRelativePath: 'Zoku Show.mkv',
        finalAbsolutePath: Value<String?>(siblingPath),
        kind: const Value<String>('video'),
        sizeBytes: const Value<int?>(100),
        status: const Value<String>(VideoDownloadJobFileStatus.imported),
        createdAt: now,
        updatedAt: now,
      ),
    );
    await environment.database.upsertVideoDownloadJobFile(
      VideoDownloadJobFilesCompanion.insert(
        jobId: jobId,
        backendFileIndex: const Value<int?>(1),
        originalRelativePath: 'Show Main.mkv',
        currentRelativePath: 'Show Main.mkv',
        finalAbsolutePath: Value<String?>(mainPath),
        kind: const Value<String>('video'),
        sizeBytes: const Value<int?>(400),
        status: const Value<String>(VideoDownloadJobFileStatus.imported),
        createdAt: now,
        updatedAt: now,
      ),
    );

    environment.service.wake();
    // 首版实现把多作品批次直接 complete——用户在下载确认时选定的 MAL/TMDB 身份
    // 被静默丢弃。现在必须绑给主片所在作品并真正进入刮削：测试环境没有可用
    // MAL/TMDB provider，coordinator 对已确认身份 fail closed，报「主资料源不可
    // 用」即证明 lookup 进了管线而不是被丢掉。
    final VideoDownloadJobRow job = await _waitForJob(
      environment.database,
      jobId,
      (VideoDownloadJobRow row) =>
          row.lifecycle == VideoDownloadJobLifecycle.needsAttention,
    );
    expect(job.lastError?.toLowerCase(), contains('mal'));
  });

  test(
      'a movie job holding a multi-episode pack is reclassified to tv and '
      'imported as one collection with per-episode titles (BUG-2760)',
      () async {
    // 用户生产库原样：TMDB 电影身份 + 12 集合集包（这里取 3 集足以复现）。
    // 修前：最大一集成「电影正片」，其余进 Extras、不入库。
    final List<TorrentFileEntry> pack = <TorrentFileEntry>[
      for (int episode = 1; episode <= 3; episode++)
        TorrentFileEntry(
          name: '[Karin] Yanisuu - 0$episode '
              '[ABEMA Early Release][WEB-DL 1080p AVC-8bit AAC].mkv',
          size: episode == 2 ? 900 : 700,
          progress: 1,
          index: episode - 1,
        ),
    ];
    final _FakeTorrentBackend backend = _FakeTorrentBackend(files: pack);
    late _PipelineEnvironment environment;
    late Directory downloadDirectory;
    environment = await _PipelineEnvironment.create(
      backend: backend,
      backendResolver: (_) async => VideoDownloadBackendBinding(
        backend: backend,
        identity: _expectedIdentity,
        pathMappings: <VideoDownloadPathMapping>[
          VideoDownloadPathMapping(
            remoteRoot: '/downloads',
            localRoot: downloadDirectory.path,
          ),
          VideoDownloadPathMapping(
            remoteRoot: '/media',
            localRoot: environment.root.path,
          ),
        ],
      ),
    );
    addTearDown(environment.close);
    downloadDirectory = Directory(p.join(environment.root.path, 'incoming'));
    await downloadDirectory.create(recursive: true);
    const String jobId = 'movie-identity-episode-pack-job';
    await environment.insertJob(
      jobId: jobId,
      stage: VideoDownloadJobStage.organize,
      observedSavePath: '/downloads',
      subtitlePolicy: VideoDownloadSubtitlePolicy.none,
      mediaKind: VideoMetadataMediaKind.movie.name,
      identityJson: encodeVideoMediaReference(
        VideoMediaReference(
          providerId: 'tmdb',
          mediaId: '1749852',
          mediaKind: VideoMetadataMediaKind.movie,
          discoveryCategory: VideoDiscoveryCategory.movie,
          title: 'Show',
          year: 2026,
          tmdbId: 1749852,
        ),
      ),
    );
    final int now = DateTime.now().millisecondsSinceEpoch;
    for (final TorrentFileEntry file in pack) {
      await environment.database.upsertVideoDownloadJobFile(
        VideoDownloadJobFilesCompanion.insert(
          jobId: jobId,
          backendFileIndex: Value<int?>(file.index),
          originalRelativePath: file.name,
          currentRelativePath: file.name,
          sizeBytes: Value<int?>(file.size),
          status: const Value<String>(VideoDownloadJobFileStatus.downloaded),
          createdAt: now,
          updatedAt: now,
        ),
      );
    }

    environment.service.wake();
    // 电影命名空间的 TMDB id 不能当剧集身份：改判后丢弃，任务 import 后直接
    // 完成（交给媒体库自动识别），而不是拿 /tv/1749852 去刮一部别的剧。
    final VideoDownloadJobRow completed = await _waitForJob(
      environment.database,
      jobId,
      (VideoDownloadJobRow row) =>
          row.lifecycle == VideoDownloadJobLifecycle.completed,
    );

    expect(completed.mediaKind, VideoMetadataMediaKind.tv.name);
    expect(completed.collectionId, isNotNull);
    final List<VideoDownloadJobFileRow> files =
        await environment.database.getVideoDownloadJobFiles(jobId);
    expect(
      files.map((VideoDownloadJobFileRow row) => row.kind),
      everyElement('video'),
    );
    expect(
      files.map((VideoDownloadJobFileRow row) => row.targetRelativePath),
      everyElement(contains('/Season 01/')),
    );
    final List<VideoBookRow> books = await environment.database.allVideoBooks();
    expect(
      books.map((VideoBookRow book) => book.title).toSet(),
      <String>{'Show - S01E01', 'Show - S01E02', 'Show - S01E03'},
    );
  });

  test('retry resets an actionable job and wakes the persisted stage',
      () async {
    final _FakeTorrentBackend backend = _FakeTorrentBackend(
      snapshots: <TorrentSnapshot>[_downloadingSnapshot(progress: 0.3)],
    );
    final _PipelineEnvironment environment =
        await _PipelineEnvironment.create(backend: backend);
    addTearDown(environment.close);
    const String jobId = 'retry-user-job';
    await environment.insertJob(
      jobId: jobId,
      stage: VideoDownloadJobStage.download,
    );
    await environment.database.updateVideoDownloadJob(
      jobId,
      const VideoDownloadJobsCompanion(
        lifecycle: Value<String>(VideoDownloadJobLifecycle.failed),
        attemptCount: Value<int>(4),
        lastError: Value<String?>('temporary failure'),
        completedAt: Value<int?>(1),
      ),
    );

    await environment.service.retryJob(jobId);
    final VideoDownloadJobRow job = await _waitForJob(
      environment.database,
      jobId,
      (VideoDownloadJobRow row) =>
          row.lifecycle == VideoDownloadJobLifecycle.active &&
          row.claimedBy == null &&
          row.nextAttemptAt != null,
    );
    expect(job.stage, VideoDownloadJobStage.download);
    expect(job.attemptCount, 0);
    expect(job.lastError, isNull);
    expect(job.completedAt, isNull);
  });

  test('retry rewinds a missing embedded torrent and enqueues it again',
      () async {
    final _FakeTorrentBackend backend = _FakeTorrentBackend(pauseAdd: true);
    final _PipelineEnvironment environment =
        await _PipelineEnvironment.create(backend: backend);
    addTearDown(environment.close);
    const String jobId = 'retry-missing-embedded-job';
    await environment.insertJob(
      jobId: jobId,
      stage: VideoDownloadJobStage.download,
    );
    await environment.database.updateVideoDownloadJob(
      jobId,
      const VideoDownloadJobsCompanion(
        lifecycle: Value<String>(VideoDownloadJobLifecycle.failed),
        attemptCount: Value<int>(6),
        lastError: Value<String?>(
          'Bad state: torrent is not visible in the original backend',
        ),
      ),
    );

    await environment.service.retryJob(jobId);
    await backend.addEntered.future.timeout(const Duration(seconds: 2));
    final VideoDownloadJobRow job =
        (await environment.database.getVideoDownloadJob(jobId))!;

    expect(job.stage, VideoDownloadJobStage.enqueue);
    expect(job.backendTaskId, isNull);
    expect(job.torrentHash, _torrentHash);
    expect(backend.addCalls, 1);
  });

  test('missing active embedded torrent is rewound and consumes retry budget',
      () async {
    final _PipelineEnvironment environment = await _PipelineEnvironment.create(
      backend: _FakeTorrentBackend(),
    );
    addTearDown(environment.close);
    const String jobId = 'active-missing-embedded-job';
    await environment.insertJob(
      jobId: jobId,
      stage: VideoDownloadJobStage.download,
    );

    environment.service.wake();
    final VideoDownloadJobRow job = await _waitForJob(
      environment.database,
      jobId,
      (VideoDownloadJobRow row) =>
          row.stage == VideoDownloadJobStage.enqueue && row.claimedBy == null,
    );

    expect(job.lifecycle, VideoDownloadJobLifecycle.active);
    expect(job.backendTaskId, isNull);
    // A rewind is a retry: it spends budget and stays diagnosable, so a task
    // the engine can never hold cannot loop forever while the UI shows an
    // eternally running job.
    expect(job.attemptCount, 1);
    expect(job.lastError, videoDownloadMissingBackendTaskError);
    expect(
        job.nextAttemptAt, greaterThan(DateTime.now().millisecondsSinceEpoch));
  });

  test('an embedded task that never survives a rewind lap ends up failed',
      () async {
    final _PipelineEnvironment environment = await _PipelineEnvironment.create(
      backend: _FakeTorrentBackend(),
      pollInterval: Duration.zero,
    );
    addTearDown(environment.close);
    const String jobId = 'never-holdable-embedded-job';
    await environment.insertJob(
      jobId: jobId,
      stage: VideoDownloadJobStage.download,
    );

    environment.service.wake();
    // Every lap re-adds the torrent successfully and then finds it gone again;
    // re-entering the download stage must not refund the retry budget.
    final VideoDownloadJobRow job = await _waitForJob(
      environment.database,
      jobId,
      (VideoDownloadJobRow row) =>
          row.lifecycle == VideoDownloadJobLifecycle.failed,
    );

    expect(job.attemptCount, greaterThanOrEqualTo(job.maxAttempts));
    expect(job.lastError, videoDownloadMissingBackendTaskError);
    expect(job.nextAttemptAt, isNull);
    expect(job.claimedBy, isNull);
    expect(job.backendTaskId, isNull);
    expect(job.stage, VideoDownloadJobStage.enqueue);
    expect(environment.backend.addCalls, greaterThan(1));
  });

  test('delete never follows a backend path out of the observed save path',
      () async {
    final _PipelineEnvironment environment = await _PipelineEnvironment.create(
      backend: _FakeTorrentBackend(),
    );
    addTearDown(environment.close);
    final Directory savePath =
        Directory(p.join(environment.root.path, 'downloads'));
    await savePath.create(recursive: true);
    final File inside = File(p.join(savePath.path, 'Show S01E01.mkv'));
    await inside.writeAsString('inside');
    final File outside = File(p.join(environment.root.path, 'private.mkv'));
    await outside.writeAsString('outside');

    const String jobId = 'escaping-backend-path-job';
    await environment.insertJob(
      jobId: jobId,
      stage: VideoDownloadJobStage.download,
      observedSavePath: savePath.path,
    );
    // A backend controls these names verbatim. p.join drops its root for an
    // absolute second argument, so an unchecked join would delete both.
    for (final String name in <String>[
      'Show S01E01.mkv',
      '../private.mkv',
      outside.path,
      p.join(environment.root.path, 'private.mkv').replaceAll('/', r'\'),
    ]) {
      await environment.insertBackendFile(jobId: jobId, name: name);
    }

    final VideoDownloadJobRow job =
        (await environment.database.getVideoDownloadJob(jobId))!;
    await deletePersistedVideoDownloadJob(
      database: environment.database,
      job: job,
      deleteFiles: true,
    );

    expect(await outside.exists(), isTrue);
    expect(await inside.exists(), isFalse);
    expect(await environment.database.getVideoDownloadJob(jobId), isNull);
  });

  // BUG-2949：一个任务的多集入库行走一次批量删除，全部消失、库外的行不受牵连。
  test('deleting a multi-episode job removes every imported library row',
      () async {
    final _PipelineEnvironment environment = await _PipelineEnvironment.create(
      backend: _FakeTorrentBackend(),
    );
    addTearDown(environment.close);
    final Directory savePath =
        Directory(p.join(environment.root.path, 'downloads'));
    await savePath.create(recursive: true);

    const String jobId = 'multi-episode-delete-job';
    await environment.insertJob(
      jobId: jobId,
      stage: VideoDownloadJobStage.download,
      observedSavePath: savePath.path,
    );
    final List<String> episodeUids = <String>[];
    for (int episode = 1; episode <= 3; episode++) {
      final String name = 'Show S01E0$episode.mkv';
      final File file = File(p.join(savePath.path, name));
      await file.writeAsString('episode $episode');
      await environment.insertBackendFile(jobId: jobId, name: name);
      final String uid = 'video/show-s01e0$episode';
      episodeUids.add(uid);
      await environment.database.upsertVideoBook(
        VideoBooksCompanion(
          bookUid: Value<String>(uid),
          title: Value<String>('Show S01E0$episode'),
          videoPath: Value<String>(file.path),
        ),
      );
    }
    final File unrelated = File(p.join(environment.root.path, 'Other.mkv'));
    await unrelated.writeAsString('other');
    await environment.database.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value<String>('video/other'),
        title: const Value<String>('Other'),
        videoPath: Value<String>(unrelated.path),
      ),
    );

    final VideoDownloadJobRow job =
        (await environment.database.getVideoDownloadJob(jobId))!;
    await deletePersistedVideoDownloadJob(
      database: environment.database,
      job: job,
      deleteFiles: true,
    );

    for (final String uid in episodeUids) {
      expect(
        await environment.database.getVideoBookByBookUid(uid),
        isNull,
        reason: '$uid must be removed with its downloaded file',
      );
    }
    expect(
      await environment.database.getVideoBookByBookUid('video/other'),
      isNotNull,
    );
    expect(await unrelated.exists(), isTrue);
    expect(await environment.database.getVideoDownloadJob(jobId), isNull);
  });

  test('a locked file leaves the durable job deleted and is reported',
      () async {
    final _PipelineEnvironment environment = await _PipelineEnvironment.create(
      backend: _FakeTorrentBackend(),
    );
    addTearDown(environment.close);
    final Directory savePath =
        Directory(p.join(environment.root.path, 'downloads'));
    await savePath.create(recursive: true);
    final File locked = File(p.join(savePath.path, 'Locked S01E01.mkv'));
    await locked.writeAsString('locked');
    final File free = File(p.join(savePath.path, 'Free S01E02.mkv'));
    await free.writeAsString('free');
    final RandomAccessFile handle = await locked.open(mode: FileMode.write);
    addTearDown(handle.close);

    const String jobId = 'locked-file-job';
    await environment.insertJob(
      jobId: jobId,
      stage: VideoDownloadJobStage.download,
      observedSavePath: savePath.path,
    );
    await environment.insertBackendFile(
      jobId: jobId,
      name: p.basename(locked.path),
    );
    await environment.insertBackendFile(
      jobId: jobId,
      name: p.basename(free.path),
    );

    final VideoDownloadJobRow job =
        (await environment.database.getVideoDownloadJob(jobId))!;
    await expectLater(
      deletePersistedVideoDownloadJob(
        database: environment.database,
        job: job,
        deleteFiles: true,
      ),
      throwsA(isA<VideoDownloadJobFilesNotDeleted>()),
    );

    // The durable row must be gone even so, otherwise every retry repeats the
    // half of the deletion that already succeeded.
    expect(await environment.database.getVideoDownloadJob(jobId), isNull);
    expect(await locked.exists(), isTrue);
    expect(await free.exists(), isFalse);
  },
      skip: !Platform.isWindows
          ? 'holding an open handle only blocks deletion on Windows'
          : null);

  test('cancel pauses the exact backend task and never deletes its files',
      () async {
    final _FakeTorrentBackend backend = _FakeTorrentBackend();
    final _PipelineEnvironment environment =
        await _PipelineEnvironment.create(backend: backend);
    addTearDown(environment.close);
    const String jobId = 'cancel-user-job';
    await environment.insertJob(
      jobId: jobId,
      stage: VideoDownloadJobStage.download,
    );

    await environment.service.cancelJob(jobId);

    final VideoDownloadJobRow job =
        (await environment.database.getVideoDownloadJob(jobId))!;
    expect(job.lifecycle, VideoDownloadJobLifecycle.cancelled);
    expect(job.claimedBy, isNull);
    expect(backend.pauseCalls, 1);
    expect(backend.pausedTorrentIds, <String>[_torrentHash]);
  });

  test('resume restarts the exact paused backend task and durable job',
      () async {
    final _FakeTorrentBackend backend = _FakeTorrentBackend(
      snapshots: <TorrentSnapshot>[_downloadingSnapshot(progress: 0.4)],
    );
    final _PipelineEnvironment environment =
        await _PipelineEnvironment.create(backend: backend);
    addTearDown(environment.close);
    const String jobId = 'resume-user-job';
    await environment.insertJob(
      jobId: jobId,
      stage: VideoDownloadJobStage.download,
    );
    await environment.service.cancelJob(jobId);

    await environment.service.resumeJob(jobId);

    final VideoDownloadJobRow job =
        (await environment.database.getVideoDownloadJob(jobId))!;
    expect(job.lifecycle, VideoDownloadJobLifecycle.active);
    expect(job.stage, VideoDownloadJobStage.download);
    expect(job.completedAt, isNull);
    expect(backend.resumeCalls, 1);
    expect(backend.resumedTorrentIds, <String>[_torrentHash]);
  });

  test('resume rewinds a paused embedded task missing from fast-resume',
      () async {
    final _FakeTorrentBackend backend = _FakeTorrentBackend(pauseAdd: true);
    final _PipelineEnvironment environment =
        await _PipelineEnvironment.create(backend: backend);
    addTearDown(environment.close);
    const String jobId = 'resume-missing-embedded-job';
    await environment.insertJob(
      jobId: jobId,
      stage: VideoDownloadJobStage.download,
    );
    await environment.service.cancelJob(jobId);

    await environment.service.resumeJob(jobId);
    await backend.addEntered.future.timeout(const Duration(seconds: 2));

    final VideoDownloadJobRow job =
        (await environment.database.getVideoDownloadJob(jobId))!;
    expect(job.lifecycle, VideoDownloadJobLifecycle.active);
    expect(job.stage, VideoDownloadJobStage.enqueue);
    expect(job.backendTaskId, isNull);
    expect(job.torrentHash, _torrentHash);
    expect(backend.resumeCalls, 0);
    expect(backend.addCalls, 1);
  });

  test('cancel refuses to touch a task when backend identity changed',
      () async {
    final _FakeTorrentBackend backend = _FakeTorrentBackend();
    final _PipelineEnvironment environment = await _PipelineEnvironment.create(
      backend: backend,
      backendResolver: (_) async => VideoDownloadBackendBinding(
        backend: backend,
        identity: const VideoDownloadBackendIdentity(
          kind: 'embedded',
          profileId: 'embedded',
          fingerprint: 'another-installation',
        ),
      ),
    );
    addTearDown(environment.close);
    const String jobId = 'cancel-mismatched-backend';
    await environment.insertJob(
      jobId: jobId,
      stage: VideoDownloadJobStage.download,
    );

    await expectLater(
      environment.service.cancelJob(jobId),
      throwsA(isA<VideoDownloadPipelineActionRequired>()),
    );

    final VideoDownloadJobRow job =
        (await environment.database.getVideoDownloadJob(jobId))!;
    expect(job.lifecycle, VideoDownloadJobLifecycle.active);
    expect(backend.pauseCalls, 0);
  });

  test('delete removes a stale task even when its backend cannot pause it',
      () async {
    final _FakeTorrentBackend backend = _FakeTorrentBackend(
      pauseResult: false,
    );
    final _PipelineEnvironment environment =
        await _PipelineEnvironment.create(backend: backend);
    addTearDown(environment.close);
    const String jobId = 'delete-stale-backend-job';
    await environment.insertJob(
      jobId: jobId,
      stage: VideoDownloadJobStage.organize,
      lifecycle: VideoDownloadJobLifecycle.needsAttention,
    );

    await environment.service.deleteJob(jobId, deleteFiles: false);

    expect(await environment.database.getVideoDownloadJob(jobId), isNull);
    expect(backend.pauseCalls, 0);
  });

  test('retry rejects a job that is already active', () async {
    final _PipelineEnvironment environment = await _PipelineEnvironment.create(
      backend: _FakeTorrentBackend(),
    );
    addTearDown(environment.close);
    const String jobId = 'retry-active-job';
    await environment.insertJob(
      jobId: jobId,
      stage: VideoDownloadJobStage.download,
    );

    await expectLater(
      environment.service.retryJob(jobId),
      throwsA(isA<VideoDownloadPipelineActionRequired>()),
    );
  });

  // 手动添加任务（2026-08-21 用户点名「用户没办法手动导入任务」）。
  group('enqueueManual', () {
    const String manualMagnet = 'magnet:?xt=urn:btih:$_torrentHash&dn=Manual';

    test('organizationPolicy 与发现域互相换算，未知策略返回 null', () {
      for (final DiscoveryMediaKind kind in DiscoveryMediaKind.values) {
        expect(
          discoveryKindOfOrganizationPolicy(
            manualDiscoveryOrganizationPolicy(kind),
          ),
          kind,
        );
      }
      expect(discoveryKindOfOrganizationPolicy('library'), isNull);
      expect(discoveryKindOfOrganizationPolicy('legacy'), isNull);
      expect(discoveryKindOfOrganizationPolicy('discovery-unknown'), isNull);
    });

    test('磁力视频任务落 manual 行：无发现身份、策略 library', () async {
      final _PipelineEnvironment environment =
          await _PipelineEnvironment.create(backend: _FakeTorrentBackend());
      addTearDown(environment.close);

      final String jobId = await environment.service.enqueueManual(
        VideoDownloadManualEnqueueRequest(
          title: 'Manual Movie',
          backendTarget: _expectedTarget,
          magnetUri: manualMagnet,
          targetSourceId: environment.sourceId,
        ),
      );
      final VideoDownloadJobRow? job =
          await environment.database.getVideoDownloadJob(jobId);
      expect(job, isNotNull);
      expect(job!.resourceProvider, kManualVideoDownloadResourceProvider);
      expect(job.magnetUri, manualMagnet);
      expect(job.torrentHash, _torrentHash);
      expect(job.metadataProvider, isNull,
          reason: '手动任务没有发现身份，import 后必须直接完成而不是进 scrape');
      expect(job.externalId, isNull);
      expect(job.mediaKind, VideoMetadataMediaKind.movie.name);
      expect(job.organizationPolicy, 'library');
      expect(job.subtitlePolicy, VideoDownloadSubtitlePolicy.none.name);
      expect(job.targetSourceId, environment.sourceId);
      expect(job.title, 'Manual Movie');
    });

    test('入参校验：双 payload / 零 payload / 无 hash 磁力 / 视频缺来源', () async {
      final _PipelineEnvironment environment =
          await _PipelineEnvironment.create(backend: _FakeTorrentBackend());
      addTearDown(environment.close);
      final InspectedTorrentMetainfo metainfo =
          inspectTorrentMetainfo(_manualV1Metainfo());

      await expectLater(
        environment.service.enqueueManual(
          VideoDownloadManualEnqueueRequest(
            title: 'x',
            backendTarget: _expectedTarget,
            magnetUri: manualMagnet,
            metainfo: metainfo,
            targetSourceId: environment.sourceId,
          ),
        ),
        throwsArgumentError,
        reason: '磁力与 .torrent 恰好二选一',
      );
      await expectLater(
        environment.service.enqueueManual(
          VideoDownloadManualEnqueueRequest(
            title: 'x',
            backendTarget: _expectedTarget,
            targetSourceId: environment.sourceId,
          ),
        ),
        throwsArgumentError,
      );
      await expectLater(
        environment.service.enqueueManual(
          VideoDownloadManualEnqueueRequest(
            title: 'x',
            backendTarget: _expectedTarget,
            magnetUri: 'magnet:?dn=no-hash',
            targetSourceId: environment.sourceId,
          ),
        ),
        throwsA(isA<VideoDownloadPipelineActionRequired>()),
      );
      await expectLater(
        environment.service.enqueueManual(
          VideoDownloadManualEnqueueRequest(
            title: 'x',
            backendTarget: _expectedTarget,
            magnetUri: manualMagnet,
          ),
        ),
        throwsA(isA<VideoDownloadPipelineActionRequired>()),
        reason: '视频任务必须有受管来源',
      );
    });

    test('.torrent 任务：元数据先落盘（<jobId>.torrent），hash 取自 metainfo', () async {
      final Directory manualDir =
          await Directory.systemTemp.createTemp('fushi-manual-torrents-');
      addTearDown(() async {
        if (await manualDir.exists()) await manualDir.delete(recursive: true);
      });
      final _PipelineEnvironment environment =
          await _PipelineEnvironment.create(backend: _FakeTorrentBackend());
      addTearDown(environment.close);
      final VideoDownloadPipelineService service = VideoDownloadPipelineService(
        database: environment.database,
        resourceRegistry: environment.resourceRegistry,
        backendResolver: (_) async => VideoDownloadBackendBinding(
          backend: environment.backend,
          identity: _expectedIdentity,
        ),
        scrapeCoordinator: environment.scrapeCoordinator,
        manualTorrentDirectory: manualDir,
        workerId: 'manual-metainfo-worker',
        pollInterval: const Duration(hours: 1),
      );
      addTearDown(service.dispose);
      final InspectedTorrentMetainfo metainfo =
          inspectTorrentMetainfo(_manualV1Metainfo());

      final String jobId = await service.enqueueManual(
        VideoDownloadManualEnqueueRequest(
          title: 'Manual Torrent',
          backendTarget: _expectedTarget,
          metainfo: metainfo,
          targetSourceId: environment.sourceId,
        ),
      );

      expect(
        File(p.join(manualDir.path, '$jobId.torrent')).existsSync(),
        isTrue,
        reason: '重启后 payload 从这份落盘元数据重新物化',
      );
      final VideoDownloadJobRow? job =
          await environment.database.getVideoDownloadJob(jobId);
      expect(job!.torrentHash, metainfo.torrentId);
      expect(job.magnetUri, isNull);
    });

    test('.torrent 任务在未配置落盘目录时显式拒绝', () async {
      final _PipelineEnvironment environment =
          await _PipelineEnvironment.create(backend: _FakeTorrentBackend());
      addTearDown(environment.close);
      await expectLater(
        environment.service.enqueueManual(
          VideoDownloadManualEnqueueRequest(
            title: 'x',
            backendTarget: _expectedTarget,
            metainfo: inspectTorrentMetainfo(_manualV1Metainfo()),
            targetSourceId: environment.sourceId,
          ),
        ),
        throwsA(isA<VideoDownloadPipelineActionRequired>()),
      );
    });

    test('发现域任务：策略 discovery-<kind>、无字幕、无目标来源；无 importer 拒绝', () async {
      final _PipelineEnvironment environment =
          await _PipelineEnvironment.create(backend: _FakeTorrentBackend());
      addTearDown(environment.close);

      await expectLater(
        environment.service.enqueueManual(
          VideoDownloadManualEnqueueRequest(
            title: 'A Novel',
            backendTarget: _expectedTarget,
            magnetUri: manualMagnet,
            discoveryKind: DiscoveryMediaKind.novel,
          ),
        ),
        throwsA(isA<VideoDownloadPipelineActionRequired>()),
        reason: '本设备没接发现导入执行器时不能默默收下书任务',
      );

      final VideoDownloadPipelineService service = VideoDownloadPipelineService(
        database: environment.database,
        resourceRegistry: environment.resourceRegistry,
        backendResolver: (_) async => VideoDownloadBackendBinding(
          backend: environment.backend,
          identity: _expectedIdentity,
        ),
        scrapeCoordinator: environment.scrapeCoordinator,
        discoveryImporter:
            (DiscoveryMediaKind kind, List<String> paths) async =>
                const DiscoveryImportOutcome(importedCount: 1),
        workerId: 'manual-discovery-worker',
        pollInterval: const Duration(hours: 1),
      );
      addTearDown(service.dispose);

      final String jobId = await service.enqueueManual(
        VideoDownloadManualEnqueueRequest(
          title: 'A Novel',
          backendTarget: _expectedTarget,
          magnetUri: manualMagnet,
          discoveryKind: DiscoveryMediaKind.novel,
          // 故意同时给字幕策略与来源：发现域任务必须把它们归零。
          subtitlePolicy: VideoDownloadSubtitlePolicy.bestEffort,
          targetSourceId: environment.sourceId,
        ),
      );
      final VideoDownloadJobRow? job =
          await environment.database.getVideoDownloadJob(jobId);
      expect(job!.organizationPolicy, 'discovery-novel');
      expect(job.subtitlePolicy, VideoDownloadSubtitlePolicy.none.name,
          reason: '非视频内容没有字幕概念');
      expect(job.targetSourceId, isNull, reason: '发现域任务不进受管视频来源');
      expect(job.mediaKind, DiscoveryMediaKind.novel.name);
    });
  });

  group('同包多卷选择（CoreAudio/TMW，BUG-2764）', () {
    test('后一卷排队等上一卷让出 torrent，而不是创建失败；同一卷再点被识别为已在队列',
        () async {
      final Directory manualDir =
          await Directory.systemTemp.createTemp('fushi-pack-torrents-');
      addTearDown(() async {
        if (await manualDir.exists()) await manualDir.delete(recursive: true);
      });
      final _FakePausedMetainfoBackend backend =
          _FakePausedMetainfoBackend(fileCount: 3);
      final _PipelineEnvironment environment =
          await _PipelineEnvironment.create(backend: backend);
      addTearDown(environment.close);
      final FushiDatabase database = environment.database;
      final VideoDownloadPipelineService service = VideoDownloadPipelineService(
        database: database,
        resourceRegistry: environment.resourceRegistry,
        backendResolver: (_) async => VideoDownloadBackendBinding(
          backend: backend,
          identity: _expectedIdentity,
        ),
        scrapeCoordinator: environment.scrapeCoordinator,
        manualTorrentDirectory: manualDir,
        workerId: 'pack-selection-worker',
        pollInterval: const Duration(hours: 1),
      );
      addTearDown(service.dispose);
      final InspectedTorrentMetainfo metainfo =
          inspectTorrentMetainfo(_manualPackMetainfo());
      final String hash = metainfo.torrentId.toLowerCase();
      Future<String> enqueueVolume(int index) => service.enqueueManual(
            VideoDownloadManualEnqueueRequest(
              title: 'Volume $index',
              backendTarget: _expectedTarget,
              metainfo: metainfo,
              selectedFileIndexes: <int>{index},
              discoveryKind: DiscoveryMediaKind.audiobook,
              importAfterDownload: false,
            ),
          );

      final String first = await enqueueVolume(0);
      // 用户原始失败：同包第二卷在这里抛「already managed」→「无法创建下载」。
      final String second = await enqueueVolume(1);
      await expectLater(
        enqueueVolume(1),
        throwsA(isA<VideoDownloadAlreadyQueued>()),
        reason: '同一卷点两次不能排出两个下载同一文件的任务',
      );
      expect((await database.getVideoDownloadJob(first))!.torrentHash, hash);
      final VideoDownloadJobRow queued =
          (await database.getVideoDownloadJob(second))!;
      expect(queued.torrentHash, isNull,
          reason: '排队的任务不占 (fingerprint, torrent_hash) 唯一槽位');
      expect(queued.selectedResourceId.toLowerCase(), hash);

      service.wake();
      await _waitForJob(
        database,
        first,
        (VideoDownloadJobRow row) =>
            row.stage == VideoDownloadJobStage.download &&
            row.claimedBy == null,
      );
      final VideoDownloadJobRow waiting = await _waitForJob(
        database,
        second,
        (VideoDownloadJobRow row) =>
            row.claimedBy == null && row.nextAttemptAt != null,
      );
      expect(waiting.stage, VideoDownloadJobStage.enqueue);
      expect(waiting.lifecycle, VideoDownloadJobLifecycle.active,
          reason: '等同包持有者不是故障，不能进「需要处理」');
      expect(waiting.lastError, isNull);
      expect(waiting.attemptCount, 0, reason: '排队等待不耗重试预算');
      expect(waiting.torrentHash, isNull);
      expect(backend.pausedAdds, <String>[hash],
          reason: '后端里同一颗 torrent 同时只归一个任务');
      expect(backend.priorities, <int, TorrentFilePriority>{
        0: TorrentFilePriority.normal,
        1: TorrentFilePriority.skip,
        2: TorrentFilePriority.skip,
      });

      // 上一卷完成：只下载型任务把 torrent 从后端摘掉并让出槽位（与
      // _resolveDiscoveryDownloadPaths 收尾同形）。
      await backend.removeTorrent(hash);
      await database.updateVideoDownloadJob(
        first,
        const VideoDownloadJobsCompanion(
          lifecycle: Value<String>(VideoDownloadJobLifecycle.completed),
          backendTaskId: Value<String?>(null),
          torrentHash: Value<String?>(null),
        ),
      );
      await database.updateVideoDownloadJob(
        second,
        const VideoDownloadJobsCompanion(nextAttemptAt: Value<int?>(null)),
      );
      service.wake();
      final VideoDownloadJobRow tookOver = await _waitForJob(
        database,
        second,
        (VideoDownloadJobRow row) =>
            row.stage == VideoDownloadJobStage.download &&
            row.claimedBy == null,
      );
      expect(tookOver.torrentHash, hash);
      expect(tookOver.lastError, isNull);
      expect(backend.pausedAdds, <String>[hash, hash]);
      expect(backend.priorities, <int, TorrentFilePriority>{
        0: TorrentFilePriority.skip,
        1: TorrentFilePriority.normal,
        2: TorrentFilePriority.skip,
      });
    });
  });

  group('skipDownloadExtras', () {
    List<TorrentFileEntry> mixedFiles() => <TorrentFileEntry>[
          const TorrentFileEntry(
              name: 'Show/EP01.mkv', size: 4, progress: 0.5, index: 0),
          const TorrentFileEntry(
              name: 'Show/EP02.mkv', size: 4, progress: 0.5, index: 1),
          const TorrentFileEntry(
              name: 'Show/SPs/NCOP.mkv', size: 4, progress: 0, index: 2),
          const TorrentFileEntry(
              name: 'Show/PV/PV1.mp4', size: 4, progress: 0, index: 3),
        ];

    Future<_PipelineEnvironment> createEnvironment(
      _FakeDetailTorrentBackend backend, {
      bool Function()? skipDownloadExtras,
    }) async {
      late _PipelineEnvironment environment;
      late Directory downloadDirectory;
      environment = await _PipelineEnvironment.create(
        backend: backend,
        skipDownloadExtras: skipDownloadExtras,
        backendResolver: (_) async => VideoDownloadBackendBinding(
          backend: backend,
          identity: _expectedIdentity,
          pathMappings: <VideoDownloadPathMapping>[
            VideoDownloadPathMapping(
              remoteRoot: '/downloads',
              localRoot: downloadDirectory.path,
            ),
            VideoDownloadPathMapping(
              remoteRoot: '/media',
              localRoot: environment.root.path,
            ),
          ],
        ),
      );
      downloadDirectory = Directory(p.join(environment.root.path, 'incoming'));
      await downloadDirectory.create(recursive: true);
      return environment;
    }

    /// 跑一轮下载观察：唤醒后等到本轮释放 claim。
    Future<void> observeOnce(
      _PipelineEnvironment environment,
      String jobId,
    ) async {
      await environment.database.updateVideoDownloadJob(
        jobId,
        const VideoDownloadJobsCompanion(nextAttemptAt: Value<int?>(null)),
      );
      environment.service.wake();
      await _waitForJob(
        environment.database,
        jobId,
        (VideoDownloadJobRow row) =>
            row.claimedBy == null && row.nextAttemptAt != null,
      );
    }

    test('下载途中跳过特典文件，完成后只整理正片', () async {
      final _FakeDetailTorrentBackend backend = _FakeDetailTorrentBackend(
        snapshots: <TorrentSnapshot>[_downloadingSnapshot(progress: 0.4)],
        files: mixedFiles(),
      );
      final _PipelineEnvironment environment = await createEnvironment(
        backend,
        skipDownloadExtras: () => true,
      );
      addTearDown(environment.close);
      const String jobId = 'skip-extras-job';
      await environment.insertJob(
        jobId: jobId,
        stage: VideoDownloadJobStage.download,
        subtitlePolicy: VideoDownloadSubtitlePolicy.none,
      );

      await observeOnce(environment, jobId);

      expect(backend.priorities, <int, TorrentFilePriority>{
        2: TorrentFilePriority.skip,
        3: TorrentFilePriority.skip,
      });
      final List<VideoDownloadJobFileRow> rows =
          await environment.database.getVideoDownloadJobFiles(jobId);
      final Map<int, VideoDownloadJobFileRow> byIndex =
          <int, VideoDownloadJobFileRow>{
        for (final VideoDownloadJobFileRow row in rows)
          row.backendFileIndex!: row,
      };
      expect(byIndex.keys.toSet(), <int>{0, 1, 2, 3});
      expect(byIndex[0]!.selected, isTrue);
      expect(byIndex[1]!.selected, isTrue);
      expect(byIndex[2]!.selected, isFalse);
      expect(byIndex[3]!.selected, isFalse);
      expect(byIndex[2]!.status, VideoDownloadJobFileStatus.skipped);
      expect(byIndex[0]!.status, VideoDownloadJobFileStatus.downloading);

      // 第二轮仍未完成：已决定过，不再重复写优先级。
      backend.priorities.clear();
      await observeOnce(environment, jobId);
      expect(backend.priorities, isEmpty);

      backend.snapshots[0] = _completeSnapshot();
      await environment.database.updateVideoDownloadJob(
        jobId,
        const VideoDownloadJobsCompanion(nextAttemptAt: Value<int?>(null)),
      );
      environment.service.wake();
      final VideoDownloadJobRow done = await _waitForJob(
        environment.database,
        jobId,
        (VideoDownloadJobRow row) =>
            row.lifecycle != VideoDownloadJobLifecycle.active,
      );
      expect(done.lifecycle, VideoDownloadJobLifecycle.completed,
          reason: '${done.lastError}');
      expect(backend.renamedIndexes..sort(), <int>[0, 1],
          reason: '被跳过的特典不改名、不落位');
      final List<VideoDownloadJobFileRow> finalRows =
          await environment.database.getVideoDownloadJobFiles(jobId);
      for (final VideoDownloadJobFileRow row in finalRows) {
        if (row.backendFileIndex! >= 2) {
          expect(row.selected, isFalse);
          expect(row.status, VideoDownloadJobFileStatus.skipped);
          expect(row.finalAbsolutePath, isNull);
          expect(row.targetRelativePath, isNull);
        } else {
          expect(row.kind, 'video');
          expect(row.finalAbsolutePath, isNotNull);
        }
      }
      expect((await environment.database.allVideoBooks()).length, 2,
          reason: '只有两集正片入库');
    });

    test('整个种子都是特典时一个也不跳', () async {
      final _FakeDetailTorrentBackend backend = _FakeDetailTorrentBackend(
        snapshots: <TorrentSnapshot>[_downloadingSnapshot(progress: 0.4)],
        files: <TorrentFileEntry>[
          const TorrentFileEntry(
              name: 'Show/SPs/NCOP.mkv', size: 4, progress: 0, index: 0),
          const TorrentFileEntry(
              name: 'Show/PV/PV1.mp4', size: 4, progress: 0, index: 1),
        ],
      );
      final _PipelineEnvironment environment = await createEnvironment(
        backend,
        skipDownloadExtras: () => true,
      );
      addTearDown(environment.close);
      const String jobId = 'all-extras-job';
      await environment.insertJob(
        jobId: jobId,
        stage: VideoDownloadJobStage.download,
      );

      await observeOnce(environment, jobId);

      expect(backend.priorities, isEmpty);
      expect(
          await environment.database.getVideoDownloadJobFiles(jobId), isEmpty);
    });

    test('没有特典的种子只判一次，之后的轮询不再列文件', () async {
      final _FakeDetailTorrentBackend backend = _FakeDetailTorrentBackend(
        snapshots: <TorrentSnapshot>[_downloadingSnapshot(progress: 0.4)],
        files: <TorrentFileEntry>[
          const TorrentFileEntry(
              name: 'Show/EP01.mkv', size: 4, progress: 0.5, index: 0),
          const TorrentFileEntry(
              name: 'Show/EP02.mkv', size: 4, progress: 0.5, index: 1),
        ],
      );
      final _PipelineEnvironment environment = await createEnvironment(
        backend,
        skipDownloadExtras: () => true,
      );
      addTearDown(environment.close);
      const String jobId = 'no-extras-job';
      await environment.insertJob(
        jobId: jobId,
        stage: VideoDownloadJobStage.download,
      );

      for (int round = 0; round < 3; round++) {
        await observeOnce(environment, jobId);
      }

      expect(backend.listFilesCalls, 1);
      expect(backend.priorities, isEmpty);
      expect(
          await environment.database.getVideoDownloadJobFiles(jobId), isEmpty,
          reason: '不落全选文件行，保持既有非选择性路径');
    });

    test('自动跳过特典的任务丢了后端任务：磁力整颗重加，下一轮补写 skip 优先级', () async {
      final _FakeDetailTorrentBackend backend = _FakeDetailTorrentBackend(
        snapshots: <TorrentSnapshot>[_downloadingSnapshot(progress: 0.4)],
        files: mixedFiles(),
      );
      final _PipelineEnvironment environment = await createEnvironment(
        backend,
        skipDownloadExtras: () => true,
      );
      addTearDown(environment.close);
      const String jobId = 'extras-rewind-job';
      await environment.insertJob(
        jobId: jobId,
        stage: VideoDownloadJobStage.download,
      );
      await observeOnce(environment, jobId);
      expect(backend.priorities.keys.toSet(), <int>{2, 3});

      // 内置引擎快速恢复丢失：后端里没有这颗 torrent 了。
      backend.snapshots.clear();
      backend.priorities.clear();
      backend.beforeAdd = () async {
        backend.snapshots.add(_downloadingSnapshot(progress: 0.1));
      };
      await environment.database.updateVideoDownloadJob(
        jobId,
        const VideoDownloadJobsCompanion(nextAttemptAt: Value<int?>(null)),
      );
      environment.service.wake();
      await _waitForJob(
        environment.database,
        jobId,
        (VideoDownloadJobRow row) =>
            row.stage == VideoDownloadJobStage.enqueue && row.claimedBy == null,
      );

      await environment.database.updateVideoDownloadJob(
        jobId,
        const VideoDownloadJobsCompanion(nextAttemptAt: Value<int?>(null)),
      );
      environment.service.wake();
      final VideoDownloadJobRow readded = await _waitForJob(
        environment.database,
        jobId,
        (VideoDownloadJobRow row) =>
            row.stage == VideoDownloadJobStage.download &&
            row.claimedBy == null,
      );
      expect(readded.lifecycle, VideoDownloadJobLifecycle.active,
          reason: '${readded.lastError}');
      expect(backend.addCalls, 1, reason: '磁力走普通整颗添加，不要求 .torrent 元数据');

      await observeOnce(environment, jobId);
      expect(backend.priorities, <int, TorrentFilePriority>{
        2: TorrentFilePriority.skip,
        3: TorrentFilePriority.skip,
      });
      final List<VideoDownloadJobFileRow> rows =
          await environment.database.getVideoDownloadJobFiles(jobId);
      expect(rows.length, 4, reason: '不重复写行');

      // 本进程已补写过：后续轮询不再重复写。
      backend.priorities.clear();
      await observeOnce(environment, jobId);
      expect(backend.priorities, isEmpty);
    });

    test('自动跳过特典的任务删除时整颗连文件删', () async {
      final _FakeDetailTorrentBackend backend = _FakeDetailTorrentBackend(
        snapshots: <TorrentSnapshot>[_downloadingSnapshot(progress: 0.4)],
        files: mixedFiles(),
      );
      final _PipelineEnvironment environment = await createEnvironment(
        backend,
        skipDownloadExtras: () => true,
      );
      addTearDown(environment.close);
      const String jobId = 'extras-delete-job';
      await environment.insertJob(
        jobId: jobId,
        stage: VideoDownloadJobStage.download,
      );
      await observeOnce(environment, jobId);
      expect(
        (await environment.database.getVideoDownloadJobFiles(jobId))
            .where((VideoDownloadJobFileRow row) => !row.selected)
            .map((VideoDownloadJobFileRow row) => row.kind)
            .toSet(),
        <String>{'extra'},
      );

      await environment.service.deleteJob(jobId, deleteFiles: true);

      expect(backend.removeDeleteFiles, <bool>[true]);
      expect(await environment.database.getVideoDownloadJob(jobId), isNull);
    });

    test('用户亲手选文件的任务仍走选择性路径（重投要元数据、删除不连合集）', () async {
      final _FakeDetailTorrentBackend backend = _FakeDetailTorrentBackend(
        snapshots: <TorrentSnapshot>[],
        files: mixedFiles(),
      );
      final _PipelineEnvironment environment = await createEnvironment(
        backend,
        skipDownloadExtras: () => true,
      );
      addTearDown(environment.close);
      const String jobId = 'user-selection-job';
      await environment.insertJob(
        jobId: jobId,
        stage: VideoDownloadJobStage.enqueue,
      );
      final int now = DateTime.now().millisecondsSinceEpoch;
      for (final TorrentFileEntry file in mixedFiles()) {
        await environment.database.upsertVideoDownloadJobFile(
          VideoDownloadJobFilesCompanion.insert(
            jobId: jobId,
            backendFileIndex: Value<int?>(file.index),
            originalRelativePath: file.name,
            currentRelativePath: file.name,
            kind: const Value<String>('other'),
            selected: Value<bool>(file.index == 0),
            createdAt: now,
            updatedAt: now,
          ),
        );
      }

      environment.service.wake();
      final VideoDownloadJobRow job = await _waitForJob(
        environment.database,
        jobId,
        (VideoDownloadJobRow row) =>
            row.lifecycle == VideoDownloadJobLifecycle.needsAttention,
      );
      expect(job.lastError, contains('single-file selection'));
      expect(backend.addCalls, 0);

      await environment.service.deleteJob(jobId, deleteFiles: true);
      expect(backend.removeDeleteFiles, <bool>[false]);
    });

    test('开关未装配或关闭时行为不变', () async {
      for (final bool Function()? toggle in <bool Function()?>[
        null,
        () => false,
      ]) {
        final _FakeDetailTorrentBackend backend = _FakeDetailTorrentBackend(
          snapshots: <TorrentSnapshot>[_downloadingSnapshot(progress: 0.4)],
          files: mixedFiles(),
        );
        final _PipelineEnvironment environment = await createEnvironment(
          backend,
          skipDownloadExtras: toggle,
        );
        const String jobId = 'no-skip-job';
        await environment.insertJob(
          jobId: jobId,
          stage: VideoDownloadJobStage.download,
        );

        await observeOnce(environment, jobId);

        expect(backend.priorities, isEmpty);
        expect(backend.listFilesCalls, 0, reason: '未完成时不该去列文件');
        expect(await environment.database.getVideoDownloadJobFiles(jobId),
            isEmpty);
        await environment.close();
      }
    });

    test('磁力元数据未到（文件列表为空）时本轮不动，下一轮再判', () async {
      final List<TorrentFileEntry> files = <TorrentFileEntry>[];
      final _FakeDetailTorrentBackend backend = _FakeDetailTorrentBackend(
        snapshots: <TorrentSnapshot>[_downloadingSnapshot(progress: 0)],
        files: files,
      );
      final _PipelineEnvironment environment = await createEnvironment(
        backend,
        skipDownloadExtras: () => true,
      );
      addTearDown(environment.close);
      const String jobId = 'metadata-pending-job';
      await environment.insertJob(
        jobId: jobId,
        stage: VideoDownloadJobStage.download,
      );

      await observeOnce(environment, jobId);
      expect(backend.priorities, isEmpty);
      expect(
          await environment.database.getVideoDownloadJobFiles(jobId), isEmpty);

      files.addAll(mixedFiles());
      await observeOnce(environment, jobId);
      expect(backend.priorities.keys.toSet(), <int>{2, 3});
      expect(
        (await environment.database.getVideoDownloadJobFiles(jobId)).length,
        4,
      );
    });

    test('后端拒绝写优先级时不落文件行，下一轮重试', () async {
      final _FakeDetailTorrentBackend backend = _FakeDetailTorrentBackend(
        snapshots: <TorrentSnapshot>[_downloadingSnapshot(progress: 0.4)],
        files: mixedFiles(),
      )..priorityResult = false;
      final _PipelineEnvironment environment = await createEnvironment(
        backend,
        skipDownloadExtras: () => true,
      );
      addTearDown(environment.close);
      const String jobId = 'priority-rejected-job';
      await environment.insertJob(
        jobId: jobId,
        stage: VideoDownloadJobStage.download,
      );

      await observeOnce(environment, jobId);
      expect(
          await environment.database.getVideoDownloadJobFiles(jobId), isEmpty);
      final VideoDownloadJobRow? job =
          await environment.database.getVideoDownloadJob(jobId);
      expect(job!.lifecycle, VideoDownloadJobLifecycle.active);
      expect(job.attemptCount, 0);

      backend.priorityResult = true;
      await observeOnce(environment, jobId);
      expect(
        (await environment.database.getVideoDownloadJobFiles(jobId)).length,
        4,
      );
    });
  });

  group('BUG-2755 download save path follows the target source', () {
    String incomingOf(String root) =>
        p.normalize(p.absolute(p.join(root, '.fushi-incoming', 'fushi-video')));

    Future<void> failJob(
      _PipelineEnvironment environment,
      String jobId, {
      String lifecycle = VideoDownloadJobLifecycle.needsAttention,
      int? targetSourceId,
      bool clearTarget = false,
    }) =>
        environment.database.updateVideoDownloadJob(
          jobId,
          VideoDownloadJobsCompanion(
            lifecycle: Value<String>(lifecycle),
            lastError: const Value<String?>(
              'The managed video source no longer exists',
            ),
            targetSourceId: clearTarget
                ? const Value<int?>(null)
                : targetSourceId == null
                    ? const Value<int?>.absent()
                    : Value<int?>(targetSourceId),
          ),
        );

    Future<int> insertSource(
      _PipelineEnvironment environment,
      String name, {
      bool create = true,
    }) async {
      final Directory directory =
          Directory(p.join(environment.root.path, name));
      if (create) await directory.create(recursive: true);
      return environment.database.insertMediaSource(
        MediaSourcesCompanion.insert(
          label: name,
          mediaKind: 'video',
          rootPath: directory.path,
          createdAt: 2,
        ),
      );
    }

    Future<void> insertSubscription(
      _PipelineEnvironment environment, {
      required int targetSourceId,
      required String jobId,
    }) async {
      await environment.database.upsertVideoDownloadSubscription(
        VideoDownloadSubscriptionsCompanion.insert(
          subscriptionId: 'sub-2755',
          resourceProvider: 'nyaa:test-instance',
          mediaKind: 'tv',
          title: 'Show',
          searchQuery: 'Show',
          backendKind: 'embedded',
          fingerprint: _expectedIdentity.fingerprint,
          targetSourceId: Value<int?>(targetSourceId),
          createdAt: 1,
          updatedAt: 1,
        ),
      );
      await environment.database.upsertVideoDownloadSubscriptionItem(
        VideoDownloadSubscriptionItemsCompanion.insert(
          subscriptionId: 'sub-2755',
          logicalItemKey: 's1e1',
          resourceProvider: 'nyaa:test-instance',
          selectedResourceId: 'release-1',
          title: 'Show - 01',
          jobId: Value<String?>(jobId),
          discoveredAt: 1,
          updatedAt: 1,
        ),
      );
    }

    test('managed enqueue downloads straight into the source staging dir',
        () async {
      final _FakeTorrentBackend backend = _FakeTorrentBackend(pauseAdd: true);
      final _PipelineEnvironment environment =
          await _PipelineEnvironment.create(backend: backend);
      addTearDown(environment.close);

      await environment.service.enqueue(environment.enqueueRequest());
      await backend.addEntered.future.timeout(const Duration(seconds: 2));

      expect(
          backend.addSavePaths, <String?>[incomingOf(environment.root.path)]);
    });

    test('a job without a usable source falls back to the global download root',
        () async {
      final _FakeTorrentBackend backend = _FakeTorrentBackend(pauseAdd: true);
      final _PipelineEnvironment environment =
          await _PipelineEnvironment.create(backend: backend);
      addTearDown(environment.close);
      final int missingSource =
          await insertSource(environment, 'gone', create: false);
      await environment.insertJob(
        jobId: 'missing-source-job',
        stage: VideoDownloadJobStage.enqueue,
      );
      await environment.database.updateVideoDownloadJob(
        'missing-source-job',
        VideoDownloadJobsCompanion(
          targetSourceId: Value<int?>(missingSource),
        ),
      );

      environment.service.wake();
      await backend.addEntered.future.timeout(const Duration(seconds: 2));

      expect(backend.addSavePaths, <String?>[null]);
    });

    test('remote backends receive the path-mapped staging dir', () async {
      final _FakeTorrentBackend backend = _FakeTorrentBackend(pauseAdd: true);
      late _PipelineEnvironment environment;
      environment = await _PipelineEnvironment.create(
        backend: backend,
        backendResolver: (_) async => VideoDownloadBackendBinding(
          backend: backend,
          identity: _expectedIdentity,
          pathMappings: <VideoDownloadPathMapping>[
            VideoDownloadPathMapping(
              remoteRoot: '/media',
              localRoot: environment.root.path,
            ),
          ],
        ),
      );
      addTearDown(environment.close);

      await environment.service.enqueue(environment.enqueueRequest());
      await backend.addEntered.future.timeout(const Duration(seconds: 2));

      expect(
        backend.addSavePaths,
        <String?>['/media/.fushi-incoming/fushi-video'],
      );
    });

    test('a source outside every mapping falls back instead of guessing',
        () async {
      final _FakeTorrentBackend backend = _FakeTorrentBackend(pauseAdd: true);
      final Directory elsewhere =
          await Directory.systemTemp.createTemp('fushi-pipeline-unmapped-');
      addTearDown(() => elsewhere.delete(recursive: true));
      final _PipelineEnvironment environment =
          await _PipelineEnvironment.create(
        backend: backend,
        backendResolver: (_) async => VideoDownloadBackendBinding(
          backend: backend,
          identity: _expectedIdentity,
          pathMappings: <VideoDownloadPathMapping>[
            VideoDownloadPathMapping(
              remoteRoot: '/downloads',
              localRoot: elsewhere.path,
            ),
          ],
        ),
      );
      addTearDown(environment.close);

      await environment.service.enqueue(environment.enqueueRequest());
      await backend.addEntered.future.timeout(const Duration(seconds: 2));

      expect(backend.addSavePaths, <String?>[null]);
    });

    test('retry rebinds an orphaned job to its subscription source', () async {
      final _FakeTorrentBackend backend = _FakeTorrentBackend(
        snapshots: <TorrentSnapshot>[_downloadingSnapshot(progress: 0.3)],
      );
      late _PipelineEnvironment environment;
      environment = await _PipelineEnvironment.create(
        backend: backend,
        defaultTargetSourceId: () async => environment.sourceId,
      );
      addTearDown(environment.close);
      final int subscriptionSource = await insertSource(environment, 'series');
      const String jobId = 'orphaned-subscription-job';
      await environment.insertJob(
        jobId: jobId,
        stage: VideoDownloadJobStage.download,
      );
      await failJob(environment, jobId, clearTarget: true);
      await insertSubscription(
        environment,
        targetSourceId: subscriptionSource,
        jobId: jobId,
      );

      await environment.service.retryJob(jobId);

      final VideoDownloadJobRow job =
          (await environment.database.getVideoDownloadJob(jobId))!;
      expect(job.targetSourceId, subscriptionSource);
      expect(job.lifecycle, isNot(VideoDownloadJobLifecycle.needsAttention));
    });

    test('retry falls back to the default source without a subscription',
        () async {
      final _FakeTorrentBackend backend = _FakeTorrentBackend(
        snapshots: <TorrentSnapshot>[_downloadingSnapshot(progress: 0.3)],
      );
      late _PipelineEnvironment environment;
      environment = await _PipelineEnvironment.create(
        backend: backend,
        defaultTargetSourceId: () async => environment.sourceId,
      );
      addTearDown(environment.close);
      const String jobId = 'orphaned-manual-job';
      await environment.insertJob(
        jobId: jobId,
        stage: VideoDownloadJobStage.organize,
        withoutTargetSource: true,
      );
      await failJob(environment, jobId);

      await environment.service.retryJob(jobId);

      final VideoDownloadJobRow job =
          (await environment.database.getVideoDownloadJob(jobId))!;
      expect(job.targetSourceId, environment.sourceId);
    });

    test('retry leaves a job whose source is still usable untouched', () async {
      final _FakeTorrentBackend backend = _FakeTorrentBackend(
        snapshots: <TorrentSnapshot>[_downloadingSnapshot(progress: 0.3)],
      );
      late _PipelineEnvironment environment;
      late int other;
      environment = await _PipelineEnvironment.create(
        backend: backend,
        defaultTargetSourceId: () async => other,
      );
      addTearDown(environment.close);
      other = await insertSource(environment, 'other');
      const String jobId = 'healthy-source-job';
      await environment.insertJob(
        jobId: jobId,
        stage: VideoDownloadJobStage.download,
      );
      await failJob(environment, jobId);

      await environment.service.retryJob(jobId);

      final VideoDownloadJobRow job =
          (await environment.database.getVideoDownloadJob(jobId))!;
      expect(job.targetSourceId, environment.sourceId);
    });

    test('re-enqueueing a torrent revives the orphaned job into the new source',
        () async {
      final _FakeTorrentBackend backend = _FakeTorrentBackend(
        snapshots: <TorrentSnapshot>[_downloadingSnapshot(progress: 0.3)],
      );
      final _PipelineEnvironment environment =
          await _PipelineEnvironment.create(backend: backend);
      addTearDown(environment.close);
      const String oldJobId = 'orphaned-same-hash-job';
      await environment.insertJob(
        jobId: oldJobId,
        stage: VideoDownloadJobStage.download,
      );
      await failJob(environment, oldJobId, clearTarget: true);

      final String jobId =
          await environment.service.enqueue(environment.enqueueRequest());

      expect(jobId, oldJobId);
      final VideoDownloadJobRow job =
          (await environment.database.getVideoDownloadJob(jobId))!;
      expect(job.targetSourceId, environment.sourceId);
      expect(job.lifecycle, isNot(VideoDownloadJobLifecycle.needsAttention));
      expect(await environment.database.getVideoDownloadJobs(), hasLength(1));
    });

    test('a same-hash job whose source still exists keeps blocking', () async {
      final _FakeTorrentBackend backend = _FakeTorrentBackend();
      final _PipelineEnvironment environment =
          await _PipelineEnvironment.create(backend: backend);
      addTearDown(environment.close);
      const String oldJobId = 'healthy-same-hash-job';
      await environment.insertJob(
        jobId: oldJobId,
        stage: VideoDownloadJobStage.download,
      );
      await failJob(environment, oldJobId);

      await expectLater(
        environment.service.enqueue(environment.enqueueRequest()),
        throwsA(anything),
      );
      final VideoDownloadJobRow job =
          (await environment.database.getVideoDownloadJob(oldJobId))!;
      expect(job.lifecycle, VideoDownloadJobLifecycle.needsAttention);
    });

    test('a hash learned at enqueue time takes over an orphaned duplicate',
        () async {
      final _FakeTorrentBackend backend = _FakeTorrentBackend(pauseAdd: true);
      final _PipelineEnvironment environment =
          await _PipelineEnvironment.create(backend: backend);
      addTearDown(environment.close);
      // 新任务的 hash 入队时还不知道（行上没有 torrent_hash），直到物化 payload
      // 才对上旧任务——这正是旧任务把它拦成「already managed」的那条路。先插它
      // 再清 hash，否则与旧任务撞 (fingerprint, torrent_hash) 唯一索引。
      const String newJobId = 'new-owner-job';
      await environment.insertJob(
        jobId: newJobId,
        stage: VideoDownloadJobStage.enqueue,
      );
      await environment.database.updateVideoDownloadJob(
        newJobId,
        const VideoDownloadJobsCompanion(
          torrentHash: Value<String?>(null),
          backendTaskId: Value<String?>(null),
          lifecycle: Value<String>(VideoDownloadJobLifecycle.cancelled),
        ),
      );
      const String oldJobId = 'orphaned-duplicate-job';
      await environment.insertJob(
        jobId: oldJobId,
        stage: VideoDownloadJobStage.download,
      );
      await failJob(environment, oldJobId, clearTarget: true);
      await insertSubscription(
        environment,
        targetSourceId: environment.sourceId,
        jobId: oldJobId,
      );
      await environment.database.updateVideoDownloadJob(
        newJobId,
        const VideoDownloadJobsCompanion(
          lifecycle: Value<String>(VideoDownloadJobLifecycle.active),
        ),
      );

      environment.service.wake();
      await backend.addEntered.future.timeout(const Duration(seconds: 2));

      expect(await environment.database.getVideoDownloadJob(oldJobId), isNull);
      final VideoDownloadJobRow job =
          (await environment.database.getVideoDownloadJob(newJobId))!;
      expect(job.torrentHash, _torrentHash);
      final VideoDownloadSubscriptionItemRow item = (await environment.database
              .getVideoDownloadSubscriptionItems('sub-2755'))
          .single;
      expect(item.jobId, newJobId);
      expect(
          backend.addSavePaths, <String?>[incomingOf(environment.root.path)]);
    });
  });

  group('BUG-2776 completed seeds leave the engine with their source', () {
    const String orphanHash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const String absentHash = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    const String stuckHash = 'cccccccccccccccccccccccccccccccccccccccc';
    const String liveHash = 'dddddddddddddddddddddddddddddddddddddddd';
    const String discoveryHash = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
    const String activeHash = 'ffffffffffffffffffffffffffffffffffffffff';

    Future<int> insertSource(_PipelineEnvironment environment, String label) =>
        environment.database.insertMediaSource(
          MediaSourcesCompanion.insert(
            label: label,
            mediaKind: 'video',
            rootPath: p.join(environment.root.path, label),
            createdAt: 1,
          ),
        );

    /// 插一条任务并换成独立 hash（同 fingerprint 下 hash 唯一）。
    Future<void> insertSeed(
      _PipelineEnvironment environment, {
      required String jobId,
      required String hash,
      int? sourceId,
      bool withoutTargetSource = false,
      String organizationPolicy = 'library',
      String lifecycle = VideoDownloadJobLifecycle.completed,
      String stage = VideoDownloadJobStage.import,
    }) async {
      await environment.insertJob(
        jobId: jobId,
        stage: stage,
        lifecycle: lifecycle,
        organizationPolicy: organizationPolicy,
        withoutTargetSource: withoutTargetSource,
      );
      await environment.database.updateVideoDownloadJob(
        jobId,
        VideoDownloadJobsCompanion(
          torrentHash: Value<String?>(hash),
          backendTaskId: Value<String?>(hash),
          targetSourceId: sourceId == null
              ? const Value<int?>.absent()
              : Value<int?>(sourceId),
        ),
      );
    }

    Future<String?> hashOf(
      _PipelineEnvironment environment,
      String jobId,
    ) async =>
        (await environment.database.getVideoDownloadJob(jobId))!.torrentHash;

    test('resume keepIds drop completed jobs whose source was deleted',
        () async {
      final _PipelineEnvironment environment =
          await _PipelineEnvironment.create(backend: _FakeTorrentBackend());
      addTearDown(environment.close);
      final int oldSource = await insertSource(environment, 'old');
      await insertSeed(
        environment,
        jobId: 'orphan',
        hash: orphanHash,
        sourceId: oldSource,
      );
      await insertSeed(environment, jobId: 'live', hash: liveHash);
      await insertSeed(
        environment,
        jobId: 'active-unsourced',
        hash: activeHash,
        withoutTargetSource: true,
        lifecycle: VideoDownloadJobLifecycle.active,
        stage: VideoDownloadJobStage.download,
      );
      await environment.database.deleteMediaSource(oldSource);

      expect(
        await loadEmbeddedTorrentResumeIds(environment.database),
        <String>{liveHash, activeHash},
        reason: '来源已删的已完成种子不再续传，否则删掉旧目录后引擎在原处重下；'
            '未完成任务的来源失效由改绑流程处理，不在这里剪掉',
      );
    });

    test('orphaned completed seeds are detached without deleting files',
        () async {
      final _RemovingTorrentBackend backend = _RemovingTorrentBackend(
        failingIds: <String>{absentHash, stuckHash},
        snapshots: <TorrentSnapshot>[
          const TorrentSnapshot(
            hash: stuckHash,
            name: 'Show',
            progress: 1,
            state: 'uploading',
            savePath: '/old',
            contentPath: '/old/Show',
            amountLeft: 0,
          ),
        ],
      );
      final _PipelineEnvironment environment =
          await _PipelineEnvironment.create(backend: backend);
      addTearDown(environment.close);
      final int oldSource = await insertSource(environment, 'old');
      for (final (String jobId, String hash) in <(String, String)>[
        ('orphan', orphanHash),
        ('absent', absentHash),
        ('stuck', stuckHash),
      ]) {
        await insertSeed(
          environment,
          jobId: jobId,
          hash: hash,
          sourceId: oldSource,
        );
      }
      await insertSeed(environment, jobId: 'live', hash: liveHash);
      await insertSeed(
        environment,
        jobId: 'discovery',
        hash: discoveryHash,
        withoutTargetSource: true,
        organizationPolicy: manualDiscoveryOrganizationPolicy(
          DiscoveryMediaKind.novel,
        ),
      );
      await environment.database.deleteMediaSource(oldSource);

      final int released =
          await environment.service.releaseOrphanedCompletedSeeds();

      expect(released, 2);
      expect(
        backend.removals,
        unorderedEquals(<(String, bool)>[
          (orphanHash, false),
          (absentHash, false),
          (stuckHash, false),
        ]),
      );
      expect(await hashOf(environment, 'orphan'), isNull);
      expect(
        await hashOf(environment, 'absent'),
        isNull,
        reason: '后端里本来就没有这颗种子，同样算摘掉',
      );
      expect(
        await hashOf(environment, 'stuck'),
        stuckHash,
        reason: '摘除失败且种子仍在后端：保持原样下次再摘',
      );
      expect(await hashOf(environment, 'live'), liveHash);
      expect(await hashOf(environment, 'discovery'), discoveryHash);
      expect(
        await environment.database.getVideoDownloadJob('orphan'),
        isNotNull,
        reason: '只摘种子，任务行与已整理文件保留',
      );
    });

    test(
        'retargeting a subscription detaches its episodes left in the old '
        'source', () async {
      final _RemovingTorrentBackend backend = _RemovingTorrentBackend();
      final _PipelineEnvironment environment =
          await _PipelineEnvironment.create(backend: backend);
      addTearDown(environment.close);
      final int newSource = await insertSource(environment, 'new');
      await environment.database.upsertVideoDownloadSubscription(
        VideoDownloadSubscriptionsCompanion.insert(
          subscriptionId: 'sub-1',
          resourceProvider: 'nyaa:test-instance',
          mediaKind: 'tv',
          title: 'Show',
          searchQuery: 'Show',
          backendKind: 'embedded',
          fingerprint: _expectedIdentity.fingerprint,
          targetSourceId: Value<int?>(newSource),
          createdAt: 1,
          updatedAt: 1,
        ),
      );
      Future<void> link(String jobId, int episode) =>
          environment.database.upsertVideoDownloadSubscriptionItem(
            VideoDownloadSubscriptionItemsCompanion.insert(
              subscriptionId: 'sub-1',
              logicalItemKey: 's1e$episode',
              resourceProvider: 'nyaa:test-instance',
              selectedResourceId: 'release-$episode',
              title: 'Show - $episode',
              jobId: Value<String?>(jobId),
              discoveredAt: 1,
              updatedAt: 1,
            ),
          );
      await insertSeed(environment, jobId: 'done-old', hash: orphanHash);
      await link('done-old', 1);
      await insertSeed(
        environment,
        jobId: 'done-new',
        hash: liveHash,
        sourceId: newSource,
      );
      await link('done-new', 2);
      await insertSeed(
        environment,
        jobId: 'downloading',
        hash: activeHash,
        lifecycle: VideoDownloadJobLifecycle.active,
        stage: VideoDownloadJobStage.download,
      );
      await link('downloading', 3);
      await insertSeed(environment, jobId: 'unlinked', hash: stuckHash);

      final int released = await environment.service
          .releaseSubscriptionSeedsOutsideTarget('sub-1');

      expect(released, 1);
      expect(backend.removals, <(String, bool)>[(orphanHash, false)]);
      expect(await hashOf(environment, 'done-old'), isNull);
      expect(await hashOf(environment, 'done-new'), liveHash);
      expect(
        await hashOf(environment, 'downloading'),
        activeHash,
        reason: '未完成的集由改绑流程带进新来源，不摘',
      );
      expect(await hashOf(environment, 'unlinked'), stuckHash);
    });
  });
}

/// 与 torrent_metainfo_test 同款的最小 v1 metainfo（单文件 name=test）。
Uint8List _manualV1Metainfo() => Uint8List.fromList(
      utf8.encode(
        'd4:infod6:lengthi1e4:name4:test6:pieces20:aaaaaaaaaaaaaaaaaaaaee',
      ),
    );

/// 三文件 v1 合集（TMW Part 这类一颗 torrent 装多卷）。
Uint8List _manualPackMetainfo() => Uint8List.fromList(
      utf8.encode(
        'd4:infod5:filesld6:lengthi1e4:pathl5:a.m4beed6:lengthi1e4:pathl5:'
        'b.m4beed6:lengthi1e4:pathl5:c.m4beee4:name4:pack6:pieces20:'
        'aaaaaaaaaaaaaaaaaaaaee',
      ),
    );

TorrentSnapshot _downloadingSnapshot({required double progress}) =>
    TorrentSnapshot(
      hash: _torrentHash,
      name: 'Show',
      progress: progress,
      state: 'downloading',
      savePath: '/downloads',
      contentPath: '/downloads/Show',
      amountLeft: 100,
    );

TorrentSnapshot _completeSnapshot() => const TorrentSnapshot(
      hash: _torrentHash,
      name: 'Show',
      progress: 1,
      state: 'uploading',
      savePath: '/downloads',
      contentPath: '/downloads/Show',
      amountLeft: 0,
    );

Future<VideoDownloadJobRow> _waitForJob(
  FushiDatabase database,
  String jobId,
  bool Function(VideoDownloadJobRow row) predicate,
) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 3));
  while (DateTime.now().isBefore(deadline)) {
    final VideoDownloadJobRow? row = await database.getVideoDownloadJob(jobId);
    if (row != null && predicate(row)) return row;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  final VideoDownloadJobRow? last = await database.getVideoDownloadJob(jobId);
  throw TimeoutException('job $jobId did not reach expected state: $last');
}

class _PipelineEnvironment {
  _PipelineEnvironment._({
    required this.database,
    required this.root,
    required this.sourceId,
    required this.backend,
    required this.provider,
    required this.resourceRegistry,
    required this.subtitleRegistry,
    required this.metadataRegistry,
    required this.scrapeCoordinator,
    required this.service,
  });

  final FushiDatabase database;
  final Directory root;
  final int sourceId;
  final _FakeTorrentBackend backend;
  final _FakeResourceProvider provider;
  final VideoResourceRegistry resourceRegistry;
  final VideoSubtitleRegistry? subtitleRegistry;
  final VideoMetadataProviderRegistry metadataRegistry;
  final VideoSourceScrapeCoordinator scrapeCoordinator;
  final VideoDownloadPipelineService service;

  static Future<_PipelineEnvironment> create({
    required _FakeTorrentBackend backend,
    VideoDownloadBackendResolver? backendResolver,
    VideoSubtitleProvider? subtitleProvider,
    VideoDownloadSubtitleLanguageResolver? subtitleLanguageResolver,
    Iterable<String> preferredSubtitleLanguages = const <String>[],
    VideoMetadataProvider? metadataProvider,
    Future<void> Function(VideoDownloadJobRow job)? onBackendTaskAdded,
    Duration leaseDuration = const Duration(minutes: 1),
    Duration pollInterval = const Duration(hours: 1),
    String? candidateMagnetUri,
    UpdateFeedPublisher? updateFeed,
    VideoCoverExtractor? coverExtractor,
    bool Function()? skipDownloadExtras,
    AutomaticSubtitleAligner? subtitleAligner,
    Future<int?> Function()? defaultTargetSourceId,
  }) async {
    final FushiDatabase database =
        FushiDatabase.forTesting(NativeDatabase.memory());
    final Directory root =
        await Directory.systemTemp.createTemp('fushi-pipeline-service-');
    final int sourceId = await database.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Managed videos',
        mediaKind: 'video',
        rootPath: root.path,
        createdAt: 1,
      ),
    );
    final _FakeResourceProvider provider =
        _FakeResourceProvider(candidateMagnetUri: candidateMagnetUri);
    final VideoResourceRegistry resourceRegistry =
        VideoResourceRegistry(<VideoResourceProvider>[provider]);
    final VideoSubtitleRegistry? subtitleRegistry = subtitleProvider == null
        ? null
        : VideoSubtitleRegistry(<VideoSubtitleProvider>[subtitleProvider]);
    final VideoMetadataProviderRegistry metadataRegistry =
        VideoMetadataProviderRegistry(<VideoMetadataProvider>[
      metadataProvider ?? _UnavailableAniListMetadataProvider(),
    ]);
    final VideoSourceScrapeCoordinator scrapeCoordinator =
        VideoSourceScrapeCoordinator(
      database: database,
      config: const VideoSourceScrapeGlobalConfig(),
      registry: metadataRegistry,
    );
    final VideoDownloadPipelineService service = VideoDownloadPipelineService(
      database: database,
      resourceRegistry: resourceRegistry,
      subtitleRegistry: subtitleRegistry,
      subtitleAligner: subtitleAligner,
      subtitleLanguageResolver: subtitleLanguageResolver,
      preferredSubtitleLanguages: preferredSubtitleLanguages,
      backendResolver: backendResolver ??
          (_) async => VideoDownloadBackendBinding(
                backend: backend,
                identity: _expectedIdentity,
              ),
      scrapeCoordinator: scrapeCoordinator,
      onBackendTaskAdded: onBackendTaskAdded,
      workerId: 'pipeline-test-worker',
      pollInterval: pollInterval,
      leaseDuration: leaseDuration,
      updateFeed: updateFeed,
      coverExtractor: coverExtractor,
      videoCoversDirectory: Directory(p.join(root.path, 'covers')),
      skipDownloadExtras: skipDownloadExtras,
      defaultTargetSourceId: defaultTargetSourceId,
    );
    return _PipelineEnvironment._(
      database: database,
      root: root,
      sourceId: sourceId,
      backend: backend,
      provider: provider,
      resourceRegistry: resourceRegistry,
      subtitleRegistry: subtitleRegistry,
      metadataRegistry: metadataRegistry,
      scrapeCoordinator: scrapeCoordinator,
      service: service,
    );
  }

  VideoDownloadEnqueueRequest enqueueRequest() => VideoDownloadEnqueueRequest(
        media: _mediaReference(),
        resource: provider.candidate,
        backendTarget: _expectedTarget,
        targetSourceId: sourceId,
      );

  Future<void> insertJob({
    required String jobId,
    required String stage,
    bool staleClaim = false,
    String organizationPolicy = 'library',
    String? observedSavePath,
    VideoDownloadSubtitlePolicy subtitlePolicy =
        VideoDownloadSubtitlePolicy.bestEffort,
    bool withoutTargetSource = false,
    String backendKind = 'embedded',
    String lifecycle = VideoDownloadJobLifecycle.active,
    String category = _expectedCategory,
    String? identityJson,
    String? mediaKind,
  }) {
    final int now = DateTime.now().millisecondsSinceEpoch;
    return database.upsertVideoDownloadJob(
      VideoDownloadJobsCompanion.insert(
        jobId: jobId,
        resourceProvider: 'nyaa:test-instance',
        selectedResourceId: 'release-1',
        magnetUri: const Value<String?>(
          'magnet:?xt=urn:btih:$_torrentHash',
        ),
        resourceTitle: const Value<String?>('Show S01E01'),
        torrentHash: const Value<String?>(_torrentHash),
        metadataProvider: const Value<String?>('anilist'),
        externalId: const Value<String?>('100'),
        identityJson: Value<String?>(identityJson),
        mediaKind: mediaKind ?? VideoMetadataMediaKind.tv.name,
        discoveryCategory: Value<String?>(VideoDiscoveryCategory.anime.name),
        title: 'Show',
        year: const Value<int?>(2026),
        season: const Value<int?>(1),
        backendKind: backendKind,
        backendTaskId: const Value<String?>(_torrentHash),
        backendProfileId: Value<String?>(_expectedIdentity.profileId),
        fingerprint: _expectedIdentity.fingerprint,
        category: Value<String?>(category),
        targetSourceId: Value<int?>(withoutTargetSource ? null : sourceId),
        organizationPolicy: Value<String>(organizationPolicy),
        subtitlePolicy: Value<String>(subtitlePolicy.name),
        observedSavePath: Value<String?>(observedSavePath),
        lifecycle: Value<String>(lifecycle),
        stage: Value<String>(stage),
        claimedBy: Value<String?>(staleClaim ? 'previous-process' : null),
        claimExpiresAt: Value<int?>(staleClaim ? now - 1 : null),
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  Future<void> insertDownloadedFile({
    required String jobId,
    required String name,
    required int size,
  }) {
    final int now = DateTime.now().millisecondsSinceEpoch;
    return database.upsertVideoDownloadJobFile(
      VideoDownloadJobFilesCompanion.insert(
        jobId: jobId,
        backendFileIndex: const Value<int?>(0),
        originalRelativePath: name,
        currentRelativePath: name,
        sizeBytes: Value<int?>(size),
        status: const Value<String>(VideoDownloadJobFileStatus.downloaded),
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  /// Inserts a file row whose `currentRelativePath` is whatever the backend
  /// reported, without any index or sanitising, exactly like the pipeline does.
  Future<void> insertBackendFile({
    required String jobId,
    required String name,
  }) {
    final int now = DateTime.now().millisecondsSinceEpoch;
    return database.upsertVideoDownloadJobFile(
      VideoDownloadJobFilesCompanion.insert(
        jobId: jobId,
        originalRelativePath: name,
        currentRelativePath: name,
        status: const Value<String>(VideoDownloadJobFileStatus.downloaded),
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  Future<void> close() async {
    backend.releaseAdd();
    await service.dispose();
    resourceRegistry.close();
    subtitleRegistry?.close();
    scrapeCoordinator.close();
    metadataRegistry.close();
    await database.close();
    if (await root.exists()) await root.delete(recursive: true);
  }
}

VideoMediaReference _mediaReference() => VideoMediaReference(
      providerId: 'anilist',
      mediaId: '100',
      mediaKind: VideoMetadataMediaKind.tv,
      discoveryCategory: VideoDiscoveryCategory.anime,
      title: 'Show',
      year: 2026,
      season: 1,
    );

class _FakeResourceCandidate extends VideoResourceCandidate {
  _FakeResourceCandidate({String? magnetUri})
      : super(
          providerId: 'nyaa',
          providerInstanceId: 'test-instance',
          remoteId: 'release-1',
          title: 'Show S01E01',
          providerPriority: 0,
          infoHash: _torrentHash,
          magnetUri: magnetUri,
        );
}

/// 在受管来源下放一集已 organize 好的视频并登记文件行（`Show (2026)/Season 01`）。
Future<void> _seedOrganizedEpisode(
  _PipelineEnvironment environment,
  String jobId,
) async {
  final Directory season = Directory(
    p.join(environment.root.path, 'Show (2026)', 'Season 01'),
  );
  await season.create(recursive: true);
  final File video = File(p.join(season.path, 'Show (2026) - S01E02.mkv'));
  await video.writeAsBytes(<int>[0, 1, 2, 3], flush: true);
  final int now = DateTime.now().millisecondsSinceEpoch;
  await environment.database.upsertVideoDownloadJobFile(
    VideoDownloadJobFilesCompanion.insert(
      jobId: jobId,
      backendFileIndex: const Value<int?>(0),
      originalRelativePath: p.basename(video.path),
      currentRelativePath: p.basename(video.path),
      targetRelativePath: Value<String?>(p.basename(video.path)),
      finalAbsolutePath: Value<String?>(video.path),
      kind: const Value<String>('video'),
      season: const Value<int?>(1),
      episode: const Value<int?>(2),
      sizeBytes: Value<int?>(await video.length()),
      status: const Value<String>(VideoDownloadJobFileStatus.organized),
      createdAt: now,
      updatedAt: now,
    ),
  );
}

class _FakeSubtitleCandidate extends VideoSubtitleCandidate {
  _FakeSubtitleCandidate()
      : super(
          providerId: 'opensubtitles',
          remoteId: 'subtitle-42',
          fileName: 'Show.S01E02.zh.srt',
          language: 'zh-CN',
          providerPriority: 0,
          season: 1,
          episode: 2,
        );
}

class _FakeSubtitleProvider implements VideoSubtitleProvider {
  /// 测试假实现：不发真请求，探测门控取值不影响被测行为。
  @override
  bool get allowsFreeProbeDownload => false;

  _FakeSubtitleProvider({required this.bytes, this.downloadFileName});

  final Uint8List bytes;

  /// 下载后才知道的真实文件名（SubDL 解 zip 的形态）；null = 与候选名相同。
  final String? downloadFileName;
  final _FakeSubtitleCandidate candidate = _FakeSubtitleCandidate();
  int searchCalls = 0;
  int downloadCalls = 0;

  /// 最近一次搜索请求（断言语言硬过滤用）。
  VideoSubtitleSearchRequest? lastRequest;

  @override
  String get id => 'opensubtitles';

  @override
  int get priority => 0;

  @override
  Future<ProviderBatchResult<VideoSubtitleCandidate>> search(
    VideoSubtitleSearchRequest request,
  ) async {
    searchCalls += 1;
    lastRequest = request;
    return ProviderBatchResult<VideoSubtitleCandidate>.success(
      <VideoSubtitleCandidate>[candidate],
    );
  }

  @override
  Future<VideoSubtitleDownload> download(
    VideoSubtitleCandidate candidate,
  ) async {
    downloadCalls += 1;
    return VideoSubtitleDownload(
      bytes: bytes,
      fileName: downloadFileName ?? candidate.fileName,
      language: candidate.language,
    );
  }

  @override
  void close() {}
}

class _FakeResourceProvider implements VideoResourceProvider {
  _FakeResourceProvider({String? candidateMagnetUri})
      : candidate = _FakeResourceCandidate(magnetUri: candidateMagnetUri);

  final _FakeResourceCandidate candidate;
  int searchCalls = 0;
  int resolveCalls = 0;

  /// true = 重搜找不回已选条目（条目下架/发布名搜不中），search 返回空成功。
  bool returnEmptySearch = false;

  /// true = 索引器彻底不可达（网络故障/限流/下线），search 直接抛。
  bool failSearch = false;

  @override
  String get id => 'nyaa';

  /// 测试替身不限域：真实域归属是各 provider 自己的内容边界，这里断言的是
  /// 流水线行为，不该再依赖「id 恰好叫 nyaa」这种间接门控。
  @override
  Set<VideoDiscoveryCategory> get categories =>
      const <VideoDiscoveryCategory>{};

  @override
  int get priority => 0;

  @override
  Future<ProviderBatchResult<VideoResourceCandidate>> search(
    VideoResourceSearchRequest request,
  ) async {
    searchCalls += 1;
    if (failSearch) {
      throw const ExternalProviderFailure(
        providerId: 'nyaa',
        operation: 'search',
        kind: ExternalProviderFailureKind.unavailable,
        message: 'indexer is unreachable',
      );
    }
    return ProviderBatchResult<VideoResourceCandidate>.success(
      returnEmptySearch
          ? const <VideoResourceCandidate>[]
          : <VideoResourceCandidate>[candidate],
    );
  }

  @override
  Future<TorrentAddPayload> resolve(VideoResourceCandidate candidate) async {
    resolveCalls += 1;
    return const TorrentMagnetPayload(
      magnetUri: 'magnet:?xt=urn:btih:$_torrentHash',
      torrentId: _torrentHash,
    );
  }

  @override
  void close() {}
}

class _UnavailableAniListMetadataProvider implements VideoMetadataProvider {
  @override
  VideoMetadataProviderKind get providerKind =>
      VideoMetadataProviderKind.anilist;

  @override
  bool get isAvailable => false;

  @override
  Future<List<VideoMetadataWork>> search(
    VideoMetadataSearchRequest request,
  ) =>
      throw UnsupportedError('unavailable provider must not be queried');

  @override
  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup) =>
      throw UnsupportedError('unavailable provider must not be queried');

  @override
  Future<List<VideoMetadataSeason>> fetchSeasons(
    VideoMetadataLookup lookup,
  ) =>
      throw UnsupportedError('unavailable provider must not be queried');

  @override
  Future<List<VideoMetadataEpisode>> fetchEpisodes(
    VideoMetadataLookup lookup, {
    required int seasonNumber,
  }) =>
      throw UnsupportedError('unavailable provider must not be queried');

  @override
  void close() {}
}

/// 已配置、但每次请求都 504（Jikan 抽风时的真实形态）。
class _GatewayTimeoutMalProvider implements VideoMetadataProvider {
  static const VideoMetadataNetworkException _error =
      VideoMetadataNetworkException(
    'MAL anime/42/full HTTP 504',
    statusCode: 504,
  );

  @override
  VideoMetadataProviderKind get providerKind => VideoMetadataProviderKind.mal;

  @override
  bool get isAvailable => true;

  @override
  Future<List<VideoMetadataWork>> search(
    VideoMetadataSearchRequest request,
  ) =>
      throw _error;

  @override
  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup) =>
      throw _error;

  @override
  Future<List<VideoMetadataSeason>> fetchSeasons(
    VideoMetadataLookup lookup,
  ) =>
      throw _error;

  @override
  Future<List<VideoMetadataEpisode>> fetchEpisodes(
    VideoMetadataLookup lookup, {
    required int seasonNumber,
  }) =>
      throw _error;

  @override
  void close() {}
}

class _FakeTorrentBackend implements TorrentPauseBackend {
  _FakeTorrentBackend({
    this.snapshots = const <TorrentSnapshot>[],
    this.files = const <TorrentFileEntry>[],
    this.pauseResult = true,
    bool pauseAdd = false,
  }) : _addGate = pauseAdd ? Completer<bool>() : null;

  final List<TorrentSnapshot> snapshots;
  final List<TorrentFileEntry> files;
  final bool pauseResult;
  final Completer<bool>? _addGate;
  final Completer<void> addEntered = Completer<void>();
  Future<void> Function()? beforeAdd;
  int prepareCategoryCalls = 0;
  final List<String> preparedCategories = <String>[];
  int addCalls = 0;
  final List<String?> addSavePaths = <String?>[];
  int listTorrentsCalls = 0;
  int listFilesCalls = 0;
  int pauseCalls = 0;
  int resumeCalls = 0;
  int moveStorageCalls = 0;
  int renameFileCalls = 0;
  final List<String> moveStoragePaths = <String>[];
  final List<String> pausedTorrentIds = <String>[];
  final List<String> resumedTorrentIds = <String>[];

  @override
  bool get pauseControlAvailable => true;

  @override
  Future<bool> pauseTorrent(String torrentId) async {
    pauseCalls += 1;
    pausedTorrentIds.add(torrentId);
    return pauseResult;
  }

  @override
  Future<bool> resumeTorrent(String torrentId) async {
    resumeCalls += 1;
    resumedTorrentIds.add(torrentId);
    return true;
  }

  void releaseAdd([bool accepted = true]) {
    final Completer<bool>? gate = _addGate;
    if (gate != null && !gate.isCompleted) gate.complete(accepted);
  }

  @override
  Future<bool> addTorrent(
    String magnetOrUrl, {
    required String category,
    String? savePath,
    bool sequential = false,
    bool firstLastPiecePrio = false,
  }) async {
    addCalls += 1;
    addSavePaths.add(savePath);
    await beforeAdd?.call();
    if (!addEntered.isCompleted) addEntered.complete();
    return await _addGate?.future ?? true;
  }

  @override
  void close() {}

  @override
  Future<List<TorrentFileEntry>> listFiles(String torrentId) async {
    listFilesCalls += 1;
    return files;
  }

  @override
  Future<List<TorrentSnapshot>> listTorrents({String? category}) async {
    listTorrentsCalls += 1;
    return snapshots;
  }

  @override
  Future<TorrentStorageResult> moveStorage(
    String torrentId,
    String newSavePath,
  ) async {
    moveStorageCalls += 1;
    moveStoragePaths.add(newSavePath);
    return TorrentStorageResult(ok: true, path: newSavePath);
  }

  @override
  Future<bool> prepareCategory(String category) async {
    prepareCategoryCalls += 1;
    preparedCategories.add(category);
    return true;
  }

  @override
  Future<String?> probeConnection() async => 'fake';

  @override
  Future<TorrentStorageResult> renameFile(
    String torrentId,
    int fileIndex,
    String newPath,
  ) async {
    renameFileCalls += 1;
    return TorrentStorageResult(ok: true, path: newPath);
  }
}

/// 带文件优先级能力的 fake：记录每次写入的优先级与被改名的文件序号。
class _FakeDetailTorrentBackend extends _FakeTorrentBackend
    implements TorrentDetailBackend, TorrentRemovalBackend {
  _FakeDetailTorrentBackend({
    required List<TorrentSnapshot> snapshots,
    required List<TorrentFileEntry> files,
  }) : super(snapshots: snapshots, files: files);

  bool priorityResult = true;
  final Map<int, TorrentFilePriority> priorities = <int, TorrentFilePriority>{};
  final List<int> renamedIndexes = <int>[];

  /// 每次 removeTorrent 的 deleteFiles 参数。
  final List<bool> removeDeleteFiles = <bool>[];

  @override
  Future<bool> removeTorrent(String torrentId,
      {bool deleteFiles = false}) async {
    removeDeleteFiles.add(deleteFiles);
    return true;
  }

  @override
  bool get detailAvailable => true;

  @override
  Future<List<TorrentPeerDetail>?> listPeers(String torrentId) async => null;

  @override
  Future<List<TorrentTrackerDetail>?> listTrackers(String torrentId) async =>
      null;

  @override
  Future<List<TorrentFilePriority>?> filePriorities(String torrentId) async =>
      null;

  @override
  Future<bool> setFilePriority(
    String torrentId,
    int fileIndex,
    TorrentFilePriority priority,
  ) async {
    if (!priorityResult) return false;
    priorities[fileIndex] = priority;
    return true;
  }

  @override
  Future<TorrentSessionStatusInfo?> sessionStatus() async => null;

  @override
  Future<TorrentPieceStates?> pieceStates(String torrentId) async => null;

  @override
  Future<TorrentStorageResult> renameFile(
    String torrentId,
    int fileIndex,
    String newPath,
  ) {
    renamedIndexes.add(fileIndex);
    return super.renameFile(torrentId, fileIndex, newPath);
  }
}

/// 能以暂停态添加 .torrent 的 fake：单文件选择（CoreAudio/TMW）走这条路。
/// 后端当前持有哪些种子随 add/remove 变化，文件优先级按写入回读。
class _FakePausedMetainfoBackend extends _FakeDetailTorrentBackend
    implements TorrentPausedMetainfoBackend {
  _FakePausedMetainfoBackend({required this.fileCount})
      : super(
          snapshots: const <TorrentSnapshot>[],
          files: const <TorrentFileEntry>[],
        );

  final int fileCount;
  final Set<String> held = <String>{};
  final List<String> pausedAdds = <String>[];

  @override
  Future<bool> addTorrentMetainfoPaused(
    TorrentMetainfoPayload payload, {
    required String category,
    String? savePath,
  }) async {
    final String hash = (payload.torrentId ?? '').toLowerCase();
    pausedAdds.add(hash);
    held.add(hash);
    return true;
  }

  @override
  Future<List<TorrentSnapshot>> listTorrents({String? category}) async =>
      <TorrentSnapshot>[
        for (final String hash in held)
          TorrentSnapshot(
            hash: hash,
            name: 'pack',
            progress: 0.1,
            state: 'downloading',
            savePath: '/downloads',
            contentPath: '/downloads/pack',
            amountLeft: 100,
          ),
      ];

  @override
  Future<List<TorrentFilePriority>?> filePriorities(String torrentId) async =>
      <TorrentFilePriority>[
        for (int index = 0; index < fileCount; index++)
          priorities[index] ?? TorrentFilePriority.normal,
      ];

  @override
  Future<bool> removeTorrent(String torrentId,
      {bool deleteFiles = false}) async {
    held.remove(torrentId.toLowerCase());
    return super.removeTorrent(torrentId, deleteFiles: deleteFiles);
  }
}

/// Records the real coordinator fetch contract without doing network or sidecar IO.
class _RecordingMetadataProvider extends _UnavailableAniListMetadataProvider {
  _RecordingMetadataProvider(this.providerKind);

  @override
  final VideoMetadataProviderKind providerKind;
  final List<VideoMetadataLookup> lookups = <VideoMetadataLookup>[];
  int searchCalls = 0;

  @override
  bool get isAvailable => true;

  @override
  Future<List<VideoMetadataWork>> search(
      VideoMetadataSearchRequest request) async {
    searchCalls++;
    throw StateError('confirmed identity must not use title search');
  }

  @override
  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup) async {
    lookups.add(lookup);
    throw StateError('recorded confirmed lookup');
  }
}

/// 记录投递到更新提醒端口的批次（不落库、不发通知）。
class _RecordingUpdateFeed implements UpdateFeedPublisher {
  final List<({UpdateFeedKind kind, List<UpdateFeedDraft> drafts})> batches =
      <({UpdateFeedKind kind, List<UpdateFeedDraft> drafts})>[];

  @override
  Future<void> publishBatch(
    UpdateFeedKind kind,
    List<UpdateFeedDraft> drafts,
  ) async {
    batches.add((kind: kind, drafts: List<UpdateFeedDraft>.of(drafts)));
  }
}

/// 带移除能力的假后端（BUG-2776）：[failingIds] 里的种子摘除返回 false。
class _RemovingTorrentBackend extends _FakeTorrentBackend
    implements TorrentRemovalBackend {
  _RemovingTorrentBackend({
    super.snapshots,
    this.failingIds = const <String>{},
  });

  final Set<String> failingIds;
  final List<(String, bool)> removals = <(String, bool)>[];

  @override
  Future<bool> removeTorrent(String torrentId,
      {bool deleteFiles = false}) async {
    removals.add((torrentId, deleteFiles));
    return !failingIds.contains(torrentId);
  }
}
