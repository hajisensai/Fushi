import 'package:fushi_audio/fushi_audio.dart';
import 'package:html/dom.dart' as dom;

import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi_engine/stats/study_char_count.dart';

/// Converts audio UTF-16 positions to the reader's completed learning units.
/// Each original DOM text node retains its own word boundary, matching
/// fushiReader.buildNodeOffsets and fushiStudyUnits.isUnitEnd.
class ReaderAudioPositionIndex {
  ReaderAudioPositionIndex._(this._text, this._studyOffsets, this._studyEnds);

  factory ReaderAudioPositionIndex.fromChapterHtml(String html) {
    final dom.Document document = EpubBook.parseChapterHtml(html);
    final StringBuffer normalized = StringBuffer();
    final List<int> offsets = <int>[];
    final List<int> studyEnds = <int>[];
    int studyOffset = 0;

    void visit(dom.Node node) {
      if (node is dom.Element &&
          const <String>{'rt', 'rp', 'rtc'}.contains(node.localName)) {
        return;
      }
      if (node is dom.Text) {
        final List<int> runes = node.data.runes.toList(growable: false);
        final List<int> kinds = runes.map(_classify).toList(growable: false);
        final List<bool> ends = List<bool>.filled(runes.length, false);
        int nextKind = 3;
        for (int i = runes.length - 1; i >= 0; i--) {
          final int kind = kinds[i];
          ends[i] = kind == 1 || (kind == 2 && nextKind != 2);
          if (kind != 0) nextKind = kind;
        }
        for (int i = 0; i < runes.length; i++) {
          final int folded = AudioTextNormalizer.foldCodePoint(runes[i]);
          final int studyEnd = studyOffset + (ends[i] ? 1 : 0);
          if (folded >= 0) {
            normalized.writeCharCode(folded);
            offsets.add(studyOffset);
            studyEnds.add(studyEnd);
            if (folded > 0xffff) {
              offsets.add(studyOffset);
              studyEnds.add(studyEnd);
            }
          }
          if (ends[i]) studyOffset++;
        }
        return;
      }
      for (final dom.Node child in node.nodes) {
        visit(child);
      }
    }

    final dom.Element? body = document.body;
    if (body != null) visit(body);
    offsets.add(studyOffset);
    return ReaderAudioPositionIndex._(
      normalized.toString(),
      offsets,
      studyEnds,
    );
  }

  final String _text;
  final List<int> _studyOffsets;
  final List<int> _studyEnds;

  /// Finds a cue without persisted coordinates only when its normalized text
  /// occurs once in this chapter. Existing fragments must continue to use
  /// [studyRangeForFragment], including fuzzy ASR matches.
  ({int offset, int length})? studyRangeForUniqueText(String text) {
    final String needle = AudioTextNormalizer.normalize(text);
    if (needle.isEmpty) return null;
    final int start = _text.indexOf(needle);
    if (start < 0 || _text.indexOf(needle, start + 1) >= 0) return null;
    return studyRangeForFragment(
      matchableStart: start,
      matchableEnd: start + needle.length,
    );
  }

  /// The persisted fragment identifies an upstream-matched EPUB span. Subtitle
  /// text may intentionally differ (fuzzy matching / ASR), so this conversion
  /// validates coordinates rather than redoing matching or searching by text.
  ({int offset, int length})? studyRangeForFragment({
    required int matchableStart,
    required int matchableEnd,
  }) {
    if (matchableStart < 0 ||
        matchableEnd <= matchableStart ||
        matchableEnd > _text.length ||
        !_isCodePointBoundary(matchableStart) ||
        !_isCodePointBoundary(matchableEnd)) {
      return null;
    }
    final int start = _studyOffsets[matchableStart];
    return (offset: start, length: _studyEnds[matchableEnd - 1] - start);
  }

  bool _isCodePointBoundary(int offset) =>
      offset == _text.length ||
      _text.codeUnitAt(offset) < 0xdc00 ||
      _text.codeUnitAt(offset) > 0xdfff;

  static int _classify(int rune) {
    final String char = String.fromCharCode(rune);
    if (kStudyTransparentPattern.hasMatch(char)) return 0;
    if (!kStudyLetterOrNumberPattern.hasMatch(char)) return 3;
    return kStudyNoSpaceScriptPattern.hasMatch(char) ? 1 : 2;
  }
}
