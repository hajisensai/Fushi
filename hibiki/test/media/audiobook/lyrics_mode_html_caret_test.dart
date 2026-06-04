import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/src/media/audiobook/lyrics_mode_html.dart';

void main() {
  AudioCue cue(int i, String text) => AudioCue()
    ..bookUid = 'b'
    ..chapterHref = 'c'
    ..sentenceIndex = i
    ..textFragmentId = 'frag-$i'
    ..text = text
    ..startMs = i * 1000
    ..endMs = i * 1000 + 900
    ..audioFileIndex = 0;

  String html() => LyricsModeHtml.generate(
        cues: <AudioCue>[cue(0, 'ねこ'), cue(1, 'いぬ'), cue(2, 'とり')],
        currentIndex: 1,
        backgroundColor: 'rgba(0,0,0,1.00)',
        textColor: 'rgba(255,255,255,1.00)',
        accentColor: 'rgba(255,200,0,1.00)',
        fontSize: 24,
      );

  test('exposes __lyricsScrollToCue helper for the caret', () {
    expect(html(), contains('window.__lyricsScrollToCue'));
  });

  test('setCue auto-scroll is gated by __lyricsCaretActive', () {
    // 焦点激活时 setCue 只换高亮、不抢滚动。
    expect(html(), contains('__lyricsCaretActive'));
  });
}
