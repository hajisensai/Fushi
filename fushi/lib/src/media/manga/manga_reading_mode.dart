import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// Reading layout of a manga book.
enum MangaReadingMode {
  /// Page-based spread reading (single or double page, RTL/LTR).
  spread,

  /// Vertically scrolling webtoon strips.
  webtoon,

  /// A paged reader that advances vertically.  It shares the paged geometry
  /// with [spread], but keeps a distinct value so preferences can round-trip
  /// the Mihon mode without losing the user's choice.
  pagedVertical,

  /// Continuous long-strip reading with a small gap between pages.
  webtoonGaps,
}

extension MangaReadingModeSemantics on MangaReadingMode {
  /// Whether the mode uses a continuous vertical document.
  bool get isWebtoon =>
      this == MangaReadingMode.webtoon || this == MangaReadingMode.webtoonGaps;

  bool get isContinuous => isWebtoon || this == MangaReadingMode.pagedVertical;

  /// Whether pages are laid out as discrete viewport-sized units.
  bool get isPaged => !isWebtoon;

  /// Whether a continuous reader should paint a gap between pages.
  bool get hasGaps => this == MangaReadingMode.webtoonGaps;

  String get storageKey {
    switch (this) {
      case MangaReadingMode.spread:
        return 'spread';
      case MangaReadingMode.webtoon:
        return 'webtoon';
      case MangaReadingMode.pagedVertical:
        return 'paged_vertical';
      case MangaReadingMode.webtoonGaps:
        return 'webtoon_gaps';
    }
  }

  static MangaReadingMode fromStorageKey(String value) {
    switch (value) {
      case 'webtoon':
        return MangaReadingMode.webtoon;
      case 'paged_vertical':
        return MangaReadingMode.pagedVertical;
      case 'webtoon_gaps':
        return MangaReadingMode.webtoonGaps;
      case 'spread':
      default:
        return MangaReadingMode.spread;
    }
  }
}

/// Pages whose median `height / width` aspect ratio exceeds this threshold are
/// auto-detected as webtoon strips; otherwise spread. Initial value 2.0.
const double kWebtoonAspectThreshold = 2.0;

/// Auto-detect the reading mode from mokuro-reported page dimensions.
///
/// Takes the median of every page's `img_height / img_width` ratio (using the
/// dimensions mokuro already provides, never decoding the image). A median
/// strictly greater than [kWebtoonAspectThreshold] is
/// [MangaReadingMode.webtoon], otherwise [MangaReadingMode.spread]. Zero-width
/// pages are skipped to avoid divide-by-zero; a payload with no valid pages
/// falls back to spread.
MangaReadingMode detectReadingMode(MokuroPayload payload) {
  final List<double> ratios = <double>[];
  for (final MokuroImage image in payload.images) {
    final double width = image.size.width;
    final double height = image.size.height;
    if (width <= 0) {
      continue;
    }
    ratios.add(height / width);
  }

  if (ratios.isEmpty) {
    return MangaReadingMode.spread;
  }

  ratios.sort();
  final int mid = ratios.length ~/ 2;
  final double median =
      ratios.length.isOdd ? ratios[mid] : (ratios[mid - 1] + ratios[mid]) / 2.0;

  return median > kWebtoonAspectThreshold
      ? MangaReadingMode.webtoon
      : MangaReadingMode.spread;
}
