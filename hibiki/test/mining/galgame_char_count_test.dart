import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/galgame_char_count.dart';

void main() {
  group('countGalgameChars（纯口径：标点不计 · CJK 每字 · 西文每串）', () {
    test('纯假名/汉字每字计 1', () {
      expect(countGalgameChars('あいうえお'), 5);
      expect(countGalgameChars('私は学生です'), 6);
      expect(countGalgameChars('한국어'), 3);
    });

    test('标点、括号、排版符号、空白不计', () {
      expect(countGalgameChars('「こんにちは、世界。」'), 7);
      expect(countGalgameChars('…！？♪　─'), 0);
      expect(countGalgameChars('え、えっと……その'), 6);
      expect(countGalgameChars('　\t\n'), 0);
    });

    test('西文按连续串计 1（对齐 Luna count_words_mixed）', () {
      expect(countGalgameChars('Hello world'), 2);
      expect(countGalgameChars('彼はHelloと言った'), 7);
      expect(countGalgameChars('ＡＢＣ　ｄｅｆ'), 2);
      expect(countGalgameChars('2026年7月25日'), 6);
    });

    test('增补面汉字按 code point 计 1（不因 UTF-16 代理对双计）', () {
      expect(countGalgameChars('𠮟る'), 2);
    });

    test('半角片假名与迭代符计数', () {
      expect(countGalgameChars('ｱｲｳｴｵ'), 5);
      expect(countGalgameChars('人々'), 2);
    });

    test('空串为 0', () {
      expect(countGalgameChars(''), 0);
    });
  });

  group('GalgameLineCharCounter（会话态：去重 · 递增 · 长度门）', () {
    test('相邻重复行计 0，非相邻重复照计', () {
      final GalgameLineCharCounter counter = GalgameLineCharCounter();
      expect(counter.countLine('こんにちは'), 5);
      expect(counter.countLine('こんにちは'), 0);
      expect(counter.countLine('さようなら'), 5);
      expect(counter.countLine('こんにちは'), 5);
    });

    test('trim 后比对：首尾空白不同的同句仍判重复', () {
      final GalgameLineCharCounter counter = GalgameLineCharCounter();
      expect(counter.countLine('こんにちは'), 5);
      expect(counter.countLine('　こんにちは　'), 0);
    });

    test('打字机递增行只计增量，总和等于整句一次到达', () {
      final GalgameLineCharCounter counter = GalgameLineCharCounter();
      int total = 0;
      for (final String line in <String>[
        'あ',
        'あり',
        'ありが',
        'ありがと',
        'ありがとう',
      ]) {
        total += counter.countLine(line);
      }
      expect(total, countGalgameChars('ありがとう'));
    });

    test('递增行末尾追加标点不产生增量', () {
      final GalgameLineCharCounter counter = GalgameLineCharCounter();
      expect(counter.countLine('ありがとう'), 5);
      expect(counter.countLine('ありがとう……！'), 0);
    });

    test('非前缀关系的新行按整行计', () {
      final GalgameLineCharCounter counter = GalgameLineCharCounter();
      expect(counter.countLine('ありがとう'), 5);
      expect(counter.countLine('とうもろこし'), 6);
    });

    test('清洗后超长垃圾行计 0，且仍参与后续相邻去重', () {
      final GalgameLineCharCounter counter =
          GalgameLineCharCounter(maxCountedChars: 10);
      final String dump = 'あ' * 11;
      expect(counter.countLine(dump), 0);
      expect(counter.countLine(dump), 0);
      expect(counter.countLine('こんにちは'), 5);
    });

    test('reset 后不再与上一会话的行做去重/前缀比对', () {
      final GalgameLineCharCounter counter = GalgameLineCharCounter();
      expect(counter.countLine('こんにちは'), 5);
      counter.reset();
      expect(counter.countLine('こんにちは'), 5);
    });

    test('空行/纯空白行计 0 且不覆盖上一行状态', () {
      final GalgameLineCharCounter counter = GalgameLineCharCounter();
      expect(counter.countLine('こんにちは'), 5);
      expect(counter.countLine('   '), 0);
      expect(counter.countLine('こんにちは'), 0);
    });
  });
}
