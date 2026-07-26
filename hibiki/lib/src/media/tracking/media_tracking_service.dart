import 'dart:async';

import 'package:hibiki/src/media/tracking/bangumi_api_client.dart';
import 'package:hibiki/src/media/tracking/media_tracking_repository.dart';
import 'package:hibiki/src/media/video/scraper/filename_parser.dart';
import 'package:hibiki/src/media/video/scraper/scraper_types.dart';
import 'package:hibiki/src/media/video/scraper/title_normalizer.dart';
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

typedef _PreparedTrackingTitle = ({
  String query,
  int? volumeNumber,
});

final RegExp _trackingVolumeSuffix = RegExp(
  r'\s*[-–—:：]?\s*(?:(?:vol(?:ume)?\.?|第)\s*(\d{1,3})\s*(?:卷|巻)?|(\d{1,3})\s*(?:卷|巻))\s*$',
  caseSensitive: false,
);

_PreparedTrackingTitle _prepareTrackingTitle(String rawTitle) {
  final String title = rawTitle.trim();
  final RegExpMatch? match = _trackingVolumeSuffix.firstMatch(title);
  if (match == null) return (query: title, volumeNumber: null);
  final int? volumeNumber =
      int.tryParse(match.group(1) ?? match.group(2) ?? '');
  final String base = title.substring(0, match.start).trim();
  return (
    query: base.isEmpty ? title : base,
    volumeNumber: volumeNumber,
  );
}

BangumiSubject? _uniqueHighConfidenceSubject(
  String query,
  List<BangumiSubject> subjects,
) {
  if (query.trim().isEmpty || subjects.isEmpty) return null;
  final String normalizedQuery = TitleNormalizer.normalize(query);
  final List<({BangumiSubject subject, double score, bool exact})> scored =
      <({BangumiSubject subject, double score, bool exact})>[
    for (final BangumiSubject subject in subjects)
      (
        subject: subject,
        score: <double>[
          TitleNormalizer.similarity(query, subject.name),
          TitleNormalizer.similarity(query, subject.nameCn),
        ].reduce((double a, double b) => a > b ? a : b),
        exact: <String>[subject.name, subject.nameCn]
            .map(TitleNormalizer.normalize)
            .where((String value) => value.isNotEmpty)
            .contains(normalizedQuery),
      ),
  ]..sort((a, b) => b.score.compareTo(a.score));
  final ({BangumiSubject subject, double score, bool exact}) best =
      scored.first;
  if (best.exact) {
    final int exactMatches = scored
        .where((entry) => entry.exact)
        .map((entry) => entry.subject.id)
        .toSet()
        .length;
    return exactMatches == 1 ? best.subject : null;
  }
  if (best.score < 0.92) return null;
  if (scored.length > 1 && best.score - scored[1].score < 0.08) return null;
  return best.subject;
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
  final Map<String, Future<MediaTrackingMappingRow?>> _autoMappingInFlight =
      <String, Future<MediaTrackingMappingRow?>>{};
  final Map<String, int> _autoMappingMissAt = <String, int>{};

  static const Duration _autoMappingMissRetry = Duration(minutes: 10);

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
    // 已有合集映射属于用户显式配置或旧版自动映射，优先沿用且绝不改写。
    if (collectionId != null) {
      final MediaTrackingMappingRow? collectionMapping =
          await _repository.findMapping(
        mediaType: TrackingMediaType.videoCollection,
        mediaKey: collectionId.toString(),
      );
      if (collectionMapping != null) {
        await _enqueueAndSync(
          mediaType: TrackingMediaType.videoCollection,
          mediaKey: collectionId.toString(),
          localProgress: episodeIndex,
          completed: seriesCompleted,
        );
        return;
      }
    }

    final AutoVideoTrackingSource? source =
        await _repository.loadAutoVideoSource(
      bookUid: bookUid,
      collectionId: collectionId,
    );
    if (source == null) return;
    final int? parsedEpisode =
        FilenameParser.parse(source.videoTitle).episode;
    final int parsedEpisodeNumber = parsedEpisode ?? 0;
    // 文件名已有明确集数时按单文件建映射，避免一个本地合集混入短篇、PV 或多季后，
    // 合集 sortIndex 被误当成 Bangumi 正片集数。无集数的电影/整季文件仍走原合集语义。
    final bool itemScoped = parsedEpisodeNumber > 0;
    final TrackingMediaType type = itemScoped || collectionId == null
        ? TrackingMediaType.video
        : TrackingMediaType.videoCollection;
    final String key =
        type == TrackingMediaType.video ? bookUid : collectionId.toString();
    final MediaTrackingMappingRow? mapping = await _ensureAutoVideoMapping(
      source: source,
      mediaType: type,
      mediaKey: key,
      progressOffset: itemScoped ? parsedEpisodeNumber : 1,
    );
    if (mapping == null) return;
    final int knownEpisodeCount = source.bangumiEpisodeCount ?? 0;
    final bool itemCompletesSeries = itemScoped &&
        knownEpisodeCount > 0 &&
        parsedEpisodeNumber >= knownEpisodeCount;
    await _enqueueAndSync(
      mediaType: type,
      mediaKey: key,
      localProgress: itemScoped || collectionId == null ? 0 : episodeIndex,
      completed: itemScoped
          ? itemCompletesSeries
          : (seriesCompleted || collectionId == null),
    );
  }

  Future<void> recordBookProgress({
    required String bookKey,
    required int completedChapterCount,
    required bool completed,
  }) async {
    final MediaTrackingMappingRow? mapping =
        await _ensureAutoBookMapping(bookKey);
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

  Future<MediaTrackingMappingRow?> _ensureAutoVideoMapping({
    required AutoVideoTrackingSource source,
    required TrackingMediaType mediaType,
    required String mediaKey,
    required int progressOffset,
  }) async {
    final MediaTrackingMappingRow? existing = await _repository.findMapping(
      mediaType: mediaType,
      mediaKey: mediaKey,
    );
    if (existing != null) return existing;
    return _singleFlightAutoMapping(
      '${mediaType.value}:$mediaKey',
      () async {
        final int? scrapedId = source.bangumiSubjectId;
        if (scrapedId != null && scrapedId > 0) {
          return _repository.saveMappingIfAbsent(
            mediaType: mediaType,
            mediaKey: mediaKey,
            mediaTitle: source.mediaTitle,
            kind: TrackingKind.anime,
            subjectId: scrapedId,
            subjectName: source.bangumiSubjectName ?? source.mediaTitle,
            progressMode: TrackingProgressMode.episode,
            progressOffset: progressOffset,
          );
        }
        if (!isConfigured) return null;

        final ParsedMediaName parsed = FilenameParser.parse(source.mediaTitle);
        final String query =
            parsed.title.isEmpty ? source.mediaTitle : parsed.title;
        final List<BangumiSubject> subjects = await searchSubjects(
          keyword: query,
          kind: TrackingKind.anime,
        );
        final BangumiSubject? subject =
            _uniqueHighConfidenceSubject(query, subjects);
        if (subject == null) return null;
        return _repository.saveMappingIfAbsent(
          mediaType: mediaType,
          mediaKey: mediaKey,
          mediaTitle: source.mediaTitle,
          kind: TrackingKind.anime,
          subjectId: subject.id,
          subjectName: subject.displayName,
          progressMode: TrackingProgressMode.episode,
          progressOffset: progressOffset,
        );
      },
    );
  }

  Future<MediaTrackingMappingRow?> _ensureAutoBookMapping(
    String bookKey,
  ) async {
    final MediaTrackingMappingRow? existing = await _repository.findMapping(
      mediaType: TrackingMediaType.book,
      mediaKey: bookKey,
    );
    if (existing != null) return existing;
    if (!isConfigured) return null;
    return _singleFlightAutoMapping(
      '${TrackingMediaType.book.value}:$bookKey',
      () async {
        final AutoBookTrackingSource? source =
            await _repository.loadAutoBookSource(bookKey);
        if (source == null) return null;
        final TrackingKind kind =
            source.format == 'manga' ? TrackingKind.manga : TrackingKind.novel;
        final _PreparedTrackingTitle prepared =
            _prepareTrackingTitle(source.title);
        final List<BangumiSubject> subjects = await searchSubjects(
          keyword: prepared.query,
          kind: kind,
        );
        final BangumiSubject? subject =
            _uniqueHighConfidenceSubject(prepared.query, subjects);
        if (subject == null) return null;
        final bool trackAsVolume =
            kind == TrackingKind.manga || prepared.volumeNumber != null;
        return _repository.saveMappingIfAbsent(
          mediaType: TrackingMediaType.book,
          mediaKey: bookKey,
          mediaTitle: source.title,
          kind: kind,
          subjectId: subject.id,
          subjectName: subject.displayName,
          progressMode: trackAsVolume
              ? TrackingProgressMode.volume
              : TrackingProgressMode.chapter,
          progressOffset: trackAsVolume ? (prepared.volumeNumber ?? 1) : 0,
        );
      },
    );
  }

  Future<MediaTrackingMappingRow?> _singleFlightAutoMapping(
    String key,
    Future<MediaTrackingMappingRow?> Function() resolve,
  ) {
    final Future<MediaTrackingMappingRow?>? running = _autoMappingInFlight[key];
    if (running != null) return running;
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int? missedAt = _autoMappingMissAt[key];
    if (missedAt != null &&
        now - missedAt < _autoMappingMissRetry.inMilliseconds) {
      return Future<MediaTrackingMappingRow?>.value(null);
    }

    Future<MediaTrackingMappingRow?> run() async {
      try {
        final MediaTrackingMappingRow? result = await resolve();
        if (result == null) {
          _autoMappingMissAt[key] = DateTime.now().millisecondsSinceEpoch;
        } else {
          _autoMappingMissAt.remove(key);
        }
        return result;
      } catch (error, stackTrace) {
        _autoMappingMissAt[key] = DateTime.now().millisecondsSinceEpoch;
        ErrorLogService.instance.log(
          'MediaTrackingService.autoMap',
          error,
          stackTrace,
        );
        return null;
      }
    }

    late final Future<MediaTrackingMappingRow?> future;
    future = run().whenComplete(() {
      if (identical(_autoMappingInFlight[key], future)) {
        _autoMappingInFlight.remove(key);
      }
    });
    _autoMappingInFlight[key] = future;
    return future;
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
    if (outbox.completed &&
        outbox.progress >= episodes.length &&
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
