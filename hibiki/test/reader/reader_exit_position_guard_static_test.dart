import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String source = File(
    'lib/src/pages/implementations/reader_hibiki_page.dart',
  ).readAsStringSync();

  test('page turns wait for the displayed progress snapshot before returning',
      () {
    final String paginate = _functionSource(
      source,
      '  Future<void> _paginate(ReaderNavigationDirection direction) async',
      '  void _openImageViewer(String imgUrl)',
    );

    expect(
      paginate,
      contains('await _refreshProgress()'),
      reason:
          'exiting immediately after a page turn must not race the progress '
          'snapshot; otherwise the saved reader position can stay on the '
          'previous page.',
    );
  });

  test('lifecycle flush syncs the WebView current page before persisting', () {
    final String syncAndFlush = _functionSource(
      source,
      '  Future<void> _syncAndFlushPosition() async',
      '  Future<void> _flushPosition() async',
    );

    expect(
      source,
      contains('Future<void> _syncPositionFromWebViewProgress() async'),
      reason: 'the exit/background path needs a direct WebView progress probe, '
          'not only the last 10-second poll value.',
    );
    expect(
      source,
      contains('ReaderPaginationScripts.stableProgressInvocation()'),
      reason: 'resizing/re-anchoring can transiently reset scroll position; '
          'exit sync must not persist that unstable snapshot.',
    );
    expect(
      syncAndFlush,
      contains('await _syncPositionFromWebViewProgress()'),
      reason: '_syncAndFlushPosition is the shared dispose/background path and '
          'must capture the page currently displayed by the WebView.',
    );
    expect(
      syncAndFlush.indexOf('await _syncPositionFromWebViewProgress()'),
      lessThan(syncAndFlush.indexOf('await _flushPosition()')),
      reason:
          'the fresh displayed progress must replace the cached value before '
          'the DB write is flushed.',
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
