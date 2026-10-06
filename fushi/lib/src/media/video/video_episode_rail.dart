import 'package:flutter/material.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/cover_ui/portrait_cover_image.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_expressive_progress.dart';
import 'package:fushi/src/utils/components/fushi_horizontal_edge_fade.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

/// 横向剧集轨道的一条展示数据。
///
/// 页面层负责把本地 / 互联数据解析成统一的 [ImageProvider]；轨道只负责展示，
/// 不知道文件路径、URL 或缓存细节。
class VideoEpisodeEntry {
  const VideoEpisodeEntry({
    required this.title,
    this.cover,
    this.episodeNumber,
    this.groupKey,
    this.completed = false,
    this.started = false,
    this.progress,
  });

  final String title;
  final ImageProvider? cover;

  /// 季分组键（`collectionGroupKeyForFilename` 派生：`s<N>` / extras）。面板据此
  /// 把多季合集切成季 chip；null 或全表同键 = 单季，面板零变化。与合集详情页
  /// 的季 tab 同一真相源（文件名纯函数，不落库）。
  final String? groupKey;

  /// 卡片角标显示的**真实集号**（从文件名解析，见 `parsedEpisodeNumberOf`）。
  /// null = 解析不出（PV / 特典 / 远端无路径），卡片回落列表顺位号。
  ///
  /// 顺位号会在「缺集 / 只导入了一部分」时说谎：`S01E05` 排在第 3 位就标成
  /// `03`（BUG-1544）。集号是文件名里写着的事实，不是下标的函数。
  final int? episodeNumber;

  final bool completed;
  final bool started;

  /// 观看进度 0..1（断点 / 时长）。只在两者都已知时给（远端集 host 下发时长）；
  /// null = 不知道比例——在看的集退回「在看」角标，不画一条猜出来的进度条。
  final double? progress;
}

/// Jellyfin 式横向剧集轨道：16:9 画面卡、集号、标题与当前集状态共用一条视觉轴。
///
/// 播放器选集面板使用本组件。M3E 形态：圆角 20 卡 + 底部 scrim 上的集号胶囊与
/// 两行标题、当前集 primary 色块边框 +「正在播放」胶囊 + 轻微放大、悬停 / 焦点
/// spring 抬升、观看进度细波浪条；两端按溢出方向渐隐。
class VideoEpisodeRail extends StatefulWidget {
  const VideoEpisodeRail({
    super.key,
    required this.episodes,
    required this.currentIndex,
    required this.onTapEpisode,
    required this.colorScheme,
    this.fontSize = 14,
    this.cardWidth = 184,
    this.padding = const EdgeInsets.symmetric(horizontal: 20),
    this.indices,
    this.active = true,
  });

  final List<VideoEpisodeEntry> episodes;

  /// 当前集的**全局**下标（与 [indices] 同口径）。
  final int currentIndex;

  /// 每张卡对应的全局下标（面板按季切片时 [episodes] 只是一节，卡片 key /
  /// 选中态 / 点击回调都必须报全局下标）。null = 恒等映射（未切片）。
  final List<int>? indices;
  final ValueChanged<int> onTapEpisode;
  final ColorScheme colorScheme;
  final double fontSize;
  final double cardWidth;
  final EdgeInsetsGeometry padding;

  /// 轨道所在面板是否正在显示。常驻挂载的播放器面板由 false → true 时把当前集
  /// 滚到正中并把焦点交给当前集卡（方向键 / 手柄直接从当前集出发）。
  final bool active;

  /// 卡片上下为抬升 / 放大留的余量（逻辑 px）。
  static const double liftPadding = 10;

  /// 轨道总高度（卡高 + 上下抬升余量），面板据此排版。
  static double heightFor(double cardWidth) =>
      cardWidth * 9 / 16 + liftPadding * 2;

  @override
  State<VideoEpisodeRail> createState() => VideoEpisodeRailState();
}

class VideoEpisodeRailState extends State<VideoEpisodeRail> {
  static const double _gap = 12;
  final ScrollController _controller = ScrollController();

  /// 当前集卡的焦点节点：随选中态在卡片间移交，面板打开时由它认领焦点。
  final FocusNode _currentFocus =
      FocusNode(debugLabel: 'video-episode-current');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _revealCurrent(animate: false),
    );
  }

  @override
  void didUpdateWidget(covariant VideoEpisodeRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      // 面板打开：先无动画定位到当前集（面板本身在 spring 进场），下一帧再把
      // 焦点交给当前集卡——卡片可能本来在懒加载范围外，要等定位后的那一帧建出来。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _revealCurrent(animate: false);
        WidgetsBinding.instance.addPostFrameCallback((_) => _focusCurrent());
        WidgetsBinding.instance.scheduleFrame();
      });
      WidgetsBinding.instance.scheduleFrame();
      return;
    }
    if (oldWidget.currentIndex != widget.currentIndex ||
        oldWidget.episodes.length != widget.episodes.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _revealCurrent());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _currentFocus.dispose();
    super.dispose();
  }

  int _globalIndexAt(int position) => widget.indices?[position] ?? position;

  /// 当前集在本轨道里的位置；不在本轨道（当前集属于另一季）→ -1。
  int get _currentPosition {
    final List<int>? indices = widget.indices;
    if (indices == null) {
      return widget.currentIndex < widget.episodes.length
          ? widget.currentIndex
          : -1;
    }
    return indices.indexOf(widget.currentIndex);
  }

  /// 是否还能往前 / 往后翻页（面板的左右翻页按钮读它）。
  bool get canPageBack =>
      _controller.hasClients && _controller.position.extentBefore > 0.5;
  bool get canPageForward =>
      _controller.hasClients && _controller.position.extentAfter > 0.5;

  /// 横向翻一屏（[direction] < 0 往前、> 0 往后），保留一张卡的重叠做视觉锚点。
  void pageBy(int direction) {
    if (!_controller.hasClients) return;
    final ScrollPosition position = _controller.position;
    final double step = (position.viewportDimension - widget.cardWidth)
        .clamp(widget.cardWidth + _gap, double.infinity);
    final double target = (position.pixels + step * direction.sign).clamp(
      0.0,
      position.maxScrollExtent,
    );
    final FushiSpringSpec spring = context.fushiMotion.spatialDefault;
    if (!spring.enabled) {
      _controller.jumpTo(target);
      return;
    }
    _controller.animateTo(
      target,
      duration: spring.duration,
      curve: spring.curve,
    );
  }

  void _focusCurrent() {
    if (!mounted || !widget.active) return;
    if (_currentPosition < 0) return;
    if (_currentFocus.context == null) return;
    _currentFocus.requestFocus();
  }

  /// 把当前集滚到视口正中（首尾集钳在两端）。
  void _revealCurrent({bool animate = true}) {
    if (!mounted || !_controller.hasClients) return;
    final int current = _currentPosition;
    if (current < 0) return;
    final ScrollPosition position = _controller.position;
    final double leading =
        widget.padding.resolve(Directionality.of(context)).horizontal / 2;
    final double itemExtent = widget.cardWidth + _gap;
    final double target = (leading +
            current * itemExtent +
            widget.cardWidth / 2 -
            position.viewportDimension / 2)
        .clamp(0.0, position.maxScrollExtent);
    if ((position.pixels - target).abs() < 1) return;
    final FushiSpringSpec spring = context.fushiMotion.spatialDefault;
    if (!animate || !spring.enabled) {
      _controller.jumpTo(target);
      return;
    }
    _controller.animateTo(
      target,
      duration: spring.duration,
      curve: spring.curve,
    );
  }

  @override
  Widget build(BuildContext context) {
    final EdgeInsets padding =
        widget.padding.resolve(Directionality.of(context)).copyWith(
              top: VideoEpisodeRail.liftPadding,
              bottom: VideoEpisodeRail.liftPadding,
            );
    return SizedBox(
      height: VideoEpisodeRail.heightFor(widget.cardWidth),
      // 桌面默认 MaterialScrollBehavior 的 dragDevices 不含鼠标——横排轨道用鼠标
      // 左右拖会毫无反应。与合集行 / 标签栏一样统一走共享件放开 mouse/trackpad/
      // stylus 拖动；触屏行为不变。轨道内只有卡片 InkWell（点击），没有依赖横拖
      // 的手势，不存在竞技场之争。
      child: FushiHorizontalEdgeFade(
        extent: 28,
        child: HorizontalDragScrollable(
          child: ListView.separated(
            controller: _controller,
            scrollDirection: Axis.horizontal,
            padding: padding,
            itemCount: widget.episodes.length,
            separatorBuilder: (_, __) => const SizedBox(width: _gap),
            itemBuilder: (BuildContext context, int position) {
              final int index = _globalIndexAt(position);
              final bool selected = index == widget.currentIndex;
              return _EpisodeRailCard(
                key: ValueKey<String>('video-episode-card-$index'),
                entry: widget.episodes[position],
                // 顺位号回落取**轨道内**位置：切成季后 PV/特典组从 01 数起。
                index: position,
                selected: selected,
                focusNode: selected ? _currentFocus : null,
                width: widget.cardWidth,
                fontSize: widget.fontSize,
                colorScheme: widget.colorScheme,
                onTap: () => widget.onTapEpisode(index),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _EpisodeRailCard extends StatefulWidget {
  const _EpisodeRailCard({
    super.key,
    required this.entry,
    required this.index,
    required this.selected,
    required this.width,
    required this.fontSize,
    required this.colorScheme,
    required this.onTap,
    this.focusNode,
  });

  final VideoEpisodeEntry entry;
  final int index;
  final bool selected;
  final double width;
  final double fontSize;
  final ColorScheme colorScheme;
  final VoidCallback onTap;
  final FocusNode? focusNode;

  @override
  State<_EpisodeRailCard> createState() => _EpisodeRailCardState();
}

class _EpisodeRailCardState extends State<_EpisodeRailCard> {
  bool _hovered = false;
  bool _focused = false;

  /// 卡片显示号：解析出的真实集号优先，解析不出才回落顺位号（BUG-1544）。
  int get _displayNumber => widget.entry.episodeNumber ?? widget.index + 1;

  /// 焦点只在键盘 / 手柄高亮模式下算「抬升」：鼠标点开面板时当前集卡也会领到
  /// 焦点，那时不该凭空浮起。
  bool get _lifted =>
      _hovered ||
      (_focused &&
          FocusManager.instance.highlightMode ==
              FocusHighlightMode.traditional);

  void _setHovered(bool value) {
    if (_hovered == value) return;
    setState(() => _hovered = value);
  }

  void _setFocused(bool value) {
    if (_focused == value) return;
    setState(() => _focused = value);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = widget.colorScheme;
    final FushiMotionScheme motion = context.fushiMotion;
    final bool selected = widget.selected;
    final bool lifted = _lifted;
    final bool glass = isGlassDesign(context);
    final bool eink = isEinkTheme(context);
    // 当前集：primary 色块边框（3px 外框，内圆角随之收小）+ 轻微放大；悬停 /
    // 焦点再往上抬一档并加深投影。
    const double frame = 3;
    const double radius = FushiM3eShape.card;
    final double scale = (selected ? 1.03 : 1.0) + (lifted ? 0.03 : 0.0);
    final List<BoxShadow>? shadow = eink || glass
        ? null
        : (lifted || selected)
            ? fushiM3eCardShadow(context, lifted ? 1 : 0)
            : null;
    final String label = '$_displayNumber. ${widget.entry.title}';
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: AnimatedScale(
        scale: scale,
        duration: motion.spatialFast.duration,
        curve: motion.spatialFast.curve,
        child: AnimatedContainer(
          duration: motion.effectsDefault.duration,
          curve: motion.effectsDefault.curve,
          width: widget.width,
          padding: const EdgeInsets.all(frame),
          decoration: BoxDecoration(
            color: selected ? cs.primary : Colors.transparent,
            borderRadius: const BorderRadius.all(Radius.circular(radius)),
            boxShadow: shadow,
          ),
          child: ClipRRect(
            borderRadius: const BorderRadius.all(
              Radius.circular(radius - frame),
            ),
            child: Material(
              color: cs.surfaceContainerHighest,
              child: InkWell(
                focusNode: widget.focusNode,
                canRequestFocus: true,
                onTap: widget.onTap,
                onHover: _setHovered,
                onFocusChange: _setFocused,
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    _EpisodeCover(entry: widget.entry, colorScheme: cs),
                    const _EpisodeScrim(),
                    if (selected)
                      PositionedDirectional(
                        top: 8,
                        start: 8,
                        child: _NowPlayingPill(
                          colorScheme: cs,
                          fontSize: widget.fontSize,
                        ),
                      ),
                    if (widget.entry.completed ||
                        (widget.entry.started && widget.entry.progress == null))
                      PositionedDirectional(
                        top: 8,
                        end: 8,
                        child: _StateBadge(
                          completed: widget.entry.completed,
                          colorScheme: cs,
                        ),
                      ),
                    _buildCaption(context, cs),
                    if (_showProgress)
                      PositionedDirectional(
                        start: 10,
                        end: 10,
                        bottom: 4,
                        child: _EpisodeProgress(
                          value: widget.entry.progress!,
                          colorScheme: cs,
                          waving: selected,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool get _showProgress {
    final double? progress = widget.entry.progress;
    return !widget.entry.completed && progress != null && progress > 0.005;
  }

  Widget _buildCaption(BuildContext context, ColorScheme cs) {
    final FushiTypography type = context.fushiType;
    final double fontSize = widget.fontSize;
    final bool selected = widget.selected;
    return PositionedDirectional(
      start: 10,
      end: 10,
      bottom: _showProgress ? 16 : 10,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: fontSize * 0.5,
              vertical: fontSize * 0.14,
            ),
            decoration: ShapeDecoration(
              color: selected ? cs.primaryContainer : cs.secondaryContainer,
              shape: const StadiumBorder(),
            ),
            child: Text(
              '$_displayNumber'.padLeft(2, '0'),
              maxLines: 1,
              softWrap: false,
              style: type.labelLargeEmphasized.tabular.copyWith(
                color:
                    selected ? cs.onPrimaryContainer : cs.onSecondaryContainer,
                fontSize: fontSize - 1,
                height: 1.2,
              ),
            ),
          ),
          SizedBox(width: fontSize * 0.5),
          Expanded(
            child: Text(
              widget.entry.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: type.titleSmall.copyWith(
                color: Colors.white,
                fontSize: fontSize,
                height: 1.2,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                shadows: const <Shadow>[
                  Shadow(color: Color(0x99000000), blurRadius: 6),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 底部渐变 scrim：集号胶囊与标题压在它上面，任何明暗的画面都读得清。
class _EpisodeScrim extends StatelessWidget {
  const _EpisodeScrim();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: <double>[0.3, 0.62, 1],
          colors: <Color>[
            Color(0x00000000),
            Color(0x8C000000),
            Color(0xE6000000),
          ],
        ),
      ),
    );
  }
}

/// 「▶ 正在播放」胶囊（当前集左上角）。
class _NowPlayingPill extends StatelessWidget {
  const _NowPlayingPill({required this.colorScheme, required this.fontSize});

  final ColorScheme colorScheme;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = colorScheme;
    return Container(
      padding: EdgeInsetsDirectional.fromSTEB(
        fontSize * 0.4,
        fontSize * 0.18,
        fontSize * 0.6,
        fontSize * 0.18,
      ),
      decoration: ShapeDecoration(
        color: cs.primary,
        shape: const StadiumBorder(),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FushiIcon(
            FushiIcons.filled(FushiIcons.play),
            size: fontSize + 2,
            color: cs.onPrimary,
          ),
          SizedBox(width: fontSize * 0.2),
          Text(
            t.reader_audiobook_now_playing,
            maxLines: 1,
            softWrap: false,
            style: context.fushiType.labelMediumEmphasized.copyWith(
              color: cs.onPrimary,
              fontSize: fontSize - 2,
            ),
          ),
        ],
      ),
    );
  }
}

/// 右上角 tonal 状态徽标：看完 = 勾、在看（无进度比例）= 历史。
class _StateBadge extends StatelessWidget {
  const _StateBadge({required this.completed, required this.colorScheme});

  final bool completed;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = colorScheme;
    return Container(
      padding: const EdgeInsets.all(5),
      decoration: ShapeDecoration(
        color: completed ? cs.secondaryContainer : cs.surfaceContainerHighest,
        shape: const CircleBorder(),
      ),
      child: FushiIcon(
        completed ? FushiIcons.check : FushiIcons.history,
        size: 16,
        color: completed ? cs.onSecondaryContainer : cs.onSurface,
      ),
    );
  }
}

/// 观看进度：M3E 细波浪（当前集流动、其余集收平成直线），Apple / 墨水屏走共享
/// 线性进度条。
class _EpisodeProgress extends StatelessWidget {
  const _EpisodeProgress({
    required this.value,
    required this.colorScheme,
    required this.waving,
  });

  final double value;
  final ColorScheme colorScheme;
  final bool waving;

  @override
  Widget build(BuildContext context) {
    final double v = value.clamp(0.0, 1.0);
    if (isGlassDesign(context) || isEinkTheme(context)) {
      return FushiLinearProgressIndicator(
        value: v,
        minHeight: 3,
        color: colorScheme.primary,
        backgroundColor: Colors.white.withValues(alpha: 0.28),
      );
    }
    return SizedBox(
      height: 8,
      child: FushiWavyLinearProgress(
        value: v,
        color: colorScheme.primary,
        trackColor: Colors.white.withValues(alpha: 0.28),
        strokeWidth: 3,
        trackGap: 3,
        stopIndicatorColor: Colors.transparent,
        waving: waving && context.fushiMotion.enabled,
      ),
    );
  }
}

class _EpisodeCover extends StatelessWidget {
  const _EpisodeCover({required this.entry, required this.colorScheme});

  final VideoEpisodeEntry entry;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    final ImageProvider? cover = entry.cover;
    if (cover == null) return _placeholder();
    // 16:9 横槽走朝向自适应（v68 收口）：刮到的剧照天然合槽直接铺满；没刮过的集
    // （2:3 刮削海报 / 方图）模糊垫底 + contain 完整显示。此前这里是全域唯一还在
    // 裸 `BoxFit.cover` 硬裁的封面消费点——竖版海报被裁成中间一条（BUG-1299 同病）。
    return PortraitCoverImage(
      image: cover,
      landscapeSlot: true,
      errorBuilder: (BuildContext _) => _placeholder(),
    );
  }

  Widget _placeholder() => ColoredBox(
        color: colorScheme.surfaceContainerHighest,
        child: Center(
          child: FushiIcon(
            FushiIcons.video,
            size: 30,
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      );
}
