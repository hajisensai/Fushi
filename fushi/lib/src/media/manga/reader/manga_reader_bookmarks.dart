/// 漫画按页书签：纯逻辑（当前屏是否有书签、书签 → 跳转目标）与书签面板。
///
/// 存储复用 `Bookmarks` 表（[BookmarkRepository]），按页记：
///  * `sectionIndex` = 0 起页码（双页时是当前 spread 第一页）；
///  * `normCharOffset` = 0、`charOffset` = -1（漫画没有字符位置）；
///  * `chapterKey` = 在线章稳定键（书架在线条目）；本地卷为 null；
///  * `label` = 本地「第 N 页」/ 在线章名（没有上下文的列表——如桌面 CLI——直接显示它）。
library;

import 'dart:async';

import 'package:fushi_audio/fushi_audio.dart' show Bookmark;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/reader/reader_desktop_chrome.dart'
    show ReaderSideSheet, ReaderSideSheetSide, showReaderSideSheet;
import 'package:fushi/src/reader/reader_panel_chrome_kit.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 当前屏上的书签：章键相同（都为 null 也算同章）且页码落在当前可见页半开区间
/// `[startPage, endPage)` 内（双页 spread 两页都算）。没有返回 null。
Bookmark? mangaBookmarkOnScreen(
  List<Bookmark> bookmarks, {
  required String? chapterKey,
  required int startPage,
  required int endPage,
}) {
  for (final Bookmark bookmark in bookmarks) {
    if (bookmark.chapterKey != chapterKey) continue;
    if (bookmark.sectionIndex >= startPage && bookmark.sectionIndex < endPage) {
      return bookmark;
    }
  }
  return null;
}

/// 书签跳转的去向。
enum MangaBookmarkJumpKind {
  /// 当前章（或本地卷）内跳页。
  currentChapter,

  /// 换到另一章再落页。
  otherChapter,

  /// 书签所在章已不在章节列表里：提示，不跳。
  chapterMissing,
}

/// [resolveMangaBookmarkJump] 的结果：去向 + 0 起页码 + 目标章下标（只在
/// [MangaBookmarkJumpKind.otherChapter] 时非空）。
typedef MangaBookmarkJump = ({
  MangaBookmarkJumpKind kind,
  int page,
  int? chapterIndex,
});

/// 书签 → 跳转目标（纯函数）。
///
///  * 书签没有章键（本地卷）或章键等于当前章 → 当前章内跳到 `sectionIndex`；
///  * 否则在 [chapterKeys]（书架在线条目的章键列表；本地卷传 null）里按键找章下标：
///    找到 → 换章并落页；找不到 / 不是在线条目 → [MangaBookmarkJumpKind.chapterMissing]。
MangaBookmarkJump resolveMangaBookmarkJump(
  Bookmark bookmark, {
  required String? currentChapterKey,
  required List<String>? chapterKeys,
}) {
  final int page = bookmark.sectionIndex < 0 ? 0 : bookmark.sectionIndex;
  final String? key = bookmark.chapterKey;
  if (key == null || key == currentChapterKey) {
    return (
      kind: MangaBookmarkJumpKind.currentChapter,
      page: page,
      chapterIndex: null,
    );
  }
  final int index = chapterKeys?.indexOf(key) ?? -1;
  if (index < 0) {
    return (
      kind: MangaBookmarkJumpKind.chapterMissing,
      page: page,
      chapterIndex: null,
    );
  }
  return (
    kind: MangaBookmarkJumpKind.otherChapter,
    page: page,
    chapterIndex: index,
  );
}

/// 书签行标题：在线章 = 「章名 · 第 N 页」，本地卷 = 「第 N 页」。[chapterName] 是
/// 按章键查到的当前章名（查不到时用书签存下的 label 当章名）。
String mangaBookmarkTitle(Bookmark bookmark, {String? chapterName}) {
  final String page = '${bookmark.sectionIndex + 1}';
  if (bookmark.chapterKey == null) {
    return t.reader_bookmark_page_label(page: page);
  }
  final String chapter = (chapterName ?? bookmark.label).trim();
  return chapter.isEmpty
      ? t.reader_bookmark_page_label(page: page)
      : t.reader_bookmark_chapter_page_label(chapter: chapter, page: page);
}

/// 新书签存进 `label` 的文案：本地卷「第 N 页」，在线章 = 章名。
String mangaBookmarkStoredLabel({required int page, String? chapterName}) {
  final String? chapter = chapterName?.trim();
  if (chapter != null && chapter.isNotEmpty) return chapter;
  return t.reader_bookmark_page_label(page: '${page + 1}');
}

/// 书签面板（右侧侧板 / 窄窗底部 sheet）：页头按钮切换当前屏书签，列表点击跳转、
/// 行尾删除。宿主负责读写库；面板每次改动后重读 [load]。
Future<void> showMangaBookmarkSheet({
  required BuildContext context,
  required Future<List<Bookmark>> Function() load,
  required Bookmark? Function(List<Bookmark> bookmarks) onScreen,
  required Future<void> Function(Bookmark? existing) toggleCurrent,
  required Future<void> Function(Bookmark bookmark) onDelete,
  required void Function(Bookmark bookmark) onSelect,
  required String Function(Bookmark bookmark) titleOf,
  required ImageProvider? Function(Bookmark bookmark) thumbnailOf,
}) => showReaderSideSheet<void>(
  context: context,
  side: ReaderSideSheetSide.right,
  bottomSheetWhenCompact: true,
  builder: (BuildContext sheetContext) => MangaBookmarkPanel(
    load: load,
    onScreen: onScreen,
    toggleCurrent: toggleCurrent,
    onDelete: onDelete,
    onSelect: (Bookmark bookmark) {
      Navigator.of(sheetContext).pop();
      onSelect(bookmark);
    },
    onClose: () => Navigator.of(sheetContext).maybePop(),
    titleOf: titleOf,
    thumbnailOf: thumbnailOf,
  ),
);

class MangaBookmarkPanel extends StatefulWidget {
  const MangaBookmarkPanel({
    super.key,
    required this.load,
    required this.onScreen,
    required this.toggleCurrent,
    required this.onDelete,
    required this.onSelect,
    required this.onClose,
    required this.titleOf,
    required this.thumbnailOf,
  });

  final Future<List<Bookmark>> Function() load;
  final Bookmark? Function(List<Bookmark> bookmarks) onScreen;
  final Future<void> Function(Bookmark? existing) toggleCurrent;
  final Future<void> Function(Bookmark bookmark) onDelete;
  final void Function(Bookmark bookmark) onSelect;
  final VoidCallback onClose;
  final String Function(Bookmark bookmark) titleOf;
  final ImageProvider? Function(Bookmark bookmark) thumbnailOf;

  @override
  State<MangaBookmarkPanel> createState() => _MangaBookmarkPanelState();
}

class _MangaBookmarkPanelState extends State<MangaBookmarkPanel> {
  List<Bookmark>? _items;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    final List<Bookmark> items = await widget.load();
    if (!mounted) return;
    setState(() => _items = items);
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      await _reload();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _createdAt(BuildContext context, DateTime at) {
    final MaterialLocalizations l10n = MaterialLocalizations.of(context);
    return '${l10n.formatShortDate(at)} '
        '${l10n.formatTimeOfDay(TimeOfDay.fromDateTime(at))}';
  }

  @override
  Widget build(BuildContext context) {
    final List<Bookmark>? items = _items;
    final Bookmark? here = items == null ? null : widget.onScreen(items);
    final Widget toggle = FushiFilledButton.tonalIcon(
      key: const ValueKey<String>('manga_bookmark_toggle'),
      onPressed: items == null || _busy
          ? null
          : () => unawaited(_run(() => widget.toggleCurrent(here))),
      icon: FushiIcon(
        here == null ? FushiIcons.bookmarkAdd : FushiIcons.bookmark,
        size: 18,
      ),
      label: Text(
        here == null ? t.reader_bookmark_add : t.reader_bookmark_remove,
      ),
    );
    final Widget body;
    if (items == null) {
      body = const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: CircularProgressIndicator()),
      );
    } else if (items.isEmpty) {
      body = ReaderPanelEmpty(
        icon: FushiIcons.bookmark,
        message: t.reader_bookmarks_empty,
      );
    } else {
      body = FushiEntranceScope(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (int i = 0; i < items.length; i++)
              FushiStaggeredEntrance(
                index: i,
                child: _BookmarkRow(
                  key: ValueKey<String>(
                    'manga_bookmark_${items[i].id ?? items[i].createdAt.millisecondsSinceEpoch}',
                  ),
                  title: widget.titleOf(items[i]),
                  subtitle: _createdAt(context, items[i].createdAt),
                  thumbnail: widget.thumbnailOf(items[i]),
                  current: identical(items[i], here),
                  onTap: () => widget.onSelect(items[i]),
                  onDelete: _busy
                      ? null
                      : () => unawaited(_run(() => widget.onDelete(items[i]))),
                ),
              ),
          ],
        ),
      );
    }
    return ReaderSideSheet(
      title: t.manga_reader_bookmarks,
      icon: FushiIcons.bookmark,
      onClose: widget.onClose,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Align(alignment: AlignmentDirectional.centerStart, child: toggle),
          const SizedBox(height: 12),
          AnimatedSwitcher(
            duration: fushiMotionDuration(context, FushiMotion.medium),
            switchInCurve: FushiMotion.enter,
            switchOutCurve: FushiMotion.exit,
            child: KeyedSubtree(
              key: ValueKey<String>(
                items == null ? 'loading' : (items.isEmpty ? 'empty' : 'list'),
              ),
              child: body,
            ),
          ),
        ],
      ),
    );
  }
}

/// 一行书签：缩略图（取不到画书签图标）+ 标题 / 创建时间 + 删除。当前屏的书签
/// 行按列表选中态高亮。
class _BookmarkRow extends StatelessWidget {
  const _BookmarkRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.thumbnail,
    required this.current,
    required this.onTap,
    required this.onDelete,
  });

  final String title;
  final String subtitle;
  final ImageProvider? thumbnail;
  final bool current;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final ImageProvider? image = thumbnail;
    final Widget leading = ClipRRect(
      borderRadius: BorderRadius.all(
        Radius.circular(readerPanelSmallRadius(context)),
      ),
      child: SizedBox(
        width: 44,
        height: 60,
        child: image == null
            ? ColoredBox(
                color: scheme.surfaceContainerHighest,
                child: Center(
                  child: FushiIcon(
                    FushiIcons.bookmark,
                    size: 22,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              )
            : Image(
                image: image,
                fit: BoxFit.cover,
                errorBuilder: (BuildContext _, Object _, StackTrace? _) =>
                    ColoredBox(color: scheme.surfaceContainerHighest),
              ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: FushiListItem(
        leading: leading,
        title: Text(title),
        titleMaxLines: 2,
        subtitle: Text(subtitle),
        selected: current,
        onTap: onTap,
        trailing: FushiIconButtonControl(
          tooltip: t.reader_bookmark_delete,
          icon: const FushiIcon(FushiIcons.delete),
          onPressed: onDelete,
        ),
      ),
    );
  }
}
