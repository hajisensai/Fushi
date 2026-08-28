import 'package:flutter/material.dart';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/utils.dart';

/// 章节列表。
///
/// 作品页和阅读器里的「章节」弹层用**同一个** widget：两处对「已读怎么显示、
/// 当前章怎么高亮、排序默认哪个方向」的答案必须一致，各写一份必然漂移。
class MangaChapterList extends StatelessWidget {
  const MangaChapterList({
    required this.entry,
    required this.states,
    required this.newestFirst,
    required this.unreadOnly,
    required this.onChapterTap,
    super.key,
    this.currentChapterKey,
    this.onSortToggled,
    this.onUnreadOnlyToggled,
    this.onToggleRead,
    this.onMarkUpToRead,
    this.showHeader = true,
  });

  final OnlineMangaLibraryEntry? entry;
  final Map<String, MangaChapterStateRow> states;

  /// 源按新→旧返回，所以 `true` = 保持源顺序，`false` = 反转成第 1 话在前。
  final bool newestFirst;
  final bool unreadOnly;
  final String? currentChapterKey;

  final void Function(OnlineMangaChapter chapter) onChapterTap;
  final VoidCallback? onSortToggled;
  final VoidCallback? onUnreadOnlyToggled;
  final void Function(OnlineMangaChapter chapter)? onToggleRead;
  final void Function(OnlineMangaChapter chapter)? onMarkUpToRead;
  final bool showHeader;

  @override
  Widget build(BuildContext context) {
    final OnlineMangaLibraryEntry? entry = this.entry;
    final List<OnlineMangaChapter> chapters =
        entry?.chapters ?? const <OnlineMangaChapter>[];
    final List<OnlineMangaChapter> visible = _visibleChapters(chapters);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (showHeader) ...<Widget>[
          _buildHeader(context, chapters.length),
          const SizedBox(height: 8),
        ],
        if (chapters.isEmpty)
          _buildEmpty(context, t.manga_series_no_chapters)
        else if (visible.isEmpty)
          _buildEmpty(context, t.manga_series_all_read)
        else
          for (final OnlineMangaChapter chapter in visible)
            _buildRow(context, chapter),
      ],
    );
  }

  List<OnlineMangaChapter> _visibleChapters(List<OnlineMangaChapter> chapters) {
    final Iterable<OnlineMangaChapter> filtered = unreadOnly
        ? chapters.where(
            (OnlineMangaChapter chapter) => states[chapter.key]?.readAt == null,
          )
        : chapters;
    final List<OnlineMangaChapter> ordered = filtered.toList(growable: false);
    if (newestFirst) return ordered;
    return ordered.reversed.toList(growable: false);
  }

  Widget _buildHeader(BuildContext context, int total) {
    final ThemeData theme = Theme.of(context);
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            '${t.mihon_chapters_title}  $total',
            style: theme.textTheme.titleLarge,
          ),
        ),
        if (onSortToggled != null)
          TextButton.icon(
            key: const ValueKey<String>('manga_chapter_sort'),
            onPressed: onSortToggled,
            icon: Icon(newestFirst ? Icons.arrow_downward : Icons.arrow_upward),
            label: Text(
              newestFirst
                  ? t.manga_series_sort_newest
                  : t.manga_series_sort_oldest,
            ),
          ),
        if (onUnreadOnlyToggled != null)
          FushiSelectableChip(
            key: const ValueKey<String>('manga_chapter_unread_only'),
            label: t.manga_series_unread_only,
            selected: unreadOnly,
            onSelected: (_) => onUnreadOnlyToggled!(),
          ),
      ],
    );
  }

  Widget _buildEmpty(BuildContext context, String message) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 24),
    child: Center(
      child: Text(message, style: Theme.of(context).textTheme.bodyMedium),
    ),
  );

  Widget _buildRow(BuildContext context, OnlineMangaChapter chapter) {
    final ThemeData theme = Theme.of(context);
    final MangaChapterStateRow? state = states[chapter.key];
    final bool read = state?.readAt != null;
    final bool current = chapter.key == currentChapterKey;
    // 「读了一半」= 有状态行、没读完、且真的翻过页。开了一下就退出（lastPage 0）
    // 不算进度，显示成「读到 1/24 页」只会误导。
    final bool partial = !read && state != null && state.lastPage > 0;
    return FushiCard(
      padding: EdgeInsets.zero,
      child: FushiListItem(
        title: Text(
          chapter.name,
          style: read
              ? theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                )
              : null,
        ),
        subtitle: _buildSubtitle(context, chapter, state, partial),
        leading: Icon(
          read
              ? Icons.check_circle_outline
              : partial
              ? Icons.incomplete_circle
              : Icons.circle_outlined,
          color: read
              ? theme.colorScheme.onSurfaceVariant
              : theme.colorScheme.primary,
        ),
        trailing: _buildTrailing(context, chapter, current),
        onTap: () => onChapterTap(chapter),
      ),
    );
  }

  Widget? _buildSubtitle(
    BuildContext context,
    OnlineMangaChapter chapter,
    MangaChapterStateRow? state,
    bool partial,
  ) {
    final List<String> parts = <String>[
      if (chapter.scanlator?.isNotEmpty == true) chapter.scanlator!,
      if (chapter.uploadedAt != null) _formatDate(chapter.uploadedAt!),
      if (partial)
        state!.pageCount != null
            ? t.manga_series_read_progress(
                page: '${state.lastPage + 1}',
                total: '${state.pageCount}',
              )
            : t.manga_series_read_progress_partial(
                page: '${state.lastPage + 1}',
              ),
    ];
    if (parts.isEmpty) return null;
    return Text(parts.join(' · '));
  }

  Widget _buildTrailing(
    BuildContext context,
    OnlineMangaChapter chapter,
    bool current,
  ) {
    final List<Widget> children = <Widget>[
      if (current)
        Icon(
          Icons.play_circle_outline,
          color: Theme.of(context).colorScheme.primary,
        ),
      if (onToggleRead != null || onMarkUpToRead != null)
        FushiOverflowMenu<String>(
          items: <PopupMenuEntry<String>>[
            if (onToggleRead != null)
              FushiPopupMenuItem<String>(
                value: 'toggle-read',
                label: states[chapter.key]?.readAt != null
                    ? t.manga_series_mark_unread
                    : t.manga_series_mark_read,
              ),
            if (onMarkUpToRead != null)
              FushiPopupMenuItem<String>(
                value: 'mark-up-to',
                label: t.manga_series_mark_previous_read,
              ),
          ],
          onSelected: (String value) {
            switch (value) {
              case 'toggle-read':
                onToggleRead?.call(chapter);
              case 'mark-up-to':
                onMarkUpToRead?.call(chapter);
            }
          },
        ),
    ];
    if (children.isEmpty) return const Icon(Icons.chevron_right);
    return Row(mainAxisSize: MainAxisSize.min, children: children);
  }

  static String _formatDate(int millis) {
    final DateTime date = DateTime.fromMillisecondsSinceEpoch(millis);
    final String month = date.month.toString().padLeft(2, '0');
    final String day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }
}
