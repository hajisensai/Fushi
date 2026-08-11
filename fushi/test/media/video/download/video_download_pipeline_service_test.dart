import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/torrent/torrent_backend.dart';
import 'package:fushi/src/media/torrent/video_resource_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/download/video_download_backend_identity.dart';
import 'package:fushi/src/media/video/download/video_download_path_mapping.dart';
import 'package:fushi/src/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi/src/media/video/download/video_resource_registry.dart';
import 'package:fushi/src/media/video/download/video_subtitle_registry.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_resolver.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_coordinator.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

const String _torrentHash = '0123456789abcdef0123456789abcdef01234567';
const VideoDownloadBackendIdentity _expectedIdentity =
    VideoDownloadBackendIdentity(
  kind: 'embedded',
  profileId: 'embedded',
  fingerprint: 'installation-fingerprint',
  category: 'fushi-video',
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
    expect(persisted.category, _expectedIdentity.category);
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
        category: 'fushi-video',
      ),
    ),
    (
      label: 'category',
      identity: const VideoDownloadBackendIdentity(
        kind: 'embedded',
        profileId: 'embedded',
        fingerprint: 'installation-fingerprint',
        category: 'different-category',
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
                  category: 'fushi-video',
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
    await _waitForJob(
      environment.database,
      jobId,
      (VideoDownloadJobRow row) =>
          row.stage == VideoDownloadJobStage.scrape &&
          row.lifecycle == VideoDownloadJobLifecycle.needsAttention,
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
    await _waitForJob(
      environment.database,
      jobId,
      (VideoDownloadJobRow row) =>
          row.stage == VideoDownloadJobStage.scrape &&
          row.lifecycle == VideoDownloadJobLifecycle.needsAttention,
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
    await _waitForJob(
      environment.database,
      jobId,
      (VideoDownloadJobRow row) =>
          row.stage == VideoDownloadJobStage.scrape &&
          row.lifecycle == VideoDownloadJobLifecycle.needsAttention,
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

  test('scrape never falls back to a same-title unrelated local work',
      () async {
    final _PipelineEnvironment environment = await _PipelineEnvironment.create(
      backend: _FakeTorrentBackend(),
    );
    addTearDown(environment.close);
    const String jobId = 'exact-scrape-path-job';
    await environment.insertJob(
      jobId: jobId,
      stage: VideoDownloadJobStage.scrape,
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

    expect(job.lastError, contains('mapped exactly'));
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

  test('missing active embedded torrent is rewound without retry exhaustion',
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
    expect(job.attemptCount, 0);
    expect(job.backendTaskId, isNull);
    expect(job.lastError, isNull);
    expect(
        job.nextAttemptAt, greaterThan(DateTime.now().millisecondsSinceEpoch));
  });

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
          category: 'fushi-video',
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
}

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
    Future<void> Function(VideoDownloadJobRow job)? onBackendTaskAdded,
    Duration leaseDuration = const Duration(minutes: 1),
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
    final _FakeResourceProvider provider = _FakeResourceProvider();
    final VideoResourceRegistry resourceRegistry =
        VideoResourceRegistry(<VideoResourceProvider>[provider]);
    final VideoSubtitleRegistry? subtitleRegistry = subtitleProvider == null
        ? null
        : VideoSubtitleRegistry(<VideoSubtitleProvider>[subtitleProvider]);
    final VideoMetadataProviderRegistry metadataRegistry =
        VideoMetadataProviderRegistry(<VideoMetadataProvider>[
      _UnavailableAniListMetadataProvider(),
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
      backendResolver: backendResolver ??
          (_) async => VideoDownloadBackendBinding(
                backend: backend,
                identity: _expectedIdentity,
              ),
      scrapeCoordinator: scrapeCoordinator,
      onBackendTaskAdded: onBackendTaskAdded,
      workerId: 'pipeline-test-worker',
      pollInterval: const Duration(hours: 1),
      leaseDuration: leaseDuration,
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
        backendIdentity: _expectedIdentity,
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
        mediaKind: VideoMetadataMediaKind.tv.name,
        discoveryCategory: Value<String?>(VideoDiscoveryCategory.anime.name),
        title: 'Show',
        year: const Value<int?>(2026),
        season: const Value<int?>(1),
        backendKind: backendKind,
        backendTaskId: const Value<String?>(_torrentHash),
        backendProfileId: Value<String?>(_expectedIdentity.profileId),
        fingerprint: _expectedIdentity.fingerprint,
        category: Value<String?>(_expectedIdentity.category),
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
  _FakeResourceCandidate()
      : super(
          providerId: 'nyaa',
          providerInstanceId: 'test-instance',
          remoteId: 'release-1',
          title: 'Show S01E01',
          providerPriority: 0,
          infoHash: _torrentHash,
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
  _FakeSubtitleProvider({required this.bytes});

  final Uint8List bytes;
  final _FakeSubtitleCandidate candidate = _FakeSubtitleCandidate();
  int searchCalls = 0;
  int downloadCalls = 0;

  @override
  String get id => 'opensubtitles';

  @override
  int get priority => 0;

  @override
  Future<ProviderBatchResult<VideoSubtitleCandidate>> search(
    VideoSubtitleSearchRequest request,
  ) async {
    searchCalls += 1;
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
      fileName: candidate.fileName,
      language: candidate.language,
    );
  }

  @override
  void close() {}
}

class _FakeResourceProvider implements VideoResourceProvider {
  _FakeResourceProvider() : candidate = _FakeResourceCandidate();

  final _FakeResourceCandidate candidate;
  int searchCalls = 0;
  int resolveCalls = 0;

  @override
  String get id => 'nyaa';

  @override
  int get priority => 0;

  @override
  Future<ProviderBatchResult<VideoResourceCandidate>> search(
    VideoResourceSearchRequest request,
  ) async {
    searchCalls += 1;
    return ProviderBatchResult<VideoResourceCandidate>.success(
      <VideoResourceCandidate>[candidate],
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

class _FakeTorrentBackend implements TorrentPauseBackend {
  _FakeTorrentBackend({
    this.snapshots = const <TorrentSnapshot>[],
    this.files = const <TorrentFileEntry>[],
    bool pauseAdd = false,
  }) : _addGate = pauseAdd ? Completer<bool>() : null;

  final List<TorrentSnapshot> snapshots;
  final List<TorrentFileEntry> files;
  final Completer<bool>? _addGate;
  final Completer<void> addEntered = Completer<void>();
  Future<void> Function()? beforeAdd;
  int prepareCategoryCalls = 0;
  int addCalls = 0;
  int listTorrentsCalls = 0;
  int listFilesCalls = 0;
  int pauseCalls = 0;
  int moveStorageCalls = 0;
  int renameFileCalls = 0;
  final List<String> moveStoragePaths = <String>[];
  final List<String> pausedTorrentIds = <String>[];

  @override
  bool get pauseControlAvailable => true;

  @override
  Future<bool> pauseTorrent(String torrentId) async {
    pauseCalls += 1;
    pausedTorrentIds.add(torrentId);
    return true;
  }

  @override
  Future<bool> resumeTorrent(String torrentId) async => true;

  void releaseAdd([bool accepted = true]) {
    final Completer<bool>? gate = _addGate;
    if (gate != null && !gate.isCompleted) gate.complete(accepted);
  }

  @override
  Future<bool> addTorrent(
    String magnetOrUrl, {
    required String category,
    bool sequential = false,
    bool firstLastPiecePrio = false,
  }) async {
    addCalls += 1;
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
