import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/media/video/video_episode_rail.dart';
import 'package:fushi/src/media/video/video_side_panel.dart';
import 'package:fushi/src/utils/components/fushi_horizontal_edge_fade.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:fushi_engine/media/collections/collection_season_groups.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';

export 'package:fushi/src/media/video/video_episode_rail.dart'
    show VideoEpisodeEntry, VideoEpisodeRail;

/// 视频播放列表的底部选集面板。
///
/// 不使用 modal sheet，也不再把画面挤成窄栏；面板浮在视频底部，与播放器其它
/// 浮层同一套表面（[VideoFloatingPanelSurface]：M3E 中性深色、圆角 28；Apple
/// 液态玻璃；墨水屏实色描边）。字幕跳转列表仍保持 push-aside，二者由页面层互斥。
///
/// 卡片尺寸按面板宽度自适应（窄屏 / 竖屏约 1.6 张、宽屏 4~5 张一屏），桌面在
/// 标题行给左右翻页按钮。横向卡片的封面、缺图、选中态由共享 [VideoEpisodeRail]
/// 渲染。
class VideoEpisodePanel extends StatefulWidget {
  const VideoEpisodePanel({
    super.key,
    required this.episodes,
    required this.currentIndex,
    required this.onTapEpisode,
    required this.onClose,
    required this.colorScheme,
    required this.title,
    required this.emptyHint,
    this.seasonLabelOf,
    this.fontSize = 14,
    this.width = double.infinity,
    this.visible = true,
  });

  /// 播放列表各集（有序，标题 + 可选封面）。空列表（单视频）时显示 [emptyHint]
  /// （剧集入口仅在播放列表出现，故正常不会空；空态作防御兜底）。与内部集表示解耦：
  /// 页面层把本地行 / 互联远端行都解析成 [VideoEpisodeEntry] 再传进来。
  final List<VideoEpisodeEntry> episodes;

  /// 当前播放集下标（[episodes] 内）；负 / 越界视为「无当前集」。
  final int currentIndex;

  /// 点某集 → 切到该集（页面层 `_switchEpisode(index, ...)`）。回调入参为集下标。
  final void Function(int index) onTapEpisode;

  /// 头部 × 关闭按钮（页面层 `_closeEpisodeList`，与 Esc / 控制条剧集按钮三路等价）。
  final VoidCallback onClose;

  final ColorScheme colorScheme;
  final String title;

  /// 列表为空时的占位提示。
  final String emptyHint;

  /// 季 chip 文案（组键 → 「第 N 季」/「PV·特典」，页面层接 i18n）。null 时
  /// 直接显示组键（仅测试/兜底）。多季判据看 [VideoEpisodeEntry.groupKey]：
  /// 派生组数 ≥ 2 才出 chip 行，单季合集整个头部与从前一样。
  final String Function(String groupKey)? seasonLabelOf;
  final double fontSize;
  final double width;

  /// 面板当前是否显示（常驻挂载的播放器面板传真实显隐）。由隐到显时轨道把
  /// 当前集滚到正中并让当前集卡领焦点。
  final bool visible;

  @override
  State<VideoEpisodePanel> createState() => _VideoEpisodePanelState();
}

class _VideoEpisodePanelState extends State<VideoEpisodePanel> {
  /// 按季切成的分节（元素是**全局下标**；季升序、PV/特典殿后，与合集详情页
  /// 季 tab 同序）。单季 → 1 节，不出 chip。
  List<CollectionSeasonSection<int>> _sections =
      const <CollectionSeasonSection<int>>[];
  int _selectedSection = 0;

  /// 每节一条轨道（换季 = 换一条新轨道，滚动位置互不串）；翻页按钮经它调轨道。
  final Map<int, GlobalKey<VideoEpisodeRailState>> _railKeys =
      <int, GlobalKey<VideoEpisodeRailState>>{};
  bool _canPageBack = false;
  bool _canPageForward = false;

  /// 重新打开后本帧新建的轨道要自己认领当前集焦点（HBK-AUDIT-025）：重开会把
  /// 季切回当前集所在季，那条轨道是新挂载的，接不到 active 的显隐边沿。帧末清掉，
  /// 之后用户点季 chip 换出的轨道不抢焦点。
  bool _claimFocusOnMount = false;

  @override
  void initState() {
    super.initState();
    _rebuildSections(followCurrent: true);
  }

  @override
  void didUpdateWidget(covariant VideoEpisodePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换集（含跨季自动连播 / 上下集）→ chip 跟到当前集所在季；列表整体换掉也
    // 重算。用户手动切到别的季浏览、当前集没变时不打扰。重新打开面板时也回到
    // 当前集所在季（上次可能停在别的季浏览）。
    final bool episodesChanged = !identical(
      oldWidget.episodes,
      widget.episodes,
    );
    final bool currentChanged = oldWidget.currentIndex != widget.currentIndex;
    final bool reopened = widget.visible && !oldWidget.visible;
    if (episodesChanged || currentChanged || reopened) {
      _rebuildSections(followCurrent: true);
    }
    if (reopened) {
      _claimFocusOnMount = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _claimFocusOnMount = false;
      });
    }
  }

  void _rebuildSections({required bool followCurrent}) {
    final List<int> all = List<int>.generate(
      widget.episodes.length,
      (int i) => i,
    );
    _sections = sortCollectionSeasonSections<int>(
      buildCollectionSeasonSections<int>(
        members: all,
        keyOf: (int i) => widget.episodes[i].groupKey,
      ),
    );
    if (followCurrent) {
      final int owner = _sections.indexWhere(
        (CollectionSeasonSection<int> s) =>
            s.items.contains(widget.currentIndex),
      );
      if (owner >= 0) _selectedSection = owner;
    }
    if (_sections.isEmpty) {
      _selectedSection = 0;
    } else {
      _selectedSection = _selectedSection.clamp(0, _sections.length - 1);
    }
  }

  bool get _hasSeasonChips => _sections.length >= 2;

  /// 当前 chip 下可见的全局下标；无 chip = 全表。
  List<int>? get _visibleIndices =>
      _hasSeasonChips ? _sections[_selectedSection].items : null;

  String _labelOf(String groupKey) =>
      widget.seasonLabelOf?.call(groupKey) ?? groupKey;

  GlobalKey<VideoEpisodeRailState> get _railKey => _railKeys.putIfAbsent(
    _selectedSection,
    () => GlobalKey<VideoEpisodeRailState>(
      debugLabel: 'video-episode-rail-$_selectedSection',
    ),
  );

  /// 轨道滚动 / 尺寸变化 → 刷新翻页按钮可用态（通知可能在布局阶段发出，帧末再改）。
  bool _onRailMetrics(ScrollMetrics metrics, int depth) {
    if (depth != 0 || metrics.axis != Axis.horizontal) return false;
    final bool back = metrics.extentBefore > 0.5;
    final bool forward = metrics.extentAfter > 0.5;
    if (back != _canPageBack || forward != _canPageForward) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (back == _canPageBack && forward == _canPageForward) return;
        setState(() {
          _canPageBack = back;
          _canPageForward = forward;
        });
      });
    }
    return false;
  }

  /// 卡片宽：按面板内宽决定一屏几张（窄屏 / 竖屏约 1.6 张，平板 2.6，桌面
  /// 3.6~4.6），再按字号定下限（大字号下集号 + 两行标题要放得下）。
  ///
  /// 系统文字缩放（[textScale]，如 200%）同样计入下限：卡面是 16:9，字变大而卡
  /// 不变高时「正在播放」胶囊与两行标题挤不下（HBK-AUDIT-024）。下限封顶在一屏
  /// 内宽的 92%，再宽就只剩一张卡。
  double _cardWidthFor(double innerWidth, double textScale) {
    final double perView = innerWidth < 480
        ? 1.6
        : innerWidth < 760
        ? 2.6
        : innerWidth < 1100
        ? 3.6
        : 4.6;
    final double fontScale = (widget.fontSize / 14).clamp(0.9, 1.6);
    final double typeScale = fontScale * textScale.clamp(1.0, 3.0);
    final double screenCap = innerWidth * 0.92;
    final double minWidth = (150 * typeScale).clamp(
      140.0,
      screenCap < 140 ? 140.0 : screenCap,
    );
    final double fitted = innerWidth / perView - 12;
    final double maxWidth = minWidth > 300 ? minWidth : 300.0;
    return fitted.clamp(minWidth, maxWidth);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double available = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final bool compact = available < 600;
        final double margin = compact ? 8 : 16;
        final double surfaceWidth = (available - margin * 2).clamp(0.0, 1440.0);
        final double cardWidth = _cardWidthFor(
          surfaceWidth - 40,
          MediaQuery.textScalerOf(context).scale(widget.fontSize) /
              widget.fontSize,
        );
        return Material(
          type: MaterialType.transparency,
          child: SizedBox(
            width: widget.width,
            child: Padding(
              padding: EdgeInsets.fromLTRB(margin, 0, margin, margin),
              child: Align(
                alignment: Alignment.bottomCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1440),
                  child: VideoFloatingPanelSurface(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        _buildHeader(context, compact),
                        if (_hasSeasonChips) _buildSeasonChips(),
                        if (widget.episodes.isEmpty)
                          _buildEmpty()
                        else
                          _buildRail(cardWidth),
                        const SizedBox(height: 10),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context, bool compact) {
    final ColorScheme cs = widget.colorScheme;
    final FushiTypography type = context.fushiType;
    final double fs = widget.fontSize;
    final bool hasCurrent =
        widget.currentIndex >= 0 &&
        widget.currentIndex < widget.episodes.length;
    final bool showPager =
        isDesktopPlatform && !compact && widget.episodes.isNotEmpty;
    final Widget titleRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Flexible(
          child: Text(
            widget.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: type.titleMediumEmphasized.copyWith(
              color: cs.onSurface,
              fontSize: fs + 3,
            ),
          ),
        ),
        if (widget.episodes.isNotEmpty) ...<Widget>[
          SizedBox(width: fs * 0.6),
          Container(
            key: const ValueKey<String>('video-episode-count-badge'),
            padding: EdgeInsets.symmetric(
              horizontal: fs * 0.55,
              vertical: fs * 0.12,
            ),
            decoration: ShapeDecoration(
              color: cs.secondaryContainer,
              shape: const StadiumBorder(),
            ),
            child: Text(
              '${widget.episodes.length}',
              maxLines: 1,
              softWrap: false,
              style: type.labelLargeEmphasized.tabular.copyWith(
                color: cs.onSecondaryContainer,
                fontSize: fs - 1,
              ),
            ),
          ),
        ],
      ],
    );
    final Widget? currentName = hasCurrent
        ? Text(
            widget.episodes[widget.currentIndex].title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: type.bodyMedium.copyWith(
              color: cs.onSurfaceVariant,
              fontSize: fs - 1,
            ),
          )
        : null;
    return Padding(
      padding: const EdgeInsetsDirectional.only(
        start: 20,
        end: 10,
        top: 12,
        bottom: 4,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            // 窄屏：标题 + 徽标一行、当前集名换到下一行；宽屏三者同一行。
            child: compact
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      titleRow,
                      if (currentName != null) currentName,
                    ],
                  )
                : Row(
                    children: <Widget>[
                      titleRow,
                      if (currentName != null) ...<Widget>[
                        SizedBox(width: fs),
                        Expanded(child: currentName),
                      ],
                    ],
                  ),
          ),
          if (showPager) ...<Widget>[
            FushiIconButtonControl(
              key: const ValueKey<String>('video-episode-page-back'),
              tooltip: MaterialLocalizations.of(context).previousPageTooltip,
              icon: FushiIcon(FushiIcons.chevronLeft, size: fs + 6),
              color: cs.onSurface,
              onPressed: _canPageBack
                  ? () => _railKey.currentState?.pageBy(-1)
                  : null,
            ),
            FushiIconButtonControl(
              key: const ValueKey<String>('video-episode-page-forward'),
              tooltip: MaterialLocalizations.of(context).nextPageTooltip,
              icon: FushiIcon(FushiIcons.chevronRight, size: fs + 6),
              color: cs.onSurface,
              onPressed: _canPageForward
                  ? () => _railKey.currentState?.pageBy(1)
                  : null,
            ),
            const SizedBox(width: 4),
          ],
          FushiIconButtonControl.filledTonal(
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            icon: FushiIcon(FushiIcons.close, size: fs + 4),
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }

  /// 季 chip 行（多季合集才渲染）：横向可滚，键盘/手柄经 Tab 落到 chip 上按
  /// Enter 切季。切季只换轨道内容，不换当前集、不触发播放。
  Widget _buildSeasonChips() {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: SizedBox(
        // 跟系统文字缩放走：200% 字号下 chip 不被固定高度压扁。
        height:
            MediaQuery.textScalerOf(context).scale(widget.fontSize) * 2 + 20,
        child: FushiHorizontalEdgeFade(
          child: HorizontalDragScrollable(
            child: ListView.separated(
              key: const ValueKey<String>('video-episode-season-chips'),
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsetsDirectional.only(
                start: 20,
                end: 20,
                bottom: 8,
              ),
              itemCount: _sections.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (BuildContext context, int i) {
                final String key = _sections[i].groupKey;
                return FushiChoiceChip(
                  key: ValueKey<String>('video-episode-season-chip-$key'),
                  label: Text(_labelOf(key)),
                  labelStyle: TextStyle(fontSize: widget.fontSize - 1),
                  selected: i == _selectedSection,
                  onSelected: (bool _) {
                    if (i == _selectedSection) return;
                    setState(() => _selectedSection = i);
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
      child: FushiPlaceholderMessage(
        icon: FushiIcons.video,
        message: widget.emptyHint,
      ),
    );
  }

  Widget _buildRail(double cardWidth) {
    final List<int>? visible = _visibleIndices;
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (ScrollMetricsNotification n) =>
          _onRailMetrics(n.metrics, n.depth),
      child: NotificationListener<ScrollNotification>(
        onNotification: (ScrollNotification n) =>
            _onRailMetrics(n.metrics, n.depth),
        child: VideoEpisodeRail(
          key: _railKey,
          episodes: visible == null
              ? widget.episodes
              : <VideoEpisodeEntry>[
                  for (final int i in visible) widget.episodes[i],
                ],
          indices: visible,
          currentIndex: widget.currentIndex,
          onTapEpisode: widget.onTapEpisode,
          colorScheme: widget.colorScheme,
          fontSize: widget.fontSize,
          cardWidth: cardWidth,
          active: widget.visible,
          claimFocusOnMount: _claimFocusOnMount,
          padding: const EdgeInsets.symmetric(horizontal: 20),
        ),
      ),
    );
  }
}
