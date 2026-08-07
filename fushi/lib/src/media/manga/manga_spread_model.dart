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

/// Build the spread sequence for [pageCount] pages under [layout].
///
/// [MangaPageLayout.single] yields one entry per page. [MangaPageLayout.double]
/// pairs pages two-at-a-time; when [spreadOffset] is 1 the first page (cover)
/// stands alone before pairing resumes. An odd trailing page is emitted as a
/// solo entry. A non-positive [pageCount] yields an empty list; a negative
/// [spreadOffset] is treated as 0. RTL ordering is applied at render time, not
/// here.
List<MangaSpreadEntry> buildMangaSpreads(
  int pageCount, {
  required MangaPageLayout layout,
  required int spreadOffset,
}) {
  if (pageCount <= 0) {
    return <MangaSpreadEntry>[];
  }

  if (layout == MangaPageLayout.single) {
    return <MangaSpreadEntry>[
      for (int i = 0; i < pageCount; i++) MangaSpreadEntry(<int>[i]),
    ];
  }

  final List<MangaSpreadEntry> entries = <MangaSpreadEntry>[];
  int cursor = 0;

  // Optional solo cover page when offset 1.
  if (spreadOffset >= 1) {
    entries.add(MangaSpreadEntry(<int>[cursor]));
    cursor += 1;
  }

  while (cursor < pageCount) {
    if (cursor + 1 < pageCount) {
      entries.add(MangaSpreadEntry(<int>[cursor, cursor + 1]));
      cursor += 2;
    } else {
      entries.add(MangaSpreadEntry(<int>[cursor]));
      cursor += 1;
    }
  }

  return entries;
}
