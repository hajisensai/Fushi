import 'package:hibiki_audio/hibiki_audio.dart';

/// Resolves the audio range used when exporting sentence audio for Anki.
///
/// The lookup cue can be only one fragment inside the selected sentence. Prefer
/// the reader's full normalized sentence range; when that is unavailable, match
/// Hoshi Android's behavior by expanding to adjacent cues whose text belongs to
/// the selected sentence. [delayMs] is the user's global A/V sync offset and is
/// applied to both edges, not as a sentence-tail padding.
///
/// [cue] is the cue the looked-up word fell inside. It can be null: audiobook
/// cue alignment leaves gaps (titles, captions, alignment misses, chapter
/// edges), so a word can sit in covered-but-uncued text while the sentence it
/// belongs to is still spanned by surrounding cues. In that case we resolve the
/// range purely from the sentence's normalized [sectionIndex] + offset/length
/// span instead of giving up — that is the only way to recover sentence audio
/// for those gap words (TODO-104a / BUG-172). Returns null only when no range
/// can be derived at all (no cue and no usable sentence span).
AudioPlaybackRange? miningSentenceAudioRange({
  required List<AudioCue> cues,
  required AudioCue? cue,
  required String sentence,
  int? sectionIndex,
  int? sentenceNormCharOffset,
  int? sentenceNormCharLength,
  int delayMs = 0,
}) {
  final AudioPlaybackRange? positionRange = _rangeFromSentencePosition(
    cues: cues,
    cue: cue,
    sentence: sentence,
    sectionIndex: sectionIndex,
    sentenceNormCharOffset: sentenceNormCharOffset,
    sentenceNormCharLength: sentenceNormCharLength,
  );

  // When the word did not land in any cue (gap), the sentence span is the only
  // anchor we have; do not fall through to cue-relative expansion.
  final AudioPlaybackRange? baseRange = positionRange ??
      (cue == null
          ? null
          : (_expandAroundCue(cues: cues, cue: cue, sentence: sentence) ??
              _cueRange(cue)));

  if (baseRange == null) {
    return null;
  }
  return _shiftRange(baseRange, delayMs);
}

AudioPlaybackRange? _rangeFromSentencePosition({
  required List<AudioCue> cues,
  required AudioCue? cue,
  required String sentence,
  required int? sectionIndex,
  required int? sentenceNormCharOffset,
  required int? sentenceNormCharLength,
}) {
  // TODO-811: local (non-sasayaki) audiobooks have cues whose textFragmentId is a
  // plain selector ([data-cue-id="N"]) or empty, never a sasayaki-encoded
  // fragment, so CollectionAudioMatcher's position matching cannot place them. The
  // sentence text is the only span anchor left, so always forward it as the text
  // fallback; findPlaybackRange returns the sasayaki position range when present
  // and otherwise recovers the range from the cue texts (which carry the real
  // start/end ms). Without this, a gap word (cue == null) on a local audiobook
  // resolved no range at all -> the card silently lost its sentence audio.
  final String textFallback = sentence.trim();
  if (sectionIndex == null ||
      sentenceNormCharOffset == null ||
      sentenceNormCharLength == null ||
      sentenceNormCharLength <= 0) {
    // No usable normalized span. Still try the text fallback when there is no
    // lookup cue to anchor a section (gap word); when a cue exists the caller's
    // _expandAroundCue path already handles text-based expansion.
    if (cue != null || textFallback.isEmpty) {
      return null;
    }
    return CollectionAudioMatcher.findPlaybackRange(
      cues: cues,
      text: textFallback,
    );
  }
  // When a lookup cue exists, keep the original guard: trust the sentence span
  // only if the cue actually decodes to this section (the word truly belongs to
  // the cued text). When there is no cue (gap word), the cue cannot vouch for
  // the section, so we trust [sectionIndex] directly — it comes from the
  // reader's current chapter / lyrics fragment, which is authoritative for the
  // selection regardless of cue coverage.
  if (cue != null) {
    final SasayakiFragment? cueFragment =
        SasayakiMatchCodec.tryDecode(cue.textFragmentId);
    if (cueFragment == null) {
      // The cue carries no sasayaki position (plain SRT selector / empty): it
      // cannot vouch for the section, and the section's cues may not be sasayaki
      // either, so trusting the text fallback here could anchor on a repeated
      // sentence elsewhere. Defer to the caller's cue-anchored _expandAroundCue.
      return null;
    }
    if (cueFragment.sectionIndex != sectionIndex) {
      // TODO-956 (C-audio): cue/reader divergence — the lookup cue decoded to a
      // DIFFERENT section than the reader's authoritative sentence span. The old
      // code returned null and fell through to _expandAroundCue's CONTIGUOUS
      // substring match, which is exactly what produced no sentence audio when
      // the cue and reader texts diverge. Instead, prefer anchoring on the
      // sentence span by POSITION in the reader's section. We pass text:null so
      // this attempt never falls back to text matching (which could grab a
      // repeated sentence); when the section's cues carry no sasayaki position
      // the call returns null and we still defer to the caller's cue expansion.
      return CollectionAudioMatcher.findPlaybackRange(
        cues: cues,
        sectionIndex: sectionIndex,
        normCharOffset: sentenceNormCharOffset,
        normCharLength: sentenceNormCharLength,
      );
    }
  }
  return CollectionAudioMatcher.findPlaybackRange(
    cues: cues,
    sectionIndex: sectionIndex,
    normCharOffset: sentenceNormCharOffset,
    normCharLength: sentenceNormCharLength,
    text: textFallback.isEmpty ? null : textFallback,
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
