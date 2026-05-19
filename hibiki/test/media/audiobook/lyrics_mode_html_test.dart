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
  });
}

AudioCue _cue(int index) {
  return AudioCue()
    ..id = index + 1
    ..bookUid = 'book'
    ..chapterHref = 'chapter'
    ..sentenceIndex = index
    ..textFragmentId = ''
    ..text = 'cue $index'
    ..startMs = index * 1000
    ..endMs = index * 1000 + 500
    ..audioFileIndex = 0;
}
