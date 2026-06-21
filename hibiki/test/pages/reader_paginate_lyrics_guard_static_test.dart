import 'package:flutter_test/flutter_test.dart';

import 'reader_hibiki_page_source_corpus.dart';

void main() {
  // Regression: in lyrics mode the WebView holds LyricsModeHtml, which has no
  // hoshiReader paginator. A keyboard/gamepad/volume page-turn funnels through
  // _paginate(); without an early bail it no-ops in JS, is misread as a page
  // edge, and triggers _handlePageTurnLimit → _navigateToChapter, replacing the
  // lyrics page with an EPUB chapter (the lyrics text disappears). _paginate
  // must bail on _lyricsMode before touching the paginator — the single choke
  // point the swipe handlers (onSwipe/onBoundarySwipe) already guard.
  test('_paginate bails in lyrics mode before invoking the paginator', () {
    final String source = readReaderPageSource();

    final String paginate = _functionSource(
      source,
      '  Future<void> _paginate(ReaderNavigationDirection direction) async',
      '  // ── Image Viewer',
    );

    expect(
      paginate,
      contains('if (_lyricsMode)'),
      reason: '_paginate must early-return in lyrics mode',
    );

    final int guardIndex = paginate.indexOf('_lyricsMode');
    final int paginateCallIndex = paginate.indexOf('paginateInvocation');
    expect(guardIndex, isNonNegative);
    expect(paginateCallIndex, isNonNegative);
    expect(
      guardIndex,
      lessThan(paginateCallIndex),
      reason: 'the _lyricsMode guard must precede the paginator invocation',
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
