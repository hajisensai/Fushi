import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('阅读器注册并在 dispose 清理 debugCaptureWebView 钩子', () {
    final String page = File(
      'lib/src/pages/implementations/reader_fushi_page.dart',
    ).readAsStringSync();
    final String webviewPart = File(
      'lib/src/pages/implementations/reader_fushi/webview.part.dart',
    ).readAsStringSync();

    expect(
      page.contains(
        'static Future<Uint8List?> Function()? debugCaptureWebView',
      ),
      isTrue,
      reason: '应在 ReaderFushiPage 声明 debugCaptureWebView 测试钩子',
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

  test('阅读器注册并在 dispose 清理 debugCallDevToolsProtocol 钩子', () {
    final String page = File(
      'lib/src/pages/implementations/reader_fushi_page.dart',
    ).readAsStringSync();
    final String webviewPart = File(
      'lib/src/pages/implementations/reader_fushi/webview.part.dart',
    ).readAsStringSync();
    expect(
      webviewPart.contains('debugCallDevToolsProtocol ='),
      isTrue,
      reason: 'onWebViewCreated 里应注册 CDP 钩子（itest 投触摸用）',
    );
    expect(
      webviewPart.contains('controller.callDevToolsProtocolMethod('),
      isTrue,
      reason: 'CDP 钩子应直接调 controller.callDevToolsProtocolMethod',
    );
    expect(
      page.contains('debugCallDevToolsProtocol = null'),
      isTrue,
      reason: 'dispose 应把 debugCallDevToolsProtocol 置空',
    );
  });
}
