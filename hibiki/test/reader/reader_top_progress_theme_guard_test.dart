import 'package:flutter_test/flutter_test.dart';

import '../pages/reader_hibiki_page_source_corpus.dart';

void main() {
  test('top reading progress follows the reader theme text color', () {
    final String src = readReaderPageSource();
    final String topProgress = _functionSource(
      src,
      '  Widget _buildTopProgressBar()',
    );

    expect(
      topProgress,
      contains('_themeTextColor()'),
      reason: 'the top reading progress must follow the active reader theme',
    );
    expect(
      src,
      isNot(contains('Color _infoTextColor()')),
      reason: 'do not keep a hard-coded progress text color helper',
    );
  });
}

String _functionSource(String source, String start) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int bodyStart = source.indexOf('{', startIndex + start.length);
  expect(bodyStart, isNonNegative, reason: 'Missing function body: $start');

  int depth = 0;
  for (int index = bodyStart; index < source.length; index++) {
    final String char = source[index];
    if (char == '{') {
      depth++;
    } else if (char == '}') {
      depth--;
      if (depth == 0) {
        return source.substring(startIndex, index + 1);
      }
    }
  }

  fail('Missing function end: $start');
}
