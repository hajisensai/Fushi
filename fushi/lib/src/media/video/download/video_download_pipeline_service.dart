import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/metadata/credential_redaction.dart';
import 'package:fushi/src/media/torrent/magnet_utils.dart';
import 'package:fushi/src/media/torrent/torrent_add_coordinator.dart';
import 'package:fushi/src/media/torrent/torrent_backend.dart';
import 'package:fushi/src/media/torrent/video_resource_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/download/video_download_backend_identity.dart';
import 'package:fushi/src/media/video/download/video_download_organizer.dart';
import 'package:fushi/src/media/video/download/video_download_path_mapping.dart';
import 'package:fushi/src/media/video/download/video_resource_registry.dart';
import 'package:fushi/src/media/video/download/video_subtitle_registry.dart';
import 'package:fushi/src/media/video/external_video.dart'
    show normalizeVideoPath;
import 'package:fushi/src/media/video/m3u8_playlist.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_coordinator.dart';
import 'package:fushi/src/media/video/metadata/video_source_work_planner.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_filename_parser.dart';
import 'package:fushi/src/media/video/video_sidecar.dart'
    show listSidecarSubtitles;

enum VideoDownloadSubtitlePolicy { none, bestEffort, required }

class VideoDownloadEnqueueRequest {
  const VideoDownloadEnqueueRequest({
    required this.media,
    required this.resource,
    required this.backendIdentity,
    required this.targetSourceId,
    this.subtitlePolicy = VideoDownloadSubtitlePolicy.bestEffort,
    this.priority = 0,
    this.maxAttempts = 6,
    this.coverUrl,
  });

  final VideoMediaReference media;
  final VideoResourceCandidate resource;
  final VideoDownloadBackendIdentity backendIdentity;
  final int targetSourceId;
  final VideoDownloadSubtitlePolicy subtitlePolicy;
  final int priority;
  final int maxAttempts;
  final String? coverUrl;
}

class VideoDownloadBackendBinding {
  VideoDownloadBackendBinding({
    required this.backend,
    required this.identity,
    VideoDownloadPathMapping? pathMapping,
    Iterable<VideoDownloadPathMapping> pathMappings =
        const <VideoDownloadPathMapping>[],
  }) : pathMappings = List<VideoDownloadPathMapping>.unmodifiable(
          <VideoDownloadPathMapping>[
            if (pathMapping != null) pathMapping,
            ...pathMappings,
          ],
        );

  final TorrentBackend backend;
  final VideoDownloadBackendIdentity identity;

  /// Kept for source compatibility with callers that configure one mapping.
  VideoDownloadPathMapping? get pathMapping => pathMappings.firstOrNull;
  final List<VideoDownloadPathMapping> pathMappings;
}

typedef VideoDownloadBackendResolver = Future<VideoDownloadBackendBinding?>
    Function(VideoDownloadJobRow job);

/// Resume ids that remain owned by the v78 pipeline after legacy JSON files
/// have been archived. New library jobs keep completed torrents alive so upload
/// policy, seeding and task metrics continue across restarts. Legacy imports
/// retain their historical terminal-state cleanup contract.
Set<String> legacyEmbeddedTorrentResumeIds(
  Iterable<VideoDownloadJobRow> jobs,
) {
  final Set<String> ids = <String>{};
  for (final VideoDownloadJobRow job in jobs) {
    if (job.backendKind != 'embedded' ||
        job.lifecycle == VideoDownloadJobLifecycle.cancelled ||
        (job.organizationPolicy == 'legacy' &&
            job.lifecycle == VideoDownloadJobLifecycle.completed)) {
      continue;
    }
    for (final String? candidate in <String?>[
      job.backendTaskId,
      job.torrentHash,
    ]) {
      final String normalized = candidate?.trim().toLowerCase() ?? '';
      if (normalized.isNotEmpty) ids.add(normalized);
    }
  }
  return ids;
}

class VideoDownloadPipelineActionRequired implements Exception {
  const VideoDownloadPipelineActionRequired(this.message);

  final String message;

  @override
  String toString() => message;
}

class VideoDownloadLeaseLost implements Exception {
  const VideoDownloadLeaseLost();

  @override
  String toString() => 'video download worker lease was lost';
}

typedef VideoDownloadLeaseRenew = Future<bool> Function();

/// Keeps a claimed database row alive while one external stage is running.
///
/// A renewal failure is deliberately treated as ownership loss, even when it
/// was caused by a transient database error. Continuing an external side
/// effect without a provable claim is less safe than letting the next worker
/// reconcile the persisted stage.
class VideoDownloadLeaseGuard {
  VideoDownloadLeaseGuard({
    required Duration leaseDuration,
    required VideoDownloadLeaseRenew renew,
  })  : _renew = renew,
        _heartbeatInterval = Duration(
          microseconds: leaseDuration.inMicroseconds ~/ 3 > 0
              ? leaseDuration.inMicroseconds ~/ 3
              : 1,
        );

  final VideoDownloadLeaseRenew _renew;
  final Duration _heartbeatInterval;

  Timer? _timer;
  Future<void>? _activeRenewal;
  bool _lost = false;
  bool _released = false;
  bool _stopped = false;

  void start() {
    if (_timer != null || _stopped || _released || _lost) return;
    _timer = Timer.periodic(_heartbeatInterval, (_) => _scheduleRenewal());
  }

  void ensureHeld() {
    if (_lost || _released) throw const VideoDownloadLeaseLost();
  }

  void markLost() {
    if (_released || _stopped) return;
    _lost = true;
    _timer?.cancel();
    _timer = null;
  }

  /// Called only after a successful CAS that intentionally releases the row.
  void markReleased() {
    _released = true;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> stop() async {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    await _activeRenewal;
  }

  void _scheduleRenewal() {
    if (_stopped || _released || _lost || _activeRenewal != null) return;
    late final Future<void> run;
    run = _renewOnce().whenComplete(() {
      if (identical(_activeRenewal, run)) _activeRenewal = null;
    });
    _activeRenewal = run;
    unawaited(run);
  }

  Future<void> _renewOnce() async {
    bool renewed = false;
    try {
      renewed = await _renew();
    } on Object {
      renewed = false;
    }
    if (!renewed && !_released && !_stopped) markLost();
  }
}

/// v78 持久任务执行器。每轮只推进一个阶段，阶段意图和文件级检查点先落 Drift，
/// 再执行后端/网络/文件副作用；进程退出后下一次 claim 从持久 stage 继续。
class VideoDownloadPipelineService {
  VideoDownloadPipelineService({
    required this.database,
    required this.resourceRegistry,
    required this.backendResolver,
    required this.scrapeCoordinator,
    this.subtitleRegistry,
    Iterable<String> preferredSubtitleLanguages = const <String>[],
    String? workerId,
    this.pollInterval = const Duration(seconds: 5),
    this.leaseDuration = const Duration(minutes: 2),
  })  : preferredSubtitleLanguages =
            List<String>.unmodifiable(preferredSubtitleLanguages),
        workerId = workerId ?? 'video-${generateVideoDownloadInstallationId()}',
        _videoRepository = VideoBookRepository(database);

  final FushiDatabase database;
  final VideoResourceRegistry resourceRegistry;
  final VideoSubtitleRegistry? subtitleRegistry;
  final List<String> preferredSubtitleLanguages;
  final VideoDownloadBackendResolver backendResolver;
  final VideoSourceScrapeCoordinator scrapeCoordinator;
  final String workerId;
  final Duration pollInterval;
  final Duration leaseDuration;
  final VideoBookRepository _videoRepository;
  final VideoDownloadOrganizer _organizer = const VideoDownloadOrganizer();

  Timer? _timer;
  bool _running = false;
  bool _disposed = false;
  VideoDownloadLeaseGuard? _activeLease;

  Future<String> enqueue(VideoDownloadEnqueueRequest request) async {
    final MediaSourceRow? source =
        await database.getMediaSourceById(request.targetSourceId);
    _validateManagedSource(source);
    if (request.maxAttempts <= 0) {
      throw ArgumentError.value(request.maxAttempts, 'maxAttempts');
    }
    final int now = DateTime.now().millisecondsSinceEpoch;
    final String jobId = generateVideoDownloadInstallationId();
    await database.upsertVideoDownloadJob(
      VideoDownloadJobsCompanion(
        jobId: Value<String>(jobId),
        resourceProvider: Value<String>(
          persistedVideoResourceProviderId(request.resource),
        ),
        selectedResourceId: Value<String>(request.resource.remoteId),
        resourceTitle: Value<String?>(request.resource.title),
        torrentHash: Value<String?>(request.resource.infoHash?.toLowerCase()),
        metadataProvider: Value<String?>(request.media.providerId),
        externalId: Value<String?>(request.media.mediaId),
        mediaKind: Value<String>(request.media.mediaKind.name),
        discoveryCategory: Value<String?>(request.media.discoveryCategory.name),
        title: Value<String>(request.media.title),
        year: Value<int?>(request.media.year),
        season: Value<int?>(request.media.season),
        coverUrl: Value<String?>(request.coverUrl),
        backendKind: Value<String>(request.backendIdentity.kind),
        backendProfileId: Value<String?>(request.backendIdentity.profileId),
        fingerprint: Value<String>(request.backendIdentity.fingerprint),
        category: Value<String?>(request.backendIdentity.category),
        targetSourceId: Value<int?>(request.targetSourceId),
        organizationPolicy: const Value<String>('library'),
        subtitlePolicy: Value<String>(request.subtitlePolicy.name),
        lifecycle: const Value<String>(VideoDownloadJobLifecycle.active),
        stage: const Value<String>(VideoDownloadJobStage.enqueue),
        priority: Value<int>(request.priority),
        maxAttempts: Value<int>(request.maxAttempts),
        createdAt: Value<int>(now),
        updatedAt: Value<int>(now),
      ),
    );
    wake();
    return jobId;
  }

  /// 把用户在独立字幕搜索中选中的候选附加到仍在执行的任务。这里只持久化来源
  /// 身份，不保存 OpenSubtitles 临时 URL；真正到 subtitle 阶段会重新搜索同一
  /// provider/remote id，再下载并原子安装。
  Future<String> attachSubtitleSelection({
    required String jobId,
    required VideoSubtitleCandidate candidate,
    int? season,
    int? episode,
  }) async {
    final VideoDownloadJobRow? job = await database.getVideoDownloadJob(jobId);
    if (job == null) {
      throw const VideoDownloadPipelineActionRequired(
        'The selected download job no longer exists',
      );
    }
    if (!const <String>{
          VideoDownloadJobStage.enqueue,
          VideoDownloadJobStage.download,
          VideoDownloadJobStage.organize,
          VideoDownloadJobStage.subtitle,
        }.contains(job.stage) ||
        job.lifecycle == VideoDownloadJobLifecycle.completed ||
        job.lifecycle == VideoDownloadJobLifecycle.cancelled ||
        job.lifecycle == VideoDownloadJobLifecycle.failed) {
      throw const VideoDownloadPipelineActionRequired(
        'Subtitles can only be attached before media import begins',
      );
    }
    final int now = DateTime.now().millisecondsSinceEpoch;
    final String selectionKey = sha256.convert(<int>[
      ...candidate.providerId.codeUnits,
      0,
      ...candidate.remoteId.codeUnits,
      0,
      ...'${season ?? ''}:${episode ?? ''}'.codeUnits,
    ]).toString();
    final String subtitleId = '$jobId:manual:$selectionKey';
    await database.upsertVideoDownloadJobSubtitle(
      VideoDownloadJobSubtitlesCompanion(
        subtitleId: Value<String>(subtitleId),
        jobId: Value<String>(jobId),
        provider: Value<String>(candidate.providerId),
        selectedSubtitleId: Value<String?>(candidate.remoteId),
        language: Value<String?>(candidate.language),
        season: Value<int?>(season ?? candidate.season),
        episode: Value<int?>(episode ?? candidate.episode),
        originalFileName: Value<String?>(candidate.fileName),
        status: const Value<String>(VideoDownloadJobSubtitleStatus.pending),
        error: const Value<String?>(null),
        createdAt: Value<int>(now),
        updatedAt: Value<int>(now),
      ),
    );
    if (job.lifecycle == VideoDownloadJobLifecycle.needsAttention) {
      await database.updateVideoDownloadJob(
        jobId,
        VideoDownloadJobsCompanion(
          lifecycle: const Value<String>(VideoDownloadJobLifecycle.active),
          claimedBy: const Value<String?>(null),
          claimExpiresAt: const Value<int?>(null),
          nextAttemptAt: Value<int?>(now),
          lastError: const Value<String?>(null),
          updatedAt: Value<int>(now),
        ),
      );
    }
    wake();
    return subtitleId;
  }

  Future<void> retryJob(String jobId) async {
    final VideoDownloadJobRow? job = await database.getVideoDownloadJob(jobId);
    if (job == null) {
      throw const VideoDownloadPipelineActionRequired(
        'The selected download job no longer exists',
      );
    }
    final bool changed = await database.retryVideoDownloadJobByUser(
      jobId: jobId,
      nowAt: DateTime.now().millisecondsSinceEpoch,
    );
    if (!changed) {
      throw const VideoDownloadPipelineActionRequired(
        'Only failed or actionable download jobs can be retried',
      );
    }
    wake();
  }

  /// Cancels Hibiki's durable workflow without deleting downloaded data.
  /// When the original backend supports user pause, its exact task is paused
  /// before the lifecycle CAS so cancellation never leaves an actively
  /// downloading task behind merely because the UI stopped tracking it.
  Future<void> cancelJob(String jobId) async {
    final VideoDownloadJobRow? job = await database.getVideoDownloadJob(jobId);
    if (job == null) {
      throw const VideoDownloadPipelineActionRequired(
        'The selected download job no longer exists',
      );
    }
    if (job.lifecycle == VideoDownloadJobLifecycle.cancelled) return;
    if (job.lifecycle == VideoDownloadJobLifecycle.completed) {
      throw const VideoDownloadPipelineActionRequired(
        'A completed download job cannot be cancelled',
      );
    }
    final String? backendTaskId = job.backendTaskId?.trim();
    if (backendTaskId?.isNotEmpty == true) {
      final VideoDownloadBackendBinding? binding = await backendResolver(job);
      _validateBackendBinding(job, binding);
      final TorrentBackend backend = binding!.backend;
      if (backend is TorrentPauseBackend && backend.pauseControlAvailable) {
        final bool paused = await backend.pauseTorrent(backendTaskId!);
        if (!paused) {
          throw const VideoDownloadPipelineActionRequired(
            'The original download backend could not pause this task',
          );
        }
      }
    }
    final bool changed = await database.cancelVideoDownloadJobByUser(
      jobId: jobId,
      nowAt: DateTime.now().millisecondsSinceEpoch,
    );
    if (!changed) {
      final VideoDownloadJobRow? current =
          await database.getVideoDownloadJob(jobId);
      if (current?.lifecycle == VideoDownloadJobLifecycle.cancelled) return;
      throw const VideoDownloadPipelineActionRequired(
        'The download job changed while it was being cancelled',
      );
    }
  }

  /// 读取任务页所需的真实后端快照。
  ///
  /// 按后端身份与分类分组，每组只列一次 torrent；返回值以持久任务 id 为键。
  /// 已完成但仍在做种的任务也会被观察，所以任务页能继续显示上传速度、节点与
  /// 分享率。配置已切换或后端不可用的组安全降级为空，由 UI 显示未知值。
  Future<Map<String, TorrentSnapshot>> loadTaskSnapshots(
    Iterable<VideoDownloadJobRow> jobs,
  ) async {
    final Map<String, List<VideoDownloadJobRow>> groups =
        <String, List<VideoDownloadJobRow>>{};
    for (final VideoDownloadJobRow job in jobs) {
      final String torrentId =
          (job.backendTaskId ?? job.torrentHash ?? '').trim().toLowerCase();
      if (torrentId.isEmpty) continue;
      final String key = <String?>[
        job.backendKind,
        job.backendProfileId,
        job.fingerprint,
        job.category,
      ].map((String? value) => value ?? '').join('\u0000');
      groups.putIfAbsent(key, () => <VideoDownloadJobRow>[]).add(job);
    }

    final Map<String, TorrentSnapshot> result = <String, TorrentSnapshot>{};
    for (final List<VideoDownloadJobRow> group in groups.values) {
      final VideoDownloadJobRow first = group.first;
      try {
        final VideoDownloadBackendBinding? binding =
            await backendResolver(first);
        _validateBackendBinding(first, binding);
        final List<TorrentSnapshot> snapshots =
            await binding!.backend.listTorrents(category: first.category);
        final Map<String, TorrentSnapshot> byHash = <String, TorrentSnapshot>{
          for (final TorrentSnapshot snapshot in snapshots)
            snapshot.hash.toLowerCase(): snapshot,
        };
        for (final VideoDownloadJobRow job in group) {
          final String torrentId =
              (job.backendTaskId ?? job.torrentHash ?? '').trim().toLowerCase();
          final TorrentSnapshot? snapshot = byHash[torrentId];
          if (snapshot != null) result[job.jobId] = snapshot;
        }
      } on Object {
        // 指标是增强信息；后端暂不可读不能让持久任务列表一起消失。
      }
    }
    return Map<String, TorrentSnapshot>.unmodifiable(result);
  }

  void start() {
    if (_disposed || _timer != null) return;
    wake();
    _timer = Timer.periodic(pollInterval, (_) => wake());
  }

  void wake() {
    if (_disposed || _running) return;
    _running = true;
    unawaited(_drain().whenComplete(() => _running = false));
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    while (_running) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await stop();
  }

  Future<void> _drain() async {
    for (int processed = 0; processed < 8 && !_disposed; processed++) {
      final int now = DateTime.now().millisecondsSinceEpoch;
      final VideoDownloadJobRow? job = await database.claimNextVideoDownloadJob(
        workerId: workerId,
        nowAt: now,
        leaseDurationMs: leaseDuration.inMilliseconds,
      );
      if (job == null) return;
      await _process(job);
    }
  }

  Future<void> _process(VideoDownloadJobRow job) async {
    final VideoDownloadLeaseGuard lease = VideoDownloadLeaseGuard(
      leaseDuration: leaseDuration,
      renew: () => database.renewVideoDownloadJobClaim(
        jobId: job.jobId,
        workerId: workerId,
        nowAt: DateTime.now().millisecondsSinceEpoch,
        leaseDurationMs: leaseDuration.inMilliseconds,
      ),
    );
    _activeLease = lease;
    lease.start();
    try {
      await _processWithLease(job);
    } on VideoDownloadLeaseLost {
      // Another worker (or a user lifecycle action) owns the row now. The
      // persisted stage is the only safe place from which to continue.
    } finally {
      if (identical(_activeLease, lease)) _activeLease = null;
      await lease.stop();
    }
  }

  Future<void> _processWithLease(VideoDownloadJobRow job) async {
    try {
      switch (job.stage) {
        case VideoDownloadJobStage.enqueue:
          await _enqueueTorrent(job);
        case VideoDownloadJobStage.download:
          await _observeDownload(job);
        case VideoDownloadJobStage.organize:
          await _organizeDownload(job);
        case VideoDownloadJobStage.subtitle:
          await _installSubtitles(job);
        case VideoDownloadJobStage.import:
          await _importMedia(job);
        case VideoDownloadJobStage.scrape:
          await _scrapeMedia(job);
        default:
          throw VideoDownloadPipelineActionRequired(
            'Unknown download stage: ${job.stage}',
          );
      }
    } on VideoDownloadPipelineActionRequired catch (error) {
      await _markNeedsAttention(job, _safeError(error.message));
    } on Object catch (error) {
      _ensureLeaseHeld();
      final bool retryable =
          error is! ExternalProviderFailure || error.retryable;
      final int now = DateTime.now().millisecondsSinceEpoch;
      if (job.stage == VideoDownloadJobStage.scrape || !retryable) {
        await _markNeedsAttention(
          job,
          _safeError(error.toString()),
          nowAt: now,
        );
        return;
      }
      final int exponent = job.attemptCount.clamp(0, 6);
      final int delaySeconds = 5 * (1 << exponent);
      await _releaseLeaseWith(
        () => database.retryVideoDownloadJob(
          jobId: job.jobId,
          workerId: workerId,
          error: _safeError(error.toString()),
          nowAt: now,
          nextAttemptAt: now + Duration(seconds: delaySeconds).inMilliseconds,
        ),
      );
    }
  }

  Future<VideoDownloadBackendBinding> _binding(
    VideoDownloadJobRow job,
  ) async {
    _ensureLeaseHeld();
    final VideoDownloadBackendBinding? binding = await backendResolver(job);
    _ensureLeaseHeld();
    _validateBackendBinding(job, binding);
    return binding!;
  }

  static void _validateBackendBinding(
    VideoDownloadJobRow job,
    VideoDownloadBackendBinding? binding,
  ) {
    if (binding == null) {
      throw const VideoDownloadPipelineActionRequired(
        'The original download backend is not configured on this device',
      );
    }
    final VideoDownloadBackendIdentity current = binding.identity;
    if (current.kind != job.backendKind ||
        current.profileId != job.backendProfileId ||
        current.fingerprint != job.fingerprint ||
        current.category != (job.category ?? '')) {
      throw const VideoDownloadPipelineActionRequired(
        'The backend instance, profile, or category no longer matches this job',
      );
    }
  }

  Future<void> _enqueueTorrent(VideoDownloadJobRow job) async {
    _ensureLeaseHeld();
    final VideoDownloadBackendBinding binding = await _binding(job);
    final String category = job.category ?? '';
    if (category.isEmpty || !await binding.backend.prepareCategory(category)) {
      throw StateError('download category is unavailable');
    }
    _ensureLeaseHeld();
    final TorrentAddPayload payload = await _resolvePayload(job);
    _ensureLeaseHeld();
    final String? hash = (payload.torrentId ?? job.torrentHash)?.toLowerCase();
    if (hash == null || hash.isEmpty) {
      throw const VideoDownloadPipelineActionRequired(
        'The selected torrent has no verifiable info hash',
      );
    }
    final VideoDownloadJobRow? duplicate =
        await database.findVideoDownloadJobByFingerprintAndTorrentHash(
      job.fingerprint,
      hash,
    );
    if (duplicate != null && duplicate.jobId != job.jobId) {
      throw VideoDownloadPipelineActionRequired(
        'This torrent is already managed by job ${duplicate.jobId}',
      );
    }
    // Persist the exact hash before the enqueue side effect.
    await database.updateVideoDownloadJob(
      job.jobId,
      VideoDownloadJobsCompanion(torrentHash: Value<String?>(hash)),
    );
    _ensureLeaseHeld();
    final bool added = await TorrentAddCoordinator(binding.backend).add(
      payload,
      category: category,
    );
    _ensureLeaseHeld();
    if (!added) {
      final List<TorrentSnapshot> current =
          await binding.backend.listTorrents(category: category);
      _ensureLeaseHeld();
      if (!current.any(
        (TorrentSnapshot value) => value.hash.toLowerCase() == hash,
      )) {
        throw StateError('download backend rejected the torrent');
      }
    }
    await _advance(
      job,
      VideoDownloadJobStage.download,
      backendTaskId: hash,
      torrentHash: hash,
    );
  }

  Future<TorrentAddPayload> _resolvePayload(VideoDownloadJobRow job) {
    final String? magnet = job.magnetUri;
    if (magnet != null && magnet.isNotEmpty) {
      return Future<TorrentAddPayload>.value(
        TorrentMagnetPayload(
          magnetUri: magnet,
          torrentId: parseMagnetInfoHash(magnet) ?? job.torrentHash,
        ),
      );
    }
    return resourceRegistry.resolveSelection(
      selection: VideoResourceSelection(
        providerId: job.resourceProvider,
        remoteId: job.selectedResourceId,
        title: job.resourceTitle ?? job.title,
      ),
      request: VideoResourceSearchRequest(
        media: _mediaReference(job),
        query: job.resourceTitle ?? job.title,
        season: job.season,
      ),
    );
  }

  Future<void> _observeDownload(VideoDownloadJobRow job) async {
    _ensureLeaseHeld();
    final VideoDownloadBackendBinding binding = await _binding(job);
    final String hash = job.backendTaskId ?? job.torrentHash ?? '';
    if (hash.isEmpty) {
      throw const VideoDownloadPipelineActionRequired(
        'The backend torrent id is missing',
      );
    }
    final List<TorrentSnapshot> snapshots = await binding.backend.listTorrents(
      category: job.category,
    );
    _ensureLeaseHeld();
    TorrentSnapshot? snapshot;
    for (final TorrentSnapshot value in snapshots) {
      if (value.hash.toLowerCase() == hash.toLowerCase()) {
        snapshot = value;
        break;
      }
    }
    if (snapshot == null) {
      throw StateError('torrent is not visible in the original backend');
    }
    if (snapshot.isFailure) {
      throw VideoDownloadPipelineActionRequired(
        'The download backend reported ${snapshot.state}',
      );
    }
    if (!snapshot.isComplete) {
      final int now = DateTime.now().millisecondsSinceEpoch;
      _ensureLeaseHeld();
      await database.updateVideoDownloadJob(
        job.jobId,
        VideoDownloadJobsCompanion(
          stageProgress: Value<double>(snapshot.progress.clamp(0, 1)),
          observedSavePath: Value<String?>(snapshot.savePath),
          updatedAt: Value<int>(now),
        ),
      );
      _ensureLeaseHeld();
      await _releaseLeaseWith(
        () => database.releaseVideoDownloadJobClaim(
          jobId: job.jobId,
          workerId: workerId,
          nowAt: now,
          nextAttemptAt: now + pollInterval.inMilliseconds,
        ),
      );
      return;
    }
    final List<TorrentFileEntry> files = await binding.backend.listFiles(hash);
    _ensureLeaseHeld();
    if (files.isEmpty) throw StateError('download has no visible files');
    await _ensureDownloadedFileRows(job, files);
    await _advance(
      job,
      VideoDownloadJobStage.organize,
      observedSavePath: snapshot.savePath,
    );
  }

  Future<void> _ensureDownloadedFileRows(
    VideoDownloadJobRow job,
    List<TorrentFileEntry> files,
  ) async {
    _ensureLeaseHeld();
    final List<VideoDownloadJobFileRow> existing =
        await database.getVideoDownloadJobFiles(job.jobId);
    final Map<int, VideoDownloadJobFileRow> byIndex =
        <int, VideoDownloadJobFileRow>{
      for (final VideoDownloadJobFileRow row in existing)
        if (row.backendFileIndex != null) row.backendFileIndex!: row,
    };
    final int now = DateTime.now().millisecondsSinceEpoch;
    for (final TorrentFileEntry file in files) {
      _ensureLeaseHeld();
      final VideoDownloadJobFileRow? row = byIndex[file.index];
      if (row != null) {
        await database.updateVideoDownloadJobFile(
          row.id,
          VideoDownloadJobFilesCompanion(
            currentRelativePath: Value<String>(file.name),
            sizeBytes: Value<int?>(file.size),
            status: const Value<String>(VideoDownloadJobFileStatus.downloaded),
            updatedAt: Value<int>(now),
          ),
        );
        continue;
      }
      await database.upsertVideoDownloadJobFile(
        VideoDownloadJobFilesCompanion(
          jobId: Value<String>(job.jobId),
          backendFileIndex: Value<int?>(file.index),
          originalRelativePath: Value<String>(file.name),
          currentRelativePath: Value<String>(file.name),
          kind: const Value<String>('other'),
          sizeBytes: Value<int?>(file.size),
          status: const Value<String>(VideoDownloadJobFileStatus.downloaded),
          createdAt: Value<int>(now),
          updatedAt: Value<int>(now),
        ),
      );
    }
  }

  Future<void> _organizeDownload(VideoDownloadJobRow job) async {
    _ensureLeaseHeld();
    if (job.organizationPolicy == 'legacy') {
      await _reconcileLegacyDownload(job);
      return;
    }
    final MediaSourceRow source = await _managedSource(job);
    final VideoDownloadBackendBinding binding = await _binding(job);
    final String hash = job.backendTaskId ?? job.torrentHash ?? '';
    if (hash.isEmpty) {
      throw const VideoDownloadPipelineActionRequired('Torrent id is missing');
    }
    List<VideoDownloadJobFileRow> rows =
        await database.getVideoDownloadJobFiles(job.jobId);
    if (await _organizedFilesExist(rows)) {
      await _markFilesOrganized(rows);
      await _advanceToSubtitle(job, rows);
      return;
    }
    final List<VideoDownloadPathMapping> mappings = _effectivePathMappings(
      binding,
      observedSavePath: job.observedSavePath,
      sourceRoot: source.rootPath,
    );
    await _validateObservedSavePath(job, mappings);
    final VideoDownloadPathMapping mapping = _mappingForLocalPath(
          mappings,
          source.rootPath,
        ) ??
        (throw const VideoDownloadPipelineActionRequired(
          'The managed video source is outside every backend path mapping',
        ));
    final VideoOrganizationRequest request = VideoOrganizationRequest(
      torrentId: hash,
      title: job.title,
      year: job.year,
      kind: job.mediaKind == VideoMetadataMediaKind.movie.name
          ? VideoOrganizationKind.movie
          : VideoOrganizationKind.episodic,
      defaultSeasonNumber: job.season ?? 1,
      sourceRoot: source.rootPath,
      pathMapping: mapping,
    );
    final List<TorrentFileEntry> backendFiles =
        await binding.backend.listFiles(hash);
    _ensureLeaseHeld();
    final VideoOrganizationPlan planned;
    try {
      planned = _organizer.plan(request, backendFiles);
    } on FormatException catch (error) {
      throw VideoDownloadPipelineActionRequired(error.message.toString());
    }
    await _persistOrganizationIntent(job, planned, backendFiles);
    _ensureLeaseHeld();
    final VideoOrganizationResult result = await _organizer.organize(
      backend: binding.backend,
      request: request,
      onFileCommitted: (VideoOrganizationFilePlan file) async {
        _ensureLeaseHeld();
        final VideoDownloadJobFileRow? row =
            await _jobFileByIndex(job.jobId, file.backendFileIndex);
        if (row == null) return;
        await database.updateVideoDownloadJobFile(
          row.id,
          VideoDownloadJobFilesCompanion(
            currentRelativePath: Value<String>(file.targetRelativePath),
            targetRelativePath: Value<String?>(file.targetRelativePath),
            finalAbsolutePath: Value<String?>(file.finalLocalPath),
            season: Value<int?>(file.seasonNumber),
            episode: Value<int?>(file.episodeNumber),
            updatedAt: Value<int>(DateTime.now().millisecondsSinceEpoch),
          ),
        );
      },
    );
    _ensureLeaseHeld();
    if (!result.ok) {
      throw VideoDownloadPipelineActionRequired(
        result.error ?? 'Backend organization failed',
      );
    }
    rows = await database.getVideoDownloadJobFiles(job.jobId);
    await _markFilesOrganized(rows);
    await _advanceToSubtitle(job, rows);
  }

  /// Reconciles a pre-v78 plan against its original backend location. Legacy
  /// plans deliberately never rename files or move torrent storage: the old
  /// JSON workflow imported in-place and could be seeding from arbitrary
  /// paths outside a managed source.
  Future<void> _reconcileLegacyDownload(VideoDownloadJobRow job) async {
    final VideoDownloadBackendBinding binding = await _binding(job);
    final String hash = job.backendTaskId ?? job.torrentHash ?? '';
    if (hash.isEmpty) {
      throw const VideoDownloadPipelineActionRequired('Torrent id is missing');
    }
    final List<VideoDownloadPathMapping> mappings = _effectivePathMappings(
      binding,
      observedSavePath: job.observedSavePath,
    );
    final ({VideoDownloadPathMapping mapping, String localPath}) saveRoot =
        await _validateObservedSavePath(job, mappings);
    final List<TorrentFileEntry> backendFiles =
        await binding.backend.listFiles(hash);
    _ensureLeaseHeld();
    if (backendFiles.isEmpty) {
      throw const VideoDownloadPipelineActionRequired(
        'The legacy torrent has no visible files',
      );
    }
    await _ensureDownloadedFileRows(job, backendFiles);
    final Map<int, TorrentFileEntry> byIndex = <int, TorrentFileEntry>{
      for (final TorrentFileEntry file in backendFiles) file.index: file,
    };
    final List<VideoDownloadJobFileRow> rows =
        await database.getVideoDownloadJobFiles(job.jobId);
    int videoCount = 0;
    final int now = DateTime.now().millisecondsSinceEpoch;
    for (final VideoDownloadJobFileRow row in rows) {
      _ensureLeaseHeld();
      final TorrentFileEntry? backendFile =
          row.backendFileIndex == null ? null : byIndex[row.backendFileIndex!];
      if (backendFile == null) continue;
      final String? absolutePath = _resolveBackendFileLocalPath(
        remoteSavePath: job.observedSavePath!,
        relativePath: backendFile.name,
        mapping: saveRoot.mapping,
        localSaveRoot: saveRoot.localPath,
      );
      if (absolutePath == null) {
        throw VideoDownloadPipelineActionRequired(
          'Legacy backend file is outside the observed save path: '
          '${backendFile.name}',
        );
      }
      final File localFile = File(absolutePath);
      if (!await localFile.exists()) {
        throw VideoDownloadPipelineActionRequired(
          'Legacy backend file is not accessible on this device: '
          '${backendFile.name}',
        );
      }
      if (backendFile.size > 0 &&
          await localFile.length() != backendFile.size) {
        throw VideoDownloadPipelineActionRequired(
          'Legacy backend file size does not match: ${backendFile.name}',
        );
      }
      final bool isVideo = _isVideoFile(backendFile.name);
      final VideoNameInfo parsed =
          parseVideoFilename(p.basename(backendFile.name));
      await database.updateVideoDownloadJobFile(
        row.id,
        VideoDownloadJobFilesCompanion(
          currentRelativePath: Value<String>(backendFile.name),
          finalAbsolutePath: Value<String?>(absolutePath),
          kind: Value<String>(isVideo ? 'video' : 'other'),
          season: Value<int?>(parsed.season),
          episode: Value<int?>(parsed.episode),
          sizeBytes: Value<int?>(backendFile.size),
          status: Value<String>(isVideo
              ? VideoDownloadJobFileStatus.organized
              : VideoDownloadJobFileStatus.skipped),
          error: const Value<String?>(null),
          updatedAt: Value<int>(now),
        ),
      );
      if (isVideo) videoCount++;
    }
    if (videoCount == 0) {
      throw const VideoDownloadPipelineActionRequired(
        'The legacy torrent has no supported video files',
      );
    }
    await _advance(job, VideoDownloadJobStage.subtitle);
  }

  Future<void> _persistOrganizationIntent(
    VideoDownloadJobRow job,
    VideoOrganizationPlan plan,
    List<TorrentFileEntry> backendFiles,
  ) async {
    _ensureLeaseHeld();
    final Map<int, TorrentFileEntry> files = <int, TorrentFileEntry>{
      for (final TorrentFileEntry file in backendFiles) file.index: file,
    };
    final int now = DateTime.now().millisecondsSinceEpoch;
    for (final VideoOrganizationFilePlan file in plan.files) {
      _ensureLeaseHeld();
      final VideoDownloadJobFileRow? row =
          await _jobFileByIndex(job.jobId, file.backendFileIndex);
      if (row == null) continue;
      await database.updateVideoDownloadJobFile(
        row.id,
        VideoDownloadJobFilesCompanion(
          targetRelativePath: Value<String?>(file.targetRelativePath),
          finalAbsolutePath: Value<String?>(file.finalLocalPath),
          kind: Value<String>(
            file.targetRelativePath.contains('/Extras/') ? 'extra' : 'video',
          ),
          season: Value<int?>(file.seasonNumber),
          episode: Value<int?>(file.episodeNumber),
          sizeBytes: Value<int?>(files[file.backendFileIndex]?.size),
          updatedAt: Value<int>(now),
        ),
      );
    }
  }

  Future<void> _advanceToSubtitle(
    VideoDownloadJobRow job,
    List<VideoDownloadJobFileRow> rows,
  ) async {
    String? root;
    for (final VideoDownloadJobFileRow row in rows) {
      final String? relative = row.targetRelativePath;
      if (relative != null && relative.contains('/')) {
        root = relative.substring(0, relative.indexOf('/'));
        break;
      }
    }
    await _advance(
      job,
      VideoDownloadJobStage.subtitle,
      targetRelativeRoot: root,
    );
  }

  Future<bool> _organizedFilesExist(
    List<VideoDownloadJobFileRow> rows,
  ) async {
    final List<VideoDownloadJobFileRow> planned = rows
        .where((VideoDownloadJobFileRow row) =>
            row.finalAbsolutePath != null && row.targetRelativePath != null)
        .toList();
    if (planned.isEmpty) return false;
    for (final VideoDownloadJobFileRow row in planned) {
      final File file = File(row.finalAbsolutePath!);
      if (!await file.exists()) return false;
      if (row.sizeBytes != null && await file.length() != row.sizeBytes) {
        return false;
      }
    }
    return true;
  }

  Future<void> _markFilesOrganized(
    List<VideoDownloadJobFileRow> rows,
  ) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    for (final VideoDownloadJobFileRow row in rows) {
      _ensureLeaseHeld();
      if (row.finalAbsolutePath == null) continue;
      await database.updateVideoDownloadJobFile(
        row.id,
        VideoDownloadJobFilesCompanion(
          status: const Value<String>(VideoDownloadJobFileStatus.organized),
          updatedAt: Value<int>(now),
        ),
      );
    }
  }

  Future<void> _installSubtitles(VideoDownloadJobRow job) async {
    _ensureLeaseHeld();
    if (job.organizationPolicy == 'legacy') {
      await _installLegacyStagedSubtitles(job);
      return;
    }
    final VideoDownloadSubtitlePolicy policy =
        VideoDownloadSubtitlePolicy.values.asNameMap()[job.subtitlePolicy] ??
            VideoDownloadSubtitlePolicy.bestEffort;
    if (policy == VideoDownloadSubtitlePolicy.none) {
      await _advance(job, VideoDownloadJobStage.import);
      return;
    }
    if (subtitleRegistry == null) {
      if (policy == VideoDownloadSubtitlePolicy.required) {
        throw const VideoDownloadPipelineActionRequired(
          'Required subtitles are not configured on this device',
        );
      }
      await _advance(job, VideoDownloadJobStage.import);
      return;
    }
    final List<VideoDownloadJobFileRow> files =
        (await database.getVideoDownloadJobFiles(job.jobId))
            .where((VideoDownloadJobFileRow row) =>
                row.kind == 'video' && row.finalAbsolutePath != null)
            .toList();
    bool anyInstalled = false;
    for (final VideoDownloadJobFileRow file in files) {
      final List<VideoDownloadJobSubtitleRow> existing =
          await database.getVideoDownloadJobSubtitles(job.jobId);
      final VideoDownloadJobSubtitleRow? prior = existing
          .where((VideoDownloadJobSubtitleRow row) =>
              row.jobFileId == file.id &&
              row.status == VideoDownloadJobSubtitleStatus.placed)
          .firstOrNull;
      if (prior?.status == VideoDownloadJobSubtitleStatus.placed &&
          prior?.finalPath != null &&
          await File(prior!.finalPath!).exists()) {
        anyInstalled = true;
        continue;
      }
      final VideoDownloadJobSubtitleRow? resolving = existing
          .where((VideoDownloadJobSubtitleRow row) =>
              row.jobFileId == file.id &&
              row.selectedSubtitleId != null &&
              row.status == VideoDownloadJobSubtitleStatus.resolving)
          .firstOrNull;
      final VideoDownloadJobSubtitleRow? manual = existing
          .where((VideoDownloadJobSubtitleRow row) =>
              row.jobFileId == null &&
              row.selectedSubtitleId != null &&
              row.status == VideoDownloadJobSubtitleStatus.pending &&
              (row.season == null || row.season == file.season) &&
              (row.episode == null || row.episode == file.episode))
          .firstOrNull;
      // A resolving row is the durable choice made before the previous
      // download/write side effect. Re-resolve that exact provider item after
      // a restart instead of choosing a possibly different first result.
      final VideoDownloadJobSubtitleRow? persistedSelection =
          manual ?? resolving;
      final String subtitleId =
          persistedSelection?.subtitleId ?? '${job.jobId}:${file.id}';
      try {
        final File video = File(file.finalAbsolutePath!);
        final ProviderBatchResult<VideoSubtitleCandidate> result =
            await subtitleRegistry!.search(
          VideoSubtitleSearchRequest(
            media: _mediaReference(job).copyWithEpisode(
              season: file.season,
              episode: file.episode,
            ),
            season: file.season,
            episode: file.episode,
            languages: preferredSubtitleLanguages,
            fingerprint: LocalVideoFingerprint(
              fileSize: await video.length(),
              fileName: p.basename(video.path),
              openSubtitlesMovieHash:
                  await computeOpenSubtitlesMovieHash(video.path),
            ),
          ),
        );
        _ensureLeaseHeld();
        if (result.items.isEmpty) {
          final String message = result.failures.isEmpty
              ? 'No matching subtitle was found'
              : result.failures.first.message;
          await _recordUnavailableSubtitle(
            job,
            file,
            subtitleId,
            message,
          );
          if (policy == VideoDownloadSubtitlePolicy.required) {
            throw VideoDownloadPipelineActionRequired(message);
          }
          continue;
        }
        VideoSubtitleCandidate? candidate;
        if (persistedSelection != null) {
          for (final VideoSubtitleCandidate value in result.items) {
            if (value.providerId == persistedSelection.provider &&
                value.remoteId == persistedSelection.selectedSubtitleId) {
              candidate = value;
              break;
            }
          }
          if (candidate == null) {
            final String message = result.failures.isEmpty
                ? 'The selected subtitle is no longer available'
                : result.failures.first.message;
            await _recordUnavailableSubtitle(
              job,
              file,
              subtitleId,
              message,
              existingSelection: persistedSelection,
            );
            throw VideoDownloadPipelineActionRequired(message);
          }
        } else {
          candidate = result.items.first;
        }
        final String extension = _safeSubtitleExtension(candidate.fileName);
        final String language = candidate.language.trim().isEmpty
            ? 'und'
            : candidate.language.trim().toLowerCase();
        final String initialTarget = p.join(
          p.dirname(video.path),
          '${p.basenameWithoutExtension(video.path)}.$language$extension',
        );
        final int now = DateTime.now().millisecondsSinceEpoch;
        final String initialTempPath = '$initialTarget.${job.jobId}.fushi.tmp';
        // Persist the selected remote identity before downloading its temporary
        // payload. OpenSubtitles/Jimaku URLs themselves are never persisted.
        await database.upsertVideoDownloadJobSubtitle(
          VideoDownloadJobSubtitlesCompanion(
            subtitleId: Value<String>(subtitleId),
            jobId: Value<String>(job.jobId),
            jobFileId: Value<int?>(file.id),
            provider: Value<String>(candidate.providerId),
            selectedSubtitleId: Value<String?>(candidate.remoteId),
            language: Value<String?>(language),
            season: Value<int?>(file.season),
            episode: Value<int?>(file.episode),
            originalFileName: Value<String?>(candidate.fileName),
            stagedPath: Value<String?>(initialTempPath),
            finalPath: Value<String?>(initialTarget),
            status: const Value<String>(
              VideoDownloadJobSubtitleStatus.resolving,
            ),
            createdAt: Value<int>(persistedSelection?.createdAt ?? now),
            updatedAt: Value<int>(now),
          ),
        );
        final VideoSubtitleDownload download =
            await subtitleRegistry!.download(candidate);
        _ensureLeaseHeld();
        final String selectedTarget = await _selectSidecarTarget(
          bytes: download.bytes,
          initialTarget: initialTarget,
        );
        final String tempPath = '$selectedTarget.${job.jobId}.fushi.tmp';
        // The exact conflict-free destination is another durable intent. If
        // the process exits after rename but before `placed`, the next run
        // downloads the same selected item, verifies content at this path and
        // adopts it without creating a second sidecar.
        await database.updateVideoDownloadJobSubtitle(
          subtitleId,
          VideoDownloadJobSubtitlesCompanion(
            stagedPath: Value<String?>(tempPath),
            finalPath: Value<String?>(selectedTarget),
            updatedAt: Value<int>(DateTime.now().millisecondsSinceEpoch),
          ),
        );
        _ensureLeaseHeld();
        final String installed = await _installSidecarAtTargetAtomically(
          bytes: download.bytes,
          target: selectedTarget,
          tempPath: tempPath,
        );
        _ensureLeaseHeld();
        await database.updateVideoDownloadJobSubtitle(
          subtitleId,
          VideoDownloadJobSubtitlesCompanion(
            stagedPath: const Value<String?>(null),
            finalPath: Value<String?>(installed),
            status: const Value<String>(
              VideoDownloadJobSubtitleStatus.placed,
            ),
            error: const Value<String?>(null),
            updatedAt: Value<int>(DateTime.now().millisecondsSinceEpoch),
          ),
        );
        anyInstalled = true;
      } on VideoDownloadPipelineActionRequired {
        rethrow;
      } on Object catch (error) {
        await _recordUnavailableSubtitle(
          job,
          file,
          subtitleId,
          _safeError(error.toString()),
          existingSelection: persistedSelection,
        );
        if (policy == VideoDownloadSubtitlePolicy.required) rethrow;
      }
    }
    if (policy == VideoDownloadSubtitlePolicy.required && !anyInstalled) {
      throw const VideoDownloadPipelineActionRequired(
        'Required subtitles could not be installed',
      );
    }
    await _advance(job, VideoDownloadJobStage.import);
  }

  /// Copies old JSON-plan subtitle staging files without consuming them.
  /// This mirrors the pre-v78 workflow: a video that already has any sidecar
  /// is left untouched, because that sidecar may have been placed or edited by
  /// the user outside Hibiki.
  Future<void> _installLegacyStagedSubtitles(
    VideoDownloadJobRow job,
  ) async {
    final VideoDownloadSubtitlePolicy policy =
        VideoDownloadSubtitlePolicy.values.asNameMap()[job.subtitlePolicy] ??
            VideoDownloadSubtitlePolicy.bestEffort;
    if (policy == VideoDownloadSubtitlePolicy.none) {
      await _advance(job, VideoDownloadJobStage.import);
      return;
    }
    final List<VideoDownloadJobFileRow> videos = (await database
            .getVideoDownloadJobFiles(job.jobId))
        .where((VideoDownloadJobFileRow row) =>
            row.kind == 'video' && row.finalAbsolutePath != null)
        .toList()
      ..sort(_compareJobFiles);
    final List<VideoDownloadJobSubtitleRow> subtitles =
        await database.getVideoDownloadJobSubtitles(job.jobId);
    bool installed = false;
    for (final VideoDownloadJobSubtitleRow subtitle in subtitles) {
      _ensureLeaseHeld();
      if (subtitle.status == VideoDownloadJobSubtitleStatus.placed &&
          subtitle.finalPath != null &&
          await File(subtitle.finalPath!).exists()) {
        installed = true;
        continue;
      }
      if (subtitle.status == VideoDownloadJobSubtitleStatus.skipped) continue;
      final VideoDownloadJobFileRow? video = _matchLegacySubtitleVideo(
        subtitle,
        videos,
      );
      final String? stagedPath = subtitle.stagedPath;
      if (video == null || stagedPath == null || stagedPath.trim().isEmpty) {
        await _markLegacySubtitleUnavailable(
          subtitle,
          video,
          'Legacy subtitle could not be paired to a video file',
        );
        if (policy == VideoDownloadSubtitlePolicy.required) {
          throw const VideoDownloadPipelineActionRequired(
            'A required legacy subtitle could not be paired to a video file',
          );
        }
        continue;
      }
      final File staged = File(stagedPath);
      if (!await staged.exists()) {
        await _markLegacySubtitleUnavailable(
          subtitle,
          video,
          'Legacy subtitle staging file is no longer accessible',
        );
        if (policy == VideoDownloadSubtitlePolicy.required) {
          throw const VideoDownloadPipelineActionRequired(
            'A required legacy subtitle staging file is unavailable',
          );
        }
        continue;
      }
      final String videoPath = video.finalAbsolutePath!;
      final String? existingSidecar = await _firstSidecarPath(videoPath);
      if (existingSidecar != null) {
        final bool sameContent = await _filesHaveSameContent(
          staged,
          File(existingSidecar),
        );
        await database.updateVideoDownloadJobSubtitle(
          subtitle.subtitleId,
          VideoDownloadJobSubtitlesCompanion(
            jobFileId: Value<int?>(video.id),
            finalPath: Value<String?>(sameContent ? existingSidecar : null),
            status: Value<String>(sameContent
                ? VideoDownloadJobSubtitleStatus.placed
                : VideoDownloadJobSubtitleStatus.skipped),
            error: Value<String?>(sameContent
                ? null
                : 'A sidecar already exists; the legacy staging file was kept'),
            updatedAt: Value<int>(DateTime.now().millisecondsSinceEpoch),
          ),
        );
        if (sameContent) installed = true;
        continue;
      }
      final String extension = _safeSubtitleExtension(
        subtitle.originalFileName ?? stagedPath,
      );
      final String language = subtitle.language?.trim() ?? '';
      final String languageSegment = language.isEmpty ? '' : '.$language';
      final String targetPath = p.join(
        p.dirname(videoPath),
        '${p.basenameWithoutExtension(videoPath)}$languageSegment$extension',
      );
      final File target = File(targetPath);
      if (await target.exists()) {
        await database.updateVideoDownloadJobSubtitle(
          subtitle.subtitleId,
          VideoDownloadJobSubtitlesCompanion(
            jobFileId: Value<int?>(video.id),
            status: const Value<String>(
              VideoDownloadJobSubtitleStatus.skipped,
            ),
            error: const Value<String?>(
              'The subtitle target already exists; nothing was overwritten',
            ),
            updatedAt: Value<int>(DateTime.now().millisecondsSinceEpoch),
          ),
        );
        continue;
      }
      final String tempPath = '$targetPath.${job.jobId}.legacy-copy.tmp';
      final File temp = File(tempPath);
      if (await temp.exists()) await temp.delete();
      await target.parent.create(recursive: true);
      await staged.copy(temp.path);
      _ensureLeaseHeld();
      if (await target.exists()) {
        await temp.delete();
        await database.updateVideoDownloadJobSubtitle(
          subtitle.subtitleId,
          VideoDownloadJobSubtitlesCompanion(
            jobFileId: Value<int?>(video.id),
            status: const Value<String>(
              VideoDownloadJobSubtitleStatus.skipped,
            ),
            error: const Value<String?>(
              'The subtitle target changed while copying; nothing was overwritten',
            ),
            updatedAt: Value<int>(DateTime.now().millisecondsSinceEpoch),
          ),
        );
        continue;
      }
      await temp.rename(target.path);
      await database.updateVideoDownloadJobSubtitle(
        subtitle.subtitleId,
        VideoDownloadJobSubtitlesCompanion(
          jobFileId: Value<int?>(video.id),
          finalPath: Value<String?>(target.path),
          status: const Value<String>(VideoDownloadJobSubtitleStatus.placed),
          error: const Value<String?>(null),
          updatedAt: Value<int>(DateTime.now().millisecondsSinceEpoch),
        ),
      );
      installed = true;
    }
    if (policy == VideoDownloadSubtitlePolicy.required && !installed) {
      throw const VideoDownloadPipelineActionRequired(
        'Required legacy subtitles could not be installed',
      );
    }
    await _advance(job, VideoDownloadJobStage.import);
  }

  Future<void> _markLegacySubtitleUnavailable(
    VideoDownloadJobSubtitleRow subtitle,
    VideoDownloadJobFileRow? video,
    String error,
  ) =>
      database.updateVideoDownloadJobSubtitle(
        subtitle.subtitleId,
        VideoDownloadJobSubtitlesCompanion(
          jobFileId: Value<int?>(video?.id),
          status: const Value<String>(
            VideoDownloadJobSubtitleStatus.unavailable,
          ),
          error: Value<String?>(error),
          updatedAt: Value<int>(DateTime.now().millisecondsSinceEpoch),
        ),
      );

  static VideoDownloadJobFileRow? _matchLegacySubtitleVideo(
    VideoDownloadJobSubtitleRow subtitle,
    List<VideoDownloadJobFileRow> videos,
  ) {
    if (subtitle.jobFileId != null) {
      for (final VideoDownloadJobFileRow video in videos) {
        if (video.id == subtitle.jobFileId) return video;
      }
    }
    if (subtitle.episode != null) {
      for (final VideoDownloadJobFileRow video in videos) {
        if (video.episode == subtitle.episode &&
            (subtitle.season == null || video.season == subtitle.season)) {
          return video;
        }
      }
    }
    if (videos.length == 1 &&
        (subtitle.episode == null || videos.single.episode == null)) {
      return videos.single;
    }
    return null;
  }

  static Future<String?> _firstSidecarPath(String videoPath) async {
    final Directory directory = Directory(p.dirname(videoPath));
    if (!await directory.exists()) return null;
    final List<String> names = <String>[];
    await for (final FileSystemEntity entity
        in directory.list(followLinks: false)) {
      if (entity is File) names.add(p.basename(entity.path));
    }
    final List<String> sidecars = listSidecarSubtitles(
      p.basenameWithoutExtension(videoPath),
      names,
    );
    return sidecars.isEmpty ? null : p.join(directory.path, sidecars.first);
  }

  static Future<bool> _filesHaveSameContent(File left, File right) async {
    if (!await left.exists() || !await right.exists()) return false;
    if (await left.length() != await right.length()) return false;
    return sha256.convert(await left.readAsBytes()) ==
        sha256.convert(await right.readAsBytes());
  }

  Future<void> _recordUnavailableSubtitle(VideoDownloadJobRow job,
      VideoDownloadJobFileRow file, String subtitleId, String error,
      {VideoDownloadJobSubtitleRow? existingSelection}) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    if (existingSelection != null) {
      await database.updateVideoDownloadJobSubtitle(
        subtitleId,
        VideoDownloadJobSubtitlesCompanion(
          jobFileId: Value<int?>(file.id),
          status: const Value<String>(
            VideoDownloadJobSubtitleStatus.unavailable,
          ),
          error: Value<String?>(_safeError(error)),
          updatedAt: Value<int>(now),
        ),
      );
      return;
    }
    await database.upsertVideoDownloadJobSubtitle(
      VideoDownloadJobSubtitlesCompanion(
        subtitleId: Value<String>(subtitleId),
        jobId: Value<String>(job.jobId),
        jobFileId: Value<int?>(file.id),
        provider: const Value<String>('auto'),
        season: Value<int?>(file.season),
        episode: Value<int?>(file.episode),
        status: const Value<String>(
          VideoDownloadJobSubtitleStatus.unavailable,
        ),
        error: Value<String?>(_safeError(error)),
        createdAt: Value<int>(now),
        updatedAt: Value<int>(now),
      ),
    );
  }

  Future<String> _selectSidecarTarget({
    required List<int> bytes,
    required String initialTarget,
  }) async {
    String target = initialTarget;
    final Digest incoming = sha256.convert(bytes);
    for (int suffix = 0; suffix < 100; suffix++) {
      final File existing = File(target);
      if (!await existing.exists()) return target;
      if (sha256.convert(await existing.readAsBytes()) == incoming) {
        return target;
      }
      final String extension = p.extension(initialTarget);
      final String stem = p.basenameWithoutExtension(initialTarget);
      target = p.join(
        p.dirname(initialTarget),
        '$stem.fushi${suffix + 1}$extension',
      );
    }
    throw const VideoDownloadPipelineActionRequired(
      'No conflict-free subtitle target is available',
    );
  }

  Future<String> _installSidecarAtTargetAtomically({
    required List<int> bytes,
    required String target,
    required String tempPath,
  }) async {
    final File existing = File(target);
    if (await existing.exists()) {
      if (sha256.convert(await existing.readAsBytes()) ==
          sha256.convert(bytes)) {
        return target;
      }
      throw const VideoDownloadPipelineActionRequired(
        'Subtitle target changed while installing; nothing was overwritten',
      );
    }
    final File temp = File(tempPath);
    if (await temp.exists()) await temp.delete();
    await temp.writeAsBytes(bytes, flush: true);
    if (await File(target).exists()) {
      await temp.delete();
      throw const VideoDownloadPipelineActionRequired(
        'Subtitle target changed while installing; nothing was overwritten',
      );
    }
    await temp.rename(target);
    return target;
  }

  Future<void> _importMedia(VideoDownloadJobRow job) async {
    _ensureLeaseHeld();
    final bool legacy = job.organizationPolicy == 'legacy';
    final MediaSourceRow? source = legacy ? null : await _managedSource(job);
    final List<VideoDownloadJobFileRow> files = (await database
            .getVideoDownloadJobFiles(job.jobId))
        .where((VideoDownloadJobFileRow row) =>
            row.kind == 'video' && row.finalAbsolutePath != null)
        .toList()
      ..sort(_compareJobFiles);
    if (files.isEmpty) {
      throw const VideoDownloadPipelineActionRequired(
        'No organized video files are available for import',
      );
    }
    final Map<int, String> bookUidByFileId = <int, String>{};
    int? collectionId;
    if (job.mediaKind == VideoMetadataMediaKind.tv.name) {
      final List<PlaylistEntry> entries = files
          .map(
            (VideoDownloadJobFileRow file) => PlaylistEntry(
              title: _episodeTitle(job.title, file),
              path: file.finalAbsolutePath!,
              positionMs: 0,
            ),
          )
          .toList();
      final SplitPlaylistImportResult result =
          await _videoRepository.importSplitPlaylist(
        collectionName: legacy || job.year == null
            ? job.title
            : '${job.title} (${job.year})',
        entries: entries,
        sourceId: source?.id,
        reuseExistingPaths: true,
      );
      _ensureLeaseHeld();
      collectionId = result.collectionId;
      await _videoRepository.reorderDownloadedCollectionEpisodes(collectionId);
      _ensureLeaseHeld();
      for (int index = 0; index < files.length; index++) {
        bookUidByFileId[files[index].id] = result.episodeUids[index];
      }
      if (result.createdEpisodeUids.isNotEmpty) {
        await _videoRepository.recordVideoImportActivity(
          bookUid: result.createdEpisodeUids.first,
          title: job.title,
        );
      }
    } else {
      final VideoDownloadJobFileRow file = files.first;
      final List<VideoBookRow> existing = await database.allVideoBooks();
      VideoBookRow? book;
      final String normalized = normalizeVideoPath(file.finalAbsolutePath!);
      for (final VideoBookRow row in existing) {
        if (normalizeVideoPath(row.videoPath) == normalized) {
          book = row;
          break;
        }
      }
      bool created = false;
      if (book == null) {
        final Set<String> taken =
            existing.map((VideoBookRow row) => row.bookUid).toSet();
        final String uid = coreUniqueVideoBookUid(
          coreSingleVideoBookUid(file.finalAbsolutePath!),
          taken,
        );
        await _videoRepository.saveVideoBook(
          VideoBooksCompanion(
            bookUid: Value<String>(uid),
            title: Value<String>(job.title),
            videoPath: Value<String>(file.finalAbsolutePath!),
            embeddedSubtitleTrack: const Value<int?>(0),
            importedAt: Value<int?>(DateTime.now().millisecondsSinceEpoch),
          ),
          sourceId: source?.id,
        );
        _ensureLeaseHeld();
        book = await database.getVideoBookByBookUid(uid);
        created = true;
      } else if (!legacy && book.sourceId == null) {
        await _videoRepository.assignSourceIfNull(book.bookUid, source!.id);
      }
      if (book == null) throw StateError('video import did not create a row');
      bookUidByFileId[file.id] = book.bookUid;
      if (created) {
        await _videoRepository.recordVideoImportActivity(
          bookUid: book.bookUid,
          title: job.title,
        );
      }
    }
    final List<VideoDownloadJobSubtitleRow> subtitles =
        await database.getVideoDownloadJobSubtitles(job.jobId);
    for (final VideoDownloadJobSubtitleRow subtitle in subtitles) {
      final String? uid = subtitle.jobFileId == null
          ? null
          : bookUidByFileId[subtitle.jobFileId!];
      if (uid != null &&
          subtitle.status == VideoDownloadJobSubtitleStatus.placed &&
          subtitle.finalPath != null) {
        await _videoRepository.updateSubtitleSource(uid, subtitle.finalPath);
      }
    }
    final int now = DateTime.now().millisecondsSinceEpoch;
    for (final VideoDownloadJobFileRow file in files) {
      await database.updateVideoDownloadJobFile(
        file.id,
        VideoDownloadJobFilesCompanion(
          status: const Value<String>(VideoDownloadJobFileStatus.imported),
          updatedAt: Value<int>(now),
        ),
      );
    }
    if (collectionId != null) {
      await database.updateVideoDownloadJob(
        job.jobId,
        VideoDownloadJobsCompanion(
          collectionId: Value<int?>(collectionId),
          updatedAt: Value<int>(now),
        ),
      );
    }
    database.notifyVideoLibraryChanged();
    if (legacy) {
      await _releaseLeaseWith(
        () => database.completeVideoDownloadJob(
          jobId: job.jobId,
          workerId: workerId,
          completedAt: now,
        ),
      );
      return;
    }
    await _advance(job, VideoDownloadJobStage.scrape, nowAt: now);
  }

  Future<void> _scrapeMedia(VideoDownloadJobRow job) async {
    _ensureLeaseHeld();
    final MediaSourceRow source = await _managedSource(job);
    final VideoMetadataProviderKind? provider =
        VideoMetadataProviderKind.values.asNameMap()[job.metadataProvider];
    final VideoMetadataMediaKind? mediaKind =
        VideoMetadataMediaKind.values.asNameMap()[job.mediaKind];
    if (provider == null || mediaKind == null || job.externalId == null) {
      throw const VideoDownloadPipelineActionRequired(
        'Confirmed discovery identity is missing; automatic fuzzy matching was not run',
      );
    }
    final List<VideoSourceScrapeWork> works =
        await VideoSourceWorkPlanner(database).plan(source);
    _ensureLeaseHeld();
    final Set<String> importedPaths =
        (await database.getVideoDownloadJobFiles(job.jobId))
            .map((VideoDownloadJobFileRow row) => row.finalAbsolutePath)
            .whereType<String>()
            .map(normalizeVideoPath)
            .toSet();
    final List<VideoSourceScrapeWork> pathMatches = works
        .where((VideoSourceScrapeWork value) => value.members.any(
              (VideoBookRow member) =>
                  importedPaths.contains(normalizeVideoPath(member.videoPath)),
            ))
        .toList(growable: false);
    VideoSourceScrapeWork? work;
    if (job.collectionId != null) {
      work = pathMatches
          .where((VideoSourceScrapeWork value) =>
              value.collection?.id == job.collectionId)
          .firstOrNull;
      // A newly imported series can contain only one episode. The source work
      // planner intentionally does not promote a single-member collection to
      // an episodic work yet, so its exact path match has no collection here.
      // Accept that one unambiguous imported-path match; this is still an
      // identity-safe lookup and never falls back to a title comparison.
      work ??= pathMatches.length == 1 ? pathMatches.single : null;
    } else if (pathMatches.length == 1) {
      work = pathMatches.single;
    }
    if (work == null) {
      throw const VideoDownloadPipelineActionRequired(
        'Imported media could not be mapped exactly back to its managed source',
      );
    }
    final report = await scrapeCoordinator.scrapeImportedWork(
      work,
      lookup: VideoMetadataLookup(
        provider: provider,
        externalId: job.externalId!,
        mediaKind: mediaKind,
      ),
    );
    _ensureLeaseHeld();
    database.notifyVideoLibraryChanged();
    if (report.cancelled ||
        report.failedWorks > 0 ||
        report.pendingConfirmations > 0 ||
        report.succeededWorks == 0) {
      final String message = report.errors.isNotEmpty
          ? report.errors.first.message
          : report.warnings.isNotEmpty
              ? report.warnings.first.message
              : 'Exact metadata scrape did not complete';
      throw VideoDownloadPipelineActionRequired(message);
    }
    await _releaseLeaseWith(
      () => database.completeVideoDownloadJob(
        jobId: job.jobId,
        workerId: workerId,
        completedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Future<void> _advance(
    VideoDownloadJobRow job,
    String stage, {
    int? nowAt,
    String? backendTaskId,
    String? torrentHash,
    String? observedSavePath,
    String? targetRelativeRoot,
  }) =>
      _releaseLeaseWith(
        () => database.advanceVideoDownloadJobStage(
          jobId: job.jobId,
          workerId: workerId,
          stage: stage,
          nowAt: nowAt ?? DateTime.now().millisecondsSinceEpoch,
          progress: 0,
          backendTaskId: backendTaskId,
          torrentHash: torrentHash,
          observedSavePath: observedSavePath,
          targetRelativeRoot: targetRelativeRoot,
        ),
      );

  Future<void> _markNeedsAttention(
    VideoDownloadJobRow job,
    String error, {
    int? nowAt,
  }) =>
      _releaseLeaseWith(
        () => database.markVideoDownloadJobNeedsAttention(
          jobId: job.jobId,
          workerId: workerId,
          error: error,
          nowAt: nowAt ?? DateTime.now().millisecondsSinceEpoch,
        ),
      );

  Future<void> _releaseLeaseWith(Future<bool> Function() transition) async {
    final VideoDownloadLeaseGuard? lease = _activeLease;
    if (lease == null) throw const VideoDownloadLeaseLost();
    lease.ensureHeld();
    final bool changed = await transition();
    if (!changed) {
      lease.markLost();
      throw const VideoDownloadLeaseLost();
    }
    lease.markReleased();
  }

  void _ensureLeaseHeld() {
    final VideoDownloadLeaseGuard? lease = _activeLease;
    if (lease == null) throw const VideoDownloadLeaseLost();
    lease.ensureHeld();
  }

  Future<MediaSourceRow> _managedSource(VideoDownloadJobRow job) async {
    final int? sourceId = job.targetSourceId;
    if (sourceId == null) {
      throw const VideoDownloadPipelineActionRequired(
        'The managed video source no longer exists',
      );
    }
    final MediaSourceRow? source = await database.getMediaSourceById(sourceId);
    _validateManagedSource(source);
    return source!;
  }

  List<VideoDownloadPathMapping> _effectivePathMappings(
    VideoDownloadBackendBinding binding, {
    String? observedSavePath,
    String? sourceRoot,
  }) {
    if (binding.pathMappings.isNotEmpty) return binding.pathMappings;
    final List<VideoDownloadPathMapping> identities =
        <VideoDownloadPathMapping>[];
    final Set<String> anchors = <String>{};
    void addAccessibleIdentity(String? path) {
      if (path == null || path.trim().isEmpty) return;
      final Directory directory = Directory(path);
      if (!directory.existsSync()) return;
      final String absolute = p.normalize(p.absolute(path));
      final String anchor = p.rootPrefix(absolute);
      final String root = anchor.isEmpty ? absolute : anchor;
      final String key = Platform.isWindows ? root.toLowerCase() : root;
      if (anchors.add(key)) {
        identities.add(VideoDownloadPathMapping.identity(root));
      }
    }

    // No explicit map means "same machine" only. Using the filesystem anchor
    // (drive root or `/`) lets a local backend move from a download directory
    // into a sibling managed source; anchoring at the source itself would
    // incorrectly reject the observed download path.
    addAccessibleIdentity(observedSavePath);
    addAccessibleIdentity(sourceRoot);
    return List<VideoDownloadPathMapping>.unmodifiable(identities);
  }

  Future<({VideoDownloadPathMapping mapping, String localPath})>
      _validateObservedSavePath(
    VideoDownloadJobRow job,
    List<VideoDownloadPathMapping> mappings,
  ) async {
    final String? observed = job.observedSavePath?.trim();
    if (observed == null || observed.isEmpty) {
      throw const VideoDownloadPipelineActionRequired(
        'The download backend did not report its save path',
      );
    }
    final VideoDownloadPathMapping? mapping =
        _mappingForRemotePath(mappings, observed);
    if (mapping == null) {
      throw const VideoDownloadPipelineActionRequired(
        'The backend save path cannot be mapped to this device',
      );
    }
    final String? localPath = mapping.remoteToLocal(observed);
    if (localPath == null || !await Directory(localPath).exists()) {
      throw const VideoDownloadPipelineActionRequired(
        'The mapped backend save path is not accessible on this device',
      );
    }
    return (mapping: mapping, localPath: p.normalize(p.absolute(localPath)));
  }

  static VideoDownloadPathMapping? _mappingForRemotePath(
    Iterable<VideoDownloadPathMapping> mappings,
    String remotePath,
  ) {
    VideoDownloadPathMapping? selected;
    for (final VideoDownloadPathMapping mapping in mappings) {
      if (mapping.remoteToLocal(remotePath) == null) continue;
      if (selected == null ||
          mapping.remoteRoot.length > selected.remoteRoot.length) {
        selected = mapping;
      }
    }
    return selected;
  }

  static VideoDownloadPathMapping? _mappingForLocalPath(
    Iterable<VideoDownloadPathMapping> mappings,
    String localPath,
  ) {
    VideoDownloadPathMapping? selected;
    for (final VideoDownloadPathMapping mapping in mappings) {
      if (mapping.localToRemote(localPath) == null) continue;
      if (selected == null ||
          mapping.localRoot.length > selected.localRoot.length) {
        selected = mapping;
      }
    }
    return selected;
  }

  static String? _resolveBackendFileLocalPath({
    required String remoteSavePath,
    required String relativePath,
    required VideoDownloadPathMapping mapping,
    required String localSaveRoot,
  }) {
    final String portable = relativePath.replaceAll('\\', '/').trim();
    if (portable.isEmpty ||
        portable.startsWith('/') ||
        RegExp(r'^[A-Za-z]:').hasMatch(portable)) {
      return null;
    }
    final List<String> segments = portable.split('/');
    if (segments.any(
      (String segment) => segment.isEmpty || segment == '..',
    )) {
      return null;
    }
    final String remote = <String>[
      remoteSavePath.replaceAll('\\', '/').replaceFirst(RegExp(r'/+$'), ''),
      ...segments,
    ].join('/');
    final String? local = mapping.remoteToLocal(remote);
    if (local == null) return null;
    final String normalizedRoot = p.normalize(p.absolute(localSaveRoot));
    final String normalizedLocal = p.normalize(p.absolute(local));
    if (normalizedLocal != normalizedRoot &&
        !p.isWithin(normalizedRoot, normalizedLocal)) {
      return null;
    }
    return normalizedLocal;
  }

  static bool _isVideoFile(String path) =>
      kVideoExtensions.contains(p.extension(path).toLowerCase());

  static void _validateManagedSource(MediaSourceRow? source) {
    if (source == null ||
        source.mediaKind != 'video' ||
        source.transport != 'local') {
      throw const VideoDownloadPipelineActionRequired(
        'A local managed video source is required',
      );
    }
    final Directory root = Directory(source.rootPath);
    if (!root.existsSync()) {
      throw const VideoDownloadPipelineActionRequired(
        'The managed video source path is not accessible on this device',
      );
    }
  }

  VideoMediaReference _mediaReference(VideoDownloadJobRow job) {
    final VideoMetadataMediaKind mediaKind =
        VideoMetadataMediaKind.values.asNameMap()[job.mediaKind] ??
            VideoMetadataMediaKind.tv;
    final VideoDiscoveryCategory category =
        VideoDiscoveryCategory.values.asNameMap()[job.discoveryCategory] ??
            (mediaKind == VideoMetadataMediaKind.movie
                ? VideoDiscoveryCategory.movie
                : VideoDiscoveryCategory.tv);
    final String provider = job.metadataProvider ?? 'unknown';
    final String id = job.externalId ?? job.title;
    return VideoMediaReference(
      providerId: provider,
      mediaId: id,
      mediaKind: mediaKind,
      discoveryCategory: category,
      title: job.title,
      year: job.year,
      season: job.season,
      tmdbId: provider == 'tmdb' ? int.tryParse(id) : null,
      anilistId: provider == 'anilist' ? int.tryParse(id) : null,
      bangumiId: provider == 'bangumi' ? int.tryParse(id) : null,
    );
  }

  Future<VideoDownloadJobFileRow?> _jobFileByIndex(
    String jobId,
    int index,
  ) async {
    for (final VideoDownloadJobFileRow row
        in await database.getVideoDownloadJobFiles(jobId)) {
      if (row.backendFileIndex == index) return row;
    }
    return null;
  }

  static int _compareJobFiles(
    VideoDownloadJobFileRow a,
    VideoDownloadJobFileRow b,
  ) {
    final int bySeason = (a.season ?? 0).compareTo(b.season ?? 0);
    if (bySeason != 0) return bySeason;
    final int byEpisode = (a.episode ?? 0).compareTo(b.episode ?? 0);
    if (byEpisode != 0) return byEpisode;
    return a.id.compareTo(b.id);
  }

  static String _episodeTitle(
    String title,
    VideoDownloadJobFileRow file,
  ) {
    final String season = (file.season ?? 1).toString().padLeft(2, '0');
    final String episode = (file.episode ?? 0).toString().padLeft(2, '0');
    return '$title - S${season}E$episode';
  }

  static String _safeSubtitleExtension(String fileName) {
    final String extension = p.extension(fileName).toLowerCase();
    return const <String>{'.srt', '.ass', '.ssa', '.vtt', '.sub'}.contains(
      extension,
    )
        ? extension
        : '.srt';
  }

  static String _safeError(String value) {
    final String redacted = redactCredentialsInText(value)
        .replaceAll(RegExp(r'[\r\n]+'), ' ')
        .trim();
    if (redacted.length <= 600) return redacted;
    return '${redacted.substring(0, 600)}…';
  }
}

extension on VideoMediaReference {
  VideoMediaReference copyWithEpisode({int? season, int? episode}) =>
      VideoMediaReference(
        providerId: providerId,
        mediaId: mediaId,
        mediaKind: mediaKind,
        discoveryCategory: discoveryCategory,
        title: title,
        originalTitle: originalTitle,
        year: year,
        season: season ?? this.season,
        episode: episode ?? this.episode,
        tmdbId: tmdbId,
        imdbId: imdbId,
        tvdbId: tvdbId,
        anilistId: anilistId,
        bangumiId: bangumiId,
        externalIds: externalIds,
      );
}
