/// Page pairing layout for spread (non-webtoon) manga.
enum MangaPageLayout {
  /// One page per entry.
  single,

  /// Two facing pages per entry (with optional solo cover / odd tail).
  double,
}

/// Runtime page-layout preference for spread reading (in-page menu, not
/// persisted; default [auto]).
enum MangaSpreadPreference {
  /// Follow the viewport: landscape shows two facing pages, portrait one.
  auto,

  /// Always one page per screen.
  single,

  /// Always two facing pages per screen.
  double,
}

extension MangaSpreadPreferenceKey on MangaSpreadPreference {
  String get key => name;

  static MangaSpreadPreference fromKey(String raw) {
    switch (raw) {
      case 'single':
        return MangaSpreadPreference.single;
      case 'double':
        return MangaSpreadPreference.double;
      case 'auto':
      default:
        return MangaSpreadPreference.auto;
    }
  }
}

/// Resolve the effective [MangaPageLayout] for a spread book from the user
/// [preference] and the current viewport orientation. Pure so the auto rule
/// (landscape → double, portrait → single) is unit-testable.
///
/// [bookPosture]：折叠屏书本姿态（竖向折痕半开 / 双屏铰链，见 `FushiFoldState`）。
/// 折痕天然就是两页之间的装订线，`auto` 下直接双页——内屏接近正方形时宽 > 高
/// 不一定成立，只看横竖会把半开的书摊成一页、页面正中压在折痕上。
MangaPageLayout resolveMangaPageLayout({
  required MangaSpreadPreference preference,
  required bool isLandscape,
  bool bookPosture = false,
}) {
  switch (preference) {
    case MangaSpreadPreference.single:
      return MangaPageLayout.single;
    case MangaSpreadPreference.double:
      return MangaPageLayout.double;
    case MangaSpreadPreference.auto:
      return isLandscape || bookPosture
          ? MangaPageLayout.double
          : MangaPageLayout.single;
  }
}

/// A single rendered unit of a spread book: one page (solo) or two facing
/// pages. Page indices are 0-based and ascending; RTL left/right ordering is
/// applied at render time, not here.
class MangaSpreadEntry {
  /// One or two ascending page indices belonging to this entry.
  const MangaSpreadEntry(this.pageIndices);

  /// The 0-based page indices in ascending order (length 1 or 2).
  final List<int> pageIndices;

  /// Whether this entry shows two facing pages.
  bool get isSpread => pageIndices.length == 2;

  @override
  String toString() => 'MangaSpreadEntry($pageIndices)';
}

/// 一页是否「宽页」：本身就是一张横跨两页的合并图（扉页 / 见开き）。
///
/// 判据是页图自身的长宽比 >= [ratioThreshold]（默认 1.0 = 横向即宽页）。纯函数，
/// 不解码图片——mokuro 产物已给出每页原始像素尺寸，不必为此读一遍图。
///
/// 宽度或高度非正（缺尺寸的在线页占位）一律判 false：宁可按普通页配对，也不要
/// 因为一条坏数据把整卷拆成单页。
bool isMangaWidePage({
  required double width,
  required double height,
  double ratioThreshold = 1.0,
}) {
  if (width <= 0 || height <= 0) return false;
  return width / height >= ratioThreshold;
}

/// Build the spread sequence for [pageCount] pages under [layout].
///
/// [MangaPageLayout.single] yields one entry per page. [MangaPageLayout.double]
/// pairs pages two-at-a-time; when [spreadOffset] is 1 the first page (cover)
/// stands alone before pairing resumes. An odd trailing page is emitted as a
/// solo entry. A non-positive [pageCount] yields an empty list; a negative
/// [spreadOffset] is treated as 0. RTL ordering is applied at render time, not
/// here.
///
/// [soloPages] 按页索引对齐（越界视为 false）：为 true 的页**独占一个 entry**。
/// 用于宽页（见开き）——一张本来就横跨两页的图若还被塞进半个槽，会缩到只有一半
/// 宽，而且它之后的所有页都会错开一位配对（左右页全反）。宽页独占既让它满宽显示，
/// 也自动把后续页序重新对齐。
///
/// 配对按「段」进行：独占页把整卷切成若干段连续普通页，每段各自决定段首页
/// 独占还是直接配对（段尾落单的页独占）：
/// - 含 [anchorPage] 的段：锚点页做一对的**前页**（阅读方向上先读的那侧）；
/// - 否则从第 0 页起的首段：封面独占（日漫惯例）；
/// - 否则（宽页之后的段）：段首直接配对（宽页把页序重新对齐）。
///
/// [spreadOffset] 为 0（「错开一页」关）时把**首段与锚点段**的配对整体错开一页。
/// 此前偏移只作用于首段：卷首附近只要有一张宽页，之后整卷的配对与偏移无关，
/// 读到后面发现配对不对时拨开关毫无反应（反馈 haetN22fJI）。锚点由阅读器在会话里
/// 设定（旋转进双页时取当前页；在宽页之后的段里拨「错开一页」时取当前对的前页），
/// 让偏移作用到读者眼前这一段。
List<MangaSpreadEntry> buildMangaSpreads(
  int pageCount, {
  required MangaPageLayout layout,
  required int spreadOffset,
  List<bool> soloPages = const <bool>[],
  int anchorPage = -1,
}) {
  if (pageCount <= 0) {
    return <MangaSpreadEntry>[];
  }

  if (layout == MangaPageLayout.single) {
    return <MangaSpreadEntry>[
      for (int i = 0; i < pageCount; i++) MangaSpreadEntry(<int>[i]),
    ];
  }

  bool solo(int index) =>
      index >= 0 && index < soloPages.length && soloPages[index];
  final bool shifted = spreadOffset < 1;

  final List<MangaSpreadEntry> entries = <MangaSpreadEntry>[];
  int cursor = 0;
  while (cursor < pageCount) {
    if (solo(cursor)) {
      entries.add(MangaSpreadEntry(<int>[cursor]));
      cursor += 1;
      continue;
    }
    final int start = cursor;
    int end = start;
    while (end < pageCount && !solo(end)) {
      end += 1;
    }
    final bool anchored = anchorPage >= start && anchorPage < end;
    final bool leadSolo;
    if (anchored) {
      leadSolo = (anchorPage - start).isOdd != shifted;
    } else if (start == 0) {
      leadSolo = !shifted;
    } else {
      leadSolo = false;
    }
    int i = start;
    if (leadSolo) {
      entries.add(MangaSpreadEntry(<int>[i]));
      i += 1;
    }
    while (i < end) {
      if (i + 1 < end) {
        entries.add(MangaSpreadEntry(<int>[i, i + 1]));
        i += 2;
      } else {
        entries.add(MangaSpreadEntry(<int>[i]));
        i += 1;
      }
    }
    cursor = end;
  }

  return entries;
}

/// 连续普通页段 `[start, end)`（见 [buildMangaSpreads]）；[page] 自己是独占页
/// 或越界时返回 null。
(int, int)? mangaSpreadRunOf(int page, int pageCount, List<bool> soloPages) {
  bool solo(int index) =>
      index >= 0 && index < soloPages.length && soloPages[index];
  if (page < 0 || page >= pageCount || solo(page)) return null;
  int start = page;
  while (start > 0 && !solo(start - 1)) {
    start -= 1;
  }
  int end = page + 1;
  while (end < pageCount && !solo(end)) {
    end += 1;
  }
  return (start, end);
}

/// 让 [page] 在当前 [spreadOffset] 下做一对**前页**的锚点值（传给
/// [buildMangaSpreads] 的 `anchorPage`）。偏移为 0 时锚点所在奇偶类会被错开成
/// 后页，所以要取同段里相邻的一页当锚点。[page] 是独占页 / 越界 / 所在段只有
/// 一页（没有配对可言）时返回 -1。
int mangaSpreadAnchorLeading(
  int page, {
  required int pageCount,
  required int spreadOffset,
  List<bool> soloPages = const <bool>[],
}) {
  final (int, int)? run = mangaSpreadRunOf(page, pageCount, soloPages);
  if (run == null) return -1;
  final (int start, int end) = run;
  if (end - start < 2) return -1;
  if (spreadOffset >= 1) return page;
  return page + 1 < end ? page + 1 : page - 1;
}
