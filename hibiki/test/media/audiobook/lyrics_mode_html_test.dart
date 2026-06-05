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

    test('current cue click uses selection without disabling native selection',
        () {
      final String html = LyricsModeHtml.generate(
        cues: <AudioCue>[_cue(0)],
        currentIndex: 0,
        backgroundColor: 'rgba(255,255,255,1.00)',
        textColor: 'rgba(0,0,0,1.00)',
        accentColor: 'rgba(255,220,0,1.00)',
        fontSize: 20,
      );

      expect(
        html,
        contains('window.hoshiSelection.selectText(e.clientX, e.clientY, 400)'),
      );
      expect(html, isNot(contains('-webkit-user-select: none;')));
      expect(html, isNot(contains('user-select: none;')));
      expect(html, isNot(contains('var _longPressed')));
      expect(html, isNot(contains("document.addEventListener('pointerdown'")));
      expect(html, isNot(contains("document.addEventListener('touchstart'")));
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
