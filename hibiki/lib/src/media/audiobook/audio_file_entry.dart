import 'package:path/path.dart' as p;

class AudioFileEntry {
  AudioFileEntry({
    required this.path,
    String? label,
    this.mappedSection,
  }) : label = label ?? p.basenameWithoutExtension(path);

  final String path;
  String label;
  int? mappedSection;
}

/// Natural-order comparison: splits strings into text and numeric chunks
/// so that "track2" < "track10".
int naturalCompare(String a, String b) {
  final RegExp re = RegExp(r'(\d+|\D+)');
  final List<String> partsA = re.allMatches(a).map((m) => m[0]!).toList();
  final List<String> partsB = re.allMatches(b).map((m) => m[0]!).toList();
  for (int i = 0; i < partsA.length && i < partsB.length; i++) {
    final int? numA = int.tryParse(partsA[i]);
    final int? numB = int.tryParse(partsB[i]);
    int cmp;
    if (numA != null && numB != null) {
      cmp = numA.compareTo(numB);
    } else {
      cmp = partsA[i].toLowerCase().compareTo(partsB[i].toLowerCase());
    }
    if (cmp != 0) return cmp;
  }
  return partsA.length.compareTo(partsB.length);
}
