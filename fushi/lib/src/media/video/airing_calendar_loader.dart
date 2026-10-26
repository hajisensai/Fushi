import 'package:http/http.dart' as http;

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
    this.force = false,
    this.isCancelled,
  });

  final DateTime weekStart;

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
  final Set<int> libraryIds = <int>{
    for (final MediaCollectionRow c in collections)
      if (c.anilistId != null) c.anilistId!,
  };
  // 订阅只认发现页订阅表（从日历点进详情页订阅写的就是它；旧 JSON 番剧订阅启动
  // 时已迁进同一张表）。
  final List<VideoDownloadSubscriptionRow> discoverySubscriptions =
      await appModel.database.getVideoDownloadSubscriptions();
  final Set<int> subscribedIds = <int>{
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
}) async {
  final DateTime weekStart = request.weekStart;
  final int weekStartSeconds = weekStart.millisecondsSinceEpoch ~/ 1000;
  final int weekEndSeconds =
      DateTime(
        weekStart.year,
        weekStart.month,
        weekStart.day + 7,
      ).millisecondsSinceEpoch ~/
      1000;
  final String signature = airingCacheSignature(
    weekStartEpochSeconds: weekStartSeconds,
    mediaIds: filterIds,
  );
  final int nowMs = DateTime.now().millisecondsSinceEpoch;
  if (!request.force) {
    final AiringScheduleCache? memory = AiringMemoryCache.get(
      signature,
      nowMs: nowMs,
    );
    if (memory != null) return memory.episodes;
    final String raw =
        appModel.prefsRepo.getPref(
              kAiringCalendarCachePrefKey,
              defaultValue: '',
            )
            as String;
    final AiringScheduleCache? persisted = decodeAiringScheduleCache(
      raw,
      signature: signature,
      nowMs: nowMs,
    );
    if (persisted != null) {
      AiringMemoryCache.put(persisted);
      return persisted.episodes;
    }
  }
  final http.Client httpClient = await appModel.createDownloadHttpClient();
  final AniListClient client = AniListClient(client: httpClient);
  try {
    final List<AniListAiringEpisode> all = <AniListAiringEpisode>[];
    int page = 1;
    while (true) {
      // airingAt_greater 是严格大于：-1 让周一 00:00 整点的条目也进窗口。
      final AniListAiringPage result = await client
          .fetchAiringSchedulePage(
            airingAtGreater: weekStartSeconds - 1,
            airingAtLesser: weekEndSeconds,
            mediaIds: filterIds,
            page: page,
          )
          .timeout(kDownloadDiscoveryTimeout);
      all.addAll(result.episodes);
      if (!result.hasNextPage || page >= kAiringCalendarMaxPages) break;
      // 调用方已销毁就停止翻页：省的是后续网络请求。
      if (request.isCancelled?.call() ?? false) break;
      page += 1;
      await Future<void>.delayed(kAiringCalendarPageInterval);
    }
    final AiringScheduleCache cache = AiringScheduleCache(
      fetchedAtMs: nowMs,
      signature: signature,
      episodes: all,
    );
    AiringMemoryCache.put(cache);
    await appModel.prefsRepo.setPref(
      kAiringCalendarCachePrefKey,
      encodeAiringScheduleCache(cache),
    );
    return all;
  } finally {
    client.close();
  }
}
