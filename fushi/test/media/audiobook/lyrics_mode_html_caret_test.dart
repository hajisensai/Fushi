import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi/src/media/audiobook/lyrics_mode_html.dart';

void main() {
  AudioCue cue(int i, String text) => AudioCue()
    ..bookKey = 'b'
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

  test('notifies Dart only after the lyrics DOM API is initialized', () {
    final String source = html();
    final int sentinel = source.indexOf('window.__lyricsSetCue');
    final int ready = source.indexOf("callHandler('onLyricsReady'");
    expect(sentinel, greaterThanOrEqualTo(0));
    expect(ready, greaterThan(sentinel));
    expect(source, contains("typeof bridge.callHandler !== 'function'"));
  });

  // BUG-1809 根因纪律：就绪信号必须走「插件在 AT_DOCUMENT_START 注入的 bridge
  // 对象」这个确定原语，不能退化成轮询/rAF，也不能把
  // `flutterInAppWebViewPlatformReady` 当主路径 —— 四个平台都在派发 onLoadStop
  // 的同一个 native 回调里派发该事件（iOS InAppWebView.swift:1925 vs :1934），
  // 正是 BUG-1809 失效的那个回调；iOS/macOS 甚至不设 `_platformReady` 标志。
  group('ready notifier uses the document-start bridge, not a timer', () {
    test('no polling: no retry budget and no setTimeout re-arm', () {
      final String source = html();
      expect(source, isNot(contains('attempt < 100')));
      expect(source, isNot(contains('notifyLyricsReady(attempt')));
      expect(source,
          isNot(contains('window.setTimeout(function() { notifyLyricsReady')));
    });

    test('no requestAnimationFrame wrapper around the ready callHandler', () {
      final String source = html();
      final int ready = source.indexOf("callHandler('onLyricsReady'");
      expect(ready, greaterThanOrEqualTo(0));
      // 取 ready 调用前 200 字符的窗口：rAF 包装只可能出现在这里。
      final String before = source.substring(
        ready < 200 ? 0 : ready - 200,
        ready,
      );
      expect(before, isNot(contains('requestAnimationFrame')));
    });

    test('platform-ready event is only a fallback behind a synchronous call',
        () {
      final String source = html();
      final int ready = source.indexOf("callHandler('onLyricsReady'");
      final int listener =
          source.indexOf("addEventListener('flutterInAppWebViewPlatformReady'");
      expect(ready, greaterThanOrEqualTo(0));
      expect(listener, greaterThan(ready),
          reason: '事件监听必须在同步调用之后注册，且只在同步调用没打出去时才挂上');
      expect(source, contains('if (!fired) {'));
      expect(source, contains('{once: true}'));
    });
  });
}
