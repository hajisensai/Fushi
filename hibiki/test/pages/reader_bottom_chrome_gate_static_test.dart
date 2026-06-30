import 'package:flutter_test/flutter_test.dart';

import 'reader_hibiki_page_source_corpus.dart';

/// 阅读器切章/spread 冷开时底栏(bottom chrome)闪烁/延迟出现的回归守卫（源码扫描，
/// 沿用 reader_paginate_lyrics_guard_static_test.dart 的 `_functionSource` 范式）。
///
/// reader 页含真实 `InAppWebView` 平台视图，widget 测试无法挂载整页、无法观测切章
/// 瞬间底栏卸载再挂回的真实帧 —— 故以结构守卫钉死「门控不变式」：
/// - 底栏可见性必须门控在 set-once 的 `_hasEverLoaded`（只置 true、从不复位），不得
///   退回每切章都翻转的 `_readerContentReady`（84f1a22af 主修复，切章不闪）。
/// - spread（漫画双页）路径只发 'spreadReady'、不发 'onRestoreComplete'，必须在
///   spreadReady 回调里也置 `_hasEverLoaded = true`，否则 spread 书冷开底栏(有声书条/
///   设置条)要等 8s `_startContentReadyTimeout` 兜底才出现。
///
/// 任一门控退回，对应断言红。
void main() {
  final String src = readReaderPageSource();

  test('bottom chrome visibility is gated on set-once _hasEverLoaded', () {
    // TODO-975：底栏可见门控收敛进 _bottomBarShouldPaint（挤压恒随
    // _hasEverLoaded && _showChrome；悬浮再加 _chromeTransientVisible），_buildBottomChrome
    // 改调它。不变式（钉死在 set-once _hasEverLoaded、不退回每切章翻转的
    // _readerContentReady）必须在 _bottomBarShouldPaint 里成立。
    final String shouldPaint = _functionSource(
      src,
      '  bool get _bottomBarShouldPaint {',
      '  bool get _anyChromeFloating',
    );
    expect(
      shouldPaint,
      contains('if (!_hasEverLoaded || !_showChrome) return false'),
      reason: '底栏门控必须用 set-once _hasEverLoaded（切章不翻转），不得退回每切章'
          '翻转的 _readerContentReady → 否则切章瞬间底栏卸载再挂回即闪烁。',
    );
    final String buildChrome = _functionSource(
      src,
      '  Widget _buildBottomChrome()',
      '  Widget _buildAudiobookBar()',
    );
    expect(
      buildChrome,
      contains('if (!_bottomBarShouldPaint)'),
      reason: '_buildBottomChrome 必须经收敛后的 _bottomBarShouldPaint 门控可见性。',
    );
    // popupBottomReserve 经 _bottomChromeReserve（含 _hasEverLoaded && _showChrome
    // 占位判据 + 悬浮归零），不得退回 _readerContentReady。
    expect(
      src,
      contains('barOccupiesLayout: _hasEverLoaded && _showChrome'),
      reason: 'popupBottomReserve / _bottomChromeReserve 必须与底栏同门控在 '
          '_hasEverLoaded，不得用 _readerContentReady。',
    );
  });

  test(
      'spread (manga) cold-open marks _hasEverLoaded so bottom bar is not delayed',
      () {
    final String spread = _functionSource(
      src,
      "handlerName: 'spreadReady'",
      "handlerName: 'onCueTap'",
    );
    expect(
      spread,
      contains('_hasEverLoaded = true'),
      reason: "spread 路径只发 'spreadReady' 不发 'onRestoreComplete'，必须在此置 "
          '_hasEverLoaded = true，否则 spread 书冷开底栏要等 8s 超时才出现。',
    );
  });

  test('_hasEverLoaded is set-once (no reset to false except its declaration)',
      () {
    // 只数「复位赋值语句」（必带结尾 `;`），不数 prose 注释里出现的 `_hasEverLoaded
    // = false` 字样 —— 注释描述状态不是复位点，旧正则漏算 `;` 会把注释误判成复位。
    final int resets =
        RegExp(r'_hasEverLoaded\s*=\s*false\s*;').allMatches(src).length;
    expect(
      resets,
      1,
      reason: '_hasEverLoaded 必须 set-once：除声明行 `bool _hasEverLoaded = false;` '
          '外不得有任何复位语句（复位会让切章底栏重新闪烁）。',
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
