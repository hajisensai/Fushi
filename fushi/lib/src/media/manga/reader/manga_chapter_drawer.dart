import 'dart:async';

import 'package:fushi/src/utils/state_resource_scope.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/manga/library/manga_chapter_list.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi_core/fushi_core.dart';

/// 阅读器里的章节抽屉（左侧侧栏，对齐 Mihon / Mangatan 的章节抽屉）。
///
/// 列表本体复用作品页那一份 [MangaChapterList]（两处对「已读怎么显示、当前章怎么
/// 高亮、排序哪个方向」的答案必须一致）。抽屉自己只管三件事：
///
/// - **排序**：新→旧 / 旧→新切换，初值与回写都走全局偏好
///   （`manga_chapter_list_newest_first`，作品页同一份）。
/// - **定位**：打开即把当前章滚进视口；顶栏另有「跳到当前章节 / 顶部 / 底部」。
/// - **快速滚动**：可拖动的滚动条，几百话的表直接拖到想去的地方。
///
/// 列表用懒建的 sliver 形态（[MangaChapterList.sliver]）：上千话的在线源以前一开
/// 抽屉就把每一话都建出来、全部排版（gap-mangamisc-5）。当前章行还没建时由
/// [scrollToMangaChapter] 按已建行的行高估位置再精确对齐。
///
/// 顶栏动作默认全部平铺，抽屉放不下时按优先级（排序 > 当前章 > 顶部 > 底部）
/// 从低往高收进「⋯」，测宽与回差复用 [FushiTopBarOverflowFit]。
class MangaChapterDrawer extends StatefulWidget {
  const MangaChapterDrawer({
    required this.entry,
    required this.states,
    required this.initialNewestFirst,
    required this.onChapterTap,
    required this.onClose,
    super.key,
    this.currentChapterKey,
    this.downloadedChapterKeys = const <String>{},
    this.onNewestFirstChanged,
  });

  final OnlineMangaLibraryEntry entry;
  final Map<String, MangaChapterStateRow> states;
  final String? currentChapterKey;
  final Set<String> downloadedChapterKeys;

  /// 打开时的排序（全局偏好的当前值）。
  final bool initialNewestFirst;

  /// 用户切了排序：宿主写回偏好。
  final ValueChanged<bool>? onNewestFirstChanged;
  final void Function(OnlineMangaChapter chapter) onChapterTap;
  final VoidCallback onClose;

  @override
  State<MangaChapterDrawer> createState() => _MangaChapterDrawerState();
}

/// 抽屉标题至少留的宽度（「章节」两三个字）；动作按钮先保它。
const double _kDrawerTitleMinWidth = 72;

class _MangaChapterDrawerState extends State<MangaChapterDrawer>
    with StateResourceScope<MangaChapterDrawer> {
  final ScrollController _scroll = ScrollController();
  final GlobalKey _currentAnchor = GlobalKey(
    debugLabel: 'manga_chapter_current',
  );
  final GlobalKey _rowsKey = GlobalKey(debugLabel: 'manga_chapter_rows');
  final FushiTopBarOverflowFit _fit = FushiTopBarOverflowFit();
  late bool _newestFirst = widget.initialNewestFirst;

  @override
  void initState() {
    super.initState();
    // 首帧布局完成后直接（不带动画）落到当前章：打开目录就该看到自己在哪。
    // 本帧正在构建，post-frame 回调必然在这一帧末尾执行。
    schedulePostFrame((_) {
      if (mounted) _scrollToCurrent();
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Duration get _jumpDuration =>
      fushiMotionDuration(context, FushiMotion.medium);

  void _toggleSort() {
    setState(() => _newestFirst = !_newestFirst);
    widget.onNewestFirstChanged?.call(_newestFirst);
    // 换序后当前章换了位置：跟过去，而不是把用户留在一段陌生的列表里。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToCurrent();
    });
  }

  /// 当前章在列表里的下标（与列表同一份排序口径）；没有当前章返回 -1。
  int get _currentIndex {
    final String? key = widget.currentChapterKey;
    if (key == null) return -1;
    return MangaChapterList.visibleChapters(
      chapters: widget.entry.chapters,
      states: widget.states,
      newestFirst: _newestFirst,
      unreadOnly: false,
    ).indexWhere((OnlineMangaChapter chapter) => chapter.key == key);
  }

  void _scrollToCurrent({Duration duration = Duration.zero}) {
    final int index = _currentIndex;
    if (index < 0) return;
    scrollToMangaChapter(
      anchor: _currentAnchor,
      rowsKey: _rowsKey,
      index: index,
      duration: duration,
    );
  }

  void _jumpToCurrent() => _scrollToCurrent(duration: _jumpDuration);

  void _jumpTo(bool top) {
    if (!_scroll.hasClients) return;
    final ScrollPosition position = _scroll.position;
    final Duration duration = _jumpDuration;
    if (top) {
      if (duration == Duration.zero) {
        position.jumpTo(position.minScrollExtent);
      } else {
        unawaited(
          position.animateTo(
            position.minScrollExtent,
            duration: duration,
            curve: FushiMotion.standard,
          ),
        );
      }
      return;
    }
    // 懒列表的总高度是按已建行估的，滚到估出来的底、末几行建出来后才知道真实的
    // 底；对齐到新的底再看一眼，行高一致时一轮就收敛。
    Future<void> settleAtBottom(int passes) async {
      if (!mounted || !_scroll.hasClients || passes <= 0) return;
      final ScrollPosition position = _scroll.position;
      if (position.pixels >= position.maxScrollExtent) return;
      position.jumpTo(position.maxScrollExtent);
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(settleAtBottom(passes - 1)),
      );
    }

    if (duration == Duration.zero) {
      unawaited(settleAtBottom(4));
    } else {
      unawaited(
        position
            .animateTo(
              position.maxScrollExtent,
              duration: duration,
              curve: FushiMotion.standard,
            )
            .then((_) => settleAtBottom(4)),
      );
    }
  }

  List<FushiToolbarItem> get _actions => <FushiToolbarItem>[
    FushiToolbarItem(
      key: const ValueKey<String>('manga_chapter_drawer_sort'),
      icon: FushiIcons.swapVert,
      label: _newestFirst
          ? t.manga_series_sort_newest
          : t.manga_series_sort_oldest,
      onPressed: _toggleSort,
    ),
    if (widget.currentChapterKey != null)
      FushiToolbarItem(
        key: const ValueKey<String>('manga_chapter_drawer_jump_current'),
        icon: FushiIcons.myLocation,
        label: t.manga_chapter_list_jump_current,
        onPressed: _jumpToCurrent,
      ),
    FushiToolbarItem(
      key: const ValueKey<String>('manga_chapter_drawer_jump_top'),
      icon: FushiIcons.alignTop,
      label: t.manga_chapter_list_jump_top,
      onPressed: () => _jumpTo(true),
    ),
    FushiToolbarItem(
      key: const ValueKey<String>('manga_chapter_drawer_jump_bottom'),
      icon: FushiIcons.alignBottom,
      label: t.manga_chapter_list_jump_bottom,
      onPressed: () => _jumpTo(false),
    ),
  ];

  Widget _header(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color foreground = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) {
          final List<FushiToolbarItem> actions = _actions;
          // 预算 = 整行 - 关闭钮 - 标题保底。
          final int visible = _fit.visibleFor(
            groups: <List<FushiToolbarItem>>[actions],
            budget: box.maxWidth - 48 - _kDrawerTitleMinWidth,
          );
          final List<FushiToolbarItem> shown = actions.sublist(0, visible);
          final List<FushiToolbarItem> folded = actions.sublist(visible);
          return Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  t.mihon_chapters_title,
                  style: theme.textTheme.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              for (final FushiToolbarItem item in shown)
                FushiToolbarButton(
                  item: item,
                  foreground: foreground,
                  selectedContainer: theme.colorScheme.secondaryContainer,
                  selectedForeground: theme.colorScheme.onSecondaryContainer,
                ),
              FushiToolbarOverflowButton(items: folded, foreground: foreground),
              FushiIconButtonControl(
                key: const ValueKey<String>('manga_chapter_drawer_close'),
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                onPressed: widget.onClose,
                icon: const FushiIcon(FushiIcons.close),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey<String>('manga_reader_chapter_drawer'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _header(context),
        const FushiDividerControl(height: 1),
        Expanded(
          child: MangaChapterFastScrollbar(
            controller: _scroll,
            thumbVisibility: true,
            // 进场窗口：开抽屉时首屏几行错峰淡入，之后（含跳到几百话外的当前章）
            // 直接显示，不让滚出来的每一行都再淡入一次。换序重开窗口。
            child: FushiEntranceScope(
              replayKey: _newestFirst,
              child: CustomScrollView(
                controller: _scroll,
                slivers: <Widget>[
                  MangaChapterList(
                    sliver: true,
                    rowsKey: _rowsKey,
                    entry: widget.entry,
                    states: widget.states,
                    newestFirst: _newestFirst,
                    unreadOnly: false,
                    currentChapterKey: widget.currentChapterKey,
                    currentChapterAnchorKey: _currentAnchor,
                    downloadedChapterKeys: widget.downloadedChapterKeys,
                    showHeader: false,
                    onChapterTap: widget.onChapterTap,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
