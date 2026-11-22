import 'package:characters/characters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/subtitle_word_sweep.dart';

/// 字幕句分词纯逻辑层的行为测试（无 WebView / 无页面态 / 不依赖词典引擎）。
///
/// 生产侧默认分词器是 [JapaneseLanguage.textToWords]（需要引擎就绪），这里注入确定性
/// 的假分词器，把「分词结果 → grapheme 下标」的折算契约钉死。
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

  group('buildSubtitleSweepTokens：分词碎片劈开 grapheme（BUG-3086）', () {
    List<int> starts(List<SubtitleSweepToken> ts) =>
        ts.map((SubtitleSweepToken t) => t.graphemeStart).toList();
    List<int> ends(List<SubtitleSweepToken> ts) =>
        ts.map((SubtitleSweepToken t) => t.graphemeEnd).toList();
    List<String> words(List<SubtitleSweepToken> ts) =>
        ts.map((SubtitleSweepToken t) => t.word).toList();

    test('代理对被逐码元切成两半：后半并入前一词，之后的词不整体错位', () {
      // 引擎未命中时 textToWords 按 `text[pos]` 逐码元切：😀 变成两个半码元碎片。
      const String sentence = '😀あい';
      final List<SubtitleSweepToken> tokens = buildSubtitleSweepTokens(
        sentence,
        tokenize: fake(const <String>['\uD83D', '\uDE00', 'あ', 'い']),
      );
      expect(words(tokens), <String>['😀', 'あ', 'い']);
      // 旧实现按碎片个数累加 grapheme：得 [0, 1, 2, 3]，「あ」指向「い」、「い」越界。
      expect(starts(tokens), <int>[0, 1, 2]);
      expect(ends(tokens), <int>[1, 2, 3]);
      final List<String> graphemes = sentence.characters.toList();
      expect(graphemes[tokens[1].graphemeStart], 'あ');
      expect(graphemes[tokens[2].graphemeStart], 'い');
    });

    test('组合浊点（か + ゛）被切成两段：浊点并入前一词', () {
      const String sentence = 'か\u3099くせい';
      expect(sentence.characters.length, 4);
      final List<SubtitleSweepToken> tokens = buildSubtitleSweepTokens(
        sentence,
        tokenize: fake(const <String>['か', '\u3099', 'く', 'せい']),
      );
      expect(words(tokens), <String>['か\u3099', 'く', 'せい']);
      expect(starts(tokens), <int>[0, 1, 2]);
      expect(ends(tokens), <int>[1, 2, 4]);
    });

    test('词尾落在 grapheme 中间：区间右端向上取整，下一段并入', () {
      // 「あか」+「゛い」：第一词结束在 か 与浊点之间。
      const String sentence = 'あか\u3099い';
      final List<SubtitleSweepToken> tokens = buildSubtitleSweepTokens(
        sentence,
        tokenize: fake(const <String>['あか', '\u3099い']),
      );
      expect(words(tokens), <String>['あか\u3099い']);
      expect(starts(tokens), <int>[0]);
      expect(ends(tokens), <int>[3]);
    });

    test('纯 emoji 句（多个代理对，逐码元切）', () {
      const String sentence = '😀😁';
      final List<SubtitleSweepToken> tokens = buildSubtitleSweepTokens(
        sentence,
        tokenize: (String text) => <String>[
          for (int i = 0; i < text.length; i++) text[i],
        ],
      );
      expect(words(tokens), <String>['😀', '😁']);
      expect(starts(tokens), <int>[0, 1]);
      expect(ends(tokens), <int>[1, 2]);
    });

    test('空句：不调用分词器，直接空表', () {
      bool called = false;
      expect(
        buildSubtitleSweepTokens(
          '',
          tokenize: (String _) {
            called = true;
            return const <String>[];
          },
        ),
        isEmpty,
      );
      expect(called, isFalse);
    });

    test('分词结果比原文长（违反不变式）：超出部分被忽略，不越界', () {
      final List<SubtitleSweepToken> tokens = buildSubtitleSweepTokens(
        'あい',
        tokenize: fake(const <String>['あい', 'う', 'え']),
      );
      expect(words(tokens), <String>['あい']);
      expect(ends(tokens), <int>[2]);
    });
  });
}
