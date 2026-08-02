import 'package:flutter/material.dart';
import 'package:hibiki/src/media/video/video_panel_auto_scroll.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/media/video/video_subtitle_jump_panel.dart'
    show formatCueTimestamp;
import 'package:hibiki/utils.dart';

/// 视频内封章节（chapter）列表面板（TODO-424）。复用 [VideoTranslucentSidePanel]
/// 的侧栏外壳，本 widget 只负责列出 [VideoPlayerController.chapters]：每行「序号 +
/// 标题 + 起始时间戳」，点击 [onTapChapter] 跳转到该章，高亮 [currentIndex] 当前章。
///
/// 标题为空（容器没写 chapter title）时回退成本地化的「章节 N」（[t.video_chapter_n]）。
/// 当前章经父级以 [currentIndex] 传入（从 libmpv `chapter` 属性读得，异步刷新）；
/// 列表内容随 [controller] 的 chapter 列表变化（[load]/换集刷新）重建。
class VideoChapterPanel extends StatefulWidget {
  const VideoChapterPanel({
    super.key,
    required this.controller,
    required this.onTapChapter,
    required this.currentIndex,
    required this.colorScheme,
    required this.emptyHint,
    this.fontSize = 14,
  });

  final VideoPlayerController controller;

  /// 点某章 → 跳到该章起点（页面层 [VideoPlayerController.seekToChapter]）。
  final void Function(VideoChapter chapter) onTapChapter;

  /// 当前播放所在章节下标（libmpv `chapter`，0-based）；负 / 越界视为「无当前章」。
  final int currentIndex;
  final ColorScheme colorScheme;

  /// 无章节时的占位提示。
  final String emptyHint;
  final double fontSize;

  @override
  State<VideoChapterPanel> createState() => _VideoChapterPanelState();
}

class _VideoChapterPanelState extends State<VideoChapterPanel> {
  // 「当前章滚到视口中部偏上」的机器与剧集面板共享（[VideoPanelAutoScroller]）。
  final VideoPanelAutoScroller _autoScroller = VideoPanelAutoScroller();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void didUpdateWidget(covariant VideoChapterPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 当前章由父级刷新（异步读 chapter 属性）：变化时滚动到它。
    if (oldWidget.currentIndex != widget.currentIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToCurrentChapter();
      });
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _autoScroller.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  void _scrollToCurrentChapter() {
    _autoScroller.scrollToIndex(
      widget.currentIndex,
      itemCount: widget.controller.chapters.length,
    );
  }

  String _chapterLabel(VideoChapter chapter) {
    final String title = chapter.title.trim();
    if (title.isNotEmpty) return title;
    return t.video_chapter_n(n: chapter.index + 1);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = widget.colorScheme;
    final List<VideoChapter> chapters = widget.controller.chapters;
    if (chapters.isEmpty) {
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
    return ListView.builder(
      controller: _autoScroller.controller,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: chapters.length,
      itemBuilder: (BuildContext _, int i) {
        final VideoChapter chapter = chapters[i];
        final bool selected = i == widget.currentIndex;
        // BUG-1418：行骨架走共享 MD3 组件（[HibikiListItem]），不再裸 ListTile。
        // 本文件的 reviewed 豁免只覆盖「行字号随 appUiScale 缩放」这一条内容理由，
        // 从不覆盖行骨架；它援引的同类 video_subtitle_jump_panel 也根本不用 ListTile。
        return HibikiListItem(
          density: HibikiListDensity.compact,
          selected: selected,
          leading: Text(
            '${i + 1}',
            style: TextStyle(
              color: selected ? cs.primary : cs.onSurfaceVariant,
              fontSize: widget.fontSize,
              fontWeight: selected ? FontWeight.w600 : null,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
          titleMaxLines: 2,
          title: Text(
            _chapterLabel(chapter),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: selected ? cs.primary : cs.onSurface,
              fontSize: widget.fontSize,
              fontWeight: selected ? FontWeight.w600 : null,
            ),
          ),
          subtitle: Text(
            formatCueTimestamp(chapter.start.inMilliseconds),
            style: TextStyle(
              color: cs.onSurfaceVariant,
              fontSize: widget.fontSize - 2,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
          trailing: selected ? Icon(Icons.play_arrow, color: cs.primary) : null,
          onTap: () => widget.onTapChapter(chapter),
        );
      },
    );
  }
}
