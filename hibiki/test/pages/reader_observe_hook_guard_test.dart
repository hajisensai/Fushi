import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('阅读器注册并在 dispose 清理 debugCaptureWebView 钩子', () {
    final String page = File(
      'lib/src/pages/implementations/reader_hibiki_page.dart',
    ).readAsStringSync();
    final String webviewPart = File(
      'lib/src/pages/implementations/reader_hibiki/webview.part.dart',
    ).readAsStringSync();

    expect(
      page.contains(
        'static Future<Uint8List?> Function()? debugCaptureWebView',
      ),
      isTrue,
      reason: '应在 ReaderHibikiPage 声明 debugCaptureWebView 测试钩子',
    );
    expect(
      webviewPart.contains('debugCaptureWebView ='),
      isTrue,
      reason: 'onWebViewCreated 里应注册 debugCaptureWebView',
    );
    expect(
      webviewPart.contains('takeScreenshot()'),
      isTrue,
      reason: '钩子应调用 controller.takeScreenshot()',
    );
    expect(
      page.contains('debugCaptureWebView = null'),
      isTrue,
      reason: 'dispose 应把 debugCaptureWebView 置空，避免跨测污染 / 悬挂引用',
    );
  });
}
