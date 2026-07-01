import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/src/media/audiobook/lyrics_mode_html.dart';

void main() {
  group('LyricsModeHtml', () {
    test('includes reader selection highlight styles in the standalone page',
        () {
      final String html = LyricsModeHtml.generate(
        cues: <AudioCue>[_cue(0)],
        currentIndex: 0,
        backgroundColor: 'rgba(255,255,255,1.00)',
        textColor: 'rgba(0,0,0,1.00)',
        accentColor: 'rgba(255,220,0,1.00)',
        fontSize: 20,
      );

      expect(html, contains('::highlight(hoshi-selection)'));
      expect(html, contains('.hoshi-dict-highlight'));
    });

    test('current cue tap uses selection without disabling native selection',
        () {
      final String html = LyricsModeHtml.generate(
        cues: <AudioCue>[_cue(0)],
        currentIndex: 0,
        backgroundColor: 'rgba(255,255,255,1.00)',
        textColor: 'rgba(0,0,0,1.00)',
        accentColor: 'rgba(255,220,0,1.00)',
        fontSize: 20,
      );

      // BUG-280: tap-to-lookup now fires from the raw pointer-up/touch-end path
      // (see _lyTapEnd) instead of the synthesized DOM 'click', so it still
      // calls hoshiSelection.selectText.
      expect(html, contains('window.hoshiSelection.selectText('));
      expect(html, isNot(contains('-webkit-user-select: none;')));
      expect(html, isNot(contains('user-select: none;')));
      expect(html, isNot(contains('var _longPressed')));
    });

    // BUG-280: 歌词模式查完一个词后无法继续查下一句。原因是 #lc 用 DOM 'click'
    // 触发查词，而 click 只在「pointerdown→up 全程未被宿主层认领」时由浏览器合成；
    // 当 Flutter 端弹窗可见时整屏有一层 translucent 手势屏障会认领点按 → WebView 收
    // 不到 click → 只关弹窗不发新查词。修复=对齐阅读器正文，用原始 pointerup/touchend
    // （passive:false）+ 小位移门控触发查词，使屏障在场时 WebView 仍能拿到点按。
    test('lyrics tap uses raw pointer/touch (not synthesized click) for lookup',
        () {
      final String html = LyricsModeHtml.generate(
        cues: <AudioCue>[_cue(0), _cue(1)],
        currentIndex: 0,
        backgroundColor: 'rgba(255,255,255,1.00)',
        textColor: 'rgba(0,0,0,1.00)',
        accentColor: 'rgba(255,220,0,1.00)',
        fontSize: 20,
      );

      // Raw pointer-up / touch-end listeners on #lc drive the lookup so the
      // gesture reaches the WebView even when the Flutter dismiss barrier is up.
      expect(html, contains("_lc.addEventListener('pointerup'"));
      expect(html, contains("_lc.addEventListener('touchend'"));
      // Lookup must NOT be wired to the synthesized 'click' event (the broken
      // path the dismiss barrier swallowed).
      expect(html, isNot(contains("addEventListener('click'")));
      // touchend / pointerup register passive:false so preventing/handling the
      // gesture is allowed (mirrors the reader content gesture handlers).
      expect(html, contains('{passive: false}'));
    });

    // BUG-017: the active cue used `max-width: 92vw` while `.cue.current` was
    // scaled by `transform: scale(1.15)`. Scaling a near-full-width box past
    // 100vw made the highlighted line spill off both screen edges (clipped by
    // `overflow-x: hidden`). The cue width must be expressed relative to the
    // container content box AND discount the scale factor so the scaled box
    // never exceeds the available width.
    test('active cue width reserves headroom for its scale (no edge clipping)',
        () {
      final String html = LyricsModeHtml.generate(
        cues: <AudioCue>[_cue(0)],
        currentIndex: 0,
        backgroundColor: 'rgba(255,255,255,1.00)',
        textColor: 'rgba(0,0,0,1.00)',
        accentColor: 'rgba(255,220,0,1.00)',
        fontSize: 20,
      );

      final String cueRule = _cssBlock(html, '.cue {');
      final String currentRule = _cssBlock(html, '.cue.current {');

      // The current cue is enlarged via transform scale, keyed off a shared
      // variable so the width headroom below stays in lock-step with it.
      expect(currentRule, contains('transform: scale(var(--cue-scale))'));
      expect(html, contains('--cue-scale:'));

      // Width must be relative to the container content box (100%), never a
      // viewport-fixed value that ignores both the scale and the margins.
      expect(cueRule, contains('max-width: calc(100% / var(--cue-scale)'));
      expect(cueRule, isNot(contains('92vw')));
      expect(cueRule, isNot(contains('max-width: 100vw')));
    });

    // The lyrics page is a standalone document (not ReaderContentStyles), so it
    // needs its own themed scrollbar or it shows the default grey bar over the
    // themed background. The classic WebView2 scrollbar honours
    // ::-webkit-scrollbar; the standard props cover overlay engines.
    test('scrollbar is themed to the cue text colour with a transparent track',
        () {
      final String html = LyricsModeHtml.generate(
        cues: <AudioCue>[_cue(0), _cue(1)],
        currentIndex: 0,
        backgroundColor: 'rgba(18,18,18,1.00)',
        textColor: 'rgba(255,255,255,0.87)',
        accentColor: 'rgba(255,220,0,1.00)',
        fontSize: 20,
      );

      expect(html, contains('::-webkit-scrollbar-thumb'));
      final String thumbRule = _cssBlock(html, '::-webkit-scrollbar-thumb {');
      expect(thumbRule, contains('background-color: rgba(255,255,255,0.87)'));

      final String trackRule = _cssBlock(html, '::-webkit-scrollbar-track {');
      expect(trackRule, contains('background: transparent'));

      final String rootRule = _cssBlock(html, 'html, body {');
      expect(rootRule, contains('scrollbar-width: thin;'));
      expect(
        rootRule,
        contains('scrollbar-color: rgba(255,255,255,0.87) transparent;'),
      );
    });

    test(
        'live style update repaints the scrollbar thumb to the new text colour',
        () {
      final String html = LyricsModeHtml.generate(
        cues: <AudioCue>[_cue(0)],
        currentIndex: 0,
        backgroundColor: 'rgba(255,255,255,1.00)',
        textColor: 'rgba(0,0,0,0.87)',
        accentColor: 'rgba(255,220,0,1.00)',
        fontSize: 20,
      );

      // __lyricsUpdateStyle must patch the scrollbar rules, not just .cue, so
      // changing theme while in lyrics mode recolours the bar without reload.
      expect(html, contains("r.selectorText === '::-webkit-scrollbar-thumb'"));
      expect(html, contains("r.selectorText === 'html, body'"));
      expect(html, contains("setProperty('scrollbar-color'"));
    });

    // TODO-907: vertical lyrics mode is a separate `vertical` flag (default
    // false = horizontal, backward-compatible). Horizontal output must NOT
    // carry the vertical writing-mode; vertical output must.
    test('default (horizontal) page has no vertical writing-mode', () {
      final String html = LyricsModeHtml.generate(
        cues: <AudioCue>[_cue(0)],
        currentIndex: 0,
        backgroundColor: 'rgba(255,255,255,1.00)',
        textColor: 'rgba(0,0,0,1.00)',
        accentColor: 'rgba(255,220,0,1.00)',
        fontSize: 20,
      );

      expect(html, isNot(contains('writing-mode: vertical-rl')));
      expect(html, contains('var __lyricsVertical = false;'));
      final String rootRule = _cssBlock(html, 'html, body {');
      expect(rootRule, contains('overflow-x: hidden;'));
    });

    test('vertical mode emits vertical-rl writing-mode and horizontal scroll',
        () {
      final String html = LyricsModeHtml.generate(
        cues: <AudioCue>[_cue(0), _cue(1)],
        currentIndex: 0,
        backgroundColor: 'rgba(255,255,255,1.00)',
        textColor: 'rgba(0,0,0,1.00)',
        accentColor: 'rgba(255,220,0,1.00)',
        fontSize: 20,
        vertical: true,
      );

      // The body switches to vertical-rl (top-to-bottom, right-to-left) and
      // scrolls horizontally; the JS axis flag must follow.
      final String rootRule = _cssBlock(html, 'html, body {');
      expect(rootRule, contains('writing-mode: vertical-rl;'));
      expect(rootRule, contains('overflow-x: auto;'));
      expect(rootRule, contains('overflow-y: hidden;'));
      expect(html, contains('var __lyricsVertical = true;'));

      // The container main axis flips to a row so cues lay out as columns.
      final String containerRule = _cssBlock(html, '.lyrics-container {');
      expect(containerRule, contains('flex-direction: row;'));

      // Scrolling is delta/incremental (scrollBy) to dodge vertical-rl's
      // negative scrollX coordinate, not absolute scrollTo.
      expect(html, contains('window.scrollBy(d, 0)'));
      expect(html, contains('_lyricsScrollByAxis'));
    });

    // TODO-1080: an over-long sentence can be taller (vertical-rl) or wider than
    // the screen and gets clipped by the body's overflow-hidden. The page must
    // ship a measure-then-shrink pass (__lyricsFitCues) that overrides only an
    // overflowing cue's inline font-size, keeping every fitting cue at the base.
    group('over-long cue auto-shrink (TODO-1080)', () {
      String buildHtml({bool vertical = false, double fontSize = 24}) {
        return LyricsModeHtml.generate(
          cues: <AudioCue>[_cue(0), _cue(1)],
          currentIndex: 0,
          backgroundColor: 'rgba(255,255,255,1.00)',
          textColor: 'rgba(0,0,0,1.00)',
          accentColor: 'rgba(255,220,0,1.00)',
          fontSize: fontSize,
          vertical: vertical,
        );
      }

      test('base cue font-size flows from the --cue-font-size custom prop', () {
        final String html = buildHtml(fontSize: 30);
        // The base size is a custom prop so JS can shrink one cue without
        // beating it via a fixed .cue font-size.
        expect(html, contains('--cue-font-size: 30.0px;'));
        final String cueRule = _cssBlock(html, '.cue {');
        expect(cueRule, contains('font-size: var(--cue-font-size);'));
        // No fixed px font-size baked onto the .cue rule itself.
        expect(cueRule, isNot(contains('font-size: 30.0px')));
      });

      test('ships a measure-then-shrink fit pass over all cues', () {
        final String html = buildHtml();
        expect(html, contains('function __lyricsFitCues()'));
        expect(html, contains('window.__lyricsFitCues = __lyricsFitCues;'));
        // The pass is invoked on initial load before scroll positioning.
        expect(html, contains('__lyricsFitCues();'));
        // Only overflowing cues get an inline override; fitting cues are cleared.
        expect(html, contains("el.style.fontSize = ''"));
        expect(html, contains('function _lyricsFitCue('));
      });

      test('shrink is clamped to a readable minimum floor', () {
        final String html = buildHtml();
        expect(html, contains('__LYRICS_MIN_FONT_PX = 12'));
        expect(html, contains('Math.max(__LYRICS_MIN_FONT_PX'));
      });

      test(
          'fit measures the constraining axis (height vertical, width horizontal)',
          () {
        final String html = buildHtml();
        // Scale-independent layout-box extents (offsetHeight/offsetWidth), not
        // getBoundingClientRect which would fold in the .current scale.
        expect(html,
            contains('__lyricsVertical ? el.offsetHeight : el.offsetWidth'));
        // Available extent is discounted by --cue-scale so a cue that fits
        // un-scaled but overflows once enlarged still fits.
        expect(html, contains('/ scale'));
      });

      test('live style update retargets the base var and re-fits (no reload)',
          () {
        final String html = buildHtml();
        // Font-size live update writes the --cue-font-size prop (not a fixed
        // .cue font-size) so the refit re-measures against the new base.
        expect(
            html,
            contains(
                "root.style.setProperty('--cue-font-size', fontSize + 'px')"));
        // __lyricsUpdateStyle re-runs the fit pass after mutating base/margins.
        final String updateFn =
            _fnBody(html, 'window.__lyricsUpdateStyle = function');
        expect(updateFn, contains('__lyricsFitCues();'));
      });

      test('re-fits on viewport resize (rotation / window resize)', () {
        final String html = buildHtml();
        expect(html, contains("window.addEventListener('resize'"));
        expect(html, contains('__lyricsFitCues()'));
      });
    });
  });
}

/// Returns the body of the first CSS rule whose declaration starts with
/// [selectorWithBrace] (e.g. `.cue {`), i.e. the text between `{` and `}`.
String _cssBlock(String css, String selectorWithBrace) {
  final int start = css.indexOf(selectorWithBrace);
  expect(start, isNonNegative, reason: 'missing rule: $selectorWithBrace');
  final int open = css.indexOf('{', start);
  final int close = css.indexOf('}', open);
  expect(close, isNonNegative, reason: 'unterminated rule: $selectorWithBrace');
  return css.substring(open + 1, close);
}

/// Returns the source of a JS function assignment starting at [signature]
/// (e.g. `window.__lyricsUpdateStyle = function`), spanning from its opening
/// brace to the matching closing brace via depth counting.
String _fnBody(String src, String signature) {
  final int start = src.indexOf(signature);
  expect(start, isNonNegative, reason: 'missing fn: $signature');
  final int open = src.indexOf('{', start);
  int depth = 0;
  for (int i = open; i < src.length; i++) {
    final String ch = src[i];
    if (ch == '{') depth++;
    if (ch == '}') {
      depth--;
      if (depth == 0) return src.substring(open + 1, i);
    }
  }
  fail('unterminated fn: $signature');
}

AudioCue _cue(int index) {
  return AudioCue()
    ..id = index + 1
    ..bookKey = 'book'
    ..chapterHref = 'chapter'
    ..sentenceIndex = index
    ..textFragmentId = ''
    ..text = 'cue $index'
    ..startMs = index * 1000
    ..endMs = index * 1000 + 500
    ..audioFileIndex = 0;
}
