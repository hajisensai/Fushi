import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/lyrics_cue_window_slide.dart';
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
    final int slide = sync.indexOf(
      '_slideLyricsWindow(forward: true, anchor: sourceIdx)',
    );
    final int reload = sync.indexOf('unawaited(_loadLyricsPage())');
    expect(slide, isNonNegative);
    expect(
      sync,
      contains('_slideLyricsWindow(forward: false, anchor: sourceIdx)'),
    );
    // 章 cue 换章的重载在前面；窗口越界重载必须排在滑动之后。
    expect(
      sync.lastIndexOf('unawaited(_loadLyricsPage())'),
      greaterThan(slide),
    );
    expect(reload, isNonNegative);
    expect(source, contains("handlerName: 'onLyricsEdge'"));
    final String slideFn = _between(
      source,
      '  bool _slideLyricsWindow({required bool forward, required int anchor}) {',
      '  /// 歌词 WebView 上的 fire-and-forget 求值',
    );
    expect(slideFn, contains('__lyricsSpliceCues'));
    expect(slideFn, contains('LyricsModeHtml.cueRowsHtml('));
    // 裁剪量统一由纯函数按锚点算（上限对锚点生效），不再在这里只看播放句。
    expect(slideFn, contains('planLyricsWindowSlide('));
    expect(slideFn, isNot(contains('lyricsCueAllBookIdx')));
  });

  // BUG-4004 复审：手动浏览时窗口锚在视口中线句，不在播放句。
  test(
    'manual browsing anchors the window on the viewport, not the player',
    () {
      final String source = readReaderPageSource();
      final String sync = _between(
        source,
        '  void _syncLyricsOverlayCue(',
        '    final bool scroll =',
      );
      // 浏览中播放推进不滑窗口；播放句走出窗口只摘高亮，不重载（重载会拽走视口）。
      final int follows = sync.indexOf('final bool follows =');
      expect(follows, isNonNegative);
      expect(sync, contains('_lyricsCueWindowUsesAllBookCues && follows'));
      // BUG-4007 R2：摘高亮的同时照样下发播放态（见 lyrics_play_state_sync_test）。
      const String clear =
          'overlaySyncScript(playing: playing, clearCue: true)';
      expect(sync, contains(clear));
      expect(
        sync.indexOf(clear),
        lessThan(sync.lastIndexOf('unawaited(_loadLyricsPage())')),
      );

      final String edge = _between(
        source,
        "handlerName: 'onLyricsEdge',",
        'controller.addJavaScriptHandler(',
      );
      expect(edge, contains('_lyricsFollowsPlayback(ctrl)'));
      expect(edge, contains('_lyricsCueIndexOffset + viewRel'));
      expect(edge, contains('__lyricsEdgeIdle'));

      final String browse = _between(
        source,
        "handlerName: 'onLyricsBrowse',",
        'controller.addJavaScriptHandler(',
      );
      expect(browse, contains('_lyricsJsBrowsing = browsing'));
      expect(browse, contains('_resyncLyricsOverlayToAudio()'));
    },
  );

  test('document reports the viewport anchor and browse transitions', () {
    final String doc = _doc(after: true);
    expect(
      doc,
      contains(
        "bridge.callHandler('onLyricsEdge', dir, window.__fushiLyricsLoadGeneration,\n"
        '        _lyViewAnchorIndex());',
      ),
    );
    expect(doc, contains('window.__lyricsEdgeIdle = function(dir)'));
    expect(
      doc,
      contains(
        "bridge.callHandler('onLyricsBrowse', on, window.__fushiLyricsLoadGeneration);",
      ),
    );
    // 浏览态只经 _lySetBrowsing 写（否则 Dart 收不到进出）。
    expect(
      RegExp(r'_lyBrowsing = (true|false);').allMatches(doc).length,
      0,
      reason: '浏览态必须只经 _lySetBrowsing 写',
    );
    // 拼接锚点优先视口中线句，补偿滚动取第一个仍在文档里的锚点。
    final String splice = _between(
      doc,
      'window.__lyricsSpliceCues = function(',
      '_lyEdgeWant = 0;',
    );
    expect(splice, contains('_lyCueAtCenter()'));
    expect(splice, contains('if (!anchors[a].isConnected) continue;'));
    // setCue(-1)：播放句不在窗口里时只摘高亮。
    expect(
      doc,
      contains('if (index < 0 || index >= len) { _currentIdx = -1; return; }'),
    );
  });
  // BUG-4130（反馈 NSP86pcPHI）：歌词模式下正文跟着音频跨章，每装一章 reader 都重灌
  // 整书 cue；旧码装章后无条件整页重载歌词文档，下一章的句子明明已在窗口里也重载。
  group('跨章不重载歌词文档（BUG-4130）', () {
    final List<AudioCue> all = <AudioCue>[for (int i = 0; i < 10; i++) _cue(i)];

    test('重灌同一份整书 cue（新列表、同元素）：窗口仍是同一段', () {
      final List<AudioCue> window = all.sublist(3, 8);
      // setAllBookCues 每次 List.from：列表身份变、元素身份不变。
      final List<AudioCue> reinjected = List<AudioCue>.from(all);
      expect(identical(reinjected, all), isFalse);
      expect(
        lyricsWindowIsSliceOf<AudioCue>(
          window: window,
          offset: 3,
          source: reinjected,
        ),
        isTrue,
      );
    });

    test('整书 cue 元素换了（重新对齐 / SRT 重建）：判为失效 → 重载', () {
      final List<AudioCue> window = all.sublist(3, 8);
      final List<AudioCue> rebuilt = <AudioCue>[
        for (int i = 0; i < 10; i++) _cue(i),
      ];
      expect(
        lyricsWindowIsSliceOf<AudioCue>(
          window: window,
          offset: 3,
          source: rebuilt,
        ),
        isFalse,
      );
      // 整书 cue 变短 / 偏移错位 / 空窗口同样失效。
      expect(
        lyricsWindowIsSliceOf<AudioCue>(
          window: window,
          offset: 3,
          source: all.sublist(0, 6),
        ),
        isFalse,
      );
      expect(
        lyricsWindowIsSliceOf<AudioCue>(window: window, offset: 2, source: all),
        isFalse,
      );
      expect(
        lyricsWindowIsSliceOf<AudioCue>(
          window: const <AudioCue>[],
          offset: 0,
          source: all,
        ),
        isFalse,
      );
    });

    test('装章重灌 cue 后不整页重载歌词，交给 _syncLyricsOverlayCue 按数据源判', () {
      final String source = readReaderPageSource();
      final String inject = _between(
        source,
        '  Future<void> _injectAudiobookBridge() async {',
        '\n  }\n',
      );
      expect(inject, contains('setAllBookCues('));
      expect(inject, contains('_onCueChanged();'));
      expect(
        inject,
        isNot(contains('_loadLyricsPage')),
        reason: '旧码：歌词模式下每装一章都 post-frame 整页重载歌词文档',
      );

      final String onCue = _between(
        source,
        '  void _onCueChanged() {',
        '    final bool navigationReveal =',
      );
      expect(onCue, contains('_syncLyricsOverlayCue(controller'));

      final String sync = _between(
        source,
        '  void _syncLyricsOverlayCue(',
        '    final bool scroll =',
      );
      // 无整书 cue 的书：按章 cue 列表身份重载（跨章照常换章）。
      final int chapterReload = sync.indexOf(
        '!identical(controller.chapterCuesSnapshot, _lyricsCueList)',
      );
      // 整书 cue 窗口：元素身份校验失败才重载，且排在任何 setCue 下发之前。
      final int sliceCheck = sync.indexOf('lyricsWindowIsSliceOf<AudioCue>(');
      final int firstSetCue = sync.indexOf('overlaySyncScript(');
      expect(chapterReload, isNonNegative);
      expect(sliceCheck, greaterThan(chapterReload));
      expect(firstSetCue, greaterThan(sliceCheck));
      expect(
        sync.substring(sliceCheck, firstSetCue),
        contains('unawaited(_loadLyricsPage())'),
      );
      expect(
        sync.substring(sliceCheck - 200, sliceCheck),
        contains('_lyricsCueWindowUsesAllBookCues &&'),
      );

      // 滑动窗口与同步共用同一判据。
      final String slideFn = _between(
        source,
        '  bool _slideLyricsWindow({required bool forward, required int anchor}) {',
        '  /// 歌词 WebView 上的 fire-and-forget 求值',
      );
      expect(slideFn, contains('lyricsWindowIsSliceOf<AudioCue>('));
    });
  });
}
