import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import 'package:fushi/src/media/torrent/anime_download_subscription.dart';
import 'package:fushi/src/media/video/airing_calendar_cache.dart';
import 'package:fushi/src/media/video/airing_discovery_mapping.dart'
    show anilistIdOfVideoDownloadSubscription;
import 'package:fushi/src/media/video/airing_week.dart';
import 'package:fushi/src/media/video/anilist_client.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/torrent/download_timeouts.dart';

/// 放送日历的唯一取数路径：完整日历页（`airing_calendar_page.dart`）与发现页
/// 「今日放送」小模块（`discovery/airing_today_shelf.dart`）都走这里，不各抓一份。
///
/// 口径：本地相关性（合集绑定的 anilistId + 下载订阅的 anilistId）恒重建；放送表
/// 按 内存缓存 → 偏好缓存 → AniList 分页拉取 取（airing_calendar_cache.dart，
/// **无 Drift schema 改动**）。HTTP 客户端经 [AppModel.createDownloadHttpClient]
/// 走全应用统一代理出口。

/// 「显示本季全部」分页上限：AniList perPage=50，一周全量 airing 实测数百条，
/// 12 页（600 条）够覆盖；防御性上限避免异常响应导致无限翻页打爆 rate limit。
const int kAiringCalendarMaxPages = 12;

/// 翻页间隔：AniList 约 90 req/min，700ms 一页远低于限额，避免 429。
const Duration kAiringCalendarPageInterval = Duration(milliseconds: 700);

/// 一次取数请求：[weekStart] 是本地周一 00:00（`localWeekStart`）。
class AiringCalendarRequest {
  const AiringCalendarRequest({
    required this.weekStart,
    this.day,
    this.force = false,
    this.isCancelled,
  });

  final DateTime weekStart;

  /// 只要这一本地日（[weekStart] 所在周内）的放送：发现页「今日放送」只显示今天，
  /// 不必等整周拉完（冷启动整周 = 数页串行 + 页间 700ms，弱网下长时间骨架屏）。
  /// 本周整周缓存命中时直接从中截取当天，不发请求；null = 整周（完整日历页）。
  final DateTime? day;

  /// true = 用户点刷新，绕过两层缓存。
  final bool force;

  /// 调用方已销毁时返回 true：停止后续翻页（省网络请求，不省结果）。
  final bool Function()? isCancelled;
}

/// 一周的放送快照 + 本地相关性 id 集合（徽章 / 默认过滤 / 引导空态用）。
class AiringCalendarSnapshot {
  const AiringCalendarSnapshot({
    required this.libraryAnilistIds,
    required this.subscribedAnilistIds,
    required this.episodes,
  });

  final Set<int> libraryAnilistIds;
  final Set<int> subscribedAnilistIds;
  final List<AniListAiringEpisode> episodes;

  /// [day] 当天（本地日期）播出的条目，按放送时刻升序；不在本周窗口内返回空。
  List<AniListAiringEpisode> episodesOn(DateTime weekStart, DateTime day) {
    final int index = daysBetweenLocalDates(weekStart, day);
    if (index < 0 || index > 6) return const <AniListAiringEpisode>[];
    return groupEpisodesByLocalWeekday(
      episodes: episodes,
      weekStartLocal: weekStart,
    )[index];
  }
}

/// 页面消费的取数端口（生产装配 = [loadAiringCalendarWeek] 绑定 [AppModel]；
/// widget 测试可注入确定性实现）。
typedef AiringCalendarLoader =
    Future<AiringCalendarSnapshot> Function(AiringCalendarRequest request);

/// 取一周放送：本地映射（合集 / 订阅）恒重建，放送表按缓存口径取。
Future<AiringCalendarSnapshot> loadAiringCalendarWeek(
  AppModel appModel,
  AiringCalendarRequest request,
) async {
  final List<MediaCollectionRow> collections = await appModel.database
      .getAllMediaCollections();
  final AnimeDownloadSubscriptionStore? store =
      appModel.animeDownloadSubscriptionStore;
  final List<AnimeDownloadSubscription> subscriptions = store == null
      ? const <AnimeDownloadSubscription>[]
      : await store.loadAll();
  final Set<int> libraryIds = <int>{
    for (final MediaCollectionRow c in collections)
      if (c.anilistId != null) c.anilistId!,
  };
  // 订阅有两套存储：旧版番剧订阅 + 发现页订阅表（从日历点进详情页订阅写的是后者）。
  // 只认前者 = 刚订阅的番照样不显示「订阅中」。
  final List<VideoDownloadSubscriptionRow> discoverySubscriptions =
      await appModel.database.getVideoDownloadSubscriptions();
  final Set<int> subscribedIds = <int>{
    for (final AnimeDownloadSubscription s in subscriptions) s.anilistId,
    for (final VideoDownloadSubscriptionRow row in discoverySubscriptions)
      ?anilistIdOfVideoDownloadSubscription(row),
  };
  // 放送表恒取当季全量（用户 2026-10-20 去掉「显示本季全部」开关、默认全显）；
  // 本地映射只驱动「在库 / 订阅中」徽章。
  final List<AniListAiringEpisode> episodes = await _fetchAiringWeekEpisodes(
    appModel,
    request: request,
    filterIds: null,
  );
  return AiringCalendarSnapshot(
    libraryAnilistIds: libraryIds,
    subscribedAnilistIds: subscribedIds,
    episodes: episodes,
  );
}

/// 取本周窗口的放送条目：内存缓存 → 偏好缓存 → AniList 分页拉取。
Future<List<AniListAiringEpisode>> _fetchAiringWeekEpisodes(
  AppModel appModel, {
  required AiringCalendarRequest request,
  required List<int>? filterIds,
}) {
  return fetchAiringScheduleEpisodes(
    request: request,
    filterIds: filterIds,
    readPersisted: () =>
        appModel.prefsRepo.getPref(
              kAiringCalendarCachePrefKey,
              defaultValue: '',
            )
            as String,
    writePersisted: (String raw) =>
        appModel.prefsRepo.setPref(kAiringCalendarCachePrefKey, raw),
    createHttpClient: appModel.createDownloadHttpClient,
  );
}

/// 放送表取数的缓存与分页口径（与 [AppModel] 解耦，便于单测）。
///
/// - 整周请求（`request.day == null`）：签名 `<周一>|all`，按 内存 → 偏好 → 分页拉取。
/// - 单日请求：先查**整周**缓存，命中就截取当天、不发请求；未命中再查单日缓存
///   （签名 `day:<当日 00:00>|all`，与整周签名不会相撞），最后只拉这一天的窗口
///   （一天的条目通常一两页）。单日结果也写进两层缓存：它只会顶掉已经失效的整周
///   缓存（整周有效时根本走不到拉取），之后进完整日历页时整周按签名未命中照常拉。
/// - 分页仍串行 + 页间 [pageInterval]（AniList 约 90 req/min 的限流是真约束）。
@visibleForTesting
Future<List<AniListAiringEpisode>> fetchAiringScheduleEpisodes({
  required AiringCalendarRequest request,
  required List<int>? filterIds,
  required String Function() readPersisted,
  required Future<void> Function(String raw) writePersisted,
  required Future<http.Client> Function() createHttpClient,
  int? nowMs,
  Duration pageInterval = kAiringCalendarPageInterval,
}) async {
  final DateTime weekStart = request.weekStart;
  final int weekStartSeconds = _epochSeconds(weekStart);
  final int weekEndSeconds = _epochSeconds(
    DateTime(weekStart.year, weekStart.month, weekStart.day + 7),
  );
  final String weekSignature = airingCacheSignature(
    weekStartEpochSeconds: weekStartSeconds,
    mediaIds: filterIds,
  );
  final DateTime? day = request.day;
  final int windowStartSeconds;
  final int windowEndSeconds;
  final String windowSignature;
  if (day == null) {
    windowStartSeconds = weekStartSeconds;
    windowEndSeconds = weekEndSeconds;
    windowSignature = weekSignature;
  } else {
    windowStartSeconds = _epochSeconds(DateTime(day.year, day.month, day.day));
    windowEndSeconds = _epochSeconds(
      DateTime(day.year, day.month, day.day + 1),
    );
    windowSignature = airingDayCacheSignature(
      dayStartEpochSeconds: windowStartSeconds,
      mediaIds: filterIds,
    );
  }
  final int now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  if (!request.force) {
    final String raw = readPersisted();
    AiringScheduleCache? lookup(String signature) {
      final AiringScheduleCache? memory = AiringMemoryCache.get(
        signature,
        nowMs: now,
      );
      if (memory != null) return memory;
      final AiringScheduleCache? persisted = decodeAiringScheduleCache(
        raw,
        signature: signature,
        nowMs: now,
      );
      if (persisted != null) AiringMemoryCache.put(persisted);
      return persisted;
    }

    final AiringScheduleCache? week = lookup(weekSignature);
    if (week != null) {
      if (day == null) return week.episodes;
      return <AniListAiringEpisode>[
        for (final AniListAiringEpisode e in week.episodes)
          if (e.airingAtSeconds >= windowStartSeconds &&
              e.airingAtSeconds < windowEndSeconds)
            e,
      ];
    }
    if (day != null) {
      final AiringScheduleCache? dayCache = lookup(windowSignature);
      if (dayCache != null) return dayCache.episodes;
    }
  }
  final http.Client httpClient = await createHttpClient();
  final AniListClient client = AniListClient(client: httpClient);
  try {
    final List<AniListAiringEpisode> all = <AniListAiringEpisode>[];
    int page = 1;
    while (true) {
      // airingAt_greater 是严格大于：-1 让窗口起点整点的条目也进窗口。
      final AniListAiringPage result = await client
          .fetchAiringSchedulePage(
            airingAtGreater: windowStartSeconds - 1,
            airingAtLesser: windowEndSeconds,
            mediaIds: filterIds,
            page: page,
          )
          .timeout(kDownloadDiscoveryTimeout);
      all.addAll(result.episodes);
      if (!result.hasNextPage || page >= kAiringCalendarMaxPages) break;
      // 调用方已销毁就停止翻页：省的是后续网络请求。
      if (request.isCancelled?.call() ?? false) break;
      page += 1;
      await Future<void>.delayed(pageInterval);
    }
    final AiringScheduleCache cache = AiringScheduleCache(
      fetchedAtMs: now,
      signature: windowSignature,
      episodes: all,
    );
    AiringMemoryCache.put(cache);
    await writePersisted(encodeAiringScheduleCache(cache));
    return all;
  } finally {
    client.close();
  }
}

int _epochSeconds(DateTime time) => time.millisecondsSinceEpoch ~/ 1000;
