import 'package:flutter_test/flutter_test.dart';

import 'reader_fushi_page_source_corpus.dart';

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
    final int finalizeCall =
        onLoadStop.indexOf('_finalizeLyricsDocumentIfReady(');
    expect(lyricsModeBranch, isNonNegative);
    expect(finalizeCall, isNonNegative);

    final String finalize = _functionSource(
      source,
      '  Future<bool> _finalizeLyricsDocumentIfReady(',
      '  Future<void> _onChapterLoadComplete(',
    );
    final int guardCall = finalize.indexOf('_isLoadedLyricsDocument(');
    final int completeCall = finalize.indexOf('_onChapterLoadComplete(');
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
    expect(guard, contains('window.__fushiLyricsLoadGeneration'));
    expect(source, contains('int _lyricsLoadGeneration = 0;'));
    expect(source, contains('++_lyricsLoadGeneration'));
    expect(source, contains('loadGeneration: loadGeneration'));
    expect(source, contains('generation != _lyricsLoadGeneration'));
    expect(source, contains('lyricsGeneration: generation'));
    expect(source, contains('int? _lyricsDocumentLoadGeneration;'));
    expect(source, contains(r"'generation': '$loadGeneration'"));
    expect(source, contains('_isCurrentLyricsDocumentUrl(url)'));
    expect(source,
        contains('_lyricsDocumentGenerationFromUrl(request.url.toString())'));
    expect(source, isNot(contains('bool _lyricsDocumentLoadInFlight')));
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
