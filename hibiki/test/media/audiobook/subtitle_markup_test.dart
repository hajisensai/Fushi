import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

void main() {
  group('parseSubtitleMarkup', () {
    test('strips {\\an8} and decodes top-center anchor', () {
      final SubtitleMarkup m = parseSubtitleMarkup(r'{\an8}（カンナ）ふわぁ~');
      expect(m.plainText, '（カンナ）ふわぁ~');
      expect(m.anchor?.vertical, SubtitleVAlign.top);
      expect(m.anchor?.horizontal, SubtitleHAlign.center);
      expect(m.spans, isEmpty);
    });

    test('italic span over correct grapheme range', () {
      final SubtitleMarkup m = parseSubtitleMarkup(r'{\i1}x{\i0}y');
      expect(m.plainText, 'xy');
      expect(m.spans.length, 1);
      expect(m.spans.first.startGrapheme, 0);
      expect(m.spans.first.endGrapheme, 1);
      expect(m.spans.first.italic, isTrue);
    });

    test('bold+underline combined, color BGR->ARGB, font size', () {
      final SubtitleMarkup m =
          parseSubtitleMarkup(r'{\b1\u1\c&H0000FF&\fs30}ab');
      final SubtitleSpan s = m.spans.single;
      expect(m.plainText, 'ab');
      expect(s.bold, isTrue);
      expect(s.underline, isTrue);
      expect(s.colorArgb, 0xFFFF0000); // &H0000FF& = B=00 G=00 R=FF -> red
      expect(s.fontSizePx, 30);
    });

    test(r'\N and \h become spaces; trims edges', () {
      final SubtitleMarkup m = parseSubtitleMarkup(r'a\Nb\hc');
      expect(m.plainText, 'a b c');
      expect(m.anchor, isNull);
    });

    test(r'\pos normalized by playRes', () {
      final SubtitleMarkup m = parseSubtitleMarkup(r'{\pos(960,540)}hi',
          playResX: 1920, playResY: 1080);
      expect(m.posFraction!.xFraction, closeTo(0.5, 1e-9));
      expect(m.posFraction!.yFraction, closeTo(0.5, 1e-9));
    });

    test('karaoke/animation/drawing tags are dropped with no style', () {
      final SubtitleMarkup m =
          parseSubtitleMarkup(r'{\k50}あ{\t(0,500,\fscx120)}い{\p1}');
      expect(m.plainText, 'あい');
      expect(m.spans, isEmpty);
      expect(m.posFraction, isNull);
    });

    test('plain text with no tags: empty spans, null anchor', () {
      final SubtitleMarkup m = parseSubtitleMarkup('こんにちは');
      expect(m.plainText, 'こんにちは');
      expect(m.spans, isEmpty);
      expect(m.anchor, isNull);
      expect(m.posFraction, isNull);
    });
  });
}
