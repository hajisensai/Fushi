import 'package:flutter_test/flutter_test.dart';

import 'reader_hibiki_page_source_corpus.dart';

/// BUG-379：歌词模式（LyricsModeHtml）进度条跑进底栏。
///
/// 歌词页是独立 HTML，没有 `window.hoshiReader`，`_applyChromeInsets` 对它整体
/// early-return，正文那套「告诉 WebView 底栏预留高度」的机制对歌词页失效。歌词 WebView
/// 仍 `Positioned.fill` 铺满全屏，底栏（`_buildAudiobookBar`，bottom:0）盖在其上，歌词
/// 文档级 CSS 滚动条（主题化的细条）沿整屏高度绘制，底部一段被绘制进底栏区域 → 看上去
/// 像「进度条跑进底栏」。
///
/// 修复：`_buildBody` 在歌词模式且底栏可见时给 WebView 套底部 padding
/// `_readerBottomReserve`，把视口收缩到底栏之上，CSS 滚动条只画在歌词区域内。
///
/// reader 页含真实 `InAppWebView` 平台视图，widget 测试无法挂载整页观测 CSS 滚动条几何，
/// 故以源码扫描守卫钉死「歌词模式 _buildBody 留底栏空间」不变式（撤销修复 → 断言红）。
void main() {
  final String src = readReaderPageSource();

  test('lyrics-mode _buildBody reserves bottom space for the chrome bar', () {
    final String body = _functionSource(
      src,
      '  Widget _buildBody()',
      // BUG-396：原结束标记 `_isCustomTheme` getter 已随判据归一删除，改用紧随其后的
      // `_buildStyleTag`（仍在 `_buildBody` 之后）作为切片终点。
      '  String _buildStyleTag()',
    );
    // 歌词模式 + 底栏可见时必须给 WebView 套底部预留，否则全屏歌词 WebView 的 CSS
    // 滚动条会延伸进底栏区域。底栏可见条件与 _buildBottomChrome / popupBottomReserve
    // 一致（_hasEverLoaded && _showChrome）。
    expect(
      body.contains('_lyricsMode && _hasEverLoaded && _showChrome'),
      isTrue,
      reason: '歌词模式且底栏可见时 _buildBody 必须给 WebView 留底栏空间（BUG-379）',
    );
    expect(
      body.contains('EdgeInsets.only(bottom: _readerBottomReserve)'),
      isTrue,
      reason: '歌词 WebView 必须收缩 _readerBottomReserve，使 CSS 滚动条不进底栏',
    );
    // 防回归：底部预留高度必须复用 _readerBottomReserve（= chrome 高 + 底部安全区），
    // 不得硬编码一个不跟底栏实际高度走的常量。
    expect(
      body.contains('Padding('),
      isTrue,
      reason: '歌词模式分支必须用 Padding 收缩 WebView',
    );
  });
}

/// 截取 [source] 中从 [start] 标记到下一个 [end] 标记之间的片段（含函数体）。
String _functionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}
