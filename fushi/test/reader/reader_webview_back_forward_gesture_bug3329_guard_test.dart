import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-3356：iOS 上阅读器左缘横滑（用户习惯的侧滑返回）把正文跳走。
///
/// 根因：flutter_inappwebview 的 `allowsBackForwardNavigationGestures` 默认 true，
/// WKWebView 把边缘横滑当成**自己的历史前进 / 后退**；阅读器跨章 `loadUrl`、歌词文档
/// `loadData` 都会往 WebView 历史里压条目，侧滑就退回上一章 / 旧文档。路由侧滑早被
/// 页面 `PopScope(canPop: false)` 关掉，剩下的就是 WebView 这一层。
///
/// 覆盖边界：手势本身只有 iOS 真机 / 模拟器能验；这里钉住两个阅读器 WebView 的
/// `initialSettings` 都显式关掉它（删掉这行即红）。
void main() {
  const List<String> files = <String>[
    'lib/src/pages/implementations/reader_fushi/webview.part.dart',
    'lib/src/pages/implementations/reader_fushi/lyrics.part.dart',
  ];

  for (final String path in files) {
    test('$path 的 InAppWebViewSettings 关掉 WebView 历史侧滑', () {
      final String src = File(path).readAsStringSync();
      final int start = src.indexOf('initialSettings: InAppWebViewSettings(');
      expect(start, isNonNegative, reason: '$path 找不到 initialSettings');
      final int end = src.indexOf('\n      ),', start);
      expect(end, greaterThan(start), reason: '$path 找不到 settings 结尾');
      final String settings = src.substring(start, end);
      expect(
        settings,
        contains('allowsBackForwardNavigationGestures: false,'),
        reason: 'WKWebView 默认把边缘横滑当历史前进 / 后退，阅读器跨章会被侧滑退回上一章',
      );
    });
  }
}
