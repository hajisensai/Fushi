import 'package:hibiki/src/epub/epub_book.dart';

/// A single entry in the spread map: either one chapter or a paired spread.
class SpreadEntry {
  const SpreadEntry.single({
    required this.chapterIndex,
    this.mergedImageChapters = const <int>[],
  }) : secondChapterIndex = null;

  const SpreadEntry.spread({
    required this.chapterIndex,
    required int this.secondChapterIndex,
  }) : mergedImageChapters = const <int>[];

  /// First (or only) chapter index in the spine.
  final int chapterIndex;

  /// Second chapter index when this is a two-page spread; `null` for singles.
  final int? secondChapterIndex;

  /// TODO-1128: spine indices of 0-char single-image chapters absorbed into
  /// this (text) chapter's continuous flow. Empty for the common case. The
  /// absorbed chapters keep their physical spine index (charOffset ownership /
  /// DB serialization unchanged) but no longer occupy their own virtual page —
  /// the reader injects their `<img>` inline when serving [chapterIndex]. Only
  /// ever populated on a `single` text entry; never on a spread or an
  /// image-only entry.
  final List<int> mergedImageChapters;

  bool get isSpread => secondChapterIndex != null;

  /// True when this entry absorbs one or more trailing single-image chapters.
  bool get hasMergedImages => mergedImageChapters.isNotEmpty;

  List<int> get chapterIndices {
    if (secondChapterIndex != null) {
      return <int>[chapterIndex, secondChapterIndex!];
    }
    if (mergedImageChapters.isEmpty) return <int>[chapterIndex];
    return <int>[chapterIndex, ...mergedImageChapters];
  }
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

  /// TODO-1128: spine indices of the 0-char single-image chapters absorbed into
  /// the *text* chapter [textChapterIndex]'s flow, in reading order. Empty when
  /// [textChapterIndex] is not an absorbing text chapter (the common case, and
  /// whenever `mergeImagePages` is off). The reader injects these chapters'
  /// `<img>` inline when serving [textChapterIndex]'s XHTML.
  List<int> mergedImagesForChapter(int textChapterIndex) {
    final int? virtual = _chapterToVirtual[textChapterIndex];
    if (virtual == null) return const <int>[];
    final SpreadEntry entry = _entries[virtual];
    if (entry.chapterIndex != textChapterIndex) return const <int>[];
    return entry.mergedImageChapters;
  }

  /// TODO-1128: true when [chapterIndex] is a single-image chapter absorbed into
  /// a neighbouring text chapter (so it must be hidden from the TOC and never
  /// paged to on its own). False for text chapters and unmerged image chapters.
  bool isAbsorbedImageChapter(int chapterIndex) {
    final int? virtual = _chapterToVirtual[chapterIndex];
    if (virtual == null) return false;
    final SpreadEntry entry = _entries[virtual];
    return entry.chapterIndex != chapterIndex &&
        entry.mergedImageChapters.contains(chapterIndex);
  }

  // ── Factories ─────────────────────────────────────────────────────

  factory EpubSpreadMap.build({
    required EpubBook book,
    required String spreadMode,
    required String spreadDirection,
    Map<int, bool>? edgeMatchResults,
    bool mergeImagePages = false,
  }) {
    final List<SpreadEntry> base;
    if (spreadMode == 'off') {
      base = _identityEntries(book);
    } else if (spreadMode == 'on') {
      base = _forceAllEntries(book);
    } else {
      base = _autoEntries(book, edgeMatchResults);
    }
    // TODO-1128: image-merge is a second, independent pass applied *after*
    // spread pairing — spread-paired image chapters are already consumed and
    // can never be absorbed, so pairing wins over merge by construction.
    final List<SpreadEntry> entries =
        mergeImagePages ? _mergeImageEntries(book, base) : base;
    return EpubSpreadMap._(entries, _buildIndex(entries));
  }

  /// Every chapter is its own virtual page.
  static List<SpreadEntry> _identityEntries(EpubBook book) =>
      List<SpreadEntry>.generate(
        book.chapters.length,
        (int i) => SpreadEntry.single(chapterIndex: i),
      );

  /// Force-pair adjacent image-only chapters. Chapter 0 (cover) stays single.
  static List<SpreadEntry> _forceAllEntries(EpubBook book) {
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
    return entries;
  }

  /// Auto mode: OPF metadata → edge match results → single.
  static List<SpreadEntry> _autoEntries(
    EpubBook book,
    Map<int, bool>? edgeMatch,
  ) {
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
    return entries;
  }

  /// TODO-1128 (受限方案 A): fold each run of trailing single-image-only
  /// entries into the immediately-preceding single *text* entry, so the source
  /// EPUB's standalone illustration chapters render inline in the neighbouring
  /// prose chapter's continuous flow instead of each taking its own page.
  ///
  /// Hard invariants (never-break-userspace):
  ///  - Only a `single` entry whose chapter is NOT image-only (a text chapter)
  ///    absorbs; two text chapters are never merged (charOffset ownership must
  ///    stay one-section-per-document).
  ///  - Only `single` image-only entries are absorbed — a spread entry (already
  ///    paired) is opaque and stops the run, so pairing always wins over merge.
  ///  - Chapter 0 (cover) is never absorbed (it is emitted as its own single).
  ///  - Absorbed chapters keep their physical spine index; they only drop their
  ///    own virtual page. [_buildIndex] then maps them to the absorbing page.
  static List<SpreadEntry> _mergeImageEntries(
    EpubBook book,
    List<SpreadEntry> base,
  ) {
    final List<SpreadEntry> out = <SpreadEntry>[];
    int i = 0;
    while (i < base.length) {
      final SpreadEntry entry = base[i];
      final bool absorbable = !entry.isSpread &&
          entry.mergedImageChapters.isEmpty &&
          !book.isImageOnlyChapter(entry.chapterIndex);
      if (!absorbable) {
        out.add(entry);
        i++;
        continue;
      }
      // Collect the run of following single image-only entries.
      final List<int> absorbed = <int>[];
      int j = i + 1;
      while (j < base.length) {
        final SpreadEntry next = base[j];
        if (next.isSpread) break;
        if (!book.isImageOnlyChapter(next.chapterIndex)) break;
        absorbed.add(next.chapterIndex);
        j++;
      }
      if (absorbed.isEmpty) {
        out.add(entry);
        i++;
      } else {
        out.add(SpreadEntry.single(
          chapterIndex: entry.chapterIndex,
          mergedImageChapters: List<int>.unmodifiable(absorbed),
        ));
        i = j;
      }
    }
    return out;
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
