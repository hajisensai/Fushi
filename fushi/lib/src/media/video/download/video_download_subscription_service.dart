import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/metadata/credential_redaction.dart';
import 'package:fushi/src/media/torrent/video_resource_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/download/video_download_backend_identity.dart';
import 'package:fushi/src/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi/src/media/video/download/video_resource_registry.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/video_filename_parser.dart';

typedef VideoDownloadSubscriptionEnqueue = Future<String> Function(
  VideoDownloadEnqueueRequest request,
);

// Nyaa's upstream RESULTS_PER_PAGE default is 75. Keeping the subscription
// window aligned lets a 75-item first page continue instead of being mistaken
// for a short page.
const int _subscriptionResourcePageSize = 75;

// Bound a single 15-minute check to 1,500 provider rows. Duplicate-page
// detection normally stops much earlier, including mirrors that ignore paging.
const int _subscriptionResourceMaxPages = 20;

/// 订阅自动重派同一个任务的持久上限。
///
/// 账本不在内存里——进程重启就归零的计数等于没有上限。它落在任务自己的
/// `attemptCount` 上，见 `FushiDatabase.reviveVideoDownloadJobForSubscription`。
/// 借满之后这一集停在 `failed` / `needsAttention` 等用户处理：面板对这两个状态
/// 就是显示重试按钮的（`video_download_jobs_panel.dart` 的 `_canRetry`），用户
/// 按一次会把 `attemptCount` 清零，自动预算随之恢复。
const int kVideoDownloadSubscriptionAutoRetryBudget = 3;

class VideoDownloadSubscriptionConfigurationError implements Exception {
  const VideoDownloadSubscriptionConfigurationError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// v78 订阅调度器。
///
/// 每次检查先用数据库 lease 独占订阅，再把逻辑集的资源选择写入
/// `video_download_subscription_items`，最后才调用持久下载流水线 enqueue。
/// 因此搜索重试、应用重启和多 worker 都不会把同一 `movie` / `SxxExx`
/// 重复变成下载任务。
/// 一个下载任务的下场还算不算数——即「这一集已经有人管了，订阅不用再派」。
///
/// BUG-1746 的根因是把「曾经派过任务」（`jobId != null`）当成了「任务成功了」。
/// 两者不是一回事：任务被取消或失败之后 jobId 依然留在订阅条目上，旧判据据此
/// 每轮都 `continue`，那一集就再也不会被下载——用户看到的是「订阅只下了中间
/// 几集」，而面板上什么异常都不显示。
///
/// 分界线按**是谁决定不下的**划：
/// - `cancelled` 是用户明确说「不要这一集」，尊重它，不自动重下（否则用户取消
///   一次、订阅补回来一次，永远取消不掉）；
/// - `failed` / `needsAttention` 是系统故障（实测例：内置下载引擎运行时缺失、
///   种子源暂时不可达），故障排除之后本该继续下，不能让这一集永久卡死；
/// - `active` / `completed` 显然还算数。
///
/// [lifecycle] 为 null 表示任务记录已经不在了（被清理/库被换过），此时没有任何
/// 东西在管这一集，应当允许重新派。
///
/// 注意「重新派」不等于「再造一份」：`failed` / `needsAttention` 的既有任务是被
/// **恢复**的（见 [VideoDownloadSubscriptionService._enqueueItem]），只有真的一
/// 条任务都没有时才会走 pipeline enqueue。
bool videoDownloadJobLifecycleStillCounts(String? lifecycle) {
  if (lifecycle == null) return false;
  return lifecycle != VideoDownloadJobLifecycle.failed &&
      lifecycle != VideoDownloadJobLifecycle.needsAttention;
}

/// 这一集是否已经被一个「仍然算数」的任务认领。判据的唯一真相源——
/// 入队去重与复用既有任务都走它，别再在别处写第二份 `jobId != null`。
bool subscriptionItemStillClaimed(
  VideoDownloadSubscriptionItemRow item,
  Map<String, String> lifecycleByJobId,
) {
  // processed / skipped 是入队之外的终态：已经落库、或被明确判定为不用下。
  // 它们与任务无关，不看 lifecycle。
  if (item.status == VideoDownloadSubscriptionItemStatus.processed ||
      item.status == VideoDownloadSubscriptionItemStatus.skipped) {
    return true;
  }
  final String? jobId = item.jobId;
  if (jobId == null) {
    // 没有 jobId 却标着 queued 只可能是历史遗留行（_markItemQueued 必定同时写
    // 两者）。保持旧行为不重复入队，避免给存量库凭空造重复任务。
    return item.status == VideoDownloadSubscriptionItemStatus.queued;
  }
  return videoDownloadJobLifecycleStillCounts(lifecycleByJobId[jobId]);
}

class VideoDownloadSubscriptionService {
  VideoDownloadSubscriptionService({
    required this.database,
    required this.resourceRegistry,
    required VideoDownloadSubscriptionEnqueue enqueue,
    String? workerId,
    this.checkInterval = const Duration(minutes: 15),
    this.leaseDuration = const Duration(minutes: 2),
    this.autoRetryBudget = kVideoDownloadSubscriptionAutoRetryBudget,
    DateTime Function()? now,
  })  : _enqueue = enqueue,
        workerId =
            workerId ?? 'video-sub-${generateVideoDownloadInstallationId()}',
        _now = now ?? DateTime.now {
    if (checkInterval <= Duration.zero) {
      throw ArgumentError.value(checkInterval, 'checkInterval');
    }
    if (leaseDuration <= Duration.zero) {
      throw ArgumentError.value(leaseDuration, 'leaseDuration');
    }
    if (autoRetryBudget <= 0) {
      throw ArgumentError.value(autoRetryBudget, 'autoRetryBudget');
    }
  }

  final FushiDatabase database;
  final VideoResourceRegistry resourceRegistry;
  final VideoDownloadSubscriptionEnqueue _enqueue;
  final String workerId;
  final Duration checkInterval;
  final Duration leaseDuration;
  final int autoRetryBudget;
  final DateTime Function() _now;

  Timer? _timer;
  Future<void>? _activeCheck;
  bool _disposed = false;
  VideoDownloadLeaseGuard? _activeLease;

  /// 启动时立刻领取所有当前到期订阅，之后固定每 15 分钟（或注入间隔）检查。
  void start() {
    if (_disposed || _timer != null) return;
    _timer = Timer.periodic(checkInterval, (_) => unawaited(checkNow()));
    unawaited(checkNow());
  }

  Future<void> checkNow() {
    if (_disposed) return Future<void>.value();
    final Future<void>? active = _activeCheck;
    if (active != null) return active;
    late final Future<void> run;
    run = _drain().whenComplete(() {
      if (identical(_activeCheck, run)) _activeCheck = null;
    });
    _activeCheck = run;
    return run;
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _activeCheck;
  }

  Future<void> dispose() async {
    _disposed = true;
    await stop();
  }

  Future<void> _drain() async {
    for (int processed = 0; processed < 64 && !_disposed; processed++) {
      final int nowAt = _now().millisecondsSinceEpoch;
      final VideoDownloadSubscriptionRow? subscription =
          await database.claimNextVideoDownloadSubscription(
        workerId: workerId,
        nowAt: nowAt,
        leaseDurationMs: leaseDuration.inMilliseconds,
      );
      if (subscription == null) return;
      await _process(subscription);
    }
  }

  Future<void> _process(VideoDownloadSubscriptionRow subscription) async {
    final VideoDownloadLeaseGuard lease = VideoDownloadLeaseGuard(
      leaseDuration: leaseDuration,
      renew: () => database.renewVideoDownloadSubscriptionClaim(
        subscriptionId: subscription.subscriptionId,
        workerId: workerId,
        nowAt: _now().millisecondsSinceEpoch,
        leaseDurationMs: leaseDuration.inMilliseconds,
      ),
    );
    _activeLease = lease;
    lease.start();
    try {
      await _processWithLease(subscription);
    } on VideoDownloadLeaseLost {
      // A later worker owns the subscription now. Its persisted item outbox is
      // sufficient to reconcile any job created before ownership was lost.
    } finally {
      if (identical(_activeLease, lease)) _activeLease = null;
      await lease.stop();
    }
  }

  Future<void> _processWithLease(
    VideoDownloadSubscriptionRow subscription,
  ) async {
    try {
      final _SubscriptionCheckOutcome outcome = await _check(subscription);
      final int checkedAt = _now().millisecondsSinceEpoch;
      await _releaseLeaseWith(
        () => database.completeVideoDownloadSubscriptionCheck(
          subscriptionId: subscription.subscriptionId,
          workerId: workerId,
          checkedAt: checkedAt,
          nextCheckAt: checkedAt + checkInterval.inMilliseconds,
          matchedAt: outcome.matched ? checkedAt : null,
          fulfillOneShot:
              subscription.mode == 'oneShot' && outcome.hasPersistentJob,
        ),
      );
    } on Object catch (error) {
      _ensureLeaseHeld();
      final int failedAt = _now().millisecondsSinceEpoch;
      final Duration retryDelay = _retryDelay(subscription, error);
      await _releaseLeaseWith(
        () => database.retryVideoDownloadSubscriptionCheck(
          subscriptionId: subscription.subscriptionId,
          workerId: workerId,
          error: _safeSubscriptionError(error),
          failedAt: failedAt,
          nextCheckAt: failedAt + retryDelay.inMilliseconds,
        ),
      );
    }
  }

  Future<_SubscriptionCheckOutcome> _check(
    VideoDownloadSubscriptionRow subscription,
  ) async {
    _ensureLeaseHeld();
    _validateSubscription(subscription);
    final List<VideoDownloadSubscriptionItemRow> existingItems =
        await database.getVideoDownloadSubscriptionItems(
      subscription.subscriptionId,
    );
    if (subscription.mode == 'oneShot' &&
        existingItems.any(
          (VideoDownloadSubscriptionItemRow item) => item.jobId != null,
        )) {
      return const _SubscriptionCheckOutcome(
        matched: true,
        hasPersistentJob: true,
      );
    }

    final String selectedProvider = subscription.resourceProvider.trim();
    final String providerBase = _providerBase(selectedProvider);
    if (!resourceRegistry.providers.any(
      (VideoResourceProvider provider) => provider.id == providerBase,
    )) {
      throw const VideoDownloadSubscriptionConfigurationError(
        'The selected resource provider is not configured on this device',
      );
    }
    final _SubscriptionFilter filter = _SubscriptionFilter.parse(
      subscription.filterJson,
      providerBase: providerBase,
    );
    final VideoMediaReference media = _mediaReference(subscription);
    final List<VideoResourceCandidate> providerCandidates =
        await _searchSubscriptionCandidates(
      media: media,
      query: subscription.searchQuery,
      season: subscription.season,
      selectedProvider: selectedProvider,
      providerBase: providerBase,
    );

    final Map<String, List<_SubscriptionRelease>> releasesByItem =
        <String, List<_SubscriptionRelease>>{};
    for (final VideoResourceCandidate candidate in providerCandidates) {
      if (!filter.matches(candidate)) continue;
      final _SubscriptionLogicalItem? logicalItem =
          _logicalItem(subscription, candidate.title);
      if (logicalItem == null) continue;
      releasesByItem
          .putIfAbsent(
            logicalItem.key,
            () => <_SubscriptionRelease>[],
          )
          .add(_SubscriptionRelease(candidate, logicalItem));
    }
    if (releasesByItem.isEmpty) {
      return const _SubscriptionCheckOutcome(
        matched: false,
        hasPersistentJob: false,
      );
    }

    final Map<String, VideoDownloadSubscriptionItemRow> existingByKey =
        <String, VideoDownloadSubscriptionItemRow>{
      for (final VideoDownloadSubscriptionItemRow item in existingItems)
        item.logicalItemKey: item,
    };
    final Set<String> managedEpisodeKeys =
        await _managedEpisodeKeys(subscription);
    // BUG-1746：判「这一集还用不用管」必须看任务的真实下场，不能只看 jobId 在不在。
    final Map<String, String> lifecycleByJobId = <String, String>{
      for (final VideoDownloadJobRow job
          in await database.getVideoDownloadJobs())
        job.jobId: job.lifecycle,
    };
    final List<String> keys = releasesByItem.keys.toList()
      ..sort(_compareLogicalItemKeys);
    bool hasPersistentJob = false;
    Object? firstError;
    for (final String key in keys) {
      final VideoDownloadSubscriptionItemRow? existing = existingByKey[key];
      if (existing != null &&
          subscriptionItemStillClaimed(existing, lifecycleByJobId)) {
        hasPersistentJob = hasPersistentJob || existing.jobId != null;
        continue;
      }
      final List<_SubscriptionRelease> choices = releasesByItem[key]!;
      final _SubscriptionRelease? release = existing == null
          ? _bestRelease(choices)
          : _findPersistedRelease(existing, choices);
      if (release == null) {
        firstError ??= ExternalProviderFailure(
          providerId: providerBase,
          operation: 'subscription-search',
          kind: ExternalProviderFailureKind.notFound,
          message: 'the persisted subscription release is unavailable',
          retryable: true,
        );
        continue;
      }
      try {
        final VideoDownloadSubscriptionItemRow item =
            existing ?? await _persistDiscoveredItem(subscription, release);
        if (managedEpisodeKeys.contains(release.logicalItem.key)) {
          await _markItemSkipped(item.id);
          continue;
        }
        hasPersistentJob =
            await _enqueueItem(subscription, media, release.candidate, item) ||
                hasPersistentJob;
      } on VideoDownloadLeaseLost {
        rethrow;
      } on Object catch (error) {
        firstError ??= error;
      }
    }
    if (firstError != null) _throwSubscriptionError(firstError);
    return _SubscriptionCheckOutcome(
      matched: true,
      hasPersistentJob: hasPersistentJob,
    );
  }

  Future<Set<String>> _managedEpisodeKeys(
    VideoDownloadSubscriptionRow subscription,
  ) async {
    if (_mediaKind(subscription.mediaKind) == VideoMetadataMediaKind.movie) {
      return const <String>{};
    }
    final Set<String> result = <String>{};
    final String provider =
        subscription.metadataProvider?.trim().toLowerCase() ?? '';
    final String externalId = subscription.externalId?.trim() ?? '';
    if (provider.isEmpty || externalId.isEmpty) return result;
    bool sameIdentity(VideoDownloadJobRow job) =>
        job.metadataProvider?.trim().toLowerCase() == provider &&
        job.externalId?.trim() == externalId;
    for (final VideoDownloadJobRow job
        in await database.getVideoDownloadJobs()) {
      // 只有 active / completed 的任务才算「这一集的文件已经有人管」。
      //
      // 这份判据与 [subscriptionItemStillClaimed] **不同**且有意不同：那边按
      // 「是谁决定不下的」划，cancelled 算数；这边按「文件到底有没有人在弄」
      // 划，cancelled 不算数。needsAttention 归到不算数一侧：它正是订阅这一轮
      // 要恢复的对象（见 [_enqueueItem]），留着它，同一条卡住的任务会在文件级
      // 把自己的订阅条目判成「已经有人管」而走 [_markItemSkipped] —— 那是个终态
      // 写入，此后 [subscriptionItemStillClaimed] 永远返回 true，这一集被静默判
      // 了永久跳过。真正已经入库的集数由下面的 collection items 那一段兜住，不
      // 依赖这里的任务扫描。
      final bool jobOwnsEpisodeFiles =
          job.lifecycle == VideoDownloadJobLifecycle.active ||
              job.lifecycle == VideoDownloadJobLifecycle.completed;
      if (!sameIdentity(job) || !jobOwnsEpisodeFiles) continue;
      for (final VideoDownloadJobFileRow file
          in await database.getVideoDownloadJobFiles(job.jobId)) {
        final int? season = file.season;
        final int? episode = file.episode;
        if (season == null || episode == null || episode <= 0) continue;
        if (file.status == VideoDownloadJobFileStatus.failed ||
            file.status == VideoDownloadJobFileStatus.skipped) {
          continue;
        }
        result.add(_episodeKey(season, episode));
      }
    }

    final VideoMetadataWorkRow? work =
        await database.getVideoMetadataWorkByProviderIdentity(
      provider: provider,
      externalId: externalId,
    );
    final int? collectionId = work?.collectionId;
    if (collectionId == null) return result;
    for (final MediaCollectionItemRow item
        in await database.getCollectionItems(collectionId)) {
      if (item.mediaType != MediaKind.video.dbValue) continue;
      final VideoBookRow? book =
          await database.getVideoBookByBookUid(item.entryKey);
      if (book == null) continue;
      final VideoNameInfo parsed = parseVideoFilename(book.videoPath);
      final int? episode = parsed.episode;
      if (episode == null || episode <= 0) continue;
      result.add(_episodeKey(parsed.season ?? 1, episode));
    }
    return result;
  }

  Future<List<VideoResourceCandidate>> _searchSubscriptionCandidates({
    required VideoMediaReference media,
    required String query,
    required int? season,
    required String selectedProvider,
    required String providerBase,
  }) async {
    final List<VideoResourceProvider> providers = resourceRegistry.providers
        .where((VideoResourceProvider provider) => provider.id == providerBase)
        .toList(growable: false);
    final Map<String, VideoResourceCandidate> candidatesByIdentity =
        <String, VideoResourceCandidate>{};

    for (int page = 1; page <= _subscriptionResourceMaxPages; page++) {
      _ensureLeaseHeld();
      final VideoResourceSearchRequest request = VideoResourceSearchRequest(
        media: media,
        query: query,
        season: season,
        page: page,
        limit: _subscriptionResourcePageSize,
      );
      final List<ProviderBatchResult<VideoResourceCandidate>> batches =
          await Future.wait(
        providers.map(
          (VideoResourceProvider provider) async {
            try {
              return await provider.search(request);
            } on Object catch (error) {
              return ProviderBatchResult<VideoResourceCandidate>.failure(
                ExternalProviderFailure.fromException(
                  providerId: provider.id,
                  operation: 'subscription-search',
                  error: error,
                ),
              );
            }
          },
        ),
      );
      _ensureLeaseHeld();
      final ProviderBatchResult<VideoResourceCandidate> result =
          ProviderBatchResult.merge<VideoResourceCandidate>(batches);
      final List<VideoResourceCandidate> pageCandidates = result.items
          .where(
            (VideoResourceCandidate candidate) =>
                _candidateBelongsToProvider(candidate, selectedProvider),
          )
          .toList(growable: false);
      if (pageCandidates.isEmpty) {
        for (final ExternalProviderFailure failure in result.failures) {
          if (_failureBelongsToProvider(failure, selectedProvider)) {
            throw failure;
          }
        }
        if (result.isTotalFailure && result.failures.isNotEmpty) {
          throw result.failures.first;
        }
        break;
      }

      int newCandidateCount = 0;
      for (final VideoResourceCandidate candidate in pageCandidates) {
        if (candidatesByIdentity.containsKey(candidate.identityKey)) continue;
        candidatesByIdentity[candidate.identityKey] = candidate;
        newCandidateCount++;
      }
      if (pageCandidates.length < _subscriptionResourcePageSize ||
          newCandidateCount == 0) {
        break;
      }
    }
    return List<VideoResourceCandidate>.unmodifiable(
      candidatesByIdentity.values,
    );
  }

  Future<VideoDownloadSubscriptionItemRow> _persistDiscoveredItem(
    VideoDownloadSubscriptionRow subscription,
    _SubscriptionRelease release,
  ) async {
    _ensureLeaseHeld();
    final VideoResourceCandidate candidate = release.candidate;
    final int nowAt = _now().millisecondsSinceEpoch;
    await database.upsertVideoDownloadSubscriptionItem(
      VideoDownloadSubscriptionItemsCompanion.insert(
        subscriptionId: subscription.subscriptionId,
        logicalItemKey: release.logicalItem.key,
        resourceProvider: persistedVideoResourceProviderId(candidate),
        selectedResourceId: candidate.remoteId,
        torrentHash: Value<String?>(candidate.infoHash?.toLowerCase()),
        title: candidate.title,
        season: Value<int?>(release.logicalItem.season),
        episode: Value<int?>(release.logicalItem.episode),
        publishedAt: Value<int?>(candidate.publishedAt?.millisecondsSinceEpoch),
        status: const Value<String>(
          VideoDownloadSubscriptionItemStatus.discovered,
        ),
        discoveredAt: nowAt,
        updatedAt: nowAt,
      ),
    );
    _ensureLeaseHeld();
    final List<VideoDownloadSubscriptionItemRow> items =
        await database.getVideoDownloadSubscriptionItems(
      subscription.subscriptionId,
    );
    return items.firstWhere(
      (VideoDownloadSubscriptionItemRow item) =>
          item.logicalItemKey == release.logicalItem.key,
    );
  }

  Future<bool> _enqueueItem(
    VideoDownloadSubscriptionRow subscription,
    VideoMediaReference media,
    VideoResourceCandidate candidate,
    VideoDownloadSubscriptionItemRow item,
  ) async {
    _ensureLeaseHeld();
    // 前置条件：调用方已用 [subscriptionItemStillClaimed] 判过这一集还用不用管。
    // 这里**不再**重复写一遍 `item.jobId != null` —— 那份副本正是 BUG-1746 的
    // 第二道锁：放开上面的判定后它会照旧把重试挡在门外。判据只留一处。
    final String providerId = persistedVideoResourceProviderId(candidate);
    final List<VideoDownloadJobRow> jobs =
        await database.getVideoDownloadJobs();
    _ensureLeaseHeld();
    for (final VideoDownloadJobRow job in jobs) {
      if (job.fingerprint != subscription.fingerprint ||
          job.resourceProvider != providerId ||
          job.selectedResourceId != candidate.remoteId) {
        continue;
      }
      if (videoDownloadJobLifecycleStillCounts(job.lifecycle)) {
        await _markItemQueued(item.id, job.jobId);
        return true;
      }
      // failed / needsAttention：**恢复**这一条既有任务，不再 enqueue 一份新的。
      //
      // `pipeline.enqueue` 每次调用都 `generateVideoDownloadInstallationId()`
      // 生成全新 jobId，而 `VideoDownloadJobs` 对
      // (fingerprint, resourceProvider, selectedResourceId) / torrentHash
      // 没有任何唯一约束。生产 checkInterval 是 15 分钟，一个持续性故障
      // （实测例：内置下载引擎运行时缺失）下这等于每集每天往下载面板堆约 96 条
      // 死任务行，永不收敛。`needsAttention` 更糟：它是「需要用户处理的可恢复
      // 状态」，backendTaskId 还在、后端 torrent 可能仍在跑，再派一份同 magnet
      // 的任务会让两条持久工作流指向同一个 infohash，各自 organize/import。
      final bool revived = await database.reviveVideoDownloadJobForSubscription(
        jobId: job.jobId,
        autoRetryBudget: autoRetryBudget,
        nowAt: _now().millisecondsSinceEpoch,
      );
      _ensureLeaseHeld();
      if (revived) await _markItemQueued(item.id, job.jobId);
      // 预算借满时任务原样停在 failed / needsAttention 等用户处理。即便如此它
      // 仍然是这一集的持久任务，不能当成「没人管」再派一份 —— 所以这里一律
      // 返回 true，不落到下面的 enqueue。
      return true;
    }

    try {
      final String jobId = await _enqueue(
        VideoDownloadEnqueueRequest(
          media: VideoMediaReference(
            providerId: media.providerId,
            mediaId: media.mediaId,
            mediaKind: media.mediaKind,
            discoveryCategory: media.discoveryCategory,
            title: media.title,
            originalTitle: media.originalTitle,
            year: media.year,
            season: item.season ?? media.season,
            episode: item.episode,
            tmdbId: media.tmdbId,
            imdbId: media.imdbId,
            tvdbId: media.tvdbId,
            anilistId: media.anilistId,
            bangumiId: media.bangumiId,
            externalIds: media.externalIds,
          ),
          resource: candidate,
          backendIdentity: VideoDownloadBackendIdentity(
            kind: subscription.backendKind,
            profileId: subscription.backendProfileId!,
            fingerprint: subscription.fingerprint,
            category: subscription.category!,
          ),
          targetSourceId: subscription.targetSourceId!,
          subtitlePolicy: _subtitlePolicy(subscription.subtitlePolicy),
          coverUrl: subscription.coverUrl,
        ),
      );
      _ensureLeaseHeld();
      await _markItemQueued(item.id, jobId);
      return true;
    } on VideoDownloadLeaseLost {
      rethrow;
    } on Object catch (error) {
      _ensureLeaseHeld();
      await database.updateVideoDownloadSubscriptionItem(
        item.id,
        VideoDownloadSubscriptionItemsCompanion(
          status: const Value<String>(
            VideoDownloadSubscriptionItemStatus.failed,
          ),
          error: Value<String?>(_safeSubscriptionError(error)),
          updatedAt: Value<int>(_now().millisecondsSinceEpoch),
        ),
      );
      rethrow;
    }
  }

  Future<void> _markItemQueued(int itemId, String jobId) async {
    _ensureLeaseHeld();
    await database.updateVideoDownloadSubscriptionItem(
      itemId,
      VideoDownloadSubscriptionItemsCompanion(
        jobId: Value<String?>(jobId),
        status: const Value<String>(
          VideoDownloadSubscriptionItemStatus.queued,
        ),
        error: const Value<String?>(null),
        updatedAt: Value<int>(_now().millisecondsSinceEpoch),
      ),
    );
    _ensureLeaseHeld();
  }

  Future<void> _markItemSkipped(int itemId) async {
    _ensureLeaseHeld();
    await database.updateVideoDownloadSubscriptionItem(
      itemId,
      VideoDownloadSubscriptionItemsCompanion(
        status: const Value<String>(
          VideoDownloadSubscriptionItemStatus.skipped,
        ),
        error: const Value<String?>(null),
        updatedAt: Value<int>(_now().millisecondsSinceEpoch),
      ),
    );
    _ensureLeaseHeld();
  }

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

  void _validateSubscription(VideoDownloadSubscriptionRow subscription) {
    if (subscription.mode != 'oneShot' && subscription.mode != 'ongoing') {
      throw const VideoDownloadSubscriptionConfigurationError(
        'The subscription mode is invalid',
      );
    }
    if (subscription.targetSourceId == null) {
      throw const VideoDownloadSubscriptionConfigurationError(
        'The subscription target source is unavailable',
      );
    }
    if (subscription.backendProfileId?.trim().isEmpty != false ||
        subscription.category?.trim().isEmpty != false) {
      throw const VideoDownloadSubscriptionConfigurationError(
        'The subscription download backend binding is incomplete',
      );
    }
    if (subscription.organizationPolicy != 'library') {
      throw const VideoDownloadSubscriptionConfigurationError(
        'Legacy organization subscriptions require the legacy scheduler',
      );
    }
    _mediaKind(subscription.mediaKind);
    _discoveryCategory(subscription);
    _subtitlePolicy(subscription.subtitlePolicy);
  }

  Duration _retryDelay(
    VideoDownloadSubscriptionRow subscription,
    Object error,
  ) {
    final int exponent = subscription.retryCount.clamp(0, 5);
    final int multiplier = 1 << exponent;
    int milliseconds = checkInterval.inMilliseconds * multiplier;
    final int maximum = const Duration(hours: 6).inMilliseconds;
    if (milliseconds > maximum) milliseconds = maximum;
    if (error is ExternalProviderFailure && error.retryAfter != null) {
      final int requested = error.retryAfter!.inMilliseconds;
      if (requested > milliseconds) milliseconds = requested;
    }
    return Duration(milliseconds: milliseconds);
  }
}

class _SubscriptionCheckOutcome {
  const _SubscriptionCheckOutcome({
    required this.matched,
    required this.hasPersistentJob,
  });

  final bool matched;
  final bool hasPersistentJob;
}

class _SubscriptionLogicalItem {
  const _SubscriptionLogicalItem({
    required this.key,
    this.season,
    this.episode,
  });

  final String key;
  final int? season;
  final int? episode;
}

class _SubscriptionRelease {
  const _SubscriptionRelease(this.candidate, this.logicalItem);

  final VideoResourceCandidate candidate;
  final _SubscriptionLogicalItem logicalItem;
}

class _SubscriptionFilter {
  const _SubscriptionFilter({
    required this.releaseGroups,
    required this.resolutions,
    required this.qualities,
    required this.sources,
    required this.codecs,
    required this.languages,
    required this.categories,
    required this.trusted,
    required this.trustedOnly,
  });

  factory _SubscriptionFilter.parse(
    String raw, {
    required String providerBase,
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw const VideoDownloadSubscriptionConfigurationError(
        'The subscription version filter is invalid',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const VideoDownloadSubscriptionConfigurationError(
        'The subscription version filter is invalid',
      );
    }
    if (decoded.containsKey('strict') && decoded['strict'] != true) {
      throw const VideoDownloadSubscriptionConfigurationError(
        'The subscription version filter must remain strict',
      );
    }
    final List<String> releaseGroups = _filterValues(
      decoded,
      'releaseGroup',
    );
    final List<String> resolutions = _filterValues(decoded, 'resolution');
    final List<String> qualities = _filterValues(decoded, 'quality');
    final List<String> sources = _filterValues(decoded, 'source');
    final List<String> codecs = _filterValues(decoded, 'codec');
    final List<String> languages = <String>{
      ..._filterValues(decoded, 'language'),
      ..._filterValues(decoded, 'languages'),
    }.toList();
    final List<String> categories = <String>{
      ..._filterValues(decoded, 'category'),
      ..._filterValues(decoded, 'nyaaCategory'),
    }.toList();
    final bool? trusted = _optionalBool(decoded, 'trusted');
    final bool? trustedOnly = _optionalBool(decoded, 'trustedOnly');
    if (providerBase == 'nyaa' &&
        (releaseGroups.isEmpty ||
            (resolutions.isEmpty && qualities.isEmpty) ||
            (trusted == null && trustedOnly == null))) {
      throw const VideoDownloadSubscriptionConfigurationError(
        'Nyaa subscriptions require release group, resolution, and trust rules',
      );
    }
    if (providerBase == 'torznab' &&
        releaseGroups.isEmpty &&
        resolutions.isEmpty &&
        qualities.isEmpty &&
        sources.isEmpty &&
        codecs.isEmpty &&
        languages.isEmpty) {
      throw const VideoDownloadSubscriptionConfigurationError(
        'Torznab subscriptions require at least one strict version rule',
      );
    }
    return _SubscriptionFilter(
      releaseGroups: releaseGroups,
      resolutions: resolutions,
      qualities: qualities,
      sources: sources,
      codecs: codecs,
      languages: languages,
      categories: categories,
      trusted: trusted,
      trustedOnly: trustedOnly ?? false,
    );
  }

  final List<String> releaseGroups;
  final List<String> resolutions;
  final List<String> qualities;
  final List<String> sources;
  final List<String> codecs;
  final List<String> languages;
  final List<String> categories;
  final bool? trusted;
  final bool trustedOnly;

  bool matches(VideoResourceCandidate candidate) {
    if (releaseGroups.isNotEmpty &&
        !_matchesExact(releaseGroups, candidate.releaseGroup)) {
      return false;
    }
    if (resolutions.isNotEmpty &&
        !_matchesVersionEvidence(
          resolutions,
          <String?>[candidate.resolution, candidate.title],
        )) {
      return false;
    }
    if (qualities.isNotEmpty &&
        !_matchesVersionEvidence(
          qualities,
          <String?>[candidate.resolution, candidate.title],
        )) {
      return false;
    }
    if (sources.isNotEmpty &&
        !_matchesVersionEvidence(sources, <String?>[candidate.title])) {
      return false;
    }
    if (codecs.isNotEmpty &&
        !_matchesVersionEvidence(codecs, <String?>[candidate.title])) {
      return false;
    }
    if (languages.isNotEmpty &&
        !_matchesVersionEvidence(languages, <String?>[candidate.title])) {
      return false;
    }
    if (categories.isNotEmpty &&
        !_matchesExact(categories, candidate.category)) {
      return false;
    }
    if (trusted != null && candidate.trusted != trusted) return false;
    if (trustedOnly && !candidate.trusted) return false;
    return true;
  }
}

VideoMediaReference _mediaReference(
  VideoDownloadSubscriptionRow subscription,
) {
  final String provider =
      subscription.metadataProvider?.trim().isNotEmpty == true
          ? subscription.metadataProvider!.trim()
          : 'subscription';
  final String mediaId = subscription.externalId?.trim().isNotEmpty == true
      ? subscription.externalId!.trim()
      : subscription.subscriptionId;
  return VideoMediaReference(
    providerId: provider,
    mediaId: mediaId,
    mediaKind: _mediaKind(subscription.mediaKind),
    discoveryCategory: _discoveryCategory(subscription),
    title: subscription.title,
    year: subscription.year,
    season: subscription.season,
    tmdbId: provider == 'tmdb' ? int.tryParse(mediaId) : null,
    anilistId: provider == 'anilist' ? int.tryParse(mediaId) : null,
    bangumiId: provider == 'bangumi' ? int.tryParse(mediaId) : null,
  );
}

VideoMetadataMediaKind _mediaKind(String raw) {
  for (final VideoMetadataMediaKind value in VideoMetadataMediaKind.values) {
    if (value.name == raw) return value;
  }
  throw const VideoDownloadSubscriptionConfigurationError(
    'The subscription media kind is invalid',
  );
}

VideoDiscoveryCategory _discoveryCategory(
  VideoDownloadSubscriptionRow subscription,
) {
  final String? raw = subscription.discoveryCategory;
  for (final VideoDiscoveryCategory value in VideoDiscoveryCategory.values) {
    if (value.name == raw) return value;
  }
  if (_providerBase(subscription.resourceProvider) == 'nyaa') {
    return VideoDiscoveryCategory.anime;
  }
  return _mediaKind(subscription.mediaKind) == VideoMetadataMediaKind.movie
      ? VideoDiscoveryCategory.movie
      : VideoDiscoveryCategory.tv;
}

VideoDownloadSubtitlePolicy _subtitlePolicy(String raw) {
  for (final VideoDownloadSubtitlePolicy value
      in VideoDownloadSubtitlePolicy.values) {
    if (value.name == raw) return value;
  }
  throw const VideoDownloadSubscriptionConfigurationError(
    'The subscription subtitle policy is invalid',
  );
}

_SubscriptionLogicalItem? _logicalItem(
  VideoDownloadSubscriptionRow subscription,
  String title,
) {
  if (_mediaKind(subscription.mediaKind) == VideoMetadataMediaKind.movie) {
    return const _SubscriptionLogicalItem(key: 'movie');
  }
  if (_looksLikeBatch(title)) return null;
  final VideoNameInfo parsed = parseVideoFilename(title);
  final int? episode = parsed.episode;
  final int season = parsed.season ?? subscription.season ?? 1;
  if (episode == null || season <= 0 || episode <= 0) {
    return null;
  }
  if (subscription.season != null && subscription.season != season) {
    return null;
  }
  if (subscription.startAfterEpisode != null) {
    // BUG-1513：新版发现订阅页会用用户选中的 release 集数预填此字段，且不会
    // 另外把该 release 直接入队。旧判断 `episode <= anchor` 因而必然跳过用户
    // 选中的首集（选第 1 集，卡片变成“第 1 集之后”，实际从第 2 集开始）。
    // `library` 是新版持久流水线创建的订阅，字段按“从该集开始”解释；legacy
    // 订阅是在已推送当前种子后创建，仍保持“该集之后”的历史契约。
    final bool inclusiveStart = subscription.organizationPolicy == 'library';
    final bool beforeWindow = inclusiveStart
        ? episode < subscription.startAfterEpisode!
        : episode <= subscription.startAfterEpisode!;
    if (beforeWindow) return null;
  }
  return _SubscriptionLogicalItem(
    key: _episodeKey(season, episode),
    season: season,
    episode: episode,
  );
}

String _episodeKey(int season, int episode) =>
    'S${season.toString().padLeft(2, '0')}'
    'E${episode.toString().padLeft(2, '0')}';

bool _looksLikeBatch(String title) {
  final String normalized = title.toLowerCase();
  if (normalized.contains('batch') ||
      normalized.contains('complete season') ||
      normalized.contains('season pack')) {
    return true;
  }
  return RegExp(
    r'\b(?:E|EP)?\d{1,4}\s*[-~]\s*(?:E|EP)?\d{1,4}\b',
    caseSensitive: false,
  ).hasMatch(title);
}

_SubscriptionRelease? _bestRelease(List<_SubscriptionRelease> releases) {
  if (releases.isEmpty) return null;
  final List<_SubscriptionRelease> sorted = List<_SubscriptionRelease>.of(
    releases,
  )..sort((_SubscriptionRelease a, _SubscriptionRelease b) {
      final VideoResourceCandidate left = a.candidate;
      final VideoResourceCandidate right = b.candidate;
      if (left.trusted != right.trusted) return left.trusted ? -1 : 1;
      final int bySeeders = right.seeders.compareTo(left.seeders);
      if (bySeeders != 0) return bySeeders;
      final int byDate = (right.publishedAt?.millisecondsSinceEpoch ?? 0)
          .compareTo(left.publishedAt?.millisecondsSinceEpoch ?? 0);
      if (byDate != 0) return byDate;
      final int byPriority =
          left.providerPriority.compareTo(right.providerPriority);
      if (byPriority != 0) return byPriority;
      return left.remoteId.compareTo(right.remoteId);
    });
  return sorted.first;
}

_SubscriptionRelease? _findPersistedRelease(
  VideoDownloadSubscriptionItemRow item,
  List<_SubscriptionRelease> releases,
) {
  for (final _SubscriptionRelease release in releases) {
    if (persistedVideoResourceProviderId(release.candidate) ==
            item.resourceProvider &&
        release.candidate.remoteId == item.selectedResourceId) {
      return release;
    }
  }
  return null;
}

int _compareLogicalItemKeys(String left, String right) {
  if (left == 'movie') return right == 'movie' ? 0 : -1;
  if (right == 'movie') return 1;
  return left.compareTo(right);
}

String _providerBase(String providerId) =>
    providerId.trim().toLowerCase().split(':').first;

bool _candidateBelongsToProvider(
  VideoResourceCandidate candidate,
  String selectedProvider,
) {
  final String selected = selectedProvider.trim().toLowerCase();
  final String persisted =
      persistedVideoResourceProviderId(candidate).toLowerCase();
  return selected.contains(':')
      ? selected == persisted
      : selected == candidate.providerId.toLowerCase();
}

bool _failureBelongsToProvider(
  ExternalProviderFailure failure,
  String selectedProvider,
) {
  final String selected = selectedProvider.trim().toLowerCase();
  final String failed = failure.providerId.trim().toLowerCase();
  return selected.contains(':')
      ? failed == selected
      : failed == selected || failed.startsWith('$selected:');
}

List<String> _filterValues(Map<String, dynamic> raw, String key) {
  if (!raw.containsKey(key) || raw[key] == null) return const <String>[];
  final Object value = raw[key]!;
  final Iterable<Object?> values = value is List<Object?>
      ? value
      : value is String
          ? <Object?>[value]
          : throw const VideoDownloadSubscriptionConfigurationError(
              'The subscription version filter is invalid',
            );
  final List<String> result = <String>[];
  for (final Object? item in values) {
    if (item is! String || item.trim().isEmpty) {
      throw const VideoDownloadSubscriptionConfigurationError(
        'The subscription version filter is invalid',
      );
    }
    result.add(item.trim());
  }
  return List<String>.unmodifiable(result);
}

bool? _optionalBool(Map<String, dynamic> raw, String key) {
  if (!raw.containsKey(key) || raw[key] == null) return null;
  final Object value = raw[key]!;
  if (value is bool) return value;
  throw const VideoDownloadSubscriptionConfigurationError(
    'The subscription version filter is invalid',
  );
}

bool _matchesExact(List<String> expected, String? actual) {
  if (actual == null || actual.trim().isEmpty) return false;
  final String foldedActual = _foldExact(actual);
  return expected.any((String value) => _foldExact(value) == foldedActual);
}

String _foldExact(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

bool _matchesVersionEvidence(
  List<String> expected,
  List<String?> evidence,
) {
  for (final String value in expected) {
    final String needle = _canonicalVersionText(value);
    for (final String? source in evidence) {
      if (source == null || source.trim().isEmpty) continue;
      final String haystack = _canonicalVersionText(source);
      if (' $haystack '.contains(' $needle ')) return true;
    }
  }
  return false;
}

String _canonicalVersionText(String value) {
  String normalized = value.toLowerCase();
  normalized = normalized.replaceAll(
    RegExp(r'\b(?:h[ ._-]?265|x265|hevc)\b'),
    ' hevc ',
  );
  normalized = normalized.replaceAll(
    RegExp(r'\b(?:h[ ._-]?264|x264|avc)\b'),
    ' avc ',
  );
  normalized = normalized.replaceAll(
    RegExp(r'\bweb[ ._-]?dl\b'),
    ' webdl ',
  );
  normalized = normalized.replaceAll(
    RegExp(r'\bweb[ ._-]?rip\b'),
    ' webrip ',
  );
  normalized = normalized.replaceAll(
    RegExp(r'\bblu[ ._-]?ray\b'),
    ' bluray ',
  );
  normalized = normalized.replaceAll(
    RegExp(r'\bdual[ ._-]?audio\b'),
    ' dualaudio ',
  );
  normalized = normalized.replaceAll(RegExp(r'\b4k\b'), ' 2160p ');
  return normalized
      .replaceAll(RegExp(r'[^a-z0-9\u3400-\u9fff]+'), ' ')
      .trim()
      .replaceAll(RegExp(r'\s+'), ' ');
}

String _safeSubscriptionError(Object error) {
  if (error is VideoDownloadSubscriptionConfigurationError) {
    return error.message;
  }
  if (error is ExternalProviderFailure) {
    final String provider = _providerBase(error.providerId);
    final String message = redactCredentialsInText(error.message);
    return '$provider ${error.kind.name}: $message';
  }
  return 'subscription check failed';
}

Never _throwSubscriptionError(Object error) {
  if (error is Exception) throw error;
  if (error is Error) throw error;
  throw StateError('subscription check failed');
}
