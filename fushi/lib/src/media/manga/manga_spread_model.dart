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
MangaPageLayout resolveMangaPageLayout({
  required MangaSpreadPreference preference,
  required bool isLandscape,
}) {
  switch (preference) {
    case MangaSpreadPreference.single:
      return MangaPageLayout.single;
    case MangaSpreadPreference.double:
      return MangaPageLayout.double;
    case MangaSpreadPreference.auto:
      return isLandscape ? MangaPageLayout.double : MangaPageLayout.single;
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
List<MangaSpreadEntry> buildMangaSpreads(
  int pageCount, {
  required MangaPageLayout layout,
  required int spreadOffset,
  List<bool> soloPages = const <bool>[],
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

  final List<MangaSpreadEntry> entries = <MangaSpreadEntry>[];
  int cursor = 0;

  // Optional solo cover page when offset 1.
  if (spreadOffset >= 1) {
    entries.add(MangaSpreadEntry(<int>[cursor]));
    cursor += 1;
  }

  while (cursor < pageCount) {
    // 本页是宽页 → 独占；下一页是宽页 → 本页也只能独占（否则宽页会被拉进配对，
    // 失去满宽显示，并把后续页序整体错开一位）。
    if (solo(cursor) || cursor + 1 >= pageCount || solo(cursor + 1)) {
      entries.add(MangaSpreadEntry(<int>[cursor]));
      cursor += 1;
    } else {
      entries.add(MangaSpreadEntry(<int>[cursor, cursor + 1]));
      cursor += 2;
    }
  }

  return entries;
}
