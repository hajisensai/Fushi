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

    test(r'\p1 drawing-mode body outside tag block is discarded', () {
      // Real OP karaoke line: \p1 enters drawing mode; the vector command
      // body (m/l/b coords) lives OUTSIDE the {...} block and must not render.
      final SubtitleMarkup m = parseSubtitleMarkup(
          r'{\an7\pos(461.719,678.906)\p1\c&H7056F8&}m 0 0 l 8.475 0 l 0 16.0596{\p0}');
      expect(m.plainText, isEmpty);
      expect(m.plainText.contains('m 0 0 l'), isFalse);
      expect(m.spans, isEmpty);
    });

    test(r'\p0 ends drawing mode; later real text still renders', () {
      final SubtitleMarkup m =
          parseSubtitleMarkup(r'{\p1}m 0 0 l 8.475 0{\p0}本当のセリフ');
      expect(m.plainText, '本当のセリフ');
      expect(m.plainText.contains('m 0 0'), isFalse);
    });

    test(r'drawing mode persists to end of cue when no \p0', () {
      final SubtitleMarkup m =
          parseSubtitleMarkup(r'{\p1}m 0 0 l 100 0 b 1 2 3 4 5 6');
      expect(m.plainText, isEmpty);
    });

    test('plain dialogue without p is byte-for-byte unchanged', () {
      final SubtitleMarkup m = parseSubtitleMarkup('吾輩は猫である。');
      expect(m.plainText, '吾輩は猫である。');
      expect(m.spans, isEmpty);
    });

    test('plain text with no tags: empty spans, null anchor', () {
      final SubtitleMarkup m = parseSubtitleMarkup('こんにちは');
      expect(m.plainText, 'こんにちは');
      expect(m.spans, isEmpty);
      expect(m.anchor, isNull);
      expect(m.posFraction, isNull);
    });
  });
  group('parseSubtitleMarkup ASS inline style tags (TODO-1105)', () {
    test(r'\fn font name preserved on span', () {
      final SubtitleMarkup m = parseSubtitleMarkup(r'{\fnYu Mincho}x');
      expect(m.plainText, 'x');
      expect(m.spans.single.fontName, 'Yu Mincho');
    });

    test(r'\3c outline color BGR->ARGB on span', () {
      final SubtitleMarkup m = parseSubtitleMarkup(r'{\3c&HFF0000&}x');
      // &HFF0000& = B=FF G=00 R=00 -> blue 0xFF0000FF.
      expect(m.spans.single.outlineColorArgb, 0xFF0000FF);
    });

    test(r'\4c shadow color BGR->ARGB on span', () {
      final SubtitleMarkup m = parseSubtitleMarkup(r'{\4c&H00FF00&}x');
      // &H00FF00& = B=00 G=FF R=00 -> green 0xFF00FF00.
      expect(m.spans.single.shadowColorArgb, 0xFF00FF00);
    });

    test(r'\bord outline width and \shad shadow depth on span', () {
      final SubtitleMarkup m = parseSubtitleMarkup(r'{\bord4\shad2}x');
      expect(m.spans.single.outlineWidthPx, 4);
      expect(m.spans.single.shadowDepthPx, 2);
    });

    test(r'combined \fn \3c \bord in one block', () {
      final SubtitleMarkup m =
          parseSubtitleMarkup(r'{\fnArial\3c&H0000FF&\bord3}ab');
      final SubtitleSpan s = m.spans.single;
      expect(m.plainText, 'ab');
      expect(s.fontName, 'Arial');
      // &H0000FF& = B=00 G=00 R=FF -> red 0xFFFF0000.
      expect(s.outlineColorArgb, 0xFFFF0000);
      expect(s.outlineWidthPx, 3);
    });

    test(r'plain text with no ASS tags keeps span fields null', () {
      final SubtitleMarkup m = parseSubtitleMarkup('hello');
      expect(m.spans, isEmpty);
      expect(m.cueStyle, isNull);
    });
  });
}
