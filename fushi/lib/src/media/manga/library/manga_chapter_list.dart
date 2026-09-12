import 'package:flutter/material.dart';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/utils.dart';

/// 一章在「先下载再读」语义下的状态（设计稿 2026-09-12 §5）。
enum _ChapterDownloadState {
  notDownloaded,
  queued,
  downloading,
  downloaded,
  failed,
}

/// 章节列表。
///
/// 作品页和阅读器里的「章节」弹层用**同一个** widget：两处对「已读怎么显示、
/// 当前章怎么高亮、排序默认哪个方向、下载状态怎么标」的答案必须一致，各写一份
/// 必然漂移。
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
    this.downloadedChapterKeys = const <String>{},
    this.jobsByChapterKey = const <String, MangaDownloadJobRow>{},
    this.onDownload,
    this.onDeleteDownload,
    this.onRetryDownload,
    this.onOcr,
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

  /// 下载状态位（设计稿 2026-09-12 §5）。两份输入合成一个状态：
  /// [downloadedChapterKeys] 是磁盘判据（`isChapterDownloaded`）的结果、
  /// [jobsByChapterKey] 是任务表里的行；下载中 / 排队 / 失败看任务行，已下载看
  /// 磁盘。默认都空 = 每章都显示成「未下载」（阅读器内的章节选择器只给磁盘那份）。
  final Set<String> downloadedChapterKeys;
  final Map<String, MangaDownloadJobRow> jobsByChapterKey;

  /// 溢出菜单里的下载动作；null = 不出现对应项。
  final void Function(OnlineMangaChapter chapter)? onDownload;
  final void Function(OnlineMangaChapter chapter)? onDeleteDownload;
  final void Function(OnlineMangaChapter chapter)? onRetryDownload;

  /// 「识别本章」（只对已下载的章出现）；null = 不出现。
  final void Function(OnlineMangaChapter chapter)? onOcr;

  /// 一章的下载状态：磁盘判据优先（真正决定能不能读），其次看任务行。
  _ChapterDownloadState _downloadStateOf(OnlineMangaChapter chapter) {
    if (downloadedChapterKeys.contains(chapter.key)) {
      return _ChapterDownloadState.downloaded;
    }
    final MangaDownloadJobRow? job = jobsByChapterKey[chapter.key];
    switch (job?.status) {
      case MangaDownloadJobStatus.queued:
        return _ChapterDownloadState.queued;
      case MangaDownloadJobStatus.running:
        return _ChapterDownloadState.downloading;
      case MangaDownloadJobStatus.failed:
        return _ChapterDownloadState.failed;
      default:
        return _ChapterDownloadState.notDownloaded;
    }
  }

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
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiCard(
      // 相邻卡片外边距为 0 时，10px 圆角在行间漏出一串页面底色缺口，长章节
      // 表看着像锯齿。章节动辄几百条，间距取 gap 的一半就够分辨。
      margin: EdgeInsets.only(bottom: tokens.spacing.gap / 2),
      // 当前章此前只有 trailing 一个播放图标，滚动中根本扫不到；整行底色是
      // 唯一能一眼定位的信号。
      selected: current,
      padding: EdgeInsets.zero,
      child: FushiListItem(
        // 章节行只有「标题 + 一行元信息」，standard 密度（56 下限 + 上下 12）
        // 是给两行副标题留的余量，几百条累计出的空白比内容还多。
        density: FushiListDensity.compact,
        padding: EdgeInsets.symmetric(
          horizontal: tokens.spacing.rowHorizontal - 4,
          vertical: tokens.spacing.gap / 2,
        ),
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
          size: 20,
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
    final MangaDownloadJobRow? job = jobsByChapterKey[chapter.key];
    final _ChapterDownloadState download = _downloadStateOf(chapter);
    final List<String> parts = <String>[
      if (chapter.scanlator?.isNotEmpty == true) chapter.scanlator!,
      if (chapter.uploadedAt != null) _formatDate(chapter.uploadedAt!),
      switch (download) {
        _ChapterDownloadState.queued => t.manga_chapter_download_status_queued,
        _ChapterDownloadState.downloading =>
          t.manga_chapter_download_status_downloading(
            done: '${job?.pagesDone ?? 0}',
            total: '${job?.pagesTotal ?? 0}',
          ),
        _ChapterDownloadState.downloaded =>
          t.manga_chapter_download_status_downloaded,
        // 失败原因原样露出来：扩展抛的 `Log in via WebView ...` 之类正是用户要
        // 知道的下一步；只写「下载失败」等于把答案藏起来（BUG-2479）。
        _ChapterDownloadState.failed => _failedLabel(job?.lastError),
        _ChapterDownloadState.notDownloaded => t.manga_chapter_not_downloaded,
      },
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
    return Text(
      parts.join(' · '),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  static String _failedLabel(String? lastError) {
    final String reason = lastError?.trim() ?? '';
    if (reason.isEmpty) return t.manga_chapter_download_status_failed;
    return '${t.manga_chapter_download_status_failed} · $reason';
  }

  Widget _buildTrailing(
    BuildContext context,
    OnlineMangaChapter chapter,
    bool current,
  ) {
    final ThemeData theme = Theme.of(context);
    final _ChapterDownloadState download = _downloadStateOf(chapter);
    final bool hasMenu =
        onToggleRead != null ||
        onMarkUpToRead != null ||
        onDownload != null ||
        onDeleteDownload != null ||
        onRetryDownload != null ||
        onOcr != null;
    final List<Widget> children = <Widget>[
      _buildDownloadIndicator(context, download),
      if (current)
        Icon(Icons.play_circle_outline, color: theme.colorScheme.primary),
      if (hasMenu)
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
            if (onDownload != null &&
                download == _ChapterDownloadState.notDownloaded)
              FushiPopupMenuItem<String>(
                value: 'download',
                label: t.manga_chapter_download_action,
              ),
            if (onRetryDownload != null &&
                download == _ChapterDownloadState.failed)
              FushiPopupMenuItem<String>(
                value: 'retry-download',
                label: t.manga_chapter_download_retry_action,
              ),
            if (onOcr != null && download == _ChapterDownloadState.downloaded)
              FushiPopupMenuItem<String>(
                key: const ValueKey<String>('manga_chapter_ocr'),
                value: 'ocr',
                label: t.manga_chapter_ocr_action,
              ),
            if (onDeleteDownload != null &&
                download == _ChapterDownloadState.downloaded)
              FushiPopupMenuItem<String>(
                value: 'delete-download',
                label: t.manga_chapter_download_delete_action,
              ),
          ],
          onSelected: (String value) {
            switch (value) {
              case 'toggle-read':
                onToggleRead?.call(chapter);
              case 'mark-up-to':
                onMarkUpToRead?.call(chapter);
              case 'download':
                onDownload?.call(chapter);
              case 'retry-download':
                onRetryDownload?.call(chapter);
              case 'delete-download':
                onDeleteDownload?.call(chapter);
              case 'ocr':
                onOcr?.call(chapter);
            }
          },
        ),
    ];
    if (children.isEmpty) return const Icon(Icons.chevron_right);
    return Row(mainAxisSize: MainAxisSize.min, children: children);
  }

  /// 行尾的下载状态位：图标一眼能扫到，文字在副标题里。
  Widget _buildDownloadIndicator(
    BuildContext context,
    _ChapterDownloadState download,
  ) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Widget icon = switch (download) {
      _ChapterDownloadState.downloaded => Icon(
        Icons.download_done,
        size: 20,
        color: scheme.primary,
      ),
      _ChapterDownloadState.queued => Icon(
        Icons.schedule,
        size: 20,
        color: scheme.onSurfaceVariant,
      ),
      _ChapterDownloadState.downloading => const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      _ChapterDownloadState.failed => Icon(
        Icons.error_outline,
        size: 20,
        color: scheme.error,
      ),
      _ChapterDownloadState.notDownloaded => Icon(
        Icons.cloud_outlined,
        size: 20,
        color: scheme.onSurfaceVariant,
      ),
    };
    return Padding(
      key: ValueKey<String>('manga_chapter_download_${download.name}'),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: icon,
    );
  }

  static String _formatDate(int millis) {
    final DateTime date = DateTime.fromMillisecondsSinceEpoch(millis);
    final String month = date.month.toString().padLeft(2, '0');
    final String day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }
}
