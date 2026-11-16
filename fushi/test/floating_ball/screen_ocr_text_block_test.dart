import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/floating_ball/screen_ocr_text_block.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';

/// BUG-4707：只有行框的截屏识字（桌面冻结层 / iOS 截屏 / 拍照）点字时，查词串要
/// 跨过 OCR 折行接上同一文本块的后续行，制卡句子取块里的整句——此前只用被点那一行，
/// 词被折到下一行就在行尾截断。
void main() {
  SystemOcrTextLine h(String text, double l, double t, double r, double b) =>
      SystemOcrTextLine(
        text: text,
        rect: Rect.fromLTRB(l, t, r, b),
        isVertical: false,
      );
  SystemOcrTextLine v(String text, double l, double t, double r, double b) =>
      SystemOcrTextLine(
        text: text,
        rect: Rect.fromLTRB(l, t, r, b),
        isVertical: true,
      );

  test('horizontal: the wrapped word continues on the next line '
      '(lines joined in reading order, not list order)', () {
    final SystemOcrTextLine first = h('今日は良い天', 100, 100, 400, 130);
    final SystemOcrTextLine second = h('気ですね。', 100, 140, 300, 170);
    final SystemOcrTextLine other = h('別の段落', 100, 400, 300, 430);
    final ScreenOcrBlockLookup lookup = screenOcrBlockLookupForHit(
      // 识别器给的顺序不保证是阅读顺序。
      lines: <SystemOcrTextLine>[second, other, first],
      hit: first,
      charIndex: 5,
    );
    expect(lookup.text, '今日は良い天気ですね。');
    expect(lookup.text.substring(5), '天気ですね。', reason: '行内下标原样有效，从被点字起的后缀跨过折行');
    expect(lookup.sentence, '今日は良い天気ですね。');
  });

  test('vertical: columns are read right to left', () {
    final SystemOcrTextLine right = v('吾輩は', 400, 100, 430, 500);
    final SystemOcrTextLine left = v('猫である。', 360, 100, 390, 500);
    final ScreenOcrBlockLookup lookup = screenOcrBlockLookupForHit(
      lines: <SystemOcrTextLine>[left, right],
      hit: right,
      charIndex: 2,
    );
    expect(lookup.text, '吾輩は猫である。');
    expect(lookup.sentence, '吾輩は猫である。');
  });

  test('Latin: a wrapped word resumes after one space', () {
    final SystemOcrTextLine first = h('I like the', 100, 100, 400, 130);
    final SystemOcrTextLine second = h('weather today.', 100, 140, 420, 170);
    final ScreenOcrBlockLookup lookup = screenOcrBlockLookupForHit(
      lines: <SystemOcrTextLine>[first, second],
      hit: first,
      charIndex: 7,
    );
    expect(lookup.text, 'I like the weather today.');
    expect(lookup.sentence, 'I like the weather today.');
  });

  test('the last line of a block gets no continuation; its sentence still '
      'starts on the previous line', () {
    final SystemOcrTextLine first = h('今日は良い天', 100, 100, 400, 130);
    final SystemOcrTextLine second = h('気ですね。', 100, 140, 300, 170);
    final ScreenOcrBlockLookup lookup = screenOcrBlockLookupForHit(
      lines: <SystemOcrTextLine>[first, second],
      hit: second,
      charIndex: 0,
    );
    expect(lookup.text, '気ですね。');
    expect(lookup.sentence, '今日は良い天気ですね。');
  });

  test('a lone line keeps the in-line sentence', () {
    final SystemOcrTextLine only = h('まだ早い。もう行く。', 100, 100, 400, 130);
    final ScreenOcrBlockLookup lookup = screenOcrBlockLookupForHit(
      lines: <SystemOcrTextLine>[only],
      hit: only,
      charIndex: 6,
    );
    expect(lookup.text, 'まだ早い。もう行く。');
    expect(lookup.sentence, 'もう行く。');
  });
}
