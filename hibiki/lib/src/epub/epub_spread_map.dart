import 'package:hibiki/src/epub/epub_book.dart';

/// A single entry in the spread map: either one chapter or a paired spread.
class SpreadEntry {
  const SpreadEntry.single({required this.chapterIndex})
      : secondChapterIndex = null;

  const SpreadEntry.spread({
    required this.chapterIndex,
    required int this.secondChapterIndex,
  });

  /// First (or only) chapter index in the spine.
  final int chapterIndex;

  /// Second chapter index when this is a two-page spread; `null` for singles.
  final int? secondChapterIndex;

  bool get isSpread => secondChapterIndex != null;

  List<int> get chapterIndices => secondChapterIndex != null
      ? <int>[chapterIndex, secondChapterIndex!]
      : <int>[chapterIndex];
}

/// Maps virtual page indices to [SpreadEntry]s, decoupling the reader's
/// navigation from raw chapter indices.
///
/// Pairing rules depend on [spreadMode]:
/// - `off`  — identity: each chapter = one virtual page.
/// - `on`   — force-pair adjacent image-only chapters (cover stays single).
/// - `auto` — use OPF metadata first, then edge-match results, then no pair.
class EpubSpreadMap {
  EpubSpreadMap._(this._entries, this._chapterToVirtual);

  final List<SpreadEntry> _entries;
  final Map<int, int> _chapterToVirtual;

  int get length => _entries.length;

  SpreadEntry entryAt(int virtualPage) => _entries[virtualPage];

  int virtualPageForChapter(int chapterIndex) =>
      _chapterToVirtual[chapterIndex] ?? 0;

  // ── Factories ─────────────────────────────────────────────────────

  factory EpubSpreadMap.build({
    required EpubBook book,
    required String spreadMode,
    required String spreadDirection,
    Map<int, bool>? edgeMatchResults,
  }) {
    if (spreadMode == 'off') return EpubSpreadMap._identity(book);
    if (spreadMode == 'on') return EpubSpreadMap._forceAll(book);
    return EpubSpreadMap._auto(book, edgeMatchResults);
  }

  /// Every chapter is its own virtual page.
  factory EpubSpreadMap._identity(EpubBook book) {
    final List<SpreadEntry> entries = List<SpreadEntry>.generate(
      book.chapters.length,
      (int i) => SpreadEntry.single(chapterIndex: i),
    );
    return EpubSpreadMap._(entries, _buildIndex(entries));
  }

  /// Force-pair adjacent image-only chapters. Chapter 0 (cover) stays single.
  factory EpubSpreadMap._forceAll(EpubBook book) {
    final List<SpreadEntry> entries = <SpreadEntry>[];
    int i = 0;
    while (i < book.chapters.length) {
      if (i == 0 || !book.isImageOnlyChapter(i)) {
        entries.add(SpreadEntry.single(chapterIndex: i));
        i++;
        continue;
      }
      if (i + 1 < book.chapters.length && book.isImageOnlyChapter(i + 1)) {
        entries.add(SpreadEntry.spread(
          chapterIndex: i,
          secondChapterIndex: i + 1,
        ));
        i += 2;
      } else {
        entries.add(SpreadEntry.single(chapterIndex: i));
        i++;
      }
    }
    return EpubSpreadMap._(entries, _buildIndex(entries));
  }

  /// Auto mode: OPF metadata → edge match results → single.
  factory EpubSpreadMap._auto(EpubBook book, Map<int, bool>? edgeMatch) {
    final List<SpreadEntry> entries = <SpreadEntry>[];
    int i = 0;
    while (i < book.chapters.length) {
      if (i + 1 < book.chapters.length && _shouldPairAuto(book, i, edgeMatch)) {
        entries.add(SpreadEntry.spread(
          chapterIndex: i,
          secondChapterIndex: i + 1,
        ));
        i += 2;
      } else {
        entries.add(SpreadEntry.single(chapterIndex: i));
        i++;
      }
    }
    return EpubSpreadMap._(entries, _buildIndex(entries));
  }

  static bool _shouldPairAuto(
    EpubBook book,
    int i,
    Map<int, bool>? edgeMatch,
  ) {
    final EpubChapter a = book.chapters[i];
    final EpubChapter b = book.chapters[i + 1];

    // OPF metadata: explicit left+right pair.
    if (_isSpreadPair(a.spreadProperty, b.spreadProperty)) return true;

    // Book-level rendition:spread with image-only chapters.
    if (book.renditionSpread != null &&
        book.renditionSpread != 'none' &&
        book.isImageOnlyChapter(i) &&
        book.isImageOnlyChapter(i + 1)) {
      return true;
    }

    // Edge match results (Phase 2).
    if (edgeMatch != null &&
        edgeMatch[i] == true &&
        book.isImageOnlyChapter(i) &&
        book.isImageOnlyChapter(i + 1)) {
      return true;
    }

    return false;
  }

  static bool _isSpreadPair(String? a, String? b) {
    if (a == null || b == null) return false;
    return (a == 'page-spread-left' && b == 'page-spread-right') ||
        (a == 'page-spread-right' && b == 'page-spread-left');
  }

  static Map<int, int> _buildIndex(List<SpreadEntry> entries) {
    final Map<int, int> index = <int, int>{};
    for (int v = 0; v < entries.length; v++) {
      for (final int c in entries[v].chapterIndices) {
        index[c] = v;
      }
    }
    return index;
  }
}
