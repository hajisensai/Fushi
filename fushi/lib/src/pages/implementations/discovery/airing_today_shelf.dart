import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/video/airing_calendar_loader.dart';
import 'package:fushi/src/media/video/airing_discovery_mapping.dart';
import 'package:fushi/src/media/video/airing_week.dart';
import 'package:fushi/src/media/video/anilist_client.dart';
import 'package:fushi/src/pages/implementations/airing_calendar_page.dart';
import 'package:fushi/src/pages/implementations/discovery/discovery_layout.dart';
import 'package:fushi/src/pages/implementations/video_discovery_detail_page.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_horizontal_edge_fade.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:fushi/utils.dart';

/// 发现页「今日放送」小模块（2026-10-20，用户：「放送日历藏太深了可以作为一个
/// 小模块放在发现页里，然后可以点进去详情」）。
///
/// 标题行 /「查看全部」→ 完整放送日历页（[AiringCalendarPage]）；内容是**今天**
/// 播出的番剧横滑竖版小卡（封面 + 标题 + 时刻 · 第 N 集），点卡与日历页里点条目
/// 一致：合成 [VideoDiscoveryItem] 进发现详情页。数据走 [loader]（生产装配 =
/// `loadAiringCalendarWeek`，与日历页同一条取数路径与两层缓存），与日历页同为
/// 当季全量放送（日历页已去掉「显示本季全部」开关）。
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

  /// 小卡宽度：手机 112、平板 / 桌面 128（竖版 2:3）。
  double _itemWidth(double maxWidth) => maxWidth < 600 ? 112 : 128;

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
            child: FushiSectionTitle(
              t.download_airing_calendar_today_title,
              // 底部不再留 gap：卡片条顶上的悬停留白（[discoveryShelfLiftHeadroom]）
              // 就是行头与卡片之间的距离。
              padding: EdgeInsets.fromLTRB(
                tokens.spacing.page,
                tokens.spacing.section,
                tokens.spacing.page,
                0,
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
    // 悬停抬升放大的卡与加深的投影要有地方画：视口上下各留一份留白。
    final double headroom = discoveryShelfLiftHeadroom(cardHeight);
    final double height = cardHeight + headroom * 2;
    final EdgeInsets padding = EdgeInsets.symmetric(
      horizontal: tokens.spacing.page,
      vertical: headroom,
    );
    Widget separator(BuildContext context, int index) =>
        SizedBox(width: tokens.spacing.card);
    Widget sized(BuildContext context, int index) =>
        SizedBox(width: itemWidth, child: itemBuilder(context, index));
    if (!scrollable) {
      // 骨架不可滚、不可聚焦：只占形状。
      return SizedBox(
        height: height,
        child: ListView.separated(
          primary: false,
          physics: const NeverScrollableScrollPhysics(),
          padding: padding,
          scrollDirection: Axis.horizontal,
          itemCount: itemCount,
          separatorBuilder: separator,
          itemBuilder: sized,
        ),
      );
    }
    return SizedBox(
      height: height,
      child: FushiHorizontalEdgeFade(
        child: HorizontalDragScrollable(
          child: ListView.separated(
            key: const PageStorageKey<String>(
              'video-discovery-airing-today-strip',
            ),
            primary: false,
            padding: padding,
            scrollDirection: Axis.horizontal,
            itemCount: itemCount,
            separatorBuilder: separator,
            itemBuilder: sized,
          ),
        ),
      ),
    );
  }

  Widget _buildEpisodeCard(AniListAiringEpisode episode) {
    final String time = FushiTimeFormat.hourMinute(
      airingAtToLocal(episode.airingAtSeconds),
    );
    final String episodeLabel = t.download_airing_calendar_episode_label(
      episode: episode.episode,
    );
    final String url = episode.media.coverUrl?.trim() ?? '';
    final String stableId = '${episode.mediaId}-${episode.episode}';
    return DiscoveryCoverCard(
      key: ValueKey<String>('video-discovery-airing-today-$stableId'),
      focusId: FushiFocusId('video-discovery-airing-today-$stableId'),
      title: episode.media.displayTitle,
      subtitle: '$time · $episodeLabel',
      onTap: () => unawaited(_openEpisode(episode)),
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
    final Color foreground = theme.colorScheme.onSurfaceVariant;
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
