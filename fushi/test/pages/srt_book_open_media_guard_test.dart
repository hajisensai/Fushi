import 'package:flutter_test/flutter_test.dart';

import 'reader_history_source_corpus.dart';

/// BUG-456 source guard: SRT/audiobook shelf entries must enter the reader via
/// AppModel.openMedia, just like normal EPUB entries. That call registers
/// ReaderFushiSource as currentMediaSource; a direct Navigator.push leaves it
/// null, so lookup sentence writes and favorite/mining sentence reads become
/// silent no-ops.
void main() {
  test('SRT book opens through AppModel.openMedia, not direct reader push', () {
    final String source = readReaderHistorySource();
    final String openSrtBook = _sectionSource(
      source,
      'Future<void> _openSrtBook(SrtBook book) async {',
      '  List<DialogAction> _srtExtraActions(',
    );

    expect(openSrtBook, contains('await appModel.openMedia('));
    expect(openSrtBook, contains('ref: ref'));
    expect(
      openSrtBook,
      contains('mediaSource: ReaderFushiSource.instance'),
    );
    expect(openSrtBook, contains('item: _srtBookMediaItem(book)'));

    expect(
      openSrtBook,
      isNot(contains('Navigator.push')),
      reason: 'Direct pushes bypass AppModel.openMedia and leave '
          'currentMediaSource null for SRT books.',
    );
    expect(openSrtBook, isNot(contains('ReaderFushiPage(')));
    expect(openSrtBook, isNot(contains('FushiAppUiScaleNeutralizer(')));
  });

  test('SRT shelf tap still delegates to the SRT open method', () {
    final String source = readReaderHistorySource();
    final String srtCard = _sectionSource(
      source,
      // 块2 起签名带 selectable（多选态成员卡不单独勾选），锚点跟随。
      'Widget _buildSrtCard(SrtBook book,',
      '  Widget _buildSrtCover(',
    );

    expect(srtCard, contains('onTap: () => _openSrtBook(book)'));
  });
}

String _sectionSource(String source, String startToken, String endToken) {
  final int start = source.indexOf(startToken);
  expect(start, isNonNegative, reason: 'Missing source marker: $startToken');
  final int end = source.indexOf(endToken, start + startToken.length);
  expect(
    end,
    greaterThan(start),
    reason: 'Missing end marker after $startToken: $endToken',
  );
  return source.substring(start, end);
}
