import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_lyrics_caret_scripts.dart';

void main() {
  group('ReaderLyricsCaretScripts.source()', () {
    final String src = ReaderLyricsCaretScripts.source();

    test('defines the hoshiLyricsCaret object and core API', () {
      expect(src, contains('window.hoshiLyricsCaret'));
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

    test('lookup reuses hoshiSelection.selectFromPosition with cue context',
        () {
      expect(src, contains('window.hoshiSelection'));
      expect(src, contains('selectFromPosition'));
      expect(src, contains('__lyricsCueContext'));
      expect(src, contains('data-text-fragment-id'));
    });
  });

  group('ReaderLyricsCaretScripts invocations target hoshiLyricsCaret', () {
    test('enter/exit/move/scrollPage/lookup/activate/refresh', () {
      expect(ReaderLyricsCaretScripts.enterInvocation(),
          'JSON.stringify(window.hoshiLyricsCaret.enter())');
      expect(ReaderLyricsCaretScripts.exitInvocation(),
          'window.hoshiLyricsCaret.exit()');
      expect(ReaderLyricsCaretScripts.moveInvocation('up'),
          "JSON.stringify(window.hoshiLyricsCaret.move('up'))");
      expect(ReaderLyricsCaretScripts.scrollPageInvocation(true),
          'JSON.stringify(window.hoshiLyricsCaret.scrollPage(true))');
      expect(ReaderLyricsCaretScripts.lookupInvocation(),
          'window.hoshiLyricsCaret.lookup()');
      expect(ReaderLyricsCaretScripts.activateInvocation(),
          'window.hoshiLyricsCaret.activate()');
      expect(ReaderLyricsCaretScripts.refreshInvocation(),
          'JSON.stringify(window.hoshiLyricsCaret.refresh())');
      expect(ReaderLyricsCaretScripts.suspendInvocation(),
          'window.hoshiLyricsCaret.suspend()');
      expect(ReaderLyricsCaretScripts.resumeInvocation(),
          'JSON.stringify(window.hoshiLyricsCaret.resume())');
      expect(ReaderLyricsCaretScripts.longPressInvocation(),
          'window.hoshiLyricsCaret.longPress()');
    });

    test('initInvocation carries ring color', () {
      final String js = ReaderLyricsCaretScripts.initInvocation(
        color: 'rgba(1,2,3,0.98)',
        insetTop: 10,
        insetBottom: 0,
      );
      expect(js, contains('window.hoshiLyricsCaret.init('));
      expect(js, contains('rgba(1,2,3,0.98)'));
    });
  });
}
