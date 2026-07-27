import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:hibiki/src/media/video/video_chrome_colors.dart';
import 'package:hibiki/src/media/video/video_panel_auto_scroll.dart';

/// 剧集面板的一条：标题 + 可选封面。
///
/// 此前面板的入参是 `List<String> episodeTitles`——**接口只收字符串，结构上就装
/// 不下封面**，于是剧集列表恒无图（用户报「视频里面的剧集列表，少了封面」）。
/// 封面源由调用方经 `resolveMediaCoverImage` 解析好再传进来：本组件只管画，不关心
/// 这一集是本地文件还是互联远端（与 `PosterCoverImage` 同一分工原则）。
class VideoEpisodeEntry {
  const VideoEpisodeEntry({required this.title, this.cover});

  final String title;

  /// 已解析好的封面图源；null = 该集无封面可用，画占位图标。
  final ImageProvider? cover;
}

/// 视频播放列表「剧集列表」push-aside 侧栏面板（TODO-638）。
///
/// 此前剧集列表是 `showModalBottomSheet`（底部弹层），与其它侧栏（字幕列表 push-aside、
/// 设置 / 倍速等 overlay）显示风格不一致。改成与字幕列表同款的 push-aside 侧栏后，三者
/// 视觉统一：顶部带标题 + 右上角 × 关闭按钮的 header，下面是可滚动的剧集列表。
///
/// 本 widget 只负责渲染——把每集列成「序号 / 当前集播放图标 + 封面缩略图 + 标题」
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
  final double fontSize;
  final double width;

  @override
  State<VideoEpisodePanel> createState() => _VideoEpisodePanelState();
}

class _VideoEpisodePanelState extends State<VideoEpisodePanel> {
  // 「当前集滚到视口中部偏上」的机器与章节面板共享（[VideoPanelAutoScroller]）。
  final VideoPanelAutoScroller _autoScroller = VideoPanelAutoScroller();

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
        final String episodeTitle = entry.title;
        final bool selected = i == widget.currentIndex;
        // 序号/播放标记 + 封面缩略图。封面缺失（旧单行 playlist 远端模型不下发
        // 封面、或本集确实没图）时**不占位撑宽**，退回原来的纯序号形态——列表
        // 宽度只有 240~420，给一列空占位会白吃走标题的横向空间。
        final Widget indicator = selected
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
              );
        final ImageProvider? cover = entry.cover;
        return ListTile(
          dense: true,
          leading: cover == null
              ? indicator
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    indicator,
                    const SizedBox(width: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: SizedBox(
                        // 16:9 小图：视频封面现状是抽帧横图，按横版给位不裁脸。
                        width: 56,
                        height: 32,
                        child: Image(
                          image: cover,
                          fit: BoxFit.cover,
                          // 文件缺失 / 解码失败 / 远端拉不到 → 退占位图标，不炸列表。
                          errorBuilder: (_, __, ___) => Icon(
                            Icons.movie_outlined,
                            size: 18,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
          title: Text(
            episodeTitle,
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
