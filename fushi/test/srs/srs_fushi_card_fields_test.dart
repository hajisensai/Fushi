import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_fushi_card_fields.dart';

void main() {
  group('srsParseInline', () {
    test('Anki furigana becomes ruby segments', () {
      expect(srsParseInline('食べる[たべる]'), const <SrsInline>[
        SrsInline('食べる', ruby: 'たべる'),
      ]);
      expect(srsParseInline('今日[きょう]は 天気[てんき]'), const <SrsInline>[
        SrsInline('今日', ruby: 'きょう'),
        SrsInline('は'),
        SrsInline('天気', ruby: 'てんき'),
      ]);
    });

    test('b / i / u / br / ruby are kept', () {
      expect(
        srsParseInline(
          '彼は<b>走<i>った</i></b><br>次<ruby>漢<rp>(</rp><rt>かん</rt><rp>)</rp></ruby>',
        ),
        const <SrsInline>[
          SrsInline('彼は'),
          SrsInline('走', bold: true),
          SrsInline('った', bold: true, italic: true),
          SrsInline('\n'),
          SrsInline('次'),
          SrsInline('漢', ruby: 'かん'),
        ],
      );
      expect(srsParseInline('<u>x</u>').single.underline, isTrue);
    });

    test('span / div / entities; sound tags dropped', () {
      expect(
        srsParseInline(
          '<div>a&amp;b</div><div><span style="color:red">c</span></div>[sound:x.mp3]',
        ),
        const <SrsInline>[SrsInline('a&b'), SrsInline('\n'), SrsInline('c')],
      );
    });

    test('unsupported markup falls back to plain text', () {
      expect(
        srsParseInline('<a href="#">本</a><img src="x.png">'),
        const <SrsInline>[SrsInline('本')],
      );
      expect(
        srsParseInline('<table><tr><td>1</td></tr></table>'),
        const <SrsInline>[SrsInline('1')],
      );
    });

    test('kana of furigana', () {
      expect(srsKanaOf(srsParseInline('食[た]べる')), 'たべる');
    });
  });

  group('fields helpers', () {
    test('sounds and images', () {
      expect(srsSoundNames('[sound:a.mp3] [sound:b.ogg]'), <String>[
        'a.mp3',
        'b.ogg',
      ]);
      expect(
        srsImageSources('<img src="p&amp;q.webp"> <img alt=x src=\'r.png\'>'),
        <String>['p&q.webp', 'r.png'],
      );
    });

    test('pitch positions from Yomitan list and kana notation', () {
      expect(
        srsPitchPositions(
          '<ul><li>[0]</li><li>[2]</li><li>[0]</li></ul>',
          'たべる',
        ),
        <int>[0, 2],
      );
      expect(srsPitchPositions('たべ＼る', 'たべる'), <int>[2]);
      expect(srsMorae('きょう'), <String>['きょ', 'う']);
      expect(srsPitchType(0, 3, ''), 'heiban');
      expect(srsPitchType(1, 3, ''), 'atamadaka');
      expect(srsPitchType(2, 3, ''), 'nakadaka');
      expect(srsPitchType(3, 3, ''), 'odaka');
      expect(srsPitchType(2, 3, 'kifuku'), 'kifuku');
    });

    test('filled', () {
      expect(srsFieldFilled(' '), isFalse);
      expect(srsFieldFilled(null), isFalse);
      expect(srsFieldFilled('x'), isTrue);
    });
  });
}
