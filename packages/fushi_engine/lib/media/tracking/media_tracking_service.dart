import 'dart:async';
import 'dart:math' as math;

import 'package:fushi_engine/media/collections/collection_season_groups.dart'
    show isMultiSeasonGrouped;
import 'package:fushi_engine/media/tracking/bangumi_api_client.dart';
import 'package:fushi_engine/media/tracking/bangumi_tracking_provider.dart';
import 'package:fushi_engine/media/tracking/book_tracking_link.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/remote_anime_link.dart';
import 'package:fushi_engine/media/tracking/title_match.dart';
import 'package:fushi_engine/media/tracking/tracking_entry_plan.dart';
import 'package:fushi_engine/media/tracking/tracking_provider.dart';
import 'package:fushi_engine/media/tracking/tracking_subject_search.dart';
import 'package:fushi_engine/media/video/scraper/filename_parser.dart';
import 'package:fushi_engine/media/video/scraper/scraper_types.dart';
import 'package:fushi_engine/media/video/scraper/title_normalizer.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/foundation/engine_notifier.dart';
import 'package:fushi_engine/privacy/media_privacy.dart'
    show MediaPrivacySnapshot;

export 'package:fushi_engine/media/tracking/bangumi_tracking_provider.dart'
    show bangumiSubjectTypeOf;

/// Whether media tracking is on in the host (the app's Media tracking module,
/// a host fact the engine cannot read itself). Read on every call.
typedef MediaTrackingSwitch = bool Function();

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

/// 换 Bangumi 令牌（含被清空）后必须归零的「本设备已对账水位」键。
///
/// 换账号 = 本地全部已完成事实都要对新账号重新对齐，继承旧账号的水位会让新账号
/// 永远收不到迁移前看完的条目。写令牌的路径不止设置页一条：互联服务配置也会把
/// host 的令牌落到子设备（[InterconnectServiceConfigSnapshot.applyTo]），所以这
/// 条不变式必须是共享常量，而不是 [MediaTrackingService.setAccessToken] 里的一段
/// 私有代码——否则两条写入路径必然漂开。
const List<String> kBangumiTokenScopedWatermarkPrefs = <String>[
  kVideoTrackingReconcileWatermarkPref,
  kBookTrackingReconcileWatermarkPref,
  kGameTrackingReconcileWatermarkPref,
];

/// Preference keys that belong to one tracking provider.
///
/// Bangumi's keys predate this helper and are frozen (existing installs read
/// them), so [forProvider] returns those exact strings for `bangumi`. Every other
/// provider gets `media_tracking_<id>_…_v1`. The token and account-name keys of
/// Bangumi already follow the `media_tracking_<id>_…` pattern.
final class TrackingProviderPrefKeys {
  const TrackingProviderPrefKeys._({
    required this.enabled,
    required this.accountName,
    required this.lastSyncAt,
    required this.lastSyncSucceeded,
    required this.lastSyncFailed,
    required this.lastSyncUnauthorized,
    required this.videoWatermark,
    required this.bookWatermark,
    required this.gameWatermark,
    required this.providerId,
  });

  factory TrackingProviderPrefKeys.forProvider(String providerId) {
    if (providerId == kTrackingProviderBangumi) {
      return const TrackingProviderPrefKeys._(
        providerId: kTrackingProviderBangumi,
        enabled: 'media_tracking_bangumi_enabled',
        accountName: kBangumiAccountNamePref,
        lastSyncAt: kMediaTrackingLastSyncAtPref,
        lastSyncSucceeded: kMediaTrackingLastSyncSucceededPref,
        lastSyncFailed: kMediaTrackingLastSyncFailedPref,
        lastSyncUnauthorized: kMediaTrackingLastSyncUnauthorizedPref,
        videoWatermark: kVideoTrackingReconcileWatermarkPref,
        bookWatermark: kBookTrackingReconcileWatermarkPref,
        gameWatermark: kGameTrackingReconcileWatermarkPref,
      );
    }
    final String p = 'media_tracking_$providerId';
    return TrackingProviderPrefKeys._(
      providerId: providerId,
      enabled: '${p}_enabled',
      accountName: '${p}_account_name',
      lastSyncAt: '${p}_last_sync_at_v1',
      lastSyncSucceeded: '${p}_last_sync_succeeded_v1',
      lastSyncFailed: '${p}_last_sync_failed_v1',
      lastSyncUnauthorized: '${p}_last_sync_unauthorized_v1',
      videoWatermark: '${p}_video_reconcile_watermark_v1',
      bookWatermark: '${p}_book_reconcile_watermark_v1',
      gameWatermark: '${p}_game_reconcile_watermark_v1',
    );
  }

  final String providerId;

  /// Provider on/off. Missing = on. Off = no new events queued, no sync, no
  /// automatic links; existing links and pending rows are kept.
  final String enabled;
  final String accountName;
  final String lastSyncAt;
  final String lastSyncSucceeded;
  final String lastSyncFailed;
  final String lastSyncUnauthorized;
  final String videoWatermark;
  final String bookWatermark;
  final String gameWatermark;

  /// Per-kind on/off for this provider. Missing = on.
  String kindEnabled(TrackingKind kind) =>
      'media_tracking_${providerId}_${kind.value}_enabled';

  /// When this kind was last switched off (ms), so switching it back on only
  /// replays what happened since.
  String kindDisabledAt(TrackingKind kind) =>
      'media_tracking_${providerId}_${kind.value}_disabled_at_v1';

  /// The reconcile watermark that covers [kind].
  String watermarkFor(TrackingKind kind) => switch (kind) {
    TrackingKind.anime => videoWatermark,
    TrackingKind.novel || TrackingKind.manga => bookWatermark,
    TrackingKind.game => gameWatermark,
  };
}

typedef BangumiApiFactory = BangumiTrackingApi Function(String accessToken);

/// 退避重试定时器工厂（BUG-1647）；生产用真 [Timer]，测试注入假实现以便
/// 确定性地断言「安排了多久后重试」并手动触发到期回调。
typedef TrackingRetryTimerFactory =
    Timer Function(Duration delay, void Function() callback);

class MediaTrackingSyncResult {
  const MediaTrackingSyncResult({
    required this.succeeded,
    required this.failed,
    required this.pending,
    this.unauthorized = false,
    this.byProvider = const <String, MediaTrackingSyncResult>{},
  });

  /// Totals across every provider that ran.
  final int succeeded;
  final int failed;

  /// Outbox rows still waiting, across every provider.
  final int pending;

  /// True when any provider's credentials were rejected in this run.
  final bool unauthorized;

  /// Per-provider results of this run (empty for a per-provider result).
  final Map<String, MediaTrackingSyncResult> byProvider;

  bool get isSuccess => failed == 0 && !unauthorized;
}

/// Sync state of one provider, for UI that lists several providers.
///
/// [MediaTrackingService.loadStatus] keeps returning the Bangumi-shaped
/// [MediaTrackingStatus] that existing screens read.
class MediaTrackingProviderStatus {
  const MediaTrackingProviderStatus({
    required this.providerId,
    required this.enabled,
    required this.configured,
    required this.accountName,
    required this.lastSyncAt,
    required this.lastSucceeded,
    required this.lastFailed,
    required this.unauthorized,
    required this.pending,
    required this.failures,
  });

  final String providerId;
  final bool enabled;
  final bool configured;
  final String accountName;
  final int lastSyncAt;
  final int lastSucceeded;
  final int lastFailed;
  final bool unauthorized;
  final int pending;
  final List<MediaTrackingFailure> failures;
}

/// One anime the account marked watched on a site
/// ([MediaTrackingService.loadWatchedAnime]).
final class TrackingWatchedItem {
  const TrackingWatchedItem({
    required this.subjectId,
    required this.name,
    required this.progress,
    this.coverUrl,
    this.updatedAt,
  });

  final int subjectId;
  final String name;

  /// Episodes watched.
  final int progress;

  /// Null when the site gives no cover (tracking plugins).
  final String? coverUrl;
  final DateTime? updatedAt;
}

/// What the home page shows about tracking, read in one go: every site's
/// state, every link the user can see (on any site) and the local items no
/// site is linked to. Local database and preferences only, no network.
class MediaTrackingHomeSnapshot {
  const MediaTrackingHomeSnapshot({
    required this.sites,
    required this.siteNames,
    required this.mappings,
    required this.unlinked,
    this.inertMappingIds = const <int>{},
    this.mediaServerInertMappingIds = const <int>{},
    this.mediaServerCoverage = MediaServerLibraryCoverage.empty,
  });

  static const MediaTrackingHomeSnapshot empty = MediaTrackingHomeSnapshot(
    sites: <MediaTrackingProviderStatus>[],
    siteNames: <String, String>{},
    mappings: <MediaTrackingMappingRow>[],
    unlinked: <MediaTrackingUnlinkedItem>[],
  );

  /// One entry per registered site, in registry order.
  final List<MediaTrackingProviderStatus> sites;

  /// Site id -> the site's name as shown to the user.
  final Map<String, String> siteNames;

  /// Links on every site, without the `bookChapter` companion rows.
  final List<MediaTrackingMappingRow> mappings;

  /// Local items with progress that no site is linked to.
  final List<MediaTrackingUnlinkedItem> unlinked;

  /// Links in [mappings] that can never send
  /// ([MediaTrackingRepository.inertMappingIds]).
  final Set<int> inertMappingIds;

  /// The part of [inertMappingIds] that is a library link of a row added
  /// from a media server (tracked by its server identity instead).
  final Set<int> mediaServerInertMappingIds;

  /// The server identities that track library rows added from a media
  /// server ([MediaTrackingRepository.loadMediaServerLibraryCoverage]).
  final MediaServerLibraryCoverage mediaServerCoverage;
}

/// How to undo one hand link ([MediaTrackingService.undoLink]): the site's
/// links just before and just after it.
final class TrackingLinkUndo {
  const TrackingLinkUndo({
    required this.providerId,
    required this.before,
    required this.after,
  });

  final String providerId;
  final TrackingLinkState before;
  final TrackingLinkState after;

  /// The links the hand link added or changed (their queued updates are
  /// the ones held for the Undo window).
  Set<int> get changedMappingIds => <int>{
    for (final MapEntry<int, MediaTrackingMappingRow> entry
        in after.mappings.entries)
      if (before.mappings[entry.key] != entry.value) entry.key,
  };
}

/// How long a hand link's update waits before it is sent
/// ([MediaTrackingService.linkItemToSubjectUndoable]): the Undo window, with
/// room so the page's Undo (shown for [kTrackingLinkUndoVisible]) always
/// ends first and lets it go ([MediaTrackingService.releaseLinkHold]).
const Duration kTrackingLinkUndoHold = Duration(seconds: 20);

/// How long the page offers Undo after a hand link.
const Duration kTrackingLinkUndoVisible = Duration(seconds: 10);

/// A link tracking made by itself ([MediaTrackingService.autoLinks]).
final class TrackingAutoLink {
  const TrackingAutoLink({required this.mapping, required this.siteName});

  /// The new link: local title, site entry, site id.
  final MediaTrackingMappingRow mapping;

  /// The site's name as shown to the user.
  final String siteName;
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

typedef _PreparedTrackingTitle = ({String query, int? volumeNumber});

final RegExp _trackingVolumeSuffix = RegExp(
  r'(?:\s*[-–—:：]?\s*(?:(?:vol(?:ume)?\.?|第)\s*(\d{1,3})\s*(?:卷|巻)?|(\d{1,3})\s*(?:卷|巻))|\s+(\d{1,3}))\s*$',
  caseSensitive: false,
);
final RegExp _trackingEditionSuffix = RegExp(
  r'\s*[\(（][^()（）\r\n]{1,48}[\)）]\s*$',
);

_PreparedTrackingTitle _prepareTrackingTitle(String rawTitle) {
  final String title = rawTitle.trim();
  final String withoutEdition = title
      .replaceFirst(_trackingEditionSuffix, '')
      .trim();
  final RegExpMatch? match = _trackingVolumeSuffix.firstMatch(withoutEdition);
  if (match == null) return (query: title, volumeNumber: null);
  final int? volumeNumber = int.tryParse(
    match.group(1) ?? match.group(2) ?? match.group(3) ?? '',
  );
  final String base = withoutEdition.substring(0, match.start).trim();
  return (query: base.isEmpty ? title : base, volumeNumber: volumeNumber);
}

/// A Bangumi search result as the legacy auto-mapping scores it, from either
/// implementation of the `bangumi` site (built-in API or bundled plugin).
typedef _BangumiCandidate = ({
  int id,
  String displayName,
  List<String> titles,
  bool kindFits,
  int volumeCount,
});

/// The built-in API's subject. Bangumi keeps manga and novels in one book
/// type, so the kind is read from the platform text.
_BangumiCandidate _candidateOfSubject(
  BangumiSubject subject,
  TrackingKind kind,
) {
  final String platform = subject.platform.toLowerCase();
  // 动画与游戏在搜索阶段已按 subject type 精确过滤，无需再按 platform 二次筛。
  final bool kindFits = switch (kind) {
    TrackingKind.anime || TrackingKind.game => true,
    TrackingKind.manga =>
      platform.contains('漫画') ||
          platform.contains('manga') ||
          platform.contains('comic'),
    TrackingKind.novel =>
      platform.contains('小说') ||
          platform.contains('小説') ||
          platform.contains('novel'),
  };
  return (
    id: subject.id,
    displayName: subject.displayName,
    titles: <String>[subject.name, subject.nameCn],
    kindFits: kindFits,
    volumeCount: subject.volumeCount,
  );
}

/// A search hit of the site's [TrackingSubjectSearch] (the bundled plugin).
_BangumiCandidate _candidateOfHit(TrackingSearchHit hit, TrackingKind kind) => (
  id: hit.subjectId,
  displayName: hit.name,
  titles: <String>{hit.name, hit.altName, ...?hit.book?.titles}.toList(),
  kindFits: hit.kind == null || hit.kind == kind,
  volumeCount: hit.finalVolume ?? hit.book?.finalVolume ?? 0,
);

_BangumiCandidate? _uniqueHighConfidenceSubject(
  String query,
  List<_BangumiCandidate> subjects,
  TrackingKind kind,
) {
  if (query.trim().isEmpty || subjects.isEmpty) return null;
  final List<_BangumiCandidate> kindMatches = subjects
      .where((_BangumiCandidate subject) => subject.kindFits)
      .toList(growable: false);
  final List<_BangumiCandidate> candidates = kindMatches.isEmpty
      ? subjects
      : kindMatches;
  final String normalizedQuery = TitleNormalizer.normalize(query);
  final List<({_BangumiCandidate subject, double score, bool exact})> scored =
      <({_BangumiCandidate subject, double score, bool exact})>[
        for (final _BangumiCandidate subject in candidates)
          (
            subject: subject,
            score: <double>[
              for (final String title in subject.titles)
                TitleNormalizer.similarity(query, title),
            ].reduce((double a, double b) => a > b ? a : b),
            exact: subject.titles
                .map(TitleNormalizer.normalize)
                .where((String value) => value.isNotEmpty)
                .contains(normalizedQuery),
          ),
      ]..sort((a, b) => b.score.compareTo(a.score));
  final ({_BangumiCandidate subject, double score, bool exact}) best =
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

/// 将播放/阅读事件先可靠写入本地 outbox，再以单调方式同步到每个已关联的追踪服务
/// （[TrackingProviderRegistry]，Bangumi 在首位）。
///
/// 外部服务不可用时所有调用 fail-open：本地播放、阅读和完成标记不受影响；后续启动或
/// 设置页“立即同步”会重试。同步只会增加远端进度，绝不把较新的远端进度回退。
class MediaTrackingService {
  MediaTrackingService({
    required MediaTrackingRepository repository,
    required PrefStore preferences,
    required String userAgent,
    BangumiApiFactory? apiFactory,
    TrackingRetryTimerFactory? retryTimerFactory,
    List<TrackingProvider> extraProviders = const <TrackingProvider>[],
    bool builtInBangumi = true,
    AnimeCrossIds? animeCrossIds,
    MangaReadProgressResolver? mangaReadProgress,
    BookLinkHintsResolver? bookLinkHints,
    MediaTrackingSwitch? trackingOn,
  }) : _repository = repository,
       _trackingOn = trackingOn ?? _alwaysOn,
       _preferences = preferences,
       _animeCrossIds = animeCrossIds,
       _mangaReadProgress = mangaReadProgress,
       _bookLinkHints = bookLinkHints,
       _apiFactory =
           apiFactory ??
           ((String token) =>
               BangumiApiClient(accessToken: token, userAgent: userAgent)),
       _retryTimerFactory =
           retryTimerFactory ??
           ((Duration delay, void Function() callback) =>
               Timer(delay, callback)) {
    _builtInBangumi = builtInBangumi
        ? BangumiTrackingProvider(
            accessToken: () => accessToken,
            apiFactory: _apiFactory,
          )
        : null;
    _registry = TrackingProviderRegistry(_withBangumiFirst(extraProviders));
  }

  final MediaTrackingRepository _repository;
  final PrefStore _preferences;

  /// The host's tracking switch. Off: nothing is recorded, linked, queued or
  /// sent (the `record*` entry points and [syncNow] return at once, no retry
  /// timer is armed). Links, queued rows, sign-ins and watermarks are kept,
  /// so the first [syncNow] after it is on again catches up through the
  /// reconcile passes (their watermarks did not move while off).
  final MediaTrackingSwitch _trackingOn;

  static bool _alwaysOn() => true;

  /// The host's tracking switch right now (see [_trackingOn]).
  bool get isOn => _trackingOn();
  final BangumiApiFactory _apiFactory;
  final TrackingRetryTimerFactory _retryTimerFactory;

  /// The built-in Dart Bangumi, always first and kept across
  /// [setExtraProviders]. Null when the host serves the `bangumi` site with a
  /// provider of its own (the app's bundled Bangumi plugin, spec
  /// `docs/specs/2026-11-11-bangumi-bundled-plugin.md` §5): then `bangumi` is
  /// only served while that provider is among the extra providers, and is
  /// simply off otherwise (this one never takes over).
  late final BangumiTrackingProvider? _builtInBangumi;

  /// [providers] in order after the built-in Bangumi; without it, a provider
  /// serving `bangumi` is moved to the front (Bangumi first either way).
  List<TrackingProvider> _withBangumiFirst(List<TrackingProvider> providers) {
    final BangumiTrackingProvider? builtIn = _builtInBangumi;
    if (builtIn != null) return <TrackingProvider>[builtIn, ...providers];
    return <TrackingProvider>[
      for (final TrackingProvider provider in providers)
        if (provider.id == kTrackingProviderBangumi) provider,
      for (final TrackingProvider provider in providers)
        if (provider.id != kTrackingProviderBangumi) provider,
    ];
  }

  /// The provider serving the `bangumi` site right now; null when none is
  /// registered (the host's Bangumi plugin is off or not loaded yet).
  TrackingProvider? get _bangumiSite =>
      _registry.byId(kTrackingProviderBangumi);

  /// The built-in Dart Bangumi serves the `bangumi` site.
  bool get _builtInServesBangumi =>
      _builtInBangumi != null && identical(_bangumiSite, _builtInBangumi);

  /// The `bangumi` site is served by the built-in provider (sign-in with an
  /// access token kept in preferences). False where the host serves it with
  /// its bundled plugin: sign-in then goes through the plugin.
  bool get usesBuiltInBangumi => _builtInBangumi != null;

  /// Replaced as a whole by [setExtraProviders], never mutated. Code that
  /// awaits while walking providers holds the list it started with, and
  /// checks [_isRegistered] before calling a provider again.
  late TrackingProviderRegistry _registry;

  /// Offline AniDB / TMDB / TVDB -> AniList / MAL ids, for media server
  /// episodes. Null = only ids the server itself has are used.
  final AnimeCrossIds? _animeCrossIds;

  /// Highest read chapter of an online manga series (app-provided). Null =
  /// manga series report no chapter progress.
  final MangaReadProgressResolver? _mangaReadProgress;

  /// Display title, extra titles and chapter-or-volume for linking a book
  /// (app-provided). Null = only the database row is used.
  final BookLinkHintsResolver? _bookLinkHints;

  /// Every registered provider, Bangumi first.
  TrackingProviderRegistry get providers => _registry;

  /// Replaces every provider except the built-in Bangumi (plugins installed,
  /// enabled, disabled or removed while the app runs). The registry becomes
  /// Bangumi followed by [providers] in order. Without the built-in Bangumi
  /// ([usesBuiltInBangumi] false) a provider in [providers] with id `bangumi`
  /// serves the site and goes first.
  ///
  /// A duplicate id (including `bangumi`) keeps the first provider; the later
  /// ones are not registered and are returned (also in
  /// [TrackingProviderRegistry.ignored]).
  ///
  /// Links, suggestions and queued updates of a removed provider stay in the
  /// database untouched; they are sent again once a provider with that id is
  /// registered. A sync or linking run already going finishes against the
  /// list it started with but never calls a provider that is no longer
  /// registered. Bumps [statusRevision]; requests a sync when a newly
  /// registered provider can send.
  List<TrackingProvider> setExtraProviders(List<TrackingProvider> providers) {
    final TrackingProviderRegistry previous = _registry;
    final TrackingProviderRegistry next = TrackingProviderRegistry.firstWins(
      _withBangumiFirst(providers),
    );
    _registry = next;
    _registryGeneration++;
    // Ids whose provider object changed (added, removed or replaced): their
    // in-memory dedupe and miss caches describe the old object.
    final Set<String> changed = <String>{
      for (final TrackingProvider old in previous.all)
        if (!identical(next.byId(old.id), old)) old.id,
      for (final TrackingProvider now in next.all)
        if (!identical(previous.byId(now.id), now)) now.id,
    };
    _lastQueued.removeWhere(
      (String key, _) => changed.contains(key.split('|').first),
    );
    _bookLinkMissAt.removeWhere(
      (String key, _) => changed.contains(key.split(':').first),
    );
    _statusRevision.value++;
    if (next.all.any(
      (TrackingProvider provider) =>
          changed.contains(provider.id) && _isActive(provider),
    )) {
      _requestSync();
    }
    return next.ignored;
  }

  /// Bumped by [setExtraProviders]; a linking run started under an older
  /// value may lack sites registered since.
  int _registryGeneration = 0;

  /// [provider] is the object registered under its id right now (not removed,
  /// not replaced by a newer instance).
  bool _isRegistered(TrackingProvider provider) =>
      identical(_registry.byId(provider.id), provider);

  bool _boolPref(String key, {required bool defaultValue}) {
    final Object? stored = _preferences.getPref(
      key,
      defaultValue: defaultValue,
    );
    return stored is bool ? stored : defaultValue;
  }

  /// Provider on/off switch (missing = on).
  bool isProviderEnabled(String providerId) => _boolPref(
    TrackingProviderPrefKeys.forProvider(providerId).enabled,
    defaultValue: true,
  );

  /// Per-kind switch for one provider (missing = the provider's default, see
  /// [TrackingProviderCapabilities.isOnByDefault]).
  bool isKindEnabled(String providerId, TrackingKind kind) => _boolPref(
    TrackingProviderPrefKeys.forProvider(providerId).kindEnabled(kind),
    defaultValue:
        _registry.byId(providerId)?.capabilities.isOnByDefault(kind) ?? true,
  );

  /// Turning a provider off keeps its links and pending rows; turning it back
  /// on lets the next sync's reconcile pass send what was missed.
  Future<void> setProviderEnabled(String providerId, bool enabled) async {
    await _preferences.setPref(
      TrackingProviderPrefKeys.forProvider(providerId).enabled,
      enabled,
    );
    _statusRevision.value++;
    if (enabled) _requestSync();
  }

  /// Turning a kind off stops that kind for this provider: nothing new is
  /// queued and rows already waiting stay waiting (not sent, not dropped).
  ///
  /// Turning it back on sends what changed meanwhile: the catch-up compares
  /// each link's local progress with what it last sent ([_catchUp]), not the
  /// whole library (rate limits). The watermark is rewound to the moment it
  /// was switched off (links made before v152 then queue what is newer).
  /// Games are the exception: the game watermark goes back to 0, which starts
  /// over and sends every set status again, overwriting a status changed on
  /// the provider's website (the same as reconnecting Bangumi with a new
  /// token).
  Future<void> setKindEnabled(
    String providerId,
    TrackingKind kind,
    bool enabled,
  ) async {
    final TrackingProviderPrefKeys keys = TrackingProviderPrefKeys.forProvider(
      providerId,
    );
    if (enabled == isKindEnabled(providerId, kind)) return;
    await _preferences.setPref(keys.kindEnabled(kind), enabled);
    if (enabled) {
      final String watermarkKey = keys.watermarkFor(kind);
      final int rewindTo = kind == TrackingKind.game
          ? 0
          : _intPref(keys.kindDisabledAt(kind));
      if (rewindTo < _intPref(watermarkKey)) {
        await _preferences.setPref(watermarkKey, rewindTo);
      }
    } else {
      await _preferences.setPref(
        keys.kindDisabledAt(kind),
        DateTime.now().millisecondsSinceEpoch,
      );
    }
    _statusRevision.value++;
    if (enabled) _requestSync();
  }

  /// Starts a sync, or asks the running one for another round so it sees
  /// changes made after its reconcile step already ran.
  void _requestSync() {
    if (_syncInFlight == null) {
      unawaited(syncNow());
    } else {
      _syncAgainRequested = true;
    }
  }

  /// Kinds [provider] may send right now (supported and switched on).
  Set<TrackingKind> _sendableKinds(TrackingProvider provider) => <TrackingKind>{
    for (final TrackingKind kind in provider.capabilities.kinds)
      if (isKindEnabled(provider.id, kind)) kind,
  };

  /// Registered, enabled and has credentials: may queue, reconcile and send.
  /// Loops that await between providers re-check this per provider, so a
  /// provider removed meanwhile is skipped.
  bool _isActive(TrackingProvider provider) =>
      _isRegistered(provider) &&
      provider.isConfigured &&
      isProviderEnabled(provider.id);

  /// Bangumi may queue events of [kind] (and run its legacy auto-mapping).
  bool _bangumiAcceptsKind(TrackingKind kind) =>
      isProviderEnabled(kTrackingProviderBangumi) &&
      isKindEnabled(kTrackingProviderBangumi, kind);

  /// BUG-1647：退避到期后的自动重试定时器；同一时刻至多一只。
  Timer? _retryTimer;

  Future<MediaTrackingSyncResult>? _syncInFlight;
  bool _syncAgainRequested = false;
  final Map<String, ({int progress, bool completed})> _lastQueued =
      <String, ({int progress, bool completed})>{};
  final Map<String, Future<MediaTrackingMappingRow?>> _autoMappingInFlight =
      <String, Future<MediaTrackingMappingRow?>>{};
  final Map<String, int> _autoMappingMissAt = <String, int>{};
  final Map<String, Future<MediaTrackingMappingRow?> Function()>
  _autoMappingRetry = <String, Future<MediaTrackingMappingRow?> Function()>{};
  final Map<String, String> _autoMappingErrors = <String, String>{};

  static const Duration _autoMappingMissRetry = Duration(minutes: 10);

  /// One linking run per book at a time (see [_linkBook]), with the
  /// [_registryGeneration] it started under.
  final Map<String, ({int generation, Future<Set<String>> future})>
  _bookLinkInFlight =
      <String, ({int generation, Future<Set<String>> future})>{};

  /// `<provider>:<bookKey>` → when linking last found nothing; retried after
  /// [_autoMappingMissRetry] so the search budget is not spent on every page.
  final Map<String, int> _bookLinkMissAt = <String, int>{};

  /// 每次同步结束/连接状态变化后自增，供 UI（首页卡片、设置页）订阅刷新。
  /// 用计数器而不是 ChangeNotifier：外部无法合法调用 `notifyListeners`（@protected）。
  final EngineValueNotifier<int> _statusRevision = EngineValueNotifier<int>(0);

  EngineValueListenable<int> get statusRevision => _statusRevision;

  /// 令牌/账号名被**本服务之外**的路径改写后（互联服务配置导入、Profile 切换）
  /// 通知状态监听者重读。服务本身不缓存令牌（[accessToken] 每次读偏好），所以
  /// 只需要一次 revision bump，不需要重建服务。
  void notifyStatusChanged() => _statusRevision.value++;

  String get accessToken =>
      (_preferences.getPref(kBangumiAccessTokenPref, defaultValue: '')
              as String)
          .trim();

  /// The provider serving `bangumi` has credentials (built-in: a token in
  /// preferences; bundled plugin: signed in). False while no provider serves
  /// it.
  bool get isConfigured => _bangumiSite?.isConfigured ?? false;

  /// 已连接账号的显示名（未连接或旧版本连接过但没记过名字时为空串）。
  String get accountName {
    final TrackingProvider? site = _bangumiSite;
    if (site == null) return '';
    return _accountNameOf(site);
  }

  /// [provider]'s account name: its own when it keeps one
  /// ([TrackingAccountNamed]), else the account-name preference.
  String _accountNameOf(TrackingProvider provider) =>
      provider is TrackingAccountNamed
      ? (provider as TrackingAccountNamed).accountName
      : _stringPref(
          TrackingProviderPrefKeys.forProvider(provider.id).accountName,
        );

  void _requireBuiltInBangumi() {
    if (_builtInBangumi == null) {
      throw StateError(
        'Bangumi is served by its plugin here: sign in through the plugin',
      );
    }
  }

  /// Built-in Bangumi only ([usesBuiltInBangumi]); throws [StateError]
  /// where the bundled plugin serves the site.
  Future<void> setAccessToken(String value) async {
    _requireBuiltInBangumi();
    final String normalized = value.trim();
    final String previous = accessToken;
    await _preferences.setPref(kBangumiAccessTokenPref, normalized);
    if (previous != normalized) {
      // 新账号必须从全部本地已完成事实重新对齐，不能继承旧账号的校正水位。
      for (final String key in kBangumiTokenScopedWatermarkPrefs) {
        await _preferences.setPref(key, 0);
      }
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
  ///
  /// Built-in Bangumi only ([usesBuiltInBangumi]); throws [StateError]
  /// where the bundled plugin serves the site.
  Future<BangumiUser> connect(String token) async {
    _requireBuiltInBangumi();
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

  /// Every site's link of one local item (the link dialog marks the current
  /// entry on the chosen site with it).
  Future<List<MediaTrackingMappingRow>> linksOfItem({
    required TrackingMediaType mediaType,
    required String mediaKey,
  }) => _repository.itemMappings(mediaType: mediaType, mediaKey: mediaKey);

  /// 汇总当前追踪状态（映射 + 待办 + 上次同步结果），给 UI 一次读齐。
  Future<MediaTrackingStatus> loadStatus() async {
    // Bangumi-shaped snapshot (existing screens read these fields); other
    // providers are reported by [loadProviderStatuses].
    const String provider = kTrackingProviderBangumi;
    final List<MediaTrackingMappingRow> mappings = await _repository
        .listMappings(provider: provider);
    // 计数走 COUNT(*) 而不是 allPending().length：后者带展示上限（默认 50 行），
    // 待办超过上限时会把「待发送」少报成上限值。
    final int pendingCount = await _repository.pendingCount(provider: provider);
    final List<PendingTrackingUpdate> pending = await _activePending(provider);
    return MediaTrackingStatus(
      configured: isConfigured,
      accountName: accountName,
      lastSyncAt: _intPref(kMediaTrackingLastSyncAtPref),
      lastSucceeded: _intPref(kMediaTrackingLastSyncSucceededPref),
      lastFailed: _intPref(kMediaTrackingLastSyncFailedPref),
      unauthorized:
          _preferences.getPref(
            kMediaTrackingLastSyncUnauthorizedPref,
            defaultValue: false,
          ) ==
          true,
      pending: pendingCount,
      // bookChapter 是卷映射的伴随行（只负责 ep_status），不是用户建立的独立关联，
      // 与设置页列表同口径地隐藏，避免同一本书显示成两条。
      mappings: mappings
          .where(
            (MediaTrackingMappingRow row) =>
                row.mediaType != TrackingMediaType.bookChapter.value,
          )
          .toList(growable: false),
      // Linked on any site counts (a book on MangaBaka is not "unlinked").
      unlinked: await _linkableUnlinked(),
      failures: _failuresOf(pending),
      automaticMappingMissCount: _autoMappingMissAt.length,
      automaticMappingErrors: _autoMappingErrors.values.toList(growable: false),
    );
  }

  /// Queued rows of [providerId] except those of ignored items (paused, so
  /// their last error is no problem to show).
  Future<List<PendingTrackingUpdate>> _activePending(String providerId) async {
    final List<PendingTrackingUpdate> pending = await _repository.allPending(
      provider: providerId,
    );
    final Set<int> paused = (await _repository.ignoredMappingIds(
      provider: providerId,
    )).toSet();
    if (paused.isEmpty) return pending;
    return <PendingTrackingUpdate>[
      for (final PendingTrackingUpdate update in pending)
        if (!paused.contains(update.mapping.id)) update,
    ];
  }

  // ── Activity ─────────────────────────────────────────────────────────

  /// The local log of sends, newest first (at most
  /// [MediaTrackingRepository.activityLimit] rows; no network).
  Future<List<MediaTrackingActivityRow>> loadActivity() =>
      _repository.listActivity();

  /// Logs one send; a failure to write the log never fails the send.
  Future<void> _logActivity(
    PendingTrackingUpdate update, {
    Object? error,
  }) async {
    try {
      await _repository.logActivity(update, error: error);
    } catch (logError, stackTrace) {
      engineLog.log('MediaTrackingService.activity', logError, stackTrace);
    }
  }

  // ── Do-not-track list ───────────────────────────────────────────────

  /// The do-not-track list, newest first.
  Future<List<MediaTrackingIgnoredRow>> listIgnored() =>
      _repository.listIgnored();

  /// The do-not-track list now (to mark rows "ignored" in the UI).
  Future<TrackingIgnoreIndex> loadIgnoreIndex() =>
      _repository.loadIgnoreIndex();

  /// Which series every local item belongs to ("Don't track the series"
  /// from a member's row).
  Future<TrackingSeriesIndex> loadSeriesIndex() =>
      _repository.loadSeriesIndex();

  /// Puts an item on the do-not-track list: it is never linked by itself,
  /// nothing is queued or sent for it, and it never "needs a link". Its
  /// links stay, paused (queued rows wait). A collection key
  /// (`videoCollection` / `bookCollection`) covers every member, also ones
  /// added later; a media server season (`remoteSeries`) covers its
  /// episodes, also the ones linked from the server's ids. The remembered
  /// episodes of a season stay (hidden while ignored), so "Track again"
  /// brings them back.
  Future<void> ignoreItem({
    required TrackingMediaType mediaType,
    required String mediaKey,
    required String mediaTitle,
    TrackingKind? kind,
  }) async {
    await _repository.addIgnored(
      mediaType: mediaType,
      mediaKey: mediaKey,
      mediaTitle: mediaTitle,
      kind: kind,
    );
    _lastQueued.clear();
    _statusRevision.value++;
  }

  /// Takes an item off the do-not-track list. Every link it paused gets its
  /// current local progress queued again (progress made meanwhile was never
  /// queued), then a sync is requested.
  Future<void> trackAgain({
    required String mediaType,
    required String mediaKey,
  }) async {
    final TrackingIgnoreIndex before = await _repository.loadIgnoreIndex();
    await _repository.removeIgnored(mediaType: mediaType, mediaKey: mediaKey);
    final TrackingIgnoreIndex after = await _repository.loadIgnoreIndex();
    _statusRevision.value++;
    if (!isOn) return;
    bool queued = false;
    for (final MediaTrackingMappingRow mapping
        in await _repository.listMappings()) {
      if (!before.covers(mapping.mediaType, mapping.mediaKey) ||
          after.covers(mapping.mediaType, mapping.mediaKey)) {
        continue;
      }
      await _enqueueCurrentProgress(mapping);
      queued = true;
    }
    if (queued) _requestSync();
  }

  /// [mediaType] + [mediaKey] (or one of [alsoKeys], `type` + `key`) is on
  /// the do-not-track list, directly or through its collection.
  Future<bool> _isIgnored(
    TrackingMediaType mediaType,
    String mediaKey, {
    List<(TrackingMediaType, String)> alsoKeys =
        const <(TrackingMediaType, String)>[],
  }) async {
    final TrackingIgnoreIndex ignored = await _repository.loadIgnoreIndex();
    if (ignored.isEmpty) return false;
    if (ignored.covers(mediaType.value, mediaKey)) return true;
    for (final (TrackingMediaType type, String key) in alsoKeys) {
      if (ignored.covers(type.value, key)) return true;
    }
    return false;
  }

  static List<MediaTrackingFailure> _failuresOf(
    List<PendingTrackingUpdate> pending,
  ) => <MediaTrackingFailure>[
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
  ];

  String _stringPref(String key) {
    final Object? stored = _preferences.getPref(key, defaultValue: '');
    return stored is String ? stored.trim() : '';
  }

  int _intPref(String key) {
    final Object? stored = _preferences.getPref(key, defaultValue: 0);
    return stored is int ? stored : int.tryParse('$stored') ?? 0;
  }

  /// One snapshot per registered provider, in registry order.
  Future<List<MediaTrackingProviderStatus>> loadProviderStatuses() async {
    final List<MediaTrackingProviderStatus> result =
        <MediaTrackingProviderStatus>[];
    for (final TrackingProvider provider in _registry.all) {
      final TrackingProviderPrefKeys keys =
          TrackingProviderPrefKeys.forProvider(provider.id);
      final List<PendingTrackingUpdate> pending = await _activePending(
        provider.id,
      );
      result.add(
        MediaTrackingProviderStatus(
          providerId: provider.id,
          enabled: isProviderEnabled(provider.id),
          configured: provider.isConfigured,
          accountName: _accountNameOf(provider),
          lastSyncAt: _intPref(keys.lastSyncAt),
          lastSucceeded: _intPref(keys.lastSyncSucceeded),
          lastFailed: _intPref(keys.lastSyncFailed),
          unauthorized: _boolPref(
            keys.lastSyncUnauthorized,
            defaultValue: false,
          ),
          pending: await _repository.pendingCount(provider: provider.id),
          failures: _failuresOf(pending),
        ),
      );
    }
    return result;
  }

  /// The home page's view of tracking; see [MediaTrackingHomeSnapshot].
  Future<MediaTrackingHomeSnapshot> loadHomeSnapshot() async {
    final List<MediaTrackingMappingRow> mappings = await _repository
        .listMappings();
    return MediaTrackingHomeSnapshot(
      sites: await loadProviderStatuses(),
      siteNames: <String, String>{
        for (final TrackingProvider provider in _registry.all)
          provider.id: provider.displayName,
      },
      mappings: mappings
          .where(
            (MediaTrackingMappingRow row) =>
                row.mediaType != TrackingMediaType.bookChapter.value,
          )
          .toList(growable: false),
      unlinked: await _linkableUnlinked(),
      inertMappingIds: await _repository.inertMappingIds(),
      mediaServerInertMappingIds: await _repository
          .mediaServerLibraryMappingIds(),
      mediaServerCoverage: await _repository.loadMediaServerLibraryCoverage(),
    );
  }

  /// [mediaType] + [mediaKey] cannot get one link that sends: a video
  /// collection holding more than one season.
  Future<bool> isMultiSeasonCollection(
    TrackingMediaType mediaType,
    String mediaKey,
  ) async {
    if (mediaType != TrackingMediaType.videoCollection) return false;
    final int? id = int.tryParse(mediaKey);
    return id != null && await _repository.isMultiSeasonVideoCollection(id);
  }

  /// Local items with progress and no link that some site could take: a
  /// registered, enabled, signed-in site sends this item's kind (supported
  /// and switched on). A game is not "needs a link" while only anime / manga
  /// sites are connected (night plan decision 4).
  Future<List<MediaTrackingUnlinkedItem>> _linkableUnlinked() async {
    final Set<TrackingKind> kinds = <TrackingKind>{
      for (final TrackingProvider provider in _activeProviders)
        ..._sendableKinds(provider),
    };
    if (kinds.isEmpty) return const <MediaTrackingUnlinkedItem>[];
    return <MediaTrackingUnlinkedItem>[
      for (final MediaTrackingUnlinkedItem item
          in await _repository.listUnlinkedHistory())
        if (kinds.contains(item.kind)) item,
    ];
  }

  /// The legacy auto-mapping's title search on whichever provider serves
  /// `bangumi`: the built-in API (subjects with their platform text), or the
  /// provider's [TrackingSubjectSearch]. Empty while no provider serves it.
  Future<List<_BangumiCandidate>> _searchBangumi({
    required String keyword,
    required TrackingKind kind,
  }) async {
    final TrackingProvider? site = _bangumiSite;
    if (site == null) return const <_BangumiCandidate>[];
    if (_builtInServesBangumi) {
      final BangumiTrackingApi api = _apiFactory(accessToken);
      try {
        return <_BangumiCandidate>[
          for (final BangumiSubject subject in await api.searchSubjects(
            keyword: keyword,
            subjectType: bangumiSubjectTypeOf(kind),
          ))
            _candidateOfSubject(subject, kind),
        ];
      } finally {
        api.close();
      }
    }
    if (site is! TrackingSubjectSearch) return const <_BangumiCandidate>[];
    return <_BangumiCandidate>[
      for (final TrackingSearchHit hit
          in await (site as TrackingSubjectSearch).searchSubjects(
            keyword,
            kind,
          ))
        _candidateOfHit(hit, kind),
    ];
  }

  // ---- Manual links from the Tracking page (one dialog for every site) ----

  /// Sites an item of [kind] can be linked to by hand right now: registered,
  /// enabled, signed in, [kind] switched on, a progress unit for it, and a
  /// way to search. The default site for [kind] first, then registry order.
  List<TrackingProvider> manualLinkSitesFor(TrackingKind kind) {
    final List<TrackingProvider> sites = <TrackingProvider>[
      for (final TrackingProvider provider in _registry.all)
        if (_isActive(provider) &&
            isKindEnabled(provider.id, kind) &&
            _manualUnitFits(provider.capabilities, kind) &&
            _canSearch(provider, kind))
          provider,
    ];
    final List<TrackingProvider> defaults = <TrackingProvider>[
      for (final TrackingProvider site in sites)
        if (site.capabilities.isOnByDefault(kind)) site,
    ];
    return <TrackingProvider>[
      ...defaults,
      for (final TrackingProvider site in sites)
        if (!defaults.contains(site)) site,
    ];
  }

  static bool _manualUnitFits(
    TrackingProviderCapabilities capabilities,
    TrackingKind kind,
  ) => switch (kind) {
    TrackingKind.anime => capabilities.accepts(
      kind,
      TrackingProgressMode.episode,
    ),
    TrackingKind.game => capabilities.accepts(
      kind,
      TrackingProgressMode.status,
    ),
    TrackingKind.manga || TrackingKind.novel =>
      capabilities.accepts(kind, TrackingProgressMode.chapter) ||
          capabilities.accepts(kind, TrackingProgressMode.volume),
  };

  static bool _canSearch(TrackingProvider provider, TrackingKind kind) =>
      provider is TrackingSubjectSearch ||
      (provider is TrackingBookLinker &&
          (kind == TrackingKind.manga || kind == TrackingKind.novel));

  /// The user's search on [providerId] for a work of [kind]: a title, or a
  /// subject id / link to the site. Only works of [kind] come back. Throws
  /// on network trouble.
  Future<List<TrackingSearchHit>> searchSiteSubjects({
    required String providerId,
    required TrackingKind kind,
    required String query,
  }) async {
    final TrackingProvider? provider = _registry.byId(providerId);
    if (provider == null || query.trim().isEmpty) {
      return const <TrackingSearchHit>[];
    }
    final int? id = parseTrackingSubjectInput(provider.siteHost, query);
    bool fits(TrackingSearchHit hit) => hit.kind == null || hit.kind == kind;
    if (provider is TrackingSubjectSearch) {
      final TrackingSubjectSearch search = provider as TrackingSubjectSearch;
      if (id != null) {
        final TrackingSearchHit? hit = await search.subjectById(id, kind);
        return hit != null && fits(hit)
            ? <TrackingSearchHit>[hit]
            : const <TrackingSearchHit>[];
      }
      return <TrackingSearchHit>[
        for (final TrackingSearchHit hit in await search.searchSubjects(
          query,
          kind,
        ))
          if (fits(hit)) hit,
      ];
    }
    if (provider is TrackingBookLinker &&
        (kind == TrackingKind.manga || kind == TrackingKind.novel)) {
      final TrackingBookLinker linker = provider as TrackingBookLinker;
      final List<TrackingBookSubject> found = id != null
          ? <TrackingBookSubject>[?await linker.bookById(id)]
          : await linker.searchBooks(query, kind);
      return <TrackingSearchHit>[
        for (final TrackingBookSubject book in found)
          if (book.kind == kind) TrackingSearchHit.ofBook(book),
      ];
    }
    return const <TrackingSearchHit>[];
  }

  /// The page of [subjectId] on [providerId]; null when the site's
  /// addresses are not known (a plugin without `tracking.subjectUrl`, an
  /// unregistered site).
  Uri? subjectPageUrl(String providerId, int subjectId, TrackingKind kind) {
    final TrackingProvider? provider = _registry.byId(providerId);
    return provider is TrackingSubjectSearch
        ? (provider as TrackingSubjectSearch).subjectPageUrl(subjectId, kind)
        : null;
  }

  /// A book linked through a site that plans book links itself
  /// ([linkBookToSubject]: chapter or volume from the book and the series).
  /// Other links use the unit the caller passes.
  bool plansBookLink(TrackingMediaType mediaType, String providerId) =>
      mediaType == TrackingMediaType.book &&
      providerId != kTrackingProviderBangumi &&
      _registry.byId(providerId) is TrackingBookLinker;

  /// Links a local item to [hit] on [providerId] because the user picked it,
  /// replacing that site's link for the item, then queues the item's current
  /// progress and syncs. Books on a site that [plansBookLink] get the
  /// planned unit (the same rule as the Track sheet); everything else uses
  /// [progressMode] / [progressOffset] (the caller's defaults for the media
  /// type). Returns the sync result; null for planned book links (sent the
  /// same way, the result is not surfaced).
  Future<MediaTrackingSyncResult?> linkItemToSubject({
    required TrackingMediaType mediaType,
    required String mediaKey,
    required String mediaTitle,
    required TrackingKind kind,
    required String providerId,
    required TrackingSearchHit hit,
    required TrackingProgressMode progressMode,
    required int progressOffset,
    BookLinkPlan? bookPlan,
    Duration? holdSend,
  }) async {
    if (hit.kind != null && hit.kind != kind) {
      throw ArgumentError.value(hit.subjectId, 'hit', 'wrong kind');
    }
    final TrackingBookSubject? book = hit.book;
    if (book != null && plansBookLink(mediaType, providerId)) {
      // The latest explicit action wins over an earlier "removed by you".
      await _repository.clearRemovedByUser(
        provider: providerId,
        mediaType: mediaType,
        mediaKey: mediaKey,
      );
      await linkBookToSubject(
        bookKey: mediaKey,
        providerId: providerId,
        subject: book,
        asKind: kind,
        plan: bookPlan,
        holdSend: holdSend,
      );
      return null;
    }
    if (bookPlan != null) {
      progressMode = bookPlan.mode;
      progressOffset = bookPlan.offset;
    }
    final MediaTrackingSyncResult result = await saveManualMappingAndSync(
      mediaType: mediaType,
      mediaKey: mediaKey,
      mediaTitle: mediaTitle,
      kind: kind,
      subjectId: hit.subjectId,
      subjectName: hit.name,
      progressMode: progressMode,
      progressOffset: progressOffset,
      provider: providerId,
      holdSend: holdSend,
    );
    _statusRevision.value++;
    return result;
  }

  /// [linkItemToSubject], and what puts the site's links back as they were
  /// before it ([undoLink]: no link, or the previous one, with what the new
  /// link queued and has not sent withdrawn).
  ///
  /// Nothing reaches the site during the Undo window (T2 G2): the link's
  /// queued update is held for [kTrackingLinkUndoHold] and goes out when the
  /// page lets it go ([releaseLinkHold], [releaseAllLinkHolds]) or when the
  /// hold ends by itself (the retry timer; after a restart, the next sync).
  ///
  /// `held` is true only when this link queued an update that now waits for
  /// the Undo window (a relink to the same entry and number, or a book still
  /// in progress, queues nothing).
  Future<({MediaTrackingSyncResult? result, TrackingLinkUndo undo, bool held})>
  linkItemToSubjectUndoable({
    required TrackingMediaType mediaType,
    required String mediaKey,
    required String mediaTitle,
    required TrackingKind kind,
    required String providerId,
    required TrackingSearchHit hit,
    required TrackingProgressMode progressMode,
    required int progressOffset,
    BookLinkPlan? bookPlan,
  }) async {
    final TrackingLinkState before = await _repository.captureLinkState(
      providerId,
    );
    final MediaTrackingSyncResult? result = await linkItemToSubject(
      mediaType: mediaType,
      mediaKey: mediaKey,
      mediaTitle: mediaTitle,
      kind: kind,
      providerId: providerId,
      hit: hit,
      progressMode: progressMode,
      progressOffset: progressOffset,
      bookPlan: bookPlan,
      holdSend: kTrackingLinkUndoHold,
    );
    final TrackingLinkState after = await _repository.captureLinkState(
      providerId,
    );
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    final bool held = after.outbox.entries.any(
      (MapEntry<int, MediaTrackingOutboxRow> e) =>
          e.value.attemptCount == 0 &&
          e.value.nextAttemptAt > nowMs &&
          before.outbox[e.key] != e.value,
    );
    return (
      result: result,
      held: held,
      undo: TrackingLinkUndo(
        providerId: providerId,
        before: before,
        after: after,
      ),
    );
  }

  /// Undoes a hand link ([linkItemToSubjectUndoable]). Returns true when
  /// the link had already sent something (its hold was let go first); that
  /// stays on the site. False = nothing of it reached the site.
  Future<bool> undoLink(TrackingLinkUndo undo) async {
    final TrackingLinkState now = await _repository.captureLinkState(
      undo.providerId,
    );
    bool alreadySent = false;
    for (final int id in undo.changedMappingIds) {
      final MediaTrackingMappingRow? linked = undo.after.mappings[id];
      final MediaTrackingMappingRow? current = now.mappings[id];
      if (linked == null || current == null) continue;
      if (current.sentProgress != linked.sentProgress ||
          current.sentCompleted != linked.sentCompleted) {
        alreadySent = true;
      }
    }
    await _repository.restoreLinkState(before: undo.before, after: undo.after);
    _statusRevision.value++;
    return alreadySent;
  }

  /// The Undo window of [undo] ended: what the link queued is sent now.
  Future<void> releaseLinkHold(TrackingLinkUndo undo) async {
    await _repository.releaseHeld(undo.changedMappingIds);
    _statusRevision.value++;
    if (_syncInFlight != null) _syncAgainRequested = true;
    await syncNow();
  }

  /// Every held hand link goes out now (the page closes, the app goes
  /// away). Held rows not let go here go out when their hold ends.
  Future<void> releaseAllLinkHolds() async {
    await _repository.releaseHeld();
    if (_syncInFlight != null) _syncAgainRequested = true;
    await syncNow();
  }

  /// Removes the link [mapping] by hand (the Tracking page). Like the Track
  /// sheet's [unlinkBook] for every kind (T2 G7): the item is never linked
  /// to that site by itself again (not from the server's ids, a scraped id
  /// or its title); only a hand link brings it back. What was sent stays on
  /// the site.
  Future<void> removeLink(MediaTrackingMappingRow mapping) async {
    if (mapping.mediaType == TrackingMediaType.book.value) {
      await unlinkBook(bookKey: mapping.mediaKey, providerId: mapping.provider);
      return;
    }
    final TrackingMediaType? type = _mediaTypeOf(mapping.mediaType);
    await _repository.deleteMapping(mapping.id);
    if (type != null) {
      await _repository.rejectSubject(
        provider: mapping.provider,
        mediaType: type,
        mediaKey: mapping.mediaKey,
        subjectId: mapping.subjectId,
        subjectName: mapping.subjectName,
        subjectKind: mapping.kind,
      );
    }
    _statusRevision.value++;
  }

  static TrackingMediaType? _mediaTypeOf(String value) {
    for (final TrackingMediaType type in TrackingMediaType.values) {
      if (type.value == value) return type;
    }
    return null;
  }

  /// The user removed [provider]'s link of this item ([removeLink]):
  /// automatic linking leaves it alone.
  Future<bool> _removedByUser(
    String provider,
    TrackingMediaType mediaType,
    String mediaKey,
  ) => _repository.isLinkRemovedByUser(
    provider: provider,
    mediaType: mediaType,
    mediaKey: mediaKey,
  );

  /// [providerId] can list the account's watched (completed) anime: the
  /// built-in Bangumi, or a provider with a [TrackingListReader] that lists
  /// and tracks anime.
  bool canListWatchedAnime(String providerId) {
    final TrackingProvider? provider = _registry.byId(providerId);
    if (provider == null) return false;
    if (identical(provider, _builtInBangumi)) return true;
    return provider is TrackingListReader &&
        (provider as TrackingListReader).canListEntries &&
        provider.capabilities.acceptsKind(TrackingKind.anime);
  }

  /// 拉取当前账号在 [providerId]（默认 Bangumi）标记为「看过」的全部动画收藏。
  ///
  /// 不从本地映射反推：映射只记录 Fushi 建过的关联，会永久漏掉用户接入 Fushi
  /// 之前的历史。账号入口必须直接以站点收藏列表为真相源。The built-in Bangumi
  /// reads its collection API; any other provider its `trackingList`
  /// ([TrackingListReader], status completed). Empty when signed out or the
  /// site cannot list.
  Future<List<TrackingWatchedItem>> loadWatchedAnime({
    String providerId = kTrackingProviderBangumi,
  }) async {
    final TrackingProvider? provider = _registry.byId(providerId);
    if (provider == null ||
        !provider.isConfigured ||
        !canListWatchedAnime(providerId)) {
      return const <TrackingWatchedItem>[];
    }
    if (identical(provider, _builtInBangumi)) {
      final BangumiTrackingApi api = _apiFactory(accessToken);
      try {
        final BangumiUser user = await api.getMe();
        return <TrackingWatchedItem>[
          for (final BangumiWatchedItem item in await api.getWatchedAnime(
            user.username,
          ))
            TrackingWatchedItem(
              subjectId: item.subject.id,
              name: item.subject.displayName,
              coverUrl: item.subject.coverUrl,
              progress: item.episodeProgress,
              updatedAt: item.updatedAt,
            ),
        ];
      } finally {
        api.close();
      }
    }
    return <TrackingWatchedItem>[
      for (final TrackingListItem item
          in await (provider as TrackingListReader).listEntries(
            TrackingKind.anime,
            TrackingEntryStatus.completed,
          ))
        TrackingWatchedItem(
          subjectId: item.subject.subjectId,
          name: item.subject.name,
          progress: item.progress,
          updatedAt: item.updatedAt,
        ),
    ];
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
    for (final MapEntry<String, Future<MediaTrackingMappingRow?> Function()>
        entry
        in retries.entries) {
      _autoMappingMissAt.remove(entry.key);
      final MediaTrackingMappingRow? mapping = await _singleFlightAutoMapping(
        entry.key,
        entry.value,
      );
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
  /// [provider] must be registered and able to track [kind] in [progressMode].
  Future<MediaTrackingSyncResult> saveManualMappingAndSync({
    required TrackingMediaType mediaType,
    required String mediaKey,
    required String mediaTitle,
    required TrackingKind kind,
    required int subjectId,
    required String subjectName,
    required TrackingProgressMode progressMode,
    required int progressOffset,
    String provider = kTrackingProviderBangumi,
    String linkSource = TrackingLinkSource.manual,
    double? confidence,
    Duration? holdSend,
  }) async {
    final TrackingProvider? target = _registry.byId(provider);
    if (target == null) {
      throw ArgumentError.value(provider, 'provider', 'not registered');
    }
    if (!target.capabilities.accepts(kind, progressMode)) {
      throw ArgumentError(
        '$provider cannot track ${kind.value} by ${progressMode.value}',
      );
    }
    // A library row added from a media server is tracked through its server
    // identity: the hand link goes there (its season), and covers the row,
    // its collection and the episodes played from the server alike.
    if ((mediaType == TrackingMediaType.video ||
            mediaType == TrackingMediaType.videoCollection) &&
        await _repository.isMediaServerLibraryItem(mediaType, mediaKey)) {
      final ({TrackingMediaType type, String key}) server =
          await _serverIdentityOf(mediaType, mediaKey);
      return saveManualMappingAndSync(
        mediaType: server.type,
        mediaKey: server.key,
        mediaTitle: mediaTitle,
        kind: kind,
        subjectId: subjectId,
        subjectName: subjectName,
        progressMode: progressMode,
        // A season link sends each episode as its own number.
        progressOffset: server.type == TrackingMediaType.remoteSeries
            ? 1
            : progressOffset,
        provider: provider,
        linkSource: linkSource,
        confidence: confidence,
        holdSend: holdSend,
      );
    }
    // One link for several seasons would be saved and never send.
    if (await isMultiSeasonCollection(mediaType, mediaKey)) {
      throw MultiSeasonCollectionLinkError(mediaKey);
    }
    if (linkSource == TrackingLinkSource.manual) {
      // The latest explicit action wins over an earlier "removed by you".
      await _repository.clearRemovedByUser(
        provider: provider,
        mediaType: mediaType,
        mediaKey: mediaKey,
      );
    }
    await _repository.saveMapping(
      mediaType: mediaType,
      mediaKey: mediaKey,
      mediaTitle: mediaTitle,
      kind: kind,
      subjectId: subjectId,
      subjectName: subjectName,
      progressMode: progressMode,
      progressOffset: progressOffset,
      provider: provider,
      linkSource: linkSource,
      confidence: confidence,
    );
    if (provider == kTrackingProviderBangumi) {
      // The auto-mapping caches only ever describe Bangumi.
      final String key = '${mediaType.value}:$mediaKey';
      _autoMappingMissAt.remove(key);
      _autoMappingRetry.remove(key);
      _autoMappingErrors.remove(key);
    }
    final MediaTrackingMappingRow? mapping = await _repository.findMapping(
      mediaType: mediaType,
      mediaKey: mediaKey,
      provider: provider,
    );
    if (mapping == null) {
      throw StateError('Manual media tracking mapping was not persisted');
    }
    await _enqueueCurrentProgress(mapping);
    if (holdSend != null) {
      await _repository.holdQueued(<int>[
        mapping.id,
      ], DateTime.now().add(holdSend).millisecondsSinceEpoch);
    }
    return syncNow(force: true);
  }

  /// The server key a hand link of library row (or collection) [mediaKey]
  /// added from a media server goes to: its season, else its episode (a
  /// movie, an episode without a season). Throws
  /// [MediaServerLibraryLinkError] while no episode of it is known (nothing
  /// watched or marked yet) and [MultiSeasonCollectionLinkError] for a
  /// collection holding several seasons.
  Future<({TrackingMediaType type, String key})> _serverIdentityOf(
    TrackingMediaType mediaType,
    String mediaKey,
  ) async {
    final List<({TrackingMediaType type, String key})> keys =
        (await _repository.loadMediaServerLibraryCoverage()).keysOf(
          mediaType.value,
          mediaKey,
        );
    if (keys.isEmpty) throw MediaServerLibraryLinkError(mediaKey);
    final int seasons = keys
        .where(
          (({TrackingMediaType type, String key}) k) =>
              k.type == TrackingMediaType.remoteSeries,
        )
        .length;
    if (seasons > 1) throw MultiSeasonCollectionLinkError(mediaKey);
    if (seasons == 0 && mediaType == TrackingMediaType.videoCollection) {
      // Several movies / lone episodes: no one key stands for them all.
      if (keys.length > 1) throw MultiSeasonCollectionLinkError(mediaKey);
    }
    return keys.first;
  }

  /// 读取指定 mapping 的当前权威本地事实并幂等入队，不依赖毫秒水位先后关系。
  Future<void> _enqueueCurrentProgress(MediaTrackingMappingRow mapping) async {
    final String provider = mapping.provider;
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
      final List<CompletedVideoTrackingProgress> progress = await _repository
          .loadCompletedVideoTrackingProgress(afterMs: -1, provider: provider);
      for (final CompletedVideoTrackingProgress item in progress) {
        if (item.mediaType != mediaType || item.mediaKey != mapping.mediaKey) {
          continue;
        }
        await _repository.enqueueProgress(
          mediaType: item.mediaType,
          mediaKey: item.mediaKey,
          localProgress: item.localProgress,
          completed: item.completed,
          provider: provider,
        );
      }
      return;
    }
    if (mediaType == TrackingMediaType.book ||
        mediaType == TrackingMediaType.bookChapter) {
      final List<PersistedBookTrackingProgress> progress = await _repository
          .loadPersistedBookTrackingProgress(
            afterMs: -1,
            provider: provider,
            mangaProgress: _mangaReadProgress,
          );
      for (final PersistedBookTrackingProgress item in progress) {
        if (item.mediaType != mediaType || item.mediaKey != mapping.mediaKey) {
          continue;
        }
        await _repository.enqueueProgress(
          mediaType: item.mediaType,
          mediaKey: item.mediaKey,
          localProgress: item.localProgress,
          completed: item.completed,
          provider: provider,
        );
      }
      return;
    }
    if (mediaType == TrackingMediaType.remoteVideo) {
      // A media server episode is only known here once it was watched to the
      // end ([recordRemoteVideoCompleted]); the site decides completion from
      // its own episode count, as there.
      await _repository.enqueueProgress(
        mediaType: TrackingMediaType.remoteVideo,
        mediaKey: mapping.mediaKey,
        localProgress: 0,
        completed: false,
        provider: provider,
      );
      return;
    }
    if (mediaType == TrackingMediaType.remoteSeries) {
      // A season linked by hand: the highest remembered episode goes out.
      int episode = 0;
      for (final MediaTrackingRemoteEpisodeRow row
          in await _repository.remoteEpisodesOfGroup(mapping.mediaKey)) {
        episode = math.max(episode, row.episodeNumber);
      }
      if (episode <= 0) return;
      await _repository.enqueueProgress(
        mediaType: TrackingMediaType.remoteSeries,
        mediaKey: mapping.mediaKey,
        localProgress: episode - 1,
        completed: false,
        provider: provider,
      );
      return;
    }
    if (mediaType == TrackingMediaType.game) {
      final List<PersistedGameTrackingStatus> progress = await _repository
          .loadPersistedGameTrackingStatus(afterMs: -1, provider: provider);
      for (final PersistedGameTrackingStatus item in progress) {
        if (item.gameId != mapping.mediaKey) continue;
        await _repository.enqueueProgress(
          mediaType: TrackingMediaType.game,
          mediaKey: item.gameId,
          localProgress: item.status,
          completed: item.status == 2,
          monotonic: false,
          provider: provider,
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
    if (!isOn) return;
    // A media server row reports through [recordRemoteVideoCompleted] only
    // (one identity per watched thing).
    if (await _repository.isMediaServerLibraryItem(
      TrackingMediaType.video,
      bookUid,
    )) {
      return;
    }
    if (await _isIgnored(
      TrackingMediaType.video,
      bookUid,
      alsoKeys: <(TrackingMediaType, String)>[
        if (collectionId != null)
          (TrackingMediaType.videoCollection, collectionId.toString()),
      ],
    )) {
      return;
    }
    // 多季合集（分组按各集文件名现场派生，≥2 组即算，存量合集零迁移生效）：
    // 「整合集 → 单个 Bangumi 条目」结构性失真——Bangumi 一季一条目，合集下标当
    // 集数会把 S02E01 报成 E13、完结误报给第一季条目。此时绕开合集级映射（保留
    // 不改写，只不再使用），一律走按集通道（季度感知刮削 subject + 文件名季内
    // 集号）。
    bool multiSeason = false;
    if (collectionId != null) {
      multiSeason = isMultiSeasonGrouped(
        await _repository.loadCollectionVideoGroupKeys(collectionId),
      );
    }
    // 已有合集映射属于用户显式配置或旧版自动映射，优先沿用且绝不改写。
    // Checked per provider: a provider with a collection mapping is done here,
    // the others still go through the per-file path below.
    final Set<String> handled = <String>{};
    if (collectionId != null && !multiSeason) {
      for (final TrackingProvider provider in _registry.all) {
        if (!isProviderEnabled(provider.id)) continue;
        final MediaTrackingMappingRow? collectionMapping = await _repository
            .findMapping(
              mediaType: TrackingMediaType.videoCollection,
              mediaKey: collectionId.toString(),
              provider: provider.id,
            );
        if (collectionMapping == null) continue;
        handled.add(provider.id);
        await _enqueueAndSync(
          provider: provider,
          mediaType: TrackingMediaType.videoCollection,
          mediaKey: collectionId.toString(),
          localProgress: episodeIndex,
          completed: seriesCompleted,
        );
      }
    }
    if (_registry.all.every(
      (TrackingProvider provider) =>
          handled.contains(provider.id) || !isProviderEnabled(provider.id),
    )) {
      return;
    }

    // Providers that link by MAL id track each file as its own episode (the
    // id says which season; a collection index could not).
    for (final TrackingProvider provider in _registry.all) {
      if (provider is! TrackingAnimeLinker ||
          handled.contains(provider.id) ||
          !_isActive(provider) ||
          !isKindEnabled(provider.id, TrackingKind.anime)) {
        continue;
      }
      final MediaTrackingMappingRow? mapping = await _linkVideoByMalId(
        provider,
        provider as TrackingAnimeLinker,
        bookUid,
      );
      if (mapping == null) continue;
      handled.add(provider.id);
      await _enqueueAndSync(
        provider: provider,
        mediaType: TrackingMediaType.video,
        mediaKey: bookUid,
        localProgress: 0,
        // The provider knows its own episode count and decides completion.
        completed: false,
      );
    }

    final AutoVideoTrackingSource? source = await _repository
        .loadAutoVideoSource(bookUid: bookUid, collectionId: collectionId);
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
    final String key = type == TrackingMediaType.video
        ? bookUid
        : collectionId.toString();
    if (!handled.contains(kTrackingProviderBangumi) &&
        _bangumiAcceptsKind(TrackingKind.anime)) {
      await _ensureAutoVideoMapping(
        source: source,
        mediaType: type,
        mediaKey: key,
        progressOffset: itemScoped ? parsedEpisodeNumber : 1,
      );
    }
    final int knownEpisodeCount = source.bangumiEpisodeCount ?? 0;
    final bool itemCompletesSeries =
        itemScoped &&
        knownEpisodeCount > 0 &&
        parsedEpisodeNumber >= knownEpisodeCount;
    await _fanOut(
      skip: handled,
      mediaType: type,
      mediaKey: key,
      localProgress: itemScoped || collectionId == null ? 0 : episodeIndex,
      completed: itemScoped
          ? itemCompletesSeries
          : (seriesCompleted || collectionId == null),
    );
  }

  /// A media server episode was watched to the end. Each linker provider
  /// (AniList) links it once from the server's ids and gets the episode;
  /// Bangumi does not track media server playback.
  ///
  /// [libraryBookUid]: the library row when the episode was added to the
  /// library (`media-server://`); a private row sends nothing.
  Future<void> recordRemoteVideoCompleted(
    RemoteAnimeEpisode episode, {
    String? libraryBookUid,
  }) async {
    if (!isOn) return;
    final String key = episode.mediaKey.trim();
    if (key.isEmpty) return;
    final String group = remoteAnimeGroupKey(episode);
    if (libraryBookUid != null &&
        await _isAutoMappingKeyPrivate(
          '${TrackingMediaType.video.value}:$libraryBookUid',
        )) {
      return;
    }
    // Remembered first, linked or not: which season it belongs to (an
    // ignored season pauses it) and what a season link sends. Local only.
    await _repository.rememberRemoteEpisode(episode);
    if (await _isIgnored(
      TrackingMediaType.remoteVideo,
      key,
      alsoKeys: <(TrackingMediaType, String)>[
        (TrackingMediaType.remoteSeries, group),
      ],
    )) {
      _statusRevision.value++;
      return;
    }
    List<RemoteAnimeCandidate>? candidates;
    for (final TrackingProvider provider in _registry.all) {
      if (!_isActive(provider) ||
          !isKindEnabled(provider.id, TrackingKind.anime)) {
        continue;
      }
      MediaTrackingMappingRow? mapping = await _repository.findMapping(
        mediaType: TrackingMediaType.remoteVideo,
        mediaKey: key,
        provider: provider.id,
      );
      if (mapping == null && !episode.isMovie) {
        // The user linked the season by hand: this episode counts as its
        // episode number there.
        final MediaTrackingMappingRow? season = await _repository.findMapping(
          mediaType: TrackingMediaType.remoteSeries,
          mediaKey: group,
          provider: provider.id,
        );
        if (season != null) {
          await _enqueueAndSync(
            provider: provider,
            mediaType: TrackingMediaType.remoteSeries,
            mediaKey: group,
            localProgress: math.max(0, episode.episodeNumber - 1),
            completed: false,
          );
          continue;
        }
      }
      if (mapping == null &&
          provider is TrackingAnimeLinker &&
          !await _removedByUser(
            provider.id,
            TrackingMediaType.remoteVideo,
            key,
          ) &&
          !await _removedByUser(
            provider.id,
            TrackingMediaType.remoteSeries,
            group,
          )) {
        candidates ??= await remoteAnimeCandidates(
          episode,
          crossIds: _animeCrossIds,
        );
        mapping = await _linkRemoteEpisode(
          provider,
          provider as TrackingAnimeLinker,
          episode,
          candidates,
        );
      }
      if (mapping == null) continue;
      await _enqueueAndSync(
        provider: provider,
        mediaType: TrackingMediaType.remoteVideo,
        mediaKey: key,
        localProgress: 0,
        // The provider knows its own episode count and decides completion.
        completed: false,
      );
    }
    // No site has it: it shows under "Needs attention" (remembered above)
    // and can be linked by hand (one link per season).
    _statusRevision.value++;
  }

  /// First candidate the provider knows whose episode fits. A candidate that
  /// does not fit (episode past the end, or a season of another length) is
  /// skipped for the next one; network trouble stops and links next time.
  Future<MediaTrackingMappingRow?> _linkRemoteEpisode(
    TrackingProvider provider,
    TrackingAnimeLinker linker,
    RemoteAnimeEpisode episode,
    List<RemoteAnimeCandidate> candidates,
  ) async {
    for (final RemoteAnimeCandidate candidate in candidates) {
      final TrackingLinkedSubject? subject;
      try {
        if (candidate.idType == provider.id) {
          subject = await linker.animeById(candidate.id);
        } else if (candidate.idType == RemoteAnimeIdType.mal) {
          subject = await linker.animeForMalId(candidate.id);
        } else {
          continue;
        }
      } catch (error, stackTrace) {
        engineLog.log('MediaTrackingService.linkRemote', error, stackTrace);
        return null;
      }
      if (subject == null) continue;
      final int? remoteCount = subject.episodeCount;
      final int? localCount = episode.seasonEpisodeCount;
      if (remoteCount != null &&
          (candidate.episode > remoteCount ||
              (candidate.sameSeason &&
                  !episode.isMovie &&
                  localCount != null &&
                  localCount != remoteCount))) {
        continue;
      }
      return _saveAutoLink(
        mediaType: TrackingMediaType.remoteVideo,
        mediaKey: episode.mediaKey.trim(),
        mediaTitle: episode.title.isEmpty ? subject.name : episode.title,
        kind: TrackingKind.anime,
        subjectId: subject.subjectId,
        subjectName: subject.name,
        progressMode: TrackingProgressMode.episode,
        progressOffset: candidate.episode,
        provider: provider.id,
        linkSource: TrackingLinkSource.id,
      );
    }
    return null;
  }

  Future<void> recordBookProgress({
    required String bookKey,
    required int completedChapterCount,
    required bool completed,
    bool bangumiAutoMapping = true,
  }) async {
    if (!isOn) return;
    if (await _isIgnored(TrackingMediaType.book, bookKey)) return;
    final MediaTrackingMappingRow? bangumiMapping = !bangumiAutoMapping
        ? await _repository.findMapping(
            mediaType: TrackingMediaType.book,
            mediaKey: bookKey,
          )
        : _bangumiAcceptsKind(TrackingKind.novel) ||
              _bangumiAcceptsKind(TrackingKind.manga)
        ? await _ensureAutoBookMapping(bookKey)
        : null;
    await _sendBookProgress(
      bookKey: bookKey,
      completedChapterCount: completedChapterCount,
      completed: completed,
      bangumiMapping: bangumiMapping,
    );
    // Linking can wait minutes for the search budget, and the reader awaits
    // this call on its exit path: it runs in the background, then sends to
    // the sites it linked.
    late final Future<void> run;
    run = _linkBook(bookKey)
        .then((Set<String> linked) async {
          if (linked.isEmpty) return;
          await _sendBookProgress(
            bookKey: bookKey,
            completedChapterCount: completedChapterCount,
            completed: completed,
            bangumiMapping: null,
            onlyProviders: linked,
          );
        })
        .catchError((Object error, StackTrace stackTrace) {
          engineLog.log('MediaTrackingService.linkBook', error, stackTrace);
        })
        .whenComplete(() => _bookLinkRuns.remove(run));
    _bookLinkRuns.add(run);
  }

  final Set<Future<void>> _bookLinkRuns = <Future<void>>{};

  /// Completes when the background linking started by [recordBookProgress]
  /// has finished (tests, and the Track sheet before it reads links).
  Future<void> whenBookLinksSettled() async {
    while (_bookLinkRuns.isNotEmpty) {
      await Future.wait(_bookLinkRuns.toList());
    }
  }

  /// Queues the book's progress for every provider with a link
  /// ([onlyProviders] limits it to those).
  Future<void> _sendBookProgress({
    required String bookKey,
    required int completedChapterCount,
    required bool completed,
    required MediaTrackingMappingRow? bangumiMapping,
    Set<String>? onlyProviders,
  }) async {
    BookTrackingSnapshot? snapshot;
    for (final TrackingProvider provider in _registry.all) {
      if (onlyProviders != null && !onlyProviders.contains(provider.id)) {
        continue;
      }
      if (!isProviderEnabled(provider.id)) continue;
      final bool isBangumi = provider.id == kTrackingProviderBangumi;
      final MediaTrackingMappingRow? mapping = isBangumi
          ? bangumiMapping
          : await _repository.findMapping(
              mediaType: TrackingMediaType.book,
              mediaKey: bookKey,
              provider: provider.id,
            );
      if (mapping == null || !_acceptsMapping(provider, mapping)) continue;
      final TrackingProgressMode? progressMode = TrackingProgressMode.tryParse(
        mapping.progressMode,
      );
      if (progressMode == null) continue;
      snapshot ??= await _repository.loadBookTrackingSnapshot(
        bookKey: bookKey,
        fallbackProgress: completedChapterCount,
        mangaProgress: _mangaReadProgress,
      );
      // BUG-1318: skip a link whose kind no longer matches the book (format
      // changed since it was linked; a PDF may be either). Bangumi keeps its
      // legacy behaviour.
      if (!isBangumi && !bookFormatTracksAs(snapshot.format, mapping.kind)) {
        continue;
      }
      final int? localProgress = resolveBookTrackingLocalProgress(
        format: snapshot.format,
        progressMode: progressMode,
        chapterProgress: snapshot.chapterProgress,
        completed: completed,
      );
      if (localProgress == null) continue;
      final bool isVolume = progressMode == TrackingProgressMode.volume;
      final bool wantsChapterCompanion =
          isVolume &&
          mapping.kind == TrackingKind.novel.value &&
          snapshot.chapterProgress != null;
      // Only Bangumi builds the chapter companion automatically; other
      // providers use one only when it was linked explicitly.
      final MediaTrackingMappingRow? chapterMapping = !wantsChapterCompanion
          ? null
          : isBangumi
          ? await _ensureBookChapterMapping(mapping)
          : await _repository.findMapping(
              mediaType: TrackingMediaType.bookChapter,
              mediaKey: bookKey,
              provider: provider.id,
            );
      await _enqueueAndSync(
        provider: provider,
        mediaType: TrackingMediaType.book,
        mediaKey: bookKey,
        localProgress: localProgress,
        completed: completed,
      );
      if (chapterMapping == null) continue;
      await _enqueueAndSync(
        provider: provider,
        mediaType: TrackingMediaType.bookChapter,
        mediaKey: bookKey,
        localProgress: snapshot.chapterProgress!,
        // 章节伴随映射只负责 ep_status；整部作品是否读完由主卷映射判断。
        completed: false,
      );
    }
  }

  /// Links [bookKey] on every active site that tracks its kind and has no
  /// link for it yet (Bangumi keeps its own matching). Returns the providers
  /// that got a new link. One run per book at a time.
  Future<Set<String>> _linkBook(String bookKey) {
    final List<TrackingProvider> linkers = <TrackingProvider>[
      for (final TrackingProvider provider in _registry.all)
        if (provider.id != kTrackingProviderBangumi &&
            provider is TrackingBookLinker &&
            _isActive(provider))
          provider,
    ];
    if (linkers.isEmpty) return Future<Set<String>>.value(const <String>{});
    final ({int generation, Future<Set<String>> future})? running =
        _bookLinkInFlight[bookKey];
    if (running != null) {
      if (running.generation == _registryGeneration) return running.future;
      // Started before the provider list changed: let it finish, then link
      // again for the sites registered since (one run per book at a time).
      return running.future.then(
        (Set<String> first) async => <String>{
          ...first,
          ...await _linkBook(bookKey),
        },
      );
    }
    late final Future<Set<String>> future;
    future = _runBookLink(bookKey, linkers).whenComplete(() {
      if (identical(_bookLinkInFlight[bookKey]?.future, future)) {
        _bookLinkInFlight.remove(bookKey);
      }
    });
    _bookLinkInFlight[bookKey] = (
      generation: _registryGeneration,
      future: future,
    );
    return future;
  }

  Future<Set<String>> _runBookLink(
    String bookKey,
    List<TrackingProvider> linkers,
  ) async {
    if (await _isIgnored(TrackingMediaType.book, bookKey)) {
      return const <String>{};
    }
    final EpubBookRow? book = await _repository.loadBook(bookKey);
    if (book == null) return const <String>{};
    final TrackingKind kind = await _bookKindOf(book);
    final int now = DateTime.now().millisecondsSinceEpoch;
    final List<TrackingProvider> missing = <TrackingProvider>[];
    for (final TrackingProvider provider in linkers) {
      if (!provider.capabilities.acceptsKind(kind) ||
          !isKindEnabled(provider.id, kind)) {
        continue;
      }
      final int? missedAt = _bookLinkMissAt['${provider.id}:$bookKey'];
      if (missedAt != null &&
          now - missedAt < _autoMappingMissRetry.inMilliseconds) {
        continue;
      }
      final MediaTrackingMappingRow? existing = await _repository.findMapping(
        mediaType: TrackingMediaType.book,
        mediaKey: bookKey,
        provider: provider.id,
      );
      if (existing != null) continue;
      // Suggestions waiting, dismissed, or a link the user removed: this
      // site is left to the user for this item.
      if (await _repository.hasSuggestions(
        provider: provider.id,
        mediaType: TrackingMediaType.book,
        mediaKey: bookKey,
      )) {
        continue;
      }
      missing.add(provider);
    }
    if (missing.isEmpty) return const <String>{};
    // A private item is never searched for and gets no new links.
    if (isTrackedMediaPrivate(
      await _repository.loadPrivacy(),
      TrackingMediaType.book.value,
      bookKey,
    )) {
      return const <String>{};
    }
    // The default site links first, so the others can link from its id.
    missing.sort(
      (TrackingProvider a, TrackingProvider b) =>
          (b.capabilities.isOnByDefault(kind) ? 1 : 0) -
          (a.capabilities.isOnByDefault(kind) ? 1 : 0),
    );
    final Set<String> linked = <String>{};
    bool suggested = false;
    BookLinkSource? source;
    for (final TrackingProvider provider in missing) {
      // Removed while an earlier site was searched: never call it again.
      if (!_isRegistered(provider)) continue;
      final String missKey = '${provider.id}:$bookKey';
      try {
        MediaTrackingMappingRow? row = await _linkBookById(
          provider,
          bookKey,
          kind,
        );
        if (row == null && provider.capabilities.isOnByDefault(kind)) {
          source ??= await _bookLinkSourceOf(book);
          final ({MediaTrackingMappingRow? row, bool suggested}) result =
              await _linkBookByTitle(provider, bookKey, source);
          row = result.row;
          suggested = suggested || result.suggested;
        }
        if (row != null) {
          linked.add(provider.id);
          _bookLinkMissAt.remove(missKey);
        } else {
          _bookLinkMissAt[missKey] = DateTime.now().millisecondsSinceEpoch;
        }
      } catch (error, stackTrace) {
        _bookLinkMissAt[missKey] = DateTime.now().millisecondsSinceEpoch;
        engineLog.log('MediaTrackingService.linkBook', error, stackTrace);
      }
    }
    if (linked.isNotEmpty || suggested) _statusRevision.value++;
    return linked;
  }

  /// A link for [provider] from another site's link to the same item: that
  /// site's id for the series on [provider] (MangaBaka's AniList id), or
  /// [provider]'s own lookup of the other site's id. Copies the other link's
  /// progress unit. Never uses a title.
  Future<MediaTrackingMappingRow?> _linkBookById(
    TrackingProvider provider,
    String bookKey,
    TrackingKind kind,
  ) async {
    final TrackingBookLinker linker = provider as TrackingBookLinker;
    for (final TrackingProvider other in _registry.all) {
      if (other.id == provider.id ||
          other is! TrackingBookLinker ||
          !other.isConfigured) {
        continue;
      }
      final MediaTrackingMappingRow? known = await _repository.findMapping(
        mediaType: TrackingMediaType.book,
        mediaKey: bookKey,
        provider: other.id,
      );
      if (known == null || known.kind != kind.value) continue;
      final TrackingProgressMode? mode = TrackingProgressMode.tryParse(
        known.progressMode,
      );
      if (mode == null || !provider.capabilities.accepts(kind, mode)) continue;
      TrackingBookSubject? subject = await linker.bookForLinkedId(
        other.id,
        known.subjectId,
      );
      if (subject == null) {
        final TrackingBookSubject? there = await (other as TrackingBookLinker)
            .bookById(known.subjectId);
        final int? id = there?.linkedIds[provider.id];
        if (id != null) subject = await linker.bookById(id);
      }
      if (subject == null || subject.kind != kind) continue;
      return _saveAutoLink(
        mediaType: TrackingMediaType.book,
        mediaKey: bookKey,
        mediaTitle: known.mediaTitle,
        kind: kind,
        subjectId: subject.subjectId,
        subjectName: subject.name,
        progressMode: mode,
        progressOffset: known.progressOffset,
        provider: provider.id,
        linkSource: TrackingLinkSource.id,
      );
    }
    return null;
  }

  /// Title search on [provider] (the default site for the kind). Links a sure
  /// match whose progress unit is safe ([planBookLink]); stores the rest as
  /// suggestions. Searches an item once: after suggestions exist, only the
  /// user links it. [suggested] = suggestions were stored.
  Future<({MediaTrackingMappingRow? row, bool suggested})> _linkBookByTitle(
    TrackingProvider provider,
    String bookKey,
    BookLinkSource source,
  ) async {
    if (await _repository.hasSuggestions(
      provider: provider.id,
      mediaType: TrackingMediaType.book,
      mediaKey: bookKey,
    )) {
      return (row: null, suggested: false);
    }
    final TrackingBookLinker linker = provider as TrackingBookLinker;
    final TrackingKind kind = source.kind;
    final List<TitleMatchCandidate<TrackingBookSubject>> candidates =
        <TitleMatchCandidate<TrackingBookSubject>>[];
    TitleMatchDecision<TrackingBookSubject>? decision;
    for (final String term in source.query.searchTerms.take(
      kBookLinkMaxSearches,
    )) {
      for (final TrackingBookSubject subject in await linker.searchBooks(
        term,
        kind,
      )) {
        candidates.add(titleCandidateOf(subject, kind));
      }
      decision = decideTitleMatch(source.query, candidates);
      if (decision.auto != null) break;
    }
    if (decision == null) return (row: null, suggested: false);
    final List<ScoredTitleCandidate<TrackingBookSubject>> review =
        <ScoredTitleCandidate<TrackingBookSubject>>[...decision.suggestions];
    final ScoredTitleCandidate<TrackingBookSubject>? auto = decision.auto;
    if (auto != null) {
      final TrackingBookSubject subject = auto.candidate.subject;
      final BookLinkPlan? plan = planBookLink(
        source: source,
        subject: subject,
        localChapters: source.chapterWork
            ? (await _repository.loadBookTrackingSnapshot(
                bookKey: bookKey,
                fallbackProgress: 0,
                mangaProgress: _mangaReadProgress,
              )).chapterProgress
            : null,
      );
      if (plan != null) {
        final MediaTrackingMappingRow row = await _saveAutoLink(
          mediaType: TrackingMediaType.book,
          mediaKey: bookKey,
          mediaTitle: source.mediaTitle,
          kind: kind,
          subjectId: subject.subjectId,
          subjectName: subject.name,
          progressMode: plan.mode,
          progressOffset: plan.offset,
          provider: provider.id,
          linkSource: TrackingLinkSource.auto,
          confidence: auto.score,
        );
        return (row: row, suggested: false);
      }
      // Sure of the series, not of the progress unit: the user decides.
      review.add(auto);
    }
    await _repository.saveSuggestions(
      provider: provider.id,
      mediaType: TrackingMediaType.book,
      mediaKey: bookKey,
      suggestions: <TrackingSuggestionDraft>[
        for (final ScoredTitleCandidate<TrackingBookSubject> scored in review)
          (
            subjectId: scored.candidate.subject.subjectId,
            subjectName: scored.candidate.subject.name,
            subjectKind: kind,
            score: scored.score,
            details: scored.candidate.subject.toDetailsJson(),
          ),
      ],
    );
    return (row: null, suggested: review.isNotEmpty);
  }

  // ── Track sheet ───────────────────────────────────────────────────

  /// Each book site's link and open suggestions for [bookKey] (sites that
  /// track its kind; Bangumi keeps its own settings page). Null when the book
  /// is gone. [asKind]: the kind to show a PDF as (manga or novel, see
  /// [trackingKindsForBookFormat]); null = the one its links have, else the
  /// format's.
  Future<BookTrackingOverview?> loadBookTracking(
    String bookKey, {
    TrackingKind? asKind,
  }) async {
    final EpubBookRow? book = await _repository.loadBook(bookKey);
    if (book == null) return null;
    final List<TrackingKind> kinds = trackingKindsForBookFormat(
      BookFormat.parseOrEpub(book.format),
    );
    final TrackingKind kind = asKind != null && kinds.contains(asKind)
        ? asKind
        : await _bookKindOf(book);
    final List<MediaTrackingSuggestionRow> suggestions = await _repository
        .loadSuggestions(mediaType: TrackingMediaType.book, mediaKey: bookKey);
    final BookLinkSource source = await _bookLinkSourceOf(book, kind: kind);
    final List<BookTrackingSite> sites = <BookTrackingSite>[];
    for (final TrackingProvider provider in _registry.all) {
      if (provider is! TrackingBookLinker ||
          provider.id == kTrackingProviderBangumi ||
          !provider.capabilities.acceptsKind(kind)) {
        continue;
      }
      sites.add(
        BookTrackingSite(
          providerId: provider.id,
          connected: provider.isConfigured,
          kindEnabled: isKindEnabled(provider.id, kind),
          isDefaultSite: provider.capabilities.isOnByDefault(kind),
          link: await _repository.findMapping(
            mediaType: TrackingMediaType.book,
            mediaKey: bookKey,
            provider: provider.id,
          ),
          suggestions: <MediaTrackingSuggestionRow>[
            for (final MediaTrackingSuggestionRow row in suggestions)
              if (row.provider == provider.id && row.subjectKind == kind.value)
                row,
          ],
        ),
      );
    }
    // Default site first (MangaBaka for books and manga).
    sites.sort(
      (BookTrackingSite a, BookTrackingSite b) =>
          (b.isDefaultSite ? 1 : 0) - (a.isDefaultSite ? 1 : 0),
    );
    final TrackingIgnoreIndex ignored = await _repository.loadIgnoreIndex();
    final MediaCollectionRow? series = (await _repository.bookSeriesCollections(
      bookKey,
    )).firstOrNull;
    return BookTrackingOverview(
      ignored: ignored.isListed(TrackingMediaType.book.value, bookKey),
      series: series == null ? null : (id: series.id, name: series.name),
      seriesIgnored:
          series != null &&
          ignored.isListed(
            TrackingMediaType.bookCollection.value,
            series.id.toString(),
          ),
      bookKey: bookKey,
      title: source.mediaTitle,
      searchQuery: source.query.searchTerms.firstOrNull ?? source.mediaTitle,
      kind: kind,
      kinds: kinds,
      isPrivate: isTrackedMediaPrivate(
        await _repository.loadPrivacy(),
        TrackingMediaType.book.value,
        bookKey,
      ),
      sites: sites,
    );
  }

  /// Links [bookKey] now where it can be (the Track sheet opened): forgets
  /// recent misses for it, runs the same linking as reading does, and sends
  /// to any site it linked. Sites with suggestions (or a link the user
  /// removed) are left to the user.
  Future<void> refreshBookLinks(String bookKey) async {
    _bookLinkMissAt.removeWhere(
      (String key, int _) => key.endsWith(':$bookKey'),
    );
    final Set<String> linked = await _linkBook(bookKey);
    for (final String providerId in linked) {
      final MediaTrackingMappingRow? mapping = await _repository.findMapping(
        mediaType: TrackingMediaType.book,
        mediaKey: bookKey,
        provider: providerId,
      );
      if (mapping != null) await _enqueueCurrentProgress(mapping);
    }
    if (linked.isNotEmpty) _requestSync();
  }

  /// The user's search on [providerId] for [bookKey]: a title, or a subject
  /// id / link to the site. Only subjects of the book's kind come back
  /// ([asKind]: the kind chosen for a PDF; see [loadBookTracking]).
  Future<List<TrackingBookSubject>> searchBookSubjects({
    required String providerId,
    required String bookKey,
    required String query,
    TrackingKind? asKind,
  }) async {
    final TrackingProvider? provider = _registry.byId(providerId);
    if (provider == null ||
        provider is! TrackingBookLinker ||
        query.trim().isEmpty) {
      return const <TrackingBookSubject>[];
    }
    final EpubBookRow? book = await _repository.loadBook(bookKey);
    if (book == null) return const <TrackingBookSubject>[];
    final TrackingKind kind =
        _chosenBookKind(book, asKind) ?? await _bookKindOf(book);
    final TrackingBookLinker linker = provider as TrackingBookLinker;
    final int? id = parseTrackingSubjectInput(provider.siteHost, query);
    final List<TrackingBookSubject> found;
    if (id != null) {
      final TrackingBookSubject? subject = await linker.bookById(id);
      found = subject == null
          ? const <TrackingBookSubject>[]
          : <TrackingBookSubject>[subject];
    } else {
      found = await linker.searchBooks(query, kind);
    }
    return <TrackingBookSubject>[
      for (final TrackingBookSubject subject in found)
        if (subject.kind == kind) subject,
    ];
  }

  /// The site's name for the UI; the id when the site is not registered
  /// (a link left behind by a site this build no longer has).
  String siteNameOf(String providerId) =>
      _registry.byId(providerId)?.displayName ?? providerId;

  /// Links [bookKey] to [subject] on [providerId] because the user chose it
  /// (a search result, or an approved suggestion: [linkSource] / [confidence]).
  /// Replaces an existing link, sends the current progress, then lets the
  /// other sites link from its id. [asKind]: the kind the user chose for a
  /// PDF (manga or novel); ignored for other formats.
  Future<void> linkBookToSubject({
    required String bookKey,
    required String providerId,
    required TrackingBookSubject subject,
    String linkSource = TrackingLinkSource.manual,
    double? confidence,
    TrackingKind? asKind,
    BookLinkPlan? plan,
    Duration? holdSend,
  }) async {
    final ({BookLinkSource source, BookLinkPlan plan})? planned =
        await _planBookLink(bookKey: bookKey, subject: subject, asKind: asKind);
    if (planned == null) return;
    final BookLinkSource source = planned.source;
    final TrackingKind kind = source.kind;
    // The user may correct the planned number (the link dialog's field).
    final BookLinkPlan chosen = plan ?? planned.plan;
    _bookLinkMissAt.remove('$providerId:$bookKey');
    await saveManualMappingAndSync(
      mediaType: TrackingMediaType.book,
      mediaKey: bookKey,
      mediaTitle: source.mediaTitle,
      kind: kind,
      subjectId: subject.subjectId,
      subjectName: subject.name,
      progressMode: chosen.mode,
      progressOffset: chosen.offset,
      provider: providerId,
      linkSource: linkSource,
      confidence: confidence,
      holdSend: holdSend,
    );
    _statusRevision.value++;
    await refreshBookLinks(bookKey);
  }

  /// The unit and number a link of book [bookKey] to [subject] would send
  /// (the Track sheet's rule, [planBookLinkForUser]); null when the book is
  /// gone.
  Future<({BookLinkSource source, BookLinkPlan plan})?> _planBookLink({
    required String bookKey,
    required TrackingBookSubject subject,
    TrackingKind? asKind,
  }) async {
    final EpubBookRow? book = await _repository.loadBook(bookKey);
    if (book == null) return null;
    final BookLinkSource source = await _bookLinkSourceOf(
      book,
      kind: _chosenBookKind(book, asKind),
    );
    if (subject.kind != source.kind) {
      throw ArgumentError.value(subject.subjectId, 'subject', 'wrong kind');
    }
    final BookLinkPlan plan = planBookLinkForUser(
      source: source,
      subject: subject,
      localChapters: source.chapterWork
          ? (await _repository.loadBookTrackingSnapshot(
              bookKey: bookKey,
              fallbackProgress: 0,
              mangaProgress: _mangaReadProgress,
            )).chapterProgress
          : null,
    );
    return (source: source, plan: plan);
  }

  /// What a hand link of book [mediaKey] to [hit] on [providerId] would send
  /// (unit and number) when the site plans book links ([plansBookLink]);
  /// null otherwise. The link dialog pre-fills its number from it.
  Future<BookLinkPlan?> planBookLinkForHit({
    required TrackingMediaType mediaType,
    required String mediaKey,
    required String providerId,
    required TrackingSearchHit hit,
    TrackingKind? asKind,
  }) async {
    final TrackingBookSubject? book = hit.book;
    if (book == null || !plansBookLink(mediaType, providerId)) return null;
    return (await _planBookLink(
      bookKey: mediaKey,
      subject: book,
      asKind: asKind,
    ))?.plan;
  }

  /// Approves a stored suggestion: links to it.
  Future<void> approveSuggestion(MediaTrackingSuggestionRow suggestion) =>
      linkBookToSubject(
        bookKey: suggestion.mediaKey,
        providerId: suggestion.provider,
        subject: subjectOfSuggestion(suggestion),
        linkSource: TrackingLinkSource.suggestion,
        confidence: suggestion.score,
        asKind: _trackingKindOf(suggestion.subjectKind),
      );

  Future<void> dismissSuggestion(int suggestionId) async {
    await _repository.dismissSuggestion(suggestionId);
    _statusRevision.value++;
  }

  /// Changes which volume a volume link counts as ([volume] ≥ 1) and sends
  /// the progress again. The site's progress never goes down.
  Future<void> setBookLinkVolume({
    required String bookKey,
    required String providerId,
    required int volume,
  }) async {
    final MediaTrackingMappingRow? mapping = await _repository.findMapping(
      mediaType: TrackingMediaType.book,
      mediaKey: bookKey,
      provider: providerId,
    );
    if (mapping == null || volume < 1) return;
    if (mapping.progressMode != TrackingProgressMode.volume.value) return;
    final TrackingKind? kind = _trackingKindOf(mapping.kind);
    if (kind == null) return;
    await saveManualMappingAndSync(
      mediaType: TrackingMediaType.book,
      mediaKey: bookKey,
      mediaTitle: mapping.mediaTitle,
      kind: kind,
      subjectId: mapping.subjectId,
      subjectName: mapping.subjectName,
      progressMode: TrackingProgressMode.volume,
      progressOffset: volume,
      provider: providerId,
    );
    _statusRevision.value++;
  }

  /// Removes the link (what was already sent stays on the site; pending
  /// updates for it go with it).
  Future<void> unlinkBook({
    required String bookKey,
    required String providerId,
  }) async {
    final MediaTrackingMappingRow? mapping = await _repository.findMapping(
      mediaType: TrackingMediaType.book,
      mediaKey: bookKey,
      provider: providerId,
    );
    if (mapping == null) return;
    await _repository.deleteMapping(mapping.id);
    // Kept as a dismissed suggestion: the item is then never linked to this
    // site by itself again, even after a restart (manual links still work).
    await _repository.rejectSubject(
      provider: providerId,
      mediaType: TrackingMediaType.book,
      mediaKey: bookKey,
      subjectId: mapping.subjectId,
      subjectName: mapping.subjectName,
      subjectKind: mapping.kind,
    );
    _statusRevision.value++;
  }

  /// [book]'s link source, tracked as [kind] (a PDF's chosen kind) or else
  /// as [_bookKindOf].
  Future<BookLinkSource> _bookLinkSourceOf(
    EpubBookRow book, {
    TrackingKind? kind,
  }) async => buildBookLinkSource(
    book,
    await _bookLinkHints?.call(book),
  ).withKind(kind ?? await _bookKindOf(book));

  /// [asKind] when [book]'s format may be tracked as it (a PDF: manga or
  /// novel), else null.
  TrackingKind? _chosenBookKind(EpubBookRow book, TrackingKind? asKind) =>
      asKind != null &&
          trackingKindsForBookFormat(
            BookFormat.parseOrEpub(book.format),
          ).contains(asKind)
      ? asKind
      : null;

  /// The kind [book] is tracked as: its format's, except a PDF linked as
  /// manga on some site (the user chose that by hand): then manga
  /// everywhere, so automatic linking on the other sites follows it.
  Future<TrackingKind> _bookKindOf(EpubBookRow book) async {
    final BookFormat format = BookFormat.parseOrEpub(book.format);
    final List<TrackingKind> kinds = trackingKindsForBookFormat(format);
    if (kinds.length > 1) {
      for (final MediaTrackingMappingRow mapping
          in await _repository.bookMappings(book.bookKey)) {
        for (final TrackingKind kind in kinds) {
          if (kind.value == mapping.kind) return kind;
        }
      }
    }
    return trackingKindForBookFormat(format);
  }

  /// A manga or PDF changed: a page save reached the end of a chapter or
  /// volume, reading started, or chapters were marked read / unread. Reads the
  /// current state itself (the callers only know their own corner of it):
  /// - online manga series → highest read chapter number (chapter links),
  ///   finished when every listed chapter is read;
  /// - local manga volume / PDF → finished when marked completed (volume
  ///   links send N-1 while reading volume N, N once it is finished).
  ///
  /// Never starts Bangumi's title auto-matching (Bangumi behaviour is
  /// unchanged); an item linked to Bangumi by hand still gets progress.
  Future<void> recordPagedBookProgress(String bookKey) async {
    if (!isOn) return;
    final bool finished = await _repository.isBookFinishedForTracking(
      bookKey: bookKey,
      mangaProgress: _mangaReadProgress,
    );
    await recordBookProgress(
      bookKey: bookKey,
      completedChapterCount: 0,
      completed: finished,
      bangumiAutoMapping: false,
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
    if (!isOn) return;
    if (status < 1 || status > 5) return;
    if (await _isIgnored(TrackingMediaType.game, gameId)) return;
    if (_bangumiAcceptsKind(TrackingKind.game)) {
      await _ensureAutoGameMapping(gameId);
    }
    await _fanOut(
      mediaType: TrackingMediaType.game,
      mediaKey: gameId,
      localProgress: status,
      completed: status == 2,
      monotonic: false,
    );
  }

  Future<MediaTrackingMappingRow?> _ensureAutoGameMapping(String gameId) async {
    final MediaTrackingMappingRow? existing = await _repository.findMapping(
      mediaType: TrackingMediaType.game,
      mediaKey: gameId,
    );
    if (existing != null) return existing;
    return _singleFlightAutoMapping(
      '${TrackingMediaType.game.value}:$gameId',
      () async {
        final AutoGameTrackingSource? source = await _repository
            .loadAutoGameSource(gameId);
        if (source == null) return null;
        final int? scrapedId = source.bangumiSubjectId;
        if (scrapedId != null && scrapedId > 0) {
          return _saveAutoLink(
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
        final List<_BangumiCandidate> subjects = await _searchBangumi(
          keyword: source.name,
          kind: TrackingKind.game,
        );
        final _BangumiCandidate? subject = _uniqueHighConfidenceSubject(
          source.name,
          subjects,
          TrackingKind.game,
        );
        if (subject == null) return null;
        return _saveAutoLink(
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
    if (await _removedByUser(kTrackingProviderBangumi, mediaType, mediaKey)) {
      return null;
    }
    return _singleFlightAutoMapping('${mediaType.value}:$mediaKey', () async {
      final int? scrapedId = source.bangumiSubjectId;
      if (scrapedId != null && scrapedId > 0) {
        return _saveAutoLink(
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
      final String query = parsed.title.isEmpty
          ? source.mediaTitle
          : parsed.title;
      final List<_BangumiCandidate> subjects = await _searchBangumi(
        keyword: query,
        kind: TrackingKind.anime,
      );
      final _BangumiCandidate? subject = _uniqueHighConfidenceSubject(
        query,
        subjects,
        TrackingKind.anime,
      );
      if (subject == null) return null;
      return _saveAutoLink(
        mediaType: mediaType,
        mediaKey: mediaKey,
        mediaTitle: source.mediaTitle,
        kind: TrackingKind.anime,
        subjectId: subject.id,
        subjectName: subject.displayName,
        progressMode: TrackingProgressMode.episode,
        progressOffset: progressOffset,
      );
    });
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
        final AutoBookTrackingSource? source = await _repository
            .loadAutoBookSource(bookKey);
        if (source == null) return null;
        final BookFormat format = BookFormat.parseOrEpub(source.format);
        final TrackingKind kind = trackingKindForBookFormat(format);
        final _PreparedTrackingTitle prepared = _prepareTrackingTitle(
          source.title,
        );
        final List<_BangumiCandidate> subjects = await _searchBangumi(
          keyword: prepared.query,
          kind: kind,
        );
        final _BangumiCandidate? subject = _uniqueHighConfidenceSubject(
          prepared.query,
          subjects,
          kind,
        );
        if (subject == null) return null;
        final bool trackAsVolume =
            format.isPagedImageBook ||
            prepared.volumeNumber != null ||
            subject.volumeCount > 1;
        return _saveAutoLink(
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
          final TrackingProvider? site = _bangumiSite;
          if (site is! TrackingEntryReader) return null;
          final TrackingKind kind = TrackingKind.values.firstWhere(
            (TrackingKind k) => k.value == volumeMapping.kind,
            orElse: () => TrackingKind.novel,
          );
          final TrackingSiteEntry? entry = await (site as TrackingEntryReader)
              .readEntry(volumeMapping.subjectId, kind);
          // 只有远端恰好停在当前卷之前，ep_status 才能作为稳定的累计话数基线。
          // 跳卷或倒回重读时不猜偏移，宁可只同步卷数。
          if (entry != null && entry.progressVolume == volumeNumber - 1) {
            chapterOffset = entry.progress;
          }
        }
        if (chapterOffset == null) return null;
        return _saveAutoLink(
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
        // 被标成私密的作品不建自动映射：建映射要拿它的本地标题去 Bangumi 搜索。
        // 不记 miss（取消私密后应立即可匹配），也不留重试（重试同样会搜）。
        if (await _isAutoMappingKeyPrivate(key) ||
            await _isAutoMappingKeyIgnored(key)) {
          _autoMappingRetry.remove(key);
          _autoMappingErrors.remove(key);
          return null;
        }
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
        engineLog.log('MediaTrackingService.autoMap', error, stackTrace);
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

  /// [key] 形如 `<TrackingMediaType.value>:<mediaKey>`（见各 `_ensureAuto*Mapping`）。
  /// The [provider] mapping for one episode file: the existing one, or a new
  /// one from the scraped MAL id. Never from a title. Only links when the
  /// episode fits the provider's episode count, and when that count equals the
  /// local season's count if both are known (a mismatch means the MAL entry
  /// does not cover the same episodes).
  Future<MediaTrackingMappingRow?> _linkVideoByMalId(
    TrackingProvider provider,
    TrackingAnimeLinker linker,
    String bookUid,
  ) async {
    final MediaTrackingMappingRow? existing = await _repository.findMapping(
      mediaType: TrackingMediaType.video,
      mediaKey: bookUid,
      provider: provider.id,
    );
    if (existing != null) return existing;
    if (await _isAutoMappingKeyPrivate(
          '${TrackingMediaType.video.value}:$bookUid',
        ) ||
        await _removedByUser(provider.id, TrackingMediaType.video, bookUid)) {
      return null;
    }
    final VideoTrackingIds? ids = await _repository.loadVideoTrackingIds(
      bookUid,
    );
    if (ids == null) return null;
    final TrackingLinkedSubject? subject;
    try {
      subject = await linker.animeForMalId(ids.malAnimeId);
    } catch (error, stackTrace) {
      engineLog.log('MediaTrackingService.linkByMalId', error, stackTrace);
      return null;
    }
    if (subject == null) return null;
    final int? remoteCount = subject.episodeCount;
    final int? localCount = ids.episodeCount;
    if (remoteCount != null &&
        (ids.episodeNumber > remoteCount ||
            (localCount != null && localCount != remoteCount))) {
      return null;
    }
    return _saveAutoLink(
      mediaType: TrackingMediaType.video,
      mediaKey: bookUid,
      mediaTitle: ids.title.isEmpty ? subject.name : ids.title,
      kind: TrackingKind.anime,
      subjectId: subject.subjectId,
      subjectName: subject.name,
      progressMode: TrackingProgressMode.episode,
      progressOffset: ids.episodeNumber,
      provider: provider.id,
      linkSource: TrackingLinkSource.id,
    );
  }

  /// [key] as in [_isAutoMappingKeyPrivate], on the do-not-track list.
  Future<bool> _isAutoMappingKeyIgnored(String key) async {
    final int colon = key.indexOf(':');
    if (colon <= 0) return false;
    return (await _repository.loadIgnoreIndex()).covers(
      key.substring(0, colon),
      key.substring(colon + 1),
    );
  }

  Future<bool> _isAutoMappingKeyPrivate(String key) async {
    final int colon = key.indexOf(':');
    if (colon <= 0) return false;
    return isTrackedMediaPrivate(
      await _repository.loadPrivacy(),
      key.substring(0, colon),
      key.substring(colon + 1),
    );
  }

  /// Queues one local event for every enabled provider that has a mapping for
  /// it (Bangumi first), except the provider ids in [skip].
  Future<void> _fanOut({
    required TrackingMediaType mediaType,
    required String mediaKey,
    required int localProgress,
    required bool completed,
    bool monotonic = true,
    Set<String> skip = const <String>{},
  }) async {
    for (final TrackingProvider provider in _registry.all) {
      if (skip.contains(provider.id)) continue;
      await _enqueueAndSync(
        provider: provider,
        mediaType: mediaType,
        mediaKey: mediaKey,
        localProgress: localProgress,
        completed: completed,
        monotonic: monotonic,
      );
    }
  }

  /// [provider] is on, can track this kind/mode, and the kind is switched on.
  bool _acceptsMapping(
    TrackingProvider provider,
    MediaTrackingMappingRow mapping,
  ) {
    final TrackingKind? kind = _trackingKindOf(mapping.kind);
    final TrackingProgressMode? mode = TrackingProgressMode.tryParse(
      mapping.progressMode,
    );
    if (kind == null || mode == null) return false;
    return provider.capabilities.accepts(kind, mode) &&
        isProviderEnabled(provider.id) &&
        isKindEnabled(provider.id, kind);
  }

  static TrackingKind? _trackingKindOf(String value) {
    for (final TrackingKind kind in TrackingKind.values) {
      if (kind.value == value) return kind;
    }
    return null;
  }

  /// The mapping of [provider] for this item, when it may receive updates now.
  Future<MediaTrackingMappingRow?> _routableMapping(
    TrackingProvider provider,
    TrackingMediaType mediaType,
    String mediaKey,
  ) async {
    if (!_isRegistered(provider) || !isProviderEnabled(provider.id)) {
      return null;
    }
    final MediaTrackingMappingRow? mapping = await _repository.findMapping(
      mediaType: mediaType,
      mediaKey: mediaKey,
      provider: provider.id,
    );
    if (mapping == null || !_acceptsMapping(provider, mapping)) return null;
    return mapping;
  }

  Future<void> _enqueueAndSync({
    required TrackingProvider provider,
    required TrackingMediaType mediaType,
    required String mediaKey,
    required int localProgress,
    required bool completed,
    bool monotonic = true,
  }) async {
    final String cacheKey = '${provider.id}|${mediaType.value}:$mediaKey';
    final ({int progress, bool completed})? previous = _lastQueued[cacheKey];
    // 单调事件按“没有前进就不必重复入队”去重；离散状态只在值真的没变时才跳过，
    // 否则状态回退（弃坑→在玩）会被这层内存缓存吃掉，连 outbox 都进不去。
    final bool unchanged =
        previous != null &&
        (monotonic
            ? (previous.progress >= localProgress &&
                  (previous.completed || !completed))
            : (previous.progress == localProgress &&
                  previous.completed == completed));
    if (unchanged) return;
    try {
      if (await _routableMapping(provider, mediaType, mediaKey) == null) {
        return;
      }
      final bool mapped = await _repository.enqueueProgress(
        mediaType: mediaType,
        mediaKey: mediaKey,
        localProgress: localProgress,
        completed: completed,
        monotonic: monotonic,
        provider: provider.id,
      );
      if (!mapped) return;
      _lastQueued[cacheKey] = (
        progress: localProgress,
        completed: monotonic
            ? (completed || (previous?.completed ?? false))
            : completed,
      );
      _requestSync();
    } catch (error, stackTrace) {
      engineLog.log('MediaTrackingService.enqueue', error, stackTrace);
    }
  }

  /// Off ([isOn] false): returns an empty result without touching the
  /// database or any site; queued rows wait for the switch.
  Future<MediaTrackingSyncResult> syncNow({bool force = false}) {
    if (!isOn) {
      return Future<MediaTrackingSyncResult>.value(
        const MediaTrackingSyncResult(succeeded: 0, failed: 0, pending: 0),
      );
    }
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
    // 本轮同步会重新计算下一次重试时刻，旧定时器作废。
    _retryTimer?.cancel();
    _retryTimer = null;
    MediaTrackingSyncResult result = await _reconcileAndSync(force: force);
    // Every round's outcome is kept (BUG-4395): only persisting the last
    // round lost a rejection seen in an earlier one.
    await _persistSyncOutcome(result);
    while (_syncAgainRequested) {
      _syncAgainRequested = false;
      result = await _reconcileAndSync(force: false);
      await _persistSyncOutcome(result);
    }
    await _scheduleBackoffRetry();
    return result;
  }

  /// [providerId] was signed in again (BUG-4395): its "sign-in needed" state
  /// is cleared and what waited for it (backed off while the site refused
  /// the old sign-in) is due now and sent in this sync.
  Future<MediaTrackingSyncResult> resumeAfterSignIn(String providerId) async {
    await _preferences.setPref(
      TrackingProviderPrefKeys.forProvider(providerId).lastSyncUnauthorized,
      false,
    );
    await _repository.retryAllNow(provider: providerId);
    _statusRevision.value++;
    // A sync already running picks the now-due rows up in another round.
    if (_syncInFlight != null) _syncAgainRequested = true;
    return syncNow();
  }

  List<TrackingProvider> get _activeProviders => <TrackingProvider>[
    for (final TrackingProvider provider in _registry.all)
      if (_isActive(provider)) provider,
  ];

  /// BUG-1647：退避到期后自动重试。
  ///
  /// 自动同步原本只有两个触发点——启动一次 + 完成事件当下一次。发送失败的行被
  /// [MediaTrackingRepository.markFailed] 推进 30s..6h 的指数退避后，若没有任何
  /// 定时器在到期时再拉一轮，`dueUpdates` 会一直把它过滤掉：失败行只能等下一个
  /// 完成事件碰巧到来（且恰好已出退避窗口），否则永远要靠手动「立即同步」。
  /// 这里在每轮同步收尾时查 outbox 里最早的 `nextAttemptAt`，挂一只定时器到点
  /// 自动 [syncNow]，把「退避」从死路修成真正的重试计划。顺带覆盖单轮发送上限
  /// （20 条/轮）导致的积压：剩余行 `nextAttemptAt` 为 0，会以最小延迟续跑。
  ///
  /// Only active providers count: rows of a provider that is off or has no
  /// credentials can never be sent, so they must not keep re-arming the timer.
  Future<void> _scheduleBackoffRetry() async {
    final Map<String, Set<TrackingKind>> sendable = <String, Set<TrackingKind>>{
      for (final TrackingProvider provider in _activeProviders)
        provider.id: _sendableKinds(provider),
    }..removeWhere((_, Set<TrackingKind> kinds) => kinds.isEmpty);
    if (sendable.isEmpty) return;
    final int? earliest;
    try {
      earliest = await _repository.earliestNextAttemptAt(sendable: sendable);
    } catch (error, stackTrace) {
      engineLog.log('MediaTrackingService.scheduleRetry', error, stackTrace);
      return;
    }
    if (earliest == null) return;
    final int now = DateTime.now().millisecondsSinceEpoch;
    // 已到期（或从未尝试）的行也至少等一小段再跑，避免与刚结束的这一轮竞争成热循环。
    final Duration delay = Duration(
      milliseconds: math.max(earliest - now, 5000),
    );
    _retryTimer = _retryTimerFactory(delay, () {
      _retryTimer = null;
      unawaited(syncNow());
    });
  }

  /// 取消挂起的重试定时器。生产进程里服务与 app 同寿命；换库/换进程重建实例前
  /// 必须先调这里，否则旧定时器会拿着旧 repository 继续同步。
  void dispose() {
    _retryTimer?.cancel();
    _retryTimer = null;
    unawaited(_autoLinks.close());
  }

  /// Single listener (the app); links made before it listens (the catch-up
  /// right after start) wait for it.
  final StreamController<TrackingAutoLink> _autoLinks =
      StreamController<TrackingAutoLink>();

  /// Every link tracking makes by itself (a sure title match or ids; from
  /// reading, playback, a hand "finished / watched" mark or the catch-up),
  /// once, when it is made. The app tells the user (T1 F9, the user's
  /// option B: automatic linking stays, the user is told). Links the user
  /// makes or approves are not on it, nor the chapter companion of a book
  /// link.
  Stream<TrackingAutoLink> get autoLinks => _autoLinks.stream;

  /// Saves an automatic link if [mediaType] + [mediaKey] has none on
  /// [provider] yet, and tells [autoLinks] when this call made it.
  Future<MediaTrackingMappingRow> _saveAutoLink({
    required TrackingMediaType mediaType,
    required String mediaKey,
    required String mediaTitle,
    required TrackingKind kind,
    required int subjectId,
    required String subjectName,
    required TrackingProgressMode progressMode,
    required int progressOffset,
    String provider = kTrackingProviderBangumi,
    String? linkSource,
    double? confidence,
  }) async {
    final ({MediaTrackingMappingRow row, bool created}) saved =
        await _repository.insertMappingIfAbsent(
          mediaType: mediaType,
          mediaKey: mediaKey,
          mediaTitle: mediaTitle,
          kind: kind,
          subjectId: subjectId,
          subjectName: subjectName,
          progressMode: progressMode,
          progressOffset: progressOffset,
          provider: provider,
          linkSource: linkSource,
          confidence: confidence,
        );
    if (saved.created &&
        mediaType != TrackingMediaType.bookChapter &&
        !_autoLinks.isClosed) {
      _autoLinks.add(
        TrackingAutoLink(
          mapping: saved.row,
          siteName: _registry.byId(provider)?.displayName ?? provider,
        ),
      );
    }
    return saved.row;
  }

  /// 把本轮同步结果落成可见状态。未配置令牌时不写「上次同步」（那一轮什么都没发，
  /// 记上去会让 UI 谎报同步过），但仍要通知 UI 刷新待办计数。
  ///
  /// Written per provider that took part in this run ([MediaTrackingSyncResult.byProvider]).
  Future<void> _persistSyncOutcome(MediaTrackingSyncResult result) async {
    for (final MapEntry<String, MediaTrackingSyncResult> entry
        in result.byProvider.entries) {
      final TrackingProviderPrefKeys keys =
          TrackingProviderPrefKeys.forProvider(entry.key);
      try {
        await _preferences.setPref(
          keys.lastSyncAt,
          DateTime.now().millisecondsSinceEpoch,
        );
        await _preferences.setPref(
          keys.lastSyncSucceeded,
          entry.value.succeeded,
        );
        await _preferences.setPref(keys.lastSyncFailed, entry.value.failed);
        // Only an answer from the site changes "sign-in needed" (BUG-4395):
        // a round that asked it nothing (its rows backed off) proves nothing.
        if (entry.value.succeeded + entry.value.failed > 0) {
          await _preferences.setPref(
            keys.lastSyncUnauthorized,
            entry.value.unauthorized,
          );
        }
      } catch (error, stackTrace) {
        // fail-open：状态记录失败不能影响已经发出去的同步结果本身。
        engineLog.log('MediaTrackingService.persistOutcome', error, stackTrace);
      }
    }
    _statusRevision.value++;
  }

  Future<MediaTrackingSyncResult> _reconcileAndSync({
    required bool force,
  }) async {
    for (final TrackingProvider provider in _activeProviders) {
      // Removed during an earlier provider's pass: keep its watermarks so the
      // pass runs in full when the id is registered again.
      if (!_isRegistered(provider)) continue;
      await _reconcileCompletedVideoProgress(provider);
      await _reconcilePersistedBookProgress(provider);
      await _reconcileGameStatus(provider);
    }
    return _sync(force: force);
  }

  /// [provider]'s mappings that may receive updates now, keyed `type:key`.
  Future<Map<String, MediaTrackingMappingRow>> _routableMappings(
    TrackingProvider provider,
  ) async => <String, MediaTrackingMappingRow>{
    for (final MediaTrackingMappingRow mapping
        in await _repository.listMappings(provider: provider.id))
      if (_acceptsMapping(provider, mapping))
        '${mapping.mediaType}:${mapping.mediaKey}': mapping,
  };

  int _watermark(String key) {
    final Object? stored = _preferences.getPref(key, defaultValue: 0);
    return stored is int ? stored : int.tryParse('$stored') ?? 0;
  }

  /// The catch-up of one kind domain for [provider], shared by videos, books
  /// and games.
  ///
  /// Every linked item's current local progress ([items]) is compared with
  /// what its link last sent ([MediaTrackingMappingRow.sentProgress]) and with
  /// a row already queued for it, so progress that arrives late with an old
  /// timestamp (adopted from Kavita / Audiobookshelf, synced from another
  /// device, restored, made while tracking was off) still goes out once, and
  /// nothing goes again when nothing changed. Never a decrease: a progress
  /// link queues only what is higher (the outbox merges by max). Local reads
  /// only, no network (unlinked Bangumi games aside, see
  /// [_reconcileGameStatus]).
  ///
  /// The watermark pref is no longer what decides. It still marks two things:
  /// 0 = start over (a new account, a game kind switched back on: what every
  /// link sent is forgotten, everything goes again), and the line under which
  /// a link made before v152 (`sentProgress` -1, nothing recorded) takes its
  /// current progress as sent instead of queueing it (the old catch-up had
  /// covered it; no resend of the whole library after the upgrade).
  Future<void> _catchUp({
    required TrackingProvider provider,
    required String watermarkKey,
    required List<TrackingMediaType> mediaTypes,
    required List<_CatchUpItem> items,
    bool monotonic = true,
    Future<void> Function(_CatchUpItem item)? unlinked,
  }) async {
    final int watermark = _watermark(watermarkKey);
    if (watermark == 0) {
      await _repository.clearSentProgress(
        provider: provider.id,
        mediaTypes: mediaTypes,
      );
    }
    final Map<String, MediaTrackingMappingRow> routable =
        await _routableMappings(provider);
    final Map<int, MediaTrackingOutboxRow> queued = await _repository
        .queuedByMapping(provider: provider.id);
    final TrackingIgnoreIndex ignored = await _repository.loadIgnoreIndex();
    final MediaPrivacySnapshot privacy = await _repository.loadPrivacy();
    int nextWatermark = watermark;
    for (final _CatchUpItem item in items) {
      nextWatermark = math.max(nextWatermark, item.evidenceAt);
      final MediaTrackingMappingRow? mapping =
          routable['${item.mediaType.value}:${item.mediaKey}'];
      if (mapping == null) {
        if (unlinked != null && item.evidenceAt > watermark) {
          await unlinked(item);
        }
        continue;
      }
      if (ignored.covers(item.mediaType.value, item.mediaKey) ||
          isTrackedMediaPrivate(privacy, item.mediaType.value, item.mediaKey)) {
        continue;
      }
      final int remote = monotonic
          ? math.max(0, item.localProgress + mapping.progressOffset)
          : item.localProgress + mapping.progressOffset;
      final int? sent = mapping.sentProgress;
      if (sent == kTrackingSentProgressLegacy &&
          watermark > 0 &&
          item.evidenceAt <= watermark) {
        await _repository.adoptSentProgress(
          mapping.id,
          progress: remote,
          completed: item.completed,
        );
        continue;
      }
      final MediaTrackingOutboxRow? waiting = queued[mapping.id];
      final bool covered;
      if (monotonic) {
        final int have = math.max(sent ?? -1, waiting?.progress ?? -1);
        final bool haveCompleted =
            mapping.sentCompleted || (waiting?.completed ?? false);
        covered = remote <= have && (!item.completed || haveCompleted);
      } else {
        // A status: the queued one, else the last sent one, must be it.
        final int? current =
            waiting?.progress ?? (sent != null && sent >= 0 ? sent : null);
        covered = current == remote;
      }
      if (covered) continue;
      await _repository.enqueueProgress(
        mediaType: item.mediaType,
        mediaKey: item.mediaKey,
        localProgress: item.localProgress,
        completed: item.completed,
        monotonic: monotonic,
        provider: provider.id,
      );
    }
    if (nextWatermark == 0) {
      nextWatermark = DateTime.now().millisecondsSinceEpoch;
    }
    if (nextWatermark != watermark) {
      await _preferences.setPref(watermarkKey, nextWatermark);
    }
  }

  /// Play statuses set locally ([_catchUp]). An unlinked game is linked by
  /// the Bangumi path ([recordGameStatus]: a scraped Bangumi id, else a
  /// unique title match) once, when its status is newer than the watermark.
  Future<void> _reconcileGameStatus(TrackingProvider provider) async {
    if (!provider.capabilities.acceptsKind(TrackingKind.game)) return;
    final List<PersistedGameTrackingStatus> statuses = await _repository
        .loadPersistedGameTrackingStatus(afterMs: -1, provider: provider.id);
    await _catchUp(
      provider: provider,
      watermarkKey: TrackingProviderPrefKeys.forProvider(
        provider.id,
      ).gameWatermark,
      mediaTypes: const <TrackingMediaType>[TrackingMediaType.game],
      monotonic: false,
      items: <_CatchUpItem>[
        for (final PersistedGameTrackingStatus item in statuses)
          if (item.status >= 1 && item.status <= 5)
            (
              mediaType: TrackingMediaType.game,
              mediaKey: item.gameId,
              localProgress: item.status,
              completed: item.status == 2,
              evidenceAt: item.evidenceAt,
            ),
      ],
      unlinked: provider.id == kTrackingProviderBangumi
          ? (_CatchUpItem item) => recordGameStatus(
              gameId: item.mediaKey,
              status: item.localProgress,
            )
          : null,
    );
  }

  Future<void> _reconcileCompletedVideoProgress(
    TrackingProvider provider,
  ) async {
    final List<CompletedVideoTrackingProgress> progress = await _repository
        .loadCompletedVideoTrackingProgress(afterMs: -1, provider: provider.id);
    await _catchUp(
      provider: provider,
      watermarkKey: TrackingProviderPrefKeys.forProvider(
        provider.id,
      ).videoWatermark,
      mediaTypes: const <TrackingMediaType>[
        TrackingMediaType.video,
        TrackingMediaType.videoCollection,
      ],
      items: <_CatchUpItem>[
        for (final CompletedVideoTrackingProgress item in progress)
          (
            mediaType: item.mediaType,
            mediaKey: item.mediaKey,
            localProgress: item.localProgress,
            completed: item.completed,
            evidenceAt: item.evidenceAt,
          ),
      ],
    );
  }

  Future<void> _reconcilePersistedBookProgress(
    TrackingProvider provider,
  ) async {
    final List<PersistedBookTrackingProgress> progress = await _repository
        .loadPersistedBookTrackingProgress(
          afterMs: -1,
          provider: provider.id,
          mangaProgress: _mangaReadProgress,
        );
    await _catchUp(
      provider: provider,
      watermarkKey: TrackingProviderPrefKeys.forProvider(
        provider.id,
      ).bookWatermark,
      mediaTypes: const <TrackingMediaType>[
        TrackingMediaType.book,
        TrackingMediaType.bookChapter,
      ],
      items: <_CatchUpItem>[
        for (final PersistedBookTrackingProgress item in progress)
          (
            mediaType: item.mediaType,
            mediaKey: item.mediaKey,
            localProgress: item.localProgress,
            completed: item.completed,
            evidenceAt: item.evidenceAt,
          ),
      ],
    );
  }

  /// Sends due rows for each active provider in turn. Each provider has its own
  /// session and error handling: one provider failing, or being unauthorized,
  /// never stops another.
  Future<MediaTrackingSyncResult> _sync({required bool force}) async {
    final List<TrackingProvider> active = _activeProviders;
    if (force) {
      for (final TrackingProvider provider in active) {
        await _repository.retryAllNow(provider: provider.id);
      }
    }
    int succeeded = 0;
    int failed = 0;
    bool unauthorized = false;
    final Map<String, MediaTrackingSyncResult> byProvider =
        <String, MediaTrackingSyncResult>{};
    for (final TrackingProvider provider in active) {
      // Removed or replaced while an earlier provider was sending: its rows
      // wait for the provider registered under that id.
      if (!_isRegistered(provider)) continue;
      final MediaTrackingSyncResult result = await _syncProvider(provider);
      // A provider removed before it sent anything leaves no "last sync".
      if (_isRegistered(provider) || result.succeeded + result.failed > 0) {
        byProvider[provider.id] = result;
      }
      succeeded += result.succeeded;
      failed += result.failed;
      unauthorized = unauthorized || result.unauthorized;
    }
    return MediaTrackingSyncResult(
      succeeded: succeeded,
      failed: failed,
      pending: await _repository.pendingCount(),
      unauthorized: unauthorized,
      byProvider: byProvider,
    );
  }

  Future<MediaTrackingSyncResult> _syncProvider(
    TrackingProvider provider,
  ) async {
    final Set<TrackingKind> kinds = _sendableKinds(provider);
    final List<PendingTrackingUpdate> updates = kinds.isEmpty
        ? const <PendingTrackingUpdate>[]
        : await _repository.dueUpdates(provider: provider.id, kinds: kinds);
    if (updates.isEmpty) {
      return MediaTrackingSyncResult(
        succeeded: 0,
        failed: 0,
        pending: await _repository.pendingCount(provider: provider.id),
      );
    }

    final TrackingProviderSession session;
    try {
      session = await provider.openSession();
    } catch (error, stackTrace) {
      engineLog.log('MediaTrackingService.authenticate', error, stackTrace);
      if (!_isRegistered(provider)) {
        // Removed while signing in (a plugin torn down): not this row's
        // fault, so nothing is marked failed.
        return MediaTrackingSyncResult(
          succeeded: 0,
          failed: 0,
          pending: await _repository.pendingCount(provider: provider.id),
        );
      }
      for (final PendingTrackingUpdate update in updates) {
        await _repository.markFailed(update.outbox, error);
        await _logActivity(update, error: error);
      }
      return MediaTrackingSyncResult(
        succeeded: 0,
        failed: updates.length,
        pending: await _repository.pendingCount(provider: provider.id),
        unauthorized:
            provider.classify(error) == TrackingFailureKind.unauthorized,
      );
    }

    int succeeded = 0;
    int failed = 0;
    bool unauthorized = false;
    try {
      for (int i = 0; i < updates.length; i++) {
        // Removed or replaced mid-batch: the rest waits, untouched, for the
        // provider registered under this id.
        if (!_isRegistered(provider)) break;
        final PendingTrackingUpdate update = updates[i];
        try {
          await provider.push(session, update);
          await _repository.markSucceeded(update.outbox);
          await _logActivity(update);
          succeeded++;
        } catch (error, stackTrace) {
          engineLog.log('MediaTrackingService.sync', error, stackTrace);
          // Failed because the provider went away (plugin torn down while
          // this push ran): the row stays as it was.
          if (!_isRegistered(provider)) break;
          await _repository.markFailed(update.outbox, error);
          await _logActivity(update, error: error);
          failed++;
          final TrackingFailureKind kind = provider.classify(error);
          unauthorized = kind == TrackingFailureKind.unauthorized;
          if (unauthorized) break;
          if (kind == TrackingFailureKind.rateLimited) {
            // Sending the rest now would only collect more 429s; back them
            // all off together without another request.
            for (final PendingTrackingUpdate rest in updates.skip(i + 1)) {
              await _repository.markFailed(rest.outbox, error);
              await _logActivity(rest, error: error);
              failed++;
            }
            break;
          }
        }
      }
    } finally {
      session.close();
    }
    return MediaTrackingSyncResult(
      succeeded: succeeded,
      failed: failed,
      pending: await _repository.pendingCount(provider: provider.id),
      unauthorized: unauthorized,
    );
  }
}

/// One linked item's local progress for the catch-up
/// ([MediaTrackingService._catchUp]).
typedef _CatchUpItem = ({
  TrackingMediaType mediaType,
  String mediaKey,
  int localProgress,
  bool completed,
  int evidenceAt,
});
