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

    test('playResY passthrough for ASS font/shadow scaling (TODO-1246)', () {
      expect(parseSubtitleMarkup('X', playResY: 1080).playResY, 1080);
      expect(parseSubtitleMarkup('X').playResY, isNull);
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

    test('karaoke syllables become spans; drawing tag drops with no style',
        () {
      final SubtitleMarkup m =
          parseSubtitleMarkup(r'{\k50}あ{\t(0,500,\fscx120)}い{\p1}');
      expect(m.plainText, 'あい');
      // \k50 起卡拉 OK 建模：两个 grapheme 都在音节 span 里（\t 块不清 karaoke 态）。
      expect(m.spans, isNotEmpty);
      expect(m.spans.first.kMode, 'k');
      expect(m.spans.first.kStartCs, 0);
      expect(m.spans.first.kDurCs, 50);
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

  group(r'parseSubtitleMarkup \r reset tag (TODO-1246)', () {
    test(r'\r reverts inline colour so the reset region is not coloured', () {
      // Before the fix, \r was ignored and the leading red primary colour bled
      // past the reset onto the trailing text -> wrong colour, defeating
      // "respect subtitle's own style".
      final SubtitleMarkup m =
          parseSubtitleMarkup(r'{\c&H0000FF&}akai{\r}shiro');
      expect(m.plainText, 'akaishiro');
      // Only the pre-reset run carries the inline red span.
      final Iterable<SubtitleSpan> coloured =
          m.spans.where((SubtitleSpan s) => s.colorArgb != null);
      expect(coloured, hasLength(1));
      expect(coloured.single.colorArgb, 0xFFFF0000); // red, graphemes 0..4
      expect(coloured.single.startGrapheme, 0);
      expect(coloured.single.endGrapheme, 4);
      // The reset run (graphemes 4..9 = "shiro") has no inline colour override.
      for (final SubtitleSpan s in m.spans) {
        if (s.startGrapheme >= 4) {
          expect(s.colorArgb, isNull,
              reason: r'\r must clear the earlier inline primary colour');
        }
      }
    });

    test(r'\r clears outline / bold / font overrides too', () {
      final SubtitleMarkup m =
          parseSubtitleMarkup(r'{\b1\3c&H0000FF&\fnArial\bord5}A{\r}B');
      expect(m.plainText, 'AB');
      final SubtitleSpan? resetSpan = m.spans.cast<SubtitleSpan?>().firstWhere(
          (SubtitleSpan? s) => s != null && s.startGrapheme >= 1,
          orElse: () => null);
      // Either no span is emitted for the reset run (all fields cleared ->
      // hasStyle false), or a span exists but carries none of the overrides.
      if (resetSpan != null) {
        expect(resetSpan.bold, isFalse);
        expect(resetSpan.outlineColorArgb, isNull);
        expect(resetSpan.outlineWidthPx, isNull);
        expect(resetSpan.fontName, isNull);
      }
    });

    test(r'\r<StyleName> is treated as a reset (baseline approximation)', () {
      final SubtitleMarkup m =
          parseSubtitleMarkup(r'{\c&H0000FF&}X{\rDefault}Y');
      expect(m.plainText, 'XY');
      for (final SubtitleSpan s in m.spans) {
        if (s.startGrapheme >= 1) {
          expect(s.colorArgb, isNull);
        }
      }
    });

    test(r'\r clears \blur too (reset region has no glow)', () {
      final SubtitleMarkup m = parseSubtitleMarkup(r'{\blur5}A{\r}B');
      expect(m.plainText, 'AB');
      for (final SubtitleSpan s in m.spans) {
        if (s.startGrapheme >= 1) {
          expect(s.blur, isNull, reason: r'\r must clear the earlier \blur');
        }
      }
    });
  });

  group(r'parseSubtitleMarkup \blur / \be glow (TODO-1373)', () {
    test(r'\blur strength on span', () {
      final SubtitleMarkup m = parseSubtitleMarkup(r'{\blur5}まったく');
      expect(m.plainText, 'まったく');
      expect(m.spans.single.blur, 5);
    });

    test(r'\blur decimal strength', () {
      expect(parseSubtitleMarkup(r'{\blur2.5}x').spans.single.blur, 2.5);
    });

    test(r'\be edge-blur maps to the same blur field', () {
      expect(parseSubtitleMarkup(r'{\be3}x').spans.single.blur, 3);
    });

    test(r'\blur0 = no glow -> no style span', () {
      // 0 强度不产出样式（与 hasStyle 一致），plainText 仍是纯文本。
      final SubtitleMarkup m = parseSubtitleMarkup(r'{\blur0}x');
      expect(m.plainText, 'x');
      expect(m.spans, isEmpty);
    });

    test(r'\blur combines with inline colour on same span', () {
      final SubtitleSpan s =
          parseSubtitleMarkup(r'{\blur5\c&H0000FF&}あ').spans.single;
      expect(s.blur, 5);
      expect(s.colorArgb, 0xFFFF0000); // &H0000FF& -> red
    });

    test(r'\blur is span-scoped; \blur0 turns it off for later text', () {
      // "A" carries blur 4; after \blur0 "B" carries none.
      final SubtitleMarkup m = parseSubtitleMarkup(r'{\blur4}A{\blur0}B');
      expect(m.plainText, 'AB');
      for (final SubtitleSpan s in m.spans) {
        if (s.startGrapheme == 0) expect(s.blur, 4);
        if (s.startGrapheme >= 1) expect(s.blur, isNull);
      }
    });

    test(r'plain text has no blur', () {
      expect(parseSubtitleMarkup('hi').spans, isEmpty);
    });
  });

  group(r'parseSubtitleMarkup \fad / \fade line fade (TODO-1373)', () {
    test(r'\fad(t1,t2) parsed as simple fade, produces no span', () {
      final SubtitleMarkup m = parseSubtitleMarkup(r'{\fad(160,160)}うた');
      expect(m.plainText, 'うた');
      expect(m.spans, isEmpty); // 行级，不产出 span
      expect(m.fade, isNotNull);
      expect(m.fade!.fadeInMs, 160);
      expect(m.fade!.fadeOutMs, 160);
    });

    test(r'\fad coexists with \an and \blur (real ED line shape)', () {
      final SubtitleMarkup m =
          parseSubtitleMarkup(r'{\fad(160,160)\an7\blur4}瞬き二つ');
      expect(m.plainText, '瞬き二つ');
      expect(m.fade!.fadeInMs, 160);
      expect(m.anchor?.vertical, SubtitleVAlign.top);
      expect(m.anchor?.horizontal, SubtitleHAlign.left);
      expect(m.spans.single.blur, 4);
    });

    test(r'\fade(a1,a2,a3,t1,t2,t3,t4) parsed as full envelope', () {
      final SubtitleMarkup m =
          parseSubtitleMarkup(r'{\fade(255,0,255,0,300,2700,3000)}x');
      expect(m.fade, isNotNull);
      // alpha 255=透明→op0, alpha 0=不透明→op1.
      expect(m.fade!.opacityAt(0, 3000), closeTo(0.0, 1e-9));
      expect(m.fade!.opacityAt(150, 3000), closeTo(0.5, 1e-9));
      expect(m.fade!.opacityAt(300, 3000), closeTo(1.0, 1e-9));
      expect(m.fade!.opacityAt(1500, 3000), closeTo(1.0, 1e-9));
      expect(m.fade!.opacityAt(2850, 3000), closeTo(0.5, 1e-9));
      expect(m.fade!.opacityAt(3000, 3000), closeTo(0.0, 1e-9));
    });

    test('no fade tag -> markup.fade is null', () {
      expect(parseSubtitleMarkup('こんにちは').fade, isNull);
      expect(parseSubtitleMarkup(r'{\an8}x').fade, isNull);
    });

    test('malformed fad forms are ignored (no crash, no fade)', () {
      expect(parseSubtitleMarkup(r'{\fad()}x').fade, isNull);
      expect(parseSubtitleMarkup(r'{\fad(160)}x').fade, isNull);
      expect(parseSubtitleMarkup(r'{\fade(1,2,3)}x').fade, isNull);
    });
  });

  group('SubtitleFade opacity envelope (TODO-1373)', () {
    test('simple fad ramps 0->1 in, plateau, 1->0 out', () {
      const SubtitleFade f = SubtitleFade.simple(160, 160);
      // dur=1000: in [0,160], plateau [160,840], out [840,1000].
      expect(f.opacityAt(0, 1000), closeTo(0.0, 1e-9));
      expect(f.opacityAt(80, 1000), closeTo(0.5, 1e-9));
      expect(f.opacityAt(160, 1000), closeTo(1.0, 1e-9));
      expect(f.opacityAt(500, 1000), closeTo(1.0, 1e-9));
      expect(f.opacityAt(840, 1000), closeTo(1.0, 1e-9));
      expect(f.opacityAt(920, 1000), closeTo(0.5, 1e-9));
      expect(f.opacityAt(1000, 1000), closeTo(0.0, 1e-9));
    });

    test('clamps out-of-range elapsed to endpoints', () {
      const SubtitleFade f = SubtitleFade.simple(100, 100);
      expect(f.opacityAt(-50, 1000), 0.0); // before start -> transparent
      expect(f.opacityAt(5000, 1000), 0.0); // past end -> transparent
    });

    test('zero fade-in/out is a hard cut (no divide-by-zero)', () {
      const SubtitleFade f = SubtitleFade.simple(0, 0);
      expect(f.opacityAt(0, 1000), 1.0);
      expect(f.opacityAt(500, 1000), 1.0);
      expect(f.opacityAt(1000, 1000), 1.0);
    });

    test('overlapping fade-in/out on a short cue stays monotonic (no reorder)',
        () {
      // dur(200) < in(160)+out(160): times get clamped monotonic, peaks mid.
      const SubtitleFade f = SubtitleFade.simple(160, 160);
      final double mid = f.opacityAt(160, 200);
      expect(mid, inInclusiveRange(0.0, 1.0));
      expect(f.opacityAt(0, 200), closeTo(0.0, 1e-9));
      expect(f.opacityAt(200, 200), closeTo(0.0, 1e-9));
    });
  });
}
