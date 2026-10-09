import 'package:characters/characters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/subtitle_word_sweep.dart';

/// 视频暂停句「整句扫词」纯逻辑层的行为测试（无 WebView / 无页面态 / 不依赖词典引擎）。
///
/// 生产侧默认分词器是 [JapaneseLanguage.textToWords]（需要引擎就绪），这里注入确定性
/// 的假分词器，把「分词结果 → grapheme 下标」的折算与「游标循环推进」两条契约钉死。
void main() {
  // 假分词器：无视输入、直接返回给定切分。形状与生产一致（按序拼接回原文）。
  SubtitleSweepTokenizer fake(List<String> parts) =>
      (String _) => parts;

  group('buildSubtitleSweepTokens', () {
    test('每个词的首字下标是 grapheme（纯汉字下与码元相等）', () {
      const String sentence = '家ではないだろ';
      final List<SubtitleSweepToken> tokens = buildSubtitleSweepTokens(
        sentence,
        tokenize: fake(const <String>['家', 'では', 'ない', 'だろ']),
      );
      expect(tokens.map((SubtitleSweepToken t) => t.word).toList(), <String>[
        '家',
        'では',
        'ない',
        'だろ',
      ]);
      expect(
        tokens.map((SubtitleSweepToken t) => t.graphemeStart).toList(),
        <int>[0, 1, 3, 5],
      );
    });

    test('切分不变式：各词按序拼回即原文', () {
      const String sentence = '今日はいい天気ですね';
      final List<SubtitleSweepToken> tokens = buildSubtitleSweepTokens(
        sentence,
        tokenize: fake(const <String>['今日', 'は', 'いい', '天気', 'です', 'ね']),
      );
      expect(tokens.map((SubtitleSweepToken t) => t.word).join(), sentence);
    });

    test('下标 → 词 一致：characters.skip(start).take(len) == word', () {
      const String sentence = '家ではないだろ';
      final List<String> graphemes = sentence.characters.toList();
      final List<SubtitleSweepToken> tokens = buildSubtitleSweepTokens(
        sentence,
        tokenize: fake(const <String>['家', 'では', 'ない', 'だろ']),
      );
      for (final SubtitleSweepToken t in tokens) {
        final String slice = graphemes
            .skip(t.graphemeStart)
            .take(t.word.characters.length)
            .join();
        expect(
          slice,
          t.word,
          reason: '下标 ${t.graphemeStart} 处应切出「${t.word}」而不是「$slice」',
        );
      }
    });

    test('「索引与引擎词条一致」：该下标起的后缀以扫词单元开头（不错位）', () {
      // 回归「扫到第 3 个位置、弹窗显示别的词」：扫描单元必须是被查后缀的前缀。
      const String sentence = '私は学生です';
      final List<SubtitleSweepToken> tokens = buildSubtitleSweepTokens(
        sentence,
        tokenize: fake(const <String>['私', 'は', '学生', 'です']),
      );
      for (final SubtitleSweepToken t in tokens) {
        final String suffix = sentence.characters.skip(t.graphemeStart).join();
        expect(
          suffix.startsWith(t.word),
          isTrue,
          reason: '「${t.word}」应是下标 ${t.graphemeStart} 处后缀「$suffix」的前缀',
        );
      }
    });

    test('组合字符（浊点）按 grapheme 计数，不按 UTF-16 码元', () {
      // 「が」= か(U+304B) + 浊点(U+3099)：2 个码元、1 个 grapheme。
      const String ga = 'か\u3099';
      const String sentence =
          '$ga'
          'くせい';
      expect(ga.length, 2); // 码元
      expect(ga.characters.length, 1); // grapheme
      final List<SubtitleSweepToken> tokens = buildSubtitleSweepTokens(
        sentence,
        tokenize: fake(<String>[ga, 'く', 'せい']),
      );
      // 若误用 UTF-16 偏移会得到 [0, 2, 3]；grapheme 空间是 [0, 1, 2]。
      expect(
        tokens.map((SubtitleSweepToken t) => t.graphemeStart).toList(),
        <int>[0, 1, 2],
      );
    });

    test('emoji（代理对）按 grapheme 计数', () {
      const String sentence = '😀あい';
      expect(sentence.length, 4); // 码元
      expect(sentence.characters.length, 3); // grapheme
      final List<SubtitleSweepToken> tokens = buildSubtitleSweepTokens(
        sentence,
        tokenize: fake(const <String>['😀', 'あ', 'い']),
      );
      expect(
        tokens.map((SubtitleSweepToken t) => t.graphemeStart).toList(),
        <int>[0, 1, 2],
      );
    });

    test('空句 → 空表', () {
      expect(buildSubtitleSweepTokens(''), isEmpty);
    });

    test('空词被跳过，且不推进下标', () {
      final List<SubtitleSweepToken> tokens = buildSubtitleSweepTokens(
        'あい',
        tokenize: fake(const <String>['', 'あ', '', 'い']),
      );
      expect(tokens.map((SubtitleSweepToken t) => t.word).toList(), <String>[
        'あ',
        'い',
      ]);
      expect(
        tokens.map((SubtitleSweepToken t) => t.graphemeStart).toList(),
        <int>[0, 1],
      );
    });
  });

  group('advanceSubtitleSweepIndex', () {
    test('前进到句尾后循环回句首', () {
      expect(advanceSubtitleSweepIndex(0, 3, forward: true), 1);
      expect(advanceSubtitleSweepIndex(1, 3, forward: true), 2);
      expect(advanceSubtitleSweepIndex(2, 3, forward: true), 0);
    });

    test('后退到句首后循环回句尾', () {
      expect(advanceSubtitleSweepIndex(0, 3, forward: false), 2);
      expect(advanceSubtitleSweepIndex(2, 3, forward: false), 1);
    });

    test('N=1 恒停在 0（两个方向都不越界）', () {
      expect(advanceSubtitleSweepIndex(0, 1, forward: true), 0);
      expect(advanceSubtitleSweepIndex(0, 1, forward: false), 0);
    });

    test('N=0 恒 -1（调用方据此早退）', () {
      expect(advanceSubtitleSweepIndex(-1, 0, forward: true), -1);
      expect(advanceSubtitleSweepIndex(0, 0, forward: false), -1);
    });

    test('尚未开始（-1）：前进落首词、后退落末词', () {
      expect(advanceSubtitleSweepIndex(-1, 3, forward: true), 0);
      expect(advanceSubtitleSweepIndex(-1, 3, forward: false), 2);
    });

    test('越界下标被夹回端点，不越界', () {
      expect(advanceSubtitleSweepIndex(5, 3, forward: true), 0);
      expect(advanceSubtitleSweepIndex(5, 3, forward: false), 2);
    });

    test('完整走一圈回到起点（N=5）', () {
      int i = -1;
      final List<int> visited = <int>[];
      for (int step = 0; step < 5; step++) {
        i = advanceSubtitleSweepIndex(i, 5, forward: true);
        visited.add(i);
      }
      expect(visited, <int>[0, 1, 2, 3, 4]);
      expect(advanceSubtitleSweepIndex(i, 5, forward: true), 0);
    });
  });
}
