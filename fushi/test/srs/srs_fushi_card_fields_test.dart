import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_fushi_card_fields.dart';
import 'package:fushi_anki/fushi_anki_core.dart'
    show coverMediaRef, inlineVideoWordAudioHtml;

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

  group('内嵌媒体', () {
    test('音频字段：[sound:] 与 <audio src> 都认，按出现顺序去重', () {
      final String field =
          '[sound:a.mp3]${inlineVideoWordAudioHtml('b.mp3')}[sound:a.mp3]';
      expect(srsAudioSources(field), <String>['a.mp3', 'b.mp3']);
    });

    test('Picture：WebM 片段与 MP4 [sound:] 算视频，图片不算', () {
      expect(srsVideoSources(coverMediaRef('c.webm')), <String>['c.webm']);
      expect(srsVideoSources(coverMediaRef('c.mp4')), <String>['c.mp4']);
      expect(srsVideoSources(coverMediaRef('c.avif')), isEmpty);
      expect(srsImageSources(coverMediaRef('c.avif')), <String>['c.avif']);
    });
  });
}
