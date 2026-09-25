part of 'gal_lookup_calibration_ocr.dart';

// Legacy advance inference is intentionally absent: v24 uses one cell width.
typedef _OcrRowEnd = ({
  double width,
  double lastWidth,
  double nextWidth,
  bool softWrap,
  bool punctuation,
  int sample,
});

/// A wrapped row proves a capacity interval, not a character count. Choose a
/// common capacity in those intervals, allowing the existing punctuation hang.
({double width, bool hanging})? _fitOcrRowCapacity(List<_OcrRowEnd> rows) {
  final List<_OcrRowEnd> wrapped = rows.where((r) => r.softWrap).toList();
  if (wrapped.isEmpty) return null;
  final Set<double> candidates = {};
  for (final _OcrRowEnd row in wrapped) {
    candidates.add(row.width);
    candidates.add((row.width - .02).ceilToDouble());
    if (row.punctuation) candidates.add(row.width - row.lastWidth);
  }
  final List<double> ordered = candidates.toList()..sort();
  for (final double width in ordered) {
    if (width < 2 || width > 128) continue;
    bool valid = true;
    bool hanging = false;
    for (final _OcrRowEnd row in rows) {
      final bool hangs =
          row.width > width + .02 &&
          row.punctuation &&
          row.lastWidth <= 1 &&
          (row.width - row.lastWidth - width).abs() <= .02;
      if (row.width > width + .02 && !hangs ||
          row.softWrap && row.width + row.nextWidth <= width + .02) {
        valid = false;
        break;
      }
      hanging = hanging || hangs;
    }
    if (valid) return (width: width, hanging: hanging);
  }
  return null;
}
