import 'package:flutter_test/flutter_test.dart';

import 'reader_hibiki_page_source_corpus.dart';

/// BUG-111 守卫（源码扫描，沿用 reader_bottom_chrome_gate_static_test.dart 范式）。
///
/// 桌面端「界面大小」≠100% 时，进阅读器/开书初始分页宽度可能偏窄（缩放层 LayoutBuilder/
/// FittedBox 未 settle，setup 脚本捕获到被缩小的视口宽），表现为正文只铺半边、需手动
/// resize 才铺满。根因不在「resize 不重排」（`_syncPageSize` 正常工作），而在 content-ready
/// 的初始重排校验**自我抹平**：旧代码先把 `_lastSyncedWidth = 当前 MediaQuery 宽`，再
/// postFrame 调 `_syncPageSize`，于是 `w != _lastSyncedWidth` 恒为 false、初始校验恒 no-op。
///
/// 修复不变式（任一退回 → 红）：
/// 1. `_buildReaderSetupScript` 必须把 JS 实际分页用的 `screenSize` 记进 `_paginatedWidth/Height`。
/// 2. content-ready 收尾（`_onChapterLoadComplete` / `_onRestoreComplete`）的同步基线必须取
///    `_paginatedWidth/Height`（= JS 已分页的宽高），不得用 content-ready 那一刻的当前
///    MediaQuery（`screen.width` / `screenSync.width`）抹平差值。
/// 3. 因此整文件不得再出现 `_lastSyncedWidth = screen.width` /
///    `_lastSyncedWidth = screenSync.width` 这类「当前 MQ 抹平」赋值。
void main() {
  final String src = readReaderPageSource();

  test(
      'setup script records the paginated viewport into _paginatedWidth/Height',
      () {
    final String setup = _functionSource(
      src,
      '  String _buildReaderSetupScript(',
      '  // ── ',
    );
    expect(
      setup,
      contains('_paginatedWidth = screenSize.width'),
      reason:
          'setup 脚本必须把 dartPageWidth 用的 screenSize.width 记进 _paginatedWidth，'
          '作为 content-ready 后的「已分页基线」。',
    );
    expect(
      setup,
      contains('_paginatedHeight = screenSize.height'),
      reason: 'setup 脚本必须同步记录 _paginatedHeight。',
    );
  });

  test('content-ready baseline uses _paginatedWidth, not current MediaQuery',
      () {
    // _onRestoreComplete：初始首屏 content-ready 的权威路径，postFrame 会调 _syncPageSize。
    final String restore = _functionSource(
      src,
      '  void _onRestoreComplete()',
      '  bool ',
    );
    expect(
      restore,
      contains('_lastSyncedWidth = _paginatedWidth'),
      reason: '_onRestoreComplete 的同步基线必须取 _paginatedWidth（JS 已分页宽度），'
          '否则 postFrame 的 _syncPageSize 比对同值、初始重排恒 no-op（BUG-111）。',
    );
    expect(
      restore,
      contains('_lastSyncedHeight = _paginatedHeight'),
      reason: '_onRestoreComplete 高度基线同理取 _paginatedHeight。',
    );
  });

  test('no current-MediaQuery self-flattening of _lastSyncedWidth survives',
      () {
    expect(
      src.contains('_lastSyncedWidth = screen.width'),
      isFalse,
      reason:
          '不得用 content-ready 当前 MediaQuery（screen.width）抹平 _lastSyncedWidth '
          '——这正是 BUG-111 让初始重排校验失效的写法。',
    );
    expect(
      src.contains('_lastSyncedWidth = screenSync.width'),
      isFalse,
      reason: '不得用 _onChapterLoadComplete 的当前 MediaQuery（screenSync.width）抹平 '
          '_lastSyncedWidth。',
    );
  });
}

/// 截取 [source] 中从 [start] 标记到其后第一个 [end] 标记之间的片段（含函数体）。
String _functionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}
