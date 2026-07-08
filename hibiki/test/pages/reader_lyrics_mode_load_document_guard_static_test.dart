import 'package:flutter_test/flutter_test.dart';

import 'reader_hibiki_page_source_corpus.dart';

void main() {
  test('lyrics-mode onLoadStop verifies the loaded document before readying it',
      () {
    final String source = readReaderPageSource();
    final String onLoadStop = _sectionSource(
      source,
      '      onLoadStop: (controller, url) async {',
      '      onReceivedError: (controller, request, error) async {',
    );

    expect(
      source,
      contains('Future<bool> _isLoadedLyricsDocument('),
      reason: '歌词模式 load stop 必须用 DOM/JS sentinel 判断当前文档是否真是歌词页。',
    );

    final int lyricsModeBranch = onLoadStop.indexOf('if (_lyricsMode)');
    final int guardCall =
        onLoadStop.indexOf('_isLoadedLyricsDocument(controller)');
    final int completeCall =
        onLoadStop.indexOf('_onChapterLoadComplete(controller)');
    expect(lyricsModeBranch, isNonNegative);
    expect(guardCall, isNonNegative);
    expect(completeCall, isNonNegative);
    expect(
      guardCall,
      lessThan(completeCall),
      reason: '旧 EPUB 正文页的 onLoadStop 可能在进入歌词模式后晚到，必须先过滤。',
    );

    final String guard = _functionSource(
      source,
      '  Future<bool> _isLoadedLyricsDocument(',
      '  Future<void> _onChapterLoadComplete(',
    );
    expect(guard, contains('window.__lyricsSetCue'));
    expect(guard, contains("document.getElementById('lc')"));
  });
}

String _sectionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}

String _functionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}
