import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import 'package:fushi/src/media/torrent/anime_download_subscription.dart';
import 'package:fushi/src/media/torrent/download_network_proxy.dart';
import 'package:fushi/src/media/video/airing_calendar_cache.dart';
import 'package:fushi/src/media/video/airing_discovery_mapping.dart';
import 'package:fushi/src/media/video/airing_week.dart';
import 'package:fushi/src/media/video/anilist_client.dart';
import 'package:fushi/src/media/video/cover_ui/portrait_cover_image.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/video_discovery_detail_page.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

/// 放送日历页（hayase Schedule 式周历，2026-08-21 重做）：周一到周日七列
/// （窄屏切按天分组列表），默认只显示与本地相关的番剧——合集绑定的 anilistId
/// + 下载订阅的 anilistId；「显示本季全部」开关拉当季全量 airing。
///
/// **每个条目都可点**：合成 [VideoDiscoveryItem]（airing_discovery_mapping）
/// 后进发现详情页，搜索资源 / 订阅 / 搜索字幕 / 在库播放全部走 [actions] 的
/// 既有装配——旧版「不在库也没订阅就不可点」的死条目形态（用户原话「根本
/// 下载不出来」）由此消除。数据走 AniList airingSchedules
/// （[AniListClient.fetchAiringSchedulePage]，HTTP 客户端经
/// [AppModel.createDownloadHttpClient] 走既有下载代理配置）；缓存内存 + 偏好
/// 两层（airing_calendar_cache.dart），**无 Drift schema 改动**。
class AiringCalendarPage extends ConsumerStatefulWidget {
  const AiringCalendarPage({
    super.key,
    this.actions = const VideoDiscoveryActions(),
  });

  /// 发现详情页动作装配（生产装配点是 home_page 的
  /// `_productionVideoDiscoveryActions`；默认空动作 = 详情页只读）。
  final VideoDiscoveryActions actions;

  @override
  ConsumerState<AiringCalendarPage> createState() => _AiringCalendarPageState();
}

class _AiringCalendarPageState extends ConsumerState<AiringCalendarPage> {
  /// 「显示本季全部」分页上限：AniList perPage=50，一周全量 airing 实测数百条，
  /// 12 页（600 条）够覆盖；防御性上限避免异常响应导致无限翻页打爆 rate limit。
  static const int _maxPages = 12;

  /// 翻页间隔：AniList 约 90 req/min，700ms 一页远低于限额，避免 429。
  static const Duration _pageInterval = Duration(milliseconds: 700);

  /// 七列布局的最小宽度；再窄切按天分组列表。
  static const double _wideLayoutMinWidth = 900;

  late DateTime _weekStart = localWeekStart(DateTime.now());
  bool _showAll = false;
  bool _loading = true;
  String? _errorDetail;
  List<AniListAiringEpisode> _episodes = const <AniListAiringEpisode>[];

  /// 本地相关性只影响「在库/订阅中」徽章与默认过滤集；条目动作一律走发现
  /// 详情页，所以这里只需要 id 集合，不再持有整行对象。
  Set<int> _libraryAnilistIds = <int>{};
  Set<int> _subscribedAnilistIds = <int>{};

  /// intl 星期名数据是否就绪（与 collections_page 同范式：未就绪先渲染 ISO
  /// 日期，数据到位后 setState 换本地化星期名）。
  bool _dateSymbolsReady = false;

  AppModel get _appModel => ref.read(appProvider);

  @override
  void initState() {
    super.initState();
    unawaited(initializeDateFormatting().then((_) {
      if (mounted) setState(() => _dateSymbolsReady = true);
    }));
    unawaited(_load());
  }

  /// 重载整页：本地映射（合集/订阅）恒重建，放送表按缓存口径取。
  /// [force] = 用户点刷新，绕过两层缓存。
  Future<void> _load({bool force = false}) async {
    setState(() {
      _loading = true;
      _errorDetail = null;
    });
    try {
      final List<MediaCollectionRow> collections =
          await _appModel.database.getAllMediaCollections();
      final AnimeDownloadSubscriptionStore? store =
          _appModel.animeDownloadSubscriptionStore;
      final List<AnimeDownloadSubscription> subscriptions = store == null
          ? const <AnimeDownloadSubscription>[]
          : await store.loadAll();
      final Set<int> libraryIds = <int>{
        for (final MediaCollectionRow c in collections)
          if (c.anilistId != null) c.anilistId!,
      };
      final Set<int> subscribedIds = <int>{
        for (final AnimeDownloadSubscription s in subscriptions) s.anilistId,
      };
      final List<int> boundIds = <int>{...libraryIds, ...subscribedIds}.toList()
        ..sort();
      final List<int>? filterIds = _showAll ? null : boundIds;
      List<AniListAiringEpisode> episodes = const <AniListAiringEpisode>[];
      // 相关模式且零绑定：不发网络请求，直接进引导空态。
      if (filterIds == null || filterIds.isNotEmpty) {
        episodes = await _fetchEpisodes(filterIds: filterIds, force: force);
      }
      if (!mounted) return;
      setState(() {
        _libraryAnilistIds = libraryIds;
        _subscribedAnilistIds = subscribedIds;
        _episodes = episodes;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorDetail = error.toString();
      });
    }
  }

  /// 取本周窗口的放送条目：内存缓存 → 偏好缓存 → AniList 分页拉取。
  Future<List<AniListAiringEpisode>> _fetchEpisodes({
    required List<int>? filterIds,
    required bool force,
  }) async {
    final int weekStartSeconds = _weekStart.millisecondsSinceEpoch ~/ 1000;
    final int weekEndSeconds = DateTime(
          _weekStart.year,
          _weekStart.month,
          _weekStart.day + 7,
        ).millisecondsSinceEpoch ~/
        1000;
    final String signature = airingCacheSignature(
      weekStartEpochSeconds: weekStartSeconds,
      mediaIds: filterIds,
    );
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    if (!force) {
      final AiringScheduleCache? memory =
          AiringMemoryCache.get(signature, nowMs: nowMs);
      if (memory != null) return memory.episodes;
      final String raw = _appModel.prefsRepo
          .getPref(kAiringCalendarCachePrefKey, defaultValue: '') as String;
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
    final http.Client httpClient = await _appModel.createDownloadHttpClient();
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
        if (!result.hasNextPage || page >= _maxPages) break;
        // 页面已销毁就停止翻页：不省 setState（末尾已有保护），省的是后续网络请求。
        if (!mounted) break;
        page += 1;
        await Future<void>.delayed(_pageInterval);
      }
      final AiringScheduleCache cache = AiringScheduleCache(
        fetchedAtMs: nowMs,
        signature: signature,
        episodes: all,
      );
      AiringMemoryCache.put(cache);
      await _appModel.prefsRepo.setPref(
        kAiringCalendarCachePrefKey,
        encodeAiringScheduleCache(cache),
      );
      return all;
    } finally {
      client.close();
    }
  }

  void _shiftWeek(int days) {
    setState(() {
      _weekStart = DateTime(
        _weekStart.year,
        _weekStart.month,
        _weekStart.day + days,
      );
    });
    unawaited(_load());
  }

  /// 任何日历条目 → 发现详情页：搜索资源 / 订阅 / 字幕 / 在库播放全在那里，
  /// 回来后重载本页映射（订阅/入库状态可能变了，徽章要跟上）。
  Future<void> _openEpisode(AniListAiringEpisode episode) async {
    await Navigator.push<void>(
      context,
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => VideoDiscoveryDetailPage(
          item: discoveryItemFromAiringEpisode(episode),
          actions: widget.actions,
        ),
      ),
    );
    if (mounted) unawaited(_load());
  }

  String _weekdayName(DateTime day) {
    if (!_dateSymbolsReady) return FushiTimeFormat.dayKey(day);
    final String locale = LocaleSettings.currentLocale.languageTag;
    DateFormat format;
    try {
      format = DateFormat.E(locale);
    } on ArgumentError {
      format = DateFormat.E();
    }
    return format.format(day);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(t.download_airing_calendar_title),
        actions: <Widget>[
          IconButton(
            tooltip: t.refresh,
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : () => unawaited(_load(force: true)),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          _buildToolbar(theme),
          Expanded(child: _buildBody(theme)),
        ],
      ),
    );
  }

  Widget _buildToolbar(ThemeData theme) {
    final DateTime weekEnd = DateTime(
      _weekStart.year,
      _weekStart.month,
      _weekStart.day + 6,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: <Widget>[
          IconButton(
            tooltip: t.download_airing_calendar_week_prev,
            icon: const Icon(Icons.chevron_left),
            onPressed: _loading ? null : () => _shiftWeek(-7),
          ),
          Text(
            '${FushiTimeFormat.dayKey(_weekStart)} ~ '
            '${FushiTimeFormat.dayKey(weekEnd)}',
            style: theme.textTheme.titleSmall,
          ),
          IconButton(
            tooltip: t.download_airing_calendar_week_next,
            icon: const Icon(Icons.chevron_right),
            onPressed: _loading ? null : () => _shiftWeek(7),
          ),
          const Spacer(),
          FilterChip(
            label: Text(t.download_airing_calendar_show_all),
            selected: _showAll,
            onSelected: _loading
                ? null
                : (bool value) {
                    setState(() => _showAll = value);
                    unawaited(_load());
                  },
          ),
        ],
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final String? errorDetail = _errorDetail;
    if (errorDetail != null) {
      return _buildError(theme, errorDetail);
    }
    if (!_showAll &&
        _libraryAnilistIds.isEmpty &&
        _subscribedAnilistIds.isEmpty) {
      return _buildCenteredNote(
        theme,
        icon: Icons.event_note_outlined,
        message: t.download_airing_calendar_empty_guidance,
      );
    }
    if (_episodes.isEmpty) {
      return _buildCenteredNote(
        theme,
        icon: Icons.event_available_outlined,
        message: t.download_airing_calendar_week_empty,
      );
    }
    final List<List<AniListAiringEpisode>> buckets =
        groupEpisodesByLocalWeekday(
      episodes: _episodes,
      weekStartLocal: _weekStart,
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool wide = constraints.maxWidth >= _wideLayoutMinWidth;
        return wide
            ? _buildWeekColumns(theme, buckets)
            : _buildDayList(theme, buckets);
      },
    );
  }

  /// 网络失败：如实展示错误详情 + 重试按钮（不吞、不静默降级）。
  Widget _buildError(ThemeData theme, String detail) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.cloud_off, size: 40, color: theme.colorScheme.error),
              const SizedBox(height: 12),
              Text(
                t.download_airing_calendar_error,
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                detail,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                icon: const Icon(Icons.refresh),
                label: Text(t.anime_download_retry),
                onPressed: () => unawaited(_load(force: true)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCenteredNote(
    ThemeData theme, {
    required IconData icon,
    required String message,
  }) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 40, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(height: 12),
              Text(
                message,
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 宽屏：周一到周日七列。
  Widget _buildWeekColumns(
    ThemeData theme,
    List<List<AniListAiringEpisode>> buckets,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (int i = 0; i < 7; i++)
          Expanded(
            child: Column(
              children: <Widget>[
                _buildDayHeader(theme, i),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 12),
                    children: <Widget>[
                      for (final AniListAiringEpisode episode in buckets[i])
                        _buildEpisodeTile(theme, episode),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// 窄屏：按天分组的列表（只列有条目的天）。
  Widget _buildDayList(
    ThemeData theme,
    List<List<AniListAiringEpisode>> buckets,
  ) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 12),
      children: <Widget>[
        for (int i = 0; i < 7; i++)
          if (buckets[i].isNotEmpty) ...<Widget>[
            _buildDayHeader(theme, i),
            for (final AniListAiringEpisode episode in buckets[i])
              _buildEpisodeTile(theme, episode),
          ],
      ],
    );
  }

  Widget _buildDayHeader(ThemeData theme, int weekdayIndex) {
    final DateTime day = DateTime(
      _weekStart.year,
      _weekStart.month,
      _weekStart.day + weekdayIndex,
    );
    final bool isToday = daysBetweenLocalDates(day, DateTime.now()) == 0;
    final String date = FushiTimeFormat.dayKey(day).substring(5);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        '${_weekdayName(day)} $date',
        style: theme.textTheme.titleSmall?.copyWith(
          color: isToday ? theme.colorScheme.primary : null,
          fontWeight: isToday ? FontWeight.bold : null,
        ),
      ),
    );
  }

  Widget _buildEpisodeTile(ThemeData theme, AniListAiringEpisode episode) {
    final bool inLibrary = _libraryAnilistIds.contains(episode.mediaId);
    final bool subscribed = _subscribedAnilistIds.contains(episode.mediaId);
    final DateTime local = airingAtToLocal(episode.airingAtSeconds);
    final String episodeLabel =
        t.download_airing_calendar_episode_label(episode: episode.episode);
    return FushiListItem(
      key: ValueKey<String>(
        'airing-episode-${episode.mediaId}-${episode.episode}',
      ),
      density: FushiListDensity.compact,
      // 重做后每个条目都可点：进发现详情页拿 搜索资源/订阅/字幕/播放。
      onTap: () => unawaited(_openEpisode(episode)),
      leading: _buildCover(theme, episode.media.coverUrl),
      // 条目落在 ListView 里（高度自由），可以安全放宽到两行——番名普遍很长，
      // 单行 ellipsis 在七列窄栏里只看得到开头几个字。
      titleMaxLines: 2,
      title: Text(
        episode.media.displayTitle,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Wrap(
        spacing: 8,
        runSpacing: 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          Text('${FushiTimeFormat.hourMinute(local)} $episodeLabel'),
          if (inLibrary)
            _buildBadge(
              theme,
              t.download_airing_calendar_in_library,
              theme.colorScheme.primary,
            ),
          if (subscribed)
            _buildBadge(
              theme,
              t.download_airing_calendar_subscribed,
              theme.colorScheme.tertiary,
            ),
        ],
      ),
    );
  }

  /// 封面缩略图（2:3，与发现页卡片同一图源与占位形态）。模型里一直有
  /// coverUrl，旧版从没画过——纯文本行是「丑」的主因之一。
  Widget _buildCover(ThemeData theme, String? coverUrl) {
    const double width = 40;
    const double height = 60;
    final String url = coverUrl?.trim() ?? '';
    return ClipRRect(
      borderRadius: FushiBorderRadius.chip,
      child: SizedBox(
        width: width,
        height: height,
        child: url.isEmpty
            ? ColoredBox(
                color: theme.colorScheme.surfaceContainerHighest,
                child: Icon(
                  Icons.movie_outlined,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            : PortraitCoverImage(image: CachedNetworkImageProvider(url)),
      ),
    );
  }

  Widget _buildBadge(ThemeData theme, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: FushiBorderRadius.chip,
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}
