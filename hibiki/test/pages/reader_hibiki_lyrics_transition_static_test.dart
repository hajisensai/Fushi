import 'package:flutter_test/flutter_test.dart';
import 'reader_hibiki_page_source_corpus.dart';

void main() {
  test('lyrics mode transition does not draw a full-screen scrim', () {
    final String source = readReaderPageSource();
    final String buildSource = _functionSource(
      source,
      '  Widget build(BuildContext context)',
      '  Widget _buildBody()',
    );
    final String contentReadyOverlay = _sectionSource(
      buildSource,
      '                if (!_readerContentReady)',
      '                if (_readerContentReady)',
    );
    final String toggleSource = _functionSource(
      source,
      '  Future<void> _toggleLyricsMode() async',
      '  Future<void> _loadLyricsPage() async',
    );

    expect(contentReadyOverlay, isNot(contains('AnimatedOpacity(')));
    expect(contentReadyOverlay, isNot(contains('_lyricsModeTransition')));
    expect(toggleSource, isNot(contains('Duration(milliseconds: 200)')));
  });
}

String _functionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}

String _sectionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}
