import 'package:flutter_test/flutter_test.dart';

import 'reader_hibiki_page_source_corpus.dart';

void main() {
  // BUG-285 (TODO-375) regression guard: _persistPosition must pass null (not a
  // raw -1) when the WebView snapshot has no exact char offset, so a transient
  // -1 during reflow / vertical edge sampling does NOT clobber the precise
  // same-section anchor. Clobbering it degrades restore + cross-chapter audio
  // follow back to chapter-start granularity (symptom 1: "音频跟随只能到章节").
  // ReaderPositionRepository.save owns the same-section-keep / cross-section-clear
  // decision when charOffset is null.
  test(
      'position save preserves the precise same-section anchor when the '
      'current char offset is unavailable (-1 → null, not raw -1)', () {
    final String source = readReaderPageSource();

    final String persist = _between(
      source,
      '  Future<void> _persistPosition(',
      '  void _syncPositionFromCurrentCue()',
    );

    expect(
      persist,
      contains('charOffset: charOffset >= 0 ? charOffset : null'),
      reason: 'A transient charOffset=-1 must map to null so '
          'ReaderPositionRepository.save keeps the existing same-section exact '
          'anchor instead of overwriting it with -1 (chapter granularity).',
    );
    expect(
      persist,
      isNot(contains('charOffset: charOffset,')),
      reason: 'Passing the raw charOffset (which may be -1) overwrites the '
          'precise same-section anchor and is exactly the BUG-285 regression.',
    );
  });

  test('continuous paginate refreshes progress after a successful JS scroll',
      () {
    final String source = readReaderPageSource();

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
