import 'package:flutter_test/flutter_test.dart';

import '../pages/reader_hibiki_page_source_corpus.dart';

void main() {
  final String source = readReaderPageSource();

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

  test('BUG-203 returning to the shelf flushes the live WebView page (await)',
      () {
    // The back-button path is the only awaitable exit hook: dispose()'s
    // _syncAndFlushPosition() is fire-and-forget and loses the race against
    // super.dispose() tearing down the WebView, so the saved position falls
    // back to the stale 10s-poll/debounce value (restore drifts back pages).
    // BaseSourcePageState.onWillPop awaits onSourcePagePop() BEFORE closeMedia
    // / triggerAutoSyncAfterClose, so the reader must override it to write the
    // currently displayed page through first.
    final String onPop = _functionSource(
      source,
      '  Future<void> onSourcePagePop() async',
      '  // The input device flipped between touch',
    );
    expect(
      onPop,
      contains('await _syncAndFlushPosition()'),
      reason:
          'the back-button exit path must capture the live WebView page before '
          'the base class runs closeMedia/auto-sync, otherwise the restore '
          'point drifts to a previous page (BUG-203).',
    );
    expect(
      onPop.indexOf('await _syncAndFlushPosition()'),
      lessThan(onPop.indexOf('await _flushReadingStats()')),
      reason: 'position sync must precede the reading-stats flush on exit.',
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
