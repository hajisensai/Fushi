import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/lyrics_mode_html.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

import '../../pages/reader_hibiki_page_source_corpus.dart';

/// BUG-019 回归守卫：歌词模式「自动音频跟随」开关必须真控制自动滚动。
///
/// 根因：`_onCueChanged` 的歌词分支原来无条件 `__lyricsSetCue(idx)`，
/// 而 `setCue` 末尾恒调 `scrollToCenter` —— 从不读 `followAudio.value`，
/// 所以跟随关掉后歌词仍自动滚到当前句（开关失效）。非歌词路径靠
/// `shouldRevealCurrentCue`（controller 内 `followAudio.value && ...`）门控。
///
/// 修复：① JS `setCue(index, scroll)` 把 `scrollToCenter` 门控到 `scroll`，类
/// 切换（当前句高亮）照旧；② Dart 把 `controller.followAudio.value` 透传进
/// `__lyricsSetCue`。两层都用源码/生成器扫描守卫——reader 页含真实 WebView，
/// `_onCueChanged` 无法 widget 挂载，JS 滚动是 WebView 行为，最强可落地层是
/// 「生成的 HTML 契约」+「reader 源码透传 followAudio」。
void main() {
  AudioCue cue(int i) => AudioCue()
    ..id = i + 1
    ..bookKey = 'book'
    ..chapterHref = 'chapter'
    ..sentenceIndex = i
    ..textFragmentId = ''
    ..text = 'cue $i'
    ..startMs = i * 1000
    ..endMs = i * 1000 + 900
    ..audioFileIndex = 0;

  test('lyrics setCue gates auto-scroll on a scroll flag', () {
    final String html = LyricsModeHtml.generate(
      cues: <AudioCue>[cue(0), cue(1), cue(2)],
      currentIndex: 0,
      backgroundColor: 'rgba(255,255,255,1.00)',
      textColor: 'rgba(0,0,0,1.00)',
      accentColor: 'rgba(255,220,0,1.00)',
      fontSize: 20,
    );

    // setCue 接受 scroll 形参，scrollToCenter 受其门控（关跟随时不滚）。
    expect(html, contains('function setCue(index, scroll)'));
    expect(
        html,
        contains(
            'if (scroll !== false && !window.__lyricsCaretActive) scrollToCenter'));
    // 桥接把第二参（followAudio）透传给 setCue。
    expect(html, contains('window.__lyricsSetCue = function(index, scroll)'));
    // 旧码（恒调 scrollToCenter、单参 setCue）下这三条全红——非同义反复。
    expect(html, isNot(contains('window.__lyricsSetCue = function(index) {')));
  });

  test(
      'reader _onCueChanged passes followAudio (+force-reveal) into __lyricsSetCue',
      () {
    final String src = readReaderPageSource();

    // 歌词分支必须把跟随开关透传进 JS scroll 形参（否则自动滚动永远发生）。
    // BUG-756 后 scroll = followAudio || forceReveal（snap 也放行），故断言从
    // 旧的 `${controller.followAudio.value}` 直插改成新的派生变量与推导式。
    expect(src, contains(r'__lyricsSetCue($idx, $scroll)'));
    expect(src, contains('controller.followAudio.value || forceReveal'));
  });

  test('lyrics branch consumes force-reveal and re-centers on snap (BUG-756)',
      () {
    final String src = readReaderPageSource();

    // ① force-reveal 一次性旗必须**也在歌词分支**消费——否则 snapReaderToAudio
    //   置的位会泄漏到之后退回正文的 _onCueChanged，凭空多滚。原来只有正文分支调一次
    //   consumeForceReveal()；歌词分支补上后全语料至少 2 处（非同义反复）。
    expect(
      'consumeForceReveal()'.allMatches(src).length,
      greaterThanOrEqualTo(2),
      reason: '歌词分支必须独立消费 force-reveal，防泄漏到正文路径',
    );
    // ② snap 那刻 cue 常没变，__lyricsSetCue 的 index===_currentIdx 早退会吞掉回中；
    //   forceReveal 下必须再显式 __lyricsScrollToCue 强制居中（绕过早退）。
    //   该调用只在 reader 页 Dart 侧（语料）出现，HTML 生成器的函数定义不在语料内。
    expect(src, contains(r'window.__lyricsScrollToCue($idx)'));
  });
}
