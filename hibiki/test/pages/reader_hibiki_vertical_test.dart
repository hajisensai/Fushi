import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'position save clears stale exact anchor when current char offset failed',
      () {
    final String source = File(
      'lib/src/pages/implementations/reader_hibiki_page.dart',
    ).readAsStringSync();

    final String persist = _between(
      source,
      '  Future<void> _persistPosition(',
      '  void _syncPositionFromCurrentCue()',
    );

    expect(
      persist,
      contains('charOffset: charOffset,'),
      reason: 'If the current WebView snapshot reports charOffset=-1, the '
          'reader must clear any old exact anchor. Keeping it can make restore '
          'prefer a stale chapter-start charOffset over the newly saved progress.',
    );
    expect(
      persist,
      isNot(contains('charOffset >= 0 ? charOffset : null')),
      reason: 'Passing null keeps same-section char_offset unchanged in '
          'ReaderPositionRepository.',
    );
  });

  test('continuous paginate refreshes progress after a successful JS scroll',
      () {
    final String source = File(
      'lib/src/pages/implementations/reader_hibiki_page.dart',
    ).readAsStringSync();

    final String paginate = _between(
      source,
      '  Future<void> _paginate(ReaderNavigationDirection direction) async',
      '  File? _readerImageFileForUrl(String imgUrl)',
    );
    final String continuousBranch = _between(
      paginate,
      'if (_settings?.isContinuousMode == true)',
      '\n    final dynamic result = await _controller!.evaluateJavascript(',
    );

    expect(
      continuousBranch,
      contains('await _refreshProgress();'),
      reason: 'Continuous-mode programmatic page turns must update the cached '
          'reader position immediately, not wait for a later scroll debounce.',
    );
    expect(
      continuousBranch,
      contains('await _caretReanchor(direction);'),
      reason: 'Caret reanchor should remain after the position refresh.',
    );
  });
}

String _between(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}
