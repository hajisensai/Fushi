import 'dart:async';

import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:fushi/src/pages/implementations/discovery/discovery_logo.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import 'package:fushi/src/media/video/airing_calendar_loader.dart';
import 'package:fushi/src/media/video/airing_discovery_mapping.dart';
import 'package:fushi/src/media/video/airing_week.dart';
import 'package:fushi/src/media/video/anilist_client.dart';
import 'package:fushi/src/media/video/anilist_failure_notice.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/pages/implementations/discovery/discovery_layout.dart';
import 'package:fushi/src/utils/components/fushi_cover_block.dart';
import 'package:fushi/src/pages/implementations/video_discovery_detail_page.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:fushi_engine/utils/misc/fushi_time_format.dart';

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
/// 两层（airing_calendar_cache.dart），**无 Drift schema 改动**。取数实现在
/// `airing_calendar_loader.dart`，发现页「今日放送」小模块共用同一份。
///
/// 入口（2026-10-20 起）：视频发现页的「今日放送」小模块标题行 /「查看全部」；
/// 发现页页头 / 搜索行原有的日历图标按钮已删除。
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
  /// 七列布局里单列至少要有的宽度：放得下一块竖海报 + 尾侧剧照的系列色块
  /// （与视频库「系列」块同一组件）。整页凑不出七列这么宽时切按天分组的
  /// 色块网格。
  static const double _weekColumnMinWidth = 260;

  /// 七列布局整体的左右外边距。
  static const double _weekColumnsOuterPadding = 8;

  /// 给定正文宽度能否排七列（每列扣掉两侧悬停余量后仍 ≥ [_weekColumnMinWidth]）。
  static bool _fitsWeekColumns(double width, double headroom) =>
      (width - _weekColumnsOuterPadding * 2) / 7 - headroom * 2 >=
      _weekColumnMinWidth;

  late DateTime _weekStart = localWeekStart(DateTime.now());
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
    unawaited(
      initializeDateFormatting().then((_) {
        if (mounted) setState(() => _dateSymbolsReady = true);
      }),
    );
    unawaited(_load());
  }

  /// 重载整页：取数走共享的 [loadAiringCalendarWeek]（发现页「今日放送」
  /// 小模块同一条路径）。[force] = 用户点刷新，绕过两层缓存。
  Future<void> _load({bool force = false}) async {
    setState(() {
      _loading = true;
      _errorDetail = null;
      _errorKind = null;
    });
    try {
      final AiringCalendarSnapshot snapshot = await loadAiringCalendarWeek(
        _appModel,
        AiringCalendarRequest(
          weekStart: _weekStart,
          force: force,
          isCancelled: () => !mounted,
        ),
      );
      if (!mounted) return;
      setState(() {
        _libraryAnilistIds = snapshot.libraryAnilistIds;
        _subscribedAnilistIds = snapshot.subscribedAnilistIds;
        _episodes = snapshot.episodes;
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
      masthead: true,
      title: t.download_airing_calendar_title,
      actions: <Widget>[
        FushiIconButton(
          tooltip: t.refresh,
          icon: FushiIcons.refresh,
          enabled: !_loading,
          onTap: _loading ? null : () => unawaited(_load(force: true)),
        ),
      ],
      headerBottom: _buildToolbar(theme),
      body: AnimatedSwitcher(
        duration: context.fushiMotion.effectsDefault.duration,
        switchInCurve: context.fushiMotion.effectsDefault.curve,
        switchOutCurve: context.fushiMotion.effectsFast.curve,
        child: KeyedSubtree(
          key: ValueKey<String>(_bodyStateKey),
          // 页头浮在正文上（脚手架默认 extendBodyBehindHeader）：顶部让位要从
          // body 子树里的 context 读（State 的 context 在脚手架之上）。
          child: Builder(
            builder: (BuildContext context) =>
                _buildBody(theme, MediaQuery.paddingOf(context).top),
          ),
        ),
      ),
    );
  }

  /// 正文状态键：加载 / 错误 / 数据之间切换时交叉淡入；换周时也换键，让新
  /// 一屏重播错峰进场。
  String get _bodyStateKey {
    if (_loading) return 'loading';
    if (_errorDetail != null) return 'error';
    return 'data-${_weekStart.millisecondsSinceEpoch}';
  }

  /// 周切换条：上一周 / 周区间 / 下一周 组成一枚按钮组（本周时区间块变成
  /// primaryContainer 胶囊）。放送表恒显示当季全部，不再有筛选 chip。窄屏时
  /// 整行可横向滚动，不挤压按钮。
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
      child: HorizontalDragScrollable(
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
                      borderRadius: tinted
                          ? FushiM3eShape.cardRadius
                          : FushiM3eShape.smallRadius,
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
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme, double topInset) {
    if (_loading) {
      return _buildSkeleton(topInset);
    }
    final String? errorDetail = _errorDetail;
    if (errorDetail != null) {
      return _buildError(theme, errorDetail, _errorKind);
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
      // 条目是发现页 / 视频库同款光面海报色块：材质与「今日放送」同档。
      child: ShelfCoverMaterialScope(
        material: ShelfCoverMaterial.glossyPoster,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final double tileHeight = discoveryTileHeight(context);
            final bool wide = _fitsWeekColumns(
              constraints.maxWidth,
              discoveryShelfLiftHeadroom(tileHeight),
            );
            return wide
                ? _buildWeekColumns(theme, buckets, topInset, tileHeight)
                : _buildDayList(theme, buckets, topInset);
          },
        ),
      ),
    );
  }

  /// 加载骨架：与正文同一套版式判据——宽屏七列（日标题条 + 两块色块轮廓），
  /// 窄屏按天分组的色块网格。整组共享一道有界闪光，数据到达时版面不跳。
  Widget _buildSkeleton(double topInset) {
    return FushiSkeletonShimmer(
      child: LayoutBuilder(
        key: const ValueKey<String>('airing-calendar-skeleton'),
        builder: (BuildContext context, BoxConstraints constraints) {
          final double tileHeight = discoveryTileHeight(context);
          final double headroom = discoveryShelfLiftHeadroom(tileHeight);
          final double gap = FushiDesignTokens.of(context).spacing.card;
          final Widget block = FushiSkeleton(
            height: tileHeight,
            borderRadius: BorderRadius.circular(
              fushiCoverBlockRadius(FushiCoverBlockSize.regular, tileHeight),
            ),
          );
          final Widget header = FushiSkeleton(
            height: 44,
            borderRadius: BorderRadius.circular(FushiM3eShape.listActive),
          );
          if (_fitsWeekColumns(constraints.maxWidth, headroom)) {
            return Padding(
              padding: EdgeInsets.fromLTRB(
                _weekColumnsOuterPadding + headroom,
                4 + topInset,
                _weekColumnsOuterPadding + headroom,
                0,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  for (int i = 0; i < 7; i++) ...<Widget>[
                    if (i > 0) SizedBox(width: headroom * 2),
                    Expanded(
                      child: Column(
                        children: <Widget>[
                          header,
                          SizedBox(height: 8 + headroom),
                          block,
                          SizedBox(height: gap),
                          block,
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            );
          }
          return CustomScrollView(
            primary: false,
            physics: const NeverScrollableScrollPhysics(),
            slivers: <Widget>[
              SliverPadding(padding: EdgeInsets.only(top: topInset)),
              for (int day = 0; day < 2; day++) ...<Widget>[
                SliverPadding(
                  padding: _dayHeaderPadding,
                  sliver: SliverToBoxAdapter(child: header),
                ),
                DiscoveryCoverGrid(
                  itemCount: 2,
                  itemBuilder: (BuildContext _, int _) => block,
                  padding: _dayGridPadding(context),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  /// 窄屏日标题的外边距（与下方色块网格同一左右页边）。
  static const EdgeInsets _dayHeaderPadding = EdgeInsets.fromLTRB(
    12,
    12,
    12,
    0,
  );

  /// 窄屏每天一组色块网格的内边距：与日标题同一左右页边。
  EdgeInsets _dayGridPadding(BuildContext context) {
    final double gap = FushiDesignTokens.of(context).spacing.gap;
    return EdgeInsets.fromLTRB(12, gap, 12, gap);
  }

  /// 网络失败：如实展示错误详情 + 重试按钮（不吞、不静默降级）。
  Widget _buildError(ThemeData theme, String detail, AniListFailureKind? kind) {
    // 走共享 [FushiPlaceholderMessage]（M3E errorContainer 色块 / Apple
    // ContentUnavailableView）：接口提示 + 原始错误串作说明行。
    // SafeArea：页头浮在正文上，不滚动的占位整体让开页头。
    return SafeArea(
      bottom: false,
      child: FushiPlaceholderMessage(
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
    return SafeArea(
      bottom: false,
      child: FushiPlaceholderMessage(icon: icon, message: message),
    );
  }

  /// 宽屏：周一到周日七列；列头是日标题色块（今天 = primaryContainer），
  /// 列内条目是视频库「系列」同款色块（规整块高 [discoveryTileHeight]）。
  /// 列表视口四周留出悬停余量（[discoveryShelfLiftHeadroom]），悬停放大的
  /// 色块不被列的裁切边吃掉。
  Widget _buildWeekColumns(
    ThemeData theme,
    List<List<AniListAiringEpisode>> buckets,
    double topInset,
    double tileHeight,
  ) {
    final double headroom = discoveryShelfLiftHeadroom(tileHeight);
    final double gap = FushiDesignTokens.of(context).spacing.card;
    int order = 0;
    // 七列各自滚动、列头固定：整块让开浮动页头（列内容滚到列头下，不进页头底下）。
    return Padding(
      padding: EdgeInsets.fromLTRB(
        _weekColumnsOuterPadding,
        4 + topInset,
        _weekColumnsOuterPadding,
        0,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (int i = 0; i < 7; i++)
            Expanded(
              child: Column(
                children: <Widget>[
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: headroom),
                    child: _buildDayHeader(theme, i, count: buckets[i].length),
                  ),
                  Expanded(
                    // 七列各自滚动，不接页面的 PrimaryScrollController
                    // （一个控制器挂七个视口会让手柄翻页兜底取不到唯一位置）。
                    child: ListView(
                      primary: false,
                      padding: EdgeInsets.fromLTRB(
                        headroom,
                        headroom,
                        headroom,
                        12 + bottomSafeInsetOf(context),
                      ),
                      children: <Widget>[
                        for (int j = 0; j < buckets[i].length; j++)
                          Padding(
                            padding: EdgeInsets.only(top: j == 0 ? 0 : gap),
                            child: FushiStaggeredEntrance(
                              index: order++,
                              child: SizedBox(
                                height: tileHeight,
                                child: _buildEpisodeTile(buckets[i][j]),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 窄屏：按天分组（只列有条目的天），每天一个日标题 + 一组色块网格
  /// （[DiscoveryCoverGrid]，与发现页「查看全部」同一套列数 / 块高）。
  Widget _buildDayList(
    ThemeData theme,
    List<List<AniListAiringEpisode>> buckets,
    double topInset,
  ) {
    final List<Widget> slivers = <Widget>[
      SliverPadding(padding: EdgeInsets.only(top: topInset)),
    ];
    int order = 0;
    for (int i = 0; i < 7; i++) {
      final List<AniListAiringEpisode> day = buckets[i];
      if (day.isEmpty) continue;
      slivers.add(
        SliverPadding(
          padding: _dayHeaderPadding,
          sliver: SliverToBoxAdapter(
            child: FushiStaggeredEntrance(
              index: order++,
              child: _buildDayHeader(theme, i, count: day.length),
            ),
          ),
        ),
      );
      // 整页一条错峰序列：网格里的块接着日标题往下数。
      final int firstOrder = order;
      order += day.length;
      slivers.add(
        DiscoveryCoverGrid(
          itemCount: day.length,
          padding: _dayGridPadding(context),
          itemBuilder: (BuildContext _, int j) => FushiStaggeredEntrance(
            index: firstOrder + j,
            child: _buildEpisodeTile(day[j]),
          ),
        ),
      );
    }
    slivers.add(
      SliverPadding(
        padding: EdgeInsets.only(bottom: 12 + bottomSafeInsetOf(context)),
      ),
    );
    return CustomScrollView(slivers: slivers);
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
        borderRadius: BorderRadius.circular(
          isToday ? FushiM3eShape.card : FushiM3eShape.listActive,
        ),
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

  /// 一集放送 = 一块视频库「系列」同款色块（[DiscoveryCoverCard] 包
  /// [FushiCoverBlock]）：AniList 封面当竖海报斜放在起始侧，有横幅
  /// （`bannerImage`）时按原比例铺在尾侧当剧照；副行「时间 · 第 N 集」。
  /// 「已入库 / 已订阅」收成副行前导图标（入库优先），文字进 Semantics。
  /// 每个条目都可点：进发现详情页拿 搜索资源/订阅/字幕/播放。
  Widget _buildEpisodeTile(AniListAiringEpisode episode) {
    final bool inLibrary = _libraryAnilistIds.contains(episode.mediaId);
    final bool subscribed = _subscribedAnilistIds.contains(episode.mediaId);
    final String time = FushiTimeFormat.hourMinute(
      airingAtToLocal(episode.airingAtSeconds),
    );
    final String episodeLabel = t.download_airing_calendar_episode_label(
      episode: episode.episode,
    );
    final String cover = episode.media.coverUrl?.trim() ?? '';
    final String banner = episode.media.bannerUrl?.trim() ?? '';
    final String stableId = '${episode.mediaId}-${episode.episode}';
    final List<String> status = <String>[
      if (inLibrary) t.download_airing_calendar_in_library,
      if (subscribed) t.download_airing_calendar_subscribed,
    ];
    final Widget card = DiscoveryCoverCard(
      key: ValueKey<String>('airing-episode-$stableId'),
      focusId: FushiFocusId('airing-calendar-episode-$stableId'),
      title: episode.media.nativeFirstTitle,
      subtitle: '$time · $episodeLabel',
      leadingIcon: inLibrary
          ? FushiIcons.video
          : subscribed
          ? FushiIcons.notifications
          : null,
      onTap: () => unawaited(_openEpisode(episode)),
      // 艺术字：AniList 不带 logo，按需经详情端口取 TMDB 的（与视频库系列块
      // 一样都有艺术字；取不到回落标题文字）。
      logoFuture: discoveryLogoFor(
        discoveryItemFromAiringEpisode(episode),
        widget.actions.loadDetails,
      ),
      backdrop: banner.isEmpty ? null : AppCachedHttpImage(banner),
      cover: DiscoveryImageCover(
        image: cover.isEmpty ? null : AppCachedHttpImage(cover),
        placeholderIcon: FushiIcons.video,
      ),
    );
    if (status.isEmpty) return card;
    return Semantics(value: status.join(', '), child: card);
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
