import 'package:flutter_test/flutter_test.dart';

import 'reader_hibiki_page_source_corpus.dart';

/// BUG-468 守卫：Windows 阅读器右键曾同时弹两个菜单——Hibiki 自定义的 Flutter 选区菜单
/// （`_showReaderTextContextMenu`）和 WebView2 原生菜单（复制/打印/更多工具）。`contextMenu`
/// 的 `hideDefaultSystemContextMenuItems: true` 是跨平台 ContextMenu API，在 WebView2 fork
/// 上并不接到原生菜单开关；fork 里唯一压制原生菜单的真值是 `InAppWebViewSettings`
/// 的 `disableContextMenu`→`put_AreDefaultContextMenusEnabled`（见
/// packages/flutter_inappwebview_windows/.../in_app_webview.cpp:231）。
///
/// 故 `initialSettings` 必须把 `disableContextMenu` 设成 `isWindowsPlatform`：Windows 关原生
/// 菜单只留 Flutter 菜单，移动端保持 false 不动原生 ContextMenu（查词+导出），防止回退成
/// 「双菜单」或「移动端丢菜单」。
void main() {
  String functionSource(String source, String start, String end) {
    final int startIndex = source.indexOf(start);
    expect(startIndex, isNonNegative, reason: 'missing start marker: $start');
    final int endIndex = source.indexOf(end, startIndex + start.length);
    expect(endIndex, isNonNegative, reason: 'missing end marker: $end');
    return source.substring(startIndex, endIndex);
  }

  test('reader WebView disables the native WebView2 context menu on Windows',
      () {
    final String source = readReaderPageSource();

    final String webViewBuild = functionSource(
      source,
      'Widget _buildWebView()',
      'Future<void> _onChapterLoadComplete(',
    );

    // The InAppWebViewSettings block must carry the real native-menu kill
    // switch, gated to Windows so mobile keeps its native ContextMenu.
    expect(
      webViewBuild,
      contains('initialSettings: InAppWebViewSettings('),
    );
    expect(
      RegExp(r'disableContextMenu:\s*isWindowsPlatform')
          .hasMatch(webViewBuild),
      isTrue,
      reason:
          'disableContextMenu must be isWindowsPlatform — the cross-platform '
          'ContextMenu.hideDefaultSystemContextMenuItems does NOT suppress the '
          'WebView2 native menu; only disableContextMenu does (BUG-468).',
    );

    // It must not be hard-on for every platform (that would kill the mobile
    // native ContextMenu and regress search/export on phones).
    expect(
      RegExp(r'disableContextMenu:\s*true').hasMatch(webViewBuild),
      isFalse,
      reason: 'disableContextMenu must be gated, not unconditionally true',
    );
  });
}
