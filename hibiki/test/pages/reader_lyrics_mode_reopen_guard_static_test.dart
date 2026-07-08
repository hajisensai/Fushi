import 'package:flutter_test/flutter_test.dart';

import 'reader_hibiki_page_source_corpus.dart';

void main() {
  test('fresh reader open never restores persisted lyrics mode', () {
    final String source = readReaderPageSource();
    final String initSource = _functionSource(
      source,
      '  Future<void> _initBookInner() async {',
      '  /// TODO-131: 按 bookKey 查 EpubBooks 行',
    );

    expect(
      initSource,
      contains('_lyricsMode = false;'),
      reason: '歌词模式是当前 reader 页面的瞬时显示态；新开书必须回到正文模式。',
    );
    expect(
      initSource,
      contains('await ReaderHibikiSource.instance.setLyricsMode(false);'),
      reason: '新开书应清掉旧会话留下的 persisted lyrics_mode，避免下次再次自动进入。',
    );
    expect(
      initSource,
      isNot(contains('savedLyricsMode')),
      reason: '不能把旧会话保存的 lyrics_mode 当成 fresh open 的恢复状态。',
    );
    expect(
      initSource,
      isNot(contains('_lyricsMode = ReaderHibikiSource.instance.lyricsMode')),
      reason: 'fresh open 不应由 persisted lyrics_mode 驱动 UI 模式。',
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
