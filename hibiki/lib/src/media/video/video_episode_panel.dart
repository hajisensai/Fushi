import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:hibiki/src/media/video/episode_thumbnail_cache.dart';
import 'package:hibiki/src/media/video/video_chrome_colors.dart';
import 'package:hibiki/src/media/video/video_panel_auto_scroll.dart';

/// 视频播放列表「剧集列表」push-aside 侧栏面板（TODO-638）。
///
/// 此前剧集列表是 `showModalBottomSheet`（底部弹层），与其它侧栏（字幕列表 push-aside、
/// 设置 / 倍速等 overlay）显示风格不一致。改成与字幕列表同款的 push-aside 侧栏后，三者
/// 视觉统一：顶部带标题 + 右上角 × 关闭按钮的 header，下面是可滚动的剧集列表。
///
/// 剧集封面（Netflix/Jellyfin 式）：每行左侧一张 16:9 缩略图（各集自己的抽帧画面，来源
/// 见 [VideoEpisodeEntry]），右侧沿用标题；当前集用 play_arrow 覆盖 + primary 高亮标记。
/// 缩略图经 [EpisodeThumbnailResolver] 懒加载，文件缺失 / 无封面时静默回退纯序号占位。
///
/// 本 widget 只负责渲染——点击 [onTapEpisode] 切到该集（页面层 `_switchEpisode`），高亮
/// [currentIndex] 当前集。可见性与互斥由页面层（`_episodeListVisible` /
/// `_videoWithSubtitlePanel`）管。
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
    this.thumbnailResolver,
    this.fontSize = 14,
    this.width = 320,
  });

  /// 播放列表各集（有序）。空列表（单视频）时显示 [emptyHint]（剧集入口仅在播放列表
  /// 出现，故正常不会空；空态作防御兜底）。
  final List<VideoEpisodeEntry> episodes;

  /// 当前播放集下标（[episodes] 内）；负 / 越界视为「无当前集」。
  final int currentIndex;

  /// 点某集 → 切到该集（页面层 `_switchEpisode(index, ...)`）。回调入参为集下标。
  final void Function(int index) onTapEpisode;

  /// 头部 × 关闭按钮（页面层 `_closeEpisodeList`，与 Esc / 控制条剧集按钮三路等价）。
  final VoidCallback onClose;

  /// 缩略图解析器；null 时用进程内单例 [EpisodeThumbnailCache.instance]（生产路径）。
  /// 测试注入替身，不真跑 ffmpeg。
  final EpisodeThumbnailResolver? thumbnailResolver;

  final ColorScheme colorScheme;
  final String title;

  /// 列表为空时的占位提示。
  final String emptyHint;
  final double fontSize;
  final double width;

  @override
  State<VideoEpisodePanel> createState() => _VideoEpisodePanelState();
}

class _VideoEpisodePanelState extends State<VideoEpisodePanel> {
  // 「当前集滚到视口中部偏上」的机器与章节面板共享（[VideoPanelAutoScroller]）。
  final VideoPanelAutoScroller _autoScroller = VideoPanelAutoScroller();

  EpisodeThumbnailResolver get _resolver =>
      widget.thumbnailResolver ?? EpisodeThumbnailCache.instance;

  @override
  void initState() {
    super.initState();
    // 首帧滚到当前集（异步：列表挂载后才有 viewport）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToCurrentEpisode();
    });
  }

  @override
  void didUpdateWidget(covariant VideoEpisodePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 当前集变化（换集 / 自动连播）时滚动到它。
    if (oldWidget.currentIndex != widget.currentIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToCurrentEpisode();
      });
    }
  }

  @override
  void dispose() {
    _autoScroller.dispose();
    super.dispose();
  }

  void _scrollToCurrentEpisode() {
    _autoScroller.scrollToIndex(
      widget.currentIndex,
      itemCount: widget.episodes.length,
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = widget.colorScheme;
    // 背景半透明色挂在 [Material] 上（而非中间套一层 [ColoredBox]）：行用 [ListTile]，
    // 它要求 [Material] 是其直接祖先、且祖先与它之间不能夹不透明的 [ColoredBox]（否则
    // 抛 inkwell-on-opaque 断言）。故 Material 直接着色，内层只用 [SizedBox] 定宽。
    return Material(
      // 浮层 alpha 两档制的实底档（UI 巡检 PR-4，0.92 → 0.94 归档）：剧集行文本
      // 密集，近实底保证可读。
      color: cs.surface.withValues(alpha: kVideoOverlaySolidAlpha),
      child: SizedBox(
        width: widget.width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _buildHeader(cs),
            const Divider(height: 1),
            Expanded(
              child: widget.episodes.isEmpty ? _buildEmpty(cs) : _buildList(cs),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ColorScheme cs) {
    final double iconSize = widget.fontSize + 4;
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 4, top: 4, bottom: 6),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: cs.onSurface,
                fontSize: widget.fontSize + 1,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            icon: Icon(Icons.close, size: iconSize),
            color: cs.onSurfaceVariant,
            onPressed: widget.onClose,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(ColorScheme cs) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          widget.emptyHint,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: cs.onSurfaceVariant,
            fontSize: widget.fontSize,
          ),
        ),
      ),
    );
  }

  Widget _buildList(ColorScheme cs) {
    return ListView.builder(
      controller: _autoScroller.controller,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: widget.episodes.length,
      itemBuilder: (BuildContext _, int i) {
        final VideoEpisodeEntry entry = widget.episodes[i];
        final bool selected = i == widget.currentIndex;
        // 缩略图宽度随字号缩放（16:9），下界 96 / 上界 160，与任务约定 96~120 一致。
        final double thumbWidth =
            (widget.fontSize / 14.0 * 108.0).clamp(96.0, 160.0);
        return ListTile(
          dense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          horizontalTitleGap: 12,
          // 左侧 16:9 缩略图（各集自己的抽帧封面），当前集叠 play_arrow + primary 边框。
          leading: _EpisodeThumbnail(
            key: ValueKey<String>(
              'ep-thumb-${entry.thumbnailKey ?? entry.coverPath ?? entry.title}-$i',
            ),
            entry: entry,
            resolver: _resolver,
            index: i,
            selected: selected,
            width: thumbWidth,
            colorScheme: cs,
            fontSize: widget.fontSize,
          ),
          title: Text(
            entry.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: selected ? cs.primary : cs.onSurface,
              fontSize: widget.fontSize,
              fontWeight: selected ? FontWeight.w600 : null,
            ),
          ),
          selected: selected,
          selectedColor: cs.primary,
          onTap: () => widget.onTapEpisode(i),
        );
      },
    );
  }
}

/// 单集缩略图：16:9 圆角封面 + 左下角序号徽标；当前集叠半透明 scrim + 居中 play_arrow +
/// primary 边框。封面经 [resolver] 懒加载（异步），加载中 / 失败显示占位（movie 图标）。
///
/// [ListView] 回收：[entry] 变化（换集重建同一行 element）时按 [_resolveToken] 丢弃
/// 过期解析，避免把上一集的封面画到本集。
class _EpisodeThumbnail extends StatefulWidget {
  const _EpisodeThumbnail({
    super.key,
    required this.entry,
    required this.resolver,
    required this.index,
    required this.selected,
    required this.width,
    required this.colorScheme,
    required this.fontSize,
  });

  final VideoEpisodeEntry entry;
  final EpisodeThumbnailResolver resolver;
  final int index;
  final bool selected;
  final double width;
  final ColorScheme colorScheme;
  final double fontSize;

  @override
  State<_EpisodeThumbnail> createState() => _EpisodeThumbnailState();
}

class _EpisodeThumbnailState extends State<_EpisodeThumbnail> {
  String? _coverPath;
  int _resolveToken = 0;

  @override
  void initState() {
    super.initState();
    _startResolve();
  }

  @override
  void didUpdateWidget(covariant _EpisodeThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 行被回收复用到另一集：重新解析封面（旧 token 的完成回调将被忽略）。
    if (!_sameEntry(oldWidget.entry, widget.entry)) {
      _coverPath = null;
      _startResolve();
    }
  }

  bool _sameEntry(VideoEpisodeEntry a, VideoEpisodeEntry b) =>
      a.coverPath == b.coverPath &&
      a.videoPath == b.videoPath &&
      a.thumbnailKey == b.thumbnailKey &&
      a.title == b.title;

  void _startResolve() {
    final int token = ++_resolveToken;
    final VideoEpisodeEntry entry = widget.entry;
    unawaited(() async {
      final String? path = await widget.resolver.resolve(entry);
      if (!mounted || token != _resolveToken) return;
      // 只在有变化时 setState，避免无谓重建。
      if (path != _coverPath) {
        setState(() => _coverPath = path);
      }
    }());
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = widget.colorScheme;
    final double w = widget.width;
    final double h = w * 9.0 / 16.0;
    final String? cover = _coverPath;
    final double dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 2.0;
    return SizedBox(
      width: w,
      height: h,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            // 底：封面或占位。
            if (cover != null)
              Image.file(
                File(cover),
                fit: BoxFit.cover,
                // 解码尺寸按显示宽 × dpr 限制，控制内存 / 加速滚动。
                cacheWidth: (w * dpr).round(),
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => _placeholder(cs),
              )
            else
              _placeholder(cs),
            // 当前集：半透明 scrim + 居中 play_arrow。
            if (widget.selected) ...<Widget>[
              ColoredBox(color: Colors.black.withValues(alpha: 0.32)),
              Center(
                child: Icon(
                  Icons.play_arrow,
                  color: cs.primary,
                  size: math.max(20.0, widget.fontSize + 6),
                ),
              ),
            ],
            // 左下角序号徽标（始终显示，便于无封面时也能看清顺序）。
            Positioned(
              left: 2,
              bottom: 2,
              child: _numberBadge(cs),
            ),
            // 当前集 primary 边框。
            if (widget.selected)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: cs.primary, width: 2),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder(ColorScheme cs) {
    return ColoredBox(
      color: cs.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.movie_outlined,
          color: cs.onSurfaceVariant,
          size: math.max(18.0, widget.fontSize + 2),
        ),
      ),
    );
  }

  Widget _numberBadge(ColorScheme cs) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        child: Text(
          '${widget.index + 1}',
          maxLines: 1,
          softWrap: false,
          style: TextStyle(
            color: Colors.white,
            fontSize: math.max(10.0, widget.fontSize - 2),
            fontWeight: FontWeight.w600,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}
