import 'package:hibiki_audio/hibiki_audio.dart';

/// Resolves the audio range used when exporting sentence audio for Anki.
///
/// The lookup cue can be only one fragment inside the selected sentence. Prefer
/// the reader's full normalized sentence range; when that is unavailable, match
/// Hoshi Android's behavior by expanding to adjacent cues whose text belongs to
/// the selected sentence. [delayMs] is the user's global A/V sync offset and is
/// applied to both edges, not as a sentence-tail padding.
AudioPlaybackRange miningSentenceAudioRange({
  required List<AudioCue> cues,
  required AudioCue cue,
  required String sentence,
  int? sectionIndex,
  int? sentenceNormCharOffset,
  int? sentenceNormCharLength,
  int delayMs = 0,
}) {
  final AudioPlaybackRange baseRange = _rangeFromSentencePosition(
        cues: cues,
        cue: cue,
        sentence: sentence,
        sectionIndex: sectionIndex,
        sentenceNormCharOffset: sentenceNormCharOffset,
        sentenceNormCharLength: sentenceNormCharLength,
      ) ??
      _expandAroundCue(cues: cues, cue: cue, sentence: sentence) ??
      _cueRange(cue);

  return _shiftRange(baseRange, delayMs);
}

AudioPlaybackRange? _rangeFromSentencePosition({
  required List<AudioCue> cues,
  required AudioCue cue,
  required String sentence,
  required int? sectionIndex,
  required int? sentenceNormCharOffset,
  required int? sentenceNormCharLength,
}) {
  final SasayakiFragment? cueFragment =
      SasayakiMatchCodec.tryDecode(cue.textFragmentId);
  if (sectionIndex == null ||
      sentenceNormCharOffset == null ||
      sentenceNormCharLength == null ||
      sentenceNormCharLength <= 0 ||
      cueFragment == null ||
      cueFragment.sectionIndex != sectionIndex) {
    return null;
  }
  return CollectionAudioMatcher.findPlaybackRange(
    cues: cues,
    sectionIndex: sectionIndex,
    normCharOffset: sentenceNormCharOffset,
    normCharLength: sentenceNormCharLength,
  );
}

AudioPlaybackRange? _expandAroundCue({
  required List<AudioCue> cues,
  required AudioCue cue,
  required String sentence,
}) {
  final int cueIndex = _indexOfCue(cues, cue);
  if (cueIndex < 0) return null;

  final String normalizedSentence = AudioTextNormalizer.normalize(sentence);
  if (normalizedSentence.isEmpty) return null;

  final AudioPlaybackRange? anchoredMatch = _anchoredAdjacentMatch(
    cues: cues,
    cueIndex: cueIndex,
    normalizedSentence: normalizedSentence,
  );
  if (anchoredMatch != null) return anchoredMatch;

  int startIndex = cueIndex;
  int endIndex = cueIndex;
  while (startIndex > 0 &&
      _canExpandTo(cue, cues[startIndex - 1], normalizedSentence)) {
    startIndex -= 1;
  }
  while (endIndex < cues.length - 1 &&
      _canExpandTo(cue, cues[endIndex + 1], normalizedSentence)) {
    endIndex += 1;
  }

  final int fileIndex = cue.audioFileIndex;
  int startMs = cues[startIndex].startMs;
  int endMs = cues[endIndex].endMs;
  for (int i = startIndex; i <= endIndex; i++) {
    final AudioCue hit = cues[i];
    if (hit.audioFileIndex != fileIndex) break;
    if (hit.startMs < startMs) startMs = hit.startMs;
    if (hit.endMs > endMs) endMs = hit.endMs;
  }

  return AudioPlaybackRange(
    audioFileIndex: fileIndex,
    startMs: startMs,
    endMs: endMs,
  );
}

AudioPlaybackRange? _anchoredAdjacentMatch({
  required List<AudioCue> cues,
  required int cueIndex,
  required String normalizedSentence,
}) {
  final List<String> normalizedTexts = <String>[];
  final List<int> cueStarts = <int>[];
  final StringBuffer buffer = StringBuffer();

  for (final AudioCue cue in cues) {
    cueStarts.add(buffer.length);
    final String normalizedText = AudioTextNormalizer.normalize(cue.text);
    normalizedTexts.add(normalizedText);
    buffer.write(normalizedText);
  }

  final String concat = buffer.toString();
  final int anchorStart = cueStarts[cueIndex];
  final int anchorEnd = anchorStart + normalizedTexts[cueIndex].length;

  int found = concat.indexOf(normalizedSentence);
  while (found >= 0) {
    final int foundEnd = found + normalizedSentence.length;
    if (_rangeContainsCue(
      rangeStart: found,
      rangeEnd: foundEnd,
      cueStart: anchorStart,
      cueEnd: anchorEnd,
    )) {
      return _cueRangeForNormalizedSpan(
        cues: cues,
        normalizedTexts: normalizedTexts,
        cueStarts: cueStarts,
        spanStart: found,
        spanEnd: foundEnd,
      );
    }
    found = concat.indexOf(normalizedSentence, found + 1);
  }

  return null;
}

bool _rangeContainsCue({
  required int rangeStart,
  required int rangeEnd,
  required int cueStart,
  required int cueEnd,
}) {
  if (cueStart == cueEnd) {
    return rangeStart <= cueStart && cueStart <= rangeEnd;
  }
  return rangeStart < cueEnd && rangeEnd > cueStart;
}

AudioPlaybackRange? _cueRangeForNormalizedSpan({
  required List<AudioCue> cues,
  required List<String> normalizedTexts,
  required List<int> cueStarts,
  required int spanStart,
  required int spanEnd,
}) {
  int startIndex = cues.length;
  int endIndex = -1;
  for (int i = 0; i < cues.length; i++) {
    final int cueStart = cueStarts[i];
    final int cueEnd = cueStart + normalizedTexts[i].length;
    if (_rangeContainsCue(
      rangeStart: spanStart,
      rangeEnd: spanEnd,
      cueStart: cueStart,
      cueEnd: cueEnd,
    )) {
      if (i < startIndex) startIndex = i;
      if (i > endIndex) endIndex = i;
    }
  }

  if (startIndex > endIndex) return null;

  final int fileIndex = cues[startIndex].audioFileIndex;
  int startMs = cues[startIndex].startMs;
  int endMs = cues[startIndex].endMs;
  for (int i = startIndex + 1; i <= endIndex; i++) {
    final AudioCue cue = cues[i];
    if (cue.audioFileIndex != fileIndex) break;
    if (cue.startMs < startMs) startMs = cue.startMs;
    if (cue.endMs > endMs) endMs = cue.endMs;
  }

  return AudioPlaybackRange(
    audioFileIndex: fileIndex,
    startMs: startMs,
    endMs: endMs,
  );
}

bool _canExpandTo(
  AudioCue anchor,
  AudioCue candidate,
  String normalizedSentence,
) {
  if (candidate.audioFileIndex != anchor.audioFileIndex) return false;

  final SasayakiFragment? anchorFragment =
      SasayakiMatchCodec.tryDecode(anchor.textFragmentId);
  final SasayakiFragment? candidateFragment =
      SasayakiMatchCodec.tryDecode(candidate.textFragmentId);
  if (anchorFragment != null &&
      candidateFragment != null &&
      candidateFragment.sectionIndex != anchorFragment.sectionIndex) {
    return false;
  }

  final String normalizedCue = AudioTextNormalizer.normalize(candidate.text);
  return normalizedCue.isNotEmpty && normalizedSentence.contains(normalizedCue);
}

int _indexOfCue(List<AudioCue> cues, AudioCue cue) {
  final int? id = cue.id;
  if (id != null) {
    final int byId = cues.indexWhere((AudioCue c) => c.id == id);
    if (byId >= 0) return byId;
  }
  return cues.indexWhere((AudioCue c) => identical(c, cue));
}

AudioPlaybackRange _cueRange(AudioCue cue) {
  final int endMs = cue.endMs > cue.startMs ? cue.endMs : cue.startMs + 1;
  return AudioPlaybackRange(
    audioFileIndex: cue.audioFileIndex,
    startMs: cue.startMs,
    endMs: endMs,
  );
}

AudioPlaybackRange _shiftRange(AudioPlaybackRange range, int delayMs) {
  if (delayMs == 0) return range;
  final int startMs = (range.startMs + delayMs).clamp(0, 1 << 30);
  final int endMs = (range.endMs + delayMs).clamp(startMs + 1, 1 << 30);
  return AudioPlaybackRange(
    audioFileIndex: range.audioFileIndex,
    startMs: startMs,
    endMs: endMs,
  );
}
