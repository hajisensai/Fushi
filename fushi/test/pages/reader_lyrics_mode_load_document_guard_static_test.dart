import 'package:flutter_test/flutter_test.dart';

import 'reader_fushi_page_source_corpus.dart';

void main() {
  test('lyrics-mode onLoadStop verifies the loaded document before readying it',
      () {
    final String source = readReaderPageSource();
    // 2026-10-04 覆盖层架构：歌词有自己的 WebView（[_buildLyricsWebView]），它的
    // onLoadStop 只走歌词 finalize；正文 WebView 的 onLoadStop 不再有歌词分支。
    final String lyricsWebView = _sectionSource(
      source,
      '  Widget _buildLyricsWebView() {',
      '    // 文档就绪前保持透明',
    );
    final String onLoadStop = _sectionSource(
      lyricsWebView,
      '      onLoadStop: (InAppWebViewController controller, WebUri? url) async {',
      '      onReceivedError: (',
    );

    expect(
      source,
      contains('Future<bool> _isLoadedLyricsDocument('),
      reason: '歌词模式 load stop 必须用 DOM/JS sentinel 判断当前文档是否真是歌词页。',
    );

    final int finalizeCall =
        onLoadStop.indexOf('_finalizeLyricsDocumentIfReady(');
    expect(finalizeCall, isNonNegative);

    final String finalize = _functionSource(
      source,
      '  Future<bool> _finalizeLyricsDocumentIfReady(',
      '  Future<void> _onChapterLoadComplete(',
    );
    final int guardCall = finalize.indexOf('_isLoadedLyricsDocument(');
    final int completeCall = finalize.indexOf('_onLyricsDocumentReady(');
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
    expect(source, contains('_onLyricsDocumentReady(controller, generation: generation)'));
    expect(source, contains('int? _lyricsDocumentLoadGeneration;'));
    expect(source, contains(r"'generation': '$loadGeneration'"));
    expect(source, contains('_isCurrentLyricsDocumentUrl(url)'));
    // 实参在 tall style 下独占一行，钉去空白后的文本。
    expect(
      source.replaceAll(RegExp(r'\s+'), ''),
      contains('_lyricsDocumentGenerationFromUrl(request.url.toString()'),
    );
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
