/// Parsed ownership/time evidence carried by a dumped resource filename.
final class GalVoiceResourceName {
  const GalVoiceResourceName({
    required this.tick,
    required this.basename,
    this.textEventId,
  });
  final int tick;
  final String basename;
  final int? textEventId;
}

/// Parses `<tick>_[fushi_textseq<textSeq>_]<basename>` without IO.
/// A malformed explicit marker cannot become a time-only candidate.
GalVoiceResourceName? parseGalVoiceResourceName(String fileName) {
  final int underscore = fileName.indexOf('_');
  if (underscore <= 0) return null;
  final int? tick = int.tryParse(fileName.substring(0, underscore));
  if (tick == null) return null;
  String basename = fileName.substring(underscore + 1);
  if (basename.isEmpty) return null;
  int? textEventId;
  if (basename.startsWith('fushi_textseq')) {
    final RegExpMatch? match = RegExp(
      r'^fushi_textseq(\d+)_(.+)$',
    ).firstMatch(basename);
    if (match == null) return null;
    textEventId = int.tryParse(match.group(1)!);
    if (textEventId == null || textEventId <= 0) return null;
    basename = match.group(2)!;
  }
  return GalVoiceResourceName(
    tick: tick,
    basename: basename,
    textEventId: textEventId,
  );
}
