/// Marker carried by voice resources that the TyranoScript DOM source copied
/// out of the game archive for one specific sentence:
/// `<tick>_fushi_domvoice<group>_<basename>`.
///
/// The group is the Dart-side id of one DOM sentence, so ownership is explicit
/// and these files must never become a time-proximity candidate for another
/// text event (native dump pairing ignores them; see [GalVoiceResourceName.domVoiceGroup]).
const String kGalDomVoiceMarker = 'fushi_domvoice';

/// Parsed ownership/time evidence carried by a dumped resource filename.
final class GalVoiceResourceName {
  const GalVoiceResourceName({
    required this.tick,
    required this.basename,
    this.textEventId,
    this.domVoiceGroup,
  });
  final int tick;
  final String basename;
  final int? textEventId;

  /// Sentence group of a TyranoScript DOM voice (`fushi_domvoice<group>_`).
  /// Non-null means the file is bound to exactly that DOM sentence: it is not
  /// a time-paired candidate, and its companions are the same group only.
  final int? domVoiceGroup;
}

final RegExp _textSeqMarker = RegExp(r'^fushi_textseq(\d+)_(.+)$');
final RegExp _domVoiceMarker = RegExp(r'^fushi_domvoice(\d+)_(.+)$');

/// Parses `<tick>_[fushi_textseq<textSeq>_|fushi_domvoice<group>_]<basename>`
/// without IO. A malformed explicit marker cannot become a time-only candidate.
GalVoiceResourceName? parseGalVoiceResourceName(String fileName) {
  final int underscore = fileName.indexOf('_');
  if (underscore <= 0) return null;
  final int? tick = int.tryParse(fileName.substring(0, underscore));
  if (tick == null) return null;
  String basename = fileName.substring(underscore + 1);
  if (basename.isEmpty) return null;
  int? textEventId;
  int? domVoiceGroup;
  if (basename.startsWith('fushi_textseq')) {
    final RegExpMatch? match = _textSeqMarker.firstMatch(basename);
    if (match == null) return null;
    textEventId = int.tryParse(match.group(1)!);
    if (textEventId == null || textEventId <= 0) return null;
    basename = match.group(2)!;
  } else if (basename.startsWith(kGalDomVoiceMarker)) {
    final RegExpMatch? match = _domVoiceMarker.firstMatch(basename);
    if (match == null) return null;
    domVoiceGroup = int.tryParse(match.group(1)!);
    if (domVoiceGroup == null || domVoiceGroup <= 0) return null;
    basename = match.group(2)!;
  }
  return GalVoiceResourceName(
    tick: tick,
    basename: basename,
    textEventId: textEventId,
    domVoiceGroup: domVoiceGroup,
  );
}

/// File name for a DOM voice of sentence [group] (see [kGalDomVoiceMarker]).
/// [basename] must already be a safe single path segment with its extension.
String galDomVoiceResourceName({
  required int tick,
  required int group,
  required String basename,
}) => '${tick}_$kGalDomVoiceMarker${group}_$basename';
