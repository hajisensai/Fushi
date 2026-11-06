import 'package:flutter/foundation.dart' show immutable;

/// 漫画阅读器「跳转回退」历史栈里的一个位置（[JumpHistory] 的元素）。
///
/// 章用**章 key** 而不是下标：阅读期间章节列表可能刷新（新话插入 / 排序变化），
/// 下标会漂，key 不会。本地卷（一卷一条目、无章节）[chapterKey] 为 null。
/// [page] 是 0-based 页号（双页 spread 记首页，落地时按当时的 spread 表重新折算，
/// 换了单双页偏好也落得对）；[fraction] 是 webtoon 连续模式的页内归一化偏移，
/// 翻页模式恒 0。[pageCount] 只用于位置文案。
@immutable
class MangaJumpPoint {
  const MangaJumpPoint({
    required this.chapterKey,
    required this.page,
    required this.pageCount,
    this.fraction = 0,
  });

  final String? chapterKey;
  final int page;
  final int pageCount;
  final double fraction;

  /// 同一处 = 同章同页（页内偏移不算：连点同一个入口不重复压栈）。
  static bool isSamePlace(MangaJumpPoint a, MangaJumpPoint b) =>
      a.chapterKey == b.chapterKey && a.page == b.page;

  @override
  String toString() =>
      'MangaJumpPoint($chapterKey, page: $page/$pageCount, '
      'fraction: $fraction)';
}

/// 位置文案里章名的最长字数，再长截断加省略号（tooltip / 面板行不折行）。
const int kMangaJumpLabelChapterMaxChars = 16;

/// 跳转落点的位置文案（语言无关）：
///
///  * 与当前同章（或本地卷）：`12 / 40`；
///  * 别的章：`<章名> · 12 / 40`，章名取不到（空）时只给页码。
///
/// [alwaysShowChapter]：同章也带章名（「跳转记录」面板，各行与当前位置同一格式，
/// 一眼看出哪几条在同一话）；本地卷 / 章名取不到时照旧只给页码。顶栏图标的
/// tooltip 用默认的短格式。
String mangaJumpPointLabel({
  required MangaJumpPoint point,
  required String? currentChapterKey,
  required String? chapterName,
  bool alwaysShowChapter = false,
}) {
  final String pages = point.pageCount > 0
      ? '${point.page + 1} / ${point.pageCount}'
      : '${point.page + 1}';
  final String name = chapterName?.trim() ?? '';
  if (point.chapterKey == null ||
      (!alwaysShowChapter && point.chapterKey == currentChapterKey) ||
      name.isEmpty) {
    return pages;
  }
  final List<int> runes = name.runes.toList();
  final String shown = runes.length > kMangaJumpLabelChapterMaxChars
      ? '${String.fromCharCodes(runes.take(kMangaJumpLabelChapterMaxChars))}…'
      : name;
  return '$shown · $pages';
}
