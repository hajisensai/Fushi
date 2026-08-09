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

class VideoDownloadSubscriptionConfigurationError implements Exception {
  const VideoDownloadSubscriptionConfigurationError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// v71 订阅调度器。
///
/// 每次检查先用数据库 lease 独占订阅，再把逻辑集的资源选择写入
/// `video_download_subscription_items`，最后才调用持久下载流水线 enqueue。
/// 因此搜索重试、应用重启和多 worker 都不会把同一 `movie` / `SxxExx`
/// 重复变成下载任务。
class VideoDownloadSubscriptionService {
  VideoDownloadSubscriptionService({
    required this.database,
    required this.resourceRegistry,
    required VideoDownloadSubscriptionEnqueue enqueue,
    String? workerId,
    this.checkInterval = const Duration(minutes: 15),
    this.leaseDuration = const Duration(minutes: 2),
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
  }

  final FushiDatabase database;
  final VideoResourceRegistry resourceRegistry;
  final VideoDownloadSubscriptionEnqueue _enqueue;
  final String workerId;
  final Duration checkInterval;
  final Duration leaseDuration;
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
    final List<String> keys = releasesByItem.keys.toList()
      ..sort(_compareLogicalItemKeys);
    bool hasPersistentJob = false;
    Object? firstError;
    for (final String key in keys) {
      final VideoDownloadSubscriptionItemRow? existing = existingByKey[key];
      if (existing != null &&
          (existing.jobId != null ||
              existing.status == VideoDownloadSubscriptionItemStatus.queued ||
              existing.status ==
                  VideoDownloadSubscriptionItemStatus.processed ||
              existing.status == VideoDownloadSubscriptionItemStatus.skipped)) {
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
    if (item.jobId != null) return true;
    final String providerId = persistedVideoResourceProviderId(candidate);
    final List<VideoDownloadJobRow> jobs =
        await database.getVideoDownloadJobs();
    _ensureLeaseHeld();
    for (final VideoDownloadJobRow job in jobs) {
      if (job.fingerprint == subscription.fingerprint &&
          job.resourceProvider == providerId &&
          job.selectedResourceId == candidate.remoteId) {
        await _markItemQueued(item.id, job.jobId);
        return true;
      }
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
  int? season;
  int? episode;
  final List<RegExpMatch> seasonEpisodeMatches = RegExp(
    r'\bS(\d{1,3})[ ._-]*E(\d{1,4})(?:v\d+)?\b',
    caseSensitive: false,
  ).allMatches(title).toList();
  if (seasonEpisodeMatches.length == 1) {
    season = int.tryParse(seasonEpisodeMatches.single.group(1)!);
    episode = int.tryParse(seasonEpisodeMatches.single.group(2)!);
  } else {
    final List<RegExpMatch> xMatches = RegExp(
      r'\b(\d{1,3})x(\d{1,4})(?:v\d+)?\b',
      caseSensitive: false,
    ).allMatches(title).toList();
    if (xMatches.length == 1) {
      season = int.tryParse(xMatches.single.group(1)!);
      episode = int.tryParse(xMatches.single.group(2)!);
    }
  }
  if (episode == null &&
      _discoveryCategory(subscription) == VideoDiscoveryCategory.anime) {
    final List<RegExpMatch> animeMatches = RegExp(
      r'(?:^|\s)-\s*(\d{1,4})(?:v\d+)?(?=\s*(?:\[|\(|$))',
      caseSensitive: false,
    ).allMatches(title).toList();
    if (animeMatches.length == 1) {
      season = subscription.season ?? 1;
      episode = int.tryParse(animeMatches.single.group(1)!);
    }
  }
  if (season == null || episode == null || season <= 0 || episode <= 0) {
    return null;
  }
  if (subscription.season != null && subscription.season != season) {
    return null;
  }
  if (subscription.startAfterEpisode != null &&
      episode <= subscription.startAfterEpisode!) {
    return null;
  }
  return _SubscriptionLogicalItem(
    key: 'S${season.toString().padLeft(2, '0')}'
        'E${episode.toString().padLeft(2, '0')}',
    season: season,
    episode: episode,
  );
}

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
