import 'package:flutter/material.dart';
import 'package:fushi/src/media/video/video_panel_auto_scroll.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_jump_panel.dart'
    show formatCueTimestamp;
import 'package:fushi/src/reader/reader_panel_kit.dart'
    show ReaderBadgeShape, ReaderPolarShapeBorder;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/utils.dart';

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
    // M3 Expressive（非 Apple、非墨水屏）：行是内缩的圆角选中块（pill），序号
    // 落在一枚小圆徽标里，当前章的徽标填主色并变形成四瓣饼干（形状即状态）；
    // 选中行前景是 onSecondaryContainer（压在 secondaryContainer 色块上）。
    // Apple / 墨水屏保持原来的平铺行 + 主色字。
    final bool m3e = !isGlassDesign(context) && !isEinkTheme(context);
    return ListView.builder(
      controller: _autoScroller.controller,
      padding: m3e
          ? const EdgeInsets.fromLTRB(4, 4, 4, 16)
          : const EdgeInsets.symmetric(vertical: 8),
      itemCount: chapters.length,
      itemBuilder: (BuildContext _, int i) {
        final VideoChapter chapter = chapters[i];
        final bool selected = i == widget.currentIndex;
        final Color selectedFg = m3e ? cs.onSecondaryContainer : cs.primary;
        // BUG-1425：行骨架走共享 MD3 组件（[FushiListItem]），不再裸 ListTile。
        // 本文件的 reviewed 豁免只覆盖「行字号随 appUiScale 缩放」这一条内容理由，
        // 从不覆盖行骨架；它援引的同类 video_subtitle_jump_panel 也根本不用 ListTile。
        return FushiListItem(
          density: FushiListDensity.compact,
          selected: selected,
          selectedShape: m3e
              ? FushiListItemSelectedShape.pill
              : FushiListItemSelectedShape.fill,
          leading: m3e
              ? _ChapterIndexBadge(
                  number: i + 1,
                  selected: selected,
                  colorScheme: cs,
                  fontSize: widget.fontSize,
                )
              : Text(
                  '${i + 1}',
                  style: TextStyle(
                    color: selected ? cs.primary : cs.onSurfaceVariant,
                    fontSize: widget.fontSize,
                    fontWeight: selected ? FontWeight.w600 : null,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
          titleMaxLines: 2,
          title: Text(
            _chapterLabel(chapter),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: selected ? selectedFg : cs.onSurface,
              fontSize: widget.fontSize,
              fontWeight: selected ? FontWeight.w600 : null,
            ),
          ),
          subtitle: Text(
            formatCueTimestamp(chapter.start.inMilliseconds),
            style: TextStyle(
              color: selected && m3e
                  ? selectedFg.withValues(alpha: 0.78)
                  : cs.onSurfaceVariant,
              fontSize: widget.fontSize - 2,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
          trailing:
              selected ? FushiIcon(Icons.play_arrow, color: selectedFg) : null,
          onTap: () => widget.onTapChapter(chapter),
        );
      },
    );
  }
}

/// M3E 章节序号徽标：常态是淡色小圆（onSurface 8%），当前章填主色并变形成
/// 四瓣饼干（[ReaderBadgeShape.cookie4]），形状与颜色一起表达「正在播放」。
class _ChapterIndexBadge extends StatelessWidget {
  const _ChapterIndexBadge({
    required this.number,
    required this.selected,
    required this.colorScheme,
    required this.fontSize,
  });

  final int number;
  final bool selected;
  final ColorScheme colorScheme;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = colorScheme;
    final double size = (fontSize * 2.3).clamp(28.0, 44.0).toDouble();
    return SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: selected ? cs.primary : cs.onSurface.withValues(alpha: 0.08),
          shape: selected
              ? ReaderPolarShapeBorder.of(ReaderBadgeShape.cookie4)
              : const CircleBorder(),
        ),
        child: Center(
          child: Text(
            '$number',
            maxLines: 1,
            style: TextStyle(
              color: selected ? cs.onPrimary : cs.onSurfaceVariant,
              fontSize: fontSize - 1,
              fontWeight: FontWeight.w600,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );
  }
}
