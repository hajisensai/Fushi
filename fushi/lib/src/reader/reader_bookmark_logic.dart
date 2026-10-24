/// 小说（EPUB）阅读器书签的纯逻辑：「当前页有没有书签」判据、书签 → 跳转参数换算、
/// 书签行副标题。页面（`reader_fushi/chrome.part.dart`）与导航面板
/// （`reader_quick_settings_sheet.dart`）只消费这里的结论，不各自写判据。
library;

import 'package:fushi_audio/fushi_audio.dart';

/// 当前页（分页模式的一页 / 连续模式的视口 / 歌词模式的当前句）在章内的字符区间。
///
/// [charStart] / [charEnd] 与 `ReaderPosition.charOffset` 同计量（章内学习单位偏移，
/// `fushiProgressDetails` 第三 / 四段），区间左闭右开；[charEnd] < 0 表示 shell 没给
/// 终点，按单点 `[charStart, charStart + 1)` 处理。[chapterCharCount] 是该章学习单位
/// 总数（`_chapterCharCounts[section]`），只用来把旧书签的 0-10000 分数折成偏移；
/// 未知传 0。
typedef ReaderBookmarkPageRange = ({
  int section,
  int charStart,
  int charEnd,
  int chapterCharCount,
});

/// 书签的跳转参数：[charOffset] >= 0 走精确字符锚（`restoreToCharOffset` /
/// 导航原子恢复的 charOffset），否则按章内分数 [progress]（`restoreProgress`）。
typedef ReaderBookmarkJump = ({int section, int charOffset, double progress});

/// 书签在章内的字符偏移：有持久化精确偏移就用它；旧书签（`charOffset < 0`）用
/// `normCharOffset`（0-10000 章内分数）乘章字数近似；章字数未知时返回 null（判不了）。
int? readerBookmarkEffectiveOffset(Bookmark bookmark, int chapterCharCount) {
  if (bookmark.charOffset >= 0) return bookmark.charOffset;
  if (chapterCharCount <= 0) return null;
  final double fraction = (bookmark.normCharOffset / 10000.0).clamp(0.0, 1.0);
  return (fraction * chapterCharCount).round();
}

/// [bookmarks] 里落在当前页 [page] 上的第一条书签；没有返回 null。
///
/// 判据：同章，且书签的**精确**偏移落在 `[charStart, charEnd)` 内。旧书签（v125 前、
/// 无精确偏移）一律不算「在当前页」：0-10000 分数与学习单位字数不一定同口径，折算
/// 后可能落到邻页，而「当前页有书签」的后果是按钮变「移除」——误判会删掉别页的书签。
/// 旧书签照样列在列表里，可以从列表删除 / 跳转。
Bookmark? readerBookmarkOnPage(
  List<Bookmark> bookmarks,
  ReaderBookmarkPageRange? page,
) {
  if (page == null || page.charStart < 0) return null;
  final int start = page.charStart;
  final int end = page.charEnd > start ? page.charEnd : start + 1;
  for (final Bookmark bookmark in bookmarks) {
    if (bookmark.sectionIndex != page.section) continue;
    final int offset = bookmark.charOffset;
    if (offset < 0) continue;
    if (offset >= start && offset < end) return bookmark;
  }
  return null;
}

/// 书签 → 跳转参数（见 [ReaderBookmarkJump]）。
ReaderBookmarkJump readerBookmarkJumpFor(Bookmark bookmark) {
  if (bookmark.charOffset >= 0) {
    return (
      section: bookmark.sectionIndex,
      charOffset: bookmark.charOffset,
      progress: 0.0,
    );
  }
  return (
    section: bookmark.sectionIndex,
    charOffset: -1,
    progress: (bookmark.normCharOffset / 10000.0).clamp(0.0, 1.0),
  );
}

/// 书签按创建时间倒序（新的在上），不改入参。
List<Bookmark> readerBookmarksNewestFirst(Iterable<Bookmark> bookmarks) =>
    List<Bookmark>.of(bookmarks)
      ..sort((Bookmark a, Bookmark b) => b.createdAt.compareTo(a.createdAt));
