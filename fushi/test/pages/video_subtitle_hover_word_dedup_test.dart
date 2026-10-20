import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';

/// 画面字幕悬停查词的「同一个词」去重（查词卡顿：划过一个三字词原先连查三次）。
void main() {
  const String sentence = '今日は天気がいい。hello world';
  bool same({
    required int grapheme,
    int? cueStartMs = 1000,
    String lastSentence = sentence,
    required int lastSpanStart,
    SubtitleLookupHighlight? highlight,
    String current = sentence,
  }) => isSameSubtitleHoverWord(
    sentence: current,
    graphemeIndex: grapheme,
    spanStart: subtitleLookupSpan(current, grapheme).start,
    cueStartMs: cueStartMs,
    lastSentence: lastSentence,
    lastSpanStart: lastSpanStart,
    activeHighlight: highlight,
  );

  // 引擎回报命中「天気」（起点 3，两个字位）。
  const SubtitleLookupHighlight tenki = SubtitleLookupHighlight(
    sentence: sentence,
    cueStartMs: 1000,
    graphemeStart: 3,
    graphemeCount: 2,
  );

  test('moving across the matched word does not look it up again', () {
    expect(same(grapheme: 3, lastSpanStart: 3, highlight: tenki), isTrue);
    expect(same(grapheme: 4, lastSpanStart: 3, highlight: tenki), isTrue);
  });

  test('leaving the matched word looks up the next one', () {
    expect(same(grapheme: 5, lastSpanStart: 3, highlight: tenki), isFalse);
    expect(same(grapheme: 2, lastSpanStart: 3, highlight: tenki), isFalse);
  });

  test('highlight of another cue or sentence does not suppress', () {
    expect(
      same(grapheme: 4, cueStartMs: 2000, lastSpanStart: -1, highlight: tenki),
      isFalse,
    );
    expect(
      same(grapheme: 4, cueStartMs: null, lastSpanStart: -1, highlight: tenki),
      isFalse,
    );
    expect(
      same(
        grapheme: 4,
        current: '別の文です。',
        lastSentence: '別の文です。',
        lastSpanStart: -1,
        highlight: tenki,
      ),
      isFalse,
    );
  });

  test('letters of one Latin word share the lookup start before results', () {
    // "hello" 起于字位 9：任一字母的查词起点都回退到词首。
    final int helloStart = subtitleLookupSpan(sentence, 12).start;
    expect(helloStart, 9);
    expect(same(grapheme: 13, lastSpanStart: helloStart), isTrue);
    expect(same(grapheme: 16, lastSpanStart: helloStart), isFalse);
    expect(
      same(grapheme: 12, lastSentence: 'other', lastSpanStart: helloStart),
      isFalse,
    );
  });

  test('a reset dedup key never suppresses', () {
    expect(same(grapheme: 0, lastSentence: '', lastSpanStart: -1), isFalse);
  });
}
