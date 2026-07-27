// 注音标记解析的语法矩阵与偏移契约。
//
// 这套测试守的是两条命：
// 1. 正文即坐标系——剥完标记后 span 的 start/length 必须精确落在纯文本上，
//    因为浮窗点字查词的 index 与它同一坐标系（UTF-16 code unit）。
// 2. 认不出就别动——歧义形式必须被普通文本挡回去，绝不吃掉正文。

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/ruby_markup.dart';

/// 断言注音区间确实落在纯文本的期望基准上。
void expectSpan(
  RubyMarkupText parsed,
  int index, {
  required String base,
  required String ruby,
}) {
  expect(parsed.spans.length, greaterThan(index),
      reason: '缺少第 $index 段注音：${parsed.spans}');
  final RubySpan span = parsed.spans[index];
  expect(span.ruby, ruby);
  expect(
    parsed.text.substring(span.start, span.end),
    base,
    reason: 'span $span 没有落在 "$base" 上（文本 "${parsed.text}"）',
  );
}

void main() {
  group('无标记直通', () {
    test('普通台词原样返回且不产生注音', () {
      const String raw = '良かれと思って案内役に優等生を選んでみたものの。';
      final RubyMarkupText parsed = parseRubyMarkup(raw);
      expect(parsed.text, raw);
      expect(parsed.hasRuby, isFalse);
      expect(parsed.toChannelSpans(), isNull);
    });

    test('空串不炸', () {
      final RubyMarkupText parsed = parseRubyMarkup('');
      expect(parsed.text, '');
      expect(parsed.hasRuby, isFalse);
    });
  });

  group('<r注音>基准</r>（截图实例 / BGI 系）', () {
    test('WITCH ON THE HOLY NIGHT 原句', () {
      // 截图里浮窗显示的原始串，游戏本体把 ふる 渲染在「震」上方。
      const String raw = '今もピリピリと空気を<rふる>震</r>わせている。';
      final RubyMarkupText parsed = parseRubyMarkup(raw);
      expect(parsed.text, '今もピリピリと空気を震わせている。');
      expect(parsed.spans.single,
          const RubySpan(start: 10, length: 1, ruby: 'ふる'));
      expectSpan(parsed, 0, base: '震', ruby: 'ふる');
    });

    test('大写 <R> 与标签内空格都认', () {
      final RubyMarkupText parsed = parseRubyMarkup('<R かんじ>漢字</R>です');
      expect(parsed.text, '漢字です');
      expectSpan(parsed, 0, base: '漢字', ruby: 'かんじ');
    });

    test('注音不是假名时原样保留（不误吃 <red> 之类）', () {
      const String raw = '<red>危険</red>';
      final RubyMarkupText parsed = parseRubyMarkup(raw);
      expect(parsed.text, raw);
      expect(parsed.hasRuby, isFalse);
    });

    test('空注音的 <r> 原样保留', () {
      const String raw = '<r>震</r>';
      final RubyMarkupText parsed = parseRubyMarkup(raw);
      expect(parsed.text, raw);
      expect(parsed.hasRuby, isFalse);
    });
  });

  group('HTML <ruby>', () {
    test('单段 rt', () {
      final RubyMarkupText parsed =
          parseRubyMarkup('空気を<ruby>震<rt>ふる</rt></ruby>わせる');
      expect(parsed.text, '空気を震わせる');
      expectSpan(parsed, 0, base: '震', ruby: 'ふる');
    });

    test('mono-ruby 拆成逐字两段', () {
      final RubyMarkupText parsed =
          parseRubyMarkup('<ruby>漢<rt>かん</rt>字<rt>じ</rt></ruby>');
      expect(parsed.text, '漢字');
      expect(parsed.spans.length, 2);
      expectSpan(parsed, 0, base: '漢', ruby: 'かん');
      expectSpan(parsed, 1, base: '字', ruby: 'じ');
    });

    test('<rb> 壳保留内容、<rp> 回退括号整段丢弃', () {
      final RubyMarkupText parsed = parseRubyMarkup(
        '<ruby><rb>漢字</rb><rp>（</rp><rt>かんじ</rt><rp>）</rp></ruby>',
      );
      expect(parsed.text, '漢字');
      expectSpan(parsed, 0, base: '漢字', ruby: 'かんじ');
    });

    test('非假名注音也抬到上方（<ruby> 结构无歧义）', () {
      final RubyMarkupText parsed =
          parseRubyMarkup('<ruby>東京<rt>Tokyo</rt></ruby>');
      expect(parsed.text, '東京');
      expectSpan(parsed, 0, base: '東京', ruby: 'Tokyo');
    });

    test('空 rt 只剥标记、不产生注音，且不把标记塞回正文', () {
      final RubyMarkupText parsed = parseRubyMarkup('<ruby>漢字<rt></rt></ruby>');
      expect(parsed.text, '漢字');
      expect(parsed.hasRuby, isFalse);
    });
  });

  group('青空文庫式', () {
    test('｜ 显式定界', () {
      final RubyMarkupText parsed = parseRubyMarkup('空気を｜震《ふる》わせる');
      expect(parsed.text, '空気を震わせる');
      expectSpan(parsed, 0, base: '震', ruby: 'ふる');
    });

    test('ASCII 竖线同样认', () {
      final RubyMarkupText parsed = parseRubyMarkup('|震《ふる》');
      expect(parsed.text, '震');
      expectSpan(parsed, 0, base: '震', ruby: 'ふる');
    });

    test('裸《》倒推前面的汉字串', () {
      final RubyMarkupText parsed = parseRubyMarkup('その優等生《ゆうとうせい》は');
      expect(parsed.text, 'その優等生は');
      expectSpan(parsed, 0, base: '優等生', ruby: 'ゆうとうせい');
    });

    test('裸《》前面没有汉字时原样保留（书名号不误吃）', () {
      const String raw = 'これは《ろんどん》だ';
      final RubyMarkupText parsed = parseRubyMarkup(raw);
      expect(parsed.text, raw);
      expect(parsed.hasRuby, isFalse);
    });

    test('裸《》内容不是假名时原样保留', () {
      const String raw = '書名《LONDON》';
      final RubyMarkupText parsed = parseRubyMarkup(raw);
      expect(parsed.text, raw);
      expect(parsed.hasRuby, isFalse);
    });

    test('连续两段裸注音不互相吃字', () {
      final RubyMarkupText parsed = parseRubyMarkup('魔術《まじゅつ》師《し》');
      expect(parsed.text, '魔術師');
      expectSpan(parsed, 0, base: '魔術', ruby: 'まじゅつ');
      expectSpan(parsed, 1, base: '師', ruby: 'し');
    });
  });

  group('漢字[かんじ] 方括号式', () {
    test('倒推汉字串', () {
      final RubyMarkupText parsed = parseRubyMarkup('空気を震[ふる]わせる');
      expect(parsed.text, '空気を震わせる');
      expectSpan(parsed, 0, base: '震', ruby: 'ふる');
    });

    test('方括号里不是假名时原样保留（编号/时间不误吃）', () {
      const String raw = '第3話[2026/07/27]';
      final RubyMarkupText parsed = parseRubyMarkup(raw);
      expect(parsed.text, raw);
      expect(parsed.hasRuby, isFalse);
    });

    test('方括号前没有汉字时原样保留', () {
      const String raw = 'えっと[ふる]';
      final RubyMarkupText parsed = parseRubyMarkup(raw);
      expect(parsed.text, raw);
      expect(parsed.hasRuby, isFalse);
    });
  });

  group('混排与偏移', () {
    test('一行多种语法混排，偏移逐段正确', () {
      final RubyMarkupText parsed = parseRubyMarkup(
        '<rふる>震</r>える<ruby>魔術<rt>まじゅつ</rt></ruby>と｜夜《よる》',
      );
      expect(parsed.text, '震える魔術と夜');
      expect(parsed.spans.length, 3);
      expectSpan(parsed, 0, base: '震', ruby: 'ふる');
      expectSpan(parsed, 1, base: '魔術', ruby: 'まじゅつ');
      expectSpan(parsed, 2, base: '夜', ruby: 'よる');
    });

    test('区间按 UTF-16 下标排列且互不重叠', () {
      final RubyMarkupText parsed =
          parseRubyMarkup('<rあ>亜</r><rい>以</r><rう>宇</r>');
      expect(parsed.text, '亜以宇');
      int previousEnd = 0;
      for (final RubySpan span in parsed.spans) {
        expect(span.start, greaterThanOrEqualTo(previousEnd));
        expect(span.length, greaterThan(0));
        previousEnd = span.end;
      }
      expect(previousEnd, lessThanOrEqualTo(parsed.text.length));
    });
  });

  group('rebase：文本被继续加工时的偏移守恒', () {
    test('trim 后区间整体平移', () {
      final RubyMarkupText parsed =
          parseRubyMarkup('  <rふる>震</r>わせる  ').trimmed();
      expect(parsed.text, '震わせる');
      expectSpan(parsed, 0, base: '震', ruby: 'ふる');
    });

    test('尾部截断丢掉越界区间、保留仍在范围内的', () {
      final RubyMarkupText parsed = parseRubyMarkup('<rふる>震</r>える<rよる>夜</r>');
      expect(parsed.text, '震える夜');
      expect(parsed.spans.length, 2);
      final RubyMarkupText clipped = parsed.rebase('震える');
      expect(clipped.text, '震える');
      expect(clipped.spans.length, 1);
      expectSpan(clipped, 0, base: '震', ruby: 'ふる');
    });

    test('候选串不是子串时整体退回无注音（宁可不显示也不错位）', () {
      final RubyMarkupText parsed = parseRubyMarkup('<rふる>震</r>わせる');
      final RubyMarkupText rebased = parsed.rebase('まったく別の文');
      expect(rebased.text, 'まったく別の文');
      expect(rebased.hasRuby, isFalse);
    });

    test('空串退回无注音', () {
      final RubyMarkupText parsed = parseRubyMarkup('<rふる>震</r>');
      expect(parsed.rebase('').hasRuby, isFalse);
    });
  });

  group('通道载荷', () {
    test('无注音时不发结构化字段（native 走老路径）', () {
      expect(parseRubyMarkup('ただの台詞').toChannelSpans(), isNull);
    });

    test('有注音时按 start/length/ruby 三字段编码', () {
      final List<Map<String, Object?>>? encoded =
          parseRubyMarkup('<rふる>震</r>').toChannelSpans();
      expect(encoded, isNotNull);
      expect(encoded!.single, <String, Object?>{
        'start': 0,
        'length': 1,
        'ruby': 'ふる',
      });
    });
  });
}
