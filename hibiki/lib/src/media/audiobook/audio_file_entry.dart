import 'package:path/path.dart' as p;

class AudioFileEntry {
  AudioFileEntry({
    required this.path,
    String? label,
    this.mappedSection,
    this.subtitlePath,
  }) : label = label ?? p.basenameWithoutExtension(path);

  final String path;
  String label;
  int? mappedSection;
  String? subtitlePath;
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

String _normalizeStem(String stem) =>
    stem.toLowerCase().replaceAll(RegExp(r'[^a-z0-9぀-鿿＀-￯]'), '');

/// Auto-pair subtitle files to audio entries by filename similarity.
/// Returns leftover subtitle paths that couldn't be matched.
List<String> autoMatchSubtitles({
  required List<AudioFileEntry> entries,
  required List<String> subtitlePaths,
}) {
  final List<String> remaining = List<String>.of(subtitlePaths);

  // Pass 1: exact stem match.
  for (final AudioFileEntry entry in entries) {
    if (entry.subtitlePath != null) continue;
    final String audioStem = _normalizeStem(p.basenameWithoutExtension(entry.path));
    for (int i = 0; i < remaining.length; i++) {
      final String subStem = _normalizeStem(p.basenameWithoutExtension(remaining[i]));
      if (audioStem == subStem) {
        entry.subtitlePath = remaining.removeAt(i);
        break;
      }
    }
  }

  // Pass 2: contains match.
  for (final AudioFileEntry entry in entries) {
    if (entry.subtitlePath != null) continue;
    final String audioStem = _normalizeStem(p.basenameWithoutExtension(entry.path));
    if (audioStem.isEmpty) continue;
    for (int i = 0; i < remaining.length; i++) {
      final String subStem = _normalizeStem(p.basenameWithoutExtension(remaining[i]));
      if (subStem.isEmpty) continue;
      if (audioStem.contains(subStem) || subStem.contains(audioStem)) {
        entry.subtitlePath = remaining.removeAt(i);
        break;
      }
    }
  }

  // Pass 3: trivial 1:1 — only one unpaired entry and one remaining subtitle.
  if (remaining.length == 1) {
    final List<AudioFileEntry> unpaired =
        entries.where((e) => e.subtitlePath == null).toList();
    if (unpaired.length == 1) {
      unpaired.first.subtitlePath = remaining.removeAt(0);
    }
  }

  return remaining;
}
