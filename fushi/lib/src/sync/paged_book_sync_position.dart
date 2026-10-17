import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi_core/fushi_core.dart';

/// 页式书（漫画 / PDF）在同步链路里的位置口径。
///
/// 页式书的 `reader_positions.sectionIndex` 是 **0-based 页码**、`chaptersJson` 恒
/// `'[]'`（见 [BookFormat.isPagedImageBook]）。按 EPUB 章节字符表换算会恒得 0：
/// 对比弹窗两侧恒显 0.0%，云通道导出 `exploredCharCount=0`，导入又经
/// `fromExploredCharCount` 把页码重置成第 1 页。
///
/// 云通道 wire 仍是 ッツ 的 `TtuProgress`；页式书把 `exploredCharCount` 当
/// 0-based 页码用（ッツ 不认识漫画 / PDF，没有兼容面），`progress` 写全书分数。
/// 互联通道本就原样搬 `sectionIndex`，只需要显示口径。
bool isPagedSyncBook(EpubBookRow book) =>
    BookFormat.parseOrEpub(book.format).isPagedImageBook;

/// 本地页式书的总页数（`chapterCount`）。
///
/// 在线漫画返回 null：它的 `chapterCount` 写的是**章数**、`sectionIndex` 是**章内**
/// 页码，两者量纲不同（同 `ReaderFushiSource._onlineMangaProgress` 的说明），
/// 只能显示页码、折算不出全书分数。
int? pagedSyncPageCount(EpubBookRow book) {
  if (!isPagedSyncBook(book)) return null;
  if (OnlineMangaLibraryEntry.tryParse(book.sourceMetadata) != null) {
    return null;
  }
  return book.chapterCount > 0 ? book.chapterCount : null;
}

/// 页式书的全书分数：1-based 页序 ÷ 总页数（与书架进度同口径，读到最后一页 = 1.0）。
/// 总页数未知返回 null。
double? pagedProgressFraction({
  required int pageIndex,
  required int? pageCount,
}) {
  if (pageCount == null || pageCount <= 0) return null;
  return (pageIndex + 1).clamp(1, pageCount) / pageCount;
}

/// 远端 / 导入页码钳到本书的合法页区间；总页数未知只钳下界。
int clampPagedSyncPageIndex(int pageIndex, int? pageCount) {
  if (pageIndex < 0) return 0;
  if (pageCount != null && pageCount > 0 && pageIndex >= pageCount) {
    return pageCount - 1;
  }
  return pageIndex;
}
