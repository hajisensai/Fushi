import 'dart:async';

import 'package:hibiki/src/media/tracking/bangumi_api_client.dart';
import 'package:hibiki/src/media/tracking/media_tracking_repository.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:hibiki_core/hibiki_core.dart';

const String kBangumiAccessTokenPref = 'media_tracking_bangumi_access_token';

typedef BangumiApiFactory = BangumiTrackingApi Function(String accessToken);

class MediaTrackingSyncResult {
  const MediaTrackingSyncResult({
    required this.succeeded,
    required this.failed,
    required this.pending,
    this.unauthorized = false,
  });

  final int succeeded;
  final int failed;
  final int pending;
  final bool unauthorized;

  bool get isSuccess => failed == 0 && !unauthorized;
}

/// 将播放/阅读事件先可靠写入本地 outbox，再以单调方式同步到 Bangumi。
///
/// 外部服务不可用时所有调用 fail-open：本地播放、阅读和完成标记不受影响；后续启动或
/// 设置页“立即同步”会重试。同步只会增加远端进度，绝不把较新的远端进度回退。
class MediaTrackingService {
  MediaTrackingService({
    required MediaTrackingRepository repository,
    required PreferencesRepository preferences,
    required String userAgent,
    BangumiApiFactory? apiFactory,
  })  : _repository = repository,
        _preferences = preferences,
        _apiFactory = apiFactory ??
            ((String token) => BangumiApiClient(
                  accessToken: token,
                  userAgent: userAgent,
                ));

  final MediaTrackingRepository _repository;
  final PreferencesRepository _preferences;
  final BangumiApiFactory _apiFactory;

  Future<MediaTrackingSyncResult>? _syncInFlight;
  final Map<String, ({int progress, bool completed})> _lastQueued =
      <String, ({int progress, bool completed})>{};

  String get accessToken =>
      (_preferences.getPref(kBangumiAccessTokenPref, defaultValue: '')
              as String)
          .trim();

  bool get isConfigured => accessToken.isNotEmpty;

  Future<void> setAccessToken(String value) =>
      _preferences.setPref(kBangumiAccessTokenPref, value.trim());

  Future<BangumiUser> validateAccessToken(String token) async {
    final BangumiTrackingApi api = _apiFactory(token.trim());
    try {
      return await api.getMe();
    } finally {
      api.close();
    }
  }

  Future<List<BangumiSubject>> searchSubjects({
    required String keyword,
    required TrackingKind kind,
  }) async {
    final BangumiTrackingApi api = _apiFactory(accessToken);
    try {
      return await api.searchSubjects(
        keyword: keyword,
        subjectType: kind == TrackingKind.anime ? 2 : 1,
      );
    } finally {
      api.close();
    }
  }

  Future<void> recordVideoCompleted({
    required String bookUid,
    int? collectionId,
    required int episodeIndex,
    bool seriesCompleted = false,
  }) async {
    final TrackingMediaType type = collectionId == null
        ? TrackingMediaType.video
        : TrackingMediaType.videoCollection;
    final String key = collectionId?.toString() ?? bookUid;
    await _enqueueAndSync(
      mediaType: type,
      mediaKey: key,
      localProgress: collectionId == null ? 0 : episodeIndex,
      completed: seriesCompleted || collectionId == null,
    );
  }

  Future<void> recordBookProgress({
    required String bookKey,
    required int completedChapterCount,
    required bool completed,
  }) async {
    final MediaTrackingMappingRow? mapping = await _repository.findMapping(
      mediaType: TrackingMediaType.book,
      mediaKey: bookKey,
    );
    if (mapping == null) return;
    final bool isVolume =
        mapping.progressMode == TrackingProgressMode.volume.value;
    if (isVolume && !completed) return;
    await _enqueueAndSync(
      mediaType: TrackingMediaType.book,
      mediaKey: bookKey,
      localProgress: isVolume ? 0 : completedChapterCount,
      completed: completed,
    );
  }

  Future<void> _enqueueAndSync({
    required TrackingMediaType mediaType,
    required String mediaKey,
    required int localProgress,
    required bool completed,
  }) async {
    final String cacheKey = '${mediaType.value}:$mediaKey';
    final ({int progress, bool completed})? previous = _lastQueued[cacheKey];
    if (previous != null &&
        previous.progress >= localProgress &&
        (previous.completed || !completed)) {
      return;
    }
    try {
      final bool mapped = await _repository.enqueueProgress(
        mediaType: mediaType,
        mediaKey: mediaKey,
        localProgress: localProgress,
        completed: completed,
      );
      if (!mapped) return;
      _lastQueued[cacheKey] = (
        progress: localProgress,
        completed: completed || (previous?.completed ?? false),
      );
      unawaited(syncNow());
    } catch (error, stackTrace) {
      ErrorLogService.instance.log(
        'MediaTrackingService.enqueue',
        error,
        stackTrace,
      );
    }
  }

  Future<MediaTrackingSyncResult> syncNow({bool force = false}) {
    final Future<MediaTrackingSyncResult>? running = _syncInFlight;
    if (running != null) return running;
    final Future<MediaTrackingSyncResult> run = _sync(force: force);
    _syncInFlight = run;
    return run.whenComplete(() {
      if (identical(_syncInFlight, run)) _syncInFlight = null;
    });
  }

  Future<MediaTrackingSyncResult> _sync({required bool force}) async {
    if (force) await _repository.retryAllNow();
    if (!isConfigured) {
      return MediaTrackingSyncResult(
        succeeded: 0,
        failed: 0,
        pending: await _repository.pendingCount(),
      );
    }

    final List<PendingTrackingUpdate> updates = await _repository.dueUpdates();
    if (updates.isEmpty) {
      return MediaTrackingSyncResult(
        succeeded: 0,
        failed: 0,
        pending: await _repository.pendingCount(),
      );
    }

    final BangumiTrackingApi api = _apiFactory(accessToken);
    int succeeded = 0;
    int failed = 0;
    bool unauthorized = false;
    try {
      final BangumiUser user = await api.getMe();
      for (final PendingTrackingUpdate update in updates) {
        try {
          await _syncUpdate(api, user, update);
          await _repository.markSucceeded(update.outbox);
          succeeded++;
        } catch (error, stackTrace) {
          await _repository.markFailed(update.outbox, error);
          failed++;
          unauthorized = error is BangumiApiException && error.isUnauthorized;
          ErrorLogService.instance.log(
            'MediaTrackingService.sync',
            error,
            stackTrace,
          );
          if (unauthorized) break;
        }
      }
    } catch (error, stackTrace) {
      unauthorized = error is BangumiApiException && error.isUnauthorized;
      for (final PendingTrackingUpdate update in updates) {
        await _repository.markFailed(update.outbox, error);
      }
      failed = updates.length;
      ErrorLogService.instance.log(
        'MediaTrackingService.authenticate',
        error,
        stackTrace,
      );
    } finally {
      api.close();
    }

    return MediaTrackingSyncResult(
      succeeded: succeeded,
      failed: failed,
      pending: await _repository.pendingCount(),
      unauthorized: unauthorized,
    );
  }

  Future<void> _syncUpdate(
    BangumiTrackingApi api,
    BangumiUser user,
    PendingTrackingUpdate update,
  ) async {
    final MediaTrackingMappingRow mapping = update.mapping;
    final BangumiUserCollection? collection =
        await api.getCollection(user.username, mapping.subjectId);
    if (mapping.progressMode == TrackingProgressMode.episode.value) {
      await _syncEpisodeProgress(api, mapping, update.outbox, collection);
      return;
    }
    await _syncBookProgress(api, mapping, update.outbox, collection);
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
    final List<BangumiEpisode> episodes =
        await api.getMainEpisodes(mapping.subjectId);
    final List<int> completedIds = episodes
        .where((BangumiEpisode episode) => episode.sort <= outbox.progress)
        .map((BangumiEpisode episode) => episode.id)
        .toList(growable: false);
    if (outbox.progress > 0 && completedIds.isEmpty) {
      throw StateError(
        'Bangumi subject ${mapping.subjectId} has no matching main episodes',
      );
    }
    await api.markEpisodesDone(mapping.subjectId, completedIds);
    final double lastMainEpisode = episodes.isEmpty ? 0 : episodes.last.sort;
    if (outbox.completed &&
        outbox.progress >= lastMainEpisode &&
        collection?.type != 2 &&
        collection?.type != 4 &&
        collection?.type != 5) {
      await api.patchCollection(
        mapping.subjectId,
        payload: const <String, dynamic>{'type': 2},
      );
    }
  }

  Future<void> _syncBookProgress(
    BangumiTrackingApi api,
    MediaTrackingMappingRow mapping,
    MediaTrackingOutboxRow outbox,
    BangumiUserCollection? collection,
  ) async {
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
    if (outbox.completed &&
        collection?.type != 2 &&
        collection?.type != 4 &&
        collection?.type != 5) {
      payload['type'] = 2;
    }
    if (collection == null) {
      payload.putIfAbsent('type', () => 3);
      await api.createCollection(mapping.subjectId, payload: payload);
    } else if (payload.isNotEmpty) {
      await api.patchCollection(mapping.subjectId, payload: payload);
    }
  }
}
