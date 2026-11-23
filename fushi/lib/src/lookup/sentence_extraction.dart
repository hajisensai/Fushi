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
// reader_selection_scripts.dart (fushiSelection.getSentenceContext): walk
// BACKWARD from the selection start until a sentence delimiter (that delimiter
// is NOT included — the sentence begins after it), then FORWARD from the
// selection end until a delimiter (that delimiter IS included, plus any trailing
// closing punctuation). One deliberate refinement over the JS walk: closing
// punctuation right after the preceding delimiter is skipped at the START too,
// since the forward rule already gives it to the previous sentence (so 「…。」X
// yields X…, not 」X…, and neighbouring sentences tile the buffer without
// overlap). The only structural difference is the input model: the
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

/// 逐字查词时喂给引擎的查询串上限（UTF-16 code unit）。
///
/// 引擎按查询串做**最长匹配**并回报 `bestLength`，所以只要「足够长到装得下最长的
/// 复合词 + 屈折尾巴」即可；给整行会让每次点击都多传几十上百个用不到的字符。日语
/// 最长实用复合词远短于 24。（BUG-1478：原先只在 texthooker_page 里当私有常量。）
const int kLookupQueryMaxChars = 24;

/// 从命中字 [charIndex] 起截一段查询串（UTF-16 下标域，与 Dart String 下标一致）。
///
/// 这是全 app「给定整句 + 光标字符偏移 → 查词」的统一入口形状：**不做分词**，把
/// 「从这个字到后面 [maxChars] 个字」整段交给引擎做最长匹配。点「永」照样命中
/// 「永遠」，点「遠」能单独查到「遠」——把分词器切出的整词当查询串则后者无从下手
/// （BUG-1478）。越界 / 空白返回空串，调用方据此放弃本次查词。
String lookupQueryFromIndex(
  String text,
  int charIndex, {
  int maxChars = kLookupQueryMaxChars,
}) {
  if (charIndex < 0 || charIndex >= text.length) return '';
  final int end = charIndex + maxChars > text.length
      ? text.length
      : charIndex + maxChars;
  final String query = text.substring(charIndex, end);
  return query.trim().isEmpty ? '' : query;
}

/// Sentence-terminating delimiters. Byte-identical to
/// `fushiSelection.sentenceDelimiters` in reader_selection_scripts.dart
/// ('。！？.!?\n\r'): the char AFTER one of these starts a new sentence.
const String kSentenceDelimiters = '。！？.!?\n\r';

/// Trailing closing punctuation pulled INTO the sentence after its terminating
/// delimiter. Byte-identical to `fushiSelection.trailingSentenceChars`
/// ('。、！？…‥」』）)】〉》〕｝}］]').
const String kTrailingSentenceChars = '。、！？…‥」』）)】〉》〕｝}］]';

/// Raw (untrimmed) bounds `[start, end)` of the sentence around the clamped
/// selection `[start, end)` inside [text], using the delimiter tables above:
/// the sentence begins right AFTER the nearest delimiter before [start] (buffer
/// start when none) and ends AT the nearest delimiter from [end] on (inclusive,
/// plus trailing closing punctuation; buffer end when none). The single
/// splitter behind [extractSentenceAt] and the captured-context sentence list
/// (`captured_context_sentences.dart`), so both cut the same sentences.
/// [start] / [end] must already lie within `0..text.length` with start <= end.
({int start, int end}) sentenceBoundsAt(String text, int start, int end) {
  final int len = text.length;
  // Walk BACKWARD from the selection start: the sentence begins right AFTER the
  // nearest preceding delimiter (or at buffer start when none is found).
  int sentenceStart = 0;
  for (int i = start - 1; i >= 0; i--) {
    if (kSentenceDelimiters.contains(text[i])) {
      sentenceStart = i + 1;
      // The closing punctuation right after that delimiter belongs to the
      // PREVIOUS sentence (the forward walk below swallows it into its end), so
      // skip it here too — otherwise 「…。」彼は… starts this sentence with a
      // stray 」 and adjacent sentences overlap (rf--UcsGta neighbour split).
      // Never past the selection itself.
      while (sentenceStart < start &&
          kTrailingSentenceChars.contains(text[sentenceStart])) {
        sentenceStart++;
      }
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
  return (start: sentenceStart, end: sentenceEnd);
}

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
  final ({int start, int end}) bounds = sentenceBoundsAt(text, start, end);
  final int sentenceStart = bounds.start;
  final int sentenceEnd = bounds.end;

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
