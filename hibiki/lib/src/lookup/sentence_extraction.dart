// TODO-1030 M0 — pure sentence extraction over a flat text buffer.
//
// The Windows UIA foreground-selection capture (foreground_selection.cpp) hands
// Dart a plain string: the selected term PLUS a bounded window of surrounding
// characters (±kForegroundContextExpand), together with the selection's
// {selStart, selLen} offsets INSIDE that buffer. This helper trims that raw
// window down to the ONE sentence the selection sits in — the same "current
// sentence" a Yomitan {sentence} field would carry — so the global-lookup popup
// can show the word in context.
//
// It deliberately mirrors the reader's DOM-based sentence walk in
// reader_selection_scripts.dart (hoshiSelection.getSentenceContext): walk
// BACKWARD from the selection start until a sentence delimiter (that delimiter
// is NOT included — the sentence begins after it), then FORWARD from the
// selection end until a delimiter (that delimiter IS included, plus any trailing
// closing punctuation). The only structural difference is the input model: the
// reader walks TEXT nodes bounded by a block element; here the input is already
// a single flat string, so there is no cross-node / block boundary — the buffer
// edge itself is the hard boundary. The delimiter tables are kept byte-identical
// to the JS side so the two paths agree (guarded by sentence_extraction_test).

/// The one sentence the selection sits in, plus where the ORIGINAL selection
/// lands inside it. Offsets are UTF-16 code-unit indices into [sentence]
/// (matching Dart String indexing and the JS String indexing the reader uses).
class SentenceExtractionResult {
  const SentenceExtractionResult({
    required this.sentence,
    required this.selStart,
    required this.selLen,
  });

  /// The extracted sentence (trimmed of leading/trailing whitespace).
  final String sentence;

  /// The selection's start offset WITHIN [sentence] (0-based, clamped).
  final int selStart;

  /// The selection's length within [sentence] (clamped so selStart+selLen never
  /// exceeds sentence.length).
  final int selLen;
}

/// Sentence-terminating delimiters. Byte-identical to
/// `hoshiSelection.sentenceDelimiters` in reader_selection_scripts.dart
/// ('。！？.!?\n\r'): the char AFTER one of these starts a new sentence.
const String kSentenceDelimiters = '。！？.!?\n\r';

/// Trailing closing punctuation pulled INTO the sentence after its terminating
/// delimiter. Byte-identical to `hoshiSelection.trailingSentenceChars`
/// ('。、！？…‥」』）)】〉》〕｝}］]').
const String kTrailingSentenceChars = '。、！？…‥」』）)】〉》〕｝}］]';

/// Extracts the current sentence around the selection [selStart, selStart+selLen)
/// inside the flat buffer [text]. Mirrors the reader's DOM sentence walk (see
/// file header). [selStart]/[selLen] are clamped defensively so an out-of-range
/// selection (e.g. UIA reported odd offsets) never throws — the worst case is
/// the whole buffer treated as one sentence.
///
/// Returns the trimmed sentence and the selection's re-based offsets within it.
/// When [text] is empty (or trims to empty) the result is an empty sentence with
/// zero offsets, and the caller falls back to the bare selected term.
SentenceExtractionResult extractSentenceAt(
  String text,
  int selStart,
  int selLen,
) {
  if (text.isEmpty) {
    return const SentenceExtractionResult(sentence: '', selStart: 0, selLen: 0);
  }
  // Clamp the selection into the buffer so the walk never indexes out of range.
  final int len = text.length;
  final int start = selStart < 0 ? 0 : (selStart > len ? len : selStart);
  final int rawEnd = selStart + selLen;
  final int end = rawEnd < start ? start : (rawEnd > len ? len : rawEnd);

  // Walk BACKWARD from the selection start: the sentence begins right AFTER the
  // nearest preceding delimiter (or at buffer start when none is found).
  int sentenceStart = 0;
  for (int i = start - 1; i >= 0; i--) {
    if (kSentenceDelimiters.contains(text[i])) {
      sentenceStart = i + 1;
      break;
    }
  }

  // Walk FORWARD from the selection end: the sentence ends AT the nearest
  // following delimiter (inclusive), then swallows any trailing closing
  // punctuation. When none is found the sentence runs to the buffer end.
  int sentenceEnd = len;
  for (int j = end; j < len; j++) {
    if (kSentenceDelimiters.contains(text[j])) {
      int e = j + 1;
      while (e < len && kTrailingSentenceChars.contains(text[e])) {
        e++;
      }
      sentenceEnd = e;
      break;
    }
  }

  final String rawSentence = text.substring(sentenceStart, sentenceEnd);
  // Re-base the selection into the raw (un-trimmed) sentence first, then account
  // for any leading whitespace the trim strips (mirrors the reader's
  // leadingTrim / sentenceOffset math).
  final int rawSelStart = start - sentenceStart;
  final String trimmed = rawSentence.trim();
  final int leadingTrim = rawSentence.length - rawSentence.trimLeft().length;

  int reSelStart = rawSelStart - leadingTrim;
  if (reSelStart < 0) reSelStart = 0;
  if (reSelStart > trimmed.length) reSelStart = trimmed.length;
  int reSelLen = end - start;
  if (reSelStart + reSelLen > trimmed.length) {
    reSelLen = trimmed.length - reSelStart;
  }
  if (reSelLen < 0) reSelLen = 0;

  return SentenceExtractionResult(
    sentence: trimmed,
    selStart: reSelStart,
    selLen: reSelLen,
  );
}
