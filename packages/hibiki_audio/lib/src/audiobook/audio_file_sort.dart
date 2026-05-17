final RegExp _chunkPattern = RegExp(r'(\d+|\D+)');

int compareAudioFilePath(String a, String b) {
  final List<String> ac = _chunks(a);
  final List<String> bc = _chunks(b);
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
