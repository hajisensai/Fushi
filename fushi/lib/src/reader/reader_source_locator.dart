import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi_engine/stats/study_char_count.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:html/dom.dart' as dom;

/// 小说卡片来源（[CardSourceLink.charOffset] / [CardSourceLink.charLength]）与制卡
/// 历史（`mined_sentences.norm_char_offset/length`）记的章内范围：**学习单位口径**
/// （JS `getNormalizedOffset` / `nodeStartOffsets`，即选区 payload 的
/// `sentenceNormalizedOffset` / `normalizedOffset`）。回看时这对值原样变成
/// `Bookmark.charAnchor`，由 `scrollToCharOffset` 与落点句标记按同一口径落位，
/// [validateReaderSourceLocator] 也按同一口径校验。
///
/// 句级 span 优先（回看标出的是「那一句」），没有句级 span 才退到选区。
///
/// **不能**传音频匹配坐标（`matchableOffset` / `sentenceMatchableOffset`）：那是
/// 有声书 cue 匹配用的白名单 UTF-16 码元数，拉丁 / 数字逐字母计、全角符号等计法
/// 都和学习单位不同，拿去当回看锚点会让高亮整体错位（BUG：小说卡片来源回看高亮
/// 落到后面的词上）。
({int offset, int length})? readerSourceStudySpan({
  required ({int offset, int length})? sentence,
  required ({int offset, int length, String text})? selection,
}) {
  if (sentence != null) return sentence;
  if (selection != null) {
    return (offset: selection.offset, length: selection.length);
  }
  return null;
}

/// Reject stale source coordinates before the ordinary bookmark fallback runs.
/// Count each DOM text node separately, as the reader's nodeStartOffsets and
/// getNormalizedOffset do; plain-text length and cached book statistics use
/// different coordinates (especially around ruby and inline Latin text).
void validateReaderSourceLocator(EpubBook book, CardSourceLink link) {
  final int? chapter = link.chapterIndex;
  if (link.kind != CardSourceKind.book ||
      chapter == null ||
      chapter < 0 ||
      chapter >= book.chapters.length) {
    throw const FormatException('Source chapter no longer exists');
  }
  final dom.Element? body = EpubBook.parseChapterHtml(
    book.chapters[chapter].html,
  ).body;
  final int total = body == null ? 0 : _sourceNodeUnits(body);
  final int? start = link.charOffset;
  final int length = link.charLength ?? 0;
  if (start == null ||
      start < 0 ||
      length < 0 ||
      (total == 0 ? start != 0 || length != 0 : start >= total) ||
      length > total - start) {
    throw const FormatException('Source character range no longer exists');
  }
}

int _sourceNodeUnits(dom.Node node) {
  if (node is dom.Text) return countStudyChars(node.data);
  if (node is dom.Element &&
      (node.localName == 'rt' || node.localName == 'rp')) {
    return 0;
  }
  int total = 0;
  for (final dom.Node child in node.nodes) {
    total += _sourceNodeUnits(child);
  }
  return total;
}
