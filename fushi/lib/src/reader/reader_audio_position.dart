import 'dart:typed_data';

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

    // 整章文本一次过原生归一化（不逐码点跨 FFI）。节点之间插 U+0000：它不在白名单里、
    // 必被丢弃，且挡住相邻节点首尾的孤立代理拼成一个代理对——归一化仍按节点逐个
    // `runes` 解码的旧口径。
    final String joined = texts.join('\u0000');
    // 每个输入码点起始码元 → 它的学习单位起点 / 终点（每个 DOM 文本节点各自断词，
    // 与 fushiReader.buildNodeOffsets / fushiStudyUnits.isUnitEnd 一致）。
    final Int32List offsetAt = Int32List(joined.length);
    final Int32List endAt = Int32List(joined.length);
    int studyOffset = 0;
    int base = 0;
    for (final String data in texts) {
      final List<int> runes = data.runes.toList(growable: false);
      final List<int> kinds = runes.map(_classify).toList(growable: false);
      final List<bool> ends = List<bool>.filled(runes.length, false);
      int nextKind = 3;
      for (int i = runes.length - 1; i >= 0; i--) {
        final int kind = kinds[i];
        ends[i] = kind == 1 || (kind == 2 && nextKind != 2);
        if (kind != 0) nextKind = kind;
      }
      int unit = base;
      for (int i = 0; i < runes.length; i++) {
        offsetAt[unit] = studyOffset;
        endAt[unit] = studyOffset + (ends[i] ? 1 : 0);
        if (ends[i]) studyOffset++;
        unit += runes[i] > 0xffff ? 2 : 1;
      }
      base += data.length + 1;
    }

    final NormalizedTextWithOffsets folded =
        AudioTextNormalizer.normalizeWithOffsets(joined);
    final List<int> starts = folded.starts;
    final List<int> offsets = List<int>.filled(starts.length + 1, 0);
    final List<int> studyEnds = List<int>.filled(starts.length, 0);
    for (int j = 0; j < starts.length; j++) {
      offsets[j] = offsetAt[starts[j]];
      studyEnds[j] = endAt[starts[j]];
    }
    offsets[starts.length] = studyOffset;
    return ReaderAudioPositionIndex._(folded.text, offsets, studyEnds);
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

  static int _classify(int rune) => switch (studyCharClassOf(rune)) {
    StudyCharClass.transparent => 0,
    StudyCharClass.perCodePoint => 1,
    StudyCharClass.word => 2,
    StudyCharClass.breaker => 3,
  };
}
