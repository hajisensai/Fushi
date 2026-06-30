import 'package:flutter_test/flutter_test.dart';

import 'reader_hibiki_page_source_corpus.dart';

/// BUG-470（TODO-975 回归修复）守卫：首屏顶部进度 inset 缺口。
///
/// TODO-975 把 `_readerTopOffset` 从「无条件含 18px 进度条预留」改为
/// `_stableTopInset + _topProgressReserve`，而 `_topProgressReserve` 经
/// `_showTopProgress` 门控（要求 `_progressCurrentChars`/`_progressTotalChars`
/// 非空且 > 0）。这两个字段在 `_refreshProgress` 才首次置值，**晚于**首载注入
/// WebView 的 `--chrome-top-inset`（用 `_readerTopOffset`，此刻顶部预留仍 0）。
/// 首载后再无路径在「进度由空→正」跃迁上重推 inset → 正文首行被顶部进度条压住，
/// 直到下次样式变更/切主题/toggle 底栏/旋屏才自愈。
///
/// reader 页含真实 `InAppWebView` 平台视图，widget 测试无法挂载整页、无法观测
/// 首载 inset 注入的真实帧，故以源码守卫钉死「门控不变式」（沿用
/// `reader_bottom_chrome_gate_static_test.dart` 范式）：
/// - `_refreshProgress` 必须在写 `_progressCurrentChars`/`_progressTotalChars`
///   前快照 `_showTopProgress`，并在它由 false→true 的上升沿补推 inset。
/// - 顶部预留 `_topProgressReserve` 仍经 `_showTopProgress` 门控（真相源不被绕过）。
///
/// 任一不变式退回，对应断言红。
void main() {
  final String src = readReaderPageSource();

  test('_refreshProgress re-pushes chrome insets on top-progress rising edge',
      () {
    final String refresh = _functionSource(
      src,
      '  Future<void> _refreshProgress() async {',
      '  /// TODO-796：当前章是纯图片',
    );

    expect(
      refresh,
      contains('final bool topProgressWasShown = _showTopProgress;'),
      reason: '_refreshProgress 必须在 rebuild 写进度字段**前**快照 _showTopProgress '
          '（顶部预留的门控真相源），才能检出首屏 null→正 的上升沿。',
    );

    final int snapshotIndex =
        refresh.indexOf('final bool topProgressWasShown = _showTopProgress;');
    final int rebuildIndex =
        refresh.indexOf('_progressCurrentChars = absoluteChars;');
    expect(snapshotIndex, isNonNegative);
    expect(rebuildIndex, isNonNegative);
    expect(
      snapshotIndex < rebuildIndex,
      isTrue,
      reason:
          '_showTopProgress 快照必须在写 _progressCurrentChars/_progressTotalChars '
          '之前——否则 rebuild 后两次都为 true，检不出上升沿。',
    );

    expect(
      refresh,
      contains('if (!topProgressWasShown && _showTopProgress)'),
      reason: '必须仅在顶部进度 false→true 的上升沿补推 inset（不是每次进度刷新都推，'
          '避免轮询/滚动造成 inset 抖动）。',
    );
    expect(
      refresh,
      contains('_applyChromeInsetsAndReanchor()'),
      reason: '上升沿补推必须走 _applyChromeInsetsAndReanchor（先下发含 18px 顶部'
          '预留的新 inset，再 begin→commit 重锚把阅读位置滚回，不破坏 restore 位置）。',
    );
  });

  test('_topProgressReserve stays gated on _showTopProgress (single source)',
      () {
    final String reserve = _functionSource(
      src,
      '  double get _topProgressReserve => topProgressReserve(',
      '  /// TODO-975：底栏内容行的预留高',
    );
    expect(
      reserve,
      contains('showTopProgress: _showTopProgress'),
      reason: '顶部预留必须经 _showTopProgress 门控（真相源），补推 inset 才能与可见性对齐。',
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
