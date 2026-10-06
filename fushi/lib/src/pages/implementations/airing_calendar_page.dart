import 'dart:async';

import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import 'package:fushi/src/media/torrent/anime_download_subscription.dart';
import 'package:fushi_engine/media/torrent/download_timeouts.dart';
import 'package:fushi/src/media/video/airing_calendar_cache.dart';
import 'package:fushi/src/media/video/airing_discovery_mapping.dart';
import 'package:fushi/src/media/video/airing_week.dart';
import 'package:fushi/src/media/video/anilist_client.dart';
import 'package:fushi/src/media/video/anilist_failure_notice.dart';
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
/// [AppModel.createDownloadHttpClient] 走全应用统一代理出口）；缓存内存 + 偏好
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

  /// 失败类别：决定错误页的主文案说的是「AniList 官方停服」「被限流」还是
  /// 「连不上」。与 [_errorDetail] 同生共死（一起赋值、一起清空）。
  AniListFailureKind? _errorKind;
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
      _errorKind = null;
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
        _errorKind = classifyAniListError(error);
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
    // 统一页面壳：M3E 浮动页头（滚动收起）/ Apple 大标题；周切换条挂在页头下沿，
    // 随页头一起收起、回滚出现。
    return FushiPageScaffold(
      title: t.download_airing_calendar_title,
      actions: <Widget>[
        FushiIconButtonControl(
          tooltip: t.refresh,
          icon: const FushiIcon(FushiIcons.refresh),
          onPressed: _loading ? null : () => unawaited(_load(force: true)),
        ),
      ],
      headerBottom: _buildToolbar(theme),
      body: AnimatedSwitcher(
        duration: context.fushiMotion.effectsDefault.duration,
        switchInCurve: context.fushiMotion.effectsDefault.curve,
        switchOutCurve: context.fushiMotion.effectsFast.curve,
        child: KeyedSubtree(
          key: ValueKey<String>(_bodyStateKey),
          child: _buildBody(theme),
        ),
      ),
    );
  }

  /// 正文状态键：加载 / 错误 / 数据之间切换时交叉淡入；换周 / 切「全部」时
  /// 也换键，让新一屏重播错峰进场。
  String get _bodyStateKey {
    if (_loading) return 'loading';
    if (_errorDetail != null) return 'error';
    return 'data-${_weekStart.millisecondsSinceEpoch}-$_showAll';
  }

  /// 周切换条：上一周 / 周区间 / 下一周 组成一枚按钮组（本周时区间块变成
  /// primaryContainer 胶囊），「显示本季全部」筛选 chip 放在行尾。窄屏时整行
  /// 可横向滚动，不挤压按钮。
  Widget _buildToolbar(ThemeData theme) {
    final DateTime weekEnd = DateTime(
      _weekStart.year,
      _weekStart.month,
      _weekStart.day + 6,
    );
    final bool glass = isGlassDesign(context);
    final bool thisWeek =
        daysBetweenLocalDates(_weekStart, localWeekStart(DateTime.now())) == 0;
    final bool tinted = thisWeek && !glass;
    final Color rangeForeground = tinted
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: <Widget>[
            FushiButtonGroup(
              spacing: 4,
              children: <Widget>[
                FushiIconButtonControl.filledTonal(
                  tooltip: t.download_airing_calendar_week_prev,
                  icon: const FushiIcon(FushiIcons.chevronLeft),
                  onPressed: _loading ? null : () => _shiftWeek(-7),
                ),
                AnimatedContainer(
                  duration: context.fushiMotion.spatialDefault.duration,
                  curve: context.fushiMotion.spatialDefault.curve,
                  height: 40,
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: glass
                        ? null
                        : tinted
                            ? theme.colorScheme.primaryContainer
                            : theme.colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(tinted ? 20 : 12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      FushiIcon(
                        FushiIcons.calendar,
                        size: 18,
                        color: rangeForeground,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${FushiTimeFormat.dayKey(_weekStart)} ~ '
                        '${FushiTimeFormat.dayKey(weekEnd)}',
                        style: context.fushiType.labelLargeEmphasized.tabular
                            .copyWith(color: rangeForeground),
                      ),
                    ],
                  ),
                ),
                FushiIconButtonControl.filledTonal(
                  tooltip: t.download_airing_calendar_week_next,
                  icon: const FushiIcon(FushiIcons.chevronRight),
                  onPressed: _loading ? null : () => _shiftWeek(7),
                ),
              ],
            ),
            const SizedBox(width: 12),
            FushiFilterChip(
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
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) {
      return _buildSkeleton();
    }
    final String? errorDetail = _errorDetail;
    if (errorDetail != null) {
      return _buildError(theme, errorDetail, _errorKind);
    }
    if (!_showAll &&
        _libraryAnilistIds.isEmpty &&
        _subscribedAnilistIds.isEmpty) {
      return _buildCenteredNote(
        theme,
        icon: FushiIcons.calendar,
        message: t.download_airing_calendar_empty_guidance,
      );
    }
    if (_episodes.isEmpty) {
      return _buildCenteredNote(
        theme,
        icon: FushiIcons.schedule,
        message: t.download_airing_calendar_week_empty,
      );
    }
    final List<List<AniListAiringEpisode>> buckets =
        groupEpisodesByLocalWeekday(
      episodes: _episodes,
      weekStartLocal: _weekStart,
    );
    return FushiEntranceScope(
      replayKey: _bodyStateKey,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool wide = constraints.maxWidth >= _wideLayoutMinWidth;
          return wide
              ? _buildWeekColumns(theme, buckets)
              : _buildDayList(theme, buckets);
        },
      ),
    );
  }

  /// 加载骨架：与按天分组列表同轮廓（日标题条 + 时刻 + 封面块 + 两条文字），
  /// 整组共享一道有界闪光。
  Widget _buildSkeleton() {
    Widget row() => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: <Widget>[
              const FushiSkeleton(width: 44, height: 20),
              const SizedBox(width: 16),
              const FushiSkeleton(width: 40, height: 60),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    FushiSkeleton.line(widthFactor: 0.8, height: 14),
                    const SizedBox(height: 8),
                    FushiSkeleton.line(widthFactor: 0.4),
                  ],
                ),
              ),
            ],
          ),
        );
    return FushiSkeletonShimmer(
      child: ListView(
        key: const ValueKey<String>('airing-calendar-skeleton'),
        primary: false,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 12),
        children: <Widget>[
          for (int day = 0; day < 2; day++) ...<Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              child: FushiSkeleton(
                height: 44,
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            FushiGroupedList(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: <Widget>[for (int i = 0; i < 3; i++) row()],
            ),
          ],
        ],
      ),
    );
  }

  /// 网络失败：如实展示错误详情 + 重试按钮（不吞、不静默降级）。
  Widget _buildError(ThemeData theme, String detail, AniListFailureKind? kind) {
    // 走共享 [FushiPlaceholderMessage]（M3E errorContainer 色块 / Apple
    // ContentUnavailableView）：接口提示 + 原始错误串作说明行。
    return FushiPlaceholderMessage(
      icon: FushiIcons.cloudOff,
      tone: FushiPlaceholderTone.error,
      message: t.download_airing_calendar_error,
      details: <String>[?anilistFailureNotice(kind), detail],
      detailMaxLines: 4,
      action: FushiFilledButton.tonalIcon(
        icon: const FushiIcon(FushiIcons.refresh),
        label: Text(t.anime_download_retry),
        onPressed: () => unawaited(_load(force: true)),
      ),
    );
  }

  Widget _buildCenteredNote(
    ThemeData theme, {
    required IconData icon,
    required String message,
  }) {
    // 空状态走共享 [FushiPlaceholderMessage]（M3E 色块图标 / Apple
    // ContentUnavailableView），不再手写图标 + 文字列。
    return FushiPlaceholderMessage(icon: icon, message: message);
  }

  /// 宽屏：周一到周日七列；列头是日标题色块（今天 = primaryContainer），
  /// 列内条目是分段卡片。
  Widget _buildWeekColumns(
    ThemeData theme,
    List<List<AniListAiringEpisode>> buckets,
  ) {
    int order = 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (int i = 0; i < 7; i++)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Column(
                  children: <Widget>[
                    _buildDayHeader(theme, i, count: buckets[i].length),
                    Expanded(
                      // 七列各自滚动，不接页面的 PrimaryScrollController
                      // （一个控制器挂七个视口会让手柄翻页兜底取不到唯一位置）。
                      child: ListView(
                        primary: false,
                        padding: EdgeInsets.only(
                          bottom: 12 + bottomSafeInsetOf(context),
                        ),
                        children: <Widget>[
                          for (int j = 0; j < buckets[i].length; j++)
                            FushiStaggeredEntrance(
                              index: order++,
                              child: _buildEpisodeTile(
                                theme,
                                buckets[i][j],
                                index: j,
                                count: buckets[i].length,
                                compact: true,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 窄屏：按天分组的时间轴列表（只列有条目的天）。
  Widget _buildDayList(
    ThemeData theme,
    List<List<AniListAiringEpisode>> buckets,
  ) {
    int order = 0;
    return ListView(
      padding: EdgeInsets.only(bottom: 12 + bottomSafeInsetOf(context)),
      children: <Widget>[
        for (int i = 0; i < 7; i++)
          if (buckets[i].isNotEmpty) ...<Widget>[
            FushiStaggeredEntrance(
              index: order++,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                child: _buildDayHeader(theme, i, count: buckets[i].length),
              ),
            ),
            for (int j = 0; j < buckets[i].length; j++)
              FushiStaggeredEntrance(
                index: order++,
                child: _buildEpisodeTile(
                  theme,
                  buckets[i][j],
                  index: j,
                  count: buckets[i].length,
                  compact: false,
                ),
              ),
          ],
      ],
    );
  }

  /// 日标题：星期 + 日期 + 条数。今天 = primaryContainer 饱和色块（M3E）/
  /// 强调色字（Apple），其余日子是中性色块。
  Widget _buildDayHeader(ThemeData theme, int weekdayIndex, {int count = 0}) {
    final DateTime day = DateTime(
      _weekStart.year,
      _weekStart.month,
      _weekStart.day + weekdayIndex,
    );
    final bool isToday = daysBetweenLocalDates(day, DateTime.now()) == 0;
    final String date = FushiTimeFormat.dayKey(day).substring(5);
    final bool glass = isGlassDesign(context);
    // 今天 = primary 色块；其余日子 = 中性 surfaceContainerHigh 块。墨水屏
    // （tone 色返回 null）与 Apple 不铺底，只给前景色。
    final FushiCardColors? tone = isToday
        ? fushiCardToneColors(context, FushiCardTone.primary)
        : null;
    final Color? background = glass
        ? null
        : tone?.container ??
            (isEinkTheme(context)
                ? null
                : theme.colorScheme.surfaceContainerHigh);
    final Color foreground = glass
        ? (isToday ? theme.colorScheme.primary : theme.colorScheme.onSurface)
        : tone?.onContainer ?? theme.colorScheme.onSurface;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(isToday ? 20 : 16),
      ),
      child: Row(
        children: <Widget>[
          Text(
            _weekdayName(day),
            style: context.fushiType.titleMediumEmphasized.copyWith(
              color: foreground,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              date,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.fushiType.bodyMedium.tabular.copyWith(
                color: foreground.withValues(alpha: 0.78),
              ),
            ),
          ),
          if (count > 0) _DayCountLabel(count: count, color: foreground),
        ],
      ),
    );
  }

  Widget _buildEpisodeTile(
    ThemeData theme,
    AniListAiringEpisode episode, {
    required int index,
    required int count,
    required bool compact,
  }) {
    final bool inLibrary = _libraryAnilistIds.contains(episode.mediaId);
    final bool subscribed = _subscribedAnilistIds.contains(episode.mediaId);
    final DateTime local = airingAtToLocal(episode.airingAtSeconds);
    final String episodeLabel =
        t.download_airing_calendar_episode_label(episode: episode.episode);
    final String time = FushiTimeFormat.hourMinute(local);
    final Widget badges = Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        Text(
          compact ? '$time $episodeLabel' : episodeLabel,
          style: context.fushiType.bodySmall.tabular.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (inLibrary)
          _buildBadge(
            theme,
            t.download_airing_calendar_in_library,
            FushiIcons.video,
            theme.colorScheme.primary,
          ),
        if (subscribed)
          _buildBadge(
            theme,
            t.download_airing_calendar_subscribed,
            FushiIcons.notifications,
            theme.colorScheme.tertiary,
          ),
      ],
    );
    return FushiGroupedListItem(
      key: ValueKey<String>(
        'airing-episode-${episode.mediaId}-${episode.episode}',
      ),
      index: index,
      count: count,
      margin: compact
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(horizontal: 12),
      // 每个条目都可点：进发现详情页拿 搜索资源/订阅/字幕/播放。
      onTap: () => unawaited(_openEpisode(episode)),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 10 : 12,
          vertical: compact ? 8 : 10,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // 窄屏时间轴：左侧放送时刻（等宽数字），上下条目一眼对齐。
            if (!compact) ...<Widget>[
              SizedBox(
                width: 52,
                child: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    time,
                    style: context.fushiType.titleMediumEmphasized.tabular
                        .copyWith(color: theme.colorScheme.primary),
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
            _buildCover(FushiDesignTokens.of(context), episode.media.coverUrl),
            SizedBox(width: compact ? 8 : 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  // 番名普遍很长，放宽到两行——单行省略在七列窄栏里只看得到开头。
                  Text(
                    episode.media.displayTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: compact
                        ? context.fushiType.labelLarge
                        : context.fushiType.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  badges,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 封面缩略图（2:3，与发现页卡片同一图源与占位形态）。
  Widget _buildCover(FushiDesignTokens tokens, String? coverUrl) {
    const double width = 40;
    const double height = 60;
    final String url = coverUrl?.trim() ?? '';
    // 底色走设计令牌，不直接读 colorScheme 的 surfaceContainer* —— 那是 MD3 守卫
    // 明令的「普通页面不得就地重开局部 MD3 决策」，发现页的封面占位就是这么写的。
    final Widget placeholder = ColoredBox(
      color: tokens.surfaces.group,
      child: const FushiIcon(FushiIcons.video, size: 20),
    );
    return ClipRRect(
      borderRadius: FushiM3eShape.smallRadius,
      child: SizedBox(
        width: width,
        height: height,
        // errorBuilder 必须给：PortraitCoverImage 在加载失败时返回
        // SizedBox.shrink()，不给就是封面 404 / 断网留一个 40×60 的空洞（上面那条
        // 占位分支只在 url 为空串时才走）。
        child: url.isEmpty
            ? placeholder
            : PortraitCoverImage(
                image: AppCachedHttpImage(url),
                errorBuilder: (_) => placeholder,
              ),
      ),
    );
  }

  /// 「已入库」「已订阅」小标签：走共享 [FushiTag]（不可交互小标签统一语言）。
  /// M3E = 中性 secondaryContainer 底 + 图标区分；Apple = 语义色胶囊。
  Widget _buildBadge(
    ThemeData theme,
    String label,
    IconData icon,
    Color dotColor,
  ) {
    return FushiTag(
      text: label,
      icon: icon,
      backgroundColor: isGlassDesign(context)
          ? dotColor
          : theme.colorScheme.secondaryContainer,
      foregroundColor: theme.colorScheme.onSecondaryContainer,
    );
  }
}

/// 日标题行尾的条数：小号等宽数字胶囊，跟随日标题前景色。
class _DayCountLabel extends StatelessWidget {
  const _DayCountLabel({required this.count, required this.color});

  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 24),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: const BorderRadius.all(Radius.circular(12)),
      ),
      child: Text(
        '$count',
        textAlign: TextAlign.center,
        style: context.fushiType.labelMediumEmphasized.tabular.copyWith(
          color: color,
        ),
      ),
    );
  }
}
