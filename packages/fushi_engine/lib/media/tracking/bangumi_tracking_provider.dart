import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/bangumi_api_client.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/tracking_entry_plan.dart';
import 'package:fushi_engine/media/tracking/tracking_provider.dart';
import 'package:fushi_engine/media/tracking/tracking_subject_search.dart';

/// Bangumi 条目类型：1 书籍（含漫画/轻小说）/ 2 动画 / 4 游戏。
int bangumiSubjectTypeOf(TrackingKind kind) => switch (kind) {
  TrackingKind.anime => 2,
  TrackingKind.game => 4,
  TrackingKind.novel || TrackingKind.manga => 1,
};

/// Bangumi as a [TrackingProvider].
///
/// The write logic below moved here unchanged from `MediaTrackingService`
/// (`_syncUpdate` and the three writers). The legacy Bangumi auto-mapping
/// (scraped ids + title fallback) stays in the service for now and is only
/// ever run for this provider.
final class BangumiTrackingProvider
    implements TrackingProvider, TrackingSubjectSearch, TrackingEntryReader {
  BangumiTrackingProvider({
    required String Function() accessToken,
    required BangumiTrackingApi Function(String accessToken) apiFactory,
  }) : _accessToken = accessToken,
       _apiFactory = apiFactory;

  final String Function() _accessToken;
  final BangumiTrackingApi Function(String accessToken) _apiFactory;

  static const TrackingProviderCapabilities _capabilities =
      TrackingProviderCapabilities(
        kinds: <TrackingKind>{
          TrackingKind.anime,
          TrackingKind.novel,
          TrackingKind.manga,
          TrackingKind.game,
        },
        progressModes: <TrackingProgressMode>{
          TrackingProgressMode.episode,
          TrackingProgressMode.chapter,
          TrackingProgressMode.volume,
          TrackingProgressMode.status,
        },
      );

  @override
  String get id => kTrackingProviderBangumi;

  @override
  String get displayName => 'Bangumi';

  @override
  String get siteHost => 'bgm.tv';

  @override
  TrackingProviderCapabilities get capabilities => _capabilities;

  @override
  bool get isConfigured => _accessToken().isNotEmpty;

  @override
  Future<TrackingProviderSession> openSession() async {
    final BangumiTrackingApi api = _apiFactory(_accessToken());
    try {
      final BangumiUser user = await api.getMe();
      return _BangumiSession(api, user);
    } catch (_) {
      api.close();
      rethrow;
    }
  }

  @override
  Future<List<TrackingSearchHit>> searchSubjects(
    String query,
    TrackingKind kind,
  ) async {
    final String trimmed = query.trim();
    if (trimmed.isEmpty) return const <TrackingSearchHit>[];
    final BangumiTrackingApi api = _apiFactory(_accessToken());
    try {
      return <TrackingSearchHit>[
        for (final BangumiSubject subject in await api.searchSubjects(
          keyword: trimmed,
          subjectType: bangumiSubjectTypeOf(kind),
        ))
          _hitOf(subject, kind),
      ];
    } finally {
      api.close();
    }
  }

  @override
  Future<TrackingSearchHit?> subjectById(
    int subjectId,
    TrackingKind kind,
  ) async {
    final BangumiTrackingApi api = _apiFactory(_accessToken());
    try {
      final BangumiSubject subject = await api.getSubject(subjectId);
      return subject.type == bangumiSubjectTypeOf(kind)
          ? _hitOf(subject, kind)
          : null;
    } on BangumiApiException catch (error) {
      if (error.statusCode == 404) return null;
      rethrow;
    } finally {
      api.close();
    }
  }

  /// The user's collection entry: status from the collection type,
  /// `ep_status` as progress and `vol_status` as volumes.
  @override
  Future<TrackingSiteEntry?> readEntry(int subjectId, TrackingKind kind) async {
    final BangumiTrackingApi api = _apiFactory(_accessToken());
    try {
      final BangumiUser user = await api.getMe();
      final BangumiUserCollection? collection = await api.getCollection(
        user.username,
        subjectId,
      );
      if (collection == null) return null;
      return TrackingSiteEntry(
        status: TrackingEntryStatus.ofPlayStatus(collection.type),
        progress: collection.episodeProgress,
        progressVolume: collection.volumeProgress,
      );
    } finally {
      api.close();
    }
  }

  @override
  Uri? subjectPageUrl(int subjectId, TrackingKind kind) =>
      Uri.parse(BangumiApiClient.subjectUrl(subjectId));

  /// Bangumi keeps manga and novels in one book type, so the kind is the one
  /// searched for.
  static TrackingSearchHit _hitOf(BangumiSubject subject, TrackingKind kind) =>
      TrackingSearchHit(
        subjectId: subject.id,
        name: subject.displayName,
        altName: subject.secondaryName,
        kind: kind,
        episodeCount: subject.episodeCount > 0 ? subject.episodeCount : null,
        finalVolume: subject.volumeCount > 0 ? subject.volumeCount : null,
      );

  @override
  TrackingFailureKind classify(Object error) {
    if (error is BangumiApiException) {
      if (error.isUnauthorized) return TrackingFailureKind.unauthorized;
      if (error.statusCode == 429) return TrackingFailureKind.rateLimited;
    }
    return TrackingFailureKind.transient;
  }

  @override
  Future<void> push(
    TrackingProviderSession session,
    PendingTrackingUpdate update,
  ) async {
    final _BangumiSession bangumi = session as _BangumiSession;
    final BangumiTrackingApi api = bangumi.api;
    final MediaTrackingMappingRow mapping = update.mapping;
    final BangumiUserCollection? collection = await api.getCollection(
      bangumi.user.username,
      mapping.subjectId,
    );
    if (mapping.progressMode == TrackingProgressMode.status.value) {
      await _syncCollectionStatus(api, mapping, update.outbox, collection);
      return;
    }
    if (mapping.progressMode == TrackingProgressMode.episode.value) {
      await _syncEpisodeProgress(api, mapping, update.outbox, collection);
      return;
    }
    await _syncBookProgress(api, mapping, update.outbox, collection);
  }

  /// 只写收藏状态（游戏条目没有话数/卷数可报）。
  ///
  /// 与观看/阅读进度不同，这里**不套用「已完成不降级」规则**：状态是用户在库页显式
  /// 选定的意图，从「玩过」改回「在玩」或标记「弃坑」都必须如实同步，否则用户会发现
  /// 状态改不回来。单调保护只适用于自动推断出来的进度，不适用于人工选择的状态。
  Future<void> _syncCollectionStatus(
    BangumiTrackingApi api,
    MediaTrackingMappingRow mapping,
    MediaTrackingOutboxRow outbox,
    BangumiUserCollection? collection,
  ) async {
    final int targetType = outbox.progress;
    if (targetType < 1 || targetType > 5) {
      throw StateError(
        'Invalid Bangumi collection type $targetType '
        'for subject ${mapping.subjectId}',
      );
    }
    if (collection == null) {
      await api.createCollection(
        mapping.subjectId,
        payload: <String, dynamic>{'type': targetType},
      );
      return;
    }
    if (collection.type == targetType) return;
    await api.patchCollection(
      mapping.subjectId,
      payload: <String, dynamic>{'type': targetType},
    );
  }

  Future<void> _syncEpisodeProgress(
    BangumiTrackingApi api,
    MediaTrackingMappingRow mapping,
    MediaTrackingOutboxRow outbox,
    BangumiUserCollection? collection,
  ) async {
    if (collection == null) {
      await api.createCollection(
        mapping.subjectId,
        payload: const <String, dynamic>{'type': 3},
      );
    }
    final List<BangumiEpisode> episodes = await api.getMainEpisodes(
      mapping.subjectId,
    );
    // Bangumi 的 sort 是作品系列全局话数，不保证从 1 开始。例如分割放送的条目
    // 可能返回 51..58；本地 progress 表示该 subject 内第 N 个正片，必须按排序后的
    // 序位取前 N 条，而不能拿 N 与 sort 数值比较。
    final List<int> completedIds = episodes
        .take(outbox.progress)
        .map((BangumiEpisode episode) => episode.id)
        .toList(growable: false);
    if (outbox.progress > 0 && completedIds.isEmpty) {
      throw StateError(
        'Bangumi subject ${mapping.subjectId} has no matching main episodes',
      );
    }
    await api.markEpisodesDone(mapping.subjectId, completedIds);
    // 观看进度与收藏状态必须保持同一语义：
    // - 已经「看过」的条目重看前面集数时不降级；
    // - 本次进度到达该 subject 最后一集即「看过」；
    // - 其余有效进度统一为「在看」，包括原先的想看/搁置/抛弃。
    //
    // collection == null 时上方已经创建为「在看」(3)，只需在最后一集补升为
    // 「看过」(2)；已有收藏则仅在目标状态不同后 PATCH。
    final bool reachesLastEpisode =
        episodes.isNotEmpty && outbox.progress >= episodes.length;
    final int currentType = collection?.type ?? 3;
    final int targetType = currentType == 2 || reachesLastEpisode ? 2 : 3;
    if (currentType != targetType) {
      await api.patchCollection(
        mapping.subjectId,
        payload: <String, dynamic>{'type': targetType},
      );
    }
  }

  Future<void> _syncBookProgress(
    BangumiTrackingApi api,
    MediaTrackingMappingRow mapping,
    MediaTrackingOutboxRow outbox,
    BangumiUserCollection? collection,
  ) async {
    final bool isChapterCompanion =
        mapping.mediaType == TrackingMediaType.bookChapter.value;
    final bool isVolume =
        mapping.progressMode == TrackingProgressMode.volume.value;
    final String progressField = isVolume ? 'vol_status' : 'ep_status';
    final int remoteProgress = collection == null
        ? 0
        : (isVolume ? collection.volumeProgress : collection.episodeProgress);
    final Map<String, dynamic> payload = <String, dynamic>{};
    if (outbox.progress > remoteProgress) {
      payload[progressField] = outbox.progress;
    }
    if (isChapterCompanion) {
      if (collection == null) {
        payload['type'] = 3;
        await api.createCollection(mapping.subjectId, payload: payload);
      } else if (payload.isNotEmpty) {
        await api.patchCollection(mapping.subjectId, payload: payload);
      }
      return;
    }

    // 书籍状态与真实阅读语义对齐：
    // - chapter：本地整本完成才是「读过」；
    // - volume：只有已读卷数达到 Bangumi 总卷数才是「读过」，单卷读完仍是「在读」；
    // - 已经「读过」的条目重读不降级，其余任何阅读事件都切为「在读」。
    final bool reachesLastUnit;
    if (isVolume) {
      final BangumiSubject subject = await api.getSubject(mapping.subjectId);
      reachesLastUnit =
          outbox.completed &&
          subject.volumeCount > 0 &&
          outbox.progress >= subject.volumeCount;
    } else if (outbox.completed) {
      final BangumiSubject subject = await api.getSubject(mapping.subjectId);
      reachesLastUnit = subject.volumeCount <= 1;
      if (reachesLastUnit &&
          subject.volumeCount == 1 &&
          (collection?.volumeProgress ?? 0) < 1) {
        payload['vol_status'] = 1;
      }
    } else {
      reachesLastUnit = false;
    }
    final int currentType = collection?.type ?? 3;
    final int targetType = currentType == 2 || reachesLastUnit ? 2 : 3;
    if (currentType != targetType) payload['type'] = targetType;
    if (collection == null) {
      payload['type'] = targetType;
      await api.createCollection(mapping.subjectId, payload: payload);
    } else if (payload.isNotEmpty) {
      await api.patchCollection(mapping.subjectId, payload: payload);
    }
  }
}

final class _BangumiSession implements TrackingProviderSession {
  _BangumiSession(this.api, this.user);

  final BangumiTrackingApi api;
  final BangumiUser user;

  @override
  void close() => api.close();
}
