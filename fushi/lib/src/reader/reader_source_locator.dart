import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi_engine/stats/study_char_count.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:html/dom.dart' as dom;

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
