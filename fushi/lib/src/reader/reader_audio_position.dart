import 'dart:typed_data';

import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_compute/fushi_compute.dart' show AudioTextFoldNative;
import 'package:html/dom.dart' as dom;

import 'package:fushi_engine/epub/epub_book.dart';

/// Converts audio UTF-16 positions to the reader's completed learning units.
/// Each original DOM text node retains its own word boundary, matching
/// fushiReader.buildNodeOffsets and fushiStudyUnits.isUnitEnd.
class ReaderAudioPositionIndex {
  ReaderAudioPositionIndex._(this._text, this._studyOffsets, this._studyEnds);

  factory ReaderAudioPositionIndex.fromChapterHtml(String html) {
    final dom.Document document = EpubBook.parseChapterHtml(html);
    final List<String> texts = <String>[];

    void visit(dom.Node node) {
      if (node is dom.Element &&
          const <String>{'rt', 'rp', 'rtc'}.contains(node.localName)) {
        return;
      }
      if (node is dom.Text) {
        texts.add(node.data);
        return;
      }
      for (final dom.Node child in node.nodes) {
        visit(child);
      }
    }

    final dom.Element? body = document.body;
    if (body != null) visit(body);

    // 整章文本一次 FFI 算完归一化与学习单位坐标（不逐码点跨 FFI，学习单位分类也在原生侧）。
    // 节点之间插 U+0000：它是断词码点、不在归一化白名单里，所以整段一次扫描等于逐节点各自
    // `runes` 解码、各自断词（与 fushiReader.buildNodeOffsets / fushiStudyUnits.isUnitEnd
    // 一致），也挡住相邻节点首尾的孤立代理拼成一个代理对。
    final ({String text, Uint32List offsets, Uint32List ends, int total})
    folded = AudioTextFoldNative.instance.foldStudy(texts.join('\u0000'));
    final Uint32List offsets = Uint32List(folded.offsets.length + 1)
      ..setAll(0, folded.offsets);
    offsets[folded.offsets.length] = folded.total;
    return ReaderAudioPositionIndex._(folded.text, offsets, folded.ends);
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
}
