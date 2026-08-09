import 'package:flutter_test/flutter_test.dart';

import 'reader_fushi_page_source_corpus.dart';

void main() {
  // BUG-785: 歌词模式改为可跨会话恢复（用户请求「重进书籍还在歌词模式」）。fresh open
  // 仍以正文起步（绝不由 persisted lyrics_mode 直接整页加载歌词 HTML 跳过 EPUB —— iOS
  // 大字幕书白屏的根因），但改为**捕获待恢复意图**（保留偏好），等 EPUB 就绪 + 有声书
  // 挂载后再切歌词（见 _onChapterLoadComplete 的 _pendingLyricsRestore 触发，另有守卫）。
  test(
      'fresh reader open starts in reader mode and defers (not wipes) lyrics restore',
      () {
    final String source = readReaderPageSource();
    final String initSource = _functionSource(
      source,
      '  Future<void> _initBookInner() async {',
      '  /// TODO-131: 按 bookKey 查 EpubBooks 行',
    );

    expect(
      initSource,
      contains('_lyricsMode = false;'),
      reason: '新开书必须先回正文模式，绝不直接整页加载歌词 HTML（iOS 白屏）。',
    );
    expect(
      initSource,
      isNot(contains('_lyricsMode = ReaderFushiSource.instance.lyricsMode')),
      reason: 'fresh open 不应由 persisted lyrics_mode 直接驱动 UI 模式（仍先正文）。',
    );
    // BUG-785: 捕获意图代替抹除——保留偏好以便延迟恢复。
    expect(
      initSource,
      contains(
          '_pendingLyricsRestore = ReaderFushiSource.instance.lyricsMode;'),
      reason: 'fresh open 应把持久化歌词模式记成待恢复意图。',
    );
    expect(
      initSource,
      isNot(contains('setLyricsMode(false)')),
      reason: 'BUG-785: 不再在 _initBookInner 抹除偏好，否则跨会话恢复失效。',
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
