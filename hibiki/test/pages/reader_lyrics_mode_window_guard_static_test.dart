import 'package:flutter_test/flutter_test.dart';

import 'reader_hibiki_page_source_corpus.dart';

void main() {
  test('lyrics mode windows all-book cues before rendering HTML', () {
    final String source = readReaderPageSource();
    final String loadLyrics = _functionSource(
      source,
      '  Future<void> _loadLyricsPage() async {',
      '  /// TODO-368: 歌词字幕文字色',
    );

    expect(
      loadLyrics,
      contains('LyricsCueWindow'),
      reason: '歌词模式不能把整本 allBookCuesSnapshot 直接塞进一个 WebView HTML。',
    );
    expect(
      loadLyrics,
      contains('_lyricsCueIndexOffset'),
      reason: '窗口化后 Dart→JS 当前 cue index 必须能从全书索引换算为窗口内索引。',
    );
    expect(
      loadLyrics,
      isNot(contains('ctrl.allBookCuesSnapshot.isNotEmpty\n'
          '        ? ctrl.allBookCuesSnapshot\n'
          '        : ctrl.chapterCuesSnapshot')),
      reason: '直接选择整本 allBookCuesSnapshot 会让大书 iOS WebView loadData 超时/白屏。',
    );
  });

  test('lyrics cue updates translate global all-book index into window index',
      () {
    final String source = readReaderPageSource();
    final String cueChanged = _functionSource(
      source,
      '  void _onCueChanged() {',
      '    final AudioCue? cue = controller.currentCue;',
    );

    expect(
      cueChanged,
      contains('_lyricsCueIndexOffset'),
      reason: '歌词页只渲染窗口时，cue 更新必须扣除窗口起点。',
    );
    expect(
      cueChanged,
      contains('_loadLyricsPage()'),
      reason: '播放位置走出当前歌词窗口时必须重载邻近窗口，不能静默停住。',
    );
  });
}

String _functionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}
