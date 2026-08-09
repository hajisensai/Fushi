/// Splits into number / non-number runs. `unicode: true` makes `\d` match any
/// Unicode decimal digit (full-width `０-９` included), so full-width numbered
/// Japanese audiobook chapters land in numeric runs instead of code-unit order.
final RegExp _chunkPattern = RegExp(r'(\d+|\D+)', unicode: true);

/// Maps full-width digits `０-９` (U+FF10..U+FF19) to ASCII `0-9` so
/// `int.tryParse` can read them and zero-padding differences collapse.
String _normalizeDigits(String value) {
  final StringBuffer buffer = StringBuffer();
  for (final int unit in value.runes) {
    if (unit >= 0xFF10 && unit <= 0xFF19) {
      buffer.writeCharCode(unit - 0xFF10 + 0x30);
    } else {
      buffer.writeCharCode(unit);
    }
  }
  return buffer.toString();
}

/// Returns the file-name portion, stripping any `/` or `\` directory prefix.
/// Platform-independent (does not rely on `package:path` host style) so
/// Windows-style and POSIX-style paths both reduce to their last segment.
String _baseName(String value) {
  int cut = -1;
  for (int i = 0; i < value.length; i++) {
    final int unit = value.codeUnitAt(i);
    if (unit == 0x2F || unit == 0x5C) cut = i;
  }
  return cut < 0 ? value : value.substring(cut + 1);
}

/// Natural-sort comparator for audiobook file paths. Compares by file name
/// first (so directory prefixes from multi-select across folders don't reorder
/// files), then falls back to the full path for ties.
int compareAudioFilePath(String a, String b) {
  final int byName = _compareNormalized(_baseName(a), _baseName(b));
  if (byName != 0) return byName;
  return _compareNormalized(a, b);
}

int _compareNormalized(String a, String b) {
  final List<String> ac = _chunks(_normalizeDigits(a));
  final List<String> bc = _chunks(_normalizeDigits(b));
  final int len = ac.length < bc.length ? ac.length : bc.length;
  for (int i = 0; i < len; i++) {
    final int? an = int.tryParse(ac[i]);
    final int? bn = int.tryParse(bc[i]);
    if (an != null && bn != null) {
      if (an != bn) return an.compareTo(bn);
      continue;
    }
    final int cmp = ac[i].compareTo(bc[i]);
    if (cmp != 0) return cmp;
  }
  return ac.length.compareTo(bc.length);
}

List<String> _chunks(String value) =>
    _chunkPattern.allMatches(value).map((m) => m[0]!).toList();
