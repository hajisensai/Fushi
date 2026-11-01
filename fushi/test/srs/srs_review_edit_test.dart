import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_fushi_card_fields.dart';
import 'package:fushi/src/srs/srs_review_edit.dart';

void main() {
  const SrsQuickFormat bold = SrsQuickFormat.bold;
  const SrsQuickFormat highlight = SrsQuickFormat.highlight;
  const SrsQuickFormat clear = SrsQuickFormat.clear;

  String? apply(
    String html,
    String text,
    SrsQuickFormat f, {
    int? occurrence,
  }) => srsApplyQuickFormat(
    html,
    SrsCardSelection(text, occurrence: occurrence),
    f,
  );

  group('srsApplyQuickFormat', () {
    test('wraps plain text', () {
      expect(apply('天候のいかんにかかわらず', 'いかん', bold), '天候の<b>いかん</b>にかかわらず');
      expect(
        apply('abc def', 'c d', highlight),
        'ab<span style="background-color: #fff59d;">c d</span>ef',
      );
    });

    test('splits around tags so nesting stays valid', () {
      expect(
        apply('<ol><li>不論</li><li>無論</li></ol>', '不論無論', bold),
        '<ol><li><b>不論</b></li><li><b>無論</b></li></ol>',
      );
      expect(apply('a<i>bc</i>d', 'bcd', bold), 'a<i><b>bc</b></i><b>d</b>');
    });

    test('ignores whitespace and line breaks of the rendered selection', () {
      expect(
        apply('foo bar<br>baz', 'bar\n baz', bold),
        'foo <b>bar</b><br><b>baz</b>',
      );
    });

    test('decodes entities and skips ruby readings', () {
      expect(apply('A &amp; B', 'A&B', bold), '<b>A &amp; B</b>');
      expect(
        apply('<ruby>漢字<rt>かんじ</rt></ruby>です', '漢字です', bold),
        '<ruby><b>漢字</b><rt>かんじ</rt></ruby><b>です</b>',
      );
      expect(apply('<ruby>漢字<rt>かんじ</rt></ruby>', 'かんじ', bold), isNull);
    });

    test('picks the given occurrence, else the first', () {
      expect(apply('x a x a', 'a', bold, occurrence: 1), 'x a x <b>a</b>');
      expect(apply('x a x a', 'a', bold, occurrence: 7), 'x <b>a</b> x a');
      expect(apply('x a x a', 'a', bold), 'x <b>a</b> x a');
    });

    test('clear removes formatting elements touching the selection', () {
      expect(apply('a<b>bc</b>d<b>e</b>', 'cd', clear), 'abcd<b>e</b>');
      expect(
        apply(
          'x<span style="background-color: #fff59d;">yy</span><span class="k">z</span>',
          'yyz',
          clear,
        ),
        'xyy<span class="k">z</span>',
      );
      expect(apply('plain', 'la', clear), 'plain');
    });

    test('bold then clear round-trips', () {
      const String src = '<div>名詞 + いかんにかかわらず</div>';
      final String b = apply(src, 'いかんに', bold)!;
      expect(apply(b, 'いかんに', clear), src);
    });

    test('missing text or empty selection = null', () {
      expect(apply('abc', 'zz', bold), isNull);
      expect(apply('abc', '  ', bold), isNull);
    });
  });

  test('srsFieldsContaining lists every field holding the text', () {
    expect(
      srsFieldsContaining(<String, String>{
        'term': '試合',
        'sentence': '<b>試合</b>は予定通り',
        'def': 'match',
      }, const SrsCardSelection('試合')),
      <String>['term', 'sentence'],
    );
    expect(
      srsFieldsContaining(<String, String>{
        'a': 'x',
      }, const SrsCardSelection('')),
      isEmpty,
    );
  });

  test('native card parser renders the written highlight', () {
    final List<SrsInline> segs = srsParseInline(
      'a<span style="background-color: #fff59d;">b</span><mark>c</mark>d',
    );
    expect(
      segs.map((SrsInline s) => (s.text, s.highlight)).toList(),
      <(String, int?)>[
        ('a', null),
        ('b', 0xFFFFF59D),
        ('c', 0xFFFFF59D),
        ('d', null),
      ],
    );
  });
}
