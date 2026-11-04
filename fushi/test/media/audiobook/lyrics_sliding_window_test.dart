import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/lyrics_mode_html.dart';
import 'package:fushi_audio/fushi_audio.dart';

import '../../pages/reader_fushi_page_source_corpus.dart';

/// 歌词模式滑动窗口（用户 2026-11-03：「自动播放到一定程度后面的文字是空白，拨过去才
/// 重新刷新加载」；「收起底部栏的时候字幕跳得很远」）。
///
/// 根因：歌词文档只装当前句前后各 300 句，播到窗口尾部后面就是空白，越界才整页
/// 重载；视口 resize 只重新适配字号、不重新对准当前句，竖排列高一变当前句就漂走。
/// 修法：窗口接近边缘时原地拼接（`__lyricsSpliceCues`）+ 远端卸载；resize 后按锚点句复位。
AudioCue _cue(int i) => AudioCue()
  ..id = i + 1
  ..bookKey = 'book'
  ..chapterHref = 'chapter'
  ..sentenceIndex = i
  ..textFragmentId = ''
  ..text = '行$i'
  ..startMs = i * 1000
  ..endMs = i * 1000 + 900
  ..audioFileIndex = 0;

String _doc({bool before = false, bool after = false}) =>
    LyricsModeHtml.generate(
      cues: <AudioCue>[for (int i = 0; i < 5; i++) _cue(i)],
      currentIndex: 2,
      hasCuesBefore: before,
      hasCuesAfter: after,
      backgroundColor: 'transparent',
      textColor: '#888888',
      accentColor: '#3366cc',
      fontSize: 24,
    );

String _between(String source, String start, String end) {
  final int from = source.indexOf(start);
  expect(from, isNonNegative, reason: 'missing $start');
  final int to = source.indexOf(end, from + start.length);
  expect(to, isNonNegative, reason: 'missing $end');
  return source.substring(from, to);
}

void main() {
  test('incremental rows carry no current / near classes', () {
    final String rows = LyricsModeHtml.cueRowsHtml(
      cues: <AudioCue>[for (int i = 0; i < 4; i++) _cue(i)],
    );
    expect(RegExp('class="cue"').allMatches(rows).length, 4);
    expect(rows, isNot(contains('current')));
    expect(rows, isNot(contains('near-')));
  });

  test('full document keeps near classes around the current cue', () {
    final String doc = _doc();
    expect(doc, contains('class="cue current" data-cue-index="2"'));
    expect(doc, contains('class="cue near-1" data-cue-index="1"'));
    expect(doc, contains('class="cue near-2" data-cue-index="0"'));
  });

  test('document tells JS whether more cues exist on each side', () {
    expect(
      _doc(before: true),
      contains('var _lyHasBefore = true, _lyHasAfter = false'),
    );
    expect(
      _doc(after: true),
      contains('var _lyHasBefore = false, _lyHasAfter = true'),
    );
  });

  test('document splices cues in place and requests edges', () {
    final String doc = _doc(after: true);
    expect(doc, contains('window.__lyricsSpliceCues = function('));
    expect(doc, contains("callHandler('onLyricsEdge'"));
    // 拼接后由脚本按锚点补偿，浏览器自带的滚动锚定关掉免得补两次。
    expect(doc, contains('overflow-anchor: none'));
  });

  test('blur mode reveals the current cue only while paused', () {
    // 用户 2026-11-03：模糊歌词暂停时显出当前句，继续播放重新模糊。
    expect(
      _doc(),
      contains('body.lyrics-blur.ly-paused .cue.current {\n  filter: blur(0);'),
    );
    expect(
      _doc(),
      contains("document.body.classList.toggle('ly-paused', !_lyPlaying);"),
    );
  });

  test('resize re-anchors instead of only re-fitting', () {
    final String doc = _doc();
    final String resize = _between(
      doc,
      "window.addEventListener('resize', function() {",
      '});',
    );
    expect(resize, contains('_lyReanchorAfterResize()'));
  });

  test('playback near the window edge slides it before any reload', () {
    final String source = readReaderPageSource();
    final String sync = _between(
      source,
      '  void _syncLyricsOverlayCue(',
      '    final bool scroll =',
    );
    final int slide = sync.indexOf('_slideLyricsWindow(forward: true)');
    final int reload = sync.indexOf('unawaited(_loadLyricsPage())');
    expect(slide, isNonNegative);
    expect(sync, contains('_slideLyricsWindow(forward: false)'));
    // 章 cue 换章的重载在前面；窗口越界重载必须排在滑动之后。
    expect(
      sync.lastIndexOf('unawaited(_loadLyricsPage())'),
      greaterThan(slide),
    );
    expect(reload, isNonNegative);
    expect(source, contains("handlerName: 'onLyricsEdge'"));
    final String slideFn = _between(
      source,
      '  void _slideLyricsWindow({required bool forward}) {',
      '  /// 歌词 WebView 上的 fire-and-forget 求值',
    );
    expect(slideFn, contains('__lyricsSpliceCues'));
    expect(slideFn, contains('LyricsModeHtml.cueRowsHtml('));
  });
}
