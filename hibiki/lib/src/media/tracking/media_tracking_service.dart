import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hibiki/src/media/collections/collection_season_groups.dart'
    show isMultiSeasonGrouped;
import 'package:hibiki/src/media/tracking/bangumi_api_client.dart';
import 'package:hibiki/src/media/tracking/media_tracking_repository.dart';
import 'package:hibiki/src/media/video/scraper/filename_parser.dart';
import 'package:hibiki/src/media/video/scraper/scraper_types.dart';
import 'package:hibiki/src/media/video/scraper/title_normalizer.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:hibiki_core/hibiki_core.dart';

const String kBangumiAccessTokenPref = 'media_tracking_bangumi_access_token';

/// 连接成功时记下的 Bangumi 昵称/用户名。令牌本身不可读回账号，重开 app 后若不存
/// 这一条，UI 就只能显示「已配置」而说不出是谁的账号。
const String kBangumiAccountNamePref = 'media_tracking_bangumi_account_name';

/// 最近一次同步尝试的结果（首页/设置页「上次同步」行的唯一数据源）。
///
/// outbox 行同步成功即删除，成功不留任何痕迹；不落这几条偏好，用户就无法区分
/// 「同步过且没有待办」与「从来没跑过同步」——这正是「看完了没反应」的可观测缺口。
const String kMediaTrackingLastSyncAtPref = 'media_tracking_last_sync_at_v1';
const String kMediaTrackingLastSyncSucceededPref =
    'media_tracking_last_sync_succeeded_v1';
const String kMediaTrackingLastSyncFailedPref =
    'media_tracking_last_sync_failed_v1';
const String kMediaTrackingLastSyncUnauthorizedPref =
    'media_tracking_last_sync_unauthorized_v1';

const String kVideoTrackingReconcileWatermarkPref =
    'media_tracking_video_reconcile_watermark_v1';
const String kBookTrackingReconcileWatermarkPref =
    'media_tracking_book_reconcile_watermark_v1';
const String kGameTrackingReconcileWatermarkPref =
    'media_tracking_game_reconcile_watermark_v1';

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

class MediaTrackingMappingRetryResult {
  const MediaTrackingMappingRetryResult({
    required this.attempted,
    required this.matched,
    this.syncResult,
  });

  final int attempted;
  final int matched;
  final MediaTrackingSyncResult? syncResult;

  bool get matchedAny => matched > 0;
}

/// 一条同步失败的待办（首页/设置页展示「为什么没同步上去」）。
///
/// 带 [mappingId] 是为了让 UI 把错误挂回对应的条目行，而不是另开一段再把标题重复
/// 一遍——同一条目在「失败」和「已关联」里各出现一次，读起来像两个不同的东西。
class MediaTrackingFailure {
  const MediaTrackingFailure({
    required this.mappingId,
    required this.mediaTitle,
    required this.subjectId,
    required this.subjectName,
    required this.attemptCount,
    required this.nextAttemptAt,
    required this.error,
  });

  final int mappingId;
  final String mediaTitle;
  final int subjectId;
  final String subjectName;
  final int attemptCount;
  final int nextAttemptAt;
  final String error;
}

/// 追踪链路的整体可见状态。
///
/// 这条链路的每个失败点原本都是静默的（没令牌→不建映射、标题匹配不唯一→不建映射、
/// 上报失败→只进错误日志），用户端零反馈。本快照把「连没连上、关联了哪些条目、
/// 还有多少没发出去、上次同步什么时候、失败原因是什么」一次性摊开给 UI。
class MediaTrackingStatus {
  const MediaTrackingStatus({
    required this.configured,
    required this.accountName,
    required this.lastSyncAt,
    required this.lastSucceeded,
    required this.lastFailed,
    required this.unauthorized,
    required this.pending,
    required this.mappings,
    required this.unlinked,
    required this.failures,
    required this.automaticMappingMissCount,
    required this.automaticMappingErrors,
  });

  /// 未配置令牌时的空快照（服务未就绪/读库失败的降级值）。
  static const MediaTrackingStatus empty = MediaTrackingStatus(
    configured: false,
    accountName: '',
    lastSyncAt: 0,
    lastSucceeded: 0,
    lastFailed: 0,
    unauthorized: false,
    pending: 0,
    mappings: <MediaTrackingMappingRow>[],
    unlinked: <MediaTrackingUnlinkedItem>[],
    failures: <MediaTrackingFailure>[],
    automaticMappingMissCount: 0,
    automaticMappingErrors: <String>[],
  );

  final bool configured;
  final String accountName;

  /// 最近一次同步尝试的时刻（epoch 毫秒；0 = 从未跑过）。
  final int lastSyncAt;
  final int lastSucceeded;
  final int lastFailed;

  /// 最近一次同步因令牌被拒而中止（令牌过期/被撤销，必须重新连接）。
  final bool unauthorized;

  /// 待同步条数（outbox 行数，含尚未到退避重试时刻的）。
  final int pending;

  /// 用户可见的映射（已滤掉 bookChapter 伴随映射，它不是独立条目）。
  final List<MediaTrackingMappingRow> mappings;

  /// 本地已经看过/读过/设置过游玩状态，但仍没有映射的条目。
  final List<MediaTrackingUnlinkedItem> unlinked;
  final List<MediaTrackingFailure> failures;

  /// 本会话内仍处于 10 分钟自动匹配退避的本地条目数。
  final int automaticMappingMissCount;

  /// 自动匹配请求失败的诊断文本。无候选/低置信度不是异常，因此只计 miss、不伪造错误。
  final List<String> automaticMappingErrors;

  bool get hasNeverSynced => lastSyncAt <= 0;

  bool get hasProblem =>
      unauthorized || failures.isNotEmpty || automaticMappingErrors.isNotEmpty;

  /// 按 mapping id 索引失败原因，供 UI 把错误挂回对应条目行。
  Map<int, MediaTrackingFailure> get failureByMappingId =>
      <int, MediaTrackingFailure>{
        for (final MediaTrackingFailure failure in failures)
          failure.mappingId: failure,
      };

  /// 展示序：有失败的条目排在最前（首页只列前几条，出问题的那条不能被挤下去），
  /// 其余保持 [mappings] 原序（kind → 标题，与设置页一致）。
  List<MediaTrackingMappingRow> get mappingsProblemFirst {
    final Map<int, MediaTrackingFailure> byId = failureByMappingId;
    if (byId.isEmpty) return mappings;
    return <MediaTrackingMappingRow>[
      ...mappings.where((MediaTrackingMappingRow m) => byId.containsKey(m.id)),
      ...mappings.where((MediaTrackingMappingRow m) => !byId.containsKey(m.id)),
    ];
  }
}

typedef _PreparedTrackingTitle = ({
  String query,
  int? volumeNumber,
});

final RegExp _trackingVolumeSuffix = RegExp(
  r'(?:\s*[-–—:：]?\s*(?:(?:vol(?:ume)?\.?|第)\s*(\d{1,3})\s*(?:卷|巻)?|(\d{1,3})\s*(?:卷|巻))|\s+(\d{1,3}))\s*$',
  caseSensitive: false,
);
final RegExp _trackingEditionSuffix = RegExp(
  r'\s*[\(（][^()（）\r\n]{1,48}[\)）]\s*$',
);

_PreparedTrackingTitle _prepareTrackingTitle(String rawTitle) {
  final String title = rawTitle.trim();
  final String withoutEdition =
      title.replaceFirst(_trackingEditionSuffix, '').trim();
  final RegExpMatch? match = _trackingVolumeSuffix.firstMatch(withoutEdition);
  if (match == null) return (query: title, volumeNumber: null);
  final int? volumeNumber =
      int.tryParse(match.group(1) ?? match.group(2) ?? match.group(3) ?? '');
  final String base = withoutEdition.substring(0, match.start).trim();
  return (
    query: base.isEmpty ? title : base,
    volumeNumber: volumeNumber,
  );
}

/// Bangumi 条目类型：1 书籍（含漫画/轻小说）/ 2 动画 / 4 游戏。
int bangumiSubjectTypeOf(TrackingKind kind) => switch (kind) {
      TrackingKind.anime => 2,
      TrackingKind.game => 4,
      TrackingKind.novel || TrackingKind.manga => 1,
    };

BangumiSubject? _uniqueHighConfidenceSubject(
  String query,
  List<BangumiSubject> subjects,
  TrackingKind kind,
) {
  if (query.trim().isEmpty || subjects.isEmpty) return null;
  final List<BangumiSubject> kindMatches = subjects.where((subject) {
    // 动画与游戏在搜索阶段已按 subject type 精确过滤，无需再按 platform 二次筛。
    if (kind == TrackingKind.anime || kind == TrackingKind.game) return true;
    final String platform = subject.platform.toLowerCase();
    if (kind == TrackingKind.manga) {
      return platform.contains('漫画') ||
          platform.contains('manga') ||
          platform.contains('comic');
    }
    return platform.contains('小说') ||
        platform.contains('小説') ||
        platform.contains('novel');
  }).toList(growable: false);
  final List<BangumiSubject> candidates =
      kindMatches.isEmpty ? subjects : kindMatches;
  final String normalizedQuery = TitleNormalizer.normalize(query);
  final List<({BangumiSubject subject, double score, bool exact})> scored =
      <({BangumiSubject subject, double score, bool exact})>[
    for (final BangumiSubject subject in candidates)
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
  bool _syncAgainRequested = false;
  final Map<String, ({int progress, bool completed})> _lastQueued =
      <String, ({int progress, bool completed})>{};
  final Map<String, Future<MediaTrackingMappingRow?>> _autoMappingInFlight =
      <String, Future<MediaTrackingMappingRow?>>{};
  final Map<String, int> _autoMappingMissAt = <String, int>{};
  final Map<String, Future<MediaTrackingMappingRow?> Function()>
      _autoMappingRetry =
      <String, Future<MediaTrackingMappingRow?> Function()>{};
  final Map<String, String> _autoMappingErrors = <String, String>{};

  static const Duration _autoMappingMissRetry = Duration(minutes: 10);

  /// 每次同步结束/连接状态变化后自增，供 UI（首页卡片、设置页）订阅刷新。
  /// 用计数器而不是 ChangeNotifier：外部无法合法调用 `notifyListeners`（@protected）。
  final ValueNotifier<int> _statusRevision = ValueNotifier<int>(0);

  ValueListenable<int> get statusRevision => _statusRevision;

  String get accessToken =>
      (_preferences.getPref(kBangumiAccessTokenPref, defaultValue: '')
              as String)
          .trim();

  bool get isConfigured => accessToken.isNotEmpty;

  /// 已连接账号的显示名（未连接或旧版本连接过但没记过名字时为空串）。
  String get accountName =>
      (_preferences.getPref(kBangumiAccountNamePref, defaultValue: '')
              as String)
          .trim();

  Future<void> setAccessToken(String value) async {
    final String normalized = value.trim();
    final String previous = accessToken;
    await _preferences.setPref(kBangumiAccessTokenPref, normalized);
    if (previous != normalized) {
      // 新账号必须从全部本地已完成事实重新对齐，不能继承旧账号的校正水位。
      await _preferences.setPref(kVideoTrackingReconcileWatermarkPref, 0);
      await _preferences.setPref(kBookTrackingReconcileWatermarkPref, 0);
      await _preferences.setPref(kGameTrackingReconcileWatermarkPref, 0);
      // 账号名属于旧令牌，换令牌后必须失效，否则 UI 会挂着上一个账号的名字。
      await _preferences.setPref(kBangumiAccountNamePref, '');
    }
    _statusRevision.value++;
  }

  Future<BangumiUser> validateAccessToken(String token) async {
    final BangumiTrackingApi api = _apiFactory(token.trim());
    try {
      return await api.getMe();
    } finally {
      api.close();
    }
  }

  /// 校验令牌 → 落盘 → 记住账号名，一步完成「连接」。
  ///
  /// 校验失败时抛出且不写入任何偏好：半连接状态（令牌存了但账号名空着）会让
  /// UI 显示「已连接」而实际每次同步都 401。
  Future<BangumiUser> connect(String token) async {
    final BangumiUser user = await validateAccessToken(token);
    await setAccessToken(token);
    final String name = user.nickname.trim().isEmpty
        ? user.username.trim()
        : user.nickname.trim();
    await _preferences.setPref(kBangumiAccountNamePref, name);
    await _preferences.setPref(kMediaTrackingLastSyncUnauthorizedPref, false);
    _statusRevision.value++;
    return user;
  }

  /// 汇总当前追踪状态（映射 + 待办 + 上次同步结果），给 UI 一次读齐。
  Future<MediaTrackingStatus> loadStatus() async {
    final List<MediaTrackingMappingRow> mappings =
        await _repository.listMappings();
    // 计数走 COUNT(*) 而不是 allPending().length：后者带展示上限（默认 50 行），
    // 待办超过上限时会把「待发送」少报成上限值。
    final int pendingCount = await _repository.pendingCount();
    final List<PendingTrackingUpdate> pending = await _repository.allPending();
    return MediaTrackingStatus(
      configured: isConfigured,
      accountName: accountName,
      lastSyncAt: _intPref(kMediaTrackingLastSyncAtPref),
      lastSucceeded: _intPref(kMediaTrackingLastSyncSucceededPref),
      lastFailed: _intPref(kMediaTrackingLastSyncFailedPref),
      unauthorized: _preferences.getPref(
            kMediaTrackingLastSyncUnauthorizedPref,
            defaultValue: false,
          ) ==
          true,
      pending: pendingCount,
      // bookChapter 是卷映射的伴随行（只负责 ep_status），不是用户建立的独立关联，
      // 与设置页列表同口径地隐藏，避免同一本书显示成两条。
      mappings: mappings
          .where((MediaTrackingMappingRow row) =>
              row.mediaType != TrackingMediaType.bookChapter.value)
          .toList(growable: false),
      unlinked: await _repository.listUnlinkedHistory(),
      failures: <MediaTrackingFailure>[
        for (final PendingTrackingUpdate update in pending)
          if ((update.outbox.lastError ?? '').trim().isNotEmpty)
            MediaTrackingFailure(
              mappingId: update.mapping.id,
              mediaTitle: update.mapping.mediaTitle,
              subjectId: update.mapping.subjectId,
              subjectName: update.mapping.subjectName,
              attemptCount: update.outbox.attemptCount,
              nextAttemptAt: update.outbox.nextAttemptAt,
              error: update.outbox.lastError!.trim(),
            ),
      ],
      automaticMappingMissCount: _autoMappingMissAt.length,
      automaticMappingErrors: _autoMappingErrors.values.toList(growable: false),
    );
  }

  int _intPref(String key) {
    final Object? stored = _preferences.getPref(key, defaultValue: 0);
    return stored is int ? stored : int.tryParse('$stored') ?? 0;
  }

  Future<List<BangumiSubject>> searchSubjects({
    required String keyword,
    required TrackingKind kind,
  }) async {
    final BangumiTrackingApi api = _apiFactory(accessToken);
    try {
      return await api.searchSubjects(
        keyword: keyword,
        subjectType: bangumiSubjectTypeOf(kind),
      );
    } finally {
      api.close();
    }
  }

  /// 拉取当前账号在 Bangumi 标记为「看过」的全部动画收藏。
  ///
  /// 不从本地映射反推：映射只记录 Hibiki 建过的关联，会永久漏掉用户接入 Hibiki
  /// 之前的历史。账号入口必须直接以 Bangumi 收藏列表为真相源。
  Future<List<BangumiWatchedItem>> loadWatchedAnime() async {
    if (!isConfigured) return const <BangumiWatchedItem>[];
    final BangumiTrackingApi api = _apiFactory(accessToken);
    try {
      final BangumiUser user = await api.getMe();
      return api.getWatchedAnime(user.username);
    } finally {
      api.close();
    }
  }

  /// 绕过本会话内自动匹配的 10 分钟 miss 退避，立即重跑所有失败条目。
  ///
  /// 成功建映射后立刻 reconciliation：mapping.updatedAt 会让当前本地权威进度越过
  /// 水位并幂等进入 outbox；失败仍留在 miss/error 状态供首页诊断。
  Future<MediaTrackingMappingRetryResult> retryAutomaticMappings() async {
    final Map<String, Future<MediaTrackingMappingRow?> Function()> retries =
        Map<String, Future<MediaTrackingMappingRow?> Function()>.of(
      _autoMappingRetry,
    );
    int matched = 0;
    for (final MapEntry<String,
        Future<MediaTrackingMappingRow?> Function()> entry in retries.entries) {
      _autoMappingMissAt.remove(entry.key);
      final MediaTrackingMappingRow? mapping =
          await _singleFlightAutoMapping(entry.key, entry.value);
      if (mapping != null) {
        matched++;
        await _enqueueCurrentProgress(mapping);
      }
    }
    if (matched == 0) {
      _statusRevision.value++;
      return MediaTrackingMappingRetryResult(
        attempted: retries.length,
        matched: 0,
      );
    }
    final MediaTrackingSyncResult syncResult = await syncNow(force: true);
    return MediaTrackingMappingRetryResult(
      attempted: retries.length,
      matched: matched,
      syncResult: syncResult,
    );
  }

  /// 保存用户确认的映射后，立即把当前本地权威进度补入 outbox 并尝试同步。
  ///
  /// reconciliation 水位 + outbox 单行合并共同保证同一当前进度不会重复发送。
  Future<MediaTrackingSyncResult> saveManualMappingAndSync({
    required TrackingMediaType mediaType,
    required String mediaKey,
    required String mediaTitle,
    required TrackingKind kind,
    required int subjectId,
    required String subjectName,
    required TrackingProgressMode progressMode,
    required int progressOffset,
  }) async {
    await _repository.saveMapping(
      mediaType: mediaType,
      mediaKey: mediaKey,
      mediaTitle: mediaTitle,
      kind: kind,
      subjectId: subjectId,
      subjectName: subjectName,
      progressMode: progressMode,
      progressOffset: progressOffset,
    );
    final String key = '${mediaType.value}:$mediaKey';
    _autoMappingMissAt.remove(key);
    _autoMappingRetry.remove(key);
    _autoMappingErrors.remove(key);
    final MediaTrackingMappingRow? mapping = await _repository.findMapping(
      mediaType: mediaType,
      mediaKey: mediaKey,
    );
    if (mapping == null) {
      throw StateError('Manual media tracking mapping was not persisted');
    }
    await _enqueueCurrentProgress(mapping);
    return syncNow(force: true);
  }

  /// 读取指定 mapping 的当前权威本地事实并幂等入队，不依赖毫秒水位先后关系。
  Future<void> _enqueueCurrentProgress(MediaTrackingMappingRow mapping) async {
    TrackingMediaType? mediaType;
    for (final TrackingMediaType value in TrackingMediaType.values) {
      if (value.value == mapping.mediaType) {
        mediaType = value;
        break;
      }
    }
    if (mediaType == null) return;
    if (mediaType == TrackingMediaType.video ||
        mediaType == TrackingMediaType.videoCollection) {
      final List<CompletedVideoTrackingProgress> progress =
          await _repository.loadCompletedVideoTrackingProgress(afterMs: -1);
      for (final CompletedVideoTrackingProgress item in progress) {
        if (item.mediaType != mediaType || item.mediaKey != mapping.mediaKey) {
          continue;
        }
        await _repository.enqueueProgress(
          mediaType: item.mediaType,
          mediaKey: item.mediaKey,
          localProgress: item.localProgress,
          completed: item.completed,
        );
      }
      return;
    }
    if (mediaType == TrackingMediaType.book ||
        mediaType == TrackingMediaType.bookChapter) {
      final List<PersistedBookTrackingProgress> progress =
          await _repository.loadPersistedBookTrackingProgress(afterMs: -1);
      for (final PersistedBookTrackingProgress item in progress) {
        if (item.mediaType != mediaType || item.mediaKey != mapping.mediaKey) {
          continue;
        }
        await _repository.enqueueProgress(
          mediaType: item.mediaType,
          mediaKey: item.mediaKey,
          localProgress: item.localProgress,
          completed: item.completed,
        );
      }
      return;
    }
    if (mediaType == TrackingMediaType.game) {
      final List<PersistedGameTrackingStatus> progress =
          await _repository.loadPersistedGameTrackingStatus(afterMs: -1);
      for (final PersistedGameTrackingStatus item in progress) {
        if (item.gameId != mapping.mediaKey) continue;
        await _repository.enqueueProgress(
          mediaType: TrackingMediaType.game,
          mediaKey: item.gameId,
          localProgress: item.status,
          completed: item.status == 2,
          monotonic: false,
        );
      }
    }
  }

  Future<void> recordVideoCompleted({
    required String bookUid,
    int? collectionId,
    required int episodeIndex,
    bool seriesCompleted = false,
  }) async {
    // 多季合集（分组按各集文件名现场派生，≥2 组即算，存量合集零迁移生效）：
    // 「整合集 → 单个 Bangumi 条目」结构性失真——Bangumi 一季一条目，合集下标当
    // 集数会把 S02E01 报成 E13、完结误报给第一季条目。此时绕开合集级映射（保留
    // 不改写，只不再使用），一律走按集通道（季度感知刮削 subject + 文件名季内
    // 集号）。
    bool multiSeason = false;
    if (collectionId != null) {
      multiSeason = isMultiSeasonGrouped(
          await _repository.loadCollectionVideoGroupKeys(collectionId));
    }
    // 已有合集映射属于用户显式配置或旧版自动映射，优先沿用且绝不改写。
    if (collectionId != null && !multiSeason) {
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
    final int? parsedEpisode = FilenameParser.parse(source.videoTitle).episode;
    final int parsedEpisodeNumber = parsedEpisode ?? 0;
    // 文件名已有明确集数时按单文件建映射，避免一个本地合集混入短篇、PV 或多季后，
    // 合集 sortIndex 被误当成 Bangumi 正片集数。无集数的电影/整季文件仍走原合集语义。
    final bool itemScoped = parsedEpisodeNumber > 0;
    // 分季合集里解析不出集号的成员是 PV/特典：不上报，也不给整个多季合集建
    // 一条注定错位的合集级映射。
    if (multiSeason && !itemScoped) return;
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
    final TrackingProgressMode? progressMode =
        TrackingProgressMode.tryParse(mapping.progressMode);
    if (progressMode == null) return;
    final BookTrackingSnapshot snapshot =
        await _repository.loadBookTrackingSnapshot(
      bookKey: bookKey,
      fallbackProgress: completedChapterCount,
    );
    final int? localProgress = resolveBookTrackingLocalProgress(
      format: snapshot.format,
      progressMode: progressMode,
      chapterProgress: snapshot.chapterProgress,
      completed: completed,
    );
    if (localProgress == null) return;
    final bool isVolume = progressMode == TrackingProgressMode.volume;
    final MediaTrackingMappingRow? chapterMapping = isVolume &&
            mapping.kind == TrackingKind.novel.value &&
            snapshot.chapterProgress != null
        ? await _ensureBookChapterMapping(mapping)
        : null;
    await _enqueueAndSync(
      mediaType: TrackingMediaType.book,
      mediaKey: bookKey,
      localProgress: localProgress,
      completed: completed,
    );
    if (chapterMapping == null) return;
    await _enqueueAndSync(
      mediaType: TrackingMediaType.bookChapter,
      mediaKey: bookKey,
      localProgress: snapshot.chapterProgress!,
      // 章节伴随映射只负责 ep_status；整部作品是否读完由主卷映射判断。
      completed: false,
    );
  }

  /// 上报游戏收藏状态。[status] 直接是 Bangumi 收藏 type（1 想玩 / 2 玩过 /
  /// 3 在玩 / 4 搁置 / 5 弃坑），`galgames.playStatus` 的值域与之刻意对齐，无需换算。
  ///
  /// 状态 0（未设置）不上报：用户从没表态过，不能凭空在远端建一条收藏。
  Future<void> recordGameStatus({
    required String gameId,
    required int status,
  }) async {
    if (status < 1 || status > 5) return;
    final MediaTrackingMappingRow? mapping =
        await _ensureAutoGameMapping(gameId);
    if (mapping == null) return;
    await _enqueueAndSync(
      mediaType: TrackingMediaType.game,
      mediaKey: gameId,
      localProgress: status,
      completed: status == 2,
      monotonic: false,
    );
  }

  Future<MediaTrackingMappingRow?> _ensureAutoGameMapping(
    String gameId,
  ) async {
    final MediaTrackingMappingRow? existing = await _repository.findMapping(
      mediaType: TrackingMediaType.game,
      mediaKey: gameId,
    );
    if (existing != null) return existing;
    return _singleFlightAutoMapping(
      '${TrackingMediaType.game.value}:$gameId',
      () async {
        final AutoGameTrackingSource? source =
            await _repository.loadAutoGameSource(gameId);
        if (source == null) return null;
        final int? scrapedId = source.bangumiSubjectId;
        if (scrapedId != null && scrapedId > 0) {
          return _repository.saveMappingIfAbsent(
            mediaType: TrackingMediaType.game,
            mediaKey: gameId,
            mediaTitle: source.name,
            kind: TrackingKind.game,
            subjectId: scrapedId,
            subjectName: source.name,
            progressMode: TrackingProgressMode.status,
            progressOffset: 0,
          );
        }
        if (!isConfigured) return null;
        // 未刮削时只能按名字兜底。游戏的本地名默认取自 exe 文件名，噪声大，
        // 因此沿用与视频/书籍相同的高置信度门槛：匹配不唯一就不建映射，
        // 宁可不同步也不把进度写到别人的条目上；用户可在设置页手工指定。
        final List<BangumiSubject> subjects = await searchSubjects(
          keyword: source.name,
          kind: TrackingKind.game,
        );
        final BangumiSubject? subject = _uniqueHighConfidenceSubject(
          source.name,
          subjects,
          TrackingKind.game,
        );
        if (subject == null) return null;
        return _repository.saveMappingIfAbsent(
          mediaType: TrackingMediaType.game,
          mediaKey: gameId,
          mediaTitle: source.name,
          kind: TrackingKind.game,
          subjectId: subject.id,
          subjectName: subject.displayName,
          progressMode: TrackingProgressMode.status,
          progressOffset: 0,
        );
      },
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
            _uniqueHighConfidenceSubject(query, subjects, TrackingKind.anime);
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
        final BookFormat format = BookFormat.parseOrEpub(source.format);
        final TrackingKind kind = format == BookFormat.manga
            ? TrackingKind.manga
            : TrackingKind.novel;
        final _PreparedTrackingTitle prepared =
            _prepareTrackingTitle(source.title);
        final List<BangumiSubject> subjects = await searchSubjects(
          keyword: prepared.query,
          kind: kind,
        );
        final BangumiSubject? subject =
            _uniqueHighConfidenceSubject(prepared.query, subjects, kind);
        if (subject == null) return null;
        final bool trackAsVolume = format.isPagedImageBook ||
            prepared.volumeNumber != null ||
            subject.volumeCount > 1;
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
          // 用户选择的 PDF 口径是“一本算一卷”：文件名即使带“第 3 卷”也不能据此
          // 推断前两卷已读。漫画仍保留卷号识别；手动映射的 offset 也不会被自动路径覆盖。
          progressOffset: format == BookFormat.pdf
              ? 1
              : (trackAsVolume ? (prepared.volumeNumber ?? 1) : 0),
        );
      },
    );
  }

  Future<MediaTrackingMappingRow?> _ensureBookChapterMapping(
    MediaTrackingMappingRow volumeMapping,
  ) async {
    final MediaTrackingMappingRow? existing = await _repository.findMapping(
      mediaType: TrackingMediaType.bookChapter,
      mediaKey: volumeMapping.mediaKey,
    );
    if (existing != null) return existing;
    if (!isConfigured) return null;
    return _singleFlightAutoMapping(
      '${TrackingMediaType.bookChapter.value}:${volumeMapping.mediaKey}',
      () async {
        final int volumeNumber = volumeMapping.progressOffset;
        int? chapterOffset;
        if (volumeNumber <= 1) {
          chapterOffset = 0;
        } else {
          final BangumiTrackingApi api = _apiFactory(accessToken);
          try {
            final BangumiUser user = await api.getMe();
            final BangumiUserCollection? collection = await api.getCollection(
              user.username,
              volumeMapping.subjectId,
            );
            // 只有远端恰好停在当前卷之前，ep_status 才能作为稳定的累计话数基线。
            // 跳卷或倒回重读时不猜偏移，宁可只同步卷数。
            if (collection?.volumeProgress == volumeNumber - 1) {
              chapterOffset = collection!.episodeProgress;
            }
          } finally {
            api.close();
          }
        }
        if (chapterOffset == null) return null;
        return _repository.saveMappingIfAbsent(
          mediaType: TrackingMediaType.bookChapter,
          mediaKey: volumeMapping.mediaKey,
          mediaTitle: volumeMapping.mediaTitle,
          kind: TrackingKind.novel,
          subjectId: volumeMapping.subjectId,
          subjectName: volumeMapping.subjectName,
          progressMode: TrackingProgressMode.chapter,
          progressOffset: chapterOffset,
        );
      },
    );
  }

  Future<MediaTrackingMappingRow?> _singleFlightAutoMapping(
    String key,
    Future<MediaTrackingMappingRow?> Function() resolve,
  ) {
    _autoMappingRetry[key] = resolve;
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
          _autoMappingErrors.remove(key);
        } else {
          _autoMappingMissAt.remove(key);
          _autoMappingRetry.remove(key);
          _autoMappingErrors.remove(key);
        }
        _statusRevision.value++;
        return result;
      } catch (error, stackTrace) {
        _autoMappingMissAt[key] = DateTime.now().millisecondsSinceEpoch;
        _autoMappingErrors[key] = error.toString();
        _statusRevision.value++;
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
    bool monotonic = true,
  }) async {
    final String cacheKey = '${mediaType.value}:$mediaKey';
    final ({int progress, bool completed})? previous = _lastQueued[cacheKey];
    // 单调事件按“没有前进就不必重复入队”去重；离散状态只在值真的没变时才跳过，
    // 否则状态回退（弃坑→在玩）会被这层内存缓存吃掉，连 outbox 都进不去。
    final bool unchanged = previous != null &&
        (monotonic
            ? (previous.progress >= localProgress &&
                (previous.completed || !completed))
            : (previous.progress == localProgress &&
                previous.completed == completed));
    if (unchanged) return;
    try {
      final bool mapped = await _repository.enqueueProgress(
        mediaType: mediaType,
        mediaKey: mediaKey,
        localProgress: localProgress,
        completed: completed,
        monotonic: monotonic,
      );
      if (!mapped) return;
      _lastQueued[cacheKey] = (
        progress: localProgress,
        completed: monotonic
            ? (completed || (previous?.completed ?? false))
            : completed,
      );
      if (_syncInFlight == null) {
        unawaited(syncNow());
      } else {
        _syncAgainRequested = true;
      }
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
    final Future<MediaTrackingSyncResult> run = _syncUntilSettled(force: force);
    _syncInFlight = run;
    return run.whenComplete(() {
      if (!identical(_syncInFlight, run)) return;
      _syncInFlight = null;
    });
  }

  Future<MediaTrackingSyncResult> _syncUntilSettled({
    required bool force,
  }) async {
    MediaTrackingSyncResult result = await _reconcileAndSync(force: force);
    while (_syncAgainRequested) {
      _syncAgainRequested = false;
      result = await _reconcileAndSync(force: false);
    }
    await _persistSyncOutcome(result);
    return result;
  }

  /// 把本轮同步结果落成可见状态。未配置令牌时不写「上次同步」（那一轮什么都没发，
  /// 记上去会让 UI 谎报同步过），但仍要通知 UI 刷新待办计数。
  Future<void> _persistSyncOutcome(MediaTrackingSyncResult result) async {
    if (isConfigured) {
      try {
        await _preferences.setPref(
          kMediaTrackingLastSyncAtPref,
          DateTime.now().millisecondsSinceEpoch,
        );
        await _preferences.setPref(
          kMediaTrackingLastSyncSucceededPref,
          result.succeeded,
        );
        await _preferences.setPref(
          kMediaTrackingLastSyncFailedPref,
          result.failed,
        );
        await _preferences.setPref(
          kMediaTrackingLastSyncUnauthorizedPref,
          result.unauthorized,
        );
      } catch (error, stackTrace) {
        // fail-open：状态记录失败不能影响已经发出去的同步结果本身。
        ErrorLogService.instance.log(
          'MediaTrackingService.persistOutcome',
          error,
          stackTrace,
        );
      }
    }
    _statusRevision.value++;
  }

  Future<MediaTrackingSyncResult> _reconcileAndSync({
    required bool force,
  }) async {
    await _reconcileCompletedVideoProgress();
    await _reconcilePersistedBookProgress();
    await _reconcileGameStatus();
    return _sync(force: force);
  }

  /// 补发本地已设置但尚未成功上报的游戏收藏状态。
  ///
  /// 正常路径在用户改状态的当下即时入队；这里只兜「当时发不出去」的两类：换账号后
  /// 水位归零的全量重建，以及先设了状态、之后才刮到 Bangumi 条目/才建映射。
  Future<void> _reconcileGameStatus() async {
    if (!isConfigured) return;
    final Object? stored = _preferences.getPref(
      kGameTrackingReconcileWatermarkPref,
      defaultValue: 0,
    );
    final int watermark = stored is int ? stored : int.tryParse('$stored') ?? 0;
    final List<PersistedGameTrackingStatus> statuses =
        await _repository.loadPersistedGameTrackingStatus(afterMs: watermark);

    int nextWatermark = watermark;
    for (final PersistedGameTrackingStatus item in statuses) {
      // 走完整入队路径：没有映射时它会尝试用刮削出的 Bangumi 条目补建。
      await recordGameStatus(gameId: item.gameId, status: item.status);
      nextWatermark =
          item.evidenceAt > nextWatermark ? item.evidenceAt : nextWatermark;
    }
    if (statuses.isEmpty) {
      nextWatermark = DateTime.now().millisecondsSinceEpoch;
    }
    if (nextWatermark != watermark) {
      await _preferences.setPref(
        kGameTrackingReconcileWatermarkPref,
        nextWatermark,
      );
    }
  }

  Future<void> _reconcileCompletedVideoProgress() async {
    if (!isConfigured) return;
    final Object? stored = _preferences.getPref(
      kVideoTrackingReconcileWatermarkPref,
      defaultValue: 0,
    );
    final int watermark = stored is int ? stored : int.tryParse('$stored') ?? 0;
    final List<CompletedVideoTrackingProgress> progress =
        await _repository.loadCompletedVideoTrackingProgress(
      afterMs: watermark,
    );

    int nextWatermark = watermark;
    for (final CompletedVideoTrackingProgress item in progress) {
      await _repository.enqueueProgress(
        mediaType: item.mediaType,
        mediaKey: item.mediaKey,
        localProgress: item.localProgress,
        completed: item.completed,
      );
      nextWatermark =
          item.evidenceAt > nextWatermark ? item.evidenceAt : nextWatermark;
    }
    // 即使当前无完成条目也推进水位；以后完成时间或新 mapping.updatedAt 会越过它。
    if (progress.isEmpty) {
      nextWatermark = DateTime.now().millisecondsSinceEpoch;
    }
    if (nextWatermark != watermark) {
      await _preferences.setPref(
        kVideoTrackingReconcileWatermarkPref,
        nextWatermark,
      );
    }
  }

  Future<void> _reconcilePersistedBookProgress() async {
    if (!isConfigured) return;
    final Object? stored = _preferences.getPref(
      kBookTrackingReconcileWatermarkPref,
      defaultValue: 0,
    );
    final int watermark = stored is int ? stored : int.tryParse('$stored') ?? 0;
    final List<PersistedBookTrackingProgress> progress =
        await _repository.loadPersistedBookTrackingProgress(
      afterMs: watermark,
    );
    int nextWatermark = watermark;
    for (final PersistedBookTrackingProgress item in progress) {
      await _repository.enqueueProgress(
        mediaType: item.mediaType,
        mediaKey: item.mediaKey,
        localProgress: item.localProgress,
        completed: item.completed,
      );
      nextWatermark =
          item.evidenceAt > nextWatermark ? item.evidenceAt : nextWatermark;
    }
    if (progress.isEmpty) {
      nextWatermark = DateTime.now().millisecondsSinceEpoch;
    }
    if (nextWatermark != watermark) {
      await _preferences.setPref(
        kBookTrackingReconcileWatermarkPref,
        nextWatermark,
      );
    }
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
      reachesLastUnit = outbox.completed &&
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
