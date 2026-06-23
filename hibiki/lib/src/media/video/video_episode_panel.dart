import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:hibiki/src/media/video/m3u8_playlist.dart';

/// 视频播放列表「剧集列表」push-aside 侧栏面板（TODO-638）。
///
/// 此前剧集列表是 `showModalBottomSheet`（底部弹层），与其它侧栏（字幕列表 push-aside、
/// 设置 / 倍速等 overlay）显示风格不一致。改成与字幕列表同款的 push-aside 侧栏后，三者
/// 视觉统一：顶部带标题 + 右上角 × 关闭按钮的 header，下面是可滚动的剧集列表。
///
/// 本 widget 只负责渲染——把每集（[PlaylistEntry]）列成「序号 / 当前集播放图标 + 标题」
/// 一行，点击 [onTapEpisode] 切到该集（页面层 `_switchEpisode`），高亮 [currentIndex]
/// 当前集。可见性与互斥由页面层（`_episodeListVisible` / `_videoWithSubtitlePanel`）管。
///
/// 与 [VideoChapterPanel] 同构（简单的 [ListView] + 当前项高亮 + play_arrow 标记），但
/// header 借鉴字幕列表面板（标题 + ×），让用户能从侧栏内部直接关闭，关闭交互（× / Esc /
/// 控制条剧集按钮）与字幕列表三路等价。
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
    this.fontSize = 14,
    this.width = 320,
  });

  /// 播放列表各集。空列表（单视频）时显示 [emptyHint]（剧集入口仅在播放列表出现，
  /// 故正常不会空；空态作防御兜底）。
  final List<PlaylistEntry> episodes;

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
  final double fontSize;
  final double width;

  @override
  State<VideoEpisodePanel> createState() => _VideoEpisodePanelState();
}

class _VideoEpisodePanelState extends State<VideoEpisodePanel> {
  final ScrollController _scrollController = ScrollController();
  int _lastScrolledIndex = -1;

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
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToCurrentEpisode() {
    final int index = widget.currentIndex;
    if (index < 0 || index >= widget.episodes.length) return;
    if (index == _lastScrolledIndex) return;
    if (!_scrollController.hasClients) return;
    _lastScrolledIndex = index;
    // 估算行高（dense ListTile，标题最多两行）约 56；把当前集滚到视口中部偏上。
    const double rowExtent = 56;
    final double viewport = _scrollController.position.viewportDimension;
    final double target = (index * rowExtent) - (viewport / 2) + rowExtent;
    final double clamped =
        target.clamp(0.0, _scrollController.position.maxScrollExtent);
    _scrollController.animateTo(
      clamped,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = widget.colorScheme;
    // 背景半透明色挂在 [Material] 上（而非中间套一层 [ColoredBox]）：行用 [ListTile]，
    // 它要求 [Material] 是其直接祖先、且祖先与它之间不能夹不透明的 [ColoredBox]（否则
    // 抛 inkwell-on-opaque 断言）。故 Material 直接着色，内层只用 [SizedBox] 定宽。
    return Material(
      color: cs.surface.withValues(alpha: 0.92),
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
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: widget.episodes.length,
      itemBuilder: (BuildContext _, int i) {
        final PlaylistEntry episode = widget.episodes[i];
        final bool selected = i == widget.currentIndex;
        return ListTile(
          dense: true,
          // 当前集用 play_arrow 取代序号（与原 bottom sheet 一致）；其余集显示序号。
          leading: selected
              ? Icon(Icons.play_arrow, color: cs.primary)
              : SizedBox(
                  // 序号列宽随字号缩放（对齐 TODO-567 字幕时间戳列范式）：固定 24px
                  // 在放大字号下放不下两位数序号（tabular figures，10 起约字号×1.2），
                  // Text 默认换行被 dense ListTile 行高纵向裁切。改为 `字号 + 12` 估宽
                  // 留余量，下界 24 保证窄字号像素不变（向后兼容）。配合 Text 单行不
                  // 换行（`maxLines:1` / `softWrap:false`），序号永不溢出 / 被裁。
                  width: math.max(24.0, widget.fontSize + 12),
                  child: Text(
                    '${i + 1}',
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    softWrap: false,
                    style: TextStyle(
                      color: cs.onSurfaceVariant,
                      fontSize: widget.fontSize,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ),
          title: Text(
            episode.title,
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
