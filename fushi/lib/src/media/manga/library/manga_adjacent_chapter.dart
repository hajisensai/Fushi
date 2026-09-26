import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';

/// 章节列表里「下一话」的下标偏移。
///
/// 源按**新→旧**返回（列表 0 = 最新一话），所以「读下一话」是下标 **-1**。
/// 这个方向反直觉，所以收成一个具名常量，阅读器换章与预下载共用。
const int kMangaNextChapterStep = -1;

/// 阅读顺序上与第 [currentIndex] 章相邻的章（[forward] = 往后读），返回它在
/// [chapters] 里的下标；没有可去的章返回 null。
///
/// 对齐 Mihon `ReaderViewModel` 的章节过滤：
/// * [skipRead]：已读章（[readChapterKeys]）不作为落点；当前章本身不受影响。
/// * [skipDuplicate]：与当前章**同话数**的章（多个汉化组的同一话）不作为落点；
///   下一话若有多个版本，优先与当前章同一汉化组的那个，否则取阅读顺序上最先
///   遇到的那个。话数未知（null / 负数）的章不参与去重。
///
/// [chapters] 必须是源顺序（新→旧），与 [OnlineMangaLibraryEntry.chapters] 一致。
int? resolveAdjacentMangaChapter({
  required List<OnlineMangaChapter> chapters,
  required int currentIndex,
  required bool forward,
  Set<String> readChapterKeys = const <String>{},
  bool skipRead = false,
  bool skipDuplicate = false,
}) {
  if (currentIndex < 0 || currentIndex >= chapters.length) return null;
  final int step = forward ? kMangaNextChapterStep : -kMangaNextChapterStep;
  final OnlineMangaChapter current = chapters[currentIndex];
  final double? currentNumber = _knownNumber(current);

  bool eligible(OnlineMangaChapter chapter) {
    if (skipRead && readChapterKeys.contains(chapter.key)) return false;
    if (skipDuplicate &&
        currentNumber != null &&
        _knownNumber(chapter) == currentNumber) {
      return false;
    }
    return true;
  }

  for (int i = currentIndex + step; i >= 0 && i < chapters.length; i += step) {
    final OnlineMangaChapter candidate = chapters[i];
    if (!eligible(candidate)) continue;
    final double? number = _knownNumber(candidate);
    if (!skipDuplicate || number == null) return i;
    // 同一话的多个版本：优先当前汉化组，否则就是第一个遇到的 [i]。
    final String? scanlator = _normalizedScanlator(current);
    if (scanlator == null || _normalizedScanlator(candidate) == scanlator) {
      return i;
    }
    for (int j = i + step; j >= 0 && j < chapters.length; j += step) {
      final OnlineMangaChapter sibling = chapters[j];
      if (_knownNumber(sibling) != number) continue;
      if (eligible(sibling) && _normalizedScanlator(sibling) == scanlator) {
        return j;
      }
    }
    return i;
  }
  return null;
}

/// 预下载下一话的时机：读过当前章约 2/3 之后，或者当前章很短（一进来就下）。
///
/// [currentPage] 从 0 数；[pageCount] 是本章总页数。
bool shouldPrefetchNextMangaChapter({
  required int currentPage,
  required int pageCount,
}) {
  if (pageCount <= 0 || currentPage < 0) return false;
  if (pageCount <= kMangaShortChapterPageCount) return true;
  return (currentPage + 1) * 3 >= pageCount * 2;
}

/// 不超过这么多页的章一打开就预下载下一话：读完它只要几十秒，等到 2/3 处再排
/// 队多半赶不上。
const int kMangaShortChapterPageCount = 8;

double? _knownNumber(OnlineMangaChapter chapter) {
  final double? number = chapter.number;
  if (number == null || !number.isFinite || number < 0) return null;
  return number;
}

String? _normalizedScanlator(OnlineMangaChapter chapter) {
  final String? value = chapter.scanlator?.trim();
  return value == null || value.isEmpty ? null : value;
}
