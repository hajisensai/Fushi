import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_lyrics_caret_scripts.dart';

void main() {
  group('ReaderLyricsCaretScripts.source()', () {
    final String src = ReaderLyricsCaretScripts.source();

    test('defines the fushiLyricsCaret object and core API', () {
      expect(src, contains('window.fushiLyricsCaret'));
      for (final String fn in <String>[
        'enter:',
        'exit:',
        'move:',
        'lookup:',
        'activate:',
        'scrollPage:',
        'refresh:',
        'init:',
        'suspend:',
        'resume:',
      ]) {
        expect(src, contains(fn), reason: 'missing $fn');
      }
    });

    test('line moves go through cue index + __lyricsScrollToCue', () {
      expect(src, contains('__lyricsScrollToCue'));
      expect(src, contains('__lyricsGetCurrentIndex'));
      expect(src, contains('_lineMove'));
    });

    test('lookup reuses fushiSelection.selectFromPosition with cue context',
        () {
      expect(src, contains('window.fushiSelection'));
      expect(src, contains('selectFromPosition'));
      expect(src, contains('__lyricsCueContext'));
      expect(src, contains('data-text-fragment-id'));
    });
  });

  group('ReaderLyricsCaretScripts invocations target fushiLyricsCaret', () {
    test('enter/exit/move/scrollPage/lookup/activate/refresh', () {
      expect(ReaderLyricsCaretScripts.enterInvocation(),
          'JSON.stringify(window.fushiLyricsCaret.enter())');
      expect(ReaderLyricsCaretScripts.exitInvocation(),
          'window.fushiLyricsCaret.exit()');
      expect(ReaderLyricsCaretScripts.moveInvocation('up'),
          "JSON.stringify(window.fushiLyricsCaret.move('up'))");
      expect(ReaderLyricsCaretScripts.scrollPageInvocation(true),
          'JSON.stringify(window.fushiLyricsCaret.scrollPage(true))');
      expect(ReaderLyricsCaretScripts.lookupInvocation(),
          'window.fushiLyricsCaret.lookup()');
      expect(ReaderLyricsCaretScripts.activateInvocation(),
          'window.fushiLyricsCaret.activate()');
      expect(ReaderLyricsCaretScripts.refreshInvocation(),
          'JSON.stringify(window.fushiLyricsCaret.refresh())');
      expect(ReaderLyricsCaretScripts.suspendInvocation(),
          'window.fushiLyricsCaret.suspend()');
      expect(ReaderLyricsCaretScripts.resumeInvocation(),
          'JSON.stringify(window.fushiLyricsCaret.resume())');
      expect(ReaderLyricsCaretScripts.longPressInvocation(),
          'window.fushiLyricsCaret.longPress()');
    });

    test('initInvocation carries ring color', () {
      final String js = ReaderLyricsCaretScripts.initInvocation(
        color: 'rgba(1,2,3,0.98)',
        insetTop: 10,
        insetBottom: 0,
      );
      expect(js, contains('window.fushiLyricsCaret.init('));
      expect(js, contains('rgba(1,2,3,0.98)'));
    });
  });
}
