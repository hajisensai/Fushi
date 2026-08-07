import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1078 源码守卫：桌面 Windows 阅读器裸 Space 在 WebView2 抢走 OS 键盘焦点后，
/// 不再被 Chromium 默认 scrollByPage 吞掉，而是走「JS 捕获 → callHandler → Dart 解析」
/// 的既有范式（与 onSwipe/onWheelPaginate 同款），交回 resolveReaderSpaceOverride 判成
/// 有声书播放/暂停或翻页。
///
/// 该链路涉 WebView2 + 平台键盘转发，widget 测试照不到真实按键落 DOM，故用源码扫描
/// 钉死接线不回退：① 内容层注入 keydown 监听裸 Space；② preventDefault 掐掉浏览器默认
/// 滚屏；③ 经 callHandler('onSpaceKey') 回传；④ Dart 注册 onSpaceKey handler；⑤ handler
/// 经 _resolveWebViewSpaceAction 走 resolveReaderSpaceOverride 统一解析。
void main() {
  final File webview =
      File('lib/src/pages/implementations/reader_fushi/webview.part.dart');
  final File caret =
      File('lib/src/pages/implementations/reader_fushi/caret.part.dart');

  /// 折叠所有空白（含换行/多空格）为单空格，令断言匹配「真实 token 序列」而非精确
  /// 格式（换行、缩进重排不会误伤守卫）。
  String squash(String s) => s.replaceAll(RegExp(r'\s+'), ' ');

  test('webview.part.dart：注入裸 Space 键盘桥并接上 onSpaceKey handler', () {
    expect(webview.existsSync(), isTrue,
        reason: 'webview.part.dart 不存在，路径变了须更新守卫');
    final String src = webview.readAsStringSync();
    final String flat = squash(src);

    // ① 内容层 keydown 捕获经共享生成器注入（JS 本身的不变式——只拦裸键、放行
    // 修饰键组合 / IME / 输入框、preventDefault、回传 key——由
    // test/focus/webview_key_bridge_test.dart 守，避免同一份行为在两处重复断言）。
    expect(flat, contains('webViewKeyBridgeScript('),
        reason: '必须经共享的 webViewKeyBridgeScript 注入内容层 keydown 捕获');
    final int start = flat.indexOf('webViewKeyBridgeScript(');
    final String call = flat.substring(start, start + 160);
    expect(call, contains("handlerName: 'onSpaceKey'"),
        reason: "桥必须回传到 'onSpaceKey'");
    expect(call, contains("keys: const <String>[' ']"),
        reason: '阅读器只拦裸 Space（其余键仍走 Flutter 焦点路径）');

    // ② Dart 侧注册 onSpaceKey handler 并解析动作。
    expect(flat, contains("handlerName: 'onSpaceKey'"),
        reason: 'Dart 必须注册 onSpaceKey handler 接收回传');
    expect(flat, contains('_resolveWebViewSpaceAction()'),
        reason: 'handler 必须经 _resolveWebViewSpaceAction 解析动作');
  });

  test(
      'caret.part.dart：裸 Space 解析走 resolveReaderSpaceOverride + reader scope 回落',
      () {
    final String src = caret.readAsStringSync();
    final String flat = squash(src);

    expect(flat, contains('ShortcutAction? _resolveWebViewSpaceAction()'),
        reason: '必须有 _resolveWebViewSpaceAction 解析裸 Space');
    final int start = flat.indexOf('_resolveWebViewSpaceAction()');
    final String body = flat.substring(start, start + 600);
    expect(body.contains('resolveReaderSpaceOverride('), isTrue,
        reason: '裸 Space 必须交 resolveReaderSpaceOverride 判有声书覆写');
    expect(body.contains('hasActiveAudiobook: _hasActiveAudiobook'), isTrue,
        reason: '有声书激活判据必须用 _hasActiveAudiobook（与键盘焦点路径同源）');
    expect(body.contains('ShortcutScope.reader'), isTrue,
        reason: '非有声书态必须回落 reader scope 裸 Space 绑定（默认翻页），行为不变');
  });
}
