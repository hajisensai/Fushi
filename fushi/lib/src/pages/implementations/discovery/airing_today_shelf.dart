import 'dart:async';

import 'package:fushi/src/pages/implementations/discovery/discovery_logo.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_cover_block.dart';
import 'package:fushi/src/utils/components/fushi_cover_block_layout.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/video/airing_calendar_loader.dart';
import 'package:fushi/src/media/video/airing_discovery_mapping.dart';
import 'package:fushi/src/media/video/airing_week.dart';
import 'package:fushi/src/media/video/anilist_client.dart';
import 'package:fushi/src/pages/implementations/airing_calendar_page.dart';
import 'package:fushi/src/pages/implementations/discovery/discovery_layout.dart';
import 'package:fushi/src/pages/implementations/video_discovery_detail_page.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart'
    show HorizontalDragScrollable;
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_section_title.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi_engine/utils/misc/fushi_time_format.dart';
import 'package:fushi/src/pages/implementations/discovery/apple/apple_discovery_media.dart'
    show appleDiscoveryArtworkWidth;
import 'package:fushi/src/pages/implementations/discovery/apple/apple_discovery_shelf.dart'
    show AppleDiscoveryShelfHeader, AppleShelfHoverArrows;
import 'package:fushi/src/pages/implementations/discovery/apple/apple_discovery_widgets.dart'
    show appleDiscoveryPageInset;
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart'
    show appleColorsOf;
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show fushiAppleUsesMacMetrics;

/// 发现页「今日放送」小模块（2026-10-20，用户：「放送日历藏太深了可以作为一个
/// 小模块放在发现页里，然后可以点进去详情」）。
///
/// 标题行 /「查看全部」→ 完整放送日历页（[AiringCalendarPage]）；内容是**今天**
/// 播出的番剧横滑竖版小卡（封面 + 标题 + 时刻 · 第 N 集），点卡与日历页里点条目
/// 一致：合成 [VideoDiscoveryItem] 进发现详情页。数据走 [loader]（生产装配 =
/// `loadAiringCalendarWeek`，与日历页同一条取数路径与两层缓存），与日历页同为
/// 当季全量放送（日历页已去掉「显示本季全部」开关）。请求带 `day`：只拉今天的
/// 窗口，整周留给进日历页时按需拉。
class AiringTodayShelf extends StatefulWidget {
  const AiringTodayShelf({
    required this.loader,
    this.actions = const VideoDiscoveryActions(),
    super.key,
  });

  final AiringCalendarLoader loader;

  /// 发现详情页 / 完整日历页沿用的动作装配。
  final VideoDiscoveryActions actions;

  @override
  State<AiringTodayShelf> createState() => _AiringTodayShelfState();
}

enum _AiringTodayPhase { loading, error, empty, data }

class _AiringTodayShelfState extends State<AiringTodayShelf> {
  _AiringTodayPhase _phase = _AiringTodayPhase.loading;
  List<AniListAiringEpisode> _today = const <AniListAiringEpisode>[];

  /// 每次重载递增：晚到的旧结果不覆盖新一轮。
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final int generation = ++_generation;
    final DateTime now = DateTime.now();
    final DateTime weekStart = localWeekStart(now);
    if (_phase == _AiringTodayPhase.error) {
      setState(() => _phase = _AiringTodayPhase.loading);
    }
    try {
      final AiringCalendarSnapshot snapshot = await widget.loader(
        AiringCalendarRequest(
          weekStart: weekStart,
          // 只取今天：不被整周分页拉取挡住（整周缓存已在时照样直接截取）。
          day: now,
          isCancelled: () => !mounted,
        ),
      );
      if (!mounted || generation != _generation) return;
      final List<AniListAiringEpisode> today = snapshot.episodesOn(
        weekStart,
        now,
      );
      setState(() {
        _today = today;
        _phase = today.isEmpty
            ? _AiringTodayPhase.empty
            : _AiringTodayPhase.data;
      });
    } on Object {
      // 失败不吞：小模块里给一行错误 + 重试；完整错误详情在日历页里看。
      if (!mounted || generation != _generation) return;
      setState(() {
        _today = const <AniListAiringEpisode>[];
        _phase = _AiringTodayPhase.error;
      });
    }
  }

  /// 进完整放送日历（详情）；回来后重载（订阅 / 入库状态、缓存可能变了）。
  Future<void> _openCalendar() async {
    await Navigator.push<void>(
      context,
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => AiringCalendarPage(actions: widget.actions),
      ),
    );
    if (mounted) unawaited(_load());
  }

  /// 与日历页 `_openEpisode` 同一行为：合成发现条目进发现详情页。
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

  /// 块宽：与库页拼贴横滑条同一规则（桌面 300，窄窗约七成行宽）。
  double _itemWidth(double maxWidth) => isGlassDesign(context)
      // Apple：海报货架档（与 [DiscoveryShelf] 的 Apple 分支同宽）。
      ? appleDiscoveryArtworkWidth(context)
      : FushiCoverBlockStrip.rowTileWidth(maxWidth);

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final FushiMotionScheme motion = context.fushiMotion;
    // 库页材质（2026-10-25 定版）：放送卡与视频库同为光面海报。
    return ShelfCoverMaterialScope(
      material: ShelfCoverMaterial.glossyPoster,
      child: Column(
        key: const ValueKey<String>('video-discovery-airing-today'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _buildHeader(tokens),
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final double itemWidth = _itemWidth(constraints.maxWidth);
              return FushiAnimatedSize(
                duration: motion.spatialDefault.duration,
                curve: motion.spatialDefault.curve,
                alignment: AlignmentDirectional.topStart,
                child: AnimatedSwitcher(
                  duration: motion.effectsDefault.duration,
                  switchInCurve: motion.effectsDefault.curve,
                  switchOutCurve: motion.effectsFast.curve,
                  child: KeyedSubtree(
                    key: ValueKey<_AiringTodayPhase>(_phase),
                    child: _buildContent(tokens, itemWidth),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  /// 标题行：整行可点进日历（按压缩放），行尾「查看全部」是可聚焦的独立按钮
  /// （键盘 / 手柄从这里进）。
  Widget _buildHeader(FushiDesignTokens tokens) {
    return FushiPressScale(
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          key: const ValueKey<String>('video-discovery-airing-today-header'),
          behavior: HitTestBehavior.opaque,
          onTap: () => unawaited(_openCalendar()),
          child: Semantics(
            button: true,
            label: t.download_airing_calendar_title,
            child: isGlassDesign(context)
                ? Padding(
                    padding: EdgeInsets.fromLTRB(
                      appleDiscoveryPageInset(context),
                      24,
                      appleDiscoveryPageInset(context),
                      4,
                    ),
                    child: AppleDiscoveryShelfHeader(
                      title: t.download_airing_calendar_today_title,
                      trailing: DiscoveryViewAllButton(
                        key: const ValueKey<String>(
                          'video-discovery-airing-today-view-all',
                        ),
                        onPressed: () => unawaited(_openCalendar()),
                      ),
                    ),
                  )
                : FushiSectionTitle(
                    t.download_airing_calendar_today_title,
                    // 与 [DiscoveryShelf] 的行头同距（横滑件的悬停余量向外扩，不占行距）。
                    padding: EdgeInsets.fromLTRB(
                      tokens.spacing.page,
                      tokens.spacing.section,
                      tokens.spacing.page,
                      tokens.spacing.gap,
                    ),
                    trailing: DiscoveryViewAllButton(
                      key: const ValueKey<String>(
                        'video-discovery-airing-today-view-all',
                      ),
                      onPressed: () => unawaited(_openCalendar()),
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(FushiDesignTokens tokens, double itemWidth) {
    return switch (_phase) {
      _AiringTodayPhase.loading => _buildStrip(
        tokens,
        itemWidth,
        itemCount: 6,
        itemBuilder: (BuildContext context, int index) =>
            const DiscoverySkeletonCard(),
        scrollable: false,
      ),
      _AiringTodayPhase.error => _buildNote(
        tokens,
        icon: FushiIcons.cloudOff,
        message: t.download_airing_calendar_error,
        action: FushiTextButton(
          key: const ValueKey<String>('video-discovery-airing-today-retry'),
          onPressed: () => unawaited(_load()),
          child: Text(t.retry),
        ),
      ),
      _AiringTodayPhase.empty => _buildNote(
        tokens,
        icon: FushiIcons.schedule,
        message: t.download_airing_calendar_today_empty,
      ),
      _AiringTodayPhase.data => FushiEntranceScope(
        replayKey: _generation,
        child: _buildStrip(
          tokens,
          itemWidth,
          itemCount: _today.length,
          itemBuilder: (BuildContext context, int index) =>
              FushiStaggeredEntrance(
                index: index,
                child: _buildEpisodeCard(_today[index]),
              ),
          scrollable: true,
        ),
      ),
    };
  }

  /// 横滑卡片条（骨架与真卡同几何：数据到达时原地替换，不顶动下方内容）。
  /// 与 [DiscoveryShelf] 同一个横滑件 [FushiCoverBlockStrip]：视口向四周外扩出
  /// 色块悬停时封面转出 / 放大与投影的余量（自写的条按旧小卡算留白，换成色块后
  /// 悬停的封面被切掉一截，用户 2026-11-16「显示不全」）。
  Widget _buildStrip(
    FushiDesignTokens tokens,
    double itemWidth, {
    required int itemCount,
    required IndexedWidgetBuilder itemBuilder,
    required bool scrollable,
  }) {
    final double cardHeight = DiscoveryCoverCard.extentFor(
      context,
      width: itemWidth,
    );
    if (isGlassDesign(context)) {
      return _buildAppleStrip(
        itemWidth,
        cardHeight,
        itemCount: itemCount,
        itemBuilder: itemBuilder,
        scrollable: scrollable,
      );
    }
    final double spacing = tokens.spacing.card;
    final Widget strip = scrollable
        ? KeyedSubtree(
            key: const PageStorageKey<String>(
              'video-discovery-airing-today-strip',
            ),
            child: FushiCoverBlockStrip(
              leadingHero: false,
              rowSize: FushiCoverBlockSize.regular,
              spacing: spacing,
              tileWidth: itemWidth,
              tileHeight: cardHeight,
              itemCount: itemCount,
              itemBuilder:
                  (BuildContext context, int index, FushiCoverBlockSize _) =>
                      itemBuilder(context, index),
            ),
          )
        // 骨架不可滚、不可聚焦：只占形状。
        : SizedBox(
            height: cardHeight,
            child: ClipRect(
              child: OverflowBox(
                alignment: AlignmentDirectional.topStart,
                maxWidth: double.infinity,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    for (int i = 0; i < itemCount; i++) ...<Widget>[
                      if (i > 0) SizedBox(width: spacing),
                      SizedBox(
                        width: itemWidth,
                        child: itemBuilder(context, i),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
      child: strip,
    );
  }

  /// Apple：横滑海报条（桌面悬停两端出翻页箭头）；骨架不可滚、不可聚焦。
  Widget _buildAppleStrip(
    double itemWidth,
    double cardHeight, {
    required int itemCount,
    required IndexedWidgetBuilder itemBuilder,
    required bool scrollable,
  }) {
    final double page = appleDiscoveryPageInset(context);
    final double gap = fushiAppleUsesMacMetrics(context) ? 16 : 12;
    final Widget strip = SizedBox(
      height: cardHeight + 16,
      child: HorizontalDragScrollable(
        child: ListView.separated(
          key: scrollable
              ? const PageStorageKey<String>(
                  'video-discovery-airing-today-strip',
                )
              : null,
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          physics: scrollable ? null : const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.symmetric(horizontal: page, vertical: 8),
          itemCount: itemCount,
          separatorBuilder: (BuildContext context, int index) =>
              SizedBox(width: gap),
          itemBuilder: (BuildContext context, int index) =>
              SizedBox(width: itemWidth, child: itemBuilder(context, index)),
        ),
      ),
    );
    return scrollable
        ? AppleShelfHoverArrows(child: strip)
        : ExcludeFocus(child: strip);
  }

  Widget _buildEpisodeCard(AniListAiringEpisode episode) {
    final String time = FushiTimeFormat.hourMinute(
      airingAtToLocal(episode.airingAtSeconds),
    );
    final String episodeLabel = t.download_airing_calendar_episode_label(
      episode: episode.episode,
    );
    final String url = episode.media.coverUrl?.trim() ?? '';
    final String banner = episode.media.bannerUrl?.trim() ?? '';
    final String stableId = '${episode.mediaId}-${episode.episode}';
    return DiscoveryCoverCard(
      key: ValueKey<String>('video-discovery-airing-today-$stableId'),
      focusId: FushiFocusId('video-discovery-airing-today-$stableId'),
      title: episode.media.displayTitle,
      subtitle: '$time · $episodeLabel',
      onTap: () => unawaited(_openEpisode(episode)),
      // AniList 横幅当剧照：与视频库系列块同摆法（剧照铺尾侧、海报斜放起始侧）。
      // 艺术字：AniList 不带 logo，按需经详情端口取 TMDB 的（与视频库系列块
      // 一样都有艺术字；取不到回落标题文字）。
      logoFuture: discoveryLogoFor(
        discoveryItemFromAiringEpisode(episode),
        widget.actions.loadDetails,
      ),
      backdrop: banner.isEmpty ? null : AppCachedHttpImage(banner),
      cover: DiscoveryImageCover(
        image: url.isEmpty ? null : AppCachedHttpImage(url),
        placeholderIcon: FushiIcons.video,
      ),
    );
  }

  /// 空态 / 错误：一行紧凑说明（图标 + 文案 + 可选动作），不占整条卡片高度。
  Widget _buildNote(
    FushiDesignTokens tokens, {
    required IconData icon,
    required String message,
    Widget? action,
  }) {
    final ThemeData theme = Theme.of(context);
    final Color foreground = isGlassDesign(context)
        ? appleColorsOf(context).secondaryLabel
        : theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: isGlassDesign(context) ? null : tokens.surfaces.group,
          borderRadius: BorderRadius.circular(FushiM3eShape.listActive),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: tokens.spacing.card,
            vertical: tokens.spacing.gap,
          ),
          child: Row(
            children: <Widget>[
              FushiIcon(icon, size: 20, color: foreground),
              SizedBox(width: tokens.spacing.gap),
              Expanded(
                child: Text(
                  message,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: foreground,
                  ),
                ),
              ),
              ?action,
            ],
          ),
        ),
      ),
    );
  }
}
